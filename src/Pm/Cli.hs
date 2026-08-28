{-# LANGUAGE OverloadedStrings #-}

-- | Shared CLI plumbing for the command layer (split out of app\/Main.hs):
-- the one true plan-execution path, root-identity binding (评审 cx-1)、
-- clean 计划的执行期三副本复验（评审 cx-3）、--only 的组闭包展开
-- （评审 cx-2）。GUI\/serve (P4) 将复用同一路径。
module Pm.Cli
  ( GoOpts (..)
  , confirm
  , renderPlanBrief
  , renderPlanBriefTo
  , executePlanNow
  , executePlanNowWith
  , PlanRun (..)
  , planRunCode
  , planIdOf
  , fullyExecuted
  , landedItems
  , savePlanAndMaybeRun
  , savePlanAndMaybeRun'
  , savePlanAndMaybeRunTo
  , emitPlanTo
  , bindExecRoot
  , bindExecRootWith
  , runBarrier
  , writeBackCatalog
  , recheckCleanPlan
  , recheckCleanItems
  , recheckDedupePlan
  , applyOnlyToPlan
  , parseOnly
  , stagingFresh
  , mainFresh
  , withFreshStagingCatalog
  , freshStagingCatalog
  , reportScanIssues
  , refreshBackupCache
  ) where

import Control.Exception (IOException, try)
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
import Pm.Catalog (CatalogLoad (..), catalogOr, loadCatalog, loadNote, saveCatalog)
import Pm.Clean (threeCopiesStillExist)
import Pm.Hash (ContentProbe (..), probeConfined)
import Pm.Config (Config (..), RootIdState (..), SideCacheWrite (..), readRootState, requireMain, requireWritable)
import Pm.Dedupe (recheckDedupeItems)
import Pm.Diff (BackupDiff (..))
import Pm.Exec (ExecEnv (..), ItemOutcome (..), defaultExecEnv, execPlan, outcomeLabel, updateCatalog)
import Pm.Import (stagingTop)
import Pm.Journal (Sync (..))
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Scan (ScanResult (..), freshPending, freshnessSweep)
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
      -- 第一方自审工作流 F020：stdin 关闭（EOF）或答案不可解码一律按「否」
      -- ——同 'Pm.ServeGuard.waitStdinEof' 的 try 纪律。裸 getLine 让异常逃到
      -- RTS：计划已存、字节未动，却在两段式确认口打出一串堆栈，且
      -- 'Pm.Ingest' 对「答了 n」的次序提示（I7）永远打不出来。
      r <- try getLine :: IO (Either IOException String)
      pure (either (const False) (\l -> map toLower l `elem` ["y", "yes"]) r)

-- | 大计划只展示头部，完整清单在计划文件里（pm apply --dry 可全量打印）。
renderPlanBrief :: Plan -> IO ()
renderPlanBrief = renderPlanBriefTo putStrLn

-- | 同上，打印口由调用方给（工作流 F051 的 sink 纪律，见 'executePlanNowWith'）。
renderPlanBriefTo :: (String -> IO ()) -> Plan -> IO ()
renderPlanBriefTo sink plan = do
  let ls = renderPlan plan
      cap = 32
  if length ls <= cap + 1
    then mapM_ sink ls
    else do
      mapM_ sink (take (cap + 1) ls)
      sink (printf "  …另有 %d 项（pm apply --dry %s 查看全量）" (length ls - cap - 1) (T.unpack (plId plan)))

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
            eeBarrier = Just (runBarrier cfg sink)
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
-- （「要不要屏障」）与这半（「是哪个」）由同一个类型钉死。新加一种屏障漏写
-- 这里 = @-Wall@ 的 incomplete-patterns 警告（本项目纪律 warnings 0，非
-- @-Werror@ 硬失败——三十二轮更正此前「直接编译不过」的过强措辞）；真漏进
-- 运行期则在锁内、journal 之前 PatternMatchFail 硬崩，不会静默放行。构造子
-- 与实现的**对应关系**由 DedupeTests 的 casePreExecRow 按降级理由区分钉住。
--
-- 返回**降级清单** @[(piIx, 原因)]@，新计划由内核构造（'Pm.Exec.applyDemotions'）
-- ——屏障在类型上就写不出「升级/改写 Op/改写元数据」。
runBarrier :: Config -> (String -> IO ()) -> BarrierKind -> Plan -> IO [(Int, T.Text)]
runBarrier cfg sink BarrierClean = recheckCleanPlan cfg sink
runBarrier cfg sink BarrierDedupe = recheckDedupePlan cfg sink

-- | 'savePlanAndMaybeRun' 的可判别结局（三十二轮 R4/R5 的根因修法）。此前
-- 调用方只拿到一个 Int，而 1 同时表示「计划已存盘未执行（预览/用户答 n）」与
-- 「执行过但有 CONFLICT\/FAILED」，0 也不区分「全部真执行完」与「有
-- NEEDS-DECISION 项根本没执行（ONotExecuted 不计入退出码）」——ingest 这类
-- 要按「上一份**真的全部落完**」才继续的调用方在 Int 上做不出这个判断。
data PlanRun
  = PrRefused String
    -- ^ root 不可写，计划**未**保存（消息已打印）
  | PrSaved
    -- ^ 计划已存盘、未执行（无 --apply，或用户在 y/N 答了 n）
  | PrRun Int [(PlanItem, ItemOutcome)]
    -- ^ 已执行：退出码 + 逐项结局

-- | 存盘 → 展示 → 确认 → 执行。执行期屏障由 'executePlanNowWith' 装进
-- ExecEnv、由内核在锁内跑，这里既不必也不能选择跳过它。
--
-- 二十九轮之前这里还有一个 @savePlanAndMaybeRunWith@ 收 @preExec@ 钩子的变体，
-- 现已删除：屏障装配点收成一处之后，"传哪个钩子"不再是调用方的决定。
savePlanAndMaybeRun :: Config -> GoOpts -> Plan -> IO Int
savePlanAndMaybeRun cfg go plan = planRunCode <$> savePlanAndMaybeRun' cfg go plan

-- | 与旧 Int 契约的换算（行为逐位保持：不可写=2、存而未执=1、执行=其退出码）。
planRunCode :: PlanRun -> Int
planRunCode (PrRefused _) = 2
planRunCode PrSaved = 1
planRunCode (PrRun c _) = c

-- | 「计划 id 只在真出了计划时是 Just」（第一方自审工作流 F052）：'PrRefused'
-- 在 savePlan **之前**返回，盘上没有文件——给出 id 就是指向一个不存在的计划
-- （GUI 会照着它显示「pm apply <id>」）。存而未执（PrSaved）盘上有文件，id 照给。
planIdOf :: PlanRun -> T.Text -> Maybe T.Text
planIdOf (PrRefused _) _ = Nothing
planIdOf _ pid = Just pid

-- | 「真的全部落完」：每一项都是 DONE 或同内容 SKIP（三十二轮 R4 的判据本体，
-- 工作流 F029/F068 自 Pm.Ingest 上提到这里——ingest 的 I7 次序闸与 push/apply
-- 的收尾都要按**逐项结果**而不是退出码判断，定义只能有一份）。ONotExecuted
-- （待裁决/用户 skip）不计入退出码，@c == 0@ 不等于它。
fullyExecuted :: [(PlanItem, ItemOutcome)] -> Bool
fullyExecuted rs = not (null rs) && all (landed . snd) rs

-- | 真正落位的项（DONE / 同内容 SKIP）。收尾脚注（git 步骤）与 @git add@ 的
-- 对象集合从这里出，不从计划面出：待裁决/未选中的项不会让 vault 多出一个
-- 文件，却会让计划面的类目进 add 清单、让一次「零字节落位」的执行打出一份
-- 可粘贴的 commit 配方（工作流 F029/F068）。比 'fullyExecuted' 弱：一个 NEW
-- 落了、一个 DRIFT 待裁决的混合计划**需要**收尾。
landedItems :: [(PlanItem, ItemOutcome)] -> [PlanItem]
landedItems rs = [it | (it, out) <- rs, landed out]

landed :: ItemOutcome -> Bool
landed ODone {} = True
landed OSkippedIdentical = True
landed _ = False

savePlanAndMaybeRun' :: Config -> GoOpts -> Plan -> IO PlanRun
savePlanAndMaybeRun' = savePlanAndMaybeRunTo putStrLn

-- | 同上，打印口由调用方给（工作流 F051/F078：`pm ui` 下 serve 的 stdout 是
-- 空设备，端点把这些行收进 JSON 响应体；CLI 传 putStrLn，逐字不变）。交互
-- 确认 'confirm' 仍走真实终端——serve 传 @GoOpts False False@，走不到它。
savePlanAndMaybeRunTo :: (String -> IO ()) -> Config -> GoOpts -> Plan -> IO PlanRun
savePlanAndMaybeRunTo sink cfg go plan = do
  -- P3b-7 复审新 major：savePlan 写 <root>/.pm/plans/，是 .pm 写入口——root
  -- 须有可解析身份且过 I11，否则不落盘。
  w <- requireWritable (plRootPath plan)
  case w of
    Left m -> sink ("计划未保存（root 不可写）: " <> m) >> pure (PrRefused m)
    Right _ -> do
      fp <- savePlan plan
      renderPlanBriefTo sink plan
      sink ("计划已存 " <> fp)
      sink ("执行: pm apply " <> T.unpack (plId plan))
      ok <- confirm go
      if ok
        then uncurry PrRun <$> executePlanNowWith cfg sink plan
        else pure PrSaved

-- | 「造计划 → 存盘 → 展示 → 确认 → 执行 → (退出码, 计划 id)」的公共收尾。
-- P8-B 上提：sort 的 emit、import、album add 三处此前各抄一份同形的尾巴
-- （新 id、取时、构造 Plan、savePlanAndMaybeRunTo、planRunCode/planIdOf）。
-- id 只在计划真的落了盘时给（工作流 F052：'PrRefused' 在 savePlan 之前返回）。
emitPlanTo :: (String -> IO ()) -> Config -> GoOpts -> T.Text -> FilePath -> RootInfo -> [PlanItem] -> IO (Int, Maybe T.Text)
emitPlanTo sink cfg go kind root info items = do
  pid <- newPlanId
  now <- getCurrentTime
  pr <- savePlanAndMaybeRunTo sink cfg go (Plan pid kind root (Just (riId info)) now items)
  pure (planRunCode pr, planIdOf pr pid)

-- | 执行后的 catalog 回写是一次「读 → 并 → 写」——execPlan 已释放锁，两次
-- 先后完成的 apply 若都在锁外回写，后写者会基于旧快照整份覆盖先写者的更新
-- （三十轮 F2）。回写因此自己取锁做完整 RMW；取不到锁就明说并放弃——catalog
-- 是可由 pm scan 重建的缓存，滞后可以接受，静默丢更新不可以。
writeBackCatalog :: (String -> IO ()) -> FilePath -> [(PlanItem, ItemOutcome)] -> IO ()
writeBackCatalog sink root results = do
  m <- withRootLock root $ do
    lc <- loadCatalog root
    case lc of
      CatAbsent -> sink "（root 尚无索引，跳过 catalog 回写；之后 pm scan 会补齐）"
      -- 工作流 F021：被拒的快照不是「尚无索引」——root 有索引，是 pm 拒绝了它
      CatRefused ws -> sink ("⚠ 快照未能载入（" <> intercalate "；" ws <> "），catalog 回写跳过——先 pm scan 重建")
      CatLoaded cat _ -> do
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
bindExecRoot = bindExecRootWith putStrLn

-- | 同上，重绑定提示走调用方给的打印口（工作流 F022 同族：serve 端点收进 log）。
bindExecRootWith :: (String -> IO ()) -> Config -> Plan -> T.Text -> IO (Either String Plan)
bindExecRootWith sink cfg plan rid = do
  let mroot = cfgMainPath cfg
  -- 第一方自审工作流 F018：每个槽位读**四态**（'readRootState'），不经
  -- 'readRootInfo' 的 Maybe——那会把「身份读不出/损坏/缺席」都塌成「不命中」，
  -- 零候选时报文「均不符」宣称一次从未发生的 UUID 比对。非 Present 的槽位
  -- 保留原因，零候选时如实列出；拒绝与退出码不变（动作本就 fail-closed）。
  stMain <- readRootState mroot
  stVault <- traverse readRootState (cfgVaultPath cfg)
  -- P3b-5 复审 #6：备份槽取**全部**命中（整盘克隆的两块盘都进候选集）；
  -- 候选去重按 canonicalizePath 的真实文件系统身份（解析 junction/大小写），
  -- 不再无条件字符串小写化。
  eBack <- discoverBackupRoots cfg
  backSts <- case eBack of
    Left _ -> pure []
    Right (_, ps) -> forM ps $ \bp -> (,) bp <$> readRootState bp
  let slots =
        [(mroot, "主库" :: String, RoleMain, stMain)]
          <> [(vp, "vault", RoleVault, st) | (Just vp, Just st) <- [(cfgVaultPath cfg, stVault)]]
          <> [(bp, "备份盘", RoleBackup, st) | (bp, st) <- backSts]
      cands0 = [(p, l) | (p, l, role, RootPresent i) <- slots, riId i == rid, riRole i == role]
      unreadable = [l <> " " <> p <> " 身份" <> why st | (p, l, _, st) <- slots, not (isPresent st)]
      isPresent RootPresent {} = True
      isPresent _ = False
      why RootAbsent = "缺席（尚未 init）"
      why (RootCorrupt m) = "损坏: " <> m
      why (RootUntrusted m) = "读不出: " <> m
      why RootPresent {} = ""
  canon <- forM cands0 $ \(p, l) -> (\c -> (c, (p, l))) <$> canonicalizePath p
  let uniq = map snd (nubBy ((==) `on` fst) canon)
  case uniq of
    [(p, label)] -> do
      when (p /= plRootPath plan) $
        sink ("· " <> label <> " root 按 UUID 重新绑定: " <> plRootPath plan <> " → " <> p)
      pure (Right plan {plRootPath = p})
    [] ->
      pure . Left $
        ( if null unreadable
            then "计划 rootId 与主库、vault、备份盘均不符（" <> T.unpack rid <> "），拒绝执行"
            else
              "计划 rootId 与可读身份的 root 均不符（" <> T.unpack rid <> "）；"
                <> intercalate "；" unreadable
                <> "，拒绝执行"
        )
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
recheckCleanPlan :: Config -> (String -> IO ()) -> Plan -> IO [(Int, T.Text)]
recheckCleanPlan cfg sink plan = do
  let mroot = cfgMainPath cfg
  -- P3b-7 复审 B1：主库见证必须来自 RoleMain root——配置主路径若与备份 root
  -- 是同一块 RoleBackup 盘，同一文件会被当成「归档副本 + 备份副本」两份见证。
  emain <- requireMain cfg
  lm <- loadCatalog mroot
  er <- discoverBackupRoot cfg
  case (emain, lm, er) of
    (Left m, _, _) -> demoteAllPending sink "复验三副本" plan ("主库身份不符: " <> m)
    (_, CatLoaded mainCat _, Right broot) -> do
      lb <- loadCatalog broot
      case lb of
        CatLoaded bakCat _ -> recheckCleanItems sink mroot mainCat broot bakCat plan
        other -> demoteAllPending sink "复验三副本" plan ("备份盘" <> loadNote other <> " → 先 pm backup")
    (_, CatLoaded _ _, Left msg) -> demoteAllPending sink "复验三副本" plan ("备份盘不在线: " <> msg)
    -- 缺席与读不出都降级，但理由各说各的（工作流 A 簇：查不出 ≠ 不存在）
    (_, other, _) -> demoteAllPending sink "复验三副本" plan ("主库" <> loadNote other)

-- | 可测核心：给定已解析的两侧 root+catalog，逐项重验，返回**降级清单**。
recheckCleanItems :: (String -> IO ()) -> FilePath -> Catalog -> FilePath -> Catalog -> Plan -> IO [(Int, T.Text)]
recheckCleanItems sink mroot mainCat broot bakCat plan = do
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
          sink ("  ⚠ 执行期三副本复验不过，该项暂停: " <> v)
          pure [(piIx it, "执行期三副本复验不过 → pm scan / pm backup 后重新生成清理计划")]
    _ -> pure []
  pure (concat dems)

-- | 复验**条件本身**不可得（主库身份不符、无索引、备份盘不在线…）时，降级
-- 全部待执行项。fail-closed：拿不到证据就不执行，而不是按生成时的判断继续。
-- clean 与 dedupe 共用——两者对"证据取不到"的处置必须一致。
demoteAllPending :: (String -> IO ()) -> String -> Plan -> String -> IO [(Int, T.Text)]
demoteAllPending sink what plan why = do
  sink ("⚠ 无法" <> what <> "（" <> why <> "），全部待执行项暂停")
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
recheckDedupePlan :: Config -> (String -> IO ()) -> Plan -> IO [(Int, T.Text)]
recheckDedupePlan cfg sink plan = do
  emain <- requireMain cfg
  case emain of
    Left m -> demoteAllPending sink "复验归档层余量" plan ("主库身份不符: " <> m)
    Right _ -> do
      lc <- loadCatalog (cfgMainPath cfg)
      case lc of
        CatLoaded cat _ -> recheckDedupeItems sink (cfgMainPath cfg) cat plan
        other -> demoteAllPending sink "复验归档层余量" plan ("主库" <> loadNote other)

-- | --only 选择展开为复合组闭包（评审 cx-2：supersede 配对不可拆）。
-- Left = 语法错误；Right (plan', 因组闭包追加的序号)。
applyOnlyToPlan :: Maybe String -> Plan -> Either String (Plan, [Int])
applyOnlyToPlan Nothing plan = Right (plan, [])
applyOnlyToPlan (Just spec) plan = case parseOnly maxIx spec of
  Nothing -> Left ("--only 语法错误或序号超出计划范围（0-" <> show maxIx <> "）: " <> spec)
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
 where
  maxIx = maximum (0 : map piIx (plItems plan))

-- "1,3-5" → [1,3,4,5]。第一方自审工作流 F019：端点先与计划的序号域比对
-- （0..maxIx，同 'Pm.Exec.applyDemotions' 对不存在序号的整批拒绝），再展开
-- ——此前 @--only 1-9000000000@ 立刻解析成功、交给下游一个 9e9 元素的惰性
-- 列表，groupClosure 的 elem/nub 在任何盘面动作之前就把进程挂死（--dry 也挂）。
parseOnly :: Int -> String -> Maybe [Int]
parseOnly maxIx spec = concat <$> mapM part (splitOn ',' spec)
 where
  ok i = i >= 0 && i <= maxIx
  part s = case break (== '-') s of
    (a, '-' : b) -> do
      x <- readMaybe a
      y <- readMaybe b
      if x <= y && ok x && ok y then Just [x .. y] else Nothing
    (a, "") -> do
      i <- readMaybe a
      if ok i then Just [i] else Nothing
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
  q@(newN, changedN, goneN, errN) <- freshnessSweep root stagingTop catStaging
  pure $
    if freshPending q == 0
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

-- | 主库整体新鲜度守卫（工作流 F057）：@pm backup@ 的 diff 以主库快照为基准，
-- 快照落后于盘面就是在替一个没看过的库担保「备份盘已与主库一致」。同一实现
-- （'freshnessSweep' 的全库形态，pm status 也用它；stat 级，不 hash）。
mainFresh :: FilePath -> Catalog -> IO (Either String ())
mainFresh root cat = do
  q@(newN, changedN, goneN, errN) <- freshnessSweep root "" (catEntries cat)
  pure $
    if freshPending q == 0
      then Right ()
      else Left (printf "主库与索引不一致（新增 %d / 变更 %d / 消失 %d / 读取错误 %d）→ 先 pm scan" newN changedN goneN errN)

-- | 「先拿到一份**可信的**暂存区索引，再做任何目标位置判定」这道闸：
-- 报告损坏快照 → 无索引则拒绝 → 索引与盘面不一致则拒绝。
--
-- 只有一份定义（'freshStagingCatalog' 是判定本体，本函数只是"打印后退出码 2"
-- 的包装——第一方自审工作流 F025 之前这里抄了第二份，三处文档还各指着不同
-- 的名字），因为 @pm import@ / @pm clean staging@ / @pm sort@ 面对的是同一个
-- 暂存区，都要回答同一个问题：「目标位置上现在有没有东西、是不是同一份
-- 内容」。判据分成几份，迟早会一处收紧、别处留旧，对同一批文件给出不同结论。
--
-- 「无索引」必须是**拒绝**而不是"当作目标为空"：后者是默认覆盖的方向，
-- 与 I5（不静默覆盖）恰好相反。
withFreshStagingCatalog :: FilePath -> (Catalog -> IO Int) -> IO Int
withFreshStagingCatalog root k =
  freshStagingCatalog putStrLn root >>= either (\m -> putStrLn m >> pure 2) k

-- | 判定本体：同上，但把失败**交回调用方**而不是自己打印后返回 2，且损坏
-- 快照的告警走调用方给的打印口。
--
-- @pm sort@ 需要这一层：它在这里失败时，已经选中的照片一个都不会被搬走，
-- 而调用方必须把它们逐条列出来（codex 二十八轮 #4）。自己打印就等于替调用方
-- 决定了"说这么多就够了"。
freshStagingCatalog :: (String -> IO ()) -> FilePath -> IO (Either String Catalog)
freshStagingCatalog sink root = do
  lc <- loadCatalog root
  case catalogOr "主库尚未索引 → 先 pm scan" lc of
    Left m -> pure (Left m)
    Right (cat, warns) -> do
      mapM_ (\w -> sink ("⚠ 快照损坏已跳过: " <> w)) warns
      fr <- stagingFresh root cat
      pure (either Left (const (Right cat)) fr)

reportScanIssues :: ScanResult -> IO ()
reportScanIssues result = do
  unless (null (srVolatile result)) $ do
    printf "⚠ %d 个文件在 hash 期间被修改（本轮未入索引，重跑 pm scan）:\n" (length (srVolatile result))
    mapM_ (putStrLn . ("    ~ " <>)) (take 10 (srVolatile result))
  when (srCarried result > 0) $
    printf "⚠ %d 条落在本轮未能枚举的子树里，按「查不出」保留上次快照值（未核对；解除占用/权限后重跑 pm scan）\n" (srCarried result)
  unless (null (srErrors result)) $ do
    printf "⚠ %d 个条目有错误:\n" (length (srErrors result))
    mapM_ (\(p, e) -> putStrLn ("    ! " <> p <> ": " <> e)) (take 20 (srErrors result))
    when (length (srErrors result) > 20) $
      printf "    …另有 %d 条\n" (length (srErrors result) - 20)

refreshBackupCache :: (String -> IO ()) -> Config -> FilePath -> Catalog -> BackupDiff -> IO ()
refreshBackupCache sink cfg broot bakCat d = do
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
    CacheLockBusy -> sink "⚠ 备份缓存本轮未刷新（另一个 pm 正持有主库锁）——下一次命令会重建"
    CacheRefused e -> sink ("⚠ 备份缓存未写入: " <> e)
