---
id: F001
type: feature
title: json-export
description: 把 CodeGraph 投影成 codegraph.json 並回報匯出摘要
status: open
created: 2026-08-21
updated: 2026-08-21
depends-on: [project-meta/F001, extraction/F001, extraction/F002, graph-core/F001]
related-adr: [ADR-003]
related-feature: []
---

# F001: json-export — CodeGraph → codegraph.json 投影與匯出報告

## 功能概述

export-query 的**第一個實體**,也是主架構 S1「project-meta → extraction → graph-core → export-query」的最後一段:把 graph-core 的內部圖 IR `CodeGraph` 投影成 dev-flow 契約格式的 `codegraph.json`(規格見 `ADR-003`),寫到磁碟,並回傳 `ExportReport` 供 CLI 層列印。本 feature 一次立起 export-writer 模組與匯出面全部對外 DTO。

**要解決的問題**:`CodeGraph` 是 knot-hs 的內部模型(帶 `NodeKind`、`geLine`、`GraphStats`、`GraphWarning` 等下游不認識的資訊),dev-flow 只認 `codegraph.json` 的欄位集合。中間這層投影必須(a)**只輸出契約欄位**、(b)**byte 級決定性**(同一 `CodeGraph` 兩次序列化完全相同,git diff 才有意義)、(c)**排版對 git diff 友善**(委派決策 D4:每個節點/邊一行)。aeson 的 `toJSON` / Generic 走 `KeyMap`,欄位順序不可靠,因此走 `Data.Aeson.Encoding` 顯式控制(委派決策 D9)。

**驗收標準**(契約卡原文):

1. 輸出的 JSON 含 `directed: true`;每個節點有 `id` / `label` / `source_file`;每條邊有 `source` / `target` / `relation` / `confidence: "EXTRACTED"`
2. `gnLine` 有值的節點輸出 `source_location: "L<行>"`
3. 在 git repo 內執行時頂層有 `built_at_commit` 且等於 `git rev-parse HEAD`;非 repo 時該欄位不存在**且無警告**
4. 同一 `CodeGraph` 兩次序列化 byte 級相同
5. `xrNotes` 含 `GraphStats` 的丟棄 / 過濾 / 去重摘要
6. 測試直接呼叫 `writeCodegraph` 寫出真實檔案,該檔以 dev-flow 的 `scan-graph.mjs` 驗證可解析(CLI 入口在 `F004`,故兩個驗收標的的實跑順延至 `F004`;`scan-graph.mjs` 的對帳依委派決策 D5 由編排者在閘門前手動跑,**不在 Haskell 測試裡 shell out node**)

**明確不做**(契約卡底線):不讀 JSON(`F002` graph-load 的事);不印 stdout / stderr(報告由 CLI 層印,承 D8「library 全程不印任何輸出」);不改 `CodeGraph` 內容;不輸出 IR 的額外欄位(`gnKind` / `geLine` / `GraphWarning` 一律不進 JSON,型別等擴充留給未來)。另承子系統邊界:不建圖、不改圖。另承 D3:本階段**不動 `app/Main.hs`**,CLI 入口(含 `--output` 等旗標)全部集中在 `F004` cli-wiring。另承 D6:`knot-hs.cabal` 的 `version` 維持 `0.0.1.0` 不動。

## 相依性

`depends-on: [project-meta/F001, extraction/F001, extraction/F002, graph-core/F001]`,四條皆由「使用到的既有串接介面」表反推,四份文檔皆 `status: done`、程式碼已在 `main`(commit `1ea5f27`),故**全部是既有程式碼查證**(2026-08-21 自來源檔讀出原文),沒有任何一條是文檔約定:

- **`graph-core/F001`(module-graph,跨子系統)——唯一的產品面相依**:`writeCodegraph` 第二參數 `CodeGraph` 及其全部欄位(`cgNodes` / `cgEdges` / `cgStats`),以及投影要讀的 `GraphNode`(`gnId` / `gnLabel` / `gnFile` / `gnLine`)、`GraphEdge`(`geSource` / `geTarget` / `geRelation`)、`Relation` 五個建構子(投影規則 1 的對映定義域)、`NodeId`(取值)、`GraphStats` 四個欄位(`xrNotes` 的來源)。**同時是決定性的前提**:投影**不重排** `cgNodes` / `cgEdges`,直接沿用 graph-core 組裝規則 7 已經排好的序(`cgNodes` 依 `gnId`、`cgEdges` 依 `(geSource, geRelation, geTarget)`);沒有那層排序,規則 5 的 byte 級決定性不成立
- **`project-meta/F001`(scan-baseline,跨子系統)——僅測試路徑**:T6 端到端要一個「真實 fixture 專案 → 非空圖 → 真實 JSON 檔」的輸入,第一段是 `loadProjectMeta` / `MetaOptions`
- **`extraction/F001`(fact-contract,跨子系統)——僅測試路徑**:同一條端到端的第二段 `extract` / `ExtractOptions` / `BackendChoice`
- **`extraction/F002`(import-scan,跨子系統)——僅測試路徑的資料依賴**:`importScanBackend` 是目前唯一註冊在 `Knot.Extract.registeredBackends` 的後端,沒有它端到端的事實流為空、圖為空、JSON 只剩空陣列,驗不到節點與邊的欄位。本 feature **不 import** `Knot.Extract.ImportScan`(資料依賴而非呼叫依賴)

