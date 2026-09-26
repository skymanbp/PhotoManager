{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | 2026-09-26 遗留清理：2026-09-25 全量审计余下的 low 项与横切审计补跑（#60 起）中不归属某个领域测试
-- 文件的钉针。每条用例名以「#编号」开头，编号对 docs/reviews/2026-09-25-full-debug-findings.json 与
-- docs/reviews/2026-09-26-crosscut-findings.json；修法与突变记录在 docs/REVIEW-LOG.md 的
-- 「2026-09-26 横切审计补跑与遗留清理」节。
module CleanupTests (cleanupTests) where

import Control.Monad (forM_)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf, isPrefixOf)
import Data.Time (UTCTime (..), defaultTimeLocale, formatTime, fromGregorian, getTimeZone, utcToLocalTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (splitDrive, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Backup (discoverAmongStates, discoverBackupRoot, discoverBackupRoots)
import Pm.BackupCmd (backupInitPreflight, runBackupRun)
import Pm.Cli (GoOpts (..), bindExecRootWith, healLines, parseWorkers, parseYmd)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), repairDegraded, repairRow, runDoctor)
import Pm.Exec (Checkpoint (..))
import Pm.Commands (InitOpts (..), ScanCmd (..), TrashCmd (..), runInit, runScanCmd, runTrash)
import Pm.Hash (sha256File)
import Pm.Op (Op (..))
import Pm.Config (Config (..), loadConfig, writeConfig)
import Pm.ConfigEdit (checkConfig, runConfigShow)
import Pm.GitGuard (pmIgnoreGuard)
import Pm.Catalog (CatalogLoad (..), loadCatalog, saveCatalog)
import Pm.SortSource (withSourceQ)
import Pm.Status (IndexSummary (..), StatusOpts (..), StatusReport (..), localStamp, renderStatus, statusReport)
import Pm.VaultHold (validateKeyed)
import Pm.Types (Catalog (..), Entry (..), RootRole (..), blankPathArg, showHuman, subpathOk)
import Pm.Undo (buildUndoPlan)
import TestUtil (captureStdout, execNow, execOk, grepSrc, injectAt, mkCopyOp, mkMain, mkPlanIO, readUtf8, runCrash, scanQuiet, withEnv, writeF)

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
    , testCase "#83 整理页重扫先清模型再请求：失败的重扫之后没有旧概览、AI 按钮不亮；AI 请求收尾按当前概览定按钮" caseSortRescanReset
    , testCase "#29 #38 --repair 做了什么进返回的 findings（REPAIR 行，不直接打 stdout）；执行自愈转发它们与 Bad 行，降级成只诊断时不再报「补记 N 条」" caseRepairFindings
    , testCase "#30 隔离预写了 manifest 却没落地（崩在移动前）：pm trash list 标「不在 trash」，不再说「已移出」；victim 仍在原位" caseTrashListNeverLanded
    , testCase "#35 在途 Copy 的 dst 后来被另一份计划正当落成新内容：doctor 报 C5-SUPERSEDED Info（不再是 C5 Bad、exit 0），--repair 不给那份文件出隔离计划" caseC5Superseded
    , testCase "#40 pm undo 一次隔离（从 trash 改名回原位）后索引补回那条——此前文件回到库里、索引静静地少它一条" caseUndoQuarantineReindexed
    , testCase "#26 备份发现按四态读：登记路径上 root-id.json 损坏 / 读不出 → 点名那块盘（不再说「未挂载，插上盘」）；pm apply 的 UUID 绑定同样点名；路径不在照旧「未挂载」" caseBackupMarkerBroken
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

-- | #83：sortScan 此前只清 DOM——重扫失败后 lastSurvey \/ segInputs 仍是上一次的、AI 按钮仍亮，再点「AI 建议地点」
-- 拿旧源付费跑 claude 并报「已预填」。本仓不跑浏览器：钉源码——请求之前就把模型清掉，AI 收尾不无条件放开按钮。
caseSortRescanReset :: Assertion
caseSortRescanReset = do
  app <- readUtf8 ("gui" </> "ui" </> "app.js")
  let (_, scan) = breakOn "async function sortScan()" app
      (beforeReq, _) = breakOn "await req(" scan
      (_, ai) = breakOn "async function sortAiPlaces()" app
      (aiBody, _) = breakOn "async function sortScan()" ai
  assertBool "sortScan 须在请求之前清掉 lastSurvey / segInputs 并关掉 AI 按钮" ("lastSurvey = null; segInputs.clear(); $(\"#btn-sort-ai\").disabled = true;" `isInfixOf` beforeReq)
  assertBool "AI 收尾不得无条件放开按钮" (not ("btn.disabled = false" `isInfixOf` aiBody))
  assertBool "AI 收尾按当前概览定按钮" ("btn.disabled = !lastSurvey || !lastSurvey.segments.length" `isInfixOf` aiBody)
 where
  breakOn pat s = go "" s
   where
    go acc r@(c : cs)
      | pat `isPrefixOf` r = (reverse acc, r)
      | otherwise = go (c : acc) cs
    go acc [] = (reverse acc, [])

