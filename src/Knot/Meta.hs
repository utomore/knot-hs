-- | project-meta 子系統對外契約進入點。
--
-- Level 2 契約:@.design/subsystems/project-meta/design.md@。
module Knot.Meta
  ( loadProjectMeta
  ) where

import System.FilePath (normalise, takeDirectory, (</>))

import Knot.Meta.CabalModel (resolvePackage)
import Knot.Meta.Discovery (findCabalFiles)
import Knot.Meta.SourceIndex (indexSources)
import Knot.Meta.Types
  ( ComponentKind (..)
  , ComponentMeta (..)
  , MetaOptions (..)
  , PackageMeta (..)
  , ProjectMeta (..)
  )

-- | S2(F002)語意:discovery 的 repo 相對 .cabal 清單逐一交給
-- 'resolvePackage'(失敗者降級為警告、略過該套件),結果在此錨定為
-- repo 相對(@pkgCabalFile@、@compSourceDirs@;F002 假設 A1)並套用
-- @compExcluded@ 的 kind × includeTests 判定,再交給 'indexSources'
-- 做歸類。@pmHie@ 恆 Nothing(F003 hie-discovery 的事)。
-- 警告順序:discovery → cabal-model → source-index(判定規則 7)。
loadProjectMeta :: MetaOptions -> IO ProjectMeta
loadProjectMeta opts = do
  (cabalRels, discoveryWarnings) <- findCabalFiles (root opts)
  results <- mapM (\rel -> resolvePackage (root opts </> rel)) cabalRels
  let paired        = zip cabalRels results
      cabalWarnings = [w | (_, Left w) <- paired]     -- 序 = cabalRels 序(決定性)
      pkgs          = [anchor rel pm | (rel, Right pm) <- paired]
  (sources, indexWarnings) <- indexSources opts pkgs
  pure ProjectMeta
    { pmPackages = pkgs
    , pmSources  = sources
    , pmHie      = Nothing
    , pmWarnings = discoveryWarnings ++ cabalWarnings ++ indexWarnings
    }
 where
  -- root 錨定:resolvePackage 只回相對 .cabal 自身目錄的結果(假設 A1)
  anchor rel pm = pm
    { pkgCabalFile  = rel
    , pkgComponents =
        [ c { compSourceDirs = map (prefixDir (takeDirectory rel)) (compSourceDirs c)
            , compExcluded   = isExcludedKind (compKind c)   -- 判定規則 1
            }
        | c <- pkgComponents pm
        ]
    }
  prefixDir pkgDir d
    | pkgDir == "." = toSlash (normalise d)
    | otherwise     = toSlash (normalise (pkgDir </> d))   -- d == "." 時化簡為 pkgDir
  isExcludedKind k = k `elem` [TestSuite, Benchmark] && not (includeTests opts)
  toSlash = map (\c -> if c == '\\' then '/' else c)
