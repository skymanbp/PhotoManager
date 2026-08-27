{-# LANGUAGE OverloadedStrings #-}

-- | P4-1：@pm serve@ 的 loopback JSON API。用 wai-extra 的 'Network.Wai.Test'
-- 直接打 'Application'，不开端口——端口/socket 那层只有 'bindLoopback'
-- 一小段，由真实库手动冒烟覆盖。
--
-- 每条用例钉一道闸：删掉对应判定，用例必须转红。
--
-- P7 拆分（750 行预算）：写端点用例在 "ServeWriteTests"。fixture 与请求
-- 原语从这里导出给它复用——抄第二份就是第二套 fixture，迟早分叉。
module ServeTests
  ( serveTests
  , tok
  , mkCfg
  , seedConfig
  , mkEnv
  , mkEnvW
  , mkEnvA
  , postReq
  , getReq
  , mkFileLink
  , mkHardLink
  , field
  , arrLen
  , firstOf
  , decodeBody
  , fixture
  , withVault
  , liftIO'
  , seedSortSrc
  ) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BSL
import Data.Char (chr, isHexDigit)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import qualified Data.Text.Encoding as TE
import Pm.Config (Config (..), pmDir, writeConfig, writeRootInfo)
import Pm.Hash (sha256File)
import Pm.Op (Fingerprint (..), Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan, newPlanId, savePlan)
import Pm.Serve (ServeEnv, allowedOrigin, hostOk, listPlans, newServeEnv, newToken, portOk, serveApp)
import Pm.Types (Catalog (..), Entry (..), FileKind (..), RootInfo (..), RootRole (..))
import SortTests (photoAt)
import Pm.Vault (VaultReport (..), computeVault, renderVaultJson)
import TestUtil

serveTests :: TestTree
serveTests =
  testGroup
    "P4-1 pm serve loopback JSON API"
    [ testCase "P4-1 token：缺失/错误 → 401；正确 → 200；token 为 32 位 hex" caseServeToken
    , testCase "P4-1 Host：非 127.0.0.1 → 403（DNS rebinding）；缺失 → 403；端口尾部精确解析" caseServeHost
    , testCase "P4-1 Origin：非 Tauri 来源 → 403；Tauri 来源 → 回 CORS 头；预检 OPTIONS 免 token" caseServeOrigin
    , testCase "P4-1 /api/status：fixture 索引 → files/layers/exit 与 runStatus 同源；无索引 → index null + exit 2" caseServeStatus
    , testCase "P4-1 /api/thumb/<sha>：JPEG 条目原字节；非 JPEG 条目 404；坏 sha 400" caseServeThumb
    , testCase "P4-1 /api/plans + /api/plan/<id>：列出/装载；坏 id 400；不存在 404" caseServePlans
    , testCase "P4-2 /api/vault/new：NEW 名字配上主库 catalog 的 sha/size；无 vault 配置 → 404" caseServeVaultNew
    , testCase "P4-2 /api/vault/status 与 CLI --json 的 stdout 逐字节相同（含末尾 LF）" caseServeVaultStatusBytes
    , testCase "P4-2 thumb：扫描后条目被换成指向库外的 symlink → 404，库外文件字节不外泄" caseServeThumbLink
    , testCase "P4-2 --port 范围 0..65535（越界不得静默折回）" caseServePortRange
    , testCase "P5-C POST /api/apply：--writable 不够 → 403（执行是另一级授权）；坏 JSON 400；超大体 413；不存在的计划 409" caseServeApplyGuards
    , testCase "P5-C POST /api/apply：真执行一个 copy 计划，字节落位、逐项结果与 log 回 JSON（不走 stdout）" caseServeApplyRuns
    , testCase "P5-C POST /api/apply --only：与 CLI 同一个解析，未选中的项不执行" caseServeApplyOnly
    , testCase "P5-C POST /api/apply：执行期屏障对 API 与 CLI 一视同仁（dedupe 计划会隔离最后一份 → 一项都不执行）" caseServeApplyBarrier
    , testCase "P5-E GET /api/sort/survey：缺 src → 400；有源 → 分段与 CLI 的 surveySort 同源" caseServeSortSurvey
    , testCase "P5-E POST /api/sort/plan：只读 403；place 与 event 同给/都不给 → 400；合法 → 计划落在 .pm/plans 且照片零改动" caseServeSortPlan
    ]

tok :: BS.ByteString
tok = "0123456789abcdef0123456789abcdef"

mkCfg :: FilePath -> Config
mkCfg root = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | 把 PM_CONFIG 指向的那份配置**先建起来**。'Pm.ConfigEdit.configTxn' 在锁内
-- 重新读盘（不拿内存里的旧快照写回），因此配置文件必须已存在——生产里
-- `pm serve` 必然跑在 `pm init` 之后，这个前提本来就成立；用例要把它摆明。
seedConfig :: FilePath -> IO ()
seedConfig root = () <$ writeConfig (mkCfg root)

-- | 缺省只读（与 `pm serve` 不带 --writable 相同）。
mkEnv :: Config -> IO ServeEnv
mkEnv cfg = newServeEnv cfg tok False False

mkEnvW :: Config -> IO ServeEnv
mkEnvW cfg = newServeEnv cfg tok True False

-- | 第三级授权：允许执行。缺省与 --writable 都到不了这里。
mkEnvA :: Config -> IO ServeEnv
mkEnvA cfg = newServeEnv cfg tok False True

-- | 带 Host + Bearer 的 POST（JSON 体）。
postReq :: BS.ByteString -> BSL.ByteString -> Session SResponse
postReq path body =
  srequest $
    SRequest
      ( setPath
          defaultRequest
            { requestMethod = methodPost
            , requestHeaderHost = Just "127.0.0.1:4321"
            , requestHeaders = [(hHost, "127.0.0.1:4321"), (hAuthorization, "Bearer " <> tok), (hContentType, "application/json")]
            }
          path
      )
      body

mkFileLink :: FilePath -> FilePath -> IO ()
mkFileLink link target =
  () <$ readCreateProcess (shell ("mklink \"" <> link <> "\" \"" <> target <> "\"")) ""

mkHardLink :: FilePath -> FilePath -> IO ()
mkHardLink link target =
  () <$ readCreateProcess (shell ("mklink /H \"" <> link <> "\" \"" <> target <> "\"")) ""

-- | 带 Host + Bearer 的 GET。
getReq :: BS.ByteString -> [Header] -> BS.ByteString -> Session SResponse
getReq path extra token =
  request $
    setPath
      defaultRequest
        { requestMethod = methodGet
        , requestHeaderHost = Just "127.0.0.1:4321"
        , requestHeaders = [(hHost, "127.0.0.1:4321"), (hAuthorization, "Bearer " <> token)] <> extra
        }
      path

field :: [String] -> Aeson.Value -> Maybe Aeson.Value
field [] v = Just v
field (k : ks) (Aeson.Object o) = KM.lookup (Key.fromString k) o >>= field ks
field _ _ = Nothing

-- | JSON 数组长度（非数组 → Nothing）。
arrLen :: Maybe Aeson.Value -> Maybe Int
arrLen (Just (Aeson.Array a)) = Just (length a)
arrLen _ = Nothing

-- | JSON 数组的第一个元素（非数组/空数组 → Nothing）。
firstOf :: Maybe Aeson.Value -> Maybe Aeson.Value
firstOf (Just (Aeson.Array a)) = case foldr (:) [] a of
  (x : _) -> Just x
  [] -> Nothing
firstOf _ = Nothing

decodeBody :: SResponse -> Aeson.Value
decodeBody r = either (error . ("响应不是 JSON: " <>)) id (Aeson.eitherDecode (simpleBody r))

-- | 最小 fixture：root-id + 两条目 catalog（一张 JPEG、一张 ARW），文件真实落盘。
fixture :: FilePath -> IO (Config, BS.ByteString, T.Text, T.Text)
fixture root = do
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True (root </> "相册")
  createDirectoryIfMissing True (root </> "Raw" </> "25-01-X-Raw")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  let jpg = root </> "相册" </> "a.jpg"
      arw = root </> "Raw" </> "25-01-X-Raw" </> "b.ARW"
      jpgBytes = "\xFF\xD8\xFF\xE0JFIF-fixture-bytes"
  BS.writeFile jpg jpgBytes
  BS.writeFile arw "RAW-BYTES"
  sj <- sha256File jpg
  sa <- sha256File arw
  saveCatalog
    root
    ( mkCat
        [ Entry ("相册" </> "a.jpg") (fromIntegral (BS.length jpgBytes)) 0 sj KindPhoto Nothing
        , Entry ("Raw" </> "25-01-X-Raw" </> "b.ARW") 9 0 sa KindPhoto Nothing
        ]
    )
  pure (mkCfg root, jpgBytes, sj, sa)

-- | vault fixture：三个类目都空 → 相册里的一切都是 NEW。
withVault :: FilePath -> Config -> IO Config
withVault vdir cfg0 = do
  mapM_ (\c -> createDirectoryIfMissing True (vdir </> c)) ["landscape", "portrait", "urban"]
  pure cfg0 {cfgVaultPath = Just vdir}

caseServeToken :: IO ()
caseServeToken = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, _, _) <- fixture root
  t <- newToken
  BS.length t @?= 32
  assertBool ("token 应为 hex: " <> BC.unpack t) (BC.all isHexDigit t)
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r0 <- request (setPath defaultRequest {requestMethod = methodGet, requestHeaderHost = Just "127.0.0.1", requestHeaders = [(hHost, "127.0.0.1")]} "/api/ping")
    assertStatus 401 r0
    r1 <- getReq "/api/ping" [] "0123456789abcdef0123456789abcdeX"
    assertStatus 401 r1
    r1' <- getReq "/api/ping" [] "short"
    assertStatus 401 r1'
    r2 <- getReq "/api/ping" [] tok
    assertStatus 200 r2
    assertHeader "Content-Type" "application/json; charset=utf-8" r2
    liftIO' (field ["ok"] (decodeBody r2) @?= Just (Aeson.Bool True))

