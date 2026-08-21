-- | graph-core 內部模組 edge-derive:邊推導、自環丟棄、去重與證據行。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「模組間公開介面」。
-- 'deriveEdges' 依 A3 裁決回傳三元組(補上警告通道)。
--
-- F001 推導 @FactImport@ → 'RImports';F002 另推導 @FactDecl@ /
-- @FactInstance@ → 'RContains'。@FactRef@ 與 @FactInstance@ 的
-- 'RImplements' 屬階段二 @F003@ decl-edges,本階段原樣略過不 crash。
--
-- 端點取得:module 端沿用 F001 的 @(gnLabel, gnFile)@ 節點索引;decl /
-- instance 端走 node-mint 的 'declNodeIndex' 與 'mintInstanceId'
-- (F002 假設 A8 + 編排者裁決)——'NodeId' 的建構子仍**只**出現在
-- node-mint,edge-derive 只是呼叫鑄造/索引函式再以節點集合驗證存在性。
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

import Knot.Extract.Types (Fact (..), QualName (..))
import Knot.Graph.FactGate (GatedFacts (..))
import Knot.Graph.NodeMint
  ( declNodeIndex
  , disambiguate
  , mintInstanceId
  , moduleFiles
  , moduleOfFile
  )
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

-- | 單筆事實的判定結果(內部狀態,不匯出)。
data Outcome
  = External ModuleName    -- ^ 規則 1:目標非內部 → 丟棄並計統計
  | Unresolved GraphWarning-- ^ 來源/目標解析不到節點 → 丟棄並發**逐筆**警告,不計統計
  | Skipped (Text, Text)   -- ^ 規則 4b:@(gwSource, 原因)@ → 彙整計數後每鍵一則警告
  | SelfLoop               -- ^ 規則 4:解析後兩端同一節點 → 丟棄,不計統計不發警告
  | Derived GraphEdge      -- ^ 產出一條邊(尚未去重)

-- | 事實 × 節點集合 → 邊集合。
--
-- 逐筆 @FactImport@ 依「外部判定 → 目標解析 → 來源解析 → 自環 → 產出」的
-- 順序判定(順序即優先序);逐筆 @FactDecl@ / @FactInstance@ 依「內部性
-- (規則 4b)→ 端點解析 → 自環 → 產出」判定,產出 'RContains'
-- (module → decl / instance,'geLine' 取宣告行;F002 假設 A5)。
--
-- 兩條判定鏈的原始邊進**同一個**去重表(組裝規則 5:相同
-- @(geSource, geTarget, geRelation)@ 合併為一條,'geLine' 取組內**最小**
-- 行號),鍵含 relation 故不互相污染。
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

  -- decl / instance 端點解析的共用素材(與 node-mint 同一份輸入 → 判定必然一致)
  facts    = gfFacts gated
  files    = moduleFiles facts
  fileMods = moduleOfFile facts
  nodeIds  = Set.fromList (map gnId nodes)
  declIdx  = declNodeIndex gated nodes

  outcomes = importOutcomes <> declOutcomes <> instanceOutcomes

  importOutcomes =
    [ classify from to file ln
    | FactImport{fiFrom = from, fiTo = to, fiFile = file, fiLine = ln} <- facts
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

  ------------------------------------------------------------------
  -- 組裝規則 2 的 FactDecl / FactInstance 列:RContains(module → decl)
  ------------------------------------------------------------------

  declOutcomes =
    [ classifyDecl q file ln
    | FactDecl{fdName = q, fdFile = file, fdLine = ln} <- facts
    ]

  -- 規則 4b:module 非內部 / 端點解析不到 → 不產邊、**不**計
  -- esDroppedExternal(那不是「指向外部套件」),改彙整為警告(假設 A4)。
  classifyDecl q file ln
    | qnModule q `Set.notMember` gfInternal gated =
        Skipped (moduleText (qnModule q), T.pack "declaring module is not internal")
    | otherwise = case declNodeOf q file of
        Nothing  -> Skipped (moduleText (qnModule q)
                     , T.pack "no declaration node for " <> qnOcc q)
        Just tgt -> case sourceNode (qnModule q) file of
          Nothing -> Skipped (moduleText (qnModule q)
                      , T.pack "no node for the declaring module")
          Just src
            | src == tgt -> SelfLoop
            | otherwise  -> Derived GraphEdge
                { geSource   = src
                , geTarget   = tgt
                , geRelation = RContains
                , geLine     = Just ln
                }

  -- declNodeIndex 建立時已以節點集合守門 → 查得到即代表節點存在。
  -- FactDecl 自帶檔案線索,故以 fdFile 收斂 D1 消歧組。
  declNodeOf q file =
    case [nid | (f, nid) <- Map.findWithDefault [] q declIdx, f == file] of
      [nid] -> Just nid
      _     -> Nothing

  instanceOutcomes =
    [ classifyInstance hd file ln
    | FactInstance{fiInstHead = hd, fiInstFile = file, fiInstLine = ln} <- facts
    ]

  -- instance 的宣告 module 由 fiInstFile 反查 FactModule(A3 裁決),
  -- **不是** qnModule fiClass(那是 class 定義處的 module)。
  classifyInstance hd file ln = case Map.lookup file fileMods of
    Nothing -> Skipped (T.pack file, T.pack "no module declared in this file")
    Just m
      | m `Set.notMember` gfInternal gated ->
          Skipped (T.pack file, T.pack "declaring module is not internal")
      | otherwise -> instanceContains m hd file ln

  -- instance 端點解析 + RContains 產出(F003 的 RImplements 來源端沿用同一條路徑)
  instanceContains m hd file ln
    | tgt `Set.notMember` nodeIds =
        Skipped (T.pack file, T.pack "no instance node for " <> hd)
    | otherwise = case sourceNode m file of
        Nothing -> Skipped (T.pack file, T.pack "no node for the declaring module")
        Just src
          | src == tgt -> SelfLoop
          | otherwise  -> Derived GraphEdge
              { geSource   = src
              , geTarget   = tgt
              , geRelation = RContains
              , geLine     = Just ln
              }
   where
    tgt = mintInstanceId m (disambiguate files m file) hd

  ------------------------------------------------------------------

  externals = [m | External m <- outcomes]
  rawEdges  = [e | Derived e <- outcomes]

  -- 假設 A4:跳過的事實以 (gwSource, 原因) 彙整計數,每個相異鍵一則警告
  -- (逐筆會刷屏);Map 的鍵序即決定性輸出序。
  skipCounts :: Map (Text, Text) Int
  skipCounts = Map.fromListWith (+) [(k, 1 :: Int) | Skipped k <- outcomes]

  warnings = [w | Unresolved w <- outcomes] <>
    [ GraphWarning
        { gwSource  = src
        , gwMessage = T.concat
            [ reason
            , T.pack "; "
            , T.pack (show n)
            , T.pack " fact(s) skipped, no contains edge"
            ]
        }
    | ((src, reason), n) <- Map.toList skipCounts
    ]

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
