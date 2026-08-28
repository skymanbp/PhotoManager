{-# LANGUAGE OverloadedStrings #-}

-- | 转换（P8-C2，DESIGN-P8 §20）：成片\/相册里的非 jpg 照片（'renderExts' 里
-- jpg 之外的 tif\/png\/psd\/heic…）派生出一份 jpg，再经计划落到成片同事件夹
-- （源在成片时；@--also-album@ 再进相册）或相册（源本就在相册）。两段式：
--
--   * 第一段（生成期，pm 状态区）：python（Pillow）把源解码写成
--     @\<主库\>\\.pm\\derived\\\<源 sha\>\\\<stem\>.jpg.tmp@ → pm 无覆盖 rename 成
--     @\<stem\>.jpg@ → 双 stat + sha。派生目录是 pm 自己的状态区，不是照片
--     （I3 的偏离登记在 DESIGN-P8 §25；'pm doctor' 对账它，见 'scanDerived'）。
--   * 第二段（计划，照片层）：'OpCopy' 派生 jpg → 目标；同 stem 的 jpg 已在
--     → 同 sha 跳过、异 sha NEEDS-DECISION（I5），判定与相册通道同一份
--     （'classifyInto'）。原 tif\/png **原地不动**（I2）。
--
-- python 的发现：@PM_PYTHON@ → PATH 上的 @python@（同 'Pm.Ui.locateUi' 的
-- @PM_UI_EXE@ 先例）；预检 @import PIL@；脚本内嵌在 'pillowScript' 里经 stdin
-- 交给 @python -@——发布件不多带文件，也不产生第二处路径依赖。
module Pm.Convert
  ( ConvertOpts (..)
  , DerivedState (..)
  , derivedSub
  , derivedRel
  , findPython
  , pillowScript
  , scanDerived
  , runConvert
  , runConvertTo
  ) where

import Pm.Album (AlbumReport (..), albumPlanItems, albumTop, attachAlbumItems, classifyAlbum, classifyInto, processedTop)
import Pm.Catalog (catalogOr, loadCatalog)
import Pm.Cli (GoOpts, emitPlanTo)
import Pm.Config (Config (..), ensurePmSubdir, pmDir, requireRole)
import Pm.Hash (StatSnap (..), sha256File, statSnap)
import Pm.Import (foldPath)
import Pm.Op (userRelOk)
import Pm.Plan (PlanItem (..))
import Pm.Types
import Pm.VaultCore (pushableExt)
import Pm.Win (NameKind (..), deleteBoundAt, moveBoundNoReplace, probeName, resolveUnder)

import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import System.FilePath (splitDirectories, takeBaseName, takeDirectory, takeExtension, takeFileName, (</>))
import System.Exit (ExitCode (..))
import System.Environment (getEnvironment, lookupEnv)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, listDirectory)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Text (Text)
import Data.List (intercalate, nub)
import Data.Char (toLower)
import Control.Monad (forM, forM_, when)
import Control.Exception (IOException, try)

-- | @pm convert@ 的参数。
data ConvertOpts = ConvertOpts
  { coGo :: GoOpts
  , coAlsoAlbum :: Bool
  , coRedo :: Bool
  , coFiles :: [String]
  }

-- | @.pm@ 下的派生目录名。
derivedSub :: FilePath
derivedSub = "derived"

-- | 派生件的库内相对路径（计划里 'OpCopy' 的源 = root \</\> 它；'opPathsOk' 只
-- 管目标，源在 @.pm@ 里合法——它是 pm 自建状态，不是用户数据）。
derivedRel :: Text -> FilePath -> FilePath
derivedRel sha stem = ".pm" </> derivedSub </> T.unpack sha </> (stem <> ".jpg")

