{-# LANGUAGE OverloadedStrings #-}

-- | P3b-9\/P3b-10：codex 六轮\/七轮复审的**路径类**收口用例（从 GuardTests 拆
-- 出，该文件触及 750 行预算）。一条主线：凡是能被手编的 @.pm@ 文件（plan \/
-- journal \/ manifest \/ catalog）里的路径字段，都必须先过词法谓词
-- 'relPathOk' \/ 'opPathsOk'，再在真正动盘处过 canonical 限域
-- 'Pm.Win.pathUnder'（junction\/大小写\/尾随点等别名只有操作系统答得准）。
module PathGuardTests (pathGuardTests) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectoryLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Commands (TrashCmd (..), runTrash)
import Pm.Config (Config (..), pmDir, writeRootInfo)
import Pm.Doctor (DoctorOpts (..), Severity (..), runDoctor)
import Pm.Exec
import Pm.Hash (sha256File)
import Pm.Journal (JEntry (..), Sync (..), jAppend, journalPath, withJournal)
import Pm.Op
import Pm.Plan
import Pm.Trash (TrashRecord (..), TrashView (..), appendManifest, trashDir, trashView)
import Pm.Types (RootInfo (..), RootRole (..))
import Pm.Undo (buildUndoPlan)
import Pm.Win (pathUnder)
import TestUtil

pathGuardTests :: TestTree
pathGuardTests =
  testGroup
    "P3b-9/10 路径校验与限域（codex 六轮/七轮）"
    [ testCase "P3b-9 relPathOk/opPathsOk：越界/盘符/ADS/.pm 内部 → validatePlan/execPlan/loadPlan 拒绝" caseOpPathValidation
    , testCase "P3b-9 doctor：合法 oid + 越界 Op/trash 路径 → OP-PATH Bad，不越出 root、--repair 不补" caseDoctorOpPathEscape
    , testCase "P3b-9 manifest trashRel 越界 → 记录剔除，trash empty 不 unlink root 外文件" caseManifestPathEscape
    , testCase "P3b-10 Win32 别名：.PM / .pm. / 尾随点空格分量 → 谓词与 execPlan 拒绝" caseWin32Aliases
    , testCase "P3b-10 trash 内 junction：不递归 + 删除/搬运前 canonical 限域 → 库外文件存活" caseTrashJunctionConfinement
    , testCase "P3b-10 手编 catalog 越界 enPath → 快照拒绝载入（backup/import 拿不到非法 src）" caseCatalogPathValidation
    , testCase "P3b-10 undo：journal 非法 Op/trashRel → 拒绝生成撤销计划" caseUndoRejectsBadPaths
    ]

mkCfg :: FilePath -> Maybe FilePath -> Config
mkCfg mainP vdir = Config mainP vdir Nothing Nothing Nothing Nothing

-- ─── P3b-9（六轮） ──────────────────────────────────────────────────────────

caseOpPathValidation :: IO ()
caseOpPathValidation = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- relPathOk 拒绝面（filepath 实测：isRelative "\\evil"/"c:evil" 都是 True，
  -- 而 root </> 它们是**整体替换**——旧 relOk 挡不住）
  relPathOk ("a" </> "b.jpg") @?= True
  relPathOk ("成片" </> "23-04-EU" </> "x.jpg") @?= True
  relPathOk (".." </> "x") @?= False
  relPathOk "a/../b" @?= False
  relPathOk "\\evil" @?= False
  relPathOk "/evil" @?= False
  relPathOk "c:evil" @?= False
  relPathOk "C:\\evil" @?= False
  relPathOk "a.jpg:ads" @?= False
  relPathOk "." @?= False
  relPathOk "" @?= False
  -- opPathsOk：.pm 内部拒绝；唯一例外是复位/undo rename 的 .pm/trash 源
  opPathsOk (OpRename (".pm" </> "trash" </> "p" </> "v.jpg") "v.jpg" (FpFileSha "aa")) @?= True
  opPathsOk (OpRename (".pm" </> "root-id.json") "stolen.bin" (FpFileSha "aa")) @?= False
  opPathsOk (OpQuarantine (".pm" </> "journal.ndjson") "aa" "t") @?= False
  -- validatePlan / execPlan（取锁前，零写入）/ loadPlan 三处拒绝
  let root = dir </> "root"
  createDirectoryIfMissing True root
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  forM_ [".." </> ".." </> "evil.jpg", "\\evil.jpg", "c:evil.jpg", "x.jpg:ads"] $ \bad -> do
    let p' = plan {plItems = [PlanItem 0 (OpQuarantine bad "aa" "t") StPending Nothing]}
    either (const (pure ())) (const (assertFailure ("validatePlan 应拒绝 " <> bad))) (validatePlan p')
    r <- execPlan defaultExecEnv p'
    case r of
      Left m -> assertBool m ("非法相对路径" `isInfixOf` m)
      Right _ -> assertFailure ("execPlan 应拒绝 " <> bad)
  jEx <- doesFileExist (journalPath root)
  jEx @?= False
  let badPlan = plan {plItems = [PlanItem 0 (OpQuarantine (".." </> ".." </> "evil.jpg") "aa" "t") StPending Nothing]}
  _ <- savePlan badPlan
  l <- loadPlan root (plId badPlan)
  either (\m -> assertBool m ("非法相对路径" `isInfixOf` m)) (const (assertFailure "loadPlan 应拒绝越界路径")) l

caseDoctorOpPathEscape :: IO ()
caseDoctorOpPathEscape = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- 合法 oid + 越界路径：旧代码在 root 外做存在性/sha 探测（root/.pm/trash 上
  -- 跳三级 = 临时根），内容相符即 Q-DONE-LOST → --repair 补 Done
  let root = dir </> "root"
      up3 = ".." </> ".." </> ".."
  createDirectoryIfMissing True root
  createDirectoryIfMissing True (dir </> "outside")
  writeFile (dir </> "outside" </> "v.jpg") "V"
  sha <- sha256File (dir </> "outside" </> "v.jpg")
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  withJournal root $ \j -> do
    -- ① pending Intent：victim 越界
    jAppend j Barrier (JIntent (tpOid 0) (OpQuarantine (up3 </> "outside" </> "v.jpg") sha "t") now)
    -- ② Done：Intent 的 victim 合法，但 Done 记录的 trash 路径越界
    jAppend j Barrier (JIntent (tpOid 1) (OpQuarantine "w.jpg" sha "t") now)
    jAppend j Barrier (JDone (tpOid 1) (Just sha) (Just (up3 </> "outside" </> "v.jpg")) now)
  rows <- doctorRows root
  length (filter (== ("OP-PATH", Bad)) rows) @?= 2
  assertBool
    ("越界路径不得进入矩阵推导: " <> show rows)
    (not (any ((`elem` ["Q-DONE-LOST", "C2", "C4", "C5"]) . fst) rows))
  _ <- runDoctor root (DoctorOpts False True)
  es <- journalEntries root
  length (filter isDone es) @?= 1 -- 仅剩手编的那条，--repair 未补任何 Done

caseManifestPathEscape :: IO ()
caseManifestPathEscape = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- 手编 manifest 的 trashRel 越界（.pm/trash 上跳三级 = 临时根）：
  -- pm trash empty 是全程序唯一 unlink 用户数据的位置，绝不能删 root 外文件
  let root = dir </> "root"
      cfg = mkCfg root Nothing
      escRel = ".." </> ".." </> ".." </> "victim.jpg"
  createDirectoryIfMissing True (trashDir root)
  writeFile (dir </> "victim.jpg") "PRECIOUS"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  appendManifest root (TrashRecord "v.jpg" escRel "aa" "test" tpid now)
  tv <- trashView root
  tvRegistered tv @?= []
  assertBool "越界记录应报为损坏行" (not (null (tvWarnings tv)))
  code <- runTrash cfg (TrashEmpty True) root
  code @?= 0 -- 无可清除条目（越界记录已剔除）
  doesFileExist (dir </> "victim.jpg") >>= (@?= True)
  readFile (dir </> "victim.jpg") >>= (@?= "PRECIOUS")

-- ─── P3b-10（七轮） ─────────────────────────────────────────────────────────

caseWin32Aliases :: IO ()
caseWin32Aliases = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- 实测（GHC 9.10 + Win11）：root </> ".PM" </> f 与 root </> ".pm." </> f 都能
  -- 打开 .pm 里的文件（大小写不敏感 + 尾随点被剥）；".pm " / ".. " 反而打不开。
  -- 谓词按更保守一侧取：大小写折叠 + 尾随点/空格剥除后再比对。
  opPathsOk (OpRename (".PM" </> "root-id.json") "stolen.bin" (FpFileSha "aa")) @?= False
  opPathsOk (OpRename (".pm." </> "root-id.json") "stolen.bin" (FpFileSha "aa")) @?= False
  opPathsOk (OpQuarantine (".Pm " </> "journal.ndjson") "aa" "t") @?= False
  relPathOk (".." </> "x") @?= False
  relPathOk (".. " </> "x") @?= False
  relPathOk ("..." </> "x") @?= False
  relPathOk (". " </> "x") @?= False
  relPathOk ("   " </> "x") @?= False
  -- 正常名不受影响（真实库 4855 条目实测零违规）
  relPathOk ("成片" </> "23-04-EU" </> "A7R06348-2.jpg") @?= True
  opPathsOk (OpQuarantine ("Raw" </> "2025" </> "25-08-PR-Raw" </> "a.arw") "aa" "t") @?= True
  -- 复位/undo 的 .pm/trash 源仍放行；大小写别名指向的是**同一个** .pm\trash
  -- 位置（NTFS 不分大小写），因此同样放行——真正的风险是 trash 内 junction 把
  -- 源解析到库外，那由 Exec 的 canonical 限域（caseTrashJunctionConfinement）拦
  opPathsOk (OpRename (".pm" </> "trash" </> "p" </> "v.jpg") "v.jpg" (FpFileSha "aa")) @?= True
  opPathsOk (OpRename (".PM" </> "trash" </> "p" </> "v.jpg") "v.jpg" (FpFileSha "aa")) @?= True
  -- 但 .pm 内非 trash 的位置一律拒绝（含别名拼法）
  opPathsOk (OpRename (".pm" </> "trashx" </> "v.jpg") "v.jpg" (FpFileSha "aa")) @?= False
  -- execPlan：取锁前拒绝，零写入
  let root = dir </> "root"
  createDirectoryIfMissing True root
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  let bad = plan {plItems = [PlanItem 0 (OpRename (".PM" </> "root-id.json") "stolen.bin" (FpFileSha "aa")) StPending Nothing]}
  either (const (pure ())) (const (assertFailure "validatePlan 应拒绝 .PM 别名")) (validatePlan bad)
  r <- execPlan defaultExecEnv bad
  case r of
    Left m -> assertBool m ("非法相对路径" `isInfixOf` m)
    Right _ -> assertFailure "execPlan 应拒绝 .PM 别名"
  doesFileExist (journalPath root) >>= (@?= False)

caseTrashJunctionConfinement :: IO ()
caseTrashJunctionConfinement = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- 实测：junction 下 doesDirectoryExist=True、listDirectory 穿透、removeFile
  -- 会真的删掉库外文件。三道屏障各测一遍：①listTrashFiles 不递归链接；
  -- ②唯一 unlink 之前 canonical 限域；③Exec 借 .pm/trash 例外搬运时同样限域。
  let root = dir </> "root"
      cfg = mkCfg root Nothing
      outside = dir </> "victimdir"
      link = trashDir root </> "link"
  createDirectoryIfMissing True (trashDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "v.jpg") "PRECIOUS"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  _ <- readCreateProcess (shell ("mklink /J \"" <> link <> "\" \"" <> outside <> "\"")) ""
  -- pathUnder 本身：库内为真、库外/自身为假
  writeFile (trashDir root </> "inside.jpg") "I"
  pathUnder (trashDir root) (trashDir root </> "inside.jpg") >>= (@?= True)
  pathUnder (trashDir root) (trashDir root) >>= (@?= False)
  pathUnder (trashDir root) (outside </> "v.jpg") >>= (@?= False)
  pathUnder (trashDir root) (link </> "v.jpg") >>= (@?= False) -- 解析后在库外
  -- ①手编记录指向链接内部：listTrashFiles 不递归 → 记录不被视为「在库」
  appendManifest root (TrashRecord "v.jpg" ("link" </> "v.jpg") "aa" "test" tpid now)
  tv <- trashView root
  assertBool "链接内容不得进入 trash 清单" (("link" </> "v.jpg") `notElem` tvUnregistered tv)
  assertBool
    "指向链接内部的记录不得被判为在库"
    (and [not present | (r, present) <- tvRegistered tv, trTrashRel r == ("link" </> "v.jpg")])
  -- ②手编记录直指链接本体：在库判定成立，靠 canonical 限域拦下
  appendManifest root (TrashRecord "v.jpg" "link" "aa" "test" tpid now)
  code <- runTrash cfg (TrashEmpty True) root
  code @?= 1 -- HELD
  doesFileExist (outside </> "v.jpg") >>= (@?= True)
  readFile (outside </> "v.jpg") >>= (@?= "PRECIOUS")
  doesDirectoryExist outside >>= (@?= True)
  -- ③七轮 #7：手编计划借 .pm/trash 例外，用 trash 内 junction 把库外文件
  -- rename 进库——词法上是正当的 undo 形态，由 Exec 的 canonical 限域拒绝
  vsha <- sha256File (outside </> "v.jpg")
  pid <- newPlanId
  let stealItem =
        PlanItem 0 (OpRename (".pm" </> "trash" </> "link" </> "v.jpg") "stolen.jpg" (FpFileSha vsha)) StPending Nothing
      steal = Plan pid "test" root (Just "m") now [stealItem]
  validatePlan steal @?= Right () -- 词法上是正当的 undo 形态
  r <- execPlan defaultExecEnv steal
  case r of
    Right [(_, OConflict m)] -> assertBool ("应因限域拒绝: " <> m) ("解析后不在" `isInfixOf` m)
    other -> assertFailure ("expected confinement OConflict, got " <> show other)
  doesFileExist (root </> "stolen.jpg") >>= (@?= False)
  doesFileExist (outside </> "v.jpg") >>= (@?= True)
  removeDirectoryLink link

caseCatalogPathValidation :: IO ()
caseCatalogPathValidation = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- 手编快照的 enPath 会被 Pm.Diff/Pm.Import 拼成 OpCopy 的绝对 src，并被
  -- doctor --deep / clean 见证直接读取 → 整份拒绝载入（快照可由 scan 重建）
  let good = dir </> "good"
  createDirectoryIfMissing True good
  saveCatalog good (mkCat [mkE ("成片" </> "ok.jpg") "aa"])
  (g, w0) <- loadCatalog good
  assertBool "正常快照应载入" (maybe False (const True) g)
  w0 @?= []
  -- 干净 root：saveCatalog 有三代轮转，同一 root 连写两次会让 loadCatalog
  -- 拒绝坏 base 后回退到上一代（那是设计内的容错，不是校验失效）
  let bad = dir </> "bad"
  createDirectoryIfMissing True bad
  saveCatalog bad (mkCat [mkE ("成片" </> "ok.jpg") "aa", mkE (".." </> ".." </> "evil.jpg") "bb"])
  (b, ws) <- loadCatalog bad
  b @?= Nothing
  assertBool ("应报路径非法: " <> show ws) (any ("条目路径非法" `isInfixOf`) ws)

caseUndoRejectsBadPaths :: IO ()
caseUndoRejectsBadPaths = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- savePlan 不校验（校验在 loadPlan/execPlan），所以撤销计划必须在生成时就拒绝
  let root = dir </> "root"
  createDirectoryIfMissing True root
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  withJournal root $ \j -> do
    jAppend j Barrier (JIntent (tpOid 0) (OpQuarantine "v.jpg" "aa" "t") now)
    jAppend j Barrier (JDone (tpOid 0) (Just "aa") (Just (".." </> ".." </> "outside.jpg")) now)
  r1 <- buildUndoPlan root 1
  either (\m -> assertBool m ("trash 路径非法" `isInfixOf` m)) (const (assertFailure "越界 trashRel 应拒绝")) r1
  doesDirectoryExist (pmDir root </> "plans") >>= (@?= False)
  -- Intent 侧非法路径同样拒绝
  let root2 = dir </> "root2"
  createDirectoryIfMissing True root2
  writeRootInfo root2 (RootInfo "m2" RoleMain now Nothing)
  withJournal root2 $ \j -> do
    jAppend j Barrier (JIntent (tpOid 0) (OpRename (".PM" </> "root-id.json") "stolen.bin" (FpFileSha "aa")) now)
    jAppend j Barrier (JDone (tpOid 0) Nothing Nothing now)
  r2 <- buildUndoPlan root2 1
  either (\m -> assertBool m ("路径非法" `isInfixOf` m)) (const (assertFailure "非法 Intent 应拒绝")) r2
