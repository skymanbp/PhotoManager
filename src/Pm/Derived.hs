{-# LANGUAGE OverloadedStrings #-}

-- | 派生目录（@.pm\/derived@）的**对账口**——1.1.2 从 "Pm.Convert" 拆出，搬移为
-- 字节级、零语义改动（'derivedSub' \/ 'DerivedState' \/ 'scanDerived'，Convert
-- 原地再导出）。拆的原因是模块依赖：'Pm.Doctor' 只为对账派生件而 import 整个
-- Convert，Convert 又 import 'Pm.Cli'（emitPlanTo），于是 Cli 无法 import Doctor
-- ——而瞬断保护（'Pm.Removable'，DESIGN §6.4 末段）要在 'Pm.Cli.executePlanNowWith'
-- 的续跑之间调 @doctor --repair@ 补记 Done。对账口本就不依赖转换本身（python、
-- 计划生成），单独成模块后 Doctor → Derived 不再经过 Cli。
module Pm.Derived
  ( DerivedState (..)
  , derivedSub
  , derivedRefs
  , scanDerived
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.List (intercalate, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (makeRelative, splitDirectories, takeExtension, (</>))

import Pm.Config (pmDir)
import Pm.Hash (sha256File)
import Pm.Import (foldPath)
import Pm.Op (Op (..))
import Pm.Plan (Plan (..), PlanExec (..), PlanItem (..))
import Pm.Types
import Pm.Win (NameKind (..), probeName)

-- | @.pm@ 下的派生目录名。
derivedSub :: FilePath
derivedSub = "derived"

-- ─── doctor 对账（DESIGN-P8 §20.2） ─────────────────────────────────────────

-- | 派生件的状态：@DerivedStale@ 其 sha 已出现在索引（已落位）；@DerivedOrphan@
-- 目录名 sha 不再是索引里任何条目的 sha（源已不在库里）；@DerivedTmp@ 转换
-- 中断留下的半成品；@DerivedPending@ 派生了还没 apply；@DerivedUnjudged@ 没有
-- 索引，判不了；@DerivedKept@ 按 sha 本该是前两种，但还有没做完的计划项引用它、或
-- 计划读不全核不了（审计 #31：@--also-album@ 的成片 \/ 相册两项共用一份派生件，成片
-- 那份落位后它判成 STALE，相册项还待裁决——删了，那一项 apply 时「源 stat 失败」）。
-- 前三种是 pm 自建状态，@--repair@ 删；后三种只报告。
data DerivedState = DerivedStale | DerivedOrphan | DerivedTmp | DerivedPending | DerivedUnjudged | DerivedKept String
  deriving (Show, Eq)

-- | 还没做完的计划项（计划文件里什么状态都算，只要 journal 里没有它的 Done）引用的派生件
-- → 引用它的计划 id。键是相对 root 的 case-fold 路径（计划的 root 路径可能按 UUID 重新绑定过）。
derivedRefs :: [Plan] -> Map.Map Text PlanExec -> Map.Map FilePath [Text]
derivedRefs plans execs =
  Map.fromListWith (<>)
    [ (key, [plId p])
    | p <- plans
    , let done = maybe Set.empty peDone (Map.lookup (plId p) execs)
    , it <- plItems p
    , piIx it `Set.notMember` done
    , OpCopy {opSrcAbs = src} <- [piOp it]
    , let key = foldPath (makeRelative (plRootPath p) src)
    , take 2 (splitDirectories key) == [".pm", derivedSub]
    ]

-- | 遍历 @.pm\/derived\/\<sha\>\/*@。逐级只认 'NamePlain'（同
-- 'Pm.Doctor.staleTmpFiles'：链接本体不递归不列出 = 不删，fail-closed）；
-- 基目录本身是链接 → Left（不是「没有派生件」：调用方报 Bad，不做任何删除）；
-- 枚举\/读取异常 → Left。@refs@ 是 'derivedRefs'；Left = 有计划读不出（核不了谁还引用它）。
scanDerived :: FilePath -> Maybe Catalog -> Either String (Map.Map FilePath [Text]) -> IO (Either String [(FilePath, DerivedState)])
scanDerived root mcat refs = do
  let base = pmDir root </> derivedSub
      shas = maybe Set.empty (Set.fromList . map enSha . Map.elems . catEntries) mcat
  bk <- probeName base
  ex <- doesDirectoryExist base
  case bk of
    NameMissing -> pure (Right [])
    NamePlain | not ex -> pure (Right [])
    NamePlain -> do
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
                              , held fp $
                                  if sha `Set.member` shas
                                    then DerivedStale
                                    else if T.pack d `Set.notMember` shas then DerivedOrphan else DerivedPending
                              )
                            ]
      pure (either (\e -> Left (show (e :: IOException))) Right r)
    _ -> pure (Left (base <> " 不是普通目录（链接/别名或查不出），派生件对账跳过、不删任何东西——人工核查"))
 where
  held fp s
    | s `notElem` [DerivedStale, DerivedOrphan] = s
    | otherwise = case refs of
        Left why -> DerivedKept ("计划读不全（" <> why <> "），核不了有没有计划还引用它，本轮不删")
        Right m -> maybe s (DerivedKept . refNote) (Map.lookup (foldPath (makeRelative root fp)) m)
  refNote pids = "计划 " <> intercalate "、" (map T.unpack (nub pids)) <> " 还有没做完的项引用它（apply / resolve 完或删掉计划后再清）"
