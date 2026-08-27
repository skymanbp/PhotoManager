# pm 评审记录（现行卷：第 39 轮起）

> 从 `docs/DESIGN.md` §16 拆出（2026-08-24）；因 750 行预算多次分卷：
> **v0.1→v0.2 设计评审、P3b 逐轮收口**在 [`REVIEW-LOG-1.md`](REVIEW-LOG-1.md)，
> **P4 GUI 与用户决策记录**在 [`REVIEW-LOG-1B.md`](REVIEW-LOG-1B.md)；**第 29–34 轮（P5 后期→P6 中期）**在
> [`REVIEW-LOG-2.md`](REVIEW-LOG-2.md)（2026-08-26 拆出）；**第 35–38 轮与
> P7 预审登记**在 [`REVIEW-LOG-3.md`](REVIEW-LOG-3.md)（2026-08-27 拆出）；每轮评审的逐条
> 处置表在 [`docs/reviews/`](reviews/)。本文件装第 35 轮起的评审段。

## 第 39 轮（P7-F `76eaaa2` 送审，codex 钉 SHA）——NO-GO，minset 6 条全修（P7-G）

attempt 1 即真跑（188 次命令执行，watchdog 三判据全过）。六条第一方全部
核实成立（#2/#3 各有实证探针：PowerShell 双引号内 `$()` 确实展开、含 `'`
路径写盘后 TOML 解码确实失败且 configTxn 已换正式文件）：

1. **freshnessSweep 基准两态 + 遍历错误无子树覆盖（major）**：基准目录被拒
   时 doesDirectoryExist 塌 False → catalog 空则全零（stagingFresh 放行，
   fail-open）；goneN 只按精确键剔错，`sub` 枚举失败时 `sub\a.jpg` 既计
   消失又计错误。修：基准 probeName 三态（Missing 保 ENOENT 语义；Plain
   而非目录、或探不出 → 一条覆盖全树的遍历错误）；`walkCovered` 按路径
   分量前缀覆盖后代、从 gone 剔除不双计。
2. **上线命令生成无路径闸（critical）**：`$()` 在 PowerShell/bash 双引号内
   都展开——合法 Windows 路径粘贴即执行；且手编 config.toml 绕过
   checkPatch。修：新 `pathArgOk`（`" $ ` % !` 与控制符拒），
   `publishCommands` 汇点对 push 目标与每条路径**再验一次**，不合格整体
   Left——拒绝生成而非逐 shell 转义（目标 shell 由用户定，无通用安全转义）。
3. **TOML 渲染器无字符串转义（major）**：`D:\O'Brien` 过 checkPatch 后写成
   非法 TOML，配置当场变砖（既有字段同根，P7 新字段新增可达实例）。修：
   新 `tomlStr`——可 literal 则 literal，含 `'`/控制符退 basic string 转义；
   渲染器所有字符串值必经它（round-trip 用例逐字段钉）。
4. **vault 段 `add -A`（major）**：与 DESIGN §14 及 gitStepsLines「明确禁止
   add -A」直接冲突。修：展示集按 `fixedCategories` 显式 add；portfolio 缺
   photos.json 配置时**拒绝生成**而非退化整仓 add。收口时生成文本的注释行
   自身含「add -A」字样撞上「任何一行不得含 add -A」的钉——改写注释措辞，
   钉保持全行扫描不放松。
5. **GUI armed 未在确认时消费（major）**：失败后按钮恢复可用且仍 armed，
   单击即再执行。修：confirm 分支先 `disarm()` 再发请求，成功/失败出口都
   回到全新未确认按钮（label 还原）。
6. **REVIEW-LOG-1.md 1027 行超预算（minor）**：冻结档案在无豁免口径下同样
   违规——逐字分卷为 REVIEW-LOG-1（451，v0.1→v0.2 + P3b）与 REVIEW-LOG-1B
   （586，P4 GUI + 用户决策记录）；1027 → 451+586 = 1037，多出的 10 行是两卷
   卷首/指针元数据（40 轮流哈希核对正文逐字相同），指针链同步。

GO-notes：Win.hs volumeFsType 的 SomeException 保留为已登记残余（评审建议
后续显式重抛 AsyncException，登记不动）；测试算术 305→311→311→317 标签级
核对成立；Serve 鉴权/执行链无旁路，DESIGN §14 token 表述诚实。

### 收敛证据（P7-G）

**324 tests（322+2：caseFreshnessSweepBaseDenied / casePublishSinkGuards）**，
GHC 警告 0。变异验证中**修正一处归因**：目录级 deny(F) 实测走的是
NamePlain→doesDirectoryExist 塌 False 的「非目录」支（§P7-A ACL 实验早有
记录），不是 ProbeUnknown 支——后者以非法字符名（ERROR_INVALID_NAME 123）
确定性注入补钉，三态三支自此各有配对：

```
m39-1  walkCovered 去前缀覆盖        → 红（sweepCounts 穷举）
m39-2  ProbeUnknown 支塌空          → 红（基准被拒 E2E·非法名钉）
m39-2b NamePlain 非目录支塌空        → 红（基准被拒 E2E·deny(F) 钉）
m39-3  pathArgOk 放开               → 红（汇点复验）
m39-4  vault add 退回 -A            → 红（publishCommands 显式类目）
m39-5  tomlStr 恒 literal           → 红（round-trip 单引号路径）
#5 为 JS，无 HUnit 配对——node --check + 代码级核查登记
```

## 第 40 轮（P7-G `a6a0922`，codex 钉 SHA，聚焦验证轮）——NO-GO，minset {2,4,5,6} → P7-H

attempt 1 即真跑（204 次命令执行）。39 轮六条修法逐格核对：#1 三态与前缀
覆盖、#3 tomlStr 全字段覆盖与 `\uXXXX` 合法性、#5 armed 消费、#6 分卷流哈希
逐字相同——四条 GO-note。7 条 NO-GO 行**先聚类再找上游根因**（用户指令
2026-08-26），三簇：

### 簇 A（3 条，Publish.hs）——上游根因：黑名单过滤后原样拼接

- #2 critical：`pathArgOk` 放行奇数个尾随 `\`——bash 双引号内 `\"` 是转义，
  `D:\safe;whoami;\` 让引号撑到下一行，第二行的首个 `"` 才闭合，`;whoami;`
  落在引号外执行（词法推演成立；PowerShell 无此语义）。
- #2 major：push 字符白名单放行 `--force origin main` → `git push --force`。
- #4 major：`git add "<photos.json>"` 无 `--`，手编 `-A` 过 pathArgOk →
  实测 `git add "-A"` = 整仓 add（`git add -- -A` 只加名为 `-A` 的文件）。

三条同形：配置值被**黑名单过滤后当文本拼进 argv 位置**。黑名单要逐 shell
枚举「能长出第二条命令」的字符类——39 轮补展开字符，40 轮补引号终结符与
选项前缀，无法证明补全。类级修法 = **解析而非过滤**（与 P3b-16「返回解析后
路径而非 Bool」同一原则）：`cmdPath` 把值解析成盘符 + 分量、分量按白名单
（字母数字含 CJK、空格、`-_.()'+,=@~#&`）验证、以 `/` **重渲染**（git 在
Windows 接受；三 shell 双引号内都无转义语义——反斜杠类整体消失）；
`pushTarget` 按 `<remote> [<refspec>]` 解析、段首必为字母数字（选项 `-`、
强推 `+`、删远端 `:branch` 三种形态一并出局）；操作数前一律 `--`（实测
`git push -- --verbose main` 把 `--verbose` 当仓库名）；photos.json 改为仓内
相对路径（不在仓内即拒）。设置入口（checkPatch：portfolioDir 只服务命令
生成，嵌不进即拒）与生成汇点各验一次。