caseServeHost :: IO ()
caseServeHost = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, _, _) <- fixture root
  assertBool "127.0.0.1" (hostOk "127.0.0.1")
  assertBool "127.0.0.1:5" (hostOk "127.0.0.1:5")
  assertBool "127.0.0.1.evil" (not (hostOk "127.0.0.1.evil"))
  assertBool "localhost" (not (hostOk "localhost"))
  -- 十八轮：端口尾部精确解析，不是前缀
  assertBool "127.0.0.1:1@evil" (not (hostOk "127.0.0.1:1@evil"))
  assertBool "127.0.0.1:abc" (not (hostOk "127.0.0.1:abc"))
  assertBool "127.0.0.1:" (not (hostOk "127.0.0.1:"))
  assertBool "127.0.0.1:123456" (not (hostOk "127.0.0.1:123456"))
  assertBool "127.0.0.1:65535" (hostOk "127.0.0.1:65535")
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- request (setPath defaultRequest {requestMethod = methodGet, requestHeaderHost = Just "evil.example:80", requestHeaders = [(hHost, "evil.example:80"), (hAuthorization, "Bearer " <> tok)]} "/api/ping")
    assertStatus 403 r
    r2 <- request (setPath defaultRequest {requestMethod = methodGet, requestHeaderHost = Nothing, requestHeaders = [(hAuthorization, "Bearer " <> tok)]} "/api/ping")
    assertStatus 403 r2
    r3 <- request (setPath defaultRequest {requestMethod = methodGet, requestHeaderHost = Just "127.0.0.1:1@evil", requestHeaders = [(hHost, "127.0.0.1:1@evil"), (hAuthorization, "Bearer " <> tok)]} "/api/ping")
    assertStatus 403 r3

