---
id: F005
type: feature
title: cli-zero-setup
description: knot extract 砍五個旗標,接上整體失敗 exit 1 通道,--summary 收斂
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, F002, F004, extraction/F001, extraction/F005, extraction/F007, project-meta/F001, project-meta/F004, graph-core/F001]
related-adr: [ADR-006]
related-feature: []
---

# F005: cli-zero-setup — `knot extract .` 是使用者需要知道的全部

## 功能概述

ADR-006 在 CLI 組裝層的落地,也是 **S5 三件套的收尾者**:extraction/F007 與 project-meta/F004 改的是 DTO 的定義端,本 feature 改消費端——`knot extract` 砍掉五個旗標(`--backend`、`--module-only`、`--hiedir`、`--hiedb`、`--db`),`ExtractCmd` 對映同步上游的新形狀,`extract` 回 `Left ExtractFailure` 時印訊息、exit 1、不寫檔;`--summary facts` 不再印能力等級與後端報告。本 feature 做完,整套專案才重新編得過、測試才重新跑得動。

library 契約(匯出面、查詢面)**零變動**;`knot query` 零變動。

**驗收標準**(契約卡逐條對照):

| # | 契約卡 | 落地 | 測試 |
|---|---|---|---|
| 1 | `--help` 不再列出五個旗標;給了 exit 非 0 且訊息指出不認得 | `extractParser` 刪五個 `option` / `switch`;optparse-applicative 對未知旗標本來就 exit 1 並印 `Invalid option` | T1 |
| 2 | 剩餘四個旗標(`--output`、`--include-tests`、`--strict`、`--summary`)解析正確且對映到正確欄位 | `ExtractCmd` 只剩五個欄位(含 `ecPath`) | T1、T2 |
| 3 | `ExtractOptions` 對映只填 `rootDir`、`MetaOptions` 對映無 `hieDirOverride`(型別檢查即證明) | `toExtractOptions` / `toMetaOptions` 改寫;殘留欄位在上游刪掉後是編譯錯誤 | T2 |
| 4 | 假的 `extract` 回 `Left BuildFailed` → exit 1、stderr 含 `bfComponent` 與 `bfDetail`、`codegraph.json` 不存在 | `runExtractCmd` 新增 `Left` 短路;`extract` 以參數注入(見「實作方式」),測試才能餵假的 | T3、T4 |
| 5 | `Left` 的四種建構子各自有可辨識的訊息;`VersionMismatch` 含 `cabal install knot-hs -w ghc-<vmHie>` | `Report.extractFailureLines` 四個分支 | T3 |
| 6 | `--strict` 的判定不受 `Left` 影響(`Left` 永遠 exit 1) | 短路發生在 `finish` 之前 | T4 |
| 7 | `--summary facts` 不含「level」「backends」字樣;`--summary meta` 不含 `.hie` 段 | `renderFactSummary` 改版;`renderMetaSummary` **現況已不印 `.hie`**(讀 `app/Knot/App/Summary.hs` 確認),測試釘住即可 | T5 |
| 8 | `--summary` 在 `extract` 回 `Left` 時亦 exit 1 | 短路在 `--summary facts` / `graph` 分流之前 | T4 |
| 9 | `knot query` 四子命令零變動(F003 測試全綠) | 不碰 `queryParser` / `runQueryCmd` | T7(回歸) |
| 10 | 乾淨目標專案(無 `.hie`、無 `.knot/`)一個命令產出兩層圖——ADR-006 端對端 | `buildable` fixture 複製到暫存目錄跑 `runCommand`,輸出含 decl 節點與 `calls` 邊 | T7 |
| 11 | 五份黃金檔 byte 不變 | 黃金測試由 extraction/F007 改走 `scanImports`,本 feature 不碰;閘門時一併跑 | (F007 T6) |
| 12 | 閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0 | 三件套的共同閘門,本 feature 收尾時執行 | T8 |

## 相依性

`depends-on: [F001, F002, F004, extraction/F001, extraction/F005, extraction/F007, project-meta/F001, project-meta/F004, graph-core/F001]`,全部由「使用到的既有串接介面」表反推:

