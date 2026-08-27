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

import Data.Maybe (isJust)

import Pm.Hash (ContentProbe (..), anyCopyAliveExcept, probeConfined)
import Pm.Win (FileId)
import Pm.Import (inArchiveLayer, pendingEditDir, stagingTop)
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
  isPendingEdit e = take 2 (parts e) == [stagingTop, pendingEditDir]
  staging = [e | e <- Map.elems (catEntries mainCat), inStaging e]
  pendingEdit = [enPath e | e <- staging, isPendingEdit e]
  -- 「归档副本」口径共用 'Pm.Import.inArchiveLayer'（mj-5：只认 Raw/成片，
  -- 相册镜像必须 HELD 而不是放行清理）。
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
        stgRel = enPath (ccStaging c)
    -- 将被移走的就是这个暂存文件本身。见证不能与它是**同一个对象**——
    -- 同一个对象出现在两个名字下不是两份副本。读不到它的身份就没法判，
    -- fail-closed（codex 二十八轮 #2）。
    stg <- probeConfined mainRoot stgRel
    case stg of
      CpSha _ sid -> do
        -- 链式排除：归档见证 ∉ {暂存件}，备份见证 ∉ {暂存件, 归档见证}。
        -- 「三副本」要的是三个**不同对象**（物理冗余）；跨卷时后一条天然成立，
        -- 但主库与备份被配成同一卷时它就是唯一防线。
        ma <- witnessId mainRoot sha [sid] (ccArchiveCopies c)
        case ma of
          Nothing -> pure (ok, held <> [(stgRel, "HELD(归档副本内容核对不过，或与暂存件是同一对象 → 先 pm scan)")])
          Just aid -> do
            mb <- witnessId backupRoot sha [sid, aid] (ccBackupCopies c)
            pure $ case mb of
              Just _ -> (ok <> [c], held)
              Nothing -> (ok, held <> [(stgRel, "HELD(备份副本内容核对不过，或与归档副本是同一对象 → 先 pm backup)")])
      _ -> pure (ok, held <> [(stgRel, "HELD(暂存文件本身读不到，无法确认见证与它不是同一对象)")])

-- | 见证条目里第一条内容相符、且身份不在 @excl@ 里的那个的**身份**。
--
-- 判定本体在 'Pm.Hash.anyCopyAliveExcept'（逐级限域 → 只打开一次 → 同句柄取
-- 身份与内容）。它的下游是 @pm trash empty@ 的永久删除，与 @pm dedupe@ 的
-- 「至少留一份」屏障共用同一个实现——两处分叉就会有一处忘了限域
-- （codex 二十六轮 #1 / 二十七轮 #1）。交回身份而不是 Bool，是为了让调用方
-- 做**链式排除**：三副本要的是三个不同对象。
witnessId :: FilePath -> Text -> [FileId] -> [Entry] -> IO (Maybe FileId)
witnessId root' sha excl = anyCopyAliveExcept root' sha excl . map enPath

-- | @pm trash empty@ 对 clean-staging 隔离记录的最终屏障（评审 cx-3）：
-- 永久删除前按**当前** catalog + 真实重 hash 重新确认「归档层 + 备份盘」
-- 各有一份同 sha 副本仍然在盘。任何一侧不过 → 该条目 HELD 不删。
-- @excl@ = **即将被永久删除的那个对象**的身份（隔离区里的载荷）。见证与它
-- 同身份不算一份副本。
threeCopiesStillExist :: FilePath -> Catalog -> FilePath -> Catalog -> [FileId] -> Text -> IO Bool
threeCopiesStillExist mainRoot mainCat backupRoot bakCat excl sha = do
  let archiveWits = [e | e <- Map.elems (catEntries mainCat), inArchiveLayer e, enSha e == sha]
      backupWits = [e | e <- Map.elems (catEntries bakCat), enSha e == sha]
  ma <- witnessId mainRoot sha excl archiveWits
  case ma of
    Nothing -> pure False
    Just aid -> isJust <$> witnessId backupRoot sha (aid : excl) backupWits

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
