{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | P2/P2.1 tests: pure planners (Names\/Import\/Diff\/Clean), dual-root
-- backup fixtures, and the P2.1 review fixes — compound groups with
-- auto-restore (cx-2), root-UUID gating (cx-1), exec-time witness re-hash
-- (cx-3\/mj-6), case-folded target keys (mj-2\/3), archive-layer restriction
-- (mj-5), Names edge cases (mj-1).
module PlannerTests (plannerTests) where

import Data.Aeson (eitherDecodeStrict, encode)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, setModificationTime)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (chooseInt, elements, forAll, listOf1, suchThat, testProperty, (.&&.), (===))

import Pm.Clean
import Pm.Cli (bindExecRoot, recheckCleanItems)
import Pm.Commands (TrashCmd (..), resolveKeep, runTrash)
import Pm.Config (Config (..), writeRootInfo)
import Pm.Diff
import Pm.Doctor (Severity (..))
import Pm.Exec
import Pm.Hash (nsToUtc, sha256File)
import Pm.Import
import Pm.Names
import Pm.Journal (Sync (..))
import Pm.Op
import Pm.Plan
import Pm.Trash (TrashRecord (..), TrashView (..), appendManifest, trashDir, trashView)
import Pm.Types
import Pm.Undo (buildUndoPlan)

import TestUtil

plannerTests :: TestTree
plannerTests =
  testGroup
    "计划器 (P2/P2.1/P2.2)"
    [ namesTests
    , importTests
    , diffTests
    , backupE2eTests
    , cleanTests
    , groupSemanticsTests
    , planFormatTests
    , p22Tests
    ]

-- ─── Names（§8 子集 + mj-1 边角） ───────────────────────────────────────────

namesTests :: TestTree
namesTests =
  testGroup
    "Pm.Names"
    [ testCase "parseYYMM 正常" (parseYYMM "26-04-Providence" @?= Just (26, 4, "Providence"))
    , testCase "月份 13 拒绝" (parseYYMM "26-13-X" @?= Nothing)
    , testCase "无地点拒绝" (parseYYMM "26-04-" @?= Nothing)
    , testCase "无连字符拒绝" (parseYYMM "2604-X" @?= Nothing)
    , testCase "canonRawEvent 补 -Raw + 推导年份" $
        canonRawEvent "26-04-Providence" @?= Just ("2026", "26-04-Providence-Raw")
    , testCase "canonRawEvent 幂等（已带 -Raw）" $
        canonRawEvent "23-01-Cotswold-Raw" @?= Just ("2023", "23-01-Cotswold-Raw")
    , testCase "mj-1: 空地点 26-04--Raw 拒绝" (canonRawEvent "26-04--Raw" @?= Nothing)
    , testCase "mj-1: 裸后缀 26-04-Raw 拒绝（歧义）" (canonRawEvent "26-04-Raw" @?= Nothing)
    , testCase "mj-1: 小写 -raw 后缀接受并规范化" $
        canonRawEvent "23-01-cotswold-raw" @?= Just ("2023", "23-01-cotswold-Raw")
    , testCase "Scheme B 不猜（P3 的 pm names 处理）" $
        canonRawEvent "RAW-2025-Winter-Alaska" @?= Nothing
    , testCase "canonProcessedEvent 恒等" $
        canonProcessedEvent "26-04-Providence" @?= Just "26-04-Providence"
    , testCase "canonProcessedEvent 剥离误带的 -Raw" $
        canonProcessedEvent "23-04-EU-Raw" @?= Just "23-04-EU"
    , testCase "canonProcessedEvent 空地点拒绝" (canonProcessedEvent "26-04--Raw" @?= Nothing)
    , testCase "canonProcessedEvent 非事件名拒绝" (canonProcessedEvent "molly" @?= Nothing)
    , testProperty "parse/canon roundtrip + 幂等（QuickCheck）" $
        forAll
          ( (,,)
              <$> chooseInt (0, 99)
              <*> chooseInt (1, 12)
              -- 地点全小写字母且 ≠ "raw"（"YY-MM-raw" 会被判为裸后缀而拒绝，
              -- 那是 mj-1 的独立用例）
              <*> listOf1 (elements ['a' .. 'z']) `suchThat` (/= "raw")
          )
          $ \(yy, mm, loc) ->
            let name = pad2 yy <> "-" <> pad2 mm <> "-" <> loc
                canon = name <> "-Raw"
                yr = "20" <> pad2 yy
             in (parseYYMM name === Just (yy, mm, loc))
                  .&&. (canonRawEvent name === Just (yr, canon))
                  .&&. (canonRawEvent canon === Just (yr, canon))
    ]

