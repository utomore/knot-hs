---
id: extraction
type: subsystem
title: extraction
description: 事實抽取子系統:自驅動插樁建置、內嵌 hiedb,兩層缺一不可
status: active
created: 2026-08-20
updated: 2026-08-22
parent: system
related-adr: [ADR-006, ADR-001]
code-paths: [src/Knot/Extract, src/Knot/Extract.hs]
---

# extraction 子系統架構

## 定位與範圍

管線第二站(見 system.md「子系統劃分 › extraction」):吃 project-meta 的 `ProjectMeta`,把原始碼與 `.hie` 轉成**事實流**——module 宣告、字面 import、頂層宣告、名稱引用——交給 graph-core 組圖。

**職責**(S5 起,→ ADR-006):定義統一抽取契約;**自行驅動目標專案的插樁建置**產生 `.hie`(落在 `.knot/`,不碰對方既有建置產物);以**內嵌的 hiedb library** 建索引並讀取;兩個事實來源(import-scan、hie-index)**缺一不可**,任一整體失敗即回報失敗,不產出部分事實流。

**明確不做**:不決定節點 id(只提供 `QualName` 原料)、不組圖、不過濾 test(只處理 `sfIncluded = True` 的檔案與 `compExcluded = False` 的 component,接受 project-meta 的判定)、不寫 `codegraph.json`。**唯一的檔案副作用是 `.knot/` 快取目錄**。

**S5 從 project-meta 接手的職責**:`.hie` 的定位、列舉與幽靈過濾。理由:`.hie` 現在由 extraction 自建,project-meta 跑在建置之前、看不到它;由建的人自己列舉,沒有時序耦合。

**S5 廢除的概念**:後端選擇(`BackendChoice`)、能力分級(`CapabilityLevel`)、探測與降級回報(`BackendReport`)、外部 hiedb 執行檔、使用者自產 `.hie`。module 級的關聯無法協助寫 code,「降級成功」只是把沒用的結果回報成成功(ADR-006)。

## 對外契約(Public Interface & DTOs)

唯一進入點,呼叫者為 CLI 組裝層(結果轉交 graph-core):

```haskell
extract :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)
```

```haskell
data ExtractOptions = ExtractOptions
  { rootDir :: FilePath        -- 專案根目錄(sfPath 等 repo 相對路徑的錨點;.knot/ 建於此下)
  }
  -- 要建置哪些 component 不在此指定:由 ProjectMeta 的 compExcluded 決定
  -- (--include-tests 已在 project-meta 階段落實為 compExcluded / sfIncluded)

data ExtractResult = ExtractResult
  { erFacts    :: [Fact]
  , erWarnings :: [ExtractWarning]   -- 單檔層級的 best-effort 警告,呼叫端印 stderr
  }

-- 整體失敗:兩層任一層拿不到。呼叫端 exit 1,與 --strict 無關
data ExtractFailure
  = BuildFailed      { bfComponent :: Text, bfDetail :: Text }  -- 某個 component 插樁建置失敗(cabal 輸出尾段)
  | VersionMismatch  { vmHie :: Text, vmKnot :: Text }          -- .hie 的 GHC 版本 ≠ knot 的(ADR-001)
  | IndexFailed      { ifDetail :: Text }                        -- hiedb 索引整體失敗
  | NoSources                                                    -- 納入範圍內零個原始檔
```

### 事實流 DTO

`QualName` 是 graph-core 鑄造決定性節點 id 的原料(Module + OccName + namespace);行號供下游 `source_location`(`L<行>`)。**S5 不動這一節**。

