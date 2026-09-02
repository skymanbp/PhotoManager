{-# LANGUAGE OverloadedStrings #-}

-- | 转换（P8-C2，DESIGN-P8 §20）：成片\/相册里的非 jpg 照片（'renderExts' 里
-- jpg 之外的 tif\/png\/psd\/heic…，谓词 'convertibleExt'）派生出一份 jpg，再经
-- 计划落到成片同事件夹（源在成片时；@--also-album@ 再进相册）或相册（源本就
-- 在相册）。两段式：
--
--   * 第一段（生成期，pm 状态区）：python（Pillow）把源解码写进
--     @\<主库\>\\.pm\\derived\\\<源 sha\>\\\<stem\>.jpg.tmp@ → pm 无覆盖 rename 成
--     @\<stem\>.jpg@ → 双 stat + sha。派生目录是 pm 自己的状态区，不是照片
--     （I3 的偏离登记在 DESIGN-P8 §25；'pm doctor' 对账它，见 'scanDerived'）。
--   * 第二段（计划，照片层）：'OpCopy' 派生 jpg → 目标；同 stem 的 jpg 已在
--     → 同 sha 跳过、异 sha NEEDS-DECISION（I5），判定与相册通道同一份
--     （'classifyInto'）。原 tif\/png **原地不动**（I2）。
--
-- 第一段的写纪律（第一方全量审 C0\/C2\/C3；与 'Pm.Exec' 的 tmp 落位用**同一组
-- 原语**，差一处——目标名要交给 python）：派生件的 tmp 与终名都以**完整相对路径**
-- 过 'resolveUnder'，只用返回的路径；tmp 由 pm 先 'openFreshBinary'（CREATE_NEW，
-- 残留先清）独占创建再交给 python 写；python 退出后复验 tmp 仍是普通名、单链接，
-- sha 在 tmp 上经同一句柄测得，随后 'moveBoundNoReplace' 落位；复用旧派生件同样
-- 只认普通名 + 单链接（'openStateRead' 的读侧规格——派生件的字节会进计划）。
-- 整段「派生 → 落位 → 测 sha」在 'withRootLock' 之内（I10；整批期间其它写路径
-- 拿不到锁会报忙，不是死锁）。登记残余（DESIGN-P8 §25）：pm 关掉独占句柄到
-- python 按名打开之间有窗口，窗口内被主动换成库外 hardlink 会写穿库外对象——
-- 随后的复验拒绝它、坏字节不进计划，但库外字节已被覆盖；Exec 无此窗口，因为
-- 它全程只经自己的句柄写。
--
-- python 的发现：@PM_PYTHON@ → PATH 上的 @python@（同 'Pm.Ui.locateUi' 的
-- @PM_UI_EXE@ 先例）；预检 @import PIL@；脚本内嵌在 'pillowScript' 里经 stdin
-- 交给 @python -@——发布件不多带文件，也不产生第二处路径依赖。子进程走
-- 'Pm.Subprocess.runTool'：整体超时 @PM_CONVERT_TIMEOUT@ 秒（缺省 600）。
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
import Pm.Config (Config (..), ensurePmSubdir, requireRole, withRootLock)
import Pm.Derived (DerivedState (..), derivedSub, scanDerived)
import Pm.Hash (StatSnap (..), sha256Handle, statSnap)
import Pm.Import (foldPath)
import Pm.Op (userRelOk)
import Pm.Plan (PlanItem (..))
import Pm.Subprocess (ToolOutcome (..), envTimeout, runTool)
import Pm.Types
import Pm.VaultCore (convertibleExt, pushableExt)
import Pm.Win (NameKind (..), deleteBoundAt, moveBoundNoReplace, openFreshBinary, openStateRead, probeName, resolveUnder)

import System.FilePath (splitDirectories, takeBaseName, takeDirectory, takeExtension, takeFileName, (</>))
import System.Exit (ExitCode (..))
import System.Environment (lookupEnv)
import System.Directory (doesFileExist, findExecutable)
import System.IO (hClose)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Text (Text)
import Data.List (intercalate, nub)
import Data.Char (toLower)
import Control.Monad (forM, forM_, unless, when)
import Control.Exception (IOException, bracket, try)

-- | @pm convert@ 的参数。
data ConvertOpts = ConvertOpts
  { coGo :: GoOpts
  , coAlsoAlbum :: Bool
  , coRedo :: Bool
  , coFiles :: [String]
  }

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
-- 原因。目标文件由 pm 先独占创建，脚本只往这个已存在的普通文件里写。
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

-- | 跑 python（'runTool'）：子进程强制 UTF-8 模式（Windows 控制台码页会让
-- python 自己在打印非 ASCII 时抛错）；超时 \/ 拉不起来 → Left 一句人话。
runPy :: FilePath -> [String] -> String -> Int -> IO (Either String (ExitCode, Text, Text))
runPy py args stdinText secs = do
  r <- runTool py args Nothing [("PYTHONUTF8", "1"), ("PYTHONIOENCODING", "utf-8")] (T.pack stdinText) secs
  pure $ case r of
    ToolFailed e -> Left ("拉起 python 失败（" <> e <> "）")
    ToolTimeout n -> Left ("python 超过 " <> show n <> " 秒未结束，已终止整棵进程树（PM_CONVERT_TIMEOUT 可调）")
    ToolRan c o e -> Right (c, o, e)

oneLine :: Text -> String
oneLine = unwords . words . T.unpack

-- | 预检：Pillow 装了没有。
preflight :: FilePath -> Int -> IO (Either String ())
preflight py secs = do
  r <- runPy py ["-c", "import PIL"] "" secs
  pure $ case r of
    Left m -> Left m
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure _, _, err) -> Left ("python 里没有 Pillow → pip install pillow（" <> py <> "；" <> oneLine err <> "）")

