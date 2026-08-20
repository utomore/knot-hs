-- | F001 scan-baseline 1-to-1 測試(對照表:T1..T9)。
module Main (main) where

import Control.Monad (forM_)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text as T

import Hedgehog (forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Knot.App.Summary (renderMetaSummary)
import Knot.Meta (loadProjectMeta)
import Knot.Meta.Discovery (findCabalFiles)
import Knot.Meta.SourceIndex (indexSources, moduleNameFromPath)
import Knot.Meta.Types
  ( MetaOptions (..)
  , MetaWarning (..)
  , ModuleName (..)
  , ProjectMeta (..)
  , SourceFile (..)
  )

projFixture, noCabalFixture :: FilePath
projFixture = "test/fixtures/proj"
noCabalFixture = "test/fixtures/no-cabal"

defOpts :: FilePath -> MetaOptions
defOpts r = MetaOptions { root = r, includeTests = False, hieDirOverride = Nothing }

-- | proj fixture 的期望結果(sfPath 碼位序)。
expectedProjPaths :: [FilePath]
expectedProjPaths =
  [ "app/Main.hs"
  , "bench/Bench.hs"
  , "src/MagicFarmer/Render/Core.hs"
  , "src/lowercase/util.hs"
  , "test/Spec.hs"
  , "tests/OtherSpec.hs"
  ]

excludedProjPaths :: [FilePath]
excludedProjPaths = ["bench/Bench.hs", "test/Spec.hs", "tests/OtherSpec.hs"]

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "F001 scan-baseline"
  [ testSmokeBuild         -- T1
  , testTypesConstruct     -- T2
  , testFindCabalFiles     -- T3
  , testScanTree           -- T4
  , testModuleSuffix       -- T5
  , testExclusionToggle    -- T6
  , testIndexDeterministic -- T7
  , testLoadProjectMeta    -- T8
  , testRenderSummary      -- T9
  ]

-- T1: tasty 能執行即證明三 component 骨架成立
testSmokeBuild :: TestTree
testSmokeBuild = testCase "test_smoke_build" $
  assertBool "tasty runs inside knot-test" True

-- T2: 建構空骨架 ProjectMeta 並驗證各欄位值
testTypesConstruct :: TestTree
testTypesConstruct = testCase "test_types_construct" $ do
  let pm = ProjectMeta
        { pmPackages = []
        , pmSources  = []
        , pmHie      = Nothing
        , pmWarnings = []
        }
  pmPackages pm @?= []
  pmSources pm @?= []
  pmHie pm @?= Nothing
  pmWarnings pm @?= []

-- T3: 有 .cabal → 正斜線相對路徑;無 .cabal → 空清單 + 一則警告
testFindCabalFiles :: TestTree
testFindCabalFiles = testCase "test_find_cabal_files" $ do
  (found, ws) <- findCabalFiles projFixture
  found @?= ["proj.cabal"]
  ws @?= []
  (found2, ws2) <- findCabalFiles noCabalFixture
  found2 @?= []
  length ws2 @?= 1
  map mwPath ws2 @?= [noCabalFixture]

-- T4: 誘餌不出現、路徑皆 repo 相對正斜線、僅 .hs 入列
testScanTree :: TestTree
testScanTree = testCase "test_scan_tree" $ do
  (srcs, ws) <- indexSources (defOpts projFixture) []
  ws @?= []
  let paths = map sfPath srcs
  paths @?= expectedProjPaths
  forM_ paths $ \p -> do
    assertBool ("forward slashes only: " <> p) ((toEnum 92 :: Char) `notElem` p)
    assertBool ("not absolute: " <> p) (not ("/" `isPrefixOf` p))
    assertBool ("no dist-newstyle leak: " <> p) (not ("dist-newstyle" `isInfixOf` p))
    assertBool ("no hidden dir leak: " <> p)
      (not (".hidden" `isInfixOf` p) && not (".stack-work" `isInfixOf` p))

-- T5: 大寫尾綴法例 + property(小寫前綴段不改變推導結果)
testModuleSuffix :: TestTree
testModuleSuffix = testGroup "test_module_suffix"
  [ testCase "examples" $ do
      moduleNameFromPath "src/MagicFarmer/Render/Core.hs"
        @?= Just (ModuleName (T.pack "MagicFarmer.Render.Core"))
      moduleNameFromPath "app/Main.hs" @?= Just (ModuleName (T.pack "Main"))
      moduleNameFromPath "src/lowercase/util.hs" @?= Nothing
  , testProperty "lowercase prefix segments do not change result" $ property $ do
      prefix <- forAll (Gen.list (Range.linear 0 4) (Gen.string (Range.linear 1 8) Gen.lower))
      let path = concatMap (<> "/") prefix <> "MagicFarmer/Render/Core.hs"
      moduleNameFromPath path === Just (ModuleName (T.pack "MagicFarmer.Render.Core"))
  ]

-- T6: includeTests=False/True 各跑一次,排除檔翻轉、其餘恆 True
testExclusionToggle :: TestTree
testExclusionToggle = testCase "test_exclusion_toggle" $ do
  (off, _) <- indexSources (defOpts projFixture) []
  (on, _)  <- indexSources ((defOpts projFixture) { includeTests = True }) []
  forM_ off $ \sf ->
    sfIncluded sf @?= (sfPath sf `notElem` excludedProjPaths)
  forM_ on $ \sf ->
    sfIncluded sf @?= True

-- T7: 連續兩次結果完全相等,且 sfPath 嚴格遞增
testIndexDeterministic :: TestTree
testIndexDeterministic = testCase "test_index_deterministic" $ do
  r1 <- indexSources (defOpts projFixture) []
  r2 <- indexSources (defOpts projFixture) []
  r2 @?= r1
  let paths = map sfPath (fst r1)
  assertBool "sfPath strictly increasing" (and (zipWith (<) paths (drop 1 paths)))

-- T8: loadProjectMeta 管線組裝
testLoadProjectMeta :: TestTree
testLoadProjectMeta = testCase "test_load_project_meta" $ do
  pm <- loadProjectMeta (defOpts projFixture)
  pmPackages pm @?= []
  pmHie pm @?= Nothing
  map sfPath (pmSources pm) @?= expectedProjPaths
  pmWarnings pm @?= []
  pm2 <- loadProjectMeta (defOpts noCabalFixture)
  map sfPath (pmSources pm2) @?= ["src/Foo.hs"]
  map mwPath (pmWarnings pm2) @?= [noCabalFixture]

-- T9: 對已知 ProjectMeta 值驗證摘要文字(檔案數、對映數、排除數、警告數)
testRenderSummary :: TestTree
testRenderSummary = testCase "test_render_summary" $ do
  let pm = ProjectMeta
        { pmPackages = []
        , pmSources =
            [ SourceFile "src/Foo/Bar.hs" (Just (ModuleName (T.pack "Foo.Bar"))) [] True
            , SourceFile "test/Spec.hs" Nothing [] False
            ]
        , pmHie = Nothing
        , pmWarnings = [MetaWarning "." (T.pack "no .cabal file found")]
        }
      out = renderMetaSummary pm
  assertBool "file count"     (T.pack "2 files" `T.isInfixOf` out)
  assertBool "module count"   (T.pack "1 with module" `T.isInfixOf` out)
  assertBool "excluded count" (T.pack "1 excluded" `T.isInfixOf` out)
  assertBool "warning count"  (T.pack "warnings: 1" `T.isInfixOf` out)
  assertBool "source path listed" (T.pack "src/Foo/Bar.hs" `T.isInfixOf` out)
  assertBool "warning message listed" (T.pack "no .cabal file found" `T.isInfixOf` out)
