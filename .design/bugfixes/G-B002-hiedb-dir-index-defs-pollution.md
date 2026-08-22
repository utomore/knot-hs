---
id: G-B002
type: bugfix
title: hiedb-dir-index-defs-pollution
description: 走目錄索引時 library 選擇器的定義行號被測試檔污染
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [ADR-002]
related-feature: [extraction/F004, graph-core/F002]
subsystems: [extraction, graph-core]
---

# G-B002: `hiedb index <目錄>` 讓 library 選擇器的定義行號被測試檔污染

## 症狀

`hiedb` 有兩種索引建法,knot 用其中一種、G-E003 的自檢測試用另一種對照:

| 建法 | 誰在用 |
|---|---|
| `hiedb index <檔案清單…>`(逐檔傳 `hieFiles`) | **knot 的正式路徑**(`HiedbDriver.hs:319`) |
| `hiedb index <目錄>` | 只有 `test_generated_filter_selfcheck` 的對照組 |

當 `.hie` 目錄含**納入範圍外**的 module(例如以 `--enable-tests` 產生時的
test-suite `Main`)時,兩者對 **record 欄位選擇器**的定義位置給出不同答案:

| 節點 | 逐檔清單(knot 正式路徑) | 走目錄(對照組) |
|---|---|---|
| `Knot.Export.Types.rootDir` | `src/Knot/Export/Types.hs:19` | `src/Knot/Export/Types.hs:`**`4482`** |
| `Knot.Export.Types.outputPath` | `:20` | `:4152` |
| `Knot.Extract.Backend.bName` | `:35` | `:1849` |

`src/Knot/Export/Types.hs` **只有 38 行**。4482 是 `test/Main.hs` 的行號,該行內容是

```haskell
      { rootDir = dir, outputPath = out, commitPolicy = NoCommit } g
```

——測試裡的**記錄更新語法**,不是定義。走目錄索引把「測試檔對 library 欄位選擇器的
**使用**」收成了那些選擇器的 `defs` 列,於是 `(檔案, 行號)` 這一對變成矛盾的:
檔案取自宣告所屬 module,行號取自測試檔。

**節點集合本身沒有差異**(兩法各 569 個 id,逐一比對零差異),差的只有 `gnLine`。

## 影響範圍

- **knot 的正式輸出不受影響**:實測 `rootDir` 為 19 行,正確。正式路徑逐檔傳
  `hieFiles`,不走目錄索引
- **受影響的只有 G-E003 的跨方法對照測試**:它的前提「兩種索引建法產出的圖相同」
  在 `.hie` 含範圍外 module 時不成立。G-B001 已讓該檢查在這種情境**明示跳過**並
  指向本文檔,不是放寬斷言
- **潛在風險**:若日後為了效能改用目錄索引,這個污染會直接進到正式輸出。下游拿
  `source_location` 取證據行會取到不存在的位置

嚴重度:**低**(正式路徑無誤),但它是一顆定時炸彈,值得在改動索引策略前先解掉。

## 重現步驟

1. 讓 `.hie` 含範圍外的 module:

   ```
   cabal clean
   cabal build test:knot-test --enable-tests --ghc-options="-fwrite-ide-info -hiedir .hie"
   ```

   (只建 test-suite → `.hie/Main.hie` 必為 test 的 1.5 MB 版本)

2. 跑完整測試套件。`test_generated_filter_selfcheck` 會印:

   ```
   [skip] G-E003 目標 3(兩種索引建法比對):.hie 含 1 個納入範圍外的 module,
          走目錄索引會被污染,見 G-B002
   ```

3. 要看到原始差異,把該跳過條件拿掉重跑,斷言會在 `cgNodes gDir @?= cgNodes g`
   失敗,差異全是 `gnLine`。

## 根因分析

**已查證的部分**:

- 差異只出現在 record 欄位選擇器(`rootDir` / `outputPath` / `commitPolicy` /
  `bName` / `bLevel` / `bProbe` …),不出現在一般函式或型別
- 走目錄那組給的行號,逐一對回去都落在 `test/Main.hs` 的**記錄建構或更新**語句上
- knot 逐檔傳清單那組的行號正確
- G-E003 早已記錄兩法的 `defs` 表列數不同(走目錄 631、逐檔 623,差 8 列),當時
  歸因於 deriving 字典;本案顯示差異不只那 8 列

**尚未查證的部分**:hiedb 端為什麼兩種呼叫形式會產生不同的 `defs` 列——是
`--src-base-dir` 的解讀差異、目錄走訪的去重策略、還是 `defs` 的 upsert 順序,
**都還沒實測**。修復前必須先把這一段查清楚,不得憑推論動手。

## 修復方向

**未定案。** 先查清上面「尚未查證的部分」再選,候選:

- **A**:確認 knot 的逐檔路徑恆為正確 → 把「不得使用目錄索引」寫成 extraction 的
  明文約束(加註解 + 測試守門),本缺陷降為文件問題
- **B**:若污染其實兩法都有、只是逐檔那組剛好沒被觸發 → 要在 `defs` 查詢加上
  「定義位置必須落在該 module 自己的檔案內」的守門
- **C**:向 hiedb 上游回報(若確認是 hiedb 的行為不一致)

## TodoList

- [ ] T1: 查證 hiedb 兩種呼叫形式產生不同 `defs` 列的機制(直接比對兩個 sqlite 的 `defs` 表)  `dep: -`
- [ ] T2: 依查證結果選定修復方向並與開發者確認  `dep: T1`
- [ ] T3: 撰寫重現缺陷的測試(修復前應失敗)  `dep: T2`
- [ ] T4: 實作修法  `dep: T3`
- [ ] T5: 解除 G-E003 目標 3 的跳過條件,確認兩法在含範圍外 module 時亦一致  `dep: T4`

## 驗證方式

- 重現測試轉綠;`test_generated_filter_selfcheck` 的跳過條件可以拿掉且維持綠燈
- 正式路徑的行號不得退化:`Knot.Export.Types.rootDir` 必須是 19
- 154 條既有測試全綠;五份黃金檔 byte 不變
- 閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0

## 修復紀錄

(尚未開工。本文檔為 G-B001 修復過程中發現、依開發者指示另案記錄。)
