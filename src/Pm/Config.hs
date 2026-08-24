{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

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
  , RootIdState (..)
  , readRootState
  , readRootInfo
  , requireRole
  , requireMain
  , requireWritable
  , createRootInfo
  , writeRootInfo
  , freshRootId
  , pmDir
  , pmSubTrash
  , pmSubTmp
  , pmSubPlans
  , requirePmTrusted
  , readJsonMaybe
  , writeSideCache
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (when)
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
  , removeFile
  )
import System.FilePath ((</>))
import System.IO (hClose)
import Text.Printf (printf)
import qualified TOML

import Pm.GitGuard (pmIgnoreGuard)
import Pm.Types
import Pm.Win (flushHandleToDisk, moveFileNoReplace, openFreshBinary, resolveUnder)

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

-- | @.pm@ 下的固定子目录名——单一真源：'Pm.Trash.trashDir'、
-- 'Pm.Exec.tmpDirFor'、'Pm.Plan.plansDir' 都引用这里，'requirePmTrusted'
-- 才能保证「校验过的那几条路径」与「实际写入的那几条路径」不会漂移。
pmSubTrash, pmSubTmp, pmSubPlans :: FilePath
pmSubTrash = "trash"
pmSubTmp = "tmp"
pmSubPlans = "plans"

-- | @.pm@ 家族的可信性闸（P3b-11，八轮复审 critical）：从 root 起逐级下降，
-- @.pm@ 及其固定子目录都必须是盘上的**真名**，不得是 junction\/symlink。
--
-- 探针实证：把 @.pm\/trash@ 本身做成指向库外的 junction 后，落位\/删除侧的
-- canonical 限域（'Pm.Win.pathUnder'）两侧都解析到库外、判定通过，@removeFile@
-- 删掉了库外文件；@.pm@ 自身被劫持时 journal\/plan\/manifest\/catalog\/root-id
-- 会**整套**写到库外。这些入口没有共同的路径参数可校验，但它们有共同的前提
-- ——'requireWritable'。闸放在这里，一次判定覆盖全部 @.pm@ 写入口。
--
-- 尚不存在的子目录放行（新库的 trash\/tmp\/plans 由 pm 自己创建；
-- 'Pm.Win.resolveUnder' 对不存在的分量返回拼接路径）。
requirePmTrusted :: FilePath -> IO (Either String ())
requirePmTrusted root = go [".pm", ".pm" </> pmSubTrash, ".pm" </> pmSubTmp, ".pm" </> pmSubPlans]
 where
  go [] = pure (Right ())
  go (rel : rest) = do
    m <- resolveUnder root rel
    case m of
      Nothing ->
        pure
          ( Left
              ( root </> rel
                  <> " 不是 root 下的真实目录（junction\\/symlink\\/别名？）——pm 拒绝以它为基准读写。"
                  <> "人工核查该路径；正常库里 .pm 及其子目录必须是普通目录"
              )
          )
      Just _ -> go rest

rootInfoPath :: FilePath -> FilePath
rootInfoPath root = pmDir root </> "root-id.json"

-- | doesFileExist + decode → Maybe 的共用读取（备份缓存 \/ vault 缓存等可重建
-- 侧缓存共用；损坏文件按缺席处理，各调用点自行决定后续语义）。
readJsonMaybe :: Aeson.FromJSON a => FilePath -> IO (Maybe a)
readJsonMaybe fp = do
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else either (const Nothing) Just <$> eitherDecodeFileStrict fp

-- | root 标识的三态（P3b-7 复审 major）：缺席与**损坏**必须区分——损坏（半写\/
-- 手编坏 JSON）若按缺席处理，init\/backup init\/vault push 会用新 UUID 与新
-- role 覆盖它，等于把一块备份盘的身份改写成主库。
-- P3b-12（九轮复审 major）：加第四态 'RootUntrusted'。`pm init` /
-- `pm backup init` / 首次 `pm vault push` 建立身份时**还没有身份**，因此天然
-- 走不了 'requireWritable' —— 九轮据此指出它们能在 `.pm` 是 junction 时到库外
-- 读写 root-id.json。身份读取的唯一入口是 'readRootState'，把可信闸放进它，
-- 这些 init 旁路连同 status / versions / 备份发现等只读入口一并覆盖。
data RootIdState = RootAbsent | RootCorrupt String | RootUntrusted String | RootPresent RootInfo
  deriving (Show, Eq)

readRootState :: FilePath -> IO RootIdState
readRootState root = do
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure (RootUntrusted m)
    Right () -> do
      let fp = rootInfoPath root
      exists <- doesFileExist fp
      if not exists
        then pure RootAbsent
        else either RootCorrupt RootPresent <$> eitherDecodeFileStrict fp

-- | 只读视图：Present → Just；缺席、损坏与**不可信**都是 Nothing（读者一律按
-- 「无身份」fail-closed；要改写标识的入口必须用 'readRootState' 分辨这几态）。
readRootInfo :: FilePath -> IO (Maybe RootInfo)
readRootInfo root = do
  st <- readRootState root
  pure $ case st of
    RootPresent i -> Just i
    _ -> Nothing