-- | #38：applyRepairs 此前逐条 putStrLn、不进 findings——@pm ui@ 下 stdout 是空设备，GUI 发起的执行自愈看不到它
-- 生成了 C5 隔离计划或删了什么。#29：自愈按诊断行合成「补记 Done N 条」，降级成只诊断（I10 / I11）时那个数是假的。
caseRepairFindings :: Assertion
caseRepairFindings = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  opA <- mkCopyOp (dir </> "a.jpg") "AAA" ("相册" </> "a.jpg")
  planA <- mkPlanIO root [opA]
  runCrash (injectAt CpCopyAfterMove) planA -- C2：已落位、缺 Done
  -- 孤儿 tmp：.pm/tmp 下不属于任何在途 Intent 的 pm 自建文件（在途 Intent 的 tmp 按设计不删）
  writeF (root </> ".pm" </> "tmp" </> "20260101-000000-abcdef" </> "0-b.jpg.tmp") "junk"
  (out, (fs, _)) <- captureStdout (runDoctor root (DoctorOpts False True))
  let rep = [fDetail f | f <- fs, fRow f == repairRow]
  assertBool (show rep) (any ("补记 Done " `isPrefixOf`) rep && any ("清除 pm 自建文件" `isPrefixOf`) rep)
  assertBool ("修复不得绕过 findings 直接打 stdout: " <> out) (not ("补记 Done" `isInfixOf` out))
  -- 自愈：降级只诊断 → 转发 I10 那行，不报「补记」；实际做了的 REPAIR 行照转；什么都没做 → 一行「无需修复」
  let degraded = healLines [Finding "C2" Warn "p:0: 已落位" "", Finding "I10" Bad "--repair 需要 root 独占锁——本轮只诊断，未做任何修复" ""]
  assertBool (unlines degraded) (any ("未做任何修复" `isInfixOf`) degraded && not (any ("补记" `isInfixOf`) degraded))
  assertBool "REPAIR 行照转" (any ("补记 Done p:0" `isInfixOf`) (healLines [Finding repairRow Info "补记 Done p:0" ""]))
  healLines [] @?= ["· 自愈：pm doctor --repair 无需修复"]
  -- 执行续跑据此停下（降级那条的原因原样交回）；修成了（没有 I10 / I11）= Nothing
  repairDegraded [Finding "I10" Bad "锁被占" "", Finding "C2" Warn "x" ""] @?= Just "锁被占"
  repairDegraded [Finding repairRow Info "补记 Done p:0" ""] @?= Nothing
  repairDegraded [Finding "I11" Bad "不可写" ""] @?= Just "不可写"
  -- 执行路径的 heal 把它交回 execPlanRetry（executePlanNowWith 自建 ExecEnv，注入不进来：钉源码）
  cli <- readUtf8 ("src" </> "Pm" </> "Cli.hs")
  assertBool "Cli 的 heal 须把 repairDegraded 交回续跑" ("pure (repairDegraded fs)" `isInfixOf` cli)
  hits <- grepSrc ("补记 Done %d 条" `isInfixOf`)
  hits @?= []

-- | #26：发现侧此前经 readRootInfo 的 Maybe 读标识，登记路径上 root-id.json 损坏 / 读不出（.pm 不是目录、
-- 是 junction、ACL 挡住）与「这个卷上没有」一样算不命中——插着的盘被报成「备份盘未挂载 → 插上备份盘后重试」，
-- pm apply 的 UUID 绑定报「均不符」。备份路径按真实盘符发现：subpath 取临时目录去掉盘符的那段。
caseBackupMarkerBroken :: Assertion
caseBackupMarkerBroken = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let cfg0 = Config (dir </> "main") Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
      cfgOf p = cfg0 {cfgBackupId = Just "bk-26", cfgBackupSubpath = Just (snd (splitDrive p))}
      bad = dir </> "bk"
      opaque = dir </> "bk2"
      refused r k = either k (\p -> assertFailure ("不该命中: " <> p)) r
  writeF (bad </> ".pm" </> "root-id.json") "{not json"
  writeF (opaque </> ".pm") "not a dir"
  discoverBackupRoot (cfgOf bad) >>= \r -> refused r $ \m ->
    assertBool m ("身份损坏" `isInfixOf` m && "不是没插盘" `isInfixOf` m && not ("插上备份盘" `isInfixOf` m))
  discoverBackupRoot (cfgOf opaque) >>= \r -> refused r $ \m -> assertBool m ("身份读不出" `isInfixOf` m && "不是没插盘" `isInfixOf` m)
  -- 探名答不上来的候选（卷没就绪 / 空读卡器槽是 ERROR_NOT_READY；这里用非法名 ERROR_INVALID_NAME 同形注入）：
  -- 四态是「读不出」（可信闸把它说成 junction/别名），但说不上「这块盘的身份坏了」——不点名
  discoverAmongStates "bk-26" [dir </> "a<b"] >>= (@?= ([], []))
  discoverBackupRoot (cfgOf (dir </> "none")) >>= \r -> refused r $ \m -> assertBool m ("备份盘未挂载" `isInfixOf` m && "插上备份盘" `isInfixOf` m)
  plan <- mkPlanIO (dir </> "main") []
  bindExecRootWith (\_ -> pure ()) (cfgOf bad) plan "bk-26" >>= \r -> case r of
    Left m -> assertBool m ("备份盘 " `isInfixOf` m && "身份损坏" `isInfixOf` m)
    Right _ -> assertFailure "不该绑定"

