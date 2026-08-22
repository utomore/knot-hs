---
id: G-E001
type: enhance
title: internal-test-exports
description: 內部邊界收斂:library 公開面、重複演算法與拓樸旁路
status: done
created: 2026-08-20
updated: 2026-08-22
depends-on: []
related-adr: [ADR-004]
related-feature: [project-meta/F001, project-meta/F002, project-meta/F003, extraction/F001, extraction/F002, extraction/F003, extraction/F004, graph-core/F001, graph-core/F002, graph-core/F003, export-query/F001, export-query/F002, export-query/F003, export-query/F004]
subsystems: [project-meta, extraction, graph-core, export-query]
---

# G-E001: 內部邊界收斂(公開面、重複演算法、拓樸旁路)

## 現況分析

本段全部出自 2026-08-22 對 `src/` `app/` `test/` 的逐檔閱讀與逐符號消費者盤點,不是從既有文檔抄的。文檔累積的四次閘門發現(2026-08-20 project-meta 階段二、2026-08-20 extraction 階段一、2026-08-21 export-query 階段一與階段二)在此重新以原始碼複驗並補齊——其中**匯出面的數量比文檔記載多了 14 個**,是 extraction 階段二(HiedbDriver / HiedbFacts)與 graph-core 階段二(NodeMint)之後長出來的。

### (1) library 公開面:31 個非契約面匯出

`knot-hs.cabal` 的 `library` 把 `src/` 全部 **26 個模組**列進 `exposed-modules`,其中 17 個是子系統內部模組。逐符號查過 src / app / test 三邊消費者(已排除註解誤命中——`resolveModuleSource` 在 `src/Knot/Graph/FactGate.hs:43` 只是註解提及):

**類型一:純測試用(只有定義模組本身與 `test/Main.hs` 用)—— 21 個**

| 子系統 | 模組:符號 |
|---|---|
| project-meta | `Knot.Meta.SourceIndex`:`moduleNameFromPath`(L124)<br>`Knot.Meta.HieLocate`:`moduleNameFromHiePath`(L167) |
| extraction | `Knot.Extract.ImportScan`:`scanSource`、`stripCommentLines`、`headerModuleOf`、`importsOf`<br>`Knot.Extract.HiedbDriver`:`defaultDbPath`、`parseIndexStats`、`chunkFileArgs`<br>`Knot.Extract.HiedbFacts`:`parseOcc`、`declKindOf`、`resolveModuleSource`、`pickFromDecl`、`SourceDecls`、`unavailableSourceDecls`、`isGeneratedName` |
| export-query | `Knot.Export.Encode`:`relationText`(L131)<br>`Knot.Query.Load`:`RelationClass`、`classifyRelation`、`dependencyRelations`、`structuralRelations` |

**類型二:跨內部模組的必要匯出(Haskell 無「只對兄弟模組開放」的可見度)—— 9 個**

| 子系統 | 符號 | 誰在 src 內呼叫 |
|---|---|---|
| extraction | `Knot.Extract.Backend.runBackends` | `src/Knot/Extract.hs:8` |
| graph-core | `Knot.Graph.NodeMint`:`moduleFiles`、`disambiguate`、`moduleOfFile`、`declNodeIndex` | `src/Knot/Graph/EdgeDerive.hs:29`、`src/Knot/Graph.hs:22` |
| export-query | `Knot.Export.Encode`:`encodeCodegraph`、`statsNotes` | `src/Knot/Export.hs:16` |
| export-query | `Knot.Query.Load.parseQueryGraph`、`Knot.Query.Types.QueryNode` | `src/Knot/Query.hs:33`、`src/Knot/Query/Engine.hs:31` |

**類型三:executable 消費 —— 1 個**

`Knot.Export.Types.defaultOutputPath`(L45),由 `app/Knot/App/Cli.hs:60` import、`toExportOptions`(L271)呼叫。不是測試用,是 CLI 預設值。

三類**性質不同,收斂手段必須同時吃得下三種**:類型一想藏、類型二藏不掉(同 package 兄弟模組要呼叫)、類型三要留給 executable。這正是選型的關鍵——見「改善方案」M1。

### (2) 大寫尾綴演算法在 project-meta 內重複實作

