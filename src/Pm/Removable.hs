{-# LANGUAGE OverloadedStrings #-}

-- | 可移动介质的**瞬断保护**（1.1.2；DESIGN §6.4 末段、§14「掉电\/劣质 USB 桥」行）。
--
-- 背景：外置 USB 备份盘在持续 I\/O 下会掉线又自己回来（2026-09-02 真实盘一天
-- 11 次，最短 2 s 内重挂）。掉线在 pm 里的样子是 'IOException' 从写口\/读口逃顶
-- （@hPutBuf: invalid argument@、@FlushFileBuffers@、@hGetBuf@），或读口被 @try@
-- 兜住后变成一片「读取失败」——前者让 @pm backup \/ pm apply@ 整批崩掉，后者让
-- @pm backup@ 的扫描与 @pm doctor --deep@ 出一堆假结论。此前的对策是仓内三支
-- python 脚本在外面「等盘回来再续」；本模块把同一套判据内建：
--
--   * 盘在不在 = @.pm\/root-id.json@ 读得出（'driveOk'；与 @scripts\/backup_verify.py@
--     的 @Drive.ok@ 同一判据）。
--   * 一个 'IOException' 的三分法（'judgeIO'）：错误类型属确定性一族（用户错误、
--     权限、已存在、非法操作…）→ 原样抛出，**测试注入的 @userError@ 与 pm 自己的
--     fail-closed 拒绝都在这一族，行为与 1.1.1 逐字相同**；否则看盘——盘不在 →
--     'Dropped'（等它回来、冷却、重试）；盘在而错误是 EINVAL 一类 → 'Hiccup'
--     （2 s 内已重挂的那种，短暂停后重试，有界）；盘在而「不存在」→ 确定性。
--   * 续跑单位：扫描按 pass（已 hash 的条目经 catalog 复用，重扫只补漏）；执行按
--     **组**（'execPlanRetry'：已完成的项不再重做、不再重 hash；被打断的组整组
--     重跑，走内核既有的崩溃恢复分支）；两次尝试之间先 @doctor --repair@ 把
--     「已落位、Done 丢失」的洞补上（C2 \/ R2 \/ Q-DONE-LOST），这样 rename 落位
--     后瞬断的那一项按 journal 认作已完成，而不是重 hash 判同再留一个 C2。
--
-- 关闭 = 'noDriveWait'（@[backup] drive-wait = 0@ 或库层默认）：任何异常照旧逃顶，
-- 与 1.1.1 逐字相同——这是判别突变测试钉住的对偶。
module Pm.Removable
  ( DriveWait (..)
  , noDriveWait
  , defaultDriveWaitSecs
  , driveWaitSecs
  , driveWaitFor
  , driveOk
  , Verdict (..)
  , judgeIO
  , withDriveRetry
  , ensureDrive
  , requireDrive
  , scanRootRetry
  , execPlanRetry
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, throwIO, try)
import Control.Monad (unless, when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Time (diffUTCTime, getCurrentTime)
import GHC.IO.Exception (IOErrorType (..), IOException (..))
import System.FilePath ((</>))
import Text.Printf (printf)

import Pm.Config (Config (..), readRootInfo)
import Pm.Exec (ExecEnv (..), ItemOutcome (..), execPlan)
import Pm.Hash (statSnap)
import Pm.Journal (JEntry (..), readJournal)
import Pm.Op (Op (..), opId)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..))
import Pm.Scan (ScanOpts, ScanResult (..), scanRoot)
import Pm.Types (Catalog)

-- | 等盘策略。@dwAttempts = 0@ = 关闭（'noDriveWait'）。
data DriveWait = DriveWait
  { dwWaitSecs :: Int
    -- ^ 盘掉线后最多等多少秒；超时把原异常原样抛出
  , dwCooldownSecs :: Int
    -- ^ 盘回来后先歇多少秒再碰它（实录：刚回来就读容易再掉）
  , dwAttempts :: Int
    -- ^ 同一步骤最多重试几次（掉线与瞬断合计）
  , dwPollMs :: Int
    -- ^ 等盘期间的探测间隔
  , dwSay :: String -> IO ()
    -- ^ 打印口（CLI = putStrLn；serve 端点收进 JSON log）
  }

noDriveWait :: DriveWait
noDriveWait = DriveWait 0 0 0 0 (\_ -> pure ())

