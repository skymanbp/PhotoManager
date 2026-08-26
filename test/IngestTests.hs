{-# LANGUAGE OverloadedStrings #-}

-- | @pm vault ingest@（P6-D）：批量入库的机械层。这里钉四件事——两份计划的
-- 形状、fail-closed 校验、I5 冲突分流、以及 **I7 来源登记**（主库 journal 的
-- Intent 带库外 srcAbs，就是 inbox-origin 记录本体）。
module IngestTests (ingestTests) where

import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (isAbsolute, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Cli (executePlanNow)
import Pm.Config (Config (..), writeRootInfo)
import Pm.Ingest (runVaultIngest)
import Pm.Op
import Pm.Plan
import Pm.Types (RootInfo (..), RootRole (..))
import TestUtil (isIntent, journalEntries, t0)
import Pm.Journal (JEntry (..))

ingestTests :: TestTree
ingestTests =
  testGroup
    "P6-D pm vault ingest（两份计划 · fail-closed 校验 · I5 分流 · I7 来源登记）"
    [ testCase "两份计划：主库 相册/ 在前、vault <类目>/ 在后，kind=vault-ingest 无屏障" caseIngestPlans
    , testCase "fail-closed：类目/源缺失/重名/非 jpg —— 全部错误一次列完，一份计划不出" caseIngestValidation
    , testCase "I5 分流：同名不同内容 → NEEDS-DECISION；同名同内容 → PENDING（执行期 SKIP）" caseIngestConflict
    , testCase "端到端：相册与类目各落一份、源零改动（拷贝不移动）、主库 journal 记下库外 srcAbs（I7）" caseIngestE2E
    ]

-- | 临时主库 + vault + 一个 _inbox。回调收 (cfg, inbox 目录)。
withIngestEnv :: (Config -> FilePath -> IO ()) -> IO ()
withIngestEnv k = withSystemTempDirectory "pm-ingest" $ \tmp -> do
  let main' = tmp </> "main"
      vault = tmp </> "vault"
      inbox = tmp </> "_inbox"
  createDirectoryIfMissing True main'
  createDirectoryIfMissing True (vault </> "landscape")
  createDirectoryIfMissing True inbox
  now <- getCurrentTime
  writeRootInfo main' (RootInfo "im" RoleMain now Nothing)
  -- vault 的 root-id 由 ensureVaultRoot 在首次 ingest 时建（非 git 树，I11 平凡通过）
  k (Config main' (Just vault) Nothing Nothing Nothing Nothing) inbox

capturePlans :: IO (Plan -> IO Int, IO [Plan])
capturePlans = do
  ref <- newIORef []
  pure (\p -> modifyIORef ref (<> [p]) >> pure 0, readIORef ref)

caseIngestPlans :: IO ()
caseIngestPlans = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "AAA"
  writeFile (inbox </> "b.jpg") "BBB"
  (runP, gotP) <- capturePlans
  c <- runVaultIngest runP "landscape" [inbox </> "a.jpg", inbox </> "b.jpg"] cfg
  c @?= 0
  ps <- gotP
  map plKind ps @?= ["vault-ingest", "vault-ingest"]
  -- 屏障分类器：拷贝型计划不需要执行期组屏障
  kindBarrier "vault-ingest" @?= Nothing
  case ps of
    [pm', pv] -> do
      plRootPath pm' @?= cfgMainPath cfg
      Just (plRootPath pv) @?= cfgVaultPath cfg
      map (opDstRel . piOp) (plItems pm') @?= ["相册" </> "a.jpg", "相册" </> "b.jpg"]
      map (opDstRel . piOp) (plItems pv) @?= ["landscape" </> "a.jpg", "landscape" </> "b.jpg"]
      assertBool "全部 PENDING" (all ((== StPending) . piStatus) (plItems pm' <> plItems pv))
      -- src 是绝对路径（库外）——I7 的来源信息在 Op 里
      assertBool "src 绝对" (all (isAbsolute . opSrcAbs . piOp) (plItems pm'))
    other -> assertFailure ("应恰好两份计划，得到 " <> show (length other))

caseIngestValidation :: IO ()
caseIngestValidation = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "AAA"
  (runP, gotP) <- capturePlans
  -- 类目不存在
  runVaultIngest runP "scenery" [inbox </> "a.jpg"] cfg >>= (@?= 2)
  -- 空文件列表
  runVaultIngest runP "landscape" [] cfg >>= (@?= 2)
  -- 源缺失
  runVaultIngest runP "landscape" [inbox </> "ghost.jpg"] cfg >>= (@?= 2)
  -- 同名两份（不同目录）
  createDirectoryIfMissing True (inbox </> "sub")
  writeFile (inbox </> "sub" </> "a.jpg") "OTHER"
  runVaultIngest runP "landscape" [inbox </> "a.jpg", inbox </> "sub" </> "a.jpg"] cfg >>= (@?= 2)
  -- 非 jpg
  writeFile (inbox </> "x.png") "PNG"
  runVaultIngest runP "landscape" [inbox </> "x.png"] cfg >>= (@?= 2)
  ps <- gotP
  length ps @?= 0

caseIngestConflict :: IO ()
caseIngestConflict = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "NEW-BYTES"
  writeFile (inbox </> "b.jpg") "SAME"
  -- 相册 已有同名不同内容的 a.jpg；vault 已有同名同内容的 b.jpg
  createDirectoryIfMissing True (cfgMainPath cfg </> "相册")
  writeFile (cfgMainPath cfg </> "相册" </> "a.jpg") "OLD-BYTES"
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> writeFile (v </> "landscape" </> "b.jpg") "SAME"
  (runP, gotP) <- capturePlans
  c <- runVaultIngest runP "landscape" [inbox </> "a.jpg", inbox </> "b.jpg"] cfg
  c @?= 0
  ps <- gotP
  case ps of
    [pm', pv] -> do
      [piStatus it | it <- plItems pm', takeFileName (opDstRel (piOp it)) == "a.jpg"]
        @?= [StNeedsDecision "目标已存在且内容不同（I5）→ pm resolve --keep src|dst|both"]
      [piStatus it | it <- plItems pv, takeFileName (opDstRel (piOp it)) == "b.jpg"]
        @?= [StPending]
    _ -> assertFailure "应恰好两份计划"

caseIngestE2E :: IO ()
caseIngestE2E = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "PHOTO-A"
  c <- runVaultIngest (\p -> savePlan p >> executePlanNow cfg p) "landscape" [inbox </> "a.jpg"] cfg
  c @?= 0
  readFile (cfgMainPath cfg </> "相册" </> "a.jpg") >>= (@?= "PHOTO-A")
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> readFile (v </> "landscape" </> "a.jpg") >>= (@?= "PHOTO-A")
  -- 拷贝不移动：源零改动
  readFile (inbox </> "a.jpg") >>= (@?= "PHOTO-A")
  -- I7 来源登记：主库 journal 的 Intent 带库外 srcAbs
  es <- journalEntries (cfgMainPath cfg)
  let srcs = [opSrcAbs op | e@(JIntent _ op _) <- es, isIntent e]
  srcs @?= [inbox </> "a.jpg"]
  seq t0 (pure ())
