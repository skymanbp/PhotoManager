{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- 评审 mn-1：x86 上 Windows API 是 stdcall，x86_64 上两者同一 ABI。
-- 与 Win32 包同款的 CPP 宏保证 32 位构建也不会栈失衡。
#if defined(i386_HOST_ARCH)
#define WINDOWS_CCONV stdcall
#else
#define WINDOWS_CCONV ccall
#endif

-- | The only module that talks to Win32 directly. Everything here exists
-- because the portable API has the wrong semantics on Windows (DESIGN.md §6,
-- §14):
--
--  * @directory@'s @renamePath\/renameFile\/copyFile@ pass
--    @MOVEFILE_REPLACE_EXISTING@ and silently destroy an existing target —
--    banned in this codebase; use 'moveFileNoReplace'.
--  * @hFlush@ only pushes handle buffers to the OS; 'flushHandleToDisk' is the
--    real persistence barrier (FlushFileBuffers).
--  * GHC inherits the ANSI codepage (CP936 here) for stdout and crashes on
--    the first un-encodable glyph; 'setupConsole' fixes the process to UTF-8.
--  * Backup-drive discovery (DESIGN.md §9) needs GetDriveTypeW \/
--    SetErrorMode \/ GetVolumeInformationW, none of which Win32-2.14.1.0
--    binds — declared via FFI below.
module Pm.Win
  ( setupConsole
  , flushHandleToDisk
  , moveFileNoReplace
  , pathUnder
  , suppressCriticalErrorDialogs
  , DriveKind (..)
  , listCandidateDrives
  , volumeFsType
  ) where

import Control.Exception (SomeException, catch, try)
import Control.Monad (when)
import Data.Bits (testBit)
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, nullPtr)
import System.Directory (canonicalizePath)
import System.FilePath (splitDirectories)
import System.IO
import qualified System.Win32.Console as Win32Console
import qualified System.Win32.File as Win32File
import System.Win32.Types (LPTSTR, peekTString, withHandleToHANDLE, withTString)

-- | Must run before any output (DESIGN.md §14 编码风险).
setupConsole :: IO ()
setupConsole = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  tty <- hIsTerminalDevice stdout
  when tty $
    Win32Console.setConsoleOutputCP 65001
      -- Swallowed because: only reachable on exotic console hosts where the
      -- call itself fails; the sole consequence is garbled glyph display,
      -- never data corruption, and aborting pm over it would be worse.
      `catch` \(_ :: SomeException) -> pure ()

-- | hFlush + FlushFileBuffers: contents durable on media when this returns
-- (modulo hardware that lies; see doctor matrix row C4).
flushHandleToDisk :: Handle -> IO ()
flushHandleToDisk h = do
  hFlush h
  withHandleToHANDLE h Win32File.flushFileBuffers

-- | Rename with flags = 0: same-volume move that FAILS if the destination
-- exists (ERROR_ALREADY_EXISTS surfaces as an IOException). This is the only
-- rename primitive Exec-side code may use (invariant I5).
moveFileNoReplace :: FilePath -> FilePath -> IO ()
moveFileNoReplace src dst = Win32File.moveFileEx src (Just dst) 0

-- | @pathUnder base p@ = @p@ **解析后**是否严格落在 @base@ 之内。
--
-- P3b-10（七轮复审 major，实测）：词法校验（'Pm.Op.relPathOk'）看不见
-- junction\/symlink——探针证实 @.pm\/trash\/link@ 指向库外目录时
-- @doesDirectoryExist@ 为 True、@listDirectory@ 穿透、@removeFile@ 会
-- **真的删掉库外文件**。'canonicalizePath' 让操作系统回答"这条路径究竟指向
-- 哪里"：跟随 reparse point、消解 @..@、补齐大小写与 8.3 短名，因此同时覆盖
-- 大小写别名、尾随点、junction 与任何未预见的等价名。
--
-- 任一侧解析失败（路径不存在、ACL 拒绝、名字非法）一律 False —— 这是
-- fail-closed：调用点用它守卫**删除\/写入**，答不上来就不动。
pathUnder :: FilePath -> FilePath -> IO Bool
pathUnder base p = do
  eb <- try (canonicalizePath base) :: IO (Either SomeException FilePath)
  ep <- try (canonicalizePath p) :: IO (Either SomeException FilePath)
  pure $ case (eb, ep) of
    (Right b, Right q) ->
      let bs = comps b
          qs = comps q
       in length qs > length bs && take (length bs) qs == bs
    _ -> False
 where
  -- NTFS 不分大小写：比较前统一折叠（同 Pm.Op.normComp 的大小写策略）
  comps = map (map toLower) . splitDirectories

-- ─── Backup-drive discovery primitives (§9) ─────────────────────────────────

foreign import WINDOWS_CCONV unsafe "windows.h SetErrorMode"
  c_SetErrorMode :: Word32 -> IO Word32

foreign import WINDOWS_CCONV unsafe "windows.h GetDriveTypeW"
  c_GetDriveTypeW :: LPTSTR -> IO Word32

foreign import WINDOWS_CCONV unsafe "windows.h GetVolumeInformationW"
  c_GetVolumeInformationW ::
    LPTSTR -> LPTSTR -> Word32 -> Ptr Word32 -> Ptr Word32 -> Ptr Word32 -> LPTSTR -> Word32 -> IO Word32

-- | SEM_FAILCRITICALERRORS: probing an empty card-reader slot must fail with
-- an error code, not pop a system "请插入磁盘" dialog (DESIGN.md §9).
suppressCriticalErrorDialogs :: IO ()
suppressCriticalErrorDialogs = () <$ c_SetErrorMode 0x0001

data DriveKind = DriveRemovable | DriveFixed
  deriving (Show, Eq)

-- | Letters of present REMOVABLE\/FIXED volumes. Network\/CD\/RAM volumes are
-- never probed for backup roots (§9). Call 'suppressCriticalErrorDialogs'
-- once beforehand.
listCandidateDrives :: IO [(Char, DriveKind)]
listCandidateDrives = do
  mask <- Win32File.getLogicalDrives
  let letters = [toEnum (fromEnum 'A' + i) | i <- [0 .. 25], testBit mask i]
  concat <$> mapM probe letters
 where
  probe c = do
    t <- withTString (c : ":\\") c_GetDriveTypeW
    pure $ case t of
      2 -> [(c, DriveRemovable)] -- DRIVE_REMOVABLE
      3 -> [(c, DriveFixed)] -- DRIVE_FIXED
      _ -> []

-- | Filesystem name ("NTFS", "exFAT", …) of the volume behind a drive
-- letter; Nothing when the query fails. Informational only — no pm protocol
-- depends on the filesystem type (DESIGN.md §9: the doctor matrix assumes no
-- rename atomicity).
volumeFsType :: Char -> IO (Maybe Text)
volumeFsType c =
  query `catch` \(_ :: SomeException) -> pure Nothing
 where
  query =
    withTString (c : ":\\") $ \rootP ->
      allocaBytes (fsBufChars * 2) $ \fsName -> do
        ok <- c_GetVolumeInformationW rootP nullPtr 0 nullPtr nullPtr nullPtr fsName (fromIntegral fsBufChars)
        if ok == 0
          then pure Nothing
          else Just . T.pack <$> peekTString fsName
  fsBufChars = 64 :: Int
