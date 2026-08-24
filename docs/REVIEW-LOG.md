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

同日 codex 八轮复审（attempt 1 即真跑，56 次命令执行，对 b502c0e）：1 critical +
4 major + 1 minor，核心指控是**限域判定的基准自身可能被劫持**——七轮学会了"问
操作系统目标在哪"，却仍默认 `root` / `.pm/trash` 这些 pm 自己拼出来的字符串是可
信基准。探针（Probe7/8）逐条核实，**五条全部成立、两条是数据丢失级**：把
`.pm/trash` 本身做成指向库外的 junction 后，`pathUnder` 两侧一起解析到库外、判定
通过，`removeFile` **真的删掉了库外文件**；`.pm/tmp/<plan>` 同形态让 doctor
`--repair` 删掉库外文件；`root/alias -> root/.pm` 让 root 级包含判定放行，可搬走
`root-id.json`；预置 hardlink 占用确定性 tmp 名后，`WriteMode` 截断写**覆盖了库外
文件的内容**（hardlink 不是 reparse point，逐级下降与 canonical 都看不见它）。
8.3 短名一条因本卷 `fsutil file queryshortname` 不支持而**无法证实**，按未证实归档
（修复面已覆盖其机制）→ **P3b-11 收口**（§10.2 P3b-11 条目）：`Pm.Win.resolveUnder`
逐级 no-follow 下降 + `pathAtOrUnder` 的 `.pm` 语义排除 + `openExclusiveBinary`
（`CREATE_NEW`）独占创建，三层各挡一类；`requirePmTrusted` 把 `.pm` 家族可信性
放进 `requireWritable`，一次判定覆盖全部 `.pm` 写入口。新增 6 测试（168/168）。

同日 codex 九轮复审（attempt 1 即真跑，104 次命令执行，对 b9a76e7）：1 critical +
4 major + 2 minor。核心指控是**闸只覆盖了固定路径层，而 pm 实际写的路径是动态
构造的**；外加一整类"失信方式"被漏掉——hardlink。探针（Probe9）核实：
`.pm/tmp` 是真目录（可信闸放行）而 `.pm/tmp/<planId>` 是 junction 时，Exec 的
tmp 残留 unlink **删掉了库外文件**；把 `.pm/journal.ndjson` 预置成库外对象的
hardlink 后，AppendMode 追加与覆盖写**都写到了库外对象**上。→ **P3b-12 收口**
（§10.2 P3b-12 条目）：动态 planId 层逐次 `resolveUnder`（创建目录前后各一次）；
`isNameSurrogate` 改按 reparse tag 的 name-surrogate 位判定（OneDrive 云占位 /
Dedup 等非重定向 reparse 不再被误拒——九轮同时点出的可用性回归）；
`openStateAppend` 用 link count 守 journal/manifest，plan 与侧缓存的覆盖写改成
"独占创建 tmp → 删旧 → no-replace 落位"；`RootIdState` 增 `RootUntrusted` 态并把
可信闸下沉进 `readRootState`，`pm init` / `pm backup init` / 首次 `vault push`
这三条**建立身份因而天然走不了 requireWritable** 的旁路一并覆盖，`createRootInfo`
自身再加一道；`pathAtOrUnder` 改三态，消除"解析不出 → 当作不在 .pm 里 → 放行"的
结构性 fail-open；`openExclusiveBinary` 补句柄异常清理；undo 拒绝无身份计划。
新增 5 测试（173/173）。

## P3b 逐轮收口（从 DESIGN.md §10.2 移入，2026-08-24）

- **P3b-4 评审收紧（2026-08-24，codex 6 major 全修复）**：
  ① supersede 组回滚复位目标被占（落位复核失败残留/竞态第三方文件）时，
  先把占位者 journaled 隔离到 `<pid>~displaced/`（`~d` opId 约定，
  `quarTrashRel` 下沉 Pm.Trash 供 Exec/doctor 共用推导）再复位 victim；
  落位后复核的 stat/hash 异常收进 OFailed 不再逃逸。
  ② I11 守卫升级为 `vaultIgnoreGuard`：`.git` 文件（worktree）、祖先仓
  （vault 非仓根一律拒）、`!` 反规则（可重新包含 .pm）全 fail-closed。
  ③ 执行期重检：ExecEnv 新增 `eePreflight` 钩子（锁内、journal/tmp/trash
  任何写入前），RoleVault root 的 apply 重跑 I11——计划生成与执行之间
  ignore 被改则整批拒绝。
  ④ 缓存身份绑定 + racy 判据：vault-cache meta 记录规范路径 + root UUID，
  不符即弃用；(size,mtime) 命中统一走 `statHitStable`（上次 hash 时刻须
  晚于 mtime 2 s 粒度余量，git racily-clean 同型；Scan 复用与 shaViaCache
  统一修）。
  ⑤ 读取不稳定名整体退出六态分类，新增 `unstable` 第八态（JSON 键殿后、
  退出码算差异、push 拒收）；顺带修掉 shaViaCache 告警直打 stdout 污染
  `--json` 的缺陷。
  ⑥ bindExecRoot 三槽位全查：UUID 命中 + role 与槽位相符、恰一命中才绑定，
  多命中（UUID 被复制/恢复）或 role 不符一律拒绝。
  评审归档：`docs/reviews/2026-08-24-p3b-codex-review.md`。
