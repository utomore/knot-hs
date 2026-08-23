---
id: E001
type: enhance
title: exclude-excluded-component-hie
description: 被排除 component 的 .hie 不進 HieLayout,收掉逐檔 cannot map 警告
status: open
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-006]
related-feature: [F005, F006, F004, F008]
---

# E001: 依 `compExcluded` 過濾被排除 component 的 `.hie`

## 現況分析

2026-08-23 的 S5 實跑驗收(system.md「開發階段」)在 MagicFarmer 上得到 **75 則**
extraction 警告,全部長這樣:

```
extract: …/.knot/build/…/t/magic-farmer-test/…/hie/MagicFarmer/App/AssetsSpec.hie:
  cannot map indexed module MagicFarmer.App.AssetsSpec back to pmSources; skipping its decls and refs
```

### 成因鏈

1. `src/Knot/Extract/BuildDriver.hs:88-101` 的 `cabalArgs` 只在有**納入**的 test-suite
   時才帶 `--enable-tests`——這是對的。但 MagicFarmer 自己的 `cabal.project` 寫了
   `tests: True`,cabal 照樣把 test-suite 建進 `.knot/build/`,`.hie` 也跟著出現
2. `BuildDriver.hs:193-203` 的 `enumerateHie` 走訪 builddir **收全部** `.hie`,每筆附
   `componentRefOf` 推出的 `ComponentRef`(`t/magic-farmer-test` → `test:magic-farmer-test`),
   **不看** `ProjectMeta` 裡該 component 的 `compExcluded`——雖然它手上就有 `pm`
3. `src/Knot/Extract/HieIndex.hs:164-182` 的 `ensureIndex` 只用 `partitionByGhc` 過濾
   GHC 版本,把被排除 component 的 `.hie` 也索引進 `hiedb.sqlite`(多花時間、索引裡
   多一堆永遠用不到的列)
4. `src/Knot/Extract/HiedbFacts.hs:245-260` 的 `buildModIndex` 對每個索引到的 module 做
   `resolveModuleSource`;test 的原始檔 `sfIncluded = False` → 依 G-B001 規則整批跳過
   並**每個 module 一則警告**。F008 的 hie-instances 對同一批 `.hie` 再警告一次
   (`skipping its instances`)

行為是**正確**的(test 的宣告沒有混進圖),問題是噪音:75 則警告讓 `--strict` 在這種
專案上永遠 exit 1,也把真正值得看的警告淹掉。

### 規則 1 的缺口

`design.md` 抽取規則 1 只說「只**建置** `compExcluded = False` 的 component」,沒說
「只**列舉 / 索引**它們的 `.hie`」。建置旗標管不到目標專案自己的 `cabal.project`
(`tests: True`、`benchmarks: True`),所以「建了什麼」和「該讀什麼」本來就該分開判定。

### 另一類噪音(本文檔不處理)

同一次實跑還有 1 則 `Paths_magic_farmer.hie: cannot map`——那是 cabal 自動產生的
`Paths_<pkg>` module,屬**納入**的 library、但不在 `pmSources`。它是「autogen module」
問題,不是 component 排除問題,另案。

## Scope(涵蓋範圍)

**動**(全部在 extraction 內):

- **build-driver** `enumerateHie`:列舉時依 `ProjectMeta` 過濾——`ComponentRef` 對到的
  component `compExcluded = True` 者**不進** `HieLayout`;對不到任何 component 的
  `.hie`(`componentRefOf` 退回的未知 kind / 套件)**保留**(那不是「被排除」,是佈局
  認不得,交給下游的 best-effort)
- **抽取規則 1**(Level 2,回填 `design.md`):加一句「`HieLayout` 只列舉納入 component
  的 `.hie`;目標專案自己開了 `tests: True` 之類而建出的被排除 component 產物,列舉時
  即濾掉」
- 新 fixture `test/fixtures/tests-on/`:library + test-suite,`cabal.project` 寫 `tests: True`

**明確不動**:

- `HieLayout` 型別、`ensureHie` / `ensureIndex` / `readIndexFacts` / `readInstanceFacts` 簽名
- hie-index 的版本過濾、索引清理邏輯(`indexFiles` 本來就會刪掉不在清單內的列——
  過濾後被排除 component 的舊列會被**自動清掉**,這是既有行為的副產品,不需新碼)
- hie-facts / hie-instances 的 `cannot map` 警告本身(它們仍是規則 9 的正確行為,只是
  不再被這批檔觸發)
- `cabalArgs`(建置旗標)、`.knot/` 佈局、`--include-tests` 的語意
- 排除的「順便改」:`Paths_*` / `PackageInfo_*` autogen module 的靜默跳過(另案,
  見上);`--strict` 對警告分級(另案)

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| MagicFarmer(`cabal.project` 有 `tests: True`)`knot extract` 的 extraction 警告 | 75 則(74 則 test spec + 1 則 `Paths_`) | **1 則**(只剩 `Paths_magic_farmer`,另案);節點 / 邊數 **不變**(1580 / 6576) |
| `tests-on` fixture,`includeTests = False` | 每個 test module 一則 `cannot map`(hie-facts)+ 一則(hie-instances) | **0 則**;`HieLayout` 不含 `test:` component 的檔;`FactDecl` 只來自 library |
| 同 fixture,`includeTests = True` | — | test 的 `.hie` 進 `HieLayout`、test 的 `FactDecl` 出現;與改善前行為相同 |
| 索引清理 | — | `includeTests` 由 True 切回 False 後,`hiedb.sqlite` 的 `mods` 不再含 test 的 `hieFile` 列 |
| 既有測試 | 152 綠 | 152 + 本文檔新增 綠;黃金檔 byte 不變;knot-hs 自掃節點數不變(knot-hs 的 `cabal.project` 沒開 `tests:`,本來就沒有這批檔) |

