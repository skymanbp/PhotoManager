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
这三条**建立身份因而天然走不了 requireWritable** 的旁路一并覆盖（**十轮更正**：`pm status` / `pm versions` 当时并未被它覆盖，
P3b-13 把闸下沉到 loader 才真正盖住），`createRootInfo`
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
  身份因而天然走不了 `requireWritable`** 的旁路一并覆盖（**十轮更正**：`pm status` / `pm versions` 当时并未被它覆盖，
P3b-13 把闸下沉到 loader 才真正盖住），`createRootInfo` 自身
  再加一道（测试实测它此前仍会把标识建到库外）；⑤`pathAtOrUnder` 改三态，消除
  「解析不出 → 当作不在 `.pm` 里 → 放行」的结构性 fail-open；⑥`openExclusiveBinary`
  补句柄异常清理；undo 拒绝无身份计划。新增 5 测试（173/173）。归档见
  `docs/reviews/2026-08-24-p3b-codex-review.md` 第九轮章节。
- **P3b-13 十轮收口（同日，codex 十轮：1 critical + 2 major + 若干 PARTIAL；
  它明确判「未收敛」并给出具体依据）**：核心是**我一直在用枚举定义可信集合，
  而枚举天然会漏**。前三轮每轮补一个子目录名（trash/tmp/plans），十轮点出
  `backup-cache` 与 `vault-cache` 从来不在名单里——把 `.pm/vault-cache` 做成
  junction 后，正常的 `pm vault status` 会删除并**替换库外**的
  catalog.json/meta.json（探针实证：库外两个文件都变成了 pm 写的内容）。
  修法不是再补一个名字：`requirePmTrusted` 改为**枚举 `.pm` 下实际存在的每个
  条目**逐一判定，pm 现有的、我漏掉的、将来新增的目录全部自动进入检查范围，
  "漏枚举"在结构上不再可能。同轮另两处：①闸下沉到 loader
  （`loadCatalog`/`readJournal`/`readManifest`/`loadPlan`）——命令层加闸盖不住
  `pm status`/`pm versions`/apply 的计划查找（**十一轮更正**：当时写的"每一次
  root-based 的 `.pm` 读取都经过 loader"不实——侧缓存读、trash 盘面遍历、doctor
  的 tmp 探测都不经过这四个 loader，P3b-14 的受信取用口才把状态文件读取真正
  收口）；②`writeSideCache` 从「给我一个目录」改成「给我 root + `.pm` 下
  的子目录名」，完整路径在建目录前后各验一次。另修：reparse 探测改
  Missing/Plain/Surrogate/Unknown 四态且 Unknown fail-closed（此前"不存在"与
  "ACL 拒绝"都塌缩成 False）；`reparseTag` 加 `mask`/`finally`（**十一轮更正**：
  当时把 `openExclusiveBinary` 也写成"已加 mask"，实际它只有逐段 `onException`，
  外层 mask 仍是已登记残余）；`admitsUserPath` 判据导出以便测试钉住真实代码。
  新增 3 测试（176/176），其中一条按十轮给的方法用 `CpCopyAfterIntent` 检查点
  在两次限域**之间**注入 junction，专门钉住建目录后的复检。
- **P3b-14 十一轮收口（同日，codex 十一轮：1 critical + 2 major + 1 minor +
  测试/文档各若干；仍判「未收敛」）**：三条实证缺口只有一个根因——pm 访问
  `.pm` 的模式是「拼路径字符串 → 校验字符串 → 再**按名字**打开」：①校验只到
  深度 1，`trash/manifest.ndjson`（深度 2）做成指向库外的**文件 symlink** 后，
  真实 `appendManifest` 把隔离记录**追加进了库外文件**（critical，Probe11）；
  ②字符串校验在原理上看不见 hardlink 而读侧没有 link count——hardlink 占名的
  catalog.json 被 `loadCatalog` **零警告载入**、`plans/<id>.json` 两种链接形态
  都让 `loadPlan` 载入**库外计划**（major×2，Probe11b）；③校验与打开是两次独立
  解析。修法把取用收成**唯一受信口**（`Pm.Config.readPmState` /
  `withPmStateAppend` / `readSideCache`）：完整相对路径逐级 `resolveUnder` →
  只打开一次 → 在**句柄**上查 link count → 从同一句柄读写。catalog 三代、
  journal、manifest、plan、root-id、两侧缓存读、lock 全部改道；`savePlan` 落位
  前对完整路径验一次。另修：`probeName` 的 Missing/Unknown 分辨改读
  `GetFileAttributesW` 失败时的 `GetLastError`（只有 2/3 算缺失，其余
  fail-closed——`doesPathExist` 二问会把 ACL 错误吞成"不存在"）；
  `requirePmTrusted` 四态分判 `.pm` 自身（普通文件不再被当"尚不存在"放行）；
  doctor 的 `staleTmpFiles` 判据从 `isNameSurrogate`（Unknown 算 False）改为仅
  `NamePlain` 放行，`--repair` 删除前对完整路径再过一次 `resolveUnder`。
  测试拆出 StateGuardTests（+5，181/181）：manifest 深层 symlink、catalog 读侧
  hardlink、plan 双形态、`.pm` 普通文件、侧缓存**文件级**链接（十一轮指出旧的
  目录级用例钉不住 `writeCacheFile` 的文件级复检）。归档见
  `docs/reviews/2026-08-24-p3b-codex-review.md` 第十一轮章节。
  （**十二轮更正**：当时 README/本条写的「lock 与全部状态入口改道」不实——
  收进受信口的是**读与追加**；`saveCatalog` 的轮转与 lock 的裸句柄仍按名字，
  由 P3b-15 收口。侧缓存读侧用例当时是**假绿**：库外 JSON 本就解不出 Catalog，
  删掉 link count 屏障照样通过，十二轮点出后已改为合法 Catalog + 突变验证。）
