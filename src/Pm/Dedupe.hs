{-# LANGUAGE OverloadedStrings #-}

-- | @pm dedupe@ —— 归档层内**精确重复**（同 sha）的隔离计划生成器
-- （DESIGN-COMMANDS §8）。
--
-- 判据不另起一套：来源就是 'Pm.Versions.versionsReport' 的 @vgExactDups@。
-- 同一份报告既是 @pm versions@ 的只读展示、也是本计划的唯一来源，两者不可能
-- 给出不同答案——「设计内冗余」（P4-9 的三条判据）已在那里排除，这里不重抄
-- 一遍。同一份知识出现两处就迟早分叉，这是 codex 二十五轮 #5 的教训。
--
-- **每一条都是 NEEDS-DECISION**。哪一份该留是用户的判断（事件夹归属、命名
-- 偏好、是否被外部引用），pm 判不出就不猜（I1）。计划只把「同字节的这 N 份
-- 在这里」摆出来、每份配一个可裁决的隔离条目；用户逐份批准
-- （@pm resolve \<id\> --item N --unskip@），@pm apply@ 只执行被批准的那些。
--
-- 组内条目**不**用 'Pm.Plan.piGroup' 绑成复合组：复合组的语义是「不可拆分」
-- （supersede 的 Quarantine+Copy 配对），而这里恰恰要求逐份裁决——三份留一份
-- 就是只批准其中两条。组的完整性改由**执行期屏障**保证：'recheckDedupeItems'
-- 在每次执行前确认该 sha 至少还留一份归档层副本**活在盘上**，否则把这些条目
-- 降级回 NEEDS-DECISION。同一道屏障在 @pm trash empty@ 永久删除前再走一次
-- （按 'dedupeReasonPrefix' 分流）。
module Pm.Dedupe
  ( DupGroup (..)
  , dedupeGroups
  , dedupePlanItems
  , dedupeReasonPrefix
  , archiveLayerRel
  , survivingArchiveCopies
  , archiveCopyAlive
  , anyArchiveCopyAlive
  , recheckDedupeItems
  ) where

import Control.Monad (forM)
import Data.Char (toLower)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (splitDirectories)

import Pm.Hash (anyCopyAlive)
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..))
import Pm.Types
import Pm.Versions (VersionsReport (..), versionsReport)

-- | 一组同 sha 的归档层文件（≥2 份）。
data DupGroup = DupGroup
  { dgSha :: Text
  , dgPaths :: [FilePath]
    -- ^ 库内相对路径，已排序（顺序来自 'versionsReport'，稳定可复现）
  }
  deriving (Show, Eq)

dedupeGroups :: Catalog -> [DupGroup]
dedupeGroups cat = [DupGroup sha ps | (sha, ps) <- vgExactDups (versionsReport cat)]

-- | 隔离记录 reason 的前缀。@pm trash empty@ 按它把记录分流到本类的**永久
-- 删除前屏障**，所以必须是这一个常量，而不是写入方与消费方各自手抄的字面量
-- （@clean-staging@ 就曾是两处字面量）。
dedupeReasonPrefix :: Text
dedupeReasonPrefix = "dedupe"

-- | 每一份重复文件一个条目，**全部** NEEDS-DECISION。序号即 'PlanItem' 的
-- @piIx@，用户按它裁决。
dedupePlanItems :: [DupGroup] -> [PlanItem]
dedupePlanItems gs = zipWith mk [0 ..] flat
 where
  flat = [(dgSha g, length (dgPaths g), p) | g <- gs, p <- dgPaths g]
  mk ix (sha, n, p) =
    PlanItem
      ix
      OpQuarantine
        { opVictimRel = p
        , opVictimSha = sha
        , opReason = dedupeReasonPrefix <> ":同 sha " <> T.pack (show n) <> " 份之一"
        }
      (StNeedsDecision (why n))
      Nothing
  why n =
    T.pack
      ( "同字节 "
          <> show n
          <> " 份，留哪一份由你定（pm 不猜，I1）；批准隔离这一份: "
          <> "pm resolve <计划 id> --item <序号> --unskip"
      )

-- | 归档三层——与 'Pm.Versions' 的报告范围同一套。暂存区不在 dedupe 视野内
-- （那里的冗余是**设计内**的「已归档待清理」，归 @pm clean staging@ 管）。
archiveLayerRel :: FilePath -> Bool
archiveLayerRel p = take 1 (splitDirectories p) `elem` [["Raw"], ["成片"], ["相册"]]

