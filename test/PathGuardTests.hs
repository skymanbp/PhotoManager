{-# LANGUAGE OverloadedStrings #-}

-- | P3b-9\/P3b-10\/P3b-11：codex 六\/七\/八轮复审的**路径类**收口用例（从
-- GuardTests 拆出，该文件触及 750 行预算）。三层，一层比一层更不信任自己：
--
--  * 词法（'relPathOk' \/ 'userRelOk' \/ 'opPathsOk'）：手编的 @.pm@ 文件
--    （plan \/ journal \/ manifest \/ catalog）里的路径字段先过纯谓词。
--  * 解析（'Pm.Win.resolveUnder'）：别名只有操作系统答得准，而且**基准自身**
--    也可能是 junction——逐级下降要求路上每一段都是盘上的真名。
--  * 独占创建（'Pm.Win.openExclusiveBinary'）：hardlink 既不是 reparse point
--    也不改变 canonical 路径，前两层都看不见它。
module PathGuardTests (pathGuardTests) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeDirectory, removeDirectoryLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.IO (hClose)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (catalogPath, loadCatalog, saveCatalog)
import Pm.Commands (TrashCmd (..), initPreflight, runTrash)
import Pm.Config (Config (..), RootIdState (..), createRootInfo, pmDir, readRootState, requirePmTrusted, writeRootInfo, writeSideCache)
import Pm.Doctor (DoctorOpts (..), Severity (..), runDoctor)
import Pm.Exec
import Pm.Hash (sha256File)
import Pm.Journal (JEntry (..), Sync (..), jAppend, journalPath, readJournal, withJournal)
import Pm.Op
import Pm.Plan
import Pm.Trash (TrashRecord (..), TrashView (..), appendManifest, manifestPath, readManifest, trashDir, trashView)
import Pm.Types (Catalog (..), Entry (..), RootInfo (..), RootRole (..))
import Pm.Undo (buildUndoPlan)
import Pm.Win (openExclusiveBinary, pathAtOrUnder, pathUnder, resolveUnder)
import TestUtil

pathGuardTests :: TestTree
pathGuardTests =
  testGroup
    "P3b-9~13 路径校验、限域、独占创建、hardlink 防护与可信闸（codex 六~十轮）"
    [ testCase "P3b-9 relPathOk/opPathsOk：越界/盘符/ADS/.pm 内部 → validatePlan/execPlan/loadPlan 拒绝" caseOpPathValidation
    , testCase "P3b-9 doctor：合法 oid + 越界 Op/trash 路径 → OP-PATH Bad，不越出 root、--repair 不补" caseDoctorOpPathEscape
    , testCase "P3b-9 manifest trashRel 越界 → 记录剔除，trash empty 不 unlink root 外文件" caseManifestPathEscape
    , testCase "P3b-10 Win32 别名：.PM / .pm. / 尾随点空格分量 → 谓词与 execPlan 拒绝" caseWin32Aliases
    , testCase "P3b-10 trash 内 junction：不递归 + 删除/搬运前 canonical 限域 → 库外文件存活" caseTrashJunctionConfinement
    , testCase "P3b-10 手编 catalog 越界 enPath → 快照拒绝载入（backup/import 拿不到非法 src）" caseCatalogPathValidation
    , testCase "P3b-10 undo：journal 非法 Op/trashRel → 拒绝生成撤销计划" caseUndoRejectsBadPaths
    , testCase "P3b-11 .pm/trash 自身是 junction（基准被劫持）→ 遍历列空、trash empty HELD、execPlan 拒绝" caseTrashBaseJunction
    , testCase "P3b-11 root/alias → .pm 的目录别名 → 逐级下降拒绝，root-id.json 搬不走" casePmAliasDir
    , testCase "P3b-11 预置 hardlink 占用确定性 tmp 名 → 独占创建拒绝，库外内容不被覆盖" caseTmpHardlinkClobber
    , testCase "P3b-11 .pm/tmp/<plan> 是 junction → doctor --repair 不删库外文件" caseDoctorTmpJunction
    , testCase "P3b-11 catalog：半写 JSON 回退 .1，语义非法则整条链拒绝（不换一代继续干活）" caseCatalogGenerationSemantics
    , testCase "P3b-11 undo 一次复位历史 → 反向 Op 以 .pm/trash 为目标，生成时即拒" caseUndoReverseResultValidated
    , testCase "P3b-12 .pm/tmp/<planId> 动态层是 junction → Exec 拒绝落位，库外同名文件存活" caseExecDynamicTmpJunction
    , testCase "P3b-12 .pm 是 junction → 建身份的三条旁路（init/backup init/vault push）一律拒绝" caseInitBypassUntrusted
    , testCase "P3b-12 journal/manifest/plan 被 hardlink 占名 → 拒绝写入，库外对象字节不变" caseStateFileHardlink
    , testCase "P3b-12 pathAtOrUnder 三态：解析不出时不得被当成「不在 .pm 里」放行" casePathAtOrUnderTristate
    , testCase "P3b-12 undo：root 身份不可用 → 拒绝生成，不留计划文件" caseUndoRequiresIdentity
    , testCase "P3b-13 .pm/vault-cache 是 junction → 枚举式可信闸抓到，侧缓存一个字节都不写" caseSideCacheJunction
    , testCase "P3b-13 闸下沉到 loader：loadCatalog/readJournal/readManifest/loadPlan 全部拒绝不可信 root" caseLoaderLevelGate
    , testCase "P3b-13 两次限域之间注入 junction → 第二次检查拦下（钉住建目录后的复检）" caseExecTmpSecondCheck
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
  -- 单代 root（无 .1）：坏 base 直接判非法
  let bad = dir </> "bad"
  createDirectoryIfMissing True bad
  saveCatalog bad (mkCat [mkE ("成片" </> "ok.jpg") "aa", mkE (".." </> ".." </> "evil.jpg") "bb"])
  (b, ws) <- loadCatalog bad
  b @?= Nothing
  assertBool ("应报路径非法: " <> show ws) (any ("条目路径非法" `isInfixOf`) ws)
  -- P3b-11：enPath 校验从 relPathOk 收紧到 userRelOk——".pm\journal.ndjson"
  -- 是完全合法的相对路径，却让 opSrcAbs 指向 pm 自己的状态文件
  let inpm = dir </> "inpm"
  createDirectoryIfMissing True inpm
  saveCatalog inpm (mkCat [mkE (".pm" </> "journal.ndjson") "cc"])
  (p, wp) <- loadCatalog inpm
  p @?= Nothing
  assertBool ("指向 .pm 的条目应拒绝: " <> show wp) (any ("条目路径非法" `isInfixOf`) wp)

-- | P3b-11（八轮复审 #4）：三代轮转对**两类**失败必须给不同答案。
-- 旧用例的注释声称测了 @.1@ 回退，实际只写过一代——codex 八轮点出，这里补真。
caseCatalogGenerationSemantics :: IO ()
caseCatalogGenerationSemantics = withSystemTempDirectory "pm-guard" $ \dir -> do
  -- ① 半写/损坏 JSON：可回退，这正是三代轮转要救的场景
  let torn = dir </> "torn"
  createDirectoryIfMissing True torn
  saveCatalog torn (mkCat [mkE ("成片" </> "gen1.jpg") "aa"])
  saveCatalog torn (mkCat [mkE ("成片" </> "gen2.jpg") "bb"])
  doesFileExist (catalogPath torn <> ".1") >>= (@?= True) -- 确有上一代可退
  writeFile (catalogPath torn) "{ this is not json"
  (t, tw) <- loadCatalog torn
  case t of
    Nothing -> assertFailure ("半写 base 应回退到 .1: " <> show tw)
    Just c -> assertBool "回退到的应是上一代内容" (any (("gen1.jpg" `isInfixOf`) . enPath) (Map.elems (catEntries c)))
  -- ② 语义非法：不是介质事故，是有人手编过——整条链就地终止，不换一代继续干活
  --（backup 忽略 load warnings 拿 .1 算 diff，会漏备 base 才有的新文件）
  let tam = dir </> "tampered"
  createDirectoryIfMissing True tam
  saveCatalog tam (mkCat [mkE ("成片" </> "gen1.jpg") "aa"])
  saveCatalog tam (mkCat [mkE (".." </> ".." </> "evil.jpg") "bb"])
  doesFileExist (catalogPath tam <> ".1") >>= (@?= True) -- 合法的上一代就在那里
  (m, mw) <- loadCatalog tam
  m @?= Nothing -- 但绝不回退过去
  assertBool ("应报路径非法: " <> show mw) (any ("条目路径非法" `isInfixOf`) mw)

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

-- ─── P3b-11（八轮） ─────────────────────────────────────────────────────────

mkJunction :: FilePath -> FilePath -> IO ()
mkJunction link target =
  () <$ readCreateProcess (shell ("mklink /J \"" <> link <> "\" \"" <> target <> "\"")) ""

-- | 八轮 critical：七轮的限域判定问的是"目标解析后在哪"，默认**基准可信**。
-- 探针实证 @.pm\/trash@ 自身是 junction 时两侧都解析到库外、判定通过，
-- @removeFile@ 删掉了库外文件。修复是逐级下降（每一段都必须是真名）。
caseTrashBaseJunction :: IO ()
caseTrashBaseJunction = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      cfg = mkCfg root Nothing
      outside = dir </> "outside-trash"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "v.jpg") "PRECIOUS"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  mkJunction (trashDir root) outside
  -- 旧判定（canonical 包含）在这里是 True——被劫持的基准与目标一起解析到库外
  pathUnder (trashDir root) (trashDir root </> "v.jpg") >>= (@?= True)
  -- 新判定：从 root 起逐级下降，.pm/trash 这一级即拒
  resolveUnder root (".pm" </> "trash" </> "v.jpg") >>= (@?= Nothing)
  -- ① .pm 家族可信性闸：所有 .pm 写入口的共同前提
  requirePmTrusted root >>= either (\m -> assertBool m ("不是 root 下的真实目录" `isInfixOf` m)) (const (assertFailure "requirePmTrusted 应拒绝 junction 基准"))
  -- ② 遍历侧：库外内容不得被列成"隔离文件"
  tv <- trashView root
  tvUnregistered tv @?= []
  -- ③ 唯一 unlink：被劫持基准 → HELD，库外文件存活。
  -- P3b-14：appendManifest 自身现在就拒绝（完整路径 resolveUnder 在 trash
  -- 这一级看到 junction）——旧用例把"穿过 junction 写出 manifest"当 setup
  -- 容忍，现改为断言拒绝；manifest 由测试直接放进库外目录（攻击者本来就能
  -- 这么放），钉 runTrash 面对既有记录仍 HELD。
  ra <- try (appendManifest root (TrashRecord "v.jpg" "v.jpg" "aa" "test" tpid now)) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "appendManifest 应拒绝被劫持的 .pm/trash")) ra
  writeFile
    (outside </> "manifest.ndjson")
    "{\"victim\":\"v.jpg\",\"trash\":\"v.jpg\",\"sha256\":\"aa\",\"reason\":\"test\",\"plan\":\"20260101-000000-aaaaaa\",\"at\":\"2026-01-01T00:00:00Z\"}\n"
  code <- runTrash cfg (TrashEmpty True) root
  code @?= 1
  doesFileExist (outside </> "v.jpg") >>= (@?= True)
  readFile (outside </> "v.jpg") >>= (@?= "PRECIOUS")
  -- ④ Exec：隔离落位会把 victim 搬出库 → 整批在取锁前拒绝
  writeFile (root </> "keep.jpg") "K"
  ksha <- sha256File (root </> "keep.jpg")
  pid <- newPlanId
  let quar = Plan pid "test" root (Just "m") now [PlanItem 0 (OpQuarantine "keep.jpg" ksha "t") StPending Nothing]
  r <- execPlan defaultExecEnv quar
  either (\m -> assertBool m ("不是 root 下的真实目录" `isInfixOf` m)) (const (assertFailure "execPlan 应拒绝被劫持的 .pm/trash")) r
  doesFileExist (root </> "keep.jpg") >>= (@?= True)
  removeDirectoryLink (trashDir root)