- **P3b-15 十二轮收口（同日，codex 十二轮：1 critical + 1 major + 3 minor；
  仍判「未收敛」）**：十一轮把**读/追加**收进了受信口，十二轮指出**同一类**的
  写与定点探测还在按名字操作 `.pm`——
  ①`saveCatalog` 的 tmp/base/.1/.2 轮转自身无任何解析（critical）：生产序列是
  「`loadCatalog` → 长扫描 → `saveCatalog`」（`Pm.Commands.runScan`、
  `Pm.BackupCmd`），扫描期间把 `.pm` 换成 junction，保存就会在**库外**建 tmp、
  删 `.2`、轮转 `.1`/base；②doctor 对 `.pm/trash` 载荷按名字 `doesFileExist` +
  `sha256File`（major）：载荷换成指向库外同内容文件的 hardlink 时 doctor
  「核验通过」，`--repair` 随即补写**虚假的 Done**，把从未落位的隔离认证成已
  完成；③`.pm/lock` 裸 `openBinaryFile`，hardlink 到库外文件即锁住共享对象；
  ④侧缓存读把失信压成缺席，而 `pm status` 只读无配对写侧，失信被显示成
  「未登记/未比对过」且可能 exit 0；⑤十一轮的侧缓存读侧用例是假绿。
  修复：`resolvePmPath`（使用点解析，`saveCatalog` 四条路径逐条解析后只用返回
  路径）、`Pm.Win.openStateLock`（句柄 link count）、doctor 的 `probePmSha`
  （完整路径 resolveUnder + `openStateRead` + **同句柄** `sha256Handle`，失信
  只报 `PM-LINK` Bad 且不参与任何 repair 推导）、`readSideCache` 保留
  `Either String (Maybe a)` 且 status 对 `Left` 报 ⚠ 并计入退出码。另修
  `probeName`：属性与 `GetLastError` 改由 `cbits/pm_win.c` **单次 FFI** 取得
  ——十二轮指出两次独立 FFI 在 threaded RTS 下可能跨 OS 线程，而 GetLastError
  是 per-OS-thread 的；这是把假设变成事实，而不是登记残余。
  测试 +3（184/184），并对本轮新屏障做突变验证（删屏障→用例转红）：
  saveCatalog 解析、lock link count、doctor 受信探测各自单独转红，删掉
  `openStateRead` 的 link count 则 4 例同时转红（含被修好的侧缓存读侧用例）。
  归档见 `docs/reviews/2026-08-24-p3b-codex-review.md` 第十二轮章节。
  （**十三轮更正**：当时写的"对**每条**新屏障做突变验证"过强——saveCatalog
  那条只钉住"四条解析全部撤回"，单撤一条时其余解析仍会在 `.pm` junction 上
  失败、用例照样绿；doctor 那条钉住 link count 但不钉"随后必须同句柄读"。
  P3b-16 已为每一代快照单独构造文件级链接用例并复验单撤一条即转红。）
- **P3b-16 十三轮收口（同日，codex 十三轮：1 major + 1 minor；仍判「未收敛」）**：
  major 是 `OpRename` 的**源**——`Pm.Op.isTrashSrcRel` 明确允许它落在
  `.pm/trash` 内（undo/组复位把隔离文件搬回原位，这是 pm 唯一允许 Op 触及
  `.pm` 内部的形态），而 `Pm.Doctor` 对它仍用裸 `existsAny`：把
  `.pm/trash/<pid>` 换成指向空目录的 junction，复位源被判成"不存在"，再让
  用户目标的指纹相符，就得到 R2 Warn，而 `repairDone` 的白名单收 R2 Warn ——
  `--repair` 随即补写**虚假的 Done**，把从未发生的复位认证成已完成。修复：
  `.pm` 侧走 `probePmExists`，失信只报 `PM-LINK` Bad（因此进不了 R 矩阵，也
  进不了 repairDone）；剥 `.pm` 前缀用分量剥离而非 `makeRelative`——
  `isTrashSrcRel` 是折大小写判定的，`.PM/trash/…` 会让词法剥离失效。
  **同轮做了类级修复**：`confinedTmp` / `confinedTrash` / 新增
  `confinedUserPath` 从返回 `Bool` 改为**返回解析后的路径**，Exec 的 tmp 落位、
  rename 两侧、quarantine 两侧一律只用返回值。返回 Bool 时调用方只能自己再拼
  一次名字——"校验的字符串"与"操作的对象"又成了两次独立解析，这正是十一~
  十三轮反复出现的同一形状；返回路径后调用方**无从**绕过。
  测试 +3（187/187）并逐条突变验证：撤复位源受信探测 / 撤 `probePmExists` /
  撤 status 失信退出码各自单独转红；另新增"每一代快照单独 symlink"的用例，
  单撤 `.1` 一条解析即转红（闭合十三轮 minor）。
  归档见 `docs/reviews/2026-08-24-p3b-codex-review.md` 第十三轮章节。
  （**十四轮更正**：上面"返回路径后调用方**无从**绕过"当时不实——Copy 的 dst
  预检仍是 Bool 版 `confinedUser`，之后两次重拼 `root </> opDstRel`。P3b-17
  删掉 Bool 版、dst 也走返回路径后，这句才在签名上成立。另：P3b-16 的
  `probePmExists` 把复位源的存在性从"文件或目录"收窄成"文件"，是它自己引入
  的 major，见下。）
