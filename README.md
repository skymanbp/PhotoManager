# PhotoManager (`pm`)

## 简介

Haskell 写的**零丢失**照片库管理器 + Rust/Tauri 桌面前端：为一个三层照片库
（Raw 原片 → 成片 → 相册收藏，外加暂存区）提供带完整性校验的索引、整理、归档、
备份盘同步、命名治理与展示集（vault）分发。**凡是动照片字节的操作都是两段式**
——先生成人可读的计划，人看过再 `pm apply` 执行；执行有 journal、事后可对账
（`pm doctor`）、整体可回滚（`pm undo`）。

> ### 定位：个人自用，公开可看
>
> 这是作者为**自己那一个**照片库写的工具：目录结构、层级语义、vault 类目都按
> 作者的工作流固定下来。公开是为了可审计、可借鉴（尤其是"怎么让一个会动你
> 数据的工具值得信任"这件事），**不是发行一个通用产品**——没有支持承诺、没有
> 兼容承诺，也不打算适配别的目录结构。Issue/PR 可能长期没人看。
>
> 但"个人项目"不是安全上打折的理由，照片是不可再生数据：pm **没有删除原语**，
> 唯一的移出机制是带 manifest 的隔离区；每条写路径都过对抗评审门禁（至今
> **三十八轮，第 37 轮 GO、minset 空、第 38 轮聚焦复核亦 GO——已收敛**，见 [docs/REVIEW-LOG.md](docs/REVIEW-LOG.md)），每道闸都配"删掉
> 它就转红"的突变验证用例（310 例，GHC 警告 0）。

**设计与不变量：[docs/DESIGN.md](docs/DESIGN.md)**（先读 §2 十一条不变量）。
命令细节：[docs/DESIGN-COMMANDS.md](docs/DESIGN-COMMANDS.md)。
开发史（P0–P6 全程）：[docs/HISTORY.md](docs/HISTORY.md)。
对抗评审归档：[docs/reviews/](docs/reviews/)。

## 功能与工作范围

- **功能一 · 索引与总览**：`pm scan`（(size,mtime) 增量复用 + 并行 hash）、
  `pm status`（四层卡 + vault 差异 + 备份盘滞后 + "下一步"），真实规模
  4633 文件 / 459.4 GiB（2026-08-26 实测）。
- **功能二 · 整理新照片**：`pm sort` 把相机卡/下载目录按 EXIF 拍摄时间分段——
  不带参数只出**提议**（时间切不开事件，边界由人定），给齐地点与区间才生成
  拷贝计划；**拷贝不是移动**，源卡零改动。
- **功能三 · 归档**：`pm import` 把暂存区事件夹归入 `Raw\年\事件-Raw` + `成片\事件`。
- **功能四 · 备份**：`pm backup` 主库 → 备份盘单向增量，按 root UUID 认盘不认
  盘符；备份盘上多出来的（EXTRA）只报告永不动。
- **功能五 · 展示集分发**：`pm vault status`（相册 ↔ vault 九态差异，`--json`
  兼容旧脚本）、`pm vault push`（定类目拷入 + DRIFT 裁决计划 + 打印显式 git
  步骤——pm 不执行 git）、`pm vault hold`（"暂不同步"的本地决定，照片一变自动失效）。
- **功能六 · 命名治理**：`pm names` 把 Raw 事件夹统一到规范命名；歧义不猜，
  报告交人。
- **功能七 · 重复处置**：`pm versions`（版本组 / 非设计内精确重复报告，只读）、
  `pm dedupe`（每份重复都是独立待裁决项，留哪份不替你选）。
- **功能八 · 暂存清理**：`pm clean staging` 只清理「归档层 + 备份盘」都有同 sha
  副本的暂存文件，执行期三副本重验。
- **功能九 · 安全网**：`pm trash`（隔离区列表/清空，永久删除前重验副本）、
  `pm undo`（整计划回滚）、`pm doctor`（崩溃恢复对账 + 完整性体检 + 轮转重验）。
- **功能十 · GUI**：六页 Tauri 桌面前端（状态 / 整理新照片 / 分类推送 / 计划 /
  设置 / 上手）——生成计划、记录决定、改配置；0.6.0 起计划页可**直接执行**
  已存计划（同一按钮两次点击确认，执行链与 `pm apply` 同源，事后可 `pm undo`），
  状态页可一键**复制上线命令**（按设置里的两仓路径/push 目标生成 git 命令文本，
  复制后自己粘进终端——pm 不执行 git）。

