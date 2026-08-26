# pm 评审记录（现行卷：第 29 轮起）

> 从 `docs/DESIGN.md` §16 拆出（2026-08-24）；2026-08-26 再拆一次（本文件触及
> 750 行预算）：**v0.1→v0.2 设计评审、P3b 逐轮收口、P4 GUI、用户决策记录**
> 在 [`REVIEW-LOG-1.md`](REVIEW-LOG-1.md)（冻结史料）；每轮评审的逐条处置表在
> [`docs/reviews/`](reviews/)。本文件只装 P5/P6 时代（第 29 轮起）的评审段。

## 第 29 轮（P5-B…F 六个提交）——NO-GO 7 条，**逐条独立核实后**处置

评审自陈沙箱里跑不了 `stack test`，结论是静态源码评审。7 条因此全部送并行
独立核实（每条一个 agent，判成 CONFIRMED 的再过一遍对抗复核 agent），核实
提示词要求分清三件事：**代码事实成立** / **已登记残余** / **威胁模型内可达**。
核下来行号系统性不准（#1 全错、#5 差 20 行、#6 差 28 行、#2 把
`copyFileHashed` 的 dst 侧说反了），但其中一条是真的、且比它自己描述的更容易
触发。

**7 条塌缩成 3 个根**——这是本轮方法上的主要收获：逐条修会重复第 27/28 轮
「同形状只扫了一半」的错误。

### 根 A（#3，critical，成立且对抗复核未能驳倒）→ 已修

**执行期组屏障跑在 root 锁外。** `preExecFor` 在 `Cli.hs` / `Commands.hs` /
`Serve.hs` 三处都在 `execPlan` **之前**调用，而锁在 `execPlan'` 里面
（全库 `withRootLock` 只有 `Exec.hs` 与 `VaultCmd.hs` 两处）；锁内只复核
victim 自己的 sha，从不重算「该 sha 在归档层还留一份」。

对抗复核给出的触发路径比原 finding 更省：**一份计划就够**——两个终端各跑
`pm apply <同一 id> --only 1` 与 `--only 2`。`applyOnlyToPlan` 把未选中项改写
成 `StSkippedByUser`，而 `recheckDedupeItems` 的 victims 只取 `StPending`，
于是双方各自看见对方那份还活着，双双放行，只需 2 份副本。

后果不是字节丢失（`pm trash empty` 的 `BArchiveCopyLeft` 屏障会让三条全部
HELD，`pm undo` 可逐条搬回），是 DESIGN-COMMANDS §8.1 的不变量被破坏 +
照片从库里静默消失，因此判 major 而非 critical。**不是已登记残余**：§14 的
残余段只点名 `MoveFileEx`/`RemoveDirectory`，且那一段的对手是恶意进程；本条
的两个行为体都是良性 pm 进程，正是 §14 明写要防、I10 负责的那一类。相反，
DESIGN-COMMANDS §10 记的二十一轮裁定（vault-holds 名单的「读→校验→写」整段
进 I10 锁）与本条**同形**，等于反证它偏离了已确立的纪律。

**修法**：屏障装进 `ExecEnv.eeBarrier`，由内核在 `withRootLock` 内调用。
「哪些种类要屏障」提成 `Pm.Plan.kindNeedsBarrier`（内核与命令层读同一张表），
**该有而没有 = 整批拒绝**——P3b-5/A3 的教训在这里的落法不是把闸搬进内核
（内核算不出「归档层还剩几份」），而是让**缺席本身**成为硬失败。内核还核对
屏障只做了降级：把条目升级回 `pending` 或改写 Op 一律整批拒绝。
装配点收成一处（`executePlanNowWith`），三处调用点里的 `preExecFor` 全部删除，
`savePlanAndMaybeRunWith` 一并删除——「传哪个钩子」不再是调用方的决定。

**同根第二处（rule 09 统一修复）**：`pm trash empty` 是 pm 全程唯一 unlink
用户数据的路径，它的屏障判据与 `removeFile` 之间同样全程不取锁。整段
（判定 → 列表 → unlink）搬进 `withRootLock`；`--yes` 是命令行开关而非交互
提问，锁内不会停下来等人。

