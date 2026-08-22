---
id: F005
type: feature
title: build-driver
description: 自行驅動目標專案的插樁建置,產出每 component 分目錄的 .hie
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, project-meta/F001, project-meta/F002]
related-adr: [ADR-006, ADR-001]
related-feature: []
---

# F005: build-driver — 自驅動插樁建置

## 功能概述

ADR-006 的第一塊落地:`knot extract` 不再要求使用者自己產 `.hie`,由 extraction 的 build-driver **對目標專案執行一次插樁建置**,產物全部落在 `<root>/.knot/build/`,不碰對方既有的 `dist-newstyle`。

**要解決的問題**:S1–S4 的 knot 在別人的專案上幾乎不可用——使用者得先 `cabal build --ghc-options="-fwrite-ide-info -hiedir .hie"`,而且 exe 與 test-suite 的 `Main.hie` 會互相覆蓋(G-B001)。本 feature 把那個命令收進 knot,並讓每個 component 的 `.hie` 天然分目錄。

**驗收標準**(契約卡原文逐條對照,手段依 spike 結果修正,見「實作方式」):

| # | 契約卡 | 落地 | 測試 |
|---|---|---|---|
| 1 | `.knot/build/`、每 component 分目錄的 `.hie`、`.knot/.gitignore`(內容 `*`)三者存在 | `.knot/build/…/<kind>/<comp>/…/extra-compilation-artifacts/hie/*.hie`;`.gitignore` 在首次建目錄時寫入 | T6 |
| 2 | 對方的 `dist-newstyle/` 位元組級不變 | `--builddir` 指向 `.knot/build`,cabal 不碰預設 builddir;以 `dist-newstyle/cache/plan.json` 的 mtime 與大小前後比對 | T6 |
| 3 | `hlFiles` 每筆的 component 與其 `.hie` 所在子目錄一致 | `ComponentRef` 由 cabal 的固定佈局路徑推得(T4) | T4 |
| 4 | `exe:knot` 與 `test:knot-test` 的 `Main.hie` 落在不同目錄、兩份都存在 | spike 2 已實證(`x/knot/…` 與 `t/knot-test/…`) | T6 |
| 5 | 第二次執行明顯快於第一次 | spike 2:首次 41.2 s → 零變更 **247 ms**(cabal 增量) | T6 |
| 6 | 故意讓某個 component 編不過 → `BuildFailed` 且 `bfComponent` 指名、`bfDetail` 含 cabal 錯誤訊息 | fixture 專案含一個故意編不過的 executable | T3 |
| 7 | `compExcluded = True` 的 component 不被建置 | 不帶 `--enable-tests` 時 cabal 的 `all` 目標本來就不含 test-suite;T6 斷言 `t/` 下無 `.hie` | T6 |

## 相依性

`depends-on: [F001, project-meta/F001, project-meta/F002]`,全部由「使用到的既有串接介面」表反推,三份皆 `done`、程式碼在 `main`,是**既有程式碼查證**而非文檔約定:

- **`F001` fact-contract(同子系統)**:`ExtractOptions.rootDir`(`src/Knot/Extract/Types.hs`)是 `.knot/` 與 cabal `cwd` 的錨點。S5 的 two-layer-contract(#7)會把 `ExtractOptions` 收斂成只剩 `rootDir`,本 feature**只碰 `rootDir`**,兩種形狀下都成立
- **`project-meta/F001` scan-baseline**:`ProjectMeta.pmPackages`(`src/Knot/Meta/Types.hs`)是「要建哪些 component」的唯一來源
- **`project-meta/F002` cabal-components**:`PackageMeta` / `ComponentMeta` / `ComponentKind` / `ComponentRef`——`compKind` 與 `compExcluded` 決定要不要帶 `--enable-tests` / `--enable-benchmarks`;`ComponentRef` 是 `HieLayout.hlFiles` 的鍵

**可平行性**:與同階段的 `#6 hiedb-embed` **可平行**——`HieLayout` 的形狀已在 `design.md` 定死,#6 可先以手寫的 `HieLayout` 測試;#6 要實際串接本 feature 的 `ensureHie` 時本 feature 須已 done。與 `#7 two-layer-contract` 不可平行(它要刪 `ExtractOptions` 的欄位,本 feature 的程式碼落在它之前)。與 graph-core / export-query 的任何任務可平行。

**不列入的相依**:`export-query/F001`(`Knot.Export.Commit` 的 `readCreateProcessWithExitCode` + `cwd` 範式)——只是**寫法參考**,本 feature 不呼叫它;`System.Process` 是 base 生態的 library,不是專案介面。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)` | 新增,簽名一字不差 |
| DTO `HieLayout { hlRoot, hlFiles }` | 新增;`hlRoot` 依本次修正的規則 7 為 `<root>/.knot/build` |
| DTO `ExtractFailure` 的 `BuildFailed { bfComponent, bfDetail }` | 新增。**整個 `ExtractFailure` 型別(四建構子)由本 feature 定義**——Haskell 的 sum type 不能分次加建構子;`VersionMismatch` / `IndexFailed` / `NoSources` 零邏輯,留給 #6 / #7 使用 |
| 抽取規則 5(插樁建置由 extraction 驅動、增量交給 cabal、失敗不 fallback) | 每次呼叫都跑 `cabal build`;不做 mtime 比對;非零 exit → `BuildFailed` |
| 抽取規則 6(每 component 一個 `.hie` 目錄) | 由 cabal 的 per-component 輸出目錄承載(本次修正的手段,見「實作方式」) |
| 抽取規則 7(`.knot/` 佈局、自建 `.gitignore`、不改道) | `.knot/build/` + `.knot/.gitignore`;無任何改道參數 |
| 「使用的技術 › 目標專案的 cabal(透過 process 呼叫)」 | 唯一的外部程序;`--builddir` 隔離 |

**未觸碰**:規則 8(版本檢查,#6)、規則 9(單檔 best-effort,hie-facts)、`ensureIndex` / `readIndexFacts`、`extract` 進入點(#7)。

## 實作方式

### 為什麼不是契約卡原本寫的「每 component 各自 `-hiedir`」

2026-08-22 spike(knot-hs 自身,3 個 component):

| 作法 | 零變更重跑 | 原因 |
|---|---|---|
| 逐 component 呼叫 `cabal build`,各帶不同 `-hiedir` | **每次全量**(26 模組、9.2 s),且 lib 在兩組旗標間 ping-pong | `--ghc-options` 進 cabal 的組態雜湊,換旗標 = 組態變更 = 重編 |
| **一次 `cabal build all`,只帶 `-fwrite-ide-info`,不帶 `-hiedir`** | **247 ms、0 模組** | 旗標恆定;GHC 沒給 `-hiedir` 就把 `.hie` 寫在 `.hi` 旁,而 cabal 本來就替每個 component 準備獨立的輸出目錄 |

後者實測 `.hie` 落點(相對 builddir):

```
build/<arch>/<ghc>/<pkg>-<ver>/l/knot-internal/build/knot-internal/extra-compilation-artifacts/hie/…   26 個
build/<arch>/<ghc>/<pkg>-<ver>/x/knot/build/knot/knot-tmp/extra-compilation-artifacts/hie/Main.hie       5 個
build/<arch>/<ghc>/<pkg>-<ver>/t/knot-test/build/knot-test/knot-test-tmp/extra-compilation-artifacts/hie/Main.hie  5 個
```

**兩份 `Main.hie` 各在自己的目錄**——規則 6 的保證成立,只是由 cabal 提供而非 knot 指定。`extra-compilation-artifacts/hie/` 是 cabal 3.10 起對 `-fwrite-ide-info` 產物的固定安置位置。

### 資料流

```
ExtractOptions.rootDir + ProjectMeta.pmPackages
  │
  ├─ 1. 準備 .knot/:建 <root>/.knot/、寫 .gitignore(內容 "*",已存在則不動)——冪等
  │
  ├─ 2. 組 cabal 命令:
  │      cabal build all --builddir=<root>/.knot/build --ghc-options=-fwrite-ide-info
  │        [--enable-tests]       ← pmPackages 中任一 TestSuite 的 compExcluded = False
  │        [--enable-benchmarks]  ← 同上,Benchmark
  │      cwd = <root>;不走 shell(proc,免 quoting);builddir 用絕對路徑
  │
  ├─ 3. 執行並轉發:stdout / stderr 逐行即時寫到 knot 自己的 stderr,同時保留最後 N 行
  │      exit ≠ 0 → Left (BuildFailed { bfComponent = 解析 cabal 的 "Failed to build <unit>" 行,
  │                                      解析不到則 "all";  bfDetail = 尾段 })
  │      cabal 不在 PATH / 啟動失敗(IOException)→ Left (BuildFailed "all" <例外文字>)
  │
  └─ 4. 列舉 HieLayout:走訪 <root>/.knot/build 收 *.hie
         每個路徑 → ComponentRef:
           …/<pkg>-<ver>/x/<name>/… → (pkg, "exe:"   <> name)
           …/<pkg>-<ver>/t/<name>/… → (pkg, "test:"  <> name)
           …/<pkg>-<ver>/b/<name>/… → (pkg, "bench:" <> name)
           …/<pkg>-<ver>/f/<name>/… → (pkg, "flib:"  <> name)
           …/<pkg>-<ver>/l/<name>/… → (pkg, "lib:"   <> name)
           …/<pkg>-<ver>/build/…   → (pkg, "lib:"   <> pkg)     ← 主 library 沒有 kind 段
         pkg 以 pmPackages 的 pkgName 做最長前綴比對(去掉 -<ver>)
         → Right HieLayout { hlRoot = <root>/.knot/build, hlFiles 依路徑碼位序 }
