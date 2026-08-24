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

import Control.Exception (bracket)
import Control.Monad (foldM, when)
import Data.Aeson (eitherDecodeFileStrict, encode)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO (hClose)

import Pm.Config (pmDir)
import Pm.Op (userRelOk)
import Pm.Types
import Pm.Win (flushHandleToDisk, moveFileNoReplace, openFreshBinary)

catalogPath :: FilePath -> FilePath
catalogPath root = pmDir root </> "catalog.json"

-- | 语义非法（手编痕迹）的哨兵后缀：'loadCatalog' 用它区分"可回退的损坏"与
-- "整条链不可信"。
tamperMark :: String
tamperMark = "，快照拒绝载入 → pm scan 重建"

-- | Newest readable copy wins: catalog.json, then .1, then .2.
--
-- 两类失败必须区别对待（P3b-11，八轮复审 #4）：
--
--  * **半写\/损坏 JSON**（进程被杀在写盘中途）是可回退的——正是三代轮转要
--    救的场景，继续试 @.1@、@.2@。
--  * **语义非法**（条目路径越界\/指向 @.pm@）不是介质事故，是有人手编过这份
--    快照。此时回退到旧代等于"攻击者提供的快照被拒了，于是换一份继续干活"
--    ——backup 忽略 load warnings 拿 @.1@ 算 diff（'Pm.BackupCmd'），会漏备
--    base 才有的新文件。整条链**就地终止**，返回 Nothing：调用点一律
--    fail-closed 到"先 pm scan 重建"。
loadCatalog :: FilePath -> IO (Maybe Catalog, [String])
loadCatalog root = do
  let base = catalogPath root
      candidates = [base, base <> ".1", base <> ".2"]
  foldM step (Nothing, []) candidates
 where
  step acc@(Just _, _) _ = pure acc
  -- 语义非法已经终止过一次 → 后续代次不再尝试（哨兵：warns 末尾是拒绝理由）
  step acc@(Nothing, warns) fp
    | any (tamperMark `isSuffixOfStr`) warns = pure acc
    | otherwise = do
        exists <- doesFileExist fp
        if not exists
          then pure (Nothing, warns)
          else do
            r <- eitherDecodeFileStrict fp
            case r of
              -- P3b-10（七轮复审 major）：快照是可手编的 .pm 文件，而 enPath 会被拼成
              -- 绝对源路径喂给 backup/import 的 OpCopy（Pm.Diff/Pm.Import）并被 doctor
              -- --deep / clean 见证直接读取。P3b-11：校验从 relPathOk 收紧到
              -- userRelOk——".pm\journal.ndjson" 是完全合法的相对路径，却让
              -- opSrcAbs 指向 pm 自己的状态文件。真实库 4855 条目实测零违规。
              Right c
                | (bad : _) <- [enPath e | e <- Map.elems (catEntries c), not (userRelOk (enPath e))] ->
                    pure (Nothing, warns <> [fp <> ": 条目路径非法（" <> bad <> "）" <> tamperMark])
                | otherwise -> pure (Just (backfill c), warns)
              Left e -> pure (Nothing, warns <> [fp <> ": " <> e])
  isSuffixOfStr suf s = suf == drop (length s - length suf) s
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
  -- 独占创建（P3b-11，八轮复审 major）：固定名 + 截断写 = 预置 hardlink 就能
  -- 让这次写落到库外共享对象上（同 'Pm.Hash.copyFileHashed'）。
  bracket (openFreshBinary tmp) hClose $ \h -> do
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
