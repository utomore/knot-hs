---
id: export-query
type: subsystem
title: export-query
description: 匯出與查詢子系統:codegraph.json 投影與四項導航查詢 CLI
status: active
created: 2026-08-20
updated: 2026-08-20
parent: system
related-adr: [ADR-003]
---

## export-query 子系統架構

### 定位與範圍

管線末站(見 system.md「子系統劃分 › export-query」),兩個面向:

- **匯出面**:吃 graph-core 的 `CodeGraph`,投影成 `codegraph.json`(規格遵守 ADR-003)寫到目標專案根目錄,並回報匯出摘要
- **查詢面**(S4):`knot query` 讀既有 `codegraph.json`,回答 dev-flow 的四項導航能力——關鍵字查節點、(反向)可達、兩點最短路徑、連通度排名

**明確不做**:不建圖、不改圖(查詢只讀不寫);不做視覺化;不重跑抽取(查詢面只認 JSON 檔,不碰 `.hie` 或原始碼)。

### 對外契約(Public Interface & DTOs)

#### 匯出面

```haskell
writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport
```

```haskell
data ExportOptions = ExportOptions
  { outputPath   :: FilePath        -- 預設 <root>/codegraph.json(CLI -o 覆寫)
  , commitPolicy :: CommitPolicy
  }

data CommitPolicy
  = AutoDetect      -- git rev-parse HEAD(對目標專案唯讀);失敗則省略欄位不警告
  | NoCommit        -- 不輸出 built_at_commit

data ExportReport = ExportReport
  { xrPath      :: FilePath
  , xrNodeCount :: Int
  , xrEdgeCount :: Int
  , xrNotes     :: [Text]           -- GraphStats 摘要行(丟棄外部 N 條、過濾產生碼 M 筆…),CLI 層列印
  }
```

#### 投影規則(契約的一部分,對齊 ADR-003)

1. **relation 對映**:`RImports → "imports"`、`RCalls → "calls"`、`RUses → "uses"`、`RImplements → "implements"`、`RContains → "contains"`
2. **節點欄位**:`id`(NodeId 原文)、`label`、`source_file`(`gnFile`,已是 repo 相對正斜線)、`source_location`(`gnLine` 有值時輸出 `L<行>`)
3. **邊欄位**:`source` / `target` / `relation` / `confidence: "EXTRACTED"`(GHC 事實,全部同值)
4. **頂層欄位**:`directed: true`;`built_at_commit` 依 `CommitPolicy`
5. **決定性**:同一 `CodeGraph` 序列化結果 byte 級相同(欄位順序、清單順序固定)

#### 查詢面

```haskell
loadQueryGraph :: FilePath -> IO (Either LoadError QueryGraph)
runQuery       :: QueryGraph -> QueryCommand -> QueryResult    -- 純函數
renderResult   :: QueryResult -> Text                          -- stdout 文字
```

```haskell
data QueryCommand
  = FindNodes Text                  -- 關鍵字(id 與 label 的子字串比對,不分大小寫)
  | Reachable NodeId Direction      -- 可達集合
  | ShortestPath NodeId NodeId      -- 兩點最短路徑
  | RankConnectivity Int            -- 連通度排名,參數為 top N

data Direction = Forward | Reverse  -- Forward:它依賴誰;Reverse:誰依賴它

data QueryGraph                     -- 從 codegraph.json 載入的查詢用圖(內容屬 Level 3)

data QueryResult
  = FoundNodes   [(NodeId, Text, FilePath)]        -- id、label、source_file
  | ReachableSet [(NodeId, Int)]                   -- 節點與其距離(hop 數)
  | PathResult   (Maybe [NodeId])                  -- Nothing = 不連通
  | Ranking      [(NodeId, Int, Int)]              -- 節點、入度、出度

data LoadError                      -- 檔案不存在 / JSON 壞掉 / 必要欄位缺漏(帶說明文字)
```

