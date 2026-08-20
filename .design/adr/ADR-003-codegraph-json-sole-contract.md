---
id: ADR-003
type: adr
title: codegraph-json-sole-contract
description: 對外唯一契約採 dev-flow 的 codegraph.json 格式
status: accepted
created: 2026-08-20
updated: 2026-08-20
---

# ADR-003: 對外唯一契約採 dev-flow 的 codegraph.json 格式

## 狀態(Status)

accepted

## 背景(Context)

下游消費者是 uto-skills / dev-flow 0.8.1 的 `arch-audit/scripts/scan-graph.mjs` 與 `_shared/codegraph.md` 所定義的七個 skill 接點。dev-flow 只認 `codegraph.json` 的格式,不認產生它的工具——knot-hs 刻意放在 uto-skills 之外,兩者只以此檔耦合。

## 決策(Decision)

`codegraph.json` 是 knot-hs 唯一的檔案輸出契約,規格遵守 dev-flow 定義:

- **必要欄位**:`nodes[].id` / `label` / `source_file`;`links[].source` / `target` / `relation`(source/target 是節點 id,不是索引)
- **選填欄位**:`source_location`(格式 `L<行>`,循環依賴證據行用)、`confidence`、頂層 `built_at_commit`、頂層 `directed`(缺省時下游當有向)
- **relation 兩類**:依賴類(`imports` `imports_from` `calls` `uses` `references` `extends` `implements` `inherits` `instantiates` `depends_on`)才算進依賴圖;結構類(`contains` `method` `defines`)不算
- `source_file` 一律 repo 相對路徑、正斜線(`code-paths` 前綴比對依據)
- **輸出位置**:目標專案根目錄 `codegraph.json`(下游搜尋順序的第一位,零設定接上)
- GHC 抽取的邊 `confidence` 一律 `EXTRACTED`(是事實不是推測)
- 這是**匯出格式,不是內部模型**:graph-core 的 IR 可攜帶型別、span 等額外資訊,匯出時投影;多餘欄位下游會忽略,可安全擴充

## 考慮過的替代方案(Alternatives Considered)

1. **自訂格式 + 轉換器**:多一層無人受益的間接;dev-flow 格式已滿足需求,內部 IR 已提供擴充空間
2. **直接輸出 hiedb 的 SQLite**:把未文件化的第三方 schema 變成對外契約,下游也讀不了

## 影響(Consequences)

- ✅ 零設定接上 dev-flow 七個 skill 接點
- ✅ 內部表示與匯出解耦,後端替換不影響下游
- ⚠️ dev-flow 若改格式,export-query 的投影層要跟進(耦合被限制在單一子系統)
