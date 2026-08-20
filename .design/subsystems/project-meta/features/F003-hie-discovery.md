---
id: F003
type: feature
title: hie-discovery
description: 三層 .hie 目錄發現、檔案列舉與幽靈 .hie 過濾
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: [F001]
related-adr: [ADR-001, ADR-002]
related-feature: []
---

# F003: hie-discovery — 三層 .hie 發現與幽靈過濾

## 功能概述

project-meta 子系統階段二的 hie-locate 模組:實作 Level 2 模組介面 `locateHie`,把「`.hie` 目錄在哪、裡面有哪些檔、哪些是幽靈」變成結構化的 `Maybe HieInfo`,供 S3 的 extraction(hiedb 後端,ADR-002)消費 `pmHie`。本 feature 不讀 `.hie` 檔內容——`.hie` 的 GHC 版本檢查屬 extraction(ADR-001),這裡只看路徑。

**要解決的問題**:hiedb 後端需要知道 `.hie` 目錄位置與有效檔案清單才能建索引;而目標專案的 `.hie` 可能由 `--hiedir` 指定、放在慣例位置 `<root>/.hie`、或散在 `dist-newstyle` 內(cabal 的 `extra-compilation-artifacts`)。另外,原始檔刪除後殘留的舊 `.hie` 會讓下游產出幽靈節點,必須在此站過濾。

**驗收標準**(契約卡原文;fixture 建在 knot-hs 自己的 `test/fixtures/`,委派決策 D5):

1. 三層 fallback 各自可觀察:`hieSource` 正確標記採用層(`FromFlag` / `FromConvention` / `FromDistNewstyle`)
2. `--hiedir` 指向不存在目錄時回 `Nothing` 加警告而不失敗
3. 以 fixture 專案驗證——刪除一個原始檔後(fixture 以「`.hie` 存在、原始檔不存在」模擬),其 `.hie` 出現在 `hieGhosts` 且附警告、不進 `hieFiles`

**明確不做**(契約卡底線):不讀 `.hie` 檔內容(GHC 版本檢查屬 extraction)、不觸發編譯產生 `.hie`、不驗證 `.hie` 與原始碼的新舊(mtime 比對不在本 feature)。對目標專案一律唯讀。

## 相依性

`depends-on: [F001]`——本 feature 消費 F001 建立的骨架與介面:DTO `HieInfo`、`HieDirSource`(F001 先行定義、零邏輯,本 feature 賦予語意)、`MetaOptions`、`SourceFile`、`ModuleName`、`MetaWarning`(`src/Knot/Meta/Types.hs`),以及 T7 接線標的 `loadProjectMeta`(`src/Knot/Meta.hs`)。介面表中其餘皆 GHC 9.14.1 boot libraries,簽名已於 2026-08-20 以 `ghc -e ':t …'` 實測查證。

**與 F002(cabal-components)的關係**:不依賴其任何介面——`locateHie` 只吃 F001 已定義的 `[SourceFile]` 與 `MetaOptions`,故 F002 不入 `depends-on`,兩份設計可平行。但 T7(`loadProjectMeta` 接線)與 F002 改的是同一個檔案(`src/Knot/Meta.hs`),依編排者的階段內序列實作,後做的一方在當時最新版上整合(見假設 A8)。F002 完成後 `sfModule` 由大寫尾綴法升級為精確對映,幽靈判定的比對品質隨之提升,契約與本文檔均不需改動。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/project-meta/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `locateHie :: MetaOptions -> [SourceFile] -> IO (Maybe HieInfo, [MetaWarning])` | 完整實作(design.md「模組間公開介面 › hie-locate」原文簽名) |
| DTO `HieInfo`(`hieDir`、`hieSource`、`hieFiles`、`hieGhosts`)、`HieDirSource` | F001 已照 design.md 原文先行定義;本 feature 賦予語意,欄位零改動 |
| 判定規則 5(三層發現順序) | `hieDirOverride` > `<root>/.hie` > 遞迴掃 `dist-newstyle`;採用層記錄在 `hieSource` |
| 判定規則 6(幽靈判定) | `.hie` 相對路徑對映的 module 在 `pmSources` 中無對應原始檔 → `hieGhosts` + 警告,不進 `hieFiles`(不交給下游) |
| 判定規則 7(決定性) | `hieFiles`、`hieGhosts` 穩定排序;警告順序固定;同輸入同輸出 |
| 資料流管線段落 | source-index 的 `[SourceFile]` + `MetaOptions` 進,`Maybe HieInfo`(含幽靈清單與警告)出 |
| 錯誤策略(best-effort) | `--hiedir` 不存在 → `Nothing` + 警告不失敗;讀不到的子目錄降級為警告 + 跳過 |
| 明確不做 | 不讀 `.hie` 內容、不觸發編譯、不比 mtime、對目標專案唯讀 |

