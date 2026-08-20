---
id: F001
type: feature
title: module-graph
description: 由事實流組出 module 節點與 imports 邊的決定性 CodeGraph
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: [project-meta/F001, extraction/F001, extraction/F002]
related-adr: []
related-feature: []
---

# F001: module-graph — graph-core 骨架(module 節點 + imports 邊)

## 功能概述

graph-core 的**第一個實體**:把 extraction 的事實流(本階段實際只有 `FactModule` / `FactImport`)組裝成內部圖 IR `CodeGraph`,包含 module 節點、`RImports` 邊、丟棄/去重統計與警告。本 feature 一次立起子系統的四個內部模組(fact-gate、node-mint、edge-derive、graph-assemble)與全部對外 DTO,使主架構 S1「project-meta → extraction → graph-core」端到端跑通,只差 export-query 的投影就能產出 `codegraph.json`(格式契約見 ADR-003,本 feature 不碰)。

**要解決的問題**:`imports` 邊是 dev-flow `/arch-audit` 依賴矩陣、循環依賴與跨界引用的唯一原料;事實流是「檔案 × 行」的扁平列表,沒有節點身分、沒有內外部判定、沒有去重,不能直接交給下游。本 feature 建立那層轉換,並保證**同輸入必同輸出**(零 `Unique`、零時間戳、零雜湊表走訪序外洩)。

**驗收標準**(契約卡原文):

1. `import base 系 module` 的邊被丟棄,且 `gsDroppedExternal` / `gsTopExternalTargets` 正確
2. 重複 import 合併,且 `gsDedupedEdges` 計數正確
3. module 自 import 不產邊
4. 同輸入兩次呼叫結果完全相等(純函數)
5. `moduleOnly = True/False` 在本階段輸出相同(尚無 decl 事實)

**明確不做**(契約卡底線):不處理 `FactDecl` / `FactRef` / `FactInstance`(屬 `F002` decl-nodes、`F003` decl-edges;本階段忽略但不 crash);不序列化 JSON;不印任何輸出(統計只放進 `GraphStats`,library 全程無 IO)。另承子系統邊界:不讀檔案、不認識 `.hie` 或 SQLite、不做 span 比對。

## 相依性

`depends-on: [project-meta/F001, extraction/F001, extraction/F002]`,三條皆由「使用到的既有串接介面」表反推,且三份文檔皆為 `status: done`、程式碼已在 `main`,故全部是**既有程式碼查證**(2026-08-20 自來源檔讀出原文),沒有任何一條是文檔約定:

- **`project-meta/F001`(scan-baseline,跨子系統)**:`buildGraph` 第二參數 `ProjectMeta` 的型別,以及 `ModuleName`(節點 id 與內部集合的鍵型別,已確認 `deriving (Eq, Ord, Show)`,`Set` / `Map` 的鍵可用)、`SourceFile`(規則 3 的來源,本階段不觸碰但型別在簽名內)、測試路徑的 `MetaOptions` / `loadProjectMeta`
- **`extraction/F001`(fact-contract,跨子系統)**:`ExtractResult`(第三參數)與 `Fact` 的建構子與欄位名(`FactModule` 的 `fmFile` / `fmModule`、`FactImport` 的 `fiFrom` / `fiTo` / `fiFile` / `fiLine`)、`DeclKind`(`NodeKind` 的 `DeclNode` 參數型別,本階段零邏輯)、測試路徑的 `extract` / `ExtractOptions`
- **`extraction/F002`(import-scan,跨子系統)**:唯一會產出 `FactModule` / `FactImport` 的後端。T7 的端到端測試與 T8 的驗收實跑都要求「真實 fixture 專案 → 非空事實流 → 非空圖」,沒有 import-scan 註冊在 `Knot.Extract` 的後端表就無事實可組。這是**資料依賴**(不是呼叫依賴:graph-core 不 import `Knot.Extract.ImportScan`),故於此段落說明;另 T8 的 app 層輸出路徑沿用 `extraction/F002` 建立的 `--facts` / `renderFactSummary` 慣例

未列入的相依與理由:

- `project-meta/F002`(cabal-components)、`project-meta/F003`(hie-discovery):只改變 `sfIncluded` / `sfOwners` / `pmHie` 的**填值語意**,不改型別;本 feature 連 `pmSources` 都只在規則 3(屬 `F002` decl-nodes)才會讀,不構成相依
- graph-core 的 `F002` / `F003`:方向相反(它們依賴本 feature 立起的 DTO 與模組骨架)
- export-query:本 feature 不呼叫它,`CodeGraph` 是單向資料流的下游輸入;ADR-003 的欄位規格由 export-query 投影時遵守,不回頭約束 IR

