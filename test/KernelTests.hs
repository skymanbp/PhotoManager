{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | P0/P1 tests: hashing, catalog, the fail-if-exists move primitive, the
-- three Exec protocols, dual-mode fault injection against the doctor matrix
-- (DESIGN.md §6.4, §13), undo round-trips, and the instance lock.
module KernelTests (kernelTests) where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), runDoctor)
import Pm.Exec
import Pm.Hash
import Pm.Journal
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Trash
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Win (moveFileNoReplace)
import System.IO.Temp (withSystemTempDirectory)

import TestUtil

kernelTests :: TestTree
kernelTests =
  testGroup
    "安全内核 (P0/P1)"
    [ hashTests
    , classifyTests
    , catalogTests
    , moveTests
    , execCopyTests
    , execRenameTests
    , execQuarantineTests
    , injectionTests
    , doctorTests
    , undoTests
    , lockTests
    ]

hashTests :: TestTree
hashTests =
  testGroup
    "Pm.Hash"
    [ testCase "sha256 of empty file (NIST vector)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let fp = dir </> "empty.bin"
          writeFile fp ""
          h <- sha256File fp
          h @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    , testCase "sha256 of \"abc\" (NIST vector)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let fp = dir </> "abc.bin"
          writeFile fp "abc"
          h <- sha256File fp
          h @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    , testCase "copyFileHashed writes + hashes + flushes" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          writeFile (dir </> "s.bin") "abc"
          h <- copyFileHashed (dir </> "s.bin") (dir </> "d.bin")
          h @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
          c <- readFile (dir </> "d.bin")
          c @?= "abc"
    ]

classifyTests :: TestTree
classifyTests =
  testGroup
    "Pm.Types.classifyExt (case-fold)"
    [ testCase ".JPG is photo" (classifyExt ".JPG" @?= KindPhoto)
    , testCase ".arw is photo" (classifyExt ".arw" @?= KindPhoto)
    , testCase ".Xmp is sidecar" (classifyExt ".Xmp" @?= KindSidecar)
    , testCase ".acr is sidecar" (classifyExt ".acr" @?= KindSidecar)
    , testCase ".txt is meta" (classifyExt ".txt" @?= KindMeta)
    ]

catalogTests :: TestTree
catalogTests =
  testGroup
    "Pm.Catalog"
    [ testCase "save/load roundtrip incl. CJK path" $
        withSystemTempDirectory "pm-test" $ \root -> do
          now <- getCurrentTime
          let e1 = Entry ("相册" </> "测试照片.JPG") 42 123456789 "aa" KindPhoto (Just now)
              e2 = Entry ("Raw" </> "2023" </> "x.ARW") 7 9 "bb" KindPhoto (Just now)
              cat = Catalog "rid-1" now (entryMap [e1, e2])
          saveCatalog root cat
          (loaded, warns) <- loadCatalog root
          warns @?= []
          fmap catRootId loaded @?= Just "rid-1"
          fmap catEntries loaded @?= Just (catEntries cat)
    , testCase "rotation keeps 3 generations, newest wins" $
        withSystemTempDirectory "pm-test" $ \root -> do
          now <- getCurrentTime
          let mk rid = Catalog rid now (entryMap [])
          mapM_ (saveCatalog root . mk) ["g1", "g2", "g3", "g4"]
          let base = catalogPath root
          e0 <- doesFileExist base
          e1 <- doesFileExist (base <> ".1")
          e2 <- doesFileExist (base <> ".2")
          (e0, e1, e2) @?= (True, True, True)
          (loaded, _) <- loadCatalog root
          fmap catRootId loaded @?= Just "g4"
    ]

moveTests :: TestTree
moveTests =
  testGroup
    "Pm.Win.moveFileNoReplace (I5 cornerstone)"
    [ testCase "refuses when destination exists" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          writeFile (dir </> "a.txt") "AAA"
          writeFile (dir </> "b.txt") "BBB"
          r <- try (moveFileNoReplace (dir </> "a.txt") (dir </> "b.txt")) :: IO (Either IOException ())
          case r of
            Left _ -> pure ()
            Right () -> assertFailure "moveFileNoReplace overwrote an existing destination"
          ca <- readFile (dir </> "a.txt")
          cb <- readFile (dir </> "b.txt")
          (ca, cb) @?= ("AAA", "BBB")
    , testCase "moves when destination absent" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          writeFile (dir </> "a.txt") "AAA"
          moveFileNoReplace (dir </> "a.txt") (dir </> "c.txt")
          ea <- doesFileExist (dir </> "a.txt")
          cc <- readFile (dir </> "c.txt")
          (ea, cc) @?= (False, "AAA")
    ]

