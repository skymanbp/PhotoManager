{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ —— 127.0.0.1 loopback JSON API（DESIGN §11，P4-1）。
--
-- 架构边界（不变量级）：GUI 是独立进程、**永不直接触碰照片文件**，一切经
-- 这里说话。
--
-- 三级授权，逐级更强，缺省最弱：
--
--   1. 无开关 —— 只读端点。
--   2. @--writable@（P4-5）—— POST 端点可**生成计划**：只写 @.pm\/plans@ 与
--      少数 pm 自身状态（vault holds、config、备份 root 标识），**不执行、
--      不碰照片**。这句契约同时写在帮助文本、DESIGN §11、README 与 GUI 里。
--   3. @--allow-apply@（P5-C）—— 才允许 @POST \/api\/apply@ **执行**已存的计划。
--
-- 第 3 级单独开一个开关、而不是并进 @--writable@：执行是另一个量级的授权，
-- 把既有开关的含义悄悄放宽，等于让所有已经按第 2 级理解去用它的地方（含
-- @pm ui@ 自己的拉起参数）无声地获得了动照片的能力。
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
import Control.Monad (when)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Control.Exception (IOException, SomeException, bracket, catch, try)
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
import Data.Time (Day, UTCTime)
import Text.Read (readMaybe)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import Network.HTTP.Types
import Network.Socket
import Network.Wai
import Network.Wai.Handler.Warp (defaultSettings, runSettingsSocket)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (dropExtension, takeExtension, (</>))
import GHC.IO.Handle (hDuplicateTo)
import System.IO (IOMode (WriteMode), hClose, hFlush, hIsEOF, openFile, stdin, stdout)

import Pm.Catalog (loadCatalog)
import Pm.Cli (GoOpts (..), executePlanNowWith, preExecFor)
import Pm.Commands (afterApply, loadPlanAnyRoot, prepareApply)
import Pm.Config (Config (..), RootIdState (..), configFilePath, loadConfig, readRootState, pmSubPlans, requirePmTrusted, requireWritable, untrustedMsg, withConfigLock)
import Pm.ConfigEdit (checkPatch, configTxn)
import Pm.BackupCmd (BackupInitOutcome (..), backupInitRun)
import Pm.Exec (outcomeLabel)
import Pm.GitGuard (vaultIgnoreGuard)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), isValidPlanId, loadPlan, savePlan)
import Pm.Sort (SortSegment (..), SortSurvey (..), runSortPlan, surveySort)
import Pm.Status (StatusOpts (..), statusReport)
import Pm.Types
import Pm.Vault (VaultDiff (..), VaultReport (..), checkAssignments, computeVault, fixedCategories, gitStepsLines, mkVaultPushPlan, newActive, planCategories, renderVaultJson, vaultPushItems)
import Pm.VaultCmd (holdOpsIO, withHoldsTxn)
import Pm.VaultHold (VaultHold (..), writeHolds)
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
    -- 缺省只读；`pm ui` 拉起时置位。
  , soAllowApply :: Bool
    -- ^ P5-C：允许 @POST /api/apply@ **执行**已存的计划（唯一会动照片字节的
    -- 端点）。蕴含 'soWritable'——能执行却不能生成计划是没有意义的组合。
  }

-- | 一次 serve 会话的状态：配置、token、可写开关、vault 缓存刷新的进程内互斥。
data ServeEnv = ServeEnv
  { seCfgRef :: IORef Config
    -- ^ 配置**每次请求**读一次：`POST /api/config` 改完之后同一个 serve 进程
    -- 必须立刻按新配置回答，否则用户改完路径还要重启 GUI（P4-8）。
  , seToken :: BS.ByteString
  , seWritable :: Bool
  , seAllowApply :: Bool
  , seVaultLock :: MVar ()
  , seApplyLock :: MVar ()
    -- ^ 同一 serve 进程内的 apply 串行化。跨进程另有 root 锁（I10）——这把只是
    -- 让页面连点两下得到的是排队，而不是一条 "lock busy"。
  }