**四道新闸各自突变转红（4/4，每次恰好一个用例）**：缺屏障改成静默放行 →
`caseKernelRefusesMissingBarrier`；屏障搬回锁外 → `caseBarrierRunsInsideLock`
（该用例在屏障里再取一次同一把锁，`withRootLock` 不可重入，取得到就说明在
锁外）；去掉「不许升级回 pending」→ `caseBarrierMayNotPromote`；trash empty
去掉取锁 → `caseTrashEmptyTakesLock`。

内核的 fail-closed 当场抓到第一个真实调用者：`PlannerTests` 那条端到端用例
用 `defaultExecEnv` 执行 `clean-staging` 计划。它考的是 Quarantine 落 trash 的
机制而非三副本屏障，改为显式挂 `Just pure`——**显式**正是这次改动要的效果。

### 根 B（#1 #2 #5 #6，4 条）→ 一行代码 + 作用域文档

四条攻击的是同一句**无限定**的声称：§14「取用口（读、追加、加锁、内容探测）
走 `openBoundTo`」。事实上走它的只有 `.pm` 状态文件的三个打开口与
`probeConfined`；Exec 三条 Op 的用户数据内容读仍是裸 `withBinaryFile`。
一句没有限定词的绝对化保证会**每一轮生出一批 finding**，这才是根因。

- **#2 thumb（唯一的代码改动）**：`GET /api/thumb` 在 `resolveUnder` 之后按
  名字 `BS.readFile`，而该端点的既定意图已被用例钉成「库外字节不外泄」。
  改走 `openBoundTo ReadMode`。#2 里关于 EXIF 的那一半**证伪**：
  `readCaptureTime` 的唯一调用者是 `Pm.Sort.readTimes`，入参来自库外源目录，
  全程没有 `resolveUnder`，也没有任何限域承诺；「扫描的 EXIF 读取」更是纯错误
  （`Pm.Scan` 不读 EXIF）。改它反而会把「源根自身是 junction」这一合法用法判死。
- **#1 Exec 的 `sha256File`**：代码事实成立，但绑定读口**不改变可利用性**——
  三条路径的形状都是「读 sha 当闸 → 紧接着对同一路径 `moveFileNoReplace`」，
  赢得下读那一跳的攻击者同样赢得下 move 那一跳，后果由 move 产生。换成
  `openBoundTo` 只会造出"读口已关"的假象。登记残余。
- **#5 `handleIsAt` 的手写规范化**、**#6 `openFreshBinary` / trash unlink 的
  名字口**：登记残余（#6 的后果本就已在 §14 逐字登记）。

§14 因此改写成**带作用域的保证 + 六条逐项登记的残余**，让下一位评审有东西可
**核对**而不是有东西可**攻击**。§6.7 并发防护同时补上「判据与动盘是同一个
跨进程事务」这一条纪律。

### 根 C（#4）→ 只改文档

`FileId` 确实是 32 位卷序列号 + 64 位索引，不是 ReFS 的 128 位 `FILE_ID_INFO`
（实测：Win32-2.14.1.0 的 `.hi` 里对 `FILE_ID_INFO` / `getFileInformationByHandleEx`
零命中，换过去要新写 FFI）。但**风险方向反了**：窄化是一个函数，只可能把两个
不同对象并成一个（→ 多拒一次 HELD），数学上产不出「把同一个对象拆成两个」
因而放行最后一份。方向与 `nlink == 1` 判据相同，按同样写法把「为什么不换
FFI」钉在 DESIGN-COMMANDS §8.1 原地。

### #7 证伪

「静音 stdout 吞掉端口冲突」不成立：`bindLoopback` 在 `bracket` 的 **acquire**
位（`Serve.hs:181`），`muteStdout` 在 body 里（`Serve.hs:193`），端口冲突必然
发生在静音之前。GUI 那一侧把原始行原样嵌进自己的错误消息经 stderr 报出。

### 核实顺带捞出、评审没报的两条

1. **`purgeBarriers` 与 `recheckCleanItems` 对「读不到 victim 身份」处置不
   一致**：前者 `excl = []` 继续，后者 fail-closed 判否。**分析后判定非隐患**：
   trash 载荷不在归档层路径上，排除集只影响「归档层某文件与载荷同身份」这一
   种情形，而那种情形下删掉 trash 那个名字，字节仍活在归档层的名字下。
   `excl = []` 在此是**正确**而非放松。记录在案，不改。
