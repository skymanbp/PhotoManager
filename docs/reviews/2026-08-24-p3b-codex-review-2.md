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

---

# 第十八轮（P4-1 `pm serve` 首评，commit 7464780；gpt-5.6-sol 独立评审）

**verdict：GO**——"未发现 critical/major；监听、鉴权与只读路由足以支撑 GUI
骨架"。网络面：确实仅监听 IPv4 loopback（显式 `SockAddrInet 127.0.0.1` 是唯一
bind，warp `runSettingsSocket` 只在传入 socket 上 accept，不按 `settingsHost`
再开 0.0.0.0——它读了 warp-3.4.9/Run.hs 与 network Name.hs 取证）；token 常量
时间比对（长度短路只泄露公开的 32）；Origin 精确白名单、OPTIONS 只回空 204；
`requestHeaderHost = Nothing` 明确 403。数据面：sha 请求不能构造路径；`listPlans`
的 `listDirectory` 不算新的按名字 open 入口（枚举的名字先过 isValidPlanId 再走
受信取用口）；Status 重构与基线 `5813081:src/Pm/Status.hs` 逐行同义、三态保住。

## 逐条判定与处置（全部在分支 p4-2-gui 闭合，200/200）

| 发现 | codex 判定 | 核实 / 处置 |
|---|---|---|
| minor `hostOk` 前缀判定 | `127.0.0.1:1@evil` 通过；warp 3.4.9 不解析 authority、原值进 `requestHeaderHost`；不构成浏览器 DNS-rebinding 绕过且仍须 token，但违反 Host 契约 | **成立**：精确解析为 `127.0.0.1` 或 `127.0.0.1:<1-5 位数字>`；+5 断言（含 `:1@evil`、`:abc`、`:`、`:123456`、`:65535`）；突变回前缀 → Host 用例 FAIL |
| minor `--port 65536` 折回 | `fromIntegral` 到 `PortNumber` 时静默折回 0，负数折回其它端口 | **成立**：`portOk` 0..65535，越界 exit 2 并报出给的值；`caseServePortRange` |
| minor vault JSON 末尾 LF | CLI `putStrLn` 多一个 LF，"逐字节相同"不成立 | **成立**：API 追加 LF；`caseServeVaultStatusBytes` 用同一 `renderVaultJson` 独立算期望逐字节比对；去掉 LF → FAIL |
| minor 并发缓存刷新 | `/api/vault/status` 会刷新 `.pm/vault-cache`，warp 并发执行两个 GET 争用固定 `.tmp` 可能 500 | **成立**：`ServeEnv.seVaultLock`（MVar）串行化 `computeVault`，`serveApp` 改收 `ServeEnv`；无并发用例（wai-test 里造不出真并发，登记） |
| 残余硬化 thumb | `userRelOk` 只是词法闸；扫描后 `相册/a.jpg` 或父目录被换成库外 symlink/junction，授权请求会读链接目标（属既有 TOCTOU 残余，非新 major） | **采纳**：读取前逐级 `resolveUnder`、只读返回路径；`caseServeThumbLink` 把条目换成指向库外 secret 的文件 symlink → 404、库外字节不外泄；删掉解析 → FAIL |
| 1 网络面 ①②④⑤⑥ | OK | ⑥ warp 锁定默认值：连接超时 30 s、HTTP/1 头 50 KiB、无总 body 上限；只读端点不读 body → 够用；**未来写端点须另加应用级大小与执行超时**（登记） |
| 2 数据面 ②③ | OK | ③ 默认 cached，`fresh=1` 全树 stat 约 2 s、token 受控，不要求服务端节流；GUI 应避免轮询（登记） |
| 3 Status 重构 | OK | 逐行同义；`CacheBad/Absent/Ok` 三态，失信计入 exit 1 |
| 4 测试 | PARTIAL | 五处突变点被钉住；未测项中：恶意 Host 后缀（已补）、thumb 链接越界（已补）、vault/status 精确字节（已补）；仍未测：main+vault plans 合并、并发 vault 刷新；`Network.Wai.Test` 不经 socket/warp HTTP 解析/超时/连接复用，建议 P4-3 前补一条真开端口的 raw HTTP 冒烟（登记） |
| 5 文档 | PARTIAL | Host 契约措辞与"字节相同"两处 → 已改（DESIGN §11、REVIEW-LOG 十八轮更正） |

