{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Shared fixtures and helpers for the pm test suite.
module TestUtil
  ( mkCopyOp
  , mkPlanIO
  , mkGroupPlanIO
  , injectAt
  , runCrash
  , execOk
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
  ) where

import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, when)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import Test.Tasty.HUnit

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

mkPlanIO :: FilePath -> [Op] -> IO Plan
mkPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plRootId = Nothing -- 测试临时 root 无标识；execPlan 仅在 eeExpectRootId 给定时校验
      , plCreated = now
      , plItems = [PlanItem i op StPending Nothing | (i, op) <- zip [0 ..] ops]
      }

-- | 带复合组的测试计划（P2.1 组语义测试用）。
mkGroupPlanIO :: FilePath -> [(Op, Maybe Int)] -> IO Plan
mkGroupPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plRootId = Nothing
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
execOk plan = do
  r <- execPlan defaultExecEnv plan
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