2. `pm trash empty` 不取锁 —— 已随根 A 一并修（见上）。

**281 tests（277 + 4 新），GHC warnings 0。**

## 第 30 轮（P5-G `c978d88`）——NO-GO 5 条，minset 3 条全修，聚类 4 根

本轮换了评审跑法（五镜头逐个走 + 每条 finding 强制四段式带逐字引用 + 按根因
聚类 + minset 判据"代码事实成立 ∧ 未登记 ∧ 模型内可达"三条同时成立）。效果
立竿见影：五条全部第一方核实成立，行号零偏差，无一条为凑数——与第 29 轮
（7 条里行号系统性不准、5 条不该进 minset）对比鲜明。评审自陈沙箱写不了
`C:\sr\pantry`，`stack test` 没跑成，静态核验。

### 聚类根 1（F1+F2，minset）：root 事务边界由调用点手工拼装，证据落在锁外

P5-G 把屏障搬进锁，但只搬了它点名的那两处——同形状的还有四处，本轮一次扫完
（rule 09 统一修复）。共同修法：**证据在锁内取**。

- **F1** `pm trash empty`：manifest 视图（`trashView`）还在锁外——我在第 29 轮
  处置里写的「整段（判定 → 列表 → unlink）搬进 withRootLock」**言过其实**，
  实际搬的是视图**之后**的整段。A 锁外取旧视图、B 锁内清掉某项、A 拿到锁按
  旧视图走到 `removeFile` 在缺失项上炸。修：`trashEmptyLocked` 自己在锁内读
  视图；`pm trash list` 保持只读咨询不取锁（同 `pm status`）。
- **F2a** `pm resolve`：「装载 → 改 → 写回」全程无锁——两个 resolve 各批不同
  条目，后保存者整份抹掉先保存者的裁决（与二十一轮 vault-holds 名单同形）。
  修：`resolveOn` 整段进 I10 锁并**锁内重载**盘上计划；锁外那份只用于按 UUID
  发现 root（线索不是证据）。
- **F2b** catalog 回写：execPlan 释放锁后 `load → update → save` 无锁，两次
  apply 的后写者基于旧快照整份覆盖先写者。修：`writeBackCatalog` 自己取锁做
  完整 RMW；锁被占则**明说**放弃（catalog 是 pm scan 可重建的缓存，滞后可
  接受，静默丢更新不可以）。
- **F2c** doctor `--repair`：判定视图（journal/tmp 枚举）在锁外取，另一份已
  批准计划可在判定与补记之间把世界改掉，doctor 随后补写过时 Done。修：整段
  进锁，次序与 execPlan 相同（先零写入预检、root 不可写连锁文件都不落；锁内
  requireWritable 复检保留）；锁被占退回只读诊断 + 一条 I10 Bad，不做任何修复。

### 聚类根 2（F3，minset）：配置模块仍允许裸 writeConfig

`pm init --force` 是配置的第四条读改写路径，唯独它没进 `withConfigLock`——
A 锁外读旧配置、B 锁内登记备份盘、A 无锁写回，登记被静默抹掉。修：init 的
「查存在 → 读旧配置(mold) → 写回」整段进配置锁、锁内重读；root 标识创建
不动配置文件，拆成 `initMarker` 留在锁外。P4-8 写的「三条读改写路径」穷尽
声明由此更正为四条。

### 聚类根 3（F4，residual → 本轮顺手关掉一半）：屏障协议未由类型封闭

`barrierDrift` 此前不比对计划元数据，屏障改写 `plId` 会让 journal 的 opId 与
旧计划碰撞（plId 参与 opId/tmp/trash 路径推导）。当前第一方屏障只碰
`plItems`，模型内不可达——但协议该冻结的是**能改什么**而不是对实现的信任。
修：元数据五元组（id/kind/root/rootId/created）一并冻结，改写即整批拒绝。
两半表（`kindNeedsBarrier` ⟺ `preExecFor`）的一致性已由 casePreExecRow 逐
kind 钉住。残余登记：更彻底的形态是单一 BarrierKind 分类器 + 屏障只返回
「状态降级映射」而非完整 Plan——留作下一次触碰这段代码时的方向，不为它
单开一轮。

