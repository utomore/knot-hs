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
import Data.Char (isAlphaNum, isDigit, isSpace)
import Data.Containers.ListUtils (nubOrd)
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, intercalate, isInfixOf, isPrefixOf, sort, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
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

-- extraction/F004 T10:驗收標準 3 的「逐筆對帳」要獨立開 DB 查 refs 表。
import Database.SQLite.Simple (Query (..), query_, withConnection)

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
  , defaultOutputPath
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
import Knot.Extract.HiedbFacts
  ( SourceDecls (..)
  , declKindOf
  , hiedbBackend
  , isGeneratedName
  , parseOcc
  , pickFromDecl
  , readIndexFacts
  , resolveModuleSource
  , unavailableSourceDecls
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
import Knot.Graph.NodeMint
  ( declNodeIndex
  , disambiguate
  , mintDeclId
  , mintInstanceId
  , mintModuleId
  , mintNodes
  , moduleFiles
  , moduleOfFile
  )
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
  , extractionF004Tests mHiedb
  , graphCoreF001Tests
  , graphCoreF002Tests
  , graphCoreF003Tests
  , exportQueryF001Tests
  , exportQueryF002Tests
  , exportQueryF003Tests
  , exportQueryF004Tests
  , globalE003Tests
  , globalE001Tests
  , globalE004Tests
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
      False False "src/Z/Late.hs" 21
  , FactDecl (qn "A.Early" "helper" ValueNs) ValueDecl False "src/A/Early.hs" 4
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
  case FactDecl q DataDecl False "src/A/Early.hs" 4 of
    f@FactDecl{} -> do
      fdName f @?= q
      fdKind f @?= DataDecl
      fdGenerated f @?= False
      fdFile f @?= "src/A/Early.hs"
      fdLine f @?= 4
  case FactRef modName (Just q) (qn "Z.Late" "go" ValueNs) True False "src/A/Early.hs" 5 of
    f@FactRef{} -> do
      frFromModule f @?= modName
      frFromDecl f   @?= Just q
      frTarget f     @?= qn "Z.Late" "go" ValueNs
      frGenerated f  @?= True
      frTargetGenerated f @?= False
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

-- extraction T3: 規則 1——後端**只處理** sfIncluded = True 的檔;其餘欄位原樣
--
-- G-B001 起調度層不再預先窄化:契約原文是「只**處理** sfIncluded = True 的
-- 檔案」,不是「只收到」。預先窄化會抹掉「這份 .hie 屬於一個被排除的檔案」
-- 這個事實,讓 hiedb-facts 的 hs_src 比對落空後誤退回 module 名猜測。
-- 因此本測試分兩半:後端收到完整清單、但產出的事實不得碰被排除的檔。
testIncludedScope :: TestTree
testIncludedScope = testCase "test_included_scope" $ do
  pm <- loadProjectMeta (defOpts compsFixture)
  let excluded = [sfPath sf | sf <- pmSources pm, not (sfIncluded sf)]
  assertBool "fixture must contain excluded files" (not (null excluded))
  -- 前半:後端拿到的是完整清單(含被排除者),其餘欄位原樣
  cref <- newIORef Nothing
  _ <- runBackends [capturingBackend cref importScanName] (extOpts Auto) pm
  seen <- readIORef cref
  case seen of
    Nothing   -> assertFailure "backend never received a ProjectMeta"
    Just pmIn -> do
      map sfPath (pmSources pmIn) @?= map sfPath (pmSources pm)
      pmPackages pmIn @?= pmPackages pm
      pmHie pmIn      @?= pmHie pm
      pmWarnings pmIn @?= pmWarnings pm
  -- 後半:規則 1 本體——import-scan 產出的事實不得提及任何被排除的檔
  (facts, _) <- bRun importScanBackend
                  ((extOpts Auto) { XT.rootDir = compsFixture }) pm
  let touched = nubOrd ([f | FactModule{fmFile = f} <- facts]
                          <> [f | FactImport{fiFile = f} <- facts])
      leaked  = [p | p <- touched, p `elem` excluded]
  assertBool ("import-scan must not process excluded files, leaked: " <> show leaked)
    (null leaked)
  assertBool "import-scan should still process the included ones" (not (null touched))

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
      <*> Gen.bool <*> genPath <*> genLine
  , FactRef <$> genMod <*> Gen.maybe genQual <*> genQual <*> Gen.bool <*> Gen.bool
      <*> genPath <*> genLine
  , FactInstance <$> genQual <*> genOcc <*> genPath <*> genLine
  ]
 where
  genMod  = ModuleName <$> genOcc
  genOcc  = T.pack <$> Gen.string (Range.linear 1 4) Gen.alpha
  genPath = Gen.string (Range.linear 1 6) Gen.alpha
  genLine = Gen.int (Range.linear 1 200)
  genQual = QualName <$> genMod <*> genOcc
              <*> Gen.element [ValueNs, DataConNs, TypeNs, FieldNs]

-- extraction T7: 進入點與註冊表
-- (F002 起註冊表已填入 import-scan、F004 起併排註冊 hiedb;本測試驗證
--  extract 確實委派給 registeredBackends——每個註冊後端剛好一筆報告、
--  能力等級由實際跑的後端決定。projFixture 沒有 .hie,故 hiedb 恆探測不過,
--  等級停在 ModuleLevel 且不會在版控樹裡建 .knot/。
--  空註冊表語意本身已隨 F002 消失,見 F002「實作備註」)
testExtractEntryEmptyRegistry :: TestTree
testExtractEntryEmptyRegistry = testCase "test_extract_entry_registry" $ do
  pm <- loadProjectMeta (defOpts projFixture)
  forM_ [Auto, ImportsOnly, HiedbOnly] $ \c -> do
    r <- extract (extOpts c) pm
    map brBackend (erReports r) @?= [importScanName, hiedbName]
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
      -- 原本直接用 fiLine / fiTo 等部分選擇器(G-E002)。改走 'importOf' 後
      -- 「第一筆之後全是 FactImport」由隱含假設變成顯式斷言:長度不變即證明。
      let parsed = mapMaybe importOf imps
      length parsed @?= length imps
      map (\(_, to, _, l) -> (l, to)) parsed @?= comboImports
      forM_ parsed $ \(from, _, fp, _) -> do
        from @?= mn "Demo.Main"
        fp   @?= path
      let ls = [l | (_, _, _, l) <- parsed]
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
          got = [(l, to) | Just (_, to, _, l) <- map importOf facts]
      warns === []
      [m | Just (_, m) <- map moduleOf facts] === [mn "Gen.Root"]
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
       Nothing -> [testCase (hiedbSkipLabel (length hiedbGatedTests)) (pure ())]

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
--
-- extraction/F004 沿用同一個開關(委派決策 D7:只__加掛__、不另建一套),
-- 故總數是兩個 feature 的受管轄節點數相加。
hiedbGatedCount :: Int
hiedbGatedCount = length hiedbGatedTests + length hiedbGatedF004Tests

-- | 測試啟動時印的一行:有 hiedb 就說用哪支,沒有就說明原因與跳過數。
hiedbNotice :: Maybe FilePath -> Int -> String
hiedbNotice (Just p) _ = "[hiedb] using " <> p
hiedbNotice Nothing n =
  "[skip] extraction/F003 hiedb-driver + F004 hiedb-facts: \
  \hiedb executable not found on PATH; " <> show n <> " tests skipped"

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
  -- 常數與實際受管轄的節點數對帳(F003 五個 + F004 加掛的,D7 同一個開關)
  hiedbGatedCount @?= length hiedbGatedTests + length hiedbGatedF004Tests
  assertBool "F004 must hang its gated tests on the same switch"
    (not (null hiedbGatedF004Tests))

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
      -- 暫代組裝(F004 已有真的 'hiedbBackend',這裡刻意用替身:
      -- bRun 被呼叫即代表降級判斷錯了)
      stubHiedbBackend = Backend
        { bName  = hiedbName
        , bLevel = DeclLevel
        , bProbe = probeHiedb
        , bRun   = \_ _ -> writeIORef ranRef True >> pure ([], [])
        }
      opts = (extOpts Auto)
        { XT.rootDir = projFixture, XT.hiedbExe = Just missing }
  pm <- loadProjectMeta (defOpts projFixture)
  res <- runBackends [importScanBackend, stubHiedbBackend] opts pm
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
-- extraction/F004 hiedb-facts
--------------------------------------------------------------------------------

extractionF004Tests :: Maybe FilePath -> TestTree
extractionF004Tests mHiedb = testGroup "extraction/F004 hiedb-facts" $
  [ testNamespaceAndGenerated  -- T1
  , testHiedbDbFlags           -- T2
  , testHiedbFactsSmoke        -- T3
  , testParseOcc               -- T4
  , testResolveModuleSource    -- T5
  , testPickFromDecl           -- T6
  , testHiedbBackendRegistered -- T8(不需 hiedb 的部分)
  , testHiedbFactsFixture      -- T9
  , testGeneratedNameJudgement -- G-E003 T2(純函數面)
  ]
  ++ case mHiedb of
       Just _  -> hiedbGatedF004Tests
       Nothing -> [testCase (hiedbSkipLabel (length hiedbGatedF004Tests)) (pure ())]

-- | F004 加掛到 D7 同一個開關上的節點(需要 hiedb 執行檔才跑得動)。
hiedbGatedF004Tests :: [TestTree]
hiedbGatedF004Tests =
  [ testReadIndexFacts         -- T7
  , testHiedbBackendLive       -- T8(需 hiedb 的部分)
  , testGeneratedFlagsFixture  -- G-E003 T2(索引面)
  , testHiedbFactsAcceptance   -- T10
  , testHiedbFactsSelfcheck    -- T11
  ]

-- | 安全取出 'FactModule' 的欄位(理由同 'declOf';G-E002)。
moduleOf :: Fact -> Maybe (FilePath, ModuleName)
moduleOf (FactModule f m) = Just (f, m)
moduleOf _                = Nothing

-- | 安全取出 'FactImport' 的欄位(理由同 'declOf';G-E002)。
importOf :: Fact -> Maybe (ModuleName, ModuleName, FilePath, Int)
importOf (FactImport from to f l) = Just (from, to, f, l)
importOf _                        = Nothing

-- | 安全取出 'FactDecl' 的欄位:以位置 pattern 承接,避免對 sum type 用
-- 部分選擇器(@-Wincomplete-record-selectors@)。
--
-- 這一家四個('moduleOf' \/ 'importOf' \/ 'declOf' \/ 'refOf')是本檔取
-- 'Fact' 欄位的**唯一**手段:@fiLine@ \/ @fmModule@ 等選擇器對 sum type 是
-- 部分函式,直接用會在全量重建時噴 @-Wincomplete-record-selectors@,而增量
-- 建置不重印警告,退化會靜悄悄地長回來(G-E002)。
declOf :: Fact -> Maybe (QualName, DeclKind, Bool, FilePath, Int)
declOf (FactDecl n k g f l) = Just (n, k, g, f, l)
declOf _                    = Nothing

-- | 安全取出 'FactRef' 的欄位(理由同 'declOf')。
refOf :: Fact -> Maybe (ModuleName, Maybe QualName, QualName, Bool, Bool, FilePath, Int)
refOf (FactRef m d t g tg f l) = Just (m, d, t, g, tg, f, l)
refOf _                        = Nothing

isImportFact :: Fact -> Bool
isImportFact FactImport{} = True
isImportFact _            = False

modText :: ModuleName -> Text
modText (ModuleName t) = t

-- | T5 用的最小 'SourceFile'(只有 @sfPath@ / @sfModule@ 影響對映)。
srcFile :: FilePath -> Maybe ModuleName -> SourceFile
srcFile p m = SourceFile
  { sfPath = p, sfModule = m, sfOwners = [], sfIncluded = True }

-- extraction/F004 T1: 前置 1 的契約更新(NameSpace 四值、FactRef.frGenerated)
testNamespaceAndGenerated :: TestTree
testNamespaceAndGenerated = testCase "test_namespace_and_generated" $ do
  -- 四個建構子皆可構造且互異;Ord 序即契約序(graph-core 的鑄造規則依賴它)
  let allNs = [ValueNs, DataConNs, TypeNs, FieldNs]
  length (nubOrd allNs) @?= 4
  sort [FieldNs, TypeNs, DataConNs, ValueNs] @?= allNs
  -- FactRef 可帶 frGenerated 且欄位取值正確(位置 pattern,見 'refOf')
  let tgt = qn "Demo.Core" "greet" ValueNs
      src = Just (qn "Demo.App" "run" ValueNs)
      fr g = FactRef (mn "Demo.App") src tgt g False "src/Demo/App.hs" 8
  refOf (fr True)  @?= Just (mn "Demo.App", src, tgt, True,  False, "src/Demo/App.hs", 8)
  refOf (fr False) @?= Just (mn "Demo.App", src, tgt, False, False, "src/Demo/App.hs", 8)
  -- 只差 frGenerated 的兩筆分得開(釘住規則 8 的排序依據含這個欄位)
  assertBool "frGenerated separates by Eq"  (fr False /= fr True)
  compare (fr False) (fr True) @?= LT
  -- G-E003:frTargetGenerated 同樣入 Eq / Ord(全序不因新欄位失效)
  let frt tg = FactRef (mn "Demo.App") src tgt False tg "src/Demo/App.hs" 8
  assertBool "frTargetGenerated separates by Eq" (frt False /= frt True)
  compare (frt False) (frt True) @?= LT
  -- fdGenerated 亦然
  let fd g = FactDecl tgt ValueDecl g "src/Demo/Core.hs" 12
  assertBool "fdGenerated separates by Eq" (fd False /= fd True)
  compare (fd False) (fd True) @?= LT
  -- declKindOf 的值域落在 DeclKind 內(四值全覆蓋,無 partial)
  map declKindOf allNs @?= [ValueDecl, DataDecl, DataDecl, ValueDecl]

-- G-E003 T2(純函數面):產生碼判準與它的降級行為
testGeneratedNameJudgement :: TestTree
testGeneratedNameJudgement = testCase "test_generated_name_judgement" $ do
  let hf  = T.pack "A.hie"
      idx = SourceDecls (Just (Map.singleton hf
              (Set.fromList [T.pack "v:greet", T.pack "t:Color"])))
  -- 有原始碼宣告 → 非產生碼
  isGeneratedName idx (Just hf) (T.pack "v:greet") @?= False
  isGeneratedName idx (Just hf) (T.pack "t:Color") @?= False
  -- 在 defs 卻不在 decls → 沒有人寫過那一行 → 產生碼
  isGeneratedName idx (Just hf) (T.pack "v:$fEqColor") @?= True
  -- 名字的 module 不在索引內(外部套件)或對映不唯一 → 恆 False
  -- (外部目標由 graph-core 規則 1 丟棄,不歸本旗標管)
  isGeneratedName idx Nothing (T.pack "v:$fShowInt") @?= False
  -- 該檔一筆 decls 都沒有 ⇒ 它的名字全都沒有原始碼宣告
  isGeneratedName idx (Just (T.pack "B.hie")) (T.pack "v:greet") @?= True
  -- decls 索引不可用時的降級:一律非產生碼,**絕不誤殺**
  isGeneratedName unavailableSourceDecls (Just hf) (T.pack "v:$fEqColor") @?= False
  isGeneratedName unavailableSourceDecls (Just hf) (T.pack "v:greet")     @?= False
  isGeneratedName unavailableSourceDecls Nothing   (T.pack "v:$fEqColor") @?= False

-- G-E003 T2(索引面):對 fixture 的真實索引驗證兩個旗標
--
-- fixture @Demo.Core@ 的 @data Color = … deriving (Eq, Show)@ 產生
-- @$fEqColor@ / @$fShowColor@ 兩個字典;其餘名字都是手寫的。
testGeneratedFlagsFixture :: TestTree
testGeneratedFlagsFixture = testCase "test_generated_flags_fixture" $
  withHiedbScratch "ge003flags" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    h  <- expectRight =<< ensureIndex (hiedbOpts root) pm
    (facts, _) <- readIndexFacts h pm
    let decls = mapMaybe declOf facts
        refs  = mapMaybe refOf facts
        genOccs  = sort [ qnOcc q | (q, _, True,  _, _) <- decls ]
        handOccs =      [ qnOcc q | (q, _, False, _, _) <- decls ]
    -- deriving 字典恰好是那兩個,一個不多一個不少
    genOccs @?= sort [T.pack "$fEqColor", T.pack "$fShowColor"]
    -- 手寫的名字一個都沒被誤判
    forM_ ["greet", "Color", "Red", "cfgName"] $ \o ->
      assertBool ("hand-written decl wrongly flagged generated: " <> o)
        (T.pack o `elem` handOccs)
    -- ref 側:指向產生碼宣告的引用被標出,指向手寫名字的沒有
    let genTargets = nubOrd (sort [ qnOcc t | (_, _, t, _, True, _, _) <- refs ])
    assertBool ("expected refs to the deriving dictionaries, got: " <> show genTargets)
      (not (null genTargets))
    forM_ genTargets $ \o ->
      assertBool ("unexpected generated ref target: " <> show o)
        (o `elem` [T.pack "$fEqColor", T.pack "$fShowColor"])
    assertBool "refs to greet must not be flagged as generated targets"
      (not (any (\(_, _, t, _, tg, _, _) ->
                   qnOcc t == T.pack "greet" && tg) refs))
    -- 目標 module 不在索引內(base / text 等外部套件)→ 旗標恆 False
    let internal = [mn "Demo.Core", mn "Demo.App"]
    assertBool "external ref targets must never be flagged generated"
      (not (any (\(_, _, t, _, tg, _, _) ->
                   qnModule t `notElem` internal && tg) refs))

