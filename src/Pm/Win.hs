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
--    banned in this codebase; use 'moveBoundNoReplace'.
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
  , moveBoundNoReplace
  , deleteBoundAt
  , pathUnder
  , pathAtOrUnder
  , isNameSurrogate
  , NameKind (..)
  , probeName
  , resolveUnder
  , openExclusiveBinary
  , openFreshBinary
  , openStateAppend
  , openStateRead
  , openStateLock
  , handleIsSingleLink
  , handleFinalPath
  , handleIsAt
  , openBoundTo
  , FileId (..)
  , handleFileId
  , suppressCriticalErrorDialogs
  , DriveKind (..)
  , listCandidateDrives
  , volumeFsType
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, catch, finally, mask, onException, try)
import Control.Monad (unless, when)
import Data.Bits (testBit, (.&.))
import Data.Char (toLower)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word32, Word64, Word8)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, intPtrToPtr, nullPtr)
import Foreign.Storable (peek, peekByteOff)
import System.Directory (canonicalizePath, doesPathExist)
import System.FilePath (splitDirectories, (</>))
import System.IO
import qualified System.Win32.Console as Win32Console
import qualified System.Win32.File as Win32File
import System.Win32.Types (LPTSTR, hANDLEToHandle, peekTString, withHandleToHANDLE, withTString)

foreign import WINDOWS_CCONV unsafe "windows.h FindFirstFileW"
  c_FindFirstFileW :: LPTSTR -> Ptr Word8 -> IO (Ptr ())

foreign import WINDOWS_CCONV unsafe "windows.h FindClose"
  c_FindClose :: Ptr () -> IO Bool

-- Win32 包的 getFileAttributes 失败时抛 IOError，错误码被折进异常文本——
-- 'probeName' 需要**原始错误码**来分辨 Missing/Unknown。P3b-15（十二轮 #3）：
-- 属性与错误码必须在**同一次** FFI 里取——分成两次 Haskell 调用时，threaded
-- RTS 可能把它们跑在不同 OS 线程上，而 GetLastError 是 per-OS-thread 的。
-- cbits/pm_win.c 的包装一次返回两者，不留线程亲和性假设。
foreign import ccall unsafe "pm_get_file_attributes_err"
  c_pmGetFileAttributesErr :: LPTSTR -> Ptr Word32 -> IO Word32

-- | 见 cbits/pm_win.c。返回写入的 wchar 数（不含结尾 NUL），0 表示失败。
foreign import ccall unsafe "pm_final_path_by_handle"
  c_pmFinalPathByHandle :: Ptr () -> LPTSTR -> Word32 -> Ptr Word32 -> IO Word32

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
      `catch` \(_ :: IOException) -> pure ()

-- | hFlush + FlushFileBuffers: contents durable on media when this returns
-- (modulo hardware that lies; see doctor matrix row C4).
flushHandleToDisk :: Handle -> IO ()
flushHandleToDisk h = do
  hFlush h
  withHandleToHANDLE h Win32File.flushFileBuffers


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
  eb <- try (canonicalizePath base) :: IO (Either IOException FilePath)
  ep <- try (canonicalizePath p) :: IO (Either IOException FilePath)
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
-- 决定 @Nothing@ 怎么算，而 'Pm.Exec.confinedUserPath' 只接受明确的
-- @Just False@（P3b-17：Bool 版 @confinedUser@ 已删除，用户侧只剩这一个口）。
pathAtOrUnder :: FilePath -> FilePath -> IO (Maybe Bool)
pathAtOrUnder base p = do
  eb <- try (canonicalizePath base) :: IO (Either IOException FilePath)
  ep <- try (canonicalizePath p) :: IO (Either IOException FilePath)
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

