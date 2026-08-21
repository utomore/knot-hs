---
id: F003
type: feature
title: query-commands
description: 四種導航查詢的演算法與查詢結果文字渲染
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: [F002]
related-adr: [ADR-003]
related-feature: []
---

# F003: query-commands — 四種查詢演算法與結果渲染

## 功能概述

export-query 查詢面的第二、三站,也是主架構 S4「`knot query`」的**能力本體**:吃 `F002` 載入好的
`QueryGraph` 與一個 `QueryCommand`,以**純函數**算出 `QueryResult`,再渲染成人類可讀的 `Text`
交給 CLI 層列印。dev-flow `_shared/codegraph.md`「能力對照」表的四項能力(關鍵字查節點、反向可達、
兩點最短路徑、連通度排名)在此落地。

**要解決的問題**:四個演算法本身都是教科書級的(子字串比對、BFS、度數排序),真正的難點是
**決定性**——`knot query` 的輸出會被人貼進 issue、被 skill 當定位依據,同一份 `codegraph.json`
配同一個指令,今天跑與明天跑必須逐字元相同。決定性的破口有三處,本 feature 逐一釘死:

1. **走訪容器的序**:`Data.Map` / `Data.Set` 的走訪序由 `Ord` 保證(依鍵升序),`Data.HashMap`
   **不保證**——因此本 feature 全程只用 `Data.Map.Strict` / `Data.Set`,不引入任何 hash 容器
2. **BFS 的展開序**:「BFS 的自然順序」不是規格。本 feature 把展開序寫死為
   **FIFO 發現序 + 鄰居依 id 升序**(鄰居的升序由 `F002` 的 `qgForward` / `qgReverse` 在載入時就備好),
   並證明這個序恰好產生查詢規則 6 要的**字典序最小路徑**(見「實作方式 › ShortestPath」)
3. **輸出的排序鍵**:四個查詢各自的排序鍵與 tie-break 全部明列(見下表),不留「依演算法產出的順序」

| 查詢 | 主排序鍵 | tie-break | 依據 |
|---|---|---|---|
| `FindNodes` | 節點 id 升序(直接沿用 `qgNodes` 的序) | 不需要(id 唯一) | 規則 4 |
| `Reachable` | 距離升序 | 節點 id 升序 | 規則 4 |
| `ShortestPath` | 路徑長度最短 | 同長度取**字典序最小路徑** | 規則 6 |
| `RankConnectivity` | (入度 + 出度)**降序** | 節點 id 升序 | 規則 4 + 契約卡驗收標準 |

**驗收標準**(契約卡原文,逐條對照落地):

| # | 契約卡原文 | 落地 | 測試 |
|---|---|---|---|
| 1 | `find` 不分大小寫比對 id 與 label | 關鍵字與 id / label 兩邊都 `T.toLower` 後做 `isInfixOf`,任一命中即收錄 | T2 |
| 2 | `reachable` 的 Forward / Reverse 方向正確且回報 hop 距離 | `Forward` 走 `qgForward`、`Reverse` 走 `qgReverse`;`ReachableSet [(NodeId, Int)]` 的 `Int` 是 BFS 層數 | T3 |
| 3 | `path` 連通時回最短路徑 | BFS + 前驅重建,回 `PathResult (Just [起點 … 終點])` | T4 |
| 4 | `path` 不連通時明確輸出「不連通」且 exit 0 | `runQuery` 回 `PathResult Nothing`;`renderResult` 輸出固定行 `path: not connected`(假設 A5)。**exit code 屬 `F004`**(契約已定:查無結果 exit 0) | T4、T6 |
| 5 | `rank` 依 入度+出度 排序、同分按 id 字典序、`--top N` 生效 | `sortOn (\(i,inD,outD) -> (Down (inD + outD), i))` 後 `take n`;`--top N` 的解析屬 `F004`,本 feature 收到的是 `RankConnectivity Int` | T5 |
| 6 | 所有查詢只走依賴類邊(`contains` 不影響結果) | 本 feature **完全不看 relation**——`qgForward` / `qgReverse` / `qgOutDeg` / `qgInDeg` 裡已經沒有結構類與未知類邊(`F002` 在載入時分流完畢),`FindNodes` 則依規則 3 掃全部節點 | T7 |
| 7 | 同輸入兩次結果相同 | 四個查詢都是 `QueryGraph -> QueryCommand -> QueryResult` 的純函數,無 IO、無 hash 容器、無隨機來源;排序鍵全部明定 | T7 |

**明確不做**(契約卡底線):不解析 CLI 參數(`--reverse` / `--top N` 的解析與預設值 10 屬 `F004`,
本 feature 收到的已經是 `QueryCommand`);不讀寫檔案(圖由 `F002` 的 `loadQueryGraph` 給定,
本 feature 全程無 IO);不做全對最短路徑、中心性、社群偵測等進階演算法(超出四能力範圍)。
另承子系統邊界:不建圖、不改圖。另承 D8:**library 全程不印任何輸出**——`renderResult` 回傳 `Text`,
`putStr` 是 `F004` 的事。另承 D3:本 feature **不動 `app/Main.hs`** 與 executable 段。
另承 D6:`knot-hs.cabal` 的 `version` 維持 `0.0.1.0` 不動。

## 相依性

`depends-on: [F002]`,單一一條,由「使用到的既有串接介面」表反推。

- **`F002` graph-load(同子系統)——唯一相依,且是**產品面**相依**:本 feature 的輸入 `QueryGraph`
  與其七個欄位、`QueryNode` 三欄位、`NodeId` 全部由 `F002` 定義;`Knot.Query.Types` /
  `Knot.Query` 兩個模組也是 `F002` 建立的,本 feature 在其上**擴充**(加 DTO、加匯出項)。
  **`F002` 尚未實作**(`status: open`,`src/Knot/Query/` 不存在,2026-08-21 以 `find src -iname "*Query*"`
  確認),因此下表凡標「來源文檔 = F002」的列,**簽名來自 `F002` 設計文檔的「型別設計」與
  「新增的介面」段落,而非既有原始碼**;實作階段必須以 `F002` 落地後的真實簽名複驗
- **不依賴 `F001`**:`F001` 寫檔、本 feature 不碰檔案;測試的 fixture 圖走 `F002` 的
  `parseQueryGraph`(純函數,吃 `ByteString`),不需要先用 `writeCodegraph` 產檔
- **不依賴 graph-core / extraction / project-meta**:查詢面只認 JSON 載入後的 `QueryGraph`
  (`ADR-003`「匯出格式 ≠ 內部模型」的鏡像)。**本 feature 的 library 與測試程式碼都不 import
  `Knot.Graph.*` 或 `Knot.Meta.*`**;`test/Main.hs` 檔頭既有的 `import Knot.Graph.Types (…)`
  是 `graph-core/F001` 與 `export-query/F001` 兩組測試留下的,與本 feature 的測試無關,
  本 feature 一律走 `import qualified Knot.Query.Types as QT`(`F002` 立下的慣例)
- **`ADR-003`** 列在 `related-adr` 而非 `depends-on`:它是「依賴類 / 結構類」名單的權威來源,
  但**分類發生在 `F002`**,本 feature 只是消費分流後的鄰接表;列它是為了說明驗收標準 6 的出處
