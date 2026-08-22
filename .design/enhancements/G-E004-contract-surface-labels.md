---
id: G-E004
type: enhance
title: contract-surface-labels
description: 契約標籤對帳與 ModuleName 的傳遞型 re-export
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [ADR-005]
related-feature: [extraction/F001, graph-core/F001, graph-core/F002, graph-core/F003, export-query/F002, export-query/F003, export-query/F004]
subsystems: [extraction, graph-core, export-query]
---

# G-E004: 契約標籤對帳與 `ModuleName` 的傳遞型 re-export

## 現況分析

出自 2026-08-22 `/arch-audit system` 的發現 ③ 與 ⑥,並在本文檔撰寫時逐一回原始碼複驗。

### (1) `Knot.Extract.Types` 用了 `ModuleName` 卻不 re-export

`src/Knot/Extract/Types.hs:28` 有 `import Knot.Meta.Types (ModuleName (..))`,四個契約 DTO 欄位是這個型別:

| 位置 | 欄位 |
|---|---|
| `:58` | `qnModule :: ModuleName`(`QualName`) |
| `:80` | `fmModule :: ModuleName`(`FactModule`) |
| `:82` | `fiFrom` / `fiTo :: ModuleName`(`FactImport`) |
| `:91` | `frFromModule :: ModuleName`(`FactRef`) |

但匯出清單(`:11-24`)沒有 `ModuleName`。結果是:**收到 extraction 契約的人,無法只靠 extraction 的契約模組把手上的值命名出來**,必須再開一個 import 回到 project-meta。

全專案掃過,只為了命名 `ModuleName` 而 import `Knot.Meta.Types` 的檔案恰好兩個:

```
src/Knot/Graph/EdgeDerive.hs:44:import Knot.Meta.Types (ModuleName (..))
src/Knot/Graph/NodeMint.hs:33:import Knot.Meta.Types (ModuleName (..))
```

兩者**都已經 import 了 `Knot.Extract.Types`**(`EdgeDerive.hs:27`、`NodeMint.hs:30`,各取 `Fact (..)` / `NameSpace (..)` / `QualName (..)`),所以 re-export 一補上,那兩行就能直接刪掉。

**這一項的性質已經改變,必須講清楚**:`/arch-audit system` 當時把它報成邊界問題,但同一次檢測也修正了拓撲宣告——`project-meta → graph-core` 現在是 `system.md` 拓撲表的**邊 2**,那兩個 import 因此完全合法。ADR-005 的附帶義務也只要求**擁有者**(project-meta)re-export,而 `Knot.Meta.Types` 本來就有。

所以本項**不是違規修復,是人體工學改善**,開發者在 scope 討論時知情後仍決定納入。ADR-005 待辦欄目前寫「依附帶義務應補上 re-export」,那句把規則講得比實際寬,一併修正。

### (2) 契約標籤對帳:四處全掃,錯一對三

全專案帶「非契約面」標籤的匯出小節共四處。逐一對回各自 `design.md` 的「對外契約」與「模組間公開介面」兩節:

| # | 位置 | 涵蓋的匯出 | 對帳結果 |
|---|---|---|---|
| 1 | `src/Knot/Extract/Backend.hs:13`「調度引擎(非契約面)」 | `runBackends` | ✅ **正確**。extraction 對外契約只有 `extract`;模組間公開介面只有 `Backend` / `ProbeResult` / `ensureIndex` / `readIndexFacts` |
| 2 | `src/Knot/Graph/NodeMint.hs:14`「非契約面」 | `moduleFiles`、`disambiguate`、`moduleOfFile`、`declNodeIndex` | ✅ **正確**。graph-core 模組間公開介面只列 `gateFacts` / `GatedFacts` / `mintModuleId` / `mintDeclId` / `mintInstanceId` / `mintNodes` / `deriveEdges` / `EdgeStats` |
| 3 | `src/Knot/Query/Load.hs:19`「非契約面」 | `parseQueryGraph`、`RelationClass`、`classifyRelation`、`dependencyRelations`、`structuralRelations` | ✅ **正確**。export-query 契約查詢面五個函式不含這些 |
| 4 | `src/Knot/Query/Types.hs:19`「非契約面」 | `NodeId (..)`、`QueryNode (..)` | ❌ **`NodeId (..)` 標錯**(見下);`QueryNode (..)` 正確 |