-- | @PM_PYTHON@ → PATH 上的 @python@（'findExecutable' 在 Windows 上按 PATHEXT
-- 认 @.exe@）。找不到就说找不到，不猜。
findPython :: IO (Either String FilePath)
findPython = do
  mEnv <- lookupEnv "PM_PYTHON"
  case mEnv of
    Just p -> do
      ok <- doesFileExist p
      pure (if ok then Right p else Left ("PM_PYTHON 指向的文件不存在: " <> p))
    Nothing ->
      maybe (Left "找不到 python（PATH 上没有）→ 设 PM_PYTHON 指向 python.exe，或把 python 加进 PATH") Right
        <$> findExecutable "python"

-- | 内嵌的 Pillow 脚本（DESIGN-P8 §20.1 的解码纪律）：16 位样本先按 1\/256 缩到
-- 8 位再转（直接 convert 会截顶）；带 alpha 的合成到白底；保留 EXIF 与 ICC；
-- @quality=95, subsampling=0, optimize=True@；任何失败 → 非零退出 + 一行 ASCII
-- 原因（stderr 只出 ASCII：GHC 按控制台码页解码子进程输出，非 ASCII 会抛）。
pillowScript :: String
pillowScript =
  unlines
    [ "import sys"
    , "def main():"
    , "    from PIL import Image"
    , "    src, dst = sys.argv[1], sys.argv[2]"
    , "    im = Image.open(src)"
    , "    im.load()"
    , "    info = dict(im.info)"
    , "    if im.mode in ('I;16', 'I;16B', 'I;16L', 'I;16N'):"
    , "        im = im.convert('I')"
    , "    if im.mode == 'I':"
    , "        im = im.point(lambda v: v * (1.0 / 256.0)).convert('L')"
    , "    if im.mode in ('RGBA', 'LA', 'PA') or (im.mode == 'P' and 'transparency' in info):"
    , "        rgba = im.convert('RGBA')"
    , "        bg = Image.new('RGB', rgba.size, (255, 255, 255))"
    , "        bg.paste(rgba, mask=rgba.getchannel('A'))"
    , "        im = bg"
    , "    elif im.mode not in ('RGB', 'L'):"
    , "        im = im.convert('RGB')"
    , "    kw = {'quality': 95, 'subsampling': 0, 'optimize': True}"
    , "    if info.get('exif'):"
    , "        kw['exif'] = info['exif']"
    , "    if info.get('icc_profile'):"
    , "        kw['icc_profile'] = info['icc_profile']"
    , "    im.save(dst, 'JPEG', **kw)"
    , "try:"
    , "    main()"
    , "except Exception as e:"
    , "    msg = type(e).__name__ + ': ' + str(e)"
    , "    sys.stderr.write(msg.encode('ascii', 'backslashreplace').decode('ascii') + '\\n')"
    , "    sys.exit(3)"
    ]

