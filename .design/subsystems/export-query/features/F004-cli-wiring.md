---
id: F004
type: feature
title: cli-wiring
description: knot extract / query 兩子命令的參數解析與四子系統管線組裝
status: open
created: 2026-08-21
updated: 2026-08-21
depends-on: [F001, F002, F003, project-meta/F001, project-meta/F002, project-meta/F003, extraction/F001, extraction/F002, graph-core/F001]
related-adr: [ADR-002, ADR-003]
related-feature: []
---

# F004: cli-wiring — knot 的參數解析與管線組裝

## 功能概述

`knot` 執行檔的**組裝層**:把 `argv` 解析成各子系統的 Options DTO,依
`project-meta → extraction → graph-core → export-query` 呼叫,再把結果、警告與 exit code 送到
stdout / stderr / 檔案。本 feature 不含任何投影、載入或查詢邏輯——全部委由四個子系統已定案的契約函式。

**要解決的問題**,三件:

1. **CLI 契約落地**:`system.md`「CLI 介面(頂層契約)」的兩個子命令與全部旗標目前只有
   `app/Main.hs` 的極簡 `getArgs` 解析(位置參數 + `--include-tests` / `--facts` / `--graph`,
   `app/Main.hs:68-80`),六個 extract 旗標中只有 `--include-tests` 存在,`query` 完全沒有。
   本 feature 以 optparse-applicative(D2 / D9)整套換掉
2. **警告匯流(硬性要求)**:四個子系統一律**不印任何輸出**(D8),把警告收在自己的 DTO 欄位裡等
   CLI 取走。目前只有 `--summary` 那三條唯讀路徑會順手印到 stdout,**預設的匯出路徑一條都印不出來**。
   其中 `cgWarnings` 的通道是**斷的**(`F001` 假設 A3 的閘門裁決:`xrNotes` 嚴守契約只放 `GraphStats`,
   `cgWarnings` 改由本層直接從 `CodeGraph` 取——`writeCodegraph` 完全不碰它,見
   `src/Knot/Export.hs:39-44`)。本層漏接的話,graph-core 的同名 module 碰撞警告
   (particle-magic 唯讀實跑實測有 1 條)永遠不會被使用者看到
3. **exit code 語意**:best-effort 與 fail-fast 兩套錯誤策略在此交會——匯出管線有跳檔仍 exit 0
   (`--strict` 改 1),查詢面的 `LoadError` 直接 exit 1,而查無結果 exit 0

**驗收標準**(契約卡原文,逐條對照落地):

| # | 契約卡原文 | 落地 | 測試 |
|---|---|---|---|
| 1 | `knot extract [PATH]` 六個旗標全部解析正確且對映到正確的 Options 欄位 | 六旗標 + 位置參數見「CLI 語法樹」;對映見「旗標 → Options DTO 對映表」,對映函式為純函數可直接斷言 | T2、T3 |
| 2 | `knot query find\|reachable\|path\|rank` 四子命令(含 `--reverse`、`--top N`,N 預設 10)對映到正確的 `QueryCommand` | `hsubparser` 巢狀子命令;四條對映見「query 子命令」 | T4 |
| 3 | `--summary meta\|facts\|graph` 保留三個既有唯讀驗收輸出,不給時 `extract` 預設寫 `codegraph.json` | `ecSummary :: Maybe SummaryMode`;`Nothing` 走匯出路徑,`Just` 走既有 `renderMetaSummary` / `renderFactSummary` / `renderGraphSummary`(三個函式一字不改) | T2、T6 |
| 4 | `--help` 對頂層與每個子命令都可用 | 頂層與每層子命令都 `<**> helper`(`hsubparser` 另會自動替每個子命令加 `--help`,`Options/Applicative/Extra.hs:88-96`) | T1、T2、T4 |
| 5 | 無效旗標與缺參數 exit 非 0 且訊息指出問題 | optparse 的 `ParserFailure`,`infoFailureCode = 1`(`Builder.hs:511-522`),錯誤走 stderr、help 走 stdout(`Extra.hs:124-133`) | T1、T2、T4、T8 |
| 6 | `LoadError` exit 1、查無結果 exit 0 | 見「輸出通道與 exit code」表 | T7 |
| 7 | 有跳檔時預設 exit 0 而 `--strict` 下 exit 1 | 「跳檔」判定 = 三條警告清單任一非空(假設 A2) | T6 |
| 8 | `ExportReport` 的 `xrNotes` 與 `queryGraphNotes` 由本層印出(library 仍全程不印) | `Knot.App.Report` 的 `exportNoteLines` / `queryNoteLines` | T5、T6、T7 |
| 9 | **(硬性)`cgWarnings` 非空時印到 stderr** | `Knot.App.Report.graphNoteLines`;`runExtractCmd` 在匯出與 `--summary` 兩條路徑都呼叫 | T5、T6 |
| 10 | 以 MagicFarmer 與 particle-magic 唯讀實跑,產出的 `codegraph.json` 經 dev-flow `scan-graph.mjs` 解析成功 | 實作階段手動執行(D5 前例);兩個標的**絕對唯讀**,`--output` 一律指向 knot-hs 的暫存目錄,不在標的專案內落檔 | T9(手動) |

**明確不做**(契約卡底線):不含任何投影、載入或查詢邏輯;**不新增 library 公開面**(本 feature 的
新增程式碼全部落在 executable 的 `app/`,library `exposed-modules` 零變動);**不改動任何子系統的
Options DTO 形狀**。另承 D6:`knot-hs.cabal` 的 `version` 維持 `0.0.1.0` 不動。另承 D8:library 全程
不印——列印全部發生在本層。

## 相依性

`depends-on` 九條,全部由「使用到的既有串接介面」表反推。本 feature 是**跨子系統的黏合層**,
四個子系統的對外契約全部是它的輸入,相依面寬是職責的必然結果,不是設計失誤。

**既有程式碼查證**(2026-08-21 自來源檔讀出簽名原文,標行號):

- **`project-meta/F001` scan-baseline**:`loadProjectMeta`(`src/Knot/Meta.hs:29`)與
  `MetaOptions` / `ProjectMeta` / `MetaWarning`(`src/Knot/Meta/Types.hs`);`renderMetaSummary`
  (`app/Knot/App/Summary.hs:52`,`--summary meta`)
- **`project-meta/F002` cabal-components**:`--include-tests` 的語意消費端——
  `isExcludedKind`(`src/Knot/Meta.hs:58`)以 `includeTests` 決定 `TestSuite` / `Benchmark`
  component 是否排除。沒有 F002,這個旗標無事可做
- **`project-meta/F003` hie-discovery**:`--hiedir` 的語意消費端——`locateHie`
  (`src/Knot/Meta.hs:36`)消費 `hieDirOverride`。同理,沒有 F003 這個旗標無事可做
- **`extraction/F001` fact-contract**:`extract`(`src/Knot/Extract.hs:19`)與
  `ExtractOptions` / `BackendChoice` / `ExtractResult` / `CapabilityLevel` / `BackendReport` /
  `ExtractWarning`(`src/Knot/Extract/Types.hs`)
- **`extraction/F002` import-scan**:`renderFactSummary`(`app/Knot/App/Summary.hs:102`,
  `--summary facts`);同時是 `--backend` 目前唯一已註冊的後端(`src/Knot/Extract.hs:25`)
- **`graph-core/F001` module-graph**:`buildGraph`(`src/Knot/Graph.hs:37`)與 `BuildOptions` /
  `CodeGraph` / `GraphWarning`(`src/Knot/Graph/Types.hs`);`renderGraphSummary`
  (`app/Knot/App/Summary.hs:142`,`--summary graph`)。**`buildGraph` 的 haddock
  (`src/Knot/Graph.hs:35-36`)明載「`erLevel` / `erReports` / `erWarnings` 由 CLI 印 stderr,
  graph-core 不轉載」——這是本 feature 匯流責任的直接來源**
- **`F001` json-export(同子系統,已 done)**:`writeCodegraph`(`src/Knot/Export.hs:33`)、
  `ExportOptions` / `CommitPolicy` / `ExportReport`,以及**特地為本 feature 留的非契約面**
  `defaultOutputPath`(`src/Knot/Export/Types.hs:45`,F001 假設 A2)

