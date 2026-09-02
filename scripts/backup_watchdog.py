"""backup_watchdog.py — 备份盘瞬断保护：无人值守地把一份 pm 备份计划跑到底。

用法:
  python backup_watchdog.py --plan <planId> --root <备份盘 root> --main <主库> --log <pm 输出日志>
                            [--max-resumes 20] [--drive-wait 1800] [--final-doctor]

做法（只用 pm 自己的公开命令，不碰照片字节）：
  1. 读备份盘 journal，算出本计划里第一个还没 Done 的条目，向下取到它所在复合组的组首；
  2. 以 `pm apply <plan> --only <组首>-<末项>` 续跑——已完成的组不再逐个重 hash
     （pm 全量续跑会对每个已落盘目标与隔离件重算 sha，每次瞬断都要白读几十 GB）；
  3. pm 非零退出后：先等盘回来（轮询 root-id.json 可读），判定是否掉线
     （等待过 / 输出里有 I/O 异常签名），是则冷却后回到 1；不是掉线且零进展则停下报告；
  4. 全部 Done 后跑 `pm backup`（重扫备份盘并比对）；`--final-doctor` 再跑
     `pm doctor --backup`（对所有 Done 目标与隔离件重读 sha——瞬断后的介质核验）。
所有 pm 输出追加进 --log；本脚本 stdout 只打每次尝试一行摘要与最终结论。
"""
import argparse
import io
import json
import os
import shutil
import subprocess
import sys
import time

from backup_verify import Drive, sha_of  # 三支备份盘脚本共用：等盘回来 / 全文 sha

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", line_buffering=True)
sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", line_buffering=True)

DROP_SIGNS = (
    "invalid argument", "hPutBuf", "hGetBuf", "resource vanished", "device is not ready",
    "Incorrect function", "备份盘未挂载", "hardware error", "The device is not ready",
    "设备未就绪", "不正确的函数", "semaphore timeout", "信号灯超时",
)
LOCK_SIGN = "正持有该 root 的锁"


def now():
    return time.strftime("%H:%M:%S")


def say(msg):
    print(f"{now()} {msg}")


