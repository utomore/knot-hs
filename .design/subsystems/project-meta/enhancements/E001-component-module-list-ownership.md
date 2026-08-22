---
id: E001
type: enhance
title: component-module-list-ownership
description: component 歸屬改看 exposed/other-modules 與 main-is,hs-source-dirs 為 . 時不再認領整個 repo
status: done
created: 2026-08-22
updated: 2026-08-23
depends-on: []
related-adr: []
related-feature: [F002]
---

# E001: component 歸屬改看 module 清單,不只看目錄前綴

## 現況分析

`src/Knot/Meta/SourceIndex.hs:41-48` 的 `ownerIndex` 用
`(ComponentRef, ComponentKind, hs-source-dirs 的段序列)` 建索引,
`:66` 的 `dirPrefixOf` 純以**目錄前綴**判斷某個 `.hs` 屬於哪個 component:

```haskell
  dirSegs d = case splitDirectories d of
    ["."] -> []              -- "." 視為根(恆命中)
    segs  -> segs
```

`["."] -> []` 這一行是關鍵:空段序列是任何路徑的前綴,所以
**`hs-source-dirs` 取預設值 `.` 的 component 會命中 repo 內每一個 `.hs`**。

Cabal 的 `hs-source-dirs` 預設值正是 `.`,所以只要目標專案的某個 component 省略
這一欄(很常見,尤其是根目錄擺 library 的小專案),knot 就會把 fixture、範例碼、
腳本全部判給它。再加上判定規則 2「只要任一 owner 未排除即 `sfIncluded = True`」,
test-suite 的排除也抵銷不掉。

**實測**(2026-08-22,G-E001 期間):knot-hs 自己的公開 `library` 一度沒寫
`hs-source-dirs`,自掃節點數從 548 跳到 **575**、警告 0 → 8,多出來的全是
`test/fixtures/**` 的檔案。當時的處置是在 knot-hs 的 `.cabal` 明寫
`hs-source-dirs: src`——那只治得了自己,治不了別人的專案。

### 真正的成因不是「`.` 這個值」

Cabal 的 component 實際包含哪些 module,是由 `exposed-modules` /
`other-modules` / `main-is` **明文列出**的;`hs-source-dirs` 只是「去哪些目錄找
這些 module」。knot 完全沒讀那三個欄位,只用目錄前綴近似:

- `hs-source-dirs: src` → 近似得還行(該目錄下多半就是它的 module)
- `hs-source-dirs: .` → 近似退化成「全部」

`src/Knot/Meta/Types.hs:40-46` 的 `ComponentMeta` 目前只有
`compName` / `compKind` / `compSourceDirs` / `compExcluded`,**沒有 module 清單**。
而 `src/Knot/Meta/CabalModel.hs:81-87` 的 `finalizePD` 結果裡,每個 component 的
`BuildInfo` / `Library` / `Executable` 都已經帶著 `exposedModules`、`otherModules`、
`modulePath`(main-is)——資料早就在手上,只是沒有往下傳。

2026-08-23 動工前重讀上述位置,現況與本節描述一致,未漂移。

## Scope

**方向定案(2026-08-23,與開發者確認)**:候選 A——`ComponentMeta` 增列 module
清單,歸屬判定改為「目錄前綴命中 **且** module 名在清單內(或路徑就是 main-is)」。
這是 project-meta 的 **Level 2 契約變更**(DTO 加欄位、判定規則 2/3 改寫),
由本文檔一併回填 `design.md`。

**會動的範圍**:

- `src/Knot/Meta/Types.hs`:`ComponentMeta` 加 `compModules`、`compMainIs`
- `src/Knot/Meta/CabalModel.hs`:從 `finalizePD` 結果填這兩欄
- `src/Knot/Meta/SourceIndex.hs`:規則 2 的歸屬判定、規則 3 的 main-is 對映
- `.design/subsystems/project-meta/design.md`:DTO、判定規則 2/3、cabal-components
  契約卡驗收標準的「三個 owner」句、「已知待解」段落
- `test/Main.hs`:F002 T6 的 `app/Main.hs` owners 期望(舊規則的產物,見實作備註)、
  既有 `ComponentMeta` 建構處補欄位、新增本文檔的 1-to-1 測試
- `test/fixtures/dotdir/`:新 fixture(省略 `hs-source-dirs` 的專案)
- `README.md` §4:已知限制改為已修正的行為說明

**明確不動**:

- discovery 模組、`loadProjectMeta` 簽名、`MetaOptions` / `ProjectMeta` / `SourceFile`
  的欄位
- 判定規則 1(kind 排除)、4(S1 啟發式)、7(決定性)與「無 owner 退回 A5」的退回路徑
- extraction / graph-core / export-query 的任何程式碼(它們只消費 `sfIncluded` /
  `sfModule` / `compName` / `compExcluded`,欄位語意不變)
- 既有 fixture 的 `.cabal`(`comps`、`graph`、`multi`、`buildable` 等)與五份黃金檔
  (預期 byte 不變:黃金 fixture 裡沒有任何檔案的 `sfIncluded` 會因新規則翻轉)
