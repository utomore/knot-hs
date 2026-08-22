---
id: G-E003
type: enhance
title: generated-decl-filter
description: 產生碼過濾只擋 ref 不擋 decl,deriving 字典污染 decl 層節點
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [ADR-002]
related-feature: [extraction/F004, graph-core/F002, graph-core/F003]
subsystems: [extraction, graph-core]
---

# G-E003: 產生碼過濾的不對稱與 deriving 字典節點

## 發現依據(2026-08-22 graph-core 階段二閘門)

graph-core 的組裝規則 3 有三個過濾條件,其中 (c) `FactRef.frGenerated = True` 在 knot-hs 自身實測濾掉 **846 筆** deriving/TH 產生的引用。但**產生碼的宣告本身一筆都沒被濾掉**。

編排者於閘門唯讀實跑 knot-hs 自身取證:

```
knot extract . --db <專案外路徑>
→ 654 nodes / 2267 edges
   節點 = 31 module + 623 decl + 0 instance
```

623 個 decl 節點中,**106 個(17%)是 deriving 產生的 dictionary 繫結**:

```
Knot.App.Cli.$fEqCommand          Knot.Export.Types.$fShowExportReport
Knot.App.Cli.$fShowSummaryMode    Knot.Extract.Backend.$fEqProbeResult
Knot.Extract.HiedbFacts.$fFromRowDefRow
Knot.Extract.HiedbFacts.$fExceptionHiedbFactsError   …(共 106 個)
```

## 為什麼會不對稱(這是本文檔的重點)

**hiedb 只在 `refs` 表有 `is_generated` 欄,`decls` 與 `defs` 表沒有。**

extraction 的抽取規則 4a 忠實轉載了它有的那一半(`FactRef.frGenerated`),而 `FactDecl` 的 DTO 因此**沒有對應欄位**——不是 extraction 漏掉,是上游資料就只有一半。graph-core 的規則 3 只能濾它拿得到的那一半,於是形成:

| | 產生碼 | 是否被濾 |
|---|---|---|
| `FactRef`(引用) | 846 筆 | ✅ 規則 3 (c) |
| `FactDecl`(宣告) | 106 個節點 | ❌ **無旗標可依** |

結果是圖裡出現一批「沒有任何人寫過那些行」的節點,而且它們**稀釋 hub 排名**——decl 層節點總數被灌水 17%,連通度排名的分母跟著失真。

## 同源的第二個症狀:19 則 unresolved 警告

閘門實跑的 19 則警告全是 `unresolved reference target $f…`:

```
graph: src/Knot/Extract/Types.hs: unresolved reference target $fShowFact; 2 ref edge(s) dropped
graph: app/Knot/App/Cli.hs: unresolved reference target $fEqBackendChoice; 1 ref edge(s) dropped
```

graph-core/F003 追出根因:**hiedb 的 `defs` 表隨索引建法而異**——`hiedb index <目錄>` 得 631 列,而 knot 的 HiedbDriver 逐檔傳 `hieFiles`(為了排除幽靈檔)得 623 列,兩者的 `mods` / `decls` / `refs` 三表**逐列相同**,只有 `defs` 差 8 列。少的 8 列全是 deriving instance 字典(`$fEqBackendChoice`、`$fShowFact` 等),連帶 **25 筆 ref 解析不到目標**。

換句話說:**同一批 deriving 字典,有些進了圖(106 個節點)、有些沒進(8 個),取決於索引怎麼建。** 這個不一致本身就是雜訊來源。

## 量化目標

1. `knot extract` 對 knot-hs 自身產出的 decl 節點中,deriving 產生的 dictionary 繫結為 **0**(目前 106)
2. `unresolved reference target $f…` 類警告為 **0**(目前 19 則 / 25 筆)
3. 兩種 hiedb 索引建法(走目錄 vs 逐檔清單)產出的圖**完全相同**(目前差 8 節點 / 33 邊)
4. 既有 134 條測試零回歸;決定性不變(兩次輸出位元相同)

## 調查結果(2026-08-22,實作前的驗證)

四個方向逐一實測,結論如下。

### B. hiedb 欄位:字面上沒有旗標,但兩表的**集合差**就是答案

`decls` / `defs` 兩表逐欄複查(hiedb 0.8,knot-hs 自身索引):

