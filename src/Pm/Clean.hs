{-# LANGUAGE OverloadedStrings #-}

-- | The @pm clean staging@ planner (DESIGN.md §5): a staging file may be
-- quarantined ONLY when the same bytes are confirmed in BOTH the main
-- archive layers AND the backup drive's catalog (三副本确认 — staging copy,
-- archive copy, backup copy). Everything else is HELD with the missing copy
-- named. 待修改\\ is never cleaned: the user parked those files there to work
-- on them (§7 spirit — import 不碰，clean 同样不碰).
--
-- The pure planner lists WHICH entries witness the second and third copies;
-- the CLI layer stat-verifies one witness on each side against the live
-- filesystem before the item may enter a plan (a catalog claim alone is not
-- a copy).
module Pm.Clean
  ( CleanCandidate (..)
  , CleanReport (..)
  , planClean
  , verifyCandidates
  , cleanPlanItems
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import System.FilePath (splitDirectories, (</>))

import Pm.Hash (StatSnap (..), statSnap)
import Pm.Import (stagingTop)
import Pm.Op
import Pm.Plan (ItemStatus (..), PlanItem (..))
import Pm.Types

data CleanCandidate = CleanCandidate
  { ccStaging :: Entry
  , ccArchiveCopies :: [Entry]
    -- ^ 主库归档层（非暂存）内同 sha 的见证条目（≥1）
  , ccBackupCopies :: [Entry]
    -- ^ 备份盘 catalog 内同 sha 的见证条目（≥1）
  }
  deriving (Show, Eq)

data CleanReport = CleanReport
  { clEligible :: [CleanCandidate]
  , clHeld :: [(FilePath, String)]
    -- ^ (srcRel, 缺哪份副本)
  , clPendingEdit :: [FilePath]
    -- ^ 待修改\\：从不清理
  }
  deriving (Show, Eq)

planClean :: Catalog -> Catalog -> CleanReport
planClean mainCat bakCat =
  CleanReport
    { clEligible = eligible
    , clHeld = held
    , clPendingEdit = pendingEdit
    }
 where
  parts e = splitDirectories (enPath e)
  inStaging e = take 1 (parts e) == [stagingTop]
  isPendingEdit e = take 2 (parts e) == [stagingTop, "待修改"]
  staging = [e | e <- Map.elems (catEntries mainCat), inStaging e]
  pendingEdit = [enPath e | e <- staging, isPendingEdit e]
  archiveBySha =
    Map.fromListWith
      (<>)
      [(enSha e, [e]) | e <- Map.elems (catEntries mainCat), not (inStaging e)]
  backupBySha =
    Map.fromListWith (<>) [(enSha e, [e]) | e <- Map.elems (catEntries bakCat)]
  judged =
    [ ( e
      , Map.findWithDefault [] (enSha e) archiveBySha
      , Map.findWithDefault [] (enSha e) backupBySha
      )
    | e <- staging
    , not (isPendingEdit e)
    ]
  eligible = [CleanCandidate e as bs | (e, as@(_ : _), bs@(_ : _)) <- judged]
  held =
    [ (enPath e, heldReason (null as) (null bs))
    | (e, as, bs) <- judged
    , null as || null bs
    ]
  heldReason True True = "HELD(主库归档层与备份盘都无此内容)"
  heldReason True False = "HELD(主库归档层无此内容 → 先 pm import)"
  heldReason False True = "HELD(备份盘无此内容 → 先 pm backup)"
  heldReason False False = "HELD(内部不一致)" -- 列表推导守卫保证不可达；仅为模式完备

-- | catalog 声称的第二/第三副本还要过一次活体 stat 核对（size+mtime 未变才
-- 认那份 sha 还作数）；变了就降级 HELD，绝不按过期 catalog 清理。
-- Returns (verified, demoted-to-held).
verifyCandidates :: FilePath -> FilePath -> [CleanCandidate] -> IO ([CleanCandidate], [(FilePath, String)])
verifyCandidates mainRoot backupRoot = foldM step ([], [])
 where
  step (ok, held) c = do
    aOk <- anyStatMatch mainRoot (ccArchiveCopies c)
    bOk <- anyStatMatch backupRoot (ccBackupCopies c)
    pure $ case (aOk, bOk) of
      (True, True) -> (ok <> [c], held)
      (False, _) -> (ok, held <> [(enPath (ccStaging c), "HELD(归档副本盘面已变 → 先 pm scan)")])
      (_, False) -> (ok, held <> [(enPath (ccStaging c), "HELD(备份副本盘面已变 → 先 pm backup)")])
  anyStatMatch root' es = go es
   where
    go [] = pure False
    go (e : rest) = do
      r <- try (statSnap (root' </> enPath e)) :: IO (Either SomeException StatSnap)
      case r of
        Right s | ssSize s == enSize e && ssMtimeNs s == enMtimeNs e -> pure True
        _ -> go rest

-- | Quarantine items for the candidates that survived the CLI's live stat
-- verification. Victims keep their staging-relative path inside the trash,
-- so restoration is a plain rename back.
cleanPlanItems :: [CleanCandidate] -> [PlanItem]
cleanPlanItems cands =
  [ PlanItem
      ix
      OpQuarantine
        { opVictimRel = enPath (ccStaging c)
        , opVictimSha = enSha (ccStaging c)
        , opReason = "clean-staging:三副本已确认"
        }
      StPending
  | (ix, c) <- zip [0 ..] cands
  ]
