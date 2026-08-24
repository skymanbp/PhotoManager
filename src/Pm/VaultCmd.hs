{-# LANGUAGE OverloadedStrings #-}

-- | vault 的**决定层**命令（与 'Pm.BackupCmd' 同款拆分：'Pm.Vault' 触及 750
-- 行预算）。这里不生成计划、不碰照片，只改主库 @.pm@ 里的「暂不同步」记录。
--
-- 校验器 'holdRequest' 是纯函数，CLI（'runVaultHold'）与 `pm serve` 的
-- @POST /api/vault/hold@ 共用同一处判定——与 push 那条路径同一原则。
module Pm.VaultCmd (holdRequest, runVaultHold) where

import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, getCurrentTime)

import Pm.Config (Config (..))
import Pm.Types
import Pm.Vault (VaultDiff (..), VaultReport (..), computeVault)
import Pm.VaultHold (VaultHold (..), applyHoldOps, readHolds, writeHolds)

-- | 校验一组「标记 / 撤销」并算出新名单。fail-closed：任一条不合法就整体
-- 不写，并把**全部**错误一次返回（GUI 能一次标完）。
--
-- 标记的文件必须当前是 NEW（只有 NEW 才谈得上同不同步）且本轮读取稳定
-- （要记下决定时的 sha）；撤销的文件必须在名单里。
holdRequest ::
  VaultReport ->
  [VaultHold] ->
  [FilePath] ->
  [FilePath] ->
  UTCTime ->
  Either [String] [VaultHold]
holdRequest r olds toHold toUnhold now
  | not (null errs) = Left errs
  | otherwise = Right (applyHoldOps olds adds dels)
 where
  hs = nub toHold
  us = nub toUnhold
  errs =
    ["没有给文件名：hold 与 unhold 都是空的" | null hs && null us]
      <> ["同一文件不能同时标记与撤销：" <> n | n <- hs, n `elem` us]
      <> [ n <> " 不在 NEW 集合里（只有 NEW 需要决定同不同步；看 pm vault status）"
         | n <- hs
         , n `notElem` vdNew (vrDiff r)
         ]
      <> [ n <> " 本轮读取不稳定，记不下决定时的 sha，稍后重试"
         | n <- hs
         , n `elem` vdNew (vrDiff r)
         , not (Map.member n (vrSrcMeta r))
         ]
      <> [n <> " 不在暂不同步名单里" | n <- us, n `notElem` map vhName olds]
  adds = [VaultHold n (enSha e) now Nothing | n <- hs, Just e <- [Map.lookup n (vrSrcMeta r)]]
  dels = us

-- | `pm vault hold|unhold <文件…>`。**只**写主库 @.pm/vault-holds.json@：
-- vault 仓与照片字节零改动，因此不走两段式计划——这是一条随时可改的本地
-- 决定，撤销就是 @pm vault unhold@。身份闸两道叠加：'computeVault' 里的
-- 'Pm.Config.requireMain' + 'Pm.VaultHold.writeHolds' 里的
-- 'Pm.Config.requireWritable'（I11）。
runVaultHold :: Bool -> [FilePath] -> Config -> IO Int
runVaultHold hold files cfg = do
  er <- computeVault True cfg
  case er of
    Left (msg, code) -> putStrLn msg >> pure code
    Right r -> do
      let root = cfgMainPath cfg
      eholds <- readHolds root
      case eholds of
        Left m -> putStrLn m >> pure 2
        Right olds -> do
          now <- getCurrentTime
          let (hs, us) = if hold then (files, []) else ([], files)
          case holdRequest r olds hs us now of
            Left errs -> mapM_ (putStrLn . ("  ✗ " <>)) errs >> pure 2
            Right kept -> do
              w <- writeHolds root kept
              case w of
                Left m -> putStrLn m >> pure 2
                Right () -> do
                  putStrLn
                    ( (if hold then "⏸ 已标记暂不同步 " else "▶ 已恢复待同步 ")
                        <> show (length (nub files))
                        <> " 张（名单现共 "
                        <> show (length kept)
                        <> " 条）："
                        <> unwords (nub files)
                    )
                  putStrLn "  照片与 vault 仓零改动——这只是主库 .pm 里的一条本地决定，随时可改。"
                  pure 0
