{-# LANGUAGE OverloadedStrings #-}

-- | P8-B 相册通道（DESIGN-P8 §19）：判定五桶、参数闸、@--also-album@ 的分组与
-- 返修耦合、@pm album add@ 端到端（幂等 \/ 非 jpg \/ 缺索引 \/ 撞名），以及 I7 组
-- 语义——成片那份没落位，相册那份不执行。
module AlbumTests (albumTests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Album
import Pm.Catalog (saveCatalog)
import Pm.Cli (GoOpts (..))
import Pm.Commands (runImportTo)
import Pm.Config (Config (..), writeRootInfo)
import Pm.Hash (sha256File)
import Pm.Import (importPlanItems, planImport)
import Pm.Op
import Pm.Plan
import Pm.Types
import TestUtil (mkCat, mkE, scanQuiet, t0, writeF)

albumTests :: TestTree
albumTests =
  testGroup
    "P8-B 相册通道（成片 → 相册）"
    [ testCase "classifyAlbum 五桶：拷贝 / 已在（同 sha）/ 同名异容 / 同批撞名（case-fold）/ 非 jpg" casePureBuckets
    , testCase "parseProcessedRel：只收 <事件夹>/<文件名>；绝对、盘符、..、成片 前缀、单级、.pm 一律拒" caseParse
    , testCase "--also-album（纯）：成片项与相册项同组、返修 → 相册项待裁决不分组、Raw 无相册项、非 jpg 交代" caseImportAlbumPure
    , testCase "albumCandidates：成片 jpg 未进相册的按事件夹分组、同名异容标记、非 jpg 单列、RAW 不列" caseCandidates
    , testCase "pm album add 端到端：落位同 sha → 重跑幂等（无计划 exit 0）→ 非 jpg/缺索引/撞名 整批拒绝 exit 2" caseAddE2E
    , testCase "I7 组语义端到端：成片项执行期 I5 冲突 → 同组相册项不执行；正常项两层都落位" caseImportGroupE2E
    ]

one :: (Show a) => String -> [a] -> IO a
one what xs = case xs of
  [x] -> pure x
  other -> assertFailure (what <> " 应恰一项，得到 " <> show other)

casePureBuckets :: IO ()
casePureBuckets = do
  let a = mkE ("成片" </> "26-06-R66" </> "a.jpg") "s1"
      b = mkE ("成片" </> "26-06-R66" </> "b.JPG") "s2"
      bAlb = mkE ("相册" </> "b.JPG") "s2"
      c = mkE ("成片" </> "26-06-R66" </> "c.jpg") "s3"
      cAlb = mkE ("相册" </> "c.jpg") "s3x"
      d1 = mkE ("成片" </> "E1" </> "d.jpg") "s4"
      d2 = mkE ("成片" </> "E2" </> "D.JPG") "s5"
      t = mkE ("成片" </> "26-06-R66" </> "t.tif") "s6"
      rep = classifyAlbum (mkCat [a, b, bAlb, c, cAlb, d1, d2, t]) [a, b, c, d1, d2, t]
  arCopy rep @?= [(a, "相册" </> "a.jpg")]
  arAlready rep @?= [(enPath b, "相册" </> "b.JPG")]
  arConflict rep @?= [(c, "相册" </> "c.jpg")]
  map fst (arDupName rep) @?= [enPath d1, enPath d2]
  arNotJpg rep @?= [enPath t]

caseParse :: IO ()
caseParse = do
  parseProcessedRel "26-06-R66/a.jpg" @?= Right ("成片" </> "26-06-R66" </> "a.jpg")
  parseProcessedRel "26-06-R66\\sub\\a.jpg" @?= Right ("成片" </> "26-06-R66" </> "sub" </> "a.jpg")
  mapM_
    (\s -> assertBool ("应拒绝: " <> show s) (either (const True) (const False) (parseProcessedRel s)))
    ["D:\\x\\a.jpg", "..\\a.jpg", "26-06-R66/../a.jpg", "成片/26-06-R66/a.jpg", "a.jpg", ".pm/plans/a.jpg", "\\26/a.jpg", "26:x/a.jpg", ""]

caseImportAlbumPure :: IO ()
caseImportAlbumPure = do
  let root = "R:"
      p1 = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "p1.jpg") "h1"
      p2 = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "p2.jpg") "h2"
      p2Old = mkE ("成片" </> "26-06-R66" </> "p2.jpg") "h2old"
      p3 = mkE ("To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "p3.tif") "h3"
      r1 = mkE ("To-Be-Sync'd" </> "Raw" </> "26-06-R66" </> "x.ARW") "h4"
      cat = mkCat [p1, p2, p2Old, p3, r1]
      rep = planImport cat
      base = importPlanItems root rep
      (items, arep) = withAlbumForImport root cat rep base
      byDst d = [it | it <- items, opDstRel (piOp it) == d]
  length items @?= length base + 2
  arNotJpg arep @?= [enPath p3]
  assertBool "基础项无组" (all ((== Nothing) . piGroup) base)
  i1 <- one "成片 p1" (byDst ("成片" </> "26-06-R66" </> "p1.jpg"))
  a1 <- one "相册 p1" (byDst ("相册" </> "p1.jpg"))
  piGroup i1 @?= Just (piIx i1)
  piGroup a1 @?= Just (piIx i1)
  piStatus a1 @?= StPending
  opSrcAbs (piOp a1) @?= root </> enPath p1
  opSha (piOp a1) @?= "h1"
  i2 <- one "成片 p2（返修）" (byDst ("成片" </> "26-06-R66" </> "p2.jpg"))
  a2 <- one "相册 p2" (byDst ("相册" </> "p2.jpg"))
  piGroup i2 @?= Nothing
  piGroup a2 @?= Nothing
  case piStatus a2 of
    StNeedsDecision why -> assertBool (T.unpack why) ("I7" `T.isInfixOf` why)
    s -> assertFailure ("相册 p2 应待裁决，得到 " <> show s)
  byDst ("相册" </> "x.ARW") @?= []
  byDst ("相册" </> "p3.tif") @?= []

caseCandidates :: IO ()
caseCandidates = do
  let a = mkE ("成片" </> "26-06-R66" </> "a.jpg") "s1"
      b = mkE ("成片" </> "26-06-R66" </> "b.jpg") "s2"
      bAlb = mkE ("相册" </> "b.jpg") "s2"
      c = mkE ("成片" </> "25-01-Atlanta" </> "c.JPG") "s3"
      cAlb = mkE ("相册" </> "c.jpg") "s3x"
      t = mkE ("成片" </> "26-06-R66" </> "t.tif") "s4"
      p = mkE ("相册" </> "p.png") "s5"
      -- 步 9 簇 C：RAW 就放在成片 / 相册**之内**（此前夹具把它放在 Raw\ 下，过滤靠
      -- 层级而不是扩展名，测不到「非 jpg 栏把 RAW 列进去」那条缺口）
      raw = mkE ("成片" </> "26-06-R66" </> "r.ARW") "s6"
      rawAlb = mkE ("相册" </> "q.DNG") "s7"
      ac = albumCandidates (mkCat [a, b, bAlb, c, cAlb, t, p, raw, rawAlb])
  acEvents ac @?= [("25-01-Atlanta", [(c, True)]), ("26-06-R66", [(a, False)])]
  map enPath (acNonJpg ac) @?= [enPath t, enPath p]

-- ─── 端到端夹具 ──────────────────────────────────────────────────────────────

withAlbumRoot :: (FilePath -> Config -> IO ()) -> IO ()
withAlbumRoot k = withSystemTempDirectory "pm-album" $ \tmp -> do
  let root = tmp </> "lib"
  writeF (root </> "相册" </> ".keep") ""
  writeRootInfo root (RootInfo "m" RoleMain t0 Nothing)
  k root (Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing)

index :: FilePath -> IO ()
index root = scanQuiet "m" root >>= saveCatalog root

runAdd :: Config -> [String] -> IO (Int, Maybe T.Text, String)
runAdd cfg args = do
  ref <- newIORef []
  (c, mpid) <- runAlbumAddTo (\l -> modifyIORef' ref (l :)) (GoOpts True True) args cfg
  ls <- reverse <$> readIORef ref
  pure (c, mpid, unlines ls)

caseAddE2E :: IO ()
caseAddE2E = withAlbumRoot $ \root cfg -> do
  writeF (root </> "成片" </> "26-06-R66" </> "a.jpg") "AAA"
  writeF (root </> "成片" </> "26-06-R66" </> "t.tif") "TIF"
  index root
  (c1, mpid1, o1) <- runAdd cfg ["26-06-R66/a.jpg"]
  assertEqual o1 0 c1
  assertBool "应有计划 id" (mpid1 /= Nothing)
  doesFileExist (root </> "相册" </> "a.jpg") >>= (@?= True)
  s1 <- sha256File (root </> "成片" </> "26-06-R66" </> "a.jpg")
  s2 <- sha256File (root </> "相册" </> "a.jpg")
  s1 @?= s2
  index root
  (c2, mpid2, o2) <- runAdd cfg ["26-06-R66/a.jpg"]
  (c2, mpid2) @?= (0, Nothing)
  assertBool o2 ("已在相册" `isInfixOf` o2)
  (c3, _, o3) <- runAdd cfg ["26-06-R66/t.tif"]
  c3 @?= 2
  assertBool o3 ("pm convert" `isInfixOf` o3)
  (c4, _, o4) <- runAdd cfg ["26-06-R66/ghost.jpg"]
  c4 @?= 2
  assertBool o4 ("不在索引" `isInfixOf` o4)
  writeF (root </> "成片" </> "26-07-X" </> "A.JPG") "AAA2"
  index root
  (c5, mpid5, o5) <- runAdd cfg ["26-06-R66/a.jpg", "26-07-X/A.JPG"]
  (c5, mpid5) @?= (2, Nothing)
  assertBool o5 ("同名" `isInfixOf` o5)
  -- NTFS 不分大小写：doesFileExist "A.JPG" 会命中 a.jpg，所以按内容判——相册那份仍是第一次落的字节
  sha256File (root </> "相册" </> "a.jpg") >>= (@?= s1)

caseImportGroupE2E :: IO ()
caseImportGroupE2E = withAlbumRoot $ \root cfg -> do
  writeF (root </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "x.jpg") "XXX"
  writeF (root </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "y.jpg") "YYY"
  writeF (root </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "t.tif") "TIF"
  index root
  -- 索引**之后**才出现的成片占位者：计划期看不见（catalog 说目标缺席），
  -- 执行期 I5 拒绝 → 组语义让同组的相册项不执行。
  writeF (root </> "成片" </> "26-06-R66" </> "x.jpg") "OTHER"
  ref <- newIORef []
  (code, mpid) <- runImportTo (\l -> modifyIORef' ref (l :)) (GoOpts True True) True cfg
  out <- unlines . reverse <$> readIORef ref
  assertEqual out 1 code
  assertBool "应有计划 id" (mpid /= Nothing)
  assertBool out ("相册 +2" `isInfixOf` out)
  assertBool out ("非 jpg 只进成片" `isInfixOf` out)
  doesFileExist (root </> "相册" </> "x.jpg") >>= (@?= False)
  doesFileExist (root </> "相册" </> "y.jpg") >>= (@?= True)
  doesFileExist (root </> "成片" </> "26-06-R66" </> "y.jpg") >>= (@?= True)
  doesFileExist (root </> "成片" </> "26-06-R66" </> "t.tif") >>= (@?= True)
  doesFileExist (root </> "相册" </> "t.tif") >>= (@?= False)
  sy <- sha256File (root </> "相册" </> "y.jpg")
  sy0 <- sha256File (root </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "y.jpg")
  sy @?= sy0
