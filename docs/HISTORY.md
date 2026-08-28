# PhotoManager 开发史（P0 – P8）

> 从 README 移出的完整阶段日志（2026-08-25，README 按九段标准重构）。
> 逐轮评审的处置细节在 [REVIEW-LOG.md](REVIEW-LOG.md) 及其分卷（1 / 1B / 2 / 3 / 4）；
> 第 1–24 轮的评审原文在 [reviews/](reviews/)（设计攻击 + P2 + P3b/P4 两卷，共四份），
> 第 25 轮起原文未入仓，逐条处置写在各卷当轮节内。本文件按阶段记录「做了什么、为什么、验收如何」。

## 阶段

- P0 ✅ 脚手架 + init/scan/status（只读）
- P1 ✅ 安全内核（Exec/Journal/doctor/trash/undo/apply/resolve；矩阵逐行测试 + 双模故障注入）
- P2 ✅ import / backup / clean staging（计划器纯函数 + 双 root fixture 端到端；
  真实归档待用户 `pm apply`，备份盘验收待插盘 `pm backup init`）
- P2.1 ✅ codex 评审 12 项修复（计划带 root UUID + supersede 复合组自动复位、
  clean 执行期三副本重验 + trash 屏障、目标键 case-fold、Names 边角；
  评审归档 docs/reviews/2026-08-23-p2-codex-review.md）
- P2.2 ✅ codex 二轮复审补齐（返修 stem 组悬置、无 rootId 全路径 fail-closed、
  clean --apply 同走执行期重验、复位配对顺序感知 + trash 去重）
- P2.3 ✅ codex 三轮收口（execPlan 内核自卫、doctor 悬挂判定末事件化、
  stem 组按目标路径、bindExecRoot 身份优先；TOCTOU 类按 DESIGN §14
  威胁模型处置，裁定权在用户）
- P3a ✅ `pm vault status`（六态 + UNPUSHABLE 第七态；真实库与 sync_photos.py
  集合逐项一致 78/15/1/0/0/0；行为基线 docs/specs/；vault 目录零写入）
- P3b-1 ✅ `pm vault push`（I11 文本级守卫 + DRIFT→resolve supersede 复用 +
  RENAME BLOCKED(photos.json) 实测命中 + doctor/trash/undo --vault；
  真实写入待用户在 P4 GUI 里给 15 NEW 分类后再裁定）
- P3b-2/3 ✅ `pm names`（真实库 42 夹：31 合规 + 6 项计划 + 3 拒猜 + 2 双月名
  报告；E2E undo 回滚有测试）+ `pm versions`（真实库定位 7 连号跨夹 ARW 重复）
  —— 6 项真实改名已于 codex 十七轮 GO 后经用户裁定执行（见下方「真实写入」）。
  **2026-08-25 更正**：曾把 相册 9275≡成片 9274 当成"例外重复"，实为相册平铺
  下的**撞名避让**（设计内）；同轮还发现 Raw 事件夹里的 JPG 不必然是成片误放
  ——原片本来就是 JPG 时（相机直出／手机／RAW 遗失）它就是原片。判据补全后
  真重复从 15 组降到 8 组，处置工具待建
- P3b-4 ✅ codex 评审 6 major 全修复（组回滚占位隔离 ~displaced、
  vaultIgnoreGuard 加固（.git 文件/祖先仓/反规则）、apply 执行锁内重检 I11、
  缓存绑定 root 身份 + racy-clean 判据统一、UNSTABLE 第八态 fail-closed、
  bindExecRoot 恰一命中；128/128 测试；归档 docs/reviews/2026-08-24-*）
- P3b-5 ✅ codex 二轮复审收口（位移槽位序号 + doctor 核 sha + undo 剔除内部
  事务、守卫 canonical 路径 + case-fold 反规则、I11 下沉 Pm.GitGuard 由内核按
  role 无条件重检、缓存身份双 Just、备份发现全命中、requireRole 统一、递归
  目录指纹、names 文件占位预检；133/133 测试）
- P3b-6 ✅ codex 三轮复审收口（严格 opId/planId 解析、通配符反规则 fail-closed
  （git 2.52 实测）、内核拒绝匿名 root + I11 守卫对所有 role 生效 + 取锁前预检、
  requireMain 补齐 vault/backup/pickRoot/init 四入口、init/backup init 走同一
  守卫、目录指纹不跟随 junction；备份命令拆出 Pm.BackupCmd；144/144 测试）
- P3b-7 ✅ codex 四轮复审收口（规范十进制 opId + validatePlan 序号校验、doctor
  畸形 oid fail-closed、悬空 junction 占槽判定、root-id 三态 + 原子 no-replace
  建标识、requireWritable 把 I11 覆盖到全部 .pm 写入口、requireMain 补 apply
  缓存/clean 复验/trash 屏障；151/151 测试）
- P3b-8 ✅ codex 五轮复审收口（opId 的 planId 须为生成格式——路径型 oid 不再
  越出 root、readDigits 有界、slotOccupied 探测异常按占用、clean/import/trash
  身份校验先于任何读取判定、测试 fixture 不覆盖损坏 root-id；155/155 测试）
- P3b-9 ✅ codex 六轮复审收口（relPathOk/opPathsOk 统一校验一切可手编路径字段：
  计划 Op、journal Op 与 Done trashRel、manifest 记录；内核 relOk 换同谓词——
  `\evil`/`c:evil` 在 Windows `</>` 下是整体替换；`.pm` 内部目标拒绝，undo 的
  `.pm/trash/` rename 源除外；158/158 测试）
- P3b-10 ✅ codex 七轮复审收口（Windows 别名与 junction：`.PM`/`.pm.` 折叠剥除
  后再判、`canonicalizePath` 限域进 trash empty 唯一 unlink 与 Exec 三个落位点、
  trash 遍历不跟随 reparse point、catalog `enPath` 校验、undo/pendingTmp 补验；
  路径用例拆出 PathGuardTests；162/162 测试）
- P3b-11 ✅ codex 八轮复审收口（限域**基准自身**也可能被劫持：`resolveUnder`
  从基准逐级 no-follow 下降进 trash empty / Exec 三落位点 / doctor tmp 清理、
  canonical `.pm` 语义排除挡目录别名、`CREATE_NEW` 独占创建挡 hardlink 占位、
  `requirePmTrusted` 把 `.pm` 家族可信性并入 requireWritable 覆盖全部 `.pm`
  写入口、catalog 区分半写回退与语义非法拒绝；168/168 测试）
- P3b-12 ✅ codex 九轮复审收口（**动态**路径层与 hardlink：`.pm/tmp/<planId>`
  逐次限域挡住"固定层可信、动态层是 junction"的删库外文件；reparse 判定改按
  name-surrogate tag（云占位/Dedup 不再误拒）；journal/manifest 的 append 与
  plan/侧缓存的覆盖写加 link-count 与独占创建防护；`RootUntrusted` 让建身份的
  三条旁路也过闸；`pathAtOrUnder` 改三态消除 fail-open；173/173 测试）
- P3b-13 ✅ codex 十轮复审收口（**不再用白名单定义可信集合**：可信闸改为枚举
  `.pm` 下实际存在的每个条目——十轮点出 `backup-cache`/`vault-cache` 从来不在
  名单里，junction 化后 `pm vault status` 会替换库外的 catalog.json/meta.json；
  闸同时下沉到 loader（loadCatalog/readJournal/readManifest/loadPlan），覆盖
  status/versions/apply 这些命令层没盖住的读入口；侧缓存改 root-relative 受信
  接口；reparse 探测改四态（Unknown 的分辨在本轮仍靠 doesPathExist 二问，
  十一轮指出并于 P3b-14 修正）；176/176 测试）