## 突变验证（本轮新增两条）

| 删掉的屏障 | 结果 |
|---|---|
| thumb 的 `resolveUnder`（改回 `root </> rel` 直接读） | `caseServeThumbLink` **FAIL**（1/4 P4-2 组） |
| vault/status 末尾 LF | `caseServeVaultStatusBytes` **FAIL**（1/4） |
| `hostOk` 退回前缀判定（前一提交） | `caseServeHost` **FAIL**（`127.0.0.1:1@evil`） |

## 残余（十八轮起，新增）

- 真开端口的 raw HTTP 冒烟测试（bind / announce / 畸形 Host / 大响应 / 超时）
  ——目前靠人工 netstat 与 curl 冒烟；`Network.Wai.Test` 覆盖不到 warp 层。
- `/api/plans` main+vault 合并无用例；并发 vault 刷新无用例（进程内互斥已加）。
- 未来写端点：应用级 body 大小与执行超时（warp 默认无总 body 上限）。
- GUI 侧避免轮询 `fresh=1`；如需自动刷新加 single-flight/最小间隔。
- 其余同十七轮清单。

---

# 第十九轮（P4-2/3 + 十八轮闭合，commit 7464780..da07eae；gpt-5.6-sol 独立评审）

**verdict：GO**——"未发现 critical/major；两个新问题均为可恢复的 minor，不阻止
合并并进入 GUI 开窗验收"（252 次探查）。

- GUI 边界：Rust 壳层确实只有 spawn / api_info / kill 三件事——`lib.rs` 无
  `std::fs`、无照片路径、唯一 `Command` 参数就是 `serve --exit-on-stdin-eof`。
  `PM_EXE` 被控制时 GUI 以自身权限运行该程序（无 shell，非参数注入），§14 单机
  同用户模型下不要求限制（能改启动环境的同用户本就能直接执行；正常 `pm ui`
  强制写入自身绝对路径）。`api_info` 只对 `main` 窗口本地页面及同源本地 iframe
  可调（capabilities 无 `remote`；它读了本地 tauri-2.11.5 与 wry-0.55.1 源码取证）；
  CSP `script-src 'self'` 由 Tauri 注入 meta CSP。`CREATE_NO_WINDOW` 不改管道；
  `Child` 持有未取出的 stdin 写端，进程死亡即关闭——与 500 ms 零残留冒烟吻合。
- 页面：所有请求经唯一 `get()`，固定 `http://127.0.0.1:<port>` + Bearer，全部
  GET；服务端字符串只进 `textContent` / `alt` / radio 属性，两处 `innerHTML` 都是
  固定空串，无 XSS sink；无 form / 提交 / POST。
- serve 变更：`race` 在 `bracket … close` 作用域内，取消或异常都会关 socket；
  开关未启用时完全不进入 stdin 路径；`/api/vault/new` 与 `/api/vault/status`
  共用同一把锁；`portOk` 在 bind 之前。
- 文档：DESIGN §11 / README / REVIEW-LOG / 第二卷十八轮章节与代码一致，
  `.gitignore` 覆盖 target 与 gen。

## 逐条判定

| 项 | 判定 |
|---|---|
| 1 十八轮闭合五项 | 全部 FIXED（互斥为进程内；无并发用例不构成阻断，已登记） |
| 2 GUI 边界 | OK |
| 3 页面 | ISSUE（minor：blob URL 不 revoke） |
| 4 `pm ui` | OK（查找顺序、错误提示、env 覆盖 `PM_EXE`、退出码原样映射、`withCfg` 先行合理） |
| 5 serve 变更 | OK |
| 6 文档 | OK |

## 新发现与处置

