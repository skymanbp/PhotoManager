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
  , savePlanAndMaybeRun
  , savePlanAndMaybeRunWith
  , bindExecRoot
  , preExecFor
  , recheckCleanPlan
  , recheckCleanItems
  , recheckDedupePlan
  , applyOnlyToPlan
  , parseOnly
  , stagingFresh
  , withFreshStagingCatalog
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
import Pm.Config (Config (..), readRootInfo, requireMain, requireWritable)
import Pm.Dedupe (recheckDedupeItems)
import Pm.Diff (BackupDiff (..))
import Pm.Exec (ExecEnv (..), ItemOutcome (..), defaultExecEnv, execPlan, outcomeLabel, updateCatalog)
import Pm.Import (stagingTop)
import Pm.Journal (Sync (..))
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
executePlanNow :: Plan -> IO Int
executePlanNow plan = case plRootId plan of
  Nothing -> do
    putStrLn "计划缺 root 标识，拒绝执行（cx-1 fail-closed）→ pm init 建立 root 标识后重新生成计划"
    pure 2
  Just _ -> executePlanNow' plan

executePlanNow' :: Plan -> IO Int
executePlanNow' plan = do
  let root = plRootPath plan
      env =
        defaultExecEnv
          { eeDoneSync = if plKind plan == "backup" then Barrier else Buffered
          , eeExpectRootId = plRootId plan
          }
  r <- execPlan env plan
  case r of
    Left e -> putStrLn e >> pure 2
    Right results -> do
      forM_ results $ \(it, out) ->
        printf "  %3d → %s\n" (piIx it) (outcomeLabel out)
      (mcat, _) <- loadCatalog root
      case mcat of
        Nothing -> putStrLn "（root 尚无索引，跳过 catalog 回写；之后 pm scan 会补齐）"
        Just cat -> do
          now <- getCurrentTime
          saveCatalog root (updateCatalog now results cat)
      let bad = [() | (_, out) <- results, isBad out]
      unless (null bad) $
        printf "⚠ %d 项 CONFLICT/FAILED（其余不受影响；详见上方逐项结果）\n" (length bad)
      pure (if null bad then 0 else 1)
 where
  isBad (OConflict _) = True
  isBad (OFailed _) = True
  isBad _ = False

-- | 计划种类 → **执行期复验钩子**的唯一一张表。
--
-- 此前「clean 计划要重验三副本」这件事写在两处：'Pm.Commands.runApply' 里按
-- @plKind@ 分支一次，@runClean@ 把 'recheckCleanPlan' 传给
-- 'savePlanAndMaybeRunWith' 又一次。P2.2 封堵的正是其中一条路径漏掉复验的
-- 旁路——两处写同一件事，迟早会有一处忘记跟上。现在加一种需要执行期屏障的
-- 计划 = 在这张表里加一行，两条路径同时生效。
preExecFor :: Config -> T.Text -> (Plan -> IO Plan)
preExecFor cfg kind
  | kind == "clean-staging" = recheckCleanPlan cfg
  | kind == "dedupe" = recheckDedupePlan cfg
  | otherwise = pure

-- | 存盘 → 展示 → 确认 → （按种类复验）→ 执行。'preExecFor' 在这里自动生效，
-- 调用方不必也不能选择跳过它。
savePlanAndMaybeRun :: Config -> GoOpts -> Plan -> IO Int
savePlanAndMaybeRun cfg go plan =
  savePlanAndMaybeRunWith (preExecFor cfg (plKind plan)) go plan

-- | 同上，但确认后、执行前先过 @preExec@ 钩子（P2.2：`pm clean staging
-- --apply` 的即时路径也要走执行期三副本重验，复审 cx-3 旁路封堵）。
savePlanAndMaybeRunWith :: (Plan -> IO Plan) -> GoOpts -> Plan -> IO Int
savePlanAndMaybeRunWith preExec go plan = do
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
        then preExec plan >>= executePlanNow
        else pure 1

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
recheckCleanPlan :: Config -> Plan -> IO Plan
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

-- | 可测核心：给定已解析的两侧 root+catalog，逐项重验并降级。
recheckCleanItems :: FilePath -> Catalog -> FilePath -> Catalog -> Plan -> IO Plan
recheckCleanItems mroot mainCat broot bakCat plan = do
  items' <- forM (plItems plan) $ \it -> case (piStatus it, piOp it) of
    (StPending, OpQuarantine v sha _) -> do
      ok <- threeCopiesStillExist mroot mainCat broot bakCat sha
      if ok
        then pure it
        else do
          putStrLn ("  ⚠ 执行期三副本复验不过，该项暂停: " <> v)
          pure it {piStatus = StNeedsDecision "执行期三副本复验不过 → pm scan / pm backup 后重新生成清理计划"}
    _ -> pure it
  pure plan {plItems = items'}

-- | 复验**条件本身**不可得（主库身份不符、无索引、备份盘不在线…）时，把全部
-- 待执行项降级 NEEDS-DECISION。fail-closed：拿不到证据就不执行，而不是按生成
-- 时的判断继续。clean 与 dedupe 共用——两者对"证据取不到"的处置必须一致。
demoteAllPending :: String -> Plan -> String -> IO Plan
demoteAllPending what plan why = do
  putStrLn ("⚠ 无法" <> what <> "（" <> why <> "），全部待执行项暂停")
  pure
    plan
      { plItems =
          [ if piStatus it == StPending
              then it {piStatus = StNeedsDecision (T.pack ("执行期无法" <> what <> ": " <> why))}
              else it
          | it <- plItems plan
          ]
      }

-- | @dedupe@ 计划的执行期屏障（'Pm.Dedupe.recheckDedupeItems'）：批准隔离的
-- 条目不得把某个 sha 在归档层的**最后一份活副本**也隔离掉。
--
-- 主库身份先验、**再**读 catalog（P3b-8 复审 B1 的次序纪律：任何主库侧读取
-- 都在身份闸之后）。与 clean 不同，这里不需要备份盘——dedupe 的保证是"归档层
-- 还留着一份"，与第三副本无关，所以一块没插的盘不该拖住它。
recheckDedupePlan :: Config -> Plan -> IO Plan
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
  either (\e -> putStrLn ("\9888 备份缓存未写入: " <> e)) pure wc
