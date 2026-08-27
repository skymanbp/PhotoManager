{-# LANGUAGE OverloadedStrings #-}

-- | P7-J：发布前第一方自审的**工作流侧**收口试针——ultracode 全模块评审的
-- 101 条发现在 HEAD 上逐条核实后仍成立的那些（docs/REVIEW-LOG.md「P7-J」）。
-- 每条钉一个屏障：拆掉对应修复，用例必须转红。
module SweepTests (sweepTests) where

import Control.Exception (IOException, try)
import Control.Monad (when)
import qualified Data.ByteString.Lazy as BSL
import Data.Aeson (encode)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Apply (ResolveOpts (..), runResolve)
import Pm.Cli (applyOnlyToPlan, bindExecRoot)
import Pm.Commands (TrashCmd (..), runTrash)
import Pm.Config (Config (..), pmDir, writeRootInfo)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity (..), runDoctor)
import Pm.Exec (Checkpoint (..), ExecEnv (..), ItemOutcome (..), defaultExecEnv, dirFingerprint, outcomeLabel, tmpDirFor, tmpNameFor, updateCatalog)
import Pm.GitGuard (vaultIgnoreGuard)
import Pm.Journal (JEntry (..), Sync (..), jAppend, journalPath, readJournal, withJournal)
import Pm.Names (runNames)
import Pm.Op (Fingerprint (..), Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan, planPath, savePlan)
import Pm.Trash (TrashRecord (..), appendManifest, manifestMaybe, readManifest, trashDir)
import Pm.Types (Catalog (..), Entry (..), RootInfo (..), RootRole (..))
import TestUtil

sweepTests :: TestTree
sweepTests =
  testGroup
    "P7-J 工作流收口试针"
    [ testCase "F027 resolve 锁内重装只取条目：写回与读盘用 UUID 绑定的 root，文件里的过期 root 零字节" caseResolveUsesBoundRoot
    , testCase "F066 I11 .gitignore 前导空白是模式的一部分：「  .pm/」不算覆盖；尾随空白/CRLF 忽略" caseIgnoreLeadingSpace
    , testCase "F095 pm names 身份先于枚举：非主库 root 即使零改名也 exit 2，不出报告" caseNamesIdentityFirst
    , testCase "F028 撕裂尾之后再追加：新记录不黏进残行；残行仍报 torn（Warn）而非 CORRUPT；manifest 同口同修" caseTornTailThenAppend
    , testCase "F000 落位后复核失败：报文指向实现了的 pm resolve 路，不指向看不见该项的 pm doctor" caseLandVerifyFailRoute
    , testCase "F033 用户侧 rename 源目录 ACL 全拒 → 仍判「在」落 R3；不落 R2、--repair 不补假 Done" caseDoctorUserRenameSrcDenied
    , testCase "F034 C1 修复文案与 --repair 实际行为一致：在途 tmp 不清除、文案不许诺清除" caseDoctorC1RepairText
    , testCase "C102 trash empty 逐项 unlink 失败 → 不逃顶、报已清除 k/N、exit 2、其余条目未动" caseTrashEmptyUnlinkFailure
    , testCase "F019 --only 序号越界 → 拒绝并点名范围（不再静默全跳过 + 惰性巨列表）；范围内照常" caseOnlyOutOfRange
    , testCase "F004 目录 rename 的 catalog 重键：改写后的条目胜过目标前缀下的过期条目（左偏），不由字节序决定" caseRekeyLeftBiased
    , testCase "F018 bindExecRoot 零候选：槽位身份损坏/读不出时如实列出原因，不宣称「均不符」" caseBindRootReportsUnreadable
    ]