可平行性:**可**與任何其他子系統的任務平行(三條相依全部已完成);但 graph-core 的 `F002` / `F003` 必須排在本 feature 之後(序列)。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/graph-core/design.md`,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| 對外契約 `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | `Knot.Graph.buildGraph`,純函數簽名一字不差 |
| DTO `BuildOptions` / `CodeGraph` / `NodeId` / `GraphNode` / `NodeKind` / `GraphEdge` / `Relation` / `GraphStats` / `GraphWarning` | 全部定義於 `Knot.Graph.Types`,欄位名與型別依契約原文;本階段只**產生** `ModuleNode` 與 `RImports`,其餘建構子先行定義(零邏輯,比照 project-meta `F001` 假設 A5 的既有慣例) |
| 鑄造規則表 · module 列(裸名 / `<module>@<source_file>`) | `mintModuleId :: ModuleName -> Maybe FilePath -> NodeId`(**A2 裁決後的契約簽名**:`Nothing` = 未碰撞鑄裸名、`Just file` = 碰撞組鑄消歧名);值/型別/instance 三列屬 `F002`,本階段不實作 |
| 同名 module 消歧(D1) | 判定依 `FactModule.fmFile` 的**相異數**:同名 >1 檔 → 該組全部改用 `<module>@<file>`;=1 檔 → 裸名;碰撞事實彙整為 `GraphWarning` |
| 組裝規則 1(內部才實化) | 內部集合 = 事實流所有 `FactModule.fmModule`(D2,**非** `pmSources.sfModule`);外部目標丟棄並計入 `gsDroppedExternal` / `gsTopExternalTargets`(D4:前 10、次數降序、同次數依名字典序) |
| 組裝規則 2 · `FactModule` 列 | `FactModule` → module 節點(`mintNodes`) |
| 組裝規則 2 · `FactImport`(雙端內部)列 | `FactImport` → `RImports`(module → module)(`deriveEdges`) |
| 組裝規則 4(自環丟棄) | 解析後 `geSource == geTarget` 的邊不產出、不計統計、不發警告 |
| 組裝規則 5(去重) | 相同 `(source, target, relation)` 合併為一條,`geLine` 保留最小行號,合併掉的條數計入 `gsDedupedEdges` |
| 組裝規則 7(決定性) | `cgNodes` 依 `NodeId` 字典序、`cgEdges` 依 `(source, relation, target)` 字典序(D5);全程純函數 |
| 模組介面 `gateFacts` / `GatedFacts` | `Knot.Graph.FactGate`,簽名依契約;`gfInternal` 由 D2 建立;`gfFiltered` 本階段恆 0(規則 3 屬 `F002`,見假設 A6) |
| 模組介面 `mintModuleId` / `mintNodes` | `Knot.Graph.NodeMint`,簽名一字不差依 A2 裁決後的契約;另匯出非契約面的 `moduleFiles`(D1 判定面,供 graph-assemble 彙整碰撞警告與 1-to-1 測試) |
| 模組介面 `deriveEdges` / `EdgeStats` | `Knot.Graph.EdgeDerive`,簽名一字不差依 **A3 裁決後的契約**(三元組,警告通道已補進契約) |
| 組裝規則 6(`moduleOnly`) | graph-assemble 於進 fact-gate 前把事實窄化為 module 層建構子(`FactModule` / `FactImport`);本階段兩個取值輸出相同(驗收標準 5) |
| 資料流管線 | `fact-gate → node-mint → edge-derive → graph-assemble` 四段全部走到,順序與 design.md 圖一致 |
| 組裝規則 3(產生碼過濾)、鑄造規則的 decl / instance 列 | **不觸碰**(`F002` / `F003` 的範圍) |

超出 Level 2 契約的部分:**無**。撰寫時發現的三處契約**缺口**(不是偏離)中,**A2 與 A3 已由編排者於階段一閘門裁決並回填 Level 2**(`design.md`「模組間公開介面」,commit `b2a2be3`),實作直接依新簽名落地,**未**另建 `mintModuleIdAt` / `deriveEdgesWithWarnings` 包裝:

- **A2 裁決**:`mintModuleId :: ModuleName -> Maybe FilePath -> NodeId`(`Nothing` = 該 module 未碰撞,鑄裸名;`Just file` = 碰撞組,鑄 `<module>@<file>`)
- **A3 裁決**:`deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])`(三元組,補上警告通道)

`NodeId` 建構子封裝(A1)未裁決,維持文檔既採判斷(`Knot.Graph.Types` 匯出 `NodeId (..)`,以 haddock 標明唯一鑄造入口在 node-mint;edge-derive 全程只從 `gnId` 取值,不鑄任何 id)。

## 實作方式

### 模組配置

```text
src/Knot/Graph/Types.hs        -- 對外 DTO(契約面)
src/Knot/Graph/FactGate.hs     -- fact-gate:gateFacts / GatedFacts
src/Knot/Graph/NodeMint.hs     -- node-mint:mintModuleId / mintNodes
src/Knot/Graph/EdgeDerive.hs   -- edge-derive:deriveEdges / EdgeStats
src/Knot/Graph.hs              -- graph-assemble:buildGraph 進入點
```

模組相依方向(無環,與資料流同向):`Types ← FactGate ← NodeMint ← EdgeDerive ← Graph`(`Types` 不 import 任何本子系統模組)。

`knot-hs.cabal`:library `exposed-modules` 加上這五個 module;library `build-depends` **不變**(`base` / `containers` / `text` 皆已在列);test-suite `build-depends` 新增 `containers`(測試要對 `gfInternal :: Set ModuleName` 斷言)。`version` 依 D6 凍結為 `0.0.1.0`。測試 group 命名 `graph-core/F001 module-graph`。

### 管線總覽

```text
BuildOptions + ProjectMeta + ExtractResult
   │
   │ erFacts                       (erWarnings / erReports 不消費:由 CLI 印 stderr)
   ▼
 moduleOnly 窄化(規則 6):True → 只留 FactModule / FactImport
   ▼
 gateFacts pm facts ──▶ GatedFacts{ gfFacts, gfInternal = D2 集合, gfFiltered = 0 }
   │                          │
   │                          ▼
   │                     mintNodes ──▶ [GraphNode]  (module 節點,已依 NodeId 去重)
   │                          │
   ▼                          ▼
 deriveEdges gated nodes ──▶ ([GraphEdge], EdgeStats, [GraphWarning])   (A3 裁決)
   │
   ▼
 graph-assemble:統計彙整(GraphStats)+ 警告彙整(碰撞 + 邊解析)+ 穩定排序(D5)
   ▼
 CodeGraph
```