-- | 八轮 major：@root\/alias@ junction 到 @root\/.pm@。词法上 alias 不是
-- @.pm@，canonical 后仍在 root 之内——旧的 root 级包含判定放行，可搬走
-- root-id.json。逐级下降在 alias 那一级就拒（它是 reparse point）。
casePmAliasDir :: IO ()
casePmAliasDir = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True (pmDir root)
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  mkJunction (root </> "alias") (pmDir root)
  -- 词法谓词放行（alias 不是 .pm），旧的 root 级 canonical 包含也放行
  opPathsOk (OpRename ("alias" </> "root-id.json") "stolen.json" (FpFileSha "aa")) @?= True
  pathUnder root (root </> "alias" </> "root-id.json") >>= (@?= True)
  -- 逐级下降拒绝
  resolveUnder root ("alias" </> "root-id.json") >>= (@?= Nothing)
  idSha <- sha256File (root </> ".pm" </> "root-id.json")
  pid <- newPlanId
  let steal =
        Plan pid "test" root (Just "m") now
          [PlanItem 0 (OpRename ("alias" </> "root-id.json") "stolen.json" (FpFileSha idSha)) StPending Nothing]
  validatePlan steal @?= Right () -- 词法上合法
  r <- execPlan defaultExecEnv steal
  case r of
    Right [(_, OConflict m)] -> assertBool ("应因限域拒绝: " <> m) ("逐级解析后不在" `isInfixOf` m)
    other -> assertFailure ("expected confinement OConflict, got " <> show other)
  doesFileExist (root </> "stolen.json") >>= (@?= False)
  doesFileExist (root </> ".pm" </> "root-id.json") >>= (@?= True)
  removeDirectoryLink (root </> "alias")

