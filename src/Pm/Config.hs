{-# LANGUAGE OverloadedStrings #-}

-- | User configuration (TOML, hand-editable) and per-root identity markers.
-- Config lives under the roaming profile (derived at runtime, never
-- hard-coded); root markers live in @\<root\>\/.pm\/root-id.json@ so roots are
-- recognized by UUID, not by drive letter (DESIGN.md §9).
module Pm.Config
  ( Config (..)
  , configFilePath
  , loadConfig
  , writeConfig
  , renderConfig
  , readRootInfo
  , requireRole
  , requireMain
  , writeRootInfo
  , freshRootId
  , pmDir
  , readJsonMaybe
  , writeSideCache
  ) where

import Crypto.Random (getRandomBytes)
import Data.Aeson (eitherDecodeFileStrict)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory
  ( XdgDirectory (XdgConfig)
  , createDirectoryIfMissing
  , doesFileExist
  , getXdgDirectory
  )
import System.FilePath ((</>))
import Text.Printf (printf)
import qualified TOML

import Pm.Types

data Config = Config
  { cfgMainPath :: FilePath
  , cfgVaultPath :: Maybe FilePath
  , cfgPhotosJson :: Maybe FilePath
  , cfgWorkers :: Maybe Int
  , cfgBackupId :: Maybe Text
    -- ^ 备份 root 的 UUID（`pm backup init` 登记；发现流程按 UUID 认盘，§9）
  , cfgBackupSubpath :: Maybe FilePath
    -- ^ 备份镜像相对盘根的位置（如 "Photography"）；盘符不入配置
  }
  deriving (Show, Eq)

instance TOML.DecodeTOML Config where
  tomlDecoder =
    Config
      <$> TOML.getFields ["main", "path"]
      <*> TOML.getFieldsOpt ["vault", "path"]
      <*> TOML.getFieldsOpt ["portfolio", "photos-json"]
      <*> TOML.getFieldsOpt ["main", "workers"]
      <*> TOML.getFieldsOpt ["backup", "id"]
      <*> TOML.getFieldsOpt ["backup", "subpath"]

configFilePath :: IO FilePath
configFilePath = do
  dir <- getXdgDirectory XdgConfig "pm"
  pure (dir </> "config.toml")

loadConfig :: IO (Either String Config)
loadConfig = do
  fp <- configFilePath
  exists <- doesFileExist fp
  if not exists
    then pure (Left ("配置不存在: " <> fp <> " —— 先运行 pm init --main <主库路径>"))
    else do
      raw <- BS.readFile fp
      case TE.decodeUtf8' raw of
        Left e -> pure (Left ("配置不是 UTF-8: " <> show e))
        Right txt -> case TOML.decode txt of
          Left e -> pure (Left (T.unpack (TOML.renderTOMLError e)))
          Right c -> pure (Right c)

-- | TOML literal strings (single quotes) keep Windows backslashes verbatim.
renderConfig :: Config -> Text
renderConfig c =
  T.unlines $
    [ "# pm 配置 —— 手动编辑后无需任何重载步骤"
    , "[main]"
    , "path = '" <> T.pack (cfgMainPath c) <> "'"
    ]
      <> maybe [] (\w -> ["workers = " <> T.pack (show w)]) (cfgWorkers c)
      <> ( case (cfgBackupId c, cfgBackupSubpath c) of
            (Just bid, Just sub) ->
              ["", "[backup]", "id = '" <> bid <> "'", "subpath = '" <> T.pack sub <> "'"]
            _ -> []
         )
      <> maybe [] (\p -> ["", "[vault]", "path = '" <> T.pack p <> "'"]) (cfgVaultPath c)
      <> maybe
        []
        (\p -> ["", "[portfolio]", "photos-json = '" <> T.pack p <> "'"])
        (cfgPhotosJson c)

writeConfig :: Config -> IO FilePath
writeConfig c = do
  fp <- configFilePath
  dir <- getXdgDirectory XdgConfig "pm"
  createDirectoryIfMissing True dir
  BS.writeFile fp (TE.encodeUtf8 (renderConfig c))
  pure fp

pmDir :: FilePath -> FilePath
pmDir root = root </> ".pm"

rootInfoPath :: FilePath -> FilePath
rootInfoPath root = pmDir root </> "root-id.json"

-- | doesFileExist + decode → Maybe 的共用读取（root-id \/ 备份缓存 \/
-- vault 缓存共用；损坏文件按缺席处理，各调用点自行决定后续语义）。
readJsonMaybe :: Aeson.FromJSON a => FilePath -> IO (Maybe a)
readJsonMaybe fp = do
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else either (const Nothing) Just <$> eitherDecodeFileStrict fp

readRootInfo :: FilePath -> IO (Maybe RootInfo)
readRootInfo = readJsonMaybe . rootInfoPath

-- | 读 root 身份并校验 role（P3b-5 复审 B1）：配置里的主库路径若指向备份\/
-- vault root，任何以「主库」身份生成的计划（import\/clean\/names\/scan）都会
-- 改错库。缺身份与 role 不符都是 Left（附下一步指引），调用点一律 fail-closed。
requireRole :: RootRole -> FilePath -> IO (Either String RootInfo)
requireRole role root = do
  minfo <- readRootInfo root
  pure $ case minfo of
    Nothing -> Left (root <> " 缺 .pm/root-id.json → 先 pm init --main <主库>（备份盘用 pm backup init）")
    Just info
      | riRole info == role -> Right info
      | otherwise ->
          Left (root <> " 是 " <> show (riRole info) <> " root，不是 " <> show role <> "，拒绝以该身份操作（检查配置路径）")

-- | 配置的主库路径必须是 RoleMain root（P3b-6 复审 B1：scan\/import\/clean\/
-- names 之外，vault 比对源、备份源、doctor\/trash\/undo 的默认 root、
-- @init --force@ 同样以「主库」身份读写该路径，全部收口到此）。
requireMain :: Config -> IO (Either String RootInfo)
requireMain = requireRole RoleMain . cfgMainPath

-- | 侧缓存目录的成对覆盖写（catalog.json + meta.json）。备份盘缓存与
-- vault 缓存共用：都是可重建的展示\/加速缓存，纯覆盖写即可——耐久层在
-- 别处（备份盘自己的 .pm、照片文件本身）。
writeSideCache :: Aeson.ToJSON meta => FilePath -> Catalog -> meta -> IO ()
writeSideCache dir cat meta = do
  createDirectoryIfMissing True dir
  BSL.writeFile (dir </> "catalog.json") (Aeson.encode cat)
  BSL.writeFile (dir </> "meta.json") (Aeson.encode meta)

writeRootInfo :: FilePath -> RootInfo -> IO ()
writeRootInfo root info = do
  createDirectoryIfMissing True (pmDir root)
  BSL.writeFile (rootInfoPath root) (Aeson.encode info)

freshRootId :: IO Text
freshRootId = do
  bytes <- getRandomBytes 16
  pure (T.pack (concatMap (printf "%02x") (BS.unpack bytes)))
