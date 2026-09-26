{-# LANGUAGE OverloadedStrings #-}

-- | 2026-09-25 全量 debug 审计（docs/reviews/2026-09-25-full-debug-audit.md，编号
-- @#id@ 与报告一致）的修复钉针——凡既有主题模块已触 750 行预算（GuardTests /
-- PathGuardTests / KernelTests …）而放不下的用例收在这里；能就地扩展既有用例的
-- 仍就地扩展。每条钉一个屏障：拆掉对应修复，用例必须转红。
module AuditFixTests (auditFixTests) where

import Control.Exception (AsyncException (..), IOException, finally, throwIO, try)
import Control.Monad (filterM, forM_, when)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import Network.HTTP.Types (hAuthorization, hContentType, hHost, hOrigin, methodPost, status500)
import Network.Wai (Request (..), defaultRequest)
import Network.Wai.Test (SRequest (..), SResponse (..), Session, runSession, setPath, srequest)
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getPermissions, listDirectory, removeFile, setModificationTime, setOwnerWritable, setPermissions)
import System.Environment (lookupEnv, setEnv)
import System.FilePath (joinPath, splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Clean (CleanReport (..), planClean)
import Pm.Cli (exitBoundary, reportScanIssues, stagingFresh)
import Pm.Commands (TrashCmd (..), runTrash)
import Pm.Config (Config (..), configFilePath, createRootInfo, loadConfig, readRootInfo, withConfigLock, writeConfig, writeRootInfo)
import Pm.Dedupe (archiveLayerRel)
import Pm.Diff (BackupDiff (..), backupDiff)
import Pm.Doctor (Severity (..))
import Pm.Exec (defaultExecEnv, execPlan)
import Pm.Hash (sha256File)
import Pm.Import (ImportReport (..), planImport, stagingArchivedSummary, stagingTop, underLayers)
import Pm.Journal (JEntry (..), Sync (..), jAppend, journalPath, withJournal)
import Pm.Op (Fingerprint (..), Op (..), OpIdSuffix (..), describeOp, opId, opPathsOk, trashSrcRel)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), savePlan, validatePlan)
import Pm.Scan (DotDirs (..), ScanOpts (..), ScanResult (..), cloudOnlyNote, freshnessSweep, isCloudOnlyAttr, listTreeCov, reparseSkipNote, scanRoot)
import Pm.Serve (serveApp)
import Pm.Sort (runSortSurvey)
import Pm.SortSource (SourceFiles (..), listSource)
import Pm.Trash (manifestPath, quarDirFor, trashDir)
import Pm.Types (Catalog (..), Entry (..), RootInfo (..), RootRole (..))
import Pm.Win (NameKind (..), probeName)
import ServeTests (fixture, liftIO', mkEnvA, mkEnvW, tok, withVault)
import qualified ServeTests as ST
import TestUtil (captureStdout, doctorRows, execOk, isClean, journalEntries, mkCopyOp, mkPlanIO, setForeignReparse, setOffline, truncateJournalTo, withDenyAll, withEnv)

auditFixTests :: TestTree
auditFixTests =
  testGroup
    "2026-09-25 全量 debug 审计修复钉针"
    [ testCase "#4 配置路径途经 junction（同 SUBST / 8.3 短名）：configFilePath 解析到真名，写 / 锁 / 读三者同形，不再被句柄后验误拒" caseConfigPathJunction
    , testCase "#5 root 是 junction：createRootInfo 落到真名下、不抛、无 .tmp 残留；已有身份仍 Left 不覆盖且不留 .tmp" caseRootIdJunctionRoot
    , testCase "#9 POST /api/apply 执行链抛异常 → 500 JSON（interrupted + planId + log，带 CORS），不再是 warp 裸 500；GUI 认 interrupted" caseServeApplyInterrupted
    , testCase "#9 serveApp 最后一道异常边界：recordPost（hold）写链抛异常 → 500 JSON 带 CORS，主库记录文件零写入" caseServeBoundaryRecordPost
    , testCase "#43 trash 例外只放隔离载荷（≥ 4 级）：trash 根 / manifest / 整个隔离目录作 rename 源，validatePlan 与 execPlan 都拒、manifest 不动；生成形态照旧放行" caseTrashSrcShape
    , testCase "#34 doctor 在途 Copy 的 dst / Quarantine 的 victim 被 ACL 拒绝：不再塌成「无痕迹」C1 / 「两处都不在」Q?，按「在而读不出」报 C? Bad / Q2" caseDoctorDeniedUserSide
    , testCase "#58 测试里临时改环境变量须原样还原（有值写回、没有才删、异常同样还原）；test/ 里删环境变量只许在 TestUtil.withEnv" caseWithEnvRestores
    , testCase "#37 批次崩在隔离 Done 之后再 pm trash empty：清除后补写 CleanShutdown，下一次 doctor 不再把已清除的载荷误报成 C4「目标不存在」" caseTrashEmptyClosesWindow
    , testCase "#37 回归：补写收尾标记失败（journal 只读）不逃顶——照常报「已清除 1 项」、另报一行、exit 2；标记没写上，doctor 如报文所说报 C4" caseTrashEmptyMarkFails
    , testCase "#61 进程出口边界：逃出命令体的 IO 异常以 2 退出（不是 GHC 默认的 1），Ctrl-C 照原样传出，main 经它调命令体" caseExitBoundary
    , testCase "#8 遍历按 name-surrogate 位判链接：第三方非 surrogate 的 reparse 文件照常枚举（此前落进「链接跳过」不进索引），置上 surrogate 位的仍不跟随；源码里 pathIsSymbolicLink 只剩 Exec 的占用判定" caseWalkForeignReparse
    , testCase "#8 云端未下载（OFFLINE 位）：scan / sort 不读、单列「云端未下载」；已索引没改过的按 stat 复用，改过的保留旧条目，新鲜度照常核对；属性位按 SDK 取值" caseCloudOnlyNotRead
    , testCase "#3 暂存区 / 布局层名折大小写认：手建的 to-be-sync'd、raw 照样过新鲜度守卫、照样路由与归档判定；规范拼写与盘面拼写不算新增 + 消失；两种拼写并存拒绝；src 不再拿层名做 == / elem 比较" caseStagingCaseFold
    ]

mkJunction :: FilePath -> FilePath -> IO ()
mkJunction link target =
  () <$ readCreateProcess (shell ("mklink /J \"" <> link <> "\" \"" <> target <> "\"")) ""

mkCfg :: FilePath -> Config
mkCfg mainP = Config mainP Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing

-- | #4（medium）：%APPDATA% 或 PM_CONFIG 的某一层是 junction / SUBST / 8.3 短名时，
-- 'writeConfig' 的落位与 'withConfigLock' 的加锁都在句柄上后验「绑定的就是这条路径」，
-- 对比基准是 GetFinalPathNameByHandle 的规范形——只做 makeAbsolute 的原样字符串
-- 必然对不上，userError 作为未捕获异常抛出：pm init / config set / backup init 崩，
-- 读照常。'configFilePath' 改为在源头 canonicalizePath 后，三者同一形态。
-- 第二次 writeConfig 额外走「删旧 → 落位」的完整删除路（同 GuardTests 正斜杠用例）。
caseConfigPathJunction :: IO ()
caseConfigPathJunction = withSystemTempDirectory "pm-cfgjunc" $ \tmp -> do
  mold <- lookupEnv "PM_CONFIG"
  let real = tmp </> "real"
      link = tmp </> "link"
      mainP = tmp </> "main"
  createDirectoryIfMissing True real
  mkJunction link real
  setEnv "PM_CONFIG" (link </> "config.toml")
  flip finally (maybe (pure ()) (setEnv "PM_CONFIG") mold) $ do
    expect <- canonicalizePath (real </> "config.toml")
    fp <- configFilePath
    fp @?= expect
    _ <- writeConfig (mkCfg mainP)
    _ <- writeConfig (mkCfg mainP)
    doesFileExist (real </> "config.toml") >>= (@?= True)
    ml <- withConfigLock (pure ())
    ml @?= Just ()
    loadConfig >>= either (assertFailure . ("配置应可读回: " <>)) (\c -> cfgMainPath c @?= mainP)

-- | #5（medium）：'createRootInfo' 此前从调用方原样字符串拼落位目标与 tmp——root 是
-- junction / SUBST / 8.3 短名时（runInit 只 makeAbsolute、vault.path 原样；DESIGN §14 与
-- resolveUnder 文档都说 junction root 合法），'moveBoundNoReplace' 的句柄先验对不上
-- GetFinalPathNameByHandle 的规范形，失败臂的 'deleteBoundAt' 同样对不上并**抛出**：
-- 异常逃出 pm init / 首次 vault push，且每次尝试泄漏一个 @root-id.json.<hex>.tmp@。
-- 改为经受信解析器取 canonical 形态；失败臂删 tmp 包 try、原因并进报文。
caseRootIdJunctionRoot :: IO ()
caseRootIdJunctionRoot = withSystemTempDirectory "pm-rootjunc" $ \tmp -> do
  let real = tmp </> "real"
      link = tmp </> "link"
      leftovers = filter (".tmp" `isSuffixOf`) <$> listDirectory (real </> ".pm")
  createDirectoryIfMissing True real
  mkJunction link real
  now <- getCurrentTime
  r1 <- createRootInfo link (RootInfo "j" RoleMain now Nothing)
  r1 @?= Right ()
  doesFileExist (real </> ".pm" </> "root-id.json") >>= (@?= True)
  leftovers >>= (@?= [])
  fmap riId <$> readRootInfo link >>= (@?= Just "j")
  -- 目标已存在（并发创建 / readRootState 之后有人放了文件）：仍 Left、不覆盖、不抛、不留 tmp
  r2 <- createRootInfo link (RootInfo "x" RoleMain now Nothing)
  either (const (pure ())) (const (assertFailure "已有身份不得被覆盖")) r2
  fmap riId <$> readRootInfo real >>= (@?= Just "j")
  leftovers >>= (@?= [])

-- | #9 夹具：让 root 锁的**打开**确定性地抛非 EBUSY 的 IOException——@.pm/lock@ 被一个
-- 目录占名（openBinaryFile 打不开目录：PermissionDenied，'Pm.Config.withRootLock' 只把
-- isAlreadyInUseError 折成「锁被占」，其余原样重抛；瞬断保护按确定性错误原样重抛）。
squatLock :: FilePath -> IO ()
squatLock root = do
  let lk = root </> ".pm" </> "lock"
  ex <- doesFileExist lk
  when ex (removeFile lk)
  createDirectory lk

-- | 带 Origin 的 POST（'ServeTests.postReq' 不带 Origin，看不见 CORS 头）。
postWithOrigin :: BS.ByteString -> BSL.ByteString -> Session SResponse
postWithOrigin path body =
  srequest $
    SRequest
      ( setPath
          defaultRequest
            { requestMethod = methodPost
            , requestHeaderHost = Just "127.0.0.1:4321"
            , requestHeaders = [(hHost, "127.0.0.1:4321"), (hOrigin, "http://tauri.localhost"), (hAuthorization, "Bearer " <> tok), (hContentType, "application/json")]
            }
          path
      )
      body

-- | 500 响应必须是 JSON 对象且带 CORS 头——warp 的裸 500（text/plain、无 CORS）在
-- 跨源的 Tauri 页面里只会变成「Failed to fetch」。
json500 :: SResponse -> IO (KM.KeyMap Aeson.Value)
json500 r = do
  simpleStatus r @?= status500
  lookup "Access-Control-Allow-Origin" (simpleHeaders r) @?= Just "http://tauri.localhost"
  case Aeson.decode (simpleBody r) of
    Just (Aeson.Object o) -> pure o
    other -> assertFailure ("500 响应须是 JSON 对象: " <> show other)

-- | #9（medium）：POST /api/apply 的执行链此前没有异常边界——内核按设计原样重抛的
-- IOException（root 锁打不开、瞬断保护判为确定性错误、索引回写失败……）逃到 warp，
-- 页面只看到「Failed to fetch」或「没有执行」，而项可能已经落位并记了 Done。修后：
-- 500 + JSON（interrupted、planId、至此的 log），页面据 interrupted 说「执行中断」。
caseServeApplyInterrupted :: IO ()
caseServeApplyInterrupted = withSystemTempDirectory "pm-apply-int" $ \root -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  op <- mkCopyOp (root </> "src" </> "a.jpg") "AAA" ("成片" </> "a.jpg")
  plan <- mkPlanIO root [op]
  _ <- savePlan plan
  squatLock root
  env <- mkEnvA (ST.mkCfg root)
  flip runSession (serveApp env) $ do
    r <- postWithOrigin "/api/apply" (Aeson.encode (Aeson.object ["planId" Aeson..= plId plan]))
    liftIO' $ do
      o <- json500 r
      KM.lookup "interrupted" o @?= Just (Aeson.Bool True)
      KM.lookup "planId" o @?= Just (Aeson.String (plId plan))
      case KM.lookup "error" o of
        Just (Aeson.String e) -> assertBool ("error 应说执行中断: " <> T.unpack e) ("执行中断" `T.isInfixOf` e)
        other -> assertFailure ("error 应为字符串: " <> show other)
      case KM.lookup "log" o of
        Just (Aeson.Array _) -> pure ()
        other -> assertFailure ("log 应为数组: " <> show other)
  doesFileExist (root </> "成片" </> "a.jpg") >>= (@?= False)
  -- 按 UTF-8 读（本机 locale 是 GBK，裸 readFile 会在中文注释上解码失败；同 DocDriftTests.readUtf8）
  js <- T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile ("gui" </> "ui" </> "app.js")
  assertBool "GUI 的 applyPlan 须按 interrupted 分支（不再一律说「没有执行」）" ("j.interrupted" `isInfixOf` js)

-- | #9 的类：凡 handler 没有自带 try 的端点（recordPost 的 hold / notes，以及今后新增的），
-- 抛出的 IOException 由 serveApp 的最后一道边界接住，答 500 JSON（带 CORS）。
caseServeBoundaryRecordPost :: IO ()
caseServeBoundaryRecordPost = withSystemTempDirectory "pm-serve-bound" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  squatLock root
  env <- mkEnvW cfg
  flip runSession (serveApp env) $ do
    r <- postWithOrigin "/api/vault/hold" "{\"hold\":[\"a.jpg\"]}"
    liftIO' $ do
      o <- json500 r
      assertBool ("应带 error: " <> show o) (KM.member "error" o)
  doesFileExist (root </> ".pm" </> "vault-holds.json") >>= (@?= False)

-- | #43（low）：'Pm.Op.isTrashSrcRel' 此前只比首两级，@.pm\/trash@ 本身（FpDir）与
-- @.pm\/trash\/manifest.ndjson@ 都算合法的 rename 源——手编计划经 validatePlan 放行，
-- apply 把 write-ahead manifest（或整个隔离区）搬进用户数据，此后隔离载荷全部失登记、
-- @pm trash empty@ 无可清、undo 拒绝反转。收紧到生成形态（≥ 4 级）后 validatePlan 与
-- execPlan（取锁前、零写入）都拒，manifest 原地不动；组复位与 undo 反转拼出的真实
-- 形态（'trashSrcRel' + 'quarDirFor'）照旧放行。
caseTrashSrcShape :: Assertion
caseTrashSrcShape = withSystemTempDirectory "pm-audit" $ \dir -> do
  let root = dir </> "root"
      man = manifestPath root
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  createDirectoryIfMissing True (trashDir root)
  BS.writeFile man "MANIFEST\n"
  msha <- sha256File man
  let pid = plId plan
      qdir = quarDirFor pid SfxPlain
  -- 生成形态照旧放行：普通隔离与 ~d 位移隔离的载荷
  opPathsOk (OpRename (trashSrcRel (qdir </> "v.jpg")) "v.jpg" (FpFileSha "aa")) @?= True
  opPathsOk (OpRename (trashSrcRel (quarDirFor pid (SfxDisplaced 2) </> "a" </> "v.jpg")) ("a" </> "v.jpg") (FpFileSha "aa")) @?= True
  -- 报告的两个反例、大小写别名、整个隔离目录：都不是单个隔离载荷
  forM_
    [ OpRename (".pm" </> "trash") "x" (FpDir "aa")
    , OpRename (".pm" </> "trash" </> "manifest.ndjson") "m.txt" (FpFileSha msha)
    , OpRename (".PM" </> "Trash" </> "manifest.ndjson") "m.txt" (FpFileSha msha)
    , OpRename (trashSrcRel qdir) "x" (FpDir "aa")
    ]
    $ \bad -> do
      let p' = plan {plItems = [PlanItem 0 bad StPending Nothing]}
      either (const (pure ())) (const (assertFailure ("validatePlan 应拒绝 " <> describeOp bad))) (validatePlan p')
      r <- execPlan defaultExecEnv p'
      either (const (pure ())) (const (assertFailure ("execPlan 应拒绝 " <> describeOp bad))) r
  BS.readFile man >>= (@?= "MANIFEST\n")
  doesFileExist (root </> "m.txt") >>= (@?= False)
  doesFileExist (journalPath root) >>= (@?= False)

-- | #34（low）：classifyPending' 的 Copy 臂用 doesFileExist 探 dst——对象自身 ACL 拒绝（deny F）
-- 把「已落位、Done 丢失」塌成「C1 Info：Intent 后无痕迹」exit 0，重跑只会撞上一个「外来文件」；
-- Quarantine 臂的 victim 同形，塌成「Q? victim 与 trash 均不存在」。改走 userSideExists 三态
-- （同 Rename 臂 F033）：名字在 → dst 读不出报 C? Bad（不进 --repair 白名单）、victim 报 Q2。
caseDoctorDeniedUserSide :: Assertion
caseDoctorDeniedUserSide = withSystemTempDirectory "pm-audit" $ \dir -> do
  let root = dir </> "root"
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  let pid = plId plan
      dst = root </> "相册" </> "x.jpg"
      victim = root </> "v.jpg"
  createDirectoryIfMissing True (root </> "相册")
  BS.writeFile dst "X" -- 已落位（与 Intent 同内容），Done 丢失
  BS.writeFile victim "V"
  vsha <- sha256File victim
  now <- getCurrentTime
  withJournal root $ \j -> do
    jAppend j Barrier (JIntent (opId pid 0) op now)
    jAppend j Barrier (JIntent (opId pid 1) (OpQuarantine "v.jpg" vsha "t") now)
  rows <- withDenyAll dst (withDenyAll victim (doctorRows root))
  assertBool ("dst 在而读不出须报 C? Bad，不得是 C1「无痕迹」: " <> show rows) (("C?", Bad) `elem` rows && "C1" `notElem` map fst rows)
  assertBool ("victim 在而读不出须报 Q2，不得是 Q?「两处都不在」: " <> show rows) ("Q2" `elem` map fst rows && "Q?" `notElem` map fst rows)

-- | #58（low）：ConvertTests / ServeP8Tests 用 bracket_ 临时设环境变量、收尾一律删掉——把跑测试的
-- 人自己设的值（如 PM_PYTHON，ConvertTests 头注推荐的路子）一并删掉，串行的后续用例随之「找不到
-- python」。五处改走 TestUtil.withEnv：原来有值写回原值、原来没有才删，异常出口同样还原。另钉类
-- 规则：test/ 里「删环境变量」只许出现在 TestUtil（新代码不得再手写「删掉当还原」）。
caseWithEnvRestores :: Assertion
caseWithEnvRestores = do
  let k1 = "PM_AUDIT58_PRESET"
      k2 = "PM_AUDIT58_ABSENT"
  withEnv [(k1, "user-value")] $ do
    withEnv [(k1, "tmp1"), (k2, "tmp2")] $ do
      lookupEnv k1 >>= (@?= Just "tmp1")
      lookupEnv k2 >>= (@?= Just "tmp2")
    lookupEnv k1 >>= (@?= Just "user-value")
    lookupEnv k2 >>= (@?= Nothing)
    r <- try (withEnv [(k1, "boom")] (ioError (userError "中途抛出"))) :: IO (Either IOException ())
    either (const (pure ())) (const (assertFailure "应抛出")) r
    lookupEnv k1 >>= (@?= Just "user-value")
  lookupEnv k1 >>= (@?= Nothing)
  -- 类规则：非注释行里的「删环境变量」只许在 TestUtil；needle 拼接构造，免得本例自指命中
  let needle = "unset" <> "Env" :: String
      codeRefs s = any (\l -> not ("--" `isPrefixOf` dropWhile (== ' ') l) && needle `isInfixOf` l) (lines s)
  ts <- filter (\f -> ".hs" `isSuffixOf` f && f /= "TestUtil.hs") <$> listDirectory "test"
  bad <- filterM (\f -> codeRefs . T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile ("test" </> f)) ts
  bad @?= []

-- | #37（low）：C4 的复验窗口 =「上次 CleanShutdown 之后的全部 Done」，而 CleanShutdown 此前只由
-- execPlan 收尾写。批次崩在隔离 Done 之后（或 doctor --repair 补记的 Q-DONE-LOST Done）再
-- pm trash empty，下一次 doctor 把刚清掉的载荷报成 C4 Bad「Done 记录的目标不存在……重新生成
-- 计划」、exit 1，直到别的计划跑一次。用户裁定：trash empty 清除后在锁内补写一条。
caseTrashEmptyClosesWindow :: Assertion
caseTrashEmptyClosesWindow = withSystemTempDirectory "pm-audit" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  BS.writeFile (root </> "v.jpg") "VICTIM"
  vsha <- sha256File (root </> "v.jpg")
  plan <- mkPlanIO root [OpQuarantine "v.jpg" vsha "t"]
  _ <- execOk plan
  -- 崩在 Done 之后、CleanShutdown 之前
  journalEntries root >>= truncateJournalTo root . filter (not . isClean)
  code <- runTrash (mkCfg root) (TrashEmpty True) root
  code @?= 0
  rows <- doctorRows root
  assertBool ("已清除的隔离载荷不得再报 C4: " <> show rows) ("C4" `notElem` map fst rows)

-- | #37 回归（2026-09-26 横切审计「异常处理」）：#37 首版在清除后补写 CleanShutdown 时没有 try——
-- journal 写不进（盘掉了、.pm 不可写）就异常逃顶：清除报告没打印，进程以 1 退出（与「清干净但有
-- HELD」同码），正是 C102 修掉过的形状。现在照常报清除结果、另报一行、exit 2。journal 置只读
-- 让这条写入必然失败；同 #37 的崩溃形态（截掉 CleanShutdown），标记没写上时 doctor 确实会报 C4。
caseTrashEmptyMarkFails :: Assertion
caseTrashEmptyMarkFails = withSystemTempDirectory "pm-audit" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  BS.writeFile (root </> "v.jpg") "VICTIM"
  vsha <- sha256File (root </> "v.jpg")
  plan <- mkPlanIO root [OpQuarantine "v.jpg" vsha "t"]
  _ <- execOk plan
  journalEntries root >>= truncateJournalTo root . filter (not . isClean)
  let jf = journalPath root
  p0 <- getPermissions jf
  setPermissions jf (setOwnerWritable False p0)
  (out, code) <- captureStdout (runTrash (mkCfg root) (TrashEmpty True) root) `finally` setPermissions jf p0
  code @?= 2
  assertBool out ("✓ 已清除 1 项" `isInfixOf` out)
  assertBool out ("收尾标记没写进 journal" `isInfixOf` out)
  rows <- doctorRows root
  assertBool ("标记没写上，doctor 如报文所说报 C4: " <> show rows) ("C4" `elem` map fst rows)

-- | #8（medium）：遍历此前用 pathIsSymbolicLink 判「链接」——它对**任何** reparse 属性答 True，
-- OneDrive 云占位（含已下载的）、Dedup、WOF 压缩的文件整批落进「链接跳过」：不进索引、不进整理、
-- 每次 scan 退出 1。改按 name-surrogate 位（probeName；P3b-12 早已这样判写路径）。夹具是第三方
-- tag——本机造不出带过滤驱动的云 / Dedup 对象，但形态相同（没有 surrogate 位的 reparse point）；
-- 同一 tag 置上 surrogate 位即「会重定向」，仍不跟随。类规则：源码里 pathIsSymbolicLink 只剩
-- Exec 的位移槽「占用」判定（悬空链接也算占着——那是存在性，不是跟不跟随）。
caseWalkForeignReparse :: Assertion
caseWalkForeignReparse = withSystemTempDirectory "pm-audit" $ \dir -> do
  forM_ ["plain.jpg", "tp.jpg", "ns.jpg"] $ \n -> BS.writeFile (dir </> n) "X"
  setForeignReparse (dir </> "tp.jpg") 0x00000BEE
  setForeignReparse (dir </> "ns.jpg") 0x20000BEE
  probeName (dir </> "tp.jpg") >>= (@?= NamePlain)
  probeName (dir </> "ns.jpg") >>= (@?= NameSurrogate)
  (files, errs, uncovered) <- listTreeCov SkipDotDirs dir
  sort files @?= ["plain.jpg", "tp.jpg"]
  errs @?= [("ns.jpg", reparseSkipNote)]
  uncovered @?= []
  bad <- codeLinesWhere ("pathIsSymbolicLink" `isInfixOf`) =<< srcHsFiles
  nub (map fst bad) @?= ["Exec.hs"]

-- | #8 用户裁定「不读，单列出来」：内容不在本机的文件（云端未下载）读它就是触发下载——整库扫描会
-- 变成整库下载。要读内容的两处（scan 的 hash、sort 的源清单）读前不读、单列「云端未下载」；stat
-- 只读元数据，新鲜度核对与 (size, mtime) 复用照常。夹具用 OFFLINE 位（用户态能设的那一位）。
caseCloudOnlyNotRead :: Assertion
caseCloudOnlyNotRead = withSystemTempDirectory "pm-audit" $ \dir -> do
  -- 属性位按 SDK 取值（winnt.h:15317/15326/15327）进；目录 / 归档 / reparse / PINNED（已下载且钉住的云文件）不进
  map isCloudOnlyAttr [0x1000, 0x40000, 0x400000] @?= [True, True, True]
  map isCloudOnlyAttr [0x10, 0x20, 0x400, 0x80000] @?= [False, False, False, False]
  let root = dir </> "lib"
      at y = UTCTime (fromGregorian y 1 1) 0 -- 远离 racy 窗口：stat 复用判据才会命中
  createDirectoryIfMissing True root
  forM_ ["a.jpg", "b.jpg", "c.jpg"] $ \n -> BS.writeFile (root </> n) "ORIGINAL" >> setModificationTime (root </> n) (at 2020)
  r1 <- scanRoot (ScanOpts 1 False) Nothing "rid" root
  srHashed r1 @?= 3
  -- b 没改、之后变成云端未下载；c 改过再变成云端未下载；d 新来、云端未下载
  BS.writeFile (root </> "c.jpg") "CHANGED-CONTENT"
  setModificationTime (root </> "c.jpg") (at 2021)
  BS.writeFile (root </> "d.jpg") "NEW"
  setModificationTime (root </> "d.jpg") (at 2020)
  mapM_ (setOffline . (root </>)) ["b.jpg", "c.jpg", "d.jpg"]
  r2 <- scanRoot (ScanOpts 1 False) (Just (srCatalog r1)) "rid" root
  let e1 = catEntries (srCatalog r1)
      e2 = catEntries (srCatalog r2)
  srHashed r2 @?= 0 -- 一个都没读
  srReused r2 @?= 2 -- a 与 b 按 stat 复用：b 不必读就核对得了
  sort (srErrors r2) @?= [("c.jpg", cloudOnlyNote), ("d.jpg", cloudOnlyNote)]
  Map.lookup "c.jpg" e2 @?= Map.lookup "c.jpg" e1 -- 改过而没读：上次快照值原样保留（查不出 ≠ 不存在）
  Map.member "d.jpg" e2 @?= False
  srCarried r2 @?= 1
  -- stat 只读元数据、不触发下载：新鲜度核对照常（c 变更、d 新增），不记成读取错误
  freshnessSweep root "" e2 >>= (@?= (1, 1, 0, 0))
  (outScan, ()) <- captureStdout (reportScanIssues r2)
  assertBool ("scan 报告应把云端未下载单列: " <> outScan) ("☁ 2 个文件云端未下载" `isInfixOf` outScan && not ("个条目有错误" `isInfixOf` outScan))
  -- sort 的源清单：云端未下载的照片不读拍摄时间、单列一格；没读过的照片不替它担保 → 退出码 1
  let src = dir </> "card"
  createDirectoryIfMissing True src
  BS.writeFile (src </> "p.jpg") "P"
  BS.writeFile (src </> "q.jpg") "Q"
  setOffline (src </> "q.jpg")
  sf <- listSource src
  map takeFileName (sfPhotos sf) @?= ["p.jpg"]
  map (\(p, e) -> (takeFileName p, e)) (sfErrors sf) @?= [("q.jpg", cloudOnlyNote)]
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  (outS, codeS) <- captureStdout (runSortSurvey src 72 (mkCfg root))
  codeS @?= 1
  assertBool ("sort 清单应把云端未下载单列一格: " <> outS) ("云端未下载 1 个（" `isInfixOf` outS && not ("遍历时出错 1 个" `isInfixOf` outS))
  js <- T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile ("gui" </> "ui" </> "app.js")
  assertBool "GUI 整理页须单列 sv.cloudOnly" ("sv.cloudOnly" `isInfixOf` js)

-- | src 与 app 下全部 .hs（递归）——类规则钉针（#8 / #3）共用。
srcHsFiles :: IO [FilePath]
srcHsFiles = (<>) <$> walk "src" <*> walk "app"
 where
  walk d = do
    es <- listDirectory d
    concat <$> mapM (\e -> doesDirectoryExist (d </> e) >>= \isD -> if isD then walk (d </> e) else pure [d </> e | ".hs" `isSuffixOf` e]) es

-- | 这些文件的非注释行里满足谓词的 (文件名, 行)。
codeLinesWhere :: (String -> Bool) -> [FilePath] -> IO [(FilePath, String)]
codeLinesWhere p fs = concat <$> mapM one fs
 where
  one f = map ((,) (takeFileName f)) . filter code . lines . T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile f
  code l = not ("--" `isPrefixOf` dropWhile (== ' ') l) && p l

-- | #3（medium）：暂存区按写死的拼写 To-Be-Sync'd 精确比较。用户手建成 to-be-sync'd（NTFS 上就是同一个
-- 目录）时，新鲜度守卫的 catalog 切片（精确 → 空）对上盘面（折大小写 → 满），每个文件都算「新增」，
-- pm scan 也补不回来：import / clean / sort 永远被拒，pm status 却说一致。用户裁定「大小写都认」：布局
-- 层名（暂存区、Raw / Processed、归档三层）一律经 Pm.Import.sameComp / underLayers 折叠比较；新鲜度
-- 核对的前缀取盘上拼写、键按路径身份比。类规则：src 里不再拿层名做 == / /= / elem 比较。
caseStagingCaseFold :: Assertion
caseStagingCaseFold = withSystemTempDirectory "pm-audit" $ \dir -> do
  now <- getCurrentTime
  let root = dir </> "root"
      stg = "to-be-sync'd"
      put rel c = createDirectoryIfMissing True (takeDirectory (root </> rel)) >> BS.writeFile (root </> rel) c
      emptyCat = Catalog "b" now mempty
  put (stg </> "raw" </> "26-08-Atlanta" </> "a.ARW") "AAA"
  put (stg </> "processed" </> "26-08-Atlanta" </> "a.jpg") "JJJ"
  put (stg </> "待修改" </> "w.jpg") "WWW"
  put (stg </> "raw" </> "26-07-Boston" </> "b.ARW") "BBB"
  put ("raw" </> "2026" </> "26-07-Boston-Raw" </> "b.ARW") "BBB" -- 同内容已在归档层（小写 raw）
  cat <- srCatalog <$> scanRoot (ScanOpts 1 False) Nothing "rid" root
  -- 守卫：catalog 与盘面一致即放行（修复前「新增 4」，pm scan 也补不回来）
  stagingFresh root cat >>= (@?= Right ())
  -- 计划落位按规范拼写记进 catalog（updateCatalog 按 dstRel）：同一个文件，不得算成「新增 + 消失」
  let respell q = if underLayers [stagingTop] q then joinPath (stagingTop : drop 1 (splitDirectories q)) else q
      canon = Map.fromList [(respell k, e {enPath = respell k}) | (k, e) <- Map.toList (catEntries cat)]
  stagingFresh root cat {catEntries = canon} >>= (@?= Right ())
  -- import 路由：小写层名照样认，目标用规范拼写；同内容已在（小写 raw 的）归档层 → 已归档冗余
  let rep = planImport cat
  sort (map snd (irCopy rep)) @?= sort ["Raw" </> "2026" </> "26-08-Atlanta-Raw" </> "a.ARW", "成片" </> "26-08-Atlanta" </> "a.jpg"]
  map snd (irAlready rep) @?= ["Raw" </> "2026" </> "26-07-Boston-Raw" </> "b.ARW"]
  irPendingEdit rep @?= [stg </> "待修改" </> "w.jpg"]
  irUnrecognized rep @?= []
  stagingArchivedSummary cat @?= (3, 1)
  clPendingEdit (planClean cat emptyCat) @?= [stg </> "待修改" </> "w.jpg"]
  map enPath (bdAdd (backupDiff cat emptyCat)) @?= ["raw" </> "2026" </> "26-07-Boston-Raw" </> "b.ARW"]
  archiveLayerRel ("raw" </> "x.jpg") @?= True
  -- 折叠没把守卫变成摆设：盘上多一个文件照常拦下
  put (stg </> "raw" </> "26-08-Atlanta" </> "c.ARW") "CCC"
  stagingFresh root cat >>= either (\m -> assertBool m ("新增 1" `isInfixOf` m)) (const (assertFailure "新文件须拦下"))
  -- 按目录启用了大小写敏感的根（fsutil 设不了就跳过这一段）：写死的拼写找不到手建的 to-be-sync'd，
  -- 核对前缀必须取盘上拼写；两种拼写并存时不替用户挑，拒绝并说明
  let root2 = dir </> "cs"
      put2 rel c = createDirectoryIfMissing True (takeDirectory (root2 </> rel)) >> BS.writeFile (root2 </> rel) c
  createDirectoryIfMissing True root2
  en <- try (readCreateProcess (shell ("fsutil file setCaseSensitiveInfo \"" <> root2 <> "\" enable")) "") :: IO (Either IOException String)
  when (either (const False) (const True) en) $ do
    put2 (stg </> "raw" </> "26-08-Atlanta" </> "a.ARW") "AAA"
    cat2 <- srCatalog <$> scanRoot (ScanOpts 1 False) Nothing "rid2" root2
    stagingFresh root2 cat2 >>= (@?= Right ())
    createDirectoryIfMissing True (root2 </> stagingTop)
    stagingFresh root2 cat2 >>= either (\m -> assertBool m ("只差大小写" `isInfixOf` m)) (const (assertFailure "两种拼写并存须拒绝"))
  -- 类规则：src 的非注释行里不再拿布局层名做 == / /= / elem 比较，也不拿它们当 case 模式字面量
  -- （比较符须紧挨层名：同一行里拿别的值比较、顺手拼个 "Raw" 路径不算）
  let pats =
        [o <> n | o <- ["== ", "/= "], n <- ["stagingTop", "[stagingTop", "\"Raw\"", "\"Processed\"", "[\"Raw\"", "[[\"Raw\"]"]]
          <> [n <> " " <> o | o <- ["==", "/="], n <- ["stagingTop", "\"Raw\"", "\"Processed\""]]
          <> ["`elem` archiveLayers", "`elem` map (: []) archiveLayers", "`elem` [[\"Raw\"]", "`elem` [\"Raw\"", "(\"Raw\",", "(\"Processed\","]
      cmpLayer l = any (`isInfixOf` l) pats
  bad <- codeLinesWhere cmpLayer =<< srcHsFiles
  bad @?= []

-- | #61（横切审计「异常处理」）：main 没有进程级边界——逃出命令体的同步 IO 异常（§6.4 写口逃逸 = 进程
-- 死亡语义，设计内）落到 GHC 默认顶层处理器，以 1 退出，与 §5.1「1 = 有差异 / 待办」同码。
caseExitBoundary :: Assertion
caseExitBoundary = do
  exitBoundary (pure 1) >>= (@?= 1)
  exitBoundary (ioError (userError "横切审计 #61 注入的 IO 失败（预期输出）")) >>= (@?= 2)
  r <- try (exitBoundary (throwIO UserInterrupt)) :: IO (Either AsyncException Int)
  r @?= Left UserInterrupt
  m <- T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile ("app" </> "Main.hs")
  assertBool "main 须经 exitBoundary 调命令体" ("exitBoundary (run cmd)" `isInfixOf` m)
