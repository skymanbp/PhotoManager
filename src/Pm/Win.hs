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
  , isNameSurrogate
  , resolveUnder
  , openExclusiveBinary
  , openFreshBinary
  , openStateAppend
  , handleIsSingleLink
  , suppressCriticalErrorDialogs
  , DriveKind (..)
  , listCandidateDrives
  , volumeFsType
  ) where

import Control.Exception (SomeException, catch, finally, mask, onException, try)
import Control.Monad (when)
import Data.Bits (testBit, (.&.))
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32, Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr, intPtrToPtr, nullPtr)
import Foreign.Storable (peekByteOff)
import System.Directory (canonicalizePath, doesPathExist, removeFile)
import System.FilePath (splitDirectories, (</>))
import System.IO
import qualified System.Win32.Console as Win32Console
import qualified System.Win32.File as Win32File
import System.Win32.Types (LPTSTR, hANDLEToHandle, peekTString, withHandleToHANDLE, withTString)

foreign import WINDOWS_CCONV unsafe "windows.h FindFirstFileW"
  c_FindFirstFileW :: LPTSTR -> Ptr Word8 -> IO (Ptr ())

foreign import WINDOWS_CCONV unsafe "windows.h FindClose"
  c_FindClose :: Ptr () -> IO Bool

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

-- | @pathAtOrUnder base p@ = @p@ 解析后**是** @base@ 本身或落在其内；
-- 解析不出来时是 @Nothing@（"答不上来"）。
--
-- P3b-12（九轮复审 major）：此前返回 @Bool@，解析失败按 False。它被用在
-- **排除**判定上（@not \<$\> pathAtOrUnder@），于是"答不上来"变成了"不在
-- @.pm@ 里，放行"——结构性 fail-open。三态把这个歧义消掉：调用点必须显式
-- 决定 @Nothing@ 怎么算，而 'Pm.Exec.confinedUser' 只接受明确的 @Just False@。
pathAtOrUnder :: FilePath -> FilePath -> IO (Maybe Bool)
pathAtOrUnder base p = do
  eb <- try (canonicalizePath base) :: IO (Either SomeException FilePath)
  ep <- try (canonicalizePath p) :: IO (Either SomeException FilePath)
  pure $ case (eb, ep) of
    (Right b, Right q) ->
      let bs = comps b
          qs = comps q
       in Just (length qs >= length bs && take (length bs) qs == bs)
    _ -> Nothing
 where
  comps = map (map toLower) . splitDirectories

-- | 该名字是否是**会改变名字解析**的 reparse point —— 即 name surrogate
-- （junction \/ symlink \/ mount point）。
--
-- P3b-12（九轮复审 major）：此前用 'pathIsSymbolicLink'，它只问"有没有
-- reparse 属性"。Windows 上 OneDrive 云占位、Dedup、WIM-boot 等**也**是
-- reparse point，但它们不改变"这个名字指向哪个对象"——一律拒绝会让 pm 在
-- 这类卷上整个不可用（九轮点出的可用性回归；本机造不出这类对象，故按
-- 规范判定而非探针）。判据改为 reparse tag 的 name-surrogate 位：
-- @IO_REPARSE_TAG_MOUNT_POINT@ (0xA0000003) 与 @IO_REPARSE_TAG_SYMLINK@
-- (0xA000000C) 都置了它，云占位\/Dedup 没有。
--
-- 有 reparse 属性但读不出 tag → 'NameSurrogate'（fail-closed：读不出就当它会
-- 重定向）。**悬空** junction 也是（属性查询在悬空时照样返回，实测）。
--
-- P3b-13（十轮复审 major）：区分"名字不存在"与"属性查得失败"。此前两者都塌
-- 缩成 False（探针实证：缺失名字抛异常、普通目录返回 16），于是 ACL 拒绝读属性
-- 时该层会被当成"尚不存在"而放行。三态让调用方对 'ProbeUnknown' fail-closed。
data NameKind = NameMissing | NamePlain | NameSurrogate | ProbeUnknown
  deriving (Show, Eq)

