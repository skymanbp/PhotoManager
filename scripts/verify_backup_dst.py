"""verify_backup_dst.py — 备份计划落盘后的介质核验：对计划里每个 copy 的目标，从备份盘重读全文算 sha256，
与计划记录的 sha（= 主库 catalog 的 sha）和 size 比对；顺带查本计划 trash 里的隔离件是否在位。只读；盘瞬断就等它回来接着读。
用法: python verify_backup_dst.py --plan <id> --root <备份盘 root> [--out result.json] [--retry 上次结果.json] [--skip-trash]
      公共选项（--drive-wait / --cooldown / --max-drops / --attempts / --max-mbps）见 backup_verify.add_common_args。
--skip-trash：`pm trash --backup empty` 之后隔离件本来就该不在，跳过那一查。
退出码见 backup_verify（0 一致 / 1 有 bad / 3 盘没回来，结果照写 --out）。
"""
import argparse
import json
import os

import backup_verify as bv


def main():
    bv.stdout_utf8()
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--skip-trash", action="store_true")
    bv.add_common_args(ap)
    a = ap.parse_args()
    drive = bv.Drive(a.root, a.drive_wait, a.cooldown)
    drive.ensure()
    plan = json.load(open(os.path.join(a.root, ".pm", "plans", a.plan + ".json"), encoding="utf-8"))
    # 审计 #22：只核 Exec 真会执行的条目——`pm resolve` 跳过（skipped）与待裁决（needs-decision）的不执行，
    # 目标本来就不在，此前被报成 missing / sha 不符 / 隔离件缺，且每次 --retry 复发
    pend = [it for it in plan["items"] if it["status"]["s"] == "pending"]
    if len(pend) != len(plan["items"]):
        print(f"skip {len(plan['items']) - len(pend)} items not pending (skipped / needs-decision: never executed)")
    targets = [{"id": it["ix"], "path": it["op"]["dst"], "size": it["op"]["size"], "sha256": it["op"]["sha256"]}
               for it in pend if it["op"].get("t") == "copy"]
    res = bv.run(a, drive, bv.apply_retry(a, targets), "copies")
    if not a.skip_trash:
        # 隔离件只做存在性（rename 是元数据操作，不重读）：本计划 trash 目录下每个 victim 都应在。
        # 审计 #23：「不在」只在盘在时算（同 run() 的 missing 判据）——盘掉了（含 run() 等盘超时 / STOP 收尾之后）记「没核」，不报 0/N
        quars = [it for it in pend if it["op"].get("t") == "quarantine"]
        present = 0
        for it in quars:
            if os.path.isfile(os.path.join(a.root, ".pm", "trash", a.plan, it["op"]["victim"])):
                present += 1
            elif not drive.ok():
                present = None; break
        if present is None:
            print("TRASH victims not verified (drive absent)")
            res["bad"].append({"why": "trash victims not verified (drive absent)"})
        else:
            print(f"TRASH victims present {present}/{len(quars)}")
            if present != len(quars):
                res["bad"].append({"why": f"trash victims present {present}/{len(quars)}"})
    bv.finish(a, res)


if __name__ == "__main__":
    main()