- **extraction/F007**(設計中,程式碼尚未落地):`extract` 的新簽名與 `ExtractOptions` / `ExtractResult` 的新形狀——本 feature 的核心輸入。**此相依依文檔的介面約定,不是既有程式碼**
- **project-meta/F004**(hie-retire,**尚未建檔,id 為預定編號**):`MetaOptions` 沒有 `hieDirOverride`。依 project-meta `design.md` 的 S5 契約(`data MetaOptions = MetaOptions { root, includeTests }`),**不是既有程式碼**(現行 `src/Knot/Meta/Types.hs:22` 仍有該欄位)
- **extraction/F005**:`ExtractFailure` 四個建構子(程式碼已存在)
- **extraction/F001**:`ExtractWarning`、`Fact` 的五個建構子(摘要分計)
- **F004** cli-wiring:`Knot.App.{Cli,Run,Report,Summary}` 是本 feature 修改的對象
- **F001** json-export:`writeCodegraph` / `ExportOptions` / `ExportReport`(不動,管線續用)
- **F002** graph-load:端對端測試以 `loadQueryGraph` 讀回輸出驗證兩層
- **project-meta/F001**、**graph-core/F001**:`loadProjectMeta` / `buildGraph` 管線續用;`BuildOptions.moduleOnly` 固定填 `False`

**三件套的落地順序(本 feature 裁定,取代 extraction/F007 文檔原本的建議)**:

```
extraction/F007(src/)→ project-meta/F004(src/)→ export-query/F005(app/ + test/)→ 共同閘門
```

理由:`toMetaOptions` 不填 `hieDirOverride` 在 `-Wall -Werror` 下是 `-Wmissing-fields` 錯誤,所以 project-meta/F004 必須先把欄位刪掉,本 feature 才寫得出「沒有那個欄位」的對映,不必留一行過渡的 `hieDirOverride = Nothing`。而 `test-suite knot-test` 把 `app/` 編進去,前兩個 feature 落地期間整套測試都跑不起來——**本 feature 是讓它重新跑得動的那一個**,三者的 1-to-1 測試全部在本 feature 收尾時一起跑。三者在同一條分支連續做完,中間狀態不得宣告任何一個 `done`。

**可平行性**:設計可與另外兩份平行;實作**必須排在最後**。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/export-query/design.md`「CLI `extract` 旗標對映與 exit code」節與 cli-zero-setup 契約卡:

| 契約項 | 本 feature 的落實 |
|---|---|
| 旗標對映表:`[PATH]` → 三個 DTO 的路徑欄位同源 | 不變 |
| `--output` → `ExportOptions.outputPath`,預設由 cli-assembly 算 | 不變 |
| `--include-tests` → `MetaOptions.includeTests` | 不變 |
| `--strict` → cli-assembly 的 exit code 判定 | 不變,但 `Left` 短路在它之前 |
| `--summary meta\|facts\|graph` | 保留;`facts` 內容收斂(下) |
| **S5 移除**五個旗標;對映上不再有 `backendChoice` / `hiedbExe` / `dbPath` / `hieDirOverride` | `ExtractCmd` 刪 `ecBackend` / `ecModuleOnly` / `ecHieDir` / `ecHiedbExe` / `ecDbPath`;`toExtractOptions` 只填 `rootDir`;`toMetaOptions` 只填 `root` / `includeTests`;`toBuildOptions` 固定 `moduleOnly = False` |
| exit code 表第一列:`Left ExtractFailure` → 1,與 `--strict` 無關,不寫檔,`VersionMismatch` 含安裝指令 | `runExtractCmd` 的短路 + `Report.extractFailureLines` |
| exit code 表其餘列 | 不變 |
| `--summary` 三站內容(S5 起):`meta` 無 `.hie` 段、`facts` 依建構子分計且不印能力等級與後端報告、`graph` 不變;`--summary` 仍驅動建置、`Left` 時 exit 1 | `renderFactSummary` 改版;`renderMetaSummary` 現況已合規;短路順序 |
| 資料流管線「組裝」段的 `Left ⇒ 印訊息、exit 1、不寫檔、到此為止` | 同上 |
| 明確不做:不新增 library 公開面、不替上游定義 DTO、不做舊旗標別名、不改 `knot query`、不動 README | 全部遵守;`BuildOptions.moduleOnly` 欄位屬 graph-core 契約,本 feature 只是不再填 `True`,**不**去 graph-core 刪欄位 |

## 實作方式

### `Knot.App.Cli`

```haskell
data ExtractCmd = ExtractCmd
  { ecPath         :: FilePath           -- ^ 位置參數 PATH,預設 "."
  , ecOutput       :: Maybe FilePath     -- ^ --output
  , ecIncludeTests :: Bool               -- ^ --include-tests
  , ecStrict       :: Bool               -- ^ --strict
  , ecSummary      :: Maybe SummaryMode  -- ^ --summary;Nothing = 寫 codegraph.json
  }
