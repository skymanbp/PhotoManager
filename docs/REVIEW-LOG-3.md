# pm 评审记录·卷 3（第 35–38 轮 + P7 预审登记）

> 2026-08-27 自现行卷拆出（750 行预算）。上承 [`REVIEW-LOG-2.md`](REVIEW-LOG-2.md)
> （第 29–34 轮），下接 [`REVIEW-LOG.md`](REVIEW-LOG.md)（第 39 轮起的现行卷）。

## 第 35 轮（P6-G `39edbb8`，codex 钉 SHA）——NO-GO，minset 4 条全修

**执行者插曲**：attempt 1 中途被一次计算机强制重启杀死（事件流 373 KB、
28 次命令执行、无 verdict 文件）——半程输出整体丢弃不采信；重启后先做四层
完整性核验（工作树 porcelain 空 / HEAD=`39edbb8` / `git fsck` 静默 /
305 例全绿且零重编译）再整轮重跑，attempt 2 真跑（318 次命令执行）出本轮
verdict。

五镜头先把三十四轮修复全部验干净：resolve/listFlatPhotos/photosJsonRef 的
try 作用域与失败方向、Exec 五口读失败 OFailed 与内容不符 OConflict 的区分、
Doctor 读失败行不进 --repair 白名单、四个 750 行拆分无语义漂移、305=299+6
的叶子数推演成立。minset 4 条聚成一根 + 一条独立：

### 根（F2+F3+F4，minset）：三十四轮的全仓 grep 命中没有逐一记账

三十四轮确实 grep 了 listDirectory/BS.readFile（本卷 34 轮节可证），但
**命中没有逐一记账**——处置清单只落了 hash 家族与 Doctor 六口，目录枚举口
与控制文件读口的命中无分类、无清单，静默掉队。扫而不记账等于没扫：本轮
按 IO 读原语全集清点（listDirectory / BS.readFile / readFile /
hGetContents / withBinaryFile / openBoundTo / statSnap）逐命中分类成表
（见下节），下一轮评审有表可核对，而不是有一句声明可攻击（二十九轮根 B
的教训在读口清单上的重演）。修法沿用既有桶，逐处：

- **F2 Names/Sort 生成期枚举**：`pm names` 的年层/事件层/成片三处
  listDirectory 与 `pm sort` 的 existingEvents 无 try，doesDirectoryExist
  通过后目录被挪走/独占即逃顶。修：与二十五轮 sort、三十三轮 ingest 同
  纪律——枚举整段 try，失败明说 + 零计划 exit 2（Names 整相位一个 try：
  生成期没有「部分成功」，半张清单比崩溃更糟）。
- **F3 Doctor/Trash/Serve 枚举**：`staleTmpFiles`/`trashView` Either 化——
  doctor 读失败落新 Bad 行 TMP-ENUM/TRASH-ENUM（「本轮核不了」如实说；
  绝缘按构造：repairDone 白名单只收 C2/R2/Q-DONE-LOST 的 Warn + oid 前缀，
  Bad 行不触发任何修复，stale 删除清单 = staleTmpFiles 返回值，Left→[] =
  零删除）；`pm trash list/empty` 拒绝并明说（empty 拆 trashEmptyLocked'
  承接原体，Left 不清任何条目）；Serve `/api/plans` 的 listPlans 迁入
  Pm.Plan（loadPlan 旁边，领域归位 + 超预算的 Serve 净减行）并 try——
  此前 warp defaultSettings 把逃逸兜成 500，服务不死但违背 errors 数组
  契约。
- **F4 Config/GitGuard 控制文件读口**：loadConfig 与 pmIgnoreGuard 的裸
  BS.readFile 各包 try 落 Left。方向都是 fail-closed：配置读不出 = 拒绝
  （不猜内容）；`.gitignore` 读不出 = I11 拒绝——核不了 ≠ 已覆盖，与
  「无 .gitignore」同向。

### F1（minset，独立根）：push 无项分支与 status 是两个出口谓词

