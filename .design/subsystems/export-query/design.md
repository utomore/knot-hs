---
id: export-query
type: subsystem
title: export-query
description: 匯出與查詢子系統:codegraph.json 投影與四項導航查詢 CLI
status: active
created: 2026-08-20
updated: 2026-08-21
parent: system
related-adr: [ADR-003]
---

# export-query 子系統架構

## 定位與範圍

管線末站(見 system.md「子系統劃分 › export-query」),兩個面向:

- **匯出面**:吃 graph-core 的 `CodeGraph`,投影成 `codegraph.json`(規格遵守 ADR-003)寫到目標專案根目錄,並回報匯出摘要
- **查詢面**(S4):`knot query` 讀既有 `codegraph.json`,回答 dev-flow 的四項導航能力——關鍵字查節點、(反向)可達、兩點最短路徑、連通度排名

**明確不做**:不建圖、不改圖(查詢只讀不寫);不做視覺化;不重跑抽取(查詢面只認 JSON 檔,不碰 `.hie` 或原始碼)。

## 對外契約(Public Interface & DTOs)

### 匯出面

```haskell
writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport
```

```haskell
data ExportOptions = ExportOptions
  { rootDir      :: FilePath        -- 目標專案根目錄;AutoDetect 在此跑 git
  , outputPath   :: FilePath        -- 預設 <rootDir>/codegraph.json(CLI -o 覆寫)
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

### 投影規則(契約的一部分,對齊 ADR-003)

1. **relation 對映**:`RImports → "imports"`、`RCalls → "calls"`、`RUses → "uses"`、`RImplements → "implements"`、`RContains → "contains"`
2. **節點欄位**:`id`(NodeId 原文)、`label`、`source_file`(`gnFile`,已是 repo 相對正斜線)、`source_location`(`gnLine` 有值時輸出 `L<行>`)
3. **邊欄位**:`source` / `target` / `relation` / `confidence: "EXTRACTED"`(GHC 事實,全部同值);`source_location`(`geLine` 有值時輸出 `L<行>`)——下游 `scan-graph.mjs` 以「邊優先、來源節點 fallback」取循環依賴與跨子系統引用的證據行,S1 的 module 節點 `gnLine` 恆為 `Nothing`,不由邊供給就取不到
4. **頂層欄位**:`directed: true`;`built_at_commit` 依 `CommitPolicy`
5. **決定性**:同一 `CodeGraph` 序列化結果 byte 級相同(欄位順序、清單順序固定)

### 查詢面

```haskell
loadQueryGraph  :: FilePath -> IO (Either LoadError QueryGraph)
queryGraphNotes :: QueryGraph -> [(Text, Int)]                 -- 未知 relation 名 + 邊數
runQuery        :: QueryGraph -> QueryCommand -> QueryResult   -- 純函數
renderResult    :: QueryResult -> Text                         -- stdout 文字
```

```haskell
data QueryCommand
  = FindNodes Text                  -- 關鍵字(id 與 label 的子字串比對,不分大小寫)
  | Reachable NodeId Direction      -- 可達集合
  | ShortestPath NodeId NodeId      -- 兩點最短路徑
  | RankConnectivity Int            -- 連通度排名,參數為 top N

data Direction = Forward | Reverse  -- Forward:它依賴誰;Reverse:誰依賴它

data QueryGraph                     -- 從 codegraph.json 載入的查詢用圖(內容屬 Level 3)
                                    -- 未知 relation 統計以 queryGraphNotes 取出,library 不印

data QueryResult
  = FoundNodes   [(NodeId, Text, FilePath)]        -- id、label、source_file
  | ReachableSet [(NodeId, Int)]                   -- 節點與其距離(hop 數)
  | PathResult   (Maybe [NodeId])                  -- Nothing = 不連通
  | Ranking      [(NodeId, Int, Int)]              -- 節點、入度、出度

data LoadError
  = LoadFileMissing Text            -- 檔案不存在 / 讀不到
  | LoadParseError  Text            -- JSON 語法壞掉
  | LoadSchemaError Text            -- 必要欄位缺漏、邊引用不存在的節點 id
