{-# LANGUAGE OverloadedStrings #-}

-- | 2026-09-25 全量 debug 审计（docs/reviews/2026-09-25-full-debug-audit.md，编号
-- @#id@ 与报告一致）的修复钉针——凡既有主题模块已触 750 行预算（GuardTests /
-- PathGuardTests / KernelTests …）而放不下的用例收在这里；能就地扩展既有用例的
-- 仍就地扩展。每条钉一个屏障：拆掉对应修复，用例必须转红。
module AuditFixTests (auditFixTests) where

import Control.Exception (finally)
import Control.Monad (forM_, when)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (isInfixOf, isSuffixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Data.Time (getCurrentTime)
import Network.HTTP.Types (hAuthorization, hContentType, hHost, hOrigin, methodPost, status500)
import Network.Wai (Request (..), defaultRequest)
import Network.Wai.Test (SRequest (..), SResponse (..), Session, runSession, setPath, srequest)
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing, doesFileExist, listDirectory, removeFile)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..), configFilePath, createRootInfo, loadConfig, readRootInfo, withConfigLock, writeConfig, writeRootInfo)
import Pm.Doctor (Severity (..))
import Pm.Exec (defaultExecEnv, execPlan)
import Pm.Hash (sha256File)
import Pm.Journal (JEntry (..), Sync (..), jAppend, journalPath, withJournal)
import Pm.Op (Fingerprint (..), Op (..), OpIdSuffix (..), describeOp, opId, opPathsOk, trashSrcRel)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), savePlan, validatePlan)
import Pm.Serve (serveApp)
import Pm.Trash (manifestPath, quarDirFor, trashDir)
import Pm.Types (RootInfo (..), RootRole (..))
import ServeTests (fixture, liftIO', mkEnvA, mkEnvW, tok, withVault)
import qualified ServeTests as ST
import TestUtil (doctorRows, mkCopyOp, mkPlanIO, withDenyAll)

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
