{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Shared fixtures and helpers for the pm test suite.
module TestUtil
  ( mkCopyOp
  , mkPlanIO
  , mkGroupPlanIO
  , ensureTestRoot
  , tpid
  , tpOid
  , injectAt
  , runCrash
  , execOk
  , execOkWith
  , doctorRows
  , journalEntries
  , isIntent
  , isDone
  , isClean
  , truncateJournalTo
  , t0
  , mkE
  , mkCat
  , scanQuiet
  , elemSubstr
  , pad2
  , mkVaultCfg
  , writeF
  , mkMain
  , execNow
  , plantStaleCatalog
  , withForeignLock
  , captureStdout
  , trashViewOK
  , withDenyAll
  , withDenyList
  , disableBackupPrivileges
  ) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, bracket_, finally, throwIO, try)
import Control.Monad (forM_, void, when)
import Data.Word (Word32)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import System.Environment (getEnv)
import System.Process (readCreateProcess, shell)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, setModificationTime)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (IOMode (..), hClose, hFlush, hGetContents, hSetEncoding, openFile, stdout, utf8)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import Pm.Cli (PlanRun (..), executePlanNowWith)
import Pm.Config (Config (..), RootIdState (..), createRootInfo, readRootState, writeRootInfo)
import Pm.Doctor (DoctorOpts (..), Finding (..), Severity, runDoctor)
import Pm.Exec
import Pm.Hash
import Pm.Journal
import Pm.Lock (withRootLock)
import Pm.Op
import Pm.Plan
import Pm.Scan (ScanOpts (..), ScanResult (..), scanRoot)
import Pm.Trash (TrashView, trashView)
import Pm.Types
-- 'plantStaleCatalog' 的前提断言用（限定导入：与上面的显式清单分开，读起来一眼看出是夹具自检用）
import qualified Pm.Catalog as Cat
import qualified Pm.Config as Cfg

-- | 对路径挂「当前用户全拒 (F)」ACE 跑动作，结束必解除（bracket_；文件
-- 所有者恒可改回自己文件的 DACL，不会被自己锁死）。三十九轮（P7）实验：
-- 拒 (RA)/(RD,RA) 都不影响 GetFileAttributesEx 类探针（目录元数据兜底），
-- 全拒 (F) 才让 CreateFile 类探针（pathIsSymbolicLink/getFileSize/
-- getModificationTime）确定性 permission denied——这是「非 ENOENT 探针
-- 失败」目前唯一的确定性注入形态。
withDenyAll :: FilePath -> IO a -> IO a
withDenyAll p act = do
  user <- getEnv "USERNAME"
  let icacls args = () <$ readCreateProcess (shell ("icacls \"" <> p <> "\" " <> args <> " >nul")) ""
  bracket_ (icacls ("/deny \"" <> user <> "\":(F)")) (icacls ("/remove:d \"" <> user <> "\"")) act

-- | 同 'withDenyAll'，但只拒**列目录**权限 (RD)：第一方自审工作流 F039/F040
-- 实测——目录级拒 (RD) 让 GetFileAttributes 与 doesDirectoryExist 照常成功
-- （probeName = NamePlain），FindFirstFile 却 ERROR_ACCESS_DENIED，即
-- listDirectory 确定性抛出。这是「目录在、列不出」的确定性注入形态。
withDenyList :: FilePath -> IO a -> IO a
withDenyList p act = do
  user <- getEnv "USERNAME"
  let icacls args = () <$ readCreateProcess (shell ("icacls \"" <> p <> "\" " <> args <> " >nul")) ""
  bracket_ (icacls ("/deny \"" <> user <> "\":(RD)")) (icacls ("/remove:d \"" <> user <> "\"")) act

-- | 上面两种注入的**前提**：本进程的令牌里 SeBackupPrivilege / SeRestorePrivilege
-- 没有启用。启用着的话，pm 的探针（GetFileAttributesEx / FindFirstFile / 带
-- FILE_FLAG_BACKUP_SEMANTICS 的 CreateFile / DeleteFile）全部绕过 DACL，注入
-- 形同虚设——CI 抓包分支实测（2026-08-28）：GitHub windows runner 是提权管理员
-- 令牌，MSYS2 bash 启动时把这两项启用，`stack test` 从 bash 拉起就继承「已启用」，
-- 9 例 ACL 用例全红、其余全绿。套件启动时在自己的令牌里把两项禁用（cbits
-- @pm_disable_backup_privileges@），与启动它的 shell 无关；普通桌面会话令牌里
-- 根本没有这两项，调用是空操作。返回 Left 错误码只在 OpenProcessToken 之类
-- 失败时出现。
foreign import ccall unsafe "pm_disable_backup_privileges"
  c_pmDisableBackupPrivileges :: Ptr Word32 -> IO Word32