**依設計文檔而非原始碼**(兩份文檔 `status: open`,`src/Knot/Query/` 於 2026-08-21 確認不存在;
下表凡標「來源文檔 = F002 / F003」的列,**簽名來自設計文檔而非既有原始碼**,實作階段必須以落地後的
真實簽名複驗):

- **`F002` graph-load**:`loadQueryGraph`、`queryGraphNotes`、`LoadError`、`QueryGraph`(抽象)、
  以及起點存在性檢查要用的 `QueryNode` / `qgNodes` / `qnId` / `NodeId`
- **`F003` query-commands**:`runQuery`、`renderResult`、`QueryCommand` / `Direction` / `QueryResult`

**未列入的相依與理由**:

- **`ADR-002` / `ADR-003`** 列在 `related-adr`:前者是 `--backend` 三個取值的語意出處(hiedb 不可用
  時降級而非失敗),後者是 `codegraph.json` 為唯一檔案輸出契約的出處;兩者都是決策紀錄不是任務文檔
- **`graph-core/F002` / `F003`(decl 層)**:尚未展開;它們上線後 `--module-only` 的兩個取值才會有
  不同輸出(`src/Knot/Graph.hs:46` 註記本階段兩值相同),但**旗標對映本身不變**,本層零改動

**可平行性**:**不可**與 `F002` / `F003` 平行——本 feature 呼叫的五個查詢面進入點由它們建立,
未落地前無法編譯。與其他子系統的任務**可**平行(上游三個子系統的階段一皆 done 且已在 `main`)。
本 feature 是整個 export-query 依賴鏈的末端。

## 對應的 Level 2 契約

本 feature **不新增任何 library 契約面**,它實作的是 `system.md`「CLI 介面(頂層契約)」與
`design.md`「CLI 子命令對映」。逐條對照:

| 契約項(出處) | 本 feature 的落實 |
|---|---|
| `knot extract [PATH]` 產出 `codegraph.json`(system.md) | `extract` 子命令的預設行為;位置參數預設 `"."` |
| `--output FILE`,預設 `<PATH>/codegraph.json`(system.md) | `ExportOptions.outputPath`;預設值以 `defaultOutputPath <PATH>` 計(F001 假設 A2 的既定分工) |
| `--backend auto\|imports\|hiedb`(system.md) | `ExtractOptions.backendChoice`:`Auto` / `ImportsOnly` / `HiedbOnly` |
| `--module-only`(system.md) | `BuildOptions.moduleOnly` |
| `--include-tests`(system.md) | `MetaOptions.includeTests` |
| `--hiedir DIR`(system.md) | `MetaOptions.hieDirOverride`(`Just`) |
| `--strict`(system.md) | 純 CLI 語意,無對應 Options 欄位:三條警告清單任一非空時 exit 1(假設 A2) |
| `knot query <find\|reachable\|path\|rank>`(system.md) | `query` 子命令下的四個 `hsubparser` 子命令 |
| `knot query find <keyword>` → `FindNodes`(design.md CLI 子命令對映) | 位置參數 `KEYWORD` → `FindNodes (T.pack kw)` |
| `knot query reachable <id> [--reverse]` → `Reachable`(同上) | 位置參數 `ID` → `NodeId`;`--reverse` → `Reverse`,否則 `Forward` |
| `knot query path <from> <to>` → `ShortestPath`(同上) | 兩個位置參數 → `ShortestPath` |
| `knot query rank [--top N]` → `RankConnectivity`(N 預設 10)(同上) | `--top` `option auto`,`value 10` |
| 全域錯誤處理:best-effort、跳檔 exit 0、`--strict` 使跳檔 exit 1(system.md 通訊拓撲) | 見「輸出通道與 exit code」表 |
| 降級原則:後端不可用時自動降級並**明確告知**(system.md、ADR-002) | `extractNoteLines` 印 `erLevel` 與 `erReports` 中 `brUsed == False` 的降級原因 |
| 「警告與錯誤:stderr」(system.md Output 3) | 五條通道全部走 stderr;stdout 只放查詢結果、摘要與 `wrote` 行(假設 A5) |
| 查詢面錯誤策略:`LoadError` 直接失敗(exit 1),查無結果 exit 0(design.md 資料流管線) | 同上表 |
| `xrNotes` 由 CLI 層列印(design.md 匯出面 DTO 註解) | `exportNoteLines` |
| `queryGraphNotes` 由 CLI 層取來印 stderr(design.md 查詢規則 2、build-log C2) | `queryNoteLines` |
| 「參數解析屬 CLI 組裝層;本子系統收 `QueryCommand`」(design.md) | 四個 `QueryCommand` 全部在本層建構 |

**未觸碰的契約面**:`writeCodegraph` / `loadQueryGraph` / `queryGraphNotes` / `runQuery` /
`renderResult` 的**實作**(分別屬 `F001` / `F002` / `F003`),以及任何 Options DTO 的**形狀**
(本層只填值)。

## 實作方式

### 模組配置

全部落在 executable 的 `app/`(library 零變動)。`app/` 的模組同時被 test-suite 編譯
(`knot-hs.cabal:53` `hs-source-dirs: test, app`),所以除了 `Main.hs` 之外都測得到——
`Main.hs` 因模組名衝突不會進 test-suite,故把它壓到**只剩分派**,可測邏輯全部下沉。

| Haskell 模組 | 本 feature 的動作 | 職責 | IO |
|---|---|---|---|
| `Knot.App.Cli` | **新增** | `Command` / `ExtractCmd` / `QueryCmd` / `SummaryMode` DTO、optparse parser、`ParserInfo`、旗標 → 四個 Options DTO 的**純對映** | 無 |
| `Knot.App.Report` | **新增** | 五條警告/摘要通道的**純行渲染** + `emitNotes`(唯一的列印函式) | 有(寫 `Handle`) |
| `Knot.App.Run` | **新增** | `runCommand` / `runExtractCmd` / `runQueryCmd`:管線組裝與 exit code 決定;**兩個 `Handle` 由呼叫端注入**(測試餵暫存檔) | 有 |
| `Knot.App.Summary` | **不動** | 既有三個唯讀摘要輸出(C6 要求保留) | 無 |
| `Main` | **改寫** | `execParser cliParserInfo >>= runCommand stdout stderr >>= exitWith`,不含任何邏輯 | 有 |

`Knot.App.Run` 的 `Handle` 注入是**驗收標準 9 可測的關鍵**:硬性要求「`cgWarnings` 非空時印到
stderr」若只測純渲染函式,漏接的風險(忘了呼叫)完全沒被覆蓋;注入後測試可以拿真實管線的輸出比對。

### CLI 語法樹

```text
knot [--help]
  extract [PATH]                      預設 PATH = "."
    -o, --output FILE                 預設 <PATH>/codegraph.json
        --backend auto|imports|hiedb  預設 auto
        --module-only
        --include-tests
        --hiedir DIR
        --strict
        --summary meta|facts|graph    不給則寫 codegraph.json(C6)
    -h, --help
  query [--graph FILE]                預設 ./codegraph.json(假設 A3)
    find <KEYWORD>
    reachable <ID> [--reverse]
    path <FROM> <TO>
    rank [--top N]                    預設 N = 10
    -h, --help(每個子命令各自可用)
```

- 頂層與 `query` 層都用 `hsubparser`;`hsubparser` 會**自動替每個子命令掛上 `--help`**
  (`Options/Applicative/Extra.hs:88-96`:`add_helper pinfo = pinfo { infoParser = infoParser pinfo <**> helper }`),
  頂層另以 `<**> helper` 明確掛一次
- `--backend` / `--summary` 用 `option (eitherReader …)`,認不得的值回
  `Left "expected auto|imports|hiedb, got \"…\""`,由 optparse 轉成 exit 1 的 stderr 訊息
- `--top` 用 `option auto`,非數字由 `auto` 的 `Read` 失敗轉成解析錯誤
- **`--graph FILE` 是本層新增的旗標**(契約未列,見假設 A3):`system.md` 明文「內部旗標細節
  (參數格式、預設值微調)屬 Level 2/3 自主權」,而 `--output` 可改道之後查詢面必須有辦法指到同一份檔

