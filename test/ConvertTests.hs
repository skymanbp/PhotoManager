{-# LANGUAGE OverloadedStrings #-}

-- | P8-C2 转换（DESIGN-P8 §20）：参数闸整批拒绝、两段式端到端（Pillow 真转：
-- 16 位缩到 8 位 \/ alpha 合成白底 \/ RGB 原样；派生件复用；失败不留半成品；
-- 源原地不动；@--also-album@ 分组），以及 doctor 对 @.pm\/derived@ 的四态对账
-- 与 @--repair@ 的删除线。真转换用本机 python（@PM_PYTHON@ → PATH）——找不到
-- python 或没装 Pillow 时用例直接失败（不跳过：这台机的发布前提）。
module ConvertTests (convertTests) where

import Control.Exception (bracket_)
import Control.Monad (forM_)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sort)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog (saveCatalog)
import Pm.Cli (GoOpts (..))
import Pm.Config (Config (..))
import Pm.Convert
import Pm.Doctor (DoctorOpts (..), Severity (..), runDoctor)
import Pm.Hash (sha256File)
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan)
import Pm.Op (Op (..))
import TestUtil (doctorRows, mkMain, scanQuiet, writeF)

convertTests :: TestTree
convertTests =
  testGroup
    "P8-C2 转换（非 jpg → 派生 jpg → 成片同事件夹 / 相册）"
    [ testCase "参数闸：空 / 缺索引 / 已是 jpg / RAW / 层外 / 绝对与 .. / 同批撞名 / PM_PYTHON 不存在 → exit 2，.pm/derived 不出现" caseRefusals
    , testCase "端到端：16 位 tif→L≈117、RGBA→白底、RGB 原样；--also-album 同组（成片项组头）；复用派生件 / --redo 重派生；I7 成片待裁决 → 相册项不执行；坏源不出计划；源字节不动" caseE2E
    , testCase "doctor：DERIVED-STALE/ORPHAN/TMP Warn、PENDING Info；--repair 只删前三种、留 pending" caseDoctorDerived
    ]

-- ─── 夹具：主库 + 相册层 + 闭包式 runner（索引由各用例按需重做） ───────────────

-- | (--also-album, --redo, 文件) → (退出码, 计划 id, 输出)；每次先重索引。
type Runner = Bool -> Bool -> [String] -> IO (Int, Maybe T.Text, String)

