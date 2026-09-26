-- | @pm doctor --deep@：全库重读重 hash（'deepVerify'，2026-09-26 自 "Pm.Doctor" 搬出——750 行预算）与把核对
-- 无误的验证时间记回快照（'recordVerified'，横切审计 #67）。此前 --deep 只出发现行、一个字节都不回写，
-- DESIGN I3b 说的「lastVerified 随每次 hash 写进 catalog」唯独漏了这条唯一的全覆盖验证：状态页「最久未验证
-- 字节」深验多少次都只涨不降，分不清昨天刚核过的介质与从没回读过的介质。
module Pm.DoctorDeep
  ( Verified
  , deepVerify
  , recordVerified
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM, when)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime, getCurrentTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

import Pm.Catalog (CatalogLoad (..), loadCatalog, saveCatalog)
import Pm.Config (requireWritable)
import Pm.Finding
import Pm.Hash (StatSnap (..), sha256File, statSnap)
import Pm.Lock (withRootLock)
import Pm.Removable (DriveWait, ensureDrive, readOnDrive, withDriveRetry)
import Pm.Types

-- | 一条核对无误、可以记回的深验：路径、sha、读前 stat（读后与之相同）、读前时刻。
data Verified = Verified FilePath Text StatSnap UTCTime

deepVerify :: DriveWait -> FilePath -> Catalog -> IO ([Finding], [Verified])
deepVerify dw root cat = do
  results <- forM (Map.elems (catEntries cat)) $ \e -> do
    let abs' = root </> enPath e
    -- 1.1.2：盘不在时 doesFileExist 答 False——先等盘，否则掉线被报成「消失」
    ensureDrive dw root "深验"
    ex <- doesFileExist abs'
    if not ex
      then pure ([Finding "DEEP" Warn ("条目在盘上消失: " <> enPath e) "跑 pm scan 刷新索引"], [])
      else do
        -- 三十四轮（同型扫尽）：--deep 扫全库、窗口以分钟计，一个被占的
        -- 文件不该让整轮诊断崩掉；读失败也不得折叠成 CORRUPT（下一步不同：
        -- 稍后重跑 vs 核查介质）。1.1.2：读错先按瞬断判（盘不在等它回来、
        -- 再读这一条），确定性的读错与等不到盘才落成 Warn。
        -- 横切审计 #67：读前读后各取一次 stat、记下读前时刻——两次 stat 相同且 sha 相符，才算「这份字节在这一刻
        -- 核对过」（同 scan 的 hashOne：读的过程中被改的不算）；与快照记录的 (size, mtime) 是否一致，由
        -- 'recordVerified' 在锁内对着重读的快照判。
        actualE <- try (withDriveRetry dw root ("深验 " <> enPath e) (readBack abs')) :: IO (Either IOException (UTCTime, StatSnap, Text, StatSnap))
        pure $ case actualE of
          Left ioe ->
            ([Finding "DEEP" Warn ("条目读取失败（被占/介质？）: " <> enPath e <> "（" <> show ioe <> "）") "稍后重跑 pm doctor --deep"], [])
          Right (t0, pre, actual, post)
            | actual /= enSha e -> ([Finding "DEEP-CORRUPT" Bad ("内容与索引 sha 不符: " <> enPath e) "核查介质；如源仍在他处，重新拷贝"], [])
            | pre == post -> ([], [Verified (enPath e) actual pre t0])
            | otherwise -> ([], [])
  -- P7-S（0.6.1，端到端运行时测试的观测缺口）：干净库上 --deep 此前一个字都不多
  -- 打，用户分不清「深验跑了没发现」与「没跑」；Info 行汇报覆盖面，不改退出码。
  let fs = concatMap fst results
      nOf row sev = length [() | f <- fs, fRow f == row, fSeverity f == sev]
      total = Map.size (catEntries cat)
      unread = nOf "DEEP" Warn -- 消失/读不出：一个字节都没重读，不得算进「已重读」（48 轮）
  pure
    ( fs <> [Finding "DEEP-DONE" Info (show total <> " 条目待深验：已重读重 hash " <> show (total - unread) <> "、不符 " <> show (nOf "DEEP-CORRUPT" Bad) <> "、读取失败/消失 " <> show unread) ""]
    , concatMap snd results
    )
 where
  readBack abs' = do
    t0 <- getCurrentTime
    pre <- statSnap abs'
    sha <- sha256File abs'
    post <- statSnap abs'
    pure (t0, pre, sha, post)

-- | 横切审计 #67（用户裁定 2026-09-26「校验后写回」）：把 'deepVerify' 核对无误的条目的验证时间记回快照。锁内完整
-- RMW（同 apply 的 'Pm.Cli.writeBackCatalog'）：重读快照，路径、sha、(size, mtime) 与深验读前所见仍一致的才记，
-- 记**读前**时刻（最保守：'Pm.Hash.statHitStable' 的「hash 晚于 mtime 2 s」量的就是它），已有的更晚就不动。快照
-- 有告警（回退到了较旧一代）不回写——那会把旧一代抬成现行。root 不可写 / 锁被占 / 读写出错都明说没记上
-- （Warn），深验本身的结论不变。@held@ = 调用方已持有该 root 的锁（@--repair@ 那条路），不再重复取。
recordVerified :: DriveWait -> Bool -> FilePath -> [Verified] -> IO [Finding]
recordVerified _ _ _ [] = pure []
recordVerified dw held root vs = do
  w <- requireWritable root
  case w of
    Left m -> pure [miss ("root 不可写: " <> m)]
    Right _ -> do
      r <- try ((if held then fmap Just else withRootLock root) rmw) :: IO (Either IOException (Maybe (Either String Int)))
      pure $ case r of
        Left e -> [miss ("读写快照出错: " <> show e)]
        Right Nothing -> [miss "另一个 pm 实例正持有该 root 的锁"]
        Right (Just (Left why)) -> [miss why]
        Right (Just (Right n)) ->
          [Finding "DEEP-STAMP" Info ("核对无误的条目里 " <> show n <> " 条已把验证时间记回索引（pm status 的「最久未验证字节」据此刷新）") ""]
 where
  byPath = Map.fromList [(p, v) | v@(Verified p _ _ _) <- vs]
  rmw = do
    lc <- readOnDrive dw root "读索引（记深验时间）" (loadCatalog root)
    case lc of
      CatLoaded cat [] -> do
        let es = Map.map stamp (catEntries cat)
            n = length [() | (_, True) <- Map.elems es]
        when (n > 0) $ withDriveRetry dw root "写索引（记深验时间）" (saveCatalog root cat {catEntries = Map.map fst es})
        pure (Right n)
      CatLoaded _ ws -> pure (Left ("快照回退到了较旧一代（" <> intercalate "；" ws <> "）"))
      CatRefused ws -> pure (Left ("快照被拒（" <> intercalate "；" ws <> "）"))
      CatAbsent -> pure (Left "快照不见了")
  stamp e = case Map.lookup (enPath e) byPath of
    Just (Verified _ sha snap t0)
      | sha == enSha e && snap == StatSnap (enSize e) (enMtimeNs e) && maybe True (< t0) (enLastVerified e) ->
          (e {enLastVerified = Just t0}, True)
    _ -> (e, False)
  miss why =
    Finding "DEEP-STAMP" Warn ("深验核对无误，但验证时间没记回索引（" <> why <> "）——pm status 的「最久未验证字节」本轮不刷新") "稍后重跑 pm doctor --deep"
