{-# LANGUAGE OverloadedStrings #-}

-- | `pm vault` 的纯核心（零 IO），三十四轮从 Pm.Vault 拆出（原文件触 750 行
-- 硬预算）：六态 diff 的 legacy 逐行复刻与 JSON 渲染。语义基线仍是
-- docs\/specs\/sync-photos-legacy-spec.md；外部调用方一律经 Pm.Vault 的再导出，
-- 拆分不改变任何行为（搬移为字节级，零语义改动）。
module Pm.VaultCore
  ( VaultDiff (..)
  , vaultDiff
  , fixedCategories
  , photoExtFold
  , pushableExt
  , convertibleExt
  , renderVaultJson
  ) where

import Data.Aeson (pairs)
import qualified Data.Aeson.Encoding as AE
import qualified Data.ByteString.Lazy as BSL
import Data.Char (toLower)
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (takeExtension)

import Pm.Types (renderExts)

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

-- | 转换对象（P8-C2；步 9 簇 C）：'renderExts' 里 jpg 之外的已渲染位图。RAW
-- 与 jpg 都不是。归档页「非 jpg」栏（'Pm.Album.albumCandidates'）与
-- @pm convert@ 的准入（'Pm.Convert.runConvertTo'）共用这一个谓词——此前两处
-- 各写各的，候选栏把 RAW 列成「非 jpg」而 convert 拒收 RAW，勾上一张就整批中止。
convertibleExt :: FilePath -> Bool
convertibleExt p = not (pushableExt p) && map toLower (takeExtension p) `elem` renderExts

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

-- ─── JSON 渲染（键名、键序、值形状 = legacy；末尾追加 unpushable） ──────────

renderVaultJson ::
  FilePath ->
  FilePath ->
  Int ->
  Int ->
  VaultDiff ->
  [(FilePath, String)] ->
  [(FilePath, String)] ->
  [(FilePath, Text)] ->
  [(FilePath, String)] ->
  BSL.ByteString
renderVaultJson srcDir vaultDir srcCount vaultCount d unpushable unstable held heldStale =
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
      -- pm 第九态（P4-7 用户裁定）：决定「暂不同步」的 NEW（仍在 new 键里，
      -- 六态集合不受影响；held 是它的注解子集，不进 vault、不算"有事可做"）
      <> AE.pair "held" (AE.list (\(n, h) -> AE.list id [AE.string n, AE.text (T.take 16 h)]) held)
      -- 决定已失效（照片字节变了 / 已不在 NEW）：回到 NEW 处理，只报告
      <> AE.pair "held_stale" (AE.list pairNC heldStale)
 where
  pairNC (n, c) = AE.list id [AE.string n, AE.string c]
