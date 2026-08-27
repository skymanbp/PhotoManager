{-# LANGUAGE OverloadedStrings #-}

-- | 相册 ↔ vault 展示集：status 六态差异（DESIGN.md §10.1）与 push 写路径
-- （§10.2）。status 六态语义与 JSON 值形状逐字段兼容 sync_photos.py
-- （docs\/specs\/sync-photos-legacy-spec.md 是逐行为基线）；UNPUSHABLE 是 pm
-- 新增第七态：.png 在 status 里显式可见（push 写路径拒收），不改变六态归类
-- 也不影响退出码。
--
-- I11：vault 是 git 工作树——status 对 vault 目录**零写入**（vault 侧 sha
-- 缓存放主库 `.pm\/vault-cache\/`）；push 建 vault root 前先验 `.gitignore`
-- 已覆盖 `.pm\/`（用户批准 2026-08-23），验不过 fail-closed。
-- I9：pm 绝不执行 git——push 结束打印显式路径的 git 步骤（禁 -A）。
module Pm.Vault
  ( VaultDiff (..)
  , vaultDiff
  , fixedCategories
  , photoExtFold
  , renderVaultJson
  , VaultCacheMeta (..)
  , readVaultCacheMeta
  , VaultReport (..)
  , computeVault
  , listFlatPhotos
  , ensureVaultRoot
  , vaultIgnoreGuard
  , gitStepsLines
  , planCategories
  , resultCategories
  , runVaultStatus
  , runVaultPush
  , newActive
  , freshSrcSha
  , hasDiffR
  , checkAssignments
  , vaultPushItems
  , mkVaultPushPlan
  , photosJsonRef
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_, unless)
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.Char (toLower)
import Data.List (nub, partition, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import System.Directory (canonicalizePath, doesDirectoryExist, listDirectory)
import System.FilePath (splitDirectories, takeExtension, (</>))
import Text.Printf (printf)

import Pm.Catalog (CatalogLoad (..), catalogMaybe, loadCatalog, loadNote)
import Pm.Cli (PlanRun (..), landedItems, planRunCode)
import Pm.Config (Config (..), RootIdState (..), SideCacheWrite (..), createRootInfo, freshRootId, pmSubVaultCache, readRootInfo, readRootState, readSideCache, requireMain, writeSideCache)
import Pm.Exec (ItemOutcome)
import Pm.GitGuard (vaultIgnoreGuard)
import Pm.Hash (StatSnap (..), sha256File, statHitStable, statSnap)
import Pm.Op
import Pm.Plan
import Pm.Publish (vaultCommands)
import Pm.Types
import Pm.VaultCore (VaultDiff (..), fixedCategories, photoExtFold, pushableExt, renderVaultJson, vaultDiff)
import Pm.VaultHold (VaultHold (..), readHolds, splitHeld)
import Pm.Win (volumeFsType, whenPresent)

-- ─── vault 侧缓存（主库 .pm\/vault-cache\/，display + sha 复用） ─────────────

-- | 上次比对的计数快照（pm status 不触 vault 也能报，同备份盘缓存性质）。
-- 键名由 Generic 派生（去 vm 前缀 + 全小写），非 legacy 兼容面。
-- P3b-4 评审 #4：缓存键是类目相对路径，vault 被换路径\/换 root 后
-- (size,mtime) 巧合会复用错误 sha——meta 记录生成时的规范路径与 root
-- UUID，身份不符即整体弃用缓存（旧格式 meta 缺字段 → 解析失败 → 同弃用）。
data VaultCacheMeta = VaultCacheMeta
  { vmAt :: UTCTime
  , vmVaultPath :: FilePath
  , vmRootId :: Maybe Text
  , vmOk, vmNew, vmMissing, vmRenamed, vmDrift, vmDuplicate, vmUnpushable, vmUnstable :: Int
  , vmHeld :: Int
    -- ^ 第九态（P4-7）：已决定「暂不同步」的 NEW 张数。`pm status` 的 vault
    -- 行用 NEW − HELD 算差异，否则已经做过的决定会永远显示成待办。
  }
  deriving (Show, Eq, Generic)

vaultMetaOpts :: Options
vaultMetaOpts = defaultOptions {fieldLabelModifier = map toLower . drop 2}

instance ToJSON VaultCacheMeta where
  toJSON = genericToJSON vaultMetaOpts
  toEncoding = genericToEncoding vaultMetaOpts

instance FromJSON VaultCacheMeta where
  parseJSON = genericParseJSON vaultMetaOpts

-- P3b-14（十一轮复审 major）：同 'Pm.Backup.readBackupCacheMeta' —— 读侧改走
-- 受信取用口。vault 缓存参与 sha 复用判定，读到库外字节会直接影响 push 前的
-- 六态判定。P3b-15（十二轮 minor）：失信保留为 Left——compute 路径可以弃用
-- 缓存内容重算（保守方向），但要把失信原因报给用户；status 仪表盘计入退出码。
readVaultCacheMeta :: FilePath -> IO (Either String (Maybe VaultCacheMeta))
readVaultCacheMeta mainRoot = readSideCache mainRoot pmSubVaultCache "meta.json"

readVaultCacheCatalog :: FilePath -> IO (Either String (Maybe Catalog))
readVaultCacheCatalog mainRoot = readSideCache mainRoot pmSubVaultCache "catalog.json"

writeVaultCache :: FilePath -> Catalog -> VaultCacheMeta -> IO SideCacheWrite
writeVaultCache mainRoot = writeSideCache mainRoot pmSubVaultCache

-- ─── IO：列目录 + 缓存感知 sha ──────────────────────────────────────────────

-- | 平铺列出目录内照片文件（case-fold 过滤），并报告出现的子目录名
-- （legacy 非递归扫描让子目录内容彻底不可见——pm 保持平铺语义但把
-- 子目录显式报出来，不静默）。
--
-- 三十四轮 F1 同族：存在性判定与枚举之间目录可被并发进程挪走/删除
-- （Explorer、用户手工整理），listDirectory 抛出会一路逃顶；而静默退化成
-- 空列表更糟——整个另一侧会被伪报成 MISSING/NEW。枚举失败 = Left，
-- 调用方整体拒绝本轮报告（exit 2，与 "source missing" 同级）。
--
-- 第一方自审 R1：存在性此前是 @doesDirectoryExist@ 二态——类目目录被 ACL 拒时
-- 塌成「不存在 = 空」，整个类目的照片伪报 NEW、一张都不 MISSING。改走
-- 'whenPresent' 三态：缺席才是空，查不出 = Left（本轮报告整体拒绝）。
listFlatPhotos :: FilePath -> IO (Either String ([FilePath], [FilePath]))
listFlatPhotos dir = do
  r <- whenPresent dir (listDirectory dir >>= mapM (\n -> (,) n <$> doesDirectoryExist (dir </> n)))
  pure $ case r of
    Left e -> Left (dir <> " 枚举失败（" <> e <> "）")
    Right Nothing -> Right ([], [])
    Right (Just flagged) ->
      let (dirs, files) = partition snd flagged
       in Right (sort (filter photoExtFold (map fst files)), sort (map fst dirs))

-- | 取一个文件的 sha：stat 与缓存条目一致（statHitStable：含 racy 余量
-- 判据，评审 #4）→ 复用；否则真实重读，双 stat 防撕裂。三轮不稳 →
-- (末次 sha, Nothing)——调用方把该名整体从六态分类排除并单列报告
-- （评审 #5）。本函数不打印：--json 输出面要纯净，告警由调用方按
-- quiet 决定。
shaViaCache :: Map FilePath Entry -> FilePath -> FilePath -> IO (Text, Maybe Entry)
shaViaCache cache rel abs' = do
  pre <- statSnap abs'
  case Map.lookup rel cache of
    Just e
      | statHitStable (enSize e) (enMtimeNs e) (enLastVerified e) pre ->
          pure (enSha e, Just e)
    _ -> go (3 :: Int) pre
 where
  go n pre = do
    sha <- sha256File abs'
    post <- statSnap abs'
    if post == pre
      then do
        now <- getCurrentTime
        pure
          ( sha
          , Just
              Entry
                { enPath = rel
                , enSize = ssSize post
                , enMtimeNs = ssMtimeNs post
                , enSha = sha
                , enKind = classifyExt (takeExtension rel)
                , enLastVerified = Just now
                }
          )
      else
        if n > 1
          then go (n - 1) post
          else pure (sha, Nothing)

-- ─── 共享计算核心（status 与 push 同源；每次运行顺带刷新缓存） ──────────────

data VaultReport = VaultReport
  { vrSrcDir, vrVaultDir :: FilePath
  , vrSrcCount, vrVaultCount :: Int
  , vrDiff :: VaultDiff
  , vrUnpushable :: [(FilePath, String)]
  , vrUnstable :: [(FilePath, String)]
    -- ^ (名, 位置)：任一侧三轮双 stat 仍不稳（评审 #5）**或读口 IOException
    -- （三十四轮 F1：AV\/索引器独占、扫描窗口内被挪走）**的名字。该名整体
    -- 退出六态分类（两侧都排除，否则另一侧会伪报 NEW\/MISSING），状态
    -- 未知 → 退出码非零，fail-closed。
  , vrSrcMeta :: Map FilePath Entry
    -- ^ 源名 → Entry（size\/mtime\/sha，push 计划的执行前提；读取不稳的
    -- 文件不在此表 → 不可入计划）
  , vrHeld :: [(FilePath, Text)]
    -- ^ 第九态（P4-7）：用户决定「暂不同步」且**当时那张还是这张**（sha 相符）
    -- 的 NEW。仍留在 'vdNew' 里（六态集合是对外契约），但 'newActive' 会把它们
    -- 排除、退出码不再报"有事可做"。
  , vrHeldStale :: [(FilePath, String)]
    -- ^ 决定已失效（字节变了 → 回到 NEW；或已不在 NEW → 可 unhold 清掉）。
  }

-- | 源侧某个名字**本轮真实**的 sha：空缓存调 'shaViaCache' → 必走重读 +
-- 双 stat；'Nothing' = 本轮读取不稳定。
--
-- 决定的**创建**与**复核**都只准用它：'vrSrcMeta' / `srcShas` 里的 sha 可能
-- 来自主库 catalog 的 (size,mtime) 命中，等长替换 + 还原 mtime 时那是**陈旧
-- 值**——二十一轮据此指出复核会失真，二十二轮进一步指出创建同样会：hold 会
-- 记下旧 sha，下一轮复核立刻把它判成失效，决定根本落不住。
freshShaAt :: FilePath -> FilePath -> IO (Maybe Text)
freshShaAt srcDir n = do
  -- 本轮扫描之后、这次重读之前文件可能已被删/被独占（二十三轮 minor）：
  -- 按"本轮不稳定"处理即可——决定不会写下、既有决定按失效回到 NEW，
  -- 而不是让 CLI 抛异常退出、API 变 500。
  r <- try (shaViaCache Map.empty ("相册" </> n) (srcDir </> n)) :: IO (Either IOException (Text, Maybe Entry))
  pure $ case r of
    Left _ -> Nothing
    Right (sha, me) -> sha <$ me

-- | 'freshShaAt' 的报告层包装（源目录取自报告）。
freshSrcSha :: VaultReport -> FilePath -> IO (Maybe Text)
freshSrcSha r = freshShaAt (vrSrcDir r)

-- | 真正"待处理"的 NEW：扣掉已决定暂不同步的（P4-7）。
newActive :: VaultReport -> [FilePath]
newActive r = [n | n <- vdNew (vrDiff r), n `notElem` map fst (vrHeld r)]

-- | 退出码语义（legacy :237）：duplicate 与 unpushable 不算差异；NEW 用
-- 'newActive'——用户已经决定暂不同步的照片不该让 `pm vault status` 永远
-- exit 1。这是**唯一**的"不能报 0"谓词：曾经并存的 'hasDiff'（按整个 vdNew
-- 判）已删除——两个同构谓词并存正是调用点用错的温床，codex 二十一轮就抓到
-- `runVaultPush` 的无项分支还在用旧的那个。
--
-- 三十五轮 F1（同一无项分支的第二次同型故障）：unstable **算**——状态未知
-- 不能报「已同步」（评审 #5 的有意偏离，规范 §6 修复项 9）。这一项此前手写
-- 在 status 的调用点（`hasDiffR r || not (null …)`），push 的无项分支没抄到
-- ——只有 UNSTABLE 时 push 返回 0，自动化调用方把读失败当成功。退出码语义
-- 折进唯一谓词本身，调用点不再各拼各的。
hasDiffR :: VaultReport -> Bool
hasDiffR r =
  let d = vrDiff r
   in not (null (newActive r) && null (vdMissing d) && null (vdRenamed d) && null (vdDrift d) && null (vrUnstable r))

-- | Left (消息, 退出码)。quiet 抑制告警行（--json 输出面要纯净）。
computeVault :: Bool -> Config -> IO (Either (String, Int) VaultReport)
computeVault quiet cfg = case cfgVaultPath cfg of
  Nothing ->
    pure (Left ("配置无 vault 路径 → pm init --main <主库> --vault <展示集路径>（或手动补 config.toml 的 [vault] path）", 2))
  Just vaultDir -> do
    -- P3b-6 复审 B1：相册源与 vault-cache 都以「主库」身份读写 cfgMainPath，
    -- 指向备份/vault root 时不得放行。
    em <- requireMain cfg
    either (\msg -> pure (Left (msg, 2))) (\_ -> computeVault' quiet cfg vaultDir) em

-- | 'computeVault' 主体（主库身份已验）。
computeVault' :: Bool -> Config -> FilePath -> IO (Either (String, Int) VaultReport)
computeVault' quiet cfg vaultDir = do
    let root = cfgMainPath cfg
        srcDir = root </> "相册"
    okSrc <- doesDirectoryExist srcDir
    okVault <- doesDirectoryExist vaultDir
    case (okSrc, okVault) of
      (False, _) -> pure (Left ("ERROR: source missing: " <> srcDir, 2))
      (_, False) -> pure (Left ("ERROR: vault missing: " <> vaultDir, 2))
      _ -> do
        -- 评审 #4：缓存身份绑定。展示/JSON 仍用配置原样路径（legacy 兼容
        -- 面）；身份比对用规范路径 + vault root UUID。
        vaultCanon <- canonicalizePath vaultDir
        mVRoot <- readRootInfo vaultDir
        lc <- loadCatalog root
        eMeta <- readVaultCacheMeta root
        eVCache <- readVaultCacheCatalog root
        -- P3b-15（十二轮）：缓存失信 → 弃用内容全量重算（保守），但失信原因
        -- 必须报出来，不静默。
        let warn s = unless quiet (putStrLn s)
            dropLeft :: Either String (Maybe a) -> IO (Maybe a)
            dropLeft (Left m) = warn ("⚠ vault 缓存不可信，弃用重算: " <> m) >> pure Nothing
            dropLeft (Right x) = pure x
        mMeta <- dropLeft eMeta
        mVCache <- dropLeft eVCache
        -- 工作流 A 簇：主库索引读不出时相册 sha 全量重算——可以，但要说
        forM_ [() | CatRefused _ <- [lc]] $ \() -> warn ("⚠ 主库" <> loadNote lc <> "，相册 sha 全量重算")
        -- P3b-5 复审 #4：双方 root-id 都必须存在且相等才复用（Nothing==Nothing
        -- 不算身份）；路径比较用 canonicalizePath 的精确输出（它已按盘上
        -- 真实大小写解析，不再无条件小写化）。vault root 建立前每次全量重 hash。
        let cacheIdentityOk = case (mMeta, mVRoot) of
              (Just m, Just vr) -> vmVaultPath m == vaultCanon && vmRootId m == Just (riId vr)
              _ -> False
            mainCache = maybe Map.empty catEntries (fst (catalogMaybe lc))
            vaultCache =
              if cacheIdentityOk then maybe Map.empty catEntries mVCache else Map.empty
            -- 三十四轮 F1（本轮 minset）：枚举-hash 主循环与 'freshShaAt' 同款
            -- fail-closed——读口 IOException（AV/索引器短暂独占、分钟级扫描窗口
            -- 内文件被 Lightroom/用户挪走）落 unstable 桶单列报告（sha 分量在
            -- 下游处处被 Just 模式滤掉，空值安全），不再逃顶让 CLI 崩、API 500
            -- ——那正是 'freshShaAt' 注释里点名要避免的两个后果，二十三轮只修
            -- 了那一个调用点，主循环漏扫。
            resolve cache rel abs' n = do
              r <- try (shaViaCache cache rel abs') :: IO (Either IOException (Text, Maybe Entry))
              pure $ case r of
                Left _ -> (n, "", Nothing)
                Right (sha, me) -> (n, sha, me)
        eSrcList <- listFlatPhotos srcDir
        eVaultTop <- listFlatPhotos vaultDir
        eCatLists <-
          forM fixedCategories $ \cat ->
            fmap ((,) cat) <$> listFlatPhotos (vaultDir </> cat)
        case (eSrcList, eVaultTop, [e | Left e <- eCatLists]) of
          (Left e, _, _) -> pure (Left ("ERROR: " <> e, 2))
          (_, Left e, _) -> pure (Left ("ERROR: " <> e, 2))
          (_, _, e : _) -> pure (Left ("ERROR: " <> e, 2))
          (Right (srcNames, srcSubdirs), Right (_, vaultTop), []) -> do
            let catLists = [cl | Right cl <- eCatLists]
            srcTriples <- mapM (\n -> resolve mainCache ("相册" </> n) (srcDir </> n) n) srcNames
            let knownAux = ["_inbox", "_site", "scripts"]
                unknownDirs =
                  [ dn
                  | dn <- vaultTop
                  , dn `notElem` fixedCategories
                  , dn `notElem` knownAux
                  , take 1 dn /= "."
                  ]
            perCat <- forM catLists $ \(cat, (names, subdirs)) -> do
              mapM_ (\dn -> warn ("  ⚠ vault 类目下有子目录（不递归）: " <> (cat </> dn))) subdirs
              ps <- mapM (\n -> resolve vaultCache (cat </> n) (vaultDir </> cat </> n) n) names
              pure (cat, ps)
            mapM_ (\dn -> warn ("  ⚠ vault 未知目录（未纳入比对）: " <> dn)) unknownDirs
            mapM_ (\dn -> warn ("  ⚠ 相册下有子目录（平铺语义，不递归）: " <> dn)) srcSubdirs
            -- 评审 #5：任一侧读取不稳的名字整体退出六态分类（只排一侧会让
            -- 另一侧伪报 NEW/MISSING）；单列报告 + 退出码非零。
            let unstable =
                  [(n, "相册") | (n, _, Nothing) <- srcTriples]
                    <> [(n, cat) | (cat, ps) <- perCat, (n, _, Nothing) <- ps]
                badNames = map fst unstable
                srcShas = Map.fromList [(n, sha) | (n, sha, _) <- srcTriples, n `notElem` badNames]
                vaultShas =
                  [ (cat, Map.fromList [(n, sha) | (n, sha, _) <- ps, n `notElem` badNames])
                  | (cat, ps) <- perCat
                  ]
                d = vaultDiff srcShas vaultShas
                vaultCount = sum [Map.size m | (_, m) <- vaultShas]
                -- 第一方自审工作流 F069：与 push 写路径的闸（'checkAssignments' 的
                -- 'pushableExt'）同一谓词。此前各写一份（@".png"@ 字面量 vs 白名单），
                -- 只因两边都先经 'photoExtFold' 预筛才碰巧相等。
                unpushableExt n = not (pushableExt n)
                unpushable =
                  [(n, "相册") | n <- srcNames, unpushableExt n]
                    <> [(n, cat) | (cat, ps) <- perCat, (n, _, _) <- ps, unpushableExt n]
            mapM_
              (\(n, loc) -> warn ("  ⚠ 读取不稳定（本轮退出六态分类，fail-closed）: " <> loc </> n))
              unstable
            now <- getCurrentTime
            eholds <- readHolds root
            case eholds of
              Left e -> pure (Left (e, 2))
              Right holds -> do
                -- 决定的复核**不吃 (size,mtime) 缓存快路**：等长替换 + 还原 mtime
                -- 时 'shaViaCache' 会复用缓存 sha，旧决定就继续压住新字节
                -- （codex 二十一轮 major）。空缓存 → 一定走真实重读 + 双 stat。
                -- 只对「名单里且仍是 NEW」的文件做，数量 = 用户决定不同步的张数。
                freshHeld <-
                  mapM
                    (\n -> (,) n <$> freshShaAt srcDir n)
                    [vhName h | h <- holds, vhName h `elem` vdNew d]
                let freshMap = Map.fromList freshHeld
                    (held, heldStale) = splitHeld holds (vdNew d) (\n -> maybe Nothing id (Map.lookup n freshMap))
                    vEntries = [e | (_, ps) <- perCat, (_, _, Just e) <- ps]
                    meta =
                      VaultCacheMeta
                        { vmAt = now
                        , vmVaultPath = vaultCanon
                        , vmRootId = riId <$> mVRoot
                        , vmOk = length (vdOk d)
                        , vmNew = length (vdNew d)
                        , vmMissing = length (vdMissing d)
                        , vmRenamed = length (vdRenamed d)
                        , vmDrift = length (vdDrift d)
                        , vmDuplicate = length (vdDuplicate d)
                        , vmUnpushable = length unpushable
                        , vmUnstable = length unstable
                        , vmHeld = length held
                        }
                -- 缓存目录不可信（junction 化）是硬失败：继续下去等于把 pm 的写
                -- 交给库外（P3b-13 十轮 critical）。锁被占则只是缓存本轮不刷新
                -- （三十一轮 F1；vault-holds 事务在锁内走到这里就是这种情形），
                -- 报告本身是本轮新算的，不受影响。
                wc <- writeVaultCache root (Catalog "vault-cache" now (entryMap vEntries)) meta
                case wc of
                  CacheRefused e -> pure (Left (e, 2))
                  _ ->
                    pure . Right $
                      VaultReport
                        { vrSrcDir = srcDir
                        , vrVaultDir = vaultDir
                        , vrSrcCount = Map.size srcShas
                        , vrVaultCount = vaultCount
                        , vrDiff = d
                        , vrUnpushable = unpushable
                        , vrUnstable = unstable
                        , vrSrcMeta = Map.fromList [(n, e) | (n, _, Just e) <- srcTriples]
                        , vrHeld = held
                        , vrHeldStale = heldStale
                        }

-- ─── pm vault status [--json] ───────────────────────────────────────────────

-- | 退出码与 legacy 同构：0 同步 \/ 1 有差异（duplicate、unpushable 不算；
-- unstable **算**——语义在 'hasDiffR' 里，status 与 push 的无项分支共用同
-- 一谓词，三十五轮 F1 起不再各拼各的）\/ 2 路径错误。
runVaultStatus :: Bool -> Config -> IO Int
runVaultStatus asJson cfg = do
  er <- computeVault asJson cfg
  case er of
    Left (msg, code) -> putStrLn msg >> pure code
    Right r -> do
      if asJson
        then BSLC.putStrLn (renderVaultJson (vrSrcDir r) (vrVaultDir r) (vrSrcCount r) (vrVaultCount r) (vrDiff r) (vrUnpushable r) (vrUnstable r) (vrHeld r) (vrHeldStale r))
        else renderHuman r
      pure (if hasDiffR r then 1 else 0)

renderHuman :: VaultReport -> IO ()
renderHuman r = do
  let d = vrDiff r
      unpushable = vrUnpushable r
  printf "vault 差异 · 相册 %s (%d) ↔ %s (%d)\n" (vrSrcDir r) (vrSrcCount r) (vrVaultDir r) (vrVaultCount r)
  printf
    "  OK %d · NEW %d · MISSING %d · RENAME %d · DRIFT %d · DUPLICATE %d · UNPUSHABLE %d · UNSTABLE %d\n"
    (length (vdOk d))
    (length (vdNew d))
    (length (vdMissing d))
    (length (vdRenamed d))
    (length (vdDrift d))
    (length (vdDuplicate d))
    (length unpushable)
    (length (vrUnstable r))
  unless (null (vrHeld r)) $
    printf "  （其中 %d 张已决定暂不同步，不计入待办；pm vault unhold <文件…> 可恢复）\n" (length (vrHeld r))
  mapM_ (\n -> putStrLn ("  + NEW " <> n <> "  → pm vault push --category <类目> " <> n)) (newActive r)
  mapM_ (\(n, _) -> putStrLn ("  ⏸ HELD " <> n <> "（暂不同步；pm vault unhold " <> n <> " 恢复）")) (vrHeld r)
  mapM_ (\(n, why) -> putStrLn ("  ⏵ HELD 失效 " <> n <> "：" <> why)) (vrHeldStale r)
  mapM_ (\(n, c) -> putStrLn ("  - MISSING " <> c </> n <> "  → 决定保留还是撤（只报告）")) (vdMissing d)
  mapM_
    ( \(n, m, c, h) ->
        putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "' (" <> T.unpack (T.take 16 h) <> ")")
    )
    (vdRenamed d)
  mapM_
    ( \(n, c, sh, vh) ->
        putStrLn
          ("  ~ DRIFT " <> c </> n <> " (src " <> T.unpack (T.take 16 sh) <> " ≠ vault " <> T.unpack (T.take 16 vh) <> ") → pm vault push 生成裁决计划")
    )
    (vdDrift d)
  mapM_ (\(n, cats) -> putStrLn ("  ! DUPLICATE " <> n <> " → " <> unwords cats)) (vdDuplicate d)
  mapM_
    (\(n, loc) -> putStrLn ("  ✋ UNPUSHABLE " <> loc </> n <> "（.png：status 可见，push 写路径拒收）"))
    unpushable
  mapM_
    (\(n, loc) -> putStrLn ("  ⚠ UNSTABLE " <> loc </> n <> "（读取期间持续变化，已退出六态分类；稍后重跑）"))
    (vrUnstable r)

-- ─── pm vault push（§10.2） ─────────────────────────────────────────────────

-- | I11 守卫 + vault root 建立（幂等）。守卫核心 'vaultIgnoreGuard' 在
-- 'Pm.GitGuard'（内核级：Exec 执行期按 role 无条件重检，此处建 root 前先检）。
ensureVaultRoot :: FilePath -> IO (Either String RootInfo)
ensureVaultRoot vaultDir = do
  g <- vaultIgnoreGuard vaultDir
  case g of
    Left msg -> pure (Left msg)
    Right () -> do
      -- P3b-7 复审 major：损坏的标识不当缺席处理（不改写）；首次创建走原子
      -- no-replace（createRootInfo）。
      st <- readRootState vaultDir
      case st of
        RootPresent info
          | riRole info == RoleVault -> pure (Right info)
          | otherwise ->
              pure (Left ("该路径已是 " <> show (riRole info) <> " root，拒绝作为 vault root"))
        RootCorrupt e ->
          pure (Left (vaultDir <> " 的 .pm/root-id.json 存在但无法解析（" <> e <> "），拒绝改写——人工核查"))
        -- P3b-12（九轮复审 major）：建立身份的入口天然走不了 requireWritable，
        -- .pm 是 junction 时会在库外建 root-id.json。闸在 readRootState 里。
        RootUntrusted m -> pure (Left m)
        RootAbsent -> do
          rid <- freshRootId
          now <- getCurrentTime
          fs <- case vaultDir of
            (c : _) -> volumeFsType c
            _ -> pure Nothing
          let info = RootInfo rid RoleVault now fs
          er <- createRootInfo vaultDir info
          case er of
            Left m -> pure (Left m)
            Right () -> do
              putStrLn ("✓ vault root 标识已创建: " <> T.unpack rid)
              pure (Right info)

-- | push 收尾要打印的显式 git 步骤（纯函数；I9：pm 自己绝不执行）。
--
-- 第一方自审 R2：文本由 'Pm.Publish.vaultCommands' 生成——与「复制上线命令」
-- 同一生成点，push 目标取自设置、路径解析后重渲染、操作数前 @--@。此前这里
-- 是第二个生成器：硬打不加引号的 @cd@ 与 @git push origin main@，P7 加了可配
-- 的 push 目标它却不知道。生成不了（路径嵌不进命令）就把原因说出来，让用户
-- 手动做；三个消费点（CLI push 收尾、API push-plan 响应、ingest 收尾）共用。
gitStepsLines :: Config -> FilePath -> Text -> [String] -> [String]
gitStepsLines cfg vaultDir pid cats =
  "→ vault 侧 git 收尾（pm 不执行 git；显式类目，明确禁止 git add -A / git add .）："
    : case vaultCommands cfg vaultDir (sort (nub cats)) ("photos: pm vault push " <> T.unpack pid) of
      Right ls -> map ("    " <>) ls
      Left why ->
        [ "    （无法安全生成命令：" <> why <> "）"
        , "    请在 " <> vaultDir <> " 里手动：git add <类目…> → git commit → git push"
        ]

-- | 计划涉及的 vault 类目（= 各 Copy dst 的第一层目录）——**生成期的预告**
-- （serve 的 push-plan 响应把它渲染成「执行后的 git 步骤」）。待裁决项不入列：
-- 裁决前它落不了位（工作流 F029）。
planCategories :: Plan -> [String]
planCategories plan = categoriesOf [piOp it | it <- plItems plan, not (needsDecision (piStatus it))]
 where
  needsDecision (StNeedsDecision _) = True
  needsDecision _ = False

-- | **落位项**的 vault 类目——收尾 git 步骤 @git add@ 的显式对象（工作流
-- F029/F068：与 'planCategories' 同一取法，但按执行结果而不是计划面）。
resultCategories :: [(PlanItem, ItemOutcome)] -> [String]
resultCategories rs = categoriesOf (map piOp (landedItems rs))

categoriesOf :: [Op] -> [String]
categoriesOf ops = filter (/= "") (nub [topOf (opDstRel op) | op <- ops, isCopy op])
 where
  topOf p = case splitDirectories p of (x : _) -> x; [] -> ""
  isCopy OpCopy {} = True
  isCopy _ = False -- Quarantine 的 trash 路径与 Rename 不进 git add

-- | photos.json 只读引用检查（§10.2 RENAME 策略）：vault 文件名出现在
-- photos.json 的哪一行（它以完整 Pages URL 引用）。
--
-- 三十四轮 F1 同族：photos.json 在另一个仓、可能正被编辑器/同步进程占住，
-- BS.readFile 抛出会让整个 push 崩掉；而读不出也**不得**答「未被引用」——
-- 那是 fail-open，会诱导用户改名打断已上线 URL。读失败 = Left，调用方按
-- 「可能被引用」报告（fail-closed）。
-- 第一方自审 R1：存在性探测也三态化——@doesFileExist@ 把 ACL 拒绝塌成「不存
-- 在」，正是上一段说的那个 fail-open 口子的另一半（三十四轮只堵了读取那半）。
photosJsonRef :: Maybe FilePath -> FilePath -> IO (Either String (Maybe Int))
photosJsonRef Nothing _ = pure (Right Nothing)
photosJsonRef (Just fp) name = do
  r <- whenPresent fp (BS.readFile fp)
  pure $ case r of
    Left e -> Left e
    Right Nothing -> Right Nothing
    Right (Just raw) ->
      let ls = zip [1 :: Int ..] (T.lines (TE.decodeUtf8Lenient raw))
       in Right (case [i | (i, l) <- ls, T.pack name `T.isInfixOf` l] of i : _ -> Just i; [] -> Nothing)

-- | `pm vault push [--category C FILES...]`：
-- NEW×已定类目 → Copy 计划项；DRIFT → NEEDS-DECISION（pm resolve --keep src
-- 走 §6.5 supersede，旧字节进 vault root 的 .pm\/trash\/）；RENAME\/MISSING
-- 只报告（RENAME 带 photos.json BLOCKED 检查）。写路径只收 jpg\/jpeg。
runVaultPush :: (Plan -> IO PlanRun) -> Maybe String -> [FilePath] -> Config -> IO Int
runVaultPush runPlan mCat files cfg = do
  er <- computeVault False cfg
  case er of
    Left (msg, code) -> putStrLn msg >> pure code
    Right r -> do
      let d = vrDiff r
      -- 选择校验（fail-closed：任何一条不合法就不出计划）
      let sel = case (mCat, files) of
            (Just c, fs@(_ : _)) -> Right [(c, f) | f <- fs]
            (Nothing, []) -> Right []
            (Just _, []) -> Left ["--category 需要同时给出要推送的文件名（pm vault push --category landscape A.jpg …）"]
            (Nothing, _ : _) -> Left ["给了文件却没给 --category（CLI 无法看图分类；或用 pm ui，P4）"]
      case sel of
        Left errs -> mapM_ putStrLn errs >> pure 2
        Right pairs' -> do
          let errs = checkAssignments r pairs'
          if not (null errs)
            then mapM_ (putStrLn . ("  ✗ " <>)) errs >> pure 2
            else do
              -- 报告面：RENAME（photos.json 引用检查）与 MISSING 只报告
              forM_ (vdRenamed d) $ \(n, m, c, _) -> do
                eref <- photosJsonRef (cfgPhotosJson cfg) m
                case eref of
                  Left e ->
                    putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "' → photos.json 读取失败（" <> e <> "）：无法核对引用，按可能被引用处理（fail-closed），只报告")
                  Right (Just line) ->
                    putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "' → BLOCKED(photos.json:" <> show line <> ")：改名会打断已上线 URL，只报告")
                  Right Nothing ->
                    putStrLn ("  🔁 RENAME 源 '" <> n <> "' ≡ vault '" <> c </> m <> "'（未被 photos.json 引用；改名功能后续增量，暂只报告）")
              forM_ (vdMissing d) $ \(n, c) ->
                putStrLn ("  - MISSING " <> c </> n <> "（可能有意撤下，决定权在用户，只报告）")
              -- 计划面：选中的 NEW + 全部 DRIFT
              let allItems = vaultPushItems r pairs'
              if null allItems
                then do
                  unless (null (newActive r)) $ do
                    putStrLn ("  → " <> show (length (newActive r)) <> " 个 NEW 待分类：pm vault push --category <类目> <文件…>（类目: " <> unwords fixedCategories <> "）")
                  putStrLn "（无可执行项，未生成计划）"
                  pure (if hasDiffR r then 1 else 0)
                else do
                  eplan <- mkVaultPushPlan r allItems
                  case eplan of
                    Left msg -> putStrLn msg >> pure 2
                    Right plan -> do
                      -- 第一方自审工作流 F068：收尾按逐项结果判（'landedItems'），
                      -- 不按退出码 0——全部待裁决的一跑退出码也是 0，却一个字节
                      -- 没落；add 清单取自落位项。退出码换算不变（'planRunCode'）。
                      pr <- runPlan plan
                      case pr of
                        PrRun _ rs
                          | not (null (landedItems rs)) ->
                              mapM_ putStrLn (gitStepsLines cfg (vrVaultDir r) (plId plan) (resultCategories rs))
                        _ -> pure ()
                      pure (planRunCode pr)

-- ─── vault push 的计划构造（CLI 与 `pm serve` 的 POST /api/vault/push-plan 共用，P4-5） ──

-- | 逐条校验「类目, NEW 文件名」指派（fail-closed：任何一条不合法就不出计划）。
-- 返回全部错误而不是第一条，GUI 能一次把问题都标出来。
checkAssignments :: VaultReport -> [(String, FilePath)] -> [String]
checkAssignments r pairs' = dupErrs <> [e | p <- pairs', Just e <- [checkSel p]]
 where
  d = vrDiff r
  heldNames = map fst (vrHeld r)
  -- 同一 name 被指派两次（跨类目或同类目重复）：逐条校验各自合法，但计划会
  -- 带两个 Copy，执行后同一张照片重复入 vault（codex 二十轮 minor）。按 name
  -- 分组 fail-closed；CLI（`pm vault push a.jpg a.jpg`）与 API 共用这一处。
  dupErrs =
    [ f <> " 被重复指派（" <> unwords (sort (nub cs)) <> "）：一个文件只能出现一次、只能进一个类目"
    | (f, cs) <- Map.toList (Map.fromListWith (<>) [(f, [c]) | (c, f) <- pairs'])
    , length cs > 1
    ]
  checkSel (c, f)
    | f `elem` map fst (vrUnstable r) = Just (f <> " 本轮读取不稳定（已退出六态分类，fail-closed），稍后重试")
    | c `notElem` fixedCategories = Just ("类目不存在: " <> c <> "（可选: " <> unwords fixedCategories <> "）")
    | f `notElem` vdNew d = Just (f <> " 不在 NEW 集合里（只有 NEW 可 push；看 pm vault status）")
    | f `elem` heldNames = Just (f <> " 已决定暂不同步 → 先 pm vault unhold " <> f <> "（或在 GUI 里改成一个类目）")
    | not (pushableExt f) = Just (f <> " 是 UNPUSHABLE（写路径只收 jpg/jpeg）")
    | not (Map.member f (vrSrcMeta r)) = Just (f <> " 读取不稳定，本轮不可入计划（稍后重试）")
    | otherwise = Nothing

-- | 计划项：选中的 NEW（Pending）+ 全部 DRIFT（NEEDS-DECISION）。调用方须先过
-- 'checkAssignments'。
vaultPushItems :: VaultReport -> [(String, FilePath)] -> [(Op, ItemStatus)]
vaultPushItems r pairs' = newItems <> driftItems
 where
  newItems =
    [ (OpCopy (vrSrcDir r </> f) (c </> f) (enSha e) (enSize e) (enMtimeNs e), StPending)
    | (c, f) <- pairs'
    , Just e <- [Map.lookup f (vrSrcMeta r)]
    ]
  driftItems =
    [ ( OpCopy (vrSrcDir r </> n) (c </> n) (enSha e) (enSize e) (enMtimeNs e)
      , StNeedsDecision "DRIFT：相册是上游真相 → pm resolve <计划> --item N --keep src（旧字节先入 vault .pm/trash）或 --keep dst 保留现状"
      )
    | (n, c, _, _) <- vdDrift (vrDiff r)
    , Just e <- [Map.lookup n (vrSrcMeta r)]
    ]

-- | 建 vault root 身份（幂等，含 I11 守卫）并组装计划——**不落盘**；落盘由
-- 调用方经 'savePlan'（CLI 的 savePlanAndMaybeRun / API 的 push-plan 端点）。
mkVaultPushPlan :: VaultReport -> [(Op, ItemStatus)] -> IO (Either String Plan)
mkVaultPushPlan r allItems = do
  einfo <- ensureVaultRoot (vrVaultDir r)
  case einfo of
    Left msg -> pure (Left msg)
    Right info -> do
      pid <- newPlanId
      now <- getCurrentTime
      pure . Right $
        Plan
          { plId = pid
          , plKind = "vault-push"
          , plRootPath = vrVaultDir r
          , plRootId = Just (riId info)
          , plCreated = now
          , plItems = [PlanItem i op st Nothing | (i, (op, st)) <- zip [0 ..] allItems]
          }
