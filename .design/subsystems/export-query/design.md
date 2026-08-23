---
id: export-query
type: subsystem
title: export-query
description: 匯出與查詢子系統:codegraph.json 投影與四項導航查詢 CLI
status: active
created: 2026-08-20
updated: 2026-08-23
parent: system
related-adr: [ADR-003, ADR-006]
code-paths: [src/Knot/Export, src/Knot/Export.hs, src/Knot/Query, src/Knot/Query.hs, app]
---

# export-query 子系統架構

## 定位與範圍

管線末站(見 system.md「子系統劃分 › export-query」),兩個面向:

- **匯出面**:吃 graph-core 的 `CodeGraph`,投影成 `codegraph.json`(規格遵守 ADR-003)寫到目標專案根目錄,並回報匯出摘要
- **查詢面**(S4):`knot query` 讀既有 `codegraph.json`,回答 dev-flow 的四項導航能力——關鍵字查節點、(反向)可達、兩點最短路徑、連通度排名

**明確不做**:不建圖、不改圖(查詢只讀不寫);不做視覺化;不重跑抽取(查詢面只認 JSON 檔,不碰 `.hie` 或原始碼)。

**S5(ADR-006)對本子系統的影響全部落在 cli-assembly**:`knot extract` 砍掉五個旗標(`--backend`、`--module-only`、`--hiedir`、`--hiedb`、`--db`)、新增 extraction 整體失敗 → exit 1 的通道、`--summary` 不再印能力等級與 `.hie` 資訊。匯出面與查詢面的 library 契約**零變動**。

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
2. **節點欄位**:`id`(NodeId 原文)、`label`、`source_file`(`gnFile`,已是 repo 相對正斜線)、`component`(`gnComponent` 有值時輸出,G-E007 / ADR-008)、`source_location`(`gnLine` 有值時輸出 `L<行>`);欄位序即此序
3. **邊欄位**:`source` / `target` / `relation` / `confidence: "EXTRACTED"`(GHC 事實,全部同值);`source_location`(`geLine` 有值時輸出 `L<行>`)——下游 `scan-graph.mjs` 以「邊優先、來源節點 fallback」取循環依賴與跨子系統引用的證據行,S1 的 module 節點 `gnLine` 恆為 `Nothing`,不由邊供給就取不到
4. **頂層欄位**:`directed: true`;`built_at_commit` 依 `CommitPolicy`
5. **決定性**:同一 `CodeGraph` 序列化結果 byte 級相同(欄位順序、清單順序固定)

### 查詢面

```haskell
loadQueryGraph    :: FilePath -> IO (Either LoadError QueryGraph)
queryGraphNotes   :: QueryGraph -> [(Text, Int)]                 -- 未知 relation 名 + 邊數
queryGraphHasNode :: QueryGraph -> NodeId -> Bool                -- 節點存在性
runQuery          :: QueryGraph -> QueryCommand -> QueryResult   -- 純函數
renderResult      :: QueryResult -> Text                         -- stdout 文字
restrictLevel     :: Level -> QueryGraph -> QueryGraph         -- E001:收斂為指定層的誘導子圖;LevelAll 為恆等
restrictScope     :: Scope -> QueryGraph -> QueryGraph         -- G-E007:收斂為指定範圍的誘導子圖;ScopeAll 為恆等
queryGraphHasTests :: QueryGraph -> Bool                       -- G-E007:圖上是否有任何測試節點(tests-of 空結果的提示依據)
```

`queryGraphHasNode` 存在的理由:`runQuery` 對「id 不存在」與「存在但無鄰居」都回空結果,呼叫端無從區分,而 CLI 需要對前者給明確訊息。沒有它,組裝層只能繞過 `QueryGraph` 的抽象直接讀內部欄位——那會讓「內容屬 Level 3」的承諾失效。

