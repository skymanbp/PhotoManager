{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Shared fixtures and helpers for the pm test suite.
module TestUtil
  ( mkCopyOp
  , mkPlanIO
  , mkGroupPlanIO
  , ensureTestRoot
  , tpid
  , tpOid
  , injectAt
  , runCrash
  , execOk
  , execOkWith
  , doctorRows
  , journalEntries
  , isIntent
  , isDone
  , isClean
  , truncateJournalTo
  , t0
  , mkE
  , mkCat
  , scanQuiet
  , elemSubstr
  , pad2
  , captureStdout
  ) where

import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Control.Monad (forM_, when)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (..), hClose, hFlush, hGetContents, hSetEncoding, openFile, stdout, utf8)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty.HUnit

import Pm.Config (RootIdState (..), createRootInfo, readRootState)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity, runDoctor)
import Pm.Exec
import Pm.Hash
import Pm.Journal
import Pm.Op
import Pm.Plan
import Pm.Scan (ScanOpts (..), ScanResult (..), scanRoot)
import Pm.Types

-- | 造一个 src 文件并生成对应的 Copy op（含真实前置条件）。
mkCopyOp :: FilePath -> String -> FilePath -> IO Op
mkCopyOp srcAbs content dstRel = do
  createDirectoryIfMissing True (takeDirectory srcAbs)
  writeFile srcAbs content
  sha <- sha256File srcAbs
  s <- statSnap srcAbs
  pure (OpCopy srcAbs dstRel sha (ssSize s) (ssMtimeNs s))

-- | 测试 root 身份（P3b-6 复审 A3：内核不再放行匿名 root）。root 目录已存在
-- → 确保带 role 标识并返回其 UUID（已有标识则沿用，不改写 role）；目录不
-- 存在（纯计划 fixture，如 \"R:\"）→ Nothing，计划 rootId 留空——这类计划
-- 从不执行。P3b-8 复审 minor：走 'readRootState' + 'createRootInfo'（生产
-- 路径，no-replace）——损坏的标识是测试要保留的状态，fixture 不得把它当缺席
-- 覆盖掉（此前 readRootInfo == Nothing 即 writeRootInfo）。
ensureTestRoot :: RootRole -> FilePath -> IO (Maybe Text)
ensureTestRoot role root = do
  ex <- doesDirectoryExist root
  if not ex
    then pure Nothing
    else do
      st <- readRootState root
      case st of
        RootPresent i -> pure (Just (riId i))
        RootCorrupt e -> assertFailure ("fixture: root-id 损坏，不覆盖（" <> e <> "）")
        RootUntrusted m -> assertFailure ("fixture: .pm 不可信（" <> m <> "）")
        RootAbsent -> do
          now <- getCurrentTime
          r <- createRootInfo root (RootInfo "test-root" role now Nothing)
          case r of
            Left e -> assertFailure ("fixture: createRootInfo 失败: " <> e)
            Right () -> pure (Just "test-root")

-- | 测试用的合法 planId 与其 opId（P3b-8：'opIdParts' 只认生成格式，手编
-- journal 的 fixture 不能再用 \"p#0\" 之类短 pid）。
tpid :: Text
tpid = "20260101-000000-abcdef"

tpOid :: Int -> Text
tpOid = opId tpid

mkPlanIO :: FilePath -> [Op] -> IO Plan
mkPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  rid <- ensureTestRoot RoleMain root
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plRootId = rid
      , plCreated = now
      , plItems = [PlanItem i op StPending Nothing | (i, op) <- zip [0 ..] ops]
      }

-- | 带复合组的测试计划（P2.1 组语义测试用）。
mkGroupPlanIO :: FilePath -> [(Op, Maybe Int)] -> IO Plan
mkGroupPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  rid <- ensureTestRoot RoleMain root
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plRootId = rid
      , plCreated = now
      , plItems = [PlanItem i op StPending g | (i, (op, g)) <- zip [0 ..] ops]
      }

injectAt :: Checkpoint -> ExecEnv
injectAt cp =
  defaultExecEnv {eeCheckpoint = \c -> when (c == cp) (throwIO (userError "inject-crash"))}

