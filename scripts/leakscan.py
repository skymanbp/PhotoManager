# -*- coding: utf-8 -*-
"""发布二进制脱敏扫描：在 UTF-8 与 UTF-16LE 两种编码下找本机路径片段。

用法：python scripts/leakscan.py <file>...  [--extra PAT ...]
      环境变量 PM_LEAK_PATTERNS="a;b;c" 追加本地才知道的模式（如档案 vault 目录名，
      这些名字本身就不该进公开仓，所以不写在这里）。
任一命中 → 退出码 1；每文件打印每模式的 utf8/utf16 命中数。用法错（--extra 缺值或给空串、没给
文件）或有文件读不到（且无命中）→ 2——与命中 1、干净 0 分得开（审计 #21：此前 --extra 放在最后抛
未捕获的 StopIteration 退 1、与命中同码；没给文件答「干净」0；空串模式处处「命中」）。

模式全部在运行期从环境派生（用户目录名、%APPDATA%/%LOCALAPPDATA% 相对用户目录的
段、本仓库绝对路径及其父目录），文件里不出现任何本机字面量。

历史：0.6.0 发布链首次扫描抓出 pm.exe 含 6 处本仓库 .stack-work 安装目录
（Cabal 的 Paths_photo_manager 模块；此前只扫用户主目录模式故漏网）。
已登记假阳性（不再作为模式）：裸 "AppData"（warp 的 Types.AppData 构造子名）、
裸用户名（与公开的版权/标识名重叠）、裸「档案」（pm-ui.exe 内嵌中文词频表）。
"""
import os
import sys
from pathlib import Path


def both_slashes(p):
    p = str(p)
    return {p.replace("/", "\\"), p.replace("\\", "/")}


def derived_patterns():
    pats = set()
    env = os.environ
    home = env.get("USERPROFILE")
    if home:
        pats |= both_slashes(home)
        for var in ("LOCALAPPDATA", "APPDATA"):
            v = env.get(var)
            if v:
                try:
                    rel = Path(v).relative_to(home)
                    pats |= both_slashes(rel)
                except ValueError:
                    pats |= both_slashes(v)
    user = env.get("USERNAME") or (Path(home).name if home else None)
    if user:
        pats |= both_slashes(Path("Users") / user)
    repo = Path(__file__).resolve().parents[1]
    pats |= both_slashes(repo) | both_slashes(repo.parent)
    extra = env.get("PM_LEAK_PATTERNS", "")
    pats |= {p for p in extra.split(";") if p}
    return sorted(p for p in pats if len(p) >= 4)


def usage(why):
    line = next(l for l in __doc__.splitlines() if l.startswith("用法"))
    sys.stderr.write("leakscan: %s\n%s\n" % (why, line))
    return 2


def main(argv):
    files, extra = [], []
    it = iter(argv)
    for a in it:
        if a == "--extra":
            v = next(it, None)
            if not v:
                return usage("--extra 后面要跟一个非空模式")
            extra.append(v)
        else:
            files.append(a)
    if not files:
        return usage("没给要扫的文件")
    pats = derived_patterns() + extra
    bad = unreadable = 0
    out = sys.stdout.buffer
    for fp in files:
        try:
            with open(fp, "rb") as f:
                data = f.read()
        except OSError as ex:
            unreadable += 1
            out.write(("%s: 读不到 (%s)\n" % (fp, ex)).encode("utf-8", "replace"))
            continue
        rows = []
        for p in pats:
            n8 = data.count(p.encode("utf-8"))
            n16 = data.count(p.encode("utf-16-le"))
            if n8 or n16:
                rows.append("%s utf8=%d utf16=%d" % (p, n8, n16))
                bad += n8 + n16
        line = "%s (%d bytes): %s" % (fp, len(data), "; ".join(rows) if rows else "clean")
        out.write((line + "\n").encode("utf-8", "replace"))
    tail = " unreadable=%d" % unreadable if unreadable else ""
    out.write(("patterns=%d total hits=%d%s\n" % (len(pats), bad, tail)).encode("utf-8"))
    return 1 if bad else 2 if unreadable else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
