
======================================================================
## CONFIRMED (12)

### [conf-1] (critical/safety) §6.2「MoveFileEx 不带 REPLACE」在 §4 依赖清单里无法实现；退回 directory 的 rename 后步 7 会静默覆盖窗口内出现的 dst
CLAIM: 整个写协议的防覆盖底座（rename 永不覆盖目标）没有任何已声明依赖能提供；用清单里唯一可用的 API 实现时，§6.1 步 2 与步 7 之间是一个无保护的 TOCTOU 窗口，覆盖后盘面与 journal 都不留痕迹。
SUGGESTION: 依赖清单显式加 Win32；Copy 落地改为「CreateFileW(dst, CREATE_NEW) 抢占坑位 → 写入 → 校验」或 MoveFileEx 不带 REPLACE_EXISTING 且失败即判 conflict（不重试覆盖）；supersede 单独定义为「Quarantine victim → CREATE_NEW 落位」两步事务并放宽 Op 注释，使 §6.2 与 §10.2 不再互斥。
VERDICT real=True:
成立（核心成立，两处措辞夸大已扣减）。反驳失败——批评的关键技术断言我用本机一手源码证实了。

【证实】(1) directory 的 rename 确为替换语义：本机 directory-1.3.8.5 Windows 后端源码 <stack-root>/x86_64-windows/ghc-9.10.3/doc/html/libraries/directory-1.3.8.5-1ef4/src/System.Directory.Internal.Windows.html 中 `renamePathInternal opath npath = ... Win32.moveFileEx opath' (Just npath') Win32.mOVEFILE_REPLACE_EXISTING`；System.Directory.OsPath 源码确认 renamePath 与 renameFile 都路由到它；haddock 措辞 renamePath "If the destination path already exists, it is replaced atomically"、renameFile "it is replaced by the old object"、copyFile 亦 "replaced atomically"（"改用 copyFile" 的捷径同样有洞）。无需 P0 spike。
(2) TOCTOU 窗口真实且比批评估计更长：DESIGN.md:194 是唯一 dst 检查、DESIGN.md:200 才落位；DESIGN.md:221-225 的并发防护只排他其他 pm 实例（.pm/lock）并只复核 src 的 (size,mtime)，对 dst 第三方写入零防护。实测 D:/Photography/相册 94 文件均值 28.4 MB / 最大 79.6 MB，步 4-6 是写+复读 ≈57-160 MB I/O，窗口秒级。
(3) 并发写者可构造：<vault-root>/.claude/skills/photo-inbox/SKILL.md 第四阶段步骤 2 即 `cp _inbox/<file> 摄影作品/<类>/<file>`；且 vault 是 git 仓，git checkout/pull/stash pop 由用户手动执行（I9 明说 pm 不碰 git，故无法互斥）。
(4) 无痕成立：覆盖后 dst sha == expectedSha，DESIGN.md:218 判"完好"补记 Done，vault status 报 OK，I5(DESIGN.md:89) 在提交点被破且不可检出。
(5) 波及面比批评更广：§6.2 同管 pm names 的 Rename(DESIGN.md:247)，用 renamePath 时被占用的 new 路径会静默销毁占用者——那是主库真数据而非 vault 副本。

【扣减】(a)「依赖清单里无法实现」过头：Win32-2.14.1.0 是 GHC 9.10.3 boot 包，本机已装（package.conf.d/Win32-2.14.1.0-26c4.conf），且 directory-1.3.8.5-1ef4.conf 的 depends 首项就是它；Win32 haddock 导出 moveFileEx :: String -> Maybe String -> MoveFileFlag -> IO ()、mOVEFILE_REPLACE_EXISTING、createFile/cREATE_NEW。故属"清单漏列 + 诱导用错 API"，修法一行 build-depends，非架构不可行。(b)「两条要求互斥」过头：Quarantine→落位两步事务与 I2 相容，不构成逻辑矛盾；但缺口真实——DESIGN.md:194 步 2 对"存在且不同"只有 conflict 一个出口无 supersede 分支，DESIGN.md:114 注释"仅显式清理路径可产生"按字面禁止 vault push 产生 Quarantine，导致 DESIGN.md:277-278 的 supersede 在文档中无可执行路径（欠定义，非互斥）。

【最小修复】
1. DESIGN.md:157-160 依赖清单加 Win32（boot 包，零新增下载）。
2. DESIGN.md:200 步 7 写死实现约束 + 禁用清单：禁止 directory 的 renamePath/renameFile/copyFile；落位改 `Win32.moveFileEx tmp (Just dst) 0`（不带 REPLACE_EXISTING），ERROR_ALREADY_EXISTS/ERROR_FILE_EXISTS → 判 conflict、journal ← Failed(op, DstAppearedDuringWrite)、保留 tmp 交 doctor、绝不重试覆盖。
3. DESIGN.md:212-219 崩溃矩阵加一行：「步 7 返回 ALREADY_EXISTS → 窗口内出现第三方 dst → conflict；src 与 victim 均未触碰，tmp 待清理」。
4. DESIGN.md:209-210 把「MoveFileEx 不带 REPLACE」从"平台事实"改写为"pm 的实现约束（平台默认恰恰相反）"，并注明同样约束 pm names 的 Rename。
5. DESIGN.md:114 注释改为「显式清理路径 + vault DRIFT supersede 事务」；DESIGN.md:194 步 2 增 supersede 分支：存在且不同 且该项带逐项确认的 supersede 授权 → Quarantine(victim → .pm/trash/<ts>/) 后再走不带 REPLACE 的落位，两步同一 journal 事务，pm undo 可逆。

（全程只读：Read + 只读 ls/grep/python-stat，未修改任何文件。）

### [conf-2] (critical/safety) 全链路无 fsync/FlushFileBuffers：Done 记录可比它所证明的字节先落盘，§6.3 缺「Intent+Done 但内容错」一行
CLAIM: journal 的「逐条 flush」只是 Haskell handle 缓冲刷进 OS，不是持久化屏障；断电/拔盘后可能出现 Intent+Done 齐全而 dst 是零块的组合，而崩溃矩阵没有这一行，doctor 判定「已完成」并永不复验，随后清暂存就是真丢字节。
SUGGESTION: 加 Win32 依赖：步 6.5 对临时文件 FlushFileBuffers 后再 rename，步 8 写完 Done 后对 journal handle FlushFileBuffers（并记录一条 clean-shutdown 标记）；§6.3 补「Intent+Done 但内容不符」行；doctor 默认对「最近一次 clean-shutdown 标记之后的全部 Done」强制重 hash，而不是靠 --deep 抽查（DESIGN.md:179）。
VERDICT real=True:
成立（critical）。核实：DESIGN.md:88 仅「逐条 flush」，全文 grep `flush|fsync|落盘|持久|屏障` 只此一处；:157-160 依赖清单实测无 Win32/unix，base 只有 hFlush（刷到 OS 非刷到盘）、directory 无同步原语 → 文档架构内确实不存在持久化屏障。:214-219 矩阵无「Intent+Done 但 dst 内容错」行，唯一做 sha 复核的是 :218「Intent 无 Done」行，而 :219 断言「拔盘/断电任意点→上述之一」是被证伪的穷尽性声明。引证文件实测存在（To-Be-Sync'd\Processed\26-04-Providence\_DSC9536.JPG, 29229670 B）。

六条反驳全部失败，三条反向加固：(a) 步 5 复读走 page cache，:199 自陈针对的是另一类威胁；(b)「源未被触碰」只延迟不免除——:237 由 Done 生成「已归档，冗余」，:238 主动建议清暂存，且 backup 路径无暂存兜底；(c) 增量 scan 反而是盲区：§12:317 stat-only 跳过 hash，而 :201 步 7 把 dst mtime 设成 src mtime、size 相同 → 腐坏对所有默认路径不可见；(d) :179 的 --deep 原文是「抽查」，非默认非全覆盖；(e) 重跑 import 的步 2 复核不可靠——Plan 由 Diff 生成（:138-139），Diff 走 catalog+stat-only，已 Done 项多半不产生 op；(f) 非「实现细节」——§6.3 是设计级穷尽矩阵，直接背书 I6→R1，修复须动依赖清单+新 journal 记录类型+新 doctor 默认模式。可构造性成立：NTFS $LogFile 只日志元数据，重放后可出现目录项/allocated size 存在而 valid-data-length 未推进（读回零）；backup 路径更直接——journal 在 D:、dst 在移动盘，跨卷零排序保证。

最小修复（成本实测为零：Win32-2.14.1.0 是本机 GHC 9.10.3 的 boot library，`…/ghc-9.10.3/lib/package.conf.d/Win32-2.14.1.0-26c4.conf`；`flushFileBuffers` 已验证导出自 System.Win32.File，命中 `…/Win32-2.14.1.0-26c4/System/Win32/File.hi`，无新增下载）：
1. §4 依赖清单（:157-160）加 `Win32`。
2. §6.1（:196-201）建立排序屏障「数据落盘 → rename → Done 落盘」：新增步 6.5，rename 前对临时文件 handle 调 flushFileBuffers；步 8 改为 写 Done → hFlush → 对 journal handle flushFileBuffers。
3. §6.3（:214-219）补一行残余态（硬件谎报 FLUSH、劣质 USB 桥、exFAT 移动盘）：「Intent+Done 齐全但 dst sha ≠ expectedSha → 报 CORRUPT，不删任何东西，把 staging/源那份标回『未确认归档』」；并把 :219 的「上述之一」改为以屏障为前提的条件表述。
4. §5 doctor（:179）+ §7（:236-238）：journal 增 CleanShutdown 标记（正常退出时写）；`pm doctor` **默认**（非 --deep）对「最近一次 CleanShutdown 之后的全部 Done」强制重 hash——工作量只有被中断那一场会话的 op，有界且廉价；「已归档，冗余」标签必须由 *已复验* 的 Done 而非仅仅存在的 Done 驱动，从而在 :238 建议清暂存之前闭环。
次要同源问题（建议一并记入 §9）：backup 路径 journal 与 dst 跨卷，无任何排序保证，而该副本正是主库失效时的唯一幸存者；且 §10.1/§12:320 用 catalog 缓存 stat-only 取代 sync_photos.py 的每次全量 sha256（实测 sync_photos.py:111-125 每轮真读文件重算），等于削弱了现有的独立复核。

### [conf-3] (critical/safety) vault DRIFT supersede 压掉的可能是唯一副本，而其「旧版本在 git 历史」前提被 I9 禁止 pm 去验证
CLAIM: I5 唯一的覆盖例外建立在 pm 既不检查、按 I9 也无权检查的前提上；vault 文件在被 supersede 时经常尚未 commit，覆盖即永久丢字节，且该路径明确不经 trash。
SUGGESTION: 把 supersede 定义为「先 Quarantine victim 到 .pm/trash/<planId>/ → 再落新字节」，在 plan 里对每个 DRIFT 项打印 victim 的 trash 落点；若坚持用 git 兜底，则必须给 pm 开一个只读 git 查询例外来验证前提，否则删掉 I5 里的免责句；undo 对 supersede 类 Copy 应还原 victim 而不是仅 quarantine 新副本。
VERDICT real=True:
成立（我尽力反驳未果）。四条反驳路线逐条核实后都倒了：