### 旗標 → Options DTO 對映表(驗收標準 1)

`ExtractCmd` 一個值展開成四個 Options DTO,四個**純函數**各負責一個(測試直接斷言):

| 目標 DTO(來源) | 欄位 | 值 |
|---|---|---|
| `MetaOptions`(`Knot.Meta.Types`) | `root` | `ecPath`(位置參數,預設 `"."`) |
| | `includeTests` | `ecIncludeTests`(`--include-tests`) |
| | `hieDirOverride` | `ecHieDir`(`--hiedir`,未給為 `Nothing`) |
| `ExtractOptions`(`Knot.Extract.Types`) | `rootDir` | `ecPath`(**與 `MetaOptions.root` 同源**:`sfPath` 等 repo 相對路徑的錨點) |
| | `backendChoice` | `ecBackend`(`--backend`,預設 `Auto`) |
| | `hiedbExe` | `Nothing`(無對應旗標,假設 A8) |
| | `dbPath` | `Nothing`(同上) |
| `BuildOptions`(`Knot.Graph.Types`) | `moduleOnly` | `ecModuleOnly`(`--module-only`) |
| `ExportOptions`(`Knot.Export.Types`) | `rootDir` | `ecPath`(`AutoDetect` 在此跑 `git rev-parse`) |
| | `outputPath` | `fromMaybe (defaultOutputPath ecPath) ecOutput`(`--output` 覆寫) |
| | `commitPolicy` | `AutoDetect`(固定,無旗標;假設 A6) |

### 同名欄位與同名型別的處理(已知踩雷點)

1. **`rootDir` 同名**:`ExtractOptions` 與 `ExportOptions` 都有(`src/Knot/Extract/Types.hs:34`、
   `src/Knot/Export/Types.hs:22`)。GHC2024 內含的 `DisambiguateRecordFields` **只**消歧記錄建構與
   模式比對,**不涵蓋記錄更新**(GHC-99339)與裸選擇器(GHC-87543)——這是 `F001` 實作階段推翻設計
   結論後的實測事實(build-log 階段一)。**本 feature 一律用 qualified import**:
   `import qualified Knot.Extract.Types as XT`、`import qualified Knot.Export.Types as ET`,
   寫 `XT.ExtractOptions { XT.rootDir = … }` / `ET.ExportOptions { ET.rootDir = … }`
   (`test/Main.hs` 已有同一慣例的 8 處前例)。**不新增 `DuplicateRecordFields` /
   `OverloadedRecordDot` 擴充**,也不動任何 library DTO 的欄位名
2. **`NodeId` 同名**:`Knot.Query.Types.NodeId`(F002 假設 A1 的既定裁決)與
   `Knot.Graph.Types.NodeId`(`src/Knot/Graph/Types.hs:50`)。本層的分工讓兩者**天然不同框**——
   `Knot.App.Cli` 只碰查詢面(從 CLI 字串建 `NodeId`),`Knot.App.Run` 碰 `CodeGraph` 時只用
   `import Knot.Graph.Types (CodeGraph (..), GraphWarning (..))`(明列匯入,不含 `NodeId`)。
   即使日後同框,也一律 qualified(`QT.`)
3. **`root` / `rootDir` 語意同源**:三個 DTO 的三個路徑欄位全部餵 `ecPath` 同一個值;對映函式集中在
   `Knot.App.Cli` 一處,避免散落各處各自 `<> "/"`

### 警告匯流(驗收標準 8、9;硬性要求)

`Knot.App.Report` 把**五條**上游通道收成統一的行清單。每條都是純函數,空輸入回 `[]`
(不產生噪音行),行文沿用專案既有慣例(英文小寫、`T.pack` 不依賴 `OverloadedStrings`、
對齊 `app/Knot/App/Summary.hs` 與 `F001` 的 `xrNotes`):

| 函式 | 來源欄位 | 出處(為什麼非印不可) | 行格式 |
|---|---|---|---|
| `metaNoteLines :: ProjectMeta -> [Text]` | `pmWarnings` | `src/Knot/Meta/Types.hs:33` haddock:「best-effort 蒐集,**由呼叫端印到 stderr**」 | `meta: <mwPath>: <mwMessage>` |
| `extractNoteLines :: ExtractResult -> [Text]` | `erLevel`、`erReports`、`erWarnings` | `src/Knot/Graph.hs:35-36` haddock:「`erLevel` / `erReports` / `erWarnings` **由 CLI 印 stderr**,graph-core 不轉載」;ADR-002 的降級告知 | `extract: level <erLevel>` / `extract: backend <brBackend> unused: <brDetail>`(只印 `brUsed == False`)/ `extract: <ewSource>: <ewMessage>` |
| `graphNoteLines :: CodeGraph -> [Text]` | `cgWarnings` | **`F001` 假設 A3 的閘門裁決**:`xrNotes` 只放 `GraphStats`,`cgWarnings` 由本層直接取。`writeCodegraph` 完全不碰它(`src/Knot/Export.hs:39-44`) | `graph: <gwSource>: <gwMessage>` |
| `exportNoteLines :: ExportReport -> [Text]` | `xrNotes` | `src/Knot/Export/Types.hs:33-34` haddock:「`GraphStats` 摘要行,**由 CLI 層列印**」 | `export: <note>`(`note` 已是 `statsNotes` 產的完整行,如 `dropped external edges: 3`) |
| `queryNoteLines :: QueryGraph -> [Text]` | `queryGraphNotes` | design.md 查詢規則 2 + build-log C2:未知 relation 不靜默吞掉 | `query: unknown relation "<rel>": <n> edges` |

列印函式只有一個:`emitNotes :: Handle -> [Text] -> IO ()`(空清單不寫任何 byte)。
`runExtractCmd` 在**匯出路徑與三個 `--summary` 路徑都呼叫**同一組通道(假設 A1),
所以 `--summary graph` 也看得到 `pmWarnings` / `erWarnings`——那是既有 `renderGraphSummary`
看不到的兩條。

### `runExtractCmd` 的流程

```text
runExtractCmd hOut hErr cmd = do
  let mo = toMetaOptions cmd
  pm <- loadProjectMeta mo
  emitNotes hErr (metaNoteLines pm)
  case ecSummary cmd of
    Just SummaryMeta  -> out (renderMetaSummary pm) >> strictExit [pm 警告]
    _ -> do
      er <- extract (toExtractOptions cmd) pm
      emitNotes hErr (extractNoteLines er)
      case ecSummary cmd of
        Just SummaryFacts -> out (renderFactSummary er) >> strictExit …
        _ -> do
          let cg = buildGraph (toBuildOptions cmd) pm er
          emitNotes hErr (graphNoteLines cg)          -- ← 硬性要求的落點
          case ecSummary cmd of
            Just SummaryGraph -> out (renderGraphSummary cg) >> strictExit …
            Nothing -> do
              r <- try (writeCodegraph (toExportOptions cmd) cg)
              case r of
                Left (e :: IOException) -> err ("export: " <> show e) >> pure (ExitFailure 1)
                Right rep -> do
                  emitNotes hErr (exportNoteLines rep)
                  out ("wrote " <> xrPath rep <> ": " <> xrNodeCount <> " nodes, " <> xrEdgeCount <> " edges")
                  strictExit …
```

- **管線順序**與 system.md 的單向拓撲一致,且**只跑到需要的那一站**:`--summary meta` 不呼叫
  `extract`、`--summary facts` 不呼叫 `buildGraph`(既有 `app/Main.hs:42-50` 的分層即是此形狀)
- **`writeCodegraph` 的 `IOException` 在此收斂**:`F001` 的 haddock(`src/Knot/Export.hs:29-32`)
  明文「由 F004 的 CLI 層決定 exit code 與訊息」。訊息走 stderr、exit 1
- **`--strict` 的判定**:`ecStrict` 為真且「已跑過的階段」蒐集到的警告總數 > 0 → `ExitFailure 1`,
  並在 stderr 補一行 `strict: <n> warnings` 說明為什麼非 0(假設 A2)
- `renderMetaSummary` / `renderFactSummary` / `renderGraphSummary` **一字不改**沿用
  (C6:保留既有三個唯讀驗收輸出)

### `runQueryCmd` 的流程

