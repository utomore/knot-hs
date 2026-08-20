-- | cabal-model 模組:以 Cabal boot library 解析單一 .cabal → PackageMeta。
--
-- F002 cabal-components。conditional 以「預設 flag 值 + 本機平台」攤平
-- ('finalizePD',不可用 flattenPackageDescription——後者取全分支聯集)。
--
-- 路徑基準(F002 假設 A1):本模組只回相對於 .cabal 檔自身目錄的結果
-- (@pkgCabalFile@ = 檔名、@compSourceDirs@ = .cabal 內原樣的 hs-source-dirs);
-- repo 相對的錨定與 @compExcluded@ 的 includeTests 判定由組裝層 "Knot.Meta" 負責。
module Knot.Meta.CabalModel
  ( resolvePackage
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T

import Distribution.Compiler
  (AbiTag (NoAbiTag), CompilerFlavor (GHC), CompilerId (CompilerId), CompilerInfo, unknownCompilerInfo)
import Distribution.PackageDescription
  ( PackageDescription
  , benchmarkBuildInfo
  , benchmarkName
  , benchmarks
  , buildInfo
  , executables
  , exeName
  , foreignLibBuildInfo
  , foreignLibName
  , foreignLibs
  , hsSourceDirs
  , libBuildInfo
  , libName
  , library
  , package
  , subLibraries
  , testBuildInfo
  , testName
  , testSuites
  )
import Distribution.PackageDescription.Configuration (finalizePD)
import Distribution.PackageDescription.Parsec (parseGenericPackageDescription, runParseResult)
import Distribution.Parsec (showPError)
import Distribution.System (buildPlatform)
import Distribution.Types.ComponentRequestedSpec (ComponentRequestedSpec (..))
import Distribution.Types.DependencySatisfaction (DependencySatisfaction (Satisfied))
import Distribution.Types.LibraryName (LibraryName (..))
import qualified Distribution.Types.PackageId as PkgId
import Distribution.Types.PackageName (unPackageName)
import Distribution.Types.UnqualComponentName (unUnqualComponentName)
import Distribution.Utils.Path (getSymbolicPath)
import Distribution.Version (mkVersion)
import System.FilePath (normalise, takeFileName)

import Knot.Meta.Types
  ( ComponentKind (..)
  , ComponentMeta (..)
  , MetaWarning (..)
  , PackageMeta (..)
  )

-- | 解析單一 .cabal → 'PackageMeta'(Level 2 模組介面原文簽名)。
-- 讀檔失敗與解析失敗皆為 @Left MetaWarning@,不拋例外(best-effort)。
-- @compExcluded@ 一律 False(依 includeTests 的判定由組裝層套用)。
resolvePackage :: FilePath -> IO (Either MetaWarning PackageMeta)
resolvePackage cabalPath = do
  readResult <- try (BS.readFile cabalPath)
  case readResult of
    Left (e :: IOException) ->
      pure (Left (MetaWarning cabalPath (T.pack ("cannot read .cabal file: " <> show e))))
    Right bs ->
      case snd (runParseResult (parseGenericPackageDescription bs)) of
        -- 非致命 PWarning 一律丟棄(F002 假設 A6)
        Left (_, errs) ->
          let msg = showPError cabalPath (NE.head errs)
                      <> " (" <> show (NE.length errs) <> " parse error(s))"
          in pure (Left (MetaWarning cabalPath (T.pack msg)))
        Right gpd ->
          -- 預設 flag 攤平;test/benchmark 必須 requested 才會保留;
          -- 相依一律視為滿足(不解析 build-depends 依賴圖)
          case finalizePD mempty componentSpec (const Satisfied)
                 buildPlatform ghcInfo [] gpd of
            Left _missing ->
              -- 理論上不會發生(F002 假設 A7)
              pure (Left (MetaWarning cabalPath
                     (T.pack "finalizePD: unsatisfiable configuration")))
            Right (pd, _flags) -> pure (Right (toPackageMeta cabalPath pd))

componentSpec :: ComponentRequestedSpec
componentSpec = ComponentRequestedSpec { testsRequested = True, benchmarksRequested = True }

-- | ADR-001 版本鎖:GHC 9.14.1(@if impl(ghc …)@ 的求值基準)。
ghcInfo :: CompilerInfo
ghcInfo = unknownCompilerInfo (CompilerId GHC (mkVersion [9, 14, 1])) NoAbiTag

-- | component 抽取順序(固定):main library → sub-libraries → executables
-- → foreign-libraries → test-suites → benchmarks;各段內維持 Cabal 的宣告序。
toPackageMeta :: FilePath -> PackageDescription -> PackageMeta
toPackageMeta cabalPath pd = PackageMeta
  { pkgName       = T.pack rawPkgName
  , pkgCabalFile  = takeFileName cabalPath
  , pkgComponents =
         [ mk "lib" rawPkgName MainLibrary (libBuildInfo l) | Just l <- [library pd] ]
      <> [ mk "lib" (subLibNameOf l) NamedLibrary (libBuildInfo l) | l <- subLibraries pd ]
      <> [ mk "exe" (unUnqualComponentName (exeName e)) Executable (buildInfo e)
         | e <- executables pd ]
      <> [ mk "flib" (unUnqualComponentName (foreignLibName f)) ForeignLibrary (foreignLibBuildInfo f)
         | f <- foreignLibs pd ]
      <> [ mk "test" (unUnqualComponentName (testName t)) TestSuite (testBuildInfo t)
         | t <- testSuites pd ]
      <> [ mk "bench" (unUnqualComponentName (benchmarkName b)) Benchmark (benchmarkBuildInfo b)
         | b <- benchmarks pd ]
  }
 where
  rawPkgName = unPackageName (PkgId.pkgName (package pd))
  subLibNameOf l = case libName l of
    LSubLibName n -> unUnqualComponentName n
    LMainLibName  -> rawPkgName   -- subLibraries 內不會出現,防禦性退回
  -- compName 前綴命名(F002 假設 A3:比照 cabal component target 語法)
  mk prefix nm kind bi = ComponentMeta
    { compName       = T.pack (prefix <> ":" <> nm)
    , compKind       = kind
    , compSourceDirs = map (toSlash . normalise . getSymbolicPath) (hsSourceDirs bi)
    , compExcluded   = False
    }
  toSlash = map (\c -> if c == '\\' then '/' else c)
