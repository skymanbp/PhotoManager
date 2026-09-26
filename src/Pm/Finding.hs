-- | doctor 的发现行：矩阵行 \/ 类别标签 + 严重度 + 说明 + 修复（'Pm.Doctor' 的输出，'Pm.Cli' 的执行自愈与
-- @pm doctor@ 的终端渲染共用）。2026-09-26 自 'Pm.Doctor' 字节级拆出（审计 #38 让 @--repair@ 的动作也回成
-- 发现行，Doctor 触 750 行预算），Doctor 再导出，调用方不变。
module Pm.Finding
  ( Severity (..)
  , Finding (..)
  , renderFinding
  , repairRow
  ) where

data Severity = Info | Warn | Bad
  deriving (Show, Eq, Ord)

data Finding = Finding
  { fRow :: String -- matrix row / category tag
  , fSeverity :: Severity
  , fDetail :: String
  , fRepair :: String -- what --repair would / did do ("" = nothing)
  }

renderFinding :: Finding -> String
renderFinding f =
  sevTag (fSeverity f)
    <> " ["
    <> fRow f
    <> "] "
    <> fDetail f
    <> (if null (fRepair f) then "" else "\n      修复: " <> fRepair f)
 where
  sevTag Info = "  ·"
  sevTag Warn = "  ⚠"
  sevTag Bad = "  ✗"

-- | @--repair@ 实际做了（或没能做）的每个动作一行的标签（审计 #38：此前 'applyRepairs' 直接 putStrLn，
-- 不进返回的 findings——@pm ui@ 下 serve 的 stdout 是空设备，GUI 发起的执行自愈里看不到）。
repairRow :: String
repairRow = "REPAIR"