`hasDiffR` 只看 newActive/missing/renamed/drift；三十四轮把 UNSTABLE 加进
status 出口时是在调用点手写并列，**没有合一回谓词**——push 的无项分支用的
还是旧 hasDiffR：主库唯一一张照片被独占时 `pm vault push` 报 0，自动化
调用方当成「无事可做」。这正是二十一轮 hasDiff/hasDiffR 双谓词分叉的同型
复发（Vault.hs 注释里就钉着那次先例）。修：unstable 项收进 hasDiffR 定义，
status 调用点的手写并列删除——出口判定只此一个谓词，两个消费点同源。

### F5（DOC_ONLY）+ 文档侧顺带发现

README「开发史（P0–P5 全程）」漂移——三十四轮 DOC 修复补了 HISTORY 标题却
没扫 README 同句；本轮连同收敛数字三格一并推进。DESIGN §14 风险行
「枚举…一律落 fail-closed 桶」在 F2-F4 修复前说过头，措辞更正为「三十四轮
全仓 grep、三十五轮按读原语清点补漏」。顺带发现两处既有 drift 一并修：
①DESIGN §4 把 `Plan.hs` 标成「纯函数，无 IO」、性质 1 把它列进纯模块——
savePlan/loadPlan 落进该模块时就已过时（`git show` 父提交可证），据实
改写；②Vault.hs 残留三十四轮拆分期的三个冗余 import（AE/BSL/fromMaybe）
——增量构建的重编译规避一直掩着它们，「GHC 警告 0」的声明只在增量构建下
成立过，本轮全量重编译显形后清除。

### 读口原语清点表（本轮扫法，下轮按此核对）

- **信任读闸（已 try，不动）**：`readPmState`（Config.hs）是 .pm 状态文件
  的唯一读口——loadPlan'/readManifest'/loadCatalog'/readHolds 全部经它；
  Scan.hashOne、Sort.snapshotWith、Ingest probe/mkItem、probeConfined、
  Doctor.probePmSha/verifyFp、Exec 五口、resolveKeep、Names 指纹
  （二十五~三十四轮逐轮上的闸）；Vault.listFlatPhotos 与
  Config.requirePmTrusted 的 .pm 枚举（各自内部 try）、Hash.dirFingerprint
  （原语本体无 try，生产调用点 Doctor/Names/Exec 全部在调用者 try 内）——
  后三处为**三十六轮 F2 补录**：首版清点漏列了这三处已保护命中。
- **零直接命中**：Clean/Dedupe/Import/Versions/Diff/Status/Backup 七模块
  无任何裸读原语——读一律经 Scan/Catalog 单点（codex 镜头③与本方清点
  双向零发现）。
- **本轮修**：Names 三处 + Sort existingEvents + Doctor staleTmpFiles +
  Trash listTrashFiles + Serve(→Plan) listPlans 的枚举；Config/GitGuard
  的控制文件 BS.readFile。
- **界外（登记不修）**：写口逃逸 = §6.4 进程死亡语义（三十四轮已登记）；
  openExclusive 家族是写路径原语；存在性**布尔探针**（doesFileExist/
  doesDirectoryExist）只允许出现在 False→拒绝 的位置——False→放行 的布尔
  探针属修复对象而非豁免（三十六轮 F1：GitGuard 已三态化）。

### 收敛证据

**308 tests（305+3：caseUnstablePushExit / caseConfigReadLocked /
caseGitignoreReadLocked，后两个用 PM_CONFIG 临时改指 + 独占句柄造确定性
占用；trashView Either 化连带 6 个既有用例改经 TestUtil.trashViewOK）**，
GHC 警告 0（全量重编译下核实）。变异 **3/3 各杀恰好一条**（m21 去
hasDiffR 的 unstable 合取 → caseUnstablePushExit；m22 去 loadConfig try →
caseConfigReadLocked；m23 去 pmIgnoreGuard try → caseGitignoreReadLocked；
运行记录在会话 scratchpad `mut35-results.txt`）。m21 预判过可能连带杀
caseUnstableOnLocked，实测不杀——该用例夹具另有可读的 a.jpg 走 NEW，
exit 1 经 newActive 仍成立；判别 UNSTABLE-only 出口的只有新用例，这正是
要补它的原因。枚举口新 try（Names/Sort/Doctor/Trash/Serve）无确定性注入
形态——openExclusiveBinary 锁的是文件，锁不住「目录被枚举」这个动作，
登记为代码级核查（与三十四轮 R2/R9 先例同款）。

