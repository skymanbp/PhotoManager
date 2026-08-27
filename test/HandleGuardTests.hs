{-# LANGUAGE OverloadedStrings #-}

-- | P5-D：句柄身份守卫（「打开 → 用**句柄**确认它绑定的路径 → 再读」）。
-- P7 自 "PathGuardTests" 拆出（750 行预算），用例逐字搬移（这两条用例
-- 自带 mklink 夹具，不依赖那边的构造器）。
module HandleGuardTests (handleGuardTests) where

import System.Directory (canonicalizePath, createDirectoryIfMissing, removeDirectory, renameFile)
import System.FilePath ((</>))
import Control.Exception (SomeException, bracket, try)
import Data.List (isInfixOf)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import System.IO (IOMode (ReadMode), hClose, hGetContents', openBinaryFile, stdin, withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readCreateProcess, shell)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Cli (GoOpts (..), confirm)
import Pm.Win (handleFinalPath, handleIsAt, openBoundTo, resolveUnder)
import TestUtil (captureStdout)

handleGuardTests :: TestTree
handleGuardTests =
  testGroup
    "P5-D 句柄身份守卫（P7 自 PathGuardTests 拆出）"
    [ testCase "P5-D 句柄反查路径：中途 junction / 末级 symlink 判否；普通文件、库内 hardlink、root 经 junction 判是" caseHandleIsAt
    , testCase "P5-D 解析之后、打开之前把中途一层换成 junction → openBoundTo 拒绝，裸 open 会读到库外（窗口已关）" caseResolveThenSwap
    , testCase "工作流 F020：确认口 stdin 是 EOF（NUL 设备）→ 按「否」返回 False，不抛 isEOFError" caseConfirmEofIsNo
    ]

-- | 设备命名空间的写法；裸 "NUL" 走的是 GHC 的普通路径打开，会 does not exist。
nulDevice :: FilePath
nulDevice = [bsl, bsl, toEnum 46, bsl] <> "NUL"
 where
  bsl = toEnum 92 :: Char

-- | 两段式确认的 stdin 关闭：`pm … --apply < NUL`、管道上游先退出、GUI 起的
-- 子进程——都是 EOF。'confirm' 此前裸 getLine，isEOFError 逃到 RTS：计划已存、
-- 字节未动，却在确认口打出一串堆栈。EOF 必须等于「否」。
caseConfirmEofIsNo :: IO ()
caseConfirmEofIsNo = do
  saved <- hDuplicate stdin
  (_, r) <-
    captureStdout $
      withBinaryFile nulDevice ReadMode $ \h -> do
        hDuplicateTo h stdin
        r <- try (confirm (GoOpts True False)) :: IO (Either SomeException Bool)
        hDuplicateTo saved stdin
        pure r
  hClose saved
  case r of
    Right b -> b @?= False
    Left e -> assertFailure ("EOF 不得以异常逃逸: " <> show e)

-- | P5-D 的地基（codex 二十八轮 #1）：把「解析出路径 → 按名字重开」换成
-- 「打开 → 用**句柄**确认它绑定的正是那条路径」。
--
-- 这条用例钉住 @GetFinalPathNameByHandleW@ 在五种别名形态下的**实测**行为，
-- 因为整条修法的正确性全压在它身上：
--
--  * 中途一层是 junction → 句柄绑到库外，反查出来的路径与期望不符 → 判否；
--  * 末级是文件 symlink → 同上；
--  * 普通文件 → 判是；
--  * 库内 hardlink（另一个名字在库外）→ **判是**。这是对的：那条路径上确实
--    有一个可读到这些字节的对象；它算不算"另一份独立副本"由 'FileId' 回答，
--    不由路径回答（第 28 轮 #2）。
--  * root 自身是 junction → 判是。root 由用户指定，把库根放在 junction 上是
--    合法用法（'resolveUnder' 的文档一直这么写）。
caseHandleIsAt :: IO ()
caseHandleIsAt = withSystemTempDirectory "pm-final" $ \tmp -> do
  let root = tmp </> "lib"
      outside = tmp </> "outside"
      q p = [dq] <> p <> [dq]
      dq = toEnum 34 :: Char
  createDirectoryIfMissing True (root </> "Raw")
  createDirectoryIfMissing True outside
  writeFile (root </> "Raw" </> "real.ARW") "inside"
  writeFile (outside </> "bait.ARW") "outside-bait"
  writeFile (outside </> "hltarget.ARW") "hl-target"
  _ <- readCreateProcess (shell ("mklink /J " <> q (root </> "Raw" </> "jn") <> " " <> q outside)) ""
  _ <- readCreateProcess (shell ("mklink " <> q (root </> "Raw" </> "sl.ARW") <> " " <> q (outside </> "bait.ARW"))) ""
  _ <- readCreateProcess (shell ("mklink /H " <> q (root </> "Raw" </> "hl.ARW") <> " " <> q (outside </> "hltarget.ARW"))) ""
  _ <- readCreateProcess (shell ("mklink /J " <> q (tmp </> "rootlink") <> " " <> q root)) ""
  croot <- canonicalizePath root
  let at rel = isAtVia (croot </> rel)
  at ("Raw" </> "real.ARW") >>= (@?= True)
  at ("Raw" </> "jn" </> "bait.ARW") >>= (@?= False)
  at ("Raw" </> "sl.ARW") >>= (@?= False)
  at ("Raw" </> "hl.ARW") >>= (@?= True)
  -- root 经 junction 到达：canonicalizePath 把它折回真身，判是
  clink <- canonicalizePath (tmp </> "rootlink")
  isAtVia (clink </> "Raw" </> "real.ARW") >>= (@?= True)
  -- 反查确实拿得到路径（不是靠 Nothing 一路判否蒙对的）
  -- NUL 设备：不是文件系统里的对象，反查必然失败 → 必须判否（fail-closed）。
  -- 这一格钉住的是 handleIsAt 的 Nothing 分支：真实场景是没有盘符的挂载卷
  -- （VOLUME_NAME_DOS 拿不到路径），那时候放行就等于凭空信任一个句柄。
  nulPath <- bracket (openBinaryFile nulDevice ReadMode) hClose handleFinalPath
  nulPath @?= Nothing
  bracket (openBinaryFile nulDevice ReadMode) hClose (\h -> handleIsAt h nulDevice) >>= (@?= False)
  mp <- bracket (openBinaryFile (croot </> "Raw" </> "real.ARW") ReadMode) hClose handleFinalPath
  case mp of
    Just p -> assertBool ("反查应给出带 real.ARW 的路径: " <> p) ("real.ARW" `isInfixOf` p)
    Nothing -> assertFailure "handleFinalPath 应能取到普通文件的路径"
 where
  isAtVia p = bracket (openBinaryFile p ReadMode) hClose (\h -> handleIsAt h p)


-- | 第 28 轮 #1 的正面回答：解析与打开之间的窗口。
--
-- 时序由用例控制，所以这不是片状竞态测试而是确定性事件：
--
--  1. 'resolveUnder' 给出路径——此刻库内一切合法，逐级下降全是真名；
--  2. **然后**把中途那一层换成指向库外的 junction（攻击者在窗口里做的事）；
--  3. 再打开那条路径。
--
-- 裸 'openBinaryFile' 在第 3 步读到的是**库外**的诱饵——这一半也要断言，
-- 否则用例只证明新写法拒绝了，不证明它拒绝的是一个真实存在的危险。
-- 'openBoundTo' 必须抛出：句柄反查出来的路径落在库外，与期望不符。
caseResolveThenSwap :: IO ()
caseResolveThenSwap = withSystemTempDirectory "pm-swap" $ \tmp -> do
  let root = tmp </> "lib"
      outside = tmp </> "outside"
      stash = tmp </> "stash"
      q p = [dq] <> p <> [dq]
      dq = toEnum 34 :: Char
  createDirectoryIfMissing True (root </> "Raw")
  createDirectoryIfMissing True outside
  createDirectoryIfMissing True stash
  writeFile (root </> "Raw" </> "real.ARW") "INSIDE"
  writeFile (outside </> "real.ARW") "OUTSIDE-BAIT"
  -- ① 解析：此刻 Raw 是真目录
  mp <- resolveUnder root ("Raw" </> "real.ARW")
  p <- case mp of
    Nothing -> assertFailure "解析应成功（此刻库内一切合法）" >> pure ""
    Just p -> pure p
  -- ② 窗口：把 Raw 换成指向库外的 junction
  renameFile (root </> "Raw" </> "real.ARW") (stash </> "real.ARW")
  removeDirectory (root </> "Raw")
  _ <- readCreateProcess (shell ("mklink /J " <> q (root </> "Raw") <> " " <> q outside)) ""
  -- ③ 裸 open 会读到库外——这就是旧写法在这一步的结果
  naive <- bracket (openBinaryFile p ReadMode) hClose hGetContents'
  naive @?= "OUTSIDE-BAIT"
  -- ③' 句柄绑定判定必须拒绝
  r <- try (bracket (openBoundTo ReadMode p) hClose hGetContents') :: IO (Either SomeException String)
  case r of
    Left e -> assertBool ("错误应说明句柄绑定不符: " <> show e) ("句柄绑定" `isInfixOf` show e)
    Right c -> assertFailure ("openBoundTo 不应读出任何内容，却得到 " <> show c)