-- extraction/F004 T2: 前置 2——CLI --hiedb / --db 補接(缺陷修補)
testHiedbDbFlags :: TestTree
testHiedbDbFlags = testCase "test_hiedb_db_flags" $ do
  -- 不給 → Nothing(其餘八個欄位維持預設)
  d <- expectExtractCmd ["extract"]
  d @?= baseExtractCmd
  ecHiedbExe d @?= Nothing
  ecDbPath d   @?= Nothing
  -- 給了 → 逐字進 ExtractCmd,且只動這兩個欄位
  c <- expectExtractCmd
    ["extract", "--hiedb", "C:/tools/hiedb.exe", "--db", "/tmp/x.sqlite"]
  ecHiedbExe c @?= Just "C:/tools/hiedb.exe"
  ecDbPath c   @?= Just "/tmp/x.sqlite"
  c @?= baseExtractCmd
    { ecHiedbExe = Just "C:/tools/hiedb.exe", ecDbPath = Just "/tmp/x.sqlite" }
  -- toExtractOptions 逐字透傳(釘住「寫死 Nothing」的缺陷已修)
  let xo = toExtractOptions c
  XT.hiedbExe xo @?= Just "C:/tools/hiedb.exe"
  XT.dbPath xo   @?= Just "/tmp/x.sqlite"
  let xo0 = toExtractOptions baseExtractCmd
  XT.hiedbExe xo0 @?= Nothing
  XT.dbPath xo0   @?= Nothing
  -- 缺參數 → exit 1 且訊息點名旗標
  forM_ ["--hiedb", "--db"] $ \flag -> do
    (msg, code) <- expectParseFailure ["extract", flag]
    code @?= ExitFailure 1
    assertHasAll ("missing " <> flag <> " argument") (T.pack msg) [flag]
  -- --help 列出兩個旗標(system.md CLI 頂層契約的落地證明)
  (helpMsg, helpCode) <- expectParseFailure ["extract", "--help"]
  helpCode @?= ExitSuccess
  assertHasAll "extract help" (T.pack helpMsg) ["--hiedb", "--db"]

-- extraction/F004 T3: 後端值與註冊表(不需 hiedb;探測不過也留得下報告)
testHiedbFactsSmoke :: TestTree
testHiedbFactsSmoke = testCase "test_hiedb_facts_smoke" $ do
  bName hiedbBackend  @?= hiedbName
  bLevel hiedbBackend @?= DeclLevel
  -- 註冊表併排註冊,順序為 [import-scan, hiedb](規則 8:順序即報告序)
  pm <- loadProjectMeta (defOpts projFixture)
  r <- extract (extOpts Auto) pm
  map brBackend (erReports r) @?= [importScanName, hiedbName]
  -- HiedbOnly 時 import-scan 未選中,hiedb 那筆仍在
  rH <- extract (extOpts HiedbOnly) pm
  scanRep <- reportFor importScanName rH
  brUsed scanRep @?= False
  _ <- reportFor hiedbName rH
  pure ()

-- extraction/F004 T4: occ 前綴判讀與 DeclKind 粗推(純函數)
testParseOcc :: TestTree
testParseOcc = testCase "test_parse_occ" $ do
  let p = parseOcc . T.pack
      ok o ns = Just (T.pack o, ns)
  p "v:foo"           @?= ok "foo" ValueNs
  p "c:Red"           @?= ok "Red" DataConNs
  p "t:Color"         @?= ok "Color" TypeNs
  p "fConfig:cfgName" @?= ok "cfgName" FieldNs     -- 父型別丟棄(假設 A9)
  p "f:x"             @?= ok "x" FieldNs           -- 空父型別亦屬 f 前綴
  -- 含冒號的運算子:切在第一個冒號
  p "c::|"            @?= ok ":|" DataConNs
  p "v:.:+:"          @?= ok ".:+:" ValueNs
  p "v:"              @?= ok "" ValueNs
  -- 不認得的前綴 → Nothing(假設 A2:含型別變數 z:)
  forM_ ["z:a", "foo", "", "q:x", "vv:x", ":x"] $ \s ->
    assertBool ("expected Nothing for " <> show s) (p s == Nothing)
  -- declKindOf 四值對映
  declKindOf ValueNs   @?= ValueDecl
  declKindOf FieldNs   @?= ValueDecl
  declKindOf DataConNs @?= DataDecl
  declKindOf TypeNs    @?= DataDecl

-- extraction/F004 T5: 絕對 hs_src → repo 相對 sfPath 的兩層對映(純函數)
testResolveModuleSource :: TestTree
testResolveModuleSource = testCase "test_resolve_module_source" $ do
  let core = srcFile "src/Demo/Core.hs" (Just (mn "Demo.Core"))
      app  = srcFile "src/Demo/App.hs" (Just (mn "Demo.App"))
      shortCore = srcFile "Core.hs" (Just (mn "Core"))
      hs = Just . T.pack
  -- 反斜線正規化 + 後綴比對,回傳 sfPath 原文
  resolveModuleSource [core, app] (mn "Demo.Core")
    (hs "C:\\proj\\src\\Demo\\Core.hs") @?= Just "src/Demo/Core.hs"
  resolveModuleSource [core, app] (mn "Demo.Core")
    (hs "/home/u/proj/src/Demo/Core.hs") @?= Just "src/Demo/Core.hs"
  -- 同時有短長兩個候選 → 取最長(與清單順序無關)
  forM_ [[shortCore, core], [core, shortCore]] $ \sfs ->
    resolveModuleSource sfs (mn "Demo.Core")
      (hs "C:\\proj\\src\\Demo\\Core.hs") @?= Just "src/Demo/Core.hs"
  -- 邊界必須落在 '/':部分片段不命中,退路也不中 → Nothing
  resolveModuleSource [srcFile "emo/Core.hs" Nothing] (mn "Demo.Core")
    (hs "C:\\proj\\src\\Demo\\Core.hs") @?= Nothing
  -- 整串相等也算命中
  resolveModuleSource [core] (mn "Demo.Core") (hs "src/Demo/Core.hs")
    @?= Just "src/Demo/Core.hs"
  -- hs_src = NULL → 退回 sfModule 唯一比對
  resolveModuleSource [core, app] (mn "Demo.App") Nothing @?= Just "src/Demo/App.hs"
  -- 後綴落空時也走退路
  resolveModuleSource [core, app] (mn "Demo.App") (hs "D:\\other\\Nope.hs")
    @?= Just "src/Demo/App.hs"
  -- 兩筆同名(兩個 Main)→ 落空
  let mainA = srcFile "app/Main.hs" (Just (mn "Main"))
      mainB = srcFile "exe/Main.hs" (Just (mn "Main"))
  resolveModuleSource [mainA, mainB] (mn "Main") Nothing @?= Nothing
  -- 零筆 → 落空
  resolveModuleSource [core] (mn "Nowhere") Nothing @?= Nothing
  resolveModuleSource [] (mn "Demo.Core") (hs "C:\\proj\\src\\Demo\\Core.hs") @?= Nothing
  -- G-B001:hs_src 命中「存在於 pmSources 但被排除」的檔 → 整批跳過,
  -- **不得**退回 module 名猜測(那會把 test 宣告掛到 executable 的檔案上)
  let appMain  = srcFile "app/Main.hs" (Just (mn "Main"))
      testMain = (srcFile "test/Main.hs" (Just (mn "Main"))) { sfIncluded = False }
      testSpec = (srcFile "test/Spec.hs" (Just (mn "Spec"))) { sfIncluded = False }
  -- 缺陷 1:同名 Main——test-suite 的 .hie 蓋掉 executable 的
  resolveModuleSource [appMain, testMain] (mn "Main")
    (hs "C:\\proj\\test\\Main.hs") @?= Nothing
  -- 納入的那一份仍要正常對映(修復不得誤傷)
  resolveModuleSource [appMain, testMain] (mn "Main")
    (hs "C:\\proj\\app\\Main.hs") @?= Just "app/Main.hs"
  -- 缺陷 2:不撞名的 test module 同樣不得進圖
  resolveModuleSource [appMain, testSpec] (mn "Spec")
    (hs "C:\\proj\\test\\Spec.hs") @?= Nothing
  -- 退路的母體同步限定為納入者:被排除的檔不得經 module 名被選中
  resolveModuleSource [appMain, testSpec] (mn "Spec") Nothing @?= Nothing

-- extraction/F004 T6: fromDecl 最內層挑選與破雷(抽取規則 4)
testPickFromDecl :: TestTree
testPickFromDecl = testCase "test_pick_from_decl" $ do
  pickFromDecl [] @?= Nothing
  -- 兩層巢狀 → 取內層
  let outer = ((1, 1, 20, 1), qn "M" "X" TypeNs)
      inner = ((3, 1, 5, 10), qn "M" "go" ValueNs)
  pickFromDecl [outer, inner] @?= Just (snd inner)
  pickFromDecl [inner, outer] @?= Just (snd inner)
  -- 三層巢狀 → 取最內
  let mid = ((2, 1, 10, 1), qn "M" "mid" ValueNs)
  pickFromDecl [outer, mid, inner] @?= Just (snd inner)
  pickFromDecl [inner, mid, outer] @?= Just (snd inner)
  -- 同 span 的 c:QueryNode 與 t:QueryNode(C3 實測情形)→ 依建構子序取
  -- DataConNs 那個,且與輸入順序無關
  let dc = ((4, 1, 4, 20), qn "M" "QueryNode" DataConNs)
      ty = ((4, 1, 4, 20), qn "M" "QueryNode" TypeNs)
  pickFromDecl [dc, ty] @?= Just (snd dc)
  pickFromDecl [ty, dc] @?= Just (snd dc)
  -- 同 span 同 namespace → 依 occ 字典序
  let occA = ((4, 1, 4, 20), qn "M" "aaa" ValueNs)
      occB = ((4, 1, 4, 20), qn "M" "bbb" ValueNs)
  pickFromDecl [occB, occA] @?= Just (snd occA)
  -- 起點相同、終點不同 → 取終點較早者(span 較小)
  let wide   = ((7, 1, 30, 1), qn "M" "wide" ValueNs)
      narrow = ((7, 1, 9, 1), qn "M" "narrow" ValueNs)
  pickFromDecl [wide, narrow] @?= Just (snd narrow)
  -- 同列不同欄的起點 → 取較晚起點(較內層)
  let colOuter = ((7, 1, 9, 1), qn "M" "outer" ValueNs)
      colInner = ((7, 5, 9, 1), qn "M" "inner" ValueNs)
  pickFromDecl [colOuter, colInner] @?= Just (snd colInner)

-- extraction/F004 T9: fixture 的形狀與四 namespace / 產生碼樣本的來源
testHiedbFactsFixture :: TestTree
testHiedbFactsFixture = testCase "test_hiedb_facts_fixture" $ do
  -- 恰好兩個 .hs 與兩個 .hie(釘住 F003 的 IndexStats 2 0 1 不被本次擴充破壞)
  hs  <- listFilesRec (hiedbFixture </> "src")
  hie <- listFilesRec (hiedbFixture </> ".hie")
  sort (map takeFileName hs)  @?= ["App.hs", "Core.hs"]
  sort (map takeFileName hie) @?= ["App.hie", "Core.hie"]
  -- .hie 為真實檔且與本 GHC 同版(升版時這裡先紅,指向重產指令)
  forM_ hie $ \p -> do
    bytes <- BS.readFile p
    assertBool ("empty .hie: " <> p) (BS.length bytes > 0)
    BS.take 3 bytes @?= TE.encodeUtf8 (T.pack "HIE")
    case BS.split 10 (BS.drop 3 (BS.take 64 bytes)) of
      (_hieVer : ghcVer : _) ->
        TE.decodeUtf8 ghcVer @?= T.pack (showVersion fullCompilerVersion)
      _ -> assertFailure ("unrecognised .hie header: " <> p)
  -- 四 namespace 與產生碼樣本的來源不得被後人改掉
  core <- readUtf8 (hiedbFixture </> "src" </> "Demo" </> "Core.hs")
  assertHasAll "fixture Core.hs" core
    ["data Config", "cfgName", "deriving (Eq, Show)", "data Color"]
  app <- readUtf8 (hiedbFixture </> "src" </> "Demo" </> "App.hs")
  assertHasAll "fixture App.hs" app ["Demo.Core", "greet", "run"]

-- | 遞迴列出目錄下所有檔案(T9 用來數 fixture 的 @.hs@ \/ @.hie@)。
--
-- 產生 @.hie@ 的指令(__不入測試流程__,GHC 升版時在
-- @test\/fixtures\/hiedb\/@ 下重跑一次):
--
-- > ghc -fno-code -fwrite-ide-info -hiedir .hie -isrc src/Demo/App.hs src/Demo/Core.hs
listFilesRec :: FilePath -> IO [FilePath]
listFilesRec dir = do
  entries <- listDirectory dir
  parts <- mapM step entries
  pure (concat parts)
 where
  step e = do
    let p = dir </> e
    isDir <- doesDirectoryExist p
    if isDir then listFilesRec p else pure [p]

-- extraction/F004 T8(不需 hiedb):後端註冊後探測失敗 → 降級但不失敗
testHiedbBackendRegistered :: TestTree
testHiedbBackendRegistered = testCase "test_hiedb_backend_registered" $ do
  pm <- loadProjectMeta (defOpts projFixture)
  let missing = hiedbFixture </> "no-such-hiedb-binary"
      opts = (extOpts Auto)
        { XT.rootDir = projFixture, XT.hiedbExe = Just missing }
  res <- extract opts pm
  erLevel res @?= ModuleLevel
  map brBackend (erReports res) @?= [importScanName, hiedbName]
  hr <- reportFor hiedbName res
  brUsed hr @?= False
  assertBool ("degrade reason must name the executable: " <> T.unpack (brDetail hr))
    (T.pack "hiedb executable " `T.isPrefixOf` brDetail hr)
  sr <- reportFor importScanName res
  brUsed sr @?= True
  -- import-scan 的事實照出(projFixture 無 import 行,故以 FactModule 為證);
  -- 失敗的 hiedb 後端一筆 decl 層事實都不留
  assertBool "import-scan facts must survive the degrade"
    (not (null (erFacts res)))
  mapMaybe declOf (erFacts res) @?= []
  mapMaybe refOf (erFacts res) @?= []

