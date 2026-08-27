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

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_, unless)
import Data.Function (on)
import Data.List (intercalate, nubBy)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.Conc (getNumProcessors)
import System.Directory (doesDirectoryExist, makeAbsolute)
import System.FilePath ((</>))
import Text.Printf (printf)

import Pm.Apply
import Pm.Backup
import Pm.BackupCmd (BackupCmd (..), backupInitPreflight, runBackupInit, runBackupRun)
import Pm.Catalog (CatalogLoad (..), catalogMaybe, catalogOr, loadCatalog, loadNote, saveCatalog)
import Pm.Clean
import Pm.ConfigEdit (checkConfig)
import Pm.Cli
import Pm.Dedupe
import Pm.Config
import Pm.GitGuard (classifyGitProbe, pmIgnoreGuard)
import Pm.Hash (ContentProbe (..), probeConfined)
import Pm.Import
import Pm.Plan
import Pm.Scan
import Pm.Trash
import Pm.Types
import Pm.Win (deleteBoundAt, probeName, resolveUnder, volumeFsType)

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


-- 备份命令（BackupCmd / runBackupInit / runBackupRun）在 Pm.BackupCmd，
-- 此处再导出（P3b-6 拆分：本文件触及 750 行预算）。

withCfg :: (Config -> IO Int) -> IO Int
withCfg act = do
  ecfg <- loadConfig
  case ecfg of
    Left e -> putStrLn e >> pure 2
    Right cfg -> act cfg


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
        -- 三十六轮同类扫尽：这里的 exists 是全仓唯一 False→放行 且无下游
        -- 响亮失败兜底的布尔探针——doesFileExist 把 ACL/介质错误塌成 False，
        -- 「配置已存在（--force 覆盖）」闸被绕过且 mold 丢失，既有备份盘
        -- 登记被无 --force 覆盖掉。同 F1 三态化：查不出 = 不写入。
        kE <- classifyGitProbe <$> probeName cfgFp
        case kE of
          Left why -> pure (Left ("配置文件 " <> cfgFp <> " " <> why))
          Right exists ->
            if exists && not (ioForce o)
              then pure (Left ("配置已存在: " <> cfgFp <> "（--force 覆盖）"))
              else do
                -- --force 重建时保留既有备份盘登记（那是 backup init 的产物）。
                -- 工作流 F010/F077：「读不出」与「不存在」不同——前者要明说哪些
                -- 设置没保留（TOML 坏了 / 非 UTF-8 / 相对路径……整份解码失败，
                -- cfgBackupId 随之丢失）。硬拒绝不可取：pm init 是唯一不经
                -- withCfg 的入口，是从坏配置里逃出来的唯一通路；先说再写。
                st <- if exists then loadConfigState else pure (CfgAbsent "")
                let (mold, lost) = case st of
                      CfgOk c -> (Just c, Nothing)
                      CfgUnreadable why -> (Nothing, Just why)
                      CfgAbsent _ -> (Nothing, Nothing)
                vaultOk <- mapM doesDirectoryExist (ioVault o)
                let newCfg =
                      Config
                          { cfgMainPath = mainPath
                          , cfgVaultPath = ioVault o
                          , cfgPhotosJson = ioPhotosJson o
                          , cfgWorkers = ioWorkers o
                          , cfgBackupId = maybe Nothing cfgBackupId mold
                          , cfgBackupSubpath = maybe Nothing cfgBackupSubpath mold
                          , -- P7：发布路径/push 目标与备份盘登记同类——它们是
                            -- config set / GUI 设置页的产物，init 没有对应旗标，
                            -- --force 重建时不保留就是静默丢设置。
                            cfgPortfolioDir = maybe Nothing cfgPortfolioDir mold
                          , cfgVaultPush = maybe Nothing cfgVaultPush mold
                          , cfgPortfolioPush = maybe Nothing cfgPortfolioPush mold
                          }
                case (ioVault o, vaultOk) of
                  (Just vp, Just False) -> pure (Left ("vault 路径不存在: " <> vp))
                  _ -> do
                    -- 工作流 C101：整份配置过同一个汇点校验（主库/vault 不嵌套、
                    -- 备份登记成对、路径绝对）——init 是四条写路径之一
                    errs <- checkConfig newCfg
                    if null errs
                      then (\fp -> Right (fp, lost)) <$> writeConfig newCfg
                      else pure (Left (intercalate "\n" errs))
      case mw of
        Nothing -> putStrLn "另一个 pm 正在改配置（config.lock 被持有），初始化未写入，稍后重试" >> pure 2
        Just (Left msg) -> putStrLn msg >> pure 2
        Just (Right (fp, lost)) -> do
          forM_ lost $ \why ->
            putStrLn ("⚠ 旧配置读不出（" <> why <> "）——备份盘登记与发布路径/push 目标未能保留，重建后请重跑 pm backup init / pm config set")
          putStrLn ("✓ 配置已写入 " <> fp) >> initMarker o mainPath

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
      -- scan 是重建快照的那条路：被拒/坏掉的旧快照只当种子丢掉，从零重算
      (old, warns) <- catalogMaybe <$> loadCatalog root
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
    -- 三十五轮 F3：枚举失败 fail-closed——不打「隔离区为空」的假报告。
    TrashList -> do
      etv <- trashView root
      case etv of
       Left e -> putStrLn ("✗ " <> e) >> pure 2
       Right tv -> do
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
-- 三十五轮 F3：视图枚举失败 fail-closed——枚举不出 = 不知道盘上有什么，
-- 绝不按「registered 全缺席」的假视图走到 unlink，一个条目都不删。
trashEmptyLocked :: Config -> FilePath -> Bool -> IO Int
trashEmptyLocked cfg root yes = do
      etv <- trashView root
      case etv of
        Left e -> putStrLn ("✗ " <> e <> " —— 未清除任何条目，解除占用后重试") >> pure 2
        Right tv -> trashEmptyLocked' cfg root yes tv

