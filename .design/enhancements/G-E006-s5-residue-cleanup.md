---
id: G-E006
type: enhance
title: s5-residue-cleanup
description: 清掉 S5 砍掉的概念在註解、匯出清單與功能規劃表裡的殘影
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-006]
related-feature: [graph-core/F001, extraction/F005, extraction/F007, export-query/F005]
subsystems: [extraction, graph-core]
---

# G-E006: S5 殘留清理

## 現況分析

2026-08-23 的全案分析(E001 收尾後)對照 ADR-006 逐一檢查 S5 砍掉的概念,三處還留著
「S5 之前的世界」的痕跡。三處都不影響執行結果,但會誤導下一個讀者。

### (1) `BuildOptions.moduleOnly` 的註解還指向已廢除的 CLI 旗標

`src/Knot/Graph/Types.hs:31-35`:

```haskell
-- | 建圖選項。@moduleOnly@ 對應 CLI @--module-only@:只出 module 節點與
-- imports 邊(組裝規則 6)。
data BuildOptions = BuildOptions
  { moduleOnly :: Bool
  }
```

`--module-only` 已於 S5 移除(export-query/F005、ADR-006 決策 4),`app/Knot/App/Cli.hs:227`
的 `toBuildOptions _ = BuildOptions { moduleOnly = False }` 恆填 `False`,並在 `:224-226`
註明「保留並固定填 `False`,不越界去 graph-core 刪欄位」。欄位本身是 graph-core 組裝
規則 6 的契約面(`.design/subsystems/graph-core/design.md`「對外契約」),library 呼叫者
仍可用,**保留是對的**;錯的是註解把它說成 CLI 旗標的對應物。

同一個檔案 `src/Knot/Graph.hs:44-45` 的規則 6 註解還寫著「本階段兩個取值輸出相同
(尚無 decl 事實)」——那是 graph-core 階段一(F001)的狀態,decl 事實自 F002 起就有了。

`design.md` 的 DTO 區塊(graph-core「對外契約」)同樣寫 `-- 對應 CLI --module-only`。

### (2) `HieLayout` 從契約模組匯出

`src/Knot/Extract/Types.hs:28` 把 `HieLayout (..)` 列在「對外契約」匯出小節;
`:127-133` 是它的定義。但 `.design/subsystems/extraction/design.md`「模組間公開介面」
把它定為 **build-driver → hie-index 的模組間介面**(`ensureHie` 的產物、`ensureIndex`
的輸入),不在「對外契約」章節。

後果:公開 `library` re-export `Knot.Extract.Types`(ADR-004),`HieLayout` 因此對
executable 可見——組裝層拿得到一個它永遠用不到、且語意上屬於 extraction 內部管線
的型別。實際消費者只有三個內部模組與測試:

- `src/Knot/Extract/BuildDriver.hs:58, 182, 190, 228`(產生者)
- `src/Knot/Extract/HieIndex.hs:73, 147, 164`(消費者)
- `src/Knot/Extract/Pipeline.hs:37, 47, 49`(`Stages` 記錄的欄位型別)
- `test/Main.hs:153, 857, 1267-1466, 5748, 5807`(F006 / F007 / F005 的 1-to-1 測試)

`app/` 零引用。

### (3) extraction 功能規劃表的階段一、二列沿用 S5 之前的措辭

`.design/subsystems/extraction/design.md`「功能規劃」:

| # | feature | 一句話說明(現文) | 模組欄(現文) |
|---|---|---|---|
| 1 | fact-contract | 「Fact DTO、**後端抽象介面、能力分級、auto 選擇與降級合成**」 | `backend-select` |
| 2 | import-scan | 「**T0 後端**:import 行解析…」 | `import-scan` |
| 3 | hiedb-driver | 「hiedb **探測**、相容檢查、index 呼叫…」 | `hiedb-driver` |
| 4 | hiedb-facts | 「讀 SQLite 出 decl/ref 事實、fromDecl 解析」 | `hiedb-facts` |

