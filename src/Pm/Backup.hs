{-# LANGUAGE OverloadedStrings #-}

-- | Backup-root discovery and the main-side cache of the backup catalog
-- (DESIGN.md §9). Roots are recognized by UUID marker, never by drive
-- letter; when the drive is absent pm says so and never guesses. The cache
-- lets @pm status@ report 「上次同步 + 当时滞后量」 while the drive is
-- unplugged, without ever probing hardware from status.
module Pm.Backup
  ( discoverBackupRoot
  , BackupCacheMeta (..)
  , writeBackupCache
  , readBackupCacheMeta
  ) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import System.FilePath ((</>))

import Pm.Config (Config (..), pmDir, readJsonMaybe, readRootInfo, writeSideCache)
import Pm.Types
import Pm.Win (listCandidateDrives, suppressCriticalErrorDialogs)

-- | Probe present REMOVABLE\/FIXED volumes for the registered backup root.
-- Right = absolute root path on the mounted drive.
discoverBackupRoot :: Config -> IO (Either String FilePath)
discoverBackupRoot cfg = case (cfgBackupId cfg, cfgBackupSubpath cfg) of
  (Just bid, Just sub) -> do
    suppressCriticalErrorDialogs
    drives <- listCandidateDrives
    found <- probe bid sub (map fst drives)
    case found of
      Just p -> pure (Right p)
      Nothing ->
        pure
          ( Left
              ( "备份盘未挂载（在 "
                  <> show (length drives)
                  <> " 个卷上都找不到 root "
                  <> T.unpack (T.take 8 bid)
                  <> "… 的 "
                  <> sub
                  <> "\\.pm\\root-id.json）→ 插上备份盘后重试"
              )
          )
  _ ->
    pure (Left "备份 root 未登记 → 插上备份盘后运行 pm backup init <盘上镜像路径>")
 where
  probe _ _ [] = pure Nothing
  probe bid sub (c : cs) = do
    let candidate = (c : ":\\") </> sub
    minfo <- readRootInfo candidate
    case minfo of
      Just info
        | riRole info == RoleBackup && riId info == bid -> pure (Just candidate)
      _ -> probe bid sub cs

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

cacheDir :: FilePath -> FilePath
cacheDir mainRoot = pmDir mainRoot </> "backup-cache"

-- | Snapshot copy of the backup catalog + meta, kept on the MAIN root
-- (shared pair-write: Pm.Config.writeSideCache).
writeBackupCache :: FilePath -> Catalog -> BackupCacheMeta -> IO ()
writeBackupCache mainRoot = writeSideCache (cacheDir mainRoot)

readBackupCacheMeta :: FilePath -> IO (Maybe BackupCacheMeta)
readBackupCacheMeta mainRoot = readJsonMaybe (cacheDir mainRoot </> "meta.json")
