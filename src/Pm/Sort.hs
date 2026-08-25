{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @pm sort@（DESIGN §7）：把一堆**散落的新照片**（相机卡、下载目录……）
-- 按拍摄时间分段，归位到暂存区的事件夹 @To-Be-Sync'd\\Raw\\\<事件\>@，
-- 之后照常走 @pm import@ 进归档层。
--
-- 它补的是 @pm import@ 明确不做的那一段：import 要求事件夹**已经存在且名字正确**
-- （它「不猜」，I1），而"这批照片属于哪个事件"此前只能靠人在资源管理器里分。
--
-- **两种形态，这是本命令的全部设计**：
--
--  1. @pm sort \<源\>@ —— **只读**。读 EXIF 拍摄时间，按间隔给出候选分段，
--     并把每段该敲的下一条命令**原样打印出来**。不写任何文件。
--  2. @pm sort \<源\> --place \<地点\> --from \<日\> --to \<日\>@ —— 生成计划。
--
-- 为什么不做成"交互式逐段问"或"生成一份待填清单文件"：地点是**计划形成之前**
-- 就必须有的输入（目标路径里就含它），而 pm 已有的 'StNeedsDecision' \/
-- @pm resolve@ 是计划形成**之后**的冲突裁决，承载不了它。与其为此发明一套新的
-- 清单文件格式，不如让 pm 只做它能做的（分段、算日期、查重名、查已归档），
-- 把它做不到的那一格（地点）留成一个命令行参数——可重跑、可回看、不怕中断，
-- 而 GUI 与将来的 AI 识别都只是**替用户填这一格**，走同一条计划路径。
--
-- 分段只是**提议**：真实库已经证明时间切不开事件（纽约 2024-12-25→2025-01-02
-- 与亚特兰大 2025-01-02→01-05 首尾相接，那 7 张连号 ARW 因此同时落进两个
-- 事件夹）。所以边界一律由用户在 @--from\/--to@ 里确认。
--
-- **本模块不自立纪律**：可信索引这道闸走 'withFreshStagingCatalog'、目标唯一性
-- 走 'Pm.Import.foldPath'、事件名走 'Pm.Names' 的两个 canon、目标已存在的裁决
-- 走 'StNeedsDecision'、源一致性走 'Pm.Hash.statSnap' 的前后双 stat。sort 只是
-- 把文件**送进** import 的入口，它对同一件事的口径必须与 import 逐字一致，
-- 否则两条路会对同一批文件给出不同判断。
module Pm.Sort
  ( -- * 纯核心
    segmentBy
  , eventNameFor
  , SortPick (..)
  , pickFiles
  , resolveEvent
  , Verdict (..)
  , classifyDst
  , holdKin
  , snapshotWith
  , SourceFiles (..)
  , listSource

    -- * 命令入口
  , runSortSurvey
  , runSortPlan
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, unless)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time
  ( Day
  , LocalTime (..)
  , NominalDiffTime
  , diffLocalTime
  , getCurrentTime
  , toGregorian
  )
import System.Directory
  ( canonicalizePath
  , doesDirectoryExist
  , listDirectory
  , makeAbsolute
  , pathIsSymbolicLink
  )
import System.FilePath (takeBaseName, takeDirectory, takeExtension, takeFileName, (</>))
import Text.Printf (printf)

import Pm.Cli (GoOpts (..), savePlanAndMaybeRun, withFreshStagingCatalog)
import Pm.Config (Config (..), requireRole)
import Pm.Exif (readCaptureTime)
import Pm.Hash (ContentProbe (..), StatSnap (..), probeConfined, sha256File, statSnap)
import Pm.Import (foldPath, stagingTop)
import Pm.Names (canonProcessedEvent, canonRawEvent)
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), newPlanId)
import Pm.Scan (DotDirs (..), listTreeWith)
import Pm.Types

-- ─── 纯核心 ─────────────────────────────────────────────────────────────────

-- | 按相邻拍摄时间的间隔切段。输入不必有序（这里自己排）。
--
-- 阈值是**提议用**的，不是判定：给大了会把两趟旅程并成一段，给小了会把一趟
-- 拆碎——两种错都由用户在 @--from\/--to@ 里纠正，所以这里不追求"聪明"。
segmentBy :: NominalDiffTime -> [(a, LocalTime)] -> [[(a, LocalTime)]]
segmentBy gap xs = go (sortOn snd xs)
 where
  go [] = []
  go (y : ys) = let (seg, rest) = grow [y] ys in reverse seg : go rest
  grow acc@((_, prev) : _) (z@(_, t) : zs)
    | diffLocalTime t prev <= gap = grow (z : acc) zs
  grow acc rest = (acc, rest)

-- | 会让目标路径逃出事件夹的字符。@--place@ 与 @--event@ **两条路都要过**：
-- 'canonRawEvent' 只约束前 6 个字符（@dd-dd-@）并要求其后非空，地点部分它
-- 不设字符限制，所以只在 @--place@ 上设闸等于给 @--event@ 留了一个绕行口。
badChar :: Char -> Bool
badChar c = c `elem` ("\\/:*?\"<>|" :: String)

