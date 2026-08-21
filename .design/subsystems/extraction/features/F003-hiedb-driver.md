---
id: F003
type: feature
title: hiedb-driver
description: 探測 hiedb 執行檔與 .hie 相容性並建好可重用的 SQLite 索引
status: done
created: 2026-08-21
updated: 2026-08-22
depends-on: [F001, F002, project-meta/F001, project-meta/F003]
related-adr: [ADR-001, ADR-002]
related-feature: []
---

# F003: hiedb-driver — hiedb 探測、相容檢查與索引就緒

## 功能概述

extraction 階段二的**第一半**:把「外部 `hiedb` 執行檔 + `pmHie` 的 `.hie` 清單」轉成一個**就緒的索引**,交給 `F004`(hiedb-facts)去讀。本 feature 負責 `Backend` hiedb 實例的**探測面**(`bProbe`)與模組介面 `ensureIndex` / `IndexHandle`,不讀索引內容、不產任何 `Fact`。

**要解決的問題**:ADR-002 把函式級能力外包給 `hiedb` 執行檔,代價是引入一個「可能沒裝、可能版本不合、可能跑到一半炸掉」的外部依賴。本 feature 是這層風險的**唯一收容處**——把三種失敗都轉成結構化的降級原因,讓 `extract` 永遠回得了 `ModuleLevel` 而不是失敗。

**驗收標準**(契約卡原文,編排者已更新):

1. hiedb 不在 PATH 時 `ProbeResult = Unavailable`(原因指明執行檔),且整體降級為 `ModuleLevel` 不失敗
2. 對 fixture 專案(自建,含 GHC 9.14.1 產出的真實 `.hie`)執行後 `.knot/hiedb.sqlite` 存在且可被 SQLite 開啟
3. `dbPath` 覆寫時 `.knot/` 不被建立
4. 重跑時索引重用(第二次明顯不重做全量)
5. 需要 hiedb 執行檔的測試在 hiedb 不存在時**自動跳過並印明原因**(ADR-002 降級原則),測試摘要要列出跳過數

**明確不做**(契約卡底線):不讀索引內容出事實(`F004` 的事);不自己解析 `.hie` 產索引;不管理 `.gitignore`(只在首次建立 `.knot/` 時給提示);不清理過期索引。另承 D4 的全域決定:library 全程**不印任何輸出**,故「印提示」改走 `ExtractWarning` 通道(見假設 A2)。

## 相依性

`depends-on: [F001, F002, project-meta/F001, project-meta/F003]`,四條皆由「使用到的既有串接介面」表反推,全部已打開原始碼查證(非文檔約定):

- **`F001`(fact-contract,同子系統)**:`Backend` / `ProbeResult` / `hiedbName` / `runBackends`(`src/Knot/Extract/Backend.hs`)與 `ExtractOptions` / `ExtractWarning` / `CapabilityLevel` / `BackendReport`(`src/Knot/Extract/Types.hs`)全部出自它;`probeHiedb` 的型別就是 `Backend.bProbe` 的欄位型別。**序列相依**(程式碼已存在,狀態 done)。
- **`F002`(import-scan,同子系統)**:只在 **T7 的降級整合測試**用到 `importScanBackend`——要證明「hiedb 不可用時整體降為 `ModuleLevel` 且不失敗」,就必須有一個真的會成功的後端在註冊表裡陪跑,否則 `erLevel` 的 `ModuleLevel` 是「沒人成功」的預設值而非「降級後仍有能力」的證據。生產路徑不呼叫它。
- **`project-meta/F001`(scan-baseline,跨子系統)**:`ProjectMeta` / `HieInfo` / `MetaOptions` 的型別定義(`src/Knot/Meta/Types.hs`),測試路徑另用 `loadProjectMeta` 由 fixture 產生真實輸入。
- **`project-meta/F003`(hie-discovery,跨子系統)**:**這是行為相依,不只是型別相依**。本 feature 把 `hieFiles` 的每個元素直接當成 `hiedb index` 的檔案參數,因此依賴 `locateHie` 的三項保證:(a) 幽靈 `.hie` 已被濾除(抽取規則 1 原文;實測單一壞檔會讓整批 `hiedb index` 以 exit 1 中止,見「錯誤處理」);(b) 路徑為 repo 相對正斜線(否則 `cwd = rootDir` 的相對解析會失效);(c) 清單已排序(規則 8 的批次順序來源)。`src/Knot/Meta/HieLocate.hs` 已實作,三項皆查證屬實。

未列入的相依與理由:

- **`F004`(hiedb-facts)**:方向相反——`F004` 消費本 feature 的 `IndexHandle`。本 feature 不引用它的任何符號,`IndexHandle` 的欄位選型雖為它而設計(見「新增的介面」),但那是設計考量不是相依
- **`project-meta/F002`(cabal-components)**:只改變 `sfIncluded` / `sfOwners` 的填值,本 feature 完全不讀 `pmSources`
- **graph-core / export-query**:本 feature 不呼叫、也不被它們直接呼叫(經 `extract` 中介)

可平行性:**不可**與 `F004` 平行(`F004` 以 `IndexHandle` 為輸入,序列相依,D5 已排 W3 → W4);與 graph-core、export-query 的任務可平行(無交集)。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `ensureIndex :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)` | 簽名**一字不改**;`Left` 承載降級原因文字(直接可進 `BackendReport.brDetail`) |
| 模組介面 `IndexHandle`(「已就緒索引的不透明參照,內容屬 Level 3」) | 匯出**抽象型別 + 存取子**(不匯出建構子),契約的「不透明」照字面落實 |
| `Backend` 的 hiedb 實例:探測面 `bProbe` | 提供 `probeHiedb :: ExtractOptions -> ProjectMeta -> IO ProbeResult`,型別即 `bProbe` 欄位型別;**後端值本身與註冊表由 `F004` 組裝**(見假設 A1) |
| `ProbeResult = Available \| Unavailable Text` | 三種 `Unavailable` 原因(執行檔類 / `.hie` 類 / 版本類),以固定前綴機器可辨 |
| 抽取規則 5(區分並回報兩類不可用) | **執行檔類**(不存在 / 不可執行)與 **`.hie` 類**(無 `pmHie` / 清單為空 / GHC 版本不合 / `hiedb index` 失敗)分別以不同前綴回報;探測手段屬 Level 3 自主權,見「實作方式 › 2」 |
| 抽取規則 6(`.knot/hiedb.sqlite` 預設位置、`dbPath` 改道、root 取自 `ExtractOptions.rootDir`) | `defaultDbPath root = root </> ".knot" </> "hiedb.sqlite"`;`dbPath = Just p` 時只碰 `p` 的父目錄,絕不建 `.knot/`;**`p` 為相對路徑時以 `rootDir` 為錨點**(規則 6 後半,A3 已裁決) |
| 抽取規則 6(索引重用交給 `hiedb index` 自身的增量機制) | 不傳 `-r/--reindex`、不刪舊 db;實測第二次為 `0 indexed, N skipped` |
| 抽取規則 7(best-effort) | 三類失敗全部轉 `Left` / `Unavailable`,`ensureIndex` 與 `probeHiedb` **不抛例外** |
| 抽取規則 8(決定性) | 批次順序 = `hieFiles` 順序;不併發、不走訪 `Map`/`Set`。`ihStats` 是本次執行的觀測值(第一次與第二次本來就不同),**不進事實流**,不受規則 8 拘束 |
| 資料流管線段落「hiedb-driver: `pmHie` → `hiedb index` → 索引就緒(失敗 → 降級 + 報告)」 | 完全對應 |
| 抽取規則 1(只處理 included) | 不適用:本 feature 不讀 `pmSources`;`.hie` 清單以 `pmHie.hieFiles` 為準(規則 1 後半) |
| 規則 2 / 3 / 4 / 4a | **不觸碰**(規則 2/3 屬 `F001`、4/4a 屬 `F004`) |

