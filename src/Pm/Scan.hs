-- | Incremental scanner (DESIGN.md §4 Scan.hs): walk the tree, reuse catalog
-- entries whose (size, mtime) are unchanged, hash the rest with a worker
-- pool, and mark files that changed while being hashed as volatile instead of
-- indexing a possibly-torn hash (§6.7).
module Pm.Scan
  ( ScanOpts (..)
  , ScanResult (..)
  , StatEntry (..)
  , scanRoot
  , listTree
  , listTreeWith
  , DotDirs (..)
  , freshnessSweep
  , maxPathLen
  ) where

import Control.Concurrent.Async (replicateConcurrently_)
import Control.Exception (SomeException, try)
import Control.Monad (forM)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (takeExtension, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import Pm.Hash
import Pm.Types

-- | Full-path length guard (DESIGN.md §14 长路径预检): refuse early and
-- loudly instead of corrupting behaviour near MAX_PATH.
maxPathLen :: Int
maxPathLen = 240

data ScanOpts = ScanOpts
  { soWorkers :: Int
  , soProgress :: Bool
  }

data StatEntry = StatEntry
  { seRel :: FilePath
  , seSnap :: StatSnap
  }

data ScanResult = ScanResult
  { srCatalog :: Catalog
  , srReused :: Int
  , srHashed :: Int
  , srHashedBytes :: Integer
  , srVolatile :: [FilePath]
  , srErrors :: [(FilePath, String)]
  }

-- | 遍历时对**点开头的目录**的策略。
--
-- 这不是一个可以有默认值的细节，两种用法要的语义相反：
--
--  * 'SkipDotDirs' —— 库根。@.pm@ @.git@ @.obsidian@ 是元数据，不是照片，跳过
--    是对的，而且**不必报告**（每次扫描都报一遍纯属噪音）。
--  * 'WalkDotDirs' —— @pm sort@ 的源。那是**用户随手指的一个目录**（相机卡、
--    下载文件夹），里面点开头的目录只是普通文件夹，完全可能装着照片。
--
-- 把库根的策略原样搬到源目录上，结果是 @card\\.hidden\\a.ARW@ 连一条记录都不
-- 留地消失——既不进计划，也不进任何一格「交代」（codex 二十六轮 #3）。
data DotDirs = SkipDotDirs | WalkDotDirs
  deriving (Show, Eq)

-- | Relative paths of all regular files under root, with the library-root
-- policy ('SkipDotDirs'). Symlinks/reparse points are skipped and over-long
-- paths are reported as errors, not silently dropped.
listTree :: FilePath -> IO ([FilePath], [(FilePath, String)])
listTree = listTreeWith SkipDotDirs

listTreeWith :: DotDirs -> FilePath -> IO ([FilePath], [(FilePath, String)])
listTreeWith dots root = go ""
 where
  go rel = do
    let dirAbs = if null rel then root else root </> rel
        here = if null rel then "." else rel
    -- 列举失败（介质被拔、ACL、目录在遍历途中消失）必须变成一条**带路径的
    -- 错误**，而不是让异常穿出整条命令。源是可移动介质时这是常态而非异常：
    -- 异常逃出去，用户只看到一条堆栈，既不知道哪个目录出的问题，也拿不到
    -- 已经扫到的部分（codex 二十六轮 #4）。
    --
    -- 这里**不需要**额外强制列表：@listDirectory@ 的异常发生在
    -- @getDirectoryContents@ 执行期（IO 内部），不是消费列表时，@try@ 兜得住。
    -- 本轮一度加过一个 @length ns \`seq\`@ 并声称"惰性值逃出 try"——那个结论
    -- 来自一次读到**旧库**的探针（当时 pm.exe 在跑，@copy/register@ 失败，
    -- 探针跑的是加 try 之前的代码）。重新构建后有无该 seq 结果完全相同
    -- （@files=[] errs=["."]@），突变也证明它不承重，已删除：**没有依据的
    -- 防御性代码加上一条假注释，比不加更糟**。
    er <- try (listDirectory dirAbs) :: IO (Either SomeException [FilePath])
    case er of
      Left e -> pure ([], [(here, "目录列举失败: " <> show e)])
      Right names -> do
        results <- forM names $ \name -> do
          let relPath = if null rel then name else rel </> name
              abs' = root </> relPath
          if length abs' >= maxPathLen
            then pure ([], [(relPath, "path too long (>=240 chars)")])
            else do
              symRes <- try (pathIsSymbolicLink abs') :: IO (Either SomeException Bool)
              -- A failed symlink probe (ACL-denied etc.) is treated as
              -- "not a symlink" so the entry still gets stat'ed below and the
              -- real error surfaces there instead of being swallowed here.
              let isSym = either (const False) id symRes
              if isSym
                then pure ([], [(relPath, "symlink/reparse point skipped")])
                else do
                  isDir <- doesDirectoryExist abs'
                  if isDir
                    then case dots of
                      WalkDotDirs -> go relPath
                      SkipDotDirs
                        | take 1 (takeFileName name) == "." -> pure ([], [])
                        | otherwise -> go relPath
                    else pure ([relPath], [])
        pure (concatMap fst results, concatMap snd results)

-- | Stat-only freshness comparison of a directory tree against a catalog
-- slice keyed by root-relative paths. @relPrefix@ narrows the walk to one
-- subtree (\"\" = whole root); the catalog slice must be pre-filtered to the
-- same subtree by the caller. Returns (new, changed, gone, readErrors).
-- Shared by pm status（全库核对）与 import/clean 的暂存区守卫。
freshnessSweep :: FilePath -> FilePath -> Map.Map FilePath Entry -> IO (Int, Int, Int, Int)
freshnessSweep root relPrefix catSlice = do
  let base = if null relPrefix then root else root </> relPrefix
  ex <- doesDirectoryExist base
  (files, errs) <- if ex then listTree base else pure ([], [])
  snaps <- forM files $ \rel -> do
    r <- try (statSnap (base </> rel)) :: IO (Either SomeException StatSnap)
    pure (if null relPrefix then rel else relPrefix </> rel, r)
  let disk = Map.fromList [(rel, s) | (rel, Right s) <- snaps]
      newN = Map.size (disk `Map.difference` catSlice)
      goneN = Map.size (catSlice `Map.difference` disk)
      changedN =
        length
          [ ()
          | (rel, s) <- Map.toList disk
          , Just e <- [Map.lookup rel catSlice]
          , enSize e /= ssSize s || enMtimeNs e /= ssMtimeNs s
          ]
  pure (newN, changedN, goneN, length errs)

scanRoot :: ScanOpts -> Maybe Catalog -> Text -> FilePath -> IO ScanResult
scanRoot opts oldCat rootId root = do
  (files, walkErrs) <- listTree root
  -- Stat pass
  statted <- forM files $ \rel -> do
    r <- try (statSnap (root </> rel)) :: IO (Either SomeException StatSnap)
    pure (rel, r)
  let stats = [StatEntry rel s | (rel, Right s) <- statted]
      statErrs = [(rel, show e) | (rel, Left e) <- statted]
      oldEntries = maybe Map.empty catEntries oldCat
      (reused, toHash) = foldl' split ([], []) stats
      -- P3b-4 评审 #4（统一修）：复用判据走 statHitStable——(size,mtime)
      -- 相等之外还排除 racy 条目（hash 时刻与 mtime 同刻度窗口内），与
      -- Pm.Vault.shaViaCache 共用同一谓词。
      split (rs, hs) se@(StatEntry rel snap) =
        case Map.lookup rel oldEntries of
          Just e
            | statHitStable (enSize e) (enMtimeNs e) (enLastVerified e) snap ->
                (e : rs, hs)
          _ -> (rs, se : hs)
      totalHashBytes = sum [ssSize (seSnap se) | se <- toHash]
  progress
    ( printf
        "扫描 %s: %d 文件, 复用 %d, 待 hash %d (%.1f GiB), workers=%d"
        root
        (length files)
        (length reused)
        (length toHash)
        (gib totalHashBytes)
        (soWorkers opts)
    )
  -- Hash pass (worker pool over a shared queue)
  queue <- newIORef toHash
  done <- newIORef (0 :: Int, 0 :: Integer)
  out <- newIORef ([] :: [Entry], [] :: [FilePath], [] :: [(FilePath, String)])
  let pop = atomicModifyIORef' queue $ \q -> case q of
        [] -> ([], Nothing)
        (x : xs) -> (xs, Just x)
      worker = do
        item <- pop
        case item of
          Nothing -> pure ()
          Just (StatEntry rel preSnap) -> do
            r <- try (hashOne rel preSnap) :: IO (Either SomeException (Either FilePath Entry))
            atomicModifyIORef' out $ \(es, vs, errs) -> case r of
              Right (Right e) -> ((e : es, vs, errs), ())
              Right (Left v) -> ((es, v : vs, errs), ())
              Left ex -> ((es, vs, (rel, show ex) : errs), ())
            case r of
              Right (Right e) -> bump (enSize e)
              _ -> bump 0
            worker
      hashOne rel preSnap = do
        let abs' = root </> rel
        sha <- sha256File abs'
        post <- statSnap abs'
        if post /= preSnap
          then pure (Left rel) -- changed while hashing → volatile, not indexed
          else do
            vnow <- getCurrentTime
            pure
              ( Right
                  Entry
                    { enPath = rel
                    , enSize = ssSize post
                    , enMtimeNs = ssMtimeNs post
                    , enSha = sha
                    , enKind = classifyExt (takeExtension rel)
                    , enLastVerified = Just vnow
                    }
              )
      bump bytes = do
        (n, b) <- atomicModifyIORef' done $ \(n, b) ->
          let s = (n + 1, b + bytes) in (s, s)
        progressWhen (n `mod` 200 == 0) (printf "  … %d/%d 已 hash (%.1f GiB)" n (length toHash) (gib b))
  replicateConcurrently_ (max 1 (soWorkers opts)) worker
  (newEntries, volatiles, hashErrs) <- readIORef out
  now <- getCurrentTime
  let entries = entryMap (reused <> newEntries)
  pure
    ScanResult
      { srCatalog = Catalog rootId now entries
      , srReused = length reused
      , srHashed = length newEntries
      , srHashedBytes = sum (map enSize newEntries)
      , srVolatile = volatiles
      , srErrors = walkErrs <> statErrs <> hashErrs
      }
 where
  progress msg = progressWhen True msg
  progressWhen cond msg
    | soProgress opts && cond = hPutStrLn stderr msg
    | otherwise = pure ()

gib :: Integer -> Double
gib b = fromIntegral b / (1024 * 1024 * 1024)
