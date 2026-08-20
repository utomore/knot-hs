---
id: extraction
type: subsystem
title: extraction
description: 事實抽取子系統:統一抽取契約與 import-scan、hiedb 雙後端
status: active
created: 2026-08-20
updated: 2026-08-20
parent: system
related-adr: [ADR-002]
---

# extraction 子系統架構

## 定位與範圍

管線第二站(見 system.md「子系統劃分 › extraction」):吃 project-meta 的 `ProjectMeta`,把原始碼與 `.hie` 轉成**事實流**——module 宣告、字面 import、頂層宣告、名稱引用、class/instance 關係——交給 graph-core 組圖。

**職責**:定義統一抽取契約;以內部後端實現之——import-scan(T0,零依賴掃 import 行)與 hiedb-sqlite(T1,呼叫 `hiedb index` 後讀其 SQLite);後端探測、auto 選擇、降級回報與事實流合成。

**明確不做**:不決定節點 id(只提供 `QualName` 原料)、不組圖、不過濾 test(只處理 `sfIncluded = True` 的檔案,接受 project-meta 的判定)、不寫任何輸出檔(`.knot/` 索引快取除外)。

## 對外契約(Public Interface & DTOs)

唯一進入點,呼叫者為 CLI 組裝層(結果轉交 graph-core):

```haskell
extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult
```

```haskell
data ExtractOptions = ExtractOptions
  { backendChoice :: BackendChoice     -- 對應 CLI --backend
  , hiedbExe      :: Maybe FilePath    -- 覆寫 hiedb 執行檔(預設查 PATH)
  , dbPath        :: Maybe FilePath    -- 覆寫索引位置(預設 <root>/.knot/hiedb.sqlite)
  }

data BackendChoice = Auto | ImportsOnly | HiedbOnly

data ExtractResult = ExtractResult
  { erFacts    :: [Fact]
  , erLevel    :: CapabilityLevel      -- 實際達到的能力等級
  , erReports  :: [BackendReport]      -- 各後端:用了/沒用 + 原因
  , erWarnings :: [ExtractWarning]     -- best-effort 蒐集,呼叫端印 stderr
  }

data CapabilityLevel = ModuleLevel | DeclLevel
```

### 事實流 DTO

`QualName` 是 graph-core 鑄造決定性節點 id 的原料(Module + OccName + namespace,對齊 system.md graph-core 的職責);行號供下游 `source_location`(`L<行>`)。

```haskell
data QualName = QualName
  { qnModule :: ModuleName
  , qnOcc    :: Text
  , qnSpace  :: NameSpace              -- 型別的 Foo 與值的 Foo 是兩個名字
  }

data NameSpace = ValueNs | TypeNs

data Fact
  = FactModule                          -- 檔案裡實際宣告的 module
      { fmFile :: FilePath, fmModule :: ModuleName }
  | FactImport                          -- 字面 import 行(imports 邊唯一來源)
      { fiFrom :: ModuleName, fiTo :: ModuleName
      , fiFile :: FilePath, fiLine :: Int }
  | FactDecl                            -- 頂層宣告
      { fdName :: QualName, fdKind :: DeclKind
      , fdFile :: FilePath, fdLine :: Int }
  | FactRef                             -- 名稱引用(calls / uses 邊的原料)
      { frFromModule :: ModuleName
      , frFromDecl   :: Maybe QualName  -- 引用發生在哪個頂層宣告內,由後端解析
      , frTarget     :: QualName
      , frFile :: FilePath, frLine :: Int }
  | FactInstance                        -- implements 邊的兩端
      { fiClass    :: QualName          -- class(TypeNs)
      , fiInstHead :: Text              -- 渲染後的 instance 標頭,如 "Renderable Sprite"
      , fiInstFile :: FilePath, fiInstLine :: Int }

data DeclKind
  = ValueDecl | DataDecl | ClassDecl | InstanceDecl
  | TypeSynDecl | PatSynDecl | FamilyDecl

data BackendReport = BackendReport
  { brBackend :: Text                   -- "import-scan" | "hiedb"
  , brUsed    :: Bool
  , brDetail  :: Text                   -- 未用時的降級原因(找不到執行檔/無 .hie/版本不合…)
  }
```