-- | @allowApply@ 蕴含 writable：见模块头的三级授权。
newServeEnv :: Config -> BS.ByteString -> Bool -> Bool -> IO ServeEnv
newServeEnv cfg tok writable allowApply = do
  ref <- newIORef cfg
  ServeEnv ref tok (writable || allowApply) allowApply <$> newMVar () <*> newMVar ()

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

-- | 把进程的 stdout 换成空设备。失败即忽略：这是防管道堵塞的加固，
-- 换不成最坏也只是回到"可能堵"的旧状态，不该因此让 serve 起不来。
muteStdout :: IO ()
muteStdout =
  ( do
      h <- openFile nulDevice WriteMode
      hDuplicateTo h stdout
      hClose h
  )
    `catch` \(_ :: SomeException) -> pure ()
 where
  -- 设备命名空间：裸 "NUL" 走 GHC 的普通路径打开会 does not exist（实测）
  nulDevice = [bsl, bsl, '.', bsl] <> "NUL"
  bsl = toEnum 92

-- | 只听 127.0.0.1；端口 0 = 随机，绑定后再从 socket 读回真实端口。
runServe :: Config -> ServeOpts -> IO Int
runServe cfg o = case soPort o of
  Just p | not (portOk p) -> do
    putStrLn ("pm serve: --port 须在 0..65535（给的是 " <> show p <> "）")
    pure 2
  _ -> do
    tok <- newToken
    env <- newServeEnv cfg tok (soWritable o) (soAllowApply o)
    r <- try (bracket (bindLoopback (maybe 0 id (soPort o))) close $ \sock -> do
      port <- socketPort sock
      BSL.putStr (encode (Announce (fromIntegral port) (T.pack (BC.unpack tok))))
      putStrLn ""
      hFlush stdout
      -- announce 之后把 stdout 引到空设备——**只在 GUI 拉起时**。
      --
      -- `pm ui` 只从这根管道读一行 announce 就丢掉 BufReader，此后无人排空。
      -- 库层任何一行 putStrLn（计划渲染、诊断、将来新增的端点）都会往里灌，
      -- 填满 64 KiB 缓冲之后 serve 卡在写上，或拿到 broken pipe。逐个端点记得
      -- 传 sink 是治不住的：漏一个就复发。手工跑 `pm serve` 时不动 stdout，
      -- 诊断照旧可见。
      when (soExitOnStdinEof o) muteStdout
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
route env req jsonR err corsHdrs respond = do
  -- 配置每次请求读一次：`POST /api/config` 改完后同一个 serve 必须立刻按新
  -- 配置回答，否则用户改完路径还得重启 GUI（P4-8）。
  cfg <- readIORef (seCfgRef env)
  routeWith cfg env req jsonR err corsHdrs respond

routeWith :: Config -> ServeEnv -> Request -> Reply -> (Status -> String -> IO ResponseReceived) -> ResponseHeaders -> (Response -> IO ResponseReceived) -> IO ResponseReceived
routeWith cfg env req jsonR err corsHdrs respond = case (requestMethod req, pathInfo req) of
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
              -- 事务壳带主库 root lock（I10）：进程内 MVar 挡不住第二个 pm
              -- 进程的读改写丢更新（codex 二十一轮 major）。
              res <- withHoldsTxn cfg $ \olds r -> do
                eops <- holdOpsIO r olds hs us
                case eops of
                  Left errs -> pure (Left (unlines errs, 400))
                  Right kept -> do
                    w <- writeHolds (cfgMainPath cfg) kept
                    pure $ case w of
                      Left m -> Left ("主库 .pm 不可写: " <> m, 403)
                      Right () -> Right kept
              case res of
                Left (msg, 400) -> jsonR status400 [] (object ["error" .= ("决定不合法" :: String), "details" .= lines msg])
                Left (msg, 403) -> err status403 msg
                Left (msg, 4) -> err status409 msg -- root lock 被别的 pm 占用
                Left (msg, 2) -> err status404 msg
                Left (msg, _) -> err status500 msg
                Right kept ->
                  jsonR status200 [] (object ["held" .= map vhName kept, "count" .= length kept])
  -- P4-8：设置页的只读视图——路径 + 每条路径的健康状态。主库这一项恒
  -- `editable:false`：它是身份锚点，改它等于换一个库，留给终端 `pm init`。
  ("GET", ["api", "config"]) -> do
    cfgPath <- configFilePath
    mainSt <- readRootState (cfgMainPath cfg)
    mainEx <- doesDirectoryExist (cfgMainPath cfg)
    vaultJ <- case cfgVaultPath cfg of
      Nothing -> pure Aeson.Null
      Just v -> do
        ex <- doesDirectoryExist v
        st <- readRootState v
        g <- vaultIgnoreGuard v
        pure
          ( object
              [ "path" .= v
              , "exists" .= ex
              , "root" .= rootTag st
              , "i11" .= either (const False) (const True) g
              , "i11why" .= either id (const "") g
              ]
          )
    photosJ <- case cfgPhotosJson cfg of
      Nothing -> pure Aeson.Null
      Just j -> do
        ex <- doesFileExist j
        pure (object ["path" .= j, "exists" .= ex])
    jsonR
      status200
      []
      ( object
          [ "configPath" .= cfgPath
          , "main" .= object ["path" .= cfgMainPath cfg, "exists" .= mainEx, "root" .= rootTag mainSt, "editable" .= False]
          , "vault" .= vaultJ
          , "photosJson" .= photosJ
          , "workers" .= cfgWorkers cfg
          , "backup" .= object ["id" .= cfgBackupId cfg, "subpath" .= cfgBackupSubpath cfg]
          ]
      )
  -- P4-8：第三个写端点——改配置（vault / photos.json / 并发数）。主库路径
  -- 只读（'checkPatch' 直接拒）。配置文件在 XDG 目录、不在任何 root 的 .pm
  -- 下，因此过的是 'writeConfig' 的原子替换而非 .pm 受信取用口。写完把
  -- 进程内 IORef 从**盘上**重读一遍，保证 serve 立刻按新配置回答。
  ("POST", ["api", "config"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝改配置"
    | otherwise -> do
        body <- readBodyCapped req
        case body of
          Nothing -> err status413 ("请求体超过 " <> show maxBodyBytes <> " 字节")
          Just raw -> case Aeson.eitherDecodeStrict' raw of
            Left e -> err status400 ("请求体不是合法 JSON: " <> e)
            Right patch -> do
              errs <- checkPatch patch
              if not (null errs)
                then jsonR status400 [] (object ["error" .= ("配置不合法" :: String), "details" .= errs])
                else do
                  -- 二十四轮 minor：进配置锁，并在锁内**重新读盘**（不再拿
                  -- 请求作用域那份 cfg 当基准）。两个请求各读旧配置、各写回
                  -- 自己那项会互相抹掉，还会撞同一个固定 tmp 名。
                  ew <-
                    try (withConfigLock (configTxn patch))
                      :: IO (Either IOException (Maybe (Either String (Config, FilePath))))
                  case ew of
                    Left e -> err status500 ("配置写入失败: " <> show e)
                    Right Nothing -> err status409 "另一个 pm 正在改配置（配置锁被占），本次没改"
                    Right (Just (Left m)) -> err status500 m
                    Right (Just (Right (c2, fp))) -> do
                      writeIORef (seCfgRef env) c2
                      jsonR status200 [] (object ["ok" .= True, "configPath" .= fp])
  -- P4-8：第四个写端点——登记备份盘。它会在**目标盘**上建立备份 root 标识
  -- （或沿用已有的）并把 UUID + 相对路径写进配置；守卫链与 CLI `pm backup
  -- init` 完全相同（共用 'backupInitRun'，本端点只负责渲染结果）。
  -- P5-C：唯一会**动照片字节**的端点。它不新增任何执行能力——装载、按 UUID
  -- 绑 root、--only 组闭包全部走 CLI 的同一个 'prepareApply'，执行期复验走同一
  -- 张 'preExecFor' 表，执行与 catalog 回写走同一个 'executePlanNowWith'。API
  -- 与 CLI 对「这个计划该怎么执行」只有一个答案。
  --
  -- 逐项结果与提示**走 JSON 响应体**，不走 stdout：`pm ui` 只读一行 announce
  -- 就丢掉 BufReader，serve 的 stdout 此后无人排空，照着打会填满管道缓冲。
  -- P5-E：GUI 第六页（整理新照片）。只读提议——与 CLI 的 `pm sort <源>` 同一个
  -- 'surveySort'，所以页面上的分段与终端建议的命令不可能各说各话。
  ("GET", ["api", "sort", "survey"]) -> do
    let qs = queryString req
        srcQ = lookup "src" qs
        gapQ = lookup "gap" qs
    case srcQ of
      Just (Just raw) | not (BS.null raw) -> do
        let src = T.unpack (TE.decodeUtf8With TEE.lenientDecode raw)
            gap = fromMaybe 72 (gapQ >>= id >>= readMaybe . BC.unpack)
        r <- surveySort src gap cfg
        case r of
          Left m -> err status409 m
          Right sv -> jsonR status200 [] (surveyJson sv)
      _ -> err status400 "缺 src 参数（要整理的源目录）"
  -- P5-E 写端点：生成 sort 计划。只写 <主库>/.pm/plans，不执行、不碰照片
  -- （与 push-plan 同一级授权；执行仍需 --allow-apply 的 /api/apply）。
  ("POST", ["api", "sort", "plan"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝生成计划"
    | otherwise -> do
        body <- readBodyCapped req
        case body of
          Nothing -> err status413 ("请求体超过 " <> show maxBodyBytes <> " 字节")
          Just raw -> case Aeson.eitherDecodeStrict' raw of
            Left e -> err status400 ("请求体不是合法 JSON: " <> e)
            Right (SortPlanReq src mplace mevent from to) ->
              case (mplace, mevent) of
                (Nothing, Nothing) -> err status400 "place 与 event 必须给一个"
                (Just _, Just _) -> err status400 "place 与 event 只能给一个"
                _ -> do
                  let poe = maybe (Right (fromMaybe "" mevent)) Left mplace
                  (code, mpid) <- runSortPlan (GoOpts False False) src poe from to cfg
                  jsonR status200 [] (object ["code" .= code, "planId" .= mpid])
  ("POST", ["api", "apply"])
    | not (seAllowApply env) ->
        err status403 "serve 未以 --allow-apply 启动，拒绝执行计划（--writable 只允许生成计划，不执行）"
    | otherwise -> do
        body <- readBodyCapped req
        case body of
          Nothing -> err status413 ("请求体超过 " <> show maxBodyBytes <> " 字节")
          Just raw -> case Aeson.eitherDecodeStrict' raw of
            Left e -> err status400 ("请求体不是合法 JSON: " <> e)
            Right (ApplyReq pid only) -> withMVar (seApplyLock env) $ \_ -> do
              prep <- prepareApply cfg pid only
              case prep of
                Left m -> err status409 m
                Right (plan, added) -> do
                  logRef <- newIORef []
                  plan' <- preExecFor cfg (plKind plan) plan
                  (code, results) <-
                    executePlanNowWith (\l -> modifyIORef' logRef (l :)) plan'
                  afterApply cfg plan' code
                  logs <- reverse <$> readIORef logRef
                  jsonR
                    status200
                    []
                    ( object
                        [ "planId" .= plId plan'
                        , "kind" .= plKind plan'
                        , "root" .= plRootPath plan'
                        , "addedByGroupClosure" .= added
                        , "code" .= code
                        , "items"
                            .= [ object ["ix" .= piIx it, "outcome" .= outcomeLabel out]
                               | (it, out) <- results
                               ]
                        , "log" .= logs
                        ]
                    )
  ("POST", ["api", "backup-init"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝登记备份盘"
    | otherwise -> do
        body <- readBodyCapped req
        case body of
          Nothing -> err status413 ("请求体超过 " <> show maxBodyBytes <> " 字节")
          Just raw -> case Aeson.eitherDecodeStrict' raw of
            Left e -> err status400 ("请求体不是合法 JSON: " <> e)
            Right (BackupInitReq p) -> do
              r <- backupInitRun p cfg
              case r of
                Left m -> jsonR status400 [] (object ["error" .= ("登记失败" :: String), "details" .= [m]])
                Right o -> do
                  fresh <- loadConfig
                  case fresh of
                    Left m -> err status500 ("登记后配置无法重新载入: " <> m)
                    Right c2 -> do
                      writeIORef (seCfgRef env) c2
                      jsonR
                        status200
                        []
                        ( object
                            [ "ok" .= True
                            , "reused" .= case o of BiReused {} -> True; BiCreated {} -> False
                            , "path" .= case o of BiReused p' _ -> p'; BiCreated p' _ _ _ -> p'
                            , "id" .= case o of BiReused _ i -> i; BiCreated _ i _ _ -> i
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
-- | @{"src","place"|"event","from","to"}@ —— 与 CLI 的 @pm sort … --place …
-- --from … --to …@ 同一组参数，交给**同一个** 'runSortPlan'。
data SortPlanReq = SortPlanReq FilePath (Maybe String) (Maybe String) Day Day

instance Aeson.FromJSON SortPlanReq where
  parseJSON = Aeson.withObject "sort-plan" $ \o ->
    SortPlanReq
      <$> o Aeson..: "src"
      <*> o Aeson..:? "place"
      <*> o Aeson..:? "event"
      <*> o Aeson..: "from"
      <*> o Aeson..: "to"

-- | 'SortSurvey' 的线上形状。写在这里而不是给 Pm.Sort 加 ToJSON 实例：
-- 内核层不该为了一个页面去认识 aeson，而线上形状是 API 的事，改它要能一眼
-- 看见影响面。
surveyJson :: SortSurvey -> Value
surveyJson sv =
  object
    [ "src" .= ssSrcAbs sv
    , "gapHours" .= ssGapHours sv
    , "photos" .= ssPhotoCount sv
    , "dated" .= ssDatedCount sv
    , "sidecars" .= ssSidecarCount sv
    , "undated" .= ssUndated sv
    , "homelessSidecars" .= ssHomelessCars sv
    , "unknown" .= ssUnknown sv
    , "errors" .= [object ["path" .= p, "why" .= w] | (p, w) <- ssErrors sv]
    , "notes" .= ssNotes sv
    , "segments"
        .= [ object
              [ "index" .= sgIndex g
              , "from" .= sgFrom g
              , "to" .= sgTo g
              , "firstAt" .= show (sgFirstAt g)
              , "lastAt" .= show (sgLastAt g)
              , "count" .= sgCount g
              , "firstFile" .= sgFirstFile g
              , "lastFile" .= sgLastFile g
              , "sameMonthEvents" .= sgSameMonthEvents g
              ]
           | g <- ssSegments sv
           ]
    ]

-- | @{"planId": "...", "only": "1,3-5"}@。@only@ 缺省 = 全量；语法与 CLI 的
-- @--only@ 逐字相同（同一个 'Pm.Cli.applyOnlyToPlan' 解析）。
data ApplyReq = ApplyReq Text (Maybe String)

instance Aeson.FromJSON ApplyReq where
  parseJSON = Aeson.withObject "apply" $ \o ->
    ApplyReq <$> o Aeson..: "planId" <*> o Aeson..:? "only"

newtype PushPlanReq = PushPlanReq [PushAssign]

data PushAssign = PushAssign {paName :: FilePath, paCategory :: String}

instance Aeson.FromJSON PushPlanReq where
  parseJSON = Aeson.withObject "push-plan" $ \o -> PushPlanReq <$> o Aeson..: "assignments"

instance Aeson.FromJSON PushAssign where
  parseJSON = Aeson.withObject "assignment" $ \o -> PushAssign <$> o Aeson..: "name" <*> o Aeson..: "category"

-- | root 标识三态 → 页面用的短标签（P4-8 设置页）。
rootTag :: RootIdState -> String
rootTag st = case st of
  RootPresent _ -> "present"
  RootAbsent -> "absent"
  RootCorrupt _ -> "corrupt"
  RootUntrusted _ -> "untrusted"

-- | @{"path":"E:\\Photography"}@
newtype BackupInitReq = BackupInitReq FilePath

instance Aeson.FromJSON BackupInitReq where
  parseJSON = Aeson.withObject "backup-init" $ \o -> BackupInitReq <$> o Aeson..: "path"

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