-- | 八轮 major：tmp 名是确定性的（doctor 要能算出来），旧代码用 WriteMode
-- 截断打开——探针实证预置成库外文件的 hardlink 后，pm 一写就覆盖了库外内容。
-- hardlink 不是 reparse point，逐级下降与 canonical 都看不见它，只有
-- CREATE_NEW 独占创建能拒。
caseTmpHardlinkClobber :: IO ()
caseTmpHardlinkClobber = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      shared = dir </> "shared-outside.dat"
  createDirectoryIfMissing True (pmDir root)
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeFile shared "ORIGINAL-OUTSIDE-CONTENT"
  op <- mkCopyOp (dir </> "s.jpg") "SOURCE-BYTES" ("相册" </> "x.jpg")
  pid <- newPlanId
  let plan = Plan pid "test" root (Just "m") now [PlanItem 0 op StPending Nothing]
      tdir = tmpDirFor root pid
      tmp = tdir </> tmpNameFor 0 ("相册" </> "x.jpg")
  createDirectoryIfMissing True tdir
  _ <- readCreateProcess (shell ("mklink /H \"" <> tmp <> "\" \"" <> shared <> "\"")) ""
  -- 独占创建本身：同名已存在即抛异常，绝不截断复用
  ex <- try (openExclusiveBinary tmp >>= hClose) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "openExclusiveBinary 不得打开已存在的名字")) ex
  -- 落位仍应成功：pm 先 unlink 掉占位的目录项再独占创建。对 hardlink，
  -- DeleteFileW 只减一个目录项——库外原对象的**字节一个不动**（这正是与
  -- 「已存在即整批失败」相比更优的地方：崩溃重跑不需要人工清 tmp）。
  r <- execPlan defaultExecEnv plan
  case r of
    Right [(_, ODone {})] -> readFile (root </> "相册" </> "x.jpg") >>= (@?= "SOURCE-BYTES")
    other -> assertFailure ("清掉占位后应正常落位: " <> show other)
  readFile shared >>= (@?= "ORIGINAL-OUTSIDE-CONTENT")
  doesFileExist shared >>= (@?= True)