-- P3b-14（十一轮 #4）：Missing\/Unknown 的分辨不再用 @doesPathExist@ 二问——
-- 它把 ACL 拒绝、非法名等错误也吞成 False（本仓 'Pm.Exec' 的注释早已记录这一
-- 点），于是"查不出"仍会塌缩进"不存在"。改为读 @GetFileAttributesW@ 失败时的
-- 错误码：只有 ERROR_FILE_NOT_FOUND (2) 与 ERROR_PATH_NOT_FOUND (3) 是
-- 'NameMissing'，其余（ACL 5、非法名 123、断网 53、介质异常……）一律
-- 'ProbeUnknown'（fail-closed——可能拒绝离线\/无权限的库，但不会误接受）。
-- P3b-15（十二轮 #3）：两次独立 FFI 换成 cbits 单次调用，错误码在同一 OS
-- 线程内取得，线程亲和性假设不复存在。
probeName :: FilePath -> IO NameKind
probeName p = do
  (attrs, ec) <-
    withTString p $ \wp ->
      alloca $ \errp -> do
        a <- c_pmGetFileAttributesErr wp errp
        e <- peek errp
        pure (a, e)
  if attrs == invalidFileAttributes
    then pure (if ec == 2 || ec == 3 then NameMissing else ProbeUnknown)
    else
      if attrs .&. Win32File.fILE_ATTRIBUTE_REPARSE_POINT == 0
        then pure NamePlain
        else do
          mt <- reparseTag p
          pure $ case mt of
            Nothing -> NameSurrogate -- 是 reparse 但读不出 tag → 保守拒绝
            Just tag ->
              if tag .&. ioReparseTagNameSurrogate /= 0 then NameSurrogate else NamePlain
 where
  invalidFileAttributes = 0xFFFFFFFF :: Word32

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
  r <- try (withHandleToHANDLE h Win32File.getFileInformationByHandle) :: IO (Either IOException Win32File.BY_HANDLE_FILE_INFORMATION)
  pure $ case r of
    Right i -> Win32File.bhfiNumberOfLinks i <= 1
    Left _ -> False -- 查不出就不写（fail-closed）

-- | 文件**对象**的身份：卷序列号 + 文件索引。两条路径指向同一个对象，当且
-- 仅当二者相等。
--
-- 这是「三份副本是不是三个独立对象」的正确判据。此前用的是
-- 'handleIsSingleLink'（link count == 1）——**充分而不必要**：每份只有一个
-- 名字确实蕴含彼此不同，但一份合法归档照片被去重工具另建一个名字（nlink 2）
-- 就被判成不可信，@pm clean staging@ 与 @pm trash empty@ 于是长期 HELD。
-- 方向是安全的，代价是永远清不掉（codex 二十八轮 #2）。
--
-- nlink 判定**仍然保留**在 @.pm@ 状态文件的三个打开口（'openStateAppend' /
-- 'openStateRead' / 'openStateLock'）——那里问的是另一件事：pm 自己的状态
-- 不得与任何别的名字共享同一个对象，nlink == 1 正是那个问题的正解。
data FileId = FileId {fidVolume :: Word32, fidIndex :: Word64}
  deriving (Eq, Ord, Show)

-- | 从**已打开的句柄**取身份。与内容读自同一句柄——按名字重开等于把校验与
-- 使用分成两次独立解析，正是本项目十一~十三轮反复收拾的那个形状。
-- 取不到就是 Nothing，调用方一律 fail-closed（不得当作"身份不同"）。
handleFileId :: Handle -> IO (Maybe FileId)
handleFileId h = do
  r <- try (withHandleToHANDLE h Win32File.getFileInformationByHandle) :: IO (Either IOException Win32File.BY_HANDLE_FILE_INFORMATION)
  pure $ case r of
    Right i ->
      Just
        (FileId (Win32File.bhfiVolumeSerialNumber i) (Win32File.bhfiFileIndex i))
    Left _ -> Nothing

-- | 一个**已打开句柄**当前绑定的路径（@GetFinalPathNameByHandleW@）。
--
-- 这是 P5-D 的地基。此前 pm 的访问模式是「'resolveUnder' 逐级下降算出一条
-- 路径 → 按那个**名字**重新打开」——两步之间有窗口：攻击者在窗口里把中途某
-- 一层换成 junction，打开的就是库外的对象（codex 二十八轮 #1）。
--
-- 句柄反查把因果调了个方向：答案是从**要读的那个对象**上取的。开完之后再
-- 怎么换目录都改不了这个句柄指向谁；开之前换过，则查出来的路径与期望不符，
-- 当场拒绝。于是那个窗口不再有意义。
--
-- 返回 @\\?\D:\dir\file@ 形态（@FILE_NAME_NORMALIZED | VOLUME_NAME_DOS@）。
-- 取不到（挂载点没有 DOS 路径、句柄类型不支持…）→ Nothing，调用方一律
-- fail-closed。
handleFinalPath :: Handle -> IO (Maybe FilePath)
handleFinalPath h = withHandleToHANDLE h rawFinalPath