disableBackupPrivileges :: IO (Either Word32 ())
disableBackupPrivileges = alloca $ \errp -> do
  ok <- c_pmDisableBackupPrivileges errp
  err <- peek errp
  pure (if ok /= 0 then Right () else Left err)

-- | 'trashView' 三十五轮 Either 化（枚举 fail-closed）后的测试解包：正常
-- fixture 里枚举失败即测试失败，各用例照旧拿 TrashView 断言。
trashViewOK :: FilePath -> IO TrashView
trashViewOK root = trashView root >>= either (assertFailure . ("trashView 枚举失败: " <>)) pure

-- | 造一个 src 文件并生成对应的 Copy op（含真实前置条件）。
mkCopyOp :: FilePath -> String -> FilePath -> IO Op
mkCopyOp srcAbs content dstRel = do
  createDirectoryIfMissing True (takeDirectory srcAbs)
  writeFile srcAbs content
  sha <- sha256File srcAbs
  s <- statSnap srcAbs
  pure (OpCopy srcAbs dstRel sha (ssSize s) (ssMtimeNs s))

-- | 测试 root 身份（P3b-6 复审 A3：内核不再放行匿名 root）。root 目录已存在
-- → 确保带 role 标识并返回其 UUID（已有标识则沿用，不改写 role）；目录不
-- 存在（纯计划 fixture，如 \"R:\"）→ Nothing，计划 rootId 留空——这类计划
-- 从不执行。P3b-8 复审 minor：走 'readRootState' + 'createRootInfo'（生产
-- 路径，no-replace）——损坏的标识是测试要保留的状态，fixture 不得把它当缺席
-- 覆盖掉（此前 readRootInfo == Nothing 即 writeRootInfo）。
ensureTestRoot :: RootRole -> FilePath -> IO (Maybe Text)
ensureTestRoot role root = do
  ex <- doesDirectoryExist root
  if not ex
    then pure Nothing
    else do
      st <- readRootState root
      case st of
        RootPresent i -> pure (Just (riId i))
        RootCorrupt e -> assertFailure ("fixture: root-id 损坏，不覆盖（" <> e <> "）")
        RootUntrusted m -> assertFailure ("fixture: .pm 不可信（" <> m <> "）")
        RootAbsent -> do
          now <- getCurrentTime
          r <- createRootInfo root (RootInfo "test-root" role now Nothing)
          case r of
            Left e -> assertFailure ("fixture: createRootInfo 失败: " <> e)
            Right () -> pure (Just "test-root")

-- | 测试用的合法 planId 与其 opId（P3b-8：'opIdParts' 只认生成格式，手编
-- journal 的 fixture 不能再用 \"p#0\" 之类短 pid）。
tpid :: Text
tpid = "20260101-000000-abcdef"

tpOid :: Int -> Text
tpOid = opId tpid

mkPlanIO :: FilePath -> [Op] -> IO Plan
mkPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  rid <- ensureTestRoot RoleMain root
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plRootId = rid
      , plCreated = now
      , plItems = [PlanItem i op StPending Nothing | (i, op) <- zip [0 ..] ops]
      }

-- | 带复合组的测试计划（P2.1 组语义测试用）。
mkGroupPlanIO :: FilePath -> [(Op, Maybe Int)] -> IO Plan
mkGroupPlanIO root ops = do
  pid <- newPlanId
  now <- getCurrentTime
  rid <- ensureTestRoot RoleMain root
  pure
    Plan
      { plId = pid
      , plKind = "test"
      , plRootPath = root
      , plRootId = rid
      , plCreated = now
      , plItems = [PlanItem i op StPending g | (i, (op, g)) <- zip [0 ..] ops]
      }

injectAt :: Checkpoint -> ExecEnv
injectAt cp =
  defaultExecEnv {eeCheckpoint = \c -> when (c == cp) (throwIO (userError "inject-crash"))}

-- | 注入崩溃：期望异常逃逸（= 进程死亡模型）。
runCrash :: ExecEnv -> Plan -> IO ()
runCrash env plan = do
  r <- try (execPlan env plan) :: IO (Either SomeException (Either String [(PlanItem, ItemOutcome)]))
  case r of
    Left _ -> pure ()
    Right _ -> assertFailure "expected injected crash to escape execPlan"

