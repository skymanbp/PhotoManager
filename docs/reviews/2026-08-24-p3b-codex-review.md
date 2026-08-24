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