### 簇 B（1 条，app.js）——上游根因：异步响应落 DOM 无「最新请求胜出」

- #5 major：`showPlan` 无 single-flight，快速点 B 后 A 的响应晚到覆盖明细，
  「执行」按钮绑的是 A。全仓同形清点：loadStatus / loadPlans / loadConfig /
  sortScan（换源再扫，旧源提议晚到会把「生成计划」绑到旧 src）同样裸落；只有
  loadVault 自带代号。类级修法：统一 `stamp/stale` 代号助手，五个加载器全部
  走它，确认文案带计划 id。JS 无 HUnit 配对——node --check + 代码级核查登记。

### 簇 C（3 条，文档）——上游根因：手抄数字/口径未从源再导出

REVIEW-LOG 写 449 实为 451（分卷多出 10 行元数据）；DESIGN-COMMANDS 322 →
当前；GUI 帮助未说明 portfolio 命令以 photos.json 为必要条件。修法之外的
纪律：发布前所有计数字面量从命令输出再导出一遍（wc -l / 测试总数）。

### 收敛证据（P7-H）

**325 tests（324+1：caseCmdPath）**，GHC 警告 0。变异逐个恰好配对转红后还原：

```
m40-1  pushTarget 去段首检查        → 3 红（语法穷举 / 汇点复验 / checkPatch）
m40-2  分量白名单放行 ';'           → 3 红（cmdPath 穷举 / 汇点复验 / checkPatch）
m40-2b 渲染改回 '\' 分隔            → 2 红（渲染钉 / 结构钉「命令行无反斜杠」）
m40-3  add 去 --                    → 1 红（结构钉「操作数前必有 --」）
m40-4  photos.json 仓内检查去掉      → 1 红（仓外拒绝钉）
m40-5  checkPatch 去 portfolioDir 可嵌检查 → 1 红
```

m40-1 首跑只红 2 条：汇点复验的选项样例 `-f origin main` 是**三段**，先被
段数规则拒，钉不住段首规则——改成两段全白名单字符的 `--mirror origin` /
`origin -f` 后 3 红。判别力不是写了断言就有，得让被测规则是唯一能拒它的。

## P7-I 第一方全量自审（用户指令 2026-08-26：发布前亲自审一遍代码与架构）

非 codex 轮：主线亲读全部源码——src 全模块 + cbits + gui
（lib.rs/app.js/index.html）+ 测试语域抽查，阅读序 Win→状态层→命令层→
serve/gui。发现**先聚类再上溯根因**（同日用户指令），归 8 簇、类级修齐：

### 簇与上游根因

- **R1 布尔存在探针 False→安心继续（读路径漏网）**：36/39 轮的三态类扫只扫
  了写路径守卫，只读报告路径上 `doesFileExist/doesDirectoryExist` 仍把
  ProbeUnknown 塌成「没有」——Vault.listFlatPhotos（类目 ACL 拒→当空→全表
  NEW）、Vault.photosJsonRef（读不出→答「未被引用」，与自身 34 轮注释矛盾）、
  Sort.existingEvents（→提议重复事件夹）、Plan.listPlans（→页面安静空白）。
  修：`Pm.Win.whenPresent`（NameMissing→Right Nothing；ProbeUnknown→Left；
  在场才 try act）四处改用；Ingest.crossCat 走 36 轮既有的
  `classifyGitProbe <$> probeName`，查不出=errors 一条。
- **R2 同一命令文本两个生成器**：P7 给上线命令建了解析-重渲染
  （Publish.cmdPath/pushTarget），CLI push 收尾 Vault.gitStepsLines 仍硬打
  `cd <dir>`（不引号）+ `git push origin main`（无视 cfgVaultPush）。修：
  `Publish.vaultCommands` 单生成点（类目白名单、commit 信息字符闸、路径经
  cmdPath），四个消费口（runVaultPush / Serve push-plan / Apply.afterApply /
  Ingest.ingestSteps）全走它，Left 时打印原因+手动指引。
- **R3 Windows 名字合法性知识散三处**：Publish.compOk 有尾随检查、Op.normComp
  只做剥后比较、Sort.badChar 只有保留字符——`--place "Boston."` 过闸，落位名
  被 Win32 剥点，handleIsAt 后验必败（响亮失败，但该在计划前拒）。修：
  `Op.winNameOk`（非空/无保留字符控制符/不以点空格结尾），Sort 两入口走它。
- **R4 用户键入路径未绝对化入库**：`pm config set --vault rel` 直写配置，
  相对路径按进程 cwd 解析，`pm ui` 拉起的 serve 与终端 pm 各有各的 cwd。修在
  汇点 Config：writeConfig 写前 makeAbsolute 四个路径字段、loadConfig 出口
  checkAbsolute 拒手编相对路径——init/config set/serve PATCH 一次收齐。
- **R5 `.pm` 子目录先 mkdir 后限域**：savePlan/appendManifest 先
  `createDirectoryIfMissing` 再 resolveUnder，`.pm` 是库外 junction 时拒绝
  前已在库外建出 plans/、trash/（拒绝对、副作用不该有；writeSideCache 早已
  是对的次序）。修：`Config.ensurePmSubdir` 先限域再建，两处收齐。
- **R6 resolveUnder 缺失层后余段裸拼**：下降循环只查**当前**分量，NameMissing
  后余段 `foldl (</>)` 原样拼上——`..` 能在缺失层之后越级；带盘符（`c:x`）或
  分隔符起头的分量让 `</>` **整体替换**逃出 base（filepath 实测语义）。修：
  下降前对整段 splitDirectories 过 badComp 预检（词法层 relPathOk 之外的
  纵深第二道）。
- **R7 部分写窗口与重复定义**：Journal.jAppend / Trash.appendManifest 两次
  hPut（行体与 `\n` 之间可被崩溃切开）→ 单 hPut 一次成行；Dedupe.foldPath
  本地重定义 → 收编 Pm.Import.foldPath。
- **R8 backup init 收 UNC 路径**：登记只记盘内相对路径、发现只枚举本机盘符
  卷——UNC 登记得上、永远发现不了。修：canonicalize **之前**盘符词法闸
  （不探网络）。

### 收敛证据

**330 tests（325+5：caseFirstPartySweep / caseProbeUnknownFailClosed /
caseVaultCommands / caseConfigAbsolutePaths / caseEnsurePmSubdirNoSideEffect；
另 caseGitSteps 重写、SortTests/GuardTests/ServeTests 各扩位）**，GHC 警告 0。
变异逐个恰好配对转红后还原（邻近用例全绿，判别力核过）：

```
m-R1h whenPresent ProbeUnknown→Right Nothing → 2 红（三态钉 / listFlatPhotos 钉）
m-R1p listPlans 吞 Left                      → 1 红（plans 是文件 → errors 必非空）
m-R2  gitStepsLines 退回硬打 cd/origin main   → 1 红（与上线命令同一生成点钉）
m-R3  winNameOk 丢尾点/空格判定               → 2 红（eventNameFor / resolveEvent）
m-R4a writeConfig 去绝对化                   → 1 红   m-R4b loadConfig 去拒 → 1 红
m-R5  ensurePmSubdir 退回先建后限域           → 1 红（库外零目录副作用钉）
m-R6  resolveUnder 拆整段预检                → 1 红（缺失层后 ../盘符分量钉）
m-R8  盘符闸拆除                             → 1 红（UNC 拒绝钉）
```