### 聚类根 4（F5，DOC_ONLY）：文档从旧实现复制了错误概括

两处**处置有误**，都出自我第 29 轮写的文档，本轮更正：①§14 残余第 2 条把
Copy 的落点读混进"读后紧跟 move"——Copy 的同内容判定没有后续 move，伪造相等
只会让该次 Copy 静默跳过（落点空着、旧字节在 trash，doctor 可见）；②§8.1
还写着"hardlink 被 openStateRead 的 link count 判定拒掉"，那是二十八轮 #2
**之前**的行为，现行判据是 FileId 身份排除，合法 hardlink 见证算数。

### 收敛证据

**六道新闸各自突变转红（6/6，每次恰好一个用例）**：视图搬回锁外 →
caseTrashEmptyTakesLock（坏行警告在锁被占时被打印）；resolve 去锁 →
caseResolveTakesLock（裁决在锁被占时落盘）；catalog 回写去锁 →
caseCatalogWriteBackTakesLock；doctor 去锁 → caseDoctorRepairTakesLock
（孤儿 tmp 在锁被占时被删）；init 去配置锁 → caseInitTakesConfigLock；
barrierDrift 放掉元数据比对 → caseBarrierMetaFrozen。

**286 tests（281 + 5 新），GHC warnings 0。**`captureStdout` 从 SortTests 移入
TestUtil（进程级 stdout 重定向，多模块共用；套件本就 NumThreads 1）。

## 第 31 轮（P5-H `92cd567`）——NO-GO 1 条，minset 1 条已修

五镜头把 P5-H 的五处修复全部验干净（无死锁、降级路径口径一致、五条新用例的
锁闸断言成立——含正确指出 caseTrashEmptyTakesLock 的"坏行警告不出现"证明只对
本次突变成立、不是对任意未来实现的通用证明，这正是突变验证的定义），只捞出
一条未登记同形状：

**F1 侧缓存成对写未进 root 锁（已修）**。`writeSideCache`（catalog.json +
meta.json 成对）全链无锁：两次 `pm backup`、或 backup 与 afterApply 交错，
后写者按旧快照回写，得到 catalog 与 meta 不配对的缓存。backup-cache 未登记
（vault-cache 的跨进程争用在**十九轮**登记过残余——三十二轮更正，此前误记
二十轮）。统一修复：成对写整段进 I10 锁——**一处锁两类同享**，vault-cache
那条登记残余随之关闭。

落地时踩到并解决了两件评审预判过的事：①`Pm.Lock` 依赖 `Pm.Config`，锁原语
只能下沉进 Config（`Pm.Lock` 保留为再导出，全部既有调用点零改动）；
②vault-holds 事务（二十一轮裁定的锁内整段）在锁内经 `computeVault` 走到缓存
写——嵌套取锁必失败。**不做"已持锁变体"**（调用方会撒谎），改为三态返回
`CacheWritten | CacheLockBusy | CacheRefused`：锁被占（含自持）降级为"缓存
本轮不刷新"——缓存可由下一次命令重建，报告本身是本轮新算的；junction 拒绝
仍硬停（P3b-13 不变）。降级的可见性分工（三十二轮核对：此前这里的"警告"
一词只兑现了一半）：backup 侧（refreshBackupCache）打 ⚠ 提示；vault 侧按
设计**静默**——自持情形每次 hold/unhold 必然命中，逐次提示是噪声，取舍登记
在 Vault.hs 消费点上方的注释里。压成一个 Left 的代价在测试里当场显形：全部
hold 用例 exit 2。

突变验证：writeSideCache 去锁 → caseSideCacheTakesLock 恰好转红（1/286）。

评审另列两条已登记残余（scan/backup 的 saveCatalog 固定 .tmp 竞态、
vault-cache——后者本轮已顺带关闭），及一条覆盖边界（catalog 回写用例未压两个
真实 writer 的合并语义）。286 tests，GHC 警告 0。

## 第 32 轮（P6-A/B/C/D 四提交 `1bdbe92 6e5e68c 5d8deea d5aff24`）——29 条，minset 4 根全修

