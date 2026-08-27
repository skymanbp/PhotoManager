# pm 评审记录·卷一 B（P4 GUI + 用户决策记录，冻结史料）

> 2026-08-26 自 [`REVIEW-LOG-1.md`](REVIEW-LOG-1.md) 拆出（39 轮 #6：750 行
> 预算对冻结档案同样生效）。逐字搬移，不再追加。现行卷见
> [`REVIEW-LOG.md`](REVIEW-LOG.md)。

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
- **P4-9（pm 0.4.7，220/220，GHC 警告 0）——`pm versions` 的「设计内冗余」判据
  补全（用户实测更正，非评审所报）**：使用者指出 Raw 事件夹里出现 JPG 不必然
  是成片误放——**原片本来就是 JPG** 的情形有三种：相机直出 JPG、手机拍的、
  RAW 遗失后用能找到的 JPG 顶替。据此复查 `23-04-EU-Raw`：整树 114 jpg + 3 acr
  + 1 zip、**RAW 文件 0 个**，EXIF 机型 ILCE-7RM2/7RM3、尺寸 7952×5304（A7R
  II/III 全分辨率，不是缩过的导出件），根下还有 `20230409_152721.JPG` 这种手机
  命名——该事件的原始档确实就是 JPG。按原判定隔离它们**等于删掉该事件仅存的
  原始档**，裁定作废。
  根因是 `designedPair` 把"设计内冗余"只定义成「成片↔相册且同名」，漏掉归档
  三层拓扑里另外两种必然的同字节关系，属**一类**缺陷而非个案，一次改全：
  ①同名（原判据）；②`成片↔相册` 异名但成片那个名字在相册已被别的文件占住
  （平铺避让，`_DSC9275`≡`_DSC9274` 那例就是——此前被当成真重复）；
  ③`Raw↔成片` 同名且该 Raw 事件夹无同 stem 原始档。stem 比对走
  `normalizeStem`（否则 `_DSC2227~2.JPG` 会从 `_DSC2227.ARW` 底下溜过去）；
  同层两份一律不是设计内。原始档扩展名清单按本库实测定（Raw 层 arw 3794 ·
  dng 71），psd/psb/tif 是编辑格式不计入。
  实测收敛：真实库 15 组 → **8 组**，剩下的正是 7 组跨事件夹连号 ARW 与 1 组
  根↔子目录重复，6 组 A 类 + 1 组 D 类误报全部消失；版本组仍 112 未受影响。
  三道判据各自突变转红且只红对应那一例：拆判据③ / 拆判据② → 新用例红，
  拆「同层至多一份」→ 既有 `caseVersions` 红。
  **教训**：把"目录名"当成内容契约（Raw 夹里就该只有 RAW）是想当然；真实照片
  库里同一层会合法地混着不同来源的原始档，判据必须问**内容与上下文**
  （有没有对应的 RAW），不能问名字。
- **P3b-2 逐项实测（2026-08-23，42 事件夹；2026-08-25 从 DESIGN §8 移入——
  那是实测记录不是设计）**：31 合规、6 项入计划（2 裸名补后缀 + 4 个 Scheme B
  唯一还原）、3 项拒猜（Summer/Autumn-Providence 同抢 `25-11-Providence-Raw`
  的同批撞名；Summer-Atlanta 还原月撞已存目录——「同年同地点唯一」还原规则的
  局限由盘面存在性防线兜底）、2 个 `&` 双月名（`23-04&05-Egham-Raw`）报
  unrecognized 交用户。别名表延后：需要它的中文事件在 Raw 侧已是 Scheme A，
  无改名需求。
## 用户决策记录（2026-08-22 AskUserQuestion 收口；2026-08-25 从 DESIGN §15 移入）

原章节标题即写明"已全部落进正文"——它是**记录**不是设计，与 §16 当年被拆出去
同一先例。逐条：

1. **计划批准**：v0.2 批准，开工 P0（逐阶段 git commit + 真实库只读验证；
   写盘功能先 fixture + 小事件试点）