未列入的相依與理由:

- **export-query 的 `F002` / `F003` / `F004`**:方向相反(`F002` 讀本 feature 寫出的檔、`F004` 呼叫本 feature 的進入點)
- **graph-core 的 `F002` / `F003`(decl 層)**:它們只讓 `cgNodes` 多出 `DeclNode` / `InstanceNode` 列、`cgEdges` 多出 `RCalls` / `RUses` / `RImplements` / `RContains` 列,**不改型別**;本 feature 的投影規則 1 已把五個 `Relation` 建構子全部對映、節點投影不看 `gnKind`,decl 層上線時匯出層零改動
- **`project-meta/F002` / `F003`**:只改變 `sfIncluded` / `pmHie` 的填值語意,不改型別,也不在本 feature 的呼叫路徑上
- **`ADR-003`** 列在 `related-adr` 而非 `depends-on`:它是格式的權威來源(欄位集合、relation 兩類、`source_file` 路徑規則),不是任務文檔

**可平行性**:**可**與任何其他子系統的任務平行(四條相依全部已完成並在 `main`)。但 export-query 內部必須序列:`F002` graph-load 讀的是本 feature 的輸出格式,`F004` cli-wiring 呼叫本 feature 的進入點,兩者都排在本 feature 之後。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/export-query/design.md`「對外契約 › 匯出面」與「投影規則」,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| `writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport` | `Knot.Export.writeCodegraph`,簽名一字不差 |
| DTO `ExportOptions { rootDir, outputPath, commitPolicy }` | `Knot.Export.Types`,三欄位名與型別依契約**現行**原文(編排者已依 build-log C1 補上 `rootDir`) |
| DTO `CommitPolicy = AutoDetect \| NoCommit` | 同上,兩建構子語意依契約註解(`AutoDetect` 在 `rootDir` 跑 git;失敗則省略欄位不警告) |
| DTO `ExportReport { xrPath, xrNodeCount, xrEdgeCount, xrNotes }` | 同上;`xrNotes :: [Text]` 為 `GraphStats` 摘要行,由 CLI 層列印(library 不印) |
| 投影規則 1(relation 對映) | `relationText`:`RImports → "imports"`、`RCalls → "calls"`、`RUses → "uses"`、`RImplements → "implements"`、`RContains → "contains"`,五對映全部落地(decl 層邊尚未產生,但對映已完備) |
| 投影規則 2(節點欄位) | `id` = `NodeId` 原文、`label` = `gnLabel`、`source_file` = `gnFile`(**原樣輸出**,已由 project-meta 的 `sfPath` 保證 repo 相對 + 正斜線,匯出層不再正規化)、`source_location` 僅在 `gnLine == Just n` 時輸出 `"L" <> show n` |
| 投影規則 3(邊欄位) | `source` / `target` / `relation` / `confidence`,`confidence` 恆為 `"EXTRACTED"`(ADR-003:GHC 抽取是事實不是推測);**不輸出 `geLine`**(見假設 A5) |
| 投影規則 4(頂層欄位) | `directed` 恆為 `true`;`built_at_commit` 依 `CommitPolicy` 輸出或整欄省略 |
| 投影規則 5(決定性) | 三重保證:欄位順序由 `Data.Aeson.Encoding` 顯式串接(不走 `KeyMap`)、清單順序沿用 `cgNodes` / `cgEdges` 原序(不重排、不去重)、寫檔走 `Data.ByteString.Builder.writeFile`(binary,`\n` 不會在 Windows 被轉成 `\r\n`) |
| 資料流管線「匯出」段落 | `CodeGraph + ExportOptions → 投影(規則 1–5)→ commit 偵測 → 寫 codegraph.json → ExportReport`,順序與契約圖一致 |
| 「使用的技術」· aeson | 用 `Data.Aeson.Encoding` 做物件層編碼與字串 escaping;**不用** `toJSON` / Generic(順序不可靠) |
| 「使用的技術」· `git rev-parse HEAD` 在 `rootDir` 執行、對目標專案唯讀、失敗即省略 | `Knot.Export.Commit.detectCommit`,以 `System.Process` 的 `cwd = Just rootDir` 落實,stdout/stderr 全部捕獲不外流 |

**未觸碰的契約面**:查詢面四個函式與其 DTO(`F002` / `F003`)、CLI 子命令對映(`F004`)。本 feature 不新增任何契約外的公開面(`Knot.Export.Encode` / `Knot.Export.Commit` 的匯出函式屬非契約面,以 haddock 標註,沿用 graph-core `FactGate` / `NodeMint` / `EdgeDerive` 的既有慣例)。

## 實作方式

### 模組配置

Level 2 的內部模組表只列一個 `export-writer`(且明載「匯出面單一模組無內部介面」)。Haskell 落地時拆成四個模組(實作自主權,沿用 `Knot.Meta` / `Knot.Extract` / `Knot.Graph` 三個子系統「`*.Types` + 進入點 + 內部模組」的既有形狀,見假設 A1):

| Haskell 模組 | 職責 | IO |
|---|---|---|
| `Knot.Export.Types` | `ExportOptions` / `CommitPolicy` / `ExportReport` + 非契約面 `defaultOutputPath` | 無 |
| `Knot.Export.Encode` | 投影規則 1–5 的**純函數**:`CodeGraph → Builder`、`GraphStats → [Text]` | 無 |
| `Knot.Export.Commit` | `CommitPolicy → rootDir → IO (Maybe Text)`:commit 偵測 | 有(唯讀:跑 git) |
| `Knot.Export` | 進入點 `writeCodegraph`:偵測 → 編碼 → 建父目錄 → 寫檔 → 組 `ExportReport` | 有(寫檔) |

四個模組全部進 `exposed-modules`(測試要直接測 `Knot.Export.Encode` 的純函數與 `detectCommit` 的三個分支)。

### JSON 版面(委派決策 D4:半 pretty)

**物件層壓成單行、文件層每個欄位/元素一行**。精確版面(`␣` 表空格,行尾一律單一 `\n`,檔尾有結尾換行):

```text
{
␣␣"directed":␣true,
␣␣"built_at_commit":␣"<sha>",
␣␣"nodes":␣[
␣␣␣␣{"id":"…","label":"…","source_file":"…"},
␣␣␣␣{"id":"…","label":"…","source_file":"…","source_location":"L42"}
␣␣],
␣␣"links":␣[
␣␣␣␣{"source":"…","target":"…","relation":"imports","confidence":"EXTRACTED"}
␣␣]
}
```

規則拆解:

- **頂層欄位順序固定**:`directed` → `built_at_commit`(僅在有值時整行出現,連同其逗號)→ `nodes` → `links`。`links` 恆為最後一欄,不留尾逗號
- **頂層冒號後有一個空格**(`"directed": true`),**物件內冒號後無空格**(`"id":"…"`)——與 D4 範例的視覺一致;物件內的緊湊形式由 aeson `E.pairs` 自然產生(已查證 `pair'` 用 `char7 ':'`、`commas` 用 `char7 ','`,無空白)
- **節點物件欄位順序**:`id` → `label` → `source_file` → (`source_location`,僅 `gnLine == Just n`)
- **邊物件欄位順序**:`source` → `target` → `relation` → `confidence`
- **陣列元素**:每個物件縮排 4 空格,元素之間 `,\n`,最後一個元素後直接 `\n` 再 `␣␣]`
- **空陣列**壓成同一行:`␣␣"nodes":␣[],` / `␣␣"links":␣[]`(避免產生 `[\n  ]` 這種空殼)
- **編碼**:UTF-8,無 BOM。aeson 的 `escapeAscii` 只escape `\` `"` 與 `< 0x20` 的控制字元,非 ASCII 原樣輸出 UTF-8 位元組(已自 `Data/Aeson/Encoding/Builder.hs:108-133` 查證),對 `instance` 標頭等含符號字串安全且決定性

