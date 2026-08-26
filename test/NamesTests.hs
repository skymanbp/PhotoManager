{-# LANGUAGE OverloadedStrings #-}

-- | P3b-2/3：pm names（Scheme B→A 统一）与 pm versions（版本组报告）。
module NamesTests (namesTests) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, sort)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Cli (executePlanNow)
import Pm.Config (Config (..), writeRootInfo)
import Pm.Names
import Pm.Plan
import Pm.Types (RootInfo (..), RootRole (..))
import Pm.Undo (buildUndoPlan)
import Pm.Versions
import TestUtil (mkCat, mkE, t0)

namesTests :: TestTree
namesTests =
  testGroup
    "P3b names/versions"
    [ testCase "parseSchemeB：RAW-YYYY-季节-地点（地点可含 '-'）" caseParseB
    , testCase "classifyRawEvent：A 类/可规范化/B 类/不可识别" caseClassify
    , testCase "restoreMonth：唯一/缺失/歧义 + case-fold 地点" caseRestore
    , testCase "namesPlan：年份夹不符与同批撞名全降裁决" caseNamesPlan
    , testCase "runNames E2E：Scheme B 目录改名落盘 + undo 完整回滚" caseNamesE2E
    , testCase "P3b-5 B1/B3：主库路径是 backup root → 拒绝出计划；目标被文件占位 → 降裁决" caseNamesGuards
    , testCase "normalizeStem：§1.1 后缀清单 + 迭代不动点" caseStem
    , testCase "versionsReport：设计内成片↔相册对排除；同目录版本组；真重复上报" caseVersions
    , testCase "designedGroup：Raw 原片就是 JPG / 相册撞名避让 算设计内；有 RAW 兄弟、没撞名、同层两份 仍上报" caseDesignedGroups
    ]

caseParseB :: IO ()
caseParseB = do
  parseSchemeB "RAW-2025-Winter-Alaska" @?= Just (2025, "Winter", "Alaska")
  parseSchemeB "raw-2025-Spring-West-America" @?= Just (2025, "Spring", "West-America")
  parseSchemeB "RAW-25-Winter-X" @?= Nothing
  parseSchemeB "RAW-2025-Winter-" @?= Nothing
  parseSchemeB "RAW-2025--X" @?= Nothing
  parseSchemeB "23-01-Cotswold-Raw" @?= Nothing

caseClassify :: IO ()
caseClassify = do
  classifyRawEvent "23-01-Cotswold-Raw" @?= RnCanonical
  classifyRawEvent "23-12-Turkey" @?= RnRename "23-12-Turkey-Raw"
  classifyRawEvent "23-12-Turkey-raw" @?= RnRename "23-12-Turkey-Raw"
  classifyRawEvent "RAW-2025-Winter-Alaska" @?= RnSchemeB 2025 "Winter" "Alaska"
  classifyRawEvent "junk" @?= RnUnrecognized
  classifyRawEvent "26-04--Raw" @?= RnUnrecognized -- 空地点（评审 mj-1）
  classifyRawEvent "26-13-X" @?= RnUnrecognized -- 非法月份

caseRestore :: IO ()
caseRestore = do
  restoreMonth ["25-01-Alaska", "25-03-West America"] 2025 "alaska" @?= Right 1
  case restoreMonth ["25-03-West America"] 2025 "Alaska" of
    Left _ -> pure ()
    Right m -> assertFailure ("缺失应 Left，得到 " <> show m)
  case restoreMonth ["25-01-Alaska", "25-02-Alaska"] 2025 "Alaska" of
    Left why -> assertBool ("应报歧义: " <> why) ("歧义" `isInfixOf` why)
    Right m -> assertFailure ("歧义应 Left，得到 " <> show m)

caseNamesPlan :: IO ()
caseNamesPlan = do
  -- 年份夹不符：事件 23-xx 放在 2024 夹
  let rep1 = namesPlan [("2024", ["23-12-Turkey"])] []
  nrRenames rep1 @?= []
  length (nrDecisions rep1) @?= 1
  -- 同批撞名（case-fold）：两个事件规范化到同一目标 → 全降裁决
  let rep2 = namesPlan [("2023", ["23-12-Turkey", "23-12-turkey-raw"])] []
  nrRenames rep2 @?= []
  length (nrDecisions rep2) @?= 2
  -- 正常混合：A 类计 ok，B 类还原，裸名补后缀
  let rep3 =
        namesPlan
          [("2023", ["23-01-Cotswold-Raw", "23-12-Turkey"]), ("2025", ["RAW-2025-Winter-Alaska"])]
          ["25-01-Alaska"]
  nrOkCount rep3 @?= 1
  nrRenames rep3
    @?= [ ("2023", "23-12-Turkey", "23-12-Turkey-Raw")
        , ("2025", "RAW-2025-Winter-Alaska", "25-01-Alaska-Raw")
        ]

