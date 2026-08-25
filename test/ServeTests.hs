{-# LANGUAGE OverloadedStrings #-}

-- | P4-1：@pm serve@ 的 loopback JSON API。用 wai-extra 的 'Network.Wai.Test'
-- 直接打 'Application'，不开端口——端口/socket 那层只有 'bindLoopback'
-- 一小段，由真实库手动冒烟覆盖。
--
-- 每条用例钉一道闸：删掉对应判定，用例必须转红。
module ServeTests (serveTests) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isHexDigit)
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
import Data.List (isInfixOf)
import qualified Data.Text.Encoding as TE
import Pm.Config (Config (..), configFilePath, pmDir, writeRootInfo)
import Pm.Hash (sha256File)
import Pm.Op (Fingerprint (..), Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan, savePlan)
import Pm.Serve (ServeEnv, allowedOrigin, hostOk, listPlans, newServeEnv, newToken, portOk, serveApp)
import Pm.Types (Entry (..), FileKind (..), RootInfo (..), RootRole (..))
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
    , testCase "P4-5 POST /api/vault/push-plan：只读 serve → 403；坏 JSON/空指派/非法类目/非 NEW → 400；超大体 → 413" caseServePushPlanGuards
    , testCase "P4-5 POST /api/vault/push-plan：合法指派 → 计划落到 <vault>/.pm/plans，可经 loadPlan 装回，项与指派一致" caseServePushPlanOk
    , testCase "P4-6 POST /api/vault/push-plan：DRIFT-only（无 NEW）空指派 → 纯裁决计划；照片零改动" caseServePushPlanDrift
    , testCase "P4-7 POST /api/vault/hold：只读 403；标记后 new 移出、held 列出；同名同时标与撤 400；撤销恢复；被 hold 的不能 push" caseServeHold
    , testCase "P4-8 GET /api/config：路径与健康状态；主库恒 editable=false" caseServeConfigGet
    , testCase "P4-8 POST /api/config：只读 403；改主库/坏路径/坏并发数/空补丁 → 400 且配置不动" caseServeConfigGuards
    , testCase "P4-8 POST /api/config：合法改动落到 PM_CONFIG 指向的文件，且同一 serve 立刻按新配置回答" caseServeConfigWrite
    ]

tok :: BS.ByteString
tok = "0123456789abcdef0123456789abcdef"

mkCfg :: FilePath -> Config
mkCfg root = Config root Nothing Nothing Nothing Nothing Nothing

-- | 缺省只读（与 `pm serve` 不带 --writable 相同）。
mkEnv :: Config -> IO ServeEnv
mkEnv cfg = newServeEnv cfg tok False

mkEnvW :: Config -> IO ServeEnv
mkEnvW cfg = newServeEnv cfg tok True

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

-- | P4-5 的闸：写开关、JSON、指派校验（与 CLI 共用 'checkAssignments'）、体上限。
-- 每条对应一处判定；删掉判定用例转红。
caseServePushPlanGuards :: IO ()
caseServePushPlanGuards = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  let good = "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"}]}"
  -- 只读 serve：403，且 .pm/plans 不出现
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- postReq "/api/vault/push-plan" good
    assertStatus 403 r
  doesDirectoryExist (vdir </> ".pm") >>= (@?= False)
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r1 <- postReq "/api/vault/push-plan" "{not json"
    assertStatus 400 r1
    r2 <- postReq "/api/vault/push-plan" "{\"assignments\":[]}"
    assertStatus 400 r2
    r3 <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"nope\"}]}"
    assertStatus 400 r3
    liftIO' (assertBool "应报类目不存在" ("nope" `BS.isInfixOf` BSL.toStrict (simpleBody r3)))
    r4 <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"ghost.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4
    -- 同一 name 指派两个类目：逐条都合法，但会出两个 Copy → 必须整体拒（二十轮 minor）
    r4a <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"},{\"name\":\"a.jpg\",\"category\":\"portrait\"}]}"
    assertStatus 400 r4a
    liftIO' (assertBool "应列出两个冲突类目" ("landscape portrait" `BS.isInfixOf` BSL.toStrict (simpleBody r4a)))
    -- 同一 name 同类目重复两次：同样是两个 Copy
    r4b <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"},{\"name\":\"a.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4b
    -- 类目大小写变体不是别名（fixedCategories 精确匹配）
    r4c <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"Landscape\"}]}"
    assertStatus 400 r4c
    -- 带路径分隔符的 name：NEW 只有平铺 basename → 不在集合里
    r4d <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"../a.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4d
    r4e <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"sub\\a.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4e
    -- 超过 64 KiB 的体：413，不解析
    r5 <- postReq "/api/vault/push-plan" (BSL.fromStrict (BS.replicate (70 * 1024) 32))
    assertStatus 413 r5
    -- GET 不是端点
    r6 <- getReq "/api/vault/push-plan" [] tok
    assertStatus 404 r6
  -- 全部被拒 → 没有任何计划落盘，vault 的 .pm 也不该被建出来（连 root-id 都不建）
  (ps, _) <- listPlans vdir
  ps @?= []
  doesDirectoryExist (vdir </> ".pm") >>= (@?= False)

