# P3a/P3b-1 codex 独立评审（2026-08-24）

- 评审者：codex `gpt-5.6-sol`（中转站后台任务 task-mt6jl8qx-mhq6bn）
- 范围：commit `018fb1c..676426c`（P3a `pm vault status` + P3b-1 `pm vault push`）
- verdict：**NO-GO**，6 major，0 minor
- 处置：主线逐条对照源码对抗核实，**6/6 成立**，同轮全部修复（P3b-4，
  128/128 测试）。62d5a4a（names/versions）不在本轮评审范围，另行补送。

## 逐条发现与处置

### #1 major｜supersede 组失败回滚可能无法复位 —— 成立，已修复

- 位置：`src/Pm/Exec.hs`（execCopy 落位后复核 / restoreQuarantine）。
- 攻击场景：DRIFT→`resolve --keep src` 后 victim 先进 trash；Copy 落位窗口
  内第三方抢占目标（或落位后复核失败留下残留文件）→ 组回滚把 victim 从
  trash rename 回原位时目标已存在，I5 拒绝 → victim 留在 trash、坏字节留在
  vault，自动复位失败。另外落位后复核的 `statSnap/sha256File` 抛异常会逃逸
  出 execCopy，整批像崩溃一样中止，组回滚完全不跑。
- 修复：
  - `restoreQuarantine` 复位前检测目标被占：占位者（文件）先 journaled
    隔离到 `<planId>~displaced/<victim>`（opId 带 `~d` 后缀；不删除，I2），
    再复位 victim；占位者是目录或读取失败 → 保守失败（旧字节仍在 trash，
    注记指路）。
  - trash 路径推导下沉为 `Pm.Trash.quarTrashRel`（oid → 目录），Exec 与
    doctor（classifyPending / applyRepairs 补记 Done）共用——两侧各推各的
    正是本条能存在的结构性原因。
  - execCopy 落位后复核包进 `try`，异常 → journal `JFailed` + `OFailed`
    （组回滚照常运行）。
  - 故障注入测试：KernelTests「P3b-4 #1」用 `CpCopyAfterFlush` 检查点注入
    第三方抢占 → 断言 victim 复位回原位、占位者进 `~displaced/`、doctor
    对账无 Bad。落位后复核**异常**路径（statSnap 抛）未做注入（Windows 上
    可靠制造 stat 异常需 ACL 翻转，脆弱）；该路径由 try 类型层面保证进入
    OFailed 分支，记录为未注入覆盖项。
- 归属：内核缺口早于本范围存在（P2 备份 supersede 同型），但 vault DRIFT
  首次高概率触发；修复对备份路径同样生效（统一修）。

### #2 major｜I11 守卫可被 .git 文件、祖先仓库、ignore 反规则绕过 —— 成立，已修复

- 位置：`src/Pm/Vault.hs` ensureVaultRoot。
- 三个绕过面逐一核实：`doesDirectoryExist .git` 漏 worktree/submodule 的
  普通 `.git` 文件；vault 为仓库子目录时祖先 `.git` 不检查；`.pm/` 行成员
  测试放过后续 `!.pm/` 反规则。
- 修复：抽出可重入的 `vaultIgnoreGuard`——`.git` 目录**或文件**都算 git
  语境；自身无 .git 但祖先有 → 一律拒绝（pm 不实现完整 gitignore 语义，
  fail-closed；真实 vault 摄影作品是嵌套独立仓根，不受影响）；`.gitignore`
  须恰含 `.pm/` 行且**无任何含 `.pm` 的 `!` 行**。测试：VaultTests
  「P3b-4 #2」四分支（.git 文件 / 反规则 / 祖先仓 / 合规放行）。

### #3 major｜pm apply 不重检 I11 —— 成立，已修复

- 位置：`src/Pm/Commands.hs` runApply → `src/Pm/Cli.hs` executePlanNow'。
- 场景：ignore 行在计划生成与 apply 之间被移除，executePlanNow 直接建
  journal/tmp/trash 污染 git 工作树。
- 修复：ExecEnv 新增 `eePreflight :: FilePath -> IO (Either String ())`
  钩子，在**锁内、身份复验后、withJournal 之前**运行（codex 建议的位置）；
  Cli 注入 `rootPreflight`：root role 为 RoleVault → 重跑 `vaultIgnoreGuard`，
  失败整批拒绝。`--apply` 即时路径与 `pm apply` 同走 executePlanNow，无旁路。
  测试：「P3b-4 #3」——计划生成后删 ignore 行 → exit 2 且 vault `.pm/` 下
  无 journal.ndjson、无落位文件。

### #4 major｜stat-only 缓存可复用错误 SHA —— 成立，已修复（统一修）

- 位置：`src/Pm/Vault.hs` shaViaCache + 缓存 meta；同型命中
  `src/Pm/Scan.hs` scanRoot 的 (size,mtime) 复用（评审未点名，主线按
  unified-fix 规则扩到同类）。
- 两个子问题：
  - 身份：缓存键是类目相对路径，vault 换路径/换 root 后 (size,mtime) 巧合
    → 复用错误 sha。修复：`VaultCacheMeta` 增 `vmVaultPath`（规范路径）+
    `vmRootId`，读取时不符整体弃用（旧格式 meta 缺字段 → 解析失败 → 同
    弃用，自动迁移）。展示/JSON 仍用配置原样路径（legacy 兼容面不变）。
  - racy-clean：同一 mtime 刻度内先 hash 后改写 → (size,mtime) 不变而内容
    已变，永久信任陈旧 sha。修复：`Pm.Hash.statHitStable` 统一判据——命中
    还须 `lastVerified − mtime > 2 s`（FAT/exFAT 最粗粒度余量；git 同型
    方案）；scanRoot 复用与 shaViaCache 共用。代价：仅「hash 后 2 s 内又被
    改写」的文件多一次重 hash，稳定库为零。
- 测试：「P3b-4 #4」两例——vault A→B 换路径 + 回溯 mtime 制造 (size,mtime)
  巧合，断言不复用（旧代码此例必失败）；statHitStable 纯判据四分支。

### #5 major｜持续变化的 vault 文件仍进入 diff —— 成立，已修复

- 位置：`src/Pm/Vault.hs` computeVault（vaultShas 丢弃 Maybe）。
- 修复：任一侧三轮双 stat 仍不稳的名字**整体**退出六态分类（只排一侧会让
  另一侧伪报 NEW/MISSING），单列为 `vrUnstable`；JSON 尾键 `unstable`
  （第八态，legacy 六键集合不受影响）；退出码**算差异**（状态未知不能报
  已同步）；push 对 unstable 名 fail-closed 拒收。顺带修复评审未点名的
  次生缺陷：shaViaCache 原来无条件 `putStrLn` 告警会污染 `--json` 纯净
  输出——告警移到调用方按 quiet 抑制。规范登记：
  `docs/specs/sync-photos-legacy-spec.md` §6 修复项 9。
- 测试：不稳定本身无法确定性制造（需与 hash 竞态），排除语义由
  computeVault 的列表推导直接表达；第八态 JSON 形状/键序由
  caseJsonShape/caseJsonKeyOrder 覆盖（`unstable` 殿后）。记录为
  弱覆盖项，复审可挑战。

### #6 major｜UUID 碰撞时 bindExecRoot 按优先级绑定 —— 成立，已修复

- 位置：`src/Pm/Cli.hs` bindExecRoot。
- 修复：主库/vault/备份三槽位**全部**探查；候选 = UUID 命中 **且 role 与
  槽位相符**（vault 槽指向 RoleBackup root 不再被接受）；规范化路径去重后
  必须**恰好一个**命中，多命中 → 报「root 身份冲突」拒绝执行。代价：每次
  apply 都跑一次备份盘发现（未登记时 O(1) 短路，已登记时按盘符探 root-id，
  毫秒级）。
- 测试：「P3b-4 #6」——同 UUID 写进主库+vault → 拒绝；vault 槽 role 不符 →
  零候选拒绝。既有 P2.2 bindExecRoot 用例与 caseBindVaultRoot 语义不变。

## 评审「未发现问题」清单（复核通过，未改动）

NEW 路径参数越界防线（Vault 选择校验 + Exec relOk）；supersede 组构造与
I5 不覆盖；gitStepsLines 纯字符串（pm 零 git 执行）;六态算法/键序/退出码
与 legacy 规范无回归；缓存损坏按缺失重算。

## 后续

- 62d5a4a（P3b-2/3 names/versions）+ 本轮修复 commit 补送 codex 复审。
- 真实写入（vault push 分类 / names apply / versions 处置）仍等复审 +
  用户 AskUserQuestion 裁定，纪律不变。

---

# 二轮复审（2026-08-24，`codex exec -s read-only` 直跑，对 676426c..d8e6d6d）

- verdict：**NO-GO**——A 部分 #5 FIXED，#1/#2/#3/#4/#6 PARTIAL；B 部分
  （62d5a4a names/versions）3 major + 1 minor。
- 处置：PARTIAL 五条与 B1/B2/B3 逐条核实成立，同轮修复（P3b-5，133/133）；
  B4 经源码 + 不变量 I7 反驳，不改。
- 桥接插件的首次派发（task-mt6limry-ngckbn）29 秒空跑（线程自述无工具），
  改用 `codex exec` 直跑取得本结论；桥接层前后台配置相同，属线程侧偶发。

## A 部分逐条