```

### 查詢規則(契約的一部分)

1. **依賴類邊才進圖**:`Reachable` / `ShortestPath` / `RankConnectivity` 只走依賴類 relation(`imports`、`imports_from`、`calls`、`uses`、`references`、`extends`、`implements`、`inherits`、`instantiates`、`depends_on`);結構類(`contains`、`method`、`defines`)不算——與 dev-flow `scan-graph.mjs` 語意一致
2. **未知 relation 列印排除**:載入時認不得的 relation 彙整列印(relation 名 + 邊數),不靜默吞掉(ADR-003 的下游行為)
3. **`FindNodes`** 比對所有節點(含結構類邊連接的節點);其餘三指令操作依賴圖
4. **決定性**:結果排序穩定(距離/度數同值時按 id 字典序)
5. **`Reachable` 不含起點自身**:只回距離 ≥ 1 的節點;起點若處在環上,會以其真實距離出現
6. **`ShortestPath` 多解取字典序最小路徑**:BFS 展開時鄰居依 id 排序、前驅取最早抵達者,確保同輸入必同輸出

### CLI 子命令對映(承接 system.md 頂層契約)

```text
knot query find <keyword>            → FindNodes
knot query reachable <id> [--reverse] → Reachable
knot query path <from> <to>          → ShortestPath
knot query rank [--top N]            → RankConnectivity(N 預設 10)
```

參數解析屬 CLI 組裝層;本子系統收 `QueryCommand`。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **export-writer** | `CodeGraph` → JSON 投影、commit 偵測、寫檔、`ExportReport` 組裝 |
| **graph-load** | 讀 `codegraph.json` → 驗證 → `QueryGraph`;未知 relation 的彙整排除 |
| **query-engine** | 四種查詢演算法(純函數,BFS/度數統計) |
| **query-render** | `QueryResult` → 人類可讀文字 |
| **cli-assembly** | (executable,非 library)`knot` 的參數解析與管線組裝:`extract` / `query` 兩個子命令、旗標對映成各子系統的 Options DTO、報告與警告列印、exit code |

## 資料流管線(Data Flow Pipeline)

```text
匯出:CodeGraph(+ ExportOptions)
  → export-writer: 投影(規則 1–5)→ commit 偵測 → 寫 codegraph.json → ExportReport → CLI 層列印

查詢:codegraph.json 路徑 + QueryCommand
  → graph-load:   讀檔 → 驗證 → 依賴類/結構類分流 → QueryGraph(壞檔 → LoadError,exit 1)
  → query-engine: QueryCommand → QueryResult(純函數)
  → query-render: 文字 → stdout
