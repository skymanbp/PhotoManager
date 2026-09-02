{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 1.1.2 瞬断保护（"Pm.Removable"，DESIGN §6.4 末段）。盘的替身 = @.pm\/root-id.json@：
-- 「拔盘」把它挪走、「插回」挪回来；插回由打印口触发（recover 一说「等它回来」
-- 就 50 ms 后插回），时序不靠计时器猜——等待路径必然真的走到。介质读错的替身
-- = 从 'eeCheckpoint' 抛 EINVAL 型 'IOException'（真实盘掉线时 hPutBuf \/
-- FlushFileBuffers 逃顶的形态）。每个「开」用例配一个「关」（'noDriveWait' \/
-- 'runDoctor'）对偶：关闭 = 1.1.1 行为，异常照旧逃顶——判别突变的红绿配对。
module RemovableTests (removableTests) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless, void, when)
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Time (addUTCTime, getCurrentTime)
import GHC.IO.Exception (IOErrorType (..), IOException (..))
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile, setModificationTime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), runDoctor, runDoctorWith)
import Pm.Exec
import Pm.Hash (sha256File)
import Pm.Journal (JEntry (..))
import Pm.Op
import Pm.Plan
import Pm.Removable
import Pm.Scan (ScanOpts (..), ScanResult (..))
import Pm.Types
import TestUtil

removableTests :: TestTree
removableTests =
  testGroup
    "瞬断保护 (1.1.2 Pm.Removable)"
    [ testCase "withDriveRetry：确定性异常（userError / 权限拒绝）立刻原样抛出，不等、不重试、不出声" caseDeterministic
    , testCase "withDriveRetry：盘在、EINVAL 型读错 → 按瞬断短停重试，第二次成功" caseHiccup
    , testCase "withDriveRetry：盘掉线 → 等它回来再重试；等不到则抛原异常" caseDropped
    , testCase "对偶：noDriveWait 下瞬断异常照旧逃顶（关闭 = 1.1.1 行为）" caseOff
    , testCase "execPlanRetry：Copy 落位后写 Done 前盘掉线 → 自愈补 Done、续跑不重做已完成项、journal 每 oid 一个 Done、doctor 干净" caseExecResume
    , testCase "execPlanRetry：supersede 组内 Copy 写 tmp 时瞬断 → 整组重跑，隔离项走 resume 分支、Copy 落位、trash 只有一份" caseExecGroupRerun
    , testCase "scanRootRetry：起手盘不在 → 等它回来照常扫完；持续性读错（ACL）有界重试后如实报读错" caseScanRetry
    , testCase "runDoctorWith --deep：盘不在时不交假结论（DEEP-SKIPPED / 消失）——等盘回来重跑；对偶 runDoctor 照旧 DEEP-SKIPPED Bad" caseDoctorDeepDrop
    ]

-- ─── 夹具 ────────────────────────────────────────────────────────────────────

idPath, idAway :: FilePath -> FilePath
idPath root = root </> ".pm" </> "root-id.json"
idAway root = root </> ".pm" </> "root-id.away"

unplug, plug :: FilePath -> IO ()
unplug root = renameFile (idPath root) (idAway root)
plug root = renameFile (idAway root) (idPath root)

-- | 测试策略：不冷却、每 20 ms 探一次、最多 3 次；打印口收进 IORef，并在
-- recover 宣布「等它回来」时 50 ms 后插回盘。
mkDw :: FilePath -> IO (DriveWait, IO [String])
mkDw root = do
  logRef <- newIORef []
  let say l = do
        modifyIORef' logRef (l :)
        when ("等它回来" `isInfixOf` l) $ void (forkIO (threadDelay 50000 >> plug root))
  pure (DriveWait {dwWaitSecs = 10, dwCooldownSecs = 0, dwAttempts = 3, dwPollMs = 20, dwSay = say}, reverse <$> readIORef logRef)

transient :: String -> IOException
transient what = IOError Nothing InvalidArgument what "invalid argument (模拟瞬断)" Nothing Nothing

mkRoot :: FilePath -> IO FilePath
mkRoot dir = do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  _ <- mkPlanIO root [] -- 建 root 身份（盘的替身）
  pure root

landedOut :: ItemOutcome -> Bool
landedOut ODone {} = True
landedOut _ = False

-- ─── withDriveRetry ──────────────────────────────────────────────────────────