實作上:每個節點 / 邊物件用 `E.pairs (E.pair k v <> …)` 產出 `Encoding`,經 `E.encodingToLazyByteString` 轉 lazy `ByteString`,再以 `BB.lazyByteString` 併入文件層 `Builder`;文件層的骨架(大括號、縮排、逗號、換行、`"directed": true`)是 ASCII 字面量,以 `BB.string7` / `BB.char7` 直接組。鍵一律以 `Data.Aeson.Key.fromText` 建構(不依賴 `OverloadedStrings`)。

### commit 偵測

```text
detectCommit NoCommit   _root = pure Nothing
detectCommit AutoDetect  root =
  try (readCreateProcessWithExitCode (proc "git" ["rev-parse","HEAD"]) { cwd = Just root } "")
    ├─ Left (IOException)            → Nothing   -- git 不在 PATH、root 不存在
    ├─ Right (ExitSuccess, out, _)   → validSha (strip out)
    └─ Right (ExitFailure _, _, _)   → Nothing   -- 非 repo(exit 128)、無 commit 的空 repo
```

- **無警告、無輸出**:`readCreateProcessWithExitCode` 會**捕獲** git 的 stderr(`fatal: not a git repository` 不會外流到我們的 stderr),搭配整條路徑不呼叫 `putStr` / `hPutStrLn`,同時滿足驗收標準 3 的「非 repo 時無警告」與 D8 的「library 全程不印」
- **`validSha`**:去掉頭尾空白(git 輸出帶 `\n`;Windows 上可能是 `\r\n`)後,要求全部字元落在 `0-9a-f` 且長度為 40(SHA-1)或 64(SHA-256 repo);不合就當偵測失敗省略欄位(假設 A6)
- **唯讀保證**:只跑 `rev-parse`,不寫 `.git`;`cwd` 指向 `rootDir` 而非 knot 自己的工作目錄,避免把 knot-hs 自己的 HEAD 寫進別人的圖(這正是 build-log C1 給 `ExportOptions` 加 `rootDir` 的原因)
- **已知邊界**:`rootDir` 若位於某個更上層 repo 之內,`git rev-parse` 會回上層 repo 的 HEAD——這是 `AutoDetect` 語意本身的性質,契約未要求偵測 repo 邊界,不額外處理

### `writeCodegraph` 進入點