**4 的成因查得到**,不是隨手寫錯。`export-query/features/F002-graph-load.md:335` 的非契約面表寫著:

> `NodeId (..)` | `Knot.Query.Types` | 契約在 `QueryCommand` / `QueryResult` 用到 `NodeId`,但**沒定義它**;本 feature 補上(假設 A1)

F002 當時的判斷正確。但現在的 `export-query/design.md`「對外契約 › 查詢面」**已經定義了它**:

```haskell
newtype NodeId = NodeId Text        -- 查詢面自有,與 graph-core 的同名型別無關
```

契約補齊之後,F002 的假設 A1 就消解了,而程式碼裡的標籤沒跟著更新。公開的 `Knot.Query` 也照契約 re-export 了 `NodeId (..)`(`src/Knot/Query.hs:21`)——**公開面是對的,只有內部模組的分組註解過期**。

### (3) 同一處的反向錯標:`QueryGraph (..)`

對帳第 4 處時另外查到一個方向相反的:`src/Knot/Query/Types.hs` 把 `QueryGraph (..)` 放在「**對外契約**」小節,但

- `export-query/design.md` 寫的是 `data QueryGraph -- 從 codegraph.json 載入的查詢用圖(**內容屬 Level 3**)`
- `F002-graph-load.md:337` 明文把「`QueryGraph (..)`(七個欄位選擇器)」登記為**非契約面**
- `src/Knot/Query/Types.hs:41` 自己的 haddock 也寫「Level 2 契約的**抽象** DTO」

也就是:**抽象型別是契約,七個欄位選擇器不是**。`(..)` 把兩者綁在同一個匯出項,而它被整個歸進「對外契約」小節,讀起來像是欄位也屬契約。

公開面沒有受影響——`src/Knot/Query.hs:20` re-export 的是不帶 `(..)` 的 `QueryGraph`,欄位不外露。純粹是內部模組的分組敘述失真。

### (4) 順帶:未標示契約狀態的一組匯出

`src/Knot/Extract/Backend.hs` 的「後端名常數」小節(`importScanName :: Text`、`hiedbName :: Text`)既沒標契約面也沒標非契約面。兩者都不在 extraction `design.md` 的任何介面區塊裡(`brBackend` 的**值域**是契約,具名常數本身是便利品),依既有慣例應標為非契約面。

## Scope(涵蓋範圍)

2026-08-22 與開發者確認的定案。

**動**:

| 項目 | 子系統 | 檔案 |
|---|---|---|
| A `ModuleName` 傳遞型 re-export | extraction、graph-core | `src/Knot/Extract/Types.hs`、`src/Knot/Graph/EdgeDerive.hs`、`src/Knot/Graph/NodeMint.hs` |
| B 契約標籤修正 | export-query、extraction | `src/Knot/Query/Types.hs`、`src/Knot/Extract/Backend.hs` |
| C 文檔同步 | — | `.design/adr/ADR-005-…md`、`export-query/features/F002-graph-load.md` |

**明確不動**:

- **對帳結果為「正確」的三處標籤一個字都不改**(`Extract/Backend.hs:13`、`Graph/NodeMint.hs:14`、`Query/Load.hs:19`),只用測試把結論鎖住
- **不刪、不新增任何匯出符號**(唯一新增是 `ModuleName` 的 re-export,它本來就在 `Knot.Meta.Types` 的公開面上)
- 不動 `Knot.Query` 的公開 re-export(`QueryGraph` 維持抽象、不帶 `(..)`)
- 不動 `knot-hs.cabal` 的雙 library 佈局與 9 個 `reexported-modules`
- 不改任何演算法行為:`codegraph.json` 輸出必須 **byte 級不變**
- `Graph.hs:31` 與 `FactGate.hs:16` 的 `import Knot.Meta.Types` **不動**——它們另需 `ProjectMeta` / `SourceFile`,而 graph-core → project-meta 是拓撲表的邊 2,合法

**對外契約是否受影響**:

- **Level 1 不變**;**Level 2 不變**——本次沒有任何契約條目的增刪或簽名變動
- `Knot.Extract.Types` 多 re-export 一個型別:公開面**擴大**但不改變任何既有語意,且該型別早已是 project-meta 的公開契約
- 契約標籤修正是**把程式碼註解對回既有契約**,契約本身不動

**討論中冒出、確認排除的項目**:

- 把 `Knot.Extract.Types` 也 re-export `ProjectMeta` / `SourceFile` —— 排除,消費端本來就有合法的邊直接取用,再加會讓 extraction 的公開面無謂變寬
- 把 `QueryGraph` 的欄位選擇器從 `Knot.Query.Types` 移到獨立的 `.Internal` 模組 —— 排除,ADR-004 的 private sublibrary 已經讓整個模組不在公開面上,再拆沒有增益

## 改善目標

讓「這個匯出到底屬不屬於契約」這件事,在程式碼裡讀到的答案與 `design.md` 一致,而且不會再默默漂回去。

**量化驗收標準**

| # | 標準 | 怎麼量 |
|---|---|---|
| 1 | 標錯的契約標籤 2 → **0** | `NodeId (..)` 移入對外契約組;`QueryGraph (..)` 註明欄位選擇器非契約 |
| 2 | 未標示契約狀態的匯出小節 1 → **0** | `Extract/Backend.hs` 的「後端名常數」補上標示 |
| 3 | 為命名 `ModuleName` 而跨模組 import `Knot.Meta.Types` 的檔案 2 → **0** | `grep -c "^import Knot.Meta.Types (ModuleName (\.\.))$" src/Knot/Graph/*.hs` 回 0 |
| 4 | 四處標籤的對帳結論**可回測** | 新增表格驅動測試,四處逐一鎖定(含三處「本次確認正確」) |
| 5 | 公開面不變質 | `Knot.Query` 仍匯出**抽象** `QueryGraph`(不帶 `(..)`);`knot-hs.cabal` 的 9 個 `reexported-modules` 不變 |
| 6 | **行為零變更**:`codegraph.json` byte 級不變 | 沿用 G-E001 的 `test_codegraph_output_unchanged`(5 份黃金檔) |
| 7 | 建置閘門零警告 | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0 |
| 8 | 既有測試零退化 | 148 條全綠 |

## 相依性

`depends-on: []` —— 不依賴任何未完成的文檔。查證依據:`.design/` 全部 14 份 feature 與 G-E001/002/003 皆 `status: done`,無進行中任務(2026-08-22 掃描,exit 0)。

**引用而非依賴**:

- **ADR-005**:本文檔項目 A 的判準來源,同時**修正它的待辦欄措辭**(現行寫法把附帶義務講得比規則本身寬)
- **G-E001**:項目 A 的兩個受益檔是它收斂公開面後留下的;驗收標準 6 直接沿用它建立的黃金檔測試
- **`export-query/F002`**:標籤錯誤的成因(假設 A1)登記在該文檔,T5 回頭註記

**影響的文檔**(T5 同步):`ADR-005`、`export-query/features/F002-graph-load.md`。`design.md` 一律不動——本次是把程式碼對回既有契約,不是改契約。

**平行開發結論**:項目 A(T1→T2)與項目 B(T3、T4)完全無交集,可平行;T5、T6 收在最後。整體規模小、風險低,與其他任務平行亦無妨。

## 改善方案

### M1 — `ModuleName` 的傳遞型 re-export(項目 A)

`src/Knot/Extract/Types.hs` 匯出清單新增一個小節:

```haskell
    -- * 共用詞彙型別(re-export 自 project-meta,見 ADR-005)
  , ModuleName (..)
```

`import Knot.Meta.Types (ModuleName (..))`(`:28`)已經在,不必動。模組頂端的 haddock(`:4-5`「本 module 不重複定義」)補一句說明:不重複定義,但**代為 re-export**,讓消費端不必為了命名而繞回源頭。

接著兩個受益檔:

- `src/Knot/Graph/EdgeDerive.hs`:刪 `:44` 的 `import Knot.Meta.Types (ModuleName (..))`,把 `ModuleName (..)` 併進 `:27` 既有的 `import Knot.Extract.Types (…)`
- `src/Knot/Graph/NodeMint.hs`:刪 `:33`,同樣併進 `:30` 既有的 `Knot.Extract.Types` import

`Graph.hs:31` 與 `FactGate.hs:16` **不動**(另需 `ProjectMeta` / `SourceFile`)。

### M2 — `Knot.Query.Types` 的契約標籤(項目 B)

匯出清單改成:

```haskell
module Knot.Query.Types
  ( -- * 對外契約
    LoadError (..)
  , QueryCommand (..)
  , Direction (..)
  , QueryResult (..)
  , NodeId (..)
    -- 契約是抽象型別本身;七個欄位選擇器屬 Level 3,只給 graph-load /
    -- query-engine 內部用(公開的 Knot.Query 只 re-export 不帶欄位的 QueryGraph)
  , QueryGraph (..)
    -- * 非契約面(F003 取用)
  , QueryNode (..)
  ) where
```

`NodeId (..)` 上移;`QueryGraph (..)` 留在契約組但加註欄位選擇器的層級;非契約面小節只剩 `QueryNode (..)`,其引文從「F003 \/ F004 取用」收斂為「F003 取用」(`F004` 用的是 `NodeId`,已升格)。

### M3 — `Knot.Extract.Backend` 的常數標示(項目 B)

「後端名常數」小節標題補上契約狀態:

```haskell
    -- * 後端名常數(非契約面:brBackend 的值域是契約,具名常數本身不是)
  , importScanName
  , hiedbName
```

### M4 — 文檔同步(項目 C)

- **`ADR-005`「待辦」欄**:現行寫「依附帶義務應補上 re-export」。改為說明附帶義務由**擁有者** project-meta 履行(`Knot.Meta.Types` 已匯出 `ModuleName`),extraction 的 re-export 是**傳遞型的便利改善**而非義務,並回鏈 G-E004
- **`export-query/features/F002-graph-load.md`**:非契約面表的 `NodeId (..)` 那一列註明「假設 A1 已於 `design.md` 補齊定義後消解,G-E004 把標籤升為契約面」;`QueryGraph (..)` 那一列維持原判(欄位選擇器確實非契約),不動

### 遷移步驟

1. M2 / M3(純註解,零語意)——先做,做完跑一次閘門確認沒手滑
2. M1(動 import)——`Knot.Extract.Types` 先加 re-export,再改兩個消費端
3. M4 文檔
4. 每步都跑 `cabal build all --enable-tests` + 黃金檔測試

### 錯誤處理

行為零變更,不涉及任何錯誤路徑。

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `newtype ModuleName = ModuleName Text` | `src/Knot/Meta/Types.hs:74` | project-meta/F001 | M1 要 re-export 的型別 |
| `qnModule :: ModuleName`(`QualName` 欄位) | `src/Knot/Extract/Types.hs:58` | extraction/F001 | M1 的動機:契約 DTO 用了它 |
| `runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult` | `src/Knot/Extract/Backend.hs:68` | extraction/F001 | 對帳第 1 處,確認標籤正確(不動) |
| `importScanName :: Text` | `src/Knot/Extract/Backend.hs:46` | extraction/F001 | M3 的標示標的 |
| `hiedbName :: Text` | `src/Knot/Extract/Backend.hs:50` | extraction/F001 | M3 的標示標的 |
| `moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)` | `src/Knot/Graph/NodeMint.hs:74` | graph-core/F001 | 對帳第 2 處,確認標籤正確(不動) |
| `declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]` | `src/Knot/Graph/NodeMint.hs:106` | graph-core/F003 | 同上 |
| `mintModuleId :: ModuleName -> Maybe FilePath -> NodeId` | `src/Knot/Graph/NodeMint.hs:39` | graph-core/F001 | M1 之後改由 extraction 契約取得 `ModuleName` 的呼叫點之一 |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | `src/Knot/Query/Load.hs:131` | export-query/F002 | 對帳第 3 處,確認標籤正確(不動) |
| `classifyRelation :: Text -> RelationClass` | `src/Knot/Query/Load.hs:79` | export-query/F002 | 同上 |
| `newtype NodeId = NodeId Text` | `src/Knot/Query/Types.hs:29` | export-query/F002 | M2 的升格標的(契約定義見 export-query `design.md` 查詢面) |
| `data QueryNode = QueryNode { qnId :: NodeId, qnLabel :: Text, qnFile :: FilePath }` | `src/Knot/Query/Types.hs:34-38` | export-query/F002 | M2 中維持非契約面的那一項 |

## 介面變動

### 新增

| 介面 | 位置 | 說明 |
|---|---|---|
| `ModuleName (..)`(re-export) | `src/Knot/Extract/Types.hs` 匯出清單 | 型別本體不變、不重複定義;僅讓 extraction 的契約模組能單獨滿足消費端的命名需求 |

### 修改