-- | 事件夹名 @YY-MM-地点@。年月取自该段**起始日**；地点只能由用户给
-- （实测相机档零 GPS，本库 94 张相册抽测 0 张有 GPS）。
--
-- 地点做最小合法性约束：非空、不含路径分隔符与 Windows 保留字符。真正的
-- 权威校验是 'canonRawEvent'——调用方拿到名字后必须再过它一次。
eventNameFor :: Day -> String -> Maybe String
eventNameFor d place
  | null place = Nothing
  | any badChar place = Nothing
  -- Scheme A 的年份只有两位，而 'Pm.Names.yearFolder' 无条件补 "20"——
  -- 2000-2099 之外的拍摄年份会被**静默**折到错误世纪（1999 → 2099，
  -- 2101 → 2001）。这里拒了它，让用户用 --event 显式指定，而不是默默归错年。
  | y < 2000 || y > 2099 = Nothing
  | otherwise = Just (pad2 (fromIntegral (y `mod` 100)) <> "-" <> pad2 m <> "-" <> place)
 where
  (y, m, _) = toGregorian d
  pad2 n = let s = show (n :: Int) in if length s < 2 then '0' : s else s

-- | 一次归位挑选的结果（纯）。
data SortPick = SortPick
  { spTake :: [(FilePath, LocalTime)]
    -- ^ 落在 [from, to] 里、且拍摄时间可定的照片
  , spSidecars :: [FilePath]
    -- ^ 跟随上述照片的侧车（.xmp\/.acr）。它们没有独立拍摄时间，只能跟着
    -- 主文件走；**必须与主文件同一个计划**，否则照片进了暂存区而调色参数
    -- 留在卡上，用户清卡后就永久丢失了。
  , spOutOfRange :: [(FilePath, LocalTime)]
    -- ^ 拍摄时间读得出、但落在 @[from, to]@ 之外。**必须报告**：用户给的
    -- 区间可能就是漏了，而他看到的计划不会提这些文件一个字，清卡之后才发现
    -- 少了（codex 二十五轮 #4）。
  , spOrphanCars :: [FilePath]
    -- ^ 侧车，但同目录同 stem 没有**区间内**的主文件。同样必须报告：它同样
    -- 不会被搬走，而它承载的是调色参数（#5）。
  , spCollide :: [(FilePath, [FilePath])]
    -- ^ 同一个 basename 来自多个源路径——**整批拒绝**，不替用户挑
  }
  deriving (Show, Eq)

-- | 按日期区间挑文件，并查同名冲突。区间**含首含尾**（按日历日比较，
-- 与用户在提议里看到的日期一致；不引入时刻，免得"到 08-03"要不要含当天晚上
-- 这种歧义）。
--
-- @allCars@ 是源里**全部**侧车。传全量而不是一个查询回调，是为了能算出
-- 「没有区间内主文件的侧车」——回调形式只能回答"这张照片有哪些侧车"，答不了
-- "哪些侧车没人认领"，而后者正是会被静默丢掉的那一类。
pickFiles :: [FilePath] -> Day -> Day -> [(FilePath, LocalTime)] -> SortPick
pickFiles allCars from to dated =
  SortPick
    { spTake = inRange
    , spSidecars = cars
    , spOutOfRange = outOfRange
    , spOrphanCars = orphans
    , spCollide = collides
    }
 where
  inRange = sortOn snd [x | x@(_, t) <- dated, let d = localDay t, d >= from, d <= to]
  outOfRange = sortOn snd [x | x@(_, t) <- dated, let d = localDay t, d < from || d > to]
  ix = sidecarIndex allCars
  -- 同目录同 stem 的 RAW+JPEG 双拍会各自认领同一个 .xmp——去重，否则同一个
  -- 侧车会生成两条写向同一目标的计划项。
  cars = dedupe (concatMap (lookupSidecars ix . fst) inRange)
  claimed = Set.fromList (map foldPath cars)
  orphans = [c | c <- allCars, not (Set.member (foldPath c) claimed)]
  -- 键走 'Pm.Import.foldPath'（normalise + case-fold）：NTFS 大小写不敏感，
  -- 只差大小写的两个源文件落位后是**同一个目标**。import 在评审 mj-2 就按
  -- 这个口径统一过目标唯一性，sort 不能另立一套。冲突要连侧车一起查——
  -- 照片撞名时它们的侧车必然也撞名，漏查就会让"整组拒绝"漏掉一半。
  byName = Map.fromListWith (<>) [(foldPath (takeFileName p), [p]) | p <- map fst inRange <> cars]
  collides = [(n, sort ps) | (n, ps) <- Map.toList byName, length ps > 1]

dedupe :: [FilePath] -> [FilePath]
dedupe = go Set.empty
 where
  go _ [] = []
  go seen (p : ps)
    | Set.member (foldPath p) seen = go seen ps
    | otherwise = p : go (Set.insert (foldPath p) seen) ps