```sql
decls( hieFile, occ, sl, sc, el, ec, is_root )   -- 沒有任何 generated 旗標
defs ( hieFile, occ, sl, sc, el, ec )            -- 連 is_root 都沒有
```

所以「有沒有現成欄位可用」的答案是 **沒有**。但兩表的關係本身帶著答案:

| 檢查(knot-hs 自身索引) | 結果 |
|---|---|
| `decls ⊆ defs`(同 `hieFile` + `occ`) | 0 筆例外 |
| `defs \ decls` | **106 筆,106/106 全是 `$f…`**,零誤判、零漏抓 |
| fixture `test/fixtures/hiedb` | 11 筆 defs 中 2 筆,正是 `$fEqColor` / `$fShowColor`(`deriving` 那一行) |

語意站得住腳:**`decls` 收的是有原始碼宣告 AST 節點的名字**(上游 `HieDb/Utils.hs` 的 `goDec` 只在遇到 `Decl` / `ValBind` context 時建列),而 `defs` 額外收編譯器產生的定義點。「在 `defs` 不在 `decls`」= **這個名字沒有人寫過那一行**。

這是 hiedb 自己兩張表的**結構事實**,不是 `$f` 前綴的名字猜測,因此:

- 不牴觸 graph-core design.md「不做啟發式」的原則,**方向 C 的原則鬆綁裁決不需要發生**
- 落在 extraction 側當事實標註(比照規則 4a 的 `frGenerated`),graph-core 仍然只採信事實、不猜

### 同一條規則在 ref 側也成立(這是症狀 2 的解法)

目標 module 已被索引的 3088 筆 ref,依「目標 occ 在該 module 的 `decls` 有沒有列」分兩堆:

| 分堆 | 筆數 | 其中 `$…` |
|---|---|---|
| 目標在 `decls` 有列 | 2834 | **0** |
| 目標在 `decls` 沒有列 | 254 | **254(全部)** |

2834 筆真名一個都沒被誤傷。關鍵是這條規則**不依賴目標的 `defs` 列存不存在**——那 8 個「索引裡沒有 def 列」的目標(症狀 2 的全部來源)照樣判得出來。

### D. 索引建法:症狀屬實,但不必動它

623 vs 631 的 8 筆差複驗屬實,且那 8 個名字**正是** 19 則 unresolved 警告的全部目標:

```
$fEqQueryCommand  $fShowQueryCommand  $fShowComponentKind  $fShowDeclKind
$fShowFact        $fEqBackendChoice   $fShowBackendChoice  $fShowCapabilityLevel
```

但上面的 ref 側規則會把指向它們的 25 筆 ref 一併濾掉,兩種建法濾完後節點集合一致。**因此不碰逐檔傳 `hieFiles`**,extraction/F003 W3 的幽靈 `.hie` 防護(單一 0-byte 假 `.hie` 讓整批 exit 1)原封不動。

### A. `.hie` 直讀:不採用

精度最好,但等於啟動 ADR-002 預留的第三後端,成本以天計,與本次優化的 scope 不成比例。B 的結構事實已能把三個量化目標一次做完。

## 介面變動(定案)

### extraction — Level 2 契約變更

`Fact` 的兩個建構子各加一個布林欄位,位置比照既有慣例(payload… → 產生碼旗標 → `file` → `line`):

```haskell
  | FactDecl                            -- 頂層宣告
      { fdName :: QualName, fdKind :: DeclKind
      , fdGenerated :: Bool             -- 新增:產生碼宣告(hiedb defs 有列、decls 無列)
      , fdFile :: FilePath, fdLine :: Int }
  | FactRef                             -- 名稱引用
      { frFromModule :: ModuleName
      , frFromDecl   :: Maybe QualName
      , frTarget     :: QualName
      , frGenerated  :: Bool            -- 既有:引用**站點**是產生碼(refs.is_generated)
      , frTargetGenerated :: Bool       -- 新增:引用**目標**是產生碼宣告
      , frFile :: FilePath, frLine :: Int }
```

兩個新欄位的值一律由同一個判準決定:**該名字在其(已索引)module 的 `decls` 表沒有列**。目標 module 不在索引內(外部套件)時 `frTargetGenerated = False`——外部目標本來就會被 graph-core 規則 1 丟棄,不需要也不應該由本旗標處理。

