---
id: E001
type: enhance
title: internal-test-exports
description: 內部邊界收斂:測試用匯出、尾綴演算法去重與 per-entry 警告
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: []
related-adr: []
related-feature: [F001]
---

# E001: 僅為測試而公開的內部函數移入 internal library

## 發現依據(2026-08-20 arch-audit subsys project-meta)

`Knot.Meta.SourceIndex` 額外匯出 `moduleNameFromPath`,註明「僅為 1-to-1 測試而匯出,非 Level 2 契約面」。功能正確、註解清楚,但內部純函數出現在 library 公開面,屬可收斂的邊界洩漏。

## 方向(細節待 /enhance-design 展開)

改用 cabal internal library(或 test-suite 直接以 hs-source-dirs 共用 src)讓測試觸及內部函數,`Knot.Meta.SourceIndex` 公開面收斂回契約定義的 `indexSources`。後續 feature 若出現同型需求(僅測試用匯出),一併納入同一機制。

## 範圍擴充(2026-08-20 階段二閘門)

- `Knot.Meta.HieLocate.moduleNameFromHiePath` 同為測試用匯出,納入收斂範圍
- 大寫尾綴演算法在 SourceIndex(`.hs`)與 HieLocate(`.hie`)重複實作,收斂時一併去重
- `Knot.Meta.Discovery`:cabal.project 列出的目錄存在但無 `.cabal` 時靜默貢獻零,補 per-entry 警告