- **`F004` cli-wiring** 方向相反(它呼叫 `runQuery` / `renderResult`),不列入

**對 `F002` 的三個形狀前提**(全部是 `F002` 設計文檔已寫定的不變式,本 feature 直接依賴、不重算):

1. `qgForward` / `qgReverse` 的鄰居**已去重且依 id 升序** → BFS 不必自己排序(規則 6 的前提)
2. `qgForward` / `qgReverse` **保留自環** → 起點在環上時 `Reachable` 才算得出真實距離(規則 5)
3. `qgOutDeg` / `qgInDeg` 是**邊數**(不去重、兩端各 +1),與下游 `scan-graph.mjs:310-318` 的
   hub 計算同語意(`F002` 假設 A4,已於開工前接受) → `RankConnectivity` 直接取用,不從鄰接表重算

**另需確認的上游狀態**:`F002` 假設 A6 的閘門裁決是「結構類補齊到 6 種」(`design.md` 查詢規則 1 與
`ADR-003` 均已補),但 `F002-graph-load.md` 的「實作方式 › 步驟 9」與 T2 測試對照仍寫 3 種
(`contains` / `method` / `defines`)。本 feature 的驗收標準 6 只要求「結構類不進依賴圖」,
3 種或 6 種都成立(兩者都是排除),**不影響本 feature 的設計**;但 `F002` 實作時應以裁決後的 6 種為準,
已列入回報請編排者處理。

**可平行性**:**不可**與 `F002` 平行——本 feature 的輸入型別與兩個宿主模組都由 `F002` 建立,
`F002` 未落地前無法編譯。與其他子系統的任務**可**平行。`F004` 排在本 feature 之後。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/export-query/design.md`「對外契約 › 查詢面」、「查詢規則」與
「CLI 子命令對映」,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| `runQuery :: QueryGraph -> QueryCommand -> QueryResult`(純函數) | `Knot.Query.Engine.runQuery`,簽名一字不差;經 `Knot.Query` 再匯出 |
| `renderResult :: QueryResult -> Text`(stdout 文字) | `Knot.Query.Render.renderResult`,簽名一字不差;回傳 `Text`,**不印**(D8) |
| DTO `QueryCommand = FindNodes Text \| Reachable NodeId Direction \| ShortestPath NodeId NodeId \| RankConnectivity Int` | `Knot.Query.Types.QueryCommand`,四建構子與參數順序依契約原文 |
| DTO `Direction = Forward \| Reverse`(Forward:它依賴誰;Reverse:誰依賴它) | `Knot.Query.Types.Direction`;`Forward` → `qgForward`、`Reverse` → `qgReverse`(`F002` 的 `qgForward` 存的就是「A 依賴 B」的正向邊) |
| DTO `QueryResult = FoundNodes [(NodeId, Text, FilePath)] \| ReachableSet [(NodeId, Int)] \| PathResult (Maybe [NodeId]) \| Ranking [(NodeId, Int, Int)]` | `Knot.Query.Types.QueryResult`,四建構子與元組形狀依契約原文(`FoundNodes` = id/label/source_file;`Ranking` = 節點/入度/出度) |
| 查詢規則 3(`FindNodes` 比對**所有**節點,含只被結構類邊連到的;其餘三指令操作依賴圖) | `FindNodes` 掃 `qgNodes`(`F002` 保證收錄全部節點);`Reachable` / `ShortestPath` 只讀 `qgForward` / `qgReverse`,`RankConnectivity` 只讀 `qgOutDeg` / `qgInDeg` |
| 查詢規則 4(決定性:結果排序穩定,距離 / 度數同值時按 id 字典序) | 見「功能概述」的排序鍵表;四個查詢的輸出序全部明定,無一依賴容器走訪的偶然序 |
| 查詢規則 5(`Reachable` 不含起點自身;起點在環上時以真實距離出現) | BFS **不預先把起點放進 visited**:起點在第 0 層被展開但不入結果,若經由環再度被發現則以該距離入列(見「實作方式 › Reachable」) |
| 查詢規則 6(`ShortestPath` 多解取字典序最小;BFS 鄰居依 id 排序、前驅取最早抵達者) | FIFO 發現序 BFS + 鄰居升序 + 首次發現寫入前驅,證明其結果恰為字典序最小路徑(見「實作方式 › ShortestPath」) |
| CLI 子命令對映四條語意(`find` / `reachable [--reverse]` / `path` / `rank [--top N]`) | 四條語意在 `runQuery` 落地;**參數解析與 `--top` 預設值 10 屬 `F004`** |
| 資料流管線「查詢」段落:`query-engine: QueryCommand → QueryResult(純函數)` → `query-render: 文字 → stdout` | `Knot.Query.Engine`(無 IO)→ `Knot.Query.Render`(無 IO);`stdout` 那一步在 `F004` |
| 錯誤策略:查無節點(`FindNodes` 空集合、`PathResult Nothing`)是正常結果,exit 0 | `runQuery` 沒有失敗路徑——任何輸入都回一個 `QueryResult`(空集合 / `Nothing` 是合法值);exit code 由 `F004` 決定 |

**契約卡與 `design.md` 的落差(以 `design.md` 為準)**:契約卡「實作的 Level 2 介面」寫的是
「查詢規則 3、4」,但**查詢規則 5、6 是 W2 期間新增**(build-log C4 / C5),而且兩條都明確指向
`Reachable` 與 `ShortestPath` 的演算法語意——`F002` 也已在其「對應的 Level 2 契約」表把這兩條標為
「屬 `F003`」。因此本 feature **一併實作規則 3、4、5、6**,並請編排者把契約卡的介面清單補上 5、6
(見回報)。

**未觸碰的契約面**:`loadQueryGraph` / `queryGraphNotes` 與 `LoadError`(`F002`);匯出面全部
(`F001` 已完成);CLI 旗標與 exit code(`F004`)。

## 實作方式

### 模組配置

Level 2 的內部模組表把查詢面分成三個邏輯模組(`graph-load` / `query-engine` / `query-render`),
本 feature 負責後兩個。Haskell 落地時**在 `F002` 建立的 `Knot.Query.*` 命名空間下擴充**
(形狀沿用 `F001` / `F002` 已通過閘門的「`*.Types` + 進入點 + 內部模組」拆法):

| Haskell 模組 | 本 feature 的動作 | 職責 | IO |
|---|---|---|---|
| `Knot.Query.Types` | **擴充**(`F002` 已建) | 新增 `QueryCommand` / `Direction` / `QueryResult` 三個契約 DTO | 無 |
| `Knot.Query.Engine` | **新增** | `runQuery`:四種演算法(純函數) | 無 |
| `Knot.Query.Render` | **新增** | `renderResult`:`QueryResult` → `Text` | 無 |
| `Knot.Query` | **擴充**(`F002` 已建) | 匯出清單加上 `runQuery`、`renderResult` 與三個新 DTO,`F004` 只需 import 這一個模組 | 有(`F002` 的讀檔) |

兩個新模組都進 `exposed-modules`(沿用 `Knot.Export.Encode` / `Knot.Query.Load` 的既有形狀,
測試可直接對 `Knot.Query.Engine` 下斷言而不必繞 `Knot.Query`)。

### 型別設計(契約原文)

```haskell
data QueryCommand
  = FindNodes Text                  -- 關鍵字(id 與 label 的子字串比對,不分大小寫)
  | Reachable NodeId Direction
  | ShortestPath NodeId NodeId
  | RankConnectivity Int            -- top N
  deriving (Eq, Show)

