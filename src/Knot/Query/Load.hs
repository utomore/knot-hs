-- | @codegraph.json@ → 'QueryGraph' 的純函數層(內部模組 graph-load)。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 查詢面」
-- 的 'queryGraphNotes',以及查詢規則 1(依賴類分流)與 2(未知 relation 排除)。
-- 讀檔在 'Knot.Query.loadQueryGraph';本模組__全程無 IO、不印任何輸出__
-- (委派決策 D8)。
--
-- 不寫 @FromJSON@ instance 而手動走 'KM.KeyMap' 的三個理由(見
-- @F002-graph-load.md@「為什麼不寫 FromJSON instance」):錯誤訊息要指出
-- 「哪個欄位、第幾筆、什麼問題」;'LoadParseError' 與 'LoadSchemaError' 必須
-- 分得開;「邊引用不存在的節點 id」是跨元素驗證。
--
-- __零 knot-hs 相依__:只 import @aeson@ \/ @bytestring@ \/ @containers@ \/
-- @text@ \/ @base@ 與同子系統的 'Knot.Query.Types'(ADR-003:匯出格式不是內部模型)。
module Knot.Query.Load
  ( -- * 對外契約
    queryGraphNotes
    -- * 非契約面(1-to-1 測試與 F003 取用)
  , parseQueryGraph
  , RelationClass (..)
  , classifyRelation
  , dependencyRelations
  , structuralRelations
  ) where

