---
id: graph-core
type: subsystem
title: graph-core
description: 圖 IR 子系統:決定性節點 id 鑄造、兩層節點組裝與邊推導
status: active
created: 2026-08-20
updated: 2026-08-22
parent: system
related-adr: []
code-paths: [src/Knot/Graph, src/Knot/Graph.hs]
---

# graph-core 子系統架構

## 定位與範圍

管線第三站(見 system.md「子系統劃分 › graph-core」):吃 project-meta 的 `ProjectMeta` 與 extraction 的 `ExtractResult`,組裝成內部圖 IR `CodeGraph`,交給 export-query 投影。

**職責**:鑄造決定性節點 id(Module + OccName + namespace,**絕不用 GHC `Unique`**);組裝 module + decl 兩層節點與 `contains` 結構邊;由事實推導依賴邊(imports / calls / uses / implements);過濾 TH/deriving 產生碼的異常事實;外部目標丟棄與統計;彙整警告。

**明確不做**:不讀檔案、不做任何 IO、不認識 `.hie` 或 SQLite(只認事實流)、不序列化(codegraph.json 是 export-query 的事)、不做 span 比對(fromDecl 已由 extraction 解析)。

## 對外契約(Public Interface & DTOs)

唯一進入點,**純函數**(無 IO,同輸入必同輸出):

```haskell
buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph
```

```haskell
data BuildOptions = BuildOptions
  { moduleOnly :: Bool          -- 對應 CLI --module-only:只出 module 節點與 imports 邊
  }

data CodeGraph = CodeGraph
  { cgNodes    :: [GraphNode]
  , cgEdges    :: [GraphEdge]
  , cgStats    :: GraphStats    -- 丟棄/過濾/去重統計,供匯出層列印
  , cgWarnings :: [GraphWarning]
  }

newtype NodeId = NodeId Text    -- 鑄造規則見下,構造唯一入口在 node-mint

data GraphNode = GraphNode
  { gnId    :: NodeId
  , gnKind  :: NodeKind
  , gnLabel :: Text             -- 人類可讀名(module 名 / occ 名 / instance 標頭)
  , gnFile  :: FilePath         -- repo 相對、正斜線(codegraph 必填欄位的來源)
  , gnLine  :: Maybe Int        -- 下游 source_location(L<行>)的來源
  }

data NodeKind = ModuleNode | DeclNode DeclKind | InstanceNode

data GraphEdge = GraphEdge
  { geSource   :: NodeId
  , geTarget   :: NodeId
  , geRelation :: Relation
  , geLine     :: Maybe Int     -- 首見證據行(去重時保留最早一筆)
  }

data Relation = RImports | RCalls | RUses | RImplements | RContains

data GraphStats = GraphStats
  { gsDroppedExternal    :: Int                    -- 指向外部目標而丟棄的邊數
  , gsTopExternalTargets :: [(ModuleName, Int)]    -- 被指最多的外部 module(報告用);取前 10,依次數降序、同次數依 module 名字典序
  , gsFilteredGenerated  :: Int                    -- TH/產生碼過濾掉的事實數
  , gsDedupedEdges       :: Int                    -- 去重合併的邊數
  }
```

```haskell
data GraphWarning = GraphWarning        -- (批次澄清裁決,比照 MetaWarning / ExtractWarning)
  { gwSource  :: Text                   -- 來源:module 名、節點 id 或檔案路徑
  , gwMessage :: Text
  }
```

### 節點 id 鑄造規則(契約的一部分,一經發佈不可變)

| 節點 | id 格式 | 例 |
|---|---|---|
| module | 裸 module 名;同名碰撞時整組改用 `<module>@<source_file>` | `Demo.Core`、`Main@app/Main.hs` |
| 值宣告 | `<mod-id>.<occ>` | `Demo.Core.render`、`Main@app/Main.hs.main` |
| 型別宣告 | `<mod-id>.<occ>#t` | `Demo.Core.Foo#t`(與建構子 `Demo.Core.Foo` 不碰撞) |
| instance | `<mod-id>#i:<instance 標頭>` | `Demo.Core#i:Renderable Sprite` |

**`<mod-id>` = 該 module 節點實際鑄出的 id**(批次澄清 C3 裁決):未碰撞時是裸 module 名,碰撞組成員是 `<module>@<source_file>`。decl 層節點沿用所屬 module 的消歧結果,故 `mintDeclId` / `mintInstanceId` 都帶 `Maybe FilePath`,語意同 `mintModuleId`(`Nothing` = 未碰撞、鑄裸名)。理由與階段一假設 A2 同源:缺了 file 參數,多 executable 專案的 `Main.main` 會整組撞成同一個 id 而在去重時被靜默吞掉。