| 严重级 | 位置 | 内容 | 处置 |
|---|---|---|---|
| minor | gui/ui/app.js | 反复进入分类页为所有原图创建新 blob URL，旧 DOM 清空但 URL 未释放，WebView 内存持续增长 | **已修**：记录每轮 URL，重建网格前逐个 `URL.revokeObjectURL` |
| minor | src/Pm/Serve.hs / Config.hs writeSideCache | **跨进程**：GUI 的 serve 与另一个 `pm vault status`（或第二个 serve）同时刷新 `.pm/vault-cache` 时各有各的 MVar，却共用固定 `<final>.tmp`，`openFreshBinary` 可能抛冲突异常让一次请求或 CLI 刷新失败 | **登记为残余**：需跨进程句柄锁并把 catalog/meta 当同一临界区（只改随机 tmp 不够——两文件必须同代）。不触碰照片、缓存可重建 |

合并前最小修复集：空。

## 残余（十九轮起，新增）

- **跨进程 vault-cache 刷新争用**（上表第二条）。
- 十八轮登记项照旧：真开端口 raw HTTP 冒烟、`/api/plans` 合并与并发刷新用例、
  写端点的 body 上限/执行超时、GUI 勿轮询 `fresh=1`。
- 开窗验收时可用 DevTools 注入远程 `<script>` / 远程 iframe invoke 再确认 CSP 与
  ACL 的运行时拒绝（十九轮建议）。

## 真实写入（用户裁定"全量执行"，2026-08-24）

`pm apply 20260824-030200-0c238a`：6/6 → DONE，1071 ms。盘上核实
`Raw/2023/23-12-Turkey-Raw`、`Raw/2025/{25-06-USA,25-08-PR,25-08-Tennessee,
25-11-Alaska,25-12-Colorado}-Raw` 均已就位；`Raw/2025` 余下 3 个 `RAW-2025-*`
是该计划生成时的 3 项拒绝，不是遗漏。事后 `pm doctor` exit 0；`pm status`
报"✓ 索引与磁盘一致"（`updateCatalog` 已重写目录前缀，无需重扫），exit 1 仅因
暂存区 5 事件待 `clean staging`（需插备份盘）与 vault 差异 16（15 NEW 待 P4 GUI
分类、1 REN=BLOCKED）。这是 pm 对真实库的**第一次 names 写入**；`pm undo` 可
整体回滚。
---

# 第二十轮（2026-08-24，codex `gpt-5.6-sol`，只读静态；范围 aa21b37..5fd42f5 = P4-4 UX 重做 + P4-5 第一个写端点）

**verdict：GO** —— "未发现 critical/major：`--writable` 闸位于请求体、缓存刷新和
vault 写入之前，端点不执行计划、不碰照片；发现均为 minor 或覆盖硬化。"
合并前最小修复集：**空**。

- 写端点｜安全边界成立；重复 name 校验、DRIFT-only 与首次建 root 并发存在非阻断缺口。
- GUI｜POST 与 XSS 边界正确；缩略失败回退及并发重载可能重新带来内存问题。

## 逐条判定