```text
runQueryCmd hOut hErr cmd = do
  r <- loadQueryGraph (qcFile cmd)
  case r of
    Left e  -> err ("query: " <> loadErrorText e) >> pure (ExitFailure 1)   -- 契約:LoadError exit 1
    Right g -> do
      emitNotes hErr (queryNoteLines g)                                     -- 契約 C2
      mapM_ (err . missingNodeLine) (missingNodes g (qcCommand cmd))        -- F003 A1 的建議
      out (renderResult (runQuery g (qcCommand cmd)))
      pure ExitSuccess                                                      -- 查無結果也是 0
```

- **`loadErrorText`**:對 `LoadFileMissing` / `LoadParseError` / `LoadSchemaError` 三建構子取出其
  `Text`(三者都自帶已組好的訊息,含路徑與問題;F002 的訊息格式為
  `"<path>: <locus>: <problem>"`),CLI 只加 `query: ` 前綴,**不重寫訊息**
- **起點/終點存在性**(`F003` 假設 A1 明確建議由本層做):`Reachable` 取其起點、`ShortestPath` 取兩端,
  以 `qgNodes` 線性比對(`any ((== nid) . QT.qnId)`)判存在,不存在則印
  `query: node not found: <id>`。**只影響訊息,不影響 exit code**(假設 A4):`runQuery` 本來就會回
  空結果,契約寫的是「查無結果 exit 0」
  - 用 `qgNodes` 而非 `qgIndex`,是為了不在 executable 段新增 `containers` 依賴;CLI 一次查詢只做一次
    線性掃描,代價可忽略
- `renderResult` 的輸出以 `T.hPutStr` 原樣送 stdout(每行已含 `\n`,F003 假設 A5)

### 輸出通道與 exit code

| 情境 | stdout | stderr | exit |
|---|---|---|---|
| `--help`(頂層或任一子命令) | help 全文 | — | 0(`Extra.hs:202` `ShowHelpText → ExitSuccess`) |
| 無子命令 / 未知子命令 / 未知旗標 / 缺參數 / 旗標值非法 | — | usage + 錯誤 | 1(`infoFailureCode`,`Builder.hs:518`) |
| `extract` 成功,無警告 | `wrote <path>: N nodes, M edges` | `export:` 摘要行 | 0 |
| `extract` 成功,有警告,無 `--strict` | 同上 | 警告 + 摘要 | 0 |
| `extract` 成功,有警告,`--strict` | 同上 | 警告 + `strict: n warnings` | 1 |
| `extract` 寫檔失敗(`IOException`) | — | `export: <e>` | 1 |
| `extract --summary meta\|facts\|graph` | 既有摘要 | 已跑階段的警告 | 0(`--strict` 且有警告則 1) |
| `query …` 成功(含空結果 / `not connected`) | `renderResult` 文字 | 未知 relation 提示、node not found | 0 |
| `query …` 載入失敗(`LoadError` 三種) | — | `query: <訊息>` | 1 |

### cabal 變更

- **executable `knot`**:`other-modules` 由 `Knot.App.Summary` 擴為
  `Knot.App.Cli`、`Knot.App.Report`、`Knot.App.Run`、`Knot.App.Summary`;
  `build-depends` **+1**:`optparse-applicative ^>=0.19`(D9 實測 0.19.0.0 於 GHC 9.14.1 / base 4.22
  解析並編譯成功);`base` / `knot-hs` / `text` 已在
- **test-suite `knot-test`**:`other-modules` 同步為同樣四個模組(否則 `app/` 的新模組不會被編譯進
  測試);`build-depends` **+1**:`optparse-applicative ^>=0.19`。其餘(`aeson` / `bytestring` /
  `directory` / `filepath` / `process` / `tasty*` / `hedgehog` / `text`)皆已在
- **library**:`exposed-modules` 與 `build-depends` **零變動**(明確不做:不新增 library 公開面)
- `version` **維持 `0.0.1.0` 不動**(D6)

### 測試策略

三個互補的縫:

1. **純解析**:`execParserPure defaultPrefs cliParserInfo argv :: ParserResult Command`
   (`Extra.hs:151-155`)——不碰 `getArgs`、不 exit,可對 `Success` / `Failure` 直接斷言;
   失敗時以 `renderFailure`(`Extra.hs:344`)取出 `(訊息, ExitCode)` 驗證「訊息指出問題」與 exit code
2. **純對映與純渲染**:四個 `to*Options` 與五個 `*NoteLines` 都是純函數,直接比對
3. **注入 `Handle` 的端到端**:`runCommand h_out h_err cmd` 寫進暫存檔再讀回,驗證
   「`cgWarnings` 真的走到 stderr」與 exit code。碰撞警告的來源是**測試自建的暫存專案**
   (兩個 `hs-source-dirs` 各放一個宣告同一個 module 名的 `.hs`,配一份最小 `.cabal`),
   走完整管線後 `cgWarnings` 必為 1 條(`src/Knot/Graph.hs:70-83` 的 `collisionWarnings`)。
   暫存目錄沿用既有 `withExportDir` 慣例(`test/Main.hs:1861`),跑完刪除

**兩個唯讀標的**(T9,實作階段手動,D5 前例):
`knot extract C:/Users/User/Documents/GameProjects/MagicFarmer --output <knot-hs 暫存>/mf.json` 與
particle-magic 同形,**`--output` 一律指向 knot-hs 這邊的暫存路徑,不在標的專案內產生任何檔案**;
再以 dev-flow 的 `arch-audit/scripts/scan-graph.mjs` 解析產出檔對帳。particle-magic 應觀察到
`graph: …` 的同名 module 碰撞警告(既有實測 1 條)——那正是驗收標準 9 的實地證明。

## 使用到的既有串接介面