-- extraction/F004 T7: readIndexFacts 主流程(驗收標準 2、4)
testReadIndexFacts :: TestTree
testReadIndexFacts = testCase "test_read_index_facts" $
  withHiedbScratch "f004facts" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    h <- expectRight =<< ensureIndex (hiedbOpts root) pm
    (facts, warns) <- readIndexFacts h pm
    -- 回傳警告的開頭是 ihNotes(F003 A2 的 .knot/ 首建提示唯一出口)
    let notes = ihNotes h
    assertBool "ihNotes must be non-empty on a fresh tree" (not (null notes))
    take (length notes) warns @?= notes
    let decls = mapMaybe declOf facts
        refs  = mapMaybe refOf facts
        occOf (q, _, _, _, _) = qnOcc q
        nsOf (q, _, _, _, _) = qnSpace q
    assertBool "expected decl facts" (not (null decls))
    assertBool "expected ref facts" (not (null refs))
    -- 驗收標準 2:四種 namespace 齊備
    sort (nubOrd (map nsOf decls)) @?= [ValueNs, DataConNs, TypeNs, FieldNs]
    forM_ [ ("greet", ValueNs), ("Color", TypeNs)
          , ("Red", DataConNs), ("cfgName", FieldNs) ] $ \(o, ns) ->
      assertBool ("missing FactDecl " <> show o <> " in " <> show ns)
        (any (\d -> occOf d == T.pack o && nsOf d == ns) decls)
    -- 驗收標準 4:每筆事實的檔案都對得回 pmSources
    let paths = Set.fromList (map sfPath (pmSources pm))
    forM_ decls $ \(_, _, _, fp, _) ->
      assertBool ("fdFile not in pmSources: " <> fp) (Set.member fp paths)
    forM_ refs $ \(_, _, _, _, _, fp, _) ->
      assertBool ("frFile not in pmSources: " <> fp) (Set.member fp paths)
    -- 產生的事實一律不含 FactModule / FactImport / FactInstance(規則 2 / C4)
    length (filter (\f -> declOf f == Nothing && refOf f == Nothing) facts) @?= 0
    -- 拿掉一個 SourceFile → 該 module 的事實消失且恰多一則警告
    let pm' = pm { pmSources =
          [ sf | sf <- pmSources pm, not ("Core.hs" `isInfixOf` sfPath sf) ] }
    (facts', warns') <- readIndexFacts h pm'
    length warns' @?= length warns + 1
    let extra = drop (length warns) warns'
    assertBool ("extra warning must name the module: " <> show extra)
      (any (hasText "Demo.Core" . ewMessage) extra)
    assertBool "Demo.Core decls must be gone"
      (not (any (\(_, _, _, fp, _) -> "Core.hs" `isInfixOf` fp)
              (mapMaybe declOf facts')))

-- extraction/F004 T8(需 hiedb):兩後端並存、事實合流,以及 ensureIndex
-- 失敗時的 HiedbFactsError 通道
testHiedbBackendLive :: TestTree
testHiedbBackendLive = testCase "test_hiedb_backend_live" $ do
  withHiedbScratch "f004backend" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    res <- extract ((extOpts Auto) { XT.rootDir = root }) pm
    erLevel res @?= DeclLevel
    map brBackend (erReports res) @?= [importScanName, hiedbName]
    forM_ (erReports res) $ \r -> do
      brUsed r @?= True
      brDetail r @?= T.empty
    assertBool "import-scan facts present" (any isImportFact (erFacts res))
    assertBool "hiedb ref facts present"
      (not (null (mapMaybe refOf (erFacts res))))
    assertBool "hiedb decl facts present"
      (not (null (mapMaybe declOf (erFacts res))))
  -- ensureIndex 必失敗(0 byte 假 .hie)→ brUsed = False + "hiedb index failed: "
  withHiedbScratch "f004boom" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    hie <- case pmHie pm of
      Nothing -> assertFailure "scratch tree must expose a .hie directory"
      Just x  -> pure x
    let bad = ".hie/Demo/Bad.hie"
    BS.writeFile (root </> bad) BS.empty
    let pmBad = pm { pmHie = Just hie { hieFiles = hieFiles hie <> [bad] } }
    res <- extract ((extOpts Auto) { XT.rootDir = root }) pmBad
    hr <- reportFor hiedbName res
    brUsed hr @?= False
    assertBool ("detail must carry the index-failure prefix: "
                  <> T.unpack (brDetail hr))
      (hasText "hiedb index failed: " (brDetail hr))
    erLevel res @?= ModuleLevel
    assertBool "import-scan facts survive" (any isImportFact (erFacts res))

-- extraction/F004 T10: 端到端驗收(驗收標準 1、3、5)
testHiedbFactsAcceptance :: TestTree
testHiedbFactsAcceptance = testCase "test_hiedb_facts_acceptance" $
  withHiedbScratch "f004accept" $ \root -> do
    pm <- loadProjectMeta (defOpts root)
    h <- expectRight =<< ensureIndex (hiedbOpts root) pm
    (facts, _) <- readIndexFacts h pm
    let refs = mapMaybe refOf facts
    -- (a) 驗收標準 1:跨 module 呼叫的 frFromDecl 指向正確的頂層宣告
    let target = qn "Demo.Core" "greet" ValueNs
        inRun  = Just (qn "Demo.App" "run" ValueNs)
        hits = [ (d, fp) | (m, d, t, _, _, fp, _) <- refs
               , m == mn "Demo.App", t == target ]
    assertBool "expected a cross-module ref to Demo.Core.greet" (not (null hits))
    -- 全部都掛在 Demo.App 的來源檔上(fdFile / frFile 取 sfPath 原文)
    forM_ hits $ \(_, fp) -> fp @?= "src/Demo/App.hs"
    -- 寫在 run 的函式體內那筆 → frFromDecl 指向 run(驗收標準 1)
    assertBool ("expected a greet ref resolved to Demo.App.run, got: " <> show hits)
      (any ((== inRun) . fst) hits)
    -- import 行上的同一個名字落在任何宣告之外 → Nothing(LEFT JOIN 的用途:
    -- 這種事實不能漏,graph-core 以來源 module 節點為源處理)
    assertBool ("expected an unresolved greet ref (import line), got: " <> show hits)
      (any ((== Nothing) . fst) hits)
    -- (b) 驗收標準 3:與 refs 表逐筆對帳 frGenerated
    rows <- withConnection (ihDbPath h) $ \c ->
      query_ c (Query (T.pack
        "SELECT occ, mod, sl, is_generated FROM refs"))
        :: IO [(Text, Text, Int, Bool)]
    assertBool "refs table must be non-empty" (not (null rows))
    let dbSet = Set.fromList
          [ (m, occ, ns, sl, g)
          | (rawOcc, m, sl, g) <- rows
          , Just (occ, ns) <- [parseOcc rawOcc] ]
        factSet = Set.fromList
          [ (modText (qnModule t), qnOcc t, qnSpace t, ln, g)
          | (_, _, t, g, _, _, ln) <- refs ]
    factSet @?= dbSet
    assertBool "fixture must carry at least one is_generated = 1 ref"
      (any (\(_, _, _, _, g) -> g) (Set.toList dbSet))
    -- (c) 驗收標準 5:連續兩次結果完全相同
    (f1, w1) <- readIndexFacts h pm
    (f2, w2) <- readIndexFacts h pm
    f2 @?= f1
    w2 @?= w1
    f1 @?= facts

-- extraction/F004 T11: knot-hs 自身唯讀驗收(需 hiedb 且自身有 .hie)
testHiedbFactsSelfcheck :: TestTree
testHiedbFactsSelfcheck = testCase "test_hiedb_facts_selfcheck" $ do
  pm <- loadProjectMeta (defOpts ".")
  case pmHie pm of
    Just hie | not (null (hieFiles hie)) -> do
      knotBefore <- doesDirectoryExist ".knot"
      tmp <- getTemporaryDirectory
      let db = tmp </> "knot-hs-f004-self" </> "self.sqlite"
      removePathForcibly (takeDirectory db)
      res <- extract ((extOpts Auto) { XT.rootDir = ".", XT.dbPath = Just db }) pm
      erLevel res @?= DeclLevel
      map brBackend (erReports res) @?= [importScanName, hiedbName]
      forM_ (erReports res) $ \r -> brUsed r @?= True
      let decls = mapMaybe declOf (erFacts res)
          refs  = mapMaybe refOf (erFacts res)
      assertBool "self decl facts" (not (null decls))
      assertBool "self ref facts" (not (null refs))
      -- 「對映不到」的警告只允許一種來源:該 module 的原始檔被排除
      -- (G-B001 的正常丟棄路徑——例如 .hie 以 --enable-tests 產生時,
      --  test-suite 的 Main.hie 會蓋掉 executable 的)。其餘一律是缺陷。
      let excludedMods =
            [ m | sf <- pmSources pm, not (sfIncluded sf), Just m <- [sfModule sf] ]
          expectedDrop w =
            any (\(ModuleName m) ->
                   hasText ("cannot map indexed module " <> T.unpack m <> " back")
                           (ewMessage w))
                excludedMods
          unmapped =
            [ w | w <- erWarnings res, hasText "cannot map indexed module" (ewMessage w) ]
          unexpected = filter (not . expectedDrop) unmapped
      assertBool ("unexpected unmapped modules: " <> show unexpected) (null unexpected)
      -- 唯讀驗收:目標專案內不得新建 .knot/
      doesDirectoryExist ".knot" >>= (@?= knotBefore)
      putStrLn ("[selfcheck/F004] hieFiles=" <> show (length (hieFiles hie))
        <> " decls=" <> show (length decls)
        <> " refs=" <> show (length refs)
        <> " generated=" <> show (length [ () | (_, _, _, g, _, _, _) <- refs, g ])
        <> " warnings=" <> show (length (erWarnings res)))
      forM_ (erWarnings res) $ \w ->
        putStrLn ("[selfcheck/F004] warn " <> T.unpack (ewSource w)
          <> ": " <> T.unpack (ewMessage w))
      removePathForcibly (takeDirectory db)
    _ -> putStrLn
      "[skip] test_hiedb_facts_selfcheck: knot-hs itself has no .hie files \
      \(build with -fwrite-ide-info -hiedir .hie to enable this check)"

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

-- | 事實流 → CodeGraph 的測試捷徑。
--
-- F002 起 fact-gate 會讀 @pmSources@(組裝規則 3),故只有**純 module 層**
-- 事實流才可以配 'emptyMeta';含 decl 層事實者一律走 'graphFacts' + 'metaFor'。
graphOf :: BuildOptions -> [Fact] -> CodeGraph
graphOf = graphFacts emptyMeta

-- | 事實流 + 手工 'ProjectMeta' → CodeGraph(F002 E3:手工事實流,不碰 hiedb)。
graphFacts :: ProjectMeta -> BuildOptions -> [Fact] -> CodeGraph
graphFacts pm opts facts = buildGraph opts pm
  ExtractResult { erFacts = facts, erLevel = ModuleLevel, erReports = [], erWarnings = [] }

-- | 事實流 → (邊, 統計, 警告) 的測試捷徑(純 module 層用)。
edgesOf :: [Fact] -> ([GraphEdge], EdgeStats, [GraphWarning])
edgesOf = edgesWith emptyMeta

-- | 事實流 + 手工 'ProjectMeta' → (邊, 統計, 警告)。
edgesWith :: ProjectMeta -> [Fact] -> ([GraphEdge], EdgeStats, [GraphWarning])
edgesWith pm facts = deriveEdges gated (mintNodes gated)
 where gated = gateFacts pm facts

-- | 手工 'ProjectMeta':@pmSources@ 涵蓋指定路徑,即組裝規則 3 (a) 條件的
-- 比對母體(F002 假設 A2:全部條目,不限 @sfIncluded@)。
metaFor :: [FilePath] -> ProjectMeta
metaFor paths = ProjectMeta
  { pmPackages = []
  , pmSources  = [SourceFile p Nothing [] True | p <- paths]
  , pmHie      = Nothing
  , pmWarnings = []
  }

-- | 節點集合裡的 module 節點(F002 起 'mintNodes' 會混入 decl / instance)。
moduleNodesOf :: [GraphNode] -> [GraphNode]
moduleNodesOf ns = [n | n <- ns, gnKind n == ModuleNode]

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
        { gsDroppedExternal = 3, gsTopExternalTargets = [(T.pack "Data.Text", 2)]
        , gsFilteredGenerated = 0, gsDedupedEdges = 1 }
  gsDroppedExternal st    @?= 3
  gsTopExternalTargets st @?= [(T.pack "Data.Text", 2)]
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
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  ]

-- | 只在 pmSources 出現、不在事實流的 module(釘住 D2)。
ghostMeta :: ProjectMeta
ghostMeta = ProjectMeta
  { pmPackages = []
  , pmSources  = [SourceFile "src/Ghost.hs" (Just (mn "Ghost")) [] True]
  , pmHie      = Nothing
  , pmWarnings = []
  }

-- graph-core T2: fact-gate 的內部集合(D2)、module 層原樣通過、規則 3 生效
--
-- F002 T6 更新(假設 A6):規則 3 實作後,@ghostMeta@ 不涵蓋
-- @src/Demo/Core.hs@ → 該筆 @FactDecl@ 由 (a) 條件濾除、@gfFiltered@ 為 1。
-- 原本的「事實原樣通過、gfFiltered == 0」改以「涵蓋該檔的 ProjectMeta」表述,
-- 兩種情境都保留,不刪測試。
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
  -- module 層事實原樣通過(不受規則 3 影響,假設 A1);FactDecl 被 (a) 濾除
  gfFacts g @?= filter isModuleLayerFact gateFixtureFacts
  assertBool "FactDecl filtered out by rule 3 (a)"
    (not (any isDeclFact (gfFacts g)))
  gfFiltered g @?= 1
  -- 檔案落在 pmSources 時同一筆 FactDecl 原樣通過、gfFiltered 回到 0
  let g2 = gateFacts (metaFor ["src/Demo/Core.hs"]) gateFixtureFacts
  gfFacts g2 @?= gateFixtureFacts
  assertBool "FactDecl passes through" (any isDeclFact (gfFacts g2))
  gfFiltered g2 @?= 0
  Set.toList (gfInternal g2) @?= sort [mn "Demo.Core", mn "Main"]

-- | 規則 3 只適用 decl 層事實(假設 A1);這兩個判定供測試對帳用。
isModuleLayerFact, isDeclFact :: Fact -> Bool
isModuleLayerFact FactModule{} = True
isModuleLayerFact FactImport{} = True
isModuleLayerFact _            = False
isDeclFact FactDecl{} = True
isDeclFact _          = False

-- graph-core T3: id 鑄造(D1)與 module 節點
--
-- F002 T6 更新(假設 A6):原本靠 'emptyMeta' 讓 @FactDecl@ 進不了
-- node-mint,結論成立的理由已被規則 3 取代 → 改配涵蓋該檔的
-- 'ProjectMeta',讓 @FactDecl@ 通過閘門,斷言 **module 節點清單不變**
-- (decl 節點另由 graph-core/F002 的測試涵蓋),保持原測試意圖。
testMintModuleNodes :: TestTree
testMintModuleNodes = testCase "test_mint_module_nodes" $ do
  -- 契約簽名兩個分支(A2 裁決)
  mintModuleId (mn "Demo.Core") Nothing @?= nid "Demo.Core"
  mintModuleId (mn "Main") (Just "app/Main.hs") @?= nid "Main@app/Main.hs"
  let g = gateFacts (metaFor ["src/Demo/Core.hs"]) gateFixtureFacts
      nodes = moduleNodesOf (mintNodes g)
  -- 單一來源檔 → 裸名;同名兩檔 → 整組消歧
  map gnId nodes @?=
    [nid "Main@app/Main.hs", nid "Main@test/Main.hs", nid "Demo.Core"]
  forM_ nodes $ \n -> do
    gnKind n @?= ModuleNode
    gnLine n @?= Nothing   -- FactModule 無行號欄位
  -- 消歧只反映在 id 與 gnFile;gnLabel 維持裸名(假設 A5)
  map gnLabel nodes @?= map T.pack ["Main", "Main", "Demo.Core"]
  map gnFile nodes @?= ["app/Main.hs", "test/Main.hs", "src/Demo/Core.hs"]
  -- 重複 FactModule 只產一個節點(FactDecl 通過閘門也不改 module 節點清單)
  let dup = gateFacts (metaFor ["src/A.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "x" ValueNs) ValueDecl False "src/A.hs" 4
        ]
  map gnId (moduleNodesOf (mintNodes dup)) @?= [nid "A"]
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
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  ]

-- | T6 的手工 'ProjectMeta':涵蓋 'assembleFacts' 觸及的四個檔案
-- (F002 起 @FactDecl@ 要通過組裝規則 3 才進得了 node-mint)。
assembleMeta :: ProjectMeta
assembleMeta = metaFor
  ["app/Main.hs", "test/Main.hs", "src/Demo/Core.hs", "src/Demo/Render.hs"]

-- graph-core T6: graph-assemble 的統計、警告彙整與 D5 穩定排序
--
-- F002 T6 更新(假設 A6):`F001` 驗收標準 5 的原文即註明「尚無 decl 事實」,
-- 該前提已被 F002 取代——@moduleOnly@ 兩取值的輸出**必須不同**。改為:
-- @False@ 時比 `F001` 原結果多 1 個 decl 節點 + 1 條 @RContains@、其餘四項
-- 統計與兩則警告不變;@True@ 時逐欄回到 `F001` 的原斷言(含
-- @gsFilteredGenerated == 0@)。不刪除任何斷言。
testBuildGraphAssemble :: TestTree
testBuildGraphAssemble = testCase "test_build_graph_assemble" $ do
  let g = graphFacts assembleMeta defBuildOpts assembleFacts
  -- 節點依 NodeId 遞增(F001 的四個 module 節點 + F002 的一個 decl 節點)
  map gnId (cgNodes g) @?=
    [ nid "Demo.Core", nid "Demo.Core.render", nid "Demo.Render"
    , nid "Main@app/Main.hs", nid "Main@test/Main.hs" ]
  assertBool "cgNodes sorted by NodeId"
    (let ids = map gnId (cgNodes g) in and (zipWith (<) ids (drop 1 ids)))
  map gnKind (cgNodes g) @?=
    [ModuleNode, DeclNode ValueDecl, ModuleNode, ModuleNode, ModuleNode]
  -- 邊依 (source, relation, target) 遞增;重複 import 合併且取最早行
  map edgeTriple (cgEdges g) @?=
    [ (nid "Demo.Core", RContains, nid "Demo.Core.render")
    , (nid "Demo.Render", RImports, nid "Demo.Core")
    , (nid "Main@app/Main.hs", RImports, nid "Demo.Core")
    ]
  map geLine (cgEdges g) @?= [Just 20, Just 4, Just 6]
  assertBool "cgEdges sorted by (source, relation, target)"
    (let ks = map edgeTriple (cgEdges g) in and (zipWith (<) ks (drop 1 ks)))
  -- GraphStats 四欄(decl 事實全部通過閘門 → gsFilteredGenerated 仍為 0)
  cgStats g @?= GraphStats
    { gsDroppedExternal    = 2
    , gsTopExternalTargets = [(T.pack "Data.Text", 2)]
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
  graphFacts assembleMeta defBuildOpts (reverse assembleFacts) @?= g
  -- moduleOnly = True:decl 節點與 RContains 消失,逐欄回到 F001 的原輸出
  let gm = graphFacts assembleMeta (BuildOptions { moduleOnly = True }) assembleFacts
  map gnId (cgNodes gm) @?=
    [ nid "Demo.Core", nid "Demo.Render"
    , nid "Main@app/Main.hs", nid "Main@test/Main.hs" ]
  map edgeTriple (cgEdges gm) @?=
    [ (nid "Demo.Render", RImports, nid "Demo.Core")
    , (nid "Main@app/Main.hs", RImports, nid "Demo.Core")
    ]
  map geLine (cgEdges gm) @?= [Just 4, Just 6]
  cgStats gm @?= cgStats g            -- 含 gsFilteredGenerated == 0
  cgWarnings gm @?= cgWarnings g
  assertBool "moduleOnly output now differs from the full graph" (gm /= g)

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
        , gsTopExternalTargets = [(T.pack "Data.Text", 2), (T.pack "Data.Map", 1)]
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
            , gsTopExternalTargets = [(T.pack "Data.Text", 3), (T.pack "Data.Map", 1)]
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
-- graph-core/F002 decl-nodes
--------------------------------------------------------------------------------

-- | 委派決策 E3:本 group 一律用手工 @[Fact]@ 事實流 + 手工 'ProjectMeta',
-- 不依賴 hiedb、不讀 @.hie@、不 shell out。
--
-- T6(@F001@ 既有測試對帳)不另立測試:依假設 A6 就地更新
-- @test_gate_facts@ / @test_mint_module_nodes@ / @test_build_graph_assemble@
-- 三條(見 graph-core/F001 group)。
graphCoreF002Tests :: TestTree
graphCoreF002Tests = testGroup "graph-core/F002 decl-nodes"
  [ testGateGeneratedFilter    -- T1
  , testGateGeneratedDeclRule  -- G-E003 T3
  , testMintDeclIds            -- T2
  , testMintDeclNodes          -- T3
  , testContainsEdges          -- T4
  , testModuleOnlyDecl         -- T5
  , testDeclGraphDeterministic -- T7
  ]

isDeclNode :: GraphNode -> Bool
isDeclNode n = case gnKind n of
  DeclNode{} -> True
  _          -> False

-- | T1 樣本:module 層 3 筆(檔案刻意不在 @pmSources@)+ decl 層 12 筆
-- (通過 3、濾除 9,三個條件各自與交集都有代表)。
gateRule3Facts :: [Fact]
gateRule3Facts =
  [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactModule "src/Ghost.hs" (mn "Ghost")
  , FactImport (mn "Ghost") (mn "Demo.Core") "src/Ghost.hs" 2
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  , FactDecl (qn "Demo.Core" "gone" ValueNs) ValueDecl False "src/Absent.hs" 5
  , FactDecl (qn "Demo.Core" "zero" ValueNs) ValueDecl False "src/Demo/Core.hs" 0
  , FactDecl (qn "Demo.Core" "neg" ValueNs) ValueDecl False "src/Demo/Core.hs" (-1)
  , FactDecl (qn "Demo.Core" "both" ValueNs) ValueDecl False "src/Absent.hs" 0
  , FactRef (mn "Demo.Core") Nothing (qn "Demo.Core" "render" ValueNs)
      False False "src/Demo/Core.hs" 30
  , FactRef (mn "Demo.Core") Nothing (qn "Demo.Core" "render" ValueNs)
      True False "src/Demo/Core.hs" 31
  , FactRef (mn "Demo.Core") Nothing (qn "Demo.Core" "render" ValueNs)
      False False "src/Absent.hs" 32
  , FactRef (mn "Demo.Core") Nothing (qn "Demo.Core" "render" ValueNs)
      False False "src/Demo/Core.hs" 0
  , FactInstance (qn "Demo.Core" "Renderable" TypeNs) (T.pack "Renderable Sprite")
      "src/Demo/Core.hs" 40
  , FactInstance (qn "Demo.Core" "Renderable" TypeNs) (T.pack "Renderable Ghost")
      "src/Absent.hs" 41
  , FactInstance (qn "Demo.Core" "Renderable" TypeNs) (T.pack "Renderable Zero")
      "src/Demo/Core.hs" 0
  ]

-- F002 T1: 組裝規則 3 的三條件(C4)、計數語意與 module 層豁免(假設 A1)
testGateGeneratedFilter :: TestTree
testGateGeneratedFilter = testCase "test_gate_generated_filter" $ do
  let g = gateFacts (metaFor ["src/Demo/Core.hs"]) gateRule3Facts
  -- 通過者:module 層 3 筆原樣(fmFile 不在 pmSources 也一律通過,假設 A1)
  -- + 檔案在 pmSources 且行號 > 0 且非產生碼的 decl / ref / instance 各 1
  gfFacts g @?=
    [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
    , FactModule "src/Ghost.hs" (mn "Ghost")
    , FactImport (mn "Ghost") (mn "Demo.Core") "src/Ghost.hs" 2
    , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
    , FactRef (mn "Demo.Core") Nothing (qn "Demo.Core" "render" ValueNs)
        False False "src/Demo/Core.hs" 30
    , FactInstance (qn "Demo.Core" "Renderable" TypeNs) (T.pack "Renderable Sprite")
        "src/Demo/Core.hs" 40
    ]
  -- gfFiltered = 濾除筆數(不是條件命中次數)
  gfFiltered g @?= 9
  gfFiltered g @?= length gateRule3Facts - length (gfFacts g)
  -- gfInternal 與過濾前相同(module 層不受規則 3 影響)
  Set.toList (gfInternal g) @?= sort [mn "Demo.Core", mn "Ghost"]
  -- (c) 條件:檔案與行號都合法,只因 frGenerated = True 被濾除
  let gGen = gateFacts (metaFor ["src/A.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactRef (mn "A") Nothing (qn "A" "x" ValueNs) True False "src/A.hs" 9
        ]
  map isModuleLayerFact (gfFacts gGen) @?= [True]
  gfFiltered gGen @?= 1
  -- 一筆同時違反 (a) 與 (b) 只算一次
  let gBoth = gateFacts (metaFor ["src/A.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "both" ValueNs) ValueDecl False "src/Absent.hs" 0
        ]
  gfFiltered gBoth @?= 1
  -- 空 pmSources:decl 層全滅、module 層全存
  let gEmpty = gateFacts emptyMeta gateRule3Facts
  gfFacts gEmpty @?= filter isModuleLayerFact gateRule3Facts
  gfFiltered gEmpty @?= 12

-- G-E003 T3: 組裝規則 3 新增的 (d)(e) 兩條件
--
-- (d) @FactDecl.fdGenerated@、(e) @FactRef.frTargetGenerated@——兩者都在
-- 「檔案在 pmSources、行號 > 0、frGenerated = False」的前提下獨立生效,
-- 否則測到的可能是 (a)/(b)/(c) 而不是新條件。
testGateGeneratedDeclRule :: TestTree
testGateGeneratedDeclRule = testCase "test_gate_generated_decl_rule" $ do
  let meta = metaFor ["src/A.hs"]
      modFact = FactModule "src/A.hs" (mn "A")
      -- 手寫宣告與 deriving 產生的字典,其餘欄位完全相同
      handDecl = FactDecl (qn "A" "render" ValueNs) ValueDecl False "src/A.hs" 20
      genDecl  = FactDecl (qn "A" "$fEqColor" ValueNs) ValueDecl True "src/A.hs" 20
      -- 指向手寫宣告 / 指向產生碼宣告的兩筆引用,其餘欄位完全相同
      handRef  = FactRef (mn "A") Nothing (qn "A" "render" ValueNs)
                   False False "src/A.hs" 30
      genRef   = FactRef (mn "A") Nothing (qn "A" "$fEqColor" ValueNs)
                   False True "src/A.hs" 30
  -- (d):只差 fdGenerated,產生碼那筆被濾除
  let gD = gateFacts meta [modFact, handDecl, genDecl]
  gfFacts gD    @?= [modFact, handDecl]
  gfFiltered gD @?= 1
  -- (e):只差 frTargetGenerated,指向產生碼的那筆被濾除
  let gE = gateFacts meta [modFact, handRef, genRef]
  gfFacts gE    @?= [modFact, handRef]
  gfFiltered gE @?= 1
  -- 同時命中 (c) 與 (e) 的一筆只計一次
  let gCE = gateFacts meta
        [ modFact
        , FactRef (mn "A") Nothing (qn "A" "$fEqColor" ValueNs)
            True True "src/A.hs" 30
        ]
  gfFacts gCE    @?= [modFact]
  gfFiltered gCE @?= 1
  -- 同時命中 (a)(b)(d) 的一筆也只計一次
  let gABD = gateFacts meta
        [ modFact
        , FactDecl (qn "A" "$fEqColor" ValueNs) ValueDecl True "src/Absent.hs" 0
        ]
  gfFiltered gABD @?= 1
  -- module 層不受 (d)(e) 影響:gfInternal 與節點來源樣本不縮水(假設 A1)
  let gMod = gateFacts meta
        [ modFact
        , FactImport (mn "A") (mn "B") "src/A.hs" 2
        , genDecl, genRef
        ]
  map isModuleLayerFact (gfFacts gMod) @?= [True, True]
  Set.toList (gfInternal gMod)         @?= [mn "A"]
  gfFiltered gMod                      @?= 2

-- F002 T2: 鑄造規則表其餘兩列 + 兩個非契約面工具
testMintDeclIds :: TestTree
testMintDeclIds = testCase "test_mint_decl_ids" $ do
  -- 驗收標準 1:同名型別與值鑄出不同 id(C2:#t 只對 TypeNs)
  mintDeclId (qn "Demo.Core" "Foo" TypeNs) Nothing    @?= nid "Demo.Core.Foo#t"
  mintDeclId (qn "Demo.Core" "Foo" DataConNs) Nothing @?= nid "Demo.Core.Foo"
  mintDeclId (qn "Demo.Core" "Foo" ValueNs) Nothing   @?= nid "Demo.Core.Foo"
  mintDeclId (qn "Demo.Core" "Foo" FieldNs) Nothing   @?= nid "Demo.Core.Foo"
  assertBool "type id never collides with the term id"
    (mintDeclId (qn "Demo.Core" "Foo" TypeNs) Nothing
       /= mintDeclId (qn "Demo.Core" "Foo" DataConNs) Nothing)
  -- C3:decl 層沿用所屬 module 的消歧結果
  mintDeclId (qn "Main" "main" ValueNs) (Just "app/Main.hs")
    @?= nid "Main@app/Main.hs.main"
  mintDeclId (qn "Main" "main" ValueNs) (Just "test/Main.hs")
    @?= nid "Main@test/Main.hs.main"
  -- 驗收標準 2:instance id 含渲染標頭,且對同輸入恆定
  mintInstanceId (mn "Demo.Core") Nothing (T.pack "Renderable Sprite")
    @?= nid "Demo.Core#i:Renderable Sprite"
  mintInstanceId (mn "Main") (Just "app/Main.hs") (T.pack "Show Foo")
    @?= nid "Main@app/Main.hs#i:Show Foo"
  mintInstanceId (mn "Demo.Core") Nothing (T.pack "Renderable Sprite")
    @?= mintInstanceId (mn "Demo.Core") Nothing (T.pack "Renderable Sprite")
  -- 非契約面 disambiguate:碰撞組回 Just file、非碰撞組與未知 module 回 Nothing
  let files = moduleFiles gateFixtureFacts
  disambiguate files (mn "Main") "app/Main.hs"        @?= Just "app/Main.hs"
  disambiguate files (mn "Main") "test/Main.hs"       @?= Just "test/Main.hs"
  disambiguate files (mn "Demo.Core") "src/Demo/Core.hs" @?= Nothing
  disambiguate files (mn "Absent") "src/Absent.hs"    @?= Nothing
  -- 非契約面 moduleOfFile:由 FactModule 建出檔案 → module 對映
  let fileMods = moduleOfFile gateFixtureFacts
  Map.lookup "app/Main.hs" fileMods      @?= Just (mn "Main")
  Map.lookup "test/Main.hs" fileMods     @?= Just (mn "Main")
  Map.lookup "src/Demo/Core.hs" fileMods @?= Just (mn "Demo.Core")
  Map.lookup "src/Absent.hs" fileMods    @?= Nothing

-- | T3/T4/T5/T7 共用:非碰撞 module + 碰撞組 + 同名型別/建構子
-- + 非內部 module 的 decl + instance。
declFixtureFacts :: [Fact]
declFixtureFacts =
  [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactModule "app/Main.hs" (mn "Main")
  , FactModule "test/Main.hs" (mn "Main")
  , FactDecl (qn "Demo.Core" "Foo" TypeNs) DataDecl False "src/Demo/Core.hs" 10
  , FactDecl (qn "Demo.Core" "Foo" DataConNs) DataDecl False "src/Demo/Core.hs" 10
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "app/Main.hs" 3
  , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "test/Main.hs" 4
  , FactDecl (qn "Ext.Pkg" "helper" ValueNs) ValueDecl False "src/Ext.hs" 7
  , FactInstance (qn "Demo.Class" "Renderable" TypeNs) (T.pack "Renderable Sprite")
      "src/Demo/Core.hs" 40
  ]

declFixtureMeta :: ProjectMeta
declFixtureMeta =
  metaFor ["src/Demo/Core.hs", "app/Main.hs", "test/Main.hs", "src/Ext.hs"]

-- F002 T3: mintNodes 產出 decl / instance 節點,module 層行為不變
testMintDeclNodes :: TestTree
testMintDeclNodes = testCase "test_mint_decl_nodes" $ do
  let gated = gateFacts declFixtureMeta declFixtureFacts
      nodes = mintNodes gated
      byId i = find ((== nid i) . gnId) nodes
  gfFiltered gated @?= 0     -- 事實全部落在 pmSources 且行號合法
  -- module 節點清單與 F001 完全相同(不改 module 層行為)
  map gnId (moduleNodesOf nodes) @?=
    [nid "Demo.Core", nid "Main@app/Main.hs", nid "Main@test/Main.hs"]
  -- decl 節點:通過閘門且 module 為內部者各一個(碰撞組兩個 Main.main 相異)
  sort (map gnId (filter isDeclNode nodes)) @?= sort
    [ nid "Demo.Core.Foo#t", nid "Demo.Core.Foo", nid "Demo.Core.render"
    , nid "Main@app/Main.hs.main", nid "Main@test/Main.hs.main"
    ]
  case byId "Demo.Core.render" of
    Nothing -> assertFailure "no node for Demo.Core.render"
    Just n  -> do
      gnKind n  @?= DeclNode ValueDecl
      gnLabel n @?= T.pack "render"      -- gnLabel 是 occ 名,不帶消歧與 #t
      gnFile n  @?= "src/Demo/Core.hs"
      gnLine n  @?= Just 20
  case byId "Demo.Core.Foo#t" of
    Nothing -> assertFailure "no node for Demo.Core.Foo#t"
    Just n  -> do
      gnKind n  @?= DeclNode DataDecl
      gnLabel n @?= T.pack "Foo"
      gnLine n  @?= Just 10
  case byId "Main@test/Main.hs.main" of
    Nothing -> assertFailure "no node for Main@test/Main.hs.main"
    Just n  -> do
      gnLabel n @?= T.pack "main"
      gnFile n  @?= "test/Main.hs"
      gnLine n  @?= Just 4
  -- instance 節點(A3:<mod-id> 由 fiInstFile 反查,不是 qnModule fiClass)
  case byId "Demo.Core#i:Renderable Sprite" of
    Nothing -> assertFailure "no node for the instance"
    Just n  -> do
      gnKind n  @?= InstanceNode
      gnLabel n @?= T.pack "Renderable Sprite"
      gnFile n  @?= "src/Demo/Core.hs"
      gnLine n  @?= Just 40
  assertBool "instance id never uses the class module"
    (all ((/= nid "Demo.Class#i:Renderable Sprite") . gnId) nodes)
  -- 組裝規則 1:qnModule 非內部 → 不產節點(也不 crash)
  byId "Ext.Pkg.helper" @?= Nothing
  -- 假設 A9:同 id 的兩筆 decl 靜默合併為一個節點;
  -- 合併保留 (gnFile, gnLine) 最小者 → 對事實流重排序不敏感(規則 7)
  let dupFacts =
        [ FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "name" FieldNs) ValueDecl False "src/A.hs" 9
        , FactDecl (qn "A" "name" FieldNs) ValueDecl False "src/A.hs" 4
        ]
      dupNodes fs = filter isDeclNode (mintNodes (gateFacts (metaFor ["src/A.hs"]) fs))
  map gnId (dupNodes dupFacts) @?= [nid "A.name"]
  map gnLine (dupNodes dupFacts) @?= [Just 4]
  dupNodes (reverse dupFacts) @?= dupNodes dupFacts
  -- 非契約面 declNodeIndex:結構性守門「查得到 ⇒ 節點存在」
  let idx = declNodeIndex gated nodes
  Map.lookup (qn "Demo.Core" "render" ValueNs) idx
    @?= Just [("src/Demo/Core.hs", nid "Demo.Core.render")]
  Map.lookup (qn "Main" "main" ValueNs) idx @?= Just
    [ ("app/Main.hs", nid "Main@app/Main.hs.main")
    , ("test/Main.hs", nid "Main@test/Main.hs.main")
    ]
  Map.lookup (qn "Ext.Pkg" "helper" ValueNs) idx @?= Nothing
  Map.lookup (qn "Demo.Core" "render" ValueNs)
    (declNodeIndex gated [n | n <- nodes, gnId n /= nid "Demo.Core.render"])
    @?= Nothing

-- F002 T4: RContains 推導、統計歸屬(假設 A4)與「明確不做」的反向斷言
testContainsEdges :: TestTree
testContainsEdges = testCase "test_contains_edges" $ do
  let (edges, st, ws) = edgesWith declFixtureMeta declFixtureFacts
  -- 驗收標準 4:每個 decl / instance 節點恰一條來自所屬 module 的 RContains
  map edgeTriple edges @?=
    [ (nid "Demo.Core", RContains, nid "Demo.Core#i:Renderable Sprite")
    , (nid "Demo.Core", RContains, nid "Demo.Core.Foo")
    , (nid "Demo.Core", RContains, nid "Demo.Core.Foo#t")
    , (nid "Demo.Core", RContains, nid "Demo.Core.render")
    , (nid "Main@app/Main.hs", RContains, nid "Main@app/Main.hs.main")
    , (nid "Main@test/Main.hs", RContains, nid "Main@test/Main.hs.main")
    ]
  map geLine edges @?= [Just 40, Just 10, Just 10, Just 20, Just 3, Just 4]
  -- 碰撞組:app/Main.hs 的 main 由 Main@app/Main.hs 擁有,不是 Main@test/Main.hs
  assertBool "collision group ownership stays per-file"
    (GraphEdge (nid "Main@app/Main.hs") (nid "Main@app/Main.hs.main") RContains (Just 3)
       `elem` edges)
  -- 本事實流不產 RCalls / RUses / RImplements(無 FactRef;instance 的 class
  -- 落在外部 module → F003 依組裝規則 1 丟棄該邊)
  assertBool "no calls/uses/implements in this stream"
    (all ((`elem` [RImports, RContains]) . geRelation) edges)
  -- 假設 A4:module 非內部 → 不產邊、不計 esDroppedExternal、彙整為一則警告
  --
  -- F003 就地更新:`Demo.Class` 不在 gfInternal,故 F003 的 RImplements 支對
  -- 這筆 FactInstance 判為「外部 class」→ 依組裝規則 1 丟棄並計入統計
  -- (驗收標準 5 後半)。RContains 面的原斷言一條不刪。
  esDroppedExternal st @?= 1
  esTopExternal st @?= [(mn "Demo.Class", 1)]
  esDeduped st @?= 0
  case ws of
    [w] -> do
      gwSource w @?= T.pack "Ext.Pkg"
      assertBool "warning says why" (T.pack "not internal" `T.isInfixOf` gwMessage w)
      assertBool "warning carries the count"
        (T.pack "1 fact(s) skipped" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws)
  -- 每個相異來源一則警告(帶筆數),不逐筆刷屏
  let (e3, st3, ws3) = edgesWith (metaFor ["src/E.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "Ext" "a" ValueNs) ValueDecl False "src/E.hs" 1
        , FactDecl (qn "Ext" "b" ValueNs) ValueDecl False "src/E.hs" 2
        , FactDecl (qn "Ext" "c" ValueNs) ValueDecl False "src/E.hs" 3
        ]
  e3 @?= []
  esDroppedExternal st3 @?= 0
  case ws3 of
    [w] -> do
      gwSource w @?= T.pack "Ext"
      assertBool "aggregated count is 3"
        (T.pack "3 fact(s) skipped" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws3)
  -- 規則 5:重複 FactDecl 合併為一條、geLine 取最小、計入 esDeduped
  let (e2, st2, ws2) = edgesWith (metaFor ["src/A.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "x" ValueNs) ValueDecl False "src/A.hs" 40
        , FactDecl (qn "A" "x" ValueNs) ValueDecl False "src/A.hs" 12
        ]
  map edgeTriple e2 @?= [(nid "A", RContains, nid "A.x")]
  map geLine e2 @?= [Just 12]
  esDeduped st2 @?= 1
  ws2 @?= []
  -- instance 的檔案查不到 FactModule → 不產邊、不計統計、彙整為一則警告
  let (e4, st4, ws4) = edgesWith (metaFor ["src/Orphan.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactInstance (qn "A" "C" TypeNs) (T.pack "C T") "src/Orphan.hs" 5
        ]
  e4 @?= []
  esDroppedExternal st4 @?= 0
  map gwSource ws4 @?= [T.pack "src/Orphan.hs"]

-- | T5/T7 樣本:decl 事實流 + 內部/外部 import + 一筆會被規則 3 濾除的宣告。
moduleOnlyFacts :: [Fact]
moduleOnlyFacts = declFixtureFacts <>
  [ FactImport (mn "Main") (mn "Demo.Core") "app/Main.hs" 2
  , FactImport (mn "Main") (mn "Data.Text") "app/Main.hs" 3
  , FactDecl (qn "Demo.Core" "generated" ValueNs) ValueDecl False "src/Demo/Core.hs" 0
  ]

-- F002 T5: 組裝規則 6 與驗收標準 3 / 5
testModuleOnlyDecl :: TestTree
testModuleOnlyDecl = testCase "test_module_only_decl" $ do
  let gFull = graphFacts declFixtureMeta defBuildOpts moduleOnlyFacts
      gMod  = graphFacts declFixtureMeta (BuildOptions { moduleOnly = True }) moduleOnlyFacts
  -- 驗收標準 5:moduleOnly = True 時 decl 節點與 RContains 完全不出現
  forM_ (cgNodes gMod) $ \n -> gnKind n @?= ModuleNode
  forM_ (cgEdges gMod) $ \e -> geRelation e @?= RImports
  -- 規則 6:decl 層事實不計入統計
  gsFilteredGenerated (cgStats gMod) @?= 0
  -- 驗收標準 3:moduleOnly = False 時濾除數如實計入
  gsFilteredGenerated (cgStats gFull) @?= 1
  assertBool "decl nodes present" (any isDeclNode (cgNodes gFull))
  assertBool "instance node present"
    (any ((== InstanceNode) . gnKind) (cgNodes gFull))
  assertBool "contains edges present"
    (any ((== RContains) . geRelation) (cgEdges gFull))
  -- 兩者的 module 節點與 imports 邊完全相同
  moduleNodesOf (cgNodes gFull) @?= cgNodes gMod
  [e | e <- cgEdges gFull, geRelation e == RImports] @?= cgEdges gMod
  -- F003 就地更新:gFull 另有一筆「instance 的 class 在外部 module」的丟棄
  -- (Demo.Class);gMod 走規則 6 忽略 decl 層事實,故仍只有 Data.Text 一筆
  gsDroppedExternal (cgStats gFull) @?= 2
  gsDroppedExternal (cgStats gMod)  @?= 1
  gsTopExternalTargets (cgStats gFull) @?= [(T.pack "Data.Text", 1), (T.pack "Demo.Class", 1)]
  gsTopExternalTargets (cgStats gMod)  @?= [(T.pack "Data.Text", 1)]
  -- D5:混合節點與 relation 下 cgNodes / cgEdges 仍為全序
  assertBool "cgNodes sorted by NodeId"
    (let ids = map gnId (cgNodes gFull) in and (zipWith (<) ids (drop 1 ids)))
  assertBool "cgEdges sorted by (source, relation, target)"
    (let ks = map edgeTriple (cgEdges gFull) in and (zipWith (<) ks (drop 1 ks)))
  assertBool "moduleOnly output differs once decl facts exist" (gMod /= gFull)

-- F002 T7: 決定性 + C1 的 instance 全路徑
testDeclGraphDeterministic :: TestTree
testDeclGraphDeterministic = testGroup "test_decl_graph_deterministic"
  [ testCase "manual fact stream: pure and order-insensitive" $ do
      let g = graphFacts declFixtureMeta defBuildOpts moduleOnlyFacts
      graphFacts declFixtureMeta defBuildOpts moduleOnlyFacts @?= g
      graphFacts declFixtureMeta defBuildOpts (reverse moduleOnlyFacts) @?= g
      assertBool "warnings deduped and sorted"
        (cgWarnings g == nubOrd (sort (cgWarnings g)))
  , testCase "C1: instance-only stream walks the whole path" $ do
      let facts =
            [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
            , FactInstance (qn "Demo.Class" "Renderable" TypeNs)
                (T.pack "Renderable Sprite") "src/Demo/Core.hs" 40
            ]
          g = graphFacts (metaFor ["src/Demo/Core.hs"]) defBuildOpts facts
      map gnId (cgNodes g) @?=
        [nid "Demo.Core", nid "Demo.Core#i:Renderable Sprite"]
      map gnKind (cgNodes g) @?= [ModuleNode, InstanceNode]
      map edgeTriple (cgEdges g) @?=
        [(nid "Demo.Core", RContains, nid "Demo.Core#i:Renderable Sprite")]
      map geLine (cgEdges g) @?= [Just 40]
      -- 端到端恆 0 條 RImplements 是預期行為(C1),不是缺陷
      assertBool "no implements edge for an external class"
        (all ((/= RImplements) . geRelation) (cgEdges g))
      cgWarnings g @?= []
      -- F003 就地更新:Demo.Class 不在 gfInternal → 外部 class,依組裝規則 1
      -- 丟棄並計入統計(F002 撰寫時 RImplements 尚未實作,故原值為 zeroStats)
      cgStats g @?= zeroStats
        { gsDroppedExternal    = 1
        , gsTopExternalTargets = [(T.pack "Demo.Class", 1)]
        }
  , testProperty "random decl fact streams stay sorted and order-insensitive" $ property $ do
      rawNames <- forAll (Gen.list (Range.linear 1 4) genModName)
      let modSpecs =
            zipWith (\t i -> (ModuleName t, "src/F" <> show i <> ".hs"))
              rawNames [1 :: Int ..]
          modFacts = [FactModule f m | (m, f) <- modSpecs]
          intMods  = nubOrd (map fst modSpecs)
          pmPaths  = map snd modSpecs <> ["src/Extra.hs"]
          pm       = metaFor pmPaths
      declSpecs <- forAll (Gen.list (Range.linear 0 10) (genDeclSpec modSpecs))
      let declFacts = [FactDecl q ValueDecl False f ln | (q, f, ln) <- declSpecs]
          facts     = modFacts <> declFacts
          passes (_, f, ln) = f `elem` pmPaths && ln > 0
          filesMap  = Map.fromListWith Set.union
            [(m, Set.singleton f) | (m, f) <- modSpecs]
          modIds    = Set.fromList
            [mintModuleId m (disambiguate filesMap m f) | (m, f) <- modSpecs]
          expectedDeclIds = Set.fromList
            [ mintDeclId q (disambiguate filesMap (qnModule q) f)
            | d@(q, f, _) <- declSpecs
            , passes d
            , qnModule q `elem` intMods
            , mintModuleId (qnModule q) (disambiguate filesMap (qnModule q) f)
                `Set.member` modIds
            ]
          g = graphFacts pm defBuildOpts facts
      -- 規則 3:濾除數 == 檔案不在 pmSources 或行號 ≤ 0 的宣告筆數
      gsFilteredGenerated (cgStats g) === length (filter (not . passes) declSpecs)
      -- 節點集合 == module 節點 ∪ 通過閘門且 module 為內部的相異 decl id
      Set.fromList (map gnId (cgNodes g)) === Set.union modIds expectedDeclIds
      -- 每個 decl 節點恰一條 RContains
      length [e | e <- cgEdges g, geRelation e == RContains]
        === Set.size expectedDeclIds
      -- D5:輸出已排序
      cgNodes g === sortOn gnId (cgNodes g)
      cgEdges g === sortOn edgeTriple (cgEdges g)
      -- 不產懸空端點
      let ids = Set.fromList (map gnId (cgNodes g))
      assert (all (\e -> geSource e `Set.member` ids && geTarget e `Set.member` ids)
                (cgEdges g))
      -- 純函數 + 對事實序不敏感
      shuffled <- forAll (Gen.shuffle facts)
      graphFacts pm defBuildOpts shuffled === g
  ]

-- | 隨機宣告:module 取自內部組或一個保證外部的名字(genModName 恆大寫開頭,
-- 故小寫的 @zext@ 絕不相等);檔案混 pmSources 內外;行號混合法與非法。
genDeclSpec :: [(ModuleName, FilePath)] -> Gen (QualName, FilePath, Int)
genDeclSpec modSpecs = do
  (m, f)   <- Gen.element modSpecs
  external <- Gen.bool
  occ      <- Gen.element (map T.pack ["x", "y", "Foo", "name"])
  ns       <- Gen.element [ValueNs, DataConNs, TypeNs, FieldNs]
  file     <- Gen.element [f, "src/Extra.hs", "src/Absent.hs"]
  ln       <- Gen.element ([-1, 0] <> [1 .. 20])
  let owner = if external then ModuleName (T.pack "zext") else m
  pure (QualName { qnModule = owner, qnOcc = occ, qnSpace = ns }, file, ln)

--------------------------------------------------------------------------------
-- graph-core/F003 decl-edges
--------------------------------------------------------------------------------

-- | 委派決策 E3:本 group 一律用手工 @[Fact]@ 事實流 + 手工 'ProjectMeta',
-- 不依賴 hiedb、不讀 @.hie@、不 shell out。
graphCoreF003Tests :: TestTree
graphCoreF003Tests = testGroup "graph-core/F003 decl-edges"
  [ testDeclNodeIndex          -- T1
  , testRefEdgesCallsUses      -- T2
  , testRefModuleSourced       -- T3
  , testImplementsEdges        -- T4
  , testRefWarningsAggregated  -- T5
  , testDeclEdgeDedupeSelfloop -- T6
  , testDeclEdgesDeterministic -- T7
  ]

-- | 手工 @FactRef@ 捷徑。@frGenerated@ 恆 'False':批次澄清 C4 已在
-- fact-gate 濾除產生碼事實,本 feature 不重複過濾。
mkRef :: String -> Maybe QualName -> QualName -> FilePath -> Int -> Fact
mkRef from mdecl tgt file ln = FactRef (mn from) mdecl tgt False False file ln

-- | 只取 decl 層依賴邊(濾掉 F001 的 'RImports' 與 F002 的 'RContains')。
depEdges :: [GraphEdge] -> [GraphEdge]
depEdges es = [e | e <- es, geRelation e `elem` [RCalls, RUses, RImplements]]

-- | 批次澄清 C2 的 term\/type 二分,測試側獨立表述(四個值全覆蓋、無
-- catch-all)——與 @Knot.Graph.EdgeDerive@ 的 @relationOf@ 對帳。
relOfNs :: NameSpace -> Relation
relOfNs ValueNs   = RCalls
relOfNs DataConNs = RCalls
relOfNs FieldNs   = RCalls
relOfNs TypeNs    = RUses

-- F003 T1: 非契約面 declNodeIndex(F002 已實作,本條補齊 1-to-1 對照)
testDeclNodeIndex :: TestTree
testDeclNodeIndex = testCase "test_decl_node_index" $ do
  let facts =
        [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
        , FactModule "app/Main.hs" (mn "Main")
        , FactModule "test/Main.hs" (mn "Main")
        , FactDecl (qn "Demo.Core" "Foo" TypeNs) DataDecl False "src/Demo/Core.hs" 10
        , FactDecl (qn "Demo.Core" "Foo" DataConNs) DataDecl False "src/Demo/Core.hs" 10
        , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
        , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "app/Main.hs" 3
        , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "test/Main.hs" 4
        , FactDecl (qn "Ext.Pkg" "helper" ValueNs) ValueDecl False "src/Ext.hs" 7
        ]
      pm    = metaFor ["src/Demo/Core.hs", "app/Main.hs", "test/Main.hs", "src/Ext.hs"]
      gated = gateFacts pm facts
      nodes = mintNodes gated
      idx   = declNodeIndex gated nodes
  -- 每個 QualName 恰 1 筆,且 NodeId 與 mintDeclId 一致
  Map.lookup (qn "Demo.Core" "render" ValueNs) idx
    @?= Just [("src/Demo/Core.hs", mintDeclId (qn "Demo.Core" "render" ValueNs) Nothing)]
  -- 型別與值的 Foo 是兩個相異鍵、對到兩個相異 id
  Map.lookup (qn "Demo.Core" "Foo" TypeNs) idx
    @?= Just [("src/Demo/Core.hs", nid "Demo.Core.Foo#t")]
  Map.lookup (qn "Demo.Core" "Foo" DataConNs) idx
    @?= Just [("src/Demo/Core.hs", nid "Demo.Core.Foo")]
  assertBool "type and term Foo are two distinct keys"
    (Map.lookup (qn "Demo.Core" "Foo" TypeNs) idx
       /= Map.lookup (qn "Demo.Core" "Foo" DataConNs) idx)
  -- 組裝規則 1:qnModule 非內部的 FactDecl 不進索引
  Map.lookup (qn "Ext.Pkg" "helper" ValueNs) idx @?= Nothing
  -- D1 碰撞組:同一個鍵下 2 筆,FilePath 各自正確且值清單已排序
  let mainEntries = Map.findWithDefault [] (qn "Main" "main" ValueNs) idx
  mainEntries @?=
    [ ("app/Main.hs", nid "Main@app/Main.hs.main")
    , ("test/Main.hs", nid "Main@test/Main.hs.main")
    ]
  mainEntries @?= sort mainEntries
  -- 守門「查得到 ⇒ 節點存在」:抽掉某個節點後該鍵消失
  Map.lookup (qn "Demo.Core" "render" ValueNs)
    (declNodeIndex gated [n | n <- nodes, gnId n /= nid "Demo.Core.render"])
    @?= Nothing
  let allIds = Set.fromList (map gnId nodes)
  assertBool "every indexed NodeId exists as a node"
    (all (\(_, i) -> i `Set.member` allIds) (concat (Map.elems idx)))
  -- 規則 7:事實流重排序後索引完全相同
  let gatedR = gateFacts pm (reverse facts)
  declNodeIndex gatedR (mintNodes gatedR) @?= idx

-- | T2/T6 共用的來源宣告(@frFromDecl@ 的 @Just@ 分支)。
refFixtureRunQ :: Maybe QualName
refFixtureRunQ = Just (qn "Demo.App" "run" ValueNs)

-- | T2 樣本:四種 namespace 的目標各一筆(C2 全覆蓋)。
refFixtureFacts :: [Fact]
refFixtureFacts =
  [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactModule "src/Demo/App.hs" (mn "Demo.App")
  , FactDecl (qn "Demo.Core" "Foo" TypeNs) DataDecl False "src/Demo/Core.hs" 10
  , FactDecl (qn "Demo.Core" "Foo" DataConNs) DataDecl False "src/Demo/Core.hs" 10
  , FactDecl (qn "Demo.Core" "name" FieldNs) ValueDecl False "src/Demo/Core.hs" 11
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  , FactDecl (qn "Demo.App" "run" ValueNs) ValueDecl False "src/Demo/App.hs" 5
  , mkRef "Demo.App" refFixtureRunQ (qn "Demo.Core" "Foo" TypeNs) "src/Demo/App.hs" 6
  , mkRef "Demo.App" refFixtureRunQ (qn "Demo.Core" "render" ValueNs) "src/Demo/App.hs" 7
  , mkRef "Demo.App" refFixtureRunQ (qn "Demo.Core" "Foo" DataConNs) "src/Demo/App.hs" 8
  , mkRef "Demo.App" refFixtureRunQ (qn "Demo.Core" "name" FieldNs) "src/Demo/App.hs" 9
  ]

refFixtureMeta :: ProjectMeta
refFixtureMeta = metaFor ["src/Demo/Core.hs", "src/Demo/App.hs"]

-- F003 T2: FactRef 主線、C2 四分支、規則 1 與規則 4b 的統計歸屬
testRefEdgesCallsUses :: TestTree
testRefEdgesCallsUses = testCase "test_ref_edges_calls_uses" $ do
  let (edges, st, ws) = edgesWith refFixtureMeta refFixtureFacts
      deps = depEdges edges
  -- 驗收標準 1 + C2:三種 term namespace → RCalls、TypeNs → RUses
  map edgeTriple deps @?=
    [ (nid "Demo.App.run", RCalls, nid "Demo.Core.Foo")
    , (nid "Demo.App.run", RCalls, nid "Demo.Core.name")
    , (nid "Demo.App.run", RCalls, nid "Demo.Core.render")
    , (nid "Demo.App.run", RUses,  nid "Demo.Core.Foo#t")
    ]
  -- geLine == frLine;geSource 是 frFromDecl 對應的 decl 節點
  map geLine deps @?= [Just 8, Just 9, Just 7, Just 6]
  length [e | e <- deps, geRelation e == RCalls] @?= 3
  length [e | e <- deps, geRelation e == RUses]  @?= 1
  assertBool "no implements edge without FactInstance"
    (all ((/= RImplements) . geRelation) edges)
  esDroppedExternal st @?= 0
  esDeduped st @?= 0
  ws @?= []
  -- 規則 1:目標 module 非內部 → 不產邊、計入 esDroppedExternal 與 esTopExternal
  let (e2, st2, ws2) = edgesWith refFixtureMeta (refFixtureFacts <>
        [ mkRef "Demo.App" refFixtureRunQ (qn "Data.Text" "pack" ValueNs) "src/Demo/App.hs" 15
        , mkRef "Demo.App" refFixtureRunQ (qn "Data.Text" "Text" TypeNs) "src/Demo/App.hs" 16
        , mkRef "Demo.App" refFixtureRunQ (qn "Data.Map" "insert" ValueNs) "src/Demo/App.hs" 17
        ])
  depEdges e2 @?= deps
  esDroppedExternal st2 @?= 3
  esTopExternal st2 @?= [(mn "Data.Text", 2), (mn "Data.Map", 1)]
  ws2 @?= []
  -- 規則 4b:來源 module 非內部 → 不產邊,esDroppedExternal **不變**,彙整警告
  let (e3, st3, ws3) = edgesWith refFixtureMeta (refFixtureFacts <>
        [ mkRef "Zed" Nothing (qn "Demo.Core" "render" ValueNs) "src/Demo/App.hs" 21
        , mkRef "Zed" Nothing (qn "Demo.Core" "render" ValueNs) "src/Demo/App.hs" 22
        ])
  depEdges e3 @?= deps
  esDroppedExternal st3 @?= 0
  case ws3 of
    [w] -> do
      gwSource w @?= T.pack "src/Demo/App.hs"
      assertBool "reason names the non-internal referencing module"
        (T.pack "referencing module is not internal: Zed" `T.isInfixOf` gwMessage w)
      assertBool "aggregated ref count"
        (T.pack "2 ref edge(s) dropped" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws3)
  -- 假設 A2:4b 與規則 1 同時成立時 4b 先判(不先算成一次外部丟棄)
  let (_, st4, _) = edgesWith refFixtureMeta (refFixtureFacts <>
        [ mkRef "Zed" Nothing (qn "Data.Text" "pack" ValueNs) "src/Demo/App.hs" 23 ])
  esDroppedExternal st4 @?= 0

-- | T3 樣本:D1 碰撞組(兩個 @Main@)+ @frFromDecl@ 有無兩分支。
moduleSourcedFacts :: [Fact]
moduleSourcedFacts =
  [ FactModule "app/Main.hs" (mn "Main")
  , FactModule "test/Main.hs" (mn "Main")
  , FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactDecl (qn "Demo.Core" "Foo" TypeNs) DataDecl False "src/Demo/Core.hs" 10
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "app/Main.hs" 3
  , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "test/Main.hs" 4
  , mkRef "Main" Nothing (qn "Demo.Core" "render" ValueNs) "app/Main.hs" 12
  , mkRef "Main" Nothing (qn "Demo.Core" "Foo" TypeNs) "test/Main.hs" 13
  , mkRef "Main" (Just (qn "Main" "main" ValueNs))
      (qn "Demo.Core" "render" ValueNs) "test/Main.hs" 14
  ]

moduleSourcedMeta :: ProjectMeta
moduleSourcedMeta = metaFor ["app/Main.hs", "test/Main.hs", "src/Demo/Core.hs"]

-- F003 T3: frFromDecl 兩分支的來源解析(驗收標準 2 + 額外查證 1)
testRefModuleSourced :: TestTree
testRefModuleSourced = testCase "test_ref_module_sourced" $ do
  let (edges, st, ws) = edgesWith moduleSourcedMeta moduleSourcedFacts
      deps = depEdges edges
  -- frFromDecl = Nothing → 源是**來源 module 節點**;消歧組靠 (module, 檔案)
  -- 精確索引命中,兩筆各自落在自己的節點上;Just q 則以 frFile 收斂
  map edgeTriple deps @?=
    [ (nid "Main@app/Main.hs", RCalls, nid "Demo.Core.render")
    , (nid "Main@test/Main.hs", RUses, nid "Demo.Core.Foo#t")
    , (nid "Main@test/Main.hs.main", RCalls, nid "Demo.Core.render")
    ]
  map geLine deps @?= [Just 12, Just 13, Just 14]
  esDroppedExternal st @?= 0
  ws @?= []
  -- 假設 A8:來源解析不到(消歧組 + 第三個檔案)→ 0 條邊 + 彙整警告
  let (e2, st2, ws2) = edgesWith (metaFor ["src/B.hs", "src/Other.hs"])
        [ FactModule "src/A1.hs" (mn "A")
        , FactModule "src/A2.hs" (mn "A")
        , FactModule "src/B.hs" (mn "B")
        , FactDecl (qn "B" "x" ValueNs) ValueDecl False "src/B.hs" 2
        , mkRef "A" Nothing (qn "B" "x" ValueNs) "src/Other.hs" 4
        ]
  depEdges e2 @?= []
  esDroppedExternal st2 @?= 0
  case ws2 of
    [w] -> do
      gwSource w @?= T.pack "src/Other.hs"
      assertBool "reason flags the unresolved source"
        (T.pack "unresolved reference source" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws2)

-- | T4 樣本(C1:端到端恆 0 條 'RImplements',只能手工驗)。
-- class 定義在 @Demo.Class@、instance 宣告在 @Demo.Impl@ → 釘住 A3。
implementsFacts :: [Fact]
implementsFacts =
  [ FactModule "src/Demo/Class.hs" (mn "Demo.Class")
  , FactModule "src/Demo/Impl.hs" (mn "Demo.Impl")
  , FactDecl (qn "Demo.Class" "Renderable" TypeNs) ClassDecl False "src/Demo/Class.hs" 8
  , FactInstance (qn "Demo.Class" "Renderable" TypeNs) (T.pack "Renderable Sprite")
      "src/Demo/Impl.hs" 40
  ]

implementsMeta :: ProjectMeta
implementsMeta = metaFor ["src/Demo/Class.hs", "src/Demo/Impl.hs"]

-- F003 T4: FactInstance → RImplements(驗收標準 5)
testImplementsEdges :: TestTree
testImplementsEdges = testCase "test_implements_edges" $ do
  let (edges, st, ws) = edgesWith implementsMeta implementsFacts
  -- 驗收標準 5 前半:instance 節點 → class 型別節點,geLine == fiInstLine
  depEdges edges @?=
    [ GraphEdge (nid "Demo.Impl#i:Renderable Sprite")
        (nid "Demo.Class.Renderable#t") RImplements (Just 40) ]
  -- A3:instance 節點的 <mod-id> 由 fiInstFile 反查,不是 qnModule fiClass
  assertBool "instance endpoint never uses the class module"
    (all ((/= nid "Demo.Class#i:Renderable Sprite") . geSource) (depEdges edges))
  map edgeTriple edges @?=
    [ (nid "Demo.Class", RContains, nid "Demo.Class.Renderable#t")
    , (nid "Demo.Impl", RContains, nid "Demo.Impl#i:Renderable Sprite")
    , (nid "Demo.Impl#i:Renderable Sprite", RImplements, nid "Demo.Class.Renderable#t")
    ]
  esDroppedExternal st @?= 0
  ws @?= []
  -- 驗收標準 5 後半:class 的 module 為外部 → 0 條邊、計入統計
  let (e2, st2, ws2) = edgesWith (metaFor ["src/Demo/Impl.hs"])
        [ FactModule "src/Demo/Impl.hs" (mn "Demo.Impl")
        , FactInstance (qn "Ext.Class" "Show" TypeNs) (T.pack "Show Sprite")
            "src/Demo/Impl.hs" 40
        ]
  depEdges e2 @?= []
  esDroppedExternal st2 @?= 1
  esTopExternal st2 @?= [(mn "Ext.Class", 1)]
  ws2 @?= []
  -- class module 內部但沒有對應 FactDecl → 0 條邊 + 彙整警告
  let (e3, st3, ws3) = edgesWith implementsMeta
        [ FactModule "src/Demo/Class.hs" (mn "Demo.Class")
        , FactModule "src/Demo/Impl.hs" (mn "Demo.Impl")
        , FactInstance (qn "Demo.Class" "Renderable" TypeNs) (T.pack "Renderable Sprite")
            "src/Demo/Impl.hs" 40
        ]
  depEdges e3 @?= []
  esDroppedExternal st3 @?= 0
  case ws3 of
    [w] -> do
      gwSource w @?= T.pack "src/Demo/Impl.hs"
      assertBool "reason names the unresolved class"
        (T.pack "unresolved class Renderable" `T.isInfixOf` gwMessage w)
      assertBool "aggregated implements count"
        (T.pack "1 implements edge(s) dropped" `T.isInfixOf` gwMessage w)
    _ -> assertFailure ("expected exactly one warning, got: " <> show ws3)
  -- 假設 A4:來源端解析失敗時不另發警告(F002 的 RContains 支已發過一則)
  let (e4, _, ws4) = edgesWith (metaFor ["src/Demo/Class.hs", "src/Orphan.hs"])
        [ FactModule "src/Demo/Class.hs" (mn "Demo.Class")
        , FactDecl (qn "Demo.Class" "Renderable" TypeNs) ClassDecl False "src/Demo/Class.hs" 8
        , FactInstance (qn "Demo.Class" "Renderable" TypeNs) (T.pack "Renderable Sprite")
            "src/Orphan.hs" 5
        ]
  depEdges e4 @?= []
  map gwSource ws4 @?= [T.pack "src/Orphan.hs"]
  assertBool "only the F002 contains warning, no duplicate implements warning"
    (all ((T.pack "no contains edge" `T.isInfixOf`) . gwMessage) ws4)

-- | T5 樣本:同一檔內三種相異跳過原因 + 一個相異檔。
refWarnFacts :: [Fact]
refWarnFacts =
  [ FactModule "src/A.hs" (mn "A")
  , FactModule "src/B.hs" (mn "B")
  , FactModule "app/Main.hs" (mn "Main")
  , FactModule "test/Main.hs" (mn "Main")
  , FactDecl (qn "A" "f" ValueNs) ValueDecl False "src/A.hs" 1
  , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "app/Main.hs" 3
  , FactDecl (qn "Main" "main" ValueNs) ValueDecl False "test/Main.hs" 4
  ]
  <> [mkRef "A" Nothing (qn "B" "g" ValueNs) "src/A.hs" ln | ln <- [10 .. 14]]
  <> [ mkRef "A" Nothing (qn "Main" "main" ValueNs) "src/A.hs" 20
     , mkRef "A" (Just (qn "A" "ghost" ValueNs)) (qn "A" "f" ValueNs) "src/A.hs" 21
     , mkRef "B" Nothing (qn "B" "g" ValueNs) "src/B.hs" 30
     ]

refWarnMeta :: ProjectMeta
refWarnMeta = metaFor ["src/A.hs", "src/B.hs", "app/Main.hs", "test/Main.hs"]

-- F003 T5: 警告彙整(驗收標準 6:不靜默、不刷屏)
testRefWarningsAggregated :: TestTree
testRefWarningsAggregated = testCase "test_ref_warnings_aggregated" $ do
  let (edges, st, ws) = edgesWith refWarnMeta refWarnFacts
  depEdges edges @?= []
  esDroppedExternal st @?= 0
  -- 同一檔 5 筆同因 → **1 則**帶筆數的警告;三種相異原因各自成鍵不被合併;
  -- 相異檔各自一則 → 共 4 則
  map (\w -> (gwSource w, gwMessage w)) ws @?=
    [ ( T.pack "src/A.hs"
      , T.pack "ambiguous reference target main (2 candidate nodes); 1 ref edge(s) dropped" )
    , ( T.pack "src/A.hs"
      , T.pack "unresolved reference source for f; 1 ref edge(s) dropped" )
    , ( T.pack "src/A.hs"
      , T.pack "unresolved reference target g; 5 ref edge(s) dropped" )
    , ( T.pack "src/B.hs"
      , T.pack "unresolved reference target g; 1 ref edge(s) dropped" )
    ]
  -- 決定性:事實流重排序後警告清單完全相同
  let (_, _, wsR) = edgesWith refWarnMeta (reverse refWarnFacts)
  wsR @?= ws
  -- 不改 imports 邊行為:解析失敗的 import 仍為**逐筆**格式
  let (_, _, wsImp) = edgesOf
        [ FactModule "src/B.hs" (mn "B")
        , FactImport (mn "Zed") (mn "B") "src/Z.hs" 4
        , FactImport (mn "Zed") (mn "B") "src/Z.hs" 5
        ]
  length wsImp @?= 2
  assertBool "import warnings stay per-item"
    (all ((T.pack "import edge dropped at line" `T.isInfixOf`) . gwMessage) wsImp)

-- | T6 樣本:imports + contains + calls 混合、同一對 decl 四筆亂序 ref、遞迴、
-- 一筆會被組裝規則 3 濾除的宣告。
dedupeFacts :: [Fact]
dedupeFacts =
  [ FactModule "src/Demo/Core.hs" (mn "Demo.Core")
  , FactModule "src/Demo/App.hs" (mn "Demo.App")
  , FactImport (mn "Demo.App") (mn "Demo.Core") "src/Demo/App.hs" 2
  , FactImport (mn "Demo.App") (mn "Data.Text") "src/Demo/App.hs" 3
  , FactDecl (qn "Demo.Core" "render" ValueNs) ValueDecl False "src/Demo/Core.hs" 20
  , FactDecl (qn "Demo.App" "run" ValueNs) ValueDecl False "src/Demo/App.hs" 5
  , FactDecl (qn "Demo.Core" "generated" ValueNs) ValueDecl False "src/Demo/Core.hs" 0
  ]
  <> [ mkRef "Demo.App" refFixtureRunQ (qn "Demo.Core" "render" ValueNs)
         "src/Demo/App.hs" ln
     | ln <- [40, 12, 25, 33] ]
  <> [ mkRef "Demo.App" refFixtureRunQ (qn "Demo.App" "run" ValueNs) "src/Demo/App.hs" 15 ]

dedupeMeta :: ProjectMeta
dedupeMeta = metaFor ["src/Demo/Core.hs", "src/Demo/App.hs"]

-- F003 T6: 去重(驗收標準 4)、自環(驗收標準 3)、D5 排序與規則 6
testDeclEdgeDedupeSelfloop :: TestTree
testDeclEdgeDedupeSelfloop = testCase "test_decl_edge_dedupe_selfloop" $ do
  let gFull = graphFacts dedupeMeta defBuildOpts dedupeFacts
  -- 驗收標準 4:同一對 decl 的 4 筆 ref 合併為 1 條、geLine 取最早行
  -- 驗收標準 3:遞迴呼叫不產邊
  map edgeTriple (cgEdges gFull) @?=
    [ (nid "Demo.App", RImports, nid "Demo.Core")
    , (nid "Demo.App", RContains, nid "Demo.App.run")
    , (nid "Demo.App.run", RCalls, nid "Demo.Core.render")
    , (nid "Demo.Core", RContains, nid "Demo.Core.render")
    ]
  map geLine (cgEdges gFull) @?= [Just 2, Just 5, Just 12, Just 20]
  gsDedupedEdges (cgStats gFull) @?= 3
  gsDroppedExternal (cgStats gFull) @?= 1
  gsFilteredGenerated (cgStats gFull) @?= 1
  cgWarnings gFull @?= []           -- 自環不發警告、不計統計
  -- D5:混合三種 relation 下 cgEdges 依 (source, relation, target) 遞增
  assertBool "cgEdges sorted by (source, relation, target)"
    (let ks = map edgeTriple (cgEdges gFull) in and (zipWith (<) ks (drop 1 ks)))
  -- 去重鍵含 relation:同一對端點的 RCalls 與 RContains 不被誤併
  let (e2, st2, ws2) = edgesWith (metaFor ["src/A.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "x" ValueNs) ValueDecl False "src/A.hs" 5
        , mkRef "A" Nothing (qn "A" "x" ValueNs) "src/A.hs" 9
        ]
  map edgeTriple e2 @?= [(nid "A", RCalls, nid "A.x"), (nid "A", RContains, nid "A.x")]
  map geLine e2 @?= [Just 9, Just 5]
  esDeduped st2 @?= 0
  ws2 @?= []
  -- 純自環事實流:不產邊、不計統計、不發警告
  let (e3, st3, ws3) = edgesWith (metaFor ["src/A.hs"])
        [ FactModule "src/A.hs" (mn "A")
        , FactDecl (qn "A" "loop" ValueNs) ValueDecl False "src/A.hs" 5
        , mkRef "A" (Just (qn "A" "loop" ValueNs)) (qn "A" "loop" ValueNs) "src/A.hs" 6
        , mkRef "A" (Just (qn "A" "loop" ValueNs)) (qn "A" "loop" ValueNs) "src/A.hs" 7
        ]
  depEdges e3 @?= []
  esDroppedExternal st3 @?= 0
  esDeduped st3 @?= 0
  ws3 @?= []
  -- 規則 6:moduleOnly = True → 邊全為 RImports、零 decl 層邊、統計不受影響
  let gMod = graphFacts dedupeMeta (BuildOptions { moduleOnly = True }) dedupeFacts
  forM_ (cgEdges gMod) $ \e -> geRelation e @?= RImports
  assertBool "no calls/uses/implements under moduleOnly"
    (null (depEdges (cgEdges gMod)))
  gsFilteredGenerated (cgStats gMod) @?= 0
  gsDedupedEdges (cgStats gMod) @?= 0

-- F003 T7: 決定性與規模對帳(E3:全程手工事實流)
testDeclEdgesDeterministic :: TestTree
testDeclEdgesDeterministic = testGroup "test_decl_edges_deterministic"
  [ testCase "manual fact streams: pure and order-insensitive" $ do
      forM_ [ (refFixtureMeta, refFixtureFacts)
            , (moduleSourcedMeta, moduleSourcedFacts)
            , (implementsMeta, implementsFacts)
            , (refWarnMeta, refWarnFacts)
            , (dedupeMeta, dedupeFacts)
            ] $ \(pm, facts) -> do
        let g = graphFacts pm defBuildOpts facts
        graphFacts pm defBuildOpts facts @?= g
        graphFacts pm defBuildOpts (reverse facts) @?= g
  , testProperty "random ref fact streams stay sorted and order-insensitive" $ property $ do
      rawNames <- forAll (Gen.list (Range.linear 1 4) genModName)
      let names    = nubOrd rawNames
          modSpecs = zipWith (\t i -> (ModuleName t, "src/F" <> show i <> ".hs"))
                       names [1 :: Int ..]
          intMods  = map fst modSpecs
          fileOf m = Map.findWithDefault "" m (Map.fromList modSpecs)
          modFacts = [FactModule f m | (m, f) <- modSpecs]
          pm       = metaFor (map snd modSpecs)
      declQs <- fmap nubOrd (forAll (Gen.list (Range.linear 0 8) (genDeclQName modSpecs)))
      refSpecs <- forAll (Gen.list (Range.linear 0 20) (genRefSpec modSpecs declQs))
      impPairs <- forAll (Gen.list (Range.linear 0 6)
                    (genImportPair intMods [ModuleName (T.pack "zimp")]))
      let declFacts = [FactDecl q ValueDecl False (fileOf (qnModule q)) 7 | q <- declQs]
          refFacts  = [FactRef from mdecl tgt False False file ln
                      | (from, mdecl, tgt, file, ln) <- refSpecs]
          impFacts  = [FactImport from to (fileOf from) ln | (from, to, ln) <- impPairs]
          facts     = modFacts <> declFacts <> refFacts <> impFacts
          g         = graphFacts pm defBuildOpts facts
          declSet   = Set.fromList declQs
          modIdOf m = mintModuleId m Nothing
          -- 來源:frFromDecl = Nothing → module 節點;Just q → decl 節點
          srcIdOf (from, mdecl, _, _, _) = case mdecl of
            Nothing -> modIdOf from
            Just q  -> mintDeclId q Nothing
          -- 目標:內部才實化,relation 由 C2 的 term/type 二分決定
          refTriples = Set.fromList
            [ (srcIdOf r, relOfNs (qnSpace tgt), mintDeclId tgt Nothing)
            | r@(_, _, tgt, _, _) <- refSpecs
            , tgt `Set.member` declSet
            , srcIdOf r /= mintDeclId tgt Nothing
            ]
          containsTriples = Set.fromList
            [(modIdOf (qnModule q), RContains, mintDeclId q Nothing) | q <- declQs]
          importTriples = Set.fromList
            [ (modIdOf from, RImports, modIdOf to)
            | (from, to, _) <- impPairs, to `elem` intMods, from /= to
            ]
          allTriples = Set.unions [refTriples, containsTriples, importTriples]
          externalRefs = length [() | (_, _, tgt, _, _) <- refSpecs
                                    , tgt `Set.notMember` declSet]
          externalImps = length [() | (_, to, _) <- impPairs, to `notElem` intMods]
      -- 邊數 == 相異非自環三元組數;三種 relation 各自對帳
      Set.fromList (map edgeTriple (cgEdges g)) === allTriples
      length (cgEdges g) === Set.size allTriples
      length [e | e <- cgEdges g, geRelation e == RCalls]
        === Set.size (Set.filter (\(_, r, _) -> r == RCalls) allTriples)
      length [e | e <- cgEdges g, geRelation e == RUses]
        === Set.size (Set.filter (\(_, r, _) -> r == RUses) allTriples)
      -- 端到端無 FactInstance → 0 條 RImplements(C1)
      length [e | e <- cgEdges g, geRelation e == RImplements] === 0
      -- 規則 1:外部目標的 ref 與 import 全數計入,一筆不漏
      gsDroppedExternal (cgStats g) === externalRefs + externalImps
      -- D5:輸出已排序
      cgNodes g === sortOn gnId (cgNodes g)
      cgEdges g === sortOn edgeTriple (cgEdges g)
      -- 不產懸空端點
      let ids = Set.fromList (map gnId (cgNodes g))
      assert (all (\e -> geSource e `Set.member` ids && geTarget e `Set.member` ids)
                (cgEdges g))
      -- 純函數 + 對事實序不敏感
      shuffled <- forAll (Gen.shuffle facts)
      graphFacts pm defBuildOpts shuffled === g
  ]

-- | 隨機頂層宣告名:module 取自內部組,namespace 混四種。
genDeclQName :: [(ModuleName, FilePath)] -> Gen QualName
genDeclQName modSpecs = do
  (m, _) <- Gen.element modSpecs
  occ    <- Gen.element (map T.pack ["x", "y", "Foo", "name"])
  ns     <- Gen.element [ValueNs, DataConNs, TypeNs, FieldNs]
  pure QualName { qnModule = m, qnOcc = occ, qnSpace = ns }

-- | 隨機引用:來源恆為內部 module 且 @frFile@ 恆為該 module 的來源檔
-- (對應 extraction @refFactsOf@ 的 @(frFromModule, frFile)@ 必然配對);
-- @frFromDecl@ 混有無(有的話取同 module 的宣告),目標混內部與外部。
genRefSpec
  :: [(ModuleName, FilePath)] -> [QualName]
  -> Gen (ModuleName, Maybe QualName, QualName, FilePath, Int)
genRefSpec modSpecs declQs = do
  (m, file) <- Gen.element modSpecs
  let own = [q | q <- declQs, qnModule q == m]
  mdecl <- if null own
             then pure Nothing
             else Gen.choice [pure Nothing, Just <$> Gen.element own]
  occ <- Gen.element (map T.pack ["x", "y", "Foo", "name"])
  ns  <- Gen.element [ValueNs, DataConNs, TypeNs, FieldNs]
  ln  <- Gen.int (Range.linear 1 40)
  let ext = QualName { qnModule = ModuleName (T.pack "zext"), qnOcc = occ, qnSpace = ns }
  tgt <- if null declQs then pure ext else Gen.choice [pure ext, Gen.element declQs]
  pure (m, mdecl, tgt, file, ln)

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
  statsNotes (GraphStats 12 [(T.pack "Data.Text", 7), (T.pack "Data.Map", 4)] 0 3)
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
        { cgStats = GraphStats 4 [(T.pack "Data.Text", 3)] 0 2 }
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

-- | 十個欄位皆為預設的 'ExtractCmd'(測試各自只改需要的欄位)。
baseExtractCmd :: ExtractCmd
baseExtractCmd = ExtractCmd
  { ecPath         = "."
  , ecOutput       = Nothing
  , ecBackend      = Auto
  , ecModuleOnly   = False
  , ecIncludeTests = False
  , ecHieDir       = Nothing
  , ecHiedbExe     = Nothing
  , ecDbPath       = Nothing
  , ecStrict       = False
  , ecSummary      = Nothing
  }

-- | 十個欄位皆非預設的 'ExtractCmd'(對映斷言的來源)。
fullExtractCmd :: ExtractCmd
fullExtractCmd = ExtractCmd
  { ecPath         = "proj"
  , ecOutput       = Just "x.json"
  , ecBackend      = ImportsOnly
  , ecModuleOnly   = True
  , ecIncludeTests = True
  , ecHieDir       = Just "dist/hie"
  , ecHiedbExe     = Just "C:/tools/hiedb.exe"
  , ecDbPath       = Just "/tmp/idx.sqlite"
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
  -- 全給定:十個欄位逐一等於預期值
  full <- expectExtractCmd
    [ "extract", "proj", "-o", "x.json", "--backend", "imports"
    , "--module-only", "--include-tests", "--hiedir", "dist/hie"
    , "--hiedb", "C:/tools/hiedb.exe", "--db", "/tmp/idx.sqlite", "--strict"
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
  -- extraction/F004 前置 2:兩個旗標已補接,逐字透傳(不再寫死 Nothing)
  hiedbExe xo @?= Just "C:/tools/hiedb.exe"
  dbPath xo @?= Just "/tmp/idx.sqlite"
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


--------------------------------------------------------------------------------
-- G-E003 產生碼過濾的對稱化(跨 extraction + graph-core)
--------------------------------------------------------------------------------

globalE003Tests :: TestTree
globalE003Tests = testGroup "global/G-E003 generated-decl-filter"
  [ testGeneratedFilterSelfcheck   -- T6
  ]

-- | G-E003 T6:對 knot-hs 自身唯讀實跑,逐一釘住四個量化目標。
--
-- 需要 hiedb 與自身的 @.hie@;缺任一就印明原因跳過(ADR-002 的降級原則,
-- 比照 'testHiedbFactsSelfcheck')。
testGeneratedFilterSelfcheck :: TestTree
testGeneratedFilterSelfcheck = testCase "test_generated_filter_selfcheck" $ do
  pm <- loadProjectMeta (defOpts ".")
  case pmHie pm of
    Just hie | not (null (hieFiles hie)) -> do
      knotBefore <- doesDirectoryExist ".knot"
      tmp <- getTemporaryDirectory
      let db = tmp </> "knot-hs-ge003-self" </> "self.sqlite"
      removePathForcibly (takeDirectory db)
      res <- extract ((extOpts Auto) { XT.rootDir = ".", XT.dbPath = Just db }) pm
      if erLevel res /= DeclLevel
        then putStrLn
          "[skip] test_generated_filter_selfcheck: hiedb unavailable, no decl layer"
        else do
          let g = buildGraph defBuildOpts pm res
              dollarNodes = [ t | NodeId t <- map gnId (cgNodes g)
                            , T.pack "$" `T.isInfixOf` t ]
              dollarEdges = [ ()
                            | e <- cgEdges g
                            , let NodeId s = geSource e
                            , let NodeId t = geTarget e
                            , T.pack "$" `T.isInfixOf` s
                                || T.pack "$" `T.isInfixOf` t ]
              unresolved  = [ gwMessage w
                            | w <- cgWarnings g
                            , hasText "unresolved reference target $" (gwMessage w) ]
          -- 目標 1:deriving 字典不再成為節點
          assertBool ("generated dictionary nodes leaked into the graph: "
                       <> show (take 5 dollarNodes)) (null dollarNodes)
          [] @?= dollarEdges
          -- 目標 2:同源的 unresolved 警告歸零
          assertBool ("unresolved $-target warnings remain: " <> show (take 5 unresolved))
            (null unresolved)
          -- 目標 4:決定性——同一份事實流兩次組裝完全相同
          buildGraph defBuildOpts pm res @?= g
          -- 目標 3:兩種 hiedb 索引建法(走目錄 vs 逐檔清單)產出的圖相同。
          -- 走目錄會多收 8 個 deriving 字典的 defs 列(逐檔清單收不到),
          -- 過濾對稱化之後那 8 筆兩邊都被濾掉,節點與邊必須逐一相等。
          -- 前提:.hie 目錄只含納入範圍內的 module。若含範圍外者(例如以
          -- --enable-tests 產生時的 test-suite Main),`hiedb index <目錄>`
          -- 會把測試檔裡的記錄欄位**使用**收成 library 選擇器的 defs 列、
          -- 行號指到測試檔(實測 Knot.Export.Types.rootDir 被標成 L4482,
          -- 該檔只有 38 行)→ 兩法必然不同。那是 G-B002 的獨立缺陷,不在
          -- 本檢查的前提內,故明示跳過而非放寬斷言。
          let outOfScope =
                [ w | w <- erWarnings res
                , hasText "cannot map indexed module" (ewMessage w) ]
          mExe <- findExecutable "hiedb"
          if not (null outOfScope)
            then putStrLn ("[skip] G-E003 目標 3(兩種索引建法比對):.hie 含 "
                    <> show (length outOfScope)
                    <> " 個納入範圍外的 module,走目錄索引會被污染,見 G-B002")
            else forM_ mExe $ \exe -> do
              let dirDb = tmp </> "knot-hs-ge003-self" </> "dir.sqlite"
              (code, _, _) <- readProcessWithExitCode exe
                ["-D", dirDb, "--src-base-dir", ".", "index", hieDir hie] ""
              code @?= ExitSuccess
              resDir <- extract
                ((extOpts Auto) { XT.rootDir = ".", XT.dbPath = Just dirDb }) pm
              let gDir = buildGraph defBuildOpts pm resDir
              cgNodes gDir @?= cgNodes g
              cgEdges gDir @?= cgEdges g
          -- 唯讀驗收:目標專案內不得新建 .knot/
          doesDirectoryExist ".knot" >>= (@?= knotBefore)
          putStrLn ("[selfcheck/G-E003] nodes=" <> show (length (cgNodes g))
            <> " edges=" <> show (length (cgEdges g))
            <> " filteredGenerated=" <> show (gsFilteredGenerated (cgStats g))
            <> " warnings=" <> show (length (cgWarnings g)))
      removePathForcibly (takeDirectory db)
    _ -> putStrLn
      "[skip] test_generated_filter_selfcheck: knot-hs itself has no .hie files \
      \(build with -fwrite-ide-info -hiedir .hie to enable this check)"

--------------------------------------------------------------------------------
-- G-E001 內部邊界收斂(跨 project-meta + extraction + graph-core + export-query)
--------------------------------------------------------------------------------

globalE001Tests :: TestTree
globalE001Tests = testGroup "global/G-E001 internal-test-exports"
  [ testCabalContractSurface       -- T1
  , testDefaultOutputPathHome      -- T2
  , testModuleSuffixRuleAgrees     -- T3
  , testGraphStatsTopExternalText  -- T4
  , testDiscoveryCabalLessDir      -- T5
  , testDesignDocsMatchGraphStats  -- T6
  , testAppImportsWithinContract   -- T7
  , testCodegraphOutputUnchanged   -- 全體回歸
  ]

-- | Level 2 契約面:公開 library 恰好 reexport 這 9 個模組(→ ADR-004)。
contractModules :: [Text]
contractModules = map T.pack
  [ "Knot.Export"
  , "Knot.Export.Types"
  , "Knot.Extract"
  , "Knot.Extract.Types"
  , "Knot.Graph"
  , "Knot.Graph.Types"
  , "Knot.Meta"
  , "Knot.Meta.Types"
  , "Knot.Query"
  ]

-- | 從 @.cabal@ 原文抓某欄位的項目清單。本檔的 @exposed-modules@ 與
-- @reexported-modules@ 各只出現一次,故不必追 stanza:取欄位行的值,
-- 再吃掉後續「有縮排、不含冒號、非註解」的接續行。
cabalFieldItems :: Text -> String -> [Text]
cabalFieldItems src field =
  case dropWhile (not . isField) (T.lines src) of
    []         -> []
    (l : rest) ->
      let headPart = T.drop 1 (T.dropWhile (/= ':') l)
      in [ item
         | raw <- T.words (T.unwords (headPart : takeWhile isCont rest))
         , let item = T.filter (/= ',') raw
         , not (T.null item)
         ]
 where
  isField ln = (T.pack field <> T.pack ":") `T.isPrefixOf` T.stripStart ln
  isCont ln =
    let s = T.strip ln
    in not (T.null s)
         && T.pack " " `T.isPrefixOf` ln
         && not (T.pack "--" `T.isPrefixOf` s)
         && not (T.any (== ':') s)

-- | G-E001 T1:公開面就是契約面,一個不多一個不少。
--
-- 這條擋的是「有人為了省事把某個內部模組加進 reexported-modules」——
-- GHC-87110 只在有人真的去 import 時才發作,這裡在清單層先擋一次。
testCabalContractSurface :: TestTree
testCabalContractSurface = testCase "test_cabal_contract_surface" $ do
  src <- readUtf8 "knot-hs.cabal"
  let reexported = cabalFieldItems src "reexported-modules"
      exposed    = cabalFieldItems src "exposed-modules"
      private    = [m | m <- exposed, m `notElem` contractModules]
  -- 公開面恰為契約模組(排序後逐字比對,順序不影響判定)
  sort reexported @?= sort contractModules
  -- 內部 library 收全部 26 個模組
  length exposed @?= 26
  -- 每個被 reexport 的模組都真的存在於內部 library
  assertBool ("reexported modules missing from knot-internal: "
               <> show [m | m <- reexported, m `notElem` exposed])
    (all (`elem` exposed) reexported)
  -- 17 個內部模組一個都不得出現在公開面
  length private @?= 17
  assertBool ("internal modules leaked into the public surface: "
               <> show [m | m <- private, m `elem` reexported])
    (not (any (`elem` reexported) private))

-- | G-E001 T2:@defaultOutputPath@ 的家在組裝層,不在 library 契約模組。
testDefaultOutputPathHome :: TestTree
testDefaultOutputPathHome = testCase "test_default_output_path_home" $ do
  -- 行為與搬遷前一字不差
  defaultOutputPath "proj" @?= "proj" </> "codegraph.json"
  defaultOutputPath "." @?= "." </> "codegraph.json"
  -- F004 既有分工不變:--output 未給時 toExportOptions 取這個預設值(回歸)
  let cmd = baseExtractCmd { ecPath = graphFixture, ecOutput = Nothing }
  ET.outputPath (toExportOptions cmd) @?= defaultOutputPath graphFixture
  -- 已從 library 契約模組移除(公開面漂移防護)。
  -- 只擋「定義 / 匯出」,不擋 Haddock 的限定交叉引用——後者是有價值的線索。
  types <- readUtf8 "src/Knot/Export/Types.hs"
  let mentions = [ln | ln <- T.lines types, hasText "defaultOutputPath" ln]
  assertBool ("Knot.Export.Types must not define defaultOutputPath: " <> show mentions)
    (not (any (hasText "defaultOutputPath ::") mentions))
  assertBool ("only qualified cross-references may remain: " <> show mentions)
    (all (hasText "Knot.App.Cli.defaultOutputPath") mentions)

-- | G-E001 T3:@.hs@ 與 @.hie@ 兩條尾綴規則等價(去重後只剩一份實作)。
testModuleSuffixRuleAgrees :: TestTree
testModuleSuffixRuleAgrees = testGroup "test_module_suffix_rule_agrees"
  [ testCase "既有具體案例兩邊一致" $ do
      moduleNameFromPath "src/Demo/Core.hs" @?= moduleNameFromHiePath "src/Demo/Core.hie"
      moduleNameFromPath "Foo.hs"           @?= moduleNameFromHiePath "Foo.hie"
      moduleNameFromPath "src/lowercase/util.hs"
        @?= moduleNameFromHiePath "src/lowercase/util.hie"
  , testProperty "隨機路徑上兩條規則恆等" $ property $ do
      lower <- forAll (Gen.list (Range.linear 0 3)
                        (Gen.string (Range.linear 1 6) Gen.lower))
      upper <- forAll (Gen.list (Range.linear 1 3)
                        ((:) <$> Gen.upper <*> Gen.string (Range.linear 0 5) Gen.alpha))
      let base = concatMap (<> "/") lower <> intercalate "/" upper
      moduleNameFromPath (base <> ".hs") === moduleNameFromHiePath (base <> ".hie")
  , testProperty "末段非大寫時兩邊同為 Nothing" $ property $ do
      seg <- forAll (Gen.string (Range.linear 1 6) Gen.lower)
      let base = "src/" <> seg
      moduleNameFromPath (base <> ".hs") === Nothing
      moduleNameFromHiePath (base <> ".hie") === Nothing
  ]

-- | G-E001 T4:公開 DTO 不再透出上游型別,且行為零變更。
testGraphStatsTopExternalText :: TestTree
testGraphStatsTopExternalText = testCase "test_graph_stats_top_external_text" $ do
  -- (a) 欄位是 Text;摘要行輸出與型別變更前逐字相同(回歸)
  let st = GraphStats 12 [(T.pack "Data.Text", 7), (T.pack "Data.Map", 4)] 0 3
  statsNotes st @?= map T.pack
    [ "dropped external edges: 12"
    , "filtered generated facts: 0"
    , "deduped edges: 3"
    , "top external target: Data.Text (7)"
    , "top external target: Data.Map (4)"
    ]
  -- (b) 組裝層的圖摘要同樣不變
  let cg = CodeGraph { cgNodes = [], cgEdges = [], cgStats = st, cgWarnings = [] }
  assertHasAll "graph summary top lines" (renderGraphSummary cg)
    ["  X Data.Text 7", "  X Data.Map 4"]
  -- (c) 驗收標準 4:export-query 的 library 不得再跨段 import 上游子系統
  forM_ ["src/Knot/Export/Encode.hs", "src/Knot/Export.hs", "src/Knot/Export/Types.hs"
        , "src/Knot/Export/Commit.hs"] $ \f -> do
    body <- readUtf8 f
    assertBool (f <> " must not import project-meta directly (topology bypass)")
      (not (hasText "import Knot.Meta" body))
  -- graph-core 的公開 DTO 模組同理:不得再認識 ModuleName
  gt <- readUtf8 "src/Knot/Graph/Types.hs"
  assertBool "Knot.Graph.Types must not import Knot.Meta.Types any more"
    (not (hasText "import Knot.Meta" gt))

-- | G-E001 T5:cabal.project 列的目錄存在卻沒有 @.cabal@ 時不再靜默貢獻零。
testDiscoveryCabalLessDir :: TestTree
testDiscoveryCabalLessDir = testCase "test_discovery_cabal_less_dir" $
  withExportDir "ge001-discovery" $ \dir -> do
    let mkProject field = do
          removePathForcibly (dir </> "p")
          createDirectoryIfMissing True (dir </> "p" </> "pkg-x")
          writeUtf8 (dir </> "p" </> "cabal.project") (field <> ": pkg-x\n")
          writeUtf8 (dir </> "p" </> "pkg-x" </> "Lib.hs") "module Lib where\n"
          findCabalFiles (dir </> "p")
        emptyDirMsg = "listed package directory contains no .cabal file"
    -- packages:目錄存在但無 .cabal → per-entry 警告 + 既有的總結警告
    (foundP, wsP) <- mkProject "packages"
    foundP @?= []
    assertBool ("packages entry should warn, got: " <> show (map mwMessage wsP))
      (any (hasText emptyDirMsg . mwMessage) wsP)
    length wsP @?= 2
    -- optional-packages:沿用「optional 缺項靜默」的既有慣例,只留總結警告
    (foundO, wsO) <- mkProject "optional-packages"
    foundO @?= []
    assertBool ("optional-packages entry must stay silent, got: "
                 <> show (map mwMessage wsO))
      (not (any (hasText emptyDirMsg . mwMessage) wsO))
    length wsO @?= 1

-- | G-E001 T6:架構文件與程式碼對同一個契約欄位的敘述不得漂移。
testDesignDocsMatchGraphStats :: TestTree
testDesignDocsMatchGraphStats = testCase "test_design_docs_match_graph_stats" $ do
  code <- readUtf8 "src/Knot/Graph/Types.hs"
  doc  <- readUtf8 ".design/subsystems/graph-core/design.md"
  let fieldType = "gsTopExternalTargets :: [(Text, Int)]"
      staleType = "gsTopExternalTargets :: [(ModuleName, Int)]"
  assertBool ("code should declare " <> show fieldType) (hasText fieldType code)
  assertBool ("graph-core/design.md should declare " <> show fieldType)
    (hasText fieldType doc)
  assertBool "graph-core/design.md still carries the pre-G-E001 type"
    (not (hasText staleType doc))

-- | G-E001 T7:組裝層只碰得到契約模組。
--
-- GHC-87110 只在建置 executable 時才發作,而 test-suite 依賴的是內部
-- library——這條測試補上那個空窗,讓違規在測試階段就現形。
testAppImportsWithinContract :: TestTree
testAppImportsWithinContract = testCase "test_app_imports_within_contract" $ do
  pm <- loadProjectMeta (defOpts ".")
  let appFiles = [sfPath sf | sf <- pmSources pm, "app/" `isPrefixOf` sfPath sf]
  assertBool "app/ sources should be discoverable" (not (null appFiles))
  forM_ appFiles $ \f -> do
    body <- readUtf8 f
    let imported =
          [ m
          | ln <- T.lines body
          , T.pack "import " `T.isPrefixOf` ln
          , m <- take 1 (filter (T.pack "Knot." `T.isPrefixOf`)
                                (T.words (T.drop 7 ln)))
          ]
        offenders =
          [ m | m <- imported
          , not (T.pack "Knot.App." `T.isPrefixOf` m)
          , m `notElem` contractModules ]
    assertBool (f <> " imports non-contract modules: " <> show offenders)
      (null offenders)

-- | 黃金檔涵蓋的 fixture 專案(以 @test\/fixtures\/golden\/\<name\>.json@ 對應)。
goldenFixtures :: [FilePath]
goldenFixtures = ["comps", "graph", "multi", "no-cabal", "proj"]

-- | G-E001 全體回歸:四站管線的 byte 級輸出必須與變更前的黃金檔完全相同。
--
-- 黃金檔取自 G-E001 動工前的建置產出,釘住 Scope 的「不改任何演算法行為」。
-- 固定走 import-scan 後端(結果不隨 hiedb 是否安裝而變)、commit 傳
-- 'Nothing'(不跑 git,黃金檔才不隨 HEAD 漂移)。
testCodegraphOutputUnchanged :: TestTree
testCodegraphOutputUnchanged = testCase "test_codegraph_output_unchanged" $
  forM_ goldenFixtures $ \name -> do
    let root   = "test/fixtures" </> name
        golden = "test/fixtures/golden" </> (name <> ".json")
    pm <- loadProjectMeta (defOpts root)
    er <- extract ((extOpts ImportsOnly) { XT.rootDir = root }) pm
    let g       = buildGraph defBuildOpts pm er
        encoded = BSL.toStrict (BB.toLazyByteString (encodeCodegraph Nothing g))
    expected <- BS.readFile golden
    assertBool
      (name <> ": codegraph bytes drifted from " <> golden
        <> " (expected " <> show (BS.length expected) <> " bytes, got "
        <> show (BS.length encoded) <> ")\n--- got ---\n"
        <> T.unpack (TE.decodeUtf8 encoded))
      (encoded == expected)

--------------------------------------------------------------------------------
-- G-E004 契約標籤對帳與 ModuleName 的傳遞型 re-export
--------------------------------------------------------------------------------

globalE004Tests :: TestTree
globalE004Tests = testGroup "global/G-E004 contract-surface-labels"
  [ testExtractionReexportsModuleName          -- T1
  , testGraphCoreNamesModuleNameViaExtraction  -- T2
  , testQueryTypesContractLabels               -- T3
  , testBackendConstantLabels                  -- T4
  , testDocsMatchContractLabels                -- T5
  , testContractLabelTable                     -- T6
  ]

-- | 讀一個模組的匯出清單,回傳 @(符號, 所屬小節標題)@ 對照。
--
-- 只掃 @module … ( … ) where@ 之間:以 @-- *@ 開頭的行切換小節,其餘註解
-- (含 @-- |@ 的補充說明)不切換;非註解行取第一個識別字當符號名。
exportGroups :: FilePath -> IO [(Text, Text)]
exportGroups path = do
  src <- readUtf8 path
  let body = takeWhile (not . isEnd)
               (drop 1 (dropWhile (not . isStart) (T.lines src)))
  pure (walk (T.pack "(未分組)") body)
 where
  isStart ln = T.pack "module " `T.isPrefixOf` ln
  isEnd   ln = T.pack ") where" `T.isSuffixOf` T.strip ln
  -- 去掉行首的 "(" / "," 與空白,讓小節標題與符號都落在行首
  clean = T.dropWhile (\c -> c == '(' || c == ',' || c == ' ') . T.strip
  -- 本專案的匯出符號都不帶 prime,故識別字只認英數與底線
  ident = T.takeWhile (\ch -> isAlphaNum ch || ch == '_')
  walk _ [] = []
  walk cur (ln : rest)
    | T.pack "-- *" `T.isPrefixOf` c = walk (T.strip (T.drop 4 c)) rest
    | T.pack "--"   `T.isPrefixOf` c = walk cur rest
    | T.null c                       = walk cur rest
    | otherwise = case T.words c of
        (w : _) | not (T.null (ident w)) -> (ident w, cur) : walk cur rest
        _                                -> walk cur rest
   where c = clean ln

-- | 查表:符號 → 小節標題;查不到回 'Nothing'。
groupOf :: [(Text, Text)] -> String -> Maybe Text
groupOf gs sym = lookup (T.pack sym) gs

-- | G-E004 T1:extraction 的契約模組代為 re-export 'ModuleName'。
--
-- 這條測試__能編譯本身就是斷言__:@XT.ModuleName@ 只有在
-- 'Knot.Extract.Types' 真的 re-export 了型別與建構子時才解析得到,
-- 而與 'Knot.Meta.Types' 的同一個型別比較則釘住「不是另外定義了一個」。
testExtractionReexportsModuleName :: TestTree
testExtractionReexportsModuleName = testCase "test_extraction_reexports_module_name" $ do
  XT.ModuleName (T.pack "Demo.Core") @?= mn "Demo.Core"
  gs <- exportGroups "src/Knot/Extract/Types.hs"
  case groupOf gs "ModuleName" of
    Nothing -> assertFailure
      ("Knot.Extract.Types should re-export ModuleName; exports: " <> show (map fst gs))
    Just grp -> assertBool
      ("ModuleName should sit in the shared-vocabulary section, got: " <> show grp)
      (hasText "共用詞彙型別" grp)

-- | G-E004 T2:graph-core 改由 extraction 契約命名 'ModuleName'。
--
-- 反向斷言同樣重要:'Knot.Graph' 與 fact-gate 另需 @ProjectMeta@ /
-- @SourceFile@,那兩處的 import __不得__被順手刪掉(拓撲的邊 2)。
testGraphCoreNamesModuleNameViaExtraction :: TestTree
testGraphCoreNamesModuleNameViaExtraction =
  testCase "test_graph_core_names_module_name_via_extraction" $ do
    forM_ ["src/Knot/Graph/EdgeDerive.hs", "src/Knot/Graph/NodeMint.hs"] $ \f -> do
      body <- readUtf8 f
      assertBool (f <> " should name ModuleName via Knot.Extract.Types, not project-meta")
        (not (hasText "import Knot.Meta" body))
    forM_ ["src/Knot/Graph.hs", "src/Knot/Graph/FactGate.hs"] $ \f -> do
      body <- readUtf8 f
      assertBool (f <> " still needs ProjectMeta/SourceFile from project-meta (edge 2)")
        (hasText "import Knot.Meta.Types" body)

-- | G-E004 T3:'Knot.Query.Types' 的契約標籤,以及公開面不得變質。
testQueryTypesContractLabels :: TestTree
testQueryTypesContractLabels = testCase "test_query_types_contract_labels" $ do
  gs <- exportGroups "src/Knot/Query/Types.hs"
  let expectGroup sym want = case groupOf gs sym of
        Nothing  -> assertFailure (sym <> " missing from Knot.Query.Types exports")
        Just grp -> assertBool
          (sym <> " should be in a " <> want <> " section, got: " <> show grp)
          (hasText want grp)
  -- NodeId 由 design.md 查詢面契約定義 → 契約面(本次修正的那一項)
  expectGroup "NodeId" "對外契約"
  expectGroup "QueryGraph" "對外契約"
  expectGroup "LoadError" "對外契約"
  -- QueryNode 不在契約裡 → 維持非契約面
  expectGroup "QueryNode" "非契約面"
  -- 公開面:Knot.Query 只 re-export 抽象 QueryGraph,欄位不得外露
  pub <- readUtf8 "src/Knot/Query.hs"
  assertBool "Knot.Query must keep QueryGraph abstract (no field selectors)"
    (not (hasText "QueryGraph (..)" pub))
  assertBool "Knot.Query should still re-export NodeId with its constructor"
    (hasText "NodeId (..)" pub)

-- | G-E004 T4:'Knot.Extract.Backend' 的每個非契約小節都要標明契約狀態。
testBackendConstantLabels :: TestTree
testBackendConstantLabels = testCase "test_backend_constant_labels" $ do
  gs <- exportGroups "src/Knot/Extract/Backend.hs"
  forM_ ["importScanName", "hiedbName", "runBackends"] $ \sym ->
    case groupOf gs sym of
      Nothing  -> assertFailure (sym <> " missing from Knot.Extract.Backend exports")
      Just grp -> assertBool
        (sym <> " should sit in a section labelled 非契約面, got: " <> show grp)
        (hasText "非契約面" grp)

-- | G-E004 T5:架構文件與 feature 文檔已同步。
testDocsMatchContractLabels :: TestTree
testDocsMatchContractLabels = testCase "test_docs_match_contract_labels" $ do
  adr <- readUtf8 ".design/adr/ADR-005-shared-vocabulary-type-boundary.md"
  assertBool "ADR-005 should no longer claim the re-export is an obligation"
    (not (hasText "依附帶義務應補上 re-export" adr))
  assertBool "ADR-005 should point at G-E004" (hasText "G-E004" adr)
  f002 <- readUtf8 ".design/subsystems/export-query/features/F002-graph-load.md"
  assertBool "F002 should record that NodeId was promoted to the contract surface"
    (hasText "已升為契約面" f002)

-- | 契約標籤對帳表:@(檔案, 符號, 是否應為非契約面)@。
--
-- 期望值來自 2026-08-22 對四處標籤的逐一對帳(見 G-E004「現況分析 (2)」),
-- 依據是各子系統 @design.md@ 的「對外契約」與「模組間公開介面」兩節。
contractLabelTable :: [(FilePath, String, Bool)]
contractLabelTable =
  -- 對帳 1:extraction 對外契約只有 extract;模組間公開介面只有
  -- Backend / ProbeResult / ensureIndex / readIndexFacts
  [ ("src/Knot/Extract/Backend.hs", "Backend",             False)
  , ("src/Knot/Extract/Backend.hs", "ProbeResult",         False)
  , ("src/Knot/Extract/Backend.hs", "importScanName",      True)
  , ("src/Knot/Extract/Backend.hs", "hiedbName",           True)
  , ("src/Knot/Extract/Backend.hs", "runBackends",         True)
  -- 對帳 2:graph-core 模組間公開介面只列 mint* 四項
  , ("src/Knot/Graph/NodeMint.hs",  "mintModuleId",        False)
  , ("src/Knot/Graph/NodeMint.hs",  "mintDeclId",          False)
  , ("src/Knot/Graph/NodeMint.hs",  "mintInstanceId",      False)
  , ("src/Knot/Graph/NodeMint.hs",  "mintNodes",           False)
  , ("src/Knot/Graph/NodeMint.hs",  "moduleFiles",         True)
  , ("src/Knot/Graph/NodeMint.hs",  "disambiguate",        True)
  , ("src/Knot/Graph/NodeMint.hs",  "moduleOfFile",        True)
  , ("src/Knot/Graph/NodeMint.hs",  "declNodeIndex",       True)
  -- 對帳 3:export-query 查詢面契約五函式,本檔佔兩個
  , ("src/Knot/Query/Load.hs",      "queryGraphNotes",     False)
  , ("src/Knot/Query/Load.hs",      "queryGraphHasNode",   False)
  , ("src/Knot/Query/Load.hs",      "parseQueryGraph",     True)
  , ("src/Knot/Query/Load.hs",      "RelationClass",       True)
  , ("src/Knot/Query/Load.hs",      "classifyRelation",    True)
  , ("src/Knot/Query/Load.hs",      "dependencyRelations", True)
  , ("src/Knot/Query/Load.hs",      "structuralRelations", True)
  -- 對帳 4:NodeId 由 design.md 查詢面契約定義(G-E004 修正的那一項)
  , ("src/Knot/Query/Types.hs",     "LoadError",           False)
  , ("src/Knot/Query/Types.hs",     "QueryCommand",        False)
  , ("src/Knot/Query/Types.hs",     "Direction",           False)
  , ("src/Knot/Query/Types.hs",     "QueryResult",         False)
  , ("src/Knot/Query/Types.hs",     "NodeId",              False)
  , ("src/Knot/Query/Types.hs",     "QueryGraph",          False)
  , ("src/Knot/Query/Types.hs",     "QueryNode",           True)
  ]

-- | G-E004 T6:四處標籤的全表對帳,把 2026-08-22 的結論鎖成回歸。
--
-- 涵蓋本次__不動__的兩處(node-mint、graph-load)——它們對帳結果是正確的,
-- 測試的作用是不讓它們日後默默漂掉。
testContractLabelTable :: TestTree
testContractLabelTable = testCase "test_contract_label_table" $ do
  let files = nubOrd [f | (f, _, _) <- contractLabelTable]
  groups <- mapM (\f -> (,) f <$> exportGroups f) files
  forM_ contractLabelTable $ \(file, sym, wantNonContract) ->
    case lookup file groups >>= \gs -> groupOf gs sym of
      Nothing -> assertFailure (file <> ": " <> sym <> " not found in the export list")
      Just grp -> do
        let isNonContract = hasText "非契約面" grp
        assertBool
          (file <> ": " <> sym <> " should be "
            <> (if wantNonContract then "非契約面" else "契約面")
            <> ", but its section reads " <> show grp)
          (isNonContract == wantNonContract)