-- | 可写 root 的统一前提（P3b-7 复审新 major）：标识存在且可解析，**并且**
-- 按盘上 role 通过 I11 守卫。所有直接写 @.pm\/@ 的入口（计划保存、catalog\/
-- 侧缓存写入、doctor --repair、trash empty、undo\/resolve）在写之前都走这里；
-- Exec 在取锁前与锁内另有同规则复检。
-- P3b-12：可信闸已下沉到 'readRootState'（它是身份读取的唯一入口，init 旁路
-- 也走它），这里只需分派它的四态。
requireWritable :: FilePath -> IO (Either String RootInfo)
requireWritable root = do
  st <- readRootState root
  case st of
    RootUntrusted m -> pure (Left m)
    RootAbsent ->
      pure (Left (root <> " 缺 .pm/root-id.json → 先 pm init --main <主库>（备份盘用 pm backup init）"))
    RootCorrupt e ->
      pure
        ( Left
            ( root <> " 的 .pm/root-id.json 存在但无法解析（" <> e
                <> "），拒绝以任何身份读写——人工核查修复；pm 不改写它"
            )
        )
    RootPresent info -> do
      g <- pmIgnoreGuard (riRole info) root
      pure (either Left (const (Right info)) g)

-- | 'requireWritable' + role 校验（P3b-5 复审 B1）：配置里的主库路径若指向
-- 备份\/vault root，任何以「主库」身份生成的计划（import\/clean\/names\/scan）
-- 都会改错库。缺身份、损坏、role 不符、I11 不过都是 Left，调用点一律
-- fail-closed。
requireRole :: RootRole -> FilePath -> IO (Either String RootInfo)
requireRole role root = do
  r <- requireWritable root
  pure $ case r of
    Right info
      | riRole info /= role ->
          Left (root <> " 是 " <> show (riRole info) <> " root，不是 " <> show role <> "，拒绝以该身份操作（检查配置路径）")
    other -> other

-- | 配置的主库路径必须是 RoleMain root（P3b-5 复审 B1；P3b-7 扩到 clean 见证\/
-- 备份缓存刷新\/init）。
requireMain :: Config -> IO (Either String RootInfo)
requireMain = requireRole RoleMain . cfgMainPath

-- | 首次建立 root 标识：**原子 no-replace**（写 tmp → 'moveFileNoReplace'；
-- 目标已存在——并发创建、或 'readRootState' 之后有人放了文件——即拒绝，
-- 绝不覆盖）。P3b-7 复审 major：此前覆盖写让损坏\/竞态 marker 可被改写身份。
createRootInfo :: FilePath -> RootInfo -> IO (Either String ())
createRootInfo root info = do
  -- P3b-12（九轮复审 major）：纵深防御。三条建身份旁路已在 'readRootState'
  -- 处被 'RootUntrusted' 拦下，但这个函数是公开 API，自身也必须问一次——
  -- 否则 .pm 是 junction 时它会把标识原子地建到**库外**（测试实测过）。
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure (Left m)
    Right () -> createRootInfo' root info

createRootInfo' :: FilePath -> RootInfo -> IO (Either String ())
createRootInfo' root info = do
  createDirectoryIfMissing True (pmDir root)
  bytes <- getRandomBytes 4
  let final = rootInfoPath root
      tmp = final <> "." <> concatMap (printf "%02x") (BS.unpack bytes) <> ".tmp"
  -- 独占创建（P3b-11，八轮复审 major）：pm 自建 tmp 一律不覆盖既有名字，
  -- 预置的 hardlink 会被 CREATE_NEW 拒绝而不是被写穿到库外。
  bracket (openFreshBinary tmp) hClose $ \h -> do
    BSL.hPut h (Aeson.encode info)
    flushHandleToDisk h
  r <- try (moveFileNoReplace tmp final) :: IO (Either IOException ())
  case r of
    Right () -> pure (Right ())
    Left e -> do
      -- §6.1 脚注：pm 自建、从未落位的 tmp 是唯一允许 unlink 的东西
      removeFile tmp
      pure (Left (final <> " 已存在或不可创建（不覆盖既有身份）: " <> show e))

-- | 覆盖写标识——仅供测试 fixture 与显式重写场景；生产建 root 一律走
-- 'createRootInfo'。
writeRootInfo :: FilePath -> RootInfo -> IO ()
writeRootInfo root info = do
  createDirectoryIfMissing True (pmDir root)
  BSL.writeFile (rootInfoPath root) (Aeson.encode info)

-- | 侧缓存目录的成对覆盖写（catalog.json + meta.json）。备份盘缓存与
-- vault 缓存共用：都是可重建的展示\/加速缓存，纯覆盖写即可——耐久层在
-- 别处（备份盘自己的 .pm、照片文件本身）。
-- P3b-12（九轮复审 major）：覆盖写同样能被 hardlink 引到库外。侧缓存是可重建
-- 的，但"可重建"不等于"可以写到别人的文件上"——与 'Pm.Plan.savePlan' 同款：
-- 独占创建 tmp → 删旧 → no-replace 落位。
writeSideCache :: Aeson.ToJSON meta => FilePath -> Catalog -> meta -> IO ()
writeSideCache dir cat meta = do
  createDirectoryIfMissing True dir
  writeJsonReplacing (dir </> "catalog.json") (Aeson.encode cat)
  writeJsonReplacing (dir </> "meta.json") (Aeson.encode meta)

writeJsonReplacing :: FilePath -> BSL.ByteString -> IO ()
writeJsonReplacing fp bytes = do
  let tmp = fp <> ".tmp"
  bracket (openFreshBinary tmp) hClose $ \h -> do
    BSL.hPut h bytes
    flushHandleToDisk h
  old <- doesFileExist fp
  when old (removeFile fp)
  moveFileNoReplace tmp fp

freshRootId :: IO Text
freshRootId = do
  bytes <- getRandomBytes 16
  pure (T.pack (concatMap (printf "%02x") (BS.unpack bytes)))