```haskell
data QueryCommand
  = FindNodes Text                  -- 關鍵字(id 與 label 的子字串比對,不分大小寫)
  | Reachable NodeId Direction (Maybe Int)   -- 可達集合;第三欄 = 深度上限(E001:CLI --depth N,Nothing = 不限)
  | ShortestPath NodeId NodeId      -- 兩點最短路徑
  | RankConnectivity Int            -- 連通度排名,參數為 top N
  | TestsOf NodeId                  -- G-E007:哪些測試節點(直接或間接)依賴它;呼叫端須傳 ScopeAll 的圖

data Direction = Forward | Reverse  -- Forward:它依賴誰;Reverse:誰依賴它

data Level = LevelAll | LevelModule | LevelDecl   -- E001:查詢的層。decl 層節點 = 任一 contains 邊的目標;其餘為 module 層

data Scope = ScopeProduct | ScopeTests | ScopeAll -- G-E007:查詢的範圍。測試節點 = component 的 compName 以 test: / bench: 開頭;
                                                  -- 無 component 欄位一律產品

newtype NodeId = NodeId Text        -- 查詢面自有,與 graph-core 的同名型別無關:
                                    -- graph-load 手上只有 JSON 字串,而 graph-core 的
                                    -- NodeId 唯一構造入口是 node-mint(ADR-003:匯出
                                    -- 格式 ≠ 內部模型)。查詢面全程不依賴 graph-core

data QueryGraph                     -- 從 codegraph.json 載入的查詢用圖(內容屬 Level 3)
                                    -- 未知 relation 統計以 queryGraphNotes 取出,library 不印

data QueryResult
  = FoundNodes   [(NodeId, Text, FilePath)]        -- id、label、source_file
  | ReachableSet [(NodeId, Int)]                   -- 節點與其距離(hop 數)
  | PathResult   (Maybe [NodeId])                  -- Nothing = 不連通
  | Ranking      [(NodeId, Int, Int)]              -- 節點、入度、出度
  | TestSet      [(NodeId, Int)]                   -- G-E007:測試節點與其距離(hop 數)

data LoadError
  = LoadFileMissing Text            -- 檔案不存在 / 讀不到
  | LoadParseError  Text            -- JSON 語法壞掉
  | LoadSchemaError Text            -- 必要欄位缺漏、邊引用不存在的節點 id
```

### 查詢規則(契約的一部分)

1. **依賴類邊才進圖**:`Reachable` / `ShortestPath` / `RankConnectivity` 只走依賴類 relation(`imports`、`imports_from`、`calls`、`uses`、`references`、`extends`、`implements`、`inherits`、`instantiates`、`depends_on`);結構類(`contains`、`method`、`defines`、`declares`、`rationale_for`、`part_of`)不算——與 dev-flow `scan-graph.mjs` 的 `DEP_RELATIONS` / `STRUCTURAL_RELATIONS` 逐項一致。`knot query` 讀的是任何 `codegraph.json`(含 graphify 產的其他語言圖),分類規則必須與唯一下游對齊,不能只認 knot 自己會產生的那五種
2. **未知 relation 列印排除**:載入時認不得的 relation 彙整列印(relation 名 + 邊數),不靜默吞掉(ADR-003 的下游行為)
3. **`FindNodes`** 比對所有節點(含結構類邊連接的節點);其餘三指令操作依賴圖
4. **決定性**:結果排序穩定(距離/度數同值時按 id 字典序)
5. **`Reachable` 不含起點自身**:只回距離 ≥ 1 的節點;起點若處在環上,會以其真實距離出現
6. **`ShortestPath` 多解取字典序最小路徑**(路徑視為節點 id 序列比大小):**展開某個節點時**把它的鄰居依 id 排序後入列,前驅取最早抵達者,確保同輸入必同輸出。注意這與「把整層佇列依 id 重排」不同——後者會退化成反向貪心而選到錯的路徑(反例:`S→Alpha→Xray→T` 與 `S→Beta→Whisky→T`,`Alpha < Beta` 但 `Whisky < Xray`,正解是走 `Alpha` 那條)

