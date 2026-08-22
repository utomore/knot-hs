---
id: F007
type: feature
title: two-layer-contract
description: 契約收斂為 Either ExtractFailure,fact-pipeline 兩層全有全無,移除探測與降級
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, F002, F004, F005, F006, project-meta/F001, graph-core/F001]
related-adr: [ADR-006]
related-feature: [F003]
---

# F007: two-layer-contract — 兩層缺一不可的契約收斂

## 功能概述

ADR-006 在 extraction 側的最後一塊:把 S1 留下的「後端註冊表 → 探測 → 選擇 → 降級合成」整層拆掉,換成**固定四站、全有全無**的 fact-pipeline。對外契約從 `IO ExtractResult` 改為 `IO (Either ExtractFailure ExtractResult)`:兩層(import-scan 的 module 層、hie-index + hie-facts 的 decl 層)**都成立**才回 `Right`;任一層整體拿不到回 `Left`,**不產出部分事實流**。使用者可見的概念(`--backend`、能力等級、降級報告)自此在 library 層沒有對應物——旗標本身由 export-query 的 cli-zero-setup 砍。

F005(build-driver)與 F006(hiedb-embed)已各自落地,但仍透過 F006 的**過渡期轉接器**(`hiedbBackend` 把 `ensureHie → ensureIndex → readIndexFacts` 塞進 `Backend.bRun`,失敗用例外丟)掛在舊引擎上。本 feature 把轉接器連同 `Knot.Extract.Backend` 一起拆掉。

**驗收標準**(契約卡逐條對照;第 1 條依 2026-08-22 裁決調整):

| # | 契約卡 | 落地 | 測試 |
|---|---|---|---|
| 1 | `Knot.Extract.Types` 匯出清單不含任何廢除型別;`src/` 與 `app/` 全部編譯通過 | **本 feature 只保證 `src/`(`knot-internal`)編譯通過**;`app/` 的編譯與 `cabal clean` 閘門由 S5 三件套(本 feature + export-query/F005 + project-meta/F004)同批落地後的共同閘門承擔——理由與順序見「相依性」 | T1、T2 |
| 2 | `build-driver` 回 `BuildFailed` 時 `extract` 回 `Left` 且**零事實**(不是「只有 import 事實」) | `Left` 不帶 `ExtractResult`,型別上就不可能夾帶事實;以假階段與 `broken-build` fixture 雙重驗證 | T4、T5 |
| 3 | 納入範圍零檔 → `NoSources` | 管線第一步就判,**不呼叫 cabal** | T4 |
| 4 | 兩層都成立時 `erFacts` 同時含 `FactModule` / `FactImport` / `FactDecl` / `FactRef` | `buildable` fixture 的完整鏈 | T5 |
| 5 | 對 knot-hs 自身跑完整管線,節點數不低於 S3 閘門的 548 | selfcheck 以 `buildGraph` 計節點 | T7 |
| 6 | 五份黃金檔(G-E001)的 module 層輸出 byte 不變 | 黃金 fixture 全部不可建置(`graph` 是刻意壞的),改走模組介面 `scanImports` + `buildGraph`,不經 `extract` | T6 |
| 7 | 同輸入兩次結果相同 | selfcheck 跑兩次逐欄比對 | T7 |
| 8 | `test_included_scope`(G-B001)的斷言沿用:後端收到完整清單、但產出的事實不提及被排除的檔 | 前半改以可注入階段捕捉 `ProjectMeta`,後半直接呼叫 `scanImports` | T3 |

## 相依性

`depends-on: [F001, F002, F004, F005, F006, project-meta/F001, graph-core/F001]`,全部由「使用到的既有串接介面」表反推:

- **F005 / F006**:`ensureHie` 與 `ensureIndex` 是管線的第二、三站,`HieLayout` / `ExtractFailure` 是站與站之間的型別;F006 的過渡轉接器是本 feature 要拆的東西。兩者皆 `done`
- **F004**:`readIndexFacts` 是第四站,簽名與查詢邏輯**不動**;但 `HiedbFacts.hs` 裡的 `hiedbBackend` / `runHiedb` / `renderFailure` / `HiedbFactsError` 由本 feature 刪除
- **F002**:`runImportScan`(私有)就是契約的 `scanImports`,本 feature 只改名匯出、刪 `importScanBackend`
- **F001**:`Fact` 的 `Ord`(全序排序)、`ExtractWarning`;`importScanName` / `hiedbName` 兩個常數搬家
- **project-meta/F001**:`ProjectMeta.pmSources` 與 `SourceFile.sfIncluded` 是 `NoSources` 判定的依據
- **graph-core/F001**:**僅驗收測試使用**——契約卡的「節點數不低於 548」只有 `buildGraph` 算得出來;production 程式碼沒有 extraction → graph-core 的引用(拓撲方向不變)

**不列入的相依**:`F003` hiedb-driver 列在 `related-feature`——它已被 F006 取代,本 feature 只是把最後一個引用它概念(`Backend`)的地方清掉。

**可平行性與實作順序(重要)**:

1. **設計可平行、實作不可單獨驗證。** 本 feature 砍掉 `ExtractOptions.backendChoice` / `hiedbExe` / `dbPath` 與 `ExtractResult.erLevel` / `erReports` 後,`app/Knot/App/{Cli,Report,Summary}.hs` 的 19 處引用會編不過——這是契約卡預期的。但 **`test-suite knot-test` 的 `hs-source-dirs` 含 `app`**(`knot-hs.cabal`:`other-modules: Knot.App.Cli …`),所以不只 exe,**本 feature 的測試也要等 export-query/F005 把 `app/` 對映改完才跑得起來**
2. 順序(export-query/F005 設計時裁定):`/feature-impl extraction/F007`(改 `src/` + 改寫 `test/Main.hs`,以 `cabal build knot-hs:knot-internal` 驗證 library 可編)→ `/feature-impl project-meta/F004`(刪 `pmHie` / `hieDirOverride` 等;先於 CLI 是因為 `toMetaOptions` 不填已刪欄位在 `-Wall -Werror` 下是 missing-fields 錯誤)→ `/feature-impl export-query/F005`(改 `app/`,此時整套測試首次可跑)→ 共同閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror`
3. 三者在**同一條分支**連續做完再跑閘門;中間狀態不得宣告任何一個 `done`

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 對外契約 `extract :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)` | 新簽名,一字不差 |
| DTO `ExtractOptions { rootDir }` | 刪 `backendChoice` / `hiedbExe` / `dbPath`(F006 起已零消費者) |
| DTO `ExtractResult { erFacts, erWarnings }` | 刪 `erLevel` / `erReports` |
| DTO `ExtractFailure` 的 `NoSources` | 由 fact-pipeline 產生;`IndexFailed` 在 decl 層零事實時也由 fact-pipeline 產生(規則 3 的判準,見下) |
| 模組介面 `scanImports :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])` | `ImportScan.runImportScan` 改名匯出,簽名已經相同 |
| **移除** `Backend`、`ProbeResult`、`BackendChoice`、`CapabilityLevel`、`BackendReport` | `Knot.Extract.Backend` 整個模組刪除;`Types.hs` 刪三個型別 |
| 抽取規則 2(來源職責互斥) | 管線固定:module 層事實只來自 `scanImports`,decl 層只來自 `readIndexFacts`;沒有第二個來源可混 |
| 抽取規則 3(兩層缺一不可) | `runPipeline` 的全有全無;**decl 層「成立」的判準 = `readIndexFacts` 至少讀出一筆 `FactDecl`**(2026-08-22 裁決,回寫 design.md 規則 3) |
| 抽取規則 9(單檔 best-effort 與整體失敗的分界) | 四站各自的單檔警告原樣併入 `erWarnings`;整體失敗只走 `Left` |
| 抽取規則 10(決定性) | `erFacts` 全序排序(`Fact` 的 `Ord`),`erWarnings` 依站序固定 |

**未觸碰**:`Fact` / `QualName` / `NameSpace` / `DeclKind` / `ExtractWarning`(卡的明確不做);`readIndexFacts` 的查詢與解析;`ensureHie` / `ensureIndex`;CLI 旗標(export-query/F005)。

## 實作方式

### 模組

`Knot.Extract.Backend` 刪除,新模組 **`Knot.Extract.Pipeline`** 承接 fact-pipeline 的職責(`knot-internal` 的 `exposed-modules` 一進一出,G-E001 的守門計數 27 / 18 不變;不進公開 library 的 `reexported-modules`)。

```haskell
module Knot.Extract.Pipeline
  ( -- * 可注入的四站(非契約面:僅為 1-to-1 測試而匯出,與 F001 的 runBackends 同模式)
    Stages (..)
  , runPipeline
  ) where