#### 查詢規則(契約的一部分)

1. **依賴類邊才進圖**:`Reachable` / `ShortestPath` / `RankConnectivity` 只走依賴類 relation(`imports`、`imports_from`、`calls`、`uses`、`references`、`extends`、`implements`、`inherits`、`instantiates`、`depends_on`);結構類(`contains`、`method`、`defines`)不算——與 dev-flow `scan-graph.mjs` 語意一致
2. **未知 relation 列印排除**:載入時認不得的 relation 彙整列印(relation 名 + 邊數),不靜默吞掉(ADR-003 的下游行為)
3. **`FindNodes`** 比對所有節點(含結構類邊連接的節點);其餘三指令操作依賴圖
4. **決定性**:結果排序穩定(距離/度數同值時按 id 字典序)

#### CLI 子命令對映(承接 system.md 頂層契約)

```text
knot query find <keyword>            → FindNodes
knot query reachable <id> [--reverse] → Reachable
knot query path <from> <to>          → ShortestPath
knot query rank [--top N]            → RankConnectivity(N 預設 10)
```

參數解析屬 CLI 組裝層;本子系統收 `QueryCommand`。

### 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **export-writer** | `CodeGraph` → JSON 投影、commit 偵測、寫檔、`ExportReport` 組裝 |
| **graph-load** | 讀 `codegraph.json` → 驗證 → `QueryGraph`;未知 relation 的彙整排除 |
| **query-engine** | 四種查詢演算法(純函數,BFS/度數統計) |
| **query-render** | `QueryResult` → 人類可讀文字 |

### 資料流管線(Data Flow Pipeline)

```text
匯出:CodeGraph(+ ExportOptions)
  → export-writer: 投影(規則 1–5)→ commit 偵測 → 寫 codegraph.json → ExportReport → CLI 層列印

查詢:codegraph.json 路徑 + QueryCommand
  → graph-load:   讀檔 → 驗證 → 依賴類/結構類分流 → QueryGraph(壞檔 → LoadError,exit 1)
  → query-engine: QueryCommand → QueryResult(純函數)
  → query-render: 文字 → stdout
```

查詢面的錯誤策略:`LoadError` 屬「使用者給錯輸入」,直接失敗(exit 1)而非 best-effort——與匯出管線的 best-effort 區隔,因為沒有「部分查詢結果」可言;查無節點(`FindNodes` 空集合、`PathResult Nothing`)是正常結果,exit 0。

### 模組間公開介面(Module Interfaces)

對外契約的 `loadQueryGraph` / `runQuery` / `renderResult` 即是三個查詢模組的邊界介面;匯出面單一模組無內部介面。無額外條目。

### 使用的技術

沿用主架構技術棧。子系統特有選型:**aeson** 做 JSON 讀寫——2026-08-20 實測在 GHC 9.14.1 編譯成功;instance 標頭等字串的 escaping 交給標準實作,匯出與查詢兩面共用。commit 偵測呼叫 `git rev-parse HEAD`(對目標專案唯讀,失敗即省略)。

### 架構圖

```text
            CodeGraph                    codegraph.json 路徑 + QueryCommand
                │                                   │
                ▼                                   ▼
 ┌─ export-query ────────────────────────────────────────────────┐
 │  export-writer                     graph-load                 │
 │   │ 投影(ADR-003)                  │ 驗證/未知 relation 排除 │
 │   │ git rev-parse(唯讀)            ▼                         │
 │   │                                query-engine(純函數)     │
 │   │                                 │ QueryResult             │
 │   │                                 ▼                         │
 │   │                                query-render               │
 └───┼─────────────────────────────────┼─────────────────────────┘
     ▼                                 ▼
 codegraph.json + ExportReport     stdout 查詢結果
 (repo 根目錄)
```

### 開發階段

對應主架構 S1(json-export)與 S4(graph-load、query-commands)。無額外內部里程碑。

