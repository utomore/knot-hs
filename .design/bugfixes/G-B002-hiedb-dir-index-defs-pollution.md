---
id: G-B002
type: bugfix
title: hiedb-dir-index-defs-pollution
description: 走目錄索引時 library 選擇器的定義行號被測試檔污染
status: done
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

**T1 spike 完成(2026-08-22),根因已查證。**

用 Node 內建的 `node:sqlite` 直接開兩個索引的 `defs` 表對比,同一個
`(hieFile, occ)` 主鍵、同一份 `.hie`,兩種呼叫形式寫出**不同的 `sl`**:

```
occ = fExportOptions:rootDir
hieFile = …\.hie\Knot\Export\Types.hie          ← 兩邊完全相同

  hiedb index <目錄>      → sl = 4492
  hiedb index <檔案清單>  → sl = 19      ← 正確(該檔 38 行,rootDir 在 19)
```

`fBackend:bName` 同樣:走目錄 1849、逐檔 35(正確)。

**所以這不是 knot 的缺陷,是 hiedb 兩種呼叫形式的行為差異。** `defs` 的主鍵是
`(hieFile, occ)`,同一列被後寫的值覆蓋;走目錄索引時,測試檔裡對 library 記錄
欄位的**使用**(`{ rootDir = dir, … }`,`test/Main.hs:4492`)被收成該欄位選擇器的
定義,覆蓋掉真正的宣告位置。

兩邊的 `defs` 總列數也不同(走目錄 868、逐檔 949),進一步證實兩種形式收集到的
不是同一組列。

**knot 的正式路徑用逐檔清單**(`HiedbDriver.hs:319`,為了排除幽靈 `.hie`),
取到的是**正確**的那一邊。實測 569 個節點的 `(檔案, 行號)` 全部自洽。

## 修復方向

**定案:方向 A —— 確認並固化 knot 的逐檔路徑,退休那條錯誤的不變量。**

G-E003 目標 3 原本斷言「兩種索引建法產出的圖**完全相同**」。spike 證明**這個不變量
本身就不該成立**:兩種形式對 `defs.sl` 的答案不同,而走目錄那個是錯的。拿正確的
結果去和錯誤的結果比對是否相等,方向從一開始就反了。

改法兩步:

1. **收斂比對範圍**:目標 3 只比對節點與邊的**身分**(`gnId`、
   `(geSource, geRelation, geTarget)`),不比對行號。原本的意圖——「逐檔清單不得
   漏收任何節點」——完整保留(實測兩法的 id 集合逐一相等)
2. **補上真正該守的不變量**:新增 `test_decl_line_within_file`,直接斷言
   **每個節點的 `gnLine` 必須落在 `gnFile` 的實際行數內**。這比互相比對強得多——
   後者只證明兩邊一樣,不證明兩邊是對的;而且它同時是 G-B001 那類錯歸的通用防線
   (19 行的 `app/Main.hs` 掛上 L3789 的節點會被直接擋下)

**不採用**原本列的 B(在 `defs` 查詢加守門)與 C(回報 hiedb 上游):B 是在下游補
一個上游本來就沒給錯的資料;C 可以之後做,但不該擋著本案。

## TodoList

- [x] T1: 查證 hiedb 兩種呼叫形式產生不同 `defs` 列的機制(直接比對兩個 sqlite 的 `defs` 表)  `dep: -`
- [x] T2: 依查證結果選定修復方向並與開發者確認  `dep: T1`
- [x] T3: 撰寫重現缺陷的測試(修復前應失敗)  `dep: T2`
- [x] T4: 實作修法  `dep: T3`
- [x] T5: 解除 G-E003 目標 3 的跳過條件,改為身分比對  `dep: T4`

## 驗證方式

- `test_decl_line_within_file`:knot 自掃的每個帶行號節點都落在其檔案行數內
- G-E003 目標 3 的跳過條件已移除,身分比對在兩種 `.hie` 狀態下都實際執行並通過
- 正式路徑的行號不得退化:`Knot.Export.Types.rootDir` 必須是 19
- 155 條測試全綠;五份黃金檔 byte 不變
- 閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0

## 修復紀錄

### 修法

**零產品程式碼變更**——knot 的正式路徑本來就是對的,改的是測試守的東西:

| 檔案 | 改動 |
|---|---|
| `test/Main.hs`(G-E003 selfcheck) | 目標 3 的比對從「完整 `GraphNode` / `GraphEdge` 記錄相等」收斂為「`gnId` 與 `(geSource, geRelation, geTarget)` 相等」;移除 G-B001 期間加的跳過條件,現在兩種 `.hie` 狀態都實際執行 |
| `test/Main.hs`(新增) | `test_decl_line_within_file`:每個節點的 `gnLine` 必須落在 `gnFile` 的實際行數內 |

### 量化結果

| 指標 | 結果 |
|---|---|
| 新守門檢查的節點數 | **538 個**帶行號的節點,全部落在檔案範圍內 |
| G-E003 目標 3 | 從「污染情境下跳過」變成**兩種 `.hie` 狀態都實際執行並通過** |
| 測試總數 | 154 → **155** |
| 產品程式碼 | **零變更** |

### 與「修復方向」的偏差

無。

### 仍然成立的限制(寫進 README 的依據)

`hiedb index <目錄>` 產生的索引**不可用於 knot**——`defs.sl` 會被同目錄下其他
`.hie` 對同名欄位的使用覆蓋。knot 一律逐檔傳 `hieFiles`,這是正確性需求,不只是
為了排除幽靈檔。若日後為了效能想改用目錄索引,必須先解掉這一點。
