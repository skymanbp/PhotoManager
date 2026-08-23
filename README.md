# PhotoManager (`pm`)

Haskell 编写的照片库管理器：为 `D:\Photography` 三层照片库（Raw → 成片 → 相册）
提供带完整性校验的索引、归档、备份同步、命名治理与 vault 分发。

**设计与不变量：[docs/DESIGN.md](docs/DESIGN.md)**（先读 §2 十一条不变量）。
对抗评审记录：[docs/reviews/](docs/reviews/)。

## 使用

```
pm init --main D:\Photography    # 一次性：写配置 + root 标识
pm scan                          # 索引（首次全量 hash，之后增量）
pm                               # = pm status，总览仪表盘
```

所有命令默认只读；写盘需要 `--apply` 并逐计划确认。pm 没有删除原语——
唯一的移出机制是带 manifest 的隔离区（`pm trash`）。

## 构建

```
# --no-interleaved-output --dump-logs none 为必须：本机 ACP=CP936，stack 把
# 依赖包警告（含 •/» 字符）重编码回自己的 stderr 时会崩（GHC 9.10 二进制向
# 非 UTF-8 管道打印不可编码字符即 commitBuffer 崩溃，已实验证实；
# GHC_CHARENC 只影响 GHC 编译器自身，救不了 stack）。pm 自身在 main 首行
# 设 UTF-8（Pm.Win.setupConsole），无此问题。
stack build --test --no-interleaved-output --no-dump-logs   # GHC 9.10.3 / lts-24.46
stack install             # 把 pm 放进 %APPDATA%\local\bin
```

## 阶段

- P0 ✅ 脚手架 + init/scan/status（只读）
- P1 ✅ 安全内核（Exec/Journal/doctor/trash/undo/apply/resolve；矩阵逐行测试 + 双模故障注入）
- P2 import / backup / clean staging
- P3 vault status/push + names + versions
- P4 GUI（C#，经 pm serve JSON API）
- P5 档案侧 skill/文档对接
