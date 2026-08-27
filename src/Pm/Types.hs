{-# LANGUAGE OverloadedStrings #-}

-- | Core domain types shared by every pm module (DESIGN.md §3).
module Pm.Types
  ( RootRole (..)
  , RootInfo (..)
  , FileKind (..)
  , Entry (..)
  , Catalog (..)
  , classifyExt
  , rawExts
  , entryMap
  ) where

import Data.Aeson
import Data.Char (toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)

data RootRole = RoleMain | RoleBackup | RoleVault
  deriving (Show, Eq)

instance ToJSON RootRole where
  toJSON RoleMain = "main"
  toJSON RoleBackup = "backup"
  toJSON RoleVault = "vault"

instance FromJSON RootRole where
  parseJSON = withText "RootRole" $ \t -> case t of
    "main" -> pure RoleMain
    "backup" -> pure RoleBackup
    "vault" -> pure RoleVault
    _ -> fail ("unknown root role: " <> show t)

-- | Contents of @\<root\>\/.pm\/root-id.json@ — identifies a root by UUID,
-- never by drive letter (DESIGN.md §9).
data RootInfo = RootInfo
  { riId :: Text
  , riRole :: RootRole
  , riCreated :: UTCTime
  , riFsType :: Maybe Text
    -- ^ 探测到的卷文件系统（"NTFS"\/"exFAT"…，§9 备份盘记录用）；仅供参考，
    -- 协议不依赖它。旧 root-id.json 缺此字段 → Nothing。
  }
  deriving (Show, Eq)

instance ToJSON RootInfo where
  toJSON r =
    object
      ["id" .= riId r, "role" .= riRole r, "created" .= riCreated r, "fsType" .= riFsType r]

instance FromJSON RootInfo where
  parseJSON = withObject "RootInfo" $ \o ->
    RootInfo <$> o .: "id" <*> o .: "role" <*> o .: "created" <*> o .:? "fsType"

data FileKind = KindPhoto | KindSidecar | KindMeta
  deriving (Show, Eq)

instance ToJSON FileKind where
  toJSON KindPhoto = "photo"
  toJSON KindSidecar = "sidecar"
  toJSON KindMeta = "meta"

instance FromJSON FileKind where
  parseJSON = withText "FileKind" $ \t -> case t of
    "photo" -> pure KindPhoto
    "sidecar" -> pure KindSidecar
    "meta" -> pure KindMeta
    _ -> fail ("unknown file kind: " <> show t)

-- | 相机原生 raw 的扩展名。**全项目唯一一份定义**。
--
-- 'Pm.Versions' 曾另抄一份（12 种），而这里只认 @.arw@\/@.dng@ 两种——两份
-- 各自演进、谁也不通知谁，正是 codex 二十五轮 #5 的根因：尼康\/佳能\/富士\/
-- 奥林巴斯的卡插进 @pm sort@，每一个 raw 都被判成 'KindMeta' 而**静默忽略**，
-- 连"照片 N 个"的计数里都不出现，用户看到的是"照片 0 个"。
--
-- 同一份知识出现两处就迟早会分叉，所以这里不是"补几个扩展名"，而是把定义
-- 收成一处、让 'Pm.Versions' 引用它。
--
-- 判据③（'Pm.Versions'）问的是"这一帧有没有 RAW 工作流"：有 → 同名 JPG 是
-- 导出件，放进 Raw 层是误放，要报；没有 → 那个 JPG 本身就是原片（相机直出
-- JPG／手机拍的／RAW 已遗失后用能找到的 JPG 顶替——用户 2026-08-25 指出的
-- 三种情况，共同特征正是"没有对应的 RAW"）。列表以本库实测为准（Raw 层
-- arw 3794 · dng 71）并补齐常见机型格式；@psd@\/@psb@\/@tif@ 是**编辑**
-- 格式不是原始档，不计入——它们的存在不能说明这一帧有 RAW。
rawExts :: [String]
rawExts =
  [".arw", ".dng", ".nef", ".cr2", ".cr3", ".raf", ".orf", ".rw2", ".pef", ".srw", ".sr2", ".x3f"]

-- | 已渲染\/已编辑的位图。@.psb@ 是 @.psd@ 的大文件变体（同一个 Photoshop
-- 家族），此前只认 @.psd@ 是同一处遗漏。
renderExts :: [String]
renderExts = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".psd", ".psb", ".heic"]

-- | 调色参数等随主文件走的附属文件。
sidecarExts :: [String]
sidecarExts = [".xmp", ".acr"]

-- | Extension classification is case-folded everywhere: the real library mixes
-- @.jpg@/@.JPG@ about half and half (DESIGN.md §1.1).
classifyExt :: FilePath -> FileKind
classifyExt ext
  | e `elem` rawExts = KindPhoto
  | e `elem` renderExts = KindPhoto
  | e `elem` sidecarExts = KindSidecar
  | otherwise = KindMeta
 where
  e = map toLower ext

-- | One indexed file. @enPath@ is relative to its root, native separators.
-- @enMtimeNs@ is whatever this root's own stat returned — it is a cache
-- invalidation key local to the root and is never compared across roots
-- (DESIGN.md §3).
data Entry = Entry
  { enPath :: FilePath
  , enSize :: Integer
  , enMtimeNs :: Integer
  , enSha :: Text
  , enKind :: FileKind
  , enLastVerified :: Maybe UTCTime
    -- ^ 上次真实重读并核对 sha 的时刻（I3b 介质级验证轮转的依据）。
    -- 旧快照缺此字段 → 载入时回填快照的 scanned 时间（Catalog.loadCatalog）。
  }
  deriving (Show, Eq)

instance ToJSON Entry where
  toJSON e = object
    [ "path" .= enPath e
    , "size" .= enSize e
    , "mtimeNs" .= enMtimeNs e
    , "sha256" .= enSha e
    , "kind" .= enKind e
    , "lastVerified" .= enLastVerified e
    ]

instance FromJSON Entry where
  parseJSON = withObject "Entry" $ \o ->
    Entry
      <$> o .: "path"
      <*> o .: "size"
      <*> o .: "mtimeNs"
      <*> o .: "sha256"
      <*> o .: "kind"
      <*> o .:? "lastVerified"

-- | Snapshot of one root. The snapshot is a rebuildable cache; the journal is
-- the durable layer (DESIGN.md §3). Entries are serialized as a list and
-- re-keyed on load.
data Catalog = Catalog
  { catRootId :: Text
  , catScanned :: UTCTime
  , catEntries :: Map FilePath Entry
  }
  deriving (Show, Eq)

instance ToJSON Catalog where
  toJSON c = object
    [ "rootId" .= catRootId c
    , "scanned" .= catScanned c
    , "entries" .= Map.elems (catEntries c)
    ]

instance FromJSON Catalog where
  parseJSON = withObject "Catalog" $ \o -> do
    rid <- o .: "rootId"
    ts <- o .: "scanned"
    es <- o .: "entries"
    pure (Catalog rid ts (entryMap es))

entryMap :: [Entry] -> Map FilePath Entry
entryMap es = Map.fromList [(enPath e, e) | e <- es]
