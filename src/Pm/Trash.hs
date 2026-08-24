{-# LANGUAGE OverloadedStrings #-}

-- | The quarantine area (invariant I2): @\<root\>\/.pm\/trash\/\<planId\>\/\<relPath\>@
-- plus a write-ahead NDJSON manifest. 'pm trash empty' is the only place in
-- the whole program that unlinks user data, and it only unlinks entries the
-- user saw item-by-item in the confirmation list (DESIGN.md §6.3, review
-- conf-10 fix 2).
module Pm.Trash
  ( TrashRecord (..)
  , trashDir
  , manifestPath
  , quarTrashRel
  , appendManifest
  , readManifest
  , listTrashFiles
  , TrashView (..)
  , trashView
  ) where

import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO

import Pm.Config (pmDir)
import Pm.Op (OpIdSuffix (..), opIdParts)
import Pm.Win (flushHandleToDisk)

data TrashRecord = TrashRecord
  { trVictimRel :: FilePath -- original path relative to root
  , trTrashRel :: FilePath -- path relative to .pm/trash/
  , trSha :: Text
  , trReason :: Text
  , trPlanId :: Text
  , trAt :: UTCTime
  }
  deriving (Show, Eq)

instance ToJSON TrashRecord where
  toJSON r =
    object
      [ "victim" .= trVictimRel r
      , "trash" .= trTrashRel r
      , "sha256" .= trSha r
      , "reason" .= trReason r
      , "plan" .= trPlanId r
      , "at" .= trAt r
      ]

instance FromJSON TrashRecord where
  parseJSON = withObject "TrashRecord" $ \o ->
    TrashRecord
      <$> o .: "victim"
      <*> o .: "trash"
      <*> o .: "sha256"
      <*> o .: "reason"
      <*> o .: "plan"
      <*> o .: "at"

trashDir :: FilePath -> FilePath
trashDir root = pmDir root </> "trash"

manifestPath :: FilePath -> FilePath
manifestPath root = trashDir root </> "manifest.ndjson"

-- | opId → 隔离落位目录的唯一推导（Exec 与 doctor 共用，P3b-4 评审 #1）：
-- 普通隔离落 @\<planId\>\/\<victim\>@；组回滚的占位者位移隔离（opId 带
-- @~d\<N\>@ 后缀，N = 本次尝试序号）落 @\<planId\>~displaced-\<N\>\/\<victim\>@
-- —— 同一计划里 victim 本体已占用前者；带序号是因为同计划重跑可能再次
-- 位移（P3b-5 复审 #1：固定目录会与上次位移残留撞车，moveFileNoReplace
-- 失败后复位再被挡住）。两侧不共用此函数就会各推各的。
-- P3b-6 复审 A1：后缀由 'opIdParts' 严格解析（不再 @splitOn "~d"@——planId
-- 含 @~d@ 时会把普通隔离推到位移目录）。非 pm 生成的 oid（手编 journal，
-- doctor 只读分类会遇到）退回普通隔离目录 @\<planId 前缀\>\/@。
quarTrashRel :: Text -> FilePath -> FilePath
quarTrashRel oid victim =
  let dir = case opIdParts oid of
        Just (pid, _, SfxDisplaced n) -> T.unpack pid <> "~displaced-" <> show n
        Just (pid, _, _) -> T.unpack pid
        Nothing -> T.unpack (T.takeWhile (/= '#') oid)
   in dir </> victim

-- | Write-ahead: flushed to disk before the victim moves (§6.3 step 1).
appendManifest :: FilePath -> TrashRecord -> IO ()
appendManifest root r = do
  createDirectoryIfMissing True (trashDir root)
  withBinaryFile (manifestPath root) AppendMode $ \h -> do
    BSL.hPut h (encode r)
    BSL.hPut h "\n"
    flushHandleToDisk h

readManifest :: FilePath -> IO ([TrashRecord], [String])
readManifest root = do
  let fp = manifestPath root
  exists <- doesFileExist fp
  if not exists
    then pure ([], [])
    else do
      raw <- BS.readFile fp
      let ls = filter (not . BS.null) (BSC.lines raw)
          step (i :: Int) l = case eitherDecodeStrict l of
            Right r -> Right r
            Left e -> Left ("manifest line " <> show i <> ": " <> e)
          results = zipWith step [1 ..] ls
      pure ([r | Right r <- results], [w | Left w <- results])

-- | Every regular file below .pm/trash/, relative to it (manifest excluded).
listTrashFiles :: FilePath -> IO [FilePath]
listTrashFiles root = do
  let base = trashDir root
  exists <- doesDirectoryExist base
  if not exists then pure [] else go base ""
 where
  go base rel = do
    let dirAbs = if null rel then base else base </> rel
    names <- listDirectory dirAbs
    fmap concat . mapM (walk base rel) $ names
  walk base rel name = do
    let relPath = if null rel then name else rel </> name
    isDir <- doesDirectoryExist (base </> relPath)
    if isDir
      then go base relPath
      else pure [relPath | relPath /= "manifest.ndjson"]

-- | Union view: manifest ∪ on-disk files (review conf-10: orphans surface as
-- UNREGISTERED instead of being invisible).
data TrashView = TrashView
  { tvRegistered :: [(TrashRecord, Bool)] -- (record, file still present?)
  , tvUnregistered :: [FilePath] -- on disk, no manifest record
  , tvWarnings :: [String]
  }

trashView :: FilePath -> IO TrashView
trashView root = do
  (records, warns) <- readManifest root
  files <- listTrashFiles root
  let fileSet = Map.fromList [(f, ()) | f <- files]
      registered = [(r, Map.member (trTrashRel r) fileSet) | r <- records]
      known = Map.fromList [(trTrashRel r, ()) | r <- records]
      unreg = [f | f <- files, not (Map.member f known)]
  pure (TrashView registered unreg warns)
