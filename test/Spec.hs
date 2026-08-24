-- | Test-suite entry: aggregation only. Cases live in KernelTests (P0/P1
-- 安全内核)、PlannerTests (P2/P2.1 计划器 + 组语义)、VaultTests (P3a/P3b-1)、
-- NamesTests (P3b-2/3)、GuardTests (P3b-6/7/8 身份与解析守卫) 与
-- PathGuardTests (P3b-9/10 路径校验与 canonical 限域).
module Main (main) where

import Test.Tasty

import GuardTests (guardTests)
import KernelTests (kernelTests)
import NamesTests (namesTests)
import PathGuardTests (pathGuardTests)
import PlannerTests (plannerTests)
import Pm.Win (setupConsole)
import VaultTests (vaultTests)

main :: IO ()
main = do
  setupConsole
  defaultMain
    (testGroup "pm" [kernelTests, plannerTests, vaultTests, namesTests, guardTests, pathGuardTests])
