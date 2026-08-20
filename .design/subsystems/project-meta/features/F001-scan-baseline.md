---
id: F001
type: feature
title: scan-baseline
description: 檔案樹掃描與大寫尾綴 module 對映,產出 S1 版 ProjectMeta
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: []
related-adr: [ADR-001]
related-feature: []
---

# F001: scan-baseline — S1 檔案樹掃描基線

## 功能概述

project-meta 子系統的第一個 feature,同時是全專案的第一個 feature:建立 knot-hs 專案骨架(cabal 專案、library、`knot` 執行檔、test-suite),並實作 S1 階段的 `loadProjectMeta` 管線——掃描 Haskell 專案的檔案樹、以大寫尾綴法推導 module 名、以路徑啟發式做 test/bench 排除,輸出僅 `pmSources` 與 `pmWarnings` 填實的 `ProjectMeta`。

**要解決的問題**:下游 extraction(import-scan)需要一份決定性的「哪些 `.hs` 檔、對應什麼 module、是否納入」清單才能開工;本 feature 提供這份清單的 S1 版本(不依賴 `.cabal` 解析與 `.hie`)。

**驗收標準**(來自契約卡;驗收標的皆絕對唯讀):

1. 對 particle-magic(`C:\Users\User\Documents\GameProjects\particle-magic`)與 MagicFarmer(`C:\Users\User\Documents\GameProjects\MagicFarmer`)執行 `knot` 摘要——列出全部 `.hs`,且 `dist-newstyle`、`.git` 內容不出現
2. `src/MagicFarmer/Render/Core.hs` 對映 `MagicFarmer.Render.Core`
3. `test/`、`bench/` 下檔案 `sfIncluded = False`,且 `includeTests = True` 時翻轉為 `True`
4. 連續執行兩次,輸出完全相同(決定性)

**明確不做**(契約卡底線):不解析 `.cabal` 內容(cabal-components 的事)、不碰 `.hie`(hie-discovery 的事)、不讀任何檔案內容、不處理多套件語意(僅回報找到的 `.cabal` 路徑)。

## 相依性

`depends-on: []`——本 feature 是專案第一個任務文檔,無任何文檔相依,亦無既有專案程式碼可依賴(repo 目前無原始碼)。所有既有串接介面均為 GHC 9.14.1 boot libraries(`base`、`directory`、`filepath`、`text`),簽名已於 2026-08-20 以 `ghc -e :t` 實測查證(見介面表)。測試框架 hedgehog + tasty 系列依委派決策 D2(solver 已實測在 GHC 9.14.1 無需 allow-newer 可解)。

