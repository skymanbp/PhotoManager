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
  , RootSel (..)
  , rootSel
  , withCfg
  , pickRoot
  , runInit
  , initPreflight
  , runScanCmd
  , runTrash
  , runUndoCmd
  , runApply
  , prepareApply
  , afterApply
  , loadPlanAnyRoot
  , runResolve
  , resolveKeep
  , runImport
  , runBackupInit
  , backupInitPreflight
  , runBackupRun
  , runClean
  , runDedupe
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toLower)
import Data.Function (on)
import Data.List (nubBy)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute, removeFile)
import System.FilePath (splitExtension, (</>))
import Text.Printf (printf)

import Pm.Backup
import Pm.BackupCmd (BackupCmd (..), backupInitPreflight, runBackupInit, runBackupRun)
import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Clean
import Pm.Cli
import Pm.Dedupe
import Pm.Config
import Pm.Diff
import Pm.GitGuard (pmIgnoreGuard)
import Pm.Hash (ContentProbe (..), probeConfined, sha256File)
import Pm.Import
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Scan
import Pm.Trash
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Vault (computeVault, gitStepsLines, planCategories)
import Pm.Win (resolveUnder, volumeFsType)

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

-- 备份命令（BackupCmd / runBackupInit / runBackupRun）在 Pm.BackupCmd，
-- 此处再导出（P3b-6 拆分：本文件触及 750 行预算）。

withCfg :: (Config -> IO Int) -> IO Int
withCfg act = do
  ecfg <- loadConfig
  case ecfg of
    Left e -> putStrLn e >> pure 2
    Right cfg -> act cfg

-- | doctor\/trash\/undo 的作用 root：主库（默认）、备份盘（UUID 发现流程）
-- 或 vault（P3b：固定路径 + role 校验，root 由首次 vault push 建立）。
data RootSel = SelMain | SelBackup | SelVault
  deriving (Show, Eq)

rootSel :: Bool -> Bool -> Either String RootSel
rootSel True True = Left "--backup 与 --vault 只能二选一"
rootSel True False = Right SelBackup
rootSel False True = Right SelVault
rootSel False False = Right SelMain

pickRoot :: Config -> RootSel -> IO (Either (String, Int) FilePath)
pickRoot cfg SelMain = do
  -- P3b-6 复审 B1：doctor --repair / trash empty / undo 默认作用于主库，
  -- 配置路径指向备份/vault root 时不得放行（与 scan/import 同一 requireMain；
  -- P3b-7 起 requireRole 内含 I11 守卫，三个槽位一视同仁）。
  em <- requireMain cfg
  pure (either (\m -> Left (m, 2)) (const (Right (cfgMainPath cfg))) em)
pickRoot cfg SelBackup = do
  er <- discoverBackupRoot cfg
  case er of
    Left msg -> pure (Left (msg, 1))
    Right p -> do
      rr <- requireRole RoleBackup p
      pure (either (\m -> Left (m, 2)) (const (Right p)) rr)
pickRoot cfg SelVault = case cfgVaultPath cfg of
  Nothing -> pure (Left ("配置无 vault 路径 → pm init --main <主库> --vault <展示集路径>", 2))
  Just vp -> do
    st <- readRootState vp
    case st of
      RootAbsent -> pure (Left ("vault root 尚未建立（首次 pm vault push 时按 I11 创建）", 2))
      _ -> do
        rr <- requireRole RoleVault vp
        pure (either (\m -> Left (m, 2)) (const (Right vp)) rr)

-- ─── init / scan ────────────────────────────────────────────────────────────