caseNamesE2E :: IO ()
caseNamesE2E = withSystemTempDirectory "pm-names" $ \tmp -> do
  let root = tmp </> "main"
      cfgLike = root -- runNames 只用 cfgMainPath
      evOld = root </> "Raw" </> "2025" </> "RAW-2025-Winter-Alaska"
      evNew = root </> "Raw" </> "2025" </> "25-01-Alaska-Raw"
  writeF (evOld </> "x.ARW") "RAWBYTES"
  createDirectoryIfMissing True (root </> "成片" </> "25-01-Alaska")
  writeRootInfo root (RootInfo "names-test-root" RoleMain t0 Nothing)
  let cfg = mkMainCfg cfgLike
  code <- runNames (\p -> savePlan p >> executePlanNow cfg p) cfg
  code @?= 0
  oldEx <- doesDirectoryExist evOld
  newEx <- doesDirectoryExist evNew
  (oldEx, newEx) @?= (False, True)
  inside <- readFile (evNew </> "x.ARW")
  inside @?= "RAWBYTES"
  -- undo 完整回滚（P3 验收标准）
  eundo <- buildUndoPlan root 1
  uplan <- either (\e -> assertFailure e >> undefined) pure eundo
  ucode <- executePlanNow cfg uplan
  ucode @?= 0
  oldEx2 <- doesDirectoryExist evOld
  newEx2 <- doesDirectoryExist evNew
  (oldEx2, newEx2) @?= (True, False)
  inside2 <- readFile (evOld </> "x.ARW")
  inside2 @?= "RAWBYTES"

caseNamesGuards :: IO ()
caseNamesGuards = withSystemTempDirectory "pm-names" $ \tmp -> do
  -- B1：配置的「主库」其实是 backup root → 不出计划、不执行
  let bad = tmp </> "bak"
  createDirectoryIfMissing True (bad </> "Raw" </> "2025" </> "RAW-2025-Winter-Alaska")
  createDirectoryIfMissing True (bad </> "成片" </> "25-01-Alaska")
  writeRootInfo bad (RootInfo "bk" RoleBackup t0 Nothing)
  ran <- newIORef False
  code <- runNames (\_ -> writeIORef ran True >> pure 0) (mkMainCfg bad)
  code @?= 2
  readIORef ran >>= (@?= False)
  -- B3：目标路径被普通文件占用 → NEEDS-DECISION，不出计划（原先只查目录会漏）
  let root = tmp </> "main"
  createDirectoryIfMissing True (root </> "Raw" </> "2023" </> "23-12-Turkey")
  writeF (root </> "Raw" </> "2023" </> "23-12-Turkey-Raw") "a file, not a dir"
  writeRootInfo root (RootInfo "m" RoleMain t0 Nothing)
  ran2 <- newIORef False
  code2 <- runNames (\_ -> writeIORef ran2 True >> pure 0) (mkMainCfg root)
  code2 @?= 1
  readIORef ran2 >>= (@?= False)

caseStem :: IO ()
caseStem = do
  normalizeStem "_DSC0245-Enhanced-NR" @?= "_DSC0245"
  normalizeStem "_DSC0268-已增强-NR" @?= "_DSC0268"
  normalizeStem "_DSC1330-HDR-3" @?= "_DSC1330"
  normalizeStem "_DSC2065~4-edit" @?= "_DSC2065"
  normalizeStem "DSC08887.2_1" @?= "DSC08887"
  normalizeStem "_DSC0264F" @?= "_DSC0264"
  normalizeStem "_DSC1216_hdr" @?= "_DSC1216"
  normalizeStem "_DSC8707-HDR_3_1" @?= "_DSC8707"
  normalizeStem "DSC08922_L" @?= "DSC08922"
  normalizeStem "A7R06348" @?= "A7R06348"
  -- 不动点（幂等）
  let samples = ["_DSC0245-Enhanced-NR", "_DSC1330-HDR-3", "DSC08887.2_1", "A7R06348"]
  mapM_ (\s -> normalizeStem (normalizeStem s) @?= normalizeStem s) samples

