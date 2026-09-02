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
  , scanDerived
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))

import Pm.Config (pmDir)
import Pm.Hash (sha256File)
import Pm.Types
import Pm.Win (NameKind (..), probeName)

-- | @.pm@ 下的派生目录名。
derivedSub :: FilePath
derivedSub = "derived"

-- ─── doctor 对账（DESIGN-P8 §20.2） ─────────────────────────────────────────

-- | 派生件的状态：@DerivedStale@ 其 sha 已出现在索引（已落位）；@DerivedOrphan@
-- 目录名 sha 不再是索引里任何条目的 sha（源已不在库里）；@DerivedTmp@ 转换
-- 中断留下的半成品；@DerivedPending@ 派生了还没 apply；@DerivedUnjudged@ 没有
-- 索引，判不了。前三种是 pm 自建状态，@--repair@ 删；后两种只报告。
data DerivedState = DerivedStale | DerivedOrphan | DerivedTmp | DerivedPending | DerivedUnjudged
  deriving (Show, Eq)

-- | 遍历 @.pm\/derived\/\<sha\>\/*@。逐级只认 'NamePlain'（同
-- 'Pm.Doctor.staleTmpFiles'：链接本体不递归不列出 = 不删，fail-closed）；
-- 基目录本身是链接 → Left（不是「没有派生件」：调用方报 Bad，不做任何删除）；
-- 枚举\/读取异常 → Left。
scanDerived :: FilePath -> Maybe Catalog -> IO (Either String [(FilePath, DerivedState)])
scanDerived root mcat = do
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
                              , if sha `Set.member` shas
                                  then DerivedStale
                                  else if T.pack d `Set.notMember` shas then DerivedOrphan else DerivedPending
                              )
                            ]
      pure (either (\e -> Left (show (e :: IOException))) Right r)
    _ -> pure (Left (base <> " 不是普通目录（链接/别名或查不出），派生件对账跳过、不删任何东西——人工核查"))
