{-# LANGUAGE ScopedTypeVariables #-}

-- | 外部进程的统一壳（第一方全量审，簇 B）。pm 会拉起两种外部程序：
-- @python@（转换第一段，"Pm.Convert"）与 @claude@（AI 建议，"Pm.ServeAi"）。
-- 此前两处各写各的：claude 那份有整体超时，但 'System.Timeout.timeout' 的
-- 异步异常只让 'withCreateProcess' 终止**直接**子进程——@claude.cmd@ 拉起的
-- node 子树在超时后照跑，而 'seSuggestLock' 已经放开，下一次点击又开一棵；
-- python 那份没有超时、按控制台码页解码输出（非 ASCII 会抛）。
--
-- 这里合成一份纪律：三个管道显式 UTF-8；喂 stdin 与读 stdout\/stderr 三路并发
-- （子进程不读就退出也不算错——结果只看退出码与输出）；整体超时覆盖从喂 stdin
-- 到子进程退出的全程；到点**先** @taskkill \/T \/F@ 杀整棵进程树、**再**收各路
-- 线程。次序不能反（门禁一轮 F2 的第二层，flood 桩实测）：Windows 上阻塞在满
-- 管道里的写是不可中断的 FFI 调用，先 cancel 会一直等到子进程读走或退出——子进程
-- 既不读 stdin 也不退出时就是永久挂死；杀掉子进程管道即断，写端立刻醒来。
-- 拉不起来 \/ 管道异常收进 'ToolFailed'，不向上抛。
module Pm.Subprocess (ToolOutcome (..), runTool, envTimeout) where

import Control.Concurrent.Async (concurrently, waitCatch, withAsync)
import Control.Exception (IOException, SomeException, try)
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hClose, hSetEncoding, utf8)
import System.Process (CreateProcess (..), StdStream (..), getPid, proc, readCreateProcessWithExitCode, waitForProcess, withCreateProcess)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | 一次外部调用的结局。
data ToolOutcome
  = ToolRan ExitCode Text Text
    -- ^ 跑完了：退出码、stdout、stderr（都已按 UTF-8 解码）
  | ToolTimeout Int
    -- ^ 超过 n 秒：整棵进程树已被杀
  | ToolFailed String
    -- ^ 拉不起来 \/ 管道异常（IOException 的文字）
  deriving (Show)

-- | 超时秒数：环境变量（正整数才算）→ 缺省值。
envTimeout :: String -> Int -> IO Int
envTimeout var def = do
  m <- lookupEnv var
  pure $ case m >>= readMaybe of
    Just n | n > 0 -> n
    _ -> def

-- | 跑一个外部程序：可执行、参数、工作目录、附加环境（同名覆盖；空 = 全部
-- 继承）、stdin 文本、超时秒。
runTool :: FilePath -> [String] -> Maybe FilePath -> [(String, String)] -> Text -> Int -> IO ToolOutcome
runTool exe args mcwd extraEnv stdinText secs = do
  env0 <- getEnvironment
  let env' = if null extraEnv then Nothing else Just (extraEnv <> filter ((`notElem` map fst extraEnv) . fst) env0)
      cp = (proc exe args) {cwd = mcwd, env = env', std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  r <- try $ withCreateProcess cp $ \mi mo me ph -> case (mi, mo, me) of
    (Just hi, Just ho, Just he) -> do
      mapM_ (`hSetEncoding` utf8) [hi, ho, he]
      -- 子进程先退出不读 stdin（如立刻报错的 claude \/ python）会让写端拿到
      -- broken pipe：那不是本次调用的失败，结局仍按退出码与输出判。
      let feed = () <$ (try (TIO.hPutStr hi stdinText >> hClose hi) :: IO (Either IOException ()))
          body = do
            ((), (out, errT)) <- concurrently feed (concurrently (TIO.hGetContents ho) (TIO.hGetContents he))
            code <- waitForProcess ph
            pure (code, out, errT)
      -- 三路并发放在自己的线程里；主线程只在 STM 上等它（可中断），计时到点先杀树。
      -- withAsync 的收尾会 cancel 那个线程——此时子进程已死、管道已断，阻塞的写立刻返回。
      withAsync body $ \a -> do
        done <- timeout (secs * 1000000) (waitCatch a)
        case done of
          Nothing -> do
            mpid <- getPid ph
            mapM_ killTree mpid
            pure (ToolTimeout secs)
          Just (Right (code, out, errT)) -> pure (ToolRan code out errT)
          Just (Left (e :: SomeException)) -> pure (ToolFailed (show e))
    _ -> pure (ToolFailed "子进程管道未建立")
  pure (either (\(e :: IOException) -> ToolFailed (show e)) id r)
 where
  killTree pid =
    () <$ (try (readCreateProcessWithExitCode (proc "taskkill" ["/T", "/F", "/PID", show pid]) "") :: IO (Either IOException (ExitCode, String, String)))