```haskell
data ExtractWarning = ExtractWarning   -- (批次澄清裁定,比照 MetaWarning 模式)
  { ewSource  :: Text                  -- 來源:檔案路徑或後端名
  , ewMessage :: Text
  }
```

`ModuleName` 直接共用 project-meta 契約的定義(`Knot.Meta.Types`,批次澄清裁定)——同一型別沿管線流動,零轉換。

### 抽取規則(契約的一部分)

1. **納入範圍**:只處理 `pmSources` 中 `sfIncluded = True` 的檔案;`.hie` 清單以 `pmHie.hieFiles` 為準(幽靈檔已被 project-meta 濾除)
2. **後端職責互斥**:`FactImport` **永遠且只**來自 import-scan(字面 import 行,決定性最強、與降級模式行為一致);hiedb 後端只產 `FactDecl` / `FactRef` / `FactInstance`;`FactModule` 由 import-scan 產出;無 module 標頭的檔案依 Haskell 語意視為 `Main`(多個 Main 以 fmFile 區分,批次澄清裁定)
3. **auto 合成**:import-scan 必跑;hiedb 探測通過(執行檔存在、`pmHie` 存在、相容性檢查過)則加跑,`erLevel = DeclLevel`;任一條件不成立記入 `BackendReport` 並降為 `ModuleLevel`。`ImportsOnly` / `HiedbOnly` 只跑指定後端(後者供除錯)
4. **fromDecl 由後端解析**:`FactRef.frFromDecl` 在事實產出時即填好(hiedb 後端以 span 包含關係 join 得出);graph-core 不做 span 比對
5. **相容性探測**:hiedb-driver 需能區分並回報「執行檔不存在」「索引失敗/`.hie` 版本不合」兩類不可用(探測手段屬 Level 3 自主權);extraction 是全系統唯一允許讀 `.hie` 內容的子系統
6. **索引快取**:預設 `<root>/.knot/hiedb.sqlite`(目標專案內**唯一允許新建**的路徑,`dbPath` 可改道);索引重用交給 `hiedb index` 自身的增量機制
7. **best-effort**:單檔解析失敗、單表查詢失敗 → 警告 + 跳過;整個後端失敗 → 降級 + 報告,不中斷
8. **決定性**:事實流排序穩定,同樣輸入產生同樣輸出

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **backend-select** | 後端探測與 auto 策略、依 `BackendChoice` 調度、事實流合成、`ExtractResult` 組裝 |
| **import-scan** | T0 後端:讀 `.hs` 檔的 module 宣告與 import 行 → `FactModule` / `FactImport` |
| **hiedb-driver** | hiedb 執行檔探測、相容性檢查、執行 `hiedb index`、`.knot/` 索引檔管理 → 就緒的索引 |
| **hiedb-facts** | 讀索引 SQLite(mods/decls/defs/refs/exports 表)→ `FactDecl` / `FactRef` / `FactInstance`,含 fromDecl 解析 |

## 資料流管線(Data Flow Pipeline)

```text
ProjectMeta(+ ExtractOptions)
  → backend-select: 探測各後端 → 決定本次啟用清單(auto/指定)
  → import-scan:    included 原始檔 → FactModule/FactImport    (單檔失敗 → 警告跳過)
  → hiedb-driver:   pmHie → hiedb index → 索引就緒              (失敗 → 降級 + 報告)
  → hiedb-facts:    索引 SQLite → FactDecl/FactRef/FactInstance (單查詢失敗 → 警告)
  → backend-select: 合成事實流 + 能力等級 + 報告 → ExtractResult → 交給 graph-core
```

## 模組間公開介面(Module Interfaces)

