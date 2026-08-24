{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ —— 127.0.0.1 loopback JSON API（DESIGN §11，P4-1）。
--
-- 架构边界（不变量级）：GUI 是独立进程、**永不直接触碰照片文件**，一切经
-- 这里说话。P4-1 只有**只读**端点；写端点（apply / vault push 分类）在 GUI
-- 骨架落地、过 codex 评审与用户裁定之后再开（DESIGN §11）。
--
-- 安全模型（单机、同用户；§14 威胁模型）：
--   * 只绑定 127.0.0.1，端口默认由内核随机分配，启动时在 stdout 打印一行
--     JSON（@{"port":N,"token":"…"}@）交给 @pm ui@ / 调用方；
--   * 每个请求必须带 @Authorization: Bearer <token>@（token = crypton 16 字节
--     熵的 hex），比对用常量时间 'constEq'；
--   * @Host@ 必须是 @127.0.0.1[:port]@——挡 DNS rebinding（浏览器里的恶意页面
--     用自家域名解析到 127.0.0.1 来打本机服务）；
--   * 带 @Origin@ 的请求只接受 Tauri WebView 的来源（tauri://localhost 与
--     http(s)://tauri.localhost），其余 403；预检 OPTIONS 不需要 token
--     （浏览器预检不会带 Authorization）。
--   * 缩略图端点按 sha 查主库 catalog，只提供 JPEG 条目的原字节（缩放由
--     GUI 做，§11）；路径来自 loadCatalog 校验过的 enPath（用户数据读取）。
module Pm.Serve
  ( ServeOpts (..)
  , Announce (..)
  , serveApp
  , runServe
  , newToken
  , allowedOrigin
  , hostOk
  , listPlans
  ) where

import Control.Concurrent.Async (race)
import Control.Exception (IOException, bracket, try)
import Crypto.Random (getRandomBytes)
import Data.Aeson (ToJSON (..), Value, encode, object, (.=))
import qualified Data.ByteArray as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isHexDigit)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Network.HTTP.Types
import Network.Socket
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettingsSocket)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, takeExtension, (</>))
import System.IO (hFlush, hIsEOF, stdin, stdout)

import Pm.Catalog (loadCatalog)
import Pm.Commands (loadPlanAnyRoot)
import Pm.Config (Config (..), pmSubPlans, requirePmTrusted, untrustedMsg)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), isValidPlanId, loadPlan)
import Pm.Status (StatusOpts (..), statusReport)
import Pm.Types
import Pm.Vault (VaultDiff (..), VaultReport (..), computeVault, fixedCategories, renderVaultJson)
import Pm.Win (resolveUnder)

data ServeOpts = ServeOpts
  { soPort :: Maybe Int
    -- ^ Nothing = 由内核随机分配（默认）
  , soExitOnStdinEof :: Bool
    -- ^ P4-3：由 GUI 拉起时置位。GUI 把一条管道接到 serve 的 stdin 且从不写；
    -- GUI 进程一死（含崩溃、被 taskkill），Windows 关闭管道，这里读到 EOF 即
    -- 退出——否则 serve 会成为孤儿一直监听（P4-2 冒烟实测出现过）。
  }

-- | 启动时打印给调用方的一行 JSON。
data Announce = Announce
  { anPort :: Int
  , anToken :: Text
  }

instance ToJSON Announce where
  toJSON a = object ["port" .= anPort a, "token" .= anToken a]

-- | 16 字节熵 → 32 位 hex。
newToken :: IO BS.ByteString
newToken = do
  raw <- getRandomBytes 16 :: IO BS.ByteString
  pure (convertToBase Base16 raw)

-- | 只听 127.0.0.1；端口 0 = 随机，绑定后再从 socket 读回真实端口。
runServe :: Config -> ServeOpts -> IO Int
runServe cfg o = do
  tok <- newToken
  r <- try (bracket (bindLoopback (maybe 0 id (soPort o))) close $ \sock -> do
    port <- socketPort sock
    BSL.putStr (encode (Announce (fromIntegral port) (T.pack (BC.unpack tok))))
    putStrLn ""
    hFlush stdout
    let server = runSettingsSocket defaultSettings sock (serveApp cfg tok)
    if soExitOnStdinEof o
      then do
        -- 父进程看门：stdin 读到 EOF（管道另一端消失）就结束；race 让先完成的
        -- 一方取消另一方——server 正常不会返回，所以实际就是 EOF 结束 server。
        _ <- race server waitStdinEof
        pure ()
      else server) :: IO (Either IOException ())
  case r of
    Left e -> putStrLn ("pm serve: " <> show e) >> pure 1
    Right () -> pure 0

