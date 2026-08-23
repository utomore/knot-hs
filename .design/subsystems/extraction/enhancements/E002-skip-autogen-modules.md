---
id: E002
type: enhance
title: skip-autogen-modules
description: cabal 自動產生的 Paths_* / PackageInfo_* module 靜默跳過,不再逐站發 cannot map 警告
status: open
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: []
related-feature: [F004, F008, B002]
---

# E002: autogen module(`Paths_*` / `PackageInfo_*`)靜默跳過

## 現況分析

extraction/E001 與 B002 修完後,story-flow 與 MagicFarmer 各剩**恰好 2 則**警告,
內容一模一樣:

```
extract: …/storyflow-types-0.1.0.0/build/extra-compilation-artifacts/hie/Paths_storyflow_types.hie:
  cannot map indexed module Paths_storyflow_types back to pmSources; skipping its decls and refs
extract: …(同一檔)cannot map indexed module Paths_storyflow_types back to pmSources; skipping its instances
```

`Paths_<pkg>` 是 cabal 替每個套件自動產生的 module(`getDataDir`、`version` 等),
`PackageInfo_<pkg>` 是 3.12 起的另一個。它們:

- **不是**使用者寫的原始碼——`.hs` 在 cabal 的 `autogen/` 目錄,不在 `hs-source-dirs`,
  所以 project-meta 的 `pmSources` 永遠沒有它(正確:它不該進圖)
- 只要 `.cabal` 把它列進 `other-modules` / `autogen-modules`(story-flow 的
  `types/storyflow-types.cabal:32-34`、MagicFarmer 的 `magic-farmer.cabal:106-107`),GHC 就會
  編它、`-fwrite-ide-info` 就會寫出它的 `.hie`,hie-index 照樣索引
- 到了 hie-facts(`src/Knot/Extract/HiedbFacts.hs:265-275` `buildModIndex`)與 hie-instances
  (`src/Knot/Extract/HieInstances.hs:97-101`),`resolveModuleSourceFor` 對不回 `pmSources`
  → 依規則 9 各發一則「cannot map」警告

規則 9 的警告是為「**應該**對得回卻對不回」的情況設計的(過期的 `.hie`、大小寫 /
symlink 走樣);autogen module 是「**本來就不該**對回」,發警告只會讓 `--strict` 在每個
列了 `Paths_*` 的專案上永遠 exit 1,也把真警告淹掉。`buildModIndex` 已經對
`.hs-boot`(`mrIsBoot`)做了同樣的「靜默略過」,autogen 是同一類。

## Scope(涵蓋範圍)

**動**(全部在 extraction 內):

- hie-facts:新增純函數 `isAutogenModule :: [PackageMeta] -> ModuleName -> Bool`(非契約面,
  與 `resolveModuleSourceFor` 同模組,供 hie-instances 共用);`buildModIndex` 對 autogen
  module 比照 `mrIsBoot` 靜默略過
- hie-instances:讀到 autogen module 的 `.hie` 時回 `([], [])`,不警告
- 抽取規則 9(Level 2,回填 `design.md`):加一句「cabal autogen module(`Paths_<pkg>`、
  `PackageInfo_<pkg>`)不在 `pmSources` 是設計使然,靜默跳過、不計警告」
- 新 fixture `test/fixtures/autogen/`(library 列 `Paths_autogen` 進 `other-modules` /
  `autogen-modules` 並真的 import 它)

**明確不動**:

- `resolveModuleSource` / `resolveModuleSourceFor`(對映邏輯不變,跳過發生在對映之前)
- hie-index(索引照建;autogen 的 `.hie` 留在索引裡無害,`defs` / `refs` 只會被
  `buildModIndex` 認不得而忽略——既有行為)
