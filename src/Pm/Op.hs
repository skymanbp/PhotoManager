{-# LANGUAGE OverloadedStrings #-}

-- | The operation algebra (DESIGN.md §3). Deliberately closed: there is no
-- delete constructor and no overwrite constructor — every landing goes
-- through a fail-if-exists rename, and the only way bytes leave a library is
-- 'OpQuarantine' into the manifest-tracked trash (invariant I2).
module Pm.Op
  ( Op (..)
  , Fingerprint (..)
  , opId
  , describeOp
  ) where

import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T

data Fingerprint
  = FpFileSha Text
  | -- | sha256 over the sorted @name\\tsize@ lines of the direct children —
    -- filesystem-agnostic (backup drive may be exFAT, no FILE_ID_128).
    FpDir Text
  deriving (Show, Eq)

instance ToJSON Fingerprint where
  toJSON (FpFileSha s) = object ["file" .= s]
  toJSON (FpDir s) = object ["dir" .= s]

instance FromJSON Fingerprint where
  parseJSON = withObject "Fingerprint" $ \o -> do
    mf <- o .:? "file"
    md <- o .:? "dir"
    case (mf, md) of
      (Just s, _) -> pure (FpFileSha s)
      (_, Just s) -> pure (FpDir s)
      _ -> fail "fingerprint needs 'file' or 'dir'"

data Op
  = -- | Copy one file into the mutated root. @src@ is absolute (it may live
    -- in another root); @dst@ is relative to the mutated root. size/mtime
    -- are the plan-time precondition on the source (§6.7 并发防护).
    OpCopy
      { opSrcAbs :: FilePath
      , opDstRel :: FilePath
      , opSha :: Text
      , opSrcSize :: Integer
      , opSrcMtimeNs :: Integer
      }
  | OpRename
      { opOldRel :: FilePath
      , opNewRel :: FilePath
      , opFp :: Fingerprint
      }
  | OpQuarantine
      { opVictimRel :: FilePath
      , opVictimSha :: Text
      , opReason :: Text
      }
  deriving (Show, Eq)

instance ToJSON Op where
  toJSON op = case op of
    OpCopy s d h sz mt ->
      object ["t" .= ("copy" :: Text), "src" .= s, "dst" .= d, "sha256" .= h, "size" .= sz, "mtimeNs" .= mt]
    OpRename o n fp ->
      object ["t" .= ("rename" :: Text), "old" .= o, "new" .= n, "fp" .= fp]
    OpQuarantine v h r ->
      object ["t" .= ("quarantine" :: Text), "victim" .= v, "sha256" .= h, "reason" .= r]

instance FromJSON Op where
  parseJSON = withObject "Op" $ \o -> do
    t <- o .: "t"
    case (t :: Text) of
      "copy" ->
        OpCopy <$> o .: "src" <*> o .: "dst" <*> o .: "sha256" <*> o .: "size" <*> o .: "mtimeNs"
      "rename" -> OpRename <$> o .: "old" <*> o .: "new" <*> o .: "fp"
      "quarantine" -> OpQuarantine <$> o .: "victim" <*> o .: "sha256" <*> o .: "reason"
      _ -> fail ("unknown op type: " <> show t)

-- | Stable id of item @ix@ inside plan @pid@.
opId :: Text -> Int -> Text
opId pid ix = pid <> "#" <> T.pack (show ix)

describeOp :: Op -> String
describeOp (OpCopy s d _ sz _) = "copy " <> s <> " -> " <> d <> " (" <> show sz <> " B)"
describeOp (OpRename o n _) = "rename " <> o <> " -> " <> n
describeOp (OpQuarantine v _ r) = "quarantine " <> v <> " (" <> T.unpack r <> ")"
