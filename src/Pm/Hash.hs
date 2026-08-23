{-# LANGUAGE BangPatterns #-}

-- | Streaming SHA-256 (crypton) plus the double-stat consistency check used
-- by scan (DESIGN.md §6.7: files being written concurrently are marked
-- volatile instead of being indexed with a possibly-torn hash).
module Pm.Hash
  ( sha256File
  , StatSnap (..)
  , statSnap
  ) where

import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import System.Directory (getFileSize, getModificationTime)
import System.IO

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
