# pm 设计（P8 卷）——Photography 为相片 SoT：相册通道、AI 建议入口、jpg 转换、1.0.0 收官

> [`DESIGN.md`](DESIGN.md) 的配套文档，**同一份设计的续篇**（拆分理由同
> [`DESIGN-COMMANDS.md`](DESIGN-COMMANDS.md) / [`DESIGN-GUI.md`](DESIGN-GUI.md)：
> DESIGN.md 有 750 行硬预算，P8 是一整个工作包）。编号自 §17 起；不变量 I1–I11
> 的定义在 [`DESIGN.md` §2](DESIGN.md#2-需求--不变量)，九态模型在
> DESIGN-COMMANDS.md §10.1，GUI 页面与端点在 DESIGN-GUI.md §11。
>
> 本文件是 P8 的**裁定登记 + 设计本体**：先写，再实现（每阶段的实现对照本文
> 逐条核对；实现与本文不符以本文为准并回改本文，不许两边各说各话）。

---

## 17. 用户裁定（2026-08-27，AskUserQuestion，逐条）

工作包原文（用户，2026-08-27）：① Photography 为相片 SoT，pm 从暂存区导入成片
时可同时导入相册，并有「成片→相册」入口；vault 仍是相册的下游投影，`_inbox`
放 diff，pm 分类并提示推送命令；② AI 辅助分类/定位要有 GUI 入口；③ 投影时检出
非 jpg 并提供一键批量转换 + 投影；④ 更新 vault 侧 skills；⑤ 做完提醒 GUI 审查；
⑥ 审查通过后全量更新文档；⑦ 推送并发布新 release，二进制走 GitHub Actions。

| # | 问题 | 裁定 | 弃用的备选与理由 |
|---|---|---|---|
| R1 | 展示集收什么格式 | **A 保持只收 JPEG** | 收 png/tif 会改 vault 硬规则 3 与 photos.json 的 Pages URL 形态 |
| R2 | `_inbox` 模型 | **D′ 不落 diff，diff 只报告**（§18） | A「_inbox 放 diff 镜像 + 第十态 PROJECTED + clean-inbox」：多一份无人校验的字节、一个新状态、一条 mv→_done 删档风险、一个投影与分类之间的 fail-open 窗口 |
| R3 | AI 后端 | **A `pm serve` 拉起 `claude -p`** | 内嵌 API 调用要管密钥（违反本项目「密钥只在 ~/.codex/auth.json、不进代码」的纪律）；纯 skill 路线没有 GUI 入口 |
| R4 | 转换引擎与派生件去向 | **A Pillow 两段式；派生 jpg 进成片同事件夹 + 相册** | JuicyPixels 不支持 TIFF/PSD；派生件只进相册会破 I7（相册 ⊆ 成片） |
| R5 | 版本 | **A 1.0.0 收官**（前提：真实库跑通，§26） | 0.7.0 与「彻底收官」的措辞不符 |
| R6 | 「定位」的范围 | **(a)+(b) 都做**：整理新照片页每段地点（photo-place 契约）+ 分类推送页每张照片地点/坐标（落 `.pm/vault-notes.json`，技能消费） | 只做一半就有一半的 AI 建议没有去处 |
| R7 | GUI 入口形态 | **新开第七页「归档」** | 并进状态页会把仪表盘拉长，且成片挑选网格（候选约 104 张）不是"状态" |
| R8 | CLI 命令面 | **`pm album add <事件夹>/<文件名>…`**（新顶层子命令 `album`；`pm import --also-album`；`pm convert`） | `pm import --from-processed` 混淆 import 的「暂存区→归档层」语义 |

盘面基线（2026-08-27 实测，只读）：成片 198（197 jpg + 1 tif `26-06-R66/_DSC9621.developed.tif`），
相册 94（56 `.jpg` + 38 `.JPG`，100% JPEG），vault 79，`_inbox` 空，
To-Be-Sync'd 13 jpg + 4 xmp + 3 arw + 1 acr。`python` = 3.13 + Pillow 12.3.0（libtiff/jpg 均 True）；
`claude` CLI 2.1.243 有 `-p/--print`、`--output-format`、`--permission-mode`、`--allowedTools`、`--add-dir`。

---

## 18. 拓扑与数据流（D′：不落 diff，diff 只报告）

```
D:\Photography（SoT，主库 root）
  To-Be-Sync'd ──pm import [--also-album]──► 成片\<事件>\ ──pm album add / GUI 挑选──► 相册\（平铺）
                                               │                                        │
                                               └── pm convert（非 jpg → 派生 jpg 落成片同事件夹 + 相册）
  相册 ──pm vault status（NEW = 相册 − vault − HELD，只报告）──► GUI 分类推送页 / 技能读 --json
  相册 ──pm vault push（GUI 保存决定 / --category）──► 摄影作品\<类目>\（原字节直拷）+ 打印 git 步骤
  主库 .pm\vault-notes.json（地点/坐标记录）──pm vault notes --json──► /photo-publish 写 photos.json
摄影作品\_inbox\：只留给库外来源的 pm vault ingest（遗留通道；README 改指 sort/import 为正路）
```

五条原则：

1. **相册只有两条入口 + 一条转换**：`pm import --also-album`（暂存区→成片时同源
   再拷一份进相册）、`pm album add`（成片→相册，CLI 与 GUI 挑选同一条计划路径）、
   `pm convert`（非 jpg → 派生 jpg 进成片同事件夹与相册）。三条都是主库 root 内的
   `OpCopy` 计划，走既有 Plan/Exec 内核（I3/I4/I5 自动成立）。
2. **diff 只报告，不落文件**：待分类集合就是 `newActive`（Vault.hs:219-220，
   NEW − HELD），它已经由 `pm vault status`、`GET /api/vault/new`、GUI 分类推送页
   三处报出。把它再拷一份进 `_inbox` 只会多出一份无人 doctor 的字节、一个第十态、
   一条 `mv → _done` 的删档步骤、一个投影与分类之间的 fail-open 窗口——而这四样
   没有一样是用户要的「pm 分类 + 提示推送命令」所需要的。九态模型一字不动。
3. **分类仍是现有 `pm vault push`**：GUI「保存决定并生成推送计划」/ CLI `--category`
   → `checkAssignments` / `vaultPushItems` / `mkVaultPushPlan`（Vault.hs:614-672）
   原字节从相册直拷进类目，收尾打印 git 步骤（`gitStepsLines`，I9）。零改动。
4. **`_inbox` 降为遗留通道**：`pm vault ingest`（库外源 → 相册 + vault 两份计划，
   Ingest.hs）保留原样，`knownAux`（Vault.hs:309）不变；`_inbox/README.txt` 与
   `/photo-inbox` 改写为「正路是 `pm sort` → `pm import --also-album` → GUI 分类」，
   `_inbox` 只在照片**不经成片**时用（例如手机直出且不想进成片）。
5. **技能变薄**：`/photo-inbox` v3 读 `pm vault status --json` 的 `new`（减 `held`），
   Read 相册里的图，出审阅表，批准后 `pm vault push --category <c> --apply --yes <文件…>`
   + `pm vault note …` 记地点/坐标——不再搬任何文件、不再有 `_done`。

---

## 19. 相册通道（P8-B，主库写路径）

### 19.1 单一 jpg 谓词

`Pm.Ingest.jpegExt`（Ingest.hs:269-272）是 `Pm.VaultCore.pushableExt`
（VaultCore.hs:55-56）的第二份定义（同为 `.jpg/.jpeg` case-fold）。P8-B 删掉前者，
ingest 的 `badExt` 改用 `pushableExt`；`caseNoDeadNames` 把 `jpegExt` 列进死名单。
相册收什么、vault 收什么，从此只有一句话（R1：只收 JPEG）。

### 19.2 `pm import --also-album`

- `Pm.Import.planImport` 不动（纯分类，§7）。`importPlanItems` 之后由新模块
  `Pm.Album.albumItemsForImport` 为 `irCopy` 里 **dst 在 `成片\` 下且 `pushableExt`**
  的每一项再生成一条**同源** `OpCopy`：src 仍是暂存区那个文件（`opSrcAbs` 相同），
  dst = `相册\<basename>`。非 jpg 的成片（如 `.tif`）只进成片，报告一行
  `→ N 个非 jpg 未入相册：pm convert <路径…>`。
- **I5**：`相册\<basename>`（case-fold）已在 catalog：同 sha → 不出该项（幂等，
  同 `irAlready` 口径）；异 sha → `StNeedsDecision`「相册已有同名不同内容 →
  pm resolve --keep」。**同批 basename 撞车**（两个事件夹各有 `_DSC0001.jpg`）→
  两条都不出相册项并逐条报告（同 `irDupTarget` 的整组拒绝纪律；相册是平铺，
  同名只能进一份，pm 不替用户挑）。
- **I7 次序（相册 ⊆ 成片）**：成片项与相册项**同一 `piGroup`**（Plan.hs:68），成片
  项在前。Exec 的组语义（Exec.hs:79-82）保证成片那份没落位（CONFLICT/FAILED）时
  相册那份不执行；`--only` 组闭包让两者不可拆开执行。成片项是返修 NEEDS-DECISION
  （`irRework`/`irReworkKin`）时**不分组**、相册项同样压成 NEEDS-DECISION（同
  `Pm.Ingest.coupleWithMain` 的耦合）——复合组成员不能单独 `--keep` 裁决，分组反而
  会把返修锁死。
- `inArchiveLayer`（Import.hs:156-157）**不动**：相册仍不算归档层（clean/三副本判定
  不受影响）。`pm status` 的暂存区「已归档，冗余」口径同样不动。
- CLI：`pm import [--apply] [--also-album]`；GUI：归档页勾选「同时导入相册」→
  `POST /api/import/plan {"alsoAlbum": true}`（§23）。

### 19.3 `pm album add <事件夹>/<文件名>…`

- 参数是**相对成片层**的路径（`26-06-R66/_DSC9621.jpg`），只接受这一种形态：绝对
  路径、`成片\` 前缀、`..`、盘符一律拒绝（`userRelOk` 同款词法闸 + `resolveUnder`
  实体闸）。文件必须在主库 catalog 里、`enKind == KindPhoto`、`pushableExt`。
- 校验与 19.2 **同一组谓词**（`Pm.Album.checkAlbumTargets`）：相册同名同 sha →
  跳过并说明；同名异 sha → NEEDS-DECISION；批内 case-fold 重名 → 整批拒绝；
  catalog 缺席/被拒 → 拒绝（「无索引」是拒绝而不是当作目标为空，§7）。
- 计划：主库 root、`plKind = "album-add"`、每项 `OpCopy (root </> 成片\…) (相册\<名>)`
  带 catalog 的 sha/size/mtime（执行期 §6.7 前提复核照旧）。身份闸次序同
  `runImport`：`requireRole RoleMain` → catalog → 校验 → `savePlanAndMaybeRun`。
- 打印口可替换（`runAlbumAddTo sink`，同 `runSortPlanTo` 的 F051 纪律）：GUI 端点
  把交代行收进 JSON。

### 19.4 归档候选（只读）

`GET /api/album/candidates`（§23）按 catalog 算：成片下 `KindPhoto ∧ pushableExt`
且相册无同名同 sha 的条目（按事件夹分组；同名异 sha 标 `conflict`），另列
`nonJpg`：成片与相册下 `KindPhoto ∧ ¬pushableExt` 的条目（`renderExts` 里的
tif/tiff/png/psd/psb/heic，Types.hs:96；RAW 不列——原始档不是转换对象）。CLI 侧
`pm album candidates` 同源同形（只读，不另起一套口径）。

---

## 20. 转换（P8-C2，`pm convert`）

### 20.1 两段式

```
第一段（生成期，pm 状态区）：python（Pillow）把 <源> 解码写成
    <主库>\.pm\derived\<源 sha>\<stem>.jpg.tmp → pm 无覆盖 rename 成 <stem>.jpg → 双 stat + sha
第二段（计划，照片层）：OpCopy <派生 jpg> → 成片\<同事件夹>\<stem>.jpg（源在成片时）
                                          → 相册\<stem>.jpg（--also-album，或源本就在相册）
```

- 源：`pm convert <库内相对路径…>`，只接受成片或相册下的 `convertibleExt` 条目（`renderExts` 里 jpg 之外的已渲染位图；
  步 9 簇 C 起与 19.4 的 `nonJpg` 栏是**同一个**谓词，RAW 两边都不列）。原 tif/png **原地不动**（I2：pm 没有删除原语；
  用户要清就自己清或走 `pm dedupe`——它们不是精确重复，不会被误报）。
  实现补两条闸（as-built）：RAW（`rawExts`）明确拒绝——它不是已渲染位图，不是
  转换对象；同批里转换后落到同一 `<stem>.jpg`（case-fold，成片同事件夹或相册）
  的先于任何转换整批拒绝（I1：pm 不替用户挑哪份留下）。
- 目标已存在（同 stem 的 `.jpg` 已在成片同事件夹或相册）：同 sha 跳过；异 sha →
  NEEDS-DECISION（I5）。派生件文件名固定小写 `.jpg`。判定与相册通道**同一份代码**：
  `classifyAlbum` 参数化为 `classifyInto dst`（成片目标 = 源所在事件夹），`--also-album`
  的相册项经上提的 `attachAlbumItems` 挂到成片项上——成片项 PENDING → 同组；成片项
  待裁决 → 相册项一并待裁决且不分组（I7）；成片那份早已落位 → 相册项单独 PENDING。
- `python` 发现：`PM_PYTHON` 环境变量 → `findExecutable "python"`（同 `PM_UI_EXE`
  的先例，Ui.hs:24）；预检 `python -c "import PIL"` 失败 → 拒绝并指引
  `pip install pillow`。脚本**内嵌在 Haskell 字符串里经 stdin 交给 `python -`**：
  发布件不多带文件，也不产生第二处路径依赖。
- 解码纪律：16 位样本先按 1/256 缩到 8 位再 `convert("RGB")`（直接 convert 会截顶）；
  保留 EXIF 块与 ICC profile（`img.info` 里有就带）；`quality=95, subsampling=0,
  optimize=True`；失败 → 非零退出 + stderr 一句原因，pm 原样转给用户，派生目录
  不留半成品（tmp 名先落、成功才 rename；Pillow 12 自己也会删掉编码失败时新建的
  文件——pm 那句 tmp 清理因此没有可注入的判红形态，REVIEW-LOG 登记为残余）。
  任一源转换失败 → 本轮不出计划、已派生的下次复用（脚本会打印每条 ⇢ 已派生 / = 复用）。
- 幂等：`.pm\derived\<sha>\<stem>.jpg` 已存在 → 复用并说明（`--redo` 强制重派生）。
- 第一段写纪律（步 9 第一方全量审 C0/C2/C3/C4/C5，as-built）：派生件的 tmp 与终名以**完整相对路径**
  各过一次 `resolveUnder`，只用返回的路径；tmp 由 pm 先 `openFreshBinary`（CREATE_NEW，残留先经
  `deleteBoundAt` 清）独占创建再交给 python 写；python 退出后复验 tmp 仍是普通名，经 `openStateRead`
  （单链接）的同一句柄测 sha，再 `moveBoundNoReplace` 落位、落位后 size 复核；复用旧派生件同样只认
  普通名 + 单链接（终名是 symlink / 库外 hardlink → 拒绝，不派生也不复用）；整段「派生 → 落位 →
  测 sha」在 `withRootLock` 内（I10）。同 sha 同 stem 的两条源共用一份派生件——先于任何转换拒绝
  （此前 `convertPlan` 的目标表按伪条目路径键入，第二条会静默吞掉第一条）。python 走
  `Pm.Subprocess.runTool`（与 claude 同一壳）：`PM_CONVERT_TIMEOUT` 秒整体超时（缺省 600），到点
  杀整棵进程树（job 对象，见 §22）；`scanDerived` 的基目录本身是链接 → Left（doctor 报 Bad、不删）。
  用例 `caseDerivedGuards`（hardlink 占 tmp / symlink 与 hardlink 占终名 / 同源 / 超时，夹具
  `test/fixtures/slow-python.cmd`）。门禁一轮（Opus）补两条：① 整批派生期间持有 root 锁——同一时间
  hold / notes / apply 等写路径拿不到锁会报忙（fail-closed，不是死锁）；② 与 Exec 的 tmp 落位是
  **同一组原语，差一处**——目标名要交给 python，pm 关掉独占句柄到 python 按名打开之间有一个窗口，
  窗口内被主动换成库外 hardlink 会写穿库外对象（随后 `probeName` + `openStateRead` 拒绝、坏字节不
  进计划，但库外字节已被覆盖）：登记为残余（同 DESIGN §14 Exec 的 TOCTOU 残余；Exec 全程只经自己
  的句柄写，无此窗口）。超时覆盖从喂 stdin 到子进程退出的全程（`runTool` 三路并发），且到点**先杀树再收线程**——Windows 满管道写是
  不可中断的 FFI 调用，先 cancel 会等到子进程读走或退出，子进程既不读也不退就永久挂死（门禁一轮突变 g3 首跑
  实测）；杀掉**所有持管道的进程**管道即断——子进程挂在 Windows job 对象里（`use_process_jobs`），到点
  `terminateProcess` 即 `TerminateJobObject` 整树，不依赖外部 `taskkill`（门禁二轮 N3：taskkill 找不到 / 被拒 / 直接子进程
  已死只剩继承了管道的孙进程，这几种它都杀不到，杀不到就是同一种挂死）。用例 `caseRunToolFlood`：桩灌满 stdout 不读
  stdin、睡 9 s，100 KiB 提示照样 1 s 超时、耗时 < 4 s、本用例新增的 PING 孙进程被收掉（全机 `tasklist` 只比前后差集，二轮 N1）。

### 20.2 doctor：`DERIVED-STALE`

`pm doctor` 新增一节：遍历 `.pm\derived\<sha>\*`（逐级只认 `NamePlain`，链接不列
不删），对每个派生件重 hash——① 该 sha 已出现在 catalog 的任一条目（已落位）→
`DERIVED-STALE`；② `<sha>` 目录名不再是 catalog 里任何条目的 sha（源已不在库里）→
`DERIVED-ORPHAN`；③ `.tmp` 半成品 → `DERIVED-TMP`（as-built 加的第三种 Warn）；
④ 其余 → Info `DERIVED-PENDING`（派生了还没 apply；无索引时同行标「未判」）；枚举
失败 → `DERIVED-ENUM` Bad，不推导任何删除。`--repair` 只删 ①②③（`deleteBoundAt`，
与「清自建 tmp」同一条删除线，doctor `--repair` 的 help 文本一并改；`caseByteExitCensus`
的模块集合加 `Convert.hs`——它删的是 `--redo` 的旧派生件与失败半成品）。派生目录是
pm 自己的状态区，不是照片：这与 I2 的关系登记在 §25。

---

## 21. 照片记录 `.pm\vault-notes.json`（P8-C）

### 21.1 为什么是主库侧的一份记录

photos.json 不在 pm 写域（DESIGN-COMMANDS §10.2；I9 同款边界），但 GUI 里 AI 给出、
用户确认过的地点/坐标必须有去处。与「暂不同步」名单同形（VaultHold.hs）：
一条**主库侧的本地记录**，vault 仓零改动，技能消费它去写 photos.json。

```json
{"name":"_DSC9621.jpg","sha":"<64 hex>","category":"landscape",
 "location":"Hallstatt, AT","coordinates":"47.556533, 13.648033",
 "title":"","source":"ai-high","at":"2026-08-27T12:00:00Z"}
```

- 校验（`validateNotes`，整体拒绝不跳过坏条目）：`name` 平铺 basename、`sha` 64 hex、
  同名唯一；`category` ∈ `fixedCategories`（可缺省）；`coordinates` 形如
  `<lat>, <lng>`（−90..90 / −180..180，可缺省）；`location`/`title` ≤ 200 字符、
  无控制符；`source` ∈ {`exif`,`ai-high`,`ai-med`,`ai-low`,`user`,`none`}。GUI 侧 `user` 来源且有内容的记录归用户所有：AI 建议不问、不填、不改它的 `source`（门禁 F4 / 二轮 N2）。
- `sha` 与 HELD 同一纪律：创建与复核都用本轮**真实重读**（`freshSrcSha`），字节变了
  → `stale`，回到「待确认」。
- 事务：与 `withHoldsTxn`（VaultCmd.hs:31-50）同一壳——取锁前 `requireMain` 预检
  → 主库 root lock（I10）→ 锁内 `computeVault` → 读 → 校验 → `writePmState`
  （`requireWritable`，I11）。壳泛化为一处 `withVaultTxn`，holds/notes 两个文件共用。

### 21.2 命令与端点

| 入口 | 形态 |
|---|---|
| `pm vault note <文件> [--category C] [--location L] [--coordinates "lat, lng"] [--title T] [--source S]` | 增/改一条（覆盖同名旧记录） |
| `pm vault note --clear <文件…>` | 删 |
| `pm vault notes [--json]` | 列出并标状态：`unsynced`（仍是 NEW/HELD）/ `pending`（已在 vault 类目、photos.json 未引用）/ `published`（`photosJsonRef` 命中）/ `stale`（sha 已变 / 已不在相册 / 读不稳定）/ `unknown`（photos.json 读不出：不答 pending——技能会重复上线，fail-closed；实现时新增） |
| `GET /api/vault/notes` | 同 `--json` |
| `POST /api/vault/notes {"set":[…],"clear":[…]}` | `--writable` 级；与 hold 端点同一锁序 |

技能侧（§24）：`/photo-publish` 第一阶段多一步——`pm vault notes --json` 取
`pending` 条目渲染成 photos.json 条目（`src` 的 Pages 基址是技能的知识，pm 不知道
也不该知道），写入、`json.tool` 校验、上线。`published` 状态由 pm 从 photos.json
**只读**反查（`photosJsonRef`，Vault.hs:539-548），所以记录不需要「已消费」标记，
也不需要技能回写 pm。

---

## 22. AI 建议（P8-D，`POST /api/suggest`）

### 22.1 边界（照抄 photo-place 的四条，不放宽）

只出建议；不进 pm 内核判断；不改任何计划参数；出不来就说出不来。GUI 把建议**预填**
进本来就要用户填的那一格（类目下拉 / 地点输入框），**不标已定、不自动点提交**
（DESIGN-COMMANDS §7：「GUI 与将来的 AI 都只是替用户填这一格」）。

### 22.2 后端：`pm serve` 拉起 `claude -p`

- 可执行：`PM_CLAUDE_EXE` → PATH 上的 `claude`（as-built：`findExecutable "claude"` 直接命中
  `claude.exe`；`PM_CLAUDE_EXE` 给了但不存在 → 409，不回退 PATH）。找不到 → 409「未安装 claude CLI」。
- 调用形：`claude -p --output-format json --permission-mode plan --max-turns 8 <提示>`，
  **cwd = 主库 root**（分类）或 **源目录**（地点），让 Read 工具落在工作目录内；
  `--permission-mode plan` 只放行只读工具——模型在构造上写不了任何东西。提示里给
  **绝对路径清单**让模型 Read 看图。整体超时 180 s（`PM_SUGGEST_TIMEOUT` 可调，测试用 1），超时 `TerminateJobObject` 杀整棵进程树（`Pm.Subprocess.runTool` 把子进程挂在 job 对象里，与转换的 python 同一壳）、409；信封 `is_error:true` → 502。以上旗标
  已用真实 `claude` 2.1.243 探针核实（cwd 内 Read 图片免提示、`permission_denials: []`；
  `--output-format json` 信封含 `result` / `is_error` / `total_cost_usd`）。as-built：提示经 stdin
  交给子进程（三根管道 utf8，不走命令行长度限制）；实测每次 ≈ $0.7–1.3（系统提示缓存写入
  占大头），响应带 `cost`，页面文案写明「你自己账号、每次有费用」。
- 并发：`seSuggestLock`（进程内 MVar）；上一次未完成 → 409。
- 上限：分类每次 ≤ 20 张；地点每次 ≤ 12 段、每段抽样 ≤ 5 张（首/中/尾）；超出 400
  让页面分批。请求体上限沿用 64 KiB（ServeGuard.hs:71）。
- 授权级：**① 只读级**（不写 `.pm`、不碰照片）；但页面上明说「会把这些照片交给你
  自己账号下的 Claude」——每次点击都是显式同意，没有自动触发。

### 22.3 两种请求

```
{"kind":"classify","names":["a.jpg",…]}          // 相册里的名字（NEW 或 HELD 都可）
→ {"items":[{"name","category","location","coordinates","source","basis","title"}],"dropped":[未回答的名字],"raw":"…","cost":0.03}
{"kind":"place","src":"E:\\DCIM","gap":72}        // serve 自己重跑 surveySort 抽样，不信任客户端路径
→ {"segments":[{"index","place","basis","confidence"}],"raw":"…","cost":…}
```

- 分类提示要求模型按图像内容判 landscape/urban/portrait（不按宽高比），坐标只在
  能说出具体依据时给、否则 `null` + `source:"none"`；`SortSegment` 增 `sgFiles`
  （as-built：段内全部可定时文件、时间序；抽样在 `ServeAi.evenSample 5` 做——首/中/尾均匀 5 张 jpg，
  RAW 同 stem 的 JPG 本就在段内；一张 jpg 也没有的段整段 `place:null` 并说明「没有可看的图」、
  不交给模型——与 photo-place §2 逐字同规）。
- 响应解析：`result` 文本里取第一段 JSON（裸或 ``` 围栏），解析失败 → 502 并把
  `raw` 原样带回（页面显示「AI 回复无法解析」，不猜）。
- 地点建议的把握「低」→ 页面预填 `<地点?>`（photo-place 契约第 3 步）。

### 22.4 测试

`PM_CLAUDE_EXE` 指向测试夹具（`test/fixtures/fake-claude.cmd` → 打印预置 JSON /
打印垃圾 / 退出非零 / 睡到超时 / 地点预置 / `is_error:true`）六种（`PM_FAKE_CLAUDE`）；as-built 落在
`test/ServeP8Tests.hs` 6 例：三个计划端点各一（只读 403 + 写域断言 + 计划可装回）、classify 一例
含五道闸（只读级仍放行、413、400 ×6、409 锁 / 缺 claude / 超时、502 垃圾 / 退出非零 / `is_error`）、place 一例
（serve 自己重跑分段、围栏 JSON、只有 RAW 的段答 null、> 12 段 400）、纯函数一例；契约：建议
**不写** `vault-holds.json` / `vault-notes.json` / 计划文件（不出现），jpg 字节不变。

---

## 23. 端点与 GUI 第七页（P8-D）

### 23.1 端点清单（新增）

| 端点 | 级 | 写域 | 同源 CLI |
|---|---|---|---|
| `POST /api/import/plan {"alsoAlbum"}` | ② | 主库 `.pm/plans` | `pm import [--also-album]`（`runImportTo sink`） |
| `GET /api/album/candidates` | ① | — | 无（`Pm.Album.albumCandidates`，只读数据面） |
| `POST /api/album/add-plan {"paths":[…]}` | ② | 主库 `.pm/plans` | `pm album add` |
| `POST /api/convert/plan {"paths":[…],"alsoAlbum"}` | ② | 主库 `.pm/derived` + `.pm/plans` | `pm convert` |
| `GET /api/vault/notes` / `POST /api/vault/notes` | ① / ② | 主库 `.pm/vault-notes.json` | `pm vault notes` / `note` |
| `POST /api/suggest` | ① | —（拉起 `claude -p`） | 无（技能自己看图） |

- `--writable` 级 POST 从六个变**九个**：`app/Main.hs` 的 `--writable` help、DESIGN-GUI.md §11、
  README 三处计数同 commit 改；as-built：三个计划端点与 `POST /api/sort/plan` 共用
  `ServeAlbum.planPost` 壳，JSON 体读取上提为 `ServeGuard.withJsonBody`（五处复制合一）；
  convert 请求在 `seConvertLock` 上排队而非 409；新增 DocDrift 哨兵 `caseRouteRoster`：从
  `Serve.hs`/`ServeVault.hs`/新端点模块里抽 `("GET"|"POST", [...])` 路由元组与
  DESIGN-GUI.md 的端点表逐项对账。
- 端点模块按边界拆：`Pm.ServeAlbum`（import/album/convert）、`Pm.ServeAi`（suggest）、
  notes 进 `Pm.ServeVault`；`Serve.hs` 只加两行路由分派（同 P8-A 的 `routeVault`）。
- CSP、Host/Origin/token 闸、`readBodyCapped` 全部沿用，不新开传输原语。

### 23.2 页面

左侧导航 **七页**：①状态 ②整理新照片 **③归档** ④分类推送 ⑤计划 ⑥设置 ⑦上手
（归档插在 sort 与分类推送之间——这就是流水线次序）。数字键 1–7；`caseGuiNavOrder`
的标记改 ①—⑦；README:57/94、DESIGN-GUI.md:95、HISTORY 的「六页」全部改「七页」。

「归档」页三张卡：

1. **暂存区归档**：复用 `/api/status` 的 `stagingEvents/stagingFiles/stagingArchived`
   摘要；勾选「同时导入相册（成片里的 jpg）」；按钮「生成归档计划」→ import/plan；
   结果横幅带 `log`（返修/无法识别/目标重复的交代行）与计划 id。
2. **成片 → 相册**：`album/candidates` 缩略图网格（`/api/thumb/<sha>`，
   `createImageBitmap` 缩放，同分类推送页）按事件夹分组；多选 → 「加入相册（生成计划）」
   → album/add-plan；`conflict` 项标「相册已有同名不同内容」。
3. **非 jpg 转换**：`nonJpg` 清单（tif/png/psd/heic…，含所在层）；多选 + 勾选
   「同时进相册」→ 「转换并生成计划」→ convert/plan；转换在生成期发生（第一段），
   落位仍要到计划页执行（第二段），页面文案把两段说清。

其余两页各加一个入口：整理新照片页「AI 建议地点」（只预填空着的 place 输入框、把握低填
`<地点?>`、每段一行依据）；分类推送页「AI 建议分类/地点」（类目按钮只描边 `.ai`、不代点；
每卡新增地点/坐标/标题三格，打开页时从 `GET /api/vault/notes` 回显；随「保存决定并生成推送
计划」按 **hold → notes（改了的差集）→ push-plan** 的次序写——hold 先行是因为服务端拒收 held
文件的 push，与 P4-7 同理）。

---

## 24. 档案侧技能与文档（P8-E，跨仓：commit 可以，档案 vault 根仓本地 only、永不 push）

| 文件 | 改法 |
|---|---|
| `.claude/skills/photo-inbox/SKILL.md` → v3 | 入口改为 `pm vault status --json`（`new` − `held`）；看图读 `D:/Photography/相册/<名>`；审阅表不变；批准后 `pm vault push --category <c> --apply --yes <名…>` + `pm vault note …`；删掉 `_inbox`/`_done`/`photo_exif.py` 段落；`_inbox` 只在「照片不经成片」时用 `pm vault ingest`（附录） |
| `.claude/skills/photo-publish/SKILL.md` → v2 | 第一阶段加 `pm vault notes --json` → `pending` 渲染成 photos.json 条目（Pages 基址在技能里）→ `json.tool` 校验；其余不变 |
| `摄影作品/_inbox/README.txt` | 「遗留通道」横幅：正路是 sort → import --also-album → GUI 分类 |
| `CLAUDE.md`（档案）§摄影 / `KB-维护速查.md` §📸 / `record-structure-version.md` Change Log | 指针与流程改写 + 补记 |
| 本仓 `.claude/skills/photo-place/SKILL.md` | 不改（它的契约就是 §22.3 地点建议的渲染格式）；只在末尾加一句「GUI 的 AI 建议地点按钮走同一契约」 |

---

## 25. 不变量对照与偏离登记

| # | 影响 | 处置 |
|---|---|---|
| I1 | 无新的删除/改名 | — |
| I2 | `doctor --repair` 删 `.pm\derived` 的 STALE/ORPHAN/TMP 派生件；`pm convert --redo` 删旧派生件、失败清半成品 | 派生件是 pm 自建状态（同「清自建 tmp」先例），不是用户字节；原 tif/png 原地不动 |
| I3 | 转换第一段在 Plan 之外写 `.pm\derived`（pm 状态区） | 登记为**偏离**：照片层仍只经 Plan（第二段）；派生件 sha 在生成期测得并进 OpCopy 前提 |
| I4 | 三条新计划种类 `import`(+相册项)/`album-add`/`convert` 全走 journal | — |
| I5 | 相册同名异容 → NEEDS-DECISION；同批重名 → 拒绝 | 19.2/19.3 |
| I7 | 相册 ⊆ 成片：import 的相册项与成片项同组、成片在前；album add / convert 源就在成片 | doctor 判定侧仍未实现（§10.3 第 2 项，登记不变） |
| I8 | `vault status --json` 的六键与 held/held_stale **零改动**；不加第十态 | D′ 的直接收益 |
| I9 | pm 仍不执行 git；`pm vault notes` 只读反查 photos.json | — |
| I10/I11 | notes 事务同 holds；derived 目录经 `ensurePmSubdir`，派生件 tmp/终名再各过完整路径 `resolveUnder` + CREATE_NEW 独占创建 + 根锁（§20.1 写纪律；整批派生期间其它写路径报忙）；三条新写路径都过 `requireWritable` | — |
| 新增边界 | `pm serve` 会拉起两种外部进程：`python`（转换）与 `claude`（建议） | 都由环境变量可覆盖、都有预检、都不写照片：python 只往 pm 先独占创建的 `.pm\derived\*.tmp` 里写，claude 在 plan 权限模式下只读；两者同走 `Pm.Subprocess.runTool`（UTF-8 管道、喂 stdin 与读两路三路并发、整体超时到点**先**杀整棵进程树（job 对象）再收线程：`PM_CONVERT_TIMEOUT` 600 / `PM_SUGGEST_TIMEOUT` 180）。登记残余：python 按名打开 tmp 的窗口（§20.1）；job 等待整树——外部工具若留下不持管道的守护子进程，`waitForProcess` 会等到超时再整树杀掉（fail-closed 报超时；首次真实 `claude -p` 跑时核实） |

---

## 26. 阶段、门禁与收官

| 阶段 | 内容 | 验证 |
|---|---|---|
| P8-B | §19 | `test/AlbumTests.hs`（纯函数 + 沙盒库端到端）；突变：同批重名闸拆掉→红、异 sha 不出 NEEDS-DECISION→红、非 jpg 入相册→红、组耦合拆掉→红 |
| P8-C | §21 | `test/VaultNoteTests.hs`；突变：坐标越界放行→红、sha 不新鲜→红、事务不取锁→红 |
| P8-C2 | §20 | `test/ConvertTests.hs` 4 例（参数闸 / 真 Pillow 端到端：16 位缩放、alpha 白底、`--also-album` 同组、`--redo`、I7 耦合、坏源 / doctor 四态 + `--repair`）；突变 m1–m6 见 REVIEW-LOG。原拟「`PM_PYTHON` 指向夹具脚本」一例改为「指向不存在 → 拒绝」：真 Pillow 已在端到端里覆盖，夹具脚本只会再抄一遍转换器接口 |
| P8-D | §22–23 | `test/ServeP8Tests.hs` 6 例（三个计划端点 / classify 五道闸 / place / 纯函数）+ `caseRouteRoster` + `caseGuiNavOrder` ①—⑦ + `node --check`；突变见 REVIEW-LOG |
| P8-E | §24 | 档案 vault commit（不 push） |
| 步 9 修复批 | §20.1 写纪律 · §22 · §25 | 第一方全量审（7 视角工作流，11 项确认 / 6 项否证）聚 A–H 八簇上游修；新哨兵 `caseDerivedGuards` / `caseQuarantineCensus`，AlbumTests RAW 入成片、`is_error` 502、`/api/vault/new` 单列 `unpushable`；突变见 REVIEW-LOG |
| 门禁 | 第一方全量审 → Opus 轮到 FINAL GO → 突变配对 → `caseLineBudget` → leakscan | 记 REVIEW-LOG（一轮 NO-GO F1–F8 修 → 二轮 GO + N1–N4 收口） |
| 提醒 | 装新构建 → 用户 GUI 审查 + **首次真实数据跑**（`pm import --also-album` / `pm album add` / `pm convert` 那 1 张 tif / GUI 分类 → 首次建 vault root）——每一步动真实照片前 AskUserQuestion 摆清单 | 用户裁定 |
| 文档 | README（含七页、新命令、AI 与转换段）、DESIGN*、DESIGN-COMMANDS §5 命令表 + §11 表、HISTORY、本文回改 | DocDrift 哨兵 |
| CI | `.github/workflows/build.yml`（windows-latest：stack test、版本一致闸、sidecar、tauri build 带 remap、leakscan、sha256 同 run、750 行闸）+ tag 触发 release job | 抓包分支 `ci-probe` 先验：symlink / hardlink / junction 夹具在提权 runner 上可用；ACL 注入用例要求套件自禁 SeBackup/SeRestore 特权（REVIEW-LOG「CI 抓包分支」）；run 33152288443 全绿后并入 main |
| 发布 | AskUserQuestion 清单 → push main → tag `v1.0.0` → CI release → 重新下载校验 | 项目收官 |
