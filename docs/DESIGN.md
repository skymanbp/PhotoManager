# PhotoManager (`pm`) — 设计文档

**版本**: v0.2 · **日期**: 2026-08-22 · **状态**: 已过对抗评审（见 §16）→ 待用户批准

---

## 0. 一句话定位

`pm` 是一个 Haskell 编写的照片库管理工具（CLI 核心 + 本地 Web GUI），为
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

**全库合计：4635 文件 / ≈459.3 GiB**（本节四行之和；§12/§13 的规模输入统一用这组数）。

**Raw 事件夹命名两套并存**（38 个事件夹）：

- Scheme A `YY-MM-地点-Raw` × **29**（如 `23-01-Cotswold-Raw`）
- Scheme B `RAW-YYYY-季节-地点` × **7**（全在 2025，如 `RAW-2025-Winter-Alaska`）
- 无后缀 × **2**（`23-12-Turkey`、`25-06-USA`）

**跨层同事件地点名不一致**：Raw 用英文（`23-07-Hunan-Raw`、`23-10-Zhenjiang-Raw`、
`23-11-Anhui-Raw`），成片用中文（`23-07-湖南`、`23-10-镇江`、`23-11-安徽`）。
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
- vault 的 `.gitignore` 现只有 `_inbox/`、`.ce/`、`_site/`——**不含 `.pm/`**（P5 需补，见 §10.3）
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
| I2 | **pm 没有删除原语，也没有覆盖写原语**。唯一移出机制 = quarantine（移入 `.pm/trash/` 保持相对路径 + manifest），仅三条路径可产生：`pm clean`、`pm undo`、supersede 复合（§6.5） | `Op` 代数只有 `Copy/Rename/Quarantine` 构造子；落位一律走「目标存在即失败」的 rename（§6.1 步 7） |
| I3 | 每次写盘前有可打印的 Plan 且经确认；每个文件落盘后 sha256 复读校验（**缓存级**：捕获写逻辑错误/截断/串文件与缓存副本位翻转，不覆盖介质层损坏——介质层见 I3b） | Exec 只接受 Plan；写协议 §6.1 |
| I3b | 介质级验证为显式能力：`--verify-media`（FILE_FLAG_NO_BUFFERING 绕缓存重读）+ `pm doctor` 的轮转重 hash（N 次体检保证全库覆盖一遍），`pm status` 显示「最久未验证字节的年龄」 | §6.6 + §12 单列开销 |
| I4 | 所有 mutation 先写 intent、成功后写 done（append-only NDJSON），**带真实持久化屏障**：intent 在其效果落盘前 `hFlush + FlushFileBuffers`；Copy 的 done 可组提交，Rename 的屏障强制且不可组提交（旧名仅存于日志） | Journal 模块（Win32 boot 库 `flushFileBuffers`，本机已验证存在）；`pm doctor` 对账 §6.4 |
| I5 | 目的地已存在且内容不同 → **conflict，停该项，不覆盖，无例外**。vault DRIFT 的 supersede 与备份盘更新**不是覆盖**：先 Quarantine 移出旧文件、再 Copy 落新字节（§6.5），旧字节始终在隔离区可还原 | Plan 生成期检查 + Exec 执行期二次检查 + 落位 rename 的 flags=0 语义三重防线 |
| I6 | 断电 / 拔盘 / 进程被杀后，`pm doctor` 能检出半成品并安全恢复；恢复矩阵覆盖三种 Op 的全部协议步骤与掉电（journal 尾部丢失）模型 | §6.4 矩阵 + §13 两类故障注入 |
| I7 | 拓扑不变量持续可校验：vault ⊆ 相册；相册 ⊆ 成片 ∪ inbox-origin（journal 中有 ingest 来源记录的集合）；侧车与主文件同批移动 | Catalog 层校验；ingest 登记来源（§10.3） |
| I8 | 相册↔vault 差异与 `sync_photos.py` **逐字段值形状兼容**（六态 + 位置元组 + 16 字符截断 hash + 退出码 0/1/2 + 同一文件过滤集合含 .png，case-fold） | §10.1 |
| I9 | pm 绝不执行 git 命令（vault/portfolio 的 add/commit/push 都由用户手动）；对 portfolio `photos.json` 仅只读引用检查 | Vault 模块无 git 调用 |
| I10 | pm 单实例：mutation 前对 `.pm/lock` 打开句柄并 `hTryLock`（内核级锁，进程死亡自动释放，锁文件残留无害且无需删除） | base `GHC.IO.Handle.Lock`（Windows 走 LockFileEx） |
| I11 | pm 不在任何 `.gitignore` 未覆盖 `.pm/` 的 git 工作树内建立 root，**任何 role**（主库/备份/vault）一视同仁：`init` / `backup init` / `vault push` 建 root 前检查（经用户确认追加 ignore 行后才建），`pm apply` 取锁前预检 + 锁内按盘上 role 重检；检查是文本级白名单（恰含 `.pm/` 行；`!` 反规则不得含 `.pm` 或通配符 `* ? [ \`，pm 不实现 wildmatch）；所有直接写 `.pm/` 的入口（计划保存、catalog/侧缓存、doctor --repair、trash、undo/resolve）经 `requireWritable` 同一守卫（P3b-7）；建立身份的三条旁路（`init` / `backup init` / 首次 `vault push`）天然走不了它，改由 `readRootState` 的 `RootUntrusted` 态覆盖（P3b-12），`pm doctor` 每次复查 | §5 init + §10.2 P3b-6/P3b-7 + §10.3 |

**「快」的量化目标**（介质分列，§12）：`pm status` 默认含 stat-only 新鲜度刷新，
主库（NVMe、热缓存）< 10 s，`--cached` 纯读快照 < 2 s；备份盘（USB HDD、冷态）
全树 stat < 90 s。

---

## 3. 领域模型

```
Root      = { id :: UUID (写在 <root>/.pm/root-id.json，不认盘符),
              role :: Main | Backup | Vault,
              path :: OsPath,
              fsType, mtimeGranularity, workerCount }   -- init 时探测记录（§9）
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
src/Pm/Config.hs            -- TOML 配置（roots、别名、后缀表、portfolio photos.json 路径）
src/Pm/Catalog.hs           -- snapshot + 内存索引
src/Pm/Journal.hs           -- NDJSON append + 持久化屏障 + replay + 对账
src/Pm/Scan.hs              -- 增量扫描（stat 比对 → 变更集 → 并行 hash，worker 数取 Root 属性）
src/Pm/Hash.hs              -- crypton SHA-256 流式（Handle 来自 file-io 的 OsPath API）
src/Pm/Diff.hs              -- 两个 Catalog → 六态差异（纯函数；只认 filename+sha，不看 mtime）
src/Pm/Plan.hs              -- Diff/规则 → Plan（纯函数，无 IO）
src/Pm/Exec.hs              -- ★安全内核：全项目唯一有写盘 IO 的模块
src/Pm/Names.hs             -- 事件夹/文件名解析、规范化、rename 计划（目标唯一性校验）
src/Pm/Versions.hs          -- 版本组聚合报告
src/Pm/Vault.hs             -- 相册↔vault 差异 + push/ingest 计划（无 git 调用）
src/Pm/Report.hs            -- 彩色终端 + --json（--json 走 ByteString 直写，绕开编码器）
src/Pm/Serve.hs             -- wai/warp 127.0.0.1 JSON API（供 GUI 桌面程序与 skill 消费）
gui/                        -- GUI 桌面程序（C#/Java，P4；独立进程，只经 API 说话，§11）
test/                       -- tasty: 单元 + QuickCheck + golden + 双模故障注入（§13）
```

**关键结构性质**：

1. `Plan.hs`、`Diff.hs`、`Names.hs` 是纯函数 → 可 QuickCheck 穷测；
2. `Exec.hs` 是唯一写盘模块，只消费 Plan → 审计面收敛到一个文件；
   **Exec 内禁用 `directory` 的 `renameFile/renamePath/copyFile`**——三者在
   Windows 上均为「目标存在即原子替换」语义（directory-1.3.8.5 haddock 实测：
   `MOVEFILE_REPLACE_EXISTING`，且声明非原子保证），与 I5 相反；
3. GUI 与 CLI 共用 Plan/Exec 核心，GUI 没有旁路写通道；
4. `Op` 无 delete/overwrite 构造子 → I2 在类型层成立。

**依赖清单**（boot 库注明；其余为 Hackage 主流包）：`base directory filepath
os-string file-io aeson bytestring text time containers crypton
optparse-applicative ansi-terminal async stm toml-reader wai warp http-types
tasty tasty-quickcheck tasty-golden temporary` +
boot：`Win32`（moveFileEx / flushFileBuffers / SetConsoleOutputCP）、`process`
（拉起 GUI 进程）。缩略图/看图渲染全部在 GUI 侧（C#/Java 原生图像栈），
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
零参数 `pm` = `pm status`。全部支持 `--json`。

| 命令 | 语义 | 写盘? |
|---|---|---|
| `pm init` | 交互式生成配置 + 各 root 的 `.pm/root-id.json`（含 FS 探测）；root 在 git 工作树内时按 I11 先补 `.gitignore` | 仅 .pm/ |
| `pm scan [root]` | 全量/增量索引（首扫全量 hash，之后 stat-比对；变更集才重 hash） | 仅 .pm/ |
| `pm status` | **总览仪表盘**：头行永远打印「索引时间（几分钟前）· 文件数」；各层规模、staging 待归档、备份盘滞后（未挂载则显示上次同步时间）、vault 差异、命名/版本问题计数、最久未验证字节年龄；**每个问题行末尾给出可直接复制的下一步命令** | 否 |
| `pm import [--apply]` | To-Be-Sync'd 事件 → `Raw\年\` + `成片\` 归档计划 | apply 时 |
| `pm backup [--apply]` | 主库 → 备份盘单向增量；备份盘多出的只报 EXTRA 永不动。**`pm backup init <盘上镜像路径>`（P2 落锤）**：插盘后一次性登记——写 role=Backup 的 root-id.json（含 FS 探测）+ 配置记 UUID+盘内相对路径，此后按 UUID 认盘 | apply 时 |
| `pm clean staging [--apply]` | **隔离区入口**：仅对「Raw/成片 已有同 sha 副本 **且** 备份 root catalog 也有同 sha 副本」（三副本确认）的 staging 文件生成 Quarantine 计划；不满足的标 `HELD(缺哪份)`；备份盘未挂载 → 不生成任何项，报「无法确认第三副本」。**`待修改\` 永不入清理计划（P2 落锤，与 §7 import 不碰同源）**；catalog 声称的两侧副本在计划期再过一次活体 stat 核对，变了降级 HELD | apply 时 |
| `pm vault status` | 相册↔vault 六态差异（§10.1 兼容 schema） | 否 |
| `pm vault push [--apply]` | NEW→定类别后拷入 vault（类别来自 GUI 勾选或 `--category`/计划文件，**CLI 无法看图，不装作能分类**）；DRIFT→确认后 supersede 复合；RENAME→只报告/BLOCKED（§10.2）；结束打印显式 git 步骤 | apply 时 |
| `pm vault ingest <files> --category <c>` | skill 调用的非交互批量入口：拷 相册/ + 拷 vault 类目 + 冲突检测 + journal 登记 inbox-origin；`--finalize` 单独一步移 `_inbox→_done`（供 skill 在 photos.json 校验通过后调，§10.3） | 是（同协议） |
| `pm names [--apply]` | 命名规范化计划（事件夹 scheme 统一、别名登记、同批目标唯一性校验） | apply 时 |
| `pm versions` | 版本组/精确重复报告 | 否 |
| `pm doctor [--deep]` | 完整性体检：catalog↔盘对账、journal 对账（含掉电残留）、半成品处置、I11 复查；**默认**对上次 CleanShutdown 之后的全部 Done 重 hash；每次体检轮转复验 1/N 全库（--deep 全量） | 否 |
| `pm apply <planId> [--only 3,7-9]` | 执行（或部分执行）已存的计划；conflict 项只停该项、批次继续、末尾汇总。**P2.1/P2.2**：执行 root 按计划 `rootId` 重新发现绑定（Exec 拿锁后再验一次；无 rootId 的计划 CLI 层 fail-closed 拒绝，含 --apply 即时路径）；`--only` 自动扩到复合组闭包；clean 计划**每次执行前**逐项重验三副本（真实重 hash），不过的降级暂停——`pm apply` 与 `clean --apply` 即时路径无差别，无豁免 | 是 |
| `pm resolve <planId> --item N --keep src\|dst\|both` | 裁决计划中标 `NEEDS-DECISION` 的冲突项（both = 新名并存）。**P2.1**：`--keep` 只接受独立的 NEEDS-DECISION Copy（复合组成员不可单独裁决）；skip/unskip 扩到全组；`--keep src` 追加的 supersede 对共享组 id | 改计划 |
| `pm trash list / empty` | 隔离区查看（manifest ∪ journal ∪ 实际目录并集，孤儿标 UNREGISTERED）/ **唯一的最终清除入口**：逐项列出、二次确认，只 unlink 确认清单里逐项可见的条目，禁止整删目录树。**P2.1（评审 cx-3 终极屏障）**：reason 为 `clean-staging` 的条目在永久删除前按当前 catalog + 真实重 hash 再确认「Raw/成片 + 备份盘」各存一份同 sha 副本，确认不了 HELD 不删 | empty 时 |
| `pm undo --last [n]` | 由 journal 生成反向计划：**仅对有 Done 的 op**；执行前逐项校验现盘内容 == journal 指纹，不符即拒绝并报告；supersede 的反向 = 从 trash 还原 victim 回原位（新副本转 quarantine） | apply 时 |
| `pm serve` | 起本地 JSON API（127.0.0.1 随机端口 + session token），供 GUI/skill 消费 | 经同一 Plan/Exec |
| `pm ui` | 启动 serve 并拉起 GUI 桌面程序（P4 交付） | 同上 |

**一目了然的日常三连**：`pm`（看仪表盘）→ 按提示跑对应命令看计划 → `--apply` 确认。

### 5.1 报告规格（R2 的硬形态）

**退出码**（与 `sync_photos.py` 对齐）：`0` = 无差异/全部成功；`1` = 有差异/
计划待处理/部分 conflict；`2` = 错误（路径不存在、root 未 init、IO 失败）。

`pm status` 终端 mock（`--no-color` 去色；`--json` 结构化等价物）：

```
pm · 索引 2026-08-22 21:03（4 分钟前）· 4635 文件 / 459.3 GiB
──────────────────────────────────────────────────────────
  Raw       4110 文件  429.7 GiB   ✓ 已索引
  成片       190 文件    4.9 GiB   ✓ 已索引
  相册        94 文件    2.5 GiB   ✓ 已索引
  暂存        241 文件   22.2 GiB   ⚠ 4 个事件未归档      → pm import
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
7  落位：Win32.moveFileEx tmp (Just dst) 0（flags=0，**目标存在即失败**——
   directory 的 renamePath 带 REPLACE_EXISTING 会静默覆盖，Exec 禁用）；
   返回 ALREADY_EXISTS → 窗口内出现第三方 dst → journal ← Failed(DstAppeared)，
   保留 tmp 交 doctor，绝不重试覆盖；
   成功后对 dst 再 stat + sha 复核一次（防撕裂），并把 **dst 自己的 stat**
   写入目标 root 的 catalog（不写源端 mtimeNs）
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
3  Win32.moveFileEx old (Just new) 0；ALREADY_EXISTS → conflict，不动
4  journal ← Done；hFlush + FlushFileBuffers
```

Plan 生成期校验**同批 Rename 目标唯一性**（防两条 Rename 撞同一 new）。
文件 Rename 带 expectedSha、目录带「直接子项名+size 指纹」——供 undo 事后校验
（不绑 NTFS 特性，备份盘可能是 exFAT）。

### 6.3 Quarantine 协议（写前日志式）

```
1  trash manifest ← 条目(victim 原路径, expectedSha, reason, planId)；FlushFileBuffers
2  journal ← Intent；屏障同 §6.2
3  Win32.moveFileEx victim (Just .pm/trash/<ts>/<相对路径>) 0
4  journal ← Done；屏障
```

### 6.4 崩溃恢复矩阵（`pm doctor` 对账；三 Op 全覆盖）

| # | 盘上状态 | doctor 判定与动作 |
|---|---|---|
| C1 | 孤儿 `.pm/tmp/*` + Intent 无 Done | 报告；建议清除 tmp（经确认），重跑计划 |
| C2 | dst 完好 sha==expected + Intent 无 Done | 补记 Done |
| C3 | dst 存在 sha==expected + journal **无任何记录**（掉电丢 journal 尾） | 按内容归属为已完成拷贝并补记 Done；backup 场景退化为 EXTRA 只读报告 |
| C4 | **Intent+Done 齐全但 dst sha ≠ expected**（硬件谎报 flush、劣质 USB 桥） | 报 **CORRUPT**，不删任何东西；staging/源那份标回「未确认归档」 |
| C5 | 步 7 撕裂：dst 存在但 sha≠expected 且有 Intent 无 Done | Failed 半成品；dst 走 quarantine（已不在 tmp，超出 unlink 授权），源未动，重跑 |
| R1 | Rename：{old 在 / new 无} | 未执行，重跑 |
| R2 | Rename：{old 无 / new 在} | 已执行；按指纹复核后补记 Done |
| R3 | Rename：{两者都在} | 未执行且目标被占 → conflict 报告，不动 |
| Q1 | trash 有文件 / manifest 无条目 | 标 UNREGISTERED，列给用户，不自动处置 |
| Q2 | manifest 有条目 / trash 无文件 + Intent 无 Done | 未执行，victim 应仍在原位，复核后清除该 manifest 条目 |

**源文件在所有 Copy 路径上未被触碰**；掉电模型（journal 尾部丢失）由 C3/R2
接住。`pm doctor` 默认对「上次 CleanShutdown 之后的全部 Done」重 hash（工作量
只有被中断那场会话，有界）；「已归档，冗余」标签只由**已复验**的 Done 驱动。

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

- `--verify-media`（backup/vault push 可选）：落位后用 `FILE_FLAG_NO_BUFFERING`
  新句柄绕缓存重读校验（扇区对齐读；开销进 §12 预算）。
- `pm doctor` 轮转：每次体检重 hash 全库 1/N（默认 N=10），保证有界时间内
  全库字节被真实重读过；`lastVerified` 进 catalog，status 显示最久未验证年龄。

### 6.7 并发防护

- mutation 前打开 `.pm/lock` 句柄 `hTryLock`（内核锁，崩溃自动释放，I10）；
- Plan 带 (size,mtime) 前提，Exec 逐项复核（防 Lightroom 并发改动）；
- scan 对每文件 hash 前后双 stat，不一致 → 标 volatile 本轮不入索引。

---

## 7. 归档（`pm import`）

- 输入：`To-Be-Sync'd\Raw\[<年>\]<事件>` → `Raw\<年>\<规范名>\`；
  `To-Be-Sync'd\Processed\<事件>` → `成片\<规范名>\`。（P2 实测：暂存 Raw 的
  事件夹直接位于 `Raw\` 下无年份层；计划器两种布局都接受，年份一律由事件名
  `YY-` 推导，显式年份层与推导不一致 → 不猜，报 unrecognized。）
- 事件名按 canonical scheme（§8 Scheme A）规范化后落位；侧车跟随；
  计划期校验同批目标唯一性（两个源撞同一目标 → 连同**同目录同 stem 侧车**
  整组拒绝，评审 mj-3）；**返修同样升级到 stem 组**（P2.2 mj-3v2：主文件
  NEEDS-DECISION 时其同 stem 待拷文件悬置为 NEEDS-DECISION，绝不先行落位
  产生孤立侧车）；目标键一律 **normalise + case-fold** 比较（NTFS 语义，
  评审 mj-2）；事件名先剥可选 `-Raw` 后缀（大小写不敏感）再验地点非空——
  `26-04--Raw`（空地点）与 `26-04-Raw`（裸后缀，歧义）都拒绝（评审 mj-1）；
  生成计划前先做暂存区新鲜度守卫（与索引不一致 → 先 pm scan）。
- 老事件返修（如 `Processed\23-04-EU`）：逐文件走 §6.1——同 sha skip、
  不同 sha 标 `NEEDS-DECISION` 交 `pm resolve`。
- 归档后 staging 原文件**原地不动**；`pm status` 依据**已复验的** Done 标记
  「已归档，冗余」；清理走 `pm clean staging`（内建三副本前置条件，§5）。
- `待修改\` 散文件无事件结构：import 不碰，单列「待修改清单」报告。

## 8. 命名治理（`pm names`）

- 事件夹统一到 canonical scheme = **Scheme A `YY-MM-地点-Raw`（用户裁定
  2026-08-22）**：29/38 已是，与成片对齐；Scheme B 的月份从成片对应事件还原，
  还原不出的——如 RAW-2025-Summer-Providence 无成片对应——标 NEEDS-DECISION 交用户。
- 跨层地点别名表（Hunan↔湖南 等）入配置，事件关联用别名闭包。
- 文件级版本后缀**不强制统一**（信息即历史）——只做清单报告，改名需用户勾选。
- rename 计划 + 同批目标唯一性校验 + journal 双向映射 + `pm undo` 可回滚。
- **P3b-2 落锤（2026-08-23 真实库实测，42 事件夹）**：31 合规、6 项入计划
  （2 裸名补后缀 + 4 个 Scheme B 唯一还原）、3 项拒猜（Summer/Autumn-Providence
  同抢 25-11-Providence-Raw 的同批撞名、Summer-Atlanta 还原月撞已存目录——
  「同年同地点唯一」还原规则的局限由盘面存在性防线兜底）、2 个 `&` 双月名
  （`23-04&05-Egham-Raw`）报 unrecognized 交用户。别名表延后：需要它的中文
  事件在 Raw 侧已是 Scheme A，无改名需求。目录改名走 §6.2（FpDir 指纹），
  catalog 前缀由 updateCatalog 重写，undo 回滚有 E2E 测试。versions（§5）
  同日落锤：暂存区不入报告、成片↔相册 同名精确对为设计内拓扑不报，
  真实库产出 112 版本组 + 15 组真重复（含跨事件夹 7 连号 ARW 与
  相册↔成片 的那 1 个异名同字节例外）。

## 9. 备份同步（`pm backup`）

- 备份 root 识别：`getLogicalDrives` 枚举 + `SetErrorMode(SEM_FAILCRITICALERRORS)`
  抑制「请插入磁盘」系统对话框 + 只探 REMOVABLE/FIXED 卷找 `.pm/root-id.json`
  （role=Backup，UUID 与配置登记值相符才认）；找不到 → 提示插盘，绝不猜。
  （P2 落锤：GetDriveTypeW/SetErrorMode/GetVolumeInformationW 均无 Win32 包
  绑定，已在 Pm.Win 自行 foreign import。）
- 登记入口 = **`pm backup init <盘上镜像路径>`**（P2 落锤，取代原设想的
  pm init 一并处理）：写 role=Backup root-id.json（含 GetVolumeInformationW
  探测的 FS 类型）+ 主配置记 `[backup] id/subpath`；拒绝与主库嵌套的路径和
  git 工作树。exFAT 无元数据日志，rename 原子性弱于 NTFS——doctor 矩阵
  （§6.4）不依赖原子性假设，仅依赖「tmp 与 dst 不同名」这一约定。
- 单向 add/update：主库有而备份没有 → Copy；同名不同 hash → 计划标出方向
  （默认判主库新），**经确认后走 §6.5 supersede 复合**（备份盘旧字节进备份盘
  自己的 `.pm/trash/`，不丢）；备份盘多出的 → EXTRA 只读报告。
- 备份 root 的 catalog 记录**备份盘自己 stat 的值**（§3）。备份计划的
  journal/trash/tmp 全在备份 root 自己的 `.pm` 下（P2 落锤，与效果同卷）；
  备份路径的 Done 仍一律即时 FlushFileBuffers（不组提交）——理由是可移动
  介质：结果打印后用户随时可能拔盘，Done 必须在汇报前已落盘；
  doctor（`--backup`）的 C3/C4 行专门接这个残余。
- worker 数是 Root 属性：init 探测介质（seek-penalty/MediaType），
  removable/rotational 默认 1（避免寻道抖动），NVMe/SSD 默认物理核数；可手动覆盖。
- 拔盘期间 `pm status` 用备份 root 的本地缓存快照报「上次同步时间 + 当时滞后量」。

---

## 10. Vault 分发与档案侧对接

### 10.1 `pm vault status` — 逐字段兼容

- 六态语义与 `sync_photos.py` 一致；`--json` **值形状逐字段照抄**：
  `ok/new/missing/duplicate` 用同形位置元组、`renamed/drift` 的 hash 截断 16 字符、
  `duplicate` 与 ok/drift 可重叠（不构成划分）、顶层键名同
  （`source_dir/vault_dir/source_count/vault_count/...`）；退出码 0/1/2 同。
- **文件过滤集合 = sync_photos.py 的 PHOTO_EXTS 等价类**（jpg/jpeg/png，case-fold）；
  「只收 jpg/jpeg」的收紧只在 push/ingest **写路径**生效，.png 在 status 里以
  `UNPUSHABLE` 显式可见而不是被静默过滤。
- P3 验收：与 sync_photos.py 输出做**集合逐项比对**（非计数比对）。
- sync_photos.py **退役由 pm 接管（用户裁定 2026-08-22）**：P3 用它做最后一次
  互校（比对通过才算验收），P5 把档案侧文档/skill 指针改指 `pm vault status`
  并 `git rm` 该脚本（档案 vault 本地 git 历史可恢复；跨仓改动 confirm-first）。
- **P3a 实测验收（2026-08-23）**：`pm vault status --json` 与 sync_photos.py
  双跑真实库，全部 legacy 键**集合逐项一致**——78 OK / 15 NEW / 1 RENAME /
  0 MISSING / 0 DRIFT / 0 DUPLICATE，source_count 94 / vault_count 79，
  RENAME 恰为档案侧登记的 `_DSC9014.JPG ≡ landscape/_DSC9013_2.JPG`；
  UNPUSHABLE 轴当前 .png=0 空洞通过，已由合成 fixture 测试补位（VaultTests）。
  legacy 逐行为基线与 vault 拓扑实测：`docs/specs/sync-photos-legacy-spec.md`、
  `docs/specs/vault-topology-p3.md`。vault 侧 sha 缓存放主库 `.pm/vault-cache/`
  （I11 之前对 vault 目录零写入；status 全链路只读 vault）。

### 10.2 `pm vault push`

- NEW：类别来自 GUI 勾选（P4 后的主路径）或 `--category`/计划文件编辑；
  CLI 只有文件名可看，**不提供假装能分类的交互表格**，无类别项保持 pending
  并提示「需要看图分类 → pm ui 或 --category」。原字节直拷（vault 硬规则 1），
  写路径只收 jpg/jpeg（case-fold）。
- DRIFT：相册是上游真相 → 逐项确认后走 §6.5 supersede 复合（victim 进
  vault root 的 `.pm/trash/`，**不依赖「git 历史里有旧版」这类 pm 无法核实的
  外部前提**）。
- RENAME：**默认只报告**。vault 文件名是 GitHub Pages URL 的一部分、被
  portfolio `photos.json` 以完整 URL 引用（§1.3）——pm 对 photos.json 做只读
  引用检查（路径入 Config），被引用的项标 `BLOCKED(photos.json:<行>)`，
  未被引用且用户确认的才生成 Rename。
- MISSING：只报告（可能是有意撤下，决定权在用户）。
- 结束打印**显式路径**的 git 步骤：`git add landscape portrait urban`（明确
  禁止 `git add -A`/`git add .`，防把 `.pm/` 等误提交）；pm 不执行 git（I9）。
- **photos.json 不在 pm 写域**：类别判定/坐标是 AI 视觉判断，属 `/photo-inbox`。
- **P3b-1 落锤（2026-08-23）**：CLI 形态 `pm vault push [--category C FILES…]`
  ——NEW 只推显式点名 + 显式类目的文件（无类目零猜测）；DRIFT 生成
  NEEDS-DECISION 项，裁决复用 `pm resolve --keep src`（§6.5 supersede，
  victim 进 vault 侧 `.pm/trash/`）；RENAME/MISSING 只报告。I11 守卫为
  **文本级** `.gitignore` 含 `.pm/` 行检查（pm 不跑 git，I9）+ role 校验，
  fail-closed；vault root 由首次生成计划时建立（用户已批准 ignore 行，
  展示集仓 commit 2d81d36）。执行绑定 bindExecRoot 序：主库 → vault
  （固定路径无发现流程）→ 备份盘；doctor/trash/undo 增 `--vault` 开关。
  真实库只读验证：RENAME 项命中 `BLOCKED(photos.json:208)`（实测该行
  正是 `_DSC9013_2.JPG` 的 Pages URL），15 NEW 待分类不出计划，vault
  目录零写入。
- **P3b-4 … P3b-12 的逐轮评审收口**（2026-08-24，codex 一~九轮）已移入
  [`docs/REVIEW-LOG.md`](REVIEW-LOG.md) §「P3b 逐轮收口」——那里是评审史的家，
  本文件是设计文档（同 P3b-8 把 §16 拆出去的先例；DESIGN.md 触及 750 行预算）。
  当前实现对应 **P3b-18 / pm 0.3.16 / 190 测试**（P3b-13~18 详情见 REVIEW-LOG）。

### 10.3 P5 — 档案侧整理优化（跨仓改动，逐项经用户确认）

1. `/photo-inbox` SKILL.md 重写：第四阶段机械步骤改为两步调用——
   `pm vault ingest <files> --category <c>`（拷 相册/ + 拷 vault/ + 冲突检测 +
   journal 登记 inbox-origin，**不动 _inbox**）；skill 完成 photos.json 写入并
   `json.tool` 校验通过后，再调 `pm vault ingest --finalize` 移 `_inbox→_done`。
   顺序保证与 skill 现行「photos.json 成功后才移」硬约束一致；AI 部分
   （看图分类、坐标、photos.json 内容）保持不变。
2. ingest 的 journal 来源登记喂 I7：相册 ⊆ 成片 ∪ inbox-origin，doctor 把
   inbox 来的照片归为「已解释」而非违例。
3. vault `.gitignore` 追加 `.pm/`（比照现有 `.ce/` 惯例；按档案 vault
   confirm-before-act 规则先征得同意——I11 在此之前拒绝在 vault 建 root）。
4. `KB-维护速查.md` §📸 与 档案 `CLAUDE.md` 摄影行更新指针；
   `record-structure-version.md` Change Log 补记。
5. `sync_photos.py` 去留按用户决定落实。

---

## 11. GUI（独立桌面程序，C#/Java —— 用户裁定 2026-08-22）

- **架构边界（不变量级）**：GUI 是独立进程，**永不直接触碰照片文件**；一切
  读写经 `pm serve` 的 loopback JSON API——写路径与 CLI 完全同一 Plan/Exec
  内核，I1-I11 对 GUI 自动成立。GUI 崩溃/缺失不影响任何 CLI 功能。
- API（Haskell 侧，P4 前即随 P1-P3 逐步成型）：`GET /api/status`、
  `GET /api/plan/<kind>`、`POST /api/apply`（planId + 勾选子集 + 分类赋值）、
  `GET /api/thumb/<sha>`（返回原 JPG 字节，缩放由 GUI 做）；只听 127.0.0.1，
  请求带随机 session token（crypton 取熵，`pm ui` 启动时传给 GUI 进程）。
- GUI 功能 = status 仪表盘 + 计划浏览/勾选/确认 + **vault push 逐张看图分类**
  （核心价值场景，CLI 做不了）；JPG 解码/缩放走 C#（WPF imaging）或 Java
  （JavaFX）原生栈，ARW 内嵌预览提取留 v2。
- 语言选型 P4 落锤：**C# WPF 优先**（Windows 原生栈最稳）；本机实测
  `dotnet` 存在但无 SDK、`java` 不存在——P4 开工前需装 .NET SDK（或 JDK），
  届时经你确认再装。
- `pm ui` = 启动 serve + 拉起 GUI exe（`process`）。

---

## 12. 性能设计（规模输入统一为 4635 文件 / 459.3 GiB；D: 为 NVMe）

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
  - P5 Plan 纯函数 golden
- **golden 测试**：fixture 照片树（小文件模拟三层库 + staging + vault，**含
  `.JPG` 大写扩展名与 CJK 路径**）跑全命令面，输出快照比对。
- **编码回归**：`chcp 936` 下跑真实二进制、stdout 重定向到文件，断言退出码
  语义正确且输出可 UTF-8 解码（进程内 golden 捕不到这条路径）。
- **真实库验证**：每阶段收尾对真实库跑只读命令核对；mutation 命令先 fixture
  树 + 用户指定的小事件试点。

### 分阶段验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| P0 | 脚手架 + file-io 冒烟 + Config/Catalog/Scan/Hash + `init/scan/status` | file-io 编译判定落锤；真实主库全量扫描成功；status 数字与 §1 实测吻合（4635/459.3 GiB）；主库增量重扫 < 10 s |
| P1 | Exec/Journal 安全内核 + `doctor/trash/undo/apply/resolve` | 双模故障注入全绿（三 Op 全步骤）；C1-Q2 矩阵逐行有测试对应 |
| P2 | `import` + `backup` + `clean staging` | fixture 试点 → 真实归档+备份，hash 复读零失配；`clean staging` 计划恰好覆盖全部冗余文件、HELD 逻辑正确、apply 后 doctor 对账通过、trash 可按相对路径还原 |
| P3 | `vault status/push` + `names` + `versions` | vault status 与 sync_photos.py **集合逐项一致**（含 .png、.JPG case）；names 计划经用户批准执行后 undo 可完整回滚 |
| P4 | `pm ui`（仪表盘 + 计划确认 + 看图分类） | GUI 完成 vault push 逐张分类全流程 |
| P5 | 档案侧 skill/文档整理优化（§10.3 五项） | 跨仓 diff 逐项经用户确认落地；/photo-inbox 走新机械层跑通一轮真实 inbox |

---

## 14. 风险与对策

**威胁模型（P2.3 明文化）**：pm 防**崩溃/掉电/介质错误/并发良性进程**
（Lightroom、资源管理器等），不防同一台机器上恶意进程的毫秒级 check-use
竞争（TOCTOU 攻击）——后者需要句柄级 FILE_ID 校验与全程句柄持有，属安全
软件范畴。设计保证：即使此类窗口被击中，字节也只会进 trash 而非消失，且
`pm trash empty` 在永久删除前重验三副本（终极屏障）。逐项分析见
`docs/reviews/2026-08-23-p2-codex-review.md` 三轮章节。

| 风险 | 对策 |
|---|---|
| **Windows 输出编码（ACP=936）**：GHC 默认 CP936，emoji/勾号直接崩进程、重定向输出 GBK 字节（本机已实测复现） | main 首行 `hSetEncoding stdout/stderr utf8`；`--json` 走 ByteString 直写绕开编码器与 CRLF；console 场景 `SetConsoleOutputCP(65001)`；§13 编码回归测试 |
| `directory` rename/copy 的替换语义（静默覆盖） | Exec 禁用清单 + 一律 `moveFileEx … 0`（§6.1/§6.2）；P1 测试覆盖 ALREADY_EXISTS 分支 |
| 掉电/谎报 flush/劣质 USB 桥 | 持久化屏障（I4）+ 矩阵 C3/C4 + doctor 默认复验窗口 + 轮转重 hash（§6.6） |
| 长路径 (>260) / Unicode 路径 | file-io（long paths）或 FilePath 方案 + ≥240 预检（P0 落锤）；CJK 路径入 golden |
| 备份盘符漂移 / 弹「请插入磁盘」框 | marker UUID + SetErrorMode + 只探 REMOVABLE/FIXED（§9） |
| exFAT 备份盘（无元数据日志、rename 原子性弱） | 矩阵不依赖原子性；FS 类型/粒度入 root-id.json；mtime 只做同 root 缓存键（§3） |
| Lightroom / 用户并发改文件 | Plan 前提复核 + 双 stat + 落位 flags=0 三重防线 |
| catalog 损坏 | journal 重建 + 快照 3 份轮换 + doctor 校验 |
| vault 是 git 工作树（.pm 污染 / git clean 风险 / 误提交） | I11 + `.gitignore` 追加 `.pm/`（P5 confirm-first）+ git 提示显式路径禁 `-A` |
| vault 改名打断 portfolio 线上 URL | RENAME 默认只报告 + photos.json 只读引用检查标 BLOCKED（§10.2） |
| file-io 未经上游在 GHC 9.10.3 测试 | P0 冒烟 + FilePath 降级预案（§4） |
| ARW 无缩略图影响 GUI | v1 明示不做；v2 在 GUI 侧提取内嵌 JPEG |
| GUI 工具链缺失（无 .NET SDK / JDK） | P4 开工前经用户确认安装；GUI 缺席不影响 CLI 全功能（§11 边界） |
| `待修改` 散文件无事件结构 | import 不碰，单列报告 |
| 相册↔成片 1 个例外文件 | doctor 报告单列，结合 inbox-origin 判定（I7），用户裁决 |

---

## 15. 用户决策记录（2026-08-22 AskUserQuestion 收口，已全部落进正文）

1. **计划批准**：v0.2 批准，开工 P0（逐阶段 git commit + 真实库只读验证；
   写盘功能先 fixture + 小事件试点）
2. **GUI 形态**：允许 C#/Java 编写 → 独立桌面程序 + `pm serve` JSON API（§11）
3. **Raw canonical 命名**：Scheme A `YY-MM-地点-Raw`（§8）
4. **`sync_photos.py`**：退役由 pm 接管（P3 末次互校 → P5 落实，§10.1）

另（2026-08-22 用户指示）：部分任务经中转站 API 委派 codex `gpt-5.6-sol`
执行以控制 token 消耗（已配置并 PING 验证）；安全内核与协议测试仍由主线
编写与审查，codex 用于样板/fixture/GUI 初稿/阶段末独立 review。

---

## 16. 评审记录（v0.1 → v0.2 → P3b）

按时间的评审摘要（2026-08-22 多智能体设计评审、P2/P3 各轮 codex 复审与对应
收口阶段）已拆到 [`docs/REVIEW-LOG.md`](REVIEW-LOG.md)（2026-08-24，本文件触及
750 行预算）；逐条处置表在 `docs/reviews/`，实现条目在 §10.2。