7. **層(E001)**:`restrictLevel` 把圖收斂為指定層的誘導子圖——`LevelModule` 只留非 `contains` 目標的節點、`LevelDecl` 只留 `contains` 目標,邊只留兩端都保留者,度數依留下的邊重算;四個查詢都在收斂後的圖上跑,`LevelAll` 即原圖。沒有 `contains` 邊的圖(非 knot 產生)全部視為 module 層
8. **深度(E001)**:`Reachable` 的第三欄為深度上限,`Just N` 只回距離 ≤ N 的節點,`Nothing` 不限;規則 5 不變
9. **範圍(G-E007)**:`restrictScope` 把圖收斂為指定範圍的誘導子圖——`ScopeProduct` 只留非測試節點、`ScopeTests` 只留測試節點,機制與規則 7 相同(兩者可交換);節點的 `component` 欄位缺鍵一律視為產品。`FindNodes` / `Reachable` / `ShortestPath` / `RankConnectivity` 都在收斂後的圖上跑
10. **`TestsOf`(G-E007)**:自目標**反向**可達、不限深度,只留測試節點,排序同 `Reachable`;必須在 `ScopeAll` 的圖上跑(呼叫端責任,規則 9 的收斂對它不適用),途經的產品節點照常展開但不進結果。圖上沒有任何測試節點時結果必空,CLI 層以 `queryGraphHasTests` 判斷並提示

### CLI 子命令對映(承接 system.md 頂層契約)

```text
knot --version                                   → 不進本子系統:CLI 組裝層印 `knot <版本> (GHC <版本>)` 即 exit 0(E002)
knot clean [PATH]                                → 不進本子系統:CLI 組裝層以 extraction 的 `knotDir` 取路徑後 removePathForcibly(E003)
knot query [--graph FILE] [--level all|module|decl] [--scope product|tests|all] <子命令>
                                                 → 先 restrictLevel,再 restrictScope,再 runQuery(預設 all / product);
                                                   tests-of 略過 restrictScope(規則 10)
knot query find <keyword>                        → FindNodes
knot query reachable <id> [--reverse] [--depth N] → Reachable … (Just N | Nothing);N ≥ 1(E001)
knot query path <from> <to>                      → ShortestPath
knot query rank [--top N]                        → RankConnectivity(N 預設 10)
knot query tests-of <id>                         → TestsOf(G-E007);圖無測試節點時 stderr 提示重跑 knot extract --include-tests
```

參數解析屬 CLI 組裝層;本子系統收 `QueryCommand`、`Level` 與 `Scope`。

### CLI `extract` 旗標對映與 exit code(承接 system.md 頂層契約,S5 起)

cli-assembly 不是 library 契約面,但它承接 system.md「CLI 介面(頂層契約)」,旗標 → 上游 Options DTO 的對映與 exit code 語意在此定死,feature 不得自行增減旗標。

| 旗標 | 對映到 | 備註 |
|---|---|---|
| `[PATH]`(預設 `.`) | `MetaOptions.root`、`ExtractOptions.rootDir`、`ExportOptions.rootDir` | 三個 DTO 的路徑欄位同源 |
| `--output FILE` | `ExportOptions.outputPath` | 未給時為 `<PATH>/codegraph.json`,預設值由 cli-assembly 算(library 不擁有 CLI 預設值,G-E001) |
| `--include-tests` | `MetaOptions.includeTests` | 單點落實:project-meta 據此填 `sfIncluded` / `compExcluded`,extraction 只消費判定結果 |
| `--strict` | cli-assembly 自己的 exit code 判定 | 見下 |
| `--summary meta\|facts\|graph` | cli-assembly 自己的輸出模式 | 印該站摘要到 stdout,不寫 `codegraph.json` |

**S5 移除**:`--backend`、`--module-only`(extraction 沒有後端選擇與能力分級了)、`--hiedir`(`.hie` 由 extraction 自建)、`--hiedb`(hiedb 已嵌入)、`--db`(`.knot/` 固定位置不改道)。對映上也就不再有 `ExtractOptions.backendChoice` / `hiedbExe` / `dbPath` 與 `MetaOptions.hieDirOverride` 可填。