data Direction = Forward | Reverse  -- Forward:它依賴誰;Reverse:誰依賴它
  deriving (Eq, Show)

data QueryResult
  = FoundNodes   [(NodeId, Text, FilePath)]
  | ReachableSet [(NodeId, Int)]
  | PathResult   (Maybe [NodeId])
  | Ranking      [(NodeId, Int, Int)]
  deriving (Eq, Show)
```

`Eq` / `Show` 是測試需要(結果比對與失敗訊息);契約未禁止,亦與 `F001` / `F002` 的 DTO 一致。

### `runQuery` 的分派

```text
runQuery g (FindNodes kw)         = FoundNodes   (findNodes g kw)
runQuery g (Reachable start dir)  = ReachableSet (reachableFrom g start dir)
runQuery g (ShortestPath from to) = PathResult   (shortestPath g from to)
runQuery g (RankConnectivity n)   = Ranking      (rankConnectivity g n)
```

四個私有函數的命名屬實作自主權;以下規格是行為契約,不是命名鎖定。

### FindNodes(規則 3、4)

1. `needle = T.toLower kw`
2. 掃 `qgNodes g`(**已依 id 升序**,`F002` 保證),對每個 `QueryNode` 判斷
   `needle isInfixOf T.toLower (unNodeId (qnId n)) || needle isInfixOf T.toLower (qnLabel n)`
3. 命中者輸出 `(qnId n, qnLabel n, qnFile n)`,**原序保留**(即 id 升序)

- **不分大小寫**:兩邊都 `T.toLower` 再比對。knot 自產的 id 是 module / 符號名(ASCII),
  其他產生器的圖可能含非 ASCII;`T.toLower` 是簡單 Unicode 小寫映射,對 ASCII 完全正確,
  對其他語系亦不會拋例外
- **空關鍵字**:`T.isInfixOf T.empty x` 恆為 `True`,故 `FindNodes ""` 回**全部節點**(假設 A6)
- **不做 rank / 分數**:契約的 `FoundNodes` 沒有分數欄位;命中即收錄,排序只有 id 升序
- **掃全部節點**:包含只被 `contains` 邊連到的節點,甚至完全孤立的節點(規則 3)

### Reachable(規則 2、4、5)

```text
reachableFrom g start dir
  | not (start `Map.member` qgIndex g) = []          -- 起點不存在 → 空集合(假設 A1)
  | otherwise = sortOn (\(i, d) -> (d, i)) (Map.toAscList dist)
 where
  adj = case dir of Forward -> qgForward g; Reverse -> qgReverse g
  -- BFS:frontier 是「本層節點的發現序」,dist 只記距離 ≥ 1 的節點
  dist = go (Map.empty) 1 (neighbours start)
  go acc _ []       = acc
  go acc d frontier =
    let fresh = [v | v <- frontier, not (v `Map.member` acc)]   -- 保序去重(見下)
        acc'  = foldl' (\m v -> Map.insert v d m) acc fresh
    in  go acc' (d + 1) (concatMap neighbours fresh)
  neighbours v = Map.findWithDefault [] v adj
```

- **起點不入結果**:第 0 層的 `start` 從不寫進 `dist`,只被展開一次(規則 5 前半)
- **起點在環上會以真實距離出現**:`start` 沒有被預先標記,若某層的鄰居含 `start`,
  它就以該層距離被寫入 `dist`——自環(`A → A`)給距離 1、二元環給距離 2(規則 5 後半)
- **保序去重**:同一層可能重複發現同一節點(不同前驅),`fresh` 的計算必須**同時**濾掉
  「已在 `acc`」與「本層前面已出現過」的重複——實作上以一次 `foldl'` 帶 `Set` 累積器完成,
  保留首次出現的位置。這一步只影響效率與展開序,不影響距離值
- **終止性**:每個節點最多被寫入 `dist` 一次,`frontier` 只由未寫入者組成,故層數上限為節點數
- **輸出排序**:`(距離升序, id 升序)`(規則 4)。注意不能只 `Map.toAscList`(那是純 id 序)
- **`Reverse` 的距離語意**:沿反向邊的 hop 數,即「誰依賴它、隔幾層」

### ShortestPath(規則 6)

```text
shortestPath g from to
  | not (from `Map.member` qgIndex g) = Nothing
  | not (to   `Map.member` qgIndex g) = Nothing
  | from == to                        = Just [from]         -- 0 hop(假設 A2)
  | otherwise                         = bfsPath
```

BFS 的三條展開紀律(**決定性的核心**):

1. **鄰居依 id 升序展開**——`qgForward` 的每條鄰接清單在載入時就排好(`F002` 不變式 1),
   直接 `Map.findWithDefault [] v (qgForward g)` 取用即可,**不再排序、也不可打亂**
2. **層內依 FIFO 發現序展開**——下一層的節點順序 = 它們被發現的先後,**不得**按節點 id 重排。
   以「上一層清單 `concatMap` 鄰居後保序去重」實作,結果與標準 FIFO 佇列 BFS 完全一致
3. **首次發現寫入前驅,之後不覆蓋**(「前驅取最早抵達者」)

**為什麼這樣就是字典序最小路徑**(契約規則 6 要的性質):

- 設 `P = [from, p₁, …, p_d]` 是抵達 `p_d` 的**字典序最小**最短路徑,則其前綴
  `[from, p₁, …, p_{d-1}]` 必然也是抵達 `p_{d-1}` 的字典序最小最短路徑
  ——否則把更小的前綴接上 `p_d`,會得到一條更小且等長的路徑,與 `P` 的最小性矛盾
- 依此歸納:若第 d 層每個節點記下的路徑都是它的字典序最小最短路徑,且該層節點**依其路徑的
  字典序排列**,那麼第 d+1 層以「層內順序 × 鄰居 id 升序」展開時,恰好是依字典序枚舉所有長度
  d+1 的候選路徑,首次發現者即為最小者;新層的順序也依然是字典序
- 基底:第 0 層只有 `[from]`,平凡成立
- **FIFO 發現序 = 路徑字典序**,所以紀律 2 不能改成「層內按節點 id 排序」——那會退化成
  「反向貪心」(只保證前驅 id 最小),在「`from → Alpha → Xray → to` vs
  `from → Beta → Whisky → to`」這種案例給出錯誤答案(`Whisky < Xray` 但 `Alpha < Beta`)。
  T4 的 fixture 就是照這個反例造的

重建路徑:自 `to` 沿前驅 `Map NodeId NodeId` 回溯到 `from`,`reverse` 後輸出
`[from, …, to]`(含頭尾兩端)。找不到 `to` 時(BFS 耗盡)回 `Nothing`。

