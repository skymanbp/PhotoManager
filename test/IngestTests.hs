{-# LANGUAGE OverloadedStrings #-}

-- | @pm vault ingest@（P6-D + 三十二轮 R4-R7）：批量入库的机械层。钉住——
-- 两份计划的形状与**预览两段式**（两份都存盘）、fail-closed 校验（含
-- case-fold 重名 \/ 跨类目占名 \/「暂不同步」名单）、I5 分流与 I7 耦合、
-- 「主库真的全部落完才轮到 vault」「两份都落完才给收尾步骤」两道执行闸、
-- 主库 role 闸（requireMain），以及 I7 来源登记（journal Intent 带库外
-- srcAbs）。
--
-- 双 stat（R9，源在读取期间变化 → 拒绝）没有直接用例：无法在不引入竞态
-- 的前提下让文件恰好在 sha256File 与 statSnap 之间变化；协议与
-- 'Pm.Scan.hashOne' 逐字同形，靠代码评审 + 该协议在 scan 侧的既有行为背书。
module IngestTests (ingestTests) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (isAbsolute, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Cli (GoOpts (..), PlanRun (..), savePlanAndMaybeRun')
import Pm.Config (Config (..), writeRootInfo)
import Pm.Ingest (ingestSteps, runVaultIngest)
import Pm.Journal (JEntry (..))
import Pm.Op
import Pm.Plan
import Pm.Types (RootInfo (..), RootRole (..))
import Pm.VaultHold (VaultHold (..))
import Pm.Win (openExclusiveBinary)
import System.IO (hClose)
import TestUtil (captureStdout, isIntent, journalEntries, mkVaultCfg, t0, tpid)

ingestTests :: TestTree
ingestTests =
  testGroup
    "P6-D pm vault ingest（两份计划 · fail-closed 校验 · I5/I7 · 执行次序闸）"
    [ testCase "预览两段式：主库 相册/ 在前、vault <类目>/ 在后，两份**都**存盘，kind=vault-ingest 无屏障" caseIngestPlans
    , testCase "fail-closed：类目/源缺失/重名(case-fold)/非 jpg/跨类目占名/HELD —— 全部错误一次列完，一份计划不出" caseIngestValidation
    , testCase "I5 分流 + I7 耦合：主库待裁决 → vault 同名项也待裁决；同名同内容 → PENDING" caseIngestConflict
    , testCase "端到端 --apply --yes：两份各落一份、源零改动、journal 记库外 srcAbs（I7）、收尾步骤打印" caseIngestE2E
    , testCase "R4 闸：主库有待裁决项（退出码仍 0）→ vault 那份不执行" caseIngestVaultGate
    , testCase "R5 闸：vault 那份未全落完 → 收尾步骤（move _done）不打印" caseIngestStepsGate
    , testCase "R6 闸：配置主库路径指向 backup root → requireMain 拒绝，一份计划不出" caseIngestRequireMain
    , testCase "三十三轮 F1：源/目标存在但读不出（独占占住）→ 错误清单 + 退出 2 + 零计划，不是 CLI 崩溃" caseIngestUnreadable
    , testCase "工作流 F072：ingestSteps 搬移行经 inboxDoneCommand——展开字符文件名给手动指引而非裸拼；命令行无反斜杠" caseIngestStepsSink
    , testCase "第一方自审 R1 的 ProbeUnknown 臂：占名查不出（非法字符名）→ 本批拒绝 exit 2 + 零计划（无需 ACL 夹具）" caseIngestProbeUnknown
    ]

-- | REVIEW-LOG 曾登记「crossCat 的 ProbeUnknown 分支需 ACL 夹具」——不需要：
-- 基名带 NTFS 非法字符时 'probeName' 得 ERROR_INVALID_NAME(123) → ProbeUnknown →
-- 'classifyGitProbe' Left → 错误清单里出现「的占名」+「核不了」。前提：被探的
-- 类目目录得在（父目录缺失时 Windows 先报 ERROR_PATH_NOT_FOUND(3) = NameMissing，
-- 实测），真实 vault 三个类目目录齐全，夹具补建一个。突变配对：把 ProbeUnknown
-- 折成 @Right False@（或删掉 Left 臂的收集）本用例转红。
caseIngestProbeUnknown :: IO ()
caseIngestProbeUnknown = withIngestEnv $ \cfg inbox -> do
  mapM_ (\v -> createDirectoryIfMissing True (v </> "portrait")) (cfgVaultPath cfg)
  (runP, gotP) <- capturePlans PrSaved
  (out, c) <- captureStdout (runVaultIngest runP False "landscape" [inbox </> "ill<egal.jpg"] cfg)
  c @?= 2
  assertBool ("应报「占名核不了」: " <> out) ("的占名" `isInfixOf` out && "核不了" `isInfixOf` out)
  ps <- gotP
  length ps @?= 0

-- | 临时主库 + vault + 一个 _inbox。回调收 (cfg, inbox 目录)。
withIngestEnv :: (Config -> FilePath -> IO ()) -> IO ()
withIngestEnv = withIngestEnvRole RoleMain

withIngestEnvRole :: RootRole -> (Config -> FilePath -> IO ()) -> IO ()
withIngestEnvRole role k = withSystemTempDirectory "pm-ingest" $ \tmp -> do
  let main' = tmp </> "main"
      vault = tmp </> "vault"
      inbox = tmp </> "_inbox"
  createDirectoryIfMissing True main'
  createDirectoryIfMissing True (vault </> "landscape")
  createDirectoryIfMissing True inbox
  now <- getCurrentTime
  writeRootInfo main' (RootInfo "im" role now Nothing)
  -- vault 的 root-id 由 ensureVaultRoot 在首次 ingest 时建（非 git 树，I11 平凡通过）
  k (Config main' (Just vault) Nothing Nothing Nothing Nothing Nothing Nothing Nothing) inbox

-- | 记录计划、按给定 'PlanRun' 应答的桩。
capturePlans :: PlanRun -> IO (Plan -> IO PlanRun, IO [Plan])
capturePlans reply = do
  ref <- newIORef []
  pure (\p -> modifyIORef ref (<> [p]) >> pure reply, readIORef ref)

-- | 真实执行（--apply --yes 的生产路径：存盘 → 确认跳过 → 执行）。
realRun :: Config -> Plan -> IO PlanRun
realRun cfg = savePlanAndMaybeRun' cfg (GoOpts True True)

caseIngestPlans :: IO ()
caseIngestPlans = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "AAA"
  writeFile (inbox </> "b.jpg") "BBB"
  (runP, gotP) <- capturePlans PrSaved
  c <- runVaultIngest runP False "landscape" [inbox </> "a.jpg", inbox </> "b.jpg"] cfg
  -- 预览结局 = 计划待处理（退出码 1，与全局协议一致）
  c @?= 1
  ps <- gotP
  map plKind ps @?= ["vault-ingest", "vault-ingest"]
  -- 屏障分类器：拷贝型计划不需要执行期组屏障
  kindBarrier "vault-ingest" @?= Nothing
  case ps of
    [pm', pv] -> do
      plRootPath pm' @?= cfgMainPath cfg
      Just (plRootPath pv) @?= cfgVaultPath cfg
      map (opDstRel . piOp) (plItems pm') @?= ["相册" </> "a.jpg", "相册" </> "b.jpg"]
      map (opDstRel . piOp) (plItems pv) @?= ["landscape" </> "a.jpg", "landscape" </> "b.jpg"]
      assertBool "全部 PENDING" (all ((== StPending) . piStatus) (plItems pm' <> plItems pv))
      -- src 是绝对路径（库外）——I7 的来源信息在 Op 里
      assertBool "src 绝对" (all (isAbsolute . opSrcAbs . piOp) (plItems pm'))
    other -> assertFailure ("应恰好两份计划（预览也要两段式），得到 " <> show (length other))

caseIngestValidation :: IO ()
caseIngestValidation = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "AAA"
  (runP, gotP) <- capturePlans PrSaved
  -- 类目不存在
  runVaultIngest runP False "scenery" [inbox </> "a.jpg"] cfg >>= (@?= 2)
  -- 空文件列表
  runVaultIngest runP False "landscape" [] cfg >>= (@?= 2)
  -- 源缺失
  runVaultIngest runP False "landscape" [inbox </> "ghost.jpg"] cfg >>= (@?= 2)
  -- 同名两份（不同目录）——精确同名
  createDirectoryIfMissing True (inbox </> "sub")
  writeFile (inbox </> "sub" </> "a.jpg") "OTHER"
  runVaultIngest runP False "landscape" [inbox </> "a.jpg", inbox </> "sub" </> "a.jpg"] cfg >>= (@?= 2)
  -- 只差大小写也算同名（三十二轮 R7：NTFS 不分大小写）
  writeFile (inbox </> "sub" </> "A.JPG") "OTHER2"
  runVaultIngest runP False "landscape" [inbox </> "a.jpg", inbox </> "sub" </> "A.JPG"] cfg >>= (@?= 2)
  -- 非 jpg
  writeFile (inbox </> "x.png") "PNG"
  runVaultIngest runP False "landscape" [inbox </> "x.png"] cfg >>= (@?= 2)
  -- 跨类目占名（三十二轮）：同名已发布在 portrait → 拒绝（否则落成 DUPLICATE）
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> do
      createDirectoryIfMissing True (v </> "portrait")
      writeFile (v </> "portrait" </> "a.jpg") "PUBLISHED"
      runVaultIngest runP False "landscape" [inbox </> "a.jpg"] cfg >>= (@?= 2)
  -- 「暂不同步」名单（三十二轮）：push 被 HELD 挡，ingest 不得更松。
  -- held.jpg 与上面的跨类目占名无关，HELD 是这一跑唯一的错误源。
  now <- getCurrentTime
  BSLC.writeFile
    (cfgMainPath cfg </> ".pm" </> "vault-holds.json")
    (encode [VaultHold "held.jpg" (T.replicate 64 "a") now Nothing])
  writeFile (inbox </> "held.jpg") "HELD-BYTES"
  (out, ch) <- captureStdout (runVaultIngest runP False "landscape" [inbox </> "held.jpg"] cfg)
  ch @?= 2
  assertBool ("应指向 unhold: " <> out) ("unhold" `isInfixOf` out)
  -- HELD 比较 case-fold（三十二轮交叉复核 R8）：大小写变体不得绕过决定
  writeFile (inbox </> "HELD.JPG") "HELD-BYTES-2"
  runVaultIngest runP False "landscape" [inbox </> "HELD.JPG"] cfg >>= (@?= 2)
  ps <- gotP
  length ps @?= 0

caseIngestConflict :: IO ()
caseIngestConflict = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "NEW-BYTES"
  writeFile (inbox </> "b.jpg") "SAME"
  -- 相册 已有同名不同内容的 a.jpg；vault 已有同名同内容的 b.jpg
  createDirectoryIfMissing True (cfgMainPath cfg </> "相册")
  writeFile (cfgMainPath cfg </> "相册" </> "a.jpg") "OLD-BYTES"
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> writeFile (v </> "landscape" </> "b.jpg") "SAME"
  (runP, gotP) <- capturePlans PrSaved
  c <- runVaultIngest runP False "landscape" [inbox </> "a.jpg", inbox </> "b.jpg"] cfg
  c @?= 1
  ps <- gotP
  case ps of
    [pm', pv] -> do
      [piStatus it | it <- plItems pm', takeFileName (opDstRel (piOp it)) == "a.jpg"]
        @?= [StNeedsDecision "目标已存在且内容不同（I5）→ pm resolve --keep src|dst|both"]
      -- I7 耦合（三十二轮 R4 的生成期闸）：主库 a.jpg 待裁决 → vault 同名项
      -- 也待裁决，单独 apply vault 计划不能先于相册落下这个名字
      [piStatus it | it <- plItems pv, takeFileName (opDstRel (piOp it)) == "a.jpg"]
        @?= [StNeedsDecision "主库（相册）同名项待裁决（I7：先裁决并完成相册那份，再 resolve --unskip 本项）"]
      [piStatus it | it <- plItems pv, takeFileName (opDstRel (piOp it)) == "b.jpg"]
        @?= [StPending]
    _ -> assertFailure "应恰好两份计划"

-- | 收尾步骤是「整块粘进终端」的文本：搬移行此前裸拼源路径（合法 NTFS 名
-- @IMG_$(whoami).jpg@ 在 bash 双引号内照样展开；目标以 @\\"@ 收尾把闭合引号
-- 转义掉）。经 'Pm.Publish.inboxDoneCommand' 后：嵌不进的给手动指引，能嵌的
-- 以 @/@ 重渲染——命令行里不再有反斜杠。
caseIngestStepsSink :: IO ()
caseIngestStepsSink = do
  let cfg = mkVaultCfg "D:\\main" "D:\\vault"
      isCmd l = let t = dropWhile (== ' ') l in take 3 t == "mv " || take 4 t == "git "
      cmdLines = filter isCmd
      bad = ingestSteps cfg "D:\\vault" tpid "landscape" ["D:\\_inbox\\IMG_$(whoami).jpg"]
  assertBool ("展开字符文件名不得裸拼进命令: " <> unlines bad) (not (any ("$(" `isInfixOf`) (cmdLines bad)))
  assertBool ("应给手动指引: " <> unlines bad) (any ("请手动" `isInfixOf`) bad)
  let ok = ingestSteps cfg "D:\\vault" tpid "landscape" ["D:\\_inbox\\a.jpg"]
  assertBool ("应有重渲染的 mv 行: " <> unlines ok) (any ("mv -- \"D:/_inbox/a.jpg\" \"D:/_inbox/_done/\"" `isInfixOf`) ok)
  assertBool ("命令行不得含反斜杠: " <> unlines ok) (not (any ('\\' `elem`) (cmdLines ok)))

caseIngestE2E :: IO ()
caseIngestE2E = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "PHOTO-A"
  (out, c) <- captureStdout (runVaultIngest (realRun cfg) True "landscape" [inbox </> "a.jpg"] cfg)
  c @?= 0
  readFile (cfgMainPath cfg </> "相册" </> "a.jpg") >>= (@?= "PHOTO-A")
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> readFile (v </> "landscape" </> "a.jpg") >>= (@?= "PHOTO-A")
  -- 拷贝不移动：源零改动
  readFile (inbox </> "a.jpg") >>= (@?= "PHOTO-A")
  -- 两份都全落完 → 收尾步骤（move 进 _done）这回要打印
  assertBool ("收尾步骤应打印: " <> out) ("_done" `isInfixOf` out)
  -- I7 来源登记：主库 journal 的 Intent 带库外 srcAbs
  es <- journalEntries (cfgMainPath cfg)
  let srcs = [opSrcAbs op | e@(JIntent _ op _) <- es, isIntent e]
  srcs @?= [inbox </> "a.jpg"]
  seq t0 (pure ())

-- | 三十二轮 R4：主库那份有待裁决项时退出码仍是 0（ONotExecuted 不进
-- 退出码）——vault 那份必须**不执行**，否则 vault 里出现相册没有的字节
-- （vault ⊆ 相册 被破坏）。b.jpg 无冲突：闸若退回「只看退出码」，b.jpg
-- 会落进 vault，本用例转红。
caseIngestVaultGate :: IO ()
caseIngestVaultGate = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "NEW-BYTES"
  writeFile (inbox </> "b.jpg") "CLEAN"
  createDirectoryIfMissing True (cfgMainPath cfg </> "相册")
  writeFile (cfgMainPath cfg </> "相册" </> "a.jpg") "OLD-BYTES"
  c <- runVaultIngest (realRun cfg) True "landscape" [inbox </> "a.jpg", inbox </> "b.jpg"] cfg
  c @?= 1
  -- 主库那份确实执行了（b 落了、a 保持旧字节待裁决）
  readFile (cfgMainPath cfg </> "相册" </> "b.jpg") >>= (@?= "CLEAN")
  readFile (cfgMainPath cfg </> "相册" </> "a.jpg") >>= (@?= "OLD-BYTES")
  -- vault 那份整份没跑：连无冲突的 b.jpg 都不在
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> do
      doesFileExist (v </> "landscape" </> "b.jpg") >>= (@?= False)
      doesFileExist (v </> "landscape" </> "a.jpg") >>= (@?= False)

-- | 三十二轮 R5：vault 那份有未落完项（这里：vault 侧 I5 待裁决）时，收尾
-- 步骤（把源移进 _done）不得打印——源一走，vault 计划里的 opSrcAbs 全部
-- 失效，裁决完也执行不了。
caseIngestStepsGate :: IO ()
caseIngestStepsGate = withIngestEnv $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "PHOTO-A"
  case cfgVaultPath cfg of
    Nothing -> assertFailure "fixture 必有 vault"
    Just v -> writeFile (v </> "landscape" </> "a.jpg") "DIFFERENT"
  (out, c) <- captureStdout (runVaultIngest (realRun cfg) True "landscape" [inbox </> "a.jpg"] cfg)
  c @?= 1
  -- 主库那份照常落
  readFile (cfgMainPath cfg </> "相册" </> "a.jpg") >>= (@?= "PHOTO-A")
  -- vault 未全落完 → 不给 move _done 指令
  assertBool ("收尾步骤不应打印: " <> out) (not ("_done" `isInfixOf` out))

-- | 三十二轮 R6：与 push 同一道 role 闸。配置主库路径指向 backup root 时，
-- 以「主库」身份生成计划会把 相册\\ 与 journal 写进备份盘。
caseIngestRequireMain :: IO ()
caseIngestRequireMain = withIngestEnvRole RoleBackup $ \cfg inbox -> do
  writeFile (inbox </> "a.jpg") "AAA"
  (runP, gotP) <- capturePlans PrSaved
  c <- runVaultIngest runP False "landscape" [inbox </> "a.jpg"] cfg
  c @?= 2
  ps <- gotP
  length ps @?= 0

-- | 三十三轮 F1：生成期的源/目标 IO 全部 fail-closed。`doesFileExist` 通过后
-- 文件被良性进程占住（这里用独占句柄 FILE_SHARE_NONE 造成确定性占用：存在性
-- 探测按属性走、照常 True，sha256File 的 ReadMode 打开必抛）——异常必须变成
-- 错误清单 + 退出 2 + 零计划，而不是逃顶把 CLI 崩掉。
caseIngestUnreadable :: IO ()
caseIngestUnreadable = withIngestEnv $ \cfg inbox -> do
  (runP, gotP) <- capturePlans PrSaved
  -- 目标侧：相册\a.jpg 存在但读不出 → mkItem 的 I5 同异判不出，整批拒绝
  writeFile (inbox </> "a.jpg") "AAA"
  createDirectoryIfMissing True (cfgMainPath cfg </> "相册")
  h <- openExclusiveBinary (cfgMainPath cfg </> "相册" </> "a.jpg")
  c1 <- runVaultIngest runP False "landscape" [inbox </> "a.jpg"] cfg
  hClose h
  c1 @?= 2
  -- 源侧：_inbox 的源被独占占住 → 探证阶段 try 接住，同样整批拒绝
  h2 <- openExclusiveBinary (inbox </> "b.jpg")
  c2 <- runVaultIngest runP False "landscape" [inbox </> "b.jpg"] cfg
  hClose h2
  c2 @?= 2
  ps <- gotP
  length ps @?= 0