**门禁执行者切换（通道事故）**：codex 中转站连续 4 次空跑（第一变体：模型
工具表缺 exec，零 command_execution，第 4 次连结果字节都没有）→ fallback 为
独立多代理 Workflow（`wf_150b83b1-85e`）：五镜头各自真读四个提交（行号必须
来自实际 sed 输出），每条可行动 finding 再过一个对抗复核代理。复核跑到第 8 个
撞上月度用量限额，剩余 9 条（R1-R9）的对抗复核由主线**第一手**完成：逐行
读码 + 探针（Win32 failIfWithRetry 装机源码逐字、makeAbsolute 归一 runghc
实测、clang struct 布局）。codex 恢复后的交叉复核（498 次命令）读到的是已
含修复的树——它准确认出这一点（对照 git show HEAD），逐行核验 9 处修法全部
背书（R1-R7/R9 判「按现行树驳倒」= 修复成立），并抓到一条真实残口
**R8-weakened：HELD 名单比较是精确大小写**——ingest 的新闸与 push 侧同病，
大小写变体可绕过「暂不同步」决定。处置：ingest 侧立即 case-fold（非交互
入口，绕过即静默发布；用例补 HELD.JPG 变体）；push 侧维持精确匹配并在此
登记——那是 P4-7 的失效语义（名字变了 → 决定失效 → 照片浮回 NEW 且
`pm vault status` 单列失效原因，重新要人裁决，不会静默发布），case-only
rename 落进同一格是保守方向。下一轮起 codex 评审对象一律钉在提交 SHA。

**产出与裁决**：五镜头 29 条（FFI 4 / 屏障协议 3 / 锁语义 4 / ingest 9 /
文档口径 9）。对抗复核驳倒 2 条降为 DOC（p6b#0 vault 侧 CacheLockBusy 静默
——规范文本从无"警告"承诺、消费点注释已登记取舍；docs#1 `--finalize`——拆分
方案在 §10.3 自己的下文登记过两处）；其余成立。minset（代码事实成立 ∧ 未登记
∧ 模型内可达）聚 **4 根、10 处修复**：

- **根 A：ingest 的完成判据一码三义**（R4/R5/p6d#2，三条互相放大——R4 造出
  未执行的裁决项、R5 把源移走、裁决从此无法执行）。上游修法：`savePlanAndMaybeRun'`
  回 `PlanRun` 三态（未存盘/存而未执/已执行+逐项结局）；vault 那份只在主库
  那份 `fullyExecuted`（逐项 DONE/同内容 SKIP，**不是**退出码 0——
  ONotExecuted 不进退出码）后执行；预览两份计划**都**存盘（两段式对两份同样
  成立，此前预览面缺一半且文案把"已存盘"说成"未完成"）；生成期把主库待裁决
  耦合到 vault 同名项（单独 apply pidV 无法先于相册落同名字节）；收尾步骤
  （move 进 _done）只在两份都落完时打印（与 push 的 `when (code==0)` 同闸）。
- **根 B：ingest 缺与 push 对齐的闸**（R6/R7/p6d#5/#6）：`requireMain`（此前
  只 readRootInfo，配置指错到 backup/vault root 照写）、批内重名 case-fold
  （与 Names 同口径）、跨类目占名（否则造出退出码不可见的 DUPLICATE）、
  「暂不同步」名单（push 被 HELD 挡，非交互入口不得更松）、源双 stat（§6.7，
  与 Scan.hs hashOne 同形——_inbox 正是还在写入的目录，单 stat 会误诊成介质
  问题）。全部进 validateIngest 一次列完；requireMain 提到 ensureVaultRoot
  之前（身份不对的一跑不留任何写痕）。
- **根 C：句柄化丢掉名字口原语内建的鲁棒性**（R1/R2）：被替换的
  moveFileEx/deleteFile 在 Win32 里都经 failIfWithRetry（err 32 → 100ms×20，
  KB 316609，杀毒/索引器短暂持有）——`withDisposeHandle` 一次就报错是未登记的
  行为回归，重试预算按原样搬到打开步（重试重跑的是**打开**；回调含先验在
  **最终成功句柄**上执行一次，先验校验的正是最终句柄——三十三轮 F2 更正本段
  此前「先验逐次重跑」的措辞）；同函数的裸 HANDLE 获取补 mask（同模块第三次
  出现的漏句柄形态，照 reparseTag 判例）。
