---
id: G-E007
type: enhance
title: test-layer
description: 測試碼以 component 標記進圖:節點帶 component、查詢加 --scope 與 tests-of,不再整塊拿掉或混入
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-008, ADR-003, ADR-005]
related-feature: [graph-core/F002, export-query/F001, export-query/F002, export-query/F003, export-query/F004, export-query/E001]
subsystems: [graph-core, export-query]
---

# G-E007: 測試層——以 component 標記進圖,`--scope` 與 `tests-of`

## 現況分析

knot 對測試碼只有兩種態度,兩種都不對:

1. **預設整塊拿掉**:project-meta 規則 1 把 test-suite / benchmark 標 `compExcluded`,
   extraction 不建、graph-core 不鑄節點。2026-08-23 的 story-flow 實測裡,「改 X 會壞哪些
   測試」是 knot 唯一答不了、grep 才能答的題(報告 Q6 / 用法一節第 7 點)
2. **`--include-tests` 整塊混入**:project-meta 把 test-suite 的 `compExcluded` 翻成 `False`,
   之後每一站都把測試 module 當一般節點。測試會 import 所有東西(story-flow 152 個測試檔 vs
   69 個產品檔),`rank` 的 hub、`reachable --reverse` 的波及面、`path` 全被灌水;
   `codegraph.json` 的節點沒有任何欄位能分辨它是不是測試
   (`src/Knot/Export/Encode.hs:94-99` 只出 `id` / `label` / `source_file` / `source_location`)

而分辨所需的資訊**一路都在**:project-meta 的 `SourceFile.sfOwners :: [ComponentRef]`
(`src/Knot/Meta/Types.hs`)知道每個檔屬於哪個 component,`ComponentMeta.compKind` 知道
它是 `TestSuite` 還是 `MainLibrary`;graph-core 的 `gateFacts :: ProjectMeta -> [Fact] -> GatedFacts`
(`src/Knot/Graph/FactGate.hs:49`)手上就有 `ProjectMeta`,只是 `GatedFacts` 三個欄位
(`:18-22`)沒把它往下傳,`mintNodes :: GatedFacts -> [GraphNode]`(`NodeMint.hs:135`)因此
鑄不出「這是哪個 component 的節點」。

測試與產品碼之間的**關係**不必發明:測試函數對產品函數的 `calls` / `uses` 就是 `.hie`
給的事實。缺的只有「哪些節點是測試」這一個 bit,以及查詢面尊重它。

## Scope(涵蓋範圍)

**動**:

- **graph-core**(Level 2 契約):`GraphNode` 新增 `gnComponent :: Maybe Text`——
  `<pkgName>:<compName>`(例 `comps:test:comps-test`、`knot-hs:lib:knot-internal`);
  `Nothing` = 檔案不屬於任何 component(無 `.cabal` 的專案、A5 退回的檔)。
  `GatedFacts` 新增 `gfOwners :: Map FilePath Text`(模組間介面,由 `gateFacts` 自 `pmSources`
  算出:每檔取 `sfOwners` 的**第一個**——project-meta 的序是 library → exe → flib → test →
  bench,所以同屬 exe 與 test-suite 的 `app/Main.hs` 標 exe,產品優先);node-mint 以 `gnFile`
  查表填 `gnComponent`
- **export-query 匯出面**(Level 2 契約 + ADR-008):`codegraph.json` 節點新增**選填**欄位
  `component`(`gnComponent` 有值才輸出),位置在 `source_file` 之後、`source_location` 之前
  (欄位序是 byte 決定性的一部分)。dev-flow 的 `scan-graph.mjs` 忽略未知欄位
