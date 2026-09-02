{-# LANGUAGE OverloadedStrings #-}

-- | P3b-14：codex 十一轮复审的收口用例（从 PathGuardTests 拆出，该文件触及
-- 750 行预算）。主题只有一个：**@.pm@ 状态文件的受信取用口**
-- （'Pm.Config.readPmState' \/ 'withPmStateAppend' \/ 'readSideCache'）。
--
-- 十一轮实证了旧模式「拼路径字符串 → 校验字符串 → 再按名字打开」的三个洞：
-- 深度 ≥2 的完整路径没人验（manifest\/plan）、字符串校验在原理上看不见
-- hardlink（读侧完全没有 link count）、校验与打开是两次独立解析。这里每个
-- 用例钉一条：删掉对应的屏障，用例必须转红。
module StateGuardTests (stateGuardTests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import System.IO (IOMode (ReadMode), hClose, openBinaryFile)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeDirectory, removeDirectoryLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (CatalogLoad (..), catalogMaybe, loadCatalog, saveCatalog)
import Pm.Commands (TrashCmd (..), runTrash)
import Pm.Config (Config (..), SideCacheWrite (..), ensurePmSubdir, pmDir, readSideCache, requirePmTrusted, writeRootInfo, writeSideCache)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), runDoctor)
import Pm.Exec (Checkpoint (..), ExecEnv (..), ItemOutcome (..), defaultExecEnv, dirFingerprint, execPlan)
import Pm.GitGuard (classifyGitProbe, vaultIgnoreGuard)
import Pm.Hash (sha256File)
import Pm.Journal (JEntry (..), Sync (..), jAppend, withJournal)
import Pm.Lock (withRootLock)
import Pm.Op (Fingerprint (..), Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan, newPlanId, savePlan)
import Pm.Trash (TrashRecord (..), appendManifest, manifestMaybe, readManifest, trashDir)
import Pm.Win (NameKind (..), deleteBoundAt, moveBoundNoReplace)
import Pm.Status (StatusOpts (..), runStatus)
import Pm.Types (Catalog (..), RootInfo (..), RootRole (..))
import TestUtil

stateGuardTests :: TestTree
stateGuardTests =
  testGroup
    "P3b-14 .pm 状态文件的受信取用口（codex 十一~十四轮）"
    [ testCase "P3b-14 manifest.ndjson 是指向库外的文件 symlink → append/读取都拒绝，库外文件零改动" caseManifestDeepSymlink
    , testCase "P3b-14 catalog.json 被 hardlink 占名 → loadCatalog 拒读（读侧 link count）" caseCatalogHardlinkRead
    , testCase "P3b-14 plans/<id>.json 是深层 hardlink/symlink → loadPlan/savePlan 拒绝" casePlanDeepLink
    , testCase "P3b-14 .pm 是普通文件 → 可信闸与 loader 一律拒绝（不当\"尚不存在\"）" casePmIsPlainFile
    , testCase "P3b-14 侧缓存文件级链接 → 写侧文件级复检拦下、读侧 hardlink 弃用" caseSideCacheFileLevel
    , testCase "P3b-15 扫描窗口内 .pm 变 junction → saveCatalog 拒绝，库外三代快照零改动" caseSaveCatalogJunction
    , testCase "P3b-15 .pm/lock 被 hardlink 占名 → withRootLock 拒绝加锁" caseLockHardlink
    , testCase "P3b-15 trash 载荷是库外 hardlink → doctor 报 PM-LINK，--repair 不补虚假 Done" caseDoctorTrashPayloadLink
    , testCase "P3b-16 复位源 .pm/trash/<pid> 是 junction → doctor 报 PM-LINK，--repair 不补虚假 Done" caseDoctorRestoreSrcJunction
    , testCase "P3b-16 .pm/tmp/<planId> 是 junction → C1 的 tmp 探测报 PM-LINK，不穿透库外" caseDoctorPendingTmpProbe
    , testCase "P3b-16 侧缓存失信 → pm status 报 ⚠ 且退出码 1（不再静默 exit 0）" caseStatusUntrustedCacheExit
    , testCase "工作流 F079/F038 manifest 整文件读不出（hardlink 占名）→ trash list/empty 退出 2，不报「隔离区为空」" caseTrashManifestUnreadableExit
    , testCase "工作流 F032 快照被拒（hardlink 占名）→ doctor 报 CATALOG Bad；从未扫描的 root 不报" caseDoctorCatalogRefused
    , testCase "工作流 F032 --deep 无快照 → DEEP-SKIPPED Bad 且退出 1，不沉默；不带 --deep 仍零发现" caseDoctorDeepSkipped
    , testCase "P3b-17 FpDir 复位源是真实目录 → 必须落 R3（收窄成 doesFileExist 会错报 R2 并补假 Done）" caseRestoreSrcFpDir
    , testCase "P3b-17 FpFileSha + 目录占住载荷名 → 同样必须落 R3（触发不需要 FpDir）" caseRestoreSrcFpFile
    , testCase "P3b-18 root 是 junction、落位前改指诱饵库 → Copy 只用解析返回的 dst 路径，落在原库" caseCopyDstUsesResolvedPath
    , testCase "P6-C 落位后验：目标父层在窗口内被换成 junction → 检出、沿句柄回迁、项失败，库外零字节" caseMoveBoundDetectsDestSwap
    , testCase "P6-C 落位先验：源经 junction 路径到达 → 拒绝，两侧原封不动" caseMoveBoundSrcViaJunction
    , testCase "P6-C 删除先验：经 junction 路径 → 拒绝目标幸存；终段 symlink → 删链接本体不删目标" caseDeleteBoundViaJunction
    , testCase "三十二轮 R1：短暂共享冲突（err 32）→ 提交型打开按 Win32 同款预算重试而非立刻失败" caseDisposeRetriesSharing
    , testCase "三十六轮 F1 classifyGitProbe 三态穷举：查不出 ≠ 不存在（ProbeUnknown 必须 Left）" caseClassifyGitProbe
    , testCase "三十六轮 F1 悬空 .git junction → 判 git 语境要 .gitignore（布尔探针会当「无 git」放行）" caseDanglingGitJunction
    , testCase "第一方自审 R5：.pm 是 junction → ensurePmSubdir/savePlan/appendManifest 拒绝且库外零目录副作用" caseEnsurePmSubdirNoSideEffect
    , testCase "41 轮 #5 catalog 身份闸：catRootId ≠ root-id.json → CatRefused（拷贝/恢复错位快照不当种子）；相符照常载入" caseCatalogIdentityMismatch
    ]

