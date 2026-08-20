---
id: F001
type: feature
title: fact-contract
description: 抽取契約 DTO、後端抽象與 auto 探測降級合成
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: [project-meta/F001]
related-adr: [ADR-002]
related-feature: []
---

# F001: fact-contract — 抽取契約與後端調度骨架

## 功能概述

extraction 子系統的第一個 feature:把 Level 2「對外契約」「事實流 DTO」「模組間公開介面」原樣落成 Haskell 型別(`Knot.Extract.*` 的第一批 module),並實作 backend-select 模組的**調度引擎**——依 `BackendChoice` 選後端、探測、best-effort 執行、合成事實流與能力等級,產出 `ExtractResult`。

**要解決的問題**:兩個後端(import-scan / hiedb)要實現「同一抽取契約」才談得上 auto 並用與降級(ADR-002 的核心決策);契約與調度必須先存在,後端才有東西可實現。本 feature 只建骨架與調度,**本階段註冊表為空**(import-scan 由 `F002` 註冊、hiedb 由階段二註冊),因此對真實專案執行的產出為空事實流——這是預期行為,不是缺陷。

**驗收標準**(契約卡原文,全部以假後端測試替身驗證):

1. auto 模式下探測失敗的後端出現在 `erReports` 且附原因
2. `erLevel` 正確反映實際跑起來的後端(而非註冊的後端)
3. `HiedbOnly` 但後端不可用時回空事實 + 報告,不 crash
4. 事實流排序穩定:同輸入連續兩次執行結果完全相同

**明確不做**(契約卡底線):不實作任何真後端(import-scan 屬 `F002`、hiedb 屬 `F003`/`F004`);不解析任何檔案、不讀 `.hie`、不碰 SQLite;不定義 CLI 參數解析(屬 CLI 組裝層);不決定節點 id、不組圖(graph-core 的職責)。

## 相依性

`depends-on: [project-meta/F001]`——唯一相依來自介面表:事實流 DTO 依委派決策 D2 直接 import `Knot.Meta.Types` 的 `ModuleName`,`extract` 的第二參數是 `ProjectMeta`、規則 1 讀 `SourceFile.sfIncluded`,這三個型別的定義出自 `project-meta/F001`(已實作,簽名見介面表,2026-08-20 自 `src/Knot/Meta/Types.hs` 讀出原文)。

未列入的相依與理由:

- `project-meta/F002`(cabal-components)、`project-meta/F003`(hie-discovery)只改變 `sfIncluded`、`pmHie` 的**填值語意**,不改型別定義,本 feature 依欄位型別使用、對填值來源不可知,故不構成相依
- 本 feature **不**相依 `F002`(import-scan):方向相反——`F002` 相依本檔的 `Backend` 介面
- 測試框架(tasty / tasty-hunit / tasty-hedgehog / hedgehog)已在 `knot-hs.cabal` 的 `knot-test` component 中就緒(D4),非新增相依

可平行性:與 graph-core、export-query 的未來任務可平行(尚無交集);本子系統內 `F002` 必須排在本檔實作之後(序列依賴,排程已定為 F001 → F002)。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| 對外契約 `extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult` | 完整實作進入點;階段一語意:後端註冊表為空 → 回空事實 + 空報告 + `ModuleLevel` |
| DTO `ExtractOptions`、`BackendChoice`、`ExtractResult`、`CapabilityLevel` | 首次定義,欄位與 design.md「對外契約」原文一致 |
| 事實流 DTO `Fact`(五個建構子全部)、`QualName`、`NameSpace`、`DeclKind`、`BackendReport`、`ExtractWarning` | 首次定義,原文一致;`ExtractWarning` 依 D1 為 `{ ewSource, ewMessage }` |
| `ModuleName` 共用 project-meta 契約 | 依 D2 直接 `import Knot.Meta.Types (ModuleName (..))`,不重複定義 |
| 模組介面 `Backend`(`bName` / `bLevel` / `bProbe` / `bRun`)、`ProbeResult` | 首次定義,原文一致;本階段無實例(測試以假後端填充) |
| 抽取規則 1(納入範圍) | backend-select 在調度前把 `pmSources` 窄化為 `sfIncluded = True` 的子集(假設 A1) |
| 抽取規則 3(auto 合成與降級) | `Auto` 跑全部探測通過的後端;`ImportsOnly` / `HiedbOnly` 只跑指定後端;不可用者記入 `BackendReport` 並使 `erLevel` 降級 |
| 抽取規則 7(best-effort) | 探測與執行全程包例外;單一後端失敗 → 報告 + 警告 + 續跑其他後端,絕不中斷 |
| 抽取規則 8(決定性) | 合成後事實流以全序排序;報告、警告依固定的註冊序 |
| 資料流管線段落 | `ProjectMeta + ExtractOptions` → 探測 → 調度 → 合成 → `ExtractResult` |
| 規則 2、4、5、6 | **不觸碰**(屬 `F002` / `F003` / `F004`) |

