{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (IOException, SomeException, throwIO, try)
import Control.Monad (forM_, when)
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (chooseInt, elements, forAll, listOf1, testProperty, (.&&.), (===))

import Pm.Catalog
import Pm.Clean
import Pm.Diff
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), runDoctor)
import Pm.Exec
import Pm.Hash
import Pm.Import
import Pm.Journal
import Pm.Lock (withRootLock)
import Pm.Names
import Pm.Op
import Pm.Plan
import Pm.Scan (ScanOpts (..), ScanResult (..), scanRoot)
import Pm.Trash
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Win (moveFileNoReplace, setupConsole)

main :: IO ()
main = do
  setupConsole
  defaultMain tests

tests :: TestTree
tests =
  testGroup
    "pm"
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
    , namesTests
    , importTests
    , diffTests
    , backupE2eTests
    , cleanTests
    ]

-- ─── P0 基础 ────────────────────────────────────────────────────────────────

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

-- ─── 测试脚手架 ─────────────────────────────────────────────────────────────

-- | 造一个 src 文件并生成对应的 Copy op（含真实前置条件）。
mkCopyOp :: FilePath -> String -> FilePath -> IO Op
mkCopyOp srcAbs content dstRel = do
  createDirectoryIfMissing True (takeDirectory srcAbs)
  writeFile srcAbs content
  sha <- sha256File srcAbs
  s <- statSnap srcAbs
  pure (OpCopy srcAbs dstRel sha (ssSize s) (ssMtimeNs s))

mkPlanIO :: FilePath -> [Op] -> IO Plan
mkPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plCreated = now
      , plItems = [PlanItem i op StPending | (i, op) <- zip [0 ..] ops]
      }

injectAt :: Checkpoint -> ExecEnv
injectAt cp =
  defaultExecEnv {eeCheckpoint = \c -> when (c == cp) (throwIO (userError "inject-crash"))}

-- | 注入崩溃：期望异常逃逸（= 进程死亡模型）。
runCrash :: ExecEnv -> Plan -> IO ()
runCrash env plan = do
  r <- try (execPlan env plan) :: IO (Either SomeException (Either String [(PlanItem, ItemOutcome)]))
  case r of
    Left _ -> pure ()
    Right _ -> assertFailure "expected injected crash to escape execPlan"

execOk :: Plan -> IO [(PlanItem, ItemOutcome)]
execOk plan = do
  r <- execPlan defaultExecEnv plan
  case r of
    Left e -> assertFailure ("lock busy unexpectedly: " <> e) >> pure []
    Right rs -> pure rs

doctorRows :: FilePath -> IO [(String, Severity)]
doctorRows root = do
  (fs, _) <- runDoctor root (DoctorOpts False False)
  pure [(fRow f, fSeverity f) | f <- fs]

journalEntries :: FilePath -> IO [JEntry]
journalEntries root = fst <$> readJournal root

isIntent, isDone, isClean :: JEntry -> Bool
isIntent JIntent {} = True; isIntent _ = False
isDone JDone {} = True; isDone _ = False
isClean JCleanShutdown {} = True; isClean _ = False

-- ─── Exec: Copy 协议 ────────────────────────────────────────────────────────

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

-- ─── Exec: Rename / Quarantine ──────────────────────────────────────────────

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

-- ─── 双模故障注入 × doctor 矩阵 ─────────────────────────────────────────────

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

-- 掉电模拟：把 journal 重写为给定条目（= 尾部未 fsync 丢失）。
truncateJournalTo :: FilePath -> [JEntry] -> IO ()
truncateJournalTo root es = do
  removeJournal
  withJournal root $ \j -> forM_ es (jAppend j Buffered)
 where
  removeJournal = do
    ex <- doesFileExist (journalPath root)
    when ex (writeFile (journalPath root) "")

-- ─── doctor 补充行 ──────────────────────────────────────────────────────────

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

-- ─── undo ───────────────────────────────────────────────────────────────────

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

