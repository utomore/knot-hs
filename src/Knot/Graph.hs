-- | graph-core 子系統對外契約進入點(內部模組 graph-assemble)。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「對外契約」。
--
-- 調度 fact-gate → node-mint → edge-derive,套用組裝規則 6(@moduleOnly@
-- 分流)、統計與警告彙整、規則 7 的穩定排序(委派決策 D5)。
-- 全程純函數:無 IO、無 @unsafePerformIO@、無時間戳、無 GHC @Unique@,
-- 同輸入必同輸出。
module Knot.Graph
  ( buildGraph
  ) where

import Data.Containers.ListUtils (nubOrd)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T

import Knot.Extract.Types (ExtractResult (..), Fact (..))
import Knot.Graph.EdgeDerive (EdgeStats (..), deriveEdges)
import Knot.Graph.FactGate (GatedFacts (..), gateFacts)
import Knot.Graph.NodeMint (mintNodes, moduleFiles)
import Knot.Graph.Types
  ( BuildOptions (..)
  , CodeGraph (..)
  , GraphEdge (..)
  , GraphNode (..)
  , GraphStats (..)
  , GraphWarning (..)
  )
import Knot.Meta.Types (ModuleName (..), ProjectMeta)

-- | graph-core 唯一對外進入點。
--
-- 只消費 @erFacts@:@erLevel@ / @erReports@ / @erWarnings@ 由 CLI 印
-- stderr,graph-core 不轉載。
buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph
buildGraph opts pm result = CodeGraph
  { cgNodes    = sortOn gnId nodes
  , cgEdges    = sortOn edgeKey edges
  , cgStats    = stats
  , cgWarnings = warnings
  }
 where
  -- 規則 6:moduleOnly 時把事實窄化為 module 層建構子(decl 層直接忽略,
  -- 不計入任何統計);本階段兩個取值輸出相同(尚無 decl 事實)
  facts0 = erFacts result
  facts
    | moduleOnly opts = filter isModuleLayer facts0
    | otherwise       = facts0

  gated = gateFacts pm facts
  nodes = mintNodes gated
  (edges, estats, edgeWarnings) = deriveEdges gated nodes

  edgeKey e = (geSource e, geRelation e, geTarget e)

  stats = GraphStats
    { gsDroppedExternal    = esDroppedExternal estats
    -- G-E001:ModuleName → Text 的轉換收在 graph-core 內部,公開 DTO 不透出上游型別
    , gsTopExternalTargets = [(m, n) | (ModuleName m, n) <- esTopExternal estats]
    , gsFilteredGenerated  = gfFiltered gated
    , gsDedupedEdges       = esDeduped estats
    }

  -- 假設 A7:碰撞警告 + 邊解析警告合併後依 (gwSource, gwMessage) 去重並
  -- 依該鍵字典序輸出(GraphWarning 的 Ord 即該鍵序),對事實流重排序穩定
  warnings = nubOrd (sort (collisionWarnings <> edgeWarnings))

  -- D1:同名 module 分屬多個來源檔 → 該組全部改用消歧 id,碰撞事實入警告
  collisionWarnings =
    [ GraphWarning
        { gwSource  = m
        , gwMessage = T.concat
            [ T.pack "module declared in "
            , T.pack (show (length fs))
            , T.pack " source files; node ids disambiguated: "
            , T.intercalate (T.pack ", ") (map T.pack fs)
            ]
        }
    | (ModuleName m, fileSet) <- Map.toList (moduleFiles (gfFacts gated))
    , let fs = sort (Set.toList fileSet)
    , length fs > 1
    ]

-- | 規則 6 的 module 層判定:只有這兩個建構子屬 module 層。
isModuleLayer :: Fact -> Bool
isModuleLayer FactModule{} = True
isModuleLayer FactImport{} = True
isModuleLayer _            = False
