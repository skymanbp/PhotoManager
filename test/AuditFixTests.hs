{-# LANGUAGE OverloadedStrings #-}

-- | 2026-09-25 全量 debug 审计（docs/reviews/2026-09-25-full-debug-audit.md，编号
-- @#id@ 与报告一致）的修复钉针——凡既有主题模块已触 750 行预算（GuardTests /
-- PathGuardTests / KernelTests …）而放不下的用例收在这里；能就地扩展既有用例的
-- 仍就地扩展。每条钉一个屏障：拆掉对应修复，用例必须转红。
module AuditFixTests (auditFixTests) where

import Control.Exception (finally)
import Data.List (isSuffixOf)
import Data.Time (getCurrentTime)
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..), configFilePath, createRootInfo, loadConfig, readRootInfo, withConfigLock, writeConfig)
import Pm.Types (RootInfo (..), RootRole (..))

auditFixTests :: TestTree
auditFixTests =
  testGroup
    "2026-09-25 全量 debug 审计修复钉针"
    [ testCase "#4 配置路径途经 junction（同 SUBST / 8.3 短名）：configFilePath 解析到真名，写 / 锁 / 读三者同形，不再被句柄后验误拒" caseConfigPathJunction
    , testCase "#5 root 是 junction：createRootInfo 落到真名下、不抛、无 .tmp 残留；已有身份仍 Left 不覆盖且不留 .tmp" caseRootIdJunctionRoot
    ]

mkJunction :: FilePath -> FilePath -> IO ()
mkJunction link target =
  () <$ readCreateProcess (shell ("mklink /J \"" <> link <> "\" \"" <> target <> "\"")) ""

mkCfg :: FilePath -> Config
mkCfg mainP = Config mainP Nothing Nothing Nothing Nothing Nothing (Just 0) Nothing Nothing Nothing

-- | #4（medium）：%APPDATA% 或 PM_CONFIG 的某一层是 junction / SUBST / 8.3 短名时，
-- 'writeConfig' 的落位与 'withConfigLock' 的加锁都在句柄上后验「绑定的就是这条路径」，
-- 对比基准是 GetFinalPathNameByHandle 的规范形——只做 makeAbsolute 的原样字符串
-- 必然对不上，userError 作为未捕获异常抛出：pm init / config set / backup init 崩，
-- 读照常。'configFilePath' 改为在源头 canonicalizePath 后，三者同一形态。
-- 第二次 writeConfig 额外走「删旧 → 落位」的完整删除路（同 GuardTests 正斜杠用例）。
caseConfigPathJunction :: IO ()
caseConfigPathJunction = withSystemTempDirectory "pm-cfgjunc" $ \tmp -> do
  mold <- lookupEnv "PM_CONFIG"
  let real = tmp </> "real"
      link = tmp </> "link"
      mainP = tmp </> "main"
  createDirectoryIfMissing True real
  mkJunction link real
  setEnv "PM_CONFIG" (link </> "config.toml")
  flip finally (maybe (pure ()) (setEnv "PM_CONFIG") mold) $ do
    expect <- canonicalizePath (real </> "config.toml")
    fp <- configFilePath
    fp @?= expect
    _ <- writeConfig (mkCfg mainP)
    _ <- writeConfig (mkCfg mainP)
    doesFileExist (real </> "config.toml") >>= (@?= True)
    ml <- withConfigLock (pure ())
    ml @?= Just ()
    loadConfig >>= either (assertFailure . ("配置应可读回: " <>)) (\c -> cfgMainPath c @?= mainP)

-- | #5（medium）：'createRootInfo' 此前从调用方原样字符串拼落位目标与 tmp——root 是
-- junction / SUBST / 8.3 短名时（runInit 只 makeAbsolute、vault.path 原样；DESIGN §14 与
-- resolveUnder 文档都说 junction root 合法），'moveBoundNoReplace' 的句柄先验对不上
-- GetFinalPathNameByHandle 的规范形，失败臂的 'deleteBoundAt' 同样对不上并**抛出**：
-- 异常逃出 pm init / 首次 vault push，且每次尝试泄漏一个 @root-id.json.<hex>.tmp@。
-- 改为经受信解析器取 canonical 形态；失败臂删 tmp 包 try、原因并进报文。
caseRootIdJunctionRoot :: IO ()
caseRootIdJunctionRoot = withSystemTempDirectory "pm-rootjunc" $ \tmp -> do
  let real = tmp </> "real"
      link = tmp </> "link"
      leftovers = filter (".tmp" `isSuffixOf`) <$> listDirectory (real </> ".pm")
  createDirectoryIfMissing True real
  mkJunction link real
  now <- getCurrentTime
  r1 <- createRootInfo link (RootInfo "j" RoleMain now Nothing)
  r1 @?= Right ()
  doesFileExist (real </> ".pm" </> "root-id.json") >>= (@?= True)
  leftovers >>= (@?= [])
  fmap riId <$> readRootInfo link >>= (@?= Just "j")
  -- 目标已存在（并发创建 / readRootState 之后有人放了文件）：仍 Left、不覆盖、不抛、不留 tmp
  r2 <- createRootInfo link (RootInfo "x" RoleMain now Nothing)
  either (const (pure ())) (const (assertFailure "已有身份不得被覆盖")) r2
  fmap riId <$> readRootInfo real >>= (@?= Just "j")
  leftovers >>= (@?= [])