withLib :: (FilePath -> Runner -> IO ()) -> IO ()
withLib k = withSystemTempDirectory "pm-convert" $ \tmp -> do
  let root = tmp </> "lib"
      cfg = Config root Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      runner also redo files = do
        scanQuiet "main-rid" root >>= saveCatalog root
        ref <- newIORef []
        (c, mpid) <- runConvertTo (\l -> modifyIORef' ref (l :)) (ConvertOpts (GoOpts True True) also redo files) cfg
        ls <- reverse <$> readIORef ref
        pure (c, mpid, unlines ls)
  writeF (root </> "相册" </> ".keep") ""
  mkMain root
  k root runner

-- | 本机 python：一次拿到路径，缺了就失败（不是 skip）。
python :: IO FilePath
python = findPython >>= either (\m -> assertFailure m >> pure "") pure

-- | 经 stdin 跑一段 python，非零退出即失败；返回 stdout。
py :: FilePath -> String -> [String] -> IO String
py exe script args = do
  (code, out, err) <- readProcessWithExitCode exe ("-" : args) script
  case code of
    ExitSuccess -> pure out
    ExitFailure n -> assertFailure ("python exit " <> show n <> ": " <> err) >> pure ""

-- | 生成三张测试图：RGB png、16 位灰 tif（样本 30000）、半透明红 RGBA png。
makeImages :: FilePath -> FilePath -> FilePath -> IO ()
makeImages exe rgbDir alphaDir =
  () <$ py exe
    (unlines
      [ "import sys"
      , "from PIL import Image"
      , "a, b = sys.argv[1], sys.argv[2]"
      , "Image.new('RGB', (4, 4), (10, 200, 30)).save(a + '/rgb.png')"
      , "Image.new('I;16', (4, 4), 30000).save(a + '/deep.tif')"
      , "Image.new('RGBA', (4, 4), (255, 0, 0, 128)).save(b + '/alpha.png')"
      ])
    [rgbDir, alphaDir]

-- | 读 jpg 左上像素：@mode r g b@ 或 @L v@（只出 ASCII）。
pixel :: FilePath -> FilePath -> IO (String, [Int])
pixel exe p = do
  out <- py exe "import sys\nfrom PIL import Image\nim = Image.open(sys.argv[1])\npx = im.getpixel((0, 0))\nprint(im.mode, *(px if isinstance(px, tuple) else (px,)))" [p]
  case words out of
    (m : vs) -> pure (m, map read vs)
    _ -> assertFailure ("pixel 输出异常: " <> out) >> pure ("", [])

near :: Int -> Int -> Bool
near a b = abs (a - b) <= 4

caseRefusals :: IO ()
caseRefusals = withLib $ \root run -> do
  writeF (root </> "成片" </> "E1" </> "rgb.png") "PNG"
  writeF (root </> "成片" </> "E1" </> "a.jpg") "JPG"
  writeF (root </> "成片" </> "E1" </> "r.ARW") "RAW"
  writeF (root </> "成片" </> "E1" </> "dup.png") "P1"
  writeF (root </> "成片" </> "E1" </> "DUP.tif") "P2"
  writeF (root </> "Raw" </> "2026" </> "x.png") "PNG"
  let refuse needle files = do
        (c, mpid, o) <- run False False files
        assertEqual o 2 c
        mpid @?= Nothing
        assertBool ("应含「" <> needle <> "」:\n" <> o) (needle `isInfixOf` o)
  refuse "未给出" []
  refuse "不在索引" ["成片/E1/ghost.png"]
  refuse "已经是 jpg" ["成片/E1/a.jpg"]
  refuse "RAW 原始档" ["成片/E1/r.ARW"]
  refuse "不在成片/相册下" ["Raw/2026/x.png"]
  refuse "库内相对路径" ["../x.png"]
  refuse "库内相对路径" ["D:\\x.png"]
  refuse "同名同目录" ["成片/E1/dup.png", "成片/E1/DUP.tif"]
  -- 一条坏参数整批拒：合法的 rgb.png 与坏的 ghost 同批 → 不转任何一张
  refuse "不在索引" ["成片/E1/rgb.png", "成片/E1/ghost.png"]
  bracket_ (setEnv "PM_PYTHON" (root </> "nope.exe")) (unsetEnv "PM_PYTHON") $
    refuse "PM_PYTHON 指向的文件不存在" ["成片/E1/rgb.png"]
  doesDirectoryExist (root </> ".pm" </> "derived") >>= (@?= False)

caseE2E :: IO ()
caseE2E = withLib $ \root run -> do
  exe <- python
  let e1 = root </> "成片" </> "E1"
      e2 = root </> "成片" </> "E2"
      alb = root </> "相册"
  mapM_ (createDirectoryIfMissing True) [e1, e2]
  makeImages exe e1 alb
  _ <- py exe "import sys\nfrom PIL import Image\nImage.new('RGB', (2, 2), (1, 2, 3)).save(sys.argv[1])" [e2 </> "solo.png"]
  srcShas <- mapM sha256File [e1 </> "rgb.png", e1 </> "deep.tif", alb </> "alpha.png"]
  let three = ["成片/E1/rgb.png", "成片/E1/deep.tif", "相册/alpha.png"]
  (c1, mpid1, o1) <- run True False three
  assertEqual o1 0 c1
  pid <- maybe (assertFailure "应有计划 id" >> pure "") pure mpid1
  assertBool o1 ("已派生" `isInfixOf` o1)
  forM_ ["rgb.jpg", "deep.jpg"] $ \n -> do
    doesFileExist (e1 </> n) >>= (@?= True)
    doesFileExist (alb </> n) >>= (@?= True)
  doesFileExist (alb </> "alpha.jpg") >>= (@?= True)
  -- 像素纪律：16 位 30000/256≈117 的 L；RGBA 半透明红合成白底 ≈ (255,127,127)；RGB 原样
  (mDeep, vDeep) <- pixel exe (e1 </> "deep.jpg")
  mDeep @?= "L"
  assertBool ("deep 像素 " <> show vDeep) (case vDeep of [v] -> near v 117; _ -> False)
  (_, vAlpha) <- pixel exe (alb </> "alpha.jpg")
  assertBool ("alpha 像素 " <> show vAlpha) (case vAlpha of [r, g, b] -> near r 255 && near g 127 && near b 127; _ -> False)
  (_, vRgb) <- pixel exe (alb </> "rgb.jpg")
  assertBool ("rgb 像素 " <> show vRgb) (case vRgb of [r, g, b] -> near r 10 && near g 200 && near b 30; _ -> False)
  -- 计划结构：--also-album 的相册项挂在成片项的组上（成片项是组头）；源都是 .pm/derived 下的派生件
  items <- planItems root pid
  let byDst d = [it | it <- items, opDstRel (piOp it) == d]
  length items @?= 5
  case (byDst ("成片" </> "E1" </> "rgb.jpg"), byDst ("相册" </> "rgb.jpg")) of
    ([m], [a]) -> do
      piGroup m @?= Just (piIx m)
      piGroup a @?= Just (piIx m)
      assertBool (opSrcAbs (piOp m)) ((".pm" </> "derived") `isInfixOf` opSrcAbs (piOp m))
    other -> assertFailure ("rgb 两项应各恰一: " <> show other)
  -- 源字节不动
  srcShas' <- mapM sha256File [e1 </> "rgb.png", e1 </> "deep.tif", alb </> "alpha.png"]
  srcShas' @?= srcShas
  -- 重跑：派生件复用、全部已落位 → 无计划 exit 0；--redo 则重派生（仍全部已落位）
  (c2, mpid2, o2) <- run True False three
  (c2, mpid2) @?= (0, Nothing)
  assertBool o2 ("复用派生件" `isInfixOf` o2 && "全部已落位" `isInfixOf` o2)
  (c2r, mpid2r, o2r) <- run True True three
  (c2r, mpid2r) @?= (0, Nothing)
  assertBool o2r ("已派生" `isInfixOf` o2r && not ("复用派生件" `isInfixOf` o2r))
  -- 不带 --also-album：成片源只落成片
  (c3, _, o3) <- run False False ["成片/E2/solo.png"]
  assertEqual o3 0 c3
  doesFileExist (e2 </> "solo.jpg") >>= (@?= True)
  doesFileExist (alb </> "solo.jpg") >>= (@?= False)
  -- I7 耦合：成片目标同名异容 → 成片项待裁决（I5），相册项一并待裁决、不执行、不分组
  _ <- py exe "import sys\nfrom PIL import Image\nImage.new('RGB', (2, 2), (9, 9, 9)).save(sys.argv[1])" [e2 </> "clash.png"]
  writeF (e2 </> "clash.jpg") "OTHER"
  (_, mpid5, o5) <- run True False ["成片/E2/clash.png"]
  pid5 <- maybe (assertFailure ("应有计划 id:\n" <> o5) >> pure "") pure mpid5
  items5 <- planItems root pid5
  length items5 @?= 2
  forM_ items5 $ \it -> case piStatus it of
    StNeedsDecision _ -> piGroup it @?= Nothing
    s -> assertFailure (opDstRel (piOp it) <> " 应待裁决，得到 " <> show s)
  doesFileExist (alb </> "clash.jpg") >>= (@?= False)
  readFile (e2 </> "clash.jpg") >>= (@?= "OTHER")
  -- 坏源：python 失败 → exit 2、不出计划、不留 .tmp、目标不出现
  writeF (e1 </> "bad.tif") "NOT A TIFF"
  (c4, mpid4, o4) <- run False False ["成片/E1/bad.tif"]
  (c4, mpid4) @?= (2, Nothing)
  assertBool o4 ("转换失败" `isInfixOf` o4)
  doesFileExist (e1 </> "bad.jpg") >>= (@?= False)
  leftovers <- derivedFiles root
  assertBool ("不应留 .tmp: " <> show leftovers) (not (any ((".tmp" `isInfixOf`)) leftovers))

planItems :: FilePath -> T.Text -> IO [PlanItem]
planItems root pid = loadPlan root pid >>= either (\e -> assertFailure e >> pure []) (pure . plItems)

-- | @.pm/derived/*/*@ 的文件名清单。
derivedFiles :: FilePath -> IO [FilePath]
derivedFiles root = do
  let base = root </> ".pm" </> "derived"
  ex <- doesDirectoryExist base
  if not ex
    then pure []
    else do
      ds <- listDirectory base
      concat <$> mapM (\d -> map (d </>) <$> listDirectory (base </> d)) ds

caseDoctorDerived :: IO ()
caseDoctorDerived = withLib $ \root _ -> do
  writeF (root </> "成片" </> "E1" </> "x.png") "PNG-X"
  writeF (root </> "成片" </> "E1" </> "w.jpg") "JPG-W"
  scanQuiet "main-rid" root >>= saveCatalog root
  shaX <- T.unpack <$> sha256File (root </> "成片" </> "E1" </> "x.png")
  let dX = root </> ".pm" </> "derived" </> shaX
      orphanDir = root </> ".pm" </> "derived" </> replicate 64 '0'
  writeF (dX </> "x.jpg") "J-PENDING" -- 派生了还没 apply
  writeF (dX </> "y.jpg.tmp") "HALF" -- 半成品
  writeF (dX </> "w.jpg") "JPG-W" -- 内容 sha 已在索引（已落位）
  writeF (orphanDir </> "z.jpg") "J-ORPHAN" -- 目录名 sha 不在索引
  rows <- doctorRows root
  let derivedRows = sort [r | r@(n, _) <- rows, "DERIVED" `isInfixOf` n]
  derivedRows @?= [("DERIVED-ORPHAN", Warn), ("DERIVED-PENDING", Info), ("DERIVED-STALE", Warn), ("DERIVED-TMP", Warn)]
  _ <- runDoctor root (DoctorOpts False True)
  kept <- sort <$> derivedFiles root
  kept @?= [shaX </> "x.jpg"]
  rows' <- doctorRows root
  [r | r@(n, _) <- rows', "DERIVED" `isInfixOf` n] @?= [("DERIVED-PENDING", Info)]