### 1. fact-gate:`gateFacts`

```text
gfInternal = Set.fromList [ fmModule f | f@FactModule{} <- facts ]     (D2)
gfFacts    = facts                                                     (原樣通過)
gfFiltered = 0                                                         (規則 3 屬 F002)
```

- `ProjectMeta` 參數在本階段**不被讀取**(規則 3 才需要 `pmSources`),以 haddock 註明此為階段性狀態,不是遺漏
- 非 module 層事實(`FactDecl` / `FactRef` / `FactInstance`)**原樣通過**,由下游模組各自忽略——契約卡要求「忽略之但不 crash」,故不得在此 pattern match 失敗

### 2. node-mint:id 鑄造與 module 節點

碰撞分組(D1 判定面):

```text
moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)
              從 FactModule 累積;Set 大小 > 1 即碰撞組
```

id 鑄造:

| 情形 | id |
|---|---|
| 該 module 名只有 1 個相異 `fmFile` | `mintModuleId m Nothing` = 裸 module 名 |
| 該 module 名有 ≥2 個相異 `fmFile` | `mintModuleId m (Just file)` = `<module>@<file>`(`file` 為 `fmFile` 原文:repo 相對、正斜線) |

`mintNodes` 對每筆 `FactModule` 產一個節點:

```text
gnId    = 依上表(碰撞組用該筆自己的 fmFile)
gnKind  = ModuleNode
gnLabel = 裸 module 名(消歧只反映在 id 與 gnFile;假設 A5)
gnFile  = fmFile
gnLine  = Nothing            (FactModule 無行號欄位——已讀原始碼確認)
```

最後依 `gnId` 去重(同一檔重複出現在事實流時保留第一筆),避免同 id 節點重複。非 `FactModule` 的事實一律略過(本階段)。

### 3. edge-derive:`FactImport` → `RImports`

由 `[GraphNode]` 建兩張索引(只取 `gnKind == ModuleNode` 者;edge-derive **不鑄造 id**,只從既有節點取 `gnId`,符合「NodeId 唯一構造入口在 node-mint」):

```text
byNameFile :: Map (ModuleName, FilePath) NodeId     -- (gnLabel, gnFile) → gnId
byName     :: Map ModuleName [NodeId]               -- gnLabel → 該名的全部節點(消歧組 >1)
```

逐筆 `FactImport` 依序判定(順序即優先序):

| 步驟 | 條件 | 動作 |
|---|---|---|
| 1 外部判定(規則 1) | `fiTo` ∉ `gfInternal` | 丟棄;`esDroppedExternal + 1`;`fiTo` 累進外部次數表 |
| 2 目標解析 | `byName fiTo` 恰 1 個節點 | 取該 `NodeId` |
| | 0 個節點(內部集合有名字卻沒節點,理論上不可達) | 丟棄 + `GraphWarning`,不計統計 |
| | ≥2 個節點(D1 消歧組) | 丟棄 + `GraphWarning`(無從判定指向哪一個;假設 A4),不計統計 |
| 3 來源解析 | `byNameFile (fiFrom, fiFile)` 命中 | 取該 `NodeId` |
| | 未命中但 `byName fiFrom` 恰 1 個 | 取該節點(退路:非 import-scan 來源的事實可能缺對應 `FactModule`) |
| | 其餘 | 丟棄 + `GraphWarning`,不計統計 |
| 4 自環(規則 4) | `srcId == tgtId` | 丟棄;不計統計、不發警告 |
| 5 產出 | — | `GraphEdge{ geSource, geTarget, geRelation = RImports, geLine = Just fiLine }` |

去重(規則 5):把上一步的邊依 `(geSource, geTarget, geRelation)` 分組,每組輸出一條、`geLine` 取組內**最小**行號(「最早的證據行」,取極小值而非「輸入序第一筆」,使結果不隨事實序改變);`esDeduped` = Σ(組大小 − 1)。

外部統計(D4):`esTopExternal` = 外部次數表依 `(次數降序, module 名字典序)` 排序後 `take 10`;`esDroppedExternal` 是**丟棄邊的總數**(不是相異 module 數)。

### 4. graph-assemble:`buildGraph`

```text
facts0  = erFacts result
facts   = if moduleOnly opts then [ f | f <- facts0, isModuleLayer f ] else facts0   (規則 6)
gated   = gateFacts pm facts
nodes   = mintNodes gated
(edges, estats, edgeWarns) = deriveEdges gated nodes
```

- **統計彙整**:`gsDroppedExternal = esDroppedExternal`、`gsTopExternalTargets = esTopExternal`、`gsDedupedEdges = esDeduped`、`gsFilteredGenerated = gfFiltered`(本階段 0)
- **警告彙整**:碰撞警告(每個碰撞組一則:`gwSource` = module 名、`gwMessage` 含相異檔數與**排序後**的檔案清單)+ `edgeWarns`;兩者合併後依 `(gwSource, gwMessage)` 去重並依該鍵字典序輸出(假設 A7)
- **穩定排序**(D5):`cgNodes` 依 `gnId`;`cgEdges` 依 `(geSource, geRelation, geTarget)`——`Relation` 以 `deriving Ord` 的建構子序為鍵序(`RImports < RCalls < RUses < RImplements < RContains`),本階段只有一種 relation,鍵在去重後即為全序(不需 `geLine` 參與比較)

### 5. 決定性(規則 7 / D5)