-- 本模块只需要 hardlink（/H）与文件 symlink（无开关）两种形态；目录 junction
-- 的用例都在 PathGuardTests。
mkHardLink, mkFileLink, mkJunction :: FilePath -> FilePath -> IO ()
mkHardLink link target =
  () <$ readCreateProcess (shell ("mklink /H \"" <> link <> "\" \"" <> target <> "\"")) ""
mkFileLink link target =
  () <$ readCreateProcess (shell ("mklink \"" <> link <> "\" \"" <> target <> "\"")) ""
mkJunction link target =
  () <$ readCreateProcess (shell ("mklink /J \"" <> link <> "\" \"" <> target <> "\"")) ""

-- | 十一轮 **critical**（探针 Probe11 实证）：@.pm/trash@ 是普通目录、可信闸
-- （深度 1）放行；@manifest.ndjson@（深度 2）是指向库外单链接文件的**文件
-- symlink**——目标 link count = 1，九轮的 link count 判定也放行，@AppendMode@
-- 跟随链接，真实的 'appendManifest' 把隔离记录**追加进了库外文件**。
-- 修复是完整路径 'resolveUnder'（'withPmStateAppend'）：删掉它，本例转红。
caseManifestDeepSymlink :: IO ()
caseManifestDeepSymlink = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (trashDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "hostage.ndjson") "OUTSIDE-ORIGINAL\n"
  mkFileLink (trashDir root </> "manifest.ndjson") (outside </> "hostage.ndjson")
  now <- getCurrentTime
  -- 写侧：拒绝（IOException），一个字节都不追加
  ra <- try (appendManifest root (TrashRecord "v.jpg" "v.jpg" "aa" "t" tpid now)) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "appendManifest 应拒绝 symlink 化的 manifest")) ra
  readFile (outside </> "hostage.ndjson") >>= (@?= "OUTSIDE-ORIGINAL\n")
  -- 读侧：同口拒绝，绝不把库外内容当隔离清单
  (rs, ws) <- manifestMaybe <$> readManifest root
  rs @?= []
  assertBool ("readManifest 应报不可信: " <> show ws) (any ("不是 root 下的真实目录项" `isInfixOf`) ws)

-- | 十一轮 major（探针 Probe11b 实证）：hardlink 既不是 reparse point 也不改
-- 名字解析，可信闸与 'Pm.Win.resolveUnder' 在**原理上**看不见它；读侧此前没有
-- link count 判定，实测 hardlink 占名的 catalog.json 被**零警告**载入——快照
-- 决定 backup\/import 会读写哪些文件。修复是 'readPmState' 的句柄 link count：
-- 删掉它，本例转红。
caseCatalogHardlinkRead :: IO ()
caseCatalogHardlinkRead = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "evil-catalog.json") "{\"whatever\":1}"
  mkHardLink (pmDir root </> "catalog.json") (outside </> "evil-catalog.json")
  -- 深度 1 的枚举闸放行（hardlink 不可见）——这正是需要读侧句柄判定的原因
  requirePmTrusted root >>= either (assertFailure . ("闸不应看见 hardlink（否则本例测错了层）: " <>)) pure
  (mc, ws) <- catalogMaybe <$> loadCatalog root
  mc @?= Nothing
  assertBool ("loadCatalog 应报拒读: " <> show ws) (any ("无法可信读取" `isInfixOf`) ws)
  -- 库外对象完好（拒读不 unlink、不改写）
  readFile (outside </> "evil-catalog.json") >>= (@?= "{\"whatever\":1}")

-- | 十一轮 major（探针实证 hardlink 与 symlink 两种形态都把**库外计划**载入，
-- apply 会照它执行）。'readPmState' 一口治两种：resolveUnder 认 symlink，
-- 句柄 link count 认 hardlink——断言拒绝理由各自对应，钉住是哪层拦的。
casePlanDeepLink :: IO ()
casePlanDeepLink = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (pmDir root </> "plans")
  createDirectoryIfMissing True outside
  writeFile (outside </> "evil-plan.json") "{\"whatever\":1}"
  -- hardlink 形态：句柄 link count 拦
  mkHardLink (pmDir root </> "plans" </> "20260101-000000-abcdef.json") (outside </> "evil-plan.json")
  lp1 <- loadPlan root tpid
  either
    (\m -> assertBool m ("无法可信读取" `isInfixOf` m))
    (const (assertFailure "loadPlan 应拒绝 hardlink 占名的计划文件"))
    lp1
  -- symlink 形态（独立 root）：完整路径 resolveUnder 拦
  let root2 = dir </> "root2"
  createDirectoryIfMissing True (pmDir root2 </> "plans")
  mkFileLink (pmDir root2 </> "plans" </> "20260101-000000-abcdef.json") (outside </> "evil-plan.json")
  lp2 <- loadPlan root2 tpid
  either
    (\m -> assertBool m ("不是 root 下的真实目录项" `isInfixOf` m))
    (const (assertFailure "loadPlan 应拒绝 symlink 化的计划文件"))
    lp2
  -- savePlan 同守卫：删旧那步会 unlink，symlink 形态必须在写前拒绝
  plan <- mkPlanIO root2 []
  rs <- try (savePlan plan {plId = tpid}) :: IO (Either SomeException FilePath)
  either (const (pure ())) (const (assertFailure "savePlan 应拒绝 symlink 化的计划文件")) rs
  readFile (outside </> "evil-plan.json") >>= (@?= "{\"whatever\":1}")

