# PhotoManager (`pm`) — 设计文档

**版本**: v0.2 · **日期**: 2026-08-22 · **状态**: 已过对抗评审（§16）→ **用户已批准 v0.2 并开工**（裁定见 §15）；**实现现状以 [`DESIGN-COMMANDS.md`](DESIGN-COMMANDS.md) 的状态行为准**，本文件不复述版本号；P8 工作包（Photography 为相片 SoT）的裁定与设计在 [`DESIGN-P8.md`](DESIGN-P8.md)

---

## 0. 一句话定位

`pm` 是一个 Haskell 编写的照片库管理工具（CLI 核心 + `pm serve` loopback API + Rust/Tauri 桌面 GUI，§11），为
`D:\Photography` 三层照片库（Raw → 成片 → 相册）提供**带完整性校验的索引、
归档、备份同步、命名治理与 vault 分发**。所有写盘操作遵循
「计划 → 确认 → 校验写入 → 持久化日志」协议；**操作代数里不存在覆盖写与
删除原语**——数据安全由类型系统和执行协议双重保证，而不是靠小心。

---

## 1. 现状（2026-08-22 实测）

### 1.1 主库 `D:\Photography`（非 git，本地唯一副本；D: 为 NVMe SSD）

| 层 | 路径 | 规模 | 组织 | 实测观察 |
|---|---|---|---|---|
| 原图 | `Raw\` | 4110 文件 / 429.7 GiB | `年份\事件夹` | .ARW×3607 + 侧车 .xmp×152/.acr×60 + .dng×71/.psd×22/.JPG×180 |
| 成片 | `成片\` | 190 JPG / 4.9 GiB | `YY-MM-地点`（28 事件夹） | 有 `-L`/`-P` 分叉（24-11-Florida-L/P） |
| 收藏集 | `相册\` | 94 JPG / 2.5 GiB | **扁平** | 93/94 与成片精确同名（相册 ⊂ 成片） |
| 暂存 | `To-Be-Sync'd\` | 241 文件 / 22.2 GiB | `Processed\` `Raw\` `待修改\` | 5 个事件未归档（4 个 2026 新事件 + `23-04-EU` 返修，pm P0 首扫实测）；`Raw\2026\` 为空 |

**全库合计：4635 文件 / ≈459.3 GiB**（2026-08-22 P0 基线实测，本节四行之和；§12/§13 的规模输入统一用这组基线数。库在长大——现库数字见 README「效果」节的注日实测，两组各自为真，三十六轮 F3 注明采样日）。

**Raw 事件夹命名已统一为 Scheme A**（`YY-MM-地点-Raw` × **44**；2026-09-02 实测，
`pm names` → 已合规 44 · 待改名 0 · 待裁决 0 · 无法识别 0）。2026-08-22 基线时为 38 夹、
两套并存——Scheme A × **29**（如 `23-01-Cotswold-Raw`）/ Scheme B `RAW-YYYY-季节-地点`
× **7**（全在 2025，如 `RAW-2025-Winter-Alaska`）/ 无后缀 × **2**（`23-12-Turkey`、
`25-06-USA`）——由 `pm names` 计划（P3b 起）与用户裁定的人工改名分批收口，最后三个
`RAW-2025-*` 与两个 `&` 双月夹（拆夹）于 2026-09-02 结清（HISTORY 同日两行）。

**跨层同事件地点名不一致**：Raw 用英文（`23-07-Hunan-Raw`、`23-10-Zhenjiang-Raw`、
`23-10-Anhui-Raw`），成片用中文（`23-07-湖南`、`23-10-镇江`、`23-10-安徽`）。
事件关联必须支持地点别名。

**版本后缀实测清单**（同 stem 多版本，样本来自 相册/ 与 成片/）：
`-已增强-NR` `-Enhanced-NR` `-HDR` `_1 _2 _3` `_ps` `_d` `_L` `_16.9` `_16_9`
`-Red` `.2`（`DSC08887.2_1.JPG`）`~4-edit` `F`（`_DSC0264F.jpg`）`_hdr`。
**扩展名大小写混用**（`.jpg`/`.JPG` 各约半），一切扩展名比较必须 case-fold。

