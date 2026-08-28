# PhotoManager (`pm`)

[English](README.md) · 中文版：与英文版逐节对应；英文版是主入口，本文件是它的中文镜像。

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
> 唯一的移出机制是带 manifest 的隔离区；每条写路径都过对抗评审门禁（**逐轮
> 记录于 [docs/REVIEW-LOG.md](docs/REVIEW-LOG.md)，收敛判定以其末节 verdict
> 为准，不在这里手抄**），凡有可观测自动化落点的闸都配"删掉它就转红"的突变
> 验证用例（418 例，GHC 警告 0）；没有落点的（GUI 无 harness、并发交错无确定
> 性观察点）在 REVIEW-LOG 登记为残余，不冒充覆盖。

**设计与不变量：[docs/DESIGN.md](docs/DESIGN.md)**（先读 §2 十一条不变量）。
命令细节：[docs/DESIGN-COMMANDS.md](docs/DESIGN-COMMANDS.md)。GUI 与 `pm serve` API：[docs/DESIGN-GUI.md](docs/DESIGN-GUI.md)。P8（Photography 为相片 SoT：相册通道 / AI 建议 / jpg 转换 / 1.0.0 收官）的裁定与设计：[docs/DESIGN-P8.md](docs/DESIGN-P8.md)。
开发史（P0–P8 全程）：[docs/HISTORY.md](docs/HISTORY.md)。
对抗评审归档：[docs/reviews/](docs/reviews/)。

## 功能与工作范围

- **功能一 · 索引与总览**：`pm scan`（(size,mtime) 增量复用 + 并行 hash）、
  `pm status`（四层卡 + vault 差异 + 备份盘滞后 + "下一步"），真实规模
  4633 文件 / 459.4 GiB（2026-08-26 实测）。
- **功能二 · 整理新照片**：`pm sort` 把相机卡/下载目录按 EXIF 拍摄时间分段——
  不带参数只出**提议**（时间切不开事件，边界由人定），给齐地点与区间才生成
  拷贝计划；**拷贝不是移动**，源卡零改动。
