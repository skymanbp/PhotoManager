{-# LANGUAGE OverloadedStrings #-}

-- | P4-5…P4-8：@pm serve@ 的写端点（生成推送计划 / 「暂不同步」决定 /
-- 改配置 / 配置写入原语）。P7 自 "ServeTests" 拆出（750 行预算），
-- 用例逐字搬移；共享的 fixture 与请求原语仍在 "ServeTests"，从那里导入。
module ServeWriteTests (serveWriteTests) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void, when)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.List (isInfixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.Wai.Test
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeFile)
import System.FilePath (isAbsolute, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Config (Config (..), configFilePath, loadConfig, withConfigLock, writeConfig)
import Pm.Op (Op (..))
import Pm.Plan (ItemStatus (..), Plan (..), PlanItem (..), loadPlan)
import Pm.Serve (listPlans, serveApp)
import ServeTests (decodeBody, field, arrLen, fixture, getReq, liftIO', mkCfg, mkEnv, mkEnvW, mkHardLink, postReq, seedConfig, tok, withVault)

serveWriteTests :: TestTree
serveWriteTests =
  testGroup
    "P4-5…P4-8 pm serve 写端点（P7 自 ServeTests 拆出）"
    [ testCase "P4-5 POST /api/vault/push-plan：只读 serve → 403；坏 JSON/空指派/非法类目/非 NEW → 400；超大体 → 413" caseServePushPlanGuards
    , testCase "P4-5 POST /api/vault/push-plan：合法指派 → 计划落到 <vault>/.pm/plans，可经 loadPlan 装回，项与指派一致" caseServePushPlanOk
    , testCase "P4-6 POST /api/vault/push-plan：DRIFT-only（无 NEW）空指派 → 纯裁决计划；照片零改动" caseServePushPlanDrift
    , testCase "P4-7 POST /api/vault/hold：只读 403；标记后 new 移出、held 列出；同名同时标与撤 400；撤销恢复；被 hold 的不能 push" caseServeHold
    , testCase "P4-8 GET /api/config：路径与健康状态；主库恒 editable=false" caseServeConfigGet
    , -- 下面这些用例都动**同一份**配置（PM_CONFIG 是进程级环境变量，见
      -- Spec.hs）。tasty 缺省并行执行，必须显式串行化，否则互相踩：一个
      -- 用例占着配置锁的时候，另一个的合法写入会变成 409。
      dependentTestGroup
        "P4-8 配置（共用同一份 PM_CONFIG，必须串行）"
        AllFinish
        [ testCase "POST /api/config：只读 403；改主库/坏路径/坏并发数/空补丁 → 400 且配置不动" caseServeConfigGuards
        , testCase "POST /api/config：\"main\": null 也是「动主库」→ 400，同请求里的 workers 一并不落地" caseServeConfigMainNull
        , testCase "POST /api/config：合法改动落到 PM_CONFIG 指向的文件，且同一 serve 立刻按新配置回答" caseServeConfigWrite
        , testCase "POST /api/config：配置锁被别的 pm 占着 → 409，配置零改动" caseServeConfigLock
        , testCase "writeConfig：config.toml.tmp 被 hardlink 占名 → 不穿透写，库外文件零改动" caseConfigTmpHardlink
        , testCase "loadConfig：正文缺失而残留 .tmp → 指出这是中断的写入并给恢复动作，不当\"配置不存在\"" caseConfigOrphanTmp
        , testCase "第一方自审 R4：配置路径须绝对——writeConfig 写前绝对化；手编相对路径 loadConfig 拒" caseConfigAbsolutePaths
        ]
    ]

-- | P4-5 的闸：写开关、JSON、指派校验（与 CLI 共用 'checkAssignments'）、体上限。
-- 每条对应一处判定；删掉判定用例转红。
caseServePushPlanGuards :: IO ()
caseServePushPlanGuards = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  let good = "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"}]}"
  -- 只读 serve：403，且 .pm/plans 不出现
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- postReq "/api/vault/push-plan" good
    assertStatus 403 r
  doesDirectoryExist (vdir </> ".pm") >>= (@?= False)
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r1 <- postReq "/api/vault/push-plan" "{not json"
    assertStatus 400 r1
    r2 <- postReq "/api/vault/push-plan" "{\"assignments\":[]}"
    assertStatus 400 r2
    r3 <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"nope\"}]}"
    assertStatus 400 r3
    liftIO' (assertBool "应报类目不存在" ("nope" `BS.isInfixOf` BSL.toStrict (simpleBody r3)))
    r4 <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"ghost.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4
    -- 同一 name 指派两个类目：逐条都合法，但会出两个 Copy → 必须整体拒（二十轮 minor）
    r4a <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"},{\"name\":\"a.jpg\",\"category\":\"portrait\"}]}"
    assertStatus 400 r4a
    liftIO' (assertBool "应列出两个冲突类目" ("landscape portrait" `BS.isInfixOf` BSL.toStrict (simpleBody r4a)))
    -- 同一 name 同类目重复两次：同样是两个 Copy
    r4b <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"landscape\"},{\"name\":\"a.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4b
    -- 类目大小写变体不是别名（fixedCategories 精确匹配）
    r4c <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"Landscape\"}]}"
    assertStatus 400 r4c
    -- 带路径分隔符的 name：NEW 只有平铺 basename → 不在集合里
    r4d <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"../a.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4d
    r4e <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"sub\\a.jpg\",\"category\":\"landscape\"}]}"
    assertStatus 400 r4e
    -- 超过 64 KiB 的体：413，不解析
    r5 <- postReq "/api/vault/push-plan" (BSL.fromStrict (BS.replicate (70 * 1024) 32))
    assertStatus 413 r5
    -- GET 不是端点
    r6 <- getReq "/api/vault/push-plan" [] tok
    assertStatus 404 r6
  -- 全部被拒 → 没有任何计划落盘，vault 的 .pm 也不该被建出来（连 root-id 都不建）
  (ps, _) <- listPlans vdir
  ps @?= []
  doesDirectoryExist (vdir </> ".pm") >>= (@?= False)