```

`extractParser` 對應刪五段;`backendReader` 刪除;`import Knot.Extract.Types (BackendChoice (..))` 刪除。四個對映:

```haskell
toMetaOptions c    = MetaOptions { root = ecPath c, includeTests = ecIncludeTests c }
toExtractOptions c = XT.ExtractOptions { XT.rootDir = ecPath c }
toBuildOptions _   = BuildOptions { moduleOnly = False }   -- 旗標已廢,graph-core 契約欄位保留
toExportOptions    -- 不變
```

`-o` 短旗標、`--help` 文案、`query` 整段**一字不動**。

### `Knot.App.Report`

通道 2 改為純警告行,外加新的整體失敗渲染:

```haskell
-- | 通道 2:erWarnings → "extract: <ewSource>: <ewMessage>";空輸入回 []。
extractNoteLines :: ExtractResult -> [Text]

-- | 整體失敗(ADR-006)→ stderr 行。四個建構子各自可辨識;永遠非空。
extractFailureLines :: ExtractFailure -> [Text]
```

四個分支的行文(固定前綴 `extract: `,沿用五條通道的命名慣例;`BuildFailed` 的 `bfDetail` 可能多行,逐行縮排列印,不截斷——cabal 的輸出雖已即時轉發,尾段重印一次讓失敗原因緊貼在 exit 之前):

| 建構子 | 行 |
|---|---|
| `BuildFailed c d` | `extract: build failed for <c>` + `d` 的每一行前加 `extract:   ` |
| `VersionMismatch h k` | `extract: .hie files were produced by GHC <h>, but this knot was built with GHC <k>` + `extract: install a matching knot: cabal install knot-hs -w ghc-<h>` |
| `IndexFailed d` | `extract: index failed: <d>` |
| `NoSources` | `extract: no Haskell sources in scope (check PATH and --include-tests)` |

文案是 Level 3 自主,只鎖三件事:前綴、四者可辨識、`VersionMismatch` 含 `cabal install knot-hs -w ghc-<vmHie>` 原文。extraction/F007 會刪掉 F006 留在 `HiedbFacts` 的過渡版 `renderFailure`,其措辭可直接搬來這裡。

### `Knot.App.Run`

`runExtractCmd` 的 `extract` 呼叫改為可注入——**執行層對上游進入點多型**,跟兩個 `Handle` 注入是同一個理由(端到端可測):

```haskell
-- | 四站管線;extract 以參數注入(Main 給 Knot.Extract.extract,測試給假的)。
runExtractCmdWith
  :: (XT.ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult))
  -> Handle -> Handle -> ExtractCmd -> IO ExitCode

runExtractCmd :: Handle -> Handle -> ExtractCmd -> IO ExitCode
runExtractCmd = runExtractCmdWith extract       -- 簽名不變,既有呼叫端(runCommand、測試)不受影響
```

管線(`--summary meta` 之後的段落):

```
er <- extractFn (toExtractOptions cmd) pm
case er of
  Left failure -> emitNotes hErr (extractFailureLines failure)
                  pure (ExitFailure 1)            -- 不看 --strict、不看 --summary、不寫檔、到此為止
  Right result -> emitNotes hErr (extractNoteLines result)
                  … 既有的 facts / graph / 寫檔分流,一字不動 …
```

`finish` 的註解(「`brUsed = False` 的降級不算」)刪除——沒有降級了。

### `Knot.App.Summary.renderFactSummary`

```
facts: <N> total, <a> modules, <b> imports, <c> decls, <d> refs, <e> instances
warnings: <W>
  M <file>  [<module>]            ← 逐筆,只印 module 層(2026-08-22 裁決)
  I <file>:<line>  <from> -> <to>
  ! <source>: <message>