- **export-query 查詢面**(Level 2 契約):
  - `QueryNode` 新增 `qnComponent :: Maybe Text`;graph-load 解析選填欄位
  - 新 DTO `data Scope = ScopeProduct | ScopeTests | ScopeAll`;節點屬 tests ⇔ `component`
    的 compName 以 `test:` 或 `bench:` 開頭;`Nothing` 與其他一律 product
  - 新模組間介面 `restrictScope :: Scope -> QueryGraph -> QueryGraph`(與 `restrictLevel`
    同一套誘導子圖機制,重構出共用的 `restrictNodes`)
  - `QueryCommand` 新增 `TestsOf NodeId`:自 ID **反向**可達、不限深度、**在 `ScopeAll` 的圖上**
    跑(不受 `--scope` 影響,否則永遠空),結果只留 tests 節點;`QueryResult` 新增
    `TestSet [(NodeId, Int)]`,`renderResult` 首行 `tests-of: <n> nodes`,明細同 `ReachableSet`
- **cli-assembly**:`knot query --scope product|tests|all`(預設 **`product`**,四子命令共用,
  與 `--graph` / `--level` 同層);新子命令 `knot query tests-of ID`;圖上沒有任何 tests 節點時
  `tests-of` 印一行提示到 stderr(`graph has no test components; rerun knot extract --include-tests`)
- `system.md`:對外 Output 的節點欄位加 `component`(選填);CLI 頂層契約加 `--scope` 與
  `tests-of`。README §輸出格式、§`knot query`
- 五份黃金 `codegraph.json`:**重產**——這是刻意的格式擴充(多一個選填欄位),不是演算法
  變動;重產前先 diff 確認只有 `component` 欄位新增、其餘 byte 不變,diff 摘要寫進實作備註

**明確不動**:

- project-meta、extraction:`--include-tests` 的語意不變(建且納入);預設不建 test-suite
  (建置成本與 MAX_PATH 風險是使用者的選擇)
- `codegraph.json` 的必要欄位、relation 名單(ADR-003)
- `scan-graph.mjs`(不在本專案);它靠 `code-paths` 分子系統,測試目錄本來就不在其內
- 「限制 / 要求 / 說明」這類自由文字**不進圖**:那是 dev-flow 文檔「1-to-1 測試對照表」
  的職責,圖只裝 GHC 說的事實(本文檔立案時與開發者的共識)
- 排除的「順便改」:dev-flow `scan-status` 以圖對帳測試對照表(表上有圖上沒有 = 測試沒寫)
  ——屬 dev-flow 側,另案;`--include-tests` 拆成「建」與「納入」兩段——另案

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| 「改 `TOn.Core.core` 會壞哪些測試」(`tests-on` fixture,`--include-tests`) | knot 答不了;grep 全文搜 | `knot query tests-of TOn.Core.core` → `TOn.Helper.helper`(1 跳)、`Main.main`(2 跳),全部 `component` 為 `tests-on:test:ton-test` |
| `--include-tests` 下 `rank` / `reachable` 被測試灌水 | 測試節點與產品節點不分 | 預設 `--scope product`:輸出與**不帶** `--include-tests` 抽取的圖逐字相同(同一 fixture 兩種抽取比對) |
| `codegraph.json` 節點 | 無 component 資訊 | 每個有 owner 的節點多 `component` 欄位;`scan-graph.mjs` 對五份黃金 fixture 的輸出不變 |
| 不帶旗標的既有查詢輸出 | — | 與改善前逐字相同(E001 T5 的常數測試不動) |
| 五份黃金檔 | byte 釘住 | 重產;diff 只有 `component` 欄位新增(實作備註附統計) |
| 測試 | 170 綠 | 170 + 本文檔新增 綠 |

## 相依性

`depends-on: []`。E001(`--level` / `restrictLevel`)已 done,本文檔重構其誘導子圖機制為
`restrictNodes` 並共用;與 extraction/E002 無關,可同批。

## 改善方案

### M1 graph-core:owner 表與 `gnComponent`

```haskell
data GatedFacts = GatedFacts { …, gfOwners :: Map FilePath Text }   -- 新增
-- gateFacts:gfOwners = Map.fromList [ (sfPath sf, label r) | sf <- pmSources pm, (r : _) <- [sfOwners sf] ]
--   label (ComponentRef (pkg, comp)) = pkg <> ":" <> comp
data GraphNode = GraphNode { …, gnComponent :: Maybe Text }          -- 新增
-- mintNodes:三種節點都以 gnFile 查 gfOwners
```