-- | #30：隔离先预写 manifest 再移动（§6.3 步 1）；崩在移动前（Q2）或移动失败，那条记录留在只追加的 manifest
-- 里——pm trash list 此前标「已移出」（本义是被 purge / 被 undo 移回），一张从没进过 trash 的照片被说成移出过。
caseTrashListNeverLanded :: Assertion
caseTrashListNeverLanded = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  BS.writeFile (root </> "v.jpg") "VICTIM"
  vsha <- sha256File (root </> "v.jpg")
  plan <- mkPlanIO root [OpQuarantine "v.jpg" vsha "t"]
  runCrash (injectAt CpQuarAfterManifest) plan
  (out, code) <- captureStdout (runTrash (Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing) TrashList root)
  code @?= 0
  assertBool out ("v.jpg" `isInfixOf` out && "不在 trash" `isInfixOf` out && not ("已移出" `isInfixOf` out))
  doesFileExist (root </> "v.jpg") >>= (@?= True)

-- | #35：崩在 Intent 之后、写 tmp 之前的 Copy，dst 后来被另一份计划正当地落成新内容——Exec 对重跑的 I5 冲突不记
-- journal，这条 Intent 永远在途；doctor 此前每轮报 C5 Bad（exit 1），--repair（含执行续跑前的自愈）给那份正当
-- 落位的文件出隔离计划。dst 的事件夹名用大写，钉住按 NTFS 语义（case-fold）比对。
caseC5Superseded :: Assertion
caseC5Superseded = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "root"
      dst = "成片" </> "Ev" </> "x.jpg"
      plansDir = root </> ".pm" </> "plans"
  createDirectoryIfMissing True root
  opA <- mkCopyOp (dir </> "a.jpg") "OLD" dst
  mkPlanIO root [opA] >>= runCrash (injectAt CpCopyAfterIntent)
  opB <- mkCopyOp (dir </> "b.jpg") "NEW" dst
  _ <- mkPlanIO root [opB] >>= execOk
  (fs, code) <- runDoctor root (DoctorOpts False False)
  let rows = [(fRow f, fSeverity f) | f <- fs]
  assertBool (show rows) (("C5-SUPERSEDED", Info) `elem` rows && "C5" `notElem` map fst rows)
  code @?= 0
  _ <- runDoctor root (DoctorOpts False True)
  ex <- doesDirectoryExist plansDir
  ps <- if ex then listDirectory plansDir else pure []
  ps @?= []
  readFile (root </> dst) >>= (@?= "NEW")

-- | #40：pm undo 一次隔离 = 从 .pm/trash 改名回原位；updateCatalog 的改名臂只改键（trash 下的条目从不在索引里），
-- 隔离落位时删掉的条目于是补不回来。走 CLI 的执行口（execNow → 索引回写），与用户跑 pm apply 同一条路。
caseUndoQuarantineReindexed :: Assertion
caseUndoQuarantineReindexed = withSystemTempDirectory "pm-cleanup" $ \dir -> do
  let root = dir </> "root"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
      v = "相册" </> "v.jpg"
      entryOf = (\lc -> case lc of CatLoaded c _ -> (\e -> (enSha e, enSize e)) <$> Map.lookup v (catEntries c); _ -> Nothing) <$> loadCatalog root
  createDirectoryIfMissing True root
  mkMain root
  writeF (root </> v) "BACK"
  scanQuiet "main-rid" root >>= saveCatalog root
  sha <- sha256File (root </> v)
  _ <- mkPlanIO root [OpQuarantine v sha "test"] >>= execNow cfg
  entryOf >>= (@?= Nothing)
  Right up <- buildUndoPlan root 1
  _ <- execNow cfg up
  readFile (root </> v) >>= (@?= "BACK")
  entryOf >>= (@?= Just (sha, 4))
