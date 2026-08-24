{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | ★ The safety kernel — the ONLY module that mutates user-visible files
-- (DESIGN.md §4, §6). Every landing is a fail-if-exists rename; every
-- mutation is journaled Intent-before-effect with real disk barriers; there
-- is no delete call anywhere except the one §6.1 footnote allows (our own
-- unrenamed tmp file).
--
-- 'Checkpoint's are called OUTSIDE all exception handling: the fault
-- injection tests throw from them to simulate a crash at every protocol
-- step, and those exceptions must escape exactly like a real crash would.
module Pm.Exec
  ( ExecEnv (..)
  , defaultExecEnv
  , Checkpoint (..)
  , ItemOutcome (..)
  , execPlan
  , tmpDirFor
  , tmpNameFor
  , slotOccupied
  , admitsUserPath
  , dirFingerprint
  , updateCatalog
  , outcomeLabel
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Crypto.Hash (Digest, SHA256 (..), hashWith)
import Data.List (sort)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , doesPathExist
  , listDirectory
  , pathIsSymbolicLink
  , removeFile
  , setModificationTime
  )
-- isRelative 不再引入：P3b-8 六轮复审——execItem 的路径自查改用 Pm.Op.opPathsOk
-- （isRelative 对 "\\evil"/"c:evil" 都答 True，而 </> 对二者是整体替换）。
import System.FilePath (splitDirectories, takeDirectory, takeExtension, takeFileName, (</>))
import System.IO.Error (isDoesNotExistError)

import Pm.Config (pmDir, pmSubTmp, pmSubTrash, readRootInfo, requirePmTrusted)
import Pm.GitGuard (pmIgnoreGuard)
import Pm.Hash
import Pm.Journal
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Trash
import Pm.Types
-- P3b-10 七轮：canonical 限域挡 junction 别名。P3b-11 八轮：改用逐级下降的
-- resolveUnder（基准自身也可能被劫持），pathAtOrUnder 负责 .pm 语义排除。
import Pm.Win (moveFileNoReplace, pathAtOrUnder, resolveUnder)

-- | Protocol step markers, one between every pair of externally visible
-- effects (§13 P3 fault injection).
data Checkpoint
  = CpCopyAfterDstCheck
  | CpCopyAfterIntent
  | CpCopyAfterTmp
  | CpCopyAfterFlush
  | CpCopyAfterMove
  | CpRenAfterIntent
  | CpRenAfterMove
  | CpQuarAfterManifest
  | CpQuarAfterIntent
  | CpQuarAfterMove
  deriving (Show, Eq)

data ExecEnv = ExecEnv
  { eeCheckpoint :: Checkpoint -> IO ()
  , eeDoneSync :: Sync
    -- ^ Copy 的 Done 持久化模式。主库默认 Buffered（可组提交，C2/C3 从盘面
    -- 重建）；备份路径必须 Barrier（DESIGN.md §9）—— 备份盘是可移动介质，
    -- 打印结果后用户随时可能拔盘，Done 必须在汇报前已落盘。
    -- Rename/Quarantine 的 Done 永远 Barrier，不受此字段影响。
  , eeExpectRootId :: Maybe Text
    -- ^ 评审 cx-1：拿到锁之后、动盘之前复验 root-id.json 的 UUID。盘符会
    -- 漂移（备份盘 E: → F:），路径不是身份；不符即整批拒绝执行。
    -- Nothing = 跳过（测试用临时 root 无标识）。
  }

defaultExecEnv :: ExecEnv
defaultExecEnv =
  ExecEnv {eeCheckpoint = \_ -> pure (), eeDoneSync = Buffered, eeExpectRootId = Nothing}

data ItemOutcome
  = ODone {oSha :: Maybe Text, oDstStat :: Maybe StatSnap, oTrashRel :: Maybe FilePath}
  | OSkippedIdentical
  | ONotExecuted -- item was marked skipped / needs-decision
  | OConflict String
  | OFailed String
  deriving (Show, Eq)

outcomeLabel :: ItemOutcome -> String
outcomeLabel ODone {} = "DONE"
outcomeLabel OSkippedIdentical = "SKIP(同内容)"
outcomeLabel ONotExecuted = "未执行"
outcomeLabel (OConflict m) = "CONFLICT: " <> m
outcomeLabel (OFailed m) = "FAILED: " <> m

-- 子目录名取自 'Pm.Config' 的单一真源，'requirePmTrusted' 校验的就是这一条。
tmpDirFor :: FilePath -> Text -> FilePath
tmpDirFor root pid = pmDir root </> pmSubTmp </> T.unpack pid

-- | tmp 名是**确定性**的（崩溃重跑要能算出同名，doctor 才能把孤儿 tmp 与在途
-- tmp 分开）——因此可预测，因此写入必须独占创建（'Pm.Win.openFreshBinary'）。
tmpNameFor :: Int -> FilePath -> FilePath
tmpNameFor ix dstRel = show ix <> "-" <> takeFileName dstRel

-- | Execute a plan's pending items under the root's exclusive lock.
-- Left = lock busy \/ root 身份不符. A checkpoint exception (test crash)
-- propagates out with the journal handle closed by bracket — exactly a
-- process death.
--
-- 组语义（评审 cx-2）：同 'piGroup' 的条目是一个语义单元。组内任一项没有
-- 成功（DONE\/同内容 SKIP 之外的一切结果）→ 组内其余项不再执行，且组内
-- **已执行的 Quarantine 立即自动复位**（journaled rename，trash → 原位）；
-- 复位成功的 Quarantine 结果被改写，catalog 回写不会误删条目。
execPlan :: ExecEnv -> Plan -> IO (Either String [(PlanItem, ItemOutcome)])
execPlan env plan = do
  -- P3b-6：取锁本身会创建 .pm/lock——无身份或 I11 不过的 root 连锁文件都
  -- 不该落下（git 工作树污染正是 I11 要防的），先做一次零写入预检；锁内
  -- 再按同一规则复检（预检与取锁之间被改仍整批拒绝）。P3b-7：计划结构
  -- （id 格式、序号非负唯一）同样先验。
  --
  -- P3b-11（八轮复审 critical）：.pm 家族的可信性排在最前——readRootInfo 读的
  -- 就是 .pm 里的文件，withRootLock 还会在 .pm 下建锁。.pm 若是 junction，
  -- 身份判定读的是库外的文件、锁也落在库外，后面全部判定都建立在假地基上。
  tr <- requirePmTrusted (plRootPath plan)
  case tr of
    Left e -> pure (Left e)
    Right () -> do
      pre <- readRootInfo (plRootPath plan)
      preOk <- case (validatePlan plan, pre) of
        (Left e, _) -> pure (Left (planMsg e))
        (_, Nothing) -> pure (Left noIdentityMsg)
        (_, Just info) -> pmIgnoreGuard (riRole info) (plRootPath plan)
      either (pure . Left) (const (execPlan' env plan)) preOk

noIdentityMsg :: String
noIdentityMsg =
  "root 无身份（缺 .pm/root-id.json），拒绝执行（fail-closed，内核级）→ 先 pm init / pm backup init 建立标识"

planMsg :: String -> String
planMsg e = e <> "，拒绝执行——id 与序号参与 opId/tmp/trash 路径推导"

execPlan' :: ExecEnv -> Plan -> IO (Either String [(PlanItem, ItemOutcome)])
execPlan' env plan = do
  let root = plRootPath plan
  r <- withRootLock root $ do
    -- P2.3 内核自卫（复审三轮 cx-1）：不信任何调用方。锁内读盘上身份，
    -- 规则缺一不可：①root 必须有身份（P3b-6 复审 A3：此前「从未 init 的裸
    -- 目录可无身份执行」是给测试 fixture 留的口子，库层调用者删掉 marker
    -- 就能走进去——fixture 改为先写 root-id）；②计划 id 须为生成格式
    -- （A1：id 参与 opId/tmp/trash 路径推导）；③调用方声明的期待须与盘上
    -- 一致；④计划自带的 rootId 须与盘上一致，且不得缺席。
    mi <- readRootInfo root
    let ridOk = case mi of
          Nothing -> Left noIdentityMsg
          Just info
            | Left e <- validatePlan plan -> Left (planMsg e)
            | Just e <- eeExpectRootId env
            , riId info /= e ->
                Left
                  ( "root 标识不符（期待 " <> T.unpack e <> "，盘上是 " <> T.unpack (riId info)
                      <> "），拒绝执行——路径不是身份（cx-1）"
                  )
            | Just rid <- plRootId plan
            , riId info /= rid ->
                Left
                  ( "计划 rootId 与盘上身份不符（计划 " <> T.unpack rid <> "，盘上 " <> T.unpack (riId info)
                      <> "），拒绝执行"
                  )
            | Nothing <- plRootId plan ->
                Left
                  ( "该 root 已有身份（" <> T.unpack (riId info)
                      <> "），拒绝执行无 rootId 的计划（fail-closed，内核级）"
                  )
            | otherwise -> Right info
    case ridOk of
      Left e -> pure (Left e)
      Right info -> do
        -- P3b-5 复审 #3 / P3b-6 复审 A3（内核自卫）：I11 重检不经可覆盖的
        -- ExecEnv 钩子，且对**所有** role 无条件执行（只查 RoleVault 会被
        -- 改写 marker role 绕过）——锁内、journal/tmp/trash 任何写入之前；
        -- 计划生成与执行之间 .gitignore 被改则整批拒绝。
        pf0 <- pmIgnoreGuard (riRole info) root
        -- .pm 可信性同样锁内复检：预检与取锁之间有人把 .pm/trash 换成 junction
        -- 的窗口，与 I11 重检是同一类内核自卫（P3b-11）。
        pf <- either (pure . Left) (const (requirePmTrusted root)) pf0
        case pf of
          Left e -> pure (Left (e <> "（执行期重检，整批拒绝）"))
          Right () -> withJournal root $ \j -> do
            (outs, restoredIxs) <- execItems env root j (plId plan) (plItems plan)
            now <- getCurrentTime
            jAppend j Barrier (JCleanShutdown now)
            let final =
                  [ if piIx it `elem` restoredIxs then (it, restoredMark) else (it, out)
                  | (it, out) <- zip (plItems plan) outs
                  ]
            pure (Right final)
  pure $ case r of
    Nothing -> Left "另一个 pm 实例正持有该 root 的锁（I10），稍后重试"
    Just x -> x
 where
  -- 复位成功后该 Quarantine 视同未生效：不能报 ODone，否则 catalog 回写
  -- 会删掉一个实际已回到原位的条目。
  restoredMark = OFailed "已隔离但组内后续项失败 → victim 已自动复位（组未生效）"

-- | Walk items in order with group awareness. Returns per-item outcomes plus
-- the ixs of quarantine items that were auto-restored.
execItems :: ExecEnv -> FilePath -> Journal -> Text -> [PlanItem] -> IO ([ItemOutcome], [Int])
execItems env root j pid = go [] [] []
 where
  go _ _ restored [] = pure ([], restored)
  go abortedGs quars restored (it : rest) = case piGroup it of
    Just g
      | g `elem` abortedGs -> do
          (outs, r') <- go abortedGs quars restored rest
          pure (ONotExecuted : outs, r')
    mg -> do
      out <- execItem env root j pid it
      case mg of
        Nothing -> do
          (outs, r') <- go abortedGs quars restored rest
          pure (out : outs, r')
        Just g
          | groupOk out -> do
              let quars' = case (piOp it, out) of
                    (OpQuarantine {}, ODone _ _ (Just tr)) -> (g, it, tr) : quars
                    _ -> quars
              (outs, r') <- go abortedGs quars' restored rest
              pure (out : outs, r')
          | otherwise -> do
              -- 组内失败：逆序复位本组已隔离的 victim
              let mine = [q | q@(g', _, _) <- quars, g' == g]
              results <- mapM (restoreQuarantine env root j pid) mine
              let notes = concatMap fst results
                  newlyRestored = [piIx qit | ((_, ok'), (_, qit, _)) <- zip results mine, ok']
                  out' = annotate out notes
              (outs, r') <- go (g : abortedGs) quars (restored <> newlyRestored) rest
              pure (out' : outs, r')
  groupOk ODone {} = True
  groupOk OSkippedIdentical = True
  groupOk _ = False
  annotate (OConflict m) notes | not (null notes) = OConflict (m <> notes)
  annotate (OFailed m) notes | not (null notes) = OFailed (m <> notes)
  annotate o _ = o

-- | Journaled in-batch rollback of one executed quarantine: rename the file
-- from @.pm\/trash\/@ back to its original place（§6.5 ②失败 → 复位）. Goes
-- through 'execRename' so Intent\/Done land in the journal and doctor's
-- restore-aware C4 check can pair them. Returns (note, restoredOk).
--
-- P3b-4 评审 #1：复位目标可能被占——supersede 的 Copy 落位后复核失败的
-- 残留文件、或落位窗口内第三方创建的文件；I5 会拒绝 rename 落回。此时先
-- 把占位者 journaled 隔离到 @\<pid\>~displaced\/@（不删除，I2），再复位
-- victim。占位者是目录或读取失败 → 不动它，保守失败（旧字节仍在 trash）。
restoreQuarantine :: ExecEnv -> FilePath -> Journal -> Text -> (Int, PlanItem, FilePath) -> IO (String, Bool)
restoreQuarantine env root j pid (_, qit, trashRel) = do
  let victimRel = opVictimRel (piOp qit)
      victimAbs = root </> victimRel
      restoreOp =
        OpRename
          (".pm" </> "trash" </> trashRel)
          victimRel
          (FpFileSha (opVictimSha (piOp qit)))
      oid = restoreOpId pid (piIx qit)
  occ <- doesFileExist victimAbs
  (dispOk, dispNote) <-
    if not occ
      then pure (True, "")
      else do
        oshaE <- try (sha256File victimAbs) :: IO (Either IOException Text)
        case oshaE of
          Left e -> pure (False, "；复位目标被占且无法读取(" <> show e <> ")")
          Right osha -> do
            -- 位移目录带尝试序号（P3b-5 复审 #1）：同计划重跑可能再次位移，
            -- 固定路径会与上次残留撞车。
            mslot <- freeDisplacedSlot pid (piIx qit) victimRel
            case mslot of
              Nothing -> pure (False, "；位移隔离槽位耗尽(99)，不动占位者")
              Just (doid, n) -> do
                let dispOp = OpQuarantine victimRel osha ("rollback-displaced:" <> opId pid (piIx qit))
                dout <- execQuarantine env root j doid (quarDirFor pid (SfxDisplaced n) </> victimRel) dispOp
                case dout of
                  ODone {} -> pure (True, "；占位文件已隔离(~displaced-" <> show n <> ")")
                  other -> pure (False, "；占位文件隔离未成功(" <> outcomeLabel other <> ")")
  -- 占位者没挪开就不试 rename（必被 I5 拒绝，徒增噪音）
  if not dispOk
    then pure ("；自动复位未做（复位目标仍被占），旧字节仍在 .pm/trash/" <> trashRel <> dispNote, False)
    else do
      out <- execRename env root j oid restoreOp
      pure $ case out of
        ODone {} -> ("；旧目标已自动复位" <> dispNote, True)
        other ->
          ( "；自动复位未成功(" <> outcomeLabel other <> ")，旧字节仍在 .pm/trash/" <> trashRel <> dispNote
          , False
          )
 where
  -- 第一个盘上尚未被占的 ~d<N> 位移槽（N 从 1 起，封顶 99）。P3b-6 复审 A1：
  -- 只看 doesFileExist 会在槽位被同名目录占住时反复选中它、后续 move 必败。
  freeDisplacedSlot pid' ix victimRel = go (1 :: Int)
   where
    go n
      | n > 99 = pure Nothing
      | otherwise = do
          occ <- slotOccupied (trashDir root </> quarDirFor pid' (SfxDisplaced n) </> victimRel)
          if occ then go (n + 1) else pure (Just (displacedOpId pid' ix n, n))

-- | 位移槽「占用」= 任何路径条目，**含悬空的 junction\/symlink**：doesPathExist
-- 跟随链接，悬空链接会答 False（P3b-7 复审 A1，directory-1.3.8.5 实测），再用
-- lstat 语义的 pathIsSymbolicLink 补判。两个探测都包在 try 里，非「不存在」的
-- 异常（ACL 拒绝、非法名）一律按占用——宁可跳槽，不撞 I5。P3b-8 复审 A1：
-- 实测 doesPathExist 自己吞掉这类错误答 False、pathIsSymbolicLink 则抛
-- InvalidArgument\/PermissionDenied，此前已落在占用分支；包起来是让契约不再
-- 依赖库的吞错细节。
slotOccupied :: FilePath -> IO Bool
slotOccupied p = do
  ex <- try (doesPathExist p) :: IO (Either IOException Bool)
  case ex of
    Right True -> pure True
    Left e | not (isDoesNotExistError e) -> pure True
    _ -> do
      r <- try (pathIsSymbolicLink p) :: IO (Either IOException Bool)
      pure $ case r of
        Right isLink -> isLink
        Left e
          | isDoesNotExistError e -> False
          | otherwise -> True

execItem :: ExecEnv -> FilePath -> Journal -> Text -> PlanItem -> IO ItemOutcome
execItem env root j pid item = case piStatus item of
  StSkippedByUser -> pure ONotExecuted
  StNeedsDecision _ -> pure ONotExecuted
  StPending -> do
    -- Ops address the root strictly by validated relative paths。P3b-8 六轮
    -- 复审：与 validatePlan 共用 'opPathsOk'——旧的 isRelative+".." 自查挡不住
    -- "\\evil"/"c:evil"（filepath 实测二者 isRelative=True 且 root </> p 是
    -- **整体替换**）、NTFS ADS（"a.jpg:ads"）与指向 .pm 内部的路径。
    if not (opPathsOk (piOp item))
      then pure (OFailed "非法相对路径（越界/盘符/ADS/.pm 内部），拒绝执行")
      else case piOp item of
        op@OpCopy {} -> execCopy env root j (opId pid (piIx item)) (piIx item) op
        op@OpRename {} -> execRename env root j (opId pid (piIx item)) op
        op@OpQuarantine {} ->
          execQuarantine env root j (opId pid (piIx item)) (quarDirFor pid SfxPlain </> opVictimRel op) op

-- | 词法校验（'opPathsOk'）之后的第二道闸：让操作系统逐级解析每个落位\/取用
-- 点。P3b-10（七轮）用 canonical 包含判定；P3b-11（八轮复审 critical，探针
-- 实证）发现那还不够——包含判定默认**基准可信**，而 @root@\/@.pm\/trash@ 也是
-- pm 拼出来的字符串：把 @.pm\/trash@ 本身做成指向库外的 junction 后，两侧都
-- 解析到库外、判定通过。'resolveUnder' 改为从基准逐分量下降，要求路上每一段
-- 都是盘上的真名，基准与目标同受检。
--
-- 用户数据路径另加 @.pm@ 语义排除：@root\/alias -\> root\/.pm@ 这类别名（以及
-- 卷上若启用的 8.3 短名）逐级下降能挡住 junction 形态，但短名不是 reparse
-- point——canonical 后落在 @.pm@ 内即拒绝，两条一起才闭合。
--
-- 尚不存在的目标不影响判定（'resolveUnder' 对缺失分量返回拼接路径），
-- 因此 rename 到新名、copy 进新目录不会被误拒。
-- P3b-12（九轮复审 major）：@.pm@ 排除判定改为三态并只接受明确的
-- @Just False@。此前 'pathAtOrUnder' 解析失败返回 False，取反后成了"不在
-- @.pm@ 里 → 放行"，是结构性 fail-open。
-- | 放行判据（纯函数，导出给测试钉住）：'Pm.Win.pathAtOrUnder' 的三态里，
-- **只有**明确的"不在 .pm 内"才放行。@Nothing@（答不上来）与 @Just True@
-- （在 .pm 内）都拒。
--
-- P3b-13（十轮复审 #7）：本机构造不出让 'canonicalizePath' 抛异常的输入
-- （实测：含 NUL 的名字被截断、@CON@\/@NUL@ 正常返回、空路径解析成 cwd），
-- 所以 @Nothing@ 分支无法从外部触发。判据因此单独导出——测试打在**真实
-- 判据**上，而不是在用例里复制一份 if 来自证。
admitsUserPath :: Maybe Bool -> Bool
admitsUserPath = (== Just False)

confinedUser :: FilePath -> [FilePath] -> IO Bool
confinedUser root rels = and <$> mapM one rels
 where
  one rel = do
    m <- resolveUnder root rel
    case m of
      Nothing -> pure False
      Just p -> admitsUserPath <$> pathAtOrUnder (pmDir root) p

-- | @.pm@ 内部落位点（隔离目标）：从 root 起全程下降，@.pm@ 与 @trash@ 这两级
-- 同样必须是真名——这正是八轮 critical 的攻击面。
confinedTrash :: FilePath -> FilePath -> IO Bool
confinedTrash root rel = isJust <$> resolveUnder root (".pm" </> pmSubTrash </> rel)

-- | pm **自建**的 @.pm\/tmp\/\<planId\>\/\<name\>@ 落位点。
--
-- P3b-12（九轮复审 critical，探针实证）：'Pm.Config.requirePmTrusted' 只走
-- @.pm@ 与 @.pm\/tmp@ 这些**固定**层，而 planId 那一层是运行时构造的。实测：
-- 把 @.pm\/tmp\/\<planId\>@ 预置成指向库外的 junction、并在库外放一个同名的
-- 确定性 tmp 文件后，'Pm.Win.openFreshBinary' 的残留 unlink **删掉了那个库外
-- 文件**。动态层必须逐次验——固定层的闸覆盖不到它。
confinedTmp :: FilePath -> Text -> FilePath -> IO Bool
confinedTmp root pid name =
  isJust <$> resolveUnder root (".pm" </> pmSubTmp </> T.unpack pid </> name)

escapeOutcome :: ItemOutcome
escapeOutcome = OConflict "路径逐级解析后不在 root/.pm\\trash 之内（junction/别名/短名？），拒绝执行"

-- ─── Copy (§6.1) ────────────────────────────────────────────────────────────

execCopy :: ExecEnv -> FilePath -> Journal -> Text -> Int -> Op -> IO ItemOutcome
execCopy env root j oid ix op = do
  okc <- confinedUser root [opDstRel op]
  if okc then execCopy' env root j oid ix op else pure escapeOutcome

execCopy' :: ExecEnv -> FilePath -> Journal -> Text -> Int -> Op -> IO ItemOutcome
execCopy' env root j oid ix op = do
  preE <- try (statSnap (opSrcAbs op)) :: IO (Either IOException StatSnap)
  case preE of
    Left e -> pure (OFailed ("源 stat 失败: " <> show e))
    Right pre
      | ssSize pre /= opSrcSize op || ssMtimeNs pre /= opSrcMtimeNs op ->
          pure (OConflict "源文件在计划生成后被修改（重新生成计划）")
      | otherwise -> do
          let dstAbs = root </> opDstRel op
          dstExists <- doesFileExist dstAbs
          if dstExists
            then do
              dsha <- sha256File dstAbs
              if dsha == opSha op
                then pure OSkippedIdentical
                else pure (OConflict "目标已存在且内容不同（I5：不覆盖）")
            else do
              let pid' = planIdOf oid
                  tname = tmpNameFor ix (opDstRel op)
                  tdir = tmpDirFor root pid'
                  tmp = tdir </> tname
              -- 动态 planId 层的逐级校验（P3b-12 九轮 critical）：固定层的
              -- requirePmTrusted 覆盖不到它，而 copyFileHashed 的残留 unlink
              -- 会沿这一层的 junction 删掉库外同名文件（实测）。
              okTmp <- confinedTmp root pid' tname
              if not okTmp
                then pure escapeOutcome
                else do
                  eeCheckpoint env CpCopyAfterDstCheck
                  t1 <- getCurrentTime
                  jAppend j Barrier (JIntent oid op t1)
                  eeCheckpoint env CpCopyAfterIntent
                  createDirectoryIfMissing True tdir
                  -- 目录创建之后再验一次：createDirectoryIfMissing 与写入之间
                  -- 是 P3b-11 起就记录的 TOCTOU 窗口，这一次复检把它收窄到
                  -- "创建后立刻"（§14 单机模型内的残余，见归档）。
                  okTmp2 <- confinedTmp root pid' tname
                  if not okTmp2 then pure escapeOutcome else execCopyTmp env root j oid op tmp

execCopyTmp :: ExecEnv -> FilePath -> Journal -> Text -> Op -> FilePath -> IO ItemOutcome
execCopyTmp env root j oid op tmp = do
  let dstAbs = root </> opDstRel op
  wsha <- copyFileHashed (opSrcAbs op) tmp
  eeCheckpoint env CpCopyAfterTmp
  rsha <- sha256File tmp
  if wsha /= opSha op || rsha /= opSha op
    then do
      -- §6.1 footnote: the one permitted unlink — our own tmp
      -- file that never got renamed into place.
      removeFile tmp
      tf <- getCurrentTime
      jAppend j Barrier (JFailed oid ("hash 失配 write=" <> wsha <> " reread=" <> rsha) tf)
      pure (OFailed "hash 失配（写入逻辑或介质问题），该项中止")
    else do
      setModificationTime tmp (nsToUtc (opSrcMtimeNs op))
      eeCheckpoint env CpCopyAfterFlush
      createDirectoryIfMissing True (takeDirectory dstAbs)
      mvE <- try (moveFileNoReplace tmp dstAbs) :: IO (Either IOException ())
      case mvE of
        Left e -> do
          raced <- doesFileExist dstAbs
          tf <- getCurrentTime
          if raced
            then do
              jAppend j Barrier (JFailed oid "DstAppearedDuringWrite" tf)
              pure (OConflict "写入窗口内目标被第三方创建；tmp 保留，交 pm doctor")
            else do
              jAppend j Barrier (JFailed oid ("落位失败: " <> T.pack (show e)) tf)
              pure (OFailed ("落位 rename 失败: " <> show e))
        Right () -> do
          -- P3b-4 评审 #1：落位后复核的 stat/hash 异常必须留在
          -- 本项内变成 OFailed——逃逸出去会绕过组回滚（复位不跑）。
          verE <-
            try ((,) <$> statSnap dstAbs <*> sha256File dstAbs)
              :: IO (Either IOException (StatSnap, Text))
          case verE of
            Left e -> do
              tf <- getCurrentTime
              jAppend j Barrier (JFailed oid ("落位后复核异常: " <> T.pack (show e)) tf)
              pure (OFailed ("落位后复核异常（交 pm doctor）: " <> show e))
            Right (post, psha)
              | psha /= opSha op -> do
                  tf <- getCurrentTime
                  jAppend j Barrier (JFailed oid "post-move verify failed" tf)
                  pure (OFailed "落位后复核失败（矩阵 C5，交 pm doctor）")
              | otherwise -> do
                  eeCheckpoint env CpCopyAfterMove
                  td <- getCurrentTime
                  jAppend j (eeDoneSync env) (JDone oid (Just (opSha op)) Nothing td)
                  pure (ODone (Just (opSha op)) (Just post) Nothing)

-- ─── Rename (§6.2) ──────────────────────────────────────────────────────────

execRename :: ExecEnv -> FilePath -> Journal -> Text -> Op -> IO ItemOutcome
execRename env root j oid op = do
  -- 源与目标都必须逐级下降到 root 内。源走 .pm/trash 例外（undo/组回滚复位）
  -- 时按 trash 内部路径判定——八轮复审 critical 的攻击面正在这条：@.pm@ 或
  -- @trash@ 自身若是 junction，旧的"基准可信"判定会把库外对象搬进库。
  okOld <-
    if isTrashSrcRel (opOldRel op)
      then isJust <$> resolveUnder root (opOldRel op)
      else confinedUser root [opOldRel op]
  okNew <- confinedUser root [opNewRel op]
  if okOld && okNew then execRename' env root j oid op else pure escapeOutcome

execRename' :: ExecEnv -> FilePath -> Journal -> Text -> Op -> IO ItemOutcome
execRename' env root j oid op = do
  let oldAbs = root </> opOldRel op
      newAbs = root </> opNewRel op
  oldIsFile <- doesFileExist oldAbs
  oldIsDir <- doesDirectoryExist oldAbs
  newIsFile <- doesFileExist newAbs
  newIsDir <- doesDirectoryExist newAbs
  if not (oldIsFile || oldIsDir)
    then pure (OConflict "重命名源不存在")
    else
      if newIsFile || newIsDir
        then pure (OConflict "重命名目标已存在（I5：不覆盖）")
        else do
          fpOk <- case opFp op of
            FpFileSha s
              | oldIsFile -> (== s) <$> sha256File oldAbs
              | otherwise -> pure False
            FpDir s
              | oldIsDir -> (== s) <$> dirFingerprint oldAbs
              | otherwise -> pure False
          if not fpOk
            then pure (OConflict "内容指纹与计划时不符（对象已被改动）")
            else do
              t1 <- getCurrentTime
              -- Barrier is mandatory here and Done may NOT be group-committed:
              -- the old name exists only in this journal (I1).
              jAppend j Barrier (JIntent oid op t1)
              eeCheckpoint env CpRenAfterIntent
              mvE <- try (moveFileNoReplace oldAbs newAbs) :: IO (Either IOException ())
              case mvE of
                Left e -> do
                  tf <- getCurrentTime
                  jAppend j Barrier (JFailed oid ("rename 失败: " <> T.pack (show e)) tf)
                  pure (OFailed ("rename 失败: " <> show e))
                Right () -> do
                  eeCheckpoint env CpRenAfterMove
                  td <- getCurrentTime
                  jAppend j Barrier (JDone oid Nothing Nothing td)
                  pure (ODone Nothing Nothing Nothing)

-- ─── Quarantine (§6.3, write-ahead manifest) ────────────────────────────────

-- | @trashRel@ 由调用方经 'quarTrashRel' 推导（普通隔离与 ~d 位移隔离落
-- 不同目录）；manifest 的 planId 从 oid 剥离。
execQuarantine :: ExecEnv -> FilePath -> Journal -> Text -> FilePath -> Op -> IO ItemOutcome
execQuarantine env root j oid trashRel op = do
  -- victim 必须在 root 内且不在 .pm 内；隔离落位从 root 起全程真名下降——
  -- 八轮复审 major：以 trashDir 为基准判定时，trash 自身是 junction 就把
  -- victim 搬出了库。
  okVictim <- confinedUser root [opVictimRel op]
  okTrash <- confinedTrash root trashRel
  if okVictim && okTrash then execQuarantine' env root j oid trashRel op else pure escapeOutcome

execQuarantine' :: ExecEnv -> FilePath -> Journal -> Text -> FilePath -> Op -> IO ItemOutcome
execQuarantine' env root j oid trashRel op = do
  let victimAbs = root </> opVictimRel op
      trashAbs = trashDir root </> trashRel
  ex <- doesFileExist victimAbs
  if not ex
    then do
      -- 同一计划重跑（崩溃恢复，评审 cx-2）：victim 已不在原位、但本计划的
      -- trash 位置有内容相符的文件 → 该项上次已执行，按已完成继续（组内
      -- 后续 Copy 得以续跑）。journal 不重写：缺失的 Done 由 doctor 补记。
      tex <- doesFileExist trashAbs
      if tex
        then do
          tsha <- sha256File trashAbs
          if tsha == opVictimSha op
            then pure (ODone (Just (opVictimSha op)) Nothing (Just trashRel))
            else pure (OConflict "victim 不在原位且本计划 trash 内容不符，需人工核查")
        else pure (OConflict "victim 不存在")
    else do
      vsha <- sha256File victimAbs
      if vsha /= opVictimSha op
        then pure (OConflict "victim 内容与计划时不符（不动）")
        else do
          now0 <- getCurrentTime
          appendManifest
            root
            TrashRecord
              { trVictimRel = opVictimRel op
              , trTrashRel = trashRel
              , trSha = opVictimSha op
              , trReason = opReason op
              , trPlanId = planIdOf oid
              , trAt = now0
              }
          eeCheckpoint env CpQuarAfterManifest
          t1 <- getCurrentTime
          jAppend j Barrier (JIntent oid op t1)
          eeCheckpoint env CpQuarAfterIntent
          createDirectoryIfMissing True (takeDirectory trashAbs)
          mvE <- try (moveFileNoReplace victimAbs trashAbs) :: IO (Either IOException ())
          case mvE of
            Left e -> do
              tf <- getCurrentTime
              jAppend j Barrier (JFailed oid ("隔离移动失败: " <> T.pack (show e)) tf)
              pure (OFailed ("隔离移动失败: " <> show e))
            Right () -> do
              eeCheckpoint env CpQuarAfterMove
              td <- getCurrentTime
              jAppend j Barrier (JDone oid (Just (opVictimSha op)) (Just trashRel) td)
              pure (ODone (Just (opVictimSha op)) Nothing (Just trashRel))

-- ─── Helpers ────────────────────────────────────────────────────────────────

planIdOf :: Text -> Text
planIdOf oid = T.takeWhile (/= '#') oid

-- | 目录指纹：递归树上每个条目一行 @类型\\t相对路径\\t大小\\tmtimeNs@
-- （目录大小记 -1、mtime 记 0），排序后 sha256。P3b-5 复审 B2：原先只看
-- 直接子项的名字+大小，换成同名同大小的另一棵树也能通过。不含文件内容
-- hash——Rename 不触碰内容、undo 可逆，而 Raw 事件夹动辄数十 GB，计划期
-- 与执行期两次全量 hash 的代价与收益不成比例（§14 单机威胁模型下作为
-- 残余风险记录：需同时伪造整棵树的名字、大小与 mtime）。
dirFingerprint :: FilePath -> IO Text
dirFingerprint dir = do
  entries <- walk ""
  let payload = TE.encodeUtf8 (T.pack (unlines (sort entries)))
      digest = hashWith SHA256 payload :: Digest SHA256
  pure (T.pack (show digest))
 where
  walk rel = do
    let here = if null rel then dir else dir </> rel
    names <- listDirectory here
    fmap concat . forM names $ \n -> do
      let relN = if null rel then n else rel </> n
          absN = dir </> relN
      -- P3b-6 复审 minor：symlink/junction 记为 l 条目、**不跟随**——指回祖先
      -- 的 junction 会无限递归；Scan.listTree 对 reparse point 同策略。
      isLink <- pathIsSymbolicLink absN
      if isLink
        then pure ["l\t" <> relN <> "\t-1\t0"]
        else do
          isD <- doesDirectoryExist absN
          if isD
            then (("d\t" <> relN <> "\t-1\t0") :) <$> walk relN
            else do
              s <- statSnap absN
              pure ["f\t" <> relN <> "\t" <> show (ssSize s) <> "\t" <> show (ssMtimeNs s)]

-- | Fold executed outcomes back into the mutated root's catalog. A directory
-- rename rewrites the path prefix of every entry beneath it.
updateCatalog :: UTCTime -> [(PlanItem, ItemOutcome)] -> Catalog -> Catalog
updateCatalog now results cat = foldl step cat results
 where
  step c (item, out) = case (piOp item, out) of
    (OpCopy _ dstRel sha _ _, ODone _ (Just st) _) ->
      c
        { catEntries =
            Map.insert
              dstRel
              Entry
                { enPath = dstRel
                , enSize = ssSize st
                , enMtimeNs = ssMtimeNs st
                , enSha = sha
                , enKind = classifyExt (takeExtension dstRel)
                , enLastVerified = Just now
                }
              (catEntries c)
        }
    (OpRename old new _, ODone {}) ->
      c {catEntries = Map.fromList (map (rekey old new) (Map.toList (catEntries c)))}
    (OpQuarantine victim _ _, ODone {}) ->
      c {catEntries = Map.delete victim (catEntries c)}
    _ -> c
  rekey old new (k, e) =
    let oldParts = splitDirectories old
        kParts = splitDirectories k
     in if take (length oldParts) kParts == oldParts
          then
            let k' = foldr1 (</>) (splitDirectories new <> drop (length oldParts) kParts)
             in (k', e {enPath = k'})
          else (k, e)