无从判红、代码级核查登记：R7 两处单 hPut 与 Dedupe.foldPath 收编——判别
试针需要能观测「两次 hPut 之间」的崩溃点或语义差异，不存在；Ingest.crossCat
的 ProbeUnknown 分支需 ACL 夹具（分类函数本身已被 caseClassifyGitProbe 判定
表钉住）。接受不修（方向安全）：Doctor.staleTmpFiles 查不出→不删（no-delete
方向）、Names 成片枚举塌 False→少提议 rename（只读）、Trash.listTrashFiles
base 塌缩（既有注释登记）。

## P7-J 第一方全量自审·第二轮（ultracode 多代理工作流，基线 `0bade70`）——14 簇类级收口

流程同 P7-I（用户指令 2026-08-26：聚类 → 上游根因 → 类级修），但换成多代理
工作流把全库**重扫**：并行 finder 分维度产出 **101 项 finding**，对抗复核后
聚成 **14 簇**；每簇一名 triage 代理在 HEAD `0bade70` 上逐 file:line 复核
（present / fixed_at_head / registered_residual / false_positive 四档，含对
预置 refute 判语的三处推翻），再按簇设计类级修法。全部修法落在本提交，
测试 330 → **382**（零 GHC 警告）。行为面变化的用户可见清单见
DESIGN-COMMANDS §11。

### 第一波（送审前已并入工作树）：散簇 + GUI

命令文本生成（F072：`Pm.Ingest` 搬移行绕过 `inboxDoneCommand` 裸拼）、扫描
覆盖（F039/F040：`.` 键换算不出全树覆盖、未枚举子树条目从快照消失）、探针
（F041）、journal/undo（F027 双侧、F028 撕裂尾追加、F033/F034、F000 报文、
F019 `--only`、F004 重键、F018 槽位报文）、gitignore 归一（F066）、names 身份
闸（F095）、trash 清除逐项停（C102）、serve 配置快照按戳重读（C105）、sort
组悬置复算（F049）。钉子新落 `test/SweepTests.hs` 等；判别突变见下表轮 1
（21/22 ✓，m-F072b 首跑 BUILD-ERROR 系突变本身笔误，改 `let src = CmdPath f`
后重跑转红）。GUI 簇 F（app.js 加载竞态 latest-request-wins 等）同波已修。

### 第二波（四阶段类级修）：五大机制簇

**簇 B——「退出码答不了『真做了吗』」（F029/F068/F031/F099；F020 独根同段修）。**
根因（triage 原文要义）：「工作是否真发生」从塌缩的 `Int` 退出码读，而不是从
**已存在**的逐项结果通道读——`executePlanNowWith` 只按 isBad 折 Int（每个
`ONotExecuted` 都消失），32 轮为此建的 `PlanRun`/`fullyExecuted` 只接了一个
消费者（ingest）；`runUndoCmd` 手搓 savePlan+`pure 0`，「存而未执 = 1」的
定义到不了它；`planCategories` 从**计划**而不是**结果**答「动了什么」。
类级修：`PlanRun`（PrRefused/PrSaved/PrRun + 逐项结果）贯通全部计划生成器与
收尾——undo 走 `savePlanAndMaybeRun'`（exit 1）、`afterApply`/`runVaultPush`
按 `landedItems`/`resultCategories` 收尾、`planIdOf`/`fullyExecuted` 单一定义。
F020（confirm 裸 `getLine`，EOF 异常逃逸）：`try` + EOF=否。

**簇 C——「CLI 打印死绑 stdout，GUI 端只有退出码」（F022/F051/F053/F078/C106）。**
类级修：`(String -> IO ())` sink 贯通全部 GUI 可达命令路径（sort/apply/
recheck/backup 缓存刷新等），serve 用 logRef 收集回 JSON `log` 字段 + 逐项
`status`；CLI 侧 sink=putStrLn，输出逐字不变。

**簇 A——「降级走旁道，退出码写常量」（F010/F077/F032/F056/F057/F021/F046/F079 等）。**
根因（triage 原文）：降级在类型系统允许消费者丢弃的**旁道**上返回（`(Maybe a,
[String])` 的告警被 `_` 抹掉；loadConfig 把「缺席」与「读不出」塌进同一个
Left；readManifest 把整文件拒绝与单条坏行混进一个 [String]），随后退出码写
**常量**而不是从降级推导——净效果：读不出/不可信/过期的状态配上 ✓ 与 exit 0。
类级修：三个未转换的 loader 补成三态（`CatalogLoad`、`ConfigLoad`、
`readManifest :: IO (Either …)`）+ 消费端逐个按三态分支；退出码改为降级的
函数（`backupVerdict` 判定表、status 的 `warns` 入码、doctor 的 CATALOG/
DEEP-SKIPPED 行、trash 视图整体拒绝、init --force 明说「未能保留」、backup
的 `mainFresh` 闸）。

**簇 G6——「配置按字段各查各的，整份记录无人验」（C101/F011/F082）。**
根因（triage 原文）：`checkPatch` 收不到 `Config`，结构上写不出任何跨字段
不变量；嵌套判定是 `backupInitPreflight` 的私有 where（只守备份对主库）；
「备份 id⇔subpath 成对」存在三份互不一致的谓词（renderer/report/GUI），
renderer 静默归一而无人拒绝；CLI 在校验器看到之前就把「--X --no-X」矛盾折成
清空。类级修：`rootsNested`/`checkConfig` 汇点 + `checkPatch` 收 `Config`
终于 `checkConfig (applyPatch c p)` + `configTxn` 锁内按盘上最新配置复验 +
init/backup init（对 vault 槽补查）/serve 四路共用 + `tri`/`mkPatch` 拒矛盾
exit 2 + renderer 与其它表同一 `section` helper（半对登记忠实保全）。

**簇 D——「单一真源纪律只写在散文里」（F002/F023/F025/F044/F047/F059/F060/F096/F097 等）。**
根因（triage 原文要义）：所有权声明只存在于 haddock 散文，定义与站点局部
再拼写可以无限共存，编译器两边都看不见。类级修：逐个上收唯一定义并让原站点
引用——`trashSrcRel`（Exec 字面 `"trash"` / Undo `pmSubTrash` / 谓词硬编码
三处同源化）、`stemOf`（Import/Sort 双份局部 stemKey）、`inArchiveLayer`
（clean 两处局部 + status 的「任何非暂存副本都算归档」口径错位 = F058/F096
行为修）、`archiveLayers`（Dedupe 抄本）、`freshPending`（四处求和）、
`utcToNs`（statSnap 原地重写截断）、`pendingEditDir`（Clean 字面 "待修改"）、
`stagingTop`（Status 字面）；死名删除：`opRelPaths`（零调用导出）、`isPng`、
`stemKey`（Versions 的同名异义局部改名 `versionKey`）。F042 同簇落地：root
自身是 junction 属合法用法（resolveUnder 文档 + 句柄守卫用例既有钉），
freshnessSweep 只对**库内子层** surrogate 拒绝。

**簇 E——「文档/注释清点漂移」（17 项：F003/F013/F014/F036/F043/F045/F048/F053/F055/F062/F076/F080/F089/F090/F100 等）。**
根因：据实清点类声明（字节出口、锁调用点、旗标census、GUI 页序、CSP 逐字）
没有哨兵，代码改一次文档错一片；另有被代码否证的机制解释（F043「与
readPmState 逐字一致 + link count 拒绝」——probeConfined 实际按 FileId 身份
排除、不查 link count；F048「listDirectory 惰性列表 try-WHNF」讹传）留在注释
里教坏下一个读者。类级修：注释逐项改写（Exec 头注、Hash、Win.pathUnder、
nsToUtc/statSnap、Config F013 错位块、Serve 孤儿文档、Status 双 `-- ^`）+
**`test/DocDriftTests.hs` 常驻哨兵 9 例**（字节出口 census、withConfigLock
census、`--json` 唯一、GUI 页序、CSP 逐字、死名、Haddock 标记卫生、讹传、
freshStagingCatalog 命名）。哨兵上线当轮即抓出 3 处漏网（Exec 头注在修注里
复述原句自指命中、Exec/Serve 各一处双标记注释段）——机制成立的直接证据。
文档侧 A1-A10/B 表核查由并行 docs 代理完成（DESIGN.md 750/750 零余量，
行为面变化改记 DESIGN-COMMANDS §11；`--verify-media` 未实现已在 I3b 标注）。

