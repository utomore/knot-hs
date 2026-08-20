-- | graph-core 內部模組 node-mint:節點 id 鑄造與 'GraphNode' 建構。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「模組間公開介面」
-- 與「節點 id 鑄造規則」。'NodeId' 的唯一構造入口(其他模組一律從既有
-- 'GraphNode' 取 'gnId')。
--
-- 階段一(F001)只鑄 module 列;值/型別/instance 列(@mintDeclId@ /
-- @mintInstanceId@)屬階段二 @F002@ decl-nodes。
module Knot.Graph.NodeMint
  ( mintModuleId
  , mintNodes
    -- * 非契約面(供 graph-assemble 彙整碰撞警告與 1-to-1 測試)
  , moduleFiles
  ) where

import Data.Containers.ListUtils (nubOrdOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T

import Knot.Extract.Types (Fact (..))
import Knot.Graph.FactGate (GatedFacts (..))
import Knot.Graph.Types (GraphNode (..), NodeId (..), NodeKind (..))
import Knot.Meta.Types (ModuleName (..))

-- | module 節點 id 鑄造(A2 裁決的契約簽名)。
--
-- @Nothing@ = 該 module 名未碰撞,鑄裸名;@Just file@ = 碰撞組成員,鑄
-- @\<module\>\@\<source_file\>@(@file@ 為 @fmFile@ 原文:repo 相對、正斜線)。
mintModuleId :: ModuleName -> Maybe FilePath -> NodeId
mintModuleId (ModuleName m) Nothing     = NodeId m
mintModuleId (ModuleName m) (Just file) = NodeId (m <> T.pack "@" <> T.pack file)

-- | 委派決策 D1 的判定面:module 名 → 宣告它的相異來源檔集合。
-- 集合大小 > 1 即碰撞組(該組全部改用消歧形式)。
moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)
moduleFiles facts = Map.fromListWith Set.union
  [(m, Set.singleton file) | FactModule{fmModule = m, fmFile = file} <- facts]

-- | 事實流 → module 節點(組裝規則 2 的 @FactModule@ 列)。
--
-- 每筆 @FactModule@ 產一個節點,最後依 'gnId' 去重(同一檔重複出現在事實
-- 流時保留第一筆)。非 @FactModule@ 的事實一律略過(本階段)。
-- 消歧只反映在 'gnId' 與 'gnFile','gnLabel' 維持裸 module 名(假設 A5);
-- @FactModule@ 無行號欄位,故 'gnLine' 恆為 @Nothing@。
mintNodes :: GatedFacts -> [GraphNode]
mintNodes gated = nubOrdOn gnId
  [mkNode m file | FactModule{fmModule = m, fmFile = file} <- facts]
 where
  facts = gfFacts gated
  files = moduleFiles facts
  mkNode m file = GraphNode
    { gnId    = mintModuleId m (disambiguate m file)
    , gnKind  = ModuleNode
    , gnLabel = moduleText m
    , gnFile  = file
    , gnLine  = Nothing
    }
  disambiguate m file
    | maybe False ((> 1) . Set.size) (Map.lookup m files) = Just file
    | otherwise                                           = Nothing
  moduleText (ModuleName t) = t