可平行性:與其他子系統的未來任務可平行;本子系統階段二的 `F002`(cabal-components)、`F003`(hie-discovery)依賴本檔的骨架與 DTO,須排在本檔之後。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/project-meta/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 對外契約 `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | 完整實作進入點;S1 語意:`pmPackages` 恆為 `[]`、`pmHie` 恆為 `Nothing` |
| DTO `MetaOptions`、`ProjectMeta`、`SourceFile`、`MetaWarning` | 首次定義,欄位與 design.md「對外契約」原文一致 |
| 模組介面 `findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])` | 實作;本階段僅定位根目錄 `*.cabal`、不解析(`cabal.project` 多套件列表屬 F002) |
| 模組介面 `indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])` | 實作;S1 呼叫時 `[PackageMeta]` 恆為 `[]`,`sfOwners` 恆為 `[]` |
| 判定規則 3(S1 大寫尾綴法) | 實作:取路徑中最長的、每段皆大寫開頭的尾綴 |
| 判定規則 4(S1 路徑啟發式排除) | 實作:頂層 `test/`、`tests/`、`bench/` 排除,`includeTests = True` 翻轉 |
| 判定規則 7(決定性) | 實作:清單穩定排序,同輸入同輸出 |
| 資料流管線段落 | `MetaOptions` → discovery → source-index → `ProjectMeta`(僅 `pmSources`、`pmWarnings` 填實) |
| 錯誤策略(best-effort) | 讀不到的目錄降級為 `MetaWarning` + 部分結果,不中斷 |

未新增任何超出 Level 2 的公開介面;執行檔的摘要輸出函式放在 executable component 內部,不進 library 對外面(見「新增的介面」)。

## 實作方式

### 專案骨架(委派決策 D1、D3)

```text
knot-hs.cabal
cabal.project
src/Knot/Meta.hs               -- loadProjectMeta 進入點
src/Knot/Meta/Types.hs         -- 全部 DTO(共用 DTO 放契約所屬子系統,D3)
src/Knot/Meta/Discovery.hs     -- findCabalFiles
src/Knot/Meta/SourceIndex.hs   -- indexSources
app/Main.hs                    -- knot 執行檔:極簡參數解析 + 摘要
app/Knot/App/Summary.hs        -- renderMetaSummary(executable 內部模組)
test/Main.hs                   -- tasty 進入點
test/fixtures/…                -- 靜態測試 fixture(D5:fixture 建在 knot-hs 自己的 test 資源)
```

- `knot-hs.cabal`:`cabal-version: 3.4`(cabal-install 3.16 支援)、`default-language: GHC2024`、三個 component:
  - `library`:exposed `Knot.Meta`、`Knot.Meta.Types`、`Knot.Meta.Discovery`、`Knot.Meta.SourceIndex`;build-depends 僅 boot libs:`base ^>=4.22`、`directory`、`filepath`、`text`、`containers`
  - `executable knot`:`hs-source-dirs: app`,依賴 library;本階段只做極簡 `getArgs` 解析(位置參數 `PATH`,預設 `.`;旗標 `--include-tests`),印 `ProjectMeta` 摘要供驗收;完整 CLI 參數解析不做(D1)
  - `test-suite knot-test`:type `exitcode-stdio-1.0`,`hs-source-dirs: test, app`(共用 `app/` 讓摘要函式可測而不進 library 介面),build-depends 加 `tasty`、`tasty-hedgehog`、`hedgehog`、`tasty-hunit`(D2;若實編不過,fallback tasty+HUnit 並記入待確認假設)
- `cabal.project`:`packages: .`(單套件,建檔以固定 build 入口)
- 版本鎖:以 GHC 9.14.1 編譯(ADR-001);本階段不依賴 `ghc` library

### 資料流(S1 管線)

```text
MetaOptions { root, includeTests, hieDirOverride }
  → discovery:    findCabalFiles root
                    · listDirectory root,取副檔名 == ".cabal" 的檔案,穩定排序
                    · 找不到任何 .cabal → MetaWarning(root, "no .cabal file found"),繼續
                    · 找到的路徑 S1 不進 DTO(無承載欄位,見假設 A3),僅建立管線與警告
  → source-index: indexSources opts []
                    · DFS 走訪 root 檔案樹;每層 listDirectory 後排序(決定性)
                    · 略過目錄(依 basename):「.」開頭的隱藏目錄(涵蓋 .git、.stack-work、
                      .hie、.design)、dist-newstyle(D4 略過清單)
                    · 收集副檔名 == ".hs" 的檔案(不含 .lhs,見假設 A4)
                    · sfPath = 相對 root 的路徑,splitDirectories 後以 "/" 重組(正斜線,
                      Windows 反斜線在此一步消除;契約:repo 相對、正斜線)
                    · sfModule = 大寫尾綴法(下述);sfOwners = [];sfIncluded = 排除啟發式(下述)
                    · 讀不到的目錄(權限、symlink 斷鏈)→ MetaWarning + 跳過,不中斷
                    · 產出前 sortOn sfPath(碼位序)
  → 組裝 ProjectMeta { pmPackages = [], pmSources, pmHie = Nothing,
                       pmWarnings = discovery ++ source-index(蒐集順序即穩定順序)}
