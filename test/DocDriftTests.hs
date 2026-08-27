-- | 文档—代码漂移哨兵（P7-J，簇 E）：DESIGN.md 里的**据实清点**类声明
-- （字节出口、配置锁调用点、--json 旗标、GUI 页序、CSP 逐字）直接以仓库
-- 文件为证据重新清点。清点漂移是本项目审出的高频形态：文档说 N 处、代码
-- 已是 N+1 处——文字改对一次会再错，只有测试能一直盯着。
--
-- 读文件一律 ByteString + UTF-8 lenient 解码：测试进程跑在 GBK locale 下，
-- String 版 readFile 会按本地码页解码仓库里的 UTF-8 文件（Hash.hs 家规的
-- 文本版）。
module DocDriftTests (docDriftTests) where

import qualified Data.ByteString as BS
import Data.Char (isDigit, isSpace)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, isSuffixOf, sort)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

docDriftTests :: TestTree
docDriftTests =
  testGroup
    "P7-J 文档—代码漂移哨兵"
    [ testCase "字节出口清点：deleteBoundAt 引用模块集合固定；Exec 头注不再写 no delete call anywhere" caseByteExitCensus
    , testCase "配置锁清点：withConfigLock 调用模块集合 = DESIGN 声明的四条读改写路径" caseConfigLockCensus
    , testCase "--json 清点：全 CLI 只有 vault status 一处 long \"json\"" caseJsonFlagCensus
    , testCase "GUI 页序：DESIGN ①—⑥ 的顺序与 index.html 的 nav 次序一致" caseGuiNavOrder
    , testCase "CSP 逐字：DESIGN 引用的指令逐条出现在 tauri.conf.json 的 csp 里" caseCspQuoted
    , testCase "死名清扫：opRelPaths / isPng / stemKey 不再出现在 src/app" caseNoDeadNames
    , testCase "Haddock 标记卫生：一段连续注释里至多一个 -- | / -- ^ 标记" caseHaddockMarkerHygiene
    , testCase "讹传清扫：F048 被否证的机制解释不再出现在 test/" caseFolkloreNotInTests
    , testCase "命名同步：DESIGN-COMMANDS 讲的是 freshStagingCatalog（F025 收尾）" caseFreshGateName
    , testCase "41 轮 GO-note #9 运行契约：cwd = 仓库根（本套件按根相对路径读仓库文件）" caseRepoRootCwd
    , testCase "41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托 REVIEW-LOG" caseReadmeSync
    , testCase "0.6.0 发布链：pm.exe 不带构建机路径——Main.hs 不用 Paths 模块、版本走 CPP 宏、exe 段显式 other-modules" caseNoPathsModule
    ]

-- ─── 基础设施 ────────────────────────────────────────────────────────────────

readUtf8 :: FilePath -> IO String
readUtf8 fp = T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile fp

-- | src/Pm 全部模块 + app/Main.hs，(展示名, 路径)。
srcModules :: IO [(String, FilePath)]
srcModules = do
  ms <- sort . filter (".hs" `isSuffixOf`) <$> listDirectory ("src" </> "Pm")
  pure ([(m, "src" </> "Pm" </> m) | m <- ms] <> [("Main.hs", "app" </> "Main.hs")])

strip :: String -> String
strip = dropWhileEnd isSpace . dropWhile isSpace

isCommentLine :: String -> Bool
isCommentLine = ("--" `isPrefixOf`) . strip

-- | 文件里**非注释行**是否引用了名字（import 行也算：调用清点问的是「哪些
-- 模块与它有关」，import 即关联）。
refsIn :: String -> String -> Bool
refsIn name s = any (\l -> not (isCommentLine l) && name `isInfixOf` l) (lines s)

-- | name 的引用模块清单（排除 excl 定义地）。
refModules :: String -> [String] -> IO [String]
refModules name excl = do
  ms <- srcModules
  found <- mapM (\(m, fp) -> (\s -> [m | refsIn name s]) <$> readUtf8 fp) ms
  pure (sort (filter (`notElem` excl) (concat found)))

