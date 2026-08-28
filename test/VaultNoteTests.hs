{-# LANGUAGE OverloadedStrings #-}

-- | P8-C 照片记录（DESIGN-P8.md §21）用例：纯校验、CLI 生命周期（unsynced →
-- pending → published → stale → 清除）、创建取盘上真实 sha、跨进程事务与取锁
-- 前预检、serve 端点五道闸。夹具与 P4-7 hold 用例同一份（'TestUtil' 的
-- 'plantStaleCatalog' \/ 'withForeignLock'、'ServeTests' 的 'withVaultWritable'）。
module VaultNoteTests (vaultNoteTests) where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.List (isInfixOf)
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import Network.Wai.Test (assertStatus, runSession)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..))
import Pm.Serve (serveApp)
import Pm.Vault (computeVault, runVaultPush)
import Pm.VaultCmd (NoteArgs (..), NoteStatus (..), noteStatuses, runVaultNote, runVaultNotes)
import Pm.VaultNote (NoteFields (..), VaultNote (..), parseCoordinates, readNotes, validateNotes)
import ServeTests (arrLen, decodeBody, field, getReq, liftIO', mkEnv, postReq, tok, withVaultWritable)
import TestUtil (execNow, mkMain, mkVaultCfg, plantStaleCatalog, withForeignLock, writeF)

vaultNoteTests :: TestTree
vaultNoteTests =
  testGroup
    "P8-C vault notes（照片记录）"
    [ testCase "P8-C 纯校验：坐标格式/越界、source、控制符/超长、类目、无字段 → 拒；同名两条/带路径名/坏 sha → 拒；合法通过并按名排序" casePureValidation
    , testCase "P8-C 生命周期：note → unsynced；push 后 pending；photos.json 引用后 published；读不出 → unknown；字节换了 stale；重记刷新；--clear 清掉；照片与 vault 零改动" caseLifecycle
    , testCase "P8-C 创建取盘上真实 sha（陈旧 catalog 命中 stat 仍不吃缓存）：记录立即生效、不判 stale" caseCreateFreshSha
    , testCase "P8-C 跨进程事务：root lock 被占 → 拒绝且记录不被覆盖；取锁前预检：匿名主库零写入" caseTxnLock
    , testCase "P8-C serve GET/POST /api/vault/notes：只读 403 而 GET 仍可；坏坐标/非相册名/空请求 400 带 details；set 后 GET 列出 unsynced 且字段已规范化；clear 后 count 0" caseServeNotes
    ]

noFields :: NoteFields
noFields = NoteFields Nothing Nothing Nothing Nothing "user"

fullFields :: NoteFields
fullFields = NoteFields (Just "landscape") (Just "Hallstatt, AT") (Just "47.556533, 13.648033") Nothing "user"

-- | 某个名字本轮的发布状态（走与 CLI/API 同一 'noteStatuses'）。
statusOf :: Config -> FilePath -> IO (T.Text, Maybe String, Maybe Int)
statusOf cfg n = do
  er <- computeVault True cfg
  r <- either (\(m, _) -> assertFailure ("computeVault: " <> m)) pure er
  en <- readNotes (cfgMainPath cfg)
  notes <- either (\m -> assertFailure ("readNotes: " <> m)) pure en
  xs <- noteStatuses cfg r notes
  case [s | (note, s) <- xs, vnName note == n] of
    [s] -> pure (nsLabel s, nsCategory s, nsLine s)
    _ -> assertFailure ("没有 " <> n <> " 的记录")

casePureValidation :: IO ()
casePureValidation = do
  parseCoordinates "47.556533, 13.648033" @?= Just (47.556533, 13.648033)
  parseCoordinates " -33.9 ,151.2 " @?= Just (-33.9, 151.2)
  mapM_
    (\c -> assertBool ("应拒: " <> show c) (parseCoordinates c == Nothing))
    ["91, 0", "0, 181", "-90.5, 0", "47.5", "47.5, 13.6, 1", "a, b", "", "47.5,", "47.5, 13.6x"]
  now <- getCurrentTime
  let good = VaultNote "a.jpg" (T.replicate 64 "a") fullFields {nfSource = "ai-high"} now
      with f = good {vnFields = f (vnFields good)}
      bad =
        [ ("坐标越界", with (\f -> f {nfCoordinates = Just "95, 10"}))
        , ("坐标格式", with (\f -> f {nfCoordinates = Just "north"}))
        , ("source", with (\f -> f {nfSource = "guess"}))
        , ("控制符", with (\f -> f {nfLocation = Just "Hall\tstatt"}))
        , ("超长", with (\f -> f {nfTitle = Just (T.replicate 201 "x")}))
        , ("类目", with (\f -> f {nfCategory = Just "scenery"}))
        , ("无字段", with (const noFields))
        , ("坏 sha", good {vnSha = "zz"})
        , ("带路径名", good {vnName = "sub" </> "a.jpg"})
        ]
  mapM_ (\(lbl, n) -> either (const (pure ())) (const (assertFailure ("应拒: " <> lbl))) (validateNotes [n])) bad
  case validateNotes [good {vnName = "b.jpg"}, good] of
    Left m -> assertFailure m
    Right ns -> map vnName ns @?= ["a.jpg", "b.jpg"]
  case validateNotes [good, good] of
    Left m -> assertBool ("应点名重复: " <> m) ("多次" `isInfixOf` m)
    Right _ -> assertFailure "同名两条必须拒绝"

-- | 记录跟着照片走一遍：状态由「相册 sha 新鲜度 + vault 落位 + photos.json
-- 只读反查」算出，任何一段拆掉本例转红。
caseLifecycle :: IO ()
caseLifecycle = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      pj = tmp </> "photos.json"
      cfg = (mkVaultCfg root vdir) {cfgPhotosJson = Just pj}
      jpg = root </> "相册" </> "a.jpg"
      set fs = NoteArgs False ["a.jpg"] fs
      clear fs = NoteArgs True fs noFields
  mkMain root
  writeF jpg "AAA"
  writeF (root </> "相册" </> "p.png") "PNG"
  createDirectoryIfMissing True (vdir </> "landscape")
  -- 拒：不在相册 / 非 jpg / 没字段 / 坏坐标 / 多个文件 / --clear 带字段 / 清除不存在的
  runVaultNote (NoteArgs False ["ghost.jpg"] fullFields) cfg >>= (@?= 2)
  runVaultNote (NoteArgs False ["p.png"] fullFields) cfg >>= (@?= 2)
  runVaultNote (set noFields) cfg >>= (@?= 2)
  runVaultNote (set fullFields {nfCoordinates = Just "95, 0"}) cfg >>= (@?= 2)
  runVaultNote (NoteArgs False ["a.jpg", "p.png"] fullFields) cfg >>= (@?= 2)
  runVaultNote (NoteArgs True ["a.jpg"] fullFields) cfg >>= (@?= 2)
  runVaultNote (clear ["a.jpg"]) cfg >>= (@?= 2)
  doesFileExist (root </> ".pm" </> "vault-notes.json") >>= (@?= False)
  -- 记录 → unsynced（还是 NEW）
  runVaultNote (set fullFields) cfg >>= (@?= 0)
  statusOf cfg "a.jpg" >>= (@?= ("unsynced", Nothing, Nothing))
  runVaultNotes True cfg >>= (@?= 0)
  -- push 落位 → pending（photos.json 尚不存在 = 未引用）
  runVaultPush (execNow cfg) (Just "landscape") ["a.jpg"] cfg >>= (@?= 0)
  statusOf cfg "a.jpg" >>= (@?= ("pending", Just "landscape", Nothing))
  -- photos.json 引用到 → published（行号）
  writeF pj "[\n  {\"src\": \"https://example.invalid/photography/landscape/a.jpg\"}\n]\n"
  statusOf cfg "a.jpg" >>= (@?= ("published", Just "landscape", Just 2))
  -- photos.json 读不出（指向目录）→ unknown，退出码 1：不能答 pending（技能会重复上线）
  statusOf cfg {cfgPhotosJson = Just tmp} "a.jpg" >>= (\(s, _, _) -> s @?= "unknown")
  runVaultNotes True cfg {cfgPhotosJson = Just tmp} >>= (@?= 1)
  -- 字节换了 → stale（退出码 1）
  writeF jpg "AAAA"
  statusOf cfg "a.jpg" >>= (\(s, _, _) -> s @?= "stale")
  runVaultNotes False cfg >>= (@?= 1)
  -- 重新确认（覆盖记录，sha 刷新）→ 不再 stale；vault 那份是旧字节 = DRIFT，仍在类目、仍被引用
  runVaultNote (set fullFields {nfTitle = Just "Lake"}) cfg >>= (@?= 0)
  statusOf cfg "a.jpg" >>= (@?= ("published", Just "landscape", Just 2))
  readNotes root >>= \r -> fmap (map (nfTitle . vnFields)) r @?= Right [Just "Lake"]
  -- 清除
  runVaultNote (clear ["a.jpg"]) cfg >>= (@?= 0)
  readNotes root >>= (@?= Right [])
  runVaultNotes True cfg >>= (@?= 0)
  -- 照片零改动；vault 里只有 push 落的那一份旧字节
  BS.readFile jpg >>= (@?= "AAAA")
  BS.readFile (vdir </> "landscape" </> "a.jpg") >>= (@?= "AAA")

-- | 同 P4-7 'caseHoldCreateFreshSha'：陈旧 catalog 的 (size,mtime) 命中时记录
-- 仍取盘上真实 sha，否则记完立刻判 stale、记录根本落不住。
caseCreateFreshSha :: IO ()
caseCreateFreshSha = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  createDirectoryIfMissing True (vdir </> "landscape")
  (_, realSha) <- plantStaleCatalog root (root </> "相册" </> "a.jpg") (pure ())
  runVaultNote (NoteArgs False ["a.jpg"] fullFields) cfg >>= (@?= 0)
  readNotes root >>= \r -> fmap (map vnSha) r @?= Right [realSha]
  statusOf cfg "a.jpg" >>= (@?= ("unsynced", Nothing, Nothing))

-- | 记录的读改写是跨进程事务（I10）；身份预检在取锁之前（不在被拒前落 .pm/lock）。
caseTxnLock :: IO ()
caseTxnLock = withSystemTempDirectory "pm-vault" $ \tmp -> do
  let root = tmp </> "main"
      vdir = tmp </> "vault"
      cfg = mkVaultCfg root vdir
  mkMain root
  writeF (root </> "相册" </> "a.jpg") "AAA"
  writeF (root </> "相册" </> "b.jpg") "BBB"
  createDirectoryIfMissing True (vdir </> "landscape")
  runVaultNote (NoteArgs False ["a.jpg"] fullFields) cfg >>= (@?= 0)
  withForeignLock root (runVaultNote (NoteArgs False ["b.jpg"] fullFields) cfg) >>= (@?= 2)
  readNotes root >>= \r -> fmap (map vnName) r @?= Right ["a.jpg"]
  -- 取锁前预检：有库、没有 root 标识 → 拒，且 .pm 零写入
  let anon = tmp </> "anon"
  writeF (anon </> "相册" </> "a.jpg") "AAA"
  runVaultNote (NoteArgs False ["a.jpg"] fullFields) (mkVaultCfg anon vdir) >>= (@?= 2)
  doesDirectoryExist (anon </> ".pm") >>= (@?= False)

-- | 只读级 GET 与 --writable 级 POST；校验错误带 details（与 CLI 同一 'noteRequest'）。
caseServeNotes :: IO ()
caseServeNotes = withVaultWritable "/api/vault/notes" "{\"set\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"}]}" "vault-notes.json" $ \root _ cfg jpgBytes envW -> do
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    g <- getReq "/api/vault/notes" [] tok
    assertStatus 200 g
    liftIO' (arrLen (field ["notes"] (decodeBody g)) @?= Just 0)
  flip runSession (serveApp envW) $ do
    rBad <- postReq "/api/vault/notes" "{\"set\":[{\"name\":\"a.jpg\",\"coordinates\":\"95, 0\"}]}"
    assertStatus 400 rBad
    liftIO' (arrLen (field ["details"] (decodeBody rBad)) @?= Just 1)
    rGhost <- postReq "/api/vault/notes" "{\"set\":[{\"name\":\"ghost.jpg\",\"category\":\"urban\"}]}"
    assertStatus 400 rGhost
    rEmpty <- postReq "/api/vault/notes" "{}"
    assertStatus 400 rEmpty
    r1 <- postReq "/api/vault/notes" "{\"set\":[{\"name\":\"a.jpg\",\"category\":\"landscape\",\"location\":\" Hallstatt, AT \",\"coordinates\":\"47.556533, 13.648033\",\"title\":\"\",\"source\":\"ai-high\"}]}"
    assertStatus 200 r1
    liftIO' (field ["count"] (decodeBody r1) @?= Just (Aeson.Number 1))
    g1 <- getReq "/api/vault/notes" [] tok
    liftIO' $ do
      let v = decodeBody g1
      arrLen (field ["notes"] v) @?= Just 1
      (firstNote v >>= field ["status"]) @?= Just (Aeson.String "unsynced")
      (firstNote v >>= field ["location"]) @?= Just (Aeson.String "Hallstatt, AT") -- 已去首尾空白
      (firstNote v >>= field ["title"]) @?= Just Aeson.Null -- 空串 = 没给
      (firstNote v >>= field ["source"]) @?= Just (Aeson.String "ai-high")
    r2 <- postReq "/api/vault/notes" "{\"clear\":[\"a.jpg\"]}"
    assertStatus 200 r2
    liftIO' (field ["count"] (decodeBody r2) @?= Just (Aeson.Number 0))
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)
 where
  firstNote v = case field ["notes"] v of
    Just (Aeson.Array a) | (x : _) <- toList a -> Just x
    _ -> Nothing
