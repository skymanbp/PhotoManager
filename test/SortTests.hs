{-# LANGUAGE OverloadedStrings #-}

-- | P5-A：`pm sort` 与它依赖的 EXIF 读取。
--
-- EXIF 用例全部走**合成夹具**（在这里按字节拼出 TIFF/JPEG），不碰使用者的
-- 照片库——真实文件只能证明"能读"，证明不了越界、损坏、时间无效这些分支，
-- 而那些分支才是安全性所在。真实库的正确性另由主线手工比对（四张 ARW/JPG
-- 与 Windows 的「拍摄日期」逐条吻合，记在 REVIEW-LOG）。
-- photoAt 一并导出：ServeTests 的 sort 端点用例要造同样的 EXIF 样本，
-- 抄第二份就是第二套 fixture，迟早与被测的解析器分叉。
module SortTests (sortTests, photoAt) where

import Control.Exception (SomeException, bracket, finally, try)
import Control.Monad (forM_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sort)
import qualified Data.Text as T
import Data.Time (Day, LocalTime (..), TimeOfDay (..), fromGregorian)
import Data.Word (Word8)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , getModificationTime
  , listDirectory
  , removeDirectoryRecursive
  , removeFile
  , setModificationTime
  )
import System.FilePath (takeDirectory, takeFileName, (</>))
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO
  ( Handle
  , IOMode (ReadMode, ReadWriteMode, WriteMode)
  , hClose
  , hFlush
  , hGetContents
  , hSetEncoding
  , openBinaryFile
  , openFile
  , stdout
  , utf8
  )
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (catalogPath, saveCatalog)
import Pm.Hash (ContentProbe (..), probeConfined)
import Pm.Scan (DotDirs (..), listTreeWith)
import Pm.Cli (GoOpts (..))
import Pm.Config (Config (..))
import Pm.Exif (parseCaptureTime, parseExifDateTime, readCaptureTime)
import Pm.Hash (StatSnap (..))
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan, planPath)
import Pm.Sort
  ( SourceFiles (..)
  , SortPick (..)
  , Verdict (..)
  , classifyDst
  , eventNameFor
  , holdKin
  , pickFiles
  , listSource
  , resolveEvent
  , runSortPlan
  , runSortSurvey
  , segmentBy
  , snapshotWith
  )
import Pm.Types (FileKind (..), RootRole (..), classifyExt, rawExts)
import TestUtil (ensureTestRoot, scanQuiet)

sortTests :: TestTree
sortTests =
  testGroup
    "P5-A pm sort"
    [ testCase "EXIF：TIFF 与 JPEG 两种容器 × 大端小端 两种端序都读到 DateTimeOriginal" caseExifBothContainers
    , testCase "EXIF：Exif 段前有别的段/填充字节/独立标记时，JPEG 段链仍走得到它" caseExifJpegChain
    , testCase "EXIF：只认拍摄时间；IFD0 的 DateTime（文件修改时间）不再回退" caseExifOnlyCaptureTags
    , testCase "EXIF：子 IFD 指针接受 LONG 与 IFD 类型，但个数必须恰为 1" caseExifSubIfdPointer
    , testCase "EXIF fail-closed：截断/坏魔数/伪 APP1/偏移越界/全零时间 一律 Nothing，不猜" caseExifFailClosed
    , testCase "EXIF：字面量解析只认 YYYY:MM:DD HH:MM:SS，非法值不放行" caseExifLiteral
    , testCase "segmentBy：按间隔切段；输入乱序自己排；恰好等于阈值算同一段" caseSegment
    , testCase "eventNameFor：YY-MM-地点；空地点与非法字符拒绝" caseEventName
    , testCase "pickFiles：区间含首含尾；同名（含大小写差异）来自多源 → 整批拒绝" casePick
    , testCase "pickFiles：侧车跟随主文件、去重、并参与撞名检查" casePickSidecars
    , testCase "classifyDst：按目标位置定性；暂存目标异容待裁决，归档异容交给 import" caseClassify
    , testCase "holdKin：同目录同 stem 组内一荣俱荣，侧车不先于主文件落位" caseHoldKin
    , testCase "resolveEvent：--place 自动补年月；--event 也过字符闸与 canonRawEvent" caseResolve
    , testCase "E2E：真目录 → 计划落盘；侧车同批、读不到时间的不进、源零改动" caseSortE2E
    , testCase "E2E：无索引拒绝出计划；目标异容整组待裁决，占位文件零改动" caseSortE2EGates
    , testCase "易变守卫：次序须为 stat→hash→stat；两次 stat 不同则不出 sha" caseVolatileGuard
    , testCase "E2E：索引落后于暂存区盘面 → 拒绝出计划（该闸此前全项目无用例）" caseSortE2EStale
    , testCase "E2E：索引说「已在目标」但盘上内容不符 → 按实际内容重判，不静默跳过" caseSortE2EStaleSkip
    , testCase "E2E：源里的 junction 不跟随；认不出的扩展名单列不吞掉" caseSortE2ETraversal
    , testCase "EXIF：IFD 偏移必须 ≥ 8；声明「没有 IFD」的文件不得返回时间" caseExifIfdOffset
    , testCase "classifyExt：相机原生 raw 与 classifyExt 必须同一份清单" caseRawExts
    , testCase "EXIF：IFD 声明的条目数必须自洽，谎报 count 整个 IFD 作废" caseExifIfdCount
    , testCase "遍历：源里的点目录必须走进去，不能像库根那样静默跳过" caseSourceDotDirs
    , testCase "限域：目标路径中途是 junction → CpEscaped，不据此跳过" caseProbeConfined
    , testCase "遍历：源根自身是 junction → 明确告知实际整理的是哪个目录" caseSourceRootLink
    , testCase "EXIF：count 未超上限但声明的 IFD 装不下 → 仍整体作废" caseExifIfdFits
    , testCase "限域：目标存在却读不出（末段是目录）→ CpUnreadable，不当缺席" caseProbeUnreadable
    , testCase "遍历：目录列举失败变成一条带路径的错误，异常不得逃逸" caseListDirFails
    , testCase "遍历：源是 pm 库根时不进入 .pm（tmp/trash 不是待归位照片）" caseSourceSkipsPmDir
    , testCase "限域：hardlink 到库外的目标不得被当成可信副本" caseProbeHardlink
    , testCase "限域：目标被独占占用 → CpUnreadable，不得判成 CpMissing" caseProbeLocked
    , testCase "撞名整批拒绝时，被选中的照片与侧车必须逐条出现在输出里" caseCollisionReportsAll
    , testCase "遍历：普通的、名叫 .pm 的用户目录要走进去（判身份靠内容不靠名字）" caseUserDotPmIsWalked
    , testCase "EXIF：子 IFD 缺 4 字节 next-IFD offset → 结构不完整，读不到时间" caseIfdNeedsNextOffset
    , testCase "诊断要真的印出来：源根是 junction 时 sfNotes 出现在输出里" caseNotesArePrinted
    , testCase "暂存区新鲜度不过 → 被选中的文件逐条列出（计划前失败的第三条路径）" caseFreshnessAbortReportsAll
    , testCase "源文件读取失败整批拒绝 → 读得出的那些也要列出（第四条路径）" caseSnapshotAbortReportsAll
    , testCase "被选中清单不得截断：超过 40 个也要逐条列全" caseChosenNotTruncated
    ]

-- ─── pm sort 纯核心 ────────────────────────────────────────────────────────

d :: Integer -> Int -> Int -> Day
d = fromGregorian

at :: Integer -> Int -> Int -> Int -> LocalTime
at y m dd h = LocalTime (d y m dd) (TimeOfDay h 0 0)

caseSegment :: IO ()
caseSegment = do
  -- 阈值 72 小时。输入故意乱序，segmentBy 必须自己排。
  let xs :: [(String, LocalTime)]
      xs =
        [ ("c", at 2026 6 20 12)
        , ("a", at 2026 6 14 8)
        , ("b", at 2026 6 15 9)
        , ("e", at 2026 8 5 6)
        ]
      segs = map (map fst) (segmentBy (72 * 3600) xs)
  -- 排序后 a(6-14 08) b(6-15 09) c(6-20 12) e(8-05 06)；
  -- 相邻间隔 a→b 25h（≤72 同段）、b→c 123h（>72 切开）、c→e 切开。
  segs @?= [["a", "b"], ["c"], ["e"]]
  -- 恰好等于阈值算同一段（边界闭合，改成 < 会把它切开）
  map (map fst) (segmentBy (72 * 3600) [("x" :: String, at 2026 1 1 0), ("y", at 2026 1 4 0)])
    @?= [["x", "y"]]
  -- 差一秒就超过阈值 → 切开
  map (map fst) (segmentBy (72 * 3600 - 1) [("x" :: String, at 2026 1 1 0), ("y", at 2026 1 4 0)])
    @?= [["x"], ["y"]]
  segmentBy 3600 ([] :: [(String, LocalTime)]) @?= []

