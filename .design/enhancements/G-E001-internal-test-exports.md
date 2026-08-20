---
id: G-E001
type: enhance
title: internal-test-exports
description: 內部邊界收斂:跨子系統的測試用匯出與重複演算法
status: open
created: 2026-08-20
updated: 2026-08-21
depends-on: []
related-adr: []
related-feature: []
subsystems: [project-meta, extraction, export-query]
---

# G-E001: 僅為測試而公開的內部函數移入 internal library

## 發現依據(2026-08-20 arch-audit subsys project-meta)

`Knot.Meta.SourceIndex` 額外匯出 `moduleNameFromPath`,註明「僅為 1-to-1 測試而匯出,非 Level 2 契約面」。功能正確、註解清楚,但內部純函數出現在 library 公開面,屬可收斂的邊界洩漏。

## 方向(細節待 /enhance-design 展開)

改用 cabal internal library(或 test-suite 直接以 hs-source-dirs 共用 src)讓測試觸及內部函數,`Knot.Meta.SourceIndex` 公開面收斂回契約定義的 `indexSources`。後續 feature 若出現同型需求(僅測試用匯出),一併納入同一機制。

## 範圍擴充(2026-08-20 階段二閘門)

- `Knot.Meta.HieLocate.moduleNameFromHiePath` 同為測試用匯出,納入收斂範圍
- 大寫尾綴演算法在 SourceIndex(`.hs`)與 HieLocate(`.hie`)重複實作,收斂時一併去重
- `Knot.Meta.Discovery`:cabal.project 列出的目錄存在但無 `.cabal` 時靜默貢獻零,補 per-entry 警告

## 範圍擴充(2026-08-20 extraction 階段一閘門:改為全域)

測試用匯出已橫跨兩個子系統,故由 project-meta 的 E001 升為全域 G-E001:

- **project-meta**:`Knot.Meta.SourceIndex.moduleNameFromPath`、`Knot.Meta.HieLocate.moduleNameFromHiePath`(兩者演算法幾乎相同,僅副檔名不同)
- **extraction**:`Knot.Extract.Backend.runBackends`、`Knot.Extract.ImportScan` 的 `scanSource` / `stripCommentLines` / `headerModuleOf` / `importsOf`
- 收斂手段(cabal internal library 或 test-suite 共用 hs-source-dirs)一次決定、兩個子系統一起套用;graph-core / export-query 之後出現同型需求時併入本文檔

## 範圍擴充(2026-08-21 export-query 階段一閘門)

export-query 的 F001 json-export 產生第三批同型匯出,依本文檔既有的「graph-core / export-query 之後出現同型需求時併入」納入:

- **export-query**:`Knot.Export.Encode` 的 `relationText`(**目前只有測試在用**,最純粹的同型案例)、`encodeCodegraph`、`statsNotes`;`Knot.Export.Types` 的 `defaultOutputPath`
- 這批與前兩批的**性質不同**,收斂手段要分開判斷:
  - `relationText` 是純粹的測試用匯出,與 project-meta / extraction 那兩批同類
  - `encodeCodegraph` / `statsNotes` 是 `Knot.Export` 跨 Haskell 模組呼叫的必要匯出,**Haskell 無法只對同 package 的兄弟模組開放**;要收斂只能靠 internal library 把 `Knot.Export.*` 整組移進去,只對外露 `Knot.Export`
  - `defaultOutputPath` 由 executable(F004 cli-wiring)消費,不是測試用;若採 internal library 方案,它得留在對外露的那一層,或升格進 Level 2 契約
- 因此本文檔的收斂方案在展開時要能同時處理三種情境:純測試用、跨內部模組必要匯出、executable 專用。**internal library 方案對三者都成立**(test-suite 與 executable 都能 depend 內部 lib),`hs-source-dirs` 共用方案只解得了第一種——這是選型的關鍵差異
