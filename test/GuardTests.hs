{-# LANGUAGE OverloadedStrings #-}

-- | P3b-6\/P3b-7\/P3b-8：codex 三轮\/四轮\/五轮复审收口用例——A1 严格 opId\/
-- planId 解析（pid 须为生成格式，路径型 oid 不得越出 root）与位移槽位探测、
-- A2 通配符反规则、A3 匿名 root 与 role 改写、B1 requireMain\/requireRole 各
-- 入口且先于任何读取判定、init\/backup init 守卫、dirFingerprint 不跟随
-- reparse point、损坏 root-id（含测试 fixture 不覆盖）、I11 覆盖全部 .pm 写入口。
module GuardTests (guardTests) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryLink)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import Pm.Cli (GoOpts (..), recheckCleanPlan, savePlanAndMaybeRun)
import Pm.Commands (RootSel (..), TrashCmd (..), afterApply, backupInitPreflight, initPreflight, pickRoot, runClean, runImport, runTrash)
import Pm.Config (Config (..), RootIdState (..), createRootInfo, pmDir, readRootInfo, readRootState, requireRole, requireWritable, writeRootInfo)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), runDoctor)
import Pm.Exec
import Pm.GitGuard (vaultIgnoreGuard)
import Pm.Hash (sha256File)
import Pm.Journal (JEntry (..), Sync (..), jAppend, journalPath, withJournal)
import Pm.Op
import Pm.Plan
import Pm.Trash (TrashRecord (..), appendManifest, quarTrashRel, trashDir)
import Pm.Types (RootInfo (..), RootRole (..))
import Pm.Vault (ensureVaultRoot, runVaultStatus)
import TestUtil

guardTests :: TestTree
guardTests =
  testGroup
    "P3b-6/7/8 守卫与解析（codex 三轮/四轮/五轮）"
    [ testCase "A2 通配符/转义反规则 fail-closed；纯字面无关反规则放行" caseWildcardNegations
    , testCase "A3 匿名 root（无 root-id）→ execPlan 拒绝，.pm 连锁文件都不创建" caseAnonymousRoot
    , testCase "A3 marker role 改成 RoleMain 也绕不过 I11（守卫对所有 role 生效）" caseRoleRewrite
    , testCase "A1 planId 生成格式校验：execPlan / loadPlan 均拒绝" casePlanIdValidation
    , testCase "A1 opIdParts 严格解析 + quarTrashRel 推导" caseOpIdParts
    , testCase "A1 位移槽被同名目录占住 → 跳到下一槽，victim 仍复位" caseSlotOccupiedByDir
    , testCase "minor dirFingerprint 不跟随 junction（指回祖先仍终止，记为 l 条目）" caseJunctionFingerprint
    , testCase "major initPreflight：git 树无 ignore / 已是备份 root → 拒绝" caseInitPreflight
    , testCase "major backupInitPreflight：.git 文件 / 与主库嵌套 → 拒绝" caseBackupInitPreflight
    , testCase "B1 pickRoot SelMain：主库路径是备份 root → 拒绝" casePickRootMain
    , testCase "B1 computeVault：主库路径无标识或非 RoleMain → exit 2" caseVaultRequiresMain
    , testCase "P3b-7 A1 opIdParts 拒绝非规范十进制（前导零）；quarTrashRel 畸形 → Nothing" caseOpIdCanonical
    , testCase "P3b-7 A1 validatePlan：负数/重复 piIx → execPlan/loadPlan 拒绝" casePlanIxValidation
    , testCase "P3b-7 A1 doctor：畸形 oid → OID-MALFORMED Bad，--repair 不补 Done" caseDoctorMalformedOid
    , testCase "P3b-7 A1 位移槽被悬空 junction 占住 → 跳到下一槽" caseSlotDanglingLink
    , testCase "P3b-7 major 损坏 root-id：Corrupt 三态；init/vault/可写性拒绝；createRootInfo 不覆盖" caseCorruptRootId
    , testCase "P3b-7 B1 主库路径为备份 root：afterApply 不写缓存、clean 复验全降级、trash empty HELD" caseMainIsBackupWitness
    , testCase "P3b-7 I11 全写入口：doctor --repair / savePlanAndMaybeRun / pickRoot --vault / requireRole 拒绝" caseI11AllWriters
    , testCase "P3b-8 A1 opIdParts 只认生成格式 pid：路径型/短名/超长序号 → Nothing；doctor 不越出 root" caseOpIdTraversal
    , testCase "P3b-8 A1 slotOccupied：非法名等探测异常按占用；文件当目录用 → 空槽" caseSlotOccupiedProbe
    , testCase "P3b-8 B1 runClean / runImport：主库身份校验先于索引读取与三副本判定" caseCleanImportGuardFirst
    , testCase "P3b-8 minor ensureTestRoot：损坏标识不覆盖；缺席则 no-replace 建立且不改 role" caseFixtureKeepsCorrupt
    ]