未新增任何超出 Level 2 的公開介面;module 命名依委派決策 D3 的自主權定為 `Knot.Meta.HieLocate`。

## 實作方式

### 三層發現(判定規則 5)

```text
locateHie opts sources
  第 1 層 FromFlag:hieDirOverride = Just d
    · d 為絕對路徑直接用;相對路徑以 root 為基準解讀(假設 A5)
    · doesDirectoryExist 成立 → 採用,hieSource = FromFlag
    · 不成立 → (Nothing, [MetaWarning d "hie directory not found"]),不 fallback
      (使用者明示的位置錯了就明說,不悄悄改道;驗收標準 2)
  第 2 層 FromConvention:無 override 時檢查 <root>/.hie
    · doesDirectoryExist 成立 → 採用,hieSource = FromConvention
  第 3 層 FromDistNewstyle:遞迴走訪 <root>/dist-newstyle 收集 *.hie
    · 找到 ≥1 個 → 採用,hieSource = FromDistNewstyle,
      hieDir = 全部 .hie 檔的最深共同祖先目錄(repo 相對;假設 A4)
    · dist-newstyle 不存在或其中無 .hie → 未命中
  三層皆未命中 → (Nothing, [])(無 .hie 是常態,不出警告;假設 A3)
```

- 第 1、2 層採用後列舉目錄內 `.hie`;列舉結果為空 → 仍回 `Just HieInfo`(`hieFiles = []`)+ 警告,不往下層 fallback(採用即成立;假設 A1)
- `hieDir` 與 `hieFiles` 皆 repo 相對、正斜線;override 落在 root 外時以 `makeRelative` 化簡,化簡不了則保留原路徑並正斜線化 + 警告(假設 A7)

### `.hie` 檔列舉

DFS 走訪採用目錄(沿用 F001 source-index 的走訪模式):每層 `listDirectory` 後 `sort` 再走訪(決定性);僅收 `takeExtension == ".hie"` 的檔案;路徑以相對段重組為正斜線;讀不到的子目錄(權限、斷鏈)→ `MetaWarning` + 跳過,不中斷(best-effort)。不略過任何子目錄名(`.hie` 樹內無 D4 情境;`dist-newstyle` 層本來就要掃它)。

### `.hie` 路徑 → module 對映(幽靈判定的前半)

純函數 `moduleNameFromHiePath`,演算法與 F001 的大寫尾綴法同構,僅副檔名不同:

1. 取 `.hie` 檔相對 `hieDir`(第 3 層為相對 `dist-newstyle` 走訪根)的路徑段,末段以 `stripExtension "hie"` 去副檔名
2. 從尾端往前取最長的、每段首字元 `isUpper` 的連續段序列,以 `.` 連接為 module 名
3. 末段非大寫開頭 → `Nothing`

此法對三層一體適用:`.hie` 樹的慣例佈局是 `<hieDir>/<Module/Path>.hie`,module 段必為大寫開頭,尾綴法即精確解;`dist-newstyle` 內前綴的建置機關段(`build/x86_64-windows/ghc-9.14.1/…/hie`)皆非連續大寫段,自然被裁掉。不重用 `Knot.Meta.SourceIndex.moduleNameFromPath`(它寫死 `"hs"` 副檔名,且 F002 正在動 source-index,不跨 feature 改它的匯出面);本函數為 hie-locate 內部實作,匯出僅為測試(見「新增的介面」)。

### 幽靈判定(判定規則 6)

1. 母集:全體 `pmSources` 的 `sfModule`(`Just` 者)收成集合——不論 `sfIncluded`(test 檔預設排除但原始檔存在,其 `.hie` 不是幽靈;假設 A6)
2. 逐一判定每個列舉到的 `.hie`:
   - 對映出 `Just m` 且 `m` ∈ 母集 → `hieFiles`
   - 對映出 `Just m` 且 `m` ∉ 母集 → `hieGhosts` + 警告(`mwPath` = 該 `.hie` 路徑,訊息含 module 名),不進 `hieFiles`
   - 對映不出(`Nothing`)→ 留在 `hieFiles` + 警告:無法證明是幽靈就不丟,下游 extraction 讀內容時自有版本與存在性檢查(假設 A2)