- build-driver、project-meta(不把 autogen 塞進 `pmSources`:它不是原始碼)
- 判定只認 cabal 的兩個固定前綴 + **本專案套件名**(`-` → `_`);不對任何其他 `Paths_`
  開頭的使用者 module 生效

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| story-flow `knot extract` extraction 警告 | 2(`Paths_storyflow_types` ×2) | **0**;節點 / 邊數不變 |
| MagicFarmer | 2(`Paths_magic_farmer` ×2) | **0** |
| `autogen` fixture | 2 則 `cannot map` | **0**;`erFacts` 無任何 `Paths_autogen` 的事實;使用者 module 對 `Paths_autogen.version` 的引用仍以「指向外部目標」處理(graph-core 丟棄計入 `gsDroppedExternal`),與現行相同 |
| 使用者自己的 `Paths_Foo` module(非 autogen) | 正常入圖 | 不受影響(套件名不符就不是 autogen) |
| 測試 | 167 綠 | 167 + 本文檔新增 綠;黃金檔 byte 不變 |

## 相依性

`depends-on: []`。B002 已 done(本文檔沿用它的 `resolveModuleSourceFor` 所在模組與
`multi-exe` 的 fixture 寫法);與其他進行中任務無關。

## 改善方案

```haskell
-- hie-facts(非契約面)
isAutogenModule :: [PackageMeta] -> ModuleName -> Bool
isAutogenModule pkgs (ModuleName m) =
  any (\p -> m `elem` [T.pack "Paths_" <> slug p, T.pack "PackageInfo_" <> slug p]) pkgs
 where slug = T.map (\c -> if c == '-' then '_' else c) . pkgName
```

- `buildModIndex` 的 `step`:`| mrIsBoot r || isAutogenModule (pmPackages pm) modName = acc`
- `HieInstances.readOne`:解出 `modName` 後先判 autogen → `pure ([], [])`
- 規則 9 回填

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `buildModIndex :: ProjectMeta -> (Text -> Maybe Text) -> [ModRow] -> (Map Text ModEntry, [ExtractWarning])`;`data ModRow = ModRow { mrHieFile :: Text, mrModule :: Text, mrHsSrc :: Maybe Text, mrIsBoot :: Bool }` | `src/Knot/Extract/HiedbFacts.hs:257-275`、`:199-204` | F004、B002 | 靜默略過的插入點 |
| `readInstanceFacts :: ExtractOptions -> HieLayout -> ProjectMeta -> IO ([Fact], [ExtractWarning])`(內部 `readOne`) | `src/Knot/Extract/HieInstances.hs:77-103` | F008 | 同上 |
| `data PackageMeta = PackageMeta { pkgName :: Text, pkgCabalFile :: FilePath, pkgComponents :: [ComponentMeta] }` | `src/Knot/Meta/Types.hs` | project-meta/F002 | 套件名 → autogen module 名 |

## 介面變動

無簽名變動;新增非契約面純函數 `isAutogenModule`。Level 2 文字變動:規則 9 加一句。

## TodoList

- [ ] T1: `isAutogenModule` + `buildModIndex` 靜默略過  `dep: -`
- [ ] T2: hie-instances 靜默略過  `dep: T1`
- [ ] T3: fixture `test/fixtures/autogen/` 端到端、規則 9 回填、story-flow / MagicFarmer 實跑 2 → 0 寫進 system.md  `dep: T2`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e002_is_autogen_module` | 套件 `story-flow` → `Paths_story_flow`、`PackageInfo_story_flow` 為 True;`Paths_other`、`Paths_Foo`(使用者自取)、`StoryFlow.Paths` 為 False;空套件清單恆 False |
| T2 | `test_e002_instances_skip_autogen` | `autogen` fixture 暫存副本:`readInstanceFacts` 零警告 |
| T3 | `test_e002_autogen_end_to_end` + 既有 `test_codegraph_output_unchanged` | `extract` → `Right`、`erWarnings = []`、無 `Paths_autogen` 的 `FactDecl` / `FactModule`;使用者 module 的 `FactDecl` 正常;`design.md` 規則 9 含「autogen」;黃金檔不變 |

## 實作備註

(撰寫時留空。)