(knot-hs 自家程式碼 2026-08-21 自來源檔讀出原文並標行號;optparse-applicative 讀自
`C:/cabal/packages/hackage.haskell.org/optparse-applicative/0.19.0.0/optparse-applicative-0.19.0.0.tar.gz`
解出的原始碼並標行號;boot 套件簽名以 `ghc -e ':t …'` 在 GHC 9.14.1 直接查出,`ghc --version` 已核對。
**標「來源文檔 = F002 / F003」的五列簽名來自設計文檔而非原始碼**——`src/Knot/Query/` 於同日確認不存在)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 管線第一站 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs:22-26 | project-meta/F001 | `PATH` / `--include-tests` / `--hiedir` 的落點 |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | src/Knot/Meta/Types.hs:29-34 | project-meta/F001 | 傳給 `extract` / `buildGraph`;`pmWarnings` 是警告通道 1 |
| `data MetaWarning = MetaWarning { mwPath :: FilePath, mwMessage :: Text }` | src/Knot/Meta/Types.hs:89-93 | project-meta/F001 | `metaNoteLines` 的兩個欄位 |
| `isExcludedKind`(`includeTests` 的消費點,`k \`elem\` [TestSuite, Benchmark] && not (includeTests opts)`) | src/Knot/Meta.hs:58 | project-meta/F002 | **不呼叫**;確認 `--include-tests` 確有語意消費端(相依性的依據) |
| `locateHie opts sources`(`hieDirOverride` 的消費點) | src/Knot/Meta.hs:36 | project-meta/F003 | **不呼叫**;確認 `--hiedir` 確有語意消費端 |
| `extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult` | src/Knot/Extract.hs:19 | extraction/F001 | 管線第二站 |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | src/Knot/Extract/Types.hs:33-38 | extraction/F001 | `--backend` 的落點;**`rootDir` 與 `ExportOptions` 同名(踩雷點)** |
| `data BackendChoice = Auto \| ImportsOnly \| HiedbOnly` | src/Knot/Extract/Types.hs:41 | extraction/F001 | `--backend auto\|imports\|hiedb` 的三個目標值 |
| `data ExtractResult = ExtractResult { erFacts :: [Fact], erLevel :: CapabilityLevel, erReports :: [BackendReport], erWarnings :: [ExtractWarning] }` | src/Knot/Extract/Types.hs:44-49 | extraction/F001 | 傳給 `buildGraph`;後三個欄位是警告通道 2 |
| `data CapabilityLevel = ModuleLevel \| DeclLevel` | src/Knot/Extract/Types.hs:53 | extraction/F001 | `extract: level <…>` 行 |
| `data BackendReport = BackendReport { brBackend :: Text, brUsed :: Bool, brDetail :: Text }` | src/Knot/Extract/Types.hs:92-96 | extraction/F001 | 降級告知行(ADR-002) |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` | src/Knot/Extract/Types.hs:100-103 | extraction/F001 | `extractNoteLines` 的兩個欄位 |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | src/Knot/Graph.hs:37 | graph-core/F001 | 管線第三站(純函數) |
| `data BuildOptions = BuildOptions { moduleOnly :: Bool }` | src/Knot/Graph/Types.hs:34-36 | graph-core/F001 | `--module-only` 的落點 |
| `data CodeGraph = CodeGraph { cgNodes :: [GraphNode], cgEdges :: [GraphEdge], cgStats :: GraphStats, cgWarnings :: [GraphWarning] }` | src/Knot/Graph/Types.hs:40-45 | graph-core/F001 | 交給 `writeCodegraph`;**`cgWarnings` 是硬性要求的警告通道 3** |
| `data GraphWarning = GraphWarning { gwSource :: Text, gwMessage :: Text }` | src/Knot/Graph/Types.hs:86-90 | graph-core/F001 | `graphNoteLines` 的兩個欄位 |
| `writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport` | src/Knot/Export.hs:33 | F001 | 管線第四站;`IOException` 由本層收斂(其 haddock src/Knot/Export.hs:29-32 明文) |
| `data ExportOptions = ExportOptions { rootDir :: FilePath, outputPath :: FilePath, commitPolicy :: CommitPolicy }` | src/Knot/Export/Types.hs:21-25 | F001 | `--output` 的落點;**`rootDir` 同名(踩雷點)** |
| `data CommitPolicy = AutoDetect \| NoCommit` | src/Knot/Export/Types.hs:30 | F001 | 固定填 `AutoDetect`(假設 A6) |
| `data ExportReport = ExportReport { xrPath :: FilePath, xrNodeCount :: Int, xrEdgeCount :: Int, xrNotes :: [Text] }` | src/Knot/Export/Types.hs:35-40 | F001 | `wrote` 行 + 警告通道 4(`xrNotes`) |
| `defaultOutputPath :: FilePath -> FilePath` | src/Knot/Export/Types.hs:45 | F001 | `--output` 未給時的預設路徑(F001 假設 A2 特地為本 feature 保留) |
| `renderMetaSummary :: ProjectMeta -> Text` | app/Knot/App/Summary.hs:52 | project-meta/F001 | `--summary meta`(C6 保留) |
| `renderFactSummary :: ExtractResult -> Text` | app/Knot/App/Summary.hs:102 | extraction/F002 | `--summary facts`(C6 保留) |
| `renderGraphSummary :: CodeGraph -> Text` | app/Knot/App/Summary.hs:142 | graph-core/F001 | `--summary graph`(C6 保留) |
| `loadQueryGraph :: FilePath -> IO (Either LoadError QueryGraph)` | (**尚未實作**)`F002` 設計文檔「新增的介面 › 契約面」→ 將落在 src/Knot/Query.hs | F002 | `query` 的第一站 |
| `queryGraphNotes :: QueryGraph -> [(Text, Int)]` | (**尚未實作**)`F002` 設計文檔「新增的介面 › 契約面」→ src/Knot/Query/Load.hs | F002 | 警告通道 5(未知 relation) |
| `data LoadError = LoadFileMissing Text \| LoadParseError Text \| LoadSchemaError Text` | (**尚未實作**)`F002` 設計文檔「新增的介面 › 契約面」→ src/Knot/Query/Types.hs | F002 | exit 1 的三種來源;取出其 `Text` 印 stderr |
| `data QueryNode = QueryNode { qnId :: NodeId, qnLabel :: Text, qnFile :: FilePath }` + `qgNodes :: QueryGraph -> [QueryNode]`(欄位選擇器) | (**尚未實作**)`F002` 設計文檔「實作方式 › 型別設計」→ src/Knot/Query/Types.hs | F002 | 起點/終點存在性檢查(F003 假設 A1 的建議) |
| `newtype NodeId = NodeId Text` `deriving (Eq, Ord, Show)` | (**尚未實作**)`F002` 設計文檔「型別設計」+「非契約面」(建構子匯出) | F002 | 從 CLI 字串建 `Reachable` / `ShortestPath` 的端點 |
| `runQuery :: QueryGraph -> QueryCommand -> QueryResult` | (**尚未實作**)`F003` 設計文檔「新增的介面 › 契約面」→ src/Knot/Query/Engine.hs | F003 | 四個子命令的執行 |
| `renderResult :: QueryResult -> Text` | (**尚未實作**)`F003` 設計文檔「新增的介面 › 契約面」→ src/Knot/Query/Render.hs | F003 | stdout 文字(本層負責 `hPutStr`) |
| `data QueryCommand = FindNodes Text \| Reachable NodeId Direction \| ShortestPath NodeId NodeId \| RankConnectivity Int` / `data Direction = Forward \| Reverse` | (**尚未實作**)`F003` 設計文檔「型別設計(契約原文)」→ src/Knot/Query/Types.hs | F003 | 四子命令 + `--reverse` + `--top N` 的對映目標 |
| `execParser :: ParserInfo a -> IO a` | optparse-applicative-0.19.0.0/src/Options/Applicative/Extra.hs:114 | - | `Main.hs` 的唯一進入點 |
| `execParserPure :: ParserPrefs -> ParserInfo a -> [String] -> ParserResult a` | 同上 Extra.hs:151-155 | - | **測試用**:純解析,不 exit |
| `defaultPrefs :: ParserPrefs` | 同上 Builder.hs:614 | - | `execParserPure` 的偏好參數(與 `execParser` 同一組) |
| `data ParserResult a = Success a \| Failure (ParserFailure ParserHelp) \| CompletionInvoked CompletionResult` | 同上 Types.hs:361-364 | - | 測試斷言解析成功/失敗 |
| `renderFailure :: ParserFailure ParserHelp -> String -> (String, ExitCode)` | 同上 Extra.hs:344-347 | - | 測試取出錯誤訊息與 exit code |
| `info :: Parser a -> InfoMod a -> ParserInfo a`(`infoFailureCode = 1`) | 同上 Builder.hs:511-522 | - | 組 `ParserInfo`;失敗 exit code 的出處 |
| `helper :: Parser (a -> a)` | 同上 Extra.hs:50-56 | - | 頂層 `--help` / `-h` |
| `hsubparser :: Mod CommandFields a -> Parser a` | 同上 Extra.hs:88-96 | - | 兩層子命令;**自動替每個子命令掛 `--help`** |
| `command :: String -> ParserInfo a -> Mod CommandFields a` | 同上 Builder.hs:243 | - | `extract` / `query` / `find` / `reachable` / `path` / `rank` |
| `strOption :: IsString s => Mod OptionFields s -> Parser s` | 同上 Builder.hs:367 | - | `--output` / `--hiedir` / `--graph` |
| `option :: ReadM a -> Mod OptionFields a -> Parser a` | 同上 Builder.hs:377 | - | `--backend` / `--summary` / `--top` |
| `eitherReader :: (String -> Either String a) -> ReadM a` | 同上 Builder.hs:148 | - | `--backend` / `--summary` 的列舉值解析與錯誤訊息 |
| `auto :: Read a => ReadM a` | 同上 Builder.hs:128 | - | `--top N` 的整數解析 |
| `switch :: Mod FlagFields Bool -> Parser Bool` | 同上 Builder.hs:348 | - | `--module-only` / `--include-tests` / `--strict` / `--reverse` |
| `strArgument :: IsString s => Mod ArgumentFields s -> Parser s` | 同上 Builder.hs:300 | - | `PATH` / `KEYWORD` / `ID` / `FROM` / `TO` |
| `long :: HasName f => String -> Mod f a` / `short :: HasName f => Char -> Mod f a` / `metavar :: HasMetavar f => String -> Mod f a` / `help :: String -> Mod f a` / `value :: HasValue f => a -> Mod f a` / `showDefault :: Show a => Mod f a` | 同上 Builder.hs:168 / 164 / 208 / 192 / 180 / 188 | - | 旗標修飾子(名稱、預設值、help 文字) |
| `fullDesc :: InfoMod a` / `progDesc :: String -> InfoMod a` / `header :: String -> InfoMod a` | 同上 Builder.hs:447 / 473 / 455 | - | `--help` 的內容 |
| `optional :: Alternative f => f a -> f (Maybe a)` | base-4.22.0.0 `Control.Applicative` | - | `--output` / `--hiedir` / `--summary` 的 `Maybe` 包裝 |
| `fromMaybe :: a -> Maybe a -> a` | base-4.22.0.0 `Data.Maybe` | - | `--output` 未給時取 `defaultOutputPath` |
| `try :: Exception e => IO a -> IO (Either e a)` | base-4.22.0.0 `Control.Exception` | - | 收斂 `writeCodegraph` 的 `IOException` |
| `exitWith :: ExitCode -> IO a` | base-4.22.0.0 `System.Exit` | - | `Main.hs` 把 `runCommand` 的 `ExitCode` 送出去 |
| `hPutStrLn :: Handle -> String -> IO ()` | base-4.22.0.0 `System.IO` | - | 錯誤行(非 `Text` 來源,如 `show e`) |
| `hPutStr :: Handle -> Text -> IO ()` | text-2.1.3 `Data.Text.IO` | - | 摘要 / 查詢結果 / 警告行的輸出(`Handle` 由呼叫端注入) |
| `pack :: String -> Text` | text-2.1.3 `Data.Text` | - | 組行文字(不依賴 `OverloadedStrings`,沿用 `Summary.hs` 慣例) |
| `scan-graph.mjs`(`codegraph.json` 消費端) | dev-flow 0.8.1 `arch-audit/scripts/scan-graph.mjs` | - | **不呼叫**;T9 手動對帳的驗收工具(D5) |

## 新增的介面

本 feature **不新增任何 library 公開面**——以下全部落在 executable `app/`(其他 `app/` 模組與
test-suite 可見,library 使用者看不到)。既有 `Knot.App.Summary` 的三個匯出**不動**。

### `Knot.App.Cli`

```haskell
-- | knot 的兩個子命令(system.md「CLI 介面(頂層契約)」)。
data Command = CmdExtract ExtractCmd | CmdQuery QueryCmd
  deriving (Eq, Show)