- **提早結束**:一旦某層發現 `to` 即可停止展開(同層其餘節點的前驅已寫完,不影響結果);
  這是效率優化,不改變輸出
- **不連通**:`PathResult Nothing`,由 `renderResult` 轉成 `path: not connected`(驗收標準 4)
- **`from == to`**:回 `Just [from]`(零 hop),**不**去找環——與規則 5 的
  「`Reachable` 起點在環上時以真實距離出現」刻意不同:`Reachable` 問的是「能到哪些節點」,
  `ShortestPath a a` 問的是「怎麼從 a 走到 a」,而零步就已抵達(假設 A2)
- **只走 `qgForward`**:契約沒有反向 `path`;`knot query path <from> <to>` 的語意是依賴方向

### RankConnectivity(規則 4、驗收標準 5)

```text
rankConnectivity g n =
  take n
    (sortOn (\(i, inD, outD) -> (Down (inD + outD), i))
       [ (i, inD, outD)
       | node <- qgNodes g                             -- 已依 id 升序
       , let i    = qnId node
             inD  = Map.findWithDefault 0 i (qgInDeg g)
             outD = Map.findWithDefault 0 i (qgOutDeg g)
       , inD + outD > 0                                -- 排除零連通度節點(假設 A3)
       ])
```

- **度數直接取 `F002` 的兩張表,不從鄰接表重算**:那兩張表算的是**邊數**(重複邊計 2、
  自環兩端各 +1),與下游 `scan-graph.mjs:310-318` 的 hub 計算同語意(`F002` 假設 A4 已裁決接受);
  用 `length (findWithDefault [] i qgForward)` 會得到**相異鄰居數**,語意不同
- **排序鍵**:`(Down (入度 + 出度), id)`——總度數降序、同分 id 升序(驗收標準 5)。
  `sortOn` 是穩定排序,但這裡的鍵已含 id、本身就是全序,穩定性不影響結果
- **排除零連通度節點**:只被 `contains` 邊連到、或完全孤立的節點不進榜(假設 A3),
  與 `scan-graph.mjs` 的 `degree` map 只收非結構邊端點一致;否則 `--top 20` 在小圖上會被
  一串 `0 0` 佔滿
- **`n <= 0`**:`take` 的自然語意 → 空清單(假設 A4);`n` 大於可排名節點數時輸出全部
- **輸出元組**是 `(NodeId, 入度, 出度)`,契約 `Ranking [(NodeId, Int, Int)]` 的欄位順序

### `renderResult` 的文字格式(假設 A5)

沿用專案既有的輸出慣例(`app/Knot/App/Summary.hs:52` 的 `renderMetaSummary :: ProjectMeta -> Text`
系列與 `F001` 的 `xrNotes`;2026-08-21 讀原文確認格式,本 feature **不呼叫、不 import** 該模組):**英文小寫、`key: value` 首行 + 兩空格縮排的明細行、`T.unlines` 產出(每行含結尾
`\n`)、不依賴 `OverloadedStrings`(一律 `T.pack`)**。`F004` 以 `T.putStr` 直接輸出。

```text
FoundNodes rows        → "found: <n> nodes"          + 每列 "  <id>  <label>  <file>"
ReachableSet rows      → "reachable: <n> nodes"      + 每列 "  <dist>  <id>"
PathResult (Just p)    → "path: <hops> hops"         + 單列 "  <id> -> <id> -> …"
PathResult Nothing     → "path: not connected"       (無明細行)
Ranking rows           → "rank: <n> nodes"           + 每列 "  <total>  <id>  in=<i> out=<o>"
```

- `<hops>` = `length p - 1`(節點數減一);`from == to` 時為 `0 hops`,明細行只有一個 id
- 空結果只輸出首行:`found: 0 nodes` / `reachable: 0 nodes` / `rank: 0 nodes`
  ——**不輸出空字串**,使用者要能分辨「查了但沒有」與「指令沒跑」
- 分隔符固定為兩個空格,**不做欄寬對齊**:對齊需要先掃全表算寬度,對超長 id 反而更難讀,
  且會讓輸出隨資料集浮動(決定性雖仍成立,diff 卻會整片變動)
- 箭號固定為 ` -> `(與 `renderGraphSummary` 的 `-imports->` 同一視覺語彙)
- `renderResult` 是全函數:四個建構子全部有分支,`-Wall` 下無 incomplete pattern 警告

### cabal 變更

- library `exposed-modules` **+2**:`Knot.Query.Engine`、`Knot.Query.Render`
  (`Knot.Query`、`Knot.Query.Types`、`Knot.Query.Load` 由 `F002` 加入)
- library `build-depends`:**零新增**——`base` / `containers` / `text` 全部已在 library 段
  (`knot-hs.cabal:28-37`);本 feature **不需要** `aeson`、`bytestring`
- test-suite `build-depends`:**零新增**——`aeson` / `bytestring` / `containers` / `hedgehog` /
  `tasty` / `tasty-hedgehog` / `tasty-hunit` / `text` 皆已在(`knot-hs.cabal:56-68`)
- `version` **維持 `0.0.1.0` 不動**(D6);executable 段**不動**(D3)

### 測試 fixture 圖的構造方式

**不手寫 `QueryGraph` 值**,而是手寫一份 `codegraph.json` 的 `ByteString` 字面量,經
`F002` 的 `parseQueryGraph` 產生 fixture 圖。理由:`QueryGraph` 的欄位帶著三條不變式
(鄰接去重升序、度數算邊數、節點依 id 升序),手寫容易造出不可能存在的圖,
反而測不到真實行為;走載入層則「fixture 一定合法」。這也不構成對 `F001` 的相依(不寫檔)。

fixture 圖(node id 皆為 ASCII,刻意讓 id 序與拓撲序不一致):

```text
節點(共 10 個;JSON 中刻意**依 id 降序**排列,以證明輸出序不是檔案原序):
        S, Alpha, Beta, Whisky, Xray, T, Self, Loop, Cyc, Iso
        每個節點的 label 與 id **刻意不同**(如 S 的 label 為 "Start.Module"、
        Alpha 的 label 為 "Alpha.Impl"),以便分開驗證「比對 id」與「比對 label」
依賴邊:S -imports-> Alpha      S -imports-> Alpha(重複邊,測度數不去重)
        S -calls->   Beta
        Alpha -calls-> Xray     Beta -calls-> Whisky
        Xray -uses->  T         Whisky -uses-> T
        Self -depends_on-> Self(自環)
        Loop -imports-> Cyc     Cyc -imports-> Loop(二元環)
結構邊:Iso -contains-> Alpha(Iso 只有這一條邊)
未知邊:S -foo-> T
```

關鍵性質:`S → Alpha → Xray → T` 與 `S → Beta → Whisky → T` **等長**,
但 `Alpha < Beta` 而 `Whisky < Xray`——字典序最小是前者,反向貪心會選後者(T4 的反例);
`Whisky` 與 `Xray` 的 (入度, 出度) 皆為 (1, 1),提供 `rank` 的同分 tie-break 案例(T5);
`Iso` 提供「只被結構邊連到」的節點(T2 找得到、T5 不入榜、T3 從它出發為空);
`Self` / `Loop` 提供規則 5 的環案例(T3)。

