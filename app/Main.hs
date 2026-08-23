{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless, when)
import Data.Char (toLower)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import Options.Applicative
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute, removeFile)
import System.Exit (exitSuccess, exitWith, ExitCode (..))
import System.FilePath (splitDirectories, splitDrive, splitExtension, (</>))
import System.IO (hFlush, stdout)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Pm.Backup
import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Clean
import Pm.Config
import Pm.Diff
import Pm.Doctor (DoctorOpts (..), renderFinding, runDoctor)
import Pm.Exec (ExecEnv (..), ItemOutcome (..), defaultExecEnv, execPlan, outcomeLabel, updateCatalog)
import Pm.Hash (StatSnap (..), sha256File, statSnap)
import Pm.Import
import Pm.Journal (Sync (..))
import Pm.Op
import Pm.Plan
import Pm.Scan
import Pm.Status
import Pm.Trash
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Win (setupConsole, volumeFsType)

data Cmd
  = CmdInit InitOpts
  | CmdScan ScanCmd
  | CmdStatus StatusOpts
  | CmdDoctor DoctorOpts Bool -- Bool = --backup (体检备份 root)
  | CmdTrash TrashCmd Bool
  | CmdUndo Int
  | CmdApply ApplyOpts
  | CmdResolve ResolveOpts
  | CmdImport GoOpts
  | CmdBackup BackupCmd
  | CmdClean GoOpts -- clean staging

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
  , roSkip :: Bool -- True = skip, False = unskip（--keep 缺席时生效）
  , roKeep :: Maybe String -- src | dst | both
  }

-- | 写盘命令共有的两段式开关（DESIGN.md §5）。
data GoOpts = GoOpts
  { goApply :: Bool
  , goYes :: Bool
  }

data BackupCmd
  = BackupInit FilePath
  | BackupRun GoOpts (Maybe Int)

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
    infoOption "pm 0.2.0 (P2)" (long "version" <> help "打印版本")
  commands =
    hsubparser
      ( command "init" (info initP (progDesc "生成配置 + 主库 root 标识"))
          <> command "scan" (info scanP (progDesc "索引主库（增量；首次全量 hash）"))
          <> command "status" (info statusP (progDesc "总览仪表盘（默认命令）"))
          <> command "import" (info importP (progDesc "暂存区 To-Be-Sync'd → Raw/成片 归档计划"))
          <> command "backup" (info backupP (progDesc "主库 → 备份盘单向增量（init 登记备份盘）"))
          <> command "clean" (info cleanP (progDesc "clean staging: 三副本确认后的暂存清理计划"))
          <> command "doctor" (info doctorP (progDesc "崩溃恢复对账 + 完整性体检（默认只读）"))
          <> command "trash" (info trashP (progDesc "隔离区：list / empty（唯一最终清除入口）"))
          <> command "undo" (info undoP (progDesc "由主库 journal 生成反向计划（经 pm apply 执行）"))
          <> command "apply" (info applyP (progDesc "执行已存的计划（主库或备份盘）"))
          <> command "resolve" (info resolveP (progDesc "裁决计划某项：跳过/恢复/--keep src|dst|both"))
      )
  initP =
    fmap CmdInit $
      InitOpts
        <$> strOption (long "main" <> metavar "PATH" <> help "主库路径，如 D:\\Photography")
        <*> optional (strOption (long "vault" <> metavar "PATH" <> help "vault 展示集路径（P3 使用）"))
        <*> optional (strOption (long "photos-json" <> metavar "PATH" <> help "portfolio photos.json 路径（P3 使用）"))
        <*> optional (option auto (long "workers" <> metavar "N" <> help "hash 并行度（默认=物理核数）"))
        <*> switch (long "force" <> help "已有配置时允许覆盖（备份盘登记保留）")
  scanP =
    fmap CmdScan $
      ScanCmd
        <$> optional (option auto (long "workers" <> metavar "N" <> help "hash 并行度"))
        <*> switch (long "quiet" <> help "不打印进度")
  statusP =
    fmap CmdStatus $
      StatusOpts
        <$> switch (long "cached" <> help "跳过新鲜度核对，纯读快照")
  goOpts =
    GoOpts
      <$> switch (long "apply" <> help "展示计划后确认执行（缺省只生成计划）")
      <*> switch (long "yes" <> help "跳过交互确认（脚本用）")
  importP = CmdImport <$> goOpts
  backupP =
    fmap CmdBackup $
      hsubparser
        ( command
            "init"
            ( info
                (BackupInit <$> strArgument (metavar "PATH" <> help "备份盘上的镜像路径，如 E:\\Photography"))
                (progDesc "登记已插入的备份盘（写 .pm/root-id.json，按 UUID 认盘不认盘符）")
            )
        )
        <|> (BackupRun <$> goOpts <*> optional (option auto (long "workers" <> metavar "N" <> help "备份盘 hash 并行度（默认 1，HDD 防寻道抖动）")))
  cleanP =
    fmap CmdClean $
      hsubparser
        (command "staging" (info goOpts (progDesc "仅清理「主库归档层 + 备份盘」都有同 sha 副本的暂存文件")))
  doctorP =
    CmdDoctor
      <$> ( DoctorOpts
              <$> switch (long "deep" <> help "全量重 hash 索引条目（慢，介质级验证）")
              <*> switch (long "repair" <> help "应用安全闭环：补记 Done / 清自建 tmp / 生成 C5 隔离计划")
          )
      <*> switch (long "backup" <> help "体检备份 root（需插盘）")
  trashP =
    CmdTrash
      <$> hsubparser
        ( command "list" (info (pure TrashList) (progDesc "manifest ∪ 盘面 并集视图"))
            <> command
              "empty"
              ( info
                  (TrashEmpty <$> switch (long "yes" <> help "确认清除下列条目（无此开关只列清单）"))
                  (progDesc "最终清除隔离区已登记条目（逐项列出）")
              )
        )
      <*> switch (long "backup" <> help "操作备份 root 的隔离区（需插盘）")
  undoP = CmdUndo <$> option auto (long "last" <> metavar "N" <> value 1 <> help "撤销最近 N 个已完成操作（默认 1；仅主库）")
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
        <*> optional
          ( strOption
              ( long "keep"
                  <> metavar "src|dst|both"
                  <> help "冲突裁决：src=以源替换（旧目标先隔离）；dst=保留目标跳过；both=源另起版本名并存"
              )
          )

