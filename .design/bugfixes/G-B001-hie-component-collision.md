---
id: G-B001
type: bugfix
title: hie-component-collision
description: 同名 module 的 .hie 互相覆蓋,test 宣告被歸到錯的原始檔
status: done
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

### T1 spike 結果(2026-08-22):上面的分析要修正

spike 查了兩件事,結論**推翻了本文檔初版列的 A / B / C 三個方向**。

**(1) hiedb 的索引留有 component 資訊 —— 有。**

```
$ hiedb -D <db> ls
…\Main.hie          Main          knot-hs-0.0.1.0-inplace-knot            ← executable
…\Knot\Query.hie    Knot.Query    knot-hs-0.0.1.0-inplace-knot-internal   ← private sublib
```

`mods` 表帶 per-component 的 unit-id。理論上可據此判斷 component,但那要解析 cabal
的 unit-id 命名慣例(`<pkg>-<ver>-inplace-<component>`),是實作細節不是契約。

**(2) `hs_src` 有值,而且問題不在它。**

`src/Knot/Extract/HiedbDriver.hs:319` 確實傳了 `--src-base-dir .`,
`src/Knot/Extract/HiedbFacts.hs:26` 註明「`mods.hs_src` 是**絕對路徑**」。
`resolveModuleSource`(`HiedbFacts.hs:324`)**已經**優先用 `hs_src` 做後綴比對,
比對不中才退回 module 名。而且 `:339` 明確寫了「多筆(例:多個 `Main`)視為落空」
——**這個保護原本就寫對了**。

**真正的成因**:`resolveModuleSource` 收到的 `sfs` 是 **`narrowScope` 窄化過的清單**
(`Backend.hs:81`,只留 `sfIncluded = True`)。於是對 test-suite 的 `Main.hie`:

1. `hs_src` = `test/Main.hs` 的絕對路徑
2. 後綴比對:`test/Main.hs` 已被窄化掉,**不在 `sfs` 裡** → 落空
3. 退回 `uniqueByModule`:窄化後 `Main` 只剩 `app/Main.hs` **一筆** →
   「多個 `Main` 視為落空」的保護**永遠不會觸發** → 回 `Just "app/Main.hs"`

**窄化把「這份 `.hie` 屬於一個我們刻意排除的檔案」這個事實抹掉了**,退路於是把它
誤認成「路徑對不上,猜一個吧」。

**(3) 那條退路是刻意設計的,有測試守著。**

`test/Main.hs:2132` 明確斷言現行行為:

```haskell
-- 後綴落空時也走退路
resolveModuleSource [core, app] (mn "Demo.App") (hs "D:\\other\\Nope.hs")
  @?= Just "src/Demo/App.hs"
```

它存在的理由正當:`hs_src` 走 `makeAbsolute`、`hieFile` 走 `canonicalizePath`,
大小寫 / 8.3 短檔名 / symlink 都可能讓路徑對不上,退路是這種情況的保命網。

問題是它**把兩種情況混為一談**:

| 情況 | 現行行為 | 應有行為 |
|---|---|---|
| 路徑技術性對不上,但檔案確實在納入範圍內 | 退回 module 名 → **猜對** | 維持 |
| `.hie` 屬於**被排除**的原始檔 | 退回 module 名 → **猜到錯的檔** | 回 `Nothing` 丟棄 |

區分兩者的判準很單純:**後者的 `hs_src` 會命中一個「存在於 `pmSources` 但
`sfIncluded = False`」的檔案**,前者則什麼都命不中。窄化之後這個判準就沒了。

## 修復方向

**定案(2026-08-22,T1 spike 後與開發者確認):把 inclusion 旗標帶到底。**

初版列的 A / B / C 全部作廢:A(上游偵測碰撞)與 B(窄化 `pmHie`)都得靠 module 名
判斷,而同名正是本缺陷的前提,分不出來;C(收斂 fact-gate 母體)只碰得到缺陷 2。

### 核心改動

讓 `resolveModuleSource` 看得到「被排除的檔案」,它就能把兩種情況分開:

```haskell
-- 收到的是完整 pmSources(含 sfIncluded = False 的條目)
resolveModuleSource sfs modName mHsSrc =
  case mHsSrc >>= longestSuffixHit of        -- 比對母體:全部 sfs
    Just sf | sfIncluded sf -> Just (sfPath sf)
            | otherwise     -> Nothing       -- 命中被排除的檔 → 這份 .hie 不在範圍內
    Nothing                 -> uniqueByModule -- 什麼都沒命中 → 維持 F004 的保命網
```