-- | 配置缺省：等 30 min（USB 盘掉线到自己回来通常几秒到一两分钟；更长说明
-- 线\/口有问题，人得介入）。
defaultDriveWaitSecs :: Int
defaultDriveWaitSecs = 1800

-- | 生产参数：冷却 30 s、最多 5 次、每 5 s 探一次（与 @scripts\/backup_verify.py@
-- 的缺省相同，2026-09-02 实录跑通）。@n <= 0@ = 关闭。
driveWaitSecs :: (String -> IO ()) -> Int -> DriveWait
driveWaitSecs say n
  | n <= 0 = noDriveWait
  | otherwise = DriveWait n 30 5 5000 say

-- | 从配置取（@[backup] drive-wait@，缺省 'defaultDriveWaitSecs'）。
driveWaitFor :: Config -> (String -> IO ()) -> DriveWait
driveWaitFor cfg say = driveWaitSecs say (fromMaybe defaultDriveWaitSecs (cfgDriveWait cfg))

armed :: DriveWait -> Bool
armed dw = dwAttempts dw > 0

-- | 盘在 = root 身份读得出（'readRootInfo' 把缺席\/读不出\/损坏都塌成 Nothing，
-- 这里要的正是这个「碰不到就当不在」）。
driveOk :: FilePath -> IO Bool
driveOk root = isJust <$> readRootInfo root

data Verdict = Deterministic | Dropped | Hiccup
  deriving (Show, Eq)

-- | 见模块头的三分法。确定性一族不看盘：它们是 pm 与测试的**语义**（拒绝、注入），
-- 不是介质事件。
judgeIO :: FilePath -> IOException -> IO Verdict
judgeIO root e
  | t `elem` [UserError, PermissionDenied, AlreadyExists, IllegalOperation, InappropriateType, UnsupportedOperation] =
      pure Deterministic
  | otherwise = do
      ok <- driveOk root
      pure (if not ok then Dropped else if t == NoSuchThing then Deterministic else Hiccup)
 where
  t = ioe_type e

-- | 等盘回来；True = 回来了（可能立刻），False = 超时。
waitForDrive :: DriveWait -> FilePath -> IO Bool
waitForDrive dw root = getCurrentTime >>= loop
 where
  loop t0 = do
    ok <- driveOk root
    if ok
      then pure True
      else do
        now <- getCurrentTime
        if realToFrac (diffUTCTime now t0) > (fromIntegral (dwWaitSecs dw) :: Double)
          then pure False
          else threadDelay (dwPollMs dw * 1000) >> loop t0

-- | 一次介质事件的处置；返回「可以重试」。'Deterministic' 永远 False。
recover :: DriveWait -> FilePath -> String -> Verdict -> String -> IO Bool
recover dw root what v why = case v of
  Deterministic -> pure False
  Hiccup -> do
    say (printf "⚠ %s 读写出错（%s）；盘仍在，按瞬断处理，%d s 后重试" what why pause)
    sleepS pause
    pure True
  Dropped -> do
    say (printf "⚠ %s 中断（%s）：备份盘掉线，等它回来（最多 %d s）…" what why (dwWaitSecs dw))
    t0 <- getCurrentTime
    back <- waitForDrive dw root
    if not back
      then say "✗ 盘没有回来，放弃重试" >> pure False
      else do
        t1 <- getCurrentTime
        say (printf "· 盘回来了（等了 %.0f s），冷却 %d s 后从中断处继续" (realToFrac (diffUTCTime t1 t0) :: Double) (dwCooldownSecs dw))
        sleepS (dwCooldownSecs dw)
        pure True
 where
  say = dwSay dw
  pause = min 5 (dwCooldownSecs dw)
  sleepS n = when (n > 0) (threadDelay (n * 1000000))

-- | 把一段 IO 包成「瞬断可重试」：异常 → 三分法 → 确定性原样抛、其余按策略等\/停
-- 后重来，次数用尽抛原异常。被包的动作须可安全重跑（catalog 三代轮转、journal
-- 只追加、doctor 幂等——本模块的调用点都是这一类）。
withDriveRetry :: DriveWait -> FilePath -> String -> IO a -> IO a
withDriveRetry dw root what act = go (0 :: Int)
 where
  go n = do
    r <- try act
    case r of
      Right a -> pure a
      Left e
        | not (armed dw) || n >= dwAttempts dw -> throwIO e
        | otherwise -> do
            v <- judgeIO root e
            ok <- recover dw root what v (show e)
            if ok then go (n + 1) else throwIO e