## 第 36 轮（P6-H `49ba732`，codex 钉 SHA）——NO-GO，minset 1 条已修

attempt 1 即真跑（204 次命令执行）。五镜头把三十五轮修复全部验干净：
hasDiffR 合一后全仓只有 status/push 两个消费点、Names 整相位 try 对照删除侧
仅缩进迁移、TRASH-ENUM/TMP-ENUM 为 Bad 且修复白名单只收 C2/R2/Q-DONE-LOST
的 Warn 或 C5、staleTmpFiles 的 Left 构造 stale=[] 删除循环零次、
trashEmptyLocked' 承接体与原体一致、/api/plans 保住 errors 数组契约、
SortSource 逐段搬移且再导出面完整、Vault 冗余 import 零残余使用、七个
「零直接命中」模块经原语全集 rg 复核为零、三个新用例判别力成立（Spec.hs
全程预置 PM_CONFIG 使 finally 还原总能成立）、m21 不杀 caseUnstableOnLocked
的登记解释静态核对成立。minset 恰一条：

### F1（minset）：I11 的 .git 存在性探测把「查不出」塌成「不存在」

`pmIgnoreGuard` 与 `findGitAncestor` 用 doesDirectoryExist/doesFileExist 探
`.git`，两者把 ACL/断网/介质错误统统吞成 False——而守卫里 False 的去向是
**放行**（自身「无」→ 祖先扫描；祖先也「无」→ Right ()）。合法 git root 的
`.git` 属性读取遇 ACL/介质错误、root 其余位置仍可写时，I11 全链放行，随后
`.pm` 写进未被 ignore 覆盖的工作树。三十五轮 F4 只关了 `.gitignore` 的
**读**口，同函数上游的**存在性探针**是同一纪律（二十六轮「缺席与读不到必须
分开」）的漏网——且 `Pm.Win.probeName`（P3b-13）当年为消灭的正是这个形状，
仓里自己的注释就点着名（Win.hs：「ACL 拒绝读属性时该层会被当成尚不存在而
放行」）。第一方核实三段俱成立（代码事实 / 未登记 / 模型内可达——§14 明列
介质错误与并发良性进程）。

修：探测改走 probeName 三态，判定收进纯函数 `classifyGitProbe`（Missing →
继续/放行；Plain/Surrogate → git 语境成立，surrogate 含悬空——「当有」只会
引向更严一侧：本层查 .gitignore、祖先层直接拒绝；Unknown → Left 核不了 =
不放行）；`findGitAncestor` 换型 `Either String (Maybe FilePath)` 逐层同
规则（无外部消费者，grep 证实）；`canonicalizePath` 一并 try（规范化失败
Left，不逃顶）。**类界写明**（本卷 §35 界外行 + GitGuard 模块头）：布尔探针
只允许出现在 False→拒绝 的位置——本模块 .gitignore 的 doesFileExist、
requirePmTrusted 的 doesDirectoryExist 均属之，这是三十五轮清点表不含它们
的原因，现在是显式规则而非默会假设。

用例：caseClassifyGitProbe（四构造子穷举——ProbeUnknown 不许给布尔答案）+
caseDanglingGitJunction（端到端判别器：悬空 .git junction 下旧布尔探针答
False 放行、probeName 判 NameSurrogate 要求 .gitignore——GuardTests 位移槽
用例早已实测悬空链接的 False 行为）。ProbeUnknown 无确定性 E2E 注入形态
（错误码 5/53 在测试里造不出来）——这正是把判定提成纯函数的原因：要害格在
类型层穷测，IO 接线薄到只剩一次 probeName 调用。两用例入 StateGuardTests
（「缺席与查不出必须分开」的家，casePmIsPlainFile 同型；GuardTests 已
711/750 行）。