-- | pm init 写任何东西（配置、root 标识）之前的守卫（P3b-6 复审 major）：
-- ①主库若处于 git 工作树内须已忽略 `.pm/`——I11 对所有 role 生效，不只
-- vault；②路径上已有非 RoleMain 的 root 标识（备份盘\/vault 被误配成主库）
-- → 拒绝，`--force` 也不覆盖 root 身份。
initPreflight :: FilePath -> IO (Either String ())
initPreflight mainPath = do
  g <- pmIgnoreGuard RoleMain mainPath
  case g of
    Left m -> pure (Left m)
    Right () -> do
      -- P3b-7 复审 major：损坏的标识不是「缺席」——拒绝，不改写
      st <- readRootState mainPath
      pure $ case st of
        RootPresent prior
          | riRole prior /= RoleMain ->
              Left (mainPath <> " 已是 " <> show (riRole prior) <> " root，拒绝作为主库初始化（--force 亦不改写 root 身份）")
        RootCorrupt e ->
          Left (mainPath <> " 的 .pm/root-id.json 存在但无法解析（" <> e <> "），拒绝初始化——人工核查；pm 不改写它")
        -- P3b-12（九轮复审 major）：显式列出不可信态。这里原本是 catch-all
        -- `_ -> Right ()`，穷尽性检查看不见它，新增的 RootUntrusted 就被静静
        -- 放行了——预检的语义必须与 runInit 的判定一致。
        RootUntrusted m -> Left m
        _ -> Right ()

runInit :: InitOpts -> IO Int
runInit o = do
  mainPath <- makeAbsolute (ioMain o)
  okMain <- doesDirectoryExist mainPath
  pre <-
    if okMain
      then initPreflight mainPath
      else pure (Left ("主库路径不存在: " <> mainPath))
  case pre of
    Left msg -> putStrLn msg >> pure 2
    Right () -> do
      cfgFp <- configFilePath
      -- 三十轮 F3：init 的「查存在 → 读旧配置(mold) → 写回」是配置的第四条
      -- 读改写路径，此前唯独它没进 withConfigLock——A 在锁外读到旧配置，B 在
      -- 锁内登记备份盘，A 再无锁写回，登记被静默抹掉。整段进配置锁、锁内
      -- 重读；root 标识的创建不动配置文件，留在锁外（initMarker）。
      mw <- withConfigLock $ do
        exists <- doesFileExist cfgFp
        if exists && not (ioForce o)
          then pure (Left ("配置已存在: " <> cfgFp <> "（--force 覆盖）"))
          else do
            -- --force 重建时保留既有备份盘登记（那是 backup init 的产物）
            mold <- if exists then either (const Nothing) Just <$> loadConfig else pure Nothing
            vaultOk <- mapM doesDirectoryExist (ioVault o)
            case (ioVault o, vaultOk) of
              (Just vp, Just False) -> pure (Left ("vault 路径不存在: " <> vp))
              _ ->
                Right
                  <$> writeConfig
                    Config
                      { cfgMainPath = mainPath
                      , cfgVaultPath = ioVault o
                      , cfgPhotosJson = ioPhotosJson o
                      , cfgWorkers = ioWorkers o
                      , cfgBackupId = maybe Nothing cfgBackupId mold
                      , cfgBackupSubpath = maybe Nothing cfgBackupSubpath mold
                      }
      case mw of
        Nothing -> putStrLn "另一个 pm 正在改配置（config.lock 被持有），初始化未写入，稍后重试" >> pure 2
        Just (Left msg) -> putStrLn msg >> pure 2
        Just (Right fp) -> putStrLn ("✓ 配置已写入 " <> fp) >> initMarker o mainPath