**抽取規則 4a 改寫**:extraction 標註產生碼的**三個面**(ref 站點 `frGenerated`、decl 本身 `fdGenerated`、ref 目標 `frTargetGenerated`),但一律**只標註、不過濾**;要不要丟棄仍是 graph-core 的決定。

**降級行為**(規則 7 best-effort):`decls` 索引查詢失敗時,兩個新旗標一律為 `False` 並發一則 `ExtractWarning`——退回本次優化前的行為,**絕不因為查不到就把全部宣告當成產生碼**。

### graph-core — 規則 3 增列

組裝規則 3 的條件由三條變五條,任一成立即濾除該事實並計入 `gsFilteredGenerated`:

| 條件 | 內容 | 狀態 |
|---|---|---|
| (a) | 事實指向的檔案不在 `pmSources` | 既有 |
| (b) | 行號 ≤ 0 | 既有 |
| (c) | `FactRef.frGenerated = True` | 既有 |
| (d) | `FactDecl.fdGenerated = True` | **新增** |
| (e) | `FactRef.frTargetGenerated = True` | **新增** |

`gsFilteredGenerated` 的語意**不變**——design.md 原本就寫「濾除的事實數」,且規則 3 的 (a)(b) 早已作用在 `FactDecl` 上,本次沒有語意漂移。

### 不變動

`GraphStats` 欄位、`gsTopExternalTargets` 呈現、`CodeGraph` / `GraphNode` / `GraphEdge`、export-query 的投影格式與查詢 CLI 全部不動。

## TodoList

- [x] **T1** extraction DTO:`Knot.Extract.Types` 的 `FactDecl` 加 `fdGenerated`、`FactRef` 加 `frTargetGenerated`
- [x] **T2** hiedb-facts:新增 `decls` 的 `(hieFile, occ)` 索引查詢與 module → `hieFile` 反查,據以計算兩個旗標;查詢失敗走降級路徑(旗標全 `False` + 警告)(dep: T1)
- [x] **T3** graph-core fact-gate:規則 3 加 (d)、(e) 兩條件(dep: T1)
- [x] **T4** 既有建構站點補參數(`src/` 與 `test/` 合計約 70 處位置式建構),回歸測試全綠(dep: T1)
- [x] **T5** Level 2 文檔同步:extraction `design.md` 的事實流 DTO 與規則 4a、graph-core `design.md` 的規則 3(dep: T2、T3)
- [x] **T6** 量化驗收:對 knot-hs 自身實跑,四項量化目標逐一取證(dep: T2、T3、T4)

## 1-to-1 測試對照表

| Todo | 測試 | 類型 |
|---|---|---|
| (前置) | 既有測試全數綠燈,且**先於任何改動跑一次**留基準 | 回歸 |
| T1 | 兩個新欄位可建構與取值;`Fact` 的 `Ord` 仍為全序(決定性前提) | 新增 |
| T2 | fixture 索引:`$fEqColor` / `$fShowColor` 的 `FactDecl.fdGenerated = True`,`greet` / `cfgName` / `Color` 為 `False` | 新增 |
| T2 | fixture 索引:指向 `$f…` 的 ref `frTargetGenerated = True`,指向 `greet` 的為 `False`;目標為外部 module(如 `GHC.Internal.Show`)時恆 `False` | 新增 |
| T2 | `decls` 查詢失敗 → 兩旗標全 `False` + 一則警告(驗證不誤殺) | 新增 |
| T3 | 規則 3 (d):`fdGenerated = True` 的 `FactDecl` 被濾除且 `gfFiltered` 計數 | 新增 |
| T3 | 規則 3 (e):`frTargetGenerated = True` 的 `FactRef` 被濾除且 `gfFiltered` 計數 | 新增 |
| T3 | 同時命中多條件的一筆事實只計一次(`gfFiltered` 是事實筆數不是命中次數) | 新增 |
| T3 | `FactModule` / `FactImport` 不受 (d)(e) 影響(A1 不回歸) | 回歸 |
| T6 | 端到端(需 hiedb,缺席時跳過並印明原因):knot-hs 自身 0 個 `$f` decl 節點、0 則 `unresolved reference target $f…` 警告、兩種索引建法圖完全相同、連續兩次輸出位元相同 | 驗收 |