- **功能三 · 归档**：`pm import` 把暂存区事件夹归入 `Raw\年\事件-Raw` + `成片\事件`；
  `--also-album` 让成片里的 jpg 同源再拷一份进 `相册\`（与成片项同组：成片没落位相册就不执行）；
  `pm album add <事件夹>/<文件名>…` 把已归档的成片 jpg 挑进相册（`pm album candidates` 列候选与非 jpg）；
  `pm convert <库内相对路径>…` 把成片/相册里的 tif/png 等派生一份 jpg（本机 python + Pillow，原文件原地不动）
  落回成片同事件夹（`--also-album` 再进相册）或相册。
- **功能四 · 备份**：`pm backup` 主库 → 备份盘单向增量，按 root UUID 认盘不认
  盘符；备份盘上多出来的（EXTRA）只报告永不动。
- **功能五 · 展示集分发**：`pm vault status`（相册 ↔ vault 九态差异，`--json`
  兼容旧脚本）、`pm vault push`（定类目拷入 + DRIFT 裁决计划 + 打印显式 git
  步骤——pm 不执行 git）、`pm vault hold`（"暂不同步"的本地决定，照片一变自动失效）、
  `pm vault note|notes`（照片记录：类目/地点/坐标/标题的主库侧本地记录，存记录时 sha、字节变了失效；
  `/photo-publish` 读 `notes --json` 的 pending 写 photos.json——photos.json 仍不在 pm 写域）、
  `pm vault ingest`（批量入库：源 → 相册 + vault 类目两份计划；`_inbox→_done` 与
  photos.json 归调用方）。
- **功能六 · 命名治理**：`pm names` 把 Raw 事件夹统一到规范命名；歧义不猜，
  报告交人。
- **功能七 · 重复处置**：`pm versions`（版本组 / 非设计内精确重复报告，只读）、
  `pm dedupe`（每份重复都是独立待裁决项，留哪份不替你选）。
- **功能八 · 暂存清理**：`pm clean staging` 只清理「归档层 + 备份盘」都有同 sha
  副本的暂存文件，执行期三副本重验。
- **功能九 · 安全网**：`pm trash`（隔离区列表/清空——待删条目一律逐项列出、加
  `--yes` 才动手；clean-staging / dedupe 记录另经真读盘复验副本仍在，其余记录不做
  副本复验）、`pm undo`（按 journal 生成反向计划，`pm apply` 后回滚最近 N 个已完成
  操作）、`pm doctor`（崩溃恢复对账 + 完整性体检：默认复验「上次干净退出之后写下
  的那批」，`--deep` 重读重 hash **全库**索引条目并汇报条目数与不符数）。
- **功能十 · GUI**：七页 Tauri 桌面前端（状态 / 整理新照片 / 归档 / 分类推送 /
  计划 / 设置 / 上手）——生成计划、记录决定、改配置、AI 建议（拉起你自己账号的
  `claude -p` 只读模式看图，只预填、不代点、每次有费用）；0.6.0 起计划页可**直接执行**
  已存计划（同一按钮两次点击确认，执行链与 `pm apply` 同源，事后可 `pm undo`），
  状态页可一键**复制上线命令**（按设置里的两仓路径/push 目标生成 git 命令文本，
  复制后自己粘进终端——pm 不执行 git）。

**明确不做的**：不适配其他目录结构；不执行 git（I9）；`photos.json` 不在写域
（类别与坐标是看图判断——pm 只把记录写进主库 `.pm`，投影归上游工作流）；没有删除原语（I2）。

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

GUI 七页（左侧导航次序）：**状态**（Raw·成片·相册·暂存四层卡 + vault 同步差异
清单 + 备份盘滞后 + "下一步"；vault 卡可一键**复制上线命令**——两仓 git 序列按
设置生成，pm 不执行 git）、**整理新照片**（填源目录 → 按拍摄时间分段 → 每段填
地点/选已有事件 → 生成拷贝计划；源目录只读；「AI 建议地点」只预填）、**归档**（暂存区
事件夹 → Raw/成片，可同时导入相册；成片 jpg 勾选进相册；tif/png 等派生 jpg——三者都只出
计划）、**分类推送**（相册里 vault 还没有的照片，缩略图选类目、填地点/坐标/标题记录（可先
「AI 建议分类/地点」预填），或选第四个按钮「暂不同步」→ 一个按钮「保存决定并生成推送
计划」把三件事一起做）、**计划**（逐项明细；0.6.0 起可**直接执行**待执行计划——
同一按钮两次点击确认，执行链与 `pm apply` 同源，事后可 `pm undo`）、**设置**
（路径与并发：vault / photos.json / 并发数可改、备份盘可登记、上线命令的
portfolio 仓路径与两仓 push 目标可自定义；改完立刻生效，终端里跑 `pm config set`
改的同样立刻生效；主库路径只读——它是身份锚点，改它等于换一个库，留给
`pm init`）、**上手**。

常用命令一览：

```
pm sort <源目录>                  # 整理新照片：按 EXIF 拍摄时间分段（不带参数=只读提议）
pm sort <源> --place 亚特兰大 --from 2026-08-01 --to 2026-08-03   # 生成拷贝计划
pm import [--also-album]         # 暂存区 → Raw\年\事件-Raw + 成片\事件 归档计划（--also-album：成片 jpg 同时进相册）
pm album add 26-06-R66/_DSC9621.jpg …   # 成片 → 相册（平铺、只收 jpg；相册同名异容 → 待裁决）
pm album candidates              # 只读：还没进相册的成片 jpg（按事件夹）+ 成片/相册下的非 jpg（→ pm convert）
pm convert 成片/26-06-R66/x.tif --also-album   # 非 jpg → 派生 jpg（Pillow，写 .pm/derived）→ 成片同事件夹（+相册）计划；原文件不动
pm backup init E:\Photography    # 一次性：登记备份盘（按 UUID 认盘，不认盘符）
pm backup                        # 主库 → 备份盘单向增量（EXTRA 只报告永不动）
pm clean staging                 # 仅清理「归档层+备份盘」都有同 sha 副本的暂存文件
pm vault status                  # 相册 ↔ vault 展示集九态差异（其中六态兼容 sync_photos.py，
                                 # --json 逐字段照抄那六个；另三态 UNPUSHABLE/UNSTABLE/HELD）