**反驳1「文档已覆盖，Quarantine 兜得住」→ 失败。** DESIGN.md:114 明写 `Quarantine { victim, reason } -- 仅显式清理路径可产生`；§5:180 说 trash 是「唯一的最终清除入口」，§7:237 的 quarantine 也是显式 `pm trash`。supersede 不在任何一条「显式清理路径」上。更糟：§6.1 步 2（DESIGN.md:194）「存在且不同 → conflict 报告」+ 步 7「同卷原子 rename 临时文件 → dst」，配合 §6.2「Windows MoveFileEx 不带 REPLACE 标志——目标存在即失败」，**文档正文根本没给 supersede 留可执行机制**。所以要么 I5 例外无法实现（§5:176/§10.2:277 的 DRIFT 分支永远 apply 不了），要么实现时必须偷偷开 REPLACE 覆盖——两种都是真缺陷。

**反驳2「旧字节还在别处，不构成丢失」→ 失败。** 我实测 `<vault-root>/摄影作品/_inbox/_done/` 现在是 **0 个文件**，且 `.gitignore` 首条 `_inbox/` 把整个暂存区（含 `_done`）排除在 git 之外——它既不是 git 历史也不是常驻副本。备份盘按 §1.2 「当前未挂载 + 可能落后」。所以 Lightroom 覆写 `相册\X.jpg` 之后，vault 工作区那份确实可能是 pre-edit 字节的唯一副本。

**反驳3「I9 不禁只读 git 查询」→ 失败。** DESIGN.md:93 保证栏原文「Vault 模块无 git 调用」，没有只读例外；§4:143 再钉一次「无 git 调用」。pm 无从验证 I5 免责句的前提。

**反驳4「场景不可构造」→ 失败。** DRIFT 的定义性成因就是这个场景：sync_photos.py:183 打印「DRIFT (同名但内容不同 → **主源已修过图**，决定哪份对)」——现有脚本对此只报告、由人裁决（脚本 docstring:20「不做任何写、改、删」），pm 却把它变成自动覆盖。未提交窗口也是工作流保证的：SKILL.md:34「不自动 git push」，第四阶段 92-117 行落盘步骤里**完全没有 git add/commit**，commit 被推到第五阶段 129-132 让用户事后手做。

**最小修复（4 处，自洽）：**
1. DESIGN.md:277-278 §10.2 DRIFT：把 supersede 定义为两步复合——先 `Quarantine{victim = vault/<cat>/<name>, reason = "drift-supersede <planId>"}` 落到 `.pm/trash/<planId>/vault/<cat>/`，再走 §6.1 Copy 写新字节；plan 逐项打印 victim 的 trash 落点。
2. DESIGN.md:114 Op 注释：`仅显式清理路径可产生` → `仅显式清理路径与 vault DRIFT supersede 可产生`（否则代数注释与修复1 打架）。
3. DESIGN.md:89 I5：删掉「旧版本仍在 git 历史 → 信息不丢失」这句不可验证的免责，改为「victim 先 quarantine → 信息不丢失」。这样 I1/I2 不再依赖 pm 无权检查的外部前提，也不必给 I9 开口子。
4. DESIGN.md:181 undo：Copy 若带 quarantined victim（supersede），反向计划 = **从 trash 还原 victim 回 dst**（并 quarantine 新副本），而不是只 quarantine 新副本；对应地 journal 的 Done 记录需带 victim 的 trash 路径。否则 undo 会把 vault landscape 从实测 49 打到 48（我实测 49/6/24=79，与 §1.3 一致），sync_photos.py 报 MISSING，photos.json 的 Pages URL 变死链。

