# P3b codex 独立评审归档 · 第二卷（第十四轮起）

第一卷 [`2026-08-24-p3b-codex-review.md`](2026-08-24-p3b-codex-review.md) 收
一~十三轮，触及 750 行预算（cc-enforcer plan §4.1）后按 P3b-8 拆 §16 的先例
续写到本卷。判定表、类级扫描、突变表、残余清单的写法与第一卷一致；残余清单
每轮**重建**而不是增量追加，以本卷最新一轮的为准。

---

# 第十四轮（复审 P3b-16，commit 91339b7；gpt-5.6-sol 独立评审）

**verdict：NO-GO；收敛性：已收敛**——十二轮设立的判据（"仓库里还有没有任何
『拼 `.pm` 路径后按名字操作』的生产入口"）下，⑤ 类清单**首次为空**。阻断项
不是新的按名字操作入口，而是**已解析路径上的文件/目录类型语义**：十三轮的
修复自己把一个谓词收窄了。

## 逐条判定与处置

| 发现 | codex 判定 | 核实 | 修复 |
|---|---|---|---|
| **major** `probePmExists` 收窄 | 新发现（src/Pm/Doctor.hs:235）：`.pm/trash` 中真实存在的**目录型**复位源被 `doesFileExist` 判为不存在；new 存在且 FpDir 相符 → R2 Warn → `--repair` 补假 Done | **成立，但触发路径更正**：两处复位构造点（src/Pm/Undo.hs:137、src/Pm/Exec.hs:278）都写死 `FpFileSha`，隔离载荷也只收文件，现有构造器产不出 FpDir 的 trash 源——但**不需要** FpDir：trash 里一个占了载荷名的目录 + victim 原位且 sha 相符，同样落 (False, True) → `verifyFp` 通过 → R2 Warn。修前该格是 R3 Warn（不在 `repairDone` 白名单），另一格从 R1 Info 掉成 R? Bad。**这是 P3b-16 自己引入的严重度上升** | `probePmExists` 加 `PmEntryQ`（`PmEntryAny` / `PmEntryFile`），调用点**显式**说明问哪种存在：复位源 Any，tmp 落位点 File（pm 自建普通文件，`staleTmpFiles` 也只收 NamePlain） |
| 1 doctor restore 源 | PARTIAL | 前缀剥离对 `.pm`/`.PM`/`.pm.` 正确、PM-LINK 不进 `repairDone`/`c5`、new 侧 `existsAny` 受 `userRelOk` 约束、`verifyDone` 对 rename 不作路径访问——四点均成立；未闭合的就是上面那条 | 同上 |
| 2 类级修复 | FIXED；建议删掉 Bool 版 `confinedUser` | 三个 helper 的返回路径在 open/hash/unlink/rename 全部被使用（它逐 file:line 核对）；`confinedUser` 与 `confinedUserPath` 逐行等价却是重复实现，且 Copy dst 之后两次重拼 `root </> opDstRel`（src/Pm/Exec.hs:449、:485） | **采纳**：删除 `confinedUser`；`execCopy` 用 `confinedUserPath` 的返回路径，`execCopy'` / `execCopyTmp` 接收 `dstAbs`，`execCopyTmp` 不再持有 `root` |
| 3 测试 | PARTIAL | 三条 P3b-16 用例与"每代快照单独 symlink"写法均成立（它具体说明了撤哪一行、为何转红）。缺口：没有用例钉住"返回路径必须被使用" | +2 例（见下）；"返回路径被使用"用例**登记未做**（见残余） |
| 4 文档 | PARTIAL（2 处） | "返回路径后调用方**无从**绕过"当时不实（Copy dst 仍是 Bool 预检 + 重拼）；"十三轮收口"因目录型回归不成立 | 删 Bool 版后前者成立；REVIEW-LOG 加「十四轮更正」 |

## 类级扫描：安全重构时谓词被悄悄收窄