超出 Level 2 契約的部分:**無**。有兩處契約**留白**由 Level 3 自主填補,已在「待確認假設」列出(A1 後端值歸屬、A2「印提示」的通道)。

## 實作方式

### 模組配置

```text
src/Knot/Extract/HiedbDriver.hs   -- probeHiedb + ensureIndex + IndexHandle + 純輔助函數
test/fixtures/hiedb/              -- 新 fixture:2 module 小專案 + GHC 9.14.1 產出的真實 .hie
```

`knot-hs.cabal`:library `exposed-modules` 加入 `Knot.Extract.HiedbDriver`;**`build-depends` 完全不變**——`process` / `directory` / `filepath` / `text` / `bytestring` / `base` 皆已在列(`process` 由 `Knot.Export.Commit` 引入的先例)。test-suite `build-depends` 亦不變。`version: 0.0.1.0` 依 D4 凍結不動。測試 group 命名 `extraction/F003 hiedb-driver`。

**不改** `src/Knot/Extract.hs` 的註冊表(假設 A1)。

### 1. 工具鏈事實(2026-08-21 於本機 GHC 9.14.1 實測,設計依此)

編排者的 D9 spike 之外,本 feature 補做了六項實測,結論直接進設計:

| 實測 | 結果 | 對設計的影響 |
|---|---|---|
| `hiedb --version` | exit 1 `Invalid option` | 探測**不能**用 `--version` |
| `hiedb --help` | exit 0 | 用它當「執行檔可跑」的 smoke test |
| 全域選項位置 | `hiedb [-D DB] [--src-base-dir ARG] … COMMAND`,**在子命令之前** | argv 組法固定為 `["-D", db, "--src-base-dir", ".", "index", <files…>]` |
| `-D` 指向不存在的目錄 | **exit 1**,`SQLite3 returned ErrorCan'tOpen … unable to open database file` | hiedb **不會**自建父目錄 → 由本 feature `createDirectoryIfMissing` |
| `index` 接**單一 `.hie` 檔**參數(help 只寫 DIRECTORY) | exit 0,`(1 indexed, 0 skipped)` | 可逐檔傳 `hieFiles`,天然排除幽靈檔與 `hieDir` 下的雜物 |
| `index` 接不存在的目錄/檔案 | **exit 0**,`(0 indexed, 0 skipped)` | exit code 不足以判定成功 → 必須解析 `Completed!` 計數 |
| `index` 接 0 byte 的假 `.hie` | **exit 1**,`Data.Binary.getPrim: end of file`,**整批中止** | 單一壞檔會毀掉整批 → 依賴 project-meta 的幽靈過濾;失敗即回 `Left` |
| 連跑第二次 | `(0 indexed, 2 skipped in 0.06s)`(第一次 `2 indexed, 0 skipped in 0.21s`) | 重用是 hiedb 內建的 hash 比對;**用計數而非計時**當驗收證據 |
| 輸出串流 | 進度與 `Completed!` 皆走 **stderr**;`-q` 可全靜音 | 用 `readCreateProcessWithExitCode` 同時捕獲兩股;**不加 `-q`**(要留下計數) |
| `.hie` 檔頭 | ASCII `"HIE"` + `"9141"` + `\n` + `"9.14.1"` + `\n` | **GHC 版本鎖可在 probe 階段就地檢出**(見下),不必等 index 炸掉 |
| `System.Info.fullCompilerVersion` | `9.14.1`(`showVersion`) | 與 `.hie` 檔頭第二行**格式完全一致**,可直接字串比對 |

### 2. `probeHiedb` — 探測(規則 5 的兩類區分)

依序短路,**先判執行檔**(驗收標準 1 要求「原因指明執行檔」):

```text
① 執行檔解析
     hiedbExe opts == Just p  → 用 p(不查 PATH)
     hiedbExe opts == Nothing → findExecutable "hiedb"
   找不到 → Unavailable "hiedb executable not found: …"              ← 執行檔類
② 執行檔可跑?  proc exe ["--help"] → ExitSuccess?
   否 / IOException → Unavailable "hiedb executable <p> is not runnable: …"  ← 執行檔類
③ pmHie == Nothing       → Unavailable "hie files unavailable: no .hie directory found …"   ← .hie 類
④ hieFiles == []         → Unavailable "hie files unavailable: <hieDir> has no usable .hie" ← .hie 類
⑤ GHC 版本鎖(ADR-001)
     讀 head(hieFiles) 的前 ~32 bytes → 解析 "HIE<n>\n<ghcVersion>\n"
     ghcVersion /= showVersion fullCompilerVersion
        → Unavailable "hie/ghc version mismatch: …"                  ← 版本類
     讀檔失敗 / 檔頭不成形 → Unavailable "hie files unavailable: cannot read hie header …"
⑥ 全過 → Available
```

三個**穩定前綴**(F004 與測試以此辨別類別,寫進 haddock):

| 前綴 | 類別 | 對應規則 5 |
|---|---|---|
| `hiedb executable ` | 執行檔不存在 / 不可執行 | 第一類 |
| `hie files unavailable: ` | 無 `.hie` / 清單空 / 檔頭讀不到 | 第二類 |
| `hie/ghc version mismatch: ` | `.hie` 由不同 GHC 產出 | 第二類(版本不合) |
| `hiedb index failed: ` | `hiedb index` 非零結束(只出現在 `ensureIndex` 的 `Left`) | 第二類(索引失敗) |