mkCfg :: FilePath -> Maybe FilePath -> Config
mkCfg mainP vdir = Config mainP vdir Nothing Nothing Nothing Nothing

caseWildcardNegations :: IO ()
caseWildcardNegations = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let v = tmp </> "v"
  createDirectoryIfMissing True (v </> ".git")
  -- git 2.52 实测：以下四种反规则都不含 ".pm" 字面却让 .pm/probe 变回未忽略
  let rejects =
        [ ".pm/\n!.[p]m/\n!.[p]m/**\n"
        , ".pm/\n!.p\\m/\n!.p\\m/**\n"
        , ".pm/\n!.?m/**\n"
        , ".pm/\n!.*/\n"
        , ".pm/\n!.PM\n"
        ]
  forM_ rejects $ \ig -> do
    writeFile (v </> ".gitignore") ig
    g <- vaultIgnoreGuard v
    assertBool ("应拒绝: " <> show ig) (either ("反规则" `isInfixOf`) (const False) g)
  -- 纯字面、不含 .pm 的反规则：git 只按字面匹配，不可能命中 .pm → 放行
  writeFile (v </> ".gitignore") "_site/\n.pm/\n!README.md\n!docs/keep.txt\n"
  g <- vaultIgnoreGuard v
  g @?= Right ()

caseAnonymousRoot :: IO ()
caseAnonymousRoot = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "bare"
  createDirectoryIfMissing True root
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  pid <- newPlanId
  now <- getCurrentTime
  -- 不经 mkPlanIO（它会写 fixture 标识）：裸目录 + 无 rootId 计划
  let plan = Plan pid "test" root Nothing now [PlanItem 0 op StPending Nothing]
  r <- execPlan defaultExecEnv plan
  case r of
    Left msg -> assertBool msg ("无身份" `isInfixOf` msg)
    Right _ -> assertFailure "内核不得在无 root-id 的目录上执行"
  pmEx <- doesDirectoryExist (pmDir root)
  pmEx @?= False -- 预检在取锁之前：连 .pm/lock 都不落
  landed <- doesFileExist (root </> "相册" </> "x.jpg")
  landed @?= False

caseRoleRewrite :: IO ()
caseRoleRewrite = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "tree"
  createDirectoryIfMissing True (root </> ".git")
  writeFile (root </> ".gitignore") "_site/\n"
  now <- getCurrentTime
  -- 攻击模型：把 vault 的 marker 改成 main——旧代码只对 RoleVault 跑守卫
  writeRootInfo root (RootInfo "rid-x" RoleMain now Nothing)
  op <- mkCopyOp (dir </> "s.jpg") "X" ("landscape" </> "x.jpg")
  plan <- mkPlanIO root [op] -- 沿用 rid-x
  plRootId plan @?= Just "rid-x"
  r <- execPlan defaultExecEnv plan
  case r of
    Left msg -> assertBool msg ("I11" `isInfixOf` msg)
    Right _ -> assertFailure "改写 role 不得绕过 I11"
  jEx <- doesFileExist (journalPath root)
  jEx @?= False

