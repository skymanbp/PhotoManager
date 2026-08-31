{-# LANGUAGE OverloadedStrings #-}

-- | Plans are pure data (DESIGN.md §3): printable, diffable, persisted under
-- @\<root\>\/.pm\/plans\/\<id\>.json@ of the root they mutate. Exec consumes
-- nothing else.
module Pm.Plan
  ( Plan (..)
  , PlanItem (..)
  , ItemStatus (..)
  , newPlanId
  , isValidPlanId
  , validatePlan
  , planPath
  , savePlan
  , loadPlan
  , listPlans
  , renderPlan
  , groupClosure
  , BarrierKind (..)
  , kindBarrier

    -- * 执行态折叠与计划文件的删除（用户 2026-08-31 裁定：标注+删除+一键清理）
  , PlanExec (..)
  , planExecs
  , planExecuted
  , runTag
  , deletePlan
  , deletePlanAnyRoot
  , prunePlans
  , planRoots
  , runPlanList
  , runPlanRm
  , runPlanPrune
  ) where

import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (nub, sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM, forM_, when)
import Data.Maybe (fromMaybe)
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (dropExtension, takeExtension, (</>))
import System.IO (hClose)
import Text.Printf (printf)

import Pm.Config (Config (..), ensurePmSubdir, pmDir, pmSubPlans, readPmState, requirePmTrusted, untrustedMsg)
import Pm.Journal (JEntry (..), readJournal)
import Pm.Win (deleteBoundAt, flushHandleToDisk, moveBoundNoReplace, openFreshBinary, resolveUnder, whenPresent)
import Pm.Op -- 含 isValidPlanId（P3b-8 起定义于 Pm.Op，本模块再导出）

data ItemStatus
  = StPending
  | StSkippedByUser
  | StNeedsDecision Text
  deriving (Show, Eq)

instance ToJSON ItemStatus where
  toJSON StPending = object ["s" .= ("pending" :: Text)]
  toJSON StSkippedByUser = object ["s" .= ("skipped" :: Text)]
  toJSON (StNeedsDecision why) = object ["s" .= ("needs-decision" :: Text), "why" .= why]

instance FromJSON ItemStatus where
  parseJSON = withObject "ItemStatus" $ \o -> do
    s <- o .: "s"
    case (s :: Text) of
      "pending" -> pure StPending
      "skipped" -> pure StSkippedByUser
      "needs-decision" -> StNeedsDecision <$> o .: "why"
      _ -> fail ("unknown item status: " <> show s)

data PlanItem = PlanItem
  { piIx :: Int
  , piOp :: Op
  , piStatus :: ItemStatus
  , piGroup :: Maybe Int
    -- ^ 复合组 id（P2.1，评审 cx-2/cx-5）：同组条目是不可拆分的语义单元
    -- （supersede = [Quarantine, Copy]）。--only/resolve 的选择自动扩到全组；
    -- Exec 内组内后续项失败会自动复位组内已执行的 Quarantine。
  }
  deriving (Show, Eq)

instance ToJSON PlanItem where
  toJSON p =
    object ["ix" .= piIx p, "op" .= piOp p, "status" .= piStatus p, "group" .= piGroup p]

instance FromJSON PlanItem where
  parseJSON = withObject "PlanItem" $ \o ->
    PlanItem <$> o .: "ix" <*> o .: "op" <*> o .: "status" <*> o .:? "group"

data Plan = Plan
  { plId :: Text
  , plKind :: Text
  , plRootPath :: FilePath
    -- ^ 生成时的挂载路径（展示/寻址用）；执行前按 'plRootId' 重新绑定。
  , plRootId :: Maybe Text
    -- ^ 被变更 root 的 UUID（P2.1，评审 cx-1）。apply 前必须重新发现/校验该
    -- UUID 并把执行 root 绑定为当前发现路径——盘符会漂移，UUID 不会。
    -- Maybe 仅为旧计划文件可解析；apply 拒绝执行 Nothing 的计划。
  , plCreated :: UTCTime
  , plItems :: [PlanItem]
  }
  deriving (Show, Eq)

instance ToJSON Plan where
  toJSON p =
    object
      [ "id" .= plId p
      , "kind" .= plKind p
      , "root" .= plRootPath p
      , "rootId" .= plRootId p
      , "created" .= plCreated p
      , "items" .= plItems p
      ]

instance FromJSON Plan where
  parseJSON = withObject "Plan" $ \o ->
    Plan <$> o .: "id" <*> o .: "kind" <*> o .: "root" <*> o .:? "rootId" <*> o .: "created" <*> o .: "items"

newPlanId :: IO Text
newPlanId = do
  now <- getCurrentTime
  bytes <- getRandomBytes 3
  let ts = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now
      hex = concatMap (printf "%02x") (BS.unpack bytes)
  pure (T.pack (ts <> "-" <> hex))

-- 'isValidPlanId'（生成格式 @YYYYMMDD-HHMMSS-hex6@）自 P3b-8 起定义在 'Pm.Op'
-- （'opIdParts' 也要它），本模块再导出；装载（'loadPlan'）与执行
-- （'Pm.Exec.execPlan'）两处都用它拒绝不合格式的 id（P3b-6 复审 A1）。

-- | 计划的结构性校验（装载与执行两处共用；P3b-7 复审 A1 \/ 新 major）：id 为
-- 生成格式；@piIx@ 非负且全局唯一——负数会拼出无法解析的 opId，重复序号让
-- 不同操作共享 oid，doctor\/undo 按 oid 折叠时会把它们混成一个；P3b-8 六轮
-- 复审 major：每个 Op 的相对路径字段过 'opPathsOk'（越界\/盘符\/ADS\/@.pm@
-- 内部一律拒绝——手编计划的路径会被拼到 root 上）。
validatePlan :: Plan -> Either String ()
validatePlan p
  | not (isValidPlanId (plId p)) =
      Left ("计划 id 不符合生成格式（" <> T.unpack (plId p) <> "，应为 YYYYMMDD-HHMMSS-hex6）")
  | any (< 0) ixs = Left "计划含负数条目序号（piIx < 0）"
  | length ixs /= Set.size (Set.fromList ixs) = Left "计划条目序号重复（piIx 不唯一）"
  | (bad : _) <- [piIx it | it <- plItems p, not (opPathsOk (piOp it))] =
      Left ("计划条目 " <> show bad <> " 含非法相对路径（绝对/盘符/':'/'.'/'..'/分隔符开头/.pm 内部）")
  | otherwise = Right ()
 where
  ixs = map piIx (plItems p)

plansDir :: FilePath -> FilePath
plansDir root = pmDir root </> pmSubPlans

planPath :: FilePath -> Text -> FilePath
planPath root pid = plansDir root </> (T.unpack pid <> ".json")

-- | P3b-12（九轮复审 major）：此前是覆盖写，计划文件名被预置成库外对象的
-- hardlink 时会写穿到库外（探针实证同型）。改为「独占创建 tmp → 删旧 →
-- 'moveBoundNoReplace' 落位」：tmp 走 @CREATE_NEW@，删旧对 hardlink 只减一个
-- 目录项。删旧与落位之间崩溃会丢掉计划文件——可接受：计划可重新生成，耐久层
-- 是 journal（DESIGN §3）。
-- P3b-14（十一轮）：建目录之后对**完整路径**再验一次（同
-- 'Pm.Config.writeCacheFile'）。可信闸只覆盖 @.pm\/plans@ 这一层，计划文件
-- 自身是深度 2；它若是指向库外的 symlink，删旧那一步会删掉库外文件。
-- 拒绝以 IOException 抛出（同 'Pm.Config.withPmStateAppend'）：14 处调用点都在
-- 「生成计划 → 落盘 → 报告」的直线上，写不成必须整条命令中止，而不是让调用方
-- 各自决定怎么忽略。
savePlan :: Plan -> IO FilePath
savePlan p = do
  let root = plRootPath p
      pid = plId p
  -- 第一方自审 R5：子目录先限域再建（'ensurePmSubdir'），不在被劫持的 .pm 后面
  -- 留下一个库外 plans 目录。
  ed <- ensurePmSubdir root pmSubPlans
  m <- either (const (pure Nothing)) (const (resolveUnder root (".pm" </> pmSubPlans </> (T.unpack pid <> ".json")))) ed
  case m of
    Nothing -> ioError (userError (untrustedMsg (planPath root pid)))
    Just fp -> do
      let tmp = fp <> ".tmp"
      bracket (openFreshBinary tmp) hClose $ \h -> do
        BSL.hPut h (encode p)
        flushHandleToDisk h
      old <- doesFileExist fp
      when old (deleteBoundAt fp)
      moveBoundNoReplace tmp fp
      pure fp

-- | 装载前先验 id 格式（也挡住 @..\\x@ 之类拼进 'planPath' 的路径穿越），装载
-- 后再过 'validatePlan' 并验文件内 id 与文件名一致。
loadPlan :: FilePath -> Text -> IO (Either String Plan)
loadPlan root pid
  | not (isValidPlanId pid) =
      pure (Left ("计划 id 不符合生成格式（" <> T.unpack pid <> "，应为 YYYYMMDD-HHMMSS-hex6），拒绝装载"))
  | otherwise = do
      -- 闸在 loader 里（P3b-13 十轮 major）：apply/resolve 的计划查找此前在任何
      -- 可信判定之前就读了 .pm/plans。
      tr <- requirePmTrusted root
      case tr of
        Left m -> pure (Left m)
        Right () -> loadPlan' root pid

loadPlan' :: FilePath -> Text -> IO (Either String Plan)
loadPlan' root pid = do
      -- P3b-14（十一轮复审 major，探针实证）：计划文件在深度 2，可信闸只验到
      -- @.pm/plans@。实测把 @plans/<id>.json@ 做成库外计划的 hardlink **或**
      -- symlink 后，loadPlan 两种形态都把**库外计划**载入了——apply 会照它执行。
      -- 受信取用口一次治两种：完整路径 resolveUnder 认 symlink，句柄 link
      -- count 认 hardlink。
      rd <- readPmState root (pmSubPlans </> (T.unpack pid <> ".json"))
      case rd of
        Left m -> pure (Left m)
        Right Nothing -> pure (Left ("计划不存在: " <> planPath root pid))
        Right (Just bytes) ->
          pure $ case eitherDecodeStrict' bytes of
            Left e -> Left e
            Right p
              | plId p /= pid ->
                  Left ("计划文件内 id（" <> T.unpack (plId p) <> "）与文件名（" <> T.unpack pid <> "）不符，拒绝装载")
              | Left e <- validatePlan p -> Left (e <> "，拒绝装载")
              -- 第一方自审工作流 F027：文件里的 @root@ 字段是生成时的挂载路径
              -- （可手编、盘符已变），是线索不是证据。受信取用口只有这一个，
              -- 在这里把记录绑到**字节实际来自**的目录，每个调用方（resolve 的
              -- 锁内重装、listPlans/GUI 列表）就不必各自记得重绑。执行前仍按
              -- 'plRootId' 走 bindExecRoot（UUID 发现），两道互不替代。
              | otherwise -> Right p {plRootPath = root}

-- | 列出 @root\/.pm\/plans@ 下装得出来的计划；装不出来的按 (文件名, 原因)
-- 返回。目录本身经 'requirePmTrusted' + 完整路径 'resolveUnder'，每个计划经
-- 'loadPlan'（受信取用口）；文件名只是候选 id，先过 'isValidPlanId'。
--
-- 三十五轮 F3：从 Pm.Serve 迁入（计划枚举与 'loadPlan' 同域；Serve 已触及
-- 750 行预算，原处再导出）并给枚举包 try——@.pm\/plans@ 被良性进程占住/
-- 挪走时 listDirectory 抛出，此前逃到 warp 的 500 兜底，GUI 拿不到结构化
-- errors。枚举失败 = errors 一条、plans 空（fail-closed，原因不吞）。
listPlans :: FilePath -> IO ([Plan], [(String, String)])
listPlans root = do
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure ([], [("", m)])
    Right () -> do
      m <- resolveUnder root (".pm" </> pmSubPlans)
      case m of
        Nothing -> pure ([], [("", untrustedMsg (root </> ".pm" </> pmSubPlans))])
        Just d -> do
          -- 第一方自审 R1：存在性三态——@doesDirectoryExist@ 把 ACL 拒绝塌成
          -- 「没有计划」，页面安静地空着；查不出 = errors 一条。
          namesE <- whenPresent d (listDirectory d)
          case namesE of
            Left e -> pure ([], [("", "计划目录枚举失败（被占/介质错误？）: " <> e)])
            Right names0 -> do
              let names = fromMaybe [] names0
              let pids = [T.pack (dropExtension n) | n <- names, takeExtension n == ".json", isValidPlanId (T.pack (dropExtension n))]
              rs <- mapM (\pid -> fmap ((,) (T.unpack pid)) (loadPlan root pid)) pids
              pure ([p | (_, Right p) <- rs], [(n, e) | (n, Left e) <- rs])

renderPlan :: Plan -> [String]
renderPlan p =
  ("计划 " <> T.unpack (plId p) <> " (" <> T.unpack (plKind p) <> ") · root " <> plRootPath p)
    : [ printf
          "  %3d | %-9s | %s%s"
          (piIx it)
          (statusTag (piStatus it))
          (describeOp (piOp it))
          (groupTag (piGroup it))
      | it <- plItems p
      ]
 where
  statusTag StPending = "PENDING" :: String
  statusTag StSkippedByUser = "SKIPPED"
  statusTag (StNeedsDecision _) = "DECIDE"
  groupTag Nothing = "" :: String
  groupTag (Just g) = "  [组" <> show g <> "·不可拆分]"

-- | Expand a selection of item indices to full compound groups: selecting any
-- member of a group selects them all（评审 cx-2/cx-5 —— supersede 配对不允许
-- 被 --only 或 resolve 拆开）。
groupClosure :: Plan -> [Int] -> [Int]
groupClosure p sel =
  let gs = Set.fromList [g | it <- plItems p, piIx it `elem` sel, Just g <- [piGroup it]]
      extra = [piIx it | it <- plItems p, Just g <- [piGroup it], g `Set.member` gs]
   in sort (nub (sel <> extra))

-- | 执行期组屏障的**种类**（三十轮 F4 的类型封闭）。
--
-- 此前「哪些 kind 要屏障」是 'Pm.Plan' 的一张布尔表、「挂哪个屏障」是
-- 'Pm.Cli' 的另一张函数表，两半靠一条测试钉住一致。现在收成**一个**分类器：
-- 内核据它判「要不要」，命令层对它做 total 的模式匹配给出「是哪个」——漏一个
-- 构造子 = @-Wall@ 的 incomplete-patterns 警告（纪律 warnings 0；非 @-Werror@
-- 硬失败，三十二轮更正措辞），真漏进运行期在锁内、journal 前硬崩不放行；
-- 构造子接没接**对**由 DedupeTests casePreExecRow 按降级理由区分钉住。
--
-- 屏障存在的理由（二十九轮 critical，对抗复核未能驳倒）：屏障若跑在
-- 'Pm.Lock.withRootLock' 之外，两个 pm 进程各跑 @pm apply <同一计划>@ 的
-- @--only 1@ / @--only 2@，双方各自看见对方那份还活着，双双放行，同一内容的
-- **所有**副本一起进隔离区。判据与动盘必须是同一个跨进程事务。
data BarrierKind
  = -- | @clean-staging@：暂存文件移出前重验「归档层 + 备份盘」三副本仍在
    BarrierClean
  | -- | @dedupe@：批准隔离的条目不得把某内容在归档层的最后一份活副本也隔离掉
    BarrierDedupe
  deriving (Show, Eq)

kindBarrier :: Text -> Maybe BarrierKind
kindBarrier "clean-staging" = Just BarrierClean
kindBarrier "dedupe" = Just BarrierDedupe
kindBarrier _ = Nothing

-- ─── 执行态折叠与计划文件的删除（用户 2026-08-31 裁定）───────────────────────

-- | 一份计划在 journal 里的执行事实。计划文件从不回写执行状态（§3：耐久层是
-- journal），「已执行」只能从这里折叠出来——GUI 计划页与 @pm plan list@ 同源。
data PlanExec = PlanExec
  { peDone :: Set.Set Int
  , peFailed :: Set.Set Int
  , peLastAt :: Maybe UTCTime
  }
  deriving (Show, Eq)

-- | 按计划 id 折叠 journal（'opIdParts' 是唯一的 oid 解析口）：普通后缀的
-- Done 计入完成、并抹掉同序号早前的失败（重试成功不再算失败）；@~r@（§6.5
-- 组回滚的自动复位）把对应序号从完成里剔除——那次执行被撤销了；@~d\<N\>@ 是
-- 组回滚的内部位移，不计。Intent\/Failed 也推动 'peLastAt'。
planExecs :: [JEntry] -> Map.Map Text PlanExec
planExecs = foldl' step Map.empty
 where
  step m e = case e of
    JDone {jeOpId = oid, jeAt = at} -> touch oid at doneStep m
    JFailed {jeOpId = oid, jeAt = at} -> touch oid at failStep m
    JIntent {jeOpId = oid, jeAt = at} -> touch oid at (\_ _ r -> r) m
    _ -> m
  touch oid at f m = case opIdParts oid of
    Nothing -> m
    Just (pid, ix, sfx) ->
      Map.alter (Just . f ix sfx . bumpAt at . fromMaybe (PlanExec Set.empty Set.empty Nothing)) pid m
  bumpAt at r = r {peLastAt = max (Just at) (peLastAt r)}
  doneStep ix SfxPlain r = r {peDone = Set.insert ix (peDone r), peFailed = Set.delete ix (peFailed r)}
  doneStep ix SfxRestore r = r {peDone = Set.delete ix (peDone r)}
  doneStep _ (SfxDisplaced _) r = r
  failStep ix SfxPlain r = r {peFailed = Set.insert ix (peFailed r)}
  failStep _ _ r = r

-- | 「已执行」判据（也是 @prune@ 的删除条件，保守取向）：至少有一个待执行项、
-- 没有待裁决残余、且每个待执行序号都有 Done。从未执行的弃用草稿、还挂着
-- 待裁决项的计划都不算——prune 不替用户裁决，删它们走显式 @pm plan rm@。
planExecuted :: Plan -> Maybe PlanExec -> Bool
planExecuted p mr = not (null pend) && null nds && all (`Set.member` done) pend
 where
  pend = [piIx it | it <- plItems p, piStatus it == StPending]
  nds = [() | it <- plItems p, StNeedsDecision _ <- [piStatus it]]
  done = maybe Set.empty peDone mr

-- | 人读执行态（CLI 与 GUI 同一折叠，措辞各自渲染）。
runTag :: Plan -> Maybe PlanExec -> String
runTag p mr
  | not (null pend) && doneN == length pend =
      (if null nds then "已执行" else "已执行（余 " <> show (length nds) <> " 项待裁决）") <> failNote
  | doneN > 0 = "部分执行 " <> show doneN <> "/" <> show (length pend) <> failNote
  | otherwise = "未执行" <> failNote
 where
  pend = [piIx it | it <- plItems p, piStatus it == StPending]
  nds = [() | it <- plItems p, StNeedsDecision _ <- [piStatus it]]
  doneN = length [ix | ix <- pend, ix `Set.member` maybe Set.empty peDone mr]
  failN = maybe 0 (Set.size . peFailed) mr
  failNote = if failN > 0 then "（失败 " <> show failN <> "）" else ""

-- | 删除一份计划文件。计划可再生成、耐久层是 journal（'savePlan' 的注释）——
-- 删除不触碰 journal\/undo\/doctor 的任何输入。守卫与 'loadPlan' 同规格：
-- id 格式 → 可信闸 → 完整路径受信解析 → 句柄式删除（'deleteBoundAt'，
-- symlink\/hardlink 同 'savePlan' 删旧的口径）。
deletePlan :: FilePath -> Text -> IO (Either String ())
deletePlan root pid
  | not (isValidPlanId pid) =
      pure (Left ("计划 id 不符合生成格式（" <> T.unpack pid <> "，应为 YYYYMMDD-HHMMSS-hex6），拒绝删除"))
  | otherwise = do
      tr <- requirePmTrusted root
      case tr of
        Left m -> pure (Left m)
        Right () -> do
          m <- resolveUnder root (".pm" </> pmSubPlans </> (T.unpack pid <> ".json"))
          case m of
            Nothing -> pure (Left (untrustedMsg (planPath root pid)))
            Just fp -> do
              ex <- doesFileExist fp
              if not ex
                then pure (Left ("计划不存在: " <> fp))
                else do
                  r <- try (deleteBoundAt fp) :: IO (Either IOException ())
                  pure (either (\e -> Left ("删除失败: " <> show e)) Right r)

-- | 计划所在的根：主库 + （配置了的）vault——与 @GET \/api\/plans@ 同一口径。
-- 备份盘上的计划（kind backup）存在盘上自己的 @.pm@ 下，不插盘看不见。
planRoots :: Config -> [(String, FilePath)]
planRoots cfg = ("主库", cfgMainPath cfg) : maybe [] (\v -> [("vault", v)]) (cfgVaultPath cfg)

-- | 在主库\/vault 里找到并删除一份计划；都没有 → Left（最后一个根的原因）。
deletePlanAnyRoot :: Config -> Text -> IO (Either String String)
deletePlanAnyRoot cfg pid = go (planRoots cfg)
 where
  go [] = pure (Left "主库/vault 都没有这份计划")
  go ((label, root) : rest) = do
    r <- deletePlan root pid
    case r of
      Right () -> pure (Right label)
      Left m -> if null rest then pure (Left m) else go rest

-- | 清理两根下全部「已执行」的计划（'planExecuted' 的保守判据）。返回
-- （删掉的 (根, 计划), 失败原因）；journal 读不出时该根一份都不删（fail-closed：
-- 折叠不出执行事实就没有「已执行」）。
prunePlans :: Config -> IO ([(String, Plan)], [String])
prunePlans cfg = do
  rs <- forM (planRoots cfg) $ \(label, root) -> do
    (ps, errs) <- listPlans root
    (es, warns) <- readJournal root
    let runs = planExecs es
        victims = [p | p <- ps, planExecuted p (Map.lookup (plId p) runs)]
    dels <- forM victims $ \p -> do
      r <- deletePlan root (plId p)
      pure (either (\m -> Left (T.unpack (plId p) <> ": " <> m)) (const (Right (label, p))) r)
    pure ([d | Right d <- dels], [e | Left e <- dels] <> map (\(n, e) -> n <> "：" <> e) errs <> warns)
  pure (concatMap fst rs, concatMap snd rs)

-- | @pm plan list@：两根的计划 + journal 折叠的执行态（按生成时间排序）。
runPlanList :: Config -> IO Int
runPlanList cfg = do
  rows <- fmap concat . forM (planRoots cfg) $ \(label, root) -> do
    (ps, errs) <- listPlans root
    (es, warns) <- readJournal root
    mapM_ (\w -> putStrLn ("⚠ journal: " <> w)) warns
    mapM_ (\(n, e) -> putStrLn ("⚠ 装不出来的计划: " <> n <> "：" <> e)) errs
    let runs = planExecs es
    pure [(label, p, Map.lookup (plId p) runs) | p <- ps]
  if null rows
    then putStrLn "还没有计划。" >> pure 0
    else do
      forM_ (sortOn (\(_, p, _) -> plCreated p) rows) $ \(label, p, mr) ->
        putStrLn
          ( printf
              "%-5s %s  %-14s %4d 项  %s"
              label
              (T.unpack (plId p))
              (T.unpack (plKind p))
              (length (plItems p))
              (runTag p mr)
          )
      putStrLn "（执行态从 journal 折叠而来，计划文件不回写；pm plan rm <id> 删除、pm plan prune 清理已执行）"
      pure 0

-- | @pm plan rm <id>…@：删除计划文件（journal\/undo 不受影响，需要可重新生成）。
runPlanRm :: [String] -> Config -> IO Int
runPlanRm ids cfg
  | null ids = putStrLn "未给出计划 id（pm plan list 查看）" >> pure 2
  | otherwise = do
      codes <- forM (nub ids) $ \i -> do
        r <- deletePlanAnyRoot cfg (T.pack i)
        case r of
          Left m -> putStrLn ("  ✗ " <> i <> ": " <> m) >> pure 2
          Right label -> putStrLn ("  ✓ 已删除计划 " <> i <> "（" <> label <> "；journal/undo 不受影响，需要可重新生成）") >> pure 0
      pure (maximum (0 : codes))

-- | @pm plan prune@：一键清理已执行（'prunePlans'）。
runPlanPrune :: Config -> IO Int
runPlanPrune cfg = do
  (deleted, errs) <- prunePlans cfg
  forM_ deleted $ \(label, p) ->
    putStrLn ("  ✓ 已清理 " <> T.unpack (plId p) <> "（" <> T.unpack (plKind p) <> "，" <> label <> "）")
  forM_ errs $ \e -> putStrLn ("  ⚠ " <> e)
  putStrLn
    ( if null deleted
        then "没有可清理的已执行计划（未执行的草稿用 pm plan rm <id> 删）"
        else "共清理 " <> show (length deleted) <> " 份；journal/undo 不受影响。"
    )
  pure (if null errs then 0 else 1)
