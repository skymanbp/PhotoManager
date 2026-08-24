# pm 评审记录（v0.1 → v0.2 → P3b）

> 从 `docs/DESIGN.md` §16 拆出（2026-08-24，DESIGN.md 触及 750 行预算）。本文件
> 是按时间的评审摘要索引；每轮评审的逐条处置表在 [`docs/reviews/`](reviews/)，
> 对应阶段的实现条目在 DESIGN.md §10.2。

2026-08-22 多智能体对抗评审（5 视角批判 + 逐条怀疑者反驳验证，19 agents）：
30 条发现 → **12 条确认**（3 critical 数据安全 + 2 critical Windows 工程 +
1 critical UX + 1 critical vault + 2 critical 性能 + 3 major）、**2 条被实测
反驳**（exFAT mtime 粒度链条：mtime 从不跨 root 比较、六态只认 filename+sha）、
16 条容量截断未验证（已由主线逐条裁决吸收）。全部确认项与裁决项已并入本版：
写协议（§6 全重写：moveFileEx flags=0、持久化屏障、三 Op 矩阵、supersede 复合、
tmp 移入 .pm/tmp、缓存级/介质级验证分层）、命令面（clean staging、apply/resolve、
ingest 拆步、status 新鲜度头行、报告规格 §5.1）、vault 对接（值形状兼容、
UNPUSHABLE、RENAME=BLOCKED、I11 gitignore）、依赖清单（Win32/file-io/JuicyPixels/
process + P0 冒烟）、性能表（介质分列 + 首备/import 行 + fsync/verify 分项）。
完整评审原文：`docs/reviews/2026-08-22-design-attack.md`。

2026-08-23 P2 实现独立评审（codex gpt-5.6-sol，对 commit b0a1363）：12 条发现
（5 critical / 6 major / 1 minor）逐条核实成立，verdict 不放行 → **P2.1 全部
修复**：Plan 携带 root UUID + 复合组（cx-1/2/4/5，§3/§5/§6.5）、clean 执行期
三副本重验 + trash empty 终极屏障（cx-3）、见证真实重 hash（mj-6）、目标键
case-fold + stem 组拒绝（mj-2/3）、Names 空地点/裸后缀拒绝（mj-1）、归档层限
Raw/成片（mj-5）、backup init 嵌套检查 case-fold（mj-4）、FFI 调用约定 CPP 宏
（mn-1）。评审归档：`docs/reviews/2026-08-23-p2-codex-review.md`。

同日 codex 二轮复审（对 5ce1ddb）：7 FIXED / 4 PARTIAL / 1 NOT-FIXED +
1 新 major → **P2.2 补齐**：返修 stem 组悬置（mj-3v2）、无 rootId 全路径
fail-closed（含 --apply 即时路径）、clean 即时路径同走执行期重验（cx-3
旁路封堵）、doctor/undo 复位配对改顺序感知 + trash empty 按 trashRel 去重
（新 major）、foldPath 补 normalise（mj-2）、backup init 改
canonicalizePath（mj-4）。

同日 codex 三轮聚焦复审（对 c663a48）→ **P2.3 收口**：execPlan 内核自卫
（有身份 root 拒无身份计划）、doctor 悬挂判定改末事件（重跑次序感知）、
stem 组键改规范化目标路径、bindExecRoot 身份优先（kind 无关）、backup
采纳前复验配置 UUID、init 写前重 canonicalize；对抗性 TOCTOU 类按 §14
威胁模型「缓解+记录+交用户裁定」处置。逐项处置表见评审归档三轮章节。

2026-08-24 P3a/P3b-1 实现独立评审（codex gpt-5.6-sol，对 018fb1c..676426c）：
verdict NO-GO，6 major 逐条对照源码核实**全部成立** → **P3b-4 全部修复**
（§10.2 P3b-4 条目：组回滚占位隔离、vaultIgnoreGuard、eePreflight 执行期
重检 I11、缓存身份绑定 + statHitStable racy 判据统一修、unstable 第八态
fail-closed、bindExecRoot 恰一命中）；新增 6 测试（128/128）。评审归档：
`docs/reviews/2026-08-24-p3b-codex-review.md`。

同日 codex 二轮复审（`codex exec` 只读直跑，对 676426c..d8e6d6d）：#5 FIXED、
其余 5 条 PARTIAL（各留一个可复现边界）+ names/versions 首评 3 major 1 minor
→ **P3b-5 收口**（§10.2 P3b-5 条目）：位移槽位序号 + doctor 核 sha + undo
剔除内部事务、守卫 canonical 路径 + case-fold 反规则、I11 下沉内核按 role
无条件重检、缓存身份双 Just、备份发现全命中、requireRole 统一、递归目录
指纹、names 文件占位预检；B4 经 I7 反驳不成立。新增 5 测试（133/133）。

