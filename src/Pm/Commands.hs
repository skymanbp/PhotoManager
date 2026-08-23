{-# LANGUAGE OverloadedStrings #-}

-- | Command orchestration (split out of app\/Main.hs; the exe is parsing +
-- dispatch only). Everything here is glue: planners are pure modules, all
-- mutation flows through Pm.Cli.executePlanNow → Pm.Exec.
module Pm.Commands
  ( InitOpts (..)
  , ScanCmd (..)
  , TrashCmd (..)
  , ApplyOpts (..)
  , ResolveOpts (..)
  , BackupCmd (..)
  , withCfg
  , pickRoot
  , runInit
  , runScanCmd
  , runTrash
  , runUndoCmd
  , runApply
  , runResolve
  , resolveKeep
  , runImport
  , runBackupInit
  , runBackupRun
  , runClean
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toLower)
import Data.Function (on)
import Data.List (isPrefixOf, nubBy)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, makeAbsolute, removeFile)
import System.FilePath (normalise, splitDirectories, splitDrive, splitExtension, (</>))
import Text.Printf (printf)

import Pm.Backup
import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Clean
import Pm.Cli
import Pm.Config
import Pm.Diff
import Pm.Hash (sha256File)
import Pm.Import
import Pm.Op
import Pm.Plan
import Pm.Scan
import Pm.Trash
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Win (volumeFsType)

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

data BackupCmd
  = BackupInit FilePath
  | BackupRun GoOpts (Maybe Int)

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

-- ─── init / scan ────────────────────────────────────────────────────────────

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

-- ─── trash ──────────────────────────────────────────────────────────────────

runTrash :: Config -> TrashCmd -> FilePath -> IO Int
runTrash cfg tc root = do
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
              -- 「已移出」= 被 purge 或被复位/undo 移回原位（文件不在 trash）
              (if present then "在库" :: String else "已移出")
              (trTrashRel r)
              (trVictimRel r)
              (T.unpack (trReason r))
              (T.unpack (trPlanId r))
          forM_ (tvUnregistered tv) $ \f ->
            putStrLn ("  UNREGISTERED " <> f <> "  （无 manifest 记录，先跑 pm doctor）")
      pure 0
    TrashEmpty yes -> do
      let present = [(r, trashDir root </> trTrashRel r) | (r, True) <- tvRegistered tv]
      -- 评审 cx-3 终极屏障：clean-staging 隔离条目是「三副本确认」清出来的
      -- 暂存副本——永久删除前按当前 catalog + 真实重 hash 再确认归档层与
      -- 备份盘各存一份；确认不了就 HELD，绝不删可能是最后一份的字节。
      let (cleanRecs, plainRecs) = span' (\(r, _) -> "clean-staging" `T.isPrefixOf` trReason r) present
      (purgeableClean, heldClean) <-
        if null cleanRecs
          then pure ([], [])
          else do
            mMain <- fst <$> loadCatalog (cfgMainPath cfg)
            er <- discoverBackupRoot cfg
            case (mMain, er) of
              (Just mainCat, Right broot) -> do
                mBak <- fst <$> loadCatalog broot
                case mBak of
                  Nothing -> pure ([], [(r, "备份盘无索引") | (r, _) <- cleanRecs])
                  Just bakCat -> do
                    judged <- forM cleanRecs $ \rec@(r, _) -> do
                      ok <- threeCopiesStillExist (cfgMainPath cfg) mainCat broot bakCat (trSha r)
                      pure (rec, ok)
                    pure
                      ( [rec | (rec, True) <- judged]
                      , [(r, "三副本复验不过") | ((r, _), False) <- judged]
                      )
              (Nothing, _) -> pure ([], [(r, "主库无索引") | (r, _) <- cleanRecs])
              (_, Left msg) -> pure ([], [(r, "备份盘不在线: " <> msg) | (r, _) <- cleanRecs])
      forM_ heldClean $ \(r, why) ->
        putStrLn ("  HELD(不删) " <> trTrashRel r <> " —— " <> why)
      -- P2.2（复审新发现）：同计划复位后重跑会为同一 trashRel 追加第二条
      -- manifest 记录（append-only 历史）——按 trashRel 去重，一个文件只
      -- unlink 一次，避免第二次 removeFile 因文件已不存在而炸掉整个批次。
      let purgeable = nubBy ((==) `on` (trTrashRel . fst)) (plainRecs <> purgeableClean)
      if null purgeable
        then putStrLn "隔离区没有可清除的已登记条目" >> pure (if null heldClean then 0 else 1)
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
 where
  span' p xs = (filter p xs, filter (not . p) xs)