-- | 裸 HANDLE 版（提交型句柄操作直接持 CreateFileW 的句柄，不经 GHC Handle）。
rawFinalPath :: Ptr () -> IO (Maybe FilePath)
rawFinalPath raw =
  allocaBytes (finalPathCch * 2) $ \buf ->
    alloca $ \errP -> do
      n <- c_pmFinalPathByHandle raw buf (fromIntegral finalPathCch) errP
      if n == 0 || n >= fromIntegral finalPathCch
        then pure Nothing
        else Just <$> peekTString buf

-- | 缓冲区上限。Win32 长路径上限 32767 wchar；pm 自己的路径预检
-- （'Pm.Scan' 的 maxPathLen）远低于它，取这个上限只是为了"够不到就算失败"
-- 而不是截断后误判。
finalPathCch :: Int
finalPathCch = 32768

-- | 这个句柄绑定的**就是** @expected@ 这条路径上的对象吗。
--
-- 比较前两边都规范化：去掉 @\\?\@ 前缀、按分隔符切开、丢掉空分量、折大小写
-- （Windows 路径比较不分大小写）。取不到路径 → False（fail-closed）。
handleIsAt :: Handle -> FilePath -> IO Bool
handleIsAt h expected = do
  m <- handleFinalPath h
  pure $ case m of
    Nothing -> False
    Just real -> normPath real == normPath expected

-- | 'handleIsAt' 与 'rawBoundTo' 共用的比较规范化。
normPath :: FilePath -> [String]
normPath p =
  [ map toLower c
  | c <- splitDirectories (dropExtended p)
  , not (null c)
  , c /= "\\"
  , c /= "/"
  ]
 where
  dropExtended q = case q of
    ('\\' : '\\' : '?' : '\\' : rest) -> rest
    _ -> q

-- | @.pm@ 内状态文件的受控打开：打开后**立刻**查 link count，\>1 即关闭并
-- 拒绝。@AppendMode@ 不截断，所以"先打开再判"是安全的——判定失败时尚未写入
-- 任何字节。截断语义（@WriteMode@）不得用此函数：那会在判定之前就毁掉内容，
-- 覆盖写一律走"独占创建 tmp → 'moveBoundNoReplace' 落位"。
openStateAppend :: FilePath -> IO Handle
openStateAppend fp = do
  h <- openBoundTo AppendMode fp
  ok <- handleIsSingleLink h
  if ok
    then pure h
    else do
      hClose h
      ioError (userError (fp <> ": 该名字与别处的文件是同一对象（hardlink），拒绝写入——人工核查"))

-- | **P5-D 的取用口**：打开 @fp@，然后在**句柄**上确认它绑定的正是 @fp@ 这
-- 条路径上的对象；不是就关掉并拒绝。
--
-- 这一步取代了本项目此前的访问模式「'resolveUnder' 逐级下降算出路径 → 按那个
-- **名字**重新打开」。那个模式的两步之间有窗口：攻击者在窗口里把中途某一层换
-- 成 junction，打开的就是库外的对象，而校验已经过去了（codex 二十八轮 #1）。
--
-- 换过来之后 'resolveUnder' **不再是安全边界**，只是预筛（提前给出人话错误、
-- 少开一次没用的句柄）。真正的判定长在要读写的那个句柄上：开完之后再怎么换
-- 目录都改不了它指向谁；开之前换过，则句柄的实际路径与期望不符，当场拒绝。
--
-- 边界更新（P6-C）：提交型 rename\/unlink 此前只有名字形态（@MoveFileEx@ \/
-- @DeleteFileW@ 按名字），是 §14 登记的最后一类窗口；现已全部句柄化
-- （'moveBoundNoReplace' \/ 'deleteBoundAt'——打开、先验绑定、
-- @SetFileInformationByHandle@ 提交、rename 另有同句柄后验）。仍留在名字层的
-- 只剩目标侧的先验（@RootDirectory@ 文档要求为 NULL），见 §14 残余第 1 条。
openBoundTo :: IOMode -> FilePath -> IO Handle
openBoundTo mode fp = do
  h <- openBinaryFile fp mode
  ok <- handleIsAt h fp
  if ok
    then pure h
    else do
      hClose h
      ioError
        ( userError
            ( fp
                <> ": 打开后句柄绑定的不是这条路径（中途有别名，或在解析与打开之间被替换），"
                <> "拒绝读写——人工核查"
            )
        )

