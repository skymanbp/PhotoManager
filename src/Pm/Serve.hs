{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ —— 127.0.0.1 loopback JSON API（DESIGN §11，P4-1）。
--
-- 架构边界（不变量级）：GUI 是独立进程、**永不直接触碰照片文件**，一切经
-- 这里说话。
--
-- 三级授权，逐级更强，缺省最弱：
--
--   1. 无开关 —— 只读端点。
--   2. @--writable@（P4-5）—— POST 端点可**生成计划**：只写 @.pm\/plans@（含
--      删除\/清理计划文件——可再生成，journal 不动）与少数 pm 自身状态
--      （vault holds、照片记录、忽略清单、config、备份 root 标识），**不执行、
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
--   * P8-A：会话环境（'ServeEnv'）在 "Pm.ServeEnv"，四个 vault 端点在 "Pm.ServeVault"
--     ——逐字搬出，本文件回到 750 行预算内；路由表在 routeWith 先问 vault 模块。
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

import Control.Applicative ((<|>))
import Control.Concurrent.Async (race)
import Control.Monad (when)
import Control.Concurrent.MVar (withMVar)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Control.Exception (IOException, bracket, try)

import Pm.ServeGuard
import Data.Aeson (ToJSON (..), Value, encode, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isHexDigit)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
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
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath (takeExtension)
import System.IO (IOMode (ReadMode), hClose, hFlush, stdout)

import Pm.Catalog (CatalogLoad (..), catalogMaybe, loadCatalog, loadNote)
import Pm.Cli (GoOpts (..), executePlanNowWith)
import Pm.Commands (afterApply, loadPlanAnyRoot, prepareApply)
import Pm.Config (Config (..), RootIdState (..), configFilePath, loadConfig, readRootState, withConfigLock)
import Pm.ConfigEdit (checkPatch, configTxn)
import Pm.BackupCmd (BackupInitOutcome (..), backupInitRun)
import Pm.Exec (outcomeLabel)
import Pm.GitGuard (vaultIgnoreGuard)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), PlanExec (..), deletePlanAnyRoot, isValidPlanId, listPlans, planExecuted, planExecs, prunePlans)
import Pm.Journal (readJournal)
import Pm.Publish (publishCommands)
import Pm.ServeAi (routeAi)
import Pm.ServeAlbum (planPost, routeAlbum)
import Pm.ServeEnv
import Pm.ServeVault (routeVault)
import Pm.Sort (SortSegment (..), SortSurvey (..), runSortPlanTo, surveySort)
import Pm.Status (StatusOpts (..), statusReport)
import Pm.Types
import Pm.Win (openBoundTo, resolveUnder)

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

-- | 启动时打印给调用方的一行 JSON。
data Announce = Announce
  { anPort :: Int
  , anToken :: Text
  }

instance ToJSON Announce where
  toJSON a = object ["port" .= anPort a, "token" .= anToken a]


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
      -- 工作流 F081：起不来是「错误」（2，与 --port 越界、pm ui 的启动失败同码），
      -- 不是「有事可做」的 1。
      Left e -> putStrLn ("pm serve: " <> show e) >> pure 2
      Right () -> pure 0

-- ─── WAI application ────────────────────────────────────────────────────────
-- （传输/守卫原语在 "Pm.ServeGuard"：newToken/hostOk/allowedOrigin/authorized/
--   readBodyCapped/muteStdout/waitStdinEof/bindLoopback，P7 拆出，逐字搬移。）

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

route :: ServeEnv -> Request -> Reply -> (Status -> String -> IO ResponseReceived) -> ResponseHeaders -> (Response -> IO ResponseReceived) -> IO ResponseReceived
route env req jsonR err corsHdrs respond = do
  -- 配置每次请求读一次：`POST /api/config` 改完后同一个 serve 必须立刻按新
  -- 配置回答，否则用户改完路径还得重启 GUI（P4-8）；带外改动见 'currentConfig'。
  ec <- currentConfig env
  case ec of
    Left m -> err status500 m
    Right cfg -> routeWith cfg env req jsonR err corsHdrs respond