### 決定性(判定規則 7)

- `hieFiles`、`hieGhosts` 產出前各以碼位序排序
- 警告順序固定:層級判定警告 → 列舉走訪警告(走訪序)→ 幽靈/無法對映警告(依排序後清單序)
- 無 mtime、無雜湊迭代序,同輸入同輸出

### `loadProjectMeta` 接線(T7)

管線尾端接上 hie-locate(design.md 資料流:source-index 之後):

```text
loadProjectMeta opts = do
  (cabalFiles, wsD) <- findCabalFiles …
  (sources, wsI)    <- indexSources …
  (hie, wsH)        <- locateHie opts sources
  pure ProjectMeta { …, pmHie = hie, pmWarnings = wsD ++ wsI ++ wsH }
```

警告彙整殿後(discovery → source-index → hie-locate,維持 F001 既定的穩定順序)。與 F002 的同檔整合序見假設 A8。

### 測試 fixture 策略(D5)

驗收標的專案絕對唯讀;fixture 全部新建於 `test/fixtures/`,`.hie` 檔一律空檔案(本 feature 不讀內容,只看路徑):

```text
test/fixtures/hie-conv/            慣例層 + 幽靈情境
├── src/Foo.hs                     實存原始檔(sfModule = Foo)
├── src/Deep/Mod.hs                巢狀 module 實存檔
└── .hie/
    ├── Foo.hie                    有效(對映 Foo,有原始檔)
    ├── Deep/Mod.hie               有效(巢狀對映)
    ├── Gone.hie                   幽靈(無 Gone.hs,模擬「刪除一個原始檔後」)
    └── lowercase/util.hie         無法對映(留置 + 警告,假設 A2)

test/fixtures/hie-dist/            dist-newstyle 層
├── src/Foo.hs
└── dist-newstyle/build/x86_64-windows/ghc-9.14.1/pkg-0.1/build/
    └── extra-compilation-artifacts/hie/Foo.hie

無 .hie 情境重用 test/fixtures/no-cabal/(三層皆未命中 → Nothing)
FromFlag 情境:--hiedir 指向 hie-conv/.hie;不存在情境指向任意不存在路徑
```

新 fixture 均為獨立根目錄,不動 `test/fixtures/proj`,F001 的既有測試期望值不受影響(`.hie` 為隱藏目錄,source-index 的 D4 略過清單本來就不掃它)。

## 使用到的既有串接介面

(專案自有介面簽名為 2026-08-20 從來源檔案讀出的原文;boot library 簽名為同日於本機 GHC 9.14.1 以 `ghc -e ':t …'` 讀出的原文)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs | F001 | T7 接線標的:`pmHie` 由恆 `Nothing` 改接 `locateHie` 結果 |
| `data HieInfo = HieInfo { hieDir :: FilePath, hieSource :: HieDirSource, hieFiles :: [FilePath], hieGhosts :: [FilePath] }` | src/Knot/Meta/Types.hs | F001 | 本 feature 的輸出 DTO(F001 先行定義,零邏輯) |
| `data HieDirSource = FromFlag \| FromConvention \| FromDistNewstyle` | src/Knot/Meta/Types.hs | F001 | 標記三層發現採用層 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs | F001 | 輸入:`root` 與 `hieDirOverride` |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs | F001 | 幽靈判定母集來源(取 `sfModule`) |
| `newtype ModuleName = ModuleName Text`(deriving `Eq`、`Ord`、`Show`) | src/Knot/Meta/Types.hs | F001 | 對映結果與母集元素型別(`Ord` 供集合比對) |
| `data MetaWarning = MetaWarning { mwPath :: FilePath, mwMessage :: Text }` | src/Knot/Meta/Types.hs | F001 | 警告載體 |
| `System.Directory.listDirectory :: FilePath -> IO [FilePath]` | directory-1.3.10.0 | - | 逐層列出目錄項目(`.hie` 列舉、`dist-newstyle` 掃描) |
| `System.Directory.doesDirectoryExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | 三層目錄存在性判定、走訪時分辨目錄 |
| `System.Directory.doesFileExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | 走訪時確認 `.hie` 候選為檔案 |
| `System.FilePath.takeExtension :: FilePath -> String` | filepath-1.5.4.0 | - | 篩 `.hie` |
| `System.FilePath.stripExtension :: String -> FilePath -> Maybe FilePath` | filepath-1.5.4.0 | - | 去 `.hie` 副檔名取 module 末段 |
| `System.FilePath.splitDirectories :: FilePath -> [FilePath]` | filepath-1.5.4.0 | - | 拆路徑段(尾綴法、共同祖先計算、正斜線重組) |
| `System.FilePath.makeRelative :: FilePath -> FilePath -> FilePath` | filepath-1.5.4.0 | - | override 路徑對 root 化為相對(假設 A7) |
| `Data.List.sort :: Ord a => [a] -> [a]` | base-4.22.0.0(GHC 9.14.1) | - | 決定性排序(每層走訪、`hieFiles`、`hieGhosts`) |
| `Data.Char.isUpper :: Char -> Bool` | base-4.22.0.0(GHC 9.14.1) | - | 尾綴法的段首判定 |