```

### 大寫尾綴法(判定規則 3 的 S1 實作)

純函數,不做 IO:

1. 取 `sfPath` 的路徑段(`splitDirectories`),末段以 `stripExtension "hs"` 去副檔名
2. 從尾端往前取**最長**的連續段序列,使每段非空且首字元 `Data.Char.isUpper`
3. 序列非空 → 以 `.` 連接為 module 名(如 `src/MagicFarmer/Render/Core.hs` → `MagicFarmer.Render.Core`;`app/Main.hs` → `Main`);末段(檔名主幹)本身非大寫開頭 → `Nothing`

### 排除啟發式(判定規則 4 的 S1 實作)

`sfPath` 的**第一個**路徑段 ∈ {`test`, `tests`, `bench`} 時視為排除:`sfIncluded = includeTests`;其餘檔案 `sfIncluded = True`。S2 起由 component 判定取代,對呼叫者透明。

### 決定性(判定規則 7)

- 每層 `listDirectory` 結果先排序再走訪;最終 `pmSources` 以 `sfPath` 碼位序排序
- 警告清單順序 = 固定的管線蒐集順序(discovery 先、source-index 後,各自內部依走訪序)
- 不讀 mtime、不用雜湊表迭代序,無任何非決定性來源

### 測試 fixture 策略(D5)

驗收標的專案絕對唯讀,單元測試不得依賴其存在;測試用靜態 fixture 建在 `test/fixtures/` 下(git 內、每個目錄至少放一個檔案以免空目錄不入版控),包含:正常 `src/` 樹、`dist-newstyle/` 與 `.git-like` 隱藏目錄內的誘餌 `.hs`(必須不出現)、頂層 `test/`/`bench/` 檔案、無 `.cabal` 的樹、有 `.cabal` 的樹。對 particle-magic 與 MagicFarmer 的驗收用 `knot` 執行檔手動執行,屬階段閘門驗收步驟,不寫成自動測試。

## 使用到的既有串接介面

(專案尚無自有程式碼;以下皆 GHC 9.14.1 boot libraries,簽名為 2026-08-20 於本機以 `ghc -e ':t …'` 讀出的原文;「來源檔案」填套件-版本)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `System.Directory.listDirectory :: FilePath -> IO [FilePath]` | directory-1.3.10.0 | - | 逐層列出目錄項目(檔案樹走訪、`.cabal` 定位) |
| `System.Directory.doesDirectoryExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | 走訪時分辨目錄與檔案 |
| `System.Directory.doesFileExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | root 有效性與 `.cabal` 候選確認 |
| `System.Directory.canonicalizePath :: FilePath -> IO FilePath` | directory-1.3.10.0 | - | 正規化 root,作為相對路徑基準 |
| `System.FilePath.takeExtension :: FilePath -> String` | filepath-1.5.4.0 | - | 篩 `.hs` 與 `.cabal` |
| `System.FilePath.stripExtension :: String -> FilePath -> Maybe FilePath` | filepath-1.5.4.0 | - | 去掉檔名 `.hs` 副檔名取 module 末段 |
| `System.FilePath.splitDirectories :: FilePath -> [FilePath]` | filepath-1.5.4.0 | - | 拆路徑段(正斜線重組、尾綴法、排除啟發式) |
| `System.FilePath.makeRelative :: FilePath -> FilePath -> FilePath` | filepath-1.5.4.0 | - | 絕對路徑 → repo 相對路徑 |
| `Data.List.sortOn :: Ord b => (a -> b) -> [a] -> [a]` | base-4.22(GHC 9.14.1) | - | 決定性排序(目錄項目、`pmSources`) |
| `Data.Char.isUpper :: Char -> Bool` | base-4.22(GHC 9.14.1) | - | 大寫尾綴法的段首判定 |

測試框架介面(`tasty`、`tasty-hedgehog`、`hedgehog`、`tasty-hunit`)為第三方套件,本機尚未安裝、無原始碼可讀,依 D2 的 solver 實測結果採用;非本 feature 定義之介面,不列入上表。

## 新增的介面

全部落在 Level 2 契約內(型別定義原文出自 design.md「對外契約」):

**`Knot.Meta`(對外契約進入點)**

```haskell
loadProjectMeta :: MetaOptions -> IO ProjectMeta
-- S1 語意:pmPackages = []、pmHie = Nothing;pmSources、pmWarnings 填實
```

**`Knot.Meta.Types`(DTO;D3:共用 DTO 放契約所屬子系統)**

```haskell
data MetaOptions = MetaOptions
  { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }

data ProjectMeta = ProjectMeta
  { pmPackages :: [PackageMeta], pmSources :: [SourceFile]
  , pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }

data SourceFile = SourceFile
  { sfPath :: FilePath, sfModule :: Maybe ModuleName
  , sfOwners :: [ComponentRef], sfIncluded :: Bool }

newtype ModuleName = ModuleName Text   -- 點分形式,如 "MagicFarmer.Render.Core"(假設 A1)

data MetaWarning = MetaWarning
  { mwPath :: FilePath, mwMessage :: Text }   -- 「帶來源路徑的警告」(假設 A2)