| # | 复审判定 | 残留边界（codex） | P3b-5 处置 |
|---|---|---|---|
| 1 | PARTIAL | 重跑再位移复用同一 `~displaced` 路径 → move 失败 → 复位被挡；doctor Q-DONE-LOST 不核 sha 就补 Done；undo 会把 `~d` 当可撤销 | `~d<N>` 尝试序号 → `<pid>~displaced-<N>/`（`quarTrashRel` 解析）；占位者未挪开不试 `~r`；doctor 核 sha 不符 → Bad 不修；`cancelRestores` 剔除所有 `~d`。测试：同计划两轮位移用槽位 1/2、undo 为空、doctor sha 不符 Bad |
| 2 | PARTIAL | junction/symlink 别名路径走词法父链看不到真实祖先 `.git`；`!.PM/` 反规则未检 | 守卫入口 `canonicalizePath`；反规则 `T.toLower` 后判 `.pm`。测试：`!.PM/` 拒绝。junction 场景未自动化（Windows 建 junction 需 `mklink /J` 进程调用，测试依赖不含 process；逻辑为一行 canonicalize，记录为未注入项） |
| 3 | PARTIAL | `execPlan defaultExecEnv` 绕过可覆盖的 `eePreflight` 钩子 | 守卫下沉 `Pm.GitGuard`；Exec 在锁内按盘上 role **无条件**调用，钩子删除；Cli 的 rootPreflight 删除。测试：RoleVault root + 无 ignore → `execPlan defaultExecEnv` 拒绝且 journal 未创建 |
| 4 | PARTIAL | `Nothing == Nothing` 让未建 root 的 vault 缓存通过；路径无条件 case-fold | 双方 root-id 皆 `Just` 且相等才复用；路径取 canonicalizePath 精确值比较。代价：vault root 建立前每次全量重 hash（真实库 79 张，秒级） |
| 5 | FIXED | — | — |
| 6 | PARTIAL | 备份发现只返回首命中，克隆盘歧义不可见；nubBy 小写去重的 FS 语义假设 | `discoverBackupRoots` 返回全部命中（`discoverAmong` 可注入候选、有测试），`discoverBackupRoot` 多命中即 Left；bindExecRoot 备份槽取全部命中，候选按 `canonicalizePath` 去重 |

## B 部分（62d5a4a）

- **B1 major｜runNames 不校验 RoleMain —— 成立，已修（统一修）**：新增
  `Pm.Config.requireRole`，names/import/clean/scan 四处以主库身份出计划或写
  索引前都校验 role；测试：backup root 伪装主库 → runNames exit 2、runPlan
  未调用。
- **B2 major｜FpDir 只看直接子项名字+大小 —— 成立，部分采纳**：改为递归树
  指纹（类型/相对路径/大小/mtimeNs；目录改名不变）。**未采纳内容 hash**：
  Rename 不触碰内容且 undo 可逆；Raw 事件夹数十 GB，计划期+执行期两次全量
  hash 的代价与收益不成比例；§14 单机威胁模型下作为残余风险登记（需同时
  伪造整棵树的名字、大小与 mtime）。若用户要求内容级 Merkle，可作为 names
  的可选开关后续增量。测试：子目录文件变化改变指纹、目录改名不变。
- **B3 minor｜目标预检只查目录 —— 成立，已修**：文件或目录皆算占用 →
  NEEDS-DECISION。测试：目标为普通文件时不出计划。
- **B4 major｜designedPair 排除过宽 —— 不成立（反驳）**：`designedPair`
  只豁免**恰两份**、一在 `成片` 一在 `相册`、同 case-fold 文件名的组（三份
  以上照报，`versionsReport` :129-134）；相册 ⊆ 成片 ∪ inbox-origin 是不变量
  I7 的设计拓扑，相册没有「所属事件」，「无关事件的成片副本」在设计里不是
  一个可定义的概念；来源映射（journal 登记）是 P5 ingest 的工作。保持现状。

## 残余与未自动化项（复审可再挑战）

- 位移隔离槽位封顶 99（超出即保守失败，victim 仍在 trash）。
- junction 别名 vault 路径的守卫行为未自动化测试。
- 目录指纹不含内容 hash（见 B2）。
- 落位后复核异常路径仍未做故障注入（同首轮记录）。

---

# 三轮复审（2026-08-24，`codex exec -s read-only` 直跑，对 d8e6d6d..e7288ae）

- 取结果：直跑三次（review3/3b/3c）模型自述只有等待/协作类工具、无 `exec`，
  零命令执行空跑；改为重试循环（读事件流 `command_execution` 计数，命中即
  取结果），第 1 次重试即真跑：132 次命令执行、约 13 分钟。原文存 scratchpad
  `review3-final.md`（不入仓）。
- verdict：**NO-GO**——A4/A6/B2/B3 FIXED，B4 反驳被接受；A1/A2/A3/B1 PARTIAL
  + 1 major + 1 minor。逐条对照源码核实**全部成立**（A2 另以 git 2.52
  `check-ignore` 实证），同轮修复（P3b-6，144/144，零 GHC 警告）。

## 逐条

| # | 复审判定 | 残留（codex） | 核实 | P3b-6 处置 |
|---|---|---|---|---|
| A1 | PARTIAL | 空槽只查 `doesFileExist`（目录/失效 reparse point 占槽 → 反复选槽 1、move 必败）；`Plan` 反序列化不校验 id，`plId="job~d7"` 时 Trash `splitOn "~d"` 与 Undo `isInfixOf "~d"` 互相错判 | 成立（Exec.hs:276 / Plan.hs:98 / Trash.hs:82 / Undo.hs:73 原文如此） | `Pm.Op.opIdParts` 严格解析 `<pid>#<ix>[~r|~d<N>]`（Trash/Undo/Doctor 共用）；`isValidPlanId` 在 loadPlan（含文件内 id≠文件名、格式不合不触盘）与 execPlan 双重把关；空槽改 `doesPathExist`。测试：解析矩阵、`job~d7` 执行/装载拒绝、目录占槽 1 → 用槽 2 |
| A2 | PARTIAL | 反规则只拒含 `.pm` 字面的 `!` 行；`!.[p]m/` + `!.[p]m/**` 可重新包含 | 成立——scratch 仓 git 2.52.0.windows.1 `check-ignore -q .pm/probe`：`!.[p]m/**`、`!.p\m/**`、`!.?m/**`、`!.*/**` 四种皆 exit 1 且 `git status` 列出 `?? .pm/probe`；字面 `!README.md` 仍 ignored | `!` 行含 `.pm`（case-fold）或任一 `* ? [ \` 即拒绝（pm 不实现 wildmatch，fail-closed）。真实 vault `.gitignore` 无 `!` 行，不受影响。测试：四种通配 + `!.PM` 拒绝、字面无关反规则放行 |
| A3 | PARTIAL | marker role 改成 RoleMain 跳过守卫；删 marker 后 `execPlan defaultExecEnv` 走「裸目录」放行 | 成立（Exec.hs:143/157 原文如此） | 内核拒绝一切无身份 root（fixture 改 `ensureTestRoot` 先写标识）；`pmIgnoreGuard role` 对所有 role 无条件执行；另加**取锁前**零写入预检——`withRootLock` 会先建 `.pm/lock`，git 树污染不该始于锁文件。测试：匿名 root 拒绝且 `.pm/` 不存在；RoleMain marker + git 树无 ignore → I11 |
| A4 | FIXED | — | — | — |
| A6 | FIXED | — | — | — |
| B1 | PARTIAL | `runInit --force` 沿用任意 role marker；`computeVault` 以 cfgMainPath 为相册源并写 vault-cache；`runBackupRun` 以之为备份源；`pickRoot SelMain` 不校验 role | 成立（Commands.hs:109/159/598、Vault.hs:297 原文如此） | `Pm.Config.requireMain` 收口四入口；`initPreflight` 遇非 RoleMain 标识拒绝（`--force` 不改写身份）。测试：pickRoot 备份 root → exit 2；computeVault 无标识/备份 role → 2、主库 → 0；initPreflight 备份 root 拒绝。`pm backup` 分支依赖盘符发现，未加自动化（同一行 `requireMain` 调用） |
| B2 | FIXED | — | — | — |
| B3 | FIXED | — | — | — |
| B4 | 反驳被接受 | — | — | — |
| major | — | `pm init --main` 无 I11 守卫；`backup init` 只查本目录 `.git` 目录（漏 `.git` 文件与祖先仓） | 成立（Commands.hs:128/553 原文如此） | `initPreflight` / `backupInitPreflight` 走同一 `pmIgnoreGuard`，在写配置/标识之前。测试：git 树无 ignore 拒绝；`.git` 文件拒绝；与主库嵌套拒绝；合规放行 |
| minor | — | `dirFingerprint` 跟随 junction，指回祖先无限递归；reparse 目录记成普通 `d` | 成立（`doesDirectoryExist` 对 junction 返回 True，directory-1.3.8.5） | `pathIsSymbolicLink` 命中记 `l` 条目不跟随（与 Scan.listTree 同策略）。测试：`mklink /J ev\loop → ev` 后指纹终止、确定、去链接后复原。真实库无 reparse point，既有 names 计划指纹不变（重生成逐项比对） |

## 附带

- `Pm.Commands` 触及 750 行文件预算 → 备份命令（`BackupCmd` / `runBackupInit` /
  `backupInitPreflight` / `runBackupRun`）拆到 `Pm.BackupCmd`，Commands 再导出，
  Main 不动。
- 三轮均未采纳「目录指纹加内容 hash」——用户裁定保持 stat 级递归（2026-08-24）。

## 残余与未自动化项

- `pm backup` 的 requireMain 分支无自动化测试（需盘符发现 fixture）。
- 位移槽位封顶 99；落位后复核异常路径未做故障注入（沿前两轮记录）。
- junction 别名 vault 路径的守卫行为（`canonicalizePath` 一行）仍未自动化。

---

# 四轮复审（2026-08-24，`codex exec -s read-only` 直跑，对 e7288ae..a2efb3f）

- 取结果：重试循环前两次空跑（零命令执行），第 3 次真跑：204 次命令执行。
- verdict：**NO-GO**——A2/A3/minor/拆分 FIXED；A1/B1/major PARTIAL + 2 新 major。
  逐条对照源码核实**全部成立**（A1 悬空链接一项另以 directory-1.3.8.5 实测：
  悬空 junction `doesPathExist=False`、`pathIsSymbolicLink=True`），同轮修复
  （P3b-7，151/151，零 GHC 警告）。

## 逐条

| # | 复审判定 | 残留（codex） | 核实 | P3b-7 处置 |
|---|---|---|---|---|
| A1 | PARTIAL | `readDigits` 收前导零（`p#00`→ix 0，`p#0~d01`→`~d1`），手编 `p#00~r` 可抵消真实 Done；`piIx` 未验非负唯一；Doctor 仍 `oid <> "~r"` 拼接、`quarTrashRel` 解析失败回退 `#` 前缀 → 畸形 quarantine 可被判 Q-DONE-LOST 并 `--repair` 补 Done；`doesPathExist` 跟随链接，悬空 junction 占槽答 False | 成立（Op.hs:106 / Plan.hs:56 / Doctor.hs:106 / Trash.hs:84 / Exec.hs:299 原文如此；悬空链接实测） | `readDigits` 要求 `show n == t`；`validatePlan`（id + piIx）在 loadPlan/execPlan 共用；隔离目录改构造式 `quarDirFor`（Exec），`quarTrashRel` 返回 Maybe，Doctor 畸形 oid → `OID-MALFORMED` Bad 且 repairDone 过滤、复位配对走 opIdParts；`slotOccupied` = doesPathExist ∨ pathIsSymbolicLink（探测异常按占用）。测试：前导零矩阵、负/重复 piIx 执行与装载拒绝、畸形 oid doctor 不补 Done、悬空 junction 占槽跳槽 2 |
| A2 | FIXED | — | — | — |
| A3 | FIXED | — | — | — |
| B1 | PARTIAL | apply 备份计划后无条件用 cfgMainPath 刷新 backup-cache；clean 执行期复验与 trash empty 用未经 requireMain 的主库见证——主路径与备份盘同为 RoleBackup 时同一文件充当两份见证 | 成立（Commands.hs runApply/runTrash、Cli.hs recheckCleanPlan、Clean.hs:124-131 原文如此） | `afterApply`（可测）先 requireMain 否则跳过缓存写；`recheckCleanPlan` 与 runTrash clean 分支先 requireMain，失败全部降级/HELD。测试：主路径为 RoleBackup → 不写 backup-cache、全项 NEEDS-DECISION、trash empty HELD 且文件仍在 |
| major | PARTIAL | `readRootInfo` 把损坏 JSON 当缺席；init/backup init/vault push 随后**覆盖写**新 UUID/role——半写坏的 RoleBackup marker 可被 `init --force` 改成 RoleMain | 成立（Config.hs:119-127、writeRootInfo 覆盖写） | `RootIdState = Absent/Corrupt/Present`，`readRootState` 三态；三处建标识入口 Corrupt 一律拒绝；`createRootInfo` 原子 no-replace（tmp → moveFileNoReplace，失败删自建 tmp）；`writeRootInfo` 仅供测试覆盖。测试：损坏标识 → initPreflight/ensureVaultRoot/requireWritable 拒绝、createRootInfo 不覆盖、二次创建拒绝 |
| minor | FIXED | — | — | — |
| 拆分 | FIXED | — | — | — |
| 新 major 1 | — | 合法 planId + 负数/重复 piIx → 畸形/碰撞 oid，Undo 折叠 | 成立 | 并入 A1 的 `validatePlan` |
| 新 major 2 | — | I11 只在 Exec 与建 root 时检查；`doctor --repair`、undo、resolve、scan/side-cache 经 role-only pickRoot 直接写 `.pm` | 成立（Main.hs CmdDoctor → pickRoot 无守卫；savePlan 无守卫） | `requireWritable`（身份可解析 + 按盘上 role 的 pmIgnoreGuard）内嵌进 `requireRole`/`requireMain`；pickRoot 三槽位、`savePlanAndMaybeRunWith`、`runDoctor` 的 repair 分支（不可写 → `I11` Bad 只报不修）、`runResolve`（先 bindExecRoot 再 requireWritable）、`runBackupRun'` 的备份 root 全部过守卫。测试：vault 缺 ignore → doctor --repair 不补 Done、计划不落盘、pickRoot --vault 与 requireRole 拒绝 |