- **根 D：比较规范化上了提交路而路径入口未归一**（R3）：`rawBoundTo` 与
  `handleIsAt` 共用手写 normPath，`PM_CONFIG` 是唯一不经 canonicalize 的
  入口——正斜杠/相对拼写会被句柄后验当成链接攻击拒绝，且首败残留 .tmp 卡死
  后续所有配置写。源头归一：`configFilePath` 对环境变量 `makeAbsolute`
  （runghc 实测两种拼写都归一到反斜杠绝对形）。

**残余处置**：p6a#0（BarrierKind→实现映射无用例，RHS 对调全绿）→ 不登记，
直接关闭：casePreExecRow 补按**降级理由**区分两个屏障的断言；p6b#1（成对写
的锁只串行化写者：掉电可留跨代对，换 vault 再换回时旧 meta 会放行新 catalog，
兜底是 sha 复用前的逐条 (size,mtime)+racy 复验）→ DESIGN §6.7 登记；预览
两段式下 pidV 可被先于 pidM apply（I7 短暂逆序，vault status 的 MISSING 可见，
pidM 落完即收敛；打印明示次序 + 待裁决项已耦合）→ 本节登记。

**文档统一修**（docs-vs-code 九条 + 各镜头 DOC 项，全部落地）：DESIGN
§6.1/6.2/6.3 落位原语与后验/回迁终态、§4 依赖行、I7/I10 行、§5 ingest 行、
§11 vault-cache 锁语义、§14 第 1 条措辞与第 4 条作用域、风险表三行；
DESIGN-COMMANDS §8.1 按类型封闭改写（kindNeedsBarrier/barrierDrift 死符号
清除）、§10.3 第 1 项 `--finalize` 改显式步骤、第 2 项 ✅ 降为「记录侧 ✅/
判定侧 ⏸」（doctor 的 inbox-origin 判定零代码，DESIGN I7 行与风险表同步
降级）；HISTORY 的 removeFile 实数 7→9 与 P6-A 措辞；本文件 31 轮节两处
更正（十九轮/警告分工）；源码注释 8 处死符号或过强措辞（Win.hs 模块头与
取用口边界、Config/Plan/Trash/Main/TestUtil/DedupeTests）。「漏写编译不过」
统一更正为「-Wall 警告 + 运行期锁内硬崩」（项目无 -Werror）。

**收敛证据**：298 tests（293+5：ingest 3 新 + R1 重试 + R3 归一），GHC 警告
0；变异 **11/11 各杀恰好一个用例**（三十三轮 F3 更正：此前此处误记 10/10——
主循环 10 项：R4 闸/R5 闸/requireMain/case-fold/跨类目/HELD/I7 耦合/预览
两段式/err-32 重试/PM_CONFIG 归一，加交叉复核后补验的 HELD case-fold 共 11；
运行记录在会话 scratchpad `mut32-results.txt` + m12 单跑输出）。R2 的 mask 与
R9 的双 stat 无确定性触发形态、不可变异验证，如实登记为评审核验项（后者与
Scan.hs hashOne 逐字同形）。本文件触及 750 行预算 → 拆卷：29 轮前史料移
[`REVIEW-LOG-1.md`](REVIEW-LOG-1.md)（**正文**纯字节搬移、拼接校验等于原文；
两卷各加数行卷首说明——三十三轮按实况精化措辞）。

## 第 33 轮（P6-E `314efe6`，codex 钉 SHA）——NO-GO，minset 1 条已修

codex 恢复后的首轮**钉 SHA**评审（260 次命令，attempt 1 即真跑；上一轮交叉
复核读活树的教训落进流程）。五镜头把第 32 轮四根修复全部验干净：PlanRun
三态穷尽、`planRunCode` 逐位保持旧 Int 契约、`fullyExecuted [] = False` 无
协议洞、ingest 各分支退出码与次序正确、耦合只降级、重试只对 err 32、mask
覆盖完整、configFilePath 归一不伤既有可用值、§6 新文字与 Exec 一致。minset
恰一条：

