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

import Control.Monad (filterM, forM, forM_, unless, when)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory, removeFile)
import System.FilePath ((</>))

import Pm.Catalog (loadCatalog)
import Pm.Config (pmDir, readRootInfo)
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

data Terminal = TDone (Maybe Text) (Maybe FilePath) | TFailed
  deriving (Show, Eq)

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
      intents = Map.fromList [(jeOpId e, jeOp e) | e@JIntent {} <- entries]
      terminals =
        Map.fromList $
          mapMaybe
            ( \e -> case e of
                JDone i s t _ -> Just (i, TDone s t)
                JFailed i _ _ -> Just (i, TFailed)
                _ -> Nothing
            )
            entries
      -- Done entries after the LAST clean-shutdown marker = the verification
      -- window for an interrupted batch (§6.4).
      afterClean = lastSegment entries
      donesAfterClean = [(jeOpId e, jeVerifiedSha e, jeTrashRel e) | e@JDone {} <- afterClean]
      pending = Map.toList (intents `Map.difference` terminals)
      -- Exec 组内自动复位（§6.5）/undo 复位会把隔离文件从 trash 移回原位，
      -- 且该 rename 有自己的 Intent+Done。这些 trash 源路径要从 C4 的
      -- 「Done 目标应仍在」检查中排除，否则复位会被误报为 CORRUPT。
      restoredFrom =
        Set.fromList
          [ opOldRel op
          | (oid, op@OpRename {}) <- Map.toList intents
          , Just (TDone _ _) <- [Map.lookup oid terminals] -- Failed 的复位没动文件，不豁免
          ]

  pendingFindings <- concat <$> mapM (classifyPending root) pending
  c4Findings <- concat <$> mapM (verifyDone root intents restoredFrom) donesAfterClean

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

  let allFindings =
        journalFindings <> pendingFindings <> c4Findings <> q1 <> manifestWarns <> staleFindings <> ageFinding

  when (doRepair opts) (applyRepairs root allFindings pending stale)

  let worst = maximum (Info : map fSeverity allFindings)
      code = if worst >= Warn then 1 else 0
  pure (allFindings, code)

-- Entries after the last JCleanShutdown (whole list if none).
lastSegment :: [JEntry] -> [JEntry]
lastSegment es = go es es
 where
  go acc [] = acc
  go _ (JCleanShutdown _ : rest) = go rest rest
  go acc (_ : rest) = go acc rest

pendingTmp :: FilePath -> (Text, Op) -> Maybe FilePath
pendingTmp root (oid, OpCopy _ dstRel _ _ _) =
  case T.splitOn "#" oid of
    [pid, ixT] | Just ix <- readMaybeInt (T.unpack ixT) -> Just (tmpDirFor root pid </> tmpNameFor ix dstRel)
    _ -> Nothing
pendingTmp _ _ = Nothing

readMaybeInt :: String -> Maybe Int
readMaybeInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing

classifyPending :: FilePath -> (Text, Op) -> IO [Finding]
classifyPending root (oid, op) = case op of
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
    let trashRel = T.unpack (planIdOfOp oid) </> victim
    trashEx <- doesFileExist (trashDir root </> trashRel)
    victimEx <- doesFileExist (root </> victim)
    case (trashEx, victimEx) of
      (True, _) -> pure [Finding "Q-DONE-LOST" Warn (T.unpack oid <> ": 已入 trash、Done 丢失 (" <> trashRel <> ")") "--repair 将补记 Done"]
      (False, True) -> do
        vsha <- sha256File (root </> victim)
        let note = if vsha == sha then "victim 原位完好" else "victim 原位但内容已变"
        pure [Finding "Q2" Info (T.unpack oid <> ": 隔离未执行，" <> note <> "，重跑原计划即可") ""]
      (False, False) -> pure [Finding "Q?" Bad (T.unpack oid <> ": victim 与 trash 均不存在，需人工核查") ""]
 where
  planIdOfOp o = T.takeWhile (/= '#') o

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
-- @restoredFrom@ = trash 源路径集合，其文件已被 journaled 复位 rename 移走
-- （§6.5 自动复位 / undo）——对应的 Quarantine Done 不再检查 trash 目标。
verifyDone :: FilePath -> Map.Map Text Op -> Set.Set FilePath -> (Text, Maybe Text, Maybe FilePath) -> IO [Finding]
verifyDone root intents restoredFrom (oid, msha, mtrash) =
  case Map.lookup oid intents of
    Nothing -> pure [Finding "C3" Info (T.unpack oid <> ": Done 无对应 Intent（journal 头部轮转或跨批），跳过") ""]
    Just op -> case (op, msha) of
      (OpCopy _ dstRel _ _ _, Just sha) -> checkTarget (root </> dstRel) dstRel sha
      (OpQuarantine _ _ _, Just sha)
        | Just trashRel <- mtrash ->
            if (".pm" </> "trash" </> trashRel) `Set.member` restoredFrom
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
        , any (\f -> fRow f `elem` ["C2", "R2", "Q-DONE-LOST"] && (T.unpack oid <> ":") `isPrefixOfStr` fDetail f && fSeverity f == Warn) findings
        ]
      c5 =
        [ (oid, op)
        | (oid, op) <- pending
        , any (\f -> fRow f == "C5" && (T.unpack oid <> ":") `isPrefixOfStr` fDetail f) findings
        ]
  unless (null repairDone) $
    withJournal root $ \j ->
      forM_ repairDone $ \(oid, op) -> do
        now <- getCurrentTime
        let (sha, trash) = case op of
              OpCopy _ _ s _ _ -> (Just s, Nothing)
              OpQuarantine v s _ -> (Just s, Just (T.unpack (T.takeWhile (/= '#') oid) </> v))
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