- **P3b-17 十四轮收口（同日，codex 十四轮：1 major；⑤ 类清单**首次为空**，
  收敛性判「已收敛」但 verdict 仍 NO-GO）**：major 出在 P3b-16 自己的修复里——
  把复位源的 `existsAny`（文件**或**目录）换成受信探针 `probePmExists` 时只
  写了 `doesFileExist`，**谓词在安全重构里被悄悄收窄**。`OpRename` 两侧合法
  可为目录（`Pm.Names` 的 Raw 事件夹改名是 FpDir，执行端确实 stat/hash/move
  目录），于是 trash 里**真实存在的目录**复位源被判成"不存在"：修前该格是
  R3 Warn（不在 `repairDone` 白名单），修后与存在且指纹相符的 new 组成
  R2 Warn（在白名单）→ `--repair` 补写**虚假 Done**；另一格从 R1 Info 掉成
  R? Bad。codex 给的触发路径是 FpDir；核实两处复位构造点（`Pm.Undo`、
  `Pm.Exec.restoreQuarantine`）都只产 FpFileSha——但**不需要** FpDir：trash
  里一个占了载荷名的目录 + victim 原位 sha 相符即可触发。
  **类级扫描**："安全重构时谓词被悄悄收窄"——把 P3b-14~16 三轮 diff 里所有被
  受信探针/取用口替换掉的原谓词逐条比宽度，共 8 处，只有这一处从"文件或目录"
  收成"文件"，其余替换前后同宽。修复：`probePmExists` 加 `PmEntryQ`
  两态，调用点**显式**说明问哪种存在（复位源 `PmEntryAny`，tmp 落位点
  `PmEntryFile`——那是 pm 自建的普通文件，`staleTmpFiles` 也只收 NamePlain）。
  同轮采纳十四轮 #2 的建议删掉 Bool 版 `confinedUser`：它与 `confinedUserPath`
  逐行等价却是重复实现，Copy 的 dst 现在从 `confinedUserPath` 的返回路径一路
  传到 `execCopyTmp`，后者不再持有 `root`（没有 root 就拼不出第二条 dst）。
  测试 +2（189/189）：FpDir 与 FpFileSha 两形态**拆成两个用例**（同一函数里前
  一条先炸后一条永远跑不到，等于没钉——十三轮的粒度教训），把探针改回
  `PmEntryFile` 两条同时转红、实得恰为 `[("R2",Warn)]`。
  **登记而未做**：十四轮 #3 指出没有用例钉住"返回路径必须被使用"（把
  `tmpAbs` 改回 `tdir </> tname`、或 dst 改回重拼，现有用例照样绿）；它给的
  设计是让 root 本身成可切换的 junction、在 Intent 后检查点切到诱饵库——
  `resolveUnder` 以 root 为基准逐级下降，root 自身是 junction 时的行为要先
  探针，本轮不做、进残余。
  归档见 `docs/reviews/2026-08-24-p3b-codex-review-2.md`（第二卷，第十四轮起；
  第一卷触及 750 行预算）。
- **P3b-17b 十五轮文档收口（同日，codex 十五轮：0 代码缺陷 + 2 文档 minor）**：
  十五轮判两条代码判据（按名字操作 / 谓词宽度——后者它**独立**复扫）**均已
  收敛**、无新运行时缺陷、"无需代码修复"；NO-GO 只因①第二卷谓词表漏列
  `readJournal` 的旧 `doesFileExist`（同宽；已按删除的谓词实现点逐文件重列），
  ②README 的 P3b-16 条目仍称"调用方只能用返回值"、与 P3b-17 删 Bool 版矛盾
  （已加同样的「十四轮更正」）。它还给了"返回路径必须被使用"用例的可行设计
  （`resolveUnder` 不对 base 调 `probeName`，root 本身可为 junction，在
  `CpCopyAfterFlush` 改指诱饵库）——登记未做。代码零变化，189/189，0.3.15。
