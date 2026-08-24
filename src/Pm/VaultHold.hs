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
-- 也不要让一张已经不是当初那张的照片被旧决定永久压住。复核用的 sha 由调用方
-- 强制重算（不吃 (size,mtime) 缓存快路，codex 二十一轮 major）。
module Pm.VaultHold
  ( VaultHold (..)
  , holdsFileName
  , holdsTmpName
  , validateHolds
  , readHolds
  , writeHolds
  , applyHoldOps
  , splitHeld
  ) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Char (isHexDigit)
import Data.List (nub, sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import System.FilePath (takeFileName)

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

-- | @.pm@ 下的文件名（'readPmState' / 'writePmState' 的 rel）与覆盖写的中间名。
holdsFileName, holdsTmpName :: FilePath
holdsFileName = "vault-holds.json"
holdsTmpName = holdsFileName <> ".tmp"

-- | 名单的语义校验（二十一轮 minor）：名字必须是**平铺 basename**（不能带
-- 路径分隔符、不能是 @.@ \/ @..@），sha 必须是 64 位 hex，名字必须唯一——
-- 同名两条不同 sha 会让同一个名字既算 HELD 又算失效。任一条不合法整体拒绝，
-- 不做"跳过坏条目"式的宽容：那等于悄悄改写用户的决定。
validateHolds :: [VaultHold] -> Either String [VaultHold]
validateHolds hs
  | (b : _) <- badName = Left ("暂不同步名单里的 name 不是平铺文件名: " <> show b)
  | (b : _) <- badSha = Left ("暂不同步名单里的 sha 不是 64 位 hex: " <> show b)
  | (d : _) <- dups = Left ("暂不同步名单里同一名字出现多次: " <> d)
  | otherwise = Right (sortOn vhName hs)
 where
  names = map vhName hs
  badName = [n | n <- names, null n || n /= takeFileName n || n `elem` [".", ".."]]
  badSha = [vhSha h | h <- hs, T.length (vhSha h) /= 64 || not (T.all isHexDigit (vhSha h))]
  dups = [n | (n, k) <- counts, k > (1 :: Int)]
  counts = [(n, length (filter (== n) names)) | n <- nub (sort names)]

-- | 读名单。缺席 = 空名单；**解析失败、语义非法都是硬错**——把手编坏/半写的
-- 决定文件当成"没有决定"，等于把用户的决定悄悄丢掉。
--
-- 另一种"缺席"必须区分（二十一轮 minor）：覆盖写在删旧文件与 rename 之间
-- 崩溃，会留下 @vault-holds.json.tmp@ 而正文缺席。这时按空名单继续，等于
-- 整份决定静默清零 —— fail-closed 并给出恢复指引。
readHolds :: FilePath -> IO (Either String [VaultHold])
readHolds root = do
  r <- readPmState root holdsFileName
  case r of
    Left m -> pure (Left m)
    Right (Just bytes) -> pure $ case Aeson.eitherDecodeStrict' bytes of
      Left e ->
        Left
          ( root <> " 的 .pm/" <> holdsFileName <> " 无法解析（" <> e
              <> "）——拒绝按「无决定」处理；人工核查修复"
          )
      Right hs -> validateHolds hs
    Right Nothing -> do
      t <- readPmState root holdsTmpName
      pure $ case t of
        Left m -> Left m
        Right Nothing -> Right [] -- 真的没有决定
        Right (Just _) ->
          Left
            ( root <> " 的 .pm/" <> holdsFileName <> " 缺失，但残留 " <> holdsTmpName
                <> "（覆盖写中途崩溃）——拒绝按「无决定」处理：核对 .tmp 内容后改名回来，或确认清空后删掉它"
            )

-- | 写名单（覆盖写：完整路径解析 → 独占 tmp → flush → no-replace rename）。
-- 先过 'requireWritable'（I11 + 身份），与其它 @.pm@ 写入口同一道闸；调用方
-- 还须持主库 root lock（I10），见 'Pm.VaultCmd.withHoldsTxn'。
writeHolds :: FilePath -> [VaultHold] -> IO (Either String ())
writeHolds root hs = case validateHolds hs of
  Left m -> pure (Left ("拒绝写出非法名单: " <> m))
  Right ok -> do
    w <- requireWritable root
    case w of
      Left m -> pure (Left m)
      Right _ -> writePmState root holdsFileName (Aeson.encode ok)

-- | 施加一组增删：@adds@ 覆盖同名旧记录（sha 会刷新——显式重新标记一张已
-- 失效的照片正是这个语义），@dels@ 按名字删除。纯函数，便于单测。
applyHoldOps :: [VaultHold] -> [VaultHold] -> [FilePath] -> [VaultHold]
applyHoldOps olds adds dels =
  sortOn vhName (adds <> [o | o <- olds, vhName o `notElem` addNames, vhName o `notElem` dels])
 where
  addNames = map vhName adds

-- | 按**本轮强制重算**的「名字 → sha」把名单分成两份：
--
-- * 生效：名字在 NEW 里且 sha 与决定时相同；
-- * 失效：字节已变 / 本轮复核不稳 / 已不在 NEW（三种各有各的说明）。
--
-- @shaOf@ 只对"在 NEW 里"的名字有定义；返回 'Nothing' 表示本轮读不稳定。
splitHeld ::
  [VaultHold] ->
  [FilePath] ->
  (FilePath -> Maybe Text) ->
  ([(FilePath, Text)], [(FilePath, String)])
splitHeld hs newNames shaOf = (held, stale)
 where
  held = [(vhName h, vhSha h) | h <- hs, vhName h `elem` newNames, shaOf (vhName h) == Just (vhSha h)]
  heldNames = map fst held
  stale = [(vhName h, why h) | h <- hs, vhName h `notElem` heldNames]
  why h
    | vhName h `notElem` newNames =
        "已不在 NEW（可能已推送、已删除或改了名）→ pm vault unhold 清掉这条"
    | shaOf (vhName h) == Nothing =
        "本轮复核读取不稳定（文件正在变动）→ 暂按 NEW 处理，稍后重跑"
    | otherwise =
        "内容已变（不再是做决定时那张）→ 重新按 NEW 处理，需要就再标一次"