-- 對索引控制代碼型別多型:IndexHandle 的建構子不匯出(F006),
-- 假階段用 h = () 就能測全有全無邏輯,不必真的建索引
data Stages h = Stages
  { stScan  :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
  , stBuild :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)
  , stIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure h)
  , stFacts :: h -> ProjectMeta -> IO ([Fact], [ExtractWarning])
  }

runPipeline :: Stages h -> ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)
```

`Knot.Extract.extract` 只剩一行:把真實四站(`scanImports` / `ensureHie` / `ensureIndex` / `readIndexFacts`)裝進 `Stages` 交給 `runPipeline`。`Pipeline` 本身只 import `Knot.Extract.Types` 與 `Knot.Meta.Types`,不認識任何一站的模組——四站模組也不 import 它,沒有環。

**常數搬家**:`importScanName` 移到 `Knot.Extract.ImportScan`、`hiedbName` 移到 `Knot.Extract.HieIndex`(`HiedbFacts` 本來就 import `HieIndex`)。兩者仍標「非契約面」——`ewSource` 的**值域**是契約,具名常數不是(G-E004 的對帳表要同步改指新位置)。

### 資料流(`runPipeline`)

```
ExtractOptions + ProjectMeta
  │
  ├─ 0. 納入範圍:included = filter sfIncluded (pmSources pm)
  │      included 為空                                  → Left NoSources        (不呼叫任何一站,尤其不叫 cabal)
  │
  ├─ 1. stScan  → (moduleFacts, scanWarns)              (單檔失敗已在站內轉警告;本站不會 Left)
  │
  ├─ 2. stBuild → Left f                                → Left f                 (BuildFailed;零事實)
  │             → Right layout
  │
  ├─ 3. stIndex opts layout → Left f                    → Left f                 (VersionMismatch / IndexFailed;零事實)
  │             → Right h
  │
  ├─ 4. stFacts h pm → (declFacts, factWarns)           (ihNotes 已由 readIndexFacts 併在 factWarns 開頭,本站不重複加)
  │      declFacts 內零筆 FactDecl                      → Left (IndexFailed detail) (規則 3 的 decl 層判準;detail 見錯誤處理)
  │
  └─ 5. Right ExtractResult
         { erFacts    = sort (moduleFacts <> declFacts)   -- 規則 10:全序,不受站序影響
         , erWarnings = scanWarns <> factWarns }          -- 站序固定:import-scan 在前