```

查詢面的錯誤策略:`LoadError` 屬「使用者給錯輸入」,直接失敗(exit 1)而非 best-effort——與匯出管線的 best-effort 區隔,因為沒有「部分查詢結果」可言;查無節點(`FindNodes` 空集合、`PathResult Nothing`)是正常結果,exit 0。

## 模組間公開介面(Module Interfaces)

對外契約的 `loadQueryGraph` / `runQuery` / `renderResult` 即是三個查詢模組的邊界介面;匯出面單一模組無內部介面。無額外條目。

## 使用的技術

沿用主架構技術棧。子系統特有選型:

- **aeson**(實測 2.3.1.0)做 JSON 讀寫——2026-08-21 於 GHC 9.14.1 / base 4.22 實測編譯成功;instance 標頭等字串的 escaping 交給標準實作,匯出與查詢兩面共用。序列化走 `Data.Aeson.Encoding` 以顯式控制欄位順序(投影規則 5 的 byte 級決定性)
- **optparse-applicative**(實測 0.19.0.0)做 CLI 解析——同日同環境實測 `hsubparser` 可用,承載 `knot extract` / `knot query` 兩個子命令

commit 偵測呼叫 `git rev-parse HEAD`(在 `rootDir` 執行,對目標專案唯讀,失敗即省略)。

## 架構圖

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

## 開發階段

對應主架構 S1(json-export)與 S4(graph-load、query-commands)。無額外內部里程碑。

## 功能規劃

### 階段一:S1 骨架

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | json-export | codegraph.json 投影、寫檔、commit 欄位、匯出報告 | export-writer | - | F001 |

### 階段二:S4 查詢 CLI

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 2 | graph-load | 讀回 codegraph.json、驗證、未知 relation 列印排除 | graph-load | #1 | - |
| 3 | query-commands | 四查詢演算法與文字輸出 | query-engine、query-render | #2 | - |
| 4 | cli-wiring | knot extract / query 兩子命令的參數解析與管線組裝 | cli-assembly | #1, #3 | - |

(共 4 個 features、2 個階段;全部完成即子系統可交付)

## Feature 契約卡

### json-export

- **階段**:階段一
- **負責模組**:export-writer
- **實作的 Level 2 介面**:`writeCodegraph` 進入點;DTO `ExportOptions`、`CommitPolicy`、`ExportReport`;投影規則 1–5 全部
- **資料流管線段落**:從 `CodeGraph` 進,經投影與 commit 偵測,出寫到磁碟的 `codegraph.json` 與 `ExportReport`
- **驗收標準**:輸出的 JSON 含 `directed: true`、每個節點有 `id`/`label`/`source_file`、每條邊有 `source`/`target`/`relation`/`confidence: "EXTRACTED"`;`gnLine` 有值的節點與 `geLine` 有值的邊都輸出 `source_location: "L<行>"`;在 git repo 內執行時頂層有 `built_at_commit` 且等於 `git rev-parse HEAD`,非 repo 時該欄位不存在且無警告;同一 `CodeGraph` 兩次序列化 byte 級相同;`xrNotes` 含 `GraphStats` 的丟棄/過濾/去重摘要;測試直接呼叫 `writeCodegraph` 寫出真實檔案,該檔以 dev-flow 的 `scan-graph.mjs` 驗證可解析(CLI 入口在 F004,故兩個驗收標的的實跑順延至 F004)
- **明確不做**:不讀 JSON(graph-load 的事);不印 stdout/stderr(報告由 CLI 層印);不改 `CodeGraph` 內容;不輸出 IR 的額外欄位(型別等擴充留給未來)

### graph-load

- **階段**:階段二
- **負責模組**:graph-load
- **實作的 Level 2 介面**:`loadQueryGraph`;DTO `QueryGraph`、`LoadError`;查詢規則 1(依賴類分流)、2(未知 relation 列印排除)
- **資料流管線段落**:從 `codegraph.json` 路徑進,經讀檔、驗證、relation 分類,出 `QueryGraph` 或 `LoadError`
- **驗收標準**:讀自家 json-export 的輸出成功;缺 `nodes` 或邊引用不存在的節點 id 時回 `LoadError` 且訊息指出問題;含未知 relation(如 `"foo"`)的檔案能載入、該類邊被排除且列印「relation 名 + 邊數」;`contains` 邊載入後不出現在依賴圖(以 reachable 驗證)
- **明確不做**:不實作查詢演算法(query-commands 的事);不寫任何檔案;不嘗試修復壞 JSON(直接 `LoadError`)

### query-commands

- **階段**:階段二
- **負責模組**:query-engine、query-render
- **實作的 Level 2 介面**:`runQuery`、`renderResult`;DTO `QueryCommand`、`Direction`、`QueryResult`;查詢規則 3、4;CLI 子命令對映表的四條語意
- **資料流管線段落**:從 `QueryGraph` + `QueryCommand` 進,經演算法,出 `QueryResult` 渲染為 stdout 文字
- **驗收標準**:以 fixture 圖驗證——`find` 不分大小寫比對 id 與 label;`reachable` 的 Forward/Reverse 方向正確且回報 hop 距離;`path` 在連通時回最短路徑、不連通時明確輸出「不連通」且 exit 0;`rank` 依 入度+出度 排序、同分按 id 字典序、`--top N` 生效;所有查詢只走依賴類邊(`contains` 不影響結果);同輸入兩次結果相同
- **明確不做**:不解析 CLI 參數(組裝層的事);不讀寫檔案(圖由 graph-load 給定);不做全對最短路徑或中心性等進階演算法(超出四能力範圍)

### cli-wiring

CLI 組裝層是跨子系統的黏合層,不屬任何單一子系統的 library 契約;落在 export-query 是因為 `knot` 的兩個子命令(`extract` 的終點、`query` 的全部)主體都在此,且管線末站才看得到完整的輸出與 exit code 語意。

- **階段**:階段二
- **負責模組**:cli-assembly(在 executable `knot`,非 library)
- **實作的 Level 2 介面**:不新增 library 契約面。消費既有四個子系統的對外契約——`loadProjectMeta`(`MetaOptions`)、`extract`(`ExtractOptions`)、`buildGraph`(`BuildOptions`)、`writeCodegraph`(`ExportOptions`)、`loadQueryGraph` / `queryGraphNotes` / `runQuery` / `renderResult`;實作 system.md「CLI 介面(頂層契約)」全部旗標
- **資料流管線段落**:從 `argv` 進,解析成各子系統的 Options DTO,依 `project-meta → extraction → graph-core → export-query` 呼叫,出檔案 / stdout / stderr 與 exit code
- **驗收標準**:`knot extract [PATH]` 六個旗標(`--output`、`--backend auto|imports|hiedb`、`--module-only`、`--include-tests`、`--hiedir DIR`、`--strict`)全部解析正確且對映到正確的 Options 欄位;`knot query find|reachable|path|rank` 四子命令(含 `--reverse`、`--top N`,N 預設 10)對映到正確的 `QueryCommand`;`--summary meta|facts|graph` 保留三個既有唯讀驗收輸出,不給時 `extract` 的預設行為是寫 `codegraph.json`;`--help` 對頂層與每個子命令都可用;無效旗標與缺參數 exit 非 0 且訊息指出問題;`LoadError` exit 1、查無結果 exit 0;有跳檔時預設 exit 0 而 `--strict` 下 exit 1;`ExportReport` 的 `xrNotes` 與 `queryGraphNotes` 由本層印出(library 仍全程不印);以 MagicFarmer 與 particle-magic 唯讀實跑,產出的 `codegraph.json` 經 dev-flow `scan-graph.mjs` 解析成功
- **明確不做**:不含任何投影、載入或查詢邏輯(全部委由四個子系統的契約函式);不新增 library 公開面;不改動任何子系統的 Options DTO 形狀(需要改就停下回報)