## 附带

- 前四轮共同证实：codex 对 pm 的 fail-closed 语义理解准确，四轮 8 条（含 2 新
  发现）无一误报。
- `apply` 的备份缓存分支因需盘符发现 fixture，用抽出的 `afterApply` 直接测试。

## 残余与未自动化项

- `pm backup` 的 requireMain/requireRole 分支无自动化测试（需盘符发现 fixture）。
- 位移槽位封顶 99；落位后复核异常路径未做故障注入（沿前几轮记录）。
- junction 别名 vault 路径的守卫行为（`canonicalizePath` 一行）仍未自动化。
- 带 reparse 属性的非链接对象（OneDrive 占位、dedup）在指纹里记为 `l`，其内容
  变化不改变指纹（保守；真实库无此类对象）。

---

# 五轮复审（2026-08-24，`codex exec -s read-only` 直跑，对 a2efb3f..fdcd5e3）

- 取结果：重试循环第 1 次即真跑：178 次命令执行（约 11 分钟）。
- verdict：**NO-GO**——major/新 major 2 FIXED；A1/B1/测试 PARTIAL + 1 新 major + 2 新
  minor。逐条对照源码核实：**主体全部成立**；A1 内两个子断言以 GHC 9.10 探针
  **证伪**（`Data.Char.isDigit` 只认 ASCII：U+0663/U+FF11 → False；`read "9…9"::Int`
  静默回绕不抛异常，`show n == t` 本已拒绝），不影响主发现（路径型 pid）。同轮修复
  （P3b-8，155/155，零 GHC 警告）。

## 逐条

| # | 复审判定 | 残留（codex） | 核实 | P3b-8 处置 |
|---|---|---|---|---|
| A1 | PARTIAL | `opIdParts` 只排除 `#`/`~`，`../../outside#0` 通过解析，doctor 经 `quarTrashRel`/`pendingTmp` 把 trash/tmp 路径推到 root 之外（内容相符 → Q-DONE-LOST → `--repair` 补 Done）；`readDigits` 对越界/非 ASCII 数字 `read` 不安全；`slotOccupied` 的 `doesPathExist` 未包 try | 路径型 pid **成立**（Op.hs:104 原文只排除 `#`/`~`）；越界/Unicode **不成立**（探针：isDigit ASCII-only，read 回绕后被 `show n == t` 拒绝）；doesPathExist 未包 try **成立**，但探针显示它自己吞掉 InvalidArgument/PermissionDenied 答 False，随后 `pathIsSymbolicLink` 抛非 DNE 异常已落在占用分支 | `isValidPlanId` 移入 `Pm.Op`（Plan 再导出），`opIdParts` 要求 pid 为生成格式；`readDigits` 加 18 位上限（不再依赖回绕语义）；`slotOccupied` 提为顶层并把两个探测都包 try（非 DNE → 占用）。测试：路径型/短名/超长序号 → Nothing、doctor 对 `../../../outside#0` 报 OID-MALFORMED 且 --repair 不补 Done、slotOccupied 非法名 → 占用 |
| major | FIXED | — | — | — |
| 新 major 2 | FIXED | — | — | — |
| B1 | PARTIAL | `runClean` 先 `verifyCandidates` 并打印「三副本已确认」，到写计划前才 `requireRole RoleMain`；`runTrash` clean 分支在 `trashView`/分类后才 `requireMain` | runClean **成立**（Commands.hs:635 vs :650 原文如此）；runTrash **部分成立**：`root` 是 pickRoot 已按槽位验过的作用 root，`trashView` 只读它的 manifest，requireMain 守的是 cfgMainPath 见证——但此前 `loadCatalog (cfgMainPath)` 在 `case emain` 之前执行（读取先于校验） | `runClean`/`runImport`（同类一并）把 `requireRole RoleMain` 移到任何 catalog 读取之前；`runTrash` clean 分支先判 `requireMain` 再读主库 catalog/备份发现（守卫仍在 clean 分支内而非 trashView 前，理由见代码注释）。测试：主路径为 RoleBackup + 索引存在 → runClean/runImport 都 exit 2 且不落计划；同 fixture 换 RoleMain → 1/0（证明 2 来自身份校验） |
| 测试 | PARTIAL | 未覆盖 runClean 次序、oid 路径穿越、readDigits 越界、slot 探测异常、root-id tmp 残留；`ensureTestRoot` 把损坏 marker 当缺席 `writeRootInfo` 覆盖 | 成立（TestUtil.hs:65-70 原文如此） | `ensureTestRoot` 改走 `readRootState` + `createRootInfo`（Corrupt → 测试失败，不覆盖）；上述各项补测试（root-id tmp 残留见残余）；journal fixture 一律用生成格式 pid（`TestUtil.tpid`） |
| 新 major | — | 同 A1 路径型 pid | 成立 | 并入 A1 |
| 新 minor 1 | — | `doesPathExist` 异常中断批次（codex 标注为假设） | 假设不成立（探针），契约改为显式 try | 并入 A1 |
| 新 minor 2 | — | `ensureTestRoot` 覆盖 RootCorrupt | 成立 | 并入测试项 |

## 附带

- 五轮主发现准确率保持（主体全成立），首次出现两个被探针证伪的子断言（Unicode
  数字、read 越界异常）——codex 自己把它们写成「没有安全失败」而非实证；处置
  原则不变：先探针再定论，不预设它错也不预设它对。
- `Exec.planIdOf`（manifest 元数据）仍是 `takeWhile (/= '#')`：其输入是内核按
  `validatePlan` 通过的计划生成的 oid，不是外部输入；未改。
- 真实库 journal 仅一个 pid（`20260823-175905-a06469`，生成格式，无后缀）：
  `opIdParts` 收紧不会在真实库触发 OID-MALFORMED（`pm doctor` 复核见提交说明）。

## 残余与未自动化项

- `createRootInfo` 在 move 前崩溃会留下 `.pm/root-id.json.<hex8>.tmp`：doctor 只扫
  `.pm/tmp/`，不会误判为身份/Done；纯残留清理，留待 doctor 增项。
- `.gitignore` 在 requireWritable 检查与后续 cache/catalog 写入之间被并发改写属
  未加锁 TOCTOU（Exec 路径锁内重检；非 Exec 写入口无第二次自守卫）。
- `pm backup` 的 requireMain/requireRole 分支无自动化测试（需盘符发现 fixture）。
- 位移槽位封顶 99；落位后复核异常路径未做故障注入；junction 别名 vault 守卫、
  reparse 非链接对象记 `l`（沿前几轮记录）。

---

# 六轮复审（2026-08-24，`codex exec -s read-only` 直跑，对 fdcd5e3..dfdf981）

- 取结果：重试循环第 1 次即真跑：126 次命令执行（约 22 分钟；结果文件在会话
  重启前已完整落盘，链的收尾复制步骤未跑，直接取 `review6-result-1.md`）。
- verdict：**NO-GO**——A1（oid 语法）/B1/文档 FIXED；余 1 个 major：**Doctor 直接
  拼接手编 journal 的 Op 路径字段**（合法 oid + `victim=../../../outside/x` 仍可
  越出 root 探测，`--repair` 可补 Done / 生成 C5 计划）。核实成立，且同类比
  codex 指出的更宽（见下）。同轮修复（P3b-9，158/158，零 GHC 警告）。