-- | 合法指派：计划写进 vault root 的 .pm/plans，响应带计划 + 路径 + apply 提示；
-- 用 loadPlan 从盘上装回，项数与目标路径与指派一致；照片零改动。
caseServePushPlanOk :: IO ()
caseServePushPlanOk = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, sj, _) <- fixture root
  cfg <- withVault vdir cfg0
  env <- mkEnvW cfg
  pid <- flip runSession (serveApp env) $ do
    r <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"portrait\"}]}"
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      arrLen (field ["plan", "items"] v) @?= Just 1
      field ["plan", "kind"] v @?= Just (Aeson.String "vault-push")
      case field ["plan", "id"] v of
        Just (Aeson.String p) -> pure p
        other -> assertFailure ("响应缺 plan.id: " <> show other)
  ep <- loadPlan vdir pid
  case ep of
    Left e -> assertFailure ("loadPlan 应装回: " <> e)
    Right plan -> do
      plKind plan @?= "vault-push"
      map (opDstRel . piOp) (plItems plan) @?= ["portrait" </> "a.jpg"]
      map (opSha . piOp) (plItems plan) @?= [sj]
  -- 照片零改动、vault 类目目录仍空（只生成计划，不执行）
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)
  doesFileExist (vdir </> "portrait" </> "a.jpg") >>= (@?= False)

-- | P4-6：vault 只有 DRIFT（同名内容不同）、没有 NEW 时，空 assignments 也要
-- 能出一份纯裁决计划——否则 GUI 的「生成推送计划」按钮永远灰着（二十轮 minor）。
-- 计划项是 NEEDS-DECISION，vault 与相册的字节都不动。把「空指派 → 400」改回
-- 无条件，本例转红。
caseServePushPlanDrift :: IO ()
caseServePushPlanDrift = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  let vaultCopy = vdir </> "landscape" </> "a.jpg"
      otherBytes = "\xFF\xD8\xFF\xE0JFIF-vault-side-bytes"
  BS.writeFile vaultCopy otherBytes
  env <- mkEnvW cfg
  pid <- flip runSession (serveApp env) $ do
    r <- postReq "/api/vault/push-plan" "{\"assignments\":[]}"
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      arrLen (field ["plan", "items"] v) @?= Just 1
      case field ["plan", "id"] v of
        Just (Aeson.String p) -> pure p
        other -> assertFailure ("响应缺 plan.id: " <> show other)
  ep <- loadPlan vdir pid
  case ep of
    Left e -> assertFailure ("loadPlan 应装回: " <> e)
    Right plan -> do
      map (opDstRel . piOp) (plItems plan) @?= ["landscape" </> "a.jpg"]
      case map piStatus (plItems plan) of
        [StNeedsDecision _] -> pure ()
        other -> assertFailure ("DRIFT 项应为 NEEDS-DECISION: " <> show other)
  -- 只生成计划：两侧字节都没动
  BS.readFile vaultCopy >>= (@?= otherBytes)
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)

-- | P4-7：第二个写端点。决定只落主库 @.pm/vault-holds.json@——照片与 vault
-- 零改动；只读 serve 拒绝；标记后该名字从 @/api/vault/new@ 的 new 移到 held，
-- 且不再能 push；撤销后回到 new。去掉 seWritable 闸或 holdRequest 的任一条
-- 判定，本例转红。
caseServeHold :: IO ()
caseServeHold = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- postReq "/api/vault/hold" "{\"hold\":[\"a.jpg\"]}"
    assertStatus 403 r
  doesFileExist (root </> ".pm" </> "vault-holds.json") >>= (@?= False)
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r0 <- getReq "/api/vault/new" [] tok
    liftIO' (arrLen (field ["new"] (decodeBody r0)) @?= Just 1)
    -- 同一名字同时标记与撤销：整体拒
    rBad <- postReq "/api/vault/hold" "{\"hold\":[\"a.jpg\"],\"unhold\":[\"a.jpg\"]}"
    assertStatus 400 rBad
    -- 不是 NEW 的名字：拒
    rGhost <- postReq "/api/vault/hold" "{\"hold\":[\"ghost.jpg\"]}"
    assertStatus 400 rGhost
    r1 <- postReq "/api/vault/hold" "{\"hold\":[\"a.jpg\"]}"
    assertStatus 200 r1
    liftIO' (arrLen (field ["held"] (decodeBody r1)) @?= Just 1)
    r2 <- getReq "/api/vault/new" [] tok
    liftIO' $ do
      arrLen (field ["new"] (decodeBody r2)) @?= Just 0
      arrLen (field ["held"] (decodeBody r2)) @?= Just 1
    -- 已决定暂不同步 → 生成计划端点拒收
    r3 <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"portrait\"}]}"
    assertStatus 400 r3
    r4 <- postReq "/api/vault/hold" "{\"unhold\":[\"a.jpg\"]}"
    assertStatus 200 r4
    r5 <- getReq "/api/vault/new" [] tok
    liftIO' (arrLen (field ["new"] (decodeBody r5)) @?= Just 1)
  -- 照片与 vault 类目目录零改动
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)
  doesFileExist (vdir </> "portrait" </> "a.jpg") >>= (@?= False)