-- | 十一轮 minor：@.pm@ 是**普通文件**时，旧闸把 @doesDirectoryExist=False@
-- 读成"尚不存在（新库）"而放行。四态判定后：缺失=放行，非目录/查不出=拒绝。
casePmIsPlainFile :: IO ()
casePmIsPlainFile = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  writeFile (pmDir root) "not a directory"
  requirePmTrusted root
    >>= either
      (\m -> assertBool m ("不是目录" `isInfixOf` m))
      (const (assertFailure "requirePmTrusted 应拒绝 .pm 是普通文件的 root"))
  (mc, ws) <- catalogMaybe <$> loadCatalog root
  mc @?= Nothing
  assertBool ("loadCatalog 应报不可信: " <> show ws) (any ("不是目录" `isInfixOf`) ws)

-- | 十一轮 #6：十轮的 'caseSideCacheJunction' 把 junction 放在**目录**级，
-- 命中的是 writeSideCache 的目录级 pre-check——删掉两个 writeCacheFile 的
-- **文件级**复检，那条用例照样绿。本例把链接放到文件级：目录是真目录、
-- pre-check 放行，catalog.json 自身是 symlink → 只有文件级复检能拦。
-- 读侧对偶（十二轮 #5 更正）：库外文件必须是**能成功解码**的 Catalog——
-- 十二轮指出旧写法放的是 @{"x":1}@，解码本来就失败，删掉 link count 屏障
-- 用例照样绿（假绿）。现在删掉屏障会得到 @Right (Just …)@ → 断言转红。
caseSideCacheFileLevel :: IO ()
caseSideCacheFileLevel = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
      cache = pmDir root </> "vault-cache"
  createDirectoryIfMissing True cache
  createDirectoryIfMissing True outside
  writeFile (outside </> "victim.json") "OUTSIDE-BYTES"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 写侧：catalog.json 是文件级 symlink → writeCacheFile 的完整路径复检拦下
  mkFileLink (cache </> "catalog.json") (outside </> "victim.json")
  w <- writeSideCache root "vault-cache" (mkCat []) (mkCat [])
  case w of
    CacheRefused m -> assertBool m ("catalog.json" `isInfixOf` m)
    other -> assertFailure ("writeSideCache 应在文件级复检拒绝 symlink，实为 " <> show other)
  readFile (outside </> "victim.json") >>= (@?= "OUTSIDE-BYTES")
  doesFileExist (cache </> "meta.json") >>= (@?= False)
  -- 读侧：meta.json 被 hardlink 占名 → readSideCache 报 Left（失信保留原因）。
  -- 库外内容是 pm 自己编码的合法 Catalog，保证拒绝只可能来自 link count。
  BSL.writeFile (outside </> "evil-meta.json") (Aeson.encode (mkCat []))
  mkHardLink (cache </> "meta.json") (outside </> "evil-meta.json")
  rm <- readSideCache root "vault-cache" "meta.json" :: IO (Either String (Maybe Catalog))
  case rm of
    Left m -> assertBool m ("无法可信读取" `isInfixOf` m)
    Right x ->
      assertFailure
        ("readSideCache 应报失信 Left，实得 Right "
           <> maybe "Nothing" (const "(Just <库外 Catalog 被当缓存>)") x)

-- ─── P3b-15（十二轮） ───────────────────────────────────────────────────────

-- | 十二轮 **critical**：'saveCatalog' 的轮转（tmp/base/.1/.2）此前全按名字
-- 操作、函数自身无任何解析。生产序列是「loadCatalog → 长扫描 → saveCatalog」
-- （'Pm.Commands.runScan'、'Pm.BackupCmd'），扫描期间把 @.pm@ 换成 junction，
-- 保存就会在**库外**建 tmp、删 @.2@、轮转 @.1@/base。
-- 本例模拟那段窗口：先以正常 root 落一份快照，再把 @.pm@ 换成 junction，然后
-- saveCatalog——四条路径的使用点解析必须整体拒绝，库外三个文件一字节不动。
caseSaveCatalogJunction :: IO ()
caseSaveCatalogJunction = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-pm"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True outside
  -- 库外预置三代快照（攻击者的“人质”）
  writeFile (outside </> "catalog.json") "OUTSIDE-BASE"
  writeFile (outside </> "catalog.json.1") "OUTSIDE-G1"
  writeFile (outside </> "catalog.json.2") "OUTSIDE-G2"
  -- 扫描窗口内 .pm 被换成 junction
  removeDirectory (pmDir root)
  mkJunction (pmDir root) outside
  r <- try (saveCatalog root (mkCat [])) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "saveCatalog 应拒绝 junction 化的 .pm")) r
  -- 库外三代原样：没被删、没被轮转、没被新 tmp 覆盖
  readFile (outside </> "catalog.json") >>= (@?= "OUTSIDE-BASE")
  readFile (outside </> "catalog.json.1") >>= (@?= "OUTSIDE-G1")
  readFile (outside </> "catalog.json.2") >>= (@?= "OUTSIDE-G2")
  doesFileExist (outside </> "catalog.json.tmp") >>= (@?= False)
  removeDirectoryLink (pmDir root)
  -- P3b-16（十三轮 minor）：上面只钉住"四条解析全部撤回"。十三轮指出单撤一条
  -- 时其余三条仍会在 `.pm` junction 上失败，用例照样绿。这里把每条路径**单独**
  -- 钉住：`.pm` 是真目录（四条解析都能过），只把**某一代**做成指向库外的文件
  -- symlink——只有针对该代的那一次解析能拦住它。
  forM_ ["catalog.json", "catalog.json.1", "catalog.json.2", "catalog.json.tmp"] $ \gen -> do
    let r2 = dir </> ("root-" <> gen)
        out2 = dir </> ("outside-" <> gen)
    createDirectoryIfMissing True (pmDir r2)
    createDirectoryIfMissing True out2
    writeFile (out2 </> "hostage") "OUTSIDE-GEN"
    mkFileLink (pmDir r2 </> gen) (out2 </> "hostage")
    e <- try (saveCatalog r2 (mkCat [])) :: IO (Either SomeException ())
    either
      (const (pure ()))
      (const (assertFailure ("saveCatalog 应拒绝 symlink 化的 " <> gen)))
      e
    readFile (out2 </> "hostage") >>= (@?= "OUTSIDE-GEN")

