-- | 版本组与精确重复报告（DESIGN.md §5 pm versions，只读）。
--
-- stem 规范化按 §1.1 实测后缀清单剥离；这是**报告级**归组——分组只影响
-- 展示不影响任何写路径，误并组的代价是一行噪音而非数据风险，因此宁可
-- 略贪也不漏报。剥离迭代至不动点（幂等，有测试钉住）。
--
-- 范围：归档层 Raw\/成片\/相册。暂存区 To-Be-Sync'd 天然含设计内冗余
-- （已归档待清理），由 status\/clean 报告，不进本报告。
--
-- **设计内冗余**（'designedGroup'）不作为「重复」报告。它有三条判据，不止
-- 一条——这是 2026-08-25 的更正：此前只认「成片↔相册 且同名」，把归档三层
-- 拓扑里另外两种必然的同字节关系全报成了缺陷（实测 15 组里误报 7 组）。
module Pm.Versions
  ( normalizeStem
  , VersionsReport (..)
  , versionsReport
  , runVersions
  ) where

import Data.Char (isDigit, toLower)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (joinPath, splitDirectories, takeBaseName, takeDirectory, takeExtension)
import Text.Printf (printf)

import Pm.Catalog (loadCatalog)
import Pm.Config (Config (..))
import Pm.Types

-- ─── stem 规范化（纯） ──────────────────────────────────────────────────────

-- | 迭代剥离一个版本后缀直到不动点。清单 = §1.1 实测：
-- @-已增强-NR -Enhanced-NR -HDR(-N) _hdr _ps _d _L _16.9 _16_9 -Red -edit
-- ~N -N _N .N F@（F 仅在紧跟数字之后剥，防误伤普通名字）。
normalizeStem :: String -> String
normalizeStem s =
  let s' = stripOne s
   in if s' == s then s else normalizeStem s'
 where
  stripOne x =
    case foldr tryStrip Nothing strippers of
      Just x' | not (null x') -> x'
      _ -> x
   where
    tryStrip f acc = case acc of
      Just _ -> acc
      Nothing -> f x
  lowEq suffix x =
    let n = length suffix
     in if length x > n && map toLower (drop (length x - n) x) == map toLower suffix
          then Just (take (length x - n) x)
          else Nothing
  strippers =
    [ lowEq "-已增强-NR"
    , lowEq "-Enhanced-NR"
    , lowEq "-HDR"
    , lowEq "_hdr"
    , lowEq "_ps"
    , lowEq "_d"
    , lowEq "_L"
    , lowEq "_16.9"
    , lowEq "_16_9"
    , lowEq "-Red"
    , lowEq "-edit"
    , sepDigits '~'
    , sepDigits '-'
    , sepDigits '_'
    , sepDigits '.'
    , trailingFAfterDigit
    ]
  -- "~4" "-2" "_3" ".2"（分隔符 + 1-2 位数字）
  sepDigits sep x =
    let (revDigits, rest) = span isDigit (reverse x)
     in case (revDigits, rest) of
          (ds, r : rs)
            | r == sep
            , not (null ds)
            , length ds <= 2
            , not (null rs) ->
                Just (reverse rs)
          _ -> Nothing
  trailingFAfterDigit x = case reverse x of
    ('F' : d : rest) | isDigit d -> Just (reverse (d : rest))
    _ -> Nothing

-- ─── 报告（纯核心） ─────────────────────────────────────────────────────────

data VersionsReport = VersionsReport
  { vgGroups :: [((FilePath, String), [FilePath])]
    -- ^ (目录, 规范化 stem case-fold) → 同组文件（>1 个才收）
  , vgExactDups :: [(Text, [FilePath])]
    -- ^ sha → 路径（>1；排除 'designedGroup' 认定的设计内冗余）
  }
  deriving (Show, Eq)

archiveLayers :: [String]
archiveLayers = ["Raw", "成片", "相册"]

-- | 相机**原始档**扩展名（case-fold）。判据③问的是"这一帧有没有 RAW 工作流"：
-- 有 → 同名 JPG 是导出件，放进 Raw 层是误放，要报；没有 → 那个 JPG 本身就是
-- 原片（相机直出 JPG／手机拍的／RAW 已遗失后用能找到的 JPG 顶替——用户
-- 2026-08-25 指出的三种情况，共同特征正是"没有对应的 RAW"）。
--
-- 列表以本库实测为准（Raw 层 arw 3794 · dng 71）并补齐常见机型格式。
-- @psd@\/@psb@\/@tif@ 是**编辑**格式不是原始档，不计入——它们的存在不能说明
-- 这一帧有 RAW。
rawExts :: [String]
rawExts =
  [".arw", ".dng", ".nef", ".cr2", ".cr3", ".raf", ".orf", ".rw2", ".pef", ".srw", ".sr2", ".x3f"]

