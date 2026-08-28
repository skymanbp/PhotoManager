{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @pm vault ingest@（P6-D，DESIGN-COMMANDS §10.3 第 1/2 项）：skill 调用的
-- 非交互批量入库。pm 只做它 root 内的两次拷贝——@_inbox@ 的成品 JPG →
-- 主库 @相册\/@ + vault @\<类目\>\/@——各自一份计划（计划只属于一个 root）。
--
-- **@_inbox@ 本身不在任何 pm root 内**：把它移进 @_done\/@ 的那一步由调用方
-- （skill）执行，pm 结束时打印显式步骤——与 I9 对 git 的处理完全相同：模型外
-- 的动作不执行、只交代。收尾步骤**只在两份计划都真的全部落完时**打印
-- （三十二轮 R5：源文件被移走后，未完成那半的计划 @opSrcAbs@ 全部失效）。
--
-- **I7 的来源登记**（记录侧）不新造记录类型：主库计划执行时，journal 的
-- @JIntent@ 里的 'Pm.Op.OpCopy' 本来就带**库外**的 @srcAbs@——「相册 ⊆ 成片 ∪
-- inbox-origin」的 inbox-origin 集合 = journal 中 dst 在 @相册\/@ 且 src 在
-- root 外的 Copy 记录。**消费侧（doctor 据此把 inbox 来的照片归为「已解释」）
-- 尚未实现**（三十二轮核对：§10.3 第 2 项只有记录侧就位）。
--
-- 执行协议（三十二轮 R4，退出码一码三义的根因修法）：runPlan 回 'PlanRun'
-- 三态。预览（无 --apply）两份计划**都**存盘并渲染（两段式协议对两份同样
-- 成立），打印执行次序；--apply 时 vault 那份只在主库那份**真的全部落完**
-- （逐项 DONE\/同内容 SKIP，而不是退出码 0——NEEDS-DECISION 不进退出码）后
-- 才执行。生成期再加一道耦合：主库某项是待裁决时，vault 同名那项也压成待
-- 裁决，单独 @pm apply@ vault 计划无法先于相册落下这个名字（I7：vault ⊆ 相册）。
--
-- 生成期的一切源\/目标 IO 都是 fail-closed（三十三轮 F1，与 'Pm.Sort' 二十五
-- 轮确立的「逐文件 try，读取失败整批拒绝」同一纪律）：@doesFileExist@ 通过后
-- 文件被良性进程移走\/占住时，stat\/hash 的异常不逃顶（那是 CLI 崩溃，违反
-- §14 的防崩溃要求），而是聚合成错误清单、退出码 2、一份计划不出。
module Pm.Ingest
  ( runVaultIngest
  , ingestSteps
  ) where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Char (toLower)
import Data.List (intercalate, nub, sort)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (getCurrentTime)
import System.Directory (doesDirectoryExist, doesFileExist, makeAbsolute)
import System.FilePath (takeFileName, (</>))

import Pm.Cli (PlanRun (..), fullyExecuted)
import Pm.Config (Config (..), requireMain)
import Pm.GitGuard (classifyGitProbe)
import Pm.Hash (StatSnap (..), sha256File, statSnap)
import Pm.Op
import Pm.Plan
import Pm.Publish (inboxDoneCommand)
import Pm.Types
import Pm.Vault (ensureVaultRoot, fixedCategories, gitStepsLines)
import Pm.VaultCore (pushableExt)
import Pm.VaultHold (VaultHold (..), readHolds)
import Pm.Win (probeName)

-- | 与 'Pm.Vault.runVaultPush' 同款调用形：@runPlan@ 由命令层给
-- （'Pm.Cli.savePlanAndMaybeRun''），本函数只负责校验、两份计划的构造与
-- 次序协议。@applyMode@ 只用于分辨 'PrSaved' 的成因（纯预览，还是 --apply 下
-- 用户对主库那份答了 n——后者不得再把 vault 那份送进确认流程）。
--
-- fail-closed：任何一条校验不过就一份计划都不出，并把**全部**错误一次列完
-- （skill 好一次修完重试）。
runVaultIngest :: (Plan -> IO PlanRun) -> Bool -> String -> [FilePath] -> Config -> IO Int
runVaultIngest runPlan applyMode cat files0 cfg = do
  files <- mapM makeAbsolute files0
  case cfgVaultPath cfg of
    Nothing -> putStrLn "未配置 vault 路径（pm config set --vault <目录>）" >> pure 2
    Just vaultDir -> do
      errs0 <- validateIngest cfg cat files vaultDir
      if not (null errs0)
        then mapM_ (putStrLn . ("  ✗ " <>)) errs0 >> pure 2
        else do
          -- 三十二轮 R6：与 push 同一道 role 闸（'requireMain'）。readRootInfo
          -- 只看身份存在与否，配置主库路径指错到 backup/vault root 时会把
          -- 相册\ 与 journal 写进错误的 root（家规见 Pm.Config:requireRole）。
          -- 主库身份闸在前、ensureVaultRoot 在后：后者首次会**建** vault
          -- root-id，身份不对的一跑不该留下任何写痕。
          emMain <- requireMain cfg
          case emMain of
            Left m -> putStrLn m >> pure 2
            Right mi -> do
              eVault <- ensureVaultRoot vaultDir
              case eVault of
                Left m -> putStrLn m >> pure 2
                Right vi -> do
                  now <- getCurrentTime
                  -- 源文件逐个取证据。三十二轮 R9：hash 前后双 stat（§6.7，与
                  -- 'Pm.Scan' 的 hashOne 同协议）——_inbox 正是「还在往里写」的
                  -- 目录，单次 stat 会把撕裂 sha 配上最终 (size,mtime)，执行期
                  -- 前提复核照过、落位才 hash 失配，报成介质问题（误诊）。
                  -- 三十三轮 F1：整段逐文件 try——校验通过后源被移走/占住时
                  -- stat/hash 会抛，异常必须变成错误清单而不是 CLI 崩溃。
                  probedE <- forM files $ \f -> do
                    r <- try $ do
                      pre <- statSnap f
                      sha <- sha256File f
                      post <- statSnap f
                      pure (sha, post, pre == post)
                    pure (f, r :: Either IOException (T.Text, StatSnap, Bool))
                  let ioErrs =
                        [ f <> " 读取失败（" <> show e <> "）——校验之后被移走/占住？源必须逐个可读"
                        | (f, Left e) <- probedE
                        ]
                      unstable = [f | (f, Right (_, _, False)) <- probedE]
                  if not (null ioErrs && null unstable)
                    then do
                      mapM_ (putStrLn . ("  ✗ " <>)) ioErrs
                      mapM_ (\f -> putStrLn ("  ✗ " <> f <> " 读取期间在变化（还在写入/同步？）→ 等它稳定后重试")) unstable
                      pure 2
                    else do
                      let probed = [(f, sha, st) | (f, Right (sha, st, True)) <- probedE]
                      mainItemsE <- forM (zip [0 ..] probed) $ \(ix, (f, sha, st)) ->
                        mkItem (cfgMainPath cfg) ("相册" </> takeFileName f) ix f sha st
                      vaultItemsE <- forM (zip [0 ..] probed) $ \(ix, (f, sha, st)) ->
                        mkItem vaultDir (cat </> takeFileName f) ix f sha st
                      let dstErrs = [e | Left e <- mainItemsE <> vaultItemsE]
                      if not (null dstErrs)
                        then mapM_ (putStrLn . ("  ✗ " <>)) dstErrs >> pure 2
                        else do
                          let mainItems = [it | Right it <- mainItemsE]
                              vaultItems = zipWith coupleWithMain mainItems [it | Right it <- vaultItemsE]
                          pidM <- newPlanId
                          pidV <- newPlanId
                          let mainPlan = Plan pidM "vault-ingest" (cfgMainPath cfg) (Just (riId mi)) now mainItems
                              vaultPlan = Plan pidV "vault-ingest" vaultDir (Just (riId vi)) now vaultItems
                          runTwoPlans cfg runPlan applyMode cat files vaultDir mainPlan vaultPlan

-- | 两份计划的次序协议（三十二轮 R4；从 'runVaultIngest' 拆出压嵌套）。
-- 次序 = 主库（相册）在前，vault 只在主库**真的全部落完**后执行（I7 拓扑）。
runTwoPlans :: Config -> (Plan -> IO PlanRun) -> Bool -> String -> [FilePath] -> FilePath -> Plan -> Plan -> IO Int
runTwoPlans cfg runPlan applyMode cat files vaultDir mainPlan vaultPlan = do
  let pidV = plId vaultPlan
  r1 <- runPlan mainPlan
  case r1 of
    PrRefused _ -> pure 2
    PrSaved
      | applyMode -> do
          -- 用户对主库那份答了 n：vault 那份既不执行也不再询问
          -- （答 y 会让 vault 先于相册落下，逆 I7 次序）。
          putStrLn "主库（相册）那份已存盘、未执行（你答了 n）。vault 那份本轮不生成——次序是相册在前（I7）；pm apply 主库那份后重跑本命令"
          pure 1
      | otherwise -> do
          -- 纯预览：两段式协议对两份同样成立（三十二轮，
          -- 此前 vault 那份根本不存盘，预览面缺一半）。
          r2 <- runPlan vaultPlan
          case r2 of
            PrRefused _ -> pure 2
            _ -> do
              mapM_ putStrLn (ingestOrderLines (plId mainPlan) pidV cat)
              pure 1
    PrRun c1 rs1
      | c1 == 0 && fullyExecuted rs1 -> do
          r2 <- runPlan vaultPlan
          case r2 of
            PrRefused _ -> pure 2
            PrSaved -> do
              putStrLn ("vault 那份已存盘未执行：pm apply " <> T.unpack pidV <> "（相册已完成，次序满足）；完成后重跑本命令拿收尾步骤")
              pure 1
            PrRun c2 rs2
              | c2 == 0 && fullyExecuted rs2 -> do
                  mapM_ putStrLn (ingestSteps cfg vaultDir pidV cat files)
                  pure 0
              | otherwise -> do
                  putStrLn "vault 那份有未完成项——收尾步骤不给：**源文件必须留在原位**（计划里的 opSrcAbs 指着它们），pm resolve / pm apply 收敛后重跑本命令"
                  pure (max 1 (max c1 c2))
      | otherwise -> do
          putStrLn "主库（相册）那份有未完成项（失败/冲突/待裁决——待裁决不进退出码，也算未完成）：vault 那份不执行（I7：vault ⊆ 相册，相册在前）；pm resolve 处理后重跑本命令"
          pure (max c1 1)

-- | I7 拓扑耦合（三十二轮 R4 的生成期闸）：主库那项待裁决时，vault 同名项
-- 也压成待裁决。两份计划都会存盘、都可被单独 @pm apply@——vault 那项若保持
-- PENDING，单独 apply vault 计划就能在相册尚无该字节时先写 vault，直接破
-- 「vault ⊆ 相册」。裁决完相册那份后用 @pm resolve <计划> --item <#> --unskip@
-- 恢复本项。
coupleWithMain :: PlanItem -> PlanItem -> PlanItem
coupleWithMain m v
  | StNeedsDecision _ <- piStatus m
  , StPending <- piStatus v =
      v {piStatus = StNeedsDecision "主库（相册）同名项待裁决（I7：先裁决并完成相册那份，再 resolve --unskip 本项）"}
  | otherwise = v

-- | 一条计划项。I5：目标已存在且内容不同 → 生成时即 NEEDS-DECISION（不静默
-- 覆盖，也不静默丢弃——交 @pm resolve --keep@）；同内容 → 照常 PENDING，
-- 执行期落 @SKIP(同内容)@。
--
-- 三十三轮 F1：目标**已存在但读不出**（存在性探测之后被移走\/占住\/ACL）时
-- I5 的同异判不出——fail-closed 返回 Left，调用方聚合后整批拒绝，而不是让
-- hash 异常把 CLI 崩掉。
mkItem :: FilePath -> FilePath -> Int -> FilePath -> T.Text -> StatSnap -> IO (Either String PlanItem)
mkItem root dstRel ix srcAbs sha st = do
  let op = OpCopy srcAbs dstRel sha (ssSize st) (ssMtimeNs st)
      dstAbs = root </> dstRel
  ex <- doesFileExist dstAbs
  est <-
    if not ex
      then pure (Right StPending)
      else do
        edsha <- try (sha256File dstAbs) :: IO (Either IOException T.Text)
        pure $ case edsha of
          Left e ->
            Left (dstAbs <> " 已存在但读不出（" <> show e <> "）——I5 同异判不出，整批拒绝")
          Right dsha
            | dsha == sha -> Right StPending -- 执行期 OSkippedIdentical，不再重拷
            | otherwise -> Right (StNeedsDecision "目标已存在且内容不同（I5）→ pm resolve --keep src|dst|both")
  pure ((\s -> PlanItem ix op s Nothing) <$> est)

-- | 全部校验错误一次列完。三十二轮补两道与 push 对齐的闸：
--
--   * **跨类目占名**：push 的 NEW 集合按名字跨全部类目索引，ingest 此前只探
--     自己类目一格——同名已发布在别的类目时照拷，制造 DUPLICATE（六态里
--     不进退出码的那个状态）。
--   * **「暂不同步」名单**：push 被 HELD 挡（先 unhold），设计给非交互 skill
--     用的 ingest 不得更松；名单读不出（损坏\/不可信）同样 fail-closed。
--
-- 批内重名判定 case-fold（三十二轮 R7，与 'Pm.Names' 的同批目标唯一性同
-- 口径）：NTFS 不分大小写，@IMG_0001.JPG@ 与 @img_0001.jpg@ 是同一个目标格。
validateIngest :: Config -> String -> [FilePath] -> FilePath -> IO [String]
validateIngest cfg cat files vaultDir = do
  vaultOk <- doesDirectoryExist vaultDir
  missing <- forM files $ \f -> do
    ex <- doesFileExist f
    pure ([f <> " 不存在（源文件必须逐个在盘上）" | not ex])
  -- 第一方自审 R1：占名探测三态（36 轮的 'classifyGitProbe' 表）——@doesFileExist@
  -- 把 ACL 拒绝塌成「无占名」，跨类目 DUPLICATE 就漏检；查不出 = 拒绝本批。
  crossCat <- forM files $ \f -> do
    let n = takeFileName f
    probes <- forM [c | c <- fixedCategories, c /= cat] $ \c ->
      (,) c . classifyGitProbe <$> probeName (vaultDir </> c </> n)
    let hits = [c | (c, Right True) <- probes]
    pure $
      [ n <> " 已存在于 vault 类目 " <> unwords hits <> "（跨类目同名会成 DUPLICATE）→ 先处置既有那份（或换名）"
      | not (null hits)
      ]
        <> [n <> " 在 vault 类目 " <> c <> " 的占名" <> why | (c, Left why) <- probes]
  eholds <- readHolds (cfgMainPath cfg)
  -- HELD 比较 case-fold（三十二轮交叉复核 R8）：NTFS 不分大小写，A.JPG 与
  -- a.jpg 是同一个目标格——精确比较会让大小写变体绕过用户的「暂不同步」
  -- 决定，而 ingest 是非交互入口，绕过即静默发布。push 侧的精确匹配是
  -- P4-7 的失效语义（改名 → 决定失效 → 照片浮回 NEW 重新问），不静默发布，
  -- 维持原样并在 REVIEW-LOG 登记。
  let nameKey = map toLower . takeFileName
      holdErrs = case eholds of
        Left m -> ["「暂不同步」名单读取失败（fail-closed，不当作无决定）: " <> m]
        Right hs ->
          [ takeFileName f <> " 在「暂不同步」名单里 → 先 pm vault unhold " <> takeFileName f <> "（决定若因字节已变失效，unhold 后重试）"
          | f <- files
          , nameKey f `elem` map (map toLower . vhName) hs
          ]
      dupNames =
        [ intercalate " / " (sort (nub (map takeFileName fs)))
            <> " 在本批出现 " <> show (length fs)
            <> " 次（NTFS 不分大小写；相册与类目都是平铺，同名只能进一份）"
        | (_, fs) <- Map.toList (Map.fromListWith (<>) [(map toLower (takeFileName f), [f]) | f <- files])
        , length fs > 1
        ]
      -- P8-B：与 push 写路径、相册通道同一谓词（'Pm.VaultCore.pushableExt'）——
      -- 此前这里是第二份 jpg 定义（DESIGN-P8 §19.1）。
      badExt = [f <> " 不是 jpg/jpeg（相册与 vault 只收成品 JPG）" | f <- files, not (pushableExt f)]
  pure . concat $
    [ ["未给出任何源文件（pm vault ingest <文件…> --category <类目>）" | null files]
    , ["类目不存在: " <> cat <> "（可选: " <> unwords fixedCategories <> "）" | cat `notElem` fixedCategories]
    , ["vault 路径不存在: " <> vaultDir | not vaultOk]
    , concat missing
    , concat crossCat
    , holdErrs
    , sort (nub dupNames)
    , badExt
    ]

-- | 纯预览收尾：两份计划都已存盘，把次序说清楚（I7：相册在前）。
ingestOrderLines :: T.Text -> T.Text -> String -> [String]
ingestOrderLines pidM pidV cat =
  [ ""
  , "两份计划均已存盘（两段式）。执行次序（I7 拓扑，相册在前）："
  , "  1. pm apply " <> T.unpack pidM <> "   （主库 相册\\）"
  , "  2. pm apply " <> T.unpack pidV <> "   （vault " <> cat <> "\\；须在 1 完成后执行）"
  , "两份都完成后重跑 pm vault ingest --apply --yes 同一批文件（已落项自动 SKIP）即打印收尾步骤"
  ]

-- | 结束时打印的**显式步骤**——pm 不执行的那些（同 I9 的 git 步骤）：
-- photos.json 由 skill 写并校验；@_inbox → _done@ 由 skill 移（pm 对库外目录
-- 零操作）；vault 仓的 git 步骤沿用 push 的同一套。只在两份计划都真的全部
-- 落完时打印（三十二轮 R5；判据 'Pm.Cli.fullyExecuted'——push 的收尾自
-- 第一方自审工作流 F068 起同样按落位项判（'Pm.Cli.landedItems'），只是这里
-- 要求**全部**落完：源文件搬走后未落完那半的计划就失效）。
-- 搬移命令与 git 步骤同一纪律（第一方自审工作流 F072）：经
-- 'Pm.Publish.inboxDoneCommand' 解析-重渲染，嵌不进命令行的路径给手动指引。
ingestSteps :: Config -> FilePath -> T.Text -> String -> [FilePath] -> [String]
ingestSteps cfg vaultDir pid cat files =
  [ ""
  , "pm 侧完成。剩余步骤由调用方执行（pm 不动库外目录、不执行 git）："
  , "  1. 写 photos.json 并用 json.tool 校验（AI 分类与坐标归 skill）"
  , "  2. 校验通过后，把以下源文件移入各自目录的 _done\\ 子目录："
  ]
    <> concatMap moveLine files
    <> gitStepsLines cfg vaultDir pid [cat]
 where
  moveLine f = case inboxDoneCommand f of
    Right l -> ["       " <> l]
    Left why -> ["       （无法安全生成搬移命令：" <> why <> "）请手动把 " <> takeFileName f <> " 移进同目录的 _done\\"]
