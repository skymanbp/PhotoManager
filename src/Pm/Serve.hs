{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ —— 127.0.0.1 loopback JSON API（DESIGN §11，P4-1）。
--
-- 架构边界（不变量级）：GUI 是独立进程、**永不直接触碰照片文件**，一切经
-- 这里说话。P4-1/2 只有**只读**端点；写端点（apply / vault push 分类）在 GUI
-- 骨架落地、过 codex 评审与用户裁定之后再开（DESIGN §11）。
--
-- 安全模型（单机、同用户；§14 威胁模型）：
--   * 只绑定 127.0.0.1，端口默认由内核随机分配，启动时在 stdout 打印一行
--     JSON（@{"port":N,"token":"…"}@）交给 @pm ui@ / 调用方；
--   * 每个请求必须带 @Authorization: Bearer <token>@（token = crypton 16 字节
--     熵的 hex），比对用常量时间 'constEq'；
--   * @Host@ 必须**恰好**是 @127.0.0.1@ 或 @127.0.0.1:<端口>@——挡 DNS rebinding
--     （浏览器里的恶意页面用自家域名解析到 127.0.0.1 来打本机服务）；
--   * 带 @Origin@ 的请求只接受 Tauri WebView 的来源（tauri://localhost 与
--     http(s)://tauri.localhost），其余 403；预检 OPTIONS 不需要 token
--     （浏览器预检不会带 Authorization）。
--   * 缩略图端点按 sha 查主库 catalog，只提供 JPEG 条目的原字节（缩放由
--     GUI 做，§11）；路径来自 loadCatalog 校验过的 enPath，读取前再经
--     'resolveUnder'（十八轮：扫描后被换成库外链接的条目不跟随）。
--   * vault 端点会刷新 @.pm/vault-cache@（不是文件系统意义的纯读）；warp 并发
--     执行请求，缓存替换共用固定 tmp 名——进程内互斥 'seVaultLock' 串行化
--     （十八轮 minor）。
module Pm.Serve
  ( ServeOpts (..)
  , ServeEnv
  , newServeEnv
  , Announce (..)
  , serveApp
  , runServe
  , newToken
  , allowedOrigin
  , hostOk
  , portOk
  , listPlans
  ) where

import Control.Concurrent.Async (race)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, bracket, try)
import Crypto.Random (getRandomBytes)
import Data.Aeson (ToJSON (..), Value, encode, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteArray as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isHexDigit)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Types
import Network.Socket
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettingsSocket)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, takeExtension, (</>))
import System.IO (hFlush, hIsEOF, stdin, stdout)

import Pm.Catalog (loadCatalog)
import Pm.Commands (loadPlanAnyRoot)
import Pm.Config (Config (..), pmSubPlans, requirePmTrusted, requireWritable, untrustedMsg)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), isValidPlanId, loadPlan, savePlan)
import Pm.Status (StatusOpts (..), statusReport)
import Pm.Types
import Pm.Vault (VaultDiff (..), VaultReport (..), checkAssignments, computeVault, fixedCategories, gitStepsLines, mkVaultPushPlan, newActive, planCategories, renderVaultJson, vaultPushItems)
import Pm.VaultCmd (holdRequest)
import Pm.VaultHold (VaultHold (..), readHolds, writeHolds)
import Pm.Win (resolveUnder)

data ServeOpts = ServeOpts
  { soPort :: Maybe Int
    -- ^ Nothing = 由内核随机分配（默认）；Just 须在 0..65535（十八轮 minor：
    -- 越界会在 fromIntegral 到 PortNumber 时静默折回）
  , soExitOnStdinEof :: Bool
    -- ^ P4-3：由 GUI 拉起时置位。GUI 把一条管道接到 serve 的 stdin 且从不写；
    -- GUI 进程一死（含崩溃、被 taskkill），Windows 关闭管道，这里读到 EOF 即
    -- 退出——否则 serve 会成为孤儿一直监听。
  , soWritable :: Bool
    -- ^ P4-5：允许 POST 端点**生成计划**（只写 @.pm/plans@，不执行、不碰照片）。
    -- 缺省只读；`pm ui` 拉起时置位。apply 端点尚不存在（后置，另评审）。
  }

