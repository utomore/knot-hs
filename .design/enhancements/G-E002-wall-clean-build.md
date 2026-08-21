---
id: G-E002
type: enhance
title: wall-clean-build
description: 讓 -Wall 零警告真正成立,並補上會退化的偵測手段
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: []
related-feature: [extraction/F002, extraction/F003]
subsystems: [extraction]
---

# G-E002: `-Wall` 零警告的落實與防退化

## 發現依據(2026-08-22 extraction 階段二閘門)

專案的全域慣例 D8 明訂 **`-Wall` 零警告**,而且在 project-meta、extraction 階段一、graph-core、export-query 四次閘門都被宣告「達成」。**實際上從未成立。**

`cabal clean` 後全量重建的真實結果是 **9 筆警告**:

| 位置 | 警告 | 來源 |
|---|---|---|
| `test/Main.hs:1304`(×2)、`1306`、`1307`、`1308` | `[GHC-17335] -Wincomplete-record-selectors` | extraction/F002 的 import-scan 測試 |
| `test/Main.hs:1431`(×2)、`1433` | 同上 | extraction/F002 的 property 測試 |
| `src/Knot/Extract/HiedbDriver.hs:160` | `[GHC-63394] -Wx-partial` | extraction/F003(**已於本次閘門修掉**) |

## 為什麼一直沒被發現(這是本文檔的重點)

**增量建置不會重印警告。** GHC 只在真的重編某個模組時才發警告,而每次閘門跑的都是增量建置——只要 `test/Main.hs` 那一段沒被改到,那 8 筆就不會出現在輸出裡。

更糟的是,想「強制重編」的直覺做法**行不通且會給出假答案**:

```
cabal build all --enable-tests --ghc-options=-fforce-recomp
→ Up to date          # cabal 自己的 up-to-date 檢查先短路,GHC 根本沒被呼叫
```

輸出是 `Up to date`、警告數是 0,看起來像「乾淨」。`touch` 原始檔也無效(cabal 用內容雜湊而非 mtime)。**唯一問得出真話的做法是 `cabal clean` 後重建。**

## 兩類警告的性質

### 1. `-Wincomplete-record-selectors`(8 筆,全在測試碼)

`Fact` 是 sum type,`fiLine` / `fiTo` / `fiFrom` / `fiFile` / `fmModule` 都是**部分選擇器**。測試碼直接對它們取值:

```haskell
map (\i -> (fiLine i, fiTo i)) imps                       -- L1304
[(fiLine f, fiTo f) | f@FactImport{} <- facts]            -- L1431
```

第二種寫法**其實是安全的**(list comprehension 的 pattern 已經篩掉別的建構子),只是 GHC 追蹤不到那層保證。第一種依賴呼叫端已知 `imps` 全是 `FactImport`。

**測試本身是好的**,只是寫法觸發了 GHC 9.10 起才加進 `-Wall` 的新警告。收斂手段候選:對每個元素改用顯式 `case` / pattern match、或為 `Fact` 提供全函式的取值輔助。

### 2. `-Wx-partial`(1 筆,已修)

`HiedbDriver.hs:160` 的 `head (hieFiles hie)`,前一個 guard 有 `null` 保護所以執行期安全,但型別層面仍是部分函式。**已於 2026-08-22 階段二閘門換成全函式寫法。**

## 方向(細節待 `/enhance-design` 展開)

1. **消除 8 筆 `-Wincomplete-record-selectors`**,手段一次決定並套用到全部呼叫點
2. **訂正 D8 的描述**:在慣例被真正落實之前,寫著「零警告」而實際有 9 筆,比沒有慣例更糟——它讓四次閘門都做出了錯誤的健康度宣告
3. **補上防退化手段**(本文檔的長期價值所在)。候選:
   - 閘門的驗收指令改為 `cabal clean && cabal build all --enable-tests`,並把「不可用 `--ghc-options=-fforce-recomp` 代替」寫進慣例
   - 或改用 `-Werror`(CI 層),讓退化無法悄悄合入
   - 前者成本低但依賴人記得,後者一勞永逸但要先把 9 筆清乾淨

## 影響範圍

只碰 `extraction` 的測試碼與已修的 `HiedbDriver`;不動任何 Level 2 契約、不動公開簽名。與 [[G-E001]] 的內部邊界收斂彼此獨立,可各自展開。