这一轮的成因与前三轮不同——不是"按名字操作"，而是**替换谓词时没有保持宽度**。
按类扫描：把 P3b-14~16 三轮 diff（`git diff a2efb3f..HEAD -- src/Pm/`）里所有
被受信探针 / 受信取用口替换掉的原谓词逐条与替换后比宽度：

按**删除的谓词实现点**计数（`git diff a2efb3f..91339b7 -- src/Pm/` 里以
`-` 开头、含 `doesFileExist` / `existsAny` / `doesDirectoryExist` /
`doesPathExist` 的行）。**排除**三行（十六轮 minor 更正——初版把它们统称为
"未换实现的 `doesPathExist`"，类型说错了两处、性质说错了一处）：
`newEx (existsAny)` 与 `raced (doesFileExist)` 只是移动位置、实现未换；
`slotOccupied` 的 `doesPathExist` 不是仅移动，而是**扩大**为"doesPathExist +
悬空链接（`pathIsSymbolicLink`）+ 异常一律按占用"——它不属本轮"受信探针
替换"这一类，故不入表，但方向是扩宽而非收窄：

| 原谓词（删除行） | 文件 | 替换为 | 宽度 |
|---|---|---|---|
| `exists <- doesFileExist fp` + 按名字读 | Catalog / **Journal**（十五轮 minor：初版漏列）/ Plan / Trash(manifest) / Config(root-id + 侧缓存) | `readPmState` / `readSideCache`（缺席 = `isDoesNotExistError`） | 同宽（5 处） |
| `tmpEx <- doesFileExist mtmp` | Doctor | `probePmExists`（文件） | 同宽 |
| `trashEx <- doesFileExist (trashDir …)` + `sha256File` | Doctor | `probePmSha`（文件 + 同句柄 hash） | 同宽 |
| **`oldEx <- existsAny (root </> old)`**（文件**或**目录） | Doctor | `probePmExists`（**只有文件**） | **收窄** ← 本轮 major |
| `isD <- doesDirectoryExist (base </> p)`（清理侧枚举） | Doctor `staleTmpFiles` | `probeName` 只收 `NamePlain` | 删除侧收窄 = **保守方向**（少删不多删） |

读/探测侧 8 处只有 `oldEx` 一处收窄；清理侧那一处是有意的保守收窄。修法不是
"把 `probePmExists` 改成 any"（那会让 tmp 探测放行目录占名），而是让**每个
调用点显式声明问哪种存在**：

    data PmEntryQ = PmEntryFile | PmEntryAny
    probePmExists :: PmEntryQ -> FilePath -> FilePath -> IO (Either String Bool)

## 突变验证

| 删掉的屏障 | 结果 |
|---|---|
| 复位源探针 `PmEntryAny` 改回 `PmEntryFile` | `caseRestoreSrcFpDir` **FAIL** + `caseRestoreSrcFpFile` **FAIL**（2/189），实得恰为 `[("R2",Warn)]`——正是本轮预言的那一格 |
| Copy dst 返回路径改回重拼 `root </> opDstRel` | **无用例转红**——这就是十四轮 #3 指出的缺口，登记（下） |

两条用例故意**拆开**而不是写在一个函数里：十三轮的粒度教训——同一函数里前
一条断言先炸，后一条永远跑不到，等于没钉。

回归：189/189（+2），GHC 警告 0；真实库只读四连不变（doctor 0 / trash list 0 /
status 1 / vault status 1；doctor 1917 ms、vault status 7184 ms，本次为改动后
首跑，未区分冷热缓存）。

## 残余（更新）

- **"返回路径必须被使用"无用例**（十四轮 #3，新登记）：把 `execCopy'` 的
  `tmpAbs` 改回 `tdir </> tname`、或 dst 改回重拼，现有用例照样绿——注入
  junction 后 `confinedTmp` 返回 Nothing 提前退出，重拼分支不可达。十四轮给
  的设计：root 本身做成可切换的 junction（A → B），在 `CpRenAfterIntent` /
  `CpQuarAfterIntent` 切到诱饵库 B，断言只动 A、B 零改动；重拼的突变会改动 B。
  **未做**：`resolveUnder` 以 root 为基准逐级下降，root 自身是 junction 时它
  的行为要先探针（可能直接拒绝，那这个设计需要别的别名层）。