- **P3b-18 十四轮 #3 残余闭合（同日，用户裁定"等待期间做"；非评审轮）**：
  用例 `caseCopyDstUsesResolvedPath`（StateGuardTests）——`rootLink` junction
  指向库 A，以 `rootLink` 为 root 执行一条 Copy；在 `CpCopyAfterFlush`（tmp 已
  写完、落位 move 之前）删除并重建 junction 改指诱饵库 B（同身份、同目录结构，
  让重拼版实现能"顺利"落到 B，失败原因只可能是用了哪条路径）。断言：ODone、
  文件在 A、B 零改动。**突变**：`execCopy` 把传给 `execCopy'` 的 dst 改回
  `root </> opDstRel op`（P3b-17 之前的形状）→ 用例 FAIL（`doesFileExist
  (libA </> dstRel)` 得 False，文件落到了 B）。平台前提经用例内直接执行实证：
  A 内 journal/lock 句柄打开期间 junction 可删除重建，已打开句柄继续指向 A。
  +1 例（190/190），警告 0，pm 0.3.16。在独立 worktree（分支
  `p3b18-returned-path`）开发，不污染十六轮正在读的工作树；进入十七轮范围。
- **P3b-17c 十六轮文档收口（同日，codex 十六轮，额度重置后重跑：0 代码缺陷 +
  1 文档 minor）**：十六轮确认 `46c4d12..ca260cb` 代码零变化、**维持十五轮
  "两条判据已收敛"的判定**；NO-GO 只因第二卷谓词表的排除说明把 `newEx`
  （实为 `existsAny`）、`raced`（实为 `doesFileExist`）说成 `doesPathExist`，
  且把已**扩宽**的 `slotOccupied` 说成仅移动——与 `git diff` 删除行逐行对照
  成立，已逐项标注类型并说明排除理由。与 P3b-18 同在分支 `p3b18-returned-path`
  上，一并合并进 main，进入十七轮范围。
- **十七轮：GO（同日，codex 十七轮，对 ca260cb..324501e，64 次探查）**——
  "生产逻辑未变、十六轮 minor 已闭合、P3b-18 钉住既定回退突变、两条判据继续
  收敛；新发现无；最小修复集空"。P3b 门禁自一轮以来首个 GO。它对新用例的
  细评：不覆盖三处单点突变（落位前 dst 预检 / 目标缺席不执行的 sha 分支 /
  move 失败分支的 race 探测）；Rename/Quarantine 对称用例属已登记残余、非阻断
  （Quarantine 优先）。真实库只读四连不变（doctor 0 / trash 0 / status 1 /
  vault 1）。归档见第二卷第十七轮章节。**门禁满足，转 AskUserQuestion 请裁定
  `pm apply 20260824-030200-0c238a`。**
- **真实写入（同日，用户裁定"全量执行"）**：`pm apply 20260824-030200-0c238a`
  6/6 DONE（1071 ms）；盘上目录名核实；`pm doctor` 0；`pm status` "✓ 索引与
  磁盘一致"（无需重扫）。pm 对真实库的第一次 names 写入，`pm undo` 可回滚。
  P3 至此只剩等外部条件的项：备份盘（插盘）、15 NEW 分类（P4 GUI）、versions
  处置（用户）。

## P4 GUI（2026-08-24 起）

- **改判（用户 AskUserQuestion）**：GUI 改 Rust + Tauri v2 + 纯静态 HTML，内核
  保持 Haskell；本机 cargo/rustc 1.94.1、tauri-cli 2.11.4、WebView2 151、
  VS2022 BuildTools 均已在，.NET SDK 不在——8/22 的 C#/Java 与"装 .NET SDK"
  作废。DESIGN §0/§4/§11/§14/§15 已改。
- **P4-1 `pm serve`（pm 0.4.0，196/196）**：`src/Pm/Serve.hs`——显式
  `SockAddrInet 127.0.0.1` 绑定（端口 0 = 内核随机，`socketPort` 读回）、启动时
  stdout 一行 `{"port","token"}`；token = crypton 16 字节熵 hex，`constEq` 常量
  时间比对；`Host` 须 `127.0.0.1[:port]`（DNS rebinding）；`Origin` 只认 Tauri
  来源，预检 OPTIONS 免 token。只读端点：ping / status[?fresh=1] / vault status
  （JSON 载荷与 `--json` 相同——**十八轮更正**：当时少 CLI 的末尾 LF，"逐字节
  相同"不成立，P4-2 已追加 LF 并加字节用例）/ plans / plan/<id> / thumb/<sha>（只提供
  catalog 里 JPEG 条目原字节；enPath 来自 loadCatalog 校验）。`Pm.Status` 拆成
  `statusReport`（ToJSON，含退出码）+ `renderStatus`，`runStatus` 组合二者，
  文本逐行同 P3b。`listPlans` 经 requirePmTrusted + 完整路径 resolveUnder，
  文件名先过 isValidPlanId 再走 loadPlan 受信取用口。测试 6 例用 wai-extra
  `Network.Wai.Test` 直接打 Application；**突变**：去 token 判定 / 去 Host 判定
  / 去 Origin 白名单 / thumb 不限 JPEG / plan id 不验格式 → 五次各自恰好一例
  转红（token / Host / Origin / thumb / plans）。真实库冒烟：无 token 401、错
  token 401、Host 伪造 403、Origin 非法 403、预检 204；status 4855 文件 exit 1
  （同 CLI）；plans 8；plan 0c238a 6 items；thumb 4 120 421 B 首字节 ffd8ff；
  `netstat` 只见 `127.0.0.1:<port>`。**没有写端点**——apply / 分类推送留到 GUI
  骨架之后，先过 codex 评审再请用户裁定。交 codex 十八轮首评。
