{-# LANGUAGE OverloadedStrings #-}

-- | The dashboard (DESIGN.md §5.1). Header always states index age; every
-- problem line ends with the exact next command to run. Default mode does a
-- stat-only freshness sweep so the numbers can say "已过期" instead of lying
-- (--cached skips the sweep).
module Pm.Status
  ( StatusOpts (..)
  , runStatus
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, unless)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Time
import System.FilePath (splitDirectories, (</>))
import Text.Printf (printf)

import Pm.Catalog (loadCatalog)
import Pm.Config (Config (..))
import Pm.Hash (StatSnap (..), statSnap)
import Pm.Scan (listTree)
import Pm.Types

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
      -- Staging events
      let stagingEvents =
            Set.toList . Set.fromList $
              mapMaybe stagingEventOf (Map.keys (catEntries cat))
      unless (null stagingEvents) $ do
        printf "  ⚠ 暂存区 %d 个事件未归档: %s\n" (length stagingEvents) (show stagingEvents)
        putStrLn "      → pm import（P2 交付）"
      -- Freshness sweep
      pending <-
        if stCached opts
          then do
            putStrLn "  （--cached: 未做新鲜度核对）"
            pure 0
          else do
            (files, _errs) <- listTree root
            snaps <- forM files $ \rel -> do
              r <- try (statSnap (root </> rel)) :: IO (Either SomeException StatSnap)
              pure (rel, r)
            let diskMap = Map.fromList [(rel, s) | (rel, Right s) <- snaps]
                catMap = catEntries cat
                newN = Map.size (diskMap `Map.difference` catMap)
                missingN = Map.size (catMap `Map.difference` diskMap)
                changedN =
                  length
                    [ ()
                    | (rel, s) <- Map.toList diskMap
                    , Just e <- [Map.lookup rel catMap]
                    , enSize e /= ssSize s || enMtimeNs e /= ssMtimeNs s
                    ]
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
