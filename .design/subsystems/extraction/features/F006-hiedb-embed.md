---
id: F006
type: feature
title: hiedb-embed
description: hiedb 改 library 嵌入,依 GHC 版本目錄過濾 .hie 並增量索引
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, F004, F005, project-meta/F001]
related-adr: [ADR-006, ADR-001]
related-feature: [F003]
---

# F006: hiedb-embed — 內嵌 hiedb 的增量索引

## 功能概述

ADR-006 的第二塊落地:hiedb 從「使用者自己安裝的外部執行檔」改為 **knot 的 `build-depends`**,索引走它的 library API。使用者不必安裝 hiedb,也不需要知道它存在。模組 `Knot.Extract.HiedbDriver`(F003)整個退場,由 `Knot.Extract.HieIndex` 取代;F005 的 `HieLayout` 是它唯一的輸入。

**前提已實證**(2026-08-22 spike,`C:\Users\User\AppData\Local\Temp\kspike3`):在 GHC 9.14.1 下,`build-depends: hiedb` + `cabal.project` 的 `allow-newer: hie-compat:base, hie-compat:ghc`,**實際編譯、連結、執行成功**,`withHieDb` 建出 106 KB 的 sqlite。ADR-002 點名的編譯連動風險已承受一次,沒有爆。

**驗收標準**(契約卡逐條對照):

| # | 契約卡 | 落地 | 測試 |
|---|---|---|---|
| 1 | `build-depends` 含 hiedb、`cabal.project` 含 `allow-newer`,閘門仍 exit 0 | 兩個檔案各加幾行;閘門是 T1 的斷言本體 | T1 |
| 2 | 不再有任何 spawn `hiedb` 執行檔的路徑 | `HiedbDriver.hs` 刪除;`proc "hiedb"`、PATH 探測、命令列分批、`parseIndexStats` 全部消失 | T2 |
| 3 | 對 fixture 索引後,`mods` 列數 = `hlFiles` 筆數 | = **版本相符**的 `hlFiles` 筆數(規則 8 本次修正) | T4 |
| 4 | 同一 `HieLayout` 連跑兩次,列數不變且明顯較快 | hiedb `addRefsFrom` 以檔案雜湊判斷,第二次 `skippedCount` = 全部 | T4 |
| 5 | 別版 GHC 的 `.hie` → `VersionMismatch` 且兩個版本字串都填 | **路徑判定**:`HieLayout` 只含 `ghc-9.12.2/` 路徑 → `vmHie = "9.12.2"`、`vmKnot = 自身`;不需別版 GHC 的 fixture | T3 |
| 6 | 索引失敗(索引檔所在目錄不可寫)→ `IndexFailed` | 以「`.knot` 位置被一個同名**檔案**佔住」製造 | T5 |
| 7 | 索引需求 hiedb 的測試不再有「沒裝就跳過」的分支 | F003 的測試隨模組退場;F004 的 fixture 測試改走可建置 fixture 的完整鏈 | T7 |

## 相依性

`depends-on: [F001, F004, F005, project-meta/F001]`,全部由「使用到的既有串接介面」表反推:

- **`F005` build-driver**:`HieLayout` / `ExtractFailure` 是本 feature 的輸入與輸出型別;`ensureHie` 在過渡期的 Backend 轉接器裡被呼叫(見「實作方式 › 過渡期」)。F005 已 `done`、程式碼在分支上
- **`F004` hiedb-facts**:本 feature **動到它的程式碼**——`hiedbBackend` 的 `bProbe` / `bRun` 改接新鏈;`readIndexFacts` 的簽名不變但 `IndexHandle` 換了定義來源。F004 的 fixture 測試也要改走完整鏈
- **`F001` fact-contract**:`ExtractOptions.rootDir`(索引檔與 `srcBaseDir` 的錨點);`Backend` / `ProbeResult` 在過渡期仍要滿足
- **`project-meta/F001`**:`ProjectMeta` 是 `readIndexFacts` 的參數,轉接器要傳它

