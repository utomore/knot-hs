-- | graph-core 內部模組 edge-derive:邊推導、自環丟棄、去重與證據行。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「模組間公開介面」。
-- 'deriveEdges' 依 A3 裁決回傳三元組(補上警告通道)。
--
-- 階段一(F001)只推導 @FactImport@ → 'RImports';@FactRef@ / @FactInstance@
-- 屬階段二 @F003@ decl-edges,本階段原樣略過不 crash。
-- edge-derive **不鑄造任何 id**,只從既有節點取 'gnId'(NodeId 的唯一構造
-- 入口在 node-mint)。
module Knot.Graph.EdgeDerive
  ( deriveEdges
  , EdgeStats (..)
  ) where

import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Extract.Types (Fact (..))
import Knot.Graph.FactGate (GatedFacts (..))
import Knot.Graph.Types
  ( GraphEdge (..)
  , GraphNode (..)
  , GraphWarning (..)
  , NodeId
  , NodeKind (..)
  , Relation (..)
  )
import Knot.Meta.Types (ModuleName (..))

data EdgeStats = EdgeStats
  { esDroppedExternal :: Int                  -- ^ 指向外部目標而丟棄的邊數(總數,非相異 module 數)
  , esTopExternal     :: [(ModuleName, Int)]  -- ^ 前 10:次數降序、同次數依名字典序(D4)
  , esDeduped         :: Int                  -- ^ 去重合併掉的邊數
  }
  deriving (Eq, Show)

-- | 單筆 @FactImport@ 的判定結果(內部狀態,不匯出)。
data Outcome
  = External ModuleName    -- ^ 規則 1:目標非內部 → 丟棄並計統計
  | Unresolved GraphWarning-- ^ 來源/目標解析不到節點 → 丟棄並發警告,不計統計
  | SelfLoop               -- ^ 規則 4:解析後兩端同一節點 → 丟棄,不計統計不發警告
  | Derived GraphEdge      -- ^ 產出一條邊(尚未去重)

-- | 事實 × 節點集合 → 邊集合。
--
-- 逐筆 @FactImport@ 依「外部判定 → 目標解析 → 來源解析 → 自環 → 產出」的
-- 順序判定(順序即優先序),再套用組裝規則 5 的去重:相同
-- @(geSource, geTarget, geRelation)@ 合併為一條,'geLine' 取組內**最小**
-- 行號(最早的證據行;取極小值而非輸入序第一筆,使結果不隨事實序改變)。
deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])
deriveEdges gated nodes = (edges, stats, warnings)
 where
  moduleNodes = [n | n <- nodes, gnKind n == ModuleNode]

  -- (gnLabel, gnFile) → gnId:來源端的精確索引
  byNameFile :: Map (Text, FilePath) NodeId
  byNameFile = Map.fromList [((gnLabel n, gnFile n), gnId n) | n <- moduleNodes]

  -- gnLabel → 該名的全部節點(D1 消歧組 > 1)
  byName :: Map Text [NodeId]
  byName = Map.fromListWith (++) [(gnLabel n, [gnId n]) | n <- moduleNodes]

  nodesNamed m = Map.findWithDefault [] m byName

  outcomes =
    [ classify from to file ln
    | FactImport{fiFrom = from, fiTo = to, fiFile = file, fiLine = ln} <- gfFacts gated
    ]

  -- 判定順序即優先序:外部 → 目標解析 → 來源解析 → 自環 → 產出
  classify from to file ln
    | to `Set.notMember` gfInternal gated = External to
    | otherwise = case nodesNamed (moduleText to) of
        []      -> Unresolved (warnAt file ln
                     (T.pack "internal module has no node: " <> moduleText to))
        [tgt]   -> resolveSource from file ln tgt
        targets -> Unresolved (warnAt file ln (T.concat
                     [ T.pack "ambiguous import target "
                     , moduleText to
                     , T.pack " ("
                     , T.pack (show (length targets))
                     , T.pack " candidate nodes)"
                     ]))

  resolveSource from file ln tgt = case sourceNode from file of
    Nothing -> Unresolved (warnAt file ln
                 (T.pack "unresolved importing module: " <> moduleText from))
    Just src
      | src == tgt -> SelfLoop
      | otherwise  -> Derived GraphEdge
          { geSource   = src
          , geTarget   = tgt
          , geRelation = RImports
          , geLine     = Just ln
          }

  -- 精確命中 (module, 檔案);未命中時退路:該名恰有一個節點(非 import-scan
  -- 來源的事實可能缺對應 FactModule)
  sourceNode from file = case Map.lookup (moduleText from, file) byNameFile of
    Just nid -> Just nid
    Nothing  -> case nodesNamed (moduleText from) of
      [nid] -> Just nid
      _     -> Nothing

  warnAt file ln msg = GraphWarning
    { gwSource  = T.pack file
    , gwMessage = T.concat [msg, T.pack "; import edge dropped at line ", T.pack (show ln)]
    }

  externals = [m | External m <- outcomes]
  warnings  = [w | Unresolved w <- outcomes]
  rawEdges  = [e | Derived e <- outcomes]

  -- 規則 5:去重分組(鍵 → (最小行號, 組大小))
  grouped :: Map (NodeId, NodeId, Relation) (Maybe Int, Int)
  grouped = Map.fromListWith mergeGroup
    [((geSource e, geTarget e, geRelation e), (geLine e, 1 :: Int)) | e <- rawEdges]
  mergeGroup (l1, c1) (l2, c2) = (minLine l1 l2, c1 + c2)
  minLine (Just a) (Just b) = Just (min a b)
  minLine Nothing  b        = b
  minLine a        Nothing  = a

  edges = sortOn edgeKey
    [ GraphEdge { geSource = s, geTarget = t, geRelation = r, geLine = ln }
    | ((s, t, r), (ln, _)) <- Map.toList grouped
    ]
  edgeKey e = (geSource e, geRelation e, geTarget e)

  externalCounts = Map.fromListWith (+) [(m, 1 :: Int) | m <- externals]

  stats = EdgeStats
    { esDroppedExternal = length externals
    , esTopExternal     =
        take 10 (sortOn (\(m, n) -> (Down n, m)) (Map.toList externalCounts))
    , esDeduped         = sum (map (subtract 1 . snd) (Map.elems grouped))
    }

  moduleText (ModuleName t) = t