| 项 | 判定 | 要点 |
|---|---|---|
| 1 写端点的闸 | ISSUE（非阻断） | 只读闸先于 body / `vaultReport` / `mkVaultPushPlan` / `savePlan`，只读 POST 零写入；GET 刷新主库 vault-cache 是 §11 明示例外。`readBodyCapped` 逐块读到首次超 64 KiB 即停，不排空剩余体——**它读了本地 warp 3.4.9 源码**：默认最多为 keep-alive 回收 8192 字节，剩余更大则直接关连接（`HTTP1.hs:226-250,290-306`、`Settings.hs:203,213-215`），故不会读完巨大剩余体；body 有 30 s timeout，但每次 ≥2048 字节接收会 tickle，慢传仍能占住 worker 直到越过上限（可硬化为按 `requestBodyLength` 预拒）。**aeson 2.2.5.0 源码**：重复键取首值（`Decoding/Conversion.hs:81-94`），默认无嵌套深度计数——64 KiB 是唯一硬界。`Landscape` 被精确拒；`../x.jpg` 因 NEW 只含平铺 basename 而不在集合里；**同一 name 指派两个类目会双双通过——实际校验缺口**。`ensureVaultRoot` 确会先建 root-id 再过 `requireWritable`：按 §10.2 已有用户批准 + 显式按钮，不需第二次确认，但"只写 plans"措辞不准。API 与 CLI 同为 `requireWritable` → `savePlan`，顺序一致 |
| 2 Vault.hs 抽取 | ISSUE（非阻断） | 对照 `aa21b37:src/Pm/Vault.hs:501-564`，逐项校验、NEW/DRIFT 构造、root-id、计划字段、`gitStepsLines` 调用**逐行等价**，DRIFT 仍以 NEEDS-DECISION 进计划。但 API 空 assignments 一律 400，而 CLI 的空选择仍能出纯 DRIFT 计划；GUI 又在零 NEW 时禁用按钮 → **DRIFT-only 状态走不了 GUI** |
| 3 GUI 侧 | ISSUE（非阻断） | POST 只由「生成推送计划」触发、body 只有 UI 状态里的指派；响应路径/命令/git 步骤只进 `textContent`，无 HTML 注入面。`createImageBitmap`/`toBlob` 失败会**回退挂原图**（"因此 WebView2 重新全分辨率解码"标注为未读 WebView2 源码的推断，但与仓库记录的根因一致）。正常路径每张只建一个 URL 且下一轮 revoke、bitmap 会 `close()`；但**连按数字键 2 会并发起多轮**，旧轮在新轮 revoke 之后继续建 URL。快捷键排除了 `INPUT`（当前页无输入框，行为正确，未来应扩到 `isContentEditable`）；`showTab` 的 `main.focus()` 的可访问性影响标注为未验证假设 |
| 4 Rust 侧 | ISSUE（措辞） | GUI 固定传 `--writable`，普通 `pm serve` 的 optparse `switch` 缺省 False，代码边界正确；但任何手动调用者都能显式传该公开参数，"GUI 是唯一客户端"只能理解为"唯一内置/预期客户端"，不是身份层强制。§14 本就不防同用户恶意进程，不构成安全绕过 |
| 5 测试 | ISSUE（覆盖） | 两条新例确实分别钉住只读闸、JSON/空/类目/NEW 校验、64 KiB、GET 404，以及计划落盘/装回/dst/sha/照片不动，三处所述突变会转红。缺口：`.pm` 不存在只在只读请求后断言；合法例未快照三个类目目录、未断言响应的 path/apply/gitSteps；应补重复 name、NEW+DRIFT/DRIFT-only、首次 root 上并发两个 POST。原 VaultTests 仍通过 `runVaultPush` 命中抽出的三段 |
| 6 文档 | ISSUE（措辞） | §11 / README / REVIEW-LOG 对端点、64 KiB、CLI 共用、终端 apply、"apply 端点仍未开"的当前表述一致；历史章节里的"写端点仍未开"有 P4-1/P4-2 时间语境，不是矛盾。需修：各处"只写 `.pm/plans`"不精确（首次还建 root-id）、风险表与 CLI help 仍写"P4-1 只读"、README 的 P5 行重复 |

## 新发现与处置（6 minor，无 critical/major）