**exit code 語意**(與 system.md「全域錯誤處理」兩層對齊):

| 情況 | exit | 與 `--strict` 的關係 |
|---|---|---|
| `extract` 回 `Left ExtractFailure`(建置失敗、GHC 版本不合、索引失敗、零原始檔) | **1** | 無關——這是整體失敗,不是警告;錯誤訊息印 stderr,**不寫** `codegraph.json`。**`VersionMismatch` 的訊息必須含 `cabal install knot-hs -w ghc-<vmHie>`**——一份 knot 只能讀一版 GHC 的 `.hie`,這是使用者唯一能做的事(extraction 規則 8) |
| `writeCodegraph` 拋 `IOException`(寫不出檔) | 1 | 無關 |
| 三站警告(`pmWarnings` + `erWarnings` + `cgWarnings`)總數 > 0 | 0 | `--strict` 時改為 1 |
| 一切正常 | 0 | — |
| `query` 的 `LoadError` | 1 | 無關 |
| `query` 查無結果 | 0 | 正常結果 |

**`--summary` 三站的內容**(S5 起):`meta` 印套件 / component / 檔案清單與 project-meta 警告,**不再有 `.hie` 段**;`facts` 印事實筆數(依 `Fact` 建構子分計)與 extraction 警告,**不再印能力等級與各後端報告**;`graph` 不變。`--summary` 仍會驅動插樁建置(它要的是真實的那一站輸出),`extract` 回 `Left` 時同樣 exit 1。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **export-writer** | `CodeGraph` → JSON 投影、commit 偵測、寫檔、`ExportReport` 組裝 |
| **graph-load** | 讀 `codegraph.json` → 驗證 → `QueryGraph`;未知 relation 的彙整排除 |
| **query-engine** | 四種查詢演算法(純函數,BFS/度數統計) |
| **query-render** | `QueryResult` → 人類可讀文字 |
| **cli-assembly** | (executable,非 library)`knot` 的參數解析與管線組裝:`extract` / `query` 兩個子命令、旗標對映成各子系統的 Options DTO、報告與警告列印、exit code(含 S5 的整體失敗通道:`Left ExtractFailure` → 訊息 + exit 1) |

## 資料流管線(Data Flow Pipeline)