| 介面 | 變動 | 受影響呼叫端 |
|---|---|---|
| `Knot.Query.Types` 匯出清單分組 | `NodeId (..)` 由「非契約面」移入「對外契約」;`QueryGraph (..)` 加註欄位選擇器屬 Level 3;非契約面小節只剩 `QueryNode (..)` | **無**——匯出的符號集合一個都沒變,只有註解分組 |
| `Knot.Extract.Backend` 匯出清單分組 | 「後端名常數」小節補上非契約面標示 | **無**(同上) |
| `Knot.Graph.EdgeDerive` / `Knot.Graph.NodeMint` 的 import | `ModuleName` 改由 `Knot.Extract.Types` 取得 | **無**(module 內部 import,不影響匯出面) |

### 移除

無。

### 不變(明示)

所有 Level 2 契約條目與簽名、`knot-hs.cabal` 的雙 library 佈局與 9 個 `reexported-modules`、`Knot.Query` 對 `QueryGraph` 的抽象 re-export、`codegraph.json` 格式與 CLI 介面。

## TodoList

- [x] T1: `Knot.Extract.Types` 匯出清單新增「共用詞彙型別」小節 re-export `ModuleName (..)`,模組 haddock 補說明  `dep: -`
- [x] T2: `Knot.Graph.EdgeDerive` 與 `Knot.Graph.NodeMint` 改由 `Knot.Extract.Types` 取 `ModuleName`,刪掉各自的 `import Knot.Meta.Types`  `dep: T1`
- [x] T3: `Knot.Query.Types` 契約標籤修正(`NodeId (..)` 升入對外契約;`QueryGraph (..)` 加註欄位層級;非契約面小節收斂為 `QueryNode (..)`)  `dep: -`
- [x] T4: `Knot.Extract.Backend` 的「後端名常數」小節補上非契約面標示  `dep: -`
- [x] T5: 文檔同步——`ADR-005` 待辦欄措辭、`export-query/F002` 非契約面表的 `NodeId` 註記  `dep: T1, T3`
- [x] T6: 防退化——四處契約標籤的表格驅動對帳測試(含三處「本次確認正確」的鎖定)  `dep: T3, T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_extraction_reexports_module_name` | 從 `Knot.Extract.Types` **單獨** import `ModuleName (..)` 並建值後比對(能編譯即證明 re-export 成立);另讀 `src/Knot/Extract/Types.hs` 斷言匯出清單含 `ModuleName` |
| T2 | `test_graph_core_names_module_name_via_extraction` | 斷言 `src/Knot/Graph/EdgeDerive.hs` 與 `src/Knot/Graph/NodeMint.hs` 皆不含 `import Knot.Meta.Types`;並斷言 `Graph.hs` / `FactGate.hs` **仍含**(那兩處需 `ProjectMeta` / `SourceFile`,不得被順手刪掉) |
| T3 | `test_query_types_contract_labels` | 解析 `src/Knot/Query/Types.hs` 匯出清單的小節歸屬:`NodeId`、`QueryGraph` 落在「對外契約」組,`QueryNode` 落在「非契約面」組;另斷言 `src/Knot/Query.hs` 匯出的是**不帶 `(..)`** 的 `QueryGraph`(公開面不得變質) |
| T4 | `test_backend_constant_labels` | 斷言 `src/Knot/Extract/Backend.hs` 中 `importScanName` / `hiedbName` 所屬小節標題含「非契約面」字樣,且 `runBackends` 所屬小節同樣含該字樣(既有結論一併鎖住) |
| T5 | `test_docs_match_contract_labels` | 斷言 `ADR-005` 待辦欄不再宣稱「依附帶義務應補上 re-export」且提及 G-E004;`F002-graph-load.md` 的 `NodeId (..)` 列已註明升為契約面 |
| T6 | `test_contract_label_table` | 表格驅動:四處標籤位置 × 各自涵蓋的匯出符號 × 期望歸屬,逐一比對。涵蓋本次**不動**的 `Graph/NodeMint.hs` 與 `Query/Load.hs` 兩處,把 2026-08-22 的對帳結論鎖成回歸 |
| 全體 | `test_codegraph_output_unchanged`(既有) | 驗收標準 6:5 份黃金檔逐 byte 比對,確保本次純註解與 import 調整沒有改到任何行為 |

## 實作備註

### 量化結果(2026-08-22 實作完成)