-- | 十二轮 minor：@.pm/lock@ 被 hardlink 到库外文件时，pm 会锁住那个共享
-- 对象（跨库互斥 / 对外部程序的 DoS）。resolveUnder 看不见 hardlink，只有
-- 句柄 link count 能拦——删掉 'Pm.Win.openStateLock' 的判定，本例转红。
caseLockHardlink :: IO ()
caseLockHardlink = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "shared.bin") "OUTSIDE-LOCK-TARGET"
  mkHardLink (pmDir root </> "lock") (outside </> "shared.bin")
  r <- try (withRootLock root (pure ())) :: IO (Either SomeException (Maybe ()))
  either (const (pure ())) (const (assertFailure "withRootLock 应拒绝 hardlink 占名的 lock")) r
  readFile (outside </> "shared.bin") >>= (@?= "OUTSIDE-LOCK-TARGET")

-- | 十二轮 **major**：doctor 对 @.pm/trash@ 载荷的核 sha 此前是
-- @doesFileExist@ + @sha256File@（按名字）。把载荷换成指向**库外同内容文件**
-- 的 hardlink 后，doctor 会“核验通过”并让 @--repair@ 补写虚假的 Done——把
-- 从未落位的隔离认证成已完成。受信探测（完整路径 resolveUnder + 句柄
-- link count + 同句柄 hash）让它只报 PM-LINK Bad，且 --repair 不补 Done。
caseDoctorTrashPayloadLink :: IO ()
caseDoctorTrashPayloadLink = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
      qdir = trashDir root </> T.unpack tpid
  createDirectoryIfMissing True qdir
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 库外文件的内容 = Intent 里声明的 sha（“看起来核验通过”）
  writeFile (outside </> "v.jpg") "VICTIM-BYTES"
  vsha <- sha256File (outside </> "v.jpg")
  mkHardLink (qdir </> "v.jpg") (outside </> "v.jpg")
  -- journal：一条只有 Intent 的隔离（doctor 的 Q-DONE-LOST 路径）
  withJournal root $ \j ->
    jAppend j Barrier (JIntent (tpOid 0) (OpQuarantine "v.jpg" vsha "t") now)
  rows <- doctorRows root
  assertBool ("应报 PM-LINK Bad，实得 " <> show rows) (("PM-LINK", Bad) `elem` rows)
  assertBool ("不得报 Q-DONE-LOST Warn（那会让 --repair 补 Done）: " <> show rows)
    (("Q-DONE-LOST", Warn) `notElem` rows)
  -- --repair 之后 journal 里仍然没有 Done
  _ <- runDoctor root (DoctorOpts False True)
  es <- journalEntries root
  assertBool ("--repair 不得补记 Done: " <> show (length es)) (not (any isDone es))
  readFile (outside </> "v.jpg") >>= (@?= "VICTIM-BYTES")

-- ─── P3b-16（十三轮） ───────────────────────────────────────────────────────

-- | 十三轮 **major**：`OpRename` 的**源**允许是 @.pm/trash/…@（'isTrashSrcRel'
-- 是 pm 唯一允许 Op 触及 `.pm` 内部的形态——undo/组复位把隔离文件搬回原位），
-- 而 doctor 此前对它用裸 `existsAny`。把 @.pm/trash/<pid>@ 换成指向空目录的
-- junction，源就被判成"不存在"；再让用户目标的指纹相符，就得到 R2 Warn，
-- `--repair` 补写**虚假的 Done**——把从未发生的复位认证成已完成。
-- 修复后 `.pm` 侧走受信探测，失信只报 PM-LINK Bad（进不了 repairDone 的
-- R2 Warn 白名单）。删掉 Doctor 的 `isTrashSrcRel` 分流，本例转红。
caseDoctorRestoreSrcJunction :: IO ()
caseDoctorRestoreSrcJunction = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-empty"
      trashSrc = ".pm" </> "trash" </> T.unpack tpid </> "v.jpg"
  createDirectoryIfMissing True (trashDir root)
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 用户目标存在且指纹与 Intent 相符（"看起来 rename 已执行"）
  writeFile (root </> "v.jpg") "RESTORED-BYTES"
  vsha <- sha256File (root </> "v.jpg")
  -- 复位源那一级是 junction → 裸 existsAny 会答"不存在"
  mkJunction (trashDir root </> T.unpack tpid) outside
  withJournal root $ \j ->
    jAppend j Barrier (JIntent (tpOid 0) (OpRename trashSrc "v.jpg" (FpFileSha vsha)) now)
  rows <- doctorRows root
  assertBool ("应报 PM-LINK Bad，实得 " <> show rows) (("PM-LINK", Bad) `elem` rows)
  assertBool ("不得报 R2 Warn（那会让 --repair 补 Done）: " <> show rows)
    (("R2", Warn) `notElem` rows)
  _ <- runDoctor root (DoctorOpts False True)
  es <- journalEntries root
  assertBool ("--repair 不得补记 Done: " <> show (length es)) (not (any isDone es))
  removeDirectoryLink (trashDir root </> T.unpack tpid)