```haskell
data QualName = QualName
  { qnModule :: ModuleName
  , qnOcc    :: Text
  , qnSpace  :: NameSpace              -- 型別的 Foo 與值的 Foo 是兩個名字
  }

-- 四值與 hiedb 的 occ 前綴一對一(2026-08-21 實測 knot-hs 自身索引:
-- v: 108、c: 95、t: 50、f<父型別>: 166+)。刻意不壓縮成「值/型別」二分——
-- graph-core 以 (Module, Occ, namespace) 鑄決定性節點 id,壓縮會讓不同的
-- GHC 實體可能撞出同一個 id
data NameSpace
  = ValueNs        -- hiedb "v:" 一般值(函式、變數)
  | DataConNs      -- hiedb "c:" 資料建構子
  | TypeNs         -- hiedb "t:" 型別與 class(GHC 的 tcClsName,兩者同命名空間)
  | FieldNs        -- hiedb "f<父型別>:" 記錄欄位選擇器
  -- hiedb 另有 "z:"(型別變數):刻意不涵蓋。型別變數是簽名內的區域名字、
  -- 不是架構實體;遇到時跳過該列,依前綴彙整成一則警告

data Fact
  = FactModule                          -- 檔案裡實際宣告的 module
      { fmFile :: FilePath, fmModule :: ModuleName }
  | FactImport                          -- 字面 import 行(imports 邊唯一來源)
      { fiFrom :: ModuleName, fiTo :: ModuleName
      , fiFile :: FilePath, fiLine :: Int }
  | FactDecl                            -- 頂層宣告
      { fdName :: QualName, fdKind :: DeclKind
      , fdGenerated :: Bool             -- 宣告本身是產生碼(G-E003)
      , fdFile :: FilePath, fdLine :: Int }
  | FactRef                             -- 名稱引用(calls / uses 邊的原料)
      { frFromModule :: ModuleName
      , frFromDecl   :: Maybe QualName  -- 引用發生在哪個頂層宣告內,由 hie-facts 解析
      , frTarget     :: QualName
      , frGenerated  :: Bool            -- 引用**站點**是產生碼(hiedb refs.is_generated)
      , frTargetGenerated :: Bool       -- 引用**目標**是產生碼宣告(G-E003)
      , frFile :: FilePath, frLine :: Int }
  | FactInstance                        -- implements 邊的兩端(建構子保留、零邏輯,見 hie-facts 卡)
      { fiClass    :: QualName
      , fiInstHead :: Text
      , fiInstFile :: FilePath, fiInstLine :: Int }

-- hiedb 索引時丟棄了 GHC 的 DeclType,class / type synonym / family 與 data
-- 無從區分,只能由 occ 前綴粗推。消費端(graph-core 的 DeclNode)不得假設
-- 能分辨 class。要補滿精度得直接讀 .hie(ADR-006 替代方案 2、3 的路線)
data DeclKind
  = ValueDecl | DataDecl | ClassDecl | InstanceDecl
  | TypeSynDecl | PatSynDecl | FamilyDecl
```

```haskell
data ExtractWarning = ExtractWarning   -- 比照 MetaWarning 模式
  { ewSource  :: Text                  -- 來源:檔案路徑或來源名
  , ewMessage :: Text
  }
```

`ModuleName` 直接共用 project-meta 契約的定義(`Knot.Meta.Types`)——同一型別沿管線流動、零轉換;`Knot.Extract.Types` 代為 re-export(G-E004)。`ComponentRef` 同樣共用。

### 抽取規則(契約的一部分)