-- ─── 用例 ────────────────────────────────────────────────────────────────────

-- | DESIGN.md:178「照片字节只有三个出口，各自职权不同（据实清点，
-- `moveBoundNoReplace` / `deleteBoundAt` 全仓调用点）」——这里重新清点
-- deleteBoundAt 侧。集合一变（新增出口/挪了出口），本用例转红，逼着改文档。
caseByteExitCensus :: IO ()
caseByteExitCensus = do
  refs <- refModules "deleteBoundAt" ["Win.hs"]
  refs @?= ["Catalog.hs", "Commands.hs", "Config.hs", "Doctor.hs", "Exec.hs", "Plan.hs"]
  exec <- readUtf8 ("src" </> "Pm" </> "Exec.hs")
  assertBool "Exec 头注不得再过度声明（工作流 F003）" (not ("no delete call anywhere" `isInfixOf` exec))
  design <- readUtf8 ("docs" </> "DESIGN.md")
  assertBool "DESIGN §4 的据实清点声明还在" ("照片字节只有三个出口" `isInfixOf` design)

-- | DESIGN.md:574「**四条**读改写路径共用（… 全仓 `withConfigLock` 调用点
-- 即此四处）」。
caseConfigLockCensus :: IO ()
caseConfigLockCensus = do
  refs <- refModules "withConfigLock" ["Config.hs"]
  refs @?= ["BackupCmd.hs", "Commands.hs", "ConfigEdit.hs", "Serve.hs"]
  design <- readUtf8 ("docs" </> "DESIGN.md")
  assertBool "DESIGN 的「四条读改写路径」声明还在" ("**四条**读改写路径共用" `isInfixOf` design)

-- | DESIGN.md:225「`--json` 只有 `pm vault status` 一个」。
caseJsonFlagCensus :: IO ()
caseJsonFlagCensus = do
  m <- readUtf8 ("app" </> "Main.hs")
  length (filter (\l -> not (isCommentLine l) && "long \"json\"" `isInfixOf` l) (lines m)) @?= 1
  design <- readUtf8 ("docs" </> "DESIGN.md")
  assertBool "DESIGN 的 --json 唯一性声明还在" ("`--json` 只有 `pm vault status` 一个" `isInfixOf` design)

-- | DESIGN.md:519-533 的 ①—⑥ 与 gui/ui/index.html 的 nav 次序：编号即次序。
caseGuiNavOrder :: IO ()
caseGuiNavOrder = do
  html <- readUtf8 ("gui" </> "ui" </> "index.html")
  let tabs = mapMaybe tabOf (lines html)
      tabOf l = case breakOn "data-tab=\"" l of
        Nothing -> Nothing
        Just rest -> Just (takeWhile (/= '"') rest)
  tabs @?= ["status", "sort", "vault", "plans", "config", "help"]
  mapM_ (\lbl -> assertBool ("nav label: " <> lbl) (("</span>" <> lbl <> "</button>") `isInfixOf` html))
    ["状态", "整理新照片", "分类推送", "计划", "设置", "上手"]
  design <- readUtf8 ("docs" </> "DESIGN.md")
  let marks = ["①**状态**", "②**整理新照片**", "③**分类推送**", "④**计划**", "⑤**设置**", "⑥**上手**"]
      pos mk = T.length (fst (T.breakOn (T.pack mk) (T.pack design)))
  mapM_ (\mk -> assertBool ("DESIGN 应包含 " <> mk) (mk `isInfixOf` design)) marks
  let ps = map pos marks
  assertBool ("①—⑥ 在 DESIGN 里应按序出现: " <> show ps) (and (zipWith (<) ps (drop 1 ps)))

breakOn :: String -> String -> Maybe String
breakOn pat s = case T.breakOn (T.pack pat) (T.pack s) of
  (_, rest)
    | T.null rest -> Nothing
    | otherwise -> Just (T.unpack (T.drop (T.length (T.pack pat)) rest))