**簽名不變**,變的只是「傳進來的是完整清單而非窄化後的清單」,以及內部改看
`sfIncluded`。`uniqueByModule` 的母體同步限定為 `sfIncluded = True`,語意與現在一致。

這樣一來:

- test-suite 的 `Main.hie` → `hs_src` 命中 `test/Main.hs`(排除)→ `Nothing` →
  走既有的 `unmapped` 警告整批跳過(`HiedbFacts.hs:305`,基礎設施已存在)
- 非同名的 test module(缺陷 2)→ 同一條路徑丟棄,**一併解掉**
- 路徑技術性對不上 → 什麼都沒命中 → 退路照常,`test/Main.hs:2132` 的既有斷言**不用改**

### 連帶要動的兩處

`resolveModuleSource` 現在拿到的是窄化後的清單,所以窄化必須讓開:

1. **`src/Knot/Extract/Backend.hs:81` `narrowScope`** 不再丟棄 `sfIncluded = False`
   的條目(否則資訊在到達 hiedb-facts 之前就沒了)
2. **`src/Knot/Extract/ImportScan.hs:59`** 改在自己的迭代點套抽取規則 1
   (`filter sfIncluded`)。該模組的 haddock 現在寫「原樣掃描收到的 `pmSources`,
   不自行過濾」,要一併改

**抽取規則 1(納入範圍)的語意完全不變**,只是從「集中預先過濾」改成「在迭代點套用」;
規則本身是 Level 2 契約,**不動**。`narrowScope` 與 `resolveModuleSource` 都是非契約面
(haddock 已如此標示),簽名與匯出面零變動。

### 為什麼不用 unit-id

spike 證實 hiedb 的 `mods` 帶 per-component unit-id,理論上更權威(連「同名但都納入」
都分得開)。不採用的理由:要解析 `<pkg>-<ver>-inplace-<component>` 這個命名慣例,
那是 cabal 的實作細節、不是任何契約,版本一變就可能失效。本方向用的
`sfIncluded` 是 project-meta 的既有契約欄位,穩定得多。

若日後出現「兩個都納入的同名 module」需求,再回頭評估 unit-id(現行的
`uniqueByModule` 對這種情況已經是回 `Nothing` + 警告,不會猜錯)。

## TodoList

- [x] T1: spike——查證 cabal / GHC 能否讓各 component 的 `.hie` 分目錄,以及 hiedb 索引是否留有 component 資訊  `dep: -`
- [x] T2: 依 spike 結果與開發者確認修復方向  `dep: T1`
- [x] T3: 撰寫重現缺陷的測試(修復前應失敗)  `dep: T2`
- [x] T4: `resolveModuleSource` 依 `sfIncluded` 分流;`narrowScope` 停止丟棄;`ImportScan` 在迭代點套規則 1  `dep: T3`
- [x] T5: 驗證缺陷 2(非同名 test module)同時被解掉  `dep: T4`
- [x] T6: 回寫 extraction/F001 假設 A1 的 `narrowScope` 敘述與 `ImportScan` 的 haddock  `dep: T4`

## 驗證方式

- **重現測試轉綠**(T3):`resolveModuleSource` 的純函數測試——傳入含
  `sfIncluded = False` 的 `test/Main.hs` 與 `sfIncluded = True` 的 `app/Main.hs`,
  `hs_src` 指向前者時必須回 `Nothing`(修復前回 `Just "app/Main.hs"`)。
  不需要 `.hie`、不需要 hiedb,決定性且秒級
- **缺陷 2**(T5):同一條測試加一組非同名案例(`test/Spec.hs` 排除、`hs_src` 指向它)
  → 同樣必須回 `Nothing`
- **既有斷言不得改**:`test/Main.hs:2132` 的「後綴落空時也走退路」必須原樣通過
- **module 層零變更**:五份黃金檔 byte 不變(`test_codegraph_output_unchanged`)
  ——`narrowScope` 與 `ImportScan` 的改動不得讓 import-scan 多掃或少掃任何檔案