⑤ 只讀**一個**檔的檔頭(O(1),不隨專案大小成長);混版專案(部分檔案來自舊 GHC)由 `hiedb index` 在步驟 ⑤ 之後自然攔下,回 `hiedb index failed: `。

### 3. `ensureIndex` — 索引就緒

```text
ensureIndex opts pm
  │
  ├─ probeHiedb opts pm ─ Unavailable r ─▶ Left r        (自足:單獨呼叫也安全)
  │                       Available
  ▼
  rootAbs = makeAbsolute (rootDir opts)
  dbAbs   = makeAbsolute (case dbPath opts of            ← 相對路徑錨在 rootDir(A3 裁決)
              Nothing              -> defaultDbPath rootAbs
              Just p | isRelative p -> rootAbs </> p
                     | otherwise    -> p)
  │
  ├─ dbParent = takeDirectory dbAbs
  │    doesDirectoryExist dbParent?  否 → createDirectoryIfMissing True dbParent
  │                                        且「走預設路徑」時產生一則 note(A2)
  ▼
  batches = chunkFileArgs 24000 400 (hieFiles hie)         ← 順序即 hieFiles 順序
  │
  └─ forM batches $ \b →
       readCreateProcessWithExitCode
         (proc exe (["-D", dbAbs, "--src-base-dir", "."] ++ "index" : b))
           { cwd = Just rootAbs }                          ← 兩股輸出全被捕獲,library 不印
       ExitFailure _ → Left ("hiedb index failed: " <> 末幾行輸出)   （短路,不跑剩餘批次）
       IOException   → Left ("hiedb index failed: " <> displayException e)
  │
  ├─ doesFileExist dbAbs? 否 → Left "hiedb index failed: database file was not created …"
  ▼
  Right IndexHandle{ ihDbPath = dbAbs, ihRootDir = rootAbs, ihExe = exe
                   , ihStats = parseIndexStats (length batches) (所有批次輸出串接)
                   , ihNotes = [.knot 首建提示?] }
```

要點:

- **`cwd = Just rootAbs` + `--src-base-dir "."`**:完全複製 D9 spike 已驗證成功的呼叫形式(`hiedb -D <db> index <hiedir> --src-base-dir .` 於 repo 根執行)。`hieFiles` 是 repo 相對正斜線路徑,在 `cwd = rootAbs` 下正確解析;`--src-base-dir` 的取值決定 `mods.hs_src` 怎麼記錄來源路徑,是 `F004` 對映 `source_file` 的前提(先例:`Knot.Export.Commit` 同樣用 `cwd` 把外部程序釘在目標專案)
- **`dbAbs` 取絕對路徑是必要的**,不是潔癖:程序的 cwd 被換成 `rootAbs`,相對的 `-D` 路徑會落在目標專案裡而非使用者預期的位置。**相對 `dbPath` 的錨點是 `rootDir` 而非行程 cwd**(A3 已裁決,與 `hieDirOverride` 同語意);要寫到專案外用絕對路徑
- **分批**:Windows `CreateProcess` 命令列上限 32767 字元;`chunkFileArgs` 以「累計字元數 ≤ 24000 **且** 檔數 ≤ 400」切批,留頭給 exe 路徑與全域選項。單一路徑本身就超長時仍自成一批(不丟檔,交給 OS 報錯)。多批對同一 db 連續 `index` 是安全的——hiedb 的索引是累加式的,且第二批不會動到第一批已寫入的列
- **不傳 `-q`**:進度輸出全被 `readCreateProcessWithExitCode` 捕獲(library 不印,D4),留著 `Completed!` 行才有重用計數可驗收
- **不傳 `-r/--reindex`**:規則 6 明文「索引重用交給 `hiedb index` 自身的增量機制」

### 4. `defaultDbPath` / `parseIndexStats` / `chunkFileArgs`(純函數)

- `defaultDbPath root = root </> ".knot" </> "hiedb.sqlite"`(規則 6),**純函數、不碰檔案系統**
- `parseIndexStats <批數> <所有批次輸出串接>`:逐行找 `Completed! (<N> indexed, <M> skipped in …)`,把找到的 `N` / `M` 全部相加;`batchCount` 直接取第一參數(批數由呼叫端已知,不從文字反推);找不到任何 `Completed!` 行 → `IndexStats 0 0 <批數>`(不視為錯誤,exit code 才是權威)
- `chunkFileArgs :: Int -> Int -> [FilePath] -> [[FilePath]]`:`(字元上限, 檔數上限)`;空清單 → `[]`;`concat . chunkFileArgs a b == id`(順序與內容保持,規則 8)

### 5. `.knot/` 政策與提示通道(驗收標準 3、契約卡「印提示」)

| 情境 | 行為 |
|---|---|
| `dbPath = Nothing`、`<root>/.knot/` 不存在 | 建立目錄,`ihNotes` 產生一則 `ExtractWarning{ ewSource = hiedbName, ewMessage = "created index cache directory .knot/ under <root>; add it to .gitignore" }` |
| `dbPath = Nothing`、`<root>/.knot/` 已存在 | 不建、**不產 note**(只在首次建立時提示) |
| `dbPath = Just p` | 只 `createDirectoryIfMissing True (takeDirectory p)`;**絕不觸碰 `.knot/`**,也不產 note(改道的使用者不需要 `.gitignore` 提示) |

契約卡寫的是「只在首次建立 `.knot/` 時**印**提示」,但 D4 全域決定 library 全程不印。合理化解讀:**產生**提示、由呼叫端(CLI 組裝層)決定印不印——這正是 `ExtractWarning` 既有的語意(`ExtractResult.erWarnings` 的 haddock 原文:「best-effort 蒐集,呼叫端印 stderr」)。`ensureIndex` 的 Level 2 簽名沒有警告通道,所以提示**掛在 `IndexHandle` 上**(`ihNotes`),由 `F004` 的 `bRun` 併入回傳的 `[ExtractWarning]`。詳見假設 A2。

### 6. 錯誤處理總表(規則 7)

| 情境 | 通道 | 結果 |
|---|---|---|
| hiedb 不在 PATH / `hiedbExe` 指到不存在的檔 | `probeHiedb` | `Unavailable "hiedb executable not found: …"` → `brUsed = False` + 原因,整體 `ModuleLevel` |
| 執行檔存在但跑不動(架構不符、非執行檔) | `probeHiedb` | `Unavailable "hiedb executable <p> is not runnable: …"` |
| `pmHie = Nothing` / `hieFiles = []` | `probeHiedb` | `Unavailable "hie files unavailable: …"` |
| `.hie` 由別版 GHC 產出 | `probeHiedb`(檔頭比對) | `Unavailable "hie/ghc version mismatch: …"` |
| `.hie` 壞檔 / 混版 / hiedb 內部例外 | `ensureIndex` | `Left "hiedb index failed: <輸出末幾行>"` |
| `-D` 父目錄建不起來(權限) | `ensureIndex` | `Left "hiedb index failed: cannot create …"`(`IOException` 轉文字) |
| index 回 exit 0 但 db 檔不存在 | `ensureIndex` | `Left "hiedb index failed: database file was not created …"` |

