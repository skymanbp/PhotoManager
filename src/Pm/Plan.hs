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
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import Text.Printf (printf)

import Pm.Config (pmDir, pmSubPlans)
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

savePlan :: Plan -> IO FilePath
savePlan p = do
  let root = plRootPath p
      fp = planPath root (plId p)
  createDirectoryIfMissing True (plansDir root)
  BSL.writeFile fp (encode p)
  pure fp

-- | 装载前先验 id 格式（也挡住 @..\\x@ 之类拼进 'planPath' 的路径穿越），装载
-- 后再过 'validatePlan' 并验文件内 id 与文件名一致。
loadPlan :: FilePath -> Text -> IO (Either String Plan)
loadPlan root pid
  | not (isValidPlanId pid) =
      pure (Left ("计划 id 不符合生成格式（" <> T.unpack pid <> "，应为 YYYYMMDD-HHMMSS-hex6），拒绝装载"))
  | otherwise = do
      let fp = planPath root pid
      exists <- doesFileExist fp
      if not exists
        then pure (Left ("计划不存在: " <> fp))
        else do
          r <- eitherDecodeFileStrict fp
          pure $ case r of
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
