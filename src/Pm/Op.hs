{-# LANGUAGE OverloadedStrings #-}

-- | The operation algebra (DESIGN.md §3). Deliberately closed: there is no
-- delete constructor and no overwrite constructor — every landing goes
-- through a fail-if-exists rename, and the only way bytes leave a library is
-- 'OpQuarantine' into the manifest-tracked trash (invariant I2).
module Pm.Op
  ( Op (..)
  , Fingerprint (..)
  , opId
  , OpIdSuffix (..)
  , opIdParts
  , restoreOpId
  , displacedOpId
  , describeOp
  ) where

import Control.Monad (guard)
import Data.Aeson
import Data.Char (isDigit)
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

-- | opId 后缀 = 内核内部事务约定（P3b-6 复审 A1 统一解析）：无后缀是用户可见
-- 操作；@~r@ 是 §6.5 组回滚的自动复位 rename；@~d\<N\>@ 是组回滚时占位者的
-- 第 N 次位移隔离（落 @\<pid\>~displaced-\<N\>\/@）。其它形态都不是 pm 生成的。
data OpIdSuffix = SfxPlain | SfxRestore | SfxDisplaced Int
  deriving (Show, Eq)

-- | 严格解析 @\<planId\>#\<ix\>[~r|~d\<N\>]@ → (planId, ix, 后缀)。planId 部分
-- 不得含 @#@\/@~@（生成格式 YYYYMMDD-HHMMSS-hex6 由 'Pm.Plan.isValidPlanId'
-- 在装载与执行处另行把关）；ix 与 N 为十进制，N ≥ 1。此前 Trash 用
-- @splitOn "~d"@、Undo 用 @isInfixOf "~d"@ 各自弱解析：planId 含 @~d@ 时前者
-- 把普通隔离推到位移目录、后者把正常操作当内部事务剔出 undo。
opIdParts :: Text -> Maybe (Text, Int, OpIdSuffix)
opIdParts oid = do
  let (pid, rest) = T.breakOn "#" oid
  guard (not (T.null pid) && T.all (\c -> c /= '#' && c /= '~') pid)
  rest' <- T.stripPrefix "#" rest
  let (ixT, sfx) = T.span isDigit rest'
  ix <- readDigits ixT
  s <- case sfx of
    "" -> Just SfxPlain
    "~r" -> Just SfxRestore
    _
      | Just nT <- T.stripPrefix "~d" sfx
      , Just n <- readDigits nT
      , n >= 1 ->
          Just (SfxDisplaced n)
    _ -> Nothing
  pure (pid, ix, s)
 where
  -- 规范十进制：无前导零、无符号（P3b-7 复审 A1："p#00"、"p#0~d01" 不是 pm
  -- 生成的，接受它们会让手编 "p#00~r" 抵消真实的 "p#0" Done）。
  readDigits t
    | T.null t || not (T.all isDigit t) = Nothing
    | otherwise =
        let n = read (T.unpack t) :: Int
         in if T.pack (show n) == t then Just n else Nothing

-- | 复位 rename 的 opId（§6.5）。
restoreOpId :: Text -> Int -> Text
restoreOpId pid ix = opId pid ix <> "~r"

-- | 第 N 次位移隔离的 opId。
displacedOpId :: Text -> Int -> Int -> Text
displacedOpId pid ix n = opId pid ix <> "~d" <> T.pack (show n)

describeOp :: Op -> String
describeOp (OpCopy s d _ sz _) = "copy " <> s <> " -> " <> d <> " (" <> show sz <> " B)"
describeOp (OpRename o n _) = "rename " <> o <> " -> " <> n
describeOp (OpQuarantine v _ r) = "quarantine " <> v <> " (" <> T.unpack r <> ")"
