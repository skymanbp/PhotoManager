-- | Catalog snapshot persistence: atomic replace + real disk flush + 3-copy
-- rotation (DESIGN.md §3). The snapshot is pm-owned state, rebuildable by a
-- rescan — the rotation below is the one place outside @pm trash empty@ where
-- pm unlinks a file, and it only ever touches its own oldest snapshot copy,
-- never user data.
module Pm.Catalog
  ( loadCatalog
  , saveCatalog
  , catalogPath
  ) where

import Control.Monad (foldM, when)
import Data.Aeson (eitherDecodeFileStrict, encode)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withBinaryFile)

import Pm.Config (pmDir)
import Pm.Op (relPathOk)
import Pm.Types
import Pm.Win (flushHandleToDisk, moveFileNoReplace)

catalogPath :: FilePath -> FilePath
catalogPath root = pmDir root </> "catalog.json"

-- | Newest readable copy wins: catalog.json, then .1, then .2.
loadCatalog :: FilePath -> IO (Maybe Catalog, [String])
loadCatalog root = do
  let base = catalogPath root
      candidates = [base, base <> ".1", base <> ".2"]
  foldM step (Nothing, []) candidates
 where
  step acc@(Just _, _) _ = pure acc
  step (Nothing, warns) fp = do
    exists <- doesFileExist fp
    if not exists
      then pure (Nothing, warns)
      else do
        r <- eitherDecodeFileStrict fp
        case r of
          -- P3b-10（七轮复审 major）：快照是可手编的 .pm 文件，而 enPath 会被拼成
          -- 绝对源路径喂给 backup/import 的 OpCopy（Pm.Diff/Pm.Import）并被 doctor
          -- --deep / clean 见证直接读取。词法非法的条目 = 有人改过快照：整份拒绝
          -- （快照是可由 pm scan 重建的缓存，fail-closed 的代价只是重扫）。
          -- 真实库 4855 条目实测零违规，正常使用不会触发。
          Right c
            | (bad : _) <- [enPath e | e <- Map.elems (catEntries c), not (relPathOk (enPath e))] ->
                pure (Nothing, warns <> [fp <> ": 条目路径非法（" <> bad <> "），快照拒绝载入 → pm scan 重建"])
            | otherwise -> pure (Just (backfill c), warns)
          Left e -> pure (Nothing, warns <> [fp <> ": " <> e])
  -- 旧快照的条目缺 lastVerified → 该 sha 正是那次扫描真实读盘算出的，
  -- 用快照时间作为验证基线。
  backfill c =
    c
      { catEntries =
          fmap
            (\e -> if enLastVerified e == Nothing then e {enLastVerified = Just (catScanned c)} else e)
            (catEntries c)
      }

saveCatalog :: FilePath -> Catalog -> IO ()
saveCatalog root cat = do
  createDirectoryIfMissing True (pmDir root)
  let base = catalogPath root
      tmp = base <> ".tmp"
  withBinaryFile tmp WriteMode $ \h -> do
    BSL.hPut h (encode cat)
    flushHandleToDisk h
  -- Rotate: keep 3 generations. Oldest copy is discarded by design (snapshot
  -- is a cache; the journal is the durable layer).
  removeIfExists (base <> ".2")
  renameIfExists (base <> ".1") (base <> ".2")
  renameIfExists base (base <> ".1")
  moveFileNoReplace tmp base

removeIfExists :: FilePath -> IO ()
removeIfExists fp = do
  exists <- doesFileExist fp
  when exists (removeFile fp)

renameIfExists :: FilePath -> FilePath -> IO ()
renameIfExists src dst = do
  exists <- doesFileExist src
  when exists (moveFileNoReplace src dst)