**明确不做的**：不适配其他目录结构；不执行 git（I9）；`photos.json` 不在写域
（类别与坐标是看图判断，归上游工作流）；没有删除原语（I2）。

## 安装（Windows x64）

> 结构说明：安装与快速上手前置于实现细节——CLI 工具的 README 先让人跑起来。

从 [Releases](https://github.com/skymanbp/PhotoManager/releases) 下载其一：

| 资产 | 说明 |
|---|---|
| `pm-ui_<版本>_x64-setup.exe` | 安装包（NSIS，装到当前用户，不要管理员权限）：GUI 与 CLI 装进同一目录 + 开始菜单项 |
| `pm-<版本>-windows-x64.zip` | 免安装：解压即用，含 `pm.exe`（CLI）与 `pm-ui.exe`（GUI） |

- **要求**：Windows 10/11 x64 + WebView2 运行时（Win11 自带；Win10 一般随 Edge
  已装，装包在缺失时会拉起微软的官方安装器）。
- 想在终端直接敲 `pm`，把安装目录加进 `PATH`（安装包不改 `PATH`）。GUI 从开始
  菜单或 `pm ui` 启动——它会自己拉起 `pm serve` 并在退出时收回，不用手工开服务。
- 两个资产都**没有代码签名**（个人项目，无证书），首次运行 SmartScreen 会提示
  "未知发布者"。介意就照下面「从源码构建」自己编，产物一致。
- 校验：release 说明里附每个资产的 SHA-256。

## 快速上手

```
pm init --main D:\Photography    # 一次性：写配置 + root 标识
pm scan                          # 索引（首次全量 hash 约 10–25 min，之后增量秒级）
pm                               # = pm status，总览仪表盘
pm ui                            # 桌面 GUI
```

GUI 六页：**状态**（Raw·成片·相册·暂存四层卡 + vault 同步差异清单 + 备份盘滞后
+ "下一步"；vault 卡可一键**复制上线命令**——两仓 git 序列按设置生成，pm 不执行
git）、**整理新照片**（填源目录 → 按拍摄时间分段 → 每段填地点/选已有事件
→ 生成拷贝计划；源目录只读）、**分类推送**（相册里 vault 还没有的照片，缩略图
选类目，或选第四个按钮「暂不同步」→ 保存决定 / 生成推送计划）、**计划**（逐项
明细；0.6.0 起可**直接执行**待执行计划——同一按钮两次点击确认，执行链与
`pm apply` 同源，事后可 `pm undo`）、**设置**（路径与并发：vault / photos.json /
并发数可改、备份盘可登记、上线命令的 portfolio 仓路径与两仓 push 目标可自定义；
主库路径只读——它是身份锚点，改它等于换一个库，留给 `pm init`）、**上手**。

常用命令一览：

```
pm sort <源目录>                  # 整理新照片：按 EXIF 拍摄时间分段（不带参数=只读提议）
pm sort <源> --place 亚特兰大 --from 2026-08-01 --to 2026-08-03   # 生成拷贝计划
pm import                        # 暂存区 → Raw\年\事件-Raw + 成片\事件 归档计划
pm backup init E:\Photography    # 一次性：登记备份盘（按 UUID 认盘，不认盘符）
pm backup                        # 主库 → 备份盘单向增量（EXTRA 只报告永不动）
pm clean staging                 # 仅清理「归档层+备份盘」都有同 sha 副本的暂存文件
pm vault status                  # 相册 ↔ vault 展示集六态差异（--json 兼容 sync_photos.py）
pm vault push --category landscape A.jpg …   # NEW 定类目拷入 vault；DRIFT 出裁决计划；
                                 # 结束打印显式 git 步骤（pm 不执行 git）
pm vault hold A.jpg …            # 决定「暂不同步」：只写主库 .pm 的一条本地记录，
                                 # vault 与照片零改动；照片字节一变该决定自动失效
pm vault unhold A.jpg …          # 撤销，文件回到 NEW
pm names                         # Raw 事件夹统一 Scheme A 计划（B 类月份从成片还原；歧义不猜）
pm versions                      # 版本组 / 非设计内精确重复报告（只读）
pm dedupe                        # 精确重复 → 逐份可裁决的隔离计划（全部待裁决；留哪份不替你选）

pm apply <planId>                # 执行计划（--dry 全量预览 / --only 1,3-5 部分执行）
pm resolve <id> --item N --keep src|dst|both   # 冲突裁决（src=旧目标先隔离）
pm doctor                        # 崩溃恢复对账 + 完整性体检（默认只读）
pm undo <planId>                 # 整体回滚已执行的计划
pm config                        # 打印配置与每条路径的健康状态（只读）
pm config set --vault <目录>     # 改 vault / --photos-json / --workers /
                                 # --portfolio-dir / --vault-push / --portfolio-push
                                 # （上线命令三项；主库路径只读，用 pm init）
pm serve                         # 127.0.0.1 JSON API（GUI 用；缺省只读，见 --writable / --allow-apply）
```

所有命令默认只读（生成计划、exit 1 表示"有事可做"）；**动照片字节**要么
`--apply` 交互确认，要么两段式 `pm apply <planId>`。唯一的例外是
`pm vault hold|unhold`：它不碰任何照片，只在主库 `.pm` 里记一条决定。

## 具体实现——为什么这个工具值得把照片交给它

1. **没有删除原语**。Op 代数只有 Copy / Rename / Quarantine；唯一移出机制是带
   write-ahead manifest 的隔离区，`pm trash empty` 这条全程唯一 unlink 用户数据
   的路径在永久删除前还要**真读盘**重验副本仍在（不信 catalog——快照不是证据）。
2. **两段式 + journal + 故障注入**。计划是磁盘上可 diff 的 JSON；执行先写意图
   再落位，写完复读核 sha；测试在**每一个协议检查点**注入崩溃并断言 doctor 能
   对账、undo 能回滚——不是"崩了大概没事"，是逐点证明。
3. **内核不信任何调用方**。十一条不变量在内核层强制：root 身份、计划格式、
   I11、`.pm` 可信性全部在锁内复检；执行期屏障（"归档层至少留一份活副本"）由
   内核在锁内调用，**该有而调用方没给 = 整批拒绝**，屏障返回值还要核对只做了
   降级——防的不是恶意，是"未来某个调用点忘了"。
4. **`.pm` 状态只经受信取用口**。打开后用 `GetFinalPathNameByHandleW` 在**句柄**
   上反查它绑定的路径（答案取自要读写的那个对象，开完再换目录也改不了句柄指向
   谁）；对象同一性按 `(卷序列号, 文件索引)` 判——junction / symlink / hardlink
   换名一类的库外读写被挡在这一层。路径字符串校验（`resolveUnder`）只是预筛，
   不是安全边界。
5. **判据与动盘是同一个跨进程事务**。凡「读证据 → 判定 → 写」整段进 I10 锁且
   证据在锁内取：执行屏障、trash empty、resolve、doctor --repair、catalog 回写、
   配置的全部四条读改写路径。两个 pm 进程并发也互相抹不掉对方的决定。
6. **三十八轮对抗评审门禁 + 突变验证（第 37 轮 GO 收敛、38 轮聚焦复核 GO）**。每条写路径合并前过独立评审（NO-GO 逐条
   第一方核实——证实的修、证伪的公开记录在 [REVIEW-LOG](docs/REVIEW-LOG.md)，
   包括评审对了我错了的、和我此前文档言过其实的）；每道承重闸配一个"删掉它
   恰好一个用例转红"的突变——绿灯证明闸在承重，不是测试恰好路过。
7. **决定照片去向的路径不引未审依赖**。EXIF 读取是第一方最小解析器：只取需要
   的标签、统一边界检查、读不到即交人判断（fail-closed），不猜文件修改时间。
8. **GUI 永不直接碰照片**。Rust 壳层只做 spawn / 交 token / kill 三件事，一切经
   `pm serve`（127.0.0.1 + 随机端口 + Bearer token 常量时间比对 + Host/Origin
   校验）；serve 三级授权：**缺省只读**；`--writable` 开五个写端点——生成
   推送计划与 sort 计划（写 `.pm/plans`）、记「暂不同步」决定、改配置（主库
   路径只读）、登记备份盘——**没有一个碰照片字节**；`--allow-apply` 才开
   `POST /api/apply`（唯一动照片字节的端点，0.6.0 起 GUI 拉起时传它，页面
   两次点击确认；执行发生在 serve 进程里，走与 CLI 同一条装载/复验/journal 链）。

## 实际效果展示

真实库上的日常总览（`pm status`，2026-08-26 实录，节选）：

```
pm · 索引 2026-08-26 12:53（0 分钟前）· 4633 文件 / 459.4 GiB
  相册                94 文件      2.5 GiB
  ⚠ 暂存区 1 个事件未归档: ["26-06-R66"]
  备份盘     上次同步 2026-08-26 12:32 · 当时无滞后（EXTRA 21）
  vault      上次比对 2026-08-25 21:47 · 无差异（dup 0 · unpushable 0）
  ✓ 索引与磁盘一致
```

重复裁决计划（`pm apply <id> --dry`，每份独立待裁决、不替你选留哪份）：

```
计划 20260825-224708-d24f7e (dedupe) · root D:\Photography
    0 | DECIDE    | quarantine Raw\2023\23-04-EU-Raw\202304景\A7R06770.JPG (dedupe:同 sha 2 份之一)
    1 | PENDING   | quarantine Raw\2023\23-04-EU-Raw\A7R06770.JPG (dedupe:同 sha 2 份之一)
    2 | PENDING   | quarantine Raw\2024\24-12-New York-Raw\_DSC9625.ARW (dedupe:同 sha 2 份之一)
    3 | DECIDE    | quarantine Raw\2025\25-01-Atlanta-Raw\_DSC9625.ARW (dedupe:同 sha 2 份之一)
```

已发生的真实写入（全部有 journal、可 undo，均在门禁 GO + 用户逐项裁定之后）：

- 220 文件 / 21.4 GiB 首次归档，字节精确、catalog 全核；
- 6 项 Raw 事件夹改名（6/6 DONE，doctor 0 异常）；
- 15 张"暂不同步"决定（vault 仓 `git status` 零改动——决定只落主库 `.pm`）；
- 重复处置：8 份同 sha 重复经逐份裁决后隔离（执行期重算 sha，事后 16/16 独立复核）；
- 从备份盘找回 2 张 ARW（源与落位双侧 sha 核对）；
- 增量备份 1016 项 / 98.5 GiB（含 2 对 supersede 复合组；重生成对比归零：新增 0 · 更新 0）；
- 暂存清理 220 项 / 21.4 GiB——即上一条"首次归档"那批的暂存冗余副本，生成期三副本
  真实重 hash + 执行期屏障再验后隔离（HELD 4 项 pm 拒收，留待 `pm import`）。

一个说明"不猜"的例子：`pm sort` 在真实卡上发现纽约与亚特兰大两个事件首尾相接
——时间**切不开**事件，7 张连号 ARW 因此落进两个事件夹。所以分段只是提议、边界
由人定；地点也只能人给（实测相机零 GPS）。

## 性能与质量指标

均为真实库实测（命令与出处可复现，非估算）：

| 指标 | 实测值 | 出处 |
|---|---|---|
| 增量扫描（4633 文件，其中 122 新 hash / 14.0 GiB，workers=16） | 19.4 s | `pm scan` 2026-08-26 |
| 首次全量 hash（480 GiB 级） | 约 10–25 min | 首次建库实录 |
| 测试套件（310 例，整套序列化跑——进程级 stdout 重定向所需） | 10–40 s | `stack test` |
| GHC 警告 | 0 | `stack build` |
| 对抗评审门禁 | 38 轮（NO-GO 逐条第一方核实后处置；第 37 轮 GO、minset 空，38 轮聚焦复核 GO——收敛） | [REVIEW-LOG](docs/REVIEW-LOG.md) |
| 突变验证 | 每道承重闸一个突变、配对用例转红（34–36 轮 6+3+2 道全数通过；37/38 轮 GO 无新增闸） | REVIEW-LOG 各轮收敛证据 |

## 三层库拓扑与「设计内冗余」

```
D:\Photography
├── Raw\<年>\<事件>-Raw\   原片（ARW/DNG/JPG + 侧车）
├── 成片\<事件>\           修完的成品 JPG
├── 相册\                  收藏平铺（字节冻结）
├── To-Be-Sync'd\          暂存区（归档前的中转）
└── .pm\                   pm 自身状态（索引/journal/计划/隔离区）
```

同一张照片出现在 成片 与 相册 是**设计内冗余**（收藏本来就是成品的拷贝）；
`pm versions` / `pm dedupe` 只把**同一层内**的精确重复当问题。Raw 事件夹里的
JPG 不必然是误放——原片本来就是 JPG 时（相机直出/手机/RAW 遗失）它就是原片。
这些判据都写进了工具，不靠人记。展示集（vault）是相册的分类镜像，住在另一个
git 仓里；备份盘是整库的单向增量镜像。

## 技术栈 · 设计思想

**技术栈**：GHC 9.10.3 + stack（lts-24.46），Win32 API 经 cbits FFI（句柄反查、
文件身份、reparse 探测都要精确错误码）；GUI 为 Rust / Tauri v2 + 纯静态 HTML
（无 npm、无前端构建链）；测试 tasty + 故障注入 + 突变验证。

**设计思想**（完整版在 [DESIGN.md](docs/DESIGN.md)）：

- **不猜**（I1）：判不出就报告交人——歧义命名、切不开的事件、读不到的 EXIF。
- **计划是数据**：可打印、可 diff、可手编（apply 会把每道闸重走一遍）。
- **fail-closed**：证据取不到 = 拒绝，而不是按上次的判断继续。
- **诚实记录**：评审对了我错了的、文档言过其实的，都留在 REVIEW-LOG 里不抹。
- **最小依赖**：动照片的路径上没有未审代码。

## 从源码构建

```bash
# CLI（GHC 9.10.3 / lts-24.46）
# --no-interleaved-output --no-dump-logs 为必须：本机 ACP=CP936，stack 把依赖包
# 警告（含 •/» 字符）重编码回自己的 stderr 时会崩（GHC 9.10 二进制向非 UTF-8
# 管道打印不可编码字符即 commitBuffer 崩溃，已实验证实；GHC_CHARENC 只影响 GHC
# 编译器自身，救不了 stack）。pm 自身在 main 首行设 UTF-8（Pm.Win.setupConsole）。
stack build --test --no-interleaved-output --no-dump-logs
stack install                    # 把 pm 放进 %APPDATA%\local\bin

# GUI + 安装包（Rust / Tauri v2；Windows 只支持 MSVC 目标）
cp "$APPDATA/local/bin/pm.exe" gui/src-tauri/binaries/pm-x86_64-pc-windows-msvc.exe
cd gui/src-tauri
# remap 掉 cargo registry 源码路径里的用户主目录，别把本机路径编进公开二进制
RUSTFLAGS="--remap-path-prefix=$USERPROFILE=~" \
  cargo tauri build --target x86_64-pc-windows-msvc
# → target/x86_64-pc-windows-msvc/release/bundle/nsis/pm-ui_<版本>_x64-setup.exe
```

## 路线图与已知限制

**路线图**（按需推进，不承诺时间）：

- ~~`pm vault ingest`~~ ✅ P6-D：pm 只拷 root 内（相册 + vault 类目两份计划），
  `_inbox→_done` 交调用方并打印显式步骤；第 32 轮门禁的 9 条 ingest finding
  已全修（执行次序闸收紧，见 REVIEW-LOG；33–37 轮连续收口「读口
  fail-closed」漏网：35 轮按 IO 读原语全集清点扫尽、36 轮关掉 I11 存在性布尔探针、37 轮关掉链接属性探针的塌 False），门禁已于第 37 轮收敛（GO、minset 空，38 轮聚焦复核 GO），真实 `_inbox` 首次使用只待用户裁定。
- ~~屏障协议的类型封闭~~ ✅ P6-A：`BarrierKind` 分类器 + 屏障只返回降级清单，
  升级/改写在类型上写不出来。
- ~~落位 rename 的句柄形态~~ ✅ P6-C：全部提交型 rename/unlink 走
  `SetFileInformationByHandle`（先验绑定 + 同句柄后验 + 回迁），名字口清零。
- ~~GUI 执行面~~ ✅ P7（用户裁定 2026-08-26）：`pm ui` 以 `--allow-apply`
  拉起，计划页两次点击确认后直接执行已存计划（执行链与 CLI 同源）；上线命令
  一键复制（`[portfolio] dir` + 两仓 push 目标可配；路径与 push 目标**解析后
  重渲染**——白名单语法、`/` 分隔、操作数前 `--`，而不是黑名单过滤后原样拼；
  pm 不执行 git）；档案 vault 侧新增 `/photo-publish` skill 作代执行入口。

**已知限制**：

- Windows-only；目录结构、层级语义为作者的库定制，不打算通用化。
- 文件身份判据在 NTFS 上精确；ReFS 的 128 位 id 被截到 64 位**只会多拒**
  （HELD/待裁决），不会放行——方向刻意（DESIGN-COMMANDS §8.1）。
- 库若放在无 DOS 路径的挂载卷上，句柄反查失败 → 受信取用口全部拒绝（显式失败，
  非静默）。
- 威胁模型（DESIGN §14）：防崩溃/掉电/介质错误/并发良性进程；**不防**同机同
  用户恶意进程的毫秒级竞争——剩余窗口六条逐项登记在 §14，不藏在"等等"里。
- 无代码签名。

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 skymanbp.

公开仓是脱敏快照（本机路径以 `<vault-root>` / `<stack-root>` 占位）；
本地开发历史不推送，远端 `main` 为线性快照提交。