`src/Knot/Meta/SourceIndex.hs:124-136` 與 `src/Knot/Meta/HieLocate.hs:167-179` 是同一個演算法(末段去副檔名 → 從尾端取最長的連續大寫開頭段 → `.` 連接),**逐行對照後唯一的差異是 `stripExtension "hs"` vs `stripExtension "hie"`**,連 `where upperSeg` 的兩個分支都一字不差。兩者各自帶一組 1-to-1 測試(各 6 處引用),改一邊忘另一邊不會有任何測試失敗。

### (3) 拓樸旁路:`GraphStats` 在公開 DTO 透出上游型別

`src/Knot/Export/Encode.hs:38` 的 `import Knot.Meta.Types (ModuleName (..))` 讓 export-query 的 library 直接依賴 project-meta,跳過 `system.md`「單向 in-memory 管線,無反向呼叫、**無旁路**」宣告的 `project-meta → extraction → graph-core → export-query` 順序。

source 級複查(2026-08-22)確認 **`src/` 裡跳段的 import 只有這一條**:

```text
grep -rn "^import .*Knot\.Meta\." src/Knot/Export src/Knot/Query
→ src/Knot/Export/Encode.hs:38:import Knot.Meta.Types (ModuleName (..))
```

成因不在 export-query。`src/Knot/Graph/Types.hs:79` 的公開 DTO 欄位 `gsTopExternalTargets :: [(ModuleName, Int)]` 把上游型別擺進契約,消費該契約的人被迫認識 `ModuleName`;`Knot.Export.Encode.statsNotes`(L156)只是照契約消費。

**一個文檔沒記、但會改變判斷的前提**:`extraction/design.md:123` 已裁定「`ModuleName` 直接共用 project-meta 契約的定義(`Knot.Meta.Types`,批次澄清裁定)——同一型別沿管線流動,零轉換」,graph-core 自己也照這條跨兩段用 `ModuleName`(`FactGate.hs:16`、`NodeMint.hs:33`、`EdgeDerive.hs:44`、`Graph/Types.hs:30`、`Graph.hs:31`)。所以本項不是「export-query 違規」,是「共用詞彙型別的邊界該畫在哪」——開發者拍板畫在 graph-core 的**公開 DTO** 上:內部隨便用,公開 DTO 不透出。

### (4) `Discovery` 的靜默零貢獻

`src/Knot/Meta/Discovery.hs:104-116`,`expandEntry` 的目錄分支:entry 指向存在的目錄、`listDirectory` 成功、但過濾後沒有任何 `.cabal` 時,回傳 `([], [])`——**零結果、零警告**。`missing`(L118-120)只涵蓋「目錄不存在」。全域錯誤處理原則是「不認得的資料一律列印,不靜默吞掉」,這裡違反了。

## Scope(涵蓋範圍)

2026-08-22 與開發者逐項確認的定案。

**動**(四個子系統全數):

| 項目 | 動到的子系統 | 動到的檔案 |
|---|---|---|
| A 匯出面收斂 | 四個全部 + 組裝層 | `knot-hs.cabal`、`src/Knot/Export/Types.hs`、`app/Knot/App/Cli.hs`、`test/Main.hs` |
| B 大寫尾綴去重 | project-meta | `src/Knot/Meta/SourceIndex.hs`、`src/Knot/Meta/HieLocate.hs` |
| C 拓樸旁路 | graph-core、export-query、組裝層 | `src/Knot/Graph/Types.hs`、`src/Knot/Graph.hs`、`src/Knot/Export/Encode.hs`、`app/Knot/App/Summary.hs` |
| D Discovery 警告 | project-meta | `src/Knot/Meta/Discovery.hs` |

**明確不動**:

- **各模組的 `module ... ( ... ) where` 匯出清單一律不改**(唯一例外:`Knot.Export.Types` 刪 `defaultOutputPath`、`Knot.Meta.SourceIndex` 加參數化版本)。收斂是 package 層級的可見度,不是模組層級的刪匯出
- **21 個純測試用匯出一個都不刪**,對應的 1-to-1 測試全部原樣保留
- `Knot.Graph.EdgeDerive.EdgeStats.esTopExternal` 維持 `[(ModuleName, Int)]`——graph-core 內部型別,不是公開 DTO,不在本次收斂範圍
- 不改任何演算法行為:`codegraph.json` 的輸出必須 **byte 級不變**(見驗收標準 7)
- 不碰 S3 尚未開始的 `implements` 邊、不碰 hiedb 後端邏輯
- 不引入 Backpack signature/mixin

**對外契約是否受影響**:

- **系統對外契約(Level 1)不變**:`codegraph.json` 格式、CLI 介面、exit code 全部不動
- **graph-core Level 2 契約變動一項**:`GraphStats.gsTopExternalTargets` 的型別 `[(ModuleName, Int)]` → `[(Text, Int)]`。開發者已同意回頭更新 `graph-core/design.md`
- **export-query Level 2 契約不變**:`defaultOutputPath` 本來就標為非契約面

**討論中冒出、確認排除的項目**:

- 把 `Knot.Query.Types` 也列進公開面 —— 排除,`app/` 只 import `Knot.Query`,DTO 由它 re-export 就夠
- 把 21 個純測試用匯出改由契約層測試間接涵蓋、刪掉匯出 —— 排除(ADR-004 的替代方案表已記否決理由:1-to-1 紀律會退化)
- project-meta 新增第 5 個內部模組 `path-rules` 承載共用純函數 —— 排除,改用「留在 source-index、hie-locate import」的低擾動作法

## 改善目標

把「靠註解宣告的邊界」換成「編譯期會擋的邊界」,並清掉重複實作與旁路。

**量化驗收標準**

| # | 標準 | 怎麼量 |
|---|---|---|
| 1 | library 公開模組數 26 → **9** | `knot-hs.cabal` 的 `reexported-modules` 恰為那 9 個;`knot-internal` 的 `exposed-modules` 為 26 個 |
| 2 | 非契約面匯出出現在公開面的數量 31 → **0** | 21 + 9 個隨其模組退出公開面;`defaultOutputPath` 移出 library |
| 3 | 契約違反是編譯錯誤,不是註解 | 負向驗證:exe 端 import 任一私有模組 → `GHC-87110 hidden package`(ADR-004 spike 已證) |
| 4 | `src/` 跨段 import 數 1 → **0** | `grep -rn "^import .*Knot\.Meta\." src/Knot/Export src/Knot/Query` 無輸出 |
| 5 | 大寫尾綴演算法實作份數 2 → **1** | `src/Knot/Meta/` 內 `takeWhile upperSeg` 只出現一次 |
| 6 | cabal.project 列的目錄存在但無 `.cabal` 時警告數 0 → **1** | 新增 fixture 斷言 |
| 7 | **行為零變更**:`codegraph.json` byte 級不變 | 對 `test/fixtures/` 與 MagicFarmer / particle-magic 前後比對輸出檔的 SHA |
| 8 | 建置閘門零警告 | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0 且零警告(G-E002 的唯一合法閘門指令) |
| 9 | 既有測試零退化 | `cabal test` 全綠,21 條純測試用匯出的 1-to-1 測試一條不少 |

## 相依性

`depends-on: []` —— 本文檔不依賴任何未完成的文檔,可獨立開工。查證依據:`.design/` 下全部 14 份 feature 文檔 `status: done`,G-E002 / G-E003 亦 `done`,無進行中任務(2026-08-22 掃描)。

**引用而非依賴**:

- **G-E002**:驗收標準 8 沿用它定下的閘門指令。G-E002 已 `done`,不構成前置
- **ADR-004**:本文檔的選型決策與 spike 實測證據落在該 ADR;ADR 隨本文檔同批建立,不是外部前置
- **ADR-001**:雙 library 佈局的驗證綁 GHC 9.14.1 / cabal 3.16.1.0,與版本鎖同源

**影響的文檔**(實作時要同步,列在 T6):

- `graph-core/design.md`:`GraphStats` 欄位型別(Level 2 契約變動,已獲同意)
- `project-meta/design.md`:模組間相依補一句 source-index → hie-locate
- `export-query/features/F001-json-export.md`:假設 A2 對 `defaultOutputPath` 歸屬的敘述
- `system.md`:「技術棧與環境」補雙 library 佈局

**平行開發結論**:四個子系統全動,且 T1 的 cabal 佈局改動會碰 `test/Main.hs` 的建置依賴,**不建議與任何其他任務平行**。本文檔內部則 T3 / T4 / T5 三項彼此無交集,可平行(見 TodoList 的 `dep:`)。S3(函式級抽取)開工前必須先完成本文檔,否則新模組會照舊佈局長出來、收斂成本再翻一倍。

## 改善方案

### M1 — package 佈局改為雙 library(項目 A 的主體)

`knot-hs.cabal` 改成(`build-depends` 與 `ghc-options` 沿用現值,此處只列結構):