**可平行性**:**不可**與 `#7 two-layer-contract` 平行——#7 要刪掉的 `Backend` 正是本 feature過渡期的轉接點;本 feature 先落地,#7 再把轉接器連同 `Backend` 一起拆掉。與 project-meta #4、export-query #5 可平行(它們不碰 `HieIndex`)。

**不列入的相依**:`F003` hiedb-driver 列在 `related-feature` 而非 `depends-on`——本 feature 是**取代**它,不是建立在它上面;F003 的文檔保持 `done` 作為紀錄,其 1-to-1 測試隨 `HiedbDriver.hs` 一併移除。hiedb 本身是外部 library,列在介面表但「來源文檔」為 `-`。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `ensureIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure IndexHandle)` | 新簽名,一字不差;舊的 `ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)` 移除 |
| `IndexHandle`(不透明) | 重新定義於 `Knot.Extract.HieIndex`;對外只給 `ihDbPath` / `ihRootDir` / `ihStats` / `ihNotes` 四個讀取器,`ihExe` 消失 |
| DTO `ExtractFailure` 的 `VersionMismatch` / `IndexFailed` | 由本 feature 產生(型別已由 F005 定義) |
| 抽取規則 1 的 `.hie` 列舉部分 | 從 `HieLayout` 取,不再有 `pmHie` |
| 抽取規則 8(版本相容,本次修正為路徑判定) | 只索引 `ghc-<自身版本>/` 目錄下的 `.hie`;零個相符 → `VersionMismatch` |
| 抽取規則 9 的索引側 | 單一 `.hie` 讀不過 → 警告進 `ihNotes` + 跳過;索引檔整體開不了 → `IndexFailed` |
| 「使用的技術 › hiedb 作為 library 嵌入」 | `cabal.project` 加 `allow-newer`;`knot-hs.cabal` 的 `knot-internal` 加 `hiedb` |