casePlanIdValidation :: IO ()
casePlanIdValidation = withSystemTempDirectory "pm-guard" $ \dir -> do
  isValidPlanId "20260824-030200-0c238a" @?= True
  isValidPlanId "job~d7" @?= False
  isValidPlanId "20260824-030200-0C238A" @?= False -- hex 须小写
  isValidPlanId "20260824-030200-0c238" @?= False
  isValidPlanId "..\\20260824-030200-0c238a" @?= False
  let root = dir </> "root"
  createDirectoryIfMissing True root
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  -- execPlan：非生成格式的 id 拒绝，零写入
  r <- execPlan defaultExecEnv plan {plId = "job~d7"}
  case r of
    Left msg -> assertBool msg ("生成格式" `isInfixOf` msg)
    Right _ -> assertFailure "非生成格式的计划 id 不得执行"
  jEx <- doesFileExist (journalPath root)
  jEx @?= False
  -- loadPlan：格式不合法不触盘直接拒；文件内 id 与文件名不符也拒
  l1 <- loadPlan root "job~d7"
  either (\m -> assertBool m ("生成格式" `isInfixOf` m)) (const (assertFailure "应拒绝装载")) l1
  fp <- savePlan plan
  let other = "20000101-000000-abcdef"
  copyFile fp (planPath root other)
  l2 <- loadPlan root other
  either (\m -> assertBool m ("不符" `isInfixOf` m)) (const (assertFailure "文件内 id 与文件名不符应拒绝")) l2
  l3 <- loadPlan root (plId plan)
  either assertFailure (\p -> plId p @?= plId plan) l3

caseOpIdParts :: IO ()
caseOpIdParts = do
  let pid = "20260824-030200-0c238a"
  opIdParts (opId pid 3) @?= Just (pid, 3, SfxPlain)
  opIdParts (restoreOpId pid 3) @?= Just (pid, 3, SfxRestore)
  opIdParts (displacedOpId pid 3 2) @?= Just (pid, 3, SfxDisplaced 2)
  opIdParts "job~d7#0~d1" @?= Nothing -- planId 含 ~：不是 pm 生成的
  opIdParts (pid <> "#0~d0") @?= Nothing -- N ≥ 1
  opIdParts (pid <> "#0~x") @?= Nothing
  opIdParts (pid <> "#") @?= Nothing
  opIdParts (pid <> "#0#1") @?= Nothing
  quarTrashRel (pid <> "#0~d2") "v.jpg" @?= Just (T.unpack pid <> "~displaced-2" </> "v.jpg")
  quarTrashRel (pid <> "#0~r") "v.jpg" @?= Just (T.unpack pid </> "v.jpg")
  quarTrashRel (pid <> "#0") ("a" </> "v.jpg") @?= Just (T.unpack pid </> "a" </> "v.jpg")

caseOpIdCanonical :: IO ()
caseOpIdCanonical = do
  -- 非规范十进制不是 pm 生成的：手编 "<pid>#00~r" 不得抵消真实 "<pid>#0" 的 Done
  opIdParts (tpid <> "#00") @?= Nothing
  opIdParts (tpid <> "#01") @?= Nothing
  opIdParts (tpid <> "#0~d01") @?= Nothing
  opIdParts (tpid <> "#10~d10") @?= Just (tpid, 10, SfxDisplaced 10)
  quarTrashRel (tpid <> "#00") "v.jpg" @?= Nothing
  quarTrashRel "job~d7#0~d1" "v.jpg" @?= Nothing