## 逐条

| # | 复审判定 | 核实 | P3b-9 处置 |
|---|---|---|---|
| A1（oid 语法/slotOccupied） | FIXED | — | — |
| B1（守卫次序） | FIXED（含 runTrash 分支内守卫的理由被接受：作用 root 已由 pickRoot 验身份，trashView 只读它的盘面与 manifest） | — | — |
| 新 major（Doctor 拼接 Op 路径） | **成立**（Doctor.hs:200/215/233/272 原文把 `dstRel`/`victim`/`old`/`new`/Done 的 `trashRel` 直接 `root </>`）。**同类统一排查发现更宽**：①Exec 自己的 relOk 只查 `isRelative` + `..`——filepath 实测 `isRelative "\\evil"`/`"c:evil"` 都是 True 且 `root </> 它们`是**整体替换**（外加 NTFS ADS `a.jpg:ads`），手编计划可直接让内核落位到 root 外；②manifest 的 `trTrashRel` 被 `pm trash empty` **unlink**（Commands.hs:325）——手编一行 `"../../../victim.jpg"` 就删 root 外文件；③Op 路径可指向 `.pm` 内部（rename root-id.json 等） | 共用谓词 `Pm.Op.relPathOk`（非空、非绝对、无 `:`、不以分隔符开头、无 `.`/`..` 分量）+ `opPathsOk`（`.pm` 内部一律拒，唯一例外 undo/复位 rename 的 `.pm/trash/` 源）：`validatePlan` 加路径校验（loadPlan/execPlan 取锁前+锁内三处生效）、`execItem` 换用同谓词、Doctor `classifyPending`/`verifyDone` 前置 `OP-PATH` Bad 且 `applyRepairs` 双保险过滤、`readManifest` 把非法记录降为损坏行（trash empty 绝不删）。测试 +3（158/158） |
| 测试 | PARTIAL（缺合法 oid + 越界 Op 路径、manifest 注入） | 成立 | `caseOpPathValidation`（拒绝面 + validatePlan/execPlan/loadPlan）、`caseDoctorOpPathEscape`（OP-PATH ×2、不进矩阵、--repair 不补）、`caseManifestPathEscape`（记录剔除、trash empty 不 unlink root 外文件） |
| 文档（§16 拆分/§10.2） | FIXED | — | P3b-9 条目补记 Doctor Op-path 残留的处置 |

## 附带

- filepath 语义探针（`Probe4.hs`，GHC 9.10）：`isRelative "\\evil" = True`、
  `isRelative "c:evil" = True`、`"D:\\root" </> "\\evil" = "\\evil"`、
  `"D:\\root" </> "c:evil" = "c:evil"`（整体替换）；`splitDirectories "a.jpg:ads"
  = ["a.jpg:ads"]`（`..` 检查对 ADS 无感）——旧 relOk 的两个绕过均实证。
- codex 对「runTrash 守卫在 clean 分支内」的理由判定为成立（trashView 枚举的
  是已验身份的作用 root）。
- `Exec.planIdOf` 维持 `takeWhile (/= '#')`（输入是内核生成 oid）。

## 残余与未自动化项

- catalog 的 `enPath` 同为可手编 `.pm` 文件字段：doctor `--deep`/status/diff 用它
  做**只读**探测（越界只泄露存在性/哈希比对结果，不产生写或删）；写屏障在
  validatePlan——由 catalog 生成的备份/归档计划落到 Op 路径后仍被拒。留待
  七轮意见是否也要在 loadCatalog 前置校验。
- 手编计划仍可 rename `.pm/trash/<x>` → 库内路径（与 undo 复位同形，受
  FpFileSha 前置条件 + I5 no-replace 约束）；语义上等价于合法 undo，未禁。
- root-id tmp 残留、.gitignore TOCTOU、`pm backup` 盘符 fixture、位移槽 99、
  reparse 记 `l`（沿前几轮记录）。

---

# 七轮复审（2026-08-24，`codex exec -s read-only` 直跑，对 fdcd5e3..dfdf981 之后的 d8316fe）

- 取结果：中转站余额耗尽（403 insufficient balance）致首轮断粮；用户充值后守候脚本
  自动重跑，attempt 2 真跑（54 次命令执行）。另有一次**新的空跑变体**：
  stderr 连刷 `tools::router: failed to parse function arguments`（112 条、30 分钟）
  且进程不退出——按零 `command_execution` 判据人工 kill，循环自愈。
- verdict：**NO-GO**（1 FIXED / 8 PARTIAL / 1 NOT-FIXED + 4 新发现）。核心指控：
  **词法校验挡不住 Windows 规范化别名与 junction**。逐条探针核实后同轮修复
  （P3b-10，162/162，零 GHC 警告）。

## 逐条

| # | 复审判定 | 探针核实 | P3b-10 处置 |
|---|---|---|---|
| 1 A1 词法谓词 | PARTIAL：`.PM`\/`.pm `\/`.. ` 别名可绕过 | **半数证实半数证伪**（Probe5，GHC 9.10 + Win11）：`root </> ".PM" </> f` 读到 `.pm` 里的文件 → **成立**；`root </> ".pm." </> f` 同样命中（尾随点被剥）→ **codex 没提到的更宽形态**；而 `.pm `、`.. `（尾随空格）**打不开** → 该断言**证伪** | `normComp` = 大小写折叠 + 剥尾随点\/空格；`relPathOk` 改判「规范化后分量非空」（一并覆盖 `.`\/`..`\/`...`\/纯空格）；`opPathsOk` 的 `.pm` 比对走 `normComp` |
| 4/7 junction | PARTIAL\/NOT-FIXED：trash 内 junction 可致库外删除\/搬运（codex 标为"需探针确认"） | **完全证实且是数据丢失级**（Probe5 B）：junction 下 `doesDirectoryExist=True`、`listDirectory` 穿透、`removeFile` **真的删掉了库外文件** | 三道闸：①`listTrashFiles` 遇 reparse point 不递归（链接本体列为条目，doctor 以 UNREGISTERED 报出）；②`pm trash empty` 每条 unlink 前 `Pm.Win.pathUnder` canonical 限域，越界 → HELD 且 exit 1；③`Pm.Exec` 的 copy\/rename\/quarantine 三个落位点同样限域（含 `.pm/trash` 例外的 rename 源——这正是 #7 的攻击面） |
| 6 catalog `enPath` | PARTIAL：手编快照 → `opSrcAbs` 未校验 | 成立（`Pm.Diff:80`\/`Pm.Import:156` 直接 `root </> enPath`）；**真实库 4855 条目实测零违规**，可安全 fail-closed | `loadCatalog` 校验每条 `enPath`，任一非法即整份拒绝载入并报警（快照是可由 `pm scan` 重建的缓存） |
| 5 undo | PARTIAL：`reverseOp` 直接拼 `.pm/trash/<trashRel>`，`savePlan` 不验 | 成立 | `reverseOp` 先验 Intent 的 `opPathsOk` 与 Done 的 `relPathOk`，非法即拒绝生成撤销计划 |
| 3/新 minor `pendingTmp` | PARTIAL：未先验 Op | 成立（仅影响 TMP-STALE 预期集合，`takeFileName` 已挡住穿越） | `pendingTmp` 前置 `opPathsOk` |
| 2 计划链路 · 8 filepath 事实 | PARTIAL（措辞）\/ FIXED | 链路本身经核实完整；filepath 事实无相反实证 | 无需改动 |
| 9 测试 · 10 文档 | PARTIAL：缺别名\/junction\/catalog 覆盖；文档把 `.pm` 拒绝写得过于绝对 | 成立 | 新增 4 例（含 junction 三道闸与 catalog\/undo）；文档补记 Win32 规范化与 reparse 的处置及残余 |

## 附带

- `canonicalizePath` 对**不存在的末段**照样返回规范路径（Probe6：新目录名、两层
  缺失均正常），因此限域门不会误拒 names 那 6 项「改到新名字」的改名。
- 测试文件触及 750 行预算 → 路径类用例拆出 `test/PathGuardTests.hs`
  （同 P3b-6 拆 `Pm.BackupCmd` 的先例）。
- 工程事故（自记）：一次用 PowerShell `Get-Content`+`WriteAllLines` 回写
  `GuardTests.hs`，控制台按 CP936 解码致 CJK 全毁；`git checkout --` 复原。
  源文件此后一律用 Edit\/Write 工具或 git 操作，不经 PowerShell 文本往返。

## 残余与未自动化项

- 限域用 `canonicalizePath`，与后续实际操作之间存在 TOCTOU 窗口（§14 单机威胁
  模型：需要攻击者在窗口内替换 reparse point）；Exec 侧另有锁 + no-replace 兜底。
- catalog 只读探测（doctor `--deep`\/status\/diff）现由 `loadCatalog` 校验覆盖，
  但 `opSrcAbs` 本身仍不做 root 归属校验（备份计划的 src 合法地位于另一 root）。
- `pm backup` 盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU
  （沿前几轮记录）。

---

# 八轮复审（对 b502c0e = P3b-10）→ NO-GO → P3b-11 收口

verdict：**NO-GO** — 1 critical + 4 major + 1 minor。核心指控一句话：**七轮学会了
问操作系统"目标解析后在哪"，却仍默认基准可信**——而 `root`、`.pm/trash`、
`.pm/tmp` 都是 pm 自己拼出来的字符串。

## 探针实证（Probe7\/8，GHC 9.10 + Win11；先证再改）

