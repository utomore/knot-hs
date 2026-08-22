---
id: F004
type: feature
title: hie-retire
description: 移除 hie-locate 模組與 pmHie / HieInfo / hieDirOverride,project-meta 不再碰 .hie
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, G-E001]
related-adr: [ADR-006]
related-feature: [F003]
---

# F004: hie-retire — project-meta 退出 `.hie` 的世界

## 功能概述

ADR-006 把 `.hie` 變成 extraction 自建於 `.knot/` 的產物,project-meta 跑在建置之前、根本看不到它。F003 hie-discovery 的整個面——三層發現順序、列舉、幽靈過濾、`--hiedir` 覆寫——自此沒有輸入可處理。本 feature 純減法:刪 `Knot.Meta.HieLocate`、刪 `HieInfo` / `HieDirSource`、`MetaOptions` 去 `hieDirOverride`、`ProjectMeta` 去 `pmHie`,`loadProjectMeta` 的管線縮短為三站。**無新增介面**。

程式碼裡 `pmHie` 的 library 側消費者在 F006 之後已經是零(extraction 改吃 `HieLayout`),剩下的引用全在 `app/Knot/App/Cli.hs:247`(`hieDirOverride = ecHieDir c`)與測試——前者由 export-query/F005 清。

**驗收標準**(契約卡逐條對照):

| # | 契約卡 | 落地 | 測試 |
|---|---|---|---|
| 1 | `src/Knot/Meta/HieLocate.hs` 不存在 | 檔案刪除、`knot-hs.cabal` 的 `exposed-modules` 去掉一列 | T2 |
| 2 | `Knot.Meta.Types` 匯出清單不含 `HieInfo` / `HieDirSource` | 兩個型別連同匯出一起刪 | T1 |
| 3 | `MetaOptions` 恰兩個欄位、`ProjectMeta` 恰三個欄位 | 記錄語法逐欄建構即證明 | T1 |
| 4 | F003 的 1-to-1 測試**移除**(不是跳過),F001 / F002 全綠 | `f003Tests` 七條與其輔助、`hie-conv` / `hie-dist` 兩個 fixture 一併刪除 | T4 |
| 5 | `src/` 與 `app/` 整體編譯通過 | `src/` 由本 feature 保證;`app/` 與閘門由 S5 三件套共同閘門承擔(見「相依性」) | T3、T5 |
| 6 | 五份黃金檔 byte 不變 | `ProjectMeta` 去一欄不影響 `pmSources` / `pmPackages`;黃金測試在共同閘門跑 | (extraction/F007 T6) |
| 7 | `--summary meta` 不再印 `.hie` 資訊 | `renderMetaSummary` 現況已不讀 `pmHie`(export-query/F005 T5 釘住);本 feature 刪欄位後它想印也印不了 | (export-query/F005 T5) |
| 8 | 閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0 | 共同閘門 | T5 |
| 9 | F003 文檔 `status` 改 `closed` | 實作收尾時改,連同 `updated` | T5 |

## 相依性

`depends-on: [F001, G-E001]`,由「使用到的既有串接介面」表反推:

- **F001** scan-baseline:`loadProjectMeta` / `MetaOptions` / `ProjectMeta` 是本 feature 修改的 DTO 與進入點;`indexSources` 是縮短後管線的最後一站(簽名不動)
- **G-E001**:它的 M3 把 `.hie` 尾綴規則併進 source-index 的 `moduleNameFromPathExt`,hie-locate 是唯一的第二個消費者;hie-locate 退場後該函式只剩 `moduleNameFromPath` 一個呼叫端,G-E001 的 T3 測試(`test_module_suffix_rule_agrees`,比較兩條規則等價)隨之失去比較對象而移除;守門測試 `test_cabal_contract_surface` 的模組計數 27 / 18 → **26 / 17**

**不列入的相依**:`F003` hie-discovery 列在 `related-feature`——本 feature 是**撤銷**它,不是建立在它上面;F003 文檔在本 feature 完成時改 `closed`。

**S5 三件套的順序(export-query/F005 設計時裁定)**:

```
extraction/F007(src/)→ project-meta/F004(本 feature,src/)→ export-query/F005(app/ + test/)→ 共同閘門
```

