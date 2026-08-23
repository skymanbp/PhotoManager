{-# LANGUAGE OverloadedStrings #-}

-- | Pure catalog-vs-catalog difference for backup sync (DESIGN.md §9).
-- Identity is (relPath, sha256) — mtime is a per-root cache key and is never
-- compared across roots (§3).
module Pm.Diff
  ( BackupDiff (..)
  , backupDiff
  , backupPlanItems
  ) where

import qualified Data.Map.Strict as Map
import System.FilePath ((</>))

import Pm.Op
import Pm.Plan (ItemStatus (..), PlanItem (..))
import Pm.Types

data BackupDiff = BackupDiff
  { bdAdd :: [Entry]
    -- ^ 主库有、备份盘没有（按相对路径）→ Copy
  , bdUpdate :: [(Entry, Entry)]
    -- ^ (主库条目, 备份条目) 同路径不同 sha → supersede 复合（§6.5）
  , bdExtra :: [FilePath]
    -- ^ 备份盘多出的 → EXTRA 只读报告，永不动（§9）
  , bdSame :: Int
  }
  deriving (Show, Eq)

backupDiff :: Catalog -> Catalog -> BackupDiff
backupDiff mainCat bakCat =
  BackupDiff
    { bdAdd = Map.elems (mainE `Map.difference` bakE)
    , bdUpdate =
        [ (m, b)
        | (rel, m) <- Map.toList mainE
        , Just b <- [Map.lookup rel bakE]
        , enSha m /= enSha b
        ]
    , bdExtra = Map.keys (bakE `Map.difference` mainE)
    , bdSame =
        length
          [ ()
          | (rel, m) <- Map.toList mainE
          , Just b <- [Map.lookup rel bakE]
          , enSha m == enSha b
          ]
    }
 where
  mainE = catEntries mainCat
  bakE = catEntries bakCat

-- | Plan items mutating the BACKUP root. Adds become plain copies; updates
-- become the §6.5 supersede compound — quarantine the backup's old bytes
-- (into the backup root's own trash) immediately before the copy. Each pair
-- shares a group id（评审 cx-2：--only\/resolve 按组闭包，Exec 组内失败自动
-- 复位）. Extras are deliberately absent: nothing in the algebra can touch
-- them.
backupPlanItems :: FilePath -> BackupDiff -> [PlanItem]
backupPlanItems mainRoot d =
  [PlanItem ix op st g | (ix, (op, st, g)) <- zip [0 ..] (adds <> updates)]
 where
  adds = [(copyOf m, StPending, Nothing) | m <- bdAdd d]
  updates =
    concat
      [ [ ( OpQuarantine
              { opVictimRel = enPath b
              , opVictimSha = enSha b
              , opReason = "supersede:backup-update"
              }
          , StPending
          , Just g
          )
        , (copyOf m, StPending, Just g)
        ]
      | (g, (m, b)) <- zip [0 ..] (bdUpdate d)
      ]
  copyOf m =
    OpCopy
      { opSrcAbs = mainRoot </> enPath m
      , opDstRel = enPath m
      , opSha = enSha m
      , opSrcSize = enSize m
      , opSrcMtimeNs = enMtimeNs m
      }