- 全程純函數:無 IO、無 `unsafePerformIO`、無時間戳、無 `Unique`
- 所有 `Map` / `Set` 只用於查表與累加,**最終輸出一律經明確排序**產生;不把 `Map.toList` 的走訪序當成輸出序使用(`Data.Map` 的走訪序本身雖為鍵序,但仍以顯式 `sortOn` 表述意圖)
- 去重的 `geLine` 取極小值、碰撞警告的檔案清單先排序 → 對事實流的重排序也不敏感

### 6. 驗收 harness(app 層,library 仍不印任何輸出)

比照 `extraction/F002` 假設 A6 的既有慣例:`Knot.App.Summary` 加 `renderGraphSummary :: CodeGraph -> Text`(節點/邊/警告筆數、四項統計、逐筆節點與邊行),`app/Main.hs` 加 `--graph` 旗標(走 `loadProjectMeta → extract → buildGraph` 後印摘要)。這是 executable 內部模組,不動 library 對外契約;MagicFarmer / particle-magic 唯讀實跑結果寫入「實作備註」。

## 使用到的既有串接介面

(全部簽名為 2026-08-20 自來源檔案讀出的原文;`containers` / `base` / `text` 簽名以 `ghc -e ':t …'`(GHC 9.14.1)實測)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | src/Knot/Meta/Types.hs:29-35 | project-meta/F001 | `buildGraph` / `gateFacts` 第二參數;本階段不讀其欄位(規則 3 屬 `F002`) |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs:65-71 | project-meta/F001 | 規則 3 的未來輸入;D2 明令**不**用 `sfModule` 建內部集合 |
| `newtype ModuleName = ModuleName Text` `deriving (Eq, Ord, Show)` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | 內部集合 `Set ModuleName`、外部次數表 `Map ModuleName Int`、`gsTopExternalTargets` 的鍵型別(**已查證有 `Ord`**,可直接當 Set/Map 鍵) |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs:22-26 | project-meta/F001 | 僅測試/app 路徑:組出真實輸入 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 僅測試/app 路徑:T7 端到端與 T8 實跑的第一段 |
| `data ExtractResult = ExtractResult { erFacts :: [Fact], erLevel :: CapabilityLevel, erReports :: [BackendReport], erWarnings :: [ExtractWarning] }` | src/Knot/Extract/Types.hs:44-50 | extraction/F001 | `buildGraph` 第三參數;**只消費 `erFacts`**(其餘三欄由 CLI 印 stderr,graph-core 不轉載) |
| `data Fact = FactModule { fmFile :: FilePath, fmModule :: ModuleName } \| FactImport { fiFrom :: ModuleName, fiTo :: ModuleName, fiFile :: FilePath, fiLine :: Int } \| FactDecl { fdName :: QualName, fdKind :: DeclKind, fdFile :: FilePath, fdLine :: Int } \| FactRef { frFromModule :: ModuleName, frFromDecl :: Maybe QualName, frTarget :: QualName, frFile :: FilePath, frLine :: Int } \| FactInstance { fiClass :: QualName, fiInstHead :: Text, fiInstFile :: FilePath, fiInstLine :: Int }` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:67-85 | extraction/F001 | 本階段消費前兩個建構子(`FactModule` **無行號欄位** → `gnLine = Nothing`;`FactImport.fiLine` → `geLine`);後三個原樣通過不 crash |
| `data DeclKind = ValueDecl \| DataDecl \| ClassDecl \| InstanceDecl \| TypeSynDecl \| PatSynDecl \| FamilyDecl` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:87-90 | extraction/F001 | `NodeKind` 的 `DeclNode DeclKind` 參數型別(本階段零邏輯;已查證有 `Ord`,`NodeKind` 可 derive `Ord`) |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | src/Knot/Extract/Types.hs:33-38 | extraction/F001 | 僅測試/app 路徑:呼叫 `extract` 取得真實事實流 |
| `data BackendChoice = Auto \| ImportsOnly \| HiedbOnly` | src/Knot/Extract/Types.hs:41-42 | extraction/F001 | 僅測試/app 路徑:`Auto` |
| `extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult` | src/Knot/Extract.hs:19 | extraction/F001 | 僅測試/app 路徑:T7 端到端與 T8 實跑的第二段(其後端註冊表由 extraction/F002 填實) |
| `importScanBackend :: Backend`(註冊於 `registeredBackends = [importScanBackend]`) | src/Knot/Extract/ImportScan.hs、src/Knot/Extract.hs:24-25 | extraction/F002 | 事實流的唯一產出者(資料依賴,不直接呼叫):沒有它 T7/T8 的真實輸入為空 |
| `renderMetaSummary :: ProjectMeta -> Text` / `renderFactSummary :: ExtractResult -> Text` | app/Knot/App/Summary.hs:38、:88 | project-meta/F001、extraction/F002 | T8 的鄰接慣例:`renderGraphSummary` 加在同一 executable 內部模組,由 test-suite 共用 `hs-source-dirs` 測試 |
| `Data.Set.fromList :: Ord a => [a] -> Set a` / `Data.Set.member :: Ord a => a -> Set a -> Bool` / `Data.Set.notMember :: Ord a => a -> Set a -> Bool` | containers(GHC 9.14.1 boot) | - | `gfInternal` 建立與內外部判定(規則 1) |
| `Data.Map.Strict.fromListWith :: Ord k => (a -> a -> a) -> [(k, a)] -> Map k a` / `Data.Map.Strict.insertWith :: Ord k => (a -> a -> a) -> k -> a -> Map k a -> Map k a` / `Data.Map.Strict.lookup :: Ord k => k -> Map k a -> Maybe a` / `Data.Map.Strict.toList :: Map k a -> [(k, a)]` | containers(GHC 9.14.1 boot) | - | 碰撞分組表、節點索引、外部次數表、去重分組 |
| `Data.Containers.ListUtils.nubOrdOn :: Ord b => (a -> b) -> [a] -> [a]` | containers(GHC 9.14.1 boot) | - | 節點依 `gnId` 去重(保留第一筆)、警告去重 |
| `Data.List.sortOn :: Ord b => (a -> b) -> [a] -> [a]` / `Data.List.take :: Int -> [a] -> [a]` | base-4.22(GHC 9.14.1) | - | D5 的穩定排序、D4 的前 10 |
| `Data.Ord.Down`(`sortOn (\\(m, n) -> (Down n, m))`) | base-4.22(GHC 9.14.1) | - | D4 的「次數降序、同次數依名字典序」 |
| `Data.Text.pack :: String -> Text` / `Data.Text` 的 `<>` | text(GHC 9.14.1 boot) | - | id 組字(`<module>@<file>`,`FilePath` 轉 `Text`)與警告訊息組裝 |