routeWith :: Config -> ServeEnv -> Request -> Reply -> ErrReply -> ResponseHeaders -> (Response -> IO ResponseReceived) -> IO ResponseReceived
routeWith cfg env req jsonR err corsHdrs respond =
  -- P8-A：vault 端点在 "Pm.ServeVault"（逐字搬移）先匹配；P8-D 再问归档页端点
  -- （"Pm.ServeAlbum"）与 AI 建议（"Pm.ServeAi"）；都不命中才走本模块的表。
  fromMaybe
    (routeMain cfg env req jsonR err corsHdrs respond)
    (routeVault cfg env req jsonR err corsHdrs respond <|> routeAlbum cfg env req jsonR err <|> routeAi cfg env req jsonR err)

routeMain :: Config -> ServeEnv -> Request -> Reply -> ErrReply -> ResponseHeaders -> (Response -> IO ResponseReceived) -> IO ResponseReceived
routeMain cfg env req jsonR err corsHdrs respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "ping"]) ->
    -- allowApply：GUI 据此决定计划页要不要渲染「执行」按钮——按钮出现在
    -- 没有第三级授权的 serve 上，点了只会收 403（P7）。
    jsonR status200 [] (object ["ok" .= True, "main" .= cfgMainPath cfg, "vault" .= cfgVaultPath cfg, "allowApply" .= seAllowApply env])
  ("GET", ["api", "status"]) -> do
    let fresh = lookup "fresh" (queryString req) == Just (Just "1")
    r <- statusReport cfg (StatusOpts (not fresh))
    jsonR status200 [] (toJSON r)
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
          , "backup" .= object ["id" .= cfgBackupId cfg, "subpath" .= cfgBackupSubpath cfg, "driveWait" .= cfgDriveWait cfg]
          , -- P7：上线命令的三项自定义（portfolio 仓路径 + 两个 push 目标）。
            "publish"
              .= object
                [ "portfolioDir" .= cfgPortfolioDir cfg
                , "vaultPush" .= cfgVaultPush cfg
                , "portfolioPush" .= cfgPortfolioPush cfg
                ]
          ]
      )
  -- P4-8：第三个写端点——改配置（vault / photos.json / 并发数）。主库路径
  -- 只读（'checkPatch' 直接拒）。配置文件在 XDG 目录、不在任何 root 的 .pm
  -- 下，因此过的是 'writeConfig' 的原子替换而非 .pm 受信取用口。写完把
  -- 进程内 IORef 从**盘上**重读一遍，保证 serve 立刻按新配置回答。
  ("POST", ["api", "config"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝改配置"
    | otherwise -> withJsonBody req err $ \patch -> do
        errs <- checkPatch cfg patch
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
                setServeConfig env c2
                jsonR status200 [] (object ["ok" .= True, "configPath" .= fp])
  -- P4-8：第四个写端点——登记备份盘。它会在**目标盘**上建立备份 root 标识
  -- （或沿用已有的）并把 UUID + 相对路径写进配置；守卫链与 CLI `pm backup
  -- init` 完全相同（共用 'backupInitRun'，本端点只负责渲染结果）。
  -- P5-C：唯一会**动照片字节**的端点。它不新增任何执行能力——装载、按 UUID
  -- 绑 root、--only 组闭包全部走 CLI 的同一个 'prepareApply'，执行期复验走同一
  -- 个 'Pm.Cli.runBarrier'（由内核在锁内跑），执行与 catalog 回写走同一个 'executePlanNowWith'。API
  -- 与 CLI 对「这个计划该怎么执行」只有一个答案。
  --
  -- 逐项结果与提示**走 JSON 响应体**，不走 stdout：`pm ui` 只读一行 announce
  -- 就丢掉 BufReader，serve 的 stdout 此后无人排空，照着打会填满管道缓冲。
  -- P5-E：GUI 第二页（整理新照片）。只读提议——与 CLI 的 `pm sort <源>` 同一个
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
  -- P8-D：「生成计划」类 POST 的壳上提为 'Pm.ServeAlbum.planPost'（sort / import /
  -- album add / convert 四处同一道）；place/event 的请求级校验留在这里（Left → 400）。
  ("POST", ["api", "sort", "plan"]) ->
    planPost env req jsonR err "生成计划" $ \(SortPlanReq src mplace mevent from to) ->
      case (mplace, mevent) of
        (Nothing, Nothing) -> Left "place 与 event 必须给一个"
        (Just _, Just _) -> Left "place 与 event 只能给一个"
        _ -> Right (\sink -> runSortPlanTo sink (GoOpts False False) src (maybe (Right (fromMaybe "" mevent)) Left mplace) from to cfg)
  ("POST", ["api", "apply"])
    | not (seAllowApply env) ->
        err status403 "serve 未以 --allow-apply 启动，拒绝执行计划（--writable 只允许生成计划，不执行）"
    | otherwise -> withJsonBody req err $ \(ApplyReq pid only) -> withMVar (seApplyLock env) $ \_ -> do
        logRef <- newIORef []
        let sink l = modifyIORef' logRef (l :)
        prep <- prepareApply cfg sink pid only
        case prep of
          Left m -> err status409 m
          Right (plan, added) -> do
            -- 屏障不在这里调：它随 cfg 装进 ExecEnv，由内核在 root 锁内
            -- 跑（二十九轮 critical）。seApplyLock 只是**进程内**互斥，
            -- 挡不住第二个 pm；跨进程那一半现在由 I10 锁负责。屏障的
            -- 降级理由、收尾 git 步骤、备份缓存告警同走这个 sink（F022/C106）。
            (code, results) <- executePlanNowWith cfg sink plan
            afterApply cfg sink plan results
            logs <- reverse <$> readIORef logRef
            jsonR
              status200
              []
              ( object
                  [ "planId" .= plId plan
                  , "kind" .= plKind plan
                  , "root" .= plRootPath plan
                  , "addedByGroupClosure" .= added
                  , "code" .= code
                  , "items"
                      .= [ object ["ix" .= piIx it, "outcome" .= outcomeLabel out, "status" .= piStatus it]
                         | (it, out) <- results
                         ]
                  , "log" .= logs
                  ]
              )
  ("POST", ["api", "backup-init"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝登记备份盘"
    | otherwise -> withJsonBody req err $ \(BackupInitReq p) -> do
        r <- backupInitRun p cfg
        case r of
          Left m -> jsonR status400 [] (object ["error" .= ("登记失败" :: String), "details" .= [m]])
          Right o -> do
            fresh <- loadConfig
            case fresh of
              Left m -> err status500 ("登记后配置无法重新载入: " <> m)
              Right c2 -> do
                setServeConfig env c2
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
  -- P7 只读端点：把配置好的两仓路径/push 目标拼成上线命令文本。pm 绝不执行
  -- git（I9）——GUI 只把这段文本复制给用户，执行在用户终端。生成逻辑在
  -- 'Pm.Publish.publishCommands'（纯函数，测试直打）。
  ("GET", ["api", "publish-commands"]) ->
    case publishCommands cfg of
      Left m -> err status409 m
      Right ls -> jsonR status200 [] (object ["commands" .= ls])
  ("GET", ["api", "plans"]) -> do
    (ps, errs) <- listPlans (cfgMainPath cfg)
    (vps, verrs) <- maybe (pure ([], [])) listPlans (cfgVaultPath cfg)
    -- 执行态从两根的 journal 折叠（'Pm.Plan.planExecs'——CLI `pm plan list` 同源）：
    -- 计划文件从不回写执行状态，页面此前把执行完的计划照样标「待执行」。
    -- journal 读不出（untrusted 等）→ 折叠为空、计划显示未执行（fail-closed），
    -- 原因进 errors。
    (mes, mwarns) <- readJournal (cfgMainPath cfg)
    (ves, vwarns) <- maybe (pure ([], [])) readJournal (cfgVaultPath cfg)
    let runs = planExecs (mes <> ves)
    jsonR
      status200
      []
      ( object
          [ "plans" .= map (\p -> planSummary p (Map.lookup (plId p) runs)) (ps <> vps)
          , "errors" .= (errs <> verrs <> [("journal", w) | w <- mwarns <> vwarns])
          ]
      )
  ("GET", ["api", "plan", pid])
    | not (isValidPlanId pid) -> err status400 "计划 id 不符合生成格式"
    | otherwise -> do
        ep <- loadPlanAnyRoot cfg pid
        either (err status404) (jsonR status200 [] . toJSON) ep
  -- 计划文件的删除与一键清理（用户 2026-08-31 裁定）。--writable 级：写域仅
  -- @.pm/plans@（计划可再生成，journal/undo/doctor 不受影响）；守卫与 CLI
  -- `pm plan rm` / `pm plan prune` 共用 'deletePlanAnyRoot' / 'prunePlans'。
  ("POST", ["api", "plan", "delete"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝删除计划"
    | otherwise -> withJsonBody req err $ \(PlanIdReq pid) -> do
        r <- deletePlanAnyRoot cfg pid
        case r of
          Left m -> err status404 m
          Right label -> jsonR status200 [] (object ["ok" .= True, "root" .= label])
  ("POST", ["api", "plans", "prune"])
    | not (seWritable env) -> err status403 "serve 以只读启动（无 --writable），拒绝清理计划"
    | otherwise -> withJsonBody req err $ \PruneReq -> do
        (deleted, perrs) <- prunePlans cfg
        jsonR
          status200
          []
          ( object
              [ "deleted" .= [object ["id" .= plId p, "kind" .= plKind p, "root" .= label] | (label, p) <- deleted]
              , "errors" .= perrs
              ]
          )
  ("GET", ["api", "thumb", sha])
    | not (validSha sha) -> err status400 "sha 须为 64 位 hex"
    | otherwise -> do
        lc <- loadCatalog (cfgMainPath cfg)
        case fst (catalogMaybe lc) >>= findJpeg sha of
          -- 工作流 A 簇：索引读不出 ≠ 无此条目——不拿 404 蒙混
          Nothing -> case lc of
            CatRefused _ -> err status503 (loadNote lc)
            _ -> err status404 "无此 JPEG 条目"
          Just rel -> do
            -- 十八轮：enPath 只过了词法闸（userRelOk）；扫描之后条目或其父目录
            -- 被换成指向库外的 symlink/junction 时，按名字 readFile 会跟随。
            -- 逐级 no-follow 解析，只读返回路径。
            m <- resolveUnder (cfgMainPath cfg) rel
            case m of
              Nothing -> err status404 "条目路径不是库内真实路径（链接？），不提供"
              Just abs' -> do
                -- 二十九轮：resolveUnder 只是**预筛**——它验的是路径，返回后
                -- 到 readFile 之间中途一层仍可被换成 junction。改成「先开，
                -- 再问句柄它绑在哪条路径上」（P5-D 的同一条纪律），与 §14
                -- 「取用口走 openBoundTo」的措辞对齐。
                -- 残余：openBoundTo 对**库内 hardlink 判是**，所以它关掉的是
                -- 竞态那一半，不是别名那一半（后者要句柄身份判据）。
                eb <-
                  try (bracket (openBoundTo ReadMode abs') hClose BS.hGetContents)
                    :: IO (Either IOException BS.ByteString)
                case eb of
                  Left e -> err status500 ("读取失败: " <> show e)
                  Right bytes ->
                    respond (responseLBS status200 (("Content-Type", "image/jpeg") : ("Cache-Control", "private, max-age=3600") : corsHdrs) (BSL.fromStrict bytes))
  _ -> err status404 "无此端点"

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

planSummary :: Plan -> Maybe PlanExec -> Value
planSummary p mr =
  object
    [ "id" .= plId p
    , "kind" .= plKind p
    , "root" .= plRootPath p
    , "created" .= (plCreated p :: UTCTime)
    , "items" .= length (plItems p)
    , "pending" .= length pend
    , "skipped" .= count StSkippedByUser
    , "needsDecision" .= length [() | PlanItem {piStatus = StNeedsDecision _} <- plItems p]
    , -- 计划文件里只有 pending / skipped / needs-decision 三态；"已执行"是 journal
      -- 层的事实（Done），不在计划文件上（DESIGN §3）——以下四个字段来自
      -- 'Pm.Plan.planExecs' 的折叠。
      "done" .= length [ix | ix <- pend, ix `Set.member` maybe Set.empty peDone mr]
    , "failed" .= maybe (0 :: Int) (Set.size . peFailed) mr
    , "executed" .= planExecuted p mr
    , "lastRunAt" .= (mr >>= peLastAt)
    ]
 where
  pend = [piIx it | it <- plItems p, piStatus it == StPending]
  count s = length [() | it <- plItems p, piStatus it == s]

-- | @{"planId": "…"}@
newtype PlanIdReq = PlanIdReq Text

instance Aeson.FromJSON PlanIdReq where
  parseJSON = Aeson.withObject "plan-delete" $ \o -> PlanIdReq <$> o Aeson..: "planId"

-- | @{}@——prune 无参数；体仍走 'withJsonBody'（上限与 JSON 闸不因无参而豁免）。
data PruneReq = PruneReq

instance Aeson.FromJSON PruneReq where
  parseJSON = Aeson.withObject "plans-prune" (\_ -> pure PruneReq)