caseServeOrigin :: IO ()
caseServeOrigin = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, _, _) <- fixture root
  assertBool "tauri://localhost" (allowedOrigin "tauri://localhost")
  assertBool "http://evil" (not (allowedOrigin "http://evil"))
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/ping" [(hOrigin, "http://evil.example")] tok
    assertStatus 403 r
    r2 <- getReq "/api/ping" [(hOrigin, "tauri://localhost")] tok
    assertStatus 200 r2
    assertHeader "Access-Control-Allow-Origin" "tauri://localhost" r2
    -- 预检：不带 token，带允许的 Origin → 204 + CORS 头
    r3 <-
      request
        ( setPath
            defaultRequest
              { requestMethod = methodOptions
              , requestHeaderHost = Just "127.0.0.1:1"
              , requestHeaders = [(hHost, "127.0.0.1:1"), (hOrigin, "http://tauri.localhost")]
              }
            "/api/status"
        )
    assertStatus 204 r3
    assertHeader "Access-Control-Allow-Origin" "http://tauri.localhost" r3
    -- 预检不放行坏来源
    r4 <-
      request
        ( setPath
            defaultRequest
              { requestMethod = methodOptions
              , requestHeaderHost = Just "127.0.0.1:1"
              , requestHeaders = [(hHost, "127.0.0.1:1"), (hOrigin, "http://evil.example")]
              }
            "/api/status"
        )
    assertStatus 403 r4

