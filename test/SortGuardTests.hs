{-# LANGUAGE OverloadedStrings #-}

-- | P5-A/P5-B：`pm sort` 的遍历/限域/报告级守卫用例，另含三条 EXIF-IFD
-- 结构自洽用例。P7 自 "SortTests" 拆出（750 行预算），用例逐字搬移；
-- 合成夹具与 E2E 脚手架（photoAt/withLib/sortPlan 等）仍在 "SortTests"。
module SortGuardTests (sortGuardTests) where

import Control.Exception (SomeException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.List (sort)
import Data.Time (LocalTime (..), TimeOfDay (..))
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, getModificationTime, removeDirectoryRecursive, setModificationTime)
import System.FilePath (takeFileName, (</>))
import System.IO (Handle, IOMode (ReadWriteMode), hClose, openBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import Pm.Hash (ContentProbe (..), probeConfined)
import Pm.Scan (DotDirs (..), listTreeWith)
import Pm.Cli (GoOpts (..))
import Pm.Config (Config (..))
import Pm.Exif (parseCaptureTime, readCaptureTime)
import Pm.Op (Op (..))
import Pm.Plan (PlanItem (..))
import Pm.Sort (SourceFiles (..), listSource, runSortPlan, runSortSurvey)
import Pm.Types (RootRole (..))
import SortTests (ascii, bs, d, photoAt, plansDirOf, planItemsIn, sample, sortPlan, u16e, u32e, want, withLib)
import TestUtil (captureStdout, ensureTestRoot, scanQuiet)

sortGuardTests :: TestTree
sortGuardTests =
  testGroup
    "P5 sort 遍历/限域/报告守卫（P7 自 SortTests 拆出）"
    [ testCase "E2E：索引说「已在目标」但盘上内容不符 → 按实际内容重判，不静默跳过" caseSortE2EStaleSkip
    , testCase "E2E：源里的 junction 不跟随；认不出的扩展名单列不吞掉" caseSortE2ETraversal
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

-- | 子串判定。多条用例共用，不各写一份。
elemSub :: String -> String -> Bool
elemSub needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]

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
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
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
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
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
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
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