1. `mCommit <- detectCommit (commitPolicy opts) (rootDir opts)`
2. `let builder = encodeCodegraph mCommit graph`(純函數,不做 IO)
3. `createDirectoryIfMissing True (takeDirectory (outputPath opts))`(`-o` 指到尚不存在的目錄時仍能寫;`takeDirectory "codegraph.json" == "."` 時為 no-op)
4. `BB.writeFile (outputPath opts) builder`——`Data.ByteString.Builder.writeFile :: FilePath -> Builder -> IO ()` 是 binary 寫入,`\n` 不會在 Windows 被轉成 `\r\n`(規則 5 的必要條件;用 `Data.Text.IO` 或 `Prelude.writeFile` 會壞掉)
5. 組 `ExportReport { xrPath = outputPath opts, xrNodeCount = length (cgNodes graph), xrEdgeCount = length (cgEdges graph), xrNotes = statsNotes (cgStats graph) }`

**錯誤處理**:寫檔失敗(權限、路徑非法)讓 `IOException` 原樣往上拋——匯出是 `knot extract` 的終點產物,寫不出來就沒有「部分成功」可言,由 `F004` 的 CLI 層決定 exit code 與訊息(與查詢面 `LoadError` 直接失敗的策略一致)。commit 偵測是唯一被吞掉例外的地方,因為契約明文要求「失敗則省略欄位不警告」。

### `xrNotes` 格式

固定英文小寫行,順序固定(前三行恆存在,`top external target` 行依 `gsTopExternalTargets` 原序,graph-core 已保證次數降序 / 同次數依名字典序):

```text
dropped external edges: 12
filtered generated facts: 0
deduped edges: 3
top external target: Data.Text (7)
top external target: Data.Map (4)
```

`cgWarnings` **不進** `xrNotes`(契約寫的是「`GraphStats` 摘要行」);CLI 層手上就有 `CodeGraph`,警告由它直接取用列印(假設 A3)。

### cabal 變更

- library `exposed-modules` +4:`Knot.Export`、`Knot.Export.Types`、`Knot.Export.Encode`、`Knot.Export.Commit`
- library `build-depends` +2:`aeson ^>=2.3`(D9 實測 2.3.1.0 可用)、`process`(GHC 9.14.1 boot,實測隨附 1.6.26.1);`bytestring` / `text` / `directory` / `filepath` 已在 library 段
- test-suite `build-depends` +1:`aeson`(T6 用 `decode` 做結構斷言;byte 級比對走 `ByteString` 不需要 aeson)
- `version` **維持 `0.0.1.0` 不動**(D6)
- executable 段**不動**(D3:CLI 入口全部在 `F004`)

### 欄位同名的已知處理

`ExportOptions.rootDir` 與既有 `ExtractOptions.rootDir`(`src/Knot/Extract/Types.hs:33`)同名。已在 GHC 9.14.1 實測:`default-language: GHC2024` 內含 `DisambiguateRecordFields`,同時 import 兩個模組時**記錄建構與更新語法**(`ExportOptions { rootDir = … }`)可正常消歧編譯;只有**裸選擇器**(`rootDir opts`)會 ambiguous。因此 library 內各模組不同時 import 兩者;`test/Main.hs`(以及後續 `F004`)一律用記錄建構語法,真要取值時改 qualified import(假設 A7)。

## 使用到的既有串接介面

