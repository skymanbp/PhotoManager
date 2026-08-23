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
  , bindExecRoot
  , recheckCleanPlan
  , applyOnlyToPlan
  , parseOnly
  , stagingFresh
  , reportScanIssues
  , refreshBackupCache
  ) where

import Control.Monad (forM, forM_, unless, when)
import Data.Char (toLower)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.FilePath (splitDirectories)
import System.IO (hFlush, stdout)
import Text.Printf (printf)
import Text.Read (readMaybe)

import Pm.Backup
import Pm.Catalog (loadCatalog, saveCatalog)
import Pm.Clean (threeCopiesStillExist)
import Pm.Config (Config (..), readRootInfo)
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
executePlanNow :: Plan -> IO Int
executePlanNow plan = do
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

savePlanAndMaybeRun :: GoOpts -> Plan -> IO Int
savePlanAndMaybeRun go plan = do
  fp <- savePlan plan
  renderPlanBrief plan
  putStrLn ("计划已存 " <> fp)
  putStrLn ("执行: pm apply " <> T.unpack (plId plan))
  ok <- confirm go
  if ok then executePlanNow plan else pure 1

-- | 评审 cx-1：执行 root 由 UUID 重新发现并绑定，绝不信计划里存的盘符路径
-- （备份盘可能换盘符重挂，旧盘符可能已属于别的卷）。
bindExecRoot :: Config -> Plan -> T.Text -> IO (Either String Plan)
bindExecRoot cfg plan rid
  | plKind plan == "backup" = do
      er <- discoverBackupRoot cfg
      case er of
        Left msg -> pure (Left ("备份计划需要备份盘在线: " <> msg))
        Right broot -> do
          minfo <- readRootInfo broot
          case minfo of
            Just info
              | riId info == rid -> do
                  when (broot /= plRootPath plan) $
                    putStrLn ("· 备份盘挂载点已变: " <> plRootPath plan <> " → " <> broot <> "（按 UUID 重新绑定）")
                  pure (Right plan {plRootPath = broot})
            _ -> pure (Left "发现的备份盘 root 标识与计划不符，拒绝执行")
  | otherwise = do
      let mroot = cfgMainPath cfg
      minfo <- readRootInfo mroot
      case minfo of
        Just info
          | riId info == rid -> pure (Right plan {plRootPath = mroot})
          | otherwise ->
              pure
                ( Left
                    ( "主库 root 标识与计划不符（计划 "
                        <> T.unpack rid
                        <> "，主库 "
                        <> T.unpack (riId info)
                        <> "），拒绝执行"
                    )
                )
        Nothing -> pure (Left "主库缺 .pm/root-id.json → pm init")

-- | 评审 cx-3：clean 计划在执行前逐项重验三副本（当前 catalog 定位见证 +
-- 真实重 hash），不过的降级 NEEDS-DECISION——计划生成与执行之间隔着任意长
-- 的时间，世界会变。即时 `pm clean staging --apply` 免此步（见证 hash 刚在
-- 同进程完成，DESIGN §5）。
recheckCleanPlan :: Config -> Plan -> IO Plan
recheckCleanPlan cfg plan = do
  let mroot = cfgMainPath cfg
  (mMain, _) <- loadCatalog mroot
  er <- discoverBackupRoot cfg
  case (mMain, er) of
    (Just mainCat, Right broot) -> do
      (mBak, _) <- loadCatalog broot
      case mBak of
        Nothing -> demoteAll "备份盘无索引 → 先 pm backup"
        Just bakCat -> do
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
    (Nothing, _) -> demoteAll "主库无索引"
    (_, Left msg) -> demoteAll ("备份盘不在线: " <> msg)
 where
  demoteAll why = do
    putStrLn ("⚠ 无法复验三副本（" <> why <> "），全部待执行项暂停")
    pure
      plan
        { plItems =
            [ if piStatus it == StPending
                then it {piStatus = StNeedsDecision (T.pack ("执行期无法复验三副本: " <> why))}
                else it
            | it <- plItems plan
            ]
        }

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
  writeBackupCache
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
