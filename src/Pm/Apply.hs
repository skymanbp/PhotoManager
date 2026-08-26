{-# LANGUAGE OverloadedStrings #-}

-- | undo \/ apply \/ resolve 命令族 + root 选择（'pickRoot'）——三十四轮从
-- Pm.Commands 拆出（原文件早已越过 750 行硬预算，本轮 resolve 的读口修改
-- 无处容身）。搬移为字节级；外部调用方（app\/Main、Pm.Serve）一律经
-- Pm.Commands 的再导出，行为零改动。
module Pm.Apply
  ( ApplyOpts (..)
  , ResolveOpts (..)
  , RootSel (..)
  , rootSel
  , pickRoot
  , runUndoCmd
  , loadPlanAnyRoot
  , prepareApply
  , runApply
  , afterApply
  , runResolve
  , resolveKeep
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Data.Char (toLower)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.FilePath (splitExtension, (</>))

import Pm.Backup (discoverBackupRoot)
import Pm.Catalog (loadCatalog)
import Pm.Cli
import Pm.Config
import Pm.Diff (backupDiff)
import Pm.Hash (sha256File)
import Pm.Op
import Pm.Plan
import Pm.Types
import Pm.Undo (buildUndoPlan)
import Pm.Vault (computeVault, gitStepsLines, planCategories)

data ApplyOpts = ApplyOpts
  { aoId :: T.Text
  , aoOnly :: Maybe String
  , aoDry :: Bool
  }

data ResolveOpts = ResolveOpts
  { roId :: T.Text
  , roItem :: Int
  , roSkip :: Bool -- True = skip, False = unskip（--keep 缺席时生效）
  , roKeep :: Maybe String -- src | dst | both
  }

-- | doctor\/trash\/undo 的作用 root：主库（默认）、备份盘（UUID 发现流程）
-- 或 vault（P3b：固定路径 + role 校验，root 由首次 vault push 建立）。
data RootSel = SelMain | SelBackup | SelVault
  deriving (Show, Eq)

rootSel :: Bool -> Bool -> Either String RootSel
rootSel True True = Left "--backup 与 --vault 只能二选一"
rootSel True False = Right SelBackup
rootSel False True = Right SelVault
rootSel False False = Right SelMain

pickRoot :: Config -> RootSel -> IO (Either (String, Int) FilePath)
pickRoot cfg SelMain = do
  -- P3b-6 复审 B1：doctor --repair / trash empty / undo 默认作用于主库，
  -- 配置路径指向备份/vault root 时不得放行（与 scan/import 同一 requireMain；
  -- P3b-7 起 requireRole 内含 I11 守卫，三个槽位一视同仁）。
  em <- requireMain cfg
  pure (either (\m -> Left (m, 2)) (const (Right (cfgMainPath cfg))) em)
pickRoot cfg SelBackup = do
  er <- discoverBackupRoot cfg
  case er of
    Left msg -> pure (Left (msg, 1))
    Right p -> do
      rr <- requireRole RoleBackup p
      pure (either (\m -> Left (m, 2)) (const (Right p)) rr)
pickRoot cfg SelVault = case cfgVaultPath cfg of
  Nothing -> pure (Left ("配置无 vault 路径 → pm init --main <主库> --vault <展示集路径>", 2))
  Just vp -> do
    st <- readRootState vp
    case st of
      RootAbsent -> pure (Left ("vault root 尚未建立（首次 pm vault push 时按 I11 创建）", 2))
      _ -> do
        rr <- requireRole RoleVault vp
        pure (either (\m -> Left (m, 2)) (const (Right vp)) rr)

-- ─── undo / apply / resolve ─────────────────────────────────────────────────

runUndoCmd :: Int -> RootSel -> Config -> IO Int
runUndoCmd n sel cfg = do
  eroot <- pickRoot cfg sel
  case eroot of
    Left (msg, code) -> putStrLn msg >> pure code
    Right root -> do
      r <- buildUndoPlan root n
      case r of
        Left e -> putStrLn e >> pure 2
        Right plan -> do
          fp <- savePlan plan
          mapM_ putStrLn (renderPlan plan)
          putStrLn ("计划已存 " <> fp)
          putStrLn ("执行: pm apply " <> T.unpack (plId plan))
          pure 0

-- | 计划可能存在主库、vault 或备份 root 的 .pm/plans 下；按此序查找。
loadPlanAnyRoot :: Config -> T.Text -> IO (Either String Plan)
loadPlanAnyRoot cfg pid = do
  r <- loadPlan (cfgMainPath cfg) pid
  case r of
    Right p -> pure (Right p)
    Left mainErr -> do
      rv <- case cfgVaultPath cfg of
        Nothing -> pure (Left mainErr)
        Just vp -> loadPlan vp pid
      case rv of
        Right p -> pure (Right p)
        Left _ -> do
          eb <- discoverBackupRoot cfg
          case eb of
            Left _ -> pure (Left mainErr)
            Right broot -> do
              rb <- loadPlan broot pid
              pure $ case rb of
                Right p -> Right p
                Left _ -> Left (mainErr <> "（vault/备份 root 也没有）")

-- | @pm apply@ 的**决定**部分：装载 → 按 UUID 重新绑定 root（评审 cx-1）→
-- @--only@ 展开到复合组闭包（评审 cx-2）。返回可执行的计划，以及因组闭包被
-- 追加进来的序号。
--
-- 抽出来是因为 CLI 与 @POST \/api\/apply@ 必须对「这个计划该怎么执行」给出
-- **同一个**答案。两处各写一遍 load\/bind\/only，就会有一处忘了按 UUID 绑
-- root、或忘了把组闭包补齐——前者会改错库，后者会把 supersede 拆成半个。
-- 执行期屏障不在这里：它随 Config 装进 ExecEnv，由内核在锁内跑
-- （'Pm.Cli.executePlanNowWith' → 'Pm.Exec.execBarrier'）。@--dry@ 因此天然
-- 不触发任何复验副作用——它根本不进 'Pm.Exec.execPlan'。
prepareApply :: Config -> T.Text -> Maybe String -> IO (Either String (Plan, [Int]))
prepareApply cfg pid only = do
  ep <- loadPlanAnyRoot cfg pid
  case ep of
    Left e -> pure (Left e)
    Right plan0 -> case plRootId plan0 of
      Nothing -> pure (Left "计划缺 root 标识（P2.1 之前的旧格式）→ 重新生成计划后再执行（评审 cx-1）")
      Just rid -> do
        ebound <- bindExecRoot cfg plan0 rid
        pure (ebound >>= applyOnlyToPlan only)

runApply :: ApplyOpts -> Config -> IO Int
runApply o cfg = do
  r <- prepareApply cfg (aoId o) (aoOnly o)
  case r of
    Left e -> putStrLn e >> pure 2
    Right (plan2, added) -> do
      unless (null added) $
        putStrLn ("· --only 已扩到复合组（不可拆），追加条目: " <> show added)
      mapM_ putStrLn (renderPlan plan2)
      if aoDry o
        then pure 0
        else do
          -- 执行期屏障由内核在 withRootLock 内跑（二十九轮 critical）；三条
          -- 执行路径共用 'Pm.Cli.executePlanNowWith' 这一个装配点，没有哪一处
          -- 还需要（也没有哪一处还能够）自己决定挂不挂屏障。
          code <- executePlanNow cfg plan2
          afterApply cfg plan2 code
          pure code

-- | apply 之后的缓存/提示收尾（可测）。P3b-7 复审 B1：备份缓存写进
-- @\<cfgMainPath\>\/.pm\/backup-cache@，主路径必须是 RoleMain root——
-- 否则跳过刷新并告警（计划本身已由 bindExecRoot 按 UUID 绑到备份 root）。
afterApply :: Config -> Plan -> Int -> IO ()
afterApply cfg plan code = do
  when (plKind plan == "backup") $ do
    emain <- requireMain cfg
    case emain of
      Left m -> putStrLn ("⚠ 备份缓存未刷新（主库身份不符）: " <> m)
      Right _ -> do
        (mMain, _) <- loadCatalog (cfgMainPath cfg)
        (mBak, _) <- loadCatalog (plRootPath plan)
        case (mMain, mBak) of
          (Just mc, Just bc) ->
            refreshBackupCache cfg (plRootPath plan) bc (backupDiff mc bc)
          _ -> pure ()
  when (plKind plan == "vault-push") $ do
    when (code == 0) $
      mapM_ putStrLn (gitStepsLines (plRootPath plan) (plId plan) (planCategories plan))
    -- 刷新 vault 缓存（computeVault 顺带写缓存，内含 requireMain；结果此处不用）
    _ <- computeVault True cfg
    pure ()

runResolve :: ResolveOpts -> Config -> IO Int
runResolve o cfg = do
  ep <- loadPlanAnyRoot cfg (roId o)
  case ep of
    Left e -> putStrLn e >> pure 2
    Right plan0 -> do
      -- P3b-7 复审新 major：resolve 会把计划**写回** <root>/.pm/plans/。root
      -- 路径取自计划文件（可手编），先按 UUID 绑回真实 root（同 apply），再验
      -- 可写（身份可解析 + I11）。
      ebound <- case plRootId plan0 of
        Nothing -> pure (Left "计划缺 root 标识（P2.1 之前的旧格式）→ 重新生成计划")
        Just rid -> bindExecRoot cfg plan0 rid
      ew <- case ebound of
        Left e -> pure (Left e)
        Right p -> either Left (const (Right p)) <$> requireWritable (plRootPath p)
      case ew of
        Left e -> putStrLn e >> pure 2
        Right plan -> resolveOn o plan

-- | 三十轮 F2：resolve 是「装载 → 改 → 写回」的跨进程 RMW——两个 pm resolve
-- 同一份计划、各批不同条目，后写者会整份抹掉先写者的裁决（与二十一轮
-- vault-holds 名单同一形状）。整段进 I10 锁，且锁内**重新装载**盘上的计划：
-- 锁外那份只用来按 UUID 发现 root（线索），不作裁决依据（证据）。
resolveOn :: ResolveOpts -> Plan -> IO Int
resolveOn o plan = do
  m <- withRootLock (plRootPath plan) $ do
    efresh <- loadPlan (plRootPath plan) (plId plan)
    case efresh of
      Left e -> putStrLn e >> pure 2
      Right fresh -> resolveOn' o fresh
  case m of
    Nothing -> putStrLn "另一个 pm 实例正持有该 root 的锁（I10），裁决未写入，稍后重试" >> pure 2
    Just c -> pure c

resolveOn' :: ResolveOpts -> Plan -> IO Int
resolveOn' o plan = do
      let hit = [it | it <- plItems plan, piIx it == roItem o]
      case (hit, roKeep o) of
        ([], _) -> putStrLn ("计划中无条目 " <> show (roItem o)) >> pure 2
        ([item], Just keep) -> resolveKeep plan item keep
        ([_], Nothing) -> do
          -- skip/unskip 扩到复合组（评审 cx-2：组是最小裁决单元）
          let ixs = groupClosure plan [roItem o]
              newStatus = if roSkip o then StSkippedByUser else StPending
              plan' =
                plan
                  { plItems =
                      [ if piIx it `elem` ixs then it {piStatus = newStatus} else it
                      | it <- plItems plan
                      ]
                  }
          when (length ixs > 1) $
            putStrLn ("· 条目属复合组，操作扩到全组: " <> show ixs)
          _ <- savePlan plan'
          mapM_ putStrLn (renderPlan plan')
          pure 0
        _ -> putStrLn "计划条目序号重复（计划文件损坏？）" >> pure 2

replaceItem :: Plan -> Int -> (PlanItem -> PlanItem) -> Plan
replaceItem plan ix f =
  plan {plItems = [if piIx it == ix then f it else it | it <- plItems plan]}

-- | --keep 裁决（DESIGN.md §5 resolve）。评审 cx-4：只接受**独立的**
-- NEEDS-DECISION Copy 条目——复合组成员不可单独裁决（组是不可拆分单元），
-- 非待裁决条目无冲突可裁。
--   src  = 旧目标先隔离、再落源（§6.5 supersede，追加为同组两个新条目）
--   dst  = 保留目标，原条目跳过
--   both = 源改用不冲突的版本名（-v2/-v3…）落位，两者并存
resolveKeep :: Plan -> PlanItem -> String -> IO Int
resolveKeep plan item keep
  | keep `notElem` ["src", "dst", "both"] =
      putStrLn ("--keep 只接受 src|dst|both，收到: " <> keep) >> pure 2
  | Just _ <- piGroup item =
      putStrLn "--keep 不能作用于复合组条目（组不可拆分；用 resolve --item N 跳过整组或重新生成计划）" >> pure 2
  | not (isNeedsDecision (piStatus item)) =
      putStrLn "--keep 只用于 NEEDS-DECISION 冲突条目（该条目不是待裁决状态）" >> pure 2
  | otherwise = case (piOp item, keep) of
      (OpCopy {}, "dst") -> do
        let plan' = replaceItem plan (piIx item) (\it -> it {piStatus = StSkippedByUser})
        _ <- savePlan plan'
        mapM_ putStrLn (renderPlan plan')
        putStrLn "✓ 保留现有目标，该项跳过"
        pure 0
      (op@OpCopy {}, "src") -> do
        let root = plRootPath plan
            dstAbs = root </> opDstRel op
        dstEx <- doesFileExist dstAbs
        if not dstEx
          then do
            -- 冲突已自行消失（目标被移走）：恢复原条目即可
            let plan' = replaceItem plan (piIx item) (\it -> it {piStatus = StPending})
            _ <- savePlan plan'
            putStrLn "目标已不存在，冲突消失；该项恢复为待执行"
            pure 0
          else do
            -- 三十四轮（同型扫尽）：隔离条目要记 victim 当下的 sha，dst 被
            -- AV/索引器占住读不出就改写不了计划（fail-closed，不猜、不落半个
            -- 改写），占用解除后重试同一条 resolve 即可。
            dshaE <- try (sha256File dstAbs) :: IO (Either IOException T.Text)
            case dshaE of
              Left e -> do
                putStrLn ("目标读取失败（" <> show e <> "），resolve 未执行——占用解除后重试")
                pure 2
              Right dsha -> do
                let maxIx = maximum (0 : map piIx (plItems plan))
                    newG = Just (1 + maximum (0 : [g | it <- plItems plan, Just g <- [piGroup it]]))
                    quarantine =
                      PlanItem
                        (maxIx + 1)
                        OpQuarantine
                          { opVictimRel = opDstRel op
                          , opVictimSha = dsha
                          , opReason = T.pack ("supersede:resolve-keep-src(item " <> show (piIx item) <> ")")
                          }
                        StPending
                        newG
                    copy = PlanItem (maxIx + 2) op StPending newG
                    base = replaceItem plan (piIx item) (\it -> it {piStatus = StSkippedByUser})
                    plan' = base {plItems = plItems base <> [quarantine, copy]}
                _ <- savePlan plan'
                mapM_ putStrLn (renderPlan plan')
                putStrLn "✓ 已改写为 supersede（同组不可拆）：旧目标先隔离（可从 trash 还原），再落源"
                pure 0
      (op@OpCopy {}, "both") -> do
        let root = plRootPath plan
            taken = [opDstRel (piOp it) | it <- plItems plan, isCopy (piOp it)]
            isCopy OpCopy {} = True
            isCopy _ = False
        newDst <- freeVersionName root taken (opDstRel op)
        let plan' =
              replaceItem
                plan
                (piIx item)
                (\it -> it {piOp = op {opDstRel = newDst}, piStatus = StPending})
        _ <- savePlan plan'
        mapM_ putStrLn (renderPlan plan')
        putStrLn ("✓ 源将以新名并存落位: " <> newDst)
        pure 0
      _ -> putStrLn "--keep 只适用于 Copy 冲突条目" >> pure 2
 where
  isNeedsDecision (StNeedsDecision _) = True
  isNeedsDecision _ = False

-- | \"a\\b.jpg\" → 第一个既不在盘上、也不在本计划目标集合（case-fold 比较，
-- 评审 mj-2 同源）里的 \"a\\b-vN.jpg\"。
freeVersionName :: FilePath -> [FilePath] -> FilePath -> IO FilePath
freeVersionName root taken dstRel = go (2 :: Int)
 where
  (stem, ext) = splitExtension dstRel
  takenFold = map (map toLower) taken
  go n = do
    let cand = stem <> "-v" <> show n <> ext
    ex <- doesFileExist (root </> cand)
    if ex || map toLower cand `elem` takenFold then go (n + 1) else pure cand