(全部簽名為 2026-08-21 自來源檔案讀出的原文。knot-hs 自家程式碼標行號;aeson 讀自 hackage tarball `C:/cabal/packages/hackage.haskell.org/aeson/2.3.1.0/aeson-2.3.1.0.tar.gz` 解出的原始碼並標行號;boot 套件讀自 `C:/ghcup/ghc/9.14.1/doc/html/libraries/` 的 haddock,版本以 `ghc-pkg list` 核對)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data CodeGraph = CodeGraph { cgNodes :: [GraphNode], cgEdges :: [GraphEdge], cgStats :: GraphStats, cgWarnings :: [GraphWarning] }` | src/Knot/Graph/Types.hs:40-45 | graph-core/F001 | `writeCodegraph` 第二參數;投影讀 `cgNodes` / `cgEdges`、`xrNotes` 讀 `cgStats`;**不讀 `cgWarnings`**(假設 A3) |
| `data GraphNode = GraphNode { gnId :: NodeId, gnKind :: NodeKind, gnLabel :: Text, gnFile :: FilePath, gnLine :: Maybe Int }` | src/Knot/Graph/Types.hs:53-59 | graph-core/F001 | 投影規則 2 的四個來源欄位;`gnKind` **不輸出**(契約卡「不輸出 IR 的額外欄位」);`gnLine` 決定 `source_location` 分支 |
| `newtype NodeId = NodeId Text` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:50-51 | graph-core/F001 | `id` / `source` / `target` 三個欄位的值(pattern match 取內含 `Text`,不重新鑄造) |
| `data GraphEdge = GraphEdge { geSource :: NodeId, geTarget :: NodeId, geRelation :: Relation, geLine :: Maybe Int }` | src/Knot/Graph/Types.hs:65-70 | graph-core/F001 | 投影規則 3 的三個來源欄位;`geLine` **不輸出**(假設 A5) |
| `data Relation = RImports \| RCalls \| RUses \| RImplements \| RContains` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:74-75 | graph-core/F001 | `relationText` 的定義域,五個建構子全部對映(投影規則 1) |
| `data GraphStats = GraphStats { gsDroppedExternal :: Int, gsTopExternalTargets :: [(ModuleName, Int)], gsFilteredGenerated :: Int, gsDedupedEdges :: Int }` | src/Knot/Graph/Types.hs:77-82 | graph-core/F001 | `statsNotes` 的唯一輸入(驗收標準 5);`gsTopExternalTargets` 已由 graph-core D4 排好序,原序輸出 |
| `newtype ModuleName = ModuleName Text` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | `gsTopExternalTargets` 元素的鍵型別,`statsNotes` 取內含 `Text` 組行 |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | src/Knot/Graph.hs:37 | graph-core/F001 | 僅測試路徑:T6 端到端的第三段,產出要匯出的真實 `CodeGraph` |
| `data BuildOptions = BuildOptions { moduleOnly :: Bool }` | src/Knot/Graph/Types.hs:34-36 | graph-core/F001 | 僅測試路徑:T6 的 `buildGraph` 參數 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 僅測試路徑:T6 端到端的第一段 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs:22-26 | project-meta/F001 | 僅測試路徑:T6 的 fixture 專案輸入 |
| `extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult` | src/Knot/Extract.hs:19 | extraction/F001 | 僅測試路徑:T6 端到端的第二段 |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | src/Knot/Extract/Types.hs:33-38 | extraction/F001 | 僅測試路徑;**欄位 `rootDir` 與本 feature 新增的 `ExportOptions.rootDir` 同名**(處理方式見「欄位同名的已知處理」與假設 A7) |
| `data BackendChoice = Auto \| ImportsOnly \| HiedbOnly` | src/Knot/Extract/Types.hs:41-42 | extraction/F001 | 僅測試路徑:`Auto` |
| `importScanBackend :: Backend`(註冊於 `registeredBackends = [importScanBackend]`) | src/Knot/Extract/ImportScan.hs:47、src/Knot/Extract.hs:24-25 | extraction/F002 | 端到端的事實來源(資料依賴,不直接呼叫):沒有它 T6 的圖為空,驗不到節點與邊欄位 |
| `renderGraphSummary :: CodeGraph -> Text` | app/Knot/App/Summary.hs:142 | graph-core/F001 | **不呼叫**,列在此處是為了釘住邊界:唯讀驗收的**列印**面已經在 executable 層有既有慣例,本 feature 不在 library 端重複造(D8) |
| `pairs :: Series -> Encoding` | aeson-2.3.1.0/src/Data/Aeson/Encoding/Internal.hs:189 | - | 把 `Series` 收成單一 JSON 物件(緊湊 `{…}`,無空白) |
| `pair :: Key -> Encoding -> Series` | aeson-2.3.1.0/src/Data/Aeson/Encoding/Internal.hs:132 | - | 逐欄位串接;`Series` 有 `Semigroup` / `Monoid` 實例(:156、:162),`<>` 的順序即輸出順序(投影規則 5) |
| `text :: Text -> Encoding' a` | aeson-2.3.1.0/src/Data/Aeson/Encoding/Internal.hs:248 | - | 全部字串值的編碼與 escaping(`escapeAscii`,見 Builder.hs:124-133) |
| `encodingToLazyByteString :: Encoding' a -> BSL.ByteString` | aeson-2.3.1.0/src/Data/Aeson/Encoding/Internal.hs:97 | - | 把單一物件的 `Encoding` 轉成可併入文件層 `Builder` 的 lazy `ByteString` |
| `fromText :: Text -> Key` | aeson-2.3.1.0/src/Data/Aeson/Key.hs:52 | - | 建構欄位鍵(避免依賴 `OverloadedStrings`) |
| `toLazyByteString :: Builder -> LazyByteString` | bytestring-0.12.2.0 `Data.ByteString.Builder` | - | 僅測試路徑:T2/T3 對純函數的輸出做 byte 級斷言而不落地檔案 |
| `writeFile :: FilePath -> Builder -> IO ()` | bytestring-0.12.2.0 `Data.ByteString.Builder` | - | 進入點寫檔;binary 語意,Windows 上不會把 `\n` 轉成 `\r\n`(規則 5 的必要條件) |
| `lazyByteString :: LazyByteString -> Builder` / `char7 :: Char -> Builder` | bytestring-0.12.2.0 `Data.ByteString.Builder` | - | 文件層骨架組裝(物件併入、ASCII 標點與換行) |
| `readCreateProcessWithExitCode :: CreateProcess -> String -> IO (ExitCode, String, String)` | process-1.6.26.1 `System.Process` | - | 跑 `git rev-parse HEAD`;**stderr 被捕獲**,git 的錯誤訊息不會外流(驗收標準 3 的「無警告」) |
| `proc :: FilePath -> [String] -> CreateProcess` | process-1.6.26.1 `System.Process` | - | 組 `git rev-parse HEAD`(不走 shell,免 quoting 問題) |
| `data CreateProcess = CreateProcess { cmdspec :: CmdSpec, cwd :: Maybe FilePath, env :: Maybe [(String, String)], … }` | process-1.6.26.1 `System.Process` | - | 以 `cwd = Just rootDir` 把 git 釘在目標專案(build-log C1 的落實) |
| `createDirectoryIfMissing :: Bool -> FilePath -> IO ()` | directory-1.3.10.0 `System.Directory` | - | `-o` 指向尚不存在的目錄時建出父目錄 |
| `takeDirectory :: FilePath -> FilePath` | filepath-1.5.4.0 `System.FilePath` | - | 取 `outputPath` 的父目錄 |
| `data ExitCode = ExitSuccess \| ExitFailure Int` | base-4.22.0.0 `System.Exit` | - | 判斷 `git rev-parse` 是否成功 |
| `Control.Exception.try :: Exception e => IO a -> IO (Either e a)` | base-4.22.0.0 `Control.Exception` | - | 捕獲 git 不在 PATH / `rootDir` 不存在時的 `IOException` |
| `Data.Text.strip :: Text -> Text` / `Data.Text.pack :: String -> Text` / `Data.Text.all :: (Char -> Bool) -> Text -> Bool` / `Data.Text.length :: Text -> Int` | text-2.1.3 `Data.Text` | - | `validSha` 的去空白與十六進位驗證、`statsNotes` 組行 |