## 新增的介面

全部落在 Level 2 契約內;為測試與跨模組協作而匯出的非契約面函式一律以 haddock 標註(沿用 project-meta / extraction 的既有慣例)。

**`Knot.Graph.Types`**(對外 DTO,契約原文)

```haskell
data BuildOptions = BuildOptions
  { moduleOnly :: Bool }
  deriving (Eq, Show)

data CodeGraph = CodeGraph
  { cgNodes    :: [GraphNode]
  , cgEdges    :: [GraphEdge]
  , cgStats    :: GraphStats
  , cgWarnings :: [GraphWarning]
  }
  deriving (Eq, Show)

-- | 節點 id。唯一構造入口是 node-mint(Level 2 契約);
--   其他模組只得從既有 'GraphNode' 取 'gnId',不得直接用建構子(假設 A1)。
newtype NodeId = NodeId Text
  deriving (Eq, Ord, Show)

data GraphNode = GraphNode
  { gnId    :: NodeId
  , gnKind  :: NodeKind
  , gnLabel :: Text
  , gnFile  :: FilePath
  , gnLine  :: Maybe Int
  }
  deriving (Eq, Show)

data NodeKind = ModuleNode | DeclNode DeclKind | InstanceNode
  deriving (Eq, Ord, Show)

data GraphEdge = GraphEdge
  { geSource   :: NodeId
  , geTarget   :: NodeId
  , geRelation :: Relation
  , geLine     :: Maybe Int
  }
  deriving (Eq, Show)

-- | 建構子序即 D5 排序鍵的 relation 序。
data Relation = RImports | RCalls | RUses | RImplements | RContains
  deriving (Eq, Ord, Show)

data GraphStats = GraphStats
  { gsDroppedExternal    :: Int
  , gsTopExternalTargets :: [(ModuleName, Int)]
  , gsFilteredGenerated  :: Int
  , gsDedupedEdges       :: Int
  }
  deriving (Eq, Show)

data GraphWarning = GraphWarning
  { gwSource  :: Text
  , gwMessage :: Text
  }
  deriving (Eq, Ord, Show)
```

**`Knot.Graph.FactGate`**

```haskell
-- | 事實驗證與過濾。階段一:只建立內部 module 集合(D2),
--   規則 3 的產生碼過濾屬 F002,故 gfFiltered 恆為 0、ProjectMeta 暫不讀取。
gateFacts :: ProjectMeta -> [Fact] -> GatedFacts

data GatedFacts = GatedFacts
  { gfFacts    :: [Fact]
  , gfInternal :: Set ModuleName
  , gfFiltered :: Int
  }
  deriving (Eq, Show)
```

**`Knot.Graph.NodeMint`**

```haskell
-- | module 節點 id 鑄造(A2 裁決的契約簽名)。
--   Nothing = 該 module 未碰撞,鑄裸名;Just file = 碰撞組,鑄 <module>@<file>。
mintModuleId :: ModuleName -> Maybe FilePath -> NodeId

-- | 事實流 → module 節點(已依 gnId 去重);非 FactModule 的事實略過。
mintNodes :: GatedFacts -> [GraphNode]

-- * 非契約面(供 graph-assemble 彙整碰撞警告與 1-to-1 測試)

-- | D1 判定面:module 名 → 宣告它的相異來源檔集合(Set 大小 > 1 即碰撞組)。
moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)
```

**`Knot.Graph.EdgeDerive`**

```haskell
-- | 邊推導(A3 裁決的契約簽名):第三個分量是來源/目標解析失敗的警告,
--   由 graph-assemble 彙整。edge-derive 不鑄造任何 id,只從既有節點取 gnId。
deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])

data EdgeStats = EdgeStats
  { esDroppedExternal :: Int
  , esTopExternal     :: [(ModuleName, Int)]
  , esDeduped         :: Int
  }
  deriving (Eq, Show)
```

**`Knot.Graph`**(graph-assemble 進入點)

```haskell
-- | graph-core 唯一對外進入點,純函數(同輸入必同輸出)。
buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph
```

**`Knot.App.Summary`**(executable 內部模組,非 library 對外介面)

```haskell
-- | 圖摘要:節點/邊/警告筆數、四項統計、逐筆節點與邊行,供唯讀驗收比對。
renderGraphSummary :: CodeGraph -> Text
```

## TodoList