```

`level:` / `backends:` 行與 `?` 行消失;decl 層只進計數(knot-hs 自身 decls 673 + refs 8210,逐筆印會淹掉對帳用的 module 層)。`instances` 分計現在恆 0(hie-facts 不產 `FactInstance`),仍印——它是契約建構子,日後補上 `implements` 邊時摘要不用改。`renderMetaSummary` / `renderGraphSummary` **不動**。

### 測試 fixture 的必要調整(T3–T7 的前提)

F004 的端到端測試(`test_run_extract` / `test_run_query` / `test_run_command_dispatch`)全部拿**不可建置的 `graph` fixture** 走 `extract`——S5 後那會是 `Left BuildFailed`。改為:

- **真實管線一律走 `buildable` fixture 複製到暫存目錄**(沿用 F006 的 `withFixtureScratch` 模式;直接指向 `test/fixtures/buildable/` 會在版控樹裡建 `.knot/`)。`find "Demo"` 的查詢斷言在 `Demo.Core` / `Demo.App` 上仍成立
- **`mkCollisionProject` 改成建得起來**:現行寫法的 executable `main-is: Dup.hs` 內容是 `module Dup where`,cabal 建不過。改為 library + 具名 sub-library(`library sub`,`hs-source-dirs: b`,`exposed-modules: Dup`)兩個 component 各宣告 `Dup`,`cgWarnings` 仍恰一條,而且現在**真的會被 cabal 建置**——這同時驗證了「同名 module 分在不同 component 目錄」在 build-driver 規則 6 下的 `.hie` 不會互相覆蓋(G-B001 的根因)。加上 `cabal.project`(`packages: .`)
- 每個真實管線測試首次呼叫 cabal 約 1–4 s、之後暫存目錄內增量;整套測試時間以 F006 的 204 s 為基準再加數十秒,可接受

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文;標「(文檔)」者來自設計文檔的介面約定,程式碼尚未落地。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `extract :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)`(文檔) | `.design/subsystems/extraction/features/F007-two-layer-contract.md`「新增的介面」 | extraction/F007 | 管線第二站;`runExtractCmdWith` 的注入參數型別 |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath }`、`data ExtractResult = ExtractResult { erFacts :: [Fact], erWarnings :: [ExtractWarning] }`(文檔) | 同上 | extraction/F007 | `toExtractOptions` 的目標形狀;`extractNoteLines` / `renderFactSummary` 的輸入 |
| `data ExtractFailure = BuildFailed { bfComponent :: Text, bfDetail :: Text } \| VersionMismatch { vmHie :: Text, vmKnot :: Text } \| IndexFailed { ifDetail :: Text } \| NoSources` | `src/Knot/Extract/Types.hs` | extraction/F005 | `extractFailureLines` 的四個分支 |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` | `src/Knot/Extract/Types.hs` | extraction/F001 | 通道 2 的行渲染 |
| `data Fact = FactModule {…} \| FactImport {…} \| FactDecl {…} \| FactRef {…} \| FactInstance {…}` | `src/Knot/Extract/Types.hs` | extraction/F001 | `renderFactSummary` 依建構子分計 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | `src/Knot/Meta.hs:29` | project-meta/F001 | 管線第一站,不變 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool }`(文檔;現行程式碼 `src/Knot/Meta/Types.hs:22` 仍含 `hieDirOverride :: Maybe FilePath`) | `.design/subsystems/project-meta/design.md`「對外契約」 | project-meta/F004 | `toMetaOptions` 的目標形狀 |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph`、`data BuildOptions = BuildOptions { moduleOnly :: Bool }` | `src/Knot/Graph.hs:37`、`src/Knot/Graph/Types.hs:33` | graph-core/F001 | 管線第三站;`moduleOnly` 固定 `False` |
| `data CodeGraph = CodeGraph { cgNodes :: [GraphNode], cgEdges :: [GraphEdge], cgStats :: GraphStats, cgWarnings :: [GraphWarning] }` | `src/Knot/Graph/Types.hs:39` | graph-core/F001 | 通道 3 不變;端對端測試數 decl 節點與 `calls` 邊 |
| `writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport`、`data ExportOptions = ExportOptions { rootDir :: FilePath, outputPath :: FilePath, commitPolicy :: CommitPolicy }`、`data ExportReport = ExportReport { xrPath :: FilePath, xrNodeCount :: Int, xrEdgeCount :: Int, xrNotes :: [Text] }` | `src/Knot/Export.hs:33`、`src/Knot/Export/Types.hs:18,32` | F001 | 管線第四站,不變 |
| `loadQueryGraph :: FilePath -> IO (Either LoadError QueryGraph)` | `src/Knot/Query.hs` | F002 | 端對端測試讀回輸出 |
| `data ExtractCmd = ExtractCmd { ecPath, ecOutput, ecBackend, ecModuleOnly, ecIncludeTests, ecHieDir, ecHiedbExe, ecDbPath, ecStrict, ecSummary }`、`cliParserInfo :: ParserInfo Command`、`toMetaOptions :: ExtractCmd -> MetaOptions`、`toExtractOptions :: ExtractCmd -> XT.ExtractOptions`、`toBuildOptions :: ExtractCmd -> BuildOptions`、`toExportOptions :: ExtractCmd -> ET.ExportOptions` | `app/Knot/App/Cli.hs` | F004 | 本 feature 修改的對象 |
| `runCommand :: Handle -> Handle -> Command -> IO ExitCode`、`runExtractCmd :: Handle -> Handle -> ExtractCmd -> IO ExitCode` | `app/Knot/App/Run.hs` | F004 | 前者不動;後者改為 `runExtractCmdWith extract` |
| `extractNoteLines :: ExtractResult -> [Text]`、`emitNotes :: Handle -> [Text] -> IO ()` | `app/Knot/App/Report.hs` | F004 | 前者改寫;後者續用 |
| `renderFactSummary :: ExtractResult -> Text`、`renderMetaSummary :: ProjectMeta -> Text` | `app/Knot/App/Summary.hs` | F004 | 前者改寫;後者只加測試釘住「無 `.hie` 段」 |

## 新增的介面

**不新增任何 library 公開面**。以下全部在 executable `app/`(test-suite 經共用 `hs-source-dirs` 可見):

```haskell
-- Knot.App.Cli(形狀變更)
data ExtractCmd = ExtractCmd
  { ecPath :: FilePath, ecOutput :: Maybe FilePath, ecIncludeTests :: Bool
  , ecStrict :: Bool, ecSummary :: Maybe SummaryMode }
  deriving (Eq, Show)