-- | 十三轮 #6：`probePmExists`（C1 分支的 tmp 存在性探测）此前没有用例。
-- @.pm/tmp/<planId>@ 是 junction 时，裸 `doesFileExist` 会穿透到库外，把
-- "库外恰好有同名文件"读成"中断于写 tmp 阶段"。受信探测让它报 PM-LINK。
caseDoctorPendingTmpProbe :: IO ()
caseDoctorPendingTmpProbe = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-tmp"
  createDirectoryIfMissing True (pmDir root </> "tmp")
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 库外放一个与 pm 确定性 tmp 同名的文件
  writeFile (outside </> "0-a.jpg") "OUTSIDE-TMP"
  mkJunction (pmDir root </> "tmp" </> T.unpack tpid) outside
  -- dst 不存在 → 走 C1 分支的 tmp 探测
  withJournal root $ \j ->
    jAppend j Barrier (JIntent (tpOid 0) (OpCopy (dir </> "src.jpg") "a.jpg" "aa" 1 0) now)
  rows <- doctorRows root
  assertBool ("应报 PM-LINK Bad，实得 " <> show rows) (("PM-LINK", Bad) `elem` rows)
  readFile (outside </> "0-a.jpg") >>= (@?= "OUTSIDE-TMP")
  removeDirectoryLink (pmDir root </> "tmp" </> T.unpack tpid)

-- | 十三轮 #6：status 的失信退出码此前没有用例——`readSideCache` 返回 Left
-- 时 'Pm.Status' 必须报 ⚠ 且**计入退出码**（十二轮点出旧实现会静默 exit 0）。
caseStatusUntrustedCacheExit :: IO ()
caseStatusUntrustedCacheExit = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
      cache = pmDir root </> "backup-cache"
  createDirectoryIfMissing True cache
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (mkCat [])
  -- 先确认干净库下 status 能返回 0（把"退出码 1 来自失信"与"来自其它差异"分开）
  code0 <- runStatus (mkSCfg root) (StatusOpts True)
  code0 @?= 0
  -- 侧缓存 meta 被 hardlink 占名 → 失信
  BSL.writeFile (outside </> "evil-meta.json") (Aeson.encode (mkCat []))
  mkHardLink (cache </> "meta.json") (outside </> "evil-meta.json")
  code1 <- runStatus (mkSCfg root) (StatusOpts True)
  code1 @?= 1

-- | 工作流 F079/F038：manifest **整文件**读不出（hardlink 占名 → readPmState
-- 拒）此前与「一行坏记录」同进一个 [String]：trash list 打「隔离区为空」exit 0，
-- trash empty 打「没有可清除」exit 0。整文件失败现在是 trashView 的 Left——
-- 与枚举失败同码 2；坏行仍只是坏行（PathGuardTests 的 caseManifestPathEscape
-- 钉住那一半 exit 0，本例与它一红一绿才算判别）。
caseTrashManifestUnreadableExit :: IO ()
caseTrashManifestUnreadableExit = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (trashDir root)
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeFile (outside </> "evil-manifest.ndjson") ""
  mkHardLink (trashDir root </> "manifest.ndjson") (outside </> "evil-manifest.ndjson")
  (outL, cL) <- captureStdout (runTrash (mkSCfg root) TrashList root)
  cL @?= 2
  assertBool ("不得报隔离区为空: " <> outL) (not ("隔离区为空" `isInfixOf` outL))
  (outE, cE) <- captureStdout (runTrash (mkSCfg root) (TrashEmpty True) root)
  cE @?= 2
  assertBool ("不得报没有可清除: " <> outE) (not ("没有可清除" `isInfixOf` outE))

-- | 工作流 F032：快照通道是 doctor 唯一被丢掉的降级信号（journal/manifest/枚举
-- 失败都有各自的行）。被拒 → CATALOG Bad；判别：从未扫描的 root（缺席）不是
-- 发现——按 @mcat == Nothing@ 键的错修法会把新 root 判红。
caseDoctorCatalogRefused :: IO ()
caseDoctorCatalogRefused = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
      fresh = dir </> "fresh"
  mapM_ (createDirectoryIfMissing True) [pmDir root, outside, fresh]
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeRootInfo fresh (RootInfo "f" RoleMain now Nothing)
  writeFile (outside </> "evil-catalog.json") "{\"whatever\":1}"
  mkHardLink (pmDir root </> "catalog.json") (outside </> "evil-catalog.json")
  rows <- doctorRows root
  assertBool ("被拒的快照应报 CATALOG Bad: " <> show rows) (("CATALOG", Bad) `elem` rows)
  rowsF <- doctorRows fresh
  assertBool ("缺席不是发现: " <> show rowsF) (not (any ((== "CATALOG") . fst) rowsF))

-- | 工作流 F032 的另一半：--deep 的决定此前藏在 @Just cat@ 分支里，没有快照
-- 就一个字节不核、一句话不说、退出 0。
caseDoctorDeepSkipped :: IO ()
caseDoctorDeepSkipped = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True (pmDir root)
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  (fs, code) <- runDoctor root (DoctorOpts True False)
  let rows = [(fRow f, fSeverity f) | f <- fs]
  assertBool ("--deep 无快照不得沉默: " <> show rows) (("DEEP-SKIPPED", Bad) `elem` rows)
  code @?= 1
  (fs0, code0) <- runDoctor root (DoctorOpts False False)
  filter (== "DEEP-SKIPPED") (map fRow fs0) @?= []
  code0 @?= 0

-- ─── P3b-17（十四轮） ───────────────────────────────────────────────────────