caseEventName :: IO ()
caseEventName = do
  eventNameFor (d 2026 8 25) "Atlanta" @?= Just "26-08-Atlanta"
  eventNameFor (d 2026 1 3) "R66" @?= Just "26-01-R66" -- 月份补零
  eventNameFor (d 2005 12 31) "X" @?= Just "05-12-X" -- 年份取后两位并补零
  eventNameFor (d 2026 8 25) "" @?= Nothing
  -- 路径分隔符与 Windows 保留字符一律拒绝：它们会让目标路径逃出事件夹
  eventNameFor (d 2026 8 25) "a/b" @?= Nothing
  eventNameFor (d 2026 8 25) "a\\b" @?= Nothing
  eventNameFor (d 2026 8 25) "a:b" @?= Nothing
  eventNameFor (d 2026 8 25) "a*b" @?= Nothing
  -- Scheme A 只存两位年，而 Names.yearFolder 无条件补 "20"：2000-2099 之外
  -- 会被静默折到错世纪（1999 → 2099）。宁可拒，不可默默归错年。
  eventNameFor (d 1999 12 31) "X" @?= Nothing
  eventNameFor (d 2100 1 1) "X" @?= Nothing
  eventNameFor (d 2000 1 1) "X" @?= Just "00-01-X" -- 下边界含
  eventNameFor (d 2099 12 31) "X" @?= Just "99-12-X" -- 上边界含

casePick :: IO ()
casePick = do
  let xs =
        [ ("A/_1.ARW", at 2026 8 1 6)
        , ("A/_2.ARW", at 2026 8 3 20)
        , ("A/_3.ARW", at 2026 8 9 6) -- 区间外
        ]
      p = pickFiles [] (d 2026 8 1) (d 2026 8 3) xs
  map fst (spTake p) @?= ["A/_1.ARW", "A/_2.ARW"] -- 含首含尾
  spCollide p @?= []
  spSidecars p @?= []
  -- 同一个 basename 来自两个源子目录 → 整批拒绝（落位后会互相覆盖）。
  -- 大小写不同也算撞名：NTFS 不区分大小写，落位后是同一个目标。
  let ys = [("A/x.ARW", at 2026 8 1 6), ("B/X.arw", at 2026 8 2 6)]
      q = pickFiles [] (d 2026 8 1) (d 2026 8 3) ys
  spCollide q @?= [("x.arw", ["A/x.ARW", "B/X.arw"])]

-- | 侧车必须跟着主文件进同一批：照片进了暂存区而 .xmp 留在卡上，用户清卡
-- 之后调色参数就永久没了。
casePickSidecars :: IO ()
casePickSidecars = do
  let cars = ["A/_1.xmp", "A/_9.xmp", "A/nobody.xmp"]
      xs =
        [ ("A/_1.ARW", at 2026 8 1 6)
        , ("A/_1.JPG", at 2026 8 1 6) -- RAW+JPEG 双拍认领同一个侧车
        , ("A/_9.ARW", at 2026 8 9 6) -- 区间外
        ]
      p = pickFiles cars (d 2026 8 1) (d 2026 8 3) xs
  -- 去重：同一个侧车被两个主文件认领，只能进一次，否则两条计划项写同一目标
  spSidecars p @?= ["A/_1.xmp"]
  spCollide p @?= []
  -- 区间外的可定时文件必须留底，否则用户清卡后才发现少了（codex 25 轮 #4）
  map fst (spOutOfRange p) @?= ["A/_9.ARW"]
  -- 无人认领的侧车同样留底：_9.xmp 的主文件在区间外，nobody.xmp 根本没主文件。
  -- 两者都不会被搬走，而它们装的是调色参数（#5）
  spOrphanCars p @?= ["A/_9.xmp", "A/nobody.xmp"]
  -- 撞名检查要含侧车：主文件撞名时侧车必然也撞名，漏查就只拒了一半
  let ys = [("A/x.ARW", at 2026 8 1 6), ("B/x.JPG", at 2026 8 2 6)]
      q = pickFiles ["A/x.xmp", "B/x.xmp"] (d 2026 8 1) (d 2026 8 3) ys
  map fst (spCollide q) @?= ["x.xmp"]

-- | 判定按**目标位置**做，不是"sha 在库里出现过就算数"。后者会把合法属于
-- 第二个事件的同一张照片静默丢掉。
caseClassify :: IO ()
caseClassify = do
  classifyDst Nothing Nothing "aa" @?= VCopy
  classifyDst (Just "aa") Nothing "aa" @?= VAtDest -- 重跑幂等
  classifyDst Nothing (Just "aa") "aa" @?= VArchived -- import 迟早判冗余
  -- 目标占着、内容不同 → 交人裁决，绝不静默覆盖（I5）
  case classifyDst (Just "bb") Nothing "aa" of
    VConflict _ -> pure ()
    v -> assertFailure ("暂存目标异容应待裁决，得到 " <> show v)
  -- 归档目标异容**不**在 sort 拦：那是 import 的返修裁决（irRework）管的事，
  -- 抢在它前面会让同一件事有两套判据
  classifyDst Nothing (Just "bb") "aa" @?= VCopy

-- | 组内一荣俱荣：主文件待裁决时同 stem 的侧车必须一起悬置，不能先落位
-- （先拷会产生孤立侧车；--keep both 改名时更会指错主文件）。
caseHoldKin :: IO ()
caseHoldKin = do
  let out =
        holdKin
          [ ("d/x.ARW", VConflict "异容")
          , ("d/x.xmp", VCopy) -- 同目录同 stem → 悬置
          , ("d/y.ARW", VCopy) -- 不同 stem → 不受影响
          , ("D/X.acr", VCopy) -- 大小写不同仍是同一组
          , ("e/x.xmp", VCopy) -- 不同目录的同名 stem → 不受影响
          ]
  map (isHeld . snd) out @?= [True, True, False, True, False]
 where
  isHeld (VConflict _) = True
  isHeld _ = False

caseResolve :: IO ()
caseResolve = do
  resolveEvent (d 2026 8 25) (Left "Atlanta") @?= Right "26-08-Atlanta"
  resolveEvent (d 2026 8 25) (Right "26-04-Providence") @?= Right "26-04-Providence"
  -- --event 也要过 canonRawEvent：不合 Scheme A 的名字现在就拒，
  -- 不能等到 pm import 认不出这个目录时才报
  case resolveEvent (d 2026 8 25) (Right "junk") of
    Left _ -> pure ()
    Right e -> assertFailure ("非法事件名应被拒: " <> e)
  case resolveEvent (d 2026 8 25) (Left "a/b") of
    Left _ -> pure ()
    Right e -> assertFailure ("非法地点应被拒: " <> e)
  -- --event 必须**另过**同一道字符闸：canonRawEvent 只约束前 6 个字符，
  -- 地点部分它不设限，所以只在 --place 上设闸等于给 --event 留了绕行口。
  -- "26-04-a\..\..\x" 合 Scheme A 的形状，却能让目标逃出事件夹。
  forM_ ["26-04-a/b", "26-04-a\\b", "26-04-a:b", "26-04-a*b", "26-04-a|b"] $ \ev ->
    case resolveEvent (d 2026 8 25) (Right ev) of
      Left _ -> pure ()
      Right e -> assertFailure ("含非法字符的 --event 应被拒: " <> e)

-- ─── 合成夹具（端序参数化） ────────────────────────────────────────────────

-- 端序：True = little-endian。此前夹具把 "II" 写死，**大端路径零覆盖**——
-- 而 endianAt/u16/u32 三处都按端序分支，对抗审查点出那是整块未测代码。
-- 抽出取字节这一步（而不是在两处各写一遍 let）：两个函数只在**宽度**上不同，
-- 端序反转是同一件事。指数 k 必须钉成 Int，否则 (^) 的指数无约束而默认到
-- Integer（-Wtype-defaults）。
byteAt :: Int -> Int -> Word8
byteAt n k = fromIntegral ((n `div` (256 ^ k)) `mod` 256)

u16e, u32e :: Bool -> Int -> [Word8]
u16e le n = (if le then id else reverse) (map (byteAt n) [0, 1])
u32e le n = (if le then id else reverse) (map (byteAt n) [0 .. 3])

