{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (IOException, try)
import qualified Data.Map.Strict as Map
import Data.Time (getCurrentTime)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Pm.Catalog
import Pm.Hash
import Pm.Types
import Pm.Win (moveFileNoReplace, setupConsole)

main :: IO ()
main = do
  setupConsole
  defaultMain tests

tests :: TestTree
tests =
  testGroup
    "pm P0"
    [ hashTests
    , classifyTests
    , catalogTests
    , moveTests
    ]

hashTests :: TestTree
hashTests =
  testGroup
    "Pm.Hash"
    [ testCase "sha256 of empty file (NIST vector)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let fp = dir </> "empty.bin"
          writeFile fp ""
          h <- sha256File fp
          h @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    , testCase "sha256 of \"abc\" (NIST vector)" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let fp = dir </> "abc.bin"
          writeFile fp "abc"
          h <- sha256File fp
          h @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    ]

classifyTests :: TestTree
classifyTests =
  testGroup
    "Pm.Types.classifyExt (case-fold)"
    [ testCase ".JPG is photo" (classifyExt ".JPG" @?= KindPhoto)
    , testCase ".arw is photo" (classifyExt ".arw" @?= KindPhoto)
    , testCase ".Xmp is sidecar" (classifyExt ".Xmp" @?= KindSidecar)
    , testCase ".acr is sidecar" (classifyExt ".acr" @?= KindSidecar)
    , testCase ".txt is meta" (classifyExt ".txt" @?= KindMeta)
    ]

catalogTests :: TestTree
catalogTests =
  testGroup
    "Pm.Catalog"
    [ testCase "save/load roundtrip incl. CJK path" $
        withSystemTempDirectory "pm-test" $ \root -> do
          now <- getCurrentTime
          let e1 = Entry ("相册" </> "测试照片.JPG") 42 123456789 "aa" KindPhoto
              e2 = Entry ("Raw" </> "2023" </> "x.ARW") 7 9 "bb" KindPhoto
              cat = Catalog "rid-1" now (entryMap [e1, e2])
          saveCatalog root cat
          (loaded, warns) <- loadCatalog root
          warns @?= []
          fmap catRootId loaded @?= Just "rid-1"
          fmap catEntries loaded @?= Just (catEntries cat)
    , testCase "rotation keeps 3 generations, newest wins" $
        withSystemTempDirectory "pm-test" $ \root -> do
          now <- getCurrentTime
          let mk rid = Catalog rid now (entryMap [])
          mapM_ (saveCatalog root . mk) ["g1", "g2", "g3", "g4"]
          let base = catalogPath root
          e0 <- doesFileExist base
          e1 <- doesFileExist (base <> ".1")
          e2 <- doesFileExist (base <> ".2")
          (e0, e1, e2) @?= (True, True, True)
          (loaded, _) <- loadCatalog root
          fmap catRootId loaded @?= Just "g4"
    ]

moveTests :: TestTree
moveTests =
  testGroup
    "Pm.Win.moveFileNoReplace (I5 cornerstone)"
    [ testCase "refuses when destination exists" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let a = dir </> "a.txt"
              b = dir </> "b.txt"
          writeFile a "AAA"
          writeFile b "BBB"
          r <- try (moveFileNoReplace a b) :: IO (Either IOException ())
          case r of
            Left _ -> pure ()
            Right () -> assertFailure "moveFileNoReplace overwrote an existing destination"
          -- both files untouched
          ca <- readFile a
          cb <- readFile b
          (ca, cb) @?= ("AAA", "BBB")
    , testCase "moves when destination absent" $
        withSystemTempDirectory "pm-test" $ \dir -> do
          let a = dir </> "a.txt"
              c = dir </> "c.txt"
          writeFile a "AAA"
          moveFileNoReplace a c
          ea <- doesFileExist a
          cc <- readFile c
          (ea, cc) @?= (False, "AAA")
    ]