-- | init 的第二段：主库 root 标识。不动配置文件，在配置锁外。
initMarker :: InitOpts -> FilePath -> IO Int
initMarker o mainPath = do
  st <- readRootState mainPath
  emarker <- case st of
    RootPresent prior -> do
      putStrLn ("✓ 主库 root 标识已存在（沿用）: " <> T.unpack (riId prior))
      pure (Right ())
    RootCorrupt e ->
      pure (Left (mainPath <> " 的 .pm/root-id.json 在预检后变为不可解析（" <> e <> "），不改写"))
    -- P3b-12（九轮复审 major）：pm init 建立身份，走不了
    -- requireWritable —— .pm 若是 junction，标识会写到库外。
    RootUntrusted m -> pure (Left m)
    RootAbsent -> do
      rid <- freshRootId
      now <- getCurrentTime
      fs <- case mainPath of
        (c : _) -> volumeFsType c
        _ -> pure Nothing
      -- 原子 no-replace（P3b-7）：预检与此刻之间有人放了文件 → 拒绝
      er <- createRootInfo mainPath (RootInfo rid RoleMain now fs)
      forM_ er $ \() -> putStrLn ("✓ 主库 root 标识已创建: " <> T.unpack rid)
      pure er
  case emarker of
    Left m -> putStrLn m >> pure 2
    Right () -> do
      -- vault root 标识在 P3 建（vault 是 git 工作树，I11 要求先走
      -- .gitignore 确认流程），此处只登记路径。
      forM_ (ioVault o) $ \vp ->
        putStrLn ("· vault 路径已登记（root 标识 P3 经确认后创建）: " <> vp)
      putStrLn "下一步: pm scan"
      pure 0

runScanCmd :: ScanCmd -> Config -> IO Int
runScanCmd sc cfg = do
  let root = cfgMainPath cfg
  -- P3b-5 复审 B1：主库路径必须是 RoleMain root（指向备份/vault 会改错库）
  er <- requireRole RoleMain root
  case er of
    Left msg -> putStrLn msg >> pure 2
    Right rootInfo -> do
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
  -- P3b-11（八轮复审 critical）：manifest 与隔离文件都住在 .pm/trash 里，
  -- 而这条命令是 pm 全程唯一 unlink 用户数据的入口。基准被 junction 劫持时
  -- 连**读**都不该读——否则 trash list 列的是库外目录的内容，trash empty
  -- 还会把"隔离区为空"这种安静的假象报给用户。同 P3b-8 的纪律：身份/可信性
  -- 校验先于任何读取。
  tr <- requirePmTrusted root
  case tr of
    Left m -> putStrLn ("✗ " <> m) >> pure 1
    Right () -> runTrash' cfg tc root

runTrash' :: Config -> TrashCmd -> FilePath -> IO Int
runTrash' cfg tc root = case tc of
    -- list 是只读咨询（同 pm status），不取锁；empty 的视图在锁内取（见下）。
    TrashList -> do
      tv <- trashView root
      mapM_ (\w -> putStrLn ("✗ manifest 损坏行: " <> w)) (tvWarnings tv)
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
    -- 二十九轮 critical 的同根第二处（rule 09 统一修复）：屏障判据与 unlink
    -- 必须是**一个跨进程事务**。这是 pm 全程唯一 unlink 用户数据的路径，此前
    -- 全程不取锁——purgeBarriers 读盘判「归档层还留着一份」与 removeFile 之间，
    -- 另一个 pm 进程完全可以把那一份也隔离掉。--yes 是命令行开关而非交互提问，
    -- 锁内不会停下来等人，所以**整段——从读 manifest 视图起**——都在锁里跑
    -- （三十轮 F1：视图也是证据，锁外取的视图会把另一个 pm 刚清掉/复位的
    -- 条目当成还在，走到 removeFile 才炸）。取不到锁 = 另一个 pm 正在动
    -- 这个 root，直接退出而不是硬来。
    TrashEmpty yes -> do
      ml <- withRootLock root (trashEmptyLocked cfg root yes)
      case ml of
        Nothing -> do
          putStrLn "另一个 pm 实例正持有该 root 的锁（I10），未清除任何条目，稍后重试"
          pure 2
        Just code -> pure code