caseServeStatus :: IO ()
caseServeStatus = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, _, _) <- fixture root
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/status" [] tok
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      field ["index", "files"] v @?= Just (Aeson.Number 2)
      field ["exit"] v @?= Just (Aeson.Number 0)
      field ["index", "freshness"] v @?= Just Aeson.Null -- 默认 cached：不做 stat 扫描
      field ["index", "backup", "state"] v @?= Just (Aeson.String "absent")
      field ["index", "vault"] v @?= Just Aeson.Null -- 配置无 vault
      arrLen (field ["index", "layers"] v) @?= Just 2
    -- fresh=1：fixture 里文件与索引一致 → 三项皆 0
    rf <- getReq "/api/status?fresh=1" [] tok
    assertStatus 200 rf
    liftIO' (field ["index", "freshness", "missing"] (decodeBody rf) @?= Just (Aeson.Number 0))
  -- 无索引的 root：index null、exit 2
  let root2 = dir </> "root2"
  createDirectoryIfMissing True (pmDir root2)
  now <- getCurrentTime
  writeRootInfo root2 (RootInfo "m2" RoleMain now Nothing)
  env2 <- mkEnv (mkCfg root2)
  flip runSession (serveApp env2) $ do
    r <- getReq "/api/status" [] tok
    assertStatus 200 r
    liftIO' $ do
      field ["index"] (decodeBody r) @?= Just Aeson.Null
      field ["exit"] (decodeBody r) @?= Just (Aeson.Number 2)

caseServeThumb :: IO ()
caseServeThumb = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, jpgBytes, sj, sa) <- fixture root
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq ("/api/thumb/" <> BC.pack (T.unpack sj)) [] tok
    assertStatus 200 r
    assertHeader "Content-Type" "image/jpeg" r
    liftIO' (BSL.toStrict (simpleBody r) @?= jpgBytes)
    -- 大写 hex 也能命中（catalog 里是小写）
    ru <- getReq ("/api/thumb/" <> BC.pack (T.unpack (T.toUpper sj))) [] tok
    assertStatus 200 ru
    -- ARW 条目：不提供
    r2 <- getReq ("/api/thumb/" <> BC.pack (T.unpack sa)) [] tok
    assertStatus 404 r2
    -- 坏 sha
    r3 <- getReq "/api/thumb/not-a-sha" [] tok
    assertStatus 400 r3
    r4 <- getReq "/api/thumb/0000000000000000000000000000000000000000000000000000000000000000" [] tok
    assertStatus 404 r4