2. **GUI 形态**：允许 C#/Java 编写 → 独立桌面程序 + `pm serve` JSON API
   （**2026-08-24 改判**：GUI 改 Rust + Tauri v2 + 纯静态 HTML，内核保持
   Haskell；边界不变）
3. **Raw canonical 命名**：Scheme A `YY-MM-地点-Raw`
4. **`sync_photos.py`**：退役由 pm 接管（P3 末次互校 → P5 落实）

另（2026-08-22 用户指示）：部分任务经中转站 API 委派 codex `gpt-5.6-sol`
执行以控制 token 消耗；安全内核与协议测试仍由主线编写与审查，codex 用于
样板/fixture/GUI 初稿/阶段末独立 review。
- **P5-A（pm 0.4.7，228/228，GHC 警告 0）——`pm sort`**：新照片从相机卡到事件夹
  这一段第一次有工具。两条设计取舍值得记：①**去重的裁决与分类整理的裁决不是
  一回事**——前者是"这一项做不做"，落在 pm 已有的 `StNeedsDecision` /
  `pm resolve`（计划形成**后**的冲突裁决）里，零新机制；后者的地点是计划形成
  **前**就必须有的输入，承载不了，于是**没有为它发明待裁决文件格式**，而是让
  pm 只做能做的（读时间、分段、算年月、查重名、查已归档），把地点留成命令行
  参数——可重跑、不怕中断，且 GUI 与将来的 AI 都只是替用户填这一格，三阶段
  共用同一条计划路径。②EXIF 自己写不引依赖：这条路径决定照片被移到哪，而本
  项目碰字节的代码全是第一方且配突变用例；解析失败的后果又恰好安全（Nothing
  → 「无法判定」交人）。
  **真实数据验证**：四张 ARW/JPG 的拍摄时间与 Windows「拍摄日期」逐条吻合
  （ARW 的 TIFF 容器与 JPEG 的 APP1 两条路径都覆盖）；真实暂存区 187 张全部
  可定时、切出 7 段，每段提议复用的已有事件与使用者实际的事件夹一一对上。
  六道闸各自突变转红：`sliceAt` 上界 / 日期有效性 / 分段阈值闭合 / 同名冲突
  整批拒绝 / 地点非法字符 / 事件名过 `canonRawEvent`。
  **突变暴露的覆盖缺口（值得记）**：拆掉 `sliceAt` 的上界检查后**一开始没有
  任何用例转红**。根因是 ByteString 的 `take`/`drop` 是全函数、越界只静默截短
  不抛错，那条"截断"用例走的是"截短→下游解析失败→Nothing"，两边行为相同；
  上界检查真正承重的地方在 `u16`/`u32` 随后对切片做 `BS.index`——短一个字节
  就抛异常。补了一条把 IFD0 偏移指到"尾端前一字节"的用例才钉住。教训：
  **突变没转红时，先怀疑用例没到达那条路径，而不是先怀疑那道闸多余**。
  另修两处自查发现：`Pm.Sort` 模块注释原写"DESIGN §13"是假交叉引用（§13 是
  测试与验收），已改 §7；`caseSegment` 的期望值是我心算错（b→c 相隔 123h >
  72h 该切开），代码对、断言错，已修正并把算术写进注释让用例自证。

### P5-A 对抗审查（2026-08-25，4 视角 + 逐条独立反驳）——228→237 例，10 条真缺陷按类修

上面那段"六道闸各自突变转红"证明的是**我写的那些闸有效**，证明不了**我没漏
掉该有的闸**——这正是对抗审查存在的意义。四个视角各自找、每条再交一个独立
反驳者：22 条候选，11 条确认，减去 1 条我自己造成的假阳性（见下），**10 条真
缺陷**。按根因归六类一次改全，不逐条打补丁：