caseDeterministic :: IO ()
caseDeterministic = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  (dw, logOf) <- mkDw root
  calls <- newIORef (0 :: Int)
  let attempt e = try (withDriveRetry dw root "t" (modifyIORef' calls (+ 1) >> throwIO e)) :: IO (Either IOException ())
  r1 <- attempt (userError "inject-crash")
  either (\e -> assertBool (show e) ("inject-crash" `isInfixOf` show e)) (const (assertFailure "userError 应原样抛出")) r1
  r2 <- attempt (IOError Nothing PermissionDenied "t" "denied" Nothing Nothing)
  either (\e -> ioe_type e @?= PermissionDenied) (const (assertFailure "权限拒绝应原样抛出")) r2
  readIORef calls >>= (@?= 2)
  logOf >>= (@?= [])

caseHiccup :: IO ()
caseHiccup = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  (dw, logOf) <- mkDw root
  calls <- newIORef (0 :: Int)
  v <- withDriveRetry dw root "t" $ do
    n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
    when (n == 1) (throwIO (transient "hGetBuf"))
    pure (42 :: Int)
  v @?= 42
  readIORef calls >>= (@?= 2)
  ls <- logOf
  length ls @?= 1
  assertBool (show ls) (all ("盘仍在" `isInfixOf`) ls)

caseDropped :: IO ()
caseDropped = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  (dw, logOf) <- mkDw root
  calls <- newIORef (0 :: Int)
  unplug root
  v <- withDriveRetry dw root "t" $ do
    n <- atomicModifyIORef' calls (\c -> (c + 1, c + 1))
    when (n == 1) (throwIO (transient "hPutBuf"))
    pure (7 :: Int)
  v @?= 7
  readIORef calls >>= (@?= 2)
  ls <- logOf
  assertBool (show ls) (any ("掉线" `isInfixOf`) ls && any ("盘回来了" `isInfixOf`) ls)
  driveOk root >>= (@?= True)
  -- 等不到（等待 0 s、无人插回）→ 抛原异常，调用次数 1
  unplug root
  calls2 <- newIORef (0 :: Int)
  r <- try (withDriveRetry dw {dwWaitSecs = 0, dwSay = \_ -> pure ()} root "t" (modifyIORef' calls2 (+ 1) >> throwIO (transient "hPutBuf"))) :: IO (Either IOException ())
  either (\e -> ioe_type e @?= InvalidArgument) (const (assertFailure "等不到盘应抛原异常")) r
  readIORef calls2 >>= (@?= 1)
  plug root

caseOff :: IO ()
caseOff = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  calls <- newIORef (0 :: Int)
  r <- try (withDriveRetry noDriveWait root "t" (modifyIORef' calls (+ 1) >> throwIO (transient "hPutBuf"))) :: IO (Either IOException ())
  either (\e -> ioe_type e @?= InvalidArgument) (const (assertFailure "关闭时应逃顶")) r
  readIORef calls >>= (@?= 1)

-- ─── execPlanRetry ───────────────────────────────────────────────────────────

caseExecResume :: IO ()
caseExecResume = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  ops <- mapM (\i -> mkCopyOp (dir </> ("s" <> show i <> ".jpg")) ("DATA-" <> show i) ("相册" </> ("a" <> show i <> ".jpg"))) [0 .. 2 :: Int]
  plan <- mkPlanIO root ops
  (dw, logOf) <- mkDw root
  moves <- newIORef (0 :: Int)
  progress <- newIORef (Map.empty :: Map.Map Int Int)
  let env =
        defaultExecEnv
          { eeCheckpoint = \c -> when (c == CpCopyAfterMove) $ do
              n <- atomicModifyIORef' moves (\k -> (k + 1, k + 1))
              -- 第二项：rename 已落位、Done 未写——真实盘 C2 洞的形态；盘同时掉线
              when (n == 2) (unplug root >> throwIO (transient "FlushFileBuffers"))
          , eeProgress = \it _ -> modifyIORef' progress (Map.insertWith (+) (piIx it) 1)
          }
      heal = void (runDoctorWith dw root (DoctorOpts False True))
  r <- execPlanRetry dw heal env plan
  outs <- either (\e -> assertFailure e >> pure []) pure r
  map (piIx . fst) outs @?= [0, 1, 2]
  assertBool (show outs) (all (landedOut . snd) outs)
  -- 已完成的项不重做：0 与 2 各执行一次；1 由 journal（doctor 补的 Done）结算，没有再执行
  readIORef progress >>= (@?= Map.fromList [(0, 1), (2, 1)])
  es <- journalEntries root
  length [() | JDone {jeOpId = o} <- es, o == opId (plId plan) 1] @?= 1
  rows <- doctorRows root
  [x | x@(t, _) <- rows, t `elem` ["C1", "C2", "C5"]] @?= []
  mapM_ (\i -> readFile (root </> "相册" </> ("a" <> show i <> ".jpg")) >>= (@?= ("DATA-" <> show i))) [0 .. 2 :: Int]
  -- 按 journal 结算的结局与内核落位时同形：catalog 回写得到三条、sha 与计划一致
  now <- getCurrentTime
  let cat = updateCatalog now outs (Catalog "test-root" now Map.empty)
  map enSha (Map.elems (catEntries cat)) @?= map opSha ops
  ls <- logOf
  assertBool (show ls) (any ("从中断处继续" `isInfixOf`) ls && any ("盘回来了" `isInfixOf`) ls)

caseExecGroupRerun :: IO ()
caseExecGroupRerun = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  let victimRel = "相册" </> "v.jpg"
  createDirectoryIfMissing True (root </> "相册")
  writeFile (root </> victimRel) "OLD"
  vsha <- sha256File (root </> victimRel)
  cop <- mkCopyOp (dir </> "new.jpg") "NEW" victimRel
  plan <- mkGroupPlanIO root [(OpQuarantine victimRel vsha "supersede:test", Just 1), (cop, Just 1)]
  (dw, _) <- mkDw root
  progress <- newIORef (Map.empty :: Map.Map Int Int)
  fired <- newIORef False
  let env =
        defaultExecEnv
          { eeCheckpoint = \c -> when (c == CpCopyAfterTmp) $ do
              f <- readIORef fired
              unless f (writeIORef fired True >> unplug root >> throwIO (transient "hPutBuf"))
          , eeProgress = \it _ -> modifyIORef' progress (Map.insertWith (+) (piIx it) 1)
          }
      heal = void (runDoctorWith dw root (DoctorOpts False True))
  r <- execPlanRetry dw heal env plan
  outs <- either (\e -> assertFailure e >> pure []) pure r
  assertBool (show outs) (all (landedOut . snd) outs)
  readFile (root </> victimRel) >>= (@?= "NEW")
  -- 隔离项第一场已执行、第二场走 resume 分支（victim 不在原位、trash 内容相符 → 视同完成）
  -- ——执行计数 2；Copy 第一场没走完（无进度），第二场落位
  readIORef progress >>= (@?= Map.fromList [(0, 2), (1, 1)])
  case outs of
    ((_, ODone _ _ (Just tr)) : _) -> do
      doesFileExist (root </> ".pm" </> "trash" </> tr) >>= (@?= True)
      readFile (root </> ".pm" </> "trash" </> tr) >>= (@?= "OLD")
    other -> assertFailure ("隔离项应带 trashRel: " <> show other)
  rows <- doctorRows root
  [x | x@(t, _) <- rows, t `elem` ["C1", "C2", "C5", "Q-DONE-LOST", "Q1", "Q2"]] @?= []

-- ─── scan / doctor ───────────────────────────────────────────────────────────

caseScanRetry :: IO ()
caseScanRetry = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  createDirectoryIfMissing True (root </> "Raw")
  now <- getCurrentTime
  mapM_
    ( \n -> do
        writeFile (root </> "Raw" </> n) n
        -- mtime 推到一小时前：刚写的文件落在 racy 窗口内（statHitStable），复用断言要的是稳定条目
        setModificationTime (root </> "Raw" </> n) (addUTCTime (-3600) now)
    )
    ["a.arw", "b.arw", "c.arw"]
  (dw, logOf) <- mkDw root
  -- ① 起手盘不在：ensureDrive 等它回来，扫描照常完成、结论干净
  unplug root
  r1 <- scanRootRetry dw (ScanOpts 1 False) Nothing "test-root" root
  srErrors r1 @?= []
  srHashed r1 @?= 3
  logOf >>= \ls -> assertBool (show ls) (any ("盘回来了" `isInfixOf`) ls)
  -- ② 持续性读错（ACL 拒读、盘在）：有界重试（3 次）后如实返回读错，不吞、不死循环；
  --    重扫拿上一遍的 catalog 复用，a/c 不重 hash
  (dw2, logOf2) <- mkDw root
  r2 <- withDenyAll (root </> "Raw" </> "b.arw") (scanRootRetry dw2 (ScanOpts 1 False) (Just (srCatalog r1)) "test-root" root)
  length (srErrors r2) @?= 1
  srHashed r2 @?= 0
  srReused r2 @?= 2
  logOf2 >>= \ls -> length (filter ("盘仍在" `isInfixOf`) ls) @?= 3

caseDoctorDeepDrop :: IO ()
caseDoctorDeepDrop = withSystemTempDirectory "pm-rm" $ \dir -> do
  root <- mkRoot dir
  createDirectoryIfMissing True (root </> "Raw")
  mapM_ (\n -> writeFile (root </> "Raw" </> n) n) ["a.arw", "b.arw"]
  cat <- scanQuiet "test-root" root
  saveCatalog root cat
  (dw, logOf) <- mkDw root
  unplug root
  (fs, code) <- runDoctorWith dw root (DoctorOpts True False)
  code @?= 0
  [fRow f | f <- fs, fSeverity f >= Warn] @?= []
  assertBool (show (map fRow fs)) ("DEEP-DONE" `elem` map fRow fs)
  logOf >>= \ls -> assertBool (show ls) (any ("盘回来了" `isInfixOf`) ls)
  -- 对偶（关闭保护 = 1.1.1 行为）：盘不在时 --deep 只能报 DEEP-SKIPPED Bad
  unplug root
  (fs0, code0) <- runDoctor root (DoctorOpts True False)
  plug root
  code0 @?= 1
  assertBool (show (map fRow fs0)) ("DEEP-SKIPPED" `elem` map fRow fs0)