### F2（DOC_ONLY，当轮补录）：§35 清点表漏列三处已保护命中

表声称按原语全集清点，但 Vault.listFlatPhotos（内部 try）、
Config.requirePmTrusted 的 .pm 枚举（内部 try）、Hash.dirFingerprint
（原语本体无 try，生产调用点 Doctor:412 / Names:283 / Exec rename 指纹全部
在调用者 try 内——三处均经评审与第一方双向核实）没落进任何一类。无代码
风险；表已当轮补录（§35 表内三十六轮标注）——「全集」声明必须逐命中可
复核，否则又是一句可攻击的声明。

### F3（DOC_ONLY，当轮修）：README 与 DESIGN 的库规模数字互相矛盾

README「效果」节是 2026-08-25 实测（4859 / 480.9 GiB），DESIGN §1/§12 是
2026-08-22 P0 基线（4635 / 459.3 GiB）——库在长大，两组都真，但互不注明
采样日，读起来就是矛盾。修：DESIGN 两处标注「P0 基线 + 采样日」并指向
README 现库数字；性能预算与验收口径仍按基线（那是它们当时的输入）。

### F4（DOC_ONLY，当轮修）：「Exec 唯一写盘模块」说过头

DESIGN §4 两处逐字称 Exec「全项目唯一有写盘 IO」——实际 Config/Journal/
Catalog/Plan/Trash 都写 pm 自有状态文件。声明的本意是照片字节：已收窄为
「唯一改动照片字节的模块」，状态文件写口显式点名。与三十五轮 Plan.hs
「纯函数无 IO」同族：架构声明与代码事实的漂移，在有人拿它做判断之前据实
收窄。

### 同类扫尽（rule 09）：全仓布尔存在探针逐处分类

按 doesFileExist/doesDirectoryExist/doesPathExist 全集清点 src/ + app/
（约 60 命中），判据 = False 的去向是否放行 ∧ 下游有无响亮失败兜底：

- **False→拒绝/报告即停**（安全方向，不动）：init/backup init/ingest 的
  路径预检、ConfigEdit/Serve 的编辑校验、loadConfig 的「无配置」、
  requirePmTrusted 的「非目录」、GitGuard 的「无 .gitignore」、
  SortSource/Names/Sort 的源根检查。
- **False→继续但下游响亮失败兜底**（不动）：写路径的「old? → delete →
  moveBoundNoReplace」三连（Config writeConfig/writeJsonReplacing、Plan
  savePlan——探针说谎则 no-replace 落位当场炸）；Exec/Apply/Names/Ingest
  的目标占位判定（误判空位 → 执行期 no-replace/I5 复核挡住；误判占位 →
  只是多拒一步）；Exec:335 与 Win slotOccupied 已是 try/异常按占用。
- **False→更保守的误报**（不动，登记）：catalog/侧缓存当缺失重建、trash
  枚举底座缺失答空（清除少删不会多删）、doctor 的 C/R/Q 行判定（探针塌
  False 只流向非 --repair 行或把已完成误报成未完成；--repair 白名单只收
  Warn+oid 组合且只补记录不动字节）、vault listFlatPhotos 目录缺失答空
  （报告面偏 MISSING，push 的 MISSING 只报告）、Scan 的嵌套 root-id 判定
  （塌 False 会把 .pm 内容当照片索引——catalog 污染可重扫修复，计划执行
  仍有全部屏障）。