-- ─── Import 计划器（纯） ────────────────────────────────────────────────────

importTests :: TestTree
importTests =
  testGroup
    "Pm.Import (§7)"
    [ testCase "staging Raw 事件 → Raw\\20YY\\…-Raw（侧车同批）" $ do
        let a = mkE ("To-Be-Sync'd" </> "Raw" </> "26-04-Providence" </> "A.ARW") "s1"
            x = mkE ("To-Be-Sync'd" </> "Raw" </> "26-04-Providence" </> "A.xmp") "s2"
            rep = planImport (mkCat [a, x])
        irCopy rep
          @?= [ (a, "Raw" </> "2026" </> "26-04-Providence-Raw" </> "A.ARW")
              , (x, "Raw" </> "2026" </> "26-04-Providence-Raw" </> "A.xmp")
              ]
    , testCase "staging Raw 带显式年份层（一致 → 接受）" $ do
        let a = mkE ("To-Be-Sync'd" </> "Raw" </> "2026" </> "26-06-R66" </> "B.ARW") "s1"
            rep = planImport (mkCat [a])
        irCopy rep @?= [(a, "Raw" </> "2026" </> "26-06-R66-Raw" </> "B.ARW")]
    , testCase "显式年份层与事件名年份不一致 → 不猜，unrecognized" $ do
        let a = mkE ("To-Be-Sync'd" </> "Raw" </> "2025" </> "26-06-R66" </> "B.ARW") "s1"
            rep = planImport (mkCat [a])
        (irCopy rep, irUnrecognized rep) @?= ([], [enPath a])
    , testCase "Processed 事件 → 成片\\事件" $ do
        let a = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "s1"
            rep = planImport (mkCat [a])
        irCopy rep @?= [(a, "成片" </> "26-06-R66" </> "c.jpg")]
    , testCase "目标已存在同 sha → 已归档冗余，不入计划" $ do
        let src = mkE ("To-Be-Sync'd" </> "Processed" </> "23-04-EU" </> "x.jpg") "same"
            dst = mkE ("成片" </> "23-04-EU" </> "x.jpg") "same"
            rep = planImport (mkCat [src, dst])
        (irCopy rep, irAlready rep) @?= ([], [(enPath src, enPath dst)])
    , testCase "mj-2: 已归档判定 case-fold（成片\\26-06-r66\\C.JPG 命中）" $ do
        let src = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "same"
            dst = mkE ("成片" </> "26-06-r66" </> "C.JPG") "same"
            rep = planImport (mkCat [src, dst])
        (irCopy rep, length (irAlready rep)) @?= ([], 1)
    , testCase "目标已存在不同 sha → 返修 NEEDS-DECISION" $ do
        let src = mkE ("To-Be-Sync'd" </> "Processed" </> "23-04-EU" </> "x.jpg") "new"
            dst = mkE ("成片" </> "23-04-EU" </> "x.jpg") "old"
            rep = planImport (mkCat [src, dst])
        irRework rep @?= [(src, enPath dst)]
        case importPlanItems "R:" rep of
          [PlanItem 0 OpCopy {} (StNeedsDecision _) Nothing] -> pure ()
          other -> assertFailure ("expected 1 needs-decision copy, got " <> show other)
    , testCase "待修改 不碰；顶层散文件 unrecognized" $ do
        let p = mkE ("To-Be-Sync'd" </> "待修改" </> "DSC08960.ARW") "s1"
            junk = mkE ("To-Be-Sync'd" </> "notes.txt") "s2"
            rep = planImport (mkCat [p, junk])
        (irPendingEdit rep, irUnrecognized rep, irCopy rep)
          @?= ([enPath p], [enPath junk], [])
    , testCase "mj-2/3: 大小写不同目标 → dup，且同 stem 侧车整组拒绝" $ do
        let a = mkE ("To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "D.ARW") "s1"
            b = mkE ("To-Be-Sync'd" </> "Raw" </> "2026" </> "26-06-r66" </> "d.arw") "s2"
            x = mkE ("To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "D.xmp") "s3"
            rep = planImport (mkCat [a, b, x])
        (irCopy rep, length (irDupTarget rep)) @?= ([], 3)
    , testCase "importPlanItems: src 绝对化 + 前置条件来自 catalog" $ do
        let e = (mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "abc") {enSize = 7, enMtimeNs = 99}
            rep = planImport (mkCat [e])
        case importPlanItems ("R:" </> "lib") rep of
          [PlanItem 0 (OpCopy src dst sha sz mt) StPending Nothing] -> do
            src @?= ("R:" </> "lib" </> enPath e)
            dst @?= ("成片" </> "26-06-R66" </> "c.jpg")
            (sha, sz, mt) @?= ("abc", 7, 99)
          other -> assertFailure ("unexpected items: " <> show other)
    , testCase "stagingArchivedSummary 排除 待修改" $ do
        let s1 = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "x"
            s2 = mkE ("To-Be-Sync'd" </> "待修改" </> "y.ARW") "y"
            a1 = mkE ("成片" </> "26-06-R66" </> "c.jpg") "x"
        stagingArchivedSummary (mkCat [s1, s2, a1]) @?= (1, 1)
    ]

-- ─── 备份 diff（纯）+ 端到端 fixture ────────────────────────────────────────

diffTests :: TestTree
diffTests =
  testGroup
    "Pm.Diff.backupDiff (§9)"
    [ testCase "add / update / extra / same 分类" $ do
        let m1 = mkE ("成片" </> "a.jpg") "A"
            m2 = mkE ("成片" </> "b.jpg") "B"
            m3 = mkE ("成片" </> "c.jpg") "C-new"
            b2 = mkE ("成片" </> "b.jpg") "B"
            b3 = mkE ("成片" </> "c.jpg") "C-old"
            b4 = mkE ("成片" </> "extra.jpg") "E"
            d = backupDiff (mkCat [m1, m2, m3]) (mkCat [b2, b3, b4])
        (bdAdd d, bdUpdate d, bdExtra d, bdSame d)
          @?= ([m1], [(m3, b3)], [enPath b4], 1)
    , testCase "update → supersede 同组：隔离在前、Copy 在后、同一相对路径" $ do
        let m = mkE ("成片" </> "c.jpg") "C-new"
            b = mkE ("成片" </> "c.jpg") "C-old"
            d = backupDiff (mkCat [m]) (mkCat [b])
        case backupPlanItems "M:" d of
          [PlanItem 0 (OpQuarantine v vs _) StPending (Just gq), PlanItem 1 (OpCopy src dst sha _ _) StPending (Just gc)] -> do
            (v, vs) @?= (enPath b, "C-old")
            (src, dst, sha) @?= ("M:" </> enPath m, enPath m, "C-new")
            gq @?= gc -- cx-2: 配对共享组 id，不可拆
          other -> assertFailure ("unexpected items: " <> show other)
    ]

backupE2eTests :: TestTree
backupE2eTests =
  testGroup
    "backup 端到端 (fixture 双 root)"
    [ testCase "首备落位 → 再 diff 清零；EXTRA 永不动" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let mroot = dir </> "main"
              broot = dir </> "bak"
          createDirectoryIfMissing True (mroot </> "成片" </> "26-06-R66")
          createDirectoryIfMissing True broot
          writeFile (mroot </> "成片" </> "26-06-R66" </> "a.jpg") "AAA"
          writeFile (mroot </> "成片" </> "26-06-R66" </> "b.jpg") "BBB"
          writeFile (broot </> "extra.jpg") "EX"
          mcat <- scanQuiet "m" mroot
          bcat0 <- scanQuiet "b" broot
          let d0 = backupDiff mcat bcat0
          (length (bdAdd d0), bdExtra d0) @?= (2, ["extra.jpg"])
          plan <- mkBackupPlan broot (backupPlanItems mroot d0)
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE", "DONE"]
          a <- readFile (broot </> "成片" </> "26-06-R66" </> "a.jpg")
          a @?= "AAA"
          bcat1 <- scanQuiet "b" broot
          let d1 = backupDiff mcat bcat1
          (length (bdAdd d1), length (bdUpdate d1), bdSame d1, bdExtra d1)
            @?= (0, 0, 2, ["extra.jpg"])
          ex <- readFile (broot </> "extra.jpg")
          ex @?= "EX"
    , testCase "主库更新 → supersede：备份旧字节入备份盘 trash，新字节落位" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let mroot = dir </> "main"
              broot = dir </> "bak"
          createDirectoryIfMissing True (mroot </> "成片")
          createDirectoryIfMissing True (broot </> "成片")
          writeFile (mroot </> "成片" </> "a.jpg") "AAA-NEW!"
          writeFile (broot </> "成片" </> "a.jpg") "AAA"
          mcat <- scanQuiet "m" mroot
          bcat <- scanQuiet "b" broot
          let d = backupDiff mcat bcat
          length (bdUpdate d) @?= 1
          plan <- mkBackupPlan broot (backupPlanItems mroot d)
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE", "DONE"]
          newC <- readFile (broot </> "成片" </> "a.jpg")
          newC @?= "AAA-NEW!"
          tv <- trashView broot
          case tvRegistered tv of
            [(r, True)] -> do
              oldC <- readFile (trashDir broot </> trTrashRel r)
              oldC @?= "AAA"
            other -> assertFailure ("expected 1 trash entry on backup root, got " <> show (length other))
    , testCase "Done Barrier 模式（备份路径）行为一致" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "BARRIER" ("成片" </> "s.jpg")
          plan <- mkPlanIO root [op]
          r <- execPlan defaultExecEnv {eeDoneSync = Barrier} plan
          case r of
            Right [(_, ODone {})] -> pure ()
            other -> assertFailure ("expected done, got " <> show other)
    ]

-- ─── clean staging（三副本前置） ────────────────────────────────────────────

cleanTests :: TestTree
cleanTests =
  testGroup
    "Pm.Clean"
    [ testCase "三副本齐 → eligible（带两侧见证）" $ do
        let s = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "X"
            a = mkE ("成片" </> "26-06-R66" </> "c.jpg") "X"
            b = mkE ("成片" </> "26-06-R66" </> "c.jpg") "X"
            rep = planClean (mkCat [s, a]) (mkCat [b])
        case clEligible rep of
          [c] -> (ccStaging c, ccArchiveCopies c, ccBackupCopies c) @?= (s, [a], [b])
          other -> assertFailure ("expected 1 eligible, got " <> show (length other))
        clHeld rep @?= []
    , testCase "缺备份副本 → HELD" $ do
        let s = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "X"
            a = mkE ("成片" </> "26-06-R66" </> "c.jpg") "X"
            rep = planClean (mkCat [s, a]) (mkCat [])
        (clEligible rep, map fst (clHeld rep)) @?= ([], [enPath s])
        case clHeld rep of
          [(_, why)] -> assertBool why ("备份盘无此内容" `elemSubstr` why)
          _ -> assertFailure "expected 1 held"
    , testCase "缺归档副本 → HELD" $ do
        let s = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "X"
            b = mkE ("成片" </> "26-06-R66" </> "c.jpg") "X"
            rep = planClean (mkCat [s]) (mkCat [b])
        case clHeld rep of
          [(p, why)] -> do
            p @?= enPath s
            assertBool why ("主库归档层无此内容" `elemSubstr` why)
          _ -> assertFailure "expected 1 held"
    , testCase "mj-5: 只有相册副本 → HELD（归档层限 Raw/成片）" $ do
        let s = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "X"
            alb = mkE ("相册" </> "c.jpg") "X"
            rep = planClean (mkCat [s, alb]) (mkCat [alb])
        case clHeld rep of
          [(_, why)] -> assertBool why ("主库归档层无此内容" `elemSubstr` why)
          other -> assertFailure ("expected 1 held, got " <> show other)
    , testCase "待修改 从不清理" $ do
        let s = mkE ("To-Be-Sync'd" </> "待修改" </> "y.ARW") "X"
            a = mkE ("Raw" </> "2023" </> "y.ARW") "X"
            rep = planClean (mkCat [s, a]) (mkCat [a])
        (clEligible rep, clHeld rep, clPendingEdit rep) @?= ([], [], [enPath s])
    , testCase "mj-6: verifyCandidates 真实重 hash——同尺寸篡改也降级 HELD" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let mroot = dir </> "main"
              broot = dir </> "bak"
          createDirectoryIfMissing True (mroot </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66")
          createDirectoryIfMissing True (mroot </> "成片" </> "26-06-R66")
          createDirectoryIfMissing True (broot </> "成片" </> "26-06-R66")
          writeFile (mroot </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "X3"
          writeFile (mroot </> "成片" </> "26-06-R66" </> "c.jpg") "X3"
          writeFile (broot </> "成片" </> "26-06-R66" </> "c.jpg") "X3"
          mcat <- scanQuiet "m" mroot
          bcat <- scanQuiet "b" broot
          let rep = planClean mcat bcat
          length (clEligible rep) @?= 1
          -- 正例：真实重 hash 通过
          (ok1, held1) <- verifyCandidates mroot broot (clEligible rep)
          (length ok1, held1) @?= (1, [])
          -- 反例：备份见证被篡改为同长度不同内容 → hash 抓到，降级
          writeFile (broot </> "成片" </> "26-06-R66" </> "c.jpg") "Y9"
          (ok2, held2) <- verifyCandidates mroot broot (clEligible rep)
          length ok2 @?= 0
          case held2 of
            [(_, why)] -> assertBool why ("备份副本内容核对不过" `elemSubstr` why)
            _ -> assertFailure "expected 1 demoted"
    , testCase "端到端：quarantine 计划落 trash 且保相对路径" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let mroot = dir </> "main"
              srel = "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg"
          createDirectoryIfMissing True (mroot </> takeDirectory srel)
          createDirectoryIfMissing True (mroot </> "成片" </> "26-06-R66")
          writeFile (mroot </> srel) "X9"
          writeFile (mroot </> "成片" </> "26-06-R66" </> "c.jpg") "X9"
          mcat <- scanQuiet "m" mroot
          -- 备份 catalog 直接用主库 catalog 模拟（clean 只看 sha 集合）
          let rep = planClean mcat mcat
          plan <- mkCleanPlan mroot (cleanPlanItems (clEligible rep))
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE"]
          stEx <- doesFileExist (mroot </> srel)
          stEx @?= False
          c <- readFile (trashDir mroot </> T.unpack (plId plan) </> srel)
          c @?= "X9"
          -- 归档副本原封不动
          keep <- readFile (mroot </> "成片" </> "26-06-R66" </> "c.jpg")
          keep @?= "X9"
    , testCase "cx-3: threeCopiesStillExist 见证消失 → False" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let mroot = dir </> "main"
              broot = dir </> "bak"
          createDirectoryIfMissing True (mroot </> "成片")
          createDirectoryIfMissing True (broot </> "成片")
          writeFile (mroot </> "成片" </> "c.jpg") "W1"
          writeFile (broot </> "成片" </> "c.jpg") "W1"
          mcat <- scanQuiet "m" mroot
          bcat <- scanQuiet "b" broot
          sha <- sha256File (mroot </> "成片" </> "c.jpg")
          ok1 <- threeCopiesStillExist mroot mcat broot bcat sha
          ok1 @?= True
          -- 备份见证内容改变（catalog 未变）→ 拒绝
          writeFile (broot </> "成片" </> "c.jpg") "Z9"
          ok2 <- threeCopiesStillExist mroot mcat broot bcat sha
          ok2 @?= False
    ]

-- ─── P2.1 组语义 / root 身份 ────────────────────────────────────────────────

groupSemanticsTests :: TestTree
groupSemanticsTests =
  testGroup
    "Exec 组语义 + root 身份 (cx-1/cx-2)"
    [ testCase "groupClosure: 选组内任一项 → 全组" $ do
        plan <-
          mkGroupPlanIO
            "R:"
            [ (OpQuarantine "a" "aa" "t", Just 0)
            , (OpCopy "S:x" "a" "bb" 1 0, Just 0)
            , (OpQuarantine "b" "cc" "t", Nothing)
            ]
        groupClosure plan [1] @?= [0, 1]
        groupClosure plan [2] @?= [2]
        groupClosure plan [0, 2] @?= [0, 1, 2]
    , testCase "cx-2: 组内 Copy 失败 → Quarantine 自动复位；doctor 无 Bad；undo 无残留" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "成片")
          writeFile (root </> "成片" </> "a.jpg") "OLD"
          oldSha <- sha256File (root </> "成片" </> "a.jpg")
          op <- mkCopyOp (dir </> "s.jpg") "NEW!" ("成片" </> "a.jpg")
          -- 源前置条件故意错（size+1）→ Copy 必然 OConflict
          let badCopy = case op of
                OpCopy s d h sz mt -> OpCopy s d h (sz + 1) mt
                other -> other
          plan <-
            mkGroupPlanIO
              root
              [ (OpQuarantine ("成片" </> "a.jpg") oldSha "supersede:test", Just 0)
              , (badCopy, Just 0)
              ]
          rs <- execOk plan
          case map snd rs of
            [q, c] -> do
              assertBool ("quarantine outcome: " <> show q) $
                case q of OFailed m -> "复位" `elemSubstr` m; _ -> False
              assertBool ("copy outcome: " <> show c) $
                case c of OConflict m -> "已自动复位" `elemSubstr` m; _ -> False
            other -> assertFailure (show other)
          back <- readFile (root </> "成片" </> "a.jpg")
          back @?= "OLD"
          -- 崩溃窗口（去掉 CleanShutdown）下 doctor 不把复位误报为 C4 CORRUPT
          es <- journalEntries root
          truncateJournalTo root (filter (not . isClean) es)
          rows <- doctorRows root
          [r | r@(_, sev) <- rows, sev == Bad] @?= []
          assertBool ("expected Q-RESTORED in " <> show rows) (("Q-RESTORED", Info) `elem` rows)
          -- 复位对是净零，不产生可撤销项
          ur <- buildUndoPlan root 1
          case ur of
            Left msg -> assertBool msg ("没有可撤销" `elemSubstr` msg)
            Right p -> assertFailure ("expected no undoable ops, got " <> show (length (plItems p)))
    , testCase "cx-2: 崩溃后同计划重跑——幂等 Quarantine 续跑 Copy" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "成片")
          writeFile (root </> "成片" </> "a.jpg") "OLD"
          oldSha <- sha256File (root </> "成片" </> "a.jpg")
          op <- mkCopyOp (dir </> "s.jpg") "NEW!" ("成片" </> "a.jpg")
          plan <-
            mkGroupPlanIO
              root
              [ (OpQuarantine ("成片" </> "a.jpg") oldSha "supersede:test", Just 0)
              , (op, Just 0)
              ]
          -- 中断点：隔离已完成、Copy 刚写完 Intent
          runCrash (injectAt CpCopyAfterIntent) plan
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE", "DONE"]
          newC <- readFile (root </> "成片" </> "a.jpg")
          newC @?= "NEW!"
          oldC <- readFile (trashDir root </> T.unpack (plId plan) </> "成片" </> "a.jpg")
          oldC @?= "OLD"
    , testCase "cx-1: eeExpectRootId 不符 → 整批拒绝；相符 → 执行" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          now <- getCurrentTime
          writeRootInfo root (RootInfo "rid-A" RoleMain now Nothing)
          op <- mkCopyOp (dir </> "s.jpg") "DATA" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          r <- execPlan defaultExecEnv {eeExpectRootId = Just "rid-B"} plan
          case r of
            Left msg -> assertBool msg ("root 标识不符" `elemSubstr` msg)
            Right _ -> assertFailure "expected refusal on rootId mismatch"
          dstEx <- doesFileExist (root </> "相册" </> "a.jpg")
          dstEx @?= False
          r2 <- execPlan defaultExecEnv {eeExpectRootId = Just "rid-A"} plan
          case r2 of
            Right [(_, ODone {})] -> pure ()
            other -> assertFailure ("expected done with matching id, got " <> show other)
    ]

-- ─── 计划文件格式兼容 ───────────────────────────────────────────────────────

planFormatTests :: TestTree
planFormatTests =
  testGroup
    "Plan 持久化格式"
    [ testCase "P2 旧格式（无 rootId/group）仍可解析为 Nothing" $ do
        let legacy =
              "{\"id\":\"p\",\"kind\":\"import\",\"root\":\"D:\\\\X\",\"created\":\"2026-01-01T00:00:00Z\",\
              \\"items\":[{\"ix\":0,\"op\":{\"t\":\"quarantine\",\"victim\":\"a\",\"sha256\":\"aa\",\"reason\":\"r\"},\
              \\"status\":{\"s\":\"pending\"}}]}"
        case eitherDecodeStrict (BSC.pack legacy) :: Either String Plan of
          Right p -> (plRootId p, map piGroup (plItems p)) @?= (Nothing, [Nothing])
          Left e -> assertFailure e
    , testCase "新字段 roundtrip（rootId/group 编解码保真）" $ do
        plan <- mkGroupPlanIO "R:" [(OpQuarantine "a" "aa" "t", Just 7)]
        let plan' = plan {plRootId = Just "rid-42"}
        case eitherDecodeStrict (BSL.toStrict (encode plan')) :: Either String Plan of
          Right p -> (plRootId p, map piGroup (plItems p)) @?= (Just "rid-42", [Just 7])
          Left e -> assertFailure e
    ]

-- ─── P2.2（复审二轮修复） ───────────────────────────────────────────────────

p22Tests :: TestTree
p22Tests =
  testGroup
    "P2.2 (复审二轮)"
    [ testCase "mj-3v2: 返修主文件 → 同 stem 侧车悬置（不入 irCopy）" $ do
        let master = mkE ("To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "E.ARW") "new"
            side = mkE ("To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "E.xmp") "sidecar"
            dstOld = mkE ("Raw" </> "2026" </> "26-06-R66-Raw" </> "E.ARW") "old"
            rep = planImport (mkCat [master, side, dstOld])
        (irCopy rep, length (irRework rep), length (irReworkKin rep)) @?= ([], 1, 1)
        let sts = [piStatus it | it <- importPlanItems "R:" rep]
        length [() | StNeedsDecision _ <- sts] @?= 2
    , testCase "P2.2: 复位后同计划重跑成功——第二次隔离不被误豁免，undo 可用" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "成片")
          writeFile (root </> "成片" </> "a.jpg") "OLD"
          oldSha <- sha256File (root </> "成片" </> "a.jpg")
          op <- mkCopyOp (dir </> "s.jpg") "NEW!" ("成片" </> "a.jpg")
          let origMt = case op of
                OpCopy _ _ _ _ mt -> mt
                _ -> 0
          -- 篡改源（size 变）→ 第一轮 Copy 必然冲突 → 自动复位
          writeFile (dir </> "s.jpg") "NEW!X"
          plan <-
            mkGroupPlanIO
              root
              [ (OpQuarantine ("成片" </> "a.jpg") oldSha "supersede:test", Just 0)
              , (op, Just 0)
              ]
          rs1 <- execOk plan
          case map snd rs1 of
            [OFailed _, OConflict _] -> pure ()
            other -> assertFailure ("round1: " <> show other)
          back <- readFile (root </> "成片" </> "a.jpg")
          back @?= "OLD"
          -- 修好源（内容与 mtime 还原到计划前提）→ 第二轮重跑同一计划
          writeFile (dir </> "s.jpg") "NEW!"
          setModificationTime (dir </> "s.jpg") (nsToUtc origMt)
          rs2 <- execOk plan
          map (outcomeLabel . snd) rs2 @?= ["DONE", "DONE"]
          newC <- readFile (root </> "成片" </> "a.jpg")
          newC @?= "NEW!"
          let trashFile = trashDir root </> T.unpack (plId plan) </> "成片" </> "a.jpg"
          oldC <- readFile trashFile
          oldC @?= "OLD"
          -- 制造验证窗口（去 CleanShutdown）：trash 完好 → 无 Bad
          es <- journalEntries root
          truncateJournalTo root (filter (not . isClean) es)
          rows0 <- doctorRows root
          [r | r@(_, sev) <- rows0, sev == Bad] @?= []
          -- undo 顺序感知：第二轮的 Q+C 仍可撤销（旧全局豁免会吞掉）
          ur <- buildUndoPlan root 2
          case ur of
            Right up -> length (plItems up) @?= 2
            Left msg -> assertFailure msg
          -- 尖锐断言：外力删掉 trash 文件 → 第二次隔离的 Done 必须报 C4，
          -- 不得被第一轮的 ~r 复位记录豁免
          removeFile trashFile
          rows1 <- doctorRows root
          assertBool ("expected C4 after trash loss, got " <> show rows1)
            (("C4", Bad) `elem` rows1)
    , testCase "P2.2: 同 trashRel 双 manifest 记录 → trash empty 去重一次清除" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
              rel = "p" </> "v.jpg"
          createDirectoryIfMissing True (trashDir root </> "p")
          writeFile (trashDir root </> rel) "V"
          now <- getCurrentTime
          let rec1 = TrashRecord "v.jpg" rel "aa" "supersede:test" "p" now
          appendManifest root rec1
          appendManifest root rec1
          let cfg = Config root Nothing Nothing Nothing Nothing Nothing
          code <- runTrash cfg (TrashEmpty True) root
          code @?= 0
          ex <- doesFileExist (trashDir root </> rel)
          ex @?= False
    , testCase "P2.2: recheckCleanItems 执行期见证退化 → 全项降级" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let mroot = dir </> "main"
              broot = dir </> "bak"
          createDirectoryIfMissing True (mroot </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66")
          createDirectoryIfMissing True (mroot </> "成片")
          createDirectoryIfMissing True (broot </> "成片")
          writeFile (mroot </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "K7"
          writeFile (mroot </> "成片" </> "c.jpg") "K7"
          writeFile (broot </> "成片" </> "c.jpg") "K7"
          mcat <- scanQuiet "m" mroot
          bcat <- scanQuiet "b" broot
          let rep = planClean mcat bcat
          plan <- mkCleanPlan mroot (cleanPlanItems (clEligible rep))
          length (plItems plan) @?= 1
          -- 计划保存后世界变了：备份见证退化
          writeFile (broot </> "成片" </> "c.jpg") "XX"
          plan' <- recheckCleanItems mroot mcat broot bcat plan
          case map piStatus (plItems plan') of
            [StNeedsDecision _] -> pure ()
            other -> assertFailure ("expected demotion, got " <> show other)
    , testCase "P2.2: bindExecRoot 主库 UUID 校验 + 重绑定" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          now <- getCurrentTime
          writeRootInfo root (RootInfo "rid-A" RoleMain now Nothing)
          let cfg = Config root Nothing Nothing Nothing Nothing Nothing
          plan0 <- mkPlanIO (dir </> "stale-path") []
          let plan = plan0 {plKind = "import"}
          r <- bindExecRoot cfg plan "rid-A"
          case r of
            Right p -> plRootPath p @?= root -- 重绑定到当前主库路径
            Left e -> assertFailure e
          r2 <- bindExecRoot cfg plan "rid-B"
          case r2 of
            Left msg -> assertBool msg ("不符" `elemSubstr` msg)
            Right _ -> assertFailure "expected mismatch refusal"
    , testCase "P2.2: --keep 拒绝复合组成员与非待裁决条目" $ do
        gplan <- mkGroupPlanIO "R:" [(OpCopy "S:x" "a" "bb" 1 0, Just 0)]
        c1 <- case plItems gplan of
          [it] -> resolveKeep gplan it "dst"
          _ -> assertFailure "one item expected" >> pure 99
        c1 @?= 2
        splan <- mkPlanIO "R:" [OpCopy "S:x" "a" "bb" 1 0] -- StPending，非待裁决
        c2 <- case plItems splan of
          [it] -> resolveKeep splan it "dst"
          _ -> assertFailure "one item expected" >> pure 99
        c2 @?= 2
    ]

-- 本地小工具：直接给 Plan 构造记录（备份/清理 e2e 用）
mkBackupPlan :: FilePath -> [PlanItem] -> IO Plan
mkBackupPlan broot items = do
  pid <- newPlanId
  now <- getCurrentTime
  pure Plan {plId = pid, plKind = "backup", plRootPath = broot, plRootId = Nothing, plCreated = now, plItems = items}

mkCleanPlan :: FilePath -> [PlanItem] -> IO Plan
mkCleanPlan mroot items = do
  pid <- newPlanId
  now <- getCurrentTime
  pure Plan {plId = pid, plKind = "clean-staging", plRootPath = mroot, plRootId = Nothing, plCreated = now, plItems = items}
