-- | @pm ui@ —— 拉起桌面 GUI（DESIGN §11，P4-3）。
--
-- 职责只有一件：找到 @pm-ui.exe@，把**自己的可执行路径**经环境变量 @PM_EXE@
-- 交给它，然后等它退出。GUI 拿到 @PM_EXE@ 后唯一会做的事是运行 @pm serve@，
-- 读取 announce 行拿到 port/token——它不会调用别的 pm 子命令，也不会碰照片
-- 文件（§11 边界）。serve 进程的生命周期归 GUI 管（GUI 退出即杀），因此这里
-- 不启动 serve，避免留下孤儿服务。
--
-- 查找顺序：环境变量 @PM_UI_EXE@（开发期指向 cargo 构建产物）→ 与 pm.exe
-- 同目录的 @pm-ui.exe@。
module Pm.Ui (runUi, locateUi) where

import Control.Monad (filterM)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (CreateProcess (..), createProcess, proc, waitForProcess)

-- | 候选路径按优先序；返回第一个存在的。
locateUi :: IO (Either [FilePath] FilePath)
locateUi = do
  self <- getExecutablePath
  mEnv <- lookupEnv "PM_UI_EXE"
  let candidates = maybe [] pure mEnv <> [takeDirectory self </> "pm-ui.exe"]
  found <- filterM doesFileExist candidates
  pure $ case found of
    (exe : _) -> Right exe
    [] -> Left candidates

runUi :: IO Int
runUi = do
  e <- locateUi
  case e of
    Left tried -> do
      putStrLn "找不到 pm-ui.exe。查过："
      mapM_ (putStrLn . ("  " <>)) tried
      putStrLn "  → 设 PM_UI_EXE 指向 cargo 构建产物，或把 pm-ui.exe 放到 pm.exe 同目录"
      pure 2
    Right exe -> do
      self <- getExecutablePath
      env0 <- getEnvironment
      let env' = ("PM_EXE", self) : filter ((/= "PM_EXE") . fst) env0
      (_, _, _, ph) <- createProcess (proc exe []) {env = Just env'}
      code <- waitForProcess ph
      pure $ case code of
        ExitSuccess -> 0
        ExitFailure n -> n
