---
id: F002
type: feature
title: graph-load
description: 讀回 codegraph.json、驗證結構並分流出查詢用依賴圖
status: done
created: 2026-08-21
updated: 2026-08-21
depends-on: [F001, graph-core/F001]
related-adr: [ADR-003]
related-feature: []
---

# F002: graph-load — codegraph.json → QueryGraph

## 功能概述

export-query 查詢面的第一站,也是主架構 S4「`knot query`」管線的入口:把磁碟上的 `codegraph.json`
讀進來、驗證結構、依 relation 分流成「查詢用依賴圖」`QueryGraph`,或回傳 `LoadError`。

**要解決的問題**:`codegraph.json` 是**對外契約格式**(`ADR-003`),不是 knot-hs 的內部模型。查詢面
刻意**只認這個檔**(子系統邊界「不重跑抽取」),所以它可能來自:

1. knot-hs 自己的 `F001` json-export(只會出現五種 relation:`imports` / `calls` / `uses` /
   `implements` / `contains`)
2. **任何其他吐得出這個格式的產生器**(graphify 等)——dev-flow 契約的依賴類 relation 有十種、
   結構類六種,遠多於 knot 自己產生的五種
3. 使用者手改壞掉的檔案

因此本 feature 的職責是三件事:(a)**讀不到 / 壞 JSON / 結構不合** → 明確的 `LoadError`,不修不猜;
(b)**relation 三分類**——依賴類進依賴圖、結構類靜默排除、認不得的排除並彙整成
`queryGraphNotes` 供 CLI 層列印;(c)把 `QueryGraph` 組成 `F003` 四種查詢演算法**直接可用**的形狀
(鄰接表、度數、節點索引),且**同一份檔案載入結果恆等**。

**驗收標準**(契約卡原文,逐條對照落地):

| # | 契約卡原文 | 落地 | 測試 |
|---|---|---|---|
| 1 | 讀自家 json-export 的輸出成功 | 測試以 `writeCodegraph` 寫出真實檔案再 `loadQueryGraph` 讀回,節點/邊數與內容對得上 | T5 |
| 2 | 缺 `nodes` 時回 `LoadError` 且訊息指出問題 | `LoadSchemaError "<path>: missing required field \"nodes\""` | T4 |
| 3 | 邊引用不存在的節點 id 時回 `LoadError` 且訊息指出問題 | `LoadSchemaError "<path>: links[7]: source \"X\" is not a known node id"` | T4 |
| 4 | 含未知 relation(如 `"foo"`)的檔案能載入、該類邊被排除且列印「relation 名 + 邊數」 | 載入成功;該邊不進 `qgForward`/`qgReverse`/度數;`queryGraphNotes` 回 `[("foo", n)]`。**library 不印**(D8),列印是 `F004` 拿 `queryGraphNotes` 印 stderr(契約 C2) | T3 |
| 5 | `contains` 邊載入後不出現在依賴圖(以 reachable 驗證) | `contains` 屬結構類,不進 `qgForward`/`qgReverse`/度數,也**不**進 `queryGraphNotes`(它是已知的結構類,不是未知)。**`reachable` 本身是 `F003` 的演算法,本階段尚不存在**,故 T3/T5 改為對 `reachable` 的唯一資料來源 `qgForward`/`qgReverse` 直接斷言——涵蓋範圍等價(`Reachable` 只讀這兩張表) | T3、T5 |

**明確不做**(契約卡底線):不實作查詢演算法(`FindNodes` / `Reachable` / `ShortestPath` /
`RankConnectivity` 全屬 `F003`);不寫任何檔案(全程唯讀);不嘗試修復壞 JSON(直接 `LoadError`,
不做「盡量讀出能讀的部分」)。另承子系統邊界:不建圖、不改圖、不碰 `.hie` 或原始碼。另承 D8:
**library 全程不印任何輸出**——未知 relation 的「列印」透過 `queryGraphNotes` 這條通道交給 CLI 層。
另承 D3:本 feature **不動 `app/Main.hs`** 與 executable 段。另承 D6:`knot-hs.cabal` 的 `version`
維持 `0.0.1.0` 不動。

## 相依性

`depends-on: [F001, graph-core/F001]`,兩條皆由「使用到的既有串接介面」表反推,且**都只落在測試路徑**;
library 端的 `Knot.Query.*` 三個模組**不 import 任何 knot-hs 自家模組**(見下)。兩份文檔皆
`status: done`、程式碼已在 `main`,故兩條都是**既有程式碼查證**(2026-08-21 自來源檔讀出原文),
沒有任何一條是文檔約定。

