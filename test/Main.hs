-- | project-meta(F001 scan-baseline、F002 cabal-components、F003 hie-discovery)、
-- extraction(F001 fact-contract、F002 import-scan)、graph-core(F001
-- module-graph)與 export-query(F001 json-export、F002 graph-load、
-- F003 query-commands、F004 cli-wiring)的 1-to-1 測試。
module Main (main) where

import Control.Exception (evaluate, throwIO)
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
import Data.List (find, intercalate, isInfixOf, isPrefixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Version (showVersion)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , getTemporaryDirectory
  , listDirectory
  , makeAbsolute
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, takeFileName, (</>))
import System.Info (fullCompilerVersion)
import System.IO
  ( Handle
  , IOMode (WriteMode)
  , hSetEncoding
  , hSetNewlineMode
  , noNewlineTranslation
  , utf8
  , withFile
  )
import System.Process (readProcessWithExitCode)

import Options.Applicative
  ( ParserResult (..)
  , defaultPrefs
  , execParserPure
  , renderFailure
  )

import Hedgehog (Gen, annotate, assert, evalIO, failure, forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Knot.App.Cli
  ( Command (..)
  , ExtractCmd (..)
  , QueryCmd (..)
  , SummaryMode (..)
  , cliParserInfo
  , toBuildOptions
  , toExportOptions
  , toExtractOptions
  , toMetaOptions
  )
import Knot.App.Report
  ( emitNotes
  , exportNoteLines
  , extractNoteLines
  , graphNoteLines
  , metaNoteLines
  , queryNoteLines
  )
import Knot.App.Run (runCommand, runExtractCmd, runQueryCmd)
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
-- F004:'ExportOptions' 與 'ExtractOptions' 的 @rootDir@ 同名,裸選擇器不可用
-- → 匯出面的裸取值走 qualified(沿用 F001 假設 A7 留下的 'XT' 慣例)。
import qualified Knot.Export.Types as ET
import Knot.Extract (extract)
import Knot.Extract.Backend
  ( Backend (..)
  , ProbeResult (..)
  , hiedbName
  , importScanName
  , runBackends
  )
import Knot.Extract.HiedbDriver
  ( IndexStats (..)
  , chunkFileArgs
  , defaultDbPath
  , ensureIndex
  , ihDbPath
  , ihExe
  , ihNotes
  , ihRootDir
  , ihStats
  , parseIndexStats
  , probeHiedb
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
import Knot.Query (loadQueryGraph)
-- F003:同時對 'Knot.Query' 的匯出面與兩個內部模組下斷言,故進入點走 qualified。
import qualified Knot.Query as KQ
import Knot.Query.Engine (runQuery)
import Knot.Query.Render (renderResult)
import Knot.Query.Load
  ( RelationClass (..)
  , classifyRelation
  , dependencyRelations
  , parseQueryGraph
  , queryGraphHasNode
  , queryGraphNotes
  , structuralRelations
  )
-- F002 假設 A1:'Knot.Query.Types.NodeId' 與 'Knot.Graph.Types.NodeId' 同名,
-- 而 DisambiguateRecordFields 不涵蓋裸選擇器 → 查詢面一律走 qualified
-- (沿用 F001 假設 A7 留下的 'XT' 慣例)。
import qualified Knot.Query.Types as QT

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

-- | extraction\/F003 用:2 module 小專案 + GHC 9.14.1 產出的__真實__ @.hie@
-- (入版控,委派決策 D6)。
--
-- @.hie@ 的產生方式(__不入測試流程__,GHC 升版時在 @test\/fixtures\/hiedb\/@
-- 下重跑一次即可;不需 cabal、不留 @dist-newstyle@ \/ @.hi@ \/ @.o@):
--
-- > ghc -fno-code -fwrite-ide-info -hiedir .hie -isrc src/Demo/App.hs src/Demo/Core.hs
--
-- 產生後 @test_hiedb_fixture@ 會比對檔頭第二行與本 GHC 版本,升版忘了重跑
-- 會先在那裡紅掉(而不是讓 hiedb 神秘失敗)。
hiedbFixture :: FilePath
hiedbFixture = "test/fixtures/hiedb"

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

-- | 委派決策 D7:hiedb 是__選用__外部依賴(ADR-002 的降級原則),沒裝時
-- 相依測試自動跳過,但必須__印明原因與跳過數__,不讓專案看起來是壞的。
main :: IO ()
main = do
  mExe <- findExecutable "hiedb"
  putStrLn (hiedbNotice mExe hiedbGatedCount)
  defaultMain (tests mExe)

tests :: Maybe FilePath -> TestTree
tests mHiedb = testGroup "knot-hs"
  [ f001Tests, f002Tests, f003Tests
  , extractionF001Tests, extractionF002Tests
  , extractionF003Tests mHiedb
  , graphCoreF001Tests
  , exportQueryF001Tests
  , exportQueryF002Tests
  , exportQueryF003Tests
  , exportQueryF004Tests
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
-- extraction/F003 hiedb-driver
--------------------------------------------------------------------------------

-- | hiedb 不可用時仍會執行的測試 + 依 hiedb 是否存在而掛載的閘門節點(D7)。
extractionF003Tests :: Maybe FilePath -> TestTree
extractionF003Tests mHiedb = testGroup "extraction/F003 hiedb-driver" $
  [ testDefaultDbPath        -- T1
  , testChunkFileArgs        -- T2
  , testParseIndexStats      -- T3
  , testHiedbFixture         -- T4
  , testHiedbSkipNotice      -- T5
  , testProbeHiedbNoExe      -- T6(不需 hiedb 的部分)
  , testHiedbDegrade         -- T10
  ]
  ++ case mHiedb of
       Just _  -> hiedbGatedTests
       Nothing -> [testCase (hiedbSkipLabel hiedbGatedCount) (pure ())]

-- | 需要 hiedb 執行檔才跑得動的測試節點(D7 的管轄範圍)。
hiedbGatedTests :: [TestTree]
hiedbGatedTests =
  [ testProbeHiedbAvailable  -- T6(需 hiedb 的部分)
  , testEnsureIndex          -- T7
  , testKnotDirPolicy        -- T8
  , testIndexReuse           -- T9
  , testHiedbSelfcheck       -- T11
  ]

-- | 跳過數常數;由 @test_hiedb_skip_notice@ 與實際掛載的節點數對帳
-- (假設 A7:不引入 @tasty-expected-failure@,跳過數改由訊息與節點名承載)。
hiedbGatedCount :: Int
hiedbGatedCount = 5

-- | 測試啟動時印的一行:有 hiedb 就說用哪支,沒有就說明原因與跳過數。
hiedbNotice :: Maybe FilePath -> Int -> String
hiedbNotice (Just p) _ = "[hiedb] using " <> p
hiedbNotice Nothing n =
  "[skip] extraction/F003 hiedb-driver: hiedb executable not found on PATH; "
    <> show n <> " tests skipped"

-- | 佔位節點的名稱本身帶跳過數,使其也出現在 tasty 的逐項輸出。
hiedbSkipLabel :: Int -> String
hiedbSkipLabel n = "skipped (hiedb not on PATH): " <> show n <> " tests"

-- | 以 PATH 上的 hiedb + 指定 root 組出 'ExtractOptions'。
hiedbOpts :: FilePath -> ExtractOptions
hiedbOpts r = (extOpts Auto) { XT.rootDir = r }

-- | 把 hiedb fixture 複製到暫存目錄再跑(假設 A6:版控樹全程唯讀)。
withHiedbScratch :: String -> (FilePath -> IO a) -> IO a
withHiedbScratch tag act = do
  tmp <- getTemporaryDirectory
  let root = tmp </> ("knot-hs-f003-" <> tag)
  removePathForcibly root
  copyTree hiedbFixture root
  r <- act root
  removePathForcibly root
  pure r

copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
  isDir <- doesDirectoryExist from
  if isDir
    then do
      createDirectoryIfMissing True to
      entries <- listDirectory from
      forM_ entries $ \e -> copyTree (from </> e) (to </> e)
    else do
      createDirectoryIfMissing True (takeDirectory to)
      copyFile from to

expectRight :: Either Text a -> IO a
expectRight (Left e)  = assertFailure ("expected Right, got: " <> T.unpack e)
expectRight (Right a) = pure a

expectUnavailable :: String -> ProbeResult -> IO Text
expectUnavailable pfx r = case r of
  Available -> assertFailure ("expected Unavailable with prefix " <> show pfx)
  Unavailable reason -> do
    assertBool ("expected prefix " <> show pfx <> ", got: " <> T.unpack reason)
      (T.pack pfx `T.isPrefixOf` reason)
    pure reason

-- extraction/F003 T1: 預設索引位置(規則 6)是純函數
testDefaultDbPath :: TestTree
testDefaultDbPath = testCase "test_default_db_path" $ do
  forM_ ["proj", "/abs/root", "proj/", "C:/x/y"] $ \r -> do
    let p = defaultDbPath r
    takeFileName p @?= "hiedb.sqlite"
    takeFileName (takeDirectory p) @?= ".knot"
    p @?= r </> ".knot" </> "hiedb.sqlite"
  -- 純函數、零 IO:求值前後 .knot/ 都不存在
  tmp <- getTemporaryDirectory
  let r = tmp </> "knot-hs-f003-pure"
  removePathForcibly r
  doesDirectoryExist (r </> ".knot") >>= (@?= False)
  _ <- evaluate (length (defaultDbPath r))
  doesDirectoryExist (r </> ".knot") >>= (@?= False)
  -- IndexStats 的 Eq / Show 可用(F004 與重用驗收都靠它)
  let st = IndexStats { indexedCount = 2, skippedCount = 0, batchCount = 1 }
  st @?= IndexStats 2 0 1
  assertBool "IndexStats Show" ("indexedCount = 2" `isInfixOf` show st)

-- extraction/F003 T2: 命令列分批(雙上限、不丟檔、順序保持)
testChunkFileArgs :: TestTree
testChunkFileArgs = testGroup "test_chunk_file_args"
  [ testCase "examples" $ do
      chunkFileArgs 100 10 [] @?= []
      -- 檔數上限觸發
      let xs = map (\i -> "a" <> show i) [1 .. 10 :: Int]
      map length (chunkFileArgs 100000 3 xs) @?= [3, 3, 3, 1]
      concat (chunkFileArgs 100000 3 xs) @?= xs
      -- 字元上限觸發(每個路徑計 length + 3 的餘裕 → 20)
      let ys = replicate 5 (replicate 17 'x')
      map length (chunkFileArgs 45 100 ys) @?= [2, 2, 1]
      -- 單一超長路徑自成一批且不被丟棄
      let long = replicate 200 'z'
      chunkFileArgs 10 100 ["a", long, "b"] @?= [["a"], [long], ["b"]]
  , testProperty "concat . chunkFileArgs a b == id" $ property $ do
      xs <- forAll (Gen.list (Range.linear 0 40)
              (Gen.string (Range.linear 1 20) Gen.alphaNum))
      charCap <- forAll (Gen.int (Range.linear 1 200))
      fileCap <- forAll (Gen.int (Range.linear 1 10))
      let batches = chunkFileArgs charCap fileCap xs
      concat batches === xs
      annotate ("batch sizes: " <> show (map length batches))
      assert (all (not . null) batches)
      assert (all ((<= fileCap) . length) batches)
  ]

-- extraction/F003 T3: hiedb 的 Completed! 行解析(多批相加)
testParseIndexStats :: TestTree
testParseIndexStats = testCase "test_parse_index_stats" $ do
  let one = T.pack "Completed! (2 indexed, 0 skipped in 0.21s + 0.00s gc)\n"
  parseIndexStats 1 one @?= IndexStats 2 0 1
  -- 兩批輸出串接 → 計數相加、批數取參數;progress 行不影響
  let two = one
        <> T.pack "Processing file src/Demo/App.hie\n"
        <> T.pack "Completed! (3 indexed, 1 skipped in 0.05s)\n"
  parseIndexStats 2 two @?= IndexStats 5 1 2
  -- 重跑的形狀
  parseIndexStats 1 (T.pack "Completed! (0 indexed, 2 skipped in 0.06s)")
    @?= IndexStats 0 2 1
  -- 不含 Completed! 的輸出 → 0/0(exit code 才是權威)
  parseIndexStats 3 (T.pack "Processing file a\nProcessing file b\n")
    @?= IndexStats 0 0 3
  parseIndexStats 0 T.empty @?= IndexStats 0 0 0

-- extraction/F003 T4: fixture 的真實 .hie 存在且與本 GHC 同版
testHiedbFixture :: TestTree
testHiedbFixture = testCase "test_hiedb_fixture" $ do
  let hies = [".hie/Demo/Core.hie", ".hie/Demo/App.hie"]
  forM_ (["src/Demo/Core.hs", "src/Demo/App.hs"] <> hies) $ \p -> do
    ok <- doesFileExist (hiedbFixture </> p)
    assertBool ("fixture file missing: " <> p) ok
  forM_ hies $ \p -> do
    bytes <- BS.readFile (hiedbFixture </> p)
    assertBool ("empty .hie (0 byte 空殼餵不了 hiedb): " <> p) (BS.length bytes > 0)
    BS.take 3 bytes @?= TE.encodeUtf8 (T.pack "HIE")
    -- 檔頭第二行 = 產生它的 GHC 版本;GHC 升版時這裡先紅,指向重跑產生指令
    case BS.split 10 (BS.drop 3 (BS.take 64 bytes)) of
      (_hieVer : ghcVer : _) ->
        TE.decodeUtf8 ghcVer @?= T.pack (showVersion fullCompilerVersion)
      _ -> assertFailure ("unrecognised .hie header: " <> p)

-- extraction/F003 T5: 跳過訊息與跳過數(D7 / 假設 A7)
testHiedbSkipNotice :: TestTree
testHiedbSkipNotice = testCase "test_hiedb_skip_notice" $ do
  let absent = hiedbNotice Nothing hiedbGatedCount
  forM_ ["hiedb", "not found", show hiedbGatedCount] $ \needle ->
    assertBool ("skip notice must mention " <> show needle <> ": " <> absent)
      (needle `isInfixOf` absent)
  let present = hiedbNotice (Just "C:/cabal/bin/hiedb.exe") hiedbGatedCount
  assertBool ("notice must name the executable: " <> present)
    ("C:/cabal/bin/hiedb.exe" `isInfixOf` present)
  -- 佔位節點名稱也帶跳過數,使其出現在 tasty 逐項輸出
  assertBool "skip label carries the count"
    (show hiedbGatedCount `isInfixOf` hiedbSkipLabel hiedbGatedCount)
  -- 常數與實際受管轄的節點數對帳
  hiedbGatedCount @?= length hiedbGatedTests

-- extraction/F003 T6(不需 hiedb):執行檔類不可用,原因指明執行檔
testProbeHiedbNoExe :: TestTree
testProbeHiedbNoExe = testCase "test_probe_hiedb" $ do
  pm <- loadProjectMeta (defOpts hiedbFixture)
  let missing = hiedbFixture </> "no-such-hiedb-binary"
      opts = (hiedbOpts hiedbFixture) { XT.hiedbExe = Just missing }
  reason <- expectUnavailable "hiedb executable " =<< probeHiedb opts pm
  assertBool ("reason must name the executable: " <> T.unpack reason)
    (T.pack missing `T.isInfixOf` reason)

-- extraction/F003 T6(需 hiedb):.hie 類與版本類的區分,以及全過 → Available
testProbeHiedbAvailable :: TestTree
testProbeHiedbAvailable = testCase "test_probe_hiedb_available" $ do
  pm <- loadProjectMeta (defOpts hiedbFixture)
  hie <- case pmHie pm of
    Nothing -> assertFailure "fixture must expose a .hie directory"
    Just h  -> pure h
  -- fixture 的 .hie 由本 GHC 產出 → 全過
  probeHiedb (hiedbOpts hiedbFixture) pm >>= (@?= Available)
  -- 無 .hie 目錄
  _ <- expectUnavailable "hie files unavailable: "
    =<< probeHiedb (hiedbOpts hiedbFixture) pm { pmHie = Nothing }
  -- 清單為空 → 訊息含 hieDir
  emptyReason <- expectUnavailable "hie files unavailable: "
    =<< probeHiedb (hiedbOpts hiedbFixture) pm { pmHie = Just hie { hieFiles = [] } }
  assertBool ("reason must name hieDir: " <> T.unpack emptyReason)
    (T.pack (hieDir hie) `T.isInfixOf` emptyReason)
  -- 版本類:檔頭寫著別版 GHC(ADR-001 版本鎖)
  withHiedbScratch "probe" $ \root -> do
    let fake = ".hie/Demo/Fake.hie"
    BS.writeFile (root </> fake) (TE.encodeUtf8 (T.pack "HIE9141\n8.10.7\n"))
    mismatch <- expectUnavailable "hie/ghc version mismatch: "
      =<< probeHiedb (hiedbOpts root) pm { pmHie = Just hie { hieFiles = [fake] } }
    assertBool ("reason must name the .hie: " <> T.unpack mismatch)
      (T.pack "Fake.hie" `T.isInfixOf` mismatch)
    -- 檔頭不成形 → .hie 類(不是版本類)
    let broken = ".hie/Demo/Broken.hie"
    BS.writeFile (root </> broken) (TE.encodeUtf8 (T.pack "not a hie file"))
    _ <- expectUnavailable "hie files unavailable: "
      =<< probeHiedb (hiedbOpts root) pm { pmHie = Just hie { hieFiles = [broken] } }
    pure ()

-- extraction/F003 T7: ensureIndex 主流程(驗收標準 2)
testEnsureIndex :: TestTree
testEnsureIndex = testCase "test_ensure_index" $ withHiedbScratch "ensure" $ \root -> do
  pm <- loadProjectMeta (defOpts root)
  hie <- case pmHie pm of
    Nothing -> assertFailure "scratch tree must expose a .hie directory"
    Just h  -> pure h
  length (hieFiles hie) @?= 2
  h <- expectRight =<< ensureIndex (hiedbOpts root) pm
  rootAbs <- makeAbsolute root
  assertBool ("ihDbPath must be absolute: " <> ihDbPath h) (isAbsolute (ihDbPath h))
  ihDbPath h @?= rootAbs </> ".knot" </> "hiedb.sqlite"
  doesFileExist (ihDbPath h) >>= (@?= True)
  -- 「可被 SQLite 開啟」的機器可驗證形式:檔案 magic
  magic <- BS.take 16 <$> BS.readFile (ihDbPath h)
  magic @?= TE.encodeUtf8 (T.pack "SQLite format 3") <> BS.pack [0]
  assertBool ("ihRootDir must be absolute: " <> ihRootDir h) (isAbsolute (ihRootDir h))
  ihRootDir h @?= rootAbs
  ihStats h @?= IndexStats { indexedCount = 2, skippedCount = 0, batchCount = 1 }
  assertBool "ihExe must name the executable actually used" (not (null (ihExe h)))
  -- 壞檔:單一 0 byte 假 .hie 會讓整批 hiedb index 以 exit 1 中止 → Left
  let bad = ".hie/Demo/Bad.hie"
  BS.writeFile (root </> bad) BS.empty
  broken <- ensureIndex (hiedbOpts root)
    pm { pmHie = Just hie { hieFiles = hieFiles hie <> [bad] } }
  case broken of
    Right _ -> assertFailure "expected Left for a corrupt .hie"
    Left e  -> assertBool ("expected index-failure prefix, got: " <> T.unpack e)
      (T.pack "hiedb index failed: " `T.isPrefixOf` e)

-- extraction/F003 T8: .knot/ 政策與 dbPath 改道(驗收標準 3)
testKnotDirPolicy :: TestTree
testKnotDirPolicy = testCase "test_knot_dir_policy" $ do
  -- (a) 預設路徑 + 乾淨樹 → 建 .knot/ 並產生恰一則提示
  withHiedbScratch "knot" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    doesDirectoryExist (root </> ".knot") >>= (@?= False)
    h1 <- expectRight =<< ensureIndex (hiedbOpts root) pm
    doesFileExist (root </> ".knot" </> "hiedb.sqlite") >>= (@?= True)
    case ihNotes h1 of
      [n] -> do
        ewSource n @?= hiedbName
        assertBool ("note must mention .knot: " <> T.unpack (ewMessage n))
          (T.pack ".knot" `T.isInfixOf` ewMessage n)
        assertBool ("note must mention .gitignore: " <> T.unpack (ewMessage n))
          (T.pack ".gitignore" `T.isInfixOf` ewMessage n)
      ns -> assertFailure ("expected exactly one note, got: " <> show ns)
    -- (b) 已存在 → 不重複提示
    h2 <- expectRight =<< ensureIndex (hiedbOpts root) pm
    ihNotes h2 @?= []
  -- (c) dbPath 指到專案外的絕對路徑 → .knot/ 完全不被建立、不出提示
  withHiedbScratch "dbabs" $ \root -> do
    tmp <- getTemporaryDirectory
    let outside = tmp </> "knot-hs-f003-dbabs-out" </> "elsewhere.sqlite"
    removePathForcibly (takeDirectory outside)
    pm <- loadProjectMeta (defOpts root)
    h <- expectRight =<< ensureIndex ((hiedbOpts root) { XT.dbPath = Just outside }) pm
    outsideAbs <- makeAbsolute outside
    ihDbPath h @?= outsideAbs
    doesFileExist outside >>= (@?= True)
    doesDirectoryExist (root </> ".knot") >>= (@?= False)
    ihNotes h @?= []
    removePathForcibly (takeDirectory outside)
  -- (d) dbPath 為相對路徑 → 以 rootDir 為錨點(階段二閘門對假設 A3 的裁決),
  --     不是行程 cwd;.knot/ 一樣不被建立
  withHiedbScratch "dbrel" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    let rel = "build/idx.sqlite"
    h <- expectRight =<< ensureIndex ((hiedbOpts root) { XT.dbPath = Just rel }) pm
    rootAbs <- makeAbsolute root
    ihDbPath h @?= rootAbs </> "build" </> "idx.sqlite"
    doesFileExist (root </> "build" </> "idx.sqlite") >>= (@?= True)
    doesDirectoryExist (root </> ".knot") >>= (@?= False)
    -- 錨點確實是 rootDir 而非行程 cwd
    doesFileExist ("build" </> "idx.sqlite") >>= (@?= False)
    ihNotes h @?= []

-- extraction/F003 T9: 索引重用以計數判定,不用計時(驗收標準 4)
testIndexReuse :: TestTree
testIndexReuse = testCase "test_index_reuse" $ withHiedbScratch "reuse" $ \root -> do
  pm <- loadProjectMeta (defOpts root)
  h1 <- expectRight =<< ensureIndex (hiedbOpts root) pm
  h2 <- expectRight =<< ensureIndex (hiedbOpts root) pm
  (indexedCount (ihStats h1), skippedCount (ihStats h1)) @?= (2, 0)
  (indexedCount (ihStats h2), skippedCount (ihStats h2)) @?= (0, 2)
  ihDbPath h2 @?= ihDbPath h1

-- extraction/F003 T10(不需 hiedb):探測失敗 → 整體降級為 ModuleLevel
-- 而不失敗(驗收標準 1)
testHiedbDegrade :: TestTree
testHiedbDegrade = testCase "test_hiedb_degrade" $ do
  ranRef <- newIORef False
  let missing = hiedbFixture </> "no-such-hiedb-binary"
      -- F004 之前的暫代組裝:bRun 被呼叫即代表降級判斷錯了
      hiedbBackend = Backend
        { bName  = hiedbName
        , bLevel = DeclLevel
        , bProbe = probeHiedb
        , bRun   = \_ _ -> writeIORef ranRef True >> pure ([], [])
        }
      opts = (extOpts Auto)
        { XT.rootDir = projFixture, XT.hiedbExe = Just missing }
  pm <- loadProjectMeta (defOpts projFixture)
  res <- runBackends [importScanBackend, hiedbBackend] opts pm
  erLevel res @?= ModuleLevel
  case erReports res of
    [scanRep, hiedbRep] -> do
      brBackend scanRep @?= importScanName
      brUsed scanRep @?= True
      brBackend hiedbRep @?= hiedbName
      brUsed hiedbRep @?= False
      assertBool ("degrade reason must name the executable: " <> T.unpack (brDetail hiedbRep))
        (T.pack "hiedb executable " `T.isPrefixOf` brDetail hiedbRep)
    rs -> assertFailure ("expected two reports, got: " <> show rs)
  assertBool "import-scan facts must survive the degrade" (not (null (erFacts res)))
  readIORef ranRef >>= (@?= False)

-- extraction/F003 T11: 以 knot-hs 自身的真實 .hie 唯讀驗收(D8:不碰
-- MagicFarmer / particle-magic);沒有 .hie 時印明原因並跳過
testHiedbSelfcheck :: TestTree
testHiedbSelfcheck = testCase "test_hiedb_selfcheck" $ do
  pm <- loadProjectMeta (defOpts ".")
  case pmHie pm of
    Just hie | not (null (hieFiles hie)) -> do
      knotBefore <- doesDirectoryExist ".knot"
      tmp <- getTemporaryDirectory
      let db = tmp </> "knot-hs-f003-self" </> "self.sqlite"
      removePathForcibly (takeDirectory db)
      h <- expectRight
        =<< ensureIndex ((extOpts Auto) { XT.rootDir = ".", XT.dbPath = Just db }) pm
      assertBool "self index must index at least one .hie"
        (indexedCount (ihStats h) > 0)
      -- 唯讀驗收:目標專案內不得新建 .knot/
      doesDirectoryExist ".knot" >>= (@?= knotBefore)
      putStrLn ("[selfcheck] hieFiles=" <> show (length (hieFiles hie))
        <> " first=" <> show (ihStats h))
      h2 <- expectRight
        =<< ensureIndex ((extOpts Auto) { XT.rootDir = ".", XT.dbPath = Just db }) pm
      putStrLn ("[selfcheck] second=" <> show (ihStats h2))
      removePathForcibly (takeDirectory db)
    _ -> putStrLn
      "[skip] test_hiedb_selfcheck: knot-hs itself has no .hie files \
      \(build with -fwrite-ide-info to enable this check)"

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

--------------------------------------------------------------------------------
-- export-query / F002 graph-load
--------------------------------------------------------------------------------

exportQueryF002Tests :: TestTree
exportQueryF002Tests = testGroup "export-query/F002 graph-load"
  [ testQueryTypesConstruct          -- T1
  , testRelationClassification       -- T2
  , testParseQueryGraphOk            -- T3
  , testParseQueryGraphErrors        -- T4
  , testLoadQueryGraphIoRoundtrip    -- T5
  , testQueryGraphHasNode            -- T6(階段二閘門裁決補的契約)
  ]

-- | 查詢面節點 id 的測試捷徑(qualified,與 graph-core 的 nid 區隔)。
qid :: String -> QT.NodeId
qid = QT.NodeId . T.pack

-- | 測試用的解析入口:路徑只進訊息,不落地檔案。
parseAt :: FilePath -> String -> Either QT.LoadError QT.QueryGraph
parseAt path = parseQueryGraph path . TE.encodeUtf8 . T.pack

parseBad :: String -> Either QT.LoadError QT.QueryGraph
parseBad = parseAt "graph.json"

-- | 斷言回 LoadSchemaError,且訊息含全部指定片段。
expectSchema :: String -> [String] -> IO ()
expectSchema src needles = case parseBad src of
  Left (QT.LoadSchemaError m) -> forM_ needles $ \n ->
    assertBool ("message " <> show m <> " should contain " <> show n)
      (n `isInfixOf` T.unpack m)
  other -> assertFailure ("expected LoadSchemaError, got: " <> show other)

-- export-query/F002 T1: 四個型別的建構與欄位讀取、Eq、NodeId 的字典序 Ord,
-- 以及兩個同名 NodeId 在 qualified import 下並存(假設 A1)
testQueryTypesConstruct :: TestTree
testQueryTypesConstruct = testCase "test_query_types_construct" $ do
  let node = QT.QueryNode
        { QT.qnId    = qid "A"
        , QT.qnLabel = T.pack "Demo.A"
        , QT.qnFile  = "src/Demo/A.hs"
        }
  QT.qnId node    @?= qid "A"
  QT.qnLabel node @?= T.pack "Demo.A"
  QT.qnFile node  @?= "src/Demo/A.hs"
  let g = QT.QueryGraph
        { QT.qgNodes   = [node]
        , QT.qgIndex   = Map.singleton (qid "A") node
        , QT.qgForward = Map.singleton (qid "A") [qid "A"]
        , QT.qgReverse = Map.singleton (qid "A") [qid "A"]
        , QT.qgOutDeg  = Map.singleton (qid "A") 1
        , QT.qgInDeg   = Map.singleton (qid "A") 1
        , QT.qgNotes   = [(T.pack "foo", 2)]
        }
  QT.qgNodes g   @?= [node]
  QT.qgIndex g   @?= Map.singleton (qid "A") node
  QT.qgForward g @?= Map.singleton (qid "A") [qid "A"]
  QT.qgReverse g @?= Map.singleton (qid "A") [qid "A"]
  QT.qgOutDeg g  @?= Map.singleton (qid "A") 1
  QT.qgInDeg g   @?= Map.singleton (qid "A") 1
  QT.qgNotes g   @?= [(T.pack "foo", 2)]
  (g == g) @?= True
  (g { QT.qgNotes = [] } == g) @?= False
  -- LoadError 三建構子彼此互異(同一段文字也不相等)
  let t = T.pack "x"
  assertBool "missing /= parse"  (QT.LoadFileMissing t /= QT.LoadParseError t)
  assertBool "parse /= schema"   (QT.LoadParseError t  /= QT.LoadSchemaError t)
  assertBool "missing /= schema" (QT.LoadFileMissing t /= QT.LoadSchemaError t)
  (QT.LoadSchemaError t == QT.LoadSchemaError t) @?= True
  -- NodeId 的 Ord 即 Text 碼位序(大寫在小寫之前)
  sort [qid "b", qid "A", qid "a"] @?= [qid "A", qid "a", qid "b"]
  -- 假設 A1:同時使用 graph-core 與查詢面的 NodeId,qualified 下可編譯
  nid "A" @?= NodeId (T.pack "A")
  QT.qnId node @?= qid "A"

-- export-query/F002 T2: 查詢規則 1 的兩張表與 classifyRelation 的三分類
testRelationClassification :: TestTree
testRelationClassification = testCase "test_relation_classification" $ do
  -- 逐字對帳 ADR-003 / scan-graph.mjs:59-64(防止日後手滑增刪)
  dependencyRelations @?= map T.pack
    [ "imports", "imports_from", "calls", "uses", "references"
    , "extends", "implements", "inherits", "instantiates", "depends_on"
    ]
  structuralRelations @?= map T.pack
    [ "contains", "method", "defines", "declares", "rationale_for", "part_of" ]
  length dependencyRelations @?= 10
  length structuralRelations @?= 6
  map classifyRelation dependencyRelations @?= replicate 10 RelDependency
  map classifyRelation structuralRelations @?= replicate 6 RelStructural
  -- 其餘一律 RelUnknown;分類大小寫敏感
  map (classifyRelation . T.pack) ["foo", "", "Imports", "contains_all"]
    @?= replicate 4 RelUnknown
  -- 反向對映:knot 自家匯出的五種 relation 全部認得
  map (classifyRelation . relationText) [RImports, RCalls, RUses, RImplements, RContains]
    @?= [RelDependency, RelDependency, RelDependency, RelDependency, RelStructural]

-- | T3 的手寫圖:節點在檔案中刻意逆序(D、C、B、A);邊涵蓋重複邊、
-- 結構類、未知類與自環。
okGraphJson :: String
okGraphJson = unlines
  [ "{"
  , "  \"directed\": true,"
  , "  \"built_at_commit\": \"deadbeef\","
  , "  \"nodes\": ["
  , "    {\"id\":\"D\",\"label\":\"Demo.D\",\"source_file\":\"src/D.hs\"},"
  , "    {\"id\":\"C\",\"label\":\"Demo.C\",\"source_file\":\"src/C.hs\",\"source_location\":\"L3\"},"
  , "    {\"id\":\"B\",\"label\":\"Demo.B\",\"source_file\":\"src/B.hs\"},"
  , "    {\"id\":\"A\",\"label\":\"Demo.A\",\"source_file\":\"src/A.hs\"}"
  , "  ],"
  , "  \"links\": ["
  , "    {\"source\":\"A\",\"target\":\"B\",\"relation\":\"imports\",\"confidence\":\"EXTRACTED\"},"
  , "    {\"source\":\"A\",\"target\":\"B\",\"relation\":\"imports\"},"
  , "    {\"source\":\"B\",\"target\":\"C\",\"relation\":\"calls\"},"
  , "    {\"source\":\"A\",\"target\":\"D\",\"relation\":\"contains\"},"
  , "    {\"source\":\"B\",\"target\":\"D\",\"relation\":\"method\"},"
  , "    {\"source\":\"A\",\"target\":\"C\",\"relation\":\"foo\"},"
  , "    {\"source\":\"B\",\"target\":\"C\",\"relation\":\"foo\"},"
  , "    {\"source\":\"A\",\"target\":\"C\",\"relation\":\"bar\"},"
  , "    {\"source\":\"C\",\"target\":\"C\",\"relation\":\"depends_on\"}"
  , "  ]"
  , "}"
  ]

-- export-query/F002 T3: parseQueryGraph 成功路徑——分流、去重升序、度數算邊數、
-- 自環保留、全域定序與決定性
testParseQueryGraphOk :: TestTree
testParseQueryGraphOk = testCase "test_parse_query_graph_ok" $ do
  g <- case parseBad okGraphJson of
    Right x  -> pure x
    Left err -> assertFailure ("expected a successful load, got: " <> show err)
  -- 規則 3、4:全部節點都在(D 只被 contains / method 邊連到),依 id 升序
  map QT.qnId (QT.qgNodes g) @?= [qid "A", qid "B", qid "C", qid "D"]
  map QT.qnLabel (QT.qgNodes g)
    @?= map T.pack ["Demo.A", "Demo.B", "Demo.C", "Demo.D"]
  map QT.qnFile (QT.qgNodes g)
    @?= ["src/A.hs", "src/B.hs", "src/C.hs", "src/D.hs"]
  Map.keys (QT.qgIndex g) @?= [qid "A", qid "B", qid "C", qid "D"]
  -- 規則 6:鄰居去重且依 id 升序;自環保留(規則 5 的前提)
  QT.qgForward g @?= Map.fromList
    [ (qid "A", [qid "B"]), (qid "B", [qid "C"]), (qid "C", [qid "C"]) ]
  QT.qgReverse g @?= Map.fromList
    [ (qid "B", [qid "A"]), (qid "C", [qid "B", qid "C"]) ]
  -- 假設 A4:度數算邊數不去重(A 的兩條 imports 記 2,對照 qgForward 只有 1 個鄰居)
  QT.qgOutDeg g @?= Map.fromList [(qid "A", 2), (qid "B", 1), (qid "C", 1)]
  QT.qgInDeg  g @?= Map.fromList [(qid "B", 2), (qid "C", 2)]
  -- 驗收標準 5:contains / method 邊不進 Reachable 的唯一資料來源
  forM_ [QT.qgForward g, QT.qgReverse g] $ \m ->
    assertBool "D is absent from the dependency adjacency"
      (Map.notMember (qid "D") m)
  forM_ [QT.qgOutDeg g, QT.qgInDeg g] $ \m ->
    assertBool "D has no dependency degree" (Map.notMember (qid "D") m)
  assertBool "contains target D is not a neighbour of A"
    (qid "D" `notElem` Map.findWithDefault [] (qid "A") (QT.qgForward g))
  -- 驗收標準 4:未知 relation 彙整、依名升序;結構類不入列
  queryGraphNotes g @?= [(T.pack "bar", 1), (T.pack "foo", 2)]
  QT.qgNotes g @?= queryGraphNotes g
  -- 規則 4:同一份 bytes 解兩次結果相等
  parseBad okGraphJson @?= Right g

-- export-query/F002 T4: parseQueryGraph 錯誤路徑(訊息含路徑 + locus + 問題)
testParseQueryGraphErrors :: TestTree
testParseQueryGraphErrors = testCase "test_parse_query_graph_errors" $ do
  -- 壞 JSON → LoadParseError,訊息含檔名
  case parseBad "{" of
    Left (QT.LoadParseError m) ->
      assertBool ("parse error mentions the path: " <> show m)
        ("graph.json" `isInfixOf` T.unpack m)
    other -> assertFailure ("expected LoadParseError, got: " <> show other)
  expectSchema "[]" ["graph.json", "top level is not a JSON object"]
  -- 驗收標準 2
  expectSchema "{\"links\":[]}" ["graph.json", "missing required field \"nodes\""]
  expectSchema "{\"nodes\":{}}" ["\"nodes\" is not an array"]
  expectSchema
    ("{\"nodes\":[{\"id\":\"A\",\"label\":\"A\",\"source_file\":\"a\"},"
      <> "{\"id\":\"B\",\"source_file\":\"b\"}]}")
    ["nodes[1]", "missing required field \"label\""]
  expectSchema "{\"nodes\":[{\"id\":\"A\",\"label\":1,\"source_file\":\"a\"}]}"
    ["nodes[0]", "field \"label\" is not a string"]
  -- 假設 A3:重複 id 是壞檔
  expectSchema
    ("{\"nodes\":[{\"id\":\"A\",\"label\":\"A\",\"source_file\":\"a\"},"
      <> "{\"id\":\"A\",\"label\":\"A2\",\"source_file\":\"a2\"}]}")
    ["nodes[1]", "duplicate node id \"A\""]
  expectSchema
    (oneNode <> ",\"links\":[{\"source\":\"A\",\"target\":\"A\"}]}")
    ["links[0]", "missing required field \"relation\""]
  -- 驗收標準 3:邊引用不存在的節點 id
  expectSchema
    (oneNode <> ",\"links\":[{\"source\":\"X\",\"target\":\"A\",\"relation\":\"imports\"}]}")
    ["links[0]", "source \"X\" is not a known node id"]
  expectSchema
    (oneNode <> ",\"links\":[{\"source\":\"A\",\"target\":\"Y\",\"relation\":\"imports\"}]}")
    ["links[0]", "target \"Y\" is not a known node id"]
  -- ADR-003:source/target 是節點 id,不接受舊格式的陣列索引
  expectSchema
    (oneNode <> ",\"links\":[{\"source\":0,\"target\":\"A\",\"relation\":\"imports\"}]}")
    ["links[0]", "field \"source\" is not a string"]
  expectSchema "{\"nodes\":[],\"links\":\"x\"}" ["\"links\" is not an array"]
  -- 假設 A2:links 缺鍵當空陣列 → 成功且圖為空
  case parseBad "{\"nodes\":[]}" of
    Right g -> do
      QT.qgNodes g   @?= []
      QT.qgIndex g   @?= Map.empty
      QT.qgForward g @?= Map.empty
      QT.qgReverse g @?= Map.empty
      QT.qgOutDeg g  @?= Map.empty
      QT.qgInDeg g   @?= Map.empty
      queryGraphNotes g @?= []
    other -> assertFailure ("expected an empty graph, got: " <> show other)
  -- fail-fast 的決定性:同一份壞檔解兩次訊息完全相同
  parseBad "{\"nodes\":{}}" @?= parseBad "{\"nodes\":{}}"
  -- 路徑原樣進訊息(不同路徑 → 不同訊息)
  assertBool "the path is part of the message"
    (parseAt "other.json" "[]" /= parseBad "[]")
 where
  oneNode = "{\"nodes\":[{\"id\":\"A\",\"label\":\"A\",\"source_file\":\"a\"}]"

-- export-query/F002 T5: loadQueryGraph 進入點與 F001 round-trip(驗收標準 1、5)
testLoadQueryGraphIoRoundtrip :: TestTree
testLoadQueryGraphIoRoundtrip = testCase "test_load_query_graph_io_roundtrip" $
  withExportDir "load" $ \dir -> do
    -- (a) 檔案不存在
    let gone = dir </> "nope.json"
    r1 <- loadQueryGraph gone
    case r1 of
      Left (QT.LoadFileMissing m) -> do
        assertBool ("message mentions the path: " <> show m)
          (takeFileName gone `isInfixOf` T.unpack m)
        assertBool ("message says file not found: " <> show m)
          ("file not found" `isInfixOf` T.unpack m)
      other -> assertFailure ("expected LoadFileMissing, got: " <> show other)
    -- (b) 路徑是目錄:一樣回 LoadFileMissing,不拋例外
    r2 <- loadQueryGraph dir
    case r2 of
      Left (QT.LoadFileMissing _) -> pure ()
      other -> assertFailure
        ("expected LoadFileMissing for a directory, got: " <> show other)
    -- (c) 驗收標準 1:手寫 CodeGraph → writeCodegraph → loadQueryGraph
    let g = graphWith
          [ xNode "Demo.A" "Demo.A" "src/Demo/A.hs" Nothing
          , xNode "Demo.B" "Demo.B" "src/Demo/B.hs" (Just 4)
          , xNode "Demo.C" "Demo.C" "src/Demo/C.hs" Nothing
          ]
          [ xEdge "Demo.A" "Demo.B" RImports (Just 6)
          , xEdge "Demo.B" "Demo.C" RCalls (Just 9)
          , xEdge "Demo.A" "Demo.C" RContains Nothing
          ]
        out = dir </> "codegraph.json"
    _ <- writeCodegraph ExportOptions
      { rootDir = dir, outputPath = out, commitPolicy = NoCommit } g
    loaded <- loadQueryGraph out
    q <- case loaded of
      Right x  -> pure x
      Left err -> assertFailure ("round-trip load failed: " <> show err)
    map QT.qnId (QT.qgNodes q)
      @?= [qid "Demo.A", qid "Demo.B", qid "Demo.C"]
    map QT.qnLabel (QT.qgNodes q)
      @?= map T.pack ["Demo.A", "Demo.B", "Demo.C"]
    map QT.qnFile (QT.qgNodes q)
      @?= ["src/Demo/A.hs", "src/Demo/B.hs", "src/Demo/C.hs"]
    -- 驗收標準 5:contains 那條不在依賴圖裡
    QT.qgForward q @?= Map.fromList
      [ (qid "Demo.A", [qid "Demo.B"]), (qid "Demo.B", [qid "Demo.C"]) ]
    QT.qgReverse q @?= Map.fromList
      [ (qid "Demo.B", [qid "Demo.A"]), (qid "Demo.C", [qid "Demo.B"]) ]
    QT.qgOutDeg q @?= Map.fromList [(qid "Demo.A", 1), (qid "Demo.B", 1)]
    QT.qgInDeg  q @?= Map.fromList [(qid "Demo.B", 1), (qid "Demo.C", 1)]
    assertBool "contains target is not a forward neighbour of Demo.A"
      (qid "Demo.C" `notElem` Map.findWithDefault [] (qid "Demo.A") (QT.qgForward q))
    -- 自家輸出不含未知 relation
    queryGraphNotes q @?= []
    -- (d) 規則 4:同一個檔案載入兩次結果相等
    again <- loadQueryGraph out
    again @?= Right q

-- export-query/F002 T6: queryGraphHasNode——契約的節點存在性通道
-- (階段二閘門裁決;組裝層 missingNodeLines 的唯一資料來源)
testQueryGraphHasNode :: TestTree
testQueryGraphHasNode = testCase "test_query_graph_has_node" $ do
  g <- case parseBad okGraphJson of
    Right x  -> pure x
    Left err -> assertFailure ("expected a successful load, got: " <> show err)
  -- 存在的節點一律 True
  map (queryGraphHasNode g) [qid "A", qid "B", qid "C"] @?= [True, True, True]
  -- 查詢規則 3:只被結構類邊(contains / method)連到的 D 也算存在
  -- ——它不在 qgForward / qgReverse / 度數裡,存在性仍為 True
  assertBool "D is absent from the dependency adjacency"
    (Map.notMember (qid "D") (QT.qgForward g)
       && Map.notMember (qid "D") (QT.qgReverse g))
  queryGraphHasNode g (qid "D") @?= True
  -- 不存在的 id 回 False(大小寫敏感,與 NodeId 的 Eq 一致)
  map (queryGraphHasNode g) [qid "Z", qid "", qid "a", qid "AB"]
    @?= [False, False, False, False]
  -- 與 qgNodes / qgIndex 的全域對帳:兩者對每個 id 的答案一致
  map (queryGraphHasNode g) (map QT.qnId (QT.qgNodes g))
    @?= replicate (length (QT.qgNodes g)) True
  Map.keys (QT.qgIndex g) @?= map QT.qnId (QT.qgNodes g)
  -- 空圖:任何 id 都不存在
  case parseBad "{\"nodes\":[]}" of
    Right e0 -> queryGraphHasNode e0 (qid "A") @?= False
    other    -> assertFailure ("empty graph should load, got: " <> show other)
  -- Knot.Query 的匯出清單已含 queryGraphHasNode(F004 只 import 這一個模組)
  KQ.queryGraphHasNode g (KQ.NodeId (T.pack "D")) @?= True
  KQ.queryGraphHasNode g (KQ.NodeId (T.pack "Z")) @?= False

--------------------------------------------------------------------------------
-- export-query / F003 query-commands
--------------------------------------------------------------------------------

exportQueryF003Tests :: TestTree
exportQueryF003Tests = testGroup "export-query/F003 query-commands"
  [ testQueryCommandTypes  -- T1
  , testQueryFind          -- T2
  , testQueryReachable     -- T3
  , testQueryPath          -- T4
  , testQueryRank          -- T5
  , testRenderResult       -- T6
  , testQueryDeterminism   -- T7
  ]

--------------------------------------------------------------------------------
-- F003 fixture 圖:不手寫 QueryGraph,改手寫 codegraph.json 走 parseQueryGraph
-- (三條不變式——鄰接去重升序、度數算邊數、節點依 id 升序——由載入層保證)
--------------------------------------------------------------------------------

jsonNode :: String -> String -> String -> String
jsonNode i l f = concat
  ["{\"id\":\"", i, "\",\"label\":\"", l, "\",\"source_file\":\"", f, "\"}"]

jsonLink :: String -> String -> String -> String
jsonLink s t r = concat
  ["{\"source\":\"", s, "\",\"target\":\"", t, "\",\"relation\":\"", r, "\"}"]

fixtureJson :: [String] -> [String] -> String
fixtureJson ns ls = concat
  [ "{\"directed\":true,\"nodes\":[", intercalate "," ns
  , "],\"links\":[", intercalate "," ls, "]}"
  ]

-- | 10 個節點,JSON 中刻意__依 id 降序__排列,以證明輸出序不是檔案原序;
-- label 與 id 刻意不同,才分得開「比對 id」與「比對 label」。
fixtureNodes :: [String]
fixtureNodes =
  [ jsonNode "Xray"   "Xray.Impl"     "src/Xray.hs"
  , jsonNode "Whisky" "Whisky.Impl"   "src/Whisky.hs"
  , jsonNode "T"      "Target.Module" "src/T.hs"
  , jsonNode "Self"   "Self.Ring"     "src/Self.hs"
  , jsonNode "S"      "Start.Module"  "src/S.hs"
  , jsonNode "Loop"   "Loop.One"      "src/Loop.hs"
  , jsonNode "Iso"    "Iso.Lonely"    "src/Iso.hs"
  , jsonNode "Cyc"    "Cyc.Two"       "src/Cyc.hs"
  , jsonNode "Beta"   "Beta.Impl"     "src/Beta.hs"
  , jsonNode "Alpha"  "Alpha.Impl"    "src/Alpha.hs"
  ]

-- | 依賴邊:兩條等長的 S→T 路徑(Alpha < Beta 但 Whisky < Xray,反向貪心的反例)、
-- 一條重複邊(度數不去重)、一個自環與一個二元環(規則 5)。
fixtureDepLinks :: [String]
fixtureDepLinks =
  [ jsonLink "S"      "Alpha"  "imports"
  , jsonLink "S"      "Alpha"  "imports"
  , jsonLink "S"      "Beta"   "calls"
  , jsonLink "Alpha"  "Xray"   "calls"
  , jsonLink "Beta"   "Whisky" "calls"
  , jsonLink "Xray"   "T"      "uses"
  , jsonLink "Whisky" "T"      "uses"
  , jsonLink "Self"   "Self"   "depends_on"
  , jsonLink "Loop"   "Cyc"    "imports"
  , jsonLink "Cyc"    "Loop"   "imports"
  ]

-- | 結構類 + 未知類:兩者都不該影響 reachable / path / rank(驗收標準 6)。
fixtureNoiseLinks :: [String]
fixtureNoiseLinks =
  [ jsonLink "Iso" "Alpha" "contains"
  , jsonLink "S"   "T"     "foo"
  ]

fixtureSrc :: String
fixtureSrc = fixtureJson fixtureNodes (fixtureDepLinks <> fixtureNoiseLinks)

-- | fixture 節點 id 的升序(規則 3、4 的期望輸出序)。
fixtureIdsAsc :: [QT.NodeId]
fixtureIdsAsc = map qid
  ["Alpha", "Beta", "Cyc", "Iso", "Loop", "S", "Self", "T", "Whisky", "Xray"]

loadFixture :: String -> IO QT.QueryGraph
loadFixture src = case parseAt "fixture.json" src of
  Right g  -> pure g
  Left err -> assertFailure ("fixture failed to load: " <> show err)

-- | T1 已釘住四個建構子的對應,故這裡的 fallback 分支不會被走到。
foundOf :: QT.QueryGraph -> String -> [(QT.NodeId, Text, FilePath)]
foundOf g kw = case runQuery g (QT.FindNodes (T.pack kw)) of
  QT.FoundNodes rows -> rows
  _                  -> []

reachableOf :: QT.QueryGraph -> QT.NodeId -> QT.Direction -> [(QT.NodeId, Int)]
reachableOf g i d = case runQuery g (QT.Reachable i d) of
  QT.ReachableSet rows -> rows
  _                    -> []

pathOf :: QT.QueryGraph -> QT.NodeId -> QT.NodeId -> Maybe [QT.NodeId]
pathOf g a b = case runQuery g (QT.ShortestPath a b) of
  QT.PathResult p -> p
  _               -> Nothing

-- | T7 (b)(c) 的比較面:四種查詢一次跑完。
probeAll :: QT.QueryGraph -> [QT.QueryResult]
probeAll g =
  [ runQuery g (QT.FindNodes (T.pack "impl"))
  , runQuery g (QT.FindNodes T.empty)
  , runQuery g (QT.Reachable (qid "S") QT.Forward)
  , runQuery g (QT.Reachable (qid "T") QT.Reverse)
  , runQuery g (QT.Reachable (qid "Loop") QT.Forward)
  , runQuery g (QT.ShortestPath (qid "S") (qid "T"))
  , runQuery g (QT.RankConnectivity 100)
  ]

-- export-query/F003 T1: 三個 DTO 的建構與 Eq、runQuery 的建構子對應、
-- Knot.Query 的匯出面,以及 fixture 圖的共用前提(10 個節點)
testQueryCommandTypes :: TestTree
testQueryCommandTypes = testCase "test_query_command_types" $ do
  -- QueryCommand 四建構子與參數順序
  let kw    = T.pack "demo"
      cFind = QT.FindNodes kw
      cFwd  = QT.Reachable (qid "A") QT.Forward
      cRev  = QT.Reachable (qid "A") QT.Reverse
      cPath = QT.ShortestPath (qid "A") (qid "B")
      cRank = QT.RankConnectivity 10
  cFind @?= QT.FindNodes kw
  assertBool "Forward /= Reverse" (QT.Forward /= QT.Reverse)
  (QT.Forward == QT.Forward) @?= True
  assertBool "direction distinguishes two Reachable commands" (cFwd /= cRev)
  assertBool "ShortestPath is ordered" (cPath /= QT.ShortestPath (qid "B") (qid "A"))
  assertBool "find /= rank" (cFind /= cRank)
  assertBool "reachable /= path" (cFwd /= cPath)
  -- QueryResult 四建構子彼此互異、欄位形狀依契約原文
  let rFound = QT.FoundNodes [(qid "A", T.pack "Demo.A", "src/A.hs")]
      rReach = QT.ReachableSet [(qid "A", 1)]
      rPath  = QT.PathResult (Just [qid "A", qid "B"])
      rRank  = QT.Ranking [(qid "A", 1, 2)]
  rFound @?= QT.FoundNodes [(qid "A", T.pack "Demo.A", "src/A.hs")]
  rReach @?= QT.ReachableSet [(qid "A", 1)]
  rPath  @?= QT.PathResult (Just [qid "A", qid "B"])
  rRank  @?= QT.Ranking [(qid "A", 1, 2)]
  assertBool "found /= reachable" (rFound /= rReach)
  assertBool "path /= rank"       (rPath /= rRank)
  assertBool "Just [] /= Nothing" (QT.PathResult (Just []) /= QT.PathResult Nothing)
  assertBool "ranking is (id, in, out)" (rRank /= QT.Ranking [(qid "A", 2, 1)])
  -- fixture:共用前提
  g <- loadFixture fixtureSrc
  length (QT.qgNodes g) @?= 10
  map QT.qnId (QT.qgNodes g) @?= fixtureIdsAsc
  queryGraphNotes g @?= [(T.pack "foo", 1)]
  -- runQuery 的四個分支各自回對應的 QueryResult 建構子
  -- (後續測試的 foundOf / reachableOf / pathOf 依賴這條)
  case runQuery g cFind of
    QT.FoundNodes _ -> pure ()
    other -> assertFailure ("FindNodes should yield FoundNodes, got: " <> show other)
  case runQuery g cFwd of
    QT.ReachableSet _ -> pure ()
    other -> assertFailure ("Reachable should yield ReachableSet, got: " <> show other)
  case runQuery g cPath of
    QT.PathResult _ -> pure ()
    other -> assertFailure ("ShortestPath should yield PathResult, got: " <> show other)
  case runQuery g cRank of
    QT.Ranking _ -> pure ()
    other -> assertFailure ("RankConnectivity should yield Ranking, got: " <> show other)
  -- Knot.Query 的匯出清單已含 runQuery / renderResult(F004 只 import 這一個模組)
  KQ.runQuery g cRank @?= runQuery g cRank
  KQ.renderResult (KQ.Ranking [(KQ.NodeId (T.pack "A"), 1, 2)])
    @?= renderResult rRank

-- export-query/F003 T2: FindNodes——不分大小寫、id 與 label 兩面、id 升序、
-- 掃全部節點(規則 3)、空關鍵字回全部(假設 A6)
testQueryFind :: TestTree
testQueryFind = testCase "test_query_find" $ do
  g <- loadFixture fixtureSrc
  -- 驗收標準 1:不分大小寫,三種寫法結果完全相同
  let alpha = [(qid "Alpha", T.pack "Alpha.Impl", "src/Alpha.hs")]
  foundOf g "alpha" @?= alpha
  foundOf g "ALPHA" @?= alpha
  foundOf g "Alpha" @?= alpha
  -- 比對 label 也命中:id "S" 不含 "start",只可能經 label "Start.Module"
  foundOf g "start" @?= [(qid "S", T.pack "Start.Module", "src/S.hs")]
  -- 三元組的第二、三欄即該節點的 label 與 source_file
  foundOf g "target" @?= [(qid "T", T.pack "Target.Module", "src/T.hs")]
  -- 多命中時依 id 升序(JSON 中節點是 id 降序,故此序不可能是檔案原序)
  foundOf g "impl" @?=
    [ (qid "Alpha",  T.pack "Alpha.Impl",  "src/Alpha.hs")
    , (qid "Beta",   T.pack "Beta.Impl",   "src/Beta.hs")
    , (qid "Whisky", T.pack "Whisky.Impl", "src/Whisky.hs")
    , (qid "Xray",   T.pack "Xray.Impl",   "src/Xray.hs")
    ]
  -- 規則 3:只被 contains 邊連到的節點照樣找得到
  foundOf g "Iso" @?= [(qid "Iso", T.pack "Iso.Lonely", "src/Iso.hs")]
  -- 查無命中是正常結果(空集合,exit 0 由 F004 決定)
  runQuery g (QT.FindNodes (T.pack "zzz")) @?= QT.FoundNodes []
  -- 假設 A6:空關鍵字回全部 10 個節點
  map (\(i, _, _) -> i) (foundOf g "") @?= fixtureIdsAsc

-- export-query/F003 T3: Reachable——方向、hop 距離、不含起點但環上以真實距離
-- 出現(規則 5)、起點不存在回空集合(假設 A1)、(距離, id) 升序(規則 4)
testQueryReachable :: TestTree
testQueryReachable = testCase "test_query_reachable" $ do
  g <- loadFixture fixtureSrc
  -- 驗收標準 2 + 規則 4、5 前半:距離正確、依 (距離, id) 升序、不含起點 S
  reachableOf g (qid "S") QT.Forward @?=
    [ (qid "Alpha", 1), (qid "Beta", 1)
    , (qid "Whisky", 2), (qid "Xray", 2)
    , (qid "T", 3)
    ]
  -- Reverse 走反向邊:誰依賴 T、隔幾層
  reachableOf g (qid "T") QT.Reverse @?=
    [ (qid "Whisky", 1), (qid "Xray", 1)
    , (qid "Alpha", 2), (qid "Beta", 2)
    , (qid "S", 3)
    ]
  -- 方向不對稱:T 沒有出邊、S 沒有入邊
  runQuery g (QT.Reachable (qid "T") QT.Forward) @?= QT.ReachableSet []
  runQuery g (QT.Reachable (qid "S") QT.Reverse) @?= QT.ReachableSet []
  -- 規則 5 後半:起點在環上時以真實距離出現(自環 1、二元環 2)
  reachableOf g (qid "Self") QT.Forward @?= [(qid "Self", 1)]
  reachableOf g (qid "Self") QT.Reverse @?= [(qid "Self", 1)]
  reachableOf g (qid "Loop") QT.Forward @?= [(qid "Cyc", 1), (qid "Loop", 2)]
  reachableOf g (qid "Cyc")  QT.Forward @?= [(qid "Loop", 1), (qid "Cyc", 2)]
  -- 驗收標準 6:contains 邊不進依賴圖——Iso 出不去、Alpha 反向也看不到 Iso
  runQuery g (QT.Reachable (qid "Iso") QT.Forward) @?= QT.ReachableSet []
  runQuery g (QT.Reachable (qid "Iso") QT.Reverse) @?= QT.ReachableSet []
  reachableOf g (qid "Alpha") QT.Reverse @?= [(qid "S", 1)]
  -- 假設 A1:起點不存在回空集合,不拋例外
  runQuery g (QT.Reachable (qid "NoSuchNode") QT.Forward) @?= QT.ReachableSet []
  runQuery g (QT.Reachable (qid "NoSuchNode") QT.Reverse) @?= QT.ReachableSet []

-- export-query/F003 T4: ShortestPath——等長多解取字典序最小(規則 6,反向貪心
-- 的反例)、不連通與端點不存在回 Nothing、from == to 回 Just [from](假設 A2)
testQueryPath :: TestTree
testQueryPath = testCase "test_query_path" $ do
  g <- loadFixture fixtureSrc
  -- 規則 6:S→Alpha→Xray→T 與 S→Beta→Whisky→T 等長,Alpha < Beta → 取前者。
  -- 這同時是反向貪心的反例:T 的兩個前驅是 Whisky 與 Xray 且 Whisky < Xray,
  -- 若實作誤取「前驅 id 最小」會回 [S,Beta,Whisky,T],本斷言必須擋下。
  pathOf g (qid "S") (qid "T")
    @?= Just [qid "S", qid "Alpha", qid "Xray", qid "T"]
  pathOf g (qid "S") (qid "Alpha") @?= Just [qid "S", qid "Alpha"]
  pathOf g (qid "S") (qid "Whisky")
    @?= Just [qid "S", qid "Beta", qid "Whisky"]
  -- 驗收標準 4:不連通回 Nothing(方向相反、走不回去)
  runQuery g (QT.ShortestPath (qid "Alpha") (qid "S")) @?= QT.PathResult Nothing
  -- 驗收標準 6:contains 邊不算路
  runQuery g (QT.ShortestPath (qid "S") (qid "Iso")) @?= QT.PathResult Nothing
  runQuery g (QT.ShortestPath (qid "Iso") (qid "Alpha")) @?= QT.PathResult Nothing
  -- 假設 A2:from == to 回 0 hop 的 Just [from],不去找環
  pathOf g (qid "S")    (qid "S")    @?= Just [qid "S"]
  pathOf g (qid "Self") (qid "Self") @?= Just [qid "Self"]
  pathOf g (qid "Loop") (qid "Loop") @?= Just [qid "Loop"]
  -- 環上的兩點仍算得出路徑
  pathOf g (qid "Loop") (qid "Cyc") @?= Just [qid "Loop", qid "Cyc"]
  -- 假設 A1:端點不存在回 Nothing
  runQuery g (QT.ShortestPath (qid "S") (qid "NoSuchNode"))
    @?= QT.PathResult Nothing
  runQuery g (QT.ShortestPath (qid "NoSuchNode") (qid "S"))
    @?= QT.PathResult Nothing
  -- 同一查詢跑兩次結果相等
  runQuery g (QT.ShortestPath (qid "S") (qid "T"))
    @?= runQuery g (QT.ShortestPath (qid "S") (qid "T"))

-- export-query/F003 T5: RankConnectivity——度數走邊數語意、同分按 id 升序、
-- 自環兩端各 +1、零連通度排除(假設 A3)、--top N 生效、n <= 0 回空(假設 A4)
testQueryRank :: TestTree
testQueryRank = testCase "test_query_rank" $ do
  g <- loadFixture fixtureSrc
  -- 10 個節點扣掉只有 contains 邊的 Iso = 9 列。
  -- S 的出度 3 = 兩條重複的 S→Alpha 計 2 再加 S→Beta(邊數語意,非相異鄰居數);
  -- Alpha 入度 2 同理;Self 的自環兩端各 +1 → (1,1)。
  -- 同分 tie-break:Alpha 與 S 同為總度數 3 而 Alpha 在前;
  -- 尾端 Whisky 與 Xray 同為 (1,1) 而 Whisky 在前。
  runQuery g (QT.RankConnectivity 100) @?= QT.Ranking
    [ (qid "Alpha",  2, 1)
    , (qid "S",      0, 3)
    , (qid "Beta",   1, 1)
    , (qid "Cyc",    1, 1)
    , (qid "Loop",   1, 1)
    , (qid "Self",   1, 1)
    , (qid "T",      2, 0)
    , (qid "Whisky", 1, 1)
    , (qid "Xray",   1, 1)
    ]
  -- 假設 A3:零連通度節點不進榜
  case runQuery g (QT.RankConnectivity 100) of
    QT.Ranking rows -> do
      length rows @?= 9
      assertBool "Iso is absent from the ranking"
        (qid "Iso" `notElem` [i | (i, _, _) <- rows])
    other -> assertFailure ("expected Ranking, got: " <> show other)
  -- 驗收標準 5:--top N 生效
  runQuery g (QT.RankConnectivity 3) @?= QT.Ranking
    [(qid "Alpha", 2, 1), (qid "S", 0, 3), (qid "Beta", 1, 1)]
  runQuery g (QT.RankConnectivity 1) @?= QT.Ranking [(qid "Alpha", 2, 1)]
  -- 假設 A4:n <= 0 回空清單,不視為錯誤
  runQuery g (QT.RankConnectivity 0)    @?= QT.Ranking []
  runQuery g (QT.RankConnectivity (-1)) @?= QT.Ranking []

-- export-query/F003 T6: renderResult 的逐字元格式(假設 A5)
testRenderResult :: TestTree
testRenderResult = testCase "test_render_result" $ do
  let a = qid "A"
      b = qid "B"
      c = qid "C"
      t = T.pack
  renderResult (QT.FoundNodes [(a, t "lbl", "src/A.hs")])
    @?= t "found: 1 nodes\n  A  lbl  src/A.hs\n"
  renderResult (QT.FoundNodes [(a, t "l1", "src/A.hs"), (b, t "l2", "src/B.hs")])
    @?= t "found: 2 nodes\n  A  l1  src/A.hs\n  B  l2  src/B.hs\n"
  -- 空結果只出首行,不輸出空字串
  renderResult (QT.FoundNodes [])   @?= t "found: 0 nodes\n"
  renderResult (QT.ReachableSet []) @?= t "reachable: 0 nodes\n"
  renderResult (QT.Ranking [])      @?= t "rank: 0 nodes\n"
  renderResult (QT.ReachableSet [(b, 2)]) @?= t "reachable: 1 nodes\n  2  B\n"
  renderResult (QT.PathResult (Just [a, b, c])) @?= t "path: 2 hops\n  A -> B -> C\n"
  renderResult (QT.PathResult (Just [a]))       @?= t "path: 0 hops\n  A\n"
  -- 驗收標準 4:不連通有明確固定輸出,且無明細行
  renderResult (QT.PathResult Nothing) @?= t "path: not connected\n"
  -- 防禦性:空路徑不可能來自 runQuery,渲染仍是全函數且不留空白明細行
  renderResult (QT.PathResult (Just [])) @?= t "path: 0 hops\n"
  renderResult (QT.Ranking [(a, 1, 2)]) @?= t "rank: 1 nodes\n  3  A  in=1 out=2\n"
  renderResult (QT.Ranking [(a, 1, 2), (b, 0, 3)])
    @?= t "rank: 2 nodes\n  3  A  in=1 out=2\n  3  B  in=0 out=3\n"
  -- 每行以 \n 結尾且全程不含 \r(binary 一致,不做平台換行轉換)
  let samples =
        [ QT.FoundNodes [(a, t "lbl", "src/A.hs")]
        , QT.FoundNodes []
        , QT.ReachableSet [(b, 2)]
        , QT.PathResult (Just [a, b, c])
        , QT.PathResult Nothing
        , QT.Ranking [(a, 1, 2)]
        ]
  forM_ samples $ \s -> do
    let out = renderResult s
    assertBool ("output ends with a newline: " <> show out)
      (T.pack "\n" `T.isSuffixOf` out)
    assertBool ("output has no carriage return: " <> show out)
      (not (T.pack "\r" `T.isInfixOf` out))
    -- 純函數:同一輸入兩次渲染逐字元相同
    renderResult s @?= out

-- export-query/F003 T7: 決定性與「只走依賴類邊」的總驗收
testQueryDeterminism :: TestTree
testQueryDeterminism = testGroup "test_query_determinism"
  [ testCase "(a) the same command twice yields the same result and text" $ do
      g <- loadFixture fixtureSrc
      let cmds =
            [ QT.FindNodes (T.pack "impl")
            , QT.Reachable (qid "S") QT.Forward
            , QT.ShortestPath (qid "S") (qid "T")
            , QT.RankConnectivity 100
            ]
      forM_ cmds $ \cmd -> do
        runQuery g cmd @?= runQuery g cmd
        renderResult (runQuery g cmd) @?= renderResult (runQuery g cmd)
  , testCase "(b) results do not depend on the node/link order in the file" $ do
      g <- loadFixture fixtureSrc
      rev <- loadFixture
        (fixtureJson (reverse fixtureNodes)
                     (reverse (fixtureDepLinks <> fixtureNoiseLinks)))
      probeAll rev @?= probeAll g
      map renderResult (probeAll rev) @?= map renderResult (probeAll g)
  , testCase "(c) structural and unknown relations do not affect any query" $ do
      g    <- loadFixture fixtureSrc
      lean <- loadFixture (fixtureJson fixtureNodes fixtureDepLinks)
      -- 驗收標準 6:contains 與未知 relation 邊整批刪除後,四種查詢全部不變
      -- (find 也不變——節點還在,規則 3)
      probeAll lean @?= probeAll g
      -- 差別只在未知 relation 的統計面(F004 印 stderr,不進查詢結果)
      queryGraphNotes g    @?= [(T.pack "foo", 1)]
      queryGraphNotes lean @?= []
  , testProperty "(d) random graphs keep the BFS invariants" $ property $ do
      (src, ids) <- forAll genQueryGraphSrc
      g <- case parseAt "gen.json" src of
        Right x  -> pure x
        Left err -> do
          annotate ("generated fixture failed to load: " <> show err)
          failure
      from <- forAll (Gen.element ids)
      to   <- forAll (Gen.element ids)
      let f   = QT.NodeId (T.pack from)
          tgt = QT.NodeId (T.pack to)
          fwd = reachableOf g f QT.Forward
      -- 同輸入同輸出
      runQuery g (QT.Reachable f QT.Forward)
        === runQuery g (QT.Reachable f QT.Forward)
      runQuery g (QT.ShortestPath f tgt) === runQuery g (QT.ShortestPath f tgt)
      -- 規則 5:距離恆 >= 1(起點不入結果);規則 4:依 (距離, id) 升序
      assert (all ((>= 1) . snd) fwd)
      sortOn (\(i, d) -> (d, i)) fwd === fwd
      -- 規則 6 的形狀不變式 + 最短性交叉驗證
      case pathOf g f tgt of
        Nothing -> pure ()
        Just p  -> do
          assert (not (null p))
          take 1 p === [f]
          take 1 (reverse p) === [tgt]
          assert
            (and [ v `elem` Map.findWithDefault [] u (QT.qgForward g)
                 | (u, v) <- zip p (drop 1 p) ])
          if f == tgt
            then length p === 1
            else lookup tgt fwd === Just (length p - 1)
  ]

-- | 隨機 fixture:3–8 個相異節點 id(取自固定字母表,含大小寫與長短以測字典序
-- 邊界)與 0–15 條隨機 relation 的邊。
genQueryGraphSrc :: Gen (String, [String])
genQueryGraphSrc = do
  k   <- Gen.int (Range.linear 3 8)
  ids <- take k <$> Gen.shuffle queryAlphabet
  ls  <- Gen.list (Range.linear 0 15) (genQueryLink ids)
  pure (fixtureJson (map nodeOf ids) ls, ids)
 where
  nodeOf i = jsonNode i (i <> ".Label") ("src/" <> i <> ".hs")

queryAlphabet :: [String]
queryAlphabet = ["a", "B", "cc", "D", "e", "Ff", "g", "H"]

genQueryLink :: [String] -> Gen String
genQueryLink ids =
  jsonLink <$> Gen.element ids <*> Gen.element ids <*> Gen.element queryRelPool

-- | 依賴類 + 結構類 + 一個未知類,確保分流路徑都被隨機走到。
queryRelPool :: [String]
queryRelPool =
  map T.unpack (dependencyRelations <> structuralRelations) <> ["foo"]

--------------------------------------------------------------------------------
-- export-query / F004 cli-wiring
--------------------------------------------------------------------------------

exportQueryF004Tests :: TestTree
exportQueryF004Tests = testGroup "export-query/F004 cli-wiring"
  -- T9 是「兩個唯讀標的手動實跑」,非自動化(D5 前例):實跑輸出與
  -- scan-graph.mjs 的對帳結果記在 F004 文檔的「實作備註」。
  [ testCliToplevelParse       -- T1
  , testExtractFlagsParse      -- T2
  , testExtractOptionsMapping  -- T3
  , testQueryFlagsParse        -- T4
  , testReportNoteLines        -- T5
  , testRunExtract             -- T6
  , testRunQuery               -- T7
  , testRunCommandDispatch     -- T8
  ]

--------------------------------------------------------------------------------
-- F004 測試輔助
--------------------------------------------------------------------------------

-- | 純解析:不碰 getArgs、不 exit(Extra.hs:151-155)。
parseCli :: [String] -> ParserResult Command
parseCli = execParserPure defaultPrefs cliParserInfo

expectParse :: [String] -> IO Command
expectParse argv = case parseCli argv of
  Success c -> pure c
  Failure f -> assertFailure
    ("expected a successful parse of " <> show argv <> ", got: "
      <> fst (renderFailure f "knot"))
  CompletionInvoked _ -> assertFailure ("unexpected completion: " <> show argv)

-- | 解析失敗時取出 (訊息, exit code)(Extra.hs:344)。
expectParseFailure :: [String] -> IO (String, ExitCode)
expectParseFailure argv = case parseCli argv of
  Failure f -> pure (renderFailure f "knot")
  Success c -> assertFailure
    ("expected a parse failure for " <> show argv <> ", got: " <> show c)
  CompletionInvoked _ -> assertFailure ("unexpected completion: " <> show argv)

expectExtractCmd :: [String] -> IO ExtractCmd
expectExtractCmd argv = do
  c <- expectParse argv
  case c of
    CmdExtract e -> pure e
    CmdQuery _   -> assertFailure ("expected CmdExtract for " <> show argv)

expectQueryCmd :: [String] -> IO QueryCmd
expectQueryCmd argv = do
  c <- expectParse argv
  case c of
    CmdQuery q   -> pure q
    CmdExtract _ -> assertFailure ("expected CmdQuery for " <> show argv)

-- | 八個欄位皆為預設的 'ExtractCmd'(測試各自只改需要的欄位)。
baseExtractCmd :: ExtractCmd
baseExtractCmd = ExtractCmd
  { ecPath         = "."
  , ecOutput       = Nothing
  , ecBackend      = Auto
  , ecModuleOnly   = False
  , ecIncludeTests = False
  , ecHieDir       = Nothing
  , ecStrict       = False
  , ecSummary      = Nothing
  }

-- | 八個欄位皆非預設的 'ExtractCmd'(對映斷言的來源)。
fullExtractCmd :: ExtractCmd
fullExtractCmd = ExtractCmd
  { ecPath         = "proj"
  , ecOutput       = Just "x.json"
  , ecBackend      = ImportsOnly
  , ecModuleOnly   = True
  , ecIncludeTests = True
  , ecHieDir       = Just "dist/hie"
  , ecStrict       = True
  , ecSummary      = Nothing
  }

-- | UTF-8、無換行轉換的暫存檔 Handle:注入執行層後讀回原樣 byte。
withNoteHandle :: FilePath -> (Handle -> IO a) -> IO a
withNoteHandle p act = withFile p WriteMode $ \h -> do
  hSetEncoding h utf8
  hSetNewlineMode h noNewlineTranslation
  act h

-- | 注入兩個 'Handle' 跑一次執行層,回 (結果, stdout, stderr)。
withCaptured :: FilePath -> (Handle -> Handle -> IO a) -> IO (a, Text, Text)
withCaptured dir act = do
  let outP = dir </> "capture-stdout.txt"
      errP = dir </> "capture-stderr.txt"
  r <- withNoteHandle outP (\hO -> withNoteHandle errP (\hE -> act hO hE))
  o <- readUtf8 outP
  e <- readUtf8 errP
  pure (r, o, e)

readUtf8 :: FilePath -> IO Text
readUtf8 p = TE.decodeUtf8 <$> BS.readFile p

writeUtf8 :: FilePath -> String -> IO ()
writeUtf8 p = BS.writeFile p . TE.encodeUtf8 . T.pack

hasText :: String -> Text -> Bool
hasText needle hay = T.pack needle `T.isInfixOf` hay

-- | 斷言 haystack 含全部片段(訊息把 haystack 原樣貼出來)。
assertHasAll :: String -> Text -> [String] -> IO ()
assertHasAll what hay needles = forM_ needles $ \n ->
  assertBool (what <> " should contain " <> show n <> ", got: " <> show hay)
    (hasText n hay)

-- | 在 @dir@ 下建一個「兩個 hs-source-dirs 各宣告同一個 module 名」的最小
-- 專案,回傳專案根目錄。走完真實管線後 @cgWarnings@ 必為 1 條
-- (@src/Knot/Graph.hs@ 的 collisionWarnings)。
mkCollisionProject :: FilePath -> IO FilePath
mkCollisionProject dir = do
  let projDir = dir </> "collide"
  createDirectoryIfMissing True (projDir </> "a")
  createDirectoryIfMissing True (projDir </> "b")
  writeUtf8 (projDir </> "collide.cabal") (unlines
    [ "cabal-version:      3.4"
    , "name:               collide"
    , "version:            0.1.0.0"
    , "build-type:         Simple"
    , ""
    , "library"
    , "    hs-source-dirs:   a"
    , "    exposed-modules:  Dup"
    , "    build-depends:    base"
    , "    default-language: GHC2024"
    , ""
    , "executable collide-exe"
    , "    hs-source-dirs:   b"
    , "    main-is:          Dup.hs"
    , "    build-depends:    base"
    , "    default-language: GHC2024"
    ])
  writeUtf8 (projDir </> "a" </> "Dup.hs") "module Dup where\n"
  writeUtf8 (projDir </> "b" </> "Dup.hs") "module Dup where\n"
  pure projDir

-- export-query/F004 T1: 頂層解析、--help、未知子命令與四個 CLI DTO
-- (驗收標準 4、5)
testCliToplevelParse :: TestTree
testCliToplevelParse = testCase "test_cli_toplevel_parse" $ do
  -- --help 走 stdout、exit 0(Extra.hs:202),訊息同時提到兩個子命令
  (helpMsg, helpCode) <- expectParseFailure ["--help"]
  helpCode @?= ExitSuccess
  assertHasAll "top-level help" (T.pack helpMsg) ["extract", "query"]
  -- 無子命令 / 未知子命令:exit 1(infoFailureCode,Builder.hs:518)
  (_, noneCode) <- expectParseFailure []
  noneCode @?= ExitFailure 1
  (bogusMsg, bogusCode) <- expectParseFailure ["bogus"]
  bogusCode @?= ExitFailure 1
  assertHasAll "unknown command message" (T.pack bogusMsg) ["bogus"]
  -- hsubparser 自動替每個子命令掛的 --help(Extra.hs:88-96)
  forM_ [["extract", "--help"], ["query", "--help"], ["query", "find", "--help"]]
    (\argv -> do
      (_, c) <- expectParseFailure argv
      assertBool (show argv <> " --help should exit 0") (c == ExitSuccess))
  -- 四個 CLI DTO 各建一值並比對 Eq
  let q = QueryCmd { qcFile = "g.json", qcCommand = QT.FindNodes (T.pack "Demo") }
  CmdExtract baseExtractCmd @?= CmdExtract baseExtractCmd
  CmdQuery q @?= CmdQuery q
  assertBool "CmdExtract /= CmdQuery" (CmdExtract baseExtractCmd /= CmdQuery q)
  assertBool "ExtractCmd Eq separates fields" (baseExtractCmd /= fullExtractCmd)
  qcFile q @?= "g.json"
  qcCommand q @?= QT.FindNodes (T.pack "Demo")
  [SummaryMeta, SummaryFacts, SummaryGraph] @?= [SummaryMeta, SummaryFacts, SummaryGraph]
  assertBool "SummaryMeta /= SummaryGraph" (SummaryMeta /= SummaryGraph)

-- export-query/F004 T2: extract 的位置參數與七個旗標(驗收標準 1、3、5)
testExtractFlagsParse :: TestTree
testExtractFlagsParse = testCase "test_extract_flags_parse" $ do
  -- 全預設
  d <- expectExtractCmd ["extract"]
  d @?= baseExtractCmd
  -- 全給定:八個欄位逐一等於預期值
  full <- expectExtractCmd
    [ "extract", "proj", "-o", "x.json", "--backend", "imports"
    , "--module-only", "--include-tests", "--hiedir", "dist/hie", "--strict"
    ]
  full @?= fullExtractCmd
  -- --backend 三個取值
  forM_ [("auto", Auto), ("imports", ImportsOnly), ("hiedb", HiedbOnly)]
    (\(s, v) -> do
      c <- expectExtractCmd ["extract", "--backend", s]
      ecBackend c @?= v)
  (bm, bc) <- expectParseFailure ["extract", "--backend", "bogus"]
  bc @?= ExitFailure 1
  assertHasAll "backend error" (T.pack bm) ["auto", "imports", "hiedb", "bogus"]
  -- --summary 三個取值(C6)
  forM_ [("meta", SummaryMeta), ("facts", SummaryFacts), ("graph", SummaryGraph)]
    (\(s, v) -> do
      c <- expectExtractCmd ["extract", "--summary", s]
      ecSummary c @?= Just v)
  (sm, sc) <- expectParseFailure ["extract", "--summary", "bogus"]
  sc @?= ExitFailure 1
  assertHasAll "summary error" (T.pack sm) ["meta", "facts", "graph", "bogus"]
  -- 缺參數與多餘位置參數
  (om, oc) <- expectParseFailure ["extract", "--output"]
  oc @?= ExitFailure 1
  assertHasAll "missing-argument error" (T.pack om) ["--output"]
  (_, xc) <- expectParseFailure ["extract", "a", "b"]
  xc @?= ExitFailure 1

-- export-query/F004 T3: 旗標 → 四個 Options DTO 的純對映(驗收標準 1)
testExtractOptionsMapping :: TestTree
testExtractOptionsMapping = testCase "test_extract_options_mapping" $ do
  let mo = toMetaOptions fullExtractCmd
      xo = toExtractOptions fullExtractCmd
      bo = toBuildOptions fullExtractCmd
      eo = toExportOptions fullExtractCmd
  root mo @?= "proj"
  includeTests mo @?= True
  hieDirOverride mo @?= Just "dist/hie"
  XT.rootDir xo @?= "proj"
  backendChoice xo @?= ImportsOnly
  hiedbExe xo @?= Nothing           -- 假設 A8:契約卡六旗標不含 --hiedb
  dbPath xo @?= Nothing             -- 假設 A8:契約卡六旗標不含 --db
  moduleOnly bo @?= True
  ET.rootDir eo @?= "proj"
  ET.outputPath eo @?= "x.json"
  ET.commitPolicy eo @?= AutoDetect -- 假設 A6:無對應旗標,固定 AutoDetect
  -- --output 未給時走 defaultOutputPath(釘住 F001 假設 A2 的分工)
  let noOut = fullExtractCmd { ecOutput = Nothing }
  ET.outputPath (toExportOptions noOut) @?= defaultOutputPath "proj"
  -- 三個 DTO 的路徑欄位同源
  [ root (toMetaOptions noOut)
    , XT.rootDir (toExtractOptions noOut)
    , ET.rootDir (toExportOptions noOut)
    ] @?= replicate 3 (ecPath noOut)

-- export-query/F004 T4: query 的 --graph 與四個子命令(驗收標準 2)
testQueryFlagsParse :: TestTree
testQueryFlagsParse = testCase "test_query_flags_parse" $ do
  q1 <- expectQueryCmd ["query", "find", "Demo"]
  qcFile q1 @?= "codegraph.json"          -- 假設 A3 的預設值
  qcCommand q1 @?= QT.FindNodes (T.pack "Demo")
  q2 <- expectQueryCmd ["query", "--graph", "out/g.json", "find", "x"]
  qcFile q2 @?= "out/g.json"              -- 假設 A3 的改道
  q3 <- expectQueryCmd ["query", "reachable", "A"]
  qcCommand q3 @?= QT.Reachable (qid "A") QT.Forward
  q4 <- expectQueryCmd ["query", "reachable", "A", "--reverse"]
  qcCommand q4 @?= QT.Reachable (qid "A") QT.Reverse
  q5 <- expectQueryCmd ["query", "path", "A", "B"]
  qcCommand q5 @?= QT.ShortestPath (qid "A") (qid "B")
  (_, pc) <- expectParseFailure ["query", "path", "A"]
  pc @?= ExitFailure 1
  q6 <- expectQueryCmd ["query", "rank"]
  qcCommand q6 @?= QT.RankConnectivity 10 -- 預設 10
  q7 <- expectQueryCmd ["query", "rank", "--top", "3"]
  qcCommand q7 @?= QT.RankConnectivity 3
  (_, tc) <- expectParseFailure ["query", "rank", "--top", "zzz"]
  tc @?= ExitFailure 1
  (fm, fc) <- expectParseFailure ["query", "find"]
  fc @?= ExitFailure 1
  assertHasAll "missing KEYWORD error" (T.pack fm) ["KEYWORD"]
  (_, xc) <- expectParseFailure ["query", "bogus"]
  xc @?= ExitFailure 1

-- export-query/F004 T5: 五條通道的純渲染 + emitNotes(驗收標準 8、9)
testReportNoteLines :: TestTree
testReportNoteLines = testCase "test_report_note_lines" $ do
  -- 通道 1:pmWarnings
  let pm1 = emptyMeta
        { pmWarnings = [MetaWarning "app/Main.hs" (T.pack "no module header")] }
  case metaNoteLines pm1 of
    [l] -> assertHasAll "meta line" l ["meta:", "app/Main.hs", "no module header"]
    other -> assertFailure ("expected one meta line, got: " <> show other)
  metaNoteLines emptyMeta @?= []
  -- 通道 2:erLevel / erReports / erWarnings
  let er1 = ExtractResult
        { erFacts    = []
        , erLevel    = ModuleLevel
        , erReports  =
            [ BackendReport (T.pack "hiedb") False (T.pack "not registered")
            , BackendReport (T.pack "import-scan") True T.empty
            ]
        , erWarnings = [ExtractWarning (T.pack "src/A.hs") (T.pack "unreadable")]
        }
  case extractNoteLines er1 of
    [lv, dg, wn] -> do
      assertHasAll "level line" lv ["extract: level", "ModuleLevel"]
      assertHasAll "degrade line" dg ["extract: backend", "hiedb", "not registered"]
      assertHasAll "warning line" wn ["extract:", "src/A.hs", "unreadable"]
      assertBool ("a used backend must not produce a line: " <> show [lv, dg, wn])
        (not (hasText "import-scan" (T.unlines [lv, dg, wn])))
    other -> assertFailure ("expected three extract lines, got: " <> show other)
  -- 只有 brUsed = True 的報告 → 零噪音行
  extractNoteLines er1
    { erReports  = [BackendReport (T.pack "import-scan") True T.empty]
    , erWarnings = []
    } @?= []
  extractNoteLines (ExtractResult [] ModuleLevel [] []) @?= []
  -- 通道 3(硬性要求):cgWarnings
  let cg1 = (graphWith [] [])
        { cgWarnings =
            [GraphWarning (T.pack "Main") (T.pack "declared in 2 source files")] }
  case graphNoteLines cg1 of
    [l] -> assertHasAll "graph line" l
      ["graph:", "Main", "declared in 2 source files"]
    other -> assertFailure ("expected one graph line, got: " <> show other)
  graphNoteLines (graphWith [] []) @?= []
  -- 通道 4:xrNotes
  case exportNoteLines (ExportReport "g.json" 1 2 [T.pack "dropped external edges: 3"]) of
    [l] -> assertHasAll "export line" l ["export:", "dropped external edges: 3"]
    other -> assertFailure ("expected one export line, got: " <> show other)
  exportNoteLines (ExportReport "g.json" 0 0 []) @?= []
  -- 通道 5:未知 relation
  let twoNodes = [jsonNode "A" "A" "src/A.hs", jsonNode "B" "B" "src/B.hs"]
  unknownG <- case parseAt "g.json" (fixtureJson twoNodes [jsonLink "A" "B" "foo"]) of
    Right g -> pure g
    Left e  -> assertFailure ("unknown-relation fixture should load: " <> show e)
  case queryNoteLines unknownG of
    [l] -> assertHasAll "query note line" l
      ["query: unknown relation", "foo", "1", "edges"]
    other -> assertFailure ("expected one query note line, got: " <> show other)
  cleanG <- case parseAt "g.json" (fixtureJson twoNodes [jsonLink "A" "B" "imports"]) of
    Right g -> pure g
    Left e  -> assertFailure ("clean fixture should load: " <> show e)
  queryNoteLines cleanG @?= []
  -- emitNotes:空清單零 byte,兩行各以 \n 結尾
  withExportDir "f004-notes" (\dir -> do
    (_, empty0, _) <- withCaptured dir (\hO _ -> emitNotes hO [])
    empty0 @?= T.empty
    (_, two, _) <- withCaptured dir
      (\hO _ -> emitNotes hO [T.pack "alpha", T.pack "beta"])
    two @?= T.pack "alpha\nbeta\n")

-- export-query/F004 T6: runExtractCmd 的四站管線與五條 stderr 通道
-- (驗收標準 3、7、8、9)
testRunExtract :: TestTree
testRunExtract = testCase "test_run_extract" $
  withExportDir "f004-extract" $ \dir -> do
    -- (a) 真實 fixture 走完匯出路徑
    let out = dir </> "cg.json"
        cmdA = baseExtractCmd { ecPath = graphFixture, ecOutput = Just out }
    (codeA, outA, errA) <- withCaptured dir (\hO hE -> runExtractCmd hO hE cmdA)
    codeA @?= ExitSuccess
    wroteFile <- doesFileExist out
    assertBool ("output file exists: " <> out) wroteFile
    loaded <- loadQueryGraph out
    case loaded of
      Right _ -> pure ()
      Left e  -> assertFailure ("exported graph should load back: " <> show e)
    assertHasAll "extract stdout" outA ["wrote ", out, " nodes, ", " edges"]
    assertHasAll "extract stderr" errA ["export:"]   -- 驗收標準 8:xrNotes
    -- (b) 硬性要求的端到端:自建同名 module 碰撞專案 → cgWarnings 走 stderr
    projDir <- mkCollisionProject dir
    let cmdB = baseExtractCmd { ecPath = projDir }   -- --output 未給 → 預設路徑
    (codeB, outB, errB) <- withCaptured dir (\hO hE -> runExtractCmd hO hE cmdB)
    codeB @?= ExitSuccess
    assertHasAll "collision warning on stderr" errB
      ["graph:", "Dup", "disambiguated", "a/Dup.hs", "b/Dup.hs"]
    -- 預設輸出路徑 = <PATH>/codegraph.json(F001 假設 A2 的分工)
    defaultWrote <- doesFileExist (defaultOutputPath projDir)
    assertBool ("default output path was used: " <> defaultOutputPath projDir)
      defaultWrote
    assertHasAll "default-path stdout" outB [defaultOutputPath projDir]
    -- 驗收標準 7:同一次輸入,--strict 把跳檔轉成 exit 1
    (codeS, _, errS) <- withCaptured dir
      (\hO hE -> runExtractCmd hO hE cmdB { ecStrict = True })
    codeS @?= ExitFailure 1
    assertHasAll "strict stderr" errS ["strict:", "graph:"]
    -- (c) 三個 --summary 模式逐字元等於既有 render 函式,且都不產出 codegraph.json
    pm <- loadProjectMeta (defOpts graphFixture)
    er <- extract ((extOpts Auto) { XT.rootDir = graphFixture }) pm
    let cg = buildGraph defBuildOpts pm er
        summaryOut = dir </> "summary-should-not-exist.json"
        summaryCmd m = baseExtractCmd
          { ecPath = graphFixture, ecOutput = Just summaryOut, ecSummary = Just m }
    forM_ [ (SummaryMeta,  renderMetaSummary pm)
          , (SummaryFacts, renderFactSummary er)
          , (SummaryGraph, renderGraphSummary cg)
          ] (\(mode, expected) -> do
      (codeM, outM, _) <- withCaptured dir
        (\hO hE -> runExtractCmd hO hE (summaryCmd mode))
      codeM @?= ExitSuccess
      outM @?= expected
      leaked <- doesFileExist summaryOut
      assertBool (show mode <> " must not write codegraph.json") (not leaked))
    -- (d) 寫不出去的路徑 → IOException 收斂成 exit 1,不拋未捕捉例外
    let blocker = dir </> "blocker"
    writeUtf8 blocker "not a directory\n"
    (codeD, _, errD) <- withCaptured dir (\hO hE -> runExtractCmd hO hE
      baseExtractCmd { ecPath = graphFixture, ecOutput = Just (blocker </> "x.json") })
    codeD @?= ExitFailure 1
    assertHasAll "export failure stderr" errD ["export:"]

-- export-query/F004 T7: runQueryCmd 的載入、通道 5、端點提示與 exit code
-- (驗收標準 6、8)
testRunQuery :: TestTree
testRunQuery = testCase "test_run_query" $
  withExportDir "f004-query" $ \dir -> do
    let out = dir </> "cg.json"
    (code0, _, _) <- withCaptured dir (\hO hE -> runExtractCmd hO hE
      baseExtractCmd { ecPath = graphFixture, ecOutput = Just out })
    code0 @?= ExitSuccess
    loadedG <- loadQueryGraph out
    g <- case loadedG of
      Right x -> pure x
      Left e  -> assertFailure ("fixture graph should load: " <> show e)
    -- 命中:stdout 等於 renderResult,exit 0
    let findCmd = QueryCmd { qcFile = out, qcCommand = QT.FindNodes (T.pack "Demo") }
    (code1, out1, _) <- withCaptured dir (\hO hE -> runQueryCmd hO hE findCmd)
    code1 @?= ExitSuccess
    out1 @?= renderResult (runQuery g (qcCommand findCmd))
    assertBool ("a hit should list nodes: " <> show out1) (T.length out1 > 0)
    -- 查無結果:一樣 exit 0(驗收標準 6)
    let missCmd = QueryCmd { qcFile = out, qcCommand = QT.FindNodes (T.pack "zzz") }
    (code2, out2, _) <- withCaptured dir (\hO hE -> runQueryCmd hO hE missCmd)
    code2 @?= ExitSuccess
    out2 @?= renderResult (runQuery g (qcCommand missCmd))
    -- LoadFileMissing → exit 1,訊息含路徑
    let gone = dir </> "nope.json"
    (code3, _, err3) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = gone, qcCommand = QT.RankConnectivity 3 })
    code3 @?= ExitFailure 1
    assertHasAll "missing-file stderr" err3 ["query:", takeFileName gone]
    -- LoadParseError → exit 1,訊息指出問題
    let badP = dir </> "bad.json"
    writeUtf8 badP "{"
    (code4, _, err4) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = badP, qcCommand = QT.RankConnectivity 3 })
    code4 @?= ExitFailure 1
    assertHasAll "parse-error stderr" err4 ["query:", takeFileName badP]
    -- LoadSchemaError(缺 nodes)→ exit 1
    let schemaP = dir </> "schema.json"
    writeUtf8 schemaP "{\"directed\":true,\"links\":[]}"
    (code5, _, err5) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = schemaP, qcCommand = QT.RankConnectivity 3 })
    code5 @?= ExitFailure 1
    assertHasAll "schema-error stderr" err5 ["query:", "nodes"]
    -- 未知 relation:exit 0,但 stderr 有通道 5 的提示(驗收標準 8)
    let relP = dir </> "rel.json"
        twoNodes = [jsonNode "A" "A" "src/A.hs", jsonNode "B" "B" "src/B.hs"]
    writeUtf8 relP (fixtureJson twoNodes [jsonLink "A" "B" "foo"])
    (code6, _, err6) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = relP, qcCommand = QT.RankConnectivity 3 })
    code6 @?= ExitSuccess
    assertHasAll "unknown-relation stderr" err6
      ["query: unknown relation", "foo", "1", "edges"]
    -- 起點不存在:印提示但仍 exit 0(假設 A4)
    (code7, _, err7) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = out, qcCommand = QT.Reachable (qid "NoSuchNode") QT.Forward })
    code7 @?= ExitSuccess
    assertHasAll "node-not-found stderr" err7 ["query: node not found: NoSuchNode"]
    -- 回歸(階段二閘門):missingNodeLines 改走 queryGraphHasNode 後行為不變
    -- (a) ShortestPath 兩端都不存在 → 兩條提示,仍 exit 0
    (code7b, _, err7b) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = out
               , qcCommand = QT.ShortestPath (qid "NoSuchFrom") (qid "NoSuchTo") })
    code7b @?= ExitSuccess
    assertHasAll "both-endpoints-missing stderr" err7b
      ["query: node not found: NoSuchFrom", "query: node not found: NoSuchTo"]
    -- (b) 只被結構類邊(contains)連到的節點__不__該被判為不存在(規則 3):
    --     它不在依賴鄰接表裡,但 queryGraphHasNode 回 True → 零提示、exit 0
    let structP = dir </> "structural.json"
        sNodes = [ jsonNode "A" "A" "src/A.hs"
                 , jsonNode "B" "B" "src/B.hs"
                 , jsonNode "Lonely" "Lonely" "src/Lonely.hs"
                 ]
    writeUtf8 structP
      (fixtureJson sNodes [jsonLink "A" "B" "imports", jsonLink "A" "Lonely" "contains"])
    (code7c, _, err7c) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = structP
               , qcCommand = QT.Reachable (qid "Lonely") QT.Forward })
    code7c @?= ExitSuccess
    assertBool ("a structural-only node exists: " <> show err7c)
      (not (hasText "node not found" err7c))
    -- 兩端都存在但不連通:零提示、空結果、exit 0
    (code8, out8, err8) <- withCaptured dir (\hO hE -> runQueryCmd hO hE
      QueryCmd { qcFile = relP, qcCommand = QT.ShortestPath (qid "A") (qid "B") })
    code8 @?= ExitSuccess
    assertBool ("existing endpoints need no hint: " <> show err8)
      (not (hasText "node not found" err8))
    out8 @?= renderResult (QT.PathResult Nothing)

