# pm 评审记录（现行卷：第 44 轮起）

> 从 `docs/DESIGN.md` §16 拆出（2026-08-24）；因 750 行预算多次分卷：
> **v0.1→v0.2 设计评审、P3b 逐轮收口**在 [`REVIEW-LOG-1.md`](REVIEW-LOG-1.md)，
> **P4 GUI 与用户决策记录**在 [`REVIEW-LOG-1B.md`](REVIEW-LOG-1B.md)；**第 29–34 轮（P5 后期→P6 中期）**在
> [`REVIEW-LOG-2.md`](REVIEW-LOG-2.md)（2026-08-26 拆出）；**第 35–38 轮与 P7 预审登记**在
> [`REVIEW-LOG-3.md`](REVIEW-LOG-3.md)；**第 39–43 轮与 P7-I / P7-J 第一方全量自审**在
> [`REVIEW-LOG-4.md`](REVIEW-LOG-4.md)（均 2026-08-27 拆出）；第 1–24 轮的评审原文在
> [`docs/reviews/`](reviews/)，此后各轮的逐条处置就在本卷/各分卷的当轮节内。本文件装**第 44 轮**起的评审段。

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
pm-test.exe SHA-256 `f42fc592a28009e92e77b5d04743eb8ab363604cb0df4c94f57a319c9668c961`、pm.exe（`.stack-work/install/…/bin` 副本）`44aa8fd0730b96bbe5ff885ab6273406aa6ea4821187ed164d09fe515ebacb88`。

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
- **GO-note `onException` 无钉**：改用 `FILE_SHARE_NONE` 独占打开（Win32 `createFile …
  oPEN_EXISTING`）为观测点（**46 轮订正**：此处原写「removeFile 观测点不成立——
  openBoundTo 经 cbits 带 FILE_SHARE_DELETE」，被评审用同版本 GHC 探针证伪：
  `openBoundTo` 是 `openBinaryFile`（Win.hs:407），legacy I/O manager 下泄漏句柄同样
  挡删除；独占打开的真理由是它对 legacy 与 WinIO 都成立）：
  泄漏的 GENERIC_READ|WRITE 句柄使其撞 ERROR_SHARING_VIOLATION；钉加在
  `caseAppendTailSameHandle` hardlink 拒绝之后，m4（`onException` → `id`）判红。

判别突变（`mutate4.py`，主树逐个 `git checkout` 还原）：

| 突变 | 文件 | 结果 | 末行 |
|---|---|---|---|
| m1 | package.yaml | RED ✓ |     0.6.0 发布链：pm.exe 不带构建机路径——Main.hs 不用 Paths 模块、版本走 CPP 宏、exe 段显式 other-modules: FAIL (0.09s) / 1 out of 1 tests failed (0.09s) |
| m2 | docs/HISTORY.md | RED ✓ |     41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托 REVIEW-LOG: FAIL (0.01s) / 1 out of 2 tests failed (0.04s) |
| m3 | src/Pm/Versions.hs | RED ✓ |     0.6.0 发布链：pm.exe 不带构建机路径——Main.hs 不用 Paths 模块、版本走 CPP 宏、exe 段显式 other-modules: FAIL (0.08s) / 1 out of 1 tests failed (0.09s) |
| m4 | src/Pm/Win.hs | RED ✓ |     P3b-12 journal/manifest/plan 被 hardlink 占名 → 拒绝写入，库外对象字节不变:                     FAIL /     41 轮 #6 openStateAppendTail：查尾与追加同一句柄——半截尾/换行尾/缺失三态 + hardlink 拒绝 |

P7-P 树：390 测试、GHC 警告 0；pm-test.exe `b0276ba3ac817621ee8d155293ba54199c043a1db4048b8bd2547ddb6497d6f5`、pm.exe（`.stack-work/install/…/bin` 副本）`9fbc577aaff552bb3b7301f83636f10368ece91587502b30cd6f5cc459b6ac43`；
sancheck37 零命中；三份发布产物 leakscan 0 命中。

## 第 46 轮（P7-P `c16c8da`，Claude Opus 5 聚焦）——FINAL NO-GO，minset {1}

评审亲跑 `All 390 tests passed (47.16s)`，双哈希逐字符对上（`b0276ba3…d6f5` /
`9fbc577a…ac43`），编译输入无一新于两 exe，跑前跑后树净；79 次工具调用 / 1759 s。
45 轮六条的修均生效（#3/#4 留残余、#6 的机制记述被证伪，见下）：HISTORY 计数入哨兵（沙箱反向突变红、历史行不受影响）、
「从零编译」全文件清点、段落定位（M4 现红）、引用面（Types.hs 非注释引用红 / 注释
绿）、扫描器入仓（**阳性对照** 0.5.0 期 `target/…/debug/pm.exe` → 12 命中 exit 1；
三份发布产物 0 命中；派生模式两种斜杠齐全，大小写/转义/UTF-16BE 三候选实测 0）、
钉的判别力（同版本 GHC 独立探针：泄漏句柄独占打开 FAILED、关闭后 SUCCEEDED）。
原文存档 `review46-opus-result.md`。

- **#1（major）钉的记录机制被产物证伪**：我在 45 轮节与 HandleGuardTests 注释里写
  「removeFile 观测点不成立——openBoundTo 经 cbits 带 FILE_SHARE_DELETE」。第一方
  复核：`openBoundTo` 就是 `openBinaryFile`（Win.hs:407），`pm_open_for_dispose`
  （cbits/pm_win.c:50）Win.hs:616 导入、仅 :641 `withDisposeHandle` 调用，服务 :696 rename /
  :721 delete——我 grep 到 `FILE_SHARE`
  就归因、没读调用链。评审探针：legacy I/O manager 下 `DeleteFileW` 对泄漏句柄
  FAILED（`__hs_swopen` 的 FILE_SHARE_DELETE 仅 `_O_TEMPORARY` 才置位），只有 WinIO
  才成功。**根因**：用未经核实的机制去驳回评审发现，与 44/45 轮 A/C「沿用记忆不读
  产物」同类且更重（讹传固化进公开源码注释）。修（P7-Q）：注释与 45 轮节改记真机制
  （removeFile 在 legacy 下同样可观测但依赖 I/O manager；独占打开对两种 manager 都
  成立——这才是选它的理由）；**类级**：`caseFolkloreNotInTests` 增加该讹传标志词
  （拼接构造），test/ 下再出现即红。
- **GO-note 存在性断言**（DocDriftTests exe 块 `any`）：再加一个没写 other-modules 的
  exe stanza 仍绿。修：按两空格 stanza 头切块，逐块全称要求（至少一个 stanza）。
- **GO-note `srcModules` 不递归**（P7-J 既有 helper，六个清点用例共用）：修：递归
  枚举 `src/Pm/**/*.hs`，展示名 = 相对路径（平铺文件不变，既有期望不动）。
- **GO-note README 扫描命令**：`pm-ui_<版本>_x64-setup.exe` 在 bash 里是重定向，
  逐字执行一个产物都没扫。修：`V=$(awk '/^version:/{print $2}' ../../package.yaml)`
  + 加引号（版本不手抄）。
- **GO-note 突变表 m4 证据质量**：只见 P3b-12 连带、没出示新钉自身的 FAIL 文案。
  修：`mutate4.py` 捕获 FAIL 后 3 行文案，m4 改 `-p openStateAppendTail` 单点重跑
  （见下；首次用 `-p "41 轮 #6"` 被 tasty 当表达式解析、基线与突变同为 usage 输出的
  **假红**，识别后改用用例名里的无空格 token——`mut4b.log` 作废，`mut4c.log` 为准）。
- **GO-note 失败文案归因**：独占打开失败也可能是第三方瞬时占用 / 文件缺失。修：
  文案列出三种来源并带原始错误文本，不一概归因「句柄未关」。

m4 单点重跑（P7-Q 树，`onException` → `id`）：

| 突变 | 文件 | 结果 | 末行 |
|---|---|---|---|
| m4 | src/Pm/Win.hs | RED ✓ | 41 轮 #6 openStateAppendTail：查尾与追加同一句柄——半截尾/换行尾/缺失三态 + hardlink 拒绝: FAIL (4.47s) / test\HandleGuardTests.hs:202: / 独占打开失败——句柄泄漏（sharing violation）/第三方占用/文件缺失，按错误 |

P7-Q 树：390 测试、GHC 警告 0；pm-test.exe `919e6b07357a6596760e1840a41fc4d48ab46b2d0469744e3c201ed846d8d15a`、pm.exe（`.stack-work/install/…/bin` 副本）`cc67aa56bb76ccc631d8adabbec6cf46024b2b3ee55d9cbebc2726794d882ebf`。

## 第 47 轮（P7-Q `1c57f71`，Claude Opus 5 聚焦）——FINAL GO，minset 空

评审亲跑 `All 390 tests passed (48.79s)`，双哈希逐字符对上（`919e6b07…d15a` /
`cc67aa56…2ebf`，并溯源到 install 副本——见 N5），`.hs/.c/.yaml/.cabal` 无一新于两 exe，
跑前跑后树净。46 轮 minset {1} 的订正叙述这次被**同版本 GHC 9.10.3 独立探针**逐句实证：
legacy manager 下泄漏句柄 `removeFile` FAILED、`+RTS --io-manager=native` 下 SUCCEEDED、
独占打开在两种 manager 下均「泄漏时 FAILED / hClose 后 SUCCEEDED」（`review47-opus/Probe*.hs`）。
五条 46 轮 GO-note 全部 CLOSED：讹传哨兵红（45 轮原句写进 test/ 即红）、exe stanza 全称化
（沙箱 A 加 `pm2:` 红 / B 换位深缩进绿）、`srcModules` 递归（`src/Pm/Sub/Bar.hs` 引用 Paths 红、
平铺展示名不变）、README 扫描命令逐字执行三份产物 `patterns=12 total hits=0`、m4 表行与
`mut4c.log` 逐字符一致且 `-p "41 轮 #6"` 假红机制复现。评审标 UNVERIFIED 一项：「GHC 警告 0」
（硬约束禁 `stack build`）——第一方 `run14.log`：`stack test` 全量重编 390 绿、源码警告 0
（仅 clang `<built-in>` 的 `-Wnonportable-include-path` 既有噪声）。原文存档
`review47-opus-result.md`。

**六条 GO-note，聚类后两根（P7-R 收口，产品代码零改动）**：
- **α「哨兵按字面形态/单一位置写，没穷举同类绕法」（N1/N2/N3）**：N1（major）
  `other-modules: []` 注释掉即假绿——`refsIn` 早备了注释行剔除而此断言没用。修：块内先
  剔 `#` 行再切 stanza（m5 红）。评审另议「改钉 `photo-manager.cabal`」不采：该文件
  **不受跟踪**（`.gitignore`，hpack 生成物；`git ls-files` 无），按 `git ls-files` 复制
  的沙箱拿不到，钉在它上面的用例会在净环境假红；真源仍是 package.yaml，产物侧第二道网是
  发布链 `leakscan.py`（三份产物 0 命中）。N2 讹传标志词单一形态、只扫 test/：修——降为
  **同行共现**判据（`openBoundTo` 与 `FILE_SHARE_DELETE`），扫描面 test/ + `srcModules`
  （src/Pm 递归 + app），自身注释改写避免自命中（m7 src 红 / m8 test 红）。N3 两空格 `#`
  行被当 stanza 头（假红）：修——头须以 `:` 结尾（m6 绿）。
- **β「记述未从产物重读」（N4/N5/N6，与 44/45 轮 A/C 同根）**：N4 46 轮节两处——
  「六条全部 CLOSED」改「修均生效（#3/#4 留残余、#6 机制记述被证伪）」；`pm_open_for_dispose`
  改记 :616 导入 / :641 `withDisposeHandle` 调用 / :696 rename / :721 delete。N5 仓内两个
  pm.exe（dist 未 strip 60.6 MB `170a3d86…` vs install 43.4 MB `cc67aa56…`）：44/45/46/47
  轮哈希行统一标「`.stack-work/install/…/bin` 副本」。N6 `.hs` 注释指向只在本机 scratchpad 的
  `mut4-rows.md`：改指本文件 46 轮 m4 表。

判别突变（`mutate5.py`，主树逐个 `git checkout` 还原；m6 为**期望绿**的误伤对照）：

