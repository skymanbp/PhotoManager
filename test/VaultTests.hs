{-# LANGUAGE OverloadedStrings #-}

-- | P3a：pm vault status 的六态核心、JSON 兼容形状与 IO 端语义
-- （基线：docs\/specs\/sync-photos-legacy-spec.md）。
module VaultTests (vaultTests) where

import Data.Aeson (decode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..))
import Pm.Vault

vaultTests :: TestTree
vaultTests =
  testGroup
    "P3a vault status"
    [ testCase "六态基本分类（ok/new/missing/rename/drift）" caseSixStates
    , testCase "DUPLICATE 与 ok/drift 重叠，不构成划分，也不算差异" caseDuplicateOverlap
    , testCase "RENAME 贪心首配：一个 NEW 只消费一个 MISSING（类目序优先）" caseGreedyFirstFit
    , testCase "RENAME 短路：任一侧候选为空则不做配对" caseRenameShortCircuit
    , testCase "vault-only 跨类目重复：两条 MISSING，不标 DUPLICATE" caseVaultOnlyDup
    , testCase "JSON 值形状 = legacy 六键 + unpushable（hash 截 16）" caseJsonShape
    , testCase "JSON 键序与 legacy 一致（unpushable 殿后）" caseJsonKeyOrder
    , testCase "IO：全同步 → exit 0；.png 只入 NEW 不改退出码语义" caseIoInSync
    , testCase "IO：NEW（含 .Jpg case-fold 收录）→ exit 1" caseIoNewExit1
    , testCase "IO：源目录缺失 → exit 2" caseIoMissingSource
    , testCase "IO：vault 文件字节改动 → 二跑经缓存复验报 DRIFT" caseIoCacheDrift
    ]

h :: Char -> Text
h c = T.replicate 64 (T.singleton c)

-- ─── 纯核心 ─────────────────────────────────────────────────────────────────

caseSixStates :: IO ()
caseSixStates = do
  let src = Map.fromList [("a.jpg", h 'a'), ("b.jpg", h 'b'), ("c.jpg", h 'c'), ("d.jpg", h 'd')]
      vault =
        [ ("landscape", Map.fromList [("a.jpg", h 'a'), ("c.jpg", h 'x')])
        , ("portrait", Map.fromList [("e.jpg", h 'd'), ("f.jpg", h 'f')])
        , ("urban", Map.empty)
        ]
      d = vaultDiff src vault
  vdOk d @?= [("a.jpg", "landscape")]
  vdNew d @?= ["b.jpg"]
  vdMissing d @?= [("f.jpg", "portrait")]
  vdRenamed d @?= [("d.jpg", "e.jpg", "portrait", h 'd')]
  vdDrift d @?= [("c.jpg", "landscape", h 'c', h 'x')]
  vdDuplicate d @?= []

caseDuplicateOverlap :: IO ()
caseDuplicateOverlap = do
  -- 同名两类目：一份同 sha（ok）一份不同（drift）→ duplicate 与两者共存
  let src = Map.fromList [("a.jpg", h 'a')]
      d =
        vaultDiff
          src
          [ ("landscape", Map.fromList [("a.jpg", h 'a')])
          , ("portrait", Map.empty)
          , ("urban", Map.fromList [("a.jpg", h 'z')])
          ]
  vdDuplicate d @?= [("a.jpg", ["landscape", "urban"])]
  vdOk d @?= [("a.jpg", "landscape")]
  vdDrift d @?= [("a.jpg", "urban", h 'a', h 'z')]
  -- 纯 duplicate（两份都同 sha）：六态无差异 → 退出码 0 语义（legacy :237）
  let d2 =
        vaultDiff
          src
          [ ("landscape", Map.fromList [("a.jpg", h 'a')])
          , ("portrait", Map.fromList [("a.jpg", h 'a')])
          , ("urban", Map.empty)
          ]
  vdDuplicate d2 @?= [("a.jpg", ["landscape", "portrait"])]
  vdNew d2 @?= []
  vdMissing d2 @?= []
  vdDrift d2 @?= []

caseGreedyFirstFit :: IO ()
caseGreedyFirstFit = do
  -- vault 同名同 sha 出现在两个类目、主源只有一个改名后的 NEW：
  -- 首配吃掉类目序第一个（landscape），urban 那份仍报 MISSING（legacy :127-138）
  let src = Map.fromList [("renamed.jpg", h 's')]
      d =
        vaultDiff
          src
          [ ("landscape", Map.fromList [("old.jpg", h 's')])
          , ("portrait", Map.empty)
          , ("urban", Map.fromList [("old.jpg", h 's')])
          ]
  vdRenamed d @?= [("renamed.jpg", "old.jpg", "landscape", h 's')]
  vdMissing d @?= [("old.jpg", "urban")]
  vdNew d @?= []

caseRenameShortCircuit :: IO ()
caseRenameShortCircuit = do
  let d = vaultDiff (Map.fromList [("n.jpg", h 'n')]) [("landscape", Map.empty), ("portrait", Map.empty), ("urban", Map.empty)]
  vdRenamed d @?= []
  vdNew d @?= ["n.jpg"]

caseVaultOnlyDup :: IO ()
caseVaultOnlyDup = do
  -- 主源没有该名字 → 走 MISSING 通路，DUPLICATE 不标（legacy 定义不一致，
  -- 兼容面按 legacy 保留；规范 §6 修复项 4 留给 push 侧处理）
  let d =
        vaultDiff
          Map.empty
          [ ("landscape", Map.fromList [("x.jpg", h 'x')])
          , ("portrait", Map.fromList [("x.jpg", h 'x')])
          , ("urban", Map.empty)
          ]
  vdDuplicate d @?= []
  vdMissing d @?= [("x.jpg", "landscape"), ("x.jpg", "portrait")]