- P3b-14 ✅ codex 十一轮复审收口（**`.pm` 状态文件的唯一受信取用口**：十一轮
  实证「拼路径 → 校验字符串 → 按名字打开」三个洞——深度 2 的 manifest 文件
  symlink 让 append 写进库外文件、读侧无 link count 让 hardlink 占名的
  catalog/plan 被零警告载入、校验与打开是两次独立解析。readPmState/
  withPmStateAppend/readSideCache 一口做完「完整路径逐级 resolveUnder → 只打开
  一次 → 句柄查 link count → 同一句柄读写」，catalog/journal/manifest/plan/
  root-id/侧缓存的**读与追加**改道；probeName 的 Missing/Unknown 改读
  GetLastError；`.pm` 是普通文件不再被当"尚不存在"；doctor 探测 Unknown
  fail-closed 且删除前重验完整路径；测试拆出 StateGuardTests；181/181 测试）
- P3b-15 ✅ codex 十二轮复审收口（十一轮收的是**读/追加**，十二轮点出同类的
  **写与定点探测**仍按名字：`saveCatalog` 的 tmp/base/.1/.2 轮转自身无任何
  解析——scan/backup 的「load → 长扫描 → save」窗口里 `.pm` 换成 junction 就会
  在库外建 tmp、删 `.2`、轮转（critical）；doctor 对 trash 载荷按名字核 sha，
  载荷换成库外 hardlink 会让 `--repair` 补写**虚假 Done**（major）；lock 裸开
  句柄无 link count；侧缓存读把失信压成缺席，让 `pm status` 静默 exit 0。
  修复：`resolvePmPath` 使用点解析 + `openStateLock` + doctor `probePmSha`
  （同句柄 hash）+ 侧缓存读保留三态并计入 status 退出码；`probeName` 的属性与
  错误码改由 cbits 单次 FFI 取得，消除 threaded RTS 的线程亲和性假设；
  新增 3 例并对新屏障做突变验证；184/184 测试）
- P3b-16 ✅ codex 十三轮复审收口（`OpRename` 的**源**允许是 `.pm/trash/…`
  （undo/组复位的唯一例外），而 doctor 对它仍用裸 `existsAny`——把
  `.pm/trash/<pid>` 换成 junction 即让复位源判成"不存在"，配上指纹相符的目标
  就得到 R2 Warn，`--repair` 补写**虚假 Done**（major）。同轮把限域助手
  `confinedTmp`/`confinedTrash`/`confinedUserPath` 从返回 Bool 改为**返回解析
  后的路径**，tmp 落位、rename、quarantine 三条路径只用返回值（**十四轮更正**：
  当时 Copy 的 dst 仍是 Bool 版 `confinedUser` 预检 + 重拼，"调用方只能用返回
  值"的绝对表述不实，P3b-17 删掉 Bool 版后才成立）。另修：我上一轮"对**每条**新屏障做
  突变验证"的说法过强（Catalog 只钉住整体撤回），现已为每一代快照单独构造
  文件级链接用例；新增 3 例，全部逐条突变验证；187/187 测试）
- P3b-17 ✅ codex 十四轮复审收口（十二轮设立的「拼 `.pm` 路径后按名字操作」
  判据下**清单首次为空**，但十三轮的修复自己引入了一条 major：把复位源的
  `existsAny`（文件**或**目录）换成受信探针时只写了 `doesFileExist`——
  **谓词在安全重构里被悄悄收窄**。trash 里真实存在的**目录**复位源被判成
  "不存在"，本该落 R3（不在修复白名单）的格退化成 R2 Warn，`--repair` 补写
  **虚假 Done**。codex 给的触发路径是 FpDir；实测不需要——现有 undo 构造器
  只产 FpFileSha，配上一个占了载荷名的目录就够。修复：探针改为调用点**显式**
  说明问哪种存在（`PmEntryAny` / `PmEntryFile`）；同轮删掉 Bool 版
  `confinedUser`，Copy 的 dst 也只用 `confinedUserPath` 的返回路径，
  `execCopyTmp` 不再持有 root。新增 2 例（FpDir / FpFileSha 两形态分开钉），
  突变一次两条同时转红；189/189 测试）
- P3b-17b ✅ codex 十五轮文档收口（两条代码判据——按名字操作 / 谓词宽度——
  首次**均判已收敛**、无需代码修复；NO-GO 只因两处文档 minor，已修；代码零
  变化）
- P3b-18 ✅ 闭合十四轮 #3 登记的覆盖缺口：此前没有用例钉住"限域助手**返回的
  路径必须被使用**"（把 Copy dst 改回 `root </> opDstRel` 重拼，旧用例照样绿）。
  按十五轮给的设计：root 本身放在 junction 上（`resolveUnder` 只 canonicalize
  base，合法用法），在 `CpCopyAfterFlush` 把它改指诱饵库 B——正确实现落在原库
  A、B 零改动；突变回重拼即落到 B、用例转红。顺带实证了十五轮标注的平台前提：
  A 内 journal/lock 句柄打开时 junction 可删除重建。190/190 测试）
- **codex 十七轮：GO** ✅（对 P3b-17c + P3b-18；生产逻辑零变化、两条收敛性判据
  维持、新发现无、最小修复集空——P3b 门禁自一轮以来首个 GO）。真实写入
  `pm apply 20260824-030200-0c238a`（6 项 Raw 事件夹改名，undo 可逆）转用户裁定。
- **真实写入 ✅**（用户裁定全量执行）：`pm apply 20260824-030200-0c238a` 6/6 DONE，
  doctor 0，status "索引与磁盘一致"——pm 对真实库的第一次 names 写入。P3 只剩
  等外部条件的项：备份盘三件套（插盘）、15 NEW 分类（P4 GUI）、versions 处置。
- **P4 改判（用户 2026-08-24）**：GUI 改 **Rust + Tauri v2 + 纯静态 HTML**，内核
  保持 Haskell（本机 cargo/tauri-cli/WebView2 已在，.NET SDK 不在，零安装）；
  §11 边界不变：GUI 独立进程、永不直接碰照片、一切经 `pm serve`。
- P4-1 ✅ `pm serve`（127.0.0.1 + 内核随机端口 + Bearer token 常量时间比对 +
  Host/Origin 校验；**只读端点** ping / status / vault status / plans / plan /
  thumb（仅 JPEG 原字节）；`Pm.Status` 拆成 statusReport（ToJSON）+ 渲染，CLI 与
  API 同源；6 例用 wai-extra 直接打 Application，五处闸各自突变转红；真实库
  冒烟：401/401/403/403/204、4855 文件、8 计划、4.1 MB 缩略原图、`netstat` 只见
  127.0.0.1；196/196 测试）—— 写端点（apply / 分类推送）留到 GUI 骨架之后，
  仍先过 codex 评审再请用户裁定