`probeHiedb` 與 `ensureIndex` **全程不抛例外**(`F001` `runOne` 的 `try` 是第二道保險,不是本 feature 的錯誤處理手段)。

### 7. 測試 fixture 與跳過機制(D6 / D7)

**fixture**(入版控,D6):

```text
test/fixtures/hiedb/src/Demo/Core.hs      -- data Color、greet
test/fixtures/hiedb/src/Demo/App.hs       -- import Demo.Core (greet);run 呼叫 greet(供 F004 驗跨 module ref)
test/fixtures/hiedb/.hie/Demo/Core.hie    -- GHC 9.14.1 產出,實際 1139 bytes
test/fixtures/hiedb/.hie/Demo/App.hie     -- GHC 9.14.1 產出,實際 999 bytes
```

產生方式(**不入測試流程**,只記在測試原始碼註解裡供 GHC 升版時重跑):於 `test/fixtures/hiedb/` 下執行
`ghc -fno-code -fwrite-ide-info -hiedir .hie -isrc src/Demo/App.hs src/Demo/Core.hs`
(實測可行且**不需 cabal、不產 `dist-newstyle`**、不留 `.hi`/`.o`)。`.gitignore` 現有的 `*.hi` 不會誤傷 `*.hie`(glob 需完全結尾相符),`.knot/` 那行則正好蓋住測試若在 fixture 內建索引的殘留——但測試一律在**暫存目錄的副本**上跑,不在版控樹內建 `.knot/`。

**跳過機制**(D7):`test/Main.hs` 的 `main` 先做一次 `findExecutable "hiedb"`:

- `Just p` → 印 `[hiedb] using <p>`,測試樹掛上完整的 hiedb 相依測試
- `Nothing` → 印 `[skip] extraction/F003 hiedb-driver: hiedb executable not found on PATH; <N> tests skipped`(**原因 + 跳過數**;`N = 5`,由 `test_hiedb_skip_notice` 與實際掛載的節點數對帳),測試樹改掛單一佔位節點,名稱即 `"skipped (hiedb not on PATH): <N> tests"`,使跳過數同時出現在 tasty 自己的逐項輸出裡

不引入新的測試套件(`tasty-expected-failure` 之類),D4 的 hedgehog + tasty 組合不變。

## 使用到的既有串接介面