-- | 一条源的派生结果：源条目、派生件的伪条目（路径 = 'derivedRel'）、是否复用。
data Derived = Derived
  { dSrc :: Entry
  , dEntry :: Entry
  , dReused :: Bool
  }

-- | 第一段（调用方持 root 锁）。幂等：派生件已在 → 复用（@--redo@ 才重派生：
-- 先删旧派生件——pm 自建状态，再派生）。失败 → 半成品 tmp 清掉，错误带源路径
-- 返回。任何 IOException 都收成 Left（fail-closed，不让一条源崩掉整批的交代）。
deriveOne :: FilePath -> FilePath -> Int -> Bool -> Entry -> IO (Either String Derived)
deriveOne root py secs redo e = do
  let stem = takeBaseName (enPath e)
      rel = derivedRel (enSha e) stem
      tag m = enPath e <> ": " <> m
  edir <- ensurePmSubdir root (derivedSub </> T.unpack (enSha e))
  case edir of
    Left m -> pure (Left (tag m))
    Right _ -> do
      -- 文件级限域：完整相对路径各过一次 'resolveUnder'，只用返回值（同
      -- 'Pm.Exec.confinedTmp' \/ 'Pm.Config.writeCacheFile'）；目录名 sha 与 stem
      -- 之间有链接 \/ 别名 → 两者都答 Nothing → 拒绝。
      mFinal <- resolveUnder root rel
      mTmp <- resolveUnder root (rel <> ".tmp")
      case (mFinal, mTmp) of
        (Just final, Just tmp) -> do
          r <- try (derive rel final tmp) :: IO (Either IOException (Either String Derived))
          case r of
            Right (Right d) -> pure (Right d)
            Right (Left m) -> cleanup tmp >> pure (Left (tag m))
            Left ex -> cleanup tmp >> pure (Left (tag ("派生中断（" <> show ex <> "）")))
        _ -> pure (Left (tag "派生件路径不是库内真实路径（.pm/derived 下有链接或别名？），拒绝——人工核查"))
 where
  cleanup tmp = () <$ (try (deleteBoundAt tmp) :: IO (Either IOException ()))
  derive rel final tmp = do
    have <- probeName final
    case have of
      NamePlain | not redo -> reuse rel final
      NamePlain -> deleteBoundAt final >> fresh rel final tmp
      NameMissing -> fresh rel final tmp
      _ -> pure (Left "派生件的名字被链接/别名占住（.pm/derived 下不该有链接），拒绝——人工核查")
  -- 复用：普通名 + 单链接（hardlink 到库外 → 'openStateRead' 抛出 → 外层收成 Left），
  -- sha 在同一句柄上测，不按名字第二次打开。
  reuse rel final = do
    sha <- bracket (openStateRead final) hClose sha256Handle
    snap <- statSnap final
    pure (Right (Derived e (Entry rel (ssSize snap) (ssMtimeNs snap) sha KindPhoto Nothing) True))
  fresh rel final tmp = do
    -- tmp 由 pm 先独占创建（CREATE_NEW；残留的半成品 \/ 同名链接先经 deleteBoundAt
    -- 清掉），python 只往这个 pm 自建的普通文件里写。
    bracket (openFreshBinary tmp) hClose (const (pure ()))
    r <- runPy py ["-", root </> enPath e, tmp] pillowScript secs
    case r of
      Left m -> pure (Left m)
      Right (ExitFailure n, _, err) -> pure (Left ("转换失败（python exit " <> show n <> "）: " <> oneLine err))
      Right (ExitSuccess, _, _) -> do
        -- 复验：仍是普通名（中途被换成链接 → 拒绝）；单链接 + sha 经同一句柄；
        -- 落位是句柄绑定的无覆盖 rename；落位后 size 须与 tmp 上测得的一致。
        pk <- probeName tmp
        if pk /= NamePlain
          then pure (Left "python 退出 0 但派生件不再是普通文件（被替换？），拒绝")
          else do
            sha <- bracket (openStateRead tmp) hClose sha256Handle
            snapT <- statSnap tmp
            when (ssSize snapT == 0) $ ioError (userError "python 退出 0 但派生件是空的")
            moveBoundNoReplace tmp final
            snap <- statSnap final
            unless (ssSize snap == ssSize snapT) $ ioError (userError "落位后大小与 tmp 上测得的不一致")
            pure (Right (Derived e (Entry rel (ssSize snap) (ssMtimeNs snap) sha KindPhoto Nothing) False))