ascii :: String -> [Word8]
ascii = map (fromIntegral . fromEnum)

-- | 最小 TIFF：IFD0 一条 ExifIFDPointer（类型/个数可控，用来钉那道闸），
-- 子 IFD 一条 ASCII 时间标签，字面量在尾部。
--
-- 偏移布局（相对 TIFF 头）：
-- @0 魔数 · 4 IFD0=8 · 8 计数 · 10 条目 · 22 next=0 · 26 子IFD计数 ·
--  28 条目 · 40 next=0 · 44 ASCII(20)@
tiffPtr :: Bool -> Int -> Int -> Int -> String -> [Word8]
tiffPtr le ptrType ptrCount tag dt =
  ascii (if le then "II" else "MM")
    <> (if le then [0x2A, 0x00] else [0x00, 0x2A])
    <> u32e le 8
    <> u16e le 1
    <> u16e le 0x8769
    <> u16e le ptrType
    <> u32e le ptrCount
    <> u32e le 26
    <> u32e le 0
    <> u16e le 1
    <> u16e le tag
    <> u16e le 2 -- ASCII
    <> u32e le 20
    <> u32e le 44
    <> u32e le 0
    <> ascii dt
    <> [0x00]

-- | 常规形态：LONG 指针、个数 1、DateTimeOriginal。
tiffWith :: Bool -> String -> [Word8]
tiffWith le = tiffPtr le 4 1 0x9003

-- | IFD0 里直接放一个 ASCII 标签（无子 IFD），用来验「不再回退到修改时间」。
tiffIfd0Only :: Bool -> Int -> String -> [Word8]
tiffIfd0Only le tag dt =
  ascii (if le then "II" else "MM")
    <> (if le then [0x2A, 0x00] else [0x00, 0x2A])
    <> u32e le 8
    <> u16e le 1
    <> u16e le tag
    <> u16e le 2
    <> u32e le 20
    <> u32e le 26
    <> u32e le 0
    <> ascii dt
    <> [0x00]

beLen :: Int -> [Word8]
beLen n = [fromIntegral (n `div` 256), fromIntegral (n `mod` 256)]

-- | 一个无实义载荷的段：@FF marker len16(be) 填充@。
seg :: Word8 -> Int -> [Word8]
seg marker n = [0xFF, marker] <> beLen (n + 2) <> replicate n 0x00

-- | 把 TIFF 包进 JPEG。@before@ 是排在 Exif APP1 **之前**的段——此前夹具把
-- Exif 放在第一个，段链的递归推进从未被执行过（对抗审查指出）。
jpegWrapAfter :: [Word8] -> [Word8] -> [Word8]
jpegWrapAfter before tiff =
  [0xFF, 0xD8]
    <> before
    <> [0xFF, 0xE1]
    <> beLen (2 + 6 + length tiff)
    <> ascii "Exif"
    <> [0x00, 0x00]
    <> tiff

jpegWrap :: [Word8] -> [Word8]
jpegWrap = jpegWrapAfter []

bs :: [Word8] -> BS.ByteString
bs = BS.pack

sample :: String
sample = "2026:08:25 13:45:07"

want :: String
want = "Just 2026-08-25 13:45:07"

-- ─── 用例 ───────────────────────────────────────────────────────────────────

-- | 两种容器 × 两种端序都读得到。大端此前完全没测。
caseExifBothContainers :: IO ()
caseExifBothContainers = mapM_ each [True, False]
 where
  each le = do
    let t = tiffWith le sample
    show (parseCaptureTime (bs t)) @?= want
    show (parseCaptureTime (bs (jpegWrap t))) @?= want

-- | JPEG 段链：Exif 段前面还有别的段时必须走到它；标记前的填充字节与
-- 独立标记（RST/TEM，无长度字段）都不得让段链走偏。
caseExifJpegChain :: IO ()
caseExifJpegChain = do
  let t = tiffWith True sample
  -- 前置一个 APP0（JFIF 常态）+ 一个非 Exif 的 APP1（如 XMP）
  show (parseCaptureTime (bs (jpegWrapAfter (seg 0xE0 14 <> seg 0xE1 20) t))) @?= want
  -- 标记前的填充字节
  show (parseCaptureTime (bs (jpegWrapAfter (seg 0xE0 4 <> [0xFF, 0xFF]) t))) @?= want
  -- 独立标记：按"有长度"去读会把其后字节当长度，段链就废了
  show (parseCaptureTime (bs (jpegWrapAfter [0xFF, 0xD0, 0xFF, 0x01] t))) @?= want

-- | 只认真正的拍摄时间。IFD0 的 DateTime(0x0132) 是**文件修改时间**，
-- 2026-08-25 起不再作为回退——返回错时间比返回 Nothing 危险得多。
caseExifOnlyCaptureTags :: IO ()
caseExifOnlyCaptureTags = do
  show (parseCaptureTime (bs (tiffPtr True 4 1 0x9004 "2021:12:31 23:59:58")))
    @?= "Just 2021-12-31 23:59:58" -- DateTimeDigitized 仍认
  parseCaptureTime (bs (tiffIfd0Only True 0x0132 "2020:01:02 03:04:05")) @?= Nothing
  parseCaptureTime (bs (tiffIfd0Only False 0x0132 "2020:01:02 03:04:05")) @?= Nothing

-- | 子 IFD 指针：类型放宽到 LONG(4) 与 IFD(13)，但个数必须恰为 1
-- （count > 1 时值字段指向 LONG 数组，拿它当偏移会解析到垃圾）。
caseExifSubIfdPointer :: IO ()
caseExifSubIfdPointer = do
  show (parseCaptureTime (bs (tiffPtr True 13 1 0x9003 sample))) @?= want
  parseCaptureTime (bs (tiffPtr True 4 2 0x9003 sample)) @?= Nothing
  parseCaptureTime (bs (tiffPtr True 3 1 0x9003 sample)) @?= Nothing -- SHORT 不是指针类型

caseExifFailClosed :: IO ()
caseExifFailClosed = do
  let t = tiffWith True sample
  -- 截断到 ASCII 之前：偏移指向缓冲区外 → 放弃，不返回半个时间
  parseCaptureTime (bs (take 44 t)) @?= Nothing
  -- 前两字节对但 0x002A 不对——此前 endianAt 只比两字节，会放行
  parseCaptureTime (bs (ascii "II" <> [0x00, 0x00] <> drop 4 t)) @?= Nothing
  parseCaptureTime (bs (ascii "NOPE" <> drop 4 t)) @?= Nothing
  -- 伪 APP1：载荷以 II 开头但不是 TIFF 头
  parseCaptureTime (bs (jpegWrap (ascii "II" <> [0x00, 0x00] <> drop 4 t))) @?= Nothing
  parseCaptureTime "hello world, not a photo at all" @?= Nothing
  parseCaptureTime "" @?= Nothing
  -- 相机没设过时间：全零日期不得当成有效拍摄时间（否则会造出假事件）
  parseCaptureTime (bs (tiffPtr True 4 1 0x9003 "0000:00:00 00:00:00")) @?= Nothing
  -- JPEG 头但段链里没有 Exif（只有 SOS）→ 放弃
  parseCaptureTime (bs [0xFF, 0xD8, 0xFF, 0xDA, 0x00, 0x02]) @?= Nothing
  -- IFD0 偏移指到「尾端前一字节」：u16 在那里只能取到 1 字节。
  -- 这一条专钉 sliceAt 的**上界**检查——ByteString 的 take/drop 是全函数，
  -- 越界只静默截短不抛错，所以"截断"那条用例两边行为相同、钉不住它；
  -- 而 u16/u32 随后对切片做 BS.index，短一个字节就抛异常。（突变 K 暴露）
  parseCaptureTime (bs (ascii "II" <> [0x2A, 0x00] <> u32e True 9 <> [0x00, 0x00])) @?= Nothing

caseExifLiteral :: IO ()
caseExifLiteral = do
  show (parseExifDateTime "2026:08:25 13:45:07") @?= want
  parseExifDateTime "2026-08-25 13:45:07" @?= Nothing -- 分隔符必须是冒号
  parseExifDateTime "2026:13:01 00:00:00" @?= Nothing -- 13 月
  parseExifDateTime "2026:02:30 00:00:00" @?= Nothing -- 2 月 30 日
  parseExifDateTime "2026:08:25 24:00:00" @?= Nothing -- 24 时
  parseExifDateTime "2026:08:25 13:45" @?= Nothing -- 长度不对
  parseExifDateTime "20x6:08:25 13:45:07" @?= Nothing -- 非数字