- P4-2/3 ✅ Tauri GUI 骨架 + `pm ui`（`gui/`：Rust 侧只 spawn `pm serve
  --exit-on-stdin-eof`、把 port/token 经 `api_info` 交给页面、退出即 kill；
  `ui/` 纯静态三页——仪表盘 / 计划 / 分类（NEW 缩略图网格 + 类目单选，无提交）；
  新只读端点 `/api/vault/new`；`pm ui` 只找 `pm-ui.exe` 并经 `PM_EXE` 交出自身
  路径，不自己起 serve。冒烟：GUI 拉起 → 127.0.0.1 新监听；只杀 GUI（不带 /T）
  → serve 500 ms 内靠 stdin EOF 退出、零残留；`hostOk` 改精确解析（十八轮）。
  MSVC 目标构建（`cargo build --target x86_64-pc-windows-msvc`）；197/197）——
  **写端点仍未开**，分类"提交"按钮与 apply 留到下一步并先过评审 + 用户裁定
- **codex 十八轮：GO**（P4-1 首评，无 critical/major；4 minor + 1 残余硬化全部
  同分支闭合：Host 精确解析、`--port` 范围、vault JSON 末尾 LF 逐字节用例、vault
  缓存刷新进程内互斥、thumb 读取前 `resolveUnder`（库外 symlink → 404，用例钉住）；
  200/200）
- **codex 十九轮：GO**（P4-2/3 + 十八轮闭合；GUI 边界确认——Rust 侧只 spawn /
  api_info / kill，页面无 XSS sink、无 POST；2 minor：blob URL 不 revoke 已修，
  跨进程 vault-cache 刷新争用登记残余）
- **用户开窗验收反馈**：分类页滚动后缩略图消失；要求更清晰优雅的 UX、快速上手、
  直观可视化，并点名三项状态可视化（vault 同步与差异 / Raw·成片·相册各层 / 备份盘
  同步）；裁定写端点"先做生成计划，apply 后置"
- P4-4/5 ✅ UX 重做 + 生成计划端点（`ui/` 四页：状态（分层卡 + vault 八态与差异
  清单 + 备份盘卡 + 下一步）/ 分类推送（GUI 侧 `createImageBitmap` 缩放缩略图——
  原图 4–75 MB 全分辨率解码是消失的根因；分段类目按钮 + 进度 + 「生成推送计划」）
  / 计划（表格 + 逐项明细，自动选中最新）/ 上手；数字键切页（P4-8 起五页）。serve 加
  `--writable`（`pm ui` 置位）与唯一写端点 `POST /api/vault/push-plan`（与 CLI
  共用校验/构造，只写 `.pm/plans`，64 KiB 上限）；三处闸突变各自转红；202/202；
  渲染经 DPI-aware 窗口截图自验四页含滚动到底）—— **apply 端点仍未开**
- **codex 二十轮：GO**（P4-4/5 首评；无 critical/major，合并前最小修复集**空**，
  6 minor。确认写端点边界成立：`--writable` 判定先于读体与任何写入、只读 serve
  下 POST 零写入；抽出的校验/构造与 CLI `runVaultPush` 逐行等价）
- P4-6 ✅ 二十轮收口 + 发布（203/203，GHC 警告 0）：5 条 minor 已修——同一 name
  重复指派 fail-closed（CLI/API 共用一处判定）、DRIFT-only 也能出纯裁决计划、
  缩略图缩放失败改挂占位符（不再回退原图）、分类页 single-flight + 忽略
  `ev.repeat`、首次建 root 的并发 500 改一次持锁；第 6 条（JSON 重复键/深嵌套）
  登记残余。打包：NSIS 安装包（CLI 作 sidecar 与 GUI 同目录，`pm_exe()` 补
  "同目录"查找）+ 免安装 zip；实测装到临时目录后 GUI 能靠同目录找到 `pm`、
  杀掉 GUI 后 serve 零残留、静默卸载后目录与注册表均干净。**apply 端点仍未开**
- P4-7 ✅ 第九态 HELD「暂不同步」（用户裁定：这批 NEW 先不同步，另给一个专门
  放"决定不同步"的分类，以后想同步再调整）——**不是 vault 的第四个类目**（那等于
  建目录把照片发出去），而是主库 `.pm/vault-holds.json` 里的本地决定：`new` 键
  不变、`newActive` 扣掉它、退出码不再报"有事可做"，push 拒收 held 文件，记录里
  存决定当时的 sha 以便照片一换就失效回到 NEW。CLI `pm vault hold|unhold` 与第二个
  写端点 `POST /api/vault/hold` 共用校验器；GUI 分类卡加第四个按钮、状态页加 HELD
  pill 与清单）。**codex 二十一、二十二轮连判 NO-GO**，两轮共四条 major 全部
  收口：决定的 sha 在**创建与复核**两处都改成本轮真实重算（吃 `(size,mtime)`
  缓存快路时，等长替换 + 还原 mtime 会让旧决定继续生效、或让新决定当场失效）；
  名单的读改写关进主库 root lock（I10，两个 pm 进程会丢更新）；取锁前补零写入
  身份预检（否则非法库会先落下 `.pm/lock`）；覆盖写崩溃留下的 `.tmp` 不再被
  读成空名单。**二十三轮 GO**，最小修复集空（212 测试；七道闸各自突变转红）
- **真实写入 ✅（用户裁定"这 15 张暂时先不同步"）**：`pm vault hold` 15 张，
  名单 15 条；`pm vault status` 报"其中 15 张已决定暂不同步，不计入待办"，
  相册仍 94 张、vault 类目仍 79 张、vault 仓 `git status` 零改动。随时
  `pm vault unhold` 或在 GUI 里改成某个类目
- P4-8 ✅ GUI 设置页 + 配置端点（用户裁定：vault / 备份盘 / photos.json / 并发数
  可在 GUI 改，**主库路径只读**）：`GET /api/config`（含每条路径的存在性、root
  三态、vault 的 I11 是否就绪）、`POST /api/config`（三态补丁：缺省=不动、
  null=清空、给值=设值）、`POST /api/backup-init`（与 CLI 共用 `backupInitRun`，
  为此把它拆成"结果 + 渲染"）；CLI 对称命令 `pm config` / `pm config set`。
  serve 的配置改 `IORef` 每请求读一次（改完立刻生效）、`writeConfig` 改原子替换。
  另加 `PM_CONFIG` 覆盖并把整个测试进程指到临时配置——**开发中实测**：一次突变
  让写端点通过，测试 fixture 的路径当场覆盖了本机真实配置（已复原并补了这道缝）
- **codex 二十四轮：GO**，最小修复集**空**（无 critical/major）。6 条 minor 全部
  收口，根因是同一条：配置文件在 XDG 目录、不在任何 root 的 `.pm` 下，于是
  **一条 `.pm` 写纪律都没继承**——现在补齐独占建 tmp、flush 落盘、跨进程配置锁
  （拿不到锁 → API 409，不再各写各的把对方抹掉），并让 `loadConfig` 认出"崩在
  删旧与改名之间"留下的 `.tmp`。另修：`"main": null` 曾被 aeson 的 `.:?` 当成
  "键缺省"而静默放行（同请求里的 workers 照改并回 200）；GUI 把并发数说成也管
  备份（备份盘另有默认 1，防 HDD 寻道抖动）；写成功后页面刷新失败会误报"没改
  成"。219 例，四道新闸各自突变转红
- **文档回归（本轮自查发现，非评审所报）**：上一提交为压 DESIGN 的 750 行预算
  把 P4-6 收口散文移进 REVIEW-LOG 时，**连同刚插入的 P4-8 设计段一起删掉了**，
  提交信息却写着"DESIGN §11 gained the settings-page and PM_CONFIG paragraphs"。
  已补回（§11 设置页 + 配置写纪律 + `PM_CONFIG` 三段），GUI 页数四→五一并改正