-- | 一次 serve 会话的状态：配置、token、可写开关、vault 缓存刷新的进程内互斥。
data ServeEnv = ServeEnv
  { seCfg :: Config
  , seToken :: BS.ByteString
  , seWritable :: Bool
  , seVaultLock :: MVar ()
  }

newServeEnv :: Config -> BS.ByteString -> Bool -> IO ServeEnv
newServeEnv cfg tok writable = ServeEnv cfg tok writable <$> newMVar ()

-- | POST 请求体上限（十八轮：warp 默认无总 body 上限，写端点须自设）。一次
-- 分类指派最多几十条 name/category，64 KiB 绰绰有余。
maxBodyBytes :: Int
maxBodyBytes = 64 * 1024

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

portOk :: Int -> Bool
portOk p = p >= 0 && p <= 65535

-- | 只听 127.0.0.1；端口 0 = 随机，绑定后再从 socket 读回真实端口。
runServe :: Config -> ServeOpts -> IO Int
runServe cfg o = case soPort o of
  Just p | not (portOk p) -> do
    putStrLn ("pm serve: --port 须在 0..65535（给的是 " <> show p <> "）")
    pure 2
  _ -> do
    tok <- newToken
    env <- newServeEnv cfg tok (soWritable o)
    r <- try (bracket (bindLoopback (maybe 0 id (soPort o))) close $ \sock -> do
      port <- socketPort sock
      BSL.putStr (encode (Announce (fromIntegral port) (T.pack (BC.unpack tok))))
      putStrLn ""
      hFlush stdout
      let server = runSettingsSocket defaultSettings sock (serveApp env)
      if soExitOnStdinEof o
        then do
          -- 父进程看门：stdin 读到 EOF（管道另一端消失）就结束；race 让先完成
          -- 的一方取消另一方——server 正常不会返回，所以实际就是 EOF 结束 server。
          _ <- race server waitStdinEof
          pure ()
        else server) :: IO (Either IOException ())
    case r of
      Left e -> putStrLn ("pm serve: " <> show e) >> pure 1
      Right () -> pure 0

-- | 阻塞直到 stdin 关闭（EOF）；读到内容就丢弃继续等。
waitStdinEof :: IO ()
waitStdinEof = do
  eof <- try (hIsEOF stdin) :: IO (Either IOException Bool)
  case eof of
    Right False -> BC.hGetLine stdin >> waitStdinEof
    _ -> pure ()

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

serveApp :: ServeEnv -> Application
serveApp env req respond = do
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
      | not (authorized (seToken env) hdrs) -> err status401 "缺少或错误的 Bearer token"
      | otherwise -> route env req jsonR err corsHdrs respond

authorized :: BS.ByteString -> RequestHeaders -> Bool
authorized tok hdrs = case lookup hAuthorization hdrs of
  Just v
    | Just given <- BS.stripPrefix "Bearer " v ->
        BS.length given == BS.length tok && BA.constEq given tok
  _ -> False

type Reply = Status -> ResponseHeaders -> Value -> IO ResponseReceived