probeName :: FilePath -> IO NameKind
probeName p = do
  ea <- try (Win32File.getFileAttributes p) :: IO (Either SomeException Win32File.FileAttributeOrFlag)
  case ea of
    Left _ -> do
      -- 属性查不到：可能是"不存在"，也可能是 ACL 拒绝之类的"答不上来"。
      -- doesPathExist 用另一条路径再问一次；它也说不存在才算缺失。
      ex <- doesPathExist p
      pure (if ex then ProbeUnknown else NameMissing)
    Right attrs
      | attrs .&. Win32File.fILE_ATTRIBUTE_REPARSE_POINT == 0 -> pure NamePlain
      | otherwise -> do
          mt <- reparseTag p
          pure $ case mt of
            Nothing -> NameSurrogate -- 是 reparse 但读不出 tag → 保守拒绝
            Just tag ->
              if tag .&. ioReparseTagNameSurrogate /= 0 then NameSurrogate else NamePlain

-- | 便捷谓词：仅当明确判定为 name surrogate 时为 True。'ProbeUnknown' 在这里
-- 是 False —— 调用方若要 fail-closed 必须直接用 'probeName'（'resolveUnder'
-- 就是这么做的）。
isNameSurrogate :: FilePath -> IO Bool
isNameSurrogate p = (== NameSurrogate) <$> probeName p

-- | @FindFirstFileW@ 的 @WIN32_FIND_DATAW.dwReserved0@ 就是 reparse tag。
-- 偏移核算（x86_64，结构体内无指针字段，故无 8 字节对齐插入）：
-- @dwFileAttributes@ 0..3、三个 @FILETIME@ 4..27、size high\/low 28..35、
-- @dwReserved0@ **36..39**、@dwReserved1@ 40..43、@cFileName[260]@ 44..563、
-- @cAlternateFileName[14]@ 564..591 —— 共 592 字节。Win32 包不暴露该字段。
--
-- 失败返回的是 @INVALID_HANDLE_VALUE@，无需 @FindClose@；成功分支用 'bracket'
-- 关闭，异步异常也不会漏句柄（P3b-13 十轮 minor）。
reparseTag :: FilePath -> IO (Maybe Word32)
reparseTag p =
  allocaBytes findDataBytes $ \buf ->
    withTString p $ \wp ->
      mask $ \restore -> do
        h <- c_FindFirstFileW wp buf
        if h == intPtrToPtr (-1)
          then pure Nothing
          else
            (restore (Just <$> peekByteOff buf 36) `finally` c_FindClose h)
 where
  findDataBytes = 592

ioReparseTagNameSurrogate :: Word32
ioReparseTagNameSurrogate = 0x20000000

-- | 状态文件（@.pm@ 内 journal \/ manifest \/ plan \/ 侧缓存）的 hardlink 判定：
-- link count \> 1 表示这个名字与别处的某个目录项指向**同一个文件对象**。
--
-- P3b-12（九轮复审 major，探针实证）：hardlink 既不是 reparse point 也不改
-- canonical 路径，'resolveUnder' 与 canonical 判定都看不见它；实测把
-- @.pm\/journal.ndjson@ 预置成库外文件的 hardlink 后，@AppendMode@ 追加与
-- 覆盖写**都写到了库外对象**上。@CREATE_NEW@ 只能守"pm 自己新建"的名字，
-- 守不住这些必须复用既有名字的状态文件——那条路径靠这里的 link count 守。
handleIsSingleLink :: Handle -> IO Bool
handleIsSingleLink h = do
  r <- try (withHandleToHANDLE h Win32File.getFileInformationByHandle) :: IO (Either SomeException Win32File.BY_HANDLE_FILE_INFORMATION)
  pure $ case r of
    Right i -> Win32File.bhfiNumberOfLinks i <= 1
    Left _ -> False -- 查不出就不写（fail-closed）