run :: Cmd -> IO Int
run (CmdInit o) = runInit o
run (CmdScan o) = withCfg (runScanCmd o)
run (CmdStatus o) = withCfg (\cfg -> runStatus cfg o)
run (CmdDoctor o onBackup) = withCfg $ \cfg -> do
  eroot <- pickRoot cfg onBackup
  case eroot of
    Left (msg, code) -> putStrLn msg >> pure code
    Right root -> do
      (findings, code) <- runDoctor root o
      if null findings
        then putStrLn "✓ doctor: 无发现"
        else mapM_ (putStrLn . renderFinding) findings
      pure code
run (CmdTrash tc onBackup) = withCfg $ \cfg -> do
  eroot <- pickRoot cfg onBackup
  case eroot of
    Left (msg, code) -> putStrLn msg >> pure code
    Right root -> runTrash tc root
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
run (CmdImport go) = withCfg (runImport go)
run (CmdBackup (BackupInit p)) = withCfg (runBackupInit p)
run (CmdBackup (BackupRun go mworkers)) = withCfg (runBackupRun go mworkers)
run (CmdClean go) = withCfg (runClean go)

withCfg :: (Config -> IO Int) -> IO Int
withCfg act = do
  ecfg <- loadConfig
  case ecfg of
    Left e -> putStrLn e >> pure 2
    Right cfg -> act cfg

