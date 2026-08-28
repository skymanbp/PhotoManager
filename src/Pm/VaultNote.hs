{-# LANGUAGE OverloadedStrings #-}

-- | 照片记录（P8-C，DESIGN-P8.md §21）：GUI 里 AI 给出、用户确认过的类目 / 地点 /
-- 坐标 / 标题。photos.json 不在 pm 写域（DESIGN-COMMANDS §10.2；I9 同款边界），
-- 这些信息的去处是一条**主库侧的本地记录** @.pm\/vault-notes.json@——与
-- 「暂不同步」名单 ('Pm.VaultHold') 同一纪律：同一份文件读写壳（缺席 = 空、
-- .tmp 残留 \/ 解析失败 \/ 语义非法 = 硬错）、同一 sha 新鲜度（记录时的 sha 存进
-- 记录，字节变了记录失效 @stale@）、同一事务壳（'Pm.VaultCmd.withVaultTxn'）。
-- vault 仓零改动；@\/photo-publish@ 技能只读 @pm vault notes --json@ 的
-- @pending@ 条目去写 photos.json，pm 不知道也不该知道 Pages 基址。
module Pm.VaultNote
  ( VaultNote (..)
  , NoteFields (..)
  , noteObject
  , notesFileName
  , noteSources
  , parseCoordinates
  , normalizeFields
  , hasFields
  , renderFields
  , noteFieldErrors
  , validateNotes
  , readNotes
  , writeNotes
  , applyNoteOps
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (Object), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Pair)
import Data.Char (isControl)
import Data.List (intercalate, sortOn)
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Time (UTCTime)

import Pm.VaultCore (fixedCategories)
import Pm.VaultHold (applyRecordOps, readPmRecords, validateKeyed, writePmRecords)

-- | 一条记录：名字（相册里的平铺 basename，与六态分类同键）+ 记录时的 sha +
-- 用户确认的字段 + 时间。
data VaultNote = VaultNote
  { vnName :: FilePath
  , vnSha :: Text
  , vnFields :: NoteFields
  , vnAt :: UTCTime
  }
  deriving (Show, Eq)

-- | 可记录的字段：全部可缺省，但至少要有一项（'hasFields'）。@source@ 是
-- 来源标签（'noteSources'），CLI 缺省 @user@，GUI 按 AI 把握传 @ai-*@。
data NoteFields = NoteFields
  { nfCategory :: Maybe String
  , nfLocation :: Maybe Text
  , nfCoordinates :: Maybe Text
  , nfTitle :: Maybe Text
  , nfSource :: Text
  }
  deriving (Show, Eq)

-- | 记录的 JSON 键（文件里与 @notes --json@ 里同一形状；后者再追加 status 等）。
noteObject :: VaultNote -> [Pair]
noteObject n =
  [ "name" .= vnName n
  , "sha" .= vnSha n
  , "category" .= nfCategory f
  , "location" .= nfLocation f
  , "coordinates" .= nfCoordinates f
  , "title" .= nfTitle f
  , "source" .= nfSource f
  , "at" .= vnAt n
  ]
 where
  f = vnFields n

instance ToJSON VaultNote where
  toJSON = object . noteObject

instance FromJSON VaultNote where
  parseJSON = withObject "VaultNote" $ \o ->
    VaultNote <$> o .: "name" <*> o .: "sha" <*> parseJSON (Object o) <*> o .: "at"

-- | 字段从对象里平铺读出；@source@ 缺省 @user@（文件里总是写全的，缺省只为
-- API 请求体服务）。
instance FromJSON NoteFields where
  parseJSON = withObject "NoteFields" $ \o ->
    NoteFields
      <$> o .:? "category"
      <*> o .:? "location"
      <*> o .:? "coordinates"
      <*> o .:? "title"
      <*> (fromMaybe "user" <$> o .:? "source")

-- | @.pm@ 下的文件名。
notesFileName :: FilePath
notesFileName = "vault-notes.json"

-- | 允许的来源标签（DESIGN-P8 §21.1）。
noteSources :: [Text]
noteSources = ["exif", "ai-high", "ai-med", "ai-low", "user", "none"]

-- | @"<lat>, <lng>"@ → (lat, lng)：两段都得是十进制数（可带符号），范围
-- −90..90 \/ −180..180；多段、少段、非数、越界都是 'Nothing'。
parseCoordinates :: Text -> Maybe (Double, Double)
parseCoordinates t = case T.splitOn "," t of
  [a, b] -> do
    lat <- num a
    lng <- num b
    if abs lat <= 90 && abs lng <= 180 then Just (lat, lng) else Nothing
  _ -> Nothing
 where
  num s = case TR.signed TR.double (T.strip s) of
    Right (v, rest) | T.null rest -> Just v
    _ -> Nothing

-- | 去首尾空白；空串 = 没给（GUI 的空输入框不该变成一条空字段）。
normalizeFields :: NoteFields -> NoteFields
normalizeFields f =
  f
    { nfCategory = strS =<< nfCategory f
    , nfLocation = strT =<< nfLocation f
    , nfCoordinates = strT =<< nfCoordinates f
    , nfTitle = strT =<< nfTitle f
    , nfSource = T.strip (nfSource f)
    }
 where
  strT t = let s = T.strip t in if T.null s then Nothing else Just s
  strS s = T.unpack <$> strT (T.pack s)

-- | 至少一项实质字段（source 只是标签，不算）。
hasFields :: NoteFields -> Bool
hasFields f = isJust (nfCategory f) || isJust (nfLocation f) || isJust (nfCoordinates f) || isJust (nfTitle f)

-- | 一行人类可读的字段摘要。
renderFields :: NoteFields -> String
renderFields f =
  intercalate " · " (catMaybes [nfCategory f, T.unpack <$> nfLocation f, T.unpack <$> nfCoordinates f, T.unpack <$> nfTitle f] <> [T.unpack (nfSource f)])

-- | 字段级校验，**全部**错误一次列完（GUI 能一次改完）。
noteFieldErrors :: NoteFields -> [String]
noteFieldErrors f =
  ["category 不在类目表里（" <> unwords fixedCategories <> "）: " <> c | Just c <- [nfCategory f], c `notElem` fixedCategories]
    <> ["coordinates 须形如「lat, lng」且在 -90..90 / -180..180 内: " <> T.unpack c | Just c <- [nfCoordinates f], parseCoordinates c == Nothing]
    <> [lbl <> " 超过 200 字符或含控制字符" | (lbl, Just v) <- [("location", nfLocation f), ("title", nfTitle f)], T.length v > 200 || T.any isControl v]
    <> ["source 不在 {" <> T.unpack (T.intercalate "," noteSources) <> "} 里: " <> T.unpack (nfSource f) | nfSource f `notElem` noteSources]
    <> ["没有给任何字段（category / location / coordinates / title 至少一项）" | not (hasFields f)]

-- | 整份记录的语义校验：与名单共用的三项（平铺名 \/ 64 hex sha \/ 名字唯一）
-- + 逐条字段校验。任一条不合法整体拒绝（同 'Pm.VaultHold.validateHolds'）。
validateNotes :: [VaultNote] -> Either String [VaultNote]
validateNotes ns = do
  validateKeyed "照片记录" vnName vnSha ns
  case [(vnName n, e) | n <- ns, e <- take 1 (noteFieldErrors (vnFields n))] of
    (n, e) : _ -> Left ("照片记录 " <> n <> " 字段非法: " <> e)
    [] -> Right (sortOn vnName ns)

readNotes :: FilePath -> IO (Either String [VaultNote])
readNotes = readPmRecords notesFileName validateNotes

-- | 调用方还须持主库 root lock（I10），见 'Pm.VaultCmd.withVaultTxn'。
writeNotes :: FilePath -> [VaultNote] -> IO (Either String ())
writeNotes = writePmRecords notesFileName validateNotes

-- | @adds@ 覆盖同名旧记录（sha 随之刷新——字节换过之后重新确认正是这个语义），
-- @dels@ 按名字删除。
applyNoteOps :: [VaultNote] -> [VaultNote] -> [FilePath] -> [VaultNote]
applyNoteOps = applyRecordOps vnName
