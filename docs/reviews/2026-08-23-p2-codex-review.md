# P2 独立评审（codex gpt-5.6-sol · xhigh）— commit b0a1363

**日期**: 2026-08-23 · **评审对象**: `git show b0a1363`（P2: import/backup/clean-staging planners）
**verdict**: **不可以放行真实库 apply**（先修复下列发现）
**状态**: P2.1 修复（commit 5ce1ddb，90/90）→ **codex 二轮复审**（见文末）
判 7 FIXED / 4 PARTIAL / 1 NOT-FIXED + 1 新 major → **P2.2 补齐
（2026-08-23，96/96 测试）**：残留缺口全部闭合（映射见 DESIGN §16）。

---

## 主线核读结论（对 codex 输出逐条对照源码后的裁定）

共 12 条发现：5 critical / 6 major / 1 minor。逐条核读后**全部成立**（无一被反驳）。
关键定性：**没有任何一条构成"字节被销毁"的路径**——所有被批评的路径终点是
conflict（I5 兜底）、trash 可还原状态、或落错卷的多余拷贝；critical 的含义是
**契约承诺未兑现**（按 UUID 认盘、三副本执行期保证、supersede 原子性/自动复位），
以及可产生「看似成功但目标缺失」「写到错误卷」的状态。

**共同根因（P2.1 修复的主轴）**：计划模型过于扁平——

1. **Plan 不携带 root 身份**（只存生成时的盘符路径）→ cx-1 换盘符错卷执行；
2. **没有"复合组"概念**（supersede = 两个可拆散的独立 item）→ cx-2/cx-4/cx-5
   的 --only / --keep 拆对、失败中断无自动复位；
3. **执行期不复验计划前提**（witness 不入计划）→ cx-3 clean 的三副本只在
   计划期成立；
4. 目标键未按 Windows 语义规范化（大小写）→ mj-2/mj-6；
5. Names 空地点边角 + archive 层定义过宽 → mj-1/mj-5。

## 发现清单（codex 原文，编号为归档号）

### critical

- **cx-1** `app/Main.hs:667,677,388` — 备份计划持久化了生成时的盘符路径。
  计划在 E: 生成、备份盘后来挂载为 F: 时，apply 从 F 盘读到计划却按
  `plRootPath=E:` 执行；若 E: 已被另一卷占用，Copy 落错卷、hash 恰好匹配的
  Quarantine 甚至可移动错误卷文件，绕过「按 UUID 认盘」。
  修复：Plan 持久化 root UUID；apply 时重新发现并校验 UUID 再绑定执行 root；
  Exec 拿锁后复验 root-id。
- **cx-2** `src/Pm/Diff.hs:62, app/Main.hs:694, src/Pm/Exec.hs:111, src/Pm/Doctor.hs:85` —
  supersede 只是两个独立 item：`--only` 只选 Quarantine → 旧 dst 入 trash、
  Copy 未执行、命令可返回成功且目标空缺；全量执行中 Quarantine 成功后
  Copy 失败/中断也留同样状态；Doctor 视 JFailed 为 terminal、无配对逻辑，
  §6.5 声称的「doctor 从 trash 复位 victim」**未实现**。
  修复：supersede 单一原子计划项（或组闭包）；失败自动复位旧目标。
- **cx-3** `app/Main.hs:646,654,682, src/Pm/Exec.hs:258` — clean 的三副本活体
  核对只在生成计划时发生；计划保存后见证退化再 apply，Exec 只验 victim 自身
  hash 即隔离；配合 `trash empty` 可删掉最后一份正确字节。
  修复：clean Plan 持久化两侧 witness（root UUID+路径+sha），每个 Quarantine
  执行前重发现备份 root 并重 hash 两侧见证；trash empty 对 clean 记录再验一次。
- **cx-4** `app/Main.hs:713,743,779` — `--keep` 不检查条目是否为独立的
  NEEDS-DECISION：对备份 `[Quarantine, Copy]` 的 Copy 做 `--keep dst` 只跳过
  Copy，Quarantine 仍 pending，apply 后旧目标反而入 trash；`--keep both`
  仍隔离旧目标，并非「并存」。
  修复：--keep 仅限非复合组的 NEEDS-DECISION Copy；复合组整体解析改写。
- **cx-5** `app/Main.hs:762,774,694` — `--keep src` 追加的 Quarantine/Copy 对
  没有组 ID，`--only` 可拆开。修复同 cx-2（组 ID + 选择闭包）。

### major

