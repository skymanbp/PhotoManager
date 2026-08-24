-- | 版本组与精确重复报告（DESIGN.md §5 pm versions，只读）。
--
-- stem 规范化按 §1.1 实测后缀清单剥离；这是**报告级**归组——分组只影响
-- 展示不影响任何写路径，误并组的代价是一行噪音而非数据风险，因此宁可
-- 略贪也不漏报。剥离迭代至不动点（幂等，有测试钉住）。
--
-- 范围：归档层 Raw\/成片\/相册。暂存区 To-Be-Sync'd 天然含设计内冗余
-- （已归档待清理），由 status\/clean 报告，不进本报告；成片↔相册 的同名
-- 精确对是设计拓扑（相册 ⊂ 成片，I7），也不作为「重复」报告。
module Pm.Versions
  ( normalizeStem
  , VersionsReport (..)
  , versionsReport
  , runVersions
  ) where

import Data.Char (isDigit, toLower)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (splitDirectories, takeBaseName, takeDirectory)
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
    -- ^ sha → 路径（>1；排除设计内 成片↔相册 同名对）
  }
  deriving (Show, Eq)

archiveLayers :: [String]
archiveLayers = ["Raw", "成片", "相册"]

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
      , not (designedPair ps)
      ]
  -- 设计内精确对：恰好两份、同 case-fold 文件名、分属 成片 与 相册
  designedPair [p1, p2] =
    let base p = map toLower (last' (splitDirectories p))
        last' xs = case reverse xs of (x : _) -> x; [] -> ""
        tops = sort [topOf p1, topOf p2]
     in base p1 == base p2 && tops == sort ["成片", "相册"]
  designedPair _ = False

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