-- | 主库 root，或（--backup 时）经发现流程找到的备份 root。
pickRoot :: Config -> Bool -> IO (Either (String, Int) FilePath)
pickRoot cfg False = pure (Right (cfgMainPath cfg))
pickRoot cfg True = do
  er <- discoverBackupRoot cfg
  pure $ case er of
    Left msg -> Left (msg, 1)
    Right p -> Right p

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
          -- --force 重建时保留既有备份盘登记（那是 backup init 的产物）
          mold <- if exists then either (const Nothing) Just <$> loadConfig else pure Nothing
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
                    , cfgBackupId = maybe Nothing cfgBackupId mold
                    , cfgBackupSubpath = maybe Nothing cfgBackupSubpath mold
                    }
              putStrLn ("✓ 配置已写入 " <> fp)
              existing <- readRootInfo mainPath
              case existing of
                Just prior ->
                  putStrLn ("✓ 主库 root 标识已存在（沿用）: " <> T.unpack (riId prior))
                Nothing -> do
                  rid <- freshRootId
                  now <- getCurrentTime
                  fs <- case mainPath of
                    (c : _) -> volumeFsType c
                    _ -> pure Nothing
                  writeRootInfo mainPath (RootInfo rid RoleMain now fs)
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
      reportScanIssues result
      pure (if null (srVolatile result) && null (srErrors result) then 0 else 1)

reportScanIssues :: ScanResult -> IO ()
reportScanIssues result = do
  unless (null (srVolatile result)) $ do
    printf "⚠ %d 个文件在 hash 期间被修改（本轮未入索引，重跑 pm scan）:\n" (length (srVolatile result))
    mapM_ (putStrLn . ("    ~ " <>)) (take 10 (srVolatile result))
  unless (null (srErrors result)) $ do
    printf "⚠ %d 个条目有错误:\n" (length (srErrors result))
    mapM_ (\(p, e) -> putStrLn ("    ! " <> p <> ": " <> e)) (take 20 (srErrors result))
    when (length (srErrors result) > 20) $
      printf "    …另有 %d 条\n" (length (srErrors result) - 20)

runTrash :: TrashCmd -> FilePath -> IO Int
runTrash tc root = do
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

-- ─── 计划执行公共路径 ───────────────────────────────────────────────────────

-- | 执行一个计划并回写其 root 的 catalog。备份计划的 Copy Done 走 Barrier
-- （可移动介质，§9）。
executePlanNow :: Plan -> IO Int
executePlanNow plan = do
  let root = plRootPath plan
      env = defaultExecEnv {eeDoneSync = if plKind plan == "backup" then Barrier else Buffered}
  r <- execPlan env plan
  case r of
    Left e -> putStrLn e >> pure 2
    Right results -> do
      forM_ results $ \(it, out) ->
        printf "  %3d → %s\n" (piIx it) (outcomeLabel out)
      (mcat, _) <- loadCatalog root
      case mcat of
        Nothing -> putStrLn "（root 尚无索引，跳过 catalog 回写；之后 pm scan 会补齐）"
        Just cat -> do
          now <- getCurrentTime
          saveCatalog root (updateCatalog now results cat)
      let bad = [() | (_, out) <- results, isBad out]
      unless (null bad) $
        printf "⚠ %d 项 CONFLICT/FAILED（其余不受影响；详见上方逐项结果）\n" (length bad)
      pure (if null bad then 0 else 1)
 where
  isBad (OConflict _) = True
  isBad (OFailed _) = True
  isBad _ = False

confirm :: GoOpts -> IO Bool
confirm go
  | not (goApply go) = pure False
  | goYes go = pure True
  | otherwise = do
      putStr "执行以上计划? [y/N] "
      hFlush stdout
      l <- getLine
      pure (map toLower l `elem` ["y", "yes"])

-- | 大计划只展示头部，完整清单在计划文件里（pm apply --dry 可全量打印）。
renderPlanBrief :: Plan -> IO ()
renderPlanBrief plan = do
  let ls = renderPlan plan
      cap = 32
  if length ls <= cap + 1
    then mapM_ putStrLn ls
    else do
      mapM_ putStrLn (take (cap + 1) ls)
      printf "  …另有 %d 项（pm apply --dry %s 查看全量）\n" (length ls - cap - 1) (T.unpack (plId plan))

savePlanAndMaybeRun :: GoOpts -> Plan -> IO Int
savePlanAndMaybeRun go plan = do
  fp <- savePlan plan
  renderPlanBrief plan
  putStrLn ("计划已存 " <> fp)
  putStrLn ("执行: pm apply " <> T.unpack (plId plan))
  ok <- confirm go
  if ok then executePlanNow plan else pure 1

