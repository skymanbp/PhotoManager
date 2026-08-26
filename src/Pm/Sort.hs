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
  , SortSurvey (..)
  , SortSegment (..)
  , surveySort
  , renderSortSurvey
  ) where

import Control.Exception (IOException, try)
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
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeBaseName, takeDirectory, takeFileName, (</>))
import Text.Printf (printf)

import Pm.Cli (GoOpts (..), freshStagingCatalog, savePlanAndMaybeRun)
import Pm.Config (Config (..), requireRole)
import Pm.Hash (ContentProbe (..), StatSnap (..), probeConfined)
import Pm.Import (foldPath, stagingTop)
import Pm.Names (canonProcessedEvent, canonRawEvent)
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), newPlanId)
import Pm.SortSource
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
reportChosen pick = reportChosenFiles (map fst (spTake pick) <> spSidecars pick)

-- | pick 之后**没有产出计划**的每一条路径都从这里出去。
--
-- 四条：撞名整批拒绝、事件名非法、暂存区新鲜度不过、源文件读取失败。第 27 轮
-- 只补了前两条，后两条一样一个文件都不出现在输出里（codex 二十八轮 #4）。
--
-- **不截断**。此前在 40 项处截断并打一行"另有 N 个"——这与本命令的契约直接
-- 矛盾：这是一条中止路径，用户要据此判断卡上还剩什么，"另有 2960 个"帮不上
-- 任何忙。清单长是因为源大，那就打印那么长。
reportChosenFiles :: [FilePath] -> IO ()
reportChosenFiles chosen = do
  printf
    "\n本次**没有任何文件**进入计划。被选中但未归位的 %d 个（含侧车）：\n"
    (length chosen)
  forM_ chosen $ \c -> putStrLn ("    " <> c)

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

-- | 一段候选分段（提议级；边界最终由用户给的 @--from\/--to@ 定）。
data SortSegment = SortSegment
  { sgIndex :: Int
  , sgFrom :: Day
  , sgTo :: Day
  , sgFirstAt :: LocalTime
  , sgLastAt :: LocalTime
  , sgCount :: Int
  , sgFirstFile :: FilePath
  , sgLastFile :: FilePath
  , sgSameMonthEvents :: [String]
    -- ^ 已有的同年月 Raw 事件夹：要并入就用 @--event@ 而不是 @--place@
  }
  deriving (Show, Eq)

-- | @pm sort \<源\>@ 只读提议的**结果**。
--
-- 与 'Pm.Status.statusReport' / 'Pm.BackupCmd.backupInitRun' 同一形态：判定与
-- 取数在这里，打印在 'renderSortSurvey'。GUI 第六页要的是结果不是那段文字，
-- 而两者必须同源——否则页面上看到的分段与终端建议的命令会各说各话。
data SortSurvey = SortSurvey
  { ssSrcAbs :: FilePath
  , ssGapHours :: Double
  , ssSegments :: [SortSegment]
  , ssPhotoCount :: Int
  , ssDatedCount :: Int
  , ssSidecarCount :: Int
  , ssUndated :: [FilePath]
  , ssHomelessCars :: [FilePath]
  , ssUnknown :: [FilePath]
  , ssErrors :: [(FilePath, String)]
  , ssNotes :: [String]
  }
  deriving (Show, Eq)