-- | 一个源文件相对**目标位置**的判定。
--
-- 此前这里是「sha 在库里任何地方出现过就算已归档、直接丢掉」——那是错的：
-- 同一张照片合法地属于第二个事件时会被**静默丢弃**，而用户以为归位了。判定
-- 必须按目标位置做，与 'Pm.Import.planImport' 同一口径。
data Verdict
  = -- | 目标不存在 → 正常拷贝
    VCopy
  | -- | 暂存目标已有同 sha → 本就归位过，跳过（重跑幂等）
    VAtDest
  | -- | 归档层的最终目标已有同 sha → import 迟早判它冗余，不必再搬一遍
    VArchived
  | -- | 目标存在且内容不同 → 交人裁决，绝不静默覆盖（I5）
    VConflict Text
  deriving (Show, Eq)

-- | @classifyDst atStaging atArchive sha@：前两个参数是两处目标位置在索引里的
-- sha（'Nothing' = 该位置无文件）。
--
-- 归档目标同名不同容时**不**在这里拦：那正是 @pm import@ 的返修裁决所管的事
-- （'Pm.Import.ImportReport' 的 @irRework@），sort 把文件送到暂存区即可。抢在
-- import 前面裁决只会让同一件事有两套判据。
classifyDst :: Maybe Text -> Maybe Text -> Text -> Verdict
classifyDst atStaging atArchive sha = case atStaging of
  Just s
    | s == sha -> VAtDest
    | otherwise -> VConflict "暂存目标已存在且内容不同"
  Nothing -> case atArchive of
    Just a | a == sha -> VArchived
    _ -> VCopy

-- | 同目录同 stem 的组内一荣俱荣：组里只要有一个成员待裁决，其余待拷成员一并
-- 悬置。这是 import 复审 mj-3 的同一条纪律——先把侧车拷过去会产生孤立侧车，
-- 裁决 @--keep both@ 改名时更会指错主文件。键是**目标**路径，不是源路径。
holdKin :: [(FilePath, Verdict)] -> [(FilePath, Verdict)]
holdKin xs = [(dst, bump dst v) | (dst, v) <- xs]
 where
  stemKey dst = (foldPath (takeDirectory dst), foldPath (takeBaseName dst))
  held = Set.fromList [stemKey dst | (dst, VConflict _) <- xs]
  bump dst VCopy
    | Set.member (stemKey dst) held = VConflict "同 stem 主文件待裁决，本组悬置"
  bump _ v = v

-- ─── 扫描（IO） ─────────────────────────────────────────────────────────────

-- | 源目录里的东西，按 'classifyExt' 分成三摞，外加遍历本身的错误。
--
-- 「认不出」不是一个可以扔掉的类：它必须被**报告**（见 'Accounting'）。
data SourceFiles = SourceFiles
  { sfPhotos :: [FilePath]
  , sfSidecars :: [FilePath]
  , sfUnknown :: [FilePath]
    -- ^ 扩展名不认识。不归位，但一定列出来——用户得知道卡上还剩什么。
  , sfErrors :: [(FilePath, String)]
    -- ^ 遍历时就出问题的（reparse point、路径过长、读不到）。
  , sfNotes :: [String]
    -- ^ **诊断**，不是"没归位的文件"。混进 'sfErrors' 会让"未入计划 N 个"
    -- 多算（codex 二十七轮 #5：源根是 junction 时 left 多算 1）。
  }