### 驳回/存疑处置（逐项 triage 判语，全库 101 项里的非 present 部分）

- **false_positive**：F006（Win.hs rawRename 判语误报）、F016、F026（volumeFsType 取首
  盘符幂等）、F063（侧缓存成对写非 dead work）、F087/F092（GUI 两项，机制
  链在复核中断裂）。~~F024/F098~~ 当时也归此档——**第 41 轮被推翻**（#5，
  γ 簇）：`catRootId` 确是 write-only，triage 采信预置 refute 判语时未经
  grep 复核，codex 对、我错；更正以下一节的类级修为准。
- **fixed_at_head**：F030。
- **registered_residual**：F012（UNC `\\?\UNC\` 与 `\\server\share` 归一，
  DESIGN.md 既有登记）、F071（VaultHold both-absent 臂复读，TOCTOU 方向无害）。
- **接受不修（方向安全，代码级核查登记）**：Catalog removeIfExists（查不出 →
  不删，no-delete 方向）；journal 撕裂尾 Warn 残余（既有注释登记）；
  m-F027R（resolveOn 不重绑）预期 GREEN——loader 已绑定，纵深防御层。
- **F090（CSP `style-src 'unsafe-inline'` 可收紧）**：代码侧证实零内联样式，
  但 Tauri v2 webview 是否自注入内联 `<style>` 无法离线核实，需一次
  `pm ui` + DevTools 实机验证——登记待办，不盲改 CSP。

### 判别突变（轮 1：第一波散簇；轮 2：第二波五簇）

每项突变恰好让配对钉子转红、邻近用例全绿后还原。轮 1 的 m-F072b 首跑
BUILD-ERROR 是**突变本身**笔误（`let src = f` 类型不符），修正为
`let src = CmdPath f` 后在轮 2 重跑转红（m2-F072b）。

**轮 1（第一波散簇，22 项）：**

| 突变 | 模式 | 预期 | 实得 | 用时 | 判定 |
|---|---|---|---|---|---|
| m-F072a Ingest 搬移行裸拼 f | `-p F072` | RED | RED (1/2 failed: 工作流 F072：ingestSteps 搬移行经 inboxDoneCommand——展开字符文件名给手动指引而非裸拼；命令行无反斜杠) | 191s | ✓ |
| m-F072b Publish inboxDoneCommand 跳过 src checkPath | `-p F072` | RED | BUILD-ERROR | 25s | ✗ |
| m-F039 uncoveredKey 丢 rel == "." | `-p F039` | RED | RED (1/1 failed: 第一方自审工作流 F039：基准目录列不出（RD 拒）→ 覆盖全树，catalog 不报「消失」) | 73s | ✓ |
| m-F040 scanRoot unknown = Map.empty | `-p F040` | RED | RED (1/1 failed: 第一方自审工作流 F040：子树列不出 → 旧条目按「查不出」保留并计数，不从快照消失) | 204s | ✓ |
| m-F041 WalkDotDirs 探针回退 doesFileExist | `-p F041` | RED | RED (1/1 failed: 工作流 F041：root-id.json 被 ACL 全拒 → 仍判 pm 状态目录不进入（布尔探针塌 False 会走进 .pm\tra) | 76s | ✓ |
| m-F049 Sort 去掉 reholdKin | `-p E2E` | RED | RED (1/11 failed: ) | 96s | ✓ |
| m-F027L loadPlan' 不绑定 root | `-p F027` | RED | RED (1/1 failed: F027 resolve 锁内重装只取条目：写回与读盘用 UUID 绑定的 root，文件里的过期 root 零字节) | 81s | ✓ |
| m-F027R resolveOn 不重绑（loader 已绑，预期纵深防御=绿） | `-p F027` | GREEN? | GREEN (1 passed) | 66s | ✓ |
| m-F066 gitignore 行规则回退 T.strip | `-p F066` | RED | RED (1/1 failed: F066 I11 .gitignore 前导空白是模式的一部分：「  .pm/」不算覆盖；尾随空白/CRLF 忽略) | 47s | ✓ |
| m-F095 runNames 身份闸失效 | `-p F095` | RED | RED (1/1 failed: ) | 66s | ✓ |
| m-F074N Names 计划闸不豁免自身 | `-p F074` | RED | RED (1/1 failed: ) | 61s | ✓ |
| m-F074E Exec 执行闸不豁免自身 | `-p F074` | RED | RED (1/1 failed: ) | 37s | ✓ |
| m-F028C 追加口不查尾部 | `-p F028` | RED | RED (1/1 failed: F028 撕裂尾之后再追加：新记录不黏进残行；残行仍报 torn（Warn）而非 CORRUPT；manifest 同口同修) | 78s | ✓ |
| m-F028J 读侧不认撕裂标记 | `-p F028` | RED | RED (1/1 failed: F028 撕裂尾之后再追加：新记录不黏进残行；残行仍报 torn（Warn）而非 CORRUPT；manifest 同口同修) | 88s | ✓ |
| m-F000 落位复核失败报文回退「交 pm doctor」 | `-p F000` | RED | RED (1/1 failed: F000 落位后复核失败：报文指向实现了的 pm resolve 路，不指向看不见该项的 pm doctor) | 60s | ✓ |
| m-F033 用户侧 old 回退 existsAny | `-p F033` | RED | RED (1/1 failed: F033 用户侧 rename 源目录 ACL 全拒 → 仍判「在」落 R3；不落 R2、--repair 不补假 Done) | 35s | ✓ |
| m-F034 C1 文案回退「将清除」 | `-p F034` | RED | RED (1/1 failed: F034 C1 修复文案与 --repair 实际行为一致：在途 tmp 不清除、文案不许诺清除) | 33s | ✓ |
| m-C102 purgeLoop 不 try | `-p C102` | RED | RED (1/1 failed: C102 trash empty 逐项 unlink 失败 → 不逃顶、报已清除 k/N、exit 2、其余条目未动) | 41s | ✓ |
| m-F019 --only 不比对序号域 | `-p F019` | RED | RED (1/1 failed: F019 --only 序号越界 → 拒绝并点名范围（不再静默全跳过 + 惰性巨列表）；范围内照常) | 74s | ✓ |
| m-F004 重键回退 fromList 字节序 | `-p F004` | RED | RED (1/1 failed: F004 目录 rename 的 catalog 重键：改写后的条目胜过目标前缀下的过期条目（左偏），不由字节序决定) | 91s | ✓ |
| m-F018 bindExecRoot 不列非 Present 槽位 | `-p F018` | RED | RED (1/1 failed: F018 bindExecRoot 零候选：槽位身份损坏/读不出时如实列出原因，不宣称「均不符」) | 87s | ✓ |
| m-C105 serve 快照永不按戳重读 | `-p C105` | RED | RED (1/8 failed: 第一方自审工作流 C105：终端带外改了 config.toml → 同一 serve 的 GET /api/config 按盘上新值答；主) | 82s | ✓ |

**轮 2（第二波五簇 + F072b 修正重跑，23 项）：**

| 突变 | 模式 | 预期 | 实得 | 用时 | 判定 |
|---|---|---|---|---|---|
| m2-F032 Catalog classify 把「读不出」折成「缺席」 | `-p F032` | RED | RED (1/2 failed: 工作流 F032 快照被拒（hardlink 占名）→ doctor 报 CATALOG Bad；从未扫描的 root 不报) | - | ✓ |
| m2-F010 Config TOML 解析失败折成 CfgAbsent | `-p F010` | RED | RED (1/1 failed: 工作流 F010/F077：init --force 遇旧配置读不出 → 明说未能保留；旧配置完好 → 登记保留且不报) | - | ✓ |
| m2-F079 readManifest 吞整文件失败为空清单 | `-p F079` | RED | RED (1/1 failed: 工作流 F079/F038 manifest 整文件读不出（hardlink 占名）→ trash list/empty 退出 2，不报「隔) | - | ✓ |
| m2-F046 status 退出码不看快照回退告警 | `-p F046` | RED | RED (1/1 failed: 工作流 F046：快照最新代坏、回退到 .1 → status 打 ⚠ 且退出 1（--cached 下唯一的 1 来源）) | 49s | ✓ |
| m2-F056 backupVerdict 降级不抬码 | `-p F056` | RED | RED (1/1 failed: 工作流 F056/F057 backupVerdict 判定表：零降级零差异才 ✓/0；主库回退告警、备份盘读错/被改/未枚举 → 1) | 29s | ✓ |
| m2-F057 mainFresh 永远放行 | `-p F057` | RED | RED (1/2 failed: 工作流 F057 mainFresh：干净库放行；多出未索引文件 → 拒绝并指向 pm scan) | 39s | ✓ |
| m2-C101a checkPatch 不做整份复验 | `-p C101` | RED | RED (1/2 failed: 工作流 C101 checkConfig：vault 与主库嵌套（两个方向、既有配置改无关字段）拒；旁边的 vault 放行；备份半对登记拒) | 42s | ✓ |
| m2-C101b runInit 跳过 checkConfig | `-p C101` | RED | RED (1/2 failed: ) | 39s | ✓ |
| m2-F082 tri 矛盾折成清空（旧行为） | `-p F082` | RED | RED (1/1 failed: 工作流 F082 tri/mkPatch：--X 与 --no-X 同给 → Left「只能给一个」；三态其余三格照旧) | 35s | ✓ |
| m2-F011 renderConfig backup 表回退全有才渲染 | `-p F011` | RED | RED (1/1 failed: 工作流 F011 备份登记 round-trip：整对写盘读回；半对（手编残余）也不被渲染器静默归零) | 53s | ✓ |
| m2-F029 afterApply 收尾不看落位项 | `-p F029` | RED | GREEN (1 passed) | 49s | ○ 纵深防御¹ |
| m2-F029b afterApply add 类目从计划取而非结果 | `-p F029` | RED | RED (1/1 failed: 工作流 F029/F068：push 收尾按落位项判) | 34s | ✓ |
| m2-F069 pushableExt 丢 .jpeg | `-p F069` | RED | RED (1/1 failed: 工作流 F069 unpushable 与 push 门同谓词：.png 入列、.jpg/.jpeg 不入（pushableExt 唯一定义) | 41s | ✓ |
| m2-F058 stagingArchivedSummary 不过层过滤 | `-p F058` | RED | RED (1/1 failed: 工作流 F058 stagingArchivedSummary：相册镜像不算「已归档」（口径 = inArchiveLayer）) | 32s | ✓ |
| m2-F096 inArchiveLayer 加相册 | `-p F096` | RED | RED (1/1 failed: 工作流 F096 threeCopiesStillExist：主库见证只认 Raw/成片——相册镜像不算归档副本) | 26s | ✓ |
| m2-F097 stemOf 基名不 case-fold | `-p F097` | RED | RED (1/1 failed: 工作流 F097 holdKin：主文件待裁决 → 同目录同 stem 侧车（case-fold）一并悬置；别组不受牵连) | 33s | ✓ |
| m2-F002 isTrashSrcRel 永假（谓词与拼法脱钩） | `-p undo` | RED | RED (5/12 failed: P3b-4 #1 / P3b-5: 复位目标被占 → 占位者隔离(~displaced-N) + victim 复位；重跑用新槽位；undo; undo quarantine = 从 trash 原位复位; cx-2: 组内 Copy 失败 → Quarantine 自动复位；doctor 无 Bad；undo 无残留; P2.2: 复位后同计划重跑成功——第二次隔离不被误豁免，undo 可用; P3b-11 undo 一次复位历史 → 反向 Op 以 .pm/trash 为目标，生成时即拒) | 48s | ✓ |
| m2-F042 子层 junction 也放行（守卫条件丢 relPrefix） | `-p F042` | RED | RED (1/1 failed: 工作流 F042：root 自身是 junction（合法）→ 照常核对；库内子层 junction 保持「探不出 = 错误」) | 42s | ✓ |
| m2-F054 foldHardErrors 不抬码 | `-p F054` | RED | RED (1/1 failed: 工作流 F054：sort 提议/计划——子树列不出（ACL 拒）→ 退出码 1，不替没看过的目录担保；junction 跳过仍是 0) | 30s | ✓ |
| m2-F047 freshPending 丢读取错误位 | `-p 退出码` | RED | RED (1/6 failed: ) | 38s | ✓ |
| m2-F052 planIdOf 拒绝也给 id | `-p F052` | RED | RED (1/2 failed: 工作流 F052：planIdOf——PrRefused 无 id（盘上没有计划）；PrSaved/PrRun 带 id) | 37s | ✓ |
| m2-F072b Publish inboxDoneCommand 跳过 src checkPath（轮1突变笔误修正版） | `-p F072` | RED | RED (2/2 failed: 工作流 F072：ingestSteps 搬移行经 inboxDoneCommand——展开字符文件名给手动指引而非裸拼；命令行无反斜杠; inboxDoneCommand（工作流 F072）：ingest 搬移命令同一纪律——解析-重渲染、'/' 分隔、操作数前 --；展开字符) | 102s | ✓ |
| m2-F020 confirm 回退裸 getLine | `-p F020` | RED | RED (1/1 failed: ) | 37s | ✓ |
¹ m2-F029 预期 RED 实得 GREEN 的机理已查明：外层闸（landedItems）被突变移除后，内层数据闸 resultCategories（同样从逐项结果推导）仍把全员未执行的 add 类目压成空 → 无 git 步骤。两层同源互护，与 m-F027R 同档；改打内层的 m2-F029b 转红证明钩子在承重。

## 第 41 轮（P7-J `f724d52` 送审，codex 钉 SHA，0.6.0 发布前最终门禁轮）——NO-GO，minset {1–7} 全修（P7-K）

三提交合审（P7-H/P7-I/P7-J，基线 `a6a0922`），623 次命令执行，9 条发现
（7 minset + 2 GO-note）**第一方逐条核实全部成立、零误报**。四簇聚类与
类级修（用户流程：聚类 → 上游根因 → 类级修）：

### α「判定与使用不在同一原子域」（#1/#3/#4/#6 同形）

判定（预检/查尾/读戳/探存在）与使用（写入/追加/缓存/建配置）分属两次独立
解析，窗口各自放行被否决过的状态。

- **#1 backup init 登记锁内只写不验**（BackupCmd.hs:136）：预检用进锁前
  快照，锁内重读后直接写——与并发 `pm config set --vault` 交错可写成嵌套
  配置。修：锁内按盘上最新配置重跑 `rootsNested` 两向 + 整份记录过
  `checkConfig`（四条写路径的汇点纪律补上最后一条）；**对称向**：备份盘
  按 UUID 登记、绝对路径要现场发现，`checkConfig` 在盘可发现时把每个命中
  与主库/vault 各判一次嵌套（ConfigEdit.hs `bkNested`）；盘不在场无从核
  ——**残余登记**：登记时点已在锁内验过，插盘后的首次配置写会补验。
  钉：GuardTests「参数快照过期 → 拒绝且不落盘」（用参数快照 vs 盘上配置
  模拟交错，确定性）+ PublishTests「对称向」。
- **#3 init 绕过 loadConfigState**（Commands.hs runInit）：exists=False 直接
  建新配置，孤儿 `<cfg>.tmp`（writeConfig 崩在删旧与改名之间的完整新配置）
  被变成死文件。修：无条件走 `loadConfigState`，缺失 + 孤儿 tmp → exit 2
  复述恢复指引；指引本身更正为「改名采用**或删除后**重跑 init」（原文还在
  推荐会踩同一坑的裸重跑）。钉：ScanGuardTests（exit 2、.tmp 原封不动）。
- **#4 serve 配置快照拆两个 IORef**（Serve.hs）：两个写端点并发可交错成
  〈旧配置, 新戳〉且永不自愈。修：合成一个 `IORef (Config, 戳, 有效位)`
  成组存取；写端点只**作废**（配对只允许发生在 `currentConfig` 的载入路径，
  载入前后**双读戳**，不一致则存无效）；「作废」与「配置文件不存在（戳
  Nothing）」分开编码——初版共用 Nothing 被整套 serve 夹具（无盘上配置的
  约定）当场抓红 14 例。**残余登记**：交错本身无确定性观察点（代码级核查
  + 双读戳结构保证），启动时装载与读戳的毫秒级窗口沿旧例登记。
- **#6 journal/manifest 追加的查尾与追加是两次打开**（Win.hs）：
  `tailUnterminated`（读口）与 `openStateAppend`（追加口）之间整个文件可被
  替换——尾判属于旧对象、补换行落到新对象。修：合成 `openStateAppendTail`
  （ReadWriteMode 不截断 + link count 守 + **同句柄**读尾字节再移回文件尾），
  两个旧原语删除（唯一调用点 `withPmStateAppend'` 改单句柄）。
  钉：HandleGuardTests（半截/换行/缺失三态 + hardlink 拒绝，同句柄追加）。