-- | 阻塞直到 stdin 关闭（EOF）；读到内容就丢弃继续等。
waitStdinEof :: IO ()
waitStdinEof = do
  eof <- try hIsEOFStdin :: IO (Either IOException Bool)
  case eof of
    Right False -> BS.hGetLine stdin >> waitStdinEof
    _ -> pure ()
 where
  hIsEOFStdin = hIsEOF stdin

bindLoopback :: Int -> IO Socket
bindLoopback port = do
  sock <- socket AF_INET Stream defaultProtocol
  bind sock (SockAddrInet (fromIntegral port) (tupleToHostAddress (127, 0, 0, 1)))
  listen sock 64
  pure sock

-- ─── WAI application ────────────────────────────────────────────────────────

allowedOrigins :: [BS.ByteString]
allowedOrigins = ["tauri://localhost", "http://tauri.localhost", "https://tauri.localhost"]

allowedOrigin :: BS.ByteString -> Bool
allowedOrigin = (`elem` allowedOrigins)

-- | @Host@ 头须为 @127.0.0.1@ 或 @127.0.0.1:<1-5 位十进制端口>@——精确解析，
-- 不做前缀判定（十八轮：前缀判定会放过 @127.0.0.1:1@evil@ 之类的尾巴；就
-- DNS rebinding 而言那不可利用，但闸的语义应当是"恰好是这个 Host"）。
hostOk :: BS.ByteString -> Bool
hostOk h = case BS.stripPrefix "127.0.0.1" h of
  Just "" -> True
  Just rest
    | Just port <- BS.stripPrefix ":" rest ->
        not (BS.null port) && BS.length port <= 5 && BC.all (\c -> c >= '0' && c <= '9') port
  _ -> False

serveApp :: Config -> BS.ByteString -> Application
serveApp cfg tok req respond = do
  let hdrs = requestHeaders req
      origin = lookup hOrigin hdrs
      corsHdrs = case origin of
        Just o | allowedOrigin o ->
          [ ("Access-Control-Allow-Origin", o)
          , ("Vary", "Origin")
          , ("Access-Control-Allow-Headers", "Authorization, Content-Type")
          , ("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
          ]
        _ -> []
      jsonR st extra v = respond (responseLBS st (("Content-Type", "application/json; charset=utf-8") : corsHdrs <> extra) (encode v))
      err st msg = jsonR st [] (object ["error" .= (msg :: String)])
  case (requestHeaderHost req, origin) of
    (Nothing, _) -> err status403 "缺少 Host"
    (Just h, _) | not (hostOk h) -> err status403 "Host 不是 127.0.0.1（拒绝：DNS rebinding？）"
    (_, Just o) | not (allowedOrigin o) -> err status403 "Origin 不在允许列表"
    _
      | requestMethod req == methodOptions ->
          respond (responseLBS status204 corsHdrs "")
      | not (authorized tok hdrs) -> err status401 "缺少或错误的 Bearer token"
      | otherwise -> route cfg req jsonR err corsHdrs respond

authorized :: BS.ByteString -> RequestHeaders -> Bool
authorized tok hdrs = case lookup hAuthorization hdrs of
  Just v
    | Just given <- BS.stripPrefix "Bearer " v ->
        BS.length given == BS.length tok && BA.constEq given tok
  _ -> False

type Reply = Status -> ResponseHeaders -> Value -> IO ResponseReceived

route :: Config -> Request -> Reply -> (Status -> String -> IO ResponseReceived) -> ResponseHeaders -> (Response -> IO ResponseReceived) -> IO ResponseReceived
route cfg req jsonR err corsHdrs respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "ping"]) ->
    jsonR status200 [] (object ["ok" .= True, "main" .= cfgMainPath cfg, "vault" .= cfgVaultPath cfg])
  ("GET", ["api", "status"]) -> do
    let fresh = lookup "fresh" (queryString req) == Just (Just "1")
    r <- statusReport cfg (StatusOpts (not fresh))
    jsonR status200 [] (toJSON r)
  ("GET", ["api", "vault", "status"]) -> do
    er <- computeVault True cfg
    case er of
      Left (msg, code) -> err (if code == 2 then status404 else status500) msg
      Right r ->
        respond
          ( responseLBS
              status200
              (("Content-Type", "application/json; charset=utf-8") : corsHdrs)
              (renderVaultJson (vrSrcDir r) (vrVaultDir r) (vrSrcCount r) (vrVaultCount r) (vrDiff r) (vrUnpushable r) (vrUnstable r))
          )
  -- P4-2：分类页要按 sha 拉缩略图，而 vault/status 的 "new" 只有文件名；
  -- 这里把 NEW 名字配上主库 catalog 的 Entry（sha/size），仍是只读。
  ("GET", ["api", "vault", "new"]) -> do
    er <- computeVault True cfg
    case er of
      Left (msg, code) -> err (if code == 2 then status404 else status500) msg
      Right r ->
        jsonR
          status200
          []
          ( object
              [ "categories" .= fixedCategories
              , "new"
                  .= [ object ["name" .= n, "sha" .= fmap enSha me, "size" .= fmap enSize me]
                     | n <- vdNew (vrDiff r)
                     , let me = Map.lookup n (vrSrcMeta r)
                     ]
              ]
          )
  ("GET", ["api", "plans"]) -> do
    (ps, errs) <- listPlans (cfgMainPath cfg)
    (vps, verrs) <- maybe (pure ([], [])) listPlans (cfgVaultPath cfg)
    jsonR status200 [] (object ["plans" .= map planSummary (ps <> vps), "errors" .= (errs <> verrs)])
  ("GET", ["api", "plan", pid])
    | not (isValidPlanId pid) -> err status400 "计划 id 不符合生成格式"
    | otherwise -> do
        ep <- loadPlanAnyRoot cfg pid
        either (err status404) (jsonR status200 [] . toJSON) ep
  ("GET", ["api", "thumb", sha])
    | not (validSha sha) -> err status400 "sha 须为 64 位 hex"
    | otherwise -> do
        (mcat, _) <- loadCatalog (cfgMainPath cfg)
        case mcat >>= findJpeg sha of
          Nothing -> err status404 "无此 JPEG 条目"
          Just rel -> do
            eb <- try (BS.readFile (cfgMainPath cfg </> rel)) :: IO (Either IOException BS.ByteString)
            case eb of
              Left e -> err status500 ("读取失败: " <> show e)
              Right bytes ->
                respond (responseLBS status200 (("Content-Type", "image/jpeg") : ("Cache-Control", "private, max-age=3600") : corsHdrs) (BSL.fromStrict bytes))
  _ -> err status404 "无此端点"

