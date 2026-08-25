{-# LANGUAGE OverloadedStrings #-}

-- | Plans are pure data (DESIGN.md §3): printable, diffable, persisted under
-- @\<root\>\/.pm\/plans\/\<id\>.json@ of the root they mutate. Exec consumes
-- nothing else.
module Pm.Plan
  ( Plan (..)
  , PlanItem (..)
  , ItemStatus (..)
  , newPlanId
  , isValidPlanId
  , validatePlan
  , planPath
  , savePlan
  , loadPlan
  , renderPlan
  , groupClosure
  , kindNeedsBarrier
  ) where

import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (nub, sort)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Control.Exception (bracket)
import Control.Monad (when)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO (hClose)
import Text.Printf (printf)

import Pm.Config (pmDir, pmSubPlans, readPmState, requirePmTrusted, untrustedMsg)
import Pm.Win (flushHandleToDisk, moveFileNoReplace, openFreshBinary, resolveUnder)
import Pm.Op -- 含 isValidPlanId（P3b-8 起定义于 Pm.Op，本模块再导出）

data ItemStatus
  = StPending
  | StSkippedByUser
  | StNeedsDecision Text
  deriving (Show, Eq)

instance ToJSON ItemStatus where
  toJSON StPending = object ["s" .= ("pending" :: Text)]
  toJSON StSkippedByUser = object ["s" .= ("skipped" :: Text)]
  toJSON (StNeedsDecision why) = object ["s" .= ("needs-decision" :: Text), "why" .= why]

instance FromJSON ItemStatus where
  parseJSON = withObject "ItemStatus" $ \o -> do
    s <- o .: "s"
    case (s :: Text) of
      "pending" -> pure StPending
      "skipped" -> pure StSkippedByUser
      "needs-decision" -> StNeedsDecision <$> o .: "why"
      _ -> fail ("unknown item status: " <> show s)

data PlanItem = PlanItem
  { piIx :: Int
  , piOp :: Op
  , piStatus :: ItemStatus
  , piGroup :: Maybe Int
    -- ^ 复合组 id（P2.1，评审 cx-2/cx-5）：同组条目是不可拆分的语义单元
    -- （supersede = [Quarantine, Copy]）。--only/resolve 的选择自动扩到全组；
    -- Exec 内组内后续项失败会自动复位组内已执行的 Quarantine。
  }
  deriving (Show, Eq)

instance ToJSON PlanItem where
  toJSON p =
    object ["ix" .= piIx p, "op" .= piOp p, "status" .= piStatus p, "group" .= piGroup p]

instance FromJSON PlanItem where
  parseJSON = withObject "PlanItem" $ \o ->
    PlanItem <$> o .: "ix" <*> o .: "op" <*> o .: "status" <*> o .:? "group"

data Plan = Plan
  { plId :: Text
  , plKind :: Text
  , plRootPath :: FilePath
    -- ^ 生成时的挂载路径（展示/寻址用）；执行前按 'plRootId' 重新绑定。
  , plRootId :: Maybe Text
    -- ^ 被变更 root 的 UUID（P2.1，评审 cx-1）。apply 前必须重新发现/校验该
    -- UUID 并把执行 root 绑定为当前发现路径——盘符会漂移，UUID 不会。
    -- Maybe 仅为旧计划文件可解析；apply 拒绝执行 Nothing 的计划。
  , plCreated :: UTCTime
  , plItems :: [PlanItem]
  }
  deriving (Show, Eq)

instance ToJSON Plan where
  toJSON p =
    object
      [ "id" .= plId p
      , "kind" .= plKind p
      , "root" .= plRootPath p
      , "rootId" .= plRootId p
      , "created" .= plCreated p
      , "items" .= plItems p
      ]

instance FromJSON Plan where
  parseJSON = withObject "Plan" $ \o ->
    Plan <$> o .: "id" <*> o .: "kind" <*> o .: "root" <*> o .:? "rootId" <*> o .: "created" <*> o .: "items"

newPlanId :: IO Text
newPlanId = do
  now <- getCurrentTime
  bytes <- getRandomBytes 3
  let ts = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now
      hex = concatMap (printf "%02x") (BS.unpack bytes)
  pure (T.pack (ts <> "-" <> hex))

-- 'isValidPlanId'（生成格式 @YYYYMMDD-HHMMSS-hex6@）自 P3b-8 起定义在 'Pm.Op'
-- （'opIdParts' 也要它），本模块再导出；装载（'loadPlan'）与执行
-- （'Pm.Exec.execPlan'）两处都用它拒绝不合格式的 id（P3b-6 复审 A1）。

-- | 计划的结构性校验（装载与执行两处共用；P3b-7 复审 A1 \/ 新 major）：id 为
-- 生成格式；@piIx@ 非负且全局唯一——负数会拼出无法解析的 opId，重复序号让
-- 不同操作共享 oid，doctor\/undo 按 oid 折叠时会把它们混成一个；P3b-8 六轮
-- 复审 major：每个 Op 的相对路径字段过 'opPathsOk'（越界\/盘符\/ADS\/@.pm@
-- 内部一律拒绝——手编计划的路径会被拼到 root 上）。
validatePlan :: Plan -> Either String ()
validatePlan p
  | not (isValidPlanId (plId p)) =
      Left ("计划 id 不符合生成格式（" <> T.unpack (plId p) <> "，应为 YYYYMMDD-HHMMSS-hex6）")
  | any (< 0) ixs = Left "计划含负数条目序号（piIx < 0）"
  | length ixs /= Set.size (Set.fromList ixs) = Left "计划条目序号重复（piIx 不唯一）"
  | (bad : _) <- [piIx it | it <- plItems p, not (opPathsOk (piOp it))] =
      Left ("计划条目 " <> show bad <> " 含非法相对路径（绝对/盘符/':'/'.'/'..'/分隔符开头/.pm 内部）")
  | otherwise = Right ()
 where
  ixs = map piIx (plItems p)

plansDir :: FilePath -> FilePath
plansDir root = pmDir root </> pmSubPlans

planPath :: FilePath -> Text -> FilePath
planPath root pid = plansDir root </> (T.unpack pid <> ".json")

-- | P3b-12（九轮复审 major）：此前是覆盖写，计划文件名被预置成库外对象的
-- hardlink 时会写穿到库外（探针实证同型）。改为「独占创建 tmp → 删旧 →
-- 'moveFileNoReplace' 落位」：tmp 走 @CREATE_NEW@，删旧对 hardlink 只减一个
-- 目录项。删旧与落位之间崩溃会丢掉计划文件——可接受：计划可重新生成，耐久层
-- 是 journal（DESIGN §3）。
-- P3b-14（十一轮）：建目录之后对**完整路径**再验一次（同
-- 'Pm.Config.writeCacheFile'）。可信闸只覆盖 @.pm\/plans@ 这一层，计划文件
-- 自身是深度 2；它若是指向库外的 symlink，删旧那一步会删掉库外文件。
-- 拒绝以 IOException 抛出（同 'Pm.Config.withPmStateAppend'）：14 处调用点都在
-- 「生成计划 → 落盘 → 报告」的直线上，写不成必须整条命令中止，而不是让调用方
-- 各自决定怎么忽略。
savePlan :: Plan -> IO FilePath
savePlan p = do
  let root = plRootPath p
      pid = plId p
  createDirectoryIfMissing True (plansDir root)
  m <- resolveUnder root (".pm" </> pmSubPlans </> (T.unpack pid <> ".json"))
  case m of
    Nothing -> ioError (userError (untrustedMsg (planPath root pid)))
    Just fp -> do
      let tmp = fp <> ".tmp"
      bracket (openFreshBinary tmp) hClose $ \h -> do
        BSL.hPut h (encode p)
        flushHandleToDisk h
      old <- doesFileExist fp
      when old (removeFile fp)
      moveFileNoReplace tmp fp
      pure fp

-- | 装载前先验 id 格式（也挡住 @..\\x@ 之类拼进 'planPath' 的路径穿越），装载
-- 后再过 'validatePlan' 并验文件内 id 与文件名一致。
loadPlan :: FilePath -> Text -> IO (Either String Plan)
loadPlan root pid
  | not (isValidPlanId pid) =
      pure (Left ("计划 id 不符合生成格式（" <> T.unpack pid <> "，应为 YYYYMMDD-HHMMSS-hex6），拒绝装载"))
  | otherwise = do
      -- 闸在 loader 里（P3b-13 十轮 major）：apply/resolve 的计划查找此前在任何
      -- 可信判定之前就读了 .pm/plans。
      tr <- requirePmTrusted root
      case tr of
        Left m -> pure (Left m)
        Right () -> loadPlan' root pid

loadPlan' :: FilePath -> Text -> IO (Either String Plan)
loadPlan' root pid = do
      -- P3b-14（十一轮复审 major，探针实证）：计划文件在深度 2，可信闸只验到
      -- @.pm/plans@。实测把 @plans/<id>.json@ 做成库外计划的 hardlink **或**
      -- symlink 后，loadPlan 两种形态都把**库外计划**载入了——apply 会照它执行。
      -- 受信取用口一次治两种：完整路径 resolveUnder 认 symlink，句柄 link
      -- count 认 hardlink。
      rd <- readPmState root (pmSubPlans </> (T.unpack pid <> ".json"))
      case rd of
        Left m -> pure (Left m)
        Right Nothing -> pure (Left ("计划不存在: " <> planPath root pid))
        Right (Just bytes) ->
          pure $ case eitherDecodeStrict' bytes of
            Left e -> Left e
            Right p
              | plId p /= pid ->
                  Left ("计划文件内 id（" <> T.unpack (plId p) <> "）与文件名（" <> T.unpack pid <> "）不符，拒绝装载")
              | Left e <- validatePlan p -> Left (e <> "，拒绝装载")
              | otherwise -> Right p

renderPlan :: Plan -> [String]
renderPlan p =
  ("计划 " <> T.unpack (plId p) <> " (" <> T.unpack (plKind p) <> ") · root " <> plRootPath p)
    : [ printf
          "  %3d | %-9s | %s%s"
          (piIx it)
          (statusTag (piStatus it))
          (describeOp (piOp it))
          (groupTag (piGroup it))
      | it <- plItems p
      ]
 where
  statusTag StPending = "PENDING" :: String
  statusTag StSkippedByUser = "SKIPPED"
  statusTag (StNeedsDecision _) = "DECIDE"
  groupTag Nothing = "" :: String
  groupTag (Just g) = "  [组" <> show g <> "·不可拆分]"

-- | Expand a selection of item indices to full compound groups: selecting any
-- member of a group selects them all（评审 cx-2/cx-5 —— supersede 配对不允许
-- 被 --only 或 resolve 拆开）。
groupClosure :: Plan -> [Int] -> [Int]
groupClosure p sel =
  let gs = Set.fromList [g | it <- plItems p, piIx it `elem` sel, Just g <- [piGroup it]]
      extra = [piIx it | it <- plItems p, Just g <- [piGroup it], g `Set.member` gs]
   in sort (nub (sel <> extra))

-- | 哪些计划**种类**必须在执行期重算一道组屏障（而不只是逐项复核 sha）。
--
-- 这是该问题的**唯一一张表**，内核（'Pm.Exec.execPlan'）与命令层
-- （'Pm.Cli.preExecFor'）读的是同一份：
--
--   * 命令层照它决定挂哪个屏障函数；
--   * 内核照它决定「没挂屏障就整批拒绝」。
--
-- 二十九轮 critical（对抗复核未能驳倒）：屏障此前跑在 'Pm.Lock.withRootLock'
-- **之外**，锁内只复核 victim 自己的 sha，从不重算「该 sha 在归档层还留一份」。
-- 于是两个 pm 进程各跑 @pm apply <同一计划> --only 1@ 与 @--only 2@ ——
-- 屏障的 victims 只取 StPending，而 --only 把未选中项改写成 StSkippedByUser，
-- 双方各自看见对方那份还活着，双双放行，同一内容的**所有**副本一起进隔离区。
-- 判据与动盘必须是同一个跨进程事务（与二十一轮 vault-holds 名单同一裁定：
-- 「读 → 校验 → 写」整段进 I10 锁）。
kindNeedsBarrier :: Text -> Bool
kindNeedsBarrier k = k `elem` ["clean-staging", "dedupe"]