| 类 | 根因 | 处置 |
|---|---|---|
| A | `Pm.Exif` 承诺 fail-closed，四处不兑现 | 六处一次改全，见下 |
| B | `Pm.Sort` 没有复用 import 已确立的目标纪律 | 判定改按**目标位置**；共用 `withFreshStagingCatalog` |
| C | 侧车（`.xmp`/`.acr`）从不跟随 | `listSource` 分两摞、`pickFiles` 带上并参与撞名检查 |
| D | 测试覆盖：大端零覆盖、JPEG 段链递归从未执行 | 夹具端序参数化 + 段链/子 IFD 用例 |
| E | 源读取无稳健性：无 `try`、无易变守卫 | `snapshotSrc` 前后双 stat + 逐文件 `try`，失败整批拒绝 |
| F | 读不到时间的文件只在提议里列、出计划时不列 | `reportUndated` 两种形态共用 |

**A 类里最重的一条不是"读不到"，是"返回自信的错值"**：子 IFD 走不通时**无
条件**回退到 IFD0 的 `DateTime`(0x0132)——那是**文件修改时间**。对一个据此
搬动文件的工具，错时间远比 Nothing 危险：它会把照片默默归进错事件，而拷贝
本身完全成功。已删除该回退。同类另五处：`pure` 在 IO 里非严格，返回的 thunk
抓住整个 256 KiB 读缓冲（实测 N=2400 常驻 518 MB；`evaluate` 强制 + `BS.copy`
断开父缓冲共享后平 1.3 MB）；子 IFD 指针放宽到 LONG/IFD 但钉住 `eCount == 1`
（count>1 时值字段指向数组，当偏移用会解析到垃圾）；TIFF 魔数改为在 `endianAt`
里比满 4 字节（此前只比两字节，伪 APP1 能一路走下去）；JPEG 段链处理 `FF`
填充与 RST/TEM 独立标记；`asciiTag` 用 `BS.copy`。

**B 类的错法值得单记**：原实现是「sha 在 catalog 里任何地方出现过 → 算已归档
→ 直接丢掉」。同一张照片合法地属于第二个事件时会被**静默丢弃**，而用户以为
归位了——这是"静默丢文件"的一种，比拒绝严重得多。改成按目标位置四态判定
（详见 [`DESIGN-COMMANDS.md` §7](DESIGN-COMMANDS.md)）。顺带发现 `runImport` /
`runClean` / 新的 sort 各写一遍同一道"可信索引"闸，抽成 `withFreshStagingCatalog`
一份定义；抽的时候才看见 `runClean` 一直在**丢弃**损坏快照的告警（`(mcat, _)`），
而它是最具破坏性的那条命令——统一后一并修好。

**八道新闸各自突变转红（8/8）**：世纪守卫 / `--event` 字符闸 / 撞名键 case-fold /
撞名检查含侧车 / 侧车去重 / 暂存目标异容不静默覆盖 / `holdKin` 组内悬置 /
按目标位置而非"sha 出现过"。

**一条自造的假阳性**：我把突变循环与审查工作流并行跑了，于是某个 agent 读到
的是**被突变过的源**，报出一条不存在的 critical。教训与突变那条并列：
**突变与评审绝不并行**——前者会在磁盘上短暂留下故意错误的代码。

**IO 层再一轮突变（N1–N4b），又挖出一条比本阶段更老的缺口**：纯核心 13 条用例
钉不住接线，于是给 `runSortPlan` 补了三条端到端用例（真目录 → 真 catalog →
计划落盘），再对接线逐道突变。五道里四道当场转红；**N2b 全绿**——拆掉
`withFreshStagingCatalog` 里的**暂存区新鲜度闸**，237 例无一转红。那道闸自 P2
就在 `runImport` 里，**全项目从来没有用例钉过它**，本轮抽取共用定义时才暴露。
它重要在：sort 判"目标位置上有没有东西"依据的是索引，索引落后于盘面时，一个
已经躺在目标位置的文件在索引里不存在，判定就给出"目标为空，照拷"。执行层的
I5 虽然兜得住，但那时用户已经看过一份写着"待拷 N 张"的计划了。补上用例后
N2b 转红。