-- | 跑 python：子进程强制 UTF-8 模式（Windows 控制台码页会让 python 自己在
-- 打印非 ASCII 时抛错）。
runPy :: FilePath -> [String] -> String -> IO (ExitCode, String, String)
runPy py args stdinText = do
  env0 <- getEnvironment
  let forced = [("PYTHONUTF8", "1"), ("PYTHONIOENCODING", "utf-8")]
      env' = forced <> filter ((`notElem` map fst forced) . fst) env0
  readCreateProcessWithExitCode (proc py args) {env = Just env'} stdinText

oneLine :: String -> String
oneLine = unwords . words

-- | 预检：Pillow 装了没有。
preflight :: FilePath -> IO (Either String ())
preflight py = do
  (code, _, err) <- runPy py ["-c", "import PIL"] ""
  pure $ case code of
    ExitSuccess -> Right ()
    ExitFailure _ -> Left ("python 里没有 Pillow → pip install pillow（" <> py <> "；" <> oneLine err <> "）")

-- | 一条源的派生结果：源条目、派生件的伪条目（路径 = 'derivedRel'）、是否复用。
data Derived = Derived
  { dSrc :: Entry
  , dEntry :: Entry
  , dReused :: Bool
  }

-- | 第一段。幂等：派生件已在 → 复用（@--redo@ 才重派生：先删旧派生件——pm 自建
-- 状态，再派生）。失败 → 半成品 tmp 清掉，错误带源路径返回。
deriveOne :: FilePath -> FilePath -> Bool -> Entry -> IO (Either String Derived)
deriveOne root py redo e = do
  edir <- ensurePmSubdir root (derivedSub </> T.unpack (enSha e))
  case edir of
    Left m -> pure (Left (enPath e <> ": " <> m))
    Right dir -> do
      let stem = takeBaseName (enPath e)
          final = dir </> (stem <> ".jpg")
          tmp = final <> ".tmp"
      have <- doesFileExist final
      r <-
        if have && not redo
          then pure (Right True)
          else do
            eold <- try (when have (deleteBoundAt final)) :: IO (Either IOException ())
            case eold of
              Left ex -> pure (Left ("旧派生件删不掉（" <> show ex <> "）"))
              Right () -> do
                (code, _, err) <- runPy py ["-", root </> enPath e, tmp] pillowScript
                case code of
                  ExitFailure n -> pure (Left ("转换失败（python exit " <> show n <> "）: " <> oneLine err))
                  ExitSuccess -> do
                    ok <- doesFileExist tmp
                    if not ok
                      then pure (Left "python 退出 0 但没有写出派生件")
                      else do
                        mr <- try (moveBoundNoReplace tmp final) :: IO (Either IOException ())
                        pure (either (\ex -> Left ("派生件落位失败（" <> show ex <> "）")) (const (Right False)) mr)
      case r of
        Left m -> do
          _ <- try (deleteBoundAt tmp) :: IO (Either IOException ())
          pure (Left (enPath e <> ": " <> m))
        Right reused -> do
          snap <- statSnap final
          sha <- sha256File final
          pure (Right (Derived e (Entry (derivedRel (enSha e) stem) (ssSize snap) (ssMtimeNs snap) sha KindPhoto Nothing) reused))

-- | 第二段（纯）：派生件的伪条目经 'classifyInto'（成片同事件夹）与
-- 'classifyAlbum'（相册）判定，相册项按 'attachAlbumItems' 挂到成片项上。
-- 返回（计划项，交代行）。
convertPlan :: FilePath -> Catalog -> Bool -> [Derived] -> ([PlanItem], [String])
convertPlan root cat alsoAlbum ds = (items, notes)
 where
  inProcessed d = take 1 (splitDirectories (enPath (dSrc d))) == [processedTop]
  mainDs = filter inProcessed ds
  mainDst = Map.fromList [(enPath (dEntry d), takeDirectory (enPath (dSrc d)) </> takeFileName (enPath (dEntry d))) | d <- mainDs]
  mrep = classifyInto (\p -> Map.findWithDefault (enPath p) (enPath p) mainDst) cat (map dEntry mainDs)
  base = albumPlanItems root 0 mrep
  albumDs = [d | d <- ds, not (inProcessed d) || alsoAlbum]
  arep = classifyAlbum cat (map dEntry albumDs)
  conflictSrcs = Set.fromList [enPath e | (e, _) <- arConflict mrep]
  pendingSrc = Set.fromList [enPath (dEntry d) | d <- albumDs, enPath (dEntry d) `Set.notMember` conflictSrcs]
  items = attachAlbumItems root base pendingSrc arep
  notes =
    ["  = 已落位（同内容）: " <> s <> " ≡ " <> t | (s, t) <- arAlready mrep <> arAlready arep]
      <> ["  ⚠ 目标已有同名不同内容: " <> enPath e <> " → " <> t <> "（待裁决）" | (e, t) <- arConflict mrep <> arConflict arep]
      <> ["  ✗ 同批撞名，未入计划: " <> s <> " → " <> t | (s, t) <- arDupName mrep <> arDupName arep]

-- | 同批里转换后落到同一个目标（case-fold）的源——先于任何转换拒绝（I1：
-- @\<stem\>.jpg@ 只能有一份，pm 不替用户挑）。
targetClashes :: Bool -> [Entry] -> [String]
targetClashes alsoAlbum es =
  [ intercalate " / " (map enPath g) <> " 转换后同名同目录（<stem>.jpg 只能有一份；先改名再转）"
  | g <- Map.elems (Map.fromListWith (flip (<>)) (mainKeys <> albumKeys))
  , length g > 1
  ]
 where
  top e = take 1 (splitDirectories (enPath e))
  jpgName e = takeBaseName (enPath e) <> ".jpg"
  mainKeys = [(foldPath (takeDirectory (enPath e) </> jpgName e), [e]) | e <- es, top e == [processedTop]]
  albumKeys = [(foldPath (albumTop </> jpgName e), [e]) | e <- es, top e == [albumTop] || alsoAlbum]

runConvert :: ConvertOpts -> Config -> IO Int
runConvert o cfg = fst <$> runConvertTo putStrLn o cfg

-- | 打印口由调用方给（工作流 F051 的 sink 纪律）。次序同 'Pm.Album.runAlbumAddTo'：
-- 身份闸 → catalog → 全部校验 fail-closed 一次列完 → python 发现与预检 →
-- 逐条派生（任一失败 → 不出计划；已派生的下次复用）→ 计划。
runConvertTo :: (String -> IO ()) -> ConvertOpts -> Config -> IO (Int, Maybe Text)
runConvertTo sink o cfg
  | null (coFiles o) = sink "未给出任何文件（pm convert 成片/<事件夹>/<文件> | 相册/<文件> …；pm album candidates 列出非 jpg）" >> pure (2, Nothing)
  | not (null lexErrs) = mapM_ (sink . ("  ✗ " <>)) lexErrs >> pure (2, Nothing)
  | otherwise = do
      er <- requireRole RoleMain root
      case er of
        Left msg -> sink msg >> pure (2, Nothing)
        Right info -> do
          lc <- loadCatalog root
          case catalogOr "主库尚未索引 → 先 pm scan" lc of
            Left m -> sink m >> pure (2, Nothing)
            Right (cat, warns) -> do
              mapM_ (\w -> sink ("⚠ 快照损坏已跳过: " <> w)) warns
              let catByFold = Map.fromList [(foldPath (enPath e), e) | e <- Map.elems (catEntries cat)]
                  looked = [(r, Map.lookup (foldPath r) catByFold) | r <- nub (coFiles o)]
                  entries = [e | (_, Just e) <- looked]
                  top e = take 1 (splitDirectories (enPath e))
                  isRaw e = map toLower (takeExtension (enPath e)) `elem` rawExts
              -- 实体闸：每个源都必须是库内真实路径（链接\/别名拒绝，查不出也拒绝）
              escaped <- fmap concat . forM entries $ \e -> do
                m <- resolveUnder root (enPath e)
                pure [enPath e <> " 不是库内真实路径（链接/别名？查不出也拒绝）" | m == Nothing]
              let errs =
                    [r <> " 不在索引里（路径拼错？或先 pm scan）" | (r, Nothing) <- looked]
                      <> [enPath e <> " 不是照片条目" | e <- entries, enKind e /= KindPhoto]
                      <> [enPath e <> " 不在成片/相册下（只转换这两层的照片）" | e <- entries, top e `notElem` [[processedTop], [albumTop]]]
                      <> [enPath e <> " 已经是 jpg（相册直接收：pm album add）" | e <- entries, pushableExt (enPath e)]
                      <> [enPath e <> " 是 RAW 原始档，不是转换对象（转换对象是 tif/png/psd/heic 等已渲染位图）" | e <- entries, isRaw e]
                      <> escaped
                      <> targetClashes (coAlsoAlbum o) entries
              if not (null errs)
                then mapM_ (sink . ("  ✗ " <>)) errs >> pure (2, Nothing)
                else do
                  epy <- findPython
                  epre <- either (pure . Left) (\py -> fmap (py <$) (preflight py)) epy
                  case epre of
                    Left m -> sink ("  ✗ " <> m) >> pure (2, Nothing)
                    Right py -> do
                      results <- mapM (deriveOne root py (coRedo o)) entries
                      let fails = [m | Left m <- results]
                          ds = [d | Right d <- results]
                      forM_ ds $ \d ->
                        sink ((if dReused d then "  = 复用派生件 " else "  ⇢ 已派生 ") <> enPath (dSrc d) <> " → " <> enPath (dEntry d))
                      if not (null fails)
                        then do
                          mapM_ (sink . ("  ✗ " <>)) fails
                          sink "（有转换失败，本轮不出计划；修好后重跑——已派生的会复用）"
                          pure (2, Nothing)
                        else do
                          let (items, notes) = convertPlan root cat (coAlsoAlbum o) ds
                          mapM_ sink notes
                          if null items
                            then sink "✓ 全部已落位（同内容），无需计划" >> pure (0, Nothing)
                            else emitPlanTo sink cfg (coGo o) "convert" root info items
 where
  root = cfgMainPath cfg
  lexErrs =
    [ f <> "：须是库内相对路径（成片/<事件夹>/<文件> 或 相册/<文件>），不能是绝对路径、带盘符、含 .. 或 :"
    | f <- coFiles o
    , not (userRelOk f)
    ]

-- ─── doctor 对账（DESIGN-P8 §20.2） ─────────────────────────────────────────

-- | 派生件的状态：@DerivedStale@ 其 sha 已出现在索引（已落位）；@DerivedOrphan@
-- 目录名 sha 不再是索引里任何条目的 sha（源已不在库里）；@DerivedTmp@ 转换
-- 中断留下的半成品；@DerivedPending@ 派生了还没 apply；@DerivedUnjudged@ 没有
-- 索引，判不了。前三种是 pm 自建状态，@--repair@ 删；后两种只报告。
data DerivedState = DerivedStale | DerivedOrphan | DerivedTmp | DerivedPending | DerivedUnjudged
  deriving (Show, Eq)

-- | 遍历 @.pm\/derived\/\<sha\>\/*@。逐级只认 'NamePlain'（同
-- 'Pm.Doctor.staleTmpFiles'：链接本体不递归不列出 = 不删，fail-closed）；
-- 枚举\/读取异常 → Left（调用方报 Bad，不做任何删除）。
scanDerived :: FilePath -> Maybe Catalog -> IO (Either String [(FilePath, DerivedState)])
scanDerived root mcat = do
  let base = pmDir root </> derivedSub
      shas = maybe Set.empty (Set.fromList . map enSha . Map.elems . catEntries) mcat
  basePlain <- (== NamePlain) <$> probeName base
  ex <- doesDirectoryExist base
  if not basePlain || not ex
    then pure (Right [])
    else do
      r <- try $ do
        dirs <- listDirectory base
        fmap concat . forM dirs $ \d -> do
          let dd = base </> d
          pk <- probeName dd
          isD <- doesDirectoryExist dd
          if pk /= NamePlain || not isD
            then pure []
            else do
              files <- listDirectory dd
              fmap concat . forM files $ \f -> do
                let fp = dd </> f
                fk <- probeName fp
                isF <- doesFileExist fp
                if fk /= NamePlain || not isF
                  then pure []
                  else
                    if takeExtension f == ".tmp"
                      then pure [(fp, DerivedTmp)]
                      else case mcat of
                        Nothing -> pure [(fp, DerivedUnjudged)]
                        Just _ -> do
                          sha <- sha256File fp
                          pure
                            [ ( fp
                              , if sha `Set.member` shas
                                  then DerivedStale
                                  else if T.pack d `Set.notMember` shas then DerivedOrphan else DerivedPending
                              )
                            ]
      pure (either (\e -> Left (show (e :: IOException))) Right r)