-- | 合法指派：计划写进 vault root 的 .pm/plans，响应带计划 + 路径 + apply 提示；
-- 用 loadPlan 从盘上装回，项数与目标路径与指派一致；照片零改动。
caseServePushPlanOk :: IO ()
caseServePushPlanOk = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, sj, _) <- fixture root
  cfg <- withVault vdir cfg0
  env <- mkEnvW cfg
  pid <- flip runSession (serveApp env) $ do
    r <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"portrait\"}]}"
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      arrLen (field ["plan", "items"] v) @?= Just 1
      field ["plan", "kind"] v @?= Just (Aeson.String "vault-push")
      case field ["plan", "id"] v of
        Just (Aeson.String p) -> pure p
        other -> assertFailure ("响应缺 plan.id: " <> show other)
  ep <- loadPlan vdir pid
  case ep of
    Left e -> assertFailure ("loadPlan 应装回: " <> e)
    Right plan -> do
      plKind plan @?= "vault-push"
      map (opDstRel . piOp) (plItems plan) @?= ["portrait" </> "a.jpg"]
      map (opSha . piOp) (plItems plan) @?= [sj]
  -- 照片零改动、vault 类目目录仍空（只生成计划，不执行）
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)
  doesFileExist (vdir </> "portrait" </> "a.jpg") >>= (@?= False)

-- | P4-6：vault 只有 DRIFT（同名内容不同）、没有 NEW 时，空 assignments 也要
-- 能出一份纯裁决计划——否则 GUI 的「生成推送计划」按钮永远灰着（二十轮 minor）。
-- 计划项是 NEEDS-DECISION，vault 与相册的字节都不动。把「空指派 → 400」改回
-- 无条件，本例转红。
caseServePushPlanDrift :: IO ()
caseServePushPlanDrift = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  let vaultCopy = vdir </> "landscape" </> "a.jpg"
      otherBytes = "\xFF\xD8\xFF\xE0JFIF-vault-side-bytes"
  BS.writeFile vaultCopy otherBytes
  env <- mkEnvW cfg
  pid <- flip runSession (serveApp env) $ do
    r <- postReq "/api/vault/push-plan" "{\"assignments\":[]}"
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      arrLen (field ["plan", "items"] v) @?= Just 1
      case field ["plan", "id"] v of
        Just (Aeson.String p) -> pure p
        other -> assertFailure ("响应缺 plan.id: " <> show other)
  ep <- loadPlan vdir pid
  case ep of
    Left e -> assertFailure ("loadPlan 应装回: " <> e)
    Right plan -> do
      map (opDstRel . piOp) (plItems plan) @?= ["landscape" </> "a.jpg"]
      case map piStatus (plItems plan) of
        [StNeedsDecision _] -> pure ()
        other -> assertFailure ("DRIFT 项应为 NEEDS-DECISION: " <> show other)
  -- 只生成计划：两侧字节都没动
  BS.readFile vaultCopy >>= (@?= otherBytes)
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)

