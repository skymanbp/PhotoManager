-- | doctor 的受信探针：@.pm@ 内定点路径（trash 载荷 \/ tmp）的受信 sha 与存在性探测，用户侧路径的
-- 三态存在性。审计 #35 时为 750 行预算从 "Pm.Doctor" 字节级拆出（同 1.1.2 拆 "Pm.Derived"、#29 拆
-- "Pm.Finding" 的先例），零语义改动；只有 Doctor 用它。
module Pm.DoctorProbe
  ( PmProbe (..)
  , probePmSha
  , PmEntryQ (..)
  , probePmExists
  , existsAny
  , userSideExists
  ) where

import Control.Exception (IOException, bracket, try)
import Data.Text (Text)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO (hClose)
import System.IO.Error (isDoesNotExistError)

import Pm.Hash (sha256Handle)
import Pm.Win (NameKind (..), openStateRead, probeName, resolveUnder)

-- | @.pm@ 内定点路径（trash 载荷 \/ tmp）的受信探测（P3b-15，十二轮 major）：
-- 完整路径 'resolveUnder' + 'openStateRead'（句柄 link count）+ **同一句柄**
-- hash。此前这里直接 @doesFileExist@\/@sha256File@——trash 载荷被换成指向库外
-- 同内容文件的 symlink\/hardlink 时，doctor 会"核验通过"并让 @--repair@ 补写
-- **虚假的 Done**，把从未落位的隔离认证成已完成。
-- 三态：@PmStateBad@=不可信（只报 Bad，不参与任何 repair 推导）、
-- @PmStateMissing@=缺席、@PmStateSha@=可信内容的 sha。
data PmProbe = PmStateBad String | PmStateMissing | PmStateSha Text

probePmSha :: FilePath -> FilePath -> IO PmProbe
probePmSha root rel = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> pure (PmStateBad (rel <> " 不是 root 下的真实路径（junction/symlink？）"))
    Just fp -> do
      r <- try (bracket (openStateRead fp) hClose sha256Handle) :: IO (Either IOException Text)
      pure $ case r of
        Right sha -> PmStateSha sha
        Left e
          | isDoesNotExistError e -> PmStateMissing
          | otherwise -> PmStateBad (rel <> " 无法可信读取（" <> show e <> "）")

-- | @.pm@ 内定点路径的**存在性**受信探测。问的是哪一种存在必须由调用点显式
-- 说明——P3b-17（十四轮 major）的成因正是它此前不必说：十三轮把复位源的
-- 'existsAny'（文件**或**目录）换成受信探针时只写了 @doesFileExist@，谓词在
-- 安全重构里**被悄悄收窄**。'Pm.Op.OpRename' 合法支持 'FpDir'（'Pm.Names' 的
-- 目录改名计划就是这一种，执行端也确实 stat/hash/move 目录），于是 trash 里
-- **真实存在的目录**复位源被判成"不存在"，与存在且指纹相符的 @new@ 组合成
-- R2 Warn，@--repair@ 随即补写**虚假 Done**（正确格是 R3，不进任何修复线）。
data PmEntryQ
  = -- | 只认普通文件（pm 自建的 tmp 落位点）
    PmEntryFile
  | -- | 任何目录项，文件或目录（'existsAny' 的受信对偶）
    PmEntryAny

probePmExists :: PmEntryQ -> FilePath -> FilePath -> IO (Either String Bool)
probePmExists q root rel = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> pure (Left (rel <> " 不是 root 下的真实路径（junction/symlink？）"))
    Just fp ->
      Right <$> case q of
        PmEntryFile -> doesFileExist fp
        PmEntryAny -> existsAny fp

existsAny :: FilePath -> IO Bool
existsAny p = do
  f <- doesFileExist p
  if f then pure True else doesDirectoryExist p

-- | 用户侧路径的三态存在性（第一方自审工作流 F033）：'probeName' 走
-- GetFileAttributes，对象自身的 ACL 拒绝不影响它；查不出即 Left。
userSideExists :: FilePath -> IO (Either String Bool)
userSideExists p = do
  k <- probeName p
  pure $ case k of
    NameMissing -> Right False
    NamePlain -> Right True
    NameSurrogate -> Right True
    ProbeUnknown -> Left (p <> " 存在性查不出（ACL/介质错误？）")
