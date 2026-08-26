{-# LANGUAGE OverloadedStrings #-}

-- | Shared CLI plumbing for the command layer (split out of app\/Main.hs):
-- the one true plan-execution path, root-identity binding (评审 cx-1)、
-- clean 计划的执行期三副本复验（评审 cx-3）、--only 的组闭包展开
-- （评审 cx-2）。GUI\/serve (P4) 将复用同一路径。
module Pm.Cli
  ( GoOpts (..)
  , confirm
  , renderPlanBrief
  , executePlanNow
  , executePlanNowWith
  , savePlanAndMaybeRun
  , bindExecRoot
  , runBarrier
  , writeBackCatalog
  , recheckCleanPlan
  , recheckCleanItems
  , recheckDedupePlan
  , applyOnlyToPlan
  , parseOnly
  , stagingFresh
  , withFreshStagingCatalog
  , freshStagingCatalog
  , reportScanIssues
  , refreshBackupCache
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toLower)
import Data.Function (on)
import Data.List (intercalate, nubBy)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (canonicalizePath)
import System.FilePath (splitDirectories)
import System.IO (hFlush, stdout)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Pm.Backup
import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Clean (threeCopiesStillExist)
import Pm.Hash (ContentProbe (..), probeConfined)
import Pm.Config (Config (..), SideCacheWrite (..), readRootInfo, requireMain, requireWritable)
import Pm.Dedupe (recheckDedupeItems)
import Pm.Diff (BackupDiff (..))
import Pm.Exec (ExecEnv (..), ItemOutcome (..), defaultExecEnv, execPlan, outcomeLabel, updateCatalog)
import Pm.Import (stagingTop)
import Pm.Journal (Sync (..))
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Scan (ScanResult (..), freshnessSweep)
import Pm.Types
import Pm.Win (volumeFsType)

-- | 写盘命令共有的两段式开关（DESIGN.md §5）。
data GoOpts = GoOpts
  { goApply :: Bool
  , goYes :: Bool
  }

confirm :: GoOpts -> IO Bool
confirm go
  | not (goApply go) = pure False
  | goYes go = pure True
  | otherwise = do
      putStr "执行以上计划? [y/N] "
      hFlush stdout
      l <- getLine
      pure (map toLower l `elem` ["y", "yes"])

-- | 大计划只展示头部，完整清单在计划文件里（pm apply --dry 可全量打印）。
renderPlanBrief :: Plan -> IO ()
renderPlanBrief plan = do
  let ls = renderPlan plan
      cap = 32
  if length ls <= cap + 1
    then mapM_ putStrLn ls
    else do
      mapM_ putStrLn (take (cap + 1) ls)
      printf "  …另有 %d 项（pm apply --dry %s 查看全量）\n" (length ls - cap - 1) (T.unpack (plId plan))

-- | 执行一个计划并回写其 root 的 catalog。备份计划的 Copy Done 走 Barrier
-- （可移动介质，§9）；执行 root 的 UUID 在锁内复验（cx-1）。
-- P2.2 fail-closed（复审 cx-1 残留）：CLI 层一律拒绝执行无 rootId 的计划，
-- 包括 --apply 即时路径——root 没有身份就没有执行资格，没有例外。
executePlanNow :: Config -> Plan -> IO Int
executePlanNow cfg = fmap fst . executePlanNowWith cfg putStrLn

-- | 同上，但**打印口由调用方给**，且把逐项结果一并交回。
--
-- 为什么打印必须可替换：`pm ui` 只从 serve 的 stdout 读**一行** announce，随后
-- 就丢掉那个 BufReader——管道之后再无人排空。API 的 apply 端点若照着 stdout 打
-- 逐项结果，一个上千项的计划会先填满管道缓冲、然后 serve 卡在写上（或拿到
-- broken pipe）。端点因此传一个把行收进 IORef 的 sink，把它们放进 JSON 响应体。
--
-- 逐项结果同样交回：CLI 只要退出码，API 要把每一项的结局报给页面。两者共用
-- **同一次**执行与同一次 catalog 回写，不另起一条执行路径。
executePlanNowWith :: Config -> (String -> IO ()) -> Plan -> IO (Int, [(PlanItem, ItemOutcome)])
executePlanNowWith cfg sink plan = case plRootId plan of
  Nothing -> do
    sink "计划缺 root 标识，拒绝执行（cx-1 fail-closed）→ pm init 建立 root 标识后重新生成计划"
    pure (2, [])
  Just _ -> executePlanNow' cfg sink plan

executePlanNow' :: Config -> (String -> IO ()) -> Plan -> IO (Int, [(PlanItem, ItemOutcome)])
executePlanNow' cfg sink plan = do
  let root = plRootPath plan
      env =
        defaultExecEnv
          { eeDoneSync = if plKind plan == "backup" then Barrier else Buffered
          , eeExpectRootId = plRootId plan
          , -- 二十九轮 critical：屏障装进 ExecEnv，由内核在 withRootLock **内**
            -- 跑；这是唯一一处装配点，调用方连"跳过屏障"这个选项都没有。
            -- 无条件装上（不再按 kind 挑）：内核先查 'Pm.Plan.kindBarrier'，
            -- 不需要屏障的计划根本不会调它；需要而没装（库层调用者用
            -- defaultExecEnv）仍整批拒绝。
            eeBarrier = Just (runBarrier cfg)
          }
  r <- execPlan env plan
  case r of
    Left e -> sink e >> pure (2, [])
    Right results -> do
      forM_ results $ \(it, out) ->
        sink (printf "  %3d → %s" (piIx it) (outcomeLabel out))
      writeBackCatalog sink root results
      let bad = [() | (_, out) <- results, isBad out]
      unless (null bad) $
        sink (printf "⚠ %d 项 CONFLICT/FAILED（其余不受影响；详见逐项结果）" (length bad))
      pure (if null bad then 0 else 1, results)
 where
  isBad (OConflict _) = True
  isBad (OFailed _) = True
  isBad _ = False

-- | 'Pm.Plan.BarrierKind' → 屏障实现。对构造子做 **total** 模式匹配：内核那半
-- （「要不要屏障」）与这半（「是哪个」）由同一个类型钉死，新加一种屏障漏写
-- 这里直接编译不过（三十轮 F4 的类型封闭；此前是两张表靠一条测试钉一致）。
--
-- 返回**降级清单** @[(piIx, 原因)]@，新计划由内核构造（'Pm.Exec.applyDemotions'）
-- ——屏障在类型上就写不出「升级/改写 Op/改写元数据」。
runBarrier :: Config -> BarrierKind -> Plan -> IO [(Int, T.Text)]
runBarrier cfg BarrierClean = recheckCleanPlan cfg
runBarrier cfg BarrierDedupe = recheckDedupePlan cfg

-- | 存盘 → 展示 → 确认 → 执行。执行期屏障由 'executePlanNowWith' 装进
-- ExecEnv、由内核在锁内跑，这里既不必也不能选择跳过它。
--
-- 二十九轮之前这里还有一个 @savePlanAndMaybeRunWith@ 收 @preExec@ 钩子的变体，
-- 现已删除：屏障装配点收成一处之后，"传哪个钩子"不再是调用方的决定。
savePlanAndMaybeRun :: Config -> GoOpts -> Plan -> IO Int
savePlanAndMaybeRun cfg go plan = do
  -- P3b-7 复审新 major：savePlan 写 <root>/.pm/plans/，是 .pm 写入口——root
  -- 须有可解析身份且过 I11，否则不落盘。
  w <- requireWritable (plRootPath plan)
  case w of
    Left m -> putStrLn ("计划未保存（root 不可写）: " <> m) >> pure 2
    Right _ -> do
      fp <- savePlan plan
      renderPlanBrief plan
      putStrLn ("计划已存 " <> fp)
      putStrLn ("执行: pm apply " <> T.unpack (plId plan))
      ok <- confirm go
      if ok
        then executePlanNow cfg plan
        else pure 1

-- | 执行后的 catalog 回写是一次「读 → 并 → 写」——execPlan 已释放锁，两次
-- 先后完成的 apply 若都在锁外回写，后写者会基于旧快照整份覆盖先写者的更新
-- （三十轮 F2）。回写因此自己取锁做完整 RMW；取不到锁就明说并放弃——catalog
-- 是可由 pm scan 重建的缓存，滞后可以接受，静默丢更新不可以。
writeBackCatalog :: (String -> IO ()) -> FilePath -> [(PlanItem, ItemOutcome)] -> IO ()
writeBackCatalog sink root results = do
  m <- withRootLock root $ do
    (mcat, _) <- loadCatalog root
    case mcat of
      Nothing -> sink "（root 尚无索引，跳过 catalog 回写；之后 pm scan 会补齐）"
      Just cat -> do
        now <- getCurrentTime
        saveCatalog root (updateCatalog now results cat)
  case m of
    Nothing -> sink "⚠ catalog 回写未完成（另一个 pm 实例正持有该 root 的锁）——索引暂时滞后，pm scan 会补齐"
    Just () -> pure ()

-- | 评审 cx-1：执行 root 由 UUID 重新发现并绑定，绝不信计划里存的盘符路径
-- （备份盘可能换盘符重挂，旧盘符可能已属于别的卷）。
-- P2.3（复审三轮新发现）：绑定按**身份**而非计划 kind——doctor 在备份 root
-- 上生成的 C5 修复计划 kind 是 doctor-c5-quarantine，按 kind 分支会把它错绑
-- 到主库（fail-closed 会拒绝，但计划就永远执行不了）。
-- P3b-4 评审 #6：三个槽位（主库\/vault\/备份）**全部**探查，候选 = UUID
-- 命中且 role 与槽位相符；必须**恰好一个**命中——多命中（同一标识被整盘
-- 复制\/恢复到第二个 root）是身份危机，拒绝执行而不是按优先级猜。
bindExecRoot :: Config -> Plan -> T.Text -> IO (Either String Plan)
bindExecRoot cfg plan rid = do
  let mroot = cfgMainPath cfg
  mMain <- fmap ((,) mroot) <$> readRootInfo mroot
  mVault <- case cfgVaultPath cfg of
    Nothing -> pure Nothing
    Just vp -> fmap ((,) vp) <$> readRootInfo vp
  -- P3b-5 复审 #6：备份槽取**全部**命中（整盘克隆的两块盘都进候选集）；
  -- 候选去重按 canonicalizePath 的真实文件系统身份（解析 junction/大小写），
  -- 不再无条件字符串小写化。
  eBack <- discoverBackupRoots cfg
  backHits <- case eBack of
    Left _ -> pure []
    Right (_, ps) -> forM ps $ \bp -> fmap ((,) bp) <$> readRootInfo bp
  let hit role m = [p | Just (p, i) <- [m], riId i == rid, riRole i == role]
      cands0 =
        [(p, "主库" :: String) | p <- hit RoleMain mMain]
          <> [(p, "vault") | p <- hit RoleVault mVault]
          <> [(p, "备份盘") | m <- backHits, p <- hit RoleBackup m]
  canon <- forM cands0 $ \(p, l) -> (\c -> (c, (p, l))) <$> canonicalizePath p
  let uniq = map snd (nubBy ((==) `on` fst) canon)
  case uniq of
    [(p, label)] -> do
      when (p /= plRootPath plan) $
        putStrLn ("· " <> label <> " root 按 UUID 重新绑定: " <> plRootPath plan <> " → " <> p)
      pure (Right plan {plRootPath = p})
    [] ->
      pure . Left $
        "计划 rootId 与主库、vault、备份盘均不符（" <> T.unpack rid <> "），拒绝执行"
          <> either (\m -> "；备份盘发现: " <> m) (const "") eBack
    many ->
      pure . Left $
        "UUID " <> T.unpack rid <> " 同时命中多个 root（"
          <> intercalate "、" [l <> " " <> p | (p, l) <- many]
          <> "），root 身份冲突（同一标识被复制/恢复到多个位置），拒绝执行——先修正 root-id.json 再重试"

-- | 评审 cx-3：clean 计划在**每次执行前**逐项重验三副本（当前 catalog 定位
-- 见证 + 真实重 hash），不过的降级 NEEDS-DECISION——计划生成与执行之间的
-- 世界会变。P2.2 起没有豁免路径：`pm apply` 与 `pm clean staging --apply`
-- 即时执行都走这里（旁路封堵）。
recheckCleanPlan :: Config -> Plan -> IO [(Int, T.Text)]
recheckCleanPlan cfg plan = do
  let mroot = cfgMainPath cfg
  -- P3b-7 复审 B1：主库见证必须来自 RoleMain root——配置主路径若与备份 root
  -- 是同一块 RoleBackup 盘，同一文件会被当成「归档副本 + 备份副本」两份见证。
  emain <- requireMain cfg
  (mMain, _) <- loadCatalog mroot
  er <- discoverBackupRoot cfg
  case (emain, mMain, er) of
    (Left m, _, _) -> demoteAllPending "复验三副本" plan ("主库身份不符: " <> m)
    (_, Just mainCat, Right broot) -> do
      (mBak, _) <- loadCatalog broot
      case mBak of
        Nothing -> demoteAllPending "复验三副本" plan "备份盘无索引 → 先 pm backup"
        Just bakCat -> recheckCleanItems mroot mainCat broot bakCat plan
    (_, Nothing, _) -> demoteAllPending "复验三副本" plan "主库无索引"
    (_, _, Left msg) -> demoteAllPending "复验三副本" plan ("备份盘不在线: " <> msg)

-- | 可测核心：给定已解析的两侧 root+catalog，逐项重验，返回**降级清单**。
recheckCleanItems :: FilePath -> Catalog -> FilePath -> Catalog -> Plan -> IO [(Int, T.Text)]
recheckCleanItems mroot mainCat broot bakCat plan = do
  dems <- forM (plItems plan) $ \it -> case (piStatus it, piOp it) of
    (StPending, OpQuarantine v sha _) -> do
      -- 将被移走的就是 victim 本身：见证与它同身份不算另一份副本
      -- （codex 二十八轮 #2）。读不到它的身份就没法做这个判断 → 判不过
      -- （fail-closed；victim 读不到时这一项本来也执行不了）。
      pv <- probeConfined mroot v
      ok <- case pv of
        CpSha _ vid -> threeCopiesStillExist mroot mainCat broot bakCat [vid] sha
        _ -> pure False
      if ok
        then pure []
        else do
          putStrLn ("  ⚠ 执行期三副本复验不过，该项暂停: " <> v)
          pure [(piIx it, "执行期三副本复验不过 → pm scan / pm backup 后重新生成清理计划")]
    _ -> pure []
  pure (concat dems)

-- | 复验**条件本身**不可得（主库身份不符、无索引、备份盘不在线…）时，降级
-- 全部待执行项。fail-closed：拿不到证据就不执行，而不是按生成时的判断继续。
-- clean 与 dedupe 共用——两者对"证据取不到"的处置必须一致。
demoteAllPending :: String -> Plan -> String -> IO [(Int, T.Text)]
demoteAllPending what plan why = do
  putStrLn ("⚠ 无法" <> what <> "（" <> why <> "），全部待执行项暂停")
  pure
    [ (piIx it, T.pack ("执行期无法" <> what <> ": " <> why))
    | it <- plItems plan
    , piStatus it == StPending
    ]

-- | @dedupe@ 计划的执行期屏障（'Pm.Dedupe.recheckDedupeItems'）：批准隔离的
-- 条目不得把某个 sha 在归档层的**最后一份活副本**也隔离掉。
--
-- 主库身份先验、**再**读 catalog（P3b-8 复审 B1 的次序纪律：任何主库侧读取
-- 都在身份闸之后）。与 clean 不同，这里不需要备份盘——dedupe 的保证是"归档层
-- 还留着一份"，与第三副本无关，所以一块没插的盘不该拖住它。
recheckDedupePlan :: Config -> Plan -> IO [(Int, T.Text)]
recheckDedupePlan cfg plan = do
  emain <- requireMain cfg
  case emain of
    Left m -> demoteAllPending "复验归档层余量" plan ("主库身份不符: " <> m)
    Right _ -> do
      (mcat, _) <- loadCatalog (cfgMainPath cfg)
      case mcat of
        Nothing -> demoteAllPending "复验归档层余量" plan "主库无索引"
        Just cat -> recheckDedupeItems (cfgMainPath cfg) cat plan

-- | --only 选择展开为复合组闭包（评审 cx-2：supersede 配对不可拆）。
-- Left = 语法错误；Right (plan', 因组闭包追加的序号)。
applyOnlyToPlan :: Maybe String -> Plan -> Either String (Plan, [Int])
applyOnlyToPlan Nothing plan = Right (plan, [])
applyOnlyToPlan (Just spec) plan = case parseOnly spec of
  Nothing -> Left ("--only 语法错误: " <> spec)
  Just sel ->
    let closed = groupClosure plan sel
        added = [ix | ix <- closed, ix `notElem` sel]
        plan' =
          plan
            { plItems =
                [ if piIx it `elem` closed then it else it {piStatus = StSkippedByUser}
                | it <- plItems plan
                ]
            }
     in Right (plan', added)

-- "1,3-5" → [1,3,4,5]
parseOnly :: String -> Maybe [Int]
parseOnly spec = concat <$> mapM part (splitOn ',' spec)
 where
  part s = case break (== '-') s of
    (a, '-' : b) -> do
      x <- readMaybe a
      y <- readMaybe b
      if x <= y then Just [x .. y] else Nothing
    (a, "") -> (: []) <$> readMaybe a
    _ -> Nothing
  splitOn c = foldr step [[]]
   where
    step ch acc@(cur : rest)
      | ch == c = [] : acc
      | otherwise = (ch : cur) : rest
    step _ [] = [[]]

-- | 暂存区新鲜度守卫：计划按 catalog 生成，catalog 落后于盘面就先扫描 ——
-- 不让计划遗漏新文件或引用旧内容（执行层还有 §6.7 前提复核兜底）。
-- 实现共享 'freshnessSweep'（pm status 用同一函数做全库核对）。
stagingFresh :: FilePath -> Catalog -> IO (Either String ())
stagingFresh root cat = do
  let catStaging =
        Map.filterWithKey
          (\k _ -> take 1 (splitDirectories k) == [stagingTop])
          (catEntries cat)
  (newN, changedN, goneN, errN) <- freshnessSweep root stagingTop catStaging
  pure $
    if newN + changedN + goneN + errN == 0
      then Right ()
      else
        Left
          ( printf
              "暂存区与索引不一致（新增 %d / 变更 %d / 消失 %d / 读取错误 %d）→ 先 pm scan"
              newN
              changedN
              goneN
              errN
          )

-- | 「先拿到一份**可信的**暂存区索引，再做任何目标位置判定」这道闸：
-- 报告损坏快照 → 无索引则拒绝 → 索引与盘面不一致则拒绝。
--
-- 只有一份定义，因为 @pm import@ / @pm clean staging@ / @pm sort@ 面对的是同
-- 一个暂存区，都要回答同一个问题：「目标位置上现在有没有东西、是不是同一份
-- 内容」。判据分成三份，迟早会一处收紧、别处留旧，对同一批文件给出不同结论。
--
-- 「无索引」必须是**拒绝**而不是"当作目标为空"：后者是默认覆盖的方向，
-- 与 I5（不静默覆盖）恰好相反。
-- | 同上，但把失败**交回调用方**而不是自己打印后返回 2。
--
-- @pm sort@ 需要这一层：它在这里失败时，已经选中的照片一个都不会被搬走，
-- 而调用方必须把它们逐条列出来（codex 二十八轮 #4）。自己打印就等于替调用方
-- 决定了"说这么多就够了"。
freshStagingCatalog :: FilePath -> IO (Either String Catalog)
freshStagingCatalog root = do
  (mcat, warns) <- loadCatalog root
  mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
  case mcat of
    Nothing -> pure (Left "主库尚未索引 → 先 pm scan")
    Just cat -> do
      fr <- stagingFresh root cat
      pure (either Left (const (Right cat)) fr)

withFreshStagingCatalog :: FilePath -> (Catalog -> IO Int) -> IO Int
withFreshStagingCatalog root k = do
  (mcat, warns) <- loadCatalog root
  mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
  case mcat of
    Nothing -> putStrLn "主库尚未索引 → 先 pm scan" >> pure 2
    Just cat -> do
      fr <- stagingFresh root cat
      case fr of
        Left msg -> putStrLn msg >> pure 2
        Right () -> k cat

reportScanIssues :: ScanResult -> IO ()
reportScanIssues result = do
  unless (null (srVolatile result)) $ do
    printf "⚠ %d 个文件在 hash 期间被修改（本轮未入索引，重跑 pm scan）:\n" (length (srVolatile result))
    mapM_ (putStrLn . ("    ~ " <>)) (take 10 (srVolatile result))
  unless (null (srErrors result)) $ do
    printf "⚠ %d 个条目有错误:\n" (length (srErrors result))
    mapM_ (\(p, e) -> putStrLn ("    ! " <> p <> ": " <> e)) (take 20 (srErrors result))
    when (length (srErrors result) > 20) $
      printf "    …另有 %d 条\n" (length (srErrors result) - 20)

refreshBackupCache :: Config -> FilePath -> Catalog -> BackupDiff -> IO ()
refreshBackupCache cfg broot bakCat d = do
  now <- getCurrentTime
  fs <- case broot of
    (c : _) -> volumeFsType c
    _ -> pure Nothing
  -- 缓存写被拒（目录不可信）时**没有发生任何写**，库外文件安全；照片本身
  -- 已经落盘完毕。因此这里报警而不把一次成功的备份判成失败——与 vault status
  -- 不同：那条命令是只读比对，缓存就是它的输出基线，失败即硬停（P3b-13）。
  wc <- writeBackupCache
    (cfgMainPath cfg)
    bakCat
    BackupCacheMeta
      { bmAt = now
      , bmPath = broot
      , bmFsType = fs
      , bmAdd = length (bdAdd d)
      , bmUpdate = length (bdUpdate d)
      , bmExtra = length (bdExtra d)
      }
  case wc of
    CacheWritten -> pure ()
    CacheLockBusy -> putStrLn "⚠ 备份缓存本轮未刷新（另一个 pm 正持有主库锁）——下一次命令会重建"
    CacheRefused e -> putStrLn ("⚠ 备份缓存未写入: " <> e)