-- ─── lock ───────────────────────────────────────────────────────────────────

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

-- ─── P2: Names ──────────────────────────────────────────────────────────────

pad2 :: Int -> String
pad2 n = if n < 10 then '0' : show n else show n

namesTests :: TestTree
namesTests =
  testGroup
    "Pm.Names (§8 子集)"
    [ testCase "parseYYMM 正常" (parseYYMM "26-04-Providence" @?= Just (26, 4, "Providence"))
    , testCase "月份 13 拒绝" (parseYYMM "26-13-X" @?= Nothing)
    , testCase "无地点拒绝" (parseYYMM "26-04-" @?= Nothing)
    , testCase "无连字符拒绝" (parseYYMM "2604-X" @?= Nothing)
    , testCase "canonRawEvent 补 -Raw + 推导年份" $
        canonRawEvent "26-04-Providence" @?= Just ("2026", "26-04-Providence-Raw")
    , testCase "canonRawEvent 幂等（已带 -Raw）" $
        canonRawEvent "23-01-Cotswold-Raw" @?= Just ("2023", "23-01-Cotswold-Raw")
    , testCase "Scheme B 不猜（P3 的 pm names 处理）" $
        canonRawEvent "RAW-2025-Winter-Alaska" @?= Nothing
    , testCase "canonProcessedEvent 恒等" $
        canonProcessedEvent "26-04-Providence" @?= Just "26-04-Providence"
    , testCase "canonProcessedEvent 剥离误带的 -Raw" $
        canonProcessedEvent "23-04-EU-Raw" @?= Just "23-04-EU"
    , testCase "canonProcessedEvent 非事件名拒绝" (canonProcessedEvent "molly" @?= Nothing)
    , testProperty "parse/canon roundtrip + 幂等（QuickCheck）" $
        forAll ((,,) <$> chooseInt (0, 99) <*> chooseInt (1, 12) <*> listOf1 (elements ['a' .. 'z'])) $
          \(yy, mm, loc) ->
            let name = pad2 yy <> "-" <> pad2 mm <> "-" <> loc
                canon = name <> "-Raw"
                yr = "20" <> pad2 yy
             in (parseYYMM name === Just (yy, mm, loc))
                  .&&. (canonRawEvent name === Just (yr, canon))
                  .&&. (canonRawEvent canon === Just (yr, canon))
    ]

-- ─── P2: Import 计划器（纯） ────────────────────────────────────────────────

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

mkE :: FilePath -> String -> Entry
mkE p sha = Entry p 1 0 (T.pack sha) KindPhoto Nothing

mkCat :: [Entry] -> Catalog
mkCat es = Catalog "test-root" t0 (entryMap es)

importTests :: TestTree
importTests =
  testGroup
    "Pm.Import (§7 计划器纯函数)"
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
    , testCase "目标已存在不同 sha → 返修 NEEDS-DECISION" $ do
        let src = mkE ("To-Be-Sync'd" </> "Processed" </> "23-04-EU" </> "x.jpg") "new"
            dst = mkE ("成片" </> "23-04-EU" </> "x.jpg") "old"
            rep = planImport (mkCat [src, dst])
        irRework rep @?= [(src, enPath dst)]
        let items = importPlanItems "R:" rep
        case items of
          [PlanItem 0 OpCopy {} (StNeedsDecision _)] -> pure ()
          other -> assertFailure ("expected 1 needs-decision copy, got " <> show other)
    , testCase "待修改 不碰；顶层散文件 unrecognized" $ do
        let p = mkE ("To-Be-Sync'd" </> "待修改" </> "DSC08960.ARW") "s1"
            junk = mkE ("To-Be-Sync'd" </> "notes.txt") "s2"
            rep = planImport (mkCat [p, junk])
        (irPendingEdit rep, irUnrecognized rep, irCopy rep)
          @?= ([enPath p], [enPath junk], [])
    , testCase "两个源撞同一目标 → 整组拒绝 (dupTarget)" $ do
        let a = mkE ("To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "D.ARW") "s1"
            b = mkE ("To-Be-Sync'd" </> "Raw" </> "2026" </> "26-06-R66" </> "D.ARW") "s2"
            rep = planImport (mkCat [a, b])
        (irCopy rep, length (irDupTarget rep)) @?= ([], 2)
    , testCase "importPlanItems: src 绝对化 + 前置条件来自 catalog" $ do
        let e = (mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "c.jpg") "abc") {enSize = 7, enMtimeNs = 99}
            rep = planImport (mkCat [e])
        case importPlanItems ("R:" </> "lib") rep of
          [PlanItem 0 (OpCopy src dst sha sz mt) StPending] -> do
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