- P5-A ✅ `pm sort`（252 例，GHC 警告 0）：散落新照片（相机卡/下载目录）
  按 EXIF 拍摄时间分段 → 暂存区
  事件夹。补的是 `pm import` 明确不做的那一段（import 要求事件夹已存在且名字
  正确，「不猜」）。两种形态：不带参数=只读提议（列候选分段 + 打印每段该敲的
  命令），给齐 `--place`/`--event` 与 `--from/--to` 才生成拷贝计划。**分段只是
  提议**——真实库证明时间切不开事件（纽约与亚特兰大首尾相接，7 张连号 ARW 因此
  落进两个事件夹），边界由用户定；地点也只能用户给（实测相机零 GPS）。EXIF 读取
  是第一方最小解析器（只取一个标签、统一边界检查、读不到即交人判断），不引未审
  依赖——这条路径决定照片被移到哪。落位是**拷贝不是移动**，源卡零改动。
  六道原有的闸各自突变转红。
  **一轮对抗审查（4 视角 + 逐条独立反驳）改掉 10 条真缺陷**，按根因归六类一次
  改全：EXIF 的 fail-closed 契约（最重一条是子 IFD 走不通时回退到**文件修改
  时间**——返回错时间会把照片默默归错事件）；判定改按**目标位置**而不是
  "sha 在库里出现过"（后者会把合法属于第二个事件的照片静默丢掉）；侧车跟随
  主文件（否则清卡后调色参数永久丢失）；源 hash 前后双 stat + 逐文件 try，
  读取失败整批拒绝。此后连过两轮 codex 门禁：第 25 轮 6 条、第 26 轮 7 条，逐条第一方核实（第 26 轮有一条部分证伪），按根因各改一处。第 26 轮最重的一条不是新缺陷而是**跨模块的类**——校验性读取未限域，同样写法早已在 `pm clean staging` 的永久删除屏障里出厂，已收成一个 helper 两处共用。连过三轮 codex 门禁（25 轮 6 条、26 轮 7 条、27 轮 5 条），逐条第一方核实，其中两条部分证伪、三条是我方结论或期望有误并已公开更正。三十二道闸各自突变转红（纯核心 8 + IO 层 5 + 25 轮 7 + 26 轮 7 + 27 轮 5）。经过见 REVIEW-LOG。
- P5-B ✅ `pm dedupe`（277 例，GHC 警告 0）：把 `pm versions` 报出来的非设计内
  精确重复变成**逐份可裁决**的隔离计划。候选组直接取自 `versionsReport`——不另
  写一套判据，否则「看到的报告」与「能操作的计划」迟早对不上。每一份都是
  `NEEDS-DECISION`：留哪一份取决于事件夹归属、命名偏好、是否被外部引用，pm 判
  不出就不猜（I1）；用 `pm resolve --item N --unskip` 逐份批准。**不**绑复合组
  （那是「不可拆分」的意思，与逐份裁决相反），组的完整性改由**执行期屏障**保证：
  每次执行前确认该内容在归档层至少还留一份**活**副本，否则整批降级回待裁决。
  幸存者名单 case-fold 比对，读不出来（占用／ACL／hardlink）一律不算「还在」。
  同一道屏障在 `pm trash empty` 永久删除前再走一次。顺带把两处一直各写一遍的
  东西收成一处：执行期屏障表（`pm apply` 与 `--apply` 共用；P5-G 起装配点进一步
  收成 `executePlanNowWith` 一处、由内核在锁内跑）、「至少一份副本还活着」的
  循环 `anyCopyAlive`（clean 的三副本屏障与本屏障共用）。
  九道新闸各自突变转红。
- P5-D ✅ 关掉「解析路径 → 按名字打开」之间的 TOCTOU 窗口：改成「打开 → 用
  **句柄**反查它绑定的路径」，`resolveUnder` 降级为预筛。竞态做成了确定性用例
  （解析成功后再把中途一层换成 junction），并同时断言裸 open 在这一步会读到
  库外文件。剩下的窗口（`MoveFileEx`/`RemoveDirectory` 这类只吃名字的 API）
  写进了威胁模型，不再用一句"属安全软件范畴"带过
- P5-E ✅ GUI 第六个页面「整理新照片」（nav 第二位）+ `GET /api/sort/survey` / `POST /api/sort/plan`
  （都不执行）；`pm serve --exit-on-stdin-eof` 打完 announce 后静音 stdout
  （GUI 只读一行就丢掉 BufReader，此后无人排空那根管道）
- P5-F ✅ 档案侧对接：`sync_photos.py` **退役但保留**（它是 I8 的字段兼容基线，
  删了那条验收就没参照），检测口改指 `pm vault status`；两个 skill、vault
  `CLAUDE.md`、`record-structure-version.md`、`KB-维护速查.md` 指针一并改写。
  `photo-place` skill：看图给每段建议地点，只出建议、由用户确认，走同一条计划
  路径（pm 内核里没有任何 AI 判断）
- P5-G ✅ **判据与动盘收进同一个跨进程事务**（第 29 轮 critical，对抗复核
  未能驳倒）：执行期组屏障此前跑在 root 锁外，两个终端各跑同一计划的
  `--only 1` / `--only 2` 就能让同一内容的两份副本一起进隔离区。屏障改由
  内核在 `withRootLock` 内调用，装配点收成一处；「哪些种类要屏障」提成
  `kindNeedsBarrier`，**该有而没有 = 整批拒绝**。`pm trash empty`（全程唯一
  unlink 用户数据的路径）同根一并搬进锁内。四道新闸各自突变转红。
  同轮的另外 4 条 finding 塌缩成同一个根因：DESIGN §14 一句**无限定**的
  「取用口都走 openBoundTo」——改写成带作用域的保证 + 六条逐项登记的残余，
  代码只动 thumb 一行
- P5-H ✅ 第 30 轮门禁（换了跑法：五镜头 + 四段式逐字引用 + 聚类，命中率
  5/5）：同一根因——「读证据 → 判定 → 写」的事务边界由调用点手工拼装——
  再扫出四处证据在锁外的路径，一次修完：trash empty 的 manifest 视图、
  resolve 的锁内重载写回、catalog 回写的加锁 RMW、doctor --repair 整段
  进锁（锁被占退回只读诊断）；`pm init --force` 补进 withConfigLock（配置
  第四条读改写路径）；barrierDrift 冻结计划元数据。六道新闸各自突变转红
- P6-A ✅ 屏障协议类型封闭（路线图②，三十轮 F4 上游修法）：屏障从「返回新
  Plan」改「返回降级清单」，新 Plan 由内核构造——升级/改写 Op/改写元数据在
  类型上写不出来，barrierDrift 删除；两张表收成一个 BarrierKind（total 匹配，
  漏写 = -Wall 警告 + 运行期锁内硬崩；三十二轮更正此前「编译不过」的过强
  措辞——项目无 -Werror）。内核仅存自卫 = 清单自洽（序号存在且 StPending）。
  变异 2/2
- P6-B ✅ 第 31 轮 F1：侧缓存 catalog+meta 成对写进 I10 锁（backup-cache 与
  vault-cache 一处锁两类，二十轮登记的 vault-cache 争用残余随之关闭）；
  Pm.Lock 原语下沉进 Pm.Config（依赖方向），三态返回区分锁被占与 junction
  拒绝（vault-holds 事务在锁内经 computeVault 自持——压成一个 Left 会让全部
  hold 用例 exit 2，实测显形后改三态）。变异 1/1
