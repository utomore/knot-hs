-- | project-meta 子系統對外契約進入點。
--
-- Level 2 契約:@.design/subsystems/project-meta/design.md@。
module Knot.Meta
  ( loadProjectMeta
  ) where

import Knot.Meta.Discovery (findCabalFiles)
import Knot.Meta.SourceIndex (indexSources)
import Knot.Meta.Types (MetaOptions (..), ProjectMeta (..))

-- | S1(F001)語意:@pmPackages = []@、@pmHie = Nothing@;
-- @pmSources@、@pmWarnings@ 填實。找到的 .cabal 路徑 S1 不進 DTO
-- (F001 假設 A3),僅用於「找不到 .cabal」警告。
-- 警告順序:discovery 先、source-index 後(判定規則 7)。
loadProjectMeta :: MetaOptions -> IO ProjectMeta
loadProjectMeta opts = do
  (_cabalFiles, discoveryWarnings) <- findCabalFiles (root opts)
  (sources, indexWarnings) <- indexSources opts []
  pure ProjectMeta
    { pmPackages = []
    , pmSources  = sources
    , pmHie      = Nothing
    , pmWarnings = discoveryWarnings ++ indexWarnings
    }
