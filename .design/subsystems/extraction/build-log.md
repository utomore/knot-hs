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
| 階段一:S1 骨架 | W1 | fact-contract | impl-done |
| 階段一:S1 骨架 | W2 | import-scan | design-done |
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
| fact-contract | F001 | F001-fact-contract.md | opus(Fable 誤判中斷改派) | 繼承 | impl-done |
| import-scan | F002 | F002-import-scan.md | opus(預防 Fable 誤判) | 繼承 | design-done |
| hiedb-driver | F003 | F003-hiedb-driver.md | 繼承 | 繼承 | 本次不跑 |
| hiedb-facts | F004 | F004-hiedb-facts.md | 繼承 | 繼承 | 本次不跑 |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | 規則 1 落實位置 | backend-select 調度前窄化 pmSources,後端只見 included 檔 | 待裁決 |
| F001 A2 | BackendChoice → 後端辨識 | 以 bName 比對契約字串常數 import-scan/hiedb | 待裁決 |
| F001 A3 | 規則 8 排序手段 | Fact 及成員 DTO derive Ord,合成後全序排序 | 待裁決 |
| F001 A4 | 無後端成功時 erLevel | 取 ModuleLevel(能力下限),真相由 erReports 表達 | 待裁決 |
| F001 A5 | 未選中的後端是否進 erReports | 進,brUsed=False + 未選中原因 | 待裁決 |
| F001 A6 | 調度引擎需為測試匯出 | 比照 project-meta 慣例,haddock 註明非契約面 | 待裁決 |
| F001 A7 | 本階段註冊表空,extract 回空事實流 | 視為階段一預期語意,T7 測試釘住 | 待裁決 |
| F002 A1 | ExtractOptions/ProjectMeta 都不帶專案根目錄,後端開不了檔(sfPath 是 repo 相對) | 建議 ExtractOptions 增 rootDir;純核心 scanSource 不碰路徑 | 接受:ExtractOptions 增 rootDir(已回寫契約) |
| F002 A2 | fmModule 權威來源 | 以檔案 module 標頭為唯一權威,不與 sfModule 交叉比對 | 待裁決 |
| F002 A3 | 讀檔/解碼失敗的檔案 | 不產生 FactModule(規則 7 優先) | 待裁決 |
| F002 A4 | import 區邊界判定 | 第一個「第 0 欄、非空、非 import/module/CPP」的 token | 待裁決 |
| F002 A5 | 重複與自我 import | 照字面出事實,不去重 | 待裁決 |
| F002 A6 | 驗收方式 | 以 knot 手動唯讀實跑,app 層加 renderFactSummary | 待裁決 |
| F002 A7 | 去註解狀態機範圍 | 只追字串字面量與巢狀區塊註解,不追字元字面量 | 待裁決 |
| F001 A8 | 後端成功時 brDetail 該填什麼(契約只定義未用時的原因) | brUsed=True 時 brDetail="",使「非空 detail ⇔ 有降級原因」 | 待裁決 |

## 階段結果

### 階段一:S1 骨架

(待執行)
