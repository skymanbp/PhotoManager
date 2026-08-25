{-# LANGUAGE OverloadedStrings #-}

-- | P3a：pm vault status 的六态核心、JSON 兼容形状与 IO 端语义
-- （基线：docs\/specs\/sync-photos-legacy-spec.md）。
module VaultTests (vaultTests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import Data.Aeson (decode, encode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeFile, setModificationTime)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Time (addUTCTime, getCurrentTime)
import Pm.Catalog (saveCatalog)
import Pm.Cli (bindExecRoot, executePlanNow)
import Pm.Commands (resolveKeep)
import Pm.Config (Config (..), writeRootInfo)
import Pm.Hash (StatSnap (..), nsToUtc, sha256File, statHitStable, statSnap)
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Types (Entry (..), FileKind (..), RootInfo (..), RootRole (..))
import Pm.Vault
import Pm.VaultCmd (runVaultHold)
import Pm.VaultHold (VaultHold (..), readHolds)
import TestUtil (mkCat, t0)

vaultTests :: TestTree
vaultTests =
  testGroup
    "P3 vault"
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
    , testCase "P3b I11：git 树无 .pm/ ignore 行 → ensureVaultRoot fail-closed" casePushI11
    , testCase "P3b push：NEW+--category 端到端落位 → 复检 OK" casePushNewLands
    , testCase "P3b push：.png / 非 NEW / 缺 --category 全部拒绝 exit 2" casePushRefusals
    , testCase "P3b push：DRIFT→NEEDS-DECISION→keep src→supersede→旧字节在 vault trash" casePushDriftSupersede
    , testCase "P3b bindExecRoot：vault 计划按 UUID 绑回配置路径" caseBindVaultRoot
    , testCase "P3b gitStepsLines/planCategories：显式类目、无 -A、隔离项不入 add" caseGitSteps
    , testCase "P3b-4 #2 守卫：.git 文件/祖先仓/反规则 全 fail-closed" caseGuardVariants
    , testCase "P3b-4 #3 apply 执行期重检 I11：ignore 行被移除 → 整批拒绝零写入" caseApplyI11Recheck
    , testCase "P3b-4 #6 bindExecRoot：UUID 多重命中/role 不符 拒绝绑定" caseBindAmbiguity
    , testCase "P3b-4 #4 缓存身份绑定：vault 换路径后 (size,mtime) 巧合不复用 sha" caseCacheIdentitySwap
    , testCase "P3b-4 #4 racy 判据 statHitStable：同刻度窗口不信任缓存" caseRacyGuard
    , testCase "P4-7 hold：NEW 标暂不同步 → 移出 newActive、exit 0、push 拒收；非法操作 exit 2；unhold 恢复" caseHoldRoundTrip
    , testCase "P4-7 hold：照片字节换了 → 决定失效，回到 NEW 并报 stale" caseHoldStale
    , testCase "P4-7 hold 复核不吃缓存快路：等长替换 + 还原 mtime（stat 命中）仍判失效" caseHoldStaleEqualLen
    , testCase "P4-7 hold 是跨进程事务：root lock 被占用 → 拒绝而不是覆盖名单" caseHoldLock
    , testCase "P4-7 名单 fail-closed：残留 .tmp 而正文缺失 / 同名两条 → 拒绝，不当空名单" caseHoldFileGuards
    , testCase "P4-7 held-only：无参 vault push 与 status 都不再报「有事可做」" caseHoldOnlyExit
    , testCase "P4-7 决定的**创建**也不吃缓存：陈旧 catalog 下 hold 记的是盘上真实 sha，下一轮仍生效" caseHoldCreateFreshSha
    , testCase "P4-7 取锁前预检：匿名主库 hold 被拒且 .pm/lock 零写入" caseHoldPreflightNoWrite
    ]

h :: Char -> Text
h c = T.replicate 64 (T.singleton c)

-- | P4-7「暂不同步」：决定只写主库 .pm，vault 与照片零改动，可撤销。
caseHoldRoundTrip :: IO ()
caseHoldRoundTrip = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  c1 <- runVaultStatus False cfg
  c1 @?= 1 -- 一张 NEW → 有事可做
  -- 非 NEW 的名字不能标；不在名单里的不能撤
  runVaultHold True ["ghost.jpg"] cfg >>= (@?= 2)
  runVaultHold False ["a.jpg"] cfg >>= (@?= 2)
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  c2 <- runVaultStatus False cfg
  c2 @?= 0 -- 已决定不同步 → 不再报"有事可做"
  er <- computeVault True cfg
  case er of
    Left (m, _) -> assertFailure ("computeVault: " <> m)
    Right r -> do
      map fst (vrHeld r) @?= ["a.jpg"]
      newActive r @?= []
      vdNew (vrDiff r) @?= ["a.jpg"] -- 六态集合是对外契约，不因决定而变
      case checkAssignments r [("landscape", "a.jpg")] of
        [] -> assertFailure "被 hold 的文件不该能直接 push"
        (e : _) -> assertBool ("错误应说明暂不同步: " <> e) ("暂不同步" `isInfixOf` e)
  -- vault 侧零改动
  doesFileExist (vdir </> "landscape" </> "a.jpg") >>= (@?= False)
  runVaultHold False ["a.jpg"] cfg >>= (@?= 0)
  runVaultStatus False cfg >>= (@?= 1)

-- | 复核**不能**吃 (size,mtime) 缓存快路：等长替换 + 还原 mtime 时，主库
-- catalog 的 stat 命中会让 'shaViaCache' 复用旧 sha，旧决定就继续压住新字节
-- （codex 二十一轮 major）。这里刻意造一条会命中的 catalog 条目。
caseHoldStaleEqualLen :: IO ()
caseHoldStaleEqualLen = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
      jpg = root </> "相册" </> "a.jpg"
  mkMain root
  writeF jpg "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  -- 造一条必然 statHitStable 的主库 catalog 条目（sha 是旧的）
  snap <- statSnap jpg
  oldSha <- sha256File jpg
  saveCatalog
    root
    ( mkCat
        [ Entry
            ("相册" </> "a.jpg")
            (ssSize snap)
            (ssMtimeNs snap)
            oldSha
            KindPhoto
            (Just (addUTCTime 3600 (nsToUtc (ssMtimeNs snap))))
        ]
    )
  -- 等长替换 + 还原 mtime：(size,mtime) 完全不变
  writeF jpg "BBB"
  setModificationTime jpg (nsToUtc (ssMtimeNs snap))
  er <- computeVault True cfg
  case er of
    Left (m, _) -> assertFailure ("computeVault: " <> m)
    Right r -> do
      vrHeld r @?= [] -- 决定必须失效
      map fst (vrHeldStale r) @?= ["a.jpg"]
      newActive r @?= ["a.jpg"]

-- | 名单的读改写是**跨进程**事务（I10）：root lock 被别的 pm 占着时必须拒绝，
-- 而不是各读各的旧名单、后写者整份覆盖先写者（codex 二十一轮 major）。
caseHoldLock :: IO ()
caseHoldLock = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  writeF (root </> "相册" </> "b.jpg") "BBB"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  gotLock <- newEmptyMVar
  release <- newEmptyMVar
  void . forkIO . void $ withRootLock root (putMVar gotLock () >> takeMVar release)
  takeMVar gotLock
  code <- runVaultHold True ["b.jpg"] cfg
  putMVar release ()
  code @?= 2 -- 拒绝
  hs <- readHolds root
  case hs of
    Left m -> assertFailure ("readHolds: " <> m)
    Right kept -> map vhName kept @?= ["a.jpg"] -- 名单没被覆盖

-- | 名单文件本身的 fail-closed：覆盖写崩在删旧与 rename 之间会留下 .tmp 而
-- 正文缺失——按"空名单"继续等于把用户的决定静默清零；同名两条也直接拒绝。
caseHoldFileGuards :: IO ()
caseHoldFileGuards = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
      holds = root </> ".pm" </> "vault-holds.json"
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  -- 崩在中途的形态：正文没了，.tmp 还在
  hsBytes <- BSLC.readFile holds
  BSLC.writeFile (holds <> ".tmp") hsBytes
  removeFile holds
  readHolds root >>= \r -> case r of
    Left m -> assertBool ("应点名 .tmp: " <> m) (".tmp" `isInfixOf` m)
    Right _ -> assertFailure "残留 .tmp 而正文缺失时不得按空名单处理"
  runVaultStatus False cfg >>= (@?= 2)
  removeFile (holds <> ".tmp")
  -- 同名两条（手编）→ 拒绝
  now <- getCurrentTime
  BSLC.writeFile holds (encode [VaultHold "a.jpg" (T.replicate 64 "a") now Nothing, VaultHold "a.jpg" (T.replicate 64 "b") now Nothing])
  readHolds root >>= \r -> case r of
    Left m -> assertBool ("应点名重复: " <> m) ("多次" `isInfixOf` m)
    Right _ -> assertFailure "同名两条必须拒绝"
  -- 路径型 name（手编）→ 拒绝
  BSLC.writeFile holds (encode [VaultHold ("sub" </> "a.jpg") (T.replicate 64 "a") now Nothing])
  readHolds root >>= \r -> case r of
    Left m -> assertBool ("应点名平铺文件名: " <> m) ("平铺" `isInfixOf` m)
    Right _ -> assertFailure "带路径的 name 必须拒绝"
  -- sha 不是 64 位 hex → 拒绝
  BSLC.writeFile holds (encode [VaultHold "a.jpg" "zz" now Nothing])
  readHolds root >>= \r -> case r of
    Left m -> assertBool ("应点名 sha: " <> m) ("hex" `isInfixOf` m)
    Right _ -> assertFailure "坏 sha 必须拒绝"

-- | 决定的**创建**同样不能吃缓存快路：二十一轮只把"复核"改成强制重 hash，
-- 创建仍从 'vrSrcMeta' 取 catalog 缓存 sha——于是 hold 会记下陈旧 sha，下一轮
-- 复核立刻判失效，决定根本落不住（codex 二十二轮 major）。
caseHoldCreateFreshSha :: IO ()
caseHoldCreateFreshSha = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
      jpg = root </> "相册" </> "a.jpg"
  mkMain root
  writeF jpg "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  snap <- statSnap jpg
  staleSha <- sha256File jpg
  -- 盘上等长替换 + 还原 mtime：catalog 的 (size,mtime) 仍然命中
  writeF jpg "BBB"
  setModificationTime jpg (nsToUtc (ssMtimeNs snap))
  realSha <- sha256File jpg
  assertBool "构造前提：两个 sha 必须不同" (staleSha /= realSha)
  saveCatalog
    root
    ( mkCat
        [ Entry
            ("相册" </> "a.jpg")
            (ssSize snap)
            (ssMtimeNs snap)
            staleSha
            KindPhoto
            (Just (addUTCTime 3600 (nsToUtc (ssMtimeNs snap))))
        ]
    )
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  hs <- readHolds root
  case hs of
    Left m -> assertFailure ("readHolds: " <> m)
    Right kept -> map vhSha kept @?= [realSha] -- 记的是盘上真实 sha
  -- 决定必须**立刻生效**并保持生效（旧实现会当场判 stale）
  er <- computeVault True cfg
  case er of
    Left (m, _) -> assertFailure ("computeVault: " <> m)
    Right r -> do
      map fst (vrHeld r) @?= ["a.jpg"]
      vrHeldStale r @?= []
  runVaultStatus False cfg >>= (@?= 0)

-- | 身份预检必须在**取锁之前**：'withRootLock' 会建 @.pm@ 并打开 @.pm/lock@，
-- 匿名 / I11 失效的 root 若先取锁再校验，就会在被拒之前先落下一个锁文件
-- （codex 二十二轮 major；与 'Pm.Exec' 的"取锁前预检"同一原则）。
caseHoldPreflightNoWrite :: IO ()
caseHoldPreflightNoWrite = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  createDirectoryIfMissing True (root </> "相册") -- 有库、但**没有 root 标识**
  writeF (root </> "相册" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultHold True ["a.jpg"] cfg >>= (@?= 2)
  doesDirectoryExist (root </> ".pm") >>= (@?= False)
  doesFileExist (root </> ".pm" </> "lock") >>= (@?= False)

-- | 只剩已决定不同步的 NEW 时，status 与无参 push 都该报"没事可做"。
caseHoldOnlyExit :: IO ()
caseHoldOnlyExit = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  runVaultStatus False cfg >>= (@?= 0)
  runVaultPush (execNow cfg) Nothing [] cfg >>= (@?= 0)

-- | 决定记的是「当时那张」：字节换了就失效，照片回到 NEW（宁可多问一次）。
caseHoldStale :: IO ()
caseHoldStale = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultHold True ["a.jpg"] cfg >>= (@?= 0)
  writeF (root </> "相册" </> "a.jpg") "AAAA" -- 重修图/重导出
  er <- computeVault True cfg
  case er of
    Left (m, _) -> assertFailure ("computeVault: " <> m)
    Right r -> do
      vrHeld r @?= []
      newActive r @?= ["a.jpg"]
      map fst (vrHeldStale r) @?= ["a.jpg"]
  runVaultStatus False cfg >>= (@?= 1)

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

-- 路径只是 JSON 值形状样本（占位盘符，不指向真实档案 vault）。
sampleJson :: BSLC.ByteString
sampleJson =
  renderVaultJson
    "D:\\Photography\\相册"
    "V:\\vault\\摄影作品"
    4
    3
    sampleDiff
    [("p.png", "相册"), ("q.png", "landscape")]
    [("w.jpg", "urban")]
    [("b.jpg", h 'b')]
    [("gone.jpg", "已不在 NEW")]

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
          , "unstable" .= [["w.jpg", "urban"] :: [String]]
          , "held" .= [["b.jpg", T.unpack (T.take 16 (h 'b'))] :: [String]]
          , "held_stale" .= [["gone.jpg", "已不在 NEW"] :: [String]]
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
        , "\"unstable\""
        , "\"held\""
        , "\"held_stale\""
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

-- | 主库 root 标识（P3b-6 复审 B1：computeVault 以主库身份读 相册/写 vault-cache，
-- 缺 RoleMain 标识 → exit 2；IO 用例先建标识）。
mkMain :: FilePath -> IO ()
mkMain root = writeRootInfo root (RootInfo "main-rid" RoleMain t0 Nothing)

caseIoInSync :: IO ()
caseIoInSync = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  writeF (vdir </> "landscape" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "portrait")
  createDirectoryIfMissing True (vdir </> "urban")
  code <- runVaultStatus False (mkVaultCfg root vdir)
  code @?= 0

caseIoNewExit1 :: IO ()
caseIoNewExit1 = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  mkMain root
  -- .Jpg 混合大小写扩展名：legacy 会静默丢弃，pm case-fold 收录（有意偏离）
  writeF (root </> "相册" </> "x.Jpg") "XXX"
  createDirectoryIfMissing True (vdir </> "landscape")
  code <- runVaultStatus False (mkVaultCfg root vdir)
  code @?= 1

caseIoMissingSource :: IO ()
caseIoMissingSource = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  createDirectoryIfMissing True (vdir </> "landscape")
  mkMain root -- root 有标识，但 相册 子目录不存在
  code <- runVaultStatus False (mkVaultCfg root vdir)
  code @?= 2

caseIoCacheDrift :: IO ()
caseIoCacheDrift = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  writeF (vdir </> "landscape" </> "a.jpg") "AAA"
  code1 <- runVaultStatus False (mkVaultCfg root vdir)
  code1 @?= 0
  -- vault 侧字节改动（大小也变 → stat 复验必然发现）→ 第二跑重 hash 报 DRIFT
  writeF (vdir </> "landscape" </> "a.jpg") "AAAA"
  code2 <- runVaultStatus False (mkVaultCfg root vdir)
  code2 @?= 1
  -- P3b-15：readVaultCacheMeta 三态（Left=失信、Right Nothing=缺席）
  mv <- readVaultCacheMeta root
  case mv of
    Left m -> assertFailure ("vault-cache meta 不可信: " <> m)
    Right Nothing -> assertFailure "vault-cache meta 未写入"
    Right (Just m) -> do
      vmDrift m @?= 1
      vmOk m @?= 0

-- ─── P3b push ───────────────────────────────────────────────────────────────

-- | 立即执行的 runPlan（测试用：跳过交互确认，仍走完整 Exec 内核）。
execNow :: Config -> Plan -> IO Int
execNow cfg p = savePlan p >> executePlanNow cfg p

casePushI11 :: IO ()
casePushI11 = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let vdir = tmp </> "vault"
  createDirectoryIfMissing True (vdir </> ".git") -- 模拟 git 工作树
  writeF (vdir </> ".gitignore") "_inbox/\n"
  er <- ensureVaultRoot vdir
  case er of
    Left msg -> assertBool "错误应点名 I11" ("I11" `isInfixOf` msg)
    Right _ -> assertFailure "缺 .pm/ ignore 行时不应建 root"
  -- 补上 .pm/ 行 → 建立成功且幂等
  writeF (vdir </> ".gitignore") "_inbox/\n.pm/\n"
  er2 <- ensureVaultRoot vdir
  case er2 of
    Left m -> assertFailure ("应建 root: " <> m)
    Right info -> do
      riRole info @?= RoleVault
      er3 <- ensureVaultRoot vdir
      fmap riId er3 @?= Right (riId info)

casePushNewLands :: IO ()
casePushNewLands = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  createDirectoryIfMissing True (vdir </> "landscape")
  code <- runVaultPush (execNow (mkVaultCfg root vdir)) (Just "landscape") ["a.jpg"] (mkVaultCfg root vdir)
  code @?= 0
  landed <- readFile (vdir </> "landscape" </> "a.jpg")
  landed @?= "AAA"
  -- 复检：push 后 a.jpg 应为 OK，NEW 清空
  code2 <- runVaultStatus False (mkVaultCfg root vdir)
  code2 @?= 0

casePushRefusals :: IO ()
casePushRefusals = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "p.png") "PNG"
  writeF (root </> "相册" </> "ok.jpg") "OK"
  writeF (vdir </> "landscape" </> "ok.jpg") "OK"
  cPng <- runVaultPush (execNow cfg) (Just "landscape") ["p.png"] cfg
  cPng @?= 2
  pngLanded <- doesFileExist (vdir </> "landscape" </> "p.png")
  pngLanded @?= False
  cNotNew <- runVaultPush (execNow cfg) (Just "landscape") ["ok.jpg"] cfg
  cNotNew @?= 2
  cNoCat <- runVaultPush (execNow cfg) Nothing ["p.png"] cfg
  cNoCat @?= 2
  cBadCat <- runVaultPush (execNow cfg) (Just "scenery") ["p.png"] cfg
  cBadCat @?= 2

casePushDriftSupersede :: IO ()
casePushDriftSupersede = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "d.jpg") "NEWBYTES"
  writeF (vdir </> "landscape" </> "d.jpg") "OLDBYTES"
  ref <- newIORef Nothing
  let capture p = savePlan p >> writeIORef ref (Just p) >> pure 1
  _ <- runVaultPush capture Nothing [] cfg
  mplan <- readIORef ref
  plan <- maybe (assertFailure "DRIFT 应生成计划" >> undefined) pure mplan
  case plItems plan of
    [it] -> do
      case piStatus it of
        StNeedsDecision _ -> pure ()
        st -> assertFailure ("DRIFT 项应为 NEEDS-DECISION，得到 " <> show st)
      -- keep src → supersede 组（旧目标先隔离再落源）
      rc <- resolveKeep plan it "src"
      rc @?= 0
      eplan <- loadPlan vdir (plId plan)
      plan' <- either (\e -> assertFailure e >> undefined) pure eplan
      code <- executePlanNow cfg plan'
      code @?= 0
      landed <- readFile (vdir </> "landscape" </> "d.jpg")
      landed @?= "NEWBYTES"
      -- 旧字节必须还在 vault 自己的 .pm/trash 里
      trashed <- findFileUnder (vdir </> ".pm" </> "trash") "d.jpg"
      case trashed of
        Nothing -> assertFailure "旧字节不在 vault trash"
        Just fp -> readFile fp >>= (@?= "OLDBYTES")
    its -> assertFailure ("计划应恰含 1 个 DRIFT 项，得到 " <> show (length its))