- **P4-2/3 Tauri GUI 骨架 + `pm ui`（pm 0.4.1，197/197）**：`gui/src-tauri`
  （Rust，`cargo tauri init --ci` 模板裁剪：桌面端 crate-type 只留 rlib，
  bundle 关闭，只留四个图标）+ `gui/ui`（纯静态 HTML/JS/CSS，无 npm）。Rust
  侧 `lib.rs` 只做三件事：spawn `pm serve --exit-on-stdin-eof`（stdin 接从不写
  的管道、stdout 读 announce 行）、`api_info` command 把 port/token 交给页面、
  `RunEvent::Exit` 时 kill 子进程；`PM_EXE` 环境变量指定 pm.exe（`pm ui` 设置
  为自身路径）。页面三页：仪表盘（/api/status）、计划（/api/plans + /api/plan）、
  分类（/api/vault/status + 新端点 **/api/vault/new** 把 NEW 名字配上主库
  catalog 的 sha/size，缩略图经 fetch→blob，因 `<img src>` 带不了 Authorization）。
  serve 新开关 `--exit-on-stdin-eof`（`race` server 与 stdin EOF）：直接实测
  `( sleep 3 ) | pm serve --exit-on-stdin-eof` 3170 ms 退出、不带开关时 stdin
  关闭不影响；GUI 冒烟：pm-ui 拉起后新增 127.0.0.1 监听，**只杀 pm-ui（不带
  /T）→ 500 ms 内监听消失、pm.exe 零残留**（P4-2 初次冒烟曾出现孤儿 serve，
  根因是我用 `ps -W` 找不到 pm-ui.exe 没杀到第一个实例——但这暴露了"GUI 异常
  死亡则 serve 成孤儿"的真实风险，开关就是为此加的）。`hostOk` 按十八轮中途
  指出改为精确解析（`127.0.0.1` 或 `127.0.0.1:<1-5 位数字>`），+5 断言，突变回
  前缀判定即转红。工具链：本机默认 `x86_64-pc-windows-gnu`，Tauri 需 MSVC——
  用已装的 `x86_64-pc-windows-msvc` 目标构建（gnu 下 cdylib "export ordinal
  too large"）。`pm ui` 找不到 pm-ui.exe 时列出查过的路径、exit 2。**写端点仍
  未开**：分类页无提交按钮。在 worktree `p4-2-gui` 开发，待十八轮结论后合并。
- **十八轮：GO（同日，codex 十八轮首评 P4-1，5813081..7464780，186 次探查；
  "未发现 critical/major"，4 minor + 1 残余硬化建议）**，全部在同一分支闭合
  （200/200）：①`hostOk` 前缀判定放过 `127.0.0.1:1@evil`（它说明这不构成浏览器
  DNS-rebinding 绕过，且仍须 token）→ 精确解析，+5 断言，突变回前缀即转红；
  ②`--port 65536` 在 `fromIntegral` 到 `PortNumber` 时静默折回 → `portOk`
  0..65535，越界 exit 2；③"与 `--json` 字节相同"忽略了 CLI `putStrLn` 的末尾
  LF → API 追加 LF，新增用例用同一 `renderVaultJson` 独立算期望再逐字节比对，
  去掉 LF 即转红；④两个并发 `/api/vault/status` 争用固定缓存 tmp 名可能 500 →
  `ServeEnv.seVaultLock` 进程内互斥串行化（`serveApp` 改收 `ServeEnv`）；
  ⑤残余硬化 thumb：enPath 只过词法闸，扫描后条目被换成库外 symlink 时按名字
  readFile 会跟随 → 读取前逐级 `resolveUnder` 只读返回路径，新增用例把
  `相册/a.jpg` 换成指向库外 secret 的文件 symlink → 404 且库外字节不外泄，
  删掉那次解析即转红。它另确认：显式 `SockAddrInet 127.0.0.1` 是唯一 bind、
  warp `runSettingsSocket` 不会再按 `settingsHost` 开 0.0.0.0；warp 3.4.9 锁定
  默认值（连接超时 30 s、HTTP/1 头上限 50 KiB、无总 body 上限——只读端点不读
  body，未来写端点须另加应用级大小与执行超时）；Status 重构与基线逐行同义；
  `Network.Wai.Test` 不经 socket/warp 解析/超时/连接复用，建议 P4-3 前补一条
  真开端口的 raw HTTP 冒烟（登记，未做——目前靠人工 netstat 冒烟）。
  归档见第二卷第十八轮章节。
- **十九轮：GO（同日，codex 十九轮审 P4-2/3 + 十八轮闭合，7464780..da07eae，
  252 次探查；"未发现 critical/major"，2 minor）**：十八轮五项全部 FIXED；GUI
  边界确认（Rust 侧只有 spawn/api_info/kill、无 `std::fs`、唯一 Command 参数是
  `serve --exit-on-stdin-eof`；`PM_EXE` 在 §14 模型下不要求限制；`api_info` 只对
  本地页面可调、CSP 由 Tauri 注入——它读了本地 tauri/wry 源码取证；页面无 XSS
  sink、无 POST）。minor ①app.js blob URL 不 revoke → **已修**（每轮 URL 记录、
  重建网格前逐个 revoke）；minor ②**跨进程** vault-cache 刷新争用固定 `.tmp`
  （GUI serve 与另一个 `pm vault status` 同时刷新）→ 进程内 MVar 挡不住，需
  跨进程句柄锁并把 catalog/meta 当同一临界区，**登记为残余**。合并前最小修复集
  空。归档见第二卷第十九轮章节。**下一步：请用户开窗验收 GUI 三页，再裁定是否
  开写端点。**