```

站 1 在站 2 之前的理由:`NoSources` 與 import-scan 的警告都不需要建置,先做能讓「零檔」「全部讀不到」這類情況在幾毫秒內結束,而不是先等 cabal。

### 錯誤處理

| 情況 | 結果 |
|---|---|
| 納入範圍零個原始檔 | `Left NoSources`,任何一站都不跑 |
| `ensureHie` / `ensureIndex` 回 `Left` | 原樣往上,不包裝、不改寫訊息(CLI 渲染是 export-query/F005 的事) |
| `readIndexFacts` 回零筆 `FactDecl`(索引檔開不了、`mods` / `defs` 查詢失敗、全部 `.hie` 單檔失敗) | `Left (IndexFailed detail)`;`detail` = 固定前綴 `"the index yielded no top-level declarations"` + 該站全部警告依序以 `"; "` 串接的 `ewSource: ewMessage`。警告序由規則 10 保證,所以 `detail` 也決定性 |
| 某一站拋出例外 | **不在管線層包 `try`**。四站的契約都是「不拋例外」(F002 逐檔 `try`、F005 收斂 `IOException`、F006 / F004 收斂 `SomeException`);逃出來的例外是該站的 bug,不是一種要渲染的失敗——`ExtractFailure` 也沒有對應的建構子,硬包只會把 bug 偽裝成「建置失敗」 |
| 單檔層級(各站自報的警告) | 原樣進 `erWarnings`,仍 `Right`(規則 9 的分界) |

### 測試搬遷(T6 的實質內容)

**刪除**(它們測的是被廢除的機制):F001 的 `test_probe_and_select`、`test_fact_synthesis`、`test_extract_entry_registry`、`test_backend_iface_construct` 與假後端輔助(`fakeOk` / `fakeUnavailable` / `fakeRunBoom` / `tracingBackend` / `reportFor` / `extOpts`);F002 的 `test_import_scan_backend_value`;F004 的 `test_hiedb_backend_registered`、`test_hiedb_backend_live`、`test_hiedb_db_flags`;F006 的 `test_hiedb_backend_adapter`。

**改寫**:`test_extract_types_construct`(T1)、`test_included_scope`(T3)、`test_codegraph_output_unchanged`(改走 `scanImports` + `buildGraph`)、G-E004 的 `test_backend_constant_labels` 與 `contractLabelTable`(改指 `Pipeline.hs` / `ImportScan.hs` / `HieIndex.hs`)、`test_cabal_contract_surface` 的註解(計數不變)。

**其餘 `extract` 呼叫點**(graph-core / export-query 的測試共十餘處,多數拿不可建置的 fixture 只取 module 層):改為呼叫 `scanImports` 組 `ExtractResult { erFacts, erWarnings }` 餵 `buildGraph`——它們要的本來就只是 module 層事實,不該為此去建置一個刻意壞掉的 fixture。只有 `buildable` / knot-hs 自身的測試保留走 `extract`。

**export-query/F004 的 CLI 測試**(`test_extract_options_mapping`、`test_run_extract`、`test_render_fact_summary` 等)由 export-query/F005 改,本 feature 不碰。

### 刻意的選擇

- **`Stages` 對控制代碼型別多型**而不是匯出 `IndexHandle` 的建構子:F006 把它定為不透明是有意的,測試不該因為想注入假階段就打破
- **decl 層零事實判失敗、module 層不另設判準**:import-scan 全部檔案讀不到的情況下 cabal 也建不起來(同一批檔案),自然落到 `BuildFailed`;為它再發明一個建構子沒有意義
- **`Left` 不附帶已蒐集的警告**:契約的 `ExtractFailure` 四個建構子都不帶警告欄,而 cabal 的輸出已由 build-driver 即時轉發到 stderr(規則 5),使用者看得到失敗原因;把警告塞進 `detail` 只會讓 `BuildFailed` 的文字不決定性

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `runImportScan :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])`(私有) | `src/Knot/Extract/ImportScan.hs` | F002 | 改名匯出為契約的 `scanImports`;管線第一站 |
| `importScanBackend :: Backend` | `src/Knot/Extract/ImportScan.hs` | F002 | 刪除 |
| `ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)` | `src/Knot/Extract/BuildDriver.hs:228` | F005 | 管線第二站 |
| `data HieLayout = HieLayout { hlRoot :: FilePath, hlFiles :: [(ComponentRef, FilePath)] }` | `src/Knot/Extract/Types.hs` | F005 | 第二→第三站的載體 |
| `data ExtractFailure = BuildFailed { bfComponent :: Text, bfDetail :: Text } \| VersionMismatch { vmHie :: Text, vmKnot :: Text } \| IndexFailed { ifDetail :: Text } \| NoSources` | `src/Knot/Extract/Types.hs` | F005 | 管線產生 `NoSources` 與(decl 層零事實的)`IndexFailed`;其餘原樣透傳 |
| `ensureIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure IndexHandle)` | `src/Knot/Extract/HieIndex.hs:158` | F006 | 管線第三站 |
| `ihNotes :: IndexHandle -> [ExtractWarning]` | `src/Knot/Extract/HieIndex.hs` | F006 | 確認它已由 `readIndexFacts` 併入回傳,管線不重複加 |
| `readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])` | `src/Knot/Extract/HiedbFacts.hs:144` | F004 | 管線第四站;簽名與邏輯不動 |
| `hiedbBackend :: Backend`、`runHiedb :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])`、`renderFailure :: ExtractFailure -> Text`、`newtype HiedbFactsError = HiedbFactsError Text` | `src/Knot/Extract/HiedbFacts.hs:90–132` | F006 | 過渡期轉接器,全部刪除 |
| `data Backend = Backend { bName :: Text, bLevel :: CapabilityLevel, bProbe :: …, bRun :: … }`、`data ProbeResult = Available \| Unavailable Text`、`runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult`、`importScanName :: Text`、`hiedbName :: Text` | `src/Knot/Extract/Backend.hs` | F001 | 模組整個刪除;兩個常數搬家 |
| `data Fact = FactModule {…} \| FactImport {…} \| FactDecl {…} \| FactRef {…} \| FactInstance {…}`,`deriving (Eq, Ord, Show)` | `src/Knot/Extract/Types.hs` | F001 | `Ord` 供 `erFacts` 全序排序;`FactDecl` 建構子供 decl 層判準 |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` | `src/Knot/Extract/Types.hs` | F001 | 併接各站警告;`IndexFailed` 的 `detail` 由此渲染 |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }`、`data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | `src/Knot/Meta/Types.hs:29,65` | project-meta/F001 | `NoSources` 判定:`filter sfIncluded (pmSources pm)`(不碰 `pmHie`,它由 project-meta/F004 移除) |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | `src/Knot/Graph.hs:37` | graph-core/F001 | **僅測試**:T6 黃金檔與 T7 節點數 ≥ 548 |