- P6-C ✅ 提交型操作句柄化（路线图③）：moveBoundNoReplace（先验源绑定 +
  no-replace + 同句柄后验落点 + 不符回迁）与 deleteBoundAt（先验绑定 +
  FileDispositionInfo，终段不跟随）替换全部 9 处 moveFileNoReplace 与 **9** 处
  提交时 removeFile（1 处用户数据 unlink = trash empty + 8 处 pm 自有 tmp/
  轮转；三十二轮实数更正，此前误记 7）；moveFileNoReplace 删除。
  RemoveDirectory 清点为零使用。
  杀手锏用例：目标父层在 CpCopyAfterFlush 换成 junction——旧实现静默把照片
  落到库外并报 DONE，新实现后验检出、沿句柄回迁、项失败、库外零字节。
  变异 3/3（后验/落位先验/删除先验各杀恰好一条）。289 tests
- P6-D ✅ `pm vault ingest`（路线图①，§10.3 第 1/2 项）：非交互批量入库的
  机械层。一条命令出**两份计划**（主库 相册/ + vault 类目/，计划只属于一个
  root；主库在前，失败即停）；I5 冲突生成时即 NEEDS-DECISION；I7 来源登记 =
  主库 journal Intent 自带的库外 srcAbs，不新造记录；`_inbox→_done` 与
  photos.json 由调用方收尾，pm 打印显式步骤（同 I9 处理 git）。fail-closed
  校验全部错误一次列完。293 tests（289+4），变异 3/3（类目校验/I5 分流/
  源缺失各杀恰好一条）
- P6-E ✅ 第 32 轮门禁收口（执行者切换：codex 通道 4/4 空跑 → 独立多代理
  Workflow 五镜头 + 对抗复核；复核撞限额的 9 条由主线第一手补做）：29 条
  finding 聚 4 根全修——①ingest 完成判据一码三义（`PlanRun` 三态 +
  `fullyExecuted` 闸 + 预览两份都存盘 + I7 生成期耦合 + 收尾步骤闸）；
  ②ingest 补齐与 push 对齐的闸（requireMain / case-fold 重名 / 跨类目占名 /
  HELD 名单 / 源双 stat）；③句柄化找回名字口原语内建的鲁棒性
  （withDisposeHandle 补 err-32 100ms×20 重试 + mask 关句柄泄漏窗）；
  ④PM_CONFIG 在 configFilePath 源头 makeAbsolute（正斜杠/相对拼写不再被
  句柄后验误拒）。文档统一修 §6 落位协议等约二十处；REVIEW-LOG 拆卷。
  298 tests（293+5），变异 11/11 各杀恰好一条（10 主循环 + HELD case-fold
  补验；三十三轮 F3 更正此前误记的 10/10）。逐条处置见 REVIEW-LOG 第 32 轮
- P6-F ✅ 第 33 轮门禁收口（codex 恢复后首轮**钉 SHA** 评审，NO-GO，minset
  恰 1 条）：ingest 生成期 IO 异常逃顶——probe 与 mkItem 的读口无 try，
  `doesFileExist` 通过后源/目标被良性进程占住即让 CLI 崩溃（违反 §14 防
  崩溃）。修法与 pm sort 二十五轮同纪律：逐文件 try、错误聚合一次列完、
  退出 2 零计划；过深嵌套顺手拆出 `runTwoPlans`。另两条 DOC（Win.hs 重试
  注释措辞、变异计数 10/10→11/11 统一）当轮修。299 tests（298+1），变异
  2/2。逐条处置见 REVIEW-LOG 第 33 轮（本条目为三十四轮补记——当轮漏立）
- P6-G ✅ 第 34 轮门禁收口（codex 又 4/4 空跑 → 独立 Workflow 三镜头 +
  逐条对抗复核，钉 `972b049`）：minset 2 条同根——「读口 fail-closed」纪律
  从未全仓扫。①`computeVault'` 枚举-hash 主循环无 try（全模块唯一 try 在
  freshShaAt，二十三轮只修了那一个调用点）→ 读失败落既有 UNSTABLE 桶；
  连带 listFlatPhotos / photosJsonRef Either 化（枚举失败整体拒绝；photos
  引用读不出按「可能被引用」，不 fail-open）。②Exec 裸 sha256File 共 5 处
  （复核把镜头报的 1 处扩成 5）→ 逐口 try 给 OFailed。rule-09 全仓普查
  再扫 Doctor 6 处 / resolveKeep / Names 指纹并修。第三条 finding（c2 断言
  不判别）被复核**证伪**，只登记取舍。750 行预算四次拆分（VaultCore /
  ExecTypes / Apply / VaultHoldTests，字节级搬移 + 再导出）。305 tests
  （299+6），变异 6/6 各杀恰好一条。逐条处置见 REVIEW-LOG 第 34 轮
- P6-H ✅ 第 35 轮门禁收口（codex 钉 SHA `39edbb8`，NO-GO，minset 4 条 +
  1 DOC）：根因是三十四轮的全仓 grep **命中未逐一记账**——目录枚举口与
  控制文件读口两类整类漏网。①push 无项分支与 status 是两个出口谓词
  （二十一轮 hasDiff/hasDiffR 分叉同型复发）：UNSTABLE-only 时 `pm vault
  push` 报 0 → unstable 项收进 hasDiffR，出口判定只此一个谓词；
  ②Names/Sort 生成期枚举 → try + 错误明说 + 零计划 exit 2（与二十五轮
  sort、三十三轮 ingest 同纪律）；③Doctor（trashView/staleTmpFiles）→
  TRASH-ENUM/TMP-ENUM Bad 行且按白名单构造绝缘于 --repair，Trash
  list/empty 拒绝并明说，Serve `/api/plans` 结构化 errors（listPlans
  迁入 Pm.Plan）；④config.toml/`.gitignore` 控制文件读口 → Left
  （I11 核不了 = 不放行）。750 行预算引发 Pm.SortSource 拆出（字节级
  搬移）。308 tests（305+3），变异 3/3 各杀恰好一条。逐条处置见
  REVIEW-LOG 第 35 轮
- P6-I ✅ 第 36 轮门禁收口（codex 钉 SHA `49ba732`，NO-GO，minset 恰 1 条 +
  3 DOC）：I11 的 `.git` 存在性探测用 doesDirectoryExist/doesFileExist——
  布尔探针把 ACL/断网/介质错误吞成 False，而守卫里 False 的去向是**放行**
  （自身→祖先扫描→Right ()），合法 git root 探测失败时 `.pm` 会写进未被
  ignore 覆盖的工作树。修法与 P3b-13 同源：改走 `probeName` 三态，判定收进
  纯函数 `classifyGitProbe` 穷测（Unknown = Left 核不了不放行；surrogate
  含悬空判「有」，只引向更严一侧）；`findGitAncestor` 逐层同规则换型
  Either；canonicalizePath 一并 try。类界写明：布尔探针只允许出现在
  False→拒绝 的位置。3 条 DOC 当轮修（35 轮清点表补录三处已保护命中 /
  README-DESIGN 规模数字各注采样日 / 「Exec 唯一写盘」收窄为「唯一动照片
  字节」）。随后全仓布尔存在探针逐处分类（约 60 命中）：唯一 False→放行
  且无下游响亮失败兜底的是 `pm init` 配置存在闸（exists 塌 False 绕过
  --force 闸且丢 mold），同表三态化一并修。310 tests（308+2），变异 m24
  恰杀穷举表、m25 设计上双杀（穷举表 + 悬空 junction E2E）。逐条处置见
  REVIEW-LOG 第 36 轮
