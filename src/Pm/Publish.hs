-- | P7：「上线命令」生成（用户裁定 2026-08-26：GUI 给一键复制入口，本地仓
-- 路径与 push 目标都可在设置页自定义，pm 只负责把命令拼好）。
--
-- 边界（不变量 I9）：pm **绝不执行 git**。这里只生成命令文本；复制、粘贴、
-- 执行都发生在用户自己的终端里。与 'Pm.Vault.gitStepsLines'（推送计划附带的
-- git 步骤）同一原则——命令生成在服务端一处，GUI 只渲染，不自己拼。
module Pm.Publish
  ( publishCommands
  , pushTargetOk
  ) where

import Data.Char (isAlphaNum)

import Pm.Config (Config (..))

-- | push 目标（如 @origin main@、@git\@github.com:u\/r.git main@）的字符闸。
-- 生成的文本是要被整块复制进终端的：分号、管道、引号、反引号、@$@ 这类能让
-- 粘贴块长出第二条命令的字符一律拒绝。设置写入口（'Pm.ConfigEdit.checkPatch'
-- 与 @POST \/api\/config@ 共用）是唯一判定处，这里只提供判定。
pushTargetOk :: String -> Bool
pushTargetOk s = not (null s) && length s <= 200 && all ok s
 where
  ok ch = isAlphaNum ch || ch `elem` ("-._/:@~^ " :: String)

-- | 生成两仓上线命令（纯函数；@GET \/api\/publish-commands@ 原样返回）。
-- 配置了哪侧就出哪侧；两侧都没配 → Left 指路设置页。
publishCommands :: Config -> Either String [String]
publishCommands c = case vaultSec <> pfSec of
  [] -> Left "还没有可生成的上线命令：先在设置页配置 vault 展示集目录或 portfolio 仓路径"
  ls -> Right ls
 where
  q p = "\"" <> p <> "\""
  gitC d args = "git -C " <> q d <> " " <> args
  push t = "push" <> maybe "" (" " <>) t
  vaultSec = case cfgVaultPath c of
    Nothing -> []
    Just v ->
      [ "# ① 展示集仓（推送前建议先看 pm vault status 是否全绿）"
      , gitC v "add -A"
      , gitC v "commit -m \"photos: 更新展示集\""
      , gitC v (push (cfgVaultPush c))
      ]
  pfSec = case cfgPortfolioDir c of
    Nothing -> []
    Just dir ->
      [ "# ② portfolio 仓（photos.json 由你在该仓里更新后再提交；pm 不写它）"
      ]
        <> ( case cfgPhotosJson c of
              Just j -> [gitC dir ("add " <> q j)]
              Nothing ->
                [ "#（未设 photos.json 路径——add -A 会带上该仓全部改动，先 git status 看清）"
                , gitC dir "add -A"
                ]
           )
        <> [ gitC dir "commit -m \"photos: 同步 photos.json\""
           , gitC dir (push (cfgPortfolioPush c))
           ]