**未觸碰**:`readIndexFacts` 的查詢邏輯(F004,只改它拿 `IndexHandle` 的來源)、`ensureHie`(F005)、`extract` 進入點與 `Backend` 的移除(#7)。

## 實作方式

### 模組

`Knot.Extract.HieIndex` 取代 `Knot.Extract.HiedbDriver`(檔案刪除,不保留殼)。`knot-internal` 的 `exposed-modules` 一進一出,總數不變(27)。

```haskell
module Knot.Extract.HieIndex
  ( -- * Level 2 模組介面
    ensureIndex
  , IndexHandle, ihDbPath, ihRootDir, ihStats, ihNotes
  , IndexStats (..)
    -- * 內部純函數(非契約面;1-to-1 測試取用)
  , ownGhcVersion          -- knot 自身的 GHC 版本字串,如 "9.14.1"
  , ghcVersionOfPath       -- .hie 路徑 → 其 ghc-<ver> 段的版本(純函數)
  , partitionByGhc         -- HieLayout → (相符, 觀察到的其他版本)
  , indexDbPath            -- <root>/.knot/hiedb.sqlite
  )
```

### 資料流

```
ExtractOptions.rootDir + HieLayout
  │
  ├─ 1. 版本過濾(規則 8,純函數):
  │      每個 hlFiles 路徑取 "ghc-<ver>" 段(cabal builddir 佈局第三段)
  │      相符 = ver == ownGhcVersion;其餘只記版本字串
  │      hlFiles 為空            → Left (IndexFailed "the build produced no .hie files")
  │      相符為空、有其他版本    → Left (VersionMismatch { vmHie = 觀察到的版本(逗號連接), vmKnot = own })
  │      相符為空、也沒版本段    → Left (IndexFailed "no .hie path carries a ghc-<version> segment")
  │
  ├─ 2. 開索引:withHieDb (<root>/.knot/hiedb.sqlite)      ← schema 由 hiedb 自建;版本不合的舊索引檔
  │      IncompatibleSchemaVersion / SQLError / IOException → Left (IndexFailed …)   自動重建不在本 feature(見「刻意的選擇」)
  │
  ├─ 3. 逐檔增量索引(每檔各自一個 runDbM,包 try):
  │      addRefsFrom db (Just rootAbs) skipOpts <絕對路徑>
  │        True  → indexedCount+1;False(雜湊未變)→ skippedCount+1
  │        例外  → 警告進 ihNotes("cannot index <path>: …"),跳過(規則 9)
  │      skipOpts = 跳過 types / typerefs / exports / imports(knot 只讀 mods / decls / defs / refs)
  │
  ├─ 4. 清理:
  │      索引裡 hieFile 不在本次相符清單者 → deleteFileFromIndex(舊版目錄、已刪 component 的殘骸)
  │      deleteMissingRealFiles(原始檔已不存在的列)
  │
  └─ 5. Right IndexHandle { ihDbPath, ihRootDir = rootDir, ihStats, ihNotes }
```

`srcBaseDir = Just rootAbs` 沿用 F003 的語意(`hs_src` 為絕對路徑,hie-facts 的 `resolveModuleSource` 以後綴比對)。多套件專案中子目錄套件的 `hie_hs_file` 相對其套件目錄、非 repo 根,`makeAbsolute (root </> …)` 會落空 → `hs_src = NULL` → `resolveModuleSource` 退回 module 名唯一比對。這是 F003 起就存在的行為,本 feature 不改(`ensureIndex` 的簽名拿不到套件目錄;要精確解得在 #7 之後另案)。

### 過渡期:`hiedbBackend` 改接新鏈

`#7 two-layer-contract` 才會拆掉 `Backend`。在那之前,為了讓現行的 `extract` 與全部 selfcheck 測試走得通,`Knot.Extract.HiedbFacts.hiedbBackend` 的兩個欄位改接:

```haskell
  , bProbe = \_ _ -> pure Available        -- 沒有執行檔可探測;版本與建置失敗走 bRun 的失敗通道
  , bRun   = \opts pm -> ensureHie opts pm >>= either throwFailure (\layout ->
               ensureIndex opts layout >>= either throwFailure (\h -> readIndexFacts h pm))
```

`throwFailure` 沿用 F004 既有的 `HiedbFactsError` 例外,由 `Knot.Extract.Backend.runOne` 轉成 `brUsed = False` + 原文——與 F004 haddock 明載的理由相同:不改成「回空事實 + 警告」,那會對外謊報函式級成功。**#7 拆 `Backend` 時這段轉接器一併消失**,不是長期結構。

這意味著從本 feature 起,`knot extract`(預設 `--backend auto`)**就會自己建置目標專案**——ADR-006 的使用者體驗在 #7 之前已經成立,差的只是旗標還在。

### 測試 fixture 策略(驗收 7 的實質內容)

F003 / F004 的 fixture 測試建立在「`test/fixtures/hiedb/.hie/` 裡預放的 `.hie` + 外部 hiedb 執行檔」之上,兩個前提都消失了:

- `HieLayout` 只認 `.knot/build/`,預放的 `.hie` 目錄不再被看到
- 沒有執行檔可「裝了才跑」,`hiedbGatedTests` 那套「沒裝就跳過並印明原因」的機制**整個移除**

改為:用 **可建置的 fixture**(F005 的 `test/fixtures/buildable/`,必要時擴充兩個 module 互相呼叫以供 F004 的跨 module 引用斷言)跑 `ensureHie → ensureIndex → readIndexFacts` 完整鏈。`test/fixtures/hiedb/` 目錄(含預放 `.hie`)刪除——它綁定 GHC 9.14.1 的二進位格式,本來就是定時炸彈。

F004 的三條 selfcheck(`test_hiedb_selfcheck`、`test_hiedb_facts_selfcheck`、G-E003 的 `test_generated_filter_selfcheck`)保留,把「缺 `.hie` 就跳過」的前置改為「直接走完整鏈」——knot 自己就是可建置專案。

### 刻意的選擇

- **版本判定用路徑不讀檔頭**:cabal 的 builddir 佈局 `build/<arch>/ghc-<ver>/…` 天然帶版本,零 IO;而且它同時解掉「GHC 升級後舊目錄殘骸」——那些檔案永遠不會再被 cabal 碰,略過就對了。讀檔頭只防「目錄名與內容不符」這種不會自然發生的情況,且 hiedb 讀到不合版本的 `.hie` 本來就會拋例外 → 走規則 9 的單檔警告,不會靜默
- **舊索引檔 schema 不合 → `IndexFailed`,不自動重建**:`withHieDb` 對 `user_version` 不合會拋 `IncompatibleSchemaVersion`(hiedb 升版、或使用者換了 hiedb 版本的 knot)。自動刪檔重建是「對方專案內的刪除動作」,即使在 `.knot/` 裡也先不擅自做;訊息指明「刪除 `.knot/hiedb.sqlite` 後重跑」。要自動化可在 CLI 層另案
- **每檔各自 `runDbM` + `try`**:`addRefsFrom` 跑在 `DbMonad`,沒有 `MonadCatch`;逐檔包 `try` 最直接,代價是每檔多一次 `ReaderT` 進出,可忽略
- **`SkipOptions` 跳四張表**:knot 只讀 `mods` / `decls` / `defs` / `refs`;`types` / `typerefs` 是索引時間的大頭(hiedb 的 PR #86 有數字),`exports` / `imports` 零消費者。`imports` 邊永遠來自 import-scan(規則 2),這裡跳過不會影響它
- **清理多餘的 `hieFile` 列**:`mods` 的 `UNIQUE (mod, unit, is_boot) ON CONFLICT REPLACE` 已經讓同 module 的新列蓋舊列,但被刪掉的 component 或舊版目錄的列會留著;逐一 `deleteFileFromIndex` 讓索引內容 = 本次相符清單,決定性更好

### 錯誤處理

| 情況 | 結果 |
|---|---|
| `HieLayout` 零檔 | `Left (IndexFailed …)`——build-driver 說建置成功卻沒產物,是異常不是版本問題 |
| 零個相符、有其他版本 | `Left (VersionMismatch { vmHie, vmKnot })`;CLI 層據 `vmHie` 印出 `cabal install knot-hs -w ghc-<vmHie>` |
| 索引檔開不了 / schema 不合 / 目錄被檔案佔住 | `Left (IndexFailed …)`,訊息含原因與(schema 不合時)修法 |
| 單一 `.hie` 讀不過或索引拋例外 | 警告進 `ihNotes`,跳過,繼續(規則 9) |
| 全部檔案都單檔失敗 | 仍 `Right`(零事實),由 #7 的規則 3 判定整體;本 feature 不越級 |

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)` | `src/Knot/Extract/BuildDriver.hs` | F005 | 過渡期轉接器的第一步 |
| `data HieLayout = HieLayout { hlRoot :: FilePath, hlFiles :: [(ComponentRef, FilePath)] }` | `src/Knot/Extract/Types.hs` | F005 | `ensureIndex` 的輸入 |
| `data ExtractFailure = BuildFailed {…} \| VersionMismatch { vmHie :: Text, vmKnot :: Text } \| IndexFailed { ifDetail :: Text } \| NoSources` | `src/Knot/Extract/Types.hs` | F005 | 本 feature 產生後兩者(含 `NoSources` 前的三者) |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | `src/Knot/Extract/Types.hs` | F001 | 只取 `rootDir`;`hiedbExe` / `dbPath` 本 feature 起**零消費者**,由 #7 刪除 |
| `data Backend = Backend { bName :: Text, bLevel :: CapabilityLevel, bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult, bRun :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning]) }` | `src/Knot/Extract/Backend.hs` | F001 | 過渡期轉接器要滿足的形狀 |
| `readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])` | `src/Knot/Extract/HiedbFacts.hs:127` | F004 | 轉接器的最後一步;`IndexHandle` 改從 `HieIndex` 取 |
| `hiedbBackend :: Backend` | `src/Knot/Extract/HiedbFacts.hs:86` | F004 | 改接 `bProbe` / `bRun` |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | `src/Knot/Meta/Types.hs` | project-meta/F001 | 轉接器傳給 `ensureHie` 與 `readIndexFacts` |
| `withHieDb :: FilePath -> (HieDb -> IO a) -> IO a` | hiedb-0.8.0.0 `HieDb/Create.hs:109` | - | 開(或建)索引檔、建 schema、檢查 `user_version` |
| `addRefsFrom :: (MonadIO m, NameCacheMonad m) => HieDb -> Maybe FilePath -> SkipOptions -> FilePath -> m Bool` | hiedb-0.8.0.0 `HieDb/Create.hs:323` | - | 逐檔增量索引;`True` = 真的索引了 |
| `data SkipOptions = SkipOptions { skipRefs, skipDecls, skipDefs, skipExports, skipImports, skipTypes, skipTypeRefs :: Bool }`、`defaultSkipOptions :: SkipOptions` | hiedb-0.8.0.0 `HieDb/Create.hs` | - | 跳過 knot 不讀的四張表 |
| `deleteFileFromIndex :: HieDb -> FilePath -> IO ()`、`deleteMissingRealFiles :: HieDb -> IO ()` | hiedb-0.8.0.0 `HieDb/Create.hs` | - | 清理步驟 |
| `runDbM :: IORef NameCache -> DbMonad a -> IO a`、`makeNc :: IO NameCache` | hiedb-0.8.0.0 `HieDb/Types.hs:347`、`HieDb/Utils.hs:94` | - | 跑 `addRefsFrom` 所需的 `NameCacheMonad` |
| `data HieDb = HieDb { getConn :: !Connection, preparedStatements :: HieDbStatements }` | hiedb-0.8.0.0 `HieDb/Types.hs:38` | - | 清理步驟要直接查 `mods` 表時取 `getConn` |
| `fullCompilerVersion :: Version` | `System.Info`(base) | - | `ownGhcVersion` 的來源(F003 既有用法) |

## 新增的介面

全部落在 `design.md` 已定義的條目內:

```haskell
-- Knot.Extract.HieIndex(模組介面,取代 Knot.Extract.HiedbDriver)
ensureIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure IndexHandle)

