-- | Test-suite entry: aggregation only. Cases live in KernelTests (P0/P1
-- 安全内核)、PlannerTests (P2/P2.1 计划器 + 组语义) 与 VaultTests (P3a).
module Main (main) where

import Test.Tasty

import KernelTests (kernelTests)
import PlannerTests (plannerTests)
import Pm.Win (setupConsole)
import VaultTests (vaultTests)

main :: IO ()
main = do
  setupConsole
  defaultMain (testGroup "pm" [kernelTests, plannerTests, vaultTests])