caseVersions :: IO ()
caseVersions = do
  let cat =
        mkCat
          [ mkE ("成片" </> "23-04-EU" </> "A.jpg") "s1"
          , mkE ("相册" </> "A.jpg") "s1" -- 设计内精确对 → 不报重复
          , mkE ("成片" </> "23-04-EU" </> "B.jpg") "s2"
          , mkE ("成片" </> "23-04-EU" </> "B-HDR.jpg") "s3" -- 同目录版本组
          , mkE ("成片" </> "23-04-EU" </> "C.jpg") "s4"
          , mkE ("成片" </> "23-05-X" </> "D.jpg") "s4" -- 跨目录同 sha 异名 → 真重复
          , mkE ("To-Be-Sync'd" </> "Processed" </> "e" </> "C.jpg") "s4" -- 暂存排除
          ]
      rep = versionsReport cat
  map fst (vgGroups rep) @?= [("成片" </> "23-04-EU", "b")]
  case vgGroups rep of
    [(_, files)] -> files @?= ["成片" </> "23-04-EU" </> "B-HDR.jpg", "成片" </> "23-04-EU" </> "B.jpg"]
    g -> assertFailure ("应恰一组，得到 " <> show g)
  case vgExactDups rep of
    [(sha, files)] -> do
      sha @?= "s4"
      files @?= ["成片" </> "23-04-EU" </> "C.jpg", "成片" </> "23-05-X" </> "D.jpg"]
    d -> assertFailure ("应恰一组真重复，得到 " <> show d)

-- | 「设计内冗余」的三条判据各配正反例（2026-08-25 更正：此前只认判据①，
-- 把归档三层拓扑里另外两种必然的同字节关系报成了缺陷）。
--
--  ③ Raw↔成片 同名：**没有**同 stem 原始档 → 原片就是 JPG（相机直出／手机／
--     RAW 遗失），设计内；**有**原始档 → 那个 JPG 是导出件，误放进 Raw，要报。
--  ② 成片↔相册 异名：成片那个名字在相册**已被别的文件占住** → 平铺避让，
--     设计内；**没被占** → 真的命名分歧，要报。
--  同层两份一律要报（由 caseVersions 里那对同 sha 的成片文件钉住）。
caseDesignedGroups :: IO ()
caseDesignedGroups = do
  let cat =
        mkCat
          [ -- ③ 正：该 Raw 事件夹零原始档 → P.jpg 就是原片
            mkE ("Raw" </> "2023" </> "23-04-EU-Raw" </> "P.jpg") "s10"
          , mkE ("成片" </> "23-04-EU" </> "P.jpg") "s10"
          , -- ③ 反：同 stem 有 ARW（且 Q~2 要经 normalizeStem 才对得上 Q）
            mkE ("Raw" </> "2025" </> "25-08-T-Raw" </> "Q~2.jpg") "s11"
          , mkE ("成片" </> "25-08-T" </> "Q~2.jpg") "s11"
          , mkE ("Raw" </> "2025" </> "25-08-T-Raw" </> "Q.ARW") "s99"
          , -- ② 正：成片叫 R.jpg，但相册里 R.jpg 已被**别的**文件占住 → 避让
            mkE ("成片" </> "25-11-Alaska" </> "R.jpg") "s12"
          , mkE ("相册" </> "R2.jpg") "s12"
          , mkE ("相册" </> "R.jpg") "s13"
          , -- ② 反：相册里没有 S.jpg 撞名，异名就是命名分歧
            mkE ("成片" </> "25-08-T" </> "S.jpg") "s14"
          , mkE ("相册" </> "S9.jpg") "s14"
          , -- 同层两份：两个事件夹各一份 / 根与子目录各一份 → 一律要报
            mkE ("Raw" </> "2024" </> "24-12-NY-Raw" </> "T.ARW") "s15"
          , mkE ("Raw" </> "2025" </> "25-01-AT-Raw" </> "T.ARW") "s15"
          , mkE ("Raw" </> "2023" </> "23-04-EU-Raw" </> "U.jpg") "s16"
          , mkE ("Raw" </> "2023" </> "23-04-EU-Raw" </> "sub" </> "U.jpg") "s16"
          ]
      rep' = versionsReport cat
  sort (map fst (vgExactDups rep')) @?= ["s11", "s14", "s15", "s16"]

-- ─── helpers ────────────────────────────────────────────────────────────────

writeF :: FilePath -> String -> IO ()
writeF fp s = createDirectoryIfMissing True (takeDirectory fp) >> writeFile fp s

mkMainCfg :: FilePath -> Config
mkMainCfg root =
  Config
    { cfgMainPath = root
    , cfgVaultPath = Nothing
    , cfgPhotosJson = Nothing
    , cfgWorkers = Nothing
    , cfgBackupId = Nothing
    , cfgBackupSubpath = Nothing
    , cfgPortfolioDir = Nothing
    , cfgVaultPush = Nothing
    , cfgPortfolioPush = Nothing
    }