- **用户开窗验收（同日）**：①bug——分类页往下滚动后缩略图消失；②"需要更加清晰
  更加优雅的 UX，让用户能够快速上手并进行实用的功能，以及直观的可视化"；③追加：
  一眼看明白的"状态"可视化——vault 同步状况与差哪些 / Raw·成片·相册各层状态 /
  备份硬盘同步状态；④裁定写端点：**开，先做"生成计划"端点，apply 端点后置**。
- **P4-4/5（pm 0.4.2，202/202）**：**P4-5 写端点**——`--writable`（缺省只读，
  `pm ui` 置位）；`POST /api/vault/push-plan`：`readBodyCapped` 64 KiB（413）→
  JSON（400）→ 与 CLI 共用的 `checkAssignments`（400 + 全部错误）→
  `vaultPushItems` / `mkVaultPushPlan`（从 `runVaultPush` 抽出，CLI 行为不变，
  VaultTests 原集合通过）→ `requireWritable` → `savePlan`；响应含计划/路径/
  `pm apply` 提示/git 步骤。测试 +2：闸用例（只读 403、坏 JSON/空/非法类目/非
  NEW 400、70 KiB 413、GET 404、之后 vault `.pm` 不出现）与合法用例（计划落到
  `<vault>/.pm/plans`，`loadPlan` 装回，dst = `portrait/a.jpg`、sha 一致，照片与
  vault 类目目录零改动）；突变：去 `--writable` 闸 / 体上限失效 / 跳过指派校验
  → 闸用例各自转红、合法用例不受影响。**P4-4 UX**——`ui/` 重写（见 DESIGN §11）；
  缩略图消失的根因：相册原图 1.2–75.9 MB（94 张共 2.5 GB），15 张 NEW 全分辨率
  解码的位图撑爆 WebView，被丢弃后不再重绘——改为 GUI 侧 `createImageBitmap`
  按 640 px 解码缩放再挂上；截图自验：分类页 END 滚到底 15 张全在。渲染验证工具
  `scratchpad/shot.ps1`（`SetProcessDPIAware` 后 `GetWindowRect` + `CopyFromScreen`，
  否则显示缩放下截到错位区域）+ `tour.ps1`（只在 pm 窗口确为前台时 SendKeys
  切页——第一版没校验前台，一个 "2" 可能打进了当时前台的窗口，已改）。
- **二十轮：GO（同日，codex 二十轮审 P4-4/5，aa21b37..5fd42f5；"未发现
  critical/major"，合并前最小修复集**空**，6 minor）**：写端点边界成立——
  `--writable` 判定在读体、缓存刷新与任何 vault 写入之前，只读 serve 下 POST
  零写入；`readBodyCapped` 逐块读到首次超过 64 KiB 即停（它读了本地 warp 3.4.9
  源码：默认最多为 keep-alive 回收 8192 字节，剩余更大则直接关连接，不会读完
  巨大剩余体）；aeson 2.2.5.0 重复键取首值、默认无嵌套深度计数（读源码取证）；
  抽出的 `checkAssignments`/`vaultPushItems`/`mkVaultPushPlan` 与 aa21b37 的
  `runVaultPush` 逐行等价，DRIFT 仍以 NEEDS-DECISION 进计划；页面 POST 只由
  按钮触发、响应只进 `textContent`，无 XSS sink。6 minor 中 5 条**已修**（同一
  name 重复指派、DRIFT-only 出不了计划、缩放失败回退原图、连按键并发加载、
  首次建 root 的并发 500），第 6 条（JSON 重复键 / 深嵌套）**登记残余**。
  归档见第二卷第二十轮章节。
- **P4-6（pm 0.4.3，203/203，GHC 警告 0）**：二十轮五条 minor 的收口（见
  DESIGN §11 P4-6 条）+ 打包发布（NSIS 安装包 + sidecar `pm.exe` + 免安装 zip；
  `pm_exe()` 查找顺序补"同目录"）+ README 按"个人自用、但公开"的定位重写。
  突变：去掉重复指派判定 → 闸用例 `ServeTests.hs:407` 转红（400→200）；把空
  指派改回无条件 400 → DRIFT 用例 `ServeTests.hs:477` 转红（200→400）；两次
  另一条用例都保持绿——单点粒度成立。**更正**：上一轮我报"警告 0"时读的是
  `tail -45` 截断过的日志，实际存量一条 `-Wdeprecations`（`BS.hGetLine`），
  本轮已修并改用完整日志核对。
