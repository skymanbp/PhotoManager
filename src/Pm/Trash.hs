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
  , quarDirFor
  , quarTrashRel
  , appendManifest
  , readManifest
  , listTrashFiles
  , TrashView (..)
  , trashView
  ) where

import Control.Exception (IOException, try)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.FilePath ((</>))
import System.IO
import System.IO.Error (isDoesNotExistError)

import Pm.Config (pmDir)
import Pm.Op (OpIdSuffix (..), opIdParts, relPathOk)
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
-- 含 @~d@ 时会把普通隔离推到位移目录）。
--
-- 隔离落位目录由 planId + 后缀**构造**（Exec 用：oid 由内核生成，必合法）：
-- 普通隔离 @\<pid\>\/@，位移隔离 @\<pid\>~displaced-\<N\>\/@。
quarDirFor :: Text -> OpIdSuffix -> FilePath
quarDirFor pid (SfxDisplaced n) = T.unpack pid <> "~displaced-" <> show n
quarDirFor pid _ = T.unpack pid

-- | 从 oid **解析**后推导（doctor 用）：不合语法 → Nothing。P3b-7 复审 A1：
-- 不再回退到 @#@ 前缀——手编 journal 的畸形 oid 会被推到真实隔离目录、判成
-- Q-DONE-LOST 并被 --repair 补记 Done；解析不出就是 Bad，不猜。
quarTrashRel :: Text -> FilePath -> Maybe FilePath
quarTrashRel oid victim = (\(pid, _, sfx) -> quarDirFor pid sfx </> victim) <$> opIdParts oid

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
      -- P3b-8 六轮复审 major（同类统一修）：manifest 与 journal/plan 一样是可
      -- 手编输入，trTrashRel 会被拼到 .pm/trash 上且 **pm trash empty 按它
      -- unlink**——路径非法的记录按损坏行剔除（fail-closed），绝不参与删除。
      let ls = filter (not . BS.null) (BSC.lines raw)
          step (i :: Int) l = case eitherDecodeStrict l of
            Right r
              | not (relPathOk (trTrashRel r)) || not (relPathOk (trVictimRel r)) ->
                  Left ("manifest line " <> show i <> ": 相对路径非法（越界/盘符/ADS），记录已忽略（fail-closed）")
              | otherwise -> Right r
            Left e -> Left ("manifest line " <> show i <> ": " <> e)
          results = zipWith step [1 ..] ls
      pure ([r | Right r <- results], [w | Left w <- results])

-- | Every regular file below .pm/trash/, relative to it (manifest excluded).
--
-- P3b-10（七轮复审 major，实测）：**绝不跟随 reparse point**。探针证实
-- @.pm\/trash\/link@（junction → 库外目录）下 @doesDirectoryExist@ 为 True、
-- @listDirectory@ 穿透、@removeFile@ 会真的删掉库外文件——若递归进去，手编一条
-- @link\\v.jpg@ 的 manifest 记录就能让 @pm trash empty@ 认为该"隔离文件在库
-- 内"。链接本身作为条目列出（doctor 以 UNREGISTERED\/Q1 报出，人工核查），
-- 但其内容一律不进入清单。同 'Pm.Scan.listTree' \/ 'Pm.Exec.dirFingerprint'
-- 的既有策略。
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
    isLink <- linkish (base </> relPath)
    isDir <- doesDirectoryExist (base </> relPath)
    if isLink
      then pure [relPath] -- 链接本体记为条目，绝不递归
      else
        if isDir
          then go base relPath
          else pure [relPath | relPath /= "manifest.ndjson"]
  -- 探测异常（非「不存在」）按「是链接」处理：不递归即可，保守不误删
  linkish p = do
    r <- try (pathIsSymbolicLink p) :: IO (Either IOException Bool)
    pure (either (not . isDoesNotExistError) id r)

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