-- | @pm trash empty@ 的锁内主体：屏障复验 → 限域判定 → 列表 → unlink。
-- 拆出来只是为了让整段显式地位于 'withRootLock' 之内（见调用点注释）。
trashEmptyLocked :: Config -> FilePath -> Bool -> IO Int
trashEmptyLocked cfg root yes = do
      tv <- trashView root
      mapM_ (\w -> putStrLn ("✗ manifest 损坏行: " <> w)) (tvWarnings tv)
      let present = [(r, trashDir root </> trTrashRel r) | (r, True) <- tvRegistered tv]
      -- 隔离记录按 reason 前缀分流到各自的**永久删除前屏障**（评审 cx-3 终极
      -- 屏障的一般化）。前缀由写入方定（'Pm.Clean.cleanPlanItems' /
      -- 'Pm.Dedupe.dedupePlanItems'），这里是唯一消费点：加一类受屏障保护的
      -- 隔离 = 在 barrierOf 里加一行，而不是再抄一段 span'。无屏障的记录
      -- （supersede 的旧字节、返修裁决…）由生成它的计划负责交代，永久删除
      -- 仍需用户逐项确认。
      let barrierOf r
            | "clean-staging" `T.isPrefixOf` trReason r = Just BThreeCopies
            | dedupeReasonPrefix `T.isPrefixOf` trReason r = Just BArchiveCopyLeft
            | otherwise = Nothing
          guarded = [(b, x) | x@(r, _) <- present, Just b <- [barrierOf r]]
          plainRecs = [x | x@(r, _) <- present, barrierOf r == Nothing]
      (purgeableGuarded, heldGuarded) <- purgeBarriers cfg guarded
      forM_ heldGuarded $ \(r, why) ->
        putStrLn ("  HELD(不删) " <> trTrashRel r <> " —— " <> why)
      -- P2.2（复审新发现）：同计划复位后重跑会为同一 trashRel 追加第二条
      -- manifest 记录（append-only 历史）——按 trashRel 去重，一个文件只
      -- unlink 一次，避免第二次 removeFile 因文件已不存在而炸掉整个批次。
      let candidates = nubBy ((==) `on` (trTrashRel . fst)) (plainRecs <> purgeableGuarded)
      -- P3b-10（七轮复审 major，junction 实测）：这是 pm 全程唯一 unlink 用户
      -- 数据的位置，词法校验（readManifest 的 relPathOk）挡不住别名——
      -- .pm/trash/link 若是指向库外的 junction，"link\v.jpg" 是完全合法的相对
      -- 路径，而 removeFile 会顺着链接删掉库外文件（探针已实证）。
      -- P3b-11（八轮复审 critical，探针实证）：以 trashDir 为基准的 canonical
      -- 包含判定还不够——.pm/trash **自身**是 junction 时，基准与目标一起解析
      -- 到库外，包含关系成立、闸门放行，removeFile 删掉了库外文件。改为从
      -- root 起逐级下降（resolveUnder），.pm 与 trash 这两级同样必须是真名。
      -- 删的就是验过的那条路径（逐级下降的落点），不是另一次词法拼接。
      judged <- forM candidates $ \(r, _) -> do
        m <- resolveUnder root (".pm" </> pmSubTrash </> trTrashRel r)
        pure (r, m)
      let purgeable = [(r, p) | (r, Just p) <- judged]
          escaped = [r | (r, Nothing) <- judged]
      forM_ escaped $ \r ->
        putStrLn ("  HELD(不删) " <> trTrashRel r <> " —— 解析后不在 .pm/trash 之内（链接/别名？先跑 pm doctor 人工核查）")
      let heldN = length heldGuarded + length escaped
      if null purgeable
        then putStrLn "隔离区没有可清除的已登记条目" >> pure (if heldN == 0 then 0 else 1)
        else do
          putStrLn ("将永久删除以下 " <> show (length purgeable) <> " 个已登记条目:")
          forM_ purgeable $ \(r, _) ->
            putStrLn ("  × " <> trTrashRel r <> "  (原 " <> trVictimRel r <> ")")
          unless (null (tvUnregistered tv)) $
            putStrLn ("（另有 " <> show (length (tvUnregistered tv)) <> " 个 UNREGISTERED 文件不会被动，先跑 pm doctor）")
          if not yes
            then putStrLn "确认清除请加 --yes" >> pure 1
            else do
              -- pm 全程唯一 unlink 用户数据的位置：仅限上面逐项列出、且已通过
              -- canonical 限域的条目（DESIGN §5 pm trash empty；I2 的最终出口）。
              forM_ purgeable $ \(_, abs') -> removeFile abs'
              putStrLn ("✓ 已清除 " <> show (length purgeable) <> " 项（manifest 记录保留为历史）")
              pure (if heldN == 0 then 0 else 1)

-- | 受屏障保护的隔离类别。
data PurgeBarrier
  = -- | @clean-staging@：归档层 + **备份盘**各一份仍在（评审 cx-3）
    BThreeCopies
  | -- | @dedupe@：归档层还留着一份即可——被隔离的本来就是"多余的那一份"
    BArchiveCopyLeft
  deriving (Show, Eq)

-- | 永久删除前按**当前** catalog + 真实重 hash 再确认该内容还有别的活副本。
--
-- 两类屏障问的不是同一件事，所以要的证据也不同：'BThreeCopies' 要备份盘那一
-- 份，'BArchiveCopyLeft' 与备份盘无关。因此**只在真有 'BThreeCopies' 记录时**
-- 才去发现备份盘——否则一块没插的盘会把与它无关的 dedupe 记录一起拖成 HELD。
--
-- 证据一律先验主库身份再读（P3b-8 复审 B1：校验先于任何主库侧读取）。
purgeBarriers ::
  Config ->
  [(PurgeBarrier, (TrashRecord, FilePath))] ->
  IO ([(TrashRecord, FilePath)], [(TrashRecord, String)])
purgeBarriers cfg guarded
  | null guarded = pure ([], [])
  | otherwise = do
      emain <- requireMain cfg
      case emain of
        Left m -> pure ([], [(r, "主库身份不符: " <> m) | (_, (r, _)) <- guarded])
        Right _ -> do
          mMain <- fst <$> loadCatalog (cfgMainPath cfg)
          case mMain of
            Nothing -> pure ([], [(r, "主库无索引") | (_, (r, _)) <- guarded])
            Just mainCat -> do
              bak <-
                if any ((== BThreeCopies) . fst) guarded
                  then do
                    er <- discoverBackupRoot cfg
                    case er of
                      Left msg -> pure (Left ("备份盘不在线: " <> msg))
                      Right broot -> do
                        mb <- fst <$> loadCatalog broot
                        pure (maybe (Left "备份盘无索引") (Right . (,) broot) mb)
                  else pure (Left "本批无 clean-staging 记录")
              judged <- forM guarded $ \(b, rec@(r, _)) -> do
                -- 即将被永久删除的那个对象 = 隔离区里的载荷。见证与它**同身份**
                -- 就不是另一份副本——同一个对象出现在两个名字下不算两份
                -- （codex 二十八轮 #2；此前这一条由 link count 代劳，代价是把
                -- 合法 hardlink 的归档见证也一并拒了，长期 HELD）。
                pp <- probeConfined (cfgMainPath cfg) (".pm" </> pmSubTrash </> trTrashRel r)
                let excl = case pp of CpSha _ fid -> [fid]; _ -> []
                v <- case b of
                  BThreeCopies -> case bak of
                    Left msg -> pure (Left msg)
                    Right (broot, bakCat) -> do
                      ok <- threeCopiesStillExist (cfgMainPath cfg) mainCat broot bakCat excl (trSha r)
                      pure (if ok then Right () else Left "三副本复验不过")
                  BArchiveCopyLeft -> do
                    ok <- anyArchiveCopyAlive (cfgMainPath cfg) mainCat excl (trSha r)
                    pure (if ok then Right () else Left "归档层已无此内容的活副本（这可能是最后一份）")
                pure (rec, v)
              pure
                ( [rec | (rec, Right ()) <- judged]
                , [(r, m) | ((r, _), Left m) <- judged]
                )

-- ─── undo / apply / resolve ─────────────────────────────────────────────────

runUndoCmd :: Int -> RootSel -> Config -> IO Int
runUndoCmd n sel cfg = do
  eroot <- pickRoot cfg sel
  case eroot of
    Left (msg, code) -> putStrLn msg >> pure code
    Right root -> do
      r <- buildUndoPlan root n
      case r of
        Left e -> putStrLn e >> pure 2
        Right plan -> do
          fp <- savePlan plan
          mapM_ putStrLn (renderPlan plan)
          putStrLn ("计划已存 " <> fp)
          putStrLn ("执行: pm apply " <> T.unpack (plId plan))
          pure 0

-- | 计划可能存在主库、vault 或备份 root 的 .pm/plans 下；按此序查找。
loadPlanAnyRoot :: Config -> T.Text -> IO (Either String Plan)
loadPlanAnyRoot cfg pid = do
  r <- loadPlan (cfgMainPath cfg) pid
  case r of
    Right p -> pure (Right p)
    Left mainErr -> do
      rv <- case cfgVaultPath cfg of
        Nothing -> pure (Left mainErr)
        Just vp -> loadPlan vp pid
      case rv of
        Right p -> pure (Right p)
        Left _ -> do
          eb <- discoverBackupRoot cfg
          case eb of
            Left _ -> pure (Left mainErr)
            Right broot -> do
              rb <- loadPlan broot pid
              pure $ case rb of
                Right p -> Right p
                Left _ -> Left (mainErr <> "（vault/备份 root 也没有）")

-- | @pm apply@ 的**决定**部分：装载 → 按 UUID 重新绑定 root（评审 cx-1）→
-- @--only@ 展开到复合组闭包（评审 cx-2）。返回可执行的计划，以及因组闭包被
-- 追加进来的序号。
--
-- 抽出来是因为 CLI 与 @POST \/api\/apply@ 必须对「这个计划该怎么执行」给出
-- **同一个**答案。两处各写一遍 load\/bind\/only，就会有一处忘了按 UUID 绑
-- root、或忘了把组闭包补齐——前者会改错库，后者会把 supersede 拆成半个。
-- 执行期屏障不在这里：它随 Config 装进 ExecEnv，由内核在锁内跑
-- （'Pm.Cli.executePlanNowWith' → 'Pm.Exec.execBarrier'）。@--dry@ 因此天然
-- 不触发任何复验副作用——它根本不进 'Pm.Exec.execPlan'。
prepareApply :: Config -> T.Text -> Maybe String -> IO (Either String (Plan, [Int]))
prepareApply cfg pid only = do
  ep <- loadPlanAnyRoot cfg pid
  case ep of
    Left e -> pure (Left e)
    Right plan0 -> case plRootId plan0 of
      Nothing -> pure (Left "计划缺 root 标识（P2.1 之前的旧格式）→ 重新生成计划后再执行（评审 cx-1）")
      Just rid -> do
        ebound <- bindExecRoot cfg plan0 rid
        pure (ebound >>= applyOnlyToPlan only)

runApply :: ApplyOpts -> Config -> IO Int
runApply o cfg = do
  r <- prepareApply cfg (aoId o) (aoOnly o)
  case r of
    Left e -> putStrLn e >> pure 2
    Right (plan2, added) -> do
      unless (null added) $
        putStrLn ("· --only 已扩到复合组（不可拆），追加条目: " <> show added)
      mapM_ putStrLn (renderPlan plan2)
      if aoDry o
        then pure 0
        else do
          -- 执行期屏障由内核在 withRootLock 内跑（二十九轮 critical）；三条
          -- 执行路径共用 'Pm.Cli.executePlanNowWith' 这一个装配点，没有哪一处
          -- 还需要（也没有哪一处还能够）自己决定挂不挂屏障。
          code <- executePlanNow cfg plan2
          afterApply cfg plan2 code
          pure code

-- | apply 之后的缓存/提示收尾（可测）。P3b-7 复审 B1：备份缓存写进
-- @\<cfgMainPath\>\/.pm\/backup-cache@，主路径必须是 RoleMain root——
-- 否则跳过刷新并告警（计划本身已由 bindExecRoot 按 UUID 绑到备份 root）。
afterApply :: Config -> Plan -> Int -> IO ()
afterApply cfg plan code = do
  when (plKind plan == "backup") $ do
    emain <- requireMain cfg
    case emain of
      Left m -> putStrLn ("⚠ 备份缓存未刷新（主库身份不符）: " <> m)
      Right _ -> do
        (mMain, _) <- loadCatalog (cfgMainPath cfg)
        (mBak, _) <- loadCatalog (plRootPath plan)
        case (mMain, mBak) of
          (Just mc, Just bc) ->
            refreshBackupCache cfg (plRootPath plan) bc (backupDiff mc bc)
          _ -> pure ()
  when (plKind plan == "vault-push") $ do
    when (code == 0) $
      mapM_ putStrLn (gitStepsLines (plRootPath plan) (plId plan) (planCategories plan))
    -- 刷新 vault 缓存（computeVault 顺带写缓存，内含 requireMain；结果此处不用）
    _ <- computeVault True cfg
    pure ()

runResolve :: ResolveOpts -> Config -> IO Int
runResolve o cfg = do
  ep <- loadPlanAnyRoot cfg (roId o)
  case ep of
    Left e -> putStrLn e >> pure 2
    Right plan0 -> do
      -- P3b-7 复审新 major：resolve 会把计划**写回** <root>/.pm/plans/。root
      -- 路径取自计划文件（可手编），先按 UUID 绑回真实 root（同 apply），再验
      -- 可写（身份可解析 + I11）。
      ebound <- case plRootId plan0 of
        Nothing -> pure (Left "计划缺 root 标识（P2.1 之前的旧格式）→ 重新生成计划")
        Just rid -> bindExecRoot cfg plan0 rid
      ew <- case ebound of
        Left e -> pure (Left e)
        Right p -> either Left (const (Right p)) <$> requireWritable (plRootPath p)
      case ew of
        Left e -> putStrLn e >> pure 2
        Right plan -> resolveOn o plan

-- | 三十轮 F2：resolve 是「装载 → 改 → 写回」的跨进程 RMW——两个 pm resolve
-- 同一份计划、各批不同条目，后写者会整份抹掉先写者的裁决（与二十一轮
-- vault-holds 名单同一形状）。整段进 I10 锁，且锁内**重新装载**盘上的计划：
-- 锁外那份只用来按 UUID 发现 root（线索），不作裁决依据（证据）。
resolveOn :: ResolveOpts -> Plan -> IO Int
resolveOn o plan = do
  m <- withRootLock (plRootPath plan) $ do
    efresh <- loadPlan (plRootPath plan) (plId plan)
    case efresh of
      Left e -> putStrLn e >> pure 2
      Right fresh -> resolveOn' o fresh
  case m of
    Nothing -> putStrLn "另一个 pm 实例正持有该 root 的锁（I10），裁决未写入，稍后重试" >> pure 2
    Just c -> pure c

resolveOn' :: ResolveOpts -> Plan -> IO Int
resolveOn' o plan = do
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
  -- P2.2 fail-closed（复审 cx-1 残留）：root 无身份就不出计划，而不是造一个
  -- rootId=Nothing 的计划再依赖下游拒绝；P3b-5 复审 B1：并校验 role 确为
  -- RoleMain。P3b-8 复审 B1：校验先于任何 catalog 读取与判定（与 runClean 同一
  -- 次序）——配置路径指向别的 root 时，不该先按它的索引算出一份归档报告再拒绝。
  er <- requireRole RoleMain root
  case er of
    Left msg -> putStrLn msg >> pure 2
    Right info -> withFreshStagingCatalog root $ \cat -> do
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
          pid <- newPlanId
          now <- getCurrentTime
          savePlanAndMaybeRun
            cfg
            go
            Plan
              { plId = pid
              , plKind = "import"
              , plRootPath = root
              , plRootId = Just (riId info)
              , plCreated = now
              , plItems = items
              }

-- | @pm dedupe@：归档层精确重复 → **逐份可裁决**的隔离计划。
--
-- 报告口径与 @pm versions@ 完全一致（同一个 'Pm.Versions.versionsReport'），
-- 所以"看到的"与"能操作的"不可能对不上。每一条都是 NEEDS-DECISION：留哪一份
-- 是用户的判断，pm 判不出就不猜（I1）。执行期还有一道屏障兜底——见
-- 'Pm.Dedupe.recheckDedupeItems'。
runDedupe :: GoOpts -> Config -> IO Int
runDedupe go cfg = do
  let root = cfgMainPath cfg
  -- 与 runClean 同一道闸：见证与受害者都取自主库 catalog，root 必须真是 RoleMain。
  erole <- requireRole RoleMain root
  case erole of
    Left msg -> putStrLn msg >> pure 2
    Right info -> do
      (mcat, warns) <- loadCatalog root
      mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
      case mcat of
        Nothing -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
        Just cat -> do
          let gs = dedupeGroups cat
              items = dedupePlanItems gs
          if null gs
            then putStrLn "✓ 归档层无非设计内精确重复" >> pure 0
            else do
              printf "精确重复 %d 组 · 共 %d 份文件\n" (length gs) (length items)
              forM_ (zip (scanl (+) 0 (map (length . dgPaths) gs)) gs) $ \(off, g) -> do
                putStrLn ("  = sha " <> T.unpack (T.take 16 (dgSha g)) <> ":")
                forM_ (zip [off ..] (dgPaths g)) $ \(ix, p) ->
                  printf "      #%-3d %s\n" (ix :: Int) p
              putStrLn "每一份都是待裁决条目——留哪一份 pm 不替你选（I1）。"
              putStrLn "批准隔离某一份: pm resolve <计划 id> --item <#序号> --unskip"
              putStrLn "执行期屏障：某个内容在归档层的最后一份活副本不会被隔离掉（自动降级待裁决）"
              pid <- newPlanId
              now <- getCurrentTime
              savePlanAndMaybeRun
                cfg
                go
                Plan
                  { plId = pid
                  , plKind = "dedupe"
                  , plRootPath = root
                  , plRootId = Just (riId info)
                  , plCreated = now
                  , plItems = items
                  }

-- ─── backup：见 Pm.BackupCmd（P3b-6 拆分） ──────────────────────────────────

-- ─── clean staging ──────────────────────────────────────────────────────────

runClean :: GoOpts -> Config -> IO Int
runClean go cfg = do
  let root = cfgMainPath cfg
  -- P2.2 fail-closed（复审 cx-1 残留）+ P3b-5 B1 role 校验：同 runImport。
  -- P3b-8 复审 B1：校验必须先于 catalog 读取与 verifyCandidates——主路径若是
  -- RoleBackup root（备份盘误配成主库、与备份发现命中同一路径），三副本判定
  -- 会把同一文件当成主库/备份两份见证并打印「三副本已确认」；即便最后拒绝
  -- 写计划，判定与输出已经错了。
  erole <- requireRole RoleMain root
  case erole of
    Left msg -> putStrLn msg >> pure 2
    Right info -> withFreshStagingCatalog root $ \cat -> do
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
                  pid <- newPlanId
                  now <- getCurrentTime
                  -- P2.2（复审 cx-3 旁路封堵）：--apply 即时路径同样在
                  -- 确认后、执行前重验三副本，与 pm apply 无差别——两者现在
                  -- 共用 'preExecFor'，不再各自记得传钩子。
                  savePlanAndMaybeRun
                    cfg
                    go
                    Plan
                      { plId = pid
                      , plKind = "clean-staging"
                      , plRootPath = root
                      , plRootId = Just (riId info)
                      , plCreated = now
                      , plItems = items
                      }
