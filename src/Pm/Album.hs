{-# LANGUAGE OverloadedStrings #-}

-- | 相册通道（P8-B，DESIGN-P8 §19）：成片 → 相册 的两条入口共用的判定与计划
-- 构造。相册是主库里的**平铺收藏层**（@相册\\\<basename\>@），只收 jpg\/jpeg
-- （'pushableExt'——与 vault 写路径同一谓词，用户裁定 R1 只收 JPEG），是 vault
-- 展示集的上游（I7：vault ⊆ 相册 ⊆ 成片）。
--
--   * @pm import --also-album@：暂存区→成片 的每一条 jpg 拷贝再生成一条**同源**
--     拷贝进相册，与成片项**同组**（'piGroup'）——成片那份没落位，相册那份不执行
--     （'Pm.Exec' 组语义），@--only@ 也拆不开；成片项是返修待裁决时**不分组**、
--     相册项一并压成待裁决（同 'Pm.Ingest.coupleWithMain' 的耦合：复合组成员不能
--     单独 @--keep@ 裁决，分组反而会把返修锁死）。
--   * @pm album add \<事件夹\>\/\<文件名\>…@：成片里已归档的 jpg 挑进相册。
--
-- 判定按 catalog（快照）做，执行期 §6.7 前提复核与落位 no-replace 仍是三重防线。
-- I5：相册同名同 sha → 不出项（幂等），同名异 sha → NEEDS-DECISION；同批 basename
-- 撞车（两个事件夹各有 @_DSC0001.jpg@，case-fold）→ 两条都不出并逐条报告——相册
-- 平铺，同名只能进一份，pm 不替用户挑（I1）。
module Pm.Album
  ( AlbumReport (..)
  , albumTop
  , processedTop
  , classifyAlbum
  , classifyInto
  , albumPlanItems
  , attachAlbumItems
  , withAlbumForImport
  , parseProcessedRel
  , AlbumCandidates (..)
  , albumCandidates
  , runAlbumAdd
  , runAlbumAddTo
  , runAlbumCandidates
  ) where

import Control.Monad (forM, forM_)
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import System.FilePath (joinPath, splitDirectories, takeFileName, (</>))

import Pm.Catalog (catalogOr, loadCatalog)
import Pm.Cli (GoOpts, emitPlanTo)
import Pm.Config (Config (..), requireRole)
import Pm.Import (ImportReport (..), foldPath)
import Pm.Op
import Pm.Plan
import Pm.Types
import Pm.VaultCore (convertibleExt, pushableExt)
import Pm.Win (resolveUnder)

albumTop, processedTop :: FilePath
albumTop = "相册"
processedTop = "成片"

-- | 相册是平铺层：目标 = @相册\\\<源文件名\>@。
albumDst :: Entry -> FilePath
albumDst e = albumTop </> takeFileName (enPath e)

-- | 判定结果五桶：@arNotJpg@ 非 jpg\/jpeg 的源（相册不收 → @pm convert@）；
-- @arDupName@ 同批 basename 撞车（case-fold），两条都不出项；@arConflict@ 相册
-- 已有同名**异** sha → NEEDS-DECISION（I5）；@arAlready@ 相册已有同名同 sha，
-- 幂等不出项（源路径, 相册目标）；@arCopy@ 相册无同名，正常拷贝（源条目, 目标）。
data AlbumReport = AlbumReport
  { arNotJpg :: [FilePath]
  , arDupName :: [(FilePath, FilePath)]
  , arConflict :: [(Entry, FilePath)]
  , arAlready :: [(FilePath, FilePath)]
  , arCopy :: [(Entry, FilePath)]
  }
  deriving (Show, Eq)

-- | 纯判定：给定 catalog 与一组候选源条目，分五桶。两条入口共用这一份定义。
classifyAlbum :: Catalog -> [Entry] -> AlbumReport
classifyAlbum = classifyInto albumDst

-- | 同一份五桶判定，目标由调用方给：'classifyAlbum' 固定落相册平铺层；
-- P8-C2 的 @pm convert@ 用它判派生 jpg 落**成片同事件夹**（目标 = 源目录 +
-- @\<stem\>.jpg@）——同 stem 已在同 sha 跳过、异 sha 待裁决、同批撞名整批拒绝，
-- 口径与相册一份。
classifyInto :: (Entry -> FilePath) -> Catalog -> [Entry] -> AlbumReport
classifyInto dstOf cat es =
  AlbumReport
    { arNotJpg = [enPath e | e <- es, not (pushableExt (enPath e))]
    , arDupName = [(enPath e, dstOf e) | e <- dups]
    , arConflict = [(e, d) | (e, d, Just False) <- judged]
    , arAlready = [(enPath e, d) | (e, d, Just True) <- judged]
    , arCopy = [(e, d) | (e, d, Nothing) <- judged]
    }
 where
  jpgs = filter (pushableExt . enPath) es
  -- 同批目标唯一性按 NTFS 语义（'foldPath'：normalise + case-fold）
  dstCount = Map.fromListWith (+) [(foldPath (dstOf e), 1 :: Int) | e <- jpgs]
  isDup e = Map.findWithDefault 0 (foldPath (dstOf e)) dstCount > 1
  (dups, uniq) = partition isDup jpgs
  catByFold = Map.fromList [(foldPath (enPath x), x) | x <- Map.elems (catEntries cat)]
  judged =
    [ (e, d, (\a -> enSha a == enSha e) <$> Map.lookup (foldPath d) catByFold)
    | e <- uniq
    , let d = dstOf e
    ]

conflictWhy, coupledWhy :: Text
conflictWhy = "相册已有同名但内容不同（I5）→ pm resolve --keep src|dst|both"
coupledWhy = "成片同名项待裁决（I7：先裁决并完成成片那份，再 resolve --unskip 本项）"

mkCopy :: FilePath -> Entry -> FilePath -> Op
mkCopy root e d = OpCopy (root </> enPath e) d (enSha e) (enSize e) (enMtimeNs e)

-- | @pm album add@ 的计划项（序号从 @ix0@ 起）：正常拷贝 PENDING，相册同名异容
-- NEEDS-DECISION。撞名与非 jpg 不进计划（调用方按 fail-closed 整批拒绝）。
albumPlanItems :: FilePath -> Int -> AlbumReport -> [PlanItem]
albumPlanItems root ix0 rep =
  [PlanItem ix op st Nothing | (ix, (op, st)) <- zip [ix0 ..] (copies <> conflicts)]
 where
  copies = [(mkCopy root e d, StPending) | (e, d) <- arCopy rep]
  conflicts = [(mkCopy root e d, StNeedsDecision conflictWhy) | (e, d) <- arConflict rep]

-- | 给 import 计划追加相册项（@--also-album@）。输入：root、catalog、import 报告
-- 与 'Pm.Import.importPlanItems' 已生成的基础条目；输出：分组后的基础条目 +
-- 追加的相册条目，以及相册报告（非 jpg \/ 撞名 \/ 已在相册 \/ 同名异容 的交代
-- 由调用方打印）。
--
-- 组 id = 成片项自己的序号（计划内唯一；import 的基础项此前无组）。只有
-- 「成片项 PENDING」的源才分组；成片项是返修（'irRework' \/ 'irReworkKin'）的，
-- 相册项压成待裁决且不分组。
withAlbumForImport :: FilePath -> Catalog -> ImportReport -> [PlanItem] -> ([PlanItem], AlbumReport)
withAlbumForImport root cat rep base = (attachAlbumItems root base pendingSrc arep, arep)
 where
  isProcessed d = take 1 (splitDirectories d) == [processedTop]
  toProcessed = [e | (e, d) <- irCopy rep <> irRework rep <> irReworkKin rep, isProcessed d]
  arep = classifyAlbum cat toProcessed
  pendingSrc = Set.fromList [enPath e | (e, d) <- irCopy rep, isProcessed d]

-- | 把相册项挂到主层（成片）项上——import @--also-album@ 与 @pm convert@
-- @--also-album@ 共用的耦合规则（P8-C2 上提）：源在 @pendingSrc@ 里（其成片项
-- PENDING，或成片那份早已落位）→ 相册项 PENDING，且若同一计划里有成片项则
-- 与之同组；否则（成片项待裁决 \/ 返修）→ 相册项待裁决且不分组；相册同名异容
-- → 待裁决。@base@ 的源以 @root \</\> enPath@ 定位（'mkCopy' 的形态）。
attachAlbumItems :: FilePath -> [PlanItem] -> Set.Set FilePath -> AlbumReport -> [PlanItem]
attachAlbumItems root base pendingSrc arep = map regroup base <> extra
 where
  ixBySrc = Map.fromList [(opSrcAbs (piOp it), piIx it) | it <- base]
  gidOf e = Map.lookup (root </> enPath e) ixBySrc
  planned =
    [ (e, d, st, g)
    | (e, d) <- arCopy arep
    , let (st, g) =
            if enPath e `Set.member` pendingSrc
              then (StPending, gidOf e)
              else (StNeedsDecision coupledWhy, Nothing)
    ]
      <> [(e, d, StNeedsDecision conflictWhy, Nothing) | (e, d) <- arConflict arep]
  extra = [PlanItem ix (mkCopy root e d) st g | (ix, (e, d, st, g)) <- zip [length base ..] planned]
  groups = Set.fromList [g | (_, _, _, Just g) <- planned]
  regroup it = if piIx it `Set.member` groups then it {piGroup = Just (piIx it)} else it

-- | @pm album add@ 的参数：**相对成片层**的 @\<事件夹\>\/\<文件名\>@（可再深）。
-- 只接受这一种形态——绝对路径、盘符、@..@、@:@、@.pm@（'userRelOk'）、
-- 带 @成片\\@ 前缀、少于两级一律拒绝，不替使用者猜（I1）。
parseProcessedRel :: String -> Either String FilePath
parseProcessedRel s
  | not (userRelOk s) = Left (s <> "：须是相对成片层的相对路径（<事件夹>/<文件名>），不能是绝对路径、带盘符、含 .. 或 :")
  | take 1 comps == [processedTop] = Left (s <> "：不要带 成片\\ 前缀，直接给 <事件夹>/<文件名>")
  | length comps < 2 = Left (s <> "：至少要 <事件夹>/<文件名> 两级")
  | otherwise = Right (processedTop </> joinPath comps)
 where
  comps = splitDirectories s

-- | 归档页 \/ @pm album candidates@ 的只读视图：成片里还没进相册的 jpg（按
-- 事件夹分组；相册有同名**异容**的标 True），以及成片\/相册下的非 jpg 照片
-- （相册不收 → @pm convert@ 的对象；RAW 不列——原始档不是转换对象）。「非 jpg」
-- 栏与 convert 的准入是**同一个**谓词 'convertibleExt'（步 9 簇 C：此前这里
-- 是 @not pushableExt@，把 RAW 也列进去，页面勾上一张 RAW 整批被 convert 拒）。
data AlbumCandidates = AlbumCandidates
  { acEvents :: [(FilePath, [(Entry, Bool)])]
  , acNonJpg :: [Entry]
  }
  deriving (Show, Eq)

albumCandidates :: Catalog -> AlbumCandidates
albumCandidates cat = AlbumCandidates events nonJpg
 where
  photos = [e | e <- Map.elems (catEntries cat), enKind e == KindPhoto]
  top e = take 1 (splitDirectories (enPath e))
  albumByFold = Map.fromList [(foldPath (takeFileName (enPath e)), e) | e <- photos, top e == [albumTop]]
  cand =
    [ (e, conflict)
    | e <- photos
    , top e == [processedTop]
    , pushableExt (enPath e)
    , let m = Map.lookup (foldPath (takeFileName (enPath e))) albumByFold
    , maybe True ((/= enSha e) . enSha) m
    , let conflict = maybe False (const True) m
    ]
  eventOf e = case splitDirectories (enPath e) of (_ : ev : _) -> ev; _ -> ""
  events = sortOn fst (Map.toList (Map.fromListWith (flip (<>)) [(eventOf e, [c]) | c@(e, _) <- cand]))
  nonJpg = [e | e <- photos, top e `elem` [[processedTop], [albumTop]], convertibleExt (enPath e)]

-- ─── IO：pm album add / candidates ──────────────────────────────────────────

runAlbumAdd :: GoOpts -> [String] -> Config -> IO Int
runAlbumAdd go args cfg = fst <$> runAlbumAddTo putStrLn go args cfg

-- | 打印口由调用方给（工作流 F051 的 sink 纪律：serve 端点把交代行收进 JSON）。
-- 次序与 'Pm.Commands.runImport' 同：身份闸先于任何 catalog 读取；一切校验
-- fail-closed，任一条不过就一份计划不出、全部错误一次列完。
runAlbumAddTo :: (String -> IO ()) -> GoOpts -> [String] -> Config -> IO (Int, Maybe Text)
runAlbumAddTo sink go args cfg
  | null args = sink "未给出任何文件（pm album add <事件夹>/<文件名> …；pm album candidates 列出候选）" >> pure (2, Nothing)
  | not (null perrs) = mapM_ (sink . ("  ✗ " <>)) perrs >> pure (2, Nothing)
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
                  looked = [(r, Map.lookup (foldPath r) catByFold) | r <- rels]
                  entries = [e | (_, Just e) <- looked]
              -- 实体闸：每个源都必须是库内真实路径（链接\/别名拒绝，查不出也拒绝）
              escaped <- fmap concat . forM entries $ \e -> do
                m <- resolveUnder root (enPath e)
                pure [enPath e <> " 不是库内真实路径（链接/别名？查不出也拒绝）" | m == Nothing]
              let rep = classifyAlbum cat entries
                  errs =
                    [r <> " 不在索引里（路径拼错？或先 pm scan）" | (r, Nothing) <- looked]
                      <> [enPath e <> " 不是照片条目" | e <- entries, enKind e /= KindPhoto]
                      <> escaped
                      <> [p <> " 不是 jpg/jpeg（相册只收 JPEG）→ pm convert " <> p | p <- arNotJpg rep]
                      <> [s <> " 与本批另一文件同名（相册平铺，同名只能进一份；NTFS 不分大小写）" | (s, _) <- arDupName rep]
              if not (null errs)
                then mapM_ (sink . ("  ✗ " <>)) errs >> pure (2, Nothing)
                else do
                  forM_ (arAlready rep) $ \(s, d) -> sink ("  = 已在相册（同内容）: " <> s <> " ≡ " <> d)
                  forM_ (arConflict rep) $ \(e, d) -> sink ("  ⚠ 相册已有同名不同内容: " <> enPath e <> " → " <> d <> "（待裁决）")
                  let items = albumPlanItems root 0 rep
                  if null items
                    then sink "✓ 无需加入相册（全部已在）" >> pure (0, Nothing)
                    else emitPlanTo sink cfg go "album-add" root info items
 where
  root = cfgMainPath cfg
  parsed = map parseProcessedRel args
  perrs = [e | Left e <- parsed]
  rels = [r | Right r <- parsed]

-- | 只读候选清单（与 @GET \/api\/album\/candidates@ 同源 'albumCandidates'）。
-- 身份闸仍在前（F095：身份闸先于任何目录枚举）。
runAlbumCandidates :: Config -> IO Int
runAlbumCandidates cfg = do
  let root = cfgMainPath cfg
  er <- requireRole RoleMain root
  case er of
    Left msg -> putStrLn msg >> pure 2
    Right _ -> do
      lc <- loadCatalog root
      case catalogOr "主库尚未索引 → 先 pm scan" lc of
        Left m -> putStrLn m >> pure 2
        Right (cat, warns) -> do
          mapM_ (\w -> putStrLn ("⚠ 快照损坏已跳过: " <> w)) warns
          let ac = albumCandidates cat
              n = sum (map (length . snd) (acEvents ac))
          putStrLn ("成片 → 相册 候选 " <> show n <> " 张（" <> show (length (acEvents ac)) <> " 个事件夹）· 非 jpg " <> show (length (acNonJpg ac)) <> " 个")
          forM_ (acEvents ac) $ \(ev, xs) -> do
            putStrLn ("  [" <> ev <> "]")
            forM_ xs $ \(e, conflict) ->
              putStrLn ("      " <> takeFileName (enPath e) <> (if conflict then "  ⚠ 相册有同名不同内容" else ""))
          forM_ (take 1 (acNonJpg ac)) $ \_ -> putStrLn "  非 jpg（相册只收 JPEG → pm convert <路径…>）："
          forM_ (acNonJpg ac) $ \e -> putStrLn ("      " <> enPath e)
          forM_ (take 1 (concatMap snd (acEvents ac))) $ \(e, _) ->
            putStrLn ("加入相册: pm album add " <> joinPath (drop 1 (splitDirectories (enPath e))) <> " …")
          pure 0
