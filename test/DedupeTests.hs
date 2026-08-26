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

import Pm.Catalog (saveCatalog)
import Pm.Cli (runBarrier)
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
    , testCase "内核只收自洽的降级清单：未知序号 / 已 skip 条目 → 整批拒绝" caseBarrierBadDemotion
    , testCase "trash empty 也在 I10 锁内：锁被占 → 退出，一个文件不删、manifest 一行不读" caseTrashEmptyTakesLock
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

-- | 把降级清单折回旧断言用的标签序列：屏障接口改为「返回降级清单、内核应用」
-- （三十轮 F4 类型封闭）后，各用例的**语义断言不变**，只换读法。
tagsOf :: Plan -> [(Int, T.Text)] -> [String]
tagsOf plan dem =
  [ if piIx it `elem` map fst dem then "DECIDE" else "PENDING"
  | it <- plItems plan
  ]

-- | 两份同字节：批准其中一份 → 那一份保持 PENDING；两份都批准 → 两份都降级。
caseBarrierKeepsOne :: IO ()
caseBarrierKeepsOne = withDup $ \root sha a b -> do
  pl1 <- planOf [(a, sha)]
  d1 <- recheckDedupeItems root (dupCat sha a b) pl1
  tagsOf pl1 d1 @?= ["PENDING"]
  pl2 <- planOf [(a, sha), (b, sha)]
  d2 <- recheckDedupeItems root (dupCat sha a b) pl2
  tagsOf pl2 d2 @?= ["DECIDE", "DECIDE"]

-- | catalog 声称第二份还在，盘上已经没有 → 不能放行。这正是"生成计划与执行
-- 之间的世界会变"：另一份可能已被别的计划移走。
caseBarrierSurvivorMissing :: IO ()
caseBarrierSurvivorMissing = withDup $ \root sha a b -> do
  removeFile (root </> b)
  pl <- planOf [(a, sha)]
  d <- recheckDedupeItems root (dupCat sha a b) pl
  tagsOf pl d @?= ["DECIDE"]

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
  pl <- planOf [(a, sha)]
  d <- recheckDedupeItems root (dupCat sha a b) pl
  tagsOf pl d @?= ["PENDING"]

-- | 受害者与幸存者互为 hardlink：**同一个对象**的两个名字。隔离掉 a 之后
-- 「归档层还有一份」在物理上是假的——两个名字下只有一份字节。屏障必须拦。
--
-- 这是身份判据要守住的那一半：路径名单挡不住它（两条路径确实不同），
-- 只有 (卷序列号, 文件索引) 相等这一条看得见。
caseBarrierSameObject :: IO ()
caseBarrierSameObject = withDup $ \root sha a b -> do
  removeFile (root </> b)
  _ <- readCreateProcess (shell ("mklink /H " <> q (root </> b) <> " " <> q (root </> a))) ""
  pl <- planOf [(a, sha)]
  d <- recheckDedupeItems root (dupCat sha a b) pl
  tagsOf pl d @?= ["DECIDE"]

-- | 受害者名单只差大小写：仍要算成同一份，否则 b 会被当成"另一份幸存者"，
-- 屏障放行，两份一起进 trash。
caseBarrierCaseFold :: IO ()
caseBarrierCaseFold = withDup $ \root sha a b -> do
  let bUp = map upper b
      upper c = if c >= 'a' && c <= 'z' then toEnum (fromEnum c - 32) else c
  pl <- planOf [(a, sha), (bUp, sha)]
  d <- recheckDedupeItems root (dupCat sha a b) pl
  tagsOf pl d @?= ["DECIDE", "DECIDE"]

-- | 暂存区不是归档层：To-Be-Sync'd 里的同 sha 副本不能充当"还留着一份"。
caseStagingIsNotSurvivor :: IO ()
caseStagingIsNotSurvivor = withDup $ \root sha a _ -> do
  let stg = "To-Be-Sync'd" </> "Raw" </> "26-01-Z" </> "dup.arw"
  createDirectoryIfMissing True (root </> "To-Be-Sync'd" </> "Raw" </> "26-01-Z")
  writeFile (root </> stg) dupBody
  let cat = mkCat [ent a sha, ent stg sha]
  archiveLayerRel stg @?= False
  survivingArchiveCopies cat Set.empty (T.pack sha) @?= [a]
  pl <- planOf [(a, sha)]
  d <- recheckDedupeItems root cat pl
  tagsOf pl d @?= ["DECIDE"]