「後端抽象介面、能力分級、auto 選擇與降級、探測」全是 S5 廢除的概念;`backend-select`
與 `hiedb-driver` 兩個模組名已分別改為 `fact-pipeline` 與 `hie-index`(同一份
`design.md`「內部模組劃分」)。這四列是歷史紀錄、`doc` 欄指向的 F001–F004 也都 done,
**列本身要留**(`scan-status.mjs` 靠它算進度、契約卡靠 slug 對上);缺的是一個「這列描述
的是重構前的樣子、現由 #7 取代」的標註。

## Scope(涵蓋範圍)

開發者 2026-08-23 指定三項,照單處理:

**動**:

- graph-core:`src/Knot/Graph/Types.hs` 的 `BuildOptions` Haddock、`src/Knot/Graph.hs`
  規則 6 註解、`.design/subsystems/graph-core/design.md` DTO 區塊的同一句註解。
  **欄位不動、簽名不動、行為不動**
- extraction:`HieLayout` 的**定義**從 `Knot.Extract.Types` 搬到 `Knot.Extract.BuildDriver`
  (產生者),並從 `Knot.Extract.Types` 匯出清單移除;`HieIndex` / `Pipeline` / 測試改
  import 來源;`design.md`「模組間公開介面」加一句「定義在 build-driver 模組,不是契約模組」
- extraction:`design.md`「功能規劃」階段一、二的四列加「S5 已重構」標註(一句話說明與
  模組欄各加註,列、slug、doc 欄不動)

**明確不動**:

- `BuildOptions.moduleOnly` 欄位與 graph-core 組裝規則 6(契約面,library 呼叫者可用)
- `HieLayout` 的欄位、`ensureHie` / `ensureIndex` 簽名、`Stages` 記錄
- CLI 旗標、任何執行期行為、黃金檔
- 排除的「順便改」(另案):
  - `ExtractOptions.rootDir` / `ExportOptions.rootDir` / `MetaOptions.root` 三個 Options
    DTO 欄位無前綴、兩種名字,`Cli.hs:13` 得靠 qualified import 繞——改名是三個子系統的
    契約變更,不在本次
  - `Knot.Extract.Types.QualName` 與 `Knot.Query.Types.QueryNode` 共用 `qn` 欄位前綴——
    兩者不同子系統、從不同時 import,改名收益小
  - `test/Main.hs` 單檔 6,000 行拆分——維護性議題,與 S5 殘留無關

對外契約:graph-core 不變;extraction 的**對外契約**(`extract` 與其 DTO)不變,
`Knot.Extract.Types` 的匯出清單縮小一個**非契約**符號——公開 library 的可見面因此
**縮小**,沒有既有呼叫端受影響(`app/` 零引用)。

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| `src/` 與 `.design/` 中指向已廢旗標 `--module-only` 的現行描述 | `Graph/Types.hs:31`、`Graph.hs:44`、graph-core `design.md` DTO 註解 | **0 處**(歷史文檔與 G-E005 不算:它們記的就是當時) |
| `Knot.Extract.Types` 匯出的非契約符號 | 1(`HieLayout`) | **0**;`HieLayout` 由 `Knot.Extract.BuildDriver` 匯出 |
| extraction 功能規劃階段一、二列的 S5 標註 | 0/4 | **4/4** |
| 測試 | 144 綠、黃金檔 byte 不變 | 144 + 本文檔新增 綠、黃金檔 byte 不變 |
| `scan-status.mjs` | 0 不一致、extraction 7/7 | 不變(表結構不動) |

## 相依性

`depends-on: []`。三項都是註解 / 匯出清單 / 文檔措辭,不依賴任何進行中的任務;
與 extraction 階段四的 `implements` feature(另案)互不相干,可平行。

回鏈的 feature:`graph-core/F001`(`BuildOptions` 首次定義)、`extraction/F005`
(`HieLayout` 首次定義,放進 `Types.hs` 是該 feature 的實作選擇)、`extraction/F007`
(契約收斂時未一併把 `HieLayout` 移出)、`export-query/F005`(砍掉 `--module-only`)。

## 改善方案

