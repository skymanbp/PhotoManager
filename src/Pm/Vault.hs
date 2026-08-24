{-# LANGUAGE OverloadedStrings #-}

-- | 相册 ↔ vault 展示集：status 六态差异（DESIGN.md §10.1）与 push 写路径
-- （§10.2）。status 六态语义与 JSON 值形状逐字段兼容 sync_photos.py
-- （docs\/specs\/sync-photos-legacy-spec.md 是逐行为基线）；UNPUSHABLE 是 pm
-- 新增第七态：.png 在 status 里显式可见（push 写路径拒收），不改变六态归类
-- 也不影响退出码。
--
-- I11：vault 是 git 工作树——status 对 vault 目录**零写入**（vault 侧 sha
-- 缓存放主库 `.pm\/vault-cache\/`）；push 建 vault root 前先验 `.gitignore`
-- 已覆盖 `.pm\/`（用户批准 2026-08-23），验不过 fail-closed。
-- I9：pm 绝不执行 git——push 结束打印显式路径的 git 步骤（禁 -A）。
module Pm.Vault
  ( VaultDiff (..)
  , vaultDiff
  , fixedCategories
  , photoExtFold
  , renderVaultJson
  , VaultCacheMeta (..)
  , readVaultCacheMeta
  , VaultReport (..)
  , computeVault
  , ensureVaultRoot
  , vaultIgnoreGuard
  , gitStepsLines
  , planCategories
  , runVaultStatus
  , runVaultPush
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson
import qualified Data.Aeson.Encoding as AE
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.Char (toLower)
import Data.List (nub, partition, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (splitDirectories, takeDirectory, takeExtension, (</>))
import Text.Printf (printf)

import Pm.Catalog (loadCatalog)
import Pm.Config (Config (..), pmDir, readJsonMaybe, readRootInfo, writeRootInfo, writeSideCache, freshRootId)
import Pm.Hash (StatSnap (..), sha256File, statHitStable, statSnap)
import Pm.Op
import Pm.Plan
import Pm.Types
import Pm.Win (volumeFsType)

-- ─── 纯核心：legacy 算法逐行复刻 ────────────────────────────────────────────

-- | 六态结果。字段元组形状 = sync_photos.py JSON 值形状（hash 此处存全长，
-- 16 字符截断在 JSON 渲染层做）。
data VaultDiff = VaultDiff
  { vdOk :: [(FilePath, String)]
  , vdNew :: [FilePath]
  , vdMissing :: [(FilePath, String)]
  , vdRenamed :: [(FilePath, FilePath, String, Text)]
    -- ^ (源名, vault 名, vault 类目, sha)
  , vdDrift :: [(FilePath, String, Text, Text)]
    -- ^ (名, 类目, 源 sha, vault sha)
  , vdDuplicate :: [(FilePath, [String])]
  }
  deriving (Show, Eq)

-- | legacy CATEGORIES 元组（次序即输出次序）。其它子目录不纳入比对，但会
-- 显式告警（legacy 的静默无视是已登记缺陷，规范 §6 修复项 1）。
fixedCategories :: [String]
fixedCategories = ["landscape", "portrait", "urban"]

-- | pm 过滤集合 = legacy PHOTO_EXTS 的 case-fold 等价类（DESIGN §10.1：
-- legacy 字面六拼写会静默丢 .Jpg\/.Png 等，pm 有意修复为 case-fold）。
photoExtFold :: FilePath -> Bool
photoExtFold p = map toLower (takeExtension p) `elem` [".jpg", ".jpeg", ".png"]

-- | push 写路径只收 jpg\/jpeg（vault 硬规则 3；.png = UNPUSHABLE）。
pushableExt :: FilePath -> Bool
pushableExt p = map toLower (takeExtension p) `elem` [".jpg", ".jpeg"]

-- | 核心 diff。输入：源侧 名→sha；vault 侧按类目次序的 (类目, 名→sha)。
-- 次序契约与 legacy 逐点对应：new\/missing 候选按名字典序（Map 键序 =
-- Python sorted 的码点序）；同名多类目按类目元组序；RENAME 仅当两侧候选
-- 皆非空才做、贪心首配、每个 NEW 至多消费一个 MISSING（legacy :123-138）。
vaultDiff :: Map FilePath Text -> [(String, Map FilePath Text)] -> VaultDiff
vaultDiff srcShas vaultByCat =
  VaultDiff
    { vdOk = ok
    , vdNew = [n | n <- newCand, n `notElem` matchedNew]
    , vdMissing = [mc | mc <- missingCand, mc `notElem` consumedMissing]
    , vdRenamed = renamed
    , vdDrift = drift
    , vdDuplicate = duplicate
    }
 where
  -- 名 → [(类目, sha)]；fromListWith 配 flip (<>) 保类目先入先出次序
  vaultIdx :: Map FilePath [(String, Text)]
  vaultIdx =
    Map.fromListWith
      (flip (<>))
      [(name, [(cat, sha)]) | (cat, m) <- vaultByCat, (name, sha) <- Map.toList m]
  newCand = Map.keys (srcShas `Map.difference` vaultIdx)
  missingCand =
    [ (name, cat)
    | (name, cats) <- Map.toList (vaultIdx `Map.difference` srcShas)
    , (cat, _) <- cats
    ]
  inter = Map.toList (Map.intersectionWith (,) srcShas vaultIdx)
  duplicate = [(name, sort (map fst cats)) | (name, (_, cats)) <- inter, length cats > 1]
  (ok, drift) = foldr classify ([], []) inter
  classify (name, (srcH, cats)) (oks, drifts) =
    let sameH = [(name, cat) | (cat, vh) <- cats, vh == srcH]
        diffH = [(name, cat, srcH, vh) | (cat, vh) <- cats, vh /= srcH]
     in (sameH <> oks, diffH <> drifts)
  vaultShaOf (n, c) = fromMaybe "" (lookup c =<< Map.lookup n vaultIdx)
  renamed
    | null newCand || null missingCand = []
    | otherwise = reverse (fst (foldl' match ([], []) newCand))
   where
    missingHash = [(mc, vaultShaOf mc) | mc <- missingCand]
    match (acc, consumed) newName =
      let h = fromMaybe "" (Map.lookup newName srcShas)
          hit =
            [ mc
            | (mc, mh) <- missingHash
            , mc `notElem` consumed
            , mh == h
            ]
       in case hit of
            ((mName, mCat) : _) ->
              ((newName, mName, mCat, h) : acc, (mName, mCat) : consumed)
            [] -> (acc, consumed)
  matchedNew = [n | (n, _, _, _) <- renamed]
  consumedMissing = [(m, c) | (_, m, c, _) <- renamed]

-- | 退出码语义（legacy :237）：duplicate（与 unpushable）不算差异。
hasDiff :: VaultDiff -> Bool
hasDiff d =
  not (null (vdNew d) && null (vdMissing d) && null (vdRenamed d) && null (vdDrift d))

-- ─── JSON 渲染（键名、键序、值形状 = legacy；末尾追加 unpushable） ──────────

renderVaultJson ::
  FilePath -> FilePath -> Int -> Int -> VaultDiff -> [(FilePath, String)] -> [(FilePath, String)] -> BSL.ByteString
renderVaultJson srcDir vaultDir srcCount vaultCount d unpushable unstable =
  AE.encodingToLazyByteString . pairs $
    AE.pair "source_dir" (AE.string srcDir)
      <> AE.pair "vault_dir" (AE.string vaultDir)
      <> AE.pair "source_count" (AE.int srcCount)
      <> AE.pair "vault_count" (AE.int vaultCount)
      <> AE.pair "ok" (AE.list pairNC (vdOk d))
      <> AE.pair "new" (AE.list AE.string (vdNew d))
      <> AE.pair "missing" (AE.list pairNC (vdMissing d))
      <> AE.pair
        "renamed"
        ( AE.list
            (\(n, m, c, h) -> AE.list id [AE.string n, AE.string m, AE.string c, AE.text (T.take 16 h)])
            (vdRenamed d)
        )
      <> AE.pair
        "drift"
        ( AE.list
            (\(n, c, sh, vh) -> AE.list id [AE.string n, AE.string c, AE.text (T.take 16 sh), AE.text (T.take 16 vh)])
            (vdDrift d)
        )
      <> AE.pair
        "duplicate"
        (AE.list (\(n, cats) -> AE.list id [AE.string n, AE.list AE.string cats]) (vdDuplicate d))
      -- pm 第七态（legacy 无此键；六键的集合逐项比对不受影响）
      <> AE.pair "unpushable" (AE.list pairNC unpushable)
      -- pm 第八态（评审 #5）：读取不稳定的名字（已从六态整体排除）
      <> AE.pair "unstable" (AE.list pairNC unstable)
 where
  pairNC (n, c) = AE.list id [AE.string n, AE.string c]

-- ─── vault 侧缓存（主库 .pm\/vault-cache\/，display + sha 复用） ─────────────

-- | 上次比对的计数快照（pm status 不触 vault 也能报，同备份盘缓存性质）。
-- 键名由 Generic 派生（去 vm 前缀 + 全小写），非 legacy 兼容面。
-- P3b-4 评审 #4：缓存键是类目相对路径，vault 被换路径\/换 root 后
-- (size,mtime) 巧合会复用错误 sha——meta 记录生成时的规范路径与 root
-- UUID，身份不符即整体弃用缓存（旧格式 meta 缺字段 → 解析失败 → 同弃用）。
data VaultCacheMeta = VaultCacheMeta
  { vmAt :: UTCTime
  , vmVaultPath :: FilePath
  , vmRootId :: Maybe Text
  , vmOk, vmNew, vmMissing, vmRenamed, vmDrift, vmDuplicate, vmUnpushable, vmUnstable :: Int
  }
  deriving (Show, Eq, Generic)

vaultMetaOpts :: Options
vaultMetaOpts = defaultOptions {fieldLabelModifier = map toLower . drop 2}

instance ToJSON VaultCacheMeta where
  toJSON = genericToJSON vaultMetaOpts
  toEncoding = genericToEncoding vaultMetaOpts

instance FromJSON VaultCacheMeta where
  parseJSON = genericParseJSON vaultMetaOpts

vaultCacheDir :: FilePath -> FilePath
vaultCacheDir mainRoot = pmDir mainRoot </> "vault-cache"

readVaultCacheMeta :: FilePath -> IO (Maybe VaultCacheMeta)
readVaultCacheMeta mainRoot = readJsonMaybe (vaultCacheDir mainRoot </> "meta.json")

readVaultCacheCatalog :: FilePath -> IO (Maybe Catalog)
readVaultCacheCatalog mainRoot = readJsonMaybe (vaultCacheDir mainRoot </> "catalog.json")

writeVaultCache :: FilePath -> Catalog -> VaultCacheMeta -> IO ()
writeVaultCache mainRoot = writeSideCache (vaultCacheDir mainRoot)

-- ─── IO：列目录 + 缓存感知 sha ──────────────────────────────────────────────

-- | 平铺列出目录内照片文件（case-fold 过滤），并报告出现的子目录名
-- （legacy 非递归扫描让子目录内容彻底不可见——pm 保持平铺语义但把
-- 子目录显式报出来，不静默）。
listFlatPhotos :: FilePath -> IO ([FilePath], [FilePath])
listFlatPhotos dir = do
  ex <- doesDirectoryExist dir
  if not ex
    then pure ([], [])
    else do
      names <- listDirectory dir
      flagged <- mapM (\n -> (,) n <$> doesDirectoryExist (dir </> n)) names
      let (dirs, files) = partition snd flagged
      pure (sort (filter photoExtFold (map fst files)), sort (map fst dirs))

-- | 取一个文件的 sha：stat 与缓存条目一致（statHitStable：含 racy 余量
-- 判据，评审 #4）→ 复用；否则真实重读，双 stat 防撕裂。三轮不稳 →
-- (末次 sha, Nothing)——调用方把该名整体从六态分类排除并单列报告
-- （评审 #5）。本函数不打印：--json 输出面要纯净，告警由调用方按
-- quiet 决定。
shaViaCache :: Map FilePath Entry -> FilePath -> FilePath -> IO (Text, Maybe Entry)
shaViaCache cache rel abs' = do
  pre <- statSnap abs'
  case Map.lookup rel cache of
    Just e
      | statHitStable (enSize e) (enMtimeNs e) (enLastVerified e) pre ->
          pure (enSha e, Just e)
    _ -> go (3 :: Int) pre
 where
  go n pre = do
    sha <- sha256File abs'
    post <- statSnap abs'
    if post == pre
      then do
        now <- getCurrentTime
        pure
          ( sha
          , Just
              Entry
                { enPath = rel
                , enSize = ssSize post
                , enMtimeNs = ssMtimeNs post
                , enSha = sha
                , enKind = classifyExt (takeExtension rel)
                , enLastVerified = Just now
                }
          )
      else
        if n > 1
          then go (n - 1) post
          else pure (sha, Nothing)

-- ─── 共享计算核心（status 与 push 同源；每次运行顺带刷新缓存） ──────────────

data VaultReport = VaultReport
  { vrSrcDir, vrVaultDir :: FilePath
  , vrSrcCount, vrVaultCount :: Int
  , vrDiff :: VaultDiff
  , vrUnpushable :: [(FilePath, String)]
  , vrUnstable :: [(FilePath, String)]
    -- ^ (名, 位置)：任一侧三轮双 stat 仍不稳的名字（评审 #5）。该名整体
    -- 退出六态分类（两侧都排除，否则另一侧会伪报 NEW\/MISSING），状态
    -- 未知 → 退出码非零，fail-closed。
  , vrSrcMeta :: Map FilePath Entry
    -- ^ 源名 → Entry（size\/mtime\/sha，push 计划的执行前提；读取不稳的
    -- 文件不在此表 → 不可入计划）
  }

-- | Left (消息, 退出码)。quiet 抑制告警行（--json 输出面要纯净）。
computeVault :: Bool -> Config -> IO (Either (String, Int) VaultReport)
computeVault quiet cfg = case cfgVaultPath cfg of
  Nothing ->
    pure (Left ("配置无 vault 路径 → pm init --main <主库> --vault <展示集路径>（或手动补 config.toml 的 [vault] path）", 2))
  Just vaultDir -> do
    let root = cfgMainPath cfg
        srcDir = root </> "相册"
    okSrc <- doesDirectoryExist srcDir
    okVault <- doesDirectoryExist vaultDir
    case (okSrc, okVault) of
      (False, _) -> pure (Left ("ERROR: source missing: " <> srcDir, 2))
      (_, False) -> pure (Left ("ERROR: vault missing: " <> vaultDir, 2))
      _ -> do
        -- 评审 #4：缓存身份绑定。展示/JSON 仍用配置原样路径（legacy 兼容
        -- 面）；身份比对用规范路径 + vault root UUID。
        vaultCanon <- canonicalizePath vaultDir
        mVRoot <- readRootInfo vaultDir
        (mcat, _) <- loadCatalog root
        mMeta <- readVaultCacheMeta root
        mVCache <- readVaultCacheCatalog root
        let cacheIdentityOk = case mMeta of
              Just m ->
                map toLower (vmVaultPath m) == map toLower vaultCanon
                  && vmRootId m == (riId <$> mVRoot)
              Nothing -> False
            mainCache = maybe Map.empty catEntries mcat
            vaultCache =
              if cacheIdentityOk then maybe Map.empty catEntries mVCache else Map.empty
            resolve cache rel abs' n = do
              (sha, me) <- shaViaCache cache rel abs'
              pure (n, sha, me)
            warn s = unless quiet (putStrLn s)
        (srcNames, srcSubdirs) <- listFlatPhotos srcDir
        srcTriples <- mapM (\n -> resolve mainCache ("相册" </> n) (srcDir </> n) n) srcNames
        (_, vaultTop) <- listFlatPhotos vaultDir
        let knownAux = ["_inbox", "_site", "scripts"]
            unknownDirs =
              [ dn
              | dn <- vaultTop
              , dn `notElem` fixedCategories
              , dn `notElem` knownAux
              , take 1 dn /= "."
              ]
        perCat <- forM fixedCategories $ \cat -> do
          (names, subdirs) <- listFlatPhotos (vaultDir </> cat)
          mapM_ (\dn -> warn ("  ⚠ vault 类目下有子目录（不递归）: " <> (cat </> dn))) subdirs
          ps <- mapM (\n -> resolve vaultCache (cat </> n) (vaultDir </> cat </> n) n) names
          pure (cat, ps)
        mapM_ (\dn -> warn ("  ⚠ vault 未知目录（未纳入比对）: " <> dn)) unknownDirs
        mapM_ (\dn -> warn ("  ⚠ 相册下有子目录（平铺语义，不递归）: " <> dn)) srcSubdirs
        -- 评审 #5：任一侧读取不稳的名字整体退出六态分类（只排一侧会让
        -- 另一侧伪报 NEW/MISSING）；单列报告 + 退出码非零。
        let unstable =
              [(n, "相册") | (n, _, Nothing) <- srcTriples]
                <> [(n, cat) | (cat, ps) <- perCat, (n, _, Nothing) <- ps]
            badNames = map fst unstable
            srcShas = Map.fromList [(n, sha) | (n, sha, _) <- srcTriples, n `notElem` badNames]
            vaultShas =
              [ (cat, Map.fromList [(n, sha) | (n, sha, _) <- ps, n `notElem` badNames])
              | (cat, ps) <- perCat
              ]
            d = vaultDiff srcShas vaultShas
            vaultCount = sum [Map.size m | (_, m) <- vaultShas]
            isPng n = map toLower (takeExtension n) == ".png"
            unpushable =
              [(n, "相册") | n <- srcNames, isPng n]
                <> [(n, cat) | (cat, ps) <- perCat, (n, _, _) <- ps, isPng n]
        mapM_
          (\(n, loc) -> warn ("  ⚠ 读取不稳定（本轮退出六态分类，fail-closed）: " <> loc </> n))
          unstable
        now <- getCurrentTime
        let vEntries = [e | (_, ps) <- perCat, (_, _, Just e) <- ps]
            meta =
              VaultCacheMeta
                { vmAt = now
                , vmVaultPath = vaultCanon
                , vmRootId = riId <$> mVRoot
                , vmOk = length (vdOk d)
                , vmNew = length (vdNew d)
                , vmMissing = length (vdMissing d)
                , vmRenamed = length (vdRenamed d)
                , vmDrift = length (vdDrift d)
                , vmDuplicate = length (vdDuplicate d)
                , vmUnpushable = length unpushable
                , vmUnstable = length unstable
                }
        writeVaultCache root (Catalog "vault-cache" now (entryMap vEntries)) meta
        pure
          ( Right
              VaultReport
                { vrSrcDir = srcDir
                , vrVaultDir = vaultDir
                , vrSrcCount = Map.size srcShas
                , vrVaultCount = vaultCount
                , vrDiff = d
                , vrUnpushable = unpushable
                , vrUnstable = unstable
                , vrSrcMeta = Map.fromList [(n, e) | (n, _, Just e) <- srcTriples]
                }
          )

-- ─── pm vault status [--json] ───────────────────────────────────────────────

-- | 退出码与 legacy 同构：0 同步 \/ 1 有差异（duplicate、unpushable 不算；
-- unstable **算**——状态未知不能报「已同步」，评审 #5 的有意偏离，规范
-- §6 修复项 9）\/ 2 路径错误。
runVaultStatus :: Bool -> Config -> IO Int
runVaultStatus asJson cfg = do
  er <- computeVault asJson cfg
  case er of
    Left (msg, code) -> putStrLn msg >> pure code
    Right r -> do
      if asJson
        then BSLC.putStrLn (renderVaultJson (vrSrcDir r) (vrVaultDir r) (vrSrcCount r) (vrVaultCount r) (vrDiff r) (vrUnpushable r) (vrUnstable r))
        else renderHuman r
      pure (if hasDiff (vrDiff r) || not (null (vrUnstable r)) then 1 else 0)

renderHuman :: VaultReport -> IO ()
renderHuman r = do
  let d = vrDiff r
      unpushable = vrUnpushable r
  printf "vault 差异 · 相册 %s (%d) ↔ %s (%d)\n" (vrSrcDir r) (vrSrcCount r) (vrVaultDir r) (vrVaultCount r)
  printf
    "  OK %d · NEW %d · MISSING %d · RENAME %d · DRIFT %d · DUPLICATE %d · UNPUSHABLE %d · UNSTABLE %d\n"
    (length (vdOk d))
    (length (vdNew d))
    (length (vdMissing d))
    (length (vdRenamed d))
    (length (vdDrift d))
    (length (vdDuplicate d))
    (length unpushable)
    (length (vrUnstable r))
  mapM_ (\n -> putStrLn ("  + NEW " <> n <> "  → pm vault push --category <类目> " <> n)) (vdNew d)
  mapM_ (\(n, c) -> putStrLn ("  - MISSING " <> c </> n <> "  → 决定保留还是撤（只报告）")) (vdMissing d)
  mapM_
    ( \(n, m, c, h) ->
        putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "' (" <> T.unpack (T.take 16 h) <> ")")
    )
    (vdRenamed d)
  mapM_
    ( \(n, c, sh, vh) ->
        putStrLn
          ("  ~ DRIFT " <> c </> n <> " (src " <> T.unpack (T.take 16 sh) <> " ≠ vault " <> T.unpack (T.take 16 vh) <> ") → pm vault push 生成裁决计划")
    )
    (vdDrift d)
  mapM_ (\(n, cats) -> putStrLn ("  ! DUPLICATE " <> n <> " → " <> unwords cats)) (vdDuplicate d)
  mapM_
    (\(n, loc) -> putStrLn ("  ✋ UNPUSHABLE " <> loc </> n <> "（.png：status 可见，push 写路径拒收）"))
    unpushable
  mapM_
    (\(n, loc) -> putStrLn ("  ⚠ UNSTABLE " <> loc </> n <> "（读取期间持续变化，已退出六态分类；稍后重跑）"))
    (vrUnstable r)

-- ─── pm vault push（§10.2） ─────────────────────────────────────────────────

-- | I11 的可重入校验核心（P3b-4 评审 #2/#3 共用：ensureVaultRoot 建 root
-- 前与 pm apply 的执行期 preflight 都走这里）。三种 git 语境全覆盖：
--
--   * vault 自身有 @.git@ **目录**（普通仓根）→ 查本目录 .gitignore；
--   * vault 自身有 @.git@ **文件**（worktree\/submodule 链接）→ 同上；
--   * vault 自身无 .git 但**祖先**有 → 一律拒绝：.pm 的忽略状态由祖先仓
--     的 ignore 链决定，pm 不实现完整 gitignore 语义，fail-closed。
--
-- .gitignore 检查是文本级白名单：必须存在恰好 @.pm\/@ 的行，且不允许任何
-- 含 @.pm@ 的反规则（@!@ 行可重新包含 .pm\/，评审 #2）。pm 不执行 git（I9）。
vaultIgnoreGuard :: FilePath -> IO (Either String ())
vaultIgnoreGuard vaultDir = do
  gitDir <- doesDirectoryExist (vaultDir </> ".git")
  gitFile <- doesFileExist (vaultDir </> ".git")
  if gitDir || gitFile
    then do
      let igFp = vaultDir </> ".gitignore"
      ex <- doesFileExist igFp
      if not ex
        then pure (Left (i11Msg igFp "无 .gitignore"))
        else do
          raw <- BS.readFile igFp
          let ls = map T.strip (T.lines (TE.decodeUtf8Lenient raw))
              hasRule = ".pm/" `elem` ls
              negations = [l | l <- ls, "!" `T.isPrefixOf` l, ".pm" `T.isInfixOf` l]
          case (hasRule, negations) of
            (False, _) -> pure (Left (i11Msg igFp "缺 `.pm/` 行"))
            (True, _ : _) ->
              pure (Left (i11Msg igFp ("存在可能重新包含 .pm 的反规则: " <> T.unpack (T.intercalate ", " negations))))
            (True, []) -> pure (Right ())
    else do
      manc <- findGitAncestor vaultDir
      case manc of
        Just anc ->
          pure
            ( Left
                ( "I11: vault 位于上层 git 仓库内部（" <> anc
                    <> "）且自身不是仓根——.pm 的忽略状态由祖先 ignore 链决定，pm 不解析完整 gitignore 语义，拒绝（fail-closed）"
                )
            )
        Nothing -> pure (Right ())
 where
  i11Msg igFp why =
    "I11: vault 是 git 工作树且 .gitignore 未有效覆盖 `.pm/`（" <> why
      <> "）—— 先经用户确认修正 " <> igFp <> "（恰含 `.pm/` 行、无 .pm 反规则），再运行"

-- | 从 start 的父目录向上找持有 .git（目录或文件）的祖先。
findGitAncestor :: FilePath -> IO (Maybe FilePath)
findGitAncestor start = go (takeDirectory start)
 where
  go dir = do
    d <- doesDirectoryExist (dir </> ".git")
    f <- doesFileExist (dir </> ".git")
    if d || f
      then pure (Just dir)
      else
        let up = takeDirectory dir
         in if up == dir then pure Nothing else go up

-- | I11 守卫 + vault root 建立（幂等）。守卫核心见 'vaultIgnoreGuard'。
ensureVaultRoot :: FilePath -> IO (Either String RootInfo)
ensureVaultRoot vaultDir = do
  g <- vaultIgnoreGuard vaultDir
  case g of
    Left msg -> pure (Left msg)
    Right () -> do
      existing <- readRootInfo vaultDir
      case existing of
        Just info
          | riRole info == RoleVault -> pure (Right info)
          | otherwise ->
              pure (Left ("该路径已是 " <> show (riRole info) <> " root，拒绝作为 vault root"))
        Nothing -> do
          rid <- freshRootId
          now <- getCurrentTime
          fs <- case vaultDir of
            (c : _) -> volumeFsType c
            _ -> pure Nothing
          let info = RootInfo rid RoleVault now fs
          writeRootInfo vaultDir info
          putStrLn ("✓ vault root 标识已创建: " <> T.unpack rid)
          pure (Right info)

-- | push 收尾要打印的显式 git 步骤（纯函数；I9：pm 自己绝不执行）。
gitStepsLines :: FilePath -> Text -> [String] -> [String]
gitStepsLines vaultDir pid cats =
  [ "→ vault 侧 git 收尾（pm 不执行 git；明确禁止 git add -A / git add .）："
  , "    cd " <> vaultDir
  , "    git add " <> unwords (sort (nub cats))
  , "    git commit -m \"photos: pm vault push " <> T.unpack pid <> "\""
  , "    git push origin main"
  ]

-- | 计划涉及的 vault 类目（= 各 Copy dst 的第一层目录；git add 的显式对象）。
planCategories :: Plan -> [String]
planCategories plan =
  filter (/= "") (nub [topOf (opDstRel (piOp it)) | it <- plItems plan, isCopy (piOp it)])
 where
  topOf p = case splitDirectories p of (x : _) -> x; [] -> ""
  isCopy OpCopy {} = True
  isCopy _ = False -- Quarantine 的 trash 路径与 Rename 不进 git add

-- | photos.json 只读引用检查（§10.2 RENAME 策略）：vault 文件名出现在
-- photos.json 的哪一行（它以完整 Pages URL 引用）。
photosJsonRef :: Maybe FilePath -> FilePath -> IO (Maybe Int)
photosJsonRef Nothing _ = pure Nothing
photosJsonRef (Just fp) name = do
  ex <- doesFileExist fp
  if not ex
    then pure Nothing
    else do
      raw <- BS.readFile fp
      let ls = zip [1 :: Int ..] (T.lines (TE.decodeUtf8Lenient raw))
      pure (case [i | (i, l) <- ls, T.pack name `T.isInfixOf` l] of i : _ -> Just i; [] -> Nothing)

-- | `pm vault push [--category C FILES...]`：
-- NEW×已定类目 → Copy 计划项；DRIFT → NEEDS-DECISION（pm resolve --keep src
-- 走 §6.5 supersede，旧字节进 vault root 的 .pm\/trash\/）；RENAME\/MISSING
-- 只报告（RENAME 带 photos.json BLOCKED 检查）。写路径只收 jpg\/jpeg。
runVaultPush :: (Plan -> IO Int) -> Maybe String -> [FilePath] -> Config -> IO Int
runVaultPush runPlan mCat files cfg = do
  er <- computeVault False cfg
  case er of
    Left (msg, code) -> putStrLn msg >> pure code
    Right r -> do
      let d = vrDiff r
      -- 选择校验（fail-closed：任何一条不合法就不出计划）
      let sel = case (mCat, files) of
            (Just c, fs@(_ : _)) -> Right [(c, f) | f <- fs]
            (Nothing, []) -> Right []
            (Just _, []) -> Left ["--category 需要同时给出要推送的文件名（pm vault push --category landscape A.jpg …）"]
            (Nothing, _ : _) -> Left ["给了文件却没给 --category（CLI 无法看图分类；或用 pm ui，P4）"]
          checkSel (c, f)
            | f `elem` map fst (vrUnstable r) = Just (f <> " 本轮读取不稳定（已退出六态分类，fail-closed），稍后重试")
            | c `notElem` fixedCategories = Just ("类目不存在: " <> c <> "（可选: " <> unwords fixedCategories <> "）")
            | f `notElem` vdNew d = Just (f <> " 不在 NEW 集合里（只有 NEW 可 push；看 pm vault status）")
            | not (pushableExt f) = Just (f <> " 是 UNPUSHABLE（写路径只收 jpg/jpeg）")
            | not (Map.member f (vrSrcMeta r)) = Just (f <> " 读取不稳定，本轮不可入计划（稍后重试）")
            | otherwise = Nothing
      case sel of
        Left errs -> mapM_ putStrLn errs >> pure 2
        Right pairs' -> do
          let errs = [e | p <- pairs', Just e <- [checkSel p]]
          if not (null errs)
            then mapM_ (putStrLn . ("  ✗ " <>)) errs >> pure 2
            else do
              -- 报告面：RENAME（photos.json 引用检查）与 MISSING 只报告
              forM_ (vdRenamed d) $ \(n, m, c, _) -> do
                ref <- photosJsonRef (cfgPhotosJson cfg) m
                case ref of
                  Just line ->
                    putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "' → BLOCKED(photos.json:" <> show line <> ")：改名会打断已上线 URL，只报告")
                  Nothing ->
                    putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "'（未被 photos.json 引用；改名功能后续增量，暂只报告）")
              forM_ (vdMissing d) $ \(n, c) ->
                putStrLn ("  - MISSING " <> c </> n <> "（可能有意撤下，决定权在用户，只报告）")
              -- 计划面：选中的 NEW + 全部 DRIFT
              let newItems =
                    [ ( OpCopy (vrSrcDir r </> f) (c </> f) (enSha e) (enSize e) (enMtimeNs e)
                      , StPending
                      )
                    | (c, f) <- pairs'
                    , Just e <- [Map.lookup f (vrSrcMeta r)]
                    ]
                  driftItems =
                    [ ( OpCopy (vrSrcDir r </> n) (c </> n) (enSha e) (enSize e) (enMtimeNs e)
                      , StNeedsDecision "DRIFT：相册是上游真相 → pm resolve <计划> --item N --keep src（旧字节先入 vault .pm/trash）或 --keep dst 保留现状"
                      )
                    | (n, c, _, _) <- vdDrift d
                    , Just e <- [Map.lookup n (vrSrcMeta r)]
                    ]
                  allItems = newItems <> driftItems
              if null allItems
                then do
                  unless (null (vdNew d)) $ do
                    putStrLn ("  → " <> show (length (vdNew d)) <> " 个 NEW 待分类：pm vault push --category <类目> <文件…>（类目: " <> unwords fixedCategories <> "）")
                  putStrLn "（无可执行项，未生成计划）"
                  pure (if hasDiff d then 1 else 0)
                else do
                  einfo <- ensureVaultRoot (vrVaultDir r)
                  case einfo of
                    Left msg -> putStrLn msg >> pure 2
                    Right info -> do
                      pid <- newPlanId
                      now <- getCurrentTime
                      let plan =
                            Plan
                              { plId = pid
                              , plKind = "vault-push"
                              , plRootPath = vrVaultDir r
                              , plRootId = Just (riId info)
                              , plCreated = now
                              , plItems = [PlanItem i op st Nothing | (i, (op, st)) <- zip [0 ..] allItems]
                              }
                      code <- runPlan plan
                      when (code == 0) $
                        mapM_ putStrLn (gitStepsLines (vrVaultDir r) pid (planCategories plan))
                      pure code