-- 移除:ecBackend / ecModuleOnly / ecHieDir / ecHiedbExe / ecDbPath、backendReader

-- Knot.App.Report(新增)
extractFailureLines :: ExtractFailure -> [Text]

-- Knot.App.Run(新增;runExtractCmd 簽名不變)
runExtractCmdWith
  :: (XT.ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult))
  -> Handle -> Handle -> ExtractCmd -> IO ExitCode
```

## TodoList

- [x] T1: `Knot.App.Cli`——`ExtractCmd` 砍五欄、`extractParser` 砍五段、刪 `backendReader` 與 `BackendChoice` import  `dep: -`
- [x] T2: 四個對映同步上游新形狀(`toMetaOptions` 無 `hieDirOverride`、`toExtractOptions` 只填 `rootDir`、`toBuildOptions` 固定 `False`)  `dep: T1`
- [x] T3: `Knot.App.Report`——`extractNoteLines` 改純警告行;新增 `extractFailureLines` 四分支(`VersionMismatch` 含安裝指令)  `dep: -`
- [x] T4: `Knot.App.Run`——`runExtractCmdWith` 注入 `extract`,`Left` 短路(exit 1、不寫檔、在 `--summary` 分流與 `--strict` 之前);`runExtractCmd = runExtractCmdWith extract`  `dep: T2, T3`
- [x] T5: `Knot.App.Summary.renderFactSummary` 改版(計數行全建構子、逐筆只印 M / I、刪 level / backends / `?` 行)  `dep: -`
- [x] T6: 測試搬遷——F004 的 `test_extract_flags_parse` / `test_extract_options_mapping` / `test_report_note_lines` / `test_render_fact_summary` 改寫;`baseExtractCmd` / `fullExtractCmd` 去五欄;`mkCollisionProject` 改為可建置(library + sub-library);真實管線測試改走 `buildable` 暫存副本  `dep: T4, T5`
- [x] T7: 端對端——乾淨 `buildable` 副本 `runCommand ["extract", dir]` 一次跑完,輸出含 decl 節點與 `calls` 邊;`knot query` 四子命令回歸  `dep: T6`
- [x] T8: 三件套共同閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0、`cabal test` 全綠(含 extraction/F007、project-meta/F004 的 1-to-1 測試與五份黃金檔)  `dep: T7`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_extract_flags_parse`(改寫) | `["extract","proj","-o","x.json","--include-tests","--strict","--summary","facts"]` 解出五欄正確;`extract --help` 的文字含 `--output` / `--include-tests` / `--strict` / `--summary`、**不含** `--backend` / `--module-only` / `--hiedir` / `--hiedb` / `--db`;五個舊旗標各自 `expectParseFailure` → exit 非 0 且訊息含該旗標名 |
| T2 | `test_extract_options_mapping`(改寫) | `fullExtractCmd`(五欄全非預設)→ `toMetaOptions` 等於 `MetaOptions { root = "proj", includeTests = True }`(記錄語法逐欄建構,殘留欄位是編譯錯誤)、`toExtractOptions` 等於 `XT.ExtractOptions { XT.rootDir = "proj" }`、`toBuildOptions` 的 `moduleOnly` 為 `False`、`toExportOptions` 不變 |
| T3 | `test_extract_failure_lines` | 四個建構子各渲染一次:全部以 `extract: ` 起頭、互不相同;`BuildFailed "lib:x" "line1\nline2"` 的輸出含 `lib:x`、`line1`、`line2`;`VersionMismatch "9.12.2" "9.14.1"` 的輸出含 `cabal install knot-hs -w ghc-9.12.2` 原文與 `9.14.1`;`IndexFailed d` 含 `d`;`NoSources` 非空。另:`extractNoteLines` 對零警告回 `[]`、對一則警告回恰一行含 `ewSource` 與 `ewMessage`、**不再有** `extract: level` 行(`test_report_note_lines` 通道 2 段同步改寫) |
| T4 | `test_run_extract_failure_channel` | 以 `runExtractCmdWith` 注入假 `extract`:(a) 回 `Left (BuildFailed "lib:demo" "boom")` → `ExitFailure 1`、stderr 含 `lib:demo` 與 `boom`、`--output` 指定的檔案**不存在**;(b) 同上加 `ecStrict = True` → 仍 `ExitFailure 1` 且 stderr 無 `strict:` 行;(c) `ecSummary = Just SummaryFacts` / `Just SummaryGraph` → 皆 `ExitFailure 1`、stdout 為空;(d) `ecSummary = Just SummaryMeta` → `ExitSuccess`(`meta` 站在 `extract` 之前收工,假 `extract` 未被呼叫,以 IORef 證明);(e) 回 `Right` 時行為與注入真實 `extract` 的既有 `test_run_extract` 一致(重用其斷言) |
| T5 | `test_render_fact_summary`(改寫)+ `test_render_meta_summary_no_hie` | 前者:含 2 `FactModule` / 1 `FactImport` / 2 `FactDecl` / 3 `FactRef` 的 `ExtractResult` → 輸出含 `facts: 8 total, 2 modules, 1 imports, 2 decls, 3 refs, 0 instances`、`warnings:` 行、M / I 行;**不含** `level`、`backends`、`  ? `;decl / ref 不逐筆出現;兩次渲染相同。後者:對 `comps` fixture 的 `ProjectMeta` 渲染,輸出不含 `.hie` 與 `hie` 段標記 |
| T6 | `test_run_extract`(改寫)+ `test_run_query`(改寫)+ `test_run_command_dispatch`(改寫) | 三者的真實管線段全部改為 `buildable` 暫存副本;`mkCollisionProject` 產出的專案真的被 cabal 建置成功且 `cgWarnings` 恰一條(`Dup` 於 `a/Dup.hs`、`b/Dup.hs`);`--strict` 下 `graph:` 警告仍轉 exit 1;三個 `--summary` 輸出逐字元等於對應 render 函式、不寫檔;寫不出去的路徑仍 exit 1 |
| T7 | `test_zero_setup_end_to_end` | `buildable` 複製到**全新**暫存目錄(斷言起始時無 `.knot/`、無任何 `.hie`),`expectParse ["extract", dir]` → `runCommand` → `ExitSuccess`;`dir/codegraph.json` 存在且 `loadQueryGraph` 成功;讀回的 JSON 節點含至少一個 `source_location` 且 id 含 `Demo.Core.`(decl 節點)、邊含 `relation = "calls"`;`dir/.knot/.gitignore` 存在。回歸:F003 的 `exportQueryF003Tests` 全綠、`["query","--graph",…,"find","Demo"]` 仍命中 |
| T8 | 閘門(人工執行,結果記入實作備註) | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0;`cabal test` 全綠;對 MagicFarmer 與 particle-magic **唯讀**實跑 `knot extract <path> -o <暫存>`(會在兩個標的內建 `.knot/`——system.md 明訂的唯一允許副作用)產出兩層圖且 `scan-graph.mjs` 解析成功 |