- **False→放行且无兜底**（修，全仓唯一一处）：`pm init` 的配置存在闸
  （Commands.hs）——exists 塌 False 绕过「配置已存在（--force 覆盖）」且
  mold 丢失，既有备份盘登记被无 --force 覆盖。同 F1 三态化
  （classifyGitProbe 通用化为存在性收口表，消息去 .git 化）；接线无独立
  判别用例（Unknown 不可 E2E 注入；Surrogate 在旧写法下也非静默——落位
  no-replace 会响亮失败），由共享分类器的穷举表 + 本条登记承载
  （三十四轮 R2/R9 先例）。

### 收敛证据

**310 tests（308+2）**，GHC 警告 0（touch 强制重编译改动文件后核实）。变异
**m24（ProbeUnknown → Right False）恰杀 1 条**（穷举表）；**m25
（NameSurrogate → Right False）杀 2 条**——穷举表与悬空 junction E2E 都是
它的设计探测器，不为凑「恰好一条」缩表。运行记录在会话 scratchpad
`mut36-results.txt`。

## 第 37 轮（P6-I `b68cb2e` + P6-I2 `0c48b28`，codex 钉双 SHA）——**GO，minset 空：门禁收敛**

**执行者插曲二**：attempt 1 半途夭折——codex 连续畸形工具调用（missing
field `target`）+ upstream 失败后，把中途分析当最终消息交出（58 次命令
执行、344 字节、无 verdict 行）。看门旧判据（exec>0 ∧ 字节>200）误收——
判据即根因，补上「结果必须含 verdict 行」后整轮重跑；夭折产物改名留证。
重跑 attempt 1 真跑（216 次命令执行）出本轮 verdict。

五镜头全绿：F1 三态修法逐格核对成立（probeName 错误码语义、classifyGitProbe
方向、三条正常路径与父提交等价、surrogate 只朝更严、canonicalizePath 成功
值不变、findGitAncestor 无外部消费者、各调用方拒绝方向保持）；rule-09 重扫
68 个存在性命中逐处落入 §36 四类、无第二个无兜底放行口（init 闸修法核过：
mold 保留、--force 语义保留、probeName 在既有配置锁内无新锁边界）；测试与
变异登记一致（310=308+2、m24/m25 与登记吻合）；文档五处对齐（README「每道
闸都有突变用例」对 init 接线略宽——评审判定 §36 已登记，不重列）；读口回归
未发现新的「已证实且未登记」第三类。**minset: ∅——按用户裁定（"没有『未
登记且模型内可达』的新根，即发布"），门禁自本轮收敛。**

### GO 后收口（quality-over-cost 裁定）：Scan 链接探针塌 False

评审把 `Scan.listTreeWith` 的 pathIsSymbolicLink 异常按 False 继续归为
「已登记未证实残余」（登记点 = 行内注释的自辩）。第一方核实推翻该自辩：
「真实错误会在下面的 stat 再现」只对普通文件成立——junction 属性读瞬时
失败后，递归会**顺利**跟着链接下去，错误永不再现，库外文件被当库内 rel
条目索引（下游：backup 会把外来字节拷进备份根、报告面被污染；删除屏障
不受影响——probeConfined/resolveUnder 拒经 junction 的路径）。可达性与
三十六轮 F1 同类（属性读遇 ACL/介质错误而其余操作成功），一致性要求同判。
修：与 Trash.linkish / Exec.slotOccupied 同纪律——非「不存在」的探测异常
按「是链接」跳过并入错误桶；「不存在」仍走 stat 路径响亮入错；该处 try
同步收窄 SomeException→IOException（Ctrl-C 不吞）。

**链接属性探针类清点**（try-塌 False 形态全仓四处）：Scan（本轮修）；
Trash.linkish 与 Exec.slotOccupied（已保守，为范式）；SortSource 的
rootLink（塌 False 只丢一条「源根是链接」诊断行，无递归/计划决策依赖——
登记不修）。Hash.dirFingerprint 的裸 pathIsSymbolicLink 异常**上抛**进
调用者 try = 响亮 fail-closed，属安全形态（塌 False 才危险，上抛不是）。