**给批评本身的两处校正（不影响成立）：** (a) `build_site.py` 不会因少一张而失败——它 `iterdir()` 输入目录，n_in 与 n_out 同步减少，只有 `n_in==0 or n_out!=n_in` 才退出 1（build_site.py:54），所以是**静默少发一张 + photos.json 死链**，不是构建报错；(b) 严重度我判 high 而非 critical：丢的是派生 JPEG rendition，其上游 ARW 仍在 `Raw\`、替代版仍在 `相册\`，字节不可复原但画面可重导出。不过按用户 R1「零数据丢失」与文档自设的 I1/I2 绝对措辞，仍是硬违约，且修复成本近乎为零。

**顺带（同类缺陷，同一修法）：** §9:254-255 备份分支「同名不同 hash → 默认视为主库更新……让用户确认方向」是第二条覆盖路径，同样不在 I5 的「唯一例外」里，也同样没有 quarantine 兜底——改 I5 时应一并把它纳入「先 quarantine victim」的统一规则。

### [conf-4] (critical/haskell-win) §6.2 对 MoveFileEx 的语义断言与 directory 实现完全相反：renameFile/renamePath 在 Windows 上带 MOVEFILE_REPLACE_EXISTING 且非原子
CLAIM: 设计文档把「Windows rename 目标存在即失败、不可能覆盖」当作 I5（不覆盖）与 §6.1 步 7（同卷原子 rename）的机制背书，但 GHC 9.10.3 随附的 directory-1.3.8.5 的公开 haddock 明确写着相反的两件事：目标存在会被静默替换，且在 Windows 上不保证原子。
SUGGESTION: 改用 boot 库 Win32-2.14.1.0 的 `System.Win32.File.moveFileEx :: WindowsString -> Maybe WindowsString -> MoveFileFlag -> IO ()`（Win32.txt:3564；`type MoveFileFlag = DWORD` 见 Win32.txt:3673），flags 传 0 → 目标存在返回 ERROR_ALREADY_EXISTS，这才是 §6.2 想要的语义；同时把 `Win32` 加进 §4 依赖清单。§6.1 步 7 删去「原子」措辞，改为 rename 后对 dst 再 stat+sha 复核一次并据此写 Done。
VERDICT real=True:
成立（核心事实逐字核对无误），但批评的失败场景有一处误读，须缩小范围后修。

【核实为真】本机 GHC 9.10.3 随附 haddock <stack-root>\x86_64-windows\ghc-9.10.3\doc\html\libraries\directory-1.3.8.5-1ef4\directory.txt：OsPath 版 renameFile（doc 块 779-815、签名 :816）与 FilePath 版（:1780-1793、签名 :1817）均写「If the new object already exists, it is replaced by the old object.」+ :790-792/:1791-1793「On Windows, this calls MoveFileEx with MOVEFILE_REPLACE_EXISTING set, which is not guaranteed to be atomic (haskell/directory#109)」+「On other platforms, this operation is atomic」。renamePath（:818-846）同为替换语义。建议的替代 API 确实存在且是 boot 库：Win32-2.14.1.0-26c4/Win32.txt:3564 moveFileEx :: WindowsString -> Maybe WindowsString -> MoveFileFlag -> IO ()、:3673 type MoveFileFlag = DWORD、:3674 mOVEFILE_REPLACE_EXISTING；Win32-2.14.1.0 就在 GHC 9.10.3 的 libraries 目录内。而 DESIGN.md:157-160 依赖清单只有 directory，无 Win32。故 DESIGN.md:209「Windows MoveFileEx 不带 REPLACE 标志——目标存在即失败，不可能覆盖」描述的是 flags=0 的裸 API，与按该清单唯一可用的 rename 实现相反；§6.2 又是全文唯一的 Rename 协议段且无任何 dst 预检，把「不可能覆盖」当作免检理由 → 实现者写出 renamePath old new 会静默销毁 dst 字节，journal 只有 old→new，pm undo 不可还原，I1/I2/I5 同破。

【批评需纠正的过度延伸】(1) 「§3 stem 规范化自动产生撞名 Rename」是误读：DESIGN.md:245-246 明写文件级版本后缀不强制统一、只做清单报告、确需改名由用户勾选；§3:124-125 的 stem 规范化只服务 VersionGroup 聚合，不生成 Rename。撞名族本身属实（实测 D:\Photography\Raw\2023\23-07-Wales-Derbyshire-Scotland-Raw\ 同时存在 DSC09432-已增强-NR.dng 与 DSC09432-已增强-NR-1.dng，全库另有 DSC00030-、_DSC0378- 两族），但要进 Plan 须经 :246 的用户勾选或 §6.4 的 Lightroom 并发窗口——场景可构造，路径与批评所述不同。(2) I5:89 机制列已含「Exec 执行期二次检查」，故并非全无守卫，实为 §6.2 与 I5 自相矛盾（且矛盾方向对安全不利）。(3) 目录级 scheme 撞名不毁数据：renamePath haddock:841-844 明写目标为已存在目录时抛 InappropriateType [EEXIST, ENOTEMPTY]，爆炸半径限于文件级 rename。(4) §6.1 步 7 非原子的严重度低于批评措辞：步 2 已保证 dst 不存在，§6.3:219「源文件在所有路径上未被触碰」仍成立，撕裂最多损失新副本；但 §6.3 确实缺「dst 存在但 sha≠expected」一行。

【最小修复，均在 DESIGN.md 内】
1. §6.2:209 删错误括注，改为：directory 的 renameFile/renamePath 在 Windows 带 MOVEFILE_REPLACE_EXISTING（directory.txt:790-792 / 1791-1793），会静默覆盖 → Exec 禁用；所有 rename 走 System.Win32.File.moveFileEx src (Just dst) 0，flags=0 → 目标存在即 ERROR_ALREADY_EXISTS → 记 Failed/conflict。
2. §6.2 补 Rename 的 dst 执行期二次检查（对齐 I5:89）+ Plan 生成期「同批 Rename 目标唯一性」校验（防 :246 勾选后两条 Rename 撞同一 new）。
3. §4:157-160 依赖清单加 Win32（注明 GHC 9.10.3 自带 boot 库 Win32-2.14.1.0，非新增外部依赖）。
4. §6.1:200 步 7 删「原子」措辞，改为 moveFileEx … 0 成功后对 dst 再 stat+sha 复核一次，通过才写步 8 Done。
5. §6.3 增一行「步 7 撕裂：dst 存在但 sha≠expectedSha」→ doctor 判 Failed 半成品，该 dst 走 quarantine 而非 unlink（其已不带 .pm-tmp. 前缀，超出 :204-205 的唯一 unlink 授权），源文件未动，重跑计划。

### [conf-5] (critical/haskell-win) Windows 控制台/重定向编码：GHC 默认用 CP936，pm 的报告会在打印途中硬崩溃、--json 会输出 GBK 字节
CLAIM: §14 风险表只列了「Unicode 路径」，漏了 Windows 的输出编码。本机 ACP/OEMCP 均为 936，GHC 二进制的 stdout 默认编码即 CP936：任何 GBK 表示不了的字符（sync_photos.py 报告里的 ✅📥📤🔁⚠️、≡、≠、…）会让进程以 exit 1 崩在报告中途；重定向时 CJK 路径按 GBK 落盘，UTF-8 消费方读不了。
SUGGESTION: main 入口第一件事：`hSetEncoding stdout utf8; hSetEncoding stderr utf8; hSetNewlineMode stdout noNewlineTranslation`；`--json` 路径用 `hSetBinaryMode stdout True` + `Data.ByteString.Lazy.hPut`（绕开 codec 与 CRLF 翻译）；再经 Win32 调 SetConsoleOutputCP(65001) 让终端能显示。把这条加入 §14 风险表，并在 golden 测试里加一条 CP936 下的报告输出用例。
VERDICT real=True:
成立（我尽力反驳但失败了）。核心事实我用项目自己的目标编译器独立复现，非采信原文。

【复现证据】用 `<stack-root>\x86_64-windows\ghc-9.10.3\bin\ghc.exe`（= `stack path --compiler-exe`）编译探针，`cmd /c chcp 936` 下运行：
- `stdout encoding = Just CP936`
- 打完 ASCII/CJK/数学符号三行后崩在 `\10004`：`commitBuffer: invalid argument (cannot encode character '\10004')`，exit=1 —— 报告确实打了一半才死
- 重定向到文件同样 exit=1；out.txt 里「湖南」= `ba fe c4 cf`（与批评者报的 186 254 196 207 逐字节一致），`bytes.decode('utf-8')` → UnicodeDecodeError
- 注册表 ACP=936 / OEMCP=936（`HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage`）

【文档定位核对】DESIGN.md:358 §14 只有「Windows 长路径 (>260) / Unicode 路径」，对策是 os-string/WCHAR API + 路径长度预检 + CJK 入 golden —— 全是文件系统路径**处理**，不含**输出编码**；os-string 只保证 WCHAR 文件名正确进内存，打印它仍走 Handle 编码器。全文 grep `encoding|编码|utf|GBK|codepage|console` 只命中 DESIGN.md:144「Report.hs 彩色终端 + --json 双输出」一行。对照 sync_photos.py:42-48 已显式 `reconfigure(encoding="utf-8")` 并注释踩坑原因，pm 未继承。

【我对批评的两处修正（不改变结论）】
1. `≠ ≡ …` 在 CP936 里**能**编码（我的探针输出 a1d9/a1d4/a1ad），批评把它们列进「GBK 表示不了」是错的；真正致命的只有 emoji/勾号（✅📥📤🔁⚠️ ✔），而那正是 sync_photos.py:154-159 实际在打的。
2. `--json` 变 GBK 是**实现相关**，非必然：我验证 `BL.putStr (encode x)` 完全绕开 codec，产出真 UTF-8（相册 = e7 9b b8 e5 86 8c）、exit 0、LF 而非 CRLF。但 DESIGN.md:144 没规定走哪条路，golden 测试（tasty-golden 在进程内比 ByteString）也捕不到选错，所以仍是真实设计缺口。

【严重性微调】不违反 R1：§6.1 是「全部字节落盘+校验+journal Done」之后才打汇总报告，崩在报告上时数据已安全且 I4/I6 可对账。真正被击中的是 R3（零差错）与 R2：sync_photos.py:28-31/238 的退出码约定是 0=同步/1=有差异/2=错误，而 §10.1 要 pm 做 drop-in，GHC 未捕获 IOException 也是 exit 1 —— `pm import --apply` 全部写盘成功却报 exit 1，用户无法分辨。

【最小修复】
1. `app/Main.hs` main 第一件事（任何命令分发之前）：`hSetEncoding stdout utf8; hSetEncoding stderr utf8`。
2. `Report.hs` 的 `--json` 路径**明确规定**用 `Data.ByteString.Lazy.hPut stdout (encode x)`（已实测：绕开 codec 与 CRLF 翻译，产出合法 UTF-8），禁止经 String/Text 的 putStrLn。
3. 仅当 stdout 是 console 时经 Win32 调 `SetConsoleOutputCP(65001)`。注意：只做第 1 步能止崩、能修重定向字节，但 CP936 控制台里 CJK 会显示成乱码（不崩），要满足 R2 必须配这一步。
4. §14 风险表增一行「Windows 控制台/重定向输出编码（ACP=936）」，对策即上述三条。
5. §13 加一条测试：`chcp 936` 下跑真实二进制、stdout 重定向到文件，断言 exit code 语义正确且文件可 UTF-8 解码（现有 golden 在进程内比 ByteString，捕不到这条路径）。

### [conf-6] (critical/ux) 「清理暂存区」这条日常动作在命令面上根本不存在——Quarantine 没有用户入口
CLAIM: §7 承诺归档后由用户「显式跑 pm trash」清理 To-Be-Sync'd，但 §5 的 pm trash 只有 list / empty（查看 / 清空隔离区），全命令面没有任何一条命令能把文件放进 .pm/trash/。用户唯一能真正腾出 22.2 GB 的办法是绕过 pm 用 Explorer 手删。
SUGGESTION: 补一条 `pm clean staging [--apply]`（或 `pm trash add <路径>`）：只对「已在 Raw/ 或 成片/ 找到同 sha 副本、且备份盘也已确认有副本」的 staging 文件生成 Quarantine 计划，默认打印计划、--apply 执行、进 .pm/trash/<ts>/ 保持相对路径。同一 §5 表里把 trash 三个子命令写全（add/list/empty）。
VERDICT real=True:
成立（反驳失败）。核实：DESIGN.md:180 全表仅 `pm trash list / empty`；全文 grep `trash|Quarantine` 只命中 86/114/179/180/181/237/346，唯一产生 Quarantine 的命令是 DESIGN.md:181 的 `pm undo`（quarantine 的是 copy 的**目的地副本**，不是 staging 源）；DESIGN.md:236 明写「staging 原文件原地不动」排除了 import 顺手清理；DESIGN.md:179+204-205 的 doctor「清理」严格限定在自建 `.pm-tmp.*`（「不属于任何用户数据」）。DESIGN.md:114 自己写 Quarantine「仅显式清理路径可产生」，而这条「显式清理路径」在 §5 从未定义 —— 文档内部不自洽。场景可构造：独立复核 D:\Photography\To-Be-Sync'd = 241 文件 / 22.19 GB（与 §1.1 一致），import+backup 全绿后 status 提示「已归档，冗余」，但 `pm trash list` 空、`pm trash empty` 无操作，用户只能去 Explorer 手删 → I2（DESIGN.md:86「唯一移出机制 = 显式 quarantine」）在最高频的日常场景上没有任何调用入口，R1 全部机制失效且 catalog 与盘面立即不一致。

最小修复（4 处，均在 DESIGN.md 内）：
1) §5 表新增一行：`pm clean staging [--apply]` | 对 To-Be-Sync'd 中「已在 Raw/ 或 成片/ 存在同 sha256 副本」**且**「备份 root 的 catalog 中存在同 sha256 副本」的文件生成 Quarantine 计划；默认只打印，`--apply` 走 §6 协议移入 `.pm/trash/<ts>/`（保持相对路径 + manifest + journal Intent/Done）| apply 时。不满足三副本的文件在计划里标 HELD 并注明缺哪一副本；备份盘未挂载时不生成任何计划项，只报「无法确认第三副本」（对齐 §9「找不到 → 提示插盘，绝不猜」）；`待修改/` 的 21 个散文件天然不满足条件，与 DESIGN.md:365「import 不碰散文件」一致。
2) DESIGN.md:180 行内补注入口来源：「隔离区的唯一两个入口 = `pm clean staging` 与 `pm undo`；本命令只负责查看与最终清除」（或直接把低层 `pm trash add <path>` 一并列出，二选一）。
3) DESIGN.md:237 把「何时清理由用户显式跑 `pm trash`」改为「…显式跑 `pm clean staging --apply`（该命令内建三副本前置条件，未满足即不入计划）」。
4) §13 P2 验收补一条：import+backup 全绿后 `pm clean staging` 计划恰好覆盖 241 个冗余文件、`--apply` 后 `pm doctor` 对账通过、`.pm/trash/<ts>/` 可按相对路径原样还原。

### [conf-7] (critical/vault) DRIFT supersede 在 Op 代数里无可执行路径，且其「旧版本在 git 历史」的免责前提 pm 无法核实 → 可不可逆丢字节
CLAIM: §10.2 的 DRIFT supersede 既没有对应的 Op 构造子（Copy/Rename/Quarantine 三者都不能覆盖已存在目标），又把 I5 的唯一例外挂在一个 pm 自己禁止查证的事实（I9 不碰 git）上；一旦实现成「就地覆盖」，被覆盖的 vault 字节可能是该版本的唯一副本。
SUGGESTION: 把 supersede 定义为两个已有 Op 的复合并写进 §10.2：`Quarantine(vault 旧文件 → .pm/trash/<ts>/)` 然后 `Copy(相册新版 → vault)`；I5 的例外条款相应改成「旧版本进隔离区」而不是「旧版本在 git 历史」，从而不依赖任何 git 事实、也不需要新增覆盖原语。
VERDICT real=True:
成立（认同 critical：直接顶到 R1/I1，且修复成本约 3 行）。

【核实】批评引用全部属实：DESIGN.md:112-114 Op 只有 Copy/Rename/Quarantine，且 114 行注释写死「仅显式清理路径可产生」；DESIGN.md:194 步2「存在且不同→conflict」；DESIGN.md:209-210 rename 不带 REPLACE；DESIGN.md:89 I5 例外挂在「旧版本仍在 git 历史」；DESIGN.md:93 I9 + DESIGN.md:143「Vault.hs（无 git 调用）」使该前提 pm 结构性不可核实。全文 supersede 仅 3 处（89/176/278），无一处给机制。

【我的反驳全部失败】
(1)「Quarantine+Copy 本可表达，已隐含覆盖」只半成立：§5:181 `pm undo` 已在非清理路径产生 Quarantine（证明复合可行，也证明 114 行注释自相矛盾）；但 I5 把 supersede 写成「不覆盖」的**例外**，字面唯一读法即「允许覆盖」，实现者照抄即引入覆盖原语并同时破 I2/§6.1/§6.2。
(2)「旧字节还在 _inbox/_done/」失败：实测 <vault-root>/摄影作品/_inbox/_done 当前 0 文件。
(3)「git 兜底」失败：现在 79 张全 tracked、树干净，但照片提交集中在 2026-02-13（upload photos batch 1-8），其后半年只有 README/workflow 提交（873e1c1、bb8cc79 = 08-18）；叠加 SKILL.md:34「不自动 git push」与 SKILL.md:94-101（同批字节同时进 相册/ 与 <类>/），未 commit 窗口是月级，场景可构造。
(4)「逐项确认即可」失败：I1（DESIGN.md:85）是无条件不变量，§2:81 明写「不靠自觉」；确认框不告知旧字节是否另有副本。
(5) sync_photos.py:16-17 确认 DRIFT = 同名不同 hash，Lightroom 重导出覆盖 相册/X.jpg 后必报 DRIFT，触发路径成立。

【最小修复：3 处编辑，不新增原语】
1. §10.2（DESIGN.md:278-279）DRIFT 条改为复合操作：「DRIFT：相册是上游真相 → 逐项确认后执行两步：① Quarantine{victim = vault/<类>/<file>, reason = "drift-supersede:<planId>"}，移入 vault root 的 .pm/trash/<ts>/<类>/<file>，manifest 记原 sha256、原路径、planId；② Copy{src = 相册/<file>, dst = vault/<类>/<file>, expectedSha}。journal 顺序：①的 Done 落盘后才写②的 Intent；②失败由 pm doctor 从 trash 原路复位。①执行后 dst 已不存在，②在 §6.1 步 2 走「不存在→继续」——全过程无覆盖写。」
2. I5（DESIGN.md:89）删掉整个例外括号，改为「目的地已存在且内容不同 → conflict，停该项不覆盖，**无例外**（vault DRIFT supersede 不是覆盖：先 Quarantine 移出旧文件再 Copy，见 §10.2）」。I5 从此不依赖任何 git 事实，与 I9 正交。
3. Op 注释（DESIGN.md:114）改为「Quarantine { victim, reason } -- 显式清理 / undo(§5) / vault supersede(§10.2) 三条路径可产生」（现注释已与 §5:181 冲突）。

【两条附带 rider，各 1 行】
- vault 的 .gitignore 实测只有 _inbox/、.ce/、_site/，**不含 .pm/** → pm init 写的 .pm/root-id.json 与新增的 .pm/trash/ 会以 untracked 污染 vault git status；P5（§10.3）须请用户手工加一行 `.pm/`。
- §9:254-255「备份盘同名不同 hash → 视为主库更新」是同一个洞（同样无原语可落地），应复用同一 Quarantine→Copy 复合并在 §9 明写。

### [conf-8] (critical/perf) §6.1 步 5 的「复读校验」读的是 Windows 文件缓存，检测不到它宣称防的那类损坏——付了 2× I/O 却没买到保证
CLAIM: Copy 协议在步 4 写完临时文件后、没有任何 FlushFileBuffers 的情况下立刻在步 5 重读同一个句柄/路径算 sha，返回的是刚写进 system file cache 的同一份内存字节，与介质上的实际内容无关；因此 §14 明确点名要防的「静默写入损坏（USB 劣质线等）」、坏扇区、控制器/固件位翻转全部检测不到，而成本却是实打实的额外一次全量读。
SUGGESTION: 步 5 之前对临时文件句柄显式 FlushFileBuffers（Haskell: Win32 `flushFileBuffers` + `withHandleToHANDLE`），并用一个新句柄以 FILE_FLAG_NO_BUFFERING（或至少 FILE_FLAG_WRITE_THROUGH 写 + 新句柄读）执行验证读；若不愿承担该开销，就把「介质级验证」诚实降级为 `pm doctor --deep` 的离线抽查，并把 §14 那一行的对策改写为实际成立的表述，不要让 I3 背书一个空保证。
VERDICT real=True:
**结论：成立（核心断言真，但批评的证据与成本论证都站不住，需按下面修正版落地）。**

**我试过的四条反驳，三条失败、一条部分成功：**

1. ~~"设计文档没规定怎么读，实现者自然会绕缓存"~~ — 失败。DESIGN.md:198 步 5 只写"复读临时文件算 sha"，DESIGN.md:362 却把它当作"静默写入损坏（USB 劣质线等）"的**唯一**对策，DESIGN.md:87 的 I3 直接把它列为硬不变量。全文 grep `flush|NO_BUFFERING|WRITE_THROUGH|缓存` 只命中 DESIGN.md:88（journal 的 flush）、119、304、320 —— 复制协议里没有任何绕缓存的约定。§4 依赖清单（DESIGN.md:157-160）也没有 `Win32`，crypton 流式 hash 走普通 Handle 就是 buffered 读。

2. ~~"吞吐数字站不住 ⇒ 结论也站不住"~~ — 部分成功，但不足以翻案。批评的实测推理确实是错的：本机 `Get-PhysicalDisk` 显示 D: = 磁盘1 = **HP SSD FX900 Pro 4TB NVMe**（PCIe 4.0，顺序读标称 ~7 GB/s），所以 2,228 MB/s **根本没"远超介质读速"**；"逼近纯内存带宽"也错（DDR4/5 双通道 20-50 GB/s，2.2 GB/s 只有 5-10%）。而它的对照组 596 MB/s 反倒低得可疑（更像 Defender 首次扫描或 LOH 分配开销）。**但我用不依赖吞吐推理的方法复验了，结论仍成立**：快照 `Win32_PerfRawData_PerfDisk_PhysicalDisk` 的累计原始计数器，写 200 MB 后立刻 `ReadAllBytes` 回读 ——
   - 回读阶段**物理读字节 = 69,632**，逻辑读 = 209,715,200（差 3000 倍，本质为 0）
   - 同期写阶段物理写 = 192,950,272（说明 writeback 已经发生了，数据确实落了盘）
   即：**即使脏页已经回写到介质，紧接着的 buffered 回读依然 100% 由 system file cache 供给，一个扇区都没碰介质。** RAM 31.2 GiB（33,485,783,040 B，与批评一致），Raw 层单文件 ~107 MB，常态必然全驻留。

3. ~~"步 5 一无是处所以批评没意义"~~ — 失败（但批评这里略有夸张）。步 5 读的是 page cache 里的**另一份内存拷贝**（不是步 4 哈希用的那个进程缓冲），所以它真能抓到：写逻辑 bug（截断 / 偏移错 / 串到别的文件 / 部分写未重试）、tmp 文件被第三方并发改写、以及缓存副本在回写前的位翻转。它抓不到的恰恰是 §14 点名的那一类（坏扇区、控制器/固件位翻转、劣质线导致的传输损坏）。所以修法是**收窄声明**，不是删掉步 5。

4. ~~"付了 2× I/O"~~ — 这半句是批评自己的错。实测回读物理 I/O ≈ 0，代价是**第二遍 SHA-256（CPU）+ memcpy**，不是第二次磁盘读。429.7 GB 首次归档 / 22 GB 备份下这仍是实打实的 CPU 成本（SHA-256 单核 ~1-2 GB/s），但标题的成本论断需要改写。

**为什么这条仍然是真问题（R1 层面）：** 步 8 会把 `Done(verifiedSha)` 写进 journal，而 §12 的增量 scan 是 stat-only、永不重 hash，所以一个介质层已损坏的目标文件会被**永久记录为"已校验"**。这正好命中两条最需要保证的路径：`pm backup`（DESIGN.md:258 "hash 复读同样强制" —— 备份盘的全部意义就是主库挂了以后的第二份）和 `pm vault push`（vault README.md:8 硬规则要求与 相册/ sha256 严格逐字节相等）。原文件全程未被触碰（DESIGN.md:219），所以**主库不丢数据 —— 丢的是"这份副本是好的"这个保证**。

**最小修复（4 处文档 + 1 条测试）：**

- **DESIGN.md:362**（§14 风险行）：把对策从"强制复读校验（§6.1 步 5）"改为「`pm doctor --deep` 离线重 hash 抽查 + `--verify-media` 显式开关；步 5 不覆盖介质层」。这是必改项 —— 目前是文档里唯一一处明确的错误映射。
- **DESIGN.md:198**（步 5 括注）：`对抗写入路径上的静默损坏` → `复读 OS 缓存副本：捕获写入逻辑错误（截断/错位/串文件）与缓存副本位翻转；**不触及介质，不覆盖坏扇区/固件/USB 传输损坏**`。
- **DESIGN.md:87**（I3）：`sha256 复读校验` → `sha256 复读校验（缓存级）`，并补 I3b：介质级验证为显式 opt-in，默认关闭。
- **DESIGN.md:258 / §12**：若给 `pm backup` + `pm vault push` 加 `--verify-media`，同步把 §12 备份预期从 4-6 min 改成 ~2×（8-12 min，USB3 HDD 上是真的第二次介质读）。
- **P3 故障注入（DESIGN.md:331-333）加一例**：步 4 之后、步 5 之前从 pm 背后改写目标临时文件的**若干字节**并同时使其缓存失效（或直接用 NO_BUFFERING 写入介质），断言协议报 Failed。当前协议会**通过**这个用例 —— 这条测试就是这个缺陷的守门人。

**批评给的修法要改一处：`FlushFileBuffers` 单独不够，"FILE_FLAG_WRITE_THROUGH 写 + 新句柄读"也不够。** 我的实测里 writeback 已经发生（物理写 193 MB）而回读物理读仍是 0 —— Windows 的 file cache 是按 file object 共享的，换新句柄照样命中同一批缓存页。唯一有效的是验证读用 `CreateFile` + `FILE_FLAG_NO_BUFFERING`（Haskell 侧需 `Win32` 包，缓冲区按物理扇区对齐、长度取扇区倍数、尾部残扇区单独处理），或者干脆按批评的第二选项诚实降级为离线抽查。

### [conf-9] (critical/perf) I4 的「逐条 flush」与 catalog 原子替换都没有 fsync 语义，§6.3 崩溃恢复矩阵与 `pm undo` 因此不成立
CLAIM: Haskell 的 hFlush 只把 Handle 缓冲推给 OS，不保证落盘；MoveFileEx 的原子性也只针对目录项，NTFS 日志的是元数据不是文件数据。文档在 §6.3 里把「拔盘/断电任意点」列为已覆盖场景，但整套判定完全依赖 journal 记录在崩溃瞬间已经在介质上——这个前提没有任何机制背书。
SUGGESTION: 把 I4 的措辞从「逐条 flush」改成「逐条 hFlush + FlushFileBuffers」，并在 §6.1 的步 3 与步 8 之后各标注一次真正的 fsync；snapshot 临时文件在 rename 前 fsync 一次；同时在 §12 为此单列开销（备份 4110 文件 ≈ 8220 次 fsync，USB 机械盘按 15–30 ms/次计 ≈ 2–4 分钟，目前完全没进预算）。另外给 doctor 增加「盘上有目标文件但 journal 无任何记录」这一行恢复策略。
VERDICT real=True:
【成立，但批评自己举的场景是最弱的那个实例，severity 应降到 major】

## 反驳掉的部分

1. **它举的「拔 USB 盘」场景不成立。** 拔备份盘不会掉主库 D: 的页缓存——进程还在跑，D: 卷未受影响，lazy writer 几秒内就把 journal 尾部刷下去。批评自己写的是「Intent 记录写在主库侧 journal 的 OS 缓冲里」，那这一半根本丢不了。即使 journal 放在备份盘上，Win10 1809 起可移动盘默认 "Quick removal" 策略（写缓存关闭 ≈ write-through），也大幅削弱该场景。
2. **孤儿临时文件不依赖 journal。** DESIGN.md:204-206 与 I6（:90）明写「临时文件命名约定 + intent/done 对账」，doctor 靠 `.pm-tmp.` 前缀就能识别，丢 Intent 不影响第 2 行。
3. **Copy 路径的危害被夸大。** 「已完成但无记录」的拷贝，下轮 §6.1 步 2 见 dst 同 sha → skip（幂等自愈）；undo 漏掉它只是备份盘多一份正确副本，而 §9（:255）本就把备份盘 EXTRA 定为只读报告永不动。不违反 R1。
4. **性能数字站不住。** 8220×15-30ms≈2-4min 算术对，但假设了（a）journal 在 USB 机械盘、（b）每文件 2 次 fsync。两者都不是必需——见下面的修复，屏障只需 1 次/文件且在主库卷上。

## 反驳失败、确实成立的部分

- **文档全文零覆盖。** grep 整篇：`flush` 仅出现 1 次（:88），`fsync`/`FlushFileBuffers`/写通/write-through 出现 0 次。更硬的证据：§4 依赖清单（:157-160）里既无 `Win32` 也无 `unix`——**当前依赖闭包在物理上无法表达 fsync**，`base` 的 System.IO 只有 hFlush。而 §3（:119）却把 journal 定义为「耐久层」，§14（:361）「catalog 损坏 → journal 重建」还进一步加码依赖它。核实过 `sync_photos.py` 是纯只读无状态（json.dump 到 stdout，:218），系统里没有第二份记录兜底。
- **§6.3 第 4 行「断电任意点 → 上述之一」是假的。** 断电不需要拔盘故事：页缓存全丢，NTFS 只对元数据（rename）做 write-ahead log，对 NDJSON 追加这种用户数据不做。「dst 完好 + journal 无 Intent 无 Done」是可构造状态，且不匹配前 3 行任何一行。
- **真正的伤害在 Rename，批评自己没找到。** I1（:85）声明文件名信息的背书机制就是「重命名旧名进日志」。rename 元数据落盘而 journal 追加丢失时，旧名无任何记录且不可逆推（规范化是朝 canonical 单向收敛，从新名分不出原来是 Scheme A/B/Bare）。`pm names --apply` 要批量改 38 个事件夹（§1.1 :28-32）。这是 I1 用自己的定义（「丢失字节或信息（含文件名）」）判自己失败。
- **文档自带的验证抓不到它。** §13 P3（:331-333）注入方式是「§6.1 每个步骤间强制中断（free-monad/handle 风格）」= 进程内中止；OS 缓冲在进程死亡后依然存活，这种注入永远产生不了掉电模型。即「断电」行被断言且不可测。

## 最小修复（6 处）

1. **:88 I4**：「逐条 flush」→「逐条 hFlush + FlushFileBuffers」。已本机核实可用：`System.Win32.File.flushFileBuffers` + `System.Win32.Types.withHandleToHANDLE` 存在于 Win32-2.14.1.0（随 GHC 9.10.3 自带的 boot 库，路径 `…/ghc-9.10.3/lib/x86_64-windows-ghc-9.10.3/Win32-2.14.1.0-26c4`）。同时把 `Win32` 加进 :157-160 依赖清单。
2. **§6.1**：只在承重处加一次屏障——步 3 之后、步 7 之前：「Intent 必须先于其效果落盘」。步 8 的 Done **可组提交**（批末或每 N 条一次），因为 §6.3 第 3 行已能由 dst 内容重建缺失的 Done。即 1 次 fsync/文件，不是 2 次。
3. **§6.2 Rename**：该屏障对 rename 是**强制且不可组提交**的——旧名只存在于 journal，rename 一落盘即不可逆推。
4. **§6.3 增第 5 行**：「dst 存在且 sha == expectedSha / journal 无任何记录」→ 按内容归属为已完成拷贝并补记 Done（backup 场景退化为 §9 的 EXTRA 只读报告）；rename 侧报「无法归属的规范名目录，需人工裁决」。
5. **§13 P3**：故障注入分两类——「进程中断」（现有 free-monad 注入）+「掉电」（新增「丢弃 journal 未 fsync 尾部」的注入模型），否则第 4/5 行永远测不到。
6. **§12 加一行**：journal fsync 开销按 1 次/文件、主库卷计（远小于批评说的 2-4 min）；snapshot 临时文件 rename 前 fsync 一次（3 次/轮，可忽略）。snapshot 本身是可重建缓存（:119），无需更多。

【顺带：环境说明备份盘「可能 exFAT」。exFAT 无任何日志（连元数据都不 journal），§6.1 步 7「同卷原子 rename」的原子性前提在 exFAT 上不成立——这条批评只擦边提了一句「MoveFileEx 原子性只针对目录项」，是独立的一条，建议 §6.1 补一句对备份卷文件系统的前提声明。】

### [conf-10] (major/safety) 三个 Op 里只有 Copy 有写协议与恢复行，Rename/Quarantine 崩溃后 doctor 与 undo 只能靠猜
CLAIM: §6.3 矩阵完全是 Copy 形状（判据是 tmp 文件与 dst sha），而 Rename 构造子不带任何内容标识、Quarantine 连协议都没有；「Intent 无 Done」时无法区分「没执行」和「执行了但 Done 丢了」，undo 会据此反向搬动用户自己的东西。
SUGGESTION: Rename 补内容标识（文件用 expectedSha，目录用 Windows FILE_ID_128 或子项名+size 指纹）写进 Intent；Quarantine 定义为「先写 manifest 条目 → MoveFileEx → 写 Done」，doctor 增加 trash 目录 ↔ manifest 双向对账；§6.3 扩成每个 Op 一组行的三段矩阵；undo 执行前逐项校验现盘内容 == journal 里的 verifiedSha/指纹，不符即拒绝并报告，而不是无条件反向操作。
VERDICT real=True:
成立（但需削掉批评自身的两处夸张）。

反驳失败的核心：§6.3 的四行判据在字面上就锚死在 §6.1 的步骤编号上（DESIGN.md:216-218 的「步 3 前 / 步 4-6 中 / 步 7 后、8 前」），无法泛化到别的 Op；而 I6（DESIGN.md:90）用「临时文件命名约定 + intent/done 对账 §6.3」这条 Copy-only 机制去背书「任意中断都能安全恢复」这条全称不变量。更硬的证据在验收侧：P3 故障注入明写「在 §6.1 每个步骤间强制中断……之后 doctor 判定与 §6.3 矩阵一致」（DESIGN.md:331-333），P1 关口是「故障注入全绿」（DESIGN.md:346）——Rename / Quarantine 的崩溃路径既没被规定、也不在验收面内。§6.2 全文只有两句（DESIGN.md:209-210），Quarantine 在整个 §6 里零出现（grep 全文只命中 86/114/180/181/237/346 六行）。

场景可构造性已实测核对：D:\Photography\Raw\2025\ 下确有 7 个 RAW-2025-* 与 8 个其他目录并存（RAW-2025-Summer-Providence 紧邻 25-03-Providence-Raw / 25-04-Providence-Raw），且 成片\ 只有 25-11-Providence、没有夏季 Providence，§8 的「季节可由成片月份还原」在这一项上还原不出来 → pm names --apply 在此处确有真实工作要做。Quarantine 孤儿也可构造：正因为 MoveFile 是原子的、manifest 落盘是另一步，「已移入 trash 但未登记」恰好是稳定可达态。P5 侧不是假想——/photo-inbox SKILL.md:116 的收尾就是 mv _inbox/<file> → _inbox/_done/<file>，且 SKILL.md:33 把「不删原图直到确认归档成功」写成硬规则。

批评的两处夸张，需在采纳时改写：
1. 「Quarantine 连协议都没有」过头。I4（DESIGN.md:88）已强制所有 mutation 先 Intent 后 Done，Journal 类型（DESIGN.md:115）对 op 泛化，所以 Intent(Quarantine) 是有的。真正缺的是 manifest 写入次序、trash 目录↔manifest↔journal 三方对账、以及 pm trash empty 的删除范围。
2. 「Rename 崩溃后 doctor 只能靠猜」过头。§6.2 已钉死 MoveFileEx 不带 REPLACE（DESIGN.md:209），I5（DESIGN.md:89）要求 Plan 期 + Exec 期两次查目的地。若 Rename 沿用 §6.1 的次序（查 dst → Intent → move → Done），则 Intent 存在即蕴含 new 当时不存在，加上 NTFS 同卷 rename 崩溃原子性，{old 无 / new 有} 是可判的，不需要 sha。内容标识真正必须的地方是 undo（事后任意时刻，new 可能已被用户改动或重建），不是 doctor。

最小修复（三条，均为文档级，不扩架构）：
1. §6.2 补四行次序 + §6.3 加 Rename 三行：{old 在 / new 无} → 未执行，重跑；{old 无 / new 在} → 已执行，复核后补记 Done；{两者都在} → 未执行且目标被占，报 conflict 不动。同时给 Rename 构造子（DESIGN.md:113）加一个仅供 undo 校验用的轻量标识：文件用 expectedSha，目录用「直接子项名+size 指纹」（FILE_ID_128 可选，避免绑死 NTFS，因为备份盘可能是 exFAT）。
2. Quarantine 定为写前日志式三步：先写 manifest 条目 → MoveFile → 写 Done；§6.3 加对应两行。并规定 pm trash list 显示 manifest ∪ journal ∪ 实际目录内容的并集（孤儿标 UNREGISTERED），pm trash empty 只 unlink 用户在二次确认清单里逐项看到的条目，禁止整删 <ts>/ 目录树——这是全项目唯一真正 unlink 用户数据的入口（DESIGN.md:180），目前只有一行规格。
3. pm undo（DESIGN.md:181）补两条前置条件：只对有 Done 记录的 op 生成反向计划（Intent-无-Done 归 doctor 管，不归 undo）；执行前逐项校验现盘内容 == journal 里的 verifiedSha / 目录指纹，不符即拒绝并报告，不做无条件反向搬动。
另需同步扩 P3（DESIGN.md:331-333）：故障注入覆盖三个 Op 的全部协议步骤，否则 P1 验收仍然放行这个缺口。

### [conf-11] (major/safety) vault root 的 .pm/（journal + catalog + trash）落在 git 工作区内，且实测 .gitignore 不覆盖它
CLAIM: 隔离区是被移出文件的唯一副本，却被放进一个用户被明确指示要跑 git add/commit/push 的工作树；一条常规 `git clean -fdx` 就能销毁 journal 与 trash，一次 `git add -A` 就能把撤下的照片推进私有远端历史。
SUGGESTION: pm init 检测到 root 内有 .git 时，把该 root 的 .pm/ 放到仓外（如 %LOCALAPPDATA%\pm\roots\<uuid>\，用 root-id.json 做映射），trash 一律与工作树解耦；若坚持仓内，必须在写 marker 的同时向该仓 .gitignore 追加 `.pm/` 并按档案 vault 的 confirm-before-act 规则先征得用户同意；§10.2 结束提示里把 `git add -A` 换成显式的 `git add landscape portrait urban`。
VERDICT real=True:
成立，但需降级并改写论据（major → minor/moderate：是仓库卫生与脏树问题，不是 R1 数据丢失）。

【核实为真的部分】vault 实测就是独立 git 仓（git rev-parse --show-toplevel = <vault-root>/摄影作品，origin = skymanbp/photography-private），其 .gitignore 只有 _inbox/、.ce/、_site/，git status --porcelain --ignored 只回 !! .ce/ 与 !! _inbox/，确无 .pm/。DESIGN.md:104（<root>/.pm/root-id.json）、:170、:171（scan 写 仅 .pm/）、:105（role=Vault 也是 root）决定 .pm/ 必落在该工作树内，而 DESIGN.md 全文 grep "gitignore" 零命中 → 文档确实零覆盖。

【必须驳回的夸大】(1) 序列 A 的「trash 是唯一副本」不成立：MISSING 按 DESIGN.md:279-280 只报告不动手（与 sync_photos.py:15,103-105 语义一致），DRIFT supersede 的保全依据是 I5(DESIGN.md:89) 的 git 历史，I7 又保证 vault ⊆ 相册，故 quarantine 后再 git clean -fdx 字节仍在 HEAD 与 D:/Photography/相册/；批评自承该前提来自「问题 3 的修复方案」= 不存在的文档状态。catalog 另有 DESIGN.md:119 明说可重扫重建。(2) git clean -fdx 是「日常动作」论据弱：build_site.py:30-31 自己 rmtree _site，无需 clean。(3) 序列 B 不是外泄：仓是 private，README 与 deploy-pages.yml 证明 Pages 只发 _site/，CI 的 build_site.py 只遍历三个分类目录 → committed .pm/ 既不公开也不破坏部署，实际代价是私仓历史膨胀 + 卫生。

【真正成立、且批评没说出来的那条】pm scan / pm vault status 的 catalog 刷新使该仓长期脏树，而 §10.2(DESIGN.md:281) 收尾正是让用户 add/commit/push（沿用 SKILL.md:130 既有习惯）→ 默认路径上 .pm/ 就会被提交。同仓已有同构先例：.ce/（实测 index.db + observe.ndjson）被 .gitignore 第 6-8 行以「Agent 工具状态目录……既有惯例：不入库」忽略。设计违反目标仓自己写下的约定。

【最小修复】不必采纳批评的「.pm/ 搬出仓外 + LOCALAPPDATA 映射」（改动大且与 root-id.json 就地识别的设计冲突）。三处即可：
1. §5 pm init / pm scan：建立 root 前检测该目录或其祖先是否含 .git；含则先打印待追加行 `.pm/`（比照 .ce/ 写法）并按档案 vault 的 confirm-before-act 征得用户同意后追加到该仓 .gitignore；未覆盖前拒绝在该 root 写 .pm/。
2. §2 增一条不变量 I11：「pm 不在任何 .gitignore 未覆盖 .pm/ 的 git 工作树内建立 root」，并把该检查列入 pm doctor 每次体检项（对应 §5 doctor 行）。
3. §10.2 DESIGN.md:281 的 git 提示原文写死显式路径 `git add landscape portrait urban`，明确禁止 `git add -A` / `git add .`；并补一句：role=Vault 的 supersede/quarantine 以 git HEAD 为兜底（呼应 I5），故要求目标文件已 committed 才允许该项进 Plan。

### [conf-12] (major/haskell-win) §4 依赖清单缺 file-io，OsPath 在 base-4.20/directory-1.3.8.5 下拿不到可写 Handle；JuicyPixels/Win32/process/random 亦被文档正文要求却未列入
CLAIM: §4 声称依赖清单「全部 Windows 成熟」，但清单既缺 OsPath 体系的关键一环（从 OsPath 打开文件 Handle 的包），又漏了文档自己在 §11/§9/§3 明确要求的四个包。按现清单 Hash.hs 和 Exec.hs 写不出来。
SUGGESTION: §4 清单补 `file-io`(System.File.OsPath 提供 openFile/withFile 的 OsPath 版)、`JuicyPixels`、`Win32`、`process`、`random`、`uuid`；或者更省事：放弃 OsPath 改用 FilePath —— Windows 上 base/directory 的 FilePath API 本就走 WCHAR 接口，OsPath 在此平台的实际收益主要是性能而非正确性，而生态里 temporary/tasty-golden/warp 等都还是 FilePath。二选一，但必须在 P0 之前定，不能留到实现时发现。
VERDICT real=True:
成立（但严重度应从 major 降到 moderate，且批评的两个子项应删除）。

我逐条复核了工具链，没有一条能反驳掉核心断言：

【已核实为真】
1. DESIGN.md:157-160 清单原文确无 file-io / JuicyPixels / Win32 / process。
2. base-4.20.2.0 haddock (doc/html/libraries/base-4.20.2.0-39f9/base.txt) 全文 grep "OsPath" **零命中**；开文件只有 FilePath 版（base.txt:37960 `withBinaryFile :: FilePath -> IOMode -> (Handle -> IO r) -> IO r`，另见 :55091）。
3. directory-1.3.8.5：公开模块 `System.Directory.OsPath` 覆盖 directory.txt:324-1324，该区间内 **没有任何返回 Handle 的函数**。全包唯一的 OsPath→Handle 是 `openFileForRead :: OsPath -> IO Handle`（directory.txt:212），只读，且位于 `module System.Directory.Internal`（directory.txt:17，自述 "Internal modules are always subject to change from version to version"）。
4. 因此在 §3 的 `Root.path :: OsPath`（:106）+ `Entry.relPath`（:107）前提下，§4:137 的 `Pm/Hash.hs`「crypton SHA-256 流式」与 §6.1 步 4-5（:196-199 流式读 src / 写临时文件 / 复读临时文件）在现清单下**没有一条非 internal 的可写 Handle 通路**。这在 §13 的 P0（:345，含 Hash）当场就要撞上。
5. `file-io-0.2.0`（Hackage，2026-01-30 上传）确实提供 `System.File.OsPath` 的 `openBinaryFile :: OsPath -> IOMode -> IO Handle`、`withBinaryFile`、`openBinaryTempFile :: OsPath -> OsString -> IO (OsPath, Handle)`。
6. JuicyPixels（DESIGN.md:304 明确点名）是纯 Hackage 包、非 boot，确实漏列，且按批评所说会拖到 P4 才暴露。

【批评的过度断言，应剔除】
- 「按现清单写不出来」不成立：`filepath` 已在清单里（:157），`System.OsPath.decodeFS` 在 Windows 上是 "permissive UTF-16 encoding, where coding errors generate Chars in the surrogate range"（filepath.txt:5363-5376），与 base 自己的文件系统编码同一套，**往返忠实、不引入编解码失败分支**。所以是「能写但难看、且丢掉 file-io 的 long-paths 支持」，不是「写不出来」。
- `random` / `uuid` 应从建议里删掉：`temporary` 已在清单（:160），file-io/base 的 `openBinaryTempFile` 直接产出 `.pm-tmp.<name>.<rand>`（:196）；session token（:308）可用已列的 crypton 取熵；「随机空闲端口」（:300）warp 绑 port 0 即可。
- `Win32`/`process` 是已装的 boot 包（ghc-pkg list --global 实测有 Win32-2.14.1.0 / process-1.6.26.1），漏列不威胁 §14:363「依赖全是 Hackage 主流包、锁定 LTS」的风险论证，只是 build-depends 要补一行。

【批评没抓到、但更值钱的连带缺陷】
DESIGN.md:209 断言「Windows MoveFileEx 不带 REPLACE 标志——目标存在即失败，不可能覆盖」。directory-1.3.8.5 对 `renameFile`（directory.txt:816）/`renamePath`（:846）的文档写的是反面：「On Windows, this calls MoveFileEx with MOVEFILE_REPLACE_EXISTING set, which is not guaranteed to be atomic (haskell/directory#109)」。也就是说 §6.1 步 7 的「同卷原子 rename」与 §6.2 的不可覆盖保证，`directory` **都不提供**——而 I5（:89，目的地存在且不同即 conflict 不覆盖）正是靠这条。必须直接调 Win32 的 `moveFileEx :: WindowsString -> Maybe WindowsString -> MoveFileFlag -> IO ()`（Win32.txt:3564，WindowsString 即 Windows 上的 OsPath，无需 decode）并传 flag 0。

【最小修复（三处，均为文档改动，P0 之前定死）】
1. §4 依赖清单（:157-160）补四个：`file-io`（System.File.OsPath，Hash.hs + Exec.hs §6.1 唯一非 internal 的 OsPath→Handle 来源）、`JuicyPixels`（§11:304）、`Win32`（boot，§6.2 见下）、`process`（boot，§11:300 开浏览器）。**不要**加 random / uuid。
2. §6.2（:209-210）改正事实并指定实现：`directory` 的 renameFile/renamePath 在 Windows 上带 MOVEFILE_REPLACE_EXISTING 且文档声明非原子；Exec 的落位 rename 改为直接 `Win32.moveFileEx tmp (Just dst) 0`（不带 REPLACE 标志），这才是 I5「目标存在即失败」的真实机制来源。
3. §13 P0 验收（:345）加一条前置冒烟：`file-io` 在 GHC 9.10.3 下能编译（上游 tested-with 只到 ghc==9.8.1，base 界 >=4.13 && <5 理论上放行，但未经上游测试）。若编不过，则**在 P0 就**改判为「Root.path 用 FilePath」全局方案，并在 §14:358 的长路径风险行里注明放弃 file-io 的 long-paths flag、改由已有的「≥240 字符预检」单独兜底——不要留到实现中途临时换包，那会打乱 §13 分阶段验收。

======================================================================
## REFUTED (2)

### [refu-1] (critical/perf) 增量 scan 的 (size,mtime) 前提在 exFAT/FAT 备份盘上系统性失效：每次 backup 都退化成全量重 hash，且存在真实漏检窗口
CLAIM: §6.1 步 7 把源文件 mtime 复制到目标；NTFS 存 100 ns UTC，exFAT/FAT 存的是本地墙钟且精度粗得多（exFAT 为 DOS 2 s + 10 ms 增量字段；FAT32 为 2 s 且完全无时区字段）。于是（a）刚刚校验通过的备份副本，其 mtime 与主库源文件必然不相等，也与 pm 记录的 mtimeNs 不相等；（b）DST/时区切换会让整盘 mtime 集体平移 1 小时。两者都让备份 root 的「(size,mtime) 不变即跳过 hash」永远命中不了。反方向更危险：2 s（或 10 ms）粒度 + 同尺寸的原地改写，落在同一粒度窗口内时增量 scan 会直接跳过 hash，catalog 保留陈旧 sha，`pm backup` 认为已同步。
SUGGESTION: Root 记录探测到的文件系统与时间戳粒度，把 mtime 比较按该粒度做容差比较（并把 NTFS→exFAT 的截断值作为期望写回 catalog，而不是记源端的 100 ns 值）；对 FAT 家族禁用 mtime 快判、改用 size + 上次校验时间 + 周期性 rehash，或至少在 `pm status` 里显式标注「该 root 的增量判据不可信」；在 §14 补一行时间戳语义风险，并在 §12 给「备份 root 全量重 hash」单列一行预算。
VERDICT real=False:
反驳成立 —— 该批评的物理前提（exFAT/FAT 时间戳粒度）真实，但从前提到结论的两级推导都断了，且核心翻车数字被实测证伪。

**1. mtime 在本设计里从不做跨文件系统比较，只做同 root 内的缓存失效键。**
批评的整条链子建立在「备份 root 的 (size,mtime) 判据要拿源端 100 ns 值去比 exFAT 截断值」上。文档说的不是这个：DESIGN.md:256「备份盘的 `.pm/` 有自己的 catalog」，而 catalog 的唯一填充路径是 `pm scan [root]`（DESIGN.md:171）+ `Scan.hs 增量扫描（stat 比对 → 变更集）`（:136），DESIGN.md:119 更明说 snapshot「丢了可由重扫重建」。也就是说备份 root 的 Entry.mtimeNs 来自 stat 备份盘上那个 exFAT 文件本身；下一轮 scan 再 stat 同一文件、同一文件系统，取回**同一个已截断值** → 相等成立是构造性的，不是巧合。跨 root 的比较走 `Diff.hs -- 两个 Catalog → 六态差异`（:138），而六态语义我逐行核过 sync_photos.py:100-138 与其 docstring:12-18 —— **全部由 filename + sha256 定义，mtime 一次都没出现**。DESIGN.md:194（步 2）更是把幂等判据显式写成 sha：「存在且 sha 相同 → skip」。所以时间戳失配在任何路径上都不可能触发重拷。

**2. 「4110 个文件全部 mtime 不同 → 重 hash 459 GiB」实测为假。**
我刚在真实库上量了（PowerShell 统计 LastWriteTimeUtc.Ticks 的亚秒/2 秒余数）：Raw 4110 个文件里只有 **118 个（2.9%）** 有非零亚秒 mtime；成片 68/190、相册 53/94、To-Be-Sync'd 34/241，全库 273/4635 = **5.9%**。其余 94.1% 的 mtime 恰好落在整 2 秒边界且亚秒为 0（相机/SD 卡的 FAT 签名，例如 A7R06426.JPG = 2023-10-11T16:58:16.0000000Z）—— 这些值在 exFAT 甚至 FAT32 上**精确可表示，截断是恒等操作**。所以哪怕真按批评假设的最坏实现（Exec 用源 mtime 播种目标 catalog，文档并没这么写：:200 只设 mtime，:201 只记 `Done(verifiedSha)`，不含 mtime），受影响集合也是 ~2.9% 的 Raw 字节 ≈ 12 GB 一次性，不是 429.7 GB 永久性。

**3. DST/时区那半条只对 FAT32 成立，而 FAT32 不在环境集合里。** exFAT 目录项带 `LastModifiedUtcOffset` 与 `LastModified10msIncrement`，正是为了消掉 FAT 的 DST 集体平移；任务环境写的是「可能 exFAT/NTFS」，且 Windows 原生工具不会把一个要镜像 460 GB 库的卷格成 FAT32。批评建议的「对 FAT 家族禁用 mtime 快判」打的是一个不存在的目标。

**4. 漏检场景不可构造 —— 它在论证中途换了文件系统。** Lightroom 重写 .xmp 发生在**主库**，实测 `Get-Volume` 显示 D: = NTFS 3815.4 GB，粒度是 100 ns 存储 / ~15.6 ms 实际 file-time tick，不是批评借用的 FAT「2 s 窗口」。要漏检就得让两次写落在同一个 ~15 ms tick 内（且 XML 侧车尺寸分毫不变），而记录值来自前一次写 —— 人/Lightroom 触发的两次写不可能相隔 15 ms。备份盘上则根本没有原地改写：pm 的唯一写路径是 建临时文件 → 双 sha 复核（:196-199）→ 同卷原子 rename（:200），I3（:87）强制每字节校验。

**唯一残留（非阻塞，不改变 real=false）**：任何 (size,mtime) 增量扫描器都存在「同尺寸原地改写落在时间戳粒度窗内被跳过」的通用弱点（rsync/git/restic 同病），文档已备好解药 —— DESIGN.md:179 `pm doctor --deep` 全量重 hash。若想再收紧，可选的最小动作只是文档级的一行：在 §6.1 步 7 后补「copy 完成后 **stat dst** 写入目标 root 的 catalog（不写源端 mtimeNs）」，把本已正确的隐含实现钉死。这属于把假设显式化，不是修 bug，够不上 critical。

### [refu-2] (major/safety) (size, mtime) 作为唯一跳过 hash 的判据在移动硬盘与粗粒度时间戳上不成立，备份可静默停止跟进而 status 仍报绿
CLAIM: 增量扫描的跳过条件在 exFAT/FAT 备份盘和库里已实测存在的整秒时间戳面前会误判；一旦漏检，backup 的 diff 直接不生成 Copy，异地唯一副本静默停在旧字节，而 status/非 deep doctor 全绿。
SUGGESTION: init 时对每个 root 用探测文件实测时间戳粒度并写进 root marker，比较时按该粒度归一而不是用固定容差；非 NTFS 的 root 一律禁用 mtime 跳过（或改用 size+全量 hash / NTFS 侧用 USN Change Journal）；把 doctor 的重 hash 从「抽查」改成有覆盖率保证的轮转（每次覆盖 1/N，保证 N 次内全覆盖），并在 status 上显示「最久未验证字节的年龄」。
VERDICT real=False:
反驳成立：批评的证据链在第 1、2 步就断了，headline 危害（不生成 Copy、备份静默停在旧字节、status 报绿）无法构造。

**1. 「库里已存在粗粒度时间戳」是对证据的误读——把「整秒的值」当成了「文件系统的粒度」。**
批评引用的 `D:\Photography\相册\A7R06333.jpg` LastWriteTime=2024-08-05T04:24:20.0000000 我复测属实，但同一个 `Get-Item` 同时给出 CreationTime=2024-10-06T18:12:07.2399410 —— 亚秒非零。全量统计：相册 94 个文件**全部 94 个** CreationTime 亚秒非零（NTFS 细粒度落盘），其中 41 个 LastWriteTime 为整秒，而这 41 个的**秒字段全部为偶数**（随机情况下概率 2^-41）——这是 DOS/FAT 时间戳「秒/2」的指纹。`待修改` 11 个文件同样全部偶数秒、mtime 在 2024、ctime 全部集中在 2025-02-14T21:16:29–33。结论：这些整秒 mtime 是从 FAT/exFAT 介质（相机 SD 卡）**拷贝时被保留下来的值**，不是 D: 的粒度。剩下 53/94 本地写出的文件带细粒度 mtime（如 `DSC00002.jpg lw=2025-05-30T00:52:59.8942621`）。跳过判据关心的不是历史值有多粗，而是**下一次修改后的值是否不同**。

**2. 实测：在 NTFS 上「同尺寸原地改写」每次都换 mtime。**
scratchpad（C: 亦 NTFS）探针：对一个 10 字节文件连续 6 次同尺寸原地覆写，得到 6 个互不相同的 LastWriteTime（…33.4708916 / .4917834 / .5059130 / .5215530 / .5367431 / .5534892，间隔 ~15 ms，100 ns tick 上全部可区分），length 恒为 10。批评第 (2) 步「任何同尺寸原地改写都逃过重 hash」在主库上不成立。批评举的 ACR 侧车例子反而是反证：`DSC09034.xmp`(23901 B) 与 `DSC09034.acr`(72556 B) 共享 mtime 2024-07-08T09:08:52（偶数秒）、ctime 2025-02-14T21:16:32/33 —— 它们是**带时间戳拷进来的**，不是在 D: 上被反复原地重写的。

**3. 第 (2) 步赖以成立的「时间容差」是文档里不存在的东西。**
对 DESIGN.md 全文 grep `容差|粒度|时间戳|轮转|bit rot`：零命中；`mtime` 只出现在 107（Entry 字段）、193、200、224、317 五处。批评先假设作者会为了可用性引入容差，再攻击这个假设——攻击的是自己造的方案。没有容差，第 (3) 步（catalog sha 与盘面脱节）就没有成因。

**4. 第 (1) 步（exFAT 截断 → 恒不相等）依赖一个文档未作出的实现选择，且失败方向是安全的。**
`Entry` 的 `mtimeNs`（DESIGN.md:107）由 `Pm/Scan.hs`「stat 比对」（DESIGN.md:136）产生，即每个 root 的 catalog 记录的是**该 root 上 stat 回来的值**；`pm backup --apply` 之后对备份 root 的下一次 scan 会记下截断后的值并稳定下来。「恒不相等」只在「把源的 mtime 写进备份的 catalog」这一实现下才成立，文档没这么说。更关键的是：即便真这么实现了，后果是**过检**（多 hash），不是漏检——`pm backup` 两侧比对用的是 **sha**（§9 DESIGN.md:255「同名不同 hash」），mtime 只决定「要不要重算 sha」，多算永远不会让 Copy 消失。批评自己也承认这一支的后果是 §12 的「22 GB ≈ 4-6 min」作废，那是性能缺陷、不是 major 安全缺陷，而且它和第 (2) 支是互斥的两条路，不能既拿它证明性能崩、又拿另一条证明静默漏检。

**5. 因此「不生成 Copy → 备份永远停在旧字节 → status 报绿」缺少任何一条已构造出的成因**：要漏 Copy 必须先有一次主库侧未被检出的字节变更，而引用的文件系统事实（D: 是 NTFS，实测确认）与实测的 NTFS 行为都产生不出这样的变更。

---
附带说明（不属于本条批评，但值得另立一条）：批评的第 3 条 suggestion 恰好命中了一个**真实但机制完全不同**的缺口——**写入之后的静态腐坏**（移动硬盘坏道/位腐）根本不碰 size 与 mtime，压根不需要粒度论证就能让 catalog 的 sha 与盘面脱节。DESIGN.md §14（:362）对「静默写入损坏（USB 劣质线等）」的回答是「强制复读校验（§6.1 步 5）」，而那只覆盖**写入的那一瞬**；:179 的「`--deep` 全量重 hash 抽查」措辞自相矛盾（全量 vs 抽查），且用户手动触发、无排期、不进 `pm status`。这条应作为独立 finding 提出（最小修复：doctor 的重 hash 改为有覆盖率保证的轮转 + status 显示「最久未验证字节的年龄」），但它不能用来救活本条批评——本条批评的整条证据链（粗粒度时间戳 → 时间容差 → 同尺寸原地改写）已被上述实测逐环推翻。

======================================================================
## UNVERIFIED (16)

### [unve-1] (major/haskell-win) §6.4 的 .pm/lock 用 O_EXCL：崩溃后残留死锁，而 pm 按自己的 I2 与 §6.1 脚注无权删除它，doctor 又是只读
CLAIM: 以 O_EXCL 创建锁文件的方案在进程异常终止后不会自动释放，而设计的其余部分（I2 无删除原语、§6.1 脚注限定唯一可 unlink 对象、doctor 只读、§6.3 崩溃矩阵无锁行）联合起来使 pm 永远无法自愈这个残留锁 —— 恰好发生在 I6 承诺要处理的断电/拔盘场景里。
SUGGESTION: 把 §6.4 的 O_EXCL 改成「打开 `.pm/lock` 拿到 Handle 后 `hTryLock h ExclusiveLock`」：锁由内核持有，进程死亡时自动释放，锁文件本身留着无害也不需要删除 —— 既满足 I10，又不逼 pm 破坏 I2。§6.3 矩阵不需要加行，但 §6.4 需要写明「锁是内核级、不残留」。

### [unve-2] (major/haskell-win) §10.2「只接受 .jpg/.jpeg」在 Windows 大小写保留文件系统上会静默丢掉 40% 的真实照片，直接违反 I8
CLAIM: 真实库里近半数照片扩展名是大写 .JPG。Haskell 侧 OsString/String 的 Eq 是大小写敏感的，若按字面比对 takeExtension ∈ {".jpg",".jpeg"}，这些文件会在进计划前就被拒绝，使 `pm vault status` 的六态集合与 sync_photos.py 不一致。
SUGGESTION: 扩展名判定统一 case-fold（比较前对 OsString 做 ASCII 小写化），并在 §10.2 写明「大小写不敏感，与 sync_photos.py:54 的集合等价」；golden fixture 里必须包含一个 .JPG 文件，否则测试测不到这条。顺带确认 build_site.py 的实际过滤集合，避免 pm 比部署层更严。

### [unve-3] (major/haskell-win) §9 备份盘发现：Win32 未绑定 GetDriveType/GetVolumeInformation/SetErrorMode，「扫所有可移动卷」会弹「请插入磁盘」对话框阻塞；exFAT 上 §6.1 步 7 的 mtime 也不会往返
CLAIM: §9 的备份 root 发现算法要求枚举可移动卷并读 marker，但 §4 既没列 Win32，Win32-2.14.1.0 本身也只绑了 getLogicalDrives 和 DriveType 常量、没有 GetDriveType 函数，更没有 SetErrorMode —— 盲扫盘符在有空读卡器/光驱的机器上会触发系统硬错误对话框；同时文档全程假定 mtime 语义与 NTFS 一致，未考虑备份盘可能是 exFAT。
SUGGESTION: §4 加 `Win32`，并在 §9 写明发现算法：先 SetErrorMode(SEM_FAILCRITICALERRORS) 抑制对话框（需自行 foreign import，Win32 未绑），再用 getLogicalDrives + 自绑 GetDriveTypeW 只探 DRIVE_REMOVABLE/DRIVE_FIXED；同时在 §14 风险表加一行「备份盘文件系统未知」，并规定跨 root 比对一律以 sha256 为准、mtime 只作同 root 内的增量提示，`pm init` 时用 GetVolumeInformationW 记录备份盘 FS 类型与时间戳粒度进 root-id.json。

### [unve-4] (major/ux) 冲突「由用户逐项裁决」没有裁决的地方；--apply 是否还要交互确认全文未定义
CLAIM: §7/§10.2 三处把决定权推给「用户逐项裁决 / 逐项确认」，但 §5 命令面没有任何交互式裁决入口、没有 --skip-conflicts / --continue / --resolve，也没写明 `--apply` 本身是否再弹一次 y/N。用户在批量中途撞上冲突后不知道下一步敲什么。
SUGGESTION: 把 planId 提到 CLI：`pm import` 落一份 plan 到 .pm/plans/<id>.json 并在末尾打印 `pm apply <id>`（可加 `--only 3,7-9`）；`pm apply` 是唯一写盘动词，二段式收敛成「看→apply <id>」。冲突项在计划里标 `NEEDS-DECISION`，提供 `pm resolve <id> --item N --keep src|dst|both`（both = 新版本改名并存），并明确 conflict 只停该项、批次继续，末尾汇总。

### [unve-5] (major/ux) pm status 默认不扫盘也不报「数字已过期」——「一目了然」的仪表盘会一目了然地骗人
CLAIM: status 被定义为纯读 snapshot，全文没有任何自动扫描、mtime 新鲜度提示或「上次 scan 时间」字段；用户必须先记得跑 pm scan，否则看到的是上一次的世界。
SUGGESTION: status 默认做 stat-only 增量刷新（§12 已给出 <10 s 预算），`--cached` 才走纯快照；报告头一行永远打印「索引时间 2026-08-22 14:03（3 分钟前）· 4351 文件」，超过阈值或检测到 root 顶层 mtime 变化就用醒目色提示 `索引可能过期，运行 pm scan`。同时把 `pm`（零参数）等价于 `pm status`。

### [unve-6] (major/ux) GUI/CLI 分工倒置：唯一必须看图才能做的操作被放在 CLI，GUI 却排到最后一期
CLAIM: `pm vault push` 的 NEW 分类要求逐张判 landscape/portrait/urban，这在 CLI 里只有文件名可看，摄影师无法完成；而能看缩略图的 GUI 直到 P4 才有，且文档同时把这件事说成「CLI 表格 / GUI 勾选」两条等价路径。
SUGGESTION: 在 §5 表里把 `pm vault push` 的 NEW 分支标成「需 GUI 或 --category 显式指定」，CLI 无 GUI 时直接打印 `需要看图分类，运行 pm ui` 而不是列文件名让人猜；或把 P4 的 vault-push 分类页提前到 P3 一起交付。另在 §10.2 明确 pm 不做分类判断，类别只能来自用户勾选或 skill 传入，消掉「CLI 表格」这条实际不可用的等价路径。

### [unve-7] (major/ux) R2 是四条硬需求之一，却全文没有一屏报告样例、没有字段定义、没有退出码
CLAIM: 「一目了然」只以形容词形式出现（总览仪表盘、彩色终端），没有任何一个输出 mock、字段清单或退出码约定；被它取代的 sync_photos.py 反而把报告格式和退出码写得清清楚楚，替换后档案侧现有核对步骤会静默失灵。
SUGGESTION: 在 §5 后加一节「报告规格」：贴 pm status、pm vault status、一份 import 计划的真实终端 mock（含无色/--json 两态），并显式约定退出码 0=无差异·1=有差异待处理·2=错误（与 sync_photos.py 对齐），--json 顶层字段照抄 sync_photos.py:218-229 的键名并注明新增键。

### [unve-8] (major/vault) §6.1 的 .pm-tmp.* 临时文件落在 git 跟踪的分类目录里，会让 vault 部署整体失败并被误提交
CLAIM: Copy 协议要求临时文件与目标同目录，而 vault 的目标目录就是 landscape/portrait/urban 这三个 git 跟踪 + CI 发布的目录；build_site.py 对非 .jpg/.jpeg 文件是硬失败，且 .gitignore 未覆盖 .pm 前缀。
SUGGESTION: §10.2 增一条 vault 专用写规则：临时文件写到 `<vault-root>/.pm/tmp/`（同卷即可保证 rename 原子，不必同目录），落盘只用 rename 进分类目录；并在 P5 清单里加「vault .gitignore 追加 `.pm/`」这一项（改动前照例经用户确认）。

### [unve-9] (major/vault) RENAME「vault 侧改名对齐相册」会静默打断 portfolio 已上线的图片 URL
CLAIM: vault 文件名是 GitHub Pages URL 的一部分，photos.json 用完整 URL 引用；pm 明确不管 photos.json，于是 pm 执行的 vault 改名会让 portfolio 线上图片 404，而 pm 的报告里看不到这个后果。
SUGGESTION: §10.2 把 RENAME 降级为**只报告**（与 MISSING 同级），或在 rename 计划里强制加一步「grep portfolio data/photos.json 中该 src，命中则该项标 BLOCKED，打印需人工同步的 photos.json 行号」；无论哪种，pm 都不主动改动被 photos.json 引用的文件名。

### [unve-10] (major/vault) `pm vault ingest` 把「移 _inbox → _done」并进拷贝命令，破坏 /photo-inbox 现有的「photos.json 成功后才移」顺序保证
CLAIM: §10.3 列举的机械步骤把 _done 移动和两次拷贝打包成一条命令，而 skill 的硬顺序是第 4 步必须在第 3 步（写 photos.json 并通过 json.tool 校验）成功之后；打包后 photos.json 失败回滚时，照片已离开 inbox，重跑 skill 看到空 inbox，该图永远不会进 portfolio。
SUGGESTION: §10.3 明确 `pm vault ingest` 只做「拷 相册 + 拷 vault + 冲突检测」，`移 _done/` 拆成独立子命令（如 `pm vault ingest --finalize`）由 skill 在 photos.json 校验通过后再调；并在 §10.2 给 skill 侧的同名冲突另起名字（如 COLLIDE），说明 pm 只提供「改名」分支，覆盖分支保留给用户手工。

### [unve-11] (major/vault) ingest 只写 相册 + vault 而不写 成片，会让 I7 拓扑不变量对每一张 inbox 照片持续误报
CLAIM: I7 把「相册 ⊆ 成片」列为 pm status/doctor 持续校验的硬拓扑，但 /photo-inbox 的入口是 _inbox 而不是 成片，改造后的 ingest 每归档一张就制造一条永久的 I7 违例。
SUGGESTION: 要么 §10.3 规定 ingest 同时向 成片/<事件> 生成 Copy（需先解决事件归属，代价大），要么把 I7 改写为「相册 ⊆ 成片 ∪ inbox-origin（journal 中有 ingest 记录的集合）」，让 ingest 在 journal 里登记来源，doctor 据此把这些项归为已解释而非违例。

### [unve-12] (major/vault) §10.1 的「--json 字段名对齐」不等于 schema 兼容：值是位置元组 + 截断 hash，且过滤器与退出码未对齐，P3 验收无法通过
CLAIM: 设计只承诺了顶层字段名，而 sync_photos.py 的 JSON 值是异构位置元组、hash 被截断到 16 字符、duplicate 与 ok/drift 重叠不构成划分；此外 pm 的 jpg/jpeg 限制与脚本的 PHOTO_EXTS（含 .png/.PNG，且大小写精确匹配）不一致，退出码契约也没写进设计。
SUGGESTION: §10.1 改为贴出**逐字段的值形状**（沿用位置元组 + `take 16` 的 hash 前缀 + duplicate 与 ok/drift 重叠的说明）并显式声明退出码 0/1/2 语义；同时写明 pm vault status 的文件过滤器等于 sync_photos.py 的 PHOTO_EXTS（含 png、大小写精确），把「只接受 jpg/jpeg」的收紧限定在 push/ingest 的写路径上，并规定 png 在 status 里以 UNPUSHABLE 形式可见而不是被静默过滤。

### [unve-13] (major/perf) 并行 hash 的 worker 数是全局配置、无介质感知；`pm scan <backup>` / `doctor --deep` 会在 USB 机械盘上寻道抖动
CLAIM: §12 把 worker 定为「物理核数」（本机 8），§4 的 Scan.hs 一律走并行 hash。§9 只把「单线程顺序」这条约束加在 copy 上，完全没有约束 scan。但备份 root 的首扫、每次增量校验、以及 `pm doctor --deep` 的抽查都走同一个 Scan.hs——8 个 worker 在一块 USB 机械盘上并发拉 8 段平均 107 MB 的顺序流，磁头在 8 个区间来回，有效吞吐从顺序的 ~100–110 MB/s 掉到 30–50 MB/s 量级。并行在这里是净负优化。
SUGGESTION: 把 worker 数做成 Root 的属性而不是全局配置：`pm init` 时用 IOCTL_STORAGE_QUERY_PROPERTY 的 seek-penalty 标志（或 MSFT_PhysicalDisk.MediaType）探测介质，rotational/removable 默认 worker=1、NVMe/SSD 默认物理核数，写进 `.pm/root-id.json` 与 TOML 的 roots 段；§9 的「单线程」约束改写为覆盖 scan 与 copy 两者。

### [unve-14] (major/perf) §12 的成本模型漏掉了强制复读的乘数，也漏掉了两个最大的真实操作（首次全量备份、pm import）——而 §7 让用户拿这个数字做决策
CLAIM: §12 只有 5 行，其中 backup 那行给的「22 GB 增量 ≈ 4–6 min（USB3 HDD）」隐含 63–76 MB/s 的净吞吐，这已经用满了 USB3 2.5 吋机械盘的顺序写上限，完全没有留出强制复读（+1× 目标端读）和每文件 fsync 的开销。同时表里没有「首次全量备份」行，也没有 `pm import` 行——而这两个恰好是用户真正会等的两个长操作。
SUGGESTION: §12 补两行（首次全量备份、pm import），并在每一行显式写出「读 + 写 + 复读 + fsync」的分项而不是单一总数；同时评估把复读分级——同卷 NVMe 内部拷贝（import、vault push）保留复读几乎免费，跨介质拷贝（backup）的复读改为绕过缓存的真验证并把它计入预算，或提供 `--verify=cached|media|deferred` 三档让用户在首次 459 GiB 备份时选择。

### [unve-15] (major/perf) §12/§2/§13 的规模输入三处互相矛盾、介质假设与实机不符，「增量 < 10 s」这条验收标准只对主库成立、对备份 root 不成立
CLAIM: 同一份文档对「全树多少文件」给了三个不同的数：§2 说 4110、§12 说 4351、§1.1 的分层数相加是 4635（实测 4635）；「首扫多少字节」用的 429.7 GB 其实只是 Raw 一层，全库是 459.24 GiB。首扫那行的介质假设（HDD / SATA SSD）与实机不符——主库所在的 D: 是 NVMe。这些数字是 §13 P0 阶段的验收标准，输入错了验收就是自证。
SUGGESTION: 把 §12 的规模输入统一为实测的 4635 文件 / 459.24 GiB（并在 §2、§13 P0 同步），首扫行按 root 的实际介质分列（主库 NVMe / 备份 USB-HDD），并把「增量 < 10 s」这条验收标准限定为「主库 root、热缓存」，为备份 root 另给一条可达成的标准（如冷态全树 stat < 90 s）。

### [unve-16] (minor/ux) 命令面 15 条（含一条只在 §10.3 出现、从未登记的 pm vault ingest），概念负载超出单人日常
CLAIM: §5 表列 13 行/约 14 个可调用命令，§10.3 又凭空要求实现 `pm vault ingest`，命令表里查不到；同时用户要记住 root/catalog/journal/plan/quarantine/supersede/EXTRA/volatile/六态/Scheme A|B 十来个新名词才能读懂报告。
SUGGESTION: 把 ingest 补进 §5 表并写明它与 push 的分工（ingest = skill 调用的非交互批量入口，push = 人用的交互入口），或直接让 skill 调 `pm vault push --category x --apply` 取消 ingest。再做一次收敛：scan 折进 status（见上一条）、versions 折成 `pm names --versions`、undo 折成 `pm history undo`，把面向人的入口压到 8 条以内；status 报告每个问题行末尾直接打印可复制的下一步命令原文（例如「staging 3 事件待归档 → 运行 pm import」），让用户不必自己做映射。