caseServePlans :: IO ()
caseServePlans = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, sj, _) <- fixture root
  -- 第一方自审 R1：.pm/plans 被文件占名（列不了目录）→ errors 一条，不得
  -- 静默当「没有计划」（旧 doesDirectoryExist 塌 False → 空列表零报错）。
  writeFile (pmDir root </> "plans") ""
  (ps0, errs0) <- listPlans root
  ps0 @?= []
  assertBool ("plans 占名应报 errors: " <> show errs0) (not (null errs0))
  removeFile (pmDir root </> "plans")
  plan <- mkPlanIO root [OpRename ("相册" </> "a.jpg") ("相册" </> "a2.jpg") (FpFileSha sj)]
  _ <- savePlan plan
  (ps, errs) <- listPlans root
  map plId ps @?= [plId plan]
  errs @?= []
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/plans" [] tok
    assertStatus 200 r
    liftIO' $ do
      let v = decodeBody r
      arrLen (field ["plans"] v) @?= Just 1
      field ["errors"] v @?= Just (Aeson.Array mempty)
    r2 <- getReq ("/api/plan/" <> BC.pack (T.unpack (plId plan))) [] tok
    assertStatus 200 r2
    liftIO' (field ["id"] (decodeBody r2) @?= Just (Aeson.String (plId plan)))
    r3 <- getReq "/api/plan/..%5Cx" [] tok
    assertStatus 400 r3
    r4 <- getReq "/api/plan/20260101-000000-abcdef" [] tok
    assertStatus 404 r4

-- | P4-2：分类页按 sha 拉缩略图，vault/status 的 "new" 只有名字。fixture 的
-- vault 三个类目都空 → 相册/a.jpg 是 NEW，sha 须等于 catalog 里的 sha。
caseServeVaultNew :: IO ()
caseServeVaultNew = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, sj, _) <- fixture root
  -- 无 vault 配置 → 404（computeVault 的退出码 2 映射）
  env0 <- mkEnv cfg0
  flip runSession (serveApp env0) $ do
    r0 <- getReq "/api/vault/new" [] tok
    assertStatus 404 r0
  cfg <- withVault vdir cfg0
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/vault/new" [] tok
    assertStatus 200 r
    liftIO' $ do
      let v = decodeBody r
      arrLen (field ["new"] v) @?= Just 1
      arrLen (field ["categories"] v) @?= Just 3
      let first = firstOf (field ["new"] v)
      (first >>= field ["name"]) @?= Just (Aeson.String "a.jpg")
      (first >>= field ["sha"]) @?= Just (Aeson.String sj)
      (first >>= field ["size"]) @?= Just (Aeson.Number (fromIntegral (BS.length jpgBytes)))

-- | 十八轮 minor：此前 API 少 CLI `putStrLn` 的末尾 LF，"逐字节相同"不成立。
-- 期望值由同一 renderVaultJson 独立算出再加 "\n"。
caseServeVaultStatusBytes :: IO ()
caseServeVaultStatusBytes = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  er <- computeVault True cfg
  expected <- case er of
    Left (m, _) -> assertFailure ("computeVault 失败: " <> m)
    Right r -> pure (renderVaultJson (vrSrcDir r) (vrVaultDir r) (vrSrcCount r) (vrVaultCount r) (vrDiff r) (vrUnpushable r) (vrUnstable r) (vrHeld r) (vrHeldStale r) <> "\n")
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/vault/status" [] tok
    assertStatus 200 r
    liftIO' (simpleBody r @?= expected)
    liftIO' (BSL.last (simpleBody r) @?= 10)

-- | 十八轮残余硬化：enPath 只过了词法闸；扫描后把条目换成指向库外文件的
-- symlink，按名字 readFile 会跟随并把库外字节交给客户端。读取前逐级
-- 'resolveUnder' → 404，库外字节不外泄。删掉那次解析，本例转红。
caseServeThumbLink :: IO ()
caseServeThumbLink = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  (cfg, _, sj, _) <- fixture root
  createDirectoryIfMissing True outside
  BS.writeFile (outside </> "secret.jpg") "OUTSIDE-SECRET"
  -- 扫描之后（catalog 已含 相册/a.jpg 的 sha）把该条目换成库外 symlink
  removeFile (root </> "相册" </> "a.jpg")
  mkFileLink (root </> "相册" </> "a.jpg") (outside </> "secret.jpg")
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq ("/api/thumb/" <> BC.pack (T.unpack sj)) [] tok
    assertStatus 404 r
    liftIO' (assertBool "库外字节不得出现在响应里" (not ("OUTSIDE-SECRET" `BS.isInfixOf` BSL.toStrict (simpleBody r))))

caseServePortRange :: IO ()
caseServePortRange = do
  assertBool "0" (portOk 0)
  assertBool "65535" (portOk 65535)
  assertBool "65536" (not (portOk 65536))
  assertBool "-1" (not (portOk (-1)))