-- | 第二段（纯）：派生件的伪条目经 'classifyInto'（成片同事件夹）与
-- 'classifyAlbum'（相册）判定，相册项按 'attachAlbumItems' 挂到成片项上。
-- 返回（计划项，交代行）；同批撞名本该在 'targetClashes' \/ 'sameDerived' 就被
-- 拒——这里再撞到就是缺口，整批 Left（fail-closed，不再只在交代里提一句）。
convertPlan :: FilePath -> Catalog -> Bool -> [Derived] -> Either [String] ([PlanItem], [String])
convertPlan root cat alsoAlbum ds
  | not (null dups) = Left dups
  | otherwise = Right (items, notes)
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
  dups = [s <> " → " <> t <> " 同批撞名（预检没拦住——请报告）" | (s, t) <- arDupName mrep <> arDupName arep]
  notes =
    ["  = 已落位（同内容）: " <> s <> " ≡ " <> t | (s, t) <- arAlready mrep <> arAlready arep]
      <> ["  ⚠ 目标已有同名不同内容: " <> enPath e <> " → " <> t <> "（待裁决）" | (e, t) <- arConflict mrep <> arConflict arep]

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

-- | 同批里派生件同名的源（同 sha + 同 stem，case-fold）：派生件按
-- @\<sha\>\/\<stem\>.jpg@ 只有一份，两条源会共用同一个伪条目——'convertPlan' 的
-- 目标表按伪条目路径键入，第二条会静默吞掉第一条（步 9 C4）。先于转换拒绝。
sameDerived :: [Entry] -> [String]
sameDerived es =
  [ intercalate " / " (map enPath g) <> " 内容相同且同名（派生件只有一份 .pm/derived/<sha>/<stem>.jpg）——同一张只转一份"
  | g <- Map.elems (Map.fromListWith (flip (<>)) [((enSha e, foldPath (takeBaseName (enPath e))), [e]) | e <- es])
  , length g > 1
  ]

runConvert :: ConvertOpts -> Config -> IO Int
runConvert o cfg = fst <$> runConvertTo putStrLn o cfg

-- | 打印口由调用方给（工作流 F051 的 sink 纪律）。次序同 'Pm.Album.runAlbumAddTo'：
-- 身份闸 → catalog → 全部校验 fail-closed 一次列完 → python 发现与预检 →
-- root 锁内逐条派生（任一失败 → 不出计划；已派生的下次复用）→ 计划。
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
              -- 准入 = 'convertibleExt'（与归档页「非 jpg」栏同一谓词）；jpg 与 RAW 各给原因
              let errs =
                    [r <> " 不在索引里（路径拼错？或先 pm scan）" | (r, Nothing) <- looked]
                      <> [enPath e <> " 不是照片条目" | e <- entries, enKind e /= KindPhoto]
                      <> [enPath e <> " 不在成片/相册下（只转换这两层的照片）" | e <- entries, top e `notElem` [[processedTop], [albumTop]]]
                      <> [enPath e <> " 已经是 jpg（相册直接收：pm album add）" | e <- entries, pushableExt (enPath e)]
                      <> [enPath e <> " 是 RAW 原始档，不是转换对象（转换对象是 tif/png/psd/heic 等已渲染位图）" | e <- entries, isRaw e]
                      <> [enPath e <> " 不是转换对象（只转 tif/png/psd/psb/heic 等已渲染位图）" | e <- entries, not (convertibleExt (enPath e)), not (pushableExt (enPath e)), not (isRaw e)]
                      <> escaped
                      <> targetClashes (coAlsoAlbum o) entries
                      <> sameDerived entries
              if not (null errs)
                then mapM_ (sink . ("  ✗ " <>)) errs >> pure (2, Nothing)
                else do
                  secs <- envTimeout "PM_CONVERT_TIMEOUT" 600
                  epy <- findPython
                  epre <- either (pure . Left) (\py -> fmap (py <$) (preflight py secs)) epy
                  case epre of
                    Left m -> sink ("  ✗ " <> m) >> pure (2, Nothing)
                    Right py -> do
                      mres <- withRootLock root (mapM (deriveOne root py secs (coRedo o)) entries)
                      case mres of
                        Nothing -> sink "另一个 pm 正持有该主库的锁（I10）——等它结束再转换" >> pure (2, Nothing)
                        Just results -> do
                          let fails = [m | Left m <- results]
                              ds = [d | Right d <- results]
                          forM_ ds $ \d ->
                            sink ((if dReused d then "  = 复用派生件 " else "  ⇢ 已派生 ") <> enPath (dSrc d) <> " → " <> enPath (dEntry d))
                          if not (null fails)
                            then do
                              mapM_ (sink . ("  ✗ " <>)) fails
                              sink "（有转换失败，本轮不出计划；修好后重跑——已派生的会复用）"
                              pure (2, Nothing)
                            else case convertPlan root cat (coAlsoAlbum o) ds of
                              Left es -> mapM_ (sink . ("  ✗ " <>)) es >> pure (2, Nothing)
                              Right (items, notes) -> do
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