-- ─── 端到端（真目录 · 真 catalog · 计划落盘） ───────────────────────────────
--
-- 纯核心的用例钉不住 IO 接线：目录扫描把照片与侧车分两摞、可信索引这道闸、
-- snapshotSrc 的前后双 stat、计划真的落到 .pm\plans。2026-08-25 对抗审查确认
-- 的 10 条里有 4 条就在这一层，所以这一层必须有自己的用例。

-- | 造一个能被 readCaptureTime 读出时间的最小 JPEG（APP1 里包一个最小 TIFF）。
photoAt :: String -> BS.ByteString
photoAt dt = bs (jpegWrap (tiffWith True dt))

-- | 铺一个**库外**源目录 + 一个已扫描的主库 root。
withLib :: (FilePath -> FilePath -> Config -> IO ()) -> IO ()
withLib k = withSystemTempDirectory "pm-sort" $ \tmp -> do
  let src = tmp </> "card"
      root = tmp </> "lib"
  createDirectoryIfMissing True (src </> "DCIM")
  BS.writeFile (src </> "DCIM" </> "a.ARW") (photoAt "2026:08:25 10:00:00")
  BS.writeFile (src </> "DCIM" </> "a.xmp") "sidecar-for-a"
  BS.writeFile (src </> "DCIM" </> "b.ARW") (photoAt "2026:08:26 10:00:00")
  BS.writeFile (src </> "DCIM" </> "z.ARW") "not a photo at all" -- 读不到拍摄时间
  createDirectoryIfMissing True root
  _ <- ensureTestRoot RoleMain root
  scanQuiet "test-root" root >>= saveCatalog root
  k src root (Config root Nothing Nothing Nothing Nothing Nothing)

sortPlan :: FilePath -> Config -> IO Int
sortPlan src cfg = fst <$> runSortPlan (GoOpts False False) src (Left "Atlanta") (d 2026 8 25) (d 2026 8 26) cfg

-- | Pm.Plan 不导出 plansDir，从 planPath 反推——好过在测试里第二次写死
-- ".pm\plans"，那样目录一改测试还会绿。
plansDirOf :: FilePath -> FilePath
plansDirOf root = takeDirectory (planPath root "x")

planItemsIn :: FilePath -> IO [PlanItem]
planItemsIn root = do
  ps <- sort <$> listDirectory (plansDirOf root)
  case ps of
    [f] -> do
      r <- loadPlan root (T.pack (take (length f - 5) f)) -- 去掉 ".json"
      case r of
        Left e -> assertFailure ("计划装不回来: " <> e) >> pure []
        Right pl -> pure (plItems pl)
    other -> assertFailure ("期望恰好一个计划，实际 " <> show other) >> pure []

caseSortE2E :: IO ()
caseSortE2E = withLib $ \src root cfg -> do
  rc <- sortPlan src cfg
  rc @?= 1 -- 计划已存、未 --apply（两段式，confirm 为否）
  items <- planItemsIn root
  -- 侧车必须同批：漏了它，用户清卡后调色参数就永久没了
  let dsts = map (opDstRel . piOp) items
  sort (map takeFileName dsts) @?= ["a.ARW", "a.xmp", "b.ARW"]
  -- 落位到 Scheme A 事件夹；z.ARW 读不到拍摄时间 → 不进计划（不猜）
  sort dsts
    @?= map (("To-Be-Sync'd" </> "Raw" </> "26-08-Atlanta") </>) ["a.ARW", "a.xmp", "b.ARW"]
  map piStatus items @?= replicate 3 StPending
  -- 源零改动：sort 是拷贝不是移动（源可能是相机卡，I2），且此处根本没执行
  ls <- sort <$> listDirectory (src </> "DCIM")
  ls @?= ["a.ARW", "a.xmp", "b.ARW", "z.ARW"]
  BS.readFile (src </> "DCIM" </> "a.xmp") >>= (@?= "sidecar-for-a")

caseSortE2EGates :: IO ()
caseSortE2EGates = withLib $ \src root cfg -> do
  -- ① 无索引 → 拒绝出计划。此前这里是"当作目标位置为空"，那是默认覆盖的方向
  removeFile (catalogPath root)
  rc0 <- sortPlan src cfg
  rc0 @?= 2
  doesDirectoryExist (plansDirOf root) >>= (@?= False)
  -- ② 目标位置被**异容**文件占住 → 整组待裁决，绝不静默覆盖（I5）
  let dstDir = root </> "To-Be-Sync'd" </> "Raw" </> "26-08-Atlanta"
      squatter = photoAt "2000:01:01 00:00:00"
  createDirectoryIfMissing True dstDir
  BS.writeFile (dstDir </> "a.ARW") squatter -- 同名不同容
  scanQuiet "test-root" root >>= saveCatalog root
  rc1 <- sortPlan src cfg
  rc1 @?= 1
  items <- planItemsIn root
  let held = [(takeFileName (opDstRel (piOp i)), isDecision (piStatus i)) | i <- items]
  -- a.ARW 异容 → 待裁决；a.xmp 是它的同 stem 侧车 → 一并悬置（不得先行落位，
  -- 否则会产生孤立侧车）；b.ARW 与冲突无关 → 照常待拷
  lookup "a.ARW" held @?= Just True
  lookup "a.xmp" held @?= Just True
  lookup "b.ARW" held @?= Just False
  -- 计划期什么都没写进目标：占位文件字节不动
  BS.readFile (dstDir </> "a.ARW") >>= (@?= squatter)
 where
  isDecision (StNeedsDecision _) = True
  isDecision _ = False

-- | 易变守卫。断言两件事，缺一不可：
--   ① **次序**是 stat → hash → stat（hash 必须夹在两次 stat 之间——先 hash
--      再两次 stat，或两次 stat 挨着，都测不出"hash 期间被改动"）；
--   ② 两次 stat 不同 → 不返回 sha，而不是返回一个撕裂的 sha。
-- 注入的意义就在这里：用真实文件只能靠制造竞态，那是片状用例。
caseVolatileGuard :: IO ()
caseVolatileGuard = do
  let s0 = StatSnap 10 100
      s1 = StatSnap 11 200
  -- 稳定：两次 stat 相同 → 出 sha，且取的是**后**一次快照
  trace0 <- newIORef [] :: IO (IORef [String])
  r0 <- snapshotWith (rec trace0 "stat" s0) (rec trace0 "hash" "sha-x") "p"
  r0 @?= Right ("sha-x", s0)
  readIORef trace0 >>= (@?= ["stat", "hash", "stat"])
  -- 易变：第二次 stat 变了 → Left，绝不带出 sha
  ref <- newIORef [s0, s1] :: IO (IORef [StatSnap])
  trace1 <- newIORef [] :: IO (IORef [String])
  r1 <- snapshotWith (pop ref trace1) (rec trace1 "hash" "sha-torn") "p"
  case r1 of
    Left _ -> pure ()
    Right v -> assertFailure ("hash 期间被改动仍返回了 sha: " <> show v)
  readIORef trace1 >>= (@?= ["stat", "hash", "stat"])
 where
  rec t tag v _ = modifyIORef' t (<> [tag]) >> pure v
  pop ref t _ = do
    modifyIORef' t (<> ["stat"])
    xs <- readIORef ref
    case xs of
      (x : rest) -> writeIORef' ref rest >> pure x
      [] -> assertFailure "stat 被调用的次数超出预期" >> pure (StatSnap 0 0)
  writeIORef' r v = modifyIORef' r (const v)

-- | 暂存区新鲜度闸。突变验证发现：这道闸自 P2 起就在 'runImport' 里，
-- **全项目却没有任何用例钉住它**——拆掉它 236 例全绿（2026-08-25，突变 N2b）。
-- sort 复用同一份定义（'withFreshStagingCatalog'），于是在这里一并补上。
--
-- 为什么它重要：sort 判"目标位置上有没有东西"依据的是索引。索引落后于盘面
-- 时，一个已经躺在目标位置的文件在索引里不存在，判定就会给出 VCopy——即
-- 「目标为空，照拷」。执行层虽有 I5 兜底，但那时用户已经看过一份说"待拷 N 张"
-- 的计划了。
caseSortE2EStale :: IO ()
caseSortE2EStale = withLib $ \src root cfg -> do
  -- 扫描之后才出现的暂存文件：索引里没有它 → 新鲜度扫掠报"新增 1"
  let stray = root </> "To-Be-Sync'd" </> "Raw" </> "26-08-Atlanta"
  createDirectoryIfMissing True stray
  BS.writeFile (stray </> "stray.ARW") (photoAt "2026:08:25 10:00:00")
  rc <- sortPlan src cfg
  rc @?= 2
  doesDirectoryExist (plansDirOf root) >>= (@?= False)
  -- 重扫之后同一条命令就该通过：证明上面的 exit 2 确由**新鲜度**产生，
  -- 而不是这个 fixture 里别的什么东西
  scanQuiet "test-root" root >>= saveCatalog root
  rc2 <- sortPlan src cfg
  rc2 @?= 1