- **TOCTOU（check-use 窗口）**：同十三轮；`execQuarantine'` 建父目录与 move 之间
  无复检（十四轮再次确认属已登记项，非新缺口）。
- `createRootInfo` 建 `.pm` 之后没有再次解析 tmp/final（十三轮 #2 后半，未修）。
- `openExclusiveBinary` 缺外层 `mask`；`requirePmTrusted` 深度 1 枚举与使用点是
  两个快照；`Pm.Config.writeRootInfo` 裸覆盖写（仅测试 fixture）；`Pm.Scan` 的
  symlink 探测异常按非 symlink 继续；`Pm.GitGuard` / `Pm.Vault.photosJsonRef`
  读库外用户文件不属 `.pm` 辖区。
- `probeName` 只把 2/3 当缺失（十三轮"建议补入的错误码：空"）。
- **status 语义扩展**：缓存失信计入 exit 1，DESIGN §5.1 的 0/1/2 描述宜补一句。
- **未证实项**：8.3 短名、Unicode 兼容等价、保留设备名、云占位/Dedup 实际
  reparse 形态、能让 `canonicalizePath` 抛异常的输入、ACL 库、UNC/断网形态。
- **慢介质开销**：无超时，实测待用户插盘。
- `tamperMark` 字符串哨兵；`opSrcAbs` 无 root 归属校验；`writeConfig` 普通
  覆盖写；备份盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU。

---

# 第十五轮（复审 P3b-17，commit 46c4d12；gpt-5.6-sol 独立评审）

**verdict：NO-GO——但两条代码判据均判「已收敛」、无新运行时缺陷、"无需代码
修复"**；NO-GO 只落在两处文档 minor。这是十二轮设立判据以来第一次代码侧
零阻断。

- 收敛性（按名字操作）：已收敛——`.pm` 的状态读写、hash、落位均进入受信
  取用口或消费解析返回路径；剩余按名字命中均属 no-follow / 占位探测或用户
  数据探测（`restoreQuarantine` 的 `victimAbs` 预探测、`slotOccupied`）。
- 收敛性（谓词宽度）：已收敛——它**独立**复扫 `a2efb3f..HEAD` 的删除谓词与
  P3b-17 自身变更，当前调用点均保持或扩大原宽度。

## 逐条判定与处置

| 项 | codex 判定 | 核实 / 处置 |
|---|---|---|
| 1 `PmEntryQ` | FIXED | 两态够用；C1 的 File 方向保守正确（目录占 tmp 名 → C1 Info，孤儿清理只收普通文件）；Copy dst 的 `doesFileExist` 不是重构收窄（Copy 只落文件，目录占名由 no-replace move 拒绝，不写 Done）；R 矩阵 (True,True) 的"目标被占"对目录形态仍准确且不进修复线 |
| 2 Copy dst 路径流 | FIXED | `dstAbs` 在 doesFileExist / sha256File / createDirectoryIfMissing / moveFileNoReplace / race 探测 / statSnap+hash 全部被使用；生产调用图无 Bool 限域旁路（`Pm.Win.pathUnder` 仅旧测试使用）。`resolveUnder` 对缺失末段从 canonicalized base 拼回余段，返回字符串可能与 `root </> rel` 不同但指向同一位置——预期加固 |
| 3 测试 | PARTIAL | 两条新例各自钉住（它复述了突变后各落 R2 的路径）；"返回路径必须被使用"仍属**已登记覆盖残余，不是阻断项**——当前签名与调用图已能静态证明 dst 全程用返回值 |
| 4 文档 | PARTIAL → 两处 minor | ① 第二卷谓词表漏列 `readJournal` 的旧 `doesFileExist`（同宽、结论不变）——**核实成立**（`git diff` 删除行 `a/src/Pm/Journal.hs: exists <- doesFileExist fp`，现由 `readPmState root "journal.ndjson"` 替换）；表已改为按删除的谓词实现点逐文件列出。② README 的 P3b-16 条目仍称"调用方只能用返回值"，与 P3b-17 删 Bool 版的陈述直接矛盾——**成立**，已加入与 REVIEW-LOG 相同的「十四轮更正」 |

