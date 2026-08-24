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
  , utcToNs
  , statHitStable
  ) where

import Control.Exception (bracket)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import qualified Data.ByteString as BS
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import System.Directory (getFileSize, getModificationTime)
import System.IO

import Pm.Win (flushHandleToDisk, openFreshBinary)

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
-- landing rename). dst 是 pm 自建的 @.pm\/tmp\/@ 文件，从不指向用户数据。
--
-- P3b-11（八轮复审 major，探针实证）：这里原先用 @WriteMode@（已存在即截断）。
-- tmp 名是确定性的，所以谁先把该名字做成库外文件的 hardlink，pm 一写就**覆盖
-- 了库外内容**（实测：库外文件真的变成 pm 写的字节）。hardlink 不是 reparse
-- point，逐级下降与 canonical 判定都看不见它。改用
-- 'Pm.Win.openFreshBinary'：先删掉同名残留（对 hardlink 只减一个目录项，
-- 库外原文件完好——实测），再 @CREATE_NEW@ 独占创建，中途被抢占即抛异常。
copyFileHashed :: FilePath -> FilePath -> IO Text
copyFileHashed src dst =
  withBinaryFile src ReadMode $ \hs ->
    bracket (openFreshBinary dst) hClose $ \hd -> do
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

utcToNs :: UTCTime -> Integer
utcToNs t = truncate (utcTimeToPOSIXSeconds t * 1_000_000_000)

-- | (size, mtime) 缓存命中的统一判据（P3b-4 评审 #4；scan 复用与 vault
-- shaViaCache 共用，消除各写各的分叉）。相等之外还要求条目不「racy」：
-- 上次真实 hash 的时刻必须晚于文件 mtime 至少一个最粗时间戳粒度的余量
-- （FAT/exFAT 2 s；NTFS 100 ns 一并覆盖）。同一 mtime 刻度内先 hash 后
-- 改写的文件 (size,mtime) 不变而内容已变，无此余量会永久信任陈旧 sha
-- （git racily-clean 同型问题）。lastVerified 缺失 → 不信任（fail-closed，
-- 重 hash 一次即回填）。
statHitStable :: Integer -> Integer -> Maybe UTCTime -> StatSnap -> Bool
statHitStable size mtimeNs mVerified snap =
  size == ssSize snap
    && mtimeNs == ssMtimeNs snap
    && case mVerified of
      Nothing -> False
      Just v -> utcToNs v - mtimeNs > racySlackNs

-- | 最粗常见文件系统（FAT 系）的时间戳粒度。
racySlackNs :: Integer
racySlackNs = 2_000_000_000

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
