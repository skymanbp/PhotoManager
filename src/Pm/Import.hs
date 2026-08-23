{-# LANGUAGE OverloadedStrings #-}

-- | The @pm import@ planner (DESIGN.md §7): pure classification of every
-- staging file into copy \/ already-archived \/ rework \/ pending-edit \/
-- unrecognized. Nothing here does IO; the CLI layer turns 'irCopy' and
-- 'irRework' into a persisted Plan for the normal confirm+apply machinery.
--
-- Rules encoded (all from §7):
--  * @To-Be-Sync'd\\Raw\\[<year>\\]<event>\\…@  → @Raw\\<20YY>\\<event>-Raw\\…@
--  * @To-Be-Sync'd\\Processed\\<event>\\…@      → @成片\\<event>\\…@
--  * @To-Be-Sync'd\\待修改\\…@ is never touched (report only).
--  * dst already has the same sha → 已归档冗余 (cleanup is @pm clean staging@'s
--    job, never import's); different sha → NEEDS-DECISION (rework), never an
--    automatic overwrite (I5).
--  * Anything whose layout or event name fails to parse → unrecognized,
--    reported verbatim — the planner does not guess (I1).
module Pm.Import
  ( ImportReport (..)
  , stagingTop
  , planImport
  , importPlanItems
  , stagingArchivedSummary
  ) where

import Data.Char (isDigit)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.FilePath (joinPath, splitDirectories, (</>))

import Pm.Names (canonProcessedEvent, canonRawEvent)
import Pm.Op
import Pm.Plan (ItemStatus (..), PlanItem (..))
import Pm.Types

stagingTop :: FilePath
stagingTop = "To-Be-Sync'd"

pendingEditDir :: FilePath
pendingEditDir = "待修改"

data ImportReport = ImportReport
  { irCopy :: [(Entry, FilePath)]
    -- ^ (staging entry, dstRel) — dst 不存在，正常归档
  , irAlready :: [(FilePath, FilePath)]
    -- ^ (srcRel, dstRel) — dst 同 sha，已归档冗余
  , irRework :: [(Entry, FilePath)]
    -- ^ (staging entry, dstRel) — dst 存在但 sha 不同 → NEEDS-DECISION
  , irPendingEdit :: [FilePath]
    -- ^ 待修改\\ 下的文件，import 不碰（§7）
  , irUnrecognized :: [FilePath]
    -- ^ 布局或事件名解析失败，只报告不猜
  , irDupTarget :: [(FilePath, FilePath)]
    -- ^ (srcRel, dstRel) — 两个源映射到同一目标，整组拒绝
  }
  deriving (Show, Eq)

-- | Where one staging file should land, if we can tell.
-- Left () = pending-edit; Right Nothing = unrecognized; Right (Just d) = dst.
route :: FilePath -> Either () (Maybe FilePath)
route rel = case splitDirectories rel of
  (top : sub : more)
    | top == stagingTop ->
        if sub == pendingEditDir
          then Left ()
          else case (sub, more) of
            ("Raw", parts) -> Right (routeRaw parts)
            ("Processed", event : rest@(_ : _)) ->
              Right ((\c -> "成片" </> c </> joinPath rest) <$> canonProcessedEvent event)
            _ -> Right Nothing
  _ -> Right Nothing
 where
  routeRaw parts = case parts of
    (y : event : rest@(_ : _))
      | isYearDir y -> do
          (yr, canon) <- canonRawEvent event
          -- 显式年份层与事件名推导年份不一致 → 不猜，报 unrecognized。
          if yr == y then Just ("Raw" </> yr </> canon </> joinPath rest) else Nothing
    (event : rest@(_ : _)) -> do
      (yr, canon) <- canonRawEvent event
      Just ("Raw" </> yr </> canon </> joinPath rest)
    _ -> Nothing
  isYearDir s = length s == 4 && all isDigit s

planImport :: Catalog -> ImportReport
planImport cat =
  let staging =
        [ e
        | e <- Map.elems (catEntries cat)
        , take 1 (splitDirectories (enPath e)) == [stagingTop]
        ]
      routed = [(e, route (enPath e)) | e <- staging]
      pendingEdit = [enPath e | (e, Left ()) <- routed]
      unrecognized = [enPath e | (e, Right Nothing) <- routed]
      mapped = [(e, dst) | (e, Right (Just dst)) <- routed]
      -- 同批目标唯一性：两个源指向同一 dst → 全组进 dupTarget，拒绝入计划
      dstCount = Map.fromListWith (+) [(dst, 1 :: Int) | (_, dst) <- mapped]
      isDup (_, dst) = Map.findWithDefault 0 dst dstCount > 1
      dups = filter isDup mapped
      uniq = filter (not . isDup) mapped
      classify (e, dst) = case Map.lookup dst (catEntries cat) of
        Nothing -> (Just (e, dst), Nothing, Nothing)
        Just archived
          | enSha archived == enSha e -> (Nothing, Just (enPath e, dst), Nothing)
          | otherwise -> (Nothing, Nothing, Just (e, dst))
      classified = map classify uniq
   in ImportReport
        { irCopy = [c | (Just c, _, _) <- classified]
        , irAlready = [a | (_, Just a, _) <- classified]
        , irRework = [r | (_, _, Just r) <- classified]
        , irPendingEdit = pendingEdit
        , irUnrecognized = unrecognized
        , irDupTarget = [(enPath e, dst) | (e, dst) <- dups]
        }

-- | Plan items for the actionable part of the report. @root@ is the main
-- library root (staging lives inside it) — sources become absolute here.
importPlanItems :: FilePath -> ImportReport -> [PlanItem]
importPlanItems root rep =
  [PlanItem ix op st | (ix, (op, st)) <- zip [0 ..] (copies <> reworks)]
 where
  copies = [(mkCopy e dst, StPending) | (e, dst) <- irCopy rep]
  reworks =
    [ (mkCopy e dst, StNeedsDecision "目标已存在且内容不同（返修）→ pm resolve --keep src|dst|both")
    | (e, dst) <- irRework rep
    ]
  mkCopy e dst =
    OpCopy
      { opSrcAbs = root </> enPath e
      , opDstRel = dst
      , opSha = enSha e
      , opSrcSize = enSize e
      , opSrcMtimeNs = enMtimeNs e
      }

-- | (staging file count, how many of them already have a same-sha copy
-- outside staging) — status uses this to say 「已归档，冗余」 vs 「待归档」.
-- 待修改\\ 不参与统计：那些文件在返修中，冗余与否无意义（clean 也不碰它们）。
stagingArchivedSummary :: Catalog -> (Int, Int)
stagingArchivedSummary cat =
  let (staging, archive) =
        Map.foldr
          ( \e (s, a) ->
              if take 1 (splitDirectories (enPath e)) == [stagingTop]
                then (if take 2 (splitDirectories (enPath e)) == [stagingTop, pendingEditDir] then s else e : s, a)
                else (s, Set.insert (enSha e) a)
          )
          ([], Set.empty)
          (catEntries cat)
   in (length staging, length [() | e <- staging, Set.member (enSha e) archive])