-- | 注入崩溃：期望异常逃逸（= 进程死亡模型）。
runCrash :: ExecEnv -> Plan -> IO ()
runCrash env plan = do
  r <- try (execPlan env plan) :: IO (Either SomeException (Either String [(PlanItem, ItemOutcome)]))
  case r of
    Left _ -> pure ()
    Right _ -> assertFailure "expected injected crash to escape execPlan"

execOk :: Plan -> IO [(PlanItem, ItemOutcome)]
execOk = execOkWith defaultExecEnv

-- | 同上，但由调用方给 'ExecEnv'。需要它的是**要屏障的计划种类**
-- （'Pm.Plan.kindNeedsBarrier'）：内核对缺席的屏障整批拒绝，所以考 Op 机制
-- 而非考屏障的用例必须显式挂一个放行屏障 @Just pure@，写出来而不是默认得到。
execOkWith :: ExecEnv -> Plan -> IO [(PlanItem, ItemOutcome)]
execOkWith env plan = do
  r <- execPlan env plan
  case r of
    Left e -> assertFailure ("lock busy unexpectedly: " <> e) >> pure []
    Right rs -> pure rs

doctorRows :: FilePath -> IO [(String, Severity)]
doctorRows root = do
  (fs, _) <- runDoctor root (DoctorOpts False False)
  pure [(fRow f, fSeverity f) | f <- fs]

journalEntries :: FilePath -> IO [JEntry]
journalEntries root = fst <$> readJournal root

isIntent, isDone, isClean :: JEntry -> Bool
isIntent JIntent {} = True; isIntent _ = False
isDone JDone {} = True; isDone _ = False
isClean JCleanShutdown {} = True; isClean _ = False

-- 掉电模拟：把 journal 重写为给定条目（= 尾部未 fsync 丢失）。
truncateJournalTo :: FilePath -> [JEntry] -> IO ()
truncateJournalTo root es = do
  removeJournal
  withJournal root $ \j -> forM_ es (jAppend j Buffered)
 where
  removeJournal = do
    ex <- doesFileExist (journalPath root)
    when ex (writeFile (journalPath root) "")

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

mkE :: FilePath -> String -> Entry
mkE p sha = Entry p 1 0 (T.pack sha) KindPhoto Nothing

mkCat :: [Entry] -> Catalog
mkCat es = Catalog "test-root" t0 (entryMap es)

scanQuiet :: String -> FilePath -> IO Catalog
scanQuiet rid root = srCatalog <$> scanRoot (ScanOpts 1 False) Nothing (T.pack rid) root

elemSubstr :: String -> String -> Bool
elemSubstr needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]

pad2 :: Int -> String
pad2 n = if n < 10 then '0' : show n else show n

-- | 进程级 stdout 重定向（原在 SortTests，三十轮起多个模块要用，移到这里）。
--
-- **两端都必须显式 UTF-8**：本机 locale 是 GBK，而 pm 的输出里有 U+26A0(⚠)
-- 与 U+2717(✗)，临时文件句柄按 locale 编码会直接抛 commitBuffer。tasty 已由
-- Spec.hs 钉成 NumThreads 1——重定向的是**进程级** stdout，并行会互相污染。
captureStdout :: IO a -> IO (String, a)
captureStdout act = withSystemTempDirectory "pm-cap" $ \dir -> do
  let fp = dir </> "out.txt"
  h <- openFile fp WriteMode
  hSetEncoding h utf8
  old <- hDuplicate stdout
  hDuplicateTo h stdout
  -- hDuplicate/hDuplicateTo 造出的句柄用的是 **locale** 编码，会把
  -- setupConsole 设好的 utf8 抹掉——替换后和还原后都要显式钉回去，
  -- 否则 pm 输出里的 ✗/⚠ 在这里、以及**后续用例**里都会炸。
  hSetEncoding stdout utf8
  a <- act `finally` (hFlush stdout >> hDuplicateTo old stdout >> hSetEncoding stdout utf8 >> hClose old)
  hClose h -- 必须先关：GHC 句柄锁不许「已开写」的文件同时被开读
  txt <- bracket (openFile fp ReadMode) hClose $ \rh -> do
    hSetEncoding rh utf8
    t <- hGetContents rh
    length t `seq` pure t
  pure (txt, a)