### 功能規劃

#### 階段一:S1 骨架

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | json-export | codegraph.json 投影、寫檔、commit 欄位、匯出報告 | export-writer | - | - |

#### 階段二:S4 查詢 CLI

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 2 | graph-load | 讀回 codegraph.json、驗證、未知 relation 列印排除 | graph-load | #1 | - |
| 3 | query-commands | 四查詢演算法與文字輸出 | query-engine、query-render | #2 | - |

(共 3 個 features、2 個階段;全部完成即子系統可交付)

### Feature 契約卡

#### json-export

- **階段**:階段一
- **負責模組**:export-writer
- **實作的 Level 2 介面**:`writeCodegraph` 進入點;DTO `ExportOptions`、`CommitPolicy`、`ExportReport`;投影規則 1–5 全部
- **資料流管線段落**:從 `CodeGraph` 進,經投影與 commit 偵測,出寫到磁碟的 `codegraph.json` 與 `ExportReport`
- **驗收標準**:輸出的 JSON 含 `directed: true`、每個節點有 `id`/`label`/`source_file`、每條邊有 `source`/`target`/`relation`/`confidence: "EXTRACTED"`;`gnLine` 有值的節點輸出 `source_location: "L<行>"`;在 git repo 內執行時頂層有 `built_at_commit` 且等於 `git rev-parse HEAD`,非 repo 時該欄位不存在且無警告;同一 `CodeGraph` 兩次序列化 byte 級相同;`xrNotes` 含 `GraphStats` 的丟棄/過濾/去重摘要;實際以 dev-flow 的 `scan-graph.mjs` 吃輸出檔驗證可解析
- **明確不做**:不讀 JSON(graph-load 的事);不印 stdout/stderr(報告由 CLI 層印);不改 `CodeGraph` 內容;不輸出 IR 的額外欄位(型別等擴充留給未來)

#### graph-load

- **階段**:階段二
- **負責模組**:graph-load
- **實作的 Level 2 介面**:`loadQueryGraph`;DTO `QueryGraph`、`LoadError`;查詢規則 1(依賴類分流)、2(未知 relation 列印排除)
- **資料流管線段落**:從 `codegraph.json` 路徑進,經讀檔、驗證、relation 分類,出 `QueryGraph` 或 `LoadError`
- **驗收標準**:讀自家 json-export 的輸出成功;缺 `nodes` 或邊引用不存在的節點 id 時回 `LoadError` 且訊息指出問題;含未知 relation(如 `"foo"`)的檔案能載入、該類邊被排除且列印「relation 名 + 邊數」;`contains` 邊載入後不出現在依賴圖(以 reachable 驗證)
- **明確不做**:不實作查詢演算法(query-commands 的事);不寫任何檔案;不嘗試修復壞 JSON(直接 `LoadError`)

#### query-commands

- **階段**:階段二
- **負責模組**:query-engine、query-render
- **實作的 Level 2 介面**:`runQuery`、`renderResult`;DTO `QueryCommand`、`Direction`、`QueryResult`;查詢規則 3、4;CLI 子命令對映表的四條語意
- **資料流管線段落**:從 `QueryGraph` + `QueryCommand` 進,經演算法,出 `QueryResult` 渲染為 stdout 文字
- **驗收標準**:以 fixture 圖驗證——`find` 不分大小寫比對 id 與 label;`reachable` 的 Forward/Reverse 方向正確且回報 hop 距離;`path` 在連通時回最短路徑、不連通時明確輸出「不連通」且 exit 0;`rank` 依 入度+出度 排序、同分按 id 字典序、`--top N` 生效;所有查詢只走依賴類邊(`contains` 不影響結果);同輸入兩次結果相同
- **明確不做**:不解析 CLI 參數(組裝層的事);不讀寫檔案(圖由 graph-load 給定);不做全對最短路徑或中心性等進階演算法(超出四能力範圍)