pm vault push --category landscape A.jpg …   # NEW 定类目拷入 vault；DRIFT 出裁决计划；
                                 # 结束打印显式 git 步骤（pm 不执行 git）
pm vault hold A.jpg …            # 决定「暂不同步」：只写主库 .pm 的一条本地记录，
                                 # vault 与照片零改动；照片字节一变该决定自动失效
pm vault unhold A.jpg …          # 撤销，文件回到 NEW
pm vault note A.jpg --category landscape --location "Hallstatt, AT" --coordinates "47.556533, 13.648033"
                                 # 照片记录：只写主库 .pm/vault-notes.json（记录时 sha，字节变了 → stale）；--clear 清除
pm vault notes [--json]          # 列出记录与发布状态 unsynced/pending/published/stale/unknown（/photo-publish 消费 pending）
pm vault ingest --category landscape <绝对路径…>   # 批量入库：源 → 主库 相册\ + vault <类目>\
                                 # 两份计划（pm 打印执行次序，相册那份先 apply）；_inbox→_done
                                 # 与 photos.json 由调用方收尾；pm 只拷不动源
pm names                         # Raw 事件夹统一 Scheme A 计划（B 类月份从成片还原；歧义不猜）
pm versions                      # 版本组 / 非设计内精确重复报告（只读）
pm dedupe                        # 精确重复 → 逐份可裁决的隔离计划（全部待裁决；留哪份不替你选，
                                 # 用 pm resolve --item N --unskip 逐份批准）

pm apply <planId>                # 执行计划（--dry 全量预览 / --only 1,3-5 部分执行）
pm resolve <id> --item N [--unskip]            # 跳过该项（默认动作）/ --unskip 恢复为待执行；
                                               # dedupe 计划全部待裁决，逐份 --unskip 批准后 apply 才会执行
pm resolve <id> --item N --keep src|dst|both   # 冲突裁决（src=旧目标先隔离）；只适用于 Copy 冲突项
pm doctor                        # 崩溃恢复对账 + 完整性体检（默认只读）
pm undo --last [N]               # 由 journal 生成反向计划：撤销最近 N 个已完成操作（默认 1；--backup/--vault 选侧），再 pm apply 执行
pm config                        # 打印配置与每条路径的健康状态（只读）
pm config set --vault <目录>     # 改 vault / --photos-json / --workers /
                                 # --portfolio-dir / --vault-push / --portfolio-push
                                 # （上线命令三项；主库路径只读，用 pm init）
