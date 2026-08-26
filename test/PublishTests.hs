{-# LANGUAGE OverloadedStrings #-}

-- | P7：上线命令生成（'Pm.Publish'）＋配置发布字段（portfolio 仓路径、
-- 两个 push 目标）＋ serve 侧的三处接线（ping 的 allowApply、config 的
-- publish 对象、GET \/api\/publish-commands）。
--
-- 每条用例钉一道闸：
--   * 路径与 push 目标都是**解析后重渲染**（40 轮 #2/#4 的上游根因：黑名单
--     过滤后原样拼接补不全）——白名单语法、'/' 分隔、操作数前 @--@；
--   * 汇点复验——手编 config.toml 绕过 checkPatch 的值在生成处再拒，整体不出；
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
import Pm.Publish (cmdPath, pathArgOk, publishCommands, pushTarget, pushTargetOk, renderCmdPath, vaultCommands)
import Pm.Serve (serveApp)
import ServeTests (decodeBody, field, fixture, getReq, liftIO', mkCfg, mkEnv, mkEnvA, tok, withVault)

publishTests :: TestTree
publishTests =
  testGroup
    "P7 上线命令与发布配置"
    [ testCase "pushTarget：<remote> [<refspec>] 语法；选项/强推/删除形态与能长出第二条命令的字符一律拒" casePushTarget
    , testCase "cmdPath：盘符绝对路径 + 白名单分量 → '/' 重渲染；UNC/相对/../空分量/尾随点/引号终结符拒" caseCmdPath
    , testCase "publishCommands：显式类目 add --、photos.json 仓内相对路径 add --、缺配/仓外拒绝生成、push -- 目标" casePublishCommands
    , testCase "汇点复验（39/40 轮）：手编配置绕过 checkPatch 的路径/push 目标/选项注入在生成处再拒，整体不出" casePublishSinkGuards
    , testCase "vaultCommands（第一方自审 R2）：push 收尾与上线命令同一生成点——push 目标取自设置、类目白名单、坏值拒" caseVaultCommands
    , testCase "配置 round-trip：发布字段 + 含单引号路径写盘后逐字段读回（39 轮 #3 tomlStr）" caseConfigRoundTrip
    , testCase "checkPatch：portfolio 仓路径须存在且可嵌命令；坏 push 目标拒；JSON 三态（null = 清空）" casePublishPatch
    , testCase "serve：ping 带 allowApply（与授权级一致）；config 带 publish 对象" caseServePingConfig
    , testCase "GET /api/publish-commands：未配置 → 409；配置 vault 后 → 200 + 命令行数组" caseServePublishCommands
    ]

casePushTarget :: IO ()
casePushTarget = do
  mapM_ (\t -> assertBool (t <> " 应放行") (pushTargetOk t))
    ["origin main", "origin", "git@github.com:u/r.git main", "https://github.com/u/r.git HEAD:main", "up-stream v1.0_rc~1"]
  pushTarget "origin main" @?= Right ["origin", "main"]
  mapM_ (\t -> assertBool (show t <> " 应拒") (not (pushTargetOk t)))
    [ "", "a;b", "a|b", "a&b", "a`b", "a$b", "a'b", "a\"b", "a\nb", "a>b", "a(b)", replicate 201 'x'
    -- 40 轮 #2：字符都合法但**位置**是选项/强推/删除——段首必须字母数字
    , "-f origin main", "--mirror origin", "origin -f", "+refs/heads/main:refs/heads/main", "origin :main"
    -- 段数与空白：三段、双空格、首尾空格
    , "a b c", "origin  main", " origin main", "origin main "
    ]

-- 路径字面量全是合成夹具（fixture）：cmdPath 是纯函数，只做解析与重渲染，不触盘。
caseCmdPath :: IO ()
caseCmdPath = do
  -- 分量 CJK/空格/'/() 放行；尾随分隔符归一；'\\' 与 '/' 同义；盘符大小写保留
  fmap renderCmdPath (cmdPath "D:\\展示集\\摄影作品") @?= Right "D:/展示集/摄影作品"
  fmap renderCmdPath (cmdPath "D:\\x\\y\\") @?= Right "D:/x/y"
  fmap renderCmdPath (cmdPath "d:/a b/O'Brien (2)") @?= Right "d:/a b/O'Brien (2)"
  fmap renderCmdPath (cmdPath "D:\\") @?= Right "D:/"
  mapM_ (\p -> assertBool (p <> " 应放行") (pathArgOk p))
    ["D:\\some dir\\pics", "D:/a/b.json", "E:\\o b\\pf"]
  mapM_ (\p -> assertBool (show p <> " 应拒") (not (pathArgOk p)))
    [ "", "D:\\repo$(calc)", "D:\\a`b", "D:\\a\"b", "D:\\a%x%", "D:\\a!b", "D:\\a\nb"
    -- 40 轮 #2：bash 双引号内尾随 '\' 撑开引号 + ';' 合法 Windows 路径
    , "D:\\safe;whoami;\\", "D:\\a;b"
    -- 形态：UNC / 相对 / 无分隔符 / 选项样 / 越级 / 空分量 / 尾随点或空格 / 超长
    , "\\\\server\\share\\x", "relative\\path", "D:x", "-A", "D:\\a\\..\\b", "D:\\a\\.\\b", "D:\\\\a", "D:\\a.", "D:\\a \\b"
    , "D:\\" <> replicate 240 'x'
    ]

-- 本文件所有盘符路径都是**合成夹具**（fixture）：publishCommands 是纯函数，
-- 只做字符串组装，不触盘——路径字面量在断言里与生成文本逐字对照，不指向
-- 任何真实机器位置。
casePublishCommands :: IO ()
casePublishCommands = do
  let base = mkCfg "D:\\Photography"
  -- 全未配：Left 指路设置页
  case publishCommands base of
    Left m -> assertBool ("应指路设置页: " <> m) ("设置" `isInfixOf` m)
    Right ls -> assertFailure ("未配置竟有命令: " <> show ls)
  -- 只配 vault：一段四行；显式类目 add --（永不 add -A），push -- 目标，路径 '/' 重渲染
  let cv = base {cfgVaultPath = Just "D:\\展示集\\摄影作品\\", cfgVaultPush = Just "origin main"}
  case publishCommands cv of
    Left m -> assertFailure m
    Right ls -> do
      length ls @?= 4
      assertBool "展示集必须显式类目 add --" ("git -C \"D:/展示集/摄影作品\" add -- landscape portrait urban" `elem` ls)
      assertBool "push 行应带 -- 与目标" ("git -C \"D:/展示集/摄影作品\" push -- origin main" `elem` ls)
      structural ls
  -- vault + portfolio + photos.json：portfolio 段 add -- 仓内相对路径（仓路径大小写不同也算仓内）
  let cb =
        cv
          { cfgPortfolioDir = Just "D:\\proj\\pf"
          , cfgPhotosJson = Just "d:/Proj/PF/data/photos.json"
          , cfgPortfolioPush = Nothing
          }
  case publishCommands cb of
    Left m -> assertFailure m
    Right ls -> do
      assertBool ("photos.json 必须按仓内相对路径 add --: " <> show ls) ("git -C \"D:/proj/pf\" add -- \"data/photos.json\"" `elem` ls)
      assertBool "未设 push 目标 → 裸 git push" ("git -C \"D:/proj/pf\" push" `elem` ls)
      structural ls
  -- 只配 portfolio、未配 photos.json：拒绝生成（不退化成整仓 add）
  case publishCommands base {cfgPortfolioDir = Just "D:\\proj\\pf"} of
    Left m -> assertBool ("应点名 photos.json: " <> m) ("photos.json" `isInfixOf` m)
    Right ls -> assertFailure ("未配 photos.json 竟生成了: " <> show ls)
  -- photos.json 不在 portfolio 仓内：拒绝（仓外 add 只会让 git 报错，但更该在生成处说清）
  case publishCommands base {cfgPortfolioDir = Just "D:\\proj\\pf", cfgPhotosJson = Just "D:\\other\\photos.json"} of
    Left m -> assertBool ("应点名仓内: " <> m) ("仓内" `isInfixOf` m)
    Right ls -> assertFailure ("仓外 photos.json 竟生成了: " <> show ls)
 where
  -- 结构钉：任何 add/push 行的操作数前都有 --；任何一行不含 add -A；命令行里没有反斜杠
  structural ls = do
    assertBool "任何一行都不得含 add -A" (not (any ("add -A" `isInfixOf`) ls))
    assertBool ("add/push 的操作数前必须有 --: " <> show ls)
      (all (\l -> not (" add " `isInfixOf` l) || " add -- " `isInfixOf` l) ls
        && all (\l -> not (" push " `isInfixOf` l) || " push -- " `isInfixOf` l) ls)
    assertBool ("命令行里不得出现反斜杠: " <> show ls) (not (any ('\\' `elem`) (filter (not . ("#" `isPrefixOf`)) ls)))

-- | 生成是唯一汇点——手编 config.toml 绕过 checkPatch 的值必须在这里被再验
-- 一次；含 shell 展开字符、引号终结符或选项形态的值整体拒绝，不出半块可疑文本。
-- （路径字面量同上为合成夹具，纯函数断言用，不触盘。）
casePublishSinkGuards :: IO ()
casePublishSinkGuards = do
  let base = mkCfg "D:\\Photography"
      refuse what cfg = case publishCommands cfg of
        Left _ -> pure ()
        Right ls -> assertFailure (what <> " 竟生成了: " <> show ls)
  -- 39 轮：路径含 $()；40 轮：尾随 '\' + ';' 的合法 Windows 路径
  case publishCommands base {cfgVaultPath = Just "D:\\repo$(calc)"} of
    Left m -> assertBool ("应指出无法嵌入: " <> m) ("嵌入" `isInfixOf` m)
    Right ls -> assertFailure ("危险路径竟生成了: " <> show ls)
  refuse "尾随反斜杠 + 分号路径" base {cfgVaultPath = Just "D:\\safe;whoami;\\"}
  -- 手编 push 目标绕过 checkPatch：汇点必须再拒——字符类与选项类各一
  case publishCommands base {cfgVaultPath = Just "D:\\v", cfgVaultPush = Just "origin; calc"} of
    Left m -> assertBool ("应点名 push 目标: " <> m) ("push" `isInfixOf` m)
    Right ls -> assertFailure ("坏 push 目标竟生成了: " <> show ls)
  -- 判别力：两段、字符全在白名单内，只有「段首须字母数字」能拒它们（三段的
  -- `-f origin main` 会先被段数拒，钉不住段首规则）
  refuse "选项形态 push 目标" base {cfgVaultPath = Just "D:\\v", cfgVaultPush = Just "--mirror origin"}
  refuse "选项在第二段" base {cfgVaultPath = Just "D:\\v", cfgVaultPush = Just "origin -f"}
  refuse "强推 refspec" base {cfgVaultPath = Just "D:\\v", cfgVaultPush = Just "origin +main:main"}
  -- 40 轮 #4：手编 photos.json = "-A" → 不是盘符绝对路径，拒；不能变成 git add "-A"
  refuse "photos.json 选项注入" base {cfgPortfolioDir = Just "D:\\pf", cfgPhotosJson = Just "-A"}
  -- 一侧坏则整体不出：portfolio 合法也不能带出半块
  refuse "一侧坏整体拒" base {cfgVaultPath = Just "D:\\a$b", cfgPortfolioDir = Just "D:\\pf", cfgPhotosJson = Just "D:\\pf\\p.json"}

-- | R2：'Pm.Vault.gitStepsLines' 与「复制上线命令」都走这一个生成器——push
-- 目标取自设置（旧第二生成器硬打 origin main）、路径解析后重渲染、操作数前
-- @--@、类目按固定名单验、commit 信息按白名单验。
caseVaultCommands :: IO ()
caseVaultCommands = do
  let base = (mkCfg "D:\\Photography") {cfgVaultPath = Just "D:\\v"}
  vaultCommands base "D:\\v" ["landscape"] "photos: pm vault push p1"
    @?= Right
      [ "git -C \"D:/v\" add -- landscape"
      , "git -C \"D:/v\" commit -m \"photos: pm vault push p1\""
      , "git -C \"D:/v\" push"
      ]
  vaultCommands base {cfgVaultPush = Just "origin main"} "D:\\v" ["urban"] "m1"
    @?= Right
      [ "git -C \"D:/v\" add -- urban"
      , "git -C \"D:/v\" commit -m \"m1\""
      , "git -C \"D:/v\" push -- origin main"
      ]
  let refuse lbl r = either (const (pure ())) (\v -> assertFailure (lbl <> " 应拒: " <> show v)) r
  refuse "空类目（add -- 空表 = commit 空）" (vaultCommands base "D:\\v" [] "m")
  refuse "白名单外类目（-A 形态）" (vaultCommands base "D:\\v" ["-A"] "m")
  refuse "嵌不进命令的路径" (vaultCommands base "D:\\v;x" ["landscape"] "m")
  refuse "坏 push 目标" (vaultCommands base {cfgVaultPush = Just "--mirror origin"} "D:\\v" ["landscape"] "m")
  refuse "commit 信息含引号" (vaultCommands base "D:\\v" ["landscape"] "a\"b")

caseConfigRoundTrip :: IO ()
caseConfigRoundTrip = do
  -- PM_CONFIG 指向 Spec.hs 的临时文件（机器全局配置由测试进程整体隔离）。
  -- vault 路径故意含单引号（39 轮 #3）：能过 checkPatch 的合法目录名，裸拼
  -- literal 单引号会写出非法 TOML 并顶掉正式配置——tomlStr 必须退到 basic
  -- string 且反斜杠转义后逐字段读回。
  let c =
        (mkCfg "D:\\Photography")
          { cfgVaultPath = Just "D:\\O'Brien\\v"
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
  -- 目录在、但嵌不进命令行（';' 是合法目录名字符）：这项只用于生成命令，入口即拒
  createDirectoryIfMissing True (dir </> "bad;dir")
  e2b <- checkPatch emptyPatch {cpPortfolioDir = Just (Just (dir </> "bad;dir"))}
  assertBool ("嵌不进命令的 portfolio 路径应拒: " <> show e2b) (any ("嵌入" `isInfixOf`) e2b)
  -- push 目标过语法闸：字符类与选项类
  e3 <- checkPatch emptyPatch {cpVaultPush = Just (Just "origin; rm -rf")}
  assertBool "带分号的 push 目标应拒" (not (null e3))
  e3b <- checkPatch emptyPatch {cpPortfolioPush = Just (Just "--mirror origin")}
  assertBool "选项形态 push 目标应拒" (not (null e3b))
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
        assertBool "应含带目标的 push -- 行" (any (\v -> case v of Aeson.String t -> "push -- origin main" `T.isInfixOf` t; _ -> False) (foldr (:) [] xs))
      other -> assertFailure ("commands 应为数组: " <> show other)