| 指控 | 探针结果 | 判定 |
| --- | --- | --- |
| `.pm/trash` **自身**是 junction → 限域失效 | `pathUnder(trash, trash\v.jpg)` = **True**（两侧都 canonical 到库外）；`removeFile` 后库外文件 **不存在了** | ✅ 成立，**数据丢失级** |
| `.pm/tmp/<plan>` 是 junction → doctor `--repair` 删库外 | `listDirectory` 穿透；`removeFile` 后库外 hostage.txt **不存在了** | ✅ 成立，**数据丢失级** |
| `root/alias -> root/.pm` 别名 | `opPathsOk` 放行（alias 词法上不是 `.pm`）；`pathUnder(root, root\alias\root-id.json)` = **True**，canonical 展开为 `.pm\root-id.json` | ✅ 成立 |
| 预置 hardlink 占确定性 tmp 名 → `WriteMode` 覆盖库外 | 库外文件内容变成 `"PM-WROTE-THIS"`；`pathIsSymbolicLink(hardlink)` = **False** | ✅ 成立（前两层看不见它） |
| 8.3 短名（如 `PM~1`）同型绕过 | 本卷 `fsutil file queryshortname` 返回不支持 → **无法在本机构造反例** | ⚠️ **未证实**；按机制覆盖（canonical `.pm` 排除），不据此宣称已复现 |
| Unicode 全角\/兼容等价、`CON`\/`NUL` 设备名 | codex 自己标为"无实证"；未构造出解析到 `.pm` 或库外普通文件的反例 | ⚠️ 未证实，列残余 |

修复候选同步验证：`descendOk`（逐级 no-follow）对上表前三条**全部拒绝**；
`CREATE_NEW` 独占创建对已存在文件与预置 hardlink **都拒绝**，且库外内容完好；
`removeFile` 删 hardlink 只减一个目录项，库外原文件字节不变（→ 重跑安全）。

## 处置

| 项 | codex 判定 | 我的核实 | P3b-11 处置 |
| --- | --- | --- | --- |
| 2 限域基准（critical\/major×2） | NOT-FIXED | 全部实证成立 | `Pm.Win.resolveUnder`：从基准逐分量下降，**每一段已存在的名字都不得是 reparse point**；`pm trash empty` 的唯一 unlink、`Pm.Exec` 三个落位点、`Doctor.staleTmpFiles` 遍历全部改用它 |
| 1 词法层 · 8.3\/别名 | PARTIAL | junction 形态成立；短名未证实 | `pathAtOrUnder` 做 canonical `.pm` 语义排除（用户数据路径的第二判据），覆盖"不是 reparse point 但 canonical 后落进 `.pm`"的整类 |
| tmp symlink\/hardlink（major） | 新发现 | 实证覆盖库外内容 | `Pm.Win.openExclusiveBinary`（`CREATE_NEW`）+ `openFreshBinary`（先 unlink 残留再独占创建）；`copyFileHashed`\/`saveCatalog`\/`createRootInfo` 三处 tmp 全部改用。**与 codex 建议的差异**：它要"已存在即拒绝"，我取"先安全 unlink 再独占创建"——崩溃重跑必须能用同名 tmp（doctor 靠确定性名区分孤儿与在途），而 unlink 对 hardlink\/symlink 只删目录项，库外字节不受影响（实证） |
| `.pm` 家族整体（journal\/plan\/manifest\/catalog\/root-id\/lock） | codex 指出"只补四个 removeFile 不够" | 成立：这些入口没有共同的路径参数，但有共同的前提 | `Pm.Config.requirePmTrusted` 并入 `requireWritable`，一次判定覆盖全部 `.pm` 写入口；`Pm.Exec` 取锁前 + 锁内各一次；`runTrash` 前置同一闸（基准被劫持时连读都不读——本轮自查发现它此前**没有任何**身份闸） |
| 3 遍历层 | PARTIAL：基准自身未查 | 成立 | `listTrashFiles`\/`staleTmpFiles` 都先查基准 |
| 4 catalog 代次语义 | PARTIAL：语义非法仍回退旧代 | 成立 | `loadCatalog` 区分**半写可回退**与**语义非法整条链拒**；校验从 `relPathOk` 收紧到 `userRelOk`（`.pm\journal.ndjson` 是合法相对路径却指向 pm 自身状态） |
| 5 undo | PARTIAL：未验生成结果 | 成立 | `reverseOp` 对**生成的**反向 Op 再过 `opPathsOk`（一次合法复位历史反转后 `.pm/trash` 成了目标） |
| 6 测试 | PARTIAL：catalog 用例注释称测 `.1` 回退实则没有 | **成立，是我的测试 bug** | 补真 `.1` 两态用例；新增 base-junction、alias、hardlink、doctor-tmp、undo-reverse 共 6 例（168\/168） |
| 7 文档 | PARTIAL：残余不完整、措辞过绝对 | 成立 | 本章节 + §10.2 P3b-11 + REVIEW-LOG 八轮段；残余清单见下 |

## 残余（更新，取代前几轮清单中已闭合的条目）

- **TOCTOU**：`resolveUnder` 逐级判定与实际 `removeFile`\/`moveFile` 之间仍有窗口
  （§14 单机威胁模型：需要攻击者在窗口内替换 reparse point）。codex 建议的
  handle 语义（`CreateFileW` 取 final path\/File ID 后在同一句柄上做 disposition）
  能收窄它，需要 handle-relative 的原生 rename\/create——未实施。
- **8.3 短名 · Unicode 等价 · 保留设备名**：本机无法构造反例（卷未启用短名），
  按未证实归档；`.pm` 语义排除按机制覆盖短名一类，设备名仍只被词法层挡。
- `opSrcAbs` 不做 root 归属校验（备份计划的 src 合法地位于另一 root）；codex 建议
  按 plan kind\/root UUID 绑定允许读取根集合——未实施。
- `Pm.Config.writeSideCache` 与 `writeConfig` 仍是普通覆盖写（前者是可重建缓存，
  后者在用户配置目录、不在库内）。
- `pm backup` 盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU（沿前
  几轮记录）。
- `docs/DESIGN.md` 已 740 行，逼近 750 行预算——下一次扩写前需拆分。

---

# 九轮复审（对 b9a76e7 = P3b-11）→ NO-GO → P3b-12 收口

verdict：**NO-GO** — 1 critical + 4 major + 2 minor。核心指控一句话：**八轮把闸
装在了"固定路径层"，而 pm 实际写的路径是动态构造的**；并且"失信"一直只定义了
reparse 一种，漏掉了 hardlink 这一整类。

## 探针实证（Probe9，GHC 9.10 + Win11）

| 指控 | 探针结果 | 判定 |
| --- | --- | --- |
| `.pm/tmp/<planId>` 动态层是 junction（critical） | `.pm/tmp` 非 reparse（可信闸**放行**）、`<planId>` 层是 reparse；`removeFile` 后库外 hostage **不存在了** | ✅ 成立，**数据丢失级** |
| journal\/plan 名被 hardlink 占用（major） | `AppendMode` 追加后库外文件变成 `"OUTSIDE-ORIGINAL\nPM-APPENDED\n"`；覆盖写后变成 `"PM-PLAN-OVERWRITE"` | ✅ 成立 |
| `pathIsSymbolicLink` 语义 | 普通目录\/文件 False、junction True、**hardlink False** | ✅ 佐证上一条：hardlink 三不沾 |
| `pathAtOrUnder` fail-open（major） | 本机构造不出 `canonicalizePath` 抛异常的输入（含 NUL 的名字被截断、`CON`\/`NUL` 正常返回） | ⚠️ 反例未构造出，但**代码结构性 fail-open 成立**，按原则修 |
| 非 name-surrogate reparse（OneDrive\/Dedup）被误拒（major） | 本机无法构造云占位\/Dedup 对象 | ⚠️ **未证实**；按 Win32 规范改 tag-aware（安全性与可用性同时更正确） |

## 处置

| 项 | codex 判定 | 我的核实 | P3b-12 处置 |
| --- | --- | --- | --- |
| 1\/新 critical 动态 tmp 层 | PARTIAL\/critical | 实证成立 | `Pm.Exec.confinedTmp`：`.pm\/tmp\/<planId>\/<name>` 完整路径逐级下降，**创建目录前后各验一次**（把 TOCTOU 收窄到"创建后立刻"） |
| 4 可信闸覆盖面 | NOT-FIXED | 成立：三条 init 旁路建立身份，天然走不了 `requireWritable` | `RootIdState` 增 `RootUntrusted`，闸下沉进 `readRootState`（身份读取的唯一入口）——init 三旁路覆盖（**十轮更正**：status\/versions 当时并未被覆盖，它们直接调 `loadCatalog`；P3b-13 把闸下沉到 loader 才真正盖住）；`createRootInfo` 自身再加一道。GHC 的 `-Wincomplete-patterns` 把三处调用点全指了出来；`initPreflight` 的 catch-all `_ -> Right ()` 是穷尽性检查看不见的第四处，测试抓到 |
| 新 major hardlink 状态文件 | 新发现 | 实证成立 | `openStateAppend`（link count \> 1 即拒）守 journal\/manifest；`savePlan` 与 `writeSideCache` 的覆盖写改「独占创建 tmp → 删旧 → no-replace 落位」 |
| 新 major 非 name-surrogate reparse | 新发现（未证实） | 无法构造反例 | `isNameSurrogate` 按 reparse tag 的 0x20000000 位判定（`FindFirstFileW` 的 `dwReserved0`）；读不出 tag → 仍拒（fail-closed） |
| 2 `pathAtOrUnder` fail-open | PARTIAL | 结构成立、反例未构造出 | 改三态 `IO (Maybe Bool)`，`confinedUser` 只接受 `Just False` |
| 3 独占创建取舍 | PARTIAL | codex 承认取舍成立，但指出父目录不可信时 `openFreshBinary` 的 unlink 会删库外——**这正是 critical** | 取舍保留（崩溃重跑需要确定性 tmp 名），前置条件写进 haddock：调用方必须先对**完整路径**做 `resolveUnder` |
| 3 句柄泄漏 | minor | 成立 | `openExclusiveBinary` 加 `onException` 覆盖 HANDLE→Handle 的所有权转移 |
| 6 undo 无身份计划 | minor | 成立 | `readRootInfo` 为 Nothing 即 Left；生成后再过 `validatePlan` |
| 5 catalog 代次 | FIXED | — | 无需改动（哨兵脆弱性列残余） |
| 7 测试 | PARTIAL：给了"更小反例" | 成立 | 该反例直接成为 `caseExecDynamicTmpJunction`；另加 init 旁路、hardlink 状态文件、三态、undo 身份共 5 例（173\/173） |
| 8 文档 | NOT-FIXED：措辞与代码不符 | 成立 | `resolveUnder` 的 haddock 更正（base 只 canonicalize，不查它是不是链接——root 由用户指定，放在 junction 上是合法用法）；"一次判定覆盖全部 `.pm` 写入口"的说法按实际覆盖面重写；"设备名由词法层挡住"删除（`relPathOk` 确实不拒 `CON`\/`NUL`） |