1. **納入範圍**:只處理 `pmSources` 中 `sfIncluded = True` 的檔案;只建置 `pkgComponents` 中 `compExcluded = False` 的 component。**`.hie` 的清單由 extraction 自己列舉**(`.knot/build/` 各 component 輸出目錄下),不再來自 project-meta
2. **來源職責互斥**:`FactImport` **永遠且只**來自 import-scan(字面 import 行,決定性最強);`FactDecl` / `FactRef` **永遠且只**來自 hie-index + hie-facts;`FactModule` 由 import-scan 產出;無 module 標頭的檔案依 Haskell 語意視為 `Main`(多個 `Main` 以 `fmFile` 區分)
3. **兩層缺一不可**(取代舊規則 3「auto 合成」):import-scan 與 hie-index 兩者**都必須整體成功**才回 `Right ExtractResult`;任一整體失敗回 `Left ExtractFailure`,**不產出部分事實流**。沒有「只跑其中一個」的模式。**decl 層「成立」的判準是 hie-facts 至少讀出一筆 `FactDecl`**:`ensureIndex` 回 `Right` 只代表索引檔就緒,索引讀不出任何頂層宣告(索引檔壞掉、`mods` / `defs` 查詢失敗、全部 `.hie` 單檔失敗)一律視為 `IndexFailed`,不得以「零 decl 事實 + 警告」的 `Right` 混過去——那正是 ADR-006 要消滅的降級成功(2026-08-22 F007 裁決)
4. **fromDecl 由 hie-facts 解析**:`FactRef.frFromDecl` 在事實產出時即填好(以 span 包含關係 join 得出);graph-core 不做 span 比對。span 包含是一對多,取 **span 最小(最內層)** 的候選;span 大小相同時依 `(qnSpace, qnOcc)` 字典序破雷。**候選集是該檔全部 `decls` 列,不得以 `is_root` 過濾**——一般頂層函式繫結是 `is_root = 0`,帶著該過濾 `calls` 邊會全空而查詢不報錯(2026-08-21 實測)
4a. **產生碼只標註、不過濾**(G-E003):`frGenerated` 原樣轉載 hiedb `refs.is_generated`;`fdGenerated` / `frTargetGenerated` 由「該名字在其 module 的 `defs` 有列、`decls` 無列」判定——這是結構事實,不是 `$f` 前綴的名字啟發式。要不要丟棄是 graph-core 規則 3 的決定。`decls` 表整個讀不到或為空時,兩個旗標一律 `False` 並發一則警告;**絕不因為查不到就把全部宣告當成產生碼**
5. **插樁建置由 extraction 驅動**(ADR-006):每次 `extract` 都對目標專案執行**一次** `cabal build all`(納入的 test-suite / benchmark 以 `--enable-tests` / `--enable-benchmarks` 帶入),加上 `-fwrite-ide-info` 與指向 `.knot/build/` 的 builddir、**不帶 `-hiedir`**、**帶 `--project-dir=<root>`**:cabal 只認 `rootDir`——有 `cabal.project` 就用它,沒有就以該目錄的 `.cabal` 為隱含專案,**不會往上層目錄找別人的 `cabal.project`**(否則指向子目錄時會把上層整個專案建進 `.knot/`;F006 實測)。語意是「指到哪、建哪」;monorepo 子套件若依賴上層 `cabal.project` 的設定,使用者應指向 monorepo 根。**增量交給 cabal**——它用內容雜湊判斷要不要重編,knot 不自己發明一套 mtime 比對(那會漏掉 `.cabal` 改動、旗標改動、相依升版)。沒改動時是一次 up-to-date 檢查(實測 247 ms)。**cabal 的 stdout / stderr 即時轉發到呼叫端的 stderr**——這是轉發子程序輸出,不是 library 自行列印(「不印」的對象是警告與報告,那些仍由 CLI 層印);失敗時尾段進 `bfDetail`。任一 component 建置失敗 → `BuildFailed`,**不 fallback**
6. **每個 component 各自一個 `.hie` 目錄**——由 cabal 天然提供,不由 knot 指定:建置**只帶 `-fwrite-ide-info`、不帶 `-hiedir`**,GHC 會把 `.hie` 寫在 `.hi` 旁,而 cabal 本來就替每個 component 準備獨立輸出目錄(`…/<kind>/<comp>/…/extra-compilation-artifacts/hie/`)。理由:GHC 的 `-hiedir` 依 module 名決定路徑、不含 component,`executable` 與 `test-suite` 都有 `Main` 時共用目錄會互相覆蓋(G-B001 的根因)。**不得改用逐 component 各帶 `-hiedir` 的作法**:2026-08-22 spike 證實換 `--ghc-options` 會被 cabal 當組態變更,每次全量重編(9.2 s vs 247 ms)。分目錄後碰撞在設計上不存在,每個 `.hie` 的 component 歸屬由路徑推得
7. **`.knot/` 快取目錄**:固定在 `<root>/.knot/`,**不提供改道**(它是快取,與 `dist-newstyle` 同性質)。佈局:`build/`(cabal builddir,`.hie` 在其內各 component 的輸出目錄下,規則 6)、索引檔、以及**首次建立時自動寫入內容為 `*` 的 `.gitignore`**——使用者連 `.gitignore` 都不用改。內容格式屬 Level 3 自主權;刪掉整個目錄只會讓下次變慢
8. **GHC 版本相容**(ADR-001):只索引 `.knot/build/` 下 `ghc-<knot 自身版本>/` 目錄內的 `.hie`——cabal 的 builddir 路徑天然帶版本,**不讀檔頭**;其他版本目錄是 GHC 升級後的殘骸(cabal 不會再碰),略過。**零個相符 → `VersionMismatch` 失敗**(不再是警告或降級),`vmHie` 帶觀察到的版本,CLI 層據此印出 `cabal install knot-hs -w ghc-<版本>`。目標專案若以 `with-compiler` 釘了別的 GHC,就是這條失敗。一份 knot 只能讀一版 GHC 的 `.hie`(`.hie` 是 GHC 內部結構的二進位序列化,讀取器在 `ghc` library 裡、精確比對版本),跨版本的正解是每版 GHC 各裝一份 knot
9. **單檔 best-effort**(在兩層都整體成立的前提下):單一原始檔解析失敗、單一 `.hie` 對映不到納入範圍內的原始檔(含過期的 `.hie`:模組已刪但舊檔還在 `.knot/build/`)→ 警告 + 跳過,仍產出事實流。這一條與規則 3 的分界:**整體**拿不到是失敗,**個別**檔案拿不到是警告
10. **決定性**:事實流排序穩定,同樣輸入產生同樣輸出

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **fact-pipeline**(原 backend-select) | 串接四個模組、落實規則 3(兩層缺一不可)、組裝 `ExtractResult` / `ExtractFailure`;沒有探測、沒有選擇、沒有降級 |
| **import-scan** | 讀 `.hs` 檔的 module 宣告與 import 行 → `FactModule` / `FactImport` |
| **build-driver**(新) | 對目標專案執行一次插樁建置(`cabal build all`,旗標恆定),維護 `.knot/` 佈局(規則 5、6、7),列舉各 component 輸出目錄下的 `.hie` → `HieLayout` |
| **hie-index**(原 hiedb-driver) | 列舉 `HieLayout`、GHC 版本檢查(規則 8)、以**內嵌的 hiedb library** 增量建索引 → `IndexHandle` |
| **hie-facts**(原 hiedb-facts) | 讀索引(mods/decls/defs/refs 表)→ `FactDecl` / `FactRef`,含 fromDecl 解析與產生碼標註(規則 4、4a、9) |

