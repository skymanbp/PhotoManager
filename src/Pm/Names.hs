{-# LANGUAGE OverloadedStrings #-}

-- | Event-folder name parsing, canonicalization and the @pm names@ planner
-- (DESIGN.md §8). Pure parsing\/classification is separated from the IO
-- planner so the decision logic is exhaustively testable; anything that does
-- not parse is reported instead of guessed (I1).
--
-- Canonical schemes (user ruling 2026-08-22):
--   Raw layer:  @Raw\\\<20YY\>\\YY-MM-地点-Raw\\@   (Scheme A)
--   成片 layer: @成片\\YY-MM-地点\\@
--
-- P3b-2 scope: Raw 事件夹统一到 Scheme A。Scheme B（@RAW-YYYY-季节-地点@）
-- 的月份从成片同年同地点事件还原；还原不出\/歧义\/年份夹不符 → 只报告
-- NEEDS-DECISION，不出计划项。跨层地点别名表（Hunan↔湖南）暂不需要：
-- 需要它的 2023 中文事件在 Raw 侧已是 Scheme A，无改名需求；别名登记推迟到
-- 真实出现跨语言还原需求时（§8）。
module Pm.Names
  ( parseYYMM
  , canonRawEvent
  , canonProcessedEvent
  , parseSchemeB
  , RawNameClass (..)
  , classifyRawEvent
  , restoreMonth
  , NamesReport (..)
  , namesPlan
  , runNames
  ) where

import Control.Monad (forM, forM_)
import Data.Char (isDigit, toLower)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Text.Printf (printf)

import Pm.Config (Config (..), requireRole)
import Pm.Exec (dirFingerprint)
import Pm.Op
import Pm.Plan
import Pm.Types (RootInfo (..), RootRole (..))

-- ─── 解析（纯） ─────────────────────────────────────────────────────────────

-- | \"26-04-Providence\" → Just (26, 4, \"Providence\"). The location part
-- must be non-empty; the month must be 1-12 (a name like \"26-13-X\" is not
-- an event date and must surface as unrecognized, not be filed under a bogus
-- month).
parseYYMM :: String -> Maybe (Int, Int, String)
parseYYMM (a : b : '-' : c : d : '-' : rest)
  | all isDigit [a, b, c, d]
  , not (null rest)
  , let mm = read [c, d] :: Int
  , mm >= 1 && mm <= 12 =
      Just (read [a, b], mm, rest)
parseYYMM _ = Nothing

-- | Case-insensitively strip ONE trailing \"-Raw\" and parse what remains.
-- 评审 mj-1：后缀必须先剥再验地点非空——否则 \"26-04--Raw\" 的空地点会被
-- \"-Raw\" 冒充成地点、\"26-04-Raw\" 会歧义成地点叫 Raw；两者都必须拒绝。
-- Returns (yy, mm, location-without-suffix).
parseEventBase :: String -> Maybe (Int, Int, String)
parseEventBase name =
  case stripRawSuffix name of
    Just base -> parseYYMM base -- 带后缀：剥掉后仍须是合法 YY-MM-地点
    Nothing -> parseYYMM name
 where
  stripRawSuffix s =
    let n = length s
     in if n >= 4 && map toLower (drop (n - 4) s) == "-raw"
          then Just (take (n - 4) s)
          else Nothing

-- | Staging raw event folder → (year folder, canonical Scheme A name).
-- \"26-04-Providence\" → (\"2026\", \"26-04-Providence-Raw\"); idempotent on
-- names already carrying the suffix (also normalizes \"-raw\" → \"-Raw\").
canonRawEvent :: String -> Maybe (String, String)
canonRawEvent name = do
  (yy, mm, loc) <- parseEventBase name
  pure (yearFolder yy, pad2 yy <> "-" <> pad2 mm <> "-" <> loc <> "-Raw")

-- | Staging processed event folder → canonical 成片 folder name
-- (\"YY-MM-地点\", any stray \"-Raw\" suffix stripped).
canonProcessedEvent :: String -> Maybe String
canonProcessedEvent name = do
  (yy, mm, loc) <- parseEventBase name
  pure (pad2 yy <> "-" <> pad2 mm <> "-" <> loc)

-- | Scheme B: @RAW-YYYY-季节-地点@（大小写不敏感的 RAW 前缀；地点可含 '-'）。
-- \"RAW-2025-Winter-Alaska\" → Just (2025, \"Winter\", \"Alaska\")。
parseSchemeB :: String -> Maybe (Int, String, String)
parseSchemeB name = case splitOn '-' name of
  (p : y : season : locParts)
    | map toLower p == "raw"
    , length y == 4
    , all isDigit y
    , not (null season)
    , not (null locParts)
    , not (any null locParts) ->
        Just (read y, season, joinWith '-' locParts)
  _ -> Nothing
 where
  joinWith c = foldr1 (\a b -> a <> [c] <> b)

splitOn :: Char -> String -> [String]
splitOn c = foldr step [[]]
 where
  step ch acc@(cur : rest)
    | ch == c = [] : acc
    | otherwise = (ch : cur) : rest
  step _ [] = [[]]

-- ─── 分类（纯） ─────────────────────────────────────────────────────────────

data RawNameClass
  = RnCanonical
    -- ^ 已是 Scheme A（精确形态：零填充 + 精确 \"-Raw\" 大小写）
  | RnRename String
    -- ^ 可机械规范化（裸名补后缀、\"-raw\" 正大小写等）→ 目标名
  | RnSchemeB Int String String
    -- ^ (年 20YY, 季节, 地点) —— 月份需从成片还原
  | RnUnrecognized
  deriving (Show, Eq)

classifyRawEvent :: String -> RawNameClass
classifyRawEvent name = case parseSchemeB name of
  Just (y, s, l) -> RnSchemeB y s l
  Nothing -> case canonRawEvent name of
    Just (_, canon)
      | canon == name -> RnCanonical
      | otherwise -> RnRename canon
    Nothing -> RnUnrecognized

-- | 从成片事件名列表还原 Scheme B 的月份：同年（20YY）同地点（case-fold）
-- 的成片事件唯一 → 取其月份；零个或多个 → Left 说明。
restoreMonth :: [String] -> Int -> String -> Either String Int
restoreMonth processedNames year loc =
  case sort (dedup candidates) of
    [m] -> Right m
    [] -> Left "成片无同年同地点事件，月份无法还原"
    ms -> Left ("成片有多个候选月份 " <> show ms <> "，歧义")
 where
  fold = map toLower
  candidates =
    [ mm
    | n <- processedNames
    , Just (yy, mm, l) <- [parseYYMM n]
    , 2000 + yy == year
    , fold l == fold loc
    ]
  dedup = foldr (\x acc -> if x `elem` acc then acc else x : acc) []

-- ─── 计划（纯核心 + IO 装配） ───────────────────────────────────────────────

data NamesReport = NamesReport
  { nrOkCount :: Int
  , nrRenames :: [(String, String, String)]
    -- ^ (年份夹, 旧名, 新名)
  , nrDecisions :: [(String, String)]
    -- ^ (Raw\\年\\旧名, 原因) —— 只报告不入计划（决定权在用户）
  , nrUnrecognized :: [String]
  }
  deriving (Show, Eq)

-- | 纯核心：给定 Raw 层 (年份夹, [事件夹]) 与成片事件夹名，产出改名清单与
-- 待裁决清单。同批目标唯一性按 case-fold 校验：撞名的各方全部降为裁决
-- （不猜哪个对）。年份夹与事件名年份不符 → 裁决。
namesPlan :: [(String, [String])] -> [String] -> NamesReport
namesPlan rawYears processedNames =
  NamesReport
    { nrOkCount = length oks
    , nrRenames = uniqueRenames
    , nrDecisions = decisions <> dupDecisions
    , nrUnrecognized = unrecognized
    }
 where
  classified =
    [(yearDir, ev, classifyRawEvent ev) | (yearDir, evs) <- rawYears, ev <- evs]
  oks = [() | (_, _, RnCanonical) <- classified]
  unrecognized = [yd </> ev | (yd, ev, RnUnrecognized) <- classified]
  step (yd, ev, cls) = case cls of
    RnRename canon -> case canonRawEvent ev of
      Just (expectYear, _)
        | expectYear /= yd ->
            Left (yd </> ev, "事件年份推导为 " <> expectYear <> "，与所在年份夹不符（不猜，须人工定夺）")
      _ -> Right (yd, ev, canon)
    RnSchemeB y _ loc
      | show y /= yd ->
          Left (yd </> ev, "Scheme B 年份 " <> show y <> " 与所在年份夹不符（不猜）")
      | otherwise -> case restoreMonth processedNames y loc of
          Right mm -> Right (yd, ev, pad2 (y - 2000) <> "-" <> pad2 mm <> "-" <> loc <> "-Raw")
          Left why -> Left (yd </> ev, why)
    _ -> Left ("", "") -- RnCanonical/RnUnrecognized 不进 step（上面已滤）
  stepped =
    [ step (yd, ev, cls)
    | (yd, ev, cls) <- classified
    , isActionable cls
    ]
  isActionable RnRename {} = True
  isActionable RnSchemeB {} = True
  isActionable _ = False
  decisions = [d | Left d <- stepped, d /= ("", "")]
  renames = [r | Right r <- stepped]
  -- 同批目标唯一性（case-fold 全路径）：撞名各方全部降为裁决
  foldKey (yd, _, new) = map toLower (yd </> new)
  keyCount = Map.fromListWith (+) [(foldKey r, 1 :: Int) | r <- renames]
  (uniqueRenames, dups) =
    ( [r | r <- renames, Map.findWithDefault 0 (foldKey r) keyCount == 1]
    , [r | r <- renames, Map.findWithDefault 0 (foldKey r) keyCount > 1]
    )
  dupDecisions =
    [(yd </> old, "同批多个事件夹规范化到同一目标 " <> new <> "（不猜）") | (yd, old, new) <- dups]

-- | `pm names`：Raw 事件夹 Scheme A 统一计划（DESIGN §8）。目录改名走
-- §6.2 Rename 协议（FpDir 指纹 + journal 屏障），catalog 前缀由
-- updateCatalog 重写，undo 可整体回滚（FpDir 对目录自身改名不变）。
runNames :: (Plan -> IO Int) -> Config -> IO Int
runNames runPlan cfg = do
  let root = cfgMainPath cfg
      rawTop = root </> "Raw"
  ex <- doesDirectoryExist rawTop
  if not ex
    then putStrLn ("Raw 层不存在: " <> rawTop) >> pure 2
    else do
      years0 <- listDirectory rawTop
      yearDirs <- filterDirs rawTop (sort years0)
      let (validYears, oddTop) = span' isYearName yearDirs
      rawYears <- forM validYears $ \yd -> do
        evs0 <- listDirectory (rawTop </> yd)
        evs <- filterDirs (rawTop </> yd) (sort evs0)
        pure (yd, evs)
      processed <- do
        pex <- doesDirectoryExist (root </> "成片")
        if pex then listDirectory (root </> "成片") >>= filterDirs (root </> "成片") else pure []
      let rep = namesPlan rawYears processed
      printf
        "命名: 已合规 %d · 待改名 %d · 待裁决 %d · 无法识别 %d\n"
        (nrOkCount rep)
        (length (nrRenames rep))
        (length (nrDecisions rep))
        (length (nrUnrecognized rep))
      forM_ oddTop $ \d -> putStrLn ("  ⚠ Raw 下非年份目录（不碰）: " <> d)
      forM_ (nrUnrecognized rep) $ \p -> putStrLn ("  ⚠ 无法识别（不猜，不入计划）: " <> p)
      forM_ (nrDecisions rep) $ \(p, why) -> putStrLn ("  ✋ NEEDS-DECISION " <> p <> " —— " <> why)
      -- 计划期盘面校验：目标路径已被文件**或**目录占用 → 该项降为裁决
      -- （不覆盖，I5 计划期防线；P3b-5 复审 B3：只查目录会让文件占位漏进计划）
      checked <- forM (nrRenames rep) $ \(yd, old, new) -> do
        let target = rawTop </> yd </> new
        tex <- (||) <$> doesFileExist target <*> doesDirectoryExist target
        pure (if tex then Left (yd </> old, "目标路径已在盘上存在（文件或目录）: " <> new) else Right (yd, old, new))
      forM_ [d | Left d <- checked] $ \(p, why) ->
        putStrLn ("  ✋ NEEDS-DECISION " <> p <> " —— " <> why)
      let finalRenames = [r | Right r <- checked]
      if null finalRenames
        then do
          putStrLn "✓ 无可机械执行的改名"
          pure (if null (nrDecisions rep) && null (nrUnrecognized rep) && null [() | Left _ <- checked] then 0 else 1)
        else do
          -- P3b-5 复审 B1：以主库身份改名的前提是该路径确为 RoleMain root
          er <- requireRole RoleMain root
          case er of
            Left msg -> putStrLn msg >> pure 2
            Right info -> do
              items <- forM (zip [0 ..] finalRenames) $ \(i, (yd, old, new)) -> do
                fp <- dirFingerprint (rawTop </> yd </> old)
                pure (PlanItem i (OpRename ("Raw" </> yd </> old) ("Raw" </> yd </> new) (FpDir fp)) StPending Nothing)
              pid <- newPlanId
              now <- getCurrentTime
              runPlan
                Plan
                  { plId = pid
                  , plKind = "names"
                  , plRootPath = root
                  , plRootId = Just (riId info)
                  , plCreated = now
                  , plItems = items
                  }
 where
  isYearName n = length n == 4 && all isDigit n && take 2 n == "20"
  span' p xs = (filter p xs, filter (not . p) xs)
  filterDirs base ns = do
    flags <- mapM (\n -> doesDirectoryExist (base </> n)) ns
    pure [n | (n, True) <- zip ns flags]

yearFolder :: Int -> String
yearFolder yy = "20" <> pad2 yy

pad2 :: Int -> String
pad2 n = if n < 10 then '0' : show n else show n
