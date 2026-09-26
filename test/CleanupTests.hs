{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 2026-09-26 遗留清理：2026-09-25 全量审计余下的 low 项与横切审计补跑（#60 起）中不归属某个领域测试
-- 文件的钉针。每条用例名以「#编号」开头，编号对 docs/reviews/2026-09-25-full-debug-findings.json 与
-- docs/reviews/2026-09-26-crosscut-findings.json；修法与突变记录在 docs/REVIEW-LOG.md 的
-- 「2026-09-26 横切审计补跑与遗留清理」节。
module CleanupTests (cleanupTests) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.List (isInfixOf)
import Data.Time (UTCTime (..), defaultTimeLocale, formatTime, fromGregorian, getTimeZone, utcToLocalTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Backup (discoverBackupRoots)
import Pm.BackupCmd (backupInitPreflight, runBackupRun)
import Pm.Cli (GoOpts (..), parseWorkers, parseYmd)
import Pm.Commands (InitOpts (..), ScanCmd (..), runInit, runScanCmd)
import Pm.Config (Config (..), loadConfig, writeConfig)
import Pm.ConfigEdit (checkConfig, runConfigShow)
import Pm.GitGuard (pmIgnoreGuard)
import Pm.Catalog (saveCatalog)
import Pm.SortSource (withSourceQ)
import Pm.Status (IndexSummary (..), StatusOpts (..), StatusReport (..), localStamp, renderStatus, statusReport)
import Pm.VaultHold (validateKeyed)
import Pm.Types (RootRole (..), blankPathArg, showHuman, subpathOk)
import TestUtil (captureStdout, grepSrc, mkMain, readUtf8, scanQuiet, withEnv, writeF)

cleanupTests :: TestTree
cleanupTests =
  testGroup
    "2026-09-26 遗留清理"
    [ testCase "#16 #18 GUI：索引读不出 ≠ 尚未索引（状态页 / 归档页带原因）；候选读不出 ≠ 没有非 jpg（按未知渲染、清掉上一轮残留）" caseGuiUnknownNotAbsent
    , testCase "#28 #73 §5.1「2 = 错误」：pm backup 找不到备份盘退 2（不是 1）；命令行用法错误退 2（parserInfo 设 failureCode 2）" caseErrorExitCodes
    , testCase "#41 #66 开头的 UTF-8 BOM：config.toml 照常载入（此前每条命令起不来）；.gitignore 首行 .pm/ 照常算覆盖；中间的 BOM 不认" caseLeadingBom
    , testCase "#14 #27 配置写口：并发数 / 掉线等待越界与非盘内相对的备份 subpath 由 checkConfig 统一拒（pm init --workers 0 不再写进配置）；发现侧对手编 subpath 说清原因" caseConfigSink
    , testCase "#54 pm status 的暂存事件按 import 的同一套布局：Raw\\<年>\\<事件> 报事件不报年份；import 认不出的形状记「(无法识别)」、待修改不计" caseStagingEventLayout
    , testCase "#69 给人看的名字不经 show：pm status 的暂存事件、记录校验的坏名字照原样显示中文（此前是 \\26477 这类转义）" caseHumanText
    , testCase "#68 历史时刻按当时的时区偏移换算（冬 / 夏两个时刻各用各的）；src 不再用 getCurrentTimeZone 换算历史时刻" caseHistoricalOffset
    , testCase "#65 #84 命令行参数：日期只收十位 YYYY-MM-DD（26-09-01 不再是公元 26 年）；空路径参数不再落到当前目录（init / backup init / sort）" caseCliArgs
    ]

-- | #16 / #18 的 GUI 形状（本仓不跑浏览器：源码哨兵 + node --check）。
caseGuiUnknownNotAbsent :: Assertion
caseGuiUnknownNotAbsent = do
  app <- readUtf8 ("gui" </> "ui" </> "app.js")
  arc <- readUtf8 ("gui" </> "ui" </> "archive.js")
  assertBool "状态页：index 空且 warnings 非空须说「主库索引读不出」" ("主库索引读不出：\" + s.root" `isInfixOf` app)
  assertBool "归档页：index 空且 warnings 非空须说「主库索引读不出」" ("主库索引读不出：\" + s.warnings.join" `isInfixOf` arc)
  assertBool "候选读不出须按未知渲染（renderConvert(null)），不许再 renderConvert([])" ("renderConvert(null)" `isInfixOf` arc && not ("renderConvert([])" `isInfixOf` arc))
  assertBool "renderConvert 须有 null 分支" ("if (list === null)" `isInfixOf` arc)
  assertBool "候选读不出须清掉上一轮的已忽略清单" ("renderIgnored([], [])" `isInfixOf` arc)

-- | #28：pm backup 找不到备份盘（这里是未登记）此前退 1，与「计划已存待执行」同码。
-- #73：用法错误走 optparse 的 failureCode（缺省 1）；parserInfo 在 app/ 里、测试链不进来，钉源码。
caseErrorExitCodes :: Assertion
caseErrorExitCodes = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "main"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
  mkMain root
  (out, code) <- captureStdout (runBackupRun (GoOpts False False) Nothing cfg)
  assertBool out ("未登记" `isInfixOf` out)
  code @?= 2
  m <- readUtf8 ("app" </> "Main.hs")
  assertBool "parserInfo 须设 failureCode 2" ("<> failureCode 2)" `isInfixOf` m)

-- | #66：toml-reader 在 1:1 拒收 U+FEFF，带 BOM 的 config.toml 让每条 pm 命令（含 GUI）起不来。
-- #41：.gitignore 带 BOM 时首行 @.pm/@ 被读成「U+FEFF.pm/」，I11 报「缺 .pm/ 行」——git 本身认它。
caseLeadingBom :: Assertion
caseLeadingBom = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let cfgPath = dir </> "config.toml"
      root = dir </> "main"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
      bom = BS.pack [0xEF, 0xBB, 0xBF]
  createDirectoryIfMissing True root
  withEnv [("PM_CONFIG", cfgPath)] $ do
    _ <- writeConfig cfg
    raw <- BS.readFile cfgPath
    BS.writeFile cfgPath (bom <> raw)
    r <- loadConfig
    either (\m -> assertFailure ("带 BOM 的 config.toml 应照常载入: " <> m)) (\c -> cfgMainPath c @?= root) r
  let g = dir </> "repo"
  createDirectoryIfMissing True (g </> ".git")
  BS.writeFile (g </> ".gitignore") (bom <> ".pm/\r\n")
  pmIgnoreGuard RoleVault g >>= (@?= Right ())
  BS.writeFile (g </> ".gitignore") ("_site/\n" <> bom <> ".pm/\n")
  r2 <- pmIgnoreGuard RoleVault g
  either (const (pure ())) (const (assertFailure "中间的 BOM 不认（git 也只跳开头那一个）")) r2

-- | #14：并发数边界此前只在 checkPatch，pm init --workers 0 / 65 原样写进配置。#27：subpath 被 </> 拼到每个
-- 卷根上，带盘符 / 前导分隔符的手编值让每个卷都命中同一路径，认对的盘被报成「整盘克隆」。
caseConfigSink :: Assertion
caseConfigSink = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "main"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
      bad = cfg {cfgBackupId = Just "bid"}
  createDirectoryIfMissing True root
  checkConfig cfg >>= (@?= [])
  e1 <- checkConfig cfg {cfgWorkers = Just 0}
  assertBool (show e1) (any ("并发数 0 越界" `isInfixOf`) e1)
  e2 <- checkConfig cfg {cfgWorkers = Just 65, cfgDriveWait = Just (-1)}
  assertBool (show e2) (any ("并发数 65 越界" `isInfixOf`) e2 && any ("掉线等待 -1 秒越界" `isInfixOf`) e2)
  withEnv [("PM_CONFIG", dir </> "config.toml")] $ do
    (_, code) <- captureStdout (runInit (InitOpts root Nothing Nothing (Just 0) False))
    code @?= 2
    doesFileExist (dir </> "config.toml") >>= (@?= False)
  forM_ ["", "Photography", "a\\b", "a/b", "a\\\\b", "Photography\\"] $ \s -> assertBool ("应收: " <> s) (subpathOk s)
  forM_ ["\\Photography", "/x", "\\\\server\\share", "E:\\Photography", "E:x", "..", "a\\..\\b", "."] $ \s -> assertBool ("应拒: " <> s) (not (subpathOk s))
  -- 手编的越界值：扫描拒（不夹紧），pm config 标 ⚠；命令行给了合法 --workers 就不看配置值
  mkMain root
  (so, sco) <- captureStdout (runScanCmd (ScanCmd Nothing True) cfg {cfgWorkers = Just 100000})
  sco @?= 2
  assertBool so ("并发数 100000 越界" `isInfixOf` so)
  (_, sco2) <- captureStdout (runScanCmd (ScanCmd (Just 2) True) cfg {cfgWorkers = Just 0})
  sco2 @?= 0
  withEnv [("PM_CONFIG", dir </> "config.toml")] $ do
    (shown, _) <- captureStdout (runConfigShow cfg {cfgWorkers = Just 0, cfgDriveWait = Just (-5), cfgBackupId = Just "bid", cfgBackupSubpath = Just "E:\\Photography"})
    assertBool shown ("0  ⚠ 越界（1..64）" `isInfixOf` shown && "-5 s  ⚠ 越界（0..86400）" `isInfixOf` shown && "盘内路径不是相对路径" `isInfixOf` shown)
  e3 <- checkConfig bad {cfgBackupSubpath = Just "\\Photography"}
  assertBool (show e3) (any ("盘内相对路径" `isInfixOf`) e3)
  r <- discoverBackupRoots bad {cfgBackupSubpath = Just "E:\\Photography"}
  either (\m -> assertBool m ("不是盘内相对路径" `isInfixOf` m)) (const (assertFailure "手编的绝对 subpath 应在发现侧拒绝")) r

-- | #65：Read Day 接受任意位数年份。#84：makeAbsolute "" 答当前目录——空路径参数一路下去被当成 cwd。
caseCliArgs :: Assertion
caseCliArgs = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  parseYmd "2026-09-01" @?= Just (fromGregorian 2026 9 1)
  forM_ ["26-09-01", "12026-09-01", "2026-9-1", "2026-02-30", "2026/09/01", " 2026-09-01", ""] $ \s ->
    assertBool ("应拒: " <> show s) (parseYmd s == Nothing)
  parseWorkers "8" @?= Right 8
  forM_ ["0", "65", "-1", "100000", "x", ""] $ \s -> assertBool ("应拒: " <> show s) (either (const True) (const False) (parseWorkers s))
  forM_ ["", " ", "\t"] $ \s -> assertBool ("应判空: " <> show s) (blankPathArg s)
  assertBool "非空路径不算空" (not (blankPathArg "."))
  let cfg = Config (dir </> "main") Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
  withEnv [("PM_CONFIG", dir </> "config.toml")] $ do
    (out, code) <- captureStdout (runInit (InitOpts "" Nothing Nothing Nothing False))
    code @?= 2
    assertBool out ("--main 为空" `isInfixOf` out)
    doesFileExist (dir </> "config.toml") >>= (@?= False)
  backupInitPreflight cfg "" >>= either (\m -> assertBool m ("备份路径为空" `isInfixOf` m)) (\p -> assertFailure ("空备份路径应拒，实得 " <> p))
  withSourceQ "" "missing" (\_ _ -> pure "listed") >>= (@?= ("missing" :: String))
  -- 空参数没在当前目录（测试进程的 cwd = 仓库根）留下任何 .pm
  listDirectory "." >>= \es -> assertBool "仓库根不应出现 .pm" (".pm" `notElem` es)

-- | #54：stagingEventOf 此前按固定位置取第 3 个分量——年份布局把年份报成事件；直接放在 Raw\ 下的文件
-- 不产生事件，status 不打暂存行，import 却报「无法识别」。
caseStagingEventLayout :: Assertion
caseStagingEventLayout = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "main"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
      st = "To-Be-Sync'd"
  mkMain root
  writeF (root </> st </> "Raw" </> "2026" </> "26-08-Hangzhou" </> "a.ARW") "A"
  writeF (root </> st </> "Raw" </> "2026" </> "26-07-Wien" </> "b.ARW") "B"
  writeF (root </> st </> "Raw" </> "x.ARW") "X"
  writeF (root </> st </> "待修改" </> "y.jpg") "Y"
  scanQuiet "main-rid" root >>= saveCatalog root
  r <- statusReport cfg (StatusOpts True)
  fmap isStagingEvents (srIndex r) @?= Just ["(无法识别)", "26-07-Wien", "26-08-Hangzhou"]
  srExit r @?= 1

-- | #69：show 把非 ASCII 打成十进制转义——pm status 的「事件未归档」清单与记录校验的报错里，中文名字认不出、复制不了。
caseHumanText :: Assertion
caseHumanText = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  showHuman "26-08-杭州" @?= "\"26-08-杭州\""
  showHuman "a\nb" @?= "\"a\\nb\""
  showHuman "old\\a.jpg" @?= "\"old\\a.jpg\""
  let root = dir </> "main"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
  mkMain root
  writeF (root </> "To-Be-Sync'd" </> "Raw" </> "26-08-杭州" </> "a.ARW") "A"
  scanQuiet "main-rid" root >>= saveCatalog root
  r <- statusReport cfg (StatusOpts True)
  (out, _) <- captureStdout (renderStatus (StatusOpts True) r >> pure ())
  assertBool out ("事件未归档: [\"26-08-杭州\"]" `isInfixOf` out)
  case validateKeyed "暂不同步名单" fst snd [("旧/杭州.jpg", "x")] of
    Left m -> assertBool m ("\"旧/杭州.jpg\"" `isInfixOf` m)
    Right () -> assertFailure "非平铺名应拒"

-- | #68：renderStatus 此前取一次 getCurrentTimeZone 套到扫描 / 备份 / vault 三个历史时刻上。本机（有夏令时的
-- 时区）冬夏两个时刻至少有一个会差一小时；CI 的 runner 若是 UTC 无夏令时，行为断言退化为恒真，由源码哨兵兜住。
caseHistoricalOffset :: Assertion
caseHistoricalOffset = do
  let winter = UTCTime (fromGregorian 2026 1 15) 3600
      summer = UTCTime (fromGregorian 2026 7 15) 3600
      expect t = (\tz -> formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz t)) <$> getTimeZone t
  forM_ [winter, summer] $ \t -> do
    want <- expect t
    localStamp t >>= (@?= want)
  grepSrc ("getCurrentTimeZone" `isInfixOf`) >>= (@?= [])