- 不讀原始碼內容(main-is 檔的 module 名用 Haskell 預設語意 `Main`,不開檔驗證)

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|------|--------|------------------|
| `hs-source-dirs` 省略(預設 `.`)的 component 認領的檔案 | repo 內全部 `.hs` | 只有 `exposed-modules` / `other-modules` / `main-is` 指到的檔 |
| knot-hs 自掃、公開 `library` 的 `hs-source-dirs` 改為 `.`(合成,不改 `.cabal`) | `test/fixtures/**` 全被認領並納入(實測 +27 節點、+8 警告) | `test/fixtures/**` 無 owner、`sfIncluded = False`;`src/**` 納入集合與現行完全相同 |
| 五份黃金檔 `codegraph.json` | — | byte 不變 |
| 既有 F001 / F002 測試 | 綠 | 綠(僅 F002 T6 的 owners 期望依新契約改寫) |

## 介面變動(Level 2 契約)

### DTO

```haskell
data ComponentMeta = ComponentMeta
  { compName       :: Text
  , compKind       :: ComponentKind
  , compSourceDirs :: [FilePath]
  , compModules    :: [ModuleName]     -- 新增:exposed-modules ++ other-modules(宣告序、去重)
  , compMainIs     :: Maybe FilePath   -- 新增:main-is(相對 hs-source-dirs 的原樣路徑、正斜線);library / foreign-library 為 Nothing
  , compExcluded   :: Bool
  }
```

### 判定規則 2(改寫)

檔案 f 歸屬 component c,當且僅當 c 的某個 `hs-source-dirs` d 是 f 的目錄前綴,**且**
下列任一成立:

- f 相對 d 依規則 3 推得的 module 名 ∈ `compModules c`
- f 相對 d 的路徑 == `compMainIs c`

`sfOwners` 仍全列(一對多)、保序去重;`sfIncluded = any (not . compExcluded)` 不變。
同一目錄下**未列在任何 component 的檔案**(作者漏列 `other-modules`、fixture、腳本)
→ 無 owner → 沿用 A5:module 名退回大寫尾綴法、納入判定退回規則 4 的路徑啟發式。

### 判定規則 3(補充)

只經 `main-is` 命中(沒有任何 owner 以 module 清單命中)的檔案,`sfModule = Just "Main"`
——Haskell 語意:`main-is` 檔案的 module 名預設為 `Main`,與路徑無關(例:
`main-is: Cli/Main.hs` 的 `app/Cli/Main.hs` 是 `Main`,不是 `Cli.Main`)。
其餘維持「取最長命中 `hs-source-dirs` 去前綴」。

### 不變

`loadProjectMeta`、`resolvePackage`、`indexSources` 三個簽名;`SourceFile` 欄位;
規則 1、4、7。

## TodoList

- [x] T1: `ComponentMeta` 加 `compModules` / `compMainIs`(`Types.hs`),既有建構處(`test/Main.hs` 兩處)補欄位  `dep: -`
- [x] T2: cabal-model 填欄位——`exposedModules ++ otherModules` 轉 `ModuleName`(宣告序去重)、exe/test/bench 的 `main-is` 正斜線化;library / flib 為 `Nothing`  `dep: T1`
- [x] T3: source-index 規則 2——`ownerIndex` 帶 module 集合與 main-is,命中條件改為「前綴 ∧(module ∈ 清單 ∨ 相對路徑 == main-is)」  `dep: T2`
- [x] T4: source-index 規則 3——僅 main-is 命中時 `sfModule = Just "Main"`;有 module 清單命中時沿用最長 dir  `dep: T3`
- [x] T5: `dotdir` fixture(省略 `hs-source-dirs` 的 library + test-suite)與 knot-hs 合成自掃的量化驗證  `dep: T4`
- [x] T6: 文檔回填——`design.md` DTO / 規則 2、3 / cabal-components 契約卡驗收句 / 移除「已知待解」;README §4;F002 T6 期望改寫並註明  `dep: T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e001_component_meta_fields` | 以六個欄位建構 `ComponentMeta`,`Eq` 成立;`compModules` 型別為 `[ModuleName]` |
| T2 | `test_e001_cabal_module_list` | `comps` fixture:`lib:comps` → `[Comps.Core]`、`flib:comps-ffi` → `[Comps.FFI]`、`exe:comps-exe` → `compMainIs = Just "Main.hs"`、`test:comps-test` → `Just "Spec.hs"`、library 的 `compMainIs = Nothing`;`cond` fixture 無 module 清單 → `[]` |
| T3 | `test_e001_owner_by_module_list` | `dotdir` fixture(`hs-source-dirs` 省略):`Foo.hs` owners = lib + test(一對多仍靠清單)、`Foo/Bar.hs` = lib;`examples/Stray.hs` 與 `test/fixtures/Decoy.hs` **無 owner**,後者 `sfIncluded = False`;`comps` 的 `src/lowercase/util.hs` 不再被 `lib:comps` 認領 |
| T4 | `test_e001_main_is_module` | `dotdir` 的 `main-is: Cli/Main.hs` → `app/Cli/Main.hs` owner = exe、`sfModule = Main`;`comps` 的 `app/Main.hs` owners 恰 `[exe:comps-exe]`(test/bench 的 main-is 是別的檔) |
| T5 | `test_e001_self_scan_dot_dir` | 讀 knot-hs 自己的 `.cabal`,把公開 `library`(MainLibrary)的 `compSourceDirs` 換成 `["."]` 後跑 `indexSources`(重演 2026-08-22 的事故):`test/fixtures/**` 全部無 owner 且 `sfIncluded = False`;`sfIncluded = True` 的路徑集合與正常 `loadProjectMeta` 完全相同;`src/**` 仍由 `lib:knot-internal` 認領 |
| T6 | —(文檔)+ 既有 `test_codegraph_output_unchanged`、F002 T6–T9 | 黃金檔 byte 不變;F002 既有測試在改寫後的期望下全綠 |