```cabal
library knot-internal
    visibility:       private
    hs-source-dirs:   src
    exposed-modules:  <現 library 的 26 個模組原樣搬過來>
    build-depends:    <現 library 的 build-depends 原樣>
    ghc-options:      -Wall
    default-language: GHC2024

library
    reexported-modules: Knot.Meta, Knot.Meta.Types
                      , Knot.Extract, Knot.Extract.Types
                      , Knot.Graph, Knot.Graph.Types
                      , Knot.Export, Knot.Export.Types
                      , Knot.Query
    build-depends:      base ^>=4.22, knot-hs:knot-internal
    default-language:   GHC2024

executable knot
    build-depends:    base, knot-hs, optparse-applicative, text      -- 只看得到 9 個

test-suite knot-test
    hs-source-dirs:   test, app
    build-depends:    base, knot-hs:knot-internal, …                 -- 看得到 26 個
```

公開 9 個 = 四個子系統的進入點 + 對外 DTO 模組。依據是 `app/` 的實際 import(`app/Knot/App/{Cli,Report,Run,Summary}.hs` 逐檔查過,**沒有一處 import 非契約模組**),所以這 9 個就是組裝層真正需要的全部。私有 17 個:`Knot.Meta.{Discovery,CabalModel,SourceIndex,HieLocate}`、`Knot.Extract.{Backend,ImportScan,HiedbDriver,HiedbFacts}`、`Knot.Graph.{FactGate,NodeMint,EdgeDerive}`、`Knot.Export.{Encode,Commit}`、`Knot.Query.{Types,Load,Engine,Render}`。

**exe 依賴公開 library、test-suite 依賴 private sublibrary** 是這個佈局的全部價值所在:類型一與類型二的 30 個匯出隨其模組退出公開面(類型二不必藏、藏不掉,但它們的**模組**是私有的,對外就摸不到),測試照樣摸得到。

可行性不是推論,是 2026-08-22 的實測(證據表見 ADR-004):正向四項全綠,負向那項如預期在 exe 端得到 `GHC-87110: … hidden package`。

### M2 — `defaultOutputPath` 移進組裝層(項目 A 的類型三)

三類匯出裡唯一 M1 蓋不到的:它住在**契約模組** `Knot.Export.Types` 裡,模組是公開的,符號就跟著公開。

- `src/Knot/Export/Types.hs`:刪 `defaultOutputPath`(L43-46)與匯出清單的 `-- * 非契約面` 小節,`import System.FilePath ((</>))` 一併刪(刪後無其他使用者)
- `app/Knot/App/Cli.hs`:定義並匯出 `defaultOutputPath :: FilePath -> FilePath`,`import Knot.Export.Types` 改為只取 `CommitPolicy (AutoDetect)`;`toExportOptions`(L271)的呼叫改指本地定義
- `test/Main.hs`:該符號的 import 從 `Knot.Export.Types` 改到 `Knot.App.Cli`——test-suite 的 `hs-source-dirs` 已含 `app`,10 處既有引用不受影響

語意上也更正確:CLI 預設輸出路徑本來就是組裝層的事,library 不該擁有它。

### M3 — 大寫尾綴演算法去重(項目 B)

- `src/Knot/Meta/SourceIndex.hs`:`moduleNameFromPath` 的本體改為帶副檔名參數的 `moduleNameFromPathExt :: String -> FilePath -> Maybe ModuleName`,加進匯出清單的「非契約面」小節;`moduleNameFromPath = moduleNameFromPathExt "hs"` 保留為別名
- `src/Knot/Meta/HieLocate.hs`:刪 L167-179 的實作與變成無用的 import(`Data.Char (isUpper)`、`System.FilePath` 的 `stripExtension`;**`splitDirectories` 仍被 `commonAncestor` 用、不可刪**),改 `moduleNameFromHiePath = moduleNameFromPathExt "hie"`,新增 `import Knot.Meta.SourceIndex (moduleNameFromPathExt)`

相依方向 source-index → hie-locate 與 `project-meta/design.md` 既有的資料流管線(`source-index` 產 `[SourceFile]` 餵給 `hie-locate`)同向,不新增 Level 2 模組。

兩個舊名一律保留為別名:12 條 1-to-1 測試不必改一個字,而演算法只剩一份。

### M4 — 拓樸旁路(項目 C)

`GraphStats` 的公開 DTO 不再透出上游型別,轉換收進 graph-core 內部:

