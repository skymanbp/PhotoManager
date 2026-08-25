{-# LANGUAGE OverloadedStrings #-}

-- | 备份盘命令（`pm backup init` \/ `pm backup`），从 Pm.Commands 拆出
-- （P3b-6：Commands 触及 750 行预算）。Pm.Commands 再导出本模块的名字，
-- 调用面不变；全部写盘仍经 Pm.Cli.savePlanAndMaybeRun → Pm.Exec。
module Pm.BackupCmd
  ( BackupCmd (..)
  , backupInitPreflight
  , runBackupInit
  , backupInitRun
  , BackupInitOutcome (..)
  , runBackupRun
  ) where

import Control.Monad (forM_, unless, when)
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (canonicalizePath, doesDirectoryExist, makeAbsolute)
import System.FilePath (normalise, splitDirectories, splitDrive)
import Text.Printf (printf)

import Pm.Backup (discoverBackupRoot)
import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Cli (GoOpts (..), refreshBackupCache, reportScanIssues, savePlanAndMaybeRun)
import Pm.Config
import Pm.Diff (BackupDiff (..), backupDiff, backupPlanItems)
import Pm.GitGuard (pmIgnoreGuard)
import Pm.Plan
import Pm.Scan (ScanOpts (..), ScanResult (..), scanRoot)
import Pm.Types
import Pm.Win (volumeFsType)

data BackupCmd
  = BackupInit FilePath
  | BackupRun GoOpts (Maybe Int)

-- | 备份盘登记前的守卫（可测）：路径规范化 → 与主库嵌套检查 → git 语境 I11。
-- 评审 mj-4（P2.2 收紧）：canonicalizePath 解析已存在前缀的 junction\/
-- symlink 与真实大小写，再按 case-fold 组件做祖先判断——文本级 normalise
-- 挡不住主库别名路径。P3b-6 复审 major：git 检查与 vault 同一守卫
-- （.git 文件、祖先仓、反规则全覆盖），不再只看本目录的 .git 目录。
-- Right = 规范化绝对路径。
backupInitPreflight :: Config -> FilePath -> IO (Either String FilePath)
backupInitPreflight cfg path = do
  abs' <- canonicalizePath =<< makeAbsolute path
  mainC <- canonicalizePath (cfgMainPath cfg)
  let canonParts p = map (map toLower) (splitDirectories (normalise p))
      nested a b = canonParts a `isPrefixOf` canonParts b
  if nested mainC abs' || nested abs' mainC
    then pure (Left ("备份路径与主库嵌套（" <> abs' <> " vs " <> mainC <> "），拒绝"))
    else do
      g <- pmIgnoreGuard RoleBackup abs'
      pure (either Left (const (Right abs')) g)

-- | `pm backup init` 的**结果**（P4-8 拆分：`POST /api/backup-init` 要的是
-- 结果，不能去捕 stdout；所有守卫留在这里，CLI 只负责渲染）。
data BackupInitOutcome
  = BiReused FilePath Text
    -- ^ 该路径已是备份 root：沿用标识，只重登记配置
  | BiCreated FilePath Text (Maybe Text) Bool
    -- ^ 新建了备份 root 标识（路径、UUID、文件系统类型、目录是否本来不存在）
  deriving (Show, Eq)

-- | 登记备份盘：建立/沿用备份 root 标识并写进配置。**不打印**。
-- 守卫链与拆分前逐条相同：preflight（含 I11 与 requireMain）→ root 三态
-- （损坏不改写、非备份角色拒绝、不可信拒绝）→ 写标识前再 canonicalize 复验
-- → 原子 no-replace 创建。
backupInitRun :: FilePath -> Config -> IO (Either String BackupInitOutcome)
backupInitRun path cfg = do
  epre <- backupInitPreflight cfg path
  case epre of
    Left msg -> pure (Left msg)
    Right abs' -> do
      -- P3b-7 复审 major：损坏的标识不当缺席（不改写）；首次创建原子 no-replace。
      st <- readRootState abs'
      case st of
        RootPresent info
          | riRole info == RoleBackup -> do
              register abs' (riId info)
              pure (Right (BiReused abs' (riId info)))
          | otherwise ->
              pure (Left ("该路径已是 " <> show (riRole info) <> " root，拒绝改作备份"))
        RootCorrupt e ->
          pure (Left (abs' <> " 的 .pm/root-id.json 存在但无法解析（" <> e <> "），拒绝改写——人工核查"))
        -- P3b-12（九轮复审 major）：同 pm init / vault push，建身份的入口也必须
        -- 先确认 .pm 家族是真目录，否则标识会落到库外。
        RootUntrusted m -> pure (Left ("✗ " <> m))
        RootAbsent -> do
          dirExisted <- doesDirectoryExist abs'
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
            then pure (Left ("路径在检查后发生变化（" <> abs' <> " → " <> abs2 <> "），拒绝"))
            else do
              er <- createRootInfo abs' (RootInfo rid RoleBackup now fs)
              case er of
                Left m -> pure (Left m)
                Right () -> do
                  register abs' rid
                  pure (Right (BiCreated abs' rid fs (not dirExisted)))
 where
  register abs' rid = do
    let sub = snd (splitDrive abs')
    _ <- writeConfig cfg {cfgBackupId = Just rid, cfgBackupSubpath = Just sub}
    pure ()

-- | CLI 渲染层：把 'backupInitRun' 的结果印成人读输出并给退出码。
runBackupInit :: FilePath -> Config -> IO Int
runBackupInit path cfg = do
  r <- backupInitRun path cfg
  case r of
    Left msg -> putStrLn msg >> pure 2
    Right o -> do
      case o of
        BiReused _ rid -> putStrLn ("✓ 该路径已是备份 root（沿用标识 " <> T.unpack rid <> "）")
        BiCreated p rid fs created -> do
          when created $ putStrLn ("· 目录不存在，已创建: " <> p)
          putStrLn ("✓ 备份 root 标识已创建: " <> T.unpack rid <> maybe "" (\t -> "（" <> T.unpack t <> "）") fs)
      putStrLn ("✓ 已登记到配置（盘符无关，按 UUID + 相对路径 " <> snd (splitDrive (outPath o)) <> " 认盘）")
      putStrLn "下一步: pm backup"
      pure 0
 where
  outPath (BiReused p _) = p
  outPath (BiCreated p _ _ _) = p

runBackupRun :: GoOpts -> Maybe Int -> Config -> IO Int
runBackupRun go mworkers cfg = do
  -- P3b-6 复审 B1：备份源是主库 catalog + 文件，配置路径须为 RoleMain root
  emain <- requireMain cfg
  either (\m -> putStrLn m >> pure 2) (const (runBackupRun' go mworkers cfg)) emain

runBackupRun' :: GoOpts -> Maybe Int -> Config -> IO Int
runBackupRun' go mworkers cfg = do
  eroot <- discoverBackupRoot cfg
  case eroot of
    Left msg -> putStrLn msg >> pure 1
    Right broot -> do
      -- P3b-7 复审新 major：备份 root 也是 .pm 写入口（catalog/计划/trash），
      -- requireRole 内含 I11 守卫（备份盘被 git init 过也会被拒）。
      erole <- requireRole RoleBackup broot
      (mMain, _) <- loadCatalog (cfgMainPath cfg)
      case (erole, mMain) of
        (Left m, _) -> putStrLn ("备份 root 不可用: " <> m) >> pure 2
        (_, Nothing) -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
        -- P2.3（复审三轮新发现）：发现后重读到的身份必须仍等于**配置登记的**
        -- UUID——不采纳盘上任意 id（发现与使用之间路径/卷可能被换）。
        (Right info, _)
          | cfgBackupId cfg /= Just (riId info) ->
              putStrLn "备份 root 身份在发现后发生变化（与配置登记不符），拒绝" >> pure 2
        (Right info, Just mainCat) -> do
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