## 残余（更新）

- **TOCTOU**：逐级判定与实际操作之间的窗口仍在（§14 单机模型）。Copy 的 tmp 路径
  已加"创建后复检"把窗口收窄，但根治需要 handle-relative 的原生 create\/rename\/
  delete（`GetFinalPathNameByHandleW` + File ID 比对）——未实施。
- **未证实项**：8.3 短名（本卷 `fsutil` 不支持）、Unicode 兼容等价、保留设备名
  （`relPathOk` **不**拒 `CON`\/`NUL`，且实测 `canonicalizePath root\CON` 正常返回；
  尚无它们解析到 `.pm` 或库外普通文件的实证）、非 name-surrogate reparse 的实际
  形态（无法构造云占位\/Dedup 对象）。
- `catalog` 的 `tamperMark` 哨兵是字符串协议，建议改显式状态（九轮认为当前无可
  构造的伪命中\/漏命中）。
- 固定名 `catalog.json.tmp` 的并发保存竞态（无锁 scan 与 saveCatalog 之间）。
- `opSrcAbs` 不做 root 归属校验（备份计划的 src 合法地位于另一 root）。
- `Pm.Config.writeConfig` 仍是普通覆盖写（在用户配置目录，不在库内）。
- `pm backup` 盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU。
- `docs/DESIGN.md` 的逐轮收口列表已移入 `docs/REVIEW-LOG.md`（DESIGN 740 → 619 行）。

---

# 十轮复审（对 98f6b72 = P3b-13 之前）→ NO-GO → P3b-13 收口

verdict：**NO-GO**；收敛性判断：**未收敛**（它按提示明确回答了这一问，并给出
具体依据而非泛泛而谈）。核心指控一句话：**我一直在用「枚举」定义可信集合，
而枚举天然会漏**——前三轮每轮补一个子目录名，十轮点出 `backup-cache` 与
`vault-cache` 从来不在名单里。

## 探针实证（Probe10）

| 指控 | 探针结果 | 判定 |
| --- | --- | --- |
| `.pm/vault-cache` 是 junction → 侧缓存写替换库外文件（critical） | 库外 `catalog.json` 变成 `"PM-CACHE"`、`meta.json` 变成 `"PM-META"` | ✅ 成立，**数据丢失级** |
| 修法候选：枚举 `.pm` 实际内容 | 列出 `vault-cache -> REPARSE` —— 白名单永远不会去看它 | ✅ 有效 |
| `getFileAttributes`：缺失名字 vs 普通目录 | 缺失抛异常、普通目录返回 16 —— 二者今天都塌缩成 False | ✅ 三态确有必要 |
| `canonicalizePath` 能否被构造成抛异常 | 含 NUL 截断、`CON`\/`NUL` 正常返回、**空路径解析成 cwd**（本例是我先假设后被自己的测试证伪） | ❌ 本机构造不出 |

## 处置

| 项 | codex 判定 | 我的核实 | P3b-13 处置 |
| --- | --- | --- | --- |
| 1\/critical 侧缓存父目录 | NOT-FIXED | 实证成立 | **不再补名单**：`requirePmTrusted` 改为验 `.pm` 自身 + `listDirectory` 枚举其下**每个实际存在的条目**逐一判定。漏枚举在结构上不再可能。`writeSideCache` 改 root-relative 接口（root + 子目录名），完整路径在建目录前后各验一次；`Pm.Backup`\/`Pm.Vault` 的缓存目录名并入 `Pm.Config` 单一真源 |
| 4\/major 读入口 | NOT-FIXED：status\/versions\/loadPlanAnyRoot 在闸之前读 `.pm`；并指出我上一轮归档「status\/versions 已覆盖」的说法不成立 | **成立，是我的文档不实** | 闸下沉到 loader：`loadCatalog`\/`readJournal`\/`readManifest`\/`loadPlan` 各自先过 `requirePmTrusted`。命令层加闸总会漏命令，loader 是所有 root-based `.pm` 读取的必经之地 |
| 2 reparse 探测 | PARTIAL：偏移核算**正确**（它逐字段复核了 592 与 36）；但"不存在"与"查询失败"塌缩 | 探针证实塌缩 | `probeName` 四态 `NameMissing`\/`NamePlain`\/`NameSurrogate`\/`ProbeUnknown`；`resolveUnder` 对 `ProbeUnknown` **拒绝**。`reparseTag` 的 `FindClose` 用 `mask`+`finally` |
| 6 句柄 | PARTIAL：两处 `onException` 已覆盖同步异常，缺外层 `mask` | 成立 | `reparseTag` 已加；`openExclusiveBinary` 的 `mask` 列残余（Win32 `createFile` 的返回与第一个 `onException` 之间仍有理论窗口） |
| 3 hardlink 防护 | PARTIAL：正常库无误报；指出 `writeRootInfo` 仍是裸覆盖写 | 成立（它是测试 fixture helper，生产无调用） | 保留并在 haddock 标注仅供 fixture；列残余 |
| 5 fail-open 扫描 | PARTIAL：`pathAtOrUnder` 已三态；另指出 `isNameSurrogate` 与 `Pm.Scan` 的探测异常仍按安全值放行 | 前者已随四态修复；`Pm.Scan` 的 symlink 探测形态未证实 | `Pm.Scan` 列残余 |
| 7 测试 | PARTIAL：**指出三条"绿但没钉住屏障"** | 全部成立 | ①用 `CpCopyAfterIntent` 在两次限域**之间**注入 junction，钉住建目录后的复检；②`admitsUserPath` 判据导出，测试打在真实代码而非用例内自造的 if 上（本机触发不了 `Nothing`，这是诚实的替代）；③`caseInitBypassUntrusted` 的覆盖面在标题与注释中如实说明 |
| 8 文档 | NOT-FIXED：列出 6 处声明与代码不符 | **全部成立** | 逐条改：`requirePmTrusted` 的"一次覆盖全部写入口"、`openFreshBinary` 关于 Catalog\/Config tmp 的说法、归档里"status\/versions 已覆盖"的错误结论、README\/REVIEW-LOG 的侧缓存声明 |

## 残余（更新）

- **TOCTOU**：逐级判定与实际操作之间的窗口仍在。Copy 的 tmp 与侧缓存都加了
  "建目录后复检"收窄，根治仍需 handle-relative 的原生 create\/rename\/delete。
- `openExclusiveBinary` 缺外层 `mask`：`createFile` 返回与第一个 `onException`
  之间的异步异常窗口（十轮 minor，未修）。
- `Pm.Config.writeRootInfo` 仍是裸覆盖写——仅测试 fixture 使用，生产走
  `createRootInfo`。
- `Pm.Scan` 的 symlink 探测异常按"不是 symlink"处理（该 ACL 形态未证实）。
- **未证实项**：8.3 短名（本卷 `fsutil` 不支持）、Unicode 兼容等价、保留设备名、
  云占位\/Dedup 的实际 reparse 形态、能让 `canonicalizePath` 抛异常的输入
  （本机构造不出，故 `pathAtOrUnder` 的 `Nothing` 分支只能由导出的判据钉住）。
- `catalog` 的 `tamperMark` 字符串哨兵；固定名 `catalog.json.tmp` 的并发竞态；
  `opSrcAbs` 不做 root 归属校验；`writeConfig` 普通覆盖写（在用户配置目录）。
- `pm backup` 盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU。

---

# 第十一轮（复审 P3b-13，commit 45ae8a9；gpt-5.6-sol 独立评审）

**verdict：NO-GO；收敛性：未收敛**——"深度 1 的白名单遗漏已消除，但深度 ≥2 的
manifest/plan 及读侧 hardlink 仍可绕过可信闸；仍属『pm 信任自己拼出的 `.pm`
子路径』同类缺口"。三条实证发现只有一个根因：pm 访问 `.pm` 的模式是
「拼路径字符串 → 校验字符串 → 再**按名字**打开」——①校验只到深度 1；②字符串
校验在原理上看不见 hardlink 而读侧没有 link count；③校验与打开是两次独立解析。

## 探针实证（Probe11/11b，GHC 9.10 + Win11；对真实 pm 函数）

| # | 形态 | 真实调用 | 结果 |
|---|---|---|---|
| A critical | `.pm/trash/manifest.ndjson` = 指向库外文件的**文件 symlink**（本机实测无需特权即可创建，此前各轮一直以为不行） | `appendManifest` | **追加进了库外文件**（`OUTSIDE-ORIGINAL` 之后多出 pm 的隔离记录）；`readManifest` 同路读回 1 条 |
| B major | `.pm/catalog.json` = 库外快照的 hardlink | `requirePmTrusted` + `loadCatalog` | 闸 **PASSED**（hardlink 不是 reparse point），库外 catalog **零警告载入** |
| C major | `.pm/plans/<id>.json` = hardlink / symlink（两种都试） | `loadPlan` | **两种形态都载入了库外计划**（apply 会照它执行） |
| D minor | `.pm` 是**普通文件** | `requirePmTrusted` | **PASSED**（`doesDirectoryExist=False` 被当"尚不存在"） |
| E 修法验证 | 完整路径 `resolveUnder` | — | symlink 形态 **Nothing（拦下）**；hardlink **Just（原理上不可见）**→ 只能靠句柄 link count |

## 处置（P3b-14，全部先探针后修）

