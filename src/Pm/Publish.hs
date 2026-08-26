-- | P7：「上线命令」生成（用户裁定 2026-08-26：GUI 给一键复制入口，本地仓
-- 路径与 push 目标都可在设置页自定义，pm 只负责把命令拼好）。
--
-- 边界（不变量 I9）：pm **绝不执行 git**。这里只生成命令文本；复制、粘贴、
-- 执行都发生在用户自己的终端里。展示集仓的三条步骤 'vaultCommands' 是**唯一**
-- 生成点——push 收尾（'Pm.Vault.gitStepsLines'）与上线命令共用，GUI 只渲染。
--
-- 39/40 轮后的三条纪律：
--
--   1. **解析而非过滤**（40 轮 #2/#4 的上游根因）：配置值不再「黑名单过滤后
--      原样拼进命令」——黑名单要逐 shell 枚举能长出第二条命令的字符，39 轮补
--      展开字符、40 轮补引号终结符（bash 双引号内尾随 @\\@ 把引号撑到下一行）
--      与选项前缀（@git add "-A"@ 实测 = 整仓 add），无法证明补全。改为把值
--      **解析**成结构（'cmdPath' 盘符 + 分量、'pushTarget' 段列表），按白名单
--      验证，再**重新渲染**：路径分隔符统一 @/@（git 在 Windows 接受；bash /
--      PowerShell / cmd 的双引号内都没有转义语义），操作数前一律 @--@。
--   2. **汇点复验**：checkPatch 只闸住 API/CLI 写入口，手编 config.toml 可以
--      绕过它。生成是唯一汇点，每个要嵌进命令的值在这里**再验一次**，不合格
--      整体拒绝（Left），不出半块可疑文本。
--   3. **永不 @git add -A@**：展示集仓按固定类目显式 add，portfolio 仓只 add
--      仓内相对路径的 photos.json；photos.json 未配置或不在仓内就拒绝生成。
module Pm.Publish
  ( publishCommands
  , vaultCommands
  , CmdPath
  , cmdPath
  , renderCmdPath
  , pathArgOk
  , pushTarget
  , pushTargetOk
  ) where

import Data.Char (isAlphaNum, isAscii, isAsciiLower, isAsciiUpper, isControl, toLower)
import Data.Either (isRight)
import Data.List (dropWhileEnd, isPrefixOf)

import Pm.Config (Config (..))
import Pm.VaultCore (fixedCategories)

-- | 已验证可嵌入命令行的路径：只接受盘符绝对路径，分量字符走白名单，
-- 渲染形态固定为 @X:/a/b@（无尾随分隔符）。盘符开头必是字母——argv 位置上
-- 永远不会以 @-@ 开头被 git 当成选项。
newtype CmdPath = CmdPath {renderCmdPath :: String}
  deriving (Show, Eq)

-- | 分量字符白名单：字母数字（含 CJK）、空格与 @-_.()'+,=\@~#&@。这些在三个
-- shell 的双引号内都是字面量；@" $ ` \\ % ! ;@ 与控制符一律不在名单上。
compCharOk :: Char -> Bool
compCharOk ch = isAlphaNum ch || ch `elem` (" -_.()'+,=@~#&" :: String)

cmdPath :: FilePath -> Either String CmdPath
cmdPath p
  | length p > 240 = Left "超过 240 字符"
  | otherwise = case p of
      (d : ':' : sep : rest)
        | (isAsciiUpper d || isAsciiLower d) && isSep sep -> do
            let comps = dropWhileEnd null (splitSeps rest)
            mapM_ compOk comps
            pure (CmdPath (d : ":/" <> joinSlash comps))
      _ -> Left "只接受盘符绝对路径（如 D:\\目录）"
 where
  isSep c = c == '\\' || c == '/'
  splitSeps s = case break isSep s of
    (a, []) -> [a]
    (a, _ : b) -> a : splitSeps b
  joinSlash = foldr1' (\a b -> a <> "/" <> b)
  foldr1' _ [] = ""
  foldr1' f xs = foldr1 f xs
  compOk c
    | null c = Left "含空分量（连续分隔符）"
    | c == "." || c == ".." = Left "含 . 或 .. 分量"
    | last c == ' ' || last c == '.' = Left ("分量以空格或点结尾: " <> c)
    | not (all compCharOk c) = Left ("分量含白名单外字符: " <> c)
    | otherwise = Right ()

-- | 便捷谓词（测试与入口校验用）。
pathArgOk :: FilePath -> Bool
pathArgOk = isRight . cmdPath