| 突变 | 文件 | 期望 | 结果 | 末行 |
|---|---|---|---|---|
| m5 | package.yaml（`other-modules: []` → `# other-modules: []`） | 红 | RED ✓ | 0.6.0 发布链…每个 exe stanza 显式 other-modules: FAIL (0.09s) / test\DocDriftTests.hs:275: / package.yaml 每个 exe stanza 均须显式 other- |
| m6 | package.yaml（`executables:` 下加两空格 `#` 行） | 绿 | GREEN ✓ | All 1 tests passed (0.09s) |
| m7 | src/Pm/Versions.hs（加一行 openBoundTo + FILE_SHARE_DELETE 注释） | 红 | RED ✓ | 讹传清扫…不再出现在 src/app/test: FAIL (0.15s) / test\DocDriftTests.hs:199: / expected: [] / but got: [("Versions.hs","openBoundTo FILE_SHA |
| m8 | test/TestUtil.hs（同上） | 红 | RED ✓ | 讹传清扫…: FAIL (0.16s) / test\DocDriftTests.hs:199: / expected: [] / but got: [("TestUtil.hs","openBoundTo FILE_SHA |

P7-R 树：390 测试、GHC 警告 0；pm-test.exe `2de4c25f0eeaae140855168f74153dd1135647553bd726ec43b5443df163abd0`、pm.exe（`.stack-work/install/…/bin` 副本）`cc67aa56bb76ccc631d8adabbec6cf46024b2b3ee55d9cbebc2726794d882ebf`
——与 P7-Q 相同（本提交只动 test/ 与 docs/），1c57f71 上构建的 0.6.0 发布产物继续有效（sidecar 同哈希）。

## 0.6.1 收口（P7-S `dec00e5`，第一方；用户 2026-08-27 五问结案：F090 / 端到端运行时 / README / 全量文档 / 推送发布）

- **F090**（0.6.0 时登记「CSP `style-src` 保留 `'unsafe-inline'`，因不知 Tauri 是否注入内联样式」）：
  发布版 pm-ui.exe 以 WebView2 `--remote-debugging-port` + CDP 探针（`scratchpad/e2e/gui/gui_csp_probe.py`）
  把响应头改写成严格策略并交叉核 meta：探针观测六页 DOM styleEls=0 / styleAttrs=2、零违规；静态清点 app.js 零
  `setAttribute`、`innerHTML` 只赋空串、CSSOM 写 3 行 4 处（`setProperty` / `style.width` / 剪贴板降级的
  `style.position`+`opacity`，不受 style-src 约束）→ 收紧为 `'self'`；前提写成哨兵
  `caseGuiNoInlineStyle`，`caseCspQuoted` 改钉收紧后形态。实测：Tauri 以响应头交付 CSP（无 meta）、
  重排指令、为其注入脚本追加 `script-src` sha256。
- **端到端运行时**：发布版 pm.exe 0.6.0 在沙盒三层库跑 68 步 ok（init → scan → sort → import → backup →
  dedupe/resolve → undo → doctor --deep 含注入损坏 → clean staging → names → vault → config → serve API），
  四类写路径 28 对 sha 逐字节一致，真实库零写入（该次的 steps.json 已被后续复跑覆盖，数字不可再从产物重读；
  0.6.1 发布件的复跑记录见第 48 轮节，e2e 驱动自此按运行写 `logs/run-<ts>/`）。观测缺口：干净库上 `--deep` 与不带 `--deep` 输出逐字相同
  → `DEEP-DONE` Info 汇总行（`caseDoctorDeepSummary`）。初版复用行标 `DEEP` 使 KernelTests「独占占住 →
  恰一条 DEEP」转红——一检查一行标，改独立行标与 `DEEP-SKIPPED` 配对。
- **文档全量审计**：ultracode 工作流 4 维度 45 条 → 逐条对抗核实 34 条成立 → 聚五根类级修（README 安全叙述范围
  / README 命令提要对齐 `--help` / DESIGN 的 P0 前旧计划残留 / DESIGN-COMMANDS 三行 / 手抄轮次与状态），
  余 11 条为评审误读或已登记残余不重开（摘要 `scratchpad/wf1-summary.md`）。新哨兵：DESIGN-COMMANDS 不手抄
  「轮 GO」、README 开发史范围从 HISTORY 标题派生。
- **ProbeUnknown 登记订正**：本文件此前记「crossCat 的 ProbeUnknown 分支需 ACL 夹具」不实——非法字符名即得
  ProbeUnknown（`caseIngestProbeUnknown`）。夹具须建被探类目目录：父目录缺失时 `GetFileAttributesW` 先报
  ERROR_PATH_NOT_FOUND(3) = NameMissing，父目录在才报 ERROR_INVALID_NAME(123)（ctypes 实测），首跑因此假红。
- **公开仓拓扑**：用户裁定「重写历史脱敏后推完整历史」——见 HISTORY P7-S ①；推前门禁加 `rangescan.py`
  （待推范围逐提交扫树 + 提交说明），0.6.1 起 tag 打在 main HEAD。

判别突变（`mutate6.py`，主树逐个 `git checkout` 还原，m9/m14 需重编译；m15 为**期望绿**的误伤对照）：

| 突变 | 文件 | 期望 | 结果 | 基线 | 末行 |
|---|---|---|---|---|---|
| m9 | src/Pm/GitGuard.hs | 期望红 | RED ✓ | All 3 tests passed (0.05s) | FAIL (0.05s) / test\IngestTests.hs:67: / 应报「占名核不了」:       test\StateGuardTests.hs:667: / ProbeUnknown 不得塌缩成布尔答案（fail-open 的形状）: False / init 配置闸组合形态：非法字符名 → ProbeUnknown  |
| m10 | gui/src-tauri/tauri.conf.json | 期望红 | RED ✓ | All 1 tests passed (0.04s) | CSP 逐字：DESIGN 引用的指令逐条出现在 tauri.conf.json 的 csp 里；style-src 只 self（F090）: FAIL (0.02s) / test\DocDriftTests.hs:151: / csp: style-src 只 self（F090 收紧） / 1 out of 1 tests fai |
| m11 | gui/ui/index.html | 期望红 | RED ✓ | All 2 tests passed (0.06s) | F090 前提：gui/ui 无内联样式/内联脚本/on* 属性，app.js 不写 style 属性字符串:                  FAIL (0.02s) / test\DocDriftTests.hs:165: / index.html 不得有内联样式/内联脚本/on* 属性 / expected: [] / 1 out |
| m12 | docs/DESIGN-COMMANDS.md | 期望红 | RED ✓ | All 2 tests passed (0.05s) | 41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托 REVIEW-LOG: FAIL (0.02s) / test\DocDriftTests.hs:260: / DESIGN-COMMANDS 不手抄「…轮 GO」收敛判定（委托 REVIEW-LO |
| m13 | README.md | 期望红 | RED ✓ | All 2 tests passed (0.03s) | 41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托 REVIEW-LOG: FAIL (0.02s) / test\DocDriftTests.hs:263: / README 开发史范围须与 HISTORY 标题一致：P0–P7 / Use -p  |
| m14 | src/Pm/Doctor.hs | 期望红 | RED ✓ | All 1 tests passed (0.14s) | P7-S doctor --deep 覆盖面汇报：干净库 Info 行报条目数/不符 0 且 exit 0；翻一字节 → DEEP-CORRUPT + 不符 1 + exit 1: FAIL (0.09s) / test\SweepTests.hs:68: / expected: 0 / but got: 1 / 1 out of 1 t |
| m15 | gui/ui/index.html | 期望绿 | GREEN ✓ | All 2 tests passed (0.03s) | All 2 tests passed (0.04s) |

P7-S 树：393 测试、GHC 警告 0（仅 clang `<built-in>` 的 `-Wnonportable-include-path` 既有噪声）；
pm-test.exe `3337e5b783077403b611a35c8ea2b4402cde9bcbc1468b7c03f12d368842deb6`、pm.exe（`.stack-work/install/…/bin` 副本）`aa3dbd70ec0cbfad1877ffee0ea3f80f451debe4f562ec05a1cabe423b9e1f3e`。

## 第 48 轮（P7-S `700b26f`，Claude Opus 5 聚焦）——FINAL GO，minset 空

评审亲跑 `All 393 tests passed (33.89s)`，双哈希逐字对上（`3337e5b7…deb6` / install 副本 `aa3dbd70…1f3e`），
67 个编译输入无一新于两 exe，跑前跑后树净；哨兵沙箱核验改在 scratchpad 影子树做（仓内零改动）。F090 在
**发布件 0.6.1** 上复核：头 `style-src 'self'`、六页 A_violations=[]、正面控制（探针主动写 style 属性）被拦；
静态面 app.js 零 `setAttribute`、`innerHTML` 全为清空。DEEP-DONE 四种情形亲跑复现；ProbeUnknown 订正、两条新哨兵、
公开仓拓扑（全史 92 提交逐提交脱敏零命中，`tree(v0.6.0)==tree(origin/main)`）、版本五处、750 预算、依赖/端点
集合相等——全部 CLOSED。评审标 UNVERIFIED 一项：GHC 警告 0（禁构建）——第一方 `run19.log` 全量重编 393 绿、
源码警告 0。原文存档 `review48-opus-result.md`。

**七条 GO-note，评审已聚两根（P7-T 收口，产品代码一处措辞改动）**：
- **α「全称声明要与实测面对齐」（N1/N2/N3/N6）**：N1 `caseGuiNoInlineStyle` 字面表放过 `style='…'`（真会被拦）
  / `style = "…"` / `onsubmit=` / `<script type="module">`——修：判据改**词法**（属性名后任意空白与单双引号、
  任意 on* 事件、非外链或有内容的 `<script>`；app.js 零 `setAttribute`、`innerHTML` 只赋空串、无
  `insertAdjacentHTML`/`outerHTML`/`document.write`/`cssText`），m16–m20 红、m22 绿。N2 `DEEP-DONE` 的「N 条目
  已全量重读」把消失/读不出的也算进去——修：`N 条目待深验：已重读重 hash M（= N − b）、不符 a、读取失败/消失 b`，
  `caseDoctorDeepSummary` 加「删一条目 → M < N」配对（m21 红）。N3 DESIGN-COMMANDS「exit 1 共四个来源」缺
  `--cached` 限定，默认模式第五个来源是新鲜度 pending——修：加限定语 + 第五来源。N6 README 状态写口清单漏
  `pm serve --writable`——修：补入并注明 `--allow-apply` 仍走计划路径。
- **β「记述必须能从产物重读」（N4/N5/N7，与 44–47 轮同根）**：N4 P7-S 节「仅两处 CSSOM 写」漏 app.js:292
  剪贴板降级两处——修：探针观测（styleAttrs=2）与静态清点（3 行 4 处）分写。N5「68 步」的 steps.json 已被 0.6.1
  复跑覆盖——修：P7-S 节改记「不可再从产物重读」，e2e 驱动按运行写 `logs/run-<ts>/`，本节登记发布件复跑（见下）。
  N7 HISTORY:248 残留「第六页」且「旧编号」定性不实（引入提交 fa5ba67 起即居 nav 第二位）——修：改「第六个页面
  （nav 第二位）」/「误编号」。评审另指两处旧卷指针错位（DESIGN-COMMANDS 指 REVIEW-LOG.md §P3b 逐轮收口、P7-J 簇修）
  一并改指 REVIEW-LOG-1 / REVIEW-LOG-4；本卷 739/750 → 第 39–43 轮与 P7-I/J 拆出卷 4。

判别突变（`mutate7.py`，主树逐个 `git checkout` 还原，m21 需重编译；m22 为**期望绿**的误伤对照）：

| 突变 | 文件 | 期望 | 结果 | 基线 | 末行 |
|---|---|---|---|---|---|
| m16 | gui/ui/index.html | 期望红 | RED ✓ | All 1 tests passed (0.08s) | F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，app.js 零 setAttribute、innerHTML 只赋空串: FAIL (0.06s) / test\DocDriftTests.hs:176: / index.html 内联样式属性 / expected: [] / 1 out o |
| m17 | gui/ui/index.html | 期望红 | RED ✓ | All 1 tests passed (0.13s) | F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，app.js 零 setAttribute、innerHTML 只赋空串: FAIL (0.11s) / test\DocDriftTests.hs:177: / index.html on* 事件属性 / expected: [] / 1 out |
| m18 | gui/ui/index.html | 期望红 | RED ✓ | All 1 tests passed (0.13s) | F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，app.js 零 setAttribute、innerHTML 只赋空串: FAIL (0.16s) / test\DocDriftTests.hs:178: / index.html 内联/非外链 <script> / expected: []  |
| m19 | gui/ui/index.html | 期望红 | RED ✓ | All 1 tests passed (0.05s) | F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，app.js 零 setAttribute、innerHTML 只赋空串: FAIL (0.11s) / test\DocDriftTests.hs:176: / index.html 内联样式属性 / expected: [] / 1 out o |
| m20 | gui/ui/app.js | 期望红 | RED ✓ | All 1 tests passed (0.10s) | F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，app.js 零 setAttribute、innerHTML 只赋空串: FAIL (0.10s) / test\DocDriftTests.hs:181: / app.js innerHTML 只允许赋空串 / expected: [] / 1 |
| m21 | src/Pm/Doctor.hs | 期望红 | RED ✓ | All 1 tests passed (0.31s) | P7-S doctor --deep 覆盖面汇报：干净库 Info 行报待验/已重读/不符 0 且 exit 0；翻一字节 → DEEP-CORRUPT + 不符 1 + exit 1；消失条目不算已重读: FAIL (0.37s) / test\SweepTests.hs:82: / 已重读数须扣除消失条目: ["2 \26465\30 |
| m22 | gui/ui/index.html | 期望绿 | GREEN ✓ | All 1 tests passed (0.12s) | All 1 tests passed (0.07s) |

P7-T 树：393 测试、GHC 警告 0；pm-test.exe `7f53c05ffb80e4c21e12f06d9ca8c74456fd664bbc998f164d3e90d3f090b3f7`、pm.exe（`.stack-work/install/…/bin` 副本）`18badebb3b0e5dedf722e7c77895bc85b568a5dcb2bab2dd76b28375c52fa5fd`。
0.6.1 发布件（`release061.sh` 于 P7-T 树重建）：zip `dd5e3d7eef0592052475a7b26bcedb231575154688dcfee1306fc6bf363b3e49`、setup `d1a719b89fa825e55e987e3df382081ceb29de9bd7de10c0519538270ca1b060`，leakscan 16 模式 0 命中；GUI 探针头
`style-src 'self'`、六页零违规、正面控制被拦；CLI e2e `logs/run-061-p7t/` 69 步 0 not ok（第 34 步
`[DEEP-DONE] 18 条目待深验：已重读重 hash 18、不符 0、读取失败/消失 0`），真实库 4894 文件 / 516907900342 B 前后逐字段相同。

## P8-A 预算拆分（第一方，2026-08-27；P8 工作包第一步，零产品行为变化）

用户 2026-08-27 交付 P8 七项工作包（Photography 为相片 SoT、成片→相册通道、相册→vault `_inbox` 投影 + 分类 +
推送提示、AI 分类/定位 GUI 入口、非 jpg 一键转换、vault 侧技能、GUI 审查后全量文档、GitHub Actions 出二进制并
发布收官）。理解阶段走 ultracode 工作流（7 读者 + 综合简报 + 两路对抗核查，均 needs-fix：15 条驳回 / 22 条缺口，
原文存档 `scratchpad/p8-understand.md`、`p8-checks.md`）——实测 `DESIGN.md` 与 `Serve.hs` 各 750/750、`app.js`
724/750，任何 P8 功能都写不进去，故先拆分：

- `Serve.hs` → `Pm.ServeEnv`（`ServeEnv`/配置快照/两个应答别名）+ `Pm.ServeVault`（四个 vault 端点 + 请求体类型，
  case 分支包成 `Maybe`，`routeWith` 先问它再走本表）；`app.js` → `vault.js`（分类推送页封成 `window.pmVault` 工厂，
  `busy()` 替代跨文件的 `submitting`）；`DESIGN.md` §11 整节 → `DESIGN-GUI.md`（存根留位，编号沿用）。三处均逐字搬移。
- 哨兵：读 §11 的 `caseGuiNavOrder` / `caseCspQuoted` / `caseConfigLockCensus` 同 commit 改读 `DESIGN-GUI.md`；
  `caseGuiNoInlineStyle` 改扫 `gui/ui` 全部 `.js` 并要求每个脚本被 index.html 外链（拆分不得让哨兵漏看文件、不得留死
  脚本）；新增 `caseLineBudget`——750 行预算此前零自动化（核查缺口 M1.5），现由 `stack test` 执行、CI 复用。
- 据实更正 `DESIGN.md` §1.3「vault `.gitignore` 不含 `.pm/`（P5 需补）」——实际早已含（核查缺口 M1.7/M2.13）。
- 核查驳回的简报断言本轮已按类改写进计划（vault root 尚未建立、PROJECTED 与 splitHeld 的自相矛盾、HELD 机制描述、
  dedupe 回归不存在、`jpegExt` 第二谓词、行号漂移）——设计裁定在下一步 AskUserQuestion 后落 `DESIGN-P8.md`。

判别突变（`mutate_p8a.py`，运行期文件突变、逐条单点 `-p '/token/'` 重跑、每条还原后复跑绿）：

| id | 突变 | -p | 基线 | 期望红 | 突变输出 | 还原 |
|---|---|---|---|---|---|---|
| m-a | scripts/_mut751.py 751 行 → 750 行预算哨兵 | `/750/` | All 1 tests passed (0.12s) | RED ✓ | 750 行预算（DESIGN §16）：手写源码/测试/文档/页面/脚本全部 ≤ 750 行（P8-A 起自动化）: FAIL (0.13s) | GREEN ✓ |
| m-b | gui/ui/_dead.js 未被 index.html 外链 → F090 哨兵 | `/F090/` | All 2 tests passed (0.03s) | RED ✓ | F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，全部脚本零 setAttribute、innerHTML 只赋空串、每个脚本都被外链: FAIL (0.01s) | GREEN ✓ |
| m-c | DESIGN-GUI.md 四条读改写路径声明改字 → 配置锁清点哨兵（改读 DESIGN-GUI 后仍钉住） | `/withConfigLock/` | All 2 tests passed (0.13s) | RED ✓ | 配置锁清点：withConfigLock 调用模块集合 = DESIGN-GUI 声明的四条读改写路径: FAIL (0.07s) | GREEN ✓ |
| m-d | DESIGN-GUI.md ①**状态** 标记破坏 → 页序哨兵（改读 DESIGN-GUI 后仍钉住） | `/nav/` | All 1 tests passed (0.01s) | RED ✓ | GUI 页序：DESIGN-GUI ①—⑥ 的顺序与 index.html 的 nav 次序一致: FAIL (0.02s) | GREEN ✓ |
| m-e | DESIGN-GUI.md style-src 引用改字 → CSP 逐字哨兵（改读 DESIGN-GUI 后仍钉住） | `/CSP/` | All 1 tests passed (0.02s) | RED ✓ | CSP 逐字：DESIGN-GUI 引用的指令逐条出现在 tauri.conf.json 的 csp 里；style-src 只 self（F090）: FAIL (0.02s) | GREEN ✓ |

P8-A 树：394 测试、GHC 警告 0（仅 clang `<built-in>` 的 `-Wnonportable-include-path` 既有噪声）；`node --check` 两脚本通过；
pm-test.exe `0d76f4ef699f5b0d07b2595c9cf73443639a93dbf2f787bd453270ca67530913`、pm.exe（`.stack-work/install/…/bin` 副本）
`0f7a01623b66b92bea7246137e0ffdfa51557672c2697081d8ecefaa915552a2`；`wc -l`：Serve.hs 544 / app.js 584 / DESIGN.md 607 / DESIGN-GUI.md 173。

## P8-B 相册通道（第一方，2026-08-27；DESIGN-P8.md §19）

用户裁定 R2（D′：不把 diff 落进 `_inbox`，只报告）与 R8（`pm album add`）之后的第一段功能代码。相册的两条入口
（`pm import --also-album` / `pm album add`）共用 `Pm.Album.classifyAlbum` 一份判定；I7 次序靠 `piGroup` 与 Exec 既有组语义
（成片项没落位 → 同组相册项 `NOT-EXECUTED`），返修项走 `coupleWithMain` 同款耦合而不分组（复合组成员不能单独 `--keep`）。
`Ingest.jpegExt` 并入 `pushableExt`（核查缺口「第二份 jpg 谓词」闭合）；三处计划收尾上提 `Pm.Cli.emitPlanTo`。

判别突变（`mutate_p8b.py`，源码级、逐条重建、`-p P8-B` / `-p jpegExt` 单点重跑、每条还原；末尾重建 + 复跑绿）：

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| m1 | withAlbumForImport: drop grouping of 成片 item (相册 item still grouped) -> I7 group e2e red | `P8-B` | RED OK | --also-album（纯）：成片项与相册项同组、返修 → 相册项待裁决不分组、Raw 无相册项、非 jpg 交代:            FAIL |
| m2 | classifyAlbum: 同名异容 judged as already (I5 bucket lost) -> five-bucket case red | `P8-B` | RED OK | classifyAlbum 五桶：拷贝 / 已在（同 sha）/ 同名异容 / 同批撞名（case-fold）/ 非 jpg:        FAIL |
| m3 | classifyAlbum: non-jpg sources enter the copy bucket -> tif accepted, five-bucket + e2e red | `P8-B` | RED OK | classifyAlbum 五桶：拷贝 / 已在（同 sha）/ 同名异容 / 同批撞名（case-fold）/ 非 jpg:        FAIL |
| m4 | classifyAlbum: same-batch basename collision (case-fold) not detected -> five-bucket + e2e red | `P8-B` | RED OK | classifyAlbum 五桶：拷贝 / 已在（同 sha）/ 同名异容 / 同批撞名（case-fold）/ 非 jpg:        FAIL |
| m5 | Ingest: a local jpegExt name comes back -> DocDrift dead-name sentinel red | `jpegExt` | RED OK | 死名清扫：opRelPaths / isPng / stemKey / jpegExt 不再出现在 src/app: FAIL (0.30s) |

final build rc=0; P8-B rc=0 (All 6 tests passed (0.62s)); jpegExt sentinel rc=0 (All 1 tests passed (0.12s))

P8-B 树：400 测试、GHC 警告 0（clang `<built-in>` 噪声同前）；pm-test.exe `94880e3881c347b7b2f16c41d080e3de4a38a36d222b74e5920f30308cbd1cfa`、pm.exe（`.stack-work/install/…/bin`）`a51af3fa80b7e5156cae175efdacb26ca0428b3ef40040259352eb30f72d86c6`。


## P8-C 照片记录（第一方，2026-08-27；DESIGN-P8.md §21）

第二份主库侧记录。设计上与「暂不同步」名单同一纪律，因此实现上先把 HELD 的四层壳上提为共用（文件读写 /
事务 / CLI / 端点），再把 notes 挂上去——两份记录一份代码，hold 行为零改动（P4-7 用例只改夹具、净减）。
状态判定加了设计没写的第五态 `unknown`：photos.json 读不出时若答 `pending`，`/photo-publish` 会把已上线的照片再渲染一条
（重复上线）；按 photosJsonRef 既有的 fail-closed 口径改为「未知，要人看一眼」并计入退出码。

突变 m2（记录取 catalog 缓存 sha 而不真实重读）首跑**未判红**。根因不在 notes：「陈旧 catalog 命中 stat」夹具写的
catalog 带固定 id `"m"`，而 `mkMain` 的 root-id 是 `"main-rid"`——41 轮加的 catalog 身份闸把它整份拒载，主库缓存为空，
每个 sha 都真实重读，前提静默失效；P4-7 的 `caseHoldStaleEqualLen` / `caseHoldCreateFreshSha` 自那轮起同样空转（绿得毫无
意义）。类级修：`plantStaleCatalog` 读真实 root id 写 catalog，并把「载得进（`CatLoaded`）+ `statHitStable` 命中」写成夹具内
断言；hold 侧补 m6。二次跑 m2 / m6 都红——旧的 hold 突变结论（codex 二十一/二十二轮）此前已无守卫，现在重新有了。

判别突变（`mutate_p8c.py`，源码级、逐条重建、`-p P8-C` / `-p P4-7` 单点重跑、每条还原；末尾重建 + P8-C / P4-7 复跑绿）：

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| m1 | parseCoordinates: -90..90 / -180..180 range gate removed -> pure validation + lifecycle red | `P8-C` | RED OK | P8-C 纯校验：坐标格式/越界、source、控制符/超长、类目、无字段 → 拒；同名两条/带路径名/坏 sha → 拒；合法通过并按名排序:                                                       FAIL |
| m2 | noteOpsIO: sha taken from vrSrcMeta (stat-hit cache) instead of freshSrcSha -> create-fresh-sha case red | `P8-C` | RED OK | FAIL (0.10s) |
| m3 | withVaultTxn: root lock dropped -> foreign-lock case red (hold case would also go red) | `P8-C` | RED OK | FAIL (0.15s) |
| m4 | noteStatuses: photos.json unreadable reported as pending instead of unknown -> lifecycle red | `P8-C` | RED OK | FAIL (0.77s) |
| m5 | recordPost: --writable gate removed -> serve notes case red (read-only POST lands) | `P8-C` | RED OK | P8-C serve GET/POST /api/vault/notes：只读 403 而 GET 仍可；坏坐标/非相册名/空请求 400 带 details；set 后 GET 列出 unsynced 且字段已规范化；clear 后 count 0: FAIL |
| m6 | holdOpsIO: sha taken from vrSrcMeta instead of freshSrcSha -> hold create-fresh-sha case red (fixture now really hits the cache) | `P4-7` | RED OK | FAIL (0.10s) |

final build rc=0; P8-C rc=0 (All 6 tests passed (2.15s)); P4-7 rc=0 (All 9 tests passed (3.14s))

P8-C 树：405 测试、GHC 警告 0（clang `<built-in>` 噪声同前）；pm-test.exe `a0e6ab368d3919338e580e5a81ee2c5a4ddb9be1ad06c577e7b658aeeab55eab`、pm.exe（`.stack-work/install/…/bin`）`2bbb41420d01319f48448ac6ed50e7876876390beb60f546e0ebf3073c893e12`。

## P8-C2 转换（第一方，2026-08-27；DESIGN-P8.md §20）

两段式按 §20 落地；三处 as-built 与设计的差别都回改进 §20/§25/§26：RAW 明确拒绝、同批转换后撞名先于转换整批拒绝、
doctor 多一种 `DERIVED-TMP`。判定不另写一套——`classifyAlbum` 参数化为 `classifyInto`，import `--also-album` 的耦合规则
上提为 `attachAlbumItems` 供 convert 共用（聚类→上游：第三条「主层项 + 相册项」通道不该有第二份 I7 逻辑）。

`caseByteExitCensus` 按设计转红（Convert.hs 成了 `deleteBoundAt` 的第七个引用模块）。处置不是把它豁免掉，而是 DESIGN §4
据实扩：Convert 删的只有 `--redo` 的旧派生件与失败半成品——`.pm/derived` 是 pm 自建状态，与 Config/Catalog/Plan 同列，
不是照片字节出口；哨兵集合与文档句子一并钉住。

残余登记：`deriveOne` 失败路径的「清掉 .tmp」没有确定性判红形态——Pillow 12.3.0 的 `Image.save` 在编码失败时会删除它自己
新建的文件（`created` → `os.remove`，源码核过），python 失败因此从不留 tmp；剩下的形态只有 rename 失败（`final` 在删除与
落位之间被别人占住），无可注入形态。该行保留为防御，不冒充有覆盖。

判别突变（`mutate_p8c2.py`，源码级、逐条重建、`-p P8-C2` 单点重跑、每条还原；末尾重建 + P8-C2 / P8-B 复跑绿）：
（表内「突变输出」列的用例标签是突变跑时的文本；之后只把端到端用例的标题补成现名——`--redo` / I7 两段早已在断言里——再重建、全套 408 绿并取下方哈希。）

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| m1 | pillowScript: 1/256 scaling of 16-bit samples dropped -> deep.tif pixel clips to 255, e2e red | `P8-C2` | RED OK | 端到端：16 位 tif→L≈117、RGBA→白底、RGB 原样；--also-album 同组；复用派生件；坏源不留 .tmp；源字节不动:                  FAIL (2.94s) |
| m2 | convertPlan: main-layer conflict sources not excluded from pendingSrc -> album copy executes while main is NEEDS-DECISION, e2e red | `P8-C2` | RED OK | 端到端：16 位 tif→L≈117、RGBA→白底、RGB 原样；--also-album 同组；复用派生件；坏源不留 .tmp；源字节不动:                  FAIL (6.77s) |
| m3 | scanDerived: stale judged by <sha> dir name (source in index) instead of file sha -> pending misreported stale, doctor case red | `P8-C2` | RED OK | doctor：DERIVED-STALE/ORPHAN/TMP Warn、PENDING Info；--repair 只删前三种、留 pending:               FAIL (0.10s) |
| m4 | runConvertTo: pushableExt refusal removed -> a.jpg accepted, refusals case red | `P8-C2` | RED OK | 参数闸：空 / 缺索引 / 已是 jpg / RAW / 层外 / 绝对与 .. / 同批撞名 / PM_PYTHON 不存在 → exit 2，.pm/derived 不出现: FAIL (0.85s) |
| m5 | deriveOne: --redo ignored -> rerun with redo still says reuse, e2e red | `P8-C2` | RED OK | 端到端：16 位 tif→L≈117、RGBA→白底、RGB 原样；--also-album 同组；复用派生件；坏源不留 .tmp；源字节不动:                  FAIL (3.70s) |
| m6 | attachAlbumItems: main item not marked as group head -> convert plan main item has no group, e2e red | `P8-C2` | RED OK | 端到端：16 位 tif→L≈117、RGBA→白底、RGB 原样；--also-album 同组；复用派生件；坏源不留 .tmp；源字节不动:                  FAIL (3.22s) |

final build rc=0; P8-C2 rc=0 (All 3 tests passed (8.36s)); P8-B rc=0 (All 6 tests passed (0.69s))

P8-C2 树：408 测试、GHC 警告 0（clang `<built-in>` 噪声同前）；pm-test.exe `5befd1f77bbbc72944229f9edd4cca0e47a03a50826e6d2198cc0a78c5820bed`、pm.exe（`.stack-work/install/…/bin`）`9a72474d9166be5856cf631be88e20abfc41de0cd4f1e4cf2045fa1ca058fd0f`。


## P8-D 归档页端点 + AI 建议（第一方，2026-08-27；DESIGN-P8.md §22–23）

范围：`Pm.ServeAlbum`（`POST /api/import/plan` / `GET /api/album/candidates` / `POST /api/album/add-plan` / `POST /api/convert/plan`，共用 `planPost` 壳；sort/plan 也改走它）、`Pm.ServeAi`（`POST /api/suggest`：`claude -p --output-format json --permission-mode plan --max-turns 8`，提示经 stdin，`PM_CLAUDE_EXE` / `PM_SUGGEST_TIMEOUT`，`seSuggestLock`）、`ServeGuard.withJsonBody`（五处「上限 → JSON」链合一）、`SortSegment.sgFiles`、GUI 第七页 `archive.js` + `vault.js` 三格记录/AI 建议 + `app.js` 整理页 AI 建议地点、DocDrift `caseGuiNavOrder` ①—⑦ + 新哨兵 `caseRouteRoster`。

第一方自审要点：① 三个计划端点不各写一遍 403/413/400/响应壳——上提为 `planPost`，并把 sort/plan 迁进来（类级，不留第五份复制）；② JSON 体读取此前 config / sort / apply / backup-init / recordPost 五份同形代码，合一为 `withJsonBody`；③ suggest 端点是只读级但仍过 `requireRole` + catalog + `resolveUnder`（链接别名不交给模型），名字闸五种一次列完（400 带 `details`）；④ place 不信任客户端分段，serve 自己重跑 `surveySort`；⑤ 子进程三根管道显式 utf8，超时由 `timeout` + `withCreateProcess` 收尾杀进程；⑥ 页面：AI 只预填、类目只描边，记录写入次序 hold → notes → push-plan。

真实 `claude` 探针（不进测试）：2.1.243，`findExecutable "claude"` 命中 `claude.exe`；`-p --permission-mode plan --output-format json` 信封含 `result` / `is_error` / `permission_denials` / `total_cost_usd`；cwd 内 Read 图片 `permission_denials: []`；每次 ≈ $0.7–1.3（系统提示缓存写入占大头）→ 页面文案写明费用与「你自己账号」。

文档哨兵自证（改代码先于改文档时的一次真实判红）：`caseRouteRoster` 在 DESIGN-GUI 未登记 5 个新端点时红（expected 18 条 ≠ got 23 条，差集恰为 import/plan、album/candidates、album/add-plan、convert/plan、suggest）；`caseGuiNavOrder` 红于「DESIGN 应包含 ③**归档**」；两者在文档扫面后绿。

判别突变（`mutate_p8d.py`，源码级、逐条重建、`-p P8-D` 单点重跑、每条还原；末尾重建 + P8-D / P7-J 复跑绿）：

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| m1 | planPost: writable gate removed -> read-only serve answers 200 on import/plan, 403 assertion red | `P8-D` | RED OK | POST /api/import/plan：只读 403 且 .pm/plans 不出现；alsoAlbum → 相册项进计划、log 有「相册 +1」:                                                    FAIL |
| m2 | suggest: seSuggestLock busy answers 200 instead of 409 -> concurrency assertion red | `P8-D` | RED OK | POST /api/suggest classify：只读级放行；预置回答规范化（未请求的名字丢弃、坐标规范）；400 五种；413；502 垃圾/退出非零；409 缺 claude/超时/并发；.pm 零写入:                       FAIL |
| m3 | classify: unrequested names not filtered -> ghost.jpg appears in items, classify case red | `P8-D` | RED OK | POST /api/suggest classify：只读级放行；预置回答规范化（未请求的名字丢弃、坐标规范）；400 五种；413；502 垃圾/退出非零；409 缺 claude/超时/并发；.pm 零写入:                       FAIL (0.25s) |
| m4 | place: RAW-only segment not answered blind -> basis lacks 没有可看的图, place case red | `P8-D` | RED OK | POST /api/suggest place：serve 自己重跑分段抽样；围栏 JSON 解析；只有 RAW 的段不交给模型答 null；>12 段 400:                                                FAIL (0.19s) |
| m5 | extractJson: bracket slice dropped -> fenced ```json answer becomes 502, place + pure cases red | `P8-D` | RED OK | POST /api/suggest place：serve 自己重跑分段抽样；围栏 JSON 解析；只有 RAW 的段不交给模型答 null；>12 段 400:                                                FAIL |
| m6 | readBodyCapped: 64 KiB cap removed -> oversized suggest body no longer 413, classify case red | `P8-D` | RED OK | POST /api/import/plan：只读 403 且 .pm/plans 不出现；alsoAlbum → 相册项进计划、log 有「相册 +1」:                                                    FAIL |

final build rc=0; P8-D rc=0 (All 8 tests passed (8.88s)); P7-J rc=0 (All 27 tests passed (1.78s))

残余（无判红形态，如实登记）：GUI 三个脚本只过 `node --check` + DocDrift 静态规则（无内联、脚本外链、无 setAttribute / innerHTML 赋值），交互行为待用户 GUI 审查（计划步「提醒 GUI 审查」）；真 `claude` 只探针不进测试（夹具 `fake-claude.cmd` 顶替，模型答案的质量不在 pm 的可判范围）；`seConvertLock` 排队只有并发交错才可观测，未配突变。

P8-D 树：415 测试、GHC 警告 0（clang `<built-in>` 噪声同前）；pm-test.exe `cf21184799d55095bbcbb3fb5ea7a9194ccae0dc2ea182bff917d5f9fdb2db48`、pm.exe（`.stack-work/install/…/bin`）`d8e8c1a176f78b8aca3d064c930e8644d4207e36793a573d5e91e90fa4995a0d`。

## 门禁步 第一方全量审 · 修复批（2026-08-27/28；DESIGN-P8.md §20.1 写纪律 / §22 / §25 / §26）

范围：P8-A～P8-E 全量（`Pm.Convert` / `Pm.Album` / `Pm.ServeAlbum` / `Pm.ServeAi` / `Pm.ServeVault` / `Pm.VaultCmd` / `Pm.Vault` / GUI 三脚本 / DESIGN*）。方法：Ultracode 评审工作流——7 个视角（写纪律 / 并发与锁 / 边界与准入 / GUI 状态机 / 文档—代码漂移 / 测试证据 / 子进程）各出发现，major 以上每条 2 个独立反驳者；11 项确认（C0–C10）、6 项否证（ServeAi stdin 次序、photosJsonRef 未配置、vaultCat DRIFT 塌缩、argv 测试锚、resolveUnder 负例、--also-album 负例）、30 条 minor 逐条处置。

确认项按上游根因聚成八簇（用户指令「记得聚类然后找上游根因」）：

| 簇 | 确认项 | 根因 | 类级修复 |
|---|---|---|---|
| A | C0 / C2 critical、C3 major | `deriveOne` 的 tmp 与终名用字符串拼接、只 `doesFileExist` 一次；python 自己 open 目标——预置的 hardlink / symlink 能把库外文件当目标写穿或当派生件读入；派生—落位—测 sha 不在根锁内 | 完整相对路径各过 `resolveUnder` 只用返回值；tmp 由 pm `openFreshBinary`（CREATE_NEW，残留先清）独占创建再交 python；复验普通名 + `openStateRead` 单链接同句柄测 sha → `moveBoundNoReplace` → 落位后 size 复核；整段 `withRootLock`；复用同规格；`try` 收所有 IOException |
| B | C5 major + python 无超时 / 码页解码 | `timeout` 只终止直接子进程，`claude.cmd` → node 子树在锁放开后照跑；python 那份根本没有超时 | 新模块 `Pm.Subprocess.runTool`：UTF-8 三管道、stdin 一次喂完、`race` 计时到点先 `taskkill /T /F` 杀整棵树；`envTimeout`（`PM_SUGGEST_TIMEOUT` 180 / `PM_CONVERT_TIMEOUT` 600）；claude 与 python 同壳 |
| C | C1 major | 候选栏「非 jpg」= `¬pushableExt`（含 RAW），convert 准入另写一份拒 RAW——两份谓词 | `VaultCore.convertibleExt` 一处定义，`albumCandidates` 与 `runConvertTo` 共用；AlbumTests 夹具把 RAW 放进成片/相册（此前放 Raw\ 下测不到） |
| D | C6 / C8 major、C9 critical | 页面基线越页：`heldInitial` 照单全收整个文件；UNPUSHABLE 混在 new 里渲染成可指派卡；记录类目不回显 → 未碰的卡被算成「清掉类目」 | `/api/vault/new` 剔除并单列 `unpushable`（只读卡）；`heldInitial` 只收本页名字；`assign` 从回显记录预置类目；`suggesting` 与 `submitting` 互斥 |
| E | C7 major | `applyPlan` 的 `await loadPlans()` 在 try 内，刷新失败把「执行完成」换成「请求失败」 | 刷新移出 try 作附注（与其余四处 loader 同律）；`loadPlans` 的自动 `showPlan` 也包 try |
| F | C4 major | 派生伪条目按 `(sha, stem)` 唯一，两条同内容同名源共用一份，`convertPlan` 的目标表按伪条目路径键入 → 第二条静默吞掉第一条、exit 0 | `sameDerived` 先于任何转换拒绝；`convertPlan` 返回 `Either`，撞名 fail-closed（不再只在交代里提一句） |
| G | C10 major + 文案 | DESIGN §2 I2「仅三条路径可产生」quarantine，代码七处构造 | I2 行据实清点七处产地；新哨兵 `caseQuarantineCensus` 钉住引用 `OpQuarantine` 的模块集合并要求 I2 逐一点名；`vault status` / `doctor --repair` 帮助文本、DESIGN-GUI `dropped` 含义与 502 条件、README 信任项 4（hardlink 走 link count） |
| H | minors | `planPost` 无 try（空 500）、取锁不在 mask、信封 `is_error` 未读、`scanDerived` 基目录是链接答「无派生件」、`findClaude` 注释错、archive.js 吞 warnings | 逐条修；`is_error` 夹具第六模式 + 502 用例 |

未采纳 / 登记为残余（如实）：`ensureVaultRoot` 的 `putStrLn`（CLI 首建路径可见，serve 路径静音无害）；`photosJsonRef` 子串匹配（photos.json 以完整 URL 引用，误报只会更保守）；notes set∩clear 冲突已由 `VaultCmd` 拒绝但未配用例；`heldStale` 在状态页无清除入口（unhold 即清）；`withRootLock` 内派生与 `killTree` 无独立判红形态（跨进程 / 进程树只有并发交错可观测）；GUI 改动只过 `node --check` + DocDrift 静态规则，交互行为待用户 GUI 审查。

新用例：`ConvertTests.caseDerivedGuards`（① tmp 名被库外 hardlink 占住 → 清掉重建、bait 字节不动；② 终名 symlink → 拒；③ 终名库外 hardlink → 复用拒；④ 同 sha 同名两源 → 先拒；⑤ `PM_CONVERT_TIMEOUT=1` + `slow-python.cmd` → 预检即超时、点名变量、无 .tmp）；`DocDriftTests.caseQuarantineCensus`；AlbumTests RAW 入成片 / 相册；ServeP8Tests `iserror` 502；ServeTests `/api/vault/new` `unpushable`。

判别突变（`mutate_s9.py`，源码级、逐条重建、单组重跑、每条还原；s9 为文档突变不重建；末尾重建 + 五组复跑绿）：

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| s1 | deriveOne: openFreshBinary pre-creation removed -> python writes through hardlinked tmp, outside bytes change, guards case red | `P8-C2` | RED OK | 步 9 派生件写纪律：tmp 名被库外 hardlink 占住 → 清掉重建、库外字节不动；终名是 symlink / 库外 hardlink → 拒绝不复用；同 sha 同名两源 → 先拒；PM_CONVERT_TIMEOUT 到点 → 杀树 exit 2、无 .tmp: FAIL (1.05s) |
| s2 | deriveOne reuse: openStateRead single-link check dropped -> outside hardlink reused as derived jpg, guards case red | `P8-C2` | RED OK | 步 9 派生件写纪律：tmp 名被库外 hardlink 占住 → 清掉重建、库外字节不动；终名是 symlink / 库外 hardlink → 拒绝不复用；同 sha 同名两源 → 先拒；PM_CONVERT_TIMEOUT 到点 → 杀树 exit 2、无 .tmp: FAIL (1.84s) |
| s3 | deriveOne: symlinked final name not refused -> convert proceeds, guards case red | `P8-C2` | NOT RED XX | All 4 tests passed (14.18s) |
| s4 | runConvertTo: sameDerived refusal removed -> two sources share one derived jpg silently, guards case red | `P8-C2` | RED OK | 步 9 派生件写纪律：tmp 名被库外 hardlink 占住 → 清掉重建、库外字节不动；终名是 symlink / 库外 hardlink → 拒绝不复用；同 sha 同名两源 → 先拒；PM_CONVERT_TIMEOUT 到点 → 杀树 exit 2、无 .tmp: FAIL (2.86s) |
| s5 | runConvertTo: PM_CONVERT_TIMEOUT ignored -> slow python not killed at 1 s, timeout message missing, guards case red | `P8-C2` | RED OK | 步 9 派生件写纪律：tmp 名被库外 hardlink 占住 → 清掉重建、库外字节不动；终名是 symlink / 库外 hardlink → 拒绝不复用；同 sha 同名两源 → 先拒；PM_CONVERT_TIMEOUT 到点 → 杀树 exit 2、无 .tmp: FAIL (8.34s) |
| s6 | albumCandidates: convertibleExt replaced by not-pushable -> RAW listed as non-jpg, candidates case red | `P8-B` | RED OK | albumCandidates：成片 jpg 未进相册的按事件夹分组、同名异容标记、非 jpg 单列、RAW 不列:             FAIL |
| s7 | vault/new: unpushable no longer removed from new -> n.png rendered as assignable NEW, vault/new case red | `P4-2` | RED OK | P4-2 /api/vault/new：NEW 名字配上主库 catalog 的 sha/size；无 vault 配置 → 404: FAIL (0.13s) |
| s8 | runClaude: is_error:true not mapped to 502 -> iserror fixture answers 200, classify case red | `P8-D` | RED OK | POST /api/suggest classify：只读级放行；预置回答规范化（未请求的名字丢弃、坐标规范）；400 五种；413；502 垃圾/退出非零/is_error；409 缺 claude/超时/并发；.pm 零写入:              FAIL (0.61s) |
| s9 | DESIGN I2: pm dedupe removed from the quarantine producer list -> caseQuarantineCensus red | `P7-J` | RED OK | 隔离产地清点（步 9 C10）：引用 OpQuarantine 的模块集合固定；DESIGN §2 I2 逐一点名每个产地:                                          FAIL (0.08s) |

final build rc=0; P8-C2 rc=0 (All 4 tests passed (14.81s)); P8-B rc=0 (All 6 tests passed (0.72s)); P4-2 rc=0 (All 4 tests passed (0.38s)); P8-D rc=0 (All 8 tests passed (9.86s)); P7-J rc=0 (All 28 tests passed (1.95s))

s3 未判红的原因：终名是 symlink 时 `resolveUnder` 的完整路径预筛已先拒绝（同一句「链接」消息），`probeName` 的拒绝分支是第二道（Win.hs 的设计：`resolveUnder` 只是预筛，句柄层才是边界）；叶级链接构造不出只过预筛不过 probe 的形态，登记为无独立判红形态的冗余防线，不删。

修复批树：417 测试、GHC 警告 0（clang `<built-in>` 噪声同前）；`node --check` ×3 绿；pm-test.exe `148735e4875c953ab1496db6e352481a42c57bffd374caf3e59c1589ef2433c5`、pm.exe（`.stack-work/install/…/bin`）`6112149481ef861feb141acd305c0a6a0dd7919d312fc420d27ba0b204ffa6ad`。

## 门禁一轮（Opus，2026-08-28，对象 a1ba887）→ NO-GO → 修复批

报告存档：scratchpad `gate_opus_a1ba887.md`。verdict **NO-GO**：2 major（F1 / F2）+ 6 minor（F3–F8）+ 一条「与 Exec 同规格」措辞纠正；13 条声称试图否证而未能（hardlink 预置 / 叶级链接逐段拒 / 库外字节不进计划 / 根锁区段 / s3 解释成立 / convertibleExt 三分覆盖 / 七处产地 / mask 解析 / planPost try 范围 / scanDerived 基目录 / sameDerived case-fold / applyPlan done 位 / 计数与版本一致）。

| # | 级别 | 发现 | 上游处置 |
|---|---|---|---|
| F1 | major | C8 只堵了 `new`：`.png` 能经 `pm vault hold` / 页面「暂不同步」进名单 → `vrHeld` → `/api/vault/new` 的 `held` → 仍渲染成可指派卡 → push-plan 整批 400 | 上游：`holdRequest` 拒收非 jpg（「UNPUSHABLE 无需暂不同步 → 归档页转换」）；存量旧名单条目由 `splitHeld` 归 stale 并说明；用例 `caseServeHold` 补 hold `n.png` 400、旧名单条目 heldStale 1 / held 0、按说明 unhold 后继续 |
| F2 | major | `runTool` 的 stdin 写在 `race` 之外——提示超过 4 KiB 管道缓冲、子进程先灌 stdout 时串行写与子进程互等，超时救不了，`seSuggestLock` 永远握住 | 喂 stdin 移进计时窗口三路并发。**第二层**（突变 g3 首跑暴露）：Windows 满管道写是不可中断的 FFI 调用，「到点先 cancel 喂线程」会等到子进程读走或退出——子进程既不读也不退就永久挂死（g3 首版让 P8-D 组挂了 900 s，用例外层 `timeout` 也救不回）。定稿：`withAsync body` + 主线程 `timeout (waitCatch a)`（STM 可中断）→ 到点**先 `taskkill /T /F`**（管道即断、写端立刻醒来）→ `withAsync` 收尾再 cancel。用例 `caseRunToolFlood`：桩灌 24 KiB 不读 stdin、睡 9 s；断言 `ToolTimeout 1`、耗时 < 4 s（区分「杀树解开」与「桩自己退出」）、`tasklist` 无 PING 孙进程 |
| F3 | minor | archive.js 把索引 warnings 写进结果横幅，`planCall` 收尾的 `loadArchive` 会抹掉刚出的计划 id（同 vault.js 记着的坑） | 专用行 `#archive-warnings` |
| F4 | minor | AI 建议在途时用户改过的三格，响应回来把 `source` 从 user 改回 ai-* | `touched` 集合：在途改过的卡跳过覆盖 |
| F5 | minor | 回显记录类目后页面分不清「上次确认的」与「本次选的」 | `.prefilled` 虚线样式 + 进度行「其中沿用记录 N」；点任一按钮即转为本次选择 |
| F6 | minor | 用例标题写「杀树」但断言观测不到；⑤ 超时打在预检（根锁外） | 标题据实；桩对 `-c` 立即答 0、对派生调用睡 3 s → 超时打在根锁内的派生调用，`.tmp` 清理有意义 |
| F7 | minor | 整批派生期间持 root 锁的阻塞窗口未登记 | DESIGN-P8 §20.1 / §25 补记（fail-closed 报忙，不是死锁） |
| F8 | minor | §22.4 闸门清点漏 `is_error` | 补 |
| 措辞 | — | 「与 Exec 的 tmp 落位同规格」不成立：Convert 要把**名字**交给 python，pm 关掉独占句柄到 python 按名打开之间有窗口 | Convert.hs 头注 + §20.1 / §25 改为「同一组原语，差一处」并登记为残余（同 DESIGN §14 Exec 的 TOCTOU 残余） |

判别突变（`mutate_gate1.py`，同前纪律；驱动层对挂死的 pm-test 做 `taskkill` 并记 RED(hang)）：

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| g1 | holdRequest: UNPUSHABLE refusal disabled -> POST hold n.png answers 200, hold case red | `P4-7` | RED OK | P4-7 POST /api/vault/hold：只读 403；标记后 new 移出、held 列出；同名同时标与撤 400；撤销恢复；被 hold 的不能 push: FAIL |
| g2 | splitHeld: pushableExt filter dropped -> legacy n.png hold stays HELD instead of stale, hold case red | `P4-7` | RED OK | P4-7 POST /api/vault/hold：只读 403；标记后 new 移出、held 列出；同名同时标与撤 400；撤销恢复；被 hold 的不能 push: FAIL (0.50s) |
| g3 | runTool: kill-tree deferred until the feeding thread ends -> stuck pipe write, flood case red | `P8-D` | RED OK | runTool（门禁 F2）：子进程灌满 stdout 且不读 stdin，喂入 100 KiB 提示 → 超时仍生效（ToolTimeout 1），不因管道互等挂死:                                             FAIL (9.39s) |

final build rc=0; P4-7 rc=0 (All 9 tests passed (3.27s)); P8-D rc=0 (All 9 tests passed (13.32s)); P8-C2 rc=0 (All 4 tests passed (17.24s))

插曲（如实）：跑 g3 首版期间机器强制重启，驱动脚本停在「已改源、未还原」——`Subprocess.hs` 留在突变态、`.stack-work` 产物是突变体的构建、`%TEMP%` 留 26 个 `pm-*` 沙盒（含此前几天被中断的用例）。处置：按预期版本手工还原并 grep 核对（`VaultCmd.hs` / `VaultHold.hs` 由脚本 `finally` 已还原）、从还原源重建、临时沙盒全部删除（0 个）、杀掉挂着的 `pm-test.exe` + `flood.cmd` 树；首跑的 g1/g2「判红」因基线 P4-7 用例本身红（我的断言把旧名单条目数进 `held`）而作废，用例改为按说明先 unhold 后重跑全部三对。

修复批树：418 测试、GHC 警告 0；`node --check` ×3 绿；pm-test.exe `9df1b87e036cda9f473e68b993a5037bccb43aef92bdd8382d378270fbe74751`、pm.exe（`.stack-work/install/…/bin`）`e53486c8a8cb5edeb6fa1af98d1b416cf53f1088982c89e31cfca880632dc174`。

## 门禁二轮（Opus，2026-08-28，对象 dba6a65）→ GO → 四条 minor 收口

报告存档：scratchpad `gate_opus_dba6a65.md`。verdict **GO**：F1–F8 与措辞项全部 CLOSED（逐行引用核过：`VaultCmd.hs:133-137` / `VaultHold.hs:176,182-183` / `Subprocess.hs:60-73` / `index.html:87` + `archive.js:74` / `vault.js:139,195,186,85` / `vault.js:118,70,130,126-127` + `style.css:92` / `ConvertTests.hs:41,259` + `slow-python.cmd:7` / DESIGN-P8 §20.1 §25 §22.4 / `Convert.hs:16-24`）；REVIEW-LOG 登记的两个产物哈希实测逐字节吻合；文档计数 418 三方一致；试图否证 F2 的五个角度（`waitCatch` 可中断、`getPid` 到超时分支必 Just、`withCreateProcess` 收尾不挂、`-threaded` 前提、flood 桩能分开「先杀」与「先收」）都未能推翻。新发现四条全 minor、无阻断；按「不留开口」全部上游收口而不是只登记：

| # | 级别 | 发现 | 上游处置 |
|---|---|---|---|
| N1 | minor（用例假红） | `caseRunToolFlood` 的 `tasklist /FI "IMAGENAME eq PING.EXE"` 是全机查询——机器上任何无关 `ping.exe` 都让这条 major 守卫假红 | 跑前快照 PING 的 PID 集合，跑后只断言「无新增」；反向核验：先起一个无关 `ping -n 30`，用例照样 OK 且那个 ping 仍存活（job 只杀自己那棵树） |
| N2 | minor（来源落盘错） | `touched` 只覆盖「AI 在途时改」：用户**先**填三格**再**点 AI，值不被覆盖但 `source` 被改成 `ai-*`，随 `POST /api/vault/notes` 落盘——用户写的地点被标成 AI 的。与 F4 同一根因 | 单一谓词 `userOwned`（本页亲手改过 `touched`，或盘上记录本就是 `user` 来源且三格有内容）：这类卡**不进 AI 请求**（不花钱问已写好的）、响应里也不碰；`touched` 改为整页生命周期（`loadVault` 清），不再在每次点 AI 时清空 |
| N3 | minor（残余挂死口） | `killTree` 吞掉 `taskkill` 的一切失败；taskkill 找不到 / 被拒 / 直接子进程已死只剩继承了管道的孙进程——都杀不到，杀不到就是 F2 那种不可中断的写永久挂死，`seSuggestLock` 永远握住 | 子进程挂 Windows **job 对象**（`use_process_jobs = True`，process-1.6.26.1 源码核过：`terminateProcess` → `TerminateJobObject` 整树、`KILL_ON_JOB_CLOSE`、无 breakaway），到点 `terminateProcess ph`，不再依赖外部 `taskkill`。代价登记 DESIGN-P8 §25：`waitForProcess` 等整个 job——外部工具若留下不持管道的守护子进程，会等到超时再整树杀（fail-closed 报超时；首次真实 `claude -p` 跑时核实） |
| N4 | minor（CLI 措辞矛盾） | `pm vault status` 对相册里的 .png 同时打印「+ NEW → pm vault push」与「✋ UNPUSHABLE」，而 `checkAssignments` 必回 UNPUSHABLE；F1 只是多了一条到达路径（旧名单 .png 退出 `vrHeld` 回到 `newActive`） | 新谓词 `Vault.newAssignable = filter pushableExt . newActive`：CLI「→ push」行与 GUI `/api/vault/new` 的 `new` 都只用它（ServeVault 原地的 `notElem unpushableNames` 过滤删除，两处一谓词）；`newActive` 与退出码语义不动（.png 在六态里仍是 NEW、仍算差异——legacy 对 .png 同 jpg）；✋ 行指到 `pm convert` / 归档页「非 jpg 转换」。用例 F069 补 `newActive` / `newAssignable` / `hasDiffR` 三断言 |

判别突变（`mutate_gate2.py`，同前纪律）：

| id | 突变 | -p | 判定 | 突变输出 |
|---|---|---|---|---|
| h1 | newAssignable = newActive (UNPUSHABLE .png counted as assignable) -> F069 case red | `F069` | RED OK | 工作流 F069 unpushable 与 push 门同谓词：.png 入列、.jpg/.jpeg 不入（pushableExt 唯一定义）；N4 newAssignable 扣掉它: FAIL (0.14s) |
| h2 | use_process_jobs = False (kill only the direct child) -> grandchild keeps the pipe, flood case red | `P8-D` | RED OK | runTool（门禁 F2）：子进程灌满 stdout 且不读 stdin，喂入 100 KiB 提示 → 超时仍生效（ToolTimeout 1），不因管道互等挂死:                                             FAIL (10.12s) |
| h3 | /api/vault/new built from newActive (UNPUSHABLE .png back in new) -> P4-2 case red | `P4-2` | RED OK | P4-2 /api/vault/new：NEW 名字配上主库 catalog 的 sha/size；无 vault 配置 → 404: FAIL (0.13s) |

final build rc=0; F069 rc=0 (All 1 tests passed (0.14s)); P8-D rc=0 (All 9 tests passed (10.57s)); P4-2 rc=0 (All 4 tests passed (0.45s))

N1 无对应源突变（是用例自身的健壮性），以反向核验代替；N2 是 GUI JS，无单元夹具，`node --check` 绿 + 逐行读核。

收口树：418 测试、GHC 警告 0；`node --check` 绿；pm-test.exe `d6eb336a1b302c3964d7e2641c2122747bd9a3fc7f4f395fff5bcfbd29b1511d`、pm.exe（`.stack-work/install/…/bin`）`a27de4fba3cb5ac373a38b70b0b5aea1f79e3eacc71a3ae0e6e9fee662070664`。

## CI 抓包分支（2026-08-28，`ci-probe` → `.github/workflows/build.yml`）

按 §26「抓包分支先验」先推分支不并主干。首跑 run 33150346218（windows-latest = Windows Server 2025 / 26100，runner 2.336.0；GHC + 全部依赖冷装 + 套件共 13 min）：**409/418**，9 红同一类——`TestUtil.withDenyAll` / `withDenyList` 的 icacls 拒绝对 pm 的探针不生效：RD 拒的目录照样列得出（F054 / F039 / F040 / listSource 半扫）、(F) 拒的文件照样 stat（freshnessSweep 两例）与 unlink（C102，连清理 icacls 都找不到文件），只有 GENERIC_READ 打开被拒（scan 探针例的错误落在 withBinaryFile 而非探针）。symlink / hardlink / junction 夹具（HandleGuardTests 等）在提权 runner 上全部可用。

取证（临时 `probe.yml`，已删；探针提交顺带触发的 4 次 build 跑已取消，不计门禁）：

| 探针 | 结果 |
|---|---|
| `whoami /priv` / `whoami /groups` | `runneradmin`，BUILTIN\Administrators，High 完整性；SeBackupPrivilege / SeRestorePrivilege **Disabled**（在令牌里但未启用）；SeCreateSymbolicLinkPrivilege Disabled（mklink 自己启用） |
| 同样的 icacls 拒绝 + Win32 错误码（P/Invoke，三种 temp 根：`%TEMP%` 短名、`RUNNER_TEMP`、工作区）| 三处一致：deny(F) 文件 `GetFileAttributesW`=0、`CreateFileW(0, BACKUP_SEMANTICS)`=5、`CreateFileW(GENERIC_READ)`=5；deny(RD) 目录 `FindFirstFileW`=5、`CreateFileW(0, BACKUP)`=0；即**原语与本地一致** |
| 同一 runner 上 `cmd` 里 `del` deny(F) 文件 | 成功（父目录 FILE_DELETE_CHILD 兜底）——pm 走 `pm_open_for_dispose`（要 DELETE 访问）不走这条，故本地 C102 成立 |

原语一致而套件不一致 → 差异在**测试进程的令牌**：pwsh 探针由 runner 直接拉起（特权 Disabled），`stack test` 由 Git Bash（MSYS2）拉起——MSYS2 在提权令牌下启动时把 SeBackupPrivilege / SeRestorePrivilege **启用**，子进程继承「已启用」状态；带 backup intent 的探针（GetFileAttributesEx / FindFirstFile / `FILE_FLAG_BACKUP_SEMANTICS` 的 CreateFile / DeleteFile——恰是 pm 的探针）全部绕过 DACL，而不带该标志的 GENERIC_READ 仍被拒——与 9 红 / 409 绿的分布逐条吻合。本地是普通桌面会话，令牌里根本没有这两项，所以全绿。

处置（161ef2b，上游在测试壳而不是改用例断言）：cbits `pm_disable_backup_privileges`（`OpenProcessToken` + `AdjustTokenPrivileges` 把两项置 0），`Spec.hs` 启动时调用（`TestUtil.disableBackupPrivileges`），与启动它的 shell 无关；令牌里没有这两项时是空操作（`ERROR_NOT_ALL_ASSIGNED`，视为成功）。本地 418/418、警告 0；重跑 run 33152288443：stack test 14 min，**418/418**，其后 pm.exe 版本闸 / sidecar / tauri build（`@tauri-apps/cli@2.11.4`，`--remap-path-prefix` 工作区与用户目录）/ leakscan / zip + NSIS + sha256 / artifact 全绿。

登记：① pm 本身若在启用了备份特权的令牌里跑，探针会绕过 DACL——读到更多而不是更少，不处理；② 目录 RD 拒在 `cmd dir` 里显示为 "File Not Found"（cmd 自己的文案），不是错误码——取证时差点被它带偏，记一笔。

## 用户复核 + 首次真实数据跑（2026-08-28，对象：CI run 33152288443 的产物，pm 0.6.1）

用户装 CI 产物复核七页，两项发现，「别的没问题」：① 侧栏左下脚注文字溢出；② 同一行按钮尺寸不齐。处置 58f136d（只改 `gui/ui/style.css`）：`.side` 钉 `min-width:0`、脚注 `overflow-wrap:anywhere`（「已连接 127.0.0.1:端口」与主库路径都是无断行点的长 token，字体回退 / 更长路径会顶出 200px 定宽列）；`.btn` `white-space:nowrap` + `.actions` `flex-shrink:0 / flex-wrap`、`.page-head` 可整体换行——页头文案长时 `.actions` 被挤窄、两个按钮各自折行成一高一矮。tour 复核截图：分类推送页头两按钮等高、脚注不溢出。

首次真实数据跑——用户裁定「你模仿我直接操作，全程监控」。纪律：先只读盘点（真实库零写入），再 AskUserQuestion 摆清单，裁定后才动。盘点：暂存区 To-Be-Sync'd 只剩用户 WIP「待修改」21 件 + 4 个空的 Raw/Processed 事件夹壳 → `pm import` 无对象；唯一非 jpg `成片\26-06-R66\_DSC9621.developed.tif`（344 MB，07-13）旁已有用户 08-14 新导出的同名 jpg（72.7 MB）→ `pm convert` 会因同名拒收；成片 → 相册候选 104 张（19 夹），其中 2 张「相册有同名不同内容」（`25-11-Alaska\_DSC9274.jpg`、`26-04-Providence\_DSC9558.JPG`——sha 核过：相册 / vault 里那两张与 `24-10&11-Providence` / `24-12-New York & East Coast` 的成片逐字节一致，I7 成立；候选这两张是相机计数回绕的**另外两张照片**）；vault 15 张 NEW 全是用户 08-24 的「暂不同步」。用户裁定：不动相册；tif 只留新 jpg、旧 tif 是以前的编辑；同名问题处理掉；vault 保持暂不同步。

执行（全部是同卷 `mv`，零删除、零字节改动；备份盘 E: 未挂载，所以旧 tif 不删只挪）：

| 操作 | 前 sha（12） | 后 sha（12） |
|---|---|---|
| `成片\25-11-Alaska\_DSC9274.jpg` → `_DSC9274_Alaska.jpg` | 7ffc9f3eb926 | 7ffc9f3eb926 |
| `成片\26-04-Providence\_DSC9558.JPG` → `_DSC9558_Providence.JPG` | e044934347c5 | e044934347c5 |
| `成片\26-06-R66\_DSC9621.developed.tif` → `To-Be-Sync'd\待修改\`（退役旧编辑） | 4bba016c224a | 4bba016c224a |

之后：`pm scan` 4633 文件（复用 4508 + 新 hash 125，20.8 s）→ `pm status` 成片 197 / 5.1 GiB、暂存 22 / 1.1 GiB、✓ 索引与磁盘一致；`pm album candidates` 104 张 · ⚠ 同名 0 · 非 jpg 0；`pm doctor` 只有 VERIFY-AGE 一行、无 Bad；`pm vault status` OK 79 · NEW 15（全 HELD）；GUI 归档页第三卡显示「成片 / 相册下没有非 jpg 照片」。

未发生、如实登记：`pm import`（无对象）、`pm convert`（无对象）、首次真实 `claude -p`（用户保持暂不同步，未点 AI 建议）→ §25「`waitForProcess` 等整个 job」的残余仍未在真实 claude 上核实；首次建 vault root 未发生（无推送）。pm 本身对本轮的贡献是盘点与复核（scan / status / candidates / doctor / vault status），三次移动是用户裁定的手工整理，不在 pm 写域。

## 1.0.0 发布（2026-08-28，tag `v1.0.0` = a99535e，release run 33171920358）

用户 AskUserQuestion 批准「main 绿了就打 tag 发 release」。main 上 1.0.0 收官批 run 全绿后 `git tag -a v1.0.0 a99535e` + push tag → build job 重跑同一条链 → release job 建 https://github.com/skymanbp/PhotoManager/releases/tag/v1.0.0（说明 = `docs/release-notes/v1.0.0.md` + SHA-256 块，资产 zip + NSIS + `sha256.txt`）。回下载校验：`sha256sum -c sha256.txt` 全 OK、本地 `scripts/leakscan.py`（含 `PM_LEAK_PATTERNS` 本地附加模式）三件产物 clean、zip 里 `pm.exe --version` → `pm 1.0.0`。本机不再编发布二进制；`release061.sh` / `publish061.sh` 链退役为对照。

| 资产 | SHA-256 |
|---|---|
| `pm-1.0.0-windows-x64.zip` | `ae7f37f379680321f3429e3957034cf8b843da9bca177bd79b1d0412c8390507` |
| `pm-ui_1.0.0_x64-setup.exe` | `ca55d30e77b40c7b374f7668329015e0537d1fa7f486a4bf612c3446cfb7a60d` |

项目收官：P8 七项（相册通道 / AI 入口 / jpg 转换 / 档案侧技能 / 用户复核 / 全量文档 / CI 发布）全部落地；vault 15 张「暂不同步」与首次真实 `claude -p` 留给用户日常使用（§25「job 等待整树」残余据此仍未核实，已登记）。

## 1.1.0 增补批（2026-08-31，用户三批 AskUserQuestion 裁定；发布令：「pm收口。提交+推送并发布新release」）

范围：计划页完善（`Pm.Plan` 执行态折叠 `planExecs`/`planExecuted` + `pm plan list|rm|prune` + GUI 计划页标注/删除/清理）、候选忽略（`Pm.Album` 按内容 sha 的 `.pm/album-ignore.json` + `pm album ignore|unignore` + GUI 归档页）、备份范围 = 主库 − 暂存区（`Pm.Diff.backupDiff` 单点收窄）；serve 写端点九 → 十二。938 插入 / 84 删除，20 文件。

**第一方全量自审（发布前，按 2026-08-26 用户流程指令）**：产品代码 hunks 逐行读（app/Main、gui/ui 四件、Pm.Album/Diff/Plan/Serve/ServeAlbum），架构对照 DESIGN 声明（Plan.hs 持计划文件生命周期 + journal 折叠、Album.hs 持相册通道决定、Serve* 只做壳；行预算全部 ≤750，最大 app.js 688）。发现聚类：**0 critical / 0 major / 1 minor 登记不改码**——`POST /api/plan/delete` 把 `deletePlanAnyRoot` 的一切 Left（含「id 不符合生成格式」）都映射为 404，而 `GET /api/plan/<pid>` 对坏格式是 400；fail-closed 完好（坏 id 在 `deletePlan` 第一道守卫拒绝、零写入）、响应体带真实原因、GUI 只回传列表里的合法 id，状态码语义差异登记于此，留待下批与 `PlanIdReq` 解析层一并对齐。

**判别突变（每条单点重跑取 FAIL 文案，随后还原全绿）**：m1 忽略分区谓词翻转 → caseIgnoreFilterPure 红；m2 「必须是候选」错误闸削除 → caseIgnoreRequestPure 红；m3 `~r` 复位剔除改无操作 → caseFold 红；m4 `planExecuted` 去待裁决检查 → caseExecuted 红；m5 `deletePlan` id 格式守卫削除 → caseDeleteAndPrune 红；m6 prune 不过滤已执行 → 同用例红（m5 已还原后单独判）；m7 备份范围过滤削除 → PlannerTests 备份范围用例红。427/427 全绿（--fast 与 stack clean 后优化链各一遍），GHC 警告 0。

**真实库落地复核（只读 + 用户逐项裁定的写入）**：`pm plan list` 13 份计划执行态与 journal 诊断逐一一致（dedupe 正确标「已执行（余 8 项待裁决）」→ prune 保守跳过）；`pm album candidates` 104 张候选 · 已忽略 0；相册改名计划 `20260831-055559-c2107f`（手写 album-rename，dry → apply → DONE）后 `pm versions` 非设计内精确重复 1 → 0 组、doctor exit 0、`pm vault status` 零差异（15 HELD 除外）；vault 仓 7183f7e / portfolio 83260cb 连带推送。外部门禁轮未跑——用户直接下达发布令，第一方自审 + 突变 + 真实库复核为本批门禁。

## 1.1.0 后真实盘复核（2026-09-02，备份盘接入；用户令「帮我完成先前要我手动完成的任务 / 对照 PM 当前版本检查问题 / 进行一次真正的同步」）

**备份盘收口（用户授权移入回收站）**：接盘后 `pm backup` 只读比对：新增 3 (0.1 GiB) · 更新 0 · 一致 4608 · EXTRA 270。EXTRA 实时清单（To-Be-Sync'd 245 / 待修改 13 / Raw 8 / 成片 3 / 相册 1，共 23.7 GiB）先按 sha 核对「主库全 catalog 有同内容」（与 `Clean.hs` 的 `backupBySha` 同判据，0 例外；同日下午逐个重 hash 细分：246 项孪生在归档层、24 项只在待修改区，见下节）再逐个 `SendToRecycleBin`（E: 回收站上限 188 GiB、NukeOnDelete 0；首轮 54 项报 error 124「system call level is not correct」且 `Test-Path` 假阴性 → 改 `[System.IO.File]::Exists` 判定重试，全部成功），空目录树用 `[System.IO.Directory]::Delete`（harness 拦下 E: 路径上的 `Remove-Item`）；备份计划 `20260902-041220-d6ea21` 3 项 apply DONE；二次 `pm backup`：新增 0 · 更新 0 · 一致 4611 · EXTRA 0 ✓。主库侧：`To-Be-Sync'd` 下 7 个空事件夹删除（Raw / Processed 现为空，待修改 13 项原样）；scan 4633、versions 精确重复 0、vault status OK 79 / NEW 15（全 HELD）/ 其余 0、album candidates 103、doctor exit 0。

**F1 未来 mtime 永久 racy（class 级根修；HISTORY 同日行）**：主库与备份盘每次 scan 都报「待 hash 122 (14.0 GiB)」。取证：122 个全是 ARW（`Raw\2023\23-06-Cornwall-Raw` 120 / `23-07-Wales-Derbyshire-Scotland-Raw` 2），mtime 2027-07-06..08 与 07-14；EXIF DateTimeOriginal 同样是 2027——相机时钟错的是整个行程：Cornwall 整夹 123 张 EXIF 全在 2027-07-06..08，Wales 夹 EXIF 在 2021-01-01..08（另 2 张 2027-07-14），2025 夏的 `RAW-2025-Summer-Atlanta` / `25-08-Tennessee-Raw` / `25-08-PR-Raw` 三夹 EXIF 在 2019-01/02（多次复位）；`pm names` 的月份从成片事件还原、不取 EXIF，不受影响。根因 `Pm.Hash.statHitStable`：复用要求 `lastVerified − mtime > 2 s`，未来 mtime 永远不满足。修：判据加当前时刻参数，`hash 晚于 mtime 2 s 以上 ∨ mtime 晚于现在 2 s 以上`——危险的只是 mtime 起 2 s 的写入窗口，窗口尚未到来时不可能已有写入落在里面；到期后重 hash 一次即永久回稳；系统时钟回拨在原判据下同样打穿（回拨后改写的文件 mtime 早于 lastVerified），不在威胁模型内。三处调用同改（scan 复用 / vault `shaViaCache` / 夹具 `plantStaleCatalog`），`caseFutureMtimeReuse` 6 断言。突变 m1：去掉第二分支 → 该用例 `expected: True / but got: False` 红，还原全绿。真实盘复核（装根修二进制后）：`pm scan` 主库「4633 文件, 复用 4633, 待 hash 0 (0.0 GiB)」用时 1.58 s，`pm backup` 备份盘「4611 文件, 复用 4611, 待 hash 0」、对比 新增 0 · 更新 0 · 一致 4611 · EXTRA 0。裁定前提修正：用户原选「mtime 改回 EXIF 拍摄时间」，因 EXIF 本身在 2027 而不可执行 → 改 pm 侧根修、文件元数据一字节不动；EXIF 假时钟登记为已知数据问题，处置（不动 / exiftool 改写——会变 sha 并触发备份盘重拷）交用户裁定。

**deep doctor**：`pm doctor --deep` 全库 4633 条目重读重 hash（459.4 GiB，00:42–01:10 约 28 min，≈ 280 MB/s）：不符 0、读取失败/消失 0、无验证时间戳条目 0，exit 0。

**names 三条 NEEDS-DECISION 盘点（只读，方案上呈 AskUserQuestion）**：`pm names` = 合规 37 · 待改名 0 · 待裁决 3 · 无法识别 2（`2023\23-04&05-Egham-Raw`、`2024\24-10&11-Providence-Raw` 的 `&` 月份区间，不入计划）。月份还原走成片同年同地点事件（`Names.hs:138-145`），2025 成片只有 `25-11-Providence` 与 `25-01-Atlanta`：① `RAW-2025-Summer-Providence`（10 ARW，_DSC9035–9044，EXIF 2025-08-11）与 ② `RAW-2025-Autumn-Providence`（29 文件，_DSC9131–9150，EXIF 2025-10-07/26；成片 `25-11-Providence\_DSC9138.jpg` 出自此批）同映到 `25-11-Providence-Raw` → 「同批多个事件夹规范化到同一目标」；③ `RAW-2025-Summer-Atlanta`（20 ARW，DSC08984–_DSC9034，EXIF 2019-01 假时钟；与 `25-08-Tennessee-Raw`（_DSC9004–9033）编号交错、无同名；成片 `25-08-Tennessee\_DSC9013_2.JPG` 的 raw 在此夹）映到已存在的 `25-01-Atlanta-Raw` → 「目标路径已在盘上存在」。

**操作手册**：`PhotoManager-操作手册.pdf`（仓根；`.gitignore` 加 `/*.pdf`）——两轮 Workflow（6 读者提取 382 条事实 → 6 章起草 → 逐章反驳核对落实 65 条 → 完整性批评 29 条 → 逐章修订 + 反驳核对 + 新增「术语与约定」章）+ 第七章「当前库状态与已知待办」由第一方按本节数字撰写；章节 JSON → HTML（本地 mermaid 11.4.1）→ Edge headless 打印，逐页复读验收。

428/428，警告 0（本批 pm 代码改动只有 F1）。

**用户裁定（AskUserQuestion，2026-09-02）与执行**：① 根修发布为 **1.1.1**（版本串五处 bump、`release-notes/v1.1.1.md`、README 路线图行、HISTORY 行；门禁链同 1.1.0：sancheck / rangescan → push main → CI 绿 → tag → release 资产回下载 `sha256sum -c` + leakscan → 本机 NSIS 静默装 + PATH 二进制 cmp）；② 三处 Raw 事件夹按裁定改名——`RAW-2025-Summer-Providence → 25-08-Providence-Raw`、`RAW-2025-Autumn-Providence → 25-11-Providence-Raw`（跟随成片夹命名）、`RAW-2025-Summer-Atlanta → 25-08-Atlanta-Raw`，主库与备份盘两侧同步 mv（同卷改名，sha 不变；先预检源在、目标不在）：`pm scan` 4633 文件（复用 4574 + 挪位 59 重 hash 6.1 GiB 一次）、`pm names` 合规 40 · 待改名 0 · 待裁决 0 · 无法识别 2（`&` 双月夹保持原名）、`pm backup` 新增 0 · 更新 0 · 一致 4611 · EXTRA 0、`pm status` ✓ 索引与磁盘一致；③ EXIF 假时钟不动，登记为已知（手册第七章待办表）。

**1.1.1 发布实录（2026-09-02）**：提交 4183a89（15 文件改 + release-notes 新增；sancheck 128 文件 0 命中、rangescan 1 提交 0 命中）→ push main → run 33635735523 build 绿 → `git tag -a v1.1.1 4183a89` → run 33636786337 build + release 绿 → 回下载 `sha256sum -c` 两资产 OK（zip `50b9d049…6bf9`、setup `cf9f9a51…814b`）→ `scripts/leakscan.py` 三产物 12 模式 0 命中 → zip 内 `pm.exe --version` = pm 1.1.1 → PATH 上 pm.exe 用 zip 那份覆盖后 `cmp` 相同 → NSIS `/S /D=%LOCALAPPDATA%\pm-ui` 静默装 exit 0、注册表 DisplayVersion 1.1.1、安装目录 pm-ui.exe 与 zip 恰差 3 字节（bundle-type 标记，同 1.0.0 实录）、sidecar pm.exe 与 zip sha 相同 → release 版 pm 在真实库 `pm scan` 复用 4633 · 待 hash 0、`pm names` 待裁决 0、`pm status` ✓。docs 补：DESIGN.md 锁作用域段的 racy 余量句补 1.1.1 新分支。操作手册 PDF 第七章按裁定结果重生成（69 页）。
**回收站 270 项的精确来源（2026-09-02 下午重算 sha 复核，修正上文「主库归档层都有同内容」的措辞）**：E: 回收站 270 项 / 23.69 GiB 逐个重 hash 对主库 catalog：246 项的孪生在主库归档层（To-Be-Sync'd\Raw 26-06-R66 137 · 26-04-Providence 53 · 26-08-Atlanta 19 · 26-07-Providence 7 与 Processed 8 = 早年备份范围含暂存区时拷去的暂存副本，事件随后 `pm import` 归档；Raw\2024\24-12-New York-Raw 的 7 个 ARW 主库已挪到 25-01-Atlanta-Raw；Alaska `_DSC9274/_DSC9275` 改名前副本、`_DSC9558` 改名前副本、`A7R06770.JPG`、退役 tif），**24 项的孪生只在主库待修改区**（E: 根级旧 `待修改` 13 + `To-Be-Sync'd\待修改` 11 含 pic temp 10 中的 staging-only 者，以及两处 `_DSC9621.developed.tif`）——`live_extra.py` 的屏障是「主库全 catalog 有同 sha」，不是「归档层」。0 项无孪生。用户须知：清空回收站后待修改区只剩 D: 一份（备份范围本就不含暂存区）。pic temp\ 10 张 = 2025-10-30..12-28 导出的 JPG，按 DateTimeOriginal 对上 25-11-Providence（1）/ 25-11-Alaska（6）/ 25-12-Colorado（3）的 ARW，成片无同图（同号 `_DSC9310`/`_DSC9523` 是 2024 年另两张）。

**下午四批裁定（AskUserQuestion，2026-09-02）与执行**：取证——两台机身 ILCE-7RM4（Cornwall 2027-07 手动设错；2025 夏复位到 2019-01-01）与 ILCE-7RM4A（Wales/Hunan 复位到 2021-01-01；Shanghai 2023-09 已正常），共用存储卡故文件编号跨机身连续：Wales 夹 7RM4 的 8979/8983（2027-07-14）夹在 7RM4A 8964..8991（复位钟第 2 天）之间 → 2027 钟 ≡ 2023-07-02，Cornwall 07-06..08 → 06-24..26；2025 夏 Atlanta 8984–9003（钟 01-01..05）→ Tennessee 9004–9033（01-21..23）→ Atlanta 9034（01-29）→ **Providence 9035–9044（7RM4A 真实 2025-08-11）** → PR 9046–9129（02-20..26），一条连续 57 天的钟不可能三趟都在 8 月。裁定：① PR 在 8 月（Atlanta 7/1–5 + 7/29、Tennessee 7/21–23、PR 8/20–26；夹改 `25-07-Atlanta-Raw` / `25-07-Tennessee-Raw` / 成片 `25-07-Tennessee`）；② 2023 三趟按夹名月份、日期按同一条钟对齐（Cornwall 6/24–26、Wales 7/1–8、Hunan 7/16–19），待修改里 3 张同内容 ARW 一并改；③ `&` 双月夹按每张拍摄月拆两夹；④ 三处时钟正确但夹名月份错的改名（`23-04-Portsmouth-Raw → 23-05`（7 张全 2023-05-07）、`23-11-Anhui-Raw + 成片 23-11-安徽 → 23-10`（87 张全 10/20–22）、`25-11-Providence-Raw + 成片 25-11-Providence → 25-10`（20 张全 2025-10）；上午裁定的 25-11 因新证据改判）。执行：`rename_events.py` D:/E: 各 122 步（拆夹按 EXIF 月，旁车随主文件，无 EXIF 两张 jpg 按同号 raw 兜底），拆夹 111 文件事后按 sha 逐一命中唯一新路径；`pm names` 合规 44 · 待改名 0 · 待裁决 0 · 无法识别 0。

**EXIF 假时钟改写（class 级，ExifTool 13.59 官方 zip，SHA-256 对 exiftool.org checksums 核过）**：三镜头 Workflow 对抗评审（33 findings → 36 代理 verify）确认并并入：IPTC:DateCreated/DigitalCreationDate 未改（改用裸 `-DateCreated` 同时命中 XMP-photoshop 与 IPTC）；字节数不变 + 保留 mtime 的文件（Luminar 导出 JPG 实测 8/8 等长；xmp 原地替换等长）会让 `statHitStable` 复用旧 sha → vault DRIFT 少报、backup 漏拷、album 候选失察——**所有改写文件必须换 mtime**（ARW → 改正后拍摄时间；其余 → now）；13 DNG + 2 PSD 也是假时钟须纳入；Y:M 位移在短月前滚（2019-01-31 +6:5 → 07-01）→ 改纯天数（−1473 / +911 / +2373）；IFD1:ModifyDate 需带组名单独改；4 条 HELD 决定记的 sha 会失效。被证伪的：EmbeddedXMPDigest（ARW 内嵌 XMP 只有 Rating、shift 不建新标签，md5 前后相同）、CJK 文件名（UTF-8 参数文件 + `-charset filename=utf8` 正确；直接 argv 才会被 CP936 打碎）、SonyDateTime 在明文 ShotInfo 块（仍决定不动）。副本验证：raw 像素条带 sha 相同、272 标签仅 9 项日期/偏移变化、JPG 像素 hash 相同、PSD/DNG 可写。真跑 `exif_fix.py --apply`：491 图（437 ARW · 13 DNG · 2 PSD · 39 JPG，55.27 GiB）491/491 updated、0 错误、0 stuck，27 xmp 正常，相册 14 张按预先算的内容 sha 找到孪生原地覆盖（大小写保持）；事后 `-time:all` 审计 532 文件只剩 Sony:SonyDateTime（476，故意不动）与 System:FileCreateDate（433，随后用 SetFileTime 只改创建时间对齐拍摄时间，mtime 零扰动）。`pm scan` 重 hash 532（55.8 GiB，78 s）；`postscan_check.py`：touched-changed 532 / untouched-same 4054 / 无 STALE。`pm vault status` DRIFT 10（预测 10）→ `pm vault push` 计划 20260902-151736-3b6e18 → `pm resolve --item 0..9 --keep src` → `pm apply` 20/20 DONE → DRIFT 0 · OK 79；4 张 HELD 失效 → `pm vault hold` 重标，名单 15，exit 0；vault 仓 10 modified 随后按用户裁定「上线」提交并推送（commit `3bb1f93`「photos: 10 张同名 jpg 换成改正 EXIF 拍摄日期后的新字节」，photos.json 未变；pm 不跑 git，见下文「清理与上线实录」）。`pm doctor` exit 0；`pm backup` 预览 新增 0 · 更新 527（= 488 图 + 25 xmp + 14 相册）· 一致 4084 · EXTRA 0。

**备份盘更新实录**：`pm apply 20260902-152404-5a64f8` 第一次在第 31 组（op #61 拷 DSC08791.ARW）抛 `hPutBuf: invalid argument`——系统日志 11:26:22 disk 51 ×6（\Device\Harddisk2 = WD My Passport 2626, USB）→ NTFS 140/50 延迟写失败 → 卷 HarddiskVolume9 重挂为 10 后 NTFS 98 报健康；同盘 8/26 12:10（×49）与当日 00:14（×6）亦掉过线。`pm doctor --backup`：C1 `#61 Intent 后无痕迹（写 tmp 前中断），重跑原计划即可`；已落盘 30 拷贝 + 31 隔离件按 journal spec 的 sha 逐一核对 0 损。裸跑续跑第二次在 217/527 组处再掉（11:41:29 disk 51 ×8），`pm doctor --backup` 脱离工具超时跑 9 min（对 217 拷贝 + 218 隔离件逐个重算 sha）只报 C1 `#435 Intent 后无痕迹`，无 C4。**用户随即要求「硬盘有时候就是会瞬断，必须做好保护措施避免浪费时间」** → 改为看门狗 `backup_watchdog.py`（pm 之外，只调公开命令）：按备份盘 journal 算断点、`pm apply <id> --only 组首-组尾` 每块 20 组续跑（裸跑续跑会对每个已 Done 目标重算 sha——`Exec.execCopy'` 目标存在即 hash 判同——掉一次白读几十 GB）、块间停 20 s、非零退出后轮询 root-id.json 等盘回来并按 `hPutBuf: invalid argument` 等签名判掉线再冷却续跑（上限 20 次，非掉线且零进展则停下报人）。第一轮跑到第 284 组停下报人：掉线恰落在「tmp rename 到位 → 写 Done」之间，盘上 `DSC09378.ARW` size/sha 与计划新值完全一致、tmp 空、journal 只有 Intent；重跑时隔离项看见原位是新文件报「victim 内容与计划时不符」，拷贝项被组闭包连带不执行——即 doctor 的 **C2「dst 完好、Done 丢失」**（`Doctor.hs` classifyPending'），只有 `--repair` 能补记。看门狗随即加「认洞」：对「有 Intent 无 Done」的 op 核盘（拷贝 dst size+sha 相符 → C2；victim 不在原位且本计划 trash 同 sha → Q-DONE-LOST），认定后跳过、收尾 `pm doctor --backup --repair` 一趟补记。第二轮从 608 起 13 次 apply、掉线 2 次（12:17:27 disk 51 ×7、12:26:36 ×3）自动续跑，1053 ops Done + 1 洞；`doctor --backup --repair` 3 s 完成 `修复: 补记 Done #569`。**发现：doctor 的 C4/Q 核验只取最后一次 `clean-shutdown` 之后的 journal 条目（`Doctor.hs` afterClean）**，分块每块干净收尾 → 该趟 doctor 对落盘字节零重读，不能当介质核验；早上那次 9 min 全量核验是因为前面是崩溃收尾。收尾 `pm backup` 重扫 242 文件到 200/242 时第四次掉线（12:32:11 disk 51 ×955，**读负载**下）→ 盘回来后单独重跑：`pm backup`（12:34–12:38，重扫 242 文件 27.0 GiB）新增 0 · 更新 0 · 一致 4611 · EXTRA 0 ✓ 备份盘已与主库一致。介质核验改用 `verify_backup_dst.py` 对 527 个拷贝目标按计划 sha 全文重读：第一趟 417/417 sha 相符、读到第 418 个时第五次掉线（12:47:26 disk 51 ×1084）→ 盘回来后 `--retry` 补读 110/110 相符，合计 527/527、55.44 GiB，sha_bad 0 · size_bad 0 · missing 0；本计划 trash 隔离件 527/527 在位。两脚本入仓 `scripts/backup_watchdog.py`（311 行）/ `scripts/verify_backup_dst.py`（86 行），README 两语备份节各加一行；pm 代码零改动。

**残余登记**：SonyDateTime 476 个仍旧值（无读者）；OffsetTime* 7RM4A 全库 +09:00（本次只保证本地时间月份）；Lightroom 云版库（%LOCALAPPDATA%\Adobe\Lightroom CC）含至少一张 Cornwall 衍生件，不重读磁盘 EXIF；外置备份盘 USB 当日掉线 8 次（00:14、11:26、11:41、12:06、12:17、12:26、12:32、12:47），读写负载下都会掉，写 ≈25 MB/s / 读 ≈100 MB/s（直插 AMD USB 3.2 根口、Windows 快速删除策略；换线/换口观察；SMART 计数需管理员权限未读）；`pm doctor --deep --backup` 未做。手册 PDF 按收口数字重生成（第七章重写，第 1/3/4 章过时句修正，meta 版本 1.1.1）。

**清理与上线实录（2026-09-02 傍晚，用户 AskUserQuestion 第五/六批裁定「留给我的全部清掉、该删删；待修改与 15 张不动；彻底收尾」）**：清前核前提——用户的前提是「主库与备份盘数据都全、清的都是多余重复件，不是就汇报」；逐项核对后上呈一条不符：备份盘 .pm/trash 529 项、vault .pm/trash 10 项与 E: 回收站里 10 项不是逐字节重复件，而是 EXIF 改前的旧版本（主库/备份盘现行字节都是改后新版本），用户裁定「一起清掉」。执行：E: 回收站 270 项 / 23.69 GiB 永久删除（用户 SID 桶清空；df 621→597 GB）；`pm trash --vault empty --yes` 10/10；`pm trash empty --yes`（主库）231/232——执行前逐条重验三副本屏障，唯一不过的 `20260826-163830-c947f5\To-Be-Sync'd\Processed\26-06-R66\_DSC9621.developed.tif` 被 pm HELD（备份范围不含待修改区，它没有第三副本；用户 WIP，不动），耗时 15 min（要 hash 备份盘上的孪生）；`pm trash --backup empty --yes` 529/529（16 s；df 597→541 GB）。上线：vault 仓 `git add -- landscape urban` → commit 3bb1f93 → push（skymanbp/photography-private main = 3bb1f93）；档案根仓 record-structure-version.md Change Log 加行、commit db7ca3b 不推。介质核验（用户裁定「查有没有跑过的记录，有就跳过；只回读那 588 个」）：备份盘 catalog lastVerified 直方图 = 08-25 3239 条 / 321 GiB（首次建索引读 hash）、08-26 588 条 / 56.4 GiB（只在写入端算过 sha）、09-02 784 条 / 80.9 GiB；`scripts/verify_backup_entries.py --verified-on 2026-08-26` 全文重读 588 条：587/588 一趟相符，`Raw\2025\25-06-USA-Raw\_DSC1066.psd`（877 MB）读到一半 EINVAL——系统日志 13:50 disk 51 ×902 + Ntfs 98，即盘瞬断后 2 s 内已重挂——`--retry` 1/1 相符；合计 588/588 sha 相符、55.5 GiB、669 s、85 MB/s。此前用初版脚本跑的两趟各被掉线打断（13:39、13:41，disk 51 ×843 / ×1099）：初版把「盘不在」误记成 missing、第三趟起手就因 catalog.json 读不到而崩——由此把三支盘上脚本的「等盘回来」收成一个内核 `scripts/backup_verify.py`（`Drive.ensure()`：root-id.json 可读 = 盘在，掉线等回、冷却 30 s、从被打断的那条重排队；任何读错先当瞬断重试 `--attempts` 次再记读错，`--max-drops` 兜底、`--retry` 续上次、`--max-mbps` 限速旋钮），`backup_watchdog.py` 改用同一 `Drive`（`--check-only` 复核 done=1054 remaining=0），两支核验脚本瘦成 38 / 29 行（cc-enforcer 重复代码探针触发的类级收口）。当日掉线合计 11 次（00:14、11:26、11:41、12:06、12:17、12:26、12:32、12:47、13:39、13:41、13:50）。文档漂移审计：Workflow 10 个读者代理（README ×2 / DESIGN / DESIGN-COMMANDS / HISTORY 尾 + REVIEW-LOG 末节 / 手册 8 章 / release notes + P8）→ 50 findings → 逐条对抗核实 18 条确认（32 驳回），全部改入：README 指标表「增量扫描 122 新 hash / 19.4 s」是 1.1.1 修前的重 hash（改为 1.58 s 现况 + 吞吐行）、README.zh「HELD 4 项留待 pm import」（08-26 已归档）、DESIGN §1「命名两套并存」（已统一 44/44）与 `23-11-Anhui` 例、DESIGN-COMMANDS §8 `RAW-2025-Summer-Providence` 例加日期锚、HISTORY 388「三处改名」实为五处且 PR 未改名、REVIEW-LOG 591 与手册第 1/2/3/7 章的「vault 未提交 / 回收站待清 / 只配了 vault / 掉线 7 次 / 从未整盘校验」等现况表述。本文件行尾统一为 LF（原 blob 混有 576 CRLF + 10 LF + 19 个孤立 CR，git 判为 -text，本次 diff 因此显示整文件）。终态：`pm status` ✓ 4633、`pm names` 44/0/0/0、`pm vault status` HELD 15 exit 0、`pm backup` 一致 4611 · EXTRA 0；本机 `pm --version` 1.1.1 不变、不发 release；手册 PDF v6（3.81 MB）；428/428。

**1.1.2 瞬断保护内建（2026-09-02 晚，用户裁定「防瞬断功能加入正式功能，防止备份/检查时硬盘断连；版本升到 1.1.2，发布新 release；更新全量文档、README 与本机安装版本」）**：**读源**——Workflow 7 个读者代理逐模块清点 I/O 触点（Exec 13 处 `try` 全是读口/rename，写口 copyFileHashed / 14 处 jAppend / appendManifest / createDirectoryIfMissing 全部裸奔逃顶；根锁与 journal 句柄整场持有、盘掉线两者都死；8 处 `doesFileExist` 在盘不在时 fail-open 答 False；Exec.hs 714/750 行）+ 第一方全读 Exec / ExecTypes / Journal / Config / Scan / Doctor / BackupCmd / Cli / Catalog / Win / Hash / Apply / Serve / Main。**设计（类级，不进内核）**：新模块 `Pm.Removable`——盘在 = `readRootInfo` 读得出（与 `scripts/backup_verify.py` 的 `Drive.ok` 同判据）；`judgeIO` 三分：错误类型属 {UserError, PermissionDenied, AlreadyExists, IllegalOperation, InappropriateType, UnsupportedOperation} → Deterministic 原样抛（测试注入的 `userError "inject-crash"`、`withDenyAll` 的 ACL 拒绝、pm 自己的 fail-closed 拒绝全在此族，行为与 1.1.1 逐字相同），否则看盘：不在 → Dropped（等 `dwWaitSecs`、冷却 30 s），在而 `NoSuchThing` → Deterministic，在而其它（InvalidArgument / ResourceVanished / OtherError…）→ Hiccup（短停 5 s）；同一步骤最多 5 次；`noDriveWait`（attempts 0）= 关闭。`withDriveRetry` 包 catalog 读写 / journal 读 / doctor 整场；`ensureDrive` 在布尔探针之前等盘；`requireDrive` 在长动作之后立刻抛（ResourceVanished 型，外层再判）；`scanRootRetry` 按 pass 续（有读错/未枚举 → 等盘或短停 → 拿这一遍的 catalog 当旧快照重扫）；`execPlanRetry` 会话级按组续跑：内核经新钩子 `ExecEnv.eeProgress`（execItems 一行）逐项报进度，异常后等盘 → 调用方给的 `heal`（Cli 传 `runDoctorWith dw root (DoctorOpts False True)`）补记 C2 / R2 / Q-DONE-LOST → 结算：组内每项都 DONE/同内容 SKIP 按进度计，否则组内每个待执行项 journal 末事件都是 Done 按 journal 计（结局由 JDone 的 sha / trashRel + Copy 的一次 dst stat 重建，形态与 execCopyLand / execRename' / execQuarantine' 的 Done 相同，`updateCatalog` 等价由用例钉住），其余组整组交给下一场 `execPlan`（内核既有崩溃恢复分支接手，Quarantine resume / dst 同内容 SKIP）。**依赖环**：Cli 要调 Doctor 而 Doctor→Convert→Cli——`scanDerived` / `DerivedState` / `derivedSub` 从 Convert 字节级搬进新模块 `Pm.Derived`（cc-enforcer 重复代码探针要求先剪源再写新模块），Convert 再导出，Doctor 改 import Derived。**接线**：`Pm.Cli.executePlanNowWith`（execPlanRetry + heal + 索引回写包 withDriveRetry）、`Pm.BackupCmd.runBackupDiff`（读索引 / scanRootRetry / 写索引 / apply 后读索引）、`app/Main` doctor → `runDoctorWith (driveWaitFor cfg putStrLn)`；`Pm.Doctor.runDoctorWith`（整场 withDriveRetry + 场末 requireDrive；`deepVerify` 逐条 ensureDrive + sha 读包 withDriveRetry；`runDoctor = runDoctorWith noDriveWait` 保住 30 余处测试调用）。**配置**：`cfgDriveWait :: Maybe Int`（`[backup] drive-wait`，缺省 1800，0 = 关）——TOML 解码 / `renderConfig` 的 `section` 加裸值清单（只设 drive-wait 也出 `[backup]` 表头）/ `ConfigPatch.cpDriveWait` 三态 + `checkPatch` 0..86400 / `applyPatch` / `pm config` 打印 / `ConfigSetOpts.csDriveWait` + `pm config set --drive-wait N | --no-drive-wait` / `GET /api/config` 的 `backup.driveWait` / GUI 设置页备份卡输入框（保存 / 恢复默认）；`pm init --force` 保留它（同备份登记）。Config.hs 触 750 行预算：字段 + 解码 + 渲染共 +3 行（749）。**测试（红绿配对）**：新 `RemovableTests` 8 例——盘的替身 = 把 `.pm/root-id.json` 挪走/挪回，插回由打印口触发（recover 一说「等它回来」就 50 ms 后插回，不靠计时器）；介质读错替身 = `eeCheckpoint` 抛 InvalidArgument 型 IOException：① 确定性异常（userError / PermissionDenied）调用 1 次、零打印；② 盘在 EINVAL → 重试成功、一条「盘仍在」；③ 盘不在 → 等回来后成功，`dwWaitSecs = 0` 无人插回 → 抛原异常且只调 1 次；④ 对偶 `noDriveWait` 逃顶；⑤ 三项 Copy、第二项 CpCopyAfterMove 拔盘 + 抛 → 结果三项全 DONE、进度 {0:1, 2:1}（第 1 项由 doctor 补的 Done 结算、没有再执行）、该 oid 恰一条 Done、doctor 无 C1/C2/C5、三文件内容对、`updateCatalog` 三条 sha = 计划 sha、日志含「从中断处继续」「盘回来了」；⑥ supersede 组内 Copy CpCopyAfterTmp 拔盘 → 整组重跑，隔离项进度 2（resume 分支）、Copy 1、victim 现为新字节、trash 里恰一份旧字节、doctor 无 C1/C2/C5/Q 行；⑦ scanRootRetry 起手盘不在 → 等回来扫完零读错 hashed 3；ACL 拒读一文件（盘在）→ 有界 3 次「盘仍在」后如实 1 处读错、hashed 0 / reused 2（文件 mtime 推到一小时前避开 racy 窗口——首版断言撞上 `statHitStable` 的设计内 racy 判定，改夹具不改判据）；⑧ `runDoctorWith --deep` 起手盘不在 → 场末 requireDrive 作废重跑，结果零 Warn + DEEP-DONE，对偶 `runDoctor` 照旧 DEEP-SKIPPED Bad exit 1。配置三处用例（checkPatch 负值拒 / 0 与 null 合法；round-trip 含 `drive-wait = 60` 与只设 drive-wait 的 `[backup]` 表头；`/api/config` 带外改动后 `backup.driveWait` 90）。测试夹具 `Config` 位置构造 24 处补 `(Just 0)`（普查 + 清单脚本；两处 `main'` / `(Just vault)` 形态由第二轮 9 参数正则普查补齐）。首跑 435/436：仅 ⑦ 的复用断言（上述 racy），改后单例过；全量 436/436、GHC 警告 0（Convert 拆出后 3 条冗余 import 已清）。**残余登记**：两场之间无锁窗口只对同 root 的另一个 pm 可见（常规 I10 竞争）；`savePlan` 写计划文件与 `refreshBackupCache` 未包（毫秒级窗口，掉线即报错重跑 `pm backup`）；`pm scan`（主库）不走 scanRootRetry（主库是内置 NVMe，掉线属另一类故障）；Hiccup 对主库 root 同样生效但只多花 ≤ 25 s；真实盘掉线未在本轮复现（当晚盘未再掉），保护路径的证据是上述 8 例与 1.1.1 实录的异常形态对照。

**1.1.2 发布实录（2026-09-02 晚）**：单提交 89a1152（代码 + 版本串四处 + release-notes + 文档）→ sancheck 132 文件 0 命中 → rangescan 1 提交 0 命中 → 快进 → push main → main run 33673507248 绿（build 8m22s，缓存热）→ `git tag -a v1.1.2 89a1152` + push → release run 33674438301 绿（build 7m28s + release job 9 s）→ 三资产 `pm-1.1.2-windows-x64.zip`（12 394 245 B，`17e9922a…`）/ `pm-ui_1.1.2_x64-setup.exe`（8 380 523 B，`5e2eb3ae…`）/ `sha256.txt` → 回下载 `sha256sum -c` 两项 OK → 仓根 `scripts/leakscan.py` 12 模式 0 命中 → zip 内 `pm.exe --version` = pm 1.1.2。装机：PATH `%APPDATA%\local\bin` 的 pm.exe 与 pm-ui.exe 用 zip 那份覆盖后 `cmp` 逐字节相同、`pm --version` 1.1.2；NSIS 静默装 `/S /D=%LOCALAPPDATA%\pm-ui` 退出码 0、DisplayVersion 1.1.2、安装目录 pm.exe sha == zip（`e8b00b19…`）、pm-ui.exe 与 zip 恰差 3 字节（bundle-type 标记，同 1.0.0 / 1.1.1）。真实库冒烟（装机后的 1.1.2）：`pm config` 打印「掉线等待（默认 1800 s）」；`pm backup` 对真实备份盘走 `scanRootRetry` 路径 9 s——扫描 4611 复用 4611 待 hash 0，新增 0 · 更新 0 · 一致 4611 · EXTRA 0，exit 0（盘未掉线，走的是零重试直路）。手册 PDF v7（3 811 130 B，版本行 pm 1.1.2）。

**1.1.3 计划页失效草稿 + 版式（2026-09-02 深夜，用户反馈「1. 为什么还有那些好多条未执行计划？2. 已执行计划在 GUI 页面上看着很乱，各种溢出文字重叠。3. 修复问题，更新版本。全量更新文档、readme、本机安装版本，然后发布新 release」）**：**Q1 实测**——`pm plan list` 7 份：4 份 import 草稿（2026-08-23，各 220 项；逐项探源 220/220 相机卡文件已清）+ 2 份 names 草稿（08-24，6 项；旧夹名已改）+ 1 份 dedupe 已执行（余 8 项待裁决）。六份草稿都是同一批事后来用新计划执行过后留下的（import 走了 --apply 的新 id、names 走了 0c238a）；1.1.0 的 prune 判据「草稿不动」是刻意的保守，代价是永远执行不成的草稿也永远留着。用户中途自己点了「清理已执行」——一份未删（dedupe 有待裁决残余、草稿不算已执行），按设计。**根因 / 类级修**——「再也执行不成」有客观判据：每一条待办的源（拷贝源 / 改名旧路径 / 隔离 victim，`Pm.Op.opSource`）都不在盘上而源所在的卷还在 → `Pm.Plan.planStale` 一个谓词，`pm plan list` / `prune`、serve `GET /api/plans`（新字段 `stale` + `state`）、GUI 四处同源；卷不在（相机卡拔了）不算，探测抛出按「源在」计，journal 有告警的根不判、prune 整根不删（fail-closed：失效判据依赖「无 Done」，折叠不全时不可信——这比 1.1.0「告警只是附注仍清已执行」更严，DESIGN-COMMANDS 新节登记）。`opSource` 初放在 Pm.Plan，DocDrift 隔离产地清点（引用 OpQuarantine 的模块集合固定）判红——它是纯读者，挪进 Pm.Op 与 `opPathsOk` / `describeOp` 同处，名单不扩；旧用例 caseDeleteAndPrune 的「草稿」没有真实源文件、按新判据正是失效草稿而被清——夹具补上源文件（活草稿），用例名改「活草稿不动」。**Q2 实测**——pm-ui 1.1.2 在 1418×1022 窗口截图（scratchpad shots/plans-before.png）：执行态列被明细面板盖住只剩「部」「未」；明细里 `A7R06770.JPG` 那条 Raw 路径逐字折成 6 行、待裁决徽标（整句 why）碎成 5 行；而且执行态写的是「部分 8/8」（GUI 自拼），CLI 同一份是「已执行（余 8 项待裁决）」。根因：`.split` 两栏各 `minmax(…,1fr)`，9 列 nowrap 的列表比半栏宽，`.table{overflow:hidden}` 让它对栏宽的最小贡献为 0，栏不长、尾列被后画的明细盖住；明细也只剩半栏。类级修：`.split` 单栏上下堆叠 + `.tbl-scroll`（≤ 42 vh 自滚、表头 sticky）、`td.path` 任意断行、`td.stc` 只放三词徽标 + `.why` 另起一行、`.st` inline-block 整词；措辞改为服务端 `state`（`runTag`）原样显示，GUI 不再自拼；失效草稿明细顶上黄横幅、不渲染「执行」，按钮改「清理已执行/失效」。**验证**——`stack test --fast` 437/437 警告 0（新增 `caseStale` 七段：源在 / 只缺一条 / 全缺 / 有 Done / 仅跳过 / 卷不在 / prune 清失效留活草稿）；Edge headless 以本地新 `pm serve --writable --allow-apply` + 页面桩（`__TAURI__.core.invoke("api_info")` 返回端口与 token，`--host-resolver-rules` 让来源恰为 `http://tauri.localhost`）在 1418×1022 复现（scratchpad harness/plans-after.png）：9 列全见、六份草稿「已失效（源已不在）」淡化、dedupe「已执行（余 8 项待裁决）」、明细整宽路径一行、why 另起一行。桩截图第一版抓到一个真 bug：`showPlan` 里新变量取名 `stale` 与外层响应代际函数 `stale(key, gen)` 同名，块内先调用后声明进 TDZ，明细报「Cannot access 'stale' before initialization」——改名 `isStale`，第二版截图通过。真实库新 `pm plan list`：6 份草稿全部「已失效（源已不在）」、dedupe 不变。**残余**——真实库那 6 份失效草稿清不清，交用户 AskUserQuestion 裁定（本轮零计划文件删除、零照片改动）。
