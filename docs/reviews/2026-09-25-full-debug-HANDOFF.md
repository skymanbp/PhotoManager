# 2026-09-25 全量 debug — 交接文档

## 现状

- 代码：**零改动**。本次只做审计；分支 `claude/full-debug-o8absa` 与 main 在 e6f3ebb（1.2.0）之上只多了本次的文档、数据与工具提交。
- 报告：`docs/reviews/2026-09-25-full-debug-audit.md`（中文正文 + 英文附录，每条含验证者摘要与建议修复）。
- 机器可读清单：`docs/reviews/2026-09-25-full-debug-findings.json`——`confirmed`（59 条，按严重度排序，带 `id` 1–59，与报告编号一致）与 `refuted`（14 条，含证伪理由）。每条含 file/line/title/summary/failure_scenario/evidence/sources 与 `verdict{refuted, reasoning, severity, corrected_summary, suggested_fix, fix_risk}`。
- 结论：0 critical / 0 high / 12 medium / 47 low。安全写内核与 API 鉴权没有可成立的违规；问题集中在路径规范化缺口（junction / SUBST / 8.3）、二态探针的 fail-open 残留、GUI「未知塌成无」、doctor 矩阵与文档漂移、误导性报文与退出码。
- 未覆盖：5 个全库横切视角（异常处理、编码与时间、CLI 与文档漂移、安全、偏函数扫描）因会话额度耗尽未跑。

## 工具

- `tools/linux-typecheck/`：Linux 容器内的类型检查壳。`setup.sh`（装 GHC 9.10.3 + cabal，约 15 分钟）→ `check.sh`（编译库 / exe / 全部测试模块，`-Wall`）→ `run-tests.sh`（跑纯逻辑测试并与 `baseline-ok.txt` 的 132 例比对，回归即退出 1）。**它证明能编译、不证明能跑对**：Win32 / mklink / ACL 相关用例在 Linux 上必然失败。最终验收仍是 Windows 上的 `stack test`（CI 会跑）。
- `tools/audit/`：本次审计的 brief 与两个 Workflow 脚本，供重跑或补跑横切视角。

## 建议的修复顺序（报告 §5）

1. 极小 / 小且影响真实使用：#4 #5（配置与 root-id 路径规范化）、#10（Raw\ 杂文件使 sort 失败）、#2（GUI 空值写 0 关掉瞬断保护）、#7（弹「请插入磁盘」）、#11（判据③失效）、#9（apply 端点异常边界）、#39（悬空 Intent 补 JFailed）、#43（isTrashSrcRel 收紧）。
2. 需要小设计：#3（暂存区 case-fold 谓词统一）、#6 与 #34（二态探针改三态）、#8（reparse point 判定改 probeName，需同步改 caseScanDeniedProbe）。
3. 文档 / 测试对齐：#12 #13 #19 #36 #58 #59。

修复纪律（沿用项目惯例）：每条修复附测试或补哨兵；不改盘上格式（journal / plan / catalog / manifest）；不新增删除或覆盖原语；读路径「查不出」不得塌成「不存在」；改动 `.pm` 写入必须经既有可信口；文档同步改 DESIGN / DESIGN-COMMANDS / REVIEW-LOG；每个文件 ≤ 750 行（DocDriftTests 会红）。

## 下个 session 的开始提示词

把下面这段作为新 session 的第一条消息（按需改动分支名与范围）：

```
接手 PhotoManager 的全量 debug 修复。先读 docs/reviews/2026-09-25-full-debug-HANDOFF.md、
docs/reviews/2026-09-25-full-debug-audit.md 与 docs/reviews/2026-09-25-full-debug-findings.json
（confirmed 59 条，按 id 编号）。

环境：Linux 容器，无法运行 Windows 版；先执行 tools/linux-typecheck/setup.sh，再用
tools/linux-typecheck/check.sh 做编译验证、tools/linux-typecheck/run-tests.sh 做纯逻辑回归。
最终验收是 Windows 上的 stack test（CI），所以每条修复都要带可在 Windows 跑的测试或哨兵。

任务：按 HANDOFF「建议的修复顺序」逐条修复 medium 12 条与列出的 low 项，每条一个提交，
提交信息写「fix #<id>: <一句话>」并引用报告编号；修一条就 check.sh + run-tests.sh 一次，
红了先修红。遵守 HANDOFF 里的修复纪律。遇到需要设计取舍的（#3、#8、#36、#37）先给方案再动手。
控制 token：不要一次开多个 workflow；需要多 agent 时一次一个。全部做完后汇总每条的改动、
测试与未做项，等我指示再决定是否合并到 main 以及是否补跑 5 个未跑的横切视角
（tools/audit/ 里有脚本）。
```