-- | 八轮 major：@.pm\/tmp\/\<planId\>@ 是 junction 时，@--repair@ 的孤儿 tmp
-- 清理会顺着链接删掉库外文件（探针实证删掉了库外 hostage.txt）。
caseDoctorTmpJunction :: IO ()
caseDoctorTmpJunction = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-tmp"
      planDir = tmpDirFor root tpid
  createDirectoryIfMissing True (pmDir root </> "tmp")
  createDirectoryIfMissing True outside
  writeFile (outside </> "hostage.txt") "HOSTAGE"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  mkJunction planDir outside
  rows <- doctorRows root
  assertBool
    ("链接内容不得被报为孤儿 tmp: " <> show rows)
    (not (any ((== "TMP-STALE") . fst) rows))
  _ <- runDoctor root (DoctorOpts False True)
  doesFileExist (outside </> "hostage.txt") >>= (@?= True)
  readFile (outside </> "hostage.txt") >>= (@?= "HOSTAGE")
  removeDirectoryLink planDir

-- | 八轮 minor：反转是对称操作，而 'opPathsOk' 的规则不对称——@.pm\/trash@
-- 只许作 rename 的源。一次合法复位历史的反向 Op 把它变成**目标**，此前
-- buildUndoPlan 照样成功，非法计划一直写进 .pm\/plans 才在 execItem 被拒。
caseUndoReverseResultValidated :: IO ()
caseUndoReverseResultValidated = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True root
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  withJournal root $ \j -> do
    -- 合法历史：把隔离文件从 trash 搬回原位（词法上正当，opPathsOk 通过）
    let restore = OpRename (".pm" </> "trash" </> "p" </> "v.jpg") "v.jpg" (FpFileSha "aa")
    opPathsOk restore @?= True
    jAppend j Barrier (JIntent (tpOid 0) restore now)
    jAppend j Barrier (JDone (tpOid 0) Nothing Nothing now)
  r <- buildUndoPlan root 1
  either
    (\m -> assertBool m ("生成的反向操作路径非法" `isInfixOf` m))
    (const (assertFailure "反向 Op 以 .pm/trash 为目标，应在生成时拒绝"))
    r
  doesDirectoryExist (pmDir root </> "plans") >>= (@?= False)

