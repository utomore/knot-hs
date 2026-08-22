---
id: G-B001
type: bugfix
title: hie-component-collision
description: 同名 module 的 .hie 互相覆蓋,test 宣告被歸到錯的原始檔
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [ADR-002]
related-feature: [project-meta/F003, extraction/F001, extraction/F004, graph-core/F002]
subsystems: [project-meta, extraction, graph-core]
---

# G-B001: 同名 module 的 `.hie` 互相覆蓋,test 宣告被歸到錯的原始檔

## 症狀

**觸發方式**:目標專案以共用的 `-hiedir` 產生 `.hie`(例如
`cabal build all --enable-tests --ghc-options="-fwrite-ide-info -hiedir .hie"`),
且**有兩個以上的 component 產出同名 module**——最常見的就是 `executable` 與
`test-suite` 都有 `Main`。之後跑 `knot extract`(decl 層,需 hiedb)。

**預期行為**:`--include-tests` 預設關閉,test-suite 的宣告不該出現在圖裡;
出現的節點,其 `source_file` 必須是該宣告真正所在的檔案。

**實際行為**(2026-08-22 以 knot 掃自己實測):

| 事實 | 數字 |
|---|---|
| `app/Main.hs` 實際行數 / 位元組 | **19 行 / 782 bytes** |
| 圖裡掛在 `app/Main.hs` 名下的節點 | **302 個**,行號到 **L3789** |
| 圖裡掛在 `test/Main.hs` 名下的節點 | **0 個** |
| `.hie/Main.hie` 檔案大小 | **1,550,075 bytes** |
| `test/Main.hs` 位元組 | 285,716 bytes |

`testExtractTypesConstruct`、`mn`、`defOpts`、`testBuildGraphDeterministic`
等符號在 `app/Main.hs` 出現 **0 次**、在 `test/Main.hs` 各出現 2 次,卻全部
被標成 `app/Main.hs`。**19 行的檔案不可能產出 1.5 MB 的 `.hie`**——那份是
test-suite 的 `Main` 蓋掉了 executable 的。

**影響範圍**:

- **decl 層不可信**:節點總數被灌水(548 → 871,+59%),`source_file` 與行號
  指到錯的檔案,下游拿它取證據行會取到不存在的位置
- **hub 排名失真**:`scan-graph.mjs` 的連通度榜首變成 `Main`(429),是第二名
  的 6 倍,而它其實是整個測試檔
- **module 層不受影響**:`imports` 邊來自 import-scan(不讀 `.hie`),依賴矩陣
  與循環依賴偵測仍可信

## 重現步驟

1. 在 knot-hs 自身執行:

   ```
   cabal build all --enable-tests --ghc-options="-fwrite-ide-info -hiedir .hie"
   <knot> extract . --db <專案外路徑>
   ```

2. 觀察 `codegraph.json`:

   ```
   grep -c '"source_file":"app/Main.hs"' codegraph.json   → 302
   grep -c '"source_file":"test/Main.hs"' codegraph.json   → 0
   wc -l < app/Main.hs                                     → 19
   ```

**最小條件**:兩個 component 產出同名 module + 共用 `-hiedir` + hiedb 可用。
不加 `--enable-tests` 產 `.hie` 時不會重現(`.hie/Main.hie` 就是 executable 的)。

### 既有測試已經是重現測試

在上述 `.hie` 狀態下跑完整測試套件,**`test_generated_filter_selfcheck` 會失敗**
(`test/Main.hs:5517`,G-E003 目標 3「兩種 hiedb 索引建法產出的圖相同」):

```
test_generated_filter_selfcheck: FAIL
  test\Main.hs:5517:
  expected: [GraphNode {gnId = NodeId "Knot.App.Cli", …
```

失敗輸出裡 `gnFile = "app/Main.hs"` 出現 **604 次**——被錯歸的 test 宣告佈滿比較的
兩邊,而 `hiedb index <目錄>` 與逐檔傳 `hieFiles` 兩種建法對它們的收錄不一致。

這條測試原本是為 G-E003 寫的,不是為本缺陷;但它在本缺陷的觸發條件下必然轉紅,
**可以直接當重現依據**。修復後它必須回到綠燈,且要另外補一條指名本缺陷的測試
(見「驗證方式」),不能只靠它。

## 根因分析

兩個獨立的缺陷,實測到的症狀是第一個造成的。

### 缺陷 1(本案主因):`.hie` 檔名以 module 名決定,同名即互相覆蓋

GHC 的 `-hiedir` 依 **module 名**決定輸出路徑,不含 component。`executable knot`
與 `test-suite knot-test` 都有 `main-is: Main.hs`,兩者都寫 `.hie/Main.hie`,
**後編譯的覆蓋先編譯的**。磁碟上只剩一份,knot 拿不到「這份屬於哪個 component」
的資訊。

接著整條鏈都沒有機會發現錯誤:

| 站 | 位置 | 發生什麼 |
|---|---|---|
| project-meta | `src/Knot/Meta/HieLocate.hs:167` `moduleNameFromHiePath` | `.hie/Main.hie` → module `Main` |
| project-meta | 同檔 `classify`(幽靈判定) | `Main` **在**母集(`app/Main.hs` 的 `sfModule`)→ 判為有效,不是幽靈 |
| extraction | `src/Knot/Extract/HiedbFacts.hs:319` `resolveModuleSource` | module `Main` → 對回**唯一納入**的來源檔 `app/Main.hs` |
| graph-core | `src/Knot/Graph/FactGate.hs:63` 條件 (a) | `app/Main.hs` **在** `pmSources` → 通過 |

