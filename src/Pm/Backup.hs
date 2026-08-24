{-# LANGUAGE OverloadedStrings #-}

-- | Backup-root discovery and the main-side cache of the backup catalog
-- (DESIGN.md §9). Roots are recognized by UUID marker, never by drive
-- letter; when the drive is absent pm says so and never guesses. The cache
-- lets @pm status@ report 「上次同步 + 当时滞后量」 while the drive is
-- unplugged, without ever probing hardware from status.
module Pm.Backup
  ( discoverBackupRoot
  , discoverBackupRoots
  , discoverAmong
  , BackupCacheMeta (..)
  , writeBackupCache
  , readBackupCacheMeta
  ) where

import Control.Monad (forM)
import Data.Aeson
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import System.FilePath ((</>))

import Pm.Config (Config (..), pmDir, pmSubBackupCache, readRootInfo, readSideCache, writeSideCache)
import Pm.Types
import Pm.Win (listCandidateDrives, suppressCriticalErrorDialogs)

-- | 在给定候选路径里找带该 UUID 的备份 root，返回**全部**命中（P3b-5 复审
-- #6：两块盘同时挂载且带同一 UUID——整盘克隆——只返回首命中会把身份歧义
-- 藏起来）。候选列表可注入，便于 fixture 测试。
discoverAmong :: Text -> [FilePath] -> IO [FilePath]
discoverAmong bid cands = do
  hits <- forM cands $ \c -> do
    minfo <- readRootInfo c
    pure [c | Just i <- [minfo], riRole i == RoleBackup, riId i == bid]
  pure (concat hits)

-- | Probe present REMOVABLE\/FIXED volumes for the registered backup root.
-- Right (探过的卷数, 全部命中路径)；Left = 未登记。
discoverBackupRoots :: Config -> IO (Either String (Int, [FilePath]))
discoverBackupRoots cfg = case (cfgBackupId cfg, cfgBackupSubpath cfg) of
  (Just bid, Just sub) -> do
    suppressCriticalErrorDialogs
    drives <- listCandidateDrives
    hits <- discoverAmong bid [(c : ":\\") </> sub | (c, _) <- drives]
    pure (Right (length drives, hits))
  _ ->
    pure (Left "备份 root 未登记 → 插上备份盘后运行 pm backup init <盘上镜像路径>")

-- | 恰一命中才是可用的备份 root；零命中 = 未挂载，多命中 = 身份冲突，
-- 都拒绝（不猜哪块盘是对的）。
discoverBackupRoot :: Config -> IO (Either String FilePath)
discoverBackupRoot cfg = do
  er <- discoverBackupRoots cfg
  pure $ case er of
    Left m -> Left m
    Right (_, [p]) -> Right p
    Right (n, []) ->
      Left
        ( "备份盘未挂载（在 " <> show n <> " 个卷上都找不到 root "
            <> maybe "?" (T.unpack . T.take 8) (cfgBackupId cfg) <> "… 的 "
            <> maybe "?" id (cfgBackupSubpath cfg) <> "\\.pm\\root-id.json）→ 插上备份盘后重试"
        )
    Right (_, ps) ->
      Left
        ( "多个卷同时匹配备份 root（" <> intercalate "、" ps
            <> "），身份冲突（同一标识被整盘克隆），拒绝——拔掉多余的盘或修正 root-id.json"
        )

-- ─── Main-side cache (status while unplugged) ───────────────────────────────

data BackupCacheMeta = BackupCacheMeta
  { bmAt :: UTCTime
  , bmPath :: FilePath
    -- ^ 上次同步时备份 root 的挂载路径（仅展示用；识别仍靠 UUID）
  , bmFsType :: Maybe Text
  , bmAdd :: Int
  , bmUpdate :: Int
  , bmExtra :: Int
    -- ^ 上次比对时的滞后量（apply 后回写为 apply 后的重算值）
  }
  deriving (Show, Eq)

instance ToJSON BackupCacheMeta where
  toJSON m =
    object
      [ "at" .= bmAt m
      , "path" .= bmPath m
      , "fsType" .= bmFsType m
      , "add" .= bmAdd m
      , "update" .= bmUpdate m
      , "extra" .= bmExtra m
      ]

instance FromJSON BackupCacheMeta where
  parseJSON = withObject "BackupCacheMeta" $ \o ->
    BackupCacheMeta
      <$> o .: "at"
      <*> o .: "path"
      <*> o .:? "fsType"
      <*> o .: "add"
      <*> o .: "update"
      <*> o .: "extra"

-- 子目录名取自 'Pm.Config' 的单一真源；写入一律走 root-relative 的
-- 'writeSideCache'（P3b-13 十轮 critical：自由拼目录让 junction 化的缓存目录
-- 把 pm 的写引到了库外）。
cacheDir :: FilePath -> FilePath
cacheDir mainRoot = pmDir mainRoot </> pmSubBackupCache

-- | Snapshot copy of the backup catalog + meta, kept on the MAIN root
-- (shared pair-write: Pm.Config.writeSideCache).
writeBackupCache :: FilePath -> Catalog -> BackupCacheMeta -> IO (Either String ())
writeBackupCache mainRoot = writeSideCache mainRoot pmSubBackupCache

-- P3b-14（十一轮复审 major）：读侧与写侧同规格。此前是自由拼路径 + 按名字
-- decode——写侧从十轮起验完整路径，读侧却没有，@meta.json@ 被 hardlink/symlink
-- 占名时 pm 会把库外内容当成自己的备份基线。
readBackupCacheMeta :: FilePath -> IO (Maybe BackupCacheMeta)
readBackupCacheMeta mainRoot = readSideCache mainRoot pmSubBackupCache "meta.json"
