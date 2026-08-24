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
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import Pm.Config (Config (..), pmDir, writeRootInfo)
import Pm.Hash (sha256File)
import Pm.Op (Fingerprint (..), Op (..))
import Pm.Plan (Plan (..), savePlan)
import Pm.Serve (allowedOrigin, hostOk, listPlans, newToken, serveApp)
import Pm.Types (Entry (..), FileKind (..), RootInfo (..), RootRole (..))
import TestUtil

serveTests :: TestTree
serveTests =
  testGroup
    "P4-1 pm serve loopback JSON API"
    [ testCase "P4-1 token：缺失/错误 → 401；正确 → 200；token 为 32 位 hex" caseServeToken
    , testCase "P4-1 Host：非 127.0.0.1 → 403（DNS rebinding）；缺失 → 403" caseServeHost
    , testCase "P4-1 Origin：非 Tauri 来源 → 403；Tauri 来源 → 回 CORS 头；预检 OPTIONS 免 token" caseServeOrigin
    , testCase "P4-1 /api/status：fixture 索引 → files/layers/exit 与 runStatus 同源；无索引 → index null + exit 2" caseServeStatus
    , testCase "P4-1 /api/thumb/<sha>：JPEG 条目原字节；非 JPEG 条目 404；坏 sha 400" caseServeThumb
    , testCase "P4-1 /api/plans + /api/plan/<id>：列出/装载；坏 id 400；不存在 404" caseServePlans
    ]

tok :: BS.ByteString
tok = "0123456789abcdef0123456789abcdef"

mkCfg :: FilePath -> Config
mkCfg root = Config root Nothing Nothing Nothing Nothing Nothing

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

caseServeToken :: IO ()
caseServeToken = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, _, _) <- fixture root
  t <- newToken
  BS.length t @?= 32
  assertBool ("token 应为 hex: " <> BC.unpack t) (BC.all isHexDigit t)
  let app = serveApp cfg tok
  flip runSession app $ do
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
  flip runSession (serveApp cfg tok) $ do
    r <- request (setPath defaultRequest {requestMethod = methodGet, requestHeaderHost = Just "evil.example:80", requestHeaders = [(hHost, "evil.example:80"), (hAuthorization, "Bearer " <> tok)]} "/api/ping")
    assertStatus 403 r
    r2 <- request (setPath defaultRequest {requestMethod = methodGet, requestHeaderHost = Nothing, requestHeaders = [(hAuthorization, "Bearer " <> tok)]} "/api/ping")
    assertStatus 403 r2

caseServeOrigin :: IO ()
caseServeOrigin = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, _, _, _) <- fixture root
  assertBool "tauri://localhost" (allowedOrigin "tauri://localhost")
  assertBool "http://evil" (not (allowedOrigin "http://evil"))
  flip runSession (serveApp cfg tok) $ do
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
  flip runSession (serveApp cfg tok) $ do
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
  flip runSession (serveApp (mkCfg root2) tok) $ do
    r <- getReq "/api/status" [] tok
    assertStatus 200 r
    liftIO' $ do
      field ["index"] (decodeBody r) @?= Just Aeson.Null
      field ["exit"] (decodeBody r) @?= Just (Aeson.Number 2)

caseServeThumb :: IO ()
caseServeThumb = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg, jpgBytes, sj, sa) <- fixture root
  flip runSession (serveApp cfg tok) $ do
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
  flip runSession (serveApp cfg tok) $ do
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

-- 'Network.Wai.Test.Session' 是 ReaderT/StateT 叠 IO；HUnit 断言直接 liftIO。
liftIO' :: IO a -> Session a
liftIO' = liftIO