-- | case-fold 后的路径键。Windows 上只差大小写的两条路径是**同一个文件**。
foldPath :: FilePath -> String
foldPath = map toLower

-- | 同 sha 的归档层副本里，**不在本次批准隔离名单**上的那些（即幸存者）。
--
-- 名单比对走 'foldPath'：把只差大小写的路径也算成受害者。方向是刻意的——
-- 算错成"受害者"只会让屏障多拒一次（NEEDS-DECISION，用户再看一眼）；算错成
-- "幸存者"则会让屏障**放行最后一份**。两个方向的代价不对称。
survivingArchiveCopies :: Catalog -> Set.Set String -> Text -> [FilePath]
survivingArchiveCopies cat victims sha =
  [ enPath e
  | e <- Map.elems (catEntries cat)
  , enSha e == sha
  , archiveLayerRel (enPath e)
  , not (Set.member (foldPath (enPath e)) victims)
  ]

-- | 「这个 sha 在归档层至少还留着一份**活的**副本」。
--
-- catalog 声称有不算数——它是快照，而这道判定的下游是把一份副本移出归档层
-- （再往下是 @pm trash empty@ 的永久删除）。读取走 'anyCopyAlive'：逐级限域、
-- 只打开一次、句柄上查 link count、同句柄读完。同一个对象出现在两个名字下
-- 不算两份，所以 hardlink 一并拒绝。
archiveCopyAlive :: FilePath -> Catalog -> Set.Set String -> Text -> IO Bool
archiveCopyAlive root cat victims sha =
  anyCopyAlive root sha (survivingArchiveCopies cat victims sha)

-- | 「归档层现在还有这个 sha 的活副本吗」——不排除任何路径。
--
-- @pm trash empty@ 的永久删除前屏障用它：受害者此刻已经在 @.pm\/trash@ 里、
-- 不在归档层，所以没有需要排除的名单。与 'archiveCopyAlive' 同一实现，只是
-- 名单为空——不另写一遍循环。
anyArchiveCopyAlive :: FilePath -> Catalog -> Text -> IO Bool
anyArchiveCopyAlive root cat = archiveCopyAlive root cat Set.empty

-- | 执行期屏障：批准隔离的条目中，同一个 sha 不得把**最后一份**归档层副本也
-- 隔离掉。
--
-- 为什么必须在执行期而不是生成时算一次：计划生成与执行之间的世界会变——另一
-- 份可能已被别的计划移走、被外部改写、或盘上根本读不出来。这与
-- @clean-staging@ 的执行期三副本复验（评审 cx-3）是同一条纪律，也是同一个
-- 理由：**catalog 是快照，不是证据**。
--
-- 读不出来（占用、ACL、介质错误）与"另一份还在"必须给出相反的结论：
-- 'anyCopyAlive' 只在真读到期望 sha 时才算数，其余一律不算——fail-closed。
recheckDedupeItems :: FilePath -> Catalog -> Plan -> IO Plan
recheckDedupeItems root cat plan = do
  let pending =
        [ (v, sha)
        | it <- plItems plan
        , piStatus it == StPending
        , OpQuarantine v sha _ <- [piOp it]
        ]
      victims = Set.fromList [foldPath v | (v, _) <- pending]
      shas = Set.toList (Set.fromList (map snd pending))
  judged <- forM shas $ \sha -> (,) sha <$> archiveCopyAlive root cat victims sha
  let doomed = Set.fromList [sha | (sha, False) <- judged]
  items' <- forM (plItems plan) $ \it -> case (piStatus it, piOp it) of
    (StPending, OpQuarantine v sha _)
      | Set.member sha doomed -> do
          putStrLn ("  ⚠ 隔离后归档层将不再有此内容的活副本，该项暂停: " <> v)
          pure it {piStatus = StNeedsDecision lastCopyWhy}
    _ -> pure it
  pure plan {plItems = items'}
 where
  lastCopyWhy =
    "执行期复验：批准的这些条目会把该内容在归档层的最后一份也隔离掉（或余下"
      <> "的那份读不出来）→ 先 pm scan 确认另一份仍在，或改为保留这一份"
