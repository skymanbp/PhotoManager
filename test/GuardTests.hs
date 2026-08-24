{-# LANGUAGE OverloadedStrings #-}

-- | P3b-6：codex 三轮复审收口用例——A1 严格 opId\/planId 解析与位移槽位、
-- A2 通配符反规则、A3 匿名 root 与 role 改写、B1 requireMain 四入口、
-- init\/backup init 守卫、dirFingerprint 不跟随 reparse point。
module GuardTests (guardTests) where

import Control.Monad (forM_, when)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Commands (RootSel (..), backupInitPreflight, initPreflight, pickRoot)
import Pm.Config (Config (..), pmDir, writeRootInfo)
import Pm.Exec
import Pm.GitGuard (vaultIgnoreGuard)
import Pm.Hash (sha256File)
import Pm.Journal (journalPath)
import Pm.Op
import Pm.Plan
import Pm.Trash (quarTrashRel, trashDir)
import Pm.Types (RootInfo (..), RootRole (..))
import Pm.Vault (runVaultStatus)
import TestUtil

guardTests :: TestTree
guardTests =
  testGroup
    "P3b-6 守卫与解析（codex 三轮）"
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
  opIdParts "p#0~d0" @?= Nothing -- N ≥ 1
  opIdParts "p#0~x" @?= Nothing
  opIdParts "p#" @?= Nothing
  opIdParts "p#0#1" @?= Nothing
  quarTrashRel "p#0~d2" "v.jpg" @?= ("p~displaced-2" </> "v.jpg")
  quarTrashRel "p#0~r" "v.jpg" @?= ("p" </> "v.jpg")
  quarTrashRel "p#0" ("a" </> "v.jpg") @?= ("p" </> "a" </> "v.jpg")

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