- [x] T1: `Knot.Graph.Types`——契約 DTO 全套與 deriving(`NodeId` / `Relation` / `NodeKind` 需 `Ord` 供 D5 排序);`knot-hs.cabal` 加五個 `exposed-modules`、test-suite 加 `containers`,`cabal build all` 通過 `dep: -`
- [x] T2: `Knot.Graph.FactGate`——`gateFacts` / `GatedFacts`:內部集合由 `FactModule.fmModule`(D2)、decl 層事實原樣通過不 crash、`gfFiltered = 0` `dep: T1`
- [x] T3: `Knot.Graph.NodeMint`——`moduleFiles` 碰撞分組、`mintModuleId`(D1 的 Nothing/Just 兩分支)、`mintNodes` 產 module 節點(五個欄位)並依 `gnId` 去重 `dep: T2`
- [x] T4: `Knot.Graph.EdgeDerive` 主線——節點索引、`FactImport` → `RImports`、規則 1 外部丟棄與 `esDroppedExternal` / `esTopExternal`(D4 前 10 與排序)、來源/目標解析失敗轉警告 `dep: T3`
- [x] T5: edge-derive 收斂——規則 4 自環丟棄(不計統計不發警告)、規則 5 去重(合併鍵、`geLine` 取最小、`esDeduped` 計數) `dep: T4`
- [x] T6: `Knot.Graph.buildGraph`——四模組調度、`moduleOnly` 事實窄化(規則 6)、`GraphStats` 四欄彙整、警告彙整(碰撞 + 邊解析,去重與排序)、D5 穩定排序 `dep: T5`
- [x] T7: 決定性與端到端——`test/fixtures/proj`(另加 `test/fixtures/graph`,見 A9)經 `loadProjectMeta` → `extract` → `buildGraph`;同輸入兩次結果相等;`moduleOnly` True/False 輸出相同;hedgehog property 以隨機事實流驗證排序與純函數性 `dep: T6`
- [x] T8: 驗收 harness——`renderGraphSummary` + `--graph` 旗標,對 MagicFarmer / particle-magic 唯讀實跑對帳(結果寫入「實作備註」) `dep: T7`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_graph_types_construct | 逐一建構九個 DTO 值並比對欄位讀取(含 `NodeKind` 三個建構子、`Relation` 五個建構子);`compare` 驗證 `Relation` 的 `Ord` 序為 `RImports < RCalls < RUses < RImplements < RContains`、`NodeId` 依內含 `Text` 字典序;`CodeGraph` 的 `Eq` 可用(T7 依賴它) |
| T2 | test_gate_facts | 給含 3 個 `FactModule`(其中兩筆同名不同檔)+ `FactImport` + 一筆 `FactDecl` 的事實流:`gfInternal` 恰為三個 `fmModule`(以 `Set.member` 斷言,且**不含**只出現在 `pmSources.sfModule` 的第四個 module 名——釘住 D2)、`gfFacts` 與輸入完全相同(含 `FactDecl` 原樣保留、不 crash)、`gfFiltered == 0` |
| T3 | test_mint_module_nodes | 單一來源檔的 module → id 為裸名;同名兩個來源檔(`app/Main.hs`、`test/Main.hs`)→ 兩個節點 id 各為 `Main@app/Main.hs` / `Main@test/Main.hs` 且 `gnLabel` 皆為裸 `Main`、`gnFile` 各自正確、`gnKind == ModuleNode`、`gnLine == Nothing`;同一 `FactModule` 重複出現 → 只產一個節點;事實流含 `FactDecl` 時不產節點也不 crash;`moduleFiles` 對同名組回傳 2 個相異檔 |
| T4 | test_imports_edges_external | fixture 事實流:內部 `A → B` 產一條 `RImports`(`geLine == Just` 該行);`A → Data.Text` / `A → Data.Map` / `B → Data.Text`(皆非內部)全數丟棄且 `esDroppedExternal == 3`;`esTopExternal` 對 12 個相異外部目標驗證只取前 10、依次數降序、同次數依 module 名字典序(D4);來源檔沒有對應 `FactModule` 的 import → 0 條邊 + 1 則警告;目標落在同名消歧組 → 0 條邊 + 1 則警告(假設 A4) |
| T5 | test_selfloop_and_dedupe | 同一 module 自 import(`fiFrom == fiTo`)→ 不產邊、`esDroppedExternal` 與 `esDeduped` 皆不變、無警告(規則 4);同一對 module 的 3 條 import(行號 40、12、25,含亂序)→ 合併為 1 條、`geLine == Just 12`、`esDeduped == 2`(規則 5);不同 relation 或不同端點不被誤併 |
| T6 | test_build_graph_assemble | 綜合事實流一次驗證 graph-assemble:`GraphStats` 四欄值(`gsFilteredGenerated == 0`)、`cgWarnings` 含碰撞警告(`gwSource` 為 module 名、訊息含兩個排序後的檔案路徑)且整體依 `(gwSource, gwMessage)` 去重排序、`cgNodes` 依 `NodeId` 遞增、`cgEdges` 依 `(geSource, geRelation, geTarget)` 遞增;把輸入事實流反轉後重跑 → `CodeGraph` 完全相同(釘住排序而非輸入序);`moduleOnly = True` 時含 `FactDecl` 的事實流輸出與 `False` 相同 |
| T7 | test_build_graph_deterministic | (實作時另加 `test/fixtures/graph` 端到端子測試,見假設 A9:驗非空邊集、外部丟棄、去重與自環)`loadProjectMeta` + `extract` 取 `test/fixtures/proj` 的真實事實流 → `buildGraph`:節點數 == 該 fixture 成功讀取的 included 檔數(每檔一個 module 節點)、邊全為 `RImports` 且兩端皆為內部節點、外部 import 全數落進 `gsDroppedExternal`;同輸入連續兩次 `buildGraph` 結果 `==`(驗收標準 4);`moduleOnly` 兩取值輸出 `==`(驗收標準 5);hedgehog property:隨機生成 module 名與 import 對(混內部/外部、含重複與自環)→ 產出的 `cgNodes` / `cgEdges` 已排序、邊數 == 相異非自環內部對數、`gsDroppedExternal` == 外部 import 筆數 |
| T8 | test_render_graph_summary | 對已知 `CodeGraph` 值驗證摘要文字(節點/邊/警告筆數、四項統計行、逐筆節點與邊行格式、外部 Top 清單行);MagicFarmer / particle-magic 的實跑屬階段閘門手動唯讀驗收(承 project-meta F001 / extraction F002 慣例),結果記入「實作備註」 |