-- | 暂存区新鲜度守卫：计划按 catalog 生成，catalog 落后于盘面就先扫描 ——
-- 不让计划遗漏新文件或引用旧内容（执行层还有 §6.7 前提复核兜底）。
stagingFresh :: FilePath -> Catalog -> IO (Either String ())
stagingFresh root cat = do
  let stagingAbs = root </> stagingTop
  ex <- doesDirectoryExist stagingAbs
  (files, errs) <- if ex then listTree stagingAbs else pure ([], [])
  snaps <- forM files $ \rel -> do
    r <- try (statSnap (stagingAbs </> rel)) :: IO (Either SomeException StatSnap)
    pure (stagingTop </> rel, r)
  let disk = Map.fromList [(rel, s) | (rel, Right s) <- snaps]
      catStaging =
        Map.filterWithKey
          (\k _ -> take 1 (splitDirectories k) == [stagingTop])
          (catEntries cat)
      newN = Map.size (disk `Map.difference` catStaging)
      goneN = Map.size (catStaging `Map.difference` disk)
      changedN =
        length
          [ ()
          | (rel, s) <- Map.toList disk
          , Just e <- [Map.lookup rel catStaging]
          , enSize e /= ssSize s || enMtimeNs e /= ssMtimeNs s
          ]
  pure $
    if newN + goneN + changedN == 0 && null errs
      then Right ()
      else
        Left
          ( printf
              "暂存区与索引不一致（新增 %d / 变更 %d / 消失 %d / 读取错误 %d）→ 先 pm scan"
              newN
              changedN
              goneN
              (length errs)
          )

-- ─── pm import ──────────────────────────────────────────────────────────────

runImport :: GoOpts -> Config -> IO Int
runImport go cfg = do
  let root = cfgMainPath cfg
  (mcat, warns) <- loadCatalog root
  mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
  case mcat of
    Nothing -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
    Just cat -> do
      fr <- stagingFresh root cat
      case fr of
        Left msg -> putStrLn msg >> pure 2
        Right () -> do
          let rep = planImport cat
              items = importPlanItems root rep
              copyBytes = sum [enSize e | (e, _) <- irCopy rep]
          printf
            "归档: 拷贝 %d 文件 (%.1f GiB) · 已归档冗余 %d · 返修待裁决 %d · 待修改不碰 %d\n"
            (length (irCopy rep))
            (fromIntegral copyBytes / (1024 * 1024 * 1024 :: Double))
            (length (irAlready rep))
            (length (irRework rep))
            (length (irPendingEdit rep))
          forM_ (irRework rep) $ \(e, dst) ->
            putStrLn ("  ⚠ 返修: " <> enPath e <> " → " <> dst <> "（目标已存在且内容不同）")
          forM_ (irUnrecognized rep) $ \p ->
            putStrLn ("  ⚠ 无法识别的暂存布局（不猜，不入计划）: " <> p)
          forM_ (irDupTarget rep) $ \(s, d) ->
            putStrLn ("  ✗ 目标重复（整组拒绝）: " <> s <> " → " <> d)
          if null items
            then do
              putStrLn "✓ 暂存区无需归档"
              pure (if null (irUnrecognized rep) && null (irDupTarget rep) then 0 else 1)
            else do
              pid <- newPlanId
              now <- getCurrentTime
              savePlanAndMaybeRun go (Plan pid "import" root now items)

-- ─── pm backup ──────────────────────────────────────────────────────────────