-- | IFD 偏移的下界。TIFF 头占 0..7，@0@ 在 TIFF 里的含义是「没有 IFD」。
-- 没有这道下界时，声明 @ifd0 = 0@ 的文件会从偏移 0 读条目数——那两个字节
-- 正是魔数的 "II"（= 18761 条），于是条目 1 落在偏移 14，在那里放一个伪造的
-- 0x8769 指针就能让「没有 IFD」的文件返回**自信的拍摄时间**。
-- （codex 二十五轮 #1；修复前本地探针两条容器路径都返回 Just）
caseExifIfdOffset :: IO ()
caseExifIfdOffset = do
  let evil =
        ascii "II"
          <> [0x2A, 0x00]
          <> u32e True 0 -- IFD0 偏移 = 0
          <> replicate 6 0x00 -- 补齐"条目 0"（占 2..13）
          <> u16e True 0x8769 -- 14..25：伪造的 ExifIFDPointer
          <> u16e True 4
          <> u32e True 1
          <> u32e True 26
          <> u16e True 1 -- 26：子 IFD 条目数
          <> u16e True 0x9003
          <> u16e True 2
          <> u32e True 20
          <> u32e True 44
          <> u32e True 0
          <> ascii sample
          <> [0x00]
  parseCaptureTime (bs evil) @?= Nothing
  parseCaptureTime (bs (jpegWrap evil)) @?= Nothing
  -- 1..7 落在 TIFF 头内部，同样不是合法 IFD 起点
  forM_ [1 .. 7] $ \o ->
    parseCaptureTime (bs (ascii "II" <> [0x2A, 0x00] <> u32e True o <> drop 8 evil)) @?= Nothing
  -- 合法下界 8 仍然照读（这道闸不能把正常文件一起关在门外）
  show (parseCaptureTime (bs (tiffWith True sample))) @?= want

-- | 相机原生 raw 的清单只能有一份。'Pm.Versions' 曾另抄一份（12 种），而
-- 'classifyExt' 只认 .arw/.dng——尼康/佳能/富士的卡进 pm sort，每个 raw 都被
-- 判成 KindMeta 而**静默忽略**，连计数里都不出现（codex 二十五轮 #5）。
caseRawExts :: IO ()
caseRawExts = do
  forM_ rawExts $ \e -> classifyExt e @?= KindPhoto
  forM_ [".NEF", ".Cr3", ".RAF"] $ \e -> classifyExt e @?= KindPhoto -- 大小写不敏感
  classifyExt ".psb" @?= KindPhoto -- .psd 的大文件变体，此前漏了
  classifyExt ".txt" @?= KindMeta
  classifyExt ".zip" @?= KindMeta

-- | 索引说「已在目标位置」，但盘上那个文件的**内容**其实不同（同尺寸改写后
-- 把 mtime 改回去，(size,mtime) 新鲜度扫掠看不出来）。跳过是一个「这张不用
-- 搬了」的决定，凭一份没核对过的 sha 做它就是静默丢文件（codex 25 轮 #2）。
caseSortE2EStaleSkip :: IO ()
caseSortE2EStaleSkip = withLib $ \src root cfg -> do
  let dstDir = root </> "To-Be-Sync'd" </> "Raw" </> "26-08-Atlanta"
      good = photoAt "2026:08:25 10:00:00" -- 与源 a.ARW 逐字节相同
  createDirectoryIfMissing True dstDir
  BS.writeFile (dstDir </> "a.ARW") good
  scanQuiet "test-root" root >>= saveCatalog root
  -- 此刻索引是诚实的：a.ARW 已在目标位置 → 不该进计划
  rc0 <- sortPlan src cfg
  rc0 @?= 1
  items0 <- planItemsIn root
  sort (map (takeFileName . opDstRel . piOp) items0) @?= ["a.xmp", "b.ARW"]
  -- 现在让索引说谎：同尺寸改写 + 把 mtime 改回去。扫掠看不出变化，
  -- 但目标的实际内容已经不是 a.ARW 了。
  st <- getModificationTime (dstDir </> "a.ARW")
  let evil = BS.map (\w -> if w == 0x00 then 0x01 else w) good
  BS.length evil @?= BS.length good -- 尺寸不变才构成本用例
  BS.writeFile (dstDir </> "a.ARW") evil
  setModificationTime (dstDir </> "a.ARW") st
  removeDirectoryRecursive (plansDirOf root)
  rc1 <- sortPlan src cfg
  rc1 @?= 1
  items1 <- planItemsIn root
  let named = [(takeFileName (opDstRel (piOp i)), piStatus i) | i <- items1]
  -- a.ARW 必须重新出现——要么待拷、要么待裁决，就是不能被静默跳过
  lookup "a.ARW" named /= Nothing @?= True
  -- 目标字节未被本命令改动（只出计划，未 --apply）
  BS.readFile (dstDir </> "a.ARW") >>= (@?= evil)

-- | 遍历纪律：源里的 junction 不跟随（自写递归会无限下降，或把源范围之外的
-- 照片纳入计划），认不出的扩展名单列而不是吞掉（codex 25 轮 #6/#5）。
caseSortE2ETraversal :: IO ()
caseSortE2ETraversal = withSystemTempDirectory "pm-sort-tv" $ \tmp -> do
  let src = tmp </> "card"
      outside = tmp </> "outside"
  createDirectoryIfMissing True (src </> "DCIM")
  createDirectoryIfMissing True outside
  BS.writeFile (src </> "DCIM" </> "a.ARW") (photoAt "2026:08:25 10:00:00")
  BS.writeFile (src </> "DCIM" </> "notes.txt") "not a photo"
  BS.writeFile (outside </> "secret.ARW") (photoAt "2026:08:25 11:00:00")
  -- 指向源目录之外的 junction：跟随它就会把 secret.ARW 纳入
  _ <- readCreateProcess (shell ("mklink /J \"" <> (src </> "link") <> "\" \"" <> outside <> "\"")) ""
  sf <- listSource src
  map takeFileName (sfPhotos sf) @?= ["a.ARW"]
  map takeFileName (sfUnknown sf) @?= ["notes.txt"] -- 认不出但**列出来**
  -- junction 被跳过并记成一条错误，而不是静默跟随，也不是静默丢弃
  map (takeFileName . fst) (sfErrors sf) @?= ["link"]

-- | IFD 声明的条目数必须自洽。此前是**截断**（取前 4096 条，越界条目由
-- sliceAt 悄悄丢掉），于是一个谎报 count=65535、实际只有 1 条的文件照样
-- 返回时间。截断等于接受一个前缀，而损坏文件的正解是 fail-closed。
-- （codex 二十六轮 #6；修复前本地探针四种 count 全部返回 Just）
caseExifIfdCount :: IO ()
caseExifIfdCount = do
  -- 偏移由程序算，不手写：本轮两次手算偏移都错了，错的夹具会让用例假绿。
  let subAt = 200
      litAt = subAt + 18
      mk cnt =
        let head8 = ascii "II" <> [0x2A, 0x00] <> u32e True 8
            ifd0 = u16e True cnt <> u16e True 0x8769 <> u16e True 4 <> u32e True 1 <> u32e True subAt
            pad = replicate (subAt - (length head8 + length ifd0)) 0x00
            sub =
              u16e True 1
                <> u16e True 0x9003
                <> u16e True 2
                <> u32e True 20
                <> u32e True litAt
                <> u32e True 0
         in head8 <> ifd0 <> pad <> sub <> ascii sample <> [0x00]
  -- 诚实声明：照读（这道闸不能把正常文件一起关在门外）
  show (parseCaptureTime (bs (mk 1))) @?= want
  -- count=3 **不是**这道闸能抓的谎：3 条条目的字节确实都在缓冲区里（多出的
  -- 两条读到填充零），声明与盘面自洽。"声明数超过有意义的条目数"原理上不可
  -- 判定——尾部的零条目与填充无从区分。所以这里断言它照读，把这道闸的边界
  -- 写清楚，而不是假装它管得更宽。
  show (parseCaptureTime (bs (mk 3))) @?= want
  -- 真正的谎报：声明的 IFD 整个装不下（2 + n*12 越出缓冲区）→ 作废
  parseCaptureTime (bs (mk 5000)) @?= Nothing -- 60002 字节，缓冲区只有 238
  parseCaptureTime (bs (mk 65535)) @?= Nothing -- 786422 字节
  -- 上限本身也是一道独立的闸：即使缓冲区足够大，超过 maxIfdEntries 也作废
  parseCaptureTime (bs (mk 5000 <> replicate 100000 0x00)) @?= Nothing

