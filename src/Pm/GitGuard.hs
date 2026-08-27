{-# LANGUAGE OverloadedStrings #-}

-- | I11 守卫核心（内核级）：任何 root 若处于 git 工作树内，pm 的 @.pm\/@ 必须
-- 被有效忽略才允许在其中建 root、写 journal\/tmp\/trash。放在独立的小模块里
-- 是为了让 'Pm.Exec' 在执行锁内**无条件**调用（P3b-5 复审 #3：只靠可覆盖的
-- ExecEnv 钩子，库层调用者一个 @execPlan defaultExecEnv@ 就绕过去了），
-- 'Pm.Vault' 建 vault root、'Pm.Commands' 的 init\/backup init 建主库\/备份
-- root 前都走同一函数（P3b-6 复审：守卫只按 role 运行会被改写 role 绕过，
-- 且 init 入口原先无守卫）。pm 不执行 git（I9）。
--
-- 三十六轮 F1：@.git@ 的存在性探测不得用 @doesDirectoryExist@\/@doesFileExist@
-- ——两者把 ACL\/断网\/介质错误统统吞成 False，而这里 False 的去向是**放行**
-- （自身「无」.git → 祖先扫描；祖先也「无」→ Right ()），查不出就塌缩成
-- 不存在，正是 'Pm.Win.probeName'（P3b-13）为消灭而生的那个形状。探测改走
-- probeName 三态，判定收进纯函数 'classifyGitProbe'（穷测）。**布尔探针只
-- 允许出现在 False→拒绝 的位置**：本模块 .gitignore 的 @doesFileExist@
-- （False = 「无 .gitignore」= Left）与 'Pm.Config.requirePmTrusted' 的
-- @doesDirectoryExist@（False = 拒绝）同属该安全方向，无须三态——这是
-- 三十五轮读原语清点未计入它们的类界，本轮把类界写明。
module Pm.GitGuard
  ( pmIgnoreGuard
  , vaultIgnoreGuard
  , findGitAncestor
  , classifyGitProbe
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (takeDirectory, (</>))

import Pm.Types (RootRole (..))
import Pm.Win (NameKind (..), probeName)

-- | 存在性探测的三态收口表（纯函数，用例穷举全部构造子）。为 @.git@ 而生
-- （三十六轮 F1），但表本身与名字无关——同轮类扫尽后 `pm init` 的配置存在闸
-- 也用它（Commands.hs，全仓唯一另一处 False→放行 且无下游响亮失败兜底的
-- 布尔探针）。消息不含具体名字，调用方自行前缀路径：
--
--   * @Right True@ —— 名字被占着：普通目录\/文件都算；**surrogate 也算**
--     （junction\/symlink，含悬空——对 .git，git 自己把悬空当损坏仓而不是
--     无仓；对配置，链接占名 = 已存在。「当有」只会把守卫引向更严一侧，
--     不会放行）。
--   * @Right False@ —— 名字确实不存在（GetFileAttributes 错误码 2\/3）。
--   * @Left@ —— 查不出（ACL 5\/断网 53\/介质错误……）：核不了 = 不放行，与
--     「读不到 .gitignore」（三十五轮 F4）同向。
classifyGitProbe :: NameKind -> Either String Bool
classifyGitProbe NameMissing = Right False
classifyGitProbe NamePlain = Right True
classifyGitProbe NameSurrogate = Right True
classifyGitProbe ProbeUnknown =
  Left "存在性查不出（ACL/介质错误？）——核不了 = 不放行，解除后重试"

-- | 三种 git 语境全覆盖：
--
--   * 自身有 @.git@（目录=普通仓根，文件=worktree\/submodule 链接）→ 查本
--     目录 .gitignore；
--   * 自身无 .git 但**祖先**有 → 一律拒绝：.pm 的忽略状态由祖先仓的 ignore
--     链决定，pm 不实现完整 gitignore 语义，fail-closed。
--
-- 路径先 'canonicalizePath'（P3b-5 复审 #2：配置路径若是 junction\/symlink
-- 别名，词法父链看不到真实目标的祖先 .git；三十六轮 F1 补：规范化失败同样
-- Left，不逃顶）。.gitignore 检查是文本级白名单：
-- 必须存在恰好 @.pm\/@ 的行，且 @!@ 反规则只允许**纯字面且不含 .pm** 的行
-- （case-fold——Windows 默认 core.ignorecase）。P3b-6 复审 A2：含通配符
-- @*@ @?@ @[@ 或转义 @\\@ 的反规则不含 @.pm@ 字面也能重新包含它（实测 git
-- 2.52：@!.[p]m\/**@、@!.p\\m\/**@、@!.?m\/**@、@!.*\/**@ 都让 @.pm\/probe@
-- 变回未忽略），pm 不实现 wildmatch，一律拒绝。
pmIgnoreGuard :: RootRole -> FilePath -> IO (Either String ())
pmIgnoreGuard role dir0 = do
  dirE <- try (canonicalizePath dir0) :: IO (Either IOException FilePath)
  case dirE of
    Left e ->
      pure (Left ("I11: " <> label <> " root 路径规范化失败（" <> show e <> "）——核不了 = 拒绝"))
    Right dir -> do
      k <- probeName (dir </> ".git")
      case classifyGitProbe k of
        Left why -> pure (Left ("I11: " <> label <> " root 的 " <> (dir </> ".git") <> " " <> why))
        Right True -> do
          let igFp = dir </> ".gitignore"
          ex <- doesFileExist igFp
          if not ex
            then pure (Left (i11Msg igFp "无 .gitignore"))
            else do
              -- 三十五轮 F4：.gitignore 被编辑器/同步器短暂独占时裸 BS.readFile
              -- 抛出，异常逃出 init 预检与 Exec 执行前守卫。核不了 = 拒绝
              -- （fail-closed，与「无 .gitignore」同向），绝不当「已覆盖」放行。
              rawE <- try (BS.readFile igFp) :: IO (Either IOException BS.ByteString)
              case rawE of
                Left e -> pure (Left (i11Msg igFp ("读取失败（被占/被挪？）: " <> show e)))
                Right raw -> do
                  -- 第一方自审工作流 F066：守卫必须是 gitignore(5) 行规则的**精确限制**
                  -- ——git 只忽略尾随**空格**（未转义时）；前导空白、尾随 TAB/NBSP 都是
                  -- 模式的一部分（git 2.52 实测：check-ignore 对这些变体全答 NOT-ignored）。
                  -- `T.strip` 两头都剥、`isSpace` 连 TAB/NBSP 也剥，都把 git 不认的行当成
                  -- 覆盖放行。只做两件事：去一个尾随 CR（CRLF 行尾），再去尾随空格。
                  let norm l = T.dropWhileEnd (== ' ') (fromMaybe l (T.stripSuffix "\r" l))
                      ls = map norm (T.lines (TE.decodeUtf8Lenient raw))
                      hasRule = ".pm/" `elem` ls
                      risky l =
                        let f = T.toLower l
                         in ".pm" `T.isInfixOf` f || T.any (`elem` ("*?[\\" :: String)) f
                      negations = [l | l <- ls, "!" `T.isPrefixOf` l, risky l]
                  case (hasRule, negations) of
                    (False, _) -> pure (Left (i11Msg igFp "缺 `.pm/` 行"))
                    (True, _ : _) ->
                      pure
                        ( Left
                            ( i11Msg
                                igFp
                                ( "存在可能重新包含 .pm 的反规则（含 .pm 或通配符 * ? [ \\）: "
                                    <> T.unpack (T.intercalate ", " negations)
                                )
                            )
                        )
                    (True, []) -> pure (Right ())
        Right False -> do
          manc <- findGitAncestor dir
          case manc of
            Left why -> pure (Left ("I11: " <> label <> " root 的祖先链上 " <> why))
            Right (Just anc) ->
              pure
                ( Left
                    ( "I11: " <> label <> " root 位于上层 git 仓库内部（" <> anc
                        <> "）且自身不是仓根——.pm 的忽略状态由祖先 ignore 链决定，pm 不解析完整 gitignore 语义，拒绝（fail-closed）"
                    )
                )
            Right Nothing -> pure (Right ())
 where
  label = case role of
    RoleMain -> "主库"
    RoleBackup -> "备份"
    RoleVault -> "vault"
  i11Msg igFp why =
    "I11: " <> label <> " root 是 git 工作树且 .gitignore 未有效覆盖 `.pm/`（" <> why
      <> "）—— 先经用户确认修正 " <> igFp <> "（恰含 `.pm/` 行；`!` 反规则不得含 .pm 或通配符），再运行"

-- | vault 角色的守卫（历史入口名，语义 = 'pmIgnoreGuard' RoleVault）。
vaultIgnoreGuard :: FilePath -> IO (Either String ())
vaultIgnoreGuard = pmIgnoreGuard RoleVault

-- | 从 start 的父目录向上找持有 .git（目录或文件）的祖先（start 须已规范化）。
-- 三十六轮 F1：逐层探测同走 'classifyGitProbe' 三态——某层查不出即 Left；
-- 这里 False 的去向是「继续向上、最终放行」，塌缩不得。
findGitAncestor :: FilePath -> IO (Either String (Maybe FilePath))
findGitAncestor start = go (takeDirectory start)
 where
  go dir = do
    k <- probeName (dir </> ".git")
    case classifyGitProbe k of
      Left why -> pure (Left ((dir </> ".git") <> " " <> why))
      Right True -> pure (Right (Just dir))
      Right False ->
        let up = takeDirectory dir
         in if up == dir then pure (Right Nothing) else go up