-- | P4-7：第二个写端点。决定只落主库 @.pm/vault-holds.json@——照片与 vault
-- 零改动；只读 serve 拒绝；标记后该名字从 @/api/vault/new@ 的 new 移到 held，
-- 且不再能 push；撤销后回到 new。去掉 seWritable 闸或 holdRequest 的任一条
-- 判定，本例转红。
caseServeHold :: IO ()
caseServeHold = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, jpgBytes, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- postReq "/api/vault/hold" "{\"hold\":[\"a.jpg\"]}"
    assertStatus 403 r
  doesFileExist (root </> ".pm" </> "vault-holds.json") >>= (@?= False)
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r0 <- getReq "/api/vault/new" [] tok
    liftIO' (arrLen (field ["new"] (decodeBody r0)) @?= Just 1)
    -- 同一名字同时标记与撤销：整体拒
    rBad <- postReq "/api/vault/hold" "{\"hold\":[\"a.jpg\"],\"unhold\":[\"a.jpg\"]}"
    assertStatus 400 rBad
    -- 不是 NEW 的名字：拒
    rGhost <- postReq "/api/vault/hold" "{\"hold\":[\"ghost.jpg\"]}"
    assertStatus 400 rGhost
    r1 <- postReq "/api/vault/hold" "{\"hold\":[\"a.jpg\"]}"
    assertStatus 200 r1
    liftIO' (arrLen (field ["held"] (decodeBody r1)) @?= Just 1)
    r2 <- getReq "/api/vault/new" [] tok
    liftIO' $ do
      arrLen (field ["new"] (decodeBody r2)) @?= Just 0
      arrLen (field ["held"] (decodeBody r2)) @?= Just 1
    -- 已决定暂不同步 → 生成计划端点拒收
    r3 <- postReq "/api/vault/push-plan" "{\"assignments\":[{\"name\":\"a.jpg\",\"category\":\"portrait\"}]}"
    assertStatus 400 r3
    r4 <- postReq "/api/vault/hold" "{\"unhold\":[\"a.jpg\"]}"
    assertStatus 200 r4
    r5 <- getReq "/api/vault/new" [] tok
    liftIO' (arrLen (field ["new"] (decodeBody r5)) @?= Just 1)
  -- 照片与 vault 类目目录零改动
  BS.readFile (root </> "相册" </> "a.jpg") >>= (@?= jpgBytes)
  doesFileExist (vdir </> "portrait" </> "a.jpg") >>= (@?= False)

-- | P4-8 设置页的只读视图：路径 + 每条路径的健康状态；主库这一项恒
-- @editable:false@（它是身份锚点，改它等于换一个库）。
caseServeConfigGet :: IO ()
caseServeConfigGet = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  env <- mkEnv cfg
  flip runSession (serveApp env) $ do
    r <- getReq "/api/config" [] tok
    assertStatus 200 r
    let v = decodeBody r
    liftIO' $ do
      field ["main", "path"] v @?= Just (Aeson.String (T.pack root))
      field ["main", "editable"] v @?= Just (Aeson.Bool False)
      field ["main", "root"] v @?= Just (Aeson.String "present")
      field ["vault", "path"] v @?= Just (Aeson.String (T.pack vdir))
      field ["vault", "exists"] v @?= Just (Aeson.Bool True)
      -- 未设的项是 null，不是漏键
      field ["photosJson"] v @?= Just Aeson.Null