execCopyTests :: TestTree
execCopyTests =
  testGroup
    "Exec.Copy (§6.1)"
    [ testCase "happy path: bytes land, journal Intent+Done+CleanShutdown, tmp gone" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "src" </> "a.jpg") "PHOTO-BYTES" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE"]
          c <- readFile (root </> "相册" </> "a.jpg")
          c @?= "PHOTO-BYTES"
          src <- readFile (dir </> "src" </> "a.jpg")
          src @?= "PHOTO-BYTES" -- 源永不被触碰
          es <- journalEntries root
          (length (filter isIntent es), length (filter isDone es), length (filter isClean es))
            @?= (1, 1, 1)
          tmpEx <- doesFileExist (tmpDirFor root (plId plan) </> tmpNameFor 0 ("相册" </> "a.jpg"))
          tmpEx @?= False
    , testCase "identical dst → SKIP, no journal entries" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          writeFile (root </> "相册" </> "a.jpg") "SAME"
          op <- mkCopyOp (dir </> "s.jpg") "SAME" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          rs <- execOk plan
          case rs of
            [(_, OSkippedIdentical)] -> pure ()
            other -> assertFailure ("expected skip, got " <> show (map snd other))
          es <- journalEntries root
          filter isIntent es @?= []
    , testCase "different dst → CONFLICT, dst untouched (I5)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          writeFile (root </> "相册" </> "a.jpg") "THEIRS"
          op <- mkCopyOp (dir </> "s.jpg") "MINE" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          rs <- execOk plan
          case rs of
            [(_, OConflict _)] -> pure ()
            other -> assertFailure ("expected conflict, got " <> show (map snd other))
          c <- readFile (root </> "相册" </> "a.jpg")
          c @?= "THEIRS"
    , testCase "source changed after plan → CONFLICT, nothing written" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "V1" ("相册" </> "a.jpg")
          writeFile (dir </> "s.jpg") "V2-LONGER" -- 破坏前置条件
          plan <- mkPlanIO root [op]
          rs <- execOk plan
          case rs of
            [(_, OConflict _)] -> pure ()
            other -> assertFailure ("expected conflict, got " <> show (map snd other))
          dstEx <- doesFileExist (root </> "相册" </> "a.jpg")
          dstEx @?= False
    , testCase "dst appears during write window → CONFLICT, interloper intact, tmp retained" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "MINE" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          let env =
                defaultExecEnv
                  { eeCheckpoint = \c -> when (c == CpCopyAfterFlush) $ do
                      createDirectoryIfMissing True (root </> "相册")
                      writeFile (root </> "相册" </> "a.jpg") "INTERLOPER"
                  }
          r <- execPlan env plan
          case r of
            Right [(_, OConflict _)] -> pure ()
            other -> assertFailure ("expected DstAppeared conflict, got " <> show other)
          c <- readFile (root </> "相册" </> "a.jpg")
          c @?= "INTERLOPER"
          tmpEx <- doesFileExist (tmpDirFor root (plId plan) </> tmpNameFor 0 ("相册" </> "a.jpg"))
          tmpEx @?= True
    ]