-- | 库根的遍历策略（跳过 .pm/.git 且不报告）不能原样用在**源目录**上：
-- 那里点开头的目录只是普通文件夹，里面完全可能有照片。
-- （codex 二十六轮 #3：修复前 card\.hidden\a.ARW 连一条记录都不留地消失）
caseSourceDotDirs :: IO ()
caseSourceDotDirs = withSystemTempDirectory "pm-sort-dot" $ \tmp -> do
  let src = tmp </> "card"
  createDirectoryIfMissing True (src </> ".hidden")
  createDirectoryIfMissing True (src </> "DCIM")
  BS.writeFile (src </> "DCIM" </> "a.ARW") (photoAt "2026:08:25 10:00:00")
  BS.writeFile (src </> ".hidden" </> "b.ARW") (photoAt "2026:08:26 10:00:00")
  sf <- listSource src
  sort (map takeFileName (sfPhotos sf)) @?= ["a.ARW", "b.ARW"]

-- | 校验性读取必须**逐级限域**后再打开。库内某层是 junction 时，被"验证"的
-- 其实是库外的文件——这个结论下游是「已归档，不用搬」与（clean 那侧）
-- 「副本还在，可以永久删」。（codex 二十六轮 #1）
caseProbeConfined :: IO ()
caseProbeConfined = withSystemTempDirectory "pm-probe" $ \tmp -> do
  let root = tmp </> "lib"
      outside = tmp </> "outside"
  createDirectoryIfMissing True (root </> "Raw")
  createDirectoryIfMissing True outside
  BS.writeFile (root </> "Raw" </> "real.ARW") "inside"
  BS.writeFile (outside </> "bait.ARW") "outside-bait"
  -- 正常路径：读得到内容
  p1 <- probeConfined root ("Raw" </> "real.ARW")
  case p1 of
    CpSha _ _ -> pure ()
    v -> assertFailure ("库内普通文件应读到 sha，得到 " <> show v)
  -- 不存在：缺席，与"读不到"必须区分开
  probeConfined root ("Raw" </> "nope.ARW") >>= (@?= CpMissing)
  -- 中途一层是 junction → 拒绝，不返回库外文件的 sha
  _ <- readCreateProcess (shell ("mklink /J " <> q (root </> "Raw" </> "link") <> " " <> q outside)) ""
  probeConfined root ("Raw" </> "link" </> "bait.ARW") >>= (@?= CpEscaped)
 where
  q p = [dq] <> p <> [dq]
  dq = toEnum 34

-- | 源根**自身**是 junction：listTree 只探子项、不探根。根由用户显式指定，
-- 与「库根放在 junction 上」一样是合法用法，所以不拒绝——但必须告诉用户他
-- 实际在整理哪个目录。（codex 二十六轮 #5，判定为告知而非拒绝）
caseSourceRootLink :: IO ()
caseSourceRootLink = withSystemTempDirectory "pm-sort-root" $ \tmp -> do
  let real = tmp </> "real"
      link = tmp </> "card"
  createDirectoryIfMissing True real
  BS.writeFile (real </> "a.ARW") (photoAt "2026:08:25 10:00:00")
  _ <- readCreateProcess (shell ("mklink /J " <> q link <> " " <> q real)) ""
  sf <- listSource link
  map takeFileName (sfPhotos sf) @?= ["a.ARW"]
  -- 照片照常列出，源根是链接这件事出现在**诊断**里而不是错误里：
  -- 它是一条说明，不是"一个没归位的文件"，混进 sfErrors 会让「未入计划 N 个」
  -- 多算 1（codex 二十七轮 #5）
  any (elemSub "源根本身是 symlink/junction") (sfNotes sf) @?= True
  sfErrors sf @?= []
 where
  q p = [dq] <> p <> [dq]
  dq = toEnum 34

-- | 'wholeIfdFits' 必须能**单独**转红。上一版用例的 count=5000/65535 同时也被
-- 'maxIfdEntries' 拦下，于是拆掉 wholeIfdFits 时无一用例转红（突变 Q1 全绿）。
-- 这里取 count=100：远低于 4096 上限，但 2 + 100*12 = 1202 字节装不进这个
-- 238 字节的缓冲区——只有 wholeIfdFits 能拦它。
caseExifIfdFits :: IO ()
caseExifIfdFits = do
  let subAt = 200
      litAt = subAt + 18
      mk cnt =
        let head8 = ascii "II" <> [0x2A, 0x00] <> u32e True 8
            ifd0 = u16e True cnt <> u16e True 0x8769 <> u16e True 4 <> u32e True 1 <> u32e True subAt
            pad = replicate (subAt - (length head8 + length ifd0)) 0x00
            sub =
              u16e True 1
                <> u16e True 0x9003
                <> u16e True 2
                <> u32e True 20
                <> u32e True litAt
                <> u32e True 0
         in head8 <> ifd0 <> pad <> sub <> ascii sample <> [0x00]
  length (mk 100) @?= 238 -- 钉住前提：缓冲区确实只有 238 字节
  parseCaptureTime (bs (mk 100)) @?= Nothing
  -- 同一个 count，把缓冲区补大到装得下 → 恢复照读，证明拦它的确实是"装不下"
  -- 而不是"100 这个数字"
  show (parseCaptureTime (bs (mk 100 <> replicate 1200 0x00))) @?= want

-- | 「存在但读不出」必须与「缺席」分开：两者的安全方向相反（缺席 → 照搬，
-- 读不出 → 保守拒绝）。末段是**目录**是本机可移植地造出这一态的办法
-- （实测 getFileSize 对目录返回 0，随后按文件打开报 permission denied）。
-- 突变 Q5（把 CpUnreadable 塌缩成 CpMissing）此前无一用例转红。
caseProbeUnreadable :: IO ()
caseProbeUnreadable = withSystemTempDirectory "pm-probe2" $ \tmp -> do
  let root = tmp </> "lib"
  createDirectoryIfMissing True (root </> "Raw" </> "adir")
  p <- probeConfined root ("Raw" </> "adir")
  case p of
    CpUnreadable _ -> pure ()
    v -> assertFailure ("存在但读不出应为 CpUnreadable，得到 " <> show v)
  -- 与真正的缺席分开
  probeConfined root ("Raw" </> "nope") >>= (@?= CpMissing)

-- | 目录列举失败必须变成一条**带路径的错误**，异常不得逃出去。
--
-- 这条用例暴露过一个真缺陷：'listDirectory' 是
-- @filter f \<$\> getDirectoryContents@，返回**惰性**列表，@try@ 只求值到
-- WHNF，异常会在消费列表时才炸——正好在 try 之外。所以光包 try 不够，必须
-- 在 try 内部强制列表脊。（突变 Q7 全绿暴露）
caseListDirFails :: IO ()
caseListDirFails = withSystemTempDirectory "pm-lsfail" $ \tmp -> do
  let f = tmp </> "notadir.txt"
  BS.writeFile f "x"
  r <- listTreeWith WalkDotDirs f
  fst r @?= []
  map fst (snd r) @?= ["."]
  any (elemSub "目录列举失败" . snd) (snd r) @?= True