```text
匯出:CodeGraph(+ ExportOptions)
  → export-writer: commit 偵測 → 投影(規則 1–5)→ 寫 codegraph.json → ExportReport → CLI 層列印
                   (commit 必須先偵測:built_at_commit 是投影輸出的頂層欄位)

查詢:codegraph.json 路徑 + QueryCommand
  → graph-load:   讀檔 → 驗證 → 依賴類/結構類分流 → QueryGraph(壞檔 → LoadError,exit 1)
  → query-engine: QueryCommand → QueryResult(純函數)
  → query-render: 文字 → stdout

組裝(knot extract,cli-assembly 負責串接;S5 起):argv
  → 解析 → MetaOptions / ExtractOptions / BuildOptions / ExportOptions
  → project-meta: loadProjectMeta → ProjectMeta
  → extraction:   extract → Left ExtractFailure ⇒ 印訊息、exit 1、不寫檔、到此為止
                            Right ExtractResult ⇒ 續行
  → graph-core:   buildGraph(ProjectMeta, ExtractResult)→ CodeGraph
  → export-writer: writeCodegraph → codegraph.json + ExportReport
  → 三站警告匯流印 stderr → exit code(--strict 判定)
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

cli-assembly 不在圖內:它是 executable 的組裝層,串接四個子系統,見「資料流管線 › 組裝」。

## 開發階段

對應主架構 S1(json-export)、S4(graph-load、query-commands、cli-wiring)與 **S5**(cli-zero-setup:砍旗標、整體失敗通道、`--summary` 收斂)。無額外內部里程碑。

## 功能規劃

### 階段一:S1 骨架

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | json-export | codegraph.json 投影、寫檔、commit 欄位、匯出報告 | export-writer | - | F001 |

### 階段二:S4 查詢 CLI

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 2 | graph-load | 讀回 codegraph.json、驗證、未知 relation 列印排除 | graph-load | #1 | F002 |
| 3 | query-commands | 四查詢演算法與文字輸出 | query-engine、query-render | #2 | F003 |
| 4 | cli-wiring | knot extract / query 兩子命令的參數解析與管線組裝 | cli-assembly | #1, #3 | F004 |

### 階段三:S5 零前置重構(ADR-006)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 5 | cli-zero-setup | 砍五個旗標、`Left ExtractFailure` → exit 1 通道、`--summary` 不印能力等級與 `.hie`、Options 對映同步上游新形狀 | cli-assembly | #4, extraction/F007, project-meta/F004 | F005 |

(共 5 個 features、3 個階段。**#5 是「S5 收尾三件套」之一**:它、extraction 的 two-layer-contract、project-meta 的 hie-retire 三者改的是同一組 DTO 的定義端與消費端,**必須同一批提交**——任一邊先落地都會讓另一邊編不過。2026-08-22 三份設計齊備,批次順序裁定為 extraction/F007 → project-meta/F004 → export-query/F005,#5 是讓整套重新編得過、測試重新跑得動的收尾者)

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
- **實作的 Level 2 介面**:`runQuery`、`renderResult`;DTO `QueryCommand`、`Direction`、`QueryResult`;查詢規則 3、4、5、6(規則 5、6 於本次委派展開期間新增,同屬本 feature);CLI 子命令對映表的四條語意
- **資料流管線段落**:從 `QueryGraph` + `QueryCommand` 進,經演算法,出 `QueryResult` 渲染為 stdout 文字
- **驗收標準**:以 fixture 圖驗證——`find` 不分大小寫比對 id 與 label;`reachable` 的 Forward/Reverse 方向正確且回報 hop 距離;`path` 在連通時回最短路徑、不連通時明確輸出「不連通」且 exit 0;`rank` 依 入度+出度 排序、同分按 id 字典序、`--top N` 生效;所有查詢只走依賴類邊(`contains` 不影響結果);同輸入兩次結果相同
- **明確不做**:不解析 CLI 參數(組裝層的事);不讀寫檔案(圖由 graph-load 給定);不做全對最短路徑或中心性等進階演算法(超出四能力範圍)

### cli-wiring

**F004 已完成;本卡為當時的驗收依據**。其驗收標準列的 `--backend` / `--module-only` / `--hiedir` 已於 S5 砍除(ADR-006),現行契約以上方「CLI `extract` 旗標對映與 exit code」節與 #5 cli-zero-setup 的卡為準。

CLI 組裝層是跨子系統的黏合層,不屬任何單一子系統的 library 契約;落在 export-query 是因為 `knot` 的兩個子命令(`extract` 的終點、`query` 的全部)主體都在此,且管線末站才看得到完整的輸出與 exit code 語意。

- **階段**:階段二
- **負責模組**:cli-assembly(在 executable `knot`,非 library)
- **實作的 Level 2 介面**:不新增 library 契約面。消費既有四個子系統的對外契約——`loadProjectMeta`(`MetaOptions`)、`extract`(`ExtractOptions`)、`buildGraph`(`BuildOptions`)、`writeCodegraph`(`ExportOptions`)、`loadQueryGraph` / `queryGraphNotes` / `runQuery` / `renderResult`;實作 system.md「CLI 介面(頂層契約)」全部旗標
- **資料流管線段落**:從 `argv` 進,解析成各子系統的 Options DTO,依 `project-meta → extraction → graph-core → export-query` 呼叫,出檔案 / stdout / stderr 與 exit code
- **驗收標準**:`knot extract [PATH]` 六個旗標(`--output`、`--backend auto|imports|hiedb`、`--module-only`、`--include-tests`、`--hiedir DIR`、`--strict`)全部解析正確且對映到正確的 Options 欄位;`knot query find|reachable|path|rank` 四子命令(含 `--reverse`、`--top N`,N 預設 10)對映到正確的 `QueryCommand`;`--summary meta|facts|graph` 保留三個既有唯讀驗收輸出,不給時 `extract` 的預設行為是寫 `codegraph.json`;`--help` 對頂層與每個子命令都可用;無效旗標與缺參數 exit 非 0 且訊息指出問題;`LoadError` exit 1、查無結果 exit 0;有跳檔時預設 exit 0 而 `--strict` 下 exit 1;`ExportReport` 的 `xrNotes` 與 `queryGraphNotes` 由本層印出(library 仍全程不印);以 MagicFarmer 與 particle-magic 唯讀實跑,產出的 `codegraph.json` 經 dev-flow `scan-graph.mjs` 解析成功
- **明確不做**:不含任何投影、載入或查詢邏輯(全部委由四個子系統的契約函式);不新增 library 公開面;不改動任何子系統的 Options DTO 形狀(需要改就停下回報)

### cli-zero-setup

- **階段**:階段三
- **負責模組**:cli-assembly(在 executable `knot`,非 library)
- **實作的 Level 2 介面**:不新增 library 契約面。落實本文件「CLI `extract` 旗標對映與 exit code」節的**全部**內容:五個旗標移除、`MetaOptions` / `ExtractOptions` 對映同步上游的新形狀(`MetaOptions` 無 `hieDirOverride`;`ExtractOptions` 只剩 `rootDir`)、`extract` 的 `Either ExtractFailure ExtractResult` 回傳處理、`--summary meta` / `facts` 的內容收斂。消費既有契約 `loadProjectMeta`、`extract`、`buildGraph`、`writeCodegraph`,簽名以各子系統 S5 後的 `design.md` 為準
- **資料流管線段落**:「資料流管線 › 組裝」整段——從 `argv` 進,經四站串接,出檔案 / stdout / stderr 與 exit code;新增的分支是 extraction 回 `Left` 時的短路
- **驗收標準**:`knot extract --help` **不再列出** `--backend` / `--module-only` / `--hiedir` / `--hiedb` / `--db`,給這些旗標 exit 非 0 且訊息指出不認得;`knot extract [PATH]` 剩餘四個旗標(`--output`、`--include-tests`、`--strict`、`--summary`)解析正確且對映到正確的 Options 欄位;`ExtractOptions` 對映只填 `rootDir`、`MetaOptions` 對映無 `hieDirOverride`(型別檢查即證明,殘留欄位是編譯錯誤);以假的 `extract` 回 `Left BuildFailed` → exit 1、stderr 含 `bfComponent` 與 `bfDetail`、**`codegraph.json` 不存在**;`Left` 的四種建構子各自有可辨識的訊息;`--strict` 的判定不受 `Left` 影響(`Left` 永遠 exit 1);`--summary facts` 的輸出**不含**「level」「backends」字樣、`--summary meta` 的輸出**不含** `.hie` 段;`--summary` 在 `extract` 回 `Left` 時亦 exit 1;既有 `knot query` 四子命令行為零變動(F003 測試全綠);**對一個乾淨的目標專案(無 `.hie`、無 `.knot/`)執行 `knot extract .`,一個命令跑完,產出兩層圖**——這是 ADR-006 的端對端驗收,也是 S5 三件套同批落地的證明;五份黃金檔 byte 不變;閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0
- **明確不做**:不含任何投影、載入或查詢邏輯;不新增 library 公開面;**不替上游定義 DTO**(`ExtractFailure` 等由 extraction 定義,本 feature 只消費);不提供任何「相容舊旗標」的別名或靜默忽略——舊旗標就是錯誤;不改 `knot query` 的任何旗標與語意;不動 README(那是文件任務,等三件套落地後一併改)