route :: ServeEnv -> Request -> Reply -> (Status -> String -> IO ResponseReceived) -> ResponseHeaders -> (Response -> IO ResponseReceived) -> IO ResponseReceived
route env req jsonR err corsHdrs respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "ping"]) ->
    jsonR status200 [] (object ["ok" .= True, "main" .= cfgMainPath cfg, "vault" .= cfgVaultPath cfg])
  ("GET", ["api", "status"]) -> do
    let fresh = lookup "fresh" (queryString req) == Just (Just "1")
    r <- statusReport cfg (StatusOpts (not fresh))
    jsonR status200 [] (toJSON r)
  ("GET", ["api", "vault", "status"]) -> do
    er <- vaultReport
    case er of
      Left (msg, code) -> err (if code == 2 then status404 else status500) msg
      Right r ->
        -- 与 `pm vault status --json` 的 stdout **逐字节相同**：同一 renderVaultJson
        -- 加 CLI putStrLn 的末尾换行（十八轮 minor：此前少那一个 LF）。
        respond
          ( responseLBS
              status200
              (("Content-Type", "application/json; charset=utf-8") : corsHdrs)
              (renderVaultJson (vrSrcDir r) (vrVaultDir r) (vrSrcCount r) (vrVaultCount r) (vrDiff r) (vrUnpushable r) (vrUnstable r) (vrHeld r) (vrHeldStale r) <> "\n")
          )
  -- P4-2：分类页要按 sha 拉缩略图，而 vault/status 的 "new" 只有文件名；
  -- 这里把 NEW 名字配上主库 catalog 的 Entry（sha/size），仍是只读。
  ("GET", ["api", "vault", "new"]) -> do
    er <- vaultReport
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
                     | n <- newActive r
                     , let me = Map.lookup n (vrSrcMeta r)
                     ]
              , -- 第九态（P4-7）：已决定「暂不同步」的 NEW。单列出来，页面把
                -- 决定回显成第四个按钮，随时能改回某个类目。
                "held"
                  .= [ object ["name" .= n, "sha" .= fmap enSha me, "size" .= fmap enSize me]
                     | (n, _) <- vrHeld r
                     , let me = Map.lookup n (vrSrcMeta r)
                     ]
              , "heldStale" .= [object ["name" .= n, "why" .= w] | (n, w) <- vrHeldStale r]
              , -- 页面要知道「没有 NEW 但有 DRIFT」也能出纯裁决计划（二十轮 minor）
                "drift" .= [object ["name" .= n, "category" .= c] | (n, c, _, _) <- vdDrift (vrDiff r)]
              ]
          )
  -- P4-5：唯一的写端点——由页面的分类指派**生成** vault push 计划（不执行、
  -- 不碰照片；执行仍是另一步，尚无端点）。写域限于 @<vault>/.pm@：计划落在
  -- @.pm/plans@，首次请求还会经 I11 幂等建 @.pm/root-id@（'mkVaultPushPlan'
  -- 里的 'ensureVaultRoot'）——二十轮把「只写 plans」这句措辞纠正到这里。
  -- 校验与计划构造和 CLI `pm vault push` 共用（'checkAssignments' /
  -- 'vaultPushItems' / 'mkVaultPushPlan'），落盘前同样过 'requireWritable'。
  ("POST", ["api", "vault", "push-plan"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝生成计划"
    | otherwise -> do
        body <- readBodyCapped req
        case body of
          Nothing -> err status413 ("请求体超过 " <> show maxBodyBytes <> " 字节")
          Just raw -> case Aeson.eitherDecodeStrict' raw of
            Left e -> err status400 ("请求体不是合法 JSON: " <> e)
            -- compute→校验→ensureRoot→落盘在同一次持锁里完成：两个并发 POST
            -- 在首次建 root 时会都看到 RootAbsent，其中一次 createRootInfo
            -- （no-replace）必失败 → 500（codex 二十轮 minor）。与 GET 刷新
            -- vault 缓存用的是同一把 'seVaultLock'。
            Right (PushPlanReq as) -> withMVar (seVaultLock env) $ \_ -> do
              er <- computeVault True cfg
              case er of
                Left (msg, code) -> err (if code == 2 then status404 else status500) msg
                Right r
                  -- 空指派只在「有 DRIFT 待裁决」时有意义（纯裁决计划）——否则
                  -- vault 只有 DRIFT 时页面按钮永远灰着（二十轮 minor）。
                  | null as && null (vdDrift (vrDiff r)) ->
                      err status400 "assignments 为空，且没有 DRIFT 待裁决项——无计划可生成"
                  | otherwise -> do
                      let pairs' = [(paCategory a, paName a) | a <- as]
                          errs = checkAssignments r pairs'
                      if not (null errs)
                        then jsonR status400 [] (object ["error" .= ("指派不合法" :: String), "details" .= errs])
                        else do
                          let items = vaultPushItems r pairs'
                          eplan <- mkVaultPushPlan r items
                          case eplan of
                            Left m -> err status500 m
                            Right plan -> do
                              w <- requireWritable (plRootPath plan)
                              case w of
                                Left m -> err status403 ("vault root 不可写: " <> m)
                                Right _ -> do
                                  esave <- try (savePlan plan) :: IO (Either IOException FilePath)
                                  case esave of
                                    Left e -> err status500 ("计划落盘失败: " <> show e)
                                    Right fp ->
                                      jsonR
                                        status200
                                        []
                                        ( object
                                            [ "plan" .= plan
                                            , "path" .= fp
                                            , "apply" .= ("pm apply " <> T.unpack (plId plan))
                                            , "gitSteps" .= gitStepsLines (plRootPath plan) (plId plan) (planCategories plan)
                                            ]
                                        )
  -- P4-7：第二个写端点——记录/撤销「暂不同步」的决定。写域是**主库**的
  -- @.pm/vault-holds.json@（vault 仓与照片零改动），校验与 CLI
  -- `pm vault hold|unhold` 共用 'holdRequest'。同样在 'seVaultLock' 里
  -- compute→校验→写一次持锁完成。
  ("POST", ["api", "vault", "hold"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝记录决定"
    | otherwise -> do
        body <- readBodyCapped req
        case body of
          Nothing -> err status413 ("请求体超过 " <> show maxBodyBytes <> " 字节")
          Just raw -> case Aeson.eitherDecodeStrict' raw of
            Left e -> err status400 ("请求体不是合法 JSON: " <> e)
            Right (HoldReq hs us) -> withMVar (seVaultLock env) $ \_ -> do
              er <- computeVault True cfg
              case er of
                Left (msg, code) -> err (if code == 2 then status404 else status500) msg
                Right r -> do
                  let root = cfgMainPath cfg
                  eholds <- readHolds root
                  case eholds of
                    Left m -> err status500 m
                    Right olds -> do
                      now <- getCurrentTime
                      case holdRequest r olds hs us now of
                        Left errs -> jsonR status400 [] (object ["error" .= ("决定不合法" :: String), "details" .= errs])
                        Right kept -> do
                          w <- writeHolds root kept
                          case w of
                            Left m -> err status403 ("主库 .pm 不可写: " <> m)
                            Right () ->
                              jsonR
                                status200
                                []
                                (object ["held" .= map vhName kept, "count" .= length kept])
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
            -- 十八轮：enPath 只过了词法闸（userRelOk）；扫描之后条目或其父目录
            -- 被换成指向库外的 symlink/junction 时，按名字 readFile 会跟随。
            -- 逐级 no-follow 解析，只读返回路径。
            m <- resolveUnder (cfgMainPath cfg) rel
            case m of
              Nothing -> err status404 "条目路径不是库内真实路径（链接？），不提供"
              Just abs' -> do
                eb <- try (BS.readFile abs') :: IO (Either IOException BS.ByteString)
                case eb of
                  Left e -> err status500 ("读取失败: " <> show e)
                  Right bytes ->
                    respond (responseLBS status200 (("Content-Type", "image/jpeg") : ("Cache-Control", "private, max-age=3600") : corsHdrs) (BSL.fromStrict bytes))
  _ -> err status404 "无此端点"
 where
  cfg = seCfg env
  -- vault 缓存刷新串行化（十八轮 minor）：两个并发 GET 会争用固定 tmp 名。
  vaultReport = withMVar (seVaultLock env) (const (computeVault True cfg))

-- | 读请求体，超过 'maxBodyBytes' 即放弃（不把剩余读完，直接 413）。
readBodyCapped :: Request -> IO (Maybe BS.ByteString)
readBodyCapped req = go [] 0
 where
  go acc n = do
    chunk <- getRequestBodyChunk req
    if BS.null chunk
      then pure (Just (BS.concat (reverse acc)))
      else
        let n' = n + BS.length chunk
         in if n' > maxBodyBytes then pure Nothing else go (chunk : acc) n'

-- | @{"assignments":[{"name":"a.jpg","category":"landscape"},…]}@
newtype PushPlanReq = PushPlanReq [PushAssign]

data PushAssign = PushAssign {paName :: FilePath, paCategory :: String}

instance Aeson.FromJSON PushPlanReq where
  parseJSON = Aeson.withObject "push-plan" $ \o -> PushPlanReq <$> o Aeson..: "assignments"

instance Aeson.FromJSON PushAssign where
  parseJSON = Aeson.withObject "assignment" $ \o -> PushAssign <$> o Aeson..: "name" <*> o Aeson..: "category"

-- | @{"hold":["a.jpg"],"unhold":["b.jpg"]}@（两个键都可缺省为空）
data HoldReq = HoldReq [FilePath] [FilePath]

instance Aeson.FromJSON HoldReq where
  parseJSON = Aeson.withObject "hold" $ \o ->
    HoldReq <$> (fromMaybe [] <$> o Aeson..:? "hold") <*> (fromMaybe [] <$> o Aeson..:? "unhold")

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