**易变守卫从"写了但测不了"变成可测**：`snapshotSrc` 的内容是**次序**
（stat → hash → stat），而次序用真实文件只能靠制造竞态，必然片状——`Pm.Scan`
的同一道守卫至今没有用例，正是卡在这里。抽出 `snapshotWith`（注入 stat 与
hash）后，"hash 期间被改动"成了确定性事件，次序本身也能断言；N3（去掉前后
比较）与 N4（把 hash 挪到两次 stat 之外）都转红。**这条方法对 `Pm.Scan` 同样
适用，登记为后续项**——本轮不顺手改它，那是另一个模块的接口变更。

**文档结构收口**：本轮把 DESIGN.md 第二次顶破 750 行预算。§16 早已把"继续削
散文"判为死路，本轮按那个判断执行——逐命令设计 §7–§10 移入
[`DESIGN-COMMANDS.md`](DESIGN-COMMANDS.md)，编号与跨文档引用不变。

### 第 25 轮 codex 门禁（2026-08-25）——NO-GO，6 条**全部核实成立**，241 例

上一节的对抗审查是我自己组织的；这一轮是外部门禁，读的是已提交的 `d66a51c`。
结果 `verdict: NO-GO`，6 条（2 critical / 4 major）。按既定处置原则逐条第一方
核实——既不预设它对，也不预设它错——**6 条全部成立**，按四个根因各改一处。

**一条值得单记的自我纠错**：#1 说"IFD0 偏移声明为 0 的文件仍返回拍摄时间"。
我第一版探针把伪造的 `0x8769` 条目放在偏移 8，得到 `Nothing`，差点据此判它证伪。
重看布局才发现是**我构造错了**：偏移为 0 时条目数从偏移 0 读起（那两个字节正是
魔数 `II` = 18761），条目 0 占 2..13，伪造项必须落在 **14**。改正后直 TIFF 与
JPEG APP1 两条路都返回 `Just 2026-08-25 13:45:07`，与评审所述逐字吻合。
**教训与突变那条同形：自己的复现失败，先怀疑复现，再怀疑结论。**

**两条被下修严重性（有源码依据，不是打折）**：#2/#3 都指向"(size, mtime) 不能
证明内容未变"。这成立，但后果没有评审说的那么重——`Pm.Exec` 落位前会重 hash
既有目标（`Exec.hs:448-454`），写入时又用写时 hash 与重读 hash 双双比对 `opSha`
（`Exec.hs:485-488`）。所以撕裂的 sha 会在 apply 期**响亮失败**，绝不会写出错误
内容；stale catalog 的后果是**静默不搬**，不是覆盖。据此 #2 归入"静默缺席"那一
类一并修，#3 记录其边界而不再额外加价。

**一条比评审说的更宽**：#5 只说"未识别文件不报告"。实际根因是**同一份知识存在
两处定义并已分叉**——`Pm.Versions.rawExts` 认 12 种 raw，`classifyExt` 只认
`.arw`/`.dng`。后果是尼康/佳能/富士/奥林巴斯的卡插进 `pm sort`，每个 raw 都判成
`KindMeta` 被静默忽略，用户看到的是"照片 0 个"。修法不是补几个扩展名，而是把
定义收成 `Pm.Types.rawExts` 一处、让 `Versions` 引用它（`.psb` 一并补齐）。
真实库实测零非索尼 raw，故 `pm versions` 的输出集合不因此改变。

**四个根因、四处改动**：① IFD 偏移下界收进 `ifdEntries`（IFD0 与子 IFD 共用）；
② 扩展名清单唯一化；③ `verifySkips` 在跳过前重 hash 目标；④ `listSource` 改用
`Pm.Scan.listTree`，并新增 `Accounting` 让每个没进计划的源文件都被列出来。

**7 道新闸各自突变转红（7/7）**：IFD 下界 / 扩展名清单 / 跳过前复核 / 认不出的
单列 / 遍历错误留底 / 区间外留底 / 无主侧车留底。加上前两轮的 13 道，`pm sort`
一线共 20 道闸有单闸用例。