caseBindVaultRoot :: IO ()
caseBindVaultRoot = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"; vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  createDirectoryIfMissing True root
  createDirectoryIfMissing True vdir
  einfo <- ensureVaultRoot vdir
  info <- either (\e -> assertFailure e >> undefined) pure einfo
  pid <- newPlanId
  let plan =
        Plan
          { plId = pid
          , plKind = "vault-push"
          , plRootPath = tmp </> "stale-mount" -- 故意给过期路径
          , plRootId = Just (riId info)
          , plCreated = riCreated info
          , plItems = []
          }
  eb <- bindExecRoot cfg plan (riId info)
  case eb of
    Left e -> assertFailure ("应绑定到 vault: " <> e)
    Right p' -> plRootPath p' @?= vdir

caseGitSteps :: IO ()
caseGitSteps = do
  let quar = PlanItem 0 (OpQuarantine ("landscape" </> "x.jpg") "s" "supersede") StPending (Just 1)
      copy1 = PlanItem 1 (OpCopy "src1" ("landscape" </> "x.jpg") "s" 1 0) StPending (Just 1)
      copy2 = PlanItem 2 (OpCopy "src2" ("urban" </> "y.jpg") "s" 1 0) StPending Nothing
      plan = Plan "pid" "vault-push" "V:\\vault" (Just "rid") t0' [quar, copy1, copy2]
      cats = planCategories plan
  cats @?= ["landscape", "urban"]
  let ls = gitStepsLines "V:\\vault" "pid" cats
      cmdLines = filter (isInfixOf "git ") (drop 1 ls) -- 首行是含「禁止 -A」字样的警示语，不是命令
  assertBool "git add 行显式列类目" ("    git add landscape urban" `elem` ls)
  assertBool "命令行无 -A / 无裸 git add ." (not (any (\l -> "-A" `isInfixOf` l || "add ." `isInfixOf` l) cmdLines))
 where
  t0' = read "2026-01-01 00:00:00 UTC"

