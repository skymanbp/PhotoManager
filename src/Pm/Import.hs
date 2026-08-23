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

import Data.Char (isDigit, toLower)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import System.FilePath (joinPath, normalise, splitDirectories, takeBaseName, takeDirectory, (</>))

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
  , irReworkKin :: [(Entry, FilePath)]
    -- ^ 复审 mj-3：同目录同 stem 组里有成员在返修 → 组内其余待拷文件一并
    -- 悬置为 NEEDS-DECISION（侧车必须跟随其主文件的裁决，绝不先行落位）
  , irPendingEdit :: [FilePath]
    -- ^ 待修改\\ 下的文件，import 不碰（§7）
  , irUnrecognized :: [FilePath]
    -- ^ 布局或事件名解析失败，只报告不猜
  , irDupTarget :: [(FilePath, FilePath)]
    -- ^ (srcRel, dstRel) — 两个源映射到同一目标，连同 stem 组整组拒绝
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
      -- 评审 mj-2：NTFS 大小写不敏感——目标唯一性与已归档查询一律用
      -- case-fold 键，计划期就抓住 26-06-R66\D.ARW vs 26-06-r66\d.arw 这类
      -- 同目标碰撞，而不是留给执行期的晚期 conflict。
      catByFold = Map.fromList [(foldPath (enPath e), e) | e <- Map.elems (catEntries cat)]
      dstCount = Map.fromListWith (+) [(foldPath dst, 1 :: Int) | (_, dst) <- mapped]
      collided (_, dst) = Map.findWithDefault 0 (foldPath dst) dstCount > 1
      -- 评审 mj-3：撞名升级到「同目录同 stem 组」——被拒文件的侧车
      -- (.xmp/.acr 同 stem) 一起进 dup 桶，绝不产生孤立侧车（§7 侧车跟随）。
      stemKey rel = (foldPath (takeDirectory rel), foldPath (takeBaseName rel))
      collStems =
        Set.fromList [stemKey (enPath e) | m@(e, _) <- mapped, collided m]
      isDup m@(e, _) = collided m || stemKey (enPath e) `Set.member` collStems
      dups = filter isDup mapped
      uniq = filter (not . isDup) mapped
      classify (e, dst) = case Map.lookup (foldPath dst) catByFold of
        Nothing -> (Just (e, dst), Nothing, Nothing)
        Just archived
          | enSha archived == enSha e -> (Nothing, Just (enPath e, dst), Nothing)
          | otherwise -> (Nothing, Nothing, Just (e, dst))
      classified = map classify uniq
      -- 复审 mj-3：返修同样升级到 stem 组——主文件 NEEDS-DECISION 时，其同
      -- 目录同 stem 的待拷侧车不得先行落位（先拷会产生孤立侧车；裁决 keep
      -- both 改名时更会指错主文件）。
      reworkStems =
        Set.fromList [stemKey (enPath e) | (_, _, Just (e, _)) <- classified]
      inReworkKin (e, _) = stemKey (enPath e) `Set.member` reworkStems
   in ImportReport
        { irCopy = [c | (Just c, _, _) <- classified, not (inReworkKin c)]
        , irAlready = [a | (_, Just a, _) <- classified]
        , irRework = [r | (_, _, Just r) <- classified]
        , irReworkKin = [c | (Just c, _, _) <- classified, inReworkKin c]
        , irPendingEdit = pendingEdit
        , irUnrecognized = unrecognized
        , irDupTarget = [(enPath e, dst) | (e, dst) <- dups]
        }

-- | Windows-semantics comparison key（评审 mj-2）：normalise + case-fold。
foldPath :: FilePath -> FilePath
foldPath = map toLower . normalise

-- | Plan items for the actionable part of the report. @root@ is the main
-- library root (staging lives inside it) — sources become absolute here.
importPlanItems :: FilePath -> ImportReport -> [PlanItem]
importPlanItems root rep =
  [PlanItem ix op st Nothing | (ix, (op, st)) <- zip [0 ..] (copies <> reworks <> kins)]
 where
  copies = [(mkCopy e dst, StPending) | (e, dst) <- irCopy rep]
  reworks =
    [ (mkCopy e dst, StNeedsDecision "目标已存在且内容不同（返修）→ pm resolve --keep src|dst|both")
    | (e, dst) <- irRework rep
    ]
  kins =
    [ (mkCopy e dst, StNeedsDecision "同 stem 主文件返修待裁决，侧车/同组文件悬置（mj-3）")
    | (e, dst) <- irReworkKin rep
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