validSha :: Text -> Bool
validSha s = T.length s == 64 && T.all isHexDigit s

-- | 按 sha 找主库 catalog 里的 JPEG 照片条目（相对路径）。
findJpeg :: Text -> Catalog -> Maybe FilePath
findJpeg sha cat =
  case [enPath e | e <- Map.elems (catEntries cat), enSha e == T.toLower sha, enKind e == KindPhoto, isJpeg (enPath e)] of
    (p : _) -> Just p
    [] -> Nothing
 where
  isJpeg p = map toLowerAscii (takeExtension p) `elem` [".jpg", ".jpeg"]
  toLowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

planSummary :: Plan -> Value
planSummary p =
  object
    [ "id" .= plId p
    , "kind" .= plKind p
    , "root" .= plRootPath p
    , "created" .= (plCreated p :: UTCTime)
    , "items" .= length (plItems p)
    , "pending" .= count StPending
    , "skipped" .= count StSkippedByUser
    , "needsDecision" .= length [() | PlanItem {piStatus = StNeedsDecision _} <- plItems p]
    ]
 where
  -- 计划文件里只有 pending / skipped / needs-decision 三态；"已执行"是 journal
  -- 层的事实（Done），不在计划文件上（DESIGN §3）。
  count s = length [() | it <- plItems p, piStatus it == s]

-- | 列出 @root/.pm/plans@ 下装得出来的计划；装不出来的按 (文件名, 原因) 返回。
-- 目录本身经 'requirePmTrusted' + 完整路径 'resolveUnder'，每个计划经
-- 'loadPlan'（受信取用口）；文件名只是候选 id，先过 'isValidPlanId'。
listPlans :: FilePath -> IO ([Plan], [(String, String)])
listPlans root = do
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure ([], [("", m)])
    Right () -> do
      m <- resolveUnder root (".pm" </> pmSubPlans)
      case m of
        Nothing -> pure ([], [("", untrustedMsg (root </> ".pm" </> pmSubPlans))])
        Just d -> do
          ex <- doesDirectoryExist d
          names <- if ex then listDirectory d else pure []
          let pids = [T.pack (dropExtension n) | n <- names, takeExtension n == ".json", isValidPlanId (T.pack (dropExtension n))]
          rs <- mapM (\pid -> fmap ((,) (T.unpack pid)) (loadPlan root pid)) pids
          pure ([p | (_, Right p) <- rs], [(n, e) | (n, Left e) <- rs])