## 使用到的既有串接介面

(knot-hs 自家的**五列全部來自 `F002` 設計文檔而非原始碼**——`F002` 尚未實作,`src/Knot/Query/`
不存在,已於 2026-08-21 以 `find src -iname "*Query*"` 確認,實作階段必須以落地後的真實簽名複驗;
最後兩列是下游 dev-flow 的對帳基準(2026-08-21 讀 `scan-graph.mjs` 原文);其餘為 boot 套件,簽名以
`ghc -e ':t …'` 在 GHC 9.14.1 直接查出,版本以 `ghc-pkg list` 核對:base-4.22.0.0、
containers-0.8、text-2.1.3。`ghc -e` 印出的內部模組名 `Data.Map.Internal.Map` /
`Data.Set.Internal.Set` / `Data.Text.Internal.Text` 在此還原為對外型別名 `Map` / `Set` / `Text`)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data QueryGraph = QueryGraph { qgNodes :: [QueryNode], qgIndex :: Map NodeId QueryNode, qgForward :: Map NodeId [NodeId], qgReverse :: Map NodeId [NodeId], qgOutDeg :: Map NodeId Int, qgInDeg :: Map NodeId Int, qgNotes :: [(Text, Int)] }` | (**尚未實作**)`F002` 設計文檔「實作方式 › 型別設計」→ 將落在 `src/Knot/Query/Types.hs` | F002 | `runQuery` 的第一參數;四個演算法的全部輸入(`qgNotes` 不用,那是 `F004` 的) |
| `data QueryNode = QueryNode { qnId :: NodeId, qnLabel :: Text, qnFile :: FilePath }` | (**尚未實作**)`F002` 設計文檔「實作方式 › 型別設計」→ `src/Knot/Query/Types.hs` | F002 | `FindNodes` 的比對來源與 `FoundNodes` 三元組的三個欄位 |
| `newtype NodeId = NodeId Text` `deriving (Eq, Ord, Show)` | (**尚未實作**)`F002` 設計文檔「實作方式 › 型別設計」+「新增的介面 › 非契約面」(建構子匯出) | F002 | `Map` / `Set` 的鍵、字典序排序的依據;`FindNodes` 與 `renderResult` 需要取出內含 `Text` |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | (**尚未實作**)`F002` 設計文檔「新增的介面 › 非契約面」→ `src/Knot/Query/Load.hs` | F002 | **僅測試路徑**:把手寫的 JSON 字面量變成合法 fixture 圖(不落地檔案) |
| `data LoadError = LoadFileMissing Text \| LoadParseError Text \| LoadSchemaError Text` | (**尚未實作**)`F002` 設計文檔「新增的介面 › 契約面」→ `src/Knot/Query/Types.hs` | F002 | 僅測試路徑:fixture 載入失敗時以 `assertFailure` 印出原因 |
| `findWithDefault :: Ord k => a -> k -> Map k a -> a` | containers-0.8 `Data.Map.Strict` | - | 取鄰居清單(預設 `[]`)與度數(預設 `0`) |
| `member :: Ord k => k -> Map k a -> Bool` | containers-0.8 `Data.Map.Strict` | - | 起點 / 終點是否存在於 `qgIndex`;BFS 的 visited 判定 |
| `insert :: Ord k => k -> a -> Map k a -> Map k a` | containers-0.8 `Data.Map.Strict` | - | BFS 寫入距離與前驅 |
| `empty :: Map k a` | containers-0.8 `Data.Map.Strict` | - | BFS 的初始距離 / 前驅表 |
| `lookup :: Ord k => k -> Map k a -> Maybe a` | containers-0.8 `Data.Map.Strict` | - | 路徑重建時沿前驅回溯 |
| `toAscList :: Map k a -> [(k, a)]` | containers-0.8 `Data.Map.Strict` | - | 取出 BFS 距離表(先得 id 升序,再以 `sortOn` 改成「距離、id」序) |
| `member :: Ord a => a -> Set a -> Bool` / `insert :: Ord a => a -> Set a -> Set a` / `empty :: Set a` | containers-0.8 `Data.Set` | - | 層內保序去重的累積器 |
| `toLower :: Text -> Text` | text-2.1.3 `Data.Text` | - | `FindNodes` 的不分大小寫折疊(關鍵字與 id / label 兩邊) |
| `isInfixOf :: Text -> Text -> Bool` | text-2.1.3 `Data.Text` | - | `FindNodes` 的子字串比對 |
| `pack :: String -> Text` | text-2.1.3 `Data.Text` | - | 組渲染字面量與數字(不依賴 `OverloadedStrings`,與 `Summary.hs` / `F001` 同慣例) |
| `unlines :: [Text] -> Text` | text-2.1.3 `Data.Text` | - | `renderResult` 的行組裝(每行含結尾 `\n`,與 `renderMetaSummary` 同形) |
| `intercalate :: Text -> [Text] -> Text` | text-2.1.3 `Data.Text` | - | 路徑明細行的 ` -> ` 串接 |
| `concat :: [Text] -> Text` | text-2.1.3 `Data.Text` | - | 渲染單行的欄位串接 |
| `sortOn :: Ord b => (a -> b) -> [a] -> [a]` | base-4.22.0.0 `Data.List` | - | `Reachable` 的 (距離, id) 與 `RankConnectivity` 的 (Down 總度數, id) 排序 |
| `foldl' :: Foldable t => (b -> a -> b) -> b -> t a -> b` | base-4.22.0.0 `Data.List` | - | BFS 逐層寫入距離 / 前驅、層內保序去重 |
| `Down :: a -> Down a` | base-4.22.0.0 `Data.Ord` | - | `RankConnectivity` 的總度數降序 |
| `DEP_RELATIONS` / `STRUCTURAL_RELATIONS` 常數 | dev-flow 0.8.1 `arch-audit/scripts/scan-graph.mjs:59-64` | - | **不呼叫**;列在此處是驗收標準 6 的語意出處。分類在 `F002` 完成,本 feature 不看 relation |
| `degree` 累計(`for (const e of links) { if (STRUCTURAL_RELATIONS.has(e.relation)) continue; for (const ref of [e.source, e.target]) … +1 }`) | dev-flow 0.8.1 `arch-audit/scripts/scan-graph.mjs:310-318` | - | **不呼叫**;`RankConnectivity` 的「度數 = 邊數」語意基準(2026-08-21 讀原文複驗:逐邊、跳結構邊、兩端各 +1) |

## 新增的介面

### 契約面(Level 2 原文)

**`Knot.Query.Engine`**(純函數,無 IO)

```haskell
-- | export-query 查詢面的演算法本體(Level 2 契約原文簽名)。
--   純函數:同一 'QueryGraph' 配同一 'QueryCommand' 必得同一結果
--   (查詢規則 4;排序鍵見各建構子的 haddock)。
runQuery :: QueryGraph -> QueryCommand -> QueryResult
```

**`Knot.Query.Render`**(純函數,無 IO)