每一站都照自己的契約做對了事,但**「module 名 → 原始檔」這個對映在同名時本質上
是多對一**,`resolveModuleSource` 只能挑一個,挑到的就是錯的那個。

### 缺陷 2(同源、未實跑驗證):非同名的 test module 宣告照樣進圖

即使沒有名稱碰撞,test-suite 的宣告仍會進圖。由程式碼讀出的依據:

- `src/Knot/Extract/Backend.hs:81` `narrowScope pm = pm { pmSources = filter sfIncluded (pmSources pm) }`
  ——**只窄化 `pmSources`**,`pmHie` 原樣保留(extraction/F001 假設 A1 明文)。
  `src/Knot/Extract/HiedbDriver.hs:259` 因此把**全部** `hieFiles` 交給 `hiedb index`
- `src/Knot/Graph/FactGate.hs:56` `srcSet = Set.fromList [sfPath sf | sf <- pmSources pm]`
  ——條件 (a) 的比對母體是 `pmSources` **全部**條目,**不限** `sfIncluded = True`
  (graph-core/F002 假設 A2 明文寫了這個選擇)

兩者相加:`test/Spec.hs` 這種不撞名的 test module,`.hie` 被索引 → 宣告被解析到
`test/Spec.hs` → fact-gate 條件 (a) 放行(它在 `pmSources` 裡)→ 節點成立。

**這一項是讀程式碼推出來的,尚未實跑驗證**——knot-hs 自己的 test-suite 只有
`Main` 一個 module,剛好落在缺陷 1,驗不到缺陷 2。

## 修復方向

**尚未定案,需與開發者討論後再開工。** 三個候選,可組合:

### 方向 A:project-meta 偵測 `.hie` 的 module 名碰撞並降級

`locateHie` 已經有母集,可以額外判斷「這個 module 名對應到多於一個 `sfModule`」
→ 該 `.hie` 標為不可信,附警告後排除。**優點**:在最上游擋住,下游三站不用改;
符合 project-meta「產出 test 排除判定 + 幽靈過濾」的既有職責。
**缺點**:會連帶丟掉 executable 那份真實的 `Main` 宣告(magnitude 小:19 行)。

### 方向 B:extraction 的 `narrowScope` 一併窄化 `pmHie`

把 `hieFiles` 也依「其 module 名是否對應到 `sfIncluded = True` 的來源檔」過濾。
**這解得了缺陷 2,但解不了缺陷 1**——`Main` 對應的 `app/Main.hs` 是納入的,
過濾會保留它,錯誤照舊。需要與 A 併用。
牽動 extraction/F001 假設 A1(「`pmHie` 原樣保留」)。

### 方向 C:graph-core 的 fact-gate 條件 (a) 改用 `sfIncluded` 母體

把 `srcSet` 從「全部 `pmSources`」收斂為「`sfIncluded = True` 的 `pmSources`」。
同樣只解缺陷 2。**動到 graph-core/F002 假設 A2 明文寫下的選擇**,要先確認當初
那個選擇的理由是否仍成立。

### 尚未查清的前提

- GHC 有沒有辦法讓不同 component 的 `.hie` 落在不同目錄(若 cabal 支援 per-component
  `-hiedir`,那 README 只要寫清楚建議做法,缺陷 1 可能不需要在 knot 內解)
- hiedb 的 `mods` 表是否留有能區分 component 的欄位(若有,`resolveModuleSource`
  可以不靠 module 名猜)

**這兩點應該先 spike 實測再決定修法**,不要憑推論選方向。

## TodoList

- [ ] T1: spike——查證 cabal / GHC 能否讓各 component 的 `.hie` 分目錄,以及 hiedb 索引是否留有 component 資訊  `dep: -`
- [ ] T2: 依 spike 結果與開發者確認修復方向(A / B / C 或組合),必要時回頭更新 extraction F001 假設 A1、graph-core F002 假設 A2  `dep: T1`
- [ ] T3: 撰寫重現缺陷的測試(修復前應失敗)  `dep: T2`
- [ ] T4: 實作定案的修法  `dep: T3`
- [ ] T5: 驗證缺陷 2(非同名 test module)是否同時被解掉,未解則補  `dep: T4`

## 驗證方式

- **重現測試轉綠**:對 knot-hs 自身跑完整管線,斷言「每個節點的 `gnLine` 不超過
  其 `gnFile` 的實際行數」——`app/Main.hs` 19 行卻掛 L3789 是本缺陷最乾淨的指紋。
  比照 `test_generated_filter_selfcheck` 的做法,缺 hiedb 或 `.hie` 時印明原因跳過
- **回歸**:154 條既有測試全綠;`codegraph.json` 的 module 層輸出(五份黃金檔)
  byte 不變——本缺陷只影響 decl 層,module 層不得有任何變化
- **閘門**:`cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0

## 修復紀錄

(尚未開工。本文檔依開發者指示先建檔記錄,`status` 停在 `open`。)