-- | 源恰好是一个 pm 库根时，@.pm@ 必须**不进入**：@.pm/tmp@ 里是半写入的临时
-- 文件、@.pm/trash@ 里是已隔离的文件，它们头部有合法 EXIF，会被当成待归位的
-- 照片拷走（codex 二十七轮 #3）。跳过但记一条，不静默。
caseSourceSkipsPmDir :: IO ()
caseSourceSkipsPmDir = withSystemTempDirectory "pm-src-root" $ \tmp -> do
  let src = tmp </> "library"
  createDirectoryIfMissing True (src </> ".pm" </> "tmp" </> "p")
  createDirectoryIfMissing True (src </> ".pm" </> "trash" </> "17")
  -- 新判据按**内容**认 pm 状态目录：有 root-id.json 才是。一个真正的 pm 根
  -- 按定义就有它，所以 fixture 补上——这不是放宽，是把判据从名字换成身份
  -- （codex 二十八轮 #3）。
  writeFile (src </> ".pm" </> "root-id.json") "{}"
  createDirectoryIfMissing True (src </> ".hidden")
  createDirectoryIfMissing True (src </> "DCIM")
  BS.writeFile (src </> "DCIM" </> "real.ARW") (photoAt "2026:08:25 10:00:00")
  -- 这两个头部有合法 EXIF，但它们是 pm 的内部状态，不是用户的待归位照片
  BS.writeFile (src </> ".pm" </> "tmp" </> "p" </> "half.ARW") (photoAt "2026:08:25 11:00:00")
  BS.writeFile (src </> ".pm" </> "trash" </> "17" </> "quar.ARW") (photoAt "2026:08:25 12:00:00")
  -- 普通点目录仍然要走进去（第 26 轮 #3 的行为不能被这次收紧顺手撤销）
  BS.writeFile (src </> ".hidden" </> "hidden.ARW") (photoAt "2026:08:26 10:00:00")
  sf <- listSource src
  sort (map takeFileName (sfPhotos sf)) @?= ["hidden.ARW", "real.ARW"]
  -- 跳过 .pm 这件事必须留一条记录
  any (elemSub "pm 状态目录" . snd) (sfErrors sf) @?= True

-- | 'resolveUnder' 原理上看不见 hardlink，而 probeConfined 的下游一边是
-- 「三副本齐了，可以永久删」——三份必须是三个**独立对象**。
--
-- 判据在第 28 轮从 link count 换成了**文件身份**（codex 二十八轮 #2）：
-- nlink == 1 是充分而不必要的，一份合法归档照片被去重工具另建一个名字就会被
-- 一律拒读、长期 HELD。真正要钉住的性质是这一条——同一个对象的两个名字身份
-- **相同**，内容相同的两个独立文件身份**不同**。屏障据此判断"还剩几份"。
caseProbeHardlink :: IO ()
caseProbeHardlink = withSystemTempDirectory "pm-hl" $ \tmp -> do
  let root = tmp </> "lib"
      outside = tmp </> "outside.ARW"
  createDirectoryIfMissing True (root </> "Raw")
  BS.writeFile outside "shared-object"
  _ <- readCreateProcess (shell ("mklink /H " <> q (root </> "Raw" </> "hl.ARW") <> " " <> q outside)) ""
  _ <- readCreateProcess (shell ("mklink /H " <> q (root </> "Raw" </> "hl2.ARW") <> " " <> q outside)) ""
  -- 同内容、**独立**的第三个文件
  BS.writeFile (root </> "Raw" </> "plain.ARW") "shared-object"
  [a, b, c] <-
    mapM (probeConfined root . ("Raw" </>)) ["hl.ARW", "hl2.ARW", "plain.ARW"]
  case (a, b, c) of
    (CpSha s1 i1, CpSha s2 i2, CpSha s3 i3) -> do
      -- 三者内容相同
      (s1 == s2, s2 == s3) @?= (True, True)
      -- 同一对象的两个名字：身份相同 → 不算两份副本
      assertBool "同一对象的两个名字身份应相同" (i1 == i2)
      -- 独立文件：身份不同 → 算另一份副本
      assertBool "独立文件的身份应不同" (i1 /= i3)
    v -> assertFailure ("三者都应读到 sha 与身份，得到 " <> show v)
 where
  q p = [dq] <> p <> [dq]
  dq = toEnum 34

-- | 目标存在但被独占打开（Windows @ERROR_SHARING_VIOLATION@）必须是
-- 'CpUnreadable' 而不是 'CpMissing'——后者会让 verifySkips 判 VCopy，
-- 等于"目标不存在，照搬"，而真相是"无法确认"（codex 二十七轮 #2）。
caseProbeLocked :: IO ()
caseProbeLocked = withSystemTempDirectory "pm-lock" $ \tmp -> do
  let root = tmp </> "lib"
      rel = "Raw" </> "busy.ARW"
  createDirectoryIfMissing True (root </> "Raw")
  BS.writeFile (root </> rel) "busy"
  -- 占住它：GHC 的句柄锁不允许「已开写」的文件再被开读，抛的是
  -- ResourceBusy——一个**非** isDoesNotExistError 的 IOException，正好是这条
  -- 用例要的形态（openExclusiveBinary 是 CREATE_NEW 语义，对已存在的文件不
  -- 适用）。ReadWriteMode 不截断，文件内容不受影响。
  r <- try (openBinaryFile (root </> rel) ReadWriteMode) :: IO (Either SomeException Handle)
  case r of
    Left e -> assertFailure ("占用失败，用例前提不成立: " <> show e)
    Right h -> do
      p <- probeConfined root rel
      hClose h
      case p of
        CpUnreadable _ -> pure ()
        v -> assertFailure ("被占用的目标应为 CpUnreadable，得到 " <> show v)

-- | 捕获 stdout。用 base 的 hDuplicate/hDuplicateTo，不引新依赖。
-- | 子串判定。多条用例共用，不各写一份。
elemSub :: String -> String -> Bool
elemSub needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]

-- | 捕获 stdout。用 base 的 hDuplicate/hDuplicateTo，不引新依赖。
--
-- **两端都必须显式 UTF-8**：本机 locale 是 GBK，而 pm 的输出里有 U+26A0(⚠)
-- 与 U+2717(✗)，临时文件句柄按 locale 编码会直接抛 commitBuffer。而且 tasty
-- 缺省并行，重定向的是**进程级** stdout——并行跑的别的用例也写进这个句柄，
-- 它们的 ⚠ 同样得编得出来，否则**它们**会炸（实测三条用例一起红）。断言只
-- 匹配本用例独有的子串，别的用例的输出混进来不影响判定。
captureStdout :: IO a -> IO (String, a)
captureStdout act = withSystemTempDirectory "pm-cap" $ \dir -> do
  let fp = dir </> "out.txt"
  h <- openFile fp WriteMode
  hSetEncoding h utf8
  old <- hDuplicate stdout
  hDuplicateTo h stdout
  -- hDuplicate/hDuplicateTo 造出的句柄用的是 **locale** 编码，会把
  -- setupConsole 设好的 utf8 抹掉——替换后和还原后都要显式钉回去，
  -- 否则 pm 输出里的 ✗/⚠ 在这里、以及**后续用例**里都会炸。
  hSetEncoding stdout utf8
  a <- act `finally` (hFlush stdout >> hDuplicateTo old stdout >> hSetEncoding stdout utf8 >> hClose old)
  hClose h -- 必须先关：GHC 句柄锁不许「已开写」的文件同时被开读
  txt <- bracket (openFile fp ReadMode) hClose $ \rh -> do
    hSetEncoding rh utf8
    t <- hGetContents rh
    length t `seq` pure t
  pure (txt, a)

-- | 撞名 → 整批拒绝。此时被选中的**其余**照片、以及跟着它们的侧车同样一个
-- 都没搬走，却既不在 spCollide（只有撞名的那个 basename）也不在
-- spOrphanCars（侧车已被主文件认领，不算无主）——不逐条列出来，它们就是这条
-- 路径上的静默缺席（codex 二十七轮 #4）。
caseCollisionReportsAll :: IO ()
caseCollisionReportsAll = withSystemTempDirectory "pm-coll" $ \tmp -> do
  let src = tmp </> "card"
      root = tmp </> "lib"
  createDirectoryIfMissing True (src </> "A")
  createDirectoryIfMissing True (src </> "B")
  -- 两个同名主文件 → 撞名；A/x.xmp 是 A/x.ARW 的侧车，会被认领
  BS.writeFile (src </> "A" </> "x.ARW") (photoAt "2026:08:25 10:00:00")
  BS.writeFile (src </> "B" </> "x.ARW") (photoAt "2026:08:25 11:00:00")
  BS.writeFile (src </> "A" </> "x.xmp") "sidecar"
  createDirectoryIfMissing True root
  _ <- ensureTestRoot RoleMain root
  scanQuiet "test-root" root >>= saveCatalog root
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
  (out, rc) <-
    captureStdout
      (fst <$> runSortPlan (GoOpts False False) src (Left "Atlanta") (d 2026 8 25) (d 2026 8 26) cfg)
  rc @?= 2 -- 整批拒绝
  -- 撞名的两个主文件本来就会被打印
  elemSub "x.ARW" out @?= True
  -- **侧车也必须出现**：它同样没被搬走，而此前它一个字都不出现
  elemSub "x.xmp" out @?= True
  -- 并且说清楚一个都没进计划
  elemSub "没有任何文件" out @?= True
  doesDirectoryExist (plansDirOf root) >>= (@?= False)



