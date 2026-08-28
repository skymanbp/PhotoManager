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
import Data.Char (isAlpha, isDigit, isSpace, toLower)
import Data.List (dropWhileEnd, isInfixOf, isPrefixOf, isSuffixOf, sort, tails)
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TEE
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

docDriftTests :: TestTree
docDriftTests =
  testGroup
    "P7-J 文档—代码漂移哨兵"
    [ testCase "字节出口清点：deleteBoundAt 引用模块集合固定；Exec 头注不再写 no delete call anywhere" caseByteExitCensus
    , testCase "配置锁清点：withConfigLock 调用模块集合 = DESIGN-GUI 声明的四条读改写路径" caseConfigLockCensus
    , testCase "--json 清点：全 CLI 只有 vault status 与 vault notes 两处 long \"json\"（P8-C）" caseJsonFlagCensus
    , testCase "GUI 页序：DESIGN-GUI ①—⑥ 的顺序与 index.html 的 nav 次序一致" caseGuiNavOrder
    , testCase "CSP 逐字：DESIGN-GUI 引用的指令逐条出现在 tauri.conf.json 的 csp 里；style-src 只 self（F090）" caseCspQuoted
    , testCase "F090 前提（48 轮词法判据）：gui/ui 无内联样式/on*/非外链 script，全部脚本零 setAttribute、innerHTML 只赋空串、每个脚本都被外链" caseGuiNoInlineStyle
    , testCase "750 行预算（DESIGN §16）：手写源码/测试/文档/页面/脚本全部 ≤ 750 行（P8-A 起自动化）" caseLineBudget
    , testCase "死名清扫：opRelPaths / isPng / stemKey / jpegExt 不再出现在 src/app" caseNoDeadNames
    , testCase "Haddock 标记卫生：一段连续注释里至多一个 -- | / -- ^ 标记" caseHaddockMarkerHygiene
    , testCase "讹传清扫：被否证的机制解释（F048 列表脊、46 轮 openBoundTo 共享模式）不再出现在 src/app/test" caseFolkloreNotInTests
    , testCase "命名同步：DESIGN-COMMANDS 讲的是 freshStagingCatalog（F025 收尾）" caseFreshGateName
    , testCase "41 轮 GO-note #9 运行契约：cwd = 仓库根（本套件按根相对路径读仓库文件）" caseRepoRootCwd
    , testCase "41 轮 #7 README 发布字段：测试计数与 DESIGN-COMMANDS 状态行一致、undo 提要 = 真 CLI、轮次判定委托 REVIEW-LOG" caseReadmeSync
    , testCase "0.6.0 发布链：pm.exe 不带构建机路径——Main.hs 不用 Paths 模块、版本走 CPP 宏、每个 exe stanza 显式 other-modules" caseNoPathsModule
    ]

-- ─── 基础设施 ────────────────────────────────────────────────────────────────

readUtf8 :: FilePath -> IO String
readUtf8 fp = T.unpack . TE.decodeUtf8With TEE.lenientDecode <$> BS.readFile fp

-- | src/Pm 全部模块（**递归**——46 轮 GO-note：平铺枚举会对 src/Pm/Sub/X.hs 里的
-- 引用视而不见，六个清点用例共用此处，一处改惠及全部）+ app/Main.hs，
-- (展示名, 路径)。展示名 = 相对 src/Pm 的路径，平铺文件仍是裸文件名，既有期望不变。
srcModules :: IO [(String, FilePath)]
srcModules = do
  ms <- walk ("src" </> "Pm") ""
  pure (sort ms <> [("Main.hs", "app" </> "Main.hs")])
 where
  walk dir rel = do
    es <- sort <$> listDirectory dir
    concat <$> mapM (visit dir rel) es
  visit dir rel e = do
    let p = dir </> e
        r = if null rel then e else rel <> "/" <> e
    isDir <- doesDirectoryExist p
    if isDir then walk p r else pure [(r, p) | ".hs" `isSuffixOf` e]

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

-- | DESIGN-GUI.md §11「配置文件的写纪律」：「**四条**读改写路径共用（… 全仓
-- `withConfigLock` 调用点即此四处）」（P8-A 起 §11 住在 DESIGN-GUI.md）。
caseConfigLockCensus :: IO ()
caseConfigLockCensus = do
  refs <- refModules "withConfigLock" ["Config.hs"]
  refs @?= ["BackupCmd.hs", "Commands.hs", "ConfigEdit.hs", "Serve.hs"]
  design <- readUtf8 ("docs" </> "DESIGN-GUI.md")
  assertBool "DESIGN-GUI 的「四条读改写路径」声明还在" ("**四条**读改写路径共用" `isInfixOf` design)

