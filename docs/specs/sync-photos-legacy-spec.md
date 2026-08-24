# sync_photos.py 行为规范（P3 兼容基线）

> 来源：2026-08-23 对 `<vault-root>\scripts\sync_photos.py`（243 行，mtime 2026-08-18）
> 的全文精读。行号引用以该版本为准。本文件是 `pm vault status` 逐字段兼容
> （DESIGN §10.1 / I8）的验收基线：**「保留」清单必须逐项复刻，「修复」清单是
> pm 相对 legacy 的有意偏离，验收比对时需逐项豁免登记。**

## 1. 常量与扫描范围

| 常量 | 值 | 行 |
|---|---|---|
| `SOURCE` | `D:\Photography\相册`（硬编码） | :51 |
| `VAULT` | `<vault-root>\摄影作品` | :52 |
| `CATEGORIES` | `("landscape", "portrait", "urban")` 固定元组 | :53 |
| `PHOTO_EXTS` | `{.jpg,.JPG,.jpeg,.JPEG,.png,.PNG}` 字面六拼写 | :54 |

- 源侧**平铺非递归**（`iterdir`，:70）；vault 侧只扫三个固定类目、各自平铺
  （:82-84），vault 根下散文件永不入扫。
- 目录缺失返回 `[]` 不报错（:68-69）→ 删掉 `urban/` 会静默退化成「全 NEW」。
- `_inbox/` 不在 `CATEGORIES` → 构造性排除（且已 gitignore）。
- CLI 仅 `--json` 一个开关（:197-203）；无 config/env/路径参数。

## 2. 匹配语义

- **主键 = 含扩展名的完整文件名，大小写敏感**（:73-75, :78-85）。集合运算：
  `src-vault`→NEW 候选、`vault-src`→MISSING 候选、交集→逐对 sha256 比对
  （:100-117）。无 stem、无 size/mtime/EXIF 通道。
- **内容身份 = 流式 SHA-256**（1 MiB 块，:58-64）；同名对**总是**全量 hash，
  全同步库也每次重读全部字节（无快路径）。
- **RENAME = 贪心首配**：仅当 NEW、MISSING 候选皆非空才做（:123）；hash 相等
  取第一个未消费项即 `break`（:127-135）。跨类目移动报 RENAME；同名跨类目
  重分类完全不可见（文件名仍匹配→按新类目报 OK）。改名+改内容不可检测
  （退化为 NEW+MISSING）。
- **DUPLICATE 是标志不是划分**：同名出现于多类目时追加（:108-110），同一名字
  仍继续进 ok/drift（:115-117）→ 六态**不构成划分**（DESIGN §10.1 明文要求
  保留）。vault-only 的跨类目重复**不**标 DUPLICATE，而是 N 条 MISSING。

## 3. 输出

### 3.1 `--json`（pm 必须逐字段照抄的形状）

顶层键序（:219-228）：`source_dir`（Windows 反斜杠串）、`vault_dir`、
`source_count`（源唯一名数）、`vault_count`（vault 文件总数，重复按份计）、
`ok` `[name, cat]`、`new` **裸字符串列表**（唯一非元组的键）、`missing`
`[name, cat]`、`renamed` `[new_name, vault_name, vault_cat, hash[:16]]`、
`drift` `[name, cat, src_h[:16], vault_h[:16]]`、`duplicate`
`[name, [cat…]]`（内层列表 sorted）。`ensure_ascii=False, indent=2` + 尾 `\n`。

顺序保证：new/missing 来自 `sorted` 差集；ok/drift/duplicate 外层 sorted 交集、
内层按 `CATEGORIES` 元组序（非字母序）；renamed 随 new 候选序。

### 3.2 人读模式

60 个 `=` 横幅 + 六行汇总（零也打印）+ 五个明细块（非空才打）；NEW/MISSING/
RENAME/DRIFT 各截 30 行 + `... and N more`，**DUPLICATE 不截断**（不对称）。
人读 hash 截 **8** 字符、JSON 截 **16**（两种宽度并存，pm 钉 16）。