execOk :: Plan -> IO [(PlanItem, ItemOutcome)]
execOk = execOkWith defaultExecEnv

-- | 同上，但由调用方给 'ExecEnv'。需要它的是**要屏障的计划种类**
-- （'Pm.Plan.kindBarrier' 给 Just 的那些）：内核对缺席的屏障整批拒绝，所以考
-- Op 机制而非考屏障的用例必须显式挂一个放行屏障 @Just (\\_ _ -> pure [])@，
-- 写出来而不是默认得到。
execOkWith :: ExecEnv -> Plan -> IO [(PlanItem, ItemOutcome)]
execOkWith env plan = do
  r <- execPlan env plan
  case r of
    Left e -> assertFailure ("lock busy unexpectedly: " <> e) >> pure []
    Right rs -> pure rs

doctorRows :: FilePath -> IO [(String, Severity)]
doctorRows root = do
  (fs, _) <- runDoctor root (DoctorOpts False False)
  pure [(fRow f, fSeverity f) | f <- fs]

journalEntries :: FilePath -> IO [JEntry]
journalEntries root = fst <$> readJournal root

isIntent, isDone, isClean :: JEntry -> Bool
isIntent JIntent {} = True; isIntent _ = False
isDone JDone {} = True; isDone _ = False
isClean JCleanShutdown {} = True; isClean _ = False

-- 掉电模拟：把 journal 重写为给定条目（= 尾部未 fsync 丢失）。
truncateJournalTo :: FilePath -> [JEntry] -> IO ()
truncateJournalTo root es = do
  removeJournal
  withJournal root $ \j -> forM_ es (jAppend j Buffered)
 where
  removeJournal = do
    ex <- doesFileExist (journalPath root)
    when ex (writeFile (journalPath root) "")

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

mkE :: FilePath -> String -> Entry
mkE p sha = Entry p 1 0 (T.pack sha) KindPhoto Nothing

-- | 41 轮 #5 后 catalog 身份必须与 root-id 对账：夹具主流写
-- @RootInfo "m"@，这里同号；显式 id 的夹具自己写配对的 root-id。
mkCat :: [Entry] -> Catalog
mkCat es = Catalog "m" t0 (entryMap es)

scanQuiet :: String -> FilePath -> IO Catalog
scanQuiet rid root = srCatalog <$> scanRoot (ScanOpts 1 False) Nothing (T.pack rid) root

elemSubstr :: String -> String -> Bool
elemSubstr needle hay = any (\i -> take (length needle) (drop i hay) == needle) [0 .. length hay]

pad2 :: Int -> String
pad2 n = if n < 10 then '0' : show n else show n

-- | 进程级 stdout 重定向（原在 SortTests，三十轮起多个模块要用，移到这里）。
--
-- **两端都必须显式 UTF-8**：本机 locale 是 GBK，而 pm 的输出里有 U+26A0(⚠)
-- 与 U+2717(✗)，临时文件句柄按 locale 编码会直接抛 commitBuffer。tasty 已由
-- Spec.hs 钉成 NumThreads 1——重定向的是**进程级** stdout，并行会互相污染。
captureStdout :: IO a -> IO (String, a)
captureStdout act = withSystemTempDirectory "pm-cap" $ \dir -> do
  let fp = dir </> "out.txt"
  h <- openFile fp WriteMode
  hSetEncoding h utf8
  old <- hDuplicate stdout
  hDuplicateTo h stdout
  -- hDuplicate/hDuplicateTo 造出的句柄用的是 **locale** 编码，会把
  -- setupConsole 设好的 utf8 抹掉——替换后和还原后都要显式钉回去，
  -- 否则 pm 输出里的 ✗/⚠ 在这里、以及**后续用例**里都会炸。
  hSetEncoding stdout utf8
  a <- act `finally` (hFlush stdout >> hDuplicateTo old stdout >> hSetEncoding stdout utf8 >> hClose old)
  hClose h -- 必须先关：GHC 句柄锁不许「已开写」的文件同时被开读
  txt <- bracket (openFile fp ReadMode) hClose $ \rh -> do
    hSetEncoding rh utf8
    t <- hGetContents rh
    length t `seq` pure t
  pure (txt, a)


-- vault 系 IO 用例的共享 fixture（三十四轮拆分 VaultTests 时上移，逐字节搬移）。

