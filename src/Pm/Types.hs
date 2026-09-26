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
  , renderExts
  , albumTop
  , processedTop
  , entryMap
  , stripBom
  , subpathOk
  , blankPathArg
  , workersOk
  , driveWaitOk
  , showHuman
  ) where

import Data.Aeson
import Data.Char (isControl, isSpace, toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
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
    _ -> fail ("unknown root role: " <> showHuman (T.unpack t))

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
    _ -> fail ("unknown file kind: " <> showHuman (T.unpack t))

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

-- | 三层库里两个层的目录名（DESIGN.md §1.1 的拓扑）。**全项目唯一一份定义**，
-- 与 'rawExts' 同一理由：相册通道（'Pm.Album'）、转换落位（'Pm.Convert'）、
-- 归档页取图（'Pm.ServeAi'）与 I7 判定（'Pm.Doctor'）问的是同一个「哪一层」。
-- 住在 'Pm.Types' 而不是 'Pm.Album'，是因为 'Pm.Doctor' 也要它而 'Pm.Album'
-- 经 'Pm.Cli' 反过来依赖 Doctor（同 'Pm.Derived' 拆出的那个环）；'Pm.Album'
-- 按原名再导出，既有调用点一字不改。
albumTop, processedTop :: FilePath
albumTop = "相册"
processedTop = "成片"

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

-- | 去掉文本开头的**一个** UTF-8 BOM（U+FEFF）。用户手编、pm 解析的文本文件（config.toml、.gitignore）
-- 被 PowerShell 5.1 的 @Set-Content -Encoding UTF8@ 或记事本「UTF-8 with BOM」存过就带它（横切审计 #66 /
-- 审计 #41：此前 config.toml 带 BOM 让每条 pm 命令起不来，.gitignore 带 BOM 让首行 @.pm/@ 不算数）。
-- 只认开头一个，与 git 的 skip_utf8_bom 同口径；中间的 U+FEFF 原样保留。
stripBom :: Text -> Text
stripBom t = maybe t id (T.stripPrefix "\xFEFF" t)

-- | 用户给的路径参数是否为空白（横切审计 #84 的类）：@makeAbsolute ""@ 答当前工作目录，空串一路
-- 下去就被当成「当前目录」——@pm init --main ""@ 把 cwd 初始化成主库、@pm backup init ""@ 在 cwd 建
-- 备份身份、@pm sort ""@ 盘点 cwd。入口一律先拒（存在性检查挡不住：cwd 总是存在的目录）。
blankPathArg :: FilePath -> Bool
blankPathArg = all isSpace

-- | 值域的唯一定义（审计 #14）：并发数 1..64、掉线等待 0..86400 秒（0 = 关闭瞬断保护）。此前只在
-- @checkPatch@ 一处，@pm init --workers@ / @pm scan --workers@ / @pm backup --workers@ 与手编配置都绕过它。
-- 用在：命令行解析（'Pm.Cli.parseWorkers'）、配置写口（'Pm.ConfigEdit.checkConfig'）、消费侧
-- （@runScanCmd@ 拒手编越界值）、展示（@pm config@ 标 ⚠）。
workersOk :: Int -> Bool
workersOk w = w >= 1 && w <= 64

driveWaitOk :: Int -> Bool
driveWaitOk d = d >= 0 && d <= 86400

-- | 备份 subpath 的形状（审计 #27）：空串（盘根镜像）或盘内相对路径——不含 @:@（盘符 / 盘相对）、不以
-- 分隔符开头（带根 / UNC），没有 @.@ \/ @..@ 分量。重复或结尾的分隔符无害（@</>@ 之后 Windows 照常解析），
-- 不拦。'Pm.ConfigEdit.checkConfig'（写口）与 'Pm.Backup.discoverBackupRoots'（发现）共用。
subpathOk :: FilePath -> Bool
subpathOk s =
  null s
    || ( notElem ':' s
          && take 1 s `notElem` ["\\", "/"]
          && all (\comp -> comp `notElem` [".", ".."]) (splitSeps s)
       )
 where
  splitSeps x = case break (`elem` ("\\/" :: String)) x of
    (a, []) -> [a]
    (a, _ : rest) -> a : splitSeps rest

-- | 给人看的带引号文本（横切审计 #69 的类）：像 'show' 一样加引号、把控制符写成转义，但**不**转义
-- 可打印的非 ASCII（'show' 把「杭州」打成 @\\26477\\24030@，用户认不出、也复制不了），也不转义反斜杠
-- （Windows 路径照原样读）。报错与状态行里引用用户的名字 \/ 路径 \/ 手编值一律用它，不用 'show'。
showHuman :: String -> String
showHuman s = "\"" <> concatMap esc s <> "\""
 where
  esc c
    | isControl c = init (drop 1 (show [c]))
    | otherwise = [c]