-- export-query/F004 T8: runCommand 分派與解析層↔執行層的接縫
-- (驗收標準 4、5)。app/Main.hs 因模組名衝突不進 test-suite,其
-- 「只剩 execParser / runCommand / exitWith」以人工複核。
testRunCommandDispatch :: TestTree
testRunCommandDispatch = testCase "test_run_command_dispatch" $
  withExportDir "f004-dispatch" $ \dir -> do
    let out = dir </> "cg.json"
    -- execParserPure 解出的 Command 直接餵給 runCommand,走完一次 extract
    ec <- expectParse ["extract", graphFixture, "-o", out]
    (code1, out1, _) <- withCaptured dir (\hO hE -> runCommand hO hE ec)
    code1 @?= ExitSuccess
    wrote <- doesFileExist out
    assertBool "CmdExtract dispatches to the export path" wrote
    assertHasAll "dispatch extract stdout" out1 ["wrote "]
    -- 再走完一次 query;查詢路徑不產生任何檔案
    qc <- expectParse ["query", "--graph", out, "find", "Demo"]
    (code2, out2, _) <- withCaptured dir (\hO hE -> runCommand hO hE qc)
    code2 @?= ExitSuccess
    assertHasAll "dispatch query stdout" out2 ["found"]
    strayed <- doesFileExist (dir </> "codegraph.json")
    assertBool "CmdQuery dispatches to the query path (no file written)"
      (not strayed)
    -- 兩條路徑的 stdout 明顯不同(分派沒有走錯)
    assertBool "extract and query stdout differ" (out1 /= out2)
    -- 驗收標準 4、5:--help exit 0、未知子命令 exit 1
    (_, helpCode) <- expectParseFailure ["--help"]
    helpCode @?= ExitSuccess
    (_, unknownCode) <- expectParseFailure ["nope"]
    unknownCode @?= ExitFailure 1

