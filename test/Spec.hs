-- | Test-suite entry: aggregation only. Cases live in KernelTests (P0/P1
-- 安全内核)、PlannerTests (P2/P2.1 计划器 + 组语义)、VaultTests (P3a/P3b-1)、
-- NamesTests (P3b-2/3)、GuardTests (P3b-6/7/8 身份与解析守卫)、
-- PathGuardTests (P3b-9~13 路径校验与 canonical 限域)、
-- StateGuardTests (P3b-14 .pm 状态文件的受信取用口) 与
-- ServeTests (P4-1 loopback JSON API).
module Main (main) where

import System.Environment (setEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import SortTests (sortTests)
import Test.Tasty
import Test.Tasty.Runners (NumThreads (..))

import AlbumTests (albumTests)
import DedupeTests (dedupeTests)
import DocDriftTests (docDriftTests)
import GuardTests (guardTests)
import HandleGuardTests (handleGuardTests)
import IngestTests (ingestTests)
import KernelTests (kernelTests)
import NamesTests (namesTests)
import PathGuardTests (pathGuardTests)
import PlannerTests (plannerTests)
import Pm.Win (setupConsole)
import PublishTests (publishTests)
import ScanGuardTests (scanGuardTests)
import ServeTests (serveTests)
import ServeWriteTests (serveWriteTests)
import SortGuardTests (sortGuardTests)
import StateGuardTests (stateGuardTests)
import SweepTests (sweepTests)
import VaultHoldTests (vaultHoldTests)
import VaultNoteTests (vaultNoteTests)
import VaultTests (vaultTests)

main :: IO ()
main = do
  setupConsole
  -- 配置文件位置是**机器全局**的（XDG / %APPDATA%）：任何一条真的写成功的
  -- 用例都会覆盖使用者本机的 config.toml。P4-8 开发时实测踩到过（一次突变让
  -- 写端点通过，真实配置当场被 fixture 路径覆盖）。整个测试进程指到临时文件，
  -- 这条路就物理上断了——不依赖"每个用例记得设环境变量"。
  withSystemTempDirectory "pm-test-cfg" $ \d -> do
    setEnv "PM_CONFIG" (d </> "config.toml")
    -- **整个套件串行**：SortTests 的 captureStdout 重定向的是**进程级**
    -- stdout。并行时别的用例（以及 tasty 自己的结果行）会写进同一个句柄——
    -- 断言读到别人的输出、失败详情反而被吞掉。这是共享资源的正确处置：
    -- 有一个进程级资源，就不能同时跑两个用例。代价是几秒钟。
    defaultMain
      (localOption (NumThreads 1) $ testGroup "pm" [kernelTests, plannerTests, vaultTests, vaultHoldTests, vaultNoteTests, namesTests, guardTests, pathGuardTests, handleGuardTests, stateGuardTests, serveTests, serveWriteTests, sortTests, sortGuardTests, dedupeTests, ingestTests, albumTests, scanGuardTests, publishTests, sweepTests, docDriftTests])