**自查另修两处文档回归**：`Pm.Exif` 的模块注释写着 `DESIGN §13`（§13 是测试与
验收，假交叉引用），且"标签优先级"仍列着已被删除的 `0x0132` 回退。前者与上一轮
在 `Pm.Sort` 修过的是**同一个缺陷**——那次只改了实例没扫同类，这次全仓扫了一遍
交叉引用（其余均仍指向存在且切题的节；§7–§10 经 DESIGN.md 的重定向存根解析）。

### 第 26 轮 codex 门禁（2026-08-25）——NO-GO，7 条：6 条成立、1 条部分证伪，248 例

读的是第 25 轮的修复 `4d67fb2`。7 条（3 critical / 2 major / 2 minor）。评审同时
**确认了三处上一轮改对的地方**：`.psb` 加宽没有意外扩大缩略图端点（`findJpeg`
另有 `.jpg/.jpeg` 限制）、`sidecarIndex` 对 `a.b.ARW` 与大小写差异工作正常、
`resolveEvent` 取排序后首项成立且 `--event` 分支不用该日期。

**最重的一条不是 P5-A 的缺陷，是一个跨模块的类。** `verifySkips` 用
`root </> rel` 直接打开目标去核对内容——库内任何一层是 junction 时，被"验证"
的其实是库外的文件。而**同样的写法早已在 `Pm.Clean.anyWitnessAlive` 里出厂**，
它的下游是 `pm trash empty` 的**永久删除**屏障（`threeCopiesStillExist`）。所以
这不是"Sort 新写坏了"，是我在一个已有的坏形状旁边又开了一个口，才把它一起照
出来。收成 `Pm.Hash.probeConfined`（`resolveUnder` 后再开）一处，两个调用点共用。
**这两处改动属安全内核，不属 P5-A。**

**四个根因、四处改动**：① 校验性读取先限域（上）；② 遍历策略按用途区分——
`listTree` 跳过点目录是给**库根**写的（`.pm`/`.git` 是元数据），`pm sort` 的源
是用户随手指的目录，点开头的目录只是普通文件夹，原样搬过去会让
`card\.hidden\a.ARW` 连一条记录都不留地消失，故参数化为
`SkipDotDirs`/`WalkDotDirs`；③ 结构性声明不自洽即整体作废——IFD 条目数此前是
**截断**（取前 4096 条，越界的由 `sliceAt` 悄悄丢掉），谎报 `count=65535` 的
文件照样返回时间，截断等于接受一个前缀；④ 缺席与读不到分开——两者安全方向
相反（缺席 → 照搬/照删，读不到 → 保守拒绝），`ContentProbe` 四态，且只捕
`IOException`，`SomeException` 会把 Ctrl-C 一起吞成"读不到"。

**一条部分证伪。** #5 说源根自身是 reparse point 属 major。但 `resolveUnder` 的
文档明确写着「root 由**用户**指定，把库根放在 junction 上是合法用法」——`pm sort`
的源同样由用户显式指定，同一条理由适用。所以不拒绝，改为**告知**用户实际在
整理哪个目录。

**一条如实登记的残余。** #1 的前半（跳过路径上源侧的 TOCTOU）：源在自己 hash
前后各 stat 一次，hash 期间的改动抓得住；但"快照之后、报告之前"的改动，任何
计划期命令都看不见。对**进计划**的项 Exec 在 apply 时会复验（`Exec.hs:441-446`
源 stat + `:485-488` 写时/重读双 hash），**被跳过**的项没有 apply，所以这一格是
真残余，边界是「需要在命令运行期间改动源文件」。

#### 本轮最该记的一条：我把一次**读到旧库的探针**当成了真缺陷

突变首轮 RED 4/7，三条全绿。按既有教训逐条追，其中 Q7（目录列举异常）我判定
为"真缺陷"：`listDirectory` 是 `filter f <$> getDirectoryContents`，我据一次探针
输出（"抛异常，说明 try 没兜住"）断定惰性列表逃出了 `try`，于是加了
`length ns \`seq\``，还在注释里把它与 `Pm.Exif` 当初那处 `pure` 非严格并列为
"同一个形状"，并据此向用户汇报"突变替我抓出一个真缺陷"。

