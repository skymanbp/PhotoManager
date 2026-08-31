{-# LANGUAGE OverloadedStrings #-}

-- | P8-B 相册通道（DESIGN-P8 §19）：判定五桶、参数闸、@--also-album@ 的分组与
-- 返修耦合、@pm album add@ 端到端（幂等 \/ 非 jpg \/ 缺索引 \/ 撞名），以及 I7 组
-- 语义——成片那份没落位，相册那份不执行。
module AlbumTests (albumTests) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Set as Set
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
    , testCase "忽略过滤（纯）：按 sha 压出候选进 acIgnored（含冲突位）；splitIgnores 分生效/失效" caseIgnoreFilterPure
    , testCase "ignoreRequest（纯）：非候选/不在索引/重复内容/同时忽略又取消/未知取消 全部拒绝；按 sha/当前路径/存档路径三种取消" caseIgnoreRequestPure
    , testCase "pm album ignore 端到端：写 .pm/album-ignore.json、candidates 不再列、unignore 恢复、照片零改动" caseIgnoreE2E
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
      ac = albumCandidates Set.empty (mkCat [a, b, bAlb, c, cAlb, t, p, raw, rawAlb])
  acEvents ac @?= [("25-01-Atlanta", [(c, True)]), ("26-06-R66", [(a, False)])]
  map enPath (acNonJpg ac) @?= [enPath t, enPath p]
  acIgnored ac @?= []

caseIgnoreFilterPure :: IO ()
caseIgnoreFilterPure = do
  let a = mkE ("成片" </> "E1" </> "a.jpg") "s1"
      b = mkE ("成片" </> "E1" </> "b.jpg") "s2"
      c = mkE ("成片" </> "E2" </> "c.jpg") "s3"
      cAlb = mkE ("相册" </> "c.jpg") "s3x"
      cat = mkCat [a, b, c, cAlb]
      ig sha path = AlbumIgnore sha path t0
      igs = [ig "s1" (enPath a), ig "s3" (enPath c), ig "dead" ("成片" </> "E9" </> "gone.jpg")]
      ac = albumCandidates (Set.fromList (map aiSha igs)) cat
  -- s1（普通候选）与 s3（同名异容冲突候选）被压出；b 仍在
  acEvents ac @?= [("E1", [(b, False)])]
  acIgnored ac @?= [(a, False), (c, True)]
  -- 生效 = 本轮真的压掉了候选；dead 已无对象 → 失效
  let (live, stale) = splitIgnores ac igs
  map aiSha live @?= ["s1", "s3"]
  map aiSha stale @?= ["dead"]

caseIgnoreRequestPure :: IO ()
caseIgnoreRequestPure = do
  let sha1 = replicate 64 '1'
      sha2 = replicate 64 '2'
      sha3 = replicate 64 '3'
      sha4 = replicate 64 '4'
      a = mkE ("成片" </> "E1" </> "a.jpg") sha1
      a2 = mkE ("成片" </> "E2" </> "a2.jpg") sha1 -- 同内容另一路径
      b = mkE ("成片" </> "E1" </> "b.jpg") sha2
      bAlb = mkE ("相册" </> "b.jpg") sha2 -- b 已在相册同内容 → 不是候选
      t = mkE ("成片" </> "E1" </> "t.tif") sha3
      cat = mkCat [a, a2, b, bAlb, t]
      old = AlbumIgnore (T.pack sha4) ("成片" </> "E9" </> "old.jpg") t0
      req adds dels = ignoreRequest cat [old] adds dels t0
      errsOf r = either id (const []) r
  -- 空请求 / 不在索引 / 已在相册（非候选）/ 非 jpg（非候选）
  assertBool "空请求应拒" (not (null (errsOf (req [] []))))
  assertBool "不在索引应拒" (any ("不在索引" `isInfixOf`) (errsOf (req ["成片" </> "E1" </> "ghost.jpg"] [])))
  assertBool "已在相册应拒" (any ("不是候选" `isInfixOf`) (errsOf (req [enPath b] [])))
  assertBool "非 jpg 应拒" (any ("不是候选" `isInfixOf`) (errsOf (req [enPath t] [])))
  -- 同一内容两条路径一起忽略 = 重复内容
  assertBool "重复内容应拒" (any ("出现多次" `isInfixOf`) (errsOf (req [enPath a, enPath a2] [])))
  -- 未知取消：sha 不在清单 / 路径既不在索引也不是存档路径
  assertBool "未知 sha 取消应拒" (any ("没有这条忽略记录" `isInfixOf`) (errsOf (req [] [sha3])))
  assertBool "未知路径取消应拒" (any ("存档路径" `isInfixOf`) (errsOf (req [] ["E9/nothing.jpg"])))
  -- 忽略成功：记录带当前路径与 sha
  case req [enPath a] [] of
    Left es -> assertFailure (unlines es)
    Right kept -> map (\x -> (aiSha x, aiPath x)) kept @?= [(T.pack sha1, enPath a), (T.pack sha4, "成片" </> "E9" </> "old.jpg")]
  -- 取消三种：64 hex sha / 存档路径（对象已不在索引）/ 当前候选路径
  case req [] [sha4] of
    Left es -> assertFailure (unlines es)
    Right kept -> kept @?= []
  case req [] ["E9/old.jpg"] of
    Left es -> assertFailure (unlines es)
    Right kept -> kept @?= []
  let withA = either (error "seed") id (req [enPath a] [])
  case ignoreRequest cat withA [] ["E1/a.jpg"] t0 of
    Left es -> assertFailure (unlines es)
    Right kept -> map aiSha kept @?= [T.pack sha4]
  -- 同一内容同时忽略又取消
  assertBool "忽略又取消应拒" (any ("同时忽略与取消" `isInfixOf`) (errsOf (ignoreRequest cat withA [enPath a2] ["E1/a.jpg"] t0)))

caseIgnoreE2E :: IO ()
caseIgnoreE2E = withAlbumRoot $ \root cfg -> do
  writeF (root </> "成片" </> "E1" </> "a.jpg") "AAA"
  writeF (root </> "成片" </> "E1" </> "b.jpg") "BBB"
  index root
  ref <- newIORef []
  let runIg adds dels = do
        c <- runAlbumIgnoreTo (\l -> modifyIORef' ref (l :)) adds dels cfg
        out <- unlines . reverse <$> readIORef ref
        pure (c, out)
  (c1, o1) <- runIg ["E1/a.jpg"] []
  assertEqual o1 0 c1
  doesFileExist (root </> ".pm" </> "album-ignore.json") >>= (@?= True)
  igs <- readIgnores root >>= either (\e -> assertFailure e >> pure []) pure
  ig0 <- one "忽略记录" igs
  aiPath ig0 @?= "成片" </> "E1" </> "a.jpg"
  cat1 <- scanQuiet "m" root
  let ac1 = albumCandidates (Set.fromList (map aiSha igs)) cat1
  [(ev, map (enPath . fst) xs) | (ev, xs) <- acEvents ac1] @?= [("E1", ["成片" </> "E1" </> "b.jpg"])]
  map (enPath . fst) (acIgnored ac1) @?= ["成片" </> "E1" </> "a.jpg"]
  -- unignore 按 sha 恢复
  (c2, o2) <- runIg [] [T.unpack (aiSha ig0)]
  assertEqual o2 0 c2
  readIgnores root >>= either assertFailure (@?= [])
  let ac2 = albumCandidates Set.empty cat1
  map (length . snd) (acEvents ac2) @?= [2]
  -- 忽略是本地决定：照片零改动，记录里的 sha = 真实文件 sha
  s <- sha256File (root </> "成片" </> "E1" </> "a.jpg")
  aiSha ig0 @?= s

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