## "返回路径必须被使用"用例——它给的可行设计（登记，未做）

十四轮我登记的理由是"root 自身是 junction 时 `resolveUnder` 的行为要先探针"。
十五轮读源码回答了：`resolveUnder` 只 canonicalize base、**不对 base 调用
`probeName`**，所以 root 本身可以是 junction。最小用例：`rootLink` junction 指
向 A，A/B 各放不同哨兵；以 `rootLink` 执行 Copy，在 `CpCopyAfterFlush` 把
junction 改指 B——正确实现只落 A；把 `execCopyTmp` 突变回 `root </> opDstRel`
会落 B。它标注的假设：Windows 允许在 A 的 journal/lock 句柄打开时重定向该
junction（须由用例的设置阶段实际验证，失败则报告平台前提）。本轮是文档收口，
不引入代码改动；进残余。

回归：代码零变化（`git diff 46c4d12..HEAD --stat` 只有 README / REVIEW-LOG /
第二卷），189/189 不变，pm 0.3.15 不变。

## 残余（更新）

- **"返回路径必须被使用"无用例**：设计已可行（见上）——**已于 P3b-18 做掉**
  （见下节）。其余同十四轮：
- **TOCTOU（check-use 窗口）**；`createRootInfo` post-mkdir 未重解析；
  `openExclusiveBinary` 缺外层 `mask`；`requirePmTrusted` 深度 1 枚举与使用点
  两个快照；`writeRootInfo` 裸覆盖写（仅 fixture）；`Pm.Scan` symlink 探测异常
  按非 symlink 继续；`Pm.GitGuard` / `photosJsonRef` 读库外用户文件。
- `probeName` 只把 2/3 当缺失；**status 语义扩展**待 DESIGN §5.1 补一句。
- **未证实项**：8.3 短名、Unicode 兼容等价、保留设备名、云占位/Dedup 实际
  reparse 形态、能让 `canonicalizePath` 抛异常的输入、ACL 库、UNC/断网形态。
- **慢介质开销**：无超时，实测待用户插盘。
- `tamperMark` 字符串哨兵；`opSrcAbs` 无 root 归属校验；`writeConfig` 普通
  覆盖写；备份盘符 fixture、位移槽 99、root-id tmp 残留、.gitignore TOCTOU。

---

# P3b-18：十四轮 #3 残余闭合（非评审轮；用户裁定"等待期间做"）

十六轮因 codex 用量上限中止、额度重置后重跑期间，按十五轮给的设计把"返回
路径必须被使用"用例做掉。在独立 worktree（分支 `p3b18-returned-path`，基于
ca260cb）开发，十六轮正在读的工作树零改动。

## 用例：`caseCopyDstUsesResolvedPath`（StateGuardTests）

| 步骤 | 内容 |
|---|---|
| 布置 | 库 A、诱饵库 B 各有 `.pm` 与相同身份 `m`；`rootLink` junction → A |
| 执行 | 以 `rootLink` 为 root 跑一条 Copy（dst `相册/x.jpg`） |
| 注入 | `CpCopyAfterFlush`（tmp 已写完并设好 mtime、落位 move 之前）：`removeDirectoryLink rootLink` + `mklink /J rootLink B` |
| 断言 | `ODone`；`A/相册/x.jpg` 存在且内容正确；`B/相册/x.jpg` **不存在** |

B 给同样的身份与目录结构是有意的：让重拼版实现能"顺利"落到 B，失败原因只
可能是"用了哪条路径"，不混入别的拒绝理由。

## 突变验证

