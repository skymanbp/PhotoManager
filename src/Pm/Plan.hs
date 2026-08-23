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
  ) where

import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
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
  }
  deriving (Show, Eq)

instance ToJSON PlanItem where
  toJSON p = object ["ix" .= piIx p, "op" .= piOp p, "status" .= piStatus p]

instance FromJSON PlanItem where
  parseJSON = withObject "PlanItem" $ \o ->
    PlanItem <$> o .: "ix" <*> o .: "op" <*> o .: "status"

data Plan = Plan
  { plId :: Text
  , plKind :: Text
  , plRootPath :: FilePath
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
      , "created" .= plCreated p
      , "items" .= plItems p
      ]

instance FromJSON Plan where
  parseJSON = withObject "Plan" $ \o ->
    Plan <$> o .: "id" <*> o .: "kind" <*> o .: "root" <*> o .: "created" <*> o .: "items"

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
    : [ printf "  %3d | %-9s | %s" (piIx it) (statusTag (piStatus it)) (describeOp (piOp it))
      | it <- plItems p
      ]
 where
  statusTag StPending = "PENDING" :: String
  statusTag StSkippedByUser = "SKIPPED"
  statusTag (StNeedsDecision _) = "DECIDE"