-- | @knot extract [PATH]@ 的六個旗標 + C6 的 --summary。
data ExtractCmd = ExtractCmd
  { ecPath         :: FilePath           -- ^ 位置參數 PATH,預設 "."
  , ecOutput       :: Maybe FilePath     -- ^ --output
  , ecBackend      :: BackendChoice      -- ^ --backend,預設 Auto
  , ecModuleOnly   :: Bool               -- ^ --module-only
  , ecIncludeTests :: Bool               -- ^ --include-tests
  , ecHieDir       :: Maybe FilePath     -- ^ --hiedir
  , ecStrict       :: Bool               -- ^ --strict
  , ecSummary      :: Maybe SummaryMode  -- ^ --summary;Nothing = 寫 codegraph.json
  }
  deriving (Eq, Show)

-- | C6:既有三個唯讀驗收輸出。
data SummaryMode = SummaryMeta | SummaryFacts | SummaryGraph
  deriving (Eq, Show)

-- | @knot query@:圖檔路徑 + 四子命令之一。
data QueryCmd = QueryCmd
  { qcFile    :: FilePath        -- ^ --graph,預設 "codegraph.json"(假設 A3)
  , qcCommand :: QueryCommand    -- ^ F003 的契約 DTO
  }
  deriving (Eq, Show)

-- | 頂層 ParserInfo(含 --help 與兩個子命令)。
cliParserInfo :: ParserInfo Command

-- | 旗標 → 四個子系統 Options DTO 的純對映(驗收標準 1;測試直接斷言)。
toMetaOptions    :: ExtractCmd -> MetaOptions
toExtractOptions :: ExtractCmd -> ExtractOptions
toBuildOptions   :: ExtractCmd -> BuildOptions
toExportOptions  :: ExtractCmd -> ExportOptions
```

### `Knot.App.Report`

```haskell
-- | 五條上游警告/摘要通道 → stderr 行(library 全程不印,D8)。
--   空輸入一律回 [](不產生噪音行)。
metaNoteLines    :: ProjectMeta   -> [Text]
extractNoteLines :: ExtractResult -> [Text]
graphNoteLines   :: CodeGraph     -> [Text]   -- ^ cgWarnings;F001 假設 A3 的落點
exportNoteLines  :: ExportReport  -> [Text]
queryNoteLines   :: QueryGraph    -> [Text]

