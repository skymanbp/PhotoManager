{-# LANGUAGE ScopedTypeVariables #-}

-- | Single-instance guard (invariant I10). Two layers of kernel-held
-- exclusion, both auto-released on process death, neither requiring the lock
-- FILE to ever be deleted (review finding unve-1):
--
-- 1. GHC's runtime already enforces cross-process single-writer file locking
--    (LockFileEx on Windows): a second writable open of @.pm\/lock@ throws
--    @resource busy@ before we even reach hTryLock. P1 实测（Spec.hs lock
--    test）就是这样失败的 — 该异常在这里被转译为「锁忙」。
-- 2. If the open succeeds (e.g. a filesystem where the implicit lock is
--    unavailable), 'hTryLock' provides the explicit guarantee.
module Pm.Lock
  ( withRootLock
  ) where

import Control.Exception (IOException, finally, throwIO, try)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hTryLock)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO
import System.IO.Error (isAlreadyInUseError)

import Pm.Config (pmDir, untrustedMsg)
import Pm.Win (openStateLock, resolveUnder)

-- | Run the action holding the root's exclusive mutation lock; Nothing if
-- another pm instance holds it.
--
-- P3b-14（十一轮）：锁文件也先过完整路径 'resolveUnder'。它本身不写字节，
-- 所以危害低于 journal\/manifest；纳入同一规则是为了让「@.pm@ 下的任何打开都
-- 先解析完整路径」成为**无例外**的陈述——留一个例外，下一轮就从那里进来。
-- P3b-15（十二轮 minor）：resolve 只认 symlink，认不出 hardlink——@.pm/lock@
-- 被 hardlink 到库外文件时 pm 会锁住那个共享对象（跨库互斥\/对外部程序的
-- DoS）。改用 'openStateLock'：打开后在句柄上查 link count，同句柄 hTryLock。
withRootLock :: FilePath -> IO a -> IO (Maybe a)
withRootLock root act = do
  createDirectoryIfMissing True (pmDir root)
  ml <- resolveUnder root (".pm" </> "lock")
  lockFp <- case ml of
    Nothing -> ioError (userError (untrustedMsg (pmDir root </> "lock")))
    Just fp -> pure fp
  -- ReadWriteMode inside: creates the file if missing, never truncates.
  r <- try (openStateLock lockFp)
  case r of
    Left (e :: IOException)
      | isAlreadyInUseError e -> pure Nothing
      | otherwise -> throwIO e
    Right h ->
      ( do
          ok <- hTryLock h ExclusiveLock
          if ok then Just <$> act else pure Nothing
      )
        `finally` hClose h
