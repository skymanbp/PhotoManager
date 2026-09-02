{-# LANGUAGE OverloadedStrings #-}

-- | 计划执行态折叠与计划文件删除（2026-08-31 用户裁定：标注+删除+一键清理）：
-- 'planExecs' 的 journal 折叠语义（普通 Done 计入、@~r@ 剔除、@~d\<N\>@ 不计、
-- 重试成功抹失败）、'planExecuted' 的保守判据（草稿不算、待裁决残余不算）、
-- 'deletePlan' 的守卫（id 格式 \/ 缺席 \/ 真删）、'prunePlans' 只清已执行。
module PlanExecTests (planExecTests) where

import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (addUTCTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..))
import Pm.Journal (JEntry (..), Sync (..), jAppend, withJournal)
import Pm.Op
import Pm.Plan
import TestUtil (mkMain, t0)

planExecTests :: TestTree
planExecTests =
  testGroup
    "计划执行态折叠 + 计划文件删除"
    [ testCase "planExecs：普通 Done 计入、~r 复位剔除、~d 不计、Failed 后再 Done 抹失败、lastAt 取最大、坏 oid 跳过" caseFold
    , testCase "planExecuted/runTag：草稿≠已执行、部分执行、待裁决残余不算已执行、全 Done 才算、失败注记" caseExecuted
    , testCase "deletePlan 守卫（坏 id/缺席/真删）；prunePlans 只清已执行、草稿不动、journal 不动" caseDeleteAndPrune
    ]

pidA, pidB :: Text
pidA = "20260831-120000-abc123"
pidB = "20260831-120001-abc456"

caseFold :: IO ()
caseFold = do
  let at n = addUTCTime (fromIntegral (n :: Int)) t0
      done oid n = JDone oid Nothing Nothing (at n)
      bad oid n = JFailed oid "boom" (at n)
      runs =
        planExecs
          [ done (opId pidA 0) 1 -- ix0 完成
          , bad (opId pidA 1) 2 -- ix1 失败…
          , done (opId pidA 1) 3 -- …重试成功 → 抹失败
          , done (opId pidA 2) 4 -- ix2 完成…
          , done (opId pidA 2 <> "~r") 5 -- …组回滚复位 → 剔除
          , done (opId pidA 3 <> "~d1") 6 -- 位移隔离：不计入完成
          , bad (opId pidA 4) 7 -- ix4 失败且未再成功
          , done "not-an-oid" 8 -- 解析不出：整条跳过
          ]
  Map.keys runs @?= [pidA]
  let r = runs Map.! pidA
  peDone r @?= Set.fromList [0, 1]
  peFailed r @?= Set.fromList [4]
  peLastAt r @?= Just (at 7)

mkPlan :: Text -> FilePath -> [(Int, ItemStatus)] -> Plan
mkPlan pid root sts =
  Plan pid "test" root (Just "main-rid") t0
    [PlanItem ix (OpCopy (root </> "src.jpg") ("dst" <> show ix <> ".jpg") "aa" 1 0) st Nothing | (ix, st) <- sts]

caseExecuted :: IO ()
caseExecuted = do
  let pe done failed = Just (PlanExec (Set.fromList done) (Set.fromList failed) Nothing)
      p2 = mkPlan pidA "R:" [(0, StPending), (1, StPending)]
      pNd = mkPlan pidA "R:" [(0, StPending), (1, StNeedsDecision "why")]
      pSkip = mkPlan pidA "R:" [(0, StPending), (1, StSkippedByUser)]
  -- 草稿（journal 无记录）：未执行
  planExecuted p2 Nothing @?= False
  runTag p2 Nothing @?= "未执行"
  -- 部分执行
  planExecuted p2 (pe [0] []) @?= False
  runTag p2 (pe [0] []) @?= "部分执行 1/2"
  -- 全部 Done：已执行；跳过项是用户裁决，不挡
  planExecuted p2 (pe [0, 1] []) @?= True
  runTag p2 (pe [0, 1] []) @?= "已执行"
  planExecuted pSkip (pe [0] []) @?= True
  -- 待裁决残余：待执行项全 Done 也不算已执行（prune 不替用户裁决）
  planExecuted pNd (pe [0] []) @?= False
  runTag pNd (pe [0] []) @?= "已执行（余 1 项待裁决）"
  -- 失败注记
  runTag p2 (pe [0] [1]) @?= "部分执行 1/2（失败 1）"

caseDeleteAndPrune :: IO ()
caseDeleteAndPrune = withSystemTempDirectory "pm-planexec" $ \tmp -> do
  let root = tmp </> "lib"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing
  mkMain root
  let pA = mkPlan pidA root [(0, StPending)]
      pB = mkPlan pidB root [(0, StPending)]
  _ <- savePlan pA
  _ <- savePlan pB
  -- pA 的执行事实进 journal（真实 withJournal 追加口；pB 是从未执行的草稿）
  withJournal root $ \j -> do
    let op0 = OpCopy (root </> "src.jpg") "dst0.jpg" "aa" 1 0
    jAppend j Buffered (JIntent (opId pidA 0) op0 t0)
    jAppend j Barrier (JDone (opId pidA 0) (Just "aa") Nothing t0)
  -- 守卫：坏 id / 缺席
  rBad <- deletePlan root "..\\evil"
  case rBad of
    Left m -> assertBool m ("不符合生成格式" `isInfixOf` m)
    Right () -> assertFailure "坏 id 应拒"
  deletePlan root "20260831-235959-ffffff" >>= either (const (pure ())) (const (assertFailure "缺席应 Left"))
  -- prune：只清已执行的 pA；草稿 pB 原地不动；journal 不动
  (deleted, errs) <- prunePlans cfg
  errs @?= []
  map (\(lbl, p) -> (lbl, plId p)) deleted @?= [("主库", pidA)]
  doesFileExist (planPath root pidA) >>= (@?= False)
  doesFileExist (planPath root pidB) >>= (@?= True)
  doesFileExist (root </> ".pm" </> "journal.ndjson") >>= (@?= True)
  -- 真删草稿：删除成功后 loadPlan Left、再删 Left
  deletePlan root pidB >>= either assertFailure pure
  loadPlan root pidB >>= either (const (pure ())) (const (assertFailure "删除后 loadPlan 应 Left"))
  deletePlan root pidB >>= either (const (pure ())) (const (assertFailure "再删应 Left"))