-- | 唯一的列印函式;空清單不寫任何 byte。
emitNotes :: Handle -> [Text] -> IO ()
```

### `Knot.App.Run`

```haskell
-- | 依 Command 分派;兩個 Handle 由呼叫端注入(Main 給 stdout/stderr,測試給暫存檔)。
runCommand     :: Handle -> Handle -> Command    -> IO ExitCode
runExtractCmd  :: Handle -> Handle -> ExtractCmd -> IO ExitCode
runQueryCmd    :: Handle -> Handle -> QueryCmd   -> IO ExitCode
```

### `Main`

```haskell
main :: IO ()   -- execParser cliParserInfo >>= runCommand stdout stderr >>= exitWith
```

**非契約面登記**(供 `G-E001` 一併收斂;沿用 `F001` / `F002` / `F003` 的慣例):上列全部屬
executable 內部匯出,不進 library `exposed-modules`,因此**不擴大 library 公開面**;
其中 `toMetaOptions` / `toExtractOptions` / `toBuildOptions` / `toExportOptions` /
`metaNoteLines` / `extractNoteLines` / `graphNoteLines` / `exportNoteLines` / `queryNoteLines`
是**為 1-to-1 測試而暴露的縫**(`Knot.App.Summary` 的三個 render 函式同性質,已有前例)。

## TodoList

- [ ] T1: `Knot.App.Cli` 的 DTO 與頂層 parser 骨架——`Command` / `ExtractCmd` / `SummaryMode` /
      `QueryCmd`(`Eq`/`Show`)、`cliParserInfo`(`hsubparser` 掛 `extract` / `query`,頂層
      `<**> helper`);`knot-hs.cabal` 的 **executable 與 test-suite 兩段**各加
      `optparse-applicative ^>=0.19` 與四個 `other-modules`;library 段零變動、`version` 不動;
      `cabal build all --enable-tests` 在 `-Wall` 下零警告
      (`QueryCmd` 內嵌 `QueryCommand`,故本項需要 `F002` / `F003` 已落地)  `dep: F002, F003`
- [ ] T2: `extract` 子命令的解析——位置參數 `PATH`(預設 `"."`)與六個旗標
      (`--output` / `--backend` / `--module-only` / `--include-tests` / `--hiedir` / `--strict`)
      + `--summary meta|facts|graph`;`--backend` 與 `--summary` 以 `eitherReader` 限定取值,
      非法值的訊息列出合法選項  `dep: T1`
- [ ] T3: 旗標 → Options DTO 的四個純對映函式——`toMetaOptions` / `toExtractOptions` /
      `toBuildOptions` / `toExportOptions`,含 `defaultOutputPath` 預設、`commitPolicy = AutoDetect`、
      `hiedbExe`/`dbPath` 為 `Nothing`;**同名 `rootDir` 以 qualified import 處理**
      (`XT.` / `ET.`,不新增語言擴充、不動 library DTO)  `dep: T2`
- [ ] T4: `query` 子命令的解析——`--graph FILE`(預設 `codegraph.json`)+ 四個子命令
      `find KEYWORD` / `reachable ID [--reverse]` / `path FROM TO` / `rank [--top N]`(N 預設 10),
      各自對映成正確的 `QueryCommand` 建構子與 `Direction`  `dep: T1`
- [ ] T5: `Knot.App.Report` 的五條通道行渲染 + `emitNotes`——
      `metaNoteLines` / `extractNoteLines`(含 `erLevel` 與 `brUsed == False` 的降級行)/
      **`graphNoteLines`(`cgWarnings`,硬性要求)** / `exportNoteLines` / `queryNoteLines`;
      空輸入回 `[]`、空清單不寫任何 byte  `dep: T1`
- [ ] T6: `runExtractCmd`——四站管線組裝、`--summary` 三條路徑各只跑到需要的那一站、
      預設路徑寫 `codegraph.json` 並印 `wrote` 行、五條通道印 stderr(**含 `cgWarnings`**)、
      `IOException` 收斂成 exit 1、`--strict` 的跳檔判定  `dep: T3, T5`
- [ ] T7: `runQueryCmd`——`loadQueryGraph` → `LoadError` exit 1(訊息含路徑與問題)、
      `queryGraphNotes` 印 stderr、起點/終點不存在時印 `node not found` 但仍 exit 0、
      成功(含空結果)`renderResult` 走 stdout 且 exit 0  `dep: T4, T5`
- [ ] T8: `runCommand` 分派 + `Main.hs` 改寫——`main` 只剩
      `execParser >>= runCommand stdout stderr >>= exitWith`;移除既有 `getArgs` 解析與
      `--facts` / `--graph` 舊旗標(改由 `--summary` 承接);頂層/子命令 `--help` exit 0、
      未知子命令與缺參數 exit 1 且訊息走 stderr  `dep: T6, T7`
- [ ] T9: **兩個唯讀標的手動實跑**(D5 前例,非自動化)——MagicFarmer 與 particle-magic 各跑一次
      `knot extract <標的> --output <knot-hs 暫存>/…json`(**標的專案零寫入**),
      產出檔以 dev-flow `scan-graph.mjs` 解析成功;particle-magic 應出現
      `graph: …` 的同名 module 碰撞警告(驗收標準 9 的實地證明)  `dep: T8`

## 1-to-1 測試對照表

(全部掛在 `test/Main.hs` 新增的 `exportQueryF004Tests :: TestTree` 群組下,加進 `tests` 清單;
沿用既有 tasty + HUnit 慣例。解析類測試一律走
`execParserPure defaultPrefs cliParserInfo argv`,不碰 `getArgs`、不 exit;執行類測試走
`runCommand`/`runExtractCmd`/`runQueryCmd` 並注入暫存檔 `Handle`,跑完讀回內容比對;
暫存目錄沿用 `withExportDir`)

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_cli_toplevel_parse | `["--help"]` → `Failure` 且 `renderFailure` 的 `ExitCode` 為 `ExitSuccess`、訊息同時含 `extract` 與 `query`(驗收標準 4);`[]`(無子命令)→ `Failure` 且 exit code 為 `ExitFailure 1`;`["bogus"]` → `ExitFailure 1` 且訊息含 `bogus`;`["extract", "--help"]` 與 `["query", "--help"]` 皆 `ExitSuccess`(`hsubparser` 自動掛的 `--help`);`Command` / `ExtractCmd` / `QueryCmd` / `SummaryMode` 四個型別各建一值並比對 `Eq` |
| T2 | test_extract_flags_parse | `["extract"]` → `ecPath == "."` 且六個旗標皆為預設(`ecOutput`/`ecHieDir`/`ecSummary` 為 `Nothing`,`ecBackend == Auto`,三個 `Bool` 為 `False`);`["extract","proj","-o","x.json","--backend","imports","--module-only","--include-tests","--hiedir","dist/hie","--strict"]` → 八個欄位逐一等於預期值(驗收標準 1);`--backend` 三個取值分別得 `Auto` / `ImportsOnly` / `HiedbOnly`;`--backend bogus` → `Failure` `ExitFailure 1` 且訊息含 `auto`、`imports`、`hiedb`;`--summary meta|facts|graph` 分別得三個 `SummaryMode`,`--summary bogus` 失敗(驗收標準 3、5);`--output` 缺值 → `Failure` 且訊息含 `--output`;`["extract","a","b"]`(多餘位置參數)→ `Failure` |
| T3 | test_extract_options_mapping | 對一個八欄位皆非預設的 `ExtractCmd`:`toMetaOptions` 的 `root`/`includeTests`/`hieDirOverride` 三欄位逐一相符;`toExtractOptions` 的 `XT.rootDir == ecPath`、`backendChoice == ecBackend`、`hiedbExe == Nothing`、`dbPath == Nothing`(假設 A8);`toBuildOptions` 的 `moduleOnly == ecModuleOnly`;`toExportOptions` 的 `ET.rootDir == ecPath`、`outputPath == "x.json"`、`commitPolicy == AutoDetect`(假設 A6)。另一個 `ecOutput == Nothing` 的 `ExtractCmd`:`outputPath == defaultOutputPath ecPath`(釘住 F001 假設 A2 的分工);`ecPath` 同時等於三個 DTO 的路徑欄位(釘住三者同源) |
| T4 | test_query_flags_parse | `["query","find","Demo"]` → `qcFile == "codegraph.json"` 且 `qcCommand == FindNodes "Demo"`;`["query","--graph","out/g.json","find","x"]` → `qcFile == "out/g.json"`(假設 A3);`["query","reachable","A"]` → `Reachable (NodeId "A") Forward`、加 `--reverse` → `Reverse`(驗收標準 2);`["query","path","A","B"]` → `ShortestPath (NodeId "A") (NodeId "B")`,只給一個端點 → `Failure`;`["query","rank"]` → `RankConnectivity 10`(**預設 10**)、`["query","rank","--top","3"]` → `RankConnectivity 3`、`--top zzz` → `Failure ExitFailure 1`;`["query","find"]`(缺關鍵字)→ `Failure` 且訊息含 `KEYWORD`;`["query","bogus"]` → `Failure` |
| T5 | test_report_note_lines | 手寫值逐一驗證五條通道:`metaNoteLines`(含 1 條 `MetaWarning`)回 1 行且含 `mwPath` 與 `mwMessage`;`extractNoteLines`(`erLevel = ModuleLevel`、1 條 `brUsed = False` 的 `BackendReport`、1 條 `ExtractWarning`)回的行分別含 `ModuleLevel`、該後端名與 `brDetail`、`ewSource` 與 `ewMessage`,且 `brUsed = True` 的報告**不產生行**;**`graphNoteLines` 對 `cgWarnings = [GraphWarning "Main" "declared in 2 source files"]` 回 1 行且含兩個欄位內容(硬性要求的純函數面)**,`cgWarnings = []` 回 `[]`;`exportNoteLines` 對 `xrNotes = ["dropped external edges: 3"]` 回含該文字的 1 行;`queryNoteLines` 對含未知 relation 的 `QueryGraph` 回含 relation 名與邊數的行;五者對空輸入一律回 `[]`;`emitNotes h []` 寫出 0 byte、`emitNotes h [a,b]` 寫出兩行且每行以 `\n` 結尾 |
| T6 | test_run_extract | (a)對 `test/fixtures/graph` 跑 `runExtractCmd`(`--output` 指向暫存目錄):exit 0;輸出檔存在且 `loadQueryGraph` 讀得回(端到端貫通);stdout 含 `wrote` 與該路徑;stderr 含 `export:` 開頭的 `xrNotes` 行(驗收標準 8)。(b)**硬性要求的端到端**:在暫存目錄自建一個「兩個 `hs-source-dirs` 各有一個檔宣告同一個 module 名」的最小專案,跑 `runExtractCmd` → **stderr 含 `graph:` 開頭且含 `disambiguated` 的碰撞警告行**(驗收標準 9);同一次執行不加 `--strict` 時 exit 0,加 `--strict` 時 exit 1 且 stderr 含 `strict:`(驗收標準 7)。(c)三個 `--summary` 模式:輸出分別逐字元等於 `renderMetaSummary` / `renderFactSummary` / `renderGraphSummary` 對同一輸入的結果(驗收標準 3,證明既有輸出未被改動),且三者都**不**產生 `codegraph.json`。(d)`--output` 指向無法寫入的路徑(如既有檔案下的子路徑)→ exit 1 且 stderr 含 `export:`,不拋未捕捉例外 |
| T7 | test_run_query | 以 T6(a)產出的真實 `codegraph.json` 為輸入:`find` 命中時 stdout 等於 `renderResult` 的輸出且 exit 0;查無結果(`find "zzz"`、`path` 不連通)stdout 為對應的空結果行且 **exit 0**(驗收標準 6);不存在的檔案路徑 → exit 1 且 stderr 含該路徑與 `query:`(`LoadFileMissing`);暫存目錄寫一份壞 JSON(`"{"`)→ exit 1 且訊息指出問題(`LoadParseError`);寫一份缺 `nodes` 的 JSON → exit 1(`LoadSchemaError`);寫一份含 `"relation":"foo"` 的合法 JSON → exit 0 且 **stderr 含 `query:` 開頭、含 `foo` 與邊數的未知 relation 行**(驗收標準 8);`reachable NoSuchNode` → stderr 含 `node not found: NoSuchNode` 且 **exit 0**(假設 A4) |
| T8 | test_run_command_dispatch | `runCommand` 對 `CmdExtract` 與 `CmdQuery` 分派到正確的執行路徑(以「有無產出檔 / 有無查詢輸出」區分);`execParserPure` 解出的 `Command` 直接餵給 `runCommand` 走完一次 `extract` 與一次 `query`(釘住解析層與執行層的接縫);`--help` 與未知子命令由 `execParserPure` 回 `Failure`、`renderFailure` 的 exit code 分別為 `ExitSuccess` / `ExitFailure 1`(驗收標準 4、5);`app/Main.hs` 除了 `execParser`/`runCommand`/`exitWith` 之外不含任何分支(以人工複核,`Main` 不進 test-suite) |
| T9 | manual_readonly_targets_acceptance(**手動,非自動化**) | 實作階段由執行者跑並貼輸出:`knot extract <MagicFarmer> --output <暫存>/mf.json` 與 `knot extract <particle-magic> --output <暫存>/pm.json` 皆 exit 0;兩個標的專案 `git status` 保持乾淨(零寫入);兩份產出檔以 `node <dev-flow>/arch-audit/scripts/scan-graph.mjs` 解析成功(節點/邊數與 `imports` relation 皆被認得);particle-magic 的 stderr 出現 1 條 `graph:` 碰撞警告(驗收標準 10、9) |

## 待確認假設

- A1: `--summary` 模式下要不要照樣把五條通道印到 stderr(既有三個摘要本身已含各自的警告)
  → 採取:**照樣印**。理由:`--summary graph` 的 `renderGraphSummary` 只印 `cgWarnings`,
  看不到 `pmWarnings` / `erWarnings`;統一規則也讓「硬性要求」在四條路徑上都成立
  → 影響:`--summary meta` / `--summary graph` 會在 stdout 與 stderr 各出現一次同一條警告
  (兩條串流分開,不影響管線使用)。若裁定不印,`runExtractCmd` 的 `--summary` 分支跳過
  `emitNotes`,T6(c)加一條「stderr 為空」斷言
- A2: `--strict` 的「跳檔」如何判定(system.md 只寫「任何跳檔改為 exit 1」,而四個子系統沒有
  「跳檔數」欄位,只有警告清單)→ 採取:**`pmWarnings` + `erWarnings` + `cgWarnings` 三者任一非空
  即視為有跳檔**;`erReports` 中 `brUsed == False` 的**降級**不算(否則沒裝 hiedb 的環境
  在 `--backend auto` 下永遠 exit 1,與 ADR-002「降級而非失敗」直接衝突)
  → 影響:若裁定要更精確的跳檔計數,上游三個子系統的警告 DTO 需要新增「是否為跳檔」的標記
  (**契約變更**,本 feature 不擅自為之)
- A3: `knot query` 讀哪一份 `codegraph.json`,契約未定(design.md 的四條對映沒有路徑參數)
  → 採取:**新增 `--graph FILE`,預設 `codegraph.json`(相對於目前工作目錄)**。理由:`--output`
  可以把匯出改道,查詢面必須有辦法指回去;system.md 明文「內部旗標細節屬 Level 2/3 自主權」
  → 影響:若裁定不得新增旗標,改成只認 `./codegraph.json`,T4 少一條斷言,且改道匯出後無法查詢。
  **建議編排者把此旗標補進 `system.md` 的 CLI 頂層契約**
- A4: 查詢起點/終點不存在時的 exit code,契約只列了「`LoadError` exit 1」與「查無結果 exit 0」
  → 採取:**exit 0**,另在 stderr 印 `query: node not found: <id>`(落實 `F003` 假設 A1 的建議)。
  理由:不存在的 id 產生的是空結果不是載入失敗,契約的兩條規則裡它屬後者
  → 影響:若裁定應視為使用者輸入錯誤(exit 1),改 `runQueryCmd` 的一個分支與 T7 的一條斷言
- A5: 各種輸出走哪條串流,契約只寫「查詢結果 stdout」「警告與錯誤 stderr」
  → 採取:**stdout 只放查詢結果、`--summary` 摘要與 `wrote …` 行;五條通道與所有錯誤走 stderr**
  → 影響:若裁定 `xrNotes` 屬報告而非警告、應走 stdout,改 `runExtractCmd` 一行;
  但那會讓 `knot extract > file` 的 stdout 混入非結構化文字
- A6: `CommitPolicy` 沒有對應旗標(system.md 只說 `built_at_commit` 自動偵測)
  → 採取:**固定填 `AutoDetect`**,`NoCommit` 從 CLI 不可達(僅測試用)
  → 影響:若日後要 `--no-commit`,加一個 `switch` 與一條對映即可,不動 library
- A7: `--backend hiedb` 在階段一的註冊表下會得到**空事實流 + 「未選中」報告**
  (`src/Knot/Extract.hs:15-18` haddock 明載這是預期行為)→ 採取:**CLI 不特別攔截**,
  由 `extractNoteLines` 的降級行說明,產出一份 0 節點的 `codegraph.json`
  → 影響:若裁定 CLI 應在此拒絕執行,加一個前置檢查並回非 0;但那會把「後端註冊表」的知識
  洩漏進 CLI 層
- A8: `ExtractOptions` 的 `hiedbExe` / `dbPath` 沒有對應旗標,但 `system.md`「使用者與體量」
  提到「允許新建 `.knot/` 索引快取目錄,**`--db` 可改道**」,而同檔的「CLI 介面(頂層契約)」
  只列了六個旗標,不含 `--db` / `--hiedb` → 採取:**依契約卡的六旗標實作,兩個欄位一律填
  `Nothing`,不新增旗標**(契約卡的「明確不做」要求不改 Options DTO;新增旗標屬契約面)
  → 影響:兩個驗收標的若要把索引寫到自訂位置,S3 之前無法用 CLI 指定。
  **已列入回報請編排者裁決是否補 `--db` / `--hiedb` 到 system.md 的 CLI 契約**
- A9: `--top N` 給 0 或負數時要不要在解析層擋掉(`F003` 假設 A4 說「`F004` 若選擇在解析層擋掉
  負數則本項不觸發」)→ 採取:**不擋**,原樣傳給 `RankConnectivity`,由 `F003` 的 `take` 語意
  回空清單 → 影響:若裁定要擋,`--top` 改用 `eitherReader` 加範圍檢查,T4 加一條斷言
- A10: `--summary` 未出現在 `system.md` 的「CLI 介面(頂層契約)」(它是 build-log C6 期間新增、
  只寫進 export-query 的契約卡)→ 採取:**依契約卡實作**,並**建議編排者把 `--summary` 與
  `--graph` 補進 `system.md` 的 CLI 契約區塊** → 影響:不補的話,system.md 與實際 CLI 長期不一致,
  下一次 `/arch-audit system` 會把它列為契約落差
- A11: 既有 `--facts` / `--graph` 兩個舊旗標(`app/Main.hs:76-77`)在 C6 之後的去留
  → 採取:**移除**,語意由 `--summary facts` / `--summary graph` 承接(C6 原文是「收進
  `knot extract --summary`」)→ 影響:若裁定保留為別名,加兩個 `flag'` 並在對映層折成
  `SummaryMode`;但那會讓同一語意有兩個入口

## 實作備註

(撰寫時留空;開發過程中與設計的偏差記錄於此。executable 內部匯出的清單已預先登記在
「新增的介面」,供 build-log 階段一發現 2 所指的 `G-E001` 一併評估——本 feature 的匯出全部在
executable 段,不擴大 library 公開面。)