## 新增的介面

全部落在 Level 2 契約內;為測試與跨模組協作而匯出的非契約面函式一律以 haddock 標註(沿用 project-meta / extraction / graph-core 的既有慣例)。

**`Knot.Export.Types`**(對外 DTO,契約原文)

```haskell
-- | 匯出選項。@rootDir@ 是目標專案根目錄('AutoDetect' 在此跑 git);
-- @outputPath@ 為權威輸出路徑(預設值由 CLI 層以 'defaultOutputPath' 算,見假設 A2)。
data ExportOptions = ExportOptions
  { rootDir      :: FilePath
  , outputPath   :: FilePath
  , commitPolicy :: CommitPolicy
  }
  deriving (Eq, Show)

-- | 'AutoDetect':在 @rootDir@ 跑 @git rev-parse HEAD@(唯讀);失敗則省略欄位且**不警告**。
--   'NoCommit':不輸出 @built_at_commit@。
data CommitPolicy = AutoDetect | NoCommit
  deriving (Eq, Show)

-- | 匯出報告。@xrNotes@ 為 'GraphStats' 摘要行,由 CLI 層列印(library 全程不印)。
data ExportReport = ExportReport
  { xrPath      :: FilePath
  , xrNodeCount :: Int
  , xrEdgeCount :: Int
  , xrNotes     :: [Text]
  }
  deriving (Eq, Show)

-- | 非契約面(供 F004 CLI 組裝):@rootDir@ → 預設輸出路徑 @\<rootDir\>/codegraph.json@。
defaultOutputPath :: FilePath -> FilePath
```

**`Knot.Export.Encode`**(內部模組;純函數,無 IO)

```haskell
-- | 投影規則 1–5 的全部落地:'Nothing' = 省略 @built_at_commit@ 整行。
--   不重排 @cgNodes@ / @cgEdges@,沿用 graph-core 已排好的序。
encodeCodegraph :: Maybe Text -> CodeGraph -> Builder

-- | 非契約面(1-to-1 測試用):投影規則 1 的 relation 對映。
relationText :: Relation -> Text

-- | 非契約面(1-to-1 測試用):'ExportReport' 的 @xrNotes@ 內容。
statsNotes :: GraphStats -> [Text]
```

**`Knot.Export.Commit`**(內部模組)

```haskell
-- | commit 偵測。'NoCommit' 直接回 'Nothing';'AutoDetect' 在 @rootDir@ 跑
--   @git rev-parse HEAD@(唯讀),任何失敗(git 不存在、非 repo、空 repo、
--   輸出不是合法 sha)一律回 'Nothing' 且**不印任何訊息**。
detectCommit :: CommitPolicy -> FilePath -> IO (Maybe Text)
```

**`Knot.Export`**(子系統匯出面的唯一對外進入點)

```haskell
-- | export-query 匯出面對外契約(Level 2 原文簽名)。
writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport
```

## TodoList

