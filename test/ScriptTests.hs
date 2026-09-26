{-# LANGUAGE OverloadedStrings #-}

-- | @scripts/@ 下的 Python 辅助脚本（备份盘核验内核 backup_verify 与两支入口、发布脱敏扫描
-- leakscan）的钉针。真跑脚本：CI 的测试 job 装了 python（build.yml 的 setup-python），本机走
-- 'findPython'（@PM_PYTHON@ → PATH）；找不到就失败，不是 skip。脚本输出写进文件再按 UTF-8 宽松
-- 解码读回——不经管道解码，runner 的代码页与 @PYTHONUTF8@ 怎么组合都不影响断言。
-- 编号对 docs/reviews/2026-09-25-full-debug-findings.json。
module ScriptTests (scriptTests) where

import Data.Aeson (FromJSON (..), decode, encode, withObject, (.:), (.:?))
import qualified Data.ByteString.Lazy as BSL
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (..), withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Convert (findPython)
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), planPath)
import TestUtil (readUtf8, writeF)

scriptTests :: TestTree
scriptTests =
  testGroup
    "scripts/ 辅助脚本"
    [ testCase "#20 #23 核验途中盘没回来：已核出的结果照写 --out、没读到的记进 bad、退出码 3；隔离件的「不在」只在盘在时算，盘不在记「没核」而不是 0/N" caseDriveGaveUp
    , testCase "#22 verify_backup_dst 只核 pending 条目：pm resolve 跳过 / 待裁决的 copy 与隔离件 Exec 不执行，不再被报成缺失" casePendingOnly
    , testCase "#21 leakscan 用法错与读不到退 2（与命中 1、干净 0 分得开）：--extra 在末尾 / 给空串、没给文件、文件不存在；命中优先" caseLeakscanUsage
    ]

-- | 跑 python（参数原样）；stdout 与 stderr 合写进 @dir\/py.log@，返回 (退出码, 日志)。
runPy :: FilePath -> [String] -> IO (Int, String)
runPy dir args = do
  exe <- findPython >>= either (\m -> assertFailure m >> pure "") pure
  let logF = dir </> "py.log"
  code <- withBinaryFile logF WriteMode $ \h -> do
    (_, _, _, ph) <- createProcess (proc exe args) {std_in = NoStream, std_out = UseHandle h, std_err = UseHandle h}
    waitForProcess ph
  out <- readUtf8 logF
  pure (case code of ExitSuccess -> 0; ExitFailure n -> n, out)

planId :: T.Text
planId = "20260926-120000-abcdef"

-- | 备份盘夹具：@.pm\/root-id.json@ + 一份按 pm 自己的编码器落盘的计划（不手写 JSON，格式漂不了）。
mkBackupRoot :: FilePath -> [(Op, ItemStatus)] -> IO ()
mkBackupRoot root ops = do
  writeF (root </> ".pm" </> "root-id.json") "{\"id\":\"bk\"}"
  let items = [PlanItem ix op st Nothing | (ix, (op, st)) <- zip [0 ..] ops]
      p = Plan planId "backup" root (Just "bk") (UTCTime (fromGregorian 2026 9 26) 0) items
  createDirectoryIfMissing True (takeDirectory (planPath root planId))
  BSL.writeFile (planPath root planId) (encode p)

-- | result.json 里测试关心的部分：bad 的 (path, why) 与 gave_up。
data Res = Res [(Maybe String, String)] (Maybe Bool)
  deriving (Show, Eq)

instance FromJSON Res where
  parseJSON = withObject "result" $ \o ->
    Res <$> (o .: "bad" >>= mapM (withObject "bad" (\b -> (,) <$> b .:? "path" <*> b .: "why"))) <*> o .:? "gave_up"

readRes :: FilePath -> String -> IO Res
readRes fp log' = BSL.readFile fp >>= maybe (assertFailure ("result.json 解不出\n" <> log') >> pure (Res [] Nothing)) pure . decode

-- | @sha256("abc")@（FIPS 180-2 测试向量）。
shaAbc :: T.Text
shaAbc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

copyTo :: FilePath -> T.Text -> Op
copyTo dst sha = OpCopy ("C:" </> "src" </> dst) dst sha 3 0