-- | 列出源目录下的全部文件（绝对路径）。
--
-- 遍历**复用 'Pm.Scan.listTree'**，不再自己写递归。自写的那版直接对任何目录
-- 递归下降，三件本项目早已认定必须做的事一件都没做：**跳过 symlink\/reparse
-- point**（源里一个指回自身的 junction 会让递归无限下降；指向外部的 junction
-- 更会把源范围之外的照片纳入计划）、**过长路径报错而不是静默丢弃**、点开头的
-- 目录跳过。这些纪律在 'listTree' 里已经有一份正确实现，再写第二份就是第二套
-- 纪律，迟早分叉——正如 'classifyExt' 与 rawExts 分叉过一次那样。
-- （codex 二十五轮 #6）
listSource :: FilePath -> IO SourceFiles
listSource dir = do
  isDir <- doesDirectoryExist dir
  if not isDir
    then pure (SourceFiles [] [] [] [] [])
    else do
      -- 'WalkDotDirs'：源是**用户随手指的一个目录**，里面点开头的目录只是普通
      -- 文件夹。'listTree' 的默认策略是给**库根**写的（@.pm@/@.git@ 是元数据，
      -- 跳过且不报告），原样搬过来会让 @card\\.hidden\\a.ARW@ 连一条记录都不留
      -- 地消失（codex 二十六轮 #3）。
      (rels, errs) <- listTreeWith WalkDotDirs dir
      -- 源根自身是不是 reparse point：'listTree' 只探子项，不探根。根由用户
      -- 显式指定（与 root 放在 junction 上一样是合法用法，见 'resolveUnder'
      -- 的说明），所以**不拒绝**，但必须告诉用户他实际在整理哪个目录
      -- （codex 二十六轮 #5）。
      rootLink <- either (const False) id <$> tryIO (pathIsSymbolicLink dir)
      real <-
        if rootLink
          then either (const Nothing) Just <$> tryIO (canonicalizePath dir)
          else pure Nothing
      let abs' = map (dir </>) (sort rels)
          pick k = [p | p <- abs', classifyExt (takeExtension p) == k]
      pure
        SourceFiles
          { sfPhotos = pick KindPhoto
          , sfSidecars = pick KindSidecar
          , sfUnknown = pick KindMeta
          , sfErrors = [(dir </> r, e) | (r, e) <- errs]
          , sfNotes =
              [ "源根本身是 symlink/junction，实际整理的是 " <> fromMaybe "（解析失败）" real
              | rootLink
              ]
          }
 where
  tryIO :: IO a -> IO (Either SomeException a)
  tryIO = try

-- | (源目录, 折叠后的 stem) → 该 stem 的侧车。按目录分键：不同目录下同名的
-- 两组照片各有各的侧车，全局按 stem 索引会把它们串在一起。
-- | 侧车与主文件的配对键：(所在目录, 折叠后的 stem)。'sidecarIndex' 与
-- 「无主侧车」两处共用，免得配对口径分成两份。
stemOf :: FilePath -> (FilePath, FilePath)
stemOf p = (foldPath (takeDirectory p), foldPath (takeBaseName p))

sidecarIndex :: [FilePath] -> Map.Map (FilePath, FilePath) [FilePath]
sidecarIndex ps =
  Map.fromListWith
    (<>)
    [(stemOf p, [p]) | p <- ps]

lookupSidecars :: Map.Map (FilePath, FilePath) [FilePath] -> FilePath -> [FilePath]
lookupSidecars ix p = Map.findWithDefault [] (stemOf p) ix

-- | 读一批文件的拍摄时间，分成「可定时」与「读不到」。'readCaptureTime' 自身
-- 已 fail-closed（读不到即 'Nothing'，不猜、不回退到文件修改时间）。
readTimes :: [FilePath] -> IO ([(FilePath, LocalTime)], [FilePath])
readTimes ps = do
  rs <- forM ps $ \p -> (,) p <$> readCaptureTime p
  pure ([(p, t) | (p, Just t) <- rs], [p | (p, Nothing) <- rs])

-- | 源文件的 sha + stat 快照。**hash 前后各 stat 一次**：源常常是相机卡或一个
-- 还在被写入的下载目录，写入过程中算出的 sha 是撕裂的，拿它进计划会让执行期
-- 的前置条件核对通过、内容却是错的（'Pm.Scan' 对库内文件用的是同一条纪律，
-- DESIGN §6.7）。
--
-- 逐文件 'try'：一个读不了的文件（卡被拔、权限不足）不该让整条命令抛异常，
-- 那样连"是哪个文件出的问题"都报不出来。
snapshotSrc :: FilePath -> IO (Either String (Text, StatSnap))
snapshotSrc = snapshotWith statSnap sha256File

-- | 上面那道守卫的**内容是次序**（stat → hash → stat），而次序用真实文件测
-- 只能靠制造竞态，必然是片状用例——'Pm.Scan' 的同一道守卫至今没有用例，正是
-- 卡在这里。把 stat 与 hash 注入进来，"hash 期间被改动"就成了确定性事件，
-- 次序本身也能被断言（见 SortTests 的 caseVolatileGuard）。
snapshotWith
  :: (FilePath -> IO StatSnap)
  -> (FilePath -> IO Text)
  -> FilePath
  -> IO (Either String (Text, StatSnap))
snapshotWith stat hash p = do
  r <- try $ do
    pre <- stat p
    sha <- hash p
    post <- stat p
    pure $
      if pre == post
        then Right (sha, post)
        else Left "hash 期间被修改（源仍在写入）"
  pure (either (\(e :: SomeException) -> Left (show e)) id r)

-- | 两种形态共用的源目录入口：解析成绝对路径、确认存在、分三摞列出。
withSource :: FilePath -> (FilePath -> SourceFiles -> IO Int) -> IO Int
withSource src k = do
  absSrc <- makeAbsolute src
  ok <- doesDirectoryExist absSrc
  if not ok
    then putStrLn ("源目录不存在: " <> absSrc) >> pure 2
    else listSource absSrc >>= k absSrc

-- | @pm sort@ **不进计划**的每一类，逐类留底。
--
-- 这不是"顺手多打几行"：静默缺席与静默覆盖同罪。用户按一份看上去正常的计划
-- 清了卡，少掉的那些再也追不回来——所以命令对它**看到的每一个文件**都要有
-- 交代，两种形态都要（只在提议里列、生成计划时不列，等于让用户以为整个源都
-- 归位了）。codex 二十五轮 #4\/#5 各是这条纪律漏掉的一格。
data Accounting = Accounting
  { acUndated :: [FilePath]
  , acOutOfRange :: [(FilePath, LocalTime)]
  , acOrphanCars :: [FilePath]
  , acUnknown :: [FilePath]
  , acErrors :: [(FilePath, String)]
  }

-- | **计划前失败**时（撞名整批拒绝、事件名不合法）把本次选中的全部文件列出来。
--
-- 这些文件一个都没搬走，却不属于 'Accounting' 的任何一格：照片在 'spTake' 里
-- （本该进计划），侧车已被主文件认领（所以不算 'spOrphanCars'）。不列出来，
-- 它们就是这条路径上的静默缺席（codex 二十七轮 #4）。
reportChosen :: SortPick -> IO ()
reportChosen pick = do
  let chosen = map fst (spTake pick) <> spSidecars pick
  printf
    "\n本次**没有任何文件**进入计划。被选中但未归位的 %d 个（含侧车）：\n"
    (length chosen)
  forM_ (take 40 chosen) $ \c -> putStrLn ("    " <> c)
  unless (length chosen <= 40) $
    printf "    …另有 %d 个\n" (length chosen - 40)

-- | 逐类打印，返回被留下的文件总数（0 = 源里每个文件都进了计划）。
reportAccounting :: Accounting -> IO Int
reportAccounting ac = do
  bucket
    "读不到拍摄时间"
    "不猜——请自行放置或先补 EXIF"
    (acUndated ac)
  bucket
    "可定时但在 --from/--to 之外"
    "本次不归位；要一起搬就放宽区间"
    [p <> "  (" <> show t <> ")" | (p, t) <- acOutOfRange ac]
  bucket
    "侧车但无区间内主文件"
    "调色参数在这里面，主文件没进本批它就跟不过去"
    (acOrphanCars ac)
  bucket
    "扩展名不认识"
    "pm 不搬它不认识的东西；需要就先补进 classifyExt"
    (acUnknown ac)
  bucket
    "遍历时出错"
    "reparse point / 路径过长 / 读不到"
    [p <> "  — " <> e | (p, e) <- acErrors ac]
  pure total
 where
  total =
    length (acUndated ac)
      + length (acOutOfRange ac)
      + length (acOrphanCars ac)
      + length (acUnknown ac)
      + length (acErrors ac)
  -- 显式签名：OverloadedStrings 下这三个字面量的类型无从推断（printf 的
  -- 可变参数不约束它们）。
  bucket :: String -> String -> [String] -> IO ()
  bucket title why xs = unless (null xs) $ do
    printf "\n%s %d 个（%s）：\n" title (length xs) why
    forM_ (take 20 xs) $ \p -> putStrLn ("      " <> p)
    unless (length xs <= 20) $
      printf "      …另有 %d 个\n" (length xs - 20)

-- ─── 形态一：只读提议 ───────────────────────────────────────────────────────

-- | @pm sort \<源\>@：扫描 + 分段 + 打印每段该敲的命令。**不写任何文件。**
runSortSurvey :: FilePath -> Double -> Config -> IO Int
runSortSurvey src gapHours cfg = do
  let root = cfgMainPath cfg
  er <- requireRole RoleMain root
  case er of
    Left msg -> putStrLn msg >> pure 2
    Right _ -> withSource src $ \absSrc sf -> do
      (dated, undated) <- readTimes (sfPhotos sf)
      existing <- existingEvents root
      let segs = segmentBy (realToFrac (gapHours * 3600)) dated
      printf
        "pm sort · 源 %s → 暂存区 %s\\Raw\\\n  照片 %d 个：可定时 %d · 读不到拍摄时间 %d · 候选分段 %d（间隔 > %.0f 小时切一刀）\n  侧车 %d 个（跟随各自主文件，不单独分段）· 不认识的 %d 个 · 遍历错误 %d 个\n"
        absSrc
        stagingTop
        (length (sfPhotos sf))
        (length dated)
        (length undated)
        (length segs)
        gapHours
        (length (sfSidecars sf))
        (length (sfUnknown sf))
        (length (sfErrors sf))
      forM_ (zip [1 :: Int ..] segs) (printSegment absSrc existing)
      -- 提议阶段没有区间，所以「区间外」这一格此刻不适用（由形态二在拿到
      -- --from/--to 之后才算得出来）。但「无主侧车」有一半是**与区间无关**的：
      -- 同目录同 stem 在整个源里都没有主文件的侧车，此刻就能判定，也就此刻
      -- 该报——否则用户要等到生成计划时才第一次看到它（codex 二十六轮 #7）。
      let stems = Set.fromList [stemOf p | p <- sfPhotos sf]
          homeless = [c | c <- sfSidecars sf, not (Set.member (stemOf c) stems)]
      _ <-
        reportAccounting
          Accounting
            { acUndated = undated
            , acOutOfRange = []
            , acOrphanCars = homeless
            , acUnknown = sfUnknown sf
            , acErrors = sfErrors sf
            }
      putStrLn "\n（分段只是提议：时间切不开首尾相接的两趟旅程，边界以你给的 --from/--to 为准）"
      pure 0

printSegment :: FilePath -> [String] -> (Int, [(FilePath, LocalTime)]) -> IO ()
printSegment _ _ (_, []) = pure ()
printSegment absSrc existing (i, seg@((p0, t0) : _)) = do
  -- 段尾用 reverse 后模式匹配取，不用部分函数 last/head：段虽已知非空，但那是
  -- 人看出来的，编译器看不出来——留 head 就是留一个将来重构时会炸的口子。
  let (pN, tN) = case reverse seg of ((a, b) : _) -> (a, b); [] -> (p0, t0)
      d0 = localDay t0
  printf "\n段 %d  %s → %s · %d 张\n" i (show t0) (show tN) (length seg)
  printf "      首 %s   尾 %s\n" (takeFileName p0) (takeFileName pN)
  forM_ (sameMonth existing d0) $ \ev ->
    putStrLn ("      ↺ 已有同年月事件 " <> ev <> " —— 要并入就把下面的 --place 换成 --event " <> ev)
  printf
    "      → pm sort \"%s\" --place <地点> --from %s --to %s\n"
    absSrc
    (show d0)
    (show (localDay tN))

-- | 暂存区与归档层里已有的事件夹名（用来提议复用，避免又造出跨夹重复）。
existingEvents :: FilePath -> IO [String]
existingEvents root = do
  a <- lsDir (root </> stagingTop </> "Raw")
  b <- concat <$> (mapM (lsDir . ((root </> "Raw") </>)) =<< lsDir (root </> "Raw"))
  pure (sort (Set.toList (Set.fromList (a <> map stripRawSuffix b))))
 where
  lsDir d = do
    ok <- doesDirectoryExist d
    if ok then sort <$> listDirectory d else pure []
  -- 反向映射复用 'Pm.Names.canonProcessedEvent'（它就是"剥掉 -Raw 后缀，返回
  -- YY-MM-地点"），而不是本地再写一个大小写敏感的 strip——两个方向用同一份
  -- 定义，归档层的 @26-04-X-raw@ 才折得到暂存区的 @26-04-X@ 上。
  stripRawSuffix n = fromMaybe n (canonProcessedEvent n)

-- | 同年月（@YY-MM-@ 前缀相同）的已有事件。
sameMonth :: [String] -> Day -> [String]
sameMonth evs d =
  let (y, m, _) = toGregorian d
      pfx = pad2 (fromIntegral y `mod` 100) <> "-" <> pad2 m <> "-"
   in [e | e <- evs, take (length pfx) e == pfx]
 where
  pad2 n = let s = show (n :: Int) in if length s < 2 then '0' : s else s

-- ─── 形态二：生成计划 ───────────────────────────────────────────────────────

-- | @pm sort \<源\> --place\/--event --from --to@：把选中的文件**拷贝**到
-- @To-Be-Sync'd\\Raw\\\<事件\>@。
--
-- 是拷贝不是移动：源可能是相机卡，pm 不删任何东西（I2）。清卡由用户自己做。
runSortPlan :: GoOpts -> FilePath -> Either String String -> Day -> Day -> Config -> IO Int
runSortPlan go src placeOrEvent from to cfg = do
  let root = cfgMainPath cfg
  -- 与 runImport 同一次序：身份校验先于任何读取与判定。
  er <- requireRole RoleMain root
  case er of
    Left msg -> putStrLn msg >> pure 2
    Right info -> withSource src $ \_ sf -> do
      (dated, undated) <- readTimes (sfPhotos sf)
      let pick = pickFiles (sfSidecars sf) from to dated
      -- 交代先于计划：留下的每一类都在用户看到"待拷 N 张"之前就列出来。
      left <-
        reportAccounting
          Accounting
            { acUndated = undated
            , acOutOfRange = spOutOfRange pick
            , acOrphanCars = spOrphanCars pick
            , acUnknown = sfUnknown sf
            , acErrors = sfErrors sf
            }
      case (spCollide pick, spTake pick) of
        (cs@(_ : _), _) -> do
          -- 撞名是**整批拒绝**：这一趟没有任何文件进入计划。所以这里不能沿用
          -- 上面那句「以上 N 个不在本次计划里」——那会让人以为其余的进了。
          -- 说清楚"一个都没进"，才是对这一格的如实交代（codex 二十六轮 #7）。
          putStrLn "✗ 同名文件来自多个源路径，整批拒绝（不替你挑哪一个）："
          forM_ cs $ \(n, srcs) -> do
            putStrLn ("    " <> n <> ":")
            forM_ srcs $ \s -> putStrLn ("        " <> s)
          -- 光打印撞名的那几个名字不够：被选中的**其余**照片、以及跟着它们的
          -- 侧车同样不会被搬走，而它们既不在 'spCollide' 里，也不在
          -- 'spOrphanCars'（侧车已被认领，所以不算无主）——于是一个都不出现在
          -- 输出里（codex 二十七轮 #4）。把本次选中的全部文件逐条列出来。
          reportChosen pick
          unless (left == 0) $
            printf "另有 %d 个文件因上列其他原因被留下。\n" left
          pure 2
        (_, []) -> do
          putStrLn "该区间内没有可定时的照片"
          unless (left == 0) $
            printf "（源里另有 %d 个文件因上列原因未被归位）\n" left
          pure 1
        (_, taken@((_, t1) : _)) -> do
          unless (left == 0) $
            printf "\n（以上 %d 个文件**不在**本次计划里；清卡前请自行确认）\n" left
          case resolveEvent (localDay t1) placeOrEvent of
            -- 与撞名同类：计划前失败，被选中的文件一个都没搬走，同样要交代。
            Left why -> putStrLn ("✗ " <> why) >> reportChosen pick >> pure 2
            Right ev ->
              withFreshStagingCatalog root $
                buildPlan cfg go info ev (map fst taken <> spSidecars pick)

-- | 决定事件夹名：@--place@ 自动补 @YY-MM@（取该段起始日），@--event@ 直接用。
-- 两条最后都要过 'canonRawEvent'——那是 import 认这个目录的同一把尺子，
-- 现在过不了的名字，等到 import 时才报就晚了。
resolveEvent :: Day -> Either String String -> Either String String
resolveEvent d poe = do
  name <- case poe of
    Right ev
      | any badChar ev -> Left ("事件名含非法字符（\\/:*?\"<>|）: " <> ev)
      | otherwise -> Right ev
    Left place ->
      maybe
        (Left ("地点不合法（空、含 \\/:*?\"<>| 、或拍摄年份不在 2000-2099）: " <> place))
        Right
        (eventNameFor d place)
  case canonRawEvent name of
    Nothing -> Left ("事件夹名不符合 Scheme A（YY-MM-地点）: " <> name)
    Just _ -> Right name

-- root 不再单独传：它恒等于 @cfgMainPath cfg@，两个参数表达同一件事时，
-- 迟早会有一处传错。计划的执行期复验钩子也要 Config（'Pm.Cli.preExecFor'）。
buildPlan :: Config -> GoOpts -> RootInfo -> String -> [FilePath] -> Catalog -> IO Int
buildPlan cfg go info ev picked cat = do
  let root = cfgMainPath cfg
  snaps <- forM picked $ \p -> (,) p <$> snapshotSrc p
  case [(p, why) | (p, Left why) <- snaps] of
    -- 少搬一个文件比搬错更难发现：能读的那些照样出计划，等于把"这批没全到"
    -- 藏进一份看上去正常的计划里。整批拒绝，把问题留在用户眼前。
    failed@(_ : _) -> do
      putStrLn "✗ 源文件读取失败，整批不出计划："
      forM_ failed $ \(p, why) -> putStrLn ("    " <> p <> " — " <> why)
      pure 2
    [] -> do
      let judged0 = judge cat ev [(p, sha, st) | (p, Right (sha, st)) <- snaps]
      judged <- verifySkips root judged0
      let changed = length [() | (a, b) <- zip judged0 judged, jVerdict a /= jVerdict b]
      unless (changed == 0) $
        printf "⚠ 索引已过期：%d 项按目标位置的**实际内容**重新判定\n" changed
      emit cfg go info judged

-- | 一个源文件的完整判定行。
data Judged = Judged
  { jSrc :: FilePath
  , jDst :: FilePath
    -- ^ 暂存目标，相对 root
  , jArch :: FilePath
    -- ^ @pm import@ 之后它的归档目标，相对 root
  , jSha :: Text
  , jStat :: StatSnap
  , jVerdict :: Verdict
  }

-- | 纯判定：按**目标位置**给每个文件定性，再做 stem 组悬置。
judge :: Catalog -> String -> [(FilePath, Text, StatSnap)] -> [Judged]
judge cat ev rows =
  zipWith
    ( \(p, sha, st) (_, v) ->
        Judged {jSrc = p, jDst = dstOf p, jArch = archiveOf p, jSha = sha, jStat = st, jVerdict = v}
    )
    rows
    (holdKin [(dstOf p, classifyDst (shaAt (dstOf p)) (shaAt (archiveOf p)) sha) | (p, sha, _) <- rows])
 where
  byFold = Map.fromList [(foldPath (enPath e), enSha e) | e <- Map.elems (catEntries cat)]
  shaAt dst = Map.lookup (foldPath dst) byFold
  dstOf p = stagingTop </> "Raw" </> ev </> takeFileName p
  -- import 会把 @To-Be-Sync'd\\Raw\\<ev>@ 里的文件路由到 @Raw\\20YY\\<ev>-Raw@。
  -- 事件名此刻已过 'canonRawEvent'（'resolveEvent' 保证），所以 Nothing 分支
  -- 取不到；保留它只是为了不在这里引入部分函数。
  archiveOf p = case canonRawEvent ev of
    Just (yr, canon) -> "Raw" </> yr </> canon </> takeFileName p
    Nothing -> dstOf p

-- | 判定说「跳过」之前，**真的去看一眼那个目标文件**。
--
-- catalog 里的 sha 是靠 (size, mtime) 维持新鲜的，而这一对证明不了内容没变：
-- 把目标文件改成同样大小、再把 mtime 改回去，catalog 就在说谎，而
-- 'classifyDst' 会据此判 'VAtDest'\/'VArchived'——也就是「这张不用搬了」。
-- 凭一份没核对过的 sha 做这个决定，等于静默丢文件（codex 二十五轮 #2）。
--
-- 只对**将要被跳过**的那些重 hash：待拷的本来就要读源，被跳过的才是"不看就
-- 当它对"的那一类，所以这道复核的代价与它挡住的风险成正比。
--
-- 两个方向的降级不同，因为两处目标的语义不同：
--
--  * **暂存目标**内容不符 → 'VConflict'。那正是本命令要写入的位置，I5 适用。
--  * **归档目标**内容不符 → 'VCopy'。归档层的同名异容是 @pm import@ 的返修
--    裁决（@irRework@）管的事，sort 把文件送进暂存区即可，抢在它前面裁决会让
--    同一件事有两套判据。
--  * 目标压根不存在（索引说有）→ 'VCopy'，照搬。
-- 读取走 'probeConfined'：**逐级限域后再打开**，而不是 @root \</\> rel@ 直接
-- 开。库内任何一层是 junction 时，被"验证"的其实是库外的文件，而这个结论会
-- 被当成「已归档，不用搬」——本项目已经为这条反模式开过三轮评审，这里不能
-- 再开一个新口子（codex 二十六轮 #1）。同一个 helper 也给
-- 'Pm.Clean.anyWitnessAlive' 用，两处不再各写一遍。
verifySkips :: FilePath -> [Judged] -> IO [Judged]
verifySkips root = mapM check
 where
  check j = case jVerdict j of
    VAtDest -> recheck j (jDst j) True
    VArchived -> recheck j (jArch j) False
    _ -> pure j
  recheck j rel isStaging = do
    p <- probeConfined root rel
    pure $ case p of
      -- 索引说有、盘上没有 → 照搬。
      CpMissing -> j {jVerdict = VCopy}
      -- **读不到不等于不存在**：两者的安全方向相反（缺席→照搬，读不到→保守）。
      CpUnreadable e -> j {jVerdict = VConflict (T.pack ("目标读不到，无法确认可跳过: " <> e))}
      CpEscaped -> j {jVerdict = VConflict "目标路径中途有 reparse point，拒绝据此跳过"}
      CpSha actual
        | actual == jSha j -> j
        | isStaging -> j {jVerdict = VConflict "暂存目标实际内容与索引不符"}
        -- 归档层同名异容是 import 的返修裁决管的事，照常拷进暂存区。
        | otherwise -> j {jVerdict = VCopy}

emit :: Config -> GoOpts -> RootInfo -> [Judged] -> IO Int
emit cfg go info judged = do
  let root = cfgMainPath cfg
  printf
    "归位：待拷 %d · 已在目标位置 %d · 已归档 %d · 待裁决 %d\n"
    (tally (== VCopy))
    (tally (== VAtDest))
    (tally (== VArchived))
    (tally isConflict)
  forM_ [j | j <- judged, isConflict (jVerdict j)] $ \j ->
    putStrLn ("  ⚠ " <> takeFileName (jSrc j) <> ": " <> conflictWhy (jVerdict j))
  forM_ (take 10 [j | j <- judged, jVerdict j == VArchived]) $ \j ->
    putStrLn ("  · 已归档，不重复搬: " <> takeFileName (jSrc j))
  if null items
    then putStrLn "✓ 没有需要归位的新照片" >> pure 0
    else do
      pid <- newPlanId
      now <- getCurrentTime
      savePlanAndMaybeRun
        cfg
        go
        Plan
          { plId = pid
          , plKind = "sort"
          , plRootPath = root
          , plRootId = Just (riId info)
          , plCreated = now
          , plItems = items
          }
 where
  tally f = length [() | j <- judged, f (jVerdict j)]
  items =
    [ PlanItem ix (OpCopy (jSrc j) (jDst j) (jSha j) (ssSize (jStat j)) (ssMtimeNs (jStat j))) (statusOf (jVerdict j)) Nothing
    | (ix, j) <- zip [0 ..] [j | j <- judged, plannable (jVerdict j)]
    ]

isConflict :: Verdict -> Bool
isConflict (VConflict _) = True
isConflict _ = False

conflictWhy :: Verdict -> String
conflictWhy (VConflict w) = T.unpack w
conflictWhy _ = ""

-- | 进计划的只有两类：正常拷贝，与待裁决（后者进计划但**不执行**，等
-- @pm resolve@）。已在目标位置\/已归档的不进——它们不是要做的事。
plannable :: Verdict -> Bool
plannable VCopy = True
plannable (VConflict _) = True
plannable _ = False

statusOf :: Verdict -> ItemStatus
statusOf (VConflict why) = StNeedsDecision (why <> " → pm resolve --keep src|dst|both")
statusOf _ = StPending