-- | @openStateAppend@ 的只读对偶：打开后立刻查 link count，\>1 即拒绝。
--
-- P3b-14（十一轮复审 major，探针实证）：写侧从九轮起就查 link count，**读侧
-- 一直没查**。实测把 @.pm\/catalog.json@ 预置成库外文件的 hardlink 后，
-- 'Pm.Config.requirePmTrusted' 放行（hardlink 不是 reparse point）、
-- @loadCatalog@ **零警告地载入了库外快照**；@.pm\/plans\/\<id\>.json@ 同形态
-- 让 @loadPlan@ 载入库外计划，apply 会照它执行。读进来的字节决定 pm 之后
-- 做什么，因此读侧与写侧必须同规格。
--
-- 判定在**句柄**上做，随后的读取也必须用同一个句柄——按名字重开等于把校验
-- 与使用分成两次独立解析（这正是十一轮那一类缺口的成因）。
openStateRead :: FilePath -> IO Handle
openStateRead fp = do
  h <- openBoundTo ReadMode fp
  ok <- handleIsSingleLink h
  if ok
    then pure h
    else do
      hClose h
      ioError (userError (fp <> ": 该名字与别处的文件是同一对象（hardlink），拒绝读取——人工核查"))

-- | 锁文件的受控打开（P3b-15，十二轮 minor）：@ReadWriteMode@（缺失即创建、
-- 绝不截断）+ 打开后立刻查 link count。@.pm\/lock@ 被 hardlink 到库外文件时，
-- pm 会锁住那个共享对象——跨库互斥、或对外部程序的 DoS；锁不写任何字节，
-- 危害低于状态文件，但「@.pm@ 下的打开都过句柄判定」必须无例外。
openStateLock :: FilePath -> IO Handle
openStateLock fp = do
  h <- openBoundTo ReadWriteMode fp
  ok <- handleIsSingleLink h
  if ok
    then pure h
    else do
      hClose h
      ioError (userError (fp <> ": 该名字与别处的文件是同一对象（hardlink），拒绝加锁——人工核查"))

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
  eb <- try (canonicalizePath base) :: IO (Either IOException FilePath)
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
-- 'openExclusiveBinary'。这一 unlink 是安全的：对 hardlink，删除 disposition
-- 只减掉一个目录项，库外原文件的内容不受影响（实测）；对 symlink 删的是链接
-- 本体（'deleteBoundAt' 终段不跟随）。残留是**非空目录**时删除失败
-- （ERROR_DIR_NOT_EMPTY），整项 fail-closed 中止；空目录会被清除（见下）。
--
-- ⚠️ 它只在**父目录已被验过**时才安全：残留的 unlink 会沿父目录的 junction
-- 走出库外（P3b-12 九轮 critical 实测：@.pm\/tmp\/\<planId\>@ 是 junction 时，
-- 这个 unlink 删掉了库外的同名文件）。调用方必须保证父目录可信：
-- 'Pm.Exec' 的 tmp 落位与 'Pm.Config.writeCacheFile' 对**完整路径**做
-- 'resolveUnder'；'Pm.Catalog.saveCatalog' 的 tmp 与三代轮转自 P3b-15 起在
-- 使用点走 'Pm.Config.resolvePmPath'（十二轮 critical：此前它只依赖
-- 'requirePmTrusted'，而那道闸与本次写之间隔着一整轮全量扫描，窗口里把
-- @.pm@ 换成 junction 就能让轮转在库外建 tmp、删旧代）。
openFreshBinary :: FilePath -> IO Handle
openFreshBinary fp = do
  lnk <- isNameSurrogate fp
  ex <- doesPathExist fp
  -- P6-C：残留清除改句柄形态（'deleteBoundAt'——打开终段不跟随、先验绑定、
  -- 句柄上置 delete disposition）。行为差异一处：残留是**空目录**时旧
  -- removeFile 抛异常、现在会被清除——pm 自建 tmp 名被空目录占住本就该让路；
  -- 非空目录仍失败（ERROR_DIR_NOT_EMPTY），fail-closed 不变。
  when (lnk || ex) (deleteBoundAt fp)
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
  driveMask <- Win32File.getLogicalDrives
  let letters = [toEnum (fromEnum 'A' + i) | i <- [0 .. 25], testBit driveMask i]
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
  -- 有意保留 SomeException（三十九轮类清扫时逐处裁定）：query 里没有会抛
  -- IOException 的操作——c_GetVolumeInformationW 以返回 0 表失败、已显式
  -- 处理，可能逃出的只有 withTString/peekTString 的编解码异常；收窄成
  -- IOException 等于把 catch 改成死代码、让这些异常直接炸掉 status。
  -- 本函数纯 informational（无协议依赖），任何失败 -> Nothing 是对的。
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