值宣告的 `<occ>` 涵蓋 `ValueNs` / `DataConNs` / `FieldNs` 三個 term-level namespace,`#t` 專屬 `TypeNs`。**已知精度限制(繼承 extraction 假設 A9)**:`DuplicateRecordFields` 下同一 module 的兩個同名欄位選擇器,丟棄父型別後 `QualName` 相同,會鑄出同一個 id 並在去重時合併。這是 extraction 契約的粗度,graph-core 不補救、不猜測。

id 只由 `QualName`(module、occ、namespace)、instance 標頭與(碰撞時的)`source_file` 決定——同一份原始碼在任何機器、任何次編譯都鑄出相同 id。

**同名 module 消歧(批次澄清裁決)**:多個來源檔宣告同一 module 名時(例:多個 executable 各有自己的 `Main`;extraction 的 D3 讓無標頭檔一律視為 `Main`),該組**全部**改用 `<module>@<source_file>` 形式,並將碰撞事實彙整進 `GraphWarning`;同名只有一個來源檔時維持裸名。判定依 `FactModule.fmFile` 的相異數,結果對同一輸入恆定。decl 層節點(階段二)沿用其所屬 module 節點的消歧結果。

### 組裝規則(契約的一部分)

1. **內部節點才實化**:內部 module 集合 = 事實流中所有 `FactModule` 的 `fmModule`(批次澄清裁決:與節點來源同一樣本,避免「節點存在卻被當外部丟邊」;非 `pmSources` 的 `sfModule`,後者為路徑推導且可能與檔內標頭不符)。只為內部 module 及其宣告建節點;指向外部(base、第三方套件)的邊**丟棄**,彙整進 `gsDroppedExternal` 與 `gsTopExternalTargets`,不靜默吞掉
2. **邊推導表**:

   | 事實 | 產出 |
   |---|---|
   | `FactModule` | module 節點 |
   | `FactImport`(雙端內部) | `RImports`(module → module) |
   | `FactDecl` | decl 節點 + `RContains`(module → decl) |
   | `FactRef`(target 為 term-level:`ValueNs` / `DataConNs` / `FieldNs`) | `RCalls`(fromDecl → target decl) |
   | `FactRef`(target 為 type-level:`TypeNs`) | `RUses`(fromDecl → target decl) |
   | `FactRef`(`frFromDecl = Nothing`) | 以**來源 module 節點**為源,relation 依 namespace 同上 |
   | `FactInstance` | instance 節點 + `RContains`(module → instance)+ `RImplements`(instance → class,class 為內部節點時) |

   **namespace → relation 是 term/type 二分**(批次澄清 C2 裁決):值層面的名字(函式、資料建構子、記錄欄位選擇器)一律 `RCalls`,`RUses` 專留給型別層面。`NameSpace` 的四個值全部有歸屬,不留靜默落空的縫;extraction 的 `z:`(型別變數)在其契約已裁決不產出,不會流到這裡。

   **`FactInstance` 目前無後端產出**(extraction C4:hiedb 0.8 的 schema 無 instance 表;見 system.md「`implements` 邊不在 S3」)。graph-core 仍**完整實作** instance 節點鑄造與 `RImplements` 推導並以手工事實流驗收——兩段都是純函數,ADR-002 預留的第三後端上線時零改動即生效;端到端輸出目前恆為 0 個 instance 節點與 0 條 `RImplements` 邊(批次澄清 C1 裁決)。