### γ「身份字段落盘从不校验」（#5）

`catRootId` 从写入那天起全仓零读点——快照整目录拷贝/恢复错位到别的库时
零告警载入，而快照决定 backup/import/undo 读写哪些文件、scan 拿谁当 sha
复用种子。修在 loader 汇点（P3b-13 闸下沉纪律）：`loadCatalog` 与
`.pm/root-id.json` 对账，不符或核不出 → `CatRefused`（种子作废、scan 全量
重建）。钉：StateGuardTests 身份闸双臂。**夹具类修**：TestUtil.mkCat 硬编码
"test-root" 与夹具主流 `RootInfo "m"` 错位多年——闸上线当场抓红 13 例
（ServeTests fixture、DedupeTests 屏障夹具等在错位快照上通过了历年测试），
统一对齐（mkCat → "m"，显式 id 夹具补配对 root-id）；这也是闸在承重的
直接证据。

### β「失败路径没过 latest-request-wins」（#2）

40 轮 #5 的类级修只覆盖了加载器的**成功**路径；旧请求晚到的**异常**照样
经 catch/`.catch(fail)` 改写画面（连接横幅、vault 卡片、计划明细）。修：
app.js 六个带代号的加载器整体包 try/catch——stale 的异常丢弃、当前代照抛
给既有兜底；loadStatus 的 vault 内部 catch 补 stale 守（loadVault 的早有，
纪律铺满）。GUI 无 harness——沿既往 GUI 修同待遇，人工核查登记，无突变行。