-- | 计划文件里的 @plRootPath@ 是线索不是证据：'loadPlan' 不核对它与装载目录
-- 一致，'bindExecRoot' 按 UUID 把它绑回真实 root（盘符变更是设计内场景）。
-- 旧 'resolveOn' 在锁内重装后却用**文件里**的 root 做裁决读盘与 savePlan 写回——
-- 写到了过期路径。fixture：把文件里的 root 手改成另一目录，resolve 之后那边
-- 必须连 .pm 都没有，绑定 root 里的计划必须已改。
caseResolveUsesBoundRoot :: IO ()
caseResolveUsesBoundRoot = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
      stale = tmp </> "stale"
  createDirectoryIfMissing True root
  createDirectoryIfMissing True stale
  op <- mkCopyOp (tmp </> "src" </> "a.jpg") "A" "a.jpg"
  plan <- mkPlanIO root [op]
  _ <- savePlan plan
  BSL.writeFile (planPath root (plId plan)) (encode plan {plRootPath = stale})
  -- 受信取用口就把记录绑到字节实际来自的目录（loader 级；resolve 的锁内
  -- 重装由此拿到绑定 root，不必各调用方自己记得重绑）
  ep0 <- loadPlan root (plId plan)
  fmap plRootPath ep0 @?= Right root
  code <- runResolve (ResolveOpts (plId plan) 0 True Nothing) (mkVaultCfg root (tmp </> "no-vault"))
  code @?= 0
  ep <- loadPlan root (plId plan)
  either assertFailure (\p -> map piStatus (plItems p) @?= [StSkippedByUser]) ep
  doesDirectoryExist (pmDir stale) >>= (@?= False)

-- | gitignore(5)：只有**尾随空格**被忽略（未用反斜杠转义时）；前导空白、尾随
-- TAB / NBSP 都是模式的一部分——「  .pm/」匹配的是名为「  .pm/」的路径，
-- @.pm/@ 仍未被忽略（git 2.52 实测：check-ignore 对这些变体都答 NOT-ignored）。
-- 旧守卫 @T.strip@ 两头都剥；@isSpace@ 连 TAB/NBSP 也剥——都把 git 不认的行
-- 当成覆盖放行。守卫必须是 git 自身规则的精确限制：去一个尾随 CR，再去尾随空格。
caseIgnoreLeadingSpace :: IO ()
caseIgnoreLeadingSpace = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let v = tmp </> "vault"
      mustRefuse label bytes = do
        BSL.writeFile (v </> ".gitignore") bytes
        g <- vaultIgnoreGuard v
        case g of
          Left m -> assertBool (label <> " 应报缺 .pm/ 行: " <> m) ("缺 `.pm/` 行" `isInfixOf` m)
          Right () -> assertFailure (label <> " 被当成覆盖放行（F066 的形状）")
  createDirectoryIfMissing True (v </> ".git")
  mustRefuse "前导空格「  .pm/」" "_site/\n  .pm/\n"
  mustRefuse "尾随 TAB「.pm/<TAB>」" "_site/\n.pm/\t\n"
  -- NBSP 必须以 UTF-8 双字节 C2 A0 落盘（OverloadedStrings 的 Char8 截断会写成
  -- 非法单字节，解码成 U+FFFD 后无论修没修都拒绝，试针就不再判别）
  mustRefuse "前导 NBSP" ("_site/\n" <> BSL.pack [0xc2, 0xa0] <> ".pm/\n")
  BSL.writeFile (v </> ".gitignore") "_site/\r\n.pm/  \r\n"
  g2 <- vaultIgnoreGuard v
  either (\m -> assertFailure ("尾随空格/CRLF 应被忽略: " <> m)) (const (pure ())) g2

