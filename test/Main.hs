-- | project-meta(F001 scan-baseline、F002 cabal-components、F003 hie-discovery)、
-- extraction(F001 fact-contract、F002 import-scan)、graph-core(F001
-- module-graph)與 export-query(F001 json-export)的 1-to-1 測試。
module Main (main) where

import Control.Exception (throwIO)
import Control.Monad (forM_)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as AKM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isDigit, isSpace)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, isInfixOf, isPrefixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process (readProcessWithExitCode)

import Hedgehog (Gen, evalIO, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Knot.App.Summary (renderFactSummary, renderGraphSummary, renderMetaSummary)
import Knot.Export (writeCodegraph)
import Knot.Export.Commit (detectCommit)
import Knot.Export.Encode (encodeCodegraph, relationText, statsNotes)
import Knot.Export.Types
  ( CommitPolicy (..)
  , ExportOptions (..)
  , ExportReport (..)
  , defaultOutputPath
  )
import Knot.Extract (extract)
import Knot.Extract.Backend
  ( Backend (..)
  , ProbeResult (..)
  , hiedbName
  , importScanName
  , runBackends
  )
import Knot.Extract.ImportScan
  ( headerModuleOf
  , importScanBackend
  , importsOf
  , scanSource
  , stripCommentLines
  )
import Knot.Extract.Types
  ( BackendChoice (..)
  , BackendReport (..)
  , CapabilityLevel (..)
  , DeclKind (..)
  , ExtractOptions (..)
  , ExtractResult (..)
  , ExtractWarning (..)
  , Fact (..)
  , NameSpace (..)
  , QualName (..)
  )
-- 假設 A7:'ExportOptions' 與 'ExtractOptions' 的 @rootDir@ 同名,
-- 記錄建構/更新語法可消歧、裸選擇器不行 → 裸取值走 qualified。
import qualified Knot.Extract.Types as XT
import Knot.Graph (buildGraph)
import Knot.Graph.EdgeDerive (EdgeStats (..), deriveEdges)
import Knot.Graph.FactGate (GatedFacts (..), gateFacts)
import Knot.Graph.NodeMint (mintModuleId, mintNodes, moduleFiles)
import Knot.Graph.Types
  ( BuildOptions (..)
  , CodeGraph (..)
  , GraphEdge (..)
  , GraphNode (..)
  , GraphStats (..)
  , GraphWarning (..)
  , NodeId (..)
  , NodeKind (..)
  , Relation (..)
  )
import Knot.Meta (loadProjectMeta)
import Knot.Meta.CabalModel (resolvePackage)
import Knot.Meta.Discovery (findCabalFiles)
import Knot.Meta.HieLocate (locateHie, moduleNameFromHiePath)
import Knot.Meta.SourceIndex (indexSources, moduleNameFromPath)
import Knot.Meta.Types
  ( ComponentKind (..)
  , ComponentMeta (..)
  , ComponentRef (..)
  , HieDirSource (..)
  , HieInfo (..)
  , MetaOptions (..)
  , MetaWarning (..)
  , ModuleName (..)
  , PackageMeta (..)
  , ProjectMeta (..)
  , SourceFile (..)
  )

projFixture, noCabalFixture, compsFixture, condFixture, multiFixture, brokenFixture :: FilePath
projFixture    = "test/fixtures/proj"
noCabalFixture = "test/fixtures/no-cabal"
compsFixture   = "test/fixtures/comps"
condFixture    = "test/fixtures/cond"
multiFixture   = "test/fixtures/multi"
brokenFixture  = "test/fixtures/broken"

-- | graph-core/F001 端到端用:含真實內部 import、外部 import、重複 import
-- 與自 import 的專案樹。
graphFixture :: FilePath
graphFixture = "test/fixtures/graph"

hieConvFixture, hieDistFixture :: FilePath
hieConvFixture = "test/fixtures/hie-conv"
hieDistFixture = "test/fixtures/hie-dist"

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

-- | comps fixture 的期望 component 名(宣告序、kind 分段固定序)。
compsNames :: [T.Text]
compsNames = map T.pack
  ["lib:comps", "lib:sub", "exe:comps-exe", "flib:comps-ffi", "test:comps-test", "bench:comps-bench"]

ref :: String -> String -> ComponentRef
ref p c = ComponentRef (T.pack p, T.pack c)

findSf :: FilePath -> [SourceFile] -> IO SourceFile
findSf p sfs = case find ((== p) . sfPath) sfs of
  Just sf -> pure sf
  Nothing -> assertFailure ("source file not found: " <> p)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "knot-hs"
  [ f001Tests, f002Tests, f003Tests
  , extractionF001Tests, extractionF002Tests
  , graphCoreF001Tests
  , exportQueryF001Tests
  ]

f001Tests :: TestTree
f001Tests = testGroup "F001 scan-baseline"
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

f002Tests :: TestTree
f002Tests = testGroup "F002 cabal-components"
  [ testResolvePackageSmoke        -- T1
  , testResolveParseError          -- T2
  , testComponentExtraction        -- T3
  , testComponentExcluded          -- T4
  , testFindCabalProject           -- T5
  , testOwnersAndIncluded          -- T6
  , testModuleMapping              -- T7
  , testLoadMetaPackages           -- T8
  , testS2DeterministicRegression  -- T9
  , testRenderSummaryComponents    -- T10
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

-- T8: loadProjectMeta 管線組裝(F002 起 pmPackages 為單一 0-component 套件)
testLoadProjectMeta :: TestTree
testLoadProjectMeta = testCase "test_load_project_meta" $ do
  pm <- loadProjectMeta (defOpts projFixture)
  pmPackages pm @?=
    [ PackageMeta { pkgName = T.pack "proj", pkgCabalFile = "proj.cabal", pkgComponents = [] } ]
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

--------------------------------------------------------------------------------
-- F002 cabal-components
--------------------------------------------------------------------------------

-- F002 T1: 解析進入點接線(Cabal / Cabal-syntax 相依成立)
testResolvePackageSmoke :: TestTree
testResolvePackageSmoke = testCase "test_resolve_package_smoke" $ do
  r <- resolvePackage (compsFixture <> "/comps.cabal")
  case r of
    Left w   -> assertFailure ("expected Right, got: " <> show w)
    Right pm -> do
      pkgName pm @?= T.pack "comps"
      pkgCabalFile pm @?= "comps.cabal"

-- F002 T2: 解析失敗與讀檔失敗皆 Left MetaWarning,不拋例外
testResolveParseError :: TestTree
testResolveParseError = testCase "test_resolve_parse_error" $ do
  r <- resolvePackage (brokenFixture <> "/broken.cabal")
  case r of
    Right pm -> assertFailure ("expected Left, got: " <> show pm)
    Left w   -> do
      mwPath w @?= brokenFixture <> "/broken.cabal"
      assertBool "non-empty message" (not (T.null (mwMessage w)))
  r2 <- resolvePackage (brokenFixture <> "/does-not-exist.cabal")
  case r2 of
    Right pm -> assertFailure ("expected Left for missing file, got: " <> show pm)
    Left w2  -> mwPath w2 @?= brokenFixture <> "/does-not-exist.cabal"

-- F002 T3: 六種 kind、compName 前綴、compSourceDirs 正斜線;cond 預設 flag 攤平
testComponentExtraction :: TestTree
testComponentExtraction = testCase "test_component_extraction" $ do
  r <- resolvePackage (compsFixture <> "/comps.cabal")
  case r of
    Left w   -> assertFailure ("expected Right, got: " <> show w)
    Right pm -> do
      let cs = pkgComponents pm
      map compName cs @?= compsNames
      map compKind cs @?=
        [MainLibrary, NamedLibrary, Executable, ForeignLibrary, TestSuite, Benchmark]
      let dirsOf n = compSourceDirs <$> find ((== T.pack n) . compName) cs
      dirsOf "lib:comps"        @?= Just ["src"]
      dirsOf "lib:sub"          @?= Just ["src/sub"]
      dirsOf "exe:comps-exe"    @?= Just ["app"]
      dirsOf "flib:comps-ffi"   @?= Just ["src/ffi"]
      dirsOf "test:comps-test"  @?= Just ["test", "app"]
      dirsOf "bench:comps-bench" @?= Just ["bench", "app"]
      forM_ cs $ \c -> do
        compExcluded c @?= False
        forM_ (compSourceDirs c) $ \d ->
          assertBool ("forward slashes only: " <> d) ((toEnum 92 :: Char) `notElem` d)
  rc <- resolvePackage (condFixture <> "/cond.cabal")
  case rc of
    Left w   -> assertFailure ("expected Right, got: " <> show w)
    Right pm -> case pkgComponents pm of
      [c] -> do
        let dirs = compSourceDirs c
        assertBool "src present"        ("src" `elem` dirs)
        assertBool "src-extra absent (default flag off)" ("src-extra" `notElem` dirs)
        length (filter (`elem` ["src-win", "src-posix"]) dirs) @?= 1
      cs -> assertFailure ("expected exactly one component, got: " <> show cs)

-- F002 T4: 規則 1——test/bench 依 includeTests 翻轉、其餘恆 False
testComponentExcluded :: TestTree
testComponentExcluded = testCase "test_component_excluded" $ do
  pm <- loadProjectMeta (defOpts compsFixture)
  case pmPackages pm of
    [p] -> forM_ (pkgComponents p) $ \c ->
      compExcluded c @?= (compKind c `elem` [TestSuite, Benchmark])
    ps  -> assertFailure ("expected one package, got: " <> show (length ps))
  pmOn <- loadProjectMeta ((defOpts compsFixture) { includeTests = True })
  case pmPackages pmOn of
    [p] -> forM_ (pkgComponents p) $ \c -> compExcluded c @?= False
    ps  -> assertFailure ("expected one package, got: " <> show (length ps))

-- F002 T5: cabal.project 展開、無 cabal.project 退回 S1、壞 cabal.project 退回 + 警告
testFindCabalProject :: TestTree
testFindCabalProject = testCase "test_find_cabal_project" $ do
  (f1, w1) <- findCabalFiles multiFixture
  f1 @?= ["pkg-a/pkg-a.cabal", "pkg-b/pkg-b.cabal"]
  w1 @?= []
  forM_ f1 $ \p ->
    assertBool ("forward slashes only: " <> p) ((toEnum 92 :: Char) `notElem` p)
  (f2, w2) <- findCabalFiles projFixture
  f2 @?= ["proj.cabal"]
  w2 @?= []
  (f3, w3) <- findCabalFiles noCabalFixture
  f3 @?= []
  length w3 @?= 1
  (f4, w4) <- findCabalFiles brokenFixture
  f4 @?= ["broken.cabal"]   -- 退回根目錄掃描
  case w4 of
    [w] -> assertBool "warning mentions cabal.project"
             (T.pack "cabal.project" `T.isInfixOf` T.pack (mwPath w))
    _   -> assertFailure ("expected exactly one warning, got: " <> show w4)

-- F002 T6: 規則 2——一對多歸類、sfIncluded 判定、includeTests 翻轉、無 owner 退回啟發式
testOwnersAndIncluded :: TestTree
testOwnersAndIncluded = testCase "test_owners_and_included" $ do
  pm <- loadProjectMeta (defOpts compsFixture)
  appMain <- findSf "app/Main.hs" (pmSources pm)
  sfOwners appMain @?=
    [ ref "comps" "exe:comps-exe", ref "comps" "test:comps-test", ref "comps" "bench:comps-bench" ]
  sfIncluded appMain @?= True
  spec <- findSf "test/Spec.hs" (pmSources pm)
  sfOwners spec @?= [ref "comps" "test:comps-test"]
  sfIncluded spec @?= False
  bench <- findSf "bench/Bench.hs" (pmSources pm)
  sfOwners bench @?= [ref "comps" "bench:comps-bench"]
  sfIncluded bench @?= False
  -- includeTests = True:僅屬 test/bench 的檔案翻轉為納入
  pmOn <- loadProjectMeta ((defOpts compsFixture) { includeTests = True })
  specOn <- findSf "test/Spec.hs" (pmSources pmOn)
  sfIncluded specOn @?= True
  benchOn <- findSf "bench/Bench.hs" (pmSources pmOn)
  sfIncluded benchOn @?= True
  -- 無 owner 檔案(不在任何 hs-source-dirs 下)走 S1 啟發式
  demo <- findSf "examples/Demo.hs" (pmSources pm)
  sfOwners demo @?= []
  sfIncluded demo @?= True

-- F002 T7: 規則 3——精確 module 對映(最長命中 dir)、無 owner 退回尾綴法
testModuleMapping :: TestTree
testModuleMapping = testCase "test_module_mapping" $ do
  pm <- loadProjectMeta (defOpts compsFixture)
  let modOf p = do
        sf <- findSf p (pmSources pm)
        pure (sfModule sf)
  core <- modOf "src/Comps/Core.hs"
  core @?= Just (ModuleName (T.pack "Comps.Core"))
  sub <- modOf "src/sub/Comps/Sub.hs"
  sub @?= Just (ModuleName (T.pack "Comps.Sub"))   -- 最長 dir 勝出,不是 sub.Comps.Sub
  lower <- modOf "src/lowercase/util.hs"
  lower @?= Nothing
  appMain <- modOf "app/Main.hs"
  appMain @?= Just (ModuleName (T.pack "Main"))
  -- 無 owner(no-cabal 專案)仍由尾綴法推得
  pm2 <- loadProjectMeta (defOpts noCabalFixture)
  foo <- findSf "src/Foo.hs" (pmSources pm2)
  sfModule foo @?= Just (ModuleName (T.pack "Foo"))

-- F002 T8: 多套件錨定(repo 相對)、跨套件 owners、警告順序
testLoadMetaPackages :: TestTree
testLoadMetaPackages = testCase "test_load_meta_packages" $ do
  pm <- loadProjectMeta (defOpts multiFixture)
  map pkgName (pmPackages pm) @?= [T.pack "pkg-a", T.pack "pkg-b"]
  map pkgCabalFile (pmPackages pm) @?= ["pkg-a/pkg-a.cabal", "pkg-b/pkg-b.cabal"]
  let allComps = concatMap pkgComponents (pmPackages pm)
      dirsOf n = compSourceDirs <$> find ((== T.pack n) . compName) allComps
  dirsOf "lib:pkg-a"      @?= Just ["pkg-a/src"]
  dirsOf "test:pkg-a-test" @?= Just ["pkg-a/test"]
  dirsOf "exe:pkg-b-exe"  @?= Just ["pkg-b/app"]
  aCore <- findSf "pkg-a/src/A/Core.hs" (pmSources pm)
  sfOwners aCore @?= [ref "pkg-a" "lib:pkg-a"]
  sfModule aCore @?= Just (ModuleName (T.pack "A.Core"))
  sfIncluded aCore @?= True
  aSpec <- findSf "pkg-a/test/ASpec.hs" (pmSources pm)
  sfOwners aSpec @?= [ref "pkg-a" "test:pkg-a-test"]
  sfIncluded aSpec @?= False
  bMain <- findSf "pkg-b/app/Main.hs" (pmSources pm)
  sfOwners bMain @?= [ref "pkg-b" "exe:pkg-b-exe"]
  sfIncluded bMain @?= True
  -- 警告順序 discovery → cabal-model → source-index:
  -- broken fixture 同時有壞 cabal.project(discovery)與壞 .cabal(cabal-model)
  pmB <- loadProjectMeta (defOpts brokenFixture)
  case pmWarnings pmB of
    [w1, w2] -> do
      assertBool "1st warning from discovery (cabal.project)"
        (T.pack "cabal.project" `T.isInfixOf` T.pack (mwPath w1))
      assertBool "2nd warning from cabal-model (broken.cabal)"
        (T.pack "broken.cabal" `T.isInfixOf` T.pack (mwPath w2))
    ws -> assertFailure ("expected exactly two warnings, got: " <> show ws)
  pmPackages pmB @?= []   -- 解析失敗的套件被略過,不中斷

-- F002 T9: 決定性 + F001 回歸(proj fixture 期望值不變、pmPackages 填實)
testS2DeterministicRegression :: TestTree
testS2DeterministicRegression = testCase "test_s2_deterministic_and_regression" $ do
  forM_ [compsFixture, multiFixture] $ \fx -> do
    r1 <- loadProjectMeta (defOpts fx)
    r2 <- loadProjectMeta (defOpts fx)
    r2 @?= r1
    let paths = map sfPath (pmSources r1)
    assertBool ("sfPath strictly increasing: " <> fx)
      (and (zipWith (<) paths (drop 1 paths)))
  pm <- loadProjectMeta (defOpts projFixture)
  pmPackages pm @?=
    [ PackageMeta { pkgName = T.pack "proj", pkgCabalFile = "proj.cabal", pkgComponents = [] } ]
  map sfPath (pmSources pm) @?= expectedProjPaths
  forM_ (pmSources pm) $ \sf -> do
    sfOwners sf @?= []   -- 0 component → 全部無 owner,退回 S1 行為
    sfIncluded sf @?= (sfPath sf `notElem` excludedProjPaths)
    sfModule sf @?= moduleNameFromPath (sfPath sf)

-- F002 T10: 摘要含套件名、.cabal 路徑、compName + excluded 標示、檔案行 owners
testRenderSummaryComponents :: TestTree
testRenderSummaryComponents = testCase "test_render_summary_components" $ do
  let comps =
        [ ComponentMeta (T.pack "lib:demo") MainLibrary ["src"] False
        , ComponentMeta (T.pack "test:demo-test") TestSuite ["test"] True
        ]
      pm = ProjectMeta
        { pmPackages = [PackageMeta (T.pack "demo") "demo.cabal" comps]
        , pmSources =
            [ SourceFile "src/Demo.hs" (Just (ModuleName (T.pack "Demo")))
                [ref "demo" "lib:demo"] True
            ]
        , pmHie = Nothing
        , pmWarnings = []
        }
      out = renderMetaSummary pm
  assertBool "package name"       (T.pack "demo" `T.isInfixOf` out)
  assertBool "cabal file path"    (T.pack "demo.cabal" `T.isInfixOf` out)
  assertBool "component lib"      (T.pack "lib:demo" `T.isInfixOf` out)
  assertBool "component test"     (T.pack "test:demo-test" `T.isInfixOf` out)
  assertBool "excluded marker"    (T.pack "excluded" `T.isInfixOf` out)
  assertBool "owners on file line" (T.pack "{demo/lib:demo}" `T.isInfixOf` out)
  assertBool "package count line" (T.pack "packages: 1" `T.isInfixOf` out)

--------------------------------------------------------------------------------
-- F003 hie-discovery
--------------------------------------------------------------------------------

-- | hie-conv fixture 的 [SourceFile](幽靈判定母集來源)。
hieConvSources :: IO [SourceFile]
hieConvSources = fst <$> indexSources (defOpts hieConvFixture) []

-- | hie-conv fixture 的期望 .hie 清單(碼位序)。
allHieConvPaths, validHieConvPaths :: [FilePath]
allHieConvPaths =
  [".hie/Deep/Mod.hie", ".hie/Foo.hie", ".hie/Gone.hie", ".hie/lowercase/util.hie"]
validHieConvPaths =
  [".hie/Deep/Mod.hie", ".hie/Foo.hie", ".hie/lowercase/util.hie"]

hieDistFooHie :: FilePath
hieDistFooHie =
  "dist-newstyle/build/x86_64-windows/ghc-9.14.1/pkg-0.1/build/extra-compilation-artifacts/hie/Foo.hie"

f003Tests :: TestTree
f003Tests = testGroup "F003 hie-discovery"
  [ testLocateNone          -- T1
  , testHieEnumerate        -- T2
  , testThreeTierSource     -- T3
  , testHieModuleMap        -- T4
  , testGhostFilter         -- T5
  , testLocateDeterministic -- T6
  , testLoadMetaHie         -- T7
  ]

-- F003 T1: 三層皆未命中 → (Nothing, []);骨架與未命中路徑成立
testLocateNone :: TestTree
testLocateNone = testCase "test_locate_none" $ do
  (srcs, _) <- indexSources (defOpts noCabalFixture) []
  r <- locateHie (defOpts noCabalFixture) srcs
  r @?= (Nothing, [])

-- F003 T2: .hie/ 下全部 .hie 入列(含巢狀)、repo 相對正斜線、非 .hie 不入列
testHieEnumerate :: TestTree
testHieEnumerate = testCase "test_hie_enumerate" $ do
  srcs <- hieConvSources
  (mh, _) <- locateHie (defOpts hieConvFixture) srcs
  case mh of
    Nothing -> assertFailure "expected Just HieInfo"
    Just h  -> do
      let everything = hieFiles h ++ hieGhosts h
      sort everything @?= allHieConvPaths
      forM_ everything $ \p -> do
        assertBool ("forward slashes only: " <> p) ((toEnum 92 :: Char) `notElem` p)
        assertBool ("repo relative: " <> p) (".hie/" `isPrefixOf` p)
      assertBool "non-.hie decoy not enumerated"
        (".hie/readme.txt" `notElem` everything)

-- F003 T3: 三層發現順序與 hieSource 標記(四例)
testThreeTierSource :: TestTree
testThreeTierSource = testGroup "test_three_tier_source"
  [ testCase "override adopts FromFlag" $ do
      srcs <- hieConvSources
      (mh, ws) <- locateHie ((defOpts hieConvFixture) { hieDirOverride = Just ".hie" }) srcs
      fmap hieSource mh @?= Just FromFlag
      fmap hieDir mh @?= Just ".hie"
      length ws @?= 2   -- 僅幽靈 + 無法對映警告,無層級警告
  , testCase "convention layer" $ do
      srcs <- hieConvSources
      (mh, _) <- locateHie (defOpts hieConvFixture) srcs
      fmap hieSource mh @?= Just FromConvention
      fmap hieDir mh @?= Just ".hie"
  , testCase "dist-newstyle layer with common-ancestor hieDir" $ do
      (srcs, _) <- indexSources (defOpts hieDistFixture) []
      (mh, ws) <- locateHie (defOpts hieDistFixture) srcs
      fmap hieSource mh @?= Just FromDistNewstyle
      fmap hieDir mh @?= Just
        "dist-newstyle/build/x86_64-windows/ghc-9.14.1/pkg-0.1/build/extra-compilation-artifacts/hie"
      fmap hieFiles mh @?= Just [hieDistFooHie]
      fmap hieGhosts mh @?= Just []
      ws @?= []
  , testCase "missing override yields Nothing plus warning, no fallback" $ do
      srcs <- hieConvSources
      (mh, ws) <- locateHie ((defOpts hieConvFixture) { hieDirOverride = Just "no-such-dir" }) srcs
      mh @?= Nothing   -- hie-conv 有 .hie 慣例層,Nothing 證明未 fallback
      case ws of
        [w] -> do
          mwPath w @?= "no-such-dir"
          assertBool "message mentions not found"
            (T.pack "not found" `T.isInfixOf` mwMessage w)
        _ -> assertFailure ("expected exactly one warning, got: " <> show ws)
  ]

-- F003 T4: 去 .hie 副檔名 + 大寫尾綴法例 + property(小寫前綴段不改變推導)
testHieModuleMap :: TestTree
testHieModuleMap = testGroup "test_hie_module_map"
  [ testCase "examples" $ do
      moduleNameFromHiePath "Foo.hie" @?= Just (ModuleName (T.pack "Foo"))
      moduleNameFromHiePath "Deep/Mod.hie" @?= Just (ModuleName (T.pack "Deep.Mod"))
      moduleNameFromHiePath "lowercase/util.hie" @?= Nothing
      moduleNameFromHiePath hieDistFooHie @?= Just (ModuleName (T.pack "Foo"))
  , testProperty "lowercase prefix segments do not change result" $ property $ do
      prefix <- forAll (Gen.list (Range.linear 0 4) (Gen.string (Range.linear 1 8) Gen.lower))
      let path = concatMap (<> "/") prefix <> "Deep/Mod.hie"
      moduleNameFromHiePath path === Just (ModuleName (T.pack "Deep.Mod"))
  ]

-- F003 T5: 幽靈入 hieGhosts + 警告不進 hieFiles;無法對映者留置 + 警告;
-- 有效檔無警告(恰兩則警告即證明)
testGhostFilter :: TestTree
testGhostFilter = testCase "test_ghost_filter" $ do
  srcs <- hieConvSources
  (mh, ws) <- locateHie (defOpts hieConvFixture) srcs
  case mh of
    Nothing -> assertFailure "expected Just HieInfo"
    Just h  -> do
      hieGhosts h @?= [".hie/Gone.hie"]
      hieFiles h @?= validHieConvPaths
      assertBool "ghost not in hieFiles" (".hie/Gone.hie" `notElem` hieFiles h)
      case ws of
        [wGhost, wUnmap] -> do
          mwPath wGhost @?= ".hie/Gone.hie"
          assertBool "ghost message mentions module"
            (T.pack "Gone" `T.isInfixOf` mwMessage wGhost)
          mwPath wUnmap @?= ".hie/lowercase/util.hie"
        _ -> assertFailure ("expected exactly two warnings, got: " <> show ws)

-- F003 T6: 連續兩次結果完全相等;hieFiles 與 hieGhosts 各自嚴格遞增
testLocateDeterministic :: TestTree
testLocateDeterministic = testCase "test_locate_deterministic" $ do
  srcs <- hieConvSources
  r1 <- locateHie (defOpts hieConvFixture) srcs
  r2 <- locateHie (defOpts hieConvFixture) srcs
  r2 @?= r1
  case fst r1 of
    Nothing -> assertFailure "expected Just HieInfo"
    Just h  -> do
      let inc xs = and (zipWith (<) xs (drop 1 xs))
      assertBool "hieFiles strictly increasing" (inc (hieFiles h))
      assertBool "hieGhosts strictly increasing" (inc (hieGhosts h))

-- F003 T7: loadProjectMeta 接線——pmHie 填實、警告殿後;no-cabal 既有行為不變
testLoadMetaHie :: TestTree
testLoadMetaHie = testCase "test_load_meta_hie" $ do
  pm <- loadProjectMeta (defOpts hieConvFixture)
  fmap hieSource (pmHie pm) @?= Just FromConvention
  fmap hieGhosts (pmHie pm) @?= Just [".hie/Gone.hie"]
  fmap hieFiles (pmHie pm) @?= Just validHieConvPaths
  case pmWarnings pm of
    [wCabal, wGhost, wUnmap] -> do
      mwPath wCabal @?= hieConvFixture        -- discovery 警告在前
      mwPath wGhost @?= ".hie/Gone.hie"       -- hie-locate 警告殿後
      mwPath wUnmap @?= ".hie/lowercase/util.hie"
    ws -> assertFailure ("expected exactly three warnings, got: " <> show ws)
  pm2 <- loadProjectMeta (defOpts noCabalFixture)
  pmHie pm2 @?= Nothing
  map mwPath (pmWarnings pm2) @?= [noCabalFixture]

--------------------------------------------------------------------------------
-- extraction/F001 fact-contract
--------------------------------------------------------------------------------

extOpts :: BackendChoice -> ExtractOptions
extOpts c = ExtractOptions
  { rootDir       = projFixture
  , backendChoice = c
  , hiedbExe      = Nothing
  , dbPath        = Nothing
  }

mn :: String -> ModuleName
mn = ModuleName . T.pack

qn :: String -> String -> NameSpace -> QualName
qn m o s = QualName { qnModule = mn m, qnOcc = T.pack o, qnSpace = s }

-- | 假後端:探測通過,回固定事實與警告。
fakeOk :: Text -> CapabilityLevel -> [Fact] -> [ExtractWarning] -> Backend
fakeOk n lvl fs ws = Backend
  { bName  = n
  , bLevel = lvl
  , bProbe = \_ _ -> pure Available
  , bRun   = \_ _ -> pure (fs, ws)
  }

-- | 假後端:探測失敗,原因指定。
fakeUnavailable :: Text -> CapabilityLevel -> Text -> Backend
fakeUnavailable n lvl reason =
  (fakeOk n lvl [] []) { bProbe = \_ _ -> pure (Unavailable reason) }

-- | 假後端:探測通過但 bRun 抛例外。
fakeRunBoom :: Text -> CapabilityLevel -> String -> Backend
fakeRunBoom n lvl msg =
  (fakeOk n lvl [] []) { bRun = \_ _ -> throwIO (userError msg) }

-- | 假後端:記錄自己被呼叫過哪些階段。
tracingBackend :: IORef [Text] -> Text -> CapabilityLevel -> Backend
tracingBackend tref n lvl = Backend
  { bName  = n
  , bLevel = lvl
  , bProbe = \_ _ -> logCall (T.pack "probe") >> pure Available
  , bRun   = \_ _ -> logCall (T.pack "run") >> pure ([], [])
  }
 where
  logCall stage = modifyIORef' tref (++ [n <> T.pack ":" <> stage])

-- | 假後端:捕獲實際收到的 ProjectMeta。
capturingBackend :: IORef (Maybe ProjectMeta) -> Text -> Backend
capturingBackend cref n =
  (fakeOk n ModuleLevel [] []) { bRun = \_ pm -> writeIORef cref (Just pm) >> pure ([], []) }

reportFor :: Text -> ExtractResult -> IO BackendReport
reportFor n r = case find ((== n) . brBackend) (erReports r) of
  Just br -> pure br
  Nothing -> assertFailure ("no BackendReport for backend: " <> T.unpack n)

-- | 刻意亂序的事實樣本(兩組,分屬兩個假後端)。
factsA, factsB :: [Fact]
factsA =
  [ FactImport (mn "Z.Late") (mn "A.Early") "src/Z/Late.hs" 9
  , FactModule "src/A/Early.hs" (mn "A.Early")
  , FactModule "src/Z/Late.hs" (mn "Z.Late")
  ]
factsB =
  [ FactRef (mn "Z.Late") (Just (qn "Z.Late" "go" ValueNs)) (qn "A.Early" "helper" ValueNs)
      "src/Z/Late.hs" 21
  , FactDecl (qn "A.Early" "helper" ValueNs) ValueDecl "src/A/Early.hs" 4
  , FactInstance (qn "A.Early" "Renderable" TypeNs) (T.pack "Renderable Sprite")
      "src/A/Early.hs" 30
  ]

emptyMeta :: ProjectMeta
emptyMeta = ProjectMeta [] [] Nothing []

extractionF001Tests :: TestTree
extractionF001Tests = testGroup "extraction/F001 fact-contract"
  [ testExtractTypesConstruct     -- T1
  , testBackendIfaceConstruct     -- T2
  , testIncludedScope             -- T3
  , testProbeAndSelect            -- T4
  , testBestEffortRun             -- T5
  , testFactSynthesis             -- T6
  , testExtractEntryEmptyRegistry -- T7
  ]

-- extraction T1: 建構每個 DTO(Fact 五個建構子全部)並驗證欄位取值
testExtractTypesConstruct :: TestTree
testExtractTypesConstruct = testCase "test_extract_types_construct" $ do
  let opts = extOpts Auto
  XT.rootDir opts    @?= projFixture
  backendChoice opts @?= Auto
  hiedbExe opts      @?= Nothing
  dbPath opts        @?= Nothing
  ExtractOptions "." HiedbOnly (Just "hiedb.exe") (Just "db") @?=
    ExtractOptions { rootDir = ".", backendChoice = HiedbOnly
                   , hiedbExe = Just "hiedb.exe", dbPath = Just "db" }
  -- QualName.qnModule 確為 Knot.Meta.Types.ModuleName(以該型別的值直接建構即證明共用)
  let modName = ModuleName (T.pack "A.Early") :: ModuleName
      q = QualName { qnModule = modName, qnOcc = T.pack "helper", qnSpace = ValueNs }
  qnModule q @?= modName
  qnOcc q    @?= T.pack "helper"
  qnSpace q  @?= ValueNs
  -- Fact 五個建構子
  case FactModule "src/A/Early.hs" modName of
    f@FactModule{} -> do
      fmFile f   @?= "src/A/Early.hs"
      fmModule f @?= modName
  case FactImport modName (mn "Data.Text") "src/A/Early.hs" 3 of
    f@FactImport{} -> do
      fiFrom f @?= modName
      fiTo f   @?= mn "Data.Text"
      fiFile f @?= "src/A/Early.hs"
      fiLine f @?= 3
  case FactDecl q DataDecl "src/A/Early.hs" 4 of
    f@FactDecl{} -> do
      fdName f @?= q
      fdKind f @?= DataDecl
      fdFile f @?= "src/A/Early.hs"
      fdLine f @?= 4
  case FactRef modName (Just q) (qn "Z.Late" "go" ValueNs) "src/A/Early.hs" 5 of
    f@FactRef{} -> do
      frFromModule f @?= modName
      frFromDecl f   @?= Just q
      frTarget f     @?= qn "Z.Late" "go" ValueNs
      frFile f       @?= "src/A/Early.hs"
      frLine f       @?= 5
  case FactInstance (qn "A.Early" "Renderable" TypeNs) (T.pack "Renderable Sprite")
         "src/A/Early.hs" 6 of
    f@FactInstance{} -> do
      fiClass f    @?= qn "A.Early" "Renderable" TypeNs
      fiInstHead f @?= T.pack "Renderable Sprite"
      fiInstFile f @?= "src/A/Early.hs"
      fiInstLine f @?= 6
  -- DeclKind 七個建構子皆可建構且互異
  length (sort [ValueDecl, DataDecl, ClassDecl, InstanceDecl, TypeSynDecl, PatSynDecl, FamilyDecl])
    @?= 7
  -- 回報 DTO
  let br = BackendReport { brBackend = importScanName, brUsed = True, brDetail = T.empty }
      ew = ExtractWarning { ewSource = hiedbName, ewMessage = T.pack "oops" }
      res = ExtractResult { erFacts = factsA, erLevel = DeclLevel
                          , erReports = [br], erWarnings = [ew] }
  brBackend br   @?= importScanName
  brUsed br      @?= True
  brDetail br    @?= T.empty
  ewSource ew    @?= hiedbName
  ewMessage ew   @?= T.pack "oops"
  erFacts res    @?= factsA
  erLevel res    @?= DeclLevel
  erReports res  @?= [br]
  erWarnings res @?= [ew]
  -- CapabilityLevel 的 Ord:ModuleLevel < DeclLevel
  assertBool "ModuleLevel < DeclLevel" (ModuleLevel < DeclLevel)

-- extraction T2: 假後端值的建構與呼叫;後端名常數等於契約字串
testBackendIfaceConstruct :: TestTree
testBackendIfaceConstruct = testCase "test_backend_iface_construct" $ do
  importScanName @?= T.pack "import-scan"
  hiedbName      @?= T.pack "hiedb"
  let opts = extOpts Auto
      ok   = fakeOk importScanName ModuleLevel factsA [ExtractWarning importScanName (T.pack "w")]
      bad  = fakeUnavailable hiedbName DeclLevel (T.pack "hiedb not on PATH")
  bName ok   @?= importScanName
  bLevel ok  @?= ModuleLevel
  bLevel bad @?= DeclLevel
  pOk <- bProbe ok opts emptyMeta
  pOk @?= Available
  pBad <- bProbe bad opts emptyMeta
  pBad @?= Unavailable (T.pack "hiedb not on PATH")
  (fs, ws) <- bRun ok opts emptyMeta
  fs @?= factsA
  ws @?= [ExtractWarning importScanName (T.pack "w")]
  (fs2, ws2) <- bRun bad opts emptyMeta
  fs2 @?= []
  ws2 @?= []

-- extraction T3: 規則 1——後端只收到 sfIncluded = True 的檔;其餘欄位原樣
testIncludedScope :: TestTree
testIncludedScope = testCase "test_included_scope" $ do
  pm <- loadProjectMeta (defOpts compsFixture)
  assertBool "fixture must contain excluded files"
    (any (not . sfIncluded) (pmSources pm))
  cref <- newIORef Nothing
  _ <- runBackends [capturingBackend cref importScanName] (extOpts Auto) pm
  seen <- readIORef cref
  case seen of
    Nothing   -> assertFailure "backend never received a ProjectMeta"
    Just pmIn -> do
      assertBool "only included sources reach the backend"
        (all sfIncluded (pmSources pmIn))
      map sfPath (pmSources pmIn) @?= map sfPath (filter sfIncluded (pmSources pm))
      pmPackages pmIn @?= pmPackages pm
      pmHie pmIn      @?= pmHie pm
      pmWarnings pmIn @?= pmWarnings pm

-- extraction T4: 選擇與探測(規則 3)
testProbeAndSelect :: TestTree
testProbeAndSelect = testGroup "test_probe_and_select"
  [ testCase "auto: failing probe reported, other backend still runs" $ do
      let reason = T.pack "hiedb not on PATH"
          reg = [ fakeOk importScanName ModuleLevel factsA []
                , fakeUnavailable hiedbName DeclLevel reason ]
      r <- runBackends reg (extOpts Auto) emptyMeta
      brHiedb <- reportFor hiedbName r
      brUsed brHiedb   @?= False
      brDetail brHiedb @?= reason
      brImport <- reportFor importScanName r
      brUsed brImport @?= True
      erFacts r @?= sort factsA
      erLevel r @?= ModuleLevel
  , testCase "auto: probe exception treated as unavailable, no crash" $ do
      let reg = [ fakeOk importScanName ModuleLevel factsA []
                , (fakeOk hiedbName DeclLevel [] [])
                    { bProbe = \_ _ -> throwIO (userError "probe-boom") } ]
      r <- runBackends reg (extOpts Auto) emptyMeta
      brHiedb <- reportFor hiedbName r
      brUsed brHiedb @?= False
      assertBool "detail carries exception text"
        (T.pack "probe-boom" `T.isInfixOf` brDetail brHiedb)
      erLevel r @?= ModuleLevel
      erWarnings r @?= []   -- 探測不可用不產警告
  , testCase "HiedbOnly with unavailable hiedb: empty facts, no crash" $ do
      let reason = T.pack "hiedb executable not found"
          reg = [ fakeOk importScanName ModuleLevel factsA []
                , fakeUnavailable hiedbName DeclLevel reason ]
      r <- runBackends reg (extOpts HiedbOnly) emptyMeta
      erFacts r @?= []
      erLevel r @?= ModuleLevel
      brHiedb <- reportFor hiedbName r
      brUsed brHiedb   @?= False
      brDetail brHiedb @?= reason
      brImport <- reportFor importScanName r
      brUsed brImport @?= False
      assertBool "import-scan reported as not selected"
        (T.pack "not selected" `T.isInfixOf` brDetail brImport)
  , testCase "ImportsOnly: hiedb backend never invoked but still reported" $ do
      traceRef <- newIORef []
      let reg = [ fakeOk importScanName ModuleLevel factsA []
                , tracingBackend traceRef hiedbName DeclLevel ]
      r <- runBackends reg (extOpts ImportsOnly) emptyMeta
      calls <- readIORef traceRef
      calls @?= []
      brHiedb <- reportFor hiedbName r
      brUsed brHiedb @?= False
      assertBool "hiedb reported as not selected"
        (T.pack "not selected" `T.isInfixOf` brDetail brHiedb)
      length (erReports r) @?= 2   -- 每個註冊後端剛好一筆
      erFacts r @?= sort factsA
  ]

-- extraction T5: best-effort 執行(規則 7)
testBestEffortRun :: TestTree
testBestEffortRun = testGroup "test_best_effort_run"
  [ testCase "throwing bRun degrades to report + warning, others survive" $ do
      let selfWarn = ExtractWarning importScanName (T.pack "unreadable file: src/X.hs")
          reg = [ fakeOk importScanName ModuleLevel factsA [selfWarn]
                , fakeRunBoom hiedbName DeclLevel "run-boom" ]
      r <- runBackends reg (extOpts Auto) emptyMeta
      brHiedb <- reportFor hiedbName r
      brUsed brHiedb @?= False
      assertBool "detail carries exception text"
        (T.pack "run-boom" `T.isInfixOf` brDetail brHiedb)
      -- 後端自報的警告原樣出現,加上失敗後端的一則警告
      case erWarnings r of
        [w1, w2] -> do
          w1 @?= selfWarn
          ewSource w2 @?= hiedbName
          assertBool "warning carries exception text"
            (T.pack "run-boom" `T.isInfixOf` ewMessage w2)
        ws -> assertFailure ("expected exactly two warnings, got: " <> show ws)
      erFacts r @?= sort factsA   -- 正常後端的事實完整保留
      erLevel r @?= ModuleLevel   -- 失敗後端不貢獻能力等級
  , testCase "lazy exception inside the fact list is caught too" $ do
      let boomBackend = (fakeOk hiedbName DeclLevel [] [])
            { bRun = \_ _ ->
                pure (FactModule "src/A/Early.hs" (mn "A.Early") : error "lazy-boom", []) }
          reg = [fakeOk importScanName ModuleLevel factsA [], boomBackend]
      r <- runBackends reg (extOpts Auto) emptyMeta
      brHiedb <- reportFor hiedbName r
      brUsed brHiedb @?= False
      assertBool "detail carries lazy exception text"
        (T.pack "lazy-boom" `T.isInfixOf` brDetail brHiedb)
      erFacts r @?= sort factsA   -- 失敗後端的事實全數丟棄
      length (erWarnings r) @?= 1
  ]

-- extraction T6: 合成(規則 8)
testFactSynthesis :: TestTree
testFactSynthesis = testGroup "test_fact_synthesis"
  [ testCase "facts totally ordered, level takes the max of successful backends" $ do
      let reg = [ fakeOk importScanName ModuleLevel factsA []
                , fakeOk hiedbName DeclLevel factsB [] ]
          opts = extOpts Auto
      r1 <- runBackends reg opts emptyMeta
      r2 <- runBackends reg opts emptyMeta
      erFacts r1 @?= sort (factsA ++ factsB)
      r2 @?= r1                    -- 同輸入連續兩次結果完全相同
      erLevel r1 @?= DeclLevel
      let fs = erFacts r1
      assertBool "facts non-decreasing" (and (zipWith (<=) fs (drop 1 fs)))
  , testCase "only the ModuleLevel backend succeeds -> ModuleLevel" $ do
      let reg = [ fakeOk importScanName ModuleLevel factsA []
                , fakeUnavailable hiedbName DeclLevel (T.pack "no hiedb") ]
      r <- runBackends reg (extOpts Auto) emptyMeta
      erLevel r @?= ModuleLevel
  , testProperty "shuffling backend output does not change synthesis" $ property $ do
      fs <- forAll (Gen.list (Range.linear 0 12) genFact)
      shuffled <- forAll (Gen.shuffle fs)
      let run xs = runBackends [fakeOk importScanName ModuleLevel xs []]
                     (extOpts Auto) emptyMeta
      base <- evalIO (run fs)
      alt  <- evalIO (run shuffled)
      erFacts alt === erFacts base
  ]

-- | T6 property 用的事實產生器(涵蓋全部五個建構子)。
genFact :: Gen Fact
genFact = Gen.choice
  [ FactModule <$> genPath <*> genMod
  , FactImport <$> genMod <*> genMod <*> genPath <*> genLine
  , FactDecl <$> genQual <*> Gen.element
      [ValueDecl, DataDecl, ClassDecl, InstanceDecl, TypeSynDecl, PatSynDecl, FamilyDecl]
      <*> genPath <*> genLine
  , FactRef <$> genMod <*> Gen.maybe genQual <*> genQual <*> genPath <*> genLine
  , FactInstance <$> genQual <*> genOcc <*> genPath <*> genLine
  ]
 where
  genMod  = ModuleName <$> genOcc
  genOcc  = T.pack <$> Gen.string (Range.linear 1 4) Gen.alpha
  genPath = Gen.string (Range.linear 1 6) Gen.alpha
  genLine = Gen.int (Range.linear 1 200)
  genQual = QualName <$> genMod <*> genOcc <*> Gen.element [ValueNs, TypeNs]

-- extraction T7: 進入點與註冊表
-- (F002 起註冊表已填入 import-scan;本測試改為驗證 extract 確實委派給
--  registeredBackends——每個註冊後端剛好一筆報告、能力等級由實際跑的後端決定。
--  空註冊表語意本身已隨 F002 消失,見 F002「實作備註」)
testExtractEntryEmptyRegistry :: TestTree
testExtractEntryEmptyRegistry = testCase "test_extract_entry_registry" $ do
  pm <- loadProjectMeta (defOpts projFixture)
  forM_ [Auto, ImportsOnly, HiedbOnly] $ \c -> do
    r <- extract (extOpts c) pm
    map brBackend (erReports r) @?= [importScanName]
    erLevel r @?= ModuleLevel
  rHiedb <- extract (extOpts HiedbOnly) pm
  erFacts rHiedb    @?= []   -- import-scan 未選中 → 無事實
  erWarnings rHiedb @?= []

--------------------------------------------------------------------------------
-- extraction/F002 import-scan
--------------------------------------------------------------------------------

extractionF002Tests :: TestTree
extractionF002Tests = testGroup "extraction/F002 import-scan"
  [ testImportScanBackendValue   -- T1
  , testStripComments            -- T2
  , testModuleHeader             -- T3
  , testImportsSyntax            -- T4
  , testScanSourceFacts          -- T5
  , testRunBestEffort            -- T6
  , testImportScanDeterministic  -- T7
  , testRenderFactSummary        -- T8
  ]

-- extraction/F002 T1: 後端值欄位、探測恆 Available、註冊生效
testImportScanBackendValue :: TestTree
testImportScanBackendValue = testCase "test_import_scan_backend_value" $ do
  bName importScanBackend  @?= importScanName
  bName importScanBackend  @?= T.pack "import-scan"
  bLevel importScanBackend @?= ModuleLevel
  p <- bProbe importScanBackend (extOpts Auto) emptyMeta
  p @?= Available
  -- 註冊生效:Auto 與 ImportsOnly 下 import-scan 被實際執行
  pm <- loadProjectMeta (defOpts projFixture)
  forM_ [Auto, ImportsOnly] $ \c -> do
    r <- extract (extOpts c) pm
    br <- reportFor importScanName r
    brUsed br   @?= True
    brDetail br @?= T.empty
  -- HiedbOnly:註冊在表內但未選中
  rH <- extract (extOpts HiedbOnly) pm
  brH <- reportFor importScanName rH
  brUsed brH @?= False
  assertBool "import-scan reported as not selected"
    (T.pack "not selected" `T.isInfixOf` brDetail brH)

-- | 測試用原始碼字面(以 \n 串接,行號 1 起算)。
srcOf :: [String] -> Text
srcOf = T.pack . unlines

-- | T4/T5 共用的綜合 import 原始碼(行號見右側註解)。
comboSrcLines :: [String]
comboSrcLines =
  [ "{-# LANGUAGE CPP #-}"                    --  1
  , "-- | haddock 標題"                        --  2
  , "module Demo.Main"                        --  3
  , "  ( main"                                --  4
  , "  ) where"                               --  5
  , ""                                        --  6
  , "import A"                                --  7
  , "import qualified B.C as X"               --  8
  , "import D"                                --  9
  , "  ( a"                                   -- 10
  , "  , b ) hiding (c)"                      -- 11
  , "import {-# SOURCE #-} E"                 -- 12
  , "import \"pkg\" F.G"                      -- 13
  , "import"                                  -- 14
  , "  qualified H as H'"                     -- 15
  , "#if MIN_VERSION_base(4,0,0)"             -- 16
  , "import I.Cpp"                            -- 17
  , "#else"                                   -- 18
  , "import J.Cpp"                            -- 19
  , "#endif"                                  -- 20
  , ""                                        -- 21
  , "main :: IO ()"                           -- 22
  , "main = print \"import K.Never\""         -- 23
  , ""                                        -- 24
  , "import L.AfterDecl"                      -- 25
  ]

comboSrc :: Text
comboSrc = srcOf comboSrcLines

-- | comboSrc 的期望 import 抽取結果(行號 × module)。
comboImports :: [(Int, ModuleName)]
comboImports =
  [ (7, mn "A"), (8, mn "B.C"), (9, mn "D"), (12, mn "E"), (13, mn "F.G")
  , (14, mn "H"), (17, mn "I.Cpp"), (19, mn "J.Cpp")
  ]

-- extraction/F002 T2: 去註解掃描器
testStripComments :: TestTree
testStripComments = testCase "test_strip_comments" $ do
  let inputLines =
        [ "{-# LANGUAGE CPP #-}"              -- 1 整段換空白
        , "module Demo where   -- trailing"   -- 2 行尾註解
        , "f x = x --> 3"                     -- 3 --> 是運算子
        , "{- outer {- inner -} still -}"     -- 4 巢狀區塊註解
        , "s = \"a -- b {- c\""               -- 5 字串內不觸發
        , "import {-# SOURCE #-} Foo"         -- 6 不黏連
        , "g = 1 ---- four dashes"            -- 7 四個 dash 仍是註解
        ]
      -- BOM + CRLF 行尾
      input = T.cons '\xFEFF' (T.intercalate (T.pack "\r\n") (map T.pack inputLines))
      out   = stripCommentLines input
  map fst out @?= [1 .. 7]
  length out @?= length inputLines
  let ln n = snd (out !! (n - 1))
      raw n = T.pack (inputLines !! (n - 1))
  assertBool "pragma blanked" (T.all isSpace (ln 1))
  T.length (ln 1) @?= T.length (raw 1)
  ln 2 @?= T.pack "module Demo where   "
  ln 3 @?= raw 3
  assertBool "nested block comment blanked" (T.all isSpace (ln 4))
  T.length (ln 4) @?= T.length (raw 4)
  ln 5 @?= raw 5
  T.words (ln 6) @?= map T.pack ["import", "Foo"]
  ln 7 @?= T.pack "g = 1 "

-- extraction/F002 T3: module 標頭
testModuleHeader :: TestTree
testModuleHeader = testCase "test_module_header" $ do
  let hdr = headerModuleOf . stripCommentLines . srcOf
  hdr ["module A.B.C where"] @?= (Just (mn "A.B.C"), False)
  hdr [ "module"
      , "  App.Effects"
      , "  ( -- * 標題"
      , "    x ) where"
      ] @?= (Just (mn "App.Effects"), False)
  hdr [ "{-# LANGUAGE CPP #-}"
      , "-- | haddock 前言"
      , "{- 區塊 -}"
      , "module Deep.Mod (main) where"
      ] @?= (Just (mn "Deep.Mod"), False)
  -- 無 module 標頭:pragma-only 檔 → Nothing 且失敗旗標為 False
  hdr ["{-# OPTIONS_GHC -F -pgmF hspec-discover #-}"] @?= (Nothing, False)
  hdr ["main :: IO ()", "main = pure ()"] @?= (Nothing, False)
  -- 有 module 關鍵字但解析不出名字 → 失敗旗標 True
  hdr ["module 123 where"] @?= (Nothing, True)
  -- 綜合原始碼
  headerModuleOf (stripCommentLines comboSrc) @?= (Just (mn "Demo.Main"), False)

-- extraction/F002 T4: import 語法涵蓋
testImportsSyntax :: TestTree
testImportsSyntax = testCase "test_imports_syntax" $ do
  let got = importsOf (stripCommentLines comboSrc)
  got @?= map (fmap Just) comboImports
  -- 宣告區之後的 import 字樣不被抽出
  assertBool "no import after declarations"
    (all ((`notElem` [23, 25]) . fst) got)
  -- 無 import 的檔案
  importsOf (stripCommentLines (srcOf ["module Empty where", "x = 1"])) @?= []
  -- 壞 import 行 → Nothing
  importsOf (stripCommentLines (srcOf ["import A", "import (oops)", "import B"]))
    @?= [(1, Just (mn "A")), (2, Nothing), (3, Just (mn "B"))]

-- extraction/F002 T5: 事實組裝
testScanSourceFacts :: TestTree
testScanSourceFacts = testCase "test_scan_source_facts" $ do
  let path = "src/Demo/Main.hs"
      (facts, warns) = scanSource path comboSrc
  warns @?= []
  case facts of
    (f : imps) -> do
      f @?= FactModule path (mn "Demo.Main")
      map (\i -> (fiLine i, fiTo i)) imps @?= comboImports
      forM_ imps $ \i -> do
        fiFrom i @?= mn "Demo.Main"
        fiFile i @?= path
      let ls = map fiLine imps
      assertBool "import lines strictly increasing" (and (zipWith (<) ls (drop 1 ls)))
    [] -> assertFailure "expected at least one fact"
  -- 無 module 標頭 → Main(D3)
  let (facts2, warns2) = scanSource "app/Main.hs" (srcOf ["import Data.Text", "main = pure ()"])
  warns2 @?= []
  facts2 @?=
    [ FactModule "app/Main.hs" (mn "Main")
    , FactImport (mn "Main") (mn "Data.Text") "app/Main.hs" 1
    ]
  -- 同一 module import 兩次 → 兩筆事實(不去重)
  let (facts3, _) = scanSource "src/Dup.hs"
        (srcOf ["module Dup where", "import Data.Text", "import Data.Text"])
  facts3 @?=
    [ FactModule "src/Dup.hs" (mn "Dup")
    , FactImport (mn "Dup") (mn "Data.Text") "src/Dup.hs" 2
    , FactImport (mn "Dup") (mn "Data.Text") "src/Dup.hs" 3
    ]
  -- 壞 import 行 → 一則 unparsable 警告,其餘事實不受影響
  let (facts4, warns4) = scanSource "src/Bad.hs"
        (srcOf ["module Bad where", "import (oops)", "import Data.Text"])
  facts4 @?=
    [ FactModule "src/Bad.hs" (mn "Bad")
    , FactImport (mn "Bad") (mn "Data.Text") "src/Bad.hs" 3
    ]
  case warns4 of
    [w] -> do
      ewSource w @?= T.pack "src/Bad.hs"
      assertBool "message is unparsable import at line 2"
        (T.pack "unparsable import at line 2" `T.isInfixOf` ewMessage w)
    ws -> assertFailure ("expected exactly one warning, got: " <> show ws)

-- | 事實的來源檔(僅 import-scan 產出的兩個建構子)。
factFile :: Fact -> FilePath
factFile f@FactModule{} = fmFile f
factFile f@FactImport{} = fiFile f
factFile f              = error ("unexpected fact from import-scan: " <> show f)

-- | 在暫存目錄建起 T6/T7 用的專案樹,跑完刪除。
withScratchTree :: (FilePath -> IO a) -> IO a
withScratchTree act = do
  tmp <- getTemporaryDirectory
  let root = tmp </> "knot-hs-f002-scratch"
  removePathForcibly root
  createDirectoryIfMissing True (root </> "src")
  BS.writeFile (root </> "src" </> "Good.hs") $ TE.encodeUtf8 $ srcOf
    [ "module Scratch.Good where"
    , "import Data.Text"
    , "import qualified Data.Map as M"
    ]
  -- 非法 UTF-8 位元組序列(0xFF / 0xFE 在 UTF-8 中永不合法)
  BS.writeFile (root </> "src" </> "Bad.hs") $
    BS.pack [0x69, 0x6d, 0x70, 0x6f, 0x72, 0x74, 0x20, 0xff, 0xfe, 0x0a]
  r <- act root
  removePathForcibly root
  pure r

-- | T6/T7 的暫存專案 ProjectMeta(含一個 pmSources 列出但不存在的檔)。
scratchMeta :: ProjectMeta
scratchMeta = ProjectMeta
  { pmPackages = []
  , pmSources  =
      [ SourceFile "src/Good.hs" Nothing [] True
      , SourceFile "src/Bad.hs" Nothing [] True
      , SourceFile "src/Missing.hs" Nothing [] True
      ]
  , pmHie      = Nothing
  , pmWarnings = []
  }

-- extraction/F002 T6: bRun 逐檔 IO 的 best-effort 行為
testRunBestEffort :: TestTree
testRunBestEffort = testCase "test_run_best_effort" $ do
  (facts, ws) <- withScratchTree $ \root ->
    bRun importScanBackend ((extOpts Auto) { XT.rootDir = root }) scratchMeta
  -- 正常檔的事實完整
  facts @?=
    [ FactModule "src/Good.hs" (mn "Scratch.Good")
    , FactImport (mn "Scratch.Good") (mn "Data.Text") "src/Good.hs" 2
    , FactImport (mn "Scratch.Good") (mn "Data.Map") "src/Good.hs" 3
    ]
  -- 壞檔各一則警告,依 pmSources 序
  case ws of
    [wBad, wMissing] -> do
      ewSource wBad @?= T.pack "src/Bad.hs"
      assertBool "decode failure recognisable"
        (T.pack "decode" `T.isInfixOf` ewMessage wBad)
      ewSource wMissing @?= T.pack "src/Missing.hs"
      assertBool "read failure recognisable"
        (T.pack "cannot read file" `T.isInfixOf` ewMessage wMissing)
    _ -> assertFailure ("expected exactly two warnings, got: " <> show ws)
  -- 經 extract 的真實 fixture:被排除檔不產生任何事實
  pm <- loadProjectMeta (defOpts compsFixture)
  r <- extract ((extOpts Auto) { XT.rootDir = compsFixture }) pm
  erWarnings r @?= []
  let excluded = map sfPath (filter (not . sfIncluded) (pmSources pm))
  assertBool "fixture must contain excluded files" (not (null excluded))
  forM_ (erFacts r) $ \f ->
    assertBool ("excluded file leaked into facts: " <> factFile f)
      (factFile f `notElem` excluded)
  sort (map factFile (erFacts r))
    @?= sort (map sfPath (filter sfIncluded (pmSources pm)))

-- extraction/F002 T7: 決定性(規則 8)
testImportScanDeterministic :: TestTree
testImportScanDeterministic = testGroup "test_import_scan_deterministic"
  [ testCase "two consecutive bRun on the same ProjectMeta are identical" $ do
      (r1, r2) <- withScratchTree $ \root -> do
        let opts = (extOpts Auto) { XT.rootDir = root }
        a <- bRun importScanBackend opts scratchMeta
        b <- bRun importScanBackend opts scratchMeta
        pure (a, b)
      r2 @?= r1
      pm <- loadProjectMeta (defOpts compsFixture)
      let opts = (extOpts Auto) { XT.rootDir = compsFixture }
      c1 <- bRun importScanBackend opts pm
      c2 <- bRun importScanBackend opts pm
      c2 @?= c1
  , testProperty "rendered imports round-trip through scanSource" $ property $ do
      mods  <- forAll (Gen.list (Range.linear 0 8) genModName)
      lns   <- forAll (mapM genImportLine mods)
      let src = srcOf ("module Gen.Root where" : lns)
          (facts, warns) = scanSource "src/Gen/Root.hs" src
          got = [(fiLine f, fiTo f) | f@FactImport{} <- facts]
      warns === []
      [fmModule f | f@FactModule{} <- facts] === [mn "Gen.Root"]
      got === zip [2 ..] (map ModuleName mods)
  ]

-- | 隨機 module 名:1–3 段,每段大寫開頭 + 英數尾。
genModName :: Gen Text
genModName = T.intercalate (T.pack ".") <$> Gen.list (Range.linear 1 3) genSeg
 where
  genSeg = do
    c <- Gen.upper
    r <- Gen.string (Range.linear 0 5) Gen.alphaNum
    pure (T.pack (c : r))

-- | 隨機渲染一條 import 行(qualified / as / (…) / hiding (…) 組合)。
genImportLine :: Text -> Gen String
genImportLine m = do
  qual   <- Gen.bool
  asName <- Gen.maybe (Gen.element ["X", "M", "Q'"])
  spec   <- Gen.element ["", " (a, b)", " hiding (c)", " (a) hiding (b)"]
  pure $ concat
    [ "import "
    , if qual then "qualified " else ""
    , T.unpack m
    , maybe "" (" as " <>) asName
    , spec
    ]

-- extraction/F002 T8: 事實摘要輸出(驗收 harness 的比對面)
testRenderFactSummary :: TestTree
testRenderFactSummary = testCase "test_render_fact_summary" $ do
  let res = ExtractResult
        { erFacts =
            [ FactModule "src/A.hs" (mn "A")
            , FactImport (mn "A") (mn "Data.Text") "src/A.hs" 3
            , FactModule "app/Main.hs" (mn "Main")
            ]
        , erLevel = ModuleLevel
        , erReports = [BackendReport importScanName True T.empty]
        , erWarnings = [ExtractWarning (T.pack "src/Bad.hs") (T.pack "cannot read file: nope")]
        }
      out = renderFactSummary res
  assertBool "level line"    (T.pack "level: ModuleLevel" `T.isInfixOf` out)
  assertBool "backend count" (T.pack "backends: 1" `T.isInfixOf` out)
  assertBool "backend line"  (T.pack "import-scan used=True" `T.isInfixOf` out)
  assertBool "fact total"    (T.pack "facts: 3 total" `T.isInfixOf` out)
  assertBool "module count"  (T.pack "2 modules" `T.isInfixOf` out)
  assertBool "import count"  (T.pack "1 imports" `T.isInfixOf` out)
  assertBool "warning count" (T.pack "warnings: 1" `T.isInfixOf` out)
  assertBool "module line"   (T.pack "  M src/A.hs  [A]" `T.isInfixOf` out)
  assertBool "import line"   (T.pack "  I src/A.hs:3  A -> Data.Text" `T.isInfixOf` out)
  assertBool "warning line"
    (T.pack "  ! src/Bad.hs: cannot read file: nope" `T.isInfixOf` out)
  -- 輸出順序固定(決定性)
  renderFactSummary res @?= out

--------------------------------------------------------------------------------
-- graph-core/F001 module-graph
--------------------------------------------------------------------------------

graphCoreF001Tests :: TestTree
graphCoreF001Tests = testGroup "graph-core/F001 module-graph"
  [ testGraphTypesConstruct     -- T1
  , testGateFacts               -- T2
  , testMintModuleNodes         -- T3
  , testImportsEdgesExternal    -- T4
  , testSelfLoopAndDedupe       -- T5
  , testBuildGraphAssemble      -- T6
  , testBuildGraphDeterministic -- T7
  , testRenderGraphSummary      -- T8
  ]

nid :: String -> NodeId
nid = NodeId . T.pack

defBuildOpts :: BuildOptions
defBuildOpts = BuildOptions { moduleOnly = False }

-- | 事實流 → CodeGraph 的測試捷徑(ProjectMeta 在階段一不被 fact-gate 讀取)。
graphOf :: BuildOptions -> [Fact] -> CodeGraph
graphOf opts facts = buildGraph opts emptyMeta
  ExtractResult { erFacts = facts, erLevel = ModuleLevel, erReports = [], erWarnings = [] }

-- | 事實流 → (邊, 統計, 警告) 的測試捷徑。
edgesOf :: [Fact] -> ([GraphEdge], EdgeStats, [GraphWarning])
edgesOf facts = deriveEdges gated (mintNodes gated)
 where gated = gateFacts emptyMeta facts

-- | 邊的可比對三元組(不含證據行)。
edgeTriple :: GraphEdge -> (NodeId, Relation, NodeId)
edgeTriple e = (geSource e, geRelation e, geTarget e)

-- graph-core T1: 逐一建構 DTO、驗證欄位讀取與 Ord 序
testGraphTypesConstruct :: TestTree
testGraphTypesConstruct = testCase "test_graph_types_construct" $ do
  let bo = BuildOptions { moduleOnly = True }
  moduleOnly bo @?= True
  moduleOnly defBuildOpts @?= False
  let node = GraphNode
        { gnId = nid "Demo.Core", gnKind = ModuleNode
        , gnLabel = T.pack "Demo.Core", gnFile = "src/Demo/Core.hs", gnLine = Nothing }
  gnId node    @?= nid "Demo.Core"
  gnKind node  @?= ModuleNode
  gnLabel node @?= T.pack "Demo.Core"
  gnFile node  @?= "src/Demo/Core.hs"
  gnLine node  @?= Nothing
  -- NodeKind 三個建構子(DeclNode 依 DeclKind 區辨)
  length (nubOrd [ModuleNode, DeclNode ValueDecl, InstanceNode]) @?= 3
  assertBool "DeclNode distinguishes DeclKind" (DeclNode ValueDecl /= DeclNode DataDecl)
  let edge = GraphEdge
        { geSource = nid "Main", geTarget = nid "Demo.Core"
        , geRelation = RImports, geLine = Just 7 }
  geSource edge   @?= nid "Main"
  geTarget edge   @?= nid "Demo.Core"
  geRelation edge @?= RImports
  geLine edge     @?= Just 7
  -- Relation 五個建構子與 Ord 序(D5 的 relation 鍵序)
  sort [RContains, RImplements, RUses, RCalls, RImports]
    @?= [RImports, RCalls, RUses, RImplements, RContains]
  -- NodeId 依內含 Text 字典序
  assertBool "NodeId lexicographic" (nid "Demo.Core" < nid "Main")
  sort [nid "Main", nid "Demo.Core", nid "Main@app/Main.hs"]
    @?= [nid "Demo.Core", nid "Main", nid "Main@app/Main.hs"]
  let st = GraphStats
        { gsDroppedExternal = 3, gsTopExternalTargets = [(mn "Data.Text", 2)]
        , gsFilteredGenerated = 0, gsDedupedEdges = 1 }
  gsDroppedExternal st    @?= 3
  gsTopExternalTargets st @?= [(mn "Data.Text", 2)]
  gsFilteredGenerated st  @?= 0
  gsDedupedEdges st       @?= 1
  let w = GraphWarning { gwSource = T.pack "Main", gwMessage = T.pack "collision" }
  gwSource w  @?= T.pack "Main"
  gwMessage w @?= T.pack "collision"
  -- GraphWarning 的 Ord = (gwSource, gwMessage) 字典序(假設 A7 的排序鍵)
  assertBool "GraphWarning Ord on (source, message)"
    (w < GraphWarning (T.pack "Main") (T.pack "zzz")
      && w < GraphWarning (T.pack "Zed") (T.pack "aaa"))
  -- CodeGraph 的 Eq(T7 依賴它)
  let cg = CodeGraph { cgNodes = [node], cgEdges = [edge], cgStats = st, cgWarnings = [w] }
  cgNodes cg    @?= [node]
  cgEdges cg    @?= [edge]
  cgStats cg    @?= st
  cgWarnings cg @?= [w]
  cg @?= CodeGraph { cgNodes = [node], cgEdges = [edge], cgStats = st, cgWarnings = [w] }
  assertBool "CodeGraph Eq discriminates" (cg /= cg { cgEdges = [] })

-- | T2/T3 共用:三個 FactModule(其中兩筆同名不同檔)+ FactImport + FactDecl。
gateFixtureFacts :: [Fact]
gateFixtureFacts =
  [ FactModule "app/Main.hs" (mn "Main")
  , FactModule "test/Main.hs" (mn "Main")
  , FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactImport (mn "Demo.Core") (mn "Data.Text") "src/Demo/Core.hs" 3
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl "src/Demo/Core.hs" 20
  ]

-- | 只在 pmSources 出現、不在事實流的 module(釘住 D2)。
ghostMeta :: ProjectMeta
ghostMeta = ProjectMeta
  { pmPackages = []
  , pmSources  = [SourceFile "src/Ghost.hs" (Just (mn "Ghost")) [] True]
  , pmHie      = Nothing
  , pmWarnings = []
  }

-- graph-core T2: fact-gate 的內部集合(D2)、原樣通過、gfFiltered 恆 0
testGateFacts :: TestTree
testGateFacts = testCase "test_gate_facts" $ do
  let g = gateFacts ghostMeta gateFixtureFacts
  -- 內部集合恰為事實流的 fmModule(Main 兩筆同名 → 集合兩個元素)
  Set.toList (gfInternal g) @?= sort [mn "Demo.Core", mn "Main"]
  assertBool "Main is internal"      (mn "Main" `Set.member` gfInternal g)
  assertBool "Demo.Core is internal" (mn "Demo.Core" `Set.member` gfInternal g)
  -- D2:pmSources.sfModule 的 Ghost 不得進內部集合
  assertBool "pmSources-only module stays out (D2)"
    (mn "Ghost" `Set.notMember` gfInternal g)
  -- 事實原樣通過(含 FactDecl,不 crash)
  gfFacts g @?= gateFixtureFacts
  assertBool "FactDecl passes through"
    (any (\f -> case f of FactDecl{} -> True; _ -> False) (gfFacts g))
  gfFiltered g @?= 0

-- graph-core T3: id 鑄造(D1)與 module 節點
testMintModuleNodes :: TestTree
testMintModuleNodes = testCase "test_mint_module_nodes" $ do
  -- 契約簽名兩個分支(A2 裁決)
  mintModuleId (mn "Demo.Core") Nothing @?= nid "Demo.Core"
  mintModuleId (mn "Main") (Just "app/Main.hs") @?= nid "Main@app/Main.hs"
  let g = gateFacts emptyMeta gateFixtureFacts
      nodes = mintNodes g
  -- 單一來源檔 → 裸名;同名兩檔 → 整組消歧
  map gnId nodes @?=
    [nid "Main@app/Main.hs", nid "Main@test/Main.hs", nid "Demo.Core"]
  forM_ nodes $ \n -> do
    gnKind n @?= ModuleNode
    gnLine n @?= Nothing   -- FactModule 無行號欄位
  -- 消歧只反映在 id 與 gnFile;gnLabel 維持裸名(假設 A5)
  map gnLabel nodes @?= map T.pack ["Main", "Main", "Demo.Core"]
  map gnFile nodes @?= ["app/Main.hs", "test/Main.hs", "src/Demo/Core.hs"]
  -- 重複 FactModule 只產一個節點;FactDecl 不產節點
  let dup = gateFacts emptyMeta
        [ FactModule "src/A.hs" (mn "A")
        , FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "x" ValueNs) ValueDecl "src/A.hs" 4
        ]
  map gnId (mintNodes dup) @?= [nid "A"]
  -- moduleFiles:同名組有兩個相異檔
  let files = moduleFiles gateFixtureFacts
  fmap Set.toList (Map.lookup (mn "Main") files) @?= Just ["app/Main.hs", "test/Main.hs"]
  fmap Set.size (Map.lookup (mn "Demo.Core") files) @?= Just 1

-- | T4 的 D4 樣本:12 個相異外部目標,次數 3/2/1 各四個(輸入序刻意反排)。
extPlan :: [(String, Int)]
extPlan =
  [ ("E01", 3), ("E02", 3), ("E03", 3), ("E04", 3)
  , ("E05", 2), ("E06", 2), ("E07", 2), ("E08", 2)
  , ("E09", 1), ("E10", 1), ("E11", 1), ("E12", 1)
  ]

topExternalFacts :: [Fact]
topExternalFacts = FactModule "src/A.hs" (mn "A")
  : zipWith (\ln nm -> FactImport (mn "A") (mn nm) "src/A.hs" ln) [1 ..]
      (reverse (concat [replicate c nm | (nm, c) <- extPlan]))

-- graph-core T4: imports 邊主線、外部丟棄與 D4、解析失敗轉警告
testImportsEdgesExternal :: TestTree
testImportsEdgesExternal = testCase "test_imports_edges_external" $ do
  -- 內部 A -> B 產一條 RImports;三筆外部全數丟棄
  let (edges, st, ws) = edgesOf
        [ FactModule "src/A.hs" (mn "A")
        , FactModule "src/B.hs" (mn "B")
        , FactImport (mn "A") (mn "B") "src/A.hs" 5
        , FactImport (mn "A") (mn "Data.Text") "src/A.hs" 6
        , FactImport (mn "A") (mn "Data.Map") "src/A.hs" 7
        , FactImport (mn "B") (mn "Data.Text") "src/B.hs" 3
        ]
  edges @?= [GraphEdge (nid "A") (nid "B") RImports (Just 5)]
  esDroppedExternal st @?= 3
  esTopExternal st @?= [(mn "Data.Text", 2), (mn "Data.Map", 1)]
  esDeduped st @?= 0
  ws @?= []
  -- D4:前 10、次數降序、同次數依 module 名字典序
  let (_, stTop, wsTop) = edgesOf topExternalFacts
  esDroppedExternal stTop @?= sum (map snd extPlan)
  esTopExternal stTop @?= [(mn nm, c) | (nm, c) <- take 10 extPlan]
  length (esTopExternal stTop) @?= 10
  wsTop @?= []
  -- 來源檔沒有對應 FactModule 的 import → 0 條邊 + 1 則警告
  let (e2, st2, ws2) = edgesOf
        [ FactModule "src/B.hs" (mn "B")
        , FactImport (mn "Zed") (mn "B") "src/Z.hs" 4
        ]
  e2 @?= []
  esDroppedExternal st2 @?= 0   -- 不是外部目標,不計入統計
  case ws2 of
    [w] -> do
      gwSource w @?= T.pack "src/Z.hs"
      assertBool "message names the unresolved source"
        (T.pack "Zed" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws2)
  -- 目標落在同名消歧組 → 0 條邊 + 1 則警告(假設 A4)
  let (e3, st3, ws3) = edgesOf
        [ FactModule "app/Main.hs" (mn "Main")
        , FactModule "test/Main.hs" (mn "Main")
        , FactModule "src/A.hs" (mn "A")
        , FactImport (mn "A") (mn "Main") "src/A.hs" 3
        ]
  e3 @?= []
  esDroppedExternal st3 @?= 0
  case ws3 of
    [w] -> do
      gwSource w @?= T.pack "src/A.hs"
      assertBool "message flags ambiguity"
        (T.pack "ambiguous" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws3)

-- graph-core T5: 規則 4(自環)與規則 5(去重、證據行)
testSelfLoopAndDedupe :: TestTree
testSelfLoopAndDedupe = testCase "test_selfloop_and_dedupe" $ do
  -- 自 import:不產邊、不計統計、不發警告
  let (e1, st1, ws1) = edgesOf
        [ FactModule "src/A.hs" (mn "A")
        , FactImport (mn "A") (mn "A") "src/A.hs" 2
        ]
  e1 @?= []
  esDroppedExternal st1 @?= 0
  esDeduped st1 @?= 0
  ws1 @?= []
  -- 去重:亂序三條合併為一,geLine 取最小
  let (e2, st2, ws2) = edgesOf
        [ FactModule "src/A.hs" (mn "A")
        , FactModule "src/B.hs" (mn "B")
        , FactModule "src/C.hs" (mn "C")
        , FactImport (mn "A") (mn "B") "src/A.hs" 40
        , FactImport (mn "A") (mn "B") "src/A.hs" 12
        , FactImport (mn "A") (mn "B") "src/A.hs" 25
        , FactImport (mn "A") (mn "C") "src/A.hs" 30
        ]
  ws2 @?= []
  esDeduped st2 @?= 2
  map edgeTriple e2 @?=
    [(nid "A", RImports, nid "B"), (nid "A", RImports, nid "C")]
  map geLine e2 @?= [Just 12, Just 30]   -- 不同端點不被誤併
  -- 不同來源端不被誤併
  let (e3, st3, _) = edgesOf
        [ FactModule "src/A.hs" (mn "A")
        , FactModule "src/B.hs" (mn "B")
        , FactModule "src/C.hs" (mn "C")
        , FactImport (mn "A") (mn "C") "src/A.hs" 3
        , FactImport (mn "B") (mn "C") "src/B.hs" 3
        ]
  length e3 @?= 2
  esDeduped st3 @?= 0

-- | T6 的綜合事實流(碰撞組 + 內部邊 + 重複 import + 外部 + 消歧目標 + decl)。
assembleFacts :: [Fact]
assembleFacts =
  [ FactModule "app/Main.hs" (mn "Main")
  , FactModule "test/Main.hs" (mn "Main")
  , FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactModule "src/Demo/Render.hs" (mn "Demo.Render")
  , FactImport (mn "Demo.Render") (mn "Demo.Core") "src/Demo/Render.hs" 9
  , FactImport (mn "Demo.Render") (mn "Demo.Core") "src/Demo/Render.hs" 4
  , FactImport (mn "Demo.Render") (mn "Data.Text") "src/Demo/Render.hs" 5
  , FactImport (mn "Demo.Core") (mn "Data.Text") "src/Demo/Core.hs" 3
  , FactImport (mn "Main") (mn "Demo.Core") "app/Main.hs" 6
  , FactImport (mn "Main") (mn "Main") "app/Main.hs" 7
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl "src/Demo/Core.hs" 20
  ]

-- graph-core T6: graph-assemble 的統計、警告彙整與 D5 穩定排序
testBuildGraphAssemble :: TestTree
testBuildGraphAssemble = testCase "test_build_graph_assemble" $ do
  let g = graphOf defBuildOpts assembleFacts
  -- 節點依 NodeId 遞增
  map gnId (cgNodes g) @?=
    [ nid "Demo.Core", nid "Demo.Render"
    , nid "Main@app/Main.hs", nid "Main@test/Main.hs" ]
  assertBool "cgNodes sorted by NodeId"
    (let ids = map gnId (cgNodes g) in and (zipWith (<) ids (drop 1 ids)))
  -- 邊依 (source, relation, target) 遞增;重複 import 合併且取最早行
  map edgeTriple (cgEdges g) @?=
    [ (nid "Demo.Render", RImports, nid "Demo.Core")
    , (nid "Main@app/Main.hs", RImports, nid "Demo.Core")
    ]
  map geLine (cgEdges g) @?= [Just 4, Just 6]
  assertBool "cgEdges sorted by (source, relation, target)"
    (let ks = map edgeTriple (cgEdges g) in and (zipWith (<) ks (drop 1 ks)))
  -- GraphStats 四欄
  cgStats g @?= GraphStats
    { gsDroppedExternal    = 2
    , gsTopExternalTargets = [(mn "Data.Text", 2)]
    , gsFilteredGenerated  = 0
    , gsDedupedEdges       = 1
    }
  -- 警告:碰撞警告(含兩個排序後檔案路徑)+ 邊解析警告,去重且排序
  cgWarnings g @?= nubOrd (sort (cgWarnings g))
  case find ((== T.pack "Main") . gwSource) (cgWarnings g) of
    Nothing -> assertFailure ("no collision warning: " <> show (cgWarnings g))
    Just w  -> do
      assertBool "collision message names both files in sorted order"
        (T.pack "app/Main.hs, test/Main.hs" `T.isInfixOf` gwMessage w)
      assertBool "collision message carries the distinct file count"
        (T.pack "2 source files" `T.isInfixOf` gwMessage w)
  assertBool "ambiguous import target warned"
    (any ((T.pack "ambiguous" `T.isInfixOf`) . gwMessage) (cgWarnings g))
  length (cgWarnings g) @?= 2
  -- 反轉輸入事實序 → 結果完全相同(釘住排序而非輸入序)
  graphOf defBuildOpts (reverse assembleFacts) @?= g
  -- moduleOnly True/False 輸出相同(本階段尚無 decl 事實邏輯)
  graphOf (BuildOptions { moduleOnly = True }) assembleFacts @?= g

-- | graph fixture 的期望節點 id(依 NodeId 遞增)。
graphFixtureNodeIds :: [NodeId]
graphFixtureNodeIds = [nid "Demo.Core", nid "Demo.Render", nid "Main"]

-- graph-core T7: 決定性與端到端
testBuildGraphDeterministic :: TestTree
testBuildGraphDeterministic = testGroup "test_build_graph_deterministic"
  [ testCase "proj fixture: one module node per included file, pure" $ do
      pm <- loadProjectMeta (defOpts projFixture)
      r <- extract ((extOpts Auto) { XT.rootDir = projFixture }) pm
      let included = filter sfIncluded (pmSources pm)
          g = buildGraph defBuildOpts pm r
      assertBool "fixture yields a non-empty fact stream" (not (null (erFacts r)))
      length (cgNodes g) @?= length included
      assertBool "cgNodes sorted by NodeId"
        (let ids = map gnId (cgNodes g) in and (zipWith (<) ids (drop 1 ids)))
      forM_ (cgNodes g) $ \n -> gnKind n @?= ModuleNode
      -- 驗收標準 4:同輸入兩次呼叫結果完全相等
      buildGraph defBuildOpts pm r @?= g
      -- 驗收標準 5:moduleOnly 兩取值輸出相同
      buildGraph (BuildOptions { moduleOnly = True }) pm r @?= g
  , testCase "graph fixture: internal edges, external drops, dedupe, self-loop" $ do
      pm <- loadProjectMeta (defOpts graphFixture)
      r <- extract ((extOpts Auto) { XT.rootDir = graphFixture }) pm
      let g = buildGraph defBuildOpts pm r
      erWarnings r @?= []
      map gnId (cgNodes g) @?= graphFixtureNodeIds
      -- 邊全為 RImports 且兩端皆為內部節點
      forM_ (cgEdges g) $ \e -> do
        geRelation e @?= RImports
        assertBool "source is an existing node" (geSource e `elem` map gnId (cgNodes g))
        assertBool "target is an existing node" (geTarget e `elem` map gnId (cgNodes g))
      map edgeTriple (cgEdges g) @?=
        [ (nid "Demo.Render", RImports, nid "Demo.Core")
        , (nid "Main", RImports, nid "Demo.Core")
        , (nid "Main", RImports, nid "Demo.Render")
        ]
      map geLine (cgEdges g) @?= [Just 3, Just 4, Just 3]
      -- 外部 import 全數落進 gsDroppedExternal;自 import 不產邊也不計統計
      cgStats g @?= GraphStats
        { gsDroppedExternal    = 3
        , gsTopExternalTargets = [(mn "Data.Text", 2), (mn "Data.Map", 1)]
        , gsFilteredGenerated  = 0
        , gsDedupedEdges       = 1
        }
      cgWarnings g @?= []
      buildGraph defBuildOpts pm r @?= g
      buildGraph (BuildOptions { moduleOnly = True }) pm r @?= g
  , testProperty "random fact streams stay sorted and order-insensitive" $ property $ do
      rawNames <- forAll (Gen.list (Range.linear 1 5) genModName)
      rawExts  <- forAll (Gen.list (Range.linear 0 4) genModName)
      let names    = nubOrd rawNames
          -- 小寫前綴保證外部名絕不與內部名相等(genModName 恆大寫開頭)
          extNames = nubOrd (map (T.pack "z" <>) rawExts)
          intMods  = map ModuleName names
          extMods  = map ModuleName extNames
          fileOf (ModuleName t) = "src/" <> T.unpack t <> ".hs"
          modFacts = [FactModule (fileOf m) m | m <- intMods]
      pairs <- forAll (Gen.list (Range.linear 0 12) (genImportPair intMods extMods))
      let impFacts = [FactImport from to (fileOf from) ln | (from, to, ln) <- pairs]
          facts    = modFacts <> impFacts
          internal = Set.fromList intMods
          expectedEdges = Set.fromList
            [(from, to) | (from, to, _) <- pairs, to `Set.member` internal, from /= to]
          expectedExternal = length [() | (_, to, _) <- pairs, to `Set.notMember` internal]
          g = graphOf defBuildOpts facts
      -- 節點:每個內部 module 一個(名字互異 → 全部裸名)
      map gnId (cgNodes g) === sort (map (\m -> mintModuleId m Nothing) intMods)
      -- 邊數 == 相異非自環內部對數;外部 import 全數計入
      length (cgEdges g) === Set.size expectedEdges
      gsDroppedExternal (cgStats g) === expectedExternal
      -- D5:輸出已排序
      cgNodes g === sortOn gnId (cgNodes g)
      cgEdges g === sortOn edgeTriple (cgEdges g)
      -- 純函數 + 對事實序不敏感
      shuffled <- forAll (Gen.shuffle facts)
      graphOf defBuildOpts shuffled === g
      graphOf (BuildOptions { moduleOnly = True }) facts === g
  ]

-- | 隨機 import:來源必為內部 module,目標為內部或外部。
genImportPair :: [ModuleName] -> [ModuleName] -> Gen (ModuleName, ModuleName, Int)
genImportPair intMods extMods = do
  from <- Gen.element intMods
  to   <- Gen.element (intMods <> extMods)
  ln   <- Gen.int (Range.linear 1 50)
  pure (from, to, ln)

-- graph-core T8: 圖摘要輸出(驗收 harness 的比對面)
testRenderGraphSummary :: TestTree
testRenderGraphSummary = testCase "test_render_graph_summary" $ do
  let g = CodeGraph
        { cgNodes =
            [ GraphNode (nid "Demo.Core") ModuleNode (T.pack "Demo.Core")
                "src/Demo/Core.hs" Nothing
            , GraphNode (nid "Main@app/Main.hs") ModuleNode (T.pack "Main")
                "app/Main.hs" (Just 1)
            ]
        , cgEdges =
            [GraphEdge (nid "Main@app/Main.hs") (nid "Demo.Core") RImports (Just 6)]
        , cgStats = GraphStats
            { gsDroppedExternal    = 4
            , gsTopExternalTargets = [(mn "Data.Text", 3), (mn "Data.Map", 1)]
            , gsFilteredGenerated  = 0
            , gsDedupedEdges       = 2
            }
        , cgWarnings = [GraphWarning (T.pack "Main") (T.pack "declared in 2 source files")]
        }
      out = renderGraphSummary g
  assertBool "count line"   (T.pack "graph: 2 nodes, 1 edges, 1 warnings" `T.isInfixOf` out)
  assertBool "stats line"
    (T.pack "stats: dropped-external=4, filtered-generated=0, deduped-edges=2, top-external=2"
       `T.isInfixOf` out)
  assertBool "external top line" (T.pack "  X Data.Text 3" `T.isInfixOf` out)
  assertBool "external tail line" (T.pack "  X Data.Map 1" `T.isInfixOf` out)
  assertBool "node line without line number"
    (T.pack "  N Demo.Core [module] src/Demo/Core.hs" `T.isInfixOf` out)
  assertBool "node line with line number"
    (T.pack "  N Main@app/Main.hs [module] app/Main.hs:1" `T.isInfixOf` out)
  assertBool "edge line"
    (T.pack "  E Main@app/Main.hs -imports-> Demo.Core  L6" `T.isInfixOf` out)
  assertBool "warning line"
    (T.pack "  ! Main: declared in 2 source files" `T.isInfixOf` out)
  -- 輸出順序固定(決定性)
  renderGraphSummary g @?= out

--------------------------------------------------------------------------------
-- export-query/F001 json-export
--------------------------------------------------------------------------------

exportQueryF001Tests :: TestTree
exportQueryF001Tests = testGroup "export-query/F001 json-export"
  [ testExportTypesConstruct          -- T1
  , testEncodeNodeEdge                -- T2
  , testEncodeDocumentLayout          -- T3
  , testDetectCommit                  -- T4
  , testWriteCodegraphEntry           -- T5
  , testExportEndToEndDeterministic   -- T6
  ]

-- | 手寫節點 / 邊 / 圖的測試捷徑。
xNode :: String -> String -> FilePath -> Maybe Int -> GraphNode
xNode i lbl f ln = GraphNode (nid i) ModuleNode (T.pack lbl) f ln

xEdge :: String -> String -> Relation -> Maybe Int -> GraphEdge
xEdge s t r ln = GraphEdge (nid s) (nid t) r ln

zeroStats :: GraphStats
zeroStats = GraphStats
  { gsDroppedExternal    = 0
  , gsTopExternalTargets = []
  , gsFilteredGenerated  = 0
  , gsDedupedEdges       = 0
  }

graphWith :: [GraphNode] -> [GraphEdge] -> CodeGraph
graphWith ns es = CodeGraph
  { cgNodes = ns, cgEdges = es, cgStats = zeroStats, cgWarnings = [] }

-- | 'encodeCodegraph' 的輸出解成 Text(檔案內容是 UTF-8,無 BOM)。
encodeText :: Maybe Text -> CodeGraph -> Text
encodeText mc g =
  TE.decodeUtf8 (BSL.toStrict (BB.toLazyByteString (encodeCodegraph mc g)))

-- | 文件中的陣列元素行(縮排恰 4 空格),去掉縮排與元素分隔逗號後回傳
-- (逗號與縮排本身由 T3 的整份 byte 級斷言負責)。
elemLines :: Text -> [Text]
elemLines =
  map (dropComma . T.drop 4) . filter (T.pack "    " `T.isPrefixOf`) . T.lines
 where
  dropComma t
    | T.pack "," `T.isSuffixOf` t = T.dropEnd 1 t
    | otherwise                   = t

-- | 在暫存目錄下建一個乾淨的工作目錄,跑完刪除。
withExportDir :: String -> (FilePath -> IO a) -> IO a
withExportDir name act = do
  tmp <- getTemporaryDirectory
  let root = tmp </> ("knot-hs-export-" <> name)
  removePathForcibly root
  createDirectoryIfMissing True root
  r <- act root
  removePathForcibly root
  pure r

-- | 測試自行呼叫一次 @git rev-parse HEAD@,避免把 sha 硬寫進測試。
gitHeadOf :: FilePath -> IO (Maybe Text)
gitHeadOf root = do
  (code, out, _) <- readProcessWithExitCode "git" ["-C", root, "rev-parse", "HEAD"] ""
  pure $ case code of
    ExitSuccess   -> Just (T.strip (T.pack out))
    ExitFailure _ -> Nothing

-- export-query T1: 三個契約 DTO 的建構與欄位讀取、defaultOutputPath,
-- 以及 ExportOptions.rootDir 與 ExtractOptions.rootDir 同名的可編譯性(假設 A7)
testExportTypesConstruct :: TestTree
testExportTypesConstruct = testCase "test_export_types_construct" $ do
  let xo = ExportOptions
        { rootDir      = "C:/proj"
        , outputPath   = "C:/proj/codegraph.json"
        , commitPolicy = AutoDetect
        }
  outputPath xo   @?= "C:/proj/codegraph.json"
  commitPolicy xo @?= AutoDetect
  -- 兩建構子互異且 Eq 可用
  assertBool "AutoDetect /= NoCommit" (AutoDetect /= NoCommit)
  (xo { commitPolicy = NoCommit } == xo) @?= False
  (xo == xo) @?= True
  let rep = ExportReport
        { xrPath      = "out/codegraph.json"
        , xrNodeCount = 3
        , xrEdgeCount = 2
        , xrNotes     = [T.pack "deduped edges: 0"]
        }
  xrPath rep      @?= "out/codegraph.json"
  xrNodeCount rep @?= 3
  xrEdgeCount rep @?= 2
  xrNotes rep     @?= [T.pack "deduped edges: 0"]
  (rep == rep)    @?= True
  -- 非契約面 defaultOutputPath(不把平台分隔符寫死)
  takeFileName  (defaultOutputPath "C:/proj") @?= "codegraph.json"
  takeDirectory (defaultOutputPath "C:/proj") @?= "C:/proj"
  -- 假設 A7:同時 import 兩個 Types 模組,記錄建構語法可消歧 rootDir
  let eo = ExtractOptions
        { rootDir       = "C:/proj"
        , backendChoice = Auto
        , hiedbExe      = Nothing
        , dbPath        = Nothing
        }
  backendChoice eo @?= Auto

-- export-query T2: 物件層——relation 對映、節點/邊欄位與順序、
-- source_location 的兩分支(節點與邊皆有)、字串 escaping
testEncodeNodeEdge :: TestTree
testEncodeNodeEdge = testCase "test_encode_node_edge" $ do
  -- 投影規則 1:五個建構子全部對映
  map relationText [RImports, RCalls, RUses, RImplements, RContains]
    @?= map T.pack ["imports", "calls", "uses", "implements", "contains"]
  -- 規則 2 / 3 的欄位與順序(byte 級字串相等,順序才釘得住)
  let g = graphWith
        [ xNode "A" "A" "src/A.hs" Nothing
        , xNode "B" "B" "src/B.hs" (Just 42)
        ]
        [ xEdge "A" "B" RImports Nothing
        , xEdge "B" "A" RCalls (Just 7)
        ]
  elemLines (encodeText Nothing g) @?= map T.pack
    [ "{\"id\":\"A\",\"label\":\"A\",\"source_file\":\"src/A.hs\"}"
    , "{\"id\":\"B\",\"label\":\"B\",\"source_file\":\"src/B.hs\",\"source_location\":\"L42\"}"
    , "{\"source\":\"A\",\"target\":\"B\",\"relation\":\"imports\",\"confidence\":\"EXTRACTED\"}"
    , "{\"source\":\"B\",\"target\":\"A\",\"relation\":\"calls\",\"confidence\":\"EXTRACTED\",\"source_location\":\"L7\"}"
    ]
  -- 節點的 Nothing 分支確實不含該鍵;邊的 Nothing 分支同理(階段一閘門 A5 裁決)
  case elemLines (encodeText Nothing g) of
    [nA, nB, eAB, eBA] -> do
      assertBool "node without gnLine has no source_location key"
        (not (T.pack "source_location" `T.isInfixOf` nA))
      assertBool "node with gnLine ends with source_location"
        (T.pack ",\"source_location\":\"L42\"}" `T.isSuffixOf` nB)
      assertBool "edge without geLine has no source_location key"
        (not (T.pack "source_location" `T.isInfixOf` eAB))
      assertBool "edge with geLine ends with source_location"
        (T.pack ",\"source_location\":\"L7\"}" `T.isSuffixOf` eBA)
    ls -> assertFailure ("expected 4 element lines, got: " <> show ls)
  -- escaping:雙引號、反斜線、控制字元、非 ASCII 原樣 UTF-8
  let ge = graphWith
        [ GraphNode (NodeId (T.pack "q\"id")) ModuleNode
            (T.pack "say \"hi\"\\p\n\1055\28450") "src/\28450.hs" Nothing
        ] []
  elemLines (encodeText Nothing ge) @?= [T.pack
    ("{\"id\":\"q\\\"id\",\"label\":\"say \\\"hi\\\"\\\\p\\n\1055\28450\""
      <> ",\"source_file\":\"src/\28450.hs\"}")]

-- export-query T3: 文件層——半 pretty 版面、頂層欄位順序、
-- built_at_commit 兩分支、空陣列壓行、檔尾換行;以及 statsNotes 的五種行
testEncodeDocumentLayout :: TestTree
testEncodeDocumentLayout = testCase "test_encode_document_layout" $ do
  let g = graphWith
        [ xNode "Demo.Core" "Demo.Core" "src/Demo/Core.hs" Nothing
        , xNode "Main" "Main" "app/Main.hs" (Just 1)
        ]
        [ xEdge "Main" "Demo.Core" RImports (Just 6) ]
      body =
        [ "  \"nodes\": ["
        , "    {\"id\":\"Demo.Core\",\"label\":\"Demo.Core\",\"source_file\":\"src/Demo/Core.hs\"},"
        , "    {\"id\":\"Main\",\"label\":\"Main\",\"source_file\":\"app/Main.hs\",\"source_location\":\"L1\"}"
        , "  ],"
        , "  \"links\": ["
        , "    {\"source\":\"Main\",\"target\":\"Demo.Core\",\"relation\":\"imports\",\"confidence\":\"EXTRACTED\",\"source_location\":\"L6\"}"
        , "  ]"
        , "}"
        ]
  -- Nothing:built_at_commit 整行不存在
  encodeText Nothing g
    @?= T.unlines (map T.pack (["{", "  \"directed\": true,"] <> body))
  -- Just sha:第二行是 built_at_commit,連同其逗號
  encodeText (Just (T.pack "deadbeef")) g @?= T.unlines (map T.pack
    (["{", "  \"directed\": true,", "  \"built_at_commit\": \"deadbeef\","] <> body))
  -- 空圖:兩個陣列壓成同一行
  encodeText Nothing (graphWith [] []) @?= T.unlines (map T.pack
    ["{", "  \"directed\": true,", "  \"nodes\": [],", "  \"links\": []", "}"])
  -- 決定性的必要條件:輸出中沒有 CR(binary builder,不經平台換行轉換)
  assertBool "no CR in output"
    (not (T.pack "\r" `T.isInfixOf` encodeText Nothing g))
  -- 驗收標準 5:statsNotes 的行序固定
  statsNotes (GraphStats 12 [(mn "Data.Text", 7), (mn "Data.Map", 4)] 0 3)
    @?= map T.pack
      [ "dropped external edges: 12"
      , "filtered generated facts: 0"
      , "deduped edges: 3"
      , "top external target: Data.Text (7)"
      , "top external target: Data.Map (4)"
      ]
  statsNotes zeroStats @?= map T.pack
    [ "dropped external edges: 0"
    , "filtered generated facts: 0"
    , "deduped edges: 0"
    ]

-- export-query T4: commit 偵測的四種情形;全程不印、不拋
testDetectCommit :: TestTree
testDetectCommit = testCase "test_detect_commit" $ do
  -- NoCommit:對任何路徑都回 Nothing(連 git 都不跑)
  detectCommit NoCommit "." >>= (@?= Nothing)
  detectCommit NoCommit "no/such/path" >>= (@?= Nothing)
  -- AutoDetect 對專案自身:值等於同一時刻 git rev-parse HEAD
  expected <- gitHeadOf "."
  actual   <- detectCommit AutoDetect "."
  actual @?= expected
  case actual of
    Nothing  -> assertFailure "expected a commit sha inside knot-hs's own repo"
    Just sha -> do
      assertBool ("sha is lowercase hex: " <> show sha)
        (T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) sha)
      assertBool ("sha length in {40,64}: " <> show (T.length sha))
        (T.length sha `elem` [40, 64])
  -- AutoDetect 對「暫存目錄下的非 repo 目錄」:Nothing,且不外流 git 訊息
  nonRepo <- withExportDir "nonrepo" (detectCommit AutoDetect)
  nonRepo @?= Nothing
  -- AutoDetect 對不存在的路徑:Nothing 而非拋例外
  tmp <- getTemporaryDirectory
  missing <- detectCommit AutoDetect (tmp </> "knot-hs-export-does-not-exist")
  missing @?= Nothing

