{-# LANGUAGE BangPatterns #-}

-- | Streaming SHA-256 (crypton) plus the double-stat consistency check used
-- by scan (DESIGN.md §6.7: files being written concurrently are marked
-- volatile instead of being indexed with a possibly-torn hash).
module Pm.Hash
  ( sha256File
  , sha256Handle
  , copyFileHashed
  , StatSnap (..)
  , statSnap
  , nsToUtc
  , utcToNs
  , statHitStable
  , ContentProbe (..)
  , probeConfined
  , anyCopyAliveExcept
  ) where

import Control.Exception (IOException, bracket, try)
import Crypto.Hash (Context, Digest, SHA256, hashFinalize, hashInit, hashUpdate)
import qualified Data.ByteString as BS
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import System.Directory (getFileSize, getModificationTime)
import System.IO.Error (isDoesNotExistError)
import System.IO

import Pm.Win (FileId, flushHandleToDisk, handleFileId, openBoundTo, openFreshBinary, resolveUnder)

chunkSize :: Int
chunkSize = 1024 * 1024

-- | 「去盘上看一眼某个库内相对路径的内容」的结果。
--
-- 四态而不是 @Maybe@：**缺席**与**读不到**必须分开。把两者都塌缩成"没有"，
-- 调用方就会把一个 ACL 拒绝当成"文件不在了"——两个结论的安全方向恰好相反
-- （缺席 → 照搬\/照删；读不到 → 保守拒绝）。codex 二十六轮 #2。
data ContentProbe
  = -- | 读到的内容 sha **与该文件对象的身份**。身份是判断"这是不是另一份
    -- 独立副本"的唯一正确依据（codex 二十八轮 #2）。
    CpSha Text FileId
  | -- | 路径解析后不存在
    CpMissing
  | -- | 中途有 reparse point\/别名，解析结果逃出 root
    CpEscaped
  | -- | 存在但读不了（权限、占用、介质错误）
    CpUnreadable String
  deriving (Show, Eq)

-- | 重读 @root@ 内某个**相对路径**的内容并算 sha——先**逐级限域**再打开。
--
-- 校验性读取此前是直接 @root \</\> rel@ 就打开，两处各写一遍
-- （@Pm.Clean.anyWitnessAlive@ 与 @Pm.Sort.verifySkips@）。那正是本项目已经
-- 用三轮评审收拾过的反模式：库内任何一层是 junction 时，被"验证"的其实是
-- **库外**的文件，而这个结论会被当成「副本还在」（@pm clean staging@ 据此
-- 永久删除）或「已归档，不用搬」（@pm sort@ 据此跳过）。两个调用点共用这一处，
-- 免得再分叉（codex 二十六轮 #1）。
--
-- 形态与 'Pm.Config.readPmState' **逐字一致**，因为要治的是同三件事：
-- 完整相对路径 'resolveUnder' → **只打开一次** → 在句柄上查 link count →
-- 从**同一句柄**读完。第一版这里是 @getFileSize@ 探一次存在性、再按名字
-- @sha256File@ 打开第二次——「校验的对象」与「读的对象」又成了两次独立解析，
-- 正是本项目十一\/十二\/十三轮反复收拾的那个形状（codex 二十七轮 #1）。
--
-- link count \> 1 一并拒绝：'resolveUnder' 原理上看不见 hardlink，而这个判定
-- 的下游一边是「三副本齐了，可以永久删」——三份副本必须是三个**独立对象**，
-- 同一个对象出现在两个名字下不算两份。
--
-- 只捕 'IOException'：@SomeException@ 会把 @UserInterrupt@\/@ThreadKilled@
-- 一起吞掉，让 Ctrl-C 变成一条"读不到"。@isDoesNotExistError@ 把**缺席**从
-- 其余错误里分出来——两者安全方向相反，塌缩成一个答案就等于把 ACL 拒绝
-- 当成"文件不在了"（codex 二十七轮 #2：独占打开触发的
-- @ERROR_SHARING_VIOLATION@ 此前被判成 'CpMissing'）。
probeConfined :: FilePath -> FilePath -> IO ContentProbe
probeConfined root rel = do
  m <- resolveUnder root rel
  case m of
    Nothing -> pure CpEscaped
    Just fp -> do
      r <-
        try
          ( bracket (openBoundTo ReadMode fp) hClose $ \h -> do
              -- 身份先取：'sha256Handle' 会把句柄读到 EOF。两者同一句柄。
              mfid <- handleFileId h
              sha <- sha256Handle h
              pure (mfid, sha)
          ) ::
          IO (Either IOException (Maybe FileId, Text))
      pure $ case r of
        Right (Just fid, sha) -> CpSha sha fid
        -- 取不到身份就无法判断它是不是另一份独立副本 → fail-closed。
        Right (Nothing, _) -> CpUnreadable "取不到文件身份（GetFileInformationByHandle 失败）"
        Left e
          | isDoesNotExistError e -> CpMissing
          | otherwise -> CpUnreadable (show e)

-- | 「这批库内相对路径里，至少有一条现在真的读得出期望的 sha」。
--
-- 判定本身很短，却是 pm 里**两处永久性决定**的共同依据：@pm clean staging@
-- 的三副本屏障（下游是 @pm trash empty@ 的唯一 unlink）与 @pm dedupe@ 的
-- 「至少留一份」屏障。两处各写一遍循环，就会有一处忘了走 'probeConfined'——
-- 本项目已经为这条反模式开过三轮评审（二十六轮 #1、二十七轮 #1），所以连
-- **循环**也收在这里，而不是只共用 'probeConfined'。
--
-- fail-closed：只有 'CpSha' 且**等于**期望值才算数。缺席、逃出 root、读不到
-- （占用\/ACL\/介质错误）一律不算——"读不到"绝不能被当成"还在"。
anyCopyAliveExcept :: FilePath -> Text -> [FileId] -> [FilePath] -> IO (Maybe FileId)
anyCopyAliveExcept root sha excl = go
 where
  go [] = pure Nothing
  go (rel : rest) = do
    p <- probeConfined root rel
    case p of
      -- 内容相符**且**不是即将被移走的那个对象本身。同一个对象出现在两个
      -- 名字下不是两份副本——这一条此前由 link count 代劳，现在按身份直判，
      -- 于是合法的 hardlink 不再被误拒（codex 二十八轮 #2）。
      CpSha actual fid | actual == sha, fid `notElem` excl -> pure (Just fid)
      _ -> go rest

sha256File :: FilePath -> IO Text
sha256File fp = withBinaryFile fp ReadMode sha256Handle

-- | 从**已打开的句柄**流式 hash（P3b-15，十二轮 major）：doctor 对 @.pm\/trash@
-- 载荷的核 sha 必须「先在句柄上判定 link count、再从同一句柄读」——按名字重开
-- 会让校验与读取变成两次独立解析（正是十一轮那类缺口）。
sha256Handle :: Handle -> IO Text
sha256Handle = go hashInit
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
