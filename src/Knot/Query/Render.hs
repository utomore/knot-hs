-- | 'QueryResult' → 人類可讀文字(內部模組 query-render)。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 查詢面」
-- 的 'renderResult',以及驗收標準 4(不連通時明確輸出「不連通」)。
--
-- __library 全程不印__(委派決策 D8):本模組回傳 'Text',@T.putStr@ 是 @F004@ 的事。
--
-- 格式沿用專案既有的輸出慣例(@app/Knot/App/Summary.hs@ 的 @renderMetaSummary@
-- 系列與 @F001@ 的 @xrNotes@,假設 A5):__英文小寫、@key: value@ 首行 +
-- 兩空格縮排的明細行、'T.unlines' 產出(每行含結尾 @\\n@)、不依賴
-- @OverloadedStrings@(一律 'T.pack')__。
--
-- 空結果__只輸出首行__(@found: 0 nodes@ 等),不輸出空字串——使用者要能分辨
-- 「查了但沒有」與「指令沒跑」。分隔符固定兩個空格,__不做欄寬對齊__:對齊要先
-- 掃全表算寬度,對超長 id 反而更難讀,且會讓輸出隨資料集浮動(決定性雖仍成立,
-- diff 卻會整片變動)。
--
-- __零 knot-hs 相依__:只 import @text@ \/ @base@ 與同子系統的 'Knot.Query.Types'。
module Knot.Query.Render
  ( -- * 對外契約
    renderResult
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Knot.Query.Types (NodeId (..), QueryResult (..))

-- | 'QueryResult' → stdout 文字(Level 2 契約原文簽名)。
--
-- 每行以 @\\n@ 結尾(含最後一行),不含 @\\r@;__不印__(D8)。
-- 四個建構子全部有分支,-Wall 下無 incomplete pattern 警告。
--
-- > FoundNodes rows      → "found: <n> nodes"      + 每列 "  <id>  <label>  <file>"
-- > ReachableSet rows    → "reachable: <n> nodes"  + 每列 "  <dist>  <id>"
-- > PathResult (Just p)  → "path: <hops> hops"     + 單列 "  <id> -> <id> -> …"
-- > PathResult Nothing   → "path: not connected"   (無明細行)
-- > Ranking rows         → "rank: <n> nodes"       + 每列 "  <total>  <id>  in=<i> out=<o>"
-- > TestSet rows         → "tests-of: <n> nodes"   + 每列 "  <dist>  <id>"(G-E007,明細同 ReachableSet)
renderResult :: QueryResult -> Text
renderResult result = case result of
  FoundNodes rows ->
    block (countLine "found" rows)
      [ row [nodeText i, label, T.pack file] | (i, label, file) <- rows ]
  ReachableSet rows ->
    block (countLine "reachable" rows)
      [ row [num d, nodeText i] | (i, d) <- rows ]
  PathResult Nothing ->
    block (T.pack "path: not connected") []
  PathResult (Just p) ->
    block
      (T.concat [T.pack "path: ", num (hops p), T.pack " hops"])
      -- 空路徑不可能來自 'Knot.Query.Engine'(路徑恆含起點與終點),
      -- 但 'renderResult' 是全函數:此時只出首行,不留一條空白明細行。
      [ T.concat [indent, T.intercalate arrow (map nodeText p)] | not (null p) ]
  Ranking rows ->
    block (countLine "rank" rows)
      [ row [num (inD + outD), nodeText i, degrees inD outD]
      | (i, inD, outD) <- rows
      ]
  TestSet rows ->
    block (countLine "tests-of" rows)
      [ row [num d, nodeText i] | (i, d) <- rows ]
 where
  hops p = max 0 (length p - 1)
  degrees inD outD =
    T.concat [T.pack "in=", num inD, T.pack " out=", num outD]

-- | 首行 + 明細行,每行含結尾 @\\n@。
block :: Text -> [Text] -> Text
block header rows = T.unlines (header : rows)

-- | @\<kind\>: \<n\> nodes@(單數不特判,固定用 @nodes@)。
countLine :: String -> [a] -> Text
countLine kind rows =
  T.concat [T.pack kind, T.pack ": ", num (length rows), T.pack " nodes"]

-- | 兩空格縮排 + 欄位以兩空格分隔的明細行。
row :: [Text] -> Text
row cols = T.concat [indent, T.intercalate sep cols]

indent, sep, arrow :: Text
indent = T.pack "  "
sep    = T.pack "  "
arrow  = T.pack " -> "

num :: Int -> Text
num = T.pack . show

-- | 'Knot.Query.Types' 只匯出 'NodeId' 的建構子,沒有具名選擇器。
nodeText :: NodeId -> Text
nodeText (NodeId t) = t