**是错的。** 重新构建后，有无该 `seq` 的探针输出完全相同（`files=[] errs=["."]`），
突变也证明它不承重。那次"抛异常"来自一个**尚未注册的旧库**——当时 `pm.exe`
正在跑备份，`stack build` 在 `copy/register` 阶段报 `permission denied` 失败过
一次，探针跑的其实是**加 `try` 之前**的代码。`seq` 与那条假注释已删除：
**没有依据的防御性代码配一条假注释，比不加更糟**——它会让下一个人相信一个
不存在的机制。

教训是三条并列的、同一形状的自我纠错，本阶段各出现一次：
① 复现失败时先怀疑复现（第 25 轮 #1，伪造项偏移算错）；
② 用例期望错时先怀疑期望（本轮 `count=3` 其实自洽应照读）；
③ **探针输出异常时先怀疑构建是否新鲜**（本轮 Q7）。三条的共同点是：
**证据本身也要被验证**，而不是拿来即用。

**7 道新闸各自突变转红**：IFD 装得下 / IFD 条目上限 / 源点目录策略 / 限域读取 /
缺席与读不到分开 / 源根链接告知 / 目录列举异常成错误。其中三道是首轮全绿后
补的用例——`wholeIfdFits` 需要 `count=100`（低于上限但装不下）才能单独命中，
`CpUnreadable` 用「末段是目录」构造（实测 `getFileSize` 返回 0、随后按文件打开
报 permission denied），列举失败用「文件当根」构造。

### 第 27 轮 codex 门禁（2026-08-25）——NO-GO，5 条**全部成立**，252 例

读的是第 26 轮的修复 `97098e3`。5 条（1 critical / 2 major / 2 minor），逐条
第一方核实，**全部成立**。评审同时明确清了两处：EXIF 边界「未发现缺口」
（`rel == length` 被 `sliceAt` 拒绝、`wholeIfdFits` 与 `sliceAt` 无重叠漏洞、
IFD0 与子 IFD 共用下界 8 符合 TIFF 布局）；`Pm.Clean` 的改动「是收紧，不是语义
回归」。

#### 最重的一条：我在**修**那个反模式的过程中，又造了一个同形实例

第 26 轮我把校验读取从 `root </> rel` 直接打开改成了 `resolveUnder` 之后再打开，
并在提交信息里写「收成一处，两个调用点共用」。但那一版的实现是
`getFileSize` 探一次存在性、再 `sha256File` **按名字打开第二次**——「校验的
对象」与「读的对象」依然是两次独立解析。这正是本项目十一/十二/十三轮反复
收拾的那个形状，而我是在修它的过程中重新引入的。

正解项目里早就有，就在隔壁：`Pm.Config.readPmState` 的
「`resolveUnder` → **只打开一次** → 在句柄上查 link count → 从**同一句柄**读完」
（`sha256Handle` 正是 P3b-15 为这条纪律加的）。`probeConfined` 现与它逐字同形。

顺带补上 hardlink 那一半：`resolveUnder` 原理上看不见 hardlink（其文档明写），
而这个判定的下游一边是 `pm trash empty` 的「三副本齐了，可以永久删」——三份
副本必须是三个**独立对象**，同一个对象出现在两个名字下不算两份。

**教训**：修一个反模式时，最容易在修复本身里复刻它。判据不是「我用了
`resolveUnder` 吗」，而是「**校验的对象与使用的对象是不是同一次解析的产物**」。

#### 其余四条

- **#2**：第 26 轮声称把「缺席」与「读不到」分开了，实现却把 `getFileSize` 的
  **任何** `IOException` 都判成 `CpMissing`。独占占用触发的
  `ERROR_SHARING_VIOLATION` 于是成了"文件不存在"→ `VCopy`。改用
  `isDoesNotExistError`，与 `readPmState` 同一判据。**声称修好与真的修好之间
  差了一个判据**。
