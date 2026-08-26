{-# LANGUAGE OverloadedStrings #-}

-- | P7：上线命令生成（'Pm.Publish'）＋配置发布字段（portfolio 仓路径、
-- 两个 push 目标）＋ serve 侧的三处接线（ping 的 allowApply、config 的
-- publish 对象、GET \/api\/publish-commands）。
--
-- 每条用例钉一道闸：
--   * push 目标字符闸——生成的文本是整块复制进终端的，能长出第二条命令的
--     字符必须在设置入口就被拒；
--   * 渲染器「每张表渲染所有已设字段」——漏一个字段，下一次写回就把用户
--     设过的那项静默抹掉（round-trip 用例直接钉）；
--   * ping 的 allowApply 与 env 一致——GUI 据此决定渲染不渲染「执行」按钮。
module PublishTests (publishTests) where

import qualified Data.Aeson as Aeson
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Network.Wai.Test (assertStatus, runSession)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..), loadConfig, writeConfig)
import Pm.ConfigEdit (ConfigPatch (..), checkPatch, emptyPatch)
import Pm.Publish (publishCommands, pushTargetOk)
import Pm.Serve (serveApp)
import ServeTests (decodeBody, field, fixture, getReq, liftIO', mkCfg, mkEnv, mkEnvA, tok, withVault)

publishTests :: TestTree
publishTests =
  testGroup
    "P7 上线命令与发布配置"
    [ testCase "pushTargetOk：合法目标放行；空/超长/能长出第二条命令的字符一律拒" casePushTargetOk
    , testCase "publishCommands：按配置出段；photos.json 精确 add；push 目标进 push 行；全未配 → Left" casePublishCommands
    , testCase "配置 round-trip：三个发布字段写盘后逐字段读回（渲染器漏字段 = 静默丢设置）" caseConfigRoundTrip
    , testCase "checkPatch：portfolio 仓路径必须存在；坏 push 目标拒；JSON 三态（null = 清空）" casePublishPatch
    , testCase "serve：ping 带 allowApply（与授权级一致）；config 带 publish 对象" caseServePingConfig
    , testCase "GET /api/publish-commands：未配置 → 409；配置 vault 后 → 200 + 命令行数组" caseServePublishCommands
    ]

casePushTargetOk :: IO ()
casePushTargetOk = do
  mapM_ (\t -> assertBool (t <> " 应放行") (pushTargetOk t))
    ["origin main", "origin", "git@github.com:u/r.git main", "https://github.com/u/r.git HEAD:main", "up-stream v1.0_rc~1"]
  mapM_ (\t -> assertBool (show t <> " 应拒") (not (pushTargetOk t)))
    ["", "a;b", "a|b", "a&b", "a`b", "a$b", "a'b", "a\"b", "a\nb", "a>b", "a(b)", replicate 201 'x']

casePublishCommands :: IO ()
casePublishCommands = do
  let base = mkCfg "D:\\Photography"
  -- 全未配：Left 指路设置页
  case publishCommands base of
    Left m -> assertBool ("应指路设置页: " <> m) ("设置" `isInfixOf` m)
    Right ls -> assertFailure ("未配置竟有命令: " <> show ls)
  -- 只配 vault：一段四行，push 目标进 push 行
  let cv = base {cfgVaultPath = Just "V:\\vault\\摄影作品", cfgVaultPush = Just "origin main"}
  case publishCommands cv of
    Left m -> assertFailure m
    Right ls -> do
      length ls @?= 4
      assertBool "add -A 应针对 vault 仓" ("git -C \"V:\\vault\\摄影作品\" add -A" `elem` ls)
      assertBool "push 行应带目标" ("git -C \"V:\\vault\\摄影作品\" push origin main" `elem` ls)
  -- vault + portfolio + photos.json：portfolio 段精确 add 那一个文件，不 add -A
  let cb =
        cv
          { cfgPortfolioDir = Just "D:\\proj\\pf"
          , cfgPhotosJson = Just "D:\\proj\\pf\\data\\photos.json"
          , cfgPortfolioPush = Nothing
          }
  case publishCommands cb of
    Left m -> assertFailure m
    Right ls -> do
      assertBool "photos.json 已设时必须精确 add" ("git -C \"D:\\proj\\pf\" add \"D:\\proj\\pf\\data\\photos.json\"" `elem` ls)
      assertBool "photos.json 已设时不得 add -A 整仓" (not ("git -C \"D:\\proj\\pf\" add -A" `elem` ls))
      assertBool "未设 push 目标 → 裸 git push" ("git -C \"D:\\proj\\pf\" push" `elem` ls)
  -- 只配 portfolio、未配 photos.json：add -A 但必须带警示注释
  let cp = base {cfgPortfolioDir = Just "D:\\proj\\pf"}
  case publishCommands cp of
    Left m -> assertFailure m
    Right ls -> do
      assertBool "退化 add -A 前必须有警示注释" (any (\l -> "#" `isPrefixOf` l && "git status" `isInfixOf` l) ls)
      assertBool "vault 未配则不出展示集段" (not (any ("展示集" `isInfixOf`) ls))

caseConfigRoundTrip :: IO ()
caseConfigRoundTrip = do
  -- PM_CONFIG 指向 Spec.hs 的临时文件（机器全局配置由测试进程整体隔离）。
  let c =
        (mkCfg "D:\\Photography")
          { cfgVaultPath = Just "D:\\v"
          , cfgVaultPush = Just "origin main"
          , cfgPortfolioDir = Just "D:\\pf"
          , cfgPortfolioPush = Just "origin gh-pages"
          , cfgPhotosJson = Just "D:\\pf\\photos.json"
          }
  _ <- writeConfig c
  back <- loadConfig
  case back of
    Left m -> assertFailure ("写出的配置读不回来: " <> m)
    Right c2 -> c2 @?= c

casePublishPatch :: IO ()
casePublishPatch = withSystemTempDirectory "pm-pub-patch" $ \dir -> do
  -- portfolio 仓路径必须已存在（与 vault 同一原则：当场拒，不留给后续命令炸）
  e1 <- checkPatch emptyPatch {cpPortfolioDir = Just (Just (dir </> "no-such"))}
  assertBool "不存在的目录应拒" (not (null e1))
  createDirectoryIfMissing True (dir </> "pf")
  e2 <- checkPatch emptyPatch {cpPortfolioDir = Just (Just (dir </> "pf"))}
  e2 @?= []
  -- push 目标过字符闸
  e3 <- checkPatch emptyPatch {cpVaultPush = Just (Just "origin; rm -rf")}
  assertBool "带分号的 push 目标应拒" (not (null e3))
  e4 <- checkPatch emptyPatch {cpPortfolioPush = Just (Just "origin main")}
  e4 @?= []
  -- JSON 三态：null = 清空（Just Nothing），缺省 = 不动（Nothing）
  case Aeson.eitherDecode "{\"vaultPush\":null}" :: Either String ConfigPatch of
    Left m -> assertFailure m
    Right pt -> do
      cpVaultPush pt @?= Just Nothing
      cpPortfolioPush pt @?= Nothing
  case Aeson.eitherDecode "{\"portfolioDir\":\"D:\\\\x\",\"portfolioPush\":\"origin main\"}" :: Either String ConfigPatch of
    Left m -> assertFailure m
    Right pt -> do
      cpPortfolioDir pt @?= Just (Just "D:\\x")
      cpPortfolioPush pt @?= Just (Just "origin main")

caseServePingConfig :: IO ()
caseServePingConfig = withSystemTempDirectory "pm-pub-serve" $ \dir -> do
  let root = dir </> "root"
  (cfg0, _, _, _) <- fixture root
  let cfg = cfg0 {cfgPortfolioDir = Just root, cfgVaultPush = Just "origin main"}
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- getReq "/api/ping" [] tok
    liftIO' (field ["allowApply"] (decodeBody r) @?= Just (Aeson.Bool False))
    rc <- getReq "/api/config" [] tok
    liftIO' $ do
      field ["publish", "portfolioDir"] (decodeBody rc) @?= Just (Aeson.String (T.pack root))
      field ["publish", "vaultPush"] (decodeBody rc) @?= Just (Aeson.String "origin main")
      field ["publish", "portfolioPush"] (decodeBody rc) @?= Just Aeson.Null
  envA <- mkEnvA cfg
  flip runSession (serveApp envA) $ do
    r <- getReq "/api/ping" [] tok
    liftIO' (field ["allowApply"] (decodeBody r) @?= Just (Aeson.Bool True))

caseServePublishCommands :: IO ()
caseServePublishCommands = withSystemTempDirectory "pm-pub-cmds" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  envNone <- mkEnv cfg0
  flip runSession (serveApp envNone) $ do
    r <- getReq "/api/publish-commands" [] tok
    assertStatus 409 r
    liftIO' (assertBool "未配置应回 error" (field ["error"] (decodeBody r) /= Nothing))
  cfg <- withVault vdir cfg0
  env <- mkEnv (cfg {cfgVaultPush = Just "origin main"})
  flip runSession (serveApp env) $ do
    r <- getReq "/api/publish-commands" [] tok
    assertStatus 200 r
    liftIO' $ case field ["commands"] (decodeBody r) of
      Just (Aeson.Array xs) -> do
        length xs @?= 4
        assertBool "应含带目标的 push 行" (any (\v -> case v of Aeson.String t -> "push origin main" `T.isInfixOf` t; _ -> False) (foldr (:) [] xs))
      other -> assertFailure ("commands 应为数组: " <> show other)