| 突变 | 结果 |
|---|---|
| `execCopy` 把传给 `execCopy'` 的 dst 改回 `root </> opDstRel op`（P3b-17 之前的形状） | **FAIL**（`doesFileExist (libA </> dstRel)` 得 False——文件沿改指后的 junction 落到了 B） |

## 平台前提（十五轮标注为假设，本例实证）

A 内 `journal.ndjson` 与 `lock` 的句柄打开期间，删除并重建 junction 成功；
已打开的句柄继续指向 A 的对象，`JDone` / `JCleanShutdown` 都写进了 A 的
journal。前提由检查点内直接执行验证——不允许则 mklink 非零退出抛异常，用例
失败并暴露前提，而不是静默跳过。

回归：190/190（+1），GHC 警告 0，pm 0.3.16。真实库只读四连待合并 main 后重跑。

---

# 第十六轮（复审 P3b-17b，commit ca260cb；gpt-5.6-sol 独立评审；额度重置后重跑）

首跑在第 38 个探查命令后被 codex 用量上限中止（`turn.failed`："You've hit
your usage limit"），后三次重试 0 exec 立即失败；用户裁定"不用换，额度刚刚
重置了"后重跑，74 次探查完成。

**verdict：NO-GO——代码与两条收敛性判据仍无阻断**（明确"维持第十五轮判定"，
并确认 `git diff 46c4d12..HEAD` 代码零变化：`.hs/.c/.yaml/.cabal` 过滤后的
diff 与 name-only 均为空）；NO-GO 只落在一处文档 minor。

| 项 | codex 判定 | 核实 / 处置 |
|---|---|---|
| 十五轮 minor ① 谓词表 | PARTIAL | `readJournal` 已补、计数口径已声明——但紧接的排除说明把 `newEx`（实为 `existsAny`）、`raced`（实为 `doesFileExist`）统称为"未换实现的 `doesPathExist`"，且 `slotOccupied` 并非仅移动而是**扩大**（补了悬空链接与异常分支）。**核实成立**（与我自己 `git diff` 删除行输出逐行对照：`-    newEx <- existsAny …`、`-  raced <- doesFileExist dstAbs`、`-  ex <- doesPathExist (trashDir …)`）。已按它的建议逐项标注类型，并说明 `slotOccupied` 因不属受信探针替换类而排除、方向是扩宽 |
| 十五轮 minor ② README | FIXED | 措辞与 REVIEW-LOG 十四轮更正一致 |
| 十五轮章节转述 | 准确 | "无需代码修复"与残余登记措辞均确认；用例设计与源码相符（`resolveUnder` 只 canonicalize base；`CpCopyAfterFlush` 在持有 `dstAbs` 的落位前） |

十六轮读的是 ca260cb 的工作树，因此它看到的"返回路径必须被使用"仍是登记
残余、测试数仍是 189——P3b-18 当时在独立分支上，尚未合并（见上节）。

最小修复集：仅修正谓词表第 33–36 行的类型说明；无需代码改动。已修（本文件
上方的排除说明即为修正后文本）。

---

# 第十七轮（复审 P3b-17c + P3b-18，commit 324501e；gpt-5.6-sol 独立评审）

**verdict：GO**——"生产逻辑未变，第十六轮 minor 已准确闭合，P3b-18 钉住既定
Copy 路径回退突变，且两条代码判据继续收敛。新发现：无。合并前最小修复集：空。"
这是 P3b 门禁自第一轮以来的第一个 GO（64 次探查）。

- 收敛性（按名字操作）：已收敛——`src/`、`cbits/` 无 diff，Copy/Rename/
  Quarantine 继续消费限域助手返回路径，维持十五/十六轮判定。
- 收敛性（谓词宽度）：已收敛——复位源 `PmEntryAny`、tmp `PmEntryFile`，维持原判定。
- 生产代码零变化：是（`app/Main.hs` 与 `package.yaml` 仅版本字面量 0.3.15 →
  0.3.16；唯一测试逻辑变更在 `test/StateGuardTests.hs`）。
- 十六轮 minor：FIXED。

