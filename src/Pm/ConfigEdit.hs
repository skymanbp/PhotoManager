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
  , checkConfig
  , rootsNested
  , applyPatch
  , configTxn
  , runConfigShow
  , runConfigSet
  , ConfigSetOpts (..)
  , tri
  , mkPatch
  ) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Char (toLower)
import Data.List (intercalate, isPrefixOf)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)
import System.FilePath (normalise, splitDirectories)

import qualified Data.Text as T
import Pm.Backup (discoverBackupRoots)
import Pm.Config (Config (..), checkAbsolute, configFilePath, loadConfig, withConfigLock, writeConfig)
import Pm.Publish (cmdPath, pushTarget)

-- | 两个 root 是否嵌套（任一方向）：canonicalize 两侧（解析已存在前缀的
-- junction/symlink 与真实大小写），再按 case-fold 分量做祖先判断——文本级
-- normalise 挡不住主库的别名路径（评审 mj-4 的既有判据，工作流 C101 上提为
-- 唯一定义：此前是 'Pm.BackupCmd.backupInitPreflight' 的私有 where，只守
-- 备份槽对主库；vault 对主库、备份对 vault 都没人守）。
rootsNested :: FilePath -> FilePath -> IO Bool
rootsNested a b = do
  ca <- canonicalizePath a
  cb <- canonicalizePath b
  let comps p = map (map toLower) (splitDirectories (normalise p))
  pure (comps ca `isPrefixOf` comps cb || comps cb `isPrefixOf` comps ca)

-- | 整份 'Config' 的汇点校验（工作流 C101/F011）：四条写路径（init / config
-- set / POST config / backup init）此前各查各的字段，跨字段不变量无归宿——
-- vault 落在 Raw\成片\相册 之下时 scan 把展示集索引进主库、dedupe 把每张
-- 已推送照片报成精确重复。查：路径绝对（'checkAbsolute'）、主库与 vault
-- 不嵌套、备份登记成对（id 与 subpath 同有同无）。
checkConfig :: Config -> IO [String]
checkConfig c = do
  nested <- case cfgVaultPath c of
    Nothing -> pure []
    Just v -> do
      n <- rootsNested (cfgMainPath c) v
      pure ["vault 与主库嵌套（" <> v <> " vs " <> cfgMainPath c <> "）——展示集必须在库外，否则 scan 把它索引进主库、dedupe 把每张已推送照片报成重复" | n]
  -- 41 轮 #1（对称向）：备份盘按 UUID+盘内相对路径登记，绝对路径要现场发现
  -- （'discoverBackupRoots'）。盘在场 → 每个命中与主库/vault 各判一次嵌套；
  -- 盘不在场 → 无从核（登记时点已在锁内验过，见 'Pm.BackupCmd'；这一半的
  -- 残余登记见 REVIEW-LOG 41 轮）。
  bkNested <- case (cfgBackupId c, cfgBackupSubpath c) of
    (Just _, Just _) -> do
      er <- discoverBackupRoots c
      case er of
        Right (_, bs) -> concat <$> mapM bkOne bs
        Left _ -> pure []
    _ -> pure []
  let absErr = either (: []) (const []) (checkAbsolute c)
      pairErr = case (cfgBackupId c, cfgBackupSubpath c) of
        (Just _, Nothing) -> ["备份盘登记不完整（只有 id、缺 subpath）—— 重跑 pm backup init <盘上镜像路径>"]
        (Nothing, Just _) -> ["备份盘登记不完整（只有 subpath、缺 id）—— 重跑 pm backup init <盘上镜像路径>"]
        _ -> []
  pure (absErr <> nested <> pairErr <> bkNested)
 where
  bkOne b = do
    nm <- rootsNested (cfgMainPath c) b
    nv <- maybe (pure False) (\v -> rootsNested v b) (cfgVaultPath c)
    pure
      (["备份盘与主库嵌套（" <> b <> "）——镜像必须在库外" | nm]
        <> ["备份盘与 vault 嵌套（" <> b <> "）——镜像必须在展示集之外" | nv])

-- | 三态字段：'Nothing' = 本次不动；@Just Nothing@ = 清空；@Just (Just x)@ = 设成 x。
data ConfigPatch = ConfigPatch
  { cpVault :: Maybe (Maybe FilePath)
  , cpPhotosJson :: Maybe (Maybe FilePath)
  , cpWorkers :: Maybe (Maybe Int)
  , cpPortfolioDir :: Maybe (Maybe FilePath)
    -- ^ P7：portfolio 仓本地路径（上线命令生成用）
  , cpVaultPush :: Maybe (Maybe String)
    -- ^ P7：展示集仓 push 目标；字符闸 'pushTargetOk'
  , cpPortfolioPush :: Maybe (Maybe String)
  , cpMain :: Maybe (Maybe FilePath)
    -- ^ 只为**拒绝**而存在：任何试图经编辑层改主库路径的请求都要报错，而不是
    -- 被静默忽略——静默忽略会让调用方以为改成功了。
    --
    -- 二十四轮 minor：这里原本是 @Maybe FilePath@ 并用 aeson 的 @.:?@ 解析，
    -- 于是"键缺省"与"键为 null"塌成同一个 'Nothing'——@{"main":null,
    -- "workers":3}@ 会**静默忽略 main、照改 workers 并回 200**，正是这个字段
    -- 存在的意义要挡的那件事。改成与另外三项同一个三态，任何**出现**即拒。
  }
  deriving (Show, Eq)