| 位置 | 内容 | 处置（P4-6） |
|---|---|---|
| `src/Pm/Vault.hs` `checkAssignments` | 持 token 的调用者把同一 NEW name 同时指派 landscape/portrait，计划含两个可执行 Copy，apply 后跨类目重复 | **已修**：按 name 分组的 fail-closed 判定（同类目重复两次同样拒），CLI 与 API 共用一处；闸用例 +3 |
| `src/Pm/Serve.hs` push-plan | vault 只有 DRIFT、没有 NEW 时按钮永远禁用，出不了裁决计划 | **已修**：空 assignments 在有 DRIFT 时放行；`/api/vault/new` 一并返回 DRIFT 清单，页面据此启用按钮并改文案 |
| `gui/ui/app.js` `shrink` | 缩放失败挂原图 = 重新触发已记录的 WebView 位图内存问题 | **已修**：失败改挂占位符（不再回退原图），`bitmap.close()` 移进 `finally` |
| `gui/ui/app.js` `loadVault` | 连按数字键 2 并发加载，旧轮在 revoke 之后继续下载原图并建 URL | **已修**：single-flight 代号（每次 await 后校验，作废轮不再建 URL），快捷键忽略 `ev.repeat` 并排除可编辑元素 |
| `src/Pm/Vault.hs` `ensureVaultRoot` | 首次 root 上两个并发 POST 都见 `RootAbsent`，一次 `createRootInfo`（no-replace）必失败 → 500 | **已修**：compute→校验→ensureRoot→落盘一次持锁（与 GET 刷新缓存同一把 `seVaultLock`）；并发用例未补，登记 |
| `src/Pm/Serve.hs` JSON | 重复键按首值；64 KiB 深嵌套值可能吃异常栈/CPU | **登记残余**：loopback + token 模型下不阻断；要把 API 当严格契约时再加重复键拒绝与深度上限 |

## P4-6 收口（同分支，203/203，GHC 警告 0）

- 突变验证（单点粒度）：去掉 `dupErrs <>` → 闸用例 `test/ServeTests.hs:407` 转红
  （期望 400 得 200），DRIFT 与合法用例保持绿；把空指派改回无条件 400 →
  `test/ServeTests.hs:477` 转红（期望 200 得 400），闸用例保持绿。
- 新增用例 `caseServePushPlanDrift`：vault 侧放同名异字节文件 → 空指派得 200、
  计划 1 项 dst `landscape/a.jpg` 且状态 NEEDS-DECISION、两侧字节零改动。
- 闸用例补：同 name 跨类目 / 同 name 同类目 / `Landscape` 大小写 / `../a.jpg` 与
  `sub\a.jpg` 路径型 name → 全 400；全部拒绝后 vault 的 `.pm` **仍不存在**。
- 文档措辞按第 1、4、6 条修正（写域 = vault 的 `.pm`，含首次 root-id；风险表与
  CLI help 不再写"P4-1 只读"；README 重复的 P5 行删掉）。
- 顺带修一条与本轮无关的存量 GHC 警告：`Data.ByteString.hGetLine` 自
  bytestring-0.12 起废弃 → `Data.ByteString.Char8.hGetLine`。**更正**：上一轮
  报"警告 0"时读的是 `tail -45` 截断的日志，该警告一直在。

## 残余（二十轮末）

- JSON 重复键 / 深嵌套（上表第 6 条）。
- 首次建 root 的**并发**用例（修已落地，用例未补）；`readBodyCapped` 的慢速上传
  可按 `requestBodyLength` 预拒。
- 十九轮登记项照旧：跨进程 vault-cache 刷新争用、真开端口 raw HTTP 冒烟、
  Rename/Quarantine 的"返回路径必须被使用"用例、TOCTOU 类（§14 威胁模型）。
- 覆盖硬化建议未做：合法例未快照三个类目目录、未断言响应 path/apply/gitSteps。
---

# 第二十一轮（2026-08-24，codex `gpt-5.6-sol`，只读静态；范围 40d6ee4..262c2f6 = P4-7 第九态 HELD「暂不同步」）

**verdict：NO-GO** —— "HELD 的失效判断可能复用旧 SHA，且名单读改写未持跨进程
root lock，均会让用户决定失真；暂不建议对真实 15 张执行。" 最小修复集三条，
**已全部在本分支闭合**（210 测试，三处突变各自转红）。

- 决定语义｜三种情况对单条记录穷尽，但未校验重名记录，且"字节一变即失效"会被主 catalog 的 SHA 快路绕过。
- 写路径｜I11 闸和主库写域正确，但名单更新不满足 I10，崩溃窗口还可能把名单暂时解释为空。
- GUI｜普通点击转换正确；提交期间仍可改状态/重载，且第一步成功、第二步失败后的重试状态不正确。

## 最小修复集与处置

