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
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO

import Pm.Config (pmDir)
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

withJournal :: FilePath -> (Journal -> IO a) -> IO a
withJournal root act = do
  createDirectoryIfMissing True (pmDir root)
  withBinaryFile (journalPath root) AppendMode (act . Journal)

jAppend :: Journal -> Sync -> JEntry -> IO ()
jAppend (Journal h) sync e = do
  BSL.hPut h (encode e)
  BSL.hPut h "\n"
  case sync of
    Barrier -> flushHandleToDisk h
    Buffered -> hFlush h

-- | Read every entry. Returns (entries, warnings). A parse failure on the
-- FINAL line is a torn tail — expected after power loss, reported as a
-- warning; a failure on any earlier line means real corruption and is
-- reported loudly (doctor surfaces both).
readJournal :: FilePath -> IO ([JEntry], [String])
readJournal root = do
  let fp = journalPath root
  exists <- doesFileExist fp
  if not exists
    then pure ([], [])
    else do
      raw <- BS.readFile fp
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