-- | 反向：卡上一个**普通**的、名叫 @.pm@ 的用户目录必须被走进去。
--
-- 按名字判会把它整个跳过——里面的照片既不进计划，也不落进任何 Accounting
-- 格，正是本命令契约里最忌讳的那种静默缺席（codex 二十八轮 #3）。
caseUserDotPmIsWalked :: IO ()
caseUserDotPmIsWalked = withSystemTempDirectory "pm-src-udot" $ \tmp -> do
  let src = tmp </> "card"
  createDirectoryIfMissing True (src </> ".pm" </> "sub")
  BS.writeFile (src </> ".pm" </> "sub" </> "mine.ARW") (photoAt "2026:08:25 10:00:00")
  sf <- listSource src
  map takeFileName (sfPhotos sf) @?= ["mine.ARW"]
  any (elemSub "pm 状态目录" . snd) (sfErrors sf) @?= False

-- | TIFF 规定每个 IFD 以 4 字节 next-IFD offset 结尾（无后继时为 0）。
-- 少算那 4 字节等于接受一个结构不完整的 IFD：本机探针实证，一个 64 字节的
-- TIFF（子 IFD 条目数组正好在缓冲区末尾结束）此前返回
-- @Just 2026-08-25 13:45:07@（codex 二十八轮 #6）。
caseIfdNeedsNextOffset :: IO ()
caseIfdNeedsNextOffset = withSystemTempDirectory "pm-ifd" $ \tmp -> do
  let body = "2026:08:25 13:45:07\0"
      -- II*\0 | IFD0@8 | 1 条 | 0x8769 LONG 1 -> 50 | next=0 | 时间串@26 | pad
      -- | 子 IFD@50: 1 条 | 0x9003 ASCII 20 -> 26   ← 到 64 字节正好结束
      core =
        BS.concat
          [ BC.pack "II", le16 42, le32 8
          , le16 1, entryB 0x8769 4 1 50, le32 0
          , BC.pack body, BS.replicate 4 0
          , le16 1, entryB 0x9003 2 20 26
          ]
      truncated = tmp </> "truncated.tif"
      wellformed = tmp </> "wellformed.tif"
  BS.length core @?= 64
  BS.writeFile truncated core
  BS.writeFile wellformed (core <> le32 0)
  readCaptureTime truncated >>= (@?= Nothing)
  -- 补上那 4 字节即恢复可读——证明拒绝的原因**就是**它，不是别的
  readCaptureTime wellformed >>= (@?= Just (LocalTime (d 2026 8 25) (TimeOfDay 13 45 7)))
 where
  le16 :: Int -> BS.ByteString
  le16 n = BS.pack [fromIntegral (n `mod` 256), fromIntegral (n `div` 256 `mod` 256)]
  le32 :: Int -> BS.ByteString
  le32 n = le16 (n `mod` 65536) <> le16 (n `div` 65536)
  entryB t ty c v = BS.concat [le16 t, le16 ty, le32 c, le32 v]


-- | 第 27 轮把「源根是 junction」这类诊断从 sfErrors 里分出来，好让它不计入
-- "未入计划 N 个"——但**忘了接输出**，于是一条本来会打印的说明彻底消失了
-- （codex 二十八轮 #7）。分开的目的是不计数，不是不说。
caseNotesArePrinted :: IO ()
caseNotesArePrinted = withSystemTempDirectory "pm-notes" $ \tmp -> do
  let real = tmp </> "real"
      link = tmp </> "link"
      root = tmp </> "lib"
  createDirectoryIfMissing True (real </> "DCIM")
  BS.writeFile (real </> "DCIM" </> "a.ARW") (photoAt "2026:08:25 10:00:00")
  _ <- readCreateProcess (shell ("mklink /J " <> qq link <> " " <> qq real)) ""
  createDirectoryIfMissing True root
  _ <- ensureTestRoot RoleMain root
  scanQuiet "test-root" root >>= saveCatalog root
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
  (out, _) <- captureStdout (runSortSurvey link 72 cfg)
  elemSub "源根本身是 symlink/junction" out @?= True

-- | 计划前失败的第三条路径：暂存区与索引不一致。选中的文件一个都没搬走，
-- 必须与撞名/事件名非法一样逐条交代（codex 二十八轮 #4）。
caseFreshnessAbortReportsAll :: IO ()
caseFreshnessAbortReportsAll = withLib $ \src root cfg -> do
  -- 扫描之后往暂存区放一个文件：索引里没有它 → 新鲜度守卫拒绝
  createDirectoryIfMissing True (root </> "To-Be-Sync'd" </> "Raw" </> "26-01-X")
  BS.writeFile (root </> "To-Be-Sync'd" </> "Raw" </> "26-01-X" </> "stale.ARW") "drifted"
  (out, rc) <- captureStdout (sortPlan src cfg)
  rc @?= 2
  -- 断言只匹配**本用例独有**的路径：captureStdout 重定向的是进程级 stdout，
  -- tasty 并行跑的别的用例也写进这个句柄（见 captureStdout 的注释）。
  elemSub (src </> "DCIM" </> "a.ARW") out @?= True
  elemSub (src </> "DCIM" </> "a.xmp") out @?= True

-- | 第四条路径：源文件读取失败整批拒绝。此前只列失败的那个，读得出的那些
-- 一个字都不出现——等于让人以为其余的进了计划（与第 27 轮 #4 同一形状，
-- 那一轮只扫了一半）。
caseSnapshotAbortReportsAll :: IO ()
caseSnapshotAbortReportsAll = withLib $ \src root cfg -> do
  _ <- pure root
  -- 占住的必须是**侧车**：锁一个 .ARW 只会让 readCaptureTime 读不到时间，
  -- 它随即被判成"读不到拍摄时间"、压根不进 pick，打不中 snapshotSrc 那条
  -- 分支。侧车不过 EXIF 读取，由主文件认领后直接进 picked。
  -- GHC 句柄锁不许"已开写"的文件再被开读，抛 ResourceBusy。
  let car = src </> "DCIM" </> "a.xmp"
  r <- try (openBinaryFile car ReadWriteMode) :: IO (Either SomeException Handle)
  case r of
    Left e -> assertFailure ("占用失败，用例前提不成立: " <> show e)
    Right h -> do
      (out, rc) <- captureStdout (sortPlan src cfg)
      hClose h
      rc @?= 2
      elemSub car out @?= True -- 失败的那个
      -- 读得出、但同样没搬走的那些——此前一个字都不出现
      elemSub (src </> "DCIM" </> "a.ARW") out @?= True
      elemSub (src </> "DCIM" </> "b.ARW") out @?= True

-- | 中止路径的清单**不得截断**。此前在 40 项处截断并打一行"另有 N 个"——
-- 用户要据此判断卡上还剩什么，"另有 N 个"帮不上任何忙（codex 二十八轮 #4）。
caseChosenNotTruncated :: IO ()
caseChosenNotTruncated = withSystemTempDirectory "pm-trunc" $ \tmp -> do
  let src = tmp </> "card"
      root = tmp </> "lib"
      names = ["f" <> pad3 i <> ".ARW" | i <- [1 .. 45 :: Int]]
  createDirectoryIfMissing True (src </> "A")
  createDirectoryIfMissing True (src </> "B")
  mapM_ (\n -> BS.writeFile (src </> "A" </> n) (photoAt "2026:08:25 10:00:00")) names
  -- 一个撞名的主文件 → 整批拒绝，45 个全在"被选中但未归位"里
  BS.writeFile (src </> "B" </> "f001.ARW") (photoAt "2026:08:25 11:00:00")
  createDirectoryIfMissing True root
  _ <- ensureTestRoot RoleMain root
  scanQuiet "test-root" root >>= saveCatalog root
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
  (out, rc) <- captureStdout (sortPlan src cfg)
  rc @?= 2
  -- 第 45 个（远在 40 之后）必须出现。用带本次临时目录的完整路径，既独有、
  -- 又能证明它是被**逐条**列出来的而不是被折成一行摘要。
  -- 不用"某串不出现"这类否定断言：进程级 stdout 里混着别的并行用例的输出。
  elemSub (src </> "A" </> "f045.ARW") out @?= True
 where
  pad3 i = let t = show i in replicate (3 - length t) '0' <> t

qq :: FilePath -> String
qq p = [toEnum 34] <> p <> [toEnum 34]
