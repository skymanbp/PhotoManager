{-# LANGUAGE OverloadedStrings #-}

-- | Pm.Exec 的对外类型面（'Checkpoint' \/ 'ExecEnv' \/ 'ItemOutcome'）与
-- 结果折叠 'updateCatalog'——三十四轮从 Pm.Exec 拆出（原文件触 750 行硬
-- 预算）。搬移为字节级、零语义改动；外部调用方一律经 Pm.Exec 的再导出。
module Pm.ExecTypes
  ( Checkpoint (..)
  , ExecEnv (..)
  , defaultExecEnv
  , ItemOutcome (..)
  , outcomeLabel
  , updateCatalog
  ) where

import Data.List (partition)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import System.FilePath (splitDirectories, takeExtension, (</>))

import Pm.Hash (StatSnap (..))
import Pm.Journal (Sync (..))
import Pm.Op
import Pm.Plan (BarrierKind, Plan, PlanItem (..))
import Pm.Types

-- | Protocol step markers, one between every pair of externally visible
-- effects (§13 P3 fault injection).
data Checkpoint
  = CpCopyAfterDstCheck
  | CpCopyAfterIntent
  | CpCopyAfterTmp
  | CpCopyAfterFlush
  | -- | 落位 rename 已成功、落位后复核之前（第一方自审工作流 F000 的注入点）
    CpCopyAfterLand
  | CpCopyAfterMove
  | CpRenAfterIntent
  | CpRenAfterMove
  | CpQuarAfterManifest
  | CpQuarAfterIntent
  | CpQuarAfterMove
  deriving (Show, Eq)

data ExecEnv = ExecEnv
  { eeCheckpoint :: Checkpoint -> IO ()
  , eeDoneSync :: Sync
    -- ^ Copy 的 Done 持久化模式。主库默认 Buffered（可组提交，C2/C3 从盘面
    -- 重建）；备份路径必须 Barrier（DESIGN.md §9）—— 备份盘是可移动介质，
    -- 打印结果后用户随时可能拔盘，Done 必须在汇报前已落盘。
    -- Rename/Quarantine 的 Done 永远 Barrier，不受此字段影响。
  , eeExpectRootId :: Maybe Text
    -- ^ 评审 cx-1：拿到锁之后、动盘之前复验 root-id.json 的 UUID。盘符会
    -- 漂移（备份盘 E: → F:），路径不是身份；不符即整批拒绝执行。
    -- Nothing = 跳过（测试用临时 root 无标识）。
  , eeBarrier :: Maybe (BarrierKind -> Plan -> IO [(Int, Text)])
    -- ^ 执行期**组屏障**（二十九轮 critical；三十轮 F4 类型封闭）。逐项的 sha
    -- 复核由内核自己做；钩子做的是**跨条目**判断——「该内容在归档层还留得下
    -- 一份活副本吗」——需要 catalog 与备份盘发现，属命令层知识。
    --
    -- 钩子只能返回**降级清单** @[(piIx, 原因)]@，新 Plan 由内核构造
    -- （'applyDemotions'）：升级回 pending、改写 Op、改写计划元数据在类型上
    -- **写不出来**，不再靠事后核对（旧 barrierDrift 已删）。内核仅存的自卫是
    -- 清单必须指向存在且 StPending 的条目——否则屏障的世界观与计划不符，
    -- 整批拒绝。「要不要屏障」仍是内核的知识（'Pm.Plan.kindBarrier'）：
    -- 该有而这里是 Nothing → 整批拒绝，缺席不会退化成静默跳过（P3b-5/A3）。
  }

defaultExecEnv :: ExecEnv
defaultExecEnv =
  ExecEnv
    { eeCheckpoint = \_ -> pure ()
    , eeDoneSync = Buffered
    , eeExpectRootId = Nothing
    , eeBarrier = Nothing
    }

data ItemOutcome
  = ODone {oSha :: Maybe Text, oDstStat :: Maybe StatSnap, oTrashRel :: Maybe FilePath}
  | OSkippedIdentical
  | ONotExecuted -- item was marked skipped / needs-decision
  | OConflict String
  | OFailed String
  deriving (Show, Eq)

outcomeLabel :: ItemOutcome -> String
outcomeLabel ODone {} = "DONE"
outcomeLabel OSkippedIdentical = "SKIP(同内容)"
outcomeLabel ONotExecuted = "未执行"
outcomeLabel (OConflict m) = "CONFLICT: " <> m
outcomeLabel (OFailed m) = "FAILED: " <> m

-- | Fold executed outcomes back into the mutated root's catalog. A directory
-- rename rewrites the path prefix of every entry beneath it.
updateCatalog :: UTCTime -> [(PlanItem, ItemOutcome)] -> Catalog -> Catalog
updateCatalog now results cat = foldl step cat results
 where
  step c (item, out) = case (piOp item, out) of
    (OpCopy _ dstRel sha _ _, ODone _ (Just st) _) ->
      c
        { catEntries =
            Map.insert
              dstRel
              Entry
                { enPath = dstRel
                , enSize = ssSize st
                , enMtimeNs = ssMtimeNs st
                , enSha = sha
                , enKind = classifyExt (takeExtension dstRel)
                , enLastVerified = Just now
                }
              (catEntries c)
        }
    (OpRename old new _, ODone {}) ->
      -- 第一方自审工作流 F004：两把 key 可以改写到同一目标（目标前缀下残留着
      -- 过期条目——目录被带外挪走后没重扫；undo 反向 rename 正是这个形状）。
      -- Map.fromList 让**字节序**决定谁活下来；改写后的条目描述的才是此刻占着
      -- 该路径的文件（exec 的前置条件：目标在盘上不存在），必须由它胜出：
      -- 左偏 union。丢弃本身是对的，只是不能由排序决定。
      let (moved, kept) = partition (underPrefix old . fst) (Map.toList (catEntries c))
       in c {catEntries = Map.fromList (map (rekey old new) moved) `Map.union` Map.fromList kept}
    (OpQuarantine victim _ _, ODone {}) ->
      c {catEntries = Map.delete victim (catEntries c)}
    _ -> c
  underPrefix old k = take (length (splitDirectories old)) (splitDirectories k) == splitDirectories old
  rekey old new (k, e) =
    let k' = foldr1 (</>) (splitDirectories new <> drop (length (splitDirectories old)) (splitDirectories k))
     in (k', e {enPath = k'})
