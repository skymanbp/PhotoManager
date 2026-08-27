# pm 评审记录（现行卷：第 35 轮起）

> 从 `docs/DESIGN.md` §16 拆出（2026-08-24）；因 750 行预算多次分卷：
> **v0.1→v0.2 设计评审、P3b 逐轮收口**在 [`REVIEW-LOG-1.md`](REVIEW-LOG-1.md)，
> **P4 GUI 与用户决策记录**在 [`REVIEW-LOG-1B.md`](REVIEW-LOG-1B.md)；**第 29–34 轮（P5 后期→P6 中期）**在
> [`REVIEW-LOG-2.md`](REVIEW-LOG-2.md)（2026-08-26 拆出）；每轮评审的逐条
> 处置表在 [`docs/reviews/`](reviews/)。本文件装第 35 轮起的评审段。

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

- **false_positive**：F006（Win.hs rawRename 判语误报）、F016、F024/F098
  （`catRootId` "write-only" 论断被驳，两项同址）、F026（volumeFsType 取首
  盘符幂等）、F063（侧缓存成对写非 dead work）、F087/F092（GUI 两项，机制
  链在复核中断裂）。
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
