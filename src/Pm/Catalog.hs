-- | Catalog snapshot persistence: atomic replace + real disk flush + 3-copy
-- rotation (DESIGN.md §3). The snapshot is pm-owned state, rebuildable by a
-- rescan — the rotation below is the one place outside @pm trash empty@ where
-- pm unlinks a file, and it only ever touches its own oldest snapshot copy,
-- never user data.
module Pm.Catalog
  ( CatalogLoad (..)
  , loadCatalog
  , catalogMaybe
  , catalogOr
  , loadNote
  , saveCatalog
  , catalogPath
  ) where

import Control.Exception (bracket)
import Control.Monad (foldM, when)
import Data.Aeson (eitherDecodeStrict', encode)
import Data.List (intercalate)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (hClose)

import Pm.Config (pmDir, readPmState, requirePmTrusted, resolvePmPath)
import Pm.Op (userRelOk)
import Pm.Types
import Pm.Win (deleteBoundAt, flushHandleToDisk, moveBoundNoReplace, openFreshBinary)

catalogPath :: FilePath -> FilePath
catalogPath root = pmDir root </> "catalog.json"

-- | 语义非法（手编痕迹）的哨兵后缀：'loadCatalog' 用它区分"可回退的损坏"与
-- "整条链不可信"。
tamperMark :: String
tamperMark = "，快照拒绝载入 → pm scan 重建"

-- | Newest readable copy wins: catalog.json, then .1, then .2.
--
-- 两类失败必须区别对待（P3b-11，八轮复审 #4）：
--
--  * **半写\/损坏 JSON**（进程被杀在写盘中途）是可回退的——正是三代轮转要
--    救的场景，继续试 @.1@、@.2@。
--  * **语义非法**（条目路径越界\/指向 @.pm@）不是介质事故，是有人手编过这份
--    快照。此时回退到旧代等于"攻击者提供的快照被拒了，于是换一份继续干活"
--    ——backup 忽略 load warnings 拿 @.1@ 算 diff（'Pm.BackupCmd'），会漏备
--    base 才有的新文件。整条链**就地终止**，返回 Nothing：调用点一律
--    fail-closed 到"先 pm scan 重建"。
--
-- 第一方自审工作流 A 簇：'readPmState' 给出的「缺席 / 读不出 / 有」三态此前
-- 在这里被压成 @Maybe@，差别只剩一个 @_@ 就能丢掉的 @[String]@——21 个调用点
-- 里 14 个正是这么丢的，于是「查不出」被当成「不存在」：doctor 沉默、backup
-- 打 ✓、apply 说「root 尚无索引」。现在类型上分开：'CatRefused' = 可信闸拒 /
-- 读不出 / 手编痕迹 / 三代全坏；'CatAbsent' 只在三代**都不存在**且零告警时；
-- 'CatLoaded' 带回退时跳过的坏代告警（不为空就是降级，退出码要认）。
data CatalogLoad = CatAbsent | CatRefused [String] | CatLoaded Catalog [String]

loadCatalog :: FilePath -> IO CatalogLoad
loadCatalog root = do
  -- P3b-13（十轮复审 major）：闸下沉到 loader。此前只在命令层加闸，于是
  -- pm status / pm versions / apply 的计划查找都在闸之前就读了 .pm。
  -- （十一轮更正：当时这里写"覆盖全部读入口"不实——侧缓存/trash 遍历/doctor
  -- 探测不经过 loader；P3b-14 的 'Pm.Config.readPmState' 才把状态文件读取
  -- 真正收成一个口，本函数的逐代读取也已改道走它。）
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure (CatRefused [m])
    Right () -> classify <$> loadCatalog' root
 where
  classify (Just c, ws) = CatLoaded c ws
  classify (Nothing, []) = CatAbsent
  classify (Nothing, ws) = CatRefused ws

-- | 折回旧的 @(Maybe, 告警)@ 形态——给**已经**按告警分支的调用点（scan 的种子、
-- status 的报告）与测试用；新代码按三态分支。
catalogMaybe :: CatalogLoad -> (Maybe Catalog, [String])
catalogMaybe CatAbsent = (Nothing, [])
catalogMaybe (CatRefused ws) = (Nothing, ws)
catalogMaybe (CatLoaded c ws) = (Just c, ws)

-- | 命令层的常用折法：缺席与拒绝都是 Left，但**理由不同**——「尚未索引 →
-- 先 pm scan」与「索引读不出（原因）」不能是同一句话。
catalogOr :: String -> CatalogLoad -> Either String (Catalog, [String])
catalogOr absentMsg CatAbsent = Left absentMsg
catalogOr _ (CatRefused ws) = Left ("索引读不出（" <> intercalate "；" ws <> "）—— 排除原因后重试，或 pm scan 重建")
catalogOr _ (CatLoaded c ws) = Right (c, ws)

-- | 一句话交代载入结果（给「因此跳过了某件事」的告警行用）。
loadNote :: CatalogLoad -> String
loadNote CatAbsent = "尚无索引"
loadNote (CatRefused ws) = "索引读不出: " <> intercalate "；" ws
loadNote (CatLoaded _ _) = "索引已载入"

loadCatalog' :: FilePath -> IO (Maybe Catalog, [String])
loadCatalog' root = foldM step (Nothing, []) ["catalog.json", "catalog.json.1", "catalog.json.2"]
 where
  step acc@(Just _, _) _ = pure acc
  -- 语义非法已经终止过一次 → 后续代次不再尝试（哨兵：warns 末尾是拒绝理由）
  step acc@(Nothing, warns) rel
    | any (tamperMark `isSuffixOfStr`) warns = pure acc
    | otherwise = do
        let fp = pmDir root </> rel
        -- P3b-14（十一轮复审 major，探针实证）：此前是 doesFileExist + 按名字
        -- decode。hardlink 不是 reparse point，可信闸看不见它——实测把
        -- catalog.json 预置成库外文件的 hardlink 后，这里**零警告地载入了库外
        -- 快照**，而快照决定 backup/import 会去读写哪些文件。改走受信取用口：
        -- 完整路径 resolveUnder + 句柄 link count + 同一句柄读完。
        rd <- readPmState root rel
        case rd of
          Left m -> pure (Nothing, warns <> [m <> tamperMark])
          Right Nothing -> pure (Nothing, warns)
          Right (Just bytes) -> case eitherDecodeStrict' bytes of
              -- P3b-10（七轮复审 major）：快照是可手编的 .pm 文件，而 enPath 会被拼成
              -- 绝对源路径喂给 backup/import 的 OpCopy（Pm.Diff/Pm.Import）并被 doctor
              -- --deep / clean 见证直接读取。P3b-11：校验从 relPathOk 收紧到
              -- userRelOk——".pm\journal.ndjson" 是完全合法的相对路径，却让
              -- opSrcAbs 指向 pm 自己的状态文件。真实库 4855 条目实测零违规。
              Right c
                | (bad : _) <- [enPath e | e <- Map.elems (catEntries c), not (userRelOk (enPath e))] ->
                    pure (Nothing, warns <> [fp <> ": 条目路径非法（" <> bad <> "）" <> tamperMark])
                | otherwise -> pure (Just (backfill c), warns)
              Left e -> pure (Nothing, warns <> [fp <> ": " <> e])
  isSuffixOfStr suf s = suf == drop (length s - length suf) s
  -- 旧快照的条目缺 lastVerified → 该 sha 正是那次扫描真实读盘算出的，
  -- 用快照时间作为验证基线。
  backfill c =
    c
      { catEntries =
          fmap
            (\e -> if enLastVerified e == Nothing then e {enLastVerified = Just (catScanned c)} else e)
            (catEntries c)
      }

saveCatalog :: FilePath -> Catalog -> IO ()
saveCatalog root cat = do
  createDirectoryIfMissing True (pmDir root)
  -- P3b-15（十二轮 critical）：轮转的四条路径在**使用点**逐条解析，操作只用
  -- 返回路径。此前 tmp/base/.1/.2 全按名字操作、本函数自身无任何解析——
  -- scan/backup 的「loadCatalog → 长扫描 → saveCatalog」序列里，扫描期间把
  -- @.pm@ 换成 junction，这里就会在**库外**建 tmp、删 @.2@、轮转 @.1@/base
  -- （removeFile 沿 junction 删库外文件是 Probe7 起的实测事实）。
  tmp <- resolvePmPath root "catalog.json.tmp"
  base <- resolvePmPath root "catalog.json"
  g1 <- resolvePmPath root "catalog.json.1"
  g2 <- resolvePmPath root "catalog.json.2"
  -- 独占创建（P3b-11，八轮复审 major）：固定名 + 截断写 = 预置 hardlink 就能
  -- 让这次写落到库外共享对象上（同 'Pm.Hash.copyFileHashed'）。
  bracket (openFreshBinary tmp) hClose $ \h -> do
    BSL.hPut h (encode cat)
    flushHandleToDisk h
  -- Rotate: keep 3 generations. Oldest copy is discarded by design (snapshot
  -- is a cache; the journal is the durable layer).
  removeIfExists g2
  renameIfExists g1 g2
  renameIfExists base g1
  moveBoundNoReplace tmp base

removeIfExists :: FilePath -> IO ()
removeIfExists fp = do
  exists <- doesFileExist fp
  when exists (deleteBoundAt fp)

renameIfExists :: FilePath -> FilePath -> IO ()
renameIfExists src dst = do
  exists <- doesFileExist src
  when exists (moveBoundNoReplace src dst)