-- 'Network.Wai.Test.Session' 是 ReaderT/StateT 叠 IO；HUnit 断言直接 liftIO。
liftIO' :: IO a -> Session a
liftIO' = liftIO


-- ─── P5-C：POST /api/apply ─────────────────────────────────────────────────

-- | 建一个只有 copy 的真实计划：源在 root 外，目标是 @成片\/<名>@。
seedApplyPlan :: FilePath -> [(String, String)] -> IO T.Text
seedApplyPlan root files = do
  createDirectoryIfMissing True (root </> "src")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  ops <- mapM (\(n, body) -> mkCopyOp (root </> "src" </> n) body ("成片" </> n)) files
  plan <- mkPlanIO root ops
  _ <- savePlan plan
  pure (plId plan)

caseServeApplyGuards :: IO ()
caseServeApplyGuards = withSystemTempDirectory "pm-serve-apply" $ \root -> do
  pid <- seedApplyPlan root [("a.jpg", "AAA")]
  let cfg = mkCfg root
  -- --writable 到不了执行：这是本端点单独一个开关的全部意义。
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r <- postReq "/api/apply" (Aeson.encode (Aeson.object ["planId" Aeson..= pid]))
    liftIO (simpleStatus r @?= status403)
  liftIO (doesFileExist (root </> "成片" </> "a.jpg") >>= (@?= False))
  envA <- mkEnvA cfg
  flip runSession (serveApp envA) $ do
    bad <- postReq "/api/apply" "{"
    liftIO (simpleStatus bad @?= status400)
    big <- postReq "/api/apply" (BSL.replicate (64 * 1024 + 1) 120)
    liftIO (simpleStatus big @?= status413)
    -- 格式合法但盘上没有这个计划
    miss <- postReq "/api/apply" (Aeson.encode (Aeson.object ["planId" Aeson..= ("20260101-000000-abcdef" :: T.Text)]))
    liftIO (simpleStatus miss @?= status409)
  -- 四次被拒之后，照片一个字节都不该动
  doesFileExist (root </> "成片" </> "a.jpg") >>= (@?= False)

caseServeApplyRuns :: IO ()
caseServeApplyRuns = withSystemTempDirectory "pm-serve-apply" $ \root -> do
  pid <- seedApplyPlan root [("a.jpg", "AAA"), ("b.jpg", "BBB")]
  envA <- mkEnvA (mkCfg root)
  flip runSession (serveApp envA) $ do
    r <- postReq "/api/apply" (Aeson.encode (Aeson.object ["planId" Aeson..= pid]))
    liftIO (simpleStatus r @?= status200)
    let v = Aeson.decode (simpleBody r) :: Maybe Aeson.Value
    liftIO $ case v of
      Just (Aeson.Object o) -> do
        KM.lookup "code" o @?= Just (Aeson.Number 0)
        -- 逐项结果回 JSON；log 也回 JSON（**不**打到 stdout：pm ui 只读一行
        -- announce 就丢掉 BufReader，之后无人排空那根管道）
        case KM.lookup "items" o of
          Just (Aeson.Array xs) -> length xs @?= 2
          other -> assertFailure ("items 应为两项: " <> show other)
        -- 非空：逐项那两行必须**在响应体里**。若 sink 换回 putStrLn，
        -- 这里会是空数组——那正是会填满 pm ui 那根无人排空的管道的写法。
        case KM.lookup "log" o of
          Just (Aeson.Array xs) -> assertBool "log 不应为空" (not (null xs))
          other -> assertFailure ("log 应为非空数组: " <> show other)
      other -> assertFailure ("响应不是对象: " <> show other)
  readFile (root </> "成片" </> "a.jpg") >>= (@?= "AAA")
  readFile (root </> "成片" </> "b.jpg") >>= (@?= "BBB")