runBackupInit :: FilePath -> Config -> IO Int
runBackupInit path cfg = do
  abs' <- makeAbsolute path
  let mainPath = cfgMainPath cfg
      isPrefix a b = splitDirectories a == take (length (splitDirectories a)) (splitDirectories b)
  if isPrefix mainPath abs' || isPrefix abs' mainPath
    then putStrLn ("备份路径与主库嵌套（" <> abs' <> " vs " <> mainPath <> "），拒绝") >> pure 2
    else do
      gitEx <- doesDirectoryExist (abs' </> ".git")
      if gitEx
        then putStrLn "该路径是 git 工作树（.pm 会污染工作区，I11），拒绝在此建备份 root" >> pure 2
        else do
          existing <- readRootInfo abs'
          case existing of
            Just info
              | riRole info == RoleBackup -> do
                  putStrLn ("✓ 该路径已是备份 root（沿用标识 " <> T.unpack (riId info) <> "）")
                  register abs' (riId info)
              | otherwise ->
                  putStrLn ("该路径已是 " <> show (riRole info) <> " root，拒绝改作备份") >> pure 2
            Nothing -> do
              ex <- doesDirectoryExist abs'
              unless ex $ putStrLn ("· 目录不存在，将创建: " <> abs')
              rid <- freshRootId
              now <- getCurrentTime
              fs <- case abs' of
                (c : _) -> volumeFsType c
                _ -> pure Nothing
              writeRootInfo abs' (RootInfo rid RoleBackup now fs)
              putStrLn ("✓ 备份 root 标识已创建: " <> T.unpack rid <> maybe "" (\t -> "（" <> T.unpack t <> "）") fs)
              register abs' rid
 where
  register abs' rid = do
    let sub = snd (splitDrive abs')
    _ <- writeConfig cfg {cfgBackupId = Just rid, cfgBackupSubpath = Just sub}
    putStrLn ("✓ 已登记到配置（盘符无关，按 UUID + 相对路径 " <> sub <> " 认盘）")
    putStrLn "下一步: pm backup"
    pure 0

runBackupRun :: GoOpts -> Maybe Int -> Config -> IO Int
runBackupRun go mworkers cfg = do
  eroot <- discoverBackupRoot cfg
  case eroot of
    Left msg -> putStrLn msg >> pure 1
    Right broot -> do
      minfo <- readRootInfo broot
      (mMain, _) <- loadCatalog (cfgMainPath cfg)
      case (minfo, mMain) of
        (Nothing, _) -> putStrLn "备份 root 标识读取失败（发现后被移除？）" >> pure 2
        (_, Nothing) -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
        (Just info, Just mainCat) -> do
          putStrLn ("备份盘: " <> broot <> maybe "" (\t -> "（" <> T.unpack t <> "）") (riFsType info))
          (oldBak, bwarns) <- loadCatalog broot
          mapM_ (\w -> putStrLn ("⚠ 备份快照损坏已跳过: " <> w)) bwarns
          let workers = fromMaybe 1 mworkers
          result <- scanRoot ScanOpts {soWorkers = workers, soProgress = True} oldBak (riId info) broot
          saveCatalog broot (srCatalog result)
          reportScanIssues result
          let bakCat = srCatalog result
              d = backupDiff mainCat bakCat
              addBytes = sum (map enSize (bdAdd d))
          printf
            "对比: 新增 %d (%.1f GiB) · 更新 %d · 一致 %d · EXTRA(备份盘多出，只读) %d\n"
            (length (bdAdd d))
            (fromIntegral addBytes / (1024 * 1024 * 1024 :: Double))
            (length (bdUpdate d))
            (bdSame d)
            (length (bdExtra d))
          forM_ (take 20 (bdExtra d)) $ \p -> putStrLn ("  EXTRA: " <> p)
          when (length (bdExtra d) > 20) $
            printf "  …另有 %d 项 EXTRA\n" (length (bdExtra d) - 20)
          refreshBackupCache cfg broot bakCat d
          let items = backupPlanItems (cfgMainPath cfg) d
          if null items
            then putStrLn "✓ 备份盘已与主库一致" >> pure 0
            else do
              unless (null (bdUpdate d)) $
                putStrLn "⚠ 更新项走 supersede 复合：备份盘旧字节先入备份盘自己的 .pm/trash，再落新字节（§6.5，不覆盖）"
              pid <- newPlanId
              now <- getCurrentTime
              code <- savePlanAndMaybeRun go (Plan pid "backup" broot now items)
              -- apply 之后备份 catalog 已被 executePlanNow 回写，缓存重算
              when (goApply go) $ do
                (mBak2, _) <- loadCatalog broot
                forM_ mBak2 $ \bak2 -> refreshBackupCache cfg broot bak2 (backupDiff mainCat bak2)
              pure code

refreshBackupCache :: Config -> FilePath -> Catalog -> BackupDiff -> IO ()
refreshBackupCache cfg broot bakCat d = do
  now <- getCurrentTime
  fs <- case broot of
    (c : _) -> volumeFsType c
    _ -> pure Nothing
  writeBackupCache
    (cfgMainPath cfg)
    bakCat
    BackupCacheMeta
      { bmAt = now
      , bmPath = broot
      , bmFsType = fs
      , bmAdd = length (bdAdd d)
      , bmUpdate = length (bdUpdate d)
      , bmExtra = length (bdExtra d)
      }

-- ─── pm clean staging ───────────────────────────────────────────────────────

runClean :: GoOpts -> Config -> IO Int
runClean go cfg = do
  let root = cfgMainPath cfg
  (mcat, _) <- loadCatalog root
  case mcat of
    Nothing -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
    Just cat -> do
      fr <- stagingFresh root cat
      case fr of
        Left msg -> putStrLn msg >> pure 2
        Right () -> do
          er <- discoverBackupRoot cfg
          case er of
            Left msg -> putStrLn ("无法确认第三副本，不生成任何清理项: " <> msg) >> pure 1
            Right broot -> do
              (mbak, _) <- loadCatalog broot
              case mbak of
                Nothing -> putStrLn "备份盘尚无索引 → 先 pm backup" >> pure 2
                Just bakCat -> do
                  let rep = planClean cat bakCat
                  (verified, demoted) <- verifyCandidates root broot (clEligible rep)
                  let held = clHeld rep <> demoted
                  printf
                    "清理: 三副本已确认 %d · HELD %d · 待修改不碰 %d\n"
                    (length verified)
                    (length held)
                    (length (clPendingEdit rep))
                  forM_ held $ \(p, why) -> putStrLn ("  " <> why <> " " <> p)
                  let items = cleanPlanItems verified
                  if null items
                    then do
                      putStrLn "无可清理项"
                      pure (if null held then 0 else 1)
                    else do
                      pid <- newPlanId
                      now <- getCurrentTime
                      savePlanAndMaybeRun go (Plan pid "clean-staging" root now items)

-- ─── pm apply / resolve ─────────────────────────────────────────────────────

-- | 计划可能存在主库或备份 root 的 .pm/plans 下；先主库，找不到再试备份盘。
loadPlanAnyRoot :: Config -> T.Text -> IO (Either String Plan)
loadPlanAnyRoot cfg pid = do
  r <- loadPlan (cfgMainPath cfg) pid
  case r of
    Right p -> pure (Right p)
    Left mainErr -> do
      eb <- discoverBackupRoot cfg
      case eb of
        Left _ -> pure (Left mainErr)
        Right broot -> do
          rb <- loadPlan broot pid
          pure $ case rb of
            Right p -> Right p
            Left _ -> Left (mainErr <> "（备份 root 也没有）")

runApply :: ApplyOpts -> Config -> IO Int
runApply o cfg = do
  ep <- loadPlanAnyRoot cfg (aoId o)
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
              code <- executePlanNow plan
              when (plKind plan == "backup") $ do
                (mMain, _) <- loadCatalog (cfgMainPath cfg)
                (mBak, _) <- loadCatalog (plRootPath plan)
                case (mMain, mBak) of
                  (Just mc, Just bc) -> refreshBackupCache cfg (plRootPath plan) bc (backupDiff mc bc)
                  _ -> pure ()
              pure code

runResolve :: ResolveOpts -> Config -> IO Int
runResolve o cfg = do
  ep <- loadPlanAnyRoot cfg (roId o)
  case ep of
    Left e -> putStrLn e >> pure 2
    Right plan -> do
      let hit = [it | it <- plItems plan, piIx it == roItem o]
      case (hit, roKeep o) of
        ([], _) -> putStrLn ("计划中无条目 " <> show (roItem o)) >> pure 2
        ([item], Just keep) -> resolveKeep plan item keep
        ([_], Nothing) -> do
          let newStatus = if roSkip o then StSkippedByUser else StPending
              plan' = replaceItem plan (roItem o) (\it -> it {piStatus = newStatus})
          _ <- savePlan plan'
          mapM_ putStrLn (renderPlan plan')
          pure 0
        _ -> putStrLn "计划条目序号重复（计划文件损坏？）" >> pure 2

replaceItem :: Plan -> Int -> (PlanItem -> PlanItem) -> Plan
replaceItem plan ix f =
  plan {plItems = [if piIx it == ix then f it else it | it <- plItems plan]}

-- | --keep 裁决（DESIGN.md §5 resolve）。只对 Copy 冲突有意义：
--   src  = 旧目标先隔离、再落源（§6.5 supersede，追加为两个新条目）
--   dst  = 保留目标，原条目跳过
--   both = 源改用不冲突的版本名（-v2/-v3…）落位，两者并存
resolveKeep :: Plan -> PlanItem -> String -> IO Int
resolveKeep plan item keep = case (piOp item, keep) of
  (OpCopy {}, "dst") -> do
    let plan' = replaceItem plan (piIx item) (\it -> it {piStatus = StSkippedByUser})
    _ <- savePlan plan'
    mapM_ putStrLn (renderPlan plan')
    putStrLn "✓ 保留现有目标，该项跳过"
    pure 0
  (op@OpCopy {}, "src") -> do
    let root = plRootPath plan
        dstAbs = root </> opDstRel op
    dstEx <- doesFileExist dstAbs
    if not dstEx
      then do
        -- 冲突已自行消失（目标被移走）：恢复原条目即可
        let plan' = replaceItem plan (piIx item) (\it -> it {piStatus = StPending})
        _ <- savePlan plan'
        putStrLn "目标已不存在，冲突消失；该项恢复为待执行"
        pure 0
      else do
        dsha <- sha256File dstAbs
        let maxIx = maximum (0 : map piIx (plItems plan))
            quarantine =
              PlanItem
                (maxIx + 1)
                OpQuarantine
                  { opVictimRel = opDstRel op
                  , opVictimSha = dsha
                  , opReason = T.pack ("supersede:resolve-keep-src(item " <> show (piIx item) <> ")")
                  }
                StPending
            copy = PlanItem (maxIx + 2) op StPending
            base = replaceItem plan (piIx item) (\it -> it {piStatus = StSkippedByUser})
            plan' = base {plItems = plItems base <> [quarantine, copy]}
        _ <- savePlan plan'
        mapM_ putStrLn (renderPlan plan')
        putStrLn "✓ 已改写为 supersede：旧目标先隔离（可从 trash 还原），再落源"
        pure 0
  (op@OpCopy {}, "both") -> do
    let root = plRootPath plan
        takenInPlan = [opDstRel (piOp it) | it <- plItems plan, isCopy (piOp it)]
        isCopy OpCopy {} = True
        isCopy _ = False
    newDst <- freeVersionName root takenInPlan (opDstRel op)
    let plan' =
          replaceItem
            plan
            (piIx item)
            (\it -> it {piOp = op {opDstRel = newDst}, piStatus = StPending})
    _ <- savePlan plan'
    mapM_ putStrLn (renderPlan plan')
    putStrLn ("✓ 源将以新名并存落位: " <> newDst)
    pure 0
  (_, k) | k `notElem` ["src", "dst", "both"] ->
    putStrLn ("--keep 只接受 src|dst|both，收到: " <> k) >> pure 2
  _ -> putStrLn "--keep 只适用于 Copy 冲突条目" >> pure 2

-- | \"a\\b.jpg\" → 第一个既不在盘上也不在本计划目标集合里的 \"a\\b-vN.jpg\"。
freeVersionName :: FilePath -> [FilePath] -> FilePath -> IO FilePath
freeVersionName root taken dstRel = go (2 :: Int)
 where
  (stem, ext) = splitExtension dstRel
  go n = do
    let cand = stem <> "-v" <> show n <> ext
    ex <- doesFileExist (root </> cand)
    if ex || cand `elem` taken then go (n + 1) else pure cand

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
