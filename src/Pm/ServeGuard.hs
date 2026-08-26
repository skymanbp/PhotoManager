{-# LANGUAGE OverloadedStrings #-}

-- | @pm serve@ 的传输/守卫层（P7 自 "Pm.Serve" 拆出，代码逐字搬移：Serve.hs
-- 触 750 行预算）。这里只有**不依赖 ServeEnv 的**传输原语：token 生成、
-- Host\/Origin 闸、常量时间鉴权、body 上限、loopback 绑定与 stdout 静音。
-- 语义与安全注释随代码走；路由与端点仍在 "Pm.Serve"。
module Pm.ServeGuard
  ( newToken
  , portOk
  , hostOk
  , allowedOrigin
  , authorized
  , maxBodyBytes
  , readBodyCapped
  , muteStdout
  , waitStdinEof
  , bindLoopback
  ) where

import Control.Exception (IOException, catch, try)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteArray as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import GHC.IO.Handle (hDuplicateTo)
import Network.HTTP.Types (RequestHeaders, hAuthorization)
import Network.Socket
import Network.Wai (Request, getRequestBodyChunk)
import System.IO (IOMode (WriteMode), hClose, hIsEOF, openFile, stdin, stdout)

-- | 16 字节熵 → 32 位 hex。
newToken :: IO BS.ByteString
newToken = do
  raw <- getRandomBytes 16 :: IO BS.ByteString
  pure (convertToBase Base16 raw)

portOk :: Int -> Bool
portOk p = p >= 0 && p <= 65535

-- | @Host@ 头须为 @127.0.0.1@ 或 @127.0.0.1:<1-5 位十进制端口>@——精确解析，
-- 不做前缀判定（十八轮：前缀判定会放过 @127.0.0.1:1\@evil@ 之类的尾巴；就
-- DNS rebinding 而言那不可利用，但闸的语义应当是"恰好是这个 Host"）。
hostOk :: BS.ByteString -> Bool
hostOk h = case BS.stripPrefix "127.0.0.1" h of
  Just "" -> True
  Just rest
    | Just port <- BS.stripPrefix ":" rest ->
        not (BS.null port) && BS.length port <= 5 && BC.all (\c -> c >= '0' && c <= '9') port
  _ -> False

allowedOrigins :: [BS.ByteString]
allowedOrigins = ["tauri://localhost", "http://tauri.localhost", "https://tauri.localhost"]

allowedOrigin :: BS.ByteString -> Bool
allowedOrigin = (`elem` allowedOrigins)

authorized :: BS.ByteString -> RequestHeaders -> Bool
authorized tok hdrs = case lookup hAuthorization hdrs of
  Just v
    | Just given <- BS.stripPrefix "Bearer " v ->
        BS.length given == BS.length tok && BA.constEq given tok
  _ -> False

-- | POST 请求体上限（十八轮：warp 默认无总 body 上限，写端点须自设）。一次
-- 分类指派最多几十条 name/category，64 KiB 绰绰有余。
maxBodyBytes :: Int
maxBodyBytes = 64 * 1024

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

-- | 把进程的 stdout 换成空设备。失败即忽略：这是防管道堵塞的加固，
-- 换不成最坏也只是回到"可能堵"的旧状态，不该因此让 serve 起不来。
muteStdout :: IO ()
muteStdout =
  ( do
      h <- openFile nulDevice WriteMode
      hDuplicateTo h stdout
      hClose h
  )
    -- 三十九轮（P7 类清扫）：SomeException→IOException。包住的三个操作都
    -- 只抛 IO 异常；吞的理由（加固失败不阻 serve 启动）不变。
    `catch` \(_ :: IOException) -> pure ()
 where
  -- 设备命名空间：裸 "NUL" 走 GHC 的普通路径打开会 does not exist（实测）
  nulDevice = [bsl, bsl, '.', bsl] <> "NUL"
  bsl = toEnum 92

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