-- export-query T5: 進入點——建父目錄、binary 寫檔、ExportReport 五項組裝
testWriteCodegraphEntry :: TestTree
testWriteCodegraphEntry = testCase "test_write_codegraph_entry" $ do
  let g = (graphWith
        [ xNode "Demo.Core" "Demo.Core" "src/Demo/Core.hs" Nothing
        , xNode "Main" "Main" "app/Main.hs" (Just 1)
        ]
        [ xEdge "Main" "Demo.Core" RImports (Just 6) ])
        { cgStats = GraphStats 4 [(mn "Data.Text", 3)] 0 2 }
  withExportDir "entry" $ \dir -> do
    -- 多層尚未建立的子路徑
    let out = dir </> "a" </> "b" </> "codegraph.json"
    rep <- writeCodegraph ExportOptions
      { rootDir = dir, outputPath = out, commitPolicy = NoCommit } g
    doesFileExist out >>= assertBool ("file written: " <> out)
    -- 進入點沒有偷改內容或換行:與純函數輸出 byte 級相同
    written <- BS.readFile out
    written @?= BSL.toStrict (BB.toLazyByteString (encodeCodegraph Nothing g))
    xrPath rep      @?= out
    xrNodeCount rep @?= 2
    xrEdgeCount rep @?= 1
    xrNotes rep     @?= statsNotes (cgStats g)
  -- AutoDetect 且 rootDir 指向專案自身:檔案含 built_at_commit 且等於 git HEAD
  expected <- gitHeadOf "."
  withExportDir "entry-commit" $ \dir -> do
    let out = dir </> "codegraph.json"
    _ <- writeCodegraph ExportOptions
      { rootDir = ".", outputPath = out, commitPolicy = AutoDetect } g
    txt <- TE.decodeUtf8 <$> BS.readFile out
    case expected of
      Nothing  -> assertFailure "expected a commit sha inside knot-hs's own repo"
      Just sha -> assertBool ("built_at_commit line for " <> show sha)
        (T.pack ("  \"built_at_commit\": \"" <> T.unpack sha <> "\",")
           `T.isInfixOf` txt)