- **P4-7（pm 0.4.4，206/206，GHC 警告 0）——第九态 HELD「暂不同步」**：用户在
  v0.4.3 发布后裁定"这 15 张暂时先不同步，另给一个专门放决定不同步的照片的
  分类"。设计要点：它**不能**是 vault 的第四个类目（vault 类目 = 展示集 git 仓
  的目录，建目录等于把照片发出去），因此是主库 `.pm/vault-holds.json` 里的
  本地决定；`new` 键不动（对外契约），`newActive` 扣掉 HELD 并据此算退出码；
  记录存决定当时的 sha，**下一次比对**复核到字节已变即失效回到 NEW（复核
  **强制重算** sha，不吃
  `(size,mtime)` 缓存快路——二十一轮指出走快路时等长替换 + 还原 mtime 会让旧
  决定继续生效）；`checkAssignments` 拒收 held 文件。新模块 `Pm.VaultHold`（状态 + 纯分类器 `splitHeld`）与 `Pm.VaultCmd`
  （命令层——`Pm.Vault` 触及 750 行预算，同 `Pm.BackupCmd` 先例），`Pm.Config`
  加 `writePmState`（`readPmState` 的对偶：完整路径解析 → 独占 tmp → flush →
  no-replace rename）。第二个写端点 `POST /api/vault/hold` 与 CLI 共用
  `holdRequest`。突变四道：`newActive` 不再扣 HELD → 往返用例 + 端点用例转红；
  `splitHeld` 不比对 sha → 失效用例转红；端点去 `seWritable` 闸 → 端点用例转红；
  `checkAssignments` 不拒 held → 往返 + 端点用例转红。**待 codex 二十一轮评审**；
  真实库那 15 张的 hold 在 GO 之后才执行。
- **二十一轮：NO-GO → 已收口（同日，codex 审 P4-7，40d6ee4..262c2f6，64 次探查）**：
  两条 major + 一条进了最小修复集的 minor，均已修并各自突变验证。①**复核吃了
  缓存快路**：`splitHeld` 的比对 sha 取自 `srcShas`，而 `shaViaCache` 在
  `(size,mtime,lastVerified)` 命中时直接复用主库 catalog 的 sha——等长替换 +
  还原 mtime 即可让旧决定继续压住新字节 → 改为对"名单里且仍是 NEW"的文件用空
  缓存强制重读（真实 hash + 双 stat），读不稳定按失效处理。②**名单读改写不是
  跨进程事务**：serve 的进程内 MVar 挡不住第二个 pm 进程，两边各读旧名单、后写
  者整份覆盖 → 抽出事务壳 `withHoldsTxn`，整段 compute→读→校验→写在主库
  `.pm/lock`（I10）里完成，锁被占 CLI exit 2 / API 409。③**残留 `.tmp` 被当成
  空名单**：覆盖写崩在删旧与 rename 之间会留下 `vault-holds.json.tmp` 而正文
  缺失，按"没有决定"继续等于静默清零 → `readHolds` 对这一形态 fail-closed，并
  补名字/sha/唯一性的语义校验。另修四条 minor：`runVaultPush` 的无项分支仍用旧
  `hasDiff`（held-only 时误报 exit 1）→ 与 `hasDiffR` 统一后**删除** `hasDiff`
  这个同构谓词；缓存 meta 加 `vmHeld`，`pm status` 的 vault 行按 NEW − HELD 报；
  GUI 提交期间冻结选择并按响应推进 `heldInitial`（第一步落盘、第二步失败后重试
  不再重复撤销）；`loadVault` 的失败分支也认 single-flight 代号。文档口径按第 8
  条修正（README 的两段式例外与 `--writable` 写域、CLI help、§11 九态、I8 退出
  码语义、REVIEW-LOG 的"字节一变即失效"）。210 测试。
- **二十二轮：NO-GO → 已收口（同日，codex 审二十一轮的收口，262c2f6..6cfd990）**：
  两条 major。①**上一轮只修了一半**——复核强制重 hash 了，`holdRequest` 的
  **创建**仍从 `vrSrcMeta` 取 catalog 缓存 sha：陈旧 catalog + 等长替换 + 还原
  mtime 时，hold 记下旧 sha、命令报成功，下一轮复核立刻判失效，决定永远落不住。
  修法是抽出唯一取法 `freshShaAt`/`freshSrcSha`（空缓存必走真实重读 + 双 stat），
  创建与复核共用；`holdRequest` 改收**已重算**的 sha，IO 外壳 `holdOpsIO` 给
  CLI 与 API 共用。②**取锁在身份预检之前**：`withRootLock` 会先建 `.pm` 并开
  `.pm/lock`，匿名 / I11 失效的 root 因此先落锁文件再被拒 → 取锁前加只读
  `requireMain` 预检（锁内复检保留），与 `Pm.Exec` 同序。另修三条 minor：
  delete→rename 窗口里"正文与 tmp 都缺失"再读一次正文消歧；提交期间导航与
  数字键不得重入 `loadVault`、`vaultDrift` 进快照；文档六处过度声明（含我在
  二十一轮归档里自己写过头的两格）。212 测试，三处突变各自转红。