execRenameTests :: TestTree
execRenameTests =
  testGroup
    "Exec.Rename (§6.2)"
    [ testCase "file rename happy path with sha fingerprint" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "Raw")
          writeFile (root </> "Raw" </> "old.arw") "RAWDATA"
          sha <- sha256File (root </> "Raw" </> "old.arw")
          plan <- mkPlanIO root [OpRename ("Raw" </> "old.arw") ("Raw" </> "new.arw") (FpFileSha sha)]
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE"]
          newC <- readFile (root </> "Raw" </> "new.arw")
          newC @?= "RAWDATA"
          oldEx <- doesFileExist (root </> "Raw" </> "old.arw")
          oldEx @?= False
    , testCase "dir rename with dir fingerprint" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "Raw" </> "RAW-2025-Winter-Alaska")
          writeFile (root </> "Raw" </> "RAW-2025-Winter-Alaska" </> "x.arw") "X"
          fp <- dirFingerprint (root </> "Raw" </> "RAW-2025-Winter-Alaska")
          plan <-
            mkPlanIO
              root
              [OpRename ("Raw" </> "RAW-2025-Winter-Alaska") ("Raw" </> "25-11-Alaska-Raw") (FpDir fp)]
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE"]
          x <- readFile (root </> "Raw" </> "25-11-Alaska-Raw" </> "x.arw")
          x @?= "X"
    , testCase "target exists → CONFLICT, both untouched" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "a.txt") "A"
          writeFile (root </> "b.txt") "B"
          sha <- sha256File (root </> "a.txt")
          plan <- mkPlanIO root [OpRename "a.txt" "b.txt" (FpFileSha sha)]
          rs <- execOk plan
          case rs of
            [(_, OConflict _)] -> pure ()
            other -> assertFailure ("expected conflict, got " <> show (map snd other))
          (,) <$> readFile (root </> "a.txt") <*> readFile (root </> "b.txt") >>= (@?= ("A", "B"))
    , testCase "fingerprint mismatch → CONFLICT (object drifted)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "a.txt") "DRIFTED"
          plan <- mkPlanIO root [OpRename "a.txt" "b.txt" (FpFileSha "0000")]
          rs <- execOk plan
          case rs of
            [(_, OConflict _)] -> pure ()
            other -> assertFailure ("expected conflict, got " <> show (map snd other))
    ]

execQuarantineTests :: TestTree
execQuarantineTests =
  testGroup
    "Exec.Quarantine (§6.3)"
    [ testCase "happy path: victim in trash, manifest + journal agree" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          writeFile (root </> "相册" </> "v.jpg") "VICTIM"
          sha <- sha256File (root </> "相册" </> "v.jpg")
          plan <- mkPlanIO root [OpQuarantine ("相册" </> "v.jpg") sha "test-clean"]
          rs <- execOk plan
          case rs of
            [(_, ODone _ _ (Just trashRel))] -> do
              c <- readFile (trashDir root </> trashRel)
              c @?= "VICTIM"
              origEx <- doesFileExist (root </> "相册" </> "v.jpg")
              origEx @?= False
              tv <- trashView root
              length (tvRegistered tv) @?= 1
              tvUnregistered tv @?= []
            other -> assertFailure ("expected quarantine done, got " <> show (map snd other))
    , testCase "victim content drifted → CONFLICT, untouched" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "v.jpg") "NOW-DIFFERENT"
          plan <- mkPlanIO root [OpQuarantine "v.jpg" "beef" "test"]
          rs <- execOk plan
          case rs of
            [(_, OConflict _)] -> pure ()
            other -> assertFailure ("expected conflict, got " <> show (map snd other))
          ex <- doesFileExist (root </> "v.jpg")
          ex @?= True
    ]