emptyPatch :: ConfigPatch
emptyPatch = ConfigPatch Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | 线格式：**键缺省** = 不动，**键为 null** = 清空，否则设值。三态必须分得
-- 开——否则"清空 vault 路径"和"不改 vault 路径"会撞成同一个请求。实例写在
-- 类型所在模块（避免孤儿实例）。
instance Aeson.FromJSON ConfigPatch where
  parseJSON = Aeson.withObject "config" $ \o -> do
    let fld k = case KM.lookup k o of
          Nothing -> pure Nothing
          Just Aeson.Null -> pure (Just Nothing)
          Just v -> Just . Just <$> Aeson.parseJSON v
    ConfigPatch
      <$> fld "vault"
      <*> fld "photosJson"
      <*> fld "workers"
      <*> fld "portfolioDir"
      <*> fld "vaultPush"
      <*> fld "portfolioPush"
      <*> fld "main"

-- | fail-closed：任一条不合法就整体不写，并一次返回全部错误（GUI 能一次标完）。
-- 路径存在性是 IO 判定：设一个不存在的 vault 目录只会让后续每条命令报错，不如
-- 当场拒绝。收 'Config'（工作流 C101）：跨字段不变量只能在**施加后的整份记录**
-- 上判——'checkConfig' 兜底；锁内以盘上最新配置再复验一次（'configTxn'）。
checkPatch :: Config -> ConfigPatch -> IO [String]
checkPatch c p = do
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
  ep <- case cpPortfolioDir p of
    Just (Just v) -> do
      isDir <- doesDirectoryExist v
      -- 这项**只**用于生成上线命令：目录在但嵌不进命令行的路径设了也没用，
      -- 当场按 'cmdPath' 的白名单语法拒（vault/photos.json 另有用途，不在此拒）。
      pure
        ([v <> " 不是一个已存在的目录（portfolio 仓路径；不需要就留空）" | not isDir]
          <> either (\why -> [v <> " 无法安全嵌入上线命令（" <> why <> "）——这项只用于生成命令，换一个只含字母数字、空格与 -_.()'+,=@~#& 的盘符绝对路径，或留空"]) (const []) (cmdPath v))
    _ -> pure []
  let ew = case cpWorkers p of
        Just (Just w) | w < 1 || w > 64 -> ["并发数 " <> show w <> " 越界（1..64）"]
        _ -> []
      -- push 目标进的是「整块复制到终端」的命令文本：语法闸见 'Pm.Publish.pushTarget'。
      es =
        [ "push 目标 " <> show t <> " 不合法（" <> why <> "；须为 <remote> [<refspec>]，每段以字母数字开头，只含字母数字与 -._/:@~^，≤200 字符）"
        | Just (Just t) <- [cpVaultPush p, cpPortfolioPush p]
        , Left why <- [pushTarget t]
        ]
      -- @Just _@ 同时盖住 @Just (Just v)@（想改成 v）与 @Just Nothing@
      -- （main: null，想清空）：两者都是"经编辑层动主库"，一律拒。
      em = ["主库路径只读：改它等于换一个库，请在终端 pm init --main <路径>" | Just _ <- [cpMain p]]
      en = ["没有要改的项" | p == emptyPatch]
  whole <- checkConfig (applyPatch c p)
  pure (em <> en <> ev <> ej <> ep <> ew <> es <> whole)

-- | 施加（纯函数）。调用方须先过 'checkPatch'。
applyPatch :: Config -> ConfigPatch -> Config
applyPatch c p =
  c
    { cfgVaultPath = maybe (cfgVaultPath c) id (cpVault p)
    , cfgPhotosJson = maybe (cfgPhotosJson c) id (cpPhotosJson p)
    , cfgWorkers = maybe (cfgWorkers c) id (cpWorkers p)
    , cfgPortfolioDir = maybe (cfgPortfolioDir c) id (cpPortfolioDir p)
    , cfgVaultPush = maybe (cfgVaultPush c) id (cpVaultPush p)
    , cfgPortfolioPush = maybe (cfgPortfolioPush c) id (cpPortfolioPush p)
    }

-- | 一次配置**读改写**。**必须在 'withConfigLock' 之内调用**：锁内重新从盘上
-- 读一遍配置再施加补丁，否则调用方手里那份快照会把别人刚改的字段抹掉
-- （`pm config set --vault` 与 GUI 的"登记备份盘"并发时正是如此）。
--
-- 写完再从**盘上**读回：既把最新配置交回给调用方刷新自己的缓存，也顺带验证
-- render→parse 往返——渲染得出却读不回来的配置等于把 pm 锁死在起不来的状态。
configTxn :: ConfigPatch -> IO (Either String (Config, FilePath))
configTxn p = do
  fresh <- loadConfig
  case fresh of
    Left e -> pure (Left ("配置无法重新读入: " <> e))
    Right c0 -> do
      -- 锁内按盘上最新配置复验（工作流 C101）：调用方 checkPatch 用的是它
      -- 自己那份可能过期的快照，并发下另一方刚设的字段要与本补丁合起来判
      errs <- checkConfig (applyPatch c0 p)
      if not (null errs)
        then pure (Left ("配置不合法（锁内按盘上最新配置复验）: " <> intercalate "；" errs))
        else configTxn' c0 p