-- ─── 提交型句柄操作（P6-C，路线图③） ───────────────────────────────────────

foreign import ccall unsafe "pm_open_for_dispose"
  c_pmOpenForDispose :: LPTSTR -> Ptr (Ptr ()) -> Ptr Word32 -> IO Word32

foreign import ccall unsafe "pm_rename_by_handle"
  c_pmRenameByHandle :: Ptr () -> LPTSTR -> Ptr Word32 -> IO Word32

foreign import ccall unsafe "pm_delete_by_handle"
  c_pmDeleteByHandle :: Ptr () -> Ptr Word32 -> IO Word32

-- | 提交型打开：DELETE 权限、全共享、目录也行（BACKUP_SEMANTICS）、终段
-- **不跟随**（OPEN_REPARSE_POINT——终段是链接时拿到的是链接本体）。
--
-- 三十二轮 R1：被 P6-C 替掉的 @moveFileEx@\/@deleteFile@ 在 Win32 包里都经
-- @failIfWithRetry@（ERROR_SHARING_VIOLATION=32 时 100ms×20 重试，KB 316609：
-- 杀毒/索引器短暂持有刚 close 的文件）。句柄化后共享冲突挪到了**打开**这一步
-- （请求 DELETE 权限撞上别人不带 FILE_SHARE_DELETE 的句柄），重试预算原样搬到
-- 这里。重试重跑的只是**打开**；回调 @k@（含调用方的 rawBoundTo 先验）在
-- **最终成功的那个句柄**上执行一次——先验校验的正是最终句柄，保证不削弱
-- （三十三轮 F2 更正此前「先验逐次重跑」的措辞）。等待用 threadDelay：不是
-- 掩盖竞态，是对短暂占用的既有礼让语义
--（because 旧名字口原语内建同款重试，删掉它才是行为回归）。
--
-- 三十二轮 R2：CreateFileW 成功返回到 @finally@ 装上之间必须无异步异常窗口
-- （P3b-12\/P3b-13 两次同型修复的既有纪律），整段 mask；threadDelay 在 mask 下
-- 仍可中断，等待期间未持有任何句柄。
withDisposeHandle :: FilePath -> (Ptr () -> IO a) -> IO a
withDisposeHandle fp k =
  withTString fp $ \pw ->
    alloca $ \hOut ->
      alloca $ \errP ->
        mask $ \restore -> do
          let open attempt = do
                ok <- c_pmOpenForDispose pw hOut errP
                if ok /= 0
                  then pure Nothing
                  else do
                    e <- peek errP
                    if e == 32 && attempt < sharingRetries
                      then threadDelay sharingDelayUs >> open (attempt + 1)
                      else pure (Just e)
          me <- open (1 :: Int)
          case me of
            Just e ->
              ioError (userError (fp <> ": 打开失败（DELETE 权限），Win32 错误码 " <> show e <> if e == 32 then "（共享冲突，已重试 " <> show sharingRetries <> " 次）" else ""))
            Nothing -> do
              h <- peek hOut
              restore (k h) `finally` Win32File.closeHandle h
 where
  -- 与 Win32 的 failIfWithRetry 同预算（delay 100ms、retries 20）。
  sharingRetries = 20 :: Int
  sharingDelayUs = 100 * 1000