-- ─── P2: 备份 diff（纯）+ 端到端 fixture ────────────────────────────────────

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
    , testCase "update → supersede 复合：隔离在前、Copy 在后、同一相对路径" $ do
        let m = mkE ("成片" </> "c.jpg") "C-new"
            b = mkE ("成片" </> "c.jpg") "C-old"
            d = backupDiff (mkCat [m]) (mkCat [b])
        case backupPlanItems "M:" d of
          [PlanItem 0 (OpQuarantine v vs _) StPending, PlanItem 1 (OpCopy src dst sha _ _) StPending] -> do
            (v, vs) @?= (enPath b, "C-old")
            (src, dst, sha) @?= ("M:" </> enPath m, enPath m, "C-new")
          other -> assertFailure ("unexpected items: " <> show other)
    ]

scanQuiet :: String -> FilePath -> IO Catalog
scanQuiet rid root = srCatalog <$> scanRoot (ScanOpts 1 False) Nothing (T.pack rid) root

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
          pid <- newPlanId
          now <- getCurrentTime
          let plan = Plan pid "backup" broot now (backupPlanItems mroot d0)
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
          pid <- newPlanId
          now <- getCurrentTime
          let plan = Plan pid "backup" broot now (backupPlanItems mroot d)
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

-- ─── P2: clean staging ──────────────────────────────────────────────────────

cleanTests :: TestTree
cleanTests =
  testGroup
    "Pm.Clean (三副本前置)"
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
    , testCase "待修改 从不清理" $ do
        let s = mkE ("To-Be-Sync'd" </> "待修改" </> "y.ARW") "X"
            a = mkE ("Raw" </> "2023" </> "y.ARW") "X"
            rep = planClean (mkCat [s, a]) (mkCat [a])
        (clEligible rep, clHeld rep, clPendingEdit rep) @?= ([], [], [enPath s])
    , testCase "verifyCandidates: 备份见证盘面已变 → 降级 HELD" $
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
          -- 正例：三副本活体核对通过
          (ok1, held1) <- verifyCandidates mroot broot (clEligible rep)
          (length ok1, held1) @?= (1, [])
          -- 反例：备份副本在 catalog 之后被改 → 降级
          writeFile (broot </> "成片" </> "26-06-R66" </> "c.jpg") "TAMPERED"
          (ok2, held2) <- verifyCandidates mroot broot (clEligible rep)
          length ok2 @?= 0
          case held2 of
            [(_, why)] -> assertBool why ("备份副本盘面已变" `elemSubstr` why)
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
          pid <- newPlanId
          now <- getCurrentTime
          let plan = Plan pid "clean-staging" mroot now (cleanPlanItems (clEligible rep))
          rs <- execOk plan
          map (outcomeLabel . snd) rs @?= ["DONE"]
          stEx <- doesFileExist (mroot </> srel)
          stEx @?= False
          c <- readFile (trashDir mroot </> T.unpack pid </> srel)
          c @?= "X9"
          -- 归档副本原封不动
          keep <- readFile (mroot </> "成片" </> "26-06-R66" </> "c.jpg")
          keep @?= "X9"
    ]

elemSubstr :: String -> String -> Bool
elemSubstr needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]
