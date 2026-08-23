{-# LANGUAGE BangPatterns #-}

-- | Streaming SHA-256 (crypton) plus the double-stat consistency check used
-- by scan (DESIGN.md §6.7: files being written concurrently are marked
-- volatile instead of being indexed with a possibly-torn hash).
module Pm.Hash
  ( sha256File
  , copyFileHashed
  , StatSnap (..)
  , statSnap
  , nsToUtc
  ) where

import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import qualified Data.ByteString as BS
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import System.Directory (getFileSize, getModificationTime)
import System.IO

import Pm.Win (flushHandleToDisk)

chunkSize :: Int
chunkSize = 1024 * 1024

sha256File :: FilePath -> IO Text
sha256File fp = withBinaryFile fp ReadMode (go hashInit)
 where
  go :: Context SHA256 -> Handle -> IO Text
  go !ctx h = do
    b <- BS.hGetSome h chunkSize
    if BS.null b
      then pure (T.pack (show (hashFinalize ctx :: Digest SHA256)))
      else go (hashUpdate ctx b) h

-- | Stream src into dst while hashing, then FlushFileBuffers the destination
-- handle before returning (DESIGN.md §6.1 步 4+6.5: data durable before the
-- landing rename). dst is truncated if present — Exec only ever points this
-- at its own @.pm\/tmp\/@ files, never at user data.
copyFileHashed :: FilePath -> FilePath -> IO Text
copyFileHashed src dst =
  withBinaryFile src ReadMode $ \hs ->
    withBinaryFile dst WriteMode $ \hd -> do
      let go :: Context SHA256 -> IO Text
          go !ctx = do
            b <- BS.hGetSome hs chunkSize
            if BS.null b
              then do
                flushHandleToDisk hd
                pure (T.pack (show (hashFinalize ctx :: Digest SHA256)))
              else BS.hPut hd b >> go (hashUpdate ctx b)
      go hashInit

-- | Inverse of the truncation in 'statSnap' — exact (both sides are integers
-- over a fixed 10^9 denominator).
nsToUtc :: Integer -> UTCTime
nsToUtc ns = posixSecondsToUTCTime (fromRational (ns % 1_000_000_000))

data StatSnap = StatSnap
  { ssSize :: Integer
  , ssMtimeNs :: Integer
  }
  deriving (Show, Eq)

statSnap :: FilePath -> IO StatSnap
statSnap fp = do
  sz <- getFileSize fp
  mt <- getModificationTime fp
  -- NTFS stores 100 ns ticks; POSIXTime is picosecond-precise, so this
  -- truncation is lossless for every filesystem we can meet.
  let ns = truncate (utcTimeToPOSIXSeconds mt * 1_000_000_000) :: Integer
  pure (StatSnap sz ns)
