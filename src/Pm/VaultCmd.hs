{-# LANGUAGE OverloadedStrings #-}

-- | vault 的**决定层**命令（与 'Pm.BackupCmd' 同款拆分：'Pm.Vault' 触及 750
-- 行预算）。这里不生成计划、不碰照片，只改主库 @.pm@ 里的两份本地记录：
-- 「暂不同步」名单（P4-7，'Pm.VaultHold'）与照片记录（P8-C，'Pm.VaultNote'）。
--
-- 三层共用，CLI 与 `pm serve` 的写端点走的是同一套：事务壳 'withVaultTxn'
-- （预检 → root lock → 锁内 computeVault → 读记录）、IO 层 'holdOpsIO' \/
-- 'noteOpsIO'（本轮真实 sha）、纯校验 'holdRequest' \/ 'noteRequest'。
module Pm.VaultCmd
  ( withVaultTxn
  , holdRequest
  , holdOpsIO
  , runVaultHold
  , NoteArgs (..)
  , NoteStatus (..)
  , noteRequest
  , noteOpsIO
  , noteStatuses
  , renderNotesJson
  , runVaultNote
  , runVaultNotes
  ) where

import Control.Monad (unless)
import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, getCurrentTime)
import System.FilePath ((</>))

import Pm.Config (Config (..), requireMain)
import Pm.Lock (withRootLock)
import Pm.Vault (VaultDiff (..), VaultReport (..), computeVault, freshSrcSha, photosJsonRef)
import Pm.VaultCore (pushableExt)
import Pm.VaultHold (VaultHold (..), applyHoldOps, isFlatName, readHolds, writeHolds)
import Pm.VaultNote (NoteFields (..), VaultNote (..), applyNoteOps, hasFields, noteFieldErrors, noteObject, normalizeFields, readNotes, renderFields, writeNotes)

-- | 记录的「读 → 校验 → 写」必须是**一个跨进程事务**（I10）：两个 pm（CLI 与
-- GUI 的 serve，或两个 serve）各自读到同一份旧记录、各自写出全量结果，后写者
-- 会整份覆盖先写者的决定——丢更新（codex 二十一轮 major）。serve 的进程内
-- MVar 挡不住这个，必须是主库的 @.pm/lock@。
--
-- **取锁前先做零写入的身份预检**（'requireMain'）：'withRootLock' 会创建
-- @.pm@ 并打开 @.pm/lock@，匿名 root 或 I11 失效的 root 若先取锁再校验，就会
-- 在被拒绝之前先落下一个 @.pm/lock@（codex 二十二轮 major）。同 'Pm.Exec' 的
-- 「取锁前预检、锁内复检」次序：锁内 'computeVault' 仍会再过一次 'requireMain'。
--
-- 锁被占用时不排队：直接告知调用方（同 `pm apply` 口径），退出码 4。
-- @reader@ 是哪份记录（'readHolds' \/ 'readNotes'）——壳只有这一处。
withVaultTxn ::
  Config ->
  (FilePath -> IO (Either String [a])) ->
  ([a] -> VaultReport -> IO (Either (String, Int) b)) ->
  IO (Either (String, Int) b)
withVaultTxn cfg reader act = do
  let root = cfgMainPath cfg
  pre <- requireMain cfg
  case pre of
    Left m -> pure (Left (m, 2))
    Right _ -> do
      m <- withRootLock root $ do
        er <- computeVault True cfg
        case er of
          Left e -> pure (Left e)
          Right r -> do
            eh <- reader root
            case eh of
              Left msg -> pure (Left (msg, 2))
              Right olds -> act olds r
      pure (maybe (Left ("另一个 pm 正在写主库（.pm/lock 被占用）——稍后重试", 4)) id m)

-- | CLI 决定命令的共用壳：事务 → 算新记录（全部错误一次列完）→ 写 → 收尾。
-- 身份闸四道叠加：取锁前 'requireMain' 预检、root lock（I10）、锁内
-- 'computeVault' 的 'requireMain' 复检、写入口的 'Pm.Config.requireWritable'（I11）。
-- 锁忙（4）对 CLI 折成 2。
runDecisionCli ::
  Config ->
  (FilePath -> IO (Either String [a])) ->
  ([a] -> VaultReport -> IO (Either [String] [a])) ->
  (FilePath -> [a] -> IO (Either String ())) ->
  ([a] -> IO ()) ->
  IO Int
runDecisionCli cfg reader ops writer done = do
  res <- withVaultTxn cfg reader $ \olds r -> do
    eops <- ops olds r
    case eops of
      Left errs -> pure (Left (unlines (map ("  ✗ " <>) errs), 2))
      Right kept -> do
        w <- writer (cfgMainPath cfg) kept
        pure $ case w of
          Left m -> Left (m, 2)
          Right () -> Right kept
  case res of
    Left (msg, code) -> putStr (ensureNl msg) >> pure (if code == 4 then 2 else code)
    Right kept -> done kept >> pure 0
 where
  ensureNl s = if null s || last s == '\n' then s else s <> "\n"