## 相依性

`depends-on: []`。被優化的是 F005(`enumerateHie`)、其消費端 F006 / F004 / F008 只受益
不改碼。與 export-query/E001 無關,可平行。

## 改善方案

### M1 `enumerateHie` 依 `compExcluded` 過濾

```haskell
enumerateHie :: ProjectMeta -> FilePath -> FilePath -> FilePath -> IO HieLayout   -- 簽名不變
  …
  excluded = Set.fromList
    [ ComponentRef (pkgName p, compName c) | p <- pmPackages pm, c <- pkgComponents p, compExcluded c ]
  entries  = sortOn snd
    [ (ref, rel) | f <- files, let ref = componentRefOf … , ref `Set.notMember` excluded, … ]
```

- 判定只看 `compExcluded`(project-meta 已把 `includeTests` 折進去,規則 1 的單點落實),
  不自己看 `compKind`
- `componentRefOf` 對不到的 ref(未知 kind 段、套件名退回去版號者)不在 `excluded` 內
  → 保留,維持現行 best-effort
- 順序與決定性不變:過濾後仍 `sortOn snd`

### M2 規則 1 回填

`design.md` 抽取規則 1 加:「**`.hie` 的列舉同樣只取納入的 component**:目標專案自己的
`cabal.project`(`tests: True` 等)可能讓 cabal 建出被排除 component 的 `.hie`,
build-driver 列舉時依 `compExcluded` 濾掉,不進 `HieLayout`、不索引、不產生警告」。
規則 9 不動(對映不到的單檔仍是警告)。

### 不需要改的地方(設計上確認過)

- hie-index `indexFiles` 的清理(`deleteFileFromIndex` 對不在清單內的列)讓切換
  `--include-tests` 後索引自動收斂
- hie-facts / hie-instances 讀的是索引 / `HieLayout`,輸入少了這批檔,警告自然消失

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `enumerateHie :: ProjectMeta -> FilePath -> FilePath -> FilePath -> IO HieLayout` | `src/Knot/Extract/BuildDriver.hs:195-203` | F005 | M1 的改動點 |
| `componentRefOf :: [Text] -> [FilePath] -> ComponentRef` | `src/Knot/Extract/BuildDriver.hs:210-` | F005 | 每筆 `.hie` 的 component |
| `data ComponentMeta = ComponentMeta { compName :: Text, compKind :: ComponentKind, compSourceDirs :: [FilePath], compModules :: [ModuleName], compMainIs :: Maybe FilePath, compExcluded :: Bool }`;`newtype ComponentRef = ComponentRef (Text, Text)` | `src/Knot/Meta/Types.hs` | project-meta/F002、E001 | 排除判定(`compExcluded`)、ref 比對 |
| `indexFiles :: ExtractOptions -> [FilePath] -> IO IndexHandle`(含 `deleteFileFromIndex` 清理) | `src/Knot/Extract/HieIndex.hs:183-` | F006 | 確認切換後索引自動收斂(不改) |
| `buildModIndex :: [SourceFile] -> [ModRow] -> (Map Text ModEntry, [ExtractWarning])` | `src/Knot/Extract/HiedbFacts.hs:245-260` | F004 | 警告的來源(不改) |

## 介面變動

無簽名變動。Level 2 文字變動:抽取規則 1 加一句(見 M2)。`HieLayout` 的**內容**語意
收窄(只含納入 component 的 `.hie`)——消費端 hie-index / hie-facts / hie-instances 不需改碼。

## TodoList

- [ ] T1: build-driver——`enumerateHie` 依 `compExcluded` 過濾,對不到 component 的檔保留  `dep: -`
- [ ] T2: fixture `test/fixtures/tests-on/`(library + test-suite,`cabal.project` 寫 `tests: True`)與端到端驗證(`includeTests` 兩態、索引收斂)  `dep: T1`
- [ ] T3: `design.md` 規則 1 回填;MagicFarmer 實跑 75 → 1 寫進 system.md 進度表  `dep: T1`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e001_enumerate_skips_excluded` | 暫存目錄手工擺 `.hie` 空檔(`…/build/x86_64-windows/ghc-9.14.1/p-0.1/build/…`、`…/t/p-test/…`、`…/x/p-exe/…`、未知 kind 段 `…/z/weird/…`):`ProjectMeta` 標 `test:p-test` 為 `compExcluded = True` → `HieLayout` 只含 lib、exe 與未知者;全部 `compExcluded = False` → 四筆都在;順序為碼位序 |
| T2 | `test_e001_tests_on_end_to_end` | `tests-on` fixture 暫存副本:`includeTests = False` 時 `extract` 回 `Right`、警告 `[]`、`FactDecl` 的檔全在 `src/`;`includeTests = True` 時 test 的 `FactDecl` 出現;先 True 後 False 再跑一次,`hiedb.sqlite` 的 `mods.hieFile` 不含 `p-test` 路徑 |
| T3 | `test_e001_rule_one_mentions_enumeration` + 既有 `test_codegraph_output_unchanged`、`test_two_layer_selfcheck` | `design.md` 規則 1 含「列舉」與 `compExcluded`;黃金檔 byte 不變;自掃節點數不變。MagicFarmer 75 → 1 為人工驗收,結果寫進 system.md |

## 實作備註

(撰寫時留空。)