configTxn' :: Config -> ConfigPatch -> IO (Either String (Config, FilePath))
configTxn' c0 p = do
      fp <- writeConfig (applyPatch c0 p)
      back <- loadConfig
      pure $ case back of
        Left m -> Left ("配置写出后无法重新载入（已写到 " <> fp <> "）: " <> m)
        Right c2 -> Right (c2, fp)

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
  case cfgPortfolioDir c of
    Nothing -> putStrLn "  portfolio （未设，只影响上线命令生成）→ pm config set --portfolio-dir <仓路径>"
    Just d -> do
      ex <- doesDirectoryExist d
      putStrLn ("  portfolio " <> d <> mark ex)
  putStrLn ("  push 目标  展示集 " <> maybe "（默认 git push）" id (cfgVaultPush c) <> " · portfolio " <> maybe "（默认 git push）" id (cfgPortfolioPush c))
  putStrLn ("  并发数    " <> maybe "（默认=核数）" show (cfgWorkers c))
  case (cfgBackupId c, cfgBackupSubpath c) of
    (Just i, Just s) -> putStrLn ("  备份盘    UUID " <> T.unpack i <> " · 盘内路径 " <> s <> "（按 UUID 认盘，与盘符无关）")
    (Nothing, Nothing) -> putStrLn "  备份盘    （未登记）→ pm backup init <盘上镜像路径>"
    -- 半对登记（手编残余）：checkConfig 在写入口拒新增，这里如实报存量
    _ -> putStrLn "  备份盘    ⚠ 登记不完整（id 与 subpath 须成对）→ 重跑 pm backup init"
  pure 0
 where
  mark True = ""
  mark False = "  ⚠ 路径不存在"

-- | 改配置：与 @POST /api/config@ 共用 'checkPatch' / 'configTxn'。
--
-- 第二个参数（调用方 'Pm.Cli.withCfg' 载入的那份配置）**只用来确认配置存在**：
-- 真正施加补丁的基准在锁内重新读（见 'configTxn'），拿这份可能已过期的快照
-- 写回会抹掉别人刚改的字段。
runConfigSet :: ConfigPatch -> Config -> IO Int
runConfigSet p stale = do
  errs <- checkPatch stale p
  if not (null errs)
    then mapM_ (putStrLn . ("  ✗ " <>)) errs >> pure 2
    else do
      m <- withConfigLock (configTxn p)
      case m of
        Nothing -> putStrLn "另一个 pm 正在改配置（配置锁被占），本次没改" >> pure 2
        Just (Left e) -> putStrLn ("✗ " <> e) >> pure 2
        Just (Right (c2, fp)) -> do
          putStrLn ("✓ 已写入 " <> fp)
          runConfigShow c2

-- ─── CLI 旗标的三态收集（工作流 F082） ──────────────────────────────────────

-- | @pm config set@ 的原始旗标：每项是 (给的值, @--no-X@ 开关)。矛盾留给
-- 'mkPatch' 拒绝——此前解析器里 @if clear then Just Nothing else …@ 把
-- 「--vault X --no-vault」静默折成清空：✓ 已写入、退出 0，给的路径从未被看见，
-- 与 @--place/--event@、@--backup/--vault@ 的「只能给一个」纪律相反。
data ConfigSetOpts = ConfigSetOpts
  { csVault :: (Maybe FilePath, Bool)
  , csPhotosJson :: (Maybe FilePath, Bool)
  , csWorkers :: (Maybe Int, Bool)
  , csPortfolioDir :: (Maybe FilePath, Bool)
  , csVaultPush :: (Maybe String, Bool)
  , csPortfolioPush :: (Maybe String, Bool)
  , csMain :: Maybe FilePath
  }

-- | (值, 清空) → 三态；两个都给 = 使用者写错了，直接报错不替他猜（I1）。
tri :: String -> (Maybe a, Bool) -> Either String (Maybe (Maybe a))
tri nm (Just _, True) = Left ("--" <> nm <> " 与 --no-" <> nm <> " 只能给一个")
tri _ (Nothing, True) = Right (Just Nothing)
tri _ (mv, False) = Right (fmap Just mv)

mkPatch :: ConfigSetOpts -> Either String ConfigPatch
mkPatch o =
  ConfigPatch
    <$> tri "vault" (csVault o)
    <*> tri "photos-json" (csPhotosJson o)
    <*> tri "workers" (csWorkers o)
    <*> tri "portfolio-dir" (csPortfolioDir o)
    <*> tri "vault-push" (csVaultPush o)
    <*> tri "portfolio-push" (csPortfolioPush o)
    <*> pure (fmap Just (csMain o))
