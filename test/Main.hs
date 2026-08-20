-- | F001 scan-baseline 與 F002 cabal-components 的 1-to-1 測試。
module Main (main) where

import Control.Monad (forM_)
import Data.List (find, isInfixOf, isPrefixOf, sort)
import qualified Data.Text as T

import Hedgehog (forAll, property, (===))
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.Hedgehog (testProperty)

import Knot.App.Summary (renderMetaSummary)
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
tests = testGroup "knot-hs" [f001Tests, f002Tests, f003Tests]

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