**验证登记**：探测异常无确定性注入形态（错误码 5/53 在测试里造不出），
新分支无配对用例、不可变异验证——按三十四轮 R2/R9 先例登记为代码级核查；
310 tests 全绿、GHC 警告 0 维持。收敛既成，转入释放链（逐步摆清单 +
AskUserQuestion，用户裁定在案）。

## 第 38 轮（P6-J `6c6f049`，codex 钉 SHA，聚焦验证轮）——**GO，minset 空**

GO 后收口提交的专项验证（attempt 1 即真跑，watchdog 三判据全过）。四镜头
全绿：①修法等价性逐格核对——四种探针输入只有「Left 非 ENOENT：继续→跳过」
一格变化，`--ignore-all-space` 证实 WalkDotDirs/SkipDotDirs 块纯重缩进，
IOException 收窄只放走本就不该捕的异步异常；错误桶经 srErrors→CLI 逐项
显示且 scan 返回 1、Sort 侧入 sfErrors 呈现语义正确。②同型清点复核：全仓
五个 pathIsSymbolicLink 调用点与 §37 的「四处塌 Bool + 一处裸调上抛」
一一对应无漏项；getFileSize/getModificationTime 只在 statSnap 内、各消费
链均有 fail-closed 归宿。③文档与收敛表述不夸大。④无「本提交内成立 ∧
未登记 ∧ 模型内可达」的新根。

**新登记残余（父提交既存，非本轮引入）**：`freshnessSweep` 过滤
statSnap Left 且只按遍历错误计 errN——已入 catalog 的条目读不出会落
goneN（保守向：新鲜度不过 → 先 pm scan）；**未入 catalog 的新文件**若
stat 失败则对计数不可见。报告面小洞，不在动盘路径上，登记待后续轮裁定。

门禁自此**含 GO 后收口在内**全部过审。释放链已经用户确认启动。

## P7 预审登记（P7-A `8ea11c9` / P7-B `57f5258` / P7-C `2e20791` / P7-D `5b95bc3`——第 39 轮门禁的送审材料）

### P7-A：五条登记残余全闭（含 38 轮新登记的 freshnessSweep）

1. **freshnessSweep 盲区**（38 轮登记）：拆出纯核心 `sweepCounts`——stat 失败
   或遍历层出错的路径**不隐身、不算消失、必入错误数**；顺藤摸出第二个洞：
   `Pm.Status` 把 errN 整个丢弃（三元组），「✓ 索引与磁盘一致」在核对受阻时
   照说、退出码照 0——一并修（四元组入渲染/JSON/退出码）。
2. **SomeException 类清点**（16 个活口逐点处置）：13 处机械收窄 IOException
   （Scan ×4、SortSource ×3 含 snapshotWith、Win ×7 含 setupConsole、Serve
   muteStdout）；worker 循环那处是有害的（async cancel 被洗成 Left）；
   snapshotWith 收窄顺带修掉潜在测试遮蔽（注入的 assertFailure 此前被洗进
   Left）。**volumeFsType 故意保持 SomeException** 并补 why-注释：收窄=死捕
   （能逃出的只有 marshalling 错误）。
3. **init 配置闸组合用例**：`classifyGitProbe <$> probeName <非法字符名>`
   → Left 含「核不了」——与 Commands.hs runInit 逐字同一表达式；全链 E2E
   无确定性形态（锁文件 `<cfg>.lock` 与配置同名系，非法名先炸锁），余下两行
   case 接线以检视覆盖登记。
4. **Scan 探针分支配对 E2E**（37 轮 GO 后收口当时无注入形态）：本轮找到
   确定性注入——见下 ACL 实验；探针失败文件不入索引、带路径入错误桶。
5. **SortSource 根链接探针三态化**：探针失败出说明行（此前塌 False 丢诊断）；
   probeNotes 行本身无确定性注入形态（见实验），按 R2/R9 惯例登记；拒绝下
   确定性成立的那半（源根不可达 → listSource 整体拒绝全空）已钉。

### ACL 注入实验（全组合实测，Windows 11 / NTFS / icacls）

