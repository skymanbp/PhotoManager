# PhotoManager (`pm`)

Haskell 编写的照片库管理器：为 `D:\Photography` 三层照片库（Raw → 成片 → 相册）
提供带完整性校验的索引、归档、备份同步、命名治理与 vault 分发。

**设计与不变量：[docs/DESIGN.md](docs/DESIGN.md)**（先读 §2 十一条不变量）。
对抗评审记录：[docs/reviews/](docs/reviews/)（按时间摘要：[docs/REVIEW-LOG.md](docs/REVIEW-LOG.md)）。

## 使用

```
pm init --main D:\Photography    # 一次性：写配置 + root 标识
pm scan                          # 索引（首次全量 hash，之后增量）
pm                               # = pm status，总览仪表盘

pm import                        # 暂存区 → Raw\年\事件-Raw + 成片\事件 归档计划
pm backup init E:\Photography    # 一次性：登记备份盘（按 UUID 认盘，不认盘符）
pm backup                        # 主库 → 备份盘单向增量（EXTRA 只报告永不动）
pm clean staging                 # 仅清理「归档层+备份盘」都有同 sha 副本的暂存文件
pm vault status                  # 相册 ↔ vault 展示集六态差异（--json 兼容 sync_photos.py）
pm vault push --category landscape A.jpg …   # NEW 定类目拷入 vault；DRIFT 出裁决计划；
                                 # 结束打印显式 git 步骤（pm 不执行 git）
pm names                         # Raw 事件夹统一 Scheme A 计划（B 类月份从成片还原；歧义不猜）
pm versions                      # 版本组 / 非设计内精确重复报告（只读）

pm apply <planId>                # 执行计划（--dry 全量预览 / --only 1,3-5 部分执行）
pm resolve <id> --item N --keep src|dst|both   # 冲突裁决（src=旧目标先隔离）
```

所有命令默认只读（生成计划、exit 1 表示有事可做）；写盘要么 `--apply` 交互
确认，要么两段式 `pm apply <planId>`。pm 没有删除原语——唯一的移出机制是带
manifest 的隔离区（`pm trash`）。

## 构建

```
# --no-interleaved-output --dump-logs none 为必须：本机 ACP=CP936，stack 把
# 依赖包警告（含 •/» 字符）重编码回自己的 stderr 时会崩（GHC 9.10 二进制向
# 非 UTF-8 管道打印不可编码字符即 commitBuffer 崩溃，已实验证实；
# GHC_CHARENC 只影响 GHC 编译器自身，救不了 stack）。pm 自身在 main 首行
# 设 UTF-8（Pm.Win.setupConsole），无此问题。
stack build --test --no-interleaved-output --no-dump-logs   # GHC 9.10.3 / lts-24.46
stack install             # 把 pm 放进 %APPDATA%\local\bin
```

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
  报告；E2E undo 回滚有测试）+ `pm versions`（真实库定位 7 连号跨夹 ARW 重复
  与 相册 9275≡成片 9274 那 1 例外）—— 6 项真实改名已于 codex 十七轮 GO 后
  经用户裁定执行（见下方「真实写入」）；versions 处置仍待用户
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
- P4-2 Tauri GUI 骨架（`gui/`：仪表盘 + 计划浏览 + 看图分类）→ P4-3 `pm ui`
- P5 档案侧 skill/文档对接（含 sync_photos.py 退役指针改写）

## License

Apache-2.0 — see [LICENSE](LICENSE). Copyright 2026 skymanbp.

公开仓是脱敏快照（本机路径以 `<vault-root>` / `<stack-root>` 占位）；
设计文档中的库规模、事件夹名等来自作者真实照片库的实测记录。