本 feature 刪掉 `hieDirOverride` 後 `app/Knot/App/Cli.hs:247` 編不過,這是預期的(契約卡明確不做:不動 CLI 旗標解析);而 `test-suite knot-test` 把 `app/` 編進去,所以**本 feature 的測試要等 export-query/F005 落地才跑得起來**。三者在同一條分支連續做完再跑閘門,中間狀態不得宣告任何一個 `done`。與 extraction/F007 之間沒有程式碼相依(extraction 自 F006 起不讀 `pmHie`),排在它之後只是批次的既定順序。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/project-meta/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 對外契約 `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | 簽名不變;實作去掉 `locateHie` 一站,警告序縮為 discovery → cabal-model → source-index |
| DTO `MetaOptions { root, includeTests }` | 刪 `hieDirOverride` |
| DTO `ProjectMeta { pmPackages, pmSources, pmWarnings }` | 刪 `pmHie` |
| 「S5 移除的 DTO」:`HieInfo`、`HieDirSource` | 型別與匯出一併刪除 |
| 內部模組「S5 移除:hie-locate」 | `Knot.Meta.HieLocate` 刪除 |
| 模組間公開介面「S5 移除:`locateHie`」 | 隨模組消失 |
| 判定規則 5、6 廢除 | 無對應程式碼殘留;規則 1–4、7 的實作一行不動 |
| 「明確不做」:不動三個判定模組、不清 extraction 側、不動 CLI、不留相容路徑 | 全部遵守 |

## 實作方式

### 程式碼(純減法)

1. **`src/Knot/Meta/Types.hs`**:刪 `HieInfo`、`HieDirSource` 的定義與匯出;`MetaOptions` 刪 `hieDirOverride`;`ProjectMeta` 刪 `pmHie`;模組 haddock 去掉對兩者的描述
2. **`src/Knot/Meta.hs`**:刪 `import Knot.Meta.HieLocate`;`loadProjectMeta` 刪 `locateHie` 呼叫與 `hieWarnings`,`pmWarnings = discoveryWarnings ++ cabalWarnings ++ indexWarnings`;haddock 的「管線尾端由 `locateHie` 填 `pmHie`」段刪除
3. **`src/Knot/Meta/HieLocate.hs`**:刪檔。`moduleNameFromHiePath` 隨之消失——它只是 `moduleNameFromPathExt ".hie"` 的別名,沒有其他呼叫端
4. **`knot-hs.cabal`**:`knot-internal` 的 `exposed-modules` 刪 `Knot.Meta.HieLocate`(27 → 26;不影響公開 `library` 的 `reexported-modules`)
5. **`src/Knot/Extract/Types.hs:37`** 的 haddock「`@sfPath@ / @hieFiles@ 等 repo 相對路徑的錨點」改掉 `hieFiles` 一詞(extraction/F007 也會改那份 haddock,誰先到誰改,不衝突)

`Knot.Meta.SourceIndex` 的 `moduleNameFromPathExt` **保留**——它是 G-E001 去重後的唯一實作,`moduleNameFromPath` 仍用它;不因為少了一個消費者就把泛化拿掉(那是 G-E001 的決定,本 feature 不翻案)。

### 測試(T4 的實質內容)

**刪除**:`f003Tests` 整組(`test_locate_none` / `test_hie_enumerate` / `test_three_tier_source` / `test_hie_module_map` / `test_ghost_filter` / `test_locate_deterministic` / `test_load_meta_hie`)與輔助(`hieConvSources`、`allHieConvPaths` / `validHieConvPaths`、`hieDistFooHie`、`hieConvFixture` / `hieDistFixture`);G-E001 的 `test_module_suffix_rule_agrees`;`import Knot.Meta.HieLocate` 與 `HieInfo (..)` / `HieDirSource (..)` 的 import;`test/fixtures/hie-conv/` 與 `test/fixtures/hie-dist/` 兩個 fixture 目錄(內含綁 GHC 9.14.1 的 `.hie` 二進位,與 F006 刪 `test/fixtures/hiedb/` 同一個理由)。

**改寫**:`defOpts` 去 `hieDirOverride = Nothing`;`emptyMeta` 改三參數;六處記錄字面量的 `pmHie = Nothing`(`test/Main.hs:339,427,643,1409,2304,2385`)刪除;`test_extract_types_construct` 等若有 `pmHie pm @?= Nothing` 斷言(`:344,411`)刪除;export-query/F004 `test_extract_options_mapping` 的 `hieDirOverride mo @?= Just "dist/hie"`(`:5017`)由 export-query/F005 改,本 feature 不碰;G-B002 `test_decl_line_within_file` 以 `pmHie` 判斷「有沒有 `.hie`」的前置(`:5807-5808`)刪除——S5 後 knot-hs 自己就會被建置,`extract` 回 `Right` 即可續行(該測試其餘的 `erLevel` / `dbPath` 殘留由 extraction/F007 T6 清)。

**新增**:T1–T3 各一條守門測試(見對照表)。

### 錯誤處理

無新路徑。`loadProjectMeta` 的 best-effort 語意(discovery / cabal-model / source-index 各自降級為警告)一字不動;少了 hie-locate 只是少一個警告來源。

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | `src/Knot/Meta.hs:29` | F001 | 簽名不變;實作刪 hie-locate 一站 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | `src/Knot/Meta/Types.hs:22` | F001 | 刪第三欄 |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | `src/Knot/Meta/Types.hs:29` | F001 | 刪 `pmHie` |
| `indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])` | `src/Knot/Meta/SourceIndex.hs:36` | F001 | 縮短後管線的最後一站,不動 |
| `data HieInfo = HieInfo { hieDir :: FilePath, hieSource :: HieDirSource, hieFiles :: [FilePath], hieGhosts :: [FilePath] }`、`data HieDirSource = FromFlag \| FromConvention \| FromDistNewstyle` | `src/Knot/Meta/Types.hs:77,85` | F003 | 刪除 |
| `locateHie :: MetaOptions -> [SourceFile] -> IO (Maybe HieInfo, [MetaWarning])`、`moduleNameFromHiePath :: FilePath -> Maybe ModuleName` | `src/Knot/Meta/HieLocate.hs:41,169` | F003 | 隨模組刪除 |
| `moduleNameFromPathExt :: String -> FilePath -> Maybe ModuleName`、`moduleNameFromPath :: FilePath -> Maybe ModuleName` | `src/Knot/Meta/SourceIndex.hs:133,125` | G-E001 | 保留;hie-locate 退場後前者只剩後者一個呼叫端,G-E001 T3 的等價測試移除 |