-- ─── JSON 兼容 ──────────────────────────────────────────────────────────────

sampleDiff :: VaultDiff
sampleDiff =
  vaultDiff
    (Map.fromList [("a.jpg", h 'a'), ("b.jpg", h 'b'), ("d.jpg", h 'd'), ("p.png", h 'p')])
    [ ("landscape", Map.fromList [("a.jpg", h 'a'), ("dd.jpg", h 'd'), ("q.png", h 'q')])
    , ("portrait", Map.fromList [("a.jpg", h 'z')])
    , ("urban", Map.empty)
    ]

sampleJson :: BSLC.ByteString
sampleJson =
  renderVaultJson
    "D:\\Photography\\相册"
    "V:\\vault\\摄影作品"
    4
    3
    sampleDiff
    [("p.png", "相册"), ("q.png", "landscape")]

caseJsonShape :: IO ()
caseJsonShape = do
  let expected =
        object
          [ "source_dir" .= ("D:\\Photography\\相册" :: String)
          , "vault_dir" .= ("V:\\vault\\摄影作品" :: String)
          , "source_count" .= (4 :: Int)
          , "vault_count" .= (3 :: Int)
          , "ok" .= [["a.jpg", "landscape"] :: [String]]
          , "new" .= (["b.jpg", "p.png"] :: [String])
          , "missing" .= [["q.png", "landscape"] :: [String]]
          , "renamed" .= [[T.unpack "d.jpg", "dd.jpg", "landscape", T.unpack (T.take 16 (h 'd'))]]
          , "drift"
              .= [["a.jpg", "portrait", T.unpack (T.take 16 (h 'a')), T.unpack (T.take 16 (h 'z'))]]
          , "duplicate"
              .= [toJSON [toJSON ("a.jpg" :: String), toJSON (["landscape", "portrait"] :: [String])]]
          , "unpushable" .= [["p.png", "相册"] :: [String], ["q.png", "landscape"]]
          ]
  decode sampleJson @?= Just expected

caseJsonKeyOrder :: IO ()
caseJsonKeyOrder = do
  let s = BSLC.unpack sampleJson
      legacyOrder =
        [ "\"source_dir\""
        , "\"vault_dir\""
        , "\"source_count\""
        , "\"vault_count\""
        , "\"ok\""
        , "\"new\""
        , "\"missing\""
        , "\"renamed\""
        , "\"drift\""
        , "\"duplicate\""
        , "\"unpushable\""
        ]
      posOf needle = length (fst (breakOn needle s))
      breakOn needle hay = go [] hay
       where
        go acc rest
          | needle `isInfixOf` take (length needle) rest || null rest = (reverse acc, rest)
          | otherwise = case rest of
              (c : cs) -> go (c : acc) cs
              [] -> (reverse acc, [])
      positions = map posOf legacyOrder
  assertBool ("键序漂移: " <> show (zip legacyOrder positions)) (and (zipWith (<) positions (drop 1 positions)))

-- ─── IO 端 ──────────────────────────────────────────────────────────────────

mkVaultCfg :: FilePath -> FilePath -> Config
mkVaultCfg root vdir =
  Config
    { cfgMainPath = root
    , cfgVaultPath = Just vdir
    , cfgPhotosJson = Nothing
    , cfgWorkers = Nothing
    , cfgBackupId = Nothing
    , cfgBackupSubpath = Nothing
    }

writeF :: FilePath -> String -> IO ()
writeF fp s = createDirectoryIfMissing True (takeDirectory fp) >> writeFile fp s

caseIoInSync :: IO ()
caseIoInSync = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  writeF (root </> "相册" </> "a.jpg") "AAA"
  writeF (vdir </> "landscape" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "portrait")
  createDirectoryIfMissing True (vdir </> "urban")
  code <- runVaultStatus False (mkVaultCfg root vdir)
  code @?= 0

caseIoNewExit1 :: IO ()
caseIoNewExit1 = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  -- .Jpg 混合大小写扩展名：legacy 会静默丢弃，pm case-fold 收录（有意偏离）
  writeF (root </> "相册" </> "x.Jpg") "XXX"
  createDirectoryIfMissing True (vdir </> "landscape")
  code <- runVaultStatus False (mkVaultCfg root vdir)
  code @?= 1

caseIoMissingSource :: IO ()
caseIoMissingSource = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  createDirectoryIfMissing True (vdir </> "landscape")
  createDirectoryIfMissing True root -- 相册 子目录不存在
  code <- runVaultStatus False (mkVaultCfg root vdir)
  code @?= 2

caseIoCacheDrift :: IO ()
caseIoCacheDrift = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  writeF (root </> "相册" </> "a.jpg") "AAA"
  writeF (vdir </> "landscape" </> "a.jpg") "AAA"
  code1 <- runVaultStatus False (mkVaultCfg root vdir)
  code1 @?= 0
  -- vault 侧字节改动（大小也变 → stat 复验必然发现）→ 第二跑重 hash 报 DRIFT
  writeF (vdir </> "landscape" </> "a.jpg") "AAAA"
  code2 <- runVaultStatus False (mkVaultCfg root vdir)
  code2 @?= 1
  mv <- readVaultCacheMeta root
  case mv of
    Nothing -> assertFailure "vault-cache meta 未写入"
    Just m -> do
      vmDrift m @?= 1
      vmOk m @?= 0