| 发现 | codex 判定 | 实证 | 修复 |
|---|---|---|---|
| critical manifest 深层 symlink | 新发现（附验证方法） | Probe11 A 成立 | **唯一受信取用口** `Pm.Config.readPmState` / `withPmStateAppend`：完整相对路径逐级 `resolveUnder` → 只打开一次 → **句柄**上查 link count → 从同一句柄读写。`appendManifest`/`readManifest` 改道 |
| major 读侧 hardlink | 新发现 | Probe11b B 成立 | 新增 `Pm.Win.openStateRead`（`openStateAppend` 的只读对偶）；catalog 三代、journal、root-id、plan、两侧缓存读全部走 `readPmState`。校验后**不按名字重开** |
| major plan 深层链接 | 新发现 | Probe11b C 两形态都成立 | `loadPlan'` 走 `readPmState`；`savePlan` 落位前对完整路径 `resolveUnder`（拒绝抛 IOException，与 append 口径一致） |
| minor `.pm` 非目录 | 新发现 | Probe11 D 成立 | `requirePmTrusted` 用 `probeName` 四态分判 `.pm` 自身：缺失=新库放行，非目录/查不出=拒绝 |
| 1 深度分工 | PARTIAL | 成立 | 见上——深度 ≥2 的固定状态文件全部经受信口；`requirePmTrusted` 的 haddock 明确写出"作用域是深度 1，更深由取用口逐条验"的分工 |
| 2 loader 覆盖面 | PARTIAL：不止四个 loader；backup 把 `Nothing` 当全扫起点 | 成立 | 侧缓存读改 `readSideCache`（不可信=弃用，且配对的写侧对同一路径返回 Left → vault 硬停/backup 警告，不会静默）；lock 加完整路径解析；trash 遍历/doctor 探测本就不递归链接，删除侧见下 |
| 3 侧缓存读侧 | PARTIAL | 成立 | `readSideCache` 完整路径 + 句柄 link count |
| 4 probeName 二问 | PARTIAL：`doesPathExist` 吞 ACL 错误 | 成立（本仓 Exec 注释早已记录该行为） | 直绑 `GetFileAttributesW`，失败时读 `GetLastError`：只有 ERROR_FILE_NOT_FOUND(2)/ERROR_PATH_NOT_FOUND(3) 算缺失，其余一律 `ProbeUnknown` fail-closed。Doctor 的 `staleTmpFiles` 判据改为仅 `NamePlain` 放行，`--repair` 删除前对完整路径再过一次 `resolveUnder`（解析不出=跳过不删） |
| 5 mask/admitsUserPath/Scan | PARTIAL：`openExclusiveBinary` 的窗口比登记的更宽（`hANDLEToHandle` 返回后到下一条 `onException` 之间也有所有权窗口） | 成立 | 残余描述已按它的措辞更正；`Pm.Scan` 维持已登记残余 |
| 6 测试钉子 | PARTIAL：`caseSideCacheJunction` 钉的是目录级 pre-check（删掉文件级复检仍绿）；`caseLoaderLevelGate` 只测 `.pm` 自身 junction | 成立 | 新模块 StateGuardTests（PathGuardTests 触及 750 行预算，按 P3b-10 先例拆分）+5 例：manifest 深层 symlink、catalog 读侧 hardlink、plan 双形态、`.pm` 普通文件、侧缓存**文件级**链接（写侧文件级复检 + 读侧 hardlink 弃用）。`caseTrashBaseJunction` 的 ③ 步改为断言 `appendManifest` 拒绝（新实现比旧用例的 setup 假设更严） |
| 7 文档 | NOT-FIXED：DESIGN 版本行陈旧、REVIEW-LOG 两处过度声明、Config haddock"前后各验一次"只到目录、"任何东西自动进入检查范围"未限定深度、README 过度 | **全部成立** | 逐条更正：DESIGN 当前实现行、REVIEW-LOG 加两处「十一轮更正」、`loadCatalog` 注释收窄声明、`requirePmTrusted`/`writeCacheFile` haddock 写明分工与文件级复检、README P3b-13 行标注二问缺陷 |

回归：181/181（+5），GHC 警告 0；真实库只读四连不变
（doctor 0 / trash list 0 / status 1 / vault status 1，doctor 275 ms）。

## 残余（更新）

- **TOCTOU**：受信取用口把「校验→打开」收成一次，但 `resolveUnder` 与
  `openStateRead/Append` 之间仍有窗口（symlink 在两者之间被放入时，靠 link
  count 那半边兜不住 symlink 形态）。根治仍需 handle-relative 原生 API
  （NtCreateFile + OBJ_DONT_REPARSE 一类），登记待 P4 前评估。
- `openExclusiveBinary` 缺外层 `mask`；窗口按十一轮的措辞登记为
  「`createFile` 返回→第一个 handler」与「`hANDLEToHandle` 返回→下一条
  `onException`」两段。
- `requirePmTrusted` 的枚举在深度 1 与使用点之间是两个快照（枚举后新放入的
  条目由使用点的完整路径解析兜底；hardlink 形态由句柄判定兜底）。
- `Pm.Config.writeRootInfo` 裸覆盖写（仅测试 fixture）；`Pm.Scan` symlink 探测
  异常按非 symlink 继续（ACL 形态未证实）；`GitGuard`/`Vault.photosJsonRef` 读
  的是**库外**用户文件（.gitignore/photos.json），不属 `.pm` 取用口的辖区。
- **未证实项**：8.3 短名、Unicode 兼容等价、保留设备名、云占位/Dedup 实际
  reparse 形态、能让 `canonicalizePath` 抛异常的输入、"可读内容但不可读
  attributes"的 ACL 库（`ProbeUnknown` 对其 fail-closed 属预期保守）。
- `tamperMark` 字符串哨兵；`catalog.json.tmp` 固定名并发；`opSrcAbs` 无 root
  归属校验；`writeConfig` 普通覆盖写；备份盘符 fixture、位移槽 99、root-id tmp
  残留、.gitignore TOCTOU。

---

# 第十二轮（复审 P3b-14，commit d50f530；gpt-5.6-sol 独立评审）

**verdict：NO-GO；收敛性：未收敛**——"读/追加口本身已闭合，但仓库仍有同类
『拼 `.pm` 路径后按名字操作』的生产入口"。这一轮的价值在于把十一轮的收口
**补全成一个可陈述的不变式**：十一轮只收了**读与追加**，写（`saveCatalog`
轮转）、加锁、doctor 的**定点探测**仍在按名字操作。

## 逐条判定与处置

| 发现 | codex 判定 | 核实 | 修复 |
|---|---|---|---|
| **critical** `saveCatalog` 轮转 | NOT-FIXED（src/Pm/Catalog.hs:97-122） | **成立**（源码逐行核对：函数自身无 `requirePmTrusted`/`resolveUnder`；攻击窗口由 `Pm.Commands.runScan:232-247`、`Pm.BackupCmd:131-135` 的「load → 长扫描 → save」提供；junction 下 `removeFile` 删库外文件是 Probe7 起的实测事实） | 新增 `Pm.Config.resolvePmPath`（使用点解析，解析不出即抛）；tmp/base/.1/.2 **四条路径逐条解析后只用返回路径**做创建、unlink、rename |
| **major** doctor 定点跟随 | NOT-FIXED（src/Pm/Doctor.hs:240,246） | **成立**：trash 载荷按名字 `doesFileExist`+`sha256File`，换成指向库外同内容文件的 hardlink 时"核验通过"，`--repair` 补写**虚假 Done** | 新增 `probePmSha`（完整路径 `resolveUnder` → `openStateRead` → **同句柄** `sha256Handle`）+ `probePmExists`；失信只报 `PM-LINK` Bad，**不参与任何 repair 推导**。`Pm.Hash` 导出 `sha256Handle`（按名字重开就等于把校验与读取拆成两次解析） |
| **minor** lock 裸句柄 | 成立 | 成立 | `Pm.Win.openStateLock`：`ReadWriteMode` 打开一次 → 句柄 link count → 同句柄 `hTryLock` |
| **minor** 侧缓存三态损失 | 成立，并指出我的注释"不会被静静吞掉"与 `Pm.Status` 实际行为矛盾 | **成立，是我的注释不实**（status 只读，没有配对写侧） | `readSideCache` 恢复 `Either String (Maybe a)`；`Pm.Status` 对 `Left` 报 ⚠ 并**计入退出码**；`computeVault` 弃用失信缓存重算但打印原因 |
| **minor** 侧缓存读侧用例假绿 | 成立 | **成立**：库外 JSON 是 `{"x":1}`，解不出 `Catalog`，删掉 link count 屏障照样绿 | 改为 pm 自己编码的**合法 Catalog**，断言 `Left`；突变验证确认现在会转红 |
| 3 FFI 线程亲和性 | PARTIAL：明确标注为**假设**、未作为已证实缺陷 | 假设合理（`GetLastError` 是 per-OS-thread，threaded RTS + `-N`，两次独立 FFI 之间无 bound-thread 保证） | **不登记残余，直接消除**：新增 `cbits/pm_win.c` 的 `pm_get_file_attributes_err`，属性与错误码**同一次调用内**取得。假设不存在了，就不需要压力探针 |
| 1/2 其余、4 doctor stale、6 文档 | PARTIAL / FIXED / NOT-FIXED | 逐条成立 | 见下「文档更正」 |

## 文档更正（十二轮点名 5 处，全部成立）

- README「lock 与全部状态入口改道」→ 改为「**读与追加**改道」，并新增 P3b-15 行。
- REVIEW-LOG 十一轮条目补「**十二轮更正**」段（同上，另记侧缓存假绿）。
- `Pm.Config` 模块头「唯一状态取用口」→ 说明写侧由 `resolvePmPath` 在使用点解析。
- `readSideCache` 注释删去"不会被静静吞掉"的不实说法，改述三态契约。
- `openFreshBinary` 注释关于 Catalog 前提的说法随 `saveCatalog` 修复一并更新。

## 突变验证（本轮每条新屏障都做了，不只是"测试通过"）

| 删掉的屏障 | 结果 |
|---|---|
| `saveCatalog` 的四条 `resolvePmPath` | `caseSaveCatalogJunction` **FAIL**（1/184） |
| `openStateLock` 的 link count | `caseLockHardlink` **FAIL**（1/184） |
| doctor `probePmSha` → 退回按名字 sha | `caseDoctorTrashPayloadLink` **FAIL**（1/184） |
| `openStateRead` 的 link count | **4 例同时 FAIL**（catalog 读侧、plan、侧缓存读侧、doctor 载荷）——其中侧缓存读侧正是十二轮点出的假绿，现已真正钉住 |

回归：184/184（+3），GHC 警告 0；真实库只读四连不变
（doctor 0 / trash list 0 / status 1 / vault status 1，doctor 240 ms），
status 的备份盘/vault 两行走的是 `Right` 分支，无误报失信。

## 残余（更新——十二轮指出上一版清单漏登记了 Catalog/lock/Status/doctor/FFI 五项，本版按其清单逐项补齐或消除）