**本 feature 不呼叫、但會被本 feature 弄壞的消費端**(預期,由同批的 export-query/F005 修):`app/Knot/App/Cli.hs:243-247` 的 `toMetaOptions`(`hieDirOverride = ecHieDir c`)。

**守門測試**(非介面,計數由本 feature 更新):`test_cabal_contract_surface`(`test/Main.hs:5437,5443`)的 `exposed` 27 → 26、`private` 18 → 17——與 extraction/F007 的「一進一出不變」疊加後,批次結束時的正確數字就是 26 / 17。

## 新增的介面

**無**。本 feature 只移除:

```haskell
-- Knot.Meta.Types:移除
data HieInfo
data HieDirSource
MetaOptions.hieDirOverride
ProjectMeta.pmHie

-- Knot.Meta.HieLocate:整個模組移除(locateHie、moduleNameFromHiePath)
```

## TodoList

- [ ] T1: `Knot.Meta.Types`——刪 `HieInfo` / `HieDirSource` 與匯出、`MetaOptions` 去 `hieDirOverride`、`ProjectMeta` 去 `pmHie`;`Knot.Extract.Types:37` haddock 去 `hieFiles` 一詞  `dep: -`
- [ ] T2: 刪 `src/Knot/Meta/HieLocate.hs`、`knot-hs.cabal` 去一列;`Knot.Meta.loadProjectMeta` 去 hie-locate 一站  `dep: T1`
- [ ] T3: `cabal build knot-hs:knot-internal` 通過(`src/` 零殘留引用)  `dep: T2`
- [ ] T4: 測試搬遷——刪 `f003Tests` 與輔助、刪兩個 fixture 目錄、刪 G-E001 T3、改寫 `defOpts` / `emptyMeta` / 六處記錄字面量 / 兩處 `pmHie` 斷言 / G-B002 的 `pmHie` 前置;守門計數 26 / 17  `dep: T3`
- [ ] T5: 共同閘門後收尾——F003 文檔 `status: closed`;閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0、`cabal test` 全綠(與 extraction/F007、export-query/F005 同批執行)  `dep: T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_meta_types_shape` | 以記錄語法建構 `MetaOptions { root = ".", includeTests = False }` 與 `ProjectMeta { pmPackages = [], pmSources = [], pmWarnings = [] }` 並斷言 `Eq` / `Show`(多一個欄位是 missing-fields 編譯錯誤,少一個欄位是 unknown-field 編譯錯誤);讀 `src/Knot/Meta/Types.hs` 的匯出清單,斷言不含 `HieInfo`、`HieDirSource`,全檔不含 `hieDirOverride`、`pmHie`;讀 `src/Knot/Extract/Types.hs` 斷言不含 `hieFiles` |
| T2 | `test_hie_locate_removed` | `src/Knot/Meta/HieLocate.hs` 不存在;`knot-hs.cabal` 的 `exposed-modules` 不含 `Knot.Meta.HieLocate`;`src/` 全域 grep 不得出現 `locateHie`、`HieLocate`、`moduleNameFromHiePath`;對 `no-cabal` 與 `comps` fixture 呼叫 `loadProjectMeta`,`pmWarnings` 與 `pmSources` 和改動前的 F001 / F002 既有斷言一致(F001 / F002 測試群組全綠即證明) |
| T3 | `test_cabal_contract_surface`(計數改寫) | `exposed` 27 → 26、`private` 18 → 17;`reexported-modules` 仍恰為九個契約模組。`knot-internal` 可編由 impl 收尾時的閘門證明 |
| T4 | F001 / F002 群組全綠 + `test_no_hie_residue` | 前者:`f001Tests` / `f002Tests` 所有既有測試在新 DTO 形狀下通過。後者:`test/Main.hs` 全檔 grep 不得出現 `f003Tests`、`locateHie`、`hieConvFixture`、`hieDistFixture`、`pmHie`、`hieDirOverride`、`HieInfo`;`test/fixtures/hie-conv/` 與 `test/fixtures/hie-dist/` 不存在 |
| T5 | 閘門(人工執行,結果記入實作備註) | `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0;`cabal test` 全綠;`.design/subsystems/project-meta/features/F003-hie-discovery.md` 的 `status: closed` |

## 實作備註

(撰寫時留空)