```haskell
-- 後端抽象(backend-select 調度的統一介面,兩後端各實現一份)
data Backend = Backend
  { bName  :: Text
  , bLevel :: CapabilityLevel
  , bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult
  , bRun   :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
  }

data ProbeResult = Available | Unavailable Text   -- 不可用原因(進 BackendReport)

-- hiedb-driver 供 hiedb-facts 使用:確保索引就緒
ensureIndex :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)

-- hiedb-facts:從就緒索引讀事實
readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])
```

`IndexHandle` 為「已就緒索引」的不透明參照(內容屬 Level 3)。

## 使用的技術

沿用主架構技術棧。子系統特有選型:

- **hiedb 執行檔**(外部、選用):依 ADR-002;使用者以同版 GHC 加 `--allow-newer=hie-compat:base` 安裝
- **sqlite-simple** 讀 hiedb 索引:2026-08-20 實測 sqlite-simple 0.4.19 + direct-sqlite 2.3.29(自帶 C sqlite3,無系統依賴)在 GHC 9.14.1 編譯成功,並實際讀出 hiedb 0.8 的 schema(`mods` / `decls` / `defs` / `refs` / `exports` / `imports` / `typerefs` 等表)。純 C binding、API 面小,第三方風險遠低於 link `ghc` 的套件;若未來版本編不過,fallback 為解析 `hiedb` 查詢子命令的文字輸出

## 架構圖

```text
 ExtractOptions + ProjectMeta
      │
      ▼
 ┌─ extraction ────────────────────────────────────────────────┐
 │  backend-select(探測/調度/合成)                            │
 │      │                    │                                  │
 │      ▼                    ▼                                  │
 │  import-scan          hiedb-driver ──▶ hiedb 執行檔(外部)  │
 │      │                    │ IndexHandle      │               │
 │      │                    ▼                  ▼               │
 │      │                hiedb-facts ◀── .knot/hiedb.sqlite     │
 │      │ FactModule         │ FactDecl/FactRef/FactInstance    │
 │      │ FactImport         │                                  │
 │      └────────┬───────────┘                                  │
 │               ▼                                              │
 │        ExtractResult(facts + level + reports + warnings)    │
 └───────────────┬──────────────────────────────────────────────┘
                 ▼
            graph-core
```

## 開發階段

對應主架構 S1(fact-contract、import-scan)與 S3(hiedb-driver、hiedb-facts)。無額外內部里程碑。

## 功能規劃

### 階段一:S1 骨架

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | fact-contract | Fact DTO、後端抽象介面、能力分級、auto 選擇與降級合成 | backend-select | - | F001 |
| 2 | import-scan | T0 後端:import 行解析、module 宣告事實 | import-scan | #1 | - |

### 階段二:S3 函式級

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 3 | hiedb-driver | hiedb 探測、相容檢查、index 呼叫、.knot 索引管理 | hiedb-driver | #1 | - |
| 4 | hiedb-facts | 讀 SQLite 出 decl/ref/instance 事實、fromDecl 解析 | hiedb-facts | #3 | - |

(共 4 個 features、2 個階段;全部完成即子系統可交付)

## Feature 契約卡

### fact-contract

- **階段**:階段一
- **負責模組**:backend-select
- **實作的 Level 2 介面**:`extract` 進入點;DTO `ExtractOptions`、`BackendChoice`、`ExtractResult`、`CapabilityLevel`、`Fact`(全部建構子)、`QualName`、`NameSpace`、`DeclKind`、`BackendReport`、`ExtractWarning`;模組介面 `Backend`、`ProbeResult`;落實抽取規則 1(納入範圍)、3(auto 合成與降級)、7(best-effort)、8(決定性)
- **資料流管線段落**:從 `ProjectMeta + ExtractOptions` 進,經探測與調度(本階段僅 import-scan 一個後端可註冊),出合成後的 `ExtractResult`
- **驗收標準**:以假後端(測試替身)驗證——auto 模式下探測失敗的後端出現在 `erReports` 且附原因、`erLevel` 正確反映實際跑的後端;`HiedbOnly` 但後端不可用時回空事實 + 報告而不 crash;事實流排序穩定(同輸入兩次結果相同)
- **明確不做**:不實作任何真後端(import-scan、hiedb 各有 feature);不解析任何檔案;不定義 CLI 參數解析(屬 CLI 組裝層)