## 对 P3b-18 用例本身的细评（它是被审对象）

| 点 | 判定 | 要点 |
|---|---|---|
| ① 返回路径是否真的被使用 | 成立（针对既定落位路径突变，非逐分支穷举） | 把 `execCopy` 下传实参改成 `root </> opDstRel op` → 改指后父目录创建、move、复核都沿 B → A/B 断言判红；只改检查点**之后**的实际使用点（父目录创建 / move / 落位复核）也会红。**不会红的单点突变**：只改落位前的 dst 预检（改指尚未发生）、目标缺席时不执行的 sha 分支、只在 move 失败分支执行的 race 探测——本例不覆盖这三处 |
| ② 诱饵库 B 同身份 | 充分，无假绿 | 突变版确会 `ODone`，但"A 有且内容正确 + B 无"三项断言足以区分落位；`libB/dstRel` 不存在不是整棵 B 的零改动快照，但既定重拼突变必然把目标文件落到 B |
| ③ 改指后按 root 名字的访问 | 无 | `execCopyTmp` 不持 root；`CpCopyAfterFlush` 后只用 `takeDirectory dstAbs` / `tmp` / `dstAbs`；journal 与 lock 均经已打开句柄。平台行为仍属运行时假设，用例直接删除并重建 junction、无跳过分支 |
| ④ Rename / Quarantine 对称用例 | 已登记残余，非阻断 | 两条已用返回路径且调用图可静态证明；可补对称突变测试，Quarantine 优先级略高 |

## 残余（同十五轮清单，"返回路径必须被使用"已闭合；新增一条）

- **Rename / Quarantine 的"返回路径必须被使用"对称用例**（十七轮 ④，Quarantine
  优先）；以及 P3b-18 用例不覆盖的三处单点突变（落位前 dst 预检、目标缺席不执行
  的 sha 分支、move 失败分支的 race 探测）。
- 其余：TOCTOU、`createRootInfo` post-mkdir、`openExclusiveBinary` 外层 `mask`、
  `requirePmTrusted` 快照、`writeRootInfo` fixture 覆盖写、`Pm.Scan` symlink 异常、
  `probeName` 错误码、status 语义扩展、未证实名字/ACL/UNC 形态、慢介质、
  `tamperMark` / `opSrcAbs` / `writeConfig` / 槽位 99 / root-id tmp / .gitignore TOCTOU。

回归（merge 后 main，pm 0.3.16）：190/190，警告 0；真实库只读四连 doctor 0
（678 ms）/ trash list 0 / status 1 / vault status 1——与 P3b-15 起每轮相同的
集合（status 1 = 暂存区事件 + 索引差异；vault 1 = 15 NEW 待 P4 GUI 分类）。
public 同步：链内首推遇 GitHub 504，手动重推成功（origin/main = public = 5c2cd4b）。

**门禁满足 → 按用户 2026-08-24 裁定，AskUserQuestion 请裁定
`pm apply 20260824-030200-0c238a`（6 项 Raw 事件夹改名，undo 可逆）。**

## 真实写入（用户裁定"全量执行"，2026-08-24）

`pm apply 20260824-030200-0c238a`：6/6 → DONE，1071 ms。盘上核实
`Raw/2023/23-12-Turkey-Raw`、`Raw/2025/{25-06-USA,25-08-PR,25-08-Tennessee,
25-11-Alaska,25-12-Colorado}-Raw` 均已就位；`Raw/2025` 余下 3 个 `RAW-2025-*`
是该计划生成时的 3 项拒绝，不是遗漏。事后 `pm doctor` exit 0；`pm status`
报"✓ 索引与磁盘一致"（`updateCatalog` 已重写目录前缀，无需重扫），exit 1 仅因
暂存区 5 事件待 `clean staging`（需插备份盘）与 vault 差异 16（15 NEW 待 P4 GUI
分类、1 REN=BLOCKED）。这是 pm 对真实库的**第一次 names 写入**；`pm undo` 可
整体回滚。