injectionTests :: TestTree
injectionTests =
  testGroup
    "故障注入 → doctor 矩阵 (§6.4, §13 P3)"
    [ copyCrashCase CpCopyAfterDstCheck [] -- intent 前 → 无痕迹无发现
    , copyCrashCase CpCopyAfterIntent [("C1", Info)]
    , copyCrashCase CpCopyAfterTmp [("C1", Warn)]
    , copyCrashCase CpCopyAfterFlush [("C1", Warn)]
    , copyCrashCase CpCopyAfterMove [("C2", Warn)]
    , testCase "C2 --repair 补记 Done 后收敛" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "DATA" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          runCrash (injectAt CpCopyAfterMove) plan
          _ <- runDoctor root (DoctorOpts False True) -- repair
          rows <- doctorRows root
          [r | r@(tag, _) <- rows, tag `elem` ["C1", "C2", "C5"]] @?= []
    , renameCrashCase CpRenAfterIntent [("R1", Info)]
    , renameCrashCase CpRenAfterMove [("R2", Warn)]
    , testCase "R2 --repair 补记 Done 后收敛" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "old.txt") "R"
          sha <- sha256File (root </> "old.txt")
          plan <- mkPlanIO root [OpRename "old.txt" "new.txt" (FpFileSha sha)]
          runCrash (injectAt CpRenAfterMove) plan
          _ <- runDoctor root (DoctorOpts False True)
          rows <- doctorRows root
          [r | r@(tag, _) <- rows, tag `elem` ["R1", "R2"]] @?= []
    , testCase "Quarantine 注入 (intent 后崩) → Q2, victim 原位" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "v.jpg") "V"
          sha <- sha256File (root </> "v.jpg")
          plan <- mkPlanIO root [OpQuarantine "v.jpg" sha "test"]
          runCrash (injectAt CpQuarAfterIntent) plan
          rows <- doctorRows root
          assertBool ("expected Q2 in " <> show rows) (("Q2", Info) `elem` rows)
          ex <- doesFileExist (root </> "v.jpg")
          ex @?= True
    , testCase "掉电模型: journal 尾部截断（丢 Done+CleanShutdown）→ C2" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "PWR" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          _ <- execOk plan
          -- 只保留 Intent 行 = Done/CleanShutdown 未落盘的掉电状态
          es <- journalEntries root
          let intentOnly = filter isIntent es
          truncateJournalTo root intentOnly
          rows <- doctorRows root
          assertBool ("expected C2 in " <> show rows) (("C2", Warn) `elem` rows)
    , testCase "掉电模型: 整个 journal 尾丢失（无任何记录）→ 盘面完好无发现(C3 语义)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "PWR2" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          _ <- execOk plan
          truncateJournalTo root []
          rows <- doctorRows root
          [r | r@(tag, sev) <- rows, sev >= Warn, tag /= "TORN"] @?= []
          c <- readFile (root </> "相册" </> "a.jpg")
          c @?= "PWR2"
    , testCase "C4: Done 声称的内容与盘面不符 → CORRUPT，不删任何东西" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          writeFile (root </> "相册" </> "a.jpg") "ACTUAL"
          now <- getCurrentTime
          let op = OpCopy (dir </> "ghost.jpg") ("相册" </> "a.jpg") "1111beef" 6 0
          withJournal root $ \j -> do
            jAppend j Barrier (JIntent "p#0" op now)
            jAppend j Barrier (JDone "p#0" (Just "1111beef") Nothing now)
          -- 无 CleanShutdown → Done 落在验证窗口内
          rows <- doctorRows root
          assertBool ("expected C4 in " <> show rows) (("C4", Bad) `elem` rows)
          c <- readFile (root </> "相册" </> "a.jpg")
          c @?= "ACTUAL"
    , testCase "C5: intent 无 done 且 dst 内容不符 → Bad（修复=隔离计划）" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          writeFile (root </> "相册" </> "a.jpg") "WRONG-CONTENT"
          now <- getCurrentTime
          let op = OpCopy (dir </> "ghost.jpg") ("相册" </> "a.jpg") "beef1234" 5 0
          withJournal root $ \j -> jAppend j Barrier (JIntent "p#0" op now)
          rows <- doctorRows root
          assertBool ("expected C5 in " <> show rows) (("C5", Bad) `elem` rows)
          c <- readFile (root </> "相册" </> "a.jpg")
          c @?= "WRONG-CONTENT" -- doctor 只读，未动 dst
    , testCase "R3: rename intent 无 done 且新旧都在 → 目标被占" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "old.txt") "O"
          writeFile (root </> "new.txt") "N"
          now <- getCurrentTime
          withJournal root $ \j ->
            jAppend j Barrier (JIntent "p#0" (OpRename "old.txt" "new.txt" (FpFileSha "aa")) now)
          rows <- doctorRows root
          assertBool ("expected R3 in " <> show rows) (("R3", Warn) `elem` rows)
    , testCase "torn tail: 末行半截 JSON → TORN warning" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          now <- getCurrentTime
          withJournal root $ \j -> jAppend j Barrier (JCleanShutdown now)
          appendFile (journalPath root) "{\"e\":\"intent\",\"op\":\"trunc"
          (_, warns) <- readJournal root
          assertBool ("expected torn warning, got " <> show warns) (any ((== "torn") . take 4) warns)
    ]