-- ─── P3b-4（codex 评审修复） ────────────────────────────────────────────────

caseGuardVariants :: IO ()
caseGuardVariants = withSystemTempDirectory "pm-vault" $ \tmp -> do
  -- ① .git 是普通文件（worktree/submodule 链接）→ 同样算 git 语境
  let v1 = tmp </> "v1"
  createDirectoryIfMissing True v1
  writeF (v1 </> ".git") "gitdir: ../repo/.git/worktrees/v1\n"
  g1 <- vaultIgnoreGuard v1
  assertBool ".git 文件应触发 I11" (either ("I11" `isInfixOf`) (const False) g1)
  -- ② 反规则：`.pm/` 行存在但另有 `!.pm/` → 拒绝；`!.PM/` 大小写变体同样
  --    拒绝（Windows 默认 core.ignorecase，P3b-5 复审 #2）
  let v2 = tmp </> "v2"
  createDirectoryIfMissing True (v2 </> ".git")
  writeF (v2 </> ".gitignore") ".pm/\n!.pm/\n"
  g2 <- vaultIgnoreGuard v2
  assertBool "反规则应拒绝" (either ("反规则" `isInfixOf`) (const False) g2)
  writeF (v2 </> ".gitignore") ".pm/\n!.PM/\n"
  g2b <- vaultIgnoreGuard v2
  assertBool "大写反规则应拒绝" (either ("反规则" `isInfixOf`) (const False) g2b)
  -- ③ 祖先仓：父链上有 .git、vault 自身不是仓根 → 拒绝
  let anc = tmp </> "repo"
      v3 = anc </> "sub" </> "vault"
  createDirectoryIfMissing True (anc </> ".git")
  createDirectoryIfMissing True v3
  g3 <- vaultIgnoreGuard v3
  assertBool "祖先仓应拒绝" (either ("上层 git" `isInfixOf`) (const False) g3)
  -- ④ 合规：.git 目录 + 恰有 `.pm/` 行、无反规则 → 放行
  let v4 = tmp </> "v4"
  createDirectoryIfMissing True (v4 </> ".git")
  writeF (v4 </> ".gitignore") "_site/\n.pm/\n"
  g4 <- vaultIgnoreGuard v4
  g4 @?= Right ()