-- ─── P3b-12（九轮） ─────────────────────────────────────────────────────────

mkHardLink :: FilePath -> FilePath -> IO ()
mkHardLink link target =
  () <$ readCreateProcess (shell ("mklink /H \"" <> link <> "\" \"" <> target <> "\"")) ""

-- | 九轮 critical（它给的"更小反例"，已用探针复现）：'requirePmTrusted' 只走
-- @.pm@ 与 @.pm/tmp@ 这些**固定**层，planId 那一层是运行时构造的。把它预置成
-- 指向库外的 junction、库外放一个同名的确定性 tmp 文件，
-- 'Pm.Win.openFreshBinary' 的残留 unlink 就会删掉那个库外文件。
caseExecDynamicTmpJunction :: IO ()
caseExecDynamicTmpJunction = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-plan"
  createDirectoryIfMissing True (pmDir root </> "tmp")
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  op <- mkCopyOp (dir </> "s.jpg") "SOURCE-BYTES" ("相册" </> "x.jpg")
  pid <- newPlanId
  let plan = Plan pid "test" root (Just "m") now [PlanItem 0 op StPending Nothing]
      hostage = outside </> tmpNameFor 0 ("相册" </> "x.jpg")
  writeFile hostage "OUTSIDE-HOSTAGE"
  mkJunction (tmpDirFor root pid) outside
  -- 固定层全部合法，可信闸放行 —— 动态层必须逐次验，这正是九轮的缺口
  requirePmTrusted root >>= either (assertFailure . ("固定层应当可信: " <>)) pure
  resolveUnder root (".pm" </> "tmp" </> T.unpack pid </> "0-x.jpg") >>= (@?= Nothing)
  r <- execPlan defaultExecEnv plan
  case r of
    Right [(_, OConflict m)] -> assertBool ("应因限域拒绝: " <> m) ("逐级解析后不在" `isInfixOf` m)
    other -> assertFailure ("expected confinement OConflict, got " <> show other)
  doesFileExist hostage >>= (@?= True)
  readFile hostage >>= (@?= "OUTSIDE-HOSTAGE")
  doesFileExist (root </> "相册" </> "x.jpg") >>= (@?= False)
  removeDirectoryLink (tmpDirFor root pid)

