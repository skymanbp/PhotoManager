{-# LANGUAGE ScopedTypeVariables #-}

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
module Pm.Win
  ( setupConsole
  , flushHandleToDisk
  , moveFileNoReplace
  ) where

import Control.Exception (SomeException, catch)
import Control.Monad (when)
import System.IO
import qualified System.Win32.Console as Win32Console
import qualified System.Win32.File as Win32File
import System.Win32.Types (withHandleToHANDLE)

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