-- | 盘不在就等它回来（关闭时不做任何事）。等不到 → 抛一个 'ResourceVanished' 型
-- 异常——不是 @userError@，外层 'withDriveRetry' 还能再判一次。用在**布尔探针之前**
-- （@doesFileExist@ 在盘不在时答 False，会把「盘掉了」说成「文件消失」）。
ensureDrive :: DriveWait -> FilePath -> String -> IO ()
ensureDrive dw root what = when (armed dw) $ do
  ok <- driveOk root
  unless ok $ do
    back <- recover dw root what Dropped "盘不在"
    unless back (throwIO (dropError what root))

-- | 盘不在就**立刻**抛（不等）——用在一段长动作**之后**：动作期间盘掉过且还没
-- 回来，它的结论不可信，交给外层 'withDriveRetry' 等盘重跑（doctor 整场就是这样包的）。
requireDrive :: DriveWait -> FilePath -> String -> IO ()
requireDrive dw root what = when (armed dw) $ do
  ok <- driveOk root
  unless ok (throwIO (dropError what root))

dropError :: String -> FilePath -> IOException
dropError what root = IOError Nothing ResourceVanished what "备份盘掉线（.pm/root-id.json 读不到）" Nothing (Just root)

-- | 'Pm.Scan.scanRoot' 按 pass 续跑：一遍扫完若有读错\/未枚举子树，盘不在就等、盘在
-- 就短停，然后拿**这一遍的 catalog**当旧快照再扫一遍——已 hash 的条目按 (size, mtime)
-- 复用，重扫只补上一遍漏掉的。干净（零读错、零未枚举）或次数用尽即返回，结论
-- 仍由调用方按 'srErrors' \/ 'srCarried' 判「不完整」——本函数只减少假的不完整。
scanRootRetry :: DriveWait -> ScanOpts -> Maybe Catalog -> Text -> FilePath -> IO ScanResult
scanRootRetry dw opts old0 rid root = go (0 :: Int) old0
 where
  go n old = do
    r <- try (ensureDrive dw root "扫描" >> scanRoot opts old rid root)
    case r of
      Left e
        | not (armed dw) || n >= dwAttempts dw -> throwIO e
        | otherwise -> do
            v <- judgeIO root e
            ok <- recover dw root "扫描" v (show e)
            if ok then go (n + 1) old else throwIO e
      Right res
        | not (armed dw) || n >= dwAttempts dw || clean res -> pure res
        | otherwise -> do
            present <- driveOk root
            let issues = show (length (srErrors res)) <> " 处读错、" <> show (srCarried res) <> " 条落在未枚举子树"
            ok <- recover dw root "扫描" (if present then Hiccup else Dropped) issues
            if ok then go (n + 1) (Just (srCatalog res)) else pure res
  clean res = null (srErrors res) && srCarried res == 0

