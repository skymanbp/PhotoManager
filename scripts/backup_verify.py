"""backup_verify.py — 两支备份盘核验脚本共用的内核（不单独运行；写入侧的等盘续跑自 pm 1.1.2 起内建于 Pm.Removable，
看门狗脚本已退役）：
  Drive        盘在不在（root-id.json 可读）、等它回来并冷却（与 pm 的判据相同）；
  sha_of       全文 sha256（可限速）；
  run/finish   把一组目标从备份盘全文重读核 sha，盘瞬断就等它回来、从被打断的那条接着读
               （verify_backup_dst.py 按计划目标、verify_backup_entries.py 按 catalog 条目）。
目标 = {"id": 可回查的键, "path": 盘上相对路径, "size": 期望字节数, "sha256": 期望 sha}；bad 记录 = {"id", "path", "why"}。
"""
import collections
import hashlib
import io
import json
import os
import sys
import time


def stdout_utf8():
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", line_buffering=True)


def ts():
    return time.strftime("%H:%M:%S")


class DriveGone(Exception):
    pass


class Drive:
    def __init__(self, root, wait_s, cooldown_s):
        self.rootid = os.path.join(root, ".pm", "root-id.json")
        self.wait_s, self.cooldown_s, self.waits = wait_s, cooldown_s, 0

    def ok(self):
        try:
            with open(self.rootid, "rb") as f:
                return len(f.read()) > 0
        except OSError:
            return False

    def ensure(self):
        """盘在就立刻返回 False；不在就等到它回来（每 5 s 探一次，超过 wait_s 退出码 3）、冷却 cooldown_s 后返回 True。"""
        if self.ok():
            return False
        t0 = time.time()
        print(f"{ts()} drive NOT readable ({self.rootid}); waiting up to {self.wait_s}s ...")
        while not self.ok():
            if time.time() - t0 > self.wait_s:
                print(f"{ts()} GIVE UP: drive did not come back within {self.wait_s}s"); sys.exit(3)
            time.sleep(5)
        self.waits += 1
        print(f"{ts()} drive back after {time.time() - t0:.0f}s; cooling {self.cooldown_s}s")
        time.sleep(self.cooldown_s)
        return True


def make_limiter(max_mbps):
    if not max_mbps:
        return lambda n: None
    state = {"t0": time.time(), "bytes": 0}

    def limit(n):
        state["bytes"] += n
        ahead = state["bytes"] / (max_mbps * 2**20) - (time.time() - state["t0"])
        if ahead > 0:
            time.sleep(ahead)
    return limit


def sha_of(path, limiter=lambda n: None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b); limiter(len(b))
    return h.hexdigest()


def add_common_args(ap):
    ap.add_argument("--root", required=True, help="备份盘 root（含 .pm 的那层）")
    ap.add_argument("--out", default=None, help="结果 json")
    ap.add_argument("--retry", default=None, help="上一次的 --out 结果；只重读其中 bad 列表里的目标")
    ap.add_argument("--drive-wait", type=int, default=1800, help="盘掉线后最多等多少秒")
    ap.add_argument("--cooldown", type=int, default=30, help="盘回来后先歇多少秒再读")
    ap.add_argument("--max-drops", type=int, default=40, help="总掉线次数上限，超过就停、未读的记进 bad 供 --retry")
    ap.add_argument("--attempts", type=int, default=5, help="同一目标被掉线打断几次后放弃")
    ap.add_argument("--max-mbps", type=float, default=0, help="读速上限（0 = 不限）；有的 USB 盘全速读比慢读更容易掉线，这是实验旋钮")


def apply_retry(a, targets):
    if not a.retry:
        return targets
    prev = json.load(open(a.retry, encoding="utf-8"))
    ids = {str(b["id"]) for b in prev["bad"] if "id" in b}
    kept = [t for t in targets if str(t["id"]) in ids]
    print(f"retry mode: {len(kept)} targets from {a.retry}")
    return kept


def run(a, drive, targets, label):
    """逐个重读；返回 {label: n, ok, sha_bad, size_bad, missing, read_err, drops, bytes, seconds, bad}。"""
    print(f"{label} to verify: {len(targets)}  bytes={sum(t['size'] for t in targets) / 2**30:.2f} GiB")
    limiter = make_limiter(a.max_mbps)
    ok = sha_bad = size_bad = missing = err = drops = hiccups = n = total = 0
    bad, attempts, queue, t0 = [], collections.Counter(), collections.deque(targets), time.time()
    while queue:
        t = queue.popleft()
        p = os.path.join(a.root, t["path"])
        try:
            if not os.path.isfile(p):
                if not drive.ok():
                    raise DriveGone("file vanished with the drive")
                missing += 1; bad.append({"id": t["id"], "path": t["path"], "why": "missing"}); n += 1; continue
            sz = os.path.getsize(p)
            if sz != t["size"]:
                size_bad += 1; bad.append({"id": t["id"], "path": t["path"], "why": f"size {sz} != {t['size']}"}); n += 1; continue
            s = sha_of(p, limiter)
        except (DriveGone, OSError) as ex:
            # 任何读错先当瞬断处理（2026-09-02 实录：13:50 盘掉线后 2 s 内已重挂，root-id.json 又读得到，
            # 只看「盘在不在」会把它误记成介质读错）：重排队、冷却、再试，attempts 次都不行才记 read error。
            time.sleep(2)
            absent = not drive.ok()
            attempts[t["path"]] += 1
            if absent:
                drops += 1
            else:
                hiccups += 1
            print(f"{ts()} {'drop' if absent else 'read hiccup'} #{drops + hiccups} while reading {t['path']} ({ex}); attempt {attempts[t['path']]}/{a.attempts}")
            if drops > a.max_drops:
                print(f"{ts()} STOP: more than {a.max_drops} drops; remaining targets go to bad for --retry")
                queue.appendleft(t)
                bad.extend({"id": q["id"], "path": q["path"], "why": "not verified (stopped)"} for q in queue); queue.clear(); break
            if attempts[t["path"]] >= a.attempts:
                err += 1; bad.append({"id": t["id"], "path": t["path"], "why": f"read error {a.attempts}x: {ex}"}); n += 1
            else:
                queue.appendleft(t)
            if absent:
                drive.ensure()
            else:
                time.sleep(a.cooldown)
            continue
        total += sz; n += 1
        if s != t["sha256"]:
            sha_bad += 1; bad.append({"id": t["id"], "path": t["path"], "why": f"sha {s[:12]} != {t['sha256'][:12]}"})
        else:
            ok += 1
        if n % 50 == 0:
            print(f"{ts()} {n}/{len(targets)} ok={ok} bad={len(bad)} drops={drops} {total / 2**30:.1f} GiB {time.time() - t0:.0f}s")
    dt = time.time() - t0
    print(f"RESULT {label}={len(targets)} ok={ok} sha_bad={sha_bad} size_bad={size_bad} missing={missing} read_err={err} "
          f"drops={drops} hiccups={hiccups} bytes={total / 2**30:.2f} GiB in {dt:.0f}s ({total / max(dt, 1) / 2**20:.0f} MB/s)")
    return {label: len(targets), "ok": ok, "sha_bad": sha_bad, "size_bad": size_bad, "missing": missing,
            "read_err": err, "drops": drops, "hiccups": hiccups, "bytes": total, "seconds": dt, "bad": bad}


def finish(a, res):
    for b in res["bad"][:30]:
        print("  BAD", b)
    if a.out:
        json.dump(res, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    sys.exit(0 if not res["bad"] else 1)