**守門測試**(非介面,但本 feature 必須維持):`test_cabal_contract_surface`(`test/Main.hs:5437,5443`)斷言 `knot-internal` 27 個 `exposed-modules`、18 個私有模組——`Backend` → `Pipeline` 一進一出後兩數不變。

## 新增的介面

全部落在 `design.md` 已定義的條目內:

```haskell
-- Knot.Extract(對外契約;新簽名)
extract :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)

-- Knot.Extract.Types(對外契約 DTO;收斂後的形狀)
data ExtractOptions = ExtractOptions
  { rootDir :: FilePath }
  deriving (Eq, Show)

data ExtractResult = ExtractResult
  { erFacts    :: [Fact]
  , erWarnings :: [ExtractWarning] }
  deriving (Eq, Show)

-- Knot.Extract.ImportScan(模組介面;原 runImportScan 改名匯出)
scanImports :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
```

**移除**:`Knot.Extract.Backend` 整個模組(`Backend`、`ProbeResult`、`runBackends`);`Knot.Extract.Types` 的 `BackendChoice`、`CapabilityLevel`、`BackendReport`;`ImportScan.importScanBackend`;`HiedbFacts.hiedbBackend` / `runHiedb` / `renderFailure` / `HiedbFactsError`。

**非契約面(Level 3 自主)**:`Knot.Extract.Pipeline` 的 `Stages h` 與 `runPipeline`,僅為測試注入而匯出;`importScanName` 改住 `ImportScan`、`hiedbName` 改住 `HieIndex`。

## TodoList