-- | @.pm@ 内状态文件的受控打开：打开后**立刻**查 link count，\>1 即关闭并
-- 拒绝。@AppendMode@ 不截断，所以"先打开再判"是安全的——判定失败时尚未写入
-- 任何字节。截断语义（@WriteMode@）不得用此函数：那会在判定之前就毁掉内容，
-- 覆盖写一律走"独占创建 tmp → 'moveFileNoReplace' 落位"。
openStateAppend :: FilePath -> IO Handle
openStateAppend fp = do
  h <- openBinaryFile fp AppendMode
  ok <- handleIsSingleLink h
  if ok
    then pure h
    else do
      hClose h
      ioError (userError (fp <> ": 该名字与别处的文件是同一对象（hardlink），拒绝写入——人工核查"))

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
-- 注意它**看不见 hardlink**（hardlink 不是 reparse point，实测）：pm 自建的
-- 名字由 'openFreshBinary' 的独占创建守，必须复用的状态文件名由
-- 'openStateAppend' 的 link count 守。
--
-- @base@ 本身只做 canonicalize，不查它是不是链接：root 由**用户**指定，把
-- 库根放在 junction 上是合法用法。安全性依赖调用方一律以 root 为 base
-- （P3b-12：九轮指出 P3b-11 的文档把这点写成了"含基准自身"，措辞已更正）。
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
        k <- probeName nxt
        case k of
          NameSurrogate -> pure Nothing
          -- P3b-13（十轮复审）：查不出这一层是什么就不往下走，也不当作"缺失"
          -- 放行 —— 答不上来即拒（fail-closed）。
          ProbeUnknown -> pure Nothing
          NameMissing -> pure (Just (foldl (</>) nxt cs))
          NamePlain -> go nxt cs

-- | 独占创建（@CREATE_NEW@）的二进制写句柄：目标已存在即抛 IOException。
--
-- P3b-11（八轮复审 major，探针实证）：pm 的 @.pm\/tmp@ 文件名是**确定性**的
-- （崩溃重跑要能算出同名，doctor 才能把孤儿 tmp 与在途 tmp 分开）。可预测的
-- 名字 + @WriteMode@ 截断打开 = 谁先把该名字做成库外文件的 hardlink，pm 一写
-- 就覆盖了库外内容——实测库外文件真的变成了 pm 写的字节。hardlink 不是
-- reparse point，'resolveUnder' 与 canonical 判定都看不见它；@CREATE_NEW@
-- 是唯一能原子拒绝的语义（实测：普通文件与 hardlink 都被拒，库外内容完好）。
-- P3b-12（九轮复审 minor）：raw HANDLE 到 Handle 的所有权转移期间加
-- 'onException' —— 'hANDLEToHandle' 或 'hSetBinaryMode' 抛异常时原来会漏句柄
-- （文件被 @FILE_SHARE_NONE@ 独占着，直到进程退出都没人能碰它）。
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
  hd <- hANDLEToHandle h `onException` Win32File.closeHandle h
  hSetBinaryMode hd True `onException` hClose hd
  pure hd

-- | 重跑安全的独占创建：先删掉同名残留（上次崩溃留下的 pm 自建 tmp），再
-- 'openExclusiveBinary'。这一 unlink 是安全的：对 hardlink，@DeleteFileW@
-- 只减掉一个目录项，库外原文件的内容不受影响（实测）；对 symlink 删的是链接
-- 本体。残留若是目录则 removeFile 抛异常，整项 fail-closed 中止。
--
-- ⚠️ 它只在**父目录已被验过**时才安全：残留的 unlink 会沿父目录的 junction
-- 走出库外（P3b-12 九轮 critical 实测：@.pm\/tmp\/\<planId\>@ 是 junction 时，
-- 这个 unlink 删掉了库外的同名文件）。调用方必须保证父目录可信：
-- 'Pm.Exec' 的 tmp 落位与 'Pm.Config.writeCacheFile' 对**完整路径**做
-- 'resolveUnder'；'Pm.Catalog' 与 'Pm.Config' 的 @.pm@ 顶层 tmp 依赖
-- 'Pm.Config.requirePmTrusted'（它现在枚举 @.pm@ 下的每个条目）——
-- P3b-13 十轮指出旧注释把后者说成"已做完整 resolveUnder"，措辞已更正。
openFreshBinary :: FilePath -> IO Handle
openFreshBinary fp = do
  lnk <- isNameSurrogate fp
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