- 拒 (RA)、(RD,RA)、(RD,X)：GetFileAttributesEx 类探针（probeName、文件上的
  doesDirectoryExist）**照常成功**——此路不通。
- 文件级**全拒 (F)**：pathIsSymbolicLink / getFileSize / getModificationTime
  （CreateFile 类）确定性 permission-denied——全仓唯一确定性「非 ENOENT 探针
  失败」注入形态；owner 恒保留 WRITE_DAC，`icacls /remove:d` 还原安全
  （TestUtil.withDenyAll 以 bracket_ 封装）。
- 目录级全拒 (F)：`doesDirectoryExist` 库层塌 `Right False`（fail-closed
  方向，可接受）→「isDir=True ∧ 链接探针失败」组合**无确定性注入形态**。
- probeName 对 ACL 免疫，但非法字符名（`<`）→ ERROR_INVALID_NAME(123) →
  ProbeUnknown（确定性），init 组合用例即用它。

### 变异（round-39 批，逐个恰好配对转红后还原）

```
m1  goneN 失去 fails 剔除     → 2 红（sweepCounts 穷举 + freshnessSweep E2E）
m1b errN 不计 stat 失败       → 1 红（sweepCounts NEW 隐身钉）
m2  scan 探针分支塌回 False   → 1 红（caseScanDeniedProbe）
m3  Status pending 丢 +e      → 1 红（caseStatusFreshnessErrExit）
最终 316/316 绿、警告 0
```

另：Serve.hs 762 → 拆出 Pm.ServeGuard（传输/守卫原语逐字搬移，Serve 683）；Commands.hs 潜在未用 doesFileExist import（P6-I 遗留）清除。

### P7-B：超预算测试模块还债拆分（纯搬移）

ServeTests 952→629 + ServeWriteTests 376；SortTests 1044→571 + SortGuardTests 503；PathGuardTests 816→718 + HandleGuardTests 123（P7-C 内）。用例本体逐字搬移（脚本按行界切割），夹具从原模块导出（第二份夹具迟早与被测解析器分叉）。动机：Config 元数变更被硬预算封锁——两文件各有定位构造点。316/316（数目不变）。

### P7-C：发布配置 + 上线命令生成

- Config +3 字段（`[portfolio] dir`、`[vault]/[portfolio] push`）；渲染器改
  「每张表渲染所有已设字段」——漏字段=下次写回静默抹掉用户设置（round-trip
  用例钉）。`pm init --force` 对三字段照备份盘登记同例保留。
- 新 `Pm.Publish`：`publishCommands`（纯函数，两仓 git 命令文本；pm 不执行
  git，I9）+ `pushTargetOk` 字符闸（生成文本整块复制进终端，能长出第二条
  命令的字符在 checkPatch 入口即拒）。
- serve：ping +`allowApply`、config +publish 对象、新只读
  `GET /api/publish-commands`。
- 变异：m-a 字符闸放开 → 2 红（单元 + checkPatch E2E）；m-b 渲染器丢 vault
  push 字段 → 1 红（round-trip）。322/322、警告 0。

### P7-D：GUI 执行面（用户裁定 2026-08-26「执行 pm 计划」）

- Rust 壳 `--allow-apply` 拉起（服务端**零新增执行能力**——P5-C 端点原样，
  变化只是壳传旗标 + 页面渲染）；计划页两次点击确认（arm/confirm 同一按钮，
  5 秒自动解除），结果/逐项/日志从 JSON 体渲染，指明 pm undo。
- **根修**：`req()` 浅合并让调用方 headers 覆盖 Authorization（sort 页生成
  计划自 P5-E 起 401）——授权头统一并入 req()，全仓不再各自拼。
- 状态页新鲜度补 errors 口径（与 Pm.Status 渲染一致）；「复制上线命令」按钮
  + 设置页三项。验证：node --check、cargo check (msvc)、真库 serve 冒烟
  （ping allowApply=true / config.publish / publish-commands 200）。