-- ─── 暂不同步（P4-7） ────────────────────────────────────────────────────────

-- | 校验一组「标记 / 撤销」并算出新名单。fail-closed：任一条不合法就整体
-- 不写，并把**全部**错误一次返回（GUI 能一次标完）。
--
-- @freshHold@ 是本轮**真实重算**的 (名字, sha)——由 'holdOpsIO' 取；'Nothing'
-- 表示本轮读不稳定。纯函数不碰 IO，便于单测。
holdRequest ::
  VaultReport ->
  [VaultHold] ->
  [(FilePath, Maybe Text)] ->
  [FilePath] ->
  UTCTime ->
  Either [String] [VaultHold]
holdRequest r olds freshHold toUnhold now
  | not (null errs) = Left errs
  | otherwise = Right (applyHoldOps olds adds dels)
 where
  hs = map fst freshHold
  us = nub toUnhold
  errs =
    ["没有给文件名：hold 与 unhold 都是空的" | null hs && null us]
      <> ["同一文件不能同时标记与撤销：" <> n | n <- hs, n `elem` us]
      <> [ n <> " 不在 NEW 集合里（只有 NEW 需要决定同不同步；看 pm vault status）"
         | n <- hs
         , n `notElem` vdNew (vrDiff r)
         ]
      <> [ n <> " 本轮读取不稳定，记不下决定时的 sha，稍后重试"
         | (n, Nothing) <- freshHold
         , n `elem` vdNew (vrDiff r)
         ]
      <> [n <> " 不在暂不同步名单里" | n <- us, n `notElem` map vhName olds]
  adds = [VaultHold n sha now Nothing | (n, Just sha) <- freshHold]
  dels = us

-- | 'holdRequest' 的 IO 外壳：把要标记的名字**本轮真实**重 hash 一遍再交给
-- 纯校验。决定里存的 sha 只能来自这里——从 'vrSrcMeta' 取等于把主库 catalog
-- 的缓存值写进决定（二十二轮 major）。CLI 与 API 共用。
holdOpsIO ::
  VaultReport ->
  [VaultHold] ->
  [FilePath] ->
  [FilePath] ->
  IO (Either [String] [VaultHold])
holdOpsIO r olds toHold toUnhold = do
  fresh <- mapM (\n -> (,) n <$> freshShaOrSkip n) (nub toHold)
  now <- getCurrentTime
  pure (holdRequest r olds fresh toUnhold now)
 where
  -- 不在 NEW 的名字不必读盘：纯校验会先把它拒掉，报错更准也不做无谓 IO。
  freshShaOrSkip n
    | n `notElem` vdNew (vrDiff r) = pure Nothing
    | otherwise = freshSrcSha r n

-- | `pm vault hold|unhold <文件…>`。**只**写主库 @.pm/vault-holds.json@：
-- vault 仓与照片字节零改动，因此不走两段式计划——这是一条随时可改的本地
-- 决定，撤销就是 @pm vault unhold@。
runVaultHold :: Bool -> [FilePath] -> Config -> IO Int
runVaultHold hold files cfg =
  runDecisionCli cfg readHolds (\olds r -> holdOpsIO r olds hs us) writeHolds $ \kept -> do
    putStrLn
      ( (if hold then "⏸ 已标记暂不同步 " else "▶ 已恢复待同步 ")
          <> show (length (nub files))
          <> " 张（名单现共 "
          <> show (length kept)
          <> " 条）："
          <> unwords (nub files)
      )
    putStrLn "  照片与 vault 仓零改动——这只是主库 .pm 里的一条本地决定，随时可改。"
 where
  (hs, us) = if hold then (files, []) else ([], files)

-- ─── 照片记录（P8-C，DESIGN-P8 §21） ────────────────────────────────────────

-- | 校验一组「记录 / 清除」并算出新记录集。fail-closed，全部错误一次返回。
-- @sets@ 里的 sha 是本轮**真实重读**（'noteOpsIO'），'Nothing' = 读不稳定。
-- 记录只对**相册里的 jpg** 有意义（NEW、HELD、已推送的都可以——记录跟着照片，
-- 不跟着六态）。
noteRequest ::
  VaultReport ->
  [VaultNote] ->
  [(FilePath, Maybe Text, NoteFields)] ->
  [FilePath] ->
  UTCTime ->
  Either [String] [VaultNote]