-- | **不写任何文件。**
surveySort :: FilePath -> Double -> Config -> IO (Either String SortSurvey)
surveySort src gapHours cfg = do
  let root = cfgMainPath cfg
  er <- requireRole RoleMain root
  case er of
    Left msg -> pure (Left msg)
    Right _ -> withSourceQ src (Left ("源目录不存在: " <> src)) $ \absSrc sf -> do
          (dated, undated) <- readTimes (sfPhotos sf)
          eexisting <- existingEvents root
          case eexisting of
            Left e -> pure (Left e)
            Right existing -> do
              let segs = segmentBy (realToFrac (gapHours * 3600)) dated
                  -- 「无主侧车」有一半**与区间无关**：同目录同 stem 在整个源里都
                  -- 没有主文件的，此刻就能判定，也就此刻该报（codex 二十六轮 #7）。
                  stems = Set.fromList [stemOf p | p <- sfPhotos sf]
                  homeless = [c | c <- sfSidecars sf, not (Set.member (stemOf c) stems)]
              pure . Right $
                SortSurvey
                  { ssSrcAbs = absSrc
                  , ssGapHours = gapHours
                  , ssSegments = [g | (i, seg) <- zip [1 ..] segs, Just g <- [mkSeg existing i seg]]
                  , ssPhotoCount = length (sfPhotos sf)
                  , ssDatedCount = length dated
                  , ssSidecarCount = length (sfSidecars sf)
                  , ssUndated = undated
                  , ssHomelessCars = homeless
                  , ssUnknown = sfUnknown sf
                  , ssErrors = sfErrors sf
                  , ssNotes = sfNotes sf
                  }
 where
  -- 段尾用 reverse 后模式匹配取，不用部分函数 last\/head：段虽已知非空，但那是
  -- 人看出来的，编译器看不出来——留 head 就是留一个将来重构时会炸的口子。
  mkSeg _ _ [] = Nothing
  mkSeg existing i seg@((p0, t0) : _) =
    let (pN, tN) = case reverse seg of ((a, b) : _) -> (a, b); [] -> (p0, t0)
     in Just
          SortSegment
            { sgIndex = i
            , sgFrom = localDay t0
            , sgTo = localDay tN
            , sgFirstAt = t0
            , sgLastAt = tN
            , sgCount = length seg
            , sgFirstFile = p0
            , sgLastFile = pN
            , sgSameMonthEvents = sameMonth existing (localDay t0)
            }

-- | 渲染 = CLI 的那段输出，逐字不变。
renderSortSurvey :: SortSurvey -> IO Int
renderSortSurvey sv = do
  mapM_ (\n -> putStrLn ("· " <> n)) (ssNotes sv)
  printf
    "pm sort · 源 %s → 暂存区 %s\\Raw\\\n  照片 %d 个：可定时 %d · 读不到拍摄时间 %d · 候选分段 %d（间隔 > %.0f 小时切一刀）\n  侧车 %d 个（跟随各自主文件，不单独分段）· 不认识的 %d 个 · 遍历错误 %d 个\n"
    (ssSrcAbs sv)
    stagingTop
    (ssPhotoCount sv)
    (ssDatedCount sv)
    (length (ssUndated sv))
    (length (ssSegments sv))
    (ssGapHours sv)
    (ssSidecarCount sv)
    (length (ssUnknown sv))
    (length (ssErrors sv))
  forM_ (ssSegments sv) (printSegment (ssSrcAbs sv))
  _ <-
    reportAccounting
      Accounting
        { acUndated = ssUndated sv
        , -- 提议阶段没有区间，「区间外」这一格此刻不适用（形态二拿到
          -- --from/--to 之后才算得出来）。
          acOutOfRange = []
        , acOrphanCars = ssHomelessCars sv
        , acUnknown = ssUnknown sv
        , acErrors = ssErrors sv
        }
  putStrLn "\n（分段只是提议：时间切不开首尾相接的两趟旅程，边界以你给的 --from/--to 为准）"
  pure 0

runSortSurvey :: FilePath -> Double -> Config -> IO Int
runSortSurvey src gapHours cfg = do
  r <- surveySort src gapHours cfg
  case r of
    Left msg -> putStrLn msg >> pure 2
    Right sv -> renderSortSurvey sv

printSegment :: FilePath -> SortSegment -> IO ()
printSegment absSrc g = do
  printf "\n段 %d  %s → %s · %d 张\n" (sgIndex g) (show (sgFirstAt g)) (show (sgLastAt g)) (sgCount g)
  printf "      首 %s   尾 %s\n" (takeFileName (sgFirstFile g)) (takeFileName (sgLastFile g))
  forM_ (sgSameMonthEvents g) $ \ev ->
    putStrLn ("      ↺ 已有同年月事件 " <> ev <> " —— 要并入就把下面的 --place 换成 --event " <> ev)
  printf
    "      → pm sort \"%s\" --place <地点> --from %s --to %s\n"
    absSrc
    (show (sgFrom g))
    (show (sgTo g))