caseSlotOccupiedByDir :: IO ()
caseSlotOccupiedByDir = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      victim = root </> "landscape" </> "d.jpg"
  createDirectoryIfMissing True (root </> "landscape")
  writeFile victim "OLDBYTES"
  oldSha <- sha256File victim
  op <- mkCopyOp (dir </> "s.jpg") "NEWBYTES" ("landscape" </> "d.jpg")
  plan <-
    mkGroupPlanIO
      root
      [ (OpQuarantine ("landscape" </> "d.jpg") oldSha "supersede:test", Just 0)
      , (op, Just 0)
      ]
  let slot n =
        trashDir root </> (T.unpack (plId plan) <> "~displaced-" <> show (n :: Int)) </> "landscape" </> "d.jpg"
  -- 槽位 1 被一个同名**目录**占住：旧代码 doesFileExist 看不见 → 反复选槽 1 → move 必败
  createDirectoryIfMissing True (slot 1)
  let env = defaultExecEnv {eeCheckpoint = \c -> when (c == CpCopyAfterFlush) $ writeFile victim "INTERLOPER"}
  r <- execPlan env plan
  case r of
    Right [(_, OFailed _), (_, OConflict m)] -> assertBool ("应改用槽位 2: " <> m) ("~displaced-2" `isInfixOf` m)
    other -> assertFailure (show other)
  readFile victim >>= (@?= "OLDBYTES")
  readFile (slot 2) >>= (@?= "INTERLOPER")

caseSlotDanglingLink :: IO ()
caseSlotDanglingLink = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      victim = root </> "landscape" </> "d.jpg"
  createDirectoryIfMissing True (root </> "landscape")
  writeFile victim "OLDBYTES"
  oldSha <- sha256File victim
  op <- mkCopyOp (dir </> "s.jpg") "NEWBYTES" ("landscape" </> "d.jpg")
  plan <-
    mkGroupPlanIO
      root
      [ (OpQuarantine ("landscape" </> "d.jpg") oldSha "supersede:test", Just 0)
      , (op, Just 0)
      ]
  let slot n =
        trashDir root </> (T.unpack (plId plan) <> "~displaced-" <> show (n :: Int)) </> "landscape" </> "d.jpg"
  -- 槽位 1 被**悬空** junction 占住：doesPathExist 跟随链接答 False（实测），
  -- 只看它会再次选槽 1 → move 必败；须用 lstat 语义补判
  createDirectoryIfMissing True (takeDirectory (slot 1))
  _ <- readCreateProcess (shell ("mklink /J \"" <> slot 1 <> "\" \"" <> (dir </> "no-such-target") <> "\"")) ""
  let env = defaultExecEnv {eeCheckpoint = \c -> when (c == CpCopyAfterFlush) $ writeFile victim "INTERLOPER"}
  r <- execPlan env plan
  case r of
    Right [(_, OFailed _), (_, OConflict m)] -> assertBool ("应改用槽位 2: " <> m) ("~displaced-2" `isInfixOf` m)
    other -> assertFailure (show other)
  readFile victim >>= (@?= "OLDBYTES")
  readFile (slot 2) >>= (@?= "INTERLOPER")
  removeDirectoryLink (slot 1)

caseJunctionFingerprint :: IO ()
caseJunctionFingerprint = withSystemTempDirectory "pm-guard" $ \dir -> do
  let ev = dir </> "ev"
  createDirectoryIfMissing True (ev </> "sub")
  writeFile (ev </> "sub" </> "a.txt") "A"
  fpPlain <- dirFingerprint ev
  -- junction ev\loop → ev（指回祖先）：跟随会无限递归。mklink 是 cmd 内建命令
  -- 且无需特权；整行经 shell 交给 cmd /c——逐参数传递时 process 会给
  -- "mklink" 加引号，cmd 便当作找不到的外部程序。
  _ <- readCreateProcess (shell ("mklink /J \"" <> (ev </> "loop") <> "\" \"" <> ev <> "\"")) ""
  fpLink <- dirFingerprint ev
  assertBool "链接应作为 l 条目计入指纹（与无链接时不同）" (fpLink /= fpPlain)
  fpLink2 <- dirFingerprint ev
  fpLink2 @?= fpLink -- 确定性
  removeDirectoryLink (ev </> "loop")
  fpAfter <- dirFingerprint ev
  fpAfter @?= fpPlain