-- | 主库身份先于任何主库侧读取（P3b-5 复审 B1）。旧序只在真要改名时才
-- 'requireRole'：一棵已合规的 Raw 树在 backup root 上照样读完、打完报告、
-- exit 0。fixture 必须是**已规范**的名字（@25-01-Alaska-Raw@ → RnCanonical，
-- 零改名）——只有这条路径上旧代码才根本不验身份；@25-01-Alaska@ 会判
-- RnRename，走的是旧代码本来就有闸的分支，试针在 HEAD 上就绿、不判别。
caseNamesIdentityFirst :: IO ()
caseNamesIdentityFirst = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let bak = tmp </> "bak"
  createDirectoryIfMissing True (bak </> "Raw" </> "2025" </> "25-01-Alaska-Raw")
  writeRootInfo bak (RootInfo "bk" RoleBackup t0 Nothing)
  ran <- newIORef False
  code <- runNames (\_ -> writeIORef ran True >> pure 0) (mkVaultCfg bak (tmp </> "no-vault"))
  code @?= 2
  readIORef ran >>= (@?= False)

-- | 断电后末行半截；此前下一次追加直接接在半截后面：新记录被吞、残行从
-- 「末行半截」（Warn）升级成「中段 CORRUPT」（Bad，undo 从此拒绝，--repair
-- 还会往同一句柄再补）。受信追加口先补换行，journal 再落 JTornGap 标记，
-- 读侧把「不可解析行 + 紧随其后的标记」判回撕裂尾。manifest 走同一个口。
caseTornTailThenAppend :: IO ()
caseTornTailThenAppend = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
  createDirectoryIfMissing True root
  withJournal root $ \j -> jAppend j Barrier (JCleanShutdown t0)
  appendFile (journalPath root) "{\"e\":\"intent\",\"op\":\"trunc"
  withJournal root $ \j -> jAppend j Barrier (JCleanShutdown t0)
  (es, warns) <- readJournal root
  length [() | JCleanShutdown {} <- es] @?= 2
  assertBool ("撕裂尾不得升级成 CORRUPT: " <> show warns) (not (any ((== "CORR") . take 4) warns))
  assertBool ("撕裂尾仍须以 torn 警告报出: " <> show warns) (any ((== "torn") . take 4) warns)
  -- manifest：半截记录之后追加，新记录完整可读、残行单独计一条损坏行
  let rec1 = TrashRecord "v.jpg" ("p" </> "v.jpg") "aa" "supersede:test" "p" t0
  appendManifest root rec1
  appendFile (trashDir root </> "manifest.ndjson") "{\"victim\":\"half"
  appendManifest root rec1
  (recs, bad) <- manifestMaybe <$> readManifest root
  length recs @?= 2
  length bad @?= 1

-- | 落位 rename 已成功、复核发现 dst 内容不符：两个失败臂都写 JFailed（终态），
-- doctor 的 pending 折叠把该 oid 退役，C 行永远不出现——「交 pm doctor」指向
-- 一个结构上看不见该项的工具。实现了的路是重新生成计划 → pm resolve。
caseLandVerifyFailRoute :: IO ()
caseLandVerifyFailRoute = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
      dstAbs = root </> "成片" </> "a.jpg"
  createDirectoryIfMissing True root
  op <- mkCopyOp (tmp </> "src" </> "a.jpg") "A" ("成片" </> "a.jpg")
  plan <- mkPlanIO root [op]
  let env = defaultExecEnv {eeCheckpoint = \c -> when (c == CpCopyAfterLand) (writeFile dstAbs "TAMPERED")}
  rs <- execOkWith env plan
  case rs of
    [(_, OFailed m)] -> do
      assertBool ("报文不得指向看不见该项的 pm doctor: " <> m) (not ("pm doctor" `isInfixOf` m))
      assertBool ("报文须指向实现了的路 pm resolve: " <> m) ("pm resolve" `isInfixOf` m)
    other -> assertFailure ("应为单项 OFailed，实得 " <> show (map (outcomeLabel . snd) other))
  rows <- doctorRows root
  assertBool ("doctor 对已记 FAILED 的项静默（不该有 C 行）: " <> show rows) (null [r | (r, _) <- rows, take 1 r == "C"])