- **P3b-5 复审收口（同日，codex 二轮：5 PARTIAL + names/versions 3 major 1 minor）**：
  ① 位移隔离带尝试序号 `~d<N>` → `<pid>~displaced-<N>/`（重跑不与残留撞车）；
  占位者没挪开就不试复位；doctor 补 Q-DONE-LOST 的 Done 前核 sha；`~d` 永不
  进入 undo 序列。② 守卫先 `canonicalizePath`（junction 别名看不到真实祖先）、
  反规则检测 case-fold。③ 守卫下沉 `Pm.GitGuard`，Exec 按盘上 role **无条件**
  在锁内重检（`execPlan defaultExecEnv` 也绕不过），ExecEnv 钩子删除。
  ④ vault 缓存只在双方 root-id 皆存在且相等时复用（`Nothing==Nothing` 不算
  身份；root 建立前每次全量重 hash）；路径比较取 canonicalizePath 精确值。
  ⑥ 备份发现返回**全部** UUID 命中（`discoverBackupRoots`/`discoverAmong`），
  多命中即身份冲突拒绝；bindExecRoot 候选按 canonicalizePath 去重。
  B1 `requireRole RoleMain` 统一加到 scan/import/clean/names（配置主库路径指向
  备份/vault root 一律拒绝）；B2 目录指纹改为**递归**（类型/相对路径/大小/
  mtime，目录改名不变）——不含内容 hash（Raw 事件夹数十 GB，两次全量 hash 与
  收益不成比例，§14 残余风险登记）；B3 names 目标预检文件或目录皆算占用。
  B4（designedPair 排除过宽）**不成立**：豁免仅限恰两份的 成片↔相册 同名对，
  正是 I7 的设计拓扑，相册无「所属事件」概念。归档同上文件第二轮章节。
- **P3b-6 三轮收口（同日，codex 三轮：A1/A2/A3/B1 PARTIAL + 1 major + 1 minor；
  A4/A6/B2/B3 FIXED，B4 反驳被接受）**：
  A1 opId 后缀改 `Pm.Op.opIdParts` 严格解析（`<pid>#<ix>[~r|~d<N>]`，Trash/
  Undo/Doctor 共用，不再各自 `splitOn`/`isInfixOf "~d"`）；planId 生成格式
  `isValidPlanId` 在 `loadPlan`（含文件内 id 与文件名一致）与 `execPlan` 两处
  把关；位移槽位空检改 `doesPathExist`（目录/reparse point 占槽即跳下一槽）。
  A2 反规则白名单收紧：`!` 行含 `.pm`（case-fold）**或**通配符 `* ? [ \` 即
  拒绝——git 2.52 实测 `!.[p]m/**`、`!.p\m/**`、`!.?m/**`、`!.*/**` 都能重新
  包含 `.pm/`；真实 vault `.gitignore` 无 `!` 行，不受影响。
  A3 内核不再放行匿名 root（无 root-id 一律拒绝；测试 fixture 改为先写标识）；
  守卫改 `pmIgnoreGuard role` 对**所有** role 无条件执行（改写 marker role 无效）；
  并在**取锁之前**先做零写入预检——`withRootLock` 会先建 `.pm/lock`，git 树
  污染不该始于锁文件（锁内仍复检）。
  B1 `requireMain` 补齐 `computeVault`（相册源 + vault-cache）、`pm backup`、
  `pickRoot SelMain`（doctor --repair / trash empty / undo 的默认 root）、
  `pm init`（已有非 RoleMain 标识即拒，`--force` 不改写身份）。
  major：`pm init` 与 `backup init` 建 root 前走同一守卫（`initPreflight` /
  `backupInitPreflight`；`.git` 文件与祖先仓不再漏）。minor：`dirFingerprint`
  对 symlink/junction 记 `l` 条目不跟随（与 Scan 同策略），指回祖先的 junction
  不再无限递归；真实库无 reparse point，既有 names 计划指纹不变。
  `Pm.Commands` 触及 750 行预算 → 备份命令拆到 `Pm.BackupCmd`（Commands 再导出）。
  测试 +11（GuardTests，144/144）。归档同上文件第三轮章节。
- **P3b-7 四轮收口（同日，codex 四轮：A2/A3/minor/拆分 FIXED；A1/B1/major PARTIAL
  + 2 新 major）**：
  A1 `opIdParts` 只认规范十进制（`p#00`、`p#0~d01` 不是 pm 生成的）；`validatePlan`
  （id 格式 + `piIx` 非负唯一）在 loadPlan 与 execPlan（取锁前 + 锁内）共用；隔离
  目录改**构造式** `quarDirFor`（Exec 用），解析式 `quarTrashRel` 返回 Maybe——
  doctor 遇畸形 oid 报 `OID-MALFORMED` Bad、不推导不修，复位配对也走 opIdParts；
  位移槽「占用」补 lstat 语义（悬空 junction 下 `doesPathExist` 为 False，实测）。
  major `RootIdState` 区分缺席/损坏/存在：损坏标识 init/backup init/vault push 一律
  拒绝改写；首次建标识 `createRootInfo` 原子 no-replace（tmp → moveFileNoReplace）。
  新 major I11 覆盖全部 `.pm` 写入口：`requireWritable`（身份可解析 + 按盘上 role
  守卫）内嵌进 `requireRole`/`requireMain`；pickRoot 三槽位、savePlanAndMaybeRun、
  doctor --repair、resolve（先按 UUID 绑回 root 再验可写）、`pm backup` 的备份 root
  都过同一守卫。B1 `requireMain` 再补 apply 后备份缓存刷新（`afterApply`）、clean
  执行期复验、trash empty 的 clean-staging 屏障——配置主路径与备份盘同为
  RoleBackup 时不再自证三副本。测试 +7（151/151）。归档同上文件第四轮章节。