(專案內簽名為 2026-08-21 自來源檔案讀出的**原文**;`base` / `directory` / `process` / `filepath` / `text` / `bytestring` 的簽名以 GHC 9.14.1 實際編譯一支 type-ascription 檔驗過,`directory-1.3.10.0`、`process-1.6.26.1`)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Backend = Backend { bName :: Text, bLevel :: CapabilityLevel, bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult, bRun :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning]) }` | src/Knot/Extract/Backend.hs:34-39 | F001 | `probeHiedb` 的型別即 `bProbe` 欄位型別;T7 以此組出降級測試用的後端值 |
| `data ProbeResult = Available \| Unavailable Text` `deriving (Eq, Show)` | src/Knot/Extract/Backend.hs:42-43 | F001 | `probeHiedb` 的回傳型別;`Eq`/`Show` 讓測試可直接比對 |
| `hiedbName :: Text` (= `"hiedb"`) | src/Knot/Extract/Backend.hs:50-51 | F001 | note 的 `ewSource` 取值;T7 後端值的 `bName` |
| `runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult` | src/Knot/Extract/Backend.hs:68 | F001 | 僅測試路徑(T7):驗證探測失敗 → `ModuleLevel` + 報告不失敗 |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | src/Knot/Extract/Types.hs:33-38 | F001 | 四欄全用:`rootDir` 錨定 `.knot/` 與 cwd、`hiedbExe` 覆寫執行檔、`dbPath` 改道、`backendChoice` 僅供 T7 走 `runBackends` |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` | src/Knot/Extract/Types.hs:100-103 | F001(D1) | `ihNotes` 的元素型別(`.knot/` 首建提示) |
| `data CapabilityLevel = ModuleLevel \| DeclLevel` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:53-54 | F001 | T7 斷言 `erLevel == ModuleLevel`;`DeclLevel` 由 `F004` 的後端值使用 |
| `data BackendReport = BackendReport { brBackend :: Text, brUsed :: Bool, brDetail :: Text }` | src/Knot/Extract/Types.hs:92-96 | F001 | T7 斷言降級原因落在 `brDetail`(即 `Unavailable` 的文字) |
| `data ExtractResult = ExtractResult { erFacts :: [Fact], erLevel :: CapabilityLevel, erReports :: [BackendReport], erWarnings :: [ExtractWarning] }` | src/Knot/Extract/Types.hs:44-49 | F001 | T7 的斷言對象 |
| `importScanBackend :: Backend` | src/Knot/Extract/ImportScan.hs:47-53 | F002 | 僅測試路徑(T7):註冊表裡「真的會成功」的陪跑後端,使 `ModuleLevel` 是降級證據而非空預設 |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | src/Knot/Meta/Types.hs:29-34 | project-meta/F001 | `probeHiedb` / `ensureIndex` 的第二參數;**只讀 `pmHie`** |
| `data HieInfo = HieInfo { hieDir :: FilePath, hieSource :: HieDirSource, hieFiles :: [FilePath], hieGhosts :: [FilePath] }` | src/Knot/Meta/Types.hs:77-82 | project-meta/F003 | `hieFiles` → `hiedb index` 的檔案參數(repo 相對正斜線、已濾幽靈、已排序);`hieDir` 只用於 `Unavailable` 訊息;`hieGhosts` **刻意不用**(規則 1) |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs:22-26 | project-meta/F001 | 僅測試路徑:對 fixture 副本組出真實輸入 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 僅測試路徑:讓 T3/T5/T6 的 `hieFiles` 來自真實的 `locateHie`(`.hie` 慣例層命中),而非手寫常數 |
| `locateHie :: MetaOptions -> [SourceFile] -> IO (Maybe HieInfo, [MetaWarning])` | src/Knot/Meta/HieLocate.hs:42 | project-meta/F003 | 不直接呼叫;列出以標明「`hieFiles` 的三項保證」出自此實作(已讀原始碼查證:`classify` 濾幽靈、`enumerateHie` 出正斜線相對路徑、`sort` 保證順序) |
| `System.Directory.findExecutable :: String -> IO (Maybe FilePath)` | directory-1.3.10.0 | - | PATH 查 `hiedb`(`hiedbExe = Nothing` 時);測試端也用它決定跳過 |
| `System.Directory.createDirectoryIfMissing :: Bool -> FilePath -> IO ()` | directory-1.3.10.0 | - | 建 db 的父目錄(hiedb 自己不建,已實測) |
| `System.Directory.doesDirectoryExist :: FilePath -> IO Bool` / `doesFileExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | 判斷 `.knot/` 是否「首次建立」(決定要不要出 note);index 後確認 db 檔真的存在 |
| `System.Directory.makeAbsolute :: FilePath -> IO FilePath` | directory-1.3.10.0 | - | `rootDir` 與 db 路徑轉絕對(cwd 會被換成 `rootAbs`,相對路徑會錯位) |
| `System.Process.readCreateProcessWithExitCode :: CreateProcess -> String -> IO (ExitCode, String, String)` | process-1.6.26.1 | - | 跑 `hiedb --help` 與 `hiedb index`,**捕獲兩股輸出**使 library 不印(先例:`Knot.Export.Commit`) |
| `System.Process.proc :: FilePath -> [String] -> CreateProcess` / `CreateProcess { cwd :: Maybe FilePath, … }` | process-1.6.26.1 | - | 不走 shell(免 quoting);`cwd` 釘在 `rootAbs` 使 `--src-base-dir .` 與相對 `.hie` 路徑成立。組合形狀(`proc` + `cwd` + 捕獲兩股 + 例外轉降級值)沿用 `src/Knot/Export/Commit.hs:31-41` 的既有範式,不另創一套 |
| `System.Info.fullCompilerVersion :: Version` / `Data.Version.showVersion :: Version -> String` | base-4.22(GHC 9.14.1) | - | ADR-001 版本鎖:`showVersion fullCompilerVersion == "9.14.1"`,與 `.hie` 檔頭第二行格式一致,可直接字串比對 |
| `Data.ByteString.readFile :: FilePath -> IO ByteString` / `Data.ByteString.take :: Int -> ByteString -> ByteString` | bytestring(GHC 9.14.1 boot) | - | 讀 `.hie` 檔頭前 ~32 bytes 做版本比對;測試端讀 SQLite magic(`"SQLite format 3\0"`)與 `.hie` magic(`"HIE"`) |
| `Control.Exception.try :: Exception e => IO a -> IO (Either e a)` / `displayException :: Exception e => e -> String` | base-4.22 | - | `IOException` 轉降級原因文字(規則 7) |
| `System.FilePath.(</>)` / `takeDirectory :: FilePath -> FilePath` | filepath(GHC 9.14.1 boot) | - | `defaultDbPath` 組路徑;取 db 父目錄 |
| `System.Directory.getTemporaryDirectory :: IO FilePath` / `removePathForcibly :: FilePath -> IO ()` | directory-1.3.10.0 | - | 僅測試路徑:把 fixture 複製到暫存目錄再跑,確保版控樹零寫入(沿用 `withScratchTree` 慣例) |

## 新增的介面

全部落在 Level 2 契約內(`ensureIndex` 簽名照抄、`IndexHandle` 為契約點名的不透明型別、`probeHiedb` 是 `bProbe` 的實例)。純輔助函數依既有慣例以 haddock 標註非契約面。

**`Knot.Extract.HiedbDriver`**

```haskell
module Knot.Extract.HiedbDriver
  ( -- * Level 2 模組介面
    ensureIndex
  , IndexHandle              -- 抽象型別:不匯出建構子(契約的「不透明參照」)
  , ihDbPath, ihRootDir, ihExe, ihStats, ihNotes
  , IndexStats (..)
    -- * Backend hiedb 實例的探測面
  , probeHiedb
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , defaultDbPath, parseIndexStats, chunkFileArgs
  ) where
```

```haskell
-- | 確保 hiedb 索引就緒。內含一次 'probeHiedb'(自足:單獨呼叫也安全)。
--   Left 的文字即降級原因,可直接進 BackendReport.brDetail;不抛例外。
ensureIndex :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)

-- | 「已就緒索引」的不透明參照。只能由 'ensureIndex' 取得,欄位經存取子讀取。
data IndexHandle

ihDbPath  :: IndexHandle -> FilePath      -- ^ 索引 SQLite 的**絕對**路徑(F004 開 DB 用)
ihRootDir :: IndexHandle -> FilePath      -- ^ 專案根**絕對**路徑(F004 把來源路徑對回 repo 相對用)
ihExe     :: IndexHandle -> FilePath      -- ^ 本次實際使用的 hiedb 執行檔(回報/除錯用)
ihStats   :: IndexHandle -> IndexStats    -- ^ 本次 index 的觀測值(**不進事實流**)
ihNotes   :: IndexHandle -> [ExtractWarning]  -- ^ 首次建立 .knot/ 的提示等;F004 的 bRun 併入回傳

-- | 本次 'ensureIndex' 的索引統計(重用驗收的證據來源)。
data IndexStats = IndexStats
  { indexedCount :: Int     -- ^ 本次新建索引的 .hie 數
  , skippedCount :: Int     -- ^ hiedb 判定內容未變而重用的 .hie 數
  , batchCount   :: Int     -- ^ 實際發出的 hiedb index 次數
  }
  deriving (Eq, Show)

-- | Backend 的 hiedb 實例探測面(型別即 Backend.bProbe 的欄位型別)。
--   Unavailable 的原因以四個固定前綴區分類別,見 haddock 表。不抛例外。
probeHiedb :: ExtractOptions -> ProjectMeta -> IO ProbeResult

-- * 內部純函數

-- | 抽取規則 6 的預設索引位置:<root>/.knot/hiedb.sqlite。純函數,不碰檔案系統。
defaultDbPath :: FilePath -> FilePath

-- | 解析 hiedb 的 "Completed! (N indexed, M skipped in …)" 行,多批相加。
parseIndexStats :: Int -> Text -> IndexStats     -- ^ 第一參數為批數