-- | 'Pm.Exec.execPlan' 的会话级续跑。内核一场会话持有 root 锁与 journal 句柄，盘
-- 掉线两者都死，异常逃顶 = 进程死亡语义（Exec 模块头）；这里在**会话之间**接手：
--
--   1. 逐项结果经 'eeProgress' 钩子实时记下（内核每执行完一项调一次）；
--   2. 异常 → 三分法；可重试 → 等盘\/短停 → 调用方给的 @heal@（@doctor --repair@：
--      对「有 Intent 无 Done、盘面证明已落位」的项补记 Done）；
--   3. 结算已完成的**组**：组内每项都有结果且都是 DONE\/同内容 SKIP → 按结果计；
--      否则组内每个待执行项在 journal 里末事件都是 Done → 按 journal 计（Copy 的
--      dst 现 stat 一次，结果形态与内核落位时相同：@ODone sha stat@ \/ rename
--      @ODone@ 空 \/ 隔离 @ODone sha _ trashRel@）；其余组整组重跑——内核既有的
--      崩溃恢复分支接手（victim 已入 trash 且 sha 相符 → 视同完成；dst 已同内容
--      → SKIP），不重做已落的字节；
--   4. 只把未结算的项交给下一场 'execPlan'（组闭包天然保全），结果按原序合并。
--
-- 关闭（'noDriveWait'）= 直接 'execPlan'，异常照旧逃顶。
execPlanRetry :: DriveWait -> IO () -> ExecEnv -> Plan -> IO (Either String [(PlanItem, ItemOutcome)])
execPlanRetry dw heal env0 plan
  | not (armed dw) = execPlan env0 plan
  | otherwise = do
      seen <- newIORef Map.empty
      let env = env0 {eeProgress = \it out -> modifyIORef' seen (Map.insert (piIx it) (it, out)) >> eeProgress env0 it out}
          root = plRootPath plan
          go n committed todo = do
            r <- try (execPlan env plan {plItems = todo})
            case r of
              Right (Left e)
                | Map.null committed -> pure (Left e)
                | otherwise -> pure (Left (e <> "（中断前已完成 " <> show (Map.size committed) <> " 项；索引待 pm scan 补齐）"))
              Right (Right outs) -> pure (Right (merge committed outs))
              Left e
                | n >= dwAttempts dw -> throwIO e
                | otherwise -> do
                    v <- judgeIO root e
                    ok <- recover dw root "执行" v (show e)
                    unless ok (throwIO e)
                    heal
                    prog <- readIORef seen
                    done <- lastDone . fst <$> withDriveRetry dw root "读 journal" (readJournal root)
                    settled <- settle root prog done (plId plan) todo
                    let committed' = Map.union committed settled
                        todo' = [it | it <- todo, piIx it `Map.notMember` committed']
                    dwSay dw (printf "· 从中断处继续：已结算 %d 项，剩 %d 项重跑" (Map.size committed') (length todo'))
                    go (n + 1 :: Int) committed' todo'
      go 0 Map.empty (plItems plan)
 where
  merge committed outs =
    let byIx = Map.union committed (Map.fromList [(piIx it, (it, o)) | (it, o) <- outs])
     in [v | it <- plItems plan, Just v <- [Map.lookup (piIx it) byIx]]

-- | 结算规则见 'execPlanRetry' 第 3 条。组 = 同 'piGroup'（Nothing 各自成组）。
settle :: FilePath -> Map.Map Int (PlanItem, ItemOutcome) -> Map.Map Text JEntry -> Text -> [PlanItem] -> IO (Map.Map Int (PlanItem, ItemOutcome))
settle root prog done pid todo = Map.unions <$> mapM settleGroup groups
 where
  groups = Map.elems (Map.fromListWith (flip (<>)) [(maybe (Left (piIx it)) Right (piGroup it), [it]) | it <- todo])
  inactive it = piStatus it /= StPending
  -- 与 'Pm.Exec.execItems' 的 groupOk 同一判据（DONE / 同内容 SKIP 才算组内成功）
  okOut ODone {} = True
  okOut OSkippedIdentical = True
  okOut _ = False
  byProgress it = case Map.lookup (piIx it) prog of
    Just (it', out) | okOut out || (inactive it && out == ONotExecuted) -> Just (it', out)
    _ -> Nothing
  settleGroup ms
    | Just rs <- mapM byProgress ms = pure (Map.fromList [(piIx it, r) | (it, r) <- zip ms rs])
    | otherwise = do
        rs <- mapM byJournal ms
        pure (maybe Map.empty (\xs -> Map.fromList [(piIx it, (it, o)) | (it, o) <- zip ms xs]) (sequence rs))
  byJournal it
    | inactive it = pure (Just ONotExecuted)
    | otherwise = case Map.lookup (opId pid (piIx it)) done of
        Just (JDone _ msha mtrash _) -> case piOp it of
          OpCopy {opDstRel = d} -> do
            st <- try (statSnap (root </> d))
            pure (either (\e -> const Nothing (e :: IOException)) (\s -> Just (ODone msha (Just s) Nothing)) st)
          _ -> pure (Just (ODone msha Nothing mtrash))
        _ -> pure Nothing

-- | 每个 oid 的**末事件**若是 Done 则记下（次序感知，同 'Pm.Doctor' 的 opState：
-- 同 oid 重跑会再出 Intent，上一轮的 Done 不算数）。
lastDone :: [JEntry] -> Map.Map Text JEntry
lastDone = foldl step Map.empty
 where
  step m e@JDone {} = Map.insert (jeOpId e) e m
  step m e@JIntent {} = Map.delete (jeOpId e) m
  step m e@JFailed {} = Map.delete (jeOpId e) m
  step m _ = m
