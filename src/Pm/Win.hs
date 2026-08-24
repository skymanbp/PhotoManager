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
  , pathAtOrUnder
  , isReparsePoint
  , resolveUnder
  , openExclusiveBinary
  , openFreshBinary
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
import System.Directory (canonicalizePath, doesPathExist, pathIsSymbolicLink, removeFile)
import System.FilePath (splitDirectories, (</>))
import System.IO
import qualified System.Win32.Console as Win32Console
import qualified System.Win32.File as Win32File
import System.Win32.Types (LPTSTR, hANDLEToHandle, peekTString, withHandleToHANDLE, withTString)

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

-- | @pathAtOrUnder base p@ = @p@ 解析后**是** @base@ 本身或落在其内。
-- 'pathUnder' 的非严格版：用于**排除**判定（「目标不得落进 .pm」——落在
-- @.pm@ 本身也必须拒绝）。同样 fail-closed，但语义相反：解析不出来时返回
-- False 表示"不能确证它在里面"，调用点因此要把它用在**排除**而非**准入**上。
pathAtOrUnder :: FilePath -> FilePath -> IO Bool
pathAtOrUnder base p = do
  eb <- try (canonicalizePath base) :: IO (Either SomeException FilePath)
  ep <- try (canonicalizePath p) :: IO (Either SomeException FilePath)
  pure $ case (eb, ep) of
    (Right b, Right q) ->
      let bs = comps b
          qs = comps q
       in length qs >= length bs && take (length bs) qs == bs
    _ -> False
 where
  comps = map (map toLower) . splitDirectories

-- | 该名字自身是否 reparse point（junction \/ symlink \/ mount point）。
-- **悬空** junction 也是 True（实测：'doesPathExist' 为 False 而
-- 'pathIsSymbolicLink' 为 True），所以必须先问它再问存在性。查询本身失败
-- （名字不存在）按 False，由调用方的存在性判断接手。
isReparsePoint :: FilePath -> IO Bool
isReparsePoint p =
  either (const False) id <$> (try (pathIsSymbolicLink p) :: IO (Either SomeException Bool))

-- | @resolveUnder base rel@：从 @base@ 起沿 @rel@ **逐分量下降**，任一级是
-- reparse point 即 Nothing；成功返回落点的绝对路径。
--
-- P3b-11（八轮复审 critical，探针实证）：'pathUnder' 只回答"目标解析后在
-- 哪"，默认**基准可信**——而基准也是 pm 自己拼出来的字符串。实测：把
-- @.pm\/trash@ 本身做成指向库外的 junction 后，@pathUnder trash
-- (trash \<\/\> "v.jpg")@ 两侧都解析到库外，包含关系成立、闸门放行，
-- @removeFile@ 随即**删掉了库外文件**。同理 @root\/alias -\> root\/.pm@ 让
-- @pathUnder root@ 为 True，可搬走 @root-id.json@。
--
-- 逐级下降把判定改成"每一段名字都必须是盘上的真名"：基准与目标同受检，
-- 中途 junction、基准 junction、悬空 junction、别名目录一律拒绝。
-- 尚不存在的分量放行——其后不可能指向任何东西，且 pm 自己会创建它们，
-- 因此 rename 到新名、copy 进新目录不会被误拒。
--
-- 注意它**看不见 hardlink**（hardlink 不是 reparse point，实测
-- 'pathIsSymbolicLink' 为 False）：那条路径由 'openFreshBinary' 的独占创建守。
resolveUnder :: FilePath -> FilePath -> IO (Maybe FilePath)
resolveUnder base rel = do
  eb <- try (canonicalizePath base) :: IO (Either SomeException FilePath)
  case eb of
    Left _ -> pure Nothing
    Right b -> go b (splitDirectories rel)
 where
  go cur [] = pure (Just cur)
  go cur (c : cs)
    -- 词法层（'Pm.Op.relPathOk'）已挡，这里再兜一次：下降算法本身不接受
    -- 任何能改变层级的分量。
    | c `elem` [".", "..", ""] = pure Nothing
    | otherwise = do
        let nxt = cur </> c
        lnk <- isReparsePoint nxt
        if lnk
          then pure Nothing
          else do
            ex <- doesPathExist nxt
            if ex then go nxt cs else pure (Just (foldl (</>) nxt cs))

-- | 独占创建（@CREATE_NEW@）的二进制写句柄：目标已存在即抛 IOException。
--
-- P3b-11（八轮复审 major，探针实证）：pm 的 @.pm\/tmp@ 文件名是**确定性**的
-- （崩溃重跑要能算出同名，doctor 才能把孤儿 tmp 与在途 tmp 分开）。可预测的
-- 名字 + @WriteMode@ 截断打开 = 谁先把该名字做成库外文件的 hardlink，pm 一写
-- 就覆盖了库外内容——实测库外文件真的变成了 pm 写的字节。hardlink 不是
-- reparse point，'resolveUnder' 与 canonical 判定都看不见它；@CREATE_NEW@
-- 是唯一能原子拒绝的语义（实测：普通文件与 hardlink 都被拒，库外内容完好）。
openExclusiveBinary :: FilePath -> IO Handle
openExclusiveBinary fp = do
  h <-
    Win32File.createFile
      fp
      Win32File.gENERIC_WRITE
      Win32File.fILE_SHARE_NONE
      Nothing
      Win32File.cREATE_NEW
      Win32File.fILE_ATTRIBUTE_NORMAL
      Nothing
  hd <- hANDLEToHandle h
  hSetBinaryMode hd True
  pure hd

-- | 重跑安全的独占创建：先删掉同名残留（上次崩溃留下的 pm 自建 tmp），再
-- 'openExclusiveBinary'。这一 unlink 是安全的：对 hardlink，@DeleteFileW@
-- 只减掉一个目录项，库外原文件的内容不受影响（实测）；对 symlink 删的是链接
-- 本体。残留若是目录则 removeFile 抛异常，整项 fail-closed 中止。
openFreshBinary :: FilePath -> IO Handle
openFreshBinary fp = do
  lnk <- isReparsePoint fp
  ex <- doesPathExist fp
  when (lnk || ex) (removeFile fp)
  openExclusiveBinary fp

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