### M1 `moduleOnly` 註解(graph-core)

`Graph/Types.hs` 的 Haddock 改為「library 呼叫者的建圖選項:`True` 只出 module 節點與
`imports` 邊(組裝規則 6)。CLI 自 S5 起恆填 `False`(兩層缺一不可,ADR-006);欄位保留給
直接呼叫 `buildGraph` 的消費端」。`Graph.hs:44-45` 刪「本階段兩個取值輸出相同」句。
`design.md` DTO 註解同步。

### M2 `HieLayout` 搬家(extraction)

1. `Knot.Extract.BuildDriver`:把 `data HieLayout`(含 Haddock)搬進來,放在
   `enumerateHie` 之前;匯出清單加 `HieLayout (..)`;刪除對 `Types` 的 `HieLayout (..)` import
2. `Knot.Extract.Types`:刪定義與匯出;`:38` ExtractOptions 的 Haddock 提到 `'HieLayout'`
   的字樣改為「`.knot/` 內各 repo 相對路徑」(不再有可連結的同模組符號)
3. `Knot.Extract.HieIndex`、`Knot.Extract.Pipeline`:`HieLayout` 改從 `Knot.Extract.BuildDriver`
   import(Pipeline 已 import BuildDriver?——實查:Pipeline **不** import BuildDriver,它以
   `Stages` 記錄注入;新增一行 `import Knot.Extract.BuildDriver (HieLayout (..))` 不會形成環:
   BuildDriver 只依賴 `Types` 與 `Meta.Types`)
4. `test/Main.hs:153` 從 `Knot.Extract.Types` 的 import 清單移除 `HieLayout (..)`,改由
   `Knot.Extract.BuildDriver` 取;`XT.HieLayout` 的五處改為新的限定名
5. `design.md`「模組間公開介面」在 `data HieLayout` 區塊後加註定義位置

### M3 功能規劃標註(extraction)

四列的「一句話說明」欄前綴 `(S5 前,已由 #7 重構)`,模組欄改為
`backend-select(今 fact-pipeline)` / `hiedb-driver(今 hie-index)`;階段一、二標題後
加一句說明。表格欄位數與 `doc` 欄不動,`scan-status.mjs` 的解析不受影響。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data BuildOptions = BuildOptions { moduleOnly :: Bool }` | `src/Knot/Graph/Types.hs:33-36` | graph-core/F001 | M1 只改其 Haddock |
| `data HieLayout = HieLayout { hlRoot :: FilePath, hlFiles :: [(ComponentRef, FilePath)] }` | `src/Knot/Extract/Types.hs:129-133` | extraction/F005 | M2 搬移對象 |
| `ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)` | `src/Knot/Extract/BuildDriver.hs:228` | extraction/F005 | M2 產生者,簽名不動 |
| `ensureIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure IndexHandle)` | `src/Knot/Extract/HieIndex.hs:164` | extraction/F006 | M2 消費者,簽名不動 |
| `exportGroups :: FilePath -> IO [(Text, Text)]`(測試 helper:符號 → 所屬匯出小節) | `test/Main.hs:5508` | G-E001 | T2 驗證匯出清單 |

## 介面變動

| 變動 | 層級 | 受影響呼叫端 |
|---|---|---|
| `Knot.Extract.Types` 匯出清單**移除** `HieLayout (..)` | 模組匯出(非 Level 2 對外契約;design.md 本來就把它列在模組間介面) | `HieIndex`、`Pipeline`、`test/Main.hs`——全部改 import 來源 |
| `Knot.Extract.BuildDriver` 匯出清單**新增** `HieLayout (..)` | 模組匯出 | 同上 |
| 其餘 | 無簽名、無欄位、無行為變動 | — |

Level 2 文檔更新:extraction `design.md`(模組間介面加註、功能規劃標註)、graph-core
`design.md`(DTO 註解)。Level 1 不動。

## TodoList

- [x] T1: graph-core——`Graph/Types.hs` `BuildOptions` Haddock、`Graph.hs` 規則 6 註解、graph-core `design.md` DTO 註解三處改寫  `dep: -`
- [x] T2: extraction——`HieLayout` 定義與匯出搬到 `BuildDriver`,`Types` 移除,`HieIndex` / `Pipeline` / 測試改 import,`design.md` 模組間介面加註  `dep: -`
- [x] T3: extraction——`design.md` 功能規劃階段一、二四列加 S5 標註  `dep: -`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e006_module_only_not_cli` | `src/Knot/Graph/Types.hs`、`src/Knot/Graph.hs`、graph-core `design.md` 不含字串 `--module-only`;`Graph.hs` 不含「尚無 decl 事實」 |
| T2 | `test_e006_hie_layout_not_contract` | `exportGroups "src/Knot/Extract/Types.hs"` 查無 `HieLayout`,檔案內容不含 `HieLayout`;`exportGroups "src/Knot/Extract/BuildDriver.hs"` 含 `HieLayout`;既有 F005 T1/T4、F006、F007 測試全綠(行為回歸) |
| T3 | `test_e006_roadmap_rows_annotated` | extraction `design.md` 功能規劃 #1–#4 四列每列含 `S5`;`scan-status.mjs` 對 extraction 仍算出 7/7 |
| 全部 | 既有 `test_codegraph_output_unchanged`、`test_cabal_contract_surface`、`test_app_imports_within_contract` | 黃金檔 byte 不變;契約模組清單不變;組裝層 import 仍在契約內 |