3. **產生碼過濾**:三者任一成立即濾除該事實並計入 `gsFilteredGenerated`——(a) 事實指向的檔案不在 `pmSources`;(b) 行號 ≤ 0;(c) `FactRef.frGenerated = True`(批次澄清 C4 裁決)。(c) 直接採信 extraction 規則 4a 原樣轉載的 `refs.is_generated` 事實,**不做「異常 span」啟發式**(system.md 已據此改寫 S3 描述);實測 knot-hs 自身 846/7265 = 11.6% 的 ref 屬此類。deriving 產生的引用不對應任何人寫的程式碼行,留著會在 decl 間製造非人為的邊並污染 hub 排名
4a. **消歧組的 import 目標**:`FactImport` 的目標 module 屬 D1 消歧組時,無從判定指向組內哪個節點 → 丟棄該邊並發 `GraphWarning`,**不**計入 `gsDroppedExternal`(它不是外部目標;A4 裁決)
4. **自環丟棄**:source 與 target 相同的邊(遞迴呼叫、module 自引)不產出,不計警告
5. **去重**:相同 `(source, target, relation)` 的邊合併為一條,保留最早的 `geLine` 證據行,合併數計入 `gsDedupedEdges`
6. **`moduleOnly`**:只輸出 module 節點與 `RImports` 邊(decl 層事實直接忽略,不計入統計)
7. **決定性**:`cgNodes` 依 `NodeId` 字典序、`cgEdges` 依 `(source, relation, target)` 字典序(批次澄清裁決);同輸入必同輸出

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **fact-gate** | 事實驗證與過濾:建立內部 module 集合、產生碼過濾(規則 3)、內部/外部判定(規則 1 的判定面) |
| **node-mint** | 節點 id 鑄造(鑄造規則表)與 `GraphNode` 建構;`NodeId` 的唯一構造入口 |
| **edge-derive** | 邊推導(規則 2)、自環丟棄(規則 4)、去重與證據行(規則 5) |
| **graph-assemble** | `buildGraph` 進入點:調度前三者、`moduleOnly` 分流(規則 6)、統計與警告彙整、穩定排序(規則 7) |

## 資料流管線(Data Flow Pipeline)

```text
ProjectMeta + ExtractResult(+ BuildOptions)
  → fact-gate:      建內部集合 → 濾除產生碼事實、標記內外部     (濾除量進統計)
  → node-mint:      FactModule/FactDecl/FactInstance → 節點集合
  → edge-derive:    事實 × 節點集合 → 邊集合(丟外部、去自環、去重)
  → graph-assemble: moduleOnly 分流 → 統計彙整 → 穩定排序 → CodeGraph → 交給 export-query
```

全程純函數,無 IO、無外部呼叫;警告以值的形式在管線中傳遞。

## 模組間公開介面(Module Interfaces)

```haskell
-- fact-gate:過濾與判定
gateFacts :: ProjectMeta -> [Fact] -> GatedFacts
data GatedFacts = GatedFacts
  { gfFacts    :: [Fact]          -- 通過過濾的事實
  , gfInternal :: Set ModuleName  -- 內部 module 集合(內外部判定的依據)
  , gfFiltered :: Int             -- 濾除量(進 gsFilteredGenerated)
  }

-- node-mint:鑄造
mintModuleId   :: ModuleName -> Maybe FilePath -> NodeId   -- Nothing = 該 module 未碰撞,鑄裸名(A2 裁決)
mintDeclId     :: QualName -> Maybe FilePath -> NodeId          -- Maybe FilePath 語意同 mintModuleId(C3 裁決)
mintInstanceId :: ModuleName -> Maybe FilePath -> Text -> NodeId -- (消歧, instance 標頭)
mintNodes      :: GatedFacts -> [GraphNode]

-- edge-derive:推導
deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])   -- (A3 裁決)
data EdgeStats = EdgeStats
  { esDroppedExternal :: Int
  , esTopExternal     :: [(ModuleName, Int)]
  , esDeduped         :: Int
  }
```

## 使用的技術

沿用主架構技術棧;無子系統特有選型——boot libs(`containers`)即足,全模組純函數。

## 架構圖

```text
 ProjectMeta + ExtractResult + BuildOptions
      │
      ▼
 ┌─ graph-core(全純函數)─────────────────────────────┐
 │  fact-gate ──GatedFacts──▶ node-mint                │
 │      │                        │ [GraphNode]          │
 │      │   ┌────────────────────┤                      │
 │      ▼   ▼                    │                      │
 │  edge-derive ──[GraphEdge]────┤                      │
 │      │ EdgeStats              │                      │
 │      ▼                        ▼                      │
 │  graph-assemble(moduleOnly 分流、統計、穩定排序)   │
 └───────────────┬──────────────────────────────────────┘
                 ▼
        CodeGraph → export-query
```

## 開發階段

對應主架構 S1(module 層)與 S3(decl 層、TH 過濾)。無額外內部里程碑。

## 功能規劃

### 階段一:S1 骨架

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | module-graph | CodeGraph DTO、buildGraph 進入點、module 節點與 imports 邊、外部丟棄統計 | graph-assemble、fact-gate、node-mint、edge-derive | - | F001 |

