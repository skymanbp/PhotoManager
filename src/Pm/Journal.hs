{-# LANGUAGE OverloadedStrings #-}

-- | Append-only NDJSON journal — the durable layer (DESIGN.md §3, I4).
-- Intent entries are written through a real persistence barrier
-- (FlushFileBuffers) BEFORE their effect touches the disk; Done entries for
-- Copy may be group-committed because doctor row C2/C3 can rebuild them from
-- disk content, while Rename/Quarantine Done entries always use the barrier
-- (the old name exists nowhere else).
module Pm.Journal
  ( JEntry (..)
  , Sync (..)
  , Journal
  , journalPath
  , withJournal
  , jAppend
  , readJournal
  ) where

import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import Data.Time (UTCTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO

import Pm.Config (pmDir, readPmState, requirePmTrusted, withPmStateAppend)
import Pm.Op (Op)
import Pm.Win (flushHandleToDisk)

data Sync = Barrier | Buffered

data JEntry
  = JIntent {jeOpId :: Text, jeOp :: Op, jeAt :: UTCTime}
  | JDone
      { jeOpId :: Text
      , jeVerifiedSha :: Maybe Text
      , jeTrashRel :: Maybe FilePath
      , jeAt :: UTCTime
      }
  | JFailed {jeOpId :: Text, jeErr :: Text, jeAt :: UTCTime}
  | JCleanShutdown {jeAt :: UTCTime}
  deriving (Show, Eq)

instance ToJSON JEntry where
  toJSON (JIntent i op at) = object ["e" .= ("intent" :: Text), "op" .= i, "spec" .= op, "at" .= at]
  toJSON (JDone i sha tr at) =
    object ["e" .= ("done" :: Text), "op" .= i, "sha256" .= sha, "trash" .= tr, "at" .= at]
  toJSON (JFailed i err at) = object ["e" .= ("failed" :: Text), "op" .= i, "err" .= err, "at" .= at]
  toJSON (JCleanShutdown at) = object ["e" .= ("clean-shutdown" :: Text), "at" .= at]

instance FromJSON JEntry where
  parseJSON = withObject "JEntry" $ \o -> do
    e <- o .: "e"
    case (e :: Text) of
      "intent" -> JIntent <$> o .: "op" <*> o .: "spec" <*> o .: "at"
      "done" -> JDone <$> o .: "op" <*> o .: "sha256" <*> o .: "trash" <*> o .: "at"
      "failed" -> JFailed <$> o .: "op" <*> o .: "err" <*> o .: "at"
      "clean-shutdown" -> JCleanShutdown <$> o .: "at"
      _ -> fail ("unknown journal entry: " <> show e)

newtype Journal = Journal Handle

journalPath :: FilePath -> FilePath
journalPath root = pmDir root </> "journal.ndjson"

-- | P3b-12（九轮复审 major，探针实证）：journal 是 append-only 的耐久层，
-- 名字固定。把 @.pm\/journal.ndjson@ 预置成库外文件的 hardlink 后，
-- @AppendMode@ 追加**真的写到了库外对象**上（hardlink 不是 reparse point，
-- 逐级下降与 canonical 都看不见它）。'openStateAppend' 打开后立刻查 link
-- count，\>1 即关闭并拒绝——AppendMode 不截断，所以此时尚未写入任何字节。
-- P3b-14（十一轮）：改走 'withPmStateAppend' —— 它在 'openStateAppend' 之前
-- 先对**完整路径**做 resolveUnder。journal 在 @.pm@ 深度 1，可信闸本就覆盖它，
-- 但 manifest 的同类形态（深度 2）实测能把追加写引到库外，两个追加点因此统一
-- 走同一个口，不留"这个为什么不一样"的缺口。
withJournal :: FilePath -> (Journal -> IO a) -> IO a
withJournal root act = do
  createDirectoryIfMissing True (pmDir root)
  withPmStateAppend root "journal.ndjson" (act . Journal)

-- 条目与换行合成**一次** hPut（第一方自审）：两次写之间缓冲恰好满时会落半行，
-- 下一条接在同一行上成为 CORRUPT-JOURNAL——响亮，但本可不发生。
jAppend :: Journal -> Sync -> JEntry -> IO ()
jAppend (Journal h) sync e = do
  BSL.hPut h (encode e <> "\n")
  case sync of
    Barrier -> flushHandleToDisk h
    Buffered -> hFlush h

-- | Read every entry. Returns (entries, warnings). A parse failure on the
-- FINAL line is a torn tail — expected after power loss, reported as a
-- warning; a failure on any earlier line means real corruption and is
-- reported loudly (doctor surfaces both).
readJournal :: FilePath -> IO ([JEntry], [String])
readJournal root = do
  -- 同 'Pm.Catalog.loadCatalog'：闸在 loader 里（P3b-13 十轮 major）
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure ([], [m])
    Right () -> readJournal' root

readJournal' :: FilePath -> IO ([JEntry], [String])
readJournal' root = do
  -- P3b-14（十一轮）：读侧与写侧同规格——受信取用口做完整路径 resolveUnder +
  -- 句柄 link count。不可信一律 Left，绝不降级成"空 journal"（那会让 doctor
  -- 把在途事务判成无事发生）。
  rd <- readPmState root "journal.ndjson"
  case rd of
    Left m -> pure ([], [m])
    Right Nothing -> pure ([], [])
    Right (Just raw) -> do
      let ls = filter (not . BS.null) (BSC.lines raw)
          parsed = map (\l -> (l, eitherDecodeStrict l :: Either String JEntry)) ls
          go _ [] = ([], [])
          go i ((l, r) : rest) =
            let (es, ws) = go (i + 1 :: Int) rest
             in case r of
                  Right e -> (e : es, ws)
                  Left err
                    | null rest ->
                        (es, ("torn tail (last line unparsable, expected after power loss): " <> err) : ws)
                    | otherwise ->
                        (es, ("CORRUPT-JOURNAL line " <> show i <> ": " <> err <> " | " <> show (BS.take 80 l)) : ws)
      pure (go 1 parsed)