超出 Level 2 的公開面只有一項:調度引擎 `runBackends` 需為假後端測試而匯出,以 haddock 註明非契約面(假設 A6)。

## 實作方式

### 模組配置

```text
src/Knot/Extract.hs           -- extract 進入點 + 後端註冊表(階段一為空)
src/Knot/Extract/Types.hs     -- 全部 DTO(對外契約 + 事實流)
src/Knot/Extract/Backend.hs   -- Backend / ProbeResult / 調度引擎 runBackends
```

`knot-hs.cabal`:上述三個 module 加入 library 的 `exposed-modules`;`build-depends` **不變**(只用到既有的 `base`、`text`),`version: 0.0.1.0` 依 D4 凍結不動。測試加在既有 `knot-test`(D4),test group 命名 `extraction/F001 fact-contract` 以與 project-meta 的 `F001 scan-baseline` group 區隔(同一 test-suite 內兩個子系統各有 F001)。

`Fact` 的多建構子共用一個型別、各自帶不同欄位名(design.md 原文已刻意避開欄位名衝突),`-Wall` 若對 partial record selector 告警,由實作以區域 pragma 或改用 pattern match 處理——屬 Level 3 自主權。

### 資料流(階段一管線)

```text
ExtractOptions + ProjectMeta
  → 窄化:     pmSources 濾為 sfIncluded = True(規則 1;pmPackages / pmHie / pmWarnings 原樣保留)
  → 選擇:     backendChoice → 選中清單
                 · Auto        → 全部註冊後端
                 · ImportsOnly → bName == "import-scan"
                 · HiedbOnly   → bName == "hiedb"
                 · 未選中者 → BackendReport{ brUsed = False, brDetail = 未選中原因 }
  → 探測:     對選中者依序 bProbe(包例外)
                 · Available     → 進啟用清單
                 · Unavailable r → BackendReport{ brUsed = False, brDetail = r }(規則 3 降級)
                 · 探測抛例外    → 視同 Unavailable,原因為例外文字(規則 7)
  → 執行:     對啟用清單依註冊序 bRun(包例外、強制求值 list spine)
                 · 成功 → facts / warnings 進池,BackendReport{ brUsed = True }
                 · 失敗 → BackendReport{ brUsed = False, brDetail = 例外文字 }
                          + ExtractWarning{ ewSource = bName, ewMessage = 例外文字 },其他後端照跑
  → 合成:     erFacts    = 全序排序(concat 各後端 facts)          (規則 8)
                erWarnings = 依註冊序串接(後端內部序原樣保留)
                erReports  = 依註冊序,每個註冊後端剛好一筆
                erLevel    = 成功執行者的 bLevel 最大值;無人成功 → ModuleLevel(假設 A4)
  → ExtractResult
```

### 決定性(規則 8)

- `Fact` 與其成員 DTO(`QualName`、`NameSpace`、`DeclKind`)一律 derive `Ord`(`ModuleName` 既有 `Ord`),合成後對事實流做全序排序(建構子序 → 欄位序);後端自身產出序不影響最終結果(假設 A3)
- `CapabilityLevel` derive `Ord`,建構子序 `ModuleLevel < DeclLevel`,`erLevel` 取最大值即「實際達到的能力等級」
- 報告與警告的順序由**註冊表順序**決定(靜態常數),不受探測結果影響
- 不做事實去重:規則 2 已保證兩後端職責互斥,不會產生重複事實;去重與衝突解決不在本子系統職責內

### 錯誤處理(規則 7)