- **mj-1** `src/Pm/Names.hs:23,37, src/Pm/Import.hs:75` — `26-04--Raw` 的空地点
  被 `-Raw` 后缀掩盖，落到 `Raw\2026\26-04--Raw\` 而非 unrecognized。
  修复：先剥 `-Raw` 再验地点非空；补空地点/仅后缀/大小写后缀测试。
- **mj-2** `src/Pm/Import.hs:96,100` — dup-target 与目标存在性查询用区分大小写
  的 `Map FilePath`，Windows 同名不同 case 的目标在计划期查不出（执行期由
  I5 兜底成晚期 conflict）。修复：Windows 语义规范化键（normalise + case-fold），
  拿不准宁可 HELD。
- **mj-3** `src/Pm/Import.hs:95,99` — 撞目标只排除撞的文件本身，不排除其事件/
  同 stem 侧车组 → 可产生孤立侧车，违反 §7「侧车跟随」。修复：冲突升级到组。
- **mj-4** `app/Main.hs:523,524,547` — backup init 的主库嵌套检查是区分大小写
  的文本比较，`D:\PHOTOGRAPHY\Bak` 可绕过，在主库内部建备份 root 形成递归。
  修复：canonical path/volume identity + 不区分大小写祖先判断。
- **mj-5** `src/Pm/Clean.hs:60,67` — 「归档副本」实际=任何非 staging 条目（含
  相册），而契约限定 Raw/成片。修复：archiveBySha 只收首组件 Raw/成片；
  补「只有相册副本必须 HELD」测试。
- **mj-6** `src/Pm/Clean.hs:102,108` — 活体核对只比 size+mtime，位腐/同尺寸
  恢复时间戳的覆盖可骗过。修复：两侧各至少一份见证真实重 hash；stat 只做
  快速淘汰。

### minor

- **mn-1** `src/Pm/Win.hs:68,71,74` — FFI 用 `ccall`，i686 构建时与 stdcall
  ABI 不符（x86_64 无差异，当前目标不受影响）。修复：`WINDOWS_CCONV` CPP 宏。

### 通过项（codex 明示）

- Import 静默漏桶检查通过：staging 条目穷尽分入六桶之一，无静默丢失。
- I5 执行期无绕过：fail-if-exists 落位挡住大小写碰撞/并发创建/既有目录覆盖。
- 待修改排除完整（`待修改\` 全后代不入 clean）。
- FFI 其余检查通过：x64 ABI、宽字符指针、64 WCHAR 缓冲区、失败路径均正确。
- resolveKeep 的 `maxIx+1/+2` 不重排既有序号；`freeVersionName` 盘面检查有效。

## 对当前待执行事项的影响

- **归档计划 `20260823-032836-06cc4e`（import，主库内，220 项）**：逐条对照，
  该计划本身不落入任何 critical 路径（主库 D: 盘符固定 → cx-1 不适用；计划内
  0 个 supersede/NEEDS-DECISION 项 → cx-2/4/5 不适用；真实事件名均有地点 →
  mj-1 不触发）。但评审 verdict 是对功能面的整体判定，**是否先修复再 apply
  由用户裁定**。
- **backup / clean staging**：cx-1/cx-2/cx-3 直接命中其核心路径，**修复前
  不应在真实备份盘上执行**（备份盘本就未挂载，天然冻结）。

## P2.1 修复方案骨架（已执行，commit 5ce1ddb）

1. Plan 结构升级：`plRootId`（UUID）+ item `piGroup`（复合组 ID）；apply 按
   UUID 重发现 root、`--only`/resolve 按组闭包（吃掉 cx-1/2/4/5）。
2. supersede 失败自动复位：execPlan 组内 Copy 失败 → 立即从 trash 复位
   victim（或 doctor 增配对行）（cx-2 后半）。
3. clean Plan 携带 witness 三元组，Exec 前逐项重验（cx-3 + mj-6 的重 hash）。
4. Import 键规范化 + 组级 dup 拒绝 + Names 空地点修复（mj-1/2/3）。
5. backup init 祖先判断规范化（mj-4）；archiveBySha 收紧 Raw/成片（mj-5）；
   FFI CPP 宏（mn-1）。

---

## 二轮复审（codex，对 commit 5ce1ddb）与 P2.2 收口

判定：cx-4/cx-5/mj-1/mj-5/mj-6/mn-1 FIXED；cx-1/cx-2/cx-3/mj-2/mj-4
PARTIAL；mj-3 NOT-FIXED；另报 1 条新 major（复位后同计划重跑的 oid/trashRel
复用会污染 doctor 豁免、undo 剔除与 trash 生命周期）。verdict 仍不放行。

**P2.2 修复（96/96 测试，含 6 个新用例）**：

| 缺口 | 修复 |
|---|---|
| cx-1 残留（--apply 即时路径可带 rootId=Nothing 执行） | runImport/runClean 无 root-id 拒绝出计划；executePlanNow 对 rootId=Nothing 一律拒绝（fail-closed 无例外） |
| cx-3 残留（clean --apply 绕过执行期重验） | savePlanAndMaybeRunWith 钩子：即时路径确认后同走 recheckCleanPlan |
| 新 major（复位后重跑的记录复用） | doctor 豁免与 undo 剔除改**顺序感知**（~r 只配对紧邻其前最近一次同 oid Done）；trash empty 按 trashRel 去重。测试含尖锐断言：重跑后删 trash 文件 → 第二次隔离必须报 C4 |
| mj-3（返修不升级 stem 组） | irReworkKin：主文件返修 → 同 stem 待拷文件悬置 NEEDS-DECISION |
| mj-2 残留（无 normalise） | foldPath = toLower · normalise |
| mj-4 残留（junction 别名） | backup init 双侧 canonicalizePath 后再比较（残余：极端卷别名场景无法纯文本识别，已文档化） |
