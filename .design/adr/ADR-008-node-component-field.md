---
id: ADR-008
type: adr
title: node-component-field
description: codegraph.json 節點新增選填 component 欄位,測試碼以此進圖而不混入
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-008: `codegraph.json` 節點的選填 `component` 欄位

## 狀態(Status)

accepted(2026-08-23)。落地:G-E007。

## 背景(Context)

ADR-003 把 dev-flow 的 `codegraph.json` 定為唯一對外契約:節點必要欄位 `id` / `label` /
`source_file`、選填 `source_location`;多餘欄位下游「可安全擴充」(`scan-graph.mjs` 與
knot 自己的 graph-load 都忽略未知鍵)。

測試碼在這個格式裡沒有位置:knot 預設不建 test-suite(圖上沒有測試),`--include-tests`
時測試 module 與產品 module 長得一模一樣(圖上分不出測試)。2026-08-23 story-flow 實測:
「改 X 會壞哪些測試」是 knot 答不了的題;而一旦 `--include-tests`,152 個測試檔把 hub 排名與
波及面全部灌水。

開發者的立場:測試是專案的一部分,導航工具不該捨棄它;但「限制 / 要求 / 說明」這類自由
文字不該進圖——那是 dev-flow 文檔(1-to-1 測試對照表)的職責,圖只裝 GHC 說的事實。

## 決策(Decision)

### 1. 節點新增選填欄位 `component`

值為 `<pkgName>:<compName>`,`compName` 帶 cabal target 前綴(project-meta 的 A3:`lib:` /
`exe:` / `flib:` / `test:` / `bench:`),例 `knot-hs:lib:knot-internal`、`comps:test:comps-test`。
檔案不屬於任何 component(無 `.cabal`、A5 退回)時**不輸出**此鍵。同一檔有多個 owner 時取
project-meta 順序的第一個(library → exe → flib → test → bench):產品優先。

```json
{"id":"Main","label":"Main","source_file":"app/Main.hs","component":"comps:exe:comps-exe","source_location":"L3"}
```

欄位序 `id` → `label` → `source_file` → `component` → `source_location`,是 byte 決定性的一部分。

### 2. 測試與產品的關係不另立 relation

測試函數對產品函數的 `calls` / `uses` 已由 `.hie` 給出,是事實;本 ADR 只加「這個節點屬於
哪個 component」這一個 bit。**不**新增 `tests` 之類的 relation,**不**在圖上放任何自由文字。

### 3. 查詢面尊重它

`knot query --scope product|tests|all`(預設 `product`),`tests-of <id>` 回答「哪些測試
(直接或間接)用到它」。tests 的判準:`component` 的 compName 以 `test:` 或 `bench:` 開頭。

### 4. 建置成本仍由使用者決定

`--include-tests` 語意不變(建且納入);預設不建。沒有測試節點的圖上 `tests-of` 給提示,
不猜。

## 考慮過的替代方案(Alternatives Considered)

1. **另出一份 `codegraph.tests.json`**:下游要認識第二個檔,`path` / `reachable` 跨檔不成立。
   否決
2. **新增 relation `tests`(測試節點 → 被測節點)**:與 `calls` 重複、且是「推論」不是事實
   (測試 `calls` 了 X 不等於「測 X」);dev-flow 會把未知 relation 列印排除、每次都吵。否決
3. **以 `source_file` 路徑猜**(`test/` 開頭即測試):story-flow 的 `tests: True`、跨目錄
   test-suite(particle-magic 的 `hs-source-dirs: test, app, src/ffi, tools`)都會猜錯;
   project-meta 早就算對了,不該再猜。否決
4. **把「限制 / 要求 / 說明」塞進節點欄位**:變成第二份文件,會漂移、無人維護;
   dev-flow 文檔的測試對照表才是它的家,測試函數名是外鍵。否決(開發者同意)

## 影響(Consequences)

- 五份黃金 `codegraph.json` 重產(只多 `component` 欄位);G-E001 的「byte 不變」守門在
  重產後繼續成立
- graph-core 的 `GraphNode` 與 export-query 的 `QueryNode` 各多一個 `Maybe Text` 欄位;
  `QueryCommand` / `QueryResult` 各多一個建構子
- dev-flow 側未來可以用此欄位做「測試對照表 ↔ 圖」的對帳(表上有、圖上沒有 = 測試沒寫),
  另案

## 相關

- ADR-003(唯一契約格式)、ADR-005(詞彙型別邊界:`component` 是 `Text`,不是上游 DTO)
- G-E007、project-meta/F002(`sfOwners`、A3 前綴)、export-query/E001(誘導子圖機制)
