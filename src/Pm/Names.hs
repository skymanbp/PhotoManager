-- | Event-folder name parsing and canonicalization (DESIGN.md §8). P2 uses
-- the subset needed by @pm import@: staging event names → canonical landing
-- folders. Everything here is a pure function; anything that does not parse
-- is Nothing — the planner reports it instead of guessing (I1).
--
-- Canonical schemes (user ruling 2026-08-22):
--   Raw layer:  @Raw\\\<20YY\>\\YY-MM-地点-Raw\\@   (Scheme A)
--   成片 layer: @成片\\YY-MM-地点\\@
module Pm.Names
  ( parseYYMM
  , canonRawEvent
  , canonProcessedEvent
  ) where

import Data.Char (isDigit, toLower)

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

-- | All library years are 20xx (earliest event: 2022).
yearFolder :: Int -> String
yearFolder yy = "20" <> pad2 yy

pad2 :: Int -> String
pad2 n = if n < 10 then '0' : show n else show n
