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

import Pm.Config (pmSubTrash, readRootInfo)
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
          dones = cancelRestores allDones
          lastN = reverse (drop (length dones - n) dones)
      if null lastN
        then pure (Left "journal 中没有可撤销的已完成操作")
        else do
          let reversedOps = map (reverseOp intents) lastN
          case sequence reversedOps of
            Left err -> pure (Left err)
            Right ops -> do
              -- P3b-12（九轮复审 minor）：身份缺席\/损坏\/不可信时不再生成一份
              -- rootId 为空的计划——execPlan 必然拒绝它，但它已经被 savePlan
              -- 写进 .pm/plans 了。生成完再过一次 validatePlan，与 loadPlan
              -- 的入口校验对称。
              minfo <- readRootInfo root
              case minfo of
                Nothing -> pure (Left (root <> " 无可用 root 标识（缺席/损坏/不可信），拒绝生成撤销计划"))
                Just info -> do
                  pid <- newPlanId
                  now <- getCurrentTime
                  let plan =
                        Plan
                          { plId = pid
                          , plKind = "undo"
                          , plRootPath = root
                          , plRootId = Just (riId info)
                          , plCreated = now
                          , plItems = [PlanItem i op StPending Nothing | (i, op) <- zip [0 ..] ops]
                          }
                  pure (either (\e -> Left ("生成的撤销计划不合法: " <> e)) (const (Right plan)) (validatePlan plan))

-- | 顺序感知的复位配对（P2.2，复审新发现）：每个 @oid~r@ 复位 Done 只取消
-- **紧邻其前最近一次**同 oid 的 Done——同一计划复位后重跑成功时，第二次
-- 真实隔离必须保持可撤销。全局「见 ~r 即整体剔除」会把后一次也吞掉。
-- P3b-5 复审 #1：组回滚的占位者位移隔离（@oid~d\<N\>@）是内核内部事务的
-- 一部分，永不进入用户可撤销序列——否则 undo 会试图把占位者搬回已由
-- victim 占据的原位。占位者本身仍在 trash（manifest 可查）。
-- P3b-6 复审 A1：后缀用 'opIdParts' 严格解析（不再 @isInfixOf "~d"@——planId
-- 含 @~d@ 时正常操作会被整体剔出 undo）；解析不出的 oid 不是 pm 生成的，
-- 不可撤销（fail-closed）。
cancelRestores
  :: [(Text, Maybe Text, Maybe FilePath)]
  -> [(Text, Maybe Text, Maybe FilePath)]
cancelRestores = reverse . go []
 where
  go acc [] = acc -- acc 为倒序（最近在前）
  go acc (d@(oid, _, _) : rest) = case opIdParts oid of
    Just (pid, ix, SfxRestore) -> go (dropMostRecent (opId pid ix) acc) rest -- ~r 自身不可撤销
    Just (_, _, SfxDisplaced _) -> go acc rest -- 位移隔离：内部事务，不可撤销
    Just (_, _, SfxPlain) -> go (d : acc) rest
    Nothing -> go acc rest
  dropMostRecent base acc = case break (\(o, _, _) -> o == base) acc of
    (pre, _ : post) -> pre <> post
    (pre, []) -> pre

-- | P3b-10（七轮复审 major）：journal 是可手编输入，撤销计划由它直接拼出
-- @.pm\/trash\/\<trashRel\>@ 与库内目标，而 'Pm.Plan.savePlan' 本身不校验
-- （校验在 loadPlan\/execPlan）。这里先验 Intent 的 Op 路径与 Done 的
-- trashRel，非法即拒绝生成计划——不把越界路径写进 @.pm\/plans@。
-- P3b-11（八轮复审 minor）：**生成结果**同样要验。反转是对称操作，而
-- 'opPathsOk' 的规则不是对称的——@.pm\/trash@ 只允许作 rename 的**源**。
-- 一次合法的复位历史（@rename .pm\/trash\/p\/v.jpg -> v.jpg@）反转后
-- @.pm\/trash@ 成了**目标**，是非法 Op；此前 'buildUndoPlan' 照样成功、
-- 'savePlan' 也不校验，直到 execItem 才拒。挡在生成处，越界路径不进
-- @.pm\/plans@。
reverseOp
  :: Map.Map Text Op
  -> (Text, Maybe Text, Maybe FilePath)
  -> Either String Op
reverseOp intents d = case reverseOp' intents d of
  Right op
    | not (opPathsOk op) ->
        Left
          ( "撤销 " <> T.unpack (fst3 d) <> " 生成的反向操作路径非法（"
              <> describeOp op
              <> "）——撤销一次复位需要独立的 redo 协议，拒绝"
          )
  other -> other
 where
  fst3 (a, _, _) = a

reverseOp'
  :: Map.Map Text Op
  -> (Text, Maybe Text, Maybe FilePath)
  -> Either String Op
reverseOp' intents (oid, msha, mtrash) = case Map.lookup oid intents of
  Nothing -> Left ("Done " <> T.unpack oid <> " 找不到对应 Intent，无法生成反向操作")
  Just op | not (opPathsOk op) -> Left ("Intent " <> T.unpack oid <> " 的路径非法（越界/盘符/ADS/.pm 内部），拒绝生成撤销计划")
  Just (OpCopy _ dstRel opSha' _ _) ->
    -- Copy 的反向 = 隔离副本（不是删除）；sha 前置条件保证只隔离
    -- 当时校验过的那份内容。
    Right (OpQuarantine dstRel (maybe opSha' id msha) ("undo:" <> oid))
  Just (OpRename old new fp) ->
    -- 内容未变，指纹在反向仍有效。
    Right (OpRename new old fp)
  Just (OpQuarantine victim sha _) -> case mtrash of
    Nothing -> Left ("Quarantine Done " <> T.unpack oid <> " 缺 trash 路径")
    Just trashRel
      | not (relPathOk trashRel) ->
          Left ("Quarantine Done " <> T.unpack oid <> " 的 trash 路径非法（" <> trashRel <> "），拒绝生成撤销计划")
      | otherwise ->
          -- 反向 = 从 trash 原位复位（同卷 rename，目标必须不存在）。
          Right (OpRename (".pm" </> pmSubTrash </> trashRel) victim (FpFileSha sha))
