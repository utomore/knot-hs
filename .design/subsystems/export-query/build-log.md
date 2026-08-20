---
id: export-query-build
type: build-log
title: export-query-build
description: 委派展開 export-query 全子系統(匯出、查詢、CLI 組裝)
status: in-progress
created: 2026-08-21
updated: 2026-08-21
parent: export-query
---

# export-query 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | json-export | pending |
| 階段二:S4 查詢 CLI | W2 | graph-load | pending |
| 階段二:S4 查詢 CLI | W3 | query-commands | pending |
| 階段二:S4 查詢 CLI | W4 | cli-wiring | pending |

開發者決定本次一路跑完整個子系統(階段一 + 階段二)。跨子系統依賴 project-meta、extraction、graph-core 的階段一皆 done 並已 merge 進 main(PR #1、#2,commit 1ea5f27),無等待項。專案尚無 `codegraph.json`,略過 codegraph 對帳。

波次全為單 feature 序列:#1 → #2 → #3 → #4 的依賴鏈無可平行處。cli-wiring 為本次新增的第 4 個 feature(見 D3)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 這次跑到第幾階段 | 一路跑完階段一 + 階段二(整個子系統) | 全部 |
| D2 | CLI 接線範圍 | 完整:引入 optparse-applicative 排 `extract` + `query` 全部旗標 | F004 |
| D3 | 完整 CLI 掛在哪(三張契約卡都寫「不解析 CLI 參數」) | 全部集中到階段二末的新 feature F004 cli-wiring;已補契約卡與功能規劃第 4 列。**代價已告知並確認**:階段一閘門沒有 CLI 入口,MagicFarmer / particle-magic 實跑順延到 F004 | F001、F004 |
| D4 | `codegraph.json` 排版格式 | 半 pretty:`nodes` / `links` 每個物件壓成單行、彼此換行(git diff 友善,MagicFarmer 規模約 300 行) | F001 |
| D5 | scan-graph.mjs 驗收怎麼跑 | 不在 Haskell 測試裡 shell out node(CI 脆弱);由測試直接呼叫 `writeCodegraph` 寫出真檔,編排者在閘門前手動跑一次 `scan-graph.mjs` 對帳 | F001、F004 |
| D6 | 版本號 | 維持 `0.0.1.0` 不動(沿用 graph-core D6 的凍結決定);全部子系統完成後再定版 | 全部 |
| D7 | git 收尾 | 一個 PR 收整個子系統(分支 `feat/export-query-stage1`);過程中仍逐 feature 留 checkpoint commit | 全部 |
| D8 | 沿用的全域決定 | hedgehog + tasty;命名空間 `Knot.*`;兩個驗收標的絕對唯讀;`-Wall` 零警告;library 全程不印任何輸出(列印一律在 executable 層) | 全部 |
| D9 | 工具鏈 spike(2026-08-21 實測,GHC 9.14.1 / base 4.22) | aeson **2.3.1.0** 與 optparse-applicative **0.19.0.0** 皆解析並編譯成功;`Data.Aeson.Encoding` 可顯式控制欄位順序、`hsubparser` 可用。已回寫 design.md「使用的技術」 | F001、F004 |

### 契約類決定(已回寫 design.md,此處僅索引)

| # | 問題 | 決定 | 回寫位置 |
|---|------|------|---------|
| C1 | `AutoDetect` 要在哪個目錄跑 `git rev-parse`(`ExportOptions` 只有 `outputPath`,`--output` 可改道) | `ExportOptions` 增 `rootDir :: FilePath`(比照 extraction A1 給 `ExtractOptions` 加 `rootDir` 的前例) | 對外契約 › 匯出面 |
| C2 | 未知 relation 的「彙整列印」從哪條通道出來(`loadQueryGraph` 無回報欄位,library 不印) | 契約新增 `queryGraphNotes :: QueryGraph -> [(Text, Int)]`,CLI 層取來印 stderr | 對外契約 › 查詢面 |
| C3 | `LoadError` 形狀 | 三建構子各帶說明 `Text`:`LoadFileMissing` / `LoadParseError` / `LoadSchemaError` | 對外契約 › 查詢面 |
| C4 | `Reachable` 是否含起點 | 不含,只回距離 ≥ 1;起點在環上時以真實距離出現 | 查詢規則 5 |
| C5 | `ShortestPath` 多條等長路徑時的決定性 | 取字典序最小路徑(BFS 鄰居依 id 排序、前驅取最早抵達者);`PathResult` 型別不動 | 查詢規則 6 |
| C6 | 既有三個唯讀驗收輸出(預設 meta 摘要、`--facts`、`--graph`)的去留 | 收進 `knot extract --summary meta|facts|graph`;不給 `--summary` 時 `extract` 預設寫 `codegraph.json` | cli-wiring 契約卡 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| json-export | F001 | F001-json-export.md | 繼承 | 繼承 | pending |
| graph-load | F002 | F002-graph-load.md | 繼承 | 繼承 | pending |
| query-commands | F003 | F003-query-commands.md | 繼承 | 繼承 | pending |
| cli-wiring | F004 | F004-cli-wiring.md | 繼承 | 繼承 | pending |

四個 feature 全部不降級:F001 的決定性序列化與 F004 的跨四子系統組裝都不是樣板工作;F002 / F003 雖然單一入口,但它們是 F004 的前置,設計錯會沿依賴鏈複利。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| — | (待各 feature 回報後填入) | — | — |

## 階段結果

### 階段一:S1 骨架

(待執行)

### 階段二:S4 查詢 CLI

(待執行)