caseServeApplyOnly :: IO ()
caseServeApplyOnly = withSystemTempDirectory "pm-serve-apply" $ \root -> do
  pid <- seedApplyPlan root [("a.jpg", "AAA"), ("b.jpg", "BBB")]
  envA <- mkEnvA (mkCfg root)
  flip runSession (serveApp envA) $ do
    r <- postReq "/api/apply" (Aeson.encode (Aeson.object ["planId" Aeson..= pid, "only" Aeson..= ("0" :: String)]))
    liftIO (simpleStatus r @?= status200)
  doesFileExist (root </> "成片" </> "a.jpg") >>= (@?= True)
  doesFileExist (root </> "成片" </> "b.jpg") >>= (@?= False)

-- | API 路径**必须**走同一张 'preExecFor' 表。这条用例造一个把某内容在归档层
-- 的两份副本**全部**批准隔离的 dedupe 计划：屏障应把两项都降级，端点因此一项
-- 都不执行，两个文件原地不动。
--
-- 少了它，把端点里的 preExecFor 换成 `pure` 全绿——也就是说 GUI 点一下就能绕过
-- 「至少留一份」这道屏障，而没有任何东西会发现。
caseServeApplyBarrier :: IO ()
caseServeApplyBarrier = withSystemTempDirectory "pm-serve-apply" $ \root -> do
  let a = "Raw" </> "2025" </> "25-01-X-Raw" </> "dup.arw"
      b = "成片" </> "2025" </> "dup.jpg"
  mapM_ (createDirectoryIfMissing True) [root </> "Raw" </> "2025" </> "25-01-X-Raw", root </> "成片" </> "2025"]
  mapM_ (\p -> writeFile (root </> p) "SAME") [a, b]
  sha <- sha256File (root </> a)
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (mkCat [mkEnt a sha, mkEnt b sha])
  pid <- newPlanId
  _ <-
    savePlan
      Plan
        { plId = pid
        , plKind = "dedupe"
        , plRootPath = root
        , plRootId = Just "m"
        , plCreated = now
        , plItems =
            [ PlanItem ix (OpQuarantine v sha "dedupe:同 sha 2 份之一") StPending Nothing
            | (ix, v) <- zip [0 ..] [a, b]
            ]
        }
  envA <- mkEnvA (mkCfg root)
  flip runSession (serveApp envA) $ do
    r <- postReq "/api/apply" (Aeson.encode (Aeson.object ["planId" Aeson..= pid]))
    liftIO (simpleStatus r @?= status200)
    liftIO $ case Aeson.decode (simpleBody r) :: Maybe Aeson.Value of
      Just (Aeson.Object o) -> case KM.lookup "items" o of
        Just (Aeson.Array xs) -> do
          length xs @?= 2
          -- 精确到标签：'Pm.Exec.outcomeLabel' ONotExecuted = "未执行"。
          -- 模糊判据（比如「不含 DONE」）会被 CONFLICT 蒙混过去。
          map outcomeOf (foldr (:) [] xs) @?= [Just "未执行", Just "未执行"]
          -- 工作流 F022/F078：页面要知道**为什么**没执行——逐项 status 随响应
          -- 返回，降级项是 needs-decision 且 why 非空（不只给一个「未执行」标签）
          map (field ["status", "s"]) (foldr (:) [] xs) @?= replicate 2 (Just (Aeson.String "needs-decision"))
          assertBool "降级理由 why 应非空"
            (all (\it -> case field ["status", "why"] it of Just (Aeson.String w) -> not (T.null w); _ -> False) (foldr (:) [] xs))
        other -> assertFailure ("items 应为两项: " <> show other)
      other -> assertFailure ("响应不是对象: " <> show other)
  -- 屏障的全部意义：两份都还在原位
  mapM_ (\p -> doesFileExist (root </> p) >>= (@?= True)) [a, b]
 where
  outcomeOf (Aeson.Object it) = case KM.lookup "outcome" it of
    Just (Aeson.String t) -> Just t
    _ -> Nothing
  outcomeOf _ = Nothing

mkEnt :: FilePath -> T.Text -> Entry
mkEnt p sha = Entry p 4 0 sha KindPhoto Nothing

-- ─── P5-E：整理新照片（GUI 第二页的两个端点） ────────────────────────────

