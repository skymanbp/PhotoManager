-- | P7：「上线命令」生成（用户裁定 2026-08-26：GUI 给一键复制入口，本地仓
-- 路径与 push 目标都可在设置页自定义，pm 只负责把命令拼好）。
--
-- 边界（不变量 I9）：pm **绝不执行 git**。这里只生成命令文本；复制、粘贴、
-- 执行都发生在用户自己的终端里。与 'Pm.Vault.gitStepsLines'（推送计划附带的
-- git 步骤）同一原则——命令生成在服务端一处，GUI 只渲染，不自己拼。
--
-- 39 轮 #2/#4 后的两条纪律：
--
--   1. **汇点复验**：checkPatch 只闸住 API/CLI 写入口，手编 config.toml 可以
--      绕过它。生成是唯一汇点，push 目标与每条要嵌进命令的路径在这里**再验
--      一次**，不合格整体拒绝（Left），不出半块可疑文本。
--   2. **永不 @git add -A@**：与 'Pm.Vault.gitStepsLines' 的「明确禁止
--      git add -A / git add .」同一条红线——展示集仓按固定类目显式 add，
--      portfolio 仓只 add photos.json；photos.json 未配置就拒绝生成而不是
--      退化成整仓 add。
module Pm.Publish
  ( publishCommands
  , pushTargetOk
  , pathArgOk
  ) where

import Data.Char (isAlphaNum, isControl)
import Data.List (intercalate)

import Pm.Config (Config (..))
import Pm.VaultCore (fixedCategories)

-- | push 目标（如 @origin main@、@git\@github.com:u\/r.git main@）的字符闸。
-- 生成的文本是要被整块复制进终端的：分号、管道、引号、反引号、@$@ 这类能让
-- 粘贴块长出第二条命令的字符一律拒绝。设置写入口（'Pm.ConfigEdit.checkPatch'
-- 与 @POST \/api\/config@ 共用）与生成汇点（'publishCommands'）都用它。
pushTargetOk :: String -> Bool
pushTargetOk s = not (null s) && length s <= 200 && all ok s
 where
  ok ch = isAlphaNum ch || ch `elem` ("-._/:@~^ " :: String)

-- | 要嵌进命令行双引号里的**路径**的字符闸（39 轮 #2）。@$@ 在 PowerShell
-- 与 bash 的双引号内都触发展开——@D:\\repo$(...)@ 是合法 Windows 路径，粘贴
-- 即执行子表达式（实测）；反引号是 PowerShell 转义、@%@ 是 cmd 变量展开、
-- @!@ 是交互式 bash 的历史展开、@"@ 直接破坏引号结构。含这些字符的路径
-- **拒绝生成**（让用户手动执行），而不是尝试逐 shell 转义——同一块文本要
-- 粘进哪个 shell 由用户定，不存在对所有 shell 都安全的转义形。
pathArgOk :: FilePath -> Bool
pathArgOk p = not (null p) && all ok p
 where
  ok ch = not (isControl ch) && ch `notElem` ("\"$`%!" :: String)

-- | 生成两仓上线命令（纯函数；@GET \/api\/publish-commands@ 原样返回）。
-- 配置了哪侧就出哪侧；两侧都没配 → Left 指路设置页；任一项复验不过 →
-- 整体 Left（不出半块可疑文本）。
publishCommands :: Config -> Either String [String]
publishCommands c = case (cfgVaultPath c, cfgPortfolioDir c) of
  (Nothing, Nothing) -> Left "还没有可生成的上线命令：先在设置页配置 vault 展示集目录或 portfolio 仓路径"
  (mv, mp) -> do
    vs <- maybe (Right []) vaultSec mv
    ps <- maybe (Right []) pfSec mp
    pure (vs <> ps)
 where
  q p = "\"" <> p <> "\""
  gitC d args = "git -C " <> q d <> " " <> args
  push t = "push" <> maybe "" (" " <>) t
  checkPath what p
    | pathArgOk p = Right p
    | otherwise =
        Left (what <> " 路径含无法安全嵌入命令的字符（\" $ ` % ! 或控制符）：" <> p <> " ——不生成，请手动执行")
  checkPush what mt = case mt of
    Nothing -> Right Nothing
    Just t
      | pushTargetOk t -> Right (Just t)
      | otherwise -> Left (what <> " 的 push 目标不合法（配置文件被手改过？）：" <> t)
  vaultSec v = do
    v' <- checkPath "vault 展示集" v
    t <- checkPush "展示集仓" (cfgVaultPush c)
    pure
      [ "# ① 展示集仓（推送前建议先看 pm vault status 是否全绿；显式类目，永不整仓 add）"
      , gitC v' ("add " <> intercalate " " fixedCategories)
      , gitC v' "commit -m \"photos: 更新展示集\""
      , gitC v' (push t)
      ]
  pfSec dir = do
    d <- checkPath "portfolio 仓" dir
    j <- case cfgPhotosJson c of
      Nothing ->
        Left "portfolio 仓已配置但 photos.json 路径未设——不生成整仓 add（会把无关改动一起推上去）；先在设置页补 photos.json"
      Just j -> checkPath "photos.json" j
    t <- checkPush "portfolio 仓" (cfgPortfolioPush c)
    pure
      [ "# ② portfolio 仓（只提交 photos.json；它由你在该仓里更新，pm 不写它）"
      , gitC d ("add " <> q j)
      , gitC d "commit -m \"photos: 同步 photos.json\""
      , gitC d (push t)
      ]
