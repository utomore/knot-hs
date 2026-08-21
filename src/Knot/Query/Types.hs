-- | export-query 查詢面對外 DTO(內部模組 graph-load 的型別層)。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 查詢面」。
-- 'LoadError' 三建構子與 'QueryGraph' \/ 'NodeId' 的型別名依契約原文;
-- 'QueryGraph' 的欄位屬 Level 3(契約只寫「內容屬 Level 3」),
-- 見 @F002-graph-load.md@「實作方式 › 型別設計」。
--
-- __本模組刻意零 knot-hs 相依__:只 import @containers@ \/ @text@ \/ @base@。
-- 查詢面只認 @codegraph.json@(ADR-003:這是匯出格式,不是內部模型),
-- 因此 'NodeId' 是查詢面自有的型別,與 'Knot.Graph.Types.NodeId' 同名但無關
-- ——後者的唯一構造入口是 node-mint,而 graph-load 手上只有 JSON 字串(假設 A1)。
module Knot.Query.Types
  ( -- * 對外契約
    LoadError (..)
  , QueryGraph (..)
  , QueryCommand (..)
  , Direction (..)
  , QueryResult (..)
    -- * 非契約面(F003 \/ F004 取用,見「新增的介面 › 非契約面」)
  , NodeId (..)
  , QueryNode (..)
  ) where

import Data.Map.Strict (Map)
import Data.Text (Text)

-- | 查詢面的節點 id(見假設 A1)。'Ord' 是 'Map' 鍵與「同值按 id 字典序」
-- (查詢規則 4)的前提;字典序即 'Text' 的碼位序。
newtype NodeId = NodeId Text
  deriving (Eq, Ord, Show)

-- | 載入後的節點。三個欄位恰為 @F003@ 的 @FoundNodes [(NodeId, Text, FilePath)]@
-- 所需(@codegraph.json@ 的 @id@ \/ @label@ \/ @source_file@)。
data QueryNode = QueryNode
  { qnId    :: NodeId
  , qnLabel :: Text        -- ^ @FindNodes@ 的比對對象之一
  , qnFile  :: FilePath    -- ^ @source_file@,已是 repo 相對正斜線
  }
  deriving (Eq, Show)

-- | 從 @codegraph.json@ 載入的查詢用圖(Level 2 契約的抽象 DTO)。
--
-- 載入時就把「決定性」(查詢規則 4)與「鄰居依 id 升序」(規則 6)做完,
-- 讓 @F003@ 的四種演算法零預處理直接跑:
--
-- * @qgNodes@ 收錄__全部__節點(含只被結構類邊連到的),依 'qnId' 升序(規則 3、4)
-- * @qgForward@ \/ @qgReverse@ 只收__依賴類__邊,鄰居__去重且依 id 升序__;
--   自環('A' → 'A')照樣保留(規則 5 的前提)
-- * @qgOutDeg@ \/ @qgInDeg@ 是依賴類__邊數__(__不__去重),與下游
--   @scan-graph.mjs@ 的 hub 計算同語意(假設 A4)
-- * @qgNotes@ 是未知 relation 名 + 邊數,依名升序;結構類__不__入列
data QueryGraph = QueryGraph
  { qgNodes   :: [QueryNode]
  , qgIndex   :: Map NodeId QueryNode
  , qgForward :: Map NodeId [NodeId]
  , qgReverse :: Map NodeId [NodeId]
  , qgOutDeg  :: Map NodeId Int
  , qgInDeg   :: Map NodeId Int
  , qgNotes   :: [(Text, Int)]
  }
  deriving (Eq, Show)

-- | 從 @codegraph.json@ 載入失敗的三種原因(Level 2 契約原文)。
--
-- 三者一律__中止載入__,不產出部分圖(子系統的錯誤策略:'LoadError' 屬
-- 「使用者給錯輸入」,直接失敗而非 best-effort);exit code 由 @F004@ 決定。
data LoadError
  = LoadFileMissing Text   -- ^ 檔案不存在 / 讀不到
  | LoadParseError  Text   -- ^ JSON 語法壞掉
  | LoadSchemaError Text   -- ^ 必要欄位缺漏、型別不對、邊引用不存在的節點 id
  deriving (Eq, Show)

-- | 四種查詢指令(Level 2 契約原文)。CLI 參數解析(@--reverse@ \/ @--top N@
-- 與其預設值)屬組裝層 @F004@;本子系統收到的已經是建好的 'QueryCommand'。
data QueryCommand
  = FindNodes Text                  -- ^ 關鍵字:id 與 label 的子字串比對,__不分大小寫__
  | Reachable NodeId Direction      -- ^ 可達集合,__不含起點自身__(查詢規則 5)
  | ShortestPath NodeId NodeId      -- ^ 兩點最短路徑,多解取字典序最小(查詢規則 6)
  | RankConnectivity Int            -- ^ 連通度排名,參數為 top N
  deriving (Eq, Show)

-- | 'Forward':它依賴誰(走 'qgForward');'Reverse':誰依賴它(走 'qgReverse')。
data Direction = Forward | Reverse
  deriving (Eq, Show)

-- | 查詢結果(Level 2 契約原文)。空集合與 'Nothing' 都是__正常結果__
-- (查無節點 exit 0,由 @F004@ 決定);'runQuery' 沒有失敗路徑。
data QueryResult
  = FoundNodes   [(NodeId, Text, FilePath)]  -- ^ id、label、@source_file@;依 id 升序
  | ReachableSet [(NodeId, Int)]             -- ^ 節點與 hop 距離(≥ 1);依 (距離, id) 升序
  | PathResult   (Maybe [NodeId])            -- ^ 含起點與終點;'Nothing' = 不連通
  | Ranking      [(NodeId, Int, Int)]        -- ^ 節點、入度、出度;依 (總度數降序, id 升序)
  deriving (Eq, Show)