```haskell
-- | 'QueryResult' → stdout 文字(Level 2 契約原文簽名)。
--   每行以 @\n@ 結尾;**不印**(D8),列印由 F004 的 CLI 層負責。
renderResult :: QueryResult -> Text
```

**`Knot.Query.Types`**(對外 DTO,契約原文;`F002` 已建立的模組)

```haskell
-- | 四種查詢指令(Level 2 契約原文)。參數解析屬 CLI 組裝層(F004)。
data QueryCommand
  = FindNodes Text                  -- ^ 關鍵字:id 與 label 的子字串比對,不分大小寫
  | Reachable NodeId Direction      -- ^ 可達集合,**不含起點自身**(查詢規則 5)
  | ShortestPath NodeId NodeId      -- ^ 兩點最短路徑,多解取字典序最小(查詢規則 6)
  | RankConnectivity Int            -- ^ 連通度排名,參數為 top N
  deriving (Eq, Show)

-- | 'Forward':它依賴誰('qgForward');'Reverse':誰依賴它('qgReverse')。
data Direction = Forward | Reverse
  deriving (Eq, Show)

-- | 查詢結果(Level 2 契約原文)。空集合與 'Nothing' 都是正常結果(exit 0 由 F004 決定)。
data QueryResult
  = FoundNodes   [(NodeId, Text, FilePath)]  -- ^ id、label、source_file;依 id 升序
  | ReachableSet [(NodeId, Int)]             -- ^ 節點與 hop 距離(≥ 1);依 (距離, id) 升序
  | PathResult   (Maybe [NodeId])            -- ^ 含起點與終點;'Nothing' = 不連通
  | Ranking      [(NodeId, Int, Int)]        -- ^ 節點、入度、出度;依 (總度數降序, id 升序)
  deriving (Eq, Show)
```

**`Knot.Query`**(查詢面對外進入點;`F002` 已建立的模組)

本 feature 只**擴充匯出清單**,不重新定義:加入 `runQuery`、`renderResult`、
`QueryCommand (..)`、`Direction (..)`、`QueryResult (..)`。`F004` 因此只需
`import Knot.Query` 一個模組即可完成整條查詢管線。

### 非契約面(供 G-E001 一併收斂;沿用 `F001` / `F002` 的既有慣例,一律以 haddock 標註)

| 匯出 | 模組 | 為什麼需要匯出 | 目前的使用者 |
|---|---|---|---|
| `Knot.Query.Engine` 這個模組本身進 `exposed-modules` | library | 測試直接對演算法下斷言(T2–T5、T7),不繞 `Knot.Query`;沿用 `Knot.Export.Encode` / `Knot.Query.Load` 的既有形狀 | 測試(`F004` 走 `Knot.Query`) |
| `Knot.Query.Render` 這個模組本身進 `exposed-modules` | library | 同上(T6) | 測試(`F004` 走 `Knot.Query`) |
| `QueryCommand (..)` / `Direction (..)` / `QueryResult (..)` 的建構子 | `Knot.Query.Types` | `F004` 要從 CLI 參數**建構** `QueryCommand`,並(若需要)對 `QueryResult` 做 exit code 判定;測試要對結果做 pattern match | `F004`、測試 |

**本 feature 不新增任何契約外的函式匯出**:`Knot.Query.Engine` 只匯出 `runQuery`、
`Knot.Query.Render` 只匯出 `renderResult`,四個演算法與 BFS 輔助函數全部是私有函數。
上表第三列的建構子匯出是契約 DTO 的必然結果(契約以 `data … = A | B` 形式定義),
與 `F002` 的 `LoadError (..)` 同性質。

## TodoList

- [x] T1: `Knot.Query.Types` 擴充三個契約 DTO(`QueryCommand` 四建構子、`Direction` 兩建構子、
      `QueryResult` 四建構子,`Eq`/`Show`);建立 `Knot.Query.Engine` 與 `Knot.Query.Render`
      兩個模組骨架並加進 `knot-hs.cabal` library 的 `exposed-modules`(**build-depends 零新增**);
      `Knot.Query` 匯出清單加上 `runQuery` / `renderResult` / 三個 DTO;`version` 不動、
      executable 段不動;`cabal build all --enable-tests` 在 `-Wall` 下零警告  `dep: F002`
- [x] T2: `runQuery` 的 `FindNodes` 分支——關鍵字與 id / label 兩邊 `T.toLower` 後
      `isInfixOf`,命中即收錄;輸出沿 `qgNodes` 的 id 升序;掃全部節點(含只被結構邊連到者);
      空關鍵字回全部節點  `dep: T1`
- [x] T3: `runQuery` 的 `Reachable` 分支——`Forward`/`Reverse` 分別走 `qgForward`/`qgReverse`;
      逐層 BFS 記錄 hop 距離;起點不入結果但**可經由環以真實距離出現**(規則 5);
      起點不存在回空集合;輸出依 (距離, id) 升序  `dep: T1`
- [x] T4: `runQuery` 的 `ShortestPath` 分支——FIFO 發現序 BFS(鄰居沿用 `qgForward` 的升序、
      層內不重排)+ 首次發現寫入前驅 + 回溯重建;連通回 `Just [from … to]`、不連通與
      端點不存在回 `Nothing`、`from == to` 回 `Just [from]`;等長多解取**字典序最小**(規則 6)
      `dep: T1`
- [x] T5: `runQuery` 的 `RankConnectivity` 分支——度數取 `qgInDeg`/`qgOutDeg`(邊數語意,不重算);
      依 (總度數降序, id 升序) 排序後 `take n`;排除總度數 0 的節點;`n <= 0` 回空清單  `dep: T1`
- [x] T6: `Knot.Query.Render.renderResult`——四個建構子的行格式、空結果只出首行、
      `PathResult Nothing` 出 `path: not connected`、路徑行的 ` -> ` 串接與 hop 數計算;
      `T.unlines` 產出(每行 `\n` 結尾)、全程不印  `dep: T1`
- [x] T7: 決定性與「只走依賴類邊」的總驗收——fixture 圖上四個查詢連跑兩次結果相等;
      `contains` 與未知 relation 邊不影響 `reachable` / `path` / `rank` 的任何結果;
      hedgehog 隨機圖屬性測試(同輸入同輸出、`Reachable` 距離恆 ≥ 1、路徑首尾正確且每一步都在
      `qgForward` 中)  `dep: T2, T3, T4, T5`

## 1-to-1 測試對照表

