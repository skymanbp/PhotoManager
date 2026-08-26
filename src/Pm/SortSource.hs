{-# LANGUAGE ScopedTypeVariables #-}

-- | @pm sort@ 的源目录扫描与快照层（P6-H：Sort.hs 触及 750 行预算拆出，
-- 扫描块逐字节搬移、Pm.Sort 再导出，行为零改动；见 REVIEW-LOG 三十五轮）。
module Pm.SortSource
  ( SourceFiles (..)
  , listSource
  , stemOf
  , sidecarIndex
  , lookupSidecars
  , readTimes
  , snapshotSrc
  , snapshotWith
  , withSourceQ
  , withSource
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Time (LocalTime)
import System.Directory (canonicalizePath, doesDirectoryExist, makeAbsolute, pathIsSymbolicLink)
import System.FilePath (takeBaseName, takeDirectory, takeExtension, (</>))
import System.IO.Error (isDoesNotExistError)

import Pm.Exif (readCaptureTime)
import Pm.Hash (StatSnap, sha256File, statSnap)
import Pm.Import (foldPath)
import Pm.Scan (DotDirs (..), listTreeWith)
import Pm.Types

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
      -- 三十九轮（P7 探针类清扫）：探测异常不再塌成「非链接」。这行只产
      -- 说明（不改枚举/分类/计划），但塌 False 意味着源根恰是 junction 而
      -- 属性读瞬时失败时，说明行消失、用户以为整理的就是指定目录——
      -- 「查不出」就说查不出。「不存在」交给上层 doesDirectoryExist 的
      -- 判定，不在这里出声。
      rootLinkE <- tryIO (pathIsSymbolicLink dir)
      let rootLink = either (const False) id rootLinkE
          probeNotes =
            [ "源根的链接属性查不出（" <> show e <> "）——若它其实是 junction/symlink，实际整理的目录可能与指定的不同"
            | Left e <- [rootLinkE]
            , not (isDoesNotExistError e)
            ]
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
              probeNotes
                <> [ "源根本身是 symlink/junction，实际整理的是 " <> fromMaybe "（解析失败）" real
                   | rootLink
                   ]
          }
 where
  -- 只捕 IOException（三十九轮类清扫；Hash.hs 家规）：SomeException 会把
  -- UserInterrupt/ThreadKilled 一起吞掉。
  tryIO :: IO a -> IO (Either IOException a)
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
  -- 三十九轮（P7 类清扫）：SomeException→IOException。生产注入
  -- （statSnap/sha256File）只抛 IO 异常，行为不变；测试注入的断言失败
  -- （HUnitFailure）此前会被洗成 Left 再被调用方吞掉——收窄后照常传播，
  -- 这是修复不是收紧。
  pure (either (\(e :: IOException) -> Left (show e)) id r)

-- | 两种形态共用的源目录入口：解析成绝对路径、确认存在、分三摞列出。
-- **静默**——不打印任何东西，因为提议形态要把诊断当**数据**交回
-- （'SortSurvey'），计划形态才当场打印。
--
-- @onMissing@ 是源目录不存在时的返回值：两种形态的返回类型不同（一个是退出码，
-- 一个是 @Either@），所以它由调用方给，而不是在这里写死一个 2。
withSourceQ :: FilePath -> a -> (FilePath -> SourceFiles -> IO a) -> IO a
withSourceQ src onMissing k = do
  absSrc <- makeAbsolute src
  ok <- doesDirectoryExist absSrc
  if not ok
    then putStrLn ("源目录不存在: " <> absSrc) >> pure onMissing
    else listSource absSrc >>= k absSrc

-- | 同上，并把 'sfNotes' 打印出来——计划形态用。
--
-- 第 27 轮把诊断从 'sfErrors' 分出来之后**没接输出**，于是"分开"变成了静默
-- 丢弃：一条本来会打印的说明反而消失了（codex 二十八轮 #7）。它不计入
-- "未入计划 N 个"，那正是分开的目的。提议形态的同一件事由
-- 'renderSortSurvey' 做。
withSource :: FilePath -> a -> (FilePath -> SourceFiles -> IO a) -> IO a
withSource src onMissing k = withSourceQ src onMissing $ \absSrc sf -> do
  mapM_ (\n -> putStrLn ("· " <> n)) (sfNotes sf)
  k absSrc sf

