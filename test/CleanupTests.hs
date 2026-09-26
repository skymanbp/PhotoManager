{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 2026-09-26 遗留清理：2026-09-25 全量审计余下的 low 项与横切审计补跑（#60 起）中不归属某个领域测试
-- 文件的钉针。每条用例名以「#编号」开头，编号对 docs/reviews/2026-09-25-full-debug-findings.json 与
-- docs/reviews/2026-09-26-crosscut-findings.json；修法与突变记录在 docs/REVIEW-LOG.md 的
-- 「2026-09-26 横切审计补跑与遗留清理」节。
module CleanupTests (cleanupTests) where

import Data.List (isInfixOf)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.BackupCmd (runBackupRun)
import Pm.Cli (GoOpts (..))
import Pm.Config (Config (..))
import TestUtil (captureStdout, mkMain, readUtf8)

cleanupTests :: TestTree
cleanupTests =
  testGroup
    "2026-09-26 遗留清理"
    [ testCase "#16 #18 GUI：索引读不出 ≠ 尚未索引（状态页 / 归档页带原因）；候选读不出 ≠ 没有非 jpg（按未知渲染、清掉上一轮残留）" caseGuiUnknownNotAbsent
    , testCase "#28 #73 §5.1「2 = 错误」：pm backup 找不到备份盘退 2（不是 1）；命令行用法错误退 2（parserInfo 设 failureCode 2）" caseErrorExitCodes
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