**To-Be-Sync'd 语义（用户确认）**：既是新片暂存区（待归档进主库），又是备份增量标记
（待拷到备份盘）。`Processed\` 含 `23-04-EU`（老事件返修）+ 2026 新事件；
`待修改\` 有 21 个散文件（与 相册/ 同 stem，如 `DSC08960.ARW/.xmp` ↔ 相册 `DSC08960.jpg`——返修中）。

### 1.2 备份盘（用户确认）

移动硬盘，**镜像 `D:\Photography` 目录结构**，可能落后（缺新照片）。当前未挂载；
盘符不固定 → 不能按盘符识别。**文件系统未知（NTFS 或 exFAT）**——`pm init` 时
探测并记录（§9）。

### 1.3 下游 vault（`<vault-root>\摄影作品\`，git → `skymanbp/photography-private`）

- `landscape` 49 + `portrait` 6 + `urban` 24 = **79 文件**（相册 94 → 最多 15 张未分发，待精确核对）
- `_inbox\`（gitignored）+ `_inbox\_done\`：/photo-inbox skill 的入口和归档区
- **硬规则**（`README.md` + `build_site.py` 注释）：
  1. 仓内三个分类目录必须保持**原图字节**（sha256 与 相册/ 严格相等——`sync_photos.py` 的 OK 判定依赖）
  2. 压缩只发生在部署层（`build_site.py` → `_site/` 3200px/q90/剥 EXIF 含 GPS → GitHub Pages）
  3. 分类目录只接受 .jpg/.jpeg（`build_site.py` 按 `suffix.lower()` 判，大小写不敏感）；**不自动 git push**
- vault 的 `.gitignore`：`_inbox/`、`.ce/`、`_site/`、`.pm/`（`.pm/` 于 2026-08-23 经用户批准追加，展示集仓 commit 2d81d36，I11 前提——见 §10.3 第 3 项；P8-A 据实更正，此前本行仍写「不含 .pm/（P5 需补）」）
- 下游的下游：portfolio `data/photos.json`——**以完整 GitHub Pages URL（含文件名）引用
  vault 文件** → vault 侧任何改名都会打断已上线 URL（§10.2 RENAME 策略据此定）

### 1.4 现有工具链（档案侧）

| 工具 | 职责 | 与 pm 的关系 |
|---|---|---|
| `<vault-root>/scripts/sync_photos.py` | 只读检测 相册↔vault：`OK/NEW/MISSING/RENAME/DRIFT/DUPLICATE`（sha256，退出码 0/1/2） | pm 逐字段兼容其 JSON schema（§10.1） |
| `<vault-root>/scripts/photo_exif.py` | 只读抽 EXIF/GPS | pm 不替代（Python 侧留用） |
| `/photo-inbox` skill | AI 看图分类 + 坐标反推 + 写 photos.json + 归档 _inbox→相册+vault | P5 优化：机械步骤改走 pm，AI 判断留在 skill（§10.3） |
| 档案 CLAUDE.md / KB-维护速查.md | vault 规则：派生副本永不手编、confirm-before-act、record 更新 | pm 作为跨仓工具遵守；P5 文档对接 |

### 1.5 开发环境

Windows 11（ACP/OEMCP = 936，见 §14 编码风险）· stack 3.9.3 · GHC 9.10.3 + 9.6.6
已本地安装 · boot 库含 Win32-2.14.1.0、process-1.6.26.1（实测）。目标 GHC 9.10.3；
具体 resolver 在 P0 脚手架时以「使用本地已装 GHC 的最新 LTS」为准实测确定。

---

## 2. 需求 → 不变量

用户四条要求（R1 数据安全零丢失 / R2 一目了然简单便捷 / R3 快且严谨零差错 /
R4 Haskell）落成以下**硬不变量**，每条都有机制背书，不靠自觉：

| # | 不变量 | 保证机制 |
|---|---|---|
| I1 | 任何 pm 操作不使任何仓库丢失字节或信息（含文件名） | I2+I4+I5；重命名旧名先持久化进日志再动盘 |
| I2 | **pm 没有删除原语，也没有覆盖写原语**。唯一移出机制 = quarantine（移入 `.pm/trash/` 保持相对路径 + manifest）。产地据实清点（步 9 C10；DocDrift `caseQuarantineCensus` 钉住引用 `OpQuarantine` 的模块集合，新模块一碰就转红）：`pm clean staging`（Clean）、`pm undo`（Undo）、supersede 复合——`pm resolve --keep src`（Apply，§6.5）、`pm dedupe`（Dedupe）、`pm doctor --repair` 的 C5 隔离计划（Doctor）、`pm diff` 备份盘更新的旧件（Diff，`supersede:backup-update`）、执行期回滚的位移件 `rollback-displaced:`（Exec） | `Op` 代数只有 `Copy/Rename/Quarantine` 构造子；落位一律走「目标存在即失败」的 rename（§6.1 步 7） |
| I3 | 每次写盘前有可打印的 Plan 且经确认；每个文件落盘后 sha256 复读校验（**缓存级**：捕获写逻辑错误/截断/串文件与缓存副本位翻转，不覆盖介质层损坏——介质层见 I3b） | Exec 只接受 Plan；写协议 §6.1 |
| I3b | 介质级验证为显式能力：`pm doctor --deep` 把 catalog 的**全部**条目重读重 hash 一遍（默认那次只复验上次 CleanShutdown 之后的 Done），`pm status` 显示「最久未验证字节的年龄」（`lastVerified` 随每次 hash 写进 catalog）。**没有轮转/抽样机制**——全库覆盖只有 `--deep` 一条路；落位后绕缓存重读的 `--verify-media` **尚未实现**（§6.6/§12 的它是设计预留） | §6.6 + §12 单列开销 |
| I4 | 所有 mutation 先写 intent、成功后写 done（append-only NDJSON），**带真实持久化屏障**：intent 在其效果落盘前 `hFlush + FlushFileBuffers`；Copy 的 done 可组提交，Rename 的屏障强制且不可组提交（旧名仅存于日志）。**追加前先封尾**：`.pm/journal.ndjson` 与隔离区 manifest 的每次追加都先查末字节，不是换行（掉电写了半行）就先补 `\n`，新记录绝不与残行黏成一条——journal 另落一条 `torn-gap` 标记把残行**封**成可识别的撕裂尾（§6.4） | Journal 模块（Win32 boot 库 `flushFileBuffers`，本机已验证存在）；`pm doctor` 对账 §6.4 |
| I5 | 目的地已存在且内容不同 → **conflict，停该项，不覆盖，无例外**。vault DRIFT 的 supersede 与备份盘更新**不是覆盖**：先 Quarantine 移出旧文件、再 Copy 落新字节（§6.5），旧字节始终在隔离区可还原 | Plan 生成期检查 + Exec 执行期二次检查 + 落位 rename 的 no-replace（ReplaceIfExists=FALSE）语义三重防线 |
| I6 | 断电 / 拔盘 / 进程被杀后，`pm doctor` 能检出半成品并安全恢复；恢复矩阵覆盖三种 Op 的全部协议步骤与掉电（journal 尾部丢失）模型 | §6.4 矩阵 + §13 两类故障注入 |
| I7 | 拓扑不变量持续可校验：vault ⊆ 相册；相册 ⊆ 成片 ∪ inbox-origin（journal 中有 ingest 来源记录的集合）；侧车与主文件同批移动 | vault⊆相册 由 `pm vault status` 的 MISSING 态校验；相册⊆成片∪inbox-origin **记录侧**就位（ingest 的 journal Intent 带库外 srcAbs），doctor 的判定侧未实现（§10.3 第 2 项）；侧车同批由 import/sort 的整组悬置保证 |
| I8 | 相册↔vault 差异与 `sync_photos.py` **逐字段值形状兼容**（六态 + 位置元组 + 16 字符截断 hash + 同一文件过滤集合含 .png，case-fold）；退出码仍是 0/1/2，但**语义自 P4-7 起收窄**：NEW 里已决定「暂不同步」的不再算差异（`new` 键本身不变，见 §10.2 第九态） | §10.1 + §10.2 |
| I9 | pm 绝不执行 git 命令（vault/portfolio 的 add/commit/push 都由用户手动）；对 portfolio `photos.json` 仅只读引用检查 | Vault 模块无 git 调用 |
| I10 | pm 单实例：mutation 前对 `.pm/lock` 打开句柄并 `hTryLock`（内核级锁，进程死亡自动释放，锁文件残留无害且无需删除）。三十一轮 F1 起**侧缓存成对写**也在此锁内——只读的 `pm vault status` / GET /api/vault/status 因此也会短暂独占它（锁被占则缓存本轮不刷新，报告不受影响） | base `GHC.IO.Handle.Lock`（Windows 走 LockFileEx） |
| I11 | pm 不在任何 `.gitignore` 未覆盖 `.pm/` 的 git 工作树内建立 root，**任何 role**（主库/备份/vault）一视同仁：`init` / `backup init` / `vault push` 建 root 前检查（经用户确认追加 ignore 行后才建），`pm apply` 取锁前预检 + 锁内按盘上 role 重检；检查是文本级白名单（恰含 `.pm/` 行；`!` 反规则不得含 `.pm` 或通配符 `* ? [ \`，pm 不实现 wildmatch）。**行的归一与 git 2.52 逐字符对齐**：只去掉一个尾随 CR（CRLF 行尾）与未转义的尾随**空格**——前导空白、尾随 TAB/NBSP 都是模式的一部分（`T.strip`/`isSpace` 两头剥会把 git 根本不认的行当成"已覆盖"而放行；2.52 的 `check-ignore` 对这些变体全答 NOT-ignored，已实测）。所有直接写 `.pm/` 的入口（计划保存、catalog/侧缓存、doctor --repair、trash、undo/resolve）经 `requireWritable` 同一守卫（P3b-7），`.pm` 下的**子目录**（`plans`/`trash`/侧缓存）一律经 `ensurePmSubdir`——先对完整相对路径 `resolveUnder`、再在返回的那条路径上 mkdir，次序反过来会在 `.pm` 是库外 junction 时先把目录建到库外再拒绝；建立身份的三条旁路（`init` / `backup init` / 首次 `vault push`）天然走不了它，改由 `readRootState` 的 `RootUntrusted` 态覆盖（P3b-12），`pm doctor` 每次复查 | §5 init + §10.2 P3b-6/P3b-7 + §10.3 |

**「快」的量化目标**（介质分列，§12）：`pm status` 默认含 stat-only 新鲜度刷新，
主库（NVMe、热缓存）< 10 s，`--cached` 纯读快照 < 2 s；备份盘（USB HDD、冷态）
全树 stat < 90 s。

---

## 3. 领域模型

```
Root      = { id :: UUID (写在 <root>/.pm/root-id.json，不认盘符),
              role :: Main | Backup | Vault,
              created :: UTCTime, fsType :: Maybe Text }  -- init 时探测记录（§9）
              -- 挂载路径与 worker 数不在 root-id.json，在 config.toml
Entry     = { relPath, size, mtimeNs, sha256, lastVerified, kind :: Photo | Sidecar | Meta }
              -- mtimeNs 一律是「本 root 上 stat 回来的值」，绝不跨 root 比较
Event     = 解析自事件夹名: { date, location, scheme :: A|B|Bare, layer }
VersionGroup = 同一规范化 stem 下的多个 Entry（跨层聚合）
Plan      = { planId, kind, rootPath, rootId :: UUID, createdAt,
              items :: [{ix, op, status, group :: Maybe Int}] }
              -- 持久化在 .pm/plans/<planId>.json，供 pm apply/resolve/审计。
              -- P2.1（评审 cx-1/cx-2）：rootId = 被变更 root 的 UUID，apply 前
              -- 重新发现并绑定执行 root（盘符会漂移，路径不是身份）；group =
              -- 复合组 id（supersede 配对），--only/resolve 按组闭包、执行层
              -- 组内失败自动复位、无 rootId 的旧计划拒绝执行
Op        = Copy { src, dst, expectedSha }
          | Rename { old, new, expectedSha | dirFingerprint }  -- 指纹供 undo 校验
          | Quarantine { victim, expectedSha, reason }
Journal   = append-only NDJSON:
            Intent(op) → Done(op, verifiedSha) | Failed(op, err)
            + CleanShutdown 标记（正常退出时写，doctor 据此界定复验范围）
Catalog   = snapshot (catalog.json, 原子替换写 + rename 前 fsync) + journal
```

- **Catalog 双层设计**：snapshot 是缓存（丢了可由重扫重建），journal 是耐久层
  （用户确认过的版本关系、地点别名、ingest 来源、历史操作全在 journal）。
  snapshot 保留最近 3 份轮换。
- **侧车绑定**：`.xmp/.acr` 与同 stem 主文件绑定为一组；Plan 保证组内同批移动，破组即 warning。
- **stem 规范化**：剥离 §1.1 后缀模式表（配置可扩充）；纯函数，property test
  保证 roundtrip 与二次规范化不动点。
- **扩展名判定全局 case-fold**（§1.1 实测大小写混用；与 `build_site.py` 的
  `suffix.lower()`、`sync_photos.py` 的大小写枚举集合等价）。

---

## 4. 架构

```
app/Main.hs                 -- 仅选项解析 + 分发；main 首行设置 stdout/stderr UTF-8（§14）
src/Pm/Cli.hs               -- 计划执行公共路径：root-UUID 绑定、组闭包、clean 执行期复验（P2.1 拆分）
src/Pm/Commands.hs          -- 各命令编排（P2.1 拆分；serve/GUI 复用同一路径）
src/Pm/Apply.hs             -- undo/apply/resolve 命令族 + pickRoot（三十四轮从 Commands 拆出，经其再导出）
src/Pm/Config.hs            -- TOML 配置（roots、别名、后缀表、portfolio photos.json 路径）
src/Pm/Catalog.hs           -- snapshot + 内存索引
src/Pm/Journal.hs           -- NDJSON append + 持久化屏障 + replay + 对账
src/Pm/Scan.hs              -- 增量扫描（stat 比对 → 变更集 → 并行 hash，worker 数来自 config.toml）
src/Pm/Hash.hs              -- crypton SHA-256 流式 + 目录指纹（FilePath 句柄；校验性读经 Pm.Win.openBoundTo 限域）
src/Pm/Diff.hs              -- 两个 Catalog → 六态差异（纯函数；只认 filename+sha，不看 mtime）
src/Pm/Plan.hs              -- Diff/规则 → Plan（规则/校验为纯函数；计划文件的存/取/枚举 IO 同在此——listPlans 三十五轮自 Serve 迁入）
src/Pm/Exec.hs              -- ★安全内核：唯一**写入/落位/改名**照片字节的模块（另两处只读的字节出口见下「关键结构性质 2」；pm 状态文件写口在 Config/Journal/Catalog/Plan/Trash，三十六轮收窄措辞；类型面在 Pm.ExecTypes，三十四轮拆出）
src/Pm/Removable.hs         -- 可移动介质瞬断保护（1.1.2，§6.4 末段）：盘在判据、IOException 三分、等盘/短停重试、扫描按 pass 续、执行按组续跑（内核之外的会话层；不写照片字节）
src/Pm/Derived.hs           -- .pm/derived 派生件对账口（1.1.2 从 Convert 字节级拆出，解 Doctor→Convert→Cli 依赖环；Convert 再导出）
src/Pm/Sort.hs              -- 卡/收件目录 → 分段提议与归位计划（源扫描层在 Pm.SortSource，三十五轮拆出）
src/Pm/Names.hs             -- 事件夹/文件名解析、规范化、rename 计划（目标唯一性校验）
src/Pm/Versions.hs          -- 版本组聚合报告
src/Pm/Vault.hs             -- 相册↔vault 差异 + push/ingest 计划（无 git 调用；纯核心在 Pm.VaultCore，三十四轮拆出）
src/Pm/Status.hs            -- 仪表盘：statusReport（数据，ToJSON）+ renderStatus（终端）；serve 与 CLI 同源
src/Pm/Serve.hs             -- wai/warp 127.0.0.1 JSON API（P4-1；供 GUI 桌面程序与 skill 消费，§11；传输守卫 Pm.ServeGuard、会话环境 Pm.ServeEnv、vault 端点 Pm.ServeVault 为 P7/P8-A 逐字拆出）
gui/                        -- GUI 桌面程序（Rust/Tauri v2，P4-2；独立进程，只经 API 说话，§11）
test/                       -- tasty: 单元 + QuickCheck + 双模故障注入 + 文档漂移哨兵（§13）
```

**关键结构性质**：

1. `Diff.hs`、`Names.hs` 与 `Plan.hs` 的规则/校验核心是纯函数 → 可 QuickCheck
   穷测（Plan.hs 另持计划文件的存/取/枚举 IO——三十五轮据实更正：「无 IO」在
   savePlan/loadPlan 落进该模块时即已过时）；
2. **照片字节只有三个出口，各自职权不同**（据实清点，`moveBoundNoReplace` /
   `deleteBoundAt` 全仓调用点）：
   - `Exec.hs` 是唯一**写入 / 落位 / 改名**照片字节的模块（`execCopyLand` 的
     `tmp → dst`、Rename 的 `old → new`、Quarantine 的 `victim → .pm/trash`），
     只消费 Plan → 照片 mutation 的审计面收敛到一个文件；它唯一的 unlink 对象
     是**自己刚建的、尚未落位的** `.pm/tmp` 文件（§6.1 步 6）；
   - `Commands.hs` 的 `pm trash empty`（`purgeLoop`）是唯一**永久删除**照片
     字节的地方，且只删已隔离、已登记、已逐项列出并经屏障复验的条目（§5）；
   - `Doctor.hs` 的 `--repair` 只删 pm 自建的**孤儿 `.pm/tmp`** 与 **`.pm/derived`
     里已落位 / 失源 / 半成品的派生件**（P8-C2），从不碰用户数据（在途 Intent
     的 tmp 更是明确不删，§6.4 C1）。
   pm 自有状态文件的写口另在 Config/Journal/Catalog/Plan/Trash 与 Convert 的
   `.pm/derived`（`--redo` 删旧派生件、失败清半成品；三十六轮据实收窄措辞，
   P8-C2 据实扩），各有锁与 fail-closed 纪律，不经 Exec；
   **Exec 内禁用 `directory` 的 `renameFile/renamePath/copyFile`**——三者在
   Windows 上均为「目标存在即原子替换」语义（directory-1.3.8.5 haddock 实测：
   `MOVEFILE_REPLACE_EXISTING`，且声明非原子保证），与 I5 相反；
3. GUI 与 CLI 共用 Plan/Exec 核心，GUI 没有旁路写通道；
4. `Op` 无 delete/overwrite 构造子 → I2 在类型层成立。

**依赖清单**（boot 库注明；其余为 Hackage 主流包）：`base directory filepath
aeson bytestring text time containers crypton
optparse-applicative ansi-terminal async toml-reader wai warp http-types
tasty tasty-hunit tasty-quickcheck temporary` +
boot：`Win32`（flushFileBuffers / SetConsoleOutputCP / createFile 等句柄工具；
提交型 rename/unlink 自 P6-C 起走 cbits 的 SetFileInformationByHandle）、
`process`（拉起 GUI 进程）。P4-1 实际加入：`wai warp http-types network memory`
（测试 `wai-extra`）。缩略图/看图渲染全部在 GUI 侧（Tauri WebView），
Haskell 侧无图像解码依赖。

> **P0 落锤（2026-08-22）**：直接采用 `FilePath` 全局方案，不引入
> file-io/os-string——评审 conf-12 已核实 Windows 上 FilePath API 同走 WCHAR、
> 正确性等价（file-io 增益主要是长路径），且 temporary/tasty-golden/warp 等
> 测试与服务生态均为 FilePath。长路径由「完整路径 ≥240 字符即计划期报错」
> 预检兜底（§14）。resolver = **lts-24.46**（本地 global project 同款，
> GHC 9.10.3 即由它安装）。

---

## 5. 命令面（CLI）

所有命令**默认只读**（打印报告/计划），写盘要么 `--apply`（展示计划后交互
y/N 确认；`--yes` 跳过交互供脚本用），要么两段式 `pm apply <planId>`。

这里的「写盘」指的是**照片字节**。计划文件本身是 pm 自己的状态：不给 `--apply`
时它照样落在 `<root>/.pm/plans/<id>.json`——两段式的第二段 `pm apply <planId>`
读的就是它，命令末尾也明明白白打印「计划已存 …／执行: pm apply …」。把这句话
读成"没有 `--apply` 就一个字节都不许写"会得出计划器违反不变量的结论（codex
二十八轮 #5 即如此，已第一方证伪）。
零参数 `pm` = `pm status`。**`--json` 只有 `pm vault status` 与 `pm vault notes` 两个**（`app/Main.hs`
两处 `long "json"`：status 为与 `sync_photos.py` 逐字段兼容，§10.1；notes 供 `/photo-publish` 消费，DESIGN-P8.md §21）；其余命令只有
终端文本形态，结构化消费走 §11 的 JSON API（`GET /api/status` 与 `pm status` 同源）；配置读写走 `pm config`（= `config show`）/ `pm config set`，见 §11。

| 命令 | 语义 | 写盘? |
|---|---|---|
| `pm init` | 交互式生成配置 + 各 root 的 `.pm/root-id.json`（含 FS 探测）；root 在 git 工作树内时按 I11 先补 `.gitignore` | 仅 .pm/ |
| `pm scan [root]` | 全量/增量索引（首扫全量 hash，之后 stat-比对；变更集才重 hash）。**进不去的子树按「查不出」承载**：ACL/IO 错误挡住的目录，其下的旧 catalog 条目原样保留（不当作"文件已消失"删掉），`pm scan` 末尾单列 `⚠ N 条…按「查不出」保留上次快照值（未核对）` | 仅 .pm/ |
| `pm status` | **总览仪表盘**：头行永远打印「索引时间（几分钟前）· 文件数」；各层规模、staging 待归档、备份盘滞后（未挂载则显示上次同步时间）、vault 差异、命名/版本问题计数、最久未验证字节年龄；**每个问题行末尾给出可直接复制的下一步命令** | 否 |
| `pm sort <源> [--place\|--event --from --to]` | **散落新照片 → 暂存区事件夹**（§7）。不带参数=只读提议：读 EXIF 拍摄时间、按间隔给候选分段、打印每段该敲的命令；给齐地点与区间才生成拷贝计划 | apply 时 |
| `pm import [--apply] [--also-album]` | To-Be-Sync'd 事件 → `Raw\年\` + `成片\` 归档计划；`--also-album`（P8-B）让成片里的 jpg 同源再拷一份进 `相册\`，相册项与成片项**同组**（成片没落位相册不执行）、返修项耦合成待裁决、非 jpg 只进成片（DESIGN-P8.md §19.2） | apply 时 |
| `pm album add <事件夹>/<文件名>… [--apply]` / `pm album candidates` | 成片 → 相册（P8-B，DESIGN-P8.md §19.3/19.4）：只收 jpg，相册同名同 sha 幂等跳过、同名异容 NEEDS-DECISION（I5）、同批撞名整批拒绝；`candidates` 只读列出还没进相册的成片 jpg 与成片/相册下的非 jpg | apply 时 / 否 |
| `pm convert <库内相对路径>… [--also-album] [--redo] [--apply]` | 非 jpg 照片 → 派生 jpg（P8-C2，DESIGN-P8.md §20）：第一段本机 python（`PM_PYTHON` → PATH）+ Pillow 经 stdin 脚本写 `.pm/derived/<源 sha>/<stem>.jpg`（16 位 1/256 缩放、alpha 合白底、EXIF/ICC 保留、q95/4:4:4；幂等复用，`--redo` 重派生），第二段 OpCopy 计划落成片同事件夹 +（`--also-album`）相册，判定与相册通道同一份（同 sha 跳过、同名异容 I5、I7 耦合分组）；RAW / 已是 jpg / 层外 / 同批撞名 一次列完 exit 2；原 tif/png **原地不动** | apply 时（第一段只写 pm 状态） |
| `pm vault note <文件> [--category C] [--location L] [--coordinates "lat, lng"] [--title T] [--source S]` / `pm vault note --clear <文件…>` / `pm vault notes [--json]` | 照片记录（P8-C，DESIGN-P8.md §21）：主库 `.pm/vault-notes.json` 一条本地记录（记录时 sha，字节变了 `stale`），文件读写壳 / 事务壳 / 端点壳与 HELD 共用；`notes` 标 unsynced / pending / published / stale / unknown（photos.json **只读**反查，读不出不答 pending） | 否（只写 pm 状态） |
| `pm backup [--apply]` | 主库 → 备份盘单向增量；**备份范围 = 主库 − 暂存区**（`To-Be-Sync'd\` 只是中转不进备份盘，2026-08-31 裁定；收窄在 `Pm.Diff.backupDiff` 单点，比对/缓存重算/status 全部继承）；备份盘多出的只报 EXTRA 永不动。**`pm backup init <盘上镜像路径>`（P2 落锤）**：插盘后一次性登记——写 role=Backup 的 root-id.json（含 FS 探测）+ 配置记 UUID+盘内相对路径，此后按 UUID 认盘 | apply 时 |
| `pm clean staging [--apply]` | **隔离区入口**：仅对「Raw/成片 已有同 sha 副本 **且** 备份 root catalog 也有同 sha 副本」（三副本确认）的 staging 文件生成 Quarantine 计划；不满足的标 `HELD(缺哪份)`；备份盘未挂载 → 不生成任何项，报「无法确认第三副本」。**`待修改\` 永不入清理计划（P2 落锤，与 §7 import 不碰同源）**；catalog 声称的两侧副本在计划期再过一次活体 stat 核对，变了降级 HELD | apply 时 |
| `pm vault status` | 相册↔vault **九态**差异：与 `sync_photos.py` 兼容的六态核心（OK/NEW/MISSING/RENAME/DRIFT/DUPLICATE，§10.1 兼容 schema）+ pm 自加的 UNPUSHABLE / UNSTABLE / HELD | 否 |
| `pm vault push [--apply]` | NEW→定类别后拷入 vault（类别来自 GUI 勾选或 `--category`/计划文件，**CLI 无法看图，不装作能分类**）；DRIFT→确认后 supersede 复合；RENAME→只报告/BLOCKED（§10.2）；结束打印显式 git 步骤 | apply 时 |
| `pm vault ingest <files> --category <c>`（P6-D，三十二轮收紧） | skill 调用的非交互批量入库：源（`_inbox`，库外）→ 主库 `相册/` + vault `<类目>/` **两份计划**（计划只属于一个 root）。预览两份**都**存盘（两段式对两份同样成立）；--apply 时 vault 那份只在主库那份**逐项真的落完**（DONE/同内容 SKIP——退出码 0 分不出 NEEDS-DECISION）后才执行，生成期再把「主库待裁决」耦合到 vault 同名项（I7：vault ⊆ 相册，相册在前）。I5 冲突生成时即 NEEDS-DECISION；校验含 case-fold 批内重名、跨类目占名、「暂不同步」名单（与 push 的 NEW/HELD 闸对齐）与源双 stat。`_inbox→_done` 与 photos.json 由调用方收尾，pm 打印显式步骤（同 I9 处理 git）且只在两份都落完时给。落实见 DESIGN-COMMANDS §10.3 | apply 时 |
| `pm names [--apply]` | 命名规范化计划（事件夹 scheme 统一、别名登记、同批目标唯一性校验） | apply 时 |
| `pm versions` | 版本组/精确重复报告 | 否 |
| `pm dedupe [--apply]` | **精确重复的逐份裁决计划**（§8.1）：来源就是 `pm versions` 的非设计内精确重复组，每一份出一个 Quarantine 条目、**全部** `NEEDS-DECISION`——留哪一份 pm 判不出就不猜（I1），用 `pm resolve --item N --unskip` 逐份批准。**不**绑复合组（复合组语义是不可拆，而这里要求逐份裁决）；组的完整性由执行期屏障保证：某个 sha 在归档层的最后一份**活**副本不会被隔离掉 | apply 时 |
| `pm doctor [--deep]` | 完整性体检：catalog↔盘对账、journal 对账（含掉电残留与撕裂尾）、半成品处置、I11 复查；**默认**对上次 CleanShutdown 之后的全部 Done 重 hash（工作量只有被中断那场会话，有界）；**`--deep` 另外把 catalog 的全部条目重读重 hash 一遍**（`DEEP` / `DEEP-CORRUPT` 行）。没有轮转/抽样档位：要么默认那个有界窗口，要么 `--deep` 全库。P8-C2 起另对账 `.pm/derived` 派生件（`DERIVED-STALE` 已落位 / `DERIVED-ORPHAN` 源已不在库 / `DERIVED-TMP` 半成品 → Warn，`--repair` 删；`DERIVED-PENDING` Info；枚举失败 `DERIVED-ENUM` Bad 不修） | 否 |
| `pm apply <planId> [--only 3,7-9]` | 执行（或部分执行）已存的计划；conflict 项只停该项、批次继续、末尾汇总。**P2.1/P2.2**：执行 root 按计划 `rootId` 重新发现绑定（Exec 拿锁后再验一次；无 rootId 的计划 CLI 层 fail-closed 拒绝，含 --apply 即时路径）；`--only` 自动扩到复合组闭包，**语法错误或序号超出 `0-N` 一律拒绝**（`--only 语法错误或序号超出计划范围（0-N）`，exit 2——不静默夹取，也不"照能认出的那几个跑"）；绑不上 root 时报文**逐槽位列出读不出身份的那些**（`缺席（尚未 init）` / `损坏: …` / `读不出: …`），而不是一句"均不符"宣称一次从未发生的 UUID 比对；clean 计划**每次执行前**逐项重验三副本（真实重 hash），不过的降级暂停——`pm apply` 与 `clean --apply` 即时路径无差别，无豁免 | 是 |
| `pm resolve <planId> --item N --keep src\|dst\|both` | 裁决计划中标 `NEEDS-DECISION` 的冲突项（both = 新名并存）。**P2.1**：`--keep` 只接受独立的 NEEDS-DECISION Copy（复合组成员不可单独裁决）；skip/unskip 扩到全组；`--keep src` 追加的 supersede 对共享组 id | 改计划 |
| `pm trash list / empty` | 隔离区查看（manifest ∪ journal ∪ 实际目录并集，孤儿标 UNREGISTERED）/ **唯一的最终清除入口**：逐项列出、二次确认，只 unlink 确认清单里逐项可见的条目，禁止整删目录树。**P2.1（评审 cx-3 终极屏障）**：reason 为 `clean-staging` 的条目在永久删除前按当前 catalog + 真实重 hash 再确认「Raw/成片 + 备份盘」各存一份同 sha 副本，确认不了 HELD 不删。**P5-B 起这道屏障一般化成一张表**（`barrierOf`）：`dedupe` 记录另走「归档三层还留着一份活副本吗」，与备份盘无关——一块没插的盘不该拖住与它无关的记录；无前缀的记录不受屏障管，仍需逐项确认。**清除过程中 unlink 失败即停**（占用/只读/句柄绑定不符）：打印 `✗ <路径>: <错误> —— 已清除 k/N 项，其余未动；解除占用/只读后重跑 pm trash empty`、exit 2——保守方向是少删不多删；manifest 不为失败的那批改写（清除成功的记录也照样保留为历史），重跑幂等 | empty 时 |
| `pm undo --last [n]` | 由 journal 生成反向计划：**仅对有 Done 的 op**；执行前逐项校验现盘内容 == journal 指纹，不符即拒绝并报告；supersede 的反向 = 从 trash 还原 victim 回原位（新副本转 quarantine） | apply 时 |
| `pm serve` | 起本地 JSON API（127.0.0.1 随机端口 + session token），供 GUI/skill 消费 | 经同一 Plan/Exec |
| `pm ui` | 启动 serve 并拉起 GUI 桌面程序（P4 交付） | 同上 |

**一目了然的日常三连**：`pm`（看仪表盘）→ 按提示跑对应命令看计划 → `--apply` 确认。

### 5.1 报告规格（R2 的硬形态）

**退出码**（与 `sync_photos.py` 对齐）：`0` = 无差异/全部成功；`1` = 有差异/
降级告警（如快照坏代回退）/计划待处理/部分 conflict；`2` = 错误（路径不存在、root 未 init、IO 失败）。

`pm status` 终端 mock（**既没有 `--no-color` 也没有 `--json`**：输出全程是无 ANSI
转义的纯文本，去色开关无对象；结构化等价物是 `GET /api/status` 的 `StatusReport`）：

```
pm · 索引 2026-08-22 21:03（4 分钟前）· 4635 文件 / 459.3 GiB
──────────────────────────────────────────────────────────
  Raw       4110 文件  429.7 GiB   ✓ 已索引
  成片       190 文件    4.9 GiB   ✓ 已索引
  相册        94 文件    2.5 GiB   ✓ 已索引
  暂存        241 文件   22.2 GiB   ⚠ 5 个事件未归档      → pm import
  备份盘     未挂载（上次同步 2026-07-30，当时落后 241 文件） → 插盘后 pm backup
  vault      79/94 已分发            ⚠ 15 NEW             → pm vault status
  命名       9 个事件夹不合规范                            → pm names
  验证       最久未验证字节 34 天                          → pm doctor
```

计划输出统一形态：`序号 | 操作 | 源 → 目标 | 大小 | 状态(OK/CONFLICT/HELD/NEEDS-DECISION)`，
末尾一行 `计划已存 .pm/plans/<id>.json —— 执行: pm apply <id>`。

---

## 6. 安全写协议（Exec 内核）

### 6.1 单文件复制协议（Copy）

```
1  stat src；与 Plan 前提比对（size/mtime 变了 → 该项 abort：源在被并发修改）
2  检查 dst：不存在 → 继续；存在且 sha 相同 → skip（幂等）；
   存在且不同 → conflict 报告（supersede 授权项走 §6.5 复合，此处仍不覆盖）
3  journal ← Intent(Copy src dst expectedSha)；hFlush + FlushFileBuffers
   （Intent 必须先于其效果落盘）
4  流式读 src → 写 <root>/.pm/tmp/<planId>/<name> + 算 sha
   （tmp 在目标 root 的 .pm 下：同卷保 rename 语义，且不污染 git 跟踪目录）
5  复读 tmp 算 sha —— 缓存级校验：捕获写逻辑错误（截断/错位/串文件）与缓存
   副本位翻转；不触及介质（介质级见 §6.6）
6  两个 sha 都 == expectedSha？否 → 删 tmp*，journal ← Failed，报错停该项
6.5 对 tmp 句柄 FlushFileBuffers（数据先于落位持久化）
7  落位：`Pm.Win.moveBoundNoReplace tmp dst`（P6-C 句柄形态：打开 tmp、**先验**
   句柄绑定、SetFileInformationByHandle(FileRenameInfo) 的 **no-replace** 提交
   ——目标存在即失败，directory 的 renamePath 带 REPLACE_EXISTING 会静默覆盖、
   Exec 禁用——再**同句柄后验**落点，不符沿句柄改回 tmp 名后响亮报错）；
   目标已存在 → 窗口内出现第三方 dst → journal ← Failed(DstAppeared)，
   保留 tmp 交 doctor，绝不重试覆盖；后验不符 → tmp 已回迁、项失败。
7.5 落位后复核：对 dst 再 stat + sha 一次（防撕裂），**dst 自己的 stat** 写入
   目标 root 的 catalog（不写源端 mtimeNs）。不符（或复核读不出来）**不是矩阵
   C5、也不交 doctor**：本项当场写 journal ← Failed（终态），doctor 的 pending
   折叠随即退役该 oid，它结构上看不见这一项。报文因此指向真正实现了的那条路
   ——`落位后复核失败（dst 内容不符、源未动；本项已记 FAILED，doctor 不再
   追踪——重新生成计划后用 pm resolve --keep src 裁决）`
8  journal ← Done(verifiedSha)；hFlush（Done 可组提交：批末或每 N 条
   FlushFileBuffers 一次——缺失的 Done 可由 §6.4 第 3 行从盘面重建）
```

\* 唯一允许 unlink 的对象是**本次自己创建的**、位于 `.pm/tmp/` 下且尚未
rename 的临时文件——不属于任何用户数据。（此外仅 `pm trash empty` 经二次
确认逐项 unlink 隔离区条目。）

### 6.2 Rename 协议（`pm names` 与 supersede 复合内部使用）

```
1  检查 new 不存在（Plan 期已查 + 执行期二次查，对齐 I5）
2  journal ← Intent(Rename old new 指纹)；hFlush + FlushFileBuffers
   （屏障强制且不可组提交：旧名仅存在于 journal，rename 一落盘即不可逆推）
3  `Pm.Win.moveBoundNoReplace old new`（先验绑定 + no-replace + 后验/回迁，
   同 §6.1 步 7；文件与目录同一原语——BACKUP_SEMANTICS 打开）；
   目标已存在 → conflict，不动
4  journal ← Done；hFlush + FlushFileBuffers
```

Plan 生成期校验**同批 Rename 目标唯一性**（防两条 Rename 撞同一 new）。
文件 Rename 带 expectedSha、目录带「直接子项名+size 指纹」——供 undo 事后校验
（不绑 NTFS 特性，备份盘可能是 exFAT）。

### 6.3 Quarantine 协议（写前日志式）

```
1  trash manifest ← 条目(victim 原路径, expectedSha, reason, planId)；FlushFileBuffers
2  journal ← Intent；屏障同 §6.2
3  `Pm.Win.moveBoundNoReplace victim (.pm/trash/<ts>/<相对路径>)`（同 §6.1 步 7）
4  journal ← Done；屏障
```

### 6.4 崩溃恢复矩阵（`pm doctor` 对账；三 Op 全覆盖）

| # | 盘上状态 | doctor 判定与动作 |
|---|---|---|
| C1 | 孤儿 `.pm/tmp/*` + Intent 无 Done（中断于写 tmp 阶段） | 报告；**`--repair` 不清除该 tmp**——它是在途 Intent 的证据。文案即 `--repair 不清除该 tmp（在途 Intent 的证据）；重跑原计划即可（重写从零开始，落位前覆盖它）`（"续传"同样不实：重跑走独占创建）。`--repair` 真正清的只有**不属于任何 pending Intent** 的孤儿 tmp（`TMP-STALE` 行）；清不掉时打印 `✗ 孤儿 tmp 未清除（…）` 并继续跑完其余修复，不中止 |
| C2 | dst 完好 sha==expected + Intent 无 Done | 补记 Done |
| C3 | dst 存在 sha==expected + journal **无任何记录**（掉电丢 journal 尾） | 按内容归属为已完成拷贝并补记 Done；backup 场景退化为 EXTRA 只读报告 |
| C4 | **Intent+Done 齐全但 dst sha ≠ expected**（硬件谎报 flush、劣质 USB 桥） | 报 **CORRUPT**，不删任何东西；staging/源那份标回「未确认归档」 |
| C5 | 步 7 撕裂：dst 存在但 sha≠expected 且有 Intent **无任何终态**（进程死在步 7 与步 8 之间） | Failed 半成品；`--repair` 生成 dst 的隔离计划（已不在 tmp，超出 unlink 授权，须经 `pm apply` 确认），源未动，重跑。**pm 没崩、只是步 7.5 复核不符的那种失败不在这一格**——它当场写了 Failed 终态，doctor 结构上看不见，走 `pm resolve` |
| R1 | Rename：{old 在 / new 无} | 未执行，重跑 |
| R2 | Rename：{old 无 / new 在} | 已执行；按指纹复核后补记 Done |
| R3 | Rename：{两者都在} | 未执行且目标被占 → conflict 报告，不动 |
| PM-LINK | Rename 任一侧的**存在性查不出**（ACL 拒绝、介质错误） | 用户侧存在性探测是**三态**（`probeName`：在 / 不在 / 查不出），查不出**不落进 R1–R3 任何一格**：报 `PM-LINK` **Bad**、不推导不修复。布尔探针会把"查不出"塌成"不存在"，{old 查不出 / new 在} 于是错读成 R2，`--repair` 补一条与真 Done 逐字节相同的**假 Done**（还会进 undo） |
| Q1 | trash 有文件 / manifest 无条目 | 标 UNREGISTERED，列给用户，不自动处置 |
| Q2 | manifest 有条目 / trash 无文件 + Intent 无 Done | 未执行，victim 应仍在原位，复核后清除该 manifest 条目 |

**源文件在所有 Copy 路径上未被触碰**；掉电模型（journal 尾部丢失）由 C3/R2
接住。`pm doctor` 默认对「上次 CleanShutdown 之后的全部 Done」重 hash（有界：
只有被中断那场会话）。

**会瞬断的可移动介质（2026-09-02 真实盘实录；1.1.2 起内建，`Pm.Removable`）**：
外置 USB 盘在持续 I/O 下约每 10 min 掉线一次（当日 11 次，最短 2 s 内重挂）。掉线
在内核里是**进程死亡语义**（本节矩阵接住），但裸重跑的代价是「每个已 Done 的
Copy 目标重 hash 判同」（§6.1 步 2，每次掉线白读几十 GB），且掉线落在「rename 落位
→ 写 Done」之间会留下 C2 格——重跑本身**不自愈**（Quarantine 看见原位是新字节，
报「victim 内容与计划时不符」，组闭包连带 Copy 不执行），只有 `--repair` 能补记。
1.1.1 时这些由仓内脚本在外面兜（分块 `--only` 续跑的看门狗，已退役）；1.1.2 把同一
套判据收进 pm：盘在 = `.pm/root-id.json` 读得出；一个 `IOException` 三分——确定性
一族（userError / 权限 / 已存在 / 非法操作…）原样抛出（测试注入与 pm 自己的
fail-closed 拒绝都在这一族，行为与 1.1.1 逐字相同），盘不在 → 等它回来（缺省
1800 s，`[backup] drive-wait`，0 = 关闭）再冷却 30 s，盘在而 EINVAL 一类 → 短停，
同一步骤最多 5 次。续跑单位：扫描按 pass（拿这一遍的 catalog 当旧快照重扫，只补
漏）；执行按**组**（`Pm.Cli.executePlanNowWith` → `execPlanRetry`：内核经
`ExecEnv.eeProgress` 逐项报进度；异常后等盘、先 `doctor --repair` 把 C2 / R2 /
Q-DONE-LOST 补上，再按「组内每项都 DONE/同内容 SKIP」或「组内每项 journal 末事件
都是 Done」结算——后者的结局从 JDone 记录（sha / trashRel）+ 一次 dst stat 重建，
形态与内核落位时相同——只把没结算的组交给下一场 `execPlan`，内核既有的崩溃恢复
分支接手：victim 已入 trash 且 sha 相符视同完成、dst 已同内容 SKIP，字节不重拷）；
`doctor --backup [--deep]` 整场幂等可重跑，`--deep` 逐条先等盘再探存在性（盘不在
时 `doesFileExist` 答 False，会把掉线报成「消失」），场末盘不在则整场作废重跑。
锁与 journal 句柄随会话死、随会话重开；两场之间无锁窗口只对同 root 的另一个 pm
可见（它拿到锁就是常规 I10 竞争）。写入后的**字节核验**仍是另一件事：走
`scripts/verify_backup_dst.py`（按计划 sha 全文重读）/ `verify_backup_entries.py`
（按备份 catalog 条目挑，如 `--verified-on <日期>`）或 `--deep`；两支脚本共用
`scripts/backup_verify.py` 的 `Drive`（同一「root-id.json 可读 = 盘在」判据）。
「已归档，冗余」标签**不由 Done 驱动**——它是当前 catalog
的 sha 集合判据（快照级提示，不是删除授权），据实更正见 DESIGN-COMMANDS §7。
**撕裂尾（掉电写了半行）不是损坏**：追加前先查末字节，不是换行就先补 `\n`
——新记录绝不与残行黏成一条（那会吞掉一条真实记录，并把残行从「末行半截」Warn
升级成中段 `CORRUPT-JOURNAL` Bad，undo 从此拒绝）；journal 另落一条
`{…,"e":"torn-gap"}` 把残行**封**住，读侧据此报 Warn `torn tail at line N
(sealed by a later append, expected after power loss)`。隔离区 manifest 走同一
追加口（同样先封尾，不写标记）；末字节查不出 → 抛错整项中止，不当无事发生。

### 6.5 supersede 复合（vault DRIFT / 备份盘更新共用，唯一的「替换」形态）

```
计划形态（P2.1 落锤，评审 cx-2/cx-4/cx-5）：[Quarantine, Copy] 两条目共享
同一 group id，是不可拆分单元——--only / resolve 的任何选择自动扩到全组。

① Quarantine{victim=dst, reason="supersede:<planId>"} → .pm/trash/<ts>/…（§6.3）
② ① 的 Done 持久化后，才写 ② Copy{src, dst, expectedSha} 的 Intent（§6.1）
   ——①之后 dst 已不存在，②在步 2 走「不存在→继续」：全过程无覆盖写
③ ②任何非成功结果 → Exec **同批自动复位**：journaled rename（oid 加 ~r 后缀，
   Intent+Done 齐全）把 victim 从 trash 移回原位；复位成功后 ① 的结果改写为
   未生效（catalog 不误删条目），复位被占位挡住则如实报告、旧字节留 trash。
   doctor 的 C4 豁免与 undo 的净零剔除都是**顺序感知**的（P2.2）：~r 只配对
   紧邻其前最近一次同 oid 的 Done——复位后同计划重跑成功产生的第二次隔离
   （Done 晚于旧 ~r）照常核查、照常可撤销；trash empty 对同 trashRel 的多条
   manifest 历史记录按路径去重，一个文件只 unlink 一次。
崩溃恢复：①与②之间进程死亡 → doctor 报 C1「重跑原计划」；重跑时 ① 幂等
   （victim 不在原位而本计划 trash 有内容相符文件 → 视为已隔离，续跑 ②）。
undo：复位对（①+~r）互为净零，不产生可撤销项；正常完成的 supersede 反向 =
   从 trash 还原 victim 回 dst，新副本转 quarantine。
```

### 6.6 介质级验证（I3b）

- `pm doctor --deep`（**唯一已实现**的全库复验）：重读重 hash catalog 的全部条目
  （`DEEP` / `DEEP-CORRUPT` 行），**没有轮转/抽样档位**；默认那次只复验上次
  CleanShutdown 之后的 Done。`lastVerified` 随每次 hash 进 catalog，`pm status` 据此
  显示最久未验证年龄。`--verify-media`（落位后 `FILE_FLAG_NO_BUFFERING` 绕缓存重读）
  **尚未实现**——全仓无该选项无该实现，§12 为它单列的开销是设计预留。

### 6.7 并发防护

- mutation 前打开 `.pm/lock` 句柄 `hTryLock`（内核锁，崩溃自动释放，I10）；
- Plan 带 (size,mtime) 前提，Exec 逐项复核（防 Lightroom 并发改动）；
- scan 对每文件 hash 前后双 stat，不一致 → 标 volatile 本轮不入索引。
- **判据与动盘是同一个跨进程事务**：凡是「读证据 → 判定 → 动盘/写回」的
  整段，必须整段在一把锁内完成，且**证据在锁内取**。落实清单（二十九轮 +
  三十轮 F1-F3）：执行期组屏障由内核在 `withRootLock` **内**调用；
  `pm trash empty` 从读 manifest 视图到唯一那次 unlink 整段在锁内；
  `pm resolve` 锁内重载计划再写回；doctor `--repair` 的「读 journal → 判定 →
  补记/删 tmp」整段在锁内（锁被占退回只读诊断）；执行后的 catalog 回写是
  加锁 RMW（锁被占则明说放弃，pm scan 可补）；侧缓存 catalog+meta 的**成对写**
  整段在锁内（三十一轮 F1，backup-cache 与 vault-cache 共用一个入口；锁被占
  = CacheLockBusy，降级为"本轮不刷新"，与 junction 拒绝的硬停是不同构造子。
  作用域（三十二轮登记）：锁只串行化**写者**；掉电停在 catalog 与 meta 两次
  replace 之间会留跨代对——换 vault 再换回的场景下旧 meta 会放行新 catalog，
  兜底是 sha 复用前逐条 (size,mtime)+racy 余量复验——`statHitStable`：上次 hash
  晚于 mtime 2 s 以上，**或** mtime 比当前时刻晚 2 s 以上（写入窗口尚未到来；
  1.1.1 补，此前未来 mtime 的文件每次扫描都重 hash）——缓存本身可重建）；
  配置的全部四条读改写路径
  （config set / API config / backup init / **pm init --force**）都在
  `withConfigLock` 内。进程内互斥（serve 的 MVar）不算——它挡不住第二个 pm。
  内核对「该有屏障而调用方没给」整批拒绝，缺席不会退化成静默跳过。

---

## 7–10. 归档 · 命名治理 · 备份同步 · Vault 分发

四节**已移到配套文档** [`DESIGN-COMMANDS.md`](DESIGN-COMMANDS.md)（2026-08-25）：

| 节 | 内容 |
|---|---|
| §7 | 归档（`pm sort` → `pm import`） |
| §8 | 命名治理（`pm names`） |
| §9 | 备份同步（`pm backup`） |
| §10 | Vault 分发与档案侧对接（含 §10.2 实现条目） |

搬家的理由不是"这几节不重要"，恰恰相反：它们是**逐命令**设计，随命令数线性
增长，而本文件是 750 行硬预算下的**全局**设计（定位、不变量、架构、安全写
协议、GUI、测试与验收、风险）。§16 早把"继续削散文"判为死路——P5-A 加 `pm sort`
时预算再次触顶，于是按这条边界拆开，而不是再削一次事实。

## 11. GUI（独立桌面程序，Rust / Tauri v2）

本节**已移到配套文档** [`DESIGN-GUI.md`](DESIGN-GUI.md)（2026-08-27，P8-A）：架构
边界（GUI 独立进程、永不直接触碰照片）、`pm serve` 的端点花名册与三级授权、写端点
契约、GUI 七页与 CSP、进程生命周期、设置页与配置写纪律、`PM_CONFIG`、打包发布。
搬家理由同 §7–10：P8 要往 §11 加端点与入口，而本文件 750 行预算已零余量。编号
沿用，跨文档引用照旧写 §11；读本节的三条 DocDrift 哨兵（页序、CSP 逐字、配置锁
清点）随之改读 `DESIGN-GUI.md`。

---

## 12. 性能设计（规模输入统一为 4635 文件 / 459.3 GiB = 2026-08-22 P0 基线；现库数字见 README「效果」节；D: 为 NVMe）

| 操作 | 成本构成 | 预期 |
|---|---|---|
| 首扫主库（459.3 GiB, NVMe） | 读 1× + SHA-256（并行，worker=核数） | 10-25 min，一次性 |
| 增量 scan 主库 | stat 全树 4635 + 变更集 hash | 热缓存 < 10 s |
| 增量 scan 备份盘（USB HDD 冷态） | stat 全树（单 worker） | < 90 s（P0 实测校准） |
| status | stat-only 新鲜度刷新 / `--cached` 纯快照 | < 10 s / < 2 s |
| **首次全量备份**（459.3 GiB → USB3 HDD） | 源读 1×（NVMe）+ 目标写 1× + 缓存级复读（CPU）+ fsync/文件 | 写吞吐 ~100-130 MB/s → **约 1.1-1.4 h**；`--verify-media` 再 +1× 目标介质读 ≈ +1.1 h |
| 备份增量 22.2 GiB | 同上 | ~4-7 min（cached）/ ~8-14 min（--verify-media） |
| `pm import` 22.2 GiB（NVMe 卷内） | 读+写+复读（CPU 级） | ~3-5 min |
| vault diff（相册 94 + vault 79） | 有 catalog 后 stat-only | 首次 ~1 min，之后 < 5 s |
| journal fsync | 1 次/文件（主库卷 NVMe）；备份路径 Done 即时 flush | 增量场景 < 数秒；首备 ~4635 次 ≈ 1-2 min |

内存：4635 Entry 全量驻留 < 10 MB；catalog.json ~2 MB；无数据库依赖。
SHA-256（crypton）单核 ~1-2 GB/s，多 worker 下 NVMe 场景磁盘先饱和。

---

## 13. 测试与验收

- **性质测试（QuickCheck）**：
  - P1 幂等：`apply(plan)` 后重扫 → 同方向 diff = ∅；再 `apply` = 全 skip
  - P2 journal replay 重建 catalog ≡ 快照
  - P3 **双模故障注入**：
    (a) 进程中断——free-monad 风格 Exec 在三种 Op 协议的**每个步骤间**强制中止；
    (b) 掉电——丢弃 journal 未 fsync 尾部 + 目标文件回退为零块/半写，模拟
    page cache 丢失。之后 `pm doctor` 判定必须与 §6.4 矩阵一致、源文件字节不变
  - P3b 介质损坏注入：步 4 后从 pm 背后改写 tmp 若干字节并使缓存失效 →
    协议必须报 Failed（这条测试是 I3/I3b 边界的守门人）
  - P4 `Names` roundtrip + 二次规范化不动点
  - P5 Plan 纯函数用例（PlannerTests；HUnit + QuickCheck，非 golden 快照）
- **fixture 树用例**（非 golden 快照——无 tasty-golden 依赖、全仓零快照比对）：小文件
  三层库 + staging + vault，含 `.JPG` 大写与 CJK 路径；文档漂移哨兵 DocDriftTests。
- **编码回归**（**尚未实现**）：设计是 `chcp 936` 下跑真实二进制、stdout 重定向到
  文件，断言退出码语义与 UTF-8 可解码；进程内用例捕不到这条路径，仍是空白。
- **真实库验证**：每阶段收尾对真实库跑只读命令核对；mutation 命令先 fixture
  树 + 用户指定的小事件试点。

### 分阶段验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| P0 | 脚手架 + file-io 冒烟 + Config/Catalog/Scan/Hash + `init/scan/status` | file-io 编译判定落锤；真实主库全量扫描成功；status 数字与 §1 实测吻合（4635/459.3 GiB）；主库增量重扫 < 10 s |
| P1 | Exec/Journal 安全内核 + `doctor/trash/undo/apply/resolve` | 双模故障注入全绿（11 个协议检查点中 8 个崩溃注入：Copy 5、Rename 2、Quarantine intent 后）；C1-Q2 矩阵逐行有测试对应 |
| P2 | `import` + `backup` + `clean staging` | fixture 试点 → 真实归档+备份，hash 复读零失配；`clean staging` 计划恰好覆盖全部冗余文件、HELD 逻辑正确、apply 后 doctor 对账通过、trash 可按相对路径还原 |
| P3 | `vault status/push` + `names` + `versions` | vault status 与 sync_photos.py **集合逐项一致**（含 .png、.JPG case）；names 计划经用户批准执行后 undo 可完整回滚 |
| P4 | `pm ui`（仪表盘 + 计划确认 + 看图分类） | GUI 完成 vault push 逐张分类全流程 |
| P5 | 档案侧 skill/文档整理优化（§10.3 五项） | 跨仓 diff 逐项经用户确认落地；/photo-inbox 走新机械层跑通一轮真实 inbox |

---

## 14. 风险与对策

**威胁模型（P2.3 明文化，P5-D 收窄）**：pm 防**崩溃/掉电/介质错误/并发良性
进程**（Lightroom、资源管理器等）。同机恶意进程的毫秒级 check-use 竞争
（TOCTOU）此前整类留白，**P5-D 起读写取用口这一半已经关上**：

- **走 `Pm.Win.openBoundTo` 的取用口**——先打开，再用
  `GetFinalPathNameByHandleW` 在**句柄**上确认它绑定的正是那条路径。因果方向
  变了：答案取自要读写的那个对象。开完之后再怎么换目录都改不了句柄指向谁；
  开之前换过，则实际路径与期望不符、当场拒绝。`resolveUnder` 因此**不再是
  安全边界**，只是预筛。用例把竞态做成确定性事件（解析成功之后再把中途一层
  换成 junction），并同时断言**裸 open 在这一步会读到库外文件**——否则只证明
  新写法拒绝了，不证明它拒绝的是真实存在的危险。

  **作用域**（二十九轮：此处此前无限定，是四条 finding 的共同来源）：
  `.pm` 状态文件的三个打开口（`openStateRead` / `openStateAppendTail` /
  `openStateLock`）、内容探测 `probeConfined`、以及 GUI 的 `GET /api/thumb`。
  **不含** Exec 三条 Op 里的用户数据内容读（`sha256File`）——见下。

- **剩下的窗口**（逐条登记，不是"属安全软件范畴"一句带过）：
  1. ~~`MoveFileEx` / `RemoveDirectory` 名字口~~ **已关（P6-C，路线图③）**：
     全部提交型操作改句柄形态——落位走 `Pm.Win.moveBoundNoReplace`（打开源、
     **先验**句柄绑定、`SetFileInformationByHandle(FileRenameInfo)` no-replace、
     **同句柄后验**对象落点，不符即沿句柄改回原名再响亮报错）；`pm trash
     empty` 的唯一 unlink 与全部 tmp/轮转清除走 `deleteBoundAt`（先验绑定 +
     `FileDispositionInfo`，终段不跟随）。`RemoveDirectory` 经清点在 pm 中
     **从未被使用**。残余缩小为：目标侧做不到先验（文档明确
     `SetFileInformationByHandle` 的 `RootDirectory` 必须为 NULL）——后验是
     **提交后检出**而非阻止；后验不符时对象要么被沿句柄改回原名，要么停在
     报文给出的实际落点（反查失败时报「未知」，见第 5 条）——字节不丢、
     错误响亮，不再有任何静默错位。
  2. Exec 的内容复核（`sha256File`）按名字打开：**Rename 的旧名复核、
     Quarantine 的 victim 复核**读后紧跟同一路径上的落位——落位自身已有先验 +
     后验（见 1），读口伪造的收益只剩让一次操作失败得更晚；**Copy 的落点同
     内容判定**没有后续 move，伪造相等只会让该次 Copy 静默跳过
     （`OSkippedIdentical`），旧字节仍在 trash，doctor 对账可见。仍不换
     `openBoundTo`：那只是把"读到谁"绑住，动作侧的保证已在 1 里给足。
  3. `openBoundTo` 只比对**路径**，对库内 hardlink 判是。所以它关掉的是竞态
     那一半，别名那一半（同一对象两个名字）要靠 `FileId`，thumb 尚未用它。
  4. `handleIsAt` 的路径规范化是手写的（去 `\\?\` 前缀、按分隔符切、折
     大小写），对 `\\?\UNC\`、卷 GUID 路径、8.3 短名、尾随点/空格、NFC/NFD
     未逐一处理；P6-C 起提交侧 `rawBoundTo` 共用同一比较。方向是**多拒**
     （比不上就拒绝，fail-closed），不是放行——但提交侧的多拒是把功能锁死
     而非只拒读，所以路径入口必须先归一：三十二轮 R3 把唯一不经 canonicalize
     的入口（`PM_CONFIG`）在 `configFilePath` 源头 `makeAbsolute`。
  5. 挂载卷若无 DOS 路径，`GetFinalPathNameByHandleW` 反查失败 → 判否 →
     该配置下取用口全部拒绝。已知代价，非静默失败。
  6. **库外源目录不做限域**：`pm sort` 的卡/收件目录不在任何 root 之内，
     `Pm.Exif.readCaptureTime` 按名字打开是设计如此（源根自身是 junction 属
     合法用法）。那里没有边界可越——能换掉源文件的人已经能写那个目录。

  设计保证不变：即使被击中，字节也只会进 trash 而非消失，且 `pm trash empty`
  在永久删除前重验三副本（终极屏障），该屏障走的是已绑定的 `probeConfined`。

逐项分析见 `docs/reviews/2026-08-23-p2-codex-review.md` 三轮章节与
REVIEW-LOG 第 28 轮。

| 风险 | 对策 |
|---|---|
| **Windows 输出编码（ACP=936）**：GHC 默认 CP936，emoji/勾号直接崩进程、重定向输出 GBK 字节（本机已实测复现） | main 首行 `hSetEncoding stdout/stderr utf8`；`--json` 走 ByteString 直写绕开编码器与 CRLF；console 场景 `SetConsoleOutputCP(65001)`；§13 编码回归测试（**尚未实现**，见 §13） |
| `directory` rename/copy 的替换语义（静默覆盖） | Exec 禁用清单 + 一律 `Pm.Win.moveBoundNoReplace`（句柄形态 no-replace，§6.1/§6.2）；P1 测试覆盖目标已存在分支 |
| 掉电/谎报 flush/劣质 USB 桥 | 持久化屏障（I4，含追加前封尾 + `torn-gap` 标记）+ 矩阵 C3/C4 + doctor 默认复验窗口（上次 CleanShutdown 之后的 Done）+ 显式 `pm doctor --deep` 全库重 hash（§6.6；**无轮转档位**，全库覆盖要人主动跑 `--deep`）；会反复瞬断的盘由 `Pm.Removable` 内建等盘续跑（1.1.2；§6.4 末段，2026-09-02 实录：当日掉线 11 次、527 组更新落位并核过）+ `scripts/verify_backup_dst.py` 写后全文重读 |
| 长路径 (>260) / Unicode 路径 | file-io（long paths）或 FilePath 方案 + ≥240 预检（P0 落锤）；CJK 路径入 golden |
| 备份盘符漂移 / 弹「请插入磁盘」框 | marker UUID + SetErrorMode + 只探 REMOVABLE/FIXED（§9） |
| exFAT 备份盘（无元数据日志、rename 原子性弱） | 矩阵不依赖原子性；FS 类型/粒度入 root-id.json；mtime 只做同 root 缓存键（§3） |
| Lightroom / 用户并发改文件 | Plan 前提复核 + 双 stat + 落位 no-replace 三重防线；杀毒/索引器的短暂占用按 Win32 同款预算重试（100ms×20，三十二轮 R1）；读口（sha256File/目录指纹/枚举）的 IOException 一律落 fail-closed 桶而非逃顶——vault 主循环入 UNSTABLE、Exec 逐项 OFailed、生成期整批拒绝、doctor 报「读取失败」行（三十四轮全仓 grep、三十五轮按 IO 读原语全集清点补漏——目录枚举口与 config.toml/`.gitignore` 控制文件读口；三十七轮链接属性探针查不出按「是链接」跳过不递归、不塌 False；执行期**写口**逃逸 = §6.4 进程死亡语义，journal 有 Intent、doctor 对账，登记为已设计行为） |
| catalog 损坏 | journal 重建 + 快照 3 份轮换 + doctor 校验 |
| vault 是 git 工作树（.pm 污染 / git clean 风险 / 误提交） | I11 + `.gitignore` 追加 `.pm/`（P5 confirm-first）+ git 提示显式路径禁 `-A`；守卫自身 fail-closed：`.git` 存在性探测走 probeName 三态（查不出 ≠ 不存在，三十六轮）、`.gitignore` 读失败拒绝（三十五轮） |
| vault 改名打断 portfolio 线上 URL | RENAME 默认只报告 + photos.json 只读引用检查标 BLOCKED（§10.2） |
| file-io 未经上游在 GHC 9.10.3 测试 | P0 冒烟 + FilePath 降级预案（§4） |
| ARW 无缩略图影响 GUI | v1 明示不做；v2 在 GUI 侧提取内嵌 JPEG |
| GUI 工具链 | 2026-08-24 改判 Rust/Tauri：cargo、tauri-cli、WebView2、MSVC 本机均已在，零安装；GUI 缺席不影响 CLI 全功能（§11 边界） |
| 本机其它进程打 `pm serve` | 只绑 127.0.0.1 + 随机端口 + Bearer token（常量时间比对）+ Host/Origin 校验；缺省**只读**，`--writable` 开九个生成计划类写端点：生成推送计划（写 vault 的 `.pm/plans` + 首次 root-id）、记录「暂不同步」决定 / 照片记录（写主库的 `.pm/vault-holds.json` / `.pm/vault-notes.json`）、改配置（写 XDG 的 config.toml，主库路径只读）、登记备份盘（在目标盘上建备份 root 标识，守卫链同 CLI）、生成 sort / 归档 / 相册 / 转换计划（写主库 `.pm/plans`；转换另写 `.pm/derived` 派生件）（§11），照片零改动；只读级 `POST /api/suggest` 拉起用户自己账号的 `claude -p --permission-mode plan`，只出建议、不写 `.pm`。P7 起 `pm ui` 以 `--allow-apply` 拉起：同用户进程若拿到 token 还能经 `POST /api/apply` 执行**已存的计划**——本节威胁模型本就不防同机同用户恶意进程（这样的进程不需要 token，直接跑 `pm apply` 甚至直接改文件即可），token 不是对同用户进程的防线；apply 能做的仍只限两段式的第二段（有计划文件才有动作，journal 全程记录、可 undo，无删除/覆盖原语） |
| 「暂不同步」把照片长期挡在视野外 | 决定记录里存决定当时的 sha（创建与复核都强制真实重算，不吃 (size,mtime) 缓存快路）：**下一次比对**（`pm vault status` / GUI 刷新）复核到字节已变即失效并回到 NEW——不是实时监视；`pm vault status` 单列 HELD 与失效项；名单是主库 `.pm` 下的普通 JSON，可读可手删 |
| release 资产无代码签名 | 个人项目无证书：安装包/exe 首次运行触发 SmartScreen "未知发布者"。README 给从源码构建的完整路径；安装包内容 = zip 内容 = `stack install` + `cargo tauri build` 的产物，可自行比对 |
| `待修改` 散文件无事件结构 | import 不碰，单列报告 |
| 相册↔成片 1 个例外文件 | 暂人工裁决——doctor 的 inbox-origin 判定侧未实现（§10.3 第 2 项，记录侧已在 journal） |

---

## 15. 用户决策记录（2026-08-22 AskUserQuestion 收口）

四条裁定（计划批准 / GUI 形态 / Raw Scheme A / `sync_photos.py` 退役）与
codex 委派方针均**已落进正文**，逐条记录移至
[`docs/REVIEW-LOG.md`](REVIEW-LOG.md)（同 §16 先例；本文件的 750 行预算）。

---

## 16. 评审记录（v0.1 → v0.2 → P3b）

按时间的评审摘要（2026-08-22 多智能体设计评审、P2/P3 各轮 codex 复审与对应
收口阶段）已拆到 [`docs/REVIEW-LOG.md`](REVIEW-LOG.md)（2026-08-24，本文件触及
750 行预算）；逐条处置表在 `docs/reviews/`，实现条目在 §10.2。

**行数预算说明（2026-08-25，已收口）**：P5-A 加 `pm sort` 后本文件涨到 764 行，
第二次触顶 750。腾挪早已做到头（§15 记录移进 REVIEW-LOG、§7 的评审经过压成短
引），再减只能删事实——**每加一条命令就要加一节**是结构性的。于是按边界拆：
逐命令设计 §7–§10 移入 [`DESIGN-COMMANDS.md`](DESIGN-COMMANDS.md)，本文件留全局
设计（定位、不变量、架构、安全写协议、GUI、测试与验收、风险），回到预算内。编号与
跨文档引用不变（正文与源码里的 §7/§10.2 照旧成立）。这不是把预算问题挪走：以后
再加命令，长的是配套文档，本文件的增量只有 §5 命令面的一行。

**第三次触顶（2026-08-27，P8-A）**：P7 期间 §11 随写端点、三级授权、GUI 执行面长到
约 160 行，本文件再次贴到 750/750。按同一条边界把 §11 整节移入
[`DESIGN-GUI.md`](DESIGN-GUI.md)（存根表留在 §11 位），读它的三条 DocDrift 哨兵同
commit 改指向；750 行预算本身自本轮起由 `caseLineBudget` 哨兵自动执行（此前只是
评审期约定）。本文件回到约 600 行，P8 的增量仍只是 §5 命令面与 §13 验收表各几行。