(全部掛在 `test/Main.hs` 新增的 `exportQueryF003Tests :: TestTree` 群組下,加進 `tests` 清單;
沿用既有 tasty + HUnit + hedgehog 慣例;查詢面型別一律走 `import qualified Knot.Query.Types as QT`
以避開與 `Knot.Graph.Types.NodeId` 的同名衝突(`F002` 立下的慣例)。fixture 圖由手寫 JSON
字面量經 `parseQueryGraph` 產生,見「實作方式 › 測試 fixture 圖的構造方式」)

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_query_command_types | 逐一建構 `FindNodes` / `Reachable … Forward` / `Reachable … Reverse` / `ShortestPath` / `RankConnectivity` 與四個 `QueryResult` 建構子並比對欄位;驗證 `Eq` 可用且四個 `QueryResult` 建構子彼此互異、`Forward /= Reverse`;fixture JSON 經 `parseQueryGraph` 回 `Right` 且節點數為 10(`Left` 時以 `assertFailure` 印出 `LoadError` 內容)——釘住後續五個測試的共用前提 |
| T2 | test_query_find | 對 fixture 圖:`FindNodes "alpha"` 與 `FindNodes "ALPHA"` 與 `FindNodes "Alpha"` 三者結果**完全相同**且命中 `Alpha`(不分大小寫,驗收標準 1);關鍵字比對 **label** 也命中——`FindNodes "start"` 命中 id 為 `S`、label 為 `Start.Module` 的節點(fixture 的 label 與 id 刻意不同,此查詢只可能經 label 命中);多命中時輸出依 **id 升序**(以刻意逆序排列的 JSON 檔證明不是檔案原序);命中三元組的第二、三欄分別等於該節點的 label 與 source_file;`FindNodes "Iso"` 找得到只被 `contains` 邊連到的節點(規則 3);`FindNodes "zzz"` 回 `FoundNodes []`;`FindNodes ""` 回全部 10 個節點(假設 A6) |
| T3 | test_query_reachable | 對 fixture 圖:`Reachable "S" Forward` 回 `[(Alpha,1),(Beta,1),(Whisky,2),(Xray,2),(T,3)]`——**距離正確、依 (距離, id) 升序、不含起點 S**(規則 5 前半、規則 4);`Reachable "T" Reverse` 回 S/Alpha/Beta/Whisky/Xray 且距離對稱(方向正確,驗收標準 2),`Reachable "T" Forward` 回 `[]`;`Reachable "Self" Forward` 回 `[(Self,1)]`、`Reachable "Loop" Forward` 回 `[(Cyc,1),(Loop,2)]`——起點在環上時**以真實距離出現**(規則 5 後半);`Reachable "Iso" Forward` 回 `[]`(只有 `contains` 邊);`Reachable "NoSuchNode" Forward` 回 `[]` 而不拋例外(假設 A1) |
| T4 | test_query_path | 對 fixture 圖:`ShortestPath "S" "T"` 回 `Just [S,Alpha,Xray,T]`——**兩條等長路徑取字典序最小**(規則 6);此處同時是**反向貪心的反例**:終點 `T` 的兩個前驅是 `Whisky` 與 `Xray`,`Whisky < Xray`,若實作誤取「前驅 id 最小」會回 `Just [S,Beta,Whisky,T]`,測試必須失敗;`ShortestPath "S" "Alpha"` 回 `Just [S,Alpha]`(1 hop);`ShortestPath "Alpha" "S"` 回 `Nothing`(反向不通,驗收標準 4);`ShortestPath "S" "Iso"` 回 `Nothing`(`contains` 邊不算路,驗收標準 6);`ShortestPath "S" "S"` 回 `Just [S]`(假設 A2);`ShortestPath "S" "NoSuchNode"` 與 `ShortestPath "NoSuchNode" "S"` 皆回 `Nothing`(假設 A1);同一查詢跑兩次結果相等 |
| T5 | test_query_rank | 對 fixture 圖:`RankConnectivity 100` 恰回 **9** 列(10 個節點扣掉 `Iso`),逐列等於手算值 `[(Alpha,2,1),(S,0,3),(Beta,1,1),(Cyc,1,1),(Loop,1,1),(Self,1,1),(T,2,0),(Whisky,1,1),(Xray,1,1)]`。這一條斷言同時釘住四件事:**度數走邊數語意**——`S` 的出度為 3(`S→Alpha` 重複兩次計 2、加 `S→Beta`)、`Alpha` 的入度為 2,若誤用相異鄰居數會變成 2 與 1(`F002` 假設 A4);**同分按 id 升序**——`Alpha` 與 `S` 同為總度數 3 而 `Alpha` 在前,尾端 `Whisky` / `Xray` 同為 `(1,1)` 而 `Whisky` 在前(驗收標準 5);**自環兩端各 +1**——`Self` 為 `(1,1)`;**零連通度排除**——`Iso` 不在輸出中(只有 `contains` 邊,假設 A3)。另:`RankConnectivity 3` 恰回前三列 `[(Alpha,2,1),(S,0,3),(Beta,1,1)]`(`--top N` 生效);`RankConnectivity 0` 與 `RankConnectivity (-1)` 回 `Ranking []`(假設 A4) |
| T6 | test_render_result | `renderResult (FoundNodes [(NodeId "A","lbl","src/A.hs")])` 逐字元等於 `"found: 1 nodes\n  A  lbl  src/A.hs\n"`;`FoundNodes []` 等於 `"found: 0 nodes\n"`;`ReachableSet [(NodeId "B",2)]` 等於 `"reachable: 1 nodes\n  2  B\n"`;`PathResult (Just [A,B,C])` 等於 `"path: 2 hops\n  A -> B -> C\n"`、`PathResult (Just [A])` 等於 `"path: 0 hops\n  A\n"`;`PathResult Nothing` 等於 `"path: not connected\n"`(驗收標準 4);`Ranking [(NodeId "A",1,2)]` 等於 `"rank: 1 nodes\n  3  A  in=1 out=2\n"`;所有輸出皆以 `\n` 結尾且**不含 `\r`**;對同一 `QueryResult` 呼叫兩次結果相同 |
| T7 | test_query_determinism | (a)fixture 圖上四個 `QueryCommand` 各跑兩次,`runQuery` 結果與 `renderResult` 文字皆相等(驗收標準 7);(b)把 fixture JSON 的 **`nodes` 與 `links` 陣列整個反轉**後重新 `parseQueryGraph`,四個查詢的結果與原順序**完全相同**(釘住結果不依賴檔案順序);(c)把 fixture 的 `contains` 邊與 `foo` 未知邊**整批刪除**後重新載入,`reachable` / `path` / `rank` 的結果與原圖**完全相同**,而 `find` 的結果**也相同**(節點仍在,規則 3)——驗收標準 6;(d)hedgehog 屬性:隨機生成 3–8 個節點 id(`Gen.element` 自固定字母表,確保重複與字典序邊界)與 0–15 條依賴邊,組成 JSON 後 `parseQueryGraph`,對隨機起點/終點斷言:`runQuery` 兩次相等;`Reachable` 的所有距離 ≥ 1 且依 (距離, id) 升序;`ShortestPath` 若回 `Just p` 則 `head p == from`、`last p == to`、相鄰兩點皆在 `qgForward` 的鄰居清單中、且 `length p - 1` 等於 `Reachable from Forward` 中 `to` 的距離(最短性交叉驗證) |

## 待確認假設

- A1: 契約的 `QueryResult` 沒有錯誤建構子,但 `Reachable` / `ShortestPath` 的起點(或終點)
  可能不存在於圖中 → 採取:**回空結果**(`ReachableSet []` / `PathResult Nothing`),
  `runQuery` 永不失敗;`qgIndex` 的存在性檢查只用來把「起點不存在」與「`from == to`」分開處理
  → 影響:使用者打錯 id 時看到的是「查無結果」而非「沒有這個節點」。**建議 `F004` 在 CLI 層
  自行以 `qgIndex` 判存在性並印更明確的訊息**(不動 library 契約);若裁定 library 要回報,
  需 Level 2 新增錯誤通道(契約變更)
