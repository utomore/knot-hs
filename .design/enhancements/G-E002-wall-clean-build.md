---
id: G-E002
type: enhance
title: wall-clean-build
description: 讓 -Wall 零警告真正成立,並補上會退化的偵測手段
status: done
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


## 現況複查(2026-08-22,實作前)

`cabal clean` 後全量重建的真實結果:**8 筆**,全部是 `test/Main.hs` 的 `-Wincomplete-record-selectors`,分兩簇(行號因 [[G-E003]] 的改動位移 +17)。第 9 筆 `-Wx-partial` 已於閘門修掉,`HiedbDriver` 現在是 `(firstHie : _)` 的全函式寫法,複查屬實。

```
test\Main.hs:1321:19 / 1321:29 / 1323:9 / 1324:9 / 1325:20   -- testScanSourceFacts
test\Main.hs:1448:19 / 1448:29 / 1450:8                       -- property: round-trip
```

### 追加發現:`-Werror` 單獨用也是假答案

文檔已記錄 `-fforce-recomp` 會被 cabal 的 up-to-date 檢查短路。實測發現**同一個陷阱還有第二個入口**:

| 指令 | 結果 | 真話? |
|---|---|---|
| `cabal build all --enable-tests --ghc-options=-fforce-recomp` | `Up to date`、0 警告 | ❌ |
| `cabal build all --enable-tests --ghc-options=-Werror`(增量樹) | exit 0、0 警告 | ❌ |
| `cabal clean && cabal build all --enable-tests` | 8 筆警告 | ✅(但只是印出來) |
| `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` | **exit 1、8 errors** | ✅ |

第二列的原因與第一列不同:`--ghc-options` 有進 cabal 的建置設定雜湊,所以 cabal **會**重新呼叫 GHC,但 **GHC 自己的重編檢查不理會警告旗標的變動**,於是每個模組都被跳過、警告不重印、`-Werror` 無從觸發。

結論:**`cabal clean` 是必要條件**,任何「不 clean 就想問出警告」的做法都會拿到假答案。

## 介面變動

**無。** 本次只動測試碼的取值寫法與文檔慣例,不碰任何公開簽名、DTO 或 Level 2 契約。

## 決策

1. **8 筆警告的收斂手段**:沿用 `test/Main.hs` 既有的全函式取值輔助家族(`declOf` / `refOf`,其註解已寫明「以位置 pattern 承接,避免對 sum type 用部分選擇器」),補上 `FactImport` / `FactModule` 的對應版本,把 8 個呼叫點改過去。不另立新寫法——同一個問題在同一個檔案裡已經有既定解法。
2. **防退化手段**(開發者裁決,2026-08-22):採**慣例層的閘門指令**,不加 `-Werror` 的 cabal flag、不建 CI。閘門驗收指令定為

   ```
   cabal clean && cabal build all --enable-tests --ghc-options=-Werror
   ```

   並把「不可用 `-fforce-recomp` 或單獨的 `-Werror` 代替」連同理由寫進慣例,讓下一個人看得到陷阱本身而不只是指令。
3. **慣例寫在哪**:寫進 `.design/system.md` 的「技術棧與環境」。**不改任何 `build-log.md`**——那是編排過程的歷史記錄,四次閘門當初確實做出了錯誤宣告,把它改掉等於湮滅這次優化的發現依據。

## TodoList

- [x] **T1** 測試碼收斂:在 `test/Main.hs` 補 `importOf` / `moduleOf` 兩個全函式取值輔助,把 8 個部分選擇器呼叫點改過去
- [x] **T2** 慣例訂正:`.design/system.md`「技術棧與環境」新增建置品質閘門,寫明驗收指令與兩個已實測的假答案(dep: -)
- [x] **T3** 全量驗收:`cabal clean && cabal build all --enable-tests --ghc-options=-Werror` 需 exit 0;`cabal test --enable-tests` 全綠(dep: T1)

## 1-to-1 測試對照表

本次不新增行為,故不新增行為測試;「測試」的角色由既有測試的**語意不變**與**閘門指令本身**承擔。

| Todo | 測試 | 類型 |
|---|---|---|
| (前置) | 既有 138 條全綠,且**先於任何改動跑一次**留基準 | 回歸 |
| T1 | `test_scan_source_facts` 與 property `rendered imports round-trip through scanSource` 改寫後語意不變且仍綠;改寫額外把「這些事實都是 `FactImport`」從隱含假設變成顯式斷言 | 回歸 |
| T2 | 無自動測試(文檔變更) | — |
| T3 | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0 —— 這條指令同時是本次的驗收與往後的防退化手段 | 驗收 |

## 影響範圍

- **測試碼**:`test/Main.hs` 的 extraction/F002 兩簇取值寫法(+ 兩個新輔助函數)
- **文檔**:`.design/system.md`「技術棧與環境」新增建置品質閘門
- **不影響**:任何 `src/` 與 `app/` 的程式碼、公開簽名、Level 2 契約、`knot-hs.cabal` 的 `ghc-options` 與 `version`

## 明確不做

- 不改任何 `build-log.md` 的歷史記錄(理由見「決策 3」)
- 不加 `-Werror` 的 cabal flag、不建 CI(開發者裁決採慣例層)
- 不動 `knot-hs.cabal` 的 `version`
- 不順手處理 [[G-E001]] 的測試用匯出(彼此獨立,各自展開)

## 實作備註

### 量化結果(2026-08-22)

驗收指令一律為 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror`(增量樹的數字不採信)。

| 量化目標 | 改善前 | 改善後 |
|---|---|---|
| 全量重建的 `-Wall` 警告數 | **8**(`-Wincomplete-record-selectors`,`test/Main.hs` 兩簇) | **0** |
| 閘門指令 exit code | **1**(8 errors) | **0** |
| 既有測試 | 138 綠 | **138 綠**(零回歸,零新增) |
| 防退化手段 | 無——四次閘門都從增量建置得出「零警告」的錯誤結論 | 驗收指令與**兩個實測過的假答案**寫進 `system.md`「建置品質閘門」 |

`-Wx-partial`(`HiedbDriver.hs` 的 `head`)在本文檔建立前的階段二閘門已修,本次複查確認現況為 `(firstHie : _)` 的全函式寫法,無需再動。

### 實作決策(文檔未定、由實作者裁量的部分)

1. **改寫順手把隱含假設變成斷言**:`test_scan_source_facts` 原本直接對 `imps` 用 `fiLine` / `fiTo`,隱含假設「第一筆之後全是 `FactImport`」——不成立時是執行期崩潰而非測試失敗。改走 `importOf` 後多一行 `length parsed @?= length imps`,把那個假設變成顯式斷言。這是收斂警告的副產品,不是額外 scope。
2. **輔助函數家族的註解升級**:`declOf` 的註解原本只說「避免部分選擇器」,現補上「增量建置不重印警告、退化會靜悄悄長回來」的理由,並點名這四個(`moduleOf` / `importOf` / `declOf` / `refOf`)是本檔取 `Fact` 欄位的唯一手段。下一個人在旁邊寫測試時看得到規則。
3. **`system.md` 而非 `build-log.md`**:慣例寫進燈塔文件;四份 `build-log.md` 的歷史宣告一字未改(理由見「決策 3」)。

### 未動到的東西(複查)

`src/` 與 `app/` 全部程式碼、任何公開簽名與 Level 2 契約、`knot-hs.cabal` 的 `ghc-options` 與 `version`(仍為 `0.0.1.0`)、[[G-E001]] 的測試用匯出,全部未變更。未加 cabal flag、未建 CI。