class Watchdog:
    def __init__(self, a):
        self.a = a
        self.pm = shutil.which("pm")
        if not self.pm:
            sys.exit("pm not on PATH")
        self.plan_path = os.path.join(a.root, ".pm", "plans", a.plan + ".json")
        self.journal = os.path.join(a.root, ".pm", "journal.ndjson")
        self.drive = Drive(a.root, a.drive_wait, cooldown_s=5)
        plan = json.load(open(self.plan_path, encoding="utf-8"))
        assert plan["id"] == a.plan, plan["id"]
        self.items = plan["items"]
        self.n = len(self.items)
        self.max_ix = max(it["ix"] for it in self.items)
        self.group_of = {it["ix"]: it["group"] for it in self.items}
        self.op_of = {it["ix"]: it["op"] for it in self.items}
        self.must = sorted(it["ix"] for it in self.items if it["status"].get("s") == "pending")
        self.holes = {}          # ix -> 判定文案
        self.hole_checked = set()
        say(f"pm={self.pm} plan={a.plan} items={self.n} pending={len(self.must)} groups={len(set(self.group_of.values()))}")

    # ── 盘面：backup_verify.Drive（root-id.json 可读 = 盘在；ensure() 等盘回来并冷却，返回 True 表示等过；超时退出码 3）──
    def wait_for_drive(self):
        return self.drive.ensure()

    # ── journal ──────────────────────────────────────────────────────────
    def journal_sets(self):
        """返回 (done, intent)：本计划里规范 oid（无 ~r 等后缀）的 Done 集与 Intent 集。"""
        done, intent = set(), set()
        prefix = self.a.plan + "#"
        with open(self.journal, "rb") as f:
            for raw in f:
                try:
                    j = json.loads(raw.decode("utf-8"))
                except ValueError:
                    continue
                op = j.get("op", "")
                if not (op.startswith(prefix) and op[len(prefix):].isdigit()):
                    continue
                ix = int(op[len(prefix):])
                if j.get("e") == "done":
                    done.add(ix)
                elif j.get("e") == "intent":
                    intent.add(ix)
        return done, intent

    def done_set(self):
        return self.journal_sets()[0]

    # ── 洞：pm 已把动作做完、Done 那一笔却被掉线吞掉（doctor C2 / Q-DONE-LOST，--repair 补记）──
    def verify_holes(self, done, intent):
        """对「有 Intent、无 Done」的 op 核盘面：拷贝目标 sha 相符 → C2 洞；
        victim 已不在原位且本计划 trash 里同 sha → Q-DONE-LOST 洞。结果缓存，每个 op 只核一次。"""
        for ix in sorted(intent - done):
            if ix in self.hole_checked or ix not in self.op_of:
                continue
            op = self.op_of[ix]
            verdict = None
            try:
                if op.get("t") == "copy":
                    dst = os.path.join(self.a.root, op["dst"])
                    if os.path.isfile(dst) and os.path.getsize(dst) == op["size"] and sha_of(dst) == op["sha256"]:
                        verdict = "C2 dst 完好、Done 丢失"
                elif op.get("t") == "quarantine":
                    victim = os.path.join(self.a.root, op["victim"])
                    trash = os.path.join(self.a.root, ".pm", "trash", self.a.plan, op["victim"])
                    if not os.path.exists(victim) and os.path.isfile(trash) and sha_of(trash) == op["sha256"]:
                        verdict = "Q-DONE-LOST 已入 trash、Done 丢失"
            except OSError as e:
                say(f"hole check #{ix} read error ({e}); will re-check next round")
                continue  # 不记入 hole_checked：盘可能正掉线，下一轮再核
            self.hole_checked.add(ix)
            if verdict:
                self.holes[ix] = verdict
                say(f"hole #{ix} verified on disk: {verdict} — skipped now, doctor --repair 补 Done at the end")

    def remaining(self, done):
        return [ix for ix in self.must if ix not in done and ix not in self.holes]

    def group_start(self, ix):
        g = self.group_of[ix]
        return min(i for i, gg in self.group_of.items() if gg == g)

    # ── 跑 pm ────────────────────────────────────────────────────────────
    def run_pm(self, args, header):
        with open(self.a.log, "ab") as lf:
            lf.write(f"\n===== {now()} {header}: pm {' '.join(args)}\n".encode("utf-8"))
            lf.flush()
            t0 = time.time()
            rc = subprocess.call([self.pm] + args, cwd=self.a.main, stdout=lf, stderr=subprocess.STDOUT)
            dt = time.time() - t0
            lf.write(f"===== {now()} exit={rc} after {dt:.0f}s\n".encode("utf-8"))
        return rc, dt

    def log_tail(self, nbytes=6000):
        try:
            with open(self.a.log, "rb") as f:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - nbytes))
                return f.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def group_end(self, ix):
        g = self.group_of[ix]
        return max(i for i, gg in self.group_of.items() if gg == g)

    def chunk_spec(self, first_rem):
        """从 first_rem 所在组的组首起，取 --chunk-groups 个组（按组闭包对齐），返回 (start, end)。"""
        start = self.group_start(first_rem)
        if self.a.chunk_groups <= 0:
            return start, self.max_ix
        groups_seen = []
        end = start
        for ix in sorted(self.group_of):
            if ix < start:
                continue
            g = self.group_of[ix]
            if g not in groups_seen:
                if len(groups_seen) >= self.a.chunk_groups:
                    break
                groups_seen.append(g)
            end = ix
        return start, self.group_end(end)

    def apply_loop(self):
        attempts = resumes = drops = lock_waits = 0
        while True:
            waited = self.wait_for_drive()
            done, intent = self.journal_sets()
            self.verify_holes(done, intent)
            rem = self.remaining(done)
            if not rem:
                say(f"ALL DONE: {len(done)} ops done + {len(self.holes)} verified holes, 0 remaining (attempts={attempts}, resumes={resumes}, drops={drops})")
                return attempts, drops
            if resumes >= self.a.max_resumes:
                say(f"GIVE UP: max resumes {self.a.max_resumes} reached; remaining {len(rem)}")
                sys.exit(4)
            start, end = self.chunk_spec(rem[0])
            spec = f"{start}-{end}"
            attempts += 1
            say(f"[attempt {attempts}] pm apply --only {spec}  (done {len(done)}/{len(self.must)}, remaining {len(rem)})")
            rc, dt = self.run_pm(["apply", self.a.plan, "--only", spec], f"attempt {attempts}")
            tail = self.log_tail()
            waited = self.wait_for_drive()
            done2, intent2 = self.journal_sets()
            self.verify_holes(done2, intent2)
            progress = len(done2) - len(done)
            chunk_done = not any(start <= ix <= end for ix in self.remaining(done2))
            say(f"[attempt {attempts}] rc={rc} {dt:.0f}s  done {len(done2)}/{len(self.must)} (+{progress}) holes={len(self.holes)} chunk_done={chunk_done}")
            if not self.remaining(done2):
                continue  # 顶部会打 ALL DONE
            if chunk_done and not waited:
                if self.a.pause > 0:
                    time.sleep(self.a.pause)  # 让盘把缓存刷完再压下一块
                continue
            if LOCK_SIGN in tail:
                lock_waits += 1
                if lock_waits > 40:
                    say("GIVE UP: root lock held for too long")
                    sys.exit(5)
                say("root lock held by another pm (doctor?) — waiting 30s")
                time.sleep(30)
                continue
            resumes += 1
            drop = waited or any(s in tail for s in DROP_SIGNS)
            if drop:
                drops += 1
                cool = min(15 * drops, 120)
                say(f"drive drop #{drops} detected (waited={waited}); cooling {cool}s then resuming (resume {resumes}/{self.a.max_resumes})")
                time.sleep(cool)
                continue
            if progress > 0:
                say("non-drop failure but progress made — retrying once more")
                time.sleep(10)
                continue
            say("STOP: no progress and no drop signature — needs a human. Log tail:")
            print(tail[-2500:])
            sys.exit(2)

    def finish(self, attempts, drops):
        # 先 doctor：有洞就带 --repair（C2 / Q-DONE-LOST 补记 Done，顺带清 pm 自建的孤儿 tmp），
        # 同时对每个 Done 目标与隔离件重读 sha——瞬断后的介质核验。
        if self.a.final_doctor or self.holes:
            args = ["doctor", "--backup"] + (["--repair"] if self.holes else [])
            for k in range(1, 4):
                self.wait_for_drive()
                rc, dt = self.run_pm(args, f"final doctor #{k}")
                tail = self.log_tail(8000)
                marks = [ln.strip() for ln in tail.splitlines() if ln.lstrip().startswith("·")]
                say(f"pm {' '.join(args)} #{k} rc={rc} {dt:.0f}s; finding lines: {len(marks)}")
                for ln in marks[-12:]:
                    print("    " + ln[:200])
                if rc == 0 or not any(s in tail for s in DROP_SIGNS):
                    break
                say("doctor hit a drop; retrying after the drive returns")
        # 最后 pm backup：重扫备份盘（崩溃那几轮没回写的 catalog 条目在这里重 hash）并比对
        for k in range(1, 3):
            self.wait_for_drive()
            rc, dt = self.run_pm(["backup"], f"final compare #{k}")
            tail = self.log_tail(4000)
            lines = [ln.strip() for ln in tail.splitlines() if "新增" in ln or "一致" in ln or "EXTRA" in ln or "未挂载" in ln]
            say(f"pm backup #{k} rc={rc} {dt:.0f}s: " + (" | ".join(lines[-3:]) if lines else "(no summary line)"))
            if rc == 0 or not any(s in tail for s in DROP_SIGNS):
                break
            say("pm backup hit a drop; retrying after the drive returns")
        say(f"WATCHDOG DONE attempts={attempts} drops={drops} holes={len(self.holes)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--root", required=True, help="备份盘 root（含 .pm）")
    ap.add_argument("--main", required=True, help="主库 root（pm 的工作目录）")
    ap.add_argument("--log", required=True, help="pm 全部输出追加到这里")
    ap.add_argument("--max-resumes", type=int, default=20)
    ap.add_argument("--drive-wait", type=int, default=1800, help="盘掉线后最多等多少秒（backup_verify.Drive）")
    ap.add_argument("--final-doctor", action="store_true")
    ap.add_argument("--chunk-groups", type=int, default=20, help="每次 --only 覆盖的复合组数（0 = 一次到底）")
    ap.add_argument("--pause", type=int, default=20, help="两块之间的停顿秒数（给盘刷缓存）")
    ap.add_argument("--check-only", action="store_true", help="只打印续跑起点，不跑 pm")
    a = ap.parse_args()
    if a.check_only:
        w = Watchdog(a)
        done, intent = w.journal_sets()
        w.verify_holes(done, intent)
        rem = w.remaining(done)
        say(f"done={len(done)} intent-without-done={sorted(intent - done)} holes={w.holes} remaining={len(rem)} first_remaining={rem[:3]} chunk={w.chunk_spec(rem[0]) if rem else None}")
        return
    w = Watchdog(a)
    attempts, drops = w.apply_loop()
    w.finish(attempts, drops)


if __name__ == "__main__":
    main()
