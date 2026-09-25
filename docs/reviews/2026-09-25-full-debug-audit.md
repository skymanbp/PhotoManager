# PhotoManager 全量 debug 报告（只读审计，未改任何代码）

分支 `claude/full-debug-o8absa`，基于提交 e6f3ebb（1.2.0）。审计日期 2026-09-25。

## 0. 方法与覆盖

- 容器内没有 Haskell 工具链且项目是 Windows-only（Win32 FFI），因此全部结论来自逐行阅读与调用链追踪，不是运行复现。为验证「代码能否编译」，我在临时目录搭了一个 Linux 类型检查壳（GHC 9.10.3 + Stackage lts-24.46 版本冻结 + 一个只做类型的 Win32 桩包 + windows.h 符号桩）：库、可执行与 27 个测试模块全部编译通过，`-Wall` 零警告；440 个测试里 132 个纯逻辑用例在 Linux 上通过，其余 308 个因 Win32 桩 / mklink / ACL / NUL 设备等 Windows 专属设施而失败，不构成缺陷。
- 第一阶段（信息收集）：14 个文件簇（10 个代码簇各 2 个独立视角：崩溃/逻辑、不变量/契约；4 个测试簇各 1 个视角），加 4 个全库横切视角（写原语、锁与竞态、Windows 路径语义、JSON 契约）。共 28 个阅读者，产出 116 条原始疑点。
- 第二阶段（聚合 + 验证）：语义去重 116 → 73 条；每条由一个对抗式验证者按「读代码 → 构造具体场景逐行追踪 → 查设计文档 / REVIEW-LOG / 已知限制 / 既有测试」三步裁决，默认存疑即证伪。结果 59 条确认、14 条证伪。
- 未覆盖：5 个横切视角（异常处理、编码与时间、CLI 与文档漂移、安全、偏函数扫描）因账号会话额度在运行中耗尽而没有跑；文件簇视角已部分覆盖这些主题，但不是专门扫描。

## 1. 结论概览

| 项目 | 数量 |
|---|---|
| 原始疑点 | 116 |
| 去重后 | 73 |
| 确认 | 59 |
| 其中 critical / high | 0 |
| 其中 medium | 12 |
| 其中 low | 47 |
| 证伪 | 14 |

没有发现 critical（丢数据 / 安全）或 high（主路径崩溃 / 错误结果）级别的缺陷：安全写内核（Intent 屏障、no-replace 落位、锁范围）与 loopback API 的鉴权在本轮审计里没有找到可成立的违规。确认的问题集中在：路径规范化缺口（junction / SUBST / 8.3）、二态探针在少数读路径上的 fail-open 残留、GUI 的「未知塌成无」、doctor 矩阵与文档的漂移、以及若干误导性报文与退出码。

## 2. 已确认 — medium（12）

| # | 位置 | 问题 | 修复难度 |
|---|---|---|---|
| 1 | gui/ui/app.js:521 | AI 地点建议没有代际守卫：请求进行中若重新扫描（可能换了源目录），迟到的响应按分段序号写进新概览的输入框，可能把上一张卡的地点填进另一张卡，进而生成错名的事件夹 | 极小 |
| 2 | gui/ui/app.js:697 | 设置页「掉线等待」留空点保存会提交 driveWait=0，即静默关闭备份盘瞬断保护，横幅却报成功；workers 字段同一构造（空→0→400） | 极小 |
| 3 | src/Pm/Cli.hs:474 | 暂存区新鲜度闸用精确大小写 `To-Be-Sync'd` 过滤 catalog，而盘上探测不区分大小写：暂存目录拼写大小写不同时，import / sort / clean 永远被「先 pm scan」拒绝，scan 也无法修好（Import/Clean/Diff/Status 同一谓词） | 中 |
| 4 | src/Pm/Config.hs:152 | 配置路径只 makeAbsolute、不 canonicalize：%APPDATA% 或 PM_CONFIG 经过 junction / SUBST / 8.3 短名时，withConfigLock 的句柄绑定校验失败并作为未捕获异常抛出——pm init / config set / backup init 崩溃（读仍正常），报文把用户自己的目录说成链接攻击 | 小 |
| 5 | src/Pm/Config.hs:608 | createRootInfo' 用未规范化的 root 字符串做句柄绑定 rename：root 是 junction / SUBST / 8.3 / 正斜杠 vault.path 时，pm init 与首次 vault push 崩溃，且每次尝试都泄漏一个 `.pm/root-id.json.<hex>.tmp`；文档明确 junction root 合法 | 小 |
| 6 | src/Pm/Names.hs:320 | filterDirs 用二态 doesDirectoryExist：ACL 拒绝的年份/事件目录被当「不是目录」静默丢弃，pm names 报告漏项且 exit 0，违反「读不出 = 整批拒绝 exit 2」契约；成片层还可能把二义性 NEEDS-DECISION 变成唯一（可能错月）的改名 | 小 |
| 7 | src/Pm/Plan.hs:391 | planStale 探测可移动盘时进程未设 SEM_FAILCRITICALERRORS：读卡器空槽会弹出系统「请插入磁盘」对话框并阻塞 pm plan list / prune / GET /api/plans | 极小 |
| 8 | src/Pm/Scan.hs:134 | 遍历用 pathIsSymbolicLink 判链接：Windows 上任何 reparse point（OneDrive 占位、Dedup、WOF 压缩、WIM）都被当 symlink 跳过并报错，与项目自己的 P3b-12 裁决（只有 name-surrogate 标签才算重定向，probeName 已实现）矛盾 | 中 |
| 9 | src/Pm/Serve.hs:339 | POST /api/apply（及 recordPost）没有异常边界：执行链抛出的 IOException 走 warp 裸 500（无 JSON、无 CORS），GUI 只看到「Failed to fetch」/「没有执行」，而项可能已落位并记 Done | 小 |
| 10 | src/Pm/Sort.hs:467 | existingEvents 对 Raw\ 下每个子项都 listDirectory：Raw\ 里有普通文件（desktop.ini / Thumbs.db）时整个 `pm sort` 概览 exit 2、/api/sort/survey 与 /api/suggest 409，报文误指被占/介质错误 | 极小 |
| 11 | src/Pm/Versions.hs:146 | rawEventOf 对深度 3 的 `Raw\<年>\<文件>` 把文件名当事件夹：同 stem 的 RAW 找不到，判据③失效，Raw↔成片 同 sha 对被当设计冗余从 vgExactDups 丢掉（pm versions / pm dedupe 都看不到） | 极小 |
| 12 | test/KernelTests.hs:553 | Q-DONE-LOST「--repair 不盲补」断言空转：夹具没有 root-id.json，--repair 在 gate 处即被拒退化为只诊断，applyRepairs 从未执行，断言恒真 | 极小 |

## 3. 已确认 — low（47）