noteRequest r olds sets clears now
  | not (null errs) = Left errs
  | otherwise = Right (applyNoteOps olds adds (nub clears))
 where
  names = [n | (n, _, _) <- sets]
  present n = Map.member n (vrSrcMeta r) || n `elem` map fst (vrUnstable r)
  errs =
    ["没有给文件名：set 与 clear 都是空的" | null sets && null clears]
      <> ["同一文件不能同时记录与清除：" <> n | n <- names, n `elem` clears]
      <> ["同一文件在本次请求里出现多次：" <> n | n <- nub names, length (filter (== n) names) > 1]
      <> [n <> " 不是平铺文件名（记录以相册里的文件名为键）" | n <- nub (names <> clears), not (isFlatName n)]
      <> [n <> " 不在相册里（记录只对相册照片有意义；看 pm vault status）" | n <- names, isFlatName n, not (present n)]
      <> [n <> " 不是 jpg（push 写路径拒收，记录无处可去）" | n <- names, present n, not (pushableExt n)]
      <> [n <> " 本轮读取不稳定，记不下记录时的 sha，稍后重试" | (n, Nothing, _) <- sets, present n, pushableExt n]
      <> [n <> " 字段非法: " <> e | (n, _, f) <- sets, e <- noteFieldErrors f]
      <> [n <> " 没有记录可清除" | n <- nub clears, n `notElem` map vnName olds]
  adds = [VaultNote n sha f now | (n, Just sha, f) <- sets]

-- | 'noteRequest' 的 IO 外壳：字段规范化 + 本轮真实 sha（同 'holdOpsIO' 的理由：
-- 'vrSrcMeta' 里的 sha 可能是 (size,mtime) 命中的陈旧缓存值）。CLI 与 API 共用。
noteOpsIO ::
  VaultReport ->
  [VaultNote] ->
  [(FilePath, NoteFields)] ->
  [FilePath] ->
  IO (Either [String] [VaultNote])
noteOpsIO r olds sets clears = do
  fresh <- mapM (\(n, f) -> (\s -> (n, s, normalizeFields f)) <$> freshOrSkip n) sets
  now <- getCurrentTime
  pure (noteRequest r olds fresh clears now)
 where
  freshOrSkip n
    | Map.member n (vrSrcMeta r) && pushableExt n = freshSrcSha r n
    | otherwise = pure Nothing

-- | 一条记录的发布状态（DESIGN-P8 §21.2）：@unsynced@ 还在 NEW/HELD；@pending@
-- 已在 vault 类目而 photos.json 未引用（技能的消费面）；@published@ photos.json
-- 引用到了（行号）；@stale@ 字节已变 \/ 已不在相册 \/ 读不稳定；@unknown@
-- photos.json 读不出——不能答 pending（技能会再渲染一条，重复上线），fail-closed。
data NoteStatus = NoteStatus
  { nsLabel :: Text
  , nsCategory :: Maybe String
  , nsLine :: Maybe Int
  , nsWhy :: Maybe String
  }
  deriving (Show, Eq)

needsAttention :: NoteStatus -> Bool
needsAttention s = nsLabel s `elem` ["stale", "unknown"]

-- | 每条记录本轮真实重读一次 sha（'freshSrcSha'，与 hold 的复核同一纪律），
-- 已在 vault 的再**只读**反查 photos.json（'photosJsonRef'）。
noteStatuses :: Config -> VaultReport -> [VaultNote] -> IO [(VaultNote, NoteStatus)]
noteStatuses cfg r = mapM one
 where
  d = vrDiff r
  vaultCat n = case [c | (m, c) <- vdOk d, m == n] <> [c | (m, c, _, _) <- vdDrift d, m == n] of
    c : _ -> Just c
    [] -> Nothing
  renamedTo n = [c </> m | (s, m, c, _) <- vdRenamed d, s == n]
  stale w = NoteStatus "stale" Nothing Nothing (Just w)
  one note = do
    let n = vnName note
    st <-
      if n `elem` map fst (vrUnstable r)
        then pure (stale "本轮读取不稳定（文件正在变动）→ 稍后重跑")
        else
          if not (Map.member n (vrSrcMeta r))
            then pure (stale "已不在相册（可能改名或删除）→ pm vault note --clear 清掉这条")
            else do
              fresh <- freshSrcSha r n
              case fresh of
                Nothing -> pure (stale "本轮读取不稳定（文件正在变动）→ 稍后重跑")
                Just s
                  | s /= vnSha note -> pure (stale "内容已变（不再是记录时那张）→ 重新确认后再记一次")
                  | otherwise -> case vaultCat n of
                      Nothing ->
                        pure
                          ( NoteStatus "unsynced" Nothing Nothing $ case renamedTo n of
                              x : _ -> Just ("vault 里同内容为另一名字 " <> x <> "（RENAME）")
                              [] -> Nothing
                          )
                      Just c -> do
                        eref <- photosJsonRef (cfgPhotosJson cfg) n
                        pure $ case eref of
                          Left e -> NoteStatus "unknown" (Just c) Nothing (Just ("photos.json 读取失败（" <> e <> "）：无法核对引用，按未知处理（fail-closed）"))
                          Right (Just line) -> NoteStatus "published" (Just c) (Just line) Nothing
                          Right Nothing ->
                            NoteStatus "pending" (Just c) Nothing $
                              if cfgPhotosJson cfg == Nothing then Just "未配置 photos.json，无法核对引用" else Nothing
    pure (note, st)

