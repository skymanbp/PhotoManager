{-# LANGUAGE OverloadedStrings #-}

-- | The dashboard (DESIGN.md §5.1). Header always states index age; every
-- problem line ends with the exact next command to run. Default mode does a
-- stat-only freshness sweep so the numbers can say "已过期" instead of lying
-- (--cached skips the sweep).
--
-- P4-1：拆成「报告数据」('statusReport'，带 ToJSON，供 'Pm.Serve' 的
-- @GET /api/status@）与「终端渲染」('renderStatus'）两层；'runStatus' 是二者
-- 的组合，输出文本与退出码语义与 P3b 相同。退出码由 'srExit' 携带，API 与
-- CLI 不会各算一套。
module Pm.Status
  ( StatusOpts (..)
  , StatusReport (..)
  , IndexSummary (..)
  , LayerRow (..)
  , CacheState (..)
  , statusReport
  , renderStatus
  , runStatus
  ) where

import Data.Aeson (ToJSON (..), object, (.=))
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

-- | 侧缓存三态（P3b-15：失信不得压成缺席）。
data CacheState a = CacheBad String | CacheAbsent | CacheOk a
  deriving (Show, Eq)

instance ToJSON a => ToJSON (CacheState a) where
  toJSON (CacheBad m) = object ["state" .= ("untrusted" :: String), "error" .= m]
  toJSON CacheAbsent = object ["state" .= ("absent" :: String)]
  toJSON (CacheOk a) = object ["state" .= ("ok" :: String), "meta" .= a]

data LayerRow = LayerRow
  { lrName :: String
  , lrFiles :: Int
  , lrBytes :: Integer
  }
  deriving (Show, Eq)

instance ToJSON LayerRow where
  toJSON r = object ["name" .= lrName r, "files" .= lrFiles r, "bytes" .= lrBytes r]

data IndexSummary = IndexSummary
  { isScannedAt :: UTCTime
  , isAgeMinutes :: Integer
  , isFiles :: Int
  , isBytes :: Integer
  , isLayers :: [LayerRow]
  , isOldestVerifiedDays :: Maybe Integer
  , isStagingEvents :: [String]
  , isStagingFiles :: Int
  , isStagingArchived :: Int
  , isBackup :: CacheState BackupCacheMeta
  , isVault :: Maybe (CacheState VaultCacheMeta)
    -- ^ Nothing = 配置里没有 vault
  , isFreshness :: Maybe (Int, Int, Int, Int)
    -- ^ (new, changed, missing, readErrors)。第四位是三十九轮（P7）补上的：
    -- freshnessSweep 一直返回错误数，这里此前把它丢弃——stat 失败的文件
    -- 既不进任何差异桶也不进退出码，「✓ 索引与磁盘一致」会在核对受阻时照说。
    -- ^ (新增, 变更, 消失)；Nothing = --cached 未核对
  }
  deriving (Show, Eq)

data StatusReport = StatusReport
  { srRoot :: FilePath
  , srWarnings :: [String]
    -- ^ 快照损坏已跳过（loadCatalog 的告警）
  , srIndex :: Maybe IndexSummary
    -- ^ Nothing = 主库尚未索引
  , srExit :: Int
    -- ^ 0 = nothing pending, 1 = something needs attention, 2 = not usable yet (no index)
  }
  deriving (Show, Eq)

instance ToJSON StatusReport where
  toJSON r =
    object
      [ "root" .= srRoot r
      , "warnings" .= srWarnings r
      , "exit" .= srExit r
      , "index" .= fmap idx (srIndex r)
      ]
   where
    idx i =
      object
        [ "scannedAt" .= isScannedAt i
        , "ageMinutes" .= isAgeMinutes i
        , "files" .= isFiles i
        , "bytes" .= isBytes i
        , "layers" .= isLayers i
        , "oldestVerifiedDays" .= isOldestVerifiedDays i
        , "stagingEvents" .= isStagingEvents i
        , "stagingFiles" .= isStagingFiles i
        , "stagingArchived" .= isStagingArchived i
        , "backup" .= isBackup i
        , "vault" .= isVault i
        , "freshness" .= fmap (\(n, c, m, e) -> object ["new" .= n, "changed" .= c, "missing" .= m, "errors" .= e]) (isFreshness i)
        ]

-- | 采集（含可选的 stat 级新鲜度核对），不打印。
statusReport :: Config -> StatusOpts -> IO StatusReport
statusReport cfg opts = do
  let root = cfgMainPath cfg
  (mcat, warns) <- loadCatalog root
  case mcat of
    Nothing -> pure (StatusReport root warns Nothing 2)
    Just cat -> do
      now <- getCurrentTime
      let ageMin = round (diffUTCTime now (catScanned cat) / 60) :: Integer
          entries = Map.elems (catEntries cat)
          totalBytes = sum (map enSize entries)
          layers = Map.toList (Map.fromListWith merge (map layerOf entries))
          merge (a, b) (c, d) = (a + c, b + d)
          layerOf e = (topComponent (enPath e), (1 :: Int, enSize e))
          verifTimes = mapMaybe enLastVerified entries
          oldest = case verifTimes of
            [] -> Nothing
            ts -> Just (round (diffUTCTime now (minimum ts) / 86400) :: Integer)
          stagingEvents = Set.toList . Set.fromList $ mapMaybe stagingEventOf (Map.keys (catEntries cat))
          (nStaging, nArchived) = stagingArchivedSummary cat
      -- 备份盘（只读缓存，不探硬件 —— 拔盘状态下也能报，§9）
      -- P3b-15（十二轮 minor）：status 只读不写，没有配对写侧替它暴露失信——
      -- 缓存不可信必须报 ⚠ 并计入退出码，不得显示成「未登记」再 exit 0。
      ebk <- readBackupCacheMeta root
      let bk = case ebk of
            Left m -> CacheBad m
            Right Nothing -> CacheAbsent
            Right (Just m) -> CacheOk m
      -- vault（只读缓存 —— I11 之前 status 对 vault 目录零接触，§10.1）
      vlt <- case cfgVaultPath cfg of
        Nothing -> pure Nothing
        Just _ -> do
          ev <- readVaultCacheMeta root
          pure . Just $ case ev of
            Left m -> CacheBad m
            Right Nothing -> CacheAbsent
            Right (Just v) -> CacheOk v
      -- Freshness sweep（共享实现：Pm.Scan.freshnessSweep）
      fresh <-
        if stCached opts
          then pure Nothing
          else do
            (newN, changedN, missingN, errN) <- freshnessSweep root "" (catEntries cat)
            pure (Just (newN, changedN, missingN, errN))
      let pending = maybe 0 (\(n, c, m, e) -> n + c + m + e) fresh
          bkBad = case bk of CacheBad _ -> True; _ -> False
          vBad = case vlt of Just (CacheBad _) -> True; _ -> False
          -- 失信缓存与差异同权计入退出码（P3b-15）
          code = if null stagingEvents && pending == 0 && not bkBad && not vBad then 0 else 1
          summary =
            IndexSummary
              { isScannedAt = catScanned cat
              , isAgeMinutes = ageMin
              , isFiles = Map.size (catEntries cat)
              , isBytes = totalBytes
              , isLayers = [LayerRow n c b | (n, (c, b)) <- sortOn fst layers]
              , isOldestVerifiedDays = oldest
              , isStagingEvents = stagingEvents
              , isStagingFiles = nStaging
              , isStagingArchived = nArchived
              , isBackup = bk
              , isVault = vlt
              , isFreshness = fresh
              }
      pure (StatusReport root warns (Just summary) code)

-- | 终端渲染（文本与 P3b 的 runStatus 逐行相同）。
renderStatus :: StatusOpts -> StatusReport -> IO ()
renderStatus opts r = do
  mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) (srWarnings r)
  case srIndex r of
    Nothing -> do
      putStrLn ("主库尚未索引: " <> srRoot r)
      putStrLn "  → 运行 pm scan（首次全量约 10-25 分钟）"
    Just i -> do
      tz <- getCurrentTimeZone
      let stamp = formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz (isScannedAt i))
      printf
        "pm · 索引 %s（%d 分钟前）· %d 文件 / %.1f GiB\n"
        stamp
        (isAgeMinutes i)
        (isFiles i)
        (gib (isBytes i))
      putStrLn (replicate 58 '─')
      mapM_ (\l -> printf "  %-14s %5d 文件 %8.1f GiB\n" (lrName l) (lrFiles l) (gib (lrBytes l))) (isLayers i)
      -- 最久未验证字节年龄（I3b）
      mapM_ (printf "  验证        最久未验证字节 %d 天前\n") (isOldestVerifiedDays i)
      -- Staging events（已归档冗余 → clean；否则 → import）
      let stagingEvents = isStagingEvents i
          nStaging = isStagingFiles i
          nArchived = isStagingArchived i
      if null stagingEvents
        then pure ()
        else
          if nStaging > 0 && nArchived == nStaging
            then do
              printf "  暂存区    %d 个事件 %d 文件内容已全部归档（冗余）\n" (length stagingEvents) nStaging
              putStrLn "      → pm clean staging（三副本确认，需插备份盘）"
            else do
              printf "  ⚠ 暂存区 %d 个事件未归档: %s\n" (length stagingEvents) (show stagingEvents)
              putStrLn "      → pm import"
      case isBackup i of
        CacheBad m -> putStrLn ("  ⚠ 备份盘   缓存不可信: " <> m)
        CacheAbsent -> putStrLn "  备份盘     未登记/未同步 → 插盘后 pm backup init <镜像路径>，再 pm backup"
        CacheOk m -> do
          let bstamp = formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz (bmAt m))
              lag = bmAdd m + bmUpdate m
          if lag == 0
            then printf "  备份盘     上次同步 %s · 当时无滞后（EXTRA %d）\n" bstamp (bmExtra m)
            else printf "  ⚠ 备份盘   上次同步 %s · 当时落后 %d 项 → 插盘后 pm backup\n" bstamp lag
      case isVault i of
        Nothing -> pure ()
        Just (CacheBad m) -> putStrLn ("  ⚠ vault    缓存不可信: " <> m)
        Just CacheAbsent -> putStrLn "  vault      未比对过 → pm vault status"
        Just (CacheOk v) -> do
          let vstamp = formatTime defaultTimeLocale "%F %R" (utcToLocalTime tz (vmAt v))
              -- HELD 是用户已经做过的决定，不该永远显示成待办（P4-7）
              vlag = vmNew v - vmHeld v + vmMissing v + vmRenamed v + vmDrift v
          -- unstable 不是差异但状态未知（P3b-4 #5）：同样要 ⚠ 提示重跑
          if vlag == 0 && vmUnstable v == 0
            then printf "  vault      上次比对 %s · 无差异（dup %d · unpushable %d）\n" vstamp (vmDuplicate v) (vmUnpushable v)
            else
              printf
                "  ⚠ vault    上次比对 %s · 差异 %d（NEW %d / MISS %d / REN %d / DRIFT %d / 不稳定 %d）→ pm vault status\n"
                vstamp
                vlag
                (vmNew v - vmHeld v)
                (vmMissing v)
                (vmRenamed v)
                (vmDrift v)
                (vmUnstable v)
      case isFreshness i of
        Nothing
          | stCached opts -> putStrLn "  （--cached: 未做新鲜度核对）"
          | otherwise -> pure ()
        Just (newN, changedN, missingN, errN)
          | newN + missingN + changedN + errN == 0 -> putStrLn "  ✓ 索引与磁盘一致"
          | otherwise -> do
              printf "  ⚠ 索引已过期或核对受阻: 新增 %d / 变更 %d / 消失 %d / 读取错误 %d\n" newN changedN missingN errN
              putStrLn "      → pm scan（有读取错误则先排除占用/权限再扫）"

-- | Returns the process exit code: 0 = nothing pending, 1 = something needs
-- attention, 2 = not usable yet (no index).
runStatus :: Config -> StatusOpts -> IO Int
runStatus cfg opts = do
  r <- statusReport cfg opts
  renderStatus opts r
  pure (srExit r)

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
