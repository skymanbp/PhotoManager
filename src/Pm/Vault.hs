{-# LANGUAGE OverloadedStrings #-}

-- | 相册 ↔ vault 展示集差异（DESIGN.md §10.1）。六态语义与 JSON 值形状逐字段
-- 兼容 sync_photos.py（docs\/specs\/sync-photos-legacy-spec.md 是逐行为基线）；
-- UNPUSHABLE 是 pm 新增第七态：.png 在 status 里显式可见（push 写路径拒收），
-- 不改变六态归类也不影响退出码。
--
-- I11：vault 是 git 工作树——本模块对 vault 目录**零写入**；vault 侧 sha
-- 缓存放主库 `.pm\/vault-cache\/`（比照 Pm.Backup 的备份盘缓存先例）。
module Pm.Vault
  ( VaultDiff (..)
  , vaultDiff
  , fixedCategories
  , photoExtFold
  , renderVaultJson
  , VaultCacheMeta (..)
  , readVaultCacheMeta
  , runVaultStatus
  ) where

import Control.Monad (unless)
import Data.Aeson
import qualified Data.Aeson.Encoding as AE
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.Char (toLower)
import Data.List (partition, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Text.Printf (printf)

import Pm.Catalog (loadCatalog)
import Pm.Config (Config (..), pmDir, readJsonMaybe, writeSideCache)
import Pm.Hash (StatSnap (..), sha256File, statSnap)
import Pm.Types

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
  FilePath -> FilePath -> Int -> Int -> VaultDiff -> [(FilePath, String)] -> BSL.ByteString
renderVaultJson srcDir vaultDir srcCount vaultCount d unpushable =
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
 where
  pairNC (n, c) = AE.list id [AE.string n, AE.string c]

-- ─── vault 侧缓存（主库 .pm\/vault-cache\/，display + sha 复用） ─────────────

-- | 上次比对的计数快照（pm status 不触 vault 也能报，同备份盘缓存性质）。
-- 键名由 Generic 派生（去 vm 前缀 + 全小写），非 legacy 兼容面。
data VaultCacheMeta = VaultCacheMeta
  { vmAt :: UTCTime
  , vmOk, vmNew, vmMissing, vmRenamed, vmDrift, vmDuplicate, vmUnpushable :: Int
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

-- | 取一个文件的 sha：stat 与缓存条目一致 → 复用；否则真实重读，并用
-- 双 stat 防撕裂（hash 期间文件在变就重来，三轮不稳则如实告警后采用
-- 末次结果且不入缓存）。返回 (sha, 可入缓存的条目)。
shaViaCache :: Map FilePath Entry -> FilePath -> FilePath -> IO (Text, Maybe Entry)
shaViaCache cache rel abs' = do
  pre <- statSnap abs'
  case Map.lookup rel cache of
    Just e
      | enSize e == ssSize pre && enMtimeNs e == ssMtimeNs pre ->
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
          else do
            putStrLn ("  ⚠ 文件在读取期间持续变化（结果按末次读取，不入缓存）: " <> abs')
            pure (sha, Nothing)

-- ─── 命令入口：pm vault status [--json] ─────────────────────────────────────

-- | 退出码与 legacy 同构：0 同步 \/ 1 有差异（duplicate、unpushable 不算）\/
-- 2 路径错误。
runVaultStatus :: Bool -> Config -> IO Int
runVaultStatus asJson cfg = case cfgVaultPath cfg of
  Nothing -> do
    putStrLn "配置无 vault 路径 → pm init --main <主库> --vault <展示集路径>（或手动补 config.toml 的 [vault] path）"
    pure 2
  Just vaultDir -> do
    let root = cfgMainPath cfg
        srcDir = root </> "相册"
    okSrc <- doesDirectoryExist srcDir
    okVault <- doesDirectoryExist vaultDir
    case (okSrc, okVault) of
      (False, _) -> putStrLn ("ERROR: source missing: " <> srcDir) >> pure 2
      (_, False) -> putStrLn ("ERROR: vault missing: " <> vaultDir) >> pure 2
      _ -> do
        (mcat, _) <- loadCatalog root
        mVCache <- readVaultCacheCatalog root
        let mainCache = maybe Map.empty catEntries mcat
            vaultCache = maybe Map.empty catEntries mVCache
            resolve cache rel abs' n = do
              (sha, me) <- shaViaCache cache rel abs'
              pure (n, sha, me)
        -- 源侧：平铺 相册\/，sha 优先复用主库 catalog（键 = 相册\名）
        (srcNames, srcSubdirs) <- listFlatPhotos srcDir
        srcTriples <- mapM (\n -> resolve mainCache ("相册" </> n) (srcDir </> n) n) srcNames
        -- vault 侧：固定三类目 + 未知目录告警
        (_, vaultTop) <- listFlatPhotos vaultDir
        let knownAux = ["_inbox", "_site", "scripts"]
            unknownDirs =
              [ dn
              | dn <- vaultTop
              , dn `notElem` fixedCategories
              , dn `notElem` knownAux
              , take 1 dn /= "."
              ]
        perCat <- mapM
          ( \cat -> do
              (names, subdirs) <- listFlatPhotos (vaultDir </> cat)
              unless asJson $
                mapM_ (\dn -> putStrLn ("  ⚠ vault 类目下有子目录（不递归）: " <> (cat </> dn))) subdirs
              ps <- mapM (\n -> resolve vaultCache (cat </> n) (vaultDir </> cat </> n) n) names
              pure (cat, ps)
          )
          fixedCategories
        unless asJson $ do
          mapM_ (\dn -> putStrLn ("  ⚠ vault 未知目录（未纳入比对）: " <> dn)) unknownDirs
          mapM_ (\dn -> putStrLn ("  ⚠ 相册下有子目录（平铺语义，不递归）: " <> dn)) srcSubdirs
        let srcShas = Map.fromList [(n, sha) | (n, sha, _) <- srcTriples]
            vaultShas = [(cat, Map.fromList [(n, sha) | (n, sha, _) <- ps]) | (cat, ps) <- perCat]
            d = vaultDiff srcShas vaultShas
            vaultCount = sum [Map.size m | (_, m) <- vaultShas]
            isPng n = map toLower (takeExtension n) == ".png"
            unpushable =
              [(n, "相册") | n <- srcNames, isPng n]
                <> [(n, cat) | (cat, ps) <- perCat, (n, _, _) <- ps, isPng n]
        -- 缓存回写（vault 侧条目 + 计数 meta；仅主库 .pm 下，I11 无涉）
        now <- getCurrentTime
        let vEntries = [e | (_, ps) <- perCat, (_, _, Just e) <- ps]
            meta =
              VaultCacheMeta
                { vmAt = now
                , vmOk = length (vdOk d)
                , vmNew = length (vdNew d)
                , vmMissing = length (vdMissing d)
                , vmRenamed = length (vdRenamed d)
                , vmDrift = length (vdDrift d)
                , vmDuplicate = length (vdDuplicate d)
                , vmUnpushable = length unpushable
                }
        writeVaultCache root (Catalog "vault-cache" now (entryMap vEntries)) meta
        if asJson
          then BSLC.putStrLn (renderVaultJson srcDir vaultDir (Map.size srcShas) vaultCount d unpushable)
          else renderHuman srcDir vaultDir (Map.size srcShas) vaultCount d unpushable
        pure (if hasDiff d then 1 else 0)

renderHuman ::
  FilePath -> FilePath -> Int -> Int -> VaultDiff -> [(FilePath, String)] -> IO ()
renderHuman srcDir vaultDir srcCount vaultCount d unpushable = do
  printf "vault 差异 · 相册 %s (%d) ↔ %s (%d)\n" srcDir srcCount vaultDir vaultCount
  printf
    "  OK %d · NEW %d · MISSING %d · RENAME %d · DRIFT %d · DUPLICATE %d · UNPUSHABLE %d\n"
    (length (vdOk d))
    (length (vdNew d))
    (length (vdMissing d))
    (length (vdRenamed d))
    (length (vdDrift d))
    (length (vdDuplicate d))
    (length unpushable)
  mapM_ (\n -> putStrLn ("  + NEW " <> n <> "  → 分类后拷入 vault（pm vault push，P3b）")) (vdNew d)
  mapM_ (\(n, c) -> putStrLn ("  - MISSING " <> c </> n <> "  → 决定保留还是撤（只报告）")) (vdMissing d)
  mapM_
    ( \(n, m, c, h) ->
        putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "' (" <> T.unpack (T.take 16 h) <> ")")
    )
    (vdRenamed d)
  mapM_
    ( \(n, c, sh, vh) ->
        putStrLn
          ("  ~ DRIFT " <> c </> n <> " (src " <> T.unpack (T.take 16 sh) <> " ≠ vault " <> T.unpack (T.take 16 vh) <> ")")
    )
    (vdDrift d)
  mapM_ (\(n, cats) -> putStrLn ("  ! DUPLICATE " <> n <> " → " <> unwords cats)) (vdDuplicate d)
  mapM_
    (\(n, loc) -> putStrLn ("  ✋ UNPUSHABLE " <> loc </> n <> "（.png：status 可见，push 写路径拒收）"))
    unpushable
