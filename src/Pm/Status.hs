{-# LANGUAGE OverloadedStrings #-}

-- | The dashboard (DESIGN.md §5.1). Header always states index age; every
-- problem line ends with the exact next command to run. Default mode does a
-- stat-only freshness sweep so the numbers can say "已过期" instead of lying
-- (--cached skips the sweep).
module Pm.Status
  ( StatusOpts (..)
  , runStatus
  ) where

import Control.Monad (unless)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Time
import System.FilePath (splitDirectories)
import Text.Printf (printf)

import Pm.Backup (BackupCacheMeta (..), readBackupCacheMeta)
import Pm.Catalog (loadCatalog)
import Pm.Config (Config (..))
import Pm.Import (stagingArchivedSummary)
import Pm.Scan (freshnessSweep)
import Pm.Types
import Pm.Vault (VaultCacheMeta (..), readVaultCacheMeta)

data StatusOpts = StatusOpts
  { stCached :: Bool
  }

-- | Returns the process exit code: 0 = nothing pending, 1 = something needs
-- attention, 2 = not usable yet (no index).
runStatus :: Config -> StatusOpts -> IO Int
runStatus cfg opts = do
  let root = cfgMainPath cfg
  (mcat, warns) <- loadCatalog root
  mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
  case mcat of
    Nothing -> do
      putStrLn ("主库尚未索引: " <> root)
      putStrLn "  → 运行 pm scan（首次全量约 10-25 分钟）"
      pure 2
    Just cat -> do
      now <- getCurrentTime
      tz <- getCurrentTimeZone
      let ageMin = round (diffUTCTime now (catScanned cat) / 60) :: Integer
          totalBytes = sum (map enSize (Map.elems (catEntries cat)))
          stamp = formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz (catScanned cat))
      printf
        "pm · 索引 %s（%d 分钟前）· %d 文件 / %.1f GiB\n"
        stamp
        ageMin
        (Map.size (catEntries cat))
        (gib totalBytes)
      putStrLn (replicate 58 '─')
      -- Per-layer table
      let layers = Map.toList (Map.fromListWith merge (map layerOf (Map.elems (catEntries cat))))
          merge (a, b) (c, d) = (a + c, b + d)
          layerOf e = (topComponent (enPath e), (1 :: Int, enSize e))
      mapM_
        (\(name, (n, b)) -> printf "  %-14s %5d 文件 %8.1f GiB\n" name n (gib b))
        (sortOn fst layers)
      -- 最久未验证字节年龄（I3b）
      let verifTimes = mapMaybe enLastVerified (Map.elems (catEntries cat))
      case verifTimes of
        [] -> pure ()
        ts -> do
          let oldestDays = round (diffUTCTime now (minimum ts) / 86400) :: Integer
          printf "  验证        最久未验证字节 %d 天前\n" oldestDays
      -- Staging events（已归档冗余 → clean；否则 → import）
      let stagingEvents =
            Set.toList . Set.fromList $
              mapMaybe stagingEventOf (Map.keys (catEntries cat))
          (nStaging, nArchived) = stagingArchivedSummary cat
      unless (null stagingEvents) $
        if nStaging > 0 && nArchived == nStaging
          then do
            printf "  暂存区    %d 个事件 %d 文件内容已全部归档（冗余）\n" (length stagingEvents) nStaging
            putStrLn "      → pm clean staging（三副本确认，需插备份盘）"
          else do
            printf "  ⚠ 暂存区 %d 个事件未归档: %s\n" (length stagingEvents) (show stagingEvents)
            putStrLn "      → pm import"
      -- 备份盘（只读缓存，不探硬件 —— 拔盘状态下也能报，§9）
      mbk <- readBackupCacheMeta root
      case mbk of
        Nothing ->
          putStrLn "  备份盘     未登记/未同步 → 插盘后 pm backup init <镜像路径>，再 pm backup"
        Just m -> do
          let bstamp = formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz (bmAt m))
              lag = bmAdd m + bmUpdate m
          if lag == 0
            then printf "  备份盘     上次同步 %s · 当时无滞后（EXTRA %d）\n" bstamp (bmExtra m)
            else printf "  ⚠ 备份盘   上次同步 %s · 当时落后 %d 项 → 插盘后 pm backup\n" bstamp lag
      -- vault（只读缓存 —— I11 之前 status 对 vault 目录零接触，§10.1）
      case cfgVaultPath cfg of
        Nothing -> pure ()
        Just _ -> do
          mv <- readVaultCacheMeta root
          case mv of
            Nothing -> putStrLn "  vault      未比对过 → pm vault status"
            Just v -> do
              let vstamp = formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz (vmAt v))
                  vlag = vmNew v + vmMissing v + vmRenamed v + vmDrift v
              if vlag == 0
                then printf "  vault      上次比对 %s · 无差异（dup %d · unpushable %d）\n" vstamp (vmDuplicate v) (vmUnpushable v)
                else
                  printf
                    "  ⚠ vault    上次比对 %s · 差异 %d（NEW %d / MISS %d / REN %d / DRIFT %d）→ pm vault status\n"
                    vstamp
                    vlag
                    (vmNew v)
                    (vmMissing v)
                    (vmRenamed v)
                    (vmDrift v)
      -- Freshness sweep（共享实现：Pm.Scan.freshnessSweep）
      pending <-
        if stCached opts
          then do
            putStrLn "  （--cached: 未做新鲜度核对）"
            pure 0
          else do
            (newN, changedN, missingN, _errN) <- freshnessSweep root "" (catEntries cat)
            if newN + missingN + changedN == 0
              then putStrLn "  ✓ 索引与磁盘一致" >> pure 0
              else do
                printf "  ⚠ 索引已过期: 新增 %d / 变更 %d / 消失 %d\n" newN changedN missingN
                putStrLn "      → pm scan"
                pure (newN + changedN + missingN)
      pure (if null stagingEvents && pending == 0 then 0 else 1)

topComponent :: FilePath -> String
topComponent rel = case splitDirectories rel of
  (c : _ : _) -> c
  _ -> "(根)"

stagingEventOf :: FilePath -> Maybe String
stagingEventOf rel = case splitDirectories rel of
  (top : sub : event : _ : _)
    | top == "To-Be-Sync'd" && sub `elem` ["Raw", "Processed"] -> Just event
  _ -> Nothing

gib :: Integer -> Double
gib b = fromIntegral b / (1024 * 1024 * 1024)