- `src/Knot/Graph/Types.hs`:L79 改 `gsTopExternalTargets :: [(Text, Int)]`;刪 L30 的 `import Knot.Meta.Types (ModuleName)`(逐符號查過,`ModuleName` 在本檔只有 L79 這一處用)
- `src/Knot/Graph.hs`:L60 的 `gsTopExternalTargets = esTopExternal estats` 改為 `[(m, n) | (ModuleName m, n) <- esTopExternal estats]`(本檔 L31 已 import `ModuleName (..)`,不必新增 import)
- `src/Knot/Graph/EdgeDerive.hs`:`esTopExternal` **不動**(內部型別)
- `src/Knot/Export/Encode.hs`:刪 L38 的 import;L156 的 `| (ModuleName m, c) <- gsTopExternalTargets st` 改為 `| (m, c) <- …`
- `app/Knot/App/Summary.hs`:L164 的 `unMod m` 改 `m`;刪 `renderGraphSummary` where 區塊裡的 `unMod`(L188)。**L87 與 L135 的另一個 `unMod` 屬別的 where 區塊、仍在用,不可刪**
- `test/Main.hs`:`gsTopExternalTargets` 的斷言值從 `mn "Data.Text"` 改字面 `T.pack "Data.Text"`(L2491、2494、2757、2830、2891、3287-3288、3326、3914、4069)

`statsNotes` 的輸出文字與 `codegraph.json` 都不受影響——`gsTopExternalTargets` 只流向 stdout 摘要,不進 JSON(`encodeCodegraph` 完全不碰 `cgStats`)。

### M5 — Discovery per-entry 警告(項目 D)

`src/Knot/Meta/Discovery.hs` 的 `expandEntry` 目錄分支(L104-116):`Right names` 過濾後為空時,不再回 `([], [])`,改依既有 `missing` 的 optional 慣例分流——`packages` 出一則 `MetaWarning (normRel entry) "listed package directory contains no .cabal file"`,`optional-packages` 靜默(與 L118-120「optional 缺項靜默」一致)。

警告序仍為 entry 出現序(`expandProject` 的 `mapM` 保序),決定性不變。

### 遷移步驟(順序有意義)

1. 先 M3 / M4 / M5(純程式碼、彼此無交集,可任意順序或平行)
2. 再 M1(改 cabal 佈局)—— 放在後面,因為它一改,`test/Main.hs` 的建置依賴就換了,前面三項的除錯環境會變複雜
3. 最後 M2(依賴 M1 已切開,才驗得出 `Knot.Export.Types` 的公開面真的乾淨)
4. 每一步都跑一次閘門指令,不累積到最後才驗

### 錯誤處理

行為全數不變。M5 是唯一新增的輸出,且落在既有 best-effort 框架內(警告 + 繼續,exit code 不變;`--strict` 的語意也不變,因為它管的是跳檔不是警告)。

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `moduleNameFromPath :: FilePath -> Maybe ModuleName` | `src/Knot/Meta/SourceIndex.hs:124` | project-meta/F001 | M3 去重的保留別名 |
| `indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])` | `src/Knot/Meta/SourceIndex.hs:35` | project-meta/F002 | M1 判定 source-index 的契約面(不動) |
| `moduleNameFromHiePath :: FilePath -> Maybe ModuleName` | `src/Knot/Meta/HieLocate.hs:167` | project-meta/F003 | M3 去重的保留別名 |
| `locateHie :: MetaOptions -> [SourceFile] -> IO (Maybe HieInfo, [MetaWarning])` | `src/Knot/Meta/HieLocate.hs:42` | project-meta/F003 | M1 判定 hie-locate 的契約面(不動) |
| `findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])` | `src/Knot/Meta/Discovery.hs:30` | project-meta/F002 | M5 的修改標的(簽名不變) |
| `runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult` | `src/Knot/Extract/Backend.hs:68` | extraction/F001 | 類型二代表:M1 後隨模組轉私有 |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | `src/Knot/Graph.hs:37` | graph-core/F001 | M4 的 `GraphStats` 組裝點所在 |
| `esTopExternal :: [(ModuleName, Int)]` | `src/Knot/Graph/EdgeDerive.hs:48` | graph-core/F001 | M4 的轉換來源(本身不動) |
| `declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]` | `src/Knot/Graph/NodeMint.hs:106` | graph-core/F003 | 類型二代表:M1 後隨模組轉私有 |
| `encodeCodegraph :: Maybe Text -> CodeGraph -> Builder` | `src/Knot/Export/Encode.hs:51` | export-query/F001 | 類型二;驗收標準 7 的比對對象 |
| `statsNotes :: GraphStats -> [Text]` | `src/Knot/Export/Encode.hs:146` | export-query/F001 | M4 的消費端 |
| `relationText :: Relation -> Text` | `src/Knot/Export/Encode.hs:131` | export-query/F001 | 類型一最純的案例:M1 後隨模組轉私有 |
| `writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport` | `src/Knot/Export.hs:33` | export-query/F001 | M1 的公開契約(不動) |
| `defaultOutputPath :: FilePath -> FilePath` | `src/Knot/Export/Types.hs:45` | export-query/F001 | M2 的搬遷標的 |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | `src/Knot/Query/Load.hs:131` | export-query/F002 | 類型二:M1 後隨模組轉私有 |
| `classifyRelation :: Text -> RelationClass` | `src/Knot/Query/Load.hs:79` | export-query/F002 | 類型一:M1 後隨模組轉私有 |
| `toExportOptions :: ExtractCmd -> ET.ExportOptions` | `app/Knot/App/Cli.hs:268` | export-query/F004 | M2 的呼叫端 |
| `renderGraphSummary :: CodeGraph -> Text` | `app/Knot/App/Summary.hs:142` | export-query/F004 | M4 的呼叫端 |