data IndexHandle            -- 不透明;四個讀取器
ihDbPath  :: IndexHandle -> FilePath
ihRootDir :: IndexHandle -> FilePath
ihStats   :: IndexHandle -> IndexStats
ihNotes   :: IndexHandle -> [ExtractWarning]

data IndexStats = IndexStats
  { indexedCount :: Int   -- 本次真的索引的 .hie 數
  , skippedCount :: Int   -- 雜湊未變、hiedb 判定重用的 .hie 數
  }                       -- batchCount 消失(沒有命令列分批了)
```

**移除**:`Knot.Extract.HiedbDriver` 整個模組(`probeHiedb`、`ihExe`、`defaultDbPath`、`parseIndexStats`、`chunkFileArgs`、舊 `ensureIndex`)。

**建置設定**:`knot-hs.cabal` 的 `knot-internal` 加 `hiedb`;`cabal.project` 加 `allow-newer: hie-compat:base, hie-compat:ghc`。

## TodoList

- [x] T1: `knot-hs.cabal` 加 `hiedb` 相依、`cabal.project` 加 `allow-newer`;閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` 仍 exit 0  `dep: -`
- [x] T2: 新模組 `Knot.Extract.HieIndex` 骨架取代 `HiedbDriver`(檔案刪除、cabal 一進一出);`IndexHandle` / `IndexStats` / 四個讀取器;`HiedbFacts` 改 import  `dep: T1`
- [x] T3: 版本過濾純函數 `ghcVersionOfPath` / `partitionByGhc` / `ownGhcVersion`,與 `VersionMismatch` / 零檔 `IndexFailed` 的判定  `dep: T2`
- [x] T4: `ensureIndex` 本體——`withHieDb` + 逐檔 `addRefsFrom`(`SkipOptions` 跳四表)+ 統計 + 清理(`deleteFileFromIndex` 多餘列、`deleteMissingRealFiles`)  `dep: T3`
- [x] T5: 失敗通道——索引檔開不了 / schema 不合 / 目錄被檔案佔住 → `IndexFailed`;單檔例外 → `ihNotes` 警告 + 跳過  `dep: T4`
- [x] T6: 過渡期轉接:`hiedbBackend` 的 `bProbe` 恆 `Available`、`bRun` 串 `ensureHie → ensureIndex → readIndexFacts`,失敗沿用 `HiedbFactsError`  `dep: T4`
- [x] T7: 測試搬遷——移除 F003 的測試與 `hiedbGatedTests` 跳過機制、刪 `test/fixtures/hiedb/`;F004 的 fixture 測試改走 `buildable` fixture 完整鏈(必要時擴充為兩個互相呼叫的 module);三條 selfcheck 改為直接走完整鏈  `dep: T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_hiedb_is_build_dependency` | 讀 `knot-hs.cabal` 斷言 `knot-internal` 的 `build-depends` 含 `hiedb`;讀 `cabal.project` 斷言含 `allow-newer:` 且列出 `hie-compat:base` 與 `hie-compat:ghc`。閘門本身由 impl 收尾時執行,不在測試內 |
| T2 | `test_no_hiedb_executable_path` | 斷言 `src/Knot/Extract/HiedbDriver.hs` 不存在;`src/` 全域 grep 不得出現 `proc "hiedb"`、`chunkFileArgs`、`parseIndexStats`、`findExecutable "hiedb"`;`knot-hs.cabal` 的 `exposed-modules` 含 `Knot.Extract.HieIndex`、不含 `Knot.Extract.HiedbDriver`;G-E001 的公開面守門測試維持 27 / 18 |
| T3 | `test_ghc_version_filter` | `ghcVersionOfPath ".knot/build/build/x86_64-windows/ghc-9.14.1/…/Main.hie"` = `Just "9.14.1"`,無 `ghc-` 段 → `Nothing`;`partitionByGhc` 對混合 `ghc-9.14.1/` 與 `ghc-9.12.2/` 的 `HieLayout` 只留相符者且回報 `["9.12.2"]`;`ensureIndex` 對只含 `ghc-9.12.2/` 的 layout → `Left (VersionMismatch "9.12.2" own)`;對空 layout → `Left (IndexFailed …)`。全部不需要真實 `.hie` 檔 |
| T4 | `test_ensure_index_incremental` | 對 `buildable` fixture 先 `ensureHie` 取得真實 `HieLayout`,再 `ensureIndex` → `Right`;以 sqlite-simple 開 `ihDbPath` 斷言 `mods` 列數 = 相符 `hlFiles` 筆數、`indexedCount` = 該數、`skippedCount` = 0;**再跑一次**:列數不變、`indexedCount` = 0、`skippedCount` = 全部、耗時明顯較短;`types` / `typerefs` / `exports` / `imports` 四表為空(跳表生效) |
| T5 | `test_ensure_index_failures` | 在暫存目錄把 `.knot` 建成一個**檔案**再呼叫 → `Left (IndexFailed …)` 且訊息含路徑;把一個 0 byte 的假 `.hie` 放進相符路徑 → `Right`,`ihNotes` 恰一則含該路徑的警告,其餘檔案照常索引;預先寫一個 `user_version` 錯誤的 sqlite → `Left (IndexFailed …)` 且訊息提到刪除索引檔重跑 |
| T6 | `test_hiedb_backend_adapter` | `hiedbBackend` 的 `bProbe` 恆 `Available`;對 `buildable` fixture 呼叫 `bRun` → 回含 `FactDecl` / `FactRef` 的事實;對 `broken-build` fixture 呼叫 → 拋 `HiedbFactsError` 且文字含 `BuildFailed` 的內容(由 `runBackends` 轉成 `brUsed = False`,以 `extract` 驗證) |
| T7 | `test_hiedb_facts_selfcheck`(改寫)+ F004 既有 fixture 測試(改走 `buildable`) | selfcheck 不再有 `[skip]` 分支,直接對 knot-hs 走完整鏈,decl / ref 筆數不低於 F004 閘門紀錄(decls 649、refs 7899 的量級);F004 的跨 module 引用、namespace、產生碼旗標斷言在 `buildable` fixture 上全部保留;`test/fixtures/hiedb/` 不存在;`hiedbGatedTests` / `hiedbSkipLabel` 不存在 |

