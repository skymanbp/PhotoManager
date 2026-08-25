{-# LANGUAGE OverloadedStrings #-}

-- | 配置的**编辑层**（P4-8，用户裁定 2026-08-25："GUI 里可以设置各种目录路径"，
-- 范围＝vault / 备份盘 / photos.json / 并发数可改，**主库路径只读**）。
--
-- 主库路径是一切身份的锚点（root-id、journal、catalog 都挂在它下面），改它等于
-- 换一个库；一台机器设一次，留给 `pm init` 在终端做。其余四项是"把已知角色挂到
-- 某个路径"，可逆、可重设，放进 GUI 合适。
--
-- 校验器 'checkPatch' 与施加 'applyPatch' 是 CLI（`pm config set`）与
-- `POST /api/config` 的**唯一**判定处——与 vault push / hold 两条路径同一原则。
module Pm.ConfigEdit
  ( ConfigPatch (..)
  , emptyPatch
  , checkPatch
  , applyPatch
  , runConfigShow
  , runConfigSet
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import System.Directory (doesDirectoryExist, doesFileExist)

import qualified Data.Text as T
import Pm.Config (Config (..), configFilePath, writeConfig)

-- | 三态字段：'Nothing' = 本次不动；@Just Nothing@ = 清空；@Just (Just x)@ = 设成 x。
data ConfigPatch = ConfigPatch
  { cpVault :: Maybe (Maybe FilePath)
  , cpPhotosJson :: Maybe (Maybe FilePath)
  , cpWorkers :: Maybe (Maybe Int)
  , cpMain :: Maybe FilePath
    -- ^ 只为**拒绝**而存在：任何试图经编辑层改主库路径的请求都要报错，而不是
    -- 被静默忽略——静默忽略会让调用方以为改成功了。
  }
  deriving (Show, Eq)

emptyPatch :: ConfigPatch
emptyPatch = ConfigPatch Nothing Nothing Nothing Nothing

-- | 线格式：**键缺省** = 不动，**键为 null** = 清空，否则设值。三态必须分得
-- 开——否则"清空 vault 路径"和"不改 vault 路径"会撞成同一个请求。实例写在
-- 类型所在模块（避免孤儿实例）。
instance Aeson.FromJSON ConfigPatch where
  parseJSON = Aeson.withObject "config" $ \o -> do
    let fld k = case KM.lookup k o of
          Nothing -> pure Nothing
          Just Aeson.Null -> pure (Just Nothing)
          Just v -> Just . Just <$> Aeson.parseJSON v
    ConfigPatch <$> fld "vault" <*> fld "photosJson" <*> fld "workers" <*> o Aeson..:? "main"

-- | fail-closed：任一条不合法就整体不写，并一次返回全部错误（GUI 能一次标完）。
-- 路径存在性是 IO 判定：设一个不存在的 vault 目录只会让后续每条命令报错，不如
-- 当场拒绝。
checkPatch :: ConfigPatch -> IO [String]
checkPatch p = do
  ev <- case cpVault p of
    Just (Just v) -> do
      isDir <- doesDirectoryExist v
      pure [v <> " 不是一个已存在的目录（vault 展示集目录须先存在，pm 不替你建库）" | not isDir]
    _ -> pure []
  ej <- case cpPhotosJson p of
    Just (Just j) -> do
      isFile <- doesFileExist j
      pure [j <> " 不是一个已存在的文件（photos.json 只读引用检查用；不需要就留空）" | not isFile]
    _ -> pure []
  let ew = case cpWorkers p of
        Just (Just w) | w < 1 || w > 64 -> ["并发数 " <> show w <> " 越界（1..64）"]
        _ -> []
      em = ["主库路径只读：改它等于换一个库，请在终端 pm init --main <路径>" | Just _ <- [cpMain p]]
      en =
        [ "没有要改的项"
        | cpVault p == Nothing && cpPhotosJson p == Nothing && cpWorkers p == Nothing && cpMain p == Nothing
        ]
  pure (em <> en <> ev <> ej <> ew)

-- | 施加（纯函数）。调用方须先过 'checkPatch'。
applyPatch :: Config -> ConfigPatch -> Config
applyPatch c p =
  c
    { cfgVaultPath = maybe (cfgVaultPath c) id (cpVault p)
    , cfgPhotosJson = maybe (cfgPhotosJson c) id (cpPhotosJson p)
    , cfgWorkers = maybe (cfgWorkers c) id (cpWorkers p)
    }

-- ─── CLI 对称命令（`pm config` / `pm config set`） ──────────────────────────

-- | 打印当前配置与每条路径的健康状态（只读）。与 GUI 设置页同一份事实。
runConfigShow :: Config -> IO Int
runConfigShow c = do
  fp <- configFilePath
  putStrLn ("配置文件: " <> fp)
  mainEx <- doesDirectoryExist (cfgMainPath c)
  putStrLn ("  主库      " <> cfgMainPath c <> mark mainEx <> "（只读：改它等于换一个库，用 pm init）")
  case cfgVaultPath c of
    Nothing -> putStrLn "  vault     （未设）→ pm config set --vault <展示集目录>"
    Just v -> do
      ex <- doesDirectoryExist v
      putStrLn ("  vault     " <> v <> mark ex)
  case cfgPhotosJson c of
    Nothing -> putStrLn "  photos.json（未设，只影响 RENAME 的引用检查）"
    Just j -> do
      ex <- doesFileExist j
      putStrLn ("  photos.json " <> j <> mark ex)
  putStrLn ("  并发数    " <> maybe "（默认=核数）" show (cfgWorkers c))
  case (cfgBackupId c, cfgBackupSubpath c) of
    (Just i, Just s) -> putStrLn ("  备份盘    UUID " <> T.unpack i <> " · 盘内路径 " <> s <> "（按 UUID 认盘，与盘符无关）")
    _ -> putStrLn "  备份盘    （未登记）→ pm backup init <盘上镜像路径>"
  pure 0
 where
  mark True = ""
  mark False = "  ⚠ 路径不存在"

-- | 改配置：与 @POST /api/config@ 共用 'checkPatch' / 'applyPatch'。
runConfigSet :: ConfigPatch -> Config -> IO Int
runConfigSet p c = do
  errs <- checkPatch p
  if not (null errs)
    then mapM_ (putStrLn . ("  ✗ " <>)) errs >> pure 2
    else do
      fp <- writeConfig (applyPatch c p)
      putStrLn ("✓ 已写入 " <> fp)
      runConfigShow (applyPatch c p)
