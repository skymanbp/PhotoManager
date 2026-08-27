{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | P0/P1 tests: hashing, catalog, the fail-if-exists move primitive, the
-- three Exec protocols, dual-mode fault injection against the doctor matrix
-- (DESIGN.md §6.4, §13), undo round-trips, and the instance lock.
module KernelTests (kernelTests) where

import Control.Exception (IOException, throwIO, try)
import Control.Monad (when)
import Data.IORef (atomicModifyIORef', newIORef)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameDirectory, setModificationTime)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog
import Pm.Config (writeRootInfo)
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
import Pm.Win (moveBoundNoReplace, openExclusiveBinary)
import System.IO (hClose)
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
          (loaded, warns) <- catalogMaybe <$> loadCatalog root
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
          (loaded, _) <- catalogMaybe <$> loadCatalog root
          fmap catRootId loaded @?= Just "g4"
    ]

moveTests :: TestTree
moveTests =
  testGroup
    "Pm.Win.moveBoundNoReplace (I5 cornerstone, P6-C 句柄形态)"
    [ testCase "refuses when destination exists" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          writeFile (dir </> "a.txt") "AAA"
          writeFile (dir </> "b.txt") "BBB"
          r <- try (moveBoundNoReplace (dir </> "a.txt") (dir </> "b.txt")) :: IO (Either IOException ())
          case r of
            Left _ -> pure ()
            Right () -> assertFailure "moveBoundNoReplace overwrote an existing destination"
          ca <- readFile (dir </> "a.txt")
          cb <- readFile (dir </> "b.txt")
          (ca, cb) @?= ("AAA", "BBB")
    , testCase "moves when destination absent" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          writeFile (dir </> "a.txt") "AAA"
          moveBoundNoReplace (dir </> "a.txt") (dir </> "c.txt")
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
    , testCase "三十四轮: dst 被独占占住 → OFailed（I5 判不出同异：不跳过、不覆盖、不逃逸），journal 零条目" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          hLock <- openExclusiveBinary (root </> "相册" </> "a.jpg")
          op <- mkCopyOp (dir </> "s.jpg") "MINE" ("相册" </> "a.jpg")
          plan <- mkPlanIO root [op]
          rs <- execOk plan
          hClose hLock
          case rs of
            [(_, OFailed m)] -> assertBool ("应指明目标读取失败: " <> m) ("目标读取失败" `elemSubstr` m)
            other -> assertFailure ("expected OFailed, got " <> show (map snd other))
          es <- journalEntries root
          filter isIntent es @?= [] -- 拒绝发生在 Intent 之前
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
    , testCase "三十四轮: 源被独占占住 → OFailed 指纹读取失败（≠ 指纹不符 CONFLICT），两侧不动" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True root
          hLock <- openExclusiveBinary (root </> "a.txt")
          plan <- mkPlanIO root [OpRename "a.txt" "b.txt" (FpFileSha "0000")]
          rs <- execOk plan
          hClose hLock
          case rs of
            [(_, OFailed m)] -> assertBool ("应指明指纹读取失败: " <> m) ("指纹读取失败" `elemSubstr` m)
            other -> assertFailure ("expected OFailed, got " <> show (map snd other))
          aEx <- doesFileExist (root </> "a.txt")
          bEx <- doesFileExist (root </> "b.txt")
          (aEx, bEx) @?= (True, False)
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
              tv <- trashViewOK root
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
    , testCase "三十四轮: victim 被独占占住 → OFailed 读取失败（内容核不了 → 不隔离、不逃逸），victim 原位" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          hLock <- openExclusiveBinary (root </> "相册" </> "v.jpg")
          plan <- mkPlanIO root [OpQuarantine ("相册" </> "v.jpg") "beef" "test"]
          rs <- execOk plan
          hClose hLock
          case rs of
            [(_, OFailed m)] -> assertBool ("应指明 victim 读取失败: " <> m) ("victim 读取失败" `elemSubstr` m)
            other -> assertFailure ("expected OFailed, got " <> show (map snd other))
          doesFileExist (root </> "相册" </> "v.jpg") >>= (@?= True)
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
            jAppend j Barrier (JIntent (tpOid 0) op now)
            jAppend j Barrier (JDone (tpOid 0) (Just "1111beef") Nothing now)
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
          withJournal root $ \j -> jAppend j Barrier (JIntent (tpOid 0) op now)
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
            jAppend j Barrier (JIntent (tpOid 0) (OpRename "old.txt" "new.txt" (FpFileSha "aa")) now)
          rows <- doctorRows root
          assertBool ("expected R3 in " <> show rows) (("R3", Warn) `elem` rows)
    , testCase "P3b-4 #1 / P3b-5: 复位目标被占 → 占位者隔离(~displaced-N) + victim 复位；重跑用新槽位；undo 不含内部事务" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
              victim = root </> "landscape" </> "d.jpg"
          createDirectoryIfMissing True (root </> "landscape")
          writeFile victim "OLDBYTES"
          oldSha <- sha256File victim
          op <- mkCopyOp (dir </> "s.jpg") "NEWBYTES" ("landscape" </> "d.jpg")
          plan <-
            mkGroupPlanIO
              root
              [ (OpQuarantine ("landscape" </> "d.jpg") oldSha "supersede:test", Just 0)
              , (op, Just 0)
              ]
          -- 竞态注入：Copy 落位 rename 前，第三方抢占目标路径。回滚必须
          -- 先隔离占位者（journaled，进 <pid>~displaced-N/）再复位 victim，
          -- 而不是被 I5 卡死留下 victim 在 trash（codex P3b-4 #1 反例）。
          let env =
                defaultExecEnv
                  { eeCheckpoint = \c -> when (c == CpCopyAfterFlush) $ writeFile victim "INTERLOPER"
                  }
              displaced n =
                trashDir root </> (T.unpack (plId plan) <> "~displaced-" <> show (n :: Int)) </> "landscape" </> "d.jpg"
          r1 <- execPlan env plan
          case r1 of
            Right [(_, OFailed m1), (_, OConflict m2)] -> do
              assertBool ("复位成功应入注记: " <> m2) ("旧目标已自动复位" `elemSubstr` m2)
              assertBool ("占位隔离应入注记: " <> m2) ("~displaced-1" `elemSubstr` m2)
              assertBool ("组未生效标注: " <> m1) ("组未生效" `elemSubstr` m1)
            other -> assertFailure ("round1: expected [OFailed, OConflict], got " <> show other)
          readFile victim >>= (@?= "OLDBYTES") -- victim 已复位到原位
          readFile (displaced 1) >>= (@?= "INTERLOPER") -- 占位者进独立隔离区，一个字节没丢
          -- P3b-5 复审 #1：同计划重跑再次被占 → 用槽位 2，不与上次残留撞车，
          -- victim 仍复位
          r2 <- execPlan env plan
          case r2 of
            Right [(_, OFailed _), (_, OConflict m2)] ->
              assertBool ("重跑应用槽位 2: " <> m2) ("~displaced-2" `elemSubstr` m2)
            other -> assertFailure ("round2: " <> show other)
          readFile victim >>= (@?= "OLDBYTES")
          readFile (displaced 2) >>= (@?= "INTERLOPER")
          -- doctor 对账无 Bad；undo 序列不含 ~d/~r 内部事务（两次 q 均被 ~r 抵消）
          rows <- doctorRows root
          [row | row@(_, sev) <- rows, sev == Bad] @?= []
          ur <- buildUndoPlan root 1
          case ur of
            Left msg -> assertBool msg ("没有可撤销" `elemSubstr` msg)
            Right p -> assertFailure ("expected no undoable ops, got " <> show (map piOp (plItems p)))
    , testCase "P3b-5 #3 内核自卫: RoleVault root 缺 .pm/ ignore → execPlan defaultExecEnv 亦拒绝（I11 不可绕过）" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "vault"
          createDirectoryIfMissing True (root </> ".git")
          writeFile (root </> ".gitignore") "_site/\n"
          now <- getCurrentTime
          writeRootInfo root (RootInfo "vault-rid" RoleVault now Nothing)
          op <- mkCopyOp (dir </> "s.jpg") "X" ("landscape" </> "x.jpg")
          plan0 <- mkPlanIO root [op]
          r <- execPlan defaultExecEnv plan0 {plRootId = Just "vault-rid"}
          case r of
            Left msg -> assertBool msg ("I11" `elemSubstr` msg)
            Right _ -> assertFailure "kernel must refuse a vault root whose .pm/ is not ignored"
          jEx <- doesFileExist (journalPath root)
          jEx @?= False -- journal 未创建：拒绝发生在任何写入之前
    , testCase "P3b-5 B2 dirFingerprint 递归：子目录内文件变化改变指纹；目录自身改名不变" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let d = dir </> "ev"
          createDirectoryIfMissing True (d </> "sub")
          writeFile (d </> "a.arw") "AAAA"
          writeFile (d </> "sub" </> "b.xmp") "BBBB"
          setModificationTime (d </> "sub" </> "b.xmp") t0
          fp1 <- dirFingerprint d
          -- 深层文件同名同大小、内容与 mtime 变化 → 旧指纹（只看直接子项）不变，新指纹必变
          writeFile (d </> "sub" </> "b.xmp") "CCCC"
          fp2 <- dirFingerprint d
          assertBool "递归指纹应随子目录文件变化" (fp1 /= fp2)
          renameDirectory d (dir </> "ev2")
          fp3 <- dirFingerprint (dir </> "ev2")
          fp3 @?= fp2 -- undo 前提：改名不改指纹
    , testCase "P3b-5 #1 doctor: Q-DONE-LOST 补记前核 sha——trash 内容不符 → Bad 且 --repair 不盲补" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (trashDir root </> T.unpack tpid)
          writeFile (trashDir root </> T.unpack tpid </> "v.jpg") "WRONG"
          now <- getCurrentTime
          withJournal root $ \j -> jAppend j Barrier (JIntent (tpOid 0) (OpQuarantine "v.jpg" "beefbeef" "t") now)
          rows <- doctorRows root
          assertBool ("expected Bad Q-DONE-LOST in " <> show rows) (("Q-DONE-LOST", Bad) `elem` rows)
          _ <- runDoctor root (DoctorOpts False True)
          es <- journalEntries root
          filter isDone es @?= []
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
    , testCase "三十四轮: --deep 遇独占占住的条目 → DEEP 读取失败 Warn，doctor 不崩" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "相册")
          hLock <- openExclusiveBinary (root </> "相册" </> "locked.jpg")
          saveCatalog root (mkCat [mkE ("相册" </> "locked.jpg") "aa"])
          (fs, code) <- runDoctor root (DoctorOpts True False)
          hClose hLock
          let deepRows = [f | f <- fs, fRow f == "DEEP"]
          case deepRows of
            [f] -> assertBool ("应指明读取失败: " <> fDetail f) ("读取失败" `elemSubstr` fDetail f)
            other -> assertFailure ("expected 1 DEEP finding, got " <> show (map fDetail other))
          code @?= 1 -- 状态未知 → 非零退出
    , testCase "P2.3: 二次复位在 rename 后崩溃 → 次序感知 R2 补记，repair 后收敛" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let root = dir </> "root"
          createDirectoryIfMissing True (root </> "成片")
          writeFile (root </> "成片" </> "a.jpg") "OLD"
          oldSha <- sha256File (root </> "成片" </> "a.jpg")
          op <- mkCopyOp (dir </> "s.jpg") "NEW!" ("成片" </> "a.jpg")
          writeFile (dir </> "s.jpg") "NEW!X" -- 源前提破坏 → Copy 每轮都冲突
          plan <-
            mkGroupPlanIO
              root
              [ (OpQuarantine ("成片" </> "a.jpg") oldSha "supersede:test", Just 0)
              , (op, Just 0)
              ]
          -- 计数 CpRenAfterMove：第 1 次（第一轮复位）放行，第 2 次（第二轮
          -- 复位 rename 已落盘、Done 未写）注入崩溃 = codex 三轮反例
          ref <- newIORef (0 :: Int)
          let env =
                defaultExecEnv
                  { eeCheckpoint = \c -> when (c == CpRenAfterMove) $ do
                      n <- atomicModifyIORef' ref (\k -> (k + 1, k + 1))
                      when (n == 2) (throwIO (userError "inject-crash"))
                  }
          r1 <- execPlan env plan
          case r1 of
            Right [(_, OFailed _), (_, OConflict _)] -> pure ()
            other -> assertFailure ("round1: " <> show other)
          runCrash env plan -- 第二轮：幂等隔离→冲突→复位 rename 后崩溃
          back <- readFile (root </> "成片" </> "a.jpg")
          back @?= "OLD" -- victim 已在原位（复位生效，仅 Done 缺失）
          rows <- doctorRows root
          -- 旧全局差集会让第一轮的 ~r Done 吞掉第二轮悬挂的 ~r Intent；
          -- 次序感知必须报 R2（可补记），此刻 C4 报告但不动盘
          assertBool ("expected R2 in " <> show rows) (any (\(t, _) -> t == "R2") rows)
          assertBool ("expected C4 in " <> show rows) (("C4", Bad) `elem` rows)
          _ <- runDoctor root (DoctorOpts False True) -- --repair 补记 ~r Done
          rows2 <- doctorRows root
          [r | r@(_, sev) <- rows2, sev == Bad] @?= []
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
          tv <- trashViewOK root
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