同日 codex 三轮复审（`codex exec` 只读直跑；前三次运行模型侧无 exec 工具而
空跑，改重试循环按事件流 `command_execution` 计数判定，第 1 次重试即真跑：
132 次命令执行；对 d8e6d6d..e7288ae）：A4/A6/B2/B3 FIXED、B4 反驳被接受；
A1/A2/A3/B1 各留一个可复现绕过 + init 守卫缺失 major + junction 指纹 minor，
逐条核实全部成立（A2 另以 git 2.52 `check-ignore` 实证）→ **P3b-6 收口**
（§10.2 P3b-6 条目）：严格 opId/planId 解析、通配符反规则拒绝、匿名 root
与 role 改写封堵 + 取锁前预检、requireMain 四入口、init/backup init 守卫、
指纹不跟随 reparse point；Commands 拆出 Pm.BackupCmd。新增 11 测试（144/144）。

同日 codex 四轮复审（重试循环第 3 次真跑，204 次命令执行，对 e7288ae..a2efb3f）：
A2/A3/minor/拆分 FIXED；A1/B1/major 各留可复现边界 + 2 新 major（piIx 校验、I11
未覆盖 doctor --repair/undo/resolve/scan 写入口），逐条核实全部成立（悬空
junction 下 `doesPathExist=False` 实测）→ **P3b-7 收口**（§10.2 P3b-7 条目）：
规范十进制 + validatePlan、构造式隔离目录 + doctor 畸形 oid fail-closed、
RootIdState 三态 + 原子建标识、requireWritable 内嵌 I11 覆盖全部 .pm 写入口、
requireMain 补 afterApply/clean 复验/trash 屏障。新增 7 测试（151/151）。

同日 codex 五轮复审（重试循环第 1 次真跑，178 次命令执行，对 a2efb3f..fdcd5e3）：
major/新 major 2 FIXED；A1/B1/测试 PARTIAL + 1 新 major（路径型 pid 越出 root）+
2 新 minor（slot 探测异常、fixture 覆盖损坏标识），主体核实成立、两个子断言以
GHC 探针证伪（`isDigit` 只认 ASCII、`read::Int` 越界静默回绕）→ **P3b-8 收口**
（§10.2 P3b-8 条目）：opId 的 planId 须为生成格式、readDigits 有界、slotOccupied
全包 try、runClean/runImport/runTrash 身份校验先于读取判定、fixture 不覆盖损坏
标识。新增 4 测试（155/155）。

同日 codex 六轮复审（第 1 次即真跑，126 次命令执行，对 fdcd5e3..dfdf981）：
A1/B1/文档 FIXED；余 1 新 major——Doctor 直接拼接手编 journal 的 Op 路径字段，
合法 oid + `../../../x` 仍越出 root；统一排查同类还发现 Exec relOk 挡不住
`\evil`/`c:evil`（filepath 实测 `</>` 整体替换）与 manifest `trashRel` 被 trash
empty unlink → **P3b-9 收口**（§10.2 P3b-9 条目）：共用 `relPathOk`/`opPathsOk`
谓词进 validatePlan/execItem/Doctor（OP-PATH fail-closed）/readManifest，`.pm`
内部目标一律拒（undo 的 `.pm/trash/` rename 源除外）。新增 3 测试（158/158）。

同日 codex 七轮复审（中转站断粮 → 用户充值后守候脚本自动重跑，attempt 2 真跑
54 次命令执行，对 d8316fe）：1 FIXED / 8 PARTIAL / 1 NOT-FIXED + 4 新发现，核心
指控是**词法校验挡不住 Windows 规范化别名与 junction**。探针逐条核实：`.PM`
与 `.pm.`（尾随点被剥）确能读到 `.pm` 内文件，`.pm `/`.. `（尾随空格）证伪；
trash 内 junction 则**实测让 removeFile 删掉了库外文件**（数据丢失级）→
**P3b-10 收口**（§10.2 P3b-10 条目）：`normComp` 折大小写剥尾随点空格、
`Pm.Win.pathUnder` canonical 限域进 trash empty 与 Exec 三个落位点、
`listTrashFiles` 不递归 reparse point、`loadCatalog` 校验 `enPath`、
`reverseOp`/`pendingTmp` 补验。测试拆出 `PathGuardTests`，新增 4 例（162/162）。
