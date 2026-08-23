-- | 投影規則 1–5 的純函數落地(Level 2 契約:@design.md@「投影規則」)。
--
-- 全程無 IO:'encodeCodegraph' 只把 'CodeGraph' 攤成 'Builder',
-- 寫檔由 'Knot.Export.writeCodegraph' 負責。
--
-- 決定性(規則 5)的三重保證:
--
-- * 欄位順序由 "Data.Aeson.Encoding" 的 'E.pairs' \/ 'E.pair' 顯式串接,
--   不走 @toJSON@ \/ @KeyMap@(順序不可靠)
-- * 清單順序沿用 @cgNodes@ \/ @cgEdges@ 原序(graph-core 組裝規則 7 已排好),
--   本模組__不重排也不去重__
-- * 換行一律單一 @\\n@ 的 ASCII 字面量,不經 'String' \/ 'Data.Text.IO' 的
--   平台換行轉換
--
-- 版面(委派決策 D4:半 pretty)——物件層壓成單行、文件層每欄位一行。
module Knot.Export.Encode
  ( encodeCodegraph
  , relationText
  , statsNotes
  ) where

import qualified Data.Aeson.Encoding as E
import qualified Data.Aeson.Key as K
import Data.ByteString.Builder (Builder)
import qualified Data.ByteString.Builder as BB
import Data.List (intersperse)
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Graph.Types
  ( CodeGraph (..)
  , GraphEdge (..)
  , GraphNode (..)
  , GraphStats (..)
  , NodeId (..)
  , Relation (..)
  )

--------------------------------------------------------------------------------
-- 文件層(規則 4、5)
--------------------------------------------------------------------------------

-- | 把 'CodeGraph' 投影成 @codegraph.json@ 的位元組。
--
-- 第一參數是 @built_at_commit@ 的值:'Nothing' 代表整行省略('CommitPolicy'
-- 為 @NoCommit@,或 commit 偵測失敗)。
--
-- 頂層欄位順序固定:@directed@ → @built_at_commit@ → @nodes@ → @links@;
-- 檔尾有結尾換行。
encodeCodegraph :: Maybe Text -> CodeGraph -> Builder
encodeCodegraph mCommit g =
  BB.char7 '{' <> nl
    <> BB.string7 "  \"directed\": true," <> nl
    <> commitLine
    <> arrayField "nodes" True  (map nodeObject (cgNodes g))
    <> arrayField "links" False (map edgeObject (cgEdges g))
    <> BB.char7 '}' <> nl
 where
  commitLine = case mCommit of
    Nothing  -> mempty
    Just sha ->
      BB.string7 "  \"built_at_commit\": " <> encoded (E.text sha) <> BB.char7 ',' <> nl

-- | 頂層陣列欄位。空陣列壓成同一行(避免 @[\\n  ]@ 空殼);非空時每個元素
-- 縮排 4 空格獨佔一行,元素之間 @,@,最後一個元素不留尾逗號。
--
-- 第二參數:本欄位之後是否還有欄位(決定行尾是否帶逗號)。
arrayField :: String -> Bool -> [Builder] -> Builder
arrayField name more elems =
  BB.string7 "  \"" <> BB.string7 name <> BB.string7 "\": [" <> body <> comma <> nl
 where
  comma = if more then BB.char7 ',' else mempty
  body = case elems of
    [] -> BB.char7 ']'
    _  -> nl
       <> mconcat (intersperse (BB.char7 ',' <> nl) (map indent elems))
       <> nl <> BB.string7 "  ]"
  indent e = BB.string7 "    " <> e

nl :: Builder
nl = BB.char7 '\n'

-- | 單一 JSON 值 → 文件層 'Builder'。
encoded :: E.Encoding -> Builder
encoded = BB.lazyByteString . E.encodingToLazyByteString

--------------------------------------------------------------------------------
-- 物件層(規則 2、3)
--------------------------------------------------------------------------------