caseApplyI11Recheck :: IO ()
caseApplyI11Recheck = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "n.jpg") "NN"
  createDirectoryIfMissing True (vdir </> "landscape")
  createDirectoryIfMissing True (vdir </> ".git")
  writeF (vdir </> ".gitignore") ".pm/\n"
  ref <- newIORef Nothing
  let capture p = savePlan p >> writeIORef ref (Just p) >> pure 1
  cPlan <- runVaultPush capture (Just "landscape") ["n.jpg"] cfg
  cPlan @?= 1
  mplan <- readIORef ref
  plan <- maybe (assertFailure "应生成计划" >> undefined) pure mplan
  -- 计划生成后 ignore 行被移除 → apply 执行期 preflight 必须整批拒绝，
  -- vault 工作树内不得出现 journal（评审 #3 的污染路径）
  writeF (vdir </> ".gitignore") "_site/\n"
  code <- executePlanNow cfg plan
  code @?= 2
  jEx <- doesFileExist (vdir </> ".pm" </> "journal.ndjson")
  jEx @?= False
  landed <- doesFileExist (vdir </> "landscape" </> "n.jpg")
  landed @?= False

caseBindAmbiguity :: IO ()
caseBindAmbiguity = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  createDirectoryIfMissing True root
  createDirectoryIfMissing True vdir
  -- 同一 UUID 出现在主库与 vault（整盘复制/恢复事故模型）→ 拒绝，不猜
  writeRootInfo root (RootInfo "dup-id" RoleMain t0 Nothing)
  writeRootInfo vdir (RootInfo "dup-id" RoleVault t0 Nothing)
  let plan = Plan "amb-test" "vault-push" vdir (Just "dup-id") t0 []
  eb <- bindExecRoot cfg plan "dup-id"
  case eb of
    Left e -> assertBool ("应报多重命中: " <> e) ("多个" `isInfixOf` e)
    Right _ -> assertFailure "UUID 碰撞必须拒绝绑定"
  -- role 与槽位不符：vault 路径上是 backup root → 零候选，同样拒绝
  writeRootInfo root (RootInfo "other" RoleMain t0 Nothing)
  writeRootInfo vdir (RootInfo "bk-id" RoleBackup t0 Nothing)
  eb2 <- bindExecRoot cfg plan "bk-id"
  case eb2 of
    Left _ -> pure ()
    Right _ -> assertFailure "role 不符不得绑定"

