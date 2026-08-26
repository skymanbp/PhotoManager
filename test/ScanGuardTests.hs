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

import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Data.Time (getCurrentTime)
import Pm.Catalog (saveCatalog)
import Pm.Config (Config (..), writeRootInfo)
import Pm.GitGuard (classifyGitProbe)
import Pm.Hash (StatSnap (..), statSnap)
import Pm.Scan (ScanOpts (..), ScanResult (..), freshnessSweep, scanRoot, sweepCounts)
import Pm.SortSource (SourceFiles (..), listSource)
import Pm.Status (StatusOpts (..), runStatus)
import Pm.Types (Catalog (..), Entry (..), FileKind (..), RootInfo (..), RootRole (..), entryMap)
import Pm.Win (probeName)
import TestUtil (t0, withDenyAll)

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
    ]

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
    code1 <- withDenyAll (root </> "photo.jpg") (runStatus cfg (StatusOpts False))
    code1 @?= 1