caseInitPreflight :: IO ()
caseInitPreflight = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let g = tmp </> "gitlib"
  createDirectoryIfMissing True (g </> ".git")
  writeFile (g </> ".gitignore") "_site/\n"
  r1 <- initPreflight g
  assertBool "主库在 git 树内且无 ignore 行应拒绝" (either ("I11" `isInfixOf`) (const False) r1)
  let b = tmp </> "bak"
  createDirectoryIfMissing True b
  now <- getCurrentTime
  writeRootInfo b (RootInfo "bk" RoleBackup now Nothing)
  r2 <- initPreflight b
  assertBool "备份 root 不得作为主库初始化" (either ("拒绝作为主库" `isInfixOf`) (const False) r2)
  let ok = tmp </> "lib"
  createDirectoryIfMissing True ok
  r3 <- initPreflight ok
  r3 @?= Right ()

caseBackupInitPreflight :: IO ()
caseBackupInitPreflight = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let mainP = tmp </> "main"
      cfg = mkCfg mainP Nothing
  createDirectoryIfMissing True mainP
  let g = tmp </> "gitbak"
  createDirectoryIfMissing True g
  writeFile (g </> ".git") "gitdir: ../x/.git/worktrees/gitbak\n" -- .git 文件：旧代码只查目录会漏
  r1 <- backupInitPreflight cfg g
  assertBool ".git 文件也应触发 I11" (either ("I11" `isInfixOf`) (const False) r1)
  r2 <- backupInitPreflight cfg (mainP </> "nested")
  assertBool "与主库嵌套应拒绝" (either ("嵌套" `isInfixOf`) (const False) r2)
  let ok = tmp </> "bak"
  createDirectoryIfMissing True ok
  r3 <- backupInitPreflight cfg ok
  case r3 of
    Right p -> assertBool p ("bak" `isInfixOf` p)
    Left e -> assertFailure e

casePickRootMain :: IO ()
casePickRootMain = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let p = tmp </> "lib"
      cfg = mkCfg p Nothing
  createDirectoryIfMissing True p
  now <- getCurrentTime
  writeRootInfo p (RootInfo "bk" RoleBackup now Nothing)
  r1 <- pickRoot cfg SelMain
  case r1 of
    Left (_, 2) -> pure ()
    other -> assertFailure ("备份 root 伪装主库应拒绝: " <> show other)
  writeRootInfo p (RootInfo "m" RoleMain now Nothing)
  r2 <- pickRoot cfg SelMain
  r2 @?= Right p

caseVaultRequiresMain :: IO ()
caseVaultRequiresMain = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkCfg root (Just vdir)
  createDirectoryIfMissing True (root </> "相册")
  createDirectoryIfMissing True (vdir </> "landscape")
  c1 <- runVaultStatus False cfg -- 无标识
  c1 @?= 2
  now <- getCurrentTime
  writeRootInfo root (RootInfo "bk" RoleBackup now Nothing)
  c2 <- runVaultStatus False cfg -- role 不符
  c2 @?= 2
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  c3 <- runVaultStatus False cfg
  c3 @?= 0

-- ─── P3b-7（四轮） ──────────────────────────────────────────────────────────

casePlanIxValidation :: IO ()
casePlanIxValidation = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  let neg = plan {plItems = [PlanItem (-1) op StPending Nothing]}
      dup = plan {plItems = [PlanItem 0 op StPending Nothing, PlanItem 0 op StPending Nothing]}
  either (const (pure ())) (const (assertFailure "负序号应拒绝")) (validatePlan neg)
  either (const (pure ())) (const (assertFailure "重复序号应拒绝")) (validatePlan dup)
  validatePlan plan @?= Right ()
  r <- execPlan defaultExecEnv dup
  case r of
    Left m -> assertBool m ("重复" `isInfixOf` m)
    Right _ -> assertFailure "重复序号的计划不得执行"
  jEx <- doesFileExist (journalPath root)
  jEx @?= False
  _ <- savePlan dup
  l <- loadPlan root (plId dup)
  either (\m -> assertBool m ("重复" `isInfixOf` m)) (const (assertFailure "重复序号的计划不得装载")) l