| # | 位置 | 问题 |
|---|---|---|
| 13 | README.md:227 / README.zh.md:173 / docs/DESIGN.md:256 | `pm undo --last [N]` 写法暗示可省参数，实际 `--last` 必须带值（正确形态 `pm undo [--last N]`）；DocDrift 哨兵只查子串抓不到 |
| 14 | app/Main.hs:265 | `pm init --workers` 不校验范围（0 / 负数 / >64 都写入 config），而 `config set` 走 1..64 闸；checkConfig 未覆盖 workers |
| 15 | gui/src-tauri/src/lib.rs:108 | 打包版 pm-ui.exe 在 pm serve 起不来（典型：尚未 pm init）时只 eprintln 后 exit(2)，windows 子系统无 stderr，程序无提示消失 |
| 16 | gui/ui/app.js:88（archive.js:29 同） | index 为 null 时一律显示「主库尚未索引 → pm scan」，把「索引读不出 / 不可信」塌成「未扫描」并丢掉 warnings |
| 17 | gui/ui/app.js:382 | 计划执行返回 code 2 且无逐项结果（执行被整体拒绝）时仍标题「有未完成/待裁决项」并提示 pm undo |
| 18 | gui/ui/archive.js:38 | /api/album/candidates 失败时 renderConvert([]) 断言「没有非 jpg 照片」（未知塌成无），其余卡片保留上次内容 |
| 19 | package.yaml:107 | extra-source-files 声称登记了 DocDriftTests 读的全部非源码文件，实际漏 docs/HISTORY.md、docs/specs、gui/ui/*.js\|css、gui/src-tauri/src、scripts |
| 20 | scripts/backup_verify.py:50 | run() 内 drive-wait 超时直接 sys.exit(3)，丢弃已积累的核验结果且不写 --out |
| 21 | scripts/leakscan.py:56 | `--extra` 作为最后一个参数时 next(it) 抛未捕获 StopIteration（已实跑确认） |
| 22 | scripts/verify_backup_dst.py:24 | 忽略计划项 status：用户 `pm resolve --item N` 跳过的项也被要求在盘上存在，误报 missing / sha 不符 |
| 23 | scripts/verify_backup_dst.py:30 | trash 受害者存在性检查无「盘在」守卫，max-drops STOP 后全部误报缺失 |
| 24 | src/Pm/Album.hs:95 | import --also-album 对 sidecar / meta / RAW 也提示「要进相册 → pm convert」，而 convert 会拒绝这些 |
| 25 | src/Pm/Album.hs:212 | 直接位于成片\ 下（无事件夹）的 jpg 被列为候选，事件名=文件名，给出的 add / ignore 命令会被 parseProcessedRel 拒绝 |
| 26 | src/Pm/Backup.hs:36 | 备份盘发现把 RootCorrupt / RootUntrusted 折成 Nothing：root-id.json 损坏或不可信的已挂载备份盘被报成「未挂载，插上重试」 |
| 27 | src/Pm/Backup.hs:46 | subpath 用 `</>` 拼接：手改成绝对 / 带根路径时每个盘都「匹配」，报假的「多个卷同时匹配 / 整盘克隆」 |
| 28 | src/Pm/BackupCmd.hs:192 | 备份盘发现失败（未注册 / 未挂载 / 冲突）返回 exit 1（=有差异），应为 2（=错误），与 §5.1 与 F031 矛盾 |
| 29 | src/Pm/Cli.hs:151 | execPlanRetry 自愈打印「补记 Done N 条」按 Warn 行计数，doctor --repair 退化为只诊断（锁忙 / 不可写）时仍如此声称；已落位的 rename 随后被当 CONFLICT 重跑 |
| 30 | src/Pm/Commands.hs:302 | 隔离动盘失败或未执行（Q2）时写前 manifest 记录永不核销，pm trash list 把从未隔离的文件标成「已移出」；DESIGN §6.4 Q2「清除该条目」无实现 |
| 31 | src/Pm/Convert.hs:12 | convert --also-album 两项共享派生源：成片项落位后派生件被判 DERIVED-STALE，任何 doctor --repair（含自动自愈）会删掉它，相册项之后 apply 报「源 stat 失败」 |
| 32 | src/Pm/Convert.hs:242 | 成片目标冲突复用 albumPlanItems，NEEDS-DECISION 文案说「相册已有同名」，位置写错 |
| 33 | src/Pm/Doctor.hs:301 | 备份 root 上 I7 行把所有 pm backup 的 Copy 都归为 inbox-origin（src 在备份 root 外），检查空转、统计误报 |
| 34 | src/Pm/Doctor.hs:397 | pending Copy 的 dst 用布尔 doesFileExist 探测：ACL 拒绝的 dst 被判 C1「无痕迹」exit 0，而非 PM-LINK Bad（Rename 臂已按 F033 改成三态） |
| 35 | src/Pm/Doctor.hs:410 | 崩溃留下的 pending Copy Intent，若 dst 后来被另一计划合法落位（内容不同），永远报 C5 Bad，--repair 还会生成隔离那个合法文件的计划 |
| 36 | src/Pm/Doctor.hs:542 | DESIGN §6.4 C3（journal 尾丢失、dst 完好 → 补记 Done）没有实现；代码里的 "C3" 标签实际含义是「有 Done 无 Intent（跳过）」；KernelTests「C3 语义」只断言零告警 |
| 37 | src/Pm/Doctor.hs:587 | C4 复验窗口 = 上次 CleanShutdown 之后全部 Done，但只有 execPlan 写 CleanShutdown：trash empty 清掉的 payload 会被反复报 C4「Done 目标不存在」 |
| 38 | src/Pm/Doctor.hs:698 | applyRepairs 用裸 putStrLn 汇报（补记 / 删 tmp / 生成 C5 计划），pm serve 的 stdout 已静音，GUI 触发的自愈动作无任何记录 |
| 39 | src/Pm/Exec.hs:491 | Copy 在 JIntent 之后二次 confinedTmp 失败返回 OConflict 但不写 JFailed 终态：Intent 悬空，doctor 报假的 C1「中断」，计划页既非完成也非失败 |
| 40 | src/Pm/ExecTypes.hs:119 | undo 隔离（从 .pm/trash rename 回原位）后 updateCatalog 不会把条目加回 catalog，索引静默缺项，之后各命令被「先 pm scan」挡住且无提示 |
| 41 | src/Pm/GitGuard.hs:102 | .gitignore 带 UTF-8 BOM 且首行 `.pm/` 时被判「缺 .pm/ 行」，git 自身会跳过 BOM |
| 42 | src/Pm/Ingest.hs:168 | runTwoPlans 对主库计划「执行被整体拒绝」（锁忙 / root 不符）也报「有未完成项 → pm resolve」 |
| 43 | src/Pm/Op.hs:220 | isTrashSrcRel 只查前两段，`.pm/trash` 本身与 `.pm/trash/manifest.ndjson` 可作 rename 源：手改计划经 pm apply 可把 manifest 或整个隔离区搬进用户数据（之后全部 payload 变 UNREGISTERED） |
| 44 | src/Pm/Plan.hs:433 | deletePlanAnyRoot 只保留最后一个 root 的错误：主库删计划真失败时报成 vault 的「计划不存在」 |
| 45 | src/Pm/Scan.hs:131 | MAX_PATH 预检（240）只管源路径，`.pm/trash/<pid>/…` 与 `.pm/tmp` 目标更长 34+ 字符：226–239 字符的源可入索引却永远无法隔离（Win32 错误码提示还误指 183） |
| 46 | src/Pm/Scan.hs:347 | 已枚举但 stat / hash 失败的文件，其旧 catalog 条目被丢弃（查不出 → 不存在），与 sweepCounts「错误口不算消失」规则不一致 |
| 47 | src/Pm/Serve.hs:394 | apply 进行中，同进程的 GET /api/plans 与 prune 撞 GHC 进程内文件锁：journal 被报「无法可信读取——人工核查」，所有计划显示未执行 |
| 48 | src/Pm/Serve.hs:404 | GET /api/plans 的失效判定按两个 root 的 journal 告警合取门控，而 CLI 与 prune 按 root 各自门控：GUI 与 CLI 结论不一致，GUI 会删掉自己标成「未执行」的计划 |
| 49 | src/Pm/ServeAi.hs:107 | classify 按裸文件名在整个相册子树里找条目，子目录同名文件会遮蔽平铺相册照片，AI 建议算在错的图上 |
| 50 | src/Pm/ServeAi.hs:184 | 坐标用 `show` 重渲染，\|v\|<0.1 时输出科学计数法（5.23e-2）并原样存入 vault-notes.json |
| 51 | src/Pm/ServeAlbum.hs:74 | /api/album/ignore 把主库锁忙报成 400「忽略清单未写入」而非 409（与 hold / notes / config 端点不一致） |
| 52 | src/Pm/ServeVault.hs:131 | 仅 DRIFT 的 push-plan 响应仍给出手动 git add / commit / push 步骤，虽然什么都不会落位 |
| 53 | src/Pm/SortSource.hs:205 | 源里含 pm root 时，设计内的「pm 状态目录不进入」跳过被当枚举失败：exit 0→1 并报「未能枚举」 |
| 54 | src/Pm/Status.hs:279 | stagingEventOf 不认 `To-Be-Sync'd\Raw\<年>\<事件>` 布局（把年份当事件），且不足 4 段的暂存文件不产生事件行 |
| 55 | src/Pm/Vault.hs:602 | vault push 无项时的提示按 newActive 计数，把 UNPUSHABLE 的 .png 算成「NEW 待分类」并给出会被拒绝的命令（N4 同形回归） |
| 56 | src/Pm/Vault.hs:613 | `pm vault push --apply` 直接执行后不刷新主库侧 vault 缓存，pm status 继续把已推的照片显示为 NEW |
| 57 | src/Pm/Vault.hs:661 | DRIFT 项生成 Copy 时不过 pushableExt 闸：vault 里已有 .png 时，resolve --keep src 会把 .png 经 push 写路径推进 vault |
| 58 | test/ConvertTests.hs:130 | bracket_ 用 unsetEnv 而非恢复旧值，清掉用户的 PM_PYTHON，后续 caseE2E / caseDerivedGuards 找不到 python（本地顺序依赖的假失败） |
| 59 | test/DocDriftTests.hs:220 | innerHTML 哨兵只看 `=` 后两个字符，`innerHTML = "" + expr` 也能通过「只允许赋空串」 |

## 4. 被证伪的疑点（14）

下面每条是原疑点与验证者证伪的要点（英文原文，截断）。

- **scripts/verify_backup_entries.py:23** — --verified-on compares a local calendar date against lastVerified, which Scan.hs writes in UTC, so entries hashed between 00:00 and 08:00 local (UTC+8) are silently excluded
  - 证伪要点：CODE: Producer side is as the finder says — src/Pm/Scan.hs:324 `vnow <- getCurrentTime` / :333 `enLastVerified = Just vnow`, src/Pm/ExecTypes.hs:100-115 `updateCatalog now …` with `now` from `getCurrentTime` in Cli.hs:282, and Types.hs:149 `"lastVerified" .= enLastVerified e` — aeson's ToJSON UTCTime emits ISO-8601 with a trailing `Z` (UTC). Consumer side, scripts/verify_backup_entries.py:23 `entries = [e for e in entries if (e.get("lastVerified") or "").startswith(a.verified_on)]` is a raw string-prefix filter; it performs no time-zone conversion at all, so there is no *wrong* conversion. The…

- **src/Pm/Album.hs:200** — albumCandidates keys album entries by basename while classifyAlbum/albumPlanItems look up the exact `相册\<name>` path — the two views disagree when 相册 has subfolders
  - 证伪要点：CODE: the two views do differ as described — albumCandidates (Album.hs:198-207) builds albumByFold from every KindPhoto entry whose first component is 相册 at any depth, keyed by case-folded basename, while classifyInto (Album.hs:107-109) looks up the exact flat path `相册\<basename>` (albumDst, :69). REPRO (traced): catalog {成片\E\x.jpg sha S, 相册\2024\x.jpg sha S}: `pm album candidates` → m = Just (相册\2024\x.jpg), enSha equal → filtered out, x.jpg not listed; `pm album add E/x.jpg` → catByFold has no `相册\x.jpg` → judged Nothing → arCopy → plan lands 相册\x.jpg; album now holds S twice. So the diverg…

- **src/Pm/Album.hs:371** — pm album unignore never accepts the record's stored path in the form pm itself prints/stores it
  - 证伪要点：CODE: resolveDel (Album.hs:368-378) accepts a 64-hex sha, otherwise runs parseProcessedRel, which rejects a `成片\` prefix (:175) with `不要带 成片\ 前缀，直接给 <事件夹>/<文件名>`; on Right rel it looks the current entry up by path and then its sha in oldBySha, and consults oldByPath only when the path is not in the index. REPRO of sub-claim 1: `pm album unignore 成片\E1\a.jpg` → perrs (:412-413) → exit 2 with that self-correcting message; `pm album unignore E1/a.jpg` then succeeds (or, if the object is gone, hits the oldByPath arm). Sub-claim 2: record {sha S1, path 成片\E1\a.jpg}, file re-exported with S2: `E1/a.…

- **src/Pm/Cli.hs:253** — Interactive confirm executes the in-memory plan captured before the lock; a `pm resolve` written under the lock during the y/N prompt is silently overridden
  - 证伪要点：CODE: Cli.hs:241-257 savePlanAndMaybeRunTo saves the plan, prints it, blocks in `confirm go` (Cli.hs:74-85, `try getLine`) with no lock, then passes the same in-memory `plan` to executePlanNowWith; Exec.execPlan' (Exec.hs:114-190) never re-reads the plan file inside withRootLock — it re-verifies disk evidence only (root identity, I11, .pm trust, group barrier, per-item fingerprints/dst state). Apply.resolveOn (Apply.hs:226-242) does its own in-lock reload and write-back, so the finder's mechanics are accurate: a `pm resolve <id> --item 7` issued in a second terminal while the prompt is open su…

- **src/Pm/Config.hs:202** — loadConfigState collapses an unreadable/ACL-denied config into '配置不存在 → 先运行 pm init'
  - 证伪要点：CODE: Config.hs:200-215 `exists <- doesFileExist fp; if not exists then … CfgAbsent "配置不存在: … —— 先运行 pm init --main <主库路径>"`. doesFileExist swallows ACL/media errors as False, so a DACL-denied config.toml yields the 'absent' message on every command routed through withCfg (Commands.hs:84-88), exit 2. REPRO: icacls deny(F) on %APPDATA%\pm\config.toml; `pm status` prints '配置不存在 … 先运行 pm init' exit 2. Following that advice: runInit (Commands.hs:141-144) probes with `classifyGitProbe <$> probeName cfgFp` → GetFileAttributesW fails with ERROR_ACCESS_DENIED → ProbeUnknown → Left '配置文件 … 存在性查不出（ACL/介…

- **src/Pm/Config.hs:299** — writeConfig silently replaces a symlinked config.toml with a regular file (deleteBoundAt deletes the link itself, not through it)
  - 证伪要点：CODE: Config.hs:288-301 writeConfig: `old <- doesFileExist fp; when old (deleteBoundAt fp); moveBoundNoReplace tmp fp`. deleteBoundAt (Win.hs:717-731) opens via pm_open_for_dispose with FILE_FLAG_OPEN_REPARSE_POINT (cbits/pm_win.c:50-56), so for a file symlink the handle is the link object; GetFinalPathNameByHandleW on that handle reports the link's own path → rawBoundTo passes → FileDispositionInfo removes the link; the tmp is then renamed into place as a regular file. REPRO: `mklink %APPDATA%\pm\config.toml D:\dotfiles\pm\config.toml`; `pm config set --vault X` → configTxn reads through the …

- **src/Pm/Config.hs:654** — Cross-process I10 contention raises PermissionDenied, not ResourceBusy, so every documented 'lock busy' downgrade is unreachable and the command crashes instead
  - 证伪要点：CODE: withRootLock (src/Pm/Config.hs:645-661) and withConfigLock (:314-329) do `try (openStateLock fp)`, map `isAlreadyInUseError` (ResourceBusy) to Nothing, rethrow anything else, then `hTryLock h ExclusiveLock` and return Nothing when it yields False. openStateLock (src/Pm/Win.hs:446-455) -> openBoundTo ReadWriteMode (:405-407) -> `openBinaryFile fp ReadWriteMode`. The finder's whole mechanism rests on the claim that GHC's `__hscore_open` opens writable files with `_wsopen(..., _SH_DENYRW, ...)`, so a second PROCESS would get ERROR_SHARING_VIOLATION -> EACCES -> PermissionDenied. That is the…

- **src/Pm/Removable.hs:218** — scanRootRetry's 'clean' predicate counts deterministic walk skips (reparse point, path too long) as transient errors, causing up to dwAttempts pointless full rescans of the backup drive with a misleading 瞬断 message
  - 证伪要点：CODE: the mechanics are as described. Scan.hs listTreeCov puts the two deterministic skip rows into the walk error list (`pure ([], [(relPath, "path too long (>=240 chars)")], [])` and `pure ([], [(relPath, reparseSkipNote)], [])`), scanRoot folds them into `srErrors = walkErrs <> statErrs <> hashErrs`, and Removable.hs:212-218 has `clean res = null (srErrors res) && srCarried res == 0`; with the drive present (`driveOk` True) the Right branch calls `recover ... Hiccup` which prints `⚠ 扫描 读写出错（N 处读错、0 条落在未枚举子树）；盘仍在，按瞬断处理，5 s 后重试`, sleeps `min 5 cooldown` = 5 s and rescans with `Just (srCatalog…

- **src/Pm/Removable.hs:257** — execPlanRetry ignores readJournal's error list: an unreadable journal is settled as empty and landed renames are re-run and reported CONFLICT
  - 证伪要点：CODE: the dead-wrapper observation is correct. Journal.hs readJournal returns `([], [m])` for a trust-gate failure (:115) and readJournal' returns `([], [m])` for a readPmState Left (:125); Config.hs readPmState wraps the open/read in `try` (:439) and converts every IOException except ENOENT into `Left "… 无法可信读取 …"` (:442-446), so `withDriveRetry dw root "读 journal" (readJournal root)` at Removable.hs:257 can never see an exception, and `fst` discards the warning. But the failure scenario does not reach the claimed outcome. (a) Rename items are never grouped with a Copy: the only plan-level Op…

- **src/Pm/Scan.hs:324** — lastVerified is stamped after hashing finishes, so the racy-mtime guard can trust a torn hash on coarse-timestamp volumes
  - 证伪要点：CODE: Scan.hs:317-334 confirms the mechanics: preSnap comes from the stat pass (Scan.hs:265-267, possibly minutes before hashing), `sha <- sha256File abs'`, `post <- statSnap abs'`, `if post /= preSnap then Left rel` (volatile), else `vnow <- getCurrentTime` AFTER hashing and `enLastVerified = Just vnow`. Hash.hs:193-198 statHitStable trusts when `utcToNs v - mtimeNs > racySlackNs` (2 s). So a torn sha survives only if: the volume has coarse timestamps (FAT/exFAT 2 s; on NTFS a write after the pre-stat changes the 100 ns mtime and post /= pre catches it), the writer's last write lands in the S…

- **src/Pm/Serve.hs:361** — POST /api/backup-init reports every failure as 400 '登记失败', including config-lock-busy and the partial-success case where the backup root marker was already created
  - 证伪要点：CODE: src/Pm/BackupCmd.hs:107-131 backupInitRun returns `Left` for preflight, role/corrupt/untrusted marker, createRootInfo failure and for `register` failures; register (BackupCmd.hs:145-175) returns `Left "另一个 pm 正在改配置（配置锁被占），备份盘没登记进配置"` when withConfigLock yields Nothing. Serve.hs:358-361 maps every Left to `400 {"error":"登记失败","details":[m]}`. The CLI does exactly the same collapse (`runBackupInit` BackupCmd.hs:178-181: every Left → print + exit 2). REPRO: GUI 登记 while a terminal holds config.toml.lock → createRootInfo writes `.pm/root-id.json` → register → Nothing → Left lock message → 40…

- **src/Pm/Trash.hs:150** — Manifest torn tail after power loss (§6.3 step 1) becomes a permanent TRASH-MANIFEST Bad (doctor exit 1) with no repair path, contradicting DESIGN §6.4 '撕裂尾不是损坏' and unlike the journal's Warn
  - 证伪要点：CODE: The mechanics the finder describes are accurate. `withPmStateAppend'` (src/Pm/Config.hs:465-475) seals a non-newline tail with `BS.hPut h (BS.singleton 10)` and passes `torn` to the callback; only `withJournal` (src/Pm/Journal.hs:88-95) uses that flag to write a `JTornGap` marker, while `appendManifest` (src/Pm/Trash.hs:117-119) calls the flag-less `withPmStateAppend` and writes no marker. `readManifest'` (Trash.hs:150-158) maps every unparsable line to `Left ("manifest line " <> show i <> ": " <> e)` with no last-line/sealed distinction, `runDoctor'` maps `tvWarnings` to `Finding "TRASH…

- **src/Pm/Vault.hs:417** — `pm vault status --json` prints its ERROR text to stdout, not stderr as the legacy contract specifies
  - 证伪要点：CODE: src/Pm/Vault.hs:414-417 `runVaultStatus asJson cfg = do er <- computeVault asJson cfg; case er of Left (msg, code) -> putStrLn msg >> pure code`, and the exit-2 strings are built at :266-267. So yes, in `--json` mode an `ERROR: vault missing: …` line lands on stdout. However this is the project-wide CLI convention, not a deviation: the only stderr writer in src/ is Scan.hs:362 (progress), and the sibling `pm vault notes --json` does exactly the same `Left (msg, code) -> putStrLn msg >> pure code` at src/Pm/VaultCmd.hs:332; Commands.hs:91/292/334 likewise. The `quiet` flag on computeVault…

- **src/Pm/VaultHold.hs:133** — readPmRecords reports a benign in-flight overwrite (delete→rename window) as crash residue and hard-fails
  - 证伪要点：CODE: The finder's reading of the code is accurate. src/Pm/Config.hs:733-741 `writeJsonReplacing` does openFreshBinary tmp → flush → `when old (deleteBoundAt fp)` → `moveBoundNoReplace tmp fp`; `deleteBoundAt` (Win.hs:720-731) sets FILE_DISPOSITION_INFO on a handle that `withDisposeHandle` closes immediately, so the name vanishes before the rename-by-handle of tmp. src/Pm/VaultHold.hs:123-137 `readPmRecords`: main → `Right Nothing`, then tmp → `Right (Just _)` → `Left "… 缺失，但残留 …tmp（覆盖写中途崩溃）…"`; only the both-missing interleaving gets the re-read (:127-132). Readers that do not hold the root l…


## 5. 修复建议的优先级（仅建议，未动手）

1. 先做「极小 / 小」且影响真实使用的：#4 #5（配置与 root-id 路径规范化，否则 junction 用户无法 init）、#10（Raw\ 下杂文件让 sort 整体失败）、#2（GUI 空值写 0 关掉瞬断保护）、#7（弹「请插入磁盘」对话框）、#11（判据③失效）、#9（apply 端点异常边界）、#39（悬空 Intent）、#43（isTrashSrcRel 收紧）。
2. 再做需要小设计的：#3（暂存区 case-fold 谓词统一）、#6 与 #34（二态探针改三态）、#8（reparse point 判定改 probeName，需同时调整 caseScanDeniedProbe）。
3. 文档 / 测试对齐：#12 #13 #19 #36 #58 #59。


---

## 附录 A：每条确认缺陷的验证者摘要与建议修复（英文原文）


### A1. [medium] gui/ui/app.js:521 — AI place suggestions from a previous survey are pre-filled into a re-scanned (possibly different) source directory

- 来源视角：gui/invariant-contract, gui/crash-logic

- 验证者摘要：sortAiPlaces() captures no survey generation: if the user re-scans (possibly a different source) while POST /api/suggest is in flight, renderSurvey rebuilds segInputs and the late response writes place values keyed only by segment index into the new survey's empty inputs, so a different card's segments get pre-filled with the previous card's places and can be turned into wrongly named event folders.

- 建议修复（trivial）：Capture `const gen = gens.sort` (or a dedicated stamp('sortAi')) and the survey object at the start of sortAiPlaces and after the await `if (stale('sort', gen) || lastSurvey !== survey) return;` before touching segInputs; alternatively disable #btn-sort-scan / ignore Enter while the AI request is pending.


### A2. [medium] gui/ui/app.js:697 — Settings page: saving an EMPTY drive-wait box silently writes driveWait=0 (disables drive-drop protection) instead of default

- 来源视角：config-cli/invariant-contract, serve-api/invariant-contract, gui/crash-logic, gui/invariant-contract, crosscut/json-contracts

- 验证者摘要：Settings page: the 保存 button for 掉线等待 sends `Number(val('#cfg-drive-wait'))`, so an empty box (the normal state when the setting is unset, placeholder '默认 1800 秒') submits driveWait:0, which the server legitimately accepts as '关闭瞬断保护' and persists as `drive-wait = 0`, disabling backup-drive drop protection while the banner reports success. The workers field has the same construction (empty → 0 → 400 blaming a value the user never typed).

- 建议修复（trivial）：Use the existing valOrNull rule: `driveWait: (v => v === '' ? null : Number(v))(val('#cfg-drive-wait'))` and likewise `workers: v === '' ? null : Number(v)`; or refuse to save an empty box with a hint to use 恢复默认.


### A3. [medium] src/Pm/Cli.hs:474 — Staging freshness gate compares a case-insensitive on-disk probe with a case-sensitive catalog filter: mismatched-case To-Be-Sync'd folder makes pm import/clean/sort refuse forever

- 来源视角：crosscut/windows-paths, scan-sort/crash-logic

- 验证者摘要：stagingFresh (and the sibling staging predicates in Import/Clean/Diff/Status) identify the staging area by exact-case first path component `To-Be-Sync'd`, while the on-disk probe/walk in freshnessSweep is NTFS case-insensitive and re-keys files under the canonical spelling. If the user's staging folder is spelled with different case, the catalog slice is empty, every staged file counts as 'new', and pm import/sort/clean staging are refused with '→ 先 pm scan' although scanning can never reconcile it; status/backup-scope silently treat those files as non-staging.

- 建议修复（moderate）：Introduce one predicate in Pm.Import, e.g. `isStagingRel rel = map (foldPath) (take 1 (splitDirectories rel)) == [foldPath stagingTop]`, and use it at Cli.hs:474, Import.hs:69/96/192, Clean.hs:64-65, Diff.hs:60, Status.hs:281. In stagingFresh, discover the on-disk spelling (listDirectory root, pick the name whose foldPath equals foldPath stagingTop, default stagingTop) and pass that name as relPrefix so sweep keys match catalog keys; alternatively fold both key sets before sweepCounts. Add a test with a lower-case staging dir.


### A4. [medium] src/Pm/Config.hs:152 — Config path (configFilePath) is only makeAbsolute'd, never canonicalized: junction/symlink/SUBST/8.3 components in %APPDATA% or PM_CONFIG make withConfigLock/writeConfig fail closed with an uncaught alias-attack error and a leftover .tmp wedges all later writes

- 来源视角：config-cli/crash-logic, crosscut/write-primitives, win-fs/crash-logic, win-fs/invariant-contract

- 验证者摘要：configFilePath (Config.hs:148-156) only makeAbsolute's PM_CONFIG and never canonicalizes the XDG/APPDATA path. If any component of the config directory is a junction/symlink/SUBST/8.3 name, withConfigLock's openStateLock→openBoundTo→handleIsAt compares the unresolved string against GetFinalPathNameByHandle output, fails, and the non-EBUSY IOException is rethrown: pm init / pm config set / pm backup init die with exit 1 and a '句柄绑定的不是这条路径…人工核查' message, POST /api/config returns 500. Reads still work, so pm can never write its configuration on such a machine. (The lock fails before writeConfig, so no .tmp orphan/wedge occurs in this scenario.)

- 建议修复（small）：In configFilePath, resolve the result once at the source: after makeAbsolute / the XDG join, apply canonicalizePath (directory ≥1.3.1 canonicalizes the longest existing prefix, so a not-yet-existing config.toml is fine), wrapped in try with the makeAbsolute'd path as fallback or a clear error. All lock/tmp/final names derive from fp, so they stay consistent.


### A5. [medium] src/Pm/Config.hs:608 — createRootInfo' feeds the raw, un-canonicalized root string (junction/SUBST/8.3/forward-slash vault.path) into handle-bound moveBoundNoReplace/deleteBoundAt; pm init / first vault push crash with an uncaught alias error and leak .pm/root-id.json.*.tmp

- 来源视角：crosscut/windows-paths, crosscut/write-primitives, win-fs/crash-logic, win-fs/invariant-contract

- 验证者摘要：createRootInfo' (Config.hs:597-615) is the only .pm write that builds its final/tmp paths from the caller's raw root string instead of a resolveUnder-canonical path. runInit (makeAbsolute only) and ensureVaultRoot (cfgVaultPath verbatim; checkAbsolute accepts 'D:/vault') therefore pass junction/SUBST/8.3/forward-slash roots straight into moveBoundNoReplace, whose rawBoundTo pre-check fails against GetFinalPathNameByHandle's canonical form; the Left branch then calls deleteBoundAt tmp unguarded, which fails the same way and throws out of pm init / pm vault push (exit 1, attack-shaped message) and out of POST /api/vault/push-plan (bare 500), leaving .pm/root-id.json.<hex>.tmp behind on every attempt. Docs (resolveUnder, DESIGN-COMMANDS §11 F042, DESIGN §14 item 4) say a junction root is legitimate and entries must be normalised, so code contradicts the contract. backup init is unaffected (BackupCmd canonicalizes).

- 建议修复（small）：In createRootInfo' derive the target from the trusted resolver instead of the raw string: `final <- resolvePmPath root "root-id.json"` (requirePmTrusted has already run, so resolveUnder yields the canonical path) and build tmp from that final; wrap the Left-branch `deleteBoundAt tmp` in try and append its failure to the returned message so no exception escapes. Optionally also canonicalizePath mainPath in runInit and vaultDir in ensureVaultRoot for consistent messages.


### A6. [medium] src/Pm/Names.hs:320 — filterDirs collapses an unreadable year/event directory into 'not a directory' → silently omitted from the pm names report, exit 0

- 来源视角：scan-sort/crash-logic

- 验证者摘要：In runNamesOn, filterDirs (Names.hs:320-322) uses the two-state `doesDirectoryExist` to classify each entry of Raw\, Raw\<year> and 成片. On Windows an ACL deny(F) on such a directory makes doesDirectoryExist return False (CreateFile ACCESS_DENIED swallowed by catchIOError — confirmed by the project's own ACL experiments in REVIEW-LOG-3/-4 and TestUtil.withDenyAll). The entry is then dropped from both validYears and oddTop, is never listed (so the enclosing `try` never fires), and is absent from the report: the header counts exclude it, no ⚠/✋ line names it, and the run can end with '✓ 无可机械执行的改名' and exit 0. This contradicts the documented contract at Names.hs:238-241 / DESIGN-COMMANDS.md §8 ('读不出 = 整批拒绝 exit 2、零计划') and is the same read-path fail-open shape that P7-I R1 fixed elsewhere via whenPresent but missed here. At the 成片 layer the omission can also remove one of two month candidates in restoreMonth, converting an ambiguity NEEDS-DECISION into a unique (possibly wrong-month) rename.

- 建议修复（small）：Make the per-entry classification three-state inside the existing `try`: replace `doesDirectoryExist (base </> n)` in filterDirs with a helper that, when doesDirectoryExist is False, distinguishes 'really not a directory' from 'cannot determine' — e.g. use `probeName`/Win32 GetFileAttributesEx (which the project measured to be immune to deny(F)) and test FILE_ATTRIBUTE_DIRECTORY, treating ProbeUnknown or an attribute-read failure as `ioError (userError (path <> " 存在性查不出（ACL/介质错误？）"))` so it flows into the existing '枚举失败 … 未生成计划' exit-2 branch at :254-257. Alternatively wrap each entry in `whenPresent (base </> n) (doesDirectoryExist ...)` and raise on Left. Add a test using TestUtil.withDenyAll on Raw\<year> asserting exit 2 and that the year is named in the output. (Vault.listFlatPhotos:130 has the same per-entry shape and could be aligned in the same way, out of scope here.)


### A7. [medium] src/Pm/Plan.hs:391 — planStale probes removable drive roots without SEM_FAILCRITICALERRORS; pm plan list / prune / GET /api/plans can pop the system "请插入磁盘" dialog for an empty card-reader slot

- 来源视角：tests-kernel/test-quality, commands-doctor/invariant-contract

- 验证者摘要：planStale (Plan.hs:388-392) probes the plan's source path and its drive root with GetFileAttributesEx-based `doesPathExist`/`doesDirectoryExist` without the process ever having called `suppressCriticalErrorDialogs` (only `discoverBackupRoots` does, Backup.hs:44). When a plan's copy source sits on a removable drive letter whose media was removed (empty card-reader slot), `pm plan list`, `pm plan prune` and `GET /api/plans` (GUI plans page) trigger the Windows hard-error 「请插入磁盘」dialog (twice per plan) and block until it is dismissed; the eventual stale=False answer is right but the CLI/GUI request stalls on every refresh. The test only covers a letter with no volume, not an empty slot.

- 建议修复（trivial）：Call `suppressCriticalErrorDialogs` once at process start (e.g. in app/Main.hs `main` right after `setupConsole`, or inside `setupConsole` in Win.hs), which is Microsoft's recommended practice and makes the existing call in discoverBackupRoots redundant but harmless; alternatively call it at the top of `planStale`. Optionally extend caseStale's comment to note the empty-slot case is covered by the process-wide error mode.


### A8. [medium] src/Pm/Scan.hs:134 — Walk skips every reparse point via pathIsSymbolicLink, contradicting the project's own name-surrogate rule (OneDrive/Dedup placeholders become 'symlink skipped' errors)

- 来源视角：scan-sort/crash-logic

- 验证者摘要：listTreeCov decides 'is a link' with directory's pathIsSymbolicLink, which on Windows is true for any FILE_ATTRIBUTE_REPARSE_POINT object, so every file/dir carrying a non-name-surrogate reparse tag (OneDrive/cfapi placeholders incl. hydrated ones, Windows Dedup, WOF/`compact /exe`, WIM) is dropped from scan, freshness sweeps and sort with a 'symlink/reparse point skipped' error row. This contradicts the project's own P3b-12 ruling (Win.hs:160-176, REVIEW-LOG-1:126) that only name-surrogate tags redirect and that rejecting the rest makes pm unusable on such volumes; probeName implements the right test but the walk never adopted it.

- 建议修复（moderate）：In listTreeCov replace the pathIsSymbolicLink probe with `probeName abs'`: NameSurrogate → reparseSkipNote (as today); ProbeUnknown → the existing '链接属性查不出' uncovered branch; NameMissing → fall through to the stat path; NamePlain → continue (dir/file). Decide separately whether dehydrated cloud placeholders should be hashed (hydration on read) or reported; update caseScanDeniedProbe, whose deny-all(F) fixture currently relies on pathIsSymbolicLink failing (GetFileAttributesW is ACL-immune, so the error would move to statSnap and lose the '查不出' wording).


### A9. [medium] src/Pm/Serve.hs:339 — No exception boundary in serveApp / POST /api/apply / recordPost: IOExceptions from the execution chain escape to warp's bare 500 (no JSON, no CORS), so the GUI shows 'Failed to fetch' / '没有执行' although items may have landed

- 来源视角：gui/crash-logic, serve-api/crash-logic, serve-api/invariant-contract, crosscut/write-primitives, tests-serve-vault/test-quality

- 验证者摘要：POST /api/apply (and ServeVault.recordPost for hold/notes) run their write chains without `try`, unlike planPost/listPlans which were explicitly fixed for the same shape. Any IOException that the kernel deliberately rethrows (Deterministic errors from execPlanRetry/withDriveRetry, userError from withRootLock/openBoundTo, saveCatalog/writeJsonReplacing failures) escapes to warp's default `500 text/plain "Something went wrong"` without CORS headers. Because the Tauri page is cross-origin, fetch rejects and the GUI shows「请求失败：Failed to fetch」(or「没有执行：HTTP 500」) with no cause, even when items have already landed and been journaled Done; the reason is only on serve's (muted) stdout/stderr.

- 建议修复（small）：Mirror ServeAlbum.planPost: in the apply handler wrap `prepareApply … executePlanNowWith … afterApply` in `try … :: IO (Either IOException …)`, read the accumulated `logRef`, and on Left answer `jsonR status500 [] (object ["error" .= ("执行中断: " <> show ex), "planId" .= pid, "log" .= logs])` so the GUI gets a JSON body with CORS headers and the lines printed so far; do the same around `withVaultTxn` in recordPost (Left → err status500 with show ex). Optionally add a last-resort `handle (\(e :: IOException) -> err status500 (show e))` around `route` in serveApp, but the per-endpoint try is the safer minimal change.


### A10. [medium] src/Pm/Sort.hs:467 — existingEvents treats a regular file under Raw\ as a fatal enumeration error → whole `pm sort` survey exits 2

- 来源视角：scan-sort/invariant-contract, scan-sort/crash-logic, tests-guards/test-quality, tests-sweep/test-quality

- 验证者摘要：existingEvents (src/Pm/Sort.hs:467) calls lsDir on every child name of `<root>\Raw` without checking that the child is a directory. For a regular file (e.g. Explorer's `Raw\desktop.ini` or `Thumbs.db`) probeName answers NamePlain, whenPresent runs listDirectory on the file, which throws on Windows (FindFirstFileW on `file\*` fails), and the failure propagates as `Left "已有事件夹枚举失败（被占/介质错误？）..."`. Consequently `pm sort <src>` (survey form) exits 2, GET /api/sort/survey and POST /api/suggest answer 409, with a message blaming a lock/media error that does not exist, while `pm sort --place` (which never calls existingEvents) and `pm names` (which filters with filterDirs) work on the same library. Introduced by the R1 whenPresent rewrite, which replaced the previous 'is it a directory' guard with an 'does the name exist' probe; no doc or review round declares this intended and no test covers a non-directory in Raw\.

- 建议修复（trivial）：In existingEvents, skip children of `<root>\Raw` that are positively identified as regular files before recursing, keeping fail-closed semantics for anything else, e.g. change line 467 to `b <- concat <$> (mapM (lsDir . ((root </> "Raw") </>)) =<< filterM (fmap not . doesFileExist . ((root </> "Raw") </>)) =<< lsDir (root </> "Raw"))` (import filterM / doesFileExist). doesFileExist returns True only when the name is definitely a file; a directory, an ACL-denied name or a missing name stays in the list and still goes through whenPresent's three-state probe, so the R1 ProbeUnknown→Left guarantee is preserved. Add a SortTests case that writes `Raw\desktop.ini` in the fixture library and asserts surveySort returns Right (and that the year-level event list is unaffected).


### A11. [medium] src/Pm/Versions.hs:146 — rawEventOf treats a depth-3 Raw file's own name as its event folder, defeating criterion ③

- 来源视角：vault-backup/crash-logic

- 验证者摘要：`rawEventOf` (src/Pm/Versions.hs:145-147) requires only 3 path segments, so for a photo lying directly in a year folder (`Raw\<年>\<file>`) it returns `Just "Raw\<年>\<file>"` — the file's own name as the 'event folder' — instead of the Nothing the comment promises. Because the key then differs per file, a same-stem RAW sitting right beside such a JPG is never found in `rawOriginals`, criterion ③ wrongly deems the Raw↔成片 same-sha pair designed redundancy, and it is dropped from `vgExactDups` (hidden from both `pm versions` and `pm dedupe`). Contradicts DESIGN-COMMANDS §5 criterion ③ ('有原始档＝导出件误放，仍报'). Only affects off-layout files at depth 3; no data-loss direction.

- 建议修复（trivial）：Require the file to be at least one level below the event folder: `rawEventOf p = case splitDirectories p of (a : b : c : _ : _) -> Just (joinPath [a, b, c]); _ -> Nothing`. Depth-3 Raw files then yield Nothing → rawFinOk False → reported as noise, matching the comment's '宁可多报一行噪音'. Optionally add a test case in caseDesignedGroups with `Raw\2024\x.JPG` + `Raw\2024\x.ARW` + `成片\...\x.JPG` expecting the sha in vgExactDups.


### A12. [medium] test/KernelTests.hs:553 — Q-DONE-LOST "--repair 不盲补" assertion is vacuous: fixture root has no root-id, so --repair is refused before applyRepairs runs

- 来源视角：tests-kernel/test-quality

- 验证者摘要：test/KernelTests.hs:544-556 ("Q-DONE-LOST ... --repair 不盲补"): the fixture never creates .pm/root-id.json (only withJournal + trash dir), so `runDoctor root (DoctorOpts False True)` is refused at runDoctorGate → requireWritable → RootAbsent and falls to diagnoseOnly; applyRepairs never executes and the I11 Bad finding is discarded. The final assertion `filter isDone es @?= []` therefore passes regardless of whether applyRepairs honours the Warn-only whitelist (Doctor.hs:680). The first assertion (Bad classification when trash sha mismatches) is still meaningful; only the '--repair does not blindly append Done' half of the test is vacuous, and no other test pins that gate for Q-DONE-LOST.

- 建议修复（trivial）：In the test, add `writeRootInfo root (RootInfo "m" RoleMain now Nothing)` (already imported from Pm.Config at KernelTests.hs:20) before `withJournal`, mirroring StateGuardTests.hs:284; optionally also assert that the repair run's findings contain no I11 row (e.g. `(fs,_) <- runDoctor ...; assertBool ... ("I11" `notElem` map fRow fs)`) so a future gate change cannot silently re-neuter it. No production code change.


### A13. [low] README.md:227 — README cheat sheet shows `pm undo --last [N]` but --last requires a value

- 来源视角：config-cli/crash-logic, config-cli/invariant-contract

- 验证者摘要：README.md:227, README.zh.md:173 and docs/DESIGN.md:256 write the undo invocation as `pm undo --last [N]`, using the docs' own bracket-means-optional convention, which implies `--last` may be given without a value. The parser (app/Main.hs:417, `option auto … value 1`) only defaults N when `--last` is absent altogether; `pm undo --last` alone is rejected by optparse-applicative with `The option `--last` expects an argument` (exit 1). The correct shape, and what `pm undo --help` prints, is `pm undo [--last N]`. The DocDriftTests sentinel (test/DocDriftTests.hs:333) checks only for the substring `pm undo --last`, so it does not catch the misplaced bracket even though REVIEW-LOG-4 round 41 #7 required the README summary to be the real CLI form.

- 建议修复（small）：Change the three doc lines to `pm undo [--last N]` (DESIGN.md: `pm undo [--last n]`), and update the sentinel in test/DocDriftTests.hs:333 to assert the corrected substring (e.g. `"pm undo [--last N]" `isInfixOf` s`, keeping the existing `pm undo <planId>` negative check) so the drift cannot regress. No code change needed.


### A14. [low] app/Main.hs:265 — pm init --workers accepts any Int (0, negative, >64) while pm config set enforces 1..64; checkConfig does not cover workers

- 来源视角：config-cli/crash-logic

- 验证者摘要：`pm init --workers N` persists any Int (0, negative, >64) into config.toml because initP has no reader bound and runInit validates only via checkConfig, which never inspects cfgWorkers; the same value is refused by `pm config set --workers` / POST /api/config via checkPatch's 1..64 gate. Consequence is a confusing inconsistency (init accepts, config set later refuses; `pm config` shows 0; scan banner prints workers=0 while actually running 1 thread via `max 1`), not a crash or data-safety violation. Hand-edited config is also loaded without a range check (Config.hs:126).

- 建议修复（trivial）：Move the range check into the shared sink: in ConfigEdit.checkConfig add `["并发数 " <> show w <> " 越界（1..64）" | Just w <- [cfgWorkers c], w < 1 || w > 64]` (and drop or keep the duplicate in checkPatch since checkPatch already calls checkConfig (applyPatch c p)); update initP's `--workers` help to "hash 并行度（1..64；默认=物理核数）". Optionally pin with a test that `runInit` with workers 0 / 65 exits 2.


### A15. [low] gui/src-tauri/src/lib.rs:108 — Packaged pm-ui.exe exits silently (no window, no message) when `pm serve` fails to announce

- 来源视角：gui/crash-logic, gui/invariant-contract

- 验证者摘要：When packaged pm-ui.exe is launched directly (Start menu / double-click) and `pm serve` fails to announce — most realistically because `pm init` has not been run yet (config missing/unreadable → withCfg prints the Chinese error on stdout instead of the JSON announce), or the loopback bind fails — lib.rs:105-111 only `eprintln!`s and `exit(2)`s before any window exists; with `windows_subsystem = "windows"` and no inherited console there is no stderr, so the app vanishes with no message. The `pm ui` half of the finding is wrong: Main.hs:166-167 gates `pm ui` behind withCfg (config errors are printed by pm itself before pm-ui starts), PM_EXE is always pm's own path, and pm-ui's stderr is inherited from the terminal via GHC createProcess, so `pm ui` does show the error line.

- 建议修复（small）：In lib.rs run(), on the Err arm show the message before exiting, e.g. under `#[cfg(windows)]` call user32 `MessageBoxW(null, msg, "pm-ui", MB_OK | MB_ICONERROR)` via a small `extern "system"` declaration (or `rfd`/tauri-plugin-dialog), keeping the eprintln for the console case; optionally also forward the first stdout line verbatim so the user sees pm's own `先运行 pm init --main <主库路径>` hint. No Haskell-side change needed.


### A16. [low] gui/ui/app.js:88 — GUI collapses 'catalog refused / unreadable' into '主库尚未索引 → pm scan' and drops the server's warnings (three-state → two-state)

- 来源视角：serve-api/invariant-contract

- 验证者摘要：GUI status page (app.js:88-91) and archive page (archive.js:28-29) test only `!s.index` and print '主库尚未索引 → pm scan', returning before the `s.warnings` loop. For CatRefused (index:null + non-empty warnings + exit 2 — untrusted .pm, unreadable/hand-edited snapshot, missing root-id.json, catalog identity mismatch) the real reason is dropped and the user is told the library was never scanned; the CLI renderer distinguishes the two cases.

- 建议修复（trivial）：In loadStatus, when `!s.index`: if `s.warnings.length` show '主库索引读不出：<root>\n' + warnings.join('\n') + '\n→ 排除原因后重试，或在终端 pm scan 重建' (banner class bad) instead of the 尚未索引 text; same branch in archive.js:29. Optionally still emit the warnings list before returning.


### A17. [low] gui/ui/app.js:382 — Plans page: apply result with code 2 and no items is described as 'has unfinished/needs-decision items' and told to consider `pm undo`

- 来源视角：gui/invariant-contract

- 验证者摘要：applyPlan (app.js:382) labels every non-zero code as '有未完成/待裁决项，见逐项结果'; the server answers 200 with code 2 and items [] when execPlan refused before executing anything (root lock held, identity/barrier refusal), so the headline is wrong and points to a per-item list that is not rendered. The reason is still visible in the log tail, and the trailing 'pm undo' hint is required by DESIGN-GUI.md:83 and only generates a reverse plan needing a confirmed apply, so impact is cosmetic.

- 建议修复（trivial）：Branch on the payload: if `j.code !== 0 && !(j.items||[]).length` render '没有执行（退出码 2）：<id>——见下方原因' with banner class bad and omit the undo hint; keep the existing text for code 1 with items.


### A18. [low] gui/ui/archive.js:38 — Archive page: when /api/album/candidates fails, the convert card asserts 'no non-jpg photos' (unknown collapsed into absent)

- 来源视角：gui/invariant-contract

- 验证者摘要：In gui/ui/archive.js loadArchive(), when GET /api/album/candidates fails (404/409/500, e.g. corrupt .pm/album-ignore.json), the catch at line 38 calls renderConvert([]) which sets #convert-meta to the definite '成片 / 相册下没有非 jpg 照片' (unknown collapsed into 'none'), while #album-cand-meta, the #album-ignored <details> (with its live 取消忽略 buttons) and #archive-warnings are never reset and keep the previous successful load's content. Only the album grid reports the error. No wrong plan can result (picked/convPicked are cleared and both lists are empty); the defect is misleading/stale UI text on the error path, contrary to the project's own three-state rule (app.js:166-170, ServeAlbum.hs:44).

- 建议修复（trivial）：In the catch at archive.js:38, replace `renderConvert([])` with explicit failure rendering: `$("#convert-list").innerHTML = ""; $("#convert-meta").textContent = "候选读不出来，非 jpg 清单未知"; $("#album-cand-meta").textContent = "读取失败"; renderIgnored([], []); $("#archive-warnings").textContent = "";` (or give renderConvert a `null` branch meaning 'unknown' and call renderIgnored([], []) there). Nothing else changes.


### A19. [low] package.yaml:107 — extra-source-files claims to declare every non-source file DocDriftTests reads, but omits several it does read

- 来源视角：scripts-ci/invariant-contract

- 验证者摘要：package.yaml:8-17 extra-source-files (comment: 'DocDriftTests reads these non-source files; registered into sdist, declared not incidental'; REVIEW-LOG-4.md:428 round 41 #9: 'registers all read non-source files') was not updated when later rounds added reads: docs/HISTORY.md (DocDriftTests.hs:345, round 45), and caseLineBudget/caseGuiNoInlineStyle directory scans of docs/specs, gui/src-tauri/src, scripts, gui/ui/*.js|*.css (:226-227, :403-416, P8-A). In an sdist tree caseReadmeSync and caseLineBudget would error with does-not-exist and caseGuiNoInlineStyle would pass vacuously with no .js scanned (it does not error as the finder said). cbits is already covered by c-sources. Practical impact is nil: no CI step, README workflow or doc uses sdist and the .cabal is gitignored; this is drift between the stanza's self-declared contract and the test suite.

- 建议修复（trivial）：Extend extra-source-files in package.yaml (hpack accepts globs) with: docs/HISTORY.md, docs/specs/*.md, gui/ui/*.js, gui/ui/*.css, gui/src-tauri/src/*.rs, scripts/*.py (optionally docs/*.md so caseLineBudget's docs scan matches the checkout). Do not add cbits/*.h (no such file; hpack warns on an empty glob). Alternatively, if sdist is explicitly not a supported channel, reword the lines 8-9 comment and REVIEW-LOG-4 #9 to drop the 'all read files are declared' claim.


### A20. [low] scripts/backup_verify.py:50 — Drive wait timeout exits 3 from inside run(), discarding all verification results and never writing --out

- 来源视角：scripts-ci/invariant-contract

- 验证者摘要：In scripts/backup_verify.py, `Drive.ensure()` (:42-55) calls `sys.exit(3)` on --drive-wait timeout. When invoked from the mid-run drop handler in `run()` (:137-138), the SystemExit skips `finish()`, so the ok/sha_bad/size_bad/missing counters and the `bad` list accumulated over the run are discarded and `--out` is never written — unlike the `--max-drops` STOP path (:129-132), which records the unread targets as bad and returns so `--retry` can resume. Users whose drive stays away longer than --drive-wait lose all verification progress and any sha_bad findings from that run and must re-read every target. Startup calls to `ensure()` in the two wrapper scripts are unaffected.

- 建议修复（small）：Make the timeout path inside run() behave like the STOP path: e.g. add a `fatal=True` parameter to `Drive.ensure()` (or a distinct `DriveTimeout(Exception)`), keep `sys.exit(3)` for the startup calls, and in run() call `drive.ensure(fatal=False)` (or catch DriveTimeout); on timeout do `queue.appendleft(t)` (only if it was not already re-queued/recorded), `bad.extend({... 'why': 'not verified (drive did not return)'} for q in queue)`, `queue.clear()`, `break`, and set a flag in the returned dict (e.g. `res['gave_up'] = True`) so `finish()` writes `--out` and then exits 3 instead of 1 when the flag is set.


### A21. [low] scripts/leakscan.py:56 — leakscan.py crashes with an uncaught StopIteration when --extra is the last argument

- 来源视角：scripts-ci/crash-logic, scripts-ci/invariant-contract

- 验证者摘要：scripts/leakscan.py:56 calls `next(it)` with no default when parsing `--extra`; a trailing `--extra` with no value raises an uncaught StopIteration traceback (exit 1) instead of a usage message. Confirmed by running the script. Only reachable from a hand-typed local invocation (CI and the README release command never pass `--extra`), the exit code is fail-closed and the traceback/missing summary line make it visually distinct from a real hit, so the impact is limited to a confusing error and an exit code that a purely script-driven wrapper cannot tell apart from 'leak found'.

- 建议修复（trivial）：Wrap the value read: `try: extra.append(next(it)) except StopIteration: sys.stderr.write("用法：" + __doc__.splitlines()[3] + "\n"); return 2` (or use `next(it, None)` and return 2 with a usage line when None). Optionally also return 2 when `files` is empty so a usage error is distinguishable from a hit (1) and clean (0).


### A22. [low] scripts/verify_backup_dst.py:24 — verify_backup_dst.py ignores plan item status: user-skipped copy items are demanded on disk and reported as missing / sha mismatch

- 来源视角：scripts-ci/crash-logic, scripts-ci/invariant-contract, crosscut/json-contracts

- 验证者摘要：verify_backup_dst.py builds its copy targets and trash-victim list from every copy/quarantine item in the plan regardless of the persisted item status. Items a user skipped with `pm resolve <backup-plan-id> --item N` (status {"s":"skipped"}, group-expanded; the only way a backup plan gets a non-pending status, since backup plans have no barrier and never get NEEDS-DECISION, so the `--keep dst` variant is unreachable) are never executed by Exec (ONotExecuted), yet the script demands their dst with the plan sha and their victim in .pm/trash/<id>/, producing `size … != …` / `sha … != …` / `missing` and `trash victims present N-1/N` bad entries and exit 1 that look like media corruption and recur on every --retry.

- 建议修复（trivial）：In scripts/verify_backup_dst.py restrict both comprehensions to items whose status is pending, e.g. `pend = [it for it in plan["items"] if it.get("status", {}).get("s", "pending") == "pending"]` and build `targets`/`quars` from `pend`; optionally print how many items were excluded as skipped/needs-decision so the count is visible.


### A23. [low] scripts/verify_backup_dst.py:30 — Trash-victim existence check runs with no drive-present guard; after a max-drops STOP it reports victims as absent

- 来源视角：scripts-ci/invariant-contract

- 验证者摘要：verify_backup_dst.py's trash-victim existence check (:29-33) uses bare os.path.isfile with no drive-present guard. After backup_verify.run() exits via the max-drops STOP branch (:129-132 breaks before the :137-138 drive.ensure()), or if the drive drops between/among the isfile calls, every victim reads as absent and the script prints/records 'trash victims present 0/N' as a bad finding. The exit code is already 1 on that path and a --retry redoes the trash check after drive.ensure(), so the effect is a misleading line in stdout and result.json rather than a persistent wrong verdict.

- 建议修复（trivial）：In verify_backup_dst.py, before the trash loop call `drive.ensure()`; after computing `present`, if `not drive.ok()` record `{"why": "trash victims not verified (drive absent)"}` instead of the count (or re-run the loop once after ensure()). Optionally also in backup_verify.run add a `drive.ensure()`-free 'stopped while drive absent' note so callers know the state.


### A24. [low] src/Pm/Album.hs:95 — import --also-album reports sidecars/meta files as '非 jpg → pm convert' (misleading suggestion)

- 来源视角：ingest-album/invariant-contract

- 验证者摘要：`pm import --also-album` (and POST /api/import/plan alsoAlbum) reports every non-jpg staging file routed to 成片 — including .xmp/.acr sidecars, KindMeta files and RAW misplaced under Processed — as `非 jpg 只进成片，不入相册: … （要进相册 → pm convert）`, but `pm convert` rejects all of those (`不是照片条目` / RAW / `不是转换对象`). Only true convertibleExt photos (tif/png/psd/psb/heic) can follow the hint. Cosmetic/misleading line; no plan or data impact.

- 建议修复（trivial）：In src/Pm/Commands.hs:531-532 append `（要进相册 → pm convert）` only when `convertibleExt p` (import Pm.VaultCore.convertibleExt), or in withAlbumForImport filter `toProcessed` to `enKind e == KindPhoto` and (for the hint) convertibleExt; existing tests (arNotJpg == [p3.tif], e2e `非 jpg 只进成片` for t.tif) remain green.


### A25. [low] src/Pm/Album.hs:212 — albumCandidates mislabels a jpg lying directly under 成片\ (event = file name) and offers an un-addable / un-ignorable `pm album add <file>` command

- 来源视角：ingest-album/crash-logic, ingest-album/invariant-contract, tests-sweep/test-quality

- 验证者摘要：A jpg placed directly under 成片\ (no event folder) is listed by `pm album candidates` / GET /api/album/candidates under a bogus event named after the file, and the offered `rel` (`stray.jpg`) is rejected by parseProcessedRel (`至少要 <事件夹>/<文件名> 两级`) in `pm album add`, `pm album ignore` and the GUI 忽略/add-plan actions (exit 2 / HTTP 400). The entry can only be cleared by moving the file into an event folder. Edge case outside the documented layout; no wrong plan or data effect.

- 建议修复（small）：In albumCandidates, require the entry to sit inside an event folder (e.g. `length (splitDirectories (enPath e)) >= 3`) and either drop such files or surface them in a separate `不在事件夹下（先移入 <事件夹>\）` note in runAlbumCandidates/candidatesJson; keep eventOf/hint unchanged. Existing caseCandidates / ServeP8 fixtures all use event folders.


### A26. [low] src/Pm/Backup.hs:36 — Backup discovery collapses a present-but-corrupt/untrusted root-id.json into "drive not mounted, plug it in"

- 来源视角：vault-backup/invariant-contract

- 验证者摘要：Backup-root discovery (discoverAmong/discoverBackupRoots) reads markers through readRootInfo, which folds RootCorrupt and RootUntrusted into Nothing, so a mounted backup drive whose .pm/root-id.json is damaged (or whose .pm is a junction/ACL-blocked) yields zero hits and every consumer (pm backup, pm clean staging, pm apply's bindExecRootWith, recheckCleanPlan, trash-empty three-copy check) reports '备份盘未挂载 … 插上备份盘后重试' or '均不符' instead of naming the corrupt/unreadable marker. Refusal is still fail-closed; only the diagnosis is wrong. (The finder's claim that pm apply already prints '身份损坏' for the backup slot is incorrect — F018 only covers main/vault slots because backup slots come from the same collapsing discovery.)

- 建议修复（small）：Add a state-aware sibling in Pm.Backup (e.g. discoverAmongStates :: Text -> [FilePath] -> IO ([FilePath], [(FilePath, String)]) using readRootState, collecting RootCorrupt/RootUntrusted candidates with their reason while ignoring RootAbsent and role/id mismatches). Have discoverBackupRoots return those alongside hits, and in discoverBackupRoot's zero-hit branch append '；以下卷上的 root-id.json 存在但读不出/损坏: <path>: <why>' when the list is non-empty. bindExecRootWith can feed the same list into its `unreadable` slot list so F018's wording covers the backup slot too. Keep discoverAmong's existing signature for test/PlannerTests.hs:277.


### A27. [low] src/Pm/Backup.hs:46 — Backup discovery joins a hand-editable subpath with `</>`: an absolute subpath makes every drive 'match' and pm refuses with a bogus clone-conflict message

- 来源视角：crosscut/windows-paths

- 验证者摘要：cfgBackupSubpath is joined onto each drive root with filepath's `</>`, which returns the right operand unchanged when it carries a drive letter or leading separator; pm itself always writes a drive-relative value, but a hand-edited absolute (`E:\Photography`) or rooted (`\Photography`) subpath is accepted by loadConfig/checkConfig and makes every present drive probe the same path, so a correctly-identified backup drive is refused with a bogus '多个卷同时匹配…整盘克隆' (or '未挂载') message that points the user at the wrong remedy. Fail-closed, no data risk; misleading message on a misconfiguration path.

- 建议修复（trivial）：In Pm.ConfigEdit.checkConfig add a lexical check on cfgBackupSubpath: reject when `isAbsolute`, `hasDrive`, starts with a path separator, contains ':' or a '..'/'.' component (i.e. `not (null s) ==> relPathOk s`; allow the empty string since `snd (splitDrive "E:\\")` is "" for a drive-root mirror), with a message like '备份 subpath 须为盘内相对路径（如 Photography），不含盘符或前导分隔符 —— 重跑 pm backup init'. Optionally run the same predicate in loadConfig next to checkAbsolute so `pm backup`/`pm status` refuse before discovery.


### A28. [low] src/Pm/BackupCmd.hs:192 — pm backup returns exit 1 ("差异/待处理") when the backup drive cannot be discovered, contradicting §5.1 (2 = error) and the F031 ruling

- 来源视角：vault-backup/invariant-contract

- 验证者摘要：runBackupRun' (src/Pm/BackupCmd.hs:192) maps every discoverBackupRoot failure — backup not registered (literally 'root 未 init'), drive not mounted, and multi-volume identity conflict — to exit code 1, which DESIGN §5.1 reserves for 'has differences / degradation / plan pending'. §5.1 defines these as errors (2), Apply.hs's F031 comment explicitly classifies the identical Left as 2 for undo/doctor/trash --backup, and all sibling precondition failures in the same function exit 2. Within pm backup, 1 already means 'plan saved, not executed' or 'verdict incomplete', so a scripted caller cannot tell 'nothing ran, drive missing' from 'plan pending'. Message text is correct; only the code is wrong, so low severity.

- 建议修复（trivial）：In src/Pm/BackupCmd.hs:192 change `Left msg -> putStrLn msg >> pure 1` to `pure 2` (optionally add a one-line comment citing F031 / DESIGN §5.1). No test or doc pins the current value; no other caller of runBackupRun exists.


### A29. [low] src/Pm/Cli.hs:151 — execPlanRetry heal reports '补记 Done N 条' even when doctor --repair degraded to diagnose-only (lock busy / not writable), and a landed rename is then re-run as CONFLICT

- 来源视角：crosscut/locks-races

- 验证者摘要：executePlanNow'.heal prints '自愈：pm doctor --repair 补记 Done N 条' from the count of C2/R2/Q-DONE-LOST Warn rows, but runDoctorGate silently degrades to diagnose-only (lock busy → I10 Bad, root not writable → I11 Bad) and those Warn rows exist regardless of whether applyRepairs ran, so the message can claim N repairs when zero JDone lines were written. For a landed OpRename whose Done append raised the hiccup, settle then finds no Done and the retry session reports CONFLICT '重命名源不存在' (exit 1, catalog not updated, Intent left dangling) although the rename succeeded. Message/cosmetic plus a confusing retry outcome in a rare coincidence; no data loss.

- 建议修复（trivial）：In `heal` (Cli.hs:149-151) check for a degraded run before counting: if any finding has fRow ∈ ["I10","I11"] (or fSeverity Bad on those rows) print its fDetail as '· 自愈未执行：…' instead of the count; otherwise print the count as now. Optionally, when heal did not run, skip the retry and return Left so the user re-runs after doctor --repair.


### A30. [low] src/Pm/Commands.hs:302 — Write-ahead trash manifest record is never reconciled when the quarantine move fails or never runs (Q2), so pm trash list labels a never-quarantined file '已移出' and doctor's Q2 row does not clear the entry as DESIGN §6.4 specifies

- 来源视角：crosscut/write-primitives, tests-kernel/test-quality

- 验证者摘要：Quarantine writes its trash-manifest record before the move (§6.3 step 1). If the move then fails (JFailed) or the process dies before it (Q2), the record stays forever because the manifest is append-only and neither Exec, doctor nor --repair reconciles it. `pm trash list` renders such a never-quarantined entry as '已移出' (whose in-code meaning is 'purged or moved back by undo'), and DESIGN §6.4 Q2 promises '复核后清除该 manifest 条目' which no code implements; the move-failure case additionally leaves no doctor row at all. Cosmetic/doc drift only: trash empty ignores absent entries and undo does not read the manifest.

- 建议修复（trivial）：Keep the manifest append-only (consistent with DESIGN.md:255/:418). (1) In docs/DESIGN.md §6.4 Q2 replace '复核后清除该 manifest 条目' with the real behaviour: the write-ahead record is left as history and shows as absent in `pm trash list`; add that a move failure with a Failed terminal leaves the same orphan record. (2) In Commands.hs runTrash' change the absent label from '已移出' to a neutral '不在 trash' (and adjust the comment at :301 to mention the never-landed case), optionally consulting the journal for a Done carrying that trashRel to distinguish '已移出' from '未入库（隔离未执行）'.


### A31. [low] src/Pm/Convert.hs:12 — A convert plan's derived source can be deleted by `pm doctor --repair` (DERIVED-STALE) while the plan still has an unresolved item that needs it

- 来源视角：ingest-album/crash-logic

- 验证者摘要：With `pm convert --also-album` on a 成片 source, the 成片 and 相册 plan items share one derived source `.pm\derived\<S>\<stem>.jpg`. Once the 成片 copy lands and catalog writeback records its sha, `scanDerived` classifies the derived file as DERIVED-STALE (sha ∈ catalog) even though the plan's 相册 item (NEEDS-DECISION for an album conflict, or the documented coupled 「先完成成片再 --unskip」 case) still names it as `opSrcAbs`. Any `pm doctor --repair` in that window (manual, or the automatic heal in `execPlanRetry`) unlinks it; the later `pm apply` of that item fails with 「源 stat 失败」 (a `--keep src` quarantine is auto-restored). No data loss; recovery is re-running `pm convert`, but the user gets an unexplained stat failure instead of a pending/kept derived file.

- 建议修复（small）：In `Pm.Doctor` (or `scanDerived` given an extra argument), collect `opSrcAbs` of every `OpCopy` item whose status is `StPending` or `StNeedsDecision` across `listPlans root`, and for any derived file in that set report `DERIVED-PENDING` (「计划 <pid> 仍引用」) and exclude it from `derivedDel` instead of STALE/ORPHAN; keep the existing rule for everything else.


### A32. [low] src/Pm/Convert.hs:242 — Convert reuses albumPlanItems for 成片-target conflicts, so the NEEDS-DECISION reason says 「相册已有同名但内容不同」 for a 成片 conflict

- 来源视角：ingest-album/crash-logic

- 验证者摘要：`convertPlan` builds the 成片-layer items with `albumPlanItems`, whose conflict status text is fixed to 「相册已有同名但内容不同（I5）→ pm resolve --keep src|dst|both」. For a convert whose derived jpg clashes with an existing `成片\<event>\<stem>.jpg` (e.g. the caseE2E clash.png/clash.jpg fixture) the saved plan item therefore says the album has the conflicting file although the conflict is in the 成片 event folder. The suggested resolve action is still right; only the location wording is wrong.

- 建议修复（trivial）：Give `albumPlanItems` (or a small wrapper used by Convert) the why-text as a parameter, and have `convertPlan` pass e.g. 「成片同事件夹已有同名但内容不同（I5）→ pm resolve --keep src|dst|both」 for `mrep`; alternatively post-map `base` in `convertPlan` replacing `StNeedsDecision conflictWhy` with the 成片-specific text.


### A33. [low] src/Pm/Doctor.hs:301 — I7 row on a backup root classifies every pm-backup Copy as 'inbox-origin' (src is always outside the backup root), so the check is vacuous there and the tally misreports

- 来源视角：commands-doctor/invariant-contract

- 验证者摘要：On a backup root every album file was landed by a pm backup OpCopy whose srcAbs is under the main root, which pathAtOrUnder(backupRoot) classifies as 'outside' (Just False); i7Findings therefore counts all of them as inbox-origin, so pm doctor --backup can never surface the main library's I7 violations and its tally reports them as 'inbox 来源 N · 未解释 0'. Only hand-copied foreign album files remain detectable on the backup. Misleading tally / vacuous check, no data effect; the main-root doctor still reports the Warn.

- 建议修复（small）：In i7Findings (or its caller in runDoctor'), read the root's role via readRootInfo; on a Backup root either skip condition ② (report only same-sha-in-成片 vs unexplained, or print a single Info that inbox-origin is not judged on a mirror) or additionally exclude Copy Intents whose opSrcAbs is under the configured main root (cfgMainRoot) from srcsFor, counting them under a separate label such as '主库镜像来源'. Update the DESIGN-COMMANDS.md:590 parenthetical accordingly.


### A34. [low] src/Pm/Doctor.hs:397 — Copy pending classification uses a boolean dst probe, so an unreadable/ACL-denied dst becomes 'C1 Info: no trace' with exit 0

- 来源视角：commands-doctor/crash-logic

- 验证者摘要：classifyPending' probes a pending Copy's dst with boolean doesFileExist (Doctor.hs:397), which returns False on ACL denial (project-verified via F041/withDenyAll), so an Intent whose dst actually landed but is unreadable-by-attributes is classified 'C1 Info: Intent 后无痕迹' with exit 0 instead of a PM-LINK Bad (as the Rename arm does after F033). No repair is wrongly applied, but doctor gives a false all-clear and a rerun then retires the Intent as FAILED while the landed copy stays un-journaled.

- 建议修复（small）：Replace `dstEx <- doesFileExist dstAbs` with `eDst <- userSideExists dstAbs` and add a `Left m -> pure [Finding "PM-LINK" Bad (oid <> ": " <> m <> "，不推导、不修复（需人工核查）") ""]` arm before the existing True/False branches (the True branch already falls back to 'C?' Bad when sha256File throws). Optionally do the same for victimEx in the Quarantine arm (line 474) for consistency.


### A35. [low] src/Pm/Doctor.hs:410 — A pending Copy Intent can never retire once its dst is legitimately re-filled with different content by another plan: doctor then reports C5 Bad forever and --repair emits a quarantine plan for the legitimate file

- 来源视角：commands-doctor/invariant-contract

- 验证者摘要：A Copy Intent left pending by a crash before any tmp write can never be retired if its dst is later legitimately landed with different content by another plan: Exec journals nothing on the I5 conflict / source-changed / source-stat-failed outcomes of a rerun, so opState keeps the oid pending, doctor reports it as C5 Bad (exit 1) on every run, and --repair (including the automatic heal pass in execPlanRetry) generates a doctor-c5-quarantine plan whose victim is the correctly landed newer file. Requires the user to abandon the crashed plan and re-plan the same dst; no data is lost without a further confirmed apply.

- 建议修复（small）：Doctor-side, read-only: in classifyPending' for OpCopy, before emitting C5 check whether a later JDone exists for a different oid whose Intent is an OpCopy with the same foldPath dstRel and opSha == the current dst sha; if so emit an Info row (e.g. 'C5-SUPERSEDED: dst 已由 <oid2> 落位，旧 Intent 作废') that is outside the repair whitelist, and optionally let --repair append a JFailed for the stale oid so it retires. Alternatively, have Exec append JFailed when a rerun of an item whose last journal event is an Intent ends in OConflict at Exec.hs:455/469.


### A36. [low] src/Pm/Doctor.hs:542 — DESIGN §6.4 row C3 (journal tail lost, dst intact → 补记 Done) is not implemented; the code's "C3" tag means 'Done without Intent (skip)', and the test named "C3 语义" pins zero findings

- 来源视角：commands-doctor/invariant-contract, tests-kernel/test-quality

- 验证者摘要：DESIGN §6.4 row C3 (dst intact, sha==expected, no journal record -> attribute as completed copy and append Done; DESIGN.md:355/365/599, DESIGN-COMMANDS.md:293) has no implementation: doctor derives everything from Intent/Done records and never sees a landed file with no record, and --repair never appends such a Done. The 'C3' finding tag actually printed by Doctor.hs:542 means 'Done without a matching Intent, skipped', so a user cross-checking doctor output against the matrix reads the wrong row. KernelTests.hs:416 '(C3 语义)' only asserts no Warn rows and does not test the documented 补记. Practical impact is small because I4's Intent barrier makes the documented C3 state reachable only through hardware that lies about flush.

- 建议修复（small）：Documentation/label fix: rename the Doctor.hs:542 tag from 'C3' to a distinct tag (e.g. 'DONE-ORPHAN'), and rewrite the DESIGN.md C3 row (and the references at DESIGN.md:365/599, DESIGN-COMMANDS.md:293, the KernelTests.hs:416 test name) to state the actual contract: a copy with no journal record is not reconcilable by doctor (the Intent barrier makes that state a lying-flush case caught by C4 / --deep / pm scan), or, if the promised behaviour is wanted, implement it by reading stored plan files for OpCopy items with no journal record whose dst sha matches and reporting them (Info, and 补记 Done only under --repair).


### A37. [low] src/Pm/Doctor.hs:587 — Legitimately purged trash payloads are reported as C4 'Done target missing' when no CleanShutdown follows the Done

- 来源视角：commands-doctor/crash-logic

- 验证者摘要：The C4 re-verification window is 'every Done since the last JCleanShutdown', but JCleanShutdown is written only at the end of Pm.Exec.execPlan. A Quarantine Done appended by a standalone `pm doctor --repair` (Q-DONE-LOST), or left by a crashed batch that is never re-run, stays in the window indefinitely. `pm trash empty` unlinks those trash payloads without touching the journal, so the next `pm doctor` reports each purged item as `C4 Bad: Done 记录的目标不存在 … 重新生成计划` and exits 1 until some unrelated plan execution on that root writes a CleanShutdown. The 1.1.2 execPlanRetry heal path is unaffected (it re-enters execPlan, which writes CleanShutdown even for an empty todo). Misleading message on an edge path; nothing on disk is affected.

- 建议修复（small）：Minimal: in checkTrashTarget (Doctor.hs:585-587) change the PmStateMissing wording for trash targets to say the payload is absent and may have been purged by `pm trash empty` (drop the '重新生成计划' advice), and/or downgrade it to Warn when the manifest still holds a record for that trashRel. Cleaner: have `pm trash empty` (inside its root lock, after a fully successful purgeLoop) or `doctor --repair` (after a pass whose window verified with zero Bad rows) append a JCleanShutdown so verified/purged Dones leave the window — but that widens the set of CleanShutdown writers and should be reflected in DESIGN §6.4.


### A38. [low] src/Pm/Doctor.hs:698 — applyRepairs reports repairs via bare putStrLn, so the automatic heal inside pm serve's apply endpoint loses them

- 来源视角：commands-doctor/invariant-contract

- 验证者摘要：applyRepairs reports everything it does (补记 Done, orphan-tmp/derived deletion and its failures, C5 quarantine-plan generation, skips) via bare putStrLn and returns no Findings; the 1.1.2 self-heal in Pm.Cli.executePlanNow' only forwards a count of C2/R2/Q-DONE-LOST Warn rows to the sink (a count taken from the diagnosis, not from what was actually appended). Under `pm ui` serve's stdout is redirected to NUL after the announce line, so a GUI-initiated apply that recovers from a drive drop can generate a doctor-c5-quarantine plan or delete/skip pm-owned files with no trace in the JSON log; the doctor's Bad rows from that pass are also not surfaced. CLI users see the lines; GUI users do not — a producer/consumer gap contrary to the cluster-C sink discipline. No data effect.

- 建议修复（small）：Make applyRepairs return its action lines (e.g. `IO [Finding]` with an Info row per action such as fRow "REPAIR", or take a `String -> IO ()` sink) and have runDoctor' include them in the returned findings; then heal in Cli.hs forwards those rows (and any Bad rows) through `sink . renderFinding` instead of a synthesized count. runDoctor/runDoctorWith signatures can stay unchanged if the Finding-list route is used; Main.hs already prints all findings via renderFinding, so CLI output remains equivalent.


### A39. [low] src/Pm/Exec.hs:491 — Copy: second tmp confinement check failing after JIntent was journaled returns OConflict without a terminal JFailed (dangling Intent; doctor then reports a bogus C1 'interrupted')

- 来源视角：kernel-exec/crash-logic, tests-guards/test-quality

- 验证者摘要：execCopy' (src/Pm/Exec.hs:491-493) is the only abort arm executed after `JIntent` was journaled that returns without a terminal: when the post-mkdir `confinedTmp` re-check yields Nothing (NameSurrogate, or ProbeUnknown from a transient GetFileAttributes error such as a removable-drive hiccup) it returns `escapeOutcome` (OConflict) with no `JFailed`, and execPlan' then appends `JCleanShutdown`. The oid stays 'pending' in the journal: `pm doctor` reports a C1 Info line '写 tmp 前中断，重跑原计划即可' for a session that ended cleanly (until the same plan is rerun), and planExecs counts the item as neither done nor failed. Every sibling post-Intent failure arm (execCopyTmp/execCopyLand/execRename'/execQuarantine') writes JFailed, and DESIGN §6.1 step 7.5 / the Exec.hs:546-551 comment reserve 'Intent 无终态' for process death. No data-safety impact (nothing was written, tmp not created, recovery advice still valid); the pinning test caseExecTmpSecondCheck does not assert the journal.

- 建议修复（trivial）：In execCopy' replace the `Nothing -> pure escapeOutcome` arm of `case mTmp2 of` (Exec.hs:492-493) with: `Nothing -> do { tf <- getCurrentTime; jAppend j Barrier (JFailed oid "tmp 落位点建目录后二次限域失败" tf); pure escapeOutcome }` (same shape as execCopyTmp:507-510). Optionally distinguish ProbeUnknown wording, but not required. Extend test/PathGuardTests.hs caseExecTmpSecondCheck to `readJournal root` and assert a `JFailed` for `opId pid 0` follows the `JIntent` (and that doctor reports no C1 for it).


### A40. [low] src/Pm/ExecTypes.hs:119 — updateCatalog never re-adds the entry restored by `pm undo` of a Quarantine (rename from .pm/trash), leaving the catalog silently missing a file that is back in the library

- 来源视角：kernel-exec/invariant-contract

- 验证者摘要：After `pm undo` of a Quarantine is applied, the reverse op is `OpRename .pm\trash\<pid>\<victim> -> <victim>`; execRename returns `ODone Nothing Nothing Nothing` and updateCatalog's OpRename branch only re-keys entries under `old`, which never exist for a `.pm\trash` prefix. The victim's catalog entry (deleted when the quarantine landed) is therefore never restored, so the saved catalog silently omits a file that is back in the library. The index is a rebuildable cache and the staging/main freshness gates later block import/backup/status with `…不一致（新增 1…）→ 先 pm scan`, so no data is at risk, but the apply prints only DONE with no hint that a rescan is now required, and the in-session rollback path (Exec.hs:179-181) shows the intended contract is that a restored victim stays indexed.

- 建议修复（small）：In updateCatalog's OpRename branch, when `isTrashSrcRel old` and the op fingerprint is `FpFileSha sha` and the outcome carries a dst stat, insert an Entry for `new` (same shape as the OpCopy branch); have execRename stat the landed target after the move and return `ODone Nothing (Just st) Nothing` (Pm.Removable's journal-based reconstruction of rename Done must produce the same shape, or fall back to a stat there too). Cheaper alternative: after a successful apply of a plan whose items include a rename from `.pm\trash`, print `索引未含复位条目 → pm scan` from writeBackCatalog.


### A41. [low] src/Pm/GitGuard.hs:102 — I11 guard (pmIgnoreGuard) does not skip a UTF-8 BOM in .gitignore, so a BOM'd file whose first line is `.pm/` is rejected as '缺 `.pm/` 行' although git honours it

- 来源视角：win-fs/crash-logic, win-fs/invariant-contract, tests-guards/test-quality

- 验证者摘要：pmIgnoreGuard (src/Pm/GitGuard.hs:100-108) does not strip a leading UTF-8 BOM from .gitignore, so a file whose first (or only) line is `.pm/` written with a BOM (Notepad 'UTF-8 with BOM', PowerShell 5.1 Set-Content/Out-File -Encoding UTF8) is rejected with '缺 `.pm/` 行' although git (skip_utf8_bom in dir.c) ignores `.pm/` for that file. The refusal is on the safe (fail-closed) side, so I11 is not violated; the defect is the false diagnostic ('the line is missing') that contradicts what the user sees and the DESIGN §2 I11 claim of character-level alignment with git 2.52. Workaround is trivial (append a second `.pm/` line or re-save without BOM), so impact is low.

- 建议修复（trivial）：In pmIgnoreGuard, drop one leading U+FEFF before splitting: `let txt = TE.decodeUtf8Lenient raw; body = fromMaybe txt (T.stripPrefix "\xFEFF" txt); ls = map norm (T.lines body)` (mirrors git's skip_utf8_bom, which only skips the BOM at the very start of the file, and stays a strict subset of git's accept set). Add a GuardTests case that writes BS.pack [0xEF,0xBB,0xBF] <> ".pm/\r\n" next to a `.git` dir and asserts Right (), plus a case that a BOM in the middle of the file (`_site/\n\xFEFF.pm/\n`) is still rejected. Alternatively, if the maintainers prefer to keep rejecting, change the message to say a BOM/non-ASCII prefix was found rather than '缺 `.pm/` 行'.


### A42. [low] src/Pm/Ingest.hs:168 — runTwoPlans reports 'unfinished items' when the main plan was refused outright (lock busy / root mismatch)

- 来源视角：ingest-album/invariant-contract

- 验证者摘要：In runTwoPlans (src/Pm/Ingest.hs:168-170) a main plan whose execution was refused outright by the kernel (lock busy I10, root-id mismatch, .pm untrusted, plan validation, drive-retry abort) arrives as `PrRun 2 []` (Cli.hs:184) and is reported with the same text as a plan that ran and left CONFLICT/FAILED/NEEDS-DECISION items — '主库（相册）那份有未完成项…pm resolve 处理后重跑本命令' — right after the kernel already printed the real reason. The exit code (2) and the I7 gate (vault plan not executed) are correct; only the guidance is misleading (pm resolve has nothing to resolve; the plan is on disk and just needs pm apply/rerun once the lock is free).

- 建议修复（trivial）：Add a dedicated guard before `otherwise` in Ingest.hs:153-170, e.g. `PrRun c1 [] -> do putStrLn "主库（相册）那份未执行（执行被拒，原因见上一行）：vault 那份不执行（I7：相册在前）；处理后重跑本命令或 pm apply <主库计划 id>"; pure (max c1 1)`. Alternatively give PlanRun a distinct constructor (e.g. PrExecRefused String) returned from savePlanAndMaybeRunTo when executePlanNowWith yields (2, []), with planRunCode = 2 and planIdOf = Just pid, and handle it in runTwoPlans and Vault.hs:615 (`_ -> pure ()` already covers it).


### A43. [low] src/Pm/Op.hs:220 — isTrashSrcRel admits `.pm/trash` itself and `.pm/trash/manifest.ndjson` as rename sources, so a hand-edited plan can move pm's own trash state into user data

- 来源视角：kernel-exec/crash-logic, tests-guards/test-quality

- 验证者摘要：isTrashSrcRel (Op.hs:220) only checks the first two components, so opPathsOk admits OpRename sources `.pm/trash` (with FpDir) and `.pm/trash/manifest.ndjson` (with FpFileSha) even though the documented contract (Op.hs:215-231) allows only quarantined payloads (`.pm/trash/<pid>[~displaced-N]/<victim>`, depth >= 4) as rename sources. validatePlan/loadPlan/execItem all defer to opPathsOk and execRename resolves such an old-path with plain resolveUnder, so a hand-edited plan run through `pm apply` moves pm's write-ahead manifest (or the whole quarantine directory) into user data; afterwards every trash payload is unregistered (doctor Q1, `pm trash empty` finds nothing purgeable) and `pm undo` refuses the reversal because `.pm/trash/...` is not allowed as a rename target. No bytes are lost and recovery is manual, so impact is low, but it is a validation gap relative to the documented .pm exception.

- 建议修复（small）：Tighten the predicate to the shape every producer actually generates: `isTrashSrcRel p = relPathOk p && length comps >= 4 && map normComp (take 2 comps) == map normComp [".pm", pmSubTrash] where comps = splitDirectories p` (optionally also require the third component to parse via opIdParts / isValidPlanId-with-suffix). Add PathGuardTests cases asserting `opPathsOk (OpRename ".pm/trash" "x" (FpDir "aa")) == False` and `opPathsOk (OpRename (".pm" </> "trash" </> "manifest.ndjson") "m.txt" (FpFileSha "aa")) == False`, while keeping the existing depth-4 positives.


### A44. [low] src/Pm/Plan.hs:433 — deletePlanAnyRoot reports the vault root's 'plan does not exist' instead of the main root's real failure

- 来源视角：commands-doctor/crash-logic

- 验证者摘要：deletePlanAnyRoot (Plan.hs:429-433) drops the main root's Left and keeps only the last root's message, so when a vault is configured a real deletion failure on the main library (handle delete refused, untrusted .pm, resolveUnder failure) is reported to `pm plan rm` (exit 2) and to POST /api/plan/delete (404) as "计划不存在: <vault>/.pm/plans/<id>.json", hiding the true cause; loadPlanAnyRoot in Apply.hs already preserves the main-root error, so the two helpers are inconsistent.

- 建议修复（small）：In deletePlanAnyRoot, distinguish absent from failed: only continue to the next root when the Left is the not-found case (e.g. have deletePlan return a small sum type or check the message prefix "计划不存在"), otherwise return that root's error immediately; when every root reports not-found, return the existing aggregate message. Alternatively collect all Lefts and join them with "；" in the final message.


### A45. [low] src/Pm/Scan.hs:131 — MAX_PATH pre-check (240) is applied to source paths only; derived .pm/trash and .pm/tmp paths are up to 33+ chars longer and can exceed 260 for sources that passed the gate

- 来源视角：crosscut/windows-paths

- 验证者摘要：The ≥240 pre-check (Scan.hs:131) only covers scanned source paths; quarantine targets (`.pm\trash\<22-char pid>\<victimRel>`, +34 chars) and copy tmp names (`.pm\tmp\<pid>\<ix>-<name>`) are never length-checked and pm's Win32 rename/create calls are not long-path aware, so a 226–239-char source file that passes the gate cannot be quarantined: `createDirectoryIfMissing` (directory furnishes `\\?\`) succeeds but `pm_rename_by_handle` fails and the item is JFailed/OFailed '隔離移動失敗 … rename 失败（Win32 错误码 …，183=目标已存在）' on every rerun. The tmp-copy escape is a NoSuchThing IOException (judged Deterministic by Removable, not a Hiccup retry) and falls under the documented write-port process-death semantics. Loud, no data loss, but contradicts the 'refuse early at plan time' intent of DESIGN.md:214/§14.

- 建议修复（small）：Either lower `maxPathLen` so that abs' + 37 < 260 (i.e. 223), or add a plan-time validation in Pm.Plan/validatePlan that computes `length (root </> ".pm" </> "trash" </> T.unpack pid </> victimRel)` and the tmp name for Copy items and rejects the plan with a clear '路径过长' message; optionally special-case the Win32 error in moveBoundNoReplace's message (drop the '183=目标已存在' hint when the code is 3/206).


### A46. [low] src/Pm/Scan.hs:347 — scanRoot drops the previous catalog entry of any enumerated file whose stat or hash fails, collapsing "cannot determine" into "absent" for per-file failures

- 来源视角：scan-sort/invariant-contract

- 验证者摘要：scanRoot keeps old entries only for unenumerated subtrees (`unknown` from walk-level `uncovered`); an enumerated file whose statSnap or sha256File throws (sharing violation, media read error — an ACL deny(F) is actually carried because the link probe fails first) contributes nothing to `entries`, so its previous catalog entry disappears from the unconditionally saved snapshot and from srCarried. This collapses 'could not read' into 'not present' for per-file failures, inconsistent with sweepCounts' per-file '错误口不算消失' rule and the F040 subtree rule; effects are a misleading '新增' in pm status once readable again, silent exclusion from doctor --deep/dedupe/versions, and rotation-out after three failing scans. Volatile files are documented as intentionally not indexed and are not part of this defect.

- 建议修复（small）：In scanRoot, treat `statErrs` and `hashErrs` paths as '查不出': `unknown = Map.filterWithKey (\k _ -> coversKey uncovered k || k `Set.member` failedKeys) oldEntries` (with failedKeys = stat-failed ∪ hash-exception rels, excluding volatiles), count them in srCarried, and add a test seeded with an old catalog where sha256File fails for one file (e.g. a handle opened with FILE_SHARE_NONE) asserting the entry survives.


### A47. [low] src/Pm/Serve.hs:394 — GET /api/plans and POST /api/plans/prune hit GHC's in-process single-writer file lock while POST /api/apply is running: journal.ndjson reported as untrusted ('人工核查') and every plan as 未执行

- 来源视角：crosscut/write-primitives, crosscut/locks-races

- 验证者摘要：While POST /api/apply is executing, the same serve process holds `.pm/journal.ndjson` open in ReadWriteMode (withJournal across execItems). GHC's in-process single-writer file lock makes any concurrent GET /api/plans or POST /api/plans/prune fail in readPmState with ResourceBusy 'file is locked', which is reported as「无法可信读取（…）——人工核查」and folds the execution map to empty, so all plans (including previously executed ones) are labelled 未执行 and prune deletes nothing until the apply completes. Benign and self-healing, but the wording tells the user to investigate a non-problem.

- 建议修复（small）：Two trivial layers: (1) in Config.hs readPmState add a branch `| isAlreadyInUseError e -> Left (path <> " 正被本进程的另一操作打开（计划执行中？），稍后重试")` so the ResourceBusy case is worded as a transient rather than 人工核查 (still Left, still fail-closed); (2) in the /api/plans and /api/plans/prune handlers, `tryReadMVar (seApplyLock env)`; when it is Nothing, skip readJournal and return errors [("journal","计划正在执行中（POST /api/apply），执行态待完成后刷新")] so the GUI shows an explicit reason instead of a manual-check warning.


### A48. [low] src/Pm/Serve.hs:404 — GET /api/plans gates stale detection on BOTH roots' journal warnings while prune/CLI gate per root

- 来源视角：serve-api/crash-logic

- 验证者摘要：GET /api/plans disables the stale-draft judgement for plans of BOTH roots whenever EITHER journal has a warning (`null mwarns && null vwarns`), whereas `pm plan list` and `prunePlans` gate per root as the docs (DESIGN-COMMANDS §1.1.3, DESIGN-GUI §11, README) specify. With a warning in only one journal, the GUI shows a stale draft of the other root as 未执行 with an 执行 button while the CLI says 已失效 and the GUI's own 清理已执行/失效 deletes it.

- 建议修复（trivial）：In the /api/plans handler compute per root like runPlanList: build `(ps, mwarns, planExecs mes)` and `(vps, vwarns, planExecs ves)` separately and use each root's own warnings/runs for its plans, e.g. `staleOf warns p mr = if null warns then planStale p mr else pure False` applied with `mwarns` to `ps` and `vwarns` to `vps` (the per-root `runs` map also matches the CLI's fold).


### A49. [low] src/Pm/ServeAi.hs:107 — classify resolves album names by bare file name over the whole 相册 subtree, so a same-named file in an album sub-directory shadows the flat album photo sent to the model

- 来源视角：serve-api/crash-logic

- 验证者摘要：classify (ServeAi.hs:106-110) resolves the requested flat album names by `takeFileName` over every KindPhoto catalog entry whose first path component is `相册`, including files in album sub-directories that the vault/GUI flat semantics ignore; `Map.fromList` keeps the last entry in key order, so e.g. `相册\old\IMG_0001.jpg` ('o' > 'I') shadows `相册\IMG_0001.jpg` and its path is what is handed to `claude -p`, while the returned suggestion is prefilled on (and, if saved, recorded for) the flat photo. Which file wins depends only on code-point order of the sub-directory name versus the file name.

- 建议修复（trivial）：Look the name up by its exact flat catalog key instead of by basename: replace the `byName` construction with `byName = Map.fromList [(n, e) | n <- names, Just e <- [Map.lookup (albumTop </> n) (catEntries cat)], enKind e == KindPhoto]` (import `(</>)` from System.FilePath; `catEntries` is keyed by `enPath` with native separators, see Types.hs:187 `entryMap`). All downstream checks (`Map.member n byName`, `resolveUnder root (enPath e)`) stay unchanged and the existing test (`a.jpg` in flat 相册) still passes.


### A50. [low] src/Pm/ServeAi.hs:184 — AI coordinate suggestions re-rendered with Haskell `show` emit scientific notation (e.g. "-1.5e-3") for |value| < 0.1, which is then prefilled and stored as the note's coordinates text

- 来源视角：crosscut/json-contracts

- 验证者摘要：normItem (ServeAi.hs:184) canonicalises the model's coordinates with Haskell `show`, which for any component with 0 < |v| < 0.1 produces exponent notation (`0.0523` → `5.23e-2`). That text is prefilled in the GUI, passes `noteFieldErrors` (TR.double accepts exponents) and is stored verbatim in `.pm/vault-notes.json` and exported by `pm vault notes --json`, contradicting the documented plain-decimal `<lat>, <lng>` form (DESIGN-P8 §21.1, README:209, and the prompt's own '十进制'). Numerically correct, cosmetically/contractually wrong; only affects coordinates within 0.1° of the equator or prime meridian.

- 建议修复（trivial）：Render with fixed-point formatting instead of `show`: `import Numeric (showFFloat)` and use `T.pack (showFFloat Nothing la "" <> ", " <> showFFloat Nothing ln "")` at ServeAi.hs:184 (`showFFloat Nothing 47.5 ""` = "47.5", so the existing test value is unchanged; `showFFloat Nothing 0.0523 ""` = "0.0523").


### A51. [low] src/Pm/ServeAlbum.hs:74 — POST /api/album/ignore reports a busy main-root lock as 400 '忽略清单未写入' instead of 409, unlike every other .pm record endpoint

- 来源视角：serve-api/crash-logic

- 验证者摘要：POST /api/album/ignore collapses every non-success outcome of runAlbumIgnoreTo (parse errors, requireMain failure, missing catalog, unreadable/unwritable ignore list, and main-root .pm/lock busy) into exit 2 → HTTP 400 "忽略清单未写入". Concretely, while POST /api/apply is executing (Exec.hs:114 holds the main-root lock under seApplyLock, which does not interlock with seVaultLock), a 忽略 click returns 400 with the lock-busy line in details, whereas the sibling record endpoints (/api/vault/hold, /api/vault/notes via recordPost, /api/config) return 409 for the same transient condition as DESIGN-COMMANDS:393 / DESIGN-GUI:199 describe. The GUI only displays the message (which already says 稍后重试), so impact is an API status-class inconsistency, not a wrong user action.

- 建议修复（small）：Make lock-busy distinguishable: in Pm.Album have runAlbumIgnoreTo return a distinct code for `withRootLock` Nothing (e.g. 4, matching withVaultTxn's convention), keep `runAlbumIgnore` (CLI wrapper) mapping 4 → 2 so the documented CLI exit 2 is preserved, and in ServeAlbum.hs map `Right 4 -> err status409 <lock message>` before the `Right _ -> status400` catch-all. Optionally also map requireMain/catalog-missing → 404 and writeIgnores failure → 403 to match recordPost, and add a ServeP8Tests case that pre-holds .pm/lock and asserts 409.


### A52. [low] src/Pm/ServeVault.hs:131 — DRIFT-only push-plan response tells the GUI user to manually git add/commit/push although nothing will land

- 来源视角：tests-serve-vault/test-quality

- 验证者摘要：`POST /api/vault/push-plan` always renders `gitSteps` from `planCategories plan`, and for a DRIFT-only (pure adjudication) plan that list is `[]`, so `gitStepsLines` falls through to `vaultCommands`' `Left "没有要 add 的类目"` and emits the manual-fallback lines ("（无法安全生成命令：没有要 add 的类目）" / "请在 <vault> 里手动：git add <类目…> → git commit → git push"). The GUI (vault.js:258) shows this under "执行后的 git 步骤" because the unconditional header makes `gitSteps` never empty. This contradicts the documented contract that git steps are only given when something lands (DESIGN-COMMANDS.md:364-367, :491; F029) and the CLI/afterApply guards (Apply.hs:197, Vault.hs:616). Misleading message only; no invariant is violated.

- 建议修复（trivial）：In src/Pm/ServeVault.hs:131 emit an empty list when the preview has no categories, e.g. `"gitSteps" .= (let cs = planCategories plan in if null cs then [] else gitStepsLines cfg (plRootPath plan) (plId plan) cs)`; vault.js:258 already handles an empty array. Optionally add an assertion to caseServePushPlanDrift that `gitSteps` is `[]`.


### A53. [low] src/Pm/SortSource.hs:205 — hardErrors treats the designed 'pm 状态目录…不进入' skip as an enumeration failure → exit code 0→1 and '未能枚举' warning for a fully enumerated source

- 来源视角：scan-sort/invariant-contract, tests-sweep/test-quality, tests-guards/test-quality

- 验证者摘要：When the sort source is (or contains) a pm root, listTreeCov records the deliberate non-entry of the directory holding root-id.json as an sfErrors row (Scan.hs:172) with an empty uncovered component, but SortSource.hardErrors (line 205) only exempts reparseSkipNote, so foldHardErrors lifts a clean exit 0 to 1 and prints '⚠ 源里有 1 处未能枚举…退出码 1'. The survey form (`pm sort <src>`, Sort.hs:437) therefore always exits 1 for a pm-root source, and the plan form (Sort.hs:563) turns '✓ 没有需要归位的新照片' / a fully-executed --go run into exit 1, plus the item is listed under the misleading bucket title 'reparse point / 路径过长 / 读不到'. This contradicts DESIGN-COMMANDS.md:492 (exit 1 only for subtrees that could not be enumerated; design-internal skips stay 0) and the listTreeCov doc comment (Scan.hs:101-104) that classifies the pm-state-dir skip as deterministic, not 'unenumerated'. The ProbeUnknown variant (Scan.hs:171, root-id.json existence unknown) is correctly a hard error and must stay one. GUI impact is limited to the spurious ⚠ line in the plan log (survey endpoint bypasses foldHardErrors; app.js keys on planId).

- 建议修复（small）：In Pm/Scan.hs define the literal once, e.g. `pmStateDirSkipNote :: String; pmStateDirSkipNote = "pm 状态目录（内含 root-id.json），源遍历不进入"`, use it at Scan.hs:172 and export it; in Pm/SortSource.hs change `hardErrors = filter ((/= reparseSkipNote) . snd)` to `hardErrors = filter ((`notElem` [reparseSkipNote, pmStateDirSkipNote]) . snd)` (leave the ProbeUnknown '存在性查不出' row as hard). Optionally extend the bucket title at Sort.hs:295 to mention 'pm 状态目录'. Add to caseSortErrorsExit a fixture writing `src\.pm\root-id.json` and asserting both forms still return 0, and extend the unit assertion at SortGuardTests.hs:72. (A more principled alternative is to have listSource call listTreeCov and derive hard errors from the uncovered list, but that is a larger change.)


### A54. [low] src/Pm/Status.hs:279 — stagingEventOf mis-parses the documented `To-Be-Sync'd\Raw\<year>\<event>` layout (reports the year as the event) and ignores files directly under Raw/Processed

- 来源视角：commands-doctor/invariant-contract, commands-doctor/crash-logic

- 验证者摘要：Pm.Status.stagingEventOf derives the staging-event list from a fixed component position (3rd component after To-Be-Sync'd\<Raw|Processed>) and requires ≥4 components, while Pm.Import.route accepts both `Raw\<event>` and `Raw\<year>\<event>` layouts (documented in DESIGN-COMMANDS.md:119-122, tested in PlannerTests). For the year layout every event under one year collapses into a single pseudo-event named after the year ('1 个事件未归档: ["2026"]' in pm status, /api/status stagingEvents, and the GUI archive/home cards), and staging files with fewer than 4 components (e.g. To-Be-Sync'd\Raw\x.arw) are counted by stagingArchivedSummary but produce no event, so status prints no staging line and can exit 0 while pm import reports them as 无法识别 and exits 1. Exit code and the '→ pm import' hint are correct in the year-layout case, so the impact is a wrong count/name (cosmetic) plus a silent edge case.

- 建议修复（small）：Make stagingEventOf mirror Import's layout rules: `(top : "Raw" : y : event : _ : _) | top == stagingTop, isYearDir y -> Just event` before the existing clause (export isYearDir from Pm.Import or inline `length y == 4 && all isDigit y`); optionally map any other `To-Be-Sync'd\*` entry outside 待修改 that yields no event to a sentinel such as "(无法识别)" so status still prints a staging line / exit 1 for shapes import will reject. No change to stagingArchivedSummary or the JSON contract needed.


### A55. [low] src/Pm/Vault.hs:602 — pm vault push no-item hint counts UNPUSHABLE .png as NEW to push (N4 same-shape regression)

- 来源视角：vault-backup/crash-logic, vault-backup/invariant-contract

- 验证者摘要：In the no-plan branch of `runVaultPush` (Vault.hs:600-602) the "→ N 个 NEW 待分类：pm vault push --category …" hint is gated and counted with `newActive` instead of `newAssignable`, so an album whose only NEW files are .png (or a jpg/png mix) is told to push N files with --category, and following that advice for a .png is rejected by `checkAssignments` (:643) with exit 2. This is the same N4 wording contradiction that was fixed in `renderHuman` (:441) but missed here; the exit code (`hasDiffR`) is unaffected and correct.

- 建议修复（trivial）：At Vault.hs:600-602 replace both uses of `newActive r` with `newAssignable r` (guard and count); optionally add a sibling line pointing UNPUSHABLE NEW items to `pm convert`. Extend caseUnstablePushExit or add a case with a .png-only album asserting the hint line is absent.


### A56. [low] src/Pm/Vault.hs:613 — Direct `pm vault push --apply` never refreshes the main-side vault cache, so `pm status` keeps showing the pushed photos as NEW

- 来源视角：vault-backup/crash-logic

- 验证者摘要：`pm vault push … --apply` executes the plan through `savePlanAndMaybeRun'` and returns without re-running `computeVault`, so `.pm/vault-cache/meta.json` keeps the pre-push counts written at the start of the command; `pm status` then shows a ⚠ vault lag (NEW N) that was just pushed, whereas executing the identical plan via `pm apply <id>` / the GUI goes through `afterApply` which refreshes the cache. Cosmetic/misleading only; `pm vault status` corrects it.

- 建议修复（small）：In runVaultPush (Vault.hs:611-618), after `pr <- runPlan plan`, when `pr` is `PrRun _ rs` with non-null `landedItems rs` (or unconditionally on PrRun) call `_ <- computeVault True cfg` to rewrite the cache, mirroring Apply.afterApply; or have runVaultPush call afterApply's vault-push branch. Add a test that reads readVaultCacheMeta after `runVaultPush (execNow cfg) … --apply` and asserts vmNew == 0.


### A57. [low] src/Pm/Vault.hs:661 — DRIFT items are turned into vault Copy ops without the jpg/jpeg write-path gate, so a .png can be pushed into a vault category

- 来源视角：vault-backup/crash-logic

- 验证者摘要：`vaultPushItems` turns every DRIFT entry into a NEEDS-DECISION `OpCopy` without applying `pushableExt`, so when the vault already holds `<cat>/x.png` and the album's `x.png` differs, `pm vault push` (CLI, and POST /api/vault/push-plan with empty assignments) emits a plan that `pm resolve --keep src` + apply will execute, copying a .png through the push write path that the module header and DESIGN-COMMANDS §10.1/§10.2 say rejects non-jpg; `pm vault status` simultaneously labels that file UNPUSHABLE("写路径拒收") and DRIFT("→ pm vault push 生成裁决计划"). Edge path (needs a pre-existing png in vault), no data loss.

- 建议修复（small）：Filter `driftItems` with `pushableExt n` (Vault.hs:660-665) and report the skipped non-jpg DRIFT as a "只报告" line (like RENAME/MISSING) pointing to `pm convert`; in ServeVault.hs:104 change the empty-assignment admission to check `any (pushableExt . fst4) (vdDrift …)` (or `not (null (vaultPushItems r []))`) so a png-only DRIFT does not yield an empty plan; add a VaultTests case with a vault-side .png DRIFT asserting no plan item is generated.


### A58. [low] test/ConvertTests.hs:130 — caseRefusals unconditionally unsetEnv "PM_PYTHON" → clobbers a user-supplied PM_PYTHON before caseE2E/caseDerivedGuards, which need python

- 来源视角：tests-sweep/test-quality

- 验证者摘要：test/ConvertTests.hs:130 and :254 wrap PM_PYTHON overrides in `bracket_ (setEnv …) (unsetEnv …)`, which deletes rather than restores any PM_PYTHON the person running the suite had set. Because Spec.hs runs the suite serially in one process (NumThreads 1) and caseRefusals precedes caseE2E/caseDerivedGuards, a local run that supplies python only via PM_PYTHON (the route the module header itself advertises) sees caseE2E and caseDerivedGuards fail with '找不到 python（PATH 上没有）' after caseRefusals succeeds. CI is unaffected (python is on PATH there, PM_PYTHON unset); the defect is an order-dependent spurious failure in local runs, not a hidden production bug.

- 建议修复（trivial）：At both sites capture the old value and restore it, mirroring test/GuardTests.hs:636-641: `old <- lookupEnv "PM_PYTHON"` then release with `maybe (unsetEnv "PM_PYTHON") (setEnv "PM_PYTHON") old` (and the same for PM_CONVERT_TIMEOUT at :254). Optionally factor a small `withEnv :: String -> String -> IO a -> IO a` helper in TestUtil and reuse it for the PM_CLAUDE_EXE/PM_SUGGEST_TIMEOUT brackets in ServeP8Tests.hs:287/336/354.


### A59. [low] test/DocDriftTests.hs:220 — innerHTML sentinel only checks the first two characters after '=' → `el.innerHTML = "" + expr` passes the '只允许赋空串' guard

- 来源视角：tests-sweep/test-quality

- 验证者摘要：caseGuiNoInlineStyle's `innerBad` (test/DocDriftTests.hs:220) accepts any innerHTML assignment whose right-hand side merely *starts* with `""`, so `el.innerHTML = "" + expr;` or `"".concat(expr)` would pass the '只允许赋空串' assertion while injecting server text as HTML. All current gui/ui/*.js uses are exactly `innerHTML = "";`, so this is a sentinel gap rather than a live defect, but it contradicts the documented F090 premise (REVIEW-LOG.md:196-199/:247, DESIGN-GUI.md:157-160) that innerHTML is only ever assigned the empty string.

- 建议修复（trivial）：Tighten the sentinel to require the statement to end right after the empty string, e.g. change `take 2 (dropWhile isSpace (drop 1 r)) == "\"\""` to `take 3 (dropWhile isSpace (drop 1 r)) == "\"\";"` (all 20 existing uses are `= "";`, so the test stays green). Optionally add a mutation row (`innerHTML = "" + x`) to the REVIEW-LOG mutation table.
