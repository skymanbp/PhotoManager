{-# LANGUAGE OverloadedStrings #-}

-- | P3b-14：codex 十一轮复审的收口用例（从 PathGuardTests 拆出，该文件触及
-- 750 行预算）。主题只有一个：**@.pm@ 状态文件的受信取用口**
-- （'Pm.Config.readPmState' \/ 'withPmStateAppend' \/ 'readSideCache'）。
--
-- 十一轮实证了旧模式「拼路径字符串 → 校验字符串 → 再按名字打开」的三个洞：
-- 深度 ≥2 的完整路径没人验（manifest\/plan）、字符串校验在原理上看不见
-- hardlink（读侧完全没有 link count）、校验与打开是两次独立解析。这里每个
-- 用例钉一条：删掉对应的屏障，用例必须转红。
module StateGuardTests (stateGuardTests) where

import Control.Exception (SomeException, try)
import Data.List (isInfixOf)
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (loadCatalog)
import Pm.Config (pmDir, readSideCache, requirePmTrusted, writeRootInfo, writeSideCache)
import Pm.Plan (Plan (..), loadPlan, savePlan)
import Pm.Trash (TrashRecord (..), appendManifest, readManifest, trashDir)
import Pm.Types (Catalog, RootInfo (..), RootRole (..))
import TestUtil

stateGuardTests :: TestTree
stateGuardTests =
  testGroup
    "P3b-14 .pm 状态文件的受信取用口（codex 十一轮）"
    [ testCase "P3b-14 manifest.ndjson 是指向库外的文件 symlink → append/读取都拒绝，库外文件零改动" caseManifestDeepSymlink
    , testCase "P3b-14 catalog.json 被 hardlink 占名 → loadCatalog 拒读（读侧 link count）" caseCatalogHardlinkRead
    , testCase "P3b-14 plans/<id>.json 是深层 hardlink/symlink → loadPlan/savePlan 拒绝" casePlanDeepLink
    , testCase "P3b-14 .pm 是普通文件 → 可信闸与 loader 一律拒绝（不当\"尚不存在\"）" casePmIsPlainFile
    , testCase "P3b-14 侧缓存文件级链接 → 写侧文件级复检拦下、读侧 hardlink 弃用" caseSideCacheFileLevel
    ]

-- 本模块只需要 hardlink（/H）与文件 symlink（无开关）两种形态；目录 junction
-- 的用例都在 PathGuardTests。
mkHardLink, mkFileLink :: FilePath -> FilePath -> IO ()
mkHardLink link target =
  () <$ readCreateProcess (shell ("mklink /H \"" <> link <> "\" \"" <> target <> "\"")) ""
mkFileLink link target =
  () <$ readCreateProcess (shell ("mklink \"" <> link <> "\" \"" <> target <> "\"")) ""

-- | 十一轮 **critical**（探针 Probe11 实证）：@.pm/trash@ 是普通目录、可信闸
-- （深度 1）放行；@manifest.ndjson@（深度 2）是指向库外单链接文件的**文件
-- symlink**——目标 link count = 1，九轮的 link count 判定也放行，@AppendMode@
-- 跟随链接，真实的 'appendManifest' 把隔离记录**追加进了库外文件**。
-- 修复是完整路径 'resolveUnder'（'withPmStateAppend'）：删掉它，本例转红。
caseManifestDeepSymlink :: IO ()
caseManifestDeepSymlink = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (trashDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "hostage.ndjson") "OUTSIDE-ORIGINAL\n"
  mkFileLink (trashDir root </> "manifest.ndjson") (outside </> "hostage.ndjson")
  now <- getCurrentTime
  -- 写侧：拒绝（IOException），一个字节都不追加
  ra <- try (appendManifest root (TrashRecord "v.jpg" "v.jpg" "aa" "t" tpid now)) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "appendManifest 应拒绝 symlink 化的 manifest")) ra
  readFile (outside </> "hostage.ndjson") >>= (@?= "OUTSIDE-ORIGINAL\n")
  -- 读侧：同口拒绝，绝不把库外内容当隔离清单
  (rs, ws) <- readManifest root
  rs @?= []
  assertBool ("readManifest 应报不可信: " <> show ws) (any ("不是 root 下的真实目录项" `isInfixOf`) ws)

-- | 十一轮 major（探针 Probe11b 实证）：hardlink 既不是 reparse point 也不改
-- 名字解析，可信闸与 'Pm.Win.resolveUnder' 在**原理上**看不见它；读侧此前没有
-- link count 判定，实测 hardlink 占名的 catalog.json 被**零警告**载入——快照
-- 决定 backup\/import 会读写哪些文件。修复是 'readPmState' 的句柄 link count：
-- 删掉它，本例转红。
caseCatalogHardlinkRead :: IO ()
caseCatalogHardlinkRead = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "evil-catalog.json") "{\"whatever\":1}"
  mkHardLink (pmDir root </> "catalog.json") (outside </> "evil-catalog.json")
  -- 深度 1 的枚举闸放行（hardlink 不可见）——这正是需要读侧句柄判定的原因
  requirePmTrusted root >>= either (assertFailure . ("闸不应看见 hardlink（否则本例测错了层）: " <>)) pure
  (mc, ws) <- loadCatalog root
  mc @?= Nothing
  assertBool ("loadCatalog 应报拒读: " <> show ws) (any ("无法可信读取" `isInfixOf`) ws)
  -- 库外对象完好（拒读不 unlink、不改写）
  readFile (outside </> "evil-catalog.json") >>= (@?= "{\"whatever\":1}")