## 實作備註

2026-08-22 實作完成,全部 Todo 與 1-to-1 測試落地;與設計的偏差如下:

1. **build-driver 多帶 `--project-dir=<root>`(動到 F005 的 `cabalArgs`)**。實測:fixture 沒有 `cabal.project` 時 cabal 會往上找到 knot-hs 自己的 `cabal.project`,把整個 knot-hs 建進 fixture 的 `.knot/build/`(F005 當時靠給 fixture 加 `cabal.project` 繞過)。`--project-dir` 讓 cabal 只認指定根目錄:有 `cabal.project` 就用它,沒有就以該目錄的 `.cabal` 為隱含專案。對使用者的語意是「指到哪、建哪」;monorepo 子目錄套件若依賴上層 `cabal.project` 的設定,需指向 monorepo 根。已寫進 L2 規則 5 與 F005 實作備註。
2. **過渡期的失敗文字 `renderFailure` 放在 `HiedbFacts`(私有)**,`BuildFailed` 只取 `bfDetail` 首行:cabal 的輸出已即時轉發到 stderr,尾段再進報告會讓同一輸入兩次執行的 `--summary facts` 不相等(規則 8 決定性;`test_run_extract` 的 (c) 段逐字元比對)。正式的 CLI 渲染屬 export-query #5。
3. **測試搬遷的副作用**:`extract` 在 `Auto` 下對不可建置 fixture(proj / comps / graph)會真的叫 cabal、失敗後留下一則 `hiedb` 來源的警告並在 fixture 內建出自我忽略的 `.knot/`。三條只看 import-scan 的既有測試(F001 T7、F002 T6、graph-core F001)改為 `ImportsOnly` 或改斷言為「唯一警告來自 hiedb」;其餘走 `Auto` 的測試語意不變。每次這類失敗建置約 1–4 s,整套測試 204 s(含 knot-hs 自建 19.5 s)。
4. **單檔失敗的計數**:0 byte 假 `.hie` 混入時 `addRefsFrom` 在讀檔時拋例外,該檔不計入 `indexedCount` / `skippedCount`,只進 `ihNotes`(T5 (b) 以 `IndexStats 0 n` 釘住)。
5. **驗收數字**(knot-hs 自身,`--include-tests` 關):`.hie` 32 個、decls 673、refs 8210(F004 閘門紀錄 649 / 7899,上升是因為 Demo fixture 與 BuildDriver 之後的程式碼增長);buildable fixture 3 個 `.hie`,第二次 `ensureIndex` 3.6 ms;跳表生效(`typenames` / `typerefs` / `exports` / `imports` 皆 0 列)。