| 情境 | 行為 |
|---|---|
| 後端未被 `backendChoice` 選中 | `brUsed = False`,`brDetail` 指明未選中(非錯誤,不產警告) |
| `bProbe` 回 `Unavailable r` | `brUsed = False`,`brDetail = r`;其他後端照跑;`erLevel` 隨實際跑成功者降級 |
| `bProbe` 抛例外 | 同上,`brDetail` 為例外文字;不 crash |
| `bRun` 抛例外(含惰性求值時才引爆者) | 該後端 facts 全數丟棄 + `brUsed = False` + 一則 `ExtractWarning`;其他後端的事實保留 |
| 選中的唯一後端不可用(`HiedbOnly` 情境) | `erFacts = []`、`erLevel = ModuleLevel`、`erReports` 含原因;正常回傳,不 crash |
| 後端自己回報的 `[ExtractWarning]` | 原樣併入 `erWarnings`,不改寫、不過濾 |

`bRun` 的回傳值以 `Control.Exception.evaluate` 強制 list spine 後才進池,確保惰性錯誤在 `try` 的作用域內引爆(實作細節,不影響契約)。

### 測試替身策略

假後端以純建構的 `Backend` 值提供(不需檔案 IO):可組出「探測通過 + 固定事實」「探測失敗 + 指定原因」「探測通過但 `bRun` 抛例外」三種行為,`bLevel` 可指定為 `ModuleLevel` 或 `DeclLevel`,`bName` 可指定為契約字串以驗證 `BackendChoice` 選擇。輸入 `ProjectMeta` 由手工建構(或以既有 fixture 經 `loadProjectMeta` 取得,驗證窄化)。驗收標的專案(MagicFarmer、particle-magic)在本 feature **不參與測試**(無真後端可跑,D4 唯讀原則亦不需觸碰)。

## 使用到的既有串接介面

(簽名皆為 2026-08-20 自來源檔案讀出的原文;base 簽名以 `ghc -e ':t …'`(GHC 9.14.1)實測)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | src/Knot/Meta/Types.hs:29-35 | project-meta/F001 | `extract` 的第二參數;本 feature 只讀寫 `pmSources`(窄化),其餘欄位原樣傳給後端 |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs:65-71 | project-meta/F001 | 規則 1 納入範圍:依 `sfIncluded` 過濾 |
| `newtype ModuleName = ModuleName Text` `deriving (Eq, Ord, Show)` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | D2:`QualName` / `FactModule` / `FactImport` 直接共用,不重複定義;既有 `Ord` 直接支撐規則 8 排序 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs:22-26 | project-meta/F001 | 僅測試路徑:組出真實 `ProjectMeta` 輸入 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 僅測試路徑:以既有 fixture 產生真實 `ProjectMeta` 驗證窄化 |
| `Control.Exception.try :: Exception e => IO a -> IO (Either e a)` | base-4.22(GHC 9.14.1) | - | 規則 7:包住 `bProbe` / `bRun`,以 `SomeException` 具現 |
| `Control.Exception.evaluate :: a -> IO a` | base-4.22(GHC 9.14.1) | - | 強制 `bRun` 回傳 list 的 spine,讓惰性例外落在 `try` 作用域內 |
| `Control.Exception.displayException :: Exception e => e -> String` | base-4.22(GHC 9.14.1) | - | 例外轉 `brDetail` / `ewMessage` 文字 |
| `Data.List.sort :: Ord a => [a] -> [a]` | base-4.22(GHC 9.14.1) | - | 規則 8:合成後事實流全序排序 |
| `Data.Text.pack :: String -> Text` | text(GHC 9.14.1 boot) | - | `String` 例外訊息轉 `Text` 欄位 |

`SomeException` 於 GHC 9.14.1 定義於 `GHC.Internal.Exception.Type`(`Control.Exception` 重匯出),為存在型別包裝(`forall e. (Exception e, HasExceptionContext) => SomeException e`),已實測確認。

## 新增的介面

全部落在 Level 2 契約內(型別定義原文出自 design.md「對外契約」「事實流 DTO」「模組間公開介面」),唯一例外標註於末。

**`Knot.Extract`(對外契約進入點)**

```haskell
extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult
-- 階段一語意:後端註冊表為空 → erFacts = []、erReports = []、erWarnings = []、erLevel = ModuleLevel
-- F002 起註冊 import-scan,階段二註冊 hiedb;extract 本身的行為不隨之改變
```

註冊表本身(`[Backend]` 常數)不匯出,屬 backend-select 內部狀態。

**`Knot.Extract.Types`(DTO)**