- P6-J ✅ 第 37 轮门禁 **GO、minset 空——收敛达成**（codex 钉 b68cb2e+
  0c48b28，216 次命令执行；attempt-1 被通道故障杀死、看门判据补「必须含
  verdict 行」后重跑）。五镜头全绿：F1 三态修法逐格核对、68 个存在性命中
  重扫无第二放行口、测试/变异/文档登记一致、读口回归无新第三类。GO 后按
  quality-over-cost 收口一处「评审归为已登记残余、第一方证实注释自辩不
  成立」的缺陷：Scan 树遍历的链接探针异常塌 False——junction 属性读瞬时
  失败后递归顺利跟过去、库外文件入索引。修同 Trash.linkish 纪律（非
  ENOENT 按链接跳过入错误桶）+ 该处 SomeException 收窄 IOException；同型
  四处清点（Trash/Exec 已保守为范式、SortSource 仅诊断行登记）。无确定性
  注入形态按 R2/R9 登记。310 tests，警告 0。随后第 38 轮聚焦验证轮对
  `6c6f049` **GO、minset 空**——修法逐格等价核对通过、同型清点无漏项、
  仅登记一处父提交既存的 freshnessSweep 报告面小洞；门禁含 GO 后收口
  在内全部过审。按用户裁定转入释放链（每个动盘步骤先摆清单 +
  AskUserQuestion）
