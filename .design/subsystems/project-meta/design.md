---
id: project-meta
type: subsystem
title: project-meta
description: 專案發現子系統:cabal component 解析、檔案歸類與排除判定
status: active
created: 2026-08-20
updated: 2026-08-22
parent: system
related-adr: [ADR-001, ADR-006]
code-paths: [src/Knot/Meta, src/Knot/Meta.hs]
---

# project-meta 子系統架構

## 定位與範圍

管線第一站(見 system.md「子系統劃分 › project-meta」):把一個 Haskell 專案根目錄變成結構化的「專案描述」,供 extraction 決定要讀哪些檔、要建置哪些 component,供 graph-core 決定哪些節點屬於納入範圍。

**職責**:定位並解析 `.cabal` / `cabal.project`(多套件支援)、掃描原始碼檔案樹、檔案 → component 歸類(**一對多**)、檔案路徑 → module 名對映、test/benchmark 排除判定(檔案級 `sfIncluded` 與 component 級 `compExcluded`)。

**明確不做**:不讀原始碼**內容**(module 對映靠路徑規則)、**不碰 `.hie`**(定位、列舉、幽靈過濾、版本檢查全屬 extraction)、不建圖、不觸發任何編譯。對目標專案一律唯讀。

**S5 移交給 extraction 的職責**(ADR-006):`.hie` 的定位與幽靈過濾。`.hie` 現在由 extraction 自建於 `.knot/`,而 project-meta 跑在建置之前、看不到它;由建的人自己列舉,沒有時序耦合。原 hie-locate 模組與 `pmHie` / `HieInfo` / `hieDirOverride` 一併退場(階段三 #4)。

## 對外契約(Public Interface & DTOs)

唯一進入點,呼叫者為 CLI 組裝層(結果轉交 extraction,也直接餵給 graph-core——拓撲的邊 2):

```haskell
loadProjectMeta :: MetaOptions -> IO ProjectMeta
```

```haskell
data MetaOptions = MetaOptions
  { root         :: FilePath        -- 專案根目錄
  , includeTests :: Bool            -- 納入 test-suite 與 benchmark(預設 False)
  }
  -- S5 移除:hieDirOverride(--hiedir 旗標已廢除,ADR-006)

data ProjectMeta = ProjectMeta
  { pmPackages :: [PackageMeta]   -- 多套件
  , pmSources  :: [SourceFile]    -- 全專案原始碼檔案清單
  , pmWarnings :: [MetaWarning]   -- best-effort 蒐集,由呼叫端印到 stderr
  }
  -- S5 移除:pmHie(.hie 由 extraction 自建自列,ADR-006)

data PackageMeta = PackageMeta
  { pkgName       :: Text
  , pkgCabalFile  :: FilePath          -- repo 相對路徑
  , pkgComponents :: [ComponentMeta]
  }

data ComponentMeta = ComponentMeta
  { compName       :: Text             -- 前綴比照 cabal target 語法:lib: / exe: / flib: / test: / bench:(A3)
  , compKind       :: ComponentKind
  , compSourceDirs :: [FilePath]       -- hs-source-dirs(repo 相對)
  , compExcluded   :: Bool             -- 依 kind 與 includeTests 判定;extraction 據此決定建置哪些 component
  }

data ComponentKind
  = MainLibrary | NamedLibrary | Executable
  | ForeignLibrary | TestSuite | Benchmark

data SourceFile = SourceFile
  { sfPath     :: FilePath             -- repo 相對、正斜線(下游 code-paths 比對依據)
  , sfModule   :: Maybe ModuleName     -- 路徑規則推得;推不出為 Nothing
  , sfOwners   :: [ComponentRef]       -- 一對多
  , sfIncluded :: Bool                 -- 排除判定結果
  }
```

```haskell
newtype ModuleName = ModuleName Text   -- 點分形式,如 "MagicFarmer.Render.Camera"(A1 裁決)

data MetaWarning = MetaWarning         -- (A2 裁決)
  { mwPath    :: FilePath              -- 警告來源路徑
  , mwMessage :: Text
  }
```

**S5 移除的 DTO**:`HieInfo`、`HieDirSource`(隨 `pmHie` 退場,ADR-006)。

`ComponentRef` 為 `(pkgName, compName)` 的參照。`compName` 帶 cabal target 前綴,所以 extraction 的 build-driver 能直接組出 `cabal build <pkgName>:<compName>` 這種目標——這是 S5 起 `ComponentMeta` 多出來的消費者,欄位本身沒變。

### 判定規則(契約的一部分)

1. **排除 kind**:`TestSuite`、`Benchmark` 預設 `compExcluded = True`,`includeTests = True` 時翻轉;其餘 kind 一律納入
2. **一對多歸類**:檔案落在多個 component 的 `hs-source-dirs` 時,`sfOwners` 全列;**只要任一 owner 未排除即 `sfIncluded = True`**(例:particle-magic 的 `app/Main.hs` 同屬 executable 與 test-suite → 納入)
3. **module 對映**:S2 起以「檔案路徑相對於所屬 component 的 hs-source-dirs」精確推導;S1(無 `.cabal` 解析)以**大寫路徑尾綴法**——取路徑中最長的、每段皆大寫開頭的尾綴(`src/MagicFarmer/Render/Core.hs` → `MagicFarmer.Render.Core`)。兩法對呼叫者透明,契約不變;不屬任何 component 的檔案退回大寫尾綴法(A5)
4. **S1 排除啟發式**:無 component 資訊時,頂層 `test/`、`tests/`、`bench/` 目錄下的檔案視為排除;S2 起由 component 判定取代(無 owner 的檔案仍沿用本啟發式,A5)
5. ~~**`.hie` 發現順序**~~:**S5 廢除**(ADR-006)。`.hie` 不再是輸入,沒有發現順序可言
6. ~~**幽靈判定**~~:**S5 廢除**,移交 extraction 抽取規則 9(單檔 best-effort:對映不到納入範圍內原始檔的 `.hie` 警告 + 跳過)
7. **決定性**:同樣輸入產生同樣輸出,所有清單排序穩定

編號 5、6 保留不重排,讓既有 feature 文檔與閘門紀錄的引用仍能對上。

**已知待解**(`enhancements/E001`):component 歸屬只看 `hs-source-dirs` 目錄前綴、不看 component 宣告的 module 清單,`hs-source-dirs` 取預設值 `.` 時會認領整個 repo。是規則 2、3 的精度問題,需獨立 scope 討論,不在 S5 範圍。

## 內部模組劃分(Internal Modules)

| 模組 | 單一職責 |
|---|---|
| **discovery** | 定位 `cabal.project` 與各 `.cabal` 檔;無 `cabal.project` 時找根目錄 `*.cabal` |
| **cabal-model** | 用 Cabal boot library 解析單一 `.cabal` → `PackageMeta`(conditional 以預設 flag 值攤平) |
| **source-index** | 掃描檔案樹(略過 `dist-newstyle`、`.git` 等)、component 歸類、module 對映、排除判定 → `[SourceFile]` |

**S5 移除**:hie-locate(三層 `.hie` 發現、列舉、幽靈過濾)。其職責由 extraction 的 build-driver 與 hie-index 接手。

## 資料流管線(Data Flow Pipeline)

```text
root(MetaOptions)
  → discovery:    找出 [.cabal 檔]                 (找不到 → 警告,繼續)
  → cabal-model:  每個 .cabal → PackageMeta        (解析失敗 → 警告,略過該套件)
  → source-index: 檔案樹 + [PackageMeta] → [SourceFile]
  → 組裝 ProjectMeta(含累積警告)→ 交給 extraction 與 graph-core
```

錯誤策略沿用全域 best-effort:任何一步失敗都降級為警告 + 部分結果,不中斷。(這裡的「降級」是 project-meta 單站內的 best-effort,與 ADR-006 廢除的「extraction 兩層降級」不是同一件事:專案描述少一個套件仍是可用的專案描述,事實流少一層則不是可用的圖。)

## 模組間公開介面(Module Interfaces)

```haskell
-- discovery
findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])

-- cabal-model
resolvePackage :: FilePath -> IO (Either MetaWarning PackageMeta)

-- source-index
indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])
```

**模組間相依**:三個模組彼此不相依,只由進入點依管線順序串接。(G-E001 M3 曾讓 hie-locate 共用 source-index 的大寫尾綴實作;hie-locate 退場後該相依消失,共用實作仍留在 source-index 供規則 3 使用。)

**S5 移除**:`locateHie`。

## 使用的技術

沿用主架構技術棧(GHC 9.14.1、GHC2024)。子系統特有選型:**Cabal boot library** 解析 `.cabal`——GHC 自帶、零第三方風險、`.cabal` 格式的權威實作,與 ADR-001 的取捨原則一致(沿用既有決策,不另開 ADR);檔案系統操作用 boot libs(`directory`、`filepath`)。

## 架構圖

```text
 MetaOptions(root、--include-tests)
      │
      ▼
 ┌─ project-meta ─────────────────────────────────────┐
 │  discovery ──[.cabal 檔]──▶ cabal-model            │
 │      │                        │ [PackageMeta]       │
 │      │   ┌────────────────────┘                     │
 │      ▼   ▼                                          │
 │  source-index                                       │
 │      │ [SourceFile]                                 │
 │      ▼                                              │
 │  ProjectMeta(packages + sources + warnings)        │
 └──────────────────┬─────────────────────────────────┘
                    ▼
      extraction(邊 1)與 graph-core(邊 2)
```

## 開發階段

對應主架構 S1(路徑掃描部分)、S2(`.cabal` 整合)與 **S5**(hie-locate 退場)。S3 原本消費 `pmHie` 的 hiedb 後端已由 extraction 的 S5 重構取代。

## 功能規劃

### 階段一:S1 骨架(已完成)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 1 | scan-baseline | ProjectMeta DTO、檔案樹掃描、大寫尾綴 module 對映、路徑啟發式排除 | discovery、source-index | - | F001 |

### 階段二:S2 .cabal 整合(已完成)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 2 | cabal-components | Cabal boot lib 解析多套件多 component、一對多歸類、component 排除、精確 module 對映 | discovery、cabal-model、source-index | #1 | F002 |
| 3 | hie-discovery | 三層 .hie 發現策略、.hie 清單、幽靈檔過濾(**S5 退場**,由 #4 移除) | hie-locate | #1 | F003 |

### 階段三:S5 零前置重構(ADR-006)

| # | feature | 一句話說明 | 模組 | 依賴 | doc |
|---|---------|-----------|------|------|-----|
| 4 | hie-retire | 移除 hie-locate 模組、`pmHie` / `HieInfo` / `HieDirSource` / `hieDirOverride`,F003 改 closed | (移除 hie-locate) | - | - |

(共 4 個 features、3 個階段。**#4 的跨子系統順序約束**:必須在 extraction 的 two-layer-contract 與 export-query 的 CLI 旗標移除**之後或同一批**落地——那兩邊是 `pmHie` / `hieDirOverride` 僅存的消費端,先刪定義會讓它們編不過。「依賴」欄填 `-` 是因為對方的 feature 文檔尚未建檔、沒有 id 可引;建檔後回填)

## Feature 契約卡

### scan-baseline

- **階段**:階段一
- **負責模組**:discovery、source-index
- **實作的 Level 2 介面**:`loadProjectMeta` 進入點;DTO `MetaOptions`、`ProjectMeta`、`SourceFile`、`MetaWarning`(首次定義,`pmPackages` 恆為空、`sfOwners` 恆為空、`pmHie` 恆為 Nothing——後者已於 S5 移除);模組介面 `findCabalFiles`(本階段僅定位、不解析)、`indexSources`(判定規則 3 的大寫尾綴法、規則 4 的路徑啟發式、規則 7 的決定性)
- **資料流管線段落**:從 `MetaOptions` 進,經 discovery → source-index,出 `ProjectMeta`(僅 `pmSources` 與 `pmWarnings` 填實)
- **驗收標準**:對 particle-magic 與 MagicFarmer(皆唯讀)執行——列出全部 `.hs` 且 `dist-newstyle`、`.git` 內容不出現;`src/MagicFarmer/Render/Camera.hs` 對映 `MagicFarmer.Render.Camera`(以驗收標的實存檔案為準);`test/`、`bench/` 檔案 `sfIncluded = False` 且 `includeTests = True` 可翻轉;連續執行兩次輸出完全相同
- **明確不做**:不解析 `.cabal` 內容(cabal-components 的事);不碰 `.hie`;不讀任何檔案內容;不處理多套件語意(僅回報找到的 `.cabal` 路徑)

### cabal-components

- **階段**:階段二
- **負責模組**:discovery、cabal-model、source-index
- **實作的 Level 2 介面**:模組介面 `resolvePackage`;DTO `PackageMeta`、`ComponentMeta`、`ComponentKind`、`ComponentRef`;強化 `indexSources` 落實判定規則 1(kind 排除)、規則 2(一對多歸類與納入判定)、規則 3 的精確 module 對映(取代大寫尾綴法);`findCabalFiles` 支援 `cabal.project` 的多套件列表
- **資料流管線段落**:從 discovery 的 `.cabal` 清單進,經 cabal-model → source-index,出 owners/included/module 填實的 `[SourceFile]` 與 `pmPackages`
- **驗收標準**:對 particle-magic(唯讀)執行——列出 9 個 component(named library 2、executable 4、foreign-library 1、test-suite 1、benchmark 1);`app/` 下檔案 `sfOwners` 含 executable 與 test-suite(A9:實際亦含 benchmark,共三個 owner)且 `sfIncluded = True`;僅屬 test-suite 的 `test/` 檔案 `sfIncluded = False`;多套件 `cabal.project` 能列出多個 `PackageMeta`(以臨時 fixture 專案驗證,不得改動驗收標的專案)
- **明確不做**:不做非預設 flag 組合的 conditional 求值(以預設 flag 攤平);不解析 build-depends 依賴圖;不讀 `.hie`;不掃 `dist-newstyle` 內的原始碼

### hie-discovery

**S5 退場**(ADR-006)。以下為 F003 完成時的契約卡,所引用的 `locateHie` / `HieInfo` / `HieDirSource` 與判定規則 5、6 已廢除,僅供回溯;程式碼由 #4 移除,F003 文檔屆時改 `closed`。

- **階段**:階段二
- **負責模組**:hie-locate
- **實作的 Level 2 介面**:模組介面 `locateHie`;DTO `HieInfo`、`HieDirSource`;落實判定規則 5(三層發現順序)與規則 6(幽靈判定)
- **資料流管線段落**:從 source-index 的 `[SourceFile]` 與 `MetaOptions` 進,出 `Maybe HieInfo`(含幽靈清單與警告)
- **驗收標準**:三層 fallback 各自可觀察(`hieSource` 正確標記採用層);`--hiedir` 指向不存在目錄時回 `Nothing` 加警告而不失敗;以 fixture 專案驗證——刪除一個原始檔後,其 `.hie` 出現在 `hieGhosts` 且附警告、不進 `hieFiles`
- **明確不做**:不讀 `.hie` 檔內容;不觸發編譯產生 `.hie`;不驗證 `.hie` 與原始碼的新舊

### hie-retire

- **階段**:階段三
- **負責模組**:hie-locate(整個模組移除)與對外契約的 DTO 層
- **實作的 Level 2 介面**:**移除** `locateHie`、`HieInfo`、`HieDirSource`、`MetaOptions.hieDirOverride`、`ProjectMeta.pmHie`;`loadProjectMeta` 簽名不變;判定規則 5、6 廢除。無新增
- **資料流管線段落**:管線縮短為 discovery → cabal-model → source-index → 組裝 `ProjectMeta`;不再有 hie-locate 一站
- **驗收標準**:`src/Knot/Meta/HieLocate.hs` 不存在;`Knot.Meta.Types` 的匯出清單不含 `HieInfo` / `HieDirSource`;`MetaOptions` 恰兩個欄位、`ProjectMeta` 恰三個欄位;F003 的 1-to-1 測試**移除**(不是跳過)而 F001 / F002 的測試全綠;`src/` 與 `app/` 整體編譯通過(公開 library 只 re-export 契約模組,任何殘留引用都是編譯錯誤);五份黃金檔(G-E001)的 `codegraph.json` byte 不變;`--summary meta` 不再印 `.hie` 資訊;**閘門** `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0;F003 文檔 `status` 改 `closed`。**順序約束**:本 feature 開工前,extraction 的 two-layer-contract 與 export-query 的 CLI 旗標移除必須已落地或同批提交——驗收標準「整體編譯通過」在那之前不可能成立
- **明確不做**:不動 discovery / cabal-model / source-index 的任何判定規則(E001 的歸屬精度另案);不替 extraction 清它那邊的 `pmHie` 消費端(extraction 階段三的事);不動 CLI 旗標解析(export-query 的事);不保留任何「相容舊 `.hie` 輸入」的路徑
