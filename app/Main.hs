{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, unless, when)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute, removeFile)
import System.Exit (exitSuccess, exitWith, ExitCode (..))
import System.FilePath ((</>))
import Text.Printf (printf)
import Text.Read (readMaybe)

import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Config
import Pm.Doctor (DoctorOpts (..), renderFinding, runDoctor)
import Pm.Exec (ItemOutcome (..), defaultExecEnv, execPlan, outcomeLabel, updateCatalog)
import Pm.Plan
import Pm.Scan
import Pm.Status
import Pm.Trash
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Win (setupConsole)

data Cmd
  = CmdInit InitOpts
  | CmdScan ScanCmd
  | CmdStatus StatusOpts
  | CmdDoctor DoctorOpts
  | CmdTrash TrashCmd
  | CmdUndo Int
  | CmdApply ApplyOpts
  | CmdResolve ResolveOpts

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

data TrashCmd = TrashList | TrashEmpty Bool

data ApplyOpts = ApplyOpts
  { aoId :: T.Text
  , aoOnly :: Maybe String
  , aoDry :: Bool
  }

data ResolveOpts = ResolveOpts
  { roId :: T.Text
  , roItem :: Int
  , roSkip :: Bool -- True = skip, False = unskip
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
    (fullDesc <> header "pm — 照片库管理器（零参数 = pm status；写盘一律两段式 计划→apply）")
 where
  versionOpt =
    infoOption "pm 0.1.0 (P1)" (long "version" <> help "打印版本")
  commands =
    hsubparser
      ( command "init" (info initP (progDesc "生成配置 + 主库 root 标识"))
          <> command "scan" (info scanP (progDesc "索引主库（增量；首次全量 hash）"))
          <> command "status" (info statusP (progDesc "总览仪表盘（默认命令）"))
          <> command "doctor" (info doctorP (progDesc "崩溃恢复对账 + 完整性体检（默认只读）"))
          <> command "trash" (info trashP (progDesc "隔离区：list / empty（唯一最终清除入口）"))
          <> command "undo" (info undoP (progDesc "由 journal 生成反向计划（经 pm apply 执行）"))
          <> command "apply" (info applyP (progDesc "执行已存的计划"))
          <> command "resolve" (info resolveP (progDesc "裁决/跳过计划中的某一项"))
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
  doctorP =
    fmap CmdDoctor $
      DoctorOpts
        <$> switch (long "deep" <> help "全量重 hash 索引条目（慢，介质级验证）")
        <*> switch (long "repair" <> help "应用安全闭环：补记 Done / 清自建 tmp / 生成 C5 隔离计划")
  trashP =
    fmap CmdTrash $
      hsubparser
        ( command "list" (info (pure TrashList) (progDesc "manifest ∪ 盘面 并集视图"))
            <> command
              "empty"
              ( info
                  (TrashEmpty <$> switch (long "yes" <> help "确认清除下列条目（无此开关只列清单）"))
                  (progDesc "最终清除隔离区已登记条目（逐项列出）")
              )
        )
  undoP = CmdUndo <$> option auto (long "last" <> metavar "N" <> value 1 <> help "撤销最近 N 个已完成操作（默认 1）")
  applyP =
    fmap CmdApply $
      ApplyOpts
        <$> strArgument (metavar "PLAN-ID")
        <*> optional (strOption (long "only" <> metavar "1,3-5" <> help "只执行这些序号"))
        <*> switch (long "dry" <> help "只打印计划不执行")
  resolveP =
    fmap CmdResolve $
      ResolveOpts
        <$> strArgument (metavar "PLAN-ID")
        <*> option auto (long "item" <> metavar "N" <> help "条目序号")
        <*> flag True False (long "unskip" <> help "恢复为待执行（默认动作是跳过该项）")

run :: Cmd -> IO Int
run (CmdInit o) = runInit o
run (CmdScan o) = withCfg (runScanCmd o)
run (CmdStatus o) = withCfg (\cfg -> runStatus cfg o)
run (CmdDoctor o) = withCfg $ \cfg -> do
  (findings, code) <- runDoctor (cfgMainPath cfg) o
  if null findings
    then putStrLn "✓ doctor: 无发现"
    else mapM_ (putStrLn . renderFinding) findings
  pure code
run (CmdTrash tc) = withCfg (runTrash tc)
run (CmdUndo n) = withCfg $ \cfg -> do
  r <- buildUndoPlan (cfgMainPath cfg) n
  case r of
    Left e -> putStrLn e >> pure 2
    Right plan -> do
      fp <- savePlan plan
      mapM_ putStrLn (renderPlan plan)
      putStrLn ("计划已存 " <> fp)
      putStrLn ("执行: pm apply " <> T.unpack (plId plan))
      pure 0
run (CmdApply o) = withCfg (runApply o)
run (CmdResolve o) = withCfg (runResolve o)

withCfg :: (Config -> IO Int) -> IO Int
withCfg act = do
  ecfg <- loadConfig
  case ecfg of
    Left e -> putStrLn e >> pure 2
    Right cfg -> act cfg

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

runScanCmd :: ScanCmd -> Config -> IO Int
runScanCmd sc cfg = do
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

runTrash :: TrashCmd -> Config -> IO Int
runTrash tc cfg = do
  let root = cfgMainPath cfg
  tv <- trashView root
  mapM_ (\w -> putStrLn ("✗ manifest 损坏行: " <> w)) (tvWarnings tv)
  case tc of
    TrashList -> do
      if null (tvRegistered tv) && null (tvUnregistered tv)
        then putStrLn "隔离区为空"
        else do
          forM_ (tvRegistered tv) $ \(r, present) ->
            printf
              "  %-8s %s  ← %s  (%s, plan %s)\n"
              (if present then "在库" :: String else "已清除")
              (trTrashRel r)
              (trVictimRel r)
              (T.unpack (trReason r))
              (T.unpack (trPlanId r))
          forM_ (tvUnregistered tv) $ \f ->
            putStrLn ("  UNREGISTERED " <> f <> "  （无 manifest 记录，先跑 pm doctor）")
      pure 0
    TrashEmpty yes -> do
      let purgeable = [(r, trashDir root </> trTrashRel r) | (r, True) <- tvRegistered tv]
      if null purgeable
        then putStrLn "隔离区没有可清除的已登记条目" >> pure 0
        else do
          putStrLn ("将永久删除以下 " <> show (length purgeable) <> " 个已登记条目:")
          forM_ purgeable $ \(r, _) ->
            putStrLn ("  × " <> trTrashRel r <> "  (原 " <> trVictimRel r <> ")")
          unless (null (tvUnregistered tv)) $
            putStrLn ("（另有 " <> show (length (tvUnregistered tv)) <> " 个 UNREGISTERED 文件不会被动，先跑 pm doctor）")
          if not yes
            then putStrLn "确认清除请加 --yes" >> pure 1
            else do
              -- pm 全程唯一 unlink 用户数据的位置：仅限上面逐项列出的条目
              -- （DESIGN §5 pm trash empty；I2 的最终出口）。
              forM_ purgeable $ \(_, abs') -> removeFile abs'
              putStrLn ("✓ 已清除 " <> show (length purgeable) <> " 项（manifest 记录保留为历史）")
              pure 0

runApply :: ApplyOpts -> Config -> IO Int
runApply o cfg = do
  let root = cfgMainPath cfg
  ep <- loadPlan root (aoId o)
  case ep of
    Left e -> putStrLn e >> pure 2
    Right plan0 -> do
      only <- case aoOnly o of
        Nothing -> pure (Right Nothing)
        Just spec -> pure (maybe (Left ("--only 语法错误: " <> spec)) (Right . Just) (parseOnly spec))
      case only of
        Left e -> putStrLn e >> pure 2
        Right msel -> do
          let selected it = maybe True (piIx it `elem`) msel
              plan =
                plan0
                  { plItems =
                      [ if selected it then it else it {piStatus = StSkippedByUser}
                      | it <- plItems plan0
                      ]
                  }
          mapM_ putStrLn (renderPlan plan)
          if aoDry o
            then pure 0
            else do
              r <- execPlan defaultExecEnv plan
              case r of
                Left e -> putStrLn e >> pure 2
                Right results -> do
                  forM_ results $ \(it, out) ->
                    printf "  %3d → %s\n" (piIx it) (outcomeLabel out)
                  -- catalog 回写
                  (mcat, _) <- loadCatalog root
                  case mcat of
                    Nothing -> putStrLn "（root 尚无索引，跳过 catalog 回写；之后 pm scan 会补齐）"
                    Just cat -> do
                      now <- getCurrentTime
                      saveCatalog root (updateCatalog now results cat)
                  let bad = [() | (_, out) <- results, isBad out]
                  pure (if null bad then 0 else 1)
 where
  isBad (OConflict _) = True
  isBad (OFailed _) = True
  isBad _ = False

runResolve :: ResolveOpts -> Config -> IO Int
runResolve o cfg = do
  let root = cfgMainPath cfg
  ep <- loadPlan root (roId o)
  case ep of
    Left e -> putStrLn e >> pure 2
    Right plan -> do
      let hit = [it | it <- plItems plan, piIx it == roItem o]
      case hit of
        [] -> putStrLn ("计划中无条目 " <> show (roItem o)) >> pure 2
        _ -> do
          let newStatus = if roSkip o then StSkippedByUser else StPending
              plan' =
                plan
                  { plItems =
                      [ if piIx it == roItem o then it {piStatus = newStatus} else it
                      | it <- plItems plan
                      ]
                  }
          _ <- savePlan plan'
          mapM_ putStrLn (renderPlan plan')
          pure 0

-- "1,3-5" → [1,3,4,5]
parseOnly :: String -> Maybe [Int]
parseOnly spec = concat <$> mapM part (splitOn ',' spec)
 where
  part s = case break (== '-') s of
    (a, '-' : b) -> do
      x <- readMaybe a
      y <- readMaybe b
      if x <= y then Just [x .. y] else Nothing
    (a, "") -> (: []) <$> readMaybe a
    _ -> Nothing
  splitOn c = foldr step [[]]
   where
    step ch acc@(cur : rest)
      | ch == c = [] : acc
      | otherwise = (ch : cur) : rest
    step _ [] = [[]]