```haskell
data ExtractOptions = ExtractOptions
  { backendChoice :: BackendChoice
  , hiedbExe      :: Maybe FilePath
  , dbPath        :: Maybe FilePath
  }

data BackendChoice = Auto | ImportsOnly | HiedbOnly

data ExtractResult = ExtractResult
  { erFacts    :: [Fact]
  , erLevel    :: CapabilityLevel
  , erReports  :: [BackendReport]
  , erWarnings :: [ExtractWarning]
  }

data CapabilityLevel = ModuleLevel | DeclLevel      -- Ord:ModuleLevel < DeclLevel

data QualName = QualName
  { qnModule :: ModuleName                          -- 共用 Knot.Meta.Types(D2)
  , qnOcc    :: Text
  , qnSpace  :: NameSpace
  }

data NameSpace = ValueNs | TypeNs

data Fact
  = FactModule   { fmFile :: FilePath, fmModule :: ModuleName }
  | FactImport   { fiFrom :: ModuleName, fiTo :: ModuleName
                 , fiFile :: FilePath, fiLine :: Int }
  | FactDecl     { fdName :: QualName, fdKind :: DeclKind
                 , fdFile :: FilePath, fdLine :: Int }
  | FactRef      { frFromModule :: ModuleName, frFromDecl :: Maybe QualName
                 , frTarget :: QualName, frFile :: FilePath, frLine :: Int }
  | FactInstance { fiClass :: QualName, fiInstHead :: Text
                 , fiInstFile :: FilePath, fiInstLine :: Int }

data DeclKind
  = ValueDecl | DataDecl | ClassDecl | InstanceDecl
  | TypeSynDecl | PatSynDecl | FamilyDecl

data BackendReport = BackendReport
  { brBackend :: Text, brUsed :: Bool, brDetail :: Text }

data ExtractWarning = ExtractWarning                -- D1
  { ewSource :: Text, ewMessage :: Text }
```

deriving:全部 `Eq`、`Show`;`Fact`、`QualName`、`NameSpace`、`DeclKind`、`CapabilityLevel` 另加 `Ord`(規則 8 的排序基礎,假設 A3)。

**`Knot.Extract.Backend`(Level 2 模組間公開介面)**

```haskell
data Backend = Backend
  { bName  :: Text
  , bLevel :: CapabilityLevel
  , bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult
  , bRun   :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
  }

data ProbeResult = Available | Unavailable Text

-- 後端名常數:值域即 design.md 的 brBackend 值域,供 BackendChoice 比對與後端自我命名
importScanName :: Text     -- "import-scan"
hiedbName      :: Text     -- "hiedb"
```

**非契約面的測試用匯出**(比照 project-meta 既有慣例,haddock 註明)

```haskell
-- | 調度引擎;僅為 1-to-1 測試(假後端)而匯出,非 Level 2 契約面。
runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult
```

`extract opts pm = runBackends registeredBackends opts pm`。

## TodoList

