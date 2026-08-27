{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ 的 vault 端点（P8-A 自 "Pm.Serve" 拆出，代码逐字搬移，只把
-- case 分支包成 'Maybe'：Serve.hs 触 750 行预算，而 P8 要往里加端点）：
-- @GET \/api\/vault\/status@、@GET \/api\/vault\/new@、@POST \/api\/vault\/push-plan@、
-- @POST \/api\/vault\/hold@ 与它们的请求体类型。授权级别、写域、锁序的注释
-- 随代码走；三级授权的总说明在 "Pm.Serve" 模块头。
module Pm.ServeVault (routeVault) where

import Control.Concurrent.MVar (withMVar)
import Control.Exception (IOException, try)
import Data.Aeson (object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Network.HTTP.Types
import Network.Wai

import Pm.Config (Config (..), requireWritable)
import Pm.Plan (Plan (..), savePlan)
import Pm.ServeEnv
import Pm.ServeGuard (maxBodyBytes, readBodyCapped)
import Pm.Types
import Pm.Vault (VaultDiff (..), VaultReport (..), checkAssignments, computeVault, fixedCategories, gitStepsLines, mkVaultPushPlan, newActive, planCategories, renderVaultJson, vaultPushItems)
import Pm.VaultCmd (holdOpsIO, withHoldsTxn)
import Pm.VaultHold (VaultHold (..), writeHolds)

-- | vault 端点的路由分支：命中返回 @Just 应答动作@，不是 vault 路径返回
-- 'Nothing' 交回 "Pm.Serve" 继续匹配。参数与 'Pm.Serve' 的 routeWith 同一组。
routeVault :: Config -> ServeEnv -> Request -> Reply -> ErrReply -> ResponseHeaders -> (Response -> IO ResponseReceived) -> Maybe (IO ResponseReceived)
routeVault cfg env req jsonR err corsHdrs respond = case (requestMethod req, pathInfo req) of
  ("GET", ["api", "vault", "status"]) -> Just $ do
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
  ("GET", ["api", "vault", "new"]) -> Just $ do
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
    | not (seWritable env) -> Just (err status403 "serve 以只读启动（无 --writable），拒绝生成计划")
    | otherwise -> Just $ do
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
                                            , -- 与 CLI 收尾、上线命令同一生成点（Pm.Publish.vaultCommands）
                                              "gitSteps" .= gitStepsLines cfg (plRootPath plan) (plId plan) (planCategories plan)
                                            ]
                                        )
  -- P4-7：第二个写端点——记录/撤销「暂不同步」的决定。写域是**主库**的
  -- @.pm/vault-holds.json@（vault 仓与照片零改动），校验与 CLI
  -- `pm vault hold|unhold` 共用 'holdRequest'。同样在 'seVaultLock' 里
  -- compute→校验→写一次持锁完成。
  ("POST", ["api", "vault", "hold"])
    | not (seWritable env) -> Just (err status403 "serve 以只读启动（无 --writable），拒绝记录决定")
    | otherwise -> Just $ do
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
  _ -> Nothing
 where
  -- vault 缓存刷新串行化（十八轮 minor）：两个并发 GET 会争用固定 tmp 名。
  vaultReport = withMVar (seVaultLock env) (const (computeVault True cfg))

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