-- ─── 接线（两条路径共用一张表 / trash empty 的分流） ──────────────────────

-- | 三十轮 F4 类型封闭之后，「要不要屏障」与「是哪个屏障」由同一个
-- 'BarrierKind' 钉死（'runBarrier' 对构造子 total 匹配，漏写编译不过），
-- 旧的"两半表一致"测试退役。这里钉的是分类器的**覆盖面**——哪些 kind 进
-- 屏障、哪些明确不进——以及 dedupe 屏障经 'runBarrier' 真的给出降级清单。
casePreExecRow :: IO ()
casePreExecRow = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "m" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing
  kindBarrier "dedupe" @?= Just BarrierDedupe
  kindBarrier "clean-staging" @?= Just BarrierClean
  forM_ ["sort", "backup", "import", "names", "undo", "vault-push", "restore-from-backup"] $ \k ->
    kindBarrier k @?= Nothing
  -- 两份都批准 → dedupe 屏障给出全量降级清单
  pd <- planOf [(a, sha), (b, sha)]
  dem <- runBarrier cfg BarrierDedupe pd {plRootPath = root}
  map fst dem @?= [0, 1]
  -- 三十二轮（p6a#0 残余关闭）：构造子 → 实现的**对应关系**按降级理由区分。
  -- 只比序号时两行 RHS 对调仍绿——本 fixture 备份未登记，clean 屏障会以
  -- 「备份盘不在线」把同样的 [0,1] 全量降级；理由文本才分得出接的是哪个。
  assertBool ("dedupe 屏障的理由应指归档层余量: " <> show dem)
    (all (T.isInfixOf "归档层" . snd) dem)
  demC <- runBarrier cfg BarrierClean pd {plRootPath = root}
  map fst demC @?= [0, 1]
  assertBool ("clean 屏障的理由应指三副本复验: " <> show demC)
    (all (T.isInfixOf "复验三副本" . snd) demC)

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
  let probe _ p = do
        held <- withRootLock root (pure ())
        writeIORef seen (Just held)
        -- 全部降级，免得这条用例真去动盘
        pure [(piIx it, "test") | it <- plItems p]
  _ <- execPlan defaultExecEnv {eeBarrier = Just probe} plan
  m <- readIORef seen
  -- Just Nothing = 屏障被调用了（外层 Just），且锁已被持有（内层 Nothing）
  m @?= Just Nothing

-- | 用 'defaultExecEnv' 执行一个 dedupe 计划——即库层调用者忘了装屏障。
-- 内核必须整批拒绝：'Pm.Plan.kindBarrier' 说这种计划要屏障，缺席本身
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

-- | 三十轮 F4 类型封闭后，「升级回 pending / 改写 Op / 改写元数据」在类型上
-- 写不出来；内核仅存的自卫是降级清单必须**自洽**。两个失洽形态都要拒：
-- 清单指向不存在的序号；清单指向用户已 skip 的条目（屏障的世界观与计划不符）。
caseBarrierBadDemotion :: IO ()
caseBarrierBadDemotion = withDup $ \root sha a b -> do
  now <- getCurrentTime
  writeRootInfo root (RootInfo "r" RoleMain now Nothing)
  saveCatalog root (dupCat sha a b)
  p0 <- planOf [(a, sha)]
  let plan = p0 {plRootPath = root}
  r1 <- execPlan defaultExecEnv {eeBarrier = Just (\_ _ -> pure [(99, "?")])} plan
  case r1 of
    Right _ -> assertFailure "内核接受了指向不存在序号的降级清单"
    Left m -> assertBool ("应因未知序号被拒，实为: " <> m) ("不存在的条目序号" `isInfixOf` m)
  let skipped = plan {plItems = [it {piStatus = StSkippedByUser} | it <- plItems plan]}
  r2 <- execPlan defaultExecEnv {eeBarrier = Just (\_ _ -> pure [(0, "?")])} skipped
  case r2 of
    Right _ -> assertFailure "内核接受了降级已 skip 条目的清单"
    Left m -> assertBool ("应因非 PENDING 被拒，实为: " <> m) ("不是 PENDING" `isInfixOf` m)
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

-- | 引号包路径：路径里有空格时 mklink 会把参数拆开。
q :: FilePath -> String
q p = [dq] <> p <> [dq]
 where
  dq = toEnum 34
