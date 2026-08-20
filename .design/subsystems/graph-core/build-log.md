---
id: graph-core-build
type: build-log
title: graph-core-build
description: 委派展開 graph-core 階段一(module-graph)
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: graph-core
---

# graph-core 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | module-graph | design-done |
| 階段二:S3 decl 層 | W2 | decl-nodes | 本次不跑 |
| 階段二:S3 decl 層 | W3 | decl-edges | 本次不跑 |

開發者決定本次只跑階段一(主架構 S1 端到端優先);跨子系統依賴 project-meta、extraction 階段一皆 done 並已 merge 進 main(PR #1,commit 76cf838)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 同名 module 碰撞(多個 executable 的 Main、extraction D3 讓無標頭檔皆為 Main) | 改鑄造規則:同名整組改用 `<module>@<source_file>`,碰撞事實進 GraphWarning;已回寫契約 | F001,及階段二 decl 層 |
| D2 | 內部 module 集合的來源 | 以事實流的 FactModule.fmModule 為準(非 pmSources.sfModule);已回寫契約 | F001 |
| D3 | GraphWarning 形狀 | `{ gwSource :: Text, gwMessage :: Text }`,比照 MetaWarning / ExtractWarning;已回寫契約 | F001 |
| D4 | gsTopExternalTargets 的 N 與排序 | 取前 10,次數降序、同次數依 module 名字典序;已回寫契約 | F001 |
| D5 | 排序鍵 | cgNodes 依 NodeId 字典序;cgEdges 依 (source, relation, target) 字典序;已回寫契約 | F001 |
| D6 | 沿用的全域決定 | hedgehog+tasty;命名空間 `Knot.Graph.*`;驗收標的絕對唯讀;版本號 0.0.1.0 凍結;收尾以 PR 整合 | 全部 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| module-graph | F001 | F001-module-graph.md | opus(預防 Fable 誤判) | 繼承 | design-done |
| decl-nodes | F002 | F002-decl-nodes.md | 繼承 | 繼承 | 本次不跑 |
| decl-edges | F003 | F003-decl-edges.md | 繼承 | 繼承 | 本次不跑 |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | NodeId 唯一構造入口在 Haskell 無法不新增模組地強制(會成 import 環) | Types 匯出 NodeId(..) + haddock 紀律;edge-derive 一律從 gnId 取值不鑄 id | 待裁決 |
| F001 A2 | mintModuleId 簽名早於 D1 寫定,缺 file 參數無法鑄 <module>@<file> | 契約簽名不動,另加非契約面 mintModuleIdAt | 接受:改契約簽名(已回寫) |
| F001 A3 | deriveEdges/EdgeStats 無警告通道,但解析失敗不得靜默 | 契約函式不動,另加非契約面 deriveEdgesWithWarnings | 接受:改回三元組(已回寫) |
| F001 A4 | import 目標落在同名消歧組時無從判定指向哪個節點 | 丟棄該邊 + 警告,不計入 gsDroppedExternal | 待裁決 |
| F001 A5 | 消歧節點的 gnLabel | 維持裸 module 名,消歧只在 gnId/gnFile | 待裁決 |
| F001 A6 | 規則 3 不在本卡範圍但 gfFiltered/gsFilteredGenerated 欄位屬本卡 | 欄位齊備恆 0,規則 3 留階段二 | 待裁決 |
| F001 A7 | cgWarnings 的排序與去重未定義,但規則 7 要求決定性 | 依 (gwSource, gwMessage) 去重並字典序輸出 | 待裁決 |
| F001 A8 | 契約卡「不印任何輸出」vs 兩標的實跑驗收 | library 不印;app 層加 renderGraphSummary + --graph | 待裁決 |

## 階段結果

### 階段一:S1 骨架

(待執行)