### M2 export-query 匯出面

`Encode.nodeObject`:`kv "source_file"` 之後插入 `componentField (gnComponent n)`
(`Nothing` → 整個鍵不存在,與 `source_location` 同作法)。黃金檔重產流程:先跑既有
`test_codegraph_output_unchanged` 取得新輸出、`diff` 舊檔確認只增 `component`、再覆蓋。

### M3 export-query 查詢面

```haskell
data Scope = ScopeProduct | ScopeTests | ScopeAll
data QueryNode = QueryNode { …, qnComponent :: Maybe Text }
restrictNodes :: (QueryNode -> Bool) -> QueryGraph -> QueryGraph   -- 內部,restrictLevel / restrictScope 共用
restrictScope :: Scope -> QueryGraph -> QueryGraph                 -- 模組間公開介面
isTestNode    :: QueryNode -> Bool                                 -- component 的 compName 以 test: / bench: 開頭
data QueryCommand = … | TestsOf NodeId
data QueryResult  = … | TestSet [(NodeId, Int)]
```

`runQuery g (TestsOf i)`:`reachableFrom g i Reverse Nothing` 後過濾 `isTestNode`;**呼叫端**
負責傳 `ScopeAll` 的圖(`Run.runQueryCmd` 對 `TestsOf` 跳過 `restrictScope`,仍套 `restrictLevel`)。

### M4 cli-assembly

`QueryCmd` 加 `qcScope :: Scope`;`--scope`(`scopeReader`);`tests-of` 子命令;
`runQueryCmd`:`g0 → restrictLevel → (TestsOf 時略過 restrictScope) → runQuery`;
`TestsOf` 且 `g0` 無任何 `isTestNode` → stderr 提示。

### M5 文件