-- | 十四轮 **major**：P3b-16 把复位源的 `existsAny`（文件**或**目录）换成受信
-- 探针时，只写了 `doesFileExist`——**谓词在安全重构里被悄悄收窄**。`OpRename`
-- 两侧都可以是目录（'Pm.Names' 生成的 Raw 事件夹改名就是 FpDir），于是 trash
-- 里**真实存在的目录**复位源被判成"不存在"，与存在且指纹相符的 new 组合成
-- R2 Warn，`--repair` 补写**虚假 Done**。正确格是 R3（不在 repairDone 白名单）。
--
-- 拆成**两个**用例而不是一个函数里两段：十三轮的粒度教训——同一函数里前一条
-- 断言先炸，后一条永远跑不到，等于没钉。拆开后突变一次必须看到**两条**都转红。
--   ① FpDir：目录 old + 目录 new —— codex 报的那条形态；
--   ② FpFileSha：目录 old + 文件 new —— 触发**不需要** FpDir，现有 undo 构造器
--      （'Pm.Undo' 只生成 FpFileSha 复位）配上一个占了载荷名的目录就够。
-- 把 'Pm.Doctor.probePmExists' 的 @PmEntryAny@ 改回 @PmEntryFile@，两条都转红。

-- | ① old 与 new 都是真实目录，Intent 记的是 new 的 FpDir 指纹。
caseRestoreSrcFpDir :: IO ()
caseRestoreSrcFpDir = withSystemTempDirectory "pm-sguard" $ \dir -> do
  now <- getCurrentTime
  let root = dir </> "root"
      qdir = trashDir root </> T.unpack tpid
  createDirectoryIfMissing True (qdir </> "olddir")
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeFile (qdir </> "olddir" </> "a.jpg") "A"
  createDirectoryIfMissing True (root </> "newdir")
  writeFile (root </> "newdir" </> "a.jpg") "A"
  fpd <- dirFingerprint (root </> "newdir")
  withJournal root $ \j ->
    jAppend
      j
      Barrier
      (JIntent (tpOid 0) (OpRename (".pm" </> "trash" </> T.unpack tpid </> "olddir") "newdir" (FpDir fpd)) now)
  assertRestoreSrcSeenAsPresent root

-- | ② 同一屏障、不需要 FpDir：trash 里一个**目录**占住了载荷名，victim 仍在原位
-- 且 sha 与 Intent 相符（收窄后正是 verifyFp 会通过、被补假 Done 的那一格）。
caseRestoreSrcFpFile :: IO ()
caseRestoreSrcFpFile = withSystemTempDirectory "pm-sguard" $ \dir -> do
  now <- getCurrentTime
  let root = dir </> "root"
      qdir = trashDir root </> T.unpack tpid
  createDirectoryIfMissing True (qdir </> "v.jpg")
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeFile (root </> "v.jpg") "RESTORED-BYTES"
  vsha <- sha256File (root </> "v.jpg")
  withJournal root $ \j ->
    jAppend
      j
      Barrier
      (JIntent (tpOid 0) (OpRename (".pm" </> "trash" </> T.unpack tpid </> "v.jpg") "v.jpg" (FpFileSha vsha)) now)
  assertRestoreSrcSeenAsPresent root

-- | 共用断言：复位源盘上确实在 → R3 Warn（未执行且目标被占），**不得**是
-- R2 Warn，且 @--repair@ 之后 journal 里没有 Done。
assertRestoreSrcSeenAsPresent :: FilePath -> IO ()
assertRestoreSrcSeenAsPresent root = do
  rows <- doctorRows root
  assertBool ("目录复位源存在 → 应报 R3 Warn，实得 " <> show rows) (("R3", Warn) `elem` rows)
  assertBool
    ("不得报 R2 Warn（那会让 --repair 补虚假 Done）: " <> show rows)
    (("R2", Warn) `notElem` rows)
  _ <- runDoctor root (DoctorOpts False True)
  es <- journalEntries root
  assertBool ("--repair 不得补记 Done: " <> show (length es)) (not (any isDone es))

-- ─── P3b-18（十四轮 #3 的缺口，十五轮给出的设计） ──────────────────────────

-- | 此前没有用例钉住"限域助手**返回的路径必须被使用**"：把 Copy 的 dst 改回
-- `root </> opDstRel` 重拼，现有用例照样绿——它们都是注入 junction 后让限域
-- 返回 Nothing 提前退出，重拼分支根本不可达。
--
-- 十五轮读源码给出设计：'Pm.Win.resolveUnder' 只 canonicalize base、不对 base
-- 调 probeName（把库根放在 junction 上是合法用法，Win.hs 注释明说）。于是：
-- rootLink → A 时解析 dst，返回的是 A 的**真实**路径；在 'CpCopyAfterFlush'
-- （tmp 已写完并设好 mtime、落位 move 之前）把 rootLink 改指诱饵库 B——
-- 正确实现只用解析返回的路径，落在 A、B 零改动；把 dst 改回重拼的突变会沿
-- 新指向落到 B。journal / lock 句柄在 A 内打开、之后只用句柄，不受改指影响。
--
-- 平台前提（十五轮标注为假设）：A 内 journal/lock 句柄打开时允许删除并重建
-- 该 junction。由检查点内直接执行验证——不允许则 mklink 非零退出抛异常，
-- 用例失败并暴露前提，而不是静默跳过。
caseCopyDstUsesResolvedPath :: IO ()
caseCopyDstUsesResolvedPath = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let libA = dir </> "A"
      libB = dir </> "B"
      rootLink = dir </> "rootLink"
      dstRel = "相册" </> "x.jpg"
  createDirectoryIfMissing True (pmDir libA)
  createDirectoryIfMissing True (pmDir libB)
  now <- getCurrentTime
  writeRootInfo libA (RootInfo "m" RoleMain now Nothing)
  -- 诱饵库给同样的身份与目录结构：让重拼版实现能"顺利"落到 B，失败原因
  -- 只可能是"用了哪条路径"，不混入别的拒绝理由。
  writeRootInfo libB (RootInfo "m" RoleMain now Nothing)
  mkJunction rootLink libA
  op <- mkCopyOp (dir </> "s.jpg") "SOURCE-BYTES" dstRel
  pid <- newPlanId
  let plan = Plan pid "test" rootLink (Just "m") now [PlanItem 0 op StPending Nothing]
      env =
        defaultExecEnv
          { eeCheckpoint = \c ->
              when (c == CpCopyAfterFlush) $ do
                removeDirectoryLink rootLink
                mkJunction rootLink libB
          }
  r <- execPlan env plan
  case r of
    Right [(_, ODone {})] -> pure ()
    other -> assertFailure ("expected ODone, got " <> show other)
  -- 落在 A（解析返回的真实路径），不在 B（改指后的重拼路径）
  doesFileExist (libA </> dstRel) >>= (@?= True)
  readFile (libA </> dstRel) >>= (@?= "SOURCE-BYTES")
  doesFileExist (libB </> dstRel) >>= (@?= False)
  removeDirectoryLink rootLink

