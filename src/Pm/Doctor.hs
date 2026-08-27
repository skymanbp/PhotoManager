{-# LANGUAGE OverloadedStrings #-}

-- | Crash-recovery reconciliation (DESIGN.md §6.4 matrix C1-C5 / R1-R3 /
-- Q1-Q2 + C4 verification window). Default run is READ-ONLY and reports; the
-- explicit @--repair@ pass applies only the safe closures: appending a
-- journal Done that disk content proves, deleting pm's own never-renamed tmp
-- files, and — for C5 — emitting a quarantine PLAN so anything touching user
-- data still goes through the normal confirm+apply machinery.
module Pm.Doctor
  ( DoctorOpts (..)
  , Severity (..)
  , Finding (..)
  , runDoctor
  , renderFinding
  ) where

import Control.Monad (filterM, forM, forM_, unless)
import Control.Exception (IOException, bracket, try)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.IO (hClose)
import System.IO.Error (isDoesNotExistError)
import System.FilePath (joinPath, makeRelative, splitDirectories, (</>))

import Pm.Catalog (CatalogLoad (..), loadCatalog)
import Pm.Config (pmDir, pmSubTmp, pmSubTrash, readRootInfo, requireWritable)
import Pm.Exec (dirFingerprint, tmpDirFor, tmpNameFor)
import Pm.Hash (sha256File, sha256Handle)
import Pm.Journal
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Trash
import Pm.Types
import Pm.Win (NameKind (..), deleteBoundAt, openStateRead, probeName, resolveUnder)

data DoctorOpts = DoctorOpts
  { doDeep :: Bool
  , doRepair :: Bool
  }

data Severity = Info | Warn | Bad
  deriving (Show, Eq, Ord)

data Finding = Finding
  { fRow :: String -- matrix row / category tag
  , fSeverity :: Severity
  , fDetail :: String
  , fRepair :: String -- what --repair would / did do ("" = nothing)
  }

renderFinding :: Finding -> String
renderFinding f =
  sevTag (fSeverity f)
    <> " ["
    <> fRow f
    <> "] "
    <> fDetail f
    <> (if null (fRepair f) then "" else "\n      修复: " <> fRepair f)
 where
  sevTag Info = "  ·"
  sevTag Warn = "  ⚠"
  sevTag Bad = "  ✗"

-- | Returns (findings, exit code). Repairs (when requested) happen inside.
--
-- 三十轮 F2：@--repair@ 的「读 journal → 判定 → 补记 Done/删 tmp」是一次
-- 跨进程 RMW——判定用的视图若在锁外取，另一份已批准计划可以在判定与补记之间
-- 把世界改掉，doctor 随后补写的就是过时 Done。整段进 I10 锁。次序与
-- 'Pm.Exec.execPlan' 相同（P3b-6）：先零写入预检，root 不可写连锁文件都不落；
-- 锁内 runDoctor' 里的 requireWritable 复检保留（预检与取锁之间被改仍拒绝）。
-- 取不到锁 → 退回只读诊断 + 一条 I10 Bad，不做任何修复。
runDoctor :: FilePath -> DoctorOpts -> IO ([Finding], Int)
runDoctor root opts
  | doRepair opts = do
      w <- requireWritable root
      case w of
        Left m -> diagnoseOnly (Finding "I11" Bad ("--repair 拒绝执行（root 不可写）: " <> m) "")
        Right _ -> do
          r <- withRootLock root (runDoctor' root opts)
          case r of
            Just x -> pure x
            Nothing ->
              diagnoseOnly
                (Finding "I10" Bad "--repair 需要 root 独占锁，另一个 pm 实例正持有——本轮只诊断，未做任何修复" "")
  | otherwise = runDoctor' root opts
 where
  diagnoseOnly f = do
    (fs, _) <- runDoctor' root opts {doRepair = False}
    let all' = fs <> [f]
    pure (all', if maximum (Info : map fSeverity all') >= Warn then 1 else 0)

runDoctor' :: FilePath -> DoctorOpts -> IO ([Finding], Int)
runDoctor' root opts = do
  (entries, jwarns) <- readJournal root
  let journalFindings =
        [ Finding
            (if take 4 w == "torn" then "TORN" else "JOURNAL")
            (if take 4 w == "torn" then Warn else Bad)
            w
            ""
        | w <- jwarns
        ]
      -- P2.3（复审三轮）：pending 判定**次序感知**——同 oid 重跑会多次出现
      -- Intent/Terminal，一个 oid 是否悬挂由其**最后一个事件**决定（末事件
      -- 是 Intent → pending）。旧的全局差集会让上一轮的 terminal 吞掉本轮
      -- 崩溃留下的新 Intent（复位重跑反例）。
      opState =
        foldl
          ( \m e -> case e of
              JIntent i op _ -> Map.insert i (op, True) m
              JDone i _ _ _ -> Map.adjust (\(op, _) -> (op, False)) i m
              JFailed i _ _ -> Map.adjust (\(op, _) -> (op, False)) i m
              _ -> m
          )
          Map.empty
          entries
      intents = fmap fst opState
      -- Done entries after the LAST clean-shutdown marker = the verification
      -- window for an interrupted batch (§6.4).
      afterClean = lastSegment entries
      donesAfterClean = [(jeOpId e, jeVerifiedSha e, jeTrashRel e) | e@JDone {} <- afterClean]
      -- pending = 末事件为 Intent 的 oid（见上 opState 的次序感知语义）
      pending = [(i, op) | (i, (op, True)) <- Map.toList opState]
      -- Exec 组内自动复位（§6.5）/undo 复位会把隔离文件从 trash 移回原位，
      -- 且该 rename 有自己的 Intent+Done。P2.2（复审新发现）：豁免必须
      -- **顺序感知**——只有当 oid 的最后一次 Done 之后还有对应 ~r 复位 Done
      -- 时，trash 目标缺席才是复位所致；同计划复位后重跑成功的第二次隔离
      -- （Done 晚于旧 ~r）仍须核查，全局豁免会把它吞掉。
      lastDonePos =
        Map.fromListWith
          max
          [(jeOpId e, p) | (p, e@JDone {}) <- zip [0 :: Int ..] entries]
      -- P3b-7 复审 A1：复位配对经 opIdParts 解析（不再 oid <> "~r" 弱拼接）；
      -- 只有规范的用户可见 oid 才有复位配对。
      restoredAfterLastDone oid = case opIdParts oid of
        Just (pid, ix, SfxPlain) ->
          case (Map.lookup oid lastDonePos, Map.lookup (restoreOpId pid ix) lastDonePos) of
            (Just q, Just r) -> r > q
            _ -> False
        _ -> False

  pendingFindings <- concat <$> mapM (classifyPending root) pending
  c4Findings <- concat <$> mapM (verifyDone root intents restoredAfterLastDone) donesAfterClean

  -- Trash reconciliation (Q1 + purged records)
  -- 三十五轮 F3（同型扫尽收尾）：trash/tmp 的枚举此前裸奔——doctor 是恢复
  -- 工具，读口异常逃顶让它在最需要的时刻崩掉。枚举失败 → 专用 Bad 行
  -- （TRASH-ENUM/TMP-ENUM 不在 --repair 的 Warn 白名单，oid 前缀判据也
  -- 不匹配，进不了任何修复推导）；stale 清单按空处理 = --repair 零删除。
  etv <- trashView root
  let (q1, manifestWarns) = case etv of
        Left e ->
          ([Finding "TRASH-ENUM" Bad ("trash 枚举/manifest 读取失败——Q1 对账本轮核不了: " <> e) "解除占用后重跑 pm doctor"], [])
        Right tv ->
          ( [ Finding "Q1" Warn ("trash 中无 manifest 记录的文件: " <> f) ""
            | f <- tvUnregistered tv
            ]
          , [Finding "TRASH-MANIFEST" Bad w "" | w <- tvWarnings tv]
          )

  -- Stale tmp files not tied to any pending intent
  estale <- staleTmpFiles root (mapMaybe (pendingTmp root) pending)
  let (stale, staleFindings) = case estale of
        Left e ->
          ([], [Finding "TMP-ENUM" Bad ("tmp 枚举失败——孤儿 tmp 本轮核不了: " <> e) "解除占用后重跑 pm doctor"])
        Right fs ->
          ( fs
          , [ Finding "TMP-STALE" Warn ("孤儿临时文件: " <> f) "--repair 将删除（pm 自建 tmp，非用户数据）"
            | f <- fs
            ]
          )

  -- Catalog verification age. 工作流 F032：快照通道此前是本函数唯一被丢掉的
  -- 降级信号（journal/manifest/枚举失败各有自己的行）——被拒的快照按行报
  -- Bad，回退跳过的坏代报 Warn；--deep 在没有快照时不得沉默（它一个字节都
  -- 没核）。缺席（从未扫描）本身不是发现。
  lc <- loadCatalog root
  let deepSkipped why = [Finding "DEEP-SKIPPED" Bad ("--deep 全库复核本轮未执行（" <> why <> "）") "先 pm scan 重建后重跑" | doDeep opts]
  ageFinding <- case lc of
    CatAbsent -> pure (deepSkipped "尚无索引")
    CatRefused ws ->
      pure ([Finding "CATALOG" Bad w "排除原因后重试，或 pm scan 重建；快照被拒说明有人手编过或介质出错" | w <- ws] <> deepSkipped "快照载入失败")
    CatLoaded cat ws -> do
      deepFindings <- if doDeep opts then deepVerify root cat else pure []
      let nUnverified = length [() | e <- Map.elems (catEntries cat), enLastVerified e == Nothing]
      pure
        ( [Finding "CATALOG" Warn ("快照坏代已跳过（本轮按较旧一代核对）: " <> w) "pm scan 重建" | w <- ws]
            <> [Finding "VERIFY-AGE" Info (show (Map.size (catEntries cat)) <> " 条目; 无验证时间戳条目 " <> show nUnverified) ""]
            <> deepFindings
        )

  let findings0 =
        journalFindings <> pendingFindings <> c4Findings <> q1 <> manifestWarns <> staleFindings <> ageFinding

  -- P3b-7 复审新 major：--repair 会写 journal / 删自建 tmp / 生成计划，属
  -- .pm 写入口——root 必须有可解析身份且过 I11（requireWritable），否则
  -- 只报告不修。
  repairFindings <-
    if doRepair opts
      then do
        w <- requireWritable root
        case w of
          Left m -> pure [Finding "I11" Bad ("--repair 拒绝执行（root 不可写）: " <> m) ""]
          Right _ -> [] <$ applyRepairs root findings0 pending stale
      else pure []

  let allFindings = findings0 <> repairFindings
      worst = maximum (Info : map fSeverity allFindings)
      code = if worst >= Warn then 1 else 0
  pure (allFindings, code)

-- Entries after the last JCleanShutdown (whole list if none).
lastSegment :: [JEntry] -> [JEntry]
lastSegment es = go es es
 where
  go acc [] = acc
  go _ (JCleanShutdown _ : rest) = go rest rest
  go acc (_ : rest) = go acc rest

-- | Copy 的 tmp 路径只对无后缀的用户可见 oid 有定义（'opIdParts' 统一解析，
-- P3b-6 复审 A1）。P3b-10（七轮复审 minor）：Op 路径也先过 'opPathsOk'——
-- 'tmpNameFor' 只取 takeFileName，普通 @..@ 穿越到不了 @.pm\/tmp@ 之外，但
-- 非法 Op 不该参与"预期 tmp 集合"的计算（否则会影响 TMP-STALE 判定）。
pendingTmp :: FilePath -> (Text, Op) -> Maybe FilePath
pendingTmp root (oid, op@(OpCopy _ dstRel _ _ _)) = case opIdParts oid of
  Just (pid, ix, SfxPlain) | opPathsOk op -> Just (tmpDirFor root pid </> tmpNameFor ix dstRel)
  _ -> Nothing
pendingTmp _ _ = Nothing

-- | P3b-7 复审 A1：opId 不合 pm 语法（手编 journal）→ 单独一条 Bad，不做任何
-- 盘面推导（tmp/trash 路径都由 oid 推出，猜错就会把无关文件认证成已完成）。
-- P3b-8 六轮复审 major：Op 自带的相对路径（victim/dstRel/old/new）同为手编
-- 输入，拼上 root 前先过 'opPathsOk'——否则合法 oid + @..\/..\/x@ 路径仍能让
-- doctor 在 root 外探测/核 sha，--repair 还会补 Done 或生成 C5 计划。
classifyPending :: FilePath -> (Text, Op) -> IO [Finding]
classifyPending root (oid, op)
  | Nothing <- opIdParts oid =
      pure [Finding "OID-MALFORMED" Bad (T.unpack oid <> ": journal 中的 opId 不是 pm 生成的语法，不推导、不修复（需人工核查）") ""]
  | not (opPathsOk op) =
      pure [Finding "OP-PATH" Bad (T.unpack oid <> ": journal 中的 Op 相对路径非法（越界/盘符/ADS/.pm 内部），不推导、不修复（需人工核查）") ""]
  | otherwise = classifyPending' root (oid, op)

-- | @.pm@ 内定点路径（trash 载荷 \/ tmp）的受信探测（P3b-15，十二轮 major）：
-- 完整路径 'resolveUnder' + 'openStateRead'（句柄 link count）+ **同一句柄**
-- hash。此前这里直接 @doesFileExist@\/@sha256File@——trash 载荷被换成指向库外
-- 同内容文件的 symlink\/hardlink 时，doctor 会"核验通过"并让 @--repair@ 补写
-- **虚假的 Done**，把从未落位的隔离认证成已完成。
-- 三态：@PmStateBad@=不可信（只报 Bad，不参与任何 repair 推导）、
-- @PmStateMissing@=缺席、@PmStateSha@=可信内容的 sha。
data PmProbe = PmStateBad String | PmStateMissing | PmStateSha Text

probePmSha :: FilePath -> FilePath -> IO PmProbe
probePmSha root rel = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> pure (PmStateBad (rel <> " 不是 root 下的真实路径（junction/symlink？）"))
    Just fp -> do
      r <- try (bracket (openStateRead fp) hClose sha256Handle) :: IO (Either IOException Text)
      pure $ case r of
        Right sha -> PmStateSha sha
        Left e
          | isDoesNotExistError e -> PmStateMissing
          | otherwise -> PmStateBad (rel <> " 无法可信读取（" <> show e <> "）")

-- | @.pm@ 内定点路径的**存在性**受信探测。问的是哪一种存在必须由调用点显式
-- 说明——P3b-17（十四轮 major）的成因正是它此前不必说：十三轮把复位源的
-- 'existsAny'（文件**或**目录）换成受信探针时只写了 @doesFileExist@，谓词在
-- 安全重构里**被悄悄收窄**。'Pm.Op.OpRename' 合法支持 'FpDir'（'Pm.Names' 的
-- 目录改名计划就是这一种，执行端也确实 stat/hash/move 目录），于是 trash 里
-- **真实存在的目录**复位源被判成"不存在"，与存在且指纹相符的 @new@ 组合成
-- R2 Warn，@--repair@ 随即补写**虚假 Done**（正确格是 R3，不进任何修复线）。
data PmEntryQ
  = -- | 只认普通文件（pm 自建的 tmp 落位点）
    PmEntryFile
  | -- | 任何目录项，文件或目录（'existsAny' 的受信对偶）
    PmEntryAny

probePmExists :: PmEntryQ -> FilePath -> FilePath -> IO (Either String Bool)
probePmExists q root rel = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> pure (Left (rel <> " 不是 root 下的真实路径（junction/symlink？）"))
    Just fp ->
      Right <$> case q of
        PmEntryFile -> doesFileExist fp
        PmEntryAny -> existsAny fp

classifyPending' :: FilePath -> (Text, Op) -> IO [Finding]
classifyPending' root (oid, op) = case op of
  OpCopy _ dstRel sha _ _ -> do
    let dstAbs = root </> dstRel
    dstEx <- doesFileExist dstAbs
    if dstEx
      then do
        -- 三十四轮（同型扫尽）：doctor 是恢复工具，读口异常逃顶让它在最需要
        -- 的时刻崩掉。dst 读不出 → 判不出 C2/C5，报 Bad 行「C?」——既不在
        -- --repair 的 Warn 白名单（C2/R2/Q-DONE-LOST）也不是 C5 行，不触发
        -- 任何修复推导（fail-closed），稍后重跑。
        dshaE <- try (sha256File dstAbs) :: IO (Either IOException Text)
        case dshaE of
          Left e -> pure [Finding "C?" Bad (T.unpack oid <> ": dst 读取失败（" <> show e <> "），C2/C5 判不出——稍后重跑 pm doctor") ""]
          Right dsha
            | dsha == sha -> pure [Finding "C2" Warn (T.unpack oid <> ": dst 完好、Done 丢失 (" <> dstRel <> ")") "--repair 将补记 Done"]
            | otherwise -> pure [Finding "C5" Bad (T.unpack oid <> ": dst 存在但内容不符 (" <> dstRel <> ")") "--repair 将生成 dst 隔离计划（经 pm apply 确认执行），源文件未受影响"]
      else do
        -- P3b-15：.pm/tmp 的存在性探测也走受信解析（此前 doesFileExist 会
        -- 跟随链接，影响 C1 的分类文本；不涉及写，但同规则无例外）。
        -- tmp 问的是 @PmEntryFile@：落位点是 pm 自建的**普通文件**，
        -- 'staleTmpFiles' 的清理也只收 NamePlain 文件。目录占名时报"无痕迹"
        -- 而不是"中断于写 tmp"，是保守方向（--repair 不会去动那个目录）。
        etmp <- case pendingTmp root (oid, op) of
          Nothing -> pure (Right False)
          Just tmpAbs -> probePmExists PmEntryFile root (makeRelative (pmDir root) tmpAbs)
        case etmp of
          Left m -> pure [Finding "PM-LINK" Bad (T.unpack oid <> ": " <> m <> "，不推导、不修复（需人工核查）") ""]
          -- 第一方自审工作流 F034：修复文案必须来自实现它的谓词——在途 Intent 的
          -- tmp 被 'staleTmpFiles' 按 pending 排除，--repair 的删除循环只吃 stale；
          -- 此前文案许诺「将清除 tmp」而循环里根本没有它（DESIGN §6.4 C1 也只说
          -- 报告 + 重跑）。「续传」同样不实：重跑走独占创建，从零重写。
          Right True -> pure [Finding "C1" Warn (T.unpack oid <> ": 中断于写 tmp 阶段 (" <> dstRel <> ")") "--repair 不清除该 tmp（在途 Intent 的证据）；重跑原计划即可（重写从零开始，落位前覆盖它）"]
          Right False -> pure [Finding "C1" Info (T.unpack oid <> ": Intent 后无痕迹（写 tmp 前中断），重跑原计划即可") ""]
  OpRename old new fp -> do
    -- P3b-16（十三轮 major）：`old` 允许是 @.pm/trash/…@（undo/组复位的复位
    -- 源，'Pm.Op.isTrashSrcRel' 明确的唯一例外），而这里此前对它用裸
    -- `existsAny`。把 @.pm/trash/<pid>@ 换成指向空目录的 junction，旧路径就被
    -- 判成"不存在"；再让用户目标的指纹相符，就得到 R2 Warn，`--repair` 随即
    -- 补写**虚假的 Done**——把从未发生的复位认证成已完成。
    -- `.pm` 侧一律走受信探测，失信只报 PM-LINK Bad（不进入 R 矩阵，因此也
    -- 进不了 repairDone 的 R2 Warn 白名单）。
    -- 剥掉首个 @.pm@ 分量得到 @.pm@ 相对路径。不用 makeRelative：
    -- 'isTrashSrcRel' 是**折大小写**判定的，@.PM\/trash\/…@ 合法，而
    -- makeRelative 的词法比较区分大小写，那种形态会剥不掉、把绝对路径拼进去。
    -- P3b-17（十四轮 major）：问的必须是 @PmEntryAny@——`existsAny` 一直含
    -- 目录，而 rename 的两侧都可以是目录（FpDir）。收窄成"文件存在"会把真实
    -- 存在的目录复位源判成缺席，把 R3 错报成 R2 Warn 并被 --repair 补假 Done。
    -- 第一方自审工作流 F033：用户侧也三态。`existsAny`（doesFileExist ||
    -- doesDirectoryExist）把 ACL 拒绝塌成 False——目录级全拒时 old 被判「不在」，
    -- 与「new 在且指纹相符」组成 (False, True) 格，R3 错报成 R2 Warn，恰在
    -- --repair 白名单里 → 补一条与真 Done 逐字节相同的假 Done，进 undo。
    -- 'probeName' 不受对象自身 ACL 影响（三十九轮实测）；查不出 → Left →
    -- PM-LINK Bad（白名单之外）。链接占名算「在」（保守：只会把格推向 R3/R?）。
    eOldEx <-
      if isTrashSrcRel old
        then probePmExists PmEntryAny root (joinPath (drop 1 (splitDirectories old)))
        else userSideExists (root </> old)
    eNewEx <- userSideExists (root </> new)
    case (,) <$> eOldEx <*> eNewEx of
      Left m -> pure [Finding "PM-LINK" Bad (T.unpack oid <> ": " <> m <> "，不推导、不修复（需人工核查）") ""]
      Right (oldEx, newEx) ->
        case (oldEx, newEx) of
          (True, False) -> pure [Finding "R1" Info (T.unpack oid <> ": rename 未执行 (" <> old <> " → " <> new <> ")，重跑原计划即可") ""]
          (False, True) -> do
            eok <- verifyFp (root </> new) fp
            pure $ case eok of
              Left e -> [Finding "R2" Bad (T.unpack oid <> ": rename 目标读取失败（" <> e <> "），本轮核不了——稍后重跑 pm doctor") ""]
              Right True -> [Finding "R2" Warn (T.unpack oid <> ": rename 已执行、Done 丢失 (" <> new <> ")") "--repair 将补记 Done"]
              Right False -> [Finding "R2" Bad (T.unpack oid <> ": rename 目标存在但指纹不符 (" <> new <> ")，需人工核查") ""]
          (True, True) -> pure [Finding "R3" Warn (T.unpack oid <> ": rename 未执行且目标被占 (" <> new <> ")" ) "解决占用后重新生成计划"]
          (False, False) -> pure [Finding "R?" Bad (T.unpack oid <> ": 新旧路径都不存在，超出矩阵，需人工核查") ""]
  OpQuarantine victim sha _ -> do
    -- P3b-4 评审 #1：trash 路径推导与 Exec 共用（quarDirFor / quarTrashRel，
    -- ~d 位移隔离落 <planId>~displaced-N/，各推各的会在这里指错目录）。
    -- oid 已在 classifyPending 验过语法，此处 Nothing 不可达；仍按 Bad 处理。
    let mTrashRel = quarTrashRel oid victim
    trashRel <- maybe (pure "") pure mTrashRel
    -- P3b-15（十二轮 major）：trash 载荷经受信探测核 sha——此前按名字
    -- doesFileExist + sha256File，载荷被换成指向库外同内容文件的 symlink/
    -- hardlink 时会"核验通过"，--repair 随即补写虚假 Done。
    tprobe <-
      if isJust mTrashRel
        then probePmSha root (pmSubTrash </> trashRel)
        else pure PmStateMissing
    victimEx <- doesFileExist (root </> victim)
    case (tprobe, victimEx) of
      (PmStateBad m, _) ->
        pure [Finding "PM-LINK" Bad (T.unpack oid <> ": " <> m <> "，不推导、不修复（需人工核查）") ""]
      (PmStateSha tsha, _) ->
        -- P3b-5 复审 #1：补记 Done 前必须核 sha——trash 位置上可能是别的
        -- 内容（同路径重试残留），盲补会把错误内容认证成「已隔离」。
        pure
          [ if tsha == sha
              then Finding "Q-DONE-LOST" Warn (T.unpack oid <> ": 已入 trash、Done 丢失 (" <> trashRel <> ")") "--repair 将补记 Done"
              else Finding "Q-DONE-LOST" Bad (T.unpack oid <> ": trash 位置内容与 Intent sha 不符 (" <> trashRel <> ")，需人工核查") ""
          ]
      (PmStateMissing, True) -> do
        -- 三十四轮（同型扫尽）：victim 读不出时如实说"读不出"（Q2 不进任何
        -- 修复推导，note 只影响文本）。
        vshaE <- try (sha256File (root </> victim)) :: IO (Either IOException Text)
        let note = case vshaE of
              Left e -> "victim 原位读取失败（" <> show e <> "，被占？稍后重跑）"
              Right vsha -> if vsha == sha then "victim 原位完好" else "victim 原位但内容已变"
        pure [Finding "Q2" Info (T.unpack oid <> ": 隔离未执行，" <> note <> "，重跑原计划即可") ""]
      (PmStateMissing, False) -> pure [Finding "Q?" Bad (T.unpack oid <> ": victim 与 trash 均不存在，需人工核查") ""]

existsAny :: FilePath -> IO Bool
existsAny p = do
  f <- doesFileExist p
  if f then pure True else doesDirectoryExist p

-- | 用户侧路径的三态存在性（第一方自审工作流 F033）：'probeName' 走
-- GetFileAttributes，对象自身的 ACL 拒绝不影响它；查不出即 Left。
userSideExists :: FilePath -> IO (Either String Bool)
userSideExists p = do
  k <- probeName p
  pure $ case k of
    NameMissing -> Right False
    NamePlain -> Right True
    NameSurrogate -> Right True
    ProbeUnknown -> Left (p <> " 存在性查不出（ACL/介质错误？）")

-- | 三十四轮（同型扫尽）：读失败 ≠ 指纹不符——两者的下一步不同（稍后重跑
-- vs 人工核查），折叠成 False 会把占用误报成内容问题；Left 由调用方报
-- Bad（不进 --repair 的 Warn 白名单）。
verifyFp :: FilePath -> Fingerprint -> IO (Either String Bool)
verifyFp p (FpFileSha s) = do
  isF <- doesFileExist p
  if not isF
    then pure (Right False)
    else do
      r <- try (sha256File p) :: IO (Either IOException Text)
      pure (either (Left . show) (Right . (== s)) r)
verifyFp p (FpDir s) = do
  isD <- doesDirectoryExist p
  if not isD
    then pure (Right False)
    else do
      r <- try (dirFingerprint p) :: IO (Either IOException Text)
      pure (either (Left . show) (Right . (== s)) r)

-- C4: an interrupted batch's Done claims re-verified against disk.
-- @restoredAfter oid@ = 该 oid 的最后一次 Done 之后存在对应 ~r 复位 Done
-- （§6.5 自动复位 / P2.2 顺序感知配对）——此时 trash 目标缺席是复位所致，
-- 免于 C4；否则照常核查。
verifyDone :: FilePath -> Map.Map Text Op -> (Text -> Bool) -> (Text, Maybe Text, Maybe FilePath) -> IO [Finding]
verifyDone root intents restoredAfter (oid, msha, mtrash) =
  case Map.lookup oid intents of
    Nothing -> pure [Finding "C3" Info (T.unpack oid <> ": Done 无对应 Intent（journal 头部轮转或跨批），跳过") ""]
    -- P3b-8 六轮复审 major：Intent 的 Op 路径与 Done 的 trash 路径都是手编
    -- 输入，拼上 root 前先验（同 classifyPending 的 OP-PATH fail-closed）。
    Just op
      | not (opPathsOk op) ->
          pure [Finding "OP-PATH" Bad (T.unpack oid <> ": journal 中的 Op 相对路径非法（越界/盘符/ADS/.pm 内部），Done 不核查（需人工核查）") ""]
      | otherwise -> case (op, msha) of
          (OpCopy _ dstRel _ _ _, Just sha) -> checkTarget (root </> dstRel) dstRel sha
          (OpQuarantine _ _ _, Just sha)
            | Just trashRel <- mtrash ->
                if not (relPathOk trashRel)
                  then pure [Finding "OP-PATH" Bad (T.unpack oid <> ": Done 记录的 trash 路径非法（" <> trashRel <> "），不核查（需人工核查）") ""]
                  else
                    if restoredAfter oid
                      then
                        pure
                          [Finding "Q-RESTORED" Info (T.unpack oid <> ": 隔离后已被 journaled 复位（" <> trashRel <> "），无需核查") ""]
                      else checkTrashTarget trashRel sha
          _ -> pure [] -- rename Done carries no content claim
 where
  -- 用户数据目标（root 下的 dstRel）：doctor 读用户文件核 sha 是它的本职。
  checkTarget abs' rel sha = do
    ex <- doesFileExist abs'
    if not ex
      then pure [Finding "C4" Bad (T.unpack oid <> ": Done 记录的目标不存在 (" <> rel <> ")") "不删任何东西；该项标回未确认，重新生成计划"]
      else do
        -- 三十四轮（同型扫尽）：读失败按"本轮核不了"报 Bad，不折叠成 CORRUPT。
        actualE <- try (sha256File abs') :: IO (Either IOException Text)
        case actualE of
          Left e -> pure [Finding "C4" Bad (T.unpack oid <> ": Done 目标读取失败（" <> show e <> "），本轮核不了——稍后重跑 pm doctor") ""]
          Right actual
            | actual == sha -> pure []
            | otherwise ->
            pure
              [ Finding
                  "C4"
                  Bad
                  (T.unpack oid <> ": CORRUPT — Done 记录 sha 与盘面不符 (" <> rel <> ")")
                  "不删任何东西；将该目标视为未确认副本，重新拷贝并核查介质"
              ]
  -- .pm/trash 内的目标（P3b-15）：走受信探测，链接形态只报 Bad 不核证。
  checkTrashTarget trashRel sha = do
    p <- probePmSha root (pmSubTrash </> trashRel)
    case p of
      PmStateBad m -> pure [Finding "PM-LINK" Bad (T.unpack oid <> ": " <> m <> "，Done 不核查（需人工核查）") ""]
      PmStateMissing -> pure [Finding "C4" Bad (T.unpack oid <> ": Done 记录的目标不存在 (" <> trashRel <> ")") "不删任何东西；该项标回未确认，重新生成计划"]
      PmStateSha actual
        | actual == sha -> pure []
        | otherwise ->
            pure
              [ Finding
                  "C4"
                  Bad
                  (T.unpack oid <> ": CORRUPT — Done 记录 sha 与盘面不符 (" <> trashRel <> ")")
                  "不删任何东西；将该目标视为未确认副本，重新拷贝并核查介质"
              ]

-- | @.pm\/tmp@ 下 pm 自建、已无对应在途计划的孤儿 tmp——@--repair@ 会 unlink
-- 它们。
--
-- P3b-11（八轮复审 major，探针实证）：遍历**逐级 no-follow**。@.pm\/tmp@ 或
-- 其下的 @\<planId\>@ 目录若是指向库外的 junction，@listDirectory@ 会穿透、
-- 随后的 @removeFile@ **真的删掉库外文件**（探针把库外 hostage.txt 删掉了）。
-- 链接本体既不递归也不列出：不列 = 不删（fail-closed），它会以 doctor 的
-- 其它行\/人工核查暴露；'Pm.Config.requirePmTrusted' 在写入口拒绝这种 root。
-- P3b-14（十一轮 #4）：判据从 'isNameSurrogate'（Unknown 算 False，会把"查不出
-- 是什么"的名字当普通文件送去 --repair 删除）改为 'probeName' 只放行
-- **明确的** NamePlain——不进列表 = 不删，与"链接本体不列出"同一 fail-closed。
-- 三十五轮 F3：枚举包 try（Either 化）——probeName/doesDirectoryExist 守卫
-- 与 listDirectory 之间有窗口，目录被占/被挪时异常会让整个 doctor 崩掉。
-- Left 由调用方报 TMP-ENUM Bad 且 stale 清单按空处理（--repair 零删除）。
staleTmpFiles :: FilePath -> [FilePath] -> IO (Either String [FilePath])
staleTmpFiles root expected = do
  let base = pmDir root </> pmSubTmp
  basePlain <- (== NamePlain) <$> probeName base
  ex <- doesDirectoryExist base
  if not basePlain || not ex
    then pure (Right [])
    else do
      r <- try $ do
        plans <- listDirectory base
        files <- concat <$> forM plans (\p -> do
          let pd = base </> p
          pk <- probeName pd
          isD <- doesDirectoryExist pd
          if pk /= NamePlain
            then pure []
            else
              if isD
                then do
                  inner <- listDirectory pd
                  filterM (fmap (== NamePlain) . probeName) (map (pd </>) inner)
                else pure [pd])
        onlyFiles <- filterM doesFileExist files
        pure [f | f <- onlyFiles, f `notElem` expected]
      pure $ case (r :: Either IOException [FilePath]) of
        Left e -> Left (show e)
        Right fs -> Right fs

deepVerify :: FilePath -> Catalog -> IO [Finding]
deepVerify root cat = do
  results <- forM (Map.elems (catEntries cat)) $ \e -> do
    let abs' = root </> enPath e
    ex <- doesFileExist abs'
    if not ex
      then pure [Finding "DEEP" Warn ("条目在盘上消失: " <> enPath e) "跑 pm scan 刷新索引"]
      else do
        -- 三十四轮（同型扫尽）：--deep 扫全库、窗口以分钟计，一个被占的
        -- 文件不该让整轮诊断崩掉；读失败也不得折叠成 CORRUPT（下一步不同：
        -- 稍后重跑 vs 核查介质）。
        actualE <- try (sha256File abs') :: IO (Either IOException Text)
        pure $ case actualE of
          Left ioe ->
            [Finding "DEEP" Warn ("条目读取失败（被占/介质？）: " <> enPath e <> "（" <> show ioe <> "）") "稍后重跑 pm doctor --deep"]
          Right actual ->
            [ Finding "DEEP-CORRUPT" Bad ("内容与索引 sha 不符: " <> enPath e) "核查介质；如源仍在他处，重新拷贝"
            | actual /= enSha e
            ]
  pure (concat results)

-- Safe closures only (journal appends / own-tmp deletion). C5 plans are
-- emitted, not executed.
applyRepairs :: FilePath -> [Finding] -> [(Text, Op)] -> [FilePath] -> IO ()
applyRepairs root findings pending stale = do
  let repairDone =
        [ (oid, op)
        | (oid, op) <- pending
        , isJust (opIdParts oid) -- P3b-7：畸形 oid 永不补记
        , opPathsOk op -- P3b-8 六轮：非法 Op 路径永不补记（classifyPending 已拦，双保险）
        , any (\f -> fRow f `elem` ["C2", "R2", "Q-DONE-LOST"] && (T.unpack oid <> ":") `isPrefixOfStr` fDetail f && fSeverity f == Warn) findings
        ]
      c5 =
        [ (oid, op)
        | (oid, op) <- pending
        , opPathsOk op -- P3b-8 六轮：C5 隔离计划的 dstRel 同样不得越界
        , any (\f -> fRow f == "C5" && (T.unpack oid <> ":") `isPrefixOfStr` fDetail f) findings
        ]
  unless (null repairDone) $
    withJournal root $ \j ->
      forM_ repairDone $ \(oid, op) -> do
        now <- getCurrentTime
        -- trash 路径由 oid 解析推导（repairDone 已过滤畸形 oid，此处必为 Just）
        let (sha, trash) = case op of
              OpCopy _ _ s _ _ -> (Just s, Nothing)
              OpQuarantine v s _ -> (Just s, quarTrashRel oid v)
              _ -> (Nothing, Nothing)
        jAppend j Barrier (JDone oid sha trash now)
        putStrLn ("  修复: 补记 Done " <> T.unpack oid)
  forM_ stale $ \f -> do
    -- P3b-14（十一轮 #4）：删除前对完整相对路径再过一次 'resolveUnder'——
    -- staleTmpFiles 枚举与这里的 unlink 之间有窗口，且枚举本身只按层探测。
    -- 解析不出就跳过（不删 = fail-closed），以 doctor 文本暴露给人工。
    m <- resolveUnder root (makeRelative root f)
    case m of
      Nothing -> putStrLn ("  跳过: " <> f <> " 不再是可信路径（junction/symlink？），不删除——人工核查")
      Just fp -> do
        -- pm 自建的 .pm/tmp 文件，从未 rename 落位，非用户数据（P6-C 句柄形态）。
        -- 第一方自审工作流 C102（同型）：unlink 会抛（占用超预算/只读属性）；
        -- 逃顶会连带放弃后面的 C5 计划生成。逐项 try、报出、继续。
        r <- try (deleteBoundAt fp) :: IO (Either IOException ())
        putStrLn $ case r of
          Right () -> "  修复: 清除孤儿 tmp " <> f
          Left e -> "  ✗ 孤儿 tmp 未清除（" <> show e <> "）: " <> f <> " —— 解除占用/只读后重跑"
  forM_ c5 $ \(oid, op) -> case op of
    OpCopy _ dstRel _ _ _ -> do
      -- 三十四轮（同型扫尽）：隔离计划记录的是 victim 当下的 sha，读不出就
      -- 生成不了（也不能拿 Intent 的 sha 顶替——C5 的前提正是内容不符）；
      -- 跳过该项并明说（fail-closed），稍后重跑。
      actualE <- try (sha256File (root </> dstRel)) :: IO (Either IOException Text)
      case actualE of
        Left e -> putStrLn ("  跳过: C5 隔离计划未生成（dst 读取失败: " <> show e <> "）——稍后重跑 pm doctor --repair")
        Right actual -> do
          pid <- newPlanId
          now <- getCurrentTime
          minfo <- readRootInfo root
          let p =
                Plan
                  { plId = pid
                  , plKind = "doctor-c5-quarantine"
                  , plRootPath = root
                  , plRootId = riId <$> minfo
                  , plCreated = now
                  , plItems =
                      [PlanItem 0 (OpQuarantine dstRel actual ("doctor-c5:" <> oid)) StPending Nothing]
                  }
          fp <- savePlan p
          putStrLn ("  修复: C5 隔离计划已生成 " <> fp <> " → 审阅后 pm apply " <> T.unpack pid)
    _ -> pure ()

isPrefixOfStr :: String -> String -> Bool
isPrefixOfStr p s = take (length p) s == p