**F1 ingest 生成期 IO 异常逃顶（已修）**。probe 的 statSnap/sha256File 与
mkItem 的目标 sha256File 都无 try——`doesFileExist` 通过后源/目标被良性
进程移走/占住，异常直接逃到无顶层 handler 的 main，CLI 崩溃而非干净报错
（违反 §14 防崩溃；可用性损失，无字节风险）。与 pm sort 二十五轮确立的
「逐文件 try，读取失败整批拒绝」同一纪律——ingest 新代码漏了同款。修：
probe 逐文件 try + mkItem 改回 Either，错误聚合一次列完、退出 2、零计划；
过深嵌套顺手拆出 `runTwoPlans`。用例 caseIngestUnreadable 用独占句柄
（FILE_SHARE_NONE：存在性探测按属性照常 True、ReadMode 打开必抛）造确定性
占用，源/目标两侧各断言；变异 2/2（去 probe try / 去 mkItem try 各恰好
转红该用例——Ingest 变异无依赖路径影响其它 F1 字样用例）。

另两条 DOC 当轮修：**F2** Win.hs 重试注释「先验逐次重跑」措辞过强——真实
语义是重试重跑**打开**、回调含先验在最终句柄上执行一次（保证不削弱），注释
与本文件 32 轮节已同步更正；**F3** 变异计数 REVIEW-LOG/HISTORY 的 10/10 与
提交信息的 11/11 矛盾——真值 11，两处文档已统一并注明运行记录出处；拆卷
「纯搬移」措辞按实况精化。residuals 与第 32 轮登记一致，无新增。

299 tests（298+1），GHC 警告 0。

## 第 34 轮（P6-F `972b049`，独立 Workflow 钉 SHA）——NO-GO，minset 2 条已修

codex 通道再度 4/4 空跑（工具表缺 exec、0 条命令执行，stderr 刷
`OutputTextDelta without active item`；零 exec 判据丢弃，占位 verdict 不算
评审），按第 32 轮先例切独立多代理 Workflow：三镜头（F1 修法完整性与同类
扫尽 / runTwoPlans 拆分等价性 / 文档与事实）+ 逐条对抗复核，全部钉
`972b049`。拆分等价性镜头**零 finding**（删除侧与新增侧去缩进 diff，36 行
中 34 行逐字节相同；两组「同类型相邻可静默互换」参数位逐字核实未换；
`null dstErrs` 的求值语义保证 zipWith 无截断）。minset 2 条，同一根因——
**二十五/三十三轮立的「读口 fail-closed」纪律从未全仓扫**，三十三轮只扫了
ingest 生成期：

**F1 computeVault' 主循环读口无 try（已修，复核 UPHELD）**：`resolve`
（枚举-hash 主循环）裸调 shaViaCache，而同一函数在 `freshShaAt` 里被 try
包着、注释写明要防的正是「CLI 抛异常退出、API 变 500」——二十三轮只修了
那一个调用点，全模块唯一的 try 就是它（复核 grep 证实），顶层无 handler，
分钟级扫描窗口内 Lightroom/用户挪走一张即崩、Serve 侧 500。修：resolve 包
try → 读失败落既有 unstable 桶（sha 分量下游处处被 Just 模式滤掉，空值
安全）；同族两口一并——`listFlatPhotos` Either 化（枚举失败整体拒绝
exit 2：静默空列表会把另一侧伪报成 MISSING，比崩溃更糟）、`photosJsonRef`
Either 化（读不出**不得**答「未被引用」——fail-open 会诱导改名打断已上线
URL）。用例 caseUnstableOnLocked（独占句柄 → UNSTABLE 单列 + exit 1 +
可读文件照常分类 + 不入 vrSrcMeta）与 casePhotosJsonRefLocked。

**F2 Exec 裸 sha256File ×5（已修，复核 UPHELD 且扩大战果）**：镜头报
「:522 是唯一漏的」，复核证伪——裸口共 **5** 处（copy I5 判定 / tmp 复读 /
rename 指纹（连带 dirFingerprint）/ quarantine 重跑判定 / quarantine
victim），其中 3 处与三十三轮刚修的 mkItem 逐字同形。复核另更正镜头两处
过头：「计划文件不更新」不是本次损失（savePlan 在执行前），丢的
writeBackCatalog 按 Cli 注释属良性滞后。修：5 处逐口 try——本模块既有形态
（moveBound/落位复核早就是 JFailed + OFailed）；读失败 ≠ 内容不符，给
OFailed（稍后重跑）不折叠成 OConflict（人工核查）；Checkpoint 逃逸契约
不受影响（try 只包读口，不包 eeCheckpoint）。用例 copy-dst-locked /
rename-fp-locked / quarantine-victim-locked。

