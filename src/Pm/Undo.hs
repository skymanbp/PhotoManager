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
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.FilePath ((</>))

import Pm.Config (readRootInfo)
import Pm.Journal
import Pm.Op
import Pm.Plan
import Pm.Types (RootInfo (..))

-- | Undo the last @n@ Done operations (most recent first in the plan).
-- §6.5 自动复位产生的 @…~r@ 复位 rename 与其配对的 Quarantine 互为净零，
-- 一起从可撤销序列剔除——撤销「一次已被自动回滚的隔离」没有意义且会把
-- victim 再次搬进 trash。
buildUndoPlan :: FilePath -> Int -> IO (Either String Plan)
buildUndoPlan root n = do
  (entries, warns) <- readJournal root
  case [w | w <- warns, take 4 w /= "torn"] of
    (w : _) -> pure (Left ("journal 损坏，先跑 pm doctor: " <> w))
    [] -> do
      let intents = Map.fromList [(jeOpId e, jeOp e) | e@JIntent {} <- entries]
          allDones = [(jeOpId e, jeVerifiedSha e, jeTrashRel e) | e@JDone {} <- entries]
          restoredBases =
            Set.fromList [T.dropEnd 2 oid | (oid, _, _) <- allDones, "~r" `T.isSuffixOf` oid]
          dones =
            [ d
            | d@(oid, _, _) <- allDones
            , not ("~r" `T.isSuffixOf` oid)
            , not (oid `Set.member` restoredBases)
            ]
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
              minfo <- readRootInfo root
              pure . Right $
                Plan
                  { plId = pid
                  , plKind = "undo"
                  , plRootPath = root
                  , plRootId = riId <$> minfo
                  , plCreated = now
                  , plItems = [PlanItem i op StPending Nothing | (i, op) <- zip [0 ..] ops]
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
