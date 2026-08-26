{-# LANGUAGE OverloadedStrings #-}

-- | @pm vault ingest@（P6-D，DESIGN-COMMANDS §10.3 第 1/2 项）：skill 调用的
-- 非交互批量入库。pm 只做它 root 内的两次拷贝——@_inbox@ 的成品 JPG →
-- 主库 @相册\/@ + vault @\<类目\>\/@——各自一份计划（计划只属于一个 root）。
--
-- **@_inbox@ 本身不在任何 pm root 内**：把它移进 @_done\/@ 的那一步由调用方
-- （skill）执行，pm 结束时打印显式步骤——与 I9 对 git 的处理完全相同：模型外
-- 的动作不执行、只交代。
--
-- **I7 的来源登记**不新造记录类型：主库计划执行时，journal 的 @JIntent@ 里
-- 的 'Pm.Op.OpCopy' 本来就带**库外**的 @srcAbs@——「相册 ⊆ 成片 ∪
-- inbox-origin」的 inbox-origin 集合 = journal 中 dst 在 @相册\/@ 且 src 在
-- root 外的 Copy 记录。doctor 由此把 inbox 来的照片归为「已解释」。
module Pm.Ingest
  ( runVaultIngest
  , ingestSteps
  ) where

import Control.Monad (forM)
import Data.List (nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute)
import System.FilePath (takeDirectory, takeFileName, (</>))

import Pm.Config (Config (..), readRootInfo)
import Pm.Hash (StatSnap (..), sha256File, statSnap)
import Pm.Op
import Pm.Plan
import Pm.Types
import Pm.Vault (ensureVaultRoot, fixedCategories, gitStepsLines)

-- | 与 'Pm.Vault.runVaultPush' 同款调用形：@runPlan@ 由命令层给
-- （'Pm.Cli.savePlanAndMaybeRun'），本函数只负责校验与两份计划的构造。
--
-- fail-closed：任何一条校验不过就一份计划都不出，并把**全部**错误一次列完
-- （skill 好一次修完重试）。两份计划的执行次序 = 主库在前（相册是上游，
-- I7 的拓扑方向）；主库那份失败即停，不再执行 vault 那份。
runVaultIngest :: (Plan -> IO Int) -> String -> [FilePath] -> Config -> IO Int
runVaultIngest runPlan cat files0 cfg = do
  files <- mapM makeAbsolute files0
  case cfgVaultPath cfg of
    Nothing -> putStrLn "未配置 vault 路径（pm config set --vault <目录>）" >> pure 2
    Just vaultDir -> do
      errs0 <- validateIngest cat files vaultDir
      if not (null errs0)
        then mapM_ (putStrLn . ("  ✗ " <>)) errs0 >> pure 2
        else do
          mMain <- readRootInfo (cfgMainPath cfg)
          eVault <- ensureVaultRoot vaultDir
          case (mMain, eVault) of
            (Nothing, _) -> putStrLn "主库无身份（先 pm init）" >> pure 2
            (_, Left m) -> putStrLn m >> pure 2
            (Just mi, Right vi) -> do
              now <- getCurrentTime
              -- 源文件逐个取证据：sha + (size, mtime) 前提（执行期逐项复核）
              probed <- forM files $ \f -> do
                sha <- sha256File f
                st <- statSnap f
                pure (f, sha, st)
              mainItems <- forM (zip [0 ..] probed) $ \(ix, (f, sha, st)) ->
                mkItem (cfgMainPath cfg) ("相册" </> takeFileName f) ix f sha st
              vaultItems <- forM (zip [0 ..] probed) $ \(ix, (f, sha, st)) ->
                mkItem vaultDir (cat </> takeFileName f) ix f sha st
              pidM <- newPlanId
              pidV <- newPlanId
              let mainPlan = Plan pidM "vault-ingest" (cfgMainPath cfg) (Just (riId mi)) now mainItems
                  vaultPlan = Plan pidV "vault-ingest" vaultDir (Just (riId vi)) now vaultItems
              c1 <- runPlan mainPlan
              if c1 /= 0
                then do
                  putStrLn "主库（相册）那份计划未完成，vault 那份不再继续（次序：相册在前，I7 拓扑方向）"
                  pure (max c1 1)
                else do
                  c2 <- runPlan vaultPlan
                  mapM_ putStrLn (ingestSteps vaultDir pidV cat files)
                  pure (max c1 c2)

-- | 一条计划项。I5：目标已存在且内容不同 → 生成时即 NEEDS-DECISION（不静默
-- 覆盖，也不静默丢弃——交 @pm resolve --keep@）；同内容 → 照常 PENDING，
-- 执行期落 @SKIP(同内容)@。
mkItem :: FilePath -> FilePath -> Int -> FilePath -> T.Text -> StatSnap -> IO PlanItem
mkItem root dstRel ix srcAbs sha st = do
  let op = OpCopy srcAbs dstRel sha (ssSize st) (ssMtimeNs st)
      dstAbs = root </> dstRel
  ex <- doesFileExist dstAbs
  status <-
    if not ex
      then pure StPending
      else do
        dsha <- sha256File dstAbs
        pure $
          if dsha == sha
            then StPending -- 执行期 OSkippedIdentical，不再重拷
            else StNeedsDecision "目标已存在且内容不同（I5）→ pm resolve --keep src|dst|both"
  pure (PlanItem ix op status Nothing)

-- | 全部校验错误一次列完。
validateIngest :: String -> [FilePath] -> FilePath -> IO [String]
validateIngest cat files vaultDir = do
  vaultOk <- doesDirectoryExist vaultDir
  missing <- forM files $ \f -> do
    ex <- doesFileExist f
    pure ([f <> " 不存在（源文件必须逐个在盘上）" | not ex])
  let dupNames =
        [ n <> " 在本批出现 " <> show (length fs) <> " 次（相册与类目都是平铺，同名只能进一份）"
        | (n, fs) <- Map.toList (Map.fromListWith (<>) [(takeFileName f, [f]) | f <- files])
        , length fs > 1
        ]
      badExt = [f <> " 不是 jpg/jpeg（相册与 vault 只收成品 JPG）" | f <- files, not (jpegExt f)]
  pure . concat $
    [ ["未给出任何源文件（pm vault ingest <文件…> --category <类目>）" | null files]
    , ["类目不存在: " <> cat <> "（可选: " <> unwords fixedCategories <> "）" | cat `notElem` fixedCategories]
    , ["vault 路径不存在: " <> vaultDir | not vaultOk]
    , concat missing
    , sort (nub dupNames)
    , badExt
    ]
 where
  jpegExt f = case reverse (map toLowerC (takeFileName f)) of
    ('g' : 'p' : 'j' : '.' : _) -> True
    ('g' : 'e' : 'p' : 'j' : '.' : _) -> True
    _ -> False
  toLowerC c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | 结束时打印的**显式步骤**——pm 不执行的那些（同 I9 的 git 步骤）：
-- photos.json 由 skill 写并校验；@_inbox → _done@ 由 skill 移（pm 对库外目录
-- 零操作）；vault 仓的 git 步骤沿用 push 的同一套。
ingestSteps :: FilePath -> T.Text -> String -> [FilePath] -> [String]
ingestSteps vaultDir pid cat files =
  [ ""
  , "pm 侧完成。剩余步骤由调用方执行（pm 不动库外目录、不执行 git）："
  , "  1. 写 photos.json 并用 json.tool 校验（AI 分类与坐标归 skill）"
  , "  2. 校验通过后，把以下源文件移入各自目录的 _done\\ 子目录："
  ]
    <> [ "       move \"" <> f <> "\" \"" <> takeDirectory f </> "_done" <> "\\\"" | f <- files]
    <> gitStepsLines vaultDir pid [cat]