- [ ] T1: `Knot.Export.Types`——三個契約 DTO(欄位名與型別依契約原文)+ 非契約面 `defaultOutputPath`;`knot-hs.cabal` library 加四個 `exposed-modules`、library `build-depends` 加 `aeson ^>=2.3` 與 `process`、test-suite 加 `aeson`;`version` 不動;`cabal build all` 在 `-Wall` 下零警告通過  `dep: -`
- [ ] T2: `Knot.Export.Encode` 物件層——`relationText`(五對映)、節點物件(規則 2:四欄位 + `source_location` 的 `Just`/`Nothing` 兩分支)、邊物件(規則 3:四欄位 + 固定 `confidence`),全部以 `E.pairs` / `E.pair` 顯式串接欄位順序  `dep: T1`
- [ ] T3: `Knot.Export.Encode` 文件層——`encodeCodegraph`:頂層四欄位順序、`built_at_commit` 的有/無兩分支、D4 半 pretty 版面(縮排、逗號、換行)、空陣列壓行、檔尾換行;`statsNotes` 的五種行  `dep: T2`
- [ ] T4: `Knot.Export.Commit`——`detectCommit` 的 `NoCommit` / `AutoDetect` 分支、`cwd = Just rootDir`、`IOException` 捕獲、`ExitFailure` 分支、`validSha`(去空白 + 十六進位 + 長度 40/64);全程不印  `dep: T1`
- [ ] T5: `Knot.Export.writeCodegraph`——偵測 → 編碼 → `createDirectoryIfMissing` → `BB.writeFile`(binary)→ `ExportReport` 五項組裝;寫檔例外原樣上拋  `dep: T3, T4`
- [ ] T6: 端到端與決定性——`test/fixtures/graph` 經 `loadProjectMeta` → `extract` → `buildGraph` → `writeCodegraph` 寫進暫存目錄的真實檔案,斷言檔案內容(結構 + 版面),並驗證同一 `CodeGraph` 兩次寫出 byte 級相同;`scan-graph.mjs` 對帳依 D5 由編排者手動跑(不 shell out node)  `dep: T5`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_export_types_construct | 逐一建構 `ExportOptions`(三欄位)/ `CommitPolicy`(兩建構子)/ `ExportReport`(四欄位)並比對欄位讀取;驗證 `Eq` 可用;`defaultOutputPath "C:/proj"` 的結果以 `takeFileName` 斷言為 `codegraph.json`、父目錄為輸入值(避免把平台分隔符寫死);**同時 import `Knot.Extract.Types (ExtractOptions(..))` 與 `Knot.Export.Types (ExportOptions(..))` 並各自用記錄建構語法建值**,釘住「欄位同名在 GHC2024 下可編譯」(假設 A7) |
| T2 | test_encode_node_edge | `relationText` 五個建構子對映到 `imports`/`calls`/`uses`/`implements`/`contains`;`gnLine == Nothing` 的節點輸出恰為 `{"id":…,"label":…,"source_file":…}`(**無** `source_location` 鍵)、`gnLine == Just 42` 的節點結尾恰為 `,"source_location":"L42"}`;欄位順序以 byte 級字串相等斷言(不是 `decode` 後比對,順序才釘得住);邊物件恰為 `{"source":…,"target":…,"relation":"imports","confidence":"EXTRACTED"}`;label 含 `"` / `\` / 中文 / 控制字元時 escaping 正確(`"` → `\"`、中文原樣 UTF-8) |
| T3 | test_encode_document_layout | 對手寫 `CodeGraph`(2 節點 + 1 邊,其中一節點有 `gnLine`)做**整份文件的 byte 級**斷言:`{`+`\n`、`  "directed": true,`、`  "nodes": [` / 元素縮排 4 空格 / 元素間 `,`、`  ],`、`  "links": [`…`  ]`、`}` + 結尾 `\n`;`Just sha` 時第二行為 `  "built_at_commit": "<sha>",`、`Nothing` 時該行整行不存在;空 `CodeGraph` 輸出 `  "nodes": [],` 與 `  "links": []` 兩行(壓行);輸出中不含 `\r`;`statsNotes` 對 `GraphStats 12 [(Data.Text,7),(Data.Map,4)] 0 3` 回傳五行且順序固定,`gsTopExternalTargets == []` 時只回三行(驗收標準 5) |
| T4 | test_detect_commit | `NoCommit` 對任何路徑回 `Nothing`;`AutoDetect` 對**專案自身根目錄**回 `Just sha` 且該值等於同一時刻 `git rev-parse HEAD` 的輸出(測試自行呼叫一次比對,避免硬寫 sha)、字元全落在 `0-9a-f` 且長度 ∈ {40,64};`AutoDetect` 對「暫存目錄下新建的非 repo 目錄」回 `Nothing`(該暫存目錄建在 `getTemporaryDirectory` 之下,不在 knot-hs 的 repo 內,否則會抓到上層 repo 的 HEAD);`AutoDetect` 對不存在的路徑回 `Nothing` 而**不拋例外**;以上四種情形均以 hedgehog `evalIO` 之外的 HUnit 斷言,並確認測試輸出中沒有 git 的訊息(驗收標準 3) |
| T5 | test_write_codegraph_entry | 以手寫 `CodeGraph` + `commitPolicy = NoCommit` 寫進暫存目錄的**多層未建立子路徑**(`<tmp>/a/b/codegraph.json`):檔案存在、內容與 `encodeCodegraph Nothing` 的 `toLazyByteString` byte 級相同(釘住進入點沒有偷改內容或換行);`ExportReport` 的 `xrPath == outputPath`、`xrNodeCount`/`xrEdgeCount` 等於清單長度、`xrNotes == statsNotes (cgStats g)`;`commitPolicy = AutoDetect` 且 `rootDir` 指向專案自身時,寫出的檔案含 `"built_at_commit"` 行且值等於 `git rev-parse HEAD` |
| T6 | test_export_end_to_end_deterministic | `test/fixtures/graph` 走 `loadProjectMeta` → `extract` → `buildGraph` → `writeCodegraph`(暫存目錄,`NoCommit`)寫出**真實檔案**:讀回檔案 bytes,以 aeson `decode` 斷言 `directed == true`、`nodes` 與 `links` 皆非空、每個節點有 `id`/`label`/`source_file` 三鍵、每條邊有 `source`/`target`/`relation`/`confidence` 四鍵且 `confidence == "EXTRACTED"`、`links` 的每個 `source`/`target` 都在 `nodes` 的 id 集合內(`F002` graph-load 的 schema 前提)、頂層無 `built_at_commit`;**連續寫兩次比對 bytes 完全相同**(驗收標準 4),且把 `cgNodes`/`cgEdges` 反轉後重寫的輸出**不同**(反證投影確實沿用輸入序而非自行排序);跑完刪除暫存目錄。`scan-graph.mjs` 的解析對帳依 D5 屬編排者的手動閘門工作,結果記入「實作備註」 |