-- | 暂存区与归档层里已有的事件夹名（用来提议复用，避免又造出跨夹重复）。
--
-- 三十五轮 F2：枚举包 try——Raw 年份夹被良性进程占住/挪走时 listDirectory
-- 抛出会让整个 survey 崩掉；静默当空更糟（提议不出「并入已有事件」，用户会
-- 照建议新建重复事件夹）。读不出 = Left，survey 整体拒绝（exit 2）。
existingEvents :: FilePath -> IO (Either String [String])
existingEvents root = do
  r <- try $ do
    a <- lsDir (root </> stagingTop </> "Raw")
    b <- concat <$> (mapM (lsDir . ((root </> "Raw") </>)) =<< lsDir (root </> "Raw"))
    pure (sort (Set.toList (Set.fromList (a <> map stripRawSuffix b))))
  pure $ case (r :: Either IOException [String]) of
    Left e -> Left ("已有事件夹枚举失败（被占/介质错误？）: " <> show e)
    Right evs -> Right evs
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
-- 返回 (退出码, 生成的计划 id)。id 只在真出了计划时是 Just——GUI 第六页要用
-- 它，而从 @.pm\/plans@ 里挑"最新的那个"是猜不是知道（并发生成时会挑错）。
runSortPlan :: GoOpts -> FilePath -> Either String String -> Day -> Day -> Config -> IO (Int, Maybe T.Text)
runSortPlan go src placeOrEvent from to cfg = do
  let root = cfgMainPath cfg
  -- 与 runImport 同一次序：身份校验先于任何读取与判定。
  er <- requireRole RoleMain root
  case er of
    Left msg -> putStrLn msg >> pure (2, Nothing)
    Right info -> withSource src (2, Nothing) $ \_ sf -> do
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
          pure (2, Nothing)
        (_, []) -> do
          putStrLn "该区间内没有可定时的照片"
          unless (left == 0) $
            printf "（源里另有 %d 个文件因上列原因未被归位）\n" left
          pure (1, Nothing)
        (_, taken@((_, t1) : _)) -> do
          unless (left == 0) $
            printf "\n（以上 %d 个文件**不在**本次计划里；清卡前请自行确认）\n" left
          case resolveEvent (localDay t1) placeOrEvent of
            -- 与撞名同类：计划前失败，被选中的文件一个都没搬走，同样要交代。
            Left why -> putStrLn ("✗ " <> why) >> reportChosen pick >> pure (2, Nothing)
            Right ev -> do
              -- 新鲜度不过同样是**计划前失败**：选中的文件一个都没搬走，
              -- 要与撞名/事件名非法一样逐条交代（codex 二十八轮 #4）。
              ecat <- freshStagingCatalog root
              case ecat of
                Left m -> putStrLn ("✗ " <> m) >> reportChosen pick >> pure (2, Nothing)
                Right cat ->
                  buildPlan cfg go info ev (map fst taken <> spSidecars pick) cat

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
-- 迟早会有一处传错。计划的执行期屏障也要 Config（'Pm.Cli.runBarrier'）。
buildPlan :: Config -> GoOpts -> RootInfo -> String -> [FilePath] -> Catalog -> IO (Int, Maybe T.Text)
buildPlan cfg go info ev picked cat = do
  let root = cfgMainPath cfg
  snaps <- forM picked $ \p -> (,) p <$> snapshotSrc p
  case [(p, why) | (p, Left why) <- snaps] of
    -- 少搬一个文件比搬错更难发现：能读的那些照样出计划，等于把"这批没全到"
    -- 藏进一份看上去正常的计划里。整批拒绝，把问题留在用户眼前。
    failed@(_ : _) -> do
      putStrLn "✗ 源文件读取失败，整批不出计划："
      forM_ failed $ \(p, why) -> putStrLn ("    " <> p <> " — " <> why)
      -- 读得出的那些也一个都没搬走：只列失败项，等于让人以为其余的进了计划
      -- （codex 二十八轮 #4，与第 27 轮 #4 同一形状——那次只扫了一半）。
      reportChosenFiles picked
      pure (2, Nothing)
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
      CpSha actual _
        | actual == jSha j -> j
        | isStaging -> j {jVerdict = VConflict "暂存目标实际内容与索引不符"}
        -- 归档层同名异容是 import 的返修裁决管的事，照常拷进暂存区。
        | otherwise -> j {jVerdict = VCopy}

emit :: Config -> GoOpts -> RootInfo -> [Judged] -> IO (Int, Maybe T.Text)
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
    then putStrLn "✓ 没有需要归位的新照片" >> pure (0, Nothing)
    else do
      pid <- newPlanId
      now <- getCurrentTime
      code <-
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
      pure (code, Just pid)
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
