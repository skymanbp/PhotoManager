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

| 原谓词（删除行） | 替换为 | 宽度 |
|---|---|---|
| catalog / plan / root-id / manifest / 侧缓存的 `doesFileExist fp` + 按名字读 | `readPmState` / `readSideCache`（缺席 = `isDoesNotExistError`） | 同宽 |
| `tmpEx <- doesFileExist mtmp` | `probePmExists`（文件） | 同宽 |
| `trashEx <- doesFileExist (trashDir …)` + `sha256File` | `probePmSha`（文件 + 同句柄 hash） | 同宽 |
| **`oldEx <- existsAny (root </> old)`**（文件**或**目录） | `probePmExists`（**只有文件**） | **收窄** ← 本轮 major |

8 处替换只有这一处收窄。修法不是"把 `probePmExists` 改成 any"（那会让 tmp
探测放行目录占名），而是让**每个调用点显式声明问哪种存在**：

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