-- | 九轮 major：建立身份的入口天然走不了 'requireWritable'（那时还没有身份），
-- 所以闸下沉到 'readRootState' —— 身份读取的唯一入口。
caseInitBypassUntrusted :: IO ()
caseInitBypassUntrusted = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-pm"
  createDirectoryIfMissing True root
  createDirectoryIfMissing True outside
  mkJunction (pmDir root) outside
  st <- readRootState root
  case st of
    RootUntrusted m -> assertBool m ("不是 root 下的真实目录" `isInfixOf` m)
    other -> assertFailure ("readRootState 应报不可信，得到 " <> show other)
  -- 三条建身份旁路共享的下游：createRootInfo 不得把标识建到库外
  now <- getCurrentTime
  _ <- createRootInfo root (RootInfo "x" RoleMain now Nothing)
  doesFileExist (outside </> "root-id.json") >>= (@?= False)
  -- pm init 的预检同样拒绝
  initPreflight root
    >>= either
      (\m -> assertBool m ("不是 root 下的真实目录" `isInfixOf` m))
      (const (assertFailure "initPreflight 应拒绝不可信 .pm"))
  removeDirectoryLink (pmDir root)

-- | 九轮 major（探针实证）：hardlink 既不是 reparse point 也不改 canonical，
-- 逐级下降与 canonical 判定都看不见它。实测预置 @journal.ndjson@ 为库外对象的
-- hardlink 后，@AppendMode@ 追加与覆盖写**都写到了库外对象**上。
caseStateFileHardlink :: IO ()
caseStateFileHardlink = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      sharedJ = dir </> "outside-journal.ndjson"
      sharedM = dir </> "outside-manifest.ndjson"
      sharedP = dir </> "outside-plan.json"
  createDirectoryIfMissing True (trashDir root)
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  writeFile sharedJ "OUTSIDE-ORIGINAL\n"
  writeFile sharedM "OUTSIDE-MANIFEST\n"
  writeFile sharedP "OUTSIDE-PLAN"
  mkHardLink (journalPath root) sharedJ
  mkHardLink (manifestPath root) sharedM
  -- journal：append 入口拒绝，库外字节不变
  rj <- try (withJournal root (\j -> jAppend j Barrier (JCleanShutdown now))) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "journal 应拒绝 hardlink 占用的名字")) rj
  readFile sharedJ >>= (@?= "OUTSIDE-ORIGINAL\n")
  -- manifest：同类
  rm <- try (appendManifest root (TrashRecord "v.jpg" "v.jpg" "aa" "test" tpid now)) :: IO (Either SomeException ())
  either (const (pure ())) (const (assertFailure "manifest 应拒绝 hardlink 占用的名字")) rm
  readFile sharedM >>= (@?= "OUTSIDE-MANIFEST\n")
  -- plan：覆盖写改成「独占创建 tmp → 删旧 → no-replace 落位」，删旧对 hardlink
  -- 只减一个目录项，库外对象的字节不变
  op <- mkCopyOp (dir </> "s.jpg") "X" ("相册" </> "x.jpg")
  plan <- mkPlanIO root [op]
  createDirectoryIfMissing True (pmDir root </> "plans")
  mkHardLink (pmDir root </> "plans" </> (T.unpack (plId plan) <> ".json")) sharedP
  _ <- savePlan plan
  readFile sharedP >>= (@?= "OUTSIDE-PLAN")