-- ─── undo / apply / resolve ─────────────────────────────────────────────────

runUndoCmd :: Int -> Config -> IO Int
runUndoCmd n cfg = do
  r <- buildUndoPlan (cfgMainPath cfg) n
  case r of
    Left e -> putStrLn e >> pure 2
    Right plan -> do
      fp <- savePlan plan
      mapM_ putStrLn (renderPlan plan)
      putStrLn ("计划已存 " <> fp)
      putStrLn ("执行: pm apply " <> T.unpack (plId plan))
      pure 0

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
    Right plan0 -> case plRootId plan0 of
      Nothing -> do
        putStrLn "计划缺 root 标识（P2.1 之前的旧格式）→ 重新生成计划后再执行（评审 cx-1）"
        pure 2
      Just rid -> do
        ebound <- bindExecRoot cfg plan0 rid
        case ebound of
          Left e -> putStrLn e >> pure 2
          Right plan1 -> case applyOnlyToPlan (aoOnly o) plan1 of
            Left e -> putStrLn e >> pure 2
            Right (plan2, added) -> do
              unless (null added) $
                putStrLn ("· --only 已扩到复合组（不可拆），追加条目: " <> show added)
              mapM_ putStrLn (renderPlan plan2)
              if aoDry o
                then pure 0
                else do
                  plan3 <-
                    if plKind plan2 == "clean-staging"
                      then recheckCleanPlan cfg plan2
                      else pure plan2
                  code <- executePlanNow plan3
                  when (plKind plan3 == "backup") $ do
                    (mMain, _) <- loadCatalog (cfgMainPath cfg)
                    (mBak, _) <- loadCatalog (plRootPath plan3)
                    case (mMain, mBak) of
                      (Just mc, Just bc) ->
                        refreshBackupCache cfg (plRootPath plan3) bc (backupDiff mc bc)
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
          -- skip/unskip 扩到复合组（评审 cx-2：组是最小裁决单元）
          let ixs = groupClosure plan [roItem o]
              newStatus = if roSkip o then StSkippedByUser else StPending
              plan' =
                plan
                  { plItems =
                      [ if piIx it `elem` ixs then it {piStatus = newStatus} else it
                      | it <- plItems plan
                      ]
                  }
          when (length ixs > 1) $
            putStrLn ("· 条目属复合组，操作扩到全组: " <> show ixs)
          _ <- savePlan plan'
          mapM_ putStrLn (renderPlan plan')
          pure 0
        _ -> putStrLn "计划条目序号重复（计划文件损坏？）" >> pure 2

replaceItem :: Plan -> Int -> (PlanItem -> PlanItem) -> Plan
replaceItem plan ix f =
  plan {plItems = [if piIx it == ix then f it else it | it <- plItems plan]}

-- | --keep 裁决（DESIGN.md §5 resolve）。评审 cx-4：只接受**独立的**
-- NEEDS-DECISION Copy 条目——复合组成员不可单独裁决（组是不可拆分单元），
-- 非待裁决条目无冲突可裁。
--   src  = 旧目标先隔离、再落源（§6.5 supersede，追加为同组两个新条目）
--   dst  = 保留目标，原条目跳过
--   both = 源改用不冲突的版本名（-v2/-v3…）落位，两者并存
resolveKeep :: Plan -> PlanItem -> String -> IO Int
resolveKeep plan item keep
  | keep `notElem` ["src", "dst", "both"] =
      putStrLn ("--keep 只接受 src|dst|both，收到: " <> keep) >> pure 2
  | Just _ <- piGroup item =
      putStrLn "--keep 不能作用于复合组条目（组不可拆分；用 resolve --item N 跳过整组或重新生成计划）" >> pure 2
  | not (isNeedsDecision (piStatus item)) =
      putStrLn "--keep 只用于 NEEDS-DECISION 冲突条目（该条目不是待裁决状态）" >> pure 2
  | otherwise = case (piOp item, keep) of
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
                newG = Just (1 + maximum (0 : [g | it <- plItems plan, Just g <- [piGroup it]]))
                quarantine =
                  PlanItem
                    (maxIx + 1)
                    OpQuarantine
                      { opVictimRel = opDstRel op
                      , opVictimSha = dsha
                      , opReason = T.pack ("supersede:resolve-keep-src(item " <> show (piIx item) <> ")")
                      }
                    StPending
                    newG
                copy = PlanItem (maxIx + 2) op StPending newG
                base = replaceItem plan (piIx item) (\it -> it {piStatus = StSkippedByUser})
                plan' = base {plItems = plItems base <> [quarantine, copy]}
            _ <- savePlan plan'
            mapM_ putStrLn (renderPlan plan')
            putStrLn "✓ 已改写为 supersede（同组不可拆）：旧目标先隔离（可从 trash 还原），再落源"
            pure 0
      (op@OpCopy {}, "both") -> do
        let root = plRootPath plan
            taken = [opDstRel (piOp it) | it <- plItems plan, isCopy (piOp it)]
            isCopy OpCopy {} = True
            isCopy _ = False
        newDst <- freeVersionName root taken (opDstRel op)
        let plan' =
              replaceItem
                plan
                (piIx item)
                (\it -> it {piOp = op {opDstRel = newDst}, piStatus = StPending})
        _ <- savePlan plan'
        mapM_ putStrLn (renderPlan plan')
        putStrLn ("✓ 源将以新名并存落位: " <> newDst)
        pure 0
      _ -> putStrLn "--keep 只适用于 Copy 冲突条目" >> pure 2
 where
  isNeedsDecision (StNeedsDecision _) = True
  isNeedsDecision _ = False

-- | \"a\\b.jpg\" → 第一个既不在盘上、也不在本计划目标集合（case-fold 比较，
-- 评审 mj-2 同源）里的 \"a\\b-vN.jpg\"。
freeVersionName :: FilePath -> [FilePath] -> FilePath -> IO FilePath
freeVersionName root taken dstRel = go (2 :: Int)
 where
  (stem, ext) = splitExtension dstRel
  takenFold = map (map toLower) taken
  go n = do
    let cand = stem <> "-v" <> show n <> ext
    ex <- doesFileExist (root </> cand)
    if ex || map toLower cand `elem` takenFold then go (n + 1) else pure cand

-- ─── import ─────────────────────────────────────────────────────────────────

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
            putStrLn ("  ✗ 目标重复（连同侧车整组拒绝）: " <> s <> " → " <> d)
          if null items
            then do
              putStrLn "✓ 暂存区无需归档"
              pure (if null (irUnrecognized rep) && null (irDupTarget rep) then 0 else 1)
            else do
              minfo <- readRootInfo root
              case minfo of
                -- P2.2 fail-closed（复审 cx-1 残留）：root 无身份就不出计划，
                -- 而不是造一个 rootId=Nothing 的计划再依赖下游拒绝。
                Nothing -> putStrLn ("主库缺 .pm/root-id.json → 先 pm init --main " <> root) >> pure 2
                Just info -> do
                  pid <- newPlanId
                  now <- getCurrentTime
                  savePlanAndMaybeRun
                    go
                    Plan
                      { plId = pid
                      , plKind = "import"
                      , plRootPath = root
                      , plRootId = Just (riId info)
                      , plCreated = now
                      , plItems = items
                      }

-- ─── backup ─────────────────────────────────────────────────────────────────

runBackupInit :: FilePath -> Config -> IO Int
runBackupInit path cfg = do
  -- 评审 mj-4（P2.2 收紧）：canonicalizePath 解析已存在前缀的 junction/
  -- symlink 与真实大小写，再按 case-fold 组件做祖先判断——文本级
  -- normalise 挡不住主库别名路径（如经 junction 指向主库）。
  abs' <- canonicalizePath =<< makeAbsolute path
  mainC <- canonicalizePath (cfgMainPath cfg)
  let canonParts p = map (map toLower) (splitDirectories (normalise p))
      nested a b = canonParts a `isPrefixOf` canonParts b
  if nested mainC abs' || nested abs' mainC
    then putStrLn ("备份路径与主库嵌套（" <> abs' <> " vs " <> mainC <> "），拒绝") >> pure 2
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
              -- P2.3（mj-4 残余缓解）：写身份文件前把路径再 canonicalize
              -- 复验一次，检查期与写入期之间被换成 junction 的窗口收敛到
              -- 近零（单机模型下的剩余风险已在评审归档记录）。
              abs2 <- canonicalizePath abs'
              if map toLower (normalise abs2) /= map toLower (normalise abs')
                then putStrLn ("路径在检查后发生变化（" <> abs' <> " → " <> abs2 <> "），拒绝") >> pure 2
                else do
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
        -- P2.3（复审三轮新发现）：发现后重读到的身份必须仍等于**配置登记的**
        -- UUID——不采纳盘上任意 id（发现与使用之间路径/卷可能被换）。
        (Just info, _)
          | cfgBackupId cfg /= Just (riId info) ->
              putStrLn "备份 root 身份在发现后发生变化（与配置登记不符），拒绝" >> pure 2
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
                putStrLn "⚠ 更新项 = supersede 复合组（不可拆）：备份盘旧字节先入其 .pm/trash，再落新字节；组内失败自动复位（§6.5）"
              pid <- newPlanId
              now <- getCurrentTime
              code <-
                savePlanAndMaybeRun
                  go
                  Plan
                    { plId = pid
                    , plKind = "backup"
                    , plRootPath = broot
                    , plRootId = Just (riId info)
                    , plCreated = now
                    , plItems = items
                    }
              -- apply 之后备份 catalog 已被 executePlanNow 回写，缓存重算
              when (goApply go) $ do
                (mBak2, _) <- loadCatalog broot
                forM_ mBak2 $ \bak2 -> refreshBackupCache cfg broot bak2 (backupDiff mainCat bak2)
              pure code

-- ─── clean staging ──────────────────────────────────────────────────────────

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
                    "清理: 三副本已确认(真实重hash) %d · HELD %d · 待修改不碰 %d\n"
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
                      minfo <- readRootInfo root
                      case minfo of
                        -- P2.2 fail-closed（复审 cx-1 残留）：同 runImport。
                        Nothing -> putStrLn ("主库缺 .pm/root-id.json → 先 pm init --main " <> root) >> pure 2
                        Just info -> do
                          pid <- newPlanId
                          now <- getCurrentTime
                          -- P2.2（复审 cx-3 旁路封堵）：--apply 即时路径同样在
                          -- 确认后、执行前重验三副本，与 pm apply 无差别。
                          savePlanAndMaybeRunWith
                            (recheckCleanPlan cfg)
                            go
                            Plan
                              { plId = pid
                              , plKind = "clean-staging"
                              , plRootPath = root
                              , plRootId = Just (riId info)
                              , plCreated = now
                              , plItems = items
                              }