## 待確認假設

- A1: Level 2 寫「`NodeId` 的唯一構造入口在 node-mint」,但 `GraphNode` 持有 `NodeId`、`mintNodes` 又回傳 `GraphNode`,Haskell 無法在不新增第三個模組的前提下讓 `Knot.Graph.Types` 匯出抽象型別而 node-mint 仍能建構(會形成 import 環)→ 採取:`Knot.Graph.Types` 匯出 `NodeId (..)`,以 haddock 標明唯一使用點是 node-mint,其他模組一律從 `gnId` 取值(edge-derive 的設計即照此,不鑄任何 id)→ 影響:若要求結構性強制,把 newtype 移進 library `other-modules` 的內部模組,`Knot.Graph.Types` 只再匯出型別本身;測試改由 `mintModuleId` 取值,`app` / export-query 需要一個 `nodeIdText :: NodeId -> Text` 取值函式
- A2: **已由編排者裁決(階段一閘門,`design.md` commit `b2a2be3`),不再待確認**。裁決結果:契約簽名改為 `mintModuleId :: ModuleName -> Maybe FilePath -> NodeId`(`Nothing` = 該 module 未碰撞鑄裸名;`Just file` = 碰撞組鑄 `<module>@<file>`)。實作依此落地,**未**另建 `mintModuleIdAt` 非契約面函式;`mintNodes` 依 `moduleFiles` 的碰撞分組決定傳 `Nothing` 還是 `Just`
- A3: **已由編排者裁決(同上)**。裁決結果:契約簽名改為 `deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])`(三元組,警告通道直接進契約)。實作依此落地,**未**另建 `deriveEdgesWithWarnings` 包裝;`EdgeStats` 維持三欄不變,`F003` decl-edges 可直接沿用第三個分量彙整 ref 解析失敗警告
- A4: `import` 的目標落在 D1 消歧組(例:專案有兩個 `Main`,某檔 `import Main`)時,無從判定指向哪一個節點 → 採取:丟棄該邊並發 `GraphWarning`,**不**計入 `gsDroppedExternal`(它不是外部目標)→ 影響:若裁定應對整組每個節點各連一條邊(寧可多報),改 edge-derive 的目標解析分支;下游依賴矩陣會多出偽邊
- A5: 消歧節點的 `gnLabel` 未明定 → 採取:維持**裸 module 名**(契約寫「人類可讀名(module 名)」),消歧只反映在 `gnId` 與 `gnFile`;edge-derive 的節點索引也因此以 `gnLabel` 為鍵 → 影響:若下游查詢輸出要求兩個 `Main` 可辨識,改為 `<module> (<file>)`,同時 edge-derive 的索引鍵要改回從事實重建
- A6: 契約卡未把規則 3(產生碼過濾)列入本 feature,但 `GatedFacts.gfFiltered` / `GraphStats.gsFilteredGenerated` 兩個欄位屬本 feature 的 DTO → 採取:欄位定義齊備但恆為 0,規則 3 留給 `F002` decl-nodes(其契約卡明列規則 3);`gateFacts` 的 `ProjectMeta` 參數本階段不讀取 → 影響:若裁定 module 層也要套規則 3(`fmFile` 不在 `pmSources` 就不建 module 節點),在 fact-gate 加一層過濾,並須先確認 `fmFile` 與 `sfPath` 的路徑正規化完全一致(目前兩者同源,風險低但未驗)
- A7: `cgWarnings` 的排序與去重未在契約定義,而規則 7 要求整體決定性 → 採取:碰撞警告與邊解析警告合併後依 `(gwSource, gwMessage)` 去重並依該鍵字典序輸出(對事實流重排序也穩定)→ 影響:若要求保留事實序以便對照行號,改為穩定排序不去重(同一筆壞 import 會重複出現)
- A8: 契約卡「不印任何輸出」與驗收要在 MagicFarmer / particle-magic 實跑對帳衝突 → 採取:比照 `extraction/F002` 假設 A6 的既有裁決,library 全程不印,改在 executable 內部模組加 `renderGraphSummary` 與 `--graph` 旗標;自動測試一律走 `test/fixtures/` 不依賴外部專案 → 影響:若編排者要求 CLI 相關改動一律等 export-query 的 CLI feature,改以一次性 ghci script 驗收,T8 只留 `renderGraphSummary` 的單元測試
- A9(實作階段新增): T7 原訂以 `test/fixtures/proj` 做端到端,但實測該 fixture 的三個 included 檔**全部沒有 module 標頭也沒有 import**——經 extraction D3(無標頭一律視為 `Main`)後,三檔同名 `Main` 形成一個三元碰撞組、事實流零 `FactImport`,端到端只驗得到「節點數 == included 檔數 + 全部消歧」而驗不到任何邊 → 採取:`proj` 端到端保留(它反而是 D1 消歧的真實樣本),**另新增 `test/fixtures/graph`**(一個 library + 一個 executable,含內部 import、外部 import、重複 import 與自 import),用它驗「非空邊集 + 外部丟棄 + 去重 + 自環」;兩者都跑 → 影響:若編排者不接受新增 fixture,改以既有 `comps` / `multi` fixture 補 import 行,或把邊的端到端驗證退回純事實流的 T6 覆蓋
- A10(實作階段新增): edge-derive 警告的 `gwSource` 未在契約明定用哪一種來源(契約允許「module 名、節點 id 或檔案路徑」)→ 採取:邊解析失敗的警告一律用**來源檔路徑**(`FactImport.fiFile`)當 `gwSource`、行號寫進 `gwMessage`(格式 `…; import edge dropped at line N`),碰撞警告則用 **module 名**當 `gwSource` → 影響:若下游要求所有警告的 `gwSource` 同型別(例如一律節點 id),改 edge-derive 的 `warnAt` 與 graph-assemble 的 `collisionWarnings` 兩處組字,A7 的排序鍵語意不變