-- | 節點物件(規則 2):@id@ → @label@ → @source_file@ →(@component@,僅
-- @gnComponent@ 有值時出現,G-E007 / ADR-008)→(@source_location@,
-- 僅 @gnLine@ 有值時出現)。@gnFile@ 原樣輸出(project-meta 已保證 repo
-- 相對 + 正斜線);@gnKind@ 不輸出(契約卡「不輸出 IR 的額外欄位」)。
nodeObject :: GraphNode -> Builder
nodeObject n = encoded $ E.pairs $
     kv "id"          (nodeIdText (gnId n))
  <> kv "label"       (gnLabel n)
  <> kv "source_file" (T.pack (gnFile n))
  <> componentField   (gnComponent n)
  <> sourceLocation   (gnLine n)

-- | @component@ 的兩分支:'Nothing' 時整個鍵不存在(與 'sourceLocation' 同作法)。
componentField :: Maybe Text -> E.Series
componentField = maybe mempty (kv "component")

-- | 邊物件(規則 3):@source@ → @target@ → @relation@ → @confidence@ →
-- (@source_location@,僅 @geLine@ 有值時出現)。
--
-- @confidence@ 恆為 @EXTRACTED@(ADR-003:GHC 抽取是事實不是推測)。
-- @source_location@ 是下游 @scan-graph.mjs@ 取循環依賴\/跨子系統引用證據行的
-- 主來源(「邊優先、來源節點 fallback」),S1 的 module 節點 @gnLine@ 恆為
-- 'Nothing',不由邊供給就取不到(階段一閘門對假設 A5 的裁決)。
edgeObject :: GraphEdge -> Builder
edgeObject e = encoded $ E.pairs $
     kv "source"     (nodeIdText (geSource e))
  <> kv "target"     (nodeIdText (geTarget e))
  <> kv "relation"   (relationText (geRelation e))
  <> kv "confidence" (T.pack "EXTRACTED")
  <> sourceLocation  (geLine e)

-- | 字串欄位。鍵以 'K.fromText' 建構(不依賴 @OverloadedStrings@),
-- 值的 escaping 交給 aeson 的 'E.text'。
kv :: String -> Text -> E.Series
kv k v = E.pair (K.fromText (T.pack k)) (E.text v)

-- | @source_location@ 的兩分支:'Nothing' 時整個鍵不存在。
sourceLocation :: Maybe Int -> E.Series
sourceLocation Nothing   = mempty
sourceLocation (Just ln) = kv "source_location" (T.pack ('L' : show ln))

nodeIdText :: NodeId -> Text
nodeIdText (NodeId t) = t

-- | 投影規則 1:'Relation' → dev-flow 契約的 relation 名。
relationText :: Relation -> Text
relationText RImports    = T.pack "imports"
relationText RCalls      = T.pack "calls"
relationText RUses       = T.pack "uses"
relationText RImplements = T.pack "implements"
relationText RContains   = T.pack "contains"

--------------------------------------------------------------------------------
-- 匯出報告的摘要行(驗收標準 5)
--------------------------------------------------------------------------------

-- | 'ExportReport' 的 @xrNotes@ 內容(假設 A4 的固定格式)。
--
-- 前三行恆存在;@top external target@ 行依 @gsTopExternalTargets@ 原序
-- (graph-core 已保證次數降序 \/ 同次數依名字典序)。
statsNotes :: GraphStats -> [Text]
statsNotes st =
  [ note "dropped external edges: "    (gsDroppedExternal st)
  , note "filtered generated facts: "  (gsFilteredGenerated st)
  , note "deduped edges: "             (gsDedupedEdges st)
  ]
  <> [ T.concat
         [ T.pack "top external target: ", m
         , T.pack " (", T.pack (show c), T.pack ")"
         ]
     | (m, c) <- gsTopExternalTargets st
     ]
 where
  note label n = T.pack label <> T.pack (show n)
