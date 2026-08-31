{-# LANGUAGE OverloadedStrings #-}

-- | Pure catalog-vs-catalog difference for backup sync (DESIGN.md §9).
-- Identity is (relPath, sha256) — mtime is a per-root cache key and is never
-- compared across roots (§3).
--
-- 备份范围 = 主库 − 暂存区（用户 2026-08-31 裁定：@To-Be-Sync'd\\@ 只是中转，
-- 不进备份盘）。范围收窄在**这里**做一次，BackupCmd 的比对、apply 后的缓存
-- 重算（Pm.Apply）与 status 卡片全部继承；暂存文件因此不再产生 add\/update，
-- 备份盘上已有的暂存副本按「不在范围内」计入 EXTRA（只报告，删除由人做）。
-- 清暂存的三副本屏障不受影响——'Pm.Clean.planClean' 按 sha 找备份见证，
-- 归档层（Raw\/成片）的备份副本即可作证，不依赖暂存路径那份。
module Pm.Diff
  ( BackupDiff (..)
  , backupDiff
  , backupPlanItems
  ) where

import qualified Data.Map.Strict as Map
import System.FilePath (splitDirectories, (</>))

import Pm.Import (stagingTop)
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
  -- 主库侧先收窄到备份范围（模块头：暂存区不进备份盘）。谓词与
  -- 'Pm.Import'/'Pm.Clean' 的暂存判定同形（首组件 == stagingTop）。
  mainE = Map.filterWithKey (\rel _ -> take 1 (splitDirectories rel) /= [stagingTop]) (catEntries mainCat)
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