## 資料流管線(Data Flow Pipeline)

```text
ProjectMeta(+ ExtractOptions)
  → import-scan:   included 原始檔 → FactModule / FactImport           (單檔失敗 → 警告跳過;零檔 → NoSources)
  → build-driver:  cabal build all(插樁、增量、旗標恆定)→ HieLayout   (建置失敗 → BuildFailed)
  → hie-index:     HieLayout → 版本檢查 → 內嵌 hiedb 增量索引 → IndexHandle (版本不合 → VersionMismatch;索引失敗 → IndexFailed)
  → hie-facts:     IndexHandle → FactDecl / FactRef                      (單 .hie 對映不到 → 警告跳過)
  → fact-pipeline: 兩層皆成立 → Right ExtractResult → 交給 graph-core
                   任一 Left → 原樣往上,不產部分事實流
```

## 模組間公開介面(Module Interfaces)

```haskell
-- import-scan
scanImports :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])

-- build-driver:對每個納入的 component 做插樁建置,回傳 .hie 佈局
ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)

data HieLayout = HieLayout
  { hlRoot  :: FilePath                       -- <root>/.knot/build
  , hlFiles :: [(ComponentRef, FilePath)]     -- 每個 .hie 屬於哪個 component;路徑 repo 相對正斜線
  }

-- hie-index:版本檢查 + 增量索引
ensureIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure IndexHandle)

-- hie-facts:從就緒索引讀事實
readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])
```

`IndexHandle` 為「已就緒索引」的不透明參照(內容屬 Level 3)。`ComponentRef` 共用 project-meta 契約的定義。

**廢除的介面**:`Backend`、`ProbeResult`、`BackendChoice`、`CapabilityLevel`、`BackendReport`、舊簽名的 `ensureIndex :: ExtractOptions -> ProjectMeta -> …`。

## 使用的技術

沿用主架構技術棧。子系統特有選型(→ ADR-006):

- **hiedb 作為 library 嵌入**(`build-depends`):索引走其 library API,不 spawn 外部執行檔。`cabal.project` 以 `allow-newer: hie-compat:base, hie-compat:ghc` 解相依——2026-08-22 spike:直接嵌入失敗(`hie-compat` 要求 `base < 4.22`),加該設定後解析通過;library 確實匯出索引能力。連帶消失:執行檔 PATH 解析、`--help` smoke test、Windows 32767 字元命令列分批、exit code 與 stdout 解析
- **目標專案的 `cabal`**(透過 process 呼叫):插樁建置唯一的外部程序。`--builddir` 隔離經 dry-run 驗證,不動對方的 `dist-newstyle`
- **sqlite-simple** 讀索引:沿用,2026-08-20 實測在 GHC 9.14.1 可用。是否改走 hiedb 的查詢 API 屬 Level 3 自主權