import Control.Monad (foldM)
import Data.Aeson (Value (..), eitherDecodeStrict')
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
-- 'foldl'' 自 base 4.20 起由 Prelude 提供,不再從 Data.List 匯入。
import Data.List (intercalate, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Query.Types
  ( LoadError (..)
  , NodeId (..)
  , QueryGraph (..)
  , QueryNode (..)
  )

--------------------------------------------------------------------------------
-- 查詢規則 1:relation 三分類
--------------------------------------------------------------------------------

-- | 一個 relation 名字在查詢面的歸屬。
data RelationClass
  = RelDependency   -- ^ 進依賴圖(鄰接表 + 度數)
  | RelStructural   -- ^ 已知的非依賴關係;__靜默__排除,不進 'qgNotes'
  | RelUnknown      -- ^ 認不得;排除並累加進 'qgNotes'(查詢規則 2)
  deriving (Eq, Show)

-- | 依賴類十種(ADR-003 / @scan-graph.mjs:59-63@ 的 @DEP_RELATIONS@)。
dependencyRelations :: [Text]
dependencyRelations = map T.pack
  [ "imports", "imports_from", "calls", "uses", "references"
  , "extends", "implements", "inherits", "instantiates", "depends_on"
  ]

-- | 結構類六種(ADR-003 / @scan-graph.mjs:64@ 的 @STRUCTURAL_RELATIONS@;
-- 2026-08-21 補齊 @declares@ \/ @rationale_for@ \/ @part_of@,見假設 A6)。
structuralRelations :: [Text]
structuralRelations = map T.pack
  [ "contains", "method", "defines", "declares", "rationale_for", "part_of" ]

dependencySet, structuralSet :: Set Text
dependencySet = Set.fromList dependencyRelations
structuralSet = Set.fromList structuralRelations

-- | 分類__大小寫敏感__:契約的 relation 名是固定字面量,@"Imports"@ 不是
-- @"imports"@,一律落 'RelUnknown' 讓使用者看得到。
classifyRelation :: Text -> RelationClass
classifyRelation r
  | r `Set.member` dependencySet = RelDependency
  | r `Set.member` structuralSet = RelStructural
  | otherwise                    = RelUnknown

--------------------------------------------------------------------------------
-- 對外契約:未知 relation 統計
--------------------------------------------------------------------------------

-- | 查詢規則 2:未知 relation 名 + 邊數,依 relation 名升序(契約原文簽名)。
--
-- library 不印(D8);由 @F004@ 的 CLI 層取來印 stderr(契約 C2)。
queryGraphNotes :: QueryGraph -> [(Text, Int)]
queryGraphNotes = qgNotes

--------------------------------------------------------------------------------
-- 錯誤訊息
--------------------------------------------------------------------------------

-- | 訊息一律 @\<path\>: \<locus\>: \<problem\>@(頂層問題無 @\<locus\>@),
-- 英文小寫、陣列索引 0 起、JSON 鍵與 id 值以雙引號包起來。
message :: FilePath -> [String] -> Text
message path parts = T.pack (intercalate ": " (path : parts))

schemaErr :: FilePath -> [String] -> Either LoadError a
schemaErr path parts = Left (LoadSchemaError (message path parts))

--------------------------------------------------------------------------------
-- 解析 + 驗證 + 分流(fail-fast)
--------------------------------------------------------------------------------

-- | @codegraph.json@ 的位元組 → 'QueryGraph'。
--
-- 第一參數只用來組錯誤訊息,__不做任何 IO__。第一個違規就回 'Left' 並中止
-- ('LoadError' 只帶一個 'Text',承載不了多筆);掃描順序固定(頂層 → @nodes@
-- 依索引 → @links@ 依索引),所以同一份壞檔恆回同一個訊息。
parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph
parseQueryGraph path bs = do
  -- 步驟 1:JSON 語法
  top <- case eitherDecodeStrict' bs of
    Left msg          -> Left (LoadParseError (message path ["invalid JSON", msg]))
    Right (Object o)  -> Right o
    -- 步驟 2:頂層必須是物件
    Right _           -> schemaErr path ["top level is not a JSON object"]

  -- 步驟 3:nodes 必要,且必須是陣列(空陣列合法)
  nodeVals <- case KM.lookup (key "nodes") top of
    Nothing        -> schemaErr path ["missing required field \"nodes\""]
    Just (Array a) -> Right (toList a)
    Just _         -> schemaErr path ["\"nodes\" is not an array"]

  -- 步驟 4:逐個節點
  nodes <- traverse (uncurry (parseNode path)) (zip [0 ..] nodeVals)

  -- 步驟 5:建索引 + 重複 id 檢查(假設 A3)
  index <- buildIndex path (zip [0 ..] nodes)

  -- 步驟 6:links 選填(缺鍵當空陣列,假設 A2;不接受 edges 別名)
  edgeVals <- case KM.lookup (key "links") top of
    Nothing        -> Right []
    Just (Array a) -> Right (toList a)
    Just _         -> schemaErr path ["\"links\" is not an array"]

  -- 步驟 7 + 8:逐條邊解析後驗證端點(先驗證再分類)
  edges <- traverse (uncurry (parseEdge path index)) (zip [0 ..] edgeVals)

  -- 步驟 9 + 10:分流與收尾定序
  let acc = foldl' absorb emptyAcc edges
  pure QueryGraph
    { qgNodes   = sortOn qnId nodes
    , qgIndex   = index
    , qgForward = Map.map Set.toAscList (accForward acc)
    , qgReverse = Map.map Set.toAscList (accReverse acc)
    , qgOutDeg  = accOutDeg acc
    , qgInDeg   = accInDeg acc
    , qgNotes   = Map.toAscList (accUnknown acc)
    }

key :: String -> K.Key
key = K.fromText . T.pack

-- | 物件的必要字串欄位(步驟 4 / 7 共用)。
requiredString :: FilePath -> String -> KM.KeyMap Value -> String -> Either LoadError Text
requiredString path locus obj k = case KM.lookup (key k) obj of
  Just (String t) -> Right t
  Just _          -> schemaErr path [locus, "field " ++ show k ++ " is not a string"]
  Nothing         -> schemaErr path [locus, "missing required field " ++ show k]

-- | 步驟 4:@id@ \/ @label@ \/ @source_file@ 三鍵;其餘欄位(@source_location@ 等)
-- 一律忽略(ADR-003:多餘欄位可安全擴充)。
parseNode :: FilePath -> Int -> Value -> Either LoadError QueryNode
parseNode path i v = case v of
  Object o -> do
    nid   <- requiredString path locus o "id"
    label <- requiredString path locus o "label"
    file  <- requiredString path locus o "source_file"
    pure QueryNode { qnId = NodeId nid, qnLabel = label, qnFile = T.unpack file }
  _ -> schemaErr path [locus, "element is not a JSON object"]
 where
  locus = "nodes[" ++ show i ++ "]"

-- | 步驟 5:重複 id 是壞檔(不做「後者覆蓋」,假設 A3)。
buildIndex :: FilePath -> [(Int, QueryNode)] -> Either LoadError (Map NodeId QueryNode)
buildIndex path = foldM step Map.empty
 where
  step m (i, n)
    | Map.member (qnId n) m =
        schemaErr path
          [ "nodes[" ++ show i ++ "]"
          , "duplicate node id " ++ show (T.unpack (unNodeId (qnId n)))
          ]
    | otherwise = Right (Map.insert (qnId n) n m)

unNodeId :: NodeId -> Text
unNodeId (NodeId t) = t

-- | 一條已驗證的邊:兩端都是已知節點 id,relation 尚未分類。
data RawEdge = RawEdge !NodeId !NodeId !Text

-- | 步驟 7:@source@ \/ @target@ \/ @relation@ 三鍵必須存在且為字串
-- (__不接受數字索引__——ADR-003 明文 source\/target 是節點 id);
-- 步驟 8:兩端必須落在節點 id 集合內,__不分 relation 類別__。
parseEdge
  :: FilePath -> Map NodeId QueryNode -> Int -> Value -> Either LoadError RawEdge
parseEdge path index i v = case v of
  Object o -> do
    src <- requiredString path locus o "source"
    tgt <- requiredString path locus o "target"
    rel <- requiredString path locus o "relation"
    s <- known "source" src
    t <- known "target" tgt
    pure (RawEdge s t rel)
  _ -> schemaErr path [locus, "element is not a JSON object"]
 where
  locus = "links[" ++ show i ++ "]"
  known field t
    | Map.member n index = Right n
    | otherwise = schemaErr path
        [locus, field ++ " " ++ show (T.unpack t) ++ " is not a known node id"]
   where
    n = NodeId t

--------------------------------------------------------------------------------
-- 分流累加器(步驟 9)
--------------------------------------------------------------------------------

-- | 鄰接表用 'Set' 累加(去重 + 依 id 升序,規則 6);度數用 'Int' 累加
-- (算__邊數__不去重,與 @scan-graph.mjs:311-318@ 的 hub 計算同語意,假設 A4)。
data Acc = Acc
  { accForward :: !(Map NodeId (Set NodeId))
  , accReverse :: !(Map NodeId (Set NodeId))
  , accOutDeg  :: !(Map NodeId Int)
  , accInDeg   :: !(Map NodeId Int)
  , accUnknown :: !(Map Text Int)
  }

emptyAcc :: Acc
emptyAcc = Acc Map.empty Map.empty Map.empty Map.empty Map.empty

-- | 自環('A' → 'A')照常進表、in\/out 度各 +1(查詢規則 5 的前提);
-- 結構類靜默排除,未知累加進 'accUnknown'。
absorb :: Acc -> RawEdge -> Acc
absorb acc (RawEdge s t rel) = case classifyRelation rel of
  RelStructural -> acc
  RelUnknown    -> acc { accUnknown = Map.insertWith (+) rel 1 (accUnknown acc) }
  RelDependency -> acc
    { accForward = Map.insertWith Set.union s (Set.singleton t) (accForward acc)
    , accReverse = Map.insertWith Set.union t (Set.singleton s) (accReverse acc)
    , accOutDeg  = Map.insertWith (+) s 1 (accOutDeg acc)
    , accInDeg   = Map.insertWith (+) t 1 (accInDeg acc)
    }
