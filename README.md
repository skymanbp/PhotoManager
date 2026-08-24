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

pm import                        # 暂存区 → Raw\年\事件-Raw + 成片\事件 归档计划
pm backup init E:\Photography    # 一次性：登记备份盘（按 UUID 认盘，不认盘符）
pm backup                        # 主库 → 备份盘单向增量（EXTRA 只报告永不动）
pm clean staging                 # 仅清理「归档层+备份盘」都有同 sha 副本的暂存文件
pm vault status                  # 相册 ↔ vault 展示集六态差异（--json 兼容 sync_photos.py）
pm vault push --category landscape A.jpg …   # NEW 定类目拷入 vault；DRIFT 出裁决计划；
                                 # 结束打印显式 git 步骤（pm 不执行 git）
pm names                         # Raw 事件夹统一 Scheme A 计划（B 类月份从成片还原；歧义不猜）
pm versions                      # 版本组 / 非设计内精确重复报告（只读）

pm apply <planId>                # 执行计划（--dry 全量预览 / --only 1,3-5 部分执行）
pm resolve <id> --item N --keep src|dst|both   # 冲突裁决（src=旧目标先隔离）
```

所有命令默认只读（生成计划、exit 1 表示有事可做）；写盘要么 `--apply` 交互
确认，要么两段式 `pm apply <planId>`。pm 没有删除原语——唯一的移出机制是带
manifest 的隔离区（`pm trash`）。

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
- P2 ✅ import / backup / clean staging（计划器纯函数 + 双 root fixture 端到端；
  真实归档待用户 `pm apply`，备份盘验收待插盘 `pm backup init`）
- P2.1 ✅ codex 评审 12 项修复（计划带 root UUID + supersede 复合组自动复位、
  clean 执行期三副本重验 + trash 屏障、目标键 case-fold、Names 边角；
  评审归档 docs/reviews/2026-08-23-p2-codex-review.md）
- P2.2 ✅ codex 二轮复审补齐（返修 stem 组悬置、无 rootId 全路径 fail-closed、
  clean --apply 同走执行期重验、复位配对顺序感知 + trash 去重）
- P2.3 ✅ codex 三轮收口（execPlan 内核自卫、doctor 悬挂判定末事件化、
  stem 组按目标路径、bindExecRoot 身份优先；TOCTOU 类按 DESIGN §14
  威胁模型处置，裁定权在用户）
- P3a ✅ `pm vault status`（六态 + UNPUSHABLE 第七态；真实库与 sync_photos.py
  集合逐项一致 78/15/1/0/0/0；行为基线 docs/specs/；vault 目录零写入）
- P3b-1 ✅ `pm vault push`（I11 文本级守卫 + DRIFT→resolve supersede 复用 +
  RENAME BLOCKED(photos.json) 实测命中 + doctor/trash/undo --vault；
  真实写入待 codex 评审 + 用户分类）
- P3b-2/3 ✅ `pm names`（真实库 42 夹：31 合规 + 6 项计划 + 3 拒猜 + 2 双月名
  报告；E2E undo 回滚有测试）+ `pm versions`（真实库定位 7 连号跨夹 ARW 重复
  与 相册 9275≡成片 9274 那 1 例外）—— 真实改名待用户 apply
- P3b-4 ✅ codex 评审 6 major 全修复（组回滚占位隔离 ~displaced、
  vaultIgnoreGuard 加固（.git 文件/祖先仓/反规则）、apply 执行锁内重检 I11、
  缓存绑定 root 身份 + racy-clean 判据统一、UNSTABLE 第八态 fail-closed、
  bindExecRoot 恰一命中；128/128 测试；归档 docs/reviews/2026-08-24-*）
- P3b-5 ✅ codex 二轮复审收口（位移槽位序号 + doctor 核 sha + undo 剔除内部
  事务、守卫 canonical 路径 + case-fold 反规则、I11 下沉 Pm.GitGuard 由内核按
  role 无条件重检、缓存身份双 Just、备份发现全命中、requireRole 统一、递归
  目录指纹、names 文件占位预检；133/133 测试）
- P3b-6 ✅ codex 三轮复审收口（严格 opId/planId 解析、通配符反规则 fail-closed
  （git 2.52 实测）、内核拒绝匿名 root + I11 守卫对所有 role 生效 + 取锁前预检、
  requireMain 补齐 vault/backup/pickRoot/init 四入口、init/backup init 走同一
  守卫、目录指纹不跟随 junction；备份命令拆出 Pm.BackupCmd；144/144 测试）
- P3b-7 ✅ codex 四轮复审收口（规范十进制 opId + validatePlan 序号校验、doctor
  畸形 oid fail-closed、悬空 junction 占槽判定、root-id 三态 + 原子 no-replace
  建标识、requireWritable 把 I11 覆盖到全部 .pm 写入口、requireMain 补 apply
  缓存/clean 复验/trash 屏障；151/151 测试）
- P3b-8 ✅ codex 五轮复审收口（opId 的 planId 须为生成格式——路径型 oid 不再
  越出 root、readDigits 有界、slotOccupied 探测异常按占用、clean/import/trash
  身份校验先于任何读取判定、测试 fixture 不覆盖损坏 root-id；155/155 测试）
- P4 GUI（C#，经 pm serve JSON API）
- P5 档案侧 skill/文档对接（含 sync_photos.py 退役指针改写）

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 skymanbp.

公开仓是脱敏快照（本机路径以 `<vault-root>` / `<stack-root>` 占位）；
设计文档中的库规模、事件夹名等来自作者真实照片库的实测记录。