## 架構圖

```text
 ExtractOptions + ProjectMeta
      │
      ▼
 ┌─ extraction ─────────────────────────────────────────────────────┐
 │  fact-pipeline(串接;兩層缺一不可)                              │
 │      │                      │                                     │
 │      ▼                      ▼                                     │
 │  import-scan            build-driver ──▶ 目標專案的 cabal build   │
 │      │                      │ HieLayout        (插樁、增量)       │
 │      │                      ▼                    │                │
 │      │                  hie-index ◀──────────────┘ .knot/build/   │
 │      │                      │ IndexHandle  (內嵌 hiedb library)   │
 │      │                      ▼                                     │
 │      │                  hie-facts ◀── .knot/ 索引                 │
 │      │ FactModule           │ FactDecl / FactRef                  │
 │      │ FactImport           │                                     │
 │      └──────────┬───────────┘                                     │
 │                 ▼                                                 │
 │   Right ExtractResult(facts + warnings)│ Left ExtractFailure     │
 └─────────────────┬─────────────────────────────────────────────────┘
                   ▼
              graph-core(只收 Right;Left 由組裝層 exit 1)
```

## 開發階段

對應主架構 S1(fact-contract、import-scan)、S3(hiedb-driver、hiedb-facts)與 **S5(零前置重構)**。S5 的三個 feature 把 ADR-006 落地,完成後 S1/S3 的四個 feature 中被廢除的介面由程式碼一併移除。

## 功能規劃

### 階段一:S1 骨架(已完成)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | fact-contract | Fact DTO、後端抽象介面、能力分級、auto 選擇與降級合成 | backend-select | - | F001 |
| 2 | import-scan | T0 後端:import 行解析、module 宣告事實 | import-scan | #1 | F002 |

### 階段二:S3 函式級(已完成)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 3 | hiedb-driver | hiedb 探測、相容檢查、index 呼叫、.knot 索引管理 | hiedb-driver | #1 | F003 |
| 4 | hiedb-facts | 讀 SQLite 出 decl/ref 事實、fromDecl 解析 | hiedb-facts | #3 | F004 |

### 階段三:S5 零前置重構(ADR-006)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 5 | build-driver | 一次 `cabal build all` 插樁建置進 `.knot/build/`、`.hie` 由 cabal 按 component 分目錄、`.gitignore` 自建、`BuildFailed` 語意 | build-driver | - | F005 |
| 6 | hiedb-embed | hiedb 改 library 嵌入、列舉 `HieLayout`、版本檢查改為失敗、增量索引 | hie-index | #5 | F006 |
| 7 | two-layer-contract | 契約收斂(砍 `BackendChoice` / `CapabilityLevel` / `BackendReport`、加 `ExtractFailure`)、fact-pipeline 全有全無、移除探測與降級 | fact-pipeline、import-scan | #5, #6 | F007 |

(共 7 個 features、3 個階段;階段三全部完成即 S5 在 extraction 側交付。`#5` 與 `#6` 可平行——`HieLayout` 已在契約定義,`#6` 可先以固定佈局測試)

## Feature 契約卡

### build-driver

- **階段**:階段三
- **負責模組**:build-driver
- **實作的 Level 2 介面**:模組介面 `ensureHie`、`HieLayout`;DTO `ExtractFailure` 的 `BuildFailed` 建構子;落實抽取規則 5(插樁建置由 extraction 驅動、增量交給 cabal、失敗不 fallback)、6(每 component 一個 hiedir)、7(`.knot/` 佈局與自建 `.gitignore`)
- **資料流管線段落**:從 `ProjectMeta` 的納入 component 清單進,經目標專案的 `cabal build`,出 `HieLayout`(或 `BuildFailed`)
- **驗收標準**:對 knot-hs 自身(唯讀)執行——`.knot/build/`、各 component 輸出目錄下的 `.hie`、`.knot/.gitignore`(內容 `*`)三者存在;對方的 `dist-newstyle/` **位元組級不變**(建置前後比對);`hlFiles` 每筆的 component 與其 `.hie` 所在子目錄一致;**`exe:knot` 與 `test:knot-test` 的 `Main.hie` 落在不同目錄、兩份都存在**(G-B001 的根因不再發生);第二次執行明顯快於第一次(cabal 增量);故意讓某個 component 編不過 → 回 `BuildFailed` 且 `bfComponent` 指名該 component、`bfDetail` 含 cabal 的錯誤訊息;`compExcluded = True` 的 component 不被建置
- **明確不做**:不讀 `.hie` 內容(hie-index 的事);不建索引;不判斷 `.hie` 新不新鮮(規則 5:每次都叫 cabal,由它判斷);不支援 stack(主架構非目標);不清理 `.knot/` 裡過期的 `.hie`(規則 9 的丟棄路徑負責)