-- | DESIGN.md:534-537 自称「`gui/src-tauri/tauri.conf.json` 逐字」——把
-- DESIGN 里逐字引用的两条指令与真实 csp 双向对上，其余两条按语义断言。
caseCspQuoted :: IO ()
caseCspQuoted = do
  conf <- readUtf8 ("gui" </> "src-tauri" </> "tauri.conf.json")
  design <- readUtf8 ("docs" </> "DESIGN.md")
  let quoted =
        [ "connect-src http://127.0.0.1:* ipc: http://ipc.localhost"
        , "img-src 'self' blob: data:"
        ]
  mapM_ (\d -> assertBool ("csp 应含 " <> d) (d `isInfixOf` conf)) quoted
  mapM_ (\d -> assertBool ("DESIGN 应逐字引用 " <> d) (d `isInfixOf` design)) quoted
  assertBool "csp: style-src 放行 unsafe-inline" ("style-src 'self' 'unsafe-inline'" `isInfixOf` conf)
  assertBool "DESIGN: style-src 例外要讲明" ("`style-src` 另放行" `isInfixOf` design)
  assertBool "csp: script-src 只 self" ("script-src 'self'" `isInfixOf` conf)

-- | P7-J 删掉的三个名字不得回潮：opRelPaths（无调用者的导出）、isPng
-- （与 push 门分叉的第二份谓词）、stemKey（Import/Sort 双份局部配对键）。
-- 只查非注释行——历史注释里提旧名是合法的交代。
caseNoDeadNames :: IO ()
caseNoDeadNames = do
  ms <- srcModules
  bad <- concat <$> mapM check ms
  bad @?= []
 where
  check (m, fp) = do
    s <- readUtf8 fp
    pure [(m, w) | w <- ["opRelPaths", "isPng", "stemKey"], refsIn w s]

-- | 一段连续注释行里出现两个 @-- |@ / @-- ^@ 标记 = 两个块被粘成了一个
-- （工作流 F013/F045/F055 的共同形态：挪代码时把上一个块的文档留在原地，
-- 新块的标记直接叠上去，Haddock 只认一个、另一个静默丢失）。
caseHaddockMarkerHygiene :: IO ()
caseHaddockMarkerHygiene = do
  ms <- srcModules
  bad <- concat <$> mapM check ms
  bad @?= []
 where
  check (m, fp) = do
    s <- readUtf8 fp
    let runs = splitRuns (zip [1 :: Int ..] (lines s))
        markers run = [n | (n, l) <- run, let t = strip l, "-- |" `isPrefixOf` t || "-- ^" `isPrefixOf` t]
    pure [(m, markers run) | run <- runs, length (markers run) > 1]
  splitRuns [] = []
  splitRuns xs = case span (isCommentLine . snd) xs of
    ([], _ : rest) -> splitRuns rest
    (run, rest) -> run : splitRuns rest

-- | F048 被否证的机制解释（惰性求值把枚举异常带出 try、要在 try 内强制
-- 求值云云）已被 'Pm.Scan.listTreeCov' 的实际代码否证——其标志词不许再
-- 出现在任何测试文件里。标志词用拼接构造，免得本文件自指命中。
caseFolkloreNotInTests :: IO ()
caseFolkloreNotInTests = do
  let folklore = "强制" <> "列表脊"
  fs <- sort . filter (".hs" `isSuffixOf`) <$> listDirectory "test"
  bad <- concat <$> mapM (\f -> (\s -> [f | folklore `isInfixOf` s]) <$> readUtf8 ("test" </> f)) fs
  bad @?= []

-- | F025 收尾：闸的共享定义叫 'freshStagingCatalog'（withFreshStagingCatalog
-- 只是 CLI 包装），命令文档要指对名字。
caseFreshGateName :: IO ()
caseFreshGateName = do
  dc <- readUtf8 ("docs" </> "DESIGN-COMMANDS.md")
  assertBool "DESIGN-COMMANDS 应指向 freshStagingCatalog" ("`freshStagingCatalog`" `isInfixOf` dc)