-- | 十一轮 major（探针实证 hardlink 与 symlink 两种形态都把**库外计划**载入，
-- apply 会照它执行）。'readPmState' 一口治两种：resolveUnder 认 symlink，
-- 句柄 link count 认 hardlink——断言拒绝理由各自对应，钉住是哪层拦的。
casePlanDeepLink :: IO ()
casePlanDeepLink = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
  createDirectoryIfMissing True (pmDir root </> "plans")
  createDirectoryIfMissing True outside
  writeFile (outside </> "evil-plan.json") "{\"whatever\":1}"
  -- hardlink 形态：句柄 link count 拦
  mkHardLink (pmDir root </> "plans" </> "20260101-000000-abcdef.json") (outside </> "evil-plan.json")
  lp1 <- loadPlan root tpid
  either
    (\m -> assertBool m ("无法可信读取" `isInfixOf` m))
    (const (assertFailure "loadPlan 应拒绝 hardlink 占名的计划文件"))
    lp1
  -- symlink 形态（独立 root）：完整路径 resolveUnder 拦
  let root2 = dir </> "root2"
  createDirectoryIfMissing True (pmDir root2 </> "plans")
  mkFileLink (pmDir root2 </> "plans" </> "20260101-000000-abcdef.json") (outside </> "evil-plan.json")
  lp2 <- loadPlan root2 tpid
  either
    (\m -> assertBool m ("不是 root 下的真实目录项" `isInfixOf` m))
    (const (assertFailure "loadPlan 应拒绝 symlink 化的计划文件"))
    lp2
  -- savePlan 同守卫：删旧那步会 unlink，symlink 形态必须在写前拒绝
  plan <- mkPlanIO root2 []
  rs <- try (savePlan plan {plId = tpid}) :: IO (Either SomeException FilePath)
  either (const (pure ())) (const (assertFailure "savePlan 应拒绝 symlink 化的计划文件")) rs
  readFile (outside </> "evil-plan.json") >>= (@?= "{\"whatever\":1}")

-- | 十一轮 minor：@.pm@ 是**普通文件**时，旧闸把 @doesDirectoryExist=False@
-- 读成"尚不存在（新库）"而放行。四态判定后：缺失=放行，非目录/查不出=拒绝。
casePmIsPlainFile :: IO ()
casePmIsPlainFile = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  writeFile (pmDir root) "not a directory"
  requirePmTrusted root
    >>= either
      (\m -> assertBool m ("不是目录" `isInfixOf` m))
      (const (assertFailure "requirePmTrusted 应拒绝 .pm 是普通文件的 root"))
  (mc, ws) <- loadCatalog root
  mc @?= Nothing
  assertBool ("loadCatalog 应报不可信: " <> show ws) (any ("不是目录" `isInfixOf`) ws)

-- | 十一轮 #6：十轮的 'caseSideCacheJunction' 把 junction 放在**目录**级，
-- 命中的是 writeSideCache 的目录级 pre-check——删掉两个 writeCacheFile 的
-- **文件级**复检，那条用例照样绿。本例把链接放到文件级：目录是真目录、
-- pre-check 放行，catalog.json 自身是 symlink → 只有文件级复检能拦。
-- 读侧对偶：meta.json 被 hardlink 占名 → 'readSideCache' 弃用（Nothing），
-- 不把库外字节当缓存。
caseSideCacheFileLevel :: IO ()
caseSideCacheFileLevel = withSystemTempDirectory "pm-sguard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside"
      cache = pmDir root </> "vault-cache"
  createDirectoryIfMissing True cache
  createDirectoryIfMissing True outside
  writeFile (outside </> "victim.json") "OUTSIDE-BYTES"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 写侧：catalog.json 是文件级 symlink → writeCacheFile 的完整路径复检拦下
  mkFileLink (cache </> "catalog.json") (outside </> "victim.json")
  w <- writeSideCache root "vault-cache" (mkCat []) (mkCat [])
  either
    (\m -> assertBool m ("catalog.json" `isInfixOf` m))
    (const (assertFailure "writeSideCache 应在文件级复检拒绝 symlink"))
    w
  readFile (outside </> "victim.json") >>= (@?= "OUTSIDE-BYTES")
  doesFileExist (cache </> "meta.json") >>= (@?= False)
  -- 读侧：meta.json 被 hardlink 占名 → readSideCache 弃用
  writeFile (outside </> "evil-meta.json") "{\"x\":1}"
  mkHardLink (cache </> "meta.json") (outside </> "evil-meta.json")
  rm <- readSideCache root "vault-cache" "meta.json" :: IO (Maybe Catalog)
  rm @?= Nothing