versionsReport :: Catalog -> VersionsReport
versionsReport cat =
  VersionsReport {vgGroups = groups, vgExactDups = dups}
 where
  photos =
    [ e
    | e <- Map.elems (catEntries cat)
    , enKind e == KindPhoto
    , topOf (enPath e) `elem` archiveLayers
    ]
  topOf p = case splitDirectories p of (x : _) -> x; [] -> ""
  stemKey e =
    ( takeDirectory (enPath e)
    , map toLower (normalizeStem (takeBaseName (enPath e)))
    )
  grouped = Map.fromListWith (<>) [(stemKey e, [enPath e]) | e <- photos]
  groups =
    sortOn fst
      [ (k, sort ps)
      | (k, ps) <- Map.toList grouped
      , length ps > 1
      ]
  bySha = Map.fromListWith (<>) [(enSha e, [enPath e]) | e <- photos]
  dups =
    sortOn snd
      [ (sha, sort ps)
      | (sha, ps) <- Map.toList bySha
      , length ps > 1
      , not (designedGroup ps)
      ]

  baseOf p = map toLower (last' (splitDirectories p))
  last' xs = case reverse xs of (x : _) -> x; [] -> ""
  stemOf p = map toLower (normalizeStem (takeBaseName p))

  -- Raw 事件夹 = @Raw\<年>\<事件>@ 前三段。定位不到（层级不足）就返回
  -- Nothing，判据③随之拒绝认定设计内——宁可多报一行噪音。
  rawEventOf p = case splitDirectories p of
    (a : b : c : _) -> Just (joinPath [a, b, c])
    _ -> Nothing

  -- 各 Raw 事件夹里**出现过 RAW 原始档**的帧：(事件夹, 规范化 stem)。
  -- 用 'normalizeStem' 而不是裸 stem——@_DSC2227~2.JPG@ 要能对上
  -- @_DSC2227.ARW@，否则版本后缀会让导出件伪装成原片。
  rawOriginals =
    Set.fromList
      [ (ev, stemOf p)
      | e <- photos
      , let p = enPath e
      , topOf p == "Raw"
      , map toLower (takeExtension p) `elem` rawExts
      , Just ev <- [rawEventOf p]
      ]

  -- 相册是**平铺**的：它已占用的文件名（case-fold），判据②要用。
  albumNames =
    Set.fromList [baseOf (enPath e) | e <- photos, topOf (enPath e) == "相册"]

  -- | 设计内冗余：同一张照片在归档三层里各留一份是**拓扑**，不是重复。
  --
  --  ① 成片↔相册 同名 —— 相册 ⊂ 成片（I7），原判据。
  --  ② 成片↔相册 不同名，但成片那个名字在相册里已被**别的**文件占住 ——
  --     相册平铺，跨事件撞帧号时只能避让；这是刻意改名，不是命名分歧。
  --     （反面：名字没被占却仍不同名 → 真的命名分歧，仍要报。）
  --  ③ Raw↔成片 同名，且该 Raw 事件夹里没有同 stem 的原始档 —— 原片本来
  --     就是 JPG。有原始档则那个 JPG 是导出件，误放进 Raw，仍要报。
  --
  -- **同一层出现两份**（两个事件夹各一份、根与子目录各一份）一律不是设计内。
  -- 成片是链条中枢：Raw↔相册 直连属于跳层，也不认。
  designedGroup ps =
    let atLayer l = [p | p <- ps, topOf p == l]
        raw = atLayer "Raw"
        fin = atLayer "成片"
        alb = atLayer "相册"
     in length raw <= 1
          && length fin <= 1
          && length alb <= 1
          && length raw + length fin + length alb == length ps
          && not (null fin)
          && rawFinOk raw fin
          && finAlbOk fin alb

  rawFinOk [] _ = True
  rawFinOk [r] [f] =
    baseOf r == baseOf f && case rawEventOf r of
      Nothing -> False
      Just ev -> not (Set.member (ev, stemOf r) rawOriginals)
  rawFinOk _ _ = False

  finAlbOk _ [] = True
  finAlbOk [f] [a]
    | baseOf f == baseOf a = True
    | otherwise = Set.member (baseOf f) albumNames
  finAlbOk _ _ = False

-- ─── 命令入口（只读） ───────────────────────────────────────────────────────

runVersions :: Config -> IO Int
runVersions cfg = do
  (mcat, warns) <- loadCatalog (cfgMainPath cfg)
  mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
  case mcat of
    Nothing -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
    Just cat -> do
      let rep = versionsReport cat
      printf
        "版本组（同目录同 stem 多版本）: %d 组 · 非设计内精确重复: %d 组\n"
        (length (vgGroups rep))
        (length (vgExactDups rep))
      capped "版本组" (vgGroups rep) $ \((dir, stem), ps) -> do
        putStrLn ("  ≡ " <> dir <> " · stem \"" <> stem <> "\":")
        mapM_ (\p -> putStrLn ("      " <> p)) ps
      capped "精确重复" (vgExactDups rep) $ \(sha, ps) -> do
        putStrLn ("  = sha " <> T.unpack (T.take 16 sha) <> ":")
        mapM_ (\p -> putStrLn ("      " <> p)) ps
      putStrLn "（只读报告：版本后缀是历史信息，不强制统一；改名需经 pm names 类计划 + 用户勾选）"
      pure (if null (vgGroups rep) && null (vgExactDups rep) then 0 else 1)
 where
  cap = 30
  capped label xs act = do
    if null xs
      then pure ()
      else do
        mapM_ act (take cap xs)
        if length xs > cap
          then printf "  …%s另有 %d 组\n" label (length xs - cap)
          else pure ()
