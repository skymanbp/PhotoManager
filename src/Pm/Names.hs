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

import Data.Char (isDigit)
import Data.List (isSuffixOf, stripPrefix)

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

-- | Staging raw event folder → (year folder, canonical Scheme A name).
-- \"26-04-Providence\" → (\"2026\", \"26-04-Providence-Raw\"); idempotent on
-- names already carrying the \"-Raw\" suffix.
canonRawEvent :: String -> Maybe (String, String)
canonRawEvent name = do
  (yy, _, _) <- parseYYMM name
  let canon = if "-Raw" `isSuffixOf` name then name else name <> "-Raw"
  pure (yearFolder yy, canon)

-- | Staging processed event folder → canonical 成片 folder name
-- (\"YY-MM-地点\", stripping a stray \"-Raw\" suffix if present).
canonProcessedEvent :: String -> Maybe String
canonProcessedEvent name = do
  (_, _, loc) <- parseYYMM name
  case stripSuffixStr "-Raw" name of
    Just stripped | not (null (drop 6 stripped)) -> pure stripped
    _ -> if null loc then Nothing else pure name

-- | All library years are 20xx (earliest event: 2022).
yearFolder :: Int -> String
yearFolder yy = "20" <> (if yy < 10 then '0' : show yy else show yy)

stripSuffixStr :: String -> String -> Maybe String
stripSuffixStr suf s = reverse <$> stripPrefix (reverse suf) (reverse s)