### import-scan

- **階段**:階段一
- **負責模組**:import-scan
- **實作的 Level 2 介面**:`Backend` 介面的 import-scan 實例(`bLevel = ModuleLevel`);產出 `FactModule` 與 `FactImport`;落實抽取規則 2(imports 唯一來源)
- **資料流管線段落**:從 `pmSources` 中 `sfIncluded = True` 的檔案進,出 `FactModule` / `FactImport` 事實流
- **驗收標準**:對 MagicFarmer 與 particle-magic(唯讀)執行——每個 included 檔案有一筆 `FactModule`;`import`、`import qualified X as Y`、`import X (…) hiding (…)` 多行語法都能抽出 `FactImport`;CPP 條件內的 import 依字面抽取(best-effort,行為寫進文件);單檔讀取失敗印警告不中斷;連續兩次執行輸出相同
- **明確不做**:不解析 import 清單明細(只到 module 對 module);不讀 `.hie`;不驗證 import 的 module 是否存在(懸空 import 留給 graph-core 處理);不做完整 Haskell 語法解析(只認 module 標頭與 import 區)

### hiedb-driver

- **階段**:階段二
- **負責模組**:hiedb-driver
- **實作的 Level 2 介面**:`Backend` 介面 hiedb 實例的探測面(`bProbe`);模組介面 `ensureIndex`、`IndexHandle`;落實抽取規則 5(兩類不可用的區分回報)、6(`.knot/hiedb.sqlite` 預設位置與 `dbPath` 改道)
- **資料流管線段落**:從 `pmHie` 進,經執行檔探測 → `hiedb index` → 出就緒的 `IndexHandle`(或降級原因)
- **驗收標準**:hiedb 不在 PATH 時 `ProbeResult = Unavailable`(原因指明執行檔)且整體降級為 `ModuleLevel` 不失敗;對 fixture 專案(自建,含 `.hie`)執行後 `.knot/hiedb.sqlite` 存在且可被 SQLite 開啟;`dbPath` 覆寫時 `.knot/` 不被建立;重跑時索引重用(第二次明顯不重做全量)
- **明確不做**:不讀索引內容出事實(hiedb-facts 的事);不自己解析 `.hie` 產索引;不管理 `.gitignore`(只在首次建立 `.knot/` 時印提示);不清理過期索引

### hiedb-facts

- **階段**:階段二
- **負責模組**:hiedb-facts
- **實作的 Level 2 介面**:`Backend` 介面 hiedb 實例的執行面(`bRun`,經 `ensureIndex` 取得 `IndexHandle` 後呼叫 `readIndexFacts`);模組介面 `readIndexFacts`;產出 `FactDecl` / `FactRef` / `FactInstance`;落實抽取規則 4(fromDecl 由 SQL span 包含 join 解析)
- **資料流管線段落**:從 `IndexHandle` 進,查 mods/decls/defs/refs/exports 表,出 decl 層事實流
- **驗收標準**:對 fixture 專案(兩 module、跨 module 呼叫、一組 class/instance)執行——跨 module 呼叫產出 `FactRef` 且 `frFromDecl` 指向正確的頂層宣告;class 與 instance 產出 `FactInstance`;`qnSpace` 正確區分同名的型別與值;產出的 `QualName` 全部可對映回 `pmSources` 的 module(對映不到的印警告);連續兩次執行輸出相同
- **明確不做**:不輸出型別資訊(`typerefs` / `typenames` 表本版不用,DTO 已預留擴充空間);不處理 TH/deriving 產生碼的過濾(graph-core 的職責);不做圖層面的聚合
