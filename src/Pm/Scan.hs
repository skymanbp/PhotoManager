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

-- | Relative paths of all regular files under root. Dot-directories (.pm,
-- .obsidian, .git …) and symlinks/reparse points are skipped; over-long paths
-- are reported as errors, not silently dropped.
listTree :: FilePath -> IO ([FilePath], [(FilePath, String)])
listTree root = go ""
 where
  go rel = do
    let dirAbs = if null rel then root else root </> rel
    names <- listDirectory dirAbs
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
                then
                  if take 1 (takeFileName name) == "."
                    then pure ([], [])
                    else go relPath
                else pure ([relPath], [])
    pure (concatMap fst results, concatMap snd results)

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
      split (rs, hs) se@(StatEntry rel snap) =
        case Map.lookup rel oldEntries of
          Just e
            | enSize e == ssSize snap && enMtimeNs e == ssMtimeNs snap ->
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
          else
            pure
              ( Right
                  Entry
                    { enPath = rel
                    , enSize = ssSize post
                    , enMtimeNs = ssMtimeNs post
                    , enSha = sha
                    , enKind = classifyExt (takeExtension rel)
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
