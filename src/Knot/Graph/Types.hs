-- | graph-core 對外 DTO(圖 IR)。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「對外契約」。
-- S1(F001)僅 'ModuleNode' 與 'RImports' 有邏輯觸碰;其餘建構子為階段二
-- ('F002' decl-nodes / 'F003' decl-edges)先行定義,零邏輯(比照
-- project-meta F001 假設 A5 的既有慣例)。
--
-- deriving 說明:全部 DTO 有 'Eq' / 'Show';'NodeId' / 'NodeKind' /
-- 'Relation' / 'GraphWarning' 另有 'Ord',支撐組裝規則 7(決定性)的
-- 穩定排序(委派決策 D5)。
module Knot.Graph.Types
  ( -- * 對外契約
    BuildOptions (..)
  , CodeGraph (..)
    -- * 節點
  , NodeId (..)
  , GraphNode (..)
  , NodeKind (..)
    -- * 邊
  , GraphEdge (..)
  , Relation (..)
    -- * 統計與警告
  , GraphStats (..)
  , GraphWarning (..)
  ) where

import Data.Text (Text)

import Knot.Extract.Types (DeclKind)
import Knot.Meta.Types (ModuleName)

-- | 建圖選項。@moduleOnly@ 對應 CLI @--module-only@:只出 module 節點與
-- imports 邊(組裝規則 6)。
data BuildOptions = BuildOptions
  { moduleOnly :: Bool
  }
  deriving (Eq, Show)

-- | 圖 IR;由 'Knot.Graph.buildGraph' 產出,交給 export-query 投影。
data CodeGraph = CodeGraph
  { cgNodes    :: [GraphNode]
  , cgEdges    :: [GraphEdge]
  , cgStats    :: GraphStats     -- ^ 丟棄/過濾/去重統計,供匯出層列印
  , cgWarnings :: [GraphWarning]
  }
  deriving (Eq, Show)

-- | 節點 id。唯一構造入口是 node-mint(Level 2 契約);其他模組只得從既有
-- 'GraphNode' 取 'gnId',不得直接用建構子(F001 假設 A1)。
newtype NodeId = NodeId Text
  deriving (Eq, Ord, Show)

data GraphNode = GraphNode
  { gnId    :: NodeId
  , gnKind  :: NodeKind
  , gnLabel :: Text              -- ^ 人類可讀名(module 名 / occ 名 / instance 標頭)
  , gnFile  :: FilePath          -- ^ repo 相對、正斜線
  , gnLine  :: Maybe Int         -- ^ 下游 source_location(L\<行\>)的來源
  }
  deriving (Eq, Show)

data NodeKind = ModuleNode | DeclNode DeclKind | InstanceNode
  deriving (Eq, Ord, Show)

data GraphEdge = GraphEdge
  { geSource   :: NodeId
  , geTarget   :: NodeId
  , geRelation :: Relation
  , geLine     :: Maybe Int      -- ^ 證據行(去重時保留最早一筆)
  }
  deriving (Eq, Show)

-- | 建構子序即委派決策 D5 排序鍵的 relation 序。
data Relation = RImports | RCalls | RUses | RImplements | RContains
  deriving (Eq, Ord, Show)

data GraphStats = GraphStats
  { gsDroppedExternal    :: Int                  -- ^ 指向外部目標而丟棄的邊數
  , gsTopExternalTargets :: [(ModuleName, Int)]  -- ^ 前 10,次數降序、同次數依名字典序
  , gsFilteredGenerated  :: Int                  -- ^ TH/產生碼過濾掉的事實數
  , gsDedupedEdges       :: Int                  -- ^ 去重合併掉的邊數
  }
  deriving (Eq, Show)

-- | 帶來源的警告(批次澄清 D3,比照 @MetaWarning@ / @ExtractWarning@)。
data GraphWarning = GraphWarning
  { gwSource  :: Text            -- ^ module 名、節點 id 或檔案路徑
  , gwMessage :: Text
  }
  deriving (Eq, Ord, Show)