-- | 裸 HANDLE 版的 'handleIsAt'（同一比较规则 'normPath'）。
rawBoundTo :: Ptr () -> FilePath -> IO Bool
rawBoundTo raw expected = do
  m <- rawFinalPath raw
  pure (maybe False (\real -> normPath real == normPath expected) m)

rawRename :: Ptr () -> FilePath -> IO (Maybe Word32)
rawRename h dst =
  withTString dst $ \pw ->
    alloca $ \errP -> do
      ok <- c_pmRenameByHandle h pw errP
      if ok == 0 then Just <$> peek errP else pure Nothing

-- | 句柄形态的 no-replace 落位（路线图③；此前是 @MoveFileExW@ 名字口——
-- DESIGN §14 登记的最后一类窗口）。协议：
--
--   1. 打开源并**先验**句柄绑定的就是这条路径（打开前被换成别名 → 拒绝）；
--   2. @SetFileInformationByHandle(FileRenameInfo)@，no-replace（I5：目标已
--      存在 → 失败，绝不覆盖）；
--   3. **后验**：问同一个句柄"对象现在在哪条路径"。目标的某一层在窗口里被换
--      成 junction 时对象会落到别处——后验当场发现，沿同一句柄改回原名，
--      再响亮报错。字节不丢、位置已知。
--
-- 目标侧做不到先验（文档明确 SetFileInformationByHandle 的 RootDirectory
-- 必须为 NULL），后验 + 回迁是句柄能给到的最强保证。
moveBoundNoReplace :: FilePath -> FilePath -> IO ()
moveBoundNoReplace src dst = withDisposeHandle src $ \h -> do
  okSrc <- rawBoundTo h src
  unless okSrc $
    ioError (userError (src <> ": 句柄绑定的不是这条路径（打开前已被换成别名/链接），拒绝落位"))
  r <- rawRename h dst
  case r of
    Just e ->
      ioError (userError (src <> " -> " <> dst <> ": rename 失败（Win32 错误码 " <> show e <> "，183=目标已存在）"))
    Nothing -> do
      okDst <- rawBoundTo h dst
      unless okDst $ do
        actual <- rawFinalPath h
        rb <- rawRename h src
        ioError . userError $
          dst
            <> ": 落位后对象不在期望路径（目标某层在窗口内被换成链接？）——实际落点 "
            <> maybe "未知" id actual
            <> case rb of
              Nothing -> "；已沿同一句柄改回原名"
              Just e -> "；改回原名也失败（Win32 错误码 " <> show e <> "），对象仍在实际落点"

-- | 句柄形态的 unlink（此前是 @removeFile@ 名字口）。打开（终段不跟随）→
-- 先验绑定 → @FileDispositionInfo@。终段是 symlink 时删的是链接本体，目标
-- 不受影响；目录为空时同样可删（pm 自建 tmp 名被空目录占住的情形）。
deleteBoundAt :: FilePath -> IO ()
deleteBoundAt fp = withDisposeHandle fp $ \h -> do
  ok <- rawBoundTo h fp
  unless ok $
    ioError (userError (fp <> ": 句柄绑定的不是这条路径（别名/链接），拒绝删除"))
  r <- alloca $ \errP -> do
    okD <- c_pmDeleteByHandle h errP
    if okD == 0 then Just <$> peek errP else pure Nothing
  case r of
    Just e -> ioError (userError (fp <> ": 句柄删除失败，Win32 错误码 " <> show e))
    Nothing -> pure ()