trashEmptyLocked' :: Config -> FilePath -> Bool -> TrashView -> IO Int
trashEmptyLocked' cfg root yes tv = do
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
              -- P6-C：unlink 改句柄形态——打开（终段不跟随）→ 先验句柄绑定
              -- 就是这条已限域的路径 → 句柄上置 delete。resolveUnder 与删除
              -- 之间的窗口不再存在：换掉中途任何一层都会让先验不符而拒绝。
              -- 第一方自审工作流 C102：unlink 是会抛的 IO（共享冲突超预算、只读
              -- 属性 → ACCESS_DENIED、句柄绑定不符）。此前裸 forM_：异常逃顶、
              -- 进程以 1 退出——与「清干净但有 HELD」同码，摘要行也没了，调用方分
              -- 不清「清完」和「删到第 k 个死掉」。逐项 try、首个失败即停（保守：
              -- 少删不多删）、报已清除 k/N、exit 2（DESIGN §5：IO 失败 = 2）。
              done <- purgeLoop (0 :: Int) purgeable
              case done of
                Right n -> do
                  putStrLn ("✓ 已清除 " <> show n <> " 项（manifest 记录保留为历史）")
                  pure (if heldN == 0 then 0 else 1)
                Left (k, p, e) -> do
                  putStrLn
                    ( "✗ " <> p <> ": " <> show e <> " —— 已清除 " <> show k <> "/" <> show (length purgeable)
                        <> " 项，其余未动；解除占用/只读后重跑 pm trash empty（pm trash list 可查看）"
                    )
                  pure 2
 where
  purgeLoop k [] = pure (Right k)
  purgeLoop k ((_, p) : rest) = do
    r <- try (deleteBoundAt p) :: IO (Either IOException ())
    case r of
      Left e -> pure (Left (k, p, e))
      Right () -> purgeLoop (k + 1) rest

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
          lm <- loadCatalog (cfgMainPath cfg)
          let held why = pure ([], [(r, why) | (_, (r, _)) <- guarded])
          case lm of
            -- 缺席与读不出都 HELD，理由各说各的（工作流 A 簇）
            CatAbsent -> held "主库无索引"
            CatRefused _ -> held ("主库" <> loadNote lm)
            CatLoaded mainCat _ -> do
              bak <-
                if any ((== BThreeCopies) . fst) guarded
                  then do
                    er <- discoverBackupRoot cfg
                    case er of
                      Left msg -> pure (Left ("备份盘不在线: " <> msg))
                      Right broot -> do
                        lb <- loadCatalog broot
                        pure (case lb of CatLoaded c _ -> Right (broot, c); other -> Left ("备份盘" <> loadNote other))
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
      lc <- loadCatalog root
      case catalogOr "主库尚未索引 → 先 pm scan" lc of
        Left m -> putStrLn m >> pure 2
        Right (cat, warns) -> do
          mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
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
          lb <- loadCatalog broot
          case catalogOr "备份盘尚无索引 → 先 pm backup" lb of
            Left m -> putStrLn m >> pure 2
            Right (bakCat, _) -> do
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
                  -- 屏障经 'Pm.Cli.runBarrier' 由内核在锁内跑，不再各自记得传钩子。
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