- **#3**：源恰好是 pm 库根时，`WalkDotDirs` 递归进 `.pm\tmp`（半写入的临时
  文件）与 `.pm\trash`（已隔离文件）；它们头部有合法 EXIF，会被当照片拷走。
  `WalkDotDirs` 加唯一例外：不进 `.pm`，但记一条不静默；普通点目录仍照走
  （第 26 轮 #3 的行为不被这次收紧顺手撤销）。
- **#4**：撞名整批拒绝时，被选中的其余照片与**已被主文件认领的侧车**既不在
  `spCollide`（只有撞名的 basename）也不在 `spOrphanCars`（已认领，不算无主），
  一个都不出现在输出里。抽出 `reportChosen`，撞名与事件名非法两条计划前失败
  路径共用。
- **#5**：源根是 junction 的说明混在 `sfErrors` 里，让「未入计划 N 个」多算 1；
  `canonicalizePath` 也未包异常。新增 `sfNotes` 把**诊断**与**没归位的文件**
  分开。

#### 补 #4 的用例时挖出的三个本机事实

第一轮突变 RED 4/5，#4 全绿——没有用例钉住「输出里到底有没有它」。这条
finding 讲的就是**印了什么**，只能真去捕获 stdout；断言 `SortPick` 的字段等于
换个说法，钉不住"调用方到底印没印"。做这件事连撞三个坑，都是本机实测：

1. 临时文件句柄按 **locale** 编码（本机 GBK），pm 输出里的 `⚠`(U+26A0) 与
   `✗`(U+2717) 直接抛 `commitBuffer: invalid argument`。
2. 重定向的是**进程级** stdout，而 tasty 缺省并行——并行跑的别的用例也写进这个
   句柄，于是**它们**一起炸（实测三条同时红）。
3. `hDuplicate`/`hDuplicateTo` 造出的句柄用 **locale** 编码，会把
   `Pm.Win.setupConsole` 早先设好的 utf8 悄悄抹掉。**替换后要钉，还原后也要钉**
   ——否则后续用例接着炸。

另外 `withSystemTempFile` 的清理会再 `hClose` 一次、与自己的关闭撞车；而不关又
读不出来——GHC 句柄锁不许「已开写」的文件同时被开读（正是 `caseProbeLocked`
用来构造占用态的同一个机制）。改成用 `withSystemTempDirectory` 自管生命周期。

**5 道新闸各自突变转红（5/5）**：单句柄校验口 / 缺席与读不到分开 / 源遍历不进
`.pm` / 计划前失败列出选中文件 / 诊断与未归位文件分开。

### 第 28 轮 codex 门禁（2026-08-25）——NO-GO，7 条中 5 条成立、1 条证伪、1 条登记残余

读的是 `cac8836`。前两次尝试 codex 侧没挂上 shell，回的是"无法评审"的 NO-GO
（不是代码结论）；第三次挂上了，跑了 52 条命令真读源码，但它的沙箱**拒绝写
`%TEMP%`**，`stack test` 与 `stack runghc` 探针全部 `permission denied`——它自己
如实写明"未伪报为通过"。所以这一轮是**只读评审**：静态可判的它判了，需要动态
验证的那几处由本方补探针。

#### 逐条处置