copyCrashCase :: Checkpoint -> [(String, Severity)] -> TestTree
copyCrashCase cp expected =
  testCase ("Copy 注入 " <> show cp <> " → " <> show expected) $
    withSystemTempDirectory "pm-test" $ \dir -> do
      let root = dir </> "root"
      createDirectoryIfMissing True root
      op <- mkCopyOp (dir </> "s.jpg") "CRASH-DATA" ("相册" </> "a.jpg")
      plan <- mkPlanIO root [op]
      runCrash (injectAt cp) plan
      -- 源文件永不被触碰
      src <- readFile (dir </> "s.jpg")
      src @?= "CRASH-DATA"
      rows <- doctorRows root
      let relevant = [r | r@(tag, _) <- rows, tag `elem` ["C1", "C2", "C5"]]
      relevant @?= expected

renameCrashCase :: Checkpoint -> [(String, Severity)] -> TestTree
renameCrashCase cp expected =
  testCase ("Rename 注入 " <> show cp <> " → " <> show expected) $
    withSystemTempDirectory "pm-test" $ \dir -> do
      let root = dir </> "root"
      createDirectoryIfMissing True root
      writeFile (root </> "old.txt") "R"
      sha <- sha256File (root </> "old.txt")
      plan <- mkPlanIO root [OpRename "old.txt" "new.txt" (FpFileSha sha)]
      runCrash (injectAt cp) plan
      rows <- doctorRows root
      let relevant = [r | r@(tag, _) <- rows, tag `elem` ["R1", "R2", "R3", "R?"]]
      relevant @?= expected

doctorTests :: TestTree
doctorTests =
  testGroup
    "doctor 杂项"
    [ testCase "Q1: trash 中无记录文件 → UNREGISTERED" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (trashDir root </> "stray")
          writeFile (trashDir root </> "stray" </> "x.jpg") "?"
          rows <- doctorRows root
          assertBool ("expected Q1 in " <> show rows) (("Q1", Warn) `elem` rows)
    , testCase "干净 root → 无发现, exit 0" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          (fs, code) <- runDoctor root (DoctorOpts False False)
          ([(fRow f, fSeverity f) | f <- fs, fSeverity f >= Warn], code) @?= ([], 0)
    ]

undoTests :: TestTree
undoTests =
  testGroup
    "undo (反向计划)"
    [ testCase "undo copy = 隔离副本；源与隔离内容完好" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          op <- mkCopyOp (dir </> "s.jpg") "UNDO-ME" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          _ <- execOk plan
          Right up <- buildUndoPlan root 1
          _ <- execOk up
          dstEx <- doesFileExist (root </> "相册" </> "a.jpg")
          dstEx @?= False
          tv <- trashView root
          case tvRegistered tv of
            [(r, present)] -> do
              present @?= True
              c <- readFile (trashDir root </> trTrashRel r)
              c @?= "UNDO-ME"
            other -> assertFailure ("expected 1 registered trash entry, got " <> show (length other))
    , testCase "undo rename = 改回原名" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          writeFile (root </> "old.txt") "N"
          sha <- sha256File (root </> "old.txt")
          plan <- mkPlanIO root [OpRename "old.txt" "new.txt" (FpFileSha sha)]
          _ <- execOk plan
          Right up <- buildUndoPlan root 1
          _ <- execOk up
          oldEx <- doesFileExist (root </> "old.txt")
          newEx <- doesFileExist (root </> "new.txt")
          (oldEx, newEx) @?= (True, False)
    , testCase "undo quarantine = 从 trash 原位复位" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          writeFile (root </> "相册" </> "v.jpg") "BACK"
          sha <- sha256File (root </> "相册" </> "v.jpg")
          plan <- mkPlanIO root [OpQuarantine ("相册" </> "v.jpg") sha "test"]
          _ <- execOk plan
          Right up <- buildUndoPlan root 1
          _ <- execOk up
          c <- readFile (root </> "相册" </> "v.jpg")
          c @?= "BACK"
    ]

lockTests :: TestTree
lockTests =
  testGroup
    "Pm.Lock (I10)"
    [ testCase "nested lock attempt is refused, released after scope" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          r <- withRootLock root $ withRootLock root (pure ("inner" :: String))
          r @?= Just Nothing
          r2 <- withRootLock root (pure ("again" :: String))
          r2 @?= Just "again"
    ]