- A2: `ShortestPath a a` 的語意契約未定(規則 5 只規範 `Reachable`)→ 採取:**回 `Just [a]`
  (0 hop)**,不去找經過環回到自己的路徑;理由:`path` 問的是「怎麼從 a 走到 a」,零步即已抵達,
  且與規則 5 的差異是刻意的——`Reachable` 問「能到哪些節點」,`a` 要出現就必須真的走過去
  → 影響:若裁定 `path a a` 應回最短環(不存在則 `Nothing`),改 `shortestPath` 的短路分支一行
  (改成不短路、BFS 找回 `a`),T4 的一條斷言反向
- A3: `RankConnectivity` 是否納入總度數為 0 的節點,契約未定 → 採取:**排除**(只被 `contains`
  邊連到或完全孤立的節點不進榜),對齊下游 `scan-graph.mjs:310-318` 的 `degree` map 只收
  非結構邊端點 → 影響:若裁定納入,刪掉一個 filter,`RankConnectivity 100` 在 fixture 上多出
  `Iso` 一列(`0 0`),T5 改一條斷言
- A4: `RankConnectivity n` 的 `n <= 0` 行為契約未定(`--top N` 的預設 10 由 `F004` 給,但使用者
  可以打 `--top 0`)→ 採取:**`take` 的自然語意 → 空清單**,不視為錯誤 → 影響:若裁定
  `n <= 0` 應等同「不限制」,改 `take` 前加一個守衛;`F004` 若選擇在解析層擋掉負數則本項不觸發
- A5: `renderResult` 的文字格式與**語言**契約未定(驗收標準只寫「不連通時明確輸出」)→ 採取:
  **英文小寫、`key: value` 首行 + 兩空格縮排明細行**,對齊既有 `app/Knot/App/Summary.hs` 的
  `renderMetaSummary` 系列與 `F001` 的 `xrNotes`;「不連通」落地為 `path: not connected`
  → 影響:若裁定改中文或鍵值化輸出,只動 `Knot.Query.Render` 一個模組與 T6 的字面量,
  演算法面零改動
- A6: `FindNodes ""`(空關鍵字)的行為契約未定 → 採取:**回全部節點**(`T.isInfixOf` 對空字串
  恆為 `True`,不特判)→ 影響:若裁定空關鍵字應回空集合或視為錯誤,加一個 `T.null` 守衛;
  CLI 層是否允許空字串參數屬 `F004`
- A7: 契約卡「實作的 Level 2 介面」只寫「查詢規則 3、4」,但 W2 期間新增的**查詢規則 5、6**
  明確規範 `Reachable` 與 `ShortestPath` 的演算法語意(`F002` 也已把兩條標為「屬 `F003`」)
  → 採取:**一併實作規則 3、4、5、6**,並以 `design.md` 為準(契約卡與 `design.md` 落差時以
  `design.md` 為準)→ 影響:若編排者裁定規則 5、6 不屬本 feature,`Reachable` 的環處理與
  `ShortestPath` 的字典序最小保證要從 T3 / T4 拿掉——但那會讓兩條契約規則無人實作,
  故建議直接補契約卡的介面清單

## 實作備註

非契約面公開匯出的清單已預先登記在「新增的介面 › 非契約面」,供 build-log 階段一
發現 2 所指的 `G-E001` 一併收斂。

### `F002` 真實簽名複驗(2026-08-21,設計時 `F002` 尚未實作)

「使用到的既有串接介面」表中標注「來源文檔 = F002」的五列,已對落地後的原始碼逐一複驗,
**五列全部一字不差,無任何落差**:

| 設計文檔記載的簽名 | 真實原始碼位置 | 結果 |
|---|---|---|
| `QueryGraph` 七欄位 | `src/Knot/Query/Types.hs:49-58` | 一致(另 `deriving (Eq, Show)`,設計未寫但不影響) |
| `QueryNode { qnId, qnLabel, qnFile }` | `src/Knot/Query/Types.hs:31-36` | 一致 |
| `newtype NodeId = NodeId Text deriving (Eq, Ord, Show)` | `src/Knot/Query/Types.hs:26-27` | 一致 |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | `src/Knot/Query/Load.hs:115` | 一致 |
| `LoadError` 三建構子 | `src/Knot/Query/Types.hs:64-68` | 一致 |

唯一與設計文稿的細節差異(**不是契約落差**):`Knot.Query.Types` 只匯出 `NodeId (..)` 的
建構子,**沒有 `unNodeId` 具名選擇器**(`F002` 的 `unNodeId` 是 `Knot.Query.Load` 的私有函數)。
設計文檔「FindNodes」與「renderResult」段落的虛擬碼寫了 `unNodeId (qnId n)`——落地時
`Knot.Query.Engine` 與 `Knot.Query.Render` 各自以匯出的建構子做模式比對定義同名私有函數。
屬實作自主權範圍,契約零變動。

### `F002` 實作階段確立、設計文檔未寫到的兩條語意(已遵守)

1. **鄰接表 / 度數的「缺鍵」語意**:`qgForward` / `qgReverse` / `qgOutDeg` / `qgInDeg`
   只收錄**實際有依賴邊**的節點,無邊者是**缺鍵**而非空清單 / 0。本 feature 取值一律走
   `Map.findWithDefault [] n` / `Map.findWithDefault 0 n`;「全部節點」一律走
   `qgNodes`(`FindNodes`、`RankConnectivity` 的來源)與 `qgIndex`(端點存在性判定)
2. **鄰接表已去重且升序、度數已是邊數**:BFS 直接取用,**不重排、不重算**

### 其他

- `design.md` 查詢規則 6 的措辭在本 feature 開工前收緊(「展開某個節點時把鄰居依 id 排序後
  入列」vs「把整層佇列依 id 重排」),與本文檔的歸納證明與 T4 反例 fixture **一致**,
  照原設計實作,零改動
- T4 的反例 fixture 已做**機械性反向驗證**:把 `Knot.Query.Engine` 的層內順序臨時改成
  `sort (map fst fresh)`(即「整層佇列依 id 重排」),`test_query_path` 立即失敗於
  `expected: Just [S,Alpha,Xray,T] but got: Just [S,Beta,Whisky,T]`,確認這條斷言真的擋得住
  退化實作;驗證後已還原
- `renderResult` 對 `PathResult (Just [])` 的防禦性處理:該值不可能來自 `runQuery`
  (路徑恆含起點與終點),但為維持全函數且不產生一條空白明細行,落地為「只出
  `path: 0 hops` 首行」,T6 有一條斷言釘住
- 既有 74 個測試全綠,本 feature 新增 10 個(T1–T6 各 1、T7 四個子項),合計 **84 個全數通過**
- 本次改動的新程式碼**零警告**;`test/Main.hs` 既有的 8 筆 `-Wincomplete-record-selectors`
  (extraction `Fact` 部分選擇器)未觸碰,行號因新增 import 而由 ~1200/~1327 位移至 ~1206/~1333