- [ ] T1: `Knot.Extract.Types` 收斂——`ExtractOptions` 只剩 `rootDir`、`ExtractResult` 只剩 `erFacts` / `erWarnings`;刪 `BackendChoice` / `CapabilityLevel` / `BackendReport` 及其匯出;haddock 同步(`ExtractFailure` 不再說「#7 接續」)  `dep: -`
- [ ] T2: 新模組 `Knot.Extract.Pipeline`(`Stages h`、`runPipeline` 骨架)取代 `Knot.Extract.Backend`(檔案刪除、cabal 一進一出);`importScanName` 搬到 `ImportScan`、`hiedbName` 搬到 `HieIndex`  `dep: T1`
- [ ] T3: `ImportScan.runImportScan` 改名匯出為 `scanImports`、刪 `importScanBackend`  `dep: T2`
- [ ] T4: `runPipeline` 本體——`NoSources` 前置判定、`Left` 透傳、decl 層零 `FactDecl` → `IndexFailed`、`Right` 的全序排序與站序警告  `dep: T2`
- [ ] T5: `extract = runPipeline realStages`;`HiedbFacts` 刪 `hiedbBackend` / `runHiedb` / `renderFailure` / `HiedbFactsError`;`cabal build knot-hs:knot-internal` 通過  `dep: T3, T4`
- [ ] T6: 測試搬遷——刪除廢除機制的測試與假後端輔助、黃金檔測試與其餘 module 層呼叫點改走 `scanImports`、G-E004 對帳表改指新位置  `dep: T5`
- [ ] T7: selfcheck——對 knot-hs 自身跑 `extract`:`Right`、四種事實皆有、節點數 ≥ 548、兩次相同  `dep: T5`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_extract_types_construct`(改寫) | 以記錄語法建構 `ExtractOptions { rootDir }` 與 `ExtractResult { erFacts, erWarnings }` 並斷言 `Eq` / `Show`;讀 `src/Knot/Extract/Types.hs` 的匯出清單,斷言不含 `BackendChoice`、`CapabilityLevel`、`BackendReport`、`Backend`、`ProbeResult` 任一字樣 |
| T2 | `test_pipeline_module_surface` | `src/Knot/Extract/Backend.hs` 不存在;`knot-hs.cabal` 的 `exposed-modules` 含 `Knot.Extract.Pipeline`、不含 `Knot.Extract.Backend`;`test_cabal_contract_surface` 的 27 / 18 維持;`importScanName` / `hiedbName` / `runPipeline` 各自在新檔案的匯出清單中且位於標「非契約面」的區段(G-E004 的 `test_backend_constant_labels` 改寫為此) |
| T3 | `test_included_scope`(改寫,G-B001 斷言沿用) | 前半:以 `runPipeline` 注入捕捉用的 `stScan`,斷言它收到的 `ProjectMeta` 與 `loadProjectMeta` 給的**整份相等**(含被排除的條目);後半:直接呼叫 `scanImports`,產出的 `fmFile` / `fiFile` 不含任何 `sfIncluded = False` 的路徑、且 included 的有被處理 |
| T4 | `test_pipeline_all_or_nothing` | 全部用假階段(`h = ()`):(a) `pmSources` 全為 `sfIncluded = False` → `Left NoSources` 且四站**一站都沒被呼叫**(以 IORef 計數);(b) `stBuild` 回 `Left (BuildFailed …)` → 原樣 `Left`,`stIndex` / `stFacts` 未被呼叫;(c) `stIndex` 回 `Left (VersionMismatch …)` → 原樣 `Left`;(d) `stFacts` 回零筆 `FactDecl`(只有 `FactRef` 或空)+ 兩則警告 → `Left (IndexFailed d)` 且 `d` 含固定前綴與兩則警告文字、順序與給定相同;(e) 四站皆成功 → `Right`,`erFacts` 等於 `sort (module 事實 <> decl 事實)`、`erWarnings` = scan 警告 ++ facts 警告;(f) 對 (e) 把 `stScan` / `stFacts` 的回傳順序打亂,`erFacts` 不變(hedgehog property) |
| T5 | `test_extract_real_chain` | 對 `buildable` fixture(複製到暫存目錄)呼叫 `extract` → `Right`,`erFacts` 同時含 `FactModule` / `FactImport` / `FactDecl` / `FactRef`;對 `broken-build` fixture → `Left (BuildFailed c d)` 且 `d` 含 cabal 的錯誤文字;`src/Knot/Extract/HiedbFacts.hs` 的匯出清單不含 `hiedbBackend`,全檔不含 `HiedbFactsError` 字樣 |
| T6 | `test_codegraph_output_unchanged`(改寫)+ `test_no_backend_residue` | 前者:五個黃金 fixture 改以 `scanImports` 組 `ExtractResult` 餵 `buildGraph`,byte 級與黃金檔相同;後者:`test/Main.hs` 與 `src/` 全域 grep 不得出現 `runBackends`、`BackendChoice`、`ImportsOnly`、`HiedbOnly`、`erLevel`、`erReports`、`CapabilityLevel`、`BackendReport`、`hiedbBackend`、`importScanBackend`(`app/` 不在範圍,由 export-query/F005 清) |
| T7 | `test_two_layer_selfcheck` | 對 knot-hs 自身(`rootDir = "."`,不含 test)呼叫 `extract` 兩次:皆 `Right`;四種 `Fact` 建構子各至少一筆;`buildGraph` 的節點數 ≥ 548;兩次的 `erFacts` 與 `erWarnings` 逐欄相等 |

## 實作備註

(撰寫時留空)