- **#1（critical，成立 → P5-D 已修）**：`resolveUnder` 遇到尚不存在的分量后
  直接拼接剩余路径、且全程不持有目录句柄，与随后的 `openStateRead` 之间有
  TOCTOU 窗口。**代码事实成立**。

  用户裁定「做最正确、彻底、优雅的方法，一切以质量为最优先」。最初的设想是
  句柄相对遍历（`NtCreateFile` + `ObjectAttributes.RootDirectory`），要新写一
  套 NT 层 FFI；**实际采用的更小也更彻底**：把因果方向调过来——先打开，再用
  `GetFinalPathNameByHandleW` 在**句柄**上问"你绑定的是哪条路径"。答案取自要
  读写的那个对象本身，于是"解析"与"使用"合成了一次。`resolveUnder` 降级为预筛。

  这条修法的前提（那个 Win32 调用在五种别名形态下究竟返回什么）没有当成"应该"
  处理，而是写成了**常驻用例**：中途 junction / 末级 symlink 判否；普通文件、
  **库内 hardlink**、root 经 junction 判是。hardlink 判是是对的——那条路径上确实
  有一个能读到这些字节的对象，它算不算"另一份独立副本"由 `FileId` 回答（#2）。

  竞态本身也做成了确定性用例：先让 `resolveUnder` 成功，**然后**把中途一层换成
  指向库外的 junction，再打开。同一条用例还断言**裸 `openBinaryFile` 在这一步
  会读到库外的诱饵**——否则它只证明新写法拒绝了，不证明拒绝的是真实存在的危险。

  剩下的窗口写进了 DESIGN §14：`MoveFileEx` / `RemoveDirectory` 这类只吃名字、
  没有句柄形态的 API。那是另一件事，不再混在一句"属安全软件范畴"里带过。
- **#2（major，成立）→ 判据从 link count 换成文件身份**。见 DESIGN-COMMANDS §8.2。
  这一条值得记住的是它的形状：`nlink == 1` **充分而不必要**，于是它给出的是
  **假阴性**（永远 HELD），方向安全但功能坏死。安全方向的错误也是错误。
- **#3（major，成立）→ `.pm` 按内容认身份**。
- **#4（major，成立）→ pick 之后四条中止路径统一交代，且不截断**。与第 27 轮 #4
  **同一形状**：那一轮我补了两条就收手，没有把这个类扫干净。
- **#5（major，证伪）**：「不给 `--apply` 也写了 `.pm/plans`，违反两段式」。
  第一方核实 DESIGN §5 与 CLI 输出：计划文件本来就要在没有 `--apply` 时落盘，
  否则 `pm apply <planId>` 无从谈起，命令末尾也明确打印「计划已存 …」。
  **根源是我自己的评审提示词**——里面把不变量简写成"未给 `--apply` 时不得有任何
  写入"，评审照字面判。提示词与 DESIGN §5 都已改准。
- **#6（major，成立）→ IFD 完整性含 4 字节 next-IFD offset**。本机探针：一个
  64 字节的 TIFF（子 IFD 条目数组正好在缓冲区末尾结束）返回
  `Just 2026-08-25 13:45:07`；补上那 4 字节后 `Nothing`，去掉又复现。
- **#7（minor，成立）→ `sfNotes` 接上输出**。这条是我上一轮**自己造的回归**：
  把诊断从 `sfErrors` 里"分出来"之后没接出口，一条本来会打印的说明就此消失。
  分开的目的是不计入「未入计划 N 个」，不是不说。

#### 这一轮暴露的两件本机事实

1. **`captureStdout` 与 tasty 并行不相容**。它重定向的是**进程级** stdout；
   用例从 1 条涨到 5 条之后，不但断言读到别的用例的输出，连 tasty 自己的
   FAIL 详情都被吞进临时文件。处置不是"断言写得更巧"，而是承认这是一个**进程级
   共享资源**：`Spec.hs` 给整个套件加 `localOption (NumThreads 1)`，串行。
   代价 1.9 s → 9.5 s。
2. **锁住一个 `.ARW` 打不中 `snapshotSrc` 那条分支**：`readCaptureTime` 先读它、
   读不到就把它判成"读不到拍摄时间"，于是它压根不进 pick。要打中，得锁一个
   **侧车**——侧车不过 EXIF 读取，由主文件认领后直接进 `picked`。我第一版用例
   因此假失败，是用例的错不是代码的错。

**八道新闸各自突变转红（8/8）**：IFD 的 4 字节 / `.pm` 按内容判 / 诊断真的打印 /
新鲜度失败列出选中文件 / snapshot 失败列出选中文件 / 清单不截断 / 身份排除集
生效 / 内容读取不再用 link count 判据。