caseDoctorMalformedOid :: IO ()
caseDoctorMalformedOid = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      tdir = trashDir root </> T.unpack tpid
  createDirectoryIfMissing True tdir
  writeFile (tdir </> "v.jpg") "V"
  sha <- sha256File (tdir </> "v.jpg")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 手编 oid "<pid>#00"（非规范）：旧代码回退到 "<pid>/" 目录 → 内容相符 →
  -- Q-DONE-LOST Warn → --repair 补记 Done——把畸形记录认证成「已隔离」
  withJournal root $ \j -> jAppend j Barrier (JIntent (tpid <> "#00") (OpQuarantine "v.jpg" sha "t") now)
  rows <- doctorRows root
  assertBool ("expected OID-MALFORMED Bad in " <> show rows) (("OID-MALFORMED", Bad) `elem` rows)
  assertBool "畸形 oid 不得再推导出 Q-DONE-LOST" (not (any ((== "Q-DONE-LOST") . fst) rows))
  _ <- runDoctor root (DoctorOpts False True)
  es <- journalEntries root
  filter isDone es @?= []

caseCorruptRootId :: IO ()
caseCorruptRootId = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let r = tmp </> "r"
  createDirectoryIfMissing True (pmDir r)
  writeFile (pmDir r </> "root-id.json") "{\"id\": \"half-writ"
  st <- readRootState r
  case st of
    RootCorrupt _ -> pure ()
    other -> assertFailure ("expected RootCorrupt, got " <> show other)
  readRootInfo r >>= (@?= Nothing)
  ip <- initPreflight r
  assertBool "损坏标识不得初始化为主库" (either ("无法解析" `isInfixOf`) (const False) ip)
  ev <- ensureVaultRoot r
  assertBool "损坏标识不得改写为 vault" (either ("无法解析" `isInfixOf`) (const False) ev)
  rw <- requireWritable r
  assertBool "损坏标识不可写" (either ("无法解析" `isInfixOf`) (const False) rw)
  now <- getCurrentTime
  cr <- createRootInfo r (RootInfo "new" RoleMain now Nothing)
  assertBool "createRootInfo 不得覆盖既有文件" (either (const True) (const False) cr)
  readFile (pmDir r </> "root-id.json") >>= (@?= "{\"id\": \"half-writ")
  -- 干净目录：首次创建成功，第二次拒绝，身份保持第一次的
  let c = tmp </> "c"
  createDirectoryIfMissing True c
  c1 <- createRootInfo c (RootInfo "one" RoleMain now Nothing)
  c1 @?= Right ()
  c2 <- createRootInfo c (RootInfo "two" RoleMain now Nothing)
  assertBool "第二次创建应拒绝（no-replace）" (either (const True) (const False) c2)
  fmap riId <$> readRootInfo c >>= (@?= Just "one")