## 影響範圍

- **extraction**:`Knot.Extract.Types`(DTO)、`Knot.Extract.HiedbFacts`(兩個旗標的計算)→ **Level 2 契約變更**
- **graph-core**:`Knot.Graph.FactGate`(規則 3)
- **不影響**:module 層行為、匯出格式、查詢 CLI、`GraphStats` 欄位、索引建法

## 明確不做

- 不改 `GraphStats` 加欄位(階段二 E4 已裁定)
- 不動 `gsTopExternalTargets` 的呈現(那是另一件事,見 graph-core build-log 階段二發現 2)
- 不動 hiedb 索引建法(逐檔傳 `hieFiles` 保留,理由見「調查結果 D」)
- 不啟動 ADR-002 的第三後端(方向 A 不採用)
- 不做 `$f` 前綴的名字啟發式(方向 C 不需要)

## 實作備註

### 量化結果(2026-08-22,knot-hs 自身唯讀實跑)

| # | 量化目標 | 改善前 | 改善後 | 驗收 |
|---|---|---|---|---|
| 1 | decl 節點中的 deriving 字典 | 106 個(佔 623 的 17%) | **0** | ✅ |
| 2 | `unresolved reference target $f…` 警告 | 19 則 / 25 筆邊 | **0** | ✅ |
| 3 | 兩種索引建法產出的圖 | 差 8 節點 / 33 邊 | **byte-for-byte 相同** | ✅ |
| 4 | 既有測試零回歸、決定性不變 | 134 綠 | **138 綠**(+4 新增),兩次輸出位元相同 | ✅ |

整圖由 **654 節點 / 2267 邊** 收斂為 **548 節點 / 1948 邊**;`gsFilteredGenerated` 由 846 增為 **1206**(= 846 站點 + 106 宣告 + 254 目標,三者無重疊)。stderr 只剩統計行,零警告。唯讀約束仍成立(`--db` 改道時目標專案不建 `.knot/`)。

目標 3 的取證方式:同一份 `.hie` 分別用 `hiedb index <目錄>`(631 defs / 114 個 `$f`)與 knot 逐檔傳 `hieFiles`(623 defs / 106 個 `$f`)建索引,兩者跑出的 `codegraph.json` `cmp` 完全相同;唯一差異落在內部統計 `gsFilteredGenerated`(1214 vs 1206),那是「濾掉幾筆事實」的計數,不是圖的內容。

### 實作決策(文檔未定、由實作者裁量的部分)

1. **新增一條 `decls` 查詢而非改寫既有的 `qRefs` join**:`qRefs` 那條 `LEFT JOIN decls` 要的是 span(解 `frFromDecl`),本判準要的是「有沒有這一列」,兩者的鍵與結果形狀都不同,合併只會讓兩個用途互相牽制。新查詢在 knot-hs 自身是 711 列,成本可忽略。
2. **降級多加一道「整張表為空」的保護**:除了文檔定案的「查詢失敗 → 旗標全 `False`」,實作把「`decls` 查得到但零列」也導向同一條降級路徑。理由:那代表上游 hiedb 不再填 `decls`,而不是「這個專案全部都是產生碼」;不擋的話整個 decl 層會被靜默清空,正是本次優化最該避免的失敗模式。
3. **module → `hieFile` 反查遇到同名 module 時存 `Nothing`**:判不出來就保守放行(旗標 `False`),寧可留下一個 deriving 字典節點,也不誤殺手寫宣告。
4. **`SourceDecls` / `isGeneratedName` / `unavailableSourceDecls` 匯出到測試面**:比照本模組既有的 `parseOcc` / `pickFromDecl` 慣例,讓判準與降級行為可純函數測試。這三個符號與 G-E001 要收斂的「僅為測試而匯出」屬同一類,一併納入該文檔的處理範圍時再收。

### 未動到的東西(複查)

`GraphStats` 欄位、`gsTopExternalTargets` 呈現、module 層行為、`codegraph.json` 格式、查詢 CLI、hiedb 索引建法(逐檔傳 `hieFiles` 與 extraction/F003 W3 的幽靈 `.hie` 防護)全部未變更。ADR-002 的第三後端未啟動。