-- | #20：盘在 run() 中途掉线、--drive-wait 内没回来，'Drive.ensure' 此前直接 @sys.exit(3)@——已核出的
-- sha 不符连同 --out 一起丢掉。#23：之后的隔离件存在性检查没有盘在判据，盘不在时报「present 0\/N」。
-- 驱动脚本把第一个目标读完后整盘改名（= 拔盘，盘上一切都不见），等待与冷却不真等。
caseDriveGaveUp :: Assertion
caseDriveGaveUp = withSystemTempDirectory "pm-script" $ \dir -> do
  let root = dir </> "E"
      out = dir </> "result.json"
      driver = dir </> "driver.py"
  mkBackupRoot root [(copyTo "a.jpg" (T.replicate 64 "0"), StPending), (copyTo "b.jpg" shaAbc, StPending), (OpQuarantine "old.jpg" shaAbc "superseded", StPending)]
  writeF (root </> "a.jpg") "abc"
  writeF (root </> "b.jpg") "abc"
  writeF (root </> ".pm" </> "trash" </> T.unpack planId </> "old.jpg") "abc"
  scripts <- makeAbsolute "scripts"
  writeF driver $
    unlines
      [ "import os, sys, time"
      , "root, out, pid, scripts = sys.argv[1:5]"
      , "sys.path.insert(0, scripts)"
      , "import backup_verify as bv"
      , "time.sleep = lambda s: None"
      , "orig, seen = bv.sha_of, []"
      , "def sha_then_unplug(p, limiter=lambda n: None):"
      , "    s = orig(p, limiter)"
      , "    seen.append(p)"
      , "    if len(seen) == 1:"
      , "        os.rename(root, root + '.gone')"
      , "    return s"
      , "bv.sha_of = sha_then_unplug"
      , "import verify_backup_dst"
      , "sys.argv = ['verify_backup_dst.py', '--plan', pid, '--root', root, '--out', out, '--drive-wait', '0', '--cooldown', '0']"
      , "verify_backup_dst.main()"
      ]
  (code, log') <- runPy dir [driver, root, out, T.unpack planId, scripts]
  assertBool ("--out 须写出（中途放弃也写）\n" <> log') =<< doesFileExist out
  res <- readRes out log'
  -- 已核出的 sha 不符照留；被打断的 b.jpg 记「没读到」供 --retry；隔离件盘不在记「没核」，不报 0/1
  res @?= Res [(Just "a.jpg", "sha ba7816bf8f01 != 000000000000"), (Just "b.jpg", "not verified (drive did not return)"), (Nothing, "trash victims not verified (drive absent)")] (Just True)
  assertEqual ("退出码（盘没回来 = 3）\n" <> log') 3 code

-- | #22：@pm resolve@ 跳过的条目 Exec 不执行（ONotExecuted），脚本此前照样要求 copy 目标在盘上、victim 在
-- trash 里——报 missing 与 1\/2，且每次 --retry 复发。夹具：pending 与 skipped 的 copy \/ 隔离件各一，外加一条待裁决的 copy。
casePendingOnly :: Assertion
casePendingOnly = withSystemTempDirectory "pm-script" $ \dir -> do
  let root = dir </> "E"
      out = dir </> "result.json"
  mkBackupRoot
    root
    [ (copyTo "a.jpg" shaAbc, StPending)
    , (copyTo "skipped.jpg" shaAbc, StSkippedByUser)
    , (copyTo "undecided.jpg" shaAbc, StNeedsDecision "dst exists")
    , (OpQuarantine "q.jpg" shaAbc "superseded", StPending)
    , (OpQuarantine "kept.jpg" shaAbc "superseded", StSkippedByUser)
    ]
  writeF (root </> "a.jpg") "abc"
  writeF (root </> ".pm" </> "trash" </> T.unpack planId </> "q.jpg") "abc"
  scripts <- makeAbsolute "scripts"
  (code, log') <- runPy dir [scripts </> "verify_backup_dst.py", "--plan", T.unpack planId, "--root", root, "--out", out]
  res <- readRes out log'
  res @?= Res [] (Just False)
  assertBool ("须交代跳过了几条\n" <> log') ("skip 3 items not pending" `isInfixOf` log')
  assertBool ("隔离件只数 pending 的那一条\n" <> log') ("TRASH victims present 1/1" `isInfixOf` log')
  assertEqual ("退出码（只核 pending：全部一致 = 0）\n" <> log') 0 code

-- | #21：@--extra@ 放在最后此前抛未捕获的 StopIteration（退出 1，与「命中」同码）；没给文件答「干净」0；
-- @--extra ""@ 的空模式处处「命中」。现在用法错与读不到的文件一律 2，命中（1）优先于读不到。
caseLeakscanUsage :: Assertion
caseLeakscanUsage = withSystemTempDirectory "pm-script" $ \dir -> do
  let clean = dir </> "clean.bin"
      hit = dir </> "hit.bin"
      missing = dir </> "missing.bin"
  writeF clean "nothing to see"
  writeF hit "xx-QQLEAKQQ-xx"
  scanner <- makeAbsolute ("scripts" </> "leakscan.py")
  let expect args want = do
        (c, log') <- runPy dir (scanner : args)
        assertEqual (unwords args <> "\n" <> log') want c
        pure log'
  usage <- expect [clean, "--extra"] 2
  assertBool ("用法错须给出用法行\n" <> usage) ("leakscan.py" `isInfixOf` usage)
  _ <- expect [clean, "--extra", ""] 2
  _ <- expect [] 2
  _ <- expect ["--extra", "QQLEAKQQ"] 2
  _ <- expect [missing] 2
  _ <- expect [clean, "--extra", "QQLEAKQQ"] 0
  _ <- expect [hit, "--extra", "QQLEAKQQ"] 1
  _ <- expect [missing, hit, "--extra", "QQLEAKQQ"] 1
  pure ()