-- | push 目标语法：@<remote> [<refspec>]@，最多两段、单个空格分隔；每段以
-- ASCII 字母数字**开头**（永远不会是选项 @-x@、强推 @+ref@ 或删远端分支的
-- @:branch@ 形态），其余只含字母数字与 @-._/:\@~^@。设置写入口
-- （'Pm.ConfigEdit.checkPatch'）与生成汇点（'publishCommands'）都用它。
pushTarget :: String -> Either String [String]
pushTarget s
  | length s > 200 = Left "超过 200 字符"
  | null ts = Left "为空"
  | s /= unwords ts = Left "多余空白"
  | length ts > 2 = Left "须为 <remote> [<refspec>] 两段以内"
  | otherwise = mapM tok ts
 where
  ts = words s
  tok t = case t of
    [] -> Left "空段"
    (h : _)
      | not (asciiAlnum h) -> Left ("段须以字母数字开头（拒绝选项、强推与删除形态）: " <> t)
      | not (all tokCh t) -> Left ("段含白名单外字符: " <> t)
      | otherwise -> Right t
  tokCh c = asciiAlnum c || c `elem` ("-._/:@~^" :: String)
  asciiAlnum c = isAscii c && isAlphaNum c

pushTargetOk :: String -> Bool
pushTargetOk = isRight . pushTarget

-- ─── 渲染原语（模块内共用） ─────────────────────────────────────────────────

q :: String -> String
q s = "\"" <> s <> "\""

gitC :: CmdPath -> String -> String
gitC d args = "git -C " <> q (renderCmdPath d) <> " " <> args

push :: [String] -> String
push ts = "push" <> (if null ts then "" else " -- " <> unwords ts)

checkPath :: String -> FilePath -> Either String CmdPath
checkPath what p = case cmdPath p of
  Right d -> Right d
  Left why -> Left (what <> " 路径无法安全嵌入命令（" <> why <> "）：" <> p <> " ——不生成，请手动执行")

checkPush :: String -> Maybe String -> Either String [String]
checkPush what mt = case mt of
  Nothing -> Right []
  Just t -> case pushTarget t of
    Right ts -> Right ts
    Left why -> Left (what <> " 的 push 目标不合法（" <> why <> "；配置文件被手改过？）：" <> t)

-- | 展示集仓的三条 git 步骤（add → commit → push），**唯一**生成点：上线命令
-- 与 push 收尾（'Pm.Vault.gitStepsLines'）共用。第一方自审 R2：P7 之前的收尾
-- 生成器硬打 @cd \<dir\>@（不加引号）与 @git push origin main@——无视设置里的
-- push 目标，也不过 'cmdPath'；两个生成器出两种文本正是 25 轮 rawExts 那类
-- 分叉。类目只认 'fixedCategories'（add 的操作数语法就是「固定类目名」，按
-- 语法验而不是过滤）；commit 信息由 pm 自己拼（计划 id 已过 isValidPlanId），
-- 仍按白名单验一次。
vaultCommands :: Config -> FilePath -> [String] -> String -> Either String [String]
vaultCommands c dir cats msg = do
  d <- checkPath "vault 展示集" dir
  t <- checkPush "展示集仓" (cfgVaultPush c)
  cs <- case filter (`notElem` fixedCategories) cats of
    _ | null cats -> Left "没有要 add 的类目"
    [] -> Right cats
    bad -> Left ("类目不在固定名单里: " <> unwords bad)
  m <-
    if not (null msg) && all msgOk msg
      then Right msg
      else Left "commit 信息含引号/转义/展开字符或控制符"
  pure [gitC d ("add -- " <> unwords cs), gitC d ("commit -m " <> q m), gitC d (push t)]
 where
  msgOk ch = ch `notElem` ("\"\\$`!%" :: String) && not (isControl ch)

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
  vaultSec v =
    ("# ① 展示集仓（推送前建议先看 pm vault status 是否全绿；显式类目，永不整仓 add）" :)
      <$> vaultCommands c v fixedCategories "photos: 更新展示集"
  pfSec dir = do
    d <- checkPath "portfolio 仓" dir
    j <- case cfgPhotosJson c of
      Nothing ->
        Left "portfolio 仓已配置但 photos.json 路径未设——不生成整仓 add（会把无关改动一起推上去）；先在设置页补 photos.json"
      Just j -> checkPath "photos.json" j
    rel <- case relUnder d j of
      Just r -> Right r
      Nothing -> Left ("photos.json 不在 portfolio 仓内（" <> renderCmdPath j <> " ∉ " <> renderCmdPath d <> "）——不生成")
    t <- checkPush "portfolio 仓" (cfgPortfolioPush c)
    pure
      [ "# ② portfolio 仓（只提交 photos.json；它由你在该仓里更新，pm 不写它）"
      , gitC d ("add -- " <> q rel)
      , gitC d "commit -m \"photos: 同步 photos.json\""
      , gitC d (push t)
      ]
  -- 仓内相对路径（Windows 路径不分大小写，按折叠后比较）；不在仓内 → Nothing。
  relUnder (CmdPath base) (CmdPath full)
    | map toLower (base <> "/") `isPrefixOf` map toLower full = Just (drop (length base + 1) full)
    | otherwise = Nothing