## 介面變動

### 新增

| 介面 | 位置 | 說明 |
|---|---|---|
| `moduleNameFromPathExt :: String -> FilePath -> Maybe ModuleName` | `src/Knot/Meta/SourceIndex.hs` | M3 的共用實作;第一參數為副檔名(不含點),`"hs"` / `"hie"`。非契約面 |
| `defaultOutputPath :: FilePath -> FilePath` | `app/Knot/App/Cli.hs` | M2 搬遷後的新家;簽名與行為與原本一字不差 |
| cabal sublibrary `knot-internal`(`visibility: private`) | `knot-hs.cabal` | M1;`exposed-modules` = 現 library 的 26 個模組 |

### 修改

| 介面 | 變動 | 受影響呼叫端 |
|---|---|---|
| **`GraphStats.gsTopExternalTargets`**<br>`[(ModuleName, Int)]` → `[(Text, Int)]` | **動到 graph-core 的 Level 2 對外契約**(`graph-core/design.md:67`),已獲開發者同意回寫 | `src/Knot/Graph.hs:60`(產出端,加轉換)、`src/Knot/Export/Encode.hs:156`、`app/Knot/App/Summary.hs:164`、`test/Main.hs` 10 處斷言 |
| `library` 的 `exposed-modules`(26 個)→ `reexported-modules`(9 個) | **package 公開面收斂**;非 Haskell 層級的契約變動,Level 2 各子系統的契約定義本身不變 | `executable knot`(改依賴公開 library)、`test-suite knot-test`(改依賴 `knot-hs:knot-internal`) |
| `Knot.Meta.SourceIndex` 匯出清單 | 新增 `moduleNameFromPathExt` | 無(新增) |
| `Knot.Meta.HieLocate.moduleNameFromHiePath` | 實作改為 `moduleNameFromPathExt "hie"` 的別名;簽名與行為不變 | 無 |
| `Knot.Meta.Discovery.findCabalFiles` | 簽名不變;目錄無 `.cabal` 時多產一則警告 | `src/Knot/Meta.hs:11`(行為相容)、警告消費端 `app/Knot/App/Report.hs` |

### 移除

| 介面 | 位置 | 受影響呼叫端 |
|---|---|---|
| `Knot.Export.Types.defaultOutputPath` | `src/Knot/Export/Types.hs:45` 及其匯出清單 | `app/Knot/App/Cli.hs:60,271`(改指本地定義)、`test/Main.hs`(改 import 來源) |

### 不變(明示)

`codegraph.json` 格式、CLI 介面與旗標、exit code 語意、`Relation` / `NodeId` / `CodeGraph` / `ExportReport` 等全部 DTO 的其餘欄位,以及 26 個模組各自的 `module ... ( ... ) where` 匯出清單(上表列出者除外)。

## TodoList