- **回歸**:154 條既有測試全綠
- **閘門**:`cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0
- **端對端**:以 `--enable-tests` 產出的 `.hie` 重跑 `knot extract .`,
  `app/Main.hs` 名下的節點數必須從 302 降到符合其 19 行的規模,且
  `test_generated_filter_selfcheck` 在該 `.hie` 狀態下轉綠

## 修復紀錄

### 修法

三處,全部非契約面,匯出面與簽名零變動:

| 檔案 | 改動 |
|---|---|
| `src/Knot/Extract/HiedbFacts.hs` | `resolveModuleSource` 的後綴比對改回傳 `SourceFile`;命中 `sfIncluded = False` 者回 `Nothing`(丟棄),命中納入者回 `sfPath`,完全沒命中才走原退路。`uniqueByModule` 的母體同步限定 `sfIncluded = True` |
| `src/Knot/Extract/Backend.hs` | 移除 `narrowScope`,`runBackends` 直接把完整 `ProjectMeta` 交給後端;連帶清掉不再需要的 `SourceFile` import |
| `src/Knot/Extract/ImportScan.hs` | `runImportScan` 在自己的迭代點 `filter sfIncluded`,抽取規則 1 落在此處 |

### 量化結果(以觸發缺陷條件的 `.hie` 實測)

重現條件靠 `cabal build test:knot-test --enable-tests --ghc-options="-fwrite-ide-info -hiedir .hie"`
**只建 test-suite** 來穩定製造(`.hie/Main.hie` = 1,558,205 bytes,test 的版本)。
先前用 `cabal build all --enable-tests` 不可靠——**誰蓋掉誰取決於建置順序**,同一條
指令兩次實測分別得到 test 的(1.5 MB)與 executable 的(2,841 bytes)。

| 指標 | 修復前 | 修復後 |
|---|---|---|
| `app/Main.hs` 名下節點數 | **302**(行號到 L3789) | **1**(只剩 import-scan 的 module 節點) |
| `test/Main.hs` 名下節點數 | 0 | 0 |
| `testExtractTypesConstruct` / `defOpts` / `testBuildGraphDeterministic` 出現次數 | 佈滿全圖 | **0** |
| 丟棄是否明示 | 否(靜默猜到錯的檔) | **是**:`cannot map indexed module Main back to pmSources; skipping its decls and refs` |

**缺陷 2 一併解掉**:`resolveModuleSource` 的純函數測試加了不撞名的案例
(`test/Spec.hs` 排除、`hs_src` 指向它)→ 回 `Nothing`。同一條修法涵蓋兩者。

**兩種 `.hie` 狀態都綠**:

- 正常建法(不含 test-suite):154 條全綠,`warnings=0`,G-E003 的跨方法比對**實際執行並通過**
- 缺陷條件建法:154 條全綠,1 則預期的丟棄警告,跨方法比對明示跳過並指向 G-B002

閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0;
五份黃金檔 byte 不變。

### 與「修復方向」的偏差

無。定案的方向照做,連 `resolveModuleSource` 的簽名不變、`test/Main.hs:2132` 既有斷言
不用改這兩點預測都成立。

### 過程中改動的既有測試(兩條,都是因為行為刻意改變)

1. **`test_included_scope`**:原斷言「後端**只收到** `sfIncluded = True` 的檔」。
   Level 2 契約原文是「只**處理**」,不是「只收到」——原測試把實作形狀寫進了斷言。
   改成兩半:後端收到完整清單(含被排除者),但 import-scan 產出的事實不得提及任何
   被排除的檔。**規則 1 的驗證強度沒有下降,只是移到正確的層級**
2. **`test_hiedb_facts_selfcheck`**:原斷言「不該有對映不到的警告」。該前提被本次修復
   正當地推翻——`.hie` 含範圍外 module 時,正好應該有一則。改成「只允許
   『該 module 的原始檔被排除』這一種來源,其餘一律是缺陷」

### 另案記錄的發現

修復後在缺陷條件的 `.hie` 下,`test_generated_filter_selfcheck` 的跨方法比對仍不一致
——但**節點 id 集合完全相同**(各 569,零差異),差的只有 `gnLine`:走目錄索引把測試檔
裡的記錄欄位**使用**收成 library 選擇器的 `defs` 列(`Knot.Export.Types.rootDir` 被標成
`src/Knot/Export/Types.hs:4482`,該檔只有 38 行)。

**knot 的正式路徑不受影響**(實測 `rootDir` 為 19 行,正確)——正式路徑逐檔傳
`hieFiles`,不走目錄索引。這是與本案根因不同的獨立缺陷,依開發者指示另開
**G-B002** 記錄,本次不修;G-E003 的該項檢查改為在污染情境明示跳過並指向 G-B002,
不是放寬斷言。