### δ「发布字段手抄不从源导出」（#7 + GO-note #8/#9）

- **#7 README**：测试计数同页 310/382 两说、`pm undo <planId>`（CLI 无此
  形态）、收敛叙事停在 37/38 轮。修：计数单一上游（DESIGN-COMMANDS 状态
  行）、undo 提要改真 CLI 形态、轮次收敛判定整段委托 REVIEW-LOG（README
  不再手抄「第 N 轮 GO」）；**常驻哨兵** DocDriftTests `caseReadmeSync` 把
  三条全钉死。
- **#8 relUnder 盘根永不匹配**（Publish.hs）："D:/" 拼 "/" 成 "D://"——
  修为恰一尾斜杠归一；PublishTests 盘根仓用例。
- **#9 DocDriftTests 的 cwd 契约**：package.yaml `extra-source-files` 登记
  全部被读的非源码文件 + `caseRepoRootCwd` 自证（换 cwd 得到一句人话）。

行为面变化的用户可见清单：DESIGN-COMMANDS §11「41 轮门禁收口追加」（4 行）。
测试 382 → **389**（7 新钉），真实库只读冒烟绿（status --cached 4633 文件
exit 0 · config exit 0 备份对完好 · vault status 15 HELD exit 0——身份闸对
真实 catalog 放行）。

### 判别突变（轮 3：41 轮七修；#2 GUI 无 harness、#4 无确定性观察点，见上文登记）