-- | P4-8 设置页的只读视图：路径 + 每条路径的健康状态；主库这一项恒
-- @editable:false@（它是身份锚点，改它等于换一个库）。
caseServeConfigGet :: IO ()
caseServeConfigGet = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/config" [] tok
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      field ["main", "path"] v @?= Just (Aeson.String (T.pack root))
      field ["main", "editable"] v @?= Just (Aeson.Bool False)
      field ["main", "root"] v @?= Just (Aeson.String "present")
      field ["vault", "path"] v @?= Just (Aeson.String (T.pack vdir))
      field ["vault", "exists"] v @?= Just (Aeson.Bool True)
      -- 未设的项是 null，不是漏键
      field ["photosJson"] v @?= Just Aeson.Null

-- | P4-8 写端点的闸：只读 serve 拒绝；主库路径只读；不存在的 vault 目录、
-- 越界并发数、空补丁一律拒——且**配置文件在任何一条拒绝后都不能被改写**。
caseServeConfigGuards :: IO ()
caseServeConfigGuards = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- postReq "/api/config" "{\"workers\":4}"
    assertStatus 403 r
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r1 <- postReq "/api/config" "{\"main\":\"D:\\\\elsewhere\"}"
    assertStatus 400 r1
    -- 断言用 ASCII 子串：中文字面量经 OverloadedStrings 变 ByteString 会按 8 位截断
    liftIO' (assertBool "应指向 pm init（主库只读）" ("pm init" `BS.isInfixOf` BSL.toStrict (simpleBody r1)))
    r2 <- postReq "/api/config" "{\"vault\":\"D:\\\\no-such-dir-for-pm-test\"}"
    assertStatus 400 r2
    r3 <- postReq "/api/config" "{\"workers\":0}"
    assertStatus 400 r3
    r4 <- postReq "/api/config" "{\"workers\":999}"
    assertStatus 400 r4
    r5 <- postReq "/api/config" "{}"
    assertStatus 400 r5
    r6 <- postReq "/api/config" "{not json"
    assertStatus 400 r6
    -- 拒绝之后 GET 仍是原来的 vault 路径（配置没被动过）
    r7 <- getReq "/api/config" [] tok
    liftIO' (field ["vault", "path"] (decodeBody r7) @?= Just (Aeson.String (T.pack vdir)))

-- | P4-8 合法路径：改动写进 **PM_CONFIG 指向的**文件（Spec.hs 把整个测试进程
-- 指到临时文件——配置路径是机器全局的，没有这道缝，一次写成功就会覆盖使用者
-- 本机的 config.toml），且同一个 serve 进程立刻按新配置回答（cfg 是 IORef，
-- 每次请求读一次）。把 IORef 改回启动时快照，本例的第二次 GET 会转红。
caseServeConfigWrite :: IO ()
caseServeConfigWrite = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
      vdir2 = dir </> "vault2"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  createDirectoryIfMissing True vdir2
  cfgFile <- configFilePath
  env <- mkEnvW cfg
  flip runSession (serveApp env) $ do
    r1 <- postReq "/api/config" (BSL.fromStrict (TE.encodeUtf8 (T.pack ("{\"vault\":" <> show vdir2 <> ",\"workers\":3}"))))
    assertStatus 200 r1
    -- 同一个 serve，立刻按新配置回答
    r2 <- getReq "/api/config" [] tok
    liftIO' $ do
      field ["vault", "path"] (decodeBody r2) @?= Just (Aeson.String (T.pack vdir2))
      field ["workers"] (decodeBody r2) @?= Just (Aeson.Number 3)
  -- 落到 PM_CONFIG 指向的文件里（而不是使用者本机的配置）
  -- 按 UTF-8 读：配置文件头是中文注释，locale 解码器（本机 CP936）会炸
  raw <- BS.readFile cfgFile
  let txt = T.unpack (TE.decodeUtf8 raw)
  assertBool ("配置文件应含新 vault 路径: " <> txt) (vdir2 `isInfixOf` txt)

caseServePortRange :: IO ()
caseServePortRange = do
  assertBool "0" (portOk 0)
  assertBool "65535" (portOk 65535)
  assertBool "65536" (not (portOk 65536))
  assertBool "-1" (not (portOk (-1)))

-- 'Network.Wai.Test.Session' 是 ReaderT/StateT 叠 IO；HUnit 断言直接 liftIO。
liftIO' :: IO a -> Session a
liftIO' = liftIO