## 實作備註

### 2026-08-23 實作完成

**量化結果**(對照「改善目標」):

| 指標 | 改善前 | 改善後 |
|---|---|---|
| `src/` 與 `.design/` 中指向 `--module-only` 的現行描述 | 3 處 | **0 處**(T1 文字守門:`Graph/Types.hs`、`Graph.hs`、graph-core `design.md` 均不含該字串) |
| `Knot.Extract.Types` 匯出的非契約符號 | 1(`HieLayout`) | **0**;`HieLayout` 由 `Knot.Extract.BuildDriver` 定義並匯出(T2) |
| extraction 功能規劃階段一、二列的 S5 標註 | 0/4 | **4/4**,`doc` 欄 F001–F004 原樣(T3) |
| 測試 | 144 綠 | **147 綠**(+3);黃金檔 byte 不變;`-Wall` 零警告 |
| `scan-status.mjs` extraction | 7/7 | 8/8 契約卡、7/8 done(多出的 1 是同日立案的 F008,與本文檔無關) |

**實作取捨**:

- `Knot.Extract.Pipeline` 原本的模組註解寫「不 import 任何一站的模組」;`HieLayout` 搬到
  build-driver 後,`Stages` 的欄位型別得向 build-driver 取,因此 Pipeline 多了一行
  `import Knot.Extract.BuildDriver (HieLayout)`。這是**純型別相依**(不呼叫 build-driver 的
  任何函數),BuildDriver 不 import Pipeline,沒有環;註解已改寫為「不呼叫任何一站的
  函數,唯一例外是向 build-driver 取 `HieLayout` 型別」。替代作法(把 `HieLayout` 放進
  第三個小模組)會為一個型別多開一個檔,不值得
- 測試端:`test/Main.hs` 對 `HieLayout` 的 15 處限定名由 `XT.` 改為 `BD.`
  (`import qualified Knot.Extract.BuildDriver as BD`),並把 `HieLayout (..)` 併進既有的
  非限定 `Knot.Extract.BuildDriver` import,讓 F005 / F006 原本裸用的 `hlFiles` / `hlRoot`
  不必逐處改
- T1 的文字守門第一次就抓到我自己改寫的 `Graph.hs` 註解(句子裡原樣寫了已廢旗標名)
  ——守門的價值在此;註解改為「對應的旗標已廢」

**未動的範圍確認**:`BuildOptions.moduleOnly` 欄位、`ensureHie` / `ensureIndex` 簽名、
`Stages` 欄位、CLI、黃金檔均未變;排除的三項「順便改」(`rootDir` 無前綴、`qn` 前綴
撞名、`test/Main.hs` 拆分)未碰。