## 實作備註

### 落地(2026-08-22)

`app/` 四個模組照「實作方式」落地,無介面偏差:`ExtractCmd` 五欄、`extractParser` 四段、`backendReader` 刪除;`toBuildOptions` 固定 `moduleOnly = False`;`extractNoteLines` 純警告行、`extractFailureLines` 四分支;`runExtractCmdWith` 注入 `extract`、`Left` 短路在 `--summary facts` / `graph` 分流與 `--strict` 之前;`renderFactSummary` 計數行五建構子分計、逐筆只印 M / I。`renderMetaSummary` 現況本就不印 `.hie`,以 `test_render_meta_summary_no_hie` 釘住。

測試搬遷依文檔:`mkCollisionProject` 改為 library + `library sub`(各一個 `Dup`,各帶一個頂層宣告——decl 層零宣告會被規則 3 判 `IndexFailed`,這點文檔沒寫到)+ `cabal.project`,真的被 cabal 建置成功且 `cgWarnings` 恰一條;`test_run_extract` / `test_run_query` / `test_run_command_dispatch` 的真實管線段全部改走 `buildable` 暫存副本;`test_run_extract_failure_channel` 以假 `extract` 驗五種情況;`test_zero_setup_end_to_end` 對全新副本(斷言起始無 `.knot/`、無 `.hie`)跑 `runCommand ["extract", dir]`,讀回 JSON 含 `Demo.Core.` 起頭且帶 `source_location` 的節點與 `relation = "calls"` 的邊,`.knot/.gitignore` 存在,`query find Demo` 仍命中。

