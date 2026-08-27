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