### 階段二:S3 decl 層

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 2 | decl-nodes | decl/instance 節點鑄造、contains 邊、TH/產生碼過濾 | fact-gate、node-mint、edge-derive | #1 | F002 |
| 3 | decl-edges | calls/uses/implements 推導、自環丟棄、去重與證據行 | edge-derive | #2 | - |

(共 3 個 features、2 個階段;全部完成即子系統可交付)

## Feature 契約卡

### module-graph

- **階段**:階段一
- **負責模組**:graph-assemble、fact-gate、node-mint、edge-derive
- **實作的 Level 2 介面**:`buildGraph` 進入點;DTO `BuildOptions`、`CodeGraph`、`NodeId`、`GraphNode`、`NodeKind`(本階段只用 `ModuleNode`)、`GraphEdge`、`Relation`(本階段只用 `RImports`)、`GraphStats`、`GraphWarning`;模組介面 `gateFacts`、`GatedFacts`、`mintModuleId`、`mintNodes`、`deriveEdges`、`EdgeStats`;落實組裝規則 1(內部才實化)、2 的 `FactModule`/`FactImport` 列、4(自環)、5(去重)、7(決定性)
- **資料流管線段落**:從 `FactModule`/`FactImport` 事實進,走完整四模組管線,出只含 module 節點與 imports 邊的 `CodeGraph`
- **驗收標準**:以 fixture 事實流驗證——`import base 系 module` 的邊被丟棄且 `gsDroppedExternal`/`gsTopExternalTargets` 正確;重複 import 合併且 `gsDedupedEdges` 計數;module 自 import 不產邊;同輸入兩次呼叫結果完全相等(純函數);`moduleOnly = True/False` 在本階段輸出相同(尚無 decl 事實)
- **明確不做**:不處理 `FactDecl`/`FactRef`/`FactInstance`(decl-nodes、decl-edges 的事,本階段忽略之但不 crash);不序列化 JSON;不印任何輸出(統計只放進 `GraphStats`)

### decl-nodes

- **階段**:階段二
- **負責模組**:fact-gate、node-mint、edge-derive(`RContains` 一列;所有邊一律由 edge-derive 產出,以「內部模組劃分」表為準)
- **實作的 Level 2 介面**:`mintDeclId`、`mintInstanceId`;`NodeKind` 的 `DeclNode`/`InstanceNode`;鑄造規則表全表(含 `#t`、`#i:` 後綴);組裝規則 2 的 `FactDecl`/`FactInstance` 節點與 `RContains` 列、規則 3(產生碼過濾)、規則 6(`moduleOnly` 忽略 decl 層)
- **資料流管線段落**:從 `FactDecl`/`FactInstance` 事實進,經 fact-gate 過濾與 node-mint 鑄造,出 decl/instance 節點與 `RContains` 邊
- **驗收標準**:同名型別與值鑄出不同 id(`Demo.Core.Foo#t` vs `Demo.Core.Foo`);instance 節點 id 含渲染標頭且穩定;指向 `pmSources` 外檔案或行號 ≤ 0 的事實被濾除且 `gsFilteredGenerated` 計數;每個 decl 節點有一條來自所屬 module 的 `RContains`;`moduleOnly = True` 時 decl 節點與 `RContains` 完全不出現
- **明確不做**:不推導 calls/uses/implements(decl-edges 的事);不改 module 層行為;不嘗試為外部名稱建節點

### decl-edges

- **階段**:階段二
- **負責模組**:edge-derive
- **實作的 Level 2 介面**:`Relation` 的 `RCalls`/`RUses`/`RImplements`;組裝規則 2 的 `FactRef`/`FactInstance` 邊列(含 `frFromDecl = Nothing` 以 module 為源的規則)、規則 4、規則 5(證據行保留)
- **資料流管線段落**:從 `FactRef`/`FactInstance` 事實與 decl-nodes 的節點集合進,出 calls/uses/implements 邊
- **驗收標準**:以 fixture 事實流驗證——值目標產 `RCalls`、型別目標產 `RUses`;`frFromDecl = Nothing` 的引用邊源是 module 節點;遞迴呼叫(自環)不產邊;同一對 decl 間多次呼叫合併為一條且 `geLine` 是最早行;instance 對內部 class 產 `RImplements`、對外部 class 丟棄並計入統計;目標解析不到內部節點的 ref 彙整為警告不靜默
- **明確不做**:不建新節點(節點集合由 decl-nodes 給定);不做 span 比對(fromDecl 是 extraction 給的);不改 imports 邊行為