caseMainIsBackupWitness :: IO ()
caseMainIsBackupWitness = withSystemTempDirectory "pm-guard" $ \tmp -> do
  -- 同一路径被配置成「主库」，但盘上标识是 RoleBackup（备份盘误配成主库）
  let mainP = tmp </> "disk"
      cfg = mkCfg mainP Nothing
  createDirectoryIfMissing True (mainP </> "成片")
  writeFile (mainP </> "成片" </> "c.jpg") "K7"
  now <- getCurrentTime
  writeRootInfo mainP (RootInfo "bk" RoleBackup now Nothing)
  pid <- newPlanId
  -- afterApply：备份计划收尾不得把 backup-cache 写进这个 root
  afterApply cfg (Plan pid "backup" mainP (Just "bk") now []) 0
  cacheEx <- doesDirectoryExist (pmDir mainP </> "backup-cache")
  cacheEx @?= False
  -- recheckCleanPlan：主库身份不符 → 全部降级，不复验
  let qplan =
        Plan pid "clean-staging" mainP (Just "bk") now
          [PlanItem 0 (OpQuarantine ("To-Be-Sync'd" </> "x.jpg") "s" "clean-staging:test") StPending Nothing]
  plan' <- recheckCleanPlan cfg qplan
  case map piStatus (plItems plan') of
    [StNeedsDecision _] -> pure ()
    other -> assertFailure ("expected demotion, got " <> show other)
  -- trash empty：clean-staging 记录 HELD，文件仍在
  let rel = "p" </> "x.jpg"
  createDirectoryIfMissing True (trashDir mainP </> "p")
  writeFile (trashDir mainP </> rel) "X"
  appendManifest mainP (TrashRecord "x.jpg" rel "aa" "clean-staging:三副本已确认" "p" now)
  code <- runTrash cfg (TrashEmpty True) mainP
  code @?= 1
  doesFileExist (trashDir mainP </> rel) >>= (@?= True)

caseI11AllWriters :: IO ()
caseI11AllWriters = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let v = tmp </> "vault"
  createDirectoryIfMissing True (v </> ".git")
  writeFile (v </> ".gitignore") "_site/\n" -- 无 .pm/ 行
  now <- getCurrentTime
  writeRootInfo v (RootInfo "vr" RoleVault now Nothing)
  -- doctor --repair：C2 类悬挂（dst 完好、Done 丢失）本可补记；I11 不过 → 只报不写
  createDirectoryIfMissing True (v </> "landscape")
  writeFile (v </> "landscape" </> "a.jpg") "A"
  sha <- sha256File (v </> "landscape" </> "a.jpg")
  withJournal v $ \j ->
    jAppend j Barrier (JIntent "20260101-000000-abcdef#0" (OpCopy (tmp </> "ghost.jpg") ("landscape" </> "a.jpg") sha 1 0) now)
  (fs, _) <- runDoctor v (DoctorOpts False True)
  assertBool ("应报 I11 Bad: " <> show [(fRow f, fSeverity f) | f <- fs]) (("I11", Bad) `elem` [(fRow f, fSeverity f) | f <- fs])
  es <- journalEntries v
  filter isDone es @?= []
  -- savePlanAndMaybeRun：计划不落盘
  pid <- newPlanId
  let plan = Plan pid "vault-push" v (Just "vr") now []
  code <- savePlanAndMaybeRun (GoOpts False False) plan
  code @?= 2
  doesFileExist (planPath v pid) >>= (@?= False)
  -- pickRoot --vault 与 requireRole 同样拒绝
  let cfg = mkCfg (tmp </> "main") (Just v)
  pr <- pickRoot cfg SelVault
  case pr of
    Left (m, 2) -> assertBool m ("I11" `isInfixOf` m)
    other -> assertFailure (show other)
  rr <- requireRole RoleVault v
  assertBool "requireRole 应含 I11 守卫" (either ("I11" `isInfixOf`) (const False) rr)

-- ─── P3b-8（五轮） ──────────────────────────────────────────────────────────

caseOpIdTraversal :: IO ()
caseOpIdTraversal = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- pid 必须是生成格式：路径型 / 短名 / 超长序号都不是 pm 生成的
  opIdParts "../../outside#0" @?= Nothing
  opIdParts "..\\..\\outside#0" @?= Nothing
  opIdParts "p#0" @?= Nothing
  opIdParts (tpid <> "#99999999999999999999") @?= Nothing -- 20 位：越过 Int，不 read
  opIdParts (tpid <> "#9223372036854775807") @?= Nothing -- 19 位（maxBound）：封顶 18
  opIdParts (tpid <> "#123456789012345678") @?= Just (tpid, 123456789012345678, SfxPlain)
  quarTrashRel "../../outside#0" "v.jpg" @?= Nothing
  -- doctor：手编 journal 的路径型 oid 不得把 trash 路径推到 root 之外——root 外
  -- 放一份内容相符的文件（trash/../../../outside = 临时根/outside），旧代码会
  -- 判 Q-DONE-LOST Warn 并被 --repair 补记 Done
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True root
  createDirectoryIfMissing True outside
  writeFile (outside </> "v.jpg") "V"
  sha <- sha256File (outside </> "v.jpg")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  withJournal root $ \j -> jAppend j Barrier (JIntent "../../../outside#0" (OpQuarantine "v.jpg" sha "t") now)
  rows <- doctorRows root
  assertBool ("expected OID-MALFORMED Bad in " <> show rows) (("OID-MALFORMED", Bad) `elem` rows)
  assertBool "路径型 oid 不得推导出 Q-DONE-LOST" (not (any ((== "Q-DONE-LOST") . fst) rows))
  _ <- runDoctor root (DoctorOpts False True)
  es <- journalEntries root
  filter isDone es @?= []

caseSlotOccupiedProbe :: IO ()
caseSlotOccupiedProbe = withSystemTempDirectory "pm-guard" $ \dir -> do
  slotOccupied (dir </> "no-such-entry") >>= (@?= False)
  writeFile (dir </> "f.txt") "x"
  slotOccupied (dir </> "f.txt") >>= (@?= True)
  slotOccupied dir >>= (@?= True)
  -- 非法名：doesPathExist 吞错答 False（实测），pathIsSymbolicLink 抛
  -- InvalidArgument（非「不存在」）→ 按占用，宁可跳槽
  slotOccupied (dir </> "bad<name") >>= (@?= True)
  -- 文件当目录用：两个探测都是「不存在」→ 空槽
  slotOccupied (dir </> "f.txt" </> "child") >>= (@?= False)

caseCleanImportGuardFirst :: IO ()
caseCleanImportGuardFirst = withSystemTempDirectory "pm-guard" $ \tmp -> do
  -- 主路径是 RoleBackup root，索引存在、暂存区为空（新鲜）。旧次序：runClean 先
  -- 读索引 → 备份发现失败 → exit 1；runImport 走到「暂存区无需归档」exit 0。
  -- 新次序：身份校验先行 → 两者都 exit 2，且不落任何计划。
  let mainP = tmp </> "disk"
      cfg = mkCfg mainP Nothing
  createDirectoryIfMissing True mainP
  now <- getCurrentTime
  writeRootInfo mainP (RootInfo "bk" RoleBackup now Nothing)
  saveCatalog mainP (mkCat [])
  c1 <- runClean (GoOpts False False) cfg
  c1 @?= 2
  c2 <- runImport (GoOpts False False) cfg
  c2 @?= 2
  doesDirectoryExist (pmDir mainP </> "plans") >>= (@?= False)
  -- 同一 fixture 换成 RoleMain：证明上面的 exit 2 确由身份校验产生（而非索引/暂存）
  writeRootInfo mainP (RootInfo "m" RoleMain now Nothing)
  c3 <- runClean (GoOpts False False) cfg
  c3 @?= 1 -- 备份 root 未登记 → 无法确认第三副本
  c4 <- runImport (GoOpts False False) cfg
  c4 @?= 0 -- 暂存区无需归档

caseFixtureKeepsCorrupt :: IO ()
caseFixtureKeepsCorrupt = withSystemTempDirectory "pm-guard" $ \tmp -> do
  let r = tmp </> "r"
  createDirectoryIfMissing True (pmDir r)
  writeFile (pmDir r </> "root-id.json") "{\"id\": \"half-writ"
  res <- try (ensureTestRoot RoleMain r) :: IO (Either SomeException (Maybe T.Text))
  either (const (pure ())) (\v -> assertFailure ("fixture 不得把损坏标识当缺席: " <> show v)) res
  readFile (pmDir r </> "root-id.json") >>= (@?= "{\"id\": \"half-writ")
  -- 缺席 → 建立（no-replace）；再次调用沿用既有标识，不改写 role
  let c = tmp </> "c"
  createDirectoryIfMissing True c
  ensureTestRoot RoleBackup c >>= (@?= Just "test-root")
  fmap riRole <$> readRootInfo c >>= (@?= Just RoleBackup)
  ensureTestRoot RoleMain c >>= (@?= Just "test-root")
  fmap riRole <$> readRootInfo c >>= (@?= Just RoleBackup)
