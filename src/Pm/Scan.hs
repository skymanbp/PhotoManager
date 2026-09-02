-- | Incremental scanner (DESIGN.md §4 Scan.hs): walk the tree, reuse catalog
-- entries whose (size, mtime) are unchanged, hash the rest with a worker
-- pool, and mark files that changed while being hashed as volatile instead of
-- indexing a possibly-torn hash (§6.7).
module Pm.Scan
  ( ScanOpts (..)
  , ScanResult (..)
  , StatEntry (..)
  , scanRoot
  , listTree
  , listTreeWith
  , listTreeCov
  , DotDirs (..)
  , freshnessSweep
  , freshPending
  , sweepCounts
  , uncoveredKeys
  , coversKey
  , maxPathLen
  , reparseSkipNote
  ) where

import Control.Concurrent.Async (replicateConcurrently_)
import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.IORef
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (pathSeparator, takeExtension, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import Text.Printf (printf)

import Pm.Hash
import Pm.Types
import Pm.Win (NameKind (..), probeName)

-- | Full-path length guard (DESIGN.md §14 长路径预检): refuse early and
-- loudly instead of corrupting behaviour near MAX_PATH.
maxPathLen :: Int
maxPathLen = 240

-- | 遍历对 symlink\/reparse point 的**设计内**跳过——进错误表只是为了逐条交代
-- （SortGuardTests 钉住这一条），不是失败。'Pm.Sort.hardErrors' 按它排除后才
-- 折进退出码（第一方自审工作流 F054）；字面量只在这里定义一次。
reparseSkipNote :: String
reparseSkipNote = "symlink/reparse point skipped"

data ScanOpts = ScanOpts
  { soWorkers :: Int
  , soProgress :: Bool
  }

data StatEntry = StatEntry
  { seRel :: FilePath
  , seSnap :: StatSnap
  }

data ScanResult = ScanResult
  { srCatalog :: Catalog
  , srReused :: Int
  , srHashed :: Int
  , srHashedBytes :: Integer
  , srVolatile :: [FilePath]
  , srErrors :: [(FilePath, String)]
  , srCarried :: Int
    -- ^ 落在本轮**未枚举**子树里、按「查不出」原样保留的旧条目数
    -- （第一方自审工作流 F040：此前它们从快照里消失并落盘）
  }

-- | 遍历时对**点开头的目录**的策略。
--
-- 这不是一个可以有默认值的细节，两种用法要的语义相反：
--
--  * 'SkipDotDirs' —— 库根。@.pm@ @.git@ @.obsidian@ 是元数据，不是照片，跳过
--    是对的，而且**不必报告**（每次扫描都报一遍纯属噪音）。
--  * 'WalkDotDirs' —— @pm sort@ 的源。那是**用户随手指的一个目录**（相机卡、
--    下载文件夹），里面点开头的目录只是普通文件夹，完全可能装着照片。
--
-- 把库根的策略原样搬到源目录上，结果是 @card\\.hidden\\a.ARW@ 连一条记录都不
-- 留地消失——既不进计划，也不进任何一格「交代」（codex 二十六轮 #3）。
data DotDirs = SkipDotDirs | WalkDotDirs
  deriving (Show, Eq)

-- | Relative paths of all regular files under root, with the library-root
-- policy ('SkipDotDirs'). Symlinks/reparse points are skipped and over-long
-- paths are reported as errors, not silently dropped.
listTree :: FilePath -> IO ([FilePath], [(FilePath, String)])
listTree = listTreeWith SkipDotDirs

listTreeWith :: DotDirs -> FilePath -> IO ([FilePath], [(FilePath, String)])
listTreeWith dots root = (\(fs, es, _) -> (fs, es)) <$> listTreeCov dots root

-- | 同上，另带**未枚举覆盖**（第一方自审工作流 F039/F040）：哪些子树根本没
-- 走进去——目录列举失败、链接属性查不出。键是 root 相对路径，**空路径 =
-- 整棵树**（基准自身列不出）；错误表里的 @.@ 只是展示键。确定性的跳过（真
-- 链接、超长路径、pm 状态目录）不在其中：那是「知道它不该进索引」，不是
-- 「查不出」。此前「没枚举到」在类型上没有表示，两个消费方各自换算、各错
-- 一处：'freshnessSweep' 拿文件前缀器换算，@.@ 换不成覆盖全树的空键（基准
-- 列不出 → 整份 catalog 报「消失」）；'scanRoot' 压根不看，未枚举子树的条目
-- 从快照里消失、无条件落盘、三代轮转把完整快照顶掉。
listTreeCov :: DotDirs -> FilePath -> IO ([FilePath], [(FilePath, String)], [FilePath])
listTreeCov dots root = go ""
 where
  go rel = do
    let dirAbs = if null rel then root else root </> rel
        here = if null rel then "." else rel
    -- 列举失败（介质被拔、ACL、目录在遍历途中消失）必须变成一条**带路径的
    -- 错误**，而不是让异常穿出整条命令。源是可移动介质时这是常态而非异常：
    -- 异常逃出去，用户只看到一条堆栈，既不知道哪个目录出的问题，也拿不到
    -- 已经扫到的部分（codex 二十六轮 #4）。
    --
    -- 这里**不需要**额外强制列表：@listDirectory@ 的异常发生在
    -- @getDirectoryContents@ 执行期（IO 内部），不是消费列表时，@try@ 兜得住。
    -- 本轮一度加过一个 @length ns \`seq\`@ 并声称"惰性值逃出 try"——那个结论
    -- 来自一次读到**旧库**的探针（当时 pm.exe 在跑，@copy/register@ 失败，
    -- 探针跑的是加 try 之前的代码）。重新构建后有无该 seq 结果完全相同
    -- （@files=[] errs=["."]@），突变也证明它不承重，已删除：**没有依据的
    -- 防御性代码加上一条假注释，比不加更糟**。
    er <- try (listDirectory dirAbs) :: IO (Either IOException [FilePath])
    case er of
      Left e -> pure ([], [(here, "目录列举失败: " <> show e)], [rel])
      Right names -> do
        results <- forM names $ \name -> do
          let relPath = if null rel then name else rel </> name
              abs' = root </> relPath
          if length abs' >= maxPathLen
            then pure ([], [(relPath, "path too long (>=240 chars)")], [])
            else do
              symRes <- try (pathIsSymbolicLink abs') :: IO (Either IOException Bool)
              -- 三十七轮（GO 后按 quality-over-cost 收口）：探测异常（非「不存
              -- 在」）按「是链接」处理——同 Trash.linkish / Exec.slotOccupied
              -- 的既有纪律。旧写法塌成 False 的辩解（「真实错误会在下面的 stat
              -- 再现」）只对普通文件成立：junction 的属性读瞬时失败后，递归会
              -- **顺利**跟着链接下去，错误永不再现，库外文件被当库内条目索引。
              -- 「不存在」（条目在遍历窗口内消失）仍走 stat 路径，在那里响亮
              -- 入错。异常类型同步收窄 SomeException→IOException（Ctrl-C 不吞）。
              case symRes of
                Left e
                  | not (isDoesNotExistError e) ->
                      pure ([], [(relPath, "链接属性查不出（" <> show e <> "），按链接跳过、不递归")], [relPath])
                _ -> do
                  let isSym = either (const False) id symRes
                  if isSym
                    then pure ([], [(relPath, reparseSkipNote)], [])
                    else do
                      isDir <- doesDirectoryExist abs'
                      if isDir
                        then case dots of
                          -- 'WalkDotDirs' 的唯一例外：pm 自己的状态目录。源恰好是
                          -- 一个 pm 库根时，@.pm\\tmp@ 里是**半写入**的临时文件、
                          -- @.pm\\trash@ 里是已隔离的文件——它们头部有合法 EXIF，
                          -- 会被当成待归位的照片拷走（codex 二十七轮 #3）。
                          --
                          -- 判据是**内容**不是名字（codex 二十八轮 #3）：目录里有
                          -- @root-id.json@ 才是 pm 状态目录——这正是 pm 自己认 root
                          -- 的方式。按名字判两个方向都错：卡上一个普通的、名叫
                          -- @.pm@ 的用户目录会被整个跳过（里面的照片一格都不进）；
                          -- 而真状态目录被改名或经别名到达时判据根本不触发。
                          -- 探针三态（第一方自审工作流 F041，R1 同类）：文件级 ACL
                          -- 拒绝会让 doesFileExist 塌 False → 走进 .pm\\trash 把隔离
                          -- 件当照片；'probeName' 对 ACL 免疫，查不出 = 不进入。
                          WalkDotDirs -> do
                            k <- probeName (abs' </> "root-id.json")
                            case k of
                              NameMissing -> go relPath
                              ProbeUnknown -> pure ([], [(relPath, "root-id.json 存在性查不出（ACL/介质错误？），按 pm 状态目录处理、不进入")], [relPath])
                              _ -> pure ([], [(relPath, "pm 状态目录（内含 root-id.json），源遍历不进入")], [])
                          SkipDotDirs
                            | take 1 (takeFileName name) == "." -> pure ([], [], [])
                            | otherwise -> go relPath
                        else pure ([relPath], [], [])
        pure (concatMap (\(a, _, _) -> a) results, concatMap (\(_, b, _) -> b) results, concatMap (\(_, _, c) -> c) results)

-- | Stat-only freshness comparison of a directory tree against a catalog
-- slice keyed by root-relative paths. @relPrefix@ narrows the walk to one
-- subtree (\"\" = whole root); the catalog slice must be pre-filtered to the
-- same subtree by the caller. Returns (new, changed, gone, readErrors).
-- Shared by pm status（全库核对）与 import/clean 的暂存区守卫。
freshnessSweep :: FilePath -> FilePath -> Map.Map FilePath Entry -> IO (Int, Int, Int, Int)
freshnessSweep root relPrefix catSlice = do
  let base = if null relPrefix then root else root </> relPrefix
  -- 基准目录三态（39 轮 #1）：此前 doesDirectoryExist 二态——目录被拒时塌
  -- False，整棵树按「没有文件」算：catalog 空则全零（stagingFresh 放行，
  -- fail-open），非空则整批误报「消失」。probeName 探不出（ACL/介质错误）
  -- 时按一条覆盖全树的遍历错误处理；真 ENOENT 保持现状语义（条目确实消失）。
  k <- probeName base
  let walkBase = do
        isDir <- doesDirectoryExist base
        if isDir
          then listTree base
          else pure ([], [("", "基准不是目录（或目录性查不出），树核不了")])
  (files, errs) <- case k of
    NamePlain -> walkBase
    -- 工作流 F042：root **自身**是 junction 是合法用法（'Pm.Win.resolveUnder'
    -- 的文档一直这么写，句柄守卫用例也钉着「root 经 junction 判是」）——只有
    -- 库内子层的 surrogate 才是越界形态，那由遍历层「不跟随 + 登记」处理；
    -- relPrefix 非空（暂存区守卫等子树核对）时保持拒绝。
    NameSurrogate | null relPrefix -> walkBase
    NameMissing -> pure ([], [])
    _ -> pure ([], [("", "基准目录探不出（" <> show k <> "），树核不了")])
  snaps <- forM files $ \rel -> do
    r <- try (statSnap (base </> rel)) :: IO (Either IOException StatSnap)
    pure (uncoveredKey relPrefix rel, r)
  pure (sweepCounts snaps (uncoveredKeys relPrefix errs) catSlice)

-- | 遍历错误表 → 调用方键空间里的**覆盖键**（第一方自审工作流 F039）：基准
-- 自身出错（展示键 @.@，或探针分支的空键）覆盖整个 @relPrefix@ 子树（全库
-- 核对时即空路径 = 整棵树）；子树错误按 rel 前缀换算。此前换算器是给文件
-- rel 写的，@.@ 原样留下，三个覆盖判别一个都不命中——基准列不出时整份
-- catalog 报「消失」。这是唯一的换算点。
uncoveredKeys :: FilePath -> [(FilePath, String)] -> [FilePath]
uncoveredKeys relPrefix = map (uncoveredKey relPrefix . fst)

uncoveredKey :: FilePath -> FilePath -> FilePath
uncoveredKey relPrefix rel
  | rel == "." || null rel = relPrefix
  | null relPrefix = rel
  | otherwise = relPrefix </> rel

-- | 键 @k@ 是否落在某个未枚举子树里（空路径 = 整棵树；前缀按路径分量对齐）。
-- 'sweepCounts' 与 'scanRoot' 共用这一个定义。
coversKey :: [FilePath] -> FilePath -> Bool
coversKey uncovered k = any (\p -> null p || p == k || (p <> [pathSeparator]) `isPrefixOf` k) uncovered

-- | 'freshnessSweep' 的纯分类核心（拆出顶层穷测——同 'classifyGitProbe' 的
-- 先例：注入形态难做时，把判定做成纯函数钉死）。出错的路径（stat 失败，或
-- 遍历层就没走进去——目录列举失败、链接属性查不出被跳过）是「查不出」，
-- fail-closed 的去向是**错误数**而不是消失：三十九轮（P7）前 Left 直接从
-- disk 集合掉出去——NEW 文件 stat 失败即隐身（暂存区守卫照样放行），
-- catalog 内文件 stat 失败被误报「消失」，而错误数只数遍历错。「消失」
-- 要求确认不在盘上；出错的文件只是核不了，因此从 gone 剔除，只走错误口
-- ——两类调用方（stagingFresh 按 errN 拒绝、pm status 依它出「一致」结论）
-- 由此都拿到真话。
sweepCounts :: [(FilePath, Either IOException StatSnap)] -> [FilePath] -> Map.Map FilePath Entry -> (Int, Int, Int, Int)
sweepCounts snaps walkErrPaths catSlice = (newN, changedN, goneN, errN)
 where
  disk = Map.fromList [(rel, s) | (rel, Right s) <- snaps]
  statFails = Set.fromList [rel | (rel, Left _) <- snaps]
  -- 遍历错误按**子树**覆盖（39 轮 #1）：目录 @sub@ 列举失败时，catalog 里
  -- @sub\a.jpg@ 同样核不了——只按精确键剔除会让后代条目被误报「消失」且与
  -- 该目录的错误双重计数。空路径 = 基准自身出错，覆盖整棵树（'coversKey'）。
  newN = Map.size (disk `Map.difference` catSlice)
  goneN =
    Map.size
      (Map.filterWithKey (\k _ -> not (coversKey walkErrPaths k)) (Map.withoutKeys (catSlice `Map.difference` disk) statFails))
  changedN =
    length
      [ ()
      | (rel, s) <- Map.toList disk
      , Just e <- [Map.lookup rel catSlice]
      , enSize e /= ssSize s || enMtimeNs e /= ssMtimeNs s
      ]
  errN = length walkErrPaths + Set.size statFails

scanRoot :: ScanOpts -> Maybe Catalog -> Text -> FilePath -> IO ScanResult
scanRoot opts oldCat rootId root = do
  (files, walkErrs, uncovered) <- listTreeCov SkipDotDirs root
  -- Stat pass
  statNow <- getCurrentTime
  statted <- forM files $ \rel -> do
    r <- try (statSnap (root </> rel)) :: IO (Either IOException StatSnap)
    pure (rel, r)
  let stats = [StatEntry rel s | (rel, Right s) <- statted]
      statErrs = [(rel, show e) | (rel, Left e) <- statted]
      oldEntries = maybe Map.empty catEntries oldCat
      (reused, toHash) = foldl' split ([], []) stats
      -- P3b-4 评审 #4（统一修）：复用判据走 statHitStable——(size,mtime)
      -- 相等之外还排除 racy 条目（hash 时刻与 mtime 同刻度窗口内；未来
      -- mtime 的窗口尚未到来，同样可信），与 Pm.Vault.shaViaCache 共用同一谓词。
      split (rs, hs) se@(StatEntry rel snap) =
        case Map.lookup rel oldEntries of
          Just e
            | statHitStable statNow (enSize e) (enMtimeNs e) (enLastVerified e) snap ->
                (e : rs, hs)
          _ -> (rs, se : hs)
      totalHashBytes = sum [ssSize (seSnap se) | se <- toHash]
  progress
    ( printf
        "扫描 %s: %d 文件, 复用 %d, 待 hash %d (%.1f GiB), workers=%d"
        root
        (length files)
        (length reused)
        (length toHash)
        (gib totalHashBytes)
        (soWorkers opts)
    )
  -- Hash pass (worker pool over a shared queue)
  queue <- newIORef toHash
  done <- newIORef (0 :: Int, 0 :: Integer)
  out <- newIORef ([] :: [Entry], [] :: [FilePath], [] :: [(FilePath, String)])
  let pop = atomicModifyIORef' queue $ \q -> case q of
        [] -> ([], Nothing)
        (x : xs) -> (xs, Just x)
      worker = do
        item <- pop
        case item of
          Nothing -> pure ()
          Just (StatEntry rel preSnap) -> do
            -- 三十九轮（P7 类清扫）：SomeException→IOException。宽口在这里
            -- 最有害：worker 捕获后**继续循环取队列**，异步取消（ThreadKilled/
            -- UserInterrupt）会被洗成一条「读文件错误」而 worker 照跑不误——
            -- 正是 Hash.hs「只捕 IOException」家规要防的形态。
            r <- try (hashOne rel preSnap) :: IO (Either IOException (Either FilePath Entry))
            atomicModifyIORef' out $ \(es, vs, errs) -> case r of
              Right (Right e) -> ((e : es, vs, errs), ())
              Right (Left v) -> ((es, v : vs, errs), ())
              Left ex -> ((es, vs, (rel, show ex) : errs), ())
            case r of
              Right (Right e) -> bump (enSize e)
              _ -> bump 0
            worker
      hashOne rel preSnap = do
        let abs' = root </> rel
        sha <- sha256File abs'
        post <- statSnap abs'
        if post /= preSnap
          then pure (Left rel) -- changed while hashing → volatile, not indexed
          else do
            vnow <- getCurrentTime
            pure
              ( Right
                  Entry
                    { enPath = rel
                    , enSize = ssSize post
                    , enMtimeNs = ssMtimeNs post
                    , enSha = sha
                    , enKind = classifyExt (takeExtension rel)
                    , enLastVerified = Just vnow
                    }
              )
      bump bytes = do
        (n, b) <- atomicModifyIORef' done $ \(n, b) ->
          let s = (n + 1, b + bytes) in (s, s)
        progressWhen (n `mod` 200 == 0) (printf "  … %d/%d 已 hash (%.1f GiB)" n (length toHash) (gib b))
  replicateConcurrently_ (max 1 (soWorkers opts)) worker
  (newEntries, volatiles, hashErrs) <- readIORef out
  now <- getCurrentTime
  -- 未枚举子树里的旧条目是「查不出」不是「不存在」（第一方自审工作流 F040）：
  -- 原样保留上次快照值，而不是让它们从快照消失、随即无条件落盘、三代轮转把
  -- 完整快照顶掉——与 'freshnessSweep' 对同一情形的处置（错误口，不算消失）
  -- 同一纪律。本轮真枚举到的条目（reused/newEntries）左优先。
  let unknown = Map.filterWithKey (\k _ -> coversKey uncovered k) oldEntries
      entries = entryMap (reused <> newEntries) `Map.union` unknown
  pure
    ScanResult
      { srCatalog = Catalog rootId now entries
      , srReused = length reused
      , srHashed = length newEntries
      , srHashedBytes = sum (map enSize newEntries)
      , srVolatile = volatiles
      , srErrors = walkErrs <> statErrs <> hashErrs
      , srCarried = Map.size unknown
      }
 where
  progress msg = progressWhen True msg
  progressWhen cond msg
    | soProgress opts && cond = hPutStrLn stderr msg
    | otherwise = pure ()

gib :: Integer -> Double
gib b = fromIntegral b / (1024 * 1024 * 1024)

-- | 新鲜度四元组折成「未决数」：任何一位非零都算未决——第四位读取错误也在内
-- （核对受阻 ≠ 一致）。status 的退出码与渲染、import\/clean\/sort 的暂存区
-- 闸、backup 的主库闸共用这一个定义（工作流 F047：此前四处各写一遍求和，
-- 口径一旦分叉，「✓ 一致」与退出码会对同一状态给出两个答案）。
freshPending :: (Int, Int, Int, Int) -> Int
freshPending (n, c, m, e) = n + c + m + e
