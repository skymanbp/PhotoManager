# pm 设计（下）——逐命令设计 §7–§10

> [`DESIGN.md`](DESIGN.md) 的配套文档，**同一份设计的续篇**，不是摘要也不是
> 附录。拆分原因（2026-08-25）：DESIGN.md 有 750 行硬预算，而"每加一条命令就要
> 加一节"是结构性的——§16 早已把继续削散文判为死路，正解是按边界拆。这里装
> 归档流水线与三条领域命令，DESIGN.md 保留定位/不变量/架构/安全内核/GUI/测试。
>
> 编号沿用 DESIGN.md，跨文档引用照旧写 §7、§10.2。不变量 I1–I11 的定义在
> [`DESIGN.md` §2](DESIGN.md#2-需求--不变量)。

---

## 7. 归档（`pm sort` → `pm import`）

**`pm sort`（P5-A）补上游**：import 要求事件夹已存在且名字正确（「不猜」，I1），
于是"这批属于哪个事件"此前只能靠人在资源管理器里分。sort 读 EXIF 拍摄时间
（`Pm.Exif`：第一方最小解析器，只取一个标签、所有偏移过同一个边界检查、读不到
即 Nothing 交人判断——这条路径决定照片被移到哪，不引未审依赖），按间隔给出
**候选分段**并打印每段该敲的命令；给齐 `--place`/`--event` 与 `--from/--to`
才生成计划。**分段只是提议**：真实库证明时间切不开事件（纽约 2024-12-25→
2025-01-02 与亚特兰大 2025-01-02→01-05 首尾相接，7 张连号 ARW 因此落进两个
事件夹），边界一律由用户确认；地点更推不出（实测相机零 GPS）。**没有为此发明
待裁决文件格式**——`StNeedsDecision`/`pm resolve` 是计划形成**后**的冲突裁决，
承载不了形成**前**的输入，那一格就留成命令行参数（可重跑、不怕中断；GUI 与
将来的 AI 都只是替用户填这一格，走同一条计划路径）。落位是**拷贝不是移动**
（源可能是相机卡，I2），目标 `To-Be-Sync'd\Raw\<事件>`，随后照常走 import。
**sort 不自立纪律**：同一件事与 import 逐字同口径——可信索引走
`freshStagingCatalog`（import/clean/sort 共用一份定义，import/clean 经 CLI
包装 `withFreshStagingCatalog` 取用；「无索引」是**拒绝**
而不是"当作目标为空"，后者是默认覆盖的方向，与 I5 恰好相反）；目标唯一性走
`foldPath`（NTFS case-fold，mj-2）；事件名过 `canonRawEvent`，且 `--place` 与
`--event` **两条都过**字符闸（canon 只约束前 6 个字符，只拦一条等于给另一条
留绕行口）；同 stem 组一荣俱荣（mj-3）；同 basename 来自多个源子目录 →
**整批拒绝**（落位后会互相覆盖，不替用户挑），侧车一并参与该检查。

判定按**目标位置**做，不是"sha 在库里任何地方出现过"——后者会把合法属于
第二个事件的同一张照片**静默丢掉**（2026-08-25 对抗审查纠正）。四态：暂存
目标同 sha = 跳过（重跑幂等）；归档最终目标同 sha = 不重搬（import 迟早判
冗余）；暂存目标异容 = `StNeedsDecision`（I5）；归档层异容**不在此拦**——
那是 import 的返修裁决（`irRework`）管的事，抢在它前面会让同一件事有两套判据。

第 25 轮门禁（NO-GO，6 条全部核实成立）又收紧四处，各自对应一个根因：

- **结构性偏移必须有下界**。`Pm.Exif` 的 IFD 偏移此前只有上界（越界即放弃），
  没有下界。TIFF 头占 0..7，而 `0` 在 TIFF 里的含义恰恰是「没有 IFD」——一个
  声明 `ifd0 = 0` 的文件会从偏移 0 读条目数，那两个字节正是魔数的 `II`
  （= 18761 条），于是条目 1 落在偏移 14，在那里放一个伪造的 `0x8769` 指针就能
  让「没有 IFD」的文件返回**自信的拍摄时间**。下界收进 `ifdEntries` 一处，
  IFD0 与子 IFD 共用。
- **同一份知识不得有两处定义**。相机原生 raw 的扩展名清单在 `Pm.Versions`
  （12 种）与 `classifyExt`（只有 `.arw`/`.dng`）各存一份且已分叉，后果是尼康/
  佳能/富士的卡插进 `pm sort` 时每个 raw 都判成 `KindMeta` 而**静默忽略**，
  用户看到"照片 0 个"。清单收成 `Pm.Types.rawExts` 唯一一份（`.psb` 一并补齐
  ——`.psd` 的大文件变体，同一处遗漏）。
- **「跳过」这个决定不能建立在未核对的缓存上**。catalog 的 sha 靠 (size, mtime)
  维持新鲜，而那一对证明不了内容没变；`VAtDest`/`VArchived` 意思是"这张不用搬
  了"，凭一份没核对过的 sha 做这个决定就是静默丢文件。`verifySkips` 在跳过前
  **真的重 hash 目标**——只对将要被跳过的那些，待拷的本来就要读源。两处目标的
  降级不同：暂存目标异容 → `StNeedsDecision`（那正是本命令要写的位置，I5 适用）；
  归档目标异容 → 照常拷进暂存区，交 import 的返修裁决。
- **遍历纪律复用而不是重写**。`listSource` 自己写了第二份递归，`Pm.Scan.listTree`
  早已处理的三件事一件都没做：跳过 symlink/reparse point（源里指回自身的
  junction 会让递归无限下降，指向外部的会把源范围之外的照片纳入计划）、过长
  路径报错而非静默丢弃、点开头目录跳过。改为直接用 `listTree`。

第 26 轮门禁又收紧四处：

- **校验性读取必须先限域**。`verifySkips` 与（安全内核那侧的）
  `Pm.Clean.anyWitnessAlive` 都是 `root </> rel` 直接打开去核对内容。库内任何
  一层是 junction 时，被"验证"的其实是**库外**的文件——这个结论的下游一边是
  「已归档，不用搬」，另一边是 `pm trash empty` 的**永久删除**屏障。收成
  `Pm.Hash.probeConfined` 一处（`resolveUnder` 后再开），两个调用点共用。
- **遍历策略必须按用途区分**。`listTree` 跳过点目录是给**库根**写的
  （`.pm`/`.git` 是元数据）；`pm sort` 的源是用户随手指的目录，那里点开头的
  目录只是普通文件夹。策略参数化为 `SkipDotDirs`/`WalkDotDirs`，否则
  `card\.hidden\a.ARW` 连一条记录都不留地消失。
- **结构性声明不自洽即整体作废**。EXIF 的 IFD 条目数此前是**截断**（取前 4096
  条，越界的由 `sliceAt` 悄悄丢掉），于是谎报 `count=65535` 的文件照样返回时间。
  截断等于接受一个前缀；损坏文件的正解是 fail-closed。
- **缺席与读不到必须分开**。两者的安全方向相反：缺席 → 照搬/照删；读不到 →
  保守拒绝。`ContentProbe` 四态（`CpSha`/`CpMissing`/`CpEscaped`/`CpUnreadable`），
  且只捕 `IOException`——`SomeException` 会把 Ctrl-C 一起吞成"读不到"。

第 27 轮门禁再收紧五处，其中最重的一条是**上一轮只修对了一半**：

- **校验口必须是「解析→只开一次→句柄上判定→同句柄读完」**。第 26 轮把它改成
  `resolveUnder` 之后再打开，但那是 `getFileSize` 探一次存在性、再**按名字打开
  第二次**——「校验的对象」与「读的对象」仍是两次独立解析，正是本项目十一/
  十二/十三轮反复收拾的那个形状。正解项目里早有：`Pm.Config.readPmState`。
  `probeConfined` 现与它逐字同形，并补上 **link count** 那一半——`resolveUnder`
  原理上看不见 hardlink，而这个判定的下游一边是「三副本齐了，可以永久删」，
  三份必须是三个**独立对象**。
- **缺席与读不到要真的分开**。第 26 轮声称分开了，实现却把 `getFileSize` 的
  **任何**异常都判成缺席；独占占用触发的 sharing violation 于是变成"文件不
  存在"→ 照搬。改用 `isDoesNotExistError`，与 `readPmState` 同一判据。
- **源遍历不进 `.pm`**。源恰好是一个 pm 库根时，`WalkDotDirs` 会递归进
  `.pm\tmp`（**半写入**的临时文件）与 `.pm\trash`（已隔离文件），它们头部有
  合法 EXIF，会被当成待归位的照片拷走。跳过但记一条，普通点目录仍照走。
- **计划前失败也要交代**。撞名整批拒绝时，被选中的其余照片与**已被主文件认领
  的侧车**既不在 `spCollide` 也不在 `spOrphanCars`，一个都不出现在输出里。
  抽出 `reportChosen`，撞名与事件名非法两条路径共用。
- **诊断不是"没归位的文件"**。源根是 junction 的说明混在 `sfErrors` 里会让
  「未入计划 N 个」多算 1；新增 `sfNotes` 把两者分开。

**并且 `pm sort` 现在对它看到的每一个文件都有交代**（`Accounting`）：读不到
拍摄时间 / 可定时但在区间外 / 无区间内主文件的侧车 / 扩展名不认识 / 遍历出错，
逐类列出并给出「不在本次计划里」的总数。此前只有第一类被报告，其余四类**既不
进计划也不出现在输出里**——用户按一份看上去正常的计划清了卡，少掉的再也追不
回来。

同一轮审查另收紧三处：侧车与主文件**同批**（照片进了暂存区而 `.xmp` 留在卡
上，用户清卡后调色参数永久丢失，而 sort 正是唯一有机会带上它的那一步）；源
hash **前后各 stat 一次**（卡仍在写入时算出的 sha 是撕裂的，与 §6.7 同纪律）；
读不到拍摄时间的**每次都列出**、源读取失败**整批拒绝**（少搬一个文件比搬错
更难发现——它会被藏进一份看上去正常的计划里）。`Pm.Exif` 同步收紧：删掉 IFD0
`DateTime`(0x0132) 回退——那是**文件修改时间**，子 IFD 因任何原因走不通都会
掉进去，返回错时间会把照片默默归进错事件，比返回 Nothing 危险得多。

- 输入：`To-Be-Sync'd\Raw\[<年>\]<事件>` → `Raw\<年>\<规范名>\`；
  `To-Be-Sync'd\Processed\<事件>` → `成片\<规范名>\`。（P2 实测：暂存 Raw 的
  事件夹直接位于 `Raw\` 下无年份层；计划器两种布局都接受，年份一律由事件名
  `YY-` 推导，显式年份层与推导不一致 → 不猜，报 unrecognized。）
- 事件名按 canonical scheme（§8 Scheme A）规范化后落位；侧车跟随；同批目标
  唯一性校验——两源撞同一目标 → 连同同目录同 stem 侧车**整组拒绝**（mj-3），
  **返修同样升级到 stem 组**（mj-3v2：主文件 NEEDS-DECISION 时同 stem 待拷
  文件悬置，绝不先行落位产生孤立侧车）；目标键一律 **normalise + case-fold**
  比较（NTFS 语义，mj-2）；事件名先剥可选 `-Raw` 后缀（大小写不敏感）再验地点
  非空——`26-04--Raw`（空地点）与 `26-04-Raw`（裸后缀，歧义）都拒（mj-1）；
  生成计划前过暂存区新鲜度守卫（与索引不一致 → 先 pm scan）。
- 老事件返修（如 `Processed\23-04-EU`）：逐文件走 §6.1——同 sha skip、
  不同 sha 标 `NEEDS-DECISION` 交 `pm resolve`。
- 归档后 staging 原文件**原地不动**；`pm status` 的「已归档，冗余」标记（据实
  更正）来自**当前 catalog 的 sha 集合**——`Pm.Import.stagingArchivedSummary` 问
  的是「staging（`To-Be-Sync'd\`，其中 `待修改\` 不计）里某条目的 sha，是否也
  出现在 staging 之外的某个条目上」。它**不查 journal 的 Done，也不要求那份副本
  被复验过**：是一句"去看看 `pm clean staging`"的**快照级提示**，不是删除授权。
  授权在下游，且两处都要真读盘：`pm clean staging` 生成期的三副本活体核对，与
  `pm trash empty` 永久删除前的屏障重 hash（§5、§8.1）。
- `待修改\` 散文件无事件结构：import 不碰，单列「待修改清单」报告。

### 7.1 只读提议拆成「结果 + 渲染」（P5-E）

`pm sort <源>` 的提议形态拆成 `surveySort`（判定与取数）+ `renderSortSurvey`
（打印，CLI 输出逐字不变），与 `Pm.Status.statusReport` /
`Pm.BackupCmd.backupInitRun` 同一形态。GUI 的「整理新照片」页（左侧导航**第二
页**，次序见 DESIGN.md §11）要的是**结果**不是那段文字，而两者必须同源——否则
页面上看到的分段与终端建议的命令会各说各话。

顺带把 `withSource` 泛化并分成两层：`withSourceQ` 只列举（提议形态要把诊断当
数据交回），`withSource` 在它之上打印 `sfNotes`（计划形态）。拆 `surveySort`
时我一度把 `makeAbsolute`/`doesDirectoryExist`/`listSource` 抄了第二遍——正是
本项目一路在收拾的那种分叉，当场收回一处。

## 8. 命名治理（`pm names`）

- 事件夹统一到 canonical scheme = **Scheme A `YY-MM-地点-Raw`（用户裁定
  2026-08-22）**：29/38 已是，与成片对齐；Scheme B 的月份从成片对应事件还原，
  还原不出的——如 RAW-2025-Summer-Providence 无成片对应——标 NEEDS-DECISION 交用户。
- 跨层地点别名表（Hunan↔湖南 等）入配置，事件关联用别名闭包。
- 文件级版本后缀**不强制统一**（信息即历史）——只做清单报告，改名需用户勾选。
- rename 计划 + 同批目标唯一性校验 + journal 双向映射 + `pm undo` 可回滚。
- **纯大小写改名不是「目标已存在」**（F074）：NTFS 按折大小写认路径身份，所以
  `23-12-Turkey-raw → 23-12-Turkey-Raw` 这类只差大小写的目标，命中的是**源自身**
  ——那不是占位。计划闸与执行闸**同一豁免**、各自用本层的路径身份比较器：
  `Pm.Names` 的盘面校验放行 `selfOnly`（同一年份夹内两名折大小写相等，
  `classifyRawEvent` 只会在 `-raw` 后缀的大小写上产生这种差），`Pm.Exec` 的
  `execRename'` 放行 `normPath oldAbs == normPath newAbs`。此前这类项永久落
  NEEDS-DECISION，报文还点名一个并不存在的占位者；no-replace 落位原语实测支持
  纯大小写改名（§6.2）。
- **身份闸先于任何目录枚举**（F095）：`runNames` 第一件事是
  `requireRole RoleMain`（内含 I11 守卫），拿到 `RootInfo` 之后才去列 `Raw\`。
  此前只在真要改名时才验身份，零改名／仅裁决的路径会在无身份下把整份报告读
  出来再以 exit 0/1 收场。枚举本身整段 `try`：读不出 = 整批拒绝 exit 2、零计划。
- **目录改名的 catalog 重键是左偏 union**（F004）：`updateCatalog` 把旧前缀下的
  条目整体 rekey 到新前缀；目标前缀下若残留过期条目（目录被带外挪走后没重扫、
  undo 反向 rename 正是这个形状），**重键后的那条必须胜出**——它描述的才是此刻
  占着该路径的文件（exec 的前置条件是目标在盘上不存在）。`Map.fromList` 会让
  字节序决定谁活下来；丢弃本身是对的，只是不能由排序决定。
- **P3b-2 落锤（2026-08-23 真实库实测，42 事件夹）**：31 合规 / 6 入计划 /
  3 拒猜 / 2 个 `&` 双月名交用户——逐项经过见 REVIEW-LOG。目录改名走 §6.2
  （FpDir 指纹），catalog 前缀由 updateCatalog 重写，undo 有 E2E 测试。versions（§5）
  同日落锤：暂存区与**设计内冗余**不入报告。设计内三判据（2026-08-25 更正，此前
  只认①，实测误报 7/15）：①`成片↔相册` 同名（相册 ⊂ 成片，I7）；②`成片↔相册`
  异名但成片那名在相册**已被别的文件占住**（平铺避让，刻意改名；没被占仍报）；
  ③`Raw↔成片` 同名且该 Raw 事件夹**无**同 stem 原始档（原片本就是 JPG：直出／手机／
  RAW 遗失后顶替，共同特征是"没有对应的 RAW"；有原始档＝导出件误放，仍报）。stem 经
  `normalizeStem` 比对，否则 `_DSC2227~2.JPG` 会从 `_DSC2227.ARW` 溜过去；**同层两份
  不算设计内**。更正后真实库 → 112 版本组 + **8** 组真重复（7 连号跨夹 + 1 根↔子目录）。

### 8.1 `pm dedupe` — 精确重复的逐份裁决（P5-B）

- **来源不另起一套**：候选组就是 `pm versions` 的 `vgExactDups`（同一个
  `versionsReport`）。设计内三判据已在那里排除，dedupe 不重抄——同一份知识
  出现两处就迟早分叉，用户看到的报告与能操作的计划就会对不上。
- **每一份一个条目，全部 `NEEDS-DECISION`**。留哪一份取决于事件夹归属、命名
  偏好、是否被外部引用——pm 判不出，就不替用户选（I1）。批准方式与既有裁决
  路径一致：`pm resolve <id> --item N --unskip`，`pm apply` 只执行被批准的。
- **不绑复合组**。`piGroup` 的语义是「不可拆分」（supersede 的 Quarantine+Copy
  配对），而这里恰恰要求逐份裁决：三份留一份 = 只批准其中两条。
- **组的完整性改由执行期屏障保证**：`recheckDedupeItems` 在**每次**执行前确认
  该 sha 至少还留一份归档层副本**活在盘上**；不成立就把这些条目降级回
  `NEEDS-DECISION`。理由与 clean-staging 的三副本复验（评审 cx-3）相同——
  **catalog 是快照，不是证据**，生成与执行之间的世界会变。
  - **屏障与动盘在同一把 I10 锁内**（二十九轮 critical，对抗复核未能驳倒）。
    此前屏障跑在锁外、锁内只复核 victim 自己的 sha：两个终端各跑
    `pm apply <同一计划> --only 1` 与 `--only 2` 就够——屏障的 victims 只取
    `StPending`，而 `--only` 把未选中项改写成 `StSkippedByUser`，双方各自看见
    对方那份还活着，双双放行，两份副本一起进隔离区。修法是把屏障装进
    `ExecEnv.eeBarrier`、由内核在 `withRootLock` 内调用；哪些种类需要屏障由
    `Pm.Plan.kindBarrier`（P6-A：`BarrierKind` 分类器，`Pm.Cli.runBarrier`
    对构造子 total 匹配）说了算，**该有而没有 = 整批拒绝**，不会退化成静默
    跳过（P3b-5/A3 的教训在这里的落法：闸算不进内核，就让缺席可见）。
    屏障只能返回**降级清单** `[(piIx, 原因)]`，新计划由内核
    `Pm.Exec.applyDemotions` 构造——「升级回 `pending` / 改写 Op / 改写元
    数据」在类型上写不出来（旧的返回值事后核对 barrierDrift 已删）；内核仅存
    的自卫是清单自洽：序号必须存在且指向 `StPending`，否则整批拒绝。
  - 幸存者名单按 case-fold 比对：只差大小写的两条路径在 Windows 上是同一个
    文件。方向刻意——算错成"受害者"只多拒一次，算错成"幸存者"会放行最后一份。
  - 读不出来（占用／ACL／介质错误）一律不算"还在"。hardlink 按**文件身份**
    判（三十轮 F5 更正——旧文还写着 link count 一律拒读，那是二十八轮 #2
    之前的行为）：`probeConfined` 从句柄取 `(卷序列号, 文件索引)`，见证与
    受害者同身份 → 排除（同一个对象两个名字不是两份副本）；不同身份的合法
    hardlink 见证**算数**，不再一律拒读。
- **三条执行路径共用一张表，且已不再由它们自己取**。`pm apply`、各命令
  `--apply` 的即时路径、`POST /api/apply` 都经 `Pm.Cli.executePlanNowWith`
  这**一个**装配点把屏障装进 `ExecEnv`，由内核在锁内调用；调用方连"跳过屏障"
  这个选项都没有。P2.2 封堵的是"两处各写一遍、其中一处漏掉复验"的旁路，
  第 29 轮封堵的是"三处都记得调、但都调在锁外"的旁路——同一件事的两层。
- `pm trash empty` 的永久删除前屏障同步一般化：见 DESIGN §5 该行。

### 8.2 第 28 轮门禁的五处收紧

七条 finding 逐条第一方核实：**五条成立**、一条（`--apply` 之前不得写盘）
第一方证伪——那是评审把 DESIGN 的"写盘"读成了"任何字节"，计划文件本来就要在
没有 `--apply` 时落盘，否则两段式的第二段无从谈起（DESIGN §5 已补明）。
另一条（`resolveUnder` 与 `openStateRead` 之间的 TOCTOU 窗口）成立，
**已在 P5-D 修掉**：取用口改为「打开 → 在句柄上确认绑定路径」，见 DESIGN §14。

- **副本独立性改按文件身份判**，不再用 link count。`nlink == 1` 是**充分而不
  必要**的：一份合法归档照片被去重工具另建一个名字就被一律拒读，
  `clean staging` / `trash empty` 于是长期 HELD。正解是比 `(卷序列号, 文件索引)`
  ——"三副本"要的是三个**不同对象**，于是链式排除：归档见证 ∉ {被移走者}、
  备份见证 ∉ {被移走者, 归档见证}。nlink 判据**保留**在 `.pm` 状态文件的三个
  打开口，那里问的是另一件事（pm 自己的状态不得与任何别的名字共享对象）。
  - **该判据的前提**（二十九轮）：`FileId` 取自 `GetFileInformationByHandle`，
    是 32 位卷序列号 + 64 位文件索引，不是 ReFS 的 128 位 `FILE_ID_INFO`
    （Win32-2.14.1.0 未绑该 API，换过去要新写 FFI）。在 NTFS 上这是精确判据
    （索引在文件存活期间不变，序列号防 MFT 记录复用撞号）。窄化的方向与
    nlink 判据**相同**——把两个不同对象并成一个只会**多拒**（HELD /
    NEEDS-DECISION），数学上产不出"把同一个对象拆成两个"因而放行最后一份，
    所以不为此加一层 FFI。id 全程不落盘，两侧都在同一把锁内从活句柄现取现比。
- **`.pm` 按内容认身份，不按名字**。按名字两个方向都错：卡上一个普通的、名叫
  `.pm` 的用户目录被整个跳过（里面的照片一格都不进）；真状态目录经别名到达时
  判据根本不触发。判据改成"目录里有 `root-id.json`"——这正是 pm 自己认 root 的
  方式。
- **pick 之后不产计划的路径共四条**，第 27 轮只补了两条。新鲜度不过、源文件
  读取失败这两条同样一个文件都不列。四条现在都走 `reportChosenFiles`，并且
  **不再截断**——这是中止路径，「另有 2960 个」帮不上任何忙。
- **`sfNotes` 接上了输出**。第 27 轮把诊断从 `sfErrors` 分出来是为了不计入
  「未入计划 N 个」，却忘了接出口，于是一条本来会打印的说明彻底消失——分开的
  目的是不计数，不是不说。
- **EXIF 的 IFD 完整性含那 4 字节 next-IFD offset**。本机探针实证：一个 64 字节
  的 TIFF（子 IFD 条目数组正好在缓冲区末尾结束）此前照样返回
  `Just 2026-08-25 13:45:07`。

## 9. 备份同步（`pm backup`）

- 备份 root 识别：`getLogicalDrives` 枚举 + `SetErrorMode(SEM_FAILCRITICALERRORS)`
  抑制「请插入磁盘」系统对话框 + 只探 REMOVABLE/FIXED 卷找 `.pm/root-id.json`
  （role=Backup，UUID 与配置登记值相符才认）；找不到 → 提示插盘，绝不猜。
  （P2 落锤：GetDriveTypeW/SetErrorMode/GetVolumeInformationW 均无 Win32 包
  绑定，已在 Pm.Win 自行 foreign import。）
- 登记入口 = **`pm backup init <盘上镜像路径>`**（P2 落锤，取代原设想的
  pm init 一并处理）：写 role=Backup root-id.json（含 GetVolumeInformationW
  探测的 FS 类型）+ 主配置记 `[backup] id/subpath`；拒绝与主库嵌套的路径和
  git 工作树。exFAT 无元数据日志，rename 原子性弱于 NTFS——doctor 矩阵
  （§6.4）不依赖原子性假设，仅依赖「tmp 与 dst 不同名」这一约定。
- 单向 add/update：主库有而备份没有 → Copy；同名不同 hash → 计划标出方向
  （默认判主库新），**经确认后走 §6.5 supersede 复合**（备份盘旧字节进备份盘
  自己的 `.pm/trash/`，不丢）；备份盘多出的 → EXTRA 只读报告。
- 备份 root 的 catalog 记录**备份盘自己 stat 的值**（§3）。备份计划的
  journal/trash/tmp 全在备份 root 自己的 `.pm` 下（P2 落锤，与效果同卷）；
  备份路径的 Done 仍一律即时 FlushFileBuffers（不组提交）——理由是可移动
  介质：结果打印后用户随时可能拔盘，Done 必须在汇报前已落盘；
  doctor（`--backup`）的 C3/C4 行专门接这个残余。
- 备份盘 hash 并行度**恒定默认 1**（HDD 防寻道抖动，`Pm.BackupCmd` `fromMaybe 1 mworkers`；
  **不读** `[main] workers`），只能用 `pm backup --workers N` 逐次覆盖。**pm 不探介质**
  ——seek-penalty/MediaType 探测从未实现；`Pm.Win.listCandidateDrives` 的 `DriveKind` 仅按
  GetDriveTypeW 筛 REMOVABLE/FIXED 做**发现**，并发数与它无关。worker 数**不是 Root 属性**：
  `root-id.json` 只记 `id/role/created/fsType`。主库扫描是另一条口径（`[main] workers`，
  DESIGN.md §11.4）。
- 拔盘期间 `pm status` 用备份 root 的本地缓存快照报「上次同步时间 + 当时滞后量」。

---

## 10. Vault 分发与档案侧对接

### 10.1 `pm vault status` — 逐字段兼容

- **六态是与 `sync_photos.py` 兼容的核心，不是 pm 的全集**：`Pm.VaultCore.VaultDiff`
  只有 OK / NEW / MISSING / RENAME / DRIFT / DUPLICATE 六个字段，legacy 算法逐行
  复刻；pm 在其上另加三态——`UNPUSHABLE`（.png：status 可见、push 写路径拒收）、
  `UNSTABLE`（读取期间持续变化，已退出六态分类，fail-closed）、`HELD`（「暂不同步」
  的本地决定，见下「第九态」），合计**九态**。CLI 汇总行打前八个计数，HELD 与
  HELD 失效另起行；GUI 状态页的计数 pill 正是这九个。凡文中写「六态」，指的都是
  legacy 兼容那六个。
- 六态语义与 `sync_photos.py` 一致；`--json` **值形状逐字段照抄**：
  `ok/new/missing/duplicate` 用同形位置元组、`renamed/drift` 的 hash 截断 16 字符、
  `duplicate` 与 ok/drift 可重叠（不构成划分）、顶层键名同
  （`source_dir/vault_dir/source_count/vault_count/...`）；退出码 0/1/2 同。
- **文件过滤集合 = sync_photos.py 的 PHOTO_EXTS 等价类**（jpg/jpeg/png，case-fold）；
  「只收 jpg/jpeg」的收紧只在 push/ingest **写路径**生效，.png 在 status 里以
  `UNPUSHABLE` 显式可见而不是被静默过滤。
- P3 验收：与 sync_photos.py 输出做**集合逐项比对**（非计数比对）。
- sync_photos.py **退役由 pm 接管（用户裁定 2026-08-22）**：P3 用它做最后一次
  互校（比对通过才算验收），P5 把档案侧文档/skill 指针改指 `pm vault status`
  并 `git rm` 该脚本（档案 vault 本地 git 历史可恢复；跨仓改动 confirm-first）。
- **P3a 实测验收（2026-08-23）**：`pm vault status --json` 与 sync_photos.py
  双跑真实库，全部 legacy 键**集合逐项一致**——78 OK / 15 NEW / 1 RENAME /
  0 MISSING / 0 DRIFT / 0 DUPLICATE，source_count 94 / vault_count 79，
  RENAME 恰为档案侧登记的 `_DSC9014.JPG ≡ landscape/_DSC9013_2.JPG`；
  UNPUSHABLE 轴当前 .png=0 空洞通过，已由合成 fixture 测试补位（VaultTests）。
  legacy 逐行为基线与 vault 拓扑实测：`docs/specs/sync-photos-legacy-spec.md`、
  `docs/specs/vault-topology-p3.md`。vault 侧 sha 缓存放主库 `.pm/vault-cache/`
  （I11 之前对 vault 目录零写入；status 全链路只读 vault）。

### 10.2 `pm vault push`

- NEW：类别来自 GUI 勾选（P4 后的主路径）或 `--category`/计划文件编辑；
  CLI 只有文件名可看，**不提供假装能分类的交互表格**，无类别项保持 pending
  并提示「需要看图分类 → pm ui 或 --category」。原字节直拷（vault 硬规则 1），
  写路径只收 jpg/jpeg（case-fold）。
- DRIFT：相册是上游真相 → 逐项确认后走 §6.5 supersede 复合（victim 进
  vault root 的 `.pm/trash/`，**不依赖「git 历史里有旧版」这类 pm 无法核实的
  外部前提**）。
- RENAME：**默认只报告**。vault 文件名是 GitHub Pages URL 的一部分、被
  portfolio `photos.json` 以完整 URL 引用（§1.3）——pm 对 photos.json 做只读
  引用检查（路径入 Config），被引用的项标 `BLOCKED(photos.json:<行>)`，
  未被引用且用户确认的才生成 Rename。
- MISSING：只报告（可能是有意撤下，决定权在用户）。
- 结束打印**显式路径**的 git 步骤，形如 `git -C "<vault>" add -- <本次落位的类目>`
  ——类目取自**逐项落位结果**（`Pm.Vault.resultCategories`；一项都没落位则整段 git
  步骤不打，见本文 §11），两条打印口同源：`pm vault push` 直跑（`Pm.Vault`）与 push
  计划的 `pm apply`（`Pm.Apply`）都走 `gitStepsLines`；GUI 生成计划时给的是**预览**，
  类目取计划面（`Pm.Serve`，`planCategories`）。固定三类 `landscape portrait urban`
  只出现在上线命令里（`Pm.Publish.publishCommands`）。明确禁止 `git add -A`/`git add .`
  （防把 `.pm/` 等误提交），操作数前必有 `--`；push 目标取自 `vault.push` 设置。命令文本与上线命令
  （DESIGN.md §11 `GET /api/publish-commands`）**同一生成点**
  （`Publish.vaultCommands`，解析-重渲染，第一方自审 R2）——生成不了（路径
  嵌不进命令行等）打印原因 + 手动指引；pm 不执行 git（I9）。
- **photos.json 不在 pm 写域**：类别判定/坐标是 AI 视觉判断，属 `/photo-inbox`。
- **第九态 HELD「暂不同步」（P4-7，用户 2026-08-24 裁定）**：相册里有、但用户
  决定**先不放进展示集**的照片。它**不是 vault 的第四个类目**——vault 的类目
  就是展示集 git 仓里的目录，建目录等于把照片发出去，恰好与"不同步"相反。
  因此它是一条**主库侧的本地决定**，存在主库 `.pm/vault-holds.json`（vault 仓
  零改动）：`{name, sha, at, note}`。语义：
  - `new` 键（对外契约、与 sync_photos.py 集合比对面）**不变**，HELD 是它的
    注解子集；`newActive` = NEW − HELD 才是"待处理"，退出码按它算——用户已经
    决定不同步的照片不该让 `pm vault status` 永远 exit 1（顶层 `pm status` 读
    缓存 meta 的 `vmHeld`，同样按 NEW − HELD 显示）。
  - 记录里存**决定当时的 sha**：照片字节后来被换过（重修图/重导出）→ 决定
    **失效**（`held_stale`），照片回到 NEW 让用户再看一眼。宁可多问一次，也
    不让一张已经不是当初那张的照片被旧决定永久压住。复核用的 sha **强制重算**
    （空缓存调 `shaViaCache` → 真实重读 + 双 stat）：走 `(size,mtime)` 缓存快路
    时，等长替换 + 还原 mtime 会让旧 sha 被复用、旧决定继续压住新字节（codex
    二十一轮 major）。代价是每次比对要重读"已决定不同步"的那几张，量级 = 用户
    自己决定的张数。本轮读不稳定 → 同样按失效处理（fail-closed）。
  - 名单的「读 → 校验 → 写」是**一个跨进程事务**：整段在主库 `.pm/lock` 里
    完成（I10）。两个 pm（CLI 与 GUI 的 serve）各读同一份旧名单、各写全量结果，
    后写者会整份覆盖先写者的决定——serve 的进程内互斥挡不住（二十一轮 major）。
    锁被占用时不排队，直接告知（CLI exit 2 / API 409）。
  - 名单本身 fail-closed：解析失败、名字不是平铺 basename、sha 不是 64 hex、
    同名多条，一律拒绝而不是"跳过坏条目"；正文缺失但残留 `vault-holds.json.tmp`
    （覆盖写崩在删旧与 rename 之间）同样拒绝——按"空名单"继续等于把用户的决定
    静默清零。
  - `pm vault push` **拒收**已 HELD 的文件（先 `pm vault unhold`）；CLI 是
    `pm vault hold|unhold <文件…>`，GUI 是分类卡上的第四个按钮。
  - 决定不走两段式计划：它不碰任何照片字节，撤销就是 unhold。身份闸**四道**，
    次序与 `pm apply` 一致——**取锁前**先做零写入的 `requireMain` 预检（否则
    `withRootLock` 会先把 `.pm/lock` 建出来再拒绝，二十二轮 major），然后
    root lock（I10），锁内 `computeVault` 的 `requireMain` 复检，落盘前
    `writeHolds` 的 `requireWritable`（I11）。
  - 决定里的 sha **创建与复核都必须是本轮真实重算的**（`freshSrcSha`）：从
    `vrSrcMeta` / `srcShas` 取会拿到主库 catalog 的 (size,mtime) 命中值，
    等长替换 + 还原 mtime 时那是陈旧值——二十一轮指出复核会失真，二十二轮
    指出创建同样会（hold 记下旧 sha → 下一轮复核立刻判失效，决定落不住）。
- **P3b-1 落锤（2026-08-23）**：CLI 形态 `pm vault push [--category C FILES…]`
  ——NEW 只推显式点名 + 显式类目的文件（无类目零猜测）；DRIFT 生成
  NEEDS-DECISION 项，裁决复用 `pm resolve --keep src`（§6.5 supersede，
  victim 进 vault 侧 `.pm/trash/`）；RENAME/MISSING 只报告。I11 守卫为
  **文本级** `.gitignore` 含 `.pm/` 行检查（pm 不跑 git，I9）+ role 校验，
  fail-closed——读不到 `.gitignore`（被占/被挪）同样拒绝，核不了 ≠ 已覆盖
  （三十五轮 F4）；`.git` 存在性探测走 `probeName` 三态，查不出（ACL/介质）
  同样拒绝——布尔探针会把「查不出」塌成「不存在」而放行（三十六轮 F1）；
  vault root 由首次生成计划时建立（用户已批准 ignore 行，
  展示集仓 commit 2d81d36）。执行绑定 bindExecRoot 序：主库 → vault
  （固定路径无发现流程）→ 备份盘；doctor/trash/undo 增 `--vault` 开关。
  真实库只读验证：RENAME 项命中 `BLOCKED(photos.json:208)`（实测该行
  正是 `_DSC9013_2.JPG` 的 Pages URL），15 NEW 待分类不出计划，vault
  目录零写入。
- **P3b-4 … P3b-12 的逐轮评审收口**（2026-08-24，codex 一~九轮）已移入
  [`docs/REVIEW-LOG-1.md`](REVIEW-LOG-1.md) §「P3b 逐轮收口」——那里是评审史的家，
  本文件是设计文档（同 P3b-8 把 §16 拆出去的先例；DESIGN.md 触及 750 行预算）。
  当前实现对应 **P7 / pm 0.6.1 / 393 测试**（P3b-13~18 与 P4 详情见 REVIEW-LOG；
  门禁轮次与收敛判定见 [`REVIEW-LOG.md`](REVIEW-LOG.md) 末节 verdict，不在此手抄；
  发布前第一方全量自审（P7-I 簇修 R1–R8、P7-J ultracode 全量审 14 簇类级修）
  及其后各轮门禁收口的行为面变化见 §11）。

### 10.3 P5 — 档案侧整理优化（跨仓改动，逐项经用户确认）

1. `/photo-inbox` SKILL.md 重写：第四阶段机械步骤改走
   `pm vault ingest <files> --category <c>`（拷 相册/ + 拷 vault/ + 冲突检测 +
   journal 登记 inbox-origin，**不动 _inbox**）；`_inbox→_done` 由 **skill
   自己 move**——pm 在两份计划都落完时打印含逐条 move 命令的显式步骤（与 I9
   处理 git 同款；设计期曾设想的 `--finalize` 子命令**不存在也不会有**，理由
   见下方「第 1/2 项的拆分」）。move 命令与 git 命令**同一纪律：解析而非过滤**
   （`Pm.Publish.inboxDoneCommand`）——源与 `_done/` 两条路径都过 `cmdPath`
   （盘符绝对路径 + 白名单分量 → 以 `/` 重渲染）后才拼成 `mv -- "<源>" "<_done>/"`；
   任一侧渲染不出来就**不拼**，改打印「无法安全生成搬移命令：<原因>」+ 手动指引，
   而不是把原始路径原样嵌进命令行。顺序保证与 skill 现行「photos.json 成功后才
   移」硬约束一致；AI 部分（看图分类、坐标、photos.json 内容）保持不变。
2. ingest 的 journal 来源登记喂 I7：相册 ⊆ 成片 ∪ inbox-origin，doctor 把
   inbox 来的照片归为「已解释」而非违例。
3. vault `.gitignore` 追加 `.pm/`（比照现有 `.ce/` 惯例；按档案 vault
   confirm-before-act 规则先征得同意——I11 在此之前拒绝在 vault 建 root）。
4. `KB-维护速查.md` §📸 与 档案 `CLAUDE.md` 摄影行更新指针；
   `record-structure-version.md` Change Log 补记。
5. `sync_photos.py` 去留按用户决定落实。

**落实情况（P5-F，2026-08-25，档案 vault commit `3859e1c`）**：

| 项 | 状态 |
|---|---|
| 1 `/photo-inbox` 改走 `pm vault ingest` | ✅ pm 侧 P6-D 实现（两份计划 + 显式收尾步骤，三十二轮收紧执行次序闸）；skill 侧指针改写随第 32 轮门禁 GO 后落地 |
| 2 ingest 的 journal 来源登记喂 I7 | **记录侧 ✅**（P6-D：主库 journal 的 Intent 带库外 srcAbs 即 inbox-origin 记录本体，不新造记录类型）；**判定侧 ⏸ 未做**——本项正文承诺的「doctor 把 inbox 来的照片归为已解释」尚无任何代码（三十二轮核对），登记为待办 |
| 3 vault `.gitignore` 追加 `.pm/` | ✅ 已在展示集仓（P3b 时经用户批准，commit `2d81d36`） |
| 4 `KB-维护速查.md` §📸 / 档案 `CLAUDE.md` / `record-structure-version.md` | ✅ 指针改写 + Change Log 补记 |
| 5 `sync_photos.py` 去留 | ✅ **退役但保留**：加横幅 + 运行时 stderr 指针，代码冻结 |

第 5 项之所以是"退役但保留"而不是删除：这个脚本同时是 **I8 的字段兼容基线**
（`docs/specs/sync-photos-legacy-spec.md` 逐条列出 pm 有意偏离它的地方）。
删掉它，那条验收就失去参照。

**第 1/2 项的拆分（P6-D 按此实现）**：把 `_inbox` 里的原图移到 `_inbox/_done/`
这一步 pm **不做**——`_inbox` 在**档案 vault** 里，不在 pm 的任何 root 之内。
pm 的整个模型建立在「操作发生在某个有身份的 root 内」之上（root-id、journal、
隔离区、undo 全挂在 root 上），给它一条"搬第三处目录里的文件"的能力，等于在
模型外开一个口子。与 I9（pm 不执行 git，只打印显式步骤）同一处理：这一步
**由 skill 自己做**，pm 只负责它 root 内的那两次拷贝，并只在两份计划都真的
全部落完时打印 move 步骤（三十二轮 R5：源移走后未完成那半的计划就废了）。
ingest 作为新写路径已过第 32 轮门禁；对真实 `_inbox` 的首次使用仍待用户裁定。

---

---

## 11. P7-J 全量自审收口的行为面变化（2026-08-27）

P7-I 之后的第二次第一方全量自审（ultracode 多代理工作流，101 项发现聚成
14 簇），逐簇根因、类级修法与突变验证在 [`REVIEW-LOG-4.md`](REVIEW-LOG-4.md)
§「P7-J」；这里只登记**用户可见的行为变化**（命令文档正文以此为准）：

| 命令/入口 | 变化 | 根因簇 |
|---|---|---|
| `pm undo` | 生成反向计划后退出 **1**（计划已存、未执行——与其它计划生成器同码；此前 0 把"还有事没做"读成"全部成功"） | B（`PlanRun` 三态收口） |
| `pm vault push` / push 计划的 `pm apply` | 收尾 git 步骤按**逐项落位结果**打印：有落位项才给 `git -C … add -- <落位类目>`；全部待裁决 → 无 git 步骤 | B |
| `pm sort` | 子树列不出（ACL 拒）→ 提议/计划两形态都退出 **1** 并打「未能枚举」——不替没看过的目录担保；junction 跳过仍是 0 | B |
| `pm trash list/empty` | manifest 整文件读不出（hardlink 占名等）→ **exit 2**、视图整体拒绝，不再显示「隔离区为空」（坏基准上 empty 会"无事可做"地成功） | A（三态加载器） |
| `pm doctor` | 快照被拒（≠缺席）→ `CATALOG` **Bad** 行；`--deep` 无快照可深验 → `DEEP-SKIPPED` **Bad** + exit 1（此前静默跳过深验照报 0） | A |
| `pm status` | 快照坏代回退 → ⚠ 行 + **exit 1**（`--cached` 只关掉新鲜度核对那一项；`--cached` 下 exit 1 共四个来源——快照坏代回退告警、暂存区尚有事件（含内容已全部归档、只打「冗余」不打 ⚠ 的那种）、备份缓存不可信、vault 缓存不可信（仅在配置了 vault 时）；不带 `--cached` 另有第五个：新鲜度核对 pending（新增/变更/消失/读取错误之和）> 0，见 `Pm.Status` 的退出码判定）；核对受阻（读取错误 >0）不打「✓ 索引与磁盘一致」 | A |
| `pm backup` | 主库快照坏代 → ⚠「diff 基于较旧一代」；主库索引与盘面不一致 → **拒绝 exit 2** 指向 `pm scan`（mainFresh 闸）；「✓ 备份盘已与主库一致」只在零降级零差异时打（`backupVerdict` 判定表） | A |
| `pm init --force` | 旧配置读不出 → 明说「未能保留」备份盘登记等字段（此前静默丢失还打 ✓）；整份新配置过 `checkConfig` 汇点 | A + G6 |
| `pm config set` | `--X` 与 `--no-X` 同给 = 矛盾 → **exit 2**（此前解析器静默折成清空）；写入前整份配置过 `checkConfig`：主库/vault/备份盘两两不嵌套、备份登记成对、路径绝对——四条写路径（init / config set / POST config / backup init）同一汇点，且锁内按盘上最新配置复验 | G6 |
| `pm serve` | 启动失败（端口/权限）→ **exit 2**（此前 0）；`POST /api/sort/plan` 与 `POST /api/apply` 响应**都含 `log`**（与 CLI 同一打印流；sort 的 log 里带渲染好的逐项计划行）；**结构化逐项结果（`ix`/`outcome`/`status`）只在 `/api/apply` 的 `items` 里**——`/api/sort/plan` 只回 `code`/`planId`/`log`；缩略图对「快照读不出」答 **503**（缺席仍 404） | B + A |
| 配置渲染 | `[backup]` 表与其它表同一渲染 helper：半对登记（手编残余）忠实保全，不再被静默归零 | G6 |
| freshness 判定 | root 自身是 junction 属合法用法：`pm status`/新鲜度闸照常核对（此前每轮报一条「基准探不出」读取错误）；库内子层 junction 保持「探不出 = 错误」 | D |

### 41 轮门禁收口追加（P7-K，2026-08-27）

四条 α/γ 簇修法的用户可见面（根因与突变见 REVIEW-LOG「第 41 轮」）：

| 命令/入口 | 变化 | 出处 |
|---|---|---|
| `pm init` | 配置缺失但躺着孤儿 `<cfg>.tmp`（上次写入崩在删旧与改名之间，.tmp 是完整新配置）→ **拒绝 exit 2** 并复述恢复指引（改名采用或删除后重跑）；此前直接新写一份，把待恢复的登记变成死文件 | 41 轮 #3 |
| `pm backup init` | 登记步在配置锁内按**盘上最新配置**复验（嵌套判定 + checkConfig 汇点）→ 与并发配置写交错时拒绝「登记被拒（锁内按盘上最新配置复验）」，而非静默写成嵌套配置 | 41 轮 #1 |
| catalog 载入（status/backup/apply/undo/scan 种子） | `catRootId` 与 `.pm/root-id.json` 对账：不符（整目录拷贝/恢复错位）→ 整链拒绝「索引读不出（catalog 身份不符…）」，scan 丢弃种子全量重建 | 41 轮 #5 |
| `pm config set` / GUI 设置页 | 备份盘**在场**（UUID 可发现）时 checkConfig 把其实际路径与主库/vault 各判一次嵌套；盘不在场无从核——登记时点已在锁内验过，残余登记于 REVIEW-LOG | 41 轮 #1 |

### 0.6.1 收口追加（P7-S，2026-08-27）

发布后端到端运行时测试（发布版 pm.exe 于沙盒三层库跑 68 步）与文档全量审计的用户可见面：

| 命令/入口 | 变化 | 出处 |
|---|---|---|
| `pm doctor --deep` | 结束多打一行 Info `[DEEP-DONE] N 条目待深验：已重读重 hash M、不符 a、读取失败/消失 b`（M = N − b：消失/读不出的没被重读；行标独立于逐条 `DEEP` Warn，与 `DEEP-SKIPPED` 配对）——此前干净库上 `--deep` 与不带 `--deep` 输出逐字相同，用户无法分辨「深验跑了没发现」与「没跑」 | e2e 观测缺口 |
| GUI（pm-ui） | CSP `style-src` 收紧为 `'self'`（去掉 `'unsafe-inline'`，F090 实机 CDP 探针证实零违规）；`gui/ui` 新增「无内联样式/无内联脚本」常驻哨兵 | F090 |
| `pm resolve` / `pm undo` / `pm vault ingest` / `pm trash` | 行为不变；README 提要改为与 `--help` 同形（`--unskip`、反向计划语义、ingest 入常用命令、屏障只覆盖 clean-staging/dedupe 两类记录） | 文档审计 |
