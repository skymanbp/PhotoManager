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

**1.1.3 计划页失效草稿 + 版式（2026-09-02 深夜，用户反馈「1. 为什么还有那些好多条未执行计划？2. 已执行计划在 GUI 页面上看着很乱，各种溢出文字重叠。3. 修复问题，更新版本。全量更新文档、readme、本机安装版本，然后发布新 release」）**：**Q1 实测**——`pm plan list` 7 份：4 份 import 草稿（2026-08-23，各 220 项；逐项探源 220/220 相机卡文件已清）+ 2 份 names 草稿（08-24，6 项；旧夹名已改）+ 1 份 dedupe 已执行（余 8 项待裁决）。六份草稿都是同一批事后来用新计划执行过后留下的（import 走了 --apply 的新 id、names 走了 0c238a）；1.1.0 的 prune 判据「草稿不动」是刻意的保守，代价是永远执行不成的草稿也永远留着。用户中途自己点了「清理已执行」——一份未删（dedupe 有待裁决残余、草稿不算已执行），按设计。**根因 / 类级修**——「再也执行不成」有客观判据：每一条待办的源（拷贝源 / 改名旧路径 / 隔离 victim，`Pm.Op.opSource`）都不在盘上而源所在的卷还在 → `Pm.Plan.planStale` 一个谓词，`pm plan list` / `prune`、serve `GET /api/plans`（新字段 `stale` + `state`）、GUI 四处同源；卷不在（相机卡拔了）不算，探测抛出按「源在」计，journal 有告警的根不判、prune 整根不删（fail-closed：失效判据依赖「无 Done」，折叠不全时不可信——这比 1.1.0「告警只是附注仍清已执行」更严，DESIGN-COMMANDS 新节登记）。`opSource` 初放在 Pm.Plan，DocDrift 隔离产地清点（引用 OpQuarantine 的模块集合固定）判红——它是纯读者，挪进 Pm.Op 与 `opPathsOk` / `describeOp` 同处，名单不扩；旧用例 caseDeleteAndPrune 的「草稿」没有真实源文件、按新判据正是失效草稿而被清——夹具补上源文件（活草稿），用例名改「活草稿不动」。**Q2 实测**——pm-ui 1.1.2 在 1418×1022 窗口截图（scratchpad shots/plans-before.png）：执行态列被明细面板盖住只剩「部」「未」；明细里 `A7R06770.JPG` 那条 Raw 路径逐字折成 6 行、待裁决徽标（整句 why）碎成 5 行；而且执行态写的是「部分 8/8」（GUI 自拼），CLI 同一份是「已执行（余 8 项待裁决）」。根因：`.split` 两栏各 `minmax(…,1fr)`，9 列 nowrap 的列表比半栏宽，`.table{overflow:hidden}` 让它对栏宽的最小贡献为 0，栏不长、尾列被后画的明细盖住；明细也只剩半栏。类级修：`.split` 单栏上下堆叠 + `.tbl-scroll`（≤ 42 vh 自滚、表头 sticky）、`td.path` 任意断行、`td.stc` 只放三词徽标 + `.why` 另起一行、`.st` inline-block 整词；措辞改为服务端 `state`（`runTag`）原样显示，GUI 不再自拼；失效草稿明细顶上黄横幅、不渲染「执行」，按钮改「清理已执行/失效」。**验证**——`stack test --fast` 437/437 警告 0（新增 `caseStale` 七段：源在 / 只缺一条 / 全缺 / 有 Done / 仅跳过 / 卷不在 / prune 清失效留活草稿）；Edge headless 以本地新 `pm serve --writable --allow-apply` + 页面桩（`__TAURI__.core.invoke("api_info")` 返回端口与 token，`--host-resolver-rules` 让来源恰为 `http://tauri.localhost`）在 1418×1022 复现（scratchpad harness/plans-after.png）：9 列全见、六份草稿「已失效（源已不在）」淡化、dedupe「已执行（余 8 项待裁决）」、明细整宽路径一行、why 另起一行。桩截图第一版抓到一个真 bug：`showPlan` 里新变量取名 `stale` 与外层响应代际函数 `stale(key, gen)` 同名，块内先调用后声明进 TDZ，明细报「Cannot access 'stale' before initialization」——改名 `isStale`，第二版截图通过。真实库新 `pm plan list`：6 份草稿全部「已失效（源已不在）」、dedupe 不变。~~**残余**——真实库那 6 份失效草稿清不清，交用户 AskUserQuestion 裁定~~ **已了结（2026-09-03 复核）**：本轮（1.1.3）零计划文件删除、零照片改动不变；那 6 份草稿此后已被清掉——`D:\Photography` 下 `pm plan list`（pm 1.2.0）打「还没有计划。」exit 0，`.pm\plans\` 是空目录（mtime 2026-09-02 23:23）。另：~~《操作手册》v9 第七章 7.3 待办表仍留着「计划页 6 份旧草稿……本轮一份未删」那一行，本轮不重生成，下次重生成时一并改~~ **已改（2026-09-03，手册 v10）**：那一行的处置列换成本表的了结标记 `**已执行**` + 上面这条复核证据，现状列里说 dedupe 计划「仍」在的那个字改成「当时」；PDF 由仓外生成链产出（`/*.pdf` 不入库）。

**1.1.3 发布实录（2026-09-02 深夜）**：单提交 497477d（代码 + 版本串五处 + release-notes + 文档）→ sancheck 135 文件 0 命中 → rangescan 1 提交 0 命中 → 快进 → push main → main run 33706827825 绿（build ≈ 9 min，缓存热）→ `git tag -a v1.1.3 497477d` + push → tag run 33707446216 build + release 双绿 → release v1.1.3 三资产（zip 12397499 B、setup 8382336 B、sha256.txt）→ 回下载 `sha256sum -c` 两项 OK（zip `5613b26d…`、setup `b44b2448…`）→ 仓内 leakscan 12 模式 0 命中 → PATH `%APPDATA%\local\bin` 的 pm.exe / pm-ui.exe 用 zip 覆盖后 cmp 逐字节相同 → NSIS 静默装 DisplayVersion 1.1.3、安装目录 pm-ui.exe 与 zip 恰差 3 字节（同 1.0.0 起的 bundle-type 标记）→ `pm --version` 1.1.3 → 真实库 `pm plan list`：6 份草稿「已失效（源已不在）」、dedupe「已执行（余 8 项待裁决）」，零计划文件删除。装好的 pm-ui 1.1.3 真机拉起并连上 serve（状态页截图 scratchpad shots/plans-real113.png）；计划页真机截图因前台锁（用户正在用机器，SetForegroundWindow 四次被拒）未取到，版式以 Edge headless 桩截图为准（同一份 gui/ui、同一 Chromium 内核）。两本手册按 1.1.3 重生成（v8 71 页 / 图册 16 页，Gmail 服务端核过两附件）。**事故登记**：第一版 tour 脚本用 `FindWindow(null, "pm")` 按标题找窗口，撞上 VS Code 的一个 170×47 子窗口并向它发了「5」与 End 两个按键——若当时某编辑器有焦点可能被插入一个 "5"，已告知用户核查；脚本改按 pm-ui 进程主窗口句柄。

**1.2.0 I7 判定侧（2026-09-03，用户裁定「实现 DESIGN-COMMANDS §10.3 第 2 项的消费侧」）**：**缺口**——§10.3 第 2 项正文承诺「ingest 的 journal 来源登记喂 I7：doctor 把 inbox 来的照片归为已解释而非违例」，落实表却是「判定侧 ⏸ 未做」，`src/Pm/Ingest.hs` 头注同写「消费侧尚未实现」，DESIGN §2 的 I7 校验列与 §14 的「相册↔成片 例外文件」行也各挂着同一条待办——四处指向同一个零代码的判定。**实现**：`Pm.Doctor.i7Findings`（内核只读，无新 Op、无新记录类型——I2/I4 面零变化）。已解释两条都以内容为准：① 索引里有同 sha 的成片副本（设计内冗余的定义就是同一份字节）；② journal 里有一条 Copy 记录，dst 经 `foldPath` 与这条相册路径相等、`opSha` 与盘上现字节相同、`opSrcAbs` 经 `pathAtOrUnder` 得到**明确的** `Just False`（库外）。三处判据各有独立的错误后果，逐条都留了突变配对：库内源（`pm album add` 的形态）若算进来，「相册 ⊆ 成片」就成了同义反复；sha 不等的记录说的不是这份字节；`pathAtOrUnder` 答不上来（卷已拔走 / ACL 拒）不算库外——把查不出的记录当成来源证明正是布尔探针塌态那一类错误，反方向只多一条待人工核查的 Warn。认 Intent 而不等 Done：Intent 就是来源记录本体（P6-D），「这份字节确实是那次拷贝落下的」由 sha 相等作证；journal 是可手编输入，路径字段先过 `opPathsOk`（同 `classifyPending`）。**fail-closed**：journal 有告警或快照是坏代回退 → 整条判据不判、只打一行 Info（判据含否定式「journal 里没有别的来源记录」，折叠不全时会把正常照片报成违例），与 1.1.3 `planStale` 同一纪律。**修复面**：I7 行进不了 `applyRepairs`——白名单只认 C2/R2/Q-DONE-LOST/C5 且要求详情以 oid 开头，用例里 `--repair` 跑完 orphan 文件字节未变。**结构**：`Pm.Doctor` 不能 import `Pm.Album`（Album → Cli → Doctor 成环，同 1.1.2 拆 `Pm.Derived` 的那个环），层名 `相册`/`成片` 因此从 `Pm.Album` 收进 `Pm.Types` 单一定义、`Pm.Album` 按原名再导出（Convert/ServeAi/ServeVault 三处改为经 `Pm.Types` 取，冗余 import 清零）；Doctor.hs 742/750。**测试**：IngestTests 新增 3 例——ingest `--apply` 端到端后**把源删掉**（skill 的 `_inbox→_done` 那一步）再 doctor，仍判「inbox 来源 1 · 未解释 0」exit 0；成片同 sha 副本已解释 + 无解释项逐条 Warn、exit 1、`--repair` 不动盘；三处判别（src 在库内 / sha 与盘面不符 / journal 中段损坏 → 不判）。突变 m1（删 inbox 那条）/ m2（删成片同 sha 那条）/ m3（删 sha 相等）/ m4（不问库内库外）/ m5（去掉 fail-closed 闸）各判红恰一例。既有 `SweepTests.caseDoctorDeepSummary` 的夹具两张照片从相册层改放成片层——相册层上无源的照片按新判据**正是**违例，其 `exit 0` 断言会变成对另一件事的断言（同 1.1.3 把 `caseDeleteAndPrune` 的草稿补上源文件的先例）。440/440，GHC 警告 0。**真实库实测**（只读）：`pm doctor` → `[I7] 相册 ⊆ 成片 ∪ inbox-origin: 94 张 = 成片副本 94 · inbox 来源 0 · 未解释 0`，exit 0——DESIGN §14 曾登记的「1 个例外文件」在 09-02 的 EXIF 改正批之后已不复存在，该行按实测改写。**残余**：`pm convert` 以相册里的非 jpg 为源时，派生 jpg 只落相册（源在相册那一支），既无成片副本也不是库外来源——真实库现无此形态（未解释 0），若日后出现会以 I7 Warn 现身、由人裁决，不在本轮扩判据。

**1.2.0 发布实录（2026-09-03）**：单提交 d35ebd1（代码 + 版本串五处 + release-notes + 文档）→ push main → main run 33796263718 绿 → `git tag -a v1.2.0 d35ebd1` + push → tag run 33797741834 build + release 双绿 → release v1.2.0 三资产（zip 12403697 B、setup 8385828 B、sha256.txt 183 B，与 v1.1.3 同一套）→ 回下载 `sha256sum -c` 两项 OK（zip `55a3bfe6…`、setup `48e4bd8e…`）→ 仓内 `scripts/leakscan.py` 对三件（zip 内 pm.exe / pm-ui.exe + setup）12 模式 0 命中 → zip 内 `pm.exe --version` = pm 1.2.0。装机：PATH `%APPDATA%\local\bin` 的 pm.exe / pm-ui.exe 用 zip 那份覆盖后 `cmp` 逐字节相同、`pm --version` 1.2.0；NSIS 静默装 `/S /D=%LOCALAPPDATA%\pm-ui` 退出码 0、DisplayVersion 1.2.0、安装目录 pm.exe 的 sha == zip（`bb62542e…`，三份 pm.exe 同一 sha）、pm-ui.exe 与 zip 恰差 3 字节（bundle-type 标记，同 1.0.0 起）。真实库冒烟（装机后的 1.2.0，只读）：`pm doctor` exit 0、末两行 `[VERIFY-AGE] 4633 条目; 无验证时间戳条目 0` 与 `[I7] 相册 ⊆ 成片 ∪ inbox-origin: 94 张 = 成片副本 94 · inbox 来源 0 · 未解释 0`；`pm doctor --vault`「无发现」exit 0（vault root 无相册层，I7 一行不打）。突变复核在**全量 440 例**上重跑：m1–m5 各判红恰一例（m1/m2 判 I7 的两条端到端用例，m3/m4/m5 判「三处判别」那例）。~~**未做**：两本手册 PDF 未按 1.2.0 重生成——仓内无生成脚本（PDF 本身 gitignore），历来由用户在仓外重做。~~ **已补（2026-09-03）**：生成链确实在仓外（会话 scratchpad 的 `build_manual.py`：章节 JSON → 单文件 HTML + 本地 mermaid 11.4.1 → Edge headless 打印），但「历来由用户在仓外重做」不准——v6/v7/v8 都是这条链在会话里跑出来的，本轮沿用同一条。《操作手册》~~v9（71 页，3 837 871 B，sha256 `cf5f3b43…`）~~ **v10（71 页，3 840 399 B，sha256 `d3708655…`）** 改十处，前九处：0.7 与 1.10 两张不变量表的 I7 行、1.3 那句「doctor 的判定侧尚未实现」、第 3 章导语与第 4 章「命令按哪一版帮助文本写」的版本串、3.10 新增一条讲 I7 判定的项目符号 + doctor 表首行补 `[I7]` 汇总行、6.6 只读命令表的 doctor 行、第七章标题与导语、7.1 主库行补 09-03 只读复测的两行 Info（第七章计一处，内含 7.2 追加的 1.2.0 当日记录一条）；第十处（当日稍晚，v9→v10）是第七章 7.3 待办表「计划页 6 份旧草稿」那一行——处置列由「清不清由你定……本轮一份未删」改成 `**已执行**`：那 6 份草稿连同 dedupe 20260825-224708-d24f7e 都已清掉，2026-09-03 在 `D:\Photography` 复核 `pm plan list` 打「还没有计划。」exit 0、`.pm\plans\` 是空目录；现状列的「仍」改「当时」。patch 脚本对全书做递归逐字段 diff，改动恰这 2 个单元格，页数不变（仍 71 页，7.4 仍与它同页）。《GUI 一键操作图册》（16 页，567 130 B，sha256 `f841e608…`）只改封面版本行——1.2.0 没有 GUI 面改动；v10 那轮不重建它，字节未变。核验：pypdf 逐页抽文本（手册按 v10 复核），两本 MERMAID ERROR 各 0 页、封面版本行 = pm 1.2.0 / pm-ui 1.2.0、旧句「判定侧尚未实现」残留 0、手册里旧待办句「清不清由你定」「本轮一份未删」残留各 0、新句「还没有计划。」1 处；PDF 仍由 `/*.pdf` 排除，不入库。v9 那份存档在生成链 scratchpad 的 `v9-backup/`（同 v8 的做法）。 **邮寄（2026-09-03）**：两本一封发到 skyman.bp@gmail.com（`send_email.py --alias gmail`，沿用 v8 的一封两附件形式），主题「PhotoManager 两本手册（pm 1.2.0 版）」，附件 3 837 871 B（手册 v9）+ 567 130 B；Gmail 服务端回读 id `1a0691cfed3917f4`——主题逐字相符、两个 application/pdf 部件字节数与盘上两份逐一相等、labels SENT+INBOX。手册改成 v10 后当日单独补寄一封（只带手册）：主题「PhotoManager 操作手册（pm 1.2.0 版，§7.3 待办行已更正）」，Gmail 服务端回读 id `1a06924b1b75fcea`——主题逐字相符、单个 application/pdf 部件 3 840 399 B 且 sha256 `d3708655…` 与盘上那份逐字节相同、labels SENT+INBOX；图册未变，不重发。

## 2026-09-25 全量 debug 审计修复（分支 `claude/full-debug-fixes`，基于 14215e1；用户令「按 HANDOFF 建议顺序逐条修复 medium 12 条与列出的 low 项，每条一个提交」）

审计本身是只读的（`docs/reviews/2026-09-25-full-debug-audit.md` + `-findings.json` + `-HANDOFF.md`，云端会话，零代码改动）。本节按修复提交顺序逐条登记：改了什么、钉针在哪、突变判红形态；未做项与设计取舍见节末。修复纪律沿用 HANDOFF：每条附可在 Windows 跑的测试或哨兵；不改盘上格式；不新增删除/覆盖原语；读路径「查不出」不塌成「不存在」；`.pm` 写经既有可信口；文件 ≤ 750 行。本机就是 Windows，验收直接跑 `stack test`（Linux 壳未用）；全量跑在 `D:\Projects\.worktrees\PhotoManagerixes-ci` 工作树按提交逐次复跑。

- **前置拆分**（ad41be9）：`Config.hs` 恰 750 行，#4/#5 都要在它里面加行——`Config` 记录 + TOML 解码 + `checkAbsolute` / `absolutizeConfig` / `tomlStr` / `renderConfig` 字节级搬进新模块 `Pm.ConfigTypes`（先剪源再写新模块；Config 原样再导出，调用方 import 不变；DESIGN §4 模块清单登记）；440/440。
- **#4**（medium，`Pm.Config.configFilePath`）：只 `makeAbsolute` 看不见 junction / SUBST / 8.3 短名，`withConfigLock` 与 `writeConfig` 的句柄后验（`openBoundTo` / `rawBoundTo` 对比 GetFinalPathNameByHandle 规范形）必然失败且 userError 非 EBUSY 被原样重抛——init / config set / backup init 崩、读照常。改在源头 `canonicalizePath`（存在的最长前缀解析，尚不存在的 config.toml 照常拼上），解析失败退回 makeAbsolute 形态（不比此前更差）。钉针：新模块 `test/AuditFixTests.hs`（GuardTests 740 行放不下）`#4`——PM_CONFIG 指向 junction 下的 config.toml：`configFilePath` = 真名、两次 writeConfig（第二次走删旧→落位）、`withConfigLock` 得 Just、loadConfig 读回；修复前实跑红（拿到的是 junction 拼写）。
- **#5**（medium，`Pm.Config.createRootInfo'`）：`.pm` 写口里唯一按调用方原样 root 拼路径的一处——root 是 junction / SUBST / 8.3 短名时 `moveBoundNoReplace` 的句柄先验对不上规范形，失败臂的 `deleteBoundAt` 同样对不上并**抛出**，异常逃出 pm init / 首次 vault push，每次尝试泄漏一个 `root-id.json.<hex>.tmp`。改为 `resolveUnder root ".pm/root-id.json"` 取 canonical 落位目标（Nothing → Left untrustedMsg，与 writePmState / writeCacheFile 同形），tmp 从它派生；失败臂删 tmp 包 try、原因并进报文。审计 A5 顺带点名的「正斜杠 vault.path」不成立：`normPath` 按 splitDirectories 切分、两种分隔符等价，未纳入钉针。钉针 `AuditFixTests #5`：root 为 junction → Right、root-id.json 落在真名下、无 .tmp 残留、readRootInfo 经 junction 读回；再建一次 → Left 不覆盖不抛、仍无 .tmp。修复前实跑红（`拒绝删除` userError 逃出）。
- **#10**（medium，`Pm.Sort.existingEvents`）：R1 的 whenPresent 改写把「是不是目录」守卫换成「名字在不在」探针，`Raw\` 下 Explorer 留下的 desktop.ini / Thumbs.db 被当年份夹 listDirectory，FindFirstFile 于 `file\*` 抛「目录名称无效」→ 整个概览 Left（`pm sort <src>` exit 2、/api/sort/survey 与 /api/suggest 409），报文说成被占/介质错误。修法：`Raw\` 直接子项里 `doesFileExist` 明确为文件的跳过——它只在「确定是文件」时为 True，目录 / ACL 拒绝 / 缺失仍走 whenPresent 三态（查不出 → 整体 Left），R1 保证不削弱。钉针 `SortTests` 新例：库里放 `Raw\desktop.ini` + `Raw\Thumbs.db` + `Raw\2026\26-08-Atlanta-Raw\` → surveySort Right、1 段、同年月提议恰 `["26-08-Atlanta"]`；修复前实跑红（Thumbs.db 读取失败）。
- **#2**（medium，`gui/ui/app.js` 设置页）：并发数 / 掉线等待两个保存按钮是 `Number(val(…))` 直提——留空（设置未设时的常态）得 0：workers 0 被服务端 400 拒且怪到用户没输过的值，driveWait 0 却是合法的「关闭瞬断保护」，静默写盘、横幅报成功。审计给的两种修法里选「拒绝」而非「留空 = null 清空」：这两个框的 placeholder 写的是默认值而不是「留空 = 默认」，各自另有「恢复默认」按钮，且 `<input type=number>` 里非法文本的 value 也是空串——照 valOrNull 处理会把一次误输入静默变成清空。新增 `numOrRefuse`：留空 → 横幅拒绝并指向「恢复默认」，不发请求。钉针 `DocDriftTests` 新哨兵：两个处理器行都须含 numOrRefuse、脚本不得再有 `Number(val(`；修复前实跑红。`node --check` 语法过；GUI 无 harness，交互按 DESIGN-GUI 既有做法留待真机 tour。
- **#1**（medium，`gui/ui/app.js` 整理页 `sortAiPlaces`）：AI 看图（claude -p，最长 3 分钟）期间用户再扫描（可能换了源目录），renderSurvey 重建 segInputs，晚到的响应按段号写进**新**概览的空输入框——上一张卡的地点填进另一张卡，再点「生成计划」就是错名的事件夹。修法与本页其它加载器同一纪律（41 轮 #2 的 stamp/stale）：起手捕获概览对象与 sort 代号，await 之后 `stale("sort", gen) || lastSurvey !== survey` 即整批丢弃并横幅说明（不静默）；重扫失败（代号变、概览未变、旧输入框已从 DOM 摘下）同样丢弃。同根第二形态一并收：renderSurvey 按分段数重置按钮，请求在途时重扫会把它放开、可并发第二发（先回的那发 finally 复位文案，后一发把「AI 看图中…」当原文案卡死）——加 `aiBusy` 门控。钉针 `DocDriftTests` 新哨兵：sortAiPlaces 的 `await post(` 之后须含两个守卫、renderSurvey 须 `aiBusy ||` 门控；修复前实跑红。`node --check` 语法过。
- **#7**（medium，`Pm.Plan.planStale` 探盘无错误模式）：SEM_FAILCRITICALERRORS 此前只由备份发现懒设，计划页失效判定探计划源与其所在卷时进程未设——读卡器空槽弹系统「请插入磁盘」框并阻塞 `pm plan list` / `prune` / `GET /api/plans`。错误模式是进程级的，类级修法是 `app/Main.hs` 的 `main` 在 `setupConsole` 之后设一次（Microsoft 建议做法），全部子命令（含 pm ui 拉起的 pm serve）与今后任何探盘路径一并覆盖；备份发现里那次调用保留（库级调用方如测试套件）。未改 `SetErrorMode` 的整值写法（与 MS 文档的启动写法一致）。钉针 `DocDriftTests` 新哨兵：main 体内须有非注释行调用 suppressCriticalErrorDialogs；修复前实跑红。空槽本身造不出来，`PlanExecTests` caseStale 注释写明由此兜。文档同步：DESIGN §14 风险表该行、DESIGN-COMMANDS §9。
- **#11**（medium，`Pm.Versions.rawEventOf`）：只要求三段，`Raw\<年>\<文件>` 把文件自己的名字当事件夹——每个文件各成一键，旁边同 stem 的 RAW 永远对不上，判据③失效，Raw↔成片 同 sha 对被当设计冗余从 vgExactDups 丢掉（pm versions / pm dedupe 都看不到），与 DESIGN-COMMANDS §5 判据③「有原始档 = 导出件误放，仍报」相悖。改为要求文件至少在事件夹下一层（`a : b : c : _ : _`），定位不到 → Nothing → 判据③不认设计内（原注释「宁可多报一行噪音」的本意）。钉针：`NamesTests` caseDesignedGroups 加 `Raw\2024\V.JPG` + `Raw\2024\V.ARW` + `成片\24-05-X\V.JPG`，期望 s17 进 vgExactDups；修复前实跑红（缺 s17）。
- **#9**（medium，`Pm.Serve` 无异常边界）：POST /api/apply 与 recordPost（hold / notes）的写链没有 `try`，内核按设计原样重抛的 IOException 逃到 warp 的裸 500（text/plain、无 CORS），跨源的 Tauri 页面只看到「Failed to fetch」或「没有执行」，而项可能已落位并记了 Done。聚类：planPost / listPlans 早已各自补过同形，缺的是**类级**的最后一道边界——每个新端点都要记得自己 try 的模式补不完。修法两层：① `serveApp` 包 `route`，接住 IOException 答 500 JSON（带 CORS）；已开始应答的（发送途中出错）不二次应答、原样重抛（`sent` 标记包在 respond 上）；② apply 端点自带 try（同 planPost 形态），答 500 + `interrupted: true` + planId + 至此的 log；GUI `applyPlan` 按 `interrupted` 说「执行中断（可能已有项落位）」并照常刷新计划列表，不再说「没有执行」。DESIGN-GUI P7 执行面一段同步。钉针 `AuditFixTests` 两例：`.pm/lock` 被目录占名（root 锁打开抛 PermissionDenied，非 EBUSY 原样重抛）→ apply 答 500 JSON、interrupted/planId/log 齐、`Access-Control-Allow-Origin` 在、照片未落位、app.js 认 interrupted；同一注入打 /api/vault/hold → 500 JSON 带 CORS、vault-holds.json 零写入。只撤 Serve.hs 的修复实跑两例皆红（异常逃出 serveApp），还原皆绿。
- **#39**（low，`Pm.Exec.execCopy'`）：建 tmp 目录后的二次限域失败臂是 Intent 之后唯一不写终态的中止臂——Intent 悬空，doctor 对一场正常结束（有 CleanShutdown）的会话报假 C1「写 tmp 前中断」，计划执行态既非完成也非失败。逐臂核过：rename / quarantine 的限域失败都在各自 Intent **之前**返回（Intent 在 execRename' / execQuarantine' 里写），只此一处。修法与 execCopyTmp / execCopyLand 中止臂同形：先 `JFailed` 再返回 escapeOutcome（tmp 未创建，无需清理）。钉针：`PathGuardTests` caseExecTmpSecondCheck 末尾加两断言——该项须有 JFailed、doctor 不得报 C1；修复前实跑红（journal 只有 Intent + CleanShutdown）。该文件因此 749 行，贴近预算。
- **#43**（low，`Pm.Op.isTrashSrcRel`）：trash 例外只比首两级，`.pm/trash` 本身（FpDir）与第三级的 `manifest.ndjson` 都算合法 rename 源——手编计划经 validatePlan 放行，apply 把 write-ahead manifest（或整个隔离区）搬进用户数据，此后隔离载荷全部失登记、`pm trash empty` 无可清、undo 拒绝反转。谓词是 validatePlan / execItem / undo 反转生成 / doctor classifyPending 共用的唯一闸，收紧一处全类收口。修法取报告首选：至少四级（`.pm/trash/<隔离目录>/<victim…>`）——所有产地（组复位、undo 反转）都经 `trashSrcRel (quarDirFor pid sfx </> victim)` 拼出，trash 下的目录只有 quarDirFor 造的隔离目录。报告列为可选的「第三级须是隔离目录名」未做：在上述构造不变量下与四级等价，且会把 PathGuardTests 里 trash 内 junction 偷库外文件那例（词法上正当、专钉 Exec 限域）提前挡在词法层，丢掉纵深那一层的钉针。钉针 `AuditFixTests` #43：生成形态（普通隔离、~d 位移隔离）照旧放行；trash 根、manifest、大小写别名、整个隔离目录四种源 validatePlan 与 execPlan（取锁前零写入）都拒、manifest 原样不动；修复前实跑红。
- **#6**（medium，`Pm.Names.runNamesOn` 的 filterDirs）：年份夹 / 事件夹 / 成片的逐项分类用 `doesDirectoryExist` 二态——它走 CreateFile，对象自身 ACL 拒绝（deny F）塌成「不是目录」，该夹从报告里静默消失：表头不计、无 ⚠ 行，实测 `Raw\2024` 被拒时报「✓ 无可机械执行的改名」exit 0；成片层少一个候选还会把月份歧义变成唯一改名。R1 的 `whenPresent` 救不了这一形：名字探针对被拒对象照样答「在」，随后的 doesDirectoryExist 仍答 False。上游根因是「枚举结果逐项判是不是目录」没有三态原语，聚类同形共四处：Names 本身（含 Raw / 成片两层存在性与改名目标占位判定）、`Pm.Vault.listFlatPhotos`（被拒子目录被当文件、再被扩展名过滤吞掉，「子目录显式报出」落空）、`Pm.Sort.existingEvents`（#10 的 `not . doesFileExist` 把被拒的普通文件当年份夹去枚举，概览整体失败）。修法：`Pm.Win` 加 `probeIsDir`——读 GetFileAttributesW 的 DIRECTORY 位，与 `probeName` 共用同一探针与错误码纪律（新抽 `fileAttrs`，只认 2/3 为缺席），对象自身 ACL 不影响它；三处枚举改走它（读不出的目录仍是目录，随后枚举抛进既有 try → 整批拒绝 exit 2；查不出同一出口），Names 的目标占位改走 `probeName`（ACL 拒绝的占位者算占，查不出降裁决）。钉针：`NamesTests` 新例三场景（Raw\2024 被拒 → exit 2 点名路径零计划；成片两个候选之一被拒 → 仍歧义 exit 1；改名目标被拒 → 算占位降裁决）+ 探针四态（目录 / 文件 / 缺席 / 非法名查不出）；`VaultTests` R1 例加被拒子目录仍报成子目录；`SortTests` #10 例加被拒的 desktop.ini 不让概览失败。四处修复前实跑皆红；场景二、三另做突变配对（只撤 filterDirs、只撤目标探针）各自转红。
- **#34**（low，`Pm.Doctor.classifyPending'`）：在途 Copy 的 dst 用 `doesFileExist` 二态探——对象自身 ACL 拒绝（deny F）把「已落位、Done 丢失」塌成「C1 Info：Intent 后无痕迹」exit 0，重跑只会撞上一个「外来文件」，`--repair` 也永远看不到 C2。Quarantine 臂的 victim 同形（报告列为可选），塌成「Q? victim 与 trash 均不存在」。与 #6 同一根因（布尔存在性探针把「在而读不出」塌成「不在」），此处已有现成三态原语 `userSideExists`（F033 给 Rename 臂造的），两臂改走它：名字在 → 原有的读取失败分支（dst → `C?` Bad，不进 --repair 白名单；victim → Q2「隔离未执行、原位读不出」）；查不出 → PM-LINK Bad。至此 classifyPending' 三臂的用户侧存在性全部三态。DESIGN §6.4 PM-LINK 行同步（覆盖 Copy dst / Quarantine victim，并写明被拒对象走「读不出」文本）。钉针 `AuditFixTests` #34：同一 journal 两条在途 Intent（已落位的 Copy、未执行的 Quarantine），dst 与 victim 都 deny F → 须有 `C?` Bad 与 Q2、不得有 C1 / Q?；修复前实跑红（`[C1 Info, Q? Bad]`）。查不出（PM-LINK）臂与 Rename 臂 F033 同形、未单独注入。
- **#12**（medium，测试空转，`KernelTests`「P3b-5 #1 doctor: Q-DONE-LOST 补记前核 sha」）：夹具没写 root-id，`runDoctor --repair` 在 `requireWritable` 处被拒（I11 行被 `_ <-` 丢掉），`applyRepairs` 根本不跑，「--repair 不盲补」的断言恒真。只改测试：补 `writeRootInfo`，并断言修复轮无 I10/I11 拒绝行（闸门将来改动不能再悄悄架空它）。突变配对实跑：把 `applyRepairs` 白名单的 `fSeverity f == Warn` 去掉——旧测试照样绿（证明空转），新测试转红（盲补出一条 JDone），还原转绿。无产品代码改动。
- **#13**（low，文档）：README 两版速查与 DESIGN §5 命令表把撤销写成 `pm undo --last [N]`——按文档自己的方括号约定，读作 `--last` 可不带值；实际 `option auto … value 1` 只在整个选项缺席时取默认，裸 `--last` 被 optparse 拒（exit 1）。三处改为与 `pm undo --help`（实跑：`Usage: pm.EXE undo [--last N] [--backup] [--vault]`）同形的 `pm undo [--last N]`（DESIGN 用小写 n，随其表内惯例）；速查行宽不变，注释列不移。DocDrift `caseReadmeSync` 的 undo 哨兵原只查子串 `pm undo --last`，放过错位的方括号，收紧为 `pm undo [--last N]`：先改哨兵对旧文档实跑红，再改文档转绿。
- **#19**（low，`package.yaml` extra-source-files）：该段自称登记 DocDriftTests 读的全部非源码文件（41 轮 #9），后续轮次加读的没跟上——`docs/HISTORY.md`（caseReadmeSync）、行预算扫描的整目录（docs / docs/specs / gui/ui 的 js·css / gui/src-tauri/src / scripts）。sdist 树里这些用例会找不到文件（或空转）。实际影响为零（无渠道用 sdist），是段落自述契约与套件的漂移；按报告首选修法补登记而非改口。根因是登记靠人记：改按目录 glob 登记，并加 DocDrift `caseExtraSourceFiles` 机器核对——行预算清单（抽成 `budgetFiles`，行预算与本例共用一份底账）与 tauri.conf.json 里不属包源码的文件，须被某条登记覆盖（精确路径或不跨子目录的 `dir/*.ext`）。先加哨兵对旧登记实跑红（列出 17 个漏登记文件），补登记后转绿；`stack sdist --ignore-check` 实打包，tarball 内含 HISTORY / REVIEW-LOG / specs / app.js / style.css / lib.rs / scripts。cbits 的 .c 已由 c-sources 覆盖，无 .h。
- **#58**（low，测试卫生）：ConvertTests 两处用 `bracket_ (setEnv …) (unsetEnv …)` 临时设 PM_PYTHON / PM_CONVERT_TIMEOUT，收尾一律删掉——跑测试的人自己设的 PM_PYTHON（ConvertTests 头注推荐的路子）被一并删掉，串行在后的 caseE2E / caseDerivedGuards 随之「找不到 python」。聚类：ServeP8Tests 三处（PM_CLAUDE_EXE / PM_FAKE_CLAUDE / PM_SUGGEST_TIMEOUT）同形，一并收口。修法：TestUtil 加 `withEnv`（原来有值写回原值、原来没有才删，设置中途或动作抛出同样还原），五处改走它。PM_CONFIG 各处是「记旧值、finally 写回」的另一写法，套件启动时 Spec.hs 必设 PM_CONFIG，不触发本缺陷，未改。钉针 `AuditFixTests` #58：withEnv 三种还原语义（嵌套、缺席、异常出口）+ 类规则扫描——test/ 非注释行里删环境变量的调用只许在 TestUtil；先加钉针对旧代码实跑红（点名 ConvertTests / ServeP8Tests），改后转绿，Convert / suggest 相关 32 例全绿。未做端到端复现（需把 python 移出 PATH 且避开 WindowsApps 的商店别名）。
- **#59**（low，哨兵缺口，DocDrift `caseGuiNoInlineStyle`）：「innerHTML 只允许赋空串」的判据只看等号后头两个字符是不是 `""`，`el.innerHTML = "" + expr;` / `"".concat(expr)` 都能过——与 F090 前提（DESIGN-GUI、本文件 48 轮）矛盾。现有 19 处全是 `= "";`，非活缺陷。判据抽成顶层 `innerHtmlBad`：每次出现须是 `= ""` 且紧跟语句结束的 `;`，读取 / 比较 / 拼接一律算违规（保守）；并在用例里加判据自身的正反例（清空两种空白写法放行；拼接、链式调用、非空串三种须拦）——先以旧判据跑，反例只拦下 1 种、实跑红；收紧后转绿。测试数不变（断言加在既有用例里）。
- **#36**（low，设计取舍，用户裁定「按正确方法来」）：DESIGN §6.4 的 C3 行（dst 完好、journal **无任何记录** → 按内容归属并补记 Done）代码从未实现；doctor 输出里的 "C3" 实为另一回事（Done 无对应 Intent，跳过），按表查会读反。两条路：按设计实现，或让文档说实话。取后者，理由：① Intent 在动盘前过屏障（I4），这一格只有硬件谎报 flush 才到得了；② 此时连「pm 做过这一步」的证据都没有，只补 Done 的话 undo 照样拒（找不到 Intent），要 undo 可用就得连 Intent 一起补——那是伪造 write-ahead 历史，且盘上那份也可能是人手放进去的，undo 会据此把它隔离掉；现有修复（C2 / R2 / Q-DONE-LOST）都只为**已有 Intent** 补终态，是同一纪律；③ 对账本有正路：重跑原计划，目标已在且内容相同即 SKIP（I5）。改动：C3 行改写为真实契约（doctor 不归属、不补记，对账走重跑，字节核查交 scan / --deep）；「Done 无 Intent」改用独立标签 DONE-ORPHAN 并入表；§6.4 段尾「掉电模型由 C3/R2 接住」改为 C2/R2/Q-DONE-LOST（Intent 过屏障，尾部丢失丢不到它）；§14 风险行与 DESIGN-COMMANDS 备份段同步；ExecTypes / Journal 两处「C2/C3 从盘面重建」的注释改为只有 C2。钉针：KernelTests 原「(C3 语义)」用例改名并加严——`--repair` 不补任何 Done、重跑原计划得 `OSkippedIdentical`、Done 无 Intent 报 `DONE-ORPHAN` 且不出现 C3；只撤 Doctor 标签实跑红（`[("C3",Info)]`），还原转绿。
- **#37**（low，设计取舍，用户裁定「清空后写收尾标记」）：C4 的复验窗口 =「上次 CleanShutdown 之后的全部 Done」，CleanShutdown 此前只由 execPlan 收尾写。批次崩在隔离 Done 之后（或 `doctor --repair` 补记的 Q-DONE-LOST Done）再 `pm trash empty`，下一次 doctor 把刚清掉的载荷报成 C4 Bad「Done 记录的目标不存在……重新生成计划」、exit 1，直到别的计划跑一次。manifest 清除后保留为历史、不留清除记录，doctor 无从区分「清掉」与「丢了」，又不许改盘上格式，故不在 doctor 侧猜。修法：`trashEmptyLocked'` 清掉了条目（含中途失败前已清的）即在锁内经 `withJournal` 补写一条 CleanShutdown——与 execPlan 同一语义（锁内、无在途批次，这条标记是真话）；在途 Intent 的判定按全 journal 末事件、不受窗口影响，C1/C2/C5 不会被它藏掉；窗口被关的代价与「随后跑任何一个计划」相同。清除入口全程只此一处（CLI，GUI 无独立实现）。DESIGN §3 journal 行与 §5 `pm trash list / empty` 行同步。钉针 `AuditFixTests` #37：隔离计划执行后截掉 CleanShutdown（崩在 Done 之后）→ trash empty --yes → doctor 不得有 C4；修复前实跑红（`[("C4",Bad)]`）。
- **#8**（medium，设计取舍，用户裁定「不读，单列出来」）：遍历（`Pm.Scan.listTreeCov`）用 `pathIsSymbolicLink` 判「链接」——它对**任何** reparse 属性答 True，OneDrive 云占位（含已下载的）、Dedup、WOF 压缩的文件与目录整批落进「symlink/reparse point skipped」：scan 不索引、每次退出 1，sort 源里的照片一张不进计划，与 P3b-12 早已定下的「只有 name-surrogate tag 才重定向」相矛盾。同类四处一并改按 `probeName`：遍历、sort 源根说明、`Hash.dirFingerprint`、隔离区枚举（`Trash.linkish`）；`Exec.slotOccupied` 问的是「占没占着」（悬空链接也算），不在此类，保留。目录位改读属性（同一个对对象自身 ACL 免疫的探针；`fileAttrs` / `isDirAttr` 从 Win 导出，`fileAttrs` 的 Left 直接带说明）；跳过说明改为「链接（junction / symlink / 挂载点）：不跟随」。内容不在本机的文件（OFFLINE 0x1000 / RECALL_ON_OPEN 0x40000 / RECALL_ON_DATA_ACCESS 0x400000，取值出自 Windows SDK 10.0.26100.0 winnt.h:15317/15326/15327）按用户裁定处理：stat 只读元数据、不触发下载，新鲜度核对与 (size, mtime) 复用照常——已索引、没改过的不必读；要读内容的两处（scan 的 hash、sort 的源清单：照片与侧车）读前经 `Pm.Scan.readHold` 不读，单列「云端未下载」（scan 报告另起 ☁ 一节、sort 清单单独一格、survey 抬头单计、GUI 整理页读 `cloudOnly`），sort 退出码照样按「没看过」算 1。副作用收口：遍历改按属性判之后，被拒文件不再在遍历层进未枚举覆盖，而是在 stat 出错——scan 的「查不出 = 保留旧条目」（F040）随之扩到逐文件：stat 读不出（非「不存在」）与读前闸拦下的，旧条目原样保留；`srCarried` 的含义与三处报文（scan / backup 结论 / 掉线续跑）措辞同步。钉针：`AuditFixTests` 两例——第三方 reparse 夹具（`test/cbits/pm_test.c`，只链进测试套件，pm.exe 不带）：tag 0xBEE 照常枚举、置 surrogate 位的 0x20000BEE 仍不跟随、源码非注释行里的 `pathIsSymbolicLink` 只剩 Exec；OFFLINE 夹具：scan 一个不读（hash 0）、没改过的按 stat 复用、改过的保留旧条目、新来的不入索引、新鲜度照常 (1,1,0,0)、scan 报告与 sort 清单单列、sort 源不读并退出 1、GUI 读 `sv.cloudOnly`；`ScanGuardTests` 被拒文件用例补「旧条目原样保留」。八个突变（遍历回旧判据、scan 读前闸、sort 读前闸、stat 保留、读前闸保留、sort 渲染、scan 渲染、Trash 回退）逐个实跑转红，还原转绿。已知边界：带过滤驱动的真云占位 / Dedup 对象本机造不出，夹具是同形的第三方 tag；RECALL_* 两位只有内核态能设，由纯函数断言按 SDK 取值钉；「已下载的云文件不带这三位」依据文档（learn.microsoft.com「File Attribute Constants」），未在真 OneDrive 上实测。
- **#3**（medium，设计取舍，用户裁定「大小写都认」）：暂存区判定按写死的拼写 `To-Be-Sync'd` 精确比较（`Cli.stagingFresh` 的 catalog 切片、Import 的路由 / 计划 / 已归档统计、Clean、Diff 的备份范围、Status 的事件统计），而盘面探测（NTFS）折大小写：用户手建成 `to-be-sync'd` 时，新鲜度守卫的切片为空、盘面是满的，每个文件都算「新增」，`pm scan` 也补不回来——import / clean / sort 永远被拒，pm status 却说一致；备份范围也把暂存区误算进去。同形的精确比较还在归档层判定（`inArchiveLayer`、`Dedupe.archiveLayerRel`、`Versions` 的层过滤），一并收。修法：`Pm.Import` 在 `foldPath` 之上立 `sameComp` / `underLayers` 两个折叠谓词，凡拿路径分量比布局层名一律经它们；`stagingFresh` 的核对前缀取盘上拼写（按目录启用了大小写敏感的根上，写死的拼写找不到手建目录），两种拼写并存 → 拒绝并说明，不替用户挑；`sweepCounts` 的键按路径身份比、只折大小写——计划落位按规范拼写记进 catalog（`updateCatalog` 按 dstRel），盘面是手建拼写，同一个文件不再算成「新增 + 消失」（这一条同时惠及 pm status 与备份的主库闸）；不做 normalise：全量回归时 `ScanGuardTests` 的 sweepCounts 穷举抓到第一版借用 `foldPath`，而 normalise 把空路径变成 `.`，全库核对里「基准自身出错 = 整棵树」的空覆盖键随之失效，库根列不出时整份 catalog 会报「消失」。钉针：`AuditFixTests` #3——小写 `to-be-sync'd` / `raw` / `processed` 的库：守卫放行、改成规范拼写的 catalog 同样放行、盘上多一个文件照常拦下、import 路由到规范拼写的目标、同内容在小写 `raw` 归档层 → 已归档冗余、已归档统计 (3,1)、clean 认出待修改、备份范围不含暂存区、dedupe 认小写层；大小写敏感根（`fsutil file setCaseSensitiveInfo`，设不了则跳过这一段）：单一手建拼写放行、两种拼写拒绝；类规则：src 非注释行不再拿层名做 == / /= / elem 比较或当 case 模式字面量（按修复前代码模拟命中 15 处、修复后 0 处）。十个突变（切片、键折叠、盘上拼写、并存拒绝、路由、归档层、clean、备份范围、dedupe、status 的 ==）逐个实跑转红，还原转绿。
- **CI：stack 钉回 3.9.3**（非审计条目，用户裁定「把 stack 钉在 3.9.3」）：`build.yml` 的 `stack-version: "latest"` 在 2026-09-25 解析成 3.11.1（此前一直是 3.9.3），编出的 pm.exe 带进构建机路径（工作区路径、用户目录下 AppData 路径各 1 处），leakscan 判红——main 上只改文档的 14215e1 与本分支检验跑 36225132082 同形同命中，两次 stack test 都绿；本机 3.9.3 编的 pm.exe 同一扫描 0 命中。3.11.1 更新说明里可能相关的是 Windows 默认 msys 环境改为 CLANG64、build 目录支持长路径，具体注入点未复现。修：钉回 3.9.3（与 DESIGN §1 开发环境同版本）；升级前须在本机隔离装新版编 pm.exe、跑 `scripts/leakscan.py` 确认 0 命中。
- **#37 回归**（2026-09-26 横切审计「异常处理」发现，0decf79 引入）：#37 在清除后补写 CleanShutdown 的那一句没有 `try`——journal 写不进（备份盘清到一半掉了、`.pm` 不可写、journal 路径不可信）时 IOException 逃出 `runTrash`，「已清除 k/N」报告不打印，进程按 GHC 默认以 1 退出（与「清干净但有 HELD」同码），正是 C102 修掉过的形状。修：这条写入改为 `try`，照常报清除结果，另报一行「收尾标记没写进 journal」（说明 doctor 若报 C4 是标记缺失而非丢失，执行任意计划即补上），exit 2。钉针 `AuditFixTests`「#37 回归」：同 #37 的崩溃形态、journal 置只读 → exit 2、报告与标记失败行都在、doctor 确报 C4；撤掉 `try` 实跑红（异常逃出），还原转绿。

## 2026-09-26 横切审计补跑与遗留清理（同分支；用户令「补跑，一次一个」→「清掉所有遗留问题，收口项目后走标准发布流程」）

2026-09-25 审计没跑的 5 个横切视角（异常处理、编码与时间、CLI 与文档漂移、安全、偏函数）逐个补跑：每个视角两个按代码分半的查找代理 + 按文件分组的对抗式验证（与 `tools/audit/` 同形，简报是 AUDIT-BRIEF 的本机版：禁 stack build/test、许只读库语义探针、已知 73 条不重报）。确认项续用报告编号（#60 起，视角顺序 → 严重度 → 文件行号，后补的视角不挪前面的号），清单 `docs/reviews/2026-09-26-crosscut-findings.json`。原报告余下的 38 条 low（#14–#57 中未修者）一并清理。本节逐条登记。
- **#61**（low，横切「异常处理」，`app/Main.hs`）：main 没有进程级边界——命令体里逃出的同步 IO 异常（§6.4 写口逃逸 = 进程死亡语义，设计内）落到 GHC 默认顶层处理器，打一行 `pm: <异常>` 后以 1 退出，与 §5.1「1 = 有差异 / 降级 / 计划待处理」同码（例：`pm backup --apply` 途中盘掉了且等不回来，与「有 CONFLICT」同码）。修：`Pm.Cli.exitBoundary` 包住 `run cmd`，同一行进 stderr、以 2 退出；只接 IOException，Ctrl-C 与 ExitCode 照原样传出。钉针 `AuditFixTests` #61（返回码透传、IO 异常 → 2、UserInterrupt 传出、main 经它调命令体）；「边界不接」「main 绕开」两个突变各自实跑转红。DESIGN §5.1 同步。
- **#60 + #62 同簇「等盘保护的触发面漏洞」**（#60 medium、#62 low，横切「异常处理」）：1.1.2 的等盘续跑只在「异常被判成掉线」时触发，两条路漏在外面。上游机制：触发判据只认异常形态，而 ① Windows 上 GHC 把介质错误（Win32 19–36：NOT_READY 21、CRC 23、读写故障 29/30、GEN_FAILURE 31）映射成 `PermissionDenied`，`judgeIO` 却把它整族判确定性（#60）；② 有的读口在盘不在时根本不抛——`loadCatalog` 把掉线读成「尚无索引」，外面光包 `withDriveRetry` 永远不触发，`pm backup` 丢掉有效的备份快照、整盘重 hash（#62）。修：`judgeIO` 对 `PermissionDenied` 先看盘，盘不在 → 掉线（盘在仍原样抛，ACL 拒绝与测试注入不变）；新增 `Pm.Removable.readOnDrive`（读前 `ensureDrive`、读后 `requireDrive`，途中掉盘抛 ResourceVanished、外层等盘重读），`pm backup` 两处读备份索引改用它。钉针 `RemovableTests` #60（盘不在的权限拒绝等盘重试、盘在判确定性）、#62（对偶：光包重试读到假的「没有」；读前等盘；途中掉盘重读；源码哨兵：代码行里不许再有 `withDriveRetry` 直接包 `loadCatalog`）。突变：判据改回整族确定性 → #60 红；`readOnDrive` 去掉前后复核 → #62 红；`pm backup` 调用点改回光包 → 哨兵红。残余（登记）：盘在而介质读错被可信闸读成 CatRefused 的一次性抖动仍不重试——区分「读错」与「篡改」要动可信闸的分类，本轮不动。DESIGN §6.4 末段、DESIGN-COMMANDS 瞬断保护段同步。
- **#64**（low，横切「异常处理」，`src/Pm/Plan.hs` `planStale`）：失效草稿判据说「探测抛出按『源在』计」，实际用的 `doesPathExist` 把一切 IOError 吞成 False，外面的 `try` 形同虚设——源探不出（ACL 拒绝、介质读错、断网、非法名）被判「已不在」，每条待办都这样时草稿显示「已失效」、`pm plan prune` / 清理按钮把计划文件删掉（照片不受影响）。同类排查：`doesPathExist` 另两处（`Exec.slotOccupied` 查不出按占用、`Win.openFreshBinary` 后接独占创建）都已 fail-closed，只此一处坏。修：改用三态 `probeName`，只有 `NameMissing`（Win32 错误 2 / 3）算不在，`ProbeUnknown` 算在；卷探测不变。「整张卡的文件夹被删」仍是错误码 3 → 失效（1.1.3 行为不退）。钉针 `PlanExecTests` #64：非法名（错误码 123，同 ScanGuardTests 的注入口径）→ 不失效、prune 不删；判据改回「非普通即不在」实跑转红。DESIGN-COMMANDS 失效草稿行同步措辞。
- **#71**（medium，横切「CLI 与文档漂移」，`src/Pm/Vault.hs` `photosJsonRef`）：photos.json **未配置**时引用检查答「未被引用」（`Right Nothing`），于是 ① `pm vault notes` 把已在 vault 的记录报成 `pending`、exit 0——DESIGN-P8 §21.2 明文「核对不了不许答 pending」（/photo-publish 消费 pending，会重复上线同一张）；② `pm vault push` 的 RENAME 报告说「未被 photos.json 引用」。上游是同一个塌缩：「没配置 = 核对不了」被当成「没引用」。修在源头：`photosJsonRef Nothing` 答 `Left`（「未配置 photos.json → pm config set --photos-json」），两处调用方的 Left 分支本就 fail-closed（记录 → `unknown`、exit 1；RENAME → 按可能被引用只报告），措辞从「读取失败」改为「核对不了」以同时覆盖读错与未配置；配置了而文件不存在仍答「未被引用」。`pm config` 的未设提示改说「RENAME 引用检查与照片记录的发布状态都核对不了」。钉针 `VaultNoteTests` #71（未配置 → 已推送记录 unknown、exit 1；上游直接答核对不了）；上游改回 `Right Nothing` 实跑转红。DESIGN §5 / DESIGN-P8 §21.2 / DESIGN-COMMANDS 同步。影响：从不配置 photos-json 的人跑 `pm vault notes` 会对已推送的记录得 exit 1——这是文档契约本来的样子。
- **#81**（**critical**，横切「安全」，`src/Pm/ServeAi.hs` `runClaude`）：AI 建议拉起 `claude -p` 时 cwd = 源目录（地点）/ 主库（分类）。`-p` 模式跳过工作区信任确认，cwd 里的 `.claude/settings.json`（hooks / env / apiKeyHelper）、`.mcp.json`、CLAUDE.md 被直接加载——一张预埋了 hooks 的存储卡（或别人给的照片文件夹），在整理页点一下「AI 建议地点」（只读级端点，不需 `--writable`）就能以用户身份执行任意命令；`--permission-mode plan` 只限制模型的工具，管不到 harness 的 hooks 与 MCP 进程，文档里「构造上写不了任何东西」的说法因此不成立。**第一方复现**（claude 2.1.280，`ANTHROPIC_BASE_URL` 指向死端口 = 零花费）：在照片目录放 SessionStart / UserPromptSubmit 两个 hook，旧调用形下两个都执行了。修（两层，各自单独都挡得住，逐层实测）：① cwd 改为 pm 自己的固定空目录（系统临时目录下 `pm-claude-cwd`，从不删除——不引入删除原语），照片目录只经 `--add-dir` 放行读；② 加 `--safe-mode`（不加载 hooks / MCP / CLAUDE.md / 技能等任何自定义）、`--setting-sources user`（不读项目与本地设置）、`--strict-mcp-config`。逐层探针：新调用形 → 无 hook 执行；只加旗标（cwd 仍是照片目录）→ 无；只换 cwd → 无。**功能复核**（一次真实调用，16×16 合成纯色图、haiku、$0.19）：`--add-dir` 内 Read 图片免提示、`permission_denials: []`、两轮答对颜色。钉针 `ServeP8Tests` #81：假 claude 记下参数行与工作目录（`PM_FAKE_CLAUDE_LOG`），分类与地点两条路都须 cwd = pm-claude-cwd、照片目录只在 `--add-dir` 后、三个隔离旗标齐全；突变「cwd 改回照片目录」「去掉 --safe-mode」各自实跑转红（首轮突变暴露断言弱点：cmd 写 CRLF，「cwd ≠ 照片目录」比较永不相等而白过——已去 `\r`，同一突变改由这条断言报红）。DESIGN §14 威胁模型行、DESIGN-P8 §22.2、DESIGN-GUI 同步。残余（登记）：用户自己的 `~/.claude/settings.json` 权限规则仍按 `--setting-sources user` 加载（hooks 已被 `--safe-mode` 关掉）；claude 将来若新增 `--safe-mode` 不覆盖的项目级机制，cwd 这一层仍独立挡住照片目录。
- **#16 + #18 同簇「GUI 把『读不出』说成『没有』」**（2026-09-25 审计 low，`gui/ui/app.js` / `gui/ui/archive.js`）：① 状态页与归档页只看 `s.index` 为空就说「主库尚未索引 → pm scan」并提前返回，索引**读不出**（可信闸拒、快照坏、root-id 缺、身份不符：`index:null` + `warnings` 带原因）时真正的原因被丢掉（#16）；② 归档页 `/api/album/candidates` 失败时 `renderConvert([])` 断言「成片 / 相册下没有非 jpg 照片」，上一轮的候选说明、已忽略清单（带能点的「取消忽略」）与告警原样残留（#18）。上游是同一个渲染习惯：空值只分「有 / 没有」两态。修：两页在 `index` 空且 `warnings` 非空时报「主库索引读不出：<原因>」（状态页 bad 横幅）；`renderConvert(null)` = 未知（「候选读不出来，非 jpg 清单未知」），失败分支同时清掉候选说明、已忽略清单与告警。新测试模块 `test/CleanupTests.hs`（本轮清理不归属领域测试文件的钉针都放这里）#16 #18：源码哨兵（两页的「读不出」分支、`renderConvert(null)` 且不再有 `renderConvert([])`、null 分支、清掉已忽略清单）+ `node --check` 两个脚本。本仓不跑浏览器，GUI 行为未实机点验（同 #1 / #2 的口径）。
- **#82**（medium，横切「偏函数与崩溃点」顺带发现，`src/Pm/Convert.hs` `pillowScript`）：`pm convert` 对非 RGB/L 源（CMYK / LAB 的 tif、psd…）朴素 `convert('RGB')`，再把**源**的 ICC 配置原样嵌进输出——RGB 数据挂着 CMYK 配置、颜色也没走色彩管理，pm 报成功。第一方对照（Pillow 12.3，本机 `RSWOP.icm`）：CMYK 青 (100,0,0,0) 旧版出 (0,255,255) 挂 CMYK 配置，新版出 (0,159,215) 挂 sRGB；LAB 源像素不变、配置从 Lab 改 sRGB；RGB+sRGB、无配置 CMYK 两版逐像素相同。修：非 RGB/L 源带 ICC 时 `ImageCms.profileToProfile` 转 sRGB、改嵌 sRGB；末道闸：嵌入配置的颜色空间必须与输出一致（RGB ↔ RGB、L ↔ GRAY），对不上即非零退出（fail-closed，不出错色的 jpg）；LA 合成为 L（灰度配置因此仍成立），调色板 → RGB、1 位 → L 改为显式分支。钉针 `ConvertTests` #82（真 Pillow，CI 同样装 pillow）：LAB 源 + Pillow 自造 LAB 配置 → 输出 RGB、嵌 RGB 配置；LA → L 且像素 ≈ 177；CMYK 数据挂 sRGB 配置 → 转换失败、不出计划；RGB 数据挂 LAB 配置 → 末道闸拒绝（「does not match」）。突变：去掉色彩管理分支 → 红；去掉末道闸 → 红。影响：已派生的件按幂等复用、不会自动重转——以前转过 CMYK / LAB 源的，用 `pm convert --redo` 重派生（发布说明写明）。
- **#28 + #73 同簇「§5.1『2 = 错误』没落到两处」**（#28 2026-09-25 审计 low `src/Pm/BackupCmd.hs`；#73 横切「CLI 与文档漂移」`app/Main.hs`）：① `pm backup` 找不到备份盘（未登记 / 未挂载 / 多卷身份冲突）退 1——§5.1 的 1 是「有差异 / 计划待处理」，脚本分不清「盘没插、什么也没跑」与「计划已存待执行」；同一个 `discoverBackupRoot` 的 Left 在 undo / doctor / trash --backup 本就退 2（F031）。② 命令行用法错误（缺参数、未知选项、多余位置参数）走 optparse-applicative 的缺省 `failureCode` 1；#61 的出口边界只包 `run cmd`，管不到解析阶段。修：前者改 2；`parserInfo` 加 `failureCode 2`（`--help` / `--version` 走 ExitSuccess，不受影响）。钉针 `CleanupTests` #28 #73（未登记备份盘 → exit 2 且说「未登记」；`parserInfo` 源码哨兵——它在 app/ 里、测试链不进来）；真 `pm.exe` 实跑：`pm --bogus-flag` → 2、`pm scan extra` → 2、`pm --version` → 0。突变「改回 1」实跑转红。DESIGN §5.1 同步。
- **#41 + #66 同簇「用户手编文本开头的 UTF-8 BOM」**（#41 2026-09-25 审计 low `src/Pm/GitGuard.hs`；#66 横切「编码与时间」`src/Pm/Config.hs`）：PowerShell 5.1 的 `Set-Content -Encoding UTF8`、记事本「UTF-8 with BOM」存出的文件以 U+FEFF 开头。① `config.toml` 带 BOM → toml-reader 在 1:1 拒收，**每条** pm 命令（含 GUI 的 serve）起不来，报一句不含文件名的解析错误，唯一的工具内恢复 `pm init --force` 还会丢掉备份登记与推送目标（#66）；② `.gitignore` 带 BOM → 首行 `.pm/` 被读成「U+FEFF.pm/」，I11 报「缺 `.pm/` 行」，而 git 自己跳过开头的 BOM（`dir.c skip_utf8_bom`）认这一行（#41，fail-closed 方向但诊断是假的）。上游：pm 解析用户手编文本时没有统一的「去开头 BOM」一步。修：`Pm.Types.stripBom`（只去开头一个，同 git 口径；中间的 U+FEFF 保留），两处都先过它；配置解析错误改为带文件路径。钉针 `CleanupTests` #41 #66（带 BOM 的 config.toml 照常载入；`.gitignore` = BOM + `.pm/\r\n` → I11 放行；BOM 在第二行 → 仍拒）；两处调用点各自撤掉 `stripBom` 实跑转红。DESIGN §2 I11 行同步。
- **#14 + #27 + #65 + #74 + #84 同簇「用户输入的值域只在一个入口验」**（#14 / #27 为 2026-09-25 审计 low；#65 / #74 / #84 为横切 low）。① 并发数 1..64、掉线等待 0..86400 此前只在 `checkPatch`（`pm config set` / `POST /api/config`）验：`pm init --workers 0` 原样写进配置，`pm scan --workers 100000` / `pm backup --workers 100000` 直接开十万个 hash 线程，手编进 `config.toml` 的越界值被静默使用（#14）。② 备份 `subpath` 从不验：发现时它被 `</>` 拼到每个卷根上，而 `</>` 遇到带盘符或前导分隔符的右操作数原样返回它——手编成 `E:\Photography` 让每个卷都命中同一路径，认对的盘被报成「多卷身份冲突（整盘克隆）」（#27）。③ `--from/--to` 用 time 的 `Read Day`，它接受任意位数年份：顺手敲的 `26-09-01`（本项目事件名就是 YY-MM）被读成公元 26 年，区间静默落空或放宽（#65）。④ 空串路径参数被 `makeAbsolute` 答成当前目录：`pm init --main ""` 把 cwd 初始化成主库、`pm backup init ""` 在 cwd 建备份身份、`pm sort ""` 盘点 cwd——存在性检查挡不住，cwd 总是存在（#84）。⑤ `pm init --workers` 的帮助写「默认=物理核数」，实际是 `getNumProcessors` 的逻辑处理器数（本机 8 核 16 线程，差一倍；#74）。上游：值域与形状没有唯一定义，各入口自己判或不判。修：`Pm.Types` 立 `workersOk` / `driveWaitOk` / `subpathOk` / `blankPathArg` 四个谓词作唯一定义；命令行四个 `--workers` 共用 `Pm.Cli.parseWorkers`（越界在解析处拒，退 2），日期走 `Pm.Cli.parseYmd`（只收十位 `YYYY-MM-DD`）；`checkConfig`（四条写路径的汇点）接管值域与 subpath 形状，`checkPatch` 里的两条旧判定撤掉；消费侧——`discoverBackupRoots` 对手编 subpath 说清原因、`pm scan` 拒用越界的配置并发数（不静默夹紧，命令行给了合法 `--workers` 时不看配置值）、`pm config` 对手编越界值与非相对 subpath 标 ⚠；`pm init` / `pm backup init` / `pm sort` 入口先拒空白路径，init 成功行点名解析出的主库绝对路径；四处「核数」措辞统一为「逻辑处理器数」。钉针 `CleanupTests` 两例：#14 #27（`checkConfig` 拒 0 / 65 / -1；`runInit --workers 0` 退 2 且不写配置；subpath 收 `""` / `Photography` / `a\b` / `a\\b` / 结尾分隔符，拒 `\Photography` / `/x` / UNC / `E:\Photography` / `E:x` / `.` / `..` / `a\..\b`；发现侧对 `E:\Photography` 答 Left；`pm scan` 遇配置 100000 退 2、给 `--workers 2` 时照常扫；`pm config` 三处 ⚠）与 #65 #84（`parseYmd` / `parseWorkers` 边界；init / backup init / sort 的空路径；仓库根不出现 `.pm`）。突变 11 个全部实跑转红（`checkConfig` 不查并发数、`parseYmd` 放宽、`subpathOk` 分别去掉冒号 / 前导分隔符 / `.`·`..` 三条、`blankPathArg` 恒假、发现侧不查、`parseWorkers` 不查值域、`runScanCmd` 不拒、`pm config` 不标、sort 空源当目录）；首轮「去掉前导分隔符检查」**没**转红——当时另有一条「无空分量」把它整个包住（重复 / 结尾分隔符其实无害却被拒），收窄为只拦 `.`/`..` 后三条各自可证。DESIGN §5 sort 行、DESIGN-COMMANDS config set 行 / sort 段 / 备份并行度段同步。
- **#52 + #55 + #56 + #57 + #80 同簇「vault push 的出口没有共用同一套判定」**（全为 2026-09-25 审计 low，#80 为横切 low）。① 无项分支的「N 个 NEW 待分类」数的是 `newActive`（含 .png），照着推被 `checkAssignments` 拒（#55，门禁二轮 N4 在 `renderHuman` 修过、这里漏了）；② DRIFT 项不过 `pushableExt`：vault 里已有 `<类目>\x.png` 且与相册不同时，`pm vault push` 与空指派的 `POST /api/vault/push-plan` 出一份 `--keep src` 后经 push 写路径把 .png 拷进 vault 的计划，`pm vault status` 同时把它标成 UNPUSHABLE「写路径拒收」和 DRIFT「→ 生成裁决计划」（#57）；③ `pm vault push --apply` 直跑不走 `afterApply`，vault 缓存停在推之前，`pm status` 继续把刚推的照片算 NEW（#56）；④ 纯裁决计划的响应照给「无法安全生成命令 / 请手动 git add」（#52）；⑤ 缺 vault 的提示指到 `pm init --main … --vault …`——此时配置一定已存在，init 拒「配置已存在」，`--force` 又丢掉 photos-json / workers（#80）。上游：写路径闸与收尾动作各出口各写一份。修：`Pm.Vault.driftPushable`（与 `newAssignable` 同一道闸）进计划构造、CLI 提示、GUI 的 DRIFT 计数与空指派放行；非 jpg 的 DRIFT 在 CLI 打一行「只报告 → pm convert」、status 的 DRIFT 行按它给下一步；直跑执行后重算即重写缓存（`Pm.Apply` 反向依赖本模块，只能镜像）；`gitSteps` 在无类目时为空；两处缺 vault 提示改为 `pm config set --vault`。钉针 `VaultTests` #55 #56 #57 #80（只有 .png 的 NEW 不出「待分类」；png DRIFT 只报告、未生成计划、vault 字节不变、`vaultPushItems r [] = []`；推 a.jpg 后缓存 NEW 从 2 变 1；两处提示），`ServeWriteTests` #57（png-only DRIFT：分类页计数 0、空指派 400）与既有 P4-6 纯裁决用例加断言 `gitSteps = []`（#52）。突变 9 个全部实跑转红；其中服务端三条首轮用带空格的筛选词跑，stack 把 `--ta` 按空格拆开、测试根本没起，旧的突变脚本把非零退出一律当红——改为只认「N out of M tests failed」，编译 / 参数失败单列，三条重跑后确为真红。DESIGN-COMMANDS §10.2 同步。
- **#47 + #48 同簇「计划列表的读出各面各写一份」**（2026-09-25 审计 low，`src/Pm/Serve.hs`）。① `GET /api/plans` 自己读两根：任一根 journal 有告警就两根都不判失效（`null mwarns && null vwarns`），而 CLI `pm plan list` 与 prune 逐根判——vault 的 journal 有告警时，主库的一份失效草稿 CLI 说「已失效」、GUI 说「未执行」带执行按钮，GUI 自己的「清理已执行/失效」又把它删了（#48）；② serve 执行 `POST /api/apply` 时整场握着 journal 写句柄，同进程并发的计划列表 / 清理撞上 GHC 的进程内单写者锁（ResourceBusy），被 `readPmState` 报成「无法可信读取——人工核查」，全部计划显示未执行（#47，暂态，自愈）。上游：列表的逐根读出没有唯一实现；`readPmState` 把「本进程占用」与「不可信」混成一类。修：`Pm.Plan.rootPlans`（一个根：计划、装不出来的、该根 journal 折叠、该根告警）与 `planRows`（两根的行 + 逐根失效判定），CLI 列表、`GET /api/plans`、prune 三处共用；`readPmState` 对 `isAlreadyInUseError` 单列措辞「正被本进程的另一操作占用（计划执行中？）——稍后重试」（仍 Left，fail-closed 不变）。钉针 `PlanExecTests` #47 #48（主库一份源已不在的草稿 + vault journal 一行坏 JSON：`planRows` 与 `GET /api/plans` 都判主库草稿失效；`withJournal` 握着写句柄时 `readJournal` 的告警说「稍后重试」、不说「人工核查」）。突变 3 个全部实跑转红（serve 回到全局告警闸、`planRows` 不判失效、占用分支去掉）。DESIGN-COMMANDS 1.1.3 `pm plan list` 行同步。
- **#44「删计划时真失败被『不存在』盖住」**（2026-09-25 审计 low，`src/Pm/Plan.hs`）：`deletePlanAnyRoot` 逐根试删，每个根的 Left 都丢掉、只留最后一个根的原因——配置了 vault 时，主库那份删不掉（句柄删不成、.pm 不可信、路径解析失败）被报成「计划不存在: <vault>\.pm\plans\<id>.json」，`pm plan rm` 与 `POST /api/plan/delete`（404）都藏起了真原因；`deletePlan` 判存在用 `doesFileExist`，查不出也吞成「不存在」。上游：删除结果只有「成 / 败（一句话）」两态，调用方分不出「没有」与「删不成」。修：`Pm.Plan.PlanDelErr = PlanNotFound | PlanNotDeleted`，`deletePlanAt` 按它答（存在性改三态 `probeName`：只有名字不存在算没有，查不出算删不成），`deletePlan` 保留旧签名给 prune 与既有用例；`deletePlanAnyRoot` 删成即止，各根都没删成时有真失败报真失败（带根名）、全是没有才报不存在；API 按类给 404 / 409 / 400。钉针 `PlanExecTests` #44（主库计划文件挂「全拒」ACL、vault 已配置：答 PlanNotDeleted 且带「主库：」、不含「计划不存在」，文件仍在；两根都没有 → PlanNotFound；API 409 / 404 / 400 / 解除后 200 真删）。突变 3 个全部实跑转红（真失败当没有、API 删不成仍 404、坏 id 不给 400）。存在性探针换三态这一处没有独立钉针：「全拒」ACL 下 GetFileAttributes 仍成功（目录元数据兜底），造不出确定性的 ProbeUnknown，它由 `probeName` 自己的用例覆盖。DESIGN-COMMANDS `pm plan rm` 行、DESIGN-GUI 计划删除段同步。
- **#51「忽略候选的没写成一律答 400」**（2026-09-25 审计 low，`src/Pm/ServeAlbum.hs`）：`runAlbumIgnoreTo` 把一切没写成（解析错、不是当前候选、主库身份不符、尚未索引、清单读不出、写不进、主库 `.pm/lock` 被占）都折成退出码 2，`POST /api/album/ignore` 于是一律 400「忽略清单未写入」——GUI 在 `POST /api/apply` 执行期间点「忽略」（执行握着主库锁，`seApplyLock` 与 `seVaultLock` 不互锁）得到 400，而 hold / notes 两个记录端点（`recordPost`）对同一暂态答 409。上游：事务结局只有「成 / 2」两态。修：`Pm.Album.IgnoreFail`（对象不合法 / 库状态不符 / 锁被占 / 写不进）作为 `runAlbumIgnoreTo` 的 Left，CLI 包装一律折成 2（文档契约不变），API 按类 400 / 404 / 409 / 403，与 `withVaultTxn` / `recordPost` 同口径。钉针 `ServeP8Tests` #51（尚未索引 404；另一个 pm 握着主库锁 409、清单不落盘；锁放开后 200），`AlbumTests` 成功路径断言改为 `Right ()`。突变 3 个全部实跑转红（锁被占折回请求不合法、API 锁忙映射回 400、尚未索引当请求不合法）。DESIGN-GUI 写端点段、DESIGN-COMMANDS `pm album ignore` 行同步。
- **#49 + #50「AI 建议把模型的输入与输出按错口径换算」**（2026-09-25 审计 low，`src/Pm/ServeAi.hs`）。① 分类请求的平铺相册名按文件名扫整个相册子树建表（`takeFileName` + `Map.fromList`，后者留键序最后一条）：`相册\old\IMG_0001.jpg` 排在 `相册\IMG_0001.jpg` 之后、顶掉平铺那张——交给 `claude -p` 的是子目录里的图，返回的建议却预填到（存下来也记到）平铺那张上；只在子目录里有的名字也被当成相册照片（#49）。② 回答里的坐标用 Haskell `show` 规范化，|值| < 0.1 时出指数形式（`0.0523` → `5.23e-2`），过得了 `noteFieldErrors`，原样存进 `.pm/vault-notes.json` 并由 `pm vault notes --json` 导出，与 DESIGN-P8 §21.1 / README / 提示词说的「十进制」不符（#50）。修：`albumFlatEntries`（按确切键 `相册\<名>` 查、只收平铺名与 KindPhoto，vault / GUI 的相册语义本就只看平铺层）与 `coordsText`（`showFFloat Nothing`），两者导出供用例直打。钉针 `ServeP8Tests` #49 #50（索引里同时有 `相册\IMG_0001.jpg`、`相册\old\IMG_0001.jpg`、`相册\old\only-sub.jpg`：查到的是平铺那张、只在子目录的不算；`(0.0523, -0.0015)` → `0.0523, -0.0015`，`(47.5, 13.6)` 不变）。突变 2 个实跑转红，且各自复现原症状（取到 `相册\old\IMG_0001.jpg`；`5.23e-2, -1.5e-3`）。DESIGN-P8 §22.3 同步。
- **#54「status 的暂存事件与 import 各用一套布局」**（2026-09-25 审计 low，`src/Pm/Status.hs`）：`stagingEventOf` 按固定位置取 `To-Be-Sync'd\<Raw|Processed>\` 之后的第一个分量、要求至少四段，而 `Pm.Import.route` 接受 `Raw\<事件>` 与 `Raw\<年>\<事件>` 两种布局（DESIGN-COMMANDS 有记、PlannerTests 有钉）——年份布局下同一年的事件全并成一个名叫「2026」的伪事件（`pm status`、`/api/status` 的 stagingEvents、GUI 首页与归档页卡片都如此）；直接放在 `Raw\` 下的文件不产生事件，status 不打暂存行、可以退 0，`pm import` 却报「无法识别」退 1。上游：暂存布局的知识在两个模块各写一份。修：`Pm.Import.stagingEventDir` 用 `route` 同一套规则给出盘上事件夹名（`isYearDir` 提到顶层共用）；import 认不出的形状答 `Just Nothing`，status 记作「(无法识别)」照样出暂存行、计入退出码；待修改不计。`Pm.Status.stagingEventOf` 删除。钉针 `CleanupTests` #54（`Raw\2026\26-08-Hangzhou`、`Raw\2026\26-07-Wien`、`Raw\x.ARW`、`待修改\y.jpg`：事件清单 = 「(无法识别)」+ 两个事件，退出码 1）。突变 3 个全部实跑转红（年份布局按第 3 分量取——复现原症状「2026」、认不出的形状不计、待修改也计）。DESIGN-COMMANDS `pm status` 行同步。
- **#69「给人看的用户文本经 `show` 渲染」**（横切「编码与时间」low，`src/Pm/Status.hs` / `src/Pm/VaultHold.hs`）：Haskell 的 `show` 把每个非 ASCII 字符打成十进制转义——`pm status` 的「⚠ 暂存区 1 个事件未归档」用 `show stagingEvents`，`pm sort --place 杭州` 建出的 `26-08-杭州` 显示成 `["26-08-\26477\24030"]`，用户认不出也复制不了（GUI 走 JSON 显示正确，两面不一致）；`validateKeyed` 报手编 / 损坏记录里的非平铺名字同样如此。上游：没有「给人看的引号文本」这一步，各处顺手用 `show`。修：`Pm.Types.showHuman`（加引号、控制符写成转义，可打印的非 ASCII 与反斜杠照原样）；按类扫全 `src/`，替换九处把用户文本经 `show` 放进人读消息的地方——status 暂存清单（ASCII 名字的输出与此前逐字相同，README 示例不变）、`validateKeyed` 的坏名字与坏 sha、忽略清单的坏 sha、`checkPatch` 的 push 目标、Op / 计划状态 / root 角色 / 文件类型四个 JSON 解码失败消息。钉针 `CleanupTests` #69（`showHuman` 三例；`Raw\26-08-杭州` 的 status 渲染含 `["26-08-杭州"]`；非平铺名 `旧/杭州.jpg` 的报错含原文）。突变 3 个全部实跑转红（status 回到 show、校验回到 show、`showHuman` 也转义非 ASCII）；其余六处是同一 helper 的机械替换，未逐处钉针。
- **#68「历史时刻用现在的时区偏移换算」**（横切「编码与时间」low，`src/Pm/Status.hs`）：`renderStatus` 取一次 `getCurrentTimeZone`，套到索引扫描时刻、备份缓存 `bmAt`、vault 缓存 `vmAt` 三个历史时刻上——本机时区有夏令时，跨切换后显示差一小时，近午夜差一天（10-31 00:30 EDT 的备份在 11 月后显示成 10-30 23:30）；GUI 的 `toLocaleString` 按历史偏移，两面对不上。上游：换算用的是「现在」的偏移而不是「那一刻」的。修：`Pm.Status.localStamp`（`getTimeZone t` 取该时刻的偏移），三处都走它；全 `src/` 仅此一处用 `getCurrentTimeZone`，已无残留。钉针 `CleanupTests` #68（2026-01-15 01:00Z 与 2026-07-15 01:00Z 两个时刻各按自己的偏移；源码哨兵：`src/` 与 `app/` 不再出现 `getCurrentTimeZone`）。突变 2 个实跑转红，且复现审计原数字（应为 `2026-01-14 20:00`，旧写法给 `21:00`）；其中一个绕开哨兵关键字、只靠行为断言也转红。说明：CI 的 runner 若在无夏令时的 UTC，行为断言恒真，那里由哨兵兜住。
- **#53「pm 状态目录的设计内不进入被当成未能枚举」**（2026-09-25 审计 low，`src/Pm/SortSource.hs`）：sort 的源恰好是 / 含一个 pm 库根时，`listTreeCov` 对内含 `root-id.json` 的目录按设计不进入，并记一行交代（未枚举覆盖为空）；`hardErrors` 却只豁免链接跳过那一条，于是提议形态对任何含 pm 库根的源都退 1，计划形态把「✓ 没有需要归位的新照片」/ 全部执行完的一跑抬成 1，并归在「reparse point / 路径过长 / 读不到」桶下——与 DESIGN-COMMANDS「只有列不出的子树退 1、设计内跳过仍是 0」和 `listTreeCov` 自己的注释相反。上游：设计内跳过的字面量散在两处，豁免表只认其一。修：`Pm.Scan.pmStateDirSkipNote` 唯一定义（遍历处引用它），`hardErrors` 豁免 `[reparseSkipNote, pmStateDirSkipNote]`；「root-id.json 存在性查不出、按状态目录处理」仍是硬错误。钉针 `SortGuardTests` #53（既有 F054 用例在 junction 之后再放一个 `DCIM\oldlib\.pm\root-id.json`：计划与提议两形态都仍是 0、不打「未能枚举」；纯函数断言 `hardErrors` 对它答空）。突变 2 个全部实跑转红（豁免表漏掉它、遍历处字面量与豁免表漂移）。DESIGN-COMMANDS `pm sort` 行同步。
- **#79「sort 分段命令原样套引号」**（横切「命令文本」low，`src/Pm/Sort.hs`）：`printSegment` 把源路径原样塞进 `"%s"`——`pm sort E:\`（或任何带尾随分隔符的源）印出 `pm sort "E:\" --place …`，cmd 的 argv 规则与 bash 都把 `\"` 读成转义引号，整行粘贴即坏；含 `%`、`"` 等字符的路径同样直通。上游：push / move 命令早已「解析而非过滤」地走 `cmdPath`（盘符绝对路径 + 白名单分量 → 以 `/` 重渲染），sort 的这一处没走同一生成点。修：`Pm.Publish.quotePathArg`（`cmdPath` + `renderCmdPath` + 引号，一处定义），`printSegment` 用它；嵌不进时印 `<源目录>` 占位并另起一行说原因，不印一条会坏的命令。钉针 `SortTests` #79（`E:\` → `"E:/"`、`E:\DCIM\` → `"E:/DCIM"`、`D:\a%b` 拒；带尾随 `\` 的真实源跑一遍提议，输出含 `→ pm sort "`、不含 `\" --place`、不含占位）。突变 3 个全部实跑转红（打印处退回原样套引号、`quotePathArg` 不经渲染、不过白名单）。DESIGN §5 sort 行与 DESIGN-COMMANDS sort 段同步。
- **#20 #23「核验途中盘没回来：整轮结果丢掉；隔离件按 0/N 报」**（2026-09-25 审计 low，`scripts/backup_verify.py` / `scripts/verify_backup_dst.py`）：`Drive.ensure()` 等盘超时直接 `sys.exit(3)`，从 `run()` 中途的掉线处理里调到时，已核出的 sha / size 不符、计数与 `--out` 全部丢掉，只能整盘重读——而掉线次数超限的 STOP 路径是把未读的记进 bad 再正常收尾；之后 `verify_backup_dst.py` 的隔离件存在性检查只用 `os.path.isfile`，盘不在时每个 victim 都「不在」，报成 `trash victims present 0/N`。上游：「盘不在」这个状态没有进结果，内核里一处直接退出、入口里一处当成「文件不在」。修：`ensure(fatal=True)` 只给启动时用（还没有结果可丢），中途改抛 `DriveTimeout`，`run()` 按 STOP 同一收尾（已核出的照留，未读的记「not verified (drive did not return)」，结果带 `gave_up`），`finish()` 照写 `--out` 后退出码 3；隔离件的「不在」与 `run()` 的 missing 同一判据——只在盘在时算，盘不在记「trash victims not verified (drive absent)」。钉针新模块 `test/ScriptTests.hs` #20 #23：真跑 `verify_backup_dst.main()`，驱动脚本在第一个目标读完后整盘改名（= 拔盘不回），断言 `result.json` 的 bad 恰为「a.jpg sha 不符 / b.jpg 没读到 / 隔离件没核」、`gave_up` 为真、退出码 3（修前实跑：GIVE UP 后没有 `--out`）。突变 4 个全部实跑转红（中途仍直接退出、finish 不看 gave_up、超时收尾不记未读、隔离件检查不看盘在）。DESIGN §6.4 末段同步。python 由 `findPython` 找（CI 的测试 job 已装），输出经文件按 UTF-8 宽松解码读回，不受 runner 代码页影响。
- **#22「按计划核验不看条目状态」**（2026-09-25 审计 low，`scripts/verify_backup_dst.py`）：copy 目标与隔离件清单取自计划的**全部**条目，不看持久化的条目状态——`pm resolve <备份计划> --item N` 跳过的条目（`{"s":"skipped"}`，按组扩展）Exec 不执行（ONotExecuted），脚本却照样要求它的目标在盘上、victim 在 `.pm/trash/<id>/` 里，报 `missing` / `size … != …` / `trash victims present N-1/N`、退出 1，像介质损坏，且每次 `--retry` 复发。上游：脚本自己重算「哪些条目该落盘」，没用 Exec 的判据（只执行 pending）。修：先按 `status.s == "pending"` 过滤（待裁决同样不执行，一并排除），copy 目标与隔离件都从它取，并打印跳过了几条。钉针 `ScriptTests` #22（pending / skipped 的 copy 与隔离件各一、外加一条待裁决的 copy：bad 为空、交代「skip 3 items not pending」、隔离件 1/1、退出 0；修前实跑报 skipped.jpg 与 undecided.jpg missing、隔离件 1/2）。突变 3 个全部实跑转红（不过滤、copy 仍取全部、隔离件仍取全部）。DESIGN §6.4 末段同步。
- **#21「leakscan 的用法错与命中同码」**（2026-09-25 审计 low，`scripts/leakscan.py`）：`--extra` 放在最后时 `next(it)` 抛未捕获的 StopIteration（traceback、退出 1——与「命中」同码，脚本化的调用方分不开）；按类扫同一入口还有三处：没给文件答 `patterns=N total hits=0`、退出 0（什么都没扫却报干净）；`--extra ""` 的空模式对任何文件都「命中」；文件不存在同样 traceback 退 1。上游：参数与读文件的失败没有自己的出口码，要么崩成 1、要么落成 0。修：用法错（`--extra` 缺值或空串、没给文件）→ 用法行到 stderr、退出 2；读不到的文件逐个交代、无命中时退出 2（命中 1 优先——确定的泄露比读不到更要紧）；汇总行在有读不到时追加 `unreadable=N`，常态输出逐字不变。钉针 `ScriptTests` #21（八种调用：末尾 `--extra` / 空串 / 没给文件 / 只给 `--extra` / 文件不存在 → 2，干净 → 0，命中 → 1，读不到 + 命中 → 1；修前实跑首例即 1）。突变 5 个全部实跑转红（缺值仍直取、空串照收、没给文件仍答干净、读不到答干净、读不到压过命中）。README / README.zh 发布链说明同步退出码。
- **#83「重扫失败后 AI 建议地点仍按旧概览付费跑」**（横切「部分函数」low，`gui/ui/app.js`）：`sortScan` 请求前只清 DOM（分段卡、概览行），不清模型——`lastSurvey`、`segInputs` 与 AI 按钮状态都留着上一次的；重扫失败（源不存在 409、网络错）后点「AI 建议地点」，每道检查都过：拿**上一个**源付费跑 `claude -p`、往已摘下的输入框里填、报「AI 建议已到：预填 N 段」，页面上却一张卡都没有。修 #1（代际守卫）只管请求在途时的晚到响应，管不到「失败的重扫之后才点」。上游：画面与它所依据的模型分开清。修：`sortScan` 在请求之前与清画面同一处清模型（`lastSurvey = null`、`segInputs.clear()`、AI 按钮关），成功的那次由 `renderSurvey` 重新立起来；`sortAiPlaces` 收尾不再无条件放开按钮，按当前概览定。钉针 `CleanupTests` #83（源码哨兵：清模型出现在 `await req(` 之前；AI 收尾不含 `btn.disabled = false`、按 `lastSurvey` 定）。突变 3 个全部实跑转红（不清模型、收尾无条件放开、清模型挪到请求之后——网络错那条路仍漏）。DESIGN-GUI 整理页条同步。
- **#17 #42「执行被拒说成有未完成项」**（2026-09-25 审计 low，`gui/ui/app.js` / `src/Pm/Ingest.hs`）：内核在任何一项开始之前整批拒绝（锁被占 I10、身份不符、计划校验、I11、`.pm` 可信性、屏障）时，`execPlanRetry` 交回一个 String，`Pm.Cli.executePlanNowWith` 把它折成 `(2, [])`——与「跑了、有未完成项」同为非零码：GUI 计划页（`POST /api/apply` 答 200 + 退出码 2 + 空逐项）说「有未完成/待裁决项，见逐项结果 … 回滚：pm undo」，`pm vault ingest` 的次序闸说「主库那份有未完成项 … pm resolve 处理后重跑」——被拒时既没有逐项结果也没有东西可裁决。同一个 `(2, [])` 还装着第二种状态：执行已开始、续跑的一场被拒（可能已有项落位）。上游：停下的两种状态在产地就被抹成一个字符串，两个消费方各自按退出码猜。修：`Pm.Removable.ExecStop`（`StopRefused` = 本次调用什么都没处理过——没有逐项进度、也没有按 journal 结算的前序落位；`StopAborted` = 执行已开始后停下）从 `execPlanRetry` 一路类型化到 `executePlanNowWith :: … -> IO (Either ExecStop (Int, …))` 与 `PlanRun` 的新构造子 `PrExecStopped`（退出码 2、计划 id 照给）；serve 的 apply 端点把被拒答 **409**（页面现成的「没有执行：」分支，不给 undo），中断答 500 `interrupted`（页面「执行中断（可能已有项落位）」）；ingest 两份计划各按结局说「没有执行（原因见上）」/「执行中断 → pm apply <id> 续跑」；`pm apply` 在停下时不再对空结果跑收尾。GUI 脚本无需改动。钉针：`RemovableTests` #17 #42（锁被占 → StopRefused；第 0 项 I5 冲突、第 1 项写 tmp 时拔盘且盘回来换了身份 → StopAborted、不带「中断前已完成」）、`AuditFixTests` #17（锁被占 → 409 + I10 原因、字节没动）、`IngestTests` #42（真内核锁被占说「没有执行」不提 pm resolve、主库相册没落；桩给中断说「执行中断 → pm apply」、vault 那份不执行）、`SortGuardTests` F052 表加 `PrExecStopped`。突变 6 个全部实跑转红（一律判被拒、一律判中断、只看结算不看逐项进度、serve 把被拒当中断、ingest 退回旧句、`planRunOf` 折回 `(2, [])`）。DESIGN-GUI apply 段、DESIGN-COMMANDS ingest 节同步。
- **#29 #38「自愈报的是诊断不是修复；没修成还续跑；修复动作不进结果」**（2026-09-25 审计 low，`src/Pm/Cli.hs` / `src/Pm/Doctor.hs` / `src/Pm/Removable.hs`）：执行续跑两场之间的自愈（`doctor --repair`）按诊断里 C2 / R2 / Q-DONE-LOST 的 Warn 行合成「补记 Done N 条」——`runDoctorGate` 锁被占（I10）或 root 不可写（I11）时降级成只诊断，那些 Warn 行照样在，于是一条没补也报 N 条；续跑照常进行，落了位而 Done 丢了的 Rename 在下一场被判 CONFLICT「重命名源不存在」（退出 1、索引不回写、Intent 悬着），其实改名已成。另一面，`applyRepairs` 做的每件事（补记 Done、清 pm 自建文件、生成 C5 隔离计划、跳过、删除失败）都是裸 `putStrLn`、不进返回的 findings——`pm ui` 下 serve 的 stdout 是空设备，GUI 发起的执行自愈时生成了隔离计划或删了东西都无迹可查（违背簇 C 的打印口纪律）。上游：修复动作没有自己的结果通道，调用方只能从诊断反推「修了没有」。修：`applyRepairs :: … -> IO [Finding]`，每个动作回一行 `repairRow`（`[REPAIR]`：做成 Info、跳过 Warn、删除失败 Bad），`runDoctor'` 并进 findings（CLI 照旧经 `renderFinding` 打出，退出码不变——被修的行本就是 Warn）；`Pm.Doctor.repairDegraded` 从 findings 取「这一轮没修成」的原因（I10 / I11 行只由降级产出）；`execPlanRetry` 的 heal 改答 `Maybe String`，没修成就停下（`StopAborted`：说原因、不续跑，排除后 `pm doctor --repair` 再重跑同一计划）；`Pm.Cli.healLines` 把实际做了的 `[REPAIR]` 行与 Bad 行转给执行的打印口，什么都没做就一行「无需修复」。`Doctor.hs` 由此触 750 行预算：发现行类型与渲染（`Severity` / `Finding` / `renderFinding` / `repairRow`）字节级拆进新模块 `Pm.Finding`，Doctor 再导出，调用方不变（DESIGN 模块图登记）。钉针：`CleanupTests` #29 #38（C2 洞 + 一个不属于在途 Intent 的孤儿 tmp：`--repair` 的 findings 含「补记 Done」与「清除 pm 自建文件」两条 `[REPAIR]`，stdout 不含「补记 Done」；`healLines` 对 I10 降级转出「未做任何修复」且不提「补记」、REPAIR 行照转、空则「无需修复」；`repairDegraded` 认 I10 与 I11、修成了答 Nothing；源码哨兵：不再有「补记 Done %d 条」、Cli 的 heal 把 `repairDegraded` 交回续跑）、`RemovableTests` #29（Rename 落位后拔盘、heal 答降级 → `StopAborted` 说原因，该项没再执行、文件在新名下）。突变 7 个全部实跑转红（修复不回 findings、仍直接打 stdout、自愈不转 Bad 行、自愈退回合成计数、续跑无视自愈结果、Cli 的 heal 一律答修成、降级判据漏 I11）。DESIGN §6.4 C1 行、DESIGN-COMMANDS 瞬断保护段同步。
- **#24「非 jpg 一律指去 pm convert」**（2026-09-25 审计 low，`src/Pm/Commands.hs` / `src/Pm/Album.hs`）：`pm import --also-album`（及 `POST /api/import/plan` 的 alsoAlbum）对每个进成片的非 jpg 都说「非 jpg 只进成片，不入相册: …（要进相册 → pm convert）」，`pm album add` 对非 jpg 一律「→ pm convert <p>」——`.xmp` / `.acr` 侧车、元数据文件、错放在 Processed 下的 RAW 照着敲，`pm convert` 一律拒收（「不是照片条目」/ RAW / 「不是转换对象」）。上游：两处提示各自假定「非 jpg = 可转换」，没用 convert 自己的准入谓词。修：两处都按 `Pm.VaultCore.convertibleExt`（convert 的准入、归档页「非 jpg」栏的同一谓词）分：收的才指向 `pm convert`，其余说「pm convert 不收这类文件」。钉针 `AlbumTests` #24（暂存 Processed 下 tif / xmp / arw 走 import --also-album 预览：tif 行指 convert、xmp 与 arw 行有交代但不指；成片下 tif / xmp 走 album add：tif 指、xmp 报「不是照片条目」且不指；修前实跑 xmp 行带「要进相册 → pm convert」）。突变 3 个全部实跑转红（import 仍一律指、album add 仍一律指、import 对谁都不指）。
- **#32「convert 成片层撞名说成相册已有」**（2026-09-25 审计 low，`src/Pm/Convert.hs` / `src/Pm/Album.hs`）：`convertPlan` 用 `albumPlanItems` 出成片层计划项，它的同名异容理由写死「相册已有同名但内容不同（I5）」——派生 jpg 撞的是 `成片\<事件>\<stem>.jpg`（`classifyInto` 判的是成片同事件夹），计划里却说相册有那份。上游：计划项生成与「判的是哪一层」脱钩，理由文案跟着函数走而不是跟着层走。修：`Pm.Album.planItemsWith` 把理由交给调用方（`albumPlanItems = planItemsWith conflictWhy` 行为不变），convert 的成片层传「成片同事件夹已有同名但内容不同（I5）→ pm resolve --keep src|dst|both」；相册层与 I7 耦合文案不动。DESIGN-P8 §20 补一句。钉针 `ConvertTests` 端到端 clash 段（成片项理由含「成片同事件夹」且不含「相册已有」、相册项是 I7 耦合；修前实跑成片项理由是「相册已有同名…」）。突变 2 个全部实跑转红（convert 传回相册那句、`planItemsWith` 丢掉调用方的理由）。
- **#25「成片根下的 jpg 被列成候选、给的 rel 敲不通」**（2026-09-25 审计 low，`src/Pm/Album.hs` / `src/Pm/ServeAlbum.hs` / `gui/ui/archive.js`）：直接放在 `成片\` 下（不在事件夹里）的 jpg 被 `pm album candidates` / `GET /api/album/candidates` 列成候选、事件夹名取了文件名，给出的 `rel`（`stray.jpg`）喂回 `pm album add` / `pm album ignore` / 归档页「加入」「忽略」一律被 `parseProcessedRel` 拒（「至少要 <事件夹>/<文件名> 两级」，exit 2 / 400）；事件夹名就叫「成片」的同一类。上游：候选的准入与 add 的准入是两套口径，页面的 `rel` 还是 serve 另拼的。修：候选准入改用 add 的**同一个**解析——`candidateRel`（相对成片层的参数形，准入与 JSON 的 `rel` 共用）过 `parseProcessedRel`，收不了的进 `acUnaddable` 带它的拒绝理由；CLI 摘要加「不能直接加入 N 张」并逐条列理由，JSON 加 `unaddable`，归档页不给卡片、在网格下单列路径并提示先移进事件夹（无候选时不再说「都已在相册里」）。钉针 `AlbumTests` #25（纯：成片根下与「成片\成片\」下的 jpg 不进事件夹、单列且理由与 add 的拒绝一字不差；CLI 实跑：摘要「不能直接加入 1 张」、理由行、不再出 `[stray.jpg]`；归档页读 `c.unaddable`）+ `ServeP8Tests` 候选端点夹具加一张根下 jpg（events 仍 1、unaddable 恰是它）。突变 5 个全部实跑转红（照旧全收、CLI 不列、JSON 丢字段、归档页不读、rel 带成片前缀）。
- **#26「插着的备份盘因身份文件坏了被说成没插」**（2026-09-25 审计 low，`src/Pm/Backup.hs` / `src/Pm/Cli.hs`）：备份盘发现经 `readRootInfo` 读标识，它把「损坏」「不可信」（`.pm` 不是目录 / 是 junction / ACL 挡住）与「缺席」一并塌成 `Nothing`——登记路径上 root-id.json 在但读不出的那块盘与「这个卷上没有」一样算不命中，`pm backup` / `pm clean staging` / `pm apply` / trash 三副本复核都报「备份盘未挂载 … → 插上备份盘后重试」，UUID 绑定报「均不符」。上游：发现侧没走四态（`readRootState`），「查不出」塌成了「不存在」。修：`discoverAmongStates` 按四态读，命中之外交出「标识在但损坏 / 读不出」的候选及原因（`discoverAmong` 签名不变，改为它的投影）；`discoverBackupRoots` 多返回这份清单，`discoverBackupRoot` 零命中且清单非空时点名它们（「找不到可用的备份 root：… 损坏或读不出（…）——不是没插盘」），`bindExecRootWith` 把它们并进 F018 的「身份读不出」列表。探名答不上来的候选（卷没就绪 / 空读卡器槽的 ERROR_NOT_READY）四态也是「读不出」、可信闸把它说成 junction——那说不上「身份坏了」，只在路径本身探得到（普通名 / 链接）时点名。DESIGN §5 命令表 `pm backup` 行 / §5.1 同步。钉针 `CleanupTests` #26（临时目录按真实盘符发现：损坏 → 点名「身份损坏」且不再说「插上备份盘」；`.pm` 是文件 → 「身份读不出」；非法名候选（ERROR_INVALID_NAME，同形注入）→ 不点名；路径不在 → 照旧「未挂载」；`bindExecRootWith` 零候选点名「备份盘 … 身份损坏」；修前实跑是「备份盘未挂载 … → 插上备份盘后重试」）。突变 5 个全部实跑转红（损坏照旧不算、读不出一律不报、读不出一律报、零命中不点名、UUID 绑定不列）。
- **#30「没进过 trash 的照片被标成已移出」**（2026-09-25 审计 low，`src/Pm/Commands.hs` / `docs/DESIGN.md` §6.4）：隔离先预写 manifest 再移动（§6.3 步 1）；崩在移动前（Q2）或移动失败，那条记录留在只追加的 manifest 里，`pm trash list` 把它标「已移出」（代码里的本义是被 purge / 被 undo 移回）——一张从没进过 trash 的照片被说成移出过；DESIGN §6.4 的 Q2 行还写着「复核后清除该 manifest 条目」，没有任何代码这么做。上游：manifest 是预写日志（只追加），「trash 里没有」有三种来历，标签只按其中一种起名。修（按裁定保持 manifest 只追加，不加改写原语）：标签改中性的「不在 trash」，注释写清三种来历；DESIGN §6.4 Q2 行改成实际行为（doctor 报 Q2 Info、重跑原计划即可；预写记录留作历史；移动失败同样留一条），§5 `pm trash list` 行补一句。钉针 `CleanupTests` #30（隔离计划崩在 manifest 之后 → trash list 标「不在 trash」、不含「已移出」、victim 仍在原位；修前实跑是「已移出」）。突变 2 个全部实跑转红（仍标「已移出」、标成「在库」）。另更正上一条 #26 的记述：改的是 DESIGN §5 命令表的 `pm backup` 行，不是 §4。
- **#31「--repair 删掉计划还要用的派生件」**（2026-09-25 审计 low，`src/Pm/Derived.hs` / `src/Pm/Doctor.hs`）：`pm convert --also-album` 对成片源出两项（成片 / 相册）共用一份派生件 `.pm\derived\<源 sha>\<stem>.jpg`。成片那份落位、索引记下它的 sha 后，`scanDerived` 按 sha 判 `DERIVED-STALE`；此时相册项还待裁决（相册同名异容，或文档里「先完成成片再 --unskip」的耦合），任何一次 `pm doctor --repair`（手动，或 `execPlanRetry` 瞬断续跑前的自愈）都把派生件删掉，之后 apply 那一项报「源 stat 失败」。上游：派生件的删除判据只看「内容是否已落位 / 源是否还在库」，不看有没有计划项还以它为源。修：`Pm.Derived.derivedRefs` 收集还没做完的计划项（计划文件里任何状态、journal 里没有它的 Done——`planExecs` 的折叠）以派生件为源的，键是相对 root 的 case-fold 路径（计划的 root 可能按 UUID 重新绑定过）；`scanDerived` 对本该 STALE / ORPHAN 的在删之前再核这道引用，引用了的改 `DerivedKept`（报 Info `DERIVED-PENDING`「计划 <id> 还有没做完的项引用它」、不删）；有计划读不出 = 核不了谁还引用，同样本轮不删（「查不出」不塌成「没人引用」）。DESIGN-P8 §20.2、DESIGN §5 doctor 行与模块图、DESIGN-COMMANDS 同步。钉针 `ConvertTests` #31（成片项执行落位、相册项待裁决、重建索引 → `--repair` 后派生件仍在、`DERIVED-PENDING` 行点名计划；再放一份读不出的计划、相册项已不在 → 仍不删、行说「计划读不全」；删掉坏计划、只剩已完成的成片项引用 → 照常删；修前实跑第一步就删了）。突变 4 个全部实跑转红（已完成的项也算引用、引用了照删、计划读不全当成没人引用、doctor 忽略读不出的计划）。
- **#33「备份盘上的 I7 汇总把主库镜像全算成 inbox 来源」**（2026-09-25 审计 low，`src/Pm/Doctor.hs`）：备份盘上每个相册文件都是 `pm backup` 的 OpCopy 落下的，记录的 src 在主库、也就是备份 root 之外，`pathAtOrUnder` 判「库外」——`i7Findings` 把它们全算成 inbox 来源，`pm doctor --backup` 的汇总报「inbox 来源 N · 未解释 0」，像是主库的 I7 在备份盘上也核过了。上游：「src 在库外 = inbox 来源」只在主库成立；备份盘上库外的来源就是主库本身。修：按 root 的 role 分——备份盘上这一类计为「主库镜像（来源在主库判定）」，主库照旧「inbox 来源」；手拷进备份盘、没有任何记录的相册文件仍逐条 Warn（判据在备份盘上不再空转）。DESIGN-COMMANDS doctor I7 行同步。钉针 `IngestTests` #33（备份 role 的 root：一张有主库来源记录、一张手拷无记录 → 汇总「主库镜像（来源在主库判定）1」、不含「inbox 来源」、「未解释 1」、Warn 恰是手拷那张；修前实跑是「inbox 来源 1」）。突变 2 个全部实跑转红（备份盘上照旧算 inbox、主库上也叫主库镜像——后者由既有的 I7 消费侧端到端用例抓）。
- **#35「在途 Copy 的 dst 被另一份计划正当落位后，doctor 永远报 C5、还给新文件出隔离计划」**（2026-09-25 审计 low，`src/Pm/Doctor.hs`）：崩在 Intent 之后、写 tmp 之前的 Copy，其 dst 后来被另一份计划正当地落成新内容——Exec 对重跑的 I5 冲突 / 源变了 / 源 stat 失败不记 journal，这条 Intent 永远在途；doctor 每轮把它判 C5 Bad（exit 1），`--repair`（含执行续跑前的自愈）生成 `doctor-c5-quarantine` 计划，victim 正是那份正当落位的新文件（还要一次确认的 apply 才会动它）。上游：C5 的判据「dst 在、sha 不符、Intent 无终态」把 pm 自己后来落下的内容也当成外来文件，没问 journal 里是谁落的。修（只读，doctor 侧）：`runDoctor'` 折出「pm 经 Copy 落到某 dst 的内容」（Done ← 它的 Intent；dst 按 `foldPath`、sha 相等），在途 Copy 的 dst 若正是别的 oid 落下的 → `C5-SUPERSEDED` Info「旧 Intent 作废——不隔离」，不进 `--repair` 白名单（它只认 `C5`）。`Doctor.hs` 为此再次触 750 行预算：受信探针（`PmProbe` / `probePmSha` / `PmEntryQ` / `probePmExists` / `existsAny` / `userSideExists`）字节级拆进新模块 `Pm.DoctorProbe`（只有 Doctor 用它；DESIGN 模块图登记，`StateGuardTests` 一处注释改指新家）。DESIGN §6.4 C5 行补一句。钉针 `CleanupTests` #35（A 计划崩在 CpCopyAfterIntent、B 计划把同一 dst（事件夹名大写，钉 case-fold）落成新内容 → doctor 有 `C5-SUPERSEDED` Info、无 C5、exit 0；`--repair` 后 `.pm/plans` 为空、dst 仍是新内容；修前实跑是 `[("C5",Bad)]`）。突变 3 个全部实跑转红（不认 pm 落位的内容、dst 比对不折大小写、作废行仍叫 C5）；既有 C5 用例（外来内容 → C5 Bad + 隔离计划）照旧绿。
- **#40「undo 隔离之后，文件回来了、索引里却没有它」**（2026-09-25 审计 low，`src/Pm/ExecTypes.hs` / `src/Pm/Exec.hs` / `src/Pm/Removable.hs`）：`pm undo` 一次隔离 = `OpRename .pm\trash\<pid>\<victim> → <victim>`；`execRename` 落位后答 `ODone` 不带 stat，`updateCatalog` 的改名臂只把 `old` 前缀下的条目改键——`.pm\trash` 下的条目从不在索引里，隔离落位时删掉的那条于是补不回来，索引静静地少一张回到库里的照片（之后 import / backup / status 的新鲜度闸报「新增 1 → 先 pm scan」，执行时却只打了 DONE）。组内自动复位（`restoredMark`）早就按「复位的 victim 仍在索引里」处理，undo 这条路没跟上。上游：改名的结局形态只表达「改键」，表达不了「从索引外复位进来」。修：`Pm.ExecTypes.restoredStat`——从 trash 复位一个文件后 stat 落位点（普通改名答 Nothing）；内核 `execRename'` 与续跑按 journal 结算（`Pm.Removable.byJournal`）共用它，两处结局同形；`updateCatalog` 对「从 trash 复位 + 带 stat」按计划时的 sha 与落位 stat 插回条目（与 Copy 臂共用同一个条目形态 `landed`）。DESIGN §5 `pm undo` 行、Removable 头注同步。钉针：`CleanupTests` #40（走 CLI 执行口：索引 → 隔离 → 条目消失 → undo → 文件回来、条目 `(sha, 4)` 回来；修前实跑是 Nothing）、`RemovableTests` #40（复位落位后、写 Done 前拔盘 → 自愈按 R2 补 Done → 按 journal 结算的结局经 `updateCatalog` 得到同一条目；修前实跑 Nothing）。突变 4 个全部实跑转红（内核不带 stat、回写不补、续跑结算不带 stat、`restoredStat` 不认 trash 复位）。
- **#45「过了长路径闸的照片隔离不了」**（2026-09-25 审计 low，`src/Pm/Plan.hs` / `src/Pm/Exec.hs`）：scan 的长路径闸（完整路径 ≥ 240 字符即报错）只看源路径；隔离的 trash 目标（`.pm\trash\<22 位计划 id>\<victim>`，+34 字符）与 Copy 的 tmp 名（`.pm\tmp\<id>\<序号>-<文件名>`）更长，pm 的 Win32 改名 / 建文件调用又不认长路径——226–239 字符的源过得了闸，却隔离不了，每次重跑都 `OFailed`，错误还说成「183=目标已存在」。修前实跑：235 字符的 victim → `隔离移动失败 … rename 失败（Win32 错误码 206，183=目标已存在）`。上游：「≥240 即计划期报错」（DESIGN P0 落锤）只落在了 scan 一处，计划要用到的派生路径没人量。修：`validatePlan`（内核执行前、锁内复核、`loadPlan`、undo 生成共用的形状闸）对每个条目要用到的路径——落位目标、Copy 的 tmp、隔离的 trash 目标——同守 `maxPathLen`，超了整份计划拒绝、一个字节不动，并说清是哪条路径、多长、怎么办（挪到更短的路径下、pm scan 后重新生成）；派生公式用内核同一份：`tmpDirFor` / `tmpNameFor` 从 `Pm.Exec` 字节级挪进 `Pm.Plan`（Exec 照旧再导出，Doctor 的冗余 import 随之收掉），trash 目标用 `Pm.Trash.quarTrashRel`。没选「把 `maxPathLen` 降到 223」：那会让 223–239 字符、从不被隔离的照片整批进不了索引。DESIGN P0 落锤段与风险表同步；DocDrift 的 `OpQuarantine` 引用普查加 `Plan.hs`（只匹配、量 trash 目标，不是新产地——I2 行的产地清单不变）。钉针 `CleanupTests` #45（源路径离上限差 5 个字符：隔离计划 → `validatePlan` 与 `execPlan` 都以「路径过长」拒绝、victim 字节不动；同长的 Copy → 以 tmp 名过长拒绝）。突变 3 个全部实跑转红（不查长度、隔离只看源、Copy 不看 tmp 名）。
- **#46「hash 时读不出的文件从快照里消失」**（2026-09-25 审计 low，`src/Pm/Scan.hs`）：`scanRoot` 把「查不出」按上次快照值承载——未枚举子树（F040）、stat 读不出与读前闸拦下的（审计 #8）——唯独 hash 那一步：枚举到了、stat 也成、读内容时抛（被占的共享冲突、介质读错）的文件，本轮什么也没交出，旧条目随快照无条件落盘而消失（再读得出时 pm status 报成「新增」；doctor --deep / dedupe / versions 看不见它；三次失败扫描后完整快照被轮转顶掉）。上游：同一条「查不出 ≠ 不存在」纪律只落在了前两道读口，第三道读口的异常被 `show` 成字符串、没法再分「不在」与「读不出」。修：hash 的异常原样留下（不先 `show`），读的时候文件已不在（`isDoesNotExistError`）的才算消失，其余并进 `unchecked`，旧条目按「查不出」保留并计入 `srCarried`（`pm scan` 末尾的 ⚠ 行随之点到它）；错误桶照旧带路径。DESIGN §5 `pm scan` 行同步。钉针 `ScanGuardTests` #46（索引后改内容、本进程以写方式开着它——GHC 的读写锁让 hash 的只读打开抛 resource busy，stat 不开文件照常成 → 错误桶恰是它、条目与上次一字不差、`srCarried` 1；修前实跑条目是 Nothing）。突变 2 个全部实跑转红（hash 出错不算查不出、不入错误桶）；「读的时候文件已不在」那一支与 stat 那条同形、无注入形态（要在 stat 与 hash 之间删文件），未单独注入。
- **#15「打包版 pm-ui 起不来时一声不响就没了」**（2026-09-25 审计 low，`gui/src-tauri/src/lib.rs`）：打包版是 `windows_subsystem = "windows"`，开始菜单 / 双击启动没有控制台；`run()` 在 serve 没报端口时只 `eprintln!` 就 `exit(2)`，窗口建不起来时 `.expect` 崩溃退出——两条都只往不存在的 stderr 写，用户什么也看不见（后者退出码还是 panic 的 101，`pm ui` 原样转交，出了 0/1/2 约定）。上游：GUI 壳在窗口出现之前唯一的出错通道是 stderr。修：`run()` 的致命出口收成一个 `fatal`（`-> !`）：stderr 一行（终端里 `pm ui` 拉起时照旧可见）+ user32 `MessageBoxW` 系统消息框，再按 2 退出；serve 起不来时它把原因打在 stdout 第一行（`withCfg` 的配置缺失、绑不上端口），`spawn_serve` 的「不是 JSON」错误原话带着这一行，所以弹框里就是 pm 自己的那句话。DESIGN-GUI P4-3 进程生命周期条同步。钉针 `CleanupTests` #15（本仓测试不建 Tauri → 源码哨兵：`fatal` 在 exit 之前弹框、`run()` 里不留 `.expect(` / `.unwrap()` / 裸 `process::exit`、链 user32；修前实跑红）。突变 5 个全部实跑转红（fatal 不弹框、弹框挪到 exit 之后、窗口建不起来退回 expect、serve 起不来退回 eprintln + 裸 exit、不链 user32）。本机另验：`cargo check --release --target x86_64-pc-windows-msvc` 零警告；把 `fatal` + `show_error` 原样抠出单独编译实跑——线程里调 `fatal`，主线程按标题找到对话框、`GetDlgItemTextW(0xFFFF)` 读回的正文与输入（含中文）一字不差、`WM_CLOSE` 关掉后进程退出码 2、stderr 恰为那一行。整包 pm-ui 的链接由 CI 的 tauri build 验（推 main / ci-* 都跑）；装好的安装版上实际起不来的那一幕没有复现，只验了抠出的这两个函数。
