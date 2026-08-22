---
id: E001
type: enhance
title: component-module-list-ownership
description: component 歸屬只看目錄前綴,hs-source-dirs 為 . 時認領整個 repo
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: []
related-feature: [F002]
---

# E001: component 歸屬改看 module 清單,不只看目錄前綴

## 現況分析

`src/Knot/Meta/SourceIndex.hs:41-44` 的 `ownerIndex` 用
`(ComponentRef, ComponentKind, hs-source-dirs 的段序列)` 建索引,
`:53` 的 `dirPrefixOf` 純以**目錄前綴**判斷某個 `.hs` 屬於哪個 component:

```haskell
  dirSegs d = case splitDirectories d of
    ["."] -> []              -- "." 視為根(恆命中)
    segs  -> segs
```

`["."] -> []` 這一行是關鍵:空段序列是任何路徑的前綴,所以
**`hs-source-dirs` 取預設值 `.` 的 component 會命中 repo 內每一個 `.hs`**。

Cabal 的 `hs-source-dirs` 預設值正是 `.`,所以只要目標專案的某個 component 省略
這一欄(很常見,尤其是根目錄擺 library 的小專案),knot 就會把 fixture、範例碼、
腳本全部判給它。再加上判定規則 2「只要任一 owner 未排除即 `sfIncluded = True`」,
test-suite 的排除也抵銷不掉。

**實測**(2026-08-22,G-E001 期間):knot-hs 自己的公開 `library` 一度沒寫
`hs-source-dirs`,自掃節點數從 548 跳到 **575**、警告 0 → 8,多出來的全是
`test/fixtures/**` 的檔案。當時的處置是在 knot-hs 的 `.cabal` 明寫
`hs-source-dirs: src`——那只治得了自己,治不了別人的專案。

### 真正的成因不是「`.` 這個值」

Cabal 的 component 實際包含哪些 module,是由 `exposed-modules` /
`other-modules` / `main-is` **明文列出**的;`hs-source-dirs` 只是「去哪些目錄找
這些 module」。knot 完全沒讀那三個欄位,只用目錄前綴近似:

- `hs-source-dirs: src` → 近似得還行(該目錄下多半就是它的 module)
- `hs-source-dirs: .` → 近似退化成「全部」

`src/Knot/Meta/Types.hs` 的 `ComponentMeta` 目前只有
`compName` / `compKind` / `compSourceDirs` / `compExcluded`,**沒有 module 清單**。

## Scope(尚未與開發者討論)

**本文檔只做記錄,scope 未定案。** 動手前需要討論的至少有:

- `ComponentMeta` 加 module 清單欄位 → **project-meta 的 Level 2 契約變更**
- 判定規則 2、3(歸屬與 module 對映)要不要跟著改寫 → 契約變更
- 對既有輸出的影響:每個被掃專案的 `sfOwners` / `sfIncluded` 都可能變,
  五份黃金檔與兩個驗收標的的節點數都會動 → 不是行為中性的優化
- `main-is` 指到的檔案沒有 module 名(`Main` 由 Haskell 語意推得),
  對映規則要另外處理

## 改善方向(候選,未定案)

- **A**:`ComponentMeta` 增列 `compModules :: [ModuleName]`,歸屬判定改為
  「目錄前綴命中 **且** module 名在清單內」。最忠實,但契約變更最大
- **B**:只對 `hs-source-dirs` 退化為 `.` 的 component 套用 A 的嚴格判定,
  其餘維持前綴近似。改動面小,但規則變得不一致
- **C**:維持現狀,改在文件警告使用者為目標專案的 `.cabal` 明寫
  `hs-source-dirs`(README 已如此記載)。零程式碼變更,但治標

## TodoList

- [ ] T1: 走 `/enhance-design` 與開發者確認 scope 與方向  `dep: -`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | — | 本文檔僅記錄,實作前先走 `/enhance-design` 補完 scope、介面表與測試對照 |

## 實作備註

(尚未開工。2026-08-22 由 G-E001 的範圍外發現立案;G-B002 修復期間確認它與
`.hie` 的兩個缺陷無關,是獨立的歸屬判定問題。)