-- | DESIGN.md「`--json` 只有 `pm vault status` 与 `pm vault notes` 两个」
-- （P8-C 起：两个都是技能消费的机器可读面，其余命令仍是人读的）。
caseJsonFlagCensus :: IO ()
caseJsonFlagCensus = do
  m <- readUtf8 ("app" </> "Main.hs")
  length (filter (\l -> not (isCommentLine l) && "long \"json\"" `isInfixOf` l) (lines m)) @?= 2
  design <- readUtf8 ("docs" </> "DESIGN.md")
  assertBool "DESIGN 的 --json 清点声明还在" ("`--json` 只有 `pm vault status` 与 `pm vault notes` 两个" `isInfixOf` design)

-- | DESIGN-GUI.md §11「GUI（P4-4 UX 重做…）」的 ①—⑥ 与 gui/ui/index.html 的 nav
-- 次序：编号即次序（P8-A 起 §11 住在 DESIGN-GUI.md）。
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
  design <- readUtf8 ("docs" </> "DESIGN-GUI.md")
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

-- | DESIGN-GUI.md §11 自称「`gui/src-tauri/tauri.conf.json` 逐字」——把
-- DESIGN-GUI 里逐字引用的两条指令与真实 csp 双向对上，其余两条按语义断言。
caseCspQuoted :: IO ()
caseCspQuoted = do
  conf <- readUtf8 ("gui" </> "src-tauri" </> "tauri.conf.json")
  design <- readUtf8 ("docs" </> "DESIGN-GUI.md")
  let quoted =
        [ "connect-src http://127.0.0.1:* ipc: http://ipc.localhost"
        , "img-src 'self' blob: data:"
        ]
  mapM_ (\d -> assertBool ("csp 应含 " <> d) (d `isInfixOf` conf)) quoted
  mapM_ (\d -> assertBool ("DESIGN 应逐字引用 " <> d) (d `isInfixOf` design)) quoted
  -- 0.6.1（F090 收口）：实机 CDP 探针证实 WebView2/Tauri 不注入内联样式，
  -- style-src 收紧为 'self'；'unsafe-inline' 不得回潮。
  assertBool "csp: style-src 只 self（F090 收紧）" ("style-src 'self';" `isInfixOf` conf)
  assertBool "csp: unsafe-inline 不得回潮" (not ("unsafe-inline" `isInfixOf` conf))
  assertBool "DESIGN: style-src 收紧要讲明" ("`style-src 'self'`" `isInfixOf` design)
  assertBool "csp: script-src 只 self" ("script-src 'self'" `isInfixOf` conf)

-- | F090 收紧后的前提：页面与脚本不得引入 CSP 会拦的内联样式/脚本形态。
-- 48 轮：判据从字面表改为**词法**——属性名后任意空白与单/双引号、任意 on* 事件、
-- 带属性或有内容的 `<script>`；脚本零 `setAttribute`、`innerHTML` 只赋空串、无
-- HTML 注入口（字面表曾放过 `style='…'` / `style = "…"` / `onsubmit=` / module script）。
-- CSSOM 写（`el.style.x = …` / `setProperty`）不受 style-src 管，仍允许。
-- 任一回潮 = 发布版 GUI 在 `style-src 'self'` 下静默丢样式。
-- P8-A：页面脚本不止 app.js（vault.js 拆出）——扫 `gui/ui` 下**全部** .js，并要求
-- 每个脚本都被 index.html 外链：拆分不得让哨兵漏看一个文件，也不得留死脚本。
caseGuiNoInlineStyle :: IO ()
caseGuiNoInlineStyle = do
  html <- readUtf8 ("gui" </> "ui" </> "index.html")
  jsFiles <- sort . filter (".js" `isSuffixOf`) <$> listDirectory ("gui" </> "ui")
  js <- concat <$> mapM (\f -> readUtf8 ("gui" </> "ui" </> f)) jsFiles
  mapM_ (\f -> assertBool ("index.html 应外链 " <> f) (("src=\"" <> f <> "\"") `isInfixOf` html)) jsFiles
  let lc = map toLower
      eqAt s = take 1 (dropWhile isSpace s) == "="
      quotedAt s = take 1 (dropWhile isSpace (drop 1 (dropWhile isSpace s))) `elem` ["\"", "'"]
      -- 空白 + 属性名 + 空白* + '=' + 空白* + 引号（单双皆算）
      attr name t = [take 24 r | (c : r) <- tails t, isSpace c, name `isPrefixOf` lc r, let s = drop (length name) r, eqAt s, quotedAt s]
      events t = [take 24 r | (c : r) <- tails t, isSpace c, "on" `isPrefixOf` lc r, let nm = takeWhile isAlpha (drop 2 r), not (null nm), eqAt (drop (2 + length nm) r)]
      -- <script …>：只允许 src= 外链且标签体为空
      scripts t = [take 40 s | s <- tails t, "<script" `isPrefixOf` lc s, let tag = takeWhile (/= '>') s, let body = takeWhile (/= '<') (drop 1 (dropWhile (/= '>') s)), not ("src=" `isInfixOf` lc tag) || any (not . isSpace) body]
      styleEls t = [take 12 s | s <- tails t, "<style" `isPrefixOf` lc s]
      innerBad t = [take 30 s | s <- tails t, "innerHTML" `isPrefixOf` s, let r = dropWhile isSpace (drop 9 s), not (take 1 r == "=" && take 2 (dropWhile isSpace (drop 1 r)) == "\"\"")]
  assertEqual "index.html 内联样式属性" [] (attr "style" html)
  assertEqual "index.html on* 事件属性" [] (events html)
  assertEqual "index.html 内联/非外链 <script>" [] (scripts html)
  assertEqual "index.html/gui/ui 脚本 <style" [] (styleEls html <> styleEls js)
  assertEqual "gui/ui 脚本 setAttribute/HTML 注入口" [] [w | w <- ["setAttribute(", "insertAdjacentHTML", "outerHTML", "document.write", "cssText"], w `isInfixOf` js]
  assertEqual "gui/ui 脚本 innerHTML 只允许赋空串" [] (innerBad js)