-- | P4-8 写端点的闸：只读 serve 拒绝；主库路径只读；不存在的 vault 目录、
-- 越界并发数、空补丁一律拒——且**配置文件在任何一条拒绝后都不能被改写**。
caseServeConfigGuards :: IO ()
caseServeConfigGuards = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  envR <- mkEnv cfg
  flip runSession (serveApp envR) $ do
    r <- postReq "/api/config" "{\"workers\":4}"
    assertStatus 403 r
  envW <- mkEnvW cfg
  flip runSession (serveApp envW) $ do
    r1 <- postReq "/api/config" "{\"main\":\"D:\\\\elsewhere\"}"
    assertStatus 400 r1
    -- 断言用 ASCII 子串：中文字面量经 OverloadedStrings 变 ByteString 会按 8 位截断
    liftIO' (assertBool "应指向 pm init（主库只读）" ("pm init" `BS.isInfixOf` BSL.toStrict (simpleBody r1)))
    r2 <- postReq "/api/config" "{\"vault\":\"D:\\\\no-such-dir-for-pm-test\"}"
    assertStatus 400 r2
    r3 <- postReq "/api/config" "{\"workers\":0}"
    assertStatus 400 r3
    r4 <- postReq "/api/config" "{\"workers\":999}"
    assertStatus 400 r4
    r5 <- postReq "/api/config" "{}"
    assertStatus 400 r5
    r6 <- postReq "/api/config" "{not json"
    assertStatus 400 r6
    -- 拒绝之后 GET 仍是原来的 vault 路径（配置没被动过）
    r7 <- getReq "/api/config" [] tok
    liftIO' (field ["vault", "path"] (decodeBody r7) @?= Just (Aeson.String (T.pack vdir)))

-- | P4-8 合法路径：改动写进 **PM_CONFIG 指向的**文件（Spec.hs 把整个测试进程
-- 指到临时文件——配置路径是机器全局的，没有这道缝，一次写成功就会覆盖使用者
-- 本机的 config.toml），且同一个 serve 进程立刻按新配置回答（cfg 是 IORef，
-- 每次请求读一次）。把 IORef 改回启动时快照，本例的第二次 GET 会转红。
caseServeConfigWrite :: IO ()
caseServeConfigWrite = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
      vdir2 = dir </> "vault2"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  createDirectoryIfMissing True vdir2
  seedConfig root
  cfgFile <- configFilePath
  env <- mkEnvW cfg
  flip runSession (serveApp env) $ do
    r1 <- postReq "/api/config" (BSL.fromStrict (TE.encodeUtf8 (T.pack ("{\"vault\":" <> show vdir2 <> ",\"workers\":3}"))))
    assertStatus 200 r1
    -- 同一个 serve，立刻按新配置回答
    r2 <- getReq "/api/config" [] tok
    liftIO' $ do
      field ["vault", "path"] (decodeBody r2) @?= Just (Aeson.String (T.pack vdir2))
      field ["workers"] (decodeBody r2) @?= Just (Aeson.Number 3)
  -- 落到 PM_CONFIG 指向的文件里（而不是使用者本机的配置）
  -- 按 UTF-8 读：配置文件头是中文注释，locale 解码器（本机 CP936）会炸
  raw <- BS.readFile cfgFile
  let txt = T.unpack (TE.decodeUtf8 raw)
  assertBool ("配置文件应含新 vault 路径: " <> txt) (vdir2 `isInfixOf` txt)

-- | 二十四轮 minor：三态里 @main@ 这一格原本用 aeson 的 @.:?@ 解析，于是
-- "键缺省"与"键为 null"塌成同一个 'Nothing'——@{"main":null,"workers":3}@
-- 会**静默忽略 main、照改 workers 并回 200**，正好绕开这个字段唯一的用途。
-- 把 @fld "main"@ 换回 @.:?@，本例转红。
caseServeConfigMainNull :: IO ()
caseServeConfigMainNull = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  env <- mkEnvW cfg
  flip runSession (serveApp env) $ do
    r <- postReq "/api/config" "{\"main\":null,\"workers\":7}"
    assertStatus 400 r
    liftIO' (assertBool "应指向 pm init（主库只读）" ("pm init" `BS.isInfixOf` BSL.toStrict (simpleBody r)))
    -- fail-closed：一条不合法则整体不写，同请求里的 workers 也不能落地
    r2 <- getReq "/api/config" [] tok
    liftIO' (field ["workers"] (decodeBody r2) @?= Just Aeson.Null)