-- | 用户侧 rename（pm names 生成的 Raw 事件夹改名）的 old 目录被 ACL 全拒：
-- `existsAny` 塌成 False，与「new 在且指纹相符」组成 (False, True) → R2 Warn
-- → --repair 白名单 → 补一条与真 Done 逐字节相同的假 Done。probeName 不受
-- 对象自身 ACL 影响，正确格是 R3。
caseDoctorUserRenameSrcDenied :: IO ()
caseDoctorUserRenameSrcDenied = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
      ydir = root </> "Raw" </> "2026"
  createDirectoryIfMissing True (ydir </> "olddir")
  createDirectoryIfMissing True (ydir </> "newdir")
  writeRootInfo root (RootInfo "m" RoleMain t0 Nothing)
  writeFile (ydir </> "olddir" </> "a.jpg") "A"
  writeFile (ydir </> "newdir" </> "a.jpg") "A"
  fpd <- dirFingerprint (ydir </> "newdir")
  withJournal root $ \j ->
    jAppend j Barrier (JIntent (tpOid 0) (OpRename ("Raw" </> "2026" </> "olddir") ("Raw" </> "2026" </> "newdir") (FpDir fpd)) t0)
  withDenyAll (ydir </> "olddir") $ do
    rows <- doctorRows root
    assertBool ("源目录在（只是 ACL 全拒）→ 应报 R3，实得 " <> show rows) (("R3", Warn) `elem` rows)
    assertBool ("不得报 R2 Warn（--repair 会补假 Done）: " <> show rows) (("R2", Warn) `notElem` rows)
    _ <- runDoctor root (DoctorOpts False True)
    es <- journalEntries root
    assertBool "--repair 不得补记 Done" (not (any isDone es))

-- | C1 Warn（Intent 后中断于写 tmp）：tmp 是在途 Intent 的证据，staleTmpFiles
-- 按 pending 排除它，--repair 的删除循环根本没有它——文案却许诺「将清除」。
-- 文案与行为成对钉住：文案不许诺清除，且 --repair 之后 tmp 仍在。
caseDoctorC1RepairText :: IO ()
caseDoctorC1RepairText = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
      dstRel = "成片" </> "a.jpg"
      tmpF = tmpDirFor root tpid </> tmpNameFor 0 dstRel
  createDirectoryIfMissing True root
  writeRootInfo root (RootInfo "m" RoleMain t0 Nothing)
  writeF tmpF "HALF"
  withJournal root $ \j -> jAppend j Barrier (JIntent (tpOid 0) (OpCopy (tmp </> "src.jpg") dstRel "aa" 1 0) t0)
  (fs, _) <- runDoctor root (DoctorOpts False False)
  case [f | f <- fs, fRow f == "C1", fSeverity f == Warn] of
    [f] -> do
      assertBool ("文案不得许诺清除: " <> fRepair f) (not ("将清除" `isInfixOf` fRepair f))
      assertBool ("文案须说明不清除: " <> fRepair f) ("不清除" `isInfixOf` fRepair f)
    other -> assertFailure ("应恰一条 C1 Warn，实得 " <> show [(fRow f, fSeverity f) | f <- other])
  _ <- runDoctor root (DoctorOpts False True)
  doesFileExist tmpF >>= (@?= True)

