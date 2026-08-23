{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute)
import System.Exit (exitSuccess, exitWith, ExitCode (..))
import Text.Printf (printf)

import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Config
import Pm.Scan
import Pm.Status
import Pm.Types
import Pm.Win (setupConsole)

data Cmd
  = CmdInit InitOpts
  | CmdScan ScanCmd
  | CmdStatus StatusOpts

data InitOpts = InitOpts
  { ioMain :: FilePath
  , ioVault :: Maybe FilePath
  , ioPhotosJson :: Maybe FilePath
  , ioWorkers :: Maybe Int
  , ioForce :: Bool
  }

data ScanCmd = ScanCmd
  { scWorkers :: Maybe Int
  , scQuiet :: Bool
  }

main :: IO ()
main = do
  setupConsole
  cmd <- execParser parserInfo
  code <- run cmd
  if code == 0 then exitSuccess else exitWith (ExitFailure code)

parserInfo :: ParserInfo Cmd
parserInfo =
  info
    (helper <*> versionOpt <*> (commands <|> pure (CmdStatus (StatusOpts False))))
    (fullDesc <> header "pm — 照片库管理器（零参数 = pm status）")
 where
  versionOpt =
    infoOption "pm 0.1.0 (P0)" (long "version" <> help "打印版本")
  commands =
    hsubparser
      ( command "init" (info initP (progDesc "生成配置 + 主库 root 标识"))
          <> command "scan" (info scanP (progDesc "索引主库（增量；首次全量 hash）"))
          <> command "status" (info statusP (progDesc "总览仪表盘（默认命令）"))
      )
  initP =
    fmap CmdInit $
      InitOpts
        <$> strOption (long "main" <> metavar "PATH" <> help "主库路径，如 D:\\Photography")
        <*> optional (strOption (long "vault" <> metavar "PATH" <> help "vault 展示集路径（P3 使用）"))
        <*> optional (strOption (long "photos-json" <> metavar "PATH" <> help "portfolio photos.json 路径（P3 使用）"))
        <*> optional (option auto (long "workers" <> metavar "N" <> help "hash 并行度（默认=物理核数）"))
        <*> switch (long "force" <> help "已有配置时允许覆盖")
  scanP =
    fmap CmdScan $
      ScanCmd
        <$> optional (option auto (long "workers" <> metavar "N" <> help "hash 并行度"))
        <*> switch (long "quiet" <> help "不打印进度")
  statusP =
    fmap CmdStatus $
      StatusOpts
        <$> switch (long "cached" <> help "跳过新鲜度核对，纯读快照")

run :: Cmd -> IO Int
run (CmdInit o) = runInit o
run (CmdScan o) = runScan o
run (CmdStatus o) = do
  ecfg <- loadConfig
  case ecfg of
    Left e -> putStrLn e >> pure 2
    Right cfg -> runStatus cfg o

runInit :: InitOpts -> IO Int
runInit o = do
  mainPath <- makeAbsolute (ioMain o)
  okMain <- doesDirectoryExist mainPath
  if not okMain
    then putStrLn ("主库路径不存在: " <> mainPath) >> pure 2
    else do
      cfgFp <- configFilePath
      exists <- doesFileExist cfgFp
      if exists && not (ioForce o)
        then do
          putStrLn ("配置已存在: " <> cfgFp <> "（--force 覆盖）")
          pure 2
        else do
          vaultOk <- mapM doesDirectoryExist (ioVault o)
          case (ioVault o, vaultOk) of
            (Just vp, Just False) -> putStrLn ("vault 路径不存在: " <> vp) >> pure 2
            _ -> do
              fp <-
                writeConfig
                  Config
                    { cfgMainPath = mainPath
                    , cfgVaultPath = ioVault o
                    , cfgPhotosJson = ioPhotosJson o
                    , cfgWorkers = ioWorkers o
                    }
              putStrLn ("✓ 配置已写入 " <> fp)
              existing <- readRootInfo mainPath
              case existing of
                Just prior ->
                  putStrLn ("✓ 主库 root 标识已存在（沿用）: " <> T.unpack (riId prior))
                Nothing -> do
                  rid <- freshRootId
                  now <- getCurrentTime
                  writeRootInfo mainPath (RootInfo rid RoleMain now)
                  putStrLn ("✓ 主库 root 标识已创建: " <> T.unpack rid)
              -- vault root 标识在 P3 建（vault 是 git 工作树，I11 要求先走
              -- .gitignore 确认流程），此处只登记路径。
              forM_ (ioVault o) $ \vp ->
                putStrLn ("· vault 路径已登记（root 标识 P3 经确认后创建）: " <> vp)
              putStrLn "下一步: pm scan"
              pure 0

runScan :: ScanCmd -> IO Int
runScan sc = do
  ecfg <- loadConfig
  case ecfg of
    Left e -> putStrLn e >> pure 2
    Right cfg -> do
      let root = cfgMainPath cfg
      minfo <- readRootInfo root
      case minfo of
        Nothing -> do
          putStrLn ("主库缺 .pm/root-id.json → 先运行 pm init --main " <> root)
          pure 2
        Just rootInfo -> do
          (old, warns) <- loadCatalog root
          mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
          defWorkers <- getNumProcessors
          let workers = fromMaybe (fromMaybe defWorkers (cfgWorkers cfg)) (scWorkers sc)
          t0 <- getCurrentTime
          result <-
            scanRoot
              ScanOpts {soWorkers = workers, soProgress = not (scQuiet sc)}
              old
              (riId rootInfo)
              root
          saveCatalog root (srCatalog result)
          t1 <- getCurrentTime
          let cat = srCatalog result
          printf
            "✓ 索引完成: %d 文件（复用 %d + 新 hash %d, %.1f GiB）用时 %s\n"
            (length (catEntries cat))
            (srReused result)
            (srHashed result)
            (fromIntegral (srHashedBytes result) / (1024 * 1024 * 1024 :: Double))
            (show (diffUTCTime t1 t0))
          unless (null (srVolatile result)) $ do
            printf "⚠ %d 个文件在 hash 期间被修改（本轮未入索引，重跑 pm scan）:\n" (length (srVolatile result))
            mapM_ (putStrLn . ("    ~ " <>)) (take 10 (srVolatile result))
          unless (null (srErrors result)) $ do
            printf "⚠ %d 个条目有错误:\n" (length (srErrors result))
            mapM_ (\(p, e) -> putStrLn ("    ! " <> p <> ": " <> e)) (take 20 (srErrors result))
            when (length (srErrors result) > 20) $
              printf "    …另有 %d 条\n" (length (srErrors result) - 20)
          pure (if null (srVolatile result) && null (srErrors result) then 0 else 1)