-- | 铺一个库外源目录（两张相隔很久的照片 → 两段）+ 一个已索引的主库。
seedSortSrc :: FilePath -> IO (FilePath, Config)
seedSortSrc tmp = do
  let src = tmp </> "card"
      root = tmp </> "lib"
  createDirectoryIfMissing True (src </> "DCIM")
  BS.writeFile (src </> "DCIM" </> "a.ARW") (photoAt "2026:08:25 10:00:00")
  BS.writeFile (src </> "DCIM" </> "b.ARW") (photoAt "2026:11:02 10:00:00")
  createDirectoryIfMissing True root
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (Catalog "m" now mempty)
  pure (src, mkCfg root)

caseServeSortSurvey :: IO ()
caseServeSortSurvey = withSystemTempDirectory "pm-serve-sort" $ \tmp -> do
  (src, cfg) <- seedSortSrc tmp
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    bad <- getReq "/api/sort/survey" [] tok
    liftIO (simpleStatus bad @?= status400)
    r <- getReq (BC.pack ("/api/sort/survey?src=" <> escape src <> "&gap=72")) [] tok
    liftIO (simpleStatus r @?= status200)
    liftIO $ case Aeson.decode (simpleBody r) :: Maybe Aeson.Value of
      Just (Aeson.Object o) -> do
        KM.lookup "photos" o @?= Just (Aeson.Number 2)
        case KM.lookup "segments" o of
          -- 8 月与 11 月相隔远超 72 小时 → 两段
          Just (Aeson.Array xs) -> length xs @?= 2
          other -> assertFailure ("segments 应为两段: " <> show other)
      other -> assertFailure ("响应不是对象: " <> show other)

caseServeSortPlan :: IO ()
caseServeSortPlan = withSystemTempDirectory "pm-serve-sort" $ \tmp -> do
  (src, cfg) <- seedSortSrc tmp
  let root = cfgMainPath cfg
      body o = Aeson.encode (Aeson.object o)
      req0 = ["src" Aeson..= src, "from" Aeson..= ("2026-08-25" :: String), "to" Aeson..= ("2026-08-26" :: String)]
  envRO <- mkEnv cfg
  flip runSession (serveApp envRO) $ do
    r <- postReq "/api/sort/plan" (body (req0 <> ["place" Aeson..= ("Atlanta" :: String)]))
    liftIO (simpleStatus r @?= status403)
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    none <- postReq "/api/sort/plan" (body req0)
    liftIO (simpleStatus none @?= status400)
    both <- postReq "/api/sort/plan" (body (req0 <> ["place" Aeson..= ("Atlanta" :: String), "event" Aeson..= ("26-08-Atlanta" :: String)]))
    liftIO (simpleStatus both @?= status400)
    ok <- postReq "/api/sort/plan" (body (req0 <> ["place" Aeson..= ("Atlanta" :: String)]))
    liftIO (simpleStatus ok @?= status200)
    liftIO $ case Aeson.decode (simpleBody ok) :: Maybe Aeson.Value of
      Just (Aeson.Object o) -> case KM.lookup "planId" o of
        Just (Aeson.String pid) -> do
          -- 计划真的落在主库的 .pm/plans 里，且装得回来
          e <- loadPlan root pid
          case e of
            Left m -> assertFailure ("计划装不回来: " <> m)
            Right pl -> plKind pl @?= "sort"
        other -> assertFailure ("planId 应为字符串: " <> show other)
      other -> assertFailure ("响应不是对象: " <> show other)
  -- 源目录零改动：sort 是**拷贝**不是移动（不变量 I2），而且这一步只出计划
  doesFileExist (src </> "DCIM" </> "a.ARW") >>= (@?= True)
  doesDirectoryExist (root </> "To-Be-Sync'd") >>= (@?= False)

-- | 百分号转义：源路径里有反斜杠与盘符，直接拼进 query 会被解析器吃掉。
escape :: String -> String
escape = concatMap one
 where
  one c
    | c `elem` (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-_.~") = [c]
    | otherwise = concatMap (\b -> [chr 37, hex (b `div` 16), hex (b `mod` 16)]) (BS.unpack (TE.encodeUtf8 (T.pack [c])))
  hex n = "0123456789ABCDEF" !! fromIntegral n
