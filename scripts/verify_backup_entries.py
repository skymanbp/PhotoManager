"""verify_backup_entries.py — 按备份盘索引（.pm/catalog.json）把一组条目从盘上全文重读核 sha。只读；盘瞬断就等它回来接着读。
用法: python verify_backup_entries.py --root <备份盘 root> [--verified-on 2026-08-26] [--retry 上次结果.json] [--out 结果.json]
      公共选项（--drive-wait / --cooldown / --max-drops / --attempts / --max-mbps）见 backup_verify.add_common_args。
  --verified-on  只核 lastVerified 以该日期开头的条目（例如只在写入端算过 sha、从没回读过的那批）；不给则全部条目（= 手工 --deep 的范围）
"""
import argparse
import json
import os

import backup_verify as bv


def main():
    bv.stdout_utf8()
    ap = argparse.ArgumentParser()
    ap.add_argument("--verified-on", default=None)
    bv.add_common_args(ap)
    a = ap.parse_args()
    drive = bv.Drive(a.root, a.drive_wait, a.cooldown)
    drive.ensure()
    entries = json.load(open(os.path.join(a.root, ".pm", "catalog.json"), encoding="utf-8"))["entries"]
    if a.verified_on:
        entries = [e for e in entries if (e.get("lastVerified") or "").startswith(a.verified_on)]
    targets = [{"id": e["path"], "path": e["path"], "size": e["size"], "sha256": e["sha256"]} for e in entries]
    bv.finish(a, bv.run(a, drive, bv.apply_retry(a, targets), "entries"))


if __name__ == "__main__":
    main()
