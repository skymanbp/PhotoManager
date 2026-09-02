{-# LANGUAGE OverloadedStrings #-}

-- | P5-A：`pm sort` 与它依赖的 EXIF 读取。
--
-- EXIF 用例全部走**合成夹具**（在这里按字节拼出 TIFF/JPEG），不碰使用者的
-- 照片库——真实文件只能证明"能读"，证明不了越界、损坏、时间无效这些分支，
-- 而那些分支才是安全性所在。真实库的正确性另由主线手工比对（四张 ARW/JPG
-- 与 Windows 的「拍摄日期」逐条吻合，记在 REVIEW-LOG）。
-- photoAt 一并导出：ServeTests 的 sort 端点用例要造同样的 EXIF 样本，
-- 抄第二份就是第二套 fixture，迟早与被测的解析器分叉。
--
-- P7 拆分（750 行预算）：遍历/限域/报告级守卫用例在 "SortGuardTests"。
-- 合成夹具（字节级 TIFF/JPEG 构造器）与 E2E 脚手架从这里导出给它复用，
-- 理由同 photoAt——第二份夹具迟早与被测解析器分叉。
module SortTests
  ( sortTests
  , photoAt
  , ascii
  , bs
  , d
  , plansDirOf
  , planItemsIn
  , sample
  , sortPlan
  , u16e
  , u32e
  , want
  , withLib
  ) where

import Control.Monad (forM_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.ByteString as BS
import Data.List (sort)
import qualified Data.Text as T
import Data.Time (Day, LocalTime (..), TimeOfDay (..), fromGregorian)
import Data.Word (Word8)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory, removeFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (catalogPath, saveCatalog)
import Pm.Cli (GoOpts (..))
import Pm.Config (Config (..))
import Pm.Exif (parseCaptureTime, parseExifDateTime)
import Pm.Hash (StatSnap (..))
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan, planPath)
import Pm.Sort
  ( SortPick (..)
  , Verdict (..)
  , classifyDst
  , eventNameFor
  , holdKin
  , pickFiles
  , resolveEvent
  , runSortPlan
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
    , testCase "EXIF：IFD 偏移必须 ≥ 8；声明「没有 IFD」的文件不得返回时间" caseExifIfdOffset
    , testCase "classifyExt：相机原生 raw 与 classifyExt 必须同一份清单" caseRawExts
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
  -- 第一方自审 R3（Op.winNameOk）：尾随点/空格 Win32 创建目录时会剥掉——
  -- 落位名≠计划名，执行期句柄后验必败；控制符同拒。都在计划前拒。
  eventNameFor (d 2026 8 25) "Boston." @?= Nothing
  eventNameFor (d 2026 8 25) "Boston " @?= Nothing
  eventNameFor (d 2026 8 25) "a\tb" @?= Nothing

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
  -- 尾随点/空格与控制符（第一方自审 R3，winNameOk）与保留字符同拒。
  forM_ ["26-04-a/b", "26-04-a\\b", "26-04-a:b", "26-04-a*b", "26-04-a|b", "26-04-X.", "26-04-X ", "26-04-a\tb"] $ \ev ->
    case resolveEvent (d 2026 8 25) (Right ev) of
      Left _ -> pure ()
      Right e -> assertFailure ("含非法字符/尾随点空格的 --event 应被拒: " <> e)

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
  k src root (Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing)

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
-- sort 复用同一份定义（'freshStagingCatalog'），于是在这里一并补上。
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