- **`F001` json-export(同子系統)**:驗收標準 1「讀自家 json-export 的輸出成功」要求測試真的走一次
  `writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport`(`src/Knot/Export.hs:33`)把檔案落地,
  再用 `loadQueryGraph` 讀回。**同時是格式的資料依賴**:本 feature 讀的欄位集合就是 `F001` 投影規則
  1–5 寫出的欄位集合(`design.md` 功能規劃「graph-load 依賴 #1」的實質內容)
- **`graph-core/F001` module-graph(跨子系統)——僅測試路徑**:同一條 round-trip 的輸入端要手寫一個
  `CodeGraph`,需要 `CodeGraph` / `GraphNode` / `GraphEdge` / `Relation` / `GraphStats` / `NodeId`
  六個型別(`src/Knot/Graph/Types.hs`)

**library 端零 knot-hs 相依(刻意)**:`Knot.Query.Types` / `Knot.Query.Load` / `Knot.Query` 只 import
`aeson`、`bytestring`、`containers`、`text` 與 `base`。這是 `ADR-003`「這是匯出格式,不是內部模型」在
查詢面的鏡像:查詢面既然只認 JSON,就不該認得上游的任何型別。build-log 階段一「發現 6」點出的
`Encode` → `Knot.Meta.Types (ModuleName)` 那種訊號在本 feature **不存在**——代價是本 feature 自己定義
一個 `NodeId`(見假設 A1),而不是沿用 `Knot.Graph.Types.NodeId`。

未列入的相依與理由:

- **`project-meta/F001` / `extraction/F001` / `extraction/F002`**:`F001` json-export 的 T6 走了完整管線,
  是因為它要驗「真實圖的投影」;本 feature 驗的是**讀回**,輸入用手寫 `CodeGraph` 就能同時覆蓋
  `contains` 邊與多種 relation(真實管線在 S1 只產得出 `imports`),再走完整管線只是把 `F001` 的 T6 抄一遍,
  不增加任何對 graph-load 的覆蓋。故不呼叫、不列入
- **同子系統的 `F003` / `F004`**:方向相反(`F003` 消費本 feature 產出的 `QueryGraph`,`F004` 呼叫
  `loadQueryGraph` 與 `queryGraphNotes`)
- **`graph-core/F002` / `F003`(decl 層)**:它們只讓匯出檔多出 `calls` / `uses` / `implements` /
  `contains` 邊,**不改 JSON 的欄位集合**;本 feature 的 relation 分類表已涵蓋 dev-flow 契約的全部
  十六種名稱,decl 層上線時載入層零改動
- **`ADR-003`** 列在 `related-adr` 而非 `depends-on`:它是欄位集合與 relation 兩類的權威來源,不是任務文檔

**可平行性**:**不可**與 `F001` 平行(`F001` 已 done,無實際等待);與其他子系統的任務**可**平行。
export-query 內部仍是序列:`F003` 讀本 feature 的 `QueryGraph`,`F004` 呼叫本 feature 的兩個進入點。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/export-query/design.md`「對外契約 › 查詢面」與「查詢規則」,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| `loadQueryGraph :: FilePath -> IO (Either LoadError QueryGraph)` | `Knot.Query.loadQueryGraph`,簽名一字不差 |
| `queryGraphNotes :: QueryGraph -> [(Text, Int)]`(未知 relation 名 + 邊數) | `Knot.Query.Load.queryGraphNotes`,經 `Knot.Query` 再匯出;簽名一字不差 |
| DTO `QueryGraph`(「從 codegraph.json 載入的查詢用圖(內容屬 Level 3)」) | `Knot.Query.Types.QueryGraph`,七個欄位皆為 Level 3 決定(見「實作方式」);`Knot.Query` 只匯出**抽象型別**,欄位由同子系統的 `F003` 經 `Knot.Query.Types` 取用 |
| DTO `LoadError = LoadFileMissing Text \| LoadParseError Text \| LoadSchemaError Text` | `Knot.Query.Types.LoadError`,三建構子與契約原文一致 |
| 查詢規則 1(依賴類邊才進圖:十種依賴類、六種結構類) | `classifyRelation`:十種 → `RelDependency`(進 `qgForward` / `qgReverse` / 度數)、六種 → `RelStructural`(排除且不列入 notes)、其餘 → `RelUnknown`(排除且累加進 notes) |
| 查詢規則 2(未知 relation 彙整列印,不靜默吞掉) | 累加成 `qgNotes :: [(Text, Int)]`,由 `queryGraphNotes` 取出;**library 不印**(D8),列印通道是 `F004`(契約 C2) |
| 查詢規則 4(決定性:結果排序穩定,同值按 id 字典序) | 載入時就把序固定住:`qgNodes` 依 `qnId` 升序、鄰接表去重後依 id 升序、`qgNotes` 依 relation 名升序。`F003` 因此不必自己維持穩定序 |
| 查詢規則 5(`Reachable` 不含起點) | 屬 `F003`;本 feature 的支撐:`qgForward` / `qgReverse` **保留自環**(`A → A` 的依賴邊照樣進表),起點在環上時 `F003` 才能算出真實距離 |
| 查詢規則 6(`ShortestPath` 多解取字典序最小) | 屬 `F003`;本 feature 的支撐:鄰接表**已依 id 升序排好**,`F003` 的 BFS 直接照序展開即可,不必在演算法裡再排一次 |
| 查詢規則 3(`FindNodes` 比對所有節點,含結構類邊連接的節點) | 本 feature 的支撐:`qgNodes` 收錄**全部**節點(是否被任何邊連到都無關),結構類邊只影響鄰接表不影響節點集合 |
| 資料流管線「查詢」段落:`讀檔 → 驗證 → 依賴類/結構類分流 → QueryGraph(壞檔 → LoadError)` | `loadQueryGraph`(IO 讀檔)→ `parseQueryGraph`(純函數:解析 → 驗證 → 分流),順序與契約圖一致 |
| 錯誤策略:`LoadError` 屬「使用者給錯輸入」,直接失敗而非 best-effort | 三種錯誤一律**中止載入**回 `Left`,不產出部分圖;exit code 由 `F004` 決定 |
| 「使用的技術」· aeson | 以 `Data.Aeson.eitherDecodeStrict'` 解成 `Value`,再手動走 `KeyMap`;**不寫 `FromJSON` instance**(理由見「實作方式」) |

**未觸碰的契約面**:`runQuery` / `renderResult` 與 DTO `QueryCommand` / `Direction` / `QueryResult`
(`F003`);CLI 子命令對映(`F004`);匯出面全部(`F001` 已完成)。

## 實作方式

### 模組配置

Level 2 的內部模組表列一個 `graph-load`。Haskell 落地時拆成三個模組(實作自主權,形狀**逐項對應**
`F001` 已通過閘門的 `Knot.Export` / `.Types` / `.Encode` 拆法):

| Haskell 模組 | 職責 | IO |
|---|---|---|
| `Knot.Query.Types` | `NodeId` / `QueryNode` / `QueryGraph` / `LoadError` | 無 |
| `Knot.Query.Load` | **純函數**:`parseQueryGraph`(解析 + 驗證 + 分流)、`queryGraphNotes`、relation 分類 | 無 |
| `Knot.Query` | 查詢面對外進入點:`loadQueryGraph`(唯一的 IO:讀檔),再匯出契約面型別 | 有(唯讀:讀檔) |

三個模組全部進 `exposed-modules`(測試要直接測 `parseQueryGraph` 的純函數分支)。
`Knot.Query` 之於查詢面 = `Knot.Export` 之於匯出面:`F003` 會往 `Knot.Query` 的匯出清單再加
`runQuery` / `renderResult`,`F004` 因此只需 import `Knot.Query` 一個模組。

### 型別設計

```haskell
newtype NodeId = NodeId Text          -- 查詢面自己的節點 id(見假設 A1)

data QueryNode = QueryNode
  { qnId    :: NodeId
  , qnLabel :: Text                   -- FindNodes 比對用
  , qnFile  :: FilePath               -- FoundNodes 的第三欄
  }

data QueryGraph = QueryGraph
  { qgNodes   :: [QueryNode]          -- 全部節點,依 qnId 升序(規則 3、4)
  , qgIndex   :: Map NodeId QueryNode -- 起點存在性檢查與 id → 節點(F003)
  , qgForward :: Map NodeId [NodeId]  -- 依賴類邊;鄰居去重、依 id 升序(規則 6)
  , qgReverse :: Map NodeId [NodeId]  -- 同上,反向(Direction = Reverse)
  , qgOutDeg  :: Map NodeId Int       -- 依賴類**邊數**(不去重),RankConnectivity 用
  , qgInDeg   :: Map NodeId Int       -- 同上
  , qgNotes   :: [(Text, Int)]        -- 未知 relation 名 + 邊數,依名升序
  }
```

- **鄰接表去重、度數不去重**:BFS 只需要「有沒有這個鄰居」,重複邊只會拖慢;但「連通度」是邊的量體
  ——同一對節點同時有 `imports` 與 `calls` 時,度數算 2。這與下游 `scan-graph.mjs` 的 hub 計算一致
  (`scan-graph.mjs:311-318` 對每條非結構邊的兩端各 +1)。兩者分開存,`F003` 不需要重算(假設 A4)
- **自環保留**:`A → A` 的依賴邊進 `qgForward`(A 的鄰居含 A)、`qgOutDeg`/`qgInDeg` 各 +1
  ——查詢規則 5「起點若處在環上,會以其真實距離出現」的必要條件
- **`qgIndex` 與 `qgNodes` 是同一批節點的兩種形狀**(一個給 `FindNodes` 線性掃、一個給 id 查詢);
  重複儲存換取 `F003` 零預處理
- deriving:全部 `(Eq, Show)`;`NodeId` 另有 `Ord`(`Map` 鍵與字典序排序的前提)

### 為什麼不寫 `FromJSON` instance

`eitherDecodeStrict'` 解到 `Value` 後**手動走 `KeyMap`**,不定義 `FromJSON QueryGraph`:

1. **錯誤訊息要指出問題**(驗收標準 2、3)。aeson 的 `Parser` 錯誤是 `String` 且路徑格式由 aeson 決定;
   `LoadSchemaError` 要求我們自己組「哪個欄位、第幾筆、什麼問題」
2. **`LoadParseError` 與 `LoadSchemaError` 必須分得開**。走 `FromJSON` 時「JSON 語法壞掉」與「欄位型別不對」
   都是同一個 `Left String`,分不出來
3. 「邊引用不存在的節點 id」是**跨元素**的驗證,本來就不在單一 `FromJSON` 的能力範圍內

### `parseQueryGraph` 的步驟(純函數,fail-fast)

`parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph`
(`FilePath` 只用來組訊息,不做任何 IO)

1. `eitherDecodeStrict' bs :: Either String Value`;`Left msg` → `LoadParseError "<path>: invalid JSON: <msg>"`
2. 頂層必須是 `Object`,否則 `LoadSchemaError "<path>: top level is not a JSON object"`
3. `nodes`:**必要**。缺鍵 → `LoadSchemaError "<path>: missing required field \"nodes\""`;
   不是 `Array` → `"<path>: \"nodes\" is not an array"`。**空陣列合法**(空專案的匯出就是 `"nodes": []`,
   驗收標準 1 不能因此失敗)
4. 逐個節點(索引 0 起):必須是 `Object`,且 `id` / `label` / `source_file` 三鍵存在且為 `String`。
   缺鍵 → `"<path>: nodes[3]: missing required field \"label\""`;型別不對 →
   `"<path>: nodes[3]: field \"label\" is not a string"`。**其餘欄位(`source_location` 等)一律忽略**
   (`ADR-003`:多餘欄位可安全擴充)
5. 建 `qgIndex`;**id 重複** → `LoadSchemaError "<path>: nodes[5]: duplicate node id \"X\""`(假設 A3)
6. `links`:**選填**。缺鍵 → 當作 `[]`(假設 A2);存在但不是 `Array` → `"<path>: \"links\" is not an array"`
7. 逐條邊(索引 0 起):必須是 `Object`,且 `source` / `target` / `relation` 三鍵存在且為 `String`
   (訊息形狀同步驟 4,前綴為 `links[7]`)。**`source` / `target` 只接受節點 id 字串,不接受陣列索引**
   ——`ADR-003` 明文「source/target 是節點 id,不是索引」(`scan-graph.mjs:97` 為相容舊格式而接受數字,
   我們不接)
8. `source` 與 `target` 都必須落在步驟 5 的 id 集合內,否則
   `LoadSchemaError "<path>: links[7]: source \"X\" is not a known node id"`(`target` 同理)。
   **這一步對所有邊執行,不分 relation 類別**——契約管線寫的是「驗證 → 分流」,先驗證再分類
9. 分流(查詢規則 1),`classifyRelation :: Text -> RelationClass`:
   - `RelDependency`(十種):`imports` `imports_from` `calls` `uses` `references` `extends`
     `implements` `inherits` `instantiates` `depends_on` → 累進 `qgForward` / `qgReverse` /
     `qgOutDeg` / `qgInDeg`
   - `RelStructural`(六種):`contains` `method` `defines` `declares` `rationale_for` `part_of`
     → **靜默排除**(已知的非依賴關係,不是「認不得」,不進 `qgNotes`)
   - `RelUnknown`:其餘任何字串(含空字串) → 排除,並 `insertWith (+) rel 1` 進未知計數
10. 收尾定序(規則 4):`qgNodes` 依 `qnId` 升序;每張鄰接表的鄰居先過 `Set` 去重再 `toAscList`;
    `qgNotes` 由 `Map Text Int` 的 `toAscList` 取出(relation 名升序)

**fail-fast**:第一個違規就回 `Left` 並中止(契約的 `LoadError` 只帶一個 `Text`,無法承載多筆);
掃描順序固定(頂層 → nodes 依索引 → links 依索引),所以「同一份壞檔恆回同一個訊息」。

**訊息格式**:一律 `"<path>: <locus>: <problem>"`(頂層問題無 `<locus>`),英文小寫,陣列索引 **0 起**,
JSON 鍵與 id 值以 `show`/雙引號包起來。風格對齊 `F001` 的 `xrNotes`(假設 A4 的既有慣例)。

### `loadQueryGraph` 進入點

```text
loadQueryGraph path = do
  r <- try (BS.readFile path)                     -- IOException
  pure $ case r of
    Left e  | isDoesNotExistError e -> Left (LoadFileMissing "<path>: file not found")
            | otherwise             -> Left (LoadFileMissing "<path>: cannot read file: <show e>")
    Right bs -> parseQueryGraph path bs
```

- **用 `try` 而不是先 `doesFileExist` 再讀**:免掉 TOCTOU,也一併涵蓋「路徑是目錄」「權限不足」
  ——契約對 `LoadFileMissing` 的註解本來就是「檔案不存在 / **讀不到**」
- **`BS.readFile` 是 binary 讀取**:不做平台換行或編碼轉換,`eitherDecodeStrict'` 自己吃 UTF-8 bytes
  (與 `F001` 的 `BB.writeFile` 對稱,round-trip 才成立)
- **全程不印**(D8):錯誤一律變成 `LoadError` 的 `Text` 回給呼叫端

### 未觸及的檔頭欄位

`directed` / `built_at_commit` 與任何其他頂層鍵**一律忽略**:

- `built_at_commit` 是新鮮度資訊,查詢面用不到
- `directed` 缺省即有向(`ADR-003`);本 feature **一律當有向圖處理**,`directed: false` 也不改變行為、
  不回錯。理由:契約的 `QueryGraph` 沒有無向的形狀,`LoadError` 三建構子也沒有「警告」語意,而
  `queryGraphNotes` 的型別 `[(Text, Int)]` 是給 relation 用的,塞警告會扭曲契約(假設 A5)

### cabal 變更

- library `exposed-modules` +3:`Knot.Query`、`Knot.Query.Types`、`Knot.Query.Load`
- library `build-depends`:**零新增**——`aeson` / `bytestring` / `containers` / `text` / `base` 全部
  已在 library 段(`knot-hs.cabal:28-37`)
- test-suite `build-depends`:**零新增**——`aeson` / `bytestring` / `directory` / `filepath` /
  `tasty-hunit` 等皆已在(`knot-hs.cabal:56-68`)
- `version` **維持 `0.0.1.0` 不動**(D6);executable 段**不動**(D3)

### `NodeId` 同名的已知處理

新增的 `Knot.Query.Types.NodeId` 與既有 `Knot.Graph.Types.NodeId`(`src/Knot/Graph/Types.hs:50`)同名。
與 `F001` 假設 A7 的 `rootDir` 是同一類問題,而且更單純——它是**型別與建構子**不是記錄欄位,
`DisambiguateRecordFields` 完全不涉入,唯一解就是 qualified import:

- **library 端無風險**:`Knot.Query.*` 三個模組**完全不 import** `Knot.Graph.Types`
- **`test/Main.hs`**:既有第 85-95 行已 `import Knot.Graph.Types (…, NodeId (..), …)`,本 feature 另需
  查詢面型別 → 新增 `import qualified Knot.Query.Types as QT`,查詢面的值一律寫 `QT.NodeId`、
  `QT.qgForward` 等(沿用 `F001` 留下的 `import qualified Knot.Extract.Types as XT` 慣例)
- **`F004` 要注意**:CLI 層要從字串建 `QueryCommand`,用到的是**查詢面**的 `NodeId`;它不需要
  graph-core 的 `NodeId`(`buildGraph` 的結果整包交給 `writeCodegraph`),所以只要不同時 import
  兩個 Types 模組就沒有衝突

## 使用到的既有串接介面

(knot-hs 自家程式碼標行號,2026-08-21 自來源檔讀出原文;aeson 讀自 hackage tarball
`C:/cabal/packages/hackage.haskell.org/aeson/2.3.1.0/aeson-2.3.1.0.tar.gz` 解出的原始碼並標行號;
boot 套件的簽名以 `ghc -e ':t …'` 在 GHC 9.14.1 直接查出,版本以 `ghc-pkg list` 核對)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `eitherDecodeStrict' :: (FromJSON a) => B.ByteString -> Either String a` | aeson-2.3.1.0/src/Data/Aeson.hs:255 | - | 步驟 1:bytes → `Value`;`Left` 即 `LoadParseError` 的來源 |
| `data Value = Object !Object \| Array !Array \| String !Text \| Number !Scientific \| Bool !Bool \| Null` | aeson-2.3.1.0/src/Data/Aeson/Types/Internal.hs:366-372 | - | 手動走樹的核心;步驟 2/3/4/6/7 全部靠 pattern match 判型 |
| `type Object = KeyMap Value` | aeson-2.3.1.0/src/Data/Aeson/Types/Internal.hs:360 | - | 頂層、節點、邊三種物件的表示 |
| `type Array = Vector Value` | aeson-2.3.1.0/src/Data/Aeson/Types/Internal.hs:363 | - | `nodes` / `links` 的表示;以 `Data.Foldable.toList` 攤成清單(**不加 `vector` 依賴**) |
| `lookup :: Key -> KeyMap v -> Maybe v` | aeson-2.3.1.0/src/Data/Aeson/KeyMap.hs:176(Map 版)/ :389(HashMap 版) | - | 取 `nodes` / `links` / `id` / `label` / `source_file` / `source` / `target` / `relation` |
| `newtype Key = Key { unKey :: Text }` | aeson-2.3.1.0/src/Data/Aeson/Key.hs:43 | - | `KeyMap` 的鍵型別 |
| `fromText :: Text -> Key` | aeson-2.3.1.0/src/Data/Aeson/Key.hs:52 | - | 建構欄位鍵(不依賴 `OverloadedStrings`,與 `F001` 的 `Knot.Export.Encode` 同一慣例) |
| `readFile :: FilePath -> IO ByteString` | bytestring-0.12.2.0 `Data.ByteString` | - | `loadQueryGraph` 唯一的 IO;binary 讀取,不做編碼/換行轉換 |
| `try :: Exception e => IO a -> IO (Either e a)` | base-4.22.0.0 `Control.Exception` | - | 捕獲讀檔的 `IOException` → `LoadFileMissing` |
| `isDoesNotExistError :: IOError -> Bool` | base-4.22.0.0 `System.IO.Error` | - | 分辨「檔案不存在」與其他讀取失敗,兩者訊息不同 |
| `toList :: Foldable t => t a -> [a]` | base-4.22.0.0 `Data.Foldable` | - | `Array`(`Vector`)→ `[Value]`,免掉 `vector` 依賴(`test/Main.hs:16` 已是同一用法) |
| `fromListWith :: Ord k => (a -> a -> a) -> [(k, a)] -> Map k a` | containers-0.8 `Data.Map.Strict` | - | 一次把邊清單摺成 `qgForward` / `qgReverse`(值先收成清單) |
| `insertWith :: Ord k => (a -> a -> a) -> k -> a -> Map k a -> Map k a` | containers-0.8 `Data.Map.Strict` | - | 累加 `qgOutDeg` / `qgInDeg` 與未知 relation 計數 |
| `toAscList :: Map k a -> [(k, a)]` | containers-0.8 `Data.Map.Strict` | - | `qgNotes` 依 relation 名升序取出(規則 4 的決定性) |
| `findWithDefault :: Ord k => a -> k -> Map k a -> a` | containers-0.8 `Data.Map.Strict` | - | `F003` 取鄰居/度數時的預設值語意(本 feature 在測試斷言中同用) |
| `fromList :: Ord a => [a] -> Set a` / `toAscList :: Set a -> [a]` | containers-0.8 `Data.Set` | - | 鄰接表去重 + 依 id 升序(規則 6 的前提) |
| `pack :: String -> Text` | text-2.1.3 `Data.Text` | - | 組錯誤訊息與 relation 名字面量(不依賴 `OverloadedStrings`) |
| `writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport` | src/Knot/Export.hs:33 | F001 | **僅測試路徑**:驗收標準 1 的 round-trip 起點——寫出真實 `codegraph.json` 再讀回 |
| `data ExportOptions = ExportOptions { rootDir :: FilePath, outputPath :: FilePath, commitPolicy :: CommitPolicy }` | src/Knot/Export/Types.hs:21-25 | F001 | 僅測試路徑:round-trip 的匯出參數 |
| `data CommitPolicy = AutoDetect \| NoCommit` | src/Knot/Export/Types.hs:30 | F001 | 僅測試路徑:round-trip 用 `NoCommit`(不需要 `built_at_commit`,也免掉對 git 的依賴) |
| `data CodeGraph = CodeGraph { cgNodes :: [GraphNode], cgEdges :: [GraphEdge], cgStats :: GraphStats, cgWarnings :: [GraphWarning] }` | src/Knot/Graph/Types.hs:40-45 | graph-core/F001 | 僅測試路徑:round-trip 的輸入 |
| `data GraphNode = GraphNode { gnId :: NodeId, gnKind :: NodeKind, gnLabel :: Text, gnFile :: FilePath, gnLine :: Maybe Int }` | src/Knot/Graph/Types.hs:53-59 | graph-core/F001 | 僅測試路徑:手寫節點 |
| `data GraphEdge = GraphEdge { geSource :: NodeId, geTarget :: NodeId, geRelation :: Relation, geLine :: Maybe Int }` | src/Knot/Graph/Types.hs:65-70 | graph-core/F001 | 僅測試路徑:手寫邊(含一條 `RContains`,驗收標準 5) |
| `data Relation = RImports \| RCalls \| RUses \| RImplements \| RContains` | src/Knot/Graph/Types.hs:74-75 | graph-core/F001 | 僅測試路徑;**同時是反向對映的定義域**:`Knot.Export.Encode.relationText`(src/Knot/Export/Encode.hs:131-136)把這五個建構子映成 `imports`/`calls`/`uses`/`implements`/`contains`,本 feature 的 `classifyRelation` 必須認得這五個字串(前四個 → 依賴類、`contains` → 結構類) |
| `newtype NodeId = NodeId Text` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:50-51 | graph-core/F001 | 僅測試路徑:手寫 `GraphNode` / `GraphEdge` 的 id。**注意其 haddock 明載「唯一構造入口是 node-mint…其他模組只得從既有 GraphNode 取 gnId,不得直接用建構子」——這正是查詢面不能沿用它的理由(假設 A1)** |
| `data GraphStats = GraphStats { gsDroppedExternal :: Int, gsTopExternalTargets :: [(ModuleName, Int)], gsFilteredGenerated :: Int, gsDedupedEdges :: Int }` | src/Knot/Graph/Types.hs:77-82 | graph-core/F001 | 僅測試路徑:`CodeGraph` 的必填欄位(round-trip 用全零值) |
| `DEP_RELATIONS` / `STRUCTURAL_RELATIONS` 常數 | dev-flow 0.8.1 `arch-audit/scripts/scan-graph.mjs:59-64` | - | **不呼叫**,列在此處是因為它是「分類語意與下游一致」的對帳基準;已查證我方十種依賴類與六種結構類與它**逐項完全相同**(2026-08-21 複驗,見假設 A6) |

## 新增的介面

### 契約面(Level 2 原文)

**`Knot.Query`**(查詢面對外進入點)

```haskell
-- | 讀 @codegraph.json@ 並組成查詢用圖(Level 2 契約原文簽名)。
--   唯一的 IO;讀不到 / 壞 JSON / 結構不合一律回 'LoadError',不修不猜、不印任何訊息。
loadQueryGraph :: FilePath -> IO (Either LoadError QueryGraph)
```

`Knot.Query` 另**再匯出**(不重新定義):`queryGraphNotes`、`LoadError (..)`、`NodeId (..)`,
以及**抽象**的 `QueryGraph`(只有型別,無欄位)。`F003` 之後會把 `runQuery` / `renderResult`
加進同一份匯出清單。

**`Knot.Query.Load`**(純函數)

```haskell
-- | 查詢規則 2:未知 relation 名 + 邊數,依 relation 名升序(Level 2 契約原文簽名)。
--   library 不印;由 F004 的 CLI 層取來印 stderr(契約 C2)。
queryGraphNotes :: QueryGraph -> [(Text, Int)]
```

**`Knot.Query.Types`**(對外 DTO,契約原文)

```haskell
-- | 從 codegraph.json 載入失敗的三種原因(Level 2 契約原文)。
data LoadError
  = LoadFileMissing Text            -- ^ 檔案不存在 / 讀不到
  | LoadParseError  Text            -- ^ JSON 語法壞掉
  | LoadSchemaError Text            -- ^ 必要欄位缺漏、型別不對、邊引用不存在的節點 id
  deriving (Eq, Show)

-- | 從 codegraph.json 載入的查詢用圖(內容屬 Level 3;欄位見「實作方式 › 型別設計」)。
data QueryGraph = QueryGraph { … }
  deriving (Eq, Show)
```

### 非契約面(供 G-E001 收斂;沿用 project-meta / extraction / graph-core / F001 的既有慣例,一律以 haddock 標註)

| 匯出 | 模組 | 為什麼需要匯出 |
|---|---|---|
| `NodeId (..)` | `Knot.Query.Types` | 契約在 `QueryCommand` / `QueryResult` 用到 `NodeId`,但**沒定義它**;本 feature 補上(假設 A1)。建構子必須匯出:`F004` 要從 CLI 字串建 id |
| `QueryNode (..)` | `Knot.Query.Types` | `F003` 的 `FoundNodes [(NodeId, Text, FilePath)]` 要讀 `qnId` / `qnLabel` / `qnFile` |
| `QueryGraph (..)`(七個欄位選擇器) | `Knot.Query.Types` | `F003` 的四種演算法要讀 `qgNodes` / `qgIndex` / `qgForward` / `qgReverse` / `qgOutDeg` / `qgInDeg`。`Knot.Query`(對 `F004` 的面)只再匯出**抽象型別**,欄位不外露 |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | `Knot.Query.Load` | 1-to-1 測試要直接測解析與驗證的分支,不落地檔案(T3 / T4) |
| `classifyRelation :: Text -> RelationClass` + `data RelationClass = RelDependency \| RelStructural \| RelUnknown` | `Knot.Query.Load` | 1-to-1 測試要逐一釘住十六種名稱的分類(T2) |
| `dependencyRelations :: [Text]` / `structuralRelations :: [Text]` | `Knot.Query.Load` | 查詢規則 1 的兩張表本體;T2 以它們對帳 `ADR-003` 的名單 |

**與 build-log 階段一「發現 2」的關係**:上表六項與 `F001` 的
`encodeCodegraph` / `relationText` / `statsNotes` / `defaultOutputPath` 屬同型需求(為測試與跨模組協作
而擴大的公開面)。依閘門裁決「擴充 G-E001 範圍、本階段不修」,本 feature **照常匯出**,並在此登記
供日後一併收斂。其中 `dependencyRelations` / `structuralRelations` / `parseQueryGraph` 是**目前只有測試在用**
的三項(`classifyRelation` 由 `parseQueryGraph` 內部使用,`QueryGraph (..)` / `QueryNode (..)` / `NodeId (..)`
由 `F003` / `F004` 使用),與 `relationText` 同一類。

## TodoList

- [x] T1: `Knot.Query.Types`——`NodeId`(`Eq`/`Ord`/`Show`)、`QueryNode`、`QueryGraph`(七欄位)、
      `LoadError`(三建構子,契約原文);`knot-hs.cabal` library 加三個 `exposed-modules`
      (**build-depends 零新增**);`version` 不動、executable 段不動;
      `cabal build all --enable-tests` 在 `-Wall` 下零警告  `dep: -`
- [x] T2: `Knot.Query.Load` 的 relation 分類——`RelationClass`、`dependencyRelations`(十種)、
      `structuralRelations`(六種)、`classifyRelation`(其餘一律 `RelUnknown`)  `dep: T1`
- [x] T3: `Knot.Query.Load.parseQueryGraph` 的**成功路徑**——步驟 1–10 的解析、分流與收尾定序:
      鄰接表去重升序、度數不去重、自環保留、`qgNodes` 依 id 升序、`qgNotes` 依名升序;
      以及 `queryGraphNotes`  `dep: T2`
- [x] T4: `Knot.Query.Load.parseQueryGraph` 的**錯誤路徑**——`LoadParseError`(壞 JSON)與
      `LoadSchemaError` 的七種情形(頂層非物件、缺 `nodes`、`nodes` 非陣列、節點缺欄位 / 型別不對、
      節點 id 重複、邊缺欄位 / 型別不對、邊端點不存在),訊息含路徑 + `nodes[i]`/`links[i]` + 問題;
      `links` 缺鍵時當空陣列不報錯  `dep: T3`
- [x] T5: `Knot.Query.loadQueryGraph` 進入點 + round-trip——`try`/`isDoesNotExistError` 兩種
      `LoadFileMissing`、目錄路徑也回 `LoadFileMissing`;手寫 `CodeGraph`(含一條 `RContains` 邊)
      經 `writeCodegraph` 落地後 `loadQueryGraph` 讀回成功且內容對得上(驗收標準 1、5);
      同一檔案載入兩次結果相等  `dep: T4`

## 1-to-1 測試對照表

(全部掛在 `test/Main.hs` 新增的 `exportQueryF002Tests :: TestTree` 群組下,加進 `tests` 清單;
沿用既有 tasty + HUnit 慣例;查詢面型別一律走 `import qualified Knot.Query.Types as QT`
以避開與 `Knot.Graph.Types.NodeId` 的同名衝突)

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_query_types_construct | 逐一建構 `QT.NodeId` / `QueryNode`(三欄位)/ `QueryGraph`(七欄位)/ `LoadError` 三建構子並比對欄位讀取;驗證 `Eq` 可用、三個 `LoadError` 建構子彼此互異;`QT.NodeId` 的 `Ord` 為 `Text` 字典序(`sort [NodeId "b", NodeId "A", NodeId "a"]` 的結果釘住碼位序);**同時 import `Knot.Graph.Types (NodeId (..))` 與 `qualified Knot.Query.Types as QT` 並各自建值**,釘住「兩個 `NodeId` 同名在 qualified import 下可編譯」(假設 A1) |
| T2 | test_relation_classification | `classifyRelation` 對 `ADR-003` 的十種依賴類名稱全部回 `RelDependency`、六種結構類全部回 `RelStructural`;`"foo"` / `""` / `"Imports"`(大小寫不同)/ `"contains_all"` 回 `RelUnknown`(**分類大小寫敏感**,contract 的名稱是固定字面量);`dependencyRelations` 恰為那十個、`structuralRelations` 恰為那六個(逐字對帳 `ADR-003` 與 `scan-graph.mjs:59-64`,防止日後手滑增刪);`map classifyRelation (map relationText [RImports, RCalls, RUses, RImplements, RContains])` 的結果為 `[RelDependency, RelDependency, RelDependency, RelDependency, RelStructural]`——釘住「knot 自家匯出的五種 relation 全部認得」的反向對映 |
| T3 | test_parse_query_graph_ok | 對一份手寫 JSON(`ByteString` 字面量,含:4 個節點且**在檔案中刻意逆序排列**;`imports` 邊、`calls` 邊、重複的 `imports` 邊(同一對節點)、`contains` 邊、`method` 邊、兩條 `"foo"` 邊、一條 `"bar"` 邊、一條自環 `depends_on` 邊)呼叫 `parseQueryGraph`:載入成功;`qgNodes` 依 id 升序(**證明不是檔案原序**)且含全部 4 個節點,連只被 `contains` 邊連到的節點也在(規則 3);`qgForward` / `qgReverse` 的鄰居**去重且升序**;`contains` 與 `method` 邊完全不出現在兩張鄰接表與度數中(驗收標準 5,`Reachable` 的唯一資料來源);兩條 `"foo"` 與一條 `"bar"` 邊同樣不在鄰接表中;`qgOutDeg` / `qgInDeg` 對重複邊**計 2**(與鄰接表的 1 個鄰居對照,釘住「鄰接去重、度數不去重」,假設 A4);自環節點在自己的 `qgForward` 鄰居中且 in/out 度各 +1(查詢規則 5 的前提);`queryGraphNotes` 回 `[("bar",1),("foo",2)]`(**依名升序、結構類不入列**,驗收標準 4);對同一份 bytes 解兩次結果 `==`(規則 4) |
| T4 | test_parse_query_graph_errors | 逐一餵壞檔並斷言建構子與訊息內容:`"{"` → `LoadParseError` 且訊息含檔名;`"[]"` → `LoadSchemaError` 含 `top level`;`{"links":[]}` → `LoadSchemaError` 含 `missing required field "nodes"`(驗收標準 2);`{"nodes":{}}` → 含 `"nodes" is not an array`;節點缺 `label` → 含 `nodes[1]` 與 `"label"`;節點 `label` 為數字 → 含 `nodes[0]` 與 `is not a string`;兩個節點同 id → 含 `duplicate node id`(假設 A3);邊缺 `relation` → 含 `links[0]` 與 `"relation"`;邊的 `source` 指向不存在的 id → 含 `links[0]`、該 id 與 `is not a known node id`(驗收標準 3),`target` 同理;邊的 `source` 是數字(舊格式索引)→ `LoadSchemaError` 含 `is not a string`(`ADR-003`:不接索引);`{"nodes":[]}`(**無 `links` 鍵**)→ **成功**且圖為空(假設 A2);`{"nodes":[],"links":"x"}` → 含 `"links" is not an array`;同一份壞檔解兩次訊息完全相同(fail-fast 的決定性) |
| T5 | test_load_query_graph_io_roundtrip | (a)`loadQueryGraph "<tmp>/knot-hs-load-missing.json"` → `LoadFileMissing` 且訊息含路徑與 `file not found`;(b)`loadQueryGraph` 對**一個目錄**的路徑 → `LoadFileMissing`(不拋例外);(c)驗收標準 1 的 round-trip:手寫 `CodeGraph`(3 個 `GraphNode`;邊為 `RImports`、`RCalls`、**一條 `RContains`**,`GraphStats` 全零)以 `writeCodegraph ExportOptions { rootDir = <tmp>, outputPath = <tmp>/codegraph.json, commitPolicy = NoCommit }` 寫出**真實檔案**,再 `loadQueryGraph` 讀回 → `Right`;`length (qgNodes g) == 3` 且 id/label/source_file 與輸入的 `gnId`/`gnLabel`/`gnFile` 對得上;`qgForward` 只含 `imports` 與 `calls` 兩條、**`contains` 那條不在**(驗收標準 5);`queryGraphNotes g == []`(自家輸出無未知 relation);(d)同一個檔案連續 `loadQueryGraph` 兩次,兩個 `QueryGraph` `==`(規則 4);跑完刪除暫存目錄(沿用 `F001` 的 `withExportDir` 慣例) |

## 待確認假設

- A1 **(最重要,建議閘門明確裁決)**:`design.md`「對外契約 › 查詢面」的 `QueryCommand` /
  `QueryResult` 用到 `NodeId`,但**契約沒有定義它**,而 knot-hs 已有一個 `Knot.Graph.Types.NodeId`
  (`src/Knot/Graph/Types.hs:50`)→ 採取:**查詢面自己定義 `Knot.Query.Types.NodeId`(同名、
  同樣是 `newtype … Text`),不沿用 graph-core 的**。兩條理由都是查證出來的事實:
  (i) graph-core 的 `NodeId` haddock 明載「唯一構造入口是 node-mint(Level 2 契約);其他模組只得從
  既有 `GraphNode` 取 `gnId`,**不得直接用建構子**」,而 graph-load 手上只有 JSON 字串、沒有
  `GraphNode`,沿用等於違反上游自己登記的不變式;(ii) `ADR-003` 明文「這是匯出格式,不是內部模型」,
  查詢面只認 JSON,不該 import 任何上游子系統的型別(build-log 階段一發現 6 的同型訊號)
  → 影響:若裁定改用 graph-core 的 `NodeId`,`Knot.Query.Types` 刪掉該 newtype 並 import
  `Knot.Graph.Types`,`Knot.Query.Load` 多一個上游相依、`depends-on` 的 `graph-core/F001` 從
  「僅測試路徑」升為產品面相依,測試也不必 qualified import;代價是查詢面與內部 IR 重新耦合,
  且要同步放寬 graph-core 那段 haddock 的不變式
- A2:`links` 頂層鍵缺席時的行為契約未定(驗收標準只點名「缺 `nodes`」)→ 採取:**當作空陣列,
  載入成功**(下游 `scan-graph.mjs:89` 也是 `graph.links ?? graph.edges ?? []`;而「有節點沒有邊」
  是語意上完全合法的圖)。**不接受 `edges` 別名**——`ADR-003` 的欄位名是 `links`,接別名等於私自
  擴充契約 → 影響:若裁定 `links` 也必填,`parseQueryGraph` 步驟 6 改成與步驟 3 同形的 `LoadSchemaError`,
  T4 的一條斷言反向
- A3:節點 id 重複時的行為契約未定 → 採取:**回 `LoadSchemaError`**(訊息含 `duplicate node id` 與
  該 id)。理由:`qgIndex` 是 `Map`,重複必須有明確的取捨,而「後者覆蓋前者」會讓同一份檔案的
  `qgNodes` 與邊的解析結果取決於檔案順序,與「不修復壞 JSON」的底線相衝 → 影響:若裁定放寬,
  改成「後出現者覆蓋」或「先出現者保留」並在 `qgNotes` 之外另尋通道回報(目前沒有這種通道),
  T4 少一條斷言
- A4:`RankConnectivity` 的「入度 / 出度」要算**邊數**還是**相異鄰居數**,契約未定(屬 `F003` 的規則,
  但 `QueryGraph` 現在就得決定存哪個)→ 採取:**鄰接表去重、度數算邊數**,兩者分開存。理由:BFS 只
  需要相異鄰居;而下游 `scan-graph.mjs:311-318` 的 hub 計算是對每條非結構邊的兩端各 +1(算邊數),
  查詢規則 1 明講「與 dev-flow `scan-graph.mjs` 語意一致」→ 影響:若裁定度數也要去重,刪掉
  `qgOutDeg` / `qgInDeg` 兩個欄位,`F003` 改用 `length (findWithDefault [] n qgForward)`,T3 的度數斷言改 1
- A5:`directed: false` 的檔案要不要拒絕或告警,契約未定 → 採取:**忽略該欄位,一律當有向圖**
  (`ADR-003`「缺省時下游當有向」;`LoadError` 沒有「警告」語意,`queryGraphNotes` 的
  `[(Text, Int)]` 是 relation 專用的形狀,塞警告會扭曲契約)→ 影響:若裁定要提醒使用者,最小改法是
  由 `F004` 在 CLI 層自己讀一次頂層 `directed` 並印 stderr(不動 library 契約);要 library 回報則需
  Level 2 新增通道(如 `LoadError` 之外的 notes 欄位),屬契約變更
- A6 **(已裁決,實作前更正)**:設計期原稿依當時的 `design.md` / `ADR-003` 寫「結構類三種
  (`contains` `method` `defines`)」,但下游 `scan-graph.mjs:64` 的 `STRUCTURAL_RELATIONS` 實際有**六種**
  (多了 `declares`、`rationale_for`、`part_of`)→ **編排者已裁決補齊到六種**,`design.md` 查詢規則 1 與
  `ADR-003` 均已更新;本文檔於實作開工前同步更正(「實作方式 › 步驟 9」、「對應的 Level 2 契約」、
  「功能概述」、TodoList T2、1-to-1 對照表 T2、`scan-graph.mjs` 對帳列),`structuralRelations` 落地六種
  → 影響:`declares` / `rationale_for` / `part_of` 由 `RelUnknown` 改判 `RelStructural`,**依賴圖完全不變**
  (兩種歸類都是「排除」),差別僅在這三種不再出現在 `queryGraphNotes`。T2 的 `RelUnknown` 反例改用
  `"contains_all"`(`declares` 已成已知名稱)。2026-08-21 由本 feature 實作者複驗 `scan-graph.mjs:59-64`
  原文,十種依賴類 + 六種結構類與我方名單逐字相同

## 實作備註

**公開介面零偏離**:`loadQueryGraph` / `queryGraphNotes` 的簽名與 `LoadError` 三建構子與 Level 2 契約
原文一字不差;`QueryGraph` 七欄位如「型別設計」。非契約面公開匯出的清單已預先登記在
「新增的介面 › 非契約面」,供 build-log 階段一發現 2 所指的 `G-E001` 一併收斂。

實作期間的內部決定(皆屬實作自主權,不動契約):

- **A6 的文檔更正在開工前完成**:「功能概述」、「對應的 Level 2 契約」、「實作方式 › 步驟 9」、
  `scan-graph.mjs` 對帳列、TodoList T2 與 1-to-1 對照表 T2 的「結構類三種」全部改為六種
  (`contains` `method` `defines` `declares` `rationale_for` `part_of`),與 `design.md` 查詢規則 1、
  `ADR-003` 一致。落地的 `structuralRelations` 即這六個
- **鄰接表 / 度數的存在性語意**:`qgForward` / `qgReverse` / `qgOutDeg` / `qgInDeg` 只收錄
  **實際有依賴邊**的節點,沒有邊的節點在 Map 中**缺鍵**(不是空清單 / 0)。`F003` 一律以
  `Map.findWithDefault [] n` 與 `Map.findWithDefault 0 n` 取值——與「使用到的既有串接介面」表登記的
  `findWithDefault` 語意一致。`qgNodes` / `qgIndex` 才是「全部節點」的權威來源(查詢規則 3)
- **鄰接表以 `Map NodeId (Set NodeId)` 累加後 `Set.toAscList`**(而非設計文字提到的
  `fromListWith` 再過 `Set`):同樣得到「去重 + 依 id 升序」,但只走一次摺疊。屬內部演算法選擇
- **兩處設計未指定訊息的錯誤**自訂為 `"<path>: nodes[i]: element is not a JSON object"` /
  `"<path>: links[i]: element is not a JSON object"`(陣列元素不是物件),形狀與其他 `LoadSchemaError`
  一致
- **`-Wall` 現況**:本 feature 新增的 `src/Knot/Query*.hs` 三個模組與 `test/Main.hs` 的
  `exportQueryF002Tests` 段落**零警告**。`test/Main.hs` 另有 8 筆 `-Wincomplete-record-selectors`
  警告(第 1200/1202/1203/1204/1327/1329 行,extraction 的 `Fact` 記錄選擇器),**與 HEAD 逐字相同、
  屬既有狀況**,本 feature 未觸碰亦未新增
