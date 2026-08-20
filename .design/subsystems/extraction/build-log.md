---
id: extraction-build
type: build-log
title: extraction-build
description: 委派展開 extraction 階段一(fact-contract、import-scan)
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: extraction
---

# extraction 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | fact-contract | pending |
| 階段一:S1 骨架 | W2 | import-scan | pending |
| 階段二:S3 函式級 | W3 | hiedb-driver | 本次不跑 |
| 階段二:S3 函式級 | W4 | hiedb-facts | 本次不跑 |

開發者決定本次只跑階段一(主架構 S1 里程碑優先,S3 之後接續模式回來);無跨子系統未完成依賴(project-meta done)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | ExtractWarning 欄位形狀 | 比照 MetaWarning:{ ewSource, ewMessage },已回寫契約 | F001、後續全部 |
| D2 | ModuleName 型別來源 | 直接共用 Knot.Meta.Types 的定義,不重複定義,已回寫契約 | F001、F002 |
| D3 | 無 module 標頭的 .hs 檔 | 依 Haskell 語意視為 Main(fmFile 區分),已回寫契約 | F002 |
| D4 | 測試框架/命名空間/唯讀(沿 project-meta 展開的全域決定) | hedgehog+tasty;Knot.Extract.*;驗收標的絕對唯讀;版本號 0.0.1.0 凍結 | 全部 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| fact-contract | F001 | F001-fact-contract.md | 繼承 | 繼承 | pending |
| import-scan | F002 | F002-import-scan.md | 繼承 | 繼承 | pending |
| hiedb-driver | F003 | F003-hiedb-driver.md | 繼承 | 繼承 | 本次不跑 |
| hiedb-facts | F004 | F004-hiedb-facts.md | 繼承 | 繼承 | 本次不跑 |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|

## 階段結果

### 階段一:S1 骨架

(待執行)