- **TOCTOU（check-use 窗口）**：受信口把「校验→打开」收成一次，但
  `resolveUnder` 与 `openStateRead/Append/Lock` 之间仍有换链窗口；
  `savePlan` 的「resolve → 独占 tmp → 删旧 → 落位」中删旧那步同理
  （十二轮：单纯再 resolve 一次只能收窄，不能消除**双重换链**）。
  根治需 handle-relative 原生 API；十二轮另给了一个更轻的收窄方案——打开后
  在同句柄上 `GetFinalPathNameByHandleW` 与预期 root 比对（需先验证
  UNC / 卷 GUID / 大小写规范化形态），登记待 P4 前评估。
- `openExclusiveBinary` 缺外层 `mask`：两段所有权窗口（`createFile` 返回→第一个
  handler；`hANDLEToHandle` 返回→下一条 `onException`）。
- `requirePmTrusted` 的深度 1 枚举与使用点是两个快照（深层由取用口逐条兜底）。
- `createRootInfo` 新建 `.pm` 之后没有再次 resolve（窄 TOCTOU）。
- `Pm.Config.writeRootInfo` 裸覆盖写（**仅测试 fixture**，生产走 `createRootInfo`）。
- `Pm.Scan` 的 symlink 探测异常按非 symlink 继续（该 ACL 形态本机构造不出）。
- `Pm.GitGuard` 读用户 `.gitignore`、`Pm.Vault.photosJsonRef` 读配置指向的
  `photos.json`——都不是 `.pm` 状态，不属受信取用口辖区（十二轮复核该排除理由成立）。
- **`probeName` 的错误码集合**：只有 2/3 算缺失，5/15/21/32/53/67/123/206 等一律
  `ProbeUnknown` fail-closed。十二轮指出这可能拒绝离线/无权限/UNC 断网的库，
  但**不会误接受**；本机构造不出这些形态的实测反例，登记为已知保守取舍。
- **未证实项**：8.3 短名、Unicode 兼容等价、保留设备名、云占位/Dedup 的实际
  reparse 形态、能让 `canonicalizePath` 抛异常的输入、"可读内容但不可读
  attributes"的 ACL 库。
- `tamperMark` 字符串哨兵；`opSrcAbs` 无 root 归属校验；`writeConfig` 普通覆盖写；
  备份盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU。
- **慢介质开销**（十二轮 dig-deeper）：每次 loader 一次 `.pm` 深度 1 枚举 +
  每个状态文件的逐级解析；备份发现对每个候选卷调用 `readRootInfo`。源码未设
  超时，可能累积延迟——**无正常文件被误判的证据**，但 USB 备份盘上的实测待
  用户插盘后补。

---

# 第十三轮（复审 P3b-15，commit 1666f4c；gpt-5.6-sol 独立评审）

**verdict：NO-GO；收敛性：未收敛**——它按**自己上一轮给的判据**（"仓库里还有没有
任何『拼 `.pm` 路径后按名字操作』的生产入口"）重新扫了一遍，并按①受信口内部 /
②已解析路径 / ③不跟随链接遍历 / ④用户数据 / ⑤裸按名字操作 五类给出了完整归类。
⑤ 只剩一条**新**缺口 —— 但那条是真的。

## 逐条判定与处置

| 发现 | codex 判定 | 核实 | 修复 |
|---|---|---|---|
| **major** doctor 的 restore 源 | NOT-FIXED（src/Pm/Doctor.hs:259） | **成立**：`Pm.Op.isTrashSrcRel`（src/Pm/Op.hs:212-218）明确允许 `OpRename` 的**源**落在 `.pm/trash` 内，而 `classifyPending'` 对它用裸 `existsAny`；`repairDone` 的白名单收 `R2` + `Warn`（src/Pm/Doctor.hs:434），于是 junction 化的复位源 + 指纹相符的目标 → R2 Warn → `--repair` 补**虚假 Done** | `.pm` 侧走 `probePmExists`，失信只报 `PM-LINK` Bad。剥 `.pm` 前缀用 `joinPath (drop 1 (splitDirectories old))` 而非 `makeRelative`——`isTrashSrcRel` 折大小写，`.PM/trash/…` 会让词法剥离失效（我第一版就写成了 `makeRelative`，自查时改掉） |
| **minor** 突变验证声明过强 | 成立 | **成立，是我的声明不实**：Catalog 用例只钉住"四条解析全部撤回"，单撤一条时其余解析仍在 junction 上失败、用例照样绿 | 为每一代快照（base/.1/.2/.tmp）**单独**构造文件级 symlink 用例；复验单撤 `.1` 一条即转红。README / REVIEW-LOG / 本归档的绝对措辞一并改掉 |
| 最小修复集 #2「严格兑现『使用返回路径』判据」 | 条件性建议（它把这些归为已登记 TOCTOU，非新缺口） | 成立，且**这是反复出现的形状本身** | **类级修复**：`confinedTmp` / `confinedTrash` 改为返回 `Maybe FilePath`，新增 `confinedUserPath`；Exec 的 tmp 落位、`execRename'` 两侧、`execQuarantine'` 两侧改为接收**已解析的绝对路径**，不再由被调函数重拼 `root </> rel` |
| 1 saveCatalog | FIXED | — | — |
| 2 doctor 同句柄 | PARTIAL（同句柄成立；三条 repair 线均不消费 `PmStateBad`；但 restore 分支绕过） | 成立 | 见上 |
| 3 lock | FIXED（含 `userError` 不会被误当"锁忙"） | — | — |
| 4 侧缓存三态 | FIXED（并确认 `--json` 不被警告污染） | — | 它建议 DESIGN 的 0/1/2 描述补一句"失信也算 attention"——已在 REVIEW-LOG 记录该语义扩展 |
| 5 FFI/C wrapper | FIXED；**并明确回答"建议补入 Missing 的错误码：空"** | 采纳 | 保持只有 2/3 算缺失 |
| 6 测试 | PARTIAL | 成立 | +3 例覆盖它点名的未钉住项：`probePmExists`、status 失信退出码、restore 探测 |
| 7 文档 | PARTIAL（2 处不符） | 成立 | 逐条更正（见下） |

## 类级修复：限域助手返回路径而非 Bool

这一轮真正的收获不是那条 major，而是它让"为什么同一形状反复出现"有了答案：
**限域助手返回 `Bool`，调用方只能自己再拼一次名字**——校验的字符串与操作的
对象因此永远是两次独立解析。十一轮修读、十二轮修写、十三轮修探测，都是这
一个成因的不同出口。改成返回解析后的路径后，调用方**无从**绕过：

    confinedTrash  :: FilePath -> FilePath -> IO (Maybe FilePath)
    confinedTmp    :: FilePath -> Text -> FilePath -> IO (Maybe FilePath)
    confinedUserPath :: FilePath -> FilePath -> IO (Maybe FilePath)

`execRename'` / `execQuarantine'` 的签名相应改为接收已解析的绝对路径
（`execRename'` 因此不再需要 `root` 参数——它已无处可拼）。

## 突变验证（本轮逐条，且补上了十三轮指出的粒度问题）

| 删掉的屏障 | 结果 |
|---|---|
| doctor restore 源的受信探测（退回 `existsAny`） | `caseDoctorRestoreSrcJunction` **FAIL**（1/187） |
| `probePmExists`（退回 `doesFileExist`） | `caseDoctorPendingTmpProbe` **FAIL**（1/187） |
| status 退出码去掉 `not bkBad && not vBad` | `caseStatusUntrustedCacheExit` **FAIL**（1/187） |
| **只撤 `catalog.json.1` 一条** `resolvePmPath` | `caseSaveCatalogJunction` **FAIL**（1/187）——十三轮指出旧写法此时仍绿，现已闭合 |

回归：187/187（+3），GHC 警告 0；真实库只读四连不变
（doctor 0 / trash list 0 / status 1 / vault status 1，doctor 196 ms）。
Exec 内核重构后 184 例原集合逐条通过（含全部故障注入矩阵）。

## 残余（更新）

- **TOCTOU（check-use 窗口）**：限域助手现在返回路径，窗口收窄到"解析→使用"
  之间；`saveCatalog` 的五步轮转仍是最宽的一处（十三轮亦如此判定）。根治需
  handle-relative 原生 API；十二轮提的
  `GetFinalPathNameByHandleW` 同句柄比对仍是待评估的轻量方案（需先验证
  UNC / 卷 GUID / 大小写规范化形态）。
- `createRootInfo` 建 `.pm` 之后没有再次解析 tmp/final（十三轮最小修复集 #2
  的后半，窄 TOCTOU，未修，登记）。
- `openExclusiveBinary` 缺外层 `mask`（两段所有权窗口）。
- `requirePmTrusted` 的深度 1 枚举与使用点是两个快照。
- `Pm.Config.writeRootInfo` 裸覆盖写（仅测试 fixture；十三轮复核确认生产调用图
  不含它）。
- `Pm.Scan` 的 symlink 探测异常按非 symlink 继续（ACL 形态本机构造不出）。
- `Pm.GitGuard` / `Pm.Vault.photosJsonRef` 读的是库外用户文件，不属 `.pm` 辖区
  （十三轮再次复核该排除理由成立）。
- `probeName` 只把 2/3 当缺失：十三轮明确回答"建议补入的错误码：空"，5/15/21/
  32/53/67/123/206 都不是"可安全创建的确定缺席"，保持 Unknown fail-closed。
- **status 语义扩展**：缓存失信现在计入 exit 1。十三轮判定其符合 README
  「exit 1 表示有事可做」，但 DESIGN §5.1 的 0/1/2 描述宜补一句——已登记。
- **未证实项**：8.3 短名、Unicode 兼容等价、保留设备名、云占位/Dedup 实际
  reparse 形态、能让 `canonicalizePath` 抛异常的输入、"可读内容但不可读
  attributes"的 ACL 库、`.pm` 的 UNC/断网形态。
- **慢介质开销**：每次 loader 一次深度 1 枚举 + 每状态文件逐级解析；备份发现
  对每个候选卷 `readRootInfo`。无超时，实测待用户插盘。
- `tamperMark` 字符串哨兵；`opSrcAbs` 无 root 归属校验；`writeConfig` 普通
  覆盖写；备份盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU。

---

> **第十四轮起见第二卷 [`2026-08-24-p3b-codex-review-2.md`](2026-08-24-p3b-codex-review-2.md)**
> （本文件触及 750 行预算，按 P3b-8 拆 §16 的先例续写）。残余清单以第二卷最新一轮为准。