## 新增的介面

全部落在 Level 2 契約內:

**`Knot.Meta.HieLocate`(Level 2 模組介面 hie-locate;D3 命名自主權)**

```haskell
locateHie :: MetaOptions -> [SourceFile] -> IO (Maybe HieInfo, [MetaWarning])
-- design.md「模組間公開介面 › hie-locate」原文簽名
-- 三層發現(規則 5)、.hie 列舉、幽靈過濾(規則 6)、決定性(規則 7)
```

測試用途匯出(haddock 標註「僅為 1-to-1 測試而匯出,非 Level 2 契約面」,沿 F001 `moduleNameFromPath` 前例):

```haskell
moduleNameFromHiePath :: FilePath -> Maybe ModuleName
-- 去 .hie 副檔名後取大寫尾綴,T4 的 hedgehog property 直接測純函數
```

另:`knot-hs.cabal` 的 library `exposed-modules` 加入 `Knot.Meta.HieLocate`(元件結構不變,不屬介面新增)。

## TodoList

- [x] T1: 模組骨架——`Knot.Meta.HieLocate` 建檔、cabal `exposed-modules` 接線;`locateHie` 簽名就位,三層皆未命中時回 `(Nothing, [])`  `dep: -`
- [x] T2: `.hie` 檔列舉走訪——遞迴、每層排序、僅收 `.hie`、repo 相對正斜線、讀不到降級警告  `dep: T1`
- [x] T3: 三層發現順序與 `hieSource` 標記——override 存在採用/不存在回 `Nothing`+警告不 fallback、慣例層 `<root>/.hie`、`dist-newstyle` 遞迴掃描與共同祖先 `hieDir`  `dep: T2`
- [x] T4: `moduleNameFromHiePath` 純函數——去 `.hie` 副檔名 + 大寫尾綴法  `dep: T1`
- [x] T5: 幽靈判定——`sfModule` 母集比對、幽靈入 `hieGhosts` + 警告不進 `hieFiles`、無法對映者留置 + 警告  `dep: T2, T4`
- [x] T6: `locateHie` 組裝與決定性——`hieFiles`/`hieGhosts` 碼位序排序、警告順序固定、連續執行結果相同  `dep: T3, T5`
- [x] T7: `loadProjectMeta` 接線——`pmHie` 接上 `locateHie`、警告彙整殿後(整合序:與 F002 同階段序列實作,於當時最新版 `loadProjectMeta` 上整合,見 A8)  `dep: T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_locate_none | 對無 `.hie` 的 fixture(no-cabal)執行 `locateHie` → `(Nothing, [])`;證明骨架與未命中路徑成立 |
| T2 | test_hie_enumerate | hie-conv fixture:`.hie/` 下全部 `.hie` 入列(含巢狀 `Deep/Mod.hie`)、路徑 repo 相對正斜線、非 `.hie` 檔不入列 |
| T3 | test_three_tier_source | testGroup 四例:`--hiedir` 指向 `hie-conv/.hie` → `FromFlag`;hie-conv 無 override → `FromConvention`;hie-dist → `FromDistNewstyle` 且 `hieDir` 為共同祖先;`--hiedir` 指向不存在路徑 → `Nothing` + 一則警告(不 fallback 到慣例層) |
| T4 | test_hie_module_map | HUnit 例:`Foo.hie` → `Foo`、`Deep/Mod.hie` → `Deep.Mod`、`lowercase/util.hie` → `Nothing`、dist-newstyle 前綴段被裁掉;hedgehog property:任意小寫前綴段不改變推導結果 |
| T5 | test_ghost_filter | hie-conv:`Gone.hie` ∈ `hieGhosts`、附警告(`mwPath` 指向該檔)、∉ `hieFiles`;`lowercase/util.hie` ∈ `hieFiles` 且附警告;`Foo.hie`、`Deep/Mod.hie` ∈ `hieFiles` 無警告 |
| T6 | test_locate_deterministic | 對 hie-conv 連續執行兩次 `locateHie`,結果完全相等;`hieFiles` 與 `hieGhosts` 各自嚴格遞增(排序穩定) |
| T7 | test_load_meta_hie | 對 hie-conv 執行 `loadProjectMeta`:`pmHie = Just …`(`hieSource = FromConvention`)、`pmWarnings` 殿後含幽靈警告;對 no-cabal 執行:`pmHie = Nothing` 且既有警告不變 |

## 待確認假設

- A1: 第 1、2 層目錄存在但其中無任何 `.hie` 檔 → 採取:仍採用該層,回 `Just HieInfo`(`hieFiles = []`)+ 警告,不往下層 fallback(採用以「目錄存在」為準,行為可預測)→ 影響:若裁定空目錄應繼續 fallback,改層級判定條件與 T3 測試
- A2: `.hie` 相對路徑無法推導 module(末段非大寫開頭)→ 採取:留在 `hieFiles` + 警告,不判幽靈(無法證明是幽靈就不丟;下游讀內容時自有檢查)→ 影響:若裁定改列 `hieGhosts` 或丟棄,改 T5 判定與測試
- A3: 三層皆未命中 → 採取:`(Nothing, [])`,不出警告(無 `.hie` 是常態;module 級降級告知屬呼叫端/extraction 職責)→ 影響:若裁定要警告,加一則 `MetaWarning` 與對應測試斷言
- A4: 第 3 層的 `hieDir` 取值(`HieInfo` 只有單一 `hieDir` 欄位,dist-newstyle 內可能有多個 hie 根)→ 採取:全部 `.hie` 檔的最深共同祖先目錄(repo 相對);module 對映用尾綴法、不依賴 `hieDir` 精確度 → 影響:若裁定改為多 hie 根,`hieDir` 需改 `[FilePath]`,屬 Level 2 契約變更,走編排者
- A5: `hieDirOverride` 為相對路徑時的基準未定 → 採取:以 `root` 為基準解讀(絕對路徑原樣使用),與子系統一切 root 錨定一致 → 影響:CLI 層若裁定相對 CWD,在組 `MetaOptions` 前先正規化,`locateHie` 不變
- A6: 幽靈比對母集是否受 `sfIncluded` 影響 → 採取:全體 `pmSources` 的 `sfModule`(不論 `sfIncluded`;test 檔預設排除但原始檔實存,其 `.hie` 不是幽靈)→ 影響:若裁定只比對納入檔,test 專案的 `.hie` 會被誤判幽靈,需同步修訂規則 6 文字(契約層)
- A7: override 目錄落在 root 外時 `hieDir`/`hieFiles` 無法 repo 相對 → 採取:`makeRelative root` 化簡,化簡不了則保留原路徑並正斜線化 + 警告 → 影響:下游若假設路徑一律 root 內相對,extraction 端需容忍絕對路徑
- A8: T7 與 F002 改同一檔(`src/Knot/Meta.hs`)且 design.md 功能規劃標 F003 僅依賴 #1 → 採取:不將 F002 列入 `depends-on`(未消費其任何介面,兩設計可平行),T7 依編排者的階段內序列實作、於當時最新版 `loadProjectMeta` 上整合(編排者現排序 F002 → F003)→ 影響:若編排者改為 F003 先實作,T7 接在 S1 版 `loadProjectMeta` 上,F002 隨後整合時保留 `pmHie` 接線

## 實作備註

- 2026-08-20 實作完成:T1–T7 全數完成,F003 新增 11 條測試案例(含 hedgehog property),全套件 31 tests 全綠;F001/F002 既有期望值零改動。
- 介面表原列 `System.Directory.doesFileExist`,實作沿 F001 source-index 走訪前例以「非目錄即為檔案候選」判定,實際未用到(內部實作自主權,非契約偏離)。
- fixture 依 D5 新建 `test/fixtures/hie-conv/`、`test/fixtures/hie-dist/`(`.hie` 皆空檔);另加 `.hie/readme.txt` 誘餌驗證非 `.hie` 檔不入列。
- 決定性細節:幽靈/無法對映警告採「排序後清單的單趟掃描序」(兩類依路徑碼位序交錯),符合「依排序後清單序」的規格文字。