## 待確認假設

- A1: Level 2 的內部模組表只列一個 `export-writer` 且明載「匯出面單一模組無內部介面」,但純函數投影、IO commit 偵測與寫檔進入點混在一個 Haskell 模組會讓 T2–T4 只能透過檔案系統間接測 → 採取:拆成 `Knot.Export` / `.Types` / `.Encode` / `.Commit` 四個 Haskell 模組(內部實作自主權,形狀沿用既有三個子系統),Level 2 的「export-writer」對應這一整組 → 影響:若編排者要求嚴格一模組一檔,合併成單一 `Knot.Export`,T2/T3/T4 改為對 `writeCodegraph` 的落地檔案做斷言(測試變慢、失敗訊息變模糊,但驗收標準不變)
- A2: 契約註解寫「`outputPath` 預設 `<rootDir>/codegraph.json`(CLI `-o` 覆寫)」,但 `outputPath :: FilePath` 不是 `Maybe`,沒說預設值由誰算 → 採取:`writeCodegraph` 把 `outputPath` 當**權威值**原樣使用(不做任何 fallback,空字串就是錯誤輸入),另在 `Knot.Export.Types` 匯出非契約面 `defaultOutputPath :: FilePath -> FilePath` 供 `F004` 組裝時取預設,避免 CLI 層硬寫檔名 → 影響:若裁定 `writeCodegraph` 應自行套預設(例如 `outputPath` 為空字串時 fallback 到 `rootDir`),改進入點一行,`defaultOutputPath` 保留給 CLI 顯示用
- A3: `xrNotes` 契約寫的是「`GraphStats` 摘要行」,但 `CodeGraph` 還帶 `cgWarnings`,若不進報告就沒有任何通道會被 CLI 印出來 → 採取:`xrNotes` **只**放 `GraphStats` 摘要(嚴守契約原文);`cgWarnings` 由 `F004` 的 CLI 層直接從手上的 `CodeGraph` 取用列印(它本來就持有整個圖)→ 影響:若裁定匯出報告要一站式涵蓋警告,`statsNotes` 改吃 `CodeGraph` 並追加警告行,`F004` 的列印來源改為單一 `xrNotes`
- A4: `xrNotes` 的行文格式契約未定 → 採取:固定五種英文小寫行(`dropped external edges: N` / `filtered generated facts: N` / `deduped edges: N` / `top external target: <module> (<n>)`),風格對齊既有 `app/Knot/App/Summary.hs` 的 `stats:` 行,順序固定以維持決定性 → 影響:格式若要改中文或鍵值化,只動 `statsNotes` 一處,測試 T3 跟著改
- A5: **投影規則 3 未把邊的 `geLine` 列入輸出,但下游 `scan-graph.mjs` 第 265 行讀 `e.source_location ?? src.source_location` 當循環依賴的證據行**;而 S1 的 module 節點 `gnLine` 恆為 `Nothing`(已查證 `src/Knot/Graph/NodeMint.hs:59`「`FactModule` 無行號欄位,故 `gnLine` 恆為 `Nothing`」),節點層 fallback 也給不出證據,結果是 `/arch-audit` 的循環依賴報告只會印出 `src/A.hs A --imports[EXTRACTED]--> B`、沒有行號 → 採取:**嚴守契約不輸出**(契約卡明列「不輸出 IR 的額外欄位」),把它列為建議編排者修訂 Level 2 投影規則 3 的項目 → 影響:若裁定要輸出,投影規則 3 加一欄(`geLine == Just n` 時輸出 `"source_location":"L<n>"`,放在 `relation` 與 `confidence` 之間或最後),`Knot.Export.Encode` 的邊物件加一分支,T2 加一條斷言;`F002` graph-load 不受影響(它本來就忽略未知/選填欄位)
- A6: `git rev-parse HEAD` 的輸出驗證強度契約未定 → 採取:去頭尾空白後要求全部字元為 `0-9a-f` 且長度為 40(SHA-1)或 64(SHA-256 repo),否則視為偵測失敗省略欄位 → 影響:若目標專案的 git 設定會回非標準字串(例如 `core.abbrev` 影響其他指令、或 wrapper 腳本多印一行),放寬為「非空、單行、無空白」;下游 `scan-graph.mjs` 只做 `builtAt.slice(0,12)` 顯示,不驗格式,放寬無風險
- A7: `ExportOptions.rootDir` 與既有 `ExtractOptions.rootDir`(`src/Knot/Extract/Types.hs:33`)欄位同名,契約已定死名稱不能改 → 採取:已在 GHC 9.14.1 實測 `GHC2024` 內含 `DisambiguateRecordFields`,**記錄建構/更新語法可消歧、裸選擇器不行**;因此 library 內不同時 import 兩個 Types 模組,`test/Main.hs` 與 `F004` 一律用記錄建構語法,需要裸取值時改 qualified import(不新增任何語言擴充)→ 影響:若 `F004` 的參數對映寫起來需要大量裸選擇器,該模組加 `import qualified Knot.Export.Types as X`,或在該模組單獨開 `{-# LANGUAGE DuplicateRecordFields, OverloadedRecordDot #-}`(僅影響 executable 段,不動契約)

## 實作備註

(撰寫時留空)
