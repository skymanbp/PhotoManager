{-# LANGUAGE OverloadedStrings #-}

-- | I11 守卫核心（内核级）：vault 是 git 工作树，pm 的 @.pm\/@ 必须被有效
-- 忽略才允许在其中建 root、写 journal\/tmp\/trash。放在独立的小模块里是为了
-- 让 'Pm.Exec' 在执行锁内**无条件**调用（P3b-5 复审 #3：只靠可覆盖的
-- ExecEnv 钩子，库层调用者一个 @execPlan defaultExecEnv@ 就绕过去了），
-- 同时 'Pm.Vault' 在建 root 前也走同一函数。pm 不执行 git（I9）。
module Pm.GitGuard
  ( vaultIgnoreGuard
  , findGitAncestor
  ) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist)
import System.FilePath (takeDirectory, (</>))

-- | 三种 git 语境全覆盖：
--
--   * 自身有 @.git@ **目录**（普通仓根）→ 查本目录 .gitignore；
--   * 自身有 @.git@ **文件**（worktree\/submodule 链接）→ 同上；
--   * 自身无 .git 但**祖先**有 → 一律拒绝：.pm 的忽略状态由祖先仓的 ignore
--     链决定，pm 不实现完整 gitignore 语义，fail-closed。
--
-- 路径先 'canonicalizePath'（P3b-5 复审 #2：配置路径若是 junction\/symlink
-- 别名，词法父链看不到真实目标的祖先 .git）。.gitignore 检查是文本级白名单：
-- 必须存在恰好 @.pm\/@ 的行，且不允许任何含 @.pm@ 的反规则（@!@ 行；
-- 比较 case-fold——Windows 默认 core.ignorecase，@!.PM\/@ 同样重新包含）。
vaultIgnoreGuard :: FilePath -> IO (Either String ())
vaultIgnoreGuard vaultDir0 = do
  vaultDir <- canonicalizePath vaultDir0
  gitDir <- doesDirectoryExist (vaultDir </> ".git")
  gitFile <- doesFileExist (vaultDir </> ".git")
  if gitDir || gitFile
    then do
      let igFp = vaultDir </> ".gitignore"
      ex <- doesFileExist igFp
      if not ex
        then pure (Left (i11Msg igFp "无 .gitignore"))
        else do
          raw <- BS.readFile igFp
          let ls = map T.strip (T.lines (TE.decodeUtf8Lenient raw))
              hasRule = ".pm/" `elem` ls
              negations = [l | l <- ls, "!" `T.isPrefixOf` l, ".pm" `T.isInfixOf` T.toLower l]
          case (hasRule, negations) of
            (False, _) -> pure (Left (i11Msg igFp "缺 `.pm/` 行"))
            (True, _ : _) ->
              pure (Left (i11Msg igFp ("存在可能重新包含 .pm 的反规则: " <> T.unpack (T.intercalate ", " negations))))
            (True, []) -> pure (Right ())
    else do
      manc <- findGitAncestor vaultDir
      case manc of
        Just anc ->
          pure
            ( Left
                ( "I11: vault 位于上层 git 仓库内部（" <> anc
                    <> "）且自身不是仓根——.pm 的忽略状态由祖先 ignore 链决定，pm 不解析完整 gitignore 语义，拒绝（fail-closed）"
                )
            )
        Nothing -> pure (Right ())
 where
  i11Msg igFp why =
    "I11: vault 是 git 工作树且 .gitignore 未有效覆盖 `.pm/`（" <> why
      <> "）—— 先经用户确认修正 " <> igFp <> "（恰含 `.pm/` 行、无 .pm 反规则），再运行"

-- | 从 start 的父目录向上找持有 .git（目录或文件）的祖先（start 须已规范化）。
findGitAncestor :: FilePath -> IO (Maybe FilePath)
findGitAncestor start = go (takeDirectory start)
 where
  go dir = do
    d <- doesDirectoryExist (dir </> ".git")
    f <- doesFileExist (dir </> ".git")
    if d || f
      then pure (Just dir)
      else
        let up = takeDirectory dir
         in if up == dir then pure Nothing else go up