整套測試時間:184 s(F006 基準 204 s;真實管線改走 buildable 副本後反而變快——graph fixture 原本每次都要等 cabal 失敗)。

### 共同閘門(T8,2026-08-22)

| 項目 | 結果 |
|---|---|
| `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` | exit 0,零警告 |
| `cabal test` | **139 / 139 綠**(184 s);含 extraction/F007 7 條、project-meta/F004 3 條、本 feature 4 條、五份黃金檔 byte 不變 |
| MagicFarmer(唯讀,`-o` 指向暫存) | `Right`:1,580 nodes、6,576 edges;`scan-graph.mjs` 解析成功,關係分布 calls 3,842 / contains 1,513 / uses 931 / imports 290 |
| particle-magic(唯讀,`-o` 指向暫存) | `Right`:1,567 nodes、7,027 edges;`scan-graph.mjs` 解析成功,關係分布 calls 4,683 / contains 1,521 / uses 696 / imports 127 |

兩個標的原本都沒有 `.knot/`,一個命令(`knot extract <path> -o <暫存>`)從零建置到兩層圖——ADR-006 的端對端在真實專案上成立;兩個標的內除了新建的 `.knot/`(自帶 `.gitignore`)沒有任何異動。`scan-graph.mjs` 回 exit 1 是它自己的可信度警告(從 knot-hs 目錄執行,圖的 commit 與當前 HEAD 不同、子系統 code-paths 覆蓋率低),不是解析失敗。

### 偏差

本 feature 無。三件套唯一的偏差在 extraction/F007(selfcheck 節點門檻 548 → 526,理由與逐 id 比對見其實作備註)。
