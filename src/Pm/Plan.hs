{-# LANGUAGE OverloadedStrings #-}

-- | Plans are pure data (DESIGN.md §3): printable, diffable, persisted under
-- @\<root\>\/.pm\/plans\/\<id\>.json@ of the root they mutate. Exec consumes
-- nothing else.
module Pm.Plan
  ( Plan (..)
  , PlanItem (..)
  , ItemStatus (..)
  , newPlanId
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

import Pm.Config (pmDir)
import Pm.Op

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

plansDir :: FilePath -> FilePath
plansDir root = pmDir root </> "plans"

planPath :: FilePath -> Text -> FilePath
planPath root pid = plansDir root </> (T.unpack pid <> ".json")

savePlan :: Plan -> IO FilePath
savePlan p = do
  let root = plRootPath p
      fp = planPath root (plId p)
  createDirectoryIfMissing True (plansDir root)
  BSL.writeFile fp (encode p)
  pure fp

loadPlan :: FilePath -> Text -> IO (Either String Plan)
loadPlan root pid = do
  let fp = planPath root pid
  exists <- doesFileExist fp
  if not exists
    then pure (Left ("计划不存在: " <> fp))
    else eitherDecodeFileStrict fp

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