- [x] T1: `knot-hs.cabal` 改雙 library 佈局(`knot-internal` private + 公開 library 只 `reexported-modules` 那 9 個;exe 依賴 `knot-hs`、test-suite 依賴 `knot-hs:knot-internal`)  `dep: -`
- [x] T2: `defaultOutputPath` 從 `Knot.Export.Types` 移進 `Knot.App.Cli`,清掉 `Knot.Export.Types` 的「非契約面」小節與無用 import  `dep: T1`
- [x] T3: 大寫尾綴演算法去重:source-index 出 `moduleNameFromPathExt`,hie-locate 改為別名並清無用 import  `dep: -`
- [x] T4: `GraphStats.gsTopExternalTargets` 改 `[(Text, Int)]`,轉換收進 `Knot.Graph.hs`,`Encode` / `Summary` / 測試斷言同步  `dep: -`
- [x] T5: `Discovery.expandEntry` 目錄分支補 per-entry 警告(`packages` 出警告、`optional-packages` 靜默)  `dep: -`
- [x] T6: 回寫架構文件:`export-query/features/F001` 假設 A2 的 `defaultOutputPath` 歸屬敘述(`graph-core/design.md`、`project-meta/design.md`、`system.md` 已於本文檔撰寫時同步,T6 只需複驗一致)  `dep: T1, T2, T3, T4, T5`
- [x] T7: 防退化手段:測試固化「exe 只依賴契約模組」與「公開面恰為那 9 個模組」  `dep: T1`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `cabalLayoutContractSurface` | 讀 `knot-hs.cabal`,斷言公開 `library` 的 `reexported-modules` 集合恰等於那 9 個契約模組、且 `knot-internal` 的 `exposed-modules` 為 26 個;任一私有模組出現在 `reexported-modules` 即失敗 |
| T2 | `defaultOutputPathMovedToCli` | 從 `Knot.App.Cli` import `defaultOutputPath`,斷言 `defaultOutputPath r == r </> "codegraph.json"`,且 `toExportOptions` 在未給 `--output` 時 `outputPath` 仍為該值(回歸:保護 F004 既有行為) |
| T3 | `moduleNameSuffixRuleAgrees`(property) | 隨機路徑段生成,斷言 `moduleNameFromPath (p <> ".hs")` 與 `moduleNameFromHiePath (p <> ".hie")` 結果恆等;既有 12 條 1-to-1 斷言全部保留為回歸 |
| T4 | `graphStatsTopExternalIsText` | `buildGraph` 對既有 fixture 事實流的 `gsTopExternalTargets` 斷言改為 `[(T.pack "Data.Text", 2)]` 等字面值;並斷言 `statsNotes` 與 `renderGraphSummary` 的輸出文字**與變更前逐字相同**(回歸) |
| T5 | `discoveryWarnsOnCabalLessDir` | 新增 fixture:`cabal.project` 的 `packages` 列一個存在但無 `.cabal` 的目錄 → 斷言恰 1 則警告且訊息為 `listed package directory contains no .cabal file`;同一目錄改列在 `optional-packages` → 斷言 0 則警告 |
| T6 | `designDocsMatchGraphStats` | 斷言 `graph-core/design.md` 的 `gsTopExternalTargets` 欄位型別文字與 `src/Knot/Graph/Types.hs` 一致(文件漂移防護);其餘文件更新以 `/arch-audit subsys` 人工複驗 |
| T7 | `appImportsStayWithinContract` | 掃 `app/**/*.hs` 的 `import Knot.*` 行,斷言全部落在那 9 個契約模組的 allowlist 內;新增非契約 import 即失敗(補上 GHC-87110 只在建置期才發作的空窗) |
| 全體 | `codegraphOutputUnchanged` | 驗收標準 7 的回歸總閘:對 `test/fixtures/` 各專案跑完整管線,斷言 `codegraph.json` 位元組與變更前的黃金檔完全相同 |

## 實作備註

### 量化結果(2026-08-22 實作完成)