pm serve                         # 127.0.0.1 JSON API（GUI 用；缺省只读，见 --writable / --allow-apply）
```

所有命令默认只读（生成计划、exit 1 表示"有事可做"）；**动照片字节**要么
`--apply` 交互确认，要么两段式 `pm apply <planId>`——不经计划的字节写只有
`pm trash empty --yes` 一条（隔离区最终清除：逐项列出、二次确认，见下文第 1 条）。
此外若干命令直接写 pm 自己的状态与配置，**都不碰照片字节**：`pm scan`、
`pm init` / `pm backup init`、`pm config set`、`pm vault hold|unhold` / `pm vault note`（主库 `.pm`
里一条「暂不同步」决定 / 一条照片记录）、`pm convert`（第一段把派生 jpg 写进主库 `.pm/derived`——pm 自建状态，落位仍走计划）、
`pm resolve`（改计划）、`pm doctor --repair`（也清 `.pm/derived` 里已落位/失源/半成品的派生件）、`pm serve --writable`
（GUI 背后：写计划/配置/「暂不同步」名单/照片记录；`--allow-apply` 执行计划仍走同一条计划路径）。

## 具体实现——为什么这个工具值得把照片交给它

1. **没有删除原语**。Op 代数只有 Copy / Rename / Quarantine；唯一移出机制是带
   write-ahead manifest 的隔离区。`pm trash empty` 是全程唯一 unlink 用户数据的
   路径：**所有**条目一律逐项列出、`--yes` 才动手，删之前还要从 root 逐级下降复
   核那条路径确实落在 `.pm/trash` 内，再在句柄上删；`clean-staging` 与 `dedupe`
   两类**另加**永久删除前屏障——**真读盘重 hash** 确认「归档层 + 备份盘」各一份、
   或归档层还留着一份活副本，且见证不能是即将删掉的那个对象自己（catalog 只用来
   定位见证，证据是那次读盘——快照不是证据）。其余记录（`supersede:` 的旧字节、
   `undo:`、`rollback-displaced:`、`doctor-c5:`）不受屏障管，由生成它的计划交代。
2. **两段式 + journal + 故障注入**。计划是磁盘上可 diff 的 JSON；执行先写意图
   再落位，写完复读核 sha；测试在**每一个协议检查点**注入崩溃并断言 doctor 能
   对账、undo 能回滚——不是"崩了大概没事"，是逐点证明。
3. **内核不信任何调用方**。十一条不变量在内核层强制：root 身份、计划格式、
   I11、`.pm` 可信性全部在锁内复检；执行期屏障（"归档层至少留一份活副本"）由
   内核在锁内调用，**该有而调用方没给 = 整批拒绝**，屏障返回值还要核对只做了
   降级——防的不是恶意，是"未来某个调用点忘了"。
4. **`.pm` 状态只经受信取用口**。打开后用 `GetFinalPathNameByHandleW` 在**句柄**
   上反查它绑定的路径（答案取自要读写的那个对象，开完再换目录也改不了句柄指向
   谁）；对象同一性按 `(卷序列号, 文件索引)` 判、hardlink 另查句柄上的 link count——junction / symlink / hardlink
   换名一类的库外读写被挡在这一层。路径字符串校验（`resolveUnder`）只是预筛，
   不是安全边界。
5. **判据与动盘是同一个跨进程事务**。凡「读证据 → 判定 → 写」整段进 I10 锁且
   证据在锁内取：执行屏障、trash empty、resolve、doctor --repair、catalog 回写、
   配置的全部四条读改写路径。两个 pm 进程并发也互相抹不掉对方的决定。
6. **对抗评审门禁 + 突变验证（轮次与收敛判定见 REVIEW-LOG，不在此手抄）**。每条写路径合并前过独立评审（NO-GO 逐条
   第一方核实——证实的修、证伪的公开记录在 [REVIEW-LOG](docs/REVIEW-LOG.md)，
   包括评审对了我错了的、和我此前文档言过其实的）；凡有自动化落点的承重闸配
   一个"删掉它恰好一个用例转红"的突变——绿灯证明闸在承重，不是测试恰好路过；
   没有落点的闸作为残余登记（REVIEW-LOG 各轮），不冒充突变覆盖。
7. **决定照片去向的路径不引未审依赖**。EXIF 读取是第一方最小解析器：只取需要
   的标签、统一边界检查、读不到即交人判断（fail-closed），不猜文件修改时间。
8. **GUI 永不直接碰照片**。Rust 壳层只做 spawn / 交 token / kill 三件事，一切经
   `pm serve`（127.0.0.1 + 随机端口 + Bearer token 常量时间比对 + Host/Origin
   校验）；serve 三级授权：**缺省只读**；`--writable` 开九个写端点——生成
   推送 / sort / 归档 / 相册 / 转换计划（写 `.pm/plans`；转换另写 `.pm/derived` 派生件，原文件
   不动）、记「暂不同步」决定与照片记录、改配置（主库路径只读）、登记备份盘——**没有一个碰
   照片字节**；AI 建议 `POST /api/suggest` 是只读级，只出建议；`--allow-apply` 才开
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
| 测试套件（418 例，整套序列化跑——进程级 stdout 重定向所需） | 10–40 s | `stack test` |
| GHC 警告 | 0 | `stack build` |
| 对抗评审门禁 | 逐轮记录（NO-GO 逐条第一方核实 → 类级修 → 聚焦复核；收敛以末节 verdict 为准） | [REVIEW-LOG](docs/REVIEW-LOG.md) |
| 突变验证 | 凡有可观测自动化落点的承重闸各配一个突变、配对用例转红（34–36 轮与 P7 各轮判别表全数通过；无落点者登记为残余） | REVIEW-LOG 各轮收敛证据 |

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

# 发布前：二进制脱敏扫描（用户目录 / %APPDATA% 段 / 仓库路径，UTF-8 与 UTF-16 两种
# 编码；模式全部运行期从环境派生；任一命中即退出 1）。0.6.0 起纳入发布链。
V=$(awk '/^version:/{print $2}' ../../package.yaml)   # 版本单一真源，别手抄
python ../../scripts/leakscan.py binaries/pm-x86_64-pc-windows-msvc.exe \
  target/x86_64-pc-windows-msvc/release/pm-ui.exe \
  "target/x86_64-pc-windows-msvc/release/bundle/nsis/pm-ui_${V}_x64-setup.exe"
```