- **P3b-8 五轮收口（同日，codex 五轮：major/新 major 2 FIXED；A1/B1/测试 PARTIAL
  + 1 新 major + 2 新 minor）**：
  A1 `opIdParts` 的 planId 部分改为必须是生成格式（`isValidPlanId` 移入 `Pm.Op`，
  Plan 再导出）——此前只排除 `#`/`~`，手编 `../../outside#0` 能让 doctor 把
  trash/tmp 路径推到 root 之外；`readDigits` 加 18 位上限；`slotOccupied` 提为顶层，
  两个探测都包 try（非「不存在」异常按占用）。GHC 探针证伪两个子断言：`isDigit`
  只认 ASCII、`read` 越界静默回绕（已被 `show n == t` 拒绝）。B1 `runClean`/
  `runImport` 的 `requireRole RoleMain` 移到任何 catalog 读取与三副本判定之前，
  `runTrash` clean 分支先判 `requireMain` 再读主库侧。测试 fixture `ensureTestRoot`
  改走 `readRootState` + `createRootInfo`（损坏标识不覆盖）；journal fixture 一律用
  生成格式 pid。测试 +4（155/155）。归档同上文件第五轮章节；§16 评审摘要拆到
  `docs/REVIEW-LOG.md`。
- **P3b-9 六轮收口（同日，codex 六轮：A1/B1/文档 FIXED；余 1 新 major）**：
  Doctor 直接拼接手编 journal 的 Op 路径字段（合法 oid + `../../../x` 仍越出
  root 探测，--repair 可补 Done）；同类统一排查另发现 Exec 旧 relOk 挡不住
  `\evil`/`c:evil`（filepath 实测 `isRelative` 均 True 且 `</>` **整体替换**）与
  NTFS ADS，manifest 的 `trashRel` 被 trash empty **unlink**，Op 路径可指向
  `.pm` 内部。修复 = 共用谓词 `Pm.Op.relPathOk`（非空/非绝对/无 `:`/不以分隔符
  开头/无 `.`/`..` 分量）+ `opPathsOk`（`.pm` 内部拒，唯一例外 undo/复位 rename
  的 `.pm/trash/` 源）：validatePlan 加路径校验、execItem 换同谓词、Doctor
  classifyPending/verifyDone 前置 `OP-PATH` Bad + applyRepairs 双保险、
  readManifest 非法记录降损坏行。catalog `enPath` 的只读探测记为残余（写屏障
  在 validatePlan）。测试 +3（158/158）。归档同上文件第六轮章节。