system.md Output / CLI、README、ADR-008。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }`;`newtype ComponentRef = ComponentRef (Text, Text)` | `src/Knot/Meta/Types.hs` | project-meta/F002 | owner 表的來源 |
| `gateFacts :: ProjectMeta -> [Fact] -> GatedFacts`;`data GatedFacts = GatedFacts { gfFacts :: [Fact], gfInternal :: Set ModuleName, gfFiltered :: Int }` | `src/Knot/Graph/FactGate.hs:18-22, 49-54` | graph-core/F001 | M1 |
| `mintNodes :: GatedFacts -> [GraphNode]`;`data GraphNode = GraphNode { gnId :: NodeId, gnKind :: NodeKind, gnLabel :: Text, gnFile :: FilePath, gnLine :: Maybe Int }` | `src/Knot/Graph/NodeMint.hs:135`、`src/Knot/Graph/Types.hs:54-61` | graph-core/F001、F002 | M1 |
| `nodeObject :: GraphNode -> Builder`;`sourceLocation :: Maybe Int -> E.Series` | `src/Knot/Export/Encode.hs:94-99, 121-123` | export-query/F001 | M2 |
| `parseNode :: FilePath -> Int -> Value -> Either LoadError QueryNode`;`data QueryNode = QueryNode { qnId :: NodeId, qnLabel :: Text, qnFile :: FilePath }` | `src/Knot/Query/Load.hs:190-199`、`src/Knot/Query/Types.hs` | export-query/F002 | M3 |
| `restrictLevel :: Level -> QueryGraph -> QueryGraph`;`reachableFrom :: QueryGraph -> NodeId -> Direction -> Maybe Int -> [(NodeId, Int)]` | `src/Knot/Query/Load.hs`、`src/Knot/Query/Engine.hs` | export-query/E001 | M3 共用 |
| `queryParser`、`queryCommandParser`、`data QueryCmd = QueryCmd { qcFile, qcLevel, qcCommand }`;`runQueryCmd :: Handle -> Handle -> QueryCmd -> IO ExitCode`;`missingNodeLines` | `app/Knot/App/Cli.hs`、`app/Knot/App/Run.hs` | export-query/F004、E001 | M4 |

## 介面變動

| 變動 | 層級 | 受影響呼叫端 |
|---|---|---|
| `GraphNode` + `gnComponent :: Maybe Text` | graph-core Level 2 對外契約(DTO 加欄位) | node-mint(填)、Encode(讀)、測試中建構 `GraphNode` 的地方 |
| `GatedFacts` + `gfOwners :: Map FilePath Text` | graph-core 模組間介面 | fact-gate → node-mint |
| `codegraph.json` 節點選填欄位 `component` | **Level 1 對外 Output**(ADR-008) | 下游忽略;`knot query` 使用 |
| `QueryNode` + `qnComponent`;新 DTO `Scope`;`restrictScope` | export-query Level 2(DTO / 模組間介面) | cli-assembly |
| `QueryCommand` + `TestsOf NodeId`;`QueryResult` + `TestSet …` | export-query Level 2 對外契約(建構子新增,既有不動) | `runQuery` / `renderResult` / `missingNodeLines` 的 case 要補 |
| CLI `--scope`、`tests-of` | Level 1 CLI 契約 | 使用者 |

## TodoList

- [x] T1: graph-core——`gfOwners`、`gnComponent`;既有測試建構處補欄位  `dep: -`
- [x] T2: export-query 匯出——`component` 欄位;五份黃金檔 diff 確認後重產  `dep: T1`
- [x] T3: export-query 查詢——`qnComponent`、`Scope`、`restrictNodes` / `restrictScope`、`TestsOf` / `TestSet`、render  `dep: T2`
- [x] T4: cli-assembly——`--scope`、`tests-of`、`runQueryCmd` 接線與無測試提示  `dep: T3`
- [x] T5: 文件——system.md Output / CLI、README、ADR-008、兩份 design.md;`tests-on` fixture 端到端與灌水對照  `dep: T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e007_node_component` | `comps` fixture(`--include-tests`):`app/Main.hs` 的 module 節點 `gnComponent = Just "comps:exe:comps-exe"`(產品優先)、`test/Spec.hs` → `Just "comps:test:comps-test"`、`examples/Demo.hs`(無 owner)→ `Nothing`;decl 節點沿用所屬檔的 component;`no-cabal` fixture 全 `Nothing` |
| T2 | `test_e007_encode_component` + 既有 `test_codegraph_output_unchanged` | 手寫 `GraphNode` 有 / 無 component 的 JSON 逐字;欄位序 `source_file` → `component` → `source_location`;黃金檔重產後測試綠,且重產前 diff 只含 `component` 新增(統計寫入實作備註) |
| T3 | `test_e007_scope_and_tests_of` | 手寫 JSON(產品 2 節點、測試 2 節點、測試→產品 `calls`):`qnComponent` 解析;`restrictScope ScopeProduct` 只剩 2、`ScopeTests` 只剩 2、`ScopeAll` 恆等;`runQuery (TestsOf p)` 回兩個測試節點與跳數;`renderResult (TestSet …)` 首行 `tests-of: 2 nodes`;無 `component` 的圖全 product |
| T4 | `test_e007_scope_flags_parse` | `--scope tests rank`、`tests-of X`、預設 `ScopeProduct`、`--scope foo` 失敗;`runQueryCmd` 對無測試節點的圖跑 `tests-of` → stderr 含 `--include-tests` 提示、exit 0 |
| T5 | `test_e007_tests_on_end_to_end` + `test_e007_docs_mention_scope` | `tests-on` 暫存副本 `includeTests = True`:`tests-of TOn.Core.core` = `[TOn.Helper.helper (1), Main@test/Spec.hs.main (2)]`;`--scope product` 的 `rank` 輸出與 `includeTests = False` 抽取的圖逐字相同;system.md / README / 兩份 design.md 含 `--scope` 與 `tests-of` |

## 實作備註

### 2026-08-23 實作完成

**量化結果**(對照「改善目標」):

| 指標 | 改善前 | 改善後 |
|---|---|---|
| `tests-on` fixture `tests-of TOn.Core.core`(`--include-tests`) | 答不了 | `TOn.Helper`(1)、`TOn.Helper.helper`(1)、`Main`(2)、`Main.main`(2),全部 `component = tests-on:test:ton-test`;`--level decl` 下只剩兩個 decl 節點(T5) |
| 同 fixture `--scope product` 的 `rank` / `find` / `reachable` / `path` | 被測試灌水 | 與不帶 `includeTests` 抽取的圖**逐字相同**,節點集合相同(T5) |
| 五份黃金檔 | byte 釘住 | 重產:`comps.json` 4 行、`graph.json` 3 行、`multi.json` 2 行變動,`no-cabal.json` / `proj.json` 不變;逐行比對 9 條變動全部只差一段 `,"component":"…"` 插入(8 種值:`comps:lib:comps` / `lib:sub` / `exe:comps-exe` / `flib:comps-ffi`、`graph:lib:graph` ×2 / `exe:graph-exe`、`pkg-a:lib:pkg-a`、`pkg-b:exe:pkg-b-exe`) |
| 不帶旗標的既有查詢輸出 | — | E001 T5 常數測試照舊綠;既有 170 測試全綠 |
| knot-hs 自掃 `--include-tests` | 無法分辨測試 | 994 節點 / 5,884 邊:`lib:knot-internal` 531、`exe:knot` 69、`test:knot-test` 353、無 owner 41(`test/fixtures/**` 的 fixture 原始碼,A5 退回路徑,既有行為);預設 `--scope product` 的 module 層 `rank --top 5` 與 `--include-tests` 前相同,`--scope all` 則 `Main@test/Main.hs`(out=31)登頂 |
| knot-hs `tests-of` | — | `Knot.Query.Load.restrictLevel` → 16 個測試節點(4 個 1 跳:`testE001RestrictLevel`、`testE001DefaultOutputUnchanged`、`testE007ScopeAndTestsOf`、`testE007TestsOnEndToEnd`);`Knot.Graph.FactGate.gateFacts` → 55;`Knot.App.Run.prepareHandles --level decl` → 4。`reachable --reverse restrictLevel`:product 9 節點 vs all 25 |
| 建置成本 | — | 已建 `.knot` 上 `--include-tests` warm 2 s;切回預設(cabal 以 `--disable-tests` 重新設定)18 s |
| `scan-graph.mjs` | — | 對 `--include-tests` 的圖解析正常(994 / 5,884,commit `1508fcb`);未對映 `test/Main.hs`(353)屬預期——測試目錄不在任何 `code-paths` |
| 測試 | 170 綠 | 170 + 6 = 176 綠(`-Wall -Werror` 零警告) |

**與設計的偏差**:

1. 新增一個設計未列的 Level 2 查詢面介面 `queryGraphHasTests :: QueryGraph -> Bool`:組裝層要在 `tests-of` 回空時分辨「沒有測試依賴它」與「圖上根本沒建測試」,又不得讀 `QueryGraph` 內部欄位(與 `queryGraphHasNode` 同一個理由)。已回填 export-query `design.md` 查詢面簽名與規則 10
2. `tests-of` 在 `--level all`(預設)的圖上也會列出測試 **module** 節點(import 清單 / export 清單點名 decl 產生的 module → decl 邊,例如 `TOn.Helper` 的 `import TOn.Core (core)`);設計表只寫了 decl 節點。這是 `.hie` 的事實,不是誤判,保留;要純 decl 答案加 `--level decl`。`tests-on` 的 `Main` 無同名碰撞,id 是 `Main.main` 而非設計表假設的 `Main@test/Spec.hs.main`
3. 黃金檔重產走測試自身的更新模式(`KNOT_REGEN_GOLDEN=1` 時 `test_codegraph_output_unchanged` 改寫檔案而非比對),重產後以 `git diff` 逐行審視;不另寫產生腳本
4. 組裝層多一條提示 `query: node X is not in scope <s>`(節點在、在該層、但被 `--scope` 收斂掉),與 E001 的 `is not at level` 對稱;`tests-of` 與 `--scope all` 下恆不出現

**未動**(依 Scope):project-meta / extraction 一字未改;relation 名單不變;fixture 原始碼的 41 個無 owner 節點是既有的 A5 行為,另案(若要處理應在 project-meta 排除「巢狀 `.cabal` 專案」的目錄)。