| # | 评审要求 | 处置（同分支） |
|---|---|---|
| 1 | HELD 创建与复核对目标照片强制实际稳定重 hash，补等长/同 mtime 用例 | **已修**：`computeVault` 对「名单里且仍是 NEW」的文件用**空缓存**调 `shaViaCache`（必走真实重读 + 双 stat），读不稳定按失效处理。新例 `caseHoldStaleEqualLen` 刻意造一条必然 `statHitStable` 的主库 catalog 条目，再等长替换 + `setModificationTime` 还原 mtime；突变回 `srcShas` → 该例转红，其余六例仍绿 |
| 2 | 用跨进程 root lock 包住 holds 的完整读改写事务，补并发丢更新用例 | **已修**：抽出事务壳 `Pm.VaultCmd.withHoldsTxn`，`compute → readHolds → holdRequest → writeHolds` 整段在主库 `.pm/lock`（I10）内；锁被占不排队（CLI exit 2 / API 409）。新例 `caseHoldLock` 在另一线程持锁后调用 `runVaultHold`，断言拒绝且**名单未被覆盖**；突变去锁 → 转红 |
| 3 | orphan `vault-holds.json.tmp` 不得降级为空名单 | **已修**：`readHolds` 在"正文缺失"时再探一次 `.tmp`，存在即 fail-closed 并给恢复指引；同时补语义校验（名字须平铺 basename、sha 须 64 hex、名字唯一）。新例 `caseHoldFileGuards` 覆盖两种形态；突变去 tmp 分支 → 转红 |

## 其余发现与处置

| 严重级 | 位置 | 内容 | 处置 |
|---|---|---|---|
| minor | `src/Pm/Vault.hs` `runVaultPush` | held-only 时无参 `vault push` 仍用旧 `hasDiff` → exit 1；`vmNew` 缓存全量 NEW，顶层 `pm status` 把 HELD 算作待办 | **已修**：统一 `hasDiffR` 并**删除** `hasDiff`（两个同构谓词并存正是用错的温床）；`VaultCacheMeta` 加 `vmHeld`，`pm status` 的 vault 行按 NEW − HELD 报。新例 `caseHoldOnlyExit` 钉住两个退出码 |
| minor | `gui/ui/app.js` | 提交两步之间可改选择/重载；第一步落盘、第二步失败后重试会重复撤销；`loadVault` 失败分支不认代号 | **已修**：提交开始取快照并置 `submitting` 冻结卡片；hold 成功后按响应推进 `heldInitial`；catch 分支加 `gen` 校验 |
| minor | `src/Pm/VaultHold.hs` | 手编同名两条不同 sha → 同名同时进 HELD 与 stale | **已修**：`validateHolds` 拒绝重复 name（并入第 3 条） |
| minor | 文档 | README 的"所有写盘两段式"未声明 hold 例外、`--writable` 写域旧；CLI help 旧；§11 仍写"八态计数"；I8 退出码措辞；REVIEW-LOG"字节一变即失效"过强 | **已修**：五处逐条改准 |

评审确认无误的点（不改）：跨层同名不会误命中（源只扫 `相册`，catalog 键是
`相册/<name>`）；`holdRequest` 确为 CLI 与 API 唯一判定点且一次返回全部错误；
端点闸序（writable → 64 KiB → 锁 → 校验 → 写）与 push-plan 一致；写域确是主库
而非 vault；`HOLD` 哨兵与三个固定类目不冲突；坏 JSON 的硬失败是有意行为（它会
卡住 vault 相关命令但不卡顶层 `pm status`）。

## 残余（二十一轮末）

- API 侧未直接测 64 KiB / 坏 JSON / 空请求 / 路径型 name 的 hold 拒绝（CLI 与
  共用校验器已覆盖同一判定）。
- `applyHoldOps` 的覆盖语义没有独立纯函数用例（经两条入口间接命中）。
- 二十轮登记项照旧：aeson 重复键/深嵌套、跨进程 vault-cache 刷新争用、真开端口
  raw HTTP 冒烟、`readBodyCapped` 慢速上传可按 `requestBodyLength` 预拒。