- **二十三轮：GO（最小修复集空，codex 审二十二轮的收口，6cfd990..4cf718a）**：
  两条必修均确认闭合——创建与复核共用 `freshSrcSha` 的真实 SHA；`requireMain`
  只走读路径且在取锁前，匿名库不会先落下 `.pm/lock`。它从源码推演确认了
  `caseHoldCreateFreshSha` 的构造（`lastVerified` = mtime + 1h 满足
  `statHitStable` 的 2 s 余量）在旧实现下必转红。3 minor 已修：`freshShaAt` 外层
  捕 `IOException`（扫描后文件被删/被占不再让 CLI 崩、API 500）；README/DESIGN
  的轮次与例数过期；GUI 计划页与安装包描述仍称"写盘一律两段式"未区分 hold。
  残余照旧登记（正常覆盖写窗口的读竞态、跨进程锁只用同进程线程代表、API 409
  与旧 meta 解码无用例、名字规范化硬化）。**真实写入**：用户裁定的 15 张
  `pm vault hold` 已执行，名单 15 条、照片与 vault 仓零改动（212 测试，pm 0.4.4）。
- **P4-8（pm 0.4.5，215/215，GHC 警告 0）——GUI 设置页 + 配置端点**：用户裁定
  "GUI 里可以设置各种目录路径"，范围＝vault / 备份盘 / photos.json / 并发数可改，
  **主库路径只读**（身份锚点，改它等于换一个库）。三端点 `GET /api/config`
  （健康视图）、`POST /api/config`（三态补丁）、`POST /api/backup-init`（与 CLI
  共用 `backupInitRun`——为此把它拆成"结果 + 渲染"，同 `Pm.Status` 先例）；CLI
  对称 `pm config` / `pm config set` 共用 `checkPatch`/`applyPatch`。serve 的
  配置改 `IORef` 每请求读一次；`writeConfig` 改原子替换。突变四道各自转红：
  去 `--writable` 闸、去"主库只读"判定、去 vault 目录存在性判定、去写后刷新
  `IORef`。
  **事故与根因（要记住）**：跑第三道突变时写端点被放行，测试 fixture 的临时
  路径**当场覆盖了使用者本机的真实 `config.toml`**（主库被写成临时目录）。已按
  实测输出复原（主库/vault 路径确定；photos.json 由此前 `BLOCKED(photos.json:208)`
  与该文件第 208 行的 URL 精确对上；`workers` 原值无从考证，现为未设＝默认核数）。
  根因不是那条突变，而是**配置路径是机器全局的，测试里任何一次写成功都会打到
  它**：`configFilePath` 加 `PM_CONFIG` 覆盖，`Spec.hs` 把整个测试进程指到临时
  文件，物理上断掉这条路。收敛性证据：同一条突变重放，真实 config.toml 的
  sha256 前后一致。
- **P4-8b（pm 0.4.6，219/219，GHC 警告 0）——codex 二十四轮 GO，最小修复集空**：
  6 条 minor 全部收口，其中 4 条同一个根因——**配置文件不在任何 root 的 `.pm`
  下，于是一条写纪律都没继承**（pm 里唯一一个裸 `writeFile` 的状态写入口）。
  按类一次扫干净：①`writeConfig` 改 `openFreshBinary` + `flushHandleToDisk` +
  no-replace 改名（裸 `writeFile` 会穿透 `config.toml.tmp` 名上的 hardlink，把
  字节写进库外的共享对象）；②新增 `withConfigLock`（`config.toml.lock` 上
  `hTryLock`，机制同 I10）罩住读→改→写→读回，三条读改写路径（`pm config set`、
  `POST /api/config`、登记备份盘）共用，拿不到锁 → 409 / 退出码 2；③`loadConfig`
  认出"崩在删旧与改名之间"留下的 `.tmp` 并给恢复动作，不当"配置不存在 → 去
  pm init"；④登记备份盘原先 `_ <- writeConfig` 把失败吞了（盘上标识建好而配置
  没记上），现在报出去，且建标识在前、登记在后 → 重跑走 `BiReused` 幂等。
  另两条：`"main": null` 曾被 aeson 的 `.:?` 折成"键缺省"而静默放行
  （`{"main":null,"workers":3}` 会改 workers 并回 200，正好绕开这个字段唯一的
  用途）——`main` 改用与另外三项同一个三态解析，出现即拒；GUI 写成功后若刷新
  失败会把横幅改回"没改成"（提交结果与刷新状态现在分开报），并发数文案也改正
  （只管扫描；备份盘默认单线程防 HDD 寻道抖动）。评审另指出 `backupInitRun` 的
  注释称 preflight"含 requireMain"而实际未调用，已更正。
  四道新闸各自突变转红：`fld "main"` 回 `.:?` / 去配置锁 / `writeConfig` 回裸
  `writeFile` / 去 `.tmp` 探测——各红且**只红**对应那一条。碰全局配置的用例收进
  `dependentTestGroup` 串行执行（`PM_CONFIG` 是进程级的，tasty 缺省并行会互踩）。
  **文档回归（本轮自查发现，不是评审报的）**：上一提交为压 DESIGN 的 750 行
  预算把 P4-6 收口散文移进本文件时，**连同刚插入的 P4-8 设计段一起删掉了**，
  而提交信息写着"DESIGN §11 gained the settings-page and PM_CONFIG paragraphs"
  ——实测 HEAD 版 DESIGN 里"设置页 / PM_CONFIG"零命中，GUI 页数也仍写四页。已补
  回三段并改正页数。教训：压行数预算的删改要与同一轮的新增分两步做、各自复验。
