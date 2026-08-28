{-# LANGUAGE OverloadedStrings #-}

-- | P4-7「暂不同步」（vault hold）用例——三十四轮从 VaultTests 拆出
-- （原文件触 750 行硬预算）。用例本体逐字节搬移，共享 fixture
-- （mkVaultCfg\/writeF\/mkMain\/execNow）上移 TestUtil。
module VaultHoldTests (vaultHoldTests) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Vault
import Pm.VaultCmd (runVaultHold)
import Pm.VaultHold (VaultHold (..), readHolds)
import TestUtil (execNow, mkMain, mkVaultCfg, plantStaleCatalog, withForeignLock, writeF)

vaultHoldTests :: TestTree
vaultHoldTests =
  testGroup
    "P4-7 vault hold"
    [ testCase "P4-7 hold：NEW 标暂不同步 → 移出 newActive、exit 0、push 拒收；非法操作 exit 2；unhold 恢复" caseHoldRoundTrip
    , testCase "P4-7 hold：照片字节换了 → 决定失效，回到 NEW 并报 stale" caseHoldStale
    , testCase "P4-7 hold 复核不吃缓存快路：等长替换 + 还原 mtime（stat 命中）仍判失效" caseHoldStaleEqualLen
    , testCase "P4-7 hold 是跨进程事务：root lock 被占用 → 拒绝而不是覆盖名单" caseHoldLock
    , testCase "P4-7 名单 fail-closed：残留 .tmp 而正文缺失 / 同名两条 → 拒绝，不当空名单" caseHoldFileGuards
    , testCase "P4-7 held-only：无参 vault push 与 status 都不再报「有事可做」" caseHoldOnlyExit
    , testCase "P4-7 决定的**创建**也不吃缓存：陈旧 catalog 下 hold 记的是盘上真实 sha，下一轮仍生效" caseHoldCreateFreshSha
    , testCase "P4-7 取锁前预检：匿名主库 hold 被拒且 .pm/lock 零写入" caseHoldPreflightNoWrite
    ]

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
  mkMain root
  createDirectoryIfMissing True (vdir </> "landscape")
  -- 决定记的是 AAA；随后造一条必然 statHitStable 的主库 catalog 条目（sha 是旧的）
  -- 并等长替换 + 还原 mtime：(size,mtime) 完全不变（'plantStaleCatalog'）
  _ <- plantStaleCatalog root (root </> "相册" </> "a.jpg") (runVaultHold True ["a.jpg"] cfg >>= (@?= 0))
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
  withForeignLock root (runVaultHold True ["b.jpg"] cfg) >>= (@?= 2) -- 拒绝
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
  mkMain root
  createDirectoryIfMissing True (vdir </> "landscape")
  -- 盘上等长替换 + 还原 mtime：catalog 的 (size,mtime) 仍然命中（'plantStaleCatalog'）
  (_, realSha) <- plantStaleCatalog root (root </> "相册" </> "a.jpg") (pure ())
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
