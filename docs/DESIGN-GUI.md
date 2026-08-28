# pm 设计（GUI 卷）——§11 桌面程序与 `pm serve` API

> [`DESIGN.md`](DESIGN.md) 的配套文档，**同一份设计的续篇**（拆分理由与
> [`DESIGN-COMMANDS.md`](DESIGN-COMMANDS.md) 相同：DESIGN.md 有 750 行硬预算，
> 而 §11 随端点与 GUI 页数线性增长——2026-08-27 P8-A 第三次触顶时按边界拆出）。
> 编号沿用，跨文档引用照旧写 §11；不变量 I1–I11 的定义在
> [`DESIGN.md` §2](DESIGN.md#2-需求--不变量)，命令面在 DESIGN.md §5。
> 读本节的 DocDrift 哨兵（页序 ①—⑦、路由清点 `caseRouteRoster`——本文件反引号里全部
> `METHOD /api/…` 的集合与 `src/Pm/Serve*.hs` 的路由元组集合逐项相等、CSP 逐字、配置锁
> 「四条读改写路径」清点）
> 自 P8-A 起以本文件为证据。

---

## 11. GUI（独立桌面程序，Rust / Tauri v2 —— 用户裁定 2026-08-24，改自 8/22 的 C#/Java）

- **架构边界（不变量级）**：GUI 是独立进程，**永不直接触碰照片文件**；一切
  读写经 `pm serve` 的 loopback JSON API——写路径与 CLI 完全同一 Plan/Exec
  内核，I1-I11 对 GUI 自动成立。GUI 崩溃/缺失不影响任何 CLI 功能。
- **语言选型（2026-08-24 改判）**：GUI 用 **Rust + Tauri v2 + 纯静态 HTML**
  （不用 npm），内核保持 Haskell。本机实测 cargo/rustc 1.94.1、tauri-cli
  2.11.4、WebView2 151、VS2022 BuildTools 均已在，.NET SDK 不在——Rust 路线
  零安装；8/22 的 "C# WPF 优先 / 装 .NET SDK" 作废。JPG 解码/缩放/中文排版
  由 WebView 原生栈承担；ARW 内嵌预览提取留 v2。
- **API（P4-1 落地，`src/Pm/Serve.hs`）**：只绑定 127.0.0.1，端口默认由内核
  随机分配，启动时在 stdout 打印一行 `{"port":N,"token":"…"}`；每个请求须带
  `Authorization: Bearer <token>`（crypton 16 字节熵 hex，常量时间比对）；
  `Host` 须**恰好**是 `127.0.0.1` 或 `127.0.0.1:<1-5 位十进制端口>`（精确解析，
  挡 DNS rebinding；十八轮把前缀判定收紧）；`--port` 限 0..65535（越界不静默
  折回）；带 `Origin` 的请求只接受 `tauri://localhost` / `http(s)://tauri.localhost`
  （预检 OPTIONS 免 token）。只读端点：`GET /api/ping`（P7 起带 `allowApply`，
  GUI 据此决定渲染不渲染计划页的「执行」按钮）、`GET /api/status[?fresh=1]`
  （与 `pm status` 同源的 `StatusReport`，含退出码）、
  `GET /api/publish-commands`（P7：把配置好的两仓路径/push 目标拼成上线命令
  文本，纯函数 `Pm.Publish.publishCommands`——pm 不执行 git，GUI 只复制）、
  `GET /api/vault/status`
  （与 `pm vault status --json` 的 stdout **逐字节相同，含末尾 LF**）、
  `GET /api/vault/new`、`GET /api/vault/notes`（P8-C 照片记录 + 发布状态，与 `pm vault notes --json` 同一渲染）、`GET /api/config`（只读健康视图，见下「设置页与配置端点」条）、`GET /api/album/candidates`（P8-D：成片 jpg 未进相册的按事件夹列出 + 非 jpg 单列，`Pm.Album.albumCandidates`）、`GET /api/sort/survey`（只读提议，见下「整理新照片」条）、`GET /api/plans`、`GET /api/plan/<id>`、
  `GET /api/thumb/<sha>`（只提供 catalog 里 JPEG 条目的原字节，读取前逐级
  `resolveUnder`——扫描后被换成库外链接的条目不跟随；缩放由 GUI 做）。vault
  两个端点会刷新 `.pm/vault-cache`：进程内 MVar + 跨进程 root 锁（三十一轮
  F1）串行化，锁被占则本轮不刷新（报告不受影响）。
- **三级授权（P5-C）**：`serve` 的授权分三级、缺省最弱——①无开关＝只读；
  ②`--writable`＝POST 端点可**生成计划**（只写 `.pm/plans` 与少量 pm 自身状态，
  **不执行、不碰照片**）；③`--allow-apply`＝才允许 `POST /api/apply` **执行**已存
  的计划（唯一会动照片字节的端点，蕴含 ②）。第 ③ 级单独一个开关而不是并进
  `--writable`：后者的契约「不执行、不碰照片」写在帮助文本、本节、README 与
  GUI 四处，悄悄放宽它等于让所有按 ② 理解去用它的地方（含 `pm ui` 自己的拉起
  参数）无声地获得动照片的能力。端点不新增任何执行能力：装载／按 UUID 绑 root／
  `--only` 组闭包走 CLI 同一个 `prepareApply`，执行、执行期屏障的装配与 catalog
  回写全部走同一个 `executePlanNowWith`（屏障由内核在 root 锁内跑，§6.7）。逐项结果与提示**走 JSON
  响应体**，不走 stdout——`pm ui` 只读一行 announce 就丢掉 BufReader，serve 的
  stdout 此后无人排空，照着打会填满管道缓冲。
- **写端点（P4-5 起，用户裁定"先做生成计划，apply 后置"）**：serve 加
  `--writable` 开关（缺省只读；`pm ui` 拉起时置位）。共**九个** `--writable`
  级写端点，都不执行、不碰照片——
  `POST /api/vault/push-plan`（P4-5，本条）、`POST /api/vault/hold`（P4-7）、`POST /api/vault/notes`（P8-C，照片记录：写主库 `.pm/vault-notes.json`，与 hold 共用 `recordPost` 壳与锁序）、
  `POST /api/config` 与 `POST /api/backup-init`（P4-8，均见下）、
  `POST /api/sort/plan`（P5-E，见下）、`POST /api/import/plan`、`POST /api/album/add-plan`、
  `POST /api/convert/plan`（P8-D，见下「归档页与 AI 建议」条）；执行是第 ③ 级 `POST /api/apply`
  （P5-C 实现，P7 起由 GUI 使用，见上文三级授权与下文 P7 条）。
  第一个是 `POST /api/vault/push-plan`，
  体 `{"assignments":[{"name","category"},…]}`，上限 64 KiB（413）；校验与计划
  构造和 CLI `pm vault push` **共用**（`checkAssignments` / `vaultPushItems` /
  `mkVaultPushPlan`，fail-closed：任一指派不合法整体 400 并列出全部错误）；落盘
  前同样过 `requireWritable`（I11 + 身份）。写域限于 **vault 的 `.pm`**：计划落
  `.pm/plans`，首次请求还会经 `ensureVaultRoot` 幂等建 `.pm/root-id`（含 I11
  守卫）——二十轮纠正了此前"只写 plans"的措辞；**不执行、不碰照片**。响应带计划、
  文件路径、`pm apply <id>` 提示与 git 步骤。
- **GUI 执行面 + 上线命令（P7，用户裁定 2026-08-26「GUI 加执行功能」→
  澄清为「执行 pm 计划」）**：`pm ui` 的 Rust 壳自 P7 起以 `--allow-apply`
  拉起 serve；计划页对有待执行项的计划渲染「执行」按钮——**同一按钮两次点击
  确认**（先 arm、5 秒不确认自动解除；WebView 无弹窗原语），走
  `POST /api/apply`，逐项结果与 log 从 JSON 响应体渲染，并指明 `pm undo`。
  git 依旧只生成不执行（I9 不变）：配置新增 `[portfolio] dir` 与
  `[vault]/[portfolio] push`。生成文本是整块复制进终端的，粘进哪个 shell
  由用户定——三十九/四十轮先后抓到展开字符、bash 双引号内尾随 `\` 撑开引号、
  `git add "-A"` 选项注入，黑名单补不全；`Pm.Publish` 因此**解析而非过滤**：
  路径解析为盘符绝对路径 + 白名单分量后以 `/` 重渲染（`cmdPath`），push
  目标按 `<remote> [<refspec>]` 语法解析且段首必为字母数字（`pushTarget`），
  操作数前一律 `--`；设置入口与生成汇点各验一次，不合格整体拒绝。状态页
  vault 卡的「复制上线命令」把 `GET /api/publish-commands` 的文本复制给
  用户自己粘贴执行；vault 会话侧的对应入口是档案仓的 `/photo-publish` skill
  （列清单确认后代执行，vault 根仓永不 push）。
- **整理新照片（P5-E，GUI 第②页）**：两个端点，都不执行。`GET /api/sort/survey
  ?src=…&gap=…` 是只读提议，走 CLI 同一个 `Pm.Sort.surveySort`——页面上的分段与
  终端建议的命令因此不可能各说各话；`POST /api/sort/plan {src, place|event, from,
  to}` 走同一个 `runSortPlan`，只写主库的 `.pm/plans`（`--writable` 级，与
  push-plan 同级）。页面把每段起止日期预填进去、地点留空要用户填（相机零 GPS，
  pm 不猜——I1），同年月已有事件夹一键并入（切成 `--event` 语义）。计划 id 由
  `runSortPlan` 直接交回，不从 `.pm/plans` 里挑"最新的那个"——并发生成时那是猜。
- **归档页与 AI 建议（P8-D，GUI 第③页；DESIGN-P8.md §22–23）**：三个写端点都走
  `ServeAlbum.planPost` 壳（`--writable` 级：403 → 体 400 → `{code, planId, log}`，
  `POST /api/sort/plan` 自 P8-D 也改走它）：`POST /api/import/plan {alsoAlbum}` ＝
  `pm import [--also-album]`（`runImportTo`）；`POST /api/album/add-plan {paths}` ＝
  `pm album add`（`runAlbumAddTo`，paths 是候选给的 `<事件夹>/<文件名>` 原样回传）；
  `POST /api/convert/plan {paths, alsoAlbum}` ＝ `pm convert`（`runConvertTo`，请求在
  `seConvertLock` 上排队——第一段派生件写主库 `.pm/derived`，两个并发转换同一源会撞 tmp）。
  JSON 体读取上提为 `ServeGuard.withJsonBody`（413 超 64 KiB / 400 非 JSON），此前五处
  复制合一。`POST /api/suggest` 是**只读级**（缺省授权即可）：serve 用 `PM_CLAUDE_EXE`
  （给了但不存在 → 409，不回退）或 PATH 上的 `claude` 拉起 `claude -p --output-format json
  --permission-mode plan --max-turns 8`（cwd ＝ 主库 / 源目录，提示经 stdin，
  `PM_SUGGEST_TIMEOUT` 秒超时、缺省 180），只把模型答的 JSON 规范化后交回——pm 不据此写
  任何东西，建议落不落盘由用户在页面上点「保存决定」/「生成计划」决定。
  `kind:"classify"`（≤ 20 个相册文件名 → 类目 / 地点 / 坐标 / 来源 / 依据 / 标题；未请求的
  名字丢弃进 `dropped`，类目不在三类 → null，坐标经 `parseCoordinates` 规范）；`kind:"place"`
  （`src` + `gap` → serve 自己重跑 `surveySort`，不信任客户端的分段；每段 `evenSample 5`
  取首/中/尾均匀 5 张 jpg，> 12 段 400，一张 jpg 也没有的段不交给模型、答 `place:null`）。
  同一时刻只跑一个（`seSuggestLock` 满 → 409）；找不到 claude / 超时 / 子进程 IO 失败 →
  409，模型退出非零或答非 JSON → 502 带 `raw`。每次调用花的是用户自己 Claude 账号的钱
  （实测每次 ≈ $0.7–1.3，系统提示缓存写入占大头），响应带 `cost`、页面文案写明。测试用
  `test/fixtures/fake-claude.cmd` 顶替（`PM_FAKE_CLAUDE` 五种模式）。
- **GUI 拉起时静音 stdout（P5-E）**：`pm serve --exit-on-stdin-eof` 打完
  announce 那一行之后把进程 stdout 引到空设备。`pm ui` 只读那一行就丢掉
  BufReader，此后管道无人排空；库层任何一行 `putStrLn` 都会往里灌，填满
  64 KiB 缓冲后 serve 卡在写上。逐个端点记得传 sink 治不住——漏一个就复发。
  手工跑 `pm serve` 时不动 stdout，诊断照旧可见。
- **GUI（P4-4 UX 重做，用户反馈"清晰优雅、快速上手、直观可视化"+ 三项状态
  可视化）**：左侧导航**七页**（数字键 1–7 切换；编号即 `gui/ui/index.html` 的 nav
  次序）。①**状态**——照片库四张分层卡（Raw / 成片 / 相册 / 暂存：文件数、体积、
  容量占比条）+ 索引时间与「核对新鲜度」；**vault 展示集同步**卡（差异数 chip、
  **九态**计数 pill = OK/NEW/HELD/MISSING/RENAME/DRIFT/DUPLICATE/UNPUSHABLE/UNSTABLE，
  其中 NEW / HELD（含失效）/ MISSING / RENAME / DRIFT / UNSTABLE 可展开清单——"差哪些"）；
  **备份硬盘同步**卡（未登记 / 上次同步时间 + 滞后 add/update/extra / 缓存不可信）；
  「下一步」列表把 status 退出码的语义翻成可点的动作。②**整理新照片**——见上 P5-E 条（P8-D 加「AI 建议地点」：
  只预填空着的地点格，把握低的填 `<地点?>`，每段一行依据）。③**归档**——三张卡：暂存区归档
  （勾「同时导入相册」）、成片 → 相册（按事件夹分组的缩略图网格勾选、「全选这个事件夹」）、
  非 jpg 转换（勾选 + 「同时进相册」→「转换并生成计划」）——三者都只出计划，见上 P8-D 条。
  ④**分类推送**——NEW 缩略图网格（原图 4–75 MB，GUI 侧 `createImageBitmap(resizeWidth
  640)` 缩放后再挂，修掉"滚动后缩略图消失"——全分辨率位图撑爆 WebView 的根因）+ 三
  类目分段按钮 + 每卡三格照片记录（地点 / 坐标 / 标题，P8-D：打开页时从 GET notes 回显，改了的差集随下一步
  经 POST notes 写主库）+「AI 建议分类/地点」（P8-D：类目只在按钮上描边 `.ai`、三格只填空着的）
  + 进度「已选 x/N」+「保存决定并生成推送计划」→ hold → notes → push-plan（hold 先行：服务端拒收 held 文件的 push）→ 结果
  面板（计划 id、`pm apply` 命令、git 步骤）。⑤**计划**——表格（类型徽标、id、时间、
  项/待执行/跳过/待裁决）+ 明细（逐项 拷贝/改名/隔离 + 源→目标 + 状态徽标，原始 JSON
  可展开），打开即选中最新计划。⑥**设置**（P4-8，见下）。⑦**上手**——四步说明 + 安全
  模型一句话。技术：`<img src>` 带不了 Authorization → fetch→blob；旧 blob URL 每轮
  revoke；Tauri CSP（`gui/src-tauri/tauri.conf.json` 逐字）：`default-src` 与
  `script-src` 只 `'self'`；`connect-src http://127.0.0.1:* ipc: http://ipc.localhost`；
  `img-src 'self' blob: data:`（缩略图 fetch→blob 要 `blob:`）；`style-src 'self'`（0.6.1
  收紧：F090 实机 CDP 探针证实 WebView2/Tauri 不注入内联样式、app.js 只走 CSSOM；运行时
  头由 Tauri 重排并为其注入脚本追加 sha256）。WebView 来源 `http://tauri.localhost` 在
  serve 的 Origin 白名单里。渲染由主线用会话 scratchpad 的 `shot.ps1`（不入仓）自验。
- **进程生命周期（P4-3）**：serve 的生命周期归 GUI 管，`pm ui` **不**启动
  serve——它只找到 `pm-ui.exe`（`PM_UI_EXE` 或 pm.exe 同目录）、把自己的路径经
  `PM_EXE` 交给 GUI、等 GUI 退出。GUI 的 Rust 侧只做三件事：`spawn pm serve
  --exit-on-stdin-eof --writable --allow-apply`（接一条从不写的 stdin 管道；授权开关见上 P7 条）、
  把 announce 的 port/token 经 Tauri command `api_info` 交给页面、退出时 kill 子进程。GUI 异常死亡（崩溃、
  被 taskkill 不带 /T）时 Windows 关闭管道，serve 读到 EOF 自行退出——冒烟实测
  500 ms 内监听消失、零残留。Rust 工具链用 `x86_64-pc-windows-msvc`（Tauri 在
  Windows 只支持 MSVC；本机默认 gnu 工具链链接 cdylib 会 "export ordinal too
  large"，桌面端 crate-type 只留 rlib）。
- **P4-6 收口（codex 二十轮）**：六条 minor 的逐条处置属于评审史，已移入
  [`docs/REVIEW-LOG.md`](REVIEW-LOG.md)；设计面口径（`newActive`／写域／锁序）见上。
- **设置页与配置端点（P4-8，用户裁定 2026-08-25："GUI 里可以设置各种目录
  路径"，范围＝vault / 备份盘 / photos.json / 并发数可改，**主库路径只读**）**：
  主库是一切身份的锚点（root-id、journal、catalog 都挂在它下面），改它等于换一
  个库，一台机器设一次，留给终端 `pm init`；`checkPatch` 对任何试图经编辑层动
  主库的请求**显式报错**而不是静默忽略。三个端点：`GET /api/config`（只读健康
  视图：每条路径 + 是否存在 + root 三态 + vault 的 I11 是否就绪）、
  `POST /api/config`、`POST /api/backup-init`（与 CLI `pm backup init` **共用**
  `backupInitRun`——为此把它拆成"结果 + 渲染"，同 `Pm.Status` 先例）。补丁是
  **三态线格式**：键缺省＝不动、键为 `null`＝清空、给值＝设值（否则"清空 vault
  路径"与"不改"会撞成同一个请求）；`main` 这一格**只为拒绝而存在**，出现即拒，
  不分设值还是 null。CLI 对称命令 `pm config` / `pm config set` 与端点共用
  `checkPatch` / `configTxn`。`ServeEnv` 的配置是 `IORef` 快照、**每请求过一次
  `currentConfig`**：重 stat config.toml 的 (mtime, size)，戳变了（设置页改的，或终端
  里跑了 `pm config set`、别的进程改了它）就当场重载，**主库路径始终钉回启动值**；
  重载失败答 500「配置文件已在外部改动但无法重新载入（…）——修正后重试」。并发数
  只作用于**扫描**；备份盘那边默认单线程防 HDD 寻道抖动，另用 `pm backup --workers N`。
- **配置文件的写纪律（P4-8b，二十四轮）**：配置在 XDG 目录、**不在任何 root 的
  `.pm` 下**，因此 `resolveUnder` 那套限域不适用——但**其余三条纪律适用**，而它
  此前一条都没有（pm 里唯一一个裸 `writeFile` 的状态写入口，只因为它不在 `.pm`
  里就没继承）。现在与 `Pm.Catalog.saveCatalog` 用同一组原语：①独占建 tmp
  （`openFreshBinary`：先 unlink 名字再独占创建——裸 `writeFile` 会**穿透**
  `config.toml.tmp` 名上的 hardlink 写进库外那个共享对象）；②`flushHandleToDisk`
  落盘；③`withConfigLock`（`config.toml.lock` 上的 `hTryLock`，机制同 I10 的
  `.pm/lock`）罩住**读→改→写→读回**全程，**四条**读改写路径共用（`pm config set` /
  `POST /api/config` / `backupInitRun`＝CLI 与 API 共用的备份盘登记 / `pm init --force`，全仓 `withConfigLock` 调用点即此四处），拿不到锁一律拒（API 409）而非互相覆盖。
  删旧与改名之间仍有窗口（Windows 没有暴露 no-replace 语义的原子 replace，而 pm
  不要覆盖原语）：崩在那里只剩内容完整的 `.tmp`，`loadConfig` 认得出并给恢复
  动作，不当"配置不存在"。
- **`PM_CONFIG` 覆盖（P4-8）**：配置路径原本是机器全局的（`%APPDATA%\pm\config.toml`）。
  开发 P4-8 时实测踩到：写端点的一次突变让 POST 通过，测试 fixture 的临时路径
  **当场覆盖了使用者本机的真实配置**（已复原）。根因不是那条突变，而是"测试写
  配置必然打到全局路径"——`configFilePath` 因此加 `PM_CONFIG` 覆盖，`Spec.hs`
  把**整个测试进程**指到临时文件，物理上断掉这条路（不依赖"每个用例记得设"）。
  它是一个显式信任面：能设环境变量的进程可以让 pm 读另一份配置、指向另一个
  合法主库——在 §14"不防同机同用户进程"的模型下可接受，且**换不掉身份**
  （`requireMain` 仍要盘上的 `RoleMain` 与 I11，执行期还校验计划的 root-id）。
  顺带支持一台机器多个库。
- **打包与发布（P4-6）**：`cargo tauri build --target x86_64-pc-windows-msvc`
  产出 NSIS 安装包（`installMode: currentUser`，不需要 UAC），`pm.exe` 作为
  Tauri **sidecar**（`externalBin`）随安装包落在 `pm-ui.exe` 同目录——因此 Rust
  侧 `pm_exe()` 的查找顺序补成 `PM_EXE` → **同目录 `pm.exe`** → `PATH`：开始
  菜单启动既没有 `PM_EXE`、通常也不在 `PATH`，没有这一跳安装版根本起不来。
  release 另附免安装 zip（`pm.exe` + `pm-ui.exe`）。两者都**无代码签名**（个人
  项目、无证书），SmartScreen 会提示"未知发布者"；不放心就照 README 从源码构建。

---

> 本卷到此为止；测试与验收（§13）、风险（§14）仍在 [`DESIGN.md`](DESIGN.md)。
