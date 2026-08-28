{-# LANGUAGE OverloadedStrings #-}

-- | P8-D：归档页四个端点（import/plan · album/candidates · album/add-plan ·
-- convert/plan）与 AI 建议端点（suggest）。写端点三道共同闸（只读 403 / 413 /
-- 400）+ 与 CLI 同源的交代行进 log；suggest 是只读级：假 claude 夹具
-- （@test/fixtures/fake-claude.cmd@，@PM_CLAUDE_EXE@ 指过去）四种形态——
-- 预置 JSON / 围栏 JSON / 垃圾 / 退出非零，外加超时与并发 409；契约：建议
-- **不写** @.pm@ 的任何记录与计划、照片字节不动。
module ServeP8Tests (serveP8Tests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (bracket_)
import Control.Monad (forM_, void)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Char (toUpper)
import Data.Foldable (toList)
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (diffUTCTime, getCurrentTime)
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, makeAbsolute)
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

import ConvertTests (writeRgbPng)
import Pm.Catalog (saveCatalog)
import Pm.Config (Config (..))
import Pm.Op (Op (..))
import Pm.Plan (Plan (..), PlanItem (..), loadPlan)
import Pm.Serve (serveApp)
import Pm.ServeAi (evenSample, extractJson)
import Pm.Subprocess (ToolOutcome (..), runTool)
import ServeTests (arrLen, decodeBody, field, fixture, getReq, liftIO', mkCfg, mkEnv, mkEnvW, postReq, seedSortSrc, tok)
import SortTests (photoAt)
import System.Timeout (timeout)
import TestUtil (mkMain, scanQuiet, writeF)

serveP8Tests :: TestTree
serveP8Tests =
  testGroup
    "P8-D pm serve 归档页端点 + AI 建议"
    [ testCase "POST /api/import/plan：只读 403 且 .pm/plans 不出现；alsoAlbum → 相册项进计划、log 有「相册 +1」" caseImportPlan
    , testCase "GET /api/album/candidates + POST /api/album/add-plan：候选按事件夹（rel 可回传）、非 jpg 单列；坏路径 code 2 / planId null / log 交代；合法 → 计划可装回、相册未动" caseCandidatesAndAddPlan
    , testCase "POST /api/convert/plan：只读 403 且 .pm/derived 不出现；真 Pillow 转换 → 派生件落 .pm/derived、计划两项同组；坏源 code 2 不出计划" caseConvertPlan
    , testCase "POST /api/suggest classify：只读级放行；预置回答规范化（未请求的名字丢弃、坐标规范）；400 五种；413；502 垃圾/退出非零/is_error；409 缺 claude/超时/并发；.pm 零写入" caseSuggestClassify
    , testCase "POST /api/suggest place：serve 自己重跑分段抽样；围栏 JSON 解析；只有 RAW 的段不交给模型答 null；>12 段 400" caseSuggestPlace
    , testCase "纯函数：evenSample 首/中/尾均匀；extractJson 裸/围栏/带前后文/垃圾" casePure
    , testCase "runTool（门禁 F2）：子进程灌满 stdout 且不读 stdin，喂入 100 KiB 提示 → 超时仍生效（ToolTimeout 1），不因管道互等挂死" caseRunToolFlood
    ]

-- ─── 归档页端点 ──────────────────────────────────────────────────────────────

withLib :: (FilePath -> Config -> IO ()) -> IO ()
withLib k = withSystemTempDirectory "pm-serve-p8" $ \tmp -> do
  let root = tmp </> "lib"
  createDirectoryIfMissing True (root </> "相册")
  mkMain root
  k root (mkCfg root)

index :: FilePath -> IO ()
index root = scanQuiet "main-rid" root >>= saveCatalog root

planIdOf :: Aeson.Value -> Maybe T.Text
planIdOf v = case field ["planId"] v of
  Just (Aeson.String p) -> Just p
  _ -> Nothing

logHas :: T.Text -> Aeson.Value -> Bool
logHas needle v = case field ["log"] v of
  Just (Aeson.Array xs) -> any (\x -> case x of Aeson.String t -> needle `T.isInfixOf` t; _ -> False) (toList xs)
  _ -> False

caseImportPlan :: IO ()
caseImportPlan = withLib $ \root cfg -> do
  writeF (root </> "To-Be-Sync'd" </> "Processed" </> "26-06-R66" </> "x.jpg") "XXX"
  index root
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ postReq "/api/import/plan" "{\"alsoAlbum\":true}" >>= assertStatus 403
  doesDirectoryExist (root </> ".pm" </> "plans") >>= (@?= False)
  envW <- mkEnvW cfg
  pid <- flip runSession (serveApp envW) $ do
    postReq "/api/import/plan" "{not json" >>= assertStatus 400
    postReq "/api/import/plan" (BSL.fromStrict (BS.replicate (70 * 1024) 32)) >>= assertStatus 413
    r <- postReq "/api/import/plan" "{\"alsoAlbum\":true}"
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      assertBool ("log 应含相册 +1: " <> show v) (logHas "相册 +1" v)
      maybe (assertFailure ("应有 planId: " <> show v) >> pure "") pure (planIdOf v)
  ep <- loadPlan root pid
  case ep of
    Left e -> assertFailure e
    Right plan -> do
      plKind plan @?= "import"
      assertBool "相册项应在计划里" (("相册" </> "x.jpg") `elem` map (opDstRel . piOp) (plItems plan))
  -- 只生成计划：照片未动
  doesFileExist (root </> "成片" </> "26-06-R66" </> "x.jpg") >>= (@?= False)

caseCandidatesAndAddPlan :: IO ()
caseCandidatesAndAddPlan = withLib $ \root cfg -> do
  writeF (root </> "成片" </> "E1" </> "a.jpg") "AAA"
  writeF (root </> "成片" </> "E1" </> "t.tif") "TIF"
  index root
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- getReq "/api/album/candidates" [] tok
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      arrLen (field ["events"] v) @?= Just 1
      case field ["events"] v of
        Just (Aeson.Array evs) -> case toList evs of
          [e] -> do
            field ["event"] e @?= Just (Aeson.String "E1")
            arrLen (field ["photos"] e) @?= Just 1
            case field ["photos"] e of
              Just (Aeson.Array ps) -> forM_ (toList ps) $ \p -> do
                field ["rel"] p @?= Just (Aeson.String (T.pack ("E1" </> "a.jpg")))
                field ["path"] p @?= Just (Aeson.String (T.pack ("成片" </> "E1" </> "a.jpg")))
                field ["conflict"] p @?= Just (Aeson.Bool False)
              other -> assertFailure ("photos: " <> show other)
          other -> assertFailure ("events: " <> show other)
        other -> assertFailure ("events: " <> show other)
      arrLen (field ["nonJpg"] v) @?= Just 1
      case field ["nonJpg"] v of
        Just (Aeson.Array xs) -> forM_ (toList xs) $ \x -> do
          field ["path"] x @?= Just (Aeson.String (T.pack ("成片" </> "E1" </> "t.tif")))
          field ["layer"] x @?= Just (Aeson.String "成片")
        other -> assertFailure ("nonJpg: " <> show other)
    postReq "/api/album/add-plan" "{\"paths\":[\"E1/a.jpg\"]}" >>= assertStatus 403
  doesDirectoryExist (root </> ".pm" </> "plans") >>= (@?= False)
  envW <- mkEnvW cfg
  pid <- flip runSession (serveApp envW) $ do
    rBad <- postReq "/api/album/add-plan" "{\"paths\":[\"E1/ghost.jpg\"]}"
    assertStatus 200 rBad
    liftIO' $ do
      field ["code"] (decodeBody rBad) @?= Just (Aeson.Number 2)
      field ["planId"] (decodeBody rBad) @?= Just Aeson.Null
      assertBool "log 应交代不在索引" (logHas "不在索引" (decodeBody rBad))
    postReq "/api/album/add-plan" "{\"paths\":[]}" >>= \r -> liftIO' (field ["code"] (decodeBody r) @?= Just (Aeson.Number 2))
    r <- postReq "/api/album/add-plan" "{\"paths\":[\"E1/a.jpg\"]}"
    assertStatus 200 r
    liftIO' $ maybe (assertFailure "应有 planId" >> pure "") pure (planIdOf (decodeBody r))
  ep <- loadPlan root pid
  case ep of
    Left e -> assertFailure e
    Right plan -> do
      plKind plan @?= "album-add"
      map (opDstRel . piOp) (plItems plan) @?= ["相册" </> "a.jpg"]
  doesFileExist (root </> "相册" </> "a.jpg") >>= (@?= False)

caseConvertPlan :: IO ()
caseConvertPlan = withLib $ \root cfg -> do
  writeRgbPng (root </> "成片" </> "E1" </> "p.png")
  writeF (root </> "成片" </> "E1" </> "bad.tif" ) "NOT A TIFF"
  index root
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ postReq "/api/convert/plan" "{\"paths\":[\"成片/E1/p.png\"]}" >>= assertStatus 403
  doesDirectoryExist (root </> ".pm" </> "derived") >>= (@?= False)
  envW <- mkEnvW cfg
  -- 体里有中文路径：按 UTF-8 编码（OverloadedStrings 的 ByteString 字面量会把非 ASCII 截成 8 位）
  let utf8Body s = BSL.fromStrict (TE.encodeUtf8 (T.pack s))
  pid <- flip runSession (serveApp envW) $ do
    rBad <- postReq "/api/convert/plan" (utf8Body "{\"paths\":[\"成片/E1/bad.tif\"]}")
    assertStatus 200 rBad
    liftIO' $ do
      field ["code"] (decodeBody rBad) @?= Just (Aeson.Number 2)
      field ["planId"] (decodeBody rBad) @?= Just Aeson.Null
      assertBool "log 应交代转换失败" (logHas "转换失败" (decodeBody rBad))
    r <- postReq "/api/convert/plan" (utf8Body "{\"paths\":[\"成片/E1/p.png\"],\"alsoAlbum\":true}")
    assertStatus 200 r
    liftIO' $ do
      assertBool "log 应含 已派生" (logHas "已派生" (decodeBody r))
      maybe (assertFailure "应有 planId" >> pure "") pure (planIdOf (decodeBody r))
  doesDirectoryExist (root </> ".pm" </> "derived") >>= (@?= True)
  ep <- loadPlan root pid
  case ep of
    Left e -> assertFailure e
    Right plan -> do
      plKind plan @?= "convert"
      map (opDstRel . piOp) (plItems plan) @?= ["成片" </> "E1" </> "p.jpg", "相册" </> "p.jpg"]
      case plItems plan of
        [m, a] -> piGroup a @?= Just (piIx m)
        other -> assertFailure ("应两项: " <> show (length other))
  doesFileExist (root </> "成片" </> "E1" </> "p.jpg") >>= (@?= False)

-- ─── AI 建议 ─────────────────────────────────────────────────────────────────

-- | 假 claude 夹具；@mode@ 经 PM_FAKE_CLAUDE 选形态（空 = 分类预置回答）。
withFakeClaude :: String -> IO a -> IO a
withFakeClaude mode act = do
  exe <- makeAbsolute ("test" </> "fixtures" </> "fake-claude.cmd")
  bracket_ (setEnv "PM_CLAUDE_EXE" exe >> setEnv "PM_FAKE_CLAUDE" mode) (unsetEnv "PM_CLAUDE_EXE" >> unsetEnv "PM_FAKE_CLAUDE") act

classifyBody :: [String] -> BSL.ByteString
classifyBody names = Aeson.encode (Aeson.object ["kind" Aeson..= ("classify" :: String), "names" Aeson..= names])

caseSuggestClassify :: IO ()
caseSuggestClassify = withSystemTempDirectory "pm-serve-ai" $ \dir -> do
  let root = dir </> "root"
  (cfg, jpgBytes, _, _) <- fixture root
  envR <- mkEnv cfg -- 只读 serve 也放行：建议不写任何东西
  withFakeClaude "" $ flip runSession (serveApp envR) $ do
    r <- postReq "/api/suggest" (classifyBody ["a.jpg"])
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      arrLen (field ["items"] v) @?= Just 1
      case field ["items"] v of
        Just (Aeson.Array xs) -> forM_ (toList xs) $ \it -> do
          field ["name"] it @?= Just (Aeson.String "a.jpg")
          field ["category"] it @?= Just (Aeson.String "landscape")
          field ["location"] it @?= Just (Aeson.String "Hallstatt")
          field ["coordinates"] it @?= Just (Aeson.String "47.5, 13.6")
          field ["source"] it @?= Just (Aeson.String "ai-high")
        other -> assertFailure ("items: " <> show other)
      arrLen (field ["dropped"] v) @?= Just 0
      field ["cost"] v @?= Just (Aeson.Number 0.03)
    -- 400：坏 kind / 空 names / 不在相册 / 带路径 / 超过 20
    postReq "/api/suggest" "{\"kind\":\"draw\"}" >>= assertStatus 400
    postReq "/api/suggest" (classifyBody []) >>= assertStatus 400
    rGhost <- postReq "/api/suggest" (classifyBody ["ghost.jpg"])
    assertStatus 400 rGhost
    liftIO' (arrLen (field ["details"] (decodeBody rGhost)) @?= Just 1)
    postReq "/api/suggest" (classifyBody ["../a.jpg"]) >>= assertStatus 400
    postReq "/api/suggest" (classifyBody (replicate 21 "a.jpg")) >>= assertStatus 400
    postReq "/api/suggest" (classifyBody ["a.jpg", "a.jpg"]) >>= assertStatus 400
    postReq "/api/suggest" (BSL.fromStrict (BS.replicate (70 * 1024) 32)) >>= assertStatus 413
  withFakeClaude "garbage" $ flip runSession (serveApp envR) $ do
    r <- postReq "/api/suggest" (classifyBody ["a.jpg"])
    assertStatus 502 r
    liftIO' $ case field ["raw"] (decodeBody r) of
      Just (Aeson.String raw) -> assertBool (T.unpack raw) ("no json" `T.isInfixOf` raw)
      other -> assertFailure ("502 应带 raw: " <> show other)
  withFakeClaude "fail" $ flip runSession (serveApp envR) $ postReq "/api/suggest" (classifyBody ["a.jpg"]) >>= assertStatus 502
  -- 退出 0 但信封 is_error:true（额度 / 登录问题）→ 502 并点名 is_error（步 9 minor）
  withFakeClaude "iserror" $ flip runSession (serveApp envR) $ do
    r <- postReq "/api/suggest" (classifyBody ["a.jpg"])
    assertStatus 502 r
    liftIO' (assertBool "应点名 is_error" ("is_error" `BS.isInfixOf` BSL.toStrict (simpleBody r)))
  -- 超时：PM_SUGGEST_TIMEOUT=1 而夹具睡 ~3 s → 409 并点名可调的环境变量（断言用 ASCII 子串）
  withFakeClaude "sleep" $ bracket_ (setEnv "PM_SUGGEST_TIMEOUT" "1") (unsetEnv "PM_SUGGEST_TIMEOUT") $
    flip runSession (serveApp envR) $ do
      r <- postReq "/api/suggest" (classifyBody ["a.jpg"])
      assertStatus 409 r
      liftIO' (assertBool "应说明超时并点名 PM_SUGGEST_TIMEOUT" ("PM_SUGGEST_TIMEOUT" `BS.isInfixOf` BSL.toStrict (simpleBody r)))
  -- 并发：上一次没结束 → 409（不排队）
  withFakeClaude "sleep" $ do
    started <- newEmptyMVar
    done <- newEmptyMVar
    void . forkIO $ do
      putMVar started ()
      flip runSession (serveApp envR) $ postReq "/api/suggest" (classifyBody ["a.jpg"]) >>= assertStatus 200
      putMVar done ()
    takeMVar started
    threadDelay 400000
    flip runSession (serveApp envR) $ postReq "/api/suggest" (classifyBody ["a.jpg"]) >>= assertStatus 409
    takeMVar done
  -- 缺 claude：409
  bracket_ (setEnv "PM_CLAUDE_EXE" (dir </> "nope.exe")) (unsetEnv "PM_CLAUDE_EXE") $
    flip runSession (serveApp envR) $ postReq "/api/suggest" (classifyBody ["a.jpg"]) >>= assertStatus 409
  -- 契约：建议不写 .pm 的记录与计划、照片字节不动
  doesFileExist (root </> ".pm" </> "vault-holds.json") >>= (@?= False)
  doesFileExist (root </> ".pm" </> "vault-notes.json") >>= (@?= False)
  doesDirectoryExist (root </> ".pm" </> "plans") >>= (@?= False)
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)

caseSuggestPlace :: IO ()
caseSuggestPlace = withSystemTempDirectory "pm-serve-ai-place" $ \tmp -> do
  (src, cfg) <- seedSortSrc tmp
  BS.writeFile (src </> "DCIM" </> "a.jpg") (photoAt "2026:08:25 11:00:00") -- 段 1 有可看的 jpg；段 2 只有 b.ARW
  env <- mkEnv cfg
  let body = Aeson.encode (Aeson.object ["kind" Aeson..= ("place" :: String), "src" Aeson..= src, "gap" Aeson..= (72 :: Int)])
  withFakeClaude "place" $ flip runSession (serveApp env) $ do
    r <- postReq "/api/suggest" body
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ case field ["segments"] v of
      Just (Aeson.Array xs) -> case toList xs of
        [s1, s2] -> do
          field ["index"] s1 @?= Just (Aeson.Number 1)
          field ["place"] s1 @?= Just (Aeson.String "Atlanta")
          field ["confidence"] s1 @?= Just (Aeson.String "high")
          field ["index"] s2 @?= Just (Aeson.Number 2)
          field ["place"] s2 @?= Just Aeson.Null
          case field ["basis"] s2 of
            Just (Aeson.String b) -> assertBool (T.unpack b) ("没有可看的图" `T.isInfixOf` b)
            other -> assertFailure ("段 2 basis: " <> show other)
        other -> assertFailure ("应两段: " <> show (length other))
      other -> assertFailure ("segments: " <> show other)
    -- 源目录不存在 → 409
    postReq "/api/suggest" (Aeson.encode (Aeson.object ["kind" Aeson..= ("place" :: String), "src" Aeson..= (tmp </> "nope")])) >>= assertStatus 409
  -- 13 段（逐月一张）→ 400
  forM_ (zip [1 :: Int ..] ["2025:01", "2025:02", "2025:03", "2025:04", "2025:05", "2025:06", "2025:07", "2025:08", "2025:09", "2025:10", "2025:11", "2025:12", "2026:01"]) $ \(i, ym) ->
    BS.writeFile (src </> "DCIM" </> ("m" <> show i <> ".jpg")) (photoAt (ym <> ":10 10:00:00"))
  withFakeClaude "place" $ flip runSession (serveApp env) $ postReq "/api/suggest" body >>= assertStatus 400

-- | 串行「先喂完 stdin 再读」在这里会互等：桩不读 stdin 却先往 stdout 写 24 KiB，
-- 两边的管道都满 → 双方永久阻塞，超时如果不覆盖喂 stdin 那一段就救不了它
-- （serve 里 seSuggestLock 会永远握住）。外层 10 s 兜底：挂死 → Nothing → 红。
caseRunToolFlood :: IO ()
caseRunToolFlood = do
  exe <- makeAbsolute ("test" </> "fixtures" </> "flood.cmd")
  pidsBefore <- pingPids
  t0 <- getCurrentTime
  r <- timeout 15000000 (runTool exe [] Nothing [] (T.replicate 100000 "x") 1)
  t1 <- getCurrentTime
  let elapsed = realToFrac (diffUTCTime t1 t0) :: Double
  case r of
    Just (ToolTimeout 1) -> pure ()
    other -> assertFailure ("应在 1 s 超时: " <> show other)
  -- 到点必须**先杀树**再收线程：桩要睡 ~9 s 才自己退出，若实现是先 cancel 喂 stdin 的
  -- 线程（阻塞在满管道里的写不可中断），返回时刻会拖到桩自己退出——用耗时把两者分开。
  -- 杀树走 job 对象（use_process_jobs）：只杀直接子进程 cmd.exe 的话，继承了管道的 ping
  -- 孙进程还握着 stdin，写端照样卡到它 9 s 后自己退出——同样被这条耗时断言判红
  assertBool ("超时应在 1 s 到点后立刻返回（杀树解开写端），实测 " <> show elapsed <> " s") (elapsed < 4)
  -- 树已杀干净：桩的 ping 孙进程不再存在（否则下一个用例 / 下一次点击还挂着一棵）。
  -- tasklist 是全机查询（门禁二轮 N1）：只看本用例跑前后**新增**的 PING PID，机器上
  -- 无关的 ping（用户手敲、另一份 stack test）不算进来
  pidsAfter <- pingPids
  let leaked = filter (`notElem` pidsBefore) pidsAfter
  assertBool ("桩的 ping 孙进程应随 job 一起被杀，残留 PID: " <> show leaked) (null leaked)
 where
  pingPids = do
    (_, tl, _) <- readProcessWithExitCode "tasklist" ["/FI", "IMAGENAME eq PING.EXE", "/FO", "CSV", "/NH"] ""
    -- CSV 行形如 "PING.EXE","12345","Console","1","5,000 K"：第二格是 PID
    pure [pid | l <- lines tl, "PING.EXE" `isInfixOf` map toUpper l, (_ : pid : _) <- [words (map (\c -> if c == ',' then ' ' else c) l)]]

casePure :: IO ()
casePure = do
  evenSample 5 [1 .. 10 :: Int] @?= [1, 3, 5, 7, 10]
  evenSample 5 [1 .. 4 :: Int] @?= [1 .. 4]
  evenSample 5 ([] :: [Int]) @?= []
  let arr = Aeson.decode "[{\"index\":1}]" :: Maybe Aeson.Value
  extractJson "[{\"index\":1}]" @?= arr
  extractJson "Here:\n```json\n[{\"index\":1}]\n```\nDone." @?= arr
  extractJson "prose [{\"index\":1}] trailing" @?= arr
  extractJson "no brackets here" @?= Nothing
  extractJson "[not json" @?= Nothing