-- | @notes --json@ 与 @GET /api/vault/notes@ 同一渲染：每条 = 记录键 + status /
-- vault_category / photos_json_line / why。
renderNotesJson :: [(VaultNote, NoteStatus)] -> Value
renderNotesJson xs =
  object
    [ "notes" .= map one xs
    , "count" .= length xs
    , "attention" .= length (filter (needsAttention . snd) xs)
    ]
 where
  one (n, s) =
    object (noteObject n <> ["status" .= nsLabel s, "vault_category" .= nsCategory s, "photos_json_line" .= nsLine s, "why" .= nsWhy s])

-- | `pm vault note` 的参数：@--clear FILES…@ 或 @FILE + 字段@。
data NoteArgs = NoteArgs
  { naClear :: Bool
  , naFiles :: [FilePath]
  , naFields :: NoteFields
  }

-- | `pm vault note <文件> [--category C] [--location L] [--coordinates "lat, lng"]
-- [--title T] [--source S]` \/ `pm vault note --clear <文件…>`。**只**写主库
-- @.pm/vault-notes.json@；vault 仓与照片零改动。
runVaultNote :: NoteArgs -> Config -> IO Int
runVaultNote a cfg
  | naClear a && hasFields (normalizeFields (naFields a)) = refuse "--clear 不接受字段（只给文件名）"
  | naClear a && null (naFiles a) = refuse "--clear 需要至少一个文件名"
  | naClear a =
      runDecisionCli cfg readNotes (\olds r -> noteOpsIO r olds [] (naFiles a)) writeNotes $ \kept ->
        putStrLn ("🗒 已清除 " <> show (length (nub (naFiles a))) <> " 条照片记录（现共 " <> show (length kept) <> " 条）")
  | [f] <- naFiles a =
      runDecisionCli cfg readNotes (\olds r -> noteOpsIO r olds [(f, naFields a)] []) writeNotes $ \kept -> do
        putStrLn ("🗒 已记录 " <> f <> "：" <> renderFields (normalizeFields (naFields a)) <> "（现共 " <> show (length kept) <> " 条）")
        putStrLn "  照片与 vault 仓零改动——这只是主库 .pm 里的一条本地记录；/photo-publish 读 pm vault notes --json 写 photos.json。"
  | otherwise = refuse "pm vault note 一次记一张：给且只给一个文件名（清除多张用 --clear）"
 where
  refuse m = putStrLn ("  ✗ " <> m) >> pure 2

-- | `pm vault notes [--json]`：列出记录与发布状态（只读）。退出码：有
-- stale \/ unknown 要人看一眼 → 1；否则 0；路径 \/ 身份错误 → 2。
runVaultNotes :: Bool -> Config -> IO Int
runVaultNotes asJson cfg = do
  er <- computeVault asJson cfg
  case er of
    Left (msg, code) -> putStrLn msg >> pure code
    Right r -> do
      en <- readNotes (cfgMainPath cfg)
      case en of
        Left m -> putStrLn m >> pure 2
        Right notes -> do
          xs <- noteStatuses cfg r notes
          if asJson
            then BSLC.putStrLn (Aeson.encode (renderNotesJson xs))
            else do
              putStrLn ("🗒 照片记录 " <> show (length xs) <> " 条" <> summary xs)
              mapM_ line xs
              unless (null xs) $
                putStrLn "  pending = 已在 vault 类目、photos.json 未引用 → /photo-publish 消费；stale / unknown 需要你看一眼"
          pure (if any (needsAttention . snd) xs then 1 else 0)
 where
  labels = ["unsynced", "pending", "published", "stale", "unknown"] :: [Text]
  summary xs
    | null xs = ""
    | otherwise = "（" <> intercalate " · " [T.unpack l <> " " <> show k | l <- labels, let k = length [() | (_, s) <- xs, nsLabel s == l], k > 0] <> "）"
  line (n, s) = do
    putStrLn
      ( "  " <> pad (T.unpack (nsLabel s)) <> " " <> vnName n <> "  " <> renderFields (vnFields n)
          <> maybe "" (\c -> "  [vault/" <> c <> "]") (nsCategory s)
          <> maybe "" (\l -> "  photos.json:" <> show l) (nsLine s)
      )
    mapM_ (\w -> putStrLn ("      ↳ " <> w)) (nsWhy s)
  pad l = l <> replicate (9 - length l) ' '