## 實作備註

**契約簽名(A2 / A3 裁決)已落地**:`mintModuleId :: ModuleName -> Maybe FilePath -> NodeId` 與 `deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])` 一字不差實作於 `Knot.Graph.NodeMint` / `Knot.Graph.EdgeDerive`;文檔撰寫期規劃的 `mintModuleIdAt` 與 `deriveEdgesWithWarnings` 兩個非契約面包裝**未建立**(契約簽名本身已表達得了消歧與警告通道)。node-mint 仍匯出非契約面的 `moduleFiles`(D1 判定面),供 graph-assemble 組碰撞警告與 T3 測試。

**產出檔案**:`src/Knot/Graph/Types.hs`、`src/Knot/Graph/FactGate.hs`、`src/Knot/Graph/NodeMint.hs`、`src/Knot/Graph/EdgeDerive.hs`、`src/Knot/Graph.hs`(library);`app/Knot/App/Summary.hs`(加 `renderGraphSummary`)、`app/Main.hs`(加 `--graph`);`knot-hs.cabal`(library `exposed-modules` +5、test-suite `build-depends` +`containers`,`version` 維持 `0.0.1.0` 未動);`test/fixtures/graph/`(新 fixture,見假設 A9);`test/Main.hs`(新增 `graph-core/F001 module-graph` group)。全部新程式碼在 `-Wall` 下**零警告**(既有 `test/Main.hs` 與 extraction 模組原有的 `-Wincomplete-record-selectors` 警告未被本 feature 觸碰)。

**測試**:`cabal test` 全綠,`All 63 tests passed`(既有 53 條全部維持通過,本 feature 新增 10 條:T1–T6 各 1、T7 三條子測試、T8 一條;T7 的 hedgehog property 100 例通過)。

**A8 唯讀實跑對帳**(`knot <path> --graph`,GHC 9.14.1;兩個標的皆只讀不寫,連續兩次輸出以 `diff` 驗證位元相同):

| 標的 | 節點 | 邊 | 警告 | `gsDroppedExternal` | `gsDedupedEdges` | `gsFilteredGenerated` | Top-1 外部 |
|---|---|---|---|---|---|---|---|
| MagicFarmer | 58 | 239 | 0 | 283 | 1 | 0 | `Data.Text` 49 |
| particle-magic | 45 | 125 | 1 | 222 | 2 | 0 | `Data.Vector.Unboxed` 16 |

- 兩標的的 `gsTopExternalTargets` 皆恰 10 筆、次數降序(MagicFarmer:`Data.Text` 49 / `Data.Map.Strict` 37 / `GHC.Generics` 30 / `Data.Aeson` 26 / `Control.DeepSeq` 14 …;particle-magic:`Data.Vector.Unboxed` 16 / `Data.Word` 14 / `Data.ByteString` 12 / `Data.List` 12 …),`Data.ByteString` 與 `Data.List` 同為 12 次時依 module 名字典序排列,**D4 在真實資料上成立**
- particle-magic 的唯一警告正是 **D1 碰撞**:`Main` 由 5 個來源檔宣告(`app/Main.hs`、`examples/haskell/Main.hs`、`tools/InspectMain.hs`、`tools/Main.hs`、`tools/SchemaMain.hs`),整組鑄成 `Main@app/Main.hs` … `Main@tools/SchemaMain.hs` 五個節點,無裸名 `Main` 節點,亦無任何「ambiguous import target」警告(該專案沒有檔案 `import Main`)。這是 D1 在真實多 executable 專案上的第一次實證
- MagicFarmer 零警告 → 該專案無同名 module、亦無來源/目標解析失敗
- 兩標的皆 `gsFilteredGenerated == 0`,符合 A6(規則 3 留給 `F002`)

**實作細節備忘**(不影響契約,供 `F002` / `F003` 接手):

- 去重以 `Map (NodeId, NodeId, Relation) (Maybe Int, Int)` 一次完成「最小行號 + 組大小」累積,`esDeduped = Σ(組大小 − 1)`;`geLine` 取極小值而非輸入序第一筆,故對事實流重排序不敏感(T6 的「反轉輸入」與 T7 的 `Gen.shuffle` property 都釘住這點)
- edge-derive 的來源解析先查 `(gnLabel, gnFile)` 精確索引,未命中才退回「該名恰一個節點」;目標解析只走 `gnLabel` 索引(D1 消歧組 >1 時依 A4 丟棄 + 警告)
- `gateFacts` 的 `ProjectMeta` 參數目前以 `_pm` 忽略,haddock 已註明是階段性狀態;`F002` 接手規則 3 時直接在此讀 `pmSources`
- `Knot.Graph.Types` 的 `NodeKind` / `Relation` / `NodeId` / `GraphWarning` 都有 `Ord`,D5 與 A7 的排序鍵全部由 deriving 提供,無自訂 `compare`
