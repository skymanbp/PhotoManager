{-# LANGUAGE OverloadedStrings #-}

-- | @pm dedupe@（P5-B）：来源与 @pm versions@ 同一份报告、每条都待裁决、
-- 以及**执行期屏障**——批准隔离的条目不得把某个内容在归档层的最后一份活副本
-- 也隔离掉。
--
-- 屏障的用例都用**真实文件**：它问的不是"catalog 里还有没有另一条记录"，而是
-- "盘上还读不读得出那些字节"。断言 'PlanItem' 的字段等于换个说法把 catalog
-- 又信了一遍，钉不住这件事。
module DedupeTests (dedupeTests) where

import Control.Monad (forM_)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (fromJust, isJust)

import Pm.Catalog (saveCatalog)
import Pm.Cli (preExecFor)
import Pm.Exec (ExecEnv (..), defaultExecEnv, execPlan)
import Pm.Lock (withRootLock)
import Pm.Commands (TrashCmd (..), runTrash)
import Pm.Config (Config (..), writeRootInfo)
import Pm.Dedupe
import Pm.Hash (sha256File)
import Pm.Op
import Pm.Plan
import Pm.Trash (TrashRecord (..), appendManifest, manifestPath, trashDir)
import Pm.Types

import TestUtil (captureStdout, mkCat, t0)

dedupeTests :: TestTree
dedupeTests =
  testGroup
    "P5-B pm dedupe（来源同 versions · 全待裁决 · 执行期「至少留一份」屏障）"
    [ testCase "设计内冗余不进 dedupe，同层两份进" caseGroupsSource
    , testCase "每一份都是独立可裁决条目：全 NEEDS-DECISION、不绑复合组" caseAllNeedsDecision
    , testCase "隔离 reason 带 dedupe 前缀（trash empty 据此分流到本类屏障）" caseReasonPrefix
    , testCase "批准 N-1 份 → 放行；批准全部 N 份 → 全部降级待裁决" caseBarrierKeepsOne
    , testCase "幸存者 catalog 有、盘上没有 → 降级（catalog 是快照不是证据）" caseBarrierSurvivorMissing
    , testCase "幸存者是 hardlink 但与受害者是不同对象 → 放行（旧的 link count 判据会在这里假 HELD）" caseBarrierSurvivorHardlink
    , testCase "受害者与幸存者互为 hardlink（同一对象）→ 降级，同一对象不算两份副本" caseBarrierSameObject
    , testCase "受害者名单 case-fold：只差大小写仍算同一份，屏障照样拦" caseBarrierCaseFold
    , testCase "暂存区的同 sha 副本不算归档层幸存者" caseStagingIsNotSurvivor
    , testCase "preExecFor 表里有 dedupe 这一行（apply 与 --apply 共用同一张表）" casePreExecRow
    , testCase "trash empty：dedupe 记录归档层无活副本 → HELD 不删；有 → 清除" caseTrashEmptyBarrier
    , testCase "屏障在 root 锁**内**跑（屏障里再取同一把锁必须失败）" caseBarrierRunsInsideLock
    , testCase "内核 fail-closed：dedupe 计划没装屏障 → 整批拒绝，不是静默跳过" caseKernelRefusesMissingBarrier
    , testCase "内核不信屏障：把条目升级回 pending → 整批拒绝" caseBarrierMayNotPromote
    , testCase "trash empty 也在 I10 锁内：锁被占 → 退出，一个文件不删、manifest 一行不读" caseTrashEmptyTakesLock
    , testCase "内核冻结屏障返回值的计划元数据：改写 plId → 整批拒绝" caseBarrierMetaFrozen
    ]

-- ─── 纯核心 ────────────────────────────────────────────────────────────────

-- | 来源就是 'Pm.Versions.versionsReport'：成片↔相册同名是**设计内**拓扑，
-- 不进 dedupe；同一层里的两份才是真重复。这条用例保证 dedupe 不会另起一套
-- 判据——两处判据分叉，用户看到的报告与能操作的计划就对不上了。
caseGroupsSource :: IO ()
caseGroupsSource = do
  let designed = mkCat [ent ("成片" </> "a.jpg") "s1", ent ("相册" </> "a.jpg") "s1"]
      real2 =
        mkCat
          [ ent ("Raw" </> "2025" </> "25-01-X-Raw" </> "a.arw") "s2"
          , ent ("Raw" </> "2025" </> "25-02-Y-Raw" </> "a.arw") "s2"
          ]
  map dgSha (dedupeGroups designed) @?= []
  map dgSha (dedupeGroups real2) @?= ["s2"]
  map (length . dgPaths) (dedupeGroups real2) @?= [2]

caseAllNeedsDecision :: IO ()
caseAllNeedsDecision = do
  let gs = [DupGroup "s" ["Raw" </> "a", "成片" </> "b", "相册" </> "c"]]
      items = dedupePlanItems gs
  length items @?= 3
  map piIx items @?= [0, 1, 2]
  -- 不绑复合组：复合组会让 resolve 的选择扩到全组，而这里要求逐份裁决。
  map piGroup items @?= [Nothing, Nothing, Nothing]
  assertBool "全部应为 NEEDS-DECISION" (all (isDecide . piStatus) items)
 where
  isDecide (StNeedsDecision _) = True
  isDecide _ = False

caseReasonPrefix :: IO ()
caseReasonPrefix = do
  let items = dedupePlanItems [DupGroup "s" ["Raw" </> "a", "成片" </> "b"]]
  forM_ items $ \it -> case piOp it of
    OpQuarantine _ _ r ->
      assertBool
        ("reason 必须以 " <> T.unpack dedupeReasonPrefix <> " 开头，实为 " <> T.unpack r)
        (dedupeReasonPrefix `T.isPrefixOf` r)
    other -> assertFailure ("dedupe 只出 quarantine，实为 " <> describeOp other)

-- ─── 执行期屏障（真实文件） ────────────────────────────────────────────────

-- | 两份同字节：批准其中一份 → 那一份保持 PENDING；两份都批准 → 两份都降级。
caseBarrierKeepsOne :: IO ()
caseBarrierKeepsOne = withDup $ \root sha a b -> do
  p1 <- recheckDedupeItems root (dupCat sha a b) =<< planOf [(a, sha)]
  map statusTag (plItems p1) @?= ["PENDING"]
  p2 <- recheckDedupeItems root (dupCat sha a b) =<< planOf [(a, sha), (b, sha)]
  map statusTag (plItems p2) @?= ["DECIDE", "DECIDE"]

-- | catalog 声称第二份还在，盘上已经没有 → 不能放行。这正是"生成计划与执行
-- 之间的世界会变"：另一份可能已被别的计划移走。
caseBarrierSurvivorMissing :: IO ()
caseBarrierSurvivorMissing = withDup $ \root sha a b -> do
  removeFile (root </> b)
  p <- recheckDedupeItems root (dupCat sha a b) =<< planOf [(a, sha)]
  map statusTag (plItems p) @?= ["DECIDE"]

-- | 幸存者 b 是 hardlink，但它的另一端在库外的第三个名字上——它与受害者 a
-- 仍是**两个不同的对象**，屏障应当放行。
--
-- 这正是旧判据（link count == 1）的假阴性：nlink 2 就一律拒读，于是一份合法
-- 归档照片被去重工具另建一个名字之后，clean staging / trash empty 永远 HELD
-- （codex 二十八轮 #2）。
caseBarrierSurvivorHardlink :: IO ()
caseBarrierSurvivorHardlink = withDup $ \root sha a b -> do
  let outside = takeDirectory root </> "outside-name.arw"
  removeFile (root </> b)
  writeFile outside dupBody
  _ <- readCreateProcess (shell ("mklink /H " <> q (root </> b) <> " " <> q outside)) ""
  p <- recheckDedupeItems root (dupCat sha a b) =<< planOf [(a, sha)]
  map statusTag (plItems p) @?= ["PENDING"]

-- | 受害者与幸存者互为 hardlink：**同一个对象**的两个名字。隔离掉 a 之后
-- 「归档层还有一份」在物理上是假的——两个名字下只有一份字节。屏障必须拦。
--
-- 这是身份判据要守住的那一半：路径名单挡不住它（两条路径确实不同），
-- 只有 (卷序列号, 文件索引) 相等这一条看得见。
caseBarrierSameObject :: IO ()
caseBarrierSameObject = withDup $ \root sha a b -> do
  removeFile (root </> b)
  _ <- readCreateProcess (shell ("mklink /H " <> q (root </> b) <> " " <> q (root </> a))) ""
  p <- recheckDedupeItems root (dupCat sha a b) =<< planOf [(a, sha)]
  map statusTag (plItems p) @?= ["DECIDE"]

-- | 受害者名单只差大小写：仍要算成同一份，否则 b 会被当成"另一份幸存者"，
-- 屏障放行，两份一起进 trash。
caseBarrierCaseFold :: IO ()
caseBarrierCaseFold = withDup $ \root sha a b -> do
  let bUp = map upper b
      upper c = if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c
  p <- recheckDedupeItems root (dupCat sha a b) =<< planOf [(a, sha), (bUp, sha)]
  map statusTag (plItems p) @?= ["DECIDE", "DECIDE"]

-- | 暂存区不是归档层：To-Be-Sync'd 里的同 sha 副本不能充当"还留着一份"。
caseStagingIsNotSurvivor :: IO ()
caseStagingIsNotSurvivor = withDup $ \root sha a _ -> do
  let stg = "To-Be-Sync'd" </> "Raw" </> "26-01-Z" </> "dup.arw"
  createDirectoryIfMissing True (root </> "To-Be-Sync'd" </> "Raw" </> "26-01-Z")
  writeFile (root </> stg) dupBody
  let cat = mkCat [ent a sha, ent stg sha]
  archiveLayerRel stg @?= False
  survivingArchiveCopies cat Set.empty (T.pack sha) @?= [a]
  p <- recheckDedupeItems root cat =<< planOf [(a, sha)]
  map statusTag (plItems p) @?= ["DECIDE"]

-- ─── 接线（两条路径共用一张表 / trash empty 的分流） ──────────────────────

-- | 屏障表有**两半**：'Pm.Plan.kindNeedsBarrier' 说哪些种类要屏障（内核据此
-- fail-closed），'Pm.Cli.preExecFor' 说是哪一个。两半必须逐 kind 一致——
-- 一边有一边没有，就是「内核以为有人管，其实没人管」或「内核整批拒绝一个
-- 本来能跑的计划」。这条用例把两半钉在一起，并验 dedupe 那个屏障真的降级。
casePreExecRow :: IO ()
casePreExecRow = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
      kinds = ["dedupe", "clean-staging", "sort", "backup", "import", "names", "undo", "vault-push"]
  -- 两半一致：kindNeedsBarrier k  ⟺  preExecFor 给得出屏障
  [(k, kindNeedsBarrier k) | k <- kinds]
    @?= [(k, isJust (preExecFor cfg k)) | k <- kinds]
  -- 两份都批准 → dedupe 那个屏障生效，全部降级
  pd <- planOf [(a, sha), (b, sha)]
  p1 <- fromJust (preExecFor cfg "dedupe") pd {plRootPath = root}
  map statusTag (plItems p1) @?= ["DECIDE", "DECIDE"]
  -- 对照：sort 在表外，两半都说"不需要"
  isJust (preExecFor cfg "sort") @?= False

-- | @pm trash empty@ 的永久删除前分流：reason 带 dedupe 前缀的记录要走
-- 「归档层还留着一份活副本吗」这道屏障。归档层没有 → HELD，文件仍在；
-- 有 → 才允许永久删除。
caseTrashEmptyBarrier :: IO ()
caseTrashEmptyBarrier = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
      rel = "p" </> "dup.arw"
  createDirectoryIfMissing True (trashDir root </> "p")
  writeFile (trashDir root </> rel) dupBody
  appendManifest root (TrashRecord b rel (T.pack sha) "dedupe:同 sha 2 份之一" "p" now)
  -- b 已被隔离（不在原位），a 也不在了 → 归档层无活副本 → HELD。
  -- catalog 仍然**声称**两条都在：屏障必须真去读盘，不能信快照。
  removeFile (root </> a)
  removeFile (root </> b)
  saveCatalog root (dupCat sha a b)
  c1 <- runTrash cfg (TrashEmpty True) root
  c1 @?= 1
  doesFileExist (trashDir root </> rel) >>= (@?= True)
  -- a 回来 → 屏障放行，永久删除
  writeFile (root </> a) dupBody
  c2 <- runTrash cfg (TrashEmpty True) root
  c2 @?= 0
  doesFileExist (trashDir root </> rel) >>= (@?= False)

-- ─── 二十九轮 critical：判据与动盘必须是同一个跨进程事务 ───────────────────

-- | 这条是修法的**直接**断言，不是间接证据：屏障函数运行期间再取一次同一个
-- root 的锁必须失败（'withRootLock' 不可重入）。取得到 = 屏障跑在锁外，
-- 也就回到了两个 pm 进程各自放行同一内容不同副本的那个窗口。
caseBarrierRunsInsideLock :: IO ()
caseBarrierRunsInsideLock = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "r" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  plan <- (\p -> p {plRootPath = root}) <$> planOf [(a, sha)]
  seen <- newIORef Nothing
  let probe p = do
        held <- withRootLock root (pure ())
        writeIORef seen (Just held)
        -- 全部降级，免得这条用例真去动盘
        pure p {plItems = [it {piStatus = StNeedsDecision "test"} | it <- plItems p]}
  _ <- execPlan defaultExecEnv {eeBarrier = Just probe} plan
  m <- readIORef seen
  -- Just Nothing = 屏障被调用了（外层 Just），且锁已被持有（内层 Nothing）
  m @?= Just Nothing

-- | 用 'defaultExecEnv' 执行一个 dedupe 计划——即库层调用者忘了装屏障。
-- 内核必须整批拒绝：'Pm.Plan.kindNeedsBarrier' 说这种计划要屏障，缺席本身
-- 就是硬失败。P3b-5/A3 的教训（承重闸不能只挂在可覆盖的钩子上）在这里的
-- 落法不是把闸搬进内核（内核算不出「归档层还剩几份」），而是让缺席可见。
caseKernelRefusesMissingBarrier :: IO ()
caseKernelRefusesMissingBarrier = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "r" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  plan <- (\p -> p {plRootPath = root}) <$> planOf [(a, sha)]
  r <- execPlan defaultExecEnv plan
  case r of
    Right _ -> assertFailure "内核放行了一个没有装屏障的 dedupe 计划"
    Left m -> assertBool ("应因缺屏障被拒，实为: " <> m) ("需要执行期屏障" `isInfixOf` m)
  -- 一个字节都不该动
  doesFileExist (root </> a) >>= (@?= True)
  doesFileExist (root </> b) >>= (@?= True)

-- | 屏障是命令层传进来的函数，内核对它一贯不信任。把用户已经 skip 的条目
-- **升级**回 pending 等于绕过用户的决定去动盘——整批拒绝，不是只忽略那一项。
caseBarrierMayNotPromote :: IO ()
caseBarrierMayNotPromote = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "r" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  p0 <- planOf [(a, sha)]
  let plan =
        p0
          { plRootPath = root
          , plItems = [it {piStatus = StSkippedByUser} | it <- plItems p0]
          }
      evil p = pure p {plItems = [it {piStatus = StPending} | it <- plItems p]}
  r <- execPlan defaultExecEnv {eeBarrier = Just evil} plan
  case r of
    Right _ -> assertFailure "内核接受了一个把条目升级回 pending 的屏障"
    Left m -> assertBool ("应因屏障改写计划被拒，实为: " <> m) ("升级回 pending" `isInfixOf` m)
  doesFileExist (root </> a) >>= (@?= True)

-- | 同根第二处：@pm trash empty@ 是 pm 全程唯一 unlink 用户数据的路径，
-- 它的屏障判据与 removeFile 之间此前同样没有跨进程保护。锁被占时整条命令
-- 退出（码 2），一个文件都不删——而不是"反正判定过了"照删。
caseTrashEmptyTakesLock :: IO ()
caseTrashEmptyTakesLock = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
      rel = "p" </> "dup.arw"
  createDirectoryIfMissing True (trashDir root </> "p")
  writeFile (trashDir root </> rel) dupBody
  appendManifest root (TrashRecord b rel (T.pack sha) "dedupe:同 sha 2 份之一" "p" now)
  saveCatalog root (dupCat sha a b)
  -- a 还在盘上，无锁时这一批本来会被永久删除（见 caseTrashEmptyBarrier 的后半段）。
  -- 三十轮 F1 的直接断言：**视图也是证据**——锁被占时连 manifest 都不该读。
  -- 先塞一行坏记录：坏行警告若被打印，说明视图取在锁外。
  appendFile (manifestPath root) "not-json\n"
  (out, mc) <- captureStdout (withRootLock root (runTrash cfg (TrashEmpty True) root))
  mc @?= Just 2
  assertBool "锁被占时不得读 manifest（坏行警告不应出现）" (not ("manifest 损坏行" `isInfixOf` out))
  doesFileExist (trashDir root </> rel) >>= (@?= True)

-- | 三十轮 F4：屏障是命令层传进来的函数，内核冻结它能改的范围——不止状态
-- 只许降级（caseBarrierMayNotPromote），**计划元数据也不许动**：plId 参与
-- opId/tmp/trash 路径推导，被改写会让 journal 的 opId 与旧计划碰撞。
caseBarrierMetaFrozen :: IO ()
caseBarrierMetaFrozen = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "r" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  plan <- (\p -> p {plRootPath = root}) <$> planOf [(a, sha)]
  let evil p = pure p {plId = "20260101-000000-ffffff"}
  r <- execPlan defaultExecEnv {eeBarrier = Just evil} plan
  case r of
    Right _ -> assertFailure "内核接受了改写 plId 的屏障"
    Left m -> assertBool ("应因元数据改写被拒，实为: " <> m) ("元数据" `isInfixOf` m)
  doesFileExist (root </> a) >>= (@?= True)

-- ─── fixtures ──────────────────────────────────────────────────────────────

dupBody :: String
dupBody = "same-bytes-in-two-places"

-- | 真实 root：@Raw\/2025\/25-01-X-Raw\/dup.arw@ 与 @成片\/2025\/dup.jpg@
-- 同字节。回调收到 (root, sha, relA, relB)。
withDup :: (FilePath -> String -> FilePath -> FilePath -> IO ()) -> IO ()
withDup k = withSystemTempDirectory "pm-dedupe" $ \root -> do
  let a = "Raw" </> "2025" </> "25-01-X-Raw" </> "dup.arw"
      b = "成片" </> "2025" </> "dup.jpg"
  forM_ [a, b] $ \rel -> do
    createDirectoryIfMissing True (root </> takeDir rel)
    writeFile (root </> rel) dupBody
  sha <- T.unpack <$> sha256File (root </> a)
  k root sha a b
 where
  takeDir = reverse . drop 1 . dropWhile (/= '\\') . reverse

dupCat :: String -> FilePath -> FilePath -> Catalog
dupCat sha a b = mkCat [ent a sha, ent b sha]

ent :: FilePath -> String -> Entry
ent p sha = Entry p (fromIntegral (length dupBody)) 0 (T.pack sha) KindPhoto Nothing

-- | 只含 quarantine 的待执行计划（模拟用户已 @resolve --unskip@ 批准的那些）。
planOf :: [(FilePath, String)] -> IO Plan
planOf vs =
  pure
    Plan
      { plId = "20260101-000000-abcdef"
      , plKind = "dedupe"
      , plRootPath = "."
      , plRootId = Just "r"
      , plCreated = t0
      , plItems =
          [ PlanItem ix (OpQuarantine v (T.pack sha) "dedupe:test") StPending Nothing
          | (ix, (v, sha)) <- zip [0 ..] vs
          ]
      }

statusTag :: PlanItem -> String
statusTag it = case piStatus it of
  StPending -> "PENDING"
  StSkippedByUser -> "SKIPPED"
  StNeedsDecision _ -> "DECIDE"


-- | 引号包路径：路径里有空格时 mklink 会把参数拆开。
q :: FilePath -> String
q p = [dq] <> p <> [dq]
 where
  dq = toEnum 34