## 實作備註

(2026-08-22 由 G-E001 的範圍外發現立案;G-B002 修復期間確認它與 `.hie` 的兩個缺陷
無關,是獨立的歸屬判定問題。2026-08-23 與開發者確認走候選 A 後開工。)

### 2026-08-23 實作完成

**量化結果**(對照「改善目標」):

| 指標 | 改善前 | 改善後 |
|------|--------|--------|
| 公開 `library` 的 `hs-source-dirs` 合成為 `.` 時,`test/fixtures/**` 被認領的檔數 | 32(全部,且 `sfIncluded = True`) | **0**;32 檔全部 `sfIncluded = False`(T5) |
| 同上,`sfIncluded = True` 的路徑集合 | 多出 `test/fixtures/**` | 與正常載入**完全相同**(T5) |
| 五份黃金檔 `codegraph.json` | — | **byte 不變**(`test_codegraph_output_unchanged` 綠) |
| knot-hs 自掃節點數(F007 T7 / G-E003 selfcheck) | 526 | **526**(不變) |
| 測試 | 139 綠 | **144 綠**(+5 E001;F002 T6 期望改寫後仍綠) |

**實作取捨**(Level 3 自主權內,不影響契約):

- source-index 的 owner 索引列從三元組改為 `Owner` 記錄(多了 module 清單與 main-is
  段序列),命中結果以 `Hit Owner Via` 記錄是靠 module 清單(帶推得的 module 名)
  還是 main-is 命中——規則 3 的「僅 main-is → `Main`」就是看 `hits` 裡有沒有
  `ViaModule`。module 清單用 `elem`(不建 `Set`):component 數 × module 數在
  驗收標的規模下(particle-magic 9 個 component、193 檔)可忽略。
- cabal-model 的 `main-is` 只對 `TestSuiteExeV10` / `BenchmarkExeV10` 取值;
  detailed-0.9 的 `TestSuiteLibV09` 把 `test-module` 併進 `compModules`(它就是
  入口 module)、`main-is` 為 `Nothing`;`TestSuiteUnsupported` / `BenchmarkUnsupported`
  兩者皆空。
- `compMainIs` 不做 repo 相對錨定(`Knot.Meta.anchor` 不碰它):它的基準是
  `hs-source-dirs`,歸屬比對時用「路徑去掉 dir 前綴後的剩餘段 == main-is 段序列」,
  多套件的 `pkg-b/app/Main.hs` 經錨定過的 `compSourceDirs = ["pkg-b/app"]` 自然命中(T4)。
- **不檢查 `main-is` 檔案是否存在、也不依 `hs-source-dirs` 順序只取第一個命中**:
  `hs-source-dirs: test, app` + `main-is: Main.hs` 時,`test/Main.hs` 與 `app/Main.hs`
  都會被該 test-suite 認領(Cabal 實際只編第一個找到的)。多認一個 owner 只影響
  `sfOwners`,不影響 `sfIncluded`(另一個 owner 是 exe,本來就納入),故維持純函數、
  不引入檔案存在性判斷。

**契約變更的連帶**:

- F002 T6 `test_owners_and_included` 的 `app/Main.hs` 期望從三個 owner 改為
  `[exe:comps-exe]`——原「三個」是純目錄前綴規則的產物(test/bench 只是把 `app` 列進
  `hs-source-dirs`,`main-is` 是 `Spec.hs` / `Bench.hs`)。一對多的驗證改由 T3 的
  `dotdir/Foo.hs`(lib 與 test 的清單都列了 `Foo`)承接;`design.md` cabal-components
  契約卡驗收標準的 A9 句已加註。F002 文檔本身不改(歷史紀錄)。
- `src/lowercase/util.hs` 一類「在 `hs-source-dirs` 下但推不出合法 module 名」的檔案,
  從「有 owner、`sfModule = Nothing`」變成「無 owner、走 A5 退回」;對納入判定無影響
  (黃金檔 `comps.json` 的 `Util` 節點 byte 不變)。

**未動的範圍確認**:discovery、extraction、graph-core、export-query 零修改;
`app/Knot/App/Summary.hs` 未加印 module 清單(`--summary meta` 輸出不變)。
本專案沒有程式碼知識圖(無 `codegraph.json` / `.codegraph/` / `graphify-out/`),無圖可更新。