- P6-K ✅ 释放链执行 + **0.5.0 发布**（2026-08-26，全部经用户 AskUserQuestion  逐步批准、每个动盘步骤先摆清单）：① /photo-inbox SKILL.md v2 落地档案 vault（档案 vault 仓 commit `204b20b`，不在本仓；机械层改走 `pm vault ingest`，AI 部分逐字未动）；② dedupe 计划 `d24f7e` 执行——8 份同 sha 重复隔离、8 份保留侧不动，事后 16/16 独立重算 sha 复核；③ 从备份盘找回 2 张 West America ARW（计划 `1d380a`，源/落位双侧 sha 核对）；④ 重生成备份计划 `00f28f` 并执行：1016 项 / 98.45 GiB（含 2 对 supersede 复合组，旧字节先入 E: 的 .pm/trash），按 8 GiB 分 13 段 `--only` 落盘——其中一段首跑在条目间隙被外因杀死（journal 0 条有始无终、tmp 孤儿 0、全段 77 项独立重算 sha 全中，零数据影响；教训：汇总脚本必须保留原始输出）；重生成对比归零（新增 0 · 更新 0 · 一致 4853 · EXTRA 21 只读）；⑤ clean staging 计划 `c947f5`：220 项 / 21.37 GiB 三副本确认后隔离（HELD 4 拒收待 `pm import`、待修改 21 不碰），事后 trash 落位 220/220、归档层+备份盘副本抽样深 hash 双侧全活；⑥ 版本 0.4.7→0.5.0（package.yaml / cabal 再生成 / Cargo.toml / tauri.conf.json 四处），310/310，警告 0；README 以 2026-08-26 实测刷新（4633 文件 / 459.4 GiB、增量扫描 19.4 s、真实写入台账补四条）；发布产物与公开仓快照见 README 安装节与 tag v0.5.0
- P7 ✅ 发布前全量自审 + 门禁收敛 + **0.6.0 发布**（2026-08-26 → 27）：① P7-A 39 轮前五项登记残余全清（freshnessSweep 读错不再算 gone、Status 读错计数进渲染/JSON/退出码、13 处 SomeException 收窄为 IOException、ACL 全拒注入夹具 `withDenyAll` 落地、Serve 拆出 ServeGuard）；② P7-B 超预算测试模块拆分（ServeTests/SortTests → 四文件，逐字搬迁）；③ P7-C/D 发布配置 + 上线命令生成（`[portfolio]`/`[vault] push` 三字段、`Pm.Publish` 纯文本生成 + 字符集闸，pm 永不执行 git，I9）、GUI 计划执行（两击武装/确认、ping.allowApply 事实门）+ 复制上线命令入口，`req()` 头覆盖 Authorization 的根因修复；④ P7-E/F 文档扫面 + 版本 0.5.0→0.6.0 四处；⑤ 39/40 轮门禁收口（P7-G 六根：fail-open 基目录、`$()` 注入、TOML 转义、`add -A`、武装重触发、归档拆分；P7-H：命令生成解析而非过滤、GUI 加载器 latest-request-wins、文档计数再派生）；⑥ 用户指令「发布前亲自审代码与架构、聚类→上游根因→类级修」→ P7-I 第一方全量自审八簇（R1–R8：三态存在探针、上线命令单生成器、Windows 名字合法性单点、路径绝对化、.pm 子目录先限域、resolveUnder 整段预检、单 hPut、backup init 盘符闸；330 测试，9 突变判红）+ P7-J 第二轮 ultracode 多代理 101 项 14 簇（PlanRun/CatalogLoad/ConfigLoad 三态贯通、rootsNested/checkConfig 汇点、单一真源上收、DocDrift 常驻哨兵；382 测试，45 突变）；⑦ 41 轮终审 NO-GO {1–7} → P7-K 四簇类级收口（α 判定与使用同原子域：backup init 锁内复验、init 孤儿 tmp 拒绝、serve 配置快照单 IORef、`openStateAppendTail` 同句柄查尾+追加；γ catalog 与 root-id 身份对账；β 六加载器失败路径 stale 丢弃；δ README 发布字段去手抄 + `caseReadmeSync`；389 测试，7 突变判红）；42/43 轮均 FINAL NO-GO（42 轮 minset {1} = 运行态证据 UNVERIFIED + 两条 GO-note；43 轮 minset {1,3,4}，其 #1 为同一条顺延）：除 #1 外三条在 P7-L/M/N 收口（`onException` 关句柄〔42 轮 GO-note〕、突变覆盖措辞去绝对化并纳入哨兵〔42 轮 GO-note + 43 轮 minset #3〕、REVIEW-LOG 环境记录改实〔43 轮 minset #4〕），#1 由 44 轮评审亲跑闭合——评审沙箱三次跑不全测试（pantry 锁 / %TEMP% / 受限令牌不能改 DACL，11 个 ACL 夹具 icacls exit 5），用户裁定保留沙箱；44 轮 codex 撞订阅额度，用户裁定改由 Claude Opus 5 评审（普通令牌，判据回到亲跑 389 全绿 + 哈希对上）→ **FINAL GO、minset 空**；四条 GO-note 聚成两根（文档对证据产物沿用记忆、句柄双关闭路径）在 P7-O 收口，同轮发布链泄漏扫描抓出 pm.exe 烤入 `Paths_photo_manager` 的构建机安装目录（0.5.0 同）→ 版本改走 CPP 宏 + exe 段 `other-modules: []` + 常驻钉（390 测试）；45 轮（Opus）NO-GO 两条文档项 + 4 GO-note 全按类收口 → P7-P（HISTORY 计数入哨兵、Paths 引用面清点 + 段落定位、`scripts/leakscan.py` 入仓（模式运行期派生）、`onException` 独占打开钉；突变 m1–m4 全红）；46 轮（Opus）NO-GO 一条 major——我驳回 removeFile 观测点时所引的 cbits/FILE_SHARE_DELETE 机制被同版本 GHC 探针证伪（openBoundTo 即 openBinaryFile）→ P7-Q 改记真机制、讹传哨兵扩条、exe stanza 全称断言、清点递归、README 扫描命令 bash 安全；47 轮（Opus 5）**FINAL GO、minset 空**，六条 GO-note 聚两根在 P7-R 收口（哨兵鲁棒性：exe stanza 断言先剔注释行、头须以 ':' 结尾，讹传哨兵改同行共现判据并扩到 src/app；记录精度：46 轮节两处转述订正、哈希行标产物路径、.hs 注释改指仓内 REVIEW-LOG），突变 m5–m8 全部按期望配对，产品代码零改动。390/390，警告 0，750 行预算：全部手写源码/测试/文档达标（生成物如 `gui/src-tauri/Cargo.lock` 不计）；发布产物与公开仓快照见 README 安装节与 tag v0.6.0
- P7-S ✅ 0.6.0 发布后结案（2026-08-27）+ **0.6.1 发布**：① 用户裁定公开仓改推**完整历史**——`git filter-repo --replace-text` 把 90 个提交里 18 个含本机路径的（用户主目录 / 档案 vault 路径链 / stack 目录）重写为 `<vault-root>` / `<stack-root>` / `V:\\vault` 占位，逐提交扫描零命中、提交说明零命中、HEAD 树哈希不变，`--force-with-lease` 替换远端 main（206aab3 → f21d76b），tag v0.6.0 树 == main 树；② 发布版 pm.exe 沙盒三层库端到端 68 步（四类写路径 28 对 sha 逐字节一致、真实库零写入）——观测缺口：干净库上 `doctor --deep` 与不带 `--deep` 输出逐字相同 → 结束加 Info 汇总行 + SweepTests 用例；③ F090 收口：发布版 pm-ui.exe 经 WebView2 CDP 探针六页实测，`style-src 'self'` 零违规 → CSP 收紧 + `caseGuiNoInlineStyle` 哨兵；④ 文档全量审计（4 维度 → 45 条 → 逐条对抗核实 34 条）聚五根类级修：README 安全叙述范围（trash 屏障只覆盖 clean-staging/dedupe、不经计划的写口清单）、README 命令提要对齐 `--help`（`resolve --unskip`、undo 反向计划、`vault ingest` 入常用命令、P0–P7）、DESIGN 里 P0 前旧计划残留（Root 记录字段、依赖清单、golden/编码回归未实现、torn-gap 键名、GET 端点清单、spawn 参数）、DESIGN-COMMANDS 三行（worker 数非 Root 属性、status exit 1 四来源、serve 响应字段、git 步骤取落位类目）、手抄轮次/状态措辞（DESIGN-COMMANDS 委托 REVIEW-LOG + 哨兵、REVIEW-LOG 卷首、HISTORY 42/43 轮与外仓 commit 标注）；七处「第六页」误编号（引入提交 fa5ba67 起即居 nav 第二位）改「第二页」；REVIEW-LOG 登记的「crossCat 需 ACL 夹具」不实 → `caseIngestProbeUnknown` 判红；⑤ 版本 0.6.0→0.6.1 四处 + Cargo.lock。393/393，警告 0；发布产物与 tag v0.6.1 见 README 安装节
- P7-T ✅ 第 48 轮（Opus 5）FINAL GO 收口（2026-08-27）：7 条 GO-note 聚两根类级修——α 全称声明对齐实测面（GUI 哨兵改词法判据、`DEEP-DONE` 已重读数扣除消失/读不出、`pm status` exit 1 口径加 `--cached` 限定、README 写口清单补 `serve --writable`）、β 记述可从产物重读（CSSOM 计数分写、e2e 按运行留档、HISTORY「第六页」误编号）；REVIEW-LOG 拆卷 4；0.6.1 发布件在 P7-T 树重建并复跑探针/e2e；393/393，警告 0
- P8-A ✅ 预算拆分（2026-08-27，零产品行为变化；P8 工作包第一步——用户 2026-08-27 七项：Photography 为相片 SoT、成片→相册通道、相册→vault `_inbox` 投影 + 分类 + 推送提示、AI 分类/定位 GUI 入口、非 jpg 一键转换、vault 侧技能更新、GUI 审查后全量文档、GitHub Actions 产二进制并发布收官）：理解阶段 ultracode 工作流（7 读者 + 综合简报 + 两路对抗核查，15 条驳回 / 22 条缺口聚类进计划）实测三个文件触顶——`Serve.hs` 750 → `Pm.ServeEnv`（会话环境）+ `Pm.ServeVault`（四个 vault 端点）逐字拆出、`app.js` 724 → `vault.js`（分类推送页 `window.pmVault` 工厂）、`DESIGN.md` 750 → `DESIGN-GUI.md`（§11 整节，存根留位）；读 §11 的三条 DocDrift 哨兵同 commit 改指向，`caseGuiNoInlineStyle` 改扫 `gui/ui` 全部脚本并要求每个脚本被 index.html 外链，新增 `caseLineBudget`（750 行预算首次自动化，CI 复用）；DESIGN §1.3 陈旧的「.gitignore 不含 .pm/」据实更正。394/394，警告 0
- P8-B ✅ 相册通道（2026-08-27；DESIGN-P8.md §19，用户裁定 R2 D′「不落 diff，diff 只报告」/ R8 `pm album add`）：① `Pm.Album`——`classifyAlbum` 五桶（拷贝 / 已在同 sha / 同名异容 I5 / 同批撞名 case-fold / 非 jpg）两条入口共用；② `pm import --also-album`：成片 jpg 同源第二份拷贝进相册，与成片项同 `piGroup`（Exec 组语义：成片没落位相册不执行）、返修耦合成待裁决不分组；③ `pm album add <事件夹>/<文件名>…`（`parseProcessedRel` 词法闸 + `resolveUnder` 实体闸 + fail-closed 全错一次列完）与只读 `pm album candidates`；④ `Ingest.jpegExt` 并入 `VaultCore.pushableExt`（`caseNoDeadNames` 加 jpegExt）；⑤ sort/import/album 三处计划收尾上提为 `Pm.Cli.emitPlanTo`；`test/AlbumTests.hs` 6 例（含 I7 组语义端到端）+ 突变 m1–m5 全红。400/400，警告 0
- P8-C ✅ 照片记录（2026-08-27；DESIGN-P8.md §21，用户裁定 R6 (a)+(b)——GUI 分类/定位落到主库侧记录）：① `Pm.VaultNote`——`.pm/vault-notes.json`（name / sha / category / location / coordinates / title / source / at），坐标 `lat, lng` 越界即拒、字段全部一次列完；② `pm vault note|notes` 与 `GET|POST /api/vault/notes`，状态 unsynced / pending / published / stale / unknown（photos.json 只读反查，读不出 fail-closed 不答 pending）；③ 与 HELD 的四处共用上提：`readPmRecords`/`writePmRecords`/`validateKeyed`（文件纪律）、`withVaultTxn reader`（事务）、`runDecisionCli`（CLI 壳）、`recordPost`（端点壳），hold 行为零改动；④ 测试夹具同样上提 `plantStaleCatalog` / `withForeignLock` / `withVaultWritable`（hold 用例改用，净减）；`--json` 清点哨兵改两处、`--writable` 五 → 六；⑤ 突变 m2 首跑未判红，查出「陈旧 catalog 命中 stat」夹具自 41 轮 catalog 身份闸起一直空转（`mkCat` 固定 id "m" ≠ `mkMain` 的 "main-rid" → 整份拒载 → 缓存为空），P4-7 两条同型用例同样空转——夹具改按真实 root id 写并把「载得进 + statHitStable 命中」写成断言，hold 补突变 m6。`test/VaultNoteTests.hs` 5 例 + 突变 m1–m6 全红。405/405，警告 0
- P8-C2 ✅ 转换（2026-08-27；DESIGN-P8.md §20，用户裁定 R4 Pillow 两段式）：① `Pm.Convert`——python 发现（`PM_PYTHON` → PATH）+ `import PIL` 预检 + 内嵌脚本经 stdin（16 位 1/256 缩放、alpha 合白底、EXIF/ICC 保留、q95/4:4:4）→ `.pm/derived/<源 sha>/<stem>.jpg.tmp` 无覆盖落位 → 派生件伪 Entry 走 `classifyInto`（相册通道判定参数化目标）出 OpCopy 计划：成片同事件夹 +（`--also-album`）相册，相册项经上提的 `attachAlbumItems` 与成片项同组 / 耦合待裁决（I7）；同批撞名（case-fold）、RAW、已是 jpg、层外、链接、缺索引全部一次列完 exit 2；派生件幂等复用、`--redo` 重派生；② doctor 对账 `.pm/derived` 四态（STALE/ORPHAN/TMP Warn → `--repair` 删；PENDING Info；枚举失败 `DERIVED-ENUM` Bad）；③ `caseByteExitCensus` 集合加 `Convert.hs` + DESIGN §4 据实扩（Convert 只删 pm 自建派生件）；`test/ConvertTests.hs` 3 例（真 Pillow）+ 突变 m1–m6 全红。408/408，警告 0
- P8-D ✅ 归档页端点 + AI 建议（2026-08-27；DESIGN-P8.md §22–23，用户裁定 R3 `pm serve` 拉起 `claude -p`、R6 (a)+(b)、R7 第七页）：① `Pm.ServeAlbum`——`POST /api/import/plan` / `GET /api/album/candidates` / `POST /api/album/add-plan` / `POST /api/convert/plan`，与 sort/plan 共用 `planPost` 壳；JSON 体读取上提为 `ServeGuard.withJsonBody`（五处合一）；② `Pm.ServeAi`——`POST /api/suggest`（只读级）：`PM_CLAUDE_EXE` → PATH 的 claude，`-p --output-format json --permission-mode plan --max-turns 8`，提示经 stdin，`PM_SUGGEST_TIMEOUT` 超时，`seSuggestLock` 满 409，classify ≤ 20 名 / place ≤ 12 段、每段 `evenSample 5` 张 jpg（只有 RAW 的段不交模型），围栏 JSON 解析失败 502 带 raw，响应带 cost；③ GUI 第七页「归档」（archive.js 三张卡）、整理页「AI 建议地点」（只预填、低把握 `<地点?>`）、分类推送页「AI 建议分类/地点」+ 每卡三格照片记录（hold → notes → push-plan）；数字键 1–7；④ DocDrift `caseGuiNavOrder` ①—⑦ + 新哨兵 `caseRouteRoster`（Serve*.hs 路由元组集合 = DESIGN-GUI 反引号端点集合）；`test/ServeP8Tests.hs` 6 例 + `fake-claude.cmd` 夹具；突变见 REVIEW-LOG。415/415，警告 0
- P8-E ✅ 档案侧技能与文档（2026-08-27；DESIGN-P8.md §24，跨仓：档案 vault 根仓只 commit 不 push）：`/photo-inbox` v3（入口 `pm vault status --json` 的 NEW − HELD，看图分类后 `pm vault push --category` + `pm vault note`，不再写 photos.json；`_inbox` 降为附录遗留通道）、`/photo-publish` v2（第一阶段加 `pm vault notes --json` 的 pending → photos.json 渲染，stale 交裁、unknown 停）、`_inbox/README.txt` 遗留横幅、档案 `CLAUDE.md` 子项目行 + skill 表补 `/photo-publish`、`KB-维护速查.md` §📸 改写、`record-structure-version.md` Change Log 一条；本仓只加 `.claude/skills/photo-place/SKILL.md`「与 GUI 的关系」一节。pm 代码零改动，415/415，警告 0
- 步 9 ✅ 第一方全量审修复批（2026-08-28；DESIGN-P8.md §20.1 写纪律 / §22 / §25 / §26）：7 视角评审工作流 11 项确认（C0–C10）、6 项否证，聚 A–H 八簇上游修——A `Pm.Convert.deriveOne`：派生件 tmp/终名完整相对路径 `resolveUnder` + `openFreshBinary` 独占创建后才交 python + `openStateRead` 单链接同句柄测 sha + `moveBoundNoReplace` + 整段 `withRootLock`；B 新模块 `Pm.Subprocess.runTool`（python 与 claude 同一壳：UTF-8 管道、整体超时 `taskkill /T /F` 杀整棵进程树、`PM_CONVERT_TIMEOUT` 600）；C `VaultCore.convertibleExt` 单一谓词（候选「非 jpg」栏与 convert 准入共用，RAW 两边不列）；D GUI 分类推送页：`/api/vault/new` 单列 `unpushable` 只读卡、heldInitial 只收本页名字、回显记录类目、suggesting 互斥；E `applyPlan` 的列表刷新移出 try；F `sameDerived` 先于转换拒绝同 sha 同名两源、`convertPlan` 撞名 fail-closed；G DESIGN §2 I2 七处隔离产地据实清点 + 哨兵 `caseQuarantineCensus`、vault status / doctor --repair 帮助文本、DESIGN-GUI `dropped`/502 措辞、README 信任项 4；H `planPost` try→500 带交代、suggest 取锁 mask、信封 `is_error` → 502、`scanDerived` 基目录是链接 → Bad。新用例 `caseDerivedGuards`（hardlink 占 tmp / symlink 与 hardlink 占终名 / 同源 / 超时，夹具 `slow-python.cmd`）；突变 s1–s9 判红（REVIEW-LOG）；417/417，警告 0。Opus 门禁一轮 NO-GO（F1 UNPUSHABLE 经 hold 通道回到页面 → `holdRequest` 拒 + `splitHeld` 归 stale；F2 `runTool` 喂 stdin 移进超时窗口三路并发 + `caseRunToolFlood`；F3 归档页警告专用行；F4 AI 在途用户改过的卡不覆盖来源；F5 沿用记录的类目虚线 + 进度分列；F6 超时用例改打派生路径；F7/F8 与 Exec 差一处的窗口登记为残余）→ 修后 418/418，警告 0。Opus 门禁二轮 GO，四条 minor 上游收口（N1 flood 用例只比 PING 前后差集；N2 用户拥有的卡不进 AI 请求、`source` 不被改；N3 子进程挂 job 对象、`terminateProcess` 整树杀替代 `taskkill /T`；N4 `newAssignable` 谓词：CLI「→ push」行与 GUI `new` 扣掉 UNPUSHABLE）；突变 h1–h3 判红；418/418，警告 0