| # | 驗收標準 | 前 | 後 | 怎麼驗的 |
|---|---|---|---|---|
| 1 | library 公開模組數 | 26 | **9** | `test_cabal_contract_surface`;`reexported-modules` 9 列、`knot-internal` `exposed-modules` 26 列 |
| 2 | 非契約面匯出出現在公開面 | 31 | **0** | 21 + 9 隨模組轉私有;`defaultOutputPath` 移入 `Knot.App.Cli` |
| 3 | 契約違反是編譯錯誤 | 註解自律 | **GHC-87110** | 在本專案實測:`app/Main.hs` 加 `import Knot.Export.Encode` → `error: [GHC-87110] It is a member of the hidden package 'knot-hs-0.0.1.0:knot-internal'`,驗完還原 |
| 4 | `src/` 跨段 import | 1 | **0** | `grep -rn "^import .*Knot\.Meta\." src/Knot/Export src/Knot/Query` 回 0 列 |
| 5 | 大寫尾綴演算法實作份數 | 2 | **1** | `takeWhile upperSeg` 只剩 `src/Knot/Meta/SourceIndex.hs` 一處 |
| 6 | 目錄無 `.cabal` 的警告數 | 0 | **1** | `test_discovery_cabal_less_dir`(`packages` 2 則含 per-entry、`optional-packages` 1 則不含) |
| 7 | `codegraph.json` byte 級不變 | — | **不變** | `test_codegraph_output_unchanged` 對 5 個 fixture 專案逐 byte 比對黃金檔 |
| 8 | 建置閘門 | — | **exit 0、零警告** | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` |
| 9 | 測試 | 138 綠 | **148 綠** | 既有 138 條零退化,G-E001 新增 10 條 |

**唯讀驗收標的實跑**(`--db` 改道專案外,兩邊 `git status` 皆 0 個變更、無 `.knot/`):

- particle-magic:46 節點 / 127 邊 —— 與 `system.md` 記錄的基線**完全相符**
- MagicFarmer:67 節點 / 288 邊(記錄基線 60 / 247)。差額**不是回歸**:MagicFarmer 自 2026-08-21 起有 30 個 commit、新增 mind-sea F001–F004,現有 141 個 `.hs`
- knot-hs 自掃(G-E003 selfcheck):548 節點 / 1947 邊 / 0 警告。節點與警告數與變更前一致;邊少 1 條,正是 M4 拿掉的 `Knot.Export.Encode → Knot.Meta.Types`——拓樸修正在自己的圖上得到證實

### 與設計的偏差

1. **`Discovery` 新警告的來源路徑用 `entry` 原文,非設計文檔寫的 `normRel entry`**。改走既有的 `missing entry optional …`——它本來就承載「`packages` 出警告、`optional-packages` 靜默」這條分流,重寫一份會多出第二個判斷點。代價是警告路徑與同函式中的 `cannot read directory`(用 `normRel`)風格不一致,但與語意最接近的鄰居「目錄不存在」一致。
2. **`executable knot` 的 `build-depends` 多加了 `filepath`**。設計沒預見:`defaultOutputPath` 搬進 `Knot.App.Cli` 後,`</>` 跟著搬過去,而 exe 原本靠 library 傳遞取得 `filepath`。
3. **公開 `library` 必須明寫 `hs-source-dirs: src`**(設計的 cabal 骨架沒有這一行)。省略時 cabal 套預設值 `.`,該 component 就宣告擁有整個 repo——`SourceIndex` 的 `dirSegs ["."] -> []`(恆命中)於是把 `test/fixtures/**.hs` 全部認領進圖。實跑抓到:自掃節點 548 → 575、警告 0 → 8。補上該行後數字回到基線。已同步寫進 `system.md` 的 package 佈局段。

### 範圍外的發現(建議另開文檔,本次未動)

上面第 3 點暴露的是 project-meta 的一個真實行為,不只是 knot-hs 自己的 cabal 寫法問題:**任何 component 只要 `hs-source-dirs` 取預設值 `.`,`SourceIndex` 就會把 repo 內全部 `.hs` 判給它並標成 `sfIncluded = True`**——包含 test fixture、範例碼、腳本。判定規則 2「只要任一 owner 未排除即納入」讓這個效果無法被 test-suite 的排除判定抵銷。

這忠實實作了 Cabal 的預設語意,不算 bug;但對「根目錄擺 library」的真實專案會灌水整張圖。本次 Scope 明訂不改演算法行為,故未處理,建議另開 project-meta 的 E 文檔評估(例如對 `.` 這種恆命中的 owner 是否該套用路徑啟發式)。

### 新增的測試資產

`test/fixtures/golden/{comps,graph,multi,no-cabal,proj}.json` —— 五個 fixture 專案在**動工前**的完整管線輸出(`--backend imports`、commit 傳 `Nothing`,故不隨 hiedb 是否安裝或 HEAD 移動而漂移)。它是本次「行為零變更」的權威依據,也留給日後任何重構當回歸閘。
