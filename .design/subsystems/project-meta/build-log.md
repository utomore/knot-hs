---
id: project-meta-build
type: build-log
title: project-meta-build
description: 委派展開 project-meta 全部兩階段三個 features
status: in-progress
created: 2026-08-20
updated: 2026-08-20
parent: project-meta
---

# project-meta 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | scan-baseline | impl-done |
| 階段二:S2 .cabal 整合 | W2 | cabal-components, hie-discovery | pending |

無跨子系統依賴;開發者決定兩階段連貫跑完(各階段閘門照停)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 專案骨架(knot-hs.cabal、src/、test/、最小執行入口)由誰建 | 附帶在 F001:library + 最小 knot 執行檔(先只印 ProjectMeta 摘要供驗收)+ test-suite;完整 CLI 參數解析不在本階段 | F001 |
| D2 | 測試框架 | hedgehog(+tasty);在 GHC 9.14 若需 allow-newer 由執行者實測後寫進 cabal.project 並記入待確認假設;編不過 fallback tasty+HUnit | 全部 features |
| D3 | module 命名空間 | Knot.<子系統>.*:Knot.Meta(project-meta)、Knot.Extract、Knot.Graph、Knot.Export/Knot.Query;共用 DTO 放契約所屬子系統 | 全部 features(跨子系統約定) |
| D4 | 檔案樹掃描的略過清單(契約寫「dist-newstyle、.git 等」) | 隱藏目錄(.開頭)、dist-newstyle、.stack-work 一律略過 | F001 |
| D5 | 驗收標的唯讀 | MagicFarmer 與 particle-magic 絕不寫入(.knot/ 例外屬 extraction,本子系統無);測試 fixture 一律建在 knot-hs 自己的 test 資源或暫存目錄 | 全部 features |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| scan-baseline | F001 | F001-scan-baseline.md | 繼承 | 繼承 | impl-done |
| cabal-components | F002 | F002-cabal-components.md | 繼承 | 繼承 | pending |
| hie-discovery | F003 | F003-hie-discovery.md | 繼承 | 繼承 | pending |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | ModuleName 未在 Level 2 定義 | newtype ModuleName = ModuleName Text(點分形式) | 接受,已回寫契約 |
| F001 A2 | MetaWarning 具體欄位未定 | { mwPath, mwMessage } | 接受,已回寫契約 |
| F001 A3 | 契約卡「回報 .cabal 路徑」S1 無 DTO 欄位 | S1 僅在找不到 .cabal 時出警告,路徑不進 DTO | 接受 |
| F001 A4 | 原始碼副檔名範圍 | 只收 .hs,不含 .lhs | 接受 |
| F001 A5 | 階段二 DTO 需先存在使型別完整 | 照 design.md 原文先行定義(零邏輯) | 接受 |
| F001 A6 | 最小執行入口的參數範圍 | 手寫 getArgs 支援 PATH 與 --include-tests | 接受 |
| F001 A7 | cabal 版本號未被指定 | 暫定 0.1.0.0(版本號依全域指示須由使用者裁定) | 裁定 0.0.1.0,已改 |

## 階段結果

### 階段一:S1 骨架

- F001 scan-baseline:design + impl 完成;Todo 9/9;測試 10 通過 0 失敗(hedgehog+tasty 實編實跑,未觸發 fallback);MagicFarmer(115 .hs)與 particle-magic(193 .hs)唯讀驗收全過,兩次輸出決定性一致
- arch-audit subsys:資料流管線、SRP、模組介面簽名、DTO 欄位全部與 design.md 一致;3 條低嚴重度發現(moduleNameFromPath 測試用匯出、契約卡驗收例引用不存在的檔案、A1/A2 定義待回寫契約)
- 編排者修正:骨架缺 .gitignore 導致 dist-newstyle 一度入版控,已補(根目錄錨定)並 amend checkpoint
- 閘門裁決:A1–A6 接受(A1/A2 已回寫契約)、A7 版本裁定 0.0.1.0、測試匯出記 E001、契約卡驗收例改實存檔;修正完成後再議進階段二

### 階段二:S2 .cabal 整合

(待執行)
