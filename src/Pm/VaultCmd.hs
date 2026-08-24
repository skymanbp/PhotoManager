{-# LANGUAGE OverloadedStrings #-}

-- | vault 的**决定层**命令（与 'Pm.BackupCmd' 同款拆分：'Pm.Vault' 触及 750
-- 行预算）。这里不生成计划、不碰照片，只改主库 @.pm@ 里的「暂不同步」记录。
--
-- 三层共用，CLI（'runVaultHold'）与 `pm serve` 的 @POST /api/vault/hold@ 走的
-- 是同一套：事务壳 'withHoldsTxn'（预检 → root lock）、IO 层 'holdOpsIO'
-- （本轮真实 sha）、纯校验 'holdRequest'。
module Pm.VaultCmd (holdRequest, holdOpsIO, withHoldsTxn, runVaultHold) where

import Data.List (nub)
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)

import Pm.Config (Config (..), requireMain)
import Pm.Lock (withRootLock)
import Pm.Vault (VaultDiff (..), VaultReport (..), computeVault, freshSrcSha)
import Pm.VaultHold (VaultHold (..), applyHoldOps, readHolds, writeHolds)

-- | 名单的「读 → 校验 → 写」必须是**一个跨进程事务**（I10）：两个 pm（CLI 与
-- GUI 的 serve，或两个 serve）各自读到同一份旧名单、各自写出全量结果，后写者
-- 会整份覆盖先写者的决定——丢更新（codex 二十一轮 major）。serve 的进程内
-- MVar 挡不住这个，必须是主库的 @.pm/lock@。
--
-- **取锁前先做零写入的身份预检**（'requireMain'）：'withRootLock' 会创建
-- @.pm@ 并打开 @.pm/lock@，匿名 root 或 I11 失效的 root 若先取锁再校验，就会
-- 在被拒绝之前先落下一个 @.pm/lock@（codex 二十二轮 major）。同 'Pm.Exec' 的
-- 「取锁前预检、锁内复检」次序：锁内 'computeVault' 仍会再过一次 'requireMain'。
--
-- 锁被占用时不排队：直接告知调用方（同 `pm apply` 口径），退出码 4。
withHoldsTxn ::
  Config ->
  ([VaultHold] -> VaultReport -> IO (Either (String, Int) a)) ->
  IO (Either (String, Int) a)
withHoldsTxn cfg act = do
  let root = cfgMainPath cfg
  pre <- requireMain cfg
  case pre of
    Left m -> pure (Left (m, 2))
    Right _ -> do
      m <- withRootLock root $ do
        er <- computeVault True cfg
        case er of
          Left e -> pure (Left e)
          Right r -> do
            eh <- readHolds root
            case eh of
              Left msg -> pure (Left (msg, 2))
              Right olds -> act olds r
      pure (maybe (Left ("另一个 pm 正在写主库（.pm/lock 被占用）——稍后重试", 4)) id m)

-- | 校验一组「标记 / 撤销」并算出新名单。fail-closed：任一条不合法就整体
-- 不写，并把**全部**错误一次返回（GUI 能一次标完）。
--
-- @freshHold@ 是本轮**真实重算**的 (名字, sha)——由 'holdOpsIO' 取；'Nothing'
-- 表示本轮读不稳定。纯函数不碰 IO，便于单测。
holdRequest ::
  VaultReport ->
  [VaultHold] ->
  [(FilePath, Maybe Text)] ->
  [FilePath] ->
  UTCTime ->
  Either [String] [VaultHold]
holdRequest r olds freshHold toUnhold now
  | not (null errs) = Left errs
  | otherwise = Right (applyHoldOps olds adds dels)
 where
  hs = map fst freshHold
  us = nub toUnhold
  errs =
    ["没有给文件名：hold 与 unhold 都是空的" | null hs && null us]
      <> ["同一文件不能同时标记与撤销：" <> n | n <- hs, n `elem` us]
      <> [ n <> " 不在 NEW 集合里（只有 NEW 需要决定同不同步；看 pm vault status）"
         | n <- hs
         , n `notElem` vdNew (vrDiff r)
         ]
      <> [ n <> " 本轮读取不稳定，记不下决定时的 sha，稍后重试"
         | (n, Nothing) <- freshHold
         , n `elem` vdNew (vrDiff r)
         ]
      <> [n <> " 不在暂不同步名单里" | n <- us, n `notElem` map vhName olds]
  adds = [VaultHold n sha now Nothing | (n, Just sha) <- freshHold]
  dels = us

-- | 'holdRequest' 的 IO 外壳：把要标记的名字**本轮真实**重 hash 一遍再交给
-- 纯校验。决定里存的 sha 只能来自这里——从 'vrSrcMeta' 取等于把主库 catalog
-- 的缓存值写进决定（二十二轮 major）。CLI 与 API 共用。
holdOpsIO ::
  VaultReport ->
  [VaultHold] ->
  [FilePath] ->
  [FilePath] ->
  IO (Either [String] [VaultHold])
holdOpsIO r olds toHold toUnhold = do
  fresh <- mapM (\n -> (,) n <$> freshShaOrSkip n) (nub toHold)
  now <- getCurrentTime
  pure (holdRequest r olds fresh toUnhold now)
 where
  -- 不在 NEW 的名字不必读盘：纯校验会先把它拒掉，报错更准也不做无谓 IO。
  freshShaOrSkip n
    | n `notElem` vdNew (vrDiff r) = pure Nothing
    | otherwise = freshSrcSha r n

-- | `pm vault hold|unhold <文件…>`。**只**写主库 @.pm/vault-holds.json@：
-- vault 仓与照片字节零改动，因此不走两段式计划——这是一条随时可改的本地
-- 决定，撤销就是 @pm vault unhold@。身份闸四道叠加：取锁前 'requireMain' 预检、
-- root lock（I10）、锁内 'computeVault' 的 'requireMain' 复检、
-- 'Pm.VaultHold.writeHolds' 的 'Pm.Config.requireWritable'（I11）。
runVaultHold :: Bool -> [FilePath] -> Config -> IO Int
runVaultHold hold files cfg = do
  res <- withHoldsTxn cfg $ \olds r -> do
    let (hs, us) = if hold then (files, []) else ([], files)
    eops <- holdOpsIO r olds hs us
    case eops of
      Left errs -> pure (Left (unlines (map ("  ✗ " <>) errs), 2))
      Right kept -> do
        w <- writeHolds (cfgMainPath cfg) kept
        pure $ case w of
          Left m -> Left (m, 2)
          Right () -> Right (length kept)
  case res of
    Left (msg, code) -> putStr (ensureNl msg) >> pure (if code == 4 then 2 else code)
    Right n -> do
      putStrLn
        ( (if hold then "⏸ 已标记暂不同步 " else "▶ 已恢复待同步 ")
            <> show (length (nub files))
            <> " 张（名单现共 "
            <> show n
            <> " 条）："
            <> unwords (nub files)
        )
      putStrLn "  照片与 vault 仓零改动——这只是主库 .pm 里的一条本地决定，随时可改。"
      pure 0
 where
  ensureNl s = if null s || last s == '\n' then s else s <> "\n"