**同类扫尽（rule 09，超出镜头范围的第一方普查）**：全仓 grep
sha256File/dirFingerprint/listDirectory/BS.readFile 邻域逐处分类。已在
try 内（不动）：Scan.hashOne、Sort.snapshotWith、Ingest（三十三轮）、
probeConfined、Doctor.probePmSha、slotOccupied。本轮补修：Doctor 6 处
（C2/C5 判定 → 新 Bad 行「C?」、Q2 note、verifyFp Either 化 + R2 调用点、
C4 checkTarget、deepVerify、--repair 的 C5 计划生成跳过）——读失败
Finding 一律不落 --repair 白名单（C2/R2/Q-DONE-LOST 的 Warn）也不落 C5
行，不触发任何修复推导；resolveKeep --keep src 的 dst sha（读不出 →
resolve 未执行 exit 2，不落半个改写）；Names 生成期 dirFingerprint
（逐项 try + 一次列完 + 零计划 exit 2，与 ingest 同纪律）。用例
doctor-deep-locked（其余见下「无确定性用例」登记）。

**F3 caseIngestUnreadable c2 断言不判别（复核 REFUTED，不进修集）**：
复核证伪其「无信号」主张——同案 c1 钉着同一平台前提的**反面**
（doesFileExist 改判 False 会让 c1 当场红，c2 根本跑不到），守卫不会
静默失去覆盖；「validateIngest 顺序调整可触发」亦假（重排不改变存在性
判定）。按复核建议登记取舍：**源侧判别力由同案 c1 的反向前提兜底**；
其原建议的 "读取失败" 断言锚与 Ingest 的「名单读取失败」共享子串，本身
不够判别，不采纳。

**DOC ×2（当轮修）**：README 三格收敛数字落后一轮（298 例/32 轮/6+1+11
——上一次收口提交恰是在这三行上维护的，git log -L 证实）+ §具体实现第 6
条「三十轮」漂移；HISTORY 缺 P6-F 条目且标题仍写 P0–P5（P6-A 起既存
漂移）——两处已随本轮收口一并补齐。

**新登记残余**：①执行期**写口**（copyFileHashed / setModificationTime /
createDirectoryIfMissing / hash 失配分支的 deleteBoundAt）异常逃逸 =
§6.4 进程死亡语义——journal 已有 Intent，doctor 对账，属已设计行为而非
缺陷；代价是一个占用中止整批（读口本轮已修掉这个代价；写口失败本就意味着
该项无法完成，且 moveBoundNoReplace 自带 err-32 重试预算）。②本轮新 try
中无确定性注入形态的：Exec tmp 复读与 quarantine 重跑分支、Doctor 的
C?/Q2/R2/C4/C5 五处、resolveKeep、Names 指纹、listFlatPhotos 枚举——注入
需要协议中途独占或重 fixture，登记为代码级核查，与有用例的 6 道同型同修法
（R2/R9 先例）。③SomeException 宽口（Sort/Scan/Win 约 20 处既有形态，
与 Hash.hs「只捕 IOException」家规不一致）——非本轮引入，登记待后续轮
裁定是否收窄。

**750 行预算引发的拆分（全部字节级搬移 + 原模块再导出，行为零改动；
下一轮 refactor-equiv 镜头素材）**：Pm.VaultCore（六态纯核心 +JSON 渲染）、
Pm.ExecTypes（Checkpoint/ExecEnv/ItemOutcome/updateCatalog）、
dirFingerprint → Pm.Hash、Pm.Apply（undo/apply/resolve 族 + pickRoot——
Commands 本已超预算，resolve 读口修改无处容身）、VaultHoldTests（P4-7
用例整族）+ 共享 fixture（mkVaultCfg/writeF/mkMain/execNow）上移 TestUtil。

**收敛证据**：305 tests（299+6），GHC 警告 0；变异 **6/6 各杀恰好一个
用例**（m15 resolve try / m16 photosJsonRef fail-closed / m17 copy-dst /
m18 rename-fp / m19 quarantine-victim / m20 deepVerify；运行记录在会话
scratchpad `mut34-results.txt`）。