mkVaultCfg :: FilePath -> FilePath -> Config
mkVaultCfg root vdir =
  Config
    { cfgMainPath = root
    , cfgVaultPath = Just vdir
    , cfgPhotosJson = Nothing
    , cfgWorkers = Nothing
    , cfgBackupId = Nothing
    , cfgBackupSubpath = Nothing
    , cfgPortfolioDir = Nothing
    , cfgVaultPush = Nothing
    , cfgPortfolioPush = Nothing
    }

writeF :: FilePath -> String -> IO ()
writeF fp s = createDirectoryIfMissing True (takeDirectory fp) >> writeFile fp s

-- | 主库 root 标识（P3b-6 复审 B1：computeVault 以主库身份读 相册/写 vault-cache，
-- 缺 RoleMain 标识 → exit 2；IO 用例先建标识）。
mkMain :: FilePath -> IO ()
mkMain root = writeRootInfo root (RootInfo "main-rid" RoleMain t0 Nothing)

-- | 立即执行的 runPlan（测试用：跳过交互确认，仍走完整 Exec 内核）。
-- 返回 'PlanRun'：push 的收尾自工作流 F068 起按逐项结果判，不按退出码。
execNow :: Config -> Plan -> IO PlanRun
execNow cfg p = savePlan p >> uncurry PrRun <$> executePlanNowWith cfg putStrLn p

-- | 「陈旧 catalog 命中 stat」夹具（P4-7 hold 与 P8-C note 共用）：@jpg@ 先写
-- "AAA"，跑完 @between@ 后取 stat 快照与旧 sha，再**等长替换**成 "BBB" 并还原
-- mtime——主库 catalog 里那条 (size,mtime) 仍然命中，但盘上字节已不是那张。
-- 返回 (陈旧 sha, 真实 sha)：决定 \/ 记录的**创建与复核**都必须取到真实 sha
-- （codex 二十一 \/ 二十二轮 major）。
plantStaleCatalog :: FilePath -> FilePath -> IO () -> IO (Text, Text)
plantStaleCatalog root jpg between = do
  writeF jpg "AAA"
  between
  snap <- statSnap jpg
  staleSha <- sha256File jpg
  writeF jpg "BBB"
  setModificationTime jpg (nsToUtc (ssMtimeNs snap))
  realSha <- sha256File jpg
  assertBool "构造前提：两个 sha 必须不同" (staleSha /= realSha)
  -- catalog 必须带**这个 root 的真实 id**：41 轮起 'loadCatalog' 核对
  -- catRootId ≡ root-id.json，身份不符整份拒载 → 主库缓存为空 → 每个 sha 都
  -- 真实重读，「缓存命中」的前提静默失效（P8-C 突变 m2 未判红才发现：此前
  -- 用 'mkCat' 的固定 "m" 配 'mkMain' 的 "main-rid"，P4-7 两条同型用例空转）。
  rid <- maybe (assertFailure (root <> " 没有 root-id（先 mkMain）")) (pure . riId) =<< Cfg.readRootInfo root
  let verified = addUTCTime 3600 (nsToUtc (ssMtimeNs snap))
  saveCatalog root (Catalog rid t0 (entryMap [Entry ("相册" </> takeFileName jpg) (ssSize snap) (ssMtimeNs snap) staleSha KindPhoto (Just verified)]))
  -- 前提写成断言：catalog 载得进 + (size,mtime,lastVerified) 对盘上文件命中
  lc <- Cat.loadCatalog root
  case lc of
    Cat.CatLoaded _ _ -> pure ()
    other -> assertFailure ("陈旧 catalog 未能载入，缓存命中前提不成立: " <> Cat.loadNote other)
  snap2 <- statSnap jpg
  now <- getCurrentTime
  assertBool "陈旧 catalog 条目必须 statHitStable 命中" (statHitStable now (ssSize snap) (ssMtimeNs snap) (Just verified) snap2)
  pure (staleSha, realSha)

-- | 另一个「pm 进程」正持有主库 root lock 时跑动作（I10 事务用例共用）：
-- 动作结束（含异常）必释放，不留一条挂起的持锁线程影响后续用例。
withForeignLock :: FilePath -> IO a -> IO a
withForeignLock root act = do
  gotLock <- newEmptyMVar
  release <- newEmptyMVar
  void . forkIO . void $ withRootLock root (putMVar gotLock () >> takeMVar release)
  takeMVar gotLock
  act `finally` putMVar release ()
