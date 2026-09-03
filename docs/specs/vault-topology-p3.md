# Vault 侧拓扑与约束实测（P3 基线）

> 来源：2026-08-23 对档案 vault 的只读实地勘察（git 命令均为只读）。
> 与 [sync-photos-legacy-spec.md](sync-photos-legacy-spec.md) 配对，
> 二者共同构成 P3 `pm vault status` 的验收基线。

## 1. 仓库边界（关键事实）

| 路径 | .git | 角色 |
|---|---|---|
| `<vault-root>\` | 有 | vault 根仓：**本地 only、无 remote、永不推送**（用户裁定 2026-08-11，历史含证件材料） |
| `<vault-root>\摄影作品\` | 有 | **嵌套独立仓** → `skymanbp/photography-private`（GitHub Pages） |
| `D:\Photography\` | 无 | 主库不在 git 下（`.pm/` 已在此运行，无 git 摩擦） |

（`<vault-root>` = 档案 vault 根目录占位；`摄影作品` 实际位于其下若干层子路径，
公开仓不写本机真实路径。）

- vault 根仓的 `.gitignore:7` 把 `摄影作品/` 所在子路径整个排除——
  两仓互不嵌套管理。**pm 的 vault root = 摄影作品目录本身**，绝不以
  `<vault-root>\` 为根做任何 git 相关提示。
- 勘察时两仓 `--porcelain` 均为空（全净）→ pm 产生的任何脏项都会是唯一脏项，
  审计友好，但也意味着静默副作用无处藏身。

## 2. 展示集结构与命名

```
摄影作品/
├── .gitignore          # _inbox/  .ce/  _site/   ← 勘察当时无 .pm/（I11 待办）
├── .github/workflows/deploy-pages.yml
├── README.md · scripts/build_site.py
├── _inbox/ (gitignored, 含 _done/)
├── landscape/  49 文件
├── portrait/    6 文件
└── urban/      24 文件     合计 79，全 .jpg/.JPG，零 png/RAW/侧车，零子目录
```

> **截至 2026-09-03 的更正（本文是 2026-08-23 的勘察快照，正文保持当时口径）**：
> 上面 `.gitignore` 那行的「无 `.pm/`」已不成立——展示集仓 2026-08-23 的
> commit `2d81d36` 追加了 `.pm/` 行（用户批准，DESIGN-COMMANDS §10.3 第 3 项），
> I11 待办随之关闭；此后又追加了 `.ccm/`。文件数与其余勘察数字仍是快照当时的值。

- 追踪文件 83 = 79 照片 + 4 基建文件；照片为普通 blob（**无 LFS**）。
- 无 manifest；元数据索引在下游 portfolio `data/photos.json`（按 Pages URL 键）。
- **文件名 = 全链路 join key**（主源 → 展示集 → Pages URL → photos.json），
  逐字节一致，类别只由父目录编码。必须原样保全的极端名：
  `_DSC0378-已增强-NR-1.JPG`、`_DSC2065~4-edit.jpg`、`_DSC8707-HDR_3_1.JPG`
  （中文后缀、`~`、大小写混合扩展名；历史上 GBK 管道毁过中文名，
  record-structure-version.md:319 有案）。

## 3. 承重不变量：字节冻结

`摄影作品/README.md:7-9`：仓内副本必须保持原始字节——sync_photos.py 用
sha256 对主源比对。源侧压缩方案曾被否决（会把 79 张全变 DRIFT），压缩改在
**部署期**：`build_site.py` 重编码进 `_site/`（3200px/q90、剥 EXIF 含 GPS），
只有 `_site/` 上 Pages。**pm 对展示集文件任何改字节的操作（EXIF 回写/重编码/
方向修正）都会打断检测器——写路径只允许原字节直拷与 supersede 复合。**

## 4. 对自动化工具的硬规则（pm 必须遵守）

1. 先确认后动作（档案 CLAUDE.md:10，I11 的上游根据）；每次改动登记
   `record-structure-version.md` Change Log（:11）。
2. 子项目 git 独立，永不与父仓混用（:51）；vault 根仓永不 push（:167-169）。
3. `/photo-inbox` skill 绝对硬约束（SKILL.md:28-35）：无用户审批不落盘/不写
   photos.json；坐标不可编造；归档必须 相册+摄影作品 双落；原件进 `_inbox/_done/`
   永不删除；**永不自动 git push**（SKILL.md:34,121 + KB-维护速查.md:169 三处独立）。
4. 版本策略（CLAUDE.md:151-162）：原位 supersede（新文件 + git rm 旧、同一提交），
   git 即档案库，禁 legacy/ 副本——工作树只保当前真相。与 pm 的隔离区并不冲突：
   `.pm/trash/` 在 gitignore 之后不属于工作树内容（这正是 I11 要先谈妥的原因）。

## 5. `.pm/` 现状（I11 前提核实）

- 两个 `.gitignore` 都无 `.pm/`；`git check-ignore .pm/` exit 1（不被忽略）；
  无全局 excludesfile。→ 现在建 `.pm/` 会立即成为 untracked 脏项并被
  `git add -A` 吞进去。**I11 门禁属实必要**：建 root 前先征得用户同意在展示集
  `.gitignore` 追加 `.pm/`（比照 `.ce/` 既有惯例，.gitignore:6-8 明文「不入库」）。
- 读-only 的 `pm vault status` 不需要 vault 侧 `.pm/`：vault 文件缓存放主库
  `.pm/` 下（比照 P2 备份盘缓存先例），I11 只挡写路径（push/ingest）。

## 6. 当前差异基线（验收预期值）

record-structure-version.md:312,319 记录的**用户挂起既知人工步**：

- `NEW=15`：主源待分类（_DSC2140_1.jpg、_DSC8617-HDR.JPG、_DSC8673.jpg、
  _DSC8707-HDR.JPG、_DSC8940_2.jpg、_DSC9157.jpg、_DSC9310.JPG、_DSC9523.JPG、
  _DSC9583_2.jpg、A7R06633.jpg、A7R07989_1.jpg、DSC08731.JPG、DSC09245.JPG、
  DSC09354.jpg、DSC09590.jpg）
- `RENAME=1`：主源 `_DSC9014.JPG` ≡ 展示集 `landscape/_DSC9013_2.JPG`
  （sha 相同名字不同，登记为待人工纠正的缺陷，非命名惯例）
- `MISSING=0 · DRIFT=0 · DUPLICATE=0`

P3 验收：`pm vault status --json` 与 sync_photos.py `--json` 在此真实语料上
**集合逐项一致**（15+1+0+0+0 + ok 78），UNPUSHABLE 轴因 png=0 空洞通过 →
必须补合成 `.png` fixture 专测。**pm 对这 16 项只报告，不自动解决。**

## 7. 主库侧参与面

vault 契约只涉及 `相册/`（94 文件，平铺，全 jpg/JPG）；`成片/`（198 文件，
`YY-MM-地点` 目录）不参与。相册 94 已含在主库 catalog 4855 条内 →
`pm vault status` 主源侧可走 stat-only 快路径（DESIGN §12 性能表）。