### hiedb-embed

- **階段**:階段三
- **負責模組**:hie-index
- **實作的 Level 2 介面**:模組介面 `ensureIndex`(新簽名,吃 `HieLayout`)、`IndexHandle`;DTO `ExtractFailure` 的 `VersionMismatch`、`IndexFailed` 建構子;落實抽取規則 8(版本不合即失敗)、規則 1 的 `.hie` 列舉部分(自 `HieLayout` 取,不再有 `pmHie`)
- **資料流管線段落**:從 `HieLayout` 進,經版本檢查 → 內嵌 hiedb 的增量索引,出 `IndexHandle`(或失敗)
- **驗收標準**:**knot-hs 的 `build-depends` 含 hiedb、`cabal.project` 含對應的 `allow-newer`,且閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` 仍 exit 0**(ADR-002 點名的編譯連動風險要實際承受一次);程式碼中**不再有**任何 spawn `hiedb` 執行檔的路徑(PATH 查找、`--help` 探測、命令列分批全部移除);對 fixture 專案索引後,索引內 `mods` 列數 = **版本相符**的 `hlFiles` 筆數;對同一 `HieLayout` 連跑兩次,第二次索引列數不變且明顯較快(增量);`HieLayout` 只含 `ghc-9.12.2/` 路徑時 → `VersionMismatch` 且 `vmHie` = `9.12.2`、`vmKnot` = 自身版本(路徑判定,不需別版 GHC 的 fixture);混有自身版本與舊版路徑時只索引相符者;索引失敗(例如索引檔所在目錄不可寫)→ `IndexFailed`。**索引需求 hiedb 的測試不再有「沒裝就跳過」的分支**——hiedb 現在是 build-depends,沒裝就編不過
- **明確不做**:不驅動建置(build-driver 的事);不讀索引出事實(hie-facts 的事);不處理 `.hie` 對映不到原始檔的情況(規則 9,hie-facts 的丟棄路徑);不提供索引位置覆寫

### two-layer-contract

- **階段**:階段三
- **負責模組**:fact-pipeline、import-scan
- **實作的 Level 2 介面**:`extract` 進入點的新簽名(回 `Either ExtractFailure ExtractResult`);DTO `ExtractOptions`(只剩 `rootDir`)、`ExtractResult`(只剩 `erFacts` / `erWarnings`)、`ExtractFailure` 的 `NoSources` 建構子;模組介面 `scanImports`;**移除** `Backend`、`ProbeResult`、`BackendChoice`、`CapabilityLevel`、`BackendReport`;落實抽取規則 2(來源職責互斥)、3(兩層缺一不可)、9(單檔 best-effort 與整體失敗的分界)、10(決定性)
- **資料流管線段落**:整條——從 `ProjectMeta + ExtractOptions` 進,串接四個模組,出 `Right ExtractResult` 或 `Left ExtractFailure`
- **驗收標準**:`Knot.Extract.Types` 的匯出清單不再含任何廢除的型別,且 `src/` 與 `app/` 全部編譯通過(公開 library 只 re-export 契約模組,廢除的型別若有殘留引用會是編譯錯誤);`build-driver` 回 `BuildFailed` 時 `extract` 回 `Left` 且**零事實**(不是「只有 import 事實」);納入範圍零檔 → `NoSources`;兩層都成立時 `erFacts` 同時含 `FactModule` / `FactImport` / `FactDecl` / `FactRef`;對 knot-hs 自身跑完整管線,節點數不低於 S3 閘門的 548(decl 層沒有因為重構而縮水);五份黃金檔(G-E001)的 module 層輸出 byte 不變;同輸入兩次結果相同。**`test_included_scope`(G-B001)的斷言沿用**:後端收到完整清單、但產出的事實不提及被排除的檔
- **明確不做**:不動 `Fact` / `QualName` / `NameSpace` / `DeclKind` / `ExtractWarning`;不動 hie-facts 的查詢與解析邏輯;不改 CLI 旗標(export-query 的事,但本 feature 砍掉 `ExtractOptions` 欄位後 CLI 的對映會編不過——**那是預期的,由 export-query 的對應 feature 接手**);不保留任何「只跑一層」的除錯模式

**歷史契約卡(階段一、二,已完成)**

以下四張為 F001–F004 完成時的契約卡,**所引用的 `Backend` / `ProbeResult` / `BackendChoice` / `CapabilityLevel` / `BackendReport` 已於 S5 廢除**,僅供回溯當時的驗收依據;新的契約以階段三三張卡為準。

### fact-contract

- **階段**:階段一
- **負責模組**:backend-select(S5 改名 fact-pipeline)
- **實作的 Level 2 介面**:`extract` 進入點;DTO `ExtractOptions`、`BackendChoice`、`ExtractResult`、`CapabilityLevel`、`Fact`(全部建構子)、`QualName`、`NameSpace`、`DeclKind`、`BackendReport`、`ExtractWarning`;模組介面 `Backend`、`ProbeResult`;落實當時的抽取規則 1、3、7、8
- **資料流管線段落**:從 `ProjectMeta + ExtractOptions` 進,經探測與調度,出合成後的 `ExtractResult`
- **驗收標準**:以假後端驗證——auto 模式下探測失敗的後端出現在 `erReports` 且附原因、`erLevel` 正確反映實際跑的後端;`HiedbOnly` 但後端不可用時回空事實 + 報告而不 crash;事實流排序穩定
- **明確不做**:不實作任何真後端;不解析任何檔案;不定義 CLI 參數解析

### import-scan

- **階段**:階段一
- **負責模組**:import-scan
- **實作的 Level 2 介面**:`Backend` 介面的 import-scan 實例;產出 `FactModule` 與 `FactImport`;落實抽取規則 2
- **資料流管線段落**:從 `pmSources` 中 `sfIncluded = True` 的檔案進,出 `FactModule` / `FactImport`
- **驗收標準**:對 MagicFarmer 與 particle-magic(唯讀)執行——每個 included 檔案有一筆 `FactModule`;多行 import 語法都能抽出 `FactImport`;CPP 條件內的 import 依字面抽取;單檔讀取失敗印警告不中斷;連續兩次執行輸出相同
- **明確不做**:不解析 import 清單明細;不讀 `.hie`;不驗證 import 的 module 是否存在;不做完整 Haskell 語法解析

### hiedb-driver

- **階段**:階段二
- **負責模組**:hiedb-driver(S5 改名 hie-index)
- **實作的 Level 2 介面**:`Backend` 介面 hiedb 實例的探測面;模組介面舊簽名的 `ensureIndex`、`IndexHandle`;落實當時的規則 5、6
- **資料流管線段落**:從 `pmHie` 進,經執行檔探測 → `hiedb index` → 出 `IndexHandle`
- **驗收標準**:hiedb 不在 PATH 時降級為 `ModuleLevel` 不失敗;對 fixture 執行後 `.knot/hiedb.sqlite` 存在;`dbPath` 覆寫時 `.knot/` 不被建立;重跑時索引重用
- **明確不做**:不讀索引內容出事實;不自己解析 `.hie`;不管理 `.gitignore`;不清理過期索引

### hiedb-facts

- **階段**:階段二
- **負責模組**:hiedb-facts(S5 改名 hie-facts)
- **實作的 Level 2 介面**:`Backend` 介面 hiedb 實例的執行面;模組介面 `readIndexFacts`;產出 `FactDecl` / `FactRef`;落實規則 4 與 4a
- **資料流管線段落**:從 `IndexHandle` 進,查 mods/decls/defs/refs 表,出 decl 層事實流
- **驗收標準**:跨 module 呼叫產出 `FactRef` 且 `frFromDecl` 指向正確的頂層宣告;`qnSpace` 正確區分四種 namespace;`frGenerated` 與 `refs.is_generated` 逐筆相符;deriving 字典 `fdGenerated = True`、指向它們的 ref `frTargetGenerated = True`;連續兩次執行輸出相同
- **明確不做**:**不產出 `FactInstance`**(hiedb 0.8 的 schema 沒有 instance 表,建構子保留零邏輯,`implements` 邊另開 feature);不輸出型別資訊;不判斷產生碼要不要丟棄