```

`compName` 的前綴格式以 project-meta F002 的 A3 裁決為準(`lib:` / `exe:` / `flib:` / `test:` / `bench:`),本 feature 組出的 `ComponentRef` 要與 `pmPackages` 裡的 `compName` **逐字相等**,下游(#6 版本檢查、hie-facts 對映)才能直接拿它當鍵。

### 幾個刻意的選擇

- **每次都呼叫 cabal,不自己判新鮮度**(規則 5):cabal 用內容雜湊,沒改動時 247 ms。knot 自己比 mtime 會漏掉 `.cabal` 改動、旗標改動、相依升版
- **`--enable-tests` 只在有納入的 test component 時才帶**:帶與不帶是兩個組態,切換會讓 cabal 重新設定。但那是使用者改了 `--include-tests` 才會發生,不是每次跑
- **轉發子程序輸出到 stderr**:這不是 library 自己印訊息(L2「不印」的對象是警告與報告,那些仍由 CLI 層印),是讓使用者看得到一個可能跑幾分鐘的建置在動。L2 規則 5 本次補了這句例外
- **`bfComponent` 解析失敗就填 `"all"`**:cabal 的錯誤訊息格式(`Failed to build exe:knot from knot-hs-0.0.1.0`)不是契約,解析只是盡力;`bfDetail` 的尾段永遠在,使用者不會拿不到資訊
- **路徑對不上 `pmPackages` 的 `.hie` 照樣列進 `hlFiles`**(`ComponentRef` 純由路徑推得):它們屬於 project-meta 沒解析到的套件(那已在 `pmWarnings`),其 `hs_src` 也不會在 `pmSources`,規則 9 會在 hie-facts 以警告丟棄。`ensureHie` 的簽名沒有警告通道,不在這裡發明一個
- **不清理 `.knot/build/` 裡過期的 `.hie`**(模組已刪、舊檔還在):同上,規則 9 處理;cabal 自己也不清舊產物

### 錯誤處理

| 情況 | 結果 |
|---|---|
| `cabal` 找不到 / 無法啟動 | `Left (BuildFailed "all" "…")`,訊息指明是 cabal 本身 |
| cabal exit ≠ 0 | `Left (BuildFailed <unit 或 all> <尾段>)` |
| `.knot/` 建不出來(權限) | `Left (BuildFailed "all" "…")`——沒有 builddir 就不可能建 |
| `pmPackages` 為空 | 照樣呼叫 cabal,讓它自己報「no cabal file」→ `BuildFailed`;不另設判斷 |
| 建置成功但 `.knot/build` 下零個 `.hie` | `Right` 回空 `hlFiles`;#6 的 `ensureIndex` 收到空清單時回 `IndexFailed`——不在本 feature 判 |

全部 `IOException` 在 `ensureHie` 內收斂成 `Left`,不往上拋。

## 使用到的既有串接介面

每一列的簽名均為 2026-08-22 從來源檔案讀出的原文。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | `src/Knot/Extract/Types.hs` | F001 | 只取 `rootDir`(#7 會把其餘三欄刪掉,本 feature 不碰它們) |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | `src/Knot/Meta/Types.hs` | project-meta/F001 | 只取 `pmPackages`(`pmHie` 由 project-meta #4 移除,本 feature 不碰) |
| `data PackageMeta = PackageMeta { pkgName :: Text, pkgCabalFile :: FilePath, pkgComponents :: [ComponentMeta] }` | `src/Knot/Meta/Types.hs` | project-meta/F002 | `pkgName` 做路徑 → `ComponentRef` 的套件比對;`pkgComponents` 決定 `--enable-*` |
| `data ComponentMeta = ComponentMeta { compName :: Text, compKind :: ComponentKind, compSourceDirs :: [FilePath], compExcluded :: Bool }` | `src/Knot/Meta/Types.hs` | project-meta/F002 | `compKind` + `compExcluded` → 要不要帶 `--enable-tests` / `--enable-benchmarks` |
| `data ComponentKind = MainLibrary \| NamedLibrary \| Executable \| ForeignLibrary \| TestSuite \| Benchmark` | `src/Knot/Meta/Types.hs` | project-meta/F002 | 同上 |
| `newtype ComponentRef = ComponentRef (Text, Text)` | `src/Knot/Meta/Types.hs` | project-meta/F002 | `HieLayout.hlFiles` 的鍵 |

## 新增的介面

全部落在 `design.md`「模組間公開介面」與「對外契約」已定義的條目內,簽名一字不差:

```haskell
-- Knot.Extract.Types(對外契約 DTO)
data ExtractFailure
  = BuildFailed      { bfComponent :: Text, bfDetail :: Text }
  | VersionMismatch  { vmHie :: Text, vmKnot :: Text }          -- 本 feature 只定義,不產生(#6)
  | IndexFailed      { ifDetail :: Text }                        -- 同上(#6)
  | NoSources                                                    -- 同上(#7)
  deriving (Eq, Show)

-- Knot.Extract.Types(模組間 DTO;ComponentRef 依 ADR-005 附帶義務由本模組 re-export)
data HieLayout = HieLayout
  { hlRoot  :: FilePath                       -- <root>/.knot/build
  , hlFiles :: [(ComponentRef, FilePath)]     -- repo 相對正斜線,依路徑碼位序
  }
  deriving (Eq, Show)

-- Knot.Extract.BuildDriver(模組介面)
ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)
```

新模組 `Knot.Extract.BuildDriver` 加入 `knot-internal` 的 `exposed-modules`;**不**進公開 library 的 `reexported-modules`(它是模組間介面,不是對外契約;ADR-004)。

## TodoList

- [x] T1: `Knot.Extract.Types` 新增 `ExtractFailure`(四建構子)與 `HieLayout`,re-export `ComponentRef`;`knot-hs.cabal` 的 `knot-internal` 加 `Knot.Extract.BuildDriver`  `dep: -`
- [x] T2: `.knot/` 準備——建目錄、寫 `.gitignore`(內容 `*`,已存在不覆寫),冪等  `dep: T1`
- [x] T3: cabal 呼叫——依 `pmPackages` 組 argv(`all` / `--enable-tests` / `--enable-benchmarks` / `--builddir` / `--ghc-options=-fwrite-ide-info`)、`cwd` 釘在 `rootDir`、不走 shell;輸出逐行轉發到 stderr 並保留尾段;exit ≠ 0 / `IOException` → `BuildFailed`,`bfComponent` 盡力解析  `dep: T1`
- [x] T4: `HieLayout` 列舉——走訪 builddir 收 `*.hie`,cabal 佈局路徑 → `ComponentRef`(六種 kind 段 + 主 library),`pkgName` 最長前綴比對,依路徑碼位序  `dep: T1`
- [x] T5: `ensureHie` 組裝 T2 → T3 → T4,全部 `IOException` 收斂成 `Left`  `dep: T2, T3, T4`
- [x] T6: 對 knot-hs 自身的唯讀 selfcheck:`.knot/build/`、`.knot/.gitignore`、兩份 `Main.hie` 分目錄、對方 `dist-newstyle/cache/plan.json` mtime 與大小不變、第二次呼叫快於第一次、不帶 `--include-tests` 時 `t/` 下無 `.hie`  `dep: T5`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_build_driver_types_construct` | 建構 `ExtractFailure` 四建構子並比對欄位;`HieLayout` 建值與 `Eq`;從 `Knot.Extract.Types` 單獨 import `ComponentRef` 可編譯(re-export 成立) |
| T2 | `test_knot_dir_prepare` | 在臨時目錄呼叫兩次:第一次後 `.knot/.gitignore` 存在且內容為 `*`;先手動改寫 `.gitignore` 內容再呼叫第二次,內容**不被覆寫** |
| T3 | `test_cabal_invocation` | (a) argv 組裝為純函數可直接斷言:無納入 test/bench → 不帶 `--enable-*`;有納入 `TestSuite` → 帶 `--enable-tests`;有 `Benchmark` → 帶 `--enable-benchmarks`;(b) 對一個故意編不過的 fixture 專案(`test/fixtures/broken-build/`,含一個引用不存在符號的 executable)執行 → `Left (BuildFailed c d)`,`c` 含該 executable 名或為 `"all"`,`d` 含 cabal 的錯誤文字;(c) `cabal` 指向不存在路徑時(以 `PATH` 清空模擬)→ `BuildFailed` 且訊息指明 cabal |
| T4 | `test_hie_layout_enumeration` | 以手建的假 builddir(只放空的 `*.hie` 檔在 cabal 佈局位置)驗證六種 kind 段與主 library 各自對映到正確的 `ComponentRef`;`pkg-1.2.3` 去版號對上 `pmPackages` 的 `pkg`;結果依路徑碼位序;同輸入兩次相同 |
| T5 | `test_ensure_hie_pipeline` | 對 `test/fixtures/graph/`(可建置的小專案)執行 `ensureHie` → `Right`,`hlFiles` 非空且每筆路徑以 `.knot/build/` 開頭、副檔名 `.hie`;對 `test/fixtures/no-cabal/` → `Left BuildFailed` |
| T6 | `test_build_driver_selfcheck` | 對 knot-hs 自身執行,逐條斷言驗收標準 1、2、4、5、7(見「功能概述」表);比照既有 selfcheck 慣例印摘要行;`.knot/` 在測試結束後移除(它在本 repo 被 `.gitignore` 排除,但測試不該留殘骸) |

## 實作備註

### 結果(2026-08-22)

| 驗收標準 | 實測 |
|---|---|
| 1 `.knot/build/`、分目錄 `.hie`、`.gitignore` | 三者皆在;`.gitignore` 內容 `*`,第二次呼叫不覆寫 |
| 2 對方 `dist-newstyle` 不變 | `plan.json` 的 mtime + 大小前後相等 |
| 3 `hlFiles` 的 component 與路徑一致 | 六種 kind 段 + 主 library 的對映全部由純函數測試釘住 |
| 4 兩份 `Main.hie` 分目錄 | `--include-tests` 下 `exe:knot` 與 `test:knot-test` 各一份,目錄不同 |
| 5 第二次明顯快 | knot-hs 自身:**首次 19.5 s → 第二次 136 ms**;`.hie` 32 個(不含 test)/ 37 個(含 test) |
| 6 編不過 → `BuildFailed` | broken-build fixture 4.3 s 內回 `Left`,`bfDetail` 含 cabal 錯誤文字 |
| 7 排除的 component 不建 | 不帶 `--include-tests` 時無任何 `test:` 的 `.hie` |

測試 155 → **161** 全綠;閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0。

### 與設計的偏差

1. **輸出轉發的實作改為單一 pipe、單一讀者**(設計寫「逐行轉發」沒指定機制)。第一版用
   `CreatePipe` × 2 + `forkIO` 兩個 pump,**在非 `-threaded` RTS 下死鎖**:`waitForProcess`
   是 blocking 的 safe FFI call,會凍結所有 green thread,pump 跑不了、pipe 塞滿、cabal
   寫不出去就永遠不結束(實測 10 分鐘沒回來)。改為 `createPipe` + `hDuplicate` 把 stdout
   與 stderr 併進同一條 pipe,主執行緒 drain 到 EOF **之後**才 `waitForProcess`——與既有
   `readCreateProcessWithExitCode` 能用的原因相同(先 drain 再 wait)。尾段因此混合兩股
   輸出,`failedUnitOf` 的解析不受影響
2. **T5 改用新 fixture `test/fixtures/buildable/`**,不用設計寫的 `graph`。`graph` fixture
   本來就不可建置(`Demo/Core.hs` import `Data.Text` 卻沒列 `text` 相依;`app/Main.hs`
   import 自己)——它是 import-scan 的測試材料,五份黃金檔釘著它的 import 行,不能改。
   T5 的失敗案例改用 repo 外的空暫存目錄,理由見下一條
3. **fixture 必須自帶 `cabal.project`**。沒有的話 cabal 從 fixture 目錄往上找到 knot-hs
   自己的 `cabal.project`,`cabal build all` 就在 fixture 的 builddir 裡**建整個 knot-hs**
   (實測:`broken-build/.knot/build/…/knot-hs-0.0.1.0/`)。`broken-build` 與 `buildable`
   都補了 `packages: .`。這對真實目標專案不是問題(它們自己就是專案根),但對「子目錄當
   專案」的情境是個要知道的 cabal 行為,已記進 T5 的註解
4. **G-E001 的公開面守門測試計數更新**:`knot-internal` 26 → 27、私有模組 17 → 18
   (新增 `Knot.Extract.BuildDriver`,依設計不進 `reexported-modules`)。這是該測試的
   預期用途,不是放寬

### 實作自主權範圍內的選擇(不算偏差)

- 尾段保留 40 行;`bfDetail` 首行固定為 `cabal exited with <code>`
- `enumerateHie` 走訪 builddir 全樹收 `*.hie`,不假設 `extra-compilation-artifacts/hie/`
  這個中間層(cabal 版本可能變),component 只看前五段
- `componentRefOf` 對段數不足的路徑回 `ComponentRef ("", "")`,不拋例外

- **2026-08-22(F006 追加)**:`cabalArgs` 多一個 `rootAbs` 參數並帶 `--project-dir=<root>`,理由與實測見 F006 實作備註 1;`test_cabal_invocation` 的期望同步。
