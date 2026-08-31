{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ 的归档页端点（P8-D，DESIGN-P8 §23.1）：
-- @POST \/api\/import\/plan@、@GET \/api\/album\/candidates@、@POST \/api\/album\/add-plan@、
-- @POST \/api\/convert\/plan@、@POST \/api\/album\/ignore@（忽略候选，只写主库
-- @.pm\/album-ignore.json@）。三个计划写端点都是 @--writable@ 级「只生成计划」，
-- 与 CLI 走**同一个** sink 化的入口（'runImportTo' \/ 'runAlbumAddTo' \/
-- 'runConvertTo'）——页面上的交代行就是终端会打印的那些行；退出码、计划 id
-- 与逐行日志走 JSON 响应体（stdout 已静音）。转换的第一段会写主库
-- @.pm\/derived@（pm 自建状态，DESIGN-P8 §20），仍不碰照片。
module Pm.ServeAlbum (routeAlbum, planPost) where

import Control.Concurrent.MVar (withMVar)
import Control.Exception (IOException, try)
import Data.Aeson (object, (.=))
import qualified Data.Aeson as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import Network.HTTP.Types
import Network.Wai
import System.FilePath (joinPath, splitDirectories, takeFileName)

import Pm.Album (AlbumCandidates (..), AlbumIgnore (..), albumCandidates, readIgnores, runAlbumAddTo, runAlbumIgnoreTo, splitIgnores)
import Pm.Catalog (catalogOr, loadCatalog)
import Pm.Cli (GoOpts (..))
import Pm.Commands (runImportTo)
import Pm.Config (Config (..), requireRole)
import Pm.Convert (ConvertOpts (..), runConvertTo)
import Pm.ServeEnv
import Pm.ServeGuard (withJsonBody)
import Pm.Types

-- | 归档页端点的路由分支：命中返回 @Just 应答动作@，否则 'Nothing' 交回
-- "Pm.Serve" 继续匹配（同 'Pm.ServeVault.routeVault' 的形态）。
routeAlbum :: Config -> ServeEnv -> Request -> Reply -> ErrReply -> Maybe (IO ResponseReceived)
routeAlbum cfg env req jsonR err = case (requestMethod req, pathInfo req) of
  -- 暂存区 → Raw/成片 归档计划（--also-album 同 CLI）。
  ("POST", ["api", "import", "plan"]) ->
    Just $ planPost env req jsonR err "生成归档计划" $ \(ImportReq also) -> Right (\sink -> runImportTo sink noGo also cfg)
  -- 只读：与 `pm album candidates` 同源 'albumCandidates'。身份闸先于任何
  -- catalog 读取（F095）；主库无身份/无索引 → 404（同 vault status 的 code 2）。
  -- 忽略清单读不出是 500 硬错（当成空会把用户压掉的候选整批放回来）。
  ("GET", ["api", "album", "candidates"]) -> Just $ do
    er <- requireRole RoleMain root
    case er of
      Left m -> err status404 m
      Right _ -> do
        ei <- readIgnores root
        case ei of
          Left m -> err status500 m
          Right igs -> do
            lc <- loadCatalog root
            case catalogOr "主库尚未索引 → 先 pm scan" lc of
              Left m -> err status404 m
              Right (cat, warns) -> do
                let ac = albumCandidates (Set.fromList (map aiSha igs)) cat
                    (_, staleIgs) = splitIgnores ac igs
                jsonR status200 [] (candidatesJson ac staleIgs warns)
  -- 忽略/取消忽略候选（用户 2026-08-31 裁定，按内容 sha）。--writable 级：写域
  -- 仅主库 @.pm/album-ignore.json@（照片零改动）；校验与 CLI
  -- `pm album ignore|unignore` 共用 'runAlbumIgnoreTo'（内含 requireMain 预检 +
  -- 主库 root lock 事务）；'seVaultLock' 只做进程内排队，连点不吃「锁被占」。
  ("POST", ["api", "album", "ignore"])
    | not (seWritable env) -> Just (err status403 "serve 以只读启动（无 --writable），拒绝写入忽略清单")
    | otherwise -> Just $ withJsonBody req err $ \(IgnoreReq is us) -> withMVar (seVaultLock env) $ \_ -> do
        logRef <- newIORef []
        r <- try (runAlbumIgnoreTo (\l -> modifyIORef' logRef (l :)) is us cfg) :: IO (Either IOException Int)
        logs <- reverse <$> readIORef logRef
        case r of
          Left ex -> jsonR status500 [] (object ["error" .= ("写入忽略清单中断: " <> show ex), "log" .= logs])
          Right 0 -> jsonR status200 [] (object ["ok" .= True, "log" .= logs])
          Right _ -> jsonR status400 [] (object ["error" .= ("忽略清单未写入" :: String), "details" .= logs])
  -- 成片 → 相册 计划：paths 是相对成片层的 <事件夹>/<文件名>（'parseProcessedRel' 闸）。
  ("POST", ["api", "album", "add-plan"]) ->
    Just $ planPost env req jsonR err "生成相册计划" $ \(PathsReq ps) -> Right (\sink -> runAlbumAddTo sink noGo ps cfg)
  -- 非 jpg → 派生 jpg → 计划。第一段（python 写 .pm/derived）进程内串行化：
  -- 两个并发请求转同一张会争用同一个 .tmp 名；排队而不是拒绝（幂等，后到者复用）。
  ("POST", ["api", "convert", "plan"]) ->
    Just $ planPost env req jsonR err "转换并生成计划" $ \(ConvertReq ps also) ->
      Right (\sink -> withMVar (seConvertLock env) (\_ -> runConvertTo sink (ConvertOpts noGo also False ps) cfg))
  _ -> Nothing
 where
  root = cfgMainPath cfg
  noGo = GoOpts False False

-- | 「生成计划」类 POST 的共用壳（sort \/ import \/ album add \/ convert 四处同一道）：
-- writable 闸 → 体上限与 JSON（'withJsonBody'）→ 请求级校验（Left → 400）→
-- 交给 sink 化的 CLI 入口 → @{"code","planId","log"}@。计划 id 由入口直接交回，
-- 不从 @.pm\/plans@ 里挑「最新的那个」（并发生成时那是猜）。
planPost ::
  Aeson.FromJSON q =>
  ServeEnv ->
  Request ->
  Reply ->
  ErrReply ->
  String ->
  (q -> Either String ((String -> IO ()) -> IO (Int, Maybe Text))) ->
  IO ResponseReceived
planPost env req jsonR err what check
  | not (seWritable env) = err status403 ("serve 以只读启动（无 --writable），拒绝" <> what)
  | otherwise = withJsonBody req err $ \q -> case check q of
      Left m -> err status400 m
      Right run -> do
        -- 工作流 F051/F078：交代清单与中止说明随 log 回页面（stdout 已静音）。
        -- 入口抛出的 IOException（索引读到一半被占、.pm 不可写）→ 500 带原因与
        -- 已有的交代行，而不是 warp 的空 500（同 sort/plan 的旧例）。
        logRef <- newIORef []
        r <- try (run (\l -> modifyIORef' logRef (l :))) :: IO (Either IOException (Int, Maybe Text))
        logs <- reverse <$> readIORef logRef
        case r of
          Left ex -> jsonR status500 [] (object ["error" .= (what <> "中断: " <> show ex), "log" .= logs])
          Right (code, mpid) -> jsonR status200 [] (object ["code" .= code, "planId" .= mpid, "log" .= logs])

-- | 'AlbumCandidates' 的线上形状（同 'Pm.Serve.surveyJson' 的理由：内核层不认识
-- aeson，线上形状是 API 的事）。@rel@ 就是 @pm album add@ \/ add-plan 要的参数，
-- @path@ 是 @pm convert@ \/ convert/plan 要的库内相对路径——页面原样回传，不再拼。
-- @ignored@ 是被忽略清单压掉的候选（取消用 sha）；@ignoreStale@ 是已失效的
-- 忽略记录（对象不再是候选——只提示，清理是用户的决定）。
candidatesJson :: AlbumCandidates -> [AlbumIgnore] -> [String] -> Aeson.Value
candidatesJson ac staleIgs warns =
  object
    [ "events"
        .= [ object
              [ "event" .= ev
              , "photos"
                  .= [ object
                        [ "rel" .= joinPath (drop 1 (splitDirectories (enPath e)))
                        , "path" .= enPath e
                        , "name" .= takeFileName (enPath e)
                        , "sha" .= enSha e
                        , "size" .= enSize e
                        , "conflict" .= conflict
                        ]
                     | (e, conflict) <- xs
                     ]
              ]
           | (ev, xs) <- acEvents ac
           ]
    , "nonJpg"
        .= [ object
              [ "path" .= enPath e
              , "layer" .= concat (take 1 (splitDirectories (enPath e)))
              , "name" .= takeFileName (enPath e)
              , "sha" .= enSha e
              , "size" .= enSize e
              ]
           | e <- acNonJpg ac
           ]
    , "ignored"
        .= [ object
              [ "path" .= enPath e
              , "name" .= takeFileName (enPath e)
              , "sha" .= enSha e
              , "size" .= enSize e
              , "conflict" .= conflict
              ]
           | (e, conflict) <- acIgnored ac
           ]
    , "ignoreStale" .= [object ["sha" .= aiSha x, "path" .= aiPath x] | x <- staleIgs]
    , "warnings" .= warns
    ]

-- | @{"ignore":["26-06-R66/a.jpg"],"unignore":["<sha|路径>"]}@（两键都可缺省）
data IgnoreReq = IgnoreReq [String] [String]

instance Aeson.FromJSON IgnoreReq where
  parseJSON = Aeson.withObject "album-ignore" $ \o -> do
    is <- o Aeson..:? "ignore"
    us <- o Aeson..:? "unignore"
    pure (IgnoreReq (fromMaybe [] is) (fromMaybe [] us))

-- | @{"alsoAlbum": true}@（缺省 false）
newtype ImportReq = ImportReq Bool

instance Aeson.FromJSON ImportReq where
  parseJSON = Aeson.withObject "import-plan" $ \o -> ImportReq . fromMaybe False <$> o Aeson..:? "alsoAlbum"

-- | @{"paths":["26-06-R66/a.jpg",…]}@
newtype PathsReq = PathsReq [String]

instance Aeson.FromJSON PathsReq where
  parseJSON = Aeson.withObject "album-add-plan" $ \o -> PathsReq <$> o Aeson..: "paths"

-- | @{"paths":["成片/26-06-R66/x.tif",…],"alsoAlbum":false}@
data ConvertReq = ConvertReq [String] Bool

instance Aeson.FromJSON ConvertReq where
  parseJSON = Aeson.withObject "convert-plan" $ \o ->
    ConvertReq <$> o Aeson..: "paths" <*> (fromMaybe False <$> o Aeson..:? "alsoAlbum")