```

階段二 DTO(`PackageMeta`、`ComponentMeta`、`ComponentKind`、`ComponentRef`、`HieInfo`、`HieDirSource`)照 design.md 原文先行定義以讓 `ProjectMeta` 型別完整,本階段無任何邏輯觸碰(假設 A5)。所有 DTO deriving `Eq`、`Show`(`ModuleName` 加 `Ord`)。

**`Knot.Meta.Discovery`(Level 2 模組介面)**

```haskell
findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])
-- S1:僅定位根目錄 *.cabal(repo 相對、正斜線、排序);不解析、不讀 cabal.project
```

**`Knot.Meta.SourceIndex`(Level 2 模組介面)**

```haskell
indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])
-- S1:第二參數恆收 [];實作判定規則 3(大寫尾綴)、4(路徑啟發式)、7(決定性)
```

**executable 內部(不屬 library 對外介面,不進 Level 2 契約面)**

```haskell
-- app/Knot/App/Summary.hs(executable component 的 other-module;test-suite 共用原始碼目錄以便測試)
renderMetaSummary :: ProjectMeta -> Text
```

## TodoList

- [ ] T1: 專案骨架——`knot-hs.cabal`(library + `knot` executable + `knot-test` test-suite)、`cabal.project`,`cabal build all` 通過  `dep: -`
- [ ] T2: `Knot.Meta.Types` 全部 DTO 定義(S1 四個 + 階段二先行定義)  `dep: T1`
- [ ] T3: `Knot.Meta.Discovery.findCabalFiles`——根目錄 `*.cabal` 定位、無 `.cabal` 警告  `dep: T2`
- [ ] T4: source-index 檔案樹走訪——D4 略過清單、repo 相對正斜線路徑、僅收 `.hs`  `dep: T2`
- [ ] T5: 大寫尾綴 module 對映(純函數)  `dep: T2`
- [ ] T6: 路徑啟發式排除與 `includeTests` 翻轉  `dep: T2`
- [ ] T7: `indexSources` 組裝(T4+T5+T6)與決定性排序  `dep: T4, T5, T6`
- [ ] T8: `Knot.Meta.loadProjectMeta` 管線組裝(discovery → source-index、警告彙整、`pmPackages = []`、`pmHie = Nothing`)  `dep: T3, T7`
- [ ] T9: `knot` 執行檔——極簡 `getArgs` 解析(`PATH`、`--include-tests`)與 `renderMetaSummary` 摘要輸出  `dep: T8`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_smoke_build | test-suite 內最小 smoke case;tasty 能執行即證明三 component 骨架成立 |
| T2 | test_types_construct | HUnit 建構空骨架 `ProjectMeta`(`pmPackages = []`、`pmHie = Nothing`)並驗證各欄位值 |
| T3 | test_find_cabal_files | fixture 兩情境:有 `.cabal` → 回報正斜線相對路徑;無 `.cabal` → 空清單 + 一則警告 |
| T4 | test_scan_tree | fixture 樹含 `dist-newstyle`、隱藏目錄內誘餌 `.hs` 與 `.txt` 干擾檔;驗證誘餌不出現、路徑皆 repo 相對正斜線、僅 `.hs` 入列 |
| T5 | test_module_suffix | HUnit 例:`src/MagicFarmer/Render/Core.hs` → `MagicFarmer.Render.Core`、`app/Main.hs` → `Main`、全小寫路徑 → `Nothing`;hedgehog property:任意小寫前綴段不改變推導結果 |
| T6 | test_exclusion_toggle | 同一 fixture 以 `includeTests = False/True` 各跑一次:頂層 `test/`、`tests/`、`bench/` 檔案 `sfIncluded` 由 `False` 翻轉為 `True`,其餘檔案恆 `True` |
| T7 | test_index_deterministic | 對 fixture 連續執行兩次 `indexSources`,結果完全相等,且 `sfPath` 嚴格遞增(排序穩定) |
| T8 | test_load_project_meta | 對 fixture 執行 `loadProjectMeta`:`pmPackages = []`、`pmHie = Nothing`、`pmSources` 與 `pmWarnings` 符合預期 |
| T9 | test_render_summary | 對已知 `ProjectMeta` 值驗證 `renderMetaSummary` 摘要文字(檔案數、module 對映數、排除數、警告數) |

## 待確認假設

- A1: `ModuleName` 在 Level 2 只出現於 `sfModule :: Maybe ModuleName`、未給定義 → 採取:`newtype ModuleName = ModuleName Text`,值為點分形式 → 影響:若編排者裁定用 `[Text]` 段列表或裸 `Text`,改 `Knot.Meta.Types` 與下游用法
- A2: `MetaWarning` 在 Level 2 僅描述為「帶來源路徑的警告」→ 採取:`MetaWarning { mwPath :: FilePath, mwMessage :: Text }` → 影響:F002/F003 若需結構化警告類別,擴充此型別(屬契約層,需回報)
- A3: 契約卡要求「回報找到的 `.cabal` 路徑」,但 S1 的 `ProjectMeta` 無承載欄位(`pmPackages` 恆空)→ 採取:`findCabalFiles` 回傳值在 S1 僅用於「找不到 `.cabal`」警告,找到的路徑不進 DTO,F002 起交 `resolvePackage` → 影響:若編排者要 S1 就露出路徑,需在 Level 2 加欄位(契約變更)
- A4: 契約卡驗收只提 `.hs` → 採取:只收 `.hs`,不含 `.lhs` → 影響:若要支援 literate Haskell,改 source-index 副檔名判定與大寫尾綴法去副檔名一步
- A5: 階段二 DTO(`PackageMeta` 等)本階段就照 design.md 原文定義(否則 `ProjectMeta` 型別不完整)→ 採取:先行定義、零邏輯 → 影響:F002/F003 若需改欄位屬 Level 2 契約變更,走編排者
- A6: D1 說完整 CLI 參數解析不做,但驗收需要對真實專案翻轉 `includeTests` → 採取:`knot` 以手寫 `getArgs` 支援位置參數 `PATH` 與旗標 `--include-tests` 兩項,不引入解析套件 → 影響:後續正式 CLI feature 以正式解析器取代,語意不變

## 實作備註

(開發過程中與設計的偏差記錄於此,撰寫時留空)