caseCacheIdentitySwap :: IO ()
caseCacheIdentitySwap = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      va = tmp </> "va"
      vb = tmp </> "vb"
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "BBBB"
  writeF (va </> "landscape" </> "a.jpg") "AAAA" -- 与源不同 → A 下是 DRIFT
  writeF (vb </> "landscape" </> "a.jpg") "BBBB" -- 与源相同 → B 下应 OK
  -- 回溯 mtime：让两个 vault 的 (size,mtime) 巧合一致，且缓存条目非 racy
  mapM_
    (\p -> setModificationTime p t0)
    [va </> "landscape" </> "a.jpg", vb </> "landscape" </> "a.jpg"]
  c1 <- runVaultStatus False (mkVaultCfg root va)
  c1 @?= 1 -- DRIFT（顺带写下绑定 va 身份的缓存）
  -- 切到 vb：若无身份绑定，(size,mtime) 命中会复用 va 的 sha 把 vb 误报 DRIFT
  c2 <- runVaultStatus False (mkVaultCfg root vb)
  c2 @?= 0

caseRacyGuard :: IO ()
caseRacyGuard = do
  let snap = StatSnap 4 1000000000
  -- hash 时刻仅晚于 mtime 0.5 s（< 2 s 粒度余量）→ racy，不信任
  statHitStable 4 1000000000 (Just (nsToUtc 1500000000)) snap @?= False
  -- hash 时刻晚于 mtime 8 s → 可信
  statHitStable 4 1000000000 (Just (nsToUtc 9000000000)) snap @?= True
  -- 无验证时间戳 → fail-closed
  statHitStable 4 1000000000 Nothing snap @?= False
  -- size 不符 → 直接不命中
  statHitStable 5 1000000000 (Just (nsToUtc 9000000000)) snap @?= False

-- | 在目录树下找第一个同名文件（trash 的 <ts>/ 层名未知）。
findFileUnder :: FilePath -> FilePath -> IO (Maybe FilePath)
findFileUnder dir name = do
  entries <- listDirectory dir
  go entries
 where
  go [] = pure Nothing
  go (e : es) = do
    let p = dir </> e
    isFile <- doesFileExist p
    if isFile
      then if takeFileName p == name then pure (Just p) else go es
      else do
        r <- findFileUnder p name
        case r of
          Just hit -> pure (Just hit)
          Nothing -> go es
