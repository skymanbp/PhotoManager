{-# LANGUAGE OverloadedStrings #-}

-- | 三十九轮（P7 全修）：扫描/新鲜度层的「出错路径 = 查不出」纪律。
--
-- 三条被钉住的事实（每条对应一处修法，撤销修法用例必须转红）：
--
--   1. 'sweepCounts'（纯核心，自 'freshnessSweep' 拆出）：stat 失败或遍历层
--      出错的路径**不隐身、不算消失，必入错误数**——此前 NEW 文件 stat 失败
--      即从 disk 集合掉出去（暂存区守卫照样放行），catalog 内文件 stat 失败
--      被误报「消失」。
--   2. 'freshnessSweep' E2E：ACL 全拒 (F) 是「非 ENOENT 探针失败」目前唯一的
--      确定性注入形态（实验记录见 REVIEW-LOG 三十九轮：拒 (RA)/(RD,RA) 不影响
--      GetFileAttributesEx 类探针；全拒才让 CreateFile 类探针 permission
--      denied）。被拒文件报错误数而非「消失」，解除即归零。
--   3. 'scanRoot' 的链接探针分支（三十七轮 GO 后收口，当时无注入形态）：探针
--      失败的文件按链接跳过、**带路径入错误桶、不入索引**——本文件补上它此前
--      缺席的配对用例。
--
-- init 配置闸（Commands.runInit :138）的组合形态也在这里钉：非法字符名让
-- GetFileAttributesEx 报 ERROR_INVALID_NAME(123) → 'ProbeUnknown' →
-- 'classifyGitProbe' 必须 Left。锁文件与配置同名系（<cfg>.lock），非法名会
-- 先炸锁，因此 runInit 级全链 E2E 无确定性形态——组合测试与 runInit 用的
-- 是**逐字同一个**表达式（classifyGitProbe <$> probeName cfgFp），余下两行
-- case 接线以检视覆盖（REVIEW-LOG 三十九轮登记实验依据）。
module ScanGuardTests (scanGuardTests) where

import Control.Exception (finally)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Time (getCurrentTime)
import Pm.BackupCmd (backupVerdict)
import Pm.Catalog (catalogPath, saveCatalog)
import Pm.Cli (GoOpts (..), mainFresh)
import Pm.Commands (InitOpts (..), runImport, runInit)
import Pm.Config (Config (..), loadConfig, writeConfig, writeRootInfo)
import Pm.Diff (backupDiff)
import Pm.GitGuard (classifyGitProbe)
import Pm.Hash (StatSnap (..), statSnap)
import Pm.Scan (ScanOpts (..), ScanResult (..), coversKey, freshnessSweep, scanRoot, sweepCounts, uncoveredKeys)
import Pm.SortSource (SourceFiles (..), listSource)
import Pm.Status (StatusOpts (..), runStatus)
import Pm.Types (Catalog (..), Entry (..), FileKind (..), RootInfo (..), RootRole (..), entryMap)
import Pm.Win (probeName)
import TestUtil (captureStdout, mkCat, t0, withDenyAll, withDenyList)

scanGuardTests :: TestTree
scanGuardTests =
  testGroup
    "三十九轮 扫描/新鲜度的「出错 = 查不出」纪律"
    [ testCase "sweepCounts 穷举：出错路径不隐身、不算消失、必入错误数（含子树覆盖）" caseSweepCounts
    , testCase "E2E：ACL 全拒文件 → freshnessSweep 报错误而非「消失」，解除即归零" caseFreshnessSweepDenied
    , testCase "E2E：基准目录被拒 → 错误口而非全零/整批消失（39 轮 #1，守卫不得 fail-open）" caseFreshnessSweepBaseDenied
    , testCase "E2E：scan 遇探针失败文件 → 不入索引、带路径入错误桶（三十七轮分支配对用例）" caseScanDeniedProbe
    , testCase "E2E：源根不可达 → listSource 整体拒绝不半扫（probeNotes 行登记无注入形态）" caseSourceRootProbeDenied
    , testCase "init 配置闸组合形态：非法字符名 → ProbeUnknown → classifyGitProbe Left 核不了" caseInitProbeUnknown
    , testCase "E2E：核对受阻（读取错误）必须计入 pm status 退出码——「一致」不得在受阻时照说" caseStatusFreshnessErrExit
    , testCase "第一方自审工作流 F039：基准目录列不出（RD 拒）→ 覆盖全树，catalog 不报「消失」" caseFreshnessSweepBaseUnlistable
    , testCase "第一方自审工作流 F040：子树列不出 → 旧条目按「查不出」保留并计数，不从快照消失" caseScanPartialWalkKeepsUnknown
    , testCase "工作流 F010/F077：init --force 遇旧配置读不出 → 明说未能保留；旧配置完好 → 登记保留且不报" caseInitForcePreservesOrSays
    , testCase "工作流 F046：快照最新代坏、回退到 .1 → status 打 ⚠ 且退出 1（--cached 下唯一的 1 来源）" caseStatusCatalogFallbackExit
    , testCase "工作流 F056/F057 backupVerdict 判定表：零降级零差异才 ✓/0；主库回退告警、备份盘读错/被改/未枚举 → 1" caseBackupVerdict
    , testCase "工作流 F057 mainFresh：干净库放行；多出未索引文件 → 拒绝并指向 pm scan" caseMainFreshGate
    , testCase "工作流 F042：root 自身是 junction（合法）→ 照常核对；库内子层 junction 保持「探不出 = 错误」" caseFreshnessJunctionRoot
    , testCase "import 暂存区新鲜度闸 E2E：索引落后 → runImport 整体拒绝 exit 2 并指向 pm scan" caseImportStaleRefused
    , testCase "工作流 C101 init 接线：vault 嵌在主库里 → runInit 拒绝 exit 2（checkConfig 汇点在 init 也生效）" caseInitNestedVaultRefused
    , testCase "41 轮 #3 配置缺失 + 孤儿 <cfg>.tmp → init 拒绝并复述恢复指引，.tmp 原封不动" caseInitOrphanTmpRefused
    ]

-- | init --force 的「读旧配置 → 写回」：旧配置 TOML 坏掉（整份解码失败，
-- cfgBackupId 随之丢失）时此前照样打「✓ 配置已写入」exit 0，登记静默丢失。
-- 硬拒绝不可取（pm init 是从坏配置逃出来的唯一通路）——要明说。反面：旧
-- 配置完好 → 登记保留、不报「未能保留」（否则修法就是「永远报」）。
caseInitForcePreservesOrSays :: IO ()
caseInitForcePreservesOrSays = withSystemTempDirectory "pm-init" $ \tmp -> do
  mold <- lookupEnv "PM_CONFIG"
  let cfgFp = tmp </> "config.toml"
      mainP = tmp </> "main"
      old = Config mainP Nothing Nothing Nothing (Just "B") (Just "mirror") Nothing (Just "origin main") Nothing
      force = InitOpts mainP Nothing Nothing Nothing True
  createDirectoryIfMissing True mainP
  setEnv "PM_CONFIG" cfgFp
  flip finally (maybe (pure ()) (setEnv "PM_CONFIG") mold) $ do
    _ <- writeConfig old
    appendFile cfgFp "\n[oops\n"
    (out, code) <- captureStdout (runInit force)
    code @?= 0
    assertBool ("旧配置读不出必须明说: " <> out) ("未能保留" `isInfixOf` out)
    loadConfig >>= either assertFailure (\c -> cfgBackupId c @?= Nothing)
    _ <- writeConfig old
    (out2, code2) <- captureStdout (runInit force)
    code2 @?= 0
    assertBool ("旧配置完好不得报未能保留: " <> out2) (not ("未能保留" `isInfixOf` out2))
    loadConfig >>= either assertFailure (\c -> (cfgBackupId c, cfgVaultPush c) @?= (Just "B", Just "origin main"))

-- | 最新代快照坏、回退到 .1：status 打「⚠ 快照损坏已跳过」，退出码此前仍 0
-- ——同一函数对失信侧缓存计入退出码，对同形的快照回退却不计。--cached 跳过
-- 新鲜度核对，所以 1 只能来自这条告警。
caseStatusCatalogFallbackExit :: IO ()
caseStatusCatalogFallbackExit = withSystemTempDirectory "pm-sfb" $ \dir -> do
  let root = dir </> "root"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  createDirectoryIfMissing True root
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (mkCat [])
  saveCatalog root (mkCat [])
  doesFileExist (catalogPath root <> ".1") >>= (@?= True)
  (_, code0) <- captureStdout (runStatus cfg (StatusOpts True))
  code0 @?= 0
  writeFile (catalogPath root) "{ not json"
  (out, code1) <- captureStdout (runStatus cfg (StatusOpts True))
  code1 @?= 1
  assertBool ("应报快照损坏已跳过: " <> out) ("快照损坏已跳过" `isInfixOf` out)

-- | 备份结论的纯判定表（discoverBackupRoot 探真实盘，E2E 造不出来，接缝在这）。
caseBackupVerdict :: IO ()
caseBackupVerdict = do
  let clean = ScanResult (mkCat []) 0 0 0 [] [] 0
      emptyDiff = backupDiff (mkCat []) (mkCat [])
      (l0, c0) = backupVerdict [] clean emptyDiff
  c0 @?= 0
  assertBool (show l0) (any ("✓ 备份盘已与主库一致" `isInfixOf`) l0)
  let (l1, c1) = backupVerdict ["catalog.json: bad json"] clean emptyDiff
  c1 @?= 1
  assertBool (show l1) (any ("主库快照" `isInfixOf`) l1 && not (any ("✓" `isInfixOf`) l1))
  let (l2, c2) = backupVerdict [] clean {srErrors = [("x.jpg", "denied")]} emptyDiff
  c2 @?= 1
  assertBool (show l2) (not (any ("✓" `isInfixOf`) l2))
  snd (backupVerdict [] clean {srVolatile = ["y.jpg"]} emptyDiff) @?= 1
  snd (backupVerdict [] clean {srCarried = 1} emptyDiff) @?= 1

-- | 主库新鲜度闸：干净库不得被挡（否则 backup 永远拒绝）；多出一个未索引
-- 文件就要拒绝并指向 pm scan。判别突变：删掉 == 0 的判定（fail-open）。
caseMainFreshGate :: IO ()
caseMainFreshGate = withSystemTempDirectory "pm-mf" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True (root </> "成片")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeFile (root </> "成片" </> "a.jpg") "A"
  cat <- srCatalog <$> scanRoot (ScanOpts 1 False) Nothing "m" root
  saveCatalog root cat
  mainFresh root cat >>= (@?= Right ())
  writeFile (root </> "成片" </> "b.jpg") "B"
  r <- mainFresh root cat
  case r of
    Left m -> assertBool m ("先 pm scan" `isInfixOf` m)
    Right () -> assertFailure "主库多出未索引文件，mainFresh 必须拒绝"

-- 纯核心穷举。mkEnt 造与 StatSnap 1 0 对齐的 catalog 条目。
caseSweepCounts :: IO ()
caseSweepCounts = do
  let ent n = Entry n 1 0 "sha-x" KindPhoto Nothing
      catA = Map.fromList [("a", ent "a")]
      okS = Right (StatSnap 1 0)
      chS = Right (StatSnap 2 0)
      boom = Left (userError "denied")
  -- 全对齐 / 变更 / 真消失 / 纯新增
  sweepCounts [("a", okS)] [] catA @?= (0, 0, 0, 0)
  sweepCounts [("a", chS)] [] catA @?= (0, 1, 0, 0)
  sweepCounts [] [] catA @?= (0, 0, 1, 0)
  sweepCounts [("b", okS)] [] Map.empty @?= (1, 0, 0, 0)
  -- catalog 内 stat 失败：核不了 ≠ 消失（旧实现 (0,0,1,0)）
  sweepCounts [("a", boom)] [] catA @?= (0, 0, 0, 1)
  -- NEW 文件 stat 失败：必须可见（旧实现全零 → 守卫放行）
  sweepCounts [("b", boom)] [] Map.empty @?= (0, 0, 0, 1)
  -- 遍历层出错的路径：同样从 gone 剔除、计入错误
  sweepCounts [] ["a"] catA @?= (0, 0, 0, 1)
  -- 遍历错在别的路径上：a 仍是真消失，错误另计
  sweepCounts [] ["sub"] catA @?= (0, 0, 1, 1)
  -- 39 轮 #1：遍历错误按**子树**覆盖——目录 sub 列举失败时，catalog 里
  -- sub\a.jpg 是「核不了」而非「消失」，且不与目录错误双重计数
  sweepCounts [] ["sub"] (Map.fromList [("sub" </> "a.jpg", ent "s")]) @?= (0, 0, 0, 1)
  -- 前缀必须按路径分量对齐：sub 出错不覆盖同前缀异分量的 subx.jpg
  sweepCounts [] ["sub"] (Map.fromList [("subx.jpg", ent "x")]) @?= (0, 0, 1, 1)
  -- 空路径 = 基准自身出错，覆盖整棵树（catalog 谁都不算消失）
  sweepCounts [] [""] catA @?= (0, 0, 0, 1)
  -- 混合：b 新增；d 真消失；a（stat 失败）与 c（遍历错）都只走错误口
  sweepCounts
    [("a", boom), ("b", okS)]
    ["c"]
    (Map.fromList [("a", ent "a"), ("c", ent "c"), ("d", ent "d")])
    @?= (1, 0, 1, 2)
  -- 第一方自审工作流 F039：展示键 "." 换算成覆盖键——全库核对 = 空路径
  -- （整棵树）；子树核对 = 前缀本身；子树错误按前缀换算。'coversKey' 是
  -- sweep 与 scan 共用的唯一覆盖判别。
  uncoveredKeys "" [(".", "e")] @?= [""]
  uncoveredKeys "To-Be-Sync'd" [(".", "e")] @?= ["To-Be-Sync'd"]
  uncoveredKeys "To-Be-Sync'd" [("sub", "e")] @?= ["To-Be-Sync'd" </> "sub"]
  coversKey [""] "x" @?= True
  coversKey ["sub"] ("sub" </> "a.jpg") @?= True
  coversKey ["sub"] "subx.jpg" @?= False

caseFreshnessSweepDenied :: IO ()
caseFreshnessSweepDenied =
  withSystemTempDirectory "pm-fresh-deny" $ \dir -> do
    writeFile (dir </> "ok.jpg") "aa"
    writeFile (dir </> "bad.jpg") "bb"
    sOk <- statSnap (dir </> "ok.jpg")
    sBad <- statSnap (dir </> "bad.jpg")
    let mk n s = Entry n (ssSize s) (ssMtimeNs s) "x" KindPhoto Nothing
        cat = Map.fromList [("ok.jpg", mk "ok.jpg" sOk), ("bad.jpg", mk "bad.jpg" sBad)]
    r <- withDenyAll (dir </> "bad.jpg") (freshnessSweep dir "" cat)
    -- 被拒文件 = 查不出：只入错误数，不算「消失」（改回旧折叠 → (0,0,1,1)）
    r @?= (0, 0, 0, 1)
    r2 <- freshnessSweep dir "" cat
    r2 @?= (0, 0, 0, 0)

-- | 39 轮 #1 E2E：**基准目录**被拒时此前 doesDirectoryExist 塌 False——
-- catalog 空则全零（守卫 fail-open 放行），非空则整批误报「消失」。三态化后
-- 两种 catalog 都必须走错误口；解除即恢复。
caseFreshnessSweepBaseDenied :: IO ()
caseFreshnessSweepBaseDenied =
  withSystemTempDirectory "pm-fresh-base" $ \dir -> do
    let base = dir </> "staging"
    createDirectoryIfMissing True base
    writeFile (base </> "a.jpg") "aa"
    s <- statSnap (base </> "a.jpg")
    let cat = Map.fromList [("staging" </> "a.jpg", Entry ("staging" </> "a.jpg") (ssSize s) (ssMtimeNs s) "x" KindPhoto Nothing)]
    -- 对照：可读时一致
    freshnessSweep dir "staging" cat >>= (@?= (0, 0, 0, 0))
    -- 基准被拒 + catalog 空：旧实现 (0,0,0,0)（fail-open），现在必须报错误
    rEmpty <- withDenyAll base (freshnessSweep dir "staging" Map.empty)
    rEmpty @?= (0, 0, 0, 1)
    -- 基准被拒 + catalog 非空：旧实现整批「消失」，现在同样只走错误口
    rCat <- withDenyAll base (freshnessSweep dir "staging" cat)
    rCat @?= (0, 0, 0, 1)
    -- 真 ENOENT 保持现状语义：条目确实消失
    freshnessSweep dir "no-such-dir" cat >>= (@?= (0, 0, 1, 0))
    -- ProbeUnknown 分支（`_`）的确定性注入：非法字符名 → GetFileAttributes
    -- 错误码 123 → 探不出，同样只走错误口而非全零（deny(F) 走的是 NamePlain→
    -- 非目录那一支——见 caseSourceRootProbeDenied 上方的实验记录，两支各自钉）
    freshnessSweep dir "st<aging" Map.empty >>= (@?= (0, 0, 0, 1))

-- | 第一方自审工作流 F039：目录级拒 (RD) 让 GetFileAttributes 与 doesDirectoryExist
-- 照常成功（probeName = NamePlain）、FindFirstFile 却 ERROR_ACCESS_DENIED——
-- 'listTree' 在**基准**上就失败，错误表记的是展示键 "."。旧换算器把它原样留下，
-- 三个覆盖判别一个都不命中，整份 catalog 报「消失」（用真实 pm.exe 实测：
-- 4 张全在盘上，pm status 报「消失 4」）。三十九轮当时判定「无确定性注入
-- 形态」——(RD) 只对 pathIsSymbolicLink 试过，没对 listDirectory 试。
caseFreshnessSweepBaseUnlistable :: IO ()
caseFreshnessSweepBaseUnlistable =
  withSystemTempDirectory "pm-fresh-rd" $ \dir -> do
    let base = dir </> "staging"
    createDirectoryIfMissing True base
    writeFile (base </> "a.jpg") "aa"
    s <- statSnap (base </> "a.jpg")
    let cat = Map.fromList [("staging" </> "a.jpg", Entry ("staging" </> "a.jpg") (ssSize s) (ssMtimeNs s) "x" KindPhoto Nothing)]
    r <- withDenyList base (freshnessSweep dir "staging" cat)
    -- 列不出 = 查不出：只入错误数（旧换算 → (0,0,1,1)）
    r @?= (0, 0, 0, 1)
    freshnessSweep dir "staging" cat >>= (@?= (0, 0, 0, 0))

-- | 第一方自审工作流 F040：子树列不出时 'scanRoot' 此前只从枚举到的文件建
-- 快照，未枚举子树里的条目静默消失，随即无条件落盘、三代轮转把完整快照
-- 顶掉（真实 pm.exe 实测：三次 scan 后 4 条 → 1 条、三代全截断）。修法是
-- 覆盖治快照：未枚举子树里的旧条目按「查不出」原样保留，并计数报出。
caseScanPartialWalkKeepsUnknown :: IO ()
caseScanPartialWalkKeepsUnknown =
  withSystemTempDirectory "pm-scan-rd" $ \dir -> do
    createDirectoryIfMissing True (dir </> "Album" </> "2024")
    writeFile (dir </> "Album" </> "top.jpg") "T"
    writeFile (dir </> "Album" </> "2024" </> "a.jpg") "A"
    r1 <- scanRoot (ScanOpts 1 False) Nothing "rid-t" dir
    Map.size (catEntries (srCatalog r1)) @?= 2
    srCarried r1 @?= 0
    r2 <- withDenyList (dir </> "Album" </> "2024") (scanRoot (ScanOpts 1 False) (Just (srCatalog r1)) "rid-t" dir)
    length (srErrors r2) @?= 1
    assertBool "未枚举子树里的旧条目必须保留（查不出 ≠ 不存在）" (Map.member ("Album" </> "2024" </> "a.jpg") (catEntries (srCatalog r2)))
    Map.size (catEntries (srCatalog r2)) @?= 2
    srCarried r2 @?= 1
    -- 解除后再扫：条目重新枚举到，不再是「保留」
    r3 <- scanRoot (ScanOpts 1 False) (Just (srCatalog r2)) "rid-t" dir
    srCarried r3 @?= 0
    Map.size (catEntries (srCatalog r3)) @?= 2

caseScanDeniedProbe :: IO ()
caseScanDeniedProbe =
  withSystemTempDirectory "pm-scan-deny" $ \dir -> do
    writeFile (dir </> "ok.jpg") "aa"
    writeFile (dir </> "bad.jpg") "bb"
    res <- withDenyAll (dir </> "bad.jpg") (scanRoot (ScanOpts 1 False) Nothing "rid-t" dir)
    let entries = catEntries (srCatalog res)
    assertBool "被拒文件不得入索引" (Map.notMember "bad.jpg" entries)
    assertBool "正常文件照常入索引" (Map.member "ok.jpg" entries)
    assertBool
      ("探针失败必须带路径入错误桶: " <> show (srErrors res))
      (any (\(p, m) -> p == "bad.jpg" && "查不出" `isInfixOf` m) (srErrors res))

-- 实验记录（三十九轮，全组合跑过）：目录级拒 (RD)/(RD,RA)/(RD,X) 下
-- pathIsSymbolicLink 照常成功、全拒 (F) 下 doesDirectoryExist 先塌 False——
-- 「isDir=True ∧ 链接探针失败」这一组合**无确定性注入形态**，SortSource 的
-- probeNotes 行（探针失败必须出说明）因此以检视覆盖、按 R2/R9 惯例登记。
-- 这里钉的是拒绝下确定性成立的那半：源根不可达时 listSource 走 isDir 闸
-- fail-closed 返回全空记录（不猜、不半扫）；「不存在」字样的诊断不精确
-- （其实是拒绝访问）已在 REVIEW-LOG 登记为已知边界。
caseSourceRootProbeDenied :: IO ()
caseSourceRootProbeDenied =
  withSystemTempDirectory "pm-src-deny" $ \dir -> do
    let src = dir </> "card"
    createDirectoryIfMissing True src
    writeFile (src </> "a.jpg") "x"
    sf <- withDenyAll src (listSource src)
    assertBool "拒绝的源根必须整体拒绝（全空），不得半扫" (null (sfPhotos sf) && null (sfSidecars sf) && null (sfUnknown sf))
    -- 解除后同一目录照常可扫（deny 已被 bracket 撤除）
    sf2 <- listSource src
    map (drop (length src + 1)) (sfPhotos sf2) @?= ["a.jpg"]

caseInitProbeUnknown :: IO ()
caseInitProbeUnknown =
  withSystemTempDirectory "pm-init-probe" $ \dir -> do
    kE <- classifyGitProbe <$> probeName (dir </> "config<illegal.json")
    case kE of
      Left why -> assertBool ("Left 须含 核不了: " <> why) ("核不了" `isInfixOf` why)
      Right x -> assertFailure ("非法名探针居然有布尔答案: " <> show x)

-- | Status 层的接线配对用例：'Pm.Status' 此前把 freshnessSweep 的错误数整个
-- 丢弃（isFreshness 三元组），「✓ 索引与磁盘一致」在核对受阻时照说、退出码
-- 照 0。突变「pending 去掉 +e」必须让本用例转红。
caseStatusFreshnessErrExit :: IO ()
caseStatusFreshnessErrExit =
  withSystemTempDirectory "pm-status-err" $ \dir -> do
    let root = dir </> "root"
        cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
    createDirectoryIfMissing True root
    now <- getCurrentTime
    writeRootInfo root (RootInfo "m" RoleMain now Nothing)
    writeFile (root </> "photo.jpg") "bytes"
    s <- statSnap (root </> "photo.jpg")
    saveCatalog root (Catalog "m" t0 (entryMap [Entry "photo.jpg" (ssSize s) (ssMtimeNs s) "x" KindPhoto Nothing]))
    -- 对照：干净库、索引与盘一致 → 0（把「1 来自受阻」与「来自其它差异」分开）
    code0 <- runStatus cfg (StatusOpts False)
    code0 @?= 0
    -- 拒读该文件 → 核对受阻：new/changed/missing 全零，错误数必须撑起退出码
    (out1, code1) <- captureStdout (withDenyAll (root </> "photo.jpg") (runStatus cfg (StatusOpts False)))
    code1 @?= 1
    assertBool ("受阻不得报一致: " <> out1) (not ("索引与磁盘一致" `isInfixOf` out1))
    assertBool ("要报读取错误: " <> out1) ("读取错误 1" `isInfixOf` out1)

-- | 工作流 F042：root 自身是 junction 是合法用法（'Pm.Win.resolveUnder' 文档 +
-- 句柄守卫用例都这么钉）——freshnessSweep 此前对它报「基准探不出」，把每次
-- status/闸核对都变成一条读取错误。库内子层 junction（relPrefix 非空）保持
-- 「探不出 = 错误」。
caseFreshnessJunctionRoot :: IO ()
caseFreshnessJunctionRoot = withSystemTempDirectory "pm-jroot" $ \tmp -> do
  let real = tmp </> "real"
      q p = [dq] <> p <> [dq]
      dq = toEnum 34 :: Char
  createDirectoryIfMissing True real
  writeFile (real </> "a.jpg") "A"
  _ <- readCreateProcess (shell ("mklink /J " <> q (tmp </> "rootlink") <> " " <> q real)) ""
  s <- statSnap (real </> "a.jpg")
  let cat = Map.fromList [("a.jpg", Entry "a.jpg" (ssSize s) (ssMtimeNs s) "x" KindPhoto Nothing)]
  freshnessSweep (tmp </> "rootlink") "" cat >>= (@?= (0, 0, 0, 0))
  createDirectoryIfMissing True (real </> "sub")
  _ <- readCreateProcess (shell ("mklink /J " <> q (real </> "Jn") <> " " <> q (real </> "sub"))) ""
  freshnessSweep real "Jn" Map.empty >>= (@?= (0, 0, 0, 1))

-- | import 的暂存区新鲜度闸 E2E：索引落后（暂存区多出未索引文件）→
-- 'runImport' 整体拒绝 exit 2（sort 侧同一道闸已有 F016 系用例；这里补
-- import 入口的配对钉子——闸定义共享 'freshStagingCatalog'）。
caseImportStaleRefused :: IO ()
caseImportStaleRefused = withSystemTempDirectory "pm-imp" $ \tmp -> do
  let root = tmp </> "main"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  createDirectoryIfMissing True (root </> "To-Be-Sync'd" </> "Raw" </> "26-06-R66")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (Catalog "m" t0 (entryMap []))
  writeFile (root </> "To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "a.ARW") "raw"
  (out, code) <- captureStdout (runImport (GoOpts False False) False cfg)
  code @?= 2
  assertBool ("拒绝时应指向 pm scan: " <> out) ("pm scan" `isInfixOf` out)

-- | 工作流 C101 的 init 侧接线：四条配置写路径共用 'checkConfig'，init 是
-- 其中之一——vault 落在主库归档层之下时必须当场拒绝（否则 scan 把展示集
-- 索引进主库、dedupe 把每张已推送照片报成精确重复）。
caseInitNestedVaultRefused :: IO ()
caseInitNestedVaultRefused = withSystemTempDirectory "pm-initnest" $ \tmp -> do
  mold <- lookupEnv "PM_CONFIG"
  let cfgFp = tmp </> "config.toml"
      mainP = tmp </> "main"
      nested = mainP </> "成片" </> "pub"
  createDirectoryIfMissing True nested
  setEnv "PM_CONFIG" cfgFp
  flip finally (maybe (pure ()) (setEnv "PM_CONFIG") mold) $ do
    (out, code) <- captureStdout (runInit (InitOpts mainP (Just nested) Nothing Nothing False))
    code @?= 2
    assertBool ("应指出嵌套: " <> out) ("嵌套" `isInfixOf` out)
    doesFileExist cfgFp >>= (@?= False)

-- | 41 轮 #3：孤儿 <cfg>.tmp（writeConfig 崩在删旧与改名之间，.tmp 是完整
-- 新配置）此前只有 'loadConfigState' 认得——init 按 exists=False 直接绕过，
-- 在旁边新写一份，把待恢复的备份盘登记等设置永久变成死文件。
caseInitOrphanTmpRefused :: IO ()
caseInitOrphanTmpRefused = withSystemTempDirectory "pm-orph" $ \tmp -> do
  mold <- lookupEnv "PM_CONFIG"
  let cfgFp = tmp </> "config.toml"
      mainP = tmp </> "main"
  createDirectoryIfMissing True mainP
  setEnv "PM_CONFIG" cfgFp
  flip finally (maybe (pure ()) (setEnv "PM_CONFIG") mold) $ do
    writeFile (cfgFp <> ".tmp") "main-path = \"D:/nowhere\"\n"
    (out, code) <- captureStdout (runInit (InitOpts mainP Nothing Nothing Nothing False))
    code @?= 2
    assertBool ("应复述 .tmp 恢复指引: " <> out) (".tmp" `isInfixOf` out)
    doesFileExist cfgFp >>= (@?= False)
    doesFileExist (cfgFp <> ".tmp") >>= (@?= True)