- **P3b-10 七轮收口（同日，codex 七轮：1 FIXED / 8 PARTIAL / 1 NOT-FIXED +
  4 新发现）**：核心是**词法校验挡不住 Windows 规范化别名与 junction**。探针
  实测：`root </> ".PM" </> f` 与 `".pm." </> f` 都能读到 `.pm` 内文件（大小写
  不敏感 + 尾随点被剥），而 `.pm ` / `.. `（尾随空格）打不开（codex 该断言证伪）；
  trash 内 junction 下 `listDirectory` 穿透且 `removeFile` **真的删掉库外文件**。
  修复分两层：①词法 `Pm.Op.normComp`（折大小写 + 剥尾随点\/空格）收紧
  `relPathOk`\/`opPathsOk`；②真正动盘处 canonical 限域 `Pm.Win.pathUnder`
  （`canonicalizePath` 让操作系统回答路径究竟指向哪，覆盖 junction\/短名\/别名）
  —— 进 `pm trash empty` 的唯一 unlink、`Pm.Exec` 的 copy\/rename\/quarantine
  三个落位点（含 `.pm/trash` 例外的 rename 源）；`listTrashFiles` 遇 reparse
  point 不递归；`loadCatalog` 校验每条 `enPath`（真实库 4855 条零违规，非法即
  整份拒绝 → `pm scan` 重建）；`reverseOp`\/`pendingTmp` 补验。测试拆出
  `test/PathGuardTests.hs` 并 +4（162/162）。归档同上文件第七轮章节。
- **P3b-11 八轮收口（同日，codex 八轮：1 critical + 4 major + 1 minor）**：
  核心是**限域判定的基准自身可能被劫持**——七轮学会了问操作系统"目标在哪"，
  却仍默认 `root` / `.pm/trash` 这些 pm 拼出来的字符串可信。探针实测五条全部
  成立：`.pm/trash` 自身是 junction 时 `pathUnder` 两侧一起解析到库外、判定
  通过，`removeFile` **删掉了库外文件**；`.pm/tmp/<plan>` 同形态让 doctor
  `--repair` 删库外文件；`root/alias -> .pm` 让 root 级包含判定放行；预置
  hardlink 占住确定性 tmp 名后 `WriteMode` **覆盖了库外文件内容**。三层修复，
  各挡一类：①`Pm.Win.resolveUnder` 从基准逐分量 no-follow 下降，路上每一段
  都必须是盘上真名（挡 junction，含基准自身）；②`pathAtOrUnder` 做 `.pm`
  语义排除（挡 8.3 短名一类"不是 reparse point 但 canonical 后落进 `.pm`"的
  别名——本卷 `fsutil` 不支持短名查询，该形态**未证实**，按机制覆盖）；
  ③`openExclusiveBinary`（`CREATE_NEW`）独占创建，挡 hardlink（它既不是
  reparse point 也不改 canonical，前两层都看不见）。`requirePmTrusted` 把
  `.pm` 家族可信性并入 `requireWritable`，一次判定覆盖全部 `.pm` 写入口；
  `runTrash` 前置同一闸（基准被劫持时连读都不读）；`loadCatalog` 区分"半写可
  回退"与"语义非法整条链拒"。测试 +6（168/168）。归档同上文件第八轮章节。
- **P3b-12 九轮收口（同日，codex 九轮：1 critical + 4 major + 2 minor）**：
  核心是**闸只覆盖了固定路径层，而 pm 实际写的路径是动态构造的**；外加一整类
  失信方式被漏掉——hardlink。探针实证：`.pm/tmp` 是真目录（可信闸放行）而
  `.pm/tmp/<planId>` 是 junction 时，Exec 的 tmp 残留 unlink **删掉了库外文件**；
  把 `.pm/journal.ndjson` 预置成库外对象的 hardlink 后，AppendMode 追加与覆盖写
  **都写到了库外对象**上。修复：①动态 planId 层在创建目录前后各做一次
  `resolveUnder`；②`isNameSurrogate` 改按 reparse tag 的 name-surrogate 位判定
  ——OneDrive 云占位 / Dedup 等**不改变名字解析**的 reparse 不再被误拒（九轮同时
  点出的可用性回归，本机造不出这类对象，按规范判定并列残余）；③`openStateAppend`
  用 link count 守 journal/manifest，plan 与侧缓存的覆盖写改成「独占创建 tmp →
  删旧 → no-replace 落位」；④`RootIdState` 增 `RootUntrusted` 并把可信闸下沉进
  `readRootState`——`pm init` / `pm backup init` / 首次 `vault push` 这三条**建立
  身份因而天然走不了 `requireWritable`** 的旁路一并覆盖，`createRootInfo` 自身
  再加一道（测试实测它此前仍会把标识建到库外）；⑤`pathAtOrUnder` 改三态，消除
  「解析不出 → 当作不在 `.pm` 里 → 放行」的结构性 fail-open；⑥`openExclusiveBinary`
  补句柄异常清理；undo 拒绝无身份计划。新增 5 测试（173/173）。归档见
  `docs/reviews/2026-08-24-p3b-codex-review.md` 第九轮章节。