-- | 九轮 major：'pathAtOrUnder' 此前解析失败返回 False，而调用点取反用作
-- "不在 .pm 里 → 放行" —— 结构性 fail-open。三态把这个歧义消掉。
--
-- P3b-13（十轮复审 #7）：十轮指出本例**没有一个产生 Nothing 的输入**，
-- 于是"异常路径若错误地返回 Just False，用例仍绿"。补上 Nothing 分支，
-- 并直接断言 'confinedUser' 对它的处置（放行判据是 @Just False@，不是
-- "不是 Just True"）。
casePathAtOrUnderTristate :: IO ()
casePathAtOrUnderTristate = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True (pmDir root)
  writeFile (root </> "photo.jpg") "P"
  pathAtOrUnder (pmDir root) (pmDir root) >>= (@?= Just True)
  pathAtOrUnder (pmDir root) (pmDir root </> "journal.ndjson") >>= (@?= Just True)
  pathAtOrUnder (pmDir root) (root </> "photo.jpg") >>= (@?= Just False)
  -- Nothing 分支在本机**触发不了**：实测 canonicalizePath 对含 NUL 的名字截断、
  -- 对 CON/NUL 正常返回、对空路径解析成 cwd（Probe9 B + 本例最初的错误假设）。
  -- 因此改为直接钉住导出的判据本身——测真实代码，而不是在用例里复制一份 if。
  pathAtOrUnder "" (root </> "photo.jpg") >>= (@?= Just False) -- 空基准 = cwd，不抛异常
  admitsUserPath (Just False) @?= True
  admitsUserPath (Just True) @?= False
  admitsUserPath Nothing @?= False -- 答不上来 → 不放行

-- | 九轮 minor：身份不可用时不再生成一份 rootId 为空、execPlan 必然拒绝的
-- 计划 —— 它已经被 savePlan 写进 .pm/plans 了。
caseUndoRequiresIdentity :: IO ()
caseUndoRequiresIdentity = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
  createDirectoryIfMissing True (pmDir root)
  now <- getCurrentTime
  withJournal root $ \j -> do
    jAppend j Barrier (JIntent (tpOid 0) (OpRename "a.jpg" "b.jpg" (FpFileSha "aa")) now)
    jAppend j Barrier (JDone (tpOid 0) Nothing Nothing now)
  r <- buildUndoPlan root 1
  either
    (\m -> assertBool m ("无可用 root 标识" `isInfixOf` m))
    (const (assertFailure "无身份时应拒绝生成撤销计划"))
    r
  doesDirectoryExist (pmDir root </> "plans") >>= (@?= False)

-- ─── P3b-13（十轮） ─────────────────────────────────────────────────────────

-- | 十轮 critical（探针实证）：`.pm/backup-cache` 与 `.pm/vault-cache` 从来不在
-- 可信闸的白名单里——我前三轮每次补一个名字、每次都漏。把 `vault-cache` 做成
-- junction 后，正常的 `pm vault status` 会删掉并**替换库外**的
-- catalog.json/meta.json（实测库外文件变成了 pm 写的内容）。
--
-- 修法不是再补一个名字，而是让闸**枚举盘上实际有什么**。本例同时钉住两件事：
-- ①枚举式闸能抓到白名单永远不会去看的目录；②writeSideCache 的 root-relative
-- 接口在越界时一个字节都不写。
caseSideCacheJunction :: IO ()
caseSideCacheJunction = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-cache"
  createDirectoryIfMissing True (pmDir root)
  createDirectoryIfMissing True outside
  writeFile (outside </> "catalog.json") "OUTSIDE-CATALOG"
  writeFile (outside </> "meta.json") "OUTSIDE-META"
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  -- 闸此刻应当放行（.pm 下全是普通条目）
  requirePmTrusted root >>= either (assertFailure . ("干净 .pm 应当可信: " <>)) pure
  mkJunction (pmDir root </> "vault-cache") outside
  -- 枚举式闸抓到它——白名单（trash/tmp/plans）永远不会去看 vault-cache
  requirePmTrusted root
    >>= either
      (\m -> assertBool m ("vault-cache" `isInfixOf` m))
      (const (assertFailure "枚举式可信闸应当抓到 junction 化的 vault-cache"))
  -- writeSideCache 拒绝，且**一个字节都不写**
  w <- writeSideCache root "vault-cache" (mkCat [mkE ("相册" </> "a.jpg") "aa"]) (mkCat [])
  either (\m -> assertBool m ("vault-cache" `isInfixOf` m)) (const (assertFailure "侧缓存写应被拒绝")) w
  readFile (outside </> "catalog.json") >>= (@?= "OUTSIDE-CATALOG")
  readFile (outside </> "meta.json") >>= (@?= "OUTSIDE-META")
  removeDirectoryLink (pmDir root </> "vault-cache")