CI（`.github/workflows/build.yml`）在 GitHub 的 windows-latest 上跑**同一条链、同一套闸**：版本一致闸 → `stack test`（含 750 行闸与文档漂移哨兵）→ `pm --version` 闸 → sidecar → tauri build（remap）→ `scripts/leakscan.py` → zip + NSIS 安装包 + `sha256.txt` 同一 run 产出；推 tag `v<版本>` 后 release job 把**同一 run** 的产物挂到 Release，说明附每个资产的 SHA-256（上面「安装」节的承诺就是这里兑现的）。Release 里的二进制不是本机编的。

## 路线图与已知限制

**路线图**（按需推进，不承诺时间）：

- ~~`pm vault ingest`~~ ✅ P6-D：pm 只拷 root 内（相册 + vault 类目两份计划），
  `_inbox→_done` 交调用方并打印显式步骤；第 32 轮门禁的 9 条 ingest finding
  已全修（执行次序闸收紧，见 REVIEW-LOG；33–37 轮连续收口「读口
  fail-closed」漏网：35 轮按 IO 读原语全集清点扫尽、36 轮关掉 I11 存在性布尔探针、37 轮关掉链接属性探针的塌 False），门禁收敛状态见 REVIEW-LOG 末节，真实 `_inbox` 首次使用只待用户裁定。
- ~~屏障协议的类型封闭~~ ✅ P6-A：`BarrierKind` 分类器 + 屏障只返回降级清单，
  升级/改写在类型上写不出来。
- ~~落位 rename 的句柄形态~~ ✅ P6-C：全部提交型 rename/unlink 走
  `SetFileInformationByHandle`（先验绑定 + 同句柄后验 + 回迁），名字口清零。
- ~~GUI 执行面~~ ✅ P7（用户裁定 2026-08-26）：`pm ui` 以 `--allow-apply`
  拉起，计划页两次点击确认后直接执行已存计划（执行链与 CLI 同源）；上线命令
  一键复制（`[portfolio] dir` + 两仓 push 目标可配；路径与 push 目标**解析后
  重渲染**——白名单语法、`/` 分隔、操作数前 `--`，而不是黑名单过滤后原样拼；
  pm 不执行 git）；档案 vault 侧新增 `/photo-publish` skill 作代执行入口。
- ~~相册通道 / AI 建议 / jpg 转换 / CI 发布~~ ✅ P8 → 1.0.0（用户裁定 2026-08-27）：
  Photography 为相片 SoT——`pm import --also-album` / `pm album add`、`pm convert`（Pillow 派生 jpg）、
  `pm vault note`、GUI 第七页「归档」+ 两个 AI 入口（`claude -p` 只读、只预填）；外部进程一把壳
  `Pm.Subprocess`；第一方全量审 + Opus 两轮门禁 + CI 单链（本 release 二进制由 GitHub Actions 出）。

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

公开仓即完整开发历史（2026-08-27 起）：早期提交里的本机路径已用 `<vault-root>` /
`<stack-root>` 占位重写（`git filter-repo`，逐提交扫描零命中），远端 `main` 与本地同源。
