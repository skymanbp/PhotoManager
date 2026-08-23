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
  , dirFingerprint
  , updateCatalog
  , outcomeLabel
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256 (..), hashWith)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  , removeFile
  , setModificationTime
  )
import System.FilePath (isRelative, splitDirectories, takeDirectory, takeExtension, takeFileName, (</>))

import Pm.Config (pmDir)
import Pm.Hash
import Pm.Journal
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Trash
import Pm.Types
import Pm.Win (moveFileNoReplace)

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
  }

defaultExecEnv :: ExecEnv
defaultExecEnv = ExecEnv {eeCheckpoint = \_ -> pure (), eeDoneSync = Buffered}

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

tmpDirFor :: FilePath -> Text -> FilePath
tmpDirFor root pid = pmDir root </> "tmp" </> T.unpack pid

tmpNameFor :: Int -> FilePath -> FilePath
tmpNameFor ix dstRel = show ix <> "-" <> takeFileName dstRel

-- | Execute a plan's pending items under the root's exclusive lock.
-- Left = lock busy. A checkpoint exception (test crash) propagates out with
-- the journal handle closed by bracket — exactly a process death.
execPlan :: ExecEnv -> Plan -> IO (Either String [(PlanItem, ItemOutcome)])
execPlan env plan = do
  let root = plRootPath plan
  r <- withRootLock root $
    withJournal root $ \j -> do
      outs <- mapM (execItem env root j (plId plan)) (plItems plan)
      now <- getCurrentTime
      jAppend j Barrier (JCleanShutdown now)
      pure outs
  pure $ case r of
    Nothing -> Left "另一个 pm 实例正持有该 root 的锁（I10），稍后重试"
    Just outs -> Right (zip (plItems plan) outs)

execItem :: ExecEnv -> FilePath -> Journal -> Text -> PlanItem -> IO ItemOutcome
execItem env root j pid item = case piStatus item of
  StSkippedByUser -> pure ONotExecuted
  StNeedsDecision _ -> pure ONotExecuted
  StPending -> do
    -- Ops address the root strictly by relative paths (no escape upward).
    if not (relOk (piOp item))
      then pure (OFailed "非法路径（绝对路径或 .. 越界），拒绝执行")
      else case piOp item of
        op@OpCopy {} -> execCopy env root j (opId pid (piIx item)) (piIx item) op
        op@OpRename {} -> execRename env root j (opId pid (piIx item)) op
        op@OpQuarantine {} -> execQuarantine env root j (opId pid (piIx item)) pid op
 where
  relOk op = all good (relPaths op)
  relPaths OpCopy {opDstRel = d} = [d]
  relPaths (OpRename o n _) = [o, n]
  relPaths (OpQuarantine v _ _) = [v]
  good p = isRelative p && ".." `notElem` splitDirectories p

-- ─── Copy (§6.1) ────────────────────────────────────────────────────────────

execCopy :: ExecEnv -> FilePath -> Journal -> Text -> Int -> Op -> IO ItemOutcome
execCopy env root j oid ix op = do
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
              eeCheckpoint env CpCopyAfterDstCheck
              t1 <- getCurrentTime
              jAppend j Barrier (JIntent oid op t1)
              eeCheckpoint env CpCopyAfterIntent
              let tdir = tmpDirFor root (planIdOf oid)
                  tmp = tdir </> tmpNameFor ix (opDstRel op)
              createDirectoryIfMissing True tdir
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
                      post <- statSnap dstAbs
                      psha <- sha256File dstAbs
                      if psha /= opSha op
                        then do
                          tf <- getCurrentTime
                          jAppend j Barrier (JFailed oid "post-move verify failed" tf)
                          pure (OFailed "落位后复核失败（矩阵 C5，交 pm doctor）")
                        else do
                          eeCheckpoint env CpCopyAfterMove
                          td <- getCurrentTime
                          jAppend j (eeDoneSync env) (JDone oid (Just (opSha op)) Nothing td)
                          pure (ODone (Just (opSha op)) (Just post) Nothing)

-- ─── Rename (§6.2) ──────────────────────────────────────────────────────────

execRename :: ExecEnv -> FilePath -> Journal -> Text -> Op -> IO ItemOutcome
execRename env root j oid op = do
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

execQuarantine :: ExecEnv -> FilePath -> Journal -> Text -> Text -> Op -> IO ItemOutcome
execQuarantine env root j oid pid op = do
  let victimAbs = root </> opVictimRel op
  ex <- doesFileExist victimAbs
  if not ex
    then pure (OConflict "victim 不存在")
    else do
      vsha <- sha256File victimAbs
      if vsha /= opVictimSha op
        then pure (OConflict "victim 内容与计划时不符（不动）")
        else do
          now0 <- getCurrentTime
          let trashRel = T.unpack pid </> opVictimRel op
              trashAbs = trashDir root </> trashRel
          appendManifest
            root
            TrashRecord
              { trVictimRel = opVictimRel op
              , trTrashRel = trashRel
              , trSha = opVictimSha op
              , trReason = opReason op
              , trPlanId = pid
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

-- | Sorted @name\\tsize@ (dirs as -1) of direct children, hashed. Cheap,
-- filesystem-agnostic identity for directory renames.
dirFingerprint :: FilePath -> IO Text
dirFingerprint dir = do
  names <- listDirectory dir
  entries <- mapM entryLine (sort names)
  let payload = TE.encodeUtf8 (T.pack (unlines entries))
      digest = hashWith SHA256 payload :: Digest SHA256
  pure (T.pack (show digest))
 where
  entryLine n = do
    isD <- doesDirectoryExist (dir </> n)
    sz <- if isD then pure (-1) else getFileSize (dir </> n)
    pure (n <> "\t" <> show sz)

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