| 突变 | 模式 | 预期 | 实得 | 用时 | 判定 |
|---|---|---|---|---|---|
| m3-R41-1 backup register 锁内闸恒放行 | `-p 快照过期` | RED | RED (1/1 failed: 41 轮 #1 backup init 登记：锁内按盘上最新配置复验嵌套/checkConfig，参数快照过期 → 拒绝且不落盘) | 77s | ✓ |
| m3-R41-1s checkConfig 不再发现备份盘 | `-p 对称向` | RED | RED (1/1 failed: 41 轮 #1 对称向：备份盘在场（可发现）→ checkConfig 判嵌套；库外镜像放行) | 49s | ✓ |
| m3-R41-3 init 孤儿 tmp 闸恒放行 | `-p 恢复指引` | RED | RED (1/1 failed: 41 轮 #3 配置缺失 + 孤儿 <cfg>.tmp → init 拒绝并复述恢复指引，.tmp 原封不动) | 27s | ✓ |
| m3-R41-5 catalog 身份闸恒相符 | `-p 身份闸` | RED | RED (1/1 failed: 41 轮 #5 catalog 身份闸：catRootId ≠ root-id.json → CatRefused（拷贝/恢复错位快照不当种) | 23s | ✓ |
| m3-R41-6 openStateAppendTail 恒报非撕裂 | `-p 同一句柄` | RED | RED (1/1 failed: 41 轮 #6 openStateAppendTail：查尾与追加同一句柄——半截尾/换行尾/缺失三态 + hardlink 拒绝) | 53s | ✓ |
| m3-R41-7 README undo 提要回抄死形态 | `-p 发布字段` | RED | RED (1/2 failed: 41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托) | 56s | ✓ |
| m3-R41-8 relUnder 回抄盲拼斜杠 | `-p publishCommands` | RED | RED (1/1 failed: publishCommands：显式类目 add --、photos.json 仓内相对路径 add --、缺配/仓外拒绝生成、push -) | 21s | ✓ |

## 第 42 轮（P7-K `7a0fa83`，codex 钉 SHA，聚焦复核轮）——FINAL NO-GO，minset {1} = 运行态证据 UNVERIFIED → P7-L

**执行者插曲**：中转站账户余额耗尽（`ai.aiclick.cc` 403 INSUFFICIENT_BALANCE，
四次 attempt 全零 exec，不算评审）；用户裁定「改用 OAuth 订阅额度」——
`~/.codex/config.toml` 去掉中转 provider 覆盖、`codex login` 走 ChatGPT，
attempt 1 即真跑（134 次命令执行）。

四镜头全部核验成立（引其原文要义）：register 锁内 `loadConfig` 后构造 c1 过
`checkConfig`；`runInit` 无条件 `loadConfigState`；`loadCatalog` 对 root-id
读不出/不匹配均 `CatRefused`；serve 单 `IORef (Config, 戳, Bool)` 仅双读戳一致
才有效、写端点只作废、主库锚点保持；`openStateAppendTail` 一次 ReadWriteMode
打开、同句柄查尾、无第二次路径解析；六个 loader 只吞 stale 代；389 = 383
testCase + 1 testProperty + 5 参数化展开，7 新钉均经 Spec 注册；`mkCat "m"`
夹具「先拒绝、再对齐成功，不是恒真」；F024/F098 更正「没有粉饰」。

- **#1（major，UNVERIFIED）运行态放行证明**：评审沙箱是受管只读环境——
  `stack test` 撞 `C:\sr\pantry\…pantry-write-lock: permission denied`，直接跑
  `pm-test.exe --list-tests` 撞 `%TEMP%` 下 `pm-test-cfg-*` 目录创建被拒——
  **不是断言失败**，但 389 例在评审方手里仍是 UNVERIFIED。处置：第 43 轮改
  `-s workspace-write` 沙箱 + `--add-dir` 把**仓外**目录
  `%LOCALAPPDATA%\Temp\pm-review43` 加为可写并设为 `TEMP/TMP`（不能放仓内：
  pm 的 I11 会拒绝位于上层 git 仓库内的测试 root，实测仓内 122/389 红——设计
  在起作用，不是回归）+ 预编译 `pm-test.exe`（不经 Stack，绕开 pantry 锁），
  让评审**自己**跑全套；另在钉定 SHA 的**新建 worktree**（独立 .stack-work，
  库对象由该 worktree 自行编译）跑一次完整 `stack test` 作第二份证据
  （`cleanenv-test.log`：HEAD f0d6dd9——日志已按 P7-M 重跑覆盖，44 轮 GO-note
  订正、树净、389 全绿）。第 43 轮实测：受限令牌**不能改 DACL**，11 个 ACL
  攻击夹具在 `icacls` exit 5 处中断——沙箱能力问题，见第 43 轮节。
- **#2（minor，GO-note）`openStateAppendTail` 判定/查尾期间异常不关句柄**
  （Win.hs:368）：hardlink 判定与 `hFileSize`/读尾/`hSeek` 若抛出，刚开的句柄
  滞留到 GC——同文件其它资源转换口已有 `onException hClose` 口径，这个新口
  漏了。修：整段置于 `flip onException (hClose h)`。无数据丢失方向（只读判定
  阶段），代码级核查登记，无独立钉（构造 `hFileSize` 抛出无确定性形态）。
- **#3（minor，GO-note）README 突变覆盖绝对化**（README.md:21、:157）：
  「每道闸都配突变」与本轮登记的两项残余（#4 交错无确定性观察点、#2 GUI
  无 harness）矛盾。修：措辞限定为「凡有可观测自动化落点的闸」并点名残余
  登记处——**δ 簇同一根因**（发布字段的强断言没有上游），本次是措辞而非
  数字，`caseReadmeSync` 不扩（绝对化措辞无法机械判定，靠评审）。

以上两条 GO-note 落在 P7-L；#1 由第 43 轮在可写沙箱里闭合。

## 第 43 轮（P7-L `45faac9`，codex 钉 SHA，workspace-write 沙箱）——FINAL NO-GO，minset {1,3,4}

沙箱改 `-s workspace-write --add-dir %LOCALAPPDATA%\Temp\pm-review43`（仓外
TEMP），32 次命令执行，评审后 `git status --porcelain` 空。#2（onException
包裹范围）、#5（修复范围/750 预算/四处版本/树净）接受。

- **#1（major，仍 UNVERIFIED）**：评审亲跑了预编译 `pm-test.exe`，但 codex 的
  Windows **受限令牌不能修改 DACL**——11 个 ACL 攻击夹具（`withDenyAll`/
  `icacls /deny`）在形成拒绝态时即 `icacls` exit 5 中断，跑不到断言。第一方
  复现：`codex sandbox`（同一令牌）default 模式 11 红、`windows.sandbox=
  "elevated"` 9 红，失败点全在 icacls；同一 exe 在普通令牌下 389 全绿。
  **用户裁定（AskUserQuestion，2026-08-27）：保留沙箱，判据改为「环境限制
  登记」**——不给模型无沙箱权限（那会让它对本机含 D:\Photography 有完整读写）。
  第 44 轮闭合标准：评审亲跑 exe 得 378/389、逐条核对 11 例失败点全在
  `icacls` exit 5（环境能力）而非产品断言、核对 exe SHA-256 与第一方两份
  全绿日志一致（工作树 `wt-test.log`：HEAD f0d6dd9 树净 → 389 绿；干净
  worktree `cleanenv-test.log`：独立 .stack-work、库对象由该 worktree 自行编译
  → 389 绿；45 轮 #2 订正措辞）。
- **#3（minor）README:221 性能表仍「每道承重闸一个突变」**：42 轮修了两处、
  第三处漏网——`caseReadmeSync` 只管数字不管措辞，「全绿恰好证明措辞不在哨兵
  范围」。修（P7-M `f0d6dd9`）：该格限定为「凡有可观测自动化落点的承重闸」
  并指向残余登记；哨兵新增断言 README 不得含「每道闸都」「每道承重闸」（δ 簇
  同根：强断言无上游→纳入哨兵）。
- **#4（minor）REVIEW-LOG 第 42 轮节记的是被替换掉的仓内 TEMP 方案**：仓内
  测试 root 会被 pm 的 I11 拒绝（上层 git 仓库内、非仓根，122/389 红——设计在
  起作用）。修（P7-M）：改记实际方案（`--add-dir` 仓外）+ DACL 实测。

## 第 44 轮（P7-N `214a463`，评审方改为 Claude Opus 5）——FINAL GO，minset 空

**评审方变更**：codex 走 OAuth 订阅后第 44 轮 attempt 1 跑了 22 次命令即撞
订阅额度上限（"You've hit your usage limit … try again at 1:30 PM"），后三次
零 exec。用户裁定（AskUserQuestion，2026-08-27）：不等，**改用 Claude Opus 5**
（Agent 子代理，只读工具 + Bash，普通用户令牌；提示 `prompt44-opus.md` 与
codex 版同一口径，原文存档 `review44-opus-result.md`；评审后
`git status --porcelain` 空，33 次工具调用 / 497 s）。**判据随之回到原判据**：
Opus 令牌能改 DACL、无 pantry/%TEMP% 限制，#1 要求亲跑 389 全绿；43 轮节写的
「378/389 + 11 例 icacls exit 5 环境限制登记」是沙箱情形下的备用标准，本轮未用。

**#1 CLOSED（运行态放行证明）**：评审亲跑 `pm-test.exe` → `All 389 tests
passed (40.48s)`、EXIT 0；SHA-256 `71cbf429…181d7` 逐字符等于第一方
`wt-test.log`；exe 晚于最新源文件 12.06 s；`git diff f0d6dd9..HEAD --stat`
仅 REVIEW-LOG；`cleanenv-test.log`（独立 worktree，库对象自行编译，08:52
时间戳可查）389 绿互证。**#3 CLOSED**：反向突变两条（回填「每道承重闸一个
突变」/「每道闸都配」）各判红于 `DocDriftTests.hs:215`；误伤核查 README:249
「每道闸重走」、:159「承重闸配」不含被禁短语。**#4 CLOSED**：`review43.sh`
与 42/43 轮节逐字一致。已登记残余三项（REVIEW-LOG:296/:379/:392）未重开。

**四条 GO-note，聚类后两根（P7-O 收口）**：
- **A/C 同根「文档对证据产物的描述沿用写作记忆，未从产物重读」**：42 轮节
  :474 写「cleanenv-test.log：HEAD 45faac9」而日志自述 f0d6dd9（09:29 重跑
  覆盖）；:473「从零编译」而那次是增量 `[1 of 22]`（从零编译在同 worktree
  更早）。修：两句改从产物重读（见上，本节即改）。**B**（43 轮节的备用判据
  未被应用）：本节首段明说。
- **D「一个句柄两条关闭路径」**（Win.hs:376）：hardlink 拒绝分支显式 `hClose`
  与 `onException (hClose h)` 处理器双关——幂等（`HandleGuardTests.hs:180-183`
  活体证伪为非缺陷），但读起来像 bug。修：删分支内 `hClose`，处理器为唯一
  关闭路径（净减一行；hardlink 用例仍绿）。

**发布链自查新增发现（非评审项，`release060.sh` 泄漏扫描）**：pm.exe 含
`D:\Projects\PhotoManager\.stack-work\install\…` ×6——0.5.0 资产同样 6 处，
历次只扫用户主目录模式故漏网。根因：`Paths_photo_manager`（Main.hs 只用它取
`--version`）把六个安装目录烤进二进制，且 exe 段的 Paths 对象直接进链接命令行、
不经归档裁剪，hpack 生成即必在。类级修：版本改走 Cabal 宏
`CURRENT_PACKAGE_VERSION`（`cabal_macros.h` 实核）+ package.yaml exe 段显式
`other-modules: []`；常驻钉 `caseNoPathsModule`（Main.hs 不引用 Paths、版本走宏、
exe 段显式 other-modules；**390 测试**）。扫描模式收敛到与 sancheck36 同类，
三种假阳性登记：裸 `AppData`（warp `Types.AppData` 构造子名）、`skyma`
（`skymanbp` 版权/标识）、`档案`（pm-ui.exe 内嵌中文词频表）。重建后
pm.exe `D:\Projects` 0 命中、`pm --version` = `pm 0.6.0`；P7-O 树
pm-test.exe SHA-256 `f42fc592a28009e92e77b5d04743eb8ab363604cb0df4c94f57a319c9668c961`、pm.exe `44aa8fd0730b96bbe5ff885ab6273406aa6ea4821187ed164d09fe515ebacb88`。

## 第 45 轮（P7-O `3c263c1`，Claude Opus 5 聚焦）——FINAL NO-GO，minset {1,2}（均文档）

评审亲跑 `All 390 tests passed (38.55s)`，双哈希逐字符对上（pm-test.exe
`f42fc592…c961`、pm.exe `44aa8fd0…cb88`），跑前跑后树净；57 次工具调用 / 848 s。
产物级机制反证：修前 sidecar（0.5.0 期 `target/…/debug/pm.exe`）`D:\Projects` ×6、
修后三份产物 0 命中；CPP 预处理逐行 diff 仅 3 处（LINE pragma / 注释内宏展开 /
目标行），`--help` 里 `To-Be-Sync'd` 与 CJK 帮助文本完好；反向突变 M1–M3 各判红于
`DocDriftTests.hs:226/227/229`，**M4（`other-modules: []` 挪到 tests 段）仍绿**。
代码侧四项 CLOSED（句柄单关闭路径、CPP 无副作用、exe 段无 Paths、运行态）。
原文存档 `review45-opus-result.md`。

- **#1（minor）HISTORY.md:369 P7 行尾「389/389」**，同句前文已是「390 测试」——
  又是 44 轮 A/C 那一类：新写的行没从产物重读。修（P7-P）：改 390/390；**类级**：
  `caseReadmeSync` 从同一上游再派生一处——HISTORY.md 末段（当期阶段行）须含
  `dcCount/dcCount`（m2 判红）。
- **#2（minor）REVIEW-LOG:507 孪生断言「独立 .stack-work 从零编译 → 389 绿」原样
  留着**——44 轮只修了被点名的 :473，没按类扫全文件。修：`git grep 从零编译`
  全清点（仅 :507 与 44 轮节的订正叙述），:507 改同口径；收口动作追加「同一断言
  全文件清点后再改」。
- **GO-note 段落定位**（`DocDriftTests.hs:229` 整文件 `isInfixOf`）：修——断言
  限定在 `executables:` 块内（顶格键之前的缩进行；CRLF 先 strip），m1 判红。
- **GO-note 引用面**（只查 Main.hs；库侧引用同样把 Paths 对象拉进 pm.exe）：修——
  `refModules "Paths_photo_manager" []` 清点 src/Pm + app 全部非注释行，m3 判红。
- **GO-note 扫描器未入仓**（抓出泄漏的 leakscan 只在 scratchpad，扫描器本身就是
  「历次漏网」的根因）：修——`scripts/leakscan.py` 入仓，模式全部运行期从
  `USERPROFILE`/`USERNAME`/`LOCALAPPDATA`/`APPDATA`/仓根派生（零本机字面量，
  rule 11），vault 类模式走 `PM_LEAK_PATTERNS`/`--extra` 留在本地；README「从源码
  构建」补发布前扫描一步；`release060.sh` 改用仓内脚本（三份产物 0 命中，
  patterns=16）。推前树扫描器 `AppData` 模式收成路径形态 `AppData[/\\]`（裸词
  是对假阳性的讨论，不是泄漏；44 轮节那句本会被误判）。
- **GO-note `onException` 无钉**：评审建议的「拒绝后 `removeFile` 须成功」**不成立**
  ——`openBoundTo`（cbits/pm_win.c:53）带 `FILE_SHARE_DELETE`，泄漏句柄挡不住删除。
  改用 `FILE_SHARE_NONE` 独占打开（Win32 `createFile … oPEN_EXISTING`）为观测点：
  泄漏的 GENERIC_READ|WRITE 句柄使其撞 ERROR_SHARING_VIOLATION；钉加在
  `caseAppendTailSameHandle` hardlink 拒绝之后，m4（`onException` → `id`）判红。

判别突变（`mutate4.py`，主树逐个 `git checkout` 还原）：

| 突变 | 文件 | 结果 | 末行 |
|---|---|---|---|
| m1 | package.yaml | RED ✓ |     0.6.0 发布链：pm.exe 不带构建机路径——Main.hs 不用 Paths 模块、版本走 CPP 宏、exe 段显式 other-modules: FAIL (0.09s) / 1 out of 1 tests failed (0.09s) |
| m2 | docs/HISTORY.md | RED ✓ |     41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托 REVIEW-LOG: FAIL (0.01s) / 1 out of 2 tests failed (0.04s) |
| m3 | src/Pm/Versions.hs | RED ✓ |     0.6.0 发布链：pm.exe 不带构建机路径——Main.hs 不用 Paths 模块、版本走 CPP 宏、exe 段显式 other-modules: FAIL (0.08s) / 1 out of 1 tests failed (0.09s) |
| m4 | src/Pm/Win.hs | RED ✓ |     P3b-12 journal/manifest/plan 被 hardlink 占名 → 拒绝写入，库外对象字节不变:                     FAIL /     41 轮 #6 openStateAppendTail：查尾与追加同一句柄——半截尾/换行尾/缺失三态 + hardlink 拒绝 |

P7-P 树：390 测试、GHC 警告 0；pm-test.exe `b0276ba3ac817621ee8d155293ba54199c043a1db4048b8bd2547ddb6497d6f5`、pm.exe `9fbc577aaff552bb3b7301f83636f10368ece91587502b30cd6f5cc459b6ac43`；
sancheck37 零命中；三份发布产物 leakscan 0 命中。