- [ ] T1: `Knot.Extract.Types` 全部 DTO 定義(含 deriving 與 `ModuleName` 共用),`knot-hs.cabal` 加 `exposed-modules`,`cabal build all` 通過  `dep: project-meta/F001`
- [ ] T2: `Knot.Extract.Backend` 的 `Backend`、`ProbeResult`、後端名常數定義  `dep: T1`
- [ ] T3: 納入範圍窄化(規則 1):`pmSources` 濾為 `sfIncluded = True`,其餘欄位原樣  `dep: T1`
- [ ] T4: 選擇與探測(規則 3):`BackendChoice` → 選中清單 → `bProbe` → 啟用清單 + 未選中/不可用的 `BackendReport`  `dep: T2, T3`
- [ ] T5: best-effort 執行(規則 7):`bRun` 包例外 + 強制求值,失敗轉報告 + 警告且不中斷其他後端  `dep: T4`
- [ ] T6: 合成(規則 8):事實流全序排序、警告/報告固定序、`erLevel` 取實際成功後端的最大能力等級  `dep: T5`
- [ ] T7: `Knot.Extract.extract` 進入點與空註冊表(階段一語意寫入 haddock)  `dep: T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_extract_types_construct | HUnit 建構每個 DTO(`Fact` 五個建構子全部)並驗證欄位取值;`QualName` 的 `qnModule` 確為 `Knot.Meta.Types.ModuleName`(以該型別的值直接建構即證明共用) |
| T2 | test_backend_iface_construct | 建構假後端值並分別呼叫 `bProbe` / `bRun`,驗證回傳 `Available` / `Unavailable r` 與 `([Fact], [ExtractWarning])` 的形狀;後端名常數等於契約字串 `"import-scan"` / `"hiedb"` |
| T3 | test_included_scope | 對既有 fixture 以 `loadProjectMeta` 取得含排除檔的 `ProjectMeta`,經假後端捕獲實際收到的 `pmSources`:只含 `sfIncluded = True` 的檔,`pmHie` / `pmPackages` 原樣未動 |
| T4 | test_probe_and_select | (a) auto + 一個探測失敗的假後端 → 該後端在 `erReports` 中 `brUsed = False` 且 `brDetail` 為指定原因,另一後端照跑;(b) `HiedbOnly` + 不可用 hiedb 假後端 → `erFacts = []`、`erLevel = ModuleLevel`、報告有原因、不 crash;(c) `ImportsOnly` → hiedb 假後端不被呼叫且以「未選中」列入報告 |
| T5 | test_best_effort_run | 假後端的 `bRun` 抛例外 → 不 crash:該後端 `brUsed = False` 且 `brDetail` 含例外文字、`erWarnings` 有一則 `ewSource = 後端名` 的警告、另一個正常後端的事實完整保留;後端自報的警告原樣出現在 `erWarnings` |
| T6 | test_fact_synthesis | 兩個假後端(一 `ModuleLevel`、一 `DeclLevel`)各回一組刻意亂序的事實 → `erFacts` 為全序排序結果、連續兩次執行完全相等;`erLevel = DeclLevel`;只有 `ModuleLevel` 成功時 `erLevel = ModuleLevel`;hedgehog property:任意事實清單經任意打亂後合成結果不變 |
| T7 | test_extract_entry_empty_registry | 對 fixture 專案呼叫 `extract`(三種 `BackendChoice` 各一次)→ 皆回 `erFacts = []`、`erReports = []`、`erWarnings = []`、`erLevel = ModuleLevel`,不抛例外 |

## 待確認假設

- A1: 規則 1「只處理 `sfIncluded = True`」由誰落實?契約卡指派給本 feature,但 `Backend.bRun` 收的是完整 `ProjectMeta` → 採取:backend-select 在調度前窄化 `pmSources`,後端只看得到 included 檔(單點強制,`Backend` 簽名不變)→ 影響:若裁定各後端自行過濾,移除窄化並把過濾寫進 `F002` / `F004` 實作
- A2: `BackendChoice` 如何對應到具體後端?契約未定辨識方式 → 採取:以 `bName` 比對契約字串常數(`"import-scan"` / `"hiedb"`,取自 design.md `brBackend` 的值域)→ 影響:若改以 `bLevel` 判定,只改選擇函數一處
- A3: 規則 8「排序穩定」的手段未指定 → 採取:為 `Fact` 及其成員 DTO derive `Ord`,合成後對整條事實流做全序排序(不依賴後端產出序)→ 影響:若裁定必須保留後端產出序(只要求各後端自身決定性),改為不排序、僅固定後端串接序;deriving 清單同步縮減
- A4: 「無任何後端成功執行」時 `erLevel` 取值未定義(`CapabilityLevel` 只有兩個值)→ 採取:回 `ModuleLevel`(能力下限),由 `erReports` 表達「其實什麼都沒跑」→ 影響:若需要第三個「無能力」等級,屬 Level 2 契約變更
- A5: 未被 `backendChoice` 選中的後端是否進 `erReports`?契約說「各後端:用了/沒用 + 原因」→ 採取:進,`brUsed = False` 且原因為「未被 backendChoice 選中」→ 影響:若只報探測過的後端,改組裝一處
- A6: 調度引擎 `runBackends` 需被假後端測試直接呼叫,但它不在 Level 2 模組間介面清單內 → 採取:比照 project-meta 既有慣例(`moduleNameFromPath`)以 haddock 註明「非契約面」匯出 → 影響:E001 型的內部匯出收斂機制落地時,一併搬遷
- A7: 本階段註冊表為空,`extract` 對真實專案回空事實流 → 採取:視為階段一預期語意並寫入 haddock 與測試(T7),不臨時塞任何真後端 → 影響:無(F002 註冊 import-scan 後自然填實)

## 實作備註

(撰寫時留空)