-- | P7-J 删掉的三个名字不得回潮：opRelPaths（无调用者的导出）、isPng
-- （与 push 门分叉的第二份谓词）、stemKey（Import/Sort 双份局部配对键）；
-- P8-B 再加 jpegExt（Ingest 里与 pushableExt 分叉的第二份 jpg 谓词，
-- DESIGN-P8 §19.1）。只查非注释行——历史注释里提旧名是合法的交代。
caseNoDeadNames :: IO ()
caseNoDeadNames = do
  ms <- srcModules
  bad <- concat <$> mapM check ms
  bad @?= []
 where
  check (m, fp) = do
    s <- readUtf8 fp
    pure [(m, w) | w <- ["opRelPaths", "isPng", "stemKey", "jpegExt"], refsIn w s]

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
  -- 46 轮第二条讹传：把 openBoundTo 说成「经 cbits 打开、带 share-delete」——实为
  -- openBinaryFile（Win.hs:407），pm_open_for_dispose 只服务 delete/rename；这句曾被
  -- 用来驳回评审发现并写进测试注释。47 轮 GO-note：单一字面形态换个措辞即漏，改为
  -- **同一行共现**判据（两个标志词同行即红），扫描面从 test/ 扩到 src/Pm + app。
  -- 标志词拼接构造，免得本函数自指命中。
  let folklore = [["强制" <> "列表脊"], ["openBoundTo", "FILE_SHARE_" <> "DELETE"]]
      hits s = [unwords ws | ws <- folklore, any (\l -> all (`isInfixOf` l) ws) (lines s)]
  ts <- map (\f -> (f, "test" </> f)) . sort . filter (".hs" `isSuffixOf`) <$> listDirectory "test"
  ms <- srcModules
  bad <- concat <$> mapM (\(m, fp) -> (\s -> [(m, w) | w <- hits s]) <$> readUtf8 fp) (ts <> ms)
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
  -- 45 轮 #1：HISTORY.md 当期阶段行的「N/N」在哨兵之外，P7 行曾被写成 389/389
  -- （产物 390）——同一上游再多派生一处：末段（最新阶段行）须含 dcCount/dcCount。
  hist <- readUtf8 ("docs" </> "HISTORY.md")
  let lastLine = foldl (\_ l -> l) "" (filter (not . all isSpace) (lines hist))
      nn = show dcCount <> "/" <> show dcCount
  assertBool ("HISTORY.md 末段（当期阶段行）须含 " <> nn) (nn `isInfixOf` lastLine)
  -- P7-S（0.6.1 文档审计）：同一类「手抄」再两处——DESIGN-COMMANDS 状态行曾停在
  -- 「37/38 轮 GO」，README「开发史（P0–P6）」在 HISTORY 已到 P7 后第二次漂移
  -- （上一次 P5→P6）。前者与 README 同一禁令；后者从 HISTORY 标题派生。
  assertBool "DESIGN-COMMANDS 不手抄「…轮 GO」收敛判定（委托 REVIEW-LOG）" (not ("轮 GO" `isInfixOf` dc))
  let title = concat (take 1 (lines hist))
  ph <- maybe (assertFailure "HISTORY.md 标题应含「P0 – P<N>」" >> pure "") (pure . takeWhile isDigit) (breakOn "P0 – P" title)
  assertBool ("README 开发史范围须与 HISTORY 标题一致：P0–P" <> ph) (("开发史（P0–P" <> ph <> " 全程）") `isInfixOf` readme)