-- | 二十四轮 minor：配置的读改写是**跨进程**事务。锁被另一个 pm 占着时必须
-- 拒绝，而不是各读各的旧配置、后写者把先写者那一项抹掉。去掉
-- 'withConfigLock' 这一层，写会成功回 200，本例转红。
caseServeConfigLock :: IO ()
caseServeConfigLock = withSystemTempDirectory "pm-serve" $ \dir -> do
  let root = dir </> "root"
      vdir = dir </> "vault"
  (cfg0, _, _, _) <- fixture root
  cfg <- withVault vdir cfg0
  env <- mkEnvW cfg
  seedConfig root
  fp <- configFilePath
  before <- BS.readFile fp
  gotLock <- newEmptyMVar
  release <- newEmptyMVar
  void . forkIO . void $ withConfigLock (putMVar gotLock () >> takeMVar release)
  takeMVar gotLock
  flip runSession (serveApp env) $ do
    r <- postReq "/api/config" "{\"workers\":5}"
    assertStatus 409 r
  putMVar release ()
  after' <- BS.readFile fp
  after' @?= before

-- | 二十四轮 minor：配置曾是 pm 里**唯一**不走「独占建 tmp → flush 到盘 →
-- no-replace 改名」的状态写入口（只因为它不在任何 root 的 @.pm@ 下，于是没
-- 继承那套纪律）。裸 'BS.writeFile' 会**穿透** @config.toml.tmp@ 这个名字上
-- 的 hardlink，把字节写进库外那个共享对象；'Pm.Win.openFreshBinary' 先 unlink
-- 名字再独占创建，库外文件零改动。把 writeConfig 换回 BS.writeFile，本例转红。
caseConfigTmpHardlink :: IO ()
caseConfigTmpHardlink = withSystemTempDirectory "pm-serve" $ \dir -> do
  seedConfig (dir </> "root")
  fp <- configFilePath
  before <- BS.readFile fp
  let outside = dir </> "outside.txt"
      tmp = fp <> ".tmp"
  BS.writeFile outside "OUTSIDE"
  existsTmp <- doesFileExist tmp
  when existsTmp (removeFile tmp)
  mkHardLink tmp outside
  _ <- writeConfig (mkCfg (dir </> "root2"))
  BS.readFile outside >>= (@?= "OUTSIDE")
  _ <- BS.writeFile fp before -- 收尾：把配置放回去，同组后面的用例还要用
  pure ()

-- | 二十四轮 minor：'writeConfig' 的「删旧 → 改名」之间崩掉，会只剩内容完整的
-- @<fp>.tmp@。把这种局面一律解释成"配置不存在，去 pm init"会让人重建一份、
-- 把刚改的设置丢掉。删掉 loadConfig 里的残留探测，本例转红。
caseConfigOrphanTmp :: IO ()
caseConfigOrphanTmp = withSystemTempDirectory "pm-serve" $ \dir -> do
  seedConfig (dir </> "root")
  fp <- configFilePath
  raw <- BS.readFile fp
  removeFile fp
  BS.writeFile (fp <> ".tmp") raw
  r <- loadConfig
  BS.writeFile fp raw -- 先恢复，再断言（断言失败也不留坏配置给后面的用例）
  removeFile (fp <> ".tmp")
  case r of
    Right _ -> assertFailure "正文缺失时不应当读成功"
    Left m -> assertBool ("应指出残留 .tmp 与恢复动作: " <> m) (".tmp" `isInfixOf` m)

-- | 第一方自审 R4：相对路径按进程 cwd 解析，`pm ui` 拉起的 serve 与终端里的
-- pm 各有各的 cwd——同一份配置会指向两个地方。写侧入库前绝对化（`pm init
-- --main .` 这类键入不落成相对路径）；读侧拒手编的相对路径。
caseConfigAbsolutePaths :: IO ()
caseConfigAbsolutePaths = do
  fp <- configFilePath
  had <- doesFileExist fp
  before <- if had then Just <$> BS.readFile fp else pure Nothing
  -- 写侧：相对 main 路径 → 盘上是绝对路径，读回不被绝对路径闸拒
  _ <- writeConfig (mkCfg "relmain")
  ec <- loadConfig
  -- 读侧：手编相对路径 → Left（不猜 cwd）
  writeFile fp "[main]\npath = 'rel\\dir'\n"
  ec2 <- loadConfig
  maybe (removeFile fp) (BS.writeFile fp) before -- 先恢复现场再断言（同 caseConfigOrphanTmp）
  case ec of
    Left m -> assertFailure ("写侧绝对化后应能读回: " <> m)
    Right c -> assertBool ("main.path 应已绝对化: " <> cfgMainPath c) (isAbsolute (cfgMainPath c))
  case ec2 of
    Right c -> assertFailure ("手编相对路径应拒: " <> cfgMainPath c)
    Left m -> assertBool m ("绝对路径" `isInfixOf` m)