-- | 依(累計字元上限, 檔數上限)切批;concat . chunkFileArgs a b == id。
chunkFileArgs :: Int -> Int -> [FilePath] -> [[FilePath]]
```

**`F004` 要靠 `IndexHandle` 做到的事**(設計時已預留,本 feature 不實作):以 `ihDbPath` 開 SQLite 查 `mods` / `decls` / `defs` / `refs`;以 `ihRootDir` 把 `mods.hs_src` 對回 repo 相對正斜線;把 `ihNotes` 併進 `bRun` 的 `[ExtractWarning]`。

## TodoList

- [x] T1: `Knot.Extract.HiedbDriver` 骨架——抽象 `IndexHandle` + 五個存取子 + `IndexStats`,純函數 `defaultDbPath`;`knot-hs.cabal` 的 `exposed-modules` 加一行(`build-depends` 與 `version` 不動);`cabal build all` 通過  `dep: F001`
- [x] T2: `chunkFileArgs`——雙上限切批、空清單、單一超長路徑自成一批、順序與內容保持  `dep: T1`
- [x] T3: `parseIndexStats`——`Completed!` 行解析、多批相加、`0 indexed / N skipped`、無 `Completed!` 行退回 0/0  `dep: T1`
- [x] T4: 建立 fixture `test/fixtures/hiedb/`(2 個 `.hs` + GHC 9.14.1 產出的 2 個真實 `.hie`)並入版控,產生指令寫進測試原始碼註解  `dep: -`
- [x] T5: 測試跳過機制——`main` 先探 `findExecutable "hiedb"`,無則印「原因 + 跳過數」並把 hiedb 相依群組換成具跳過數的佔位節點(D7)  `dep: T4`
- [x] T6: `probeHiedb`——執行檔解析(`hiedbExe` 覆寫 / PATH)、`--help` smoke、`pmHie` / `hieFiles` 檢查、`.hie` 檔頭 GHC 版本比對(ADR-001),四個穩定前綴寫進 haddock  `dep: T1, project-meta/F003`
- [x] T7: `ensureIndex` 主流程——db 路徑解析與絕對化、父目錄建立、`cwd = rootAbs` + `--src-base-dir .` 的 argv 組法、分批呼叫、exit code 與 db 檔存在性判讀、`IndexHandle` 組裝  `dep: T2, T3, T6, project-meta/F001`
- [x] T8: `.knot/` 政策——預設路徑首次建立時經 `ihNotes` 出提示(A2)、已存在時不出、`dbPath` 覆寫時 `.knot/` 完全不被建立  `dep: T7`
- [x] T9: 索引重用——同一暫存樹連跑兩次 `ensureIndex`,計數由 `N indexed / 0 skipped` 轉為 `0 indexed / N skipped`  `dep: T7`
- [x] T10: 降級整合——`probeHiedb` 不可用時經 `runBackends` 驗 `erLevel == ModuleLevel`、hiedb 那筆 `brUsed = False` 且 `brDetail` 指明執行檔、不抛例外、import-scan 事實不受影響  `dep: T6, F002`
- [x] T11: 以 knot-hs 自身的真實 `.hie`(D8:24 個 module)唯讀驗收多批/大量檔路徑,`dbPath` 改道到暫存目錄,結果寫入「實作備註」  `dep: T7`

## 1-to-1 測試對照表

(標「**需 hiedb**」者納入 T5 的跳過機制;其餘在任何環境都會執行)

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_default_db_path | `defaultDbPath r == r </> ".knot" </> "hiedb.sqlite"`,對相對 / 絕對 / 帶尾斜線的 root 皆成立;呼叫前後 `doesDirectoryExist (r </> ".knot")` 均為 `False`(純函數,零 IO);`IndexStats` 的 `Eq`/`Show` 可用 |
| T2 | test_chunk_file_args | 空清單 → `[]`;檔數上限觸發時批數正確;字元上限觸發時批數正確;單一超長路徑自成一批且不被丟棄;`concat (chunkFileArgs a b xs) == xs`(hedgehog property,隨機路徑清單 × 隨機上限) |
| T3 | test_parse_index_stats | 單批 `Completed! (2 indexed, 0 skipped in 0.21s + 0.00s gc)` → `IndexStats 2 0 1`;兩批輸出串接 → 計數相加且 `batchCount == 2`;`(0 indexed, 2 skipped …)` → `IndexStats 0 2 1`;不含 `Completed!` 的輸出 → `IndexStats 0 0 n`;夾雜 `Processing file …` progress 行不影響 |
| T4 | test_hiedb_fixture | 四個 fixture 檔存在;兩個 `.hie` 皆 **> 0 bytes** 且前 3 bytes 為 `"HIE"`;檔頭第二行(GHC 版本)等於 `showVersion fullCompilerVersion`(GHC 升版時此測試會**先**紅,明確指向「重跑 fixture 產生指令」而非讓 hiedb 神秘失敗) |
| T5 | test_hiedb_skip_notice | 跳過訊息組裝函式:`Nothing` → 文字同時含 `"hiedb"`、`"not found"` 與跳過數;`Just p` → 文字含該路徑;跳過數等於受跳過機制管轄的測試數(常數與實際掛載的節點數對帳) |
| T6 | test_probe_hiedb | (無 hiedb 亦可)`hiedbExe = Just "<不存在的路徑>"` → `Unavailable`,訊息以 `"hiedb executable "` 起頭且含該路徑;**需 hiedb**:`pmHie = Nothing` → 前綴 `"hie files unavailable: "`;`hieFiles = []` → 同前綴且訊息含 `hieDir`;fixture 副本(檔頭版本相符)→ `Available`;把一個 `.hie` 換成檔頭寫著別的 GHC 版本的假檔 → 前綴 `"hie/ghc version mismatch: "` |
| T7 | test_ensure_index | **需 hiedb**:把 fixture 複製到暫存目錄,經 `loadProjectMeta` 取真實 `ProjectMeta` → `ensureIndex` 回 `Right h`;`ihDbPath h` 為絕對路徑、檔案存在、前 16 bytes 等於 `"SQLite format 3\0"`(驗收標準 2 的「可被 SQLite 開啟」);`ihRootDir h` 為絕對且指向暫存樹;`ihStats h == IndexStats 2 0 1`;把 `hieFiles` 換成含一個 0 byte 假 `.hie` 的清單 → `Left`,文字以 `"hiedb index failed: "` 起頭(規則 5 第二類);全程未抛例外 |
| T8 | test_knot_dir_policy | **需 hiedb**:(a) `dbPath = Nothing` 於乾淨暫存樹 → `<root>/.knot/hiedb.sqlite` 存在且 `ihNotes` 恰一則、`ewSource == hiedbName`、訊息含 `.knot` 與 `.gitignore`;(b) 同一樹再跑一次 → `ihNotes == []`(不重複提示);(c) `dbPath = Just <暫存目錄外的路徑>` 於乾淨暫存樹 → 該檔存在、`doesDirectoryExist (root </> ".knot") == False`、`ihNotes == []`(驗收標準 3) |
| T9 | test_index_reuse | **需 hiedb**:同一暫存樹連續兩次 `ensureIndex` → 第一次 `indexedCount == 2 && skippedCount == 0`,第二次 `indexedCount == 0 && skippedCount == 2`,`ihDbPath` 兩次相同(驗收標準 4;以計數而非計時判定,不受機器速度影響) |
| T10 | test_hiedb_degrade | (無 hiedb 亦可)以 `probeHiedb` 與一個「被呼叫即測試失敗」的 `bRun` 組出 hiedb `Backend`,連同 `importScanBackend` 交給 `runBackends`,`hiedbExe = Just "<不存在的路徑>"`:`erLevel == ModuleLevel`;`erReports` 兩筆,hiedb 那筆 `brUsed == False` 且 `brDetail` 以 `"hiedb executable "` 起頭;import-scan 那筆 `brUsed == True` 且 `erFacts` 非空;`bRun` 未被呼叫;不抛例外(驗收標準 1) |
| T11 | test_hiedb_selfcheck | **需 hiedb**,且 knot-hs 自身 `dist-newstyle` 下有 `.hie` 時才跑(否則印明原因跳過):以 `dbPath` 指向暫存目錄對自身 `.hie` 跑 `ensureIndex` → `Right`、`indexedCount > 0`、`<repo>/.knot/` 未被建立;實跑數據(檔數、批數、兩次的計數)記入「實作備註」 |

## 待確認假設

**全部七條已由階段二閘門裁決**(A3 有變更、其餘照設計採納);以下保留原文以留下決策脈絡,裁決落點見每條末尾的「**裁決**」。

- A1: 契約卡把「`Backend` hiedb 實例的**探測面**」給 `F003`、「**執行面** `bRun`」給 `F004`,但沒說 `Backend` 值本身與 `Knot.Extract` 註冊表由誰組裝 → 採取:**`F003` 只匯出 `probeHiedb` 函式,不建 `Backend` 值、不改註冊表**,由 `F004` 組出 `hiedbBackend = Backend { bName = hiedbName, bLevel = DeclLevel, bProbe = probeHiedb, bRun = … }` 並註冊。理由:在 `F003` 就註冊一個 `bRun` 未實作的後端,會讓「hiedb 可用」的環境在 `auto` 模式下直接壞掉(比沒註冊更糟)。驗收標準 1 的「整體降級」因此由 T10 以 `runBackends` + 測試組裝的後端值證明,而非透過生產註冊表 → 影響:若編排者要求 `F003` 就要能端到端降級,`F003` 需改為註冊一個 `bRun = pure ([], [])` 的暫時後端,並由 `F004` 覆寫(兩次改同一行,且中間狀態會謊報 `DeclLevel`)。**裁決:採納**——`F003` 只匯出 `probeHiedb`,`src/Knot/Extract.hs` 的註冊表未動,`Backend` 值與註冊由 `F004` 組裝
- A2: 契約卡要求「只在首次建立 `.knot/` 時**印**提示」,但 D4 全域決定 library 全程不印,而 Level 2 的 `ensureIndex :: … -> IO (Either Text IndexHandle)` 簽名裡沒有警告通道 → 採取:提示**掛在 `IndexHandle` 上**(`ihNotes :: IndexHandle -> [ExtractWarning]`),由 `F004` 的 `bRun` 併入回傳的 `[ExtractWarning]`,最終經 `ExtractResult.erWarnings` 由 CLI 組裝層印 stderr(這正是該欄位 haddock 原文「呼叫端印 stderr」的用法);契約卡的「印」解讀為「產生使用者看得到的提示」→ 影響:若編排者裁定要改 Level 2 簽名(如 `ensureIndex :: … -> IO (Either Text (IndexHandle, [ExtractWarning]))`),`ihNotes` 拿掉、`ensureIndex` 回傳形狀與 `F004` 的呼叫端各動一處。**裁決:採納**——`ihNotes` 掛在 `IndexHandle` 上,`F004` 的 `bRun` 併入 `[ExtractWarning]`
- A3: `ExtractOptions.dbPath` 若為**相對路徑**,錨點未定義(`rootDir` 還是行程 cwd?)→ 原提案:以 `makeAbsolute` 對行程 cwd 解析。**裁決:變更為以 `rootDir` 為錨點**——同一支 CLI 的兩個路徑覆寫旗標(`--hiedir` / `--db`)不應有兩套規則,與 project-meta 的 `hieDirOverride` 同語意;要寫到專案外用絕對路徑。`design.md` 抽取規則 6 已由編排者回寫此語意,本文檔的「實作方式 › 3」與對照表同步更新,`ensureIndex` 的路徑解析(`resolveDbPath`)與 T8(d) 依此實作
- A4: 規則 5 說「探測手段屬 Level 3 自主權」,但沒說相容性檢查要做到多深 → 採取:probe 階段只讀**第一個** `.hie` 的檔頭比對 GHC 版本(O(1),已實測檔頭格式為 `"HIE"+"9141"+\n+"9.14.1"+\n`),混版專案的其餘檔案交給 `hiedb index` 攔下並回 `hiedb index failed: `。理由:全檔掃描檔頭在大專案上是白花的 IO,而 index 本來就會全部讀過一次 → 影響:若要求 probe 就要抓出混版,改為掃全部 `hieFiles` 的檔頭(成本隨檔數線性成長,並需決定「部分不合」時是降級還是只跳過那些檔)。**裁決:採納**——probe 只讀 `head hieFiles` 的檔頭
- A5: 抽取規則 8(決定性)是否拘束 `IndexHandle` → 採取:`ihStats` 是**本次執行的觀測值**,第一次與第二次本來就不同(那正是驗收標準 4 的證據),因此明文排除於規則 8 之外;規則 8 拘束的是**事實流**,而事實流由 `F004` 產出、與 `ihStats` 無關 → 影響:若裁定 `IndexHandle` 也必須「同輸入同輸出」,`ihStats` 需移出 handle(改由 `ensureIndex` 另一個回傳位置給),重用驗收就得改用計時或 db mtime,兩者都比計數脆弱。**裁決:採納**——`ihStats` 留在 handle 上,haddock 明文標註「不進事實流」
- A6: 驗收標準要求對 fixture 專案執行後「`.knot/hiedb.sqlite` 存在」,但 fixture 在版控樹內,在原地建 `.knot/` 會弄髒 repo → 採取:所有需要寫入的測試都先把 fixture **複製到暫存目錄**再跑,測完 `removePathForcibly`(沿用 `test/Main.hs` 既有的 `withScratchTree` 慣例);版控樹內的 `test/fixtures/hiedb/` 全程唯讀 → 影響:無(`.gitignore` 已有 `.knot/`,即使漏建也不會進版控;此假設只是把「測試不弄髒工作樹」寫明)。**裁決:採納**——`withHiedbScratch` 每次複製 fixture 到暫存目錄,跑完 `removePathForcibly`
- A7: D7 要求「測試摘要要列出跳過數」,但 tasty 沒有內建的 skipped 狀態(要外掛 `tasty-expected-failure`,屬新增測試依賴)→ 採取:**不加新依賴**(D4 只認 hedgehog + tasty),改為 `main` 在 `defaultMain` 前印一行 `[skip] … <N> tests skipped`,並讓佔位測試節點的**名稱本身**含跳過數,使其同時出現在 tasty 的逐項輸出 → 影響:若編排者要求標準的 SKIP 狀態,test-suite `build-depends` 加 `tasty-expected-failure`,改用 `ignoreTestBecause`(一行包裹,測試本體不動)。**裁決:採納**——不加新依賴,`main` 印一行 + 佔位節點名稱帶跳過數

## 實作備註

### 與設計的偏差

1. **`probeParts` 取代兩次解析**(內部實作自主權,不動契約):`probeHiedb` 的本體是私有的 `probeParts :: … -> IO (Either Text (FilePath, HieInfo))`,成功時把「已解析的執行檔路徑 + `HieInfo`」一併交出;`probeHiedb` 只是把它包成 `ProbeResult`,`ensureIndex` 直接重用結果,不必重跑 `findExecutable` 與 `--help`。公開簽名與設計一字不差。
2. **`hiedbExe` 明示路徑的解析多一層 fallback**:設計只寫「用 p(不查 PATH)」。實作為 `doesFileExist p` 不成立時再試一次 `findExecutable p`——Windows 上使用者很容易寫 `C:\cabal\bin\hiedb` 而漏掉 `.exe`,直接判 not found 會誤報。兩條路都失敗才回 `hiedb executable not found: <p>`,訊息前綴與測試斷言不受影響。
3. **`ensureIndex` 外層再包一次 `IOException`**:設計把「`-D` 父目錄建不起來」單獨列為一條錯誤處理。實作改為整個 body 包 `try @IOException`,任何 IO 失敗(`makeAbsolute` / `createDirectoryIfMissing` / `doesFileExist`)一律轉 `hiedb index failed: <displayException>`,語意涵蓋設計表列的兩條且不會漏。
4. **`chunkFileArgs` 對非正的上限做防呆**:兩個上限內部一律取 `max 1`,否則 `fileCap <= 0` 會讓切批不前進而無窮迴圈。純內部行為,property 測試仍以 `>= 1` 的上限驗 `concat . chunkFileArgs a b == id`。
5. **T6 拆成兩個測試節點**:`test_probe_hiedb`(執行檔類,無 hiedb 亦可跑)與 `test_probe_hiedb_available`(`.hie` 類 / 版本類 / 全過,需 hiedb)。原因:probe 是短路的,`pmHie` 與版本檢查只有在執行檔通過後才到得了,不拆就無法讓「無 hiedb 環境」也驗到執行檔類。另補一條設計未列的案例:檔頭不成形 → `hie files unavailable: `(不是版本類)。
6. **T8 增加 (d) 相對 `dbPath` 案例**:A3 裁決變更後新增,驗 `dbPath = Just "build/idx.sqlite"` 落在 `<root>/build/idx.sqlite`、**行程 cwd 下沒有** `build/idx.sqlite`、`.knot/` 未建立。
7. **`.knot/` 提示訊息措辭**:實際為 `created index cache directory <dbParent> under <rootAbs>; add .knot/ to .gitignore`(同時含 `.knot` 與 `.gitignore`,符合驗收)。
8. **階段二閘門裁決:`probeParts` 的 `head` 換成全函式寫法**:原本是 `null (hieFiles hie)` guard + `head (hieFiles hie)`,執行期雖安全,但 GHC 9.14 的 `-Wall` 含 `-Wx-partial`,仍會發 `[GHC-63394]`。改以 `case hieFiles hie of { [] -> …; (firstHie : _) -> … }`,型別層面就不需要部分函式,警告消除;行為與錯誤訊息(`… has no usable .hie files`)完全不變。

### T11 自我驗收數據(knot-hs 自身的真實 `.hie`)

版控樹裡 knot-hs 自己**沒有** `.hie`(`.cabal` 未帶 `-fwrite-ide-info`,且本 feature 不得改建置旗標),所以 `test_hiedb_selfcheck` 在一般環境走「印明原因並跳過」的分支。為取得實跑數據,實作階段以**不改任何檔案**的方式臨時產生一次再刪除:

```text
cabal build lib:knot-hs --ghc-options="-fwrite-ide-info -hiedir .hie"   # 產生 26 個 .hie
cabal test --enable-tests
rm -rf .hie                                                             # 復原,版控樹零殘留
```

結果(`[selfcheck]` 為測試印出的原文):

| 項目 | 值 |
|---|---|
| `.hie` 檔總數 / `hieFiles` 採用數 | 26 / **25**(1 個由 project-meta 的幽靈過濾濾除,即 `Paths_` 類無對應原始檔者) |
| 批數 | **1**(25 個 repo 相對路徑遠低於 24000 字元 / 400 檔的雙上限) |
| 第一次 | `IndexStats {indexedCount = 25, skippedCount = 0, batchCount = 1}` |
| 第二次 | `IndexStats {indexedCount = 0, skippedCount = 25, batchCount = 1}` |
| `dbPath` 改道 | 指向系統暫存目錄的絕對路徑;`<repo>/.knot/` 全程未被建立(斷言通過) |
| 全套測試 | `All 106 tests passed (6.18s)` |

多批路徑(`chunkFileArgs` 切出 >1 批)因此**未經真實 hiedb 驗證**,只由 T2 的例子與 property 驗證切批本身正確;真實多批要等有 >400 個 `.hie` 的目標專案(MagicFarmer / particle-magic 依 D8 不碰)。批次間對同一 db 連續 `index` 的安全性沿用設計時的實測結論(hiedb 索引為累加式)。

### 建置與測試環境

- `hiedb`:`C:\cabal\bin\hiedb.exe`(存在,故 5 個閘門測試**實跑**,非跳過)
- GHC 9.14.1;fixture `.hie` 檔頭第二行 `9.14.1` 與 `showVersion fullCompilerVersion` 相符
- fixture 實測大小:`Demo/Core.hie` 1139 bytes、`Demo/App.hie` 999 bytes(設計時記的 1026 / 884 是另一版原始碼的量測值,已以實際值為準)
- 新增程式碼 `-Wall` **零警告**;`test/Main.hs` 既有的 8 筆 `-Wincomplete-record-selectors` 未動(既有負債)
