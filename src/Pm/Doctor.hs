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
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory, removeFile)
import System.FilePath ((</>))

import Pm.Catalog (loadCatalog)
import Pm.Config (pmDir, readRootInfo, requireWritable)
import Pm.Exec (dirFingerprint, tmpDirFor, tmpNameFor)
import Pm.Hash (sha256File)
import Pm.Journal
import Pm.Op
import Pm.Plan
import Pm.Trash
import Pm.Types

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
runDoctor :: FilePath -> DoctorOpts -> IO ([Finding], Int)
runDoctor root opts = do
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
  tv <- trashView root
  let q1 =
        [ Finding "Q1" Warn ("trash 中无 manifest 记录的文件: " <> f) ""
        | f <- tvUnregistered tv
        ]
      manifestWarns = [Finding "TRASH-MANIFEST" Bad w "" | w <- tvWarnings tv]

  -- Stale tmp files not tied to any pending intent
  stale <- staleTmpFiles root (mapMaybe (pendingTmp root) pending)
  let staleFindings =
        [ Finding "TMP-STALE" Warn ("孤儿临时文件: " <> f) "--repair 将删除（pm 自建 tmp，非用户数据）"
        | f <- stale
        ]

  -- Catalog verification age
  (mcat, _) <- loadCatalog root
  ageFinding <- case mcat of
    Nothing -> pure []
    Just cat -> do
      deepFindings <-
        if doDeep opts
          then deepVerify root cat
          else pure []
      let unverified = [() | e <- Map.elems (catEntries cat), enLastVerified e == Nothing]
      pure
        ( [ Finding
              "VERIFY-AGE"
              Info
              (show (Map.size (catEntries cat)) <> " 条目; 无验证时间戳条目 " <> show (length unverified))
              ""
          ]
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
-- P3b-6 复审 A1）。
pendingTmp :: FilePath -> (Text, Op) -> Maybe FilePath
pendingTmp root (oid, OpCopy _ dstRel _ _ _) = case opIdParts oid of
  Just (pid, ix, SfxPlain) -> Just (tmpDirFor root pid </> tmpNameFor ix dstRel)
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

classifyPending' :: FilePath -> (Text, Op) -> IO [Finding]
classifyPending' root (oid, op) = case op of
  OpCopy _ dstRel sha _ _ -> do
    let dstAbs = root </> dstRel
    dstEx <- doesFileExist dstAbs
    if dstEx
      then do
        dsha <- sha256File dstAbs
        if dsha == sha
          then pure [Finding "C2" Warn (T.unpack oid <> ": dst 完好、Done 丢失 (" <> dstRel <> ")") "--repair 将补记 Done"]
          else pure [Finding "C5" Bad (T.unpack oid <> ": dst 存在但内容不符 (" <> dstRel <> ")") "--repair 将生成 dst 隔离计划（经 pm apply 确认执行），源文件未受影响"]
      else do
        let mtmp = pendingTmp root (oid, op)
        tmpEx <- maybe (pure False) doesFileExist mtmp
        if tmpEx
          then pure [Finding "C1" Warn (T.unpack oid <> ": 中断于写 tmp 阶段 (" <> dstRel <> ")") "--repair 将清除 tmp；重跑原计划即可续传"]
          else pure [Finding "C1" Info (T.unpack oid <> ": Intent 后无痕迹（写 tmp 前中断），重跑原计划即可") ""]
  OpRename old new fp -> do
    oldEx <- existsAny (root </> old)
    newEx <- existsAny (root </> new)
    case (oldEx, newEx) of
      (True, False) -> pure [Finding "R1" Info (T.unpack oid <> ": rename 未执行 (" <> old <> " → " <> new <> ")，重跑原计划即可") ""]
      (False, True) -> do
        ok <- verifyFp (root </> new) fp
        if ok
          then pure [Finding "R2" Warn (T.unpack oid <> ": rename 已执行、Done 丢失 (" <> new <> ")") "--repair 将补记 Done"]
          else pure [Finding "R2" Bad (T.unpack oid <> ": rename 目标存在但指纹不符 (" <> new <> ")，需人工核查") ""]
      (True, True) -> pure [Finding "R3" Warn (T.unpack oid <> ": rename 未执行且目标被占 (" <> new <> ")" ) "解决占用后重新生成计划"]
      (False, False) -> pure [Finding "R?" Bad (T.unpack oid <> ": 新旧路径都不存在，超出矩阵，需人工核查") ""]
  OpQuarantine victim sha _ -> do
    -- P3b-4 评审 #1：trash 路径推导与 Exec 共用（quarDirFor / quarTrashRel，
    -- ~d 位移隔离落 <planId>~displaced-N/，各推各的会在这里指错目录）。
    -- oid 已在 classifyPending 验过语法，此处 Nothing 不可达；仍按 Bad 处理。
    let mTrashRel = quarTrashRel oid victim
    trashRel <- maybe (pure "") pure mTrashRel
    trashEx <- if isJust mTrashRel then doesFileExist (trashDir root </> trashRel) else pure False
    victimEx <- doesFileExist (root </> victim)
    case (trashEx, victimEx) of
      (True, _) -> do
        -- P3b-5 复审 #1：补记 Done 前必须核 sha——trash 位置上可能是别的
        -- 内容（同路径重试残留），盲补会把错误内容认证成「已隔离」。
        tsha <- sha256File (trashDir root </> trashRel)
        pure
          [ if tsha == sha
              then Finding "Q-DONE-LOST" Warn (T.unpack oid <> ": 已入 trash、Done 丢失 (" <> trashRel <> ")") "--repair 将补记 Done"
              else Finding "Q-DONE-LOST" Bad (T.unpack oid <> ": trash 位置内容与 Intent sha 不符 (" <> trashRel <> ")，需人工核查") ""
          ]
      (False, True) -> do
        vsha <- sha256File (root </> victim)
        let note = if vsha == sha then "victim 原位完好" else "victim 原位但内容已变"
        pure [Finding "Q2" Info (T.unpack oid <> ": 隔离未执行，" <> note <> "，重跑原计划即可") ""]
      (False, False) -> pure [Finding "Q?" Bad (T.unpack oid <> ": victim 与 trash 均不存在，需人工核查") ""]

existsAny :: FilePath -> IO Bool
existsAny p = do
  f <- doesFileExist p
  if f then pure True else doesDirectoryExist p

verifyFp :: FilePath -> Fingerprint -> IO Bool
verifyFp p (FpFileSha s) = do
  isF <- doesFileExist p
  if isF then (== s) <$> sha256File p else pure False
verifyFp p (FpDir s) = do
  isD <- doesDirectoryExist p
  if isD then (== s) <$> dirFingerprint p else pure False

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
                      else checkTarget (trashDir root </> trashRel) trashRel sha
          _ -> pure [] -- rename Done carries no content claim
 where
  checkTarget abs' rel sha = do
    ex <- doesFileExist abs'
    if not ex
      then pure [Finding "C4" Bad (T.unpack oid <> ": Done 记录的目标不存在 (" <> rel <> ")") "不删任何东西；该项标回未确认，重新生成计划"]
      else do
        actual <- sha256File abs'
        if actual == sha
          then pure []
          else
            pure
              [ Finding
                  "C4"
                  Bad
                  (T.unpack oid <> ": CORRUPT — Done 记录 sha 与盘面不符 (" <> rel <> ")")
                  "不删任何东西；将该目标视为未确认副本，重新拷贝并核查介质"
              ]

staleTmpFiles :: FilePath -> [FilePath] -> IO [FilePath]
staleTmpFiles root expected = do
  let base = pmDir root </> "tmp"
  ex <- doesDirectoryExist base
  if not ex
    then pure []
    else do
      plans <- listDirectory base
      files <- concat <$> forM plans (\p -> do
        isD <- doesDirectoryExist (base </> p)
        if isD
          then map ((base </> p) </>) <$> listDirectory (base </> p)
          else pure [base </> p])
      onlyFiles <- filterM doesFileExist files
      pure [f | f <- onlyFiles, f `notElem` expected]

deepVerify :: FilePath -> Catalog -> IO [Finding]
deepVerify root cat = do
  results <- forM (Map.elems (catEntries cat)) $ \e -> do
    let abs' = root </> enPath e
    ex <- doesFileExist abs'
    if not ex
      then pure [Finding "DEEP" Warn ("条目在盘上消失: " <> enPath e) "跑 pm scan 刷新索引"]
      else do
        actual <- sha256File abs'
        pure
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
    removeFile f -- pm 自建的 .pm/tmp 文件，从未 rename 落位，非用户数据
    putStrLn ("  修复: 清除孤儿 tmp " <> f)
  forM_ c5 $ \(oid, op) -> case op of
    OpCopy _ dstRel _ _ _ -> do
      actual <- sha256File (root </> dstRel)
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
