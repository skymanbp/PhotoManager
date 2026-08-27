{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ 的会话环境（P8-A 自 "Pm.Serve" 拆出，代码逐字搬移：Serve.hs
-- 触 750 行预算，而 P8 要往里加端点）。这里只有**被多个端点模块共用**的会话
-- 状态：'ServeEnv'（配置快照、token、授权位、两把进程内互斥）、配置快照的
-- 读与作废、以及端点应答的两个类型别名。路由与其余端点仍在 "Pm.Serve"，
-- vault 端点在 "Pm.ServeVault"，传输原语在 "Pm.ServeGuard"。
module Pm.ServeEnv
  ( ServeEnv (..)
  , newServeEnv
  , currentConfig
  , setServeConfig
  , Reply
  , ErrReply
  ) where

import Control.Concurrent.MVar (MVar, newMVar)
import Data.Aeson (Value)
import qualified Data.ByteString as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Time (UTCTime)
import Network.HTTP.Types (ResponseHeaders, Status)
import Network.Wai (ResponseReceived)

import Pm.Config (Config (..), configFilePath, loadConfig)
import Pm.ServeGuard (configStamp)

-- | 一次 serve 会话的状态：配置、token、可写开关、vault 缓存刷新的进程内互斥。
data ServeEnv = ServeEnv
  { seCfgSnap :: IORef (Config, Maybe (UTCTime, Integer), Bool)
    -- ^ 配置快照、其 config.toml 变更戳、有效位——**一个** IORef 成组存取
    -- （41 轮 #4：拆两个 ref 时两个写端点可交错成〈旧配置, 新戳〉且永不
    -- 自愈）。有效位 False = 作废，下一请求必从盘上重读（C105/P4-8）；
    -- 作废与「配置文件不存在（戳 Nothing）」是两个状态，不共用编码。
  , seToken :: BS.ByteString
  , seWritable :: Bool
  , seAllowApply :: Bool
  , seVaultLock :: MVar ()
  , seApplyLock :: MVar ()
    -- ^ 同一 serve 进程内的 apply 串行化。跨进程另有 root 锁（I10）——这把只是
    -- 让页面连点两下得到的是排队，而不是一条 "lock busy"。
  }

-- | @allowApply@ 蕴含 writable：见 "Pm.Serve" 模块头的三级授权。
newServeEnv :: Config -> BS.ByteString -> Bool -> Bool -> IO ServeEnv
newServeEnv cfg tok writable allowApply = do
  -- 〈配置, 戳〉一次配对写入（装载与读戳之间的毫秒级启动窗口沿旧例登记）。
  snap <- configFilePath >>= configStamp >>= \st -> newIORef (cfg, st, True)
  ServeEnv snap tok (writable || allowApply) allowApply <$> newMVar () <*> newMVar ()

-- | 本次请求应答所依据的配置。第一方自审工作流 C105：此前快照只在本进程的
-- POST 之后刷新，终端里 `pm config set` / `pm backup init` 改了 config.toml
-- 之后 GET /api/config 仍答启动时的旧值——设置页「重新载入」拿到同一份旧快照，
-- 还把旧 vault 路径预填进输入框，一点保存就把终端改动静默改回去。每次请求
-- stat 一次配置文件（'configStamp'），戳变了才重读；只并入可变字段，主库路径
-- 保持启动时的锚点（--allow-apply 授权的对象就是它；'Pm.ConfigEdit' 也拒改）。
-- 重读失败 → 本次请求 500 并说明原因，快照与戳都不动（报告 fail-closed）。
currentConfig :: ServeEnv -> IO (Either String Config)
currentConfig env = do
  fp <- configFilePath
  now <- configStamp fp
  (boot, seen, ok) <- readIORef (seCfgSnap env)
  if ok && now == seen
    then pure (Right boot)
    else do
      r <- loadConfig
      case r of
        Left m -> pure (Left ("配置文件已在外部改动但无法重新载入（" <> m <> "）——修正后重试"))
        Right fresh -> do
          let merged = fresh {cfgMainPath = cfgMainPath boot}
          -- 41 轮 #4：载入后**再读一次戳**，与载入前一致才可与配置成对入册；
          -- 载入期间又被改（戳不同）→ 有效位 False，下一请求必然重读。
          now2 <- configStamp fp
          writeIORef (seCfgSnap env) (merged, now2, now2 == now)
          pure (Right merged)

-- | 写端点改完配置后**作废**快照。41 轮 #4：此前这里「写配置引用」与「读
-- 盘上变更戳」是两步独立动作，两个写端点并发可交错成〈旧配置, 新戳〉——
-- 〈配置, 戳〉配对只允许发生在 'currentConfig' 的双读戳路径上；这里只作废
-- （主库锚点随快照保持），下一请求必然从盘上重读到刚写入的值。
setServeConfig :: ServeEnv -> Config -> IO ()
setServeConfig env _ = do
  (boot, seen, _) <- readIORef (seCfgSnap env)
  writeIORef (seCfgSnap env) (boot, seen, False)

-- | JSON 应答（状态码、附加头、体）——由 'Pm.Serve.serveApp' 按请求的 CORS 头
-- 构造后传给各端点模块。
type Reply = Status -> ResponseHeaders -> Value -> IO ResponseReceived

-- | 错误应答（状态码、一句人话）——同上，体固定为 @{"error": …}@。
type ErrReply = Status -> String -> IO ResponseReceived
