{-# LANGUAGE OverloadedStrings #-}

-- | vault 的「暂不同步」名单（P4-7，用户 2026-08-24 裁定："这 15 张暂时先不
-- 同步。然后给一个分类，专门放决定不同步的照片，后续如果想同步了可以调整"）。
--
-- **它不是 vault 里的第四个类目**：vault 的类目就是展示集 git 仓里的目录，
-- 建目录等于把照片发出去——恰好与"不同步"相反。因此这是一条**主库侧的本地
-- 决定**，存在主库 `.pm/vault-holds.json`，vault 仓零改动。
--
-- 记录里同时存决定当时的 sha：照片字节后来被换过（重修图、重导出）时，这条
-- 决定就**失效**（stale），照片重新回到 NEW 让用户再看一眼——宁可多问一次，
-- 也不要让一张已经不是当初那张的照片被旧决定永久压住。
module Pm.VaultHold
  ( VaultHold (..)
  , holdsFileName
  , readHolds
  , writeHolds
  , applyHoldOps
  , splitHeld
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.List (sortOn)
import Data.Text (Text)
import Data.Time (UTCTime)

import Pm.Config (readPmState, requireWritable, writePmState)

-- | 一条决定：名字（相册里的平铺 basename，与六态分类同键）+ 决定当时的 sha。
data VaultHold = VaultHold
  { vhName :: FilePath
  , vhSha :: Text
  , vhAt :: UTCTime
  , vhNote :: Maybe Text
  }
  deriving (Show, Eq)

instance ToJSON VaultHold where
  toJSON h = object ["name" .= vhName h, "sha" .= vhSha h, "at" .= vhAt h, "note" .= vhNote h]

instance FromJSON VaultHold where
  parseJSON = withObject "VaultHold" $ \o ->
    VaultHold <$> o .: "name" <*> o .: "sha" <*> o .: "at" <*> o .:? "note"

-- | @.pm@ 下的文件名（`readPmState` / `writePmState` 的 rel）。
holdsFileName :: FilePath
holdsFileName = "vault-holds.json"

-- | 读名单。缺席 = 空名单；**解析失败是硬错**——把手编坏/半写的决定文件当成
-- "没有决定"，等于把用户的决定悄悄丢掉。
readHolds :: FilePath -> IO (Either String [VaultHold])
readHolds root = do
  r <- readPmState root holdsFileName
  pure $ case r of
    Left m -> Left m
    Right Nothing -> Right []
    Right (Just bytes) -> case Aeson.eitherDecodeStrict' bytes of
      Left e ->
        Left
          ( root <> " 的 .pm/" <> holdsFileName <> " 无法解析（" <> e
              <> "）——拒绝按「无决定」处理；人工核查修复"
          )
      Right hs -> Right (sortOn vhName hs)

-- | 写名单（覆盖写：完整路径解析 → 独占 tmp → flush → no-replace rename）。
-- 先过 'requireWritable'（I11 + 身份），与其它 @.pm@ 写入口同一道闸。
writeHolds :: FilePath -> [VaultHold] -> IO (Either String ())
writeHolds root hs = do
  w <- requireWritable root
  case w of
    Left m -> pure (Left m)
    Right _ -> writePmState root holdsFileName (Aeson.encode (sortOn vhName hs))

-- | 施加一组增删：@adds@ 覆盖同名旧记录（sha 会刷新），@dels@ 按名字删除。
-- 纯函数，便于单测。
applyHoldOps :: [VaultHold] -> [VaultHold] -> [FilePath] -> [VaultHold]
applyHoldOps olds adds dels =
  sortOn vhName (adds <> [o | o <- olds, vhName o `notElem` addNames, vhName o `notElem` dels])
 where
  addNames = map vhName adds

-- | 按当前的「名字 → sha」把名单分成三份：
--
-- * 生效（名字在 NEW 里且 sha 与决定时相同）→ 从 NEW 里移出去；
-- * 失效-内容已变（名字在 NEW 里但 sha 变了）→ **留在 NEW**，并报告；
-- * 失效-不在 NEW（已推送 / 已删除 / 改了名）→ 报告，可 unhold 清掉。
splitHeld ::
  [VaultHold] ->
  [FilePath] ->
  (FilePath -> Maybe Text) ->
  ([(FilePath, Text)], [(FilePath, String)])
splitHeld hs newNames shaOf = (held, stale)
 where
  held = [(vhName h, vhSha h) | h <- hs, vhName h `elem` newNames, shaOf (vhName h) == Just (vhSha h)]
  stale =
    [ (vhName h, why)
    | h <- hs
    , (vhName h, vhSha h) `notElem` held
    , let why =
            if vhName h `elem` newNames
              then "内容已变（不再是做决定时那张）→ 重新按 NEW 处理，需要就再标一次"
              else "已不在 NEW（可能已推送、已删除或改了名）→ pm vault unhold 清掉这条"
    ]