-- | 41 轮 GO-note #9：本套件全部按仓库根相对路径读文件——契约明说并自证，
-- 换 cwd 的运行方式会在这里得到一句人话而不是九个 does-not-exist。
caseRepoRootCwd :: IO ()
caseRepoRootCwd = do
  ok <- doesFileExist "package.yaml"
  assertBool "DocDriftTests 须从仓库根运行（stack test 的默认 cwd）——package.yaml 不在当前目录" ok

-- | 41 轮 #7（δ 簇「发布字段手抄」）：README 的测试计数曾同页 310/382 两说、
-- undo 提要写着不存在的 `pm undo <planId>`、收敛叙事停在 37/38 轮。数字只
-- 允许一个上游（DESIGN-COMMANDS 状态行），提要必须是真 CLI 形态，轮次收敛
-- 判定整段委托 REVIEW-LOG——README 不再手抄「第 N 轮 GO」。
caseReadmeSync :: IO ()
caseReadmeSync = do
  readme <- readUtf8 "README.md"
  dc <- readUtf8 ("docs" </> "DESIGN-COMMANDS.md")
  dcCount <- case countsBefore " 测试**" dc of
    [n] -> pure n
    other -> assertFailure ("DESIGN-COMMANDS 状态行应恰有一个「N 测试」: " <> show other) >> pure 0
  let rCounts = countsBefore " 例" readme
  assertBool "README 至少报一次测试计数（N 例）" (not (null rCounts))
  assertEqual ("README 全部「N 例」须等于 DESIGN-COMMANDS 状态行的 " <> show dcCount) [] (filter (/= dcCount) rCounts)
  assertBool "README 的 undo 提要须是真 CLI 形态 pm undo --last" ("pm undo --last" `isInfixOf` readme)
  assertBool "README 不得出现 pm undo <planId>（CLI 无此形态）" (not ("pm undo <planId>" `isInfixOf` readme))
  assertBool "README 不手抄「…轮 GO」收敛判定（委托 REVIEW-LOG）" (not ("轮 GO" `isInfixOf` readme))
  -- 43 轮 #3：突变覆盖的绝对化措辞（「每道闸都配」「每道承重闸」）与登记残余
  -- 矛盾——42 轮修了两处、第三处漏网，哨兵此前不管措辞只管数字。
  assertBool "README 不得绝对化突变覆盖（有登记残余）" (not (any (`isInfixOf` readme) ["每道闸都", "每道承重闸"]))

-- | 0.6.0 发布链泄漏扫描：`Paths_photo_manager` 把构建机的六个安装目录
-- （`D:\…\.stack-work\install\…`）烤进 pm.exe——exe 段的 Paths 对象直接进
-- 链接命令行，不经归档裁剪，只要 hpack 生成它就一定在。修法两处（版本改走
-- Cabal 的 CPP 宏、package.yaml exe 段显式 `other-modules: []`）都不许回潮；
-- 只查非注释行，注释里交代历史是合法的。
caseNoPathsModule :: IO ()
caseNoPathsModule = do
  m <- readUtf8 ("app" </> "Main.hs")
  assertBool "app/Main.hs 不得引用 Paths_photo_manager（安装目录会烤进二进制）" (not (refsIn "Paths_photo_manager" m))
  assertBool "app/Main.hs 的版本串须取 CURRENT_PACKAGE_VERSION 宏" (refsIn "CURRENT_PACKAGE_VERSION" m)
  py <- readUtf8 "package.yaml"
  assertBool "package.yaml exe 段须显式 other-modules: []（否则 hpack 自动加 Paths 模块）" ("other-modules: []" `isInfixOf` py)

-- | @countsBefore suf s@：s 里所有「数字串 + suf」形态的数字。
countsBefore :: String -> String -> [Int]
countsBefore suf = go
 where
  go [] = []
  go xs@(c : _)
    | isDigit c =
        let (ds, r) = span isDigit xs
         in if suf `isPrefixOf` r then read ds : go r else go r
    | otherwise = go (drop 1 xs)