mkSCfg :: FilePath -> Config
mkSCfg root = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing

-- ─── P6-C（路线图③）：提交型操作的句柄形态 ────────────────────────────────

-- | 杀手锏：'Pm.Win.moveBoundNoReplace' 的**后验**。dstAbs 已由限域解析成
-- 真实路径，但名字口的 rename 在提交那一刻仍会沿"窗口里刚换上的 junction"
-- 走——旧实现（MoveFileExW）在这个用例里会把照片**静默**落到库外并报 ODone。
-- 新实现：rename 之后问同一个句柄"对象现在在哪"，不符 → 沿句柄改回 tmp →
-- 项失败。断言三件事：项不是 ODone、库外目录零字节、tmp 已回迁（doctor 可对账）。
caseMoveBoundDetectsDestSwap :: IO ()
caseMoveBoundDetectsDestSwap = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "lib"
      evil = dir </> "evil"
      dstRel = "相册" </> "x.jpg"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True evil
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  op <- mkCopyOp (dir </> "s.jpg") "SOURCE-BYTES" dstRel
  pid <- newPlanId
  let plan = Plan pid "test" root (Just "m") now [PlanItem 0 op StPending Nothing]
      env =
        defaultExecEnv
          { eeCheckpoint = \c ->
              when (c == CpCopyAfterFlush) $
                -- 相册 尚不存在：在检查点把它整层做成指向库外的 junction。
                -- 随后的 createDirectoryIfMissing 看到"目录已在"，名字口的
                -- rename 会顺着它把文件送出库。
                mkJunction (root </> "相册") evil
          }
  r <- execPlan env plan
  case r of
    Right [(_, ODone {})] -> assertFailure "落位后验失效：对象落到库外却报 DONE"
    Right [(_, _)] -> pure ()
    other -> assertFailure ("expected one non-DONE outcome, got " <> show other)
  -- 库外零字节
  evilFiles <- listDirectory evil
  evilFiles @?= []
  -- tmp 已沿句柄回迁（字节不丢，doctor 可对账）
  tmps <- listDirectory (pmDir root </> "tmp" </> T.unpack pid)
  tmps @?= ["0-x.jpg"]
  removeDirectoryLink (root </> "相册")

-- | 先验：源路径经 junction 到达（J\x 的句柄绑定的是 D\x）→ 拒绝。
caseMoveBoundSrcViaJunction :: IO ()
caseMoveBoundSrcViaJunction = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let d = dir </> "D"
      j = dir </> "J"
  createDirectoryIfMissing True d
  writeFile (d </> "x.txt") "KEEP"
  mkJunction j d
  r <- try (moveBoundNoReplace (j </> "x.txt") (dir </> "y.txt")) :: IO (Either SomeException ())
  case r of
    Left _ -> pure ()
    Right () -> assertFailure "经 junction 的源路径应被先验拒绝"
  readFile (d </> "x.txt") >>= (@?= "KEEP")
  doesFileExist (dir </> "y.txt") >>= (@?= False)
  removeDirectoryLink j

-- | 删除的两个形态：经 junction 的路径拒绝（目标幸存）；终段是 symlink 时
-- 删的是链接本体（OPEN_REPARSE_POINT），目标原封不动。
caseDeleteBoundViaJunction :: IO ()
caseDeleteBoundViaJunction = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let d = dir </> "D"
      j = dir </> "J"
  createDirectoryIfMissing True d
  writeFile (d </> "x.txt") "KEEP"
  mkJunction j d
  r <- try (deleteBoundAt (j </> "x.txt")) :: IO (Either SomeException ())
  case r of
    Left _ -> pure ()
    Right () -> assertFailure "经 junction 的删除路径应被先验拒绝"
  readFile (d </> "x.txt") >>= (@?= "KEEP")
  removeDirectoryLink j
  -- 终段 symlink：删链接不删目标
  writeFile (dir </> "target.txt") "TARGET"
  mkFileLink (dir </> "ln.txt") (dir </> "target.txt")
  deleteBoundAt (dir </> "ln.txt")
  doesFileExist (dir </> "ln.txt") >>= (@?= False)
  readFile (dir </> "target.txt") >>= (@?= "TARGET")

