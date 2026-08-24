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