| # | 驗收標準 | 前 | 後 | 怎麼驗的 |
|---|---|---|---|---|
| 1 | 標錯的契約標籤 | 2 | **0** | `NodeId (..)` 已在 `Knot.Query.Types` 的「對外契約」組;`QueryGraph (..)` 加註欄位選擇器屬 Level 3 |
| 2 | 未標示契約狀態的匯出小節 | 1 | **0** | `Extract/Backend.hs:10` 現為「後端名常數(非契約面:…)」 |
| 3 | 為命名 `ModuleName` 而 import `Knot.Meta.Types` 的檔案 | 2 | **0** | `grep -c "^import Knot.Meta.Types (ModuleName (\.\.))$" src/Knot/Graph*` 回 0 |
| 4 | 四處標籤的對帳結論可回測 | 無 | **27 列表格驅動** | `test_contract_label_table`,涵蓋四處檔案 × 27 個符號 |
| 5 | 公開面不變質 | — | **不變** | `reexported-modules` 仍 9 條;`src/Knot/Query.hs:20` 仍是不帶 `(..)` 的 `QueryGraph` |
| 6 | `codegraph.json` byte 級不變 | — | **不變** | `test_codegraph_output_unchanged` 5 份黃金檔全綠 |
| 7 | 建置閘門 | — | **exit 0、零警告** | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` |
| 8 | 測試 | 148 綠 | **154 綠** | 既有 148 條零退化 + 新增 6 條 |

**守門測試的有效性另做了變異驗證**:把 `Knot.Query.Types` 的「非契約面」小節標題
故意改成「內部使用」,`test_contract_label_table` 立刻 FAIL 並指名
`QueryNode should be 非契約面, but its section reads "內部使用"`;驗畢還原。沒有這一步,
「加了測試」只是宣稱。

**對帳結論的最終數字**:四處標籤共 27 個符號,錯 1(`NodeId`)、對 26;另有 1 處反向錯標
(`QueryGraph (..)` 的欄位選擇器)與 1 處未標示(後端名常數),皆已處理。三處「本次確認正確」
的標籤一字未改,由 T6 鎖成回歸。

### 與設計的偏差

1. **T5 多改了一處**:文檔只寫「`export-query/F002` 非契約面表的 `NodeId` 註記」,實作時
   同一文檔的「待確認假設 A1」段落也加了消解註記。理由:A1 的前提(「契約沒有定義
   `NodeId`」)正是標籤過期的根源,只改表格會讓假設段落單獨留著一個已不成立的前提。
   同一文檔、同一主題,未擴及其他檔案。
2. **測試輔助函式 `exportGroups` 的識別字判定不認 prime(`'`)**。本專案的匯出符號都不帶
   prime,故以英數 + 底線收斂;若日後出現 `foo'` 這類匯出會被截成 `foo`。屬實作自主權,
   但記在此以免日後誤判(函式內已有對應註解)。

### 未執行

專案沒有納管的 `codegraph.json`(knot 是自己的產生器,圖一向 ad-hoc 生成),故收尾的
「讓圖跟上」一步略過。需要時可跑 `knot extract . --db <專案外路徑>` 重生。

### S5 後續(2026-08-22,extraction/F007 two-layer-contract)

`Knot.Extract.Backend` 整個模組已隨 F007 刪除,本文檔對帳第 1 處與 M3 的標示標的搬家如下;結論(「具名常數是非契約面、`ewSource` 的值域才是契約」)不變:

| 原位置 | 新位置 | 標籤 |
|---|---|---|
| `Extract/Backend.hs` 的 `importScanName` | `src/Knot/Extract/ImportScan.hs`「站名常數(非契約面)」 | 非契約面 |
| `Extract/Backend.hs` 的 `hiedbName` | `src/Knot/Extract/HieIndex.hs`「站名常數(非契約面)」 | 非契約面 |
| `Extract/Backend.hs` 的 `runBackends`(調度引擎) | `src/Knot/Extract/Pipeline.hs` 的 `Stages` / `runPipeline`「可注入的四站(非契約面)」 | 非契約面 |
| `Backend` / `ProbeResult`(模組間公開介面) | 廢除;模組間公開介面改為 `scanImports` / `ensureHie` / `ensureIndex` / `readIndexFacts` | 契約面 |

`test_backend_constant_labels`(T4)由 extraction/F007 的 `test_pipeline_module_surface` 改寫承接;`contractLabelTable` 的「對帳 1」列同步改指上表的新位置(`test_contract_label_table` 仍鎖住全表)。