-- | pm 全程唯一 unlink 用户数据的循环此前裸跑：第一个 unlink 抛出（这里用
-- ACL 全拒让 CreateFile(DELETE) 确定性 ACCESS_DENIED）就逃顶、进程以 1 退出、
-- 摘要行消失。修后：不逃顶、exit 2、报已清除 0/2、第二个条目未动。
caseTrashEmptyUnlinkFailure :: IO ()
caseTrashEmptyUnlinkFailure = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
      rel1 = "p" </> "a.jpg"
      rel2 = "p" </> "b.jpg"
  createDirectoryIfMissing True (trashDir root </> "p")
  writeFile (trashDir root </> rel1) "A"
  writeFile (trashDir root </> rel2) "B"
  appendManifest root (TrashRecord "a.jpg" rel1 "aa" "supersede:test" "p" t0)
  appendManifest root (TrashRecord "b.jpg" rel2 "bb" "supersede:test" "p" t0)
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  (out, r) <- captureStdout (withDenyAll (trashDir root </> rel1) (try (runTrash cfg (TrashEmpty True) root)))
  case r :: Either IOException Int of
    Left e -> assertFailure ("unlink 异常不得逃出 runTrash: " <> show e)
    Right code -> code @?= 2
  assertBool ("摘要须报已清除 k/N: " <> out) ("0/2" `isInfixOf` out)
  doesFileExist (trashDir root </> rel2) >>= (@?= True)

-- | @--only 0-999@ 对单项计划：旧代码解析成功、全部项 StSkippedByUser、exit 0
-- （静默无事发生），而 @0-9000000000@ 会在任何盘面动作前把进程挂死。端点先
-- 与计划序号域比对。
caseOnlyOutOfRange :: IO ()
caseOnlyOutOfRange = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
  createDirectoryIfMissing True root
  op <- mkCopyOp (tmp </> "src" </> "a.jpg") "A" "a.jpg"
  plan <- mkPlanIO root [op]
  case applyOnlyToPlan (Just "0-999") plan of
    Left m -> assertBool ("越界须点名序号范围: " <> m) ("序号" `isInfixOf` m)
    Right _ -> assertFailure "越界 --only 应被拒（旧代码：静默全跳过 + 惰性巨列表）"
  case applyOnlyToPlan (Just "0") plan of
    Right (p, added) -> (map piStatus (plItems p), added) @?= ([StPending], [])
    Left m -> assertFailure ("范围内的 --only 不该被拒: " <> m)

-- | 目标前缀下残留过期条目（目录带外挪走后没重扫）时，rename 重键把两把 key
-- 写到同一目标：'-' (0x2D) < '\\' (0x5C) 让改写后的活条目排在前、过期条目
-- 排在后，Map.fromList 保留后者——catalog 记下一个已消失文件的 sha。改写后的
-- 条目必须胜出。
caseRekeyLeftBiased :: IO ()
caseRekeyLeftBiased = do
  let live = mkE ("Raw" </> "2025" </> "25-06-USA-Raw" </> "DSC1.ARW") "aa"
      stale = mkE ("Raw" </> "2025" </> "25-06-USA" </> "DSC1.ARW") "cc"
      item = PlanItem 0 (OpRename ("Raw" </> "2025" </> "25-06-USA-Raw") ("Raw" </> "2025" </> "25-06-USA") (FpDir "x")) StPending Nothing
      cat' = updateCatalog t0 [(item, ODone Nothing Nothing Nothing)] (mkCat [live, stale])
      k = "Raw" </> "2025" </> "25-06-USA" </> "DSC1.ARW"
  fmap enSha (Map.lookup k (catEntries cat')) @?= Just "aa"
  Map.size (catEntries cat') @?= 1

-- | 主库 root-id.json 损坏：旧 bindExecRoot 经 readRootInfo 的 Maybe 把它塌成
-- 「不命中」，报文「与主库、vault、备份盘均不符」宣称一次从未发生的比对。
caseBindRootReportsUnreadable :: IO ()
caseBindRootReportsUnreadable = withSystemTempDirectory "pm-sweep" $ \tmp -> do
  let root = tmp </> "root"
  createDirectoryIfMissing True root
  plan <- mkPlanIO root []
  writeFile (pmDir root </> "root-id.json") "{"
  let cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
  r <- bindExecRoot cfg plan "rid-x"
  case r of
    Left m -> assertBool ("零候选时须说明主库身份损坏，而非宣称比对不符: " <> m) ("身份损坏" `isInfixOf` m)
    Right _ -> assertFailure "身份损坏的 root 不得绑定"
