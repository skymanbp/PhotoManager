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
  , threeCopiesStillExist
  ) where

import Control.Monad (foldM)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import System.FilePath (splitDirectories)

import Pm.Hash (ContentProbe (..), probeConfined)
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
  -- 评审 mj-5：「归档副本」按契约只认 Raw/成片 两层——相册是下游收藏集，
  -- 只在相册有副本说明归档层错位，必须 HELD 而不是放行清理。
  inArchiveLayer e = take 1 (parts e) `elem` [["Raw"], ["成片"]]
  archiveBySha =
    Map.fromListWith
      (<>)
      [(enSha e, [e]) | e <- Map.elems (catEntries mainCat), inArchiveLayer e]
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

-- | catalog 声称的第二/第三副本还要过一次**真实重 hash** 活体核对（评审
-- mj-6：只比 size+mtime 挡不住位腐或恢复了时间戳的同尺寸覆盖——sha 才是
-- 内容证明）；不符就降级 HELD，绝不按过期 catalog 清理。
-- Returns (verified, demoted-to-held).
verifyCandidates :: FilePath -> FilePath -> [CleanCandidate] -> IO ([CleanCandidate], [(FilePath, String)])
verifyCandidates mainRoot backupRoot = foldM step ([], [])
 where
  step (ok, held) c = do
    let sha = enSha (ccStaging c)
    aOk <- anyWitnessAlive mainRoot sha (ccArchiveCopies c)
    bOk <- anyWitnessAlive backupRoot sha (ccBackupCopies c)
    pure $ case (aOk, bOk) of
      (True, True) -> (ok <> [c], held)
      (False, _) -> (ok, held <> [(enPath (ccStaging c), "HELD(归档副本内容核对不过 → 先 pm scan)")])
      (_, False) -> (ok, held <> [(enPath (ccStaging c), "HELD(备份副本内容核对不过 → 先 pm backup)")])

-- | 至少一个见证条目在盘上重读出期望 sha 才算副本仍然存在。
--
-- 读取走 'probeConfined'——**逐级限域后再打开**，而不是 @root' \</\> enPath e@
-- 直接开。这条判定的下游是**永久删除**（@pm trash empty@ 的最终屏障
-- 'threeCopiesStillExist' 用的就是它）：库内任何一层是 junction 时，被"验证"
-- 的其实是**库外**的文件，于是"副本还在"这个结论成立、隔离件被真删。本项目
-- 已经为这条反模式开过三轮评审，这里是最后一处遗漏（codex 二十六轮 #1，与
-- 'Pm.Sort.verifySkips' 同一根因，共用同一个 helper）。
anyWitnessAlive :: FilePath -> Text -> [Entry] -> IO Bool
anyWitnessAlive root' sha = go
 where
  go [] = pure False
  go (e : rest) = do
    p <- probeConfined root' (enPath e)
    case p of
      CpSha actual | actual == sha -> pure True
      _ -> go rest

-- | @pm trash empty@ 对 clean-staging 隔离记录的最终屏障（评审 cx-3）：
-- 永久删除前按**当前** catalog + 真实重 hash 重新确认「归档层 + 备份盘」
-- 各有一份同 sha 副本仍然在盘。任何一侧不过 → 该条目 HELD 不删。
threeCopiesStillExist :: FilePath -> Catalog -> FilePath -> Catalog -> Text -> IO Bool
threeCopiesStillExist mainRoot mainCat backupRoot bakCat sha = do
  let inArchiveLayer e = take 1 (splitDirectories (enPath e)) `elem` [["Raw"], ["成片"]]
      archiveWits = [e | e <- Map.elems (catEntries mainCat), inArchiveLayer e, enSha e == sha]
      backupWits = [e | e <- Map.elems (catEntries bakCat), enSha e == sha]
  aOk <- anyWitnessAlive mainRoot sha archiveWits
  bOk <- anyWitnessAlive backupRoot sha backupWits
  pure (aOk && bOk)

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
      Nothing
  | (ix, c) <- zip [0 ..] cands
  ]