-- | 十轮 major：闸此前只在命令层，`pm status` / `pm versions` / apply 的计划
-- 查找都在闸之前就读了 `.pm`。闸下沉到 loader 后，每一次 root-based 的 `.pm`
-- 读取都经过它。
caseLoaderLevelGate :: IO ()
caseLoaderLevelGate = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-pm"
  createDirectoryIfMissing True root
  createDirectoryIfMissing True outside
  -- 库外放一份"看起来很正常"的 catalog 与 journal
  writeFile (outside </> "journal.ndjson") ""
  mkJunction (pmDir root) outside
  (mc, cw) <- loadCatalog root
  mc @?= Nothing
  assertBool ("loadCatalog 应报不可信: " <> show cw) (any ("不是 root 下的真实目录项" `isInfixOf`) cw)
  (js, jw) <- readJournal root
  js @?= []
  assertBool ("readJournal 应报不可信: " <> show jw) (any ("不是 root 下的真实目录项" `isInfixOf`) jw)
  (ms, mw) <- readManifest root
  ms @?= []
  assertBool ("readManifest 应报不可信: " <> show mw) (any ("不是 root 下的真实目录项" `isInfixOf`) mw)
  lp <- loadPlan root tpid
  either
    (\m -> assertBool m ("不是 root 下的真实目录项" `isInfixOf` m))
    (const (assertFailure "loadPlan 应拒绝不可信 root"))
    lp
  removeDirectoryLink (pmDir root)

-- | 十轮 #7：它指出 'caseExecDynamicTmpJunction' 在**第一次**检查前就放好了
-- junction，因此删掉建目录**之后**的第二次 confinedTmp 调用，那条用例照样绿。
-- 这里用 'CpCopyAfterIntent' 检查点在两次检查**之间**注入 junction，专门钉住
-- 第二次检查：没有它，落位就会沿 junction 走到库外。
caseExecTmpSecondCheck :: IO ()
caseExecTmpSecondCheck = withSystemTempDirectory "pm-guard" $ \dir -> do
  let root = dir </> "root"
      outside = dir </> "outside-plan2"
  createDirectoryIfMissing True (pmDir root </> "tmp")
  createDirectoryIfMissing True outside
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  op <- mkCopyOp (dir </> "s.jpg") "SOURCE-BYTES" ("相册" </> "x.jpg")
  pid <- newPlanId
  let plan = Plan pid "test" root (Just "m") now [PlanItem 0 op StPending Nothing]
      pdir = tmpDirFor root pid
      hostage = outside </> tmpNameFor 0 ("相册" </> "x.jpg")
  writeFile hostage "OUTSIDE-HOSTAGE"
  -- 第一次检查时 .pm/tmp/<planId> 尚不存在（合法：pm 自己会建）；
  -- Intent 落盘后、tmp 写入前，把它换成指向库外的 junction。
  let env =
        defaultExecEnv
          { eeCheckpoint = \c ->
              when (c == CpCopyAfterIntent) $ do
                ex <- doesDirectoryExist pdir
                when ex (removeDirectory pdir)
                mkJunction pdir outside
          }
  r <- execPlan env plan
  case r of
    Right [(_, OConflict m)] -> assertBool ("应因第二次限域拒绝: " <> m) ("逐级解析后不在" `isInfixOf` m)
    other -> assertFailure ("expected second-check confinement OConflict, got " <> show other)
  doesFileExist hostage >>= (@?= True)
  readFile hostage >>= (@?= "OUTSIDE-HOSTAGE")
  removeDirectoryLink pdir