-- export-query T6: 端到端真實檔案 + 決定性(驗收標準 1–4)
testExportEndToEndDeterministic :: TestTree
testExportEndToEndDeterministic =
  testCase "test_export_end_to_end_deterministic" $ do
    pm <- loadProjectMeta (defOpts graphFixture)
    r  <- extract ((extOpts Auto) { XT.rootDir = graphFixture }) pm
    let g = buildGraph defBuildOpts pm r
    withExportDir "e2e" $ \dir -> do
      let out  = dir </> "codegraph.json"
          opts = ExportOptions
            { rootDir = graphFixture, outputPath = out, commitPolicy = NoCommit }
      _ <- writeCodegraph opts g
      bytes1 <- BS.readFile out
      -- 結構斷言(F002 graph-load 的 schema 前提)
      top <- case A.decodeStrict bytes1 of
        Just (A.Object o) -> pure o
        other -> assertFailure ("top level is not a JSON object: " <> show other)
      AKM.lookup (AK.fromString "directed") top @?= Just (A.Bool True)
      AKM.lookup (AK.fromString "built_at_commit") top @?= Nothing
      nodes <- objArray "nodes" top
      links <- objArray "links" top
      assertBool "nodes is non-empty" (not (null nodes))
      assertBool "links is non-empty" (not (null links))
      ids <- fmap Set.fromList $ mapM (nodeIdOf) nodes
      forM_ links $ \e -> do
        forM_ ["source", "target", "relation", "confidence"] $ \k ->
          assertBool ("link has " <> k <> ": " <> show e)
            (AKM.member (AK.fromString k) e)
        AKM.lookup (AK.fromString "confidence") e
          @?= Just (A.String (T.pack "EXTRACTED"))
        -- 階段一閘門 A5 裁決:graph fixture 的邊都有 geLine → 都有 source_location
        assertBool ("link has source_location: " <> show e)
          (AKM.member (AK.fromString "source_location") e)
        s <- strField "source" e
        t <- strField "target" e
        assertBool ("link source is a known node id: " <> show s) (s `Set.member` ids)
        assertBool ("link target is a known node id: " <> show t) (t `Set.member` ids)
      -- 驗收標準 4:同一 CodeGraph 兩次序列化 byte 級相同
      _ <- writeCodegraph opts g
      bytes2 <- BS.readFile out
      bytes2 @?= bytes1
      -- 反證:投影沿用輸入序而非自行排序
      _ <- writeCodegraph opts
        g { cgNodes = reverse (cgNodes g), cgEdges = reverse (cgEdges g) }
      bytes3 <- BS.readFile out
      assertBool "reversed input yields different bytes" (bytes3 /= bytes1)
 where
  objArray k o = case AKM.lookup (AK.fromString k) o of
    Just (A.Array v) -> pure [m | A.Object m <- toList v]
    other -> assertFailure (k <> " is not an array of objects: " <> show other)
  nodeIdOf n = do
    forM_ ["id", "label", "source_file"] $ \k ->
      assertBool ("node has " <> k <> ": " <> show n)
        (AKM.member (AK.fromString k) n)
    strField "id" n
  strField k o = case AKM.lookup (AK.fromString k) o of
    Just (A.String t) -> pure t
    other -> assertFailure (k <> " is not a string: " <> show other)