-- | 0.6.0 发布链泄漏扫描：`Paths_photo_manager` 把构建机的六个安装目录
-- （`D:\…\.stack-work\install\…`）烤进 pm.exe——exe 段的 Paths 对象直接进
-- 链接命令行，不经归档裁剪，只要 hpack 生成它就一定在。修法两处（版本改走
-- Cabal 的 CPP 宏、package.yaml exe 段显式 `other-modules: []`）都不许回潮；
-- 只查非注释行，注释里交代历史是合法的。
caseNoPathsModule :: IO ()
caseNoPathsModule = do
  -- 45 轮 GO-note：库侧引用同样把 Paths 对象拉进 pm.exe（引用任一名字即整对象
  -- 入链），所以清点 src/Pm + app 全部非注释行，不只 Main.hs。
  refs <- refModules "Paths_photo_manager" []
  assertEqual "src/Pm + app 非注释行不得引用 Paths_photo_manager（安装目录会烤进二进制）" [] refs
  m <- readUtf8 ("app" </> "Main.hs")
  assertBool "app/Main.hs 的版本串须取 CURRENT_PACKAGE_VERSION 宏" (refsIn "CURRENT_PACKAGE_VERSION" m)
  py <- readUtf8 "package.yaml"
  -- 45 轮 GO-note：断言限定在 executables: 块内——整文件 isInfixOf 会被「把该行
  -- 挪到 tests 段」骗绿，而 exe 段随即恢复 hpack 自动注入。块 = executables: 行
  -- 之后直到下一个顶格键之前的缩进行（package.yaml 是 CRLF，比较前先 strip）。
  let indented l = case l of
        (c : _) -> isSpace c
        [] -> True
      exeBlock = takeWhile indented (drop 1 (dropWhile ((/= "executables:") . strip) (lines py)))
      -- 46 轮 GO-note：存在性断言会被「再加一个没写 other-modules 的 exe stanza」骗绿
      -- ——按两空格缩进的 stanza 头切块，逐块全称要求。47 轮 GO-note：先剔除注释行
      -- （把该行注释掉曾骗绿），stanza 头须以 ':' 结尾（两空格注释行曾被当头、假红）。
      code = filter (not . ("#" `isPrefixOf`) . strip) exeBlock
      isHeader l = case l of
        (' ' : ' ' : c : _) -> not (isSpace c) && ":" `isSuffixOf` strip l
        _ -> False
      stanzas ls' = case dropWhile (not . isHeader) ls' of
        [] -> []
        (h : rest) -> let (body, more) = break isHeader rest in (h : body) : stanzas more
      exes = stanzas code
  assertBool "package.yaml executables: 块内至少一个 exe stanza" (not (null exes))
  assertBool "package.yaml 每个 exe stanza 均须显式 other-modules: []（非注释行；否则 hpack 自动加 Paths 模块）" (all (any ("other-modules: []" `isInfixOf`)) exes)

-- | 750 行硬预算（DESIGN §16）：此前只是评审期约定、零自动化——P8-A 拆分三个
-- 触顶文件（Serve.hs / app.js / DESIGN.md）时写成哨兵，CI 的 `stack test` 顺带
-- 执行。手写的源码 / 测试 / 文档 / 页面 / 脚本全部 ≤ 750 行；生成物（Cargo.lock、
-- .cabal）与第三方评审原件（docs/reviews/，证据不得修剪）不在清单里。
caseLineBudget :: IO ()
caseLineBudget = do
  ms <- srcModules
  dirs <-
    concat
      <$> mapM
        listWith
        [ ("test", [".hs"])
        , ("docs", [".md"])
        , ("docs" </> "specs", [".md"])
        , ("gui" </> "ui", [".js", ".html", ".css"])
        , ("gui" </> "src-tauri" </> "src", [".rs"])
        , ("scripts", [".py"])
        , ("cbits", [".c", ".h"])
        ]
  let files = map snd ms <> dirs <> ["README.md"]
  over <- concat <$> mapM (\f -> (\s -> [(f, n) | let n = length (lines s), n > 750]) <$> readUtf8 f) files
  assertEqual "超过 750 行预算的手写文件（DESIGN §16）" [] over
 where
  listWith (d, exts) = map (d </>) . sort . filter (\f -> any (`isSuffixOf` f) exts) <$> listDirectory d

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