## 4. 退出码

| 码 | 条件 | 行 |
|---|---|---|
| 2 | SOURCE 或 VAULT 不是目录（stderr `ERROR: source/vault missing: …`） | :205-210 |
| 1 | `new or missing or renamed or drift` 任一非空 | :237-238 |
| 0 | 其余（**DUPLICATE 不影响退出码**，docstring 明文有意为之） | :237 |

未捕获异常（hash 途中文件被删/锁，:61 无 try）→ Python 裸 traceback 退 1，
调用方无法与「有差异」区分——pm 需用独立错误码/结构化错误区分（见 §6）。

## 5. 只读性（已审计核实）

唯一 `open` 是 `path.open("rb")`（:61）；imports 无 `os/subprocess/shutil`；
零写、零 git、零网络。唯一进程内副作用是 stdout/stderr UTF-8 reconfigure
（:43-48，bare except pass——失败则后面 emoji 打印处 UnicodeEncodeError）。

## 6. 保留 vs 修复

**保留（契约，验收逐项比对）**：六态词汇及语义；DUPLICATE 不进退出码；
DUPLICATE 与 ok/drift 重叠；JSON 键名/键序/值形状（含 `new` 裸串列表）与
16 字符 hash；status 只读；平铺源 + 三固定类目拓扑（`/photo-inbox` skill
明文依赖）；`_inbox/` 构造性排除。

**修复（pm 有意偏离，验收时登记豁免）**：
1. 固定 `CATEGORIES` 静默无视新增类目 → pm 动态枚举或对未知子目录硬报错。
2. 扩展名字面六拼写，`.Jpg/.Png` 等被静默丢弃 → pm case-fold（DESIGN §10.1
   已定）。**验收注意：若真实库存在混合大小写扩展名，集合比对将天然不等。**
3. 贪心首配 RENAME 非最优匹配 → pm 显式报歧义或做正确二部匹配。
4. vault-only 跨类目重复不标 DUPLICATE 的定义不一致。
5. 无 I/O 错误处理（裸 traceback 退 1）→ pm 区分错误与差异。
6. 全量重 hash 无快路径 → pm 走 catalog stat-only（DESIGN §12 性能表）。
7. 源非递归扫描：`相册/` 一旦分子目录全库报 MISSING → pm 需明确策略。
8. **UNPUSHABLE 是 pm 新增第七态**：legacy 对 `.png` 完全同 jpg（全库 grep
   `UNPUSHABLE` 零命中）。当前真实库 `.png` 为零 → 该轴验收**空洞通过**，
   必须用合成 `.png` fixture 专项测试。
9. **UNSTABLE 是 pm 新增第八态（P3b-4 评审 #5，2026-08-24）**：读取期间持续
   变化（三轮双 stat 不稳）的名字整体退出六态分类（两侧都排除，防另一侧伪报
   NEW/MISSING），JSON 尾键 `unstable`（`[name, loc]` 形状）单列，**退出码算
   差异（非零）**——legacy 无撕裂防护，读到什么算什么；pm 状态未知即
   fail-closed。稳定库两跑集合不受影响（unstable 恒空）。

## 7. P5 指针改写清单（档案侧引用 sync_photos.py 的全部位置）

`<vault-root>\CLAUDE.md:34,44`；`photo-inbox\SKILL.md:17,32,133`；
`sync-portfolio-kb\SKILL.md:28,121`；`vault-doctor\SKILL.md:32`；
`record-structure-version.md:12`。`KB-维护速查.md` 通篇未提该脚本，无需改
（用户日常照片入口是 `/photo-inbox`，sync_photos.py 只是可选核对）。

真实库现状（2026-08-23 实测）：源 94 文件（56 `.jpg` + 38 `.JPG`，零 png）；
vault landscape 49 / portrait 6 / urban 24 = 79。
