{-# LANGUAGE OverloadedStrings #-}

-- | Reverse-plan generation from the journal (DESIGN.md §5 pm undo).
-- Only ops with a Done record are undoable (Intent-without-Done belongs to
-- doctor); the generated plan re-verifies current disk content at execution
-- time through the normal Op preconditions, so a target that changed since
-- the original operation is refused, never blindly reverted.
module Pm.Undo
  ( buildUndoPlan
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.FilePath ((</>))

import Pm.Journal
import Pm.Op
import Pm.Plan

-- | Undo the last @n@ Done operations (most recent first in the plan).
buildUndoPlan :: FilePath -> Int -> IO (Either String Plan)
buildUndoPlan root n = do
  (entries, warns) <- readJournal root
  case [w | w <- warns, take 4 w /= "torn"] of
    (w : _) -> pure (Left ("journal 损坏，先跑 pm doctor: " <> w))
    [] -> do
      let intents = Map.fromList [(jeOpId e, jeOp e) | e@JIntent {} <- entries]
          dones = [(jeOpId e, jeVerifiedSha e, jeTrashRel e) | e@JDone {} <- entries]
          lastN = reverse (drop (length dones - n) dones)
      if null lastN
        then pure (Left "journal 中没有可撤销的已完成操作")
        else do
          let reversedOps = map (reverseOp intents) lastN
          case sequence reversedOps of
            Left err -> pure (Left err)
            Right ops -> do
              pid <- newPlanId
              now <- getCurrentTime
              pure . Right $
                Plan
                  { plId = pid
                  , plKind = "undo"
                  , plRootPath = root
                  , plCreated = now
                  , plItems = [PlanItem i op StPending | (i, op) <- zip [0 ..] ops]
                  }

reverseOp
  :: Map.Map Text Op
  -> (Text, Maybe Text, Maybe FilePath)
  -> Either String Op
reverseOp intents (oid, msha, mtrash) = case Map.lookup oid intents of
  Nothing -> Left ("Done " <> T.unpack oid <> " 找不到对应 Intent，无法生成反向操作")
  Just (OpCopy _ dstRel opSha' _ _) ->
    -- Copy 的反向 = 隔离副本（不是删除）；sha 前置条件保证只隔离
    -- 当时校验过的那份内容。
    Right (OpQuarantine dstRel (maybe opSha' id msha) ("undo:" <> oid))
  Just (OpRename old new fp) ->
    -- 内容未变，指纹在反向仍有效。
    Right (OpRename new old fp)
  Just (OpQuarantine victim sha _) -> case mtrash of
    Nothing -> Left ("Quarantine Done " <> T.unpack oid <> " 缺 trash 路径")
    Just trashRel ->
      -- 反向 = 从 trash 原位复位（同卷 rename，目标必须不存在）。
      Right (OpRename (".pm" </> "trash" </> trashRel) victim (FpFileSha sha))