-- | 三十二轮 R1：被 P6-C 替掉的名字口原语（Win32 的 moveFileEx/deleteFile）
-- 内建「ERROR_SHARING_VIOLATION=32 → 100ms×20 重试」（KB 316609：杀毒/索引器
-- 短暂持有刚 close 的文件）；句柄化后冲突挪到打开那一步，重试预算必须跟着搬。
-- fixture：GHC 的 openBinaryFile 不带 FILE_SHARE_DELETE，另一线程 300ms 后
-- 才放手——无重试的实现（旧 withDisposeHandle）在这里**立刻**抛 err 32；
-- 有重试的在 ≤2s 预算内等到句柄释放并删除成功。300ms 对 2s 预算余量 6 倍，
-- 只在整机停顿 >1.7s 时才可能误红。
caseDisposeRetriesSharing :: IO ()
caseDisposeRetriesSharing = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let f = dir </> "busy.txt"
  writeFile f "X"
  h <- openBinaryFile f ReadMode
  _ <- forkIO (threadDelay 300000 >> hClose h)
  deleteBoundAt f
  doesFileExist f >>= (@?= False)

-- ─── 三十六轮 F1：I11 的 .git 存在性探测三态化 ─────────────────────────────

-- | 判定表穷举。要害格是 ProbeUnknown：布尔探针把 ACL/介质错误吞成 False，
-- 而 GitGuard 里 False 的去向是放行（自身→祖先扫描→Right ()）——查不出必须
-- 是 Left，不许给布尔答案。Surrogate 判「有」：只会引向更严一侧，不会放行。
caseClassifyGitProbe :: IO ()
caseClassifyGitProbe = do
  classifyGitProbe NameMissing @?= Right False
  classifyGitProbe NamePlain @?= Right True
  classifyGitProbe NameSurrogate @?= Right True
  case classifyGitProbe ProbeUnknown of
    Left why -> assertBool ("拒绝理由应点名核不了: " <> why) ("核不了" `isInfixOf` why)
    Right b -> assertFailure ("ProbeUnknown 不得塌缩成布尔答案（fail-open 的形状）: " <> show b)

-- | 端到端判别器：**悬空** junction 的 @.git@。旧布尔探针（doesDirectoryExist/
-- doesFileExist）对悬空链接都答 False（GuardTests 位移槽用例同一实测），守卫
-- 便当「无 git 语境」走祖先扫描放行；probeName 判 NameSurrogate → git 语境
-- 成立 → 本层必须有覆盖 .pm/ 的 .gitignore，这里没有 → 拒绝。
caseDanglingGitJunction :: IO ()
caseDanglingGitJunction = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let v = dir </> "vault"
  createDirectoryIfMissing True v
  mkJunction (v </> ".git") (dir </> "no-such-target")
  g <- vaultIgnoreGuard v
  case g of
    Right () -> assertFailure "悬空 .git junction 被当成「无 git 语境」放行（三十六轮 F1 的形状）"
    Left msg -> assertBool ("应按 git 语境要求 .gitignore: " <> msg) (".gitignore" `isInfixOf` msg)
  removeDirectoryLink (v </> ".git")

-- ─── 第一方自审 R5：`.pm` 子目录「先限域再建」───────────────────────────────

-- | @.pm@ 整个是 junction 时，旧序「先 createDirectoryIfMissing 子目录、再
-- resolveUnder 限域」照样会**拒绝**——但 mkdir 已经穿透 junction 把
-- @plans/@\/@trash/@ 建进了库外，留下目录副作用。'ensurePmSubdir' 把限域挪到
-- mkdir 之前：把它退回「先建后限域」，下面三条 @doesDirectoryExist … \@?= False@
-- 转红（拒绝断言仍绿——这正是旧序漏检的原因）。
caseEnsurePmSubdirNoSideEffect :: IO ()
caseEnsurePmSubdirNoSideEffect = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True root
  createDirectoryIfMissing True outside
  mkJunction (pmDir root) outside
  -- 根口：helper 本身
  eh <- ensurePmSubdir root "probe"
  either (const (pure ())) (const (assertFailure "ensurePmSubdir 应拒绝 junction 化的 .pm")) eh
  doesDirectoryExist (outside </> "probe") >>= (@?= False)
  -- 消费口 1：savePlan（plan 在真实的 root2 上构造，写向被劫持的 root）
  plan0 <- mkPlanIO (dir </> "root2") []
  rs <- try (savePlan plan0 {plRootPath = root}) :: IO (Either SomeException FilePath)
  either (const (pure ())) (const (assertFailure "savePlan 应拒绝 junction 化的 .pm")) rs
  doesDirectoryExist (outside </> "plans") >>= (@?= False)
  -- 消费口 2：appendManifest
  now <- getCurrentTime
  ra <- try (appendManifest root (TrashRecord "v.jpg" "v.jpg" "aa" "t" tpid now)) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "appendManifest 应拒绝 junction 化的 .pm")) ra
  doesDirectoryExist (outside </> "trash") >>= (@?= False)
  removeDirectoryLink (pmDir root)

-- | 41 轮 #5：catRootId 是身份字段，落盘后此前**无人读**——把 A 库的 .pm
-- 整目录拷去 B 库（迁移/恢复错位）后 loadCatalog 零告警载入，而快照决定
-- backup/import/undo 去读写哪些文件、scan 拿谁当 sha 复用种子。loader 汇点
-- 与 .pm/root-id.json 对账，对不上整链拒绝（同 P3b-13 的闸下沉纪律）。
caseCatalogIdentityMismatch :: IO ()
caseCatalogIdentityMismatch = withSystemTempDirectory "pm-catid" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  now <- getCurrentTime
  writeRootInfo root (RootInfo "real-rid" RoleMain now Nothing)
  saveCatalog root (mkCat [])
  cl <- loadCatalog root
  case cl of
    CatRefused ws -> assertBool ("应点名身份不符: " <> show ws) (any ("身份不符" `isInfixOf`) ws)
    _ -> assertFailure "错位快照竟被载入（或被当成缺席）"
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  cl2 <- loadCatalog root
  case cl2 of
    CatLoaded c ws -> do
      catRootId c @?= "m"
      ws @?= []
    _ -> assertFailure "身份相符的快照必须照常载入"
