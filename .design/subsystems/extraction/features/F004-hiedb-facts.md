---
id: F004
type: feature
title: hiedb-facts
description: 讀 hiedb 索引出 decl 層事實流並組裝註冊 hiedb 後端
status: done
created: 2026-08-21
updated: 2026-08-22
depends-on: [F001, F002, F003, project-meta/F001, export-query/F004]
related-adr: [ADR-002]
related-feature: []
---

# F004: hiedb-facts — 索引 SQLite → decl 層事實流

## 功能概述

extraction 階段二的**第二半**:把 `F003` 交出來的**就緒索引**(`IndexHandle`)讀成 `FactDecl` / `FactRef` 事實流,並把 `probeHiedb`(F003)與本 feature 的執行面組成完整的 hiedb `Backend` **註冊進 `Knot.Extract`**——這是整條函式級管線最後一塊拼圖,一裝上去 `knot extract` 的 `erLevel` 才第一次到得了 `DeclLevel`。

**要解決的問題**:hiedb 的索引是「壓平的列」——`decls` 沒有 module 欄、`refs` 的 `mod` 是被引用者而非引用發生地、namespace 藏在 `occ` 的字串前綴裡、來源路徑是絕對且(Windows)反斜線。本 feature 是把這堆列還原成 `QualName` 語意的唯一處所:接上 module、判讀 namespace、以 span 包含 join 還原「這個引用寫在哪個頂層宣告裡」、把絕對路徑對回 `pmSources` 的 repo 相對正斜線路徑。

**本 feature 另含兩件前置**(編排者裁定一併做,見「實作方式 › 0」):把 design.md 的 C1/C2 契約更新落到 `Knot.Extract.Types`;補接 CLI 的 `--hiedb` / `--db`。後者是**硬性前置**:hiedb 後端一註冊,沒有 `--db` 就會在任何被掃描的專案裡建 `.knot/` 且無法改道,直接違反 system.md「驗收標的不得異動」的唯讀例外機制。

**驗收標準**(契約卡原文,編排者已依實測改寫):

1. 對 fixture 專案(自建、含 GHC 9.14.1 產出的真實 `.hie`,兩 module、跨 module 呼叫)執行——跨 module 呼叫產出 `FactRef` 且 `frFromDecl` 指向正確的頂層宣告(多候選時為 span 最內層者)
2. `qnSpace` 正確區分四種 namespace(`v:` / `c:` / `t:` / `f<父型別>:`)
3. `frGenerated` 與 hiedb 的 `refs.is_generated` 逐筆相符
4. 產出的 `QualName` 全部可對映回 `pmSources` 的 module(對映不到的印警告)
5. 連續兩次執行輸出相同

**明確不做**(契約卡底線):**不產出 `FactInstance`**(hiedb 0.8 schema 無 instance 表,已於上游原始碼複查屬實,見「實作方式 › 1」);建構子保留但零邏輯,`implements` 邊另開 feature;不輸出型別資訊(`typerefs` / `typenames` 本版不用);不判斷產生碼要不要丟棄(只轉載旗標,取捨是 graph-core 的職責);不做圖層面的聚合。另承 D4 全域決定:library 全程**不印任何輸出**,所有提示走 `ExtractWarning`。

## 相依性

`depends-on: [F001, F002, F003, project-meta/F001, export-query/F004]`,全部由「使用到的既有串接介面」表反推:

- **`F001`(fact-contract,同子系統,已 done 有原始碼)**:`Backend` / `ProbeResult` / `hiedbName` / `runBackends`(`src/Knot/Extract/Backend.hs`)與全套事實流 DTO(`src/Knot/Extract/Types.hs`)。本 feature 組裝 `Backend` 值、產出 `Fact`、並**修改** `NameSpace` 與 `FactRef` 兩個 DTO(前置 1,C1/C2 契約更新)。**序列相依**。
- **`F002`(import-scan,同子系統,已 done 有原始碼)**:`importScanBackend` 是註冊表既有成員,本 feature 把 `hiedbBackend` 併排註冊(`src/Knot/Extract.hs`)。另有**行為相依**:`FactModule` / `FactImport` 的 `fmFile` / `fiFile` 用的是 `sfPath` 原文,本 feature 的 `fdFile` / `frFile` **必須取同一個字串**,否則 graph-core 的 module 節點與 decl 節點會指向兩套路徑寫法而接不起來(組裝規則 2 的 `RContains` 靠 module 名、規則 3 的產生碼過濾靠「檔案在不在 `pmSources`」)。
- **`F003`(hiedb-driver,同子系統,**設計完成、尚無原始碼**)**:`ensureIndex` / `IndexHandle` / `ihDbPath` / `ihRootDir` / `ihNotes` / `probeHiedb`。**本相依依 `F003` 設計文檔的介面約定,非既有程式碼**——介面表對應列已標明。序列相依(D5 已排 W3 → W4),**不可平行**。
- **`project-meta/F001`(scan-baseline,跨子系統,已 done 有原始碼)**:`ProjectMeta` / `SourceFile` / `ModuleName`(`src/Knot/Meta/Types.hs`)是 `QualName` 對映回 module 的唯一依據(驗收標準 4);測試路徑另用 `loadProjectMeta` 對 fixture 副本產生真實輸入。
- **`export-query/F004`(cli-wiring,跨子系統,已 done 有原始碼)**:前置 2 直接修改 `app/Knot/App/Cli.hs` 的 `ExtractCmd`、`extractParser` 與 `toExtractOptions`,並刪掉引用其假設 A8 的 haddock。**這是修改相依,不是呼叫相依**——本 feature 的 library 程式碼不 import 任何 executable 模組。

未列入的相依與理由:

- **`project-meta/F003`(hie-discovery)**:本 feature 不讀 `pmHie`(`.hie` 清單是 `F003` 的輸入),只讀 `pmSources`。`hieFiles` 的三項保證由 `F003` 承接,對本 feature 是間接的
- **`project-meta/F002`(cabal-components)**:只改變 `sfIncluded` / `sfOwners` 的填值;本 feature 收到的 `pmSources` 已由 `runBackends` 窄化(F001 假設 A1),不自行判定
- **graph-core / export-query 的圖層任務**:方向相反,它們消費本 feature 的事實
- **`ADR-001`(GHC 版本鎖)**:版本檢出全部落在 `F003` 的 `probeHiedb`;本 feature 只在 fixture 測試裡順帶釘住(見 T9),不實作檢查

可平行性:**不可**與 `F003` 平行;與 graph-core、export-query 的圖層任務可平行(無交集,但 graph-core 階段二要等本 feature 的 DTO 變更落地,見「回報給編排者」)。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])` | 簽名**一字不改** |
| `Backend` 的 hiedb 實例執行面 `bRun` | `hiedbBackend = Backend { bName = hiedbName, bLevel = DeclLevel, bProbe = probeHiedb, bRun = runHiedb }`;`runHiedb` 內 `ensureIndex` → `readIndexFacts`(契約卡原文的呼叫順序) |
| 事實流 DTO `NameSpace` 四值 | 前置 1:`ValueNs` / `DataConNs` / `TypeNs` / `FieldNs`,與 hiedb 的 `occ` 前綴一對一 |
| 事實流 DTO `FactRef.frGenerated :: Bool` | 前置 1:新增欄位,位置依 design.md 原文(`frTarget` 之後、`frFile` 之前) |
| 產出 `FactDecl` / `FactRef` | `FactDecl` 出自 `defs` × `mods`;`FactRef` 出自 `refs` LEFT JOIN `decls` × `mods` |
| 抽取規則 4(fromDecl 由 SQL span 包含 join 解析、取最內層) | SQL 做 join(一對多),最內層挑選與 `(qnSpace, qnOcc)` 破雷在 Haskell 做(理由見「實作方式 › 4」) |
| 抽取規則 4a(`frGenerated` 原樣轉載) | 直接投影 `refs.is_generated`,**不過濾、不詮釋** |
| 抽取規則 1(納入範圍) | 只用 `pmSources`(已由 `runBackends` 窄化為 `sfIncluded = True`)做對映;對映不到的 module 整批跳過 + 警告 |
| 抽取規則 6(索引位置與 `dbPath` 改道) | 不自行決定路徑,一律用 `ihDbPath`;前置 2 讓 `--db` / `--hiedb` 真的傳得進 `ExtractOptions` |
| 抽取規則 7(best-effort) | 三條查詢各自包例外:單查詢失敗 → 警告 + 該類事實為空,其餘照出;`ensureIndex` 失敗 → 整個後端降級(見「實作方式 › 6」) |
| 抽取規則 8(決定性) | SQL 全部帶 `ORDER BY`;挑選與破雷為全序;回傳前再排序一次 |
| 資料流管線段落「hiedb-facts:索引 SQLite → FactDecl/FactRef(單查詢失敗 → 警告)」 | 完全對應 |
| 規則 2(`FactImport` 只來自 import-scan) | **遵守**:本 feature 一筆 `FactImport` / `FactModule` 都不產(hiedb 的 `imports` 表本版不用) |
| 規則 3(auto 合成)、5(相容性探測) | 屬 `F001` / `F003`,本 feature 只把 `bLevel = DeclLevel` 交給 `synthLevel` |

超出 Level 2 契約的部分:**無**。`FactInstance` 依契約卡明文不產出(建構子保留)。三處契約留白由 Level 3 自主填補,已列入「待確認假設」(A1 `DeclKind` 的推導、A2 未知 namespace 的處置、A3 來源路徑對映策略)。

## 實作方式

### 模組配置

```text
src/Knot/Extract/HiedbFacts.hs    -- hiedbBackend + readIndexFacts + 純輔助函數
src/Knot/Extract.hs               -- 註冊表加入 hiedbBackend(改一行)
src/Knot/Extract/Types.hs         -- 前置 1:NameSpace 四值、FactRef 增 frGenerated
app/Knot/App/Cli.hs               -- 前置 2:--hiedb / --db
test/fixtures/hiedb/              -- F003 建立,本 feature 擴充(記錄欄位 + deriving)
```

`knot-hs.cabal` 的三處改動(`version: 0.0.1.0` 依 D4 **凍結不動**):

- library `exposed-modules` 加 `Knot.Extract.HiedbFacts`(`Knot.Extract.HiedbDriver` 由 `F003` 加)
- library `build-depends` 加 `sqlite-simple ^>=0.4.19`(design.md「使用的技術」已記選型;store 現有 `sqlite-simple-0.4.19.0` + `direct-sqlite-2.3.29`,自帶 C sqlite3、無系統依賴)
- test-suite `build-depends` 同樣加 `sqlite-simple`(驗收標準 3 的「逐筆相符」要獨立開 DB 對帳)

測試 group 命名 `extraction/F004 hiedb-facts`。**不加語言擴充**:專案 `src/` 與 `app/` 全部只靠 `GHC2024`(實查:零 `{-# LANGUAGE #-}`),所以 SQL 字串一律用 `Query . T.pack`(或 `fromString`),不開 `OverloadedStrings`。

### 0. 兩件前置

**前置 1 — C1/C2 契約更新落地**(`src/Knot/Extract/Types.hs`):

```haskell
-- 四值與 hiedb 的 occ 前綴一對一(design.md 原文的註解一併搬過來)
data NameSpace
  = ValueNs        -- ^ hiedb "v:" 一般值(函式、變數)
  | DataConNs      -- ^ hiedb "c:" 資料建構子
  | TypeNs         -- ^ hiedb "t:" 型別與 class(GHC 的 tcClsName,兩者同命名空間)
  | FieldNs        -- ^ hiedb "f<父型別>:" 記錄欄位選擇器
  deriving (Eq, Ord, Show)
```

`FactRef` 增 `frGenerated :: Bool`,欄位位置照 design.md 原文(`frTarget` 之後、`frFile` 之前)——位置決定 derive 出來的 `Ord`,而規則 8 的排序靠它。

連帶要調的既有測試(實查 `test/Main.hs` 的觸碰點):`genQual`(第 1073 行)的 `Gen.element [ValueNs, TypeNs]` → 四值;`FactRef` 的三處建構(第 807、862、1065 行)補上 `Bool`;`extractionF001Tests` 的 `test_types_construct`(第 841-873 行)補 `frGenerated` 斷言與四個 namespace 值。graph-core 現有程式碼**完全不受影響**(實查:`Knot.Graph.*` 只在註解提到 `FactRef`,未 pattern-match、未用 `NameSpace`)。

**前置 2 — CLI 補接 `--hiedb` / `--db`**(`app/Knot/App/Cli.hs`,範圍嚴格限縮在這兩個旗標):

- `ExtractCmd` 在 `ecHieDir` 之後、`ecStrict` 之前插入 `ecHiedbExe :: Maybe FilePath` 與 `ecDbPath :: Maybe FilePath`(位置對齊 system.md CLI 契約的旗標順序;`extractParser` 是 applicative 串接,**欄位序與解析序必須一致**)
- `extractParser` 對應位置加兩個 `optional (strOption …)`:`--hiedb PATH`(help `override the hiedb executable location`)、`--db FILE`(help `override the index location (default: <PATH>/.knot/hiedb.sqlite)`)
- `toExtractOptions` 改為 `XT.hiedbExe = ecHiedbExe c`、`XT.dbPath = ecDbPath c`
- haddock:刪掉「@hiedbExe@ 與 @dbPath@ 一律 'Nothing'…(假設 A8)」整段,改記「兩旗標對映 system.md CLI 契約」;`ExtractCmd` 的「六個旗標」改「八個旗標」
- 測試:`baseExtractCmd` / `fullExtractCmd` 補兩欄位(註解的「八個欄位」改「十個欄位」),`test_extract_flags_parse` 的全給定 argv 加 `--hiedb`/`--db`,`test_extract_options_mapping` 把兩條 `Nothing` 斷言改成透傳斷言

這是**缺陷修補**(Level 1 契約承諾了程式碼沒有的旗標),不動 CLI 的任何其他部分。

### 1. 上游原始碼查證(不是推測,是讀 hiedb 0.8.0.0 的原始碼)

編排者與 W3 的實測結論,本 feature 另行到 `hiedb-0.8.0.0` 原始碼複查了**行為成因**——設計依這些成因而非表象:

| 查證點 | 上游原始碼 | 結論 |
|---|---|---|
| schema 全貌 | `src/HieDb/Create.hs` `setupHieDb`(CREATE TABLE 原文) | 八張表:`mods` / `exports` / `refs` / `decls` / `imports` / `defs` / `typenames` / `typerefs`。**確無 instance 表**,契約卡的「不產 `FactInstance`」成立 |
| `refs` 欄位 | 同上 | `(hieFile, occ, mod, unit, sl, sc, el, ec, is_generated)`;`is_generated BOOLEAN NOT NULL` |
| `decls` 欄位 | 同上 | `(hieFile, occ, sl, sc, el, ec, is_root)`——**無 `mod` 欄**,module 必須 join `mods` |
| `defs` 欄位 | 同上 | `(hieFile, occ, sl, sc, el, ec)`,`PRIMARY KEY(hieFile, occ)` → **每個名字剛好一列** |
| `occ` 的 namespace 編碼 | `src/HieDb/Types.hs` `toNsChar` / `fromNsChar` / `instance ToField OccName` | 前綴共**五種**:`v:` `c:` `t:` `z:`(型別變數 `tvName`)`f<父型別>:`。契約的四值**沒有涵蓋 `z:`** → 見假設 A2 |
| `refs` 只收外部可見名 | `src/HieDb/Utils.hs` `goRef`(`Just mod <- nameModule_maybe name`) | 只有「有 module 的名字」進 `refs`;局部繫結(含多數型別變數)本來就不會出現,`z:` 屬邊界情況而非常態 |
| `refs.mod` 的語意 | 同上(`RefRow path occ (moduleName mod) …`) | 是**被引用者的定義 module**;引用發生地要走 `refs.hieFile` → `mods.mod` |
| `decls.is_root` 的語意 | `src/HieDb/Utils.hs` `isRoot`(`ValBind InstanceBind` / `Decl _ _`) | `is_root = 1` 即「頂層宣告(含 instance 繫結)」→ 正是 fromDecl 的候選集 |
| `defs` 的涵蓋範圍 | `src/HieDb/Utils.hs` `genDefRow`(`nameModule_maybe name == Just smod`) | 只收**本 module 定義**的名字,且含資料建構子、記錄欄位、class method → 正是 `FactDecl` 的來源 |
| GHC 丟棄 decl 種類 | `goDec` 只存 `is_root`,`Decl DeclType` 的 `DeclType` **被丟掉** | hiedb 0.8 **無法**區分 data / class / synonym / family → `DeclKind` 只能由 namespace 粗推,見假設 A1 |
| `mods.hs_src` 怎麼來 | `src/HieDb/Create.hs` `addRefsWithFile`:`makeAbsolute (srcBaseDir </> hie_hs_file)` | **絕對路徑**(不是相對!),且 `--src-base-dir` 未給時為 `NULL`、`is_real = 0`。`F003` 傳 `--src-base-dir "."` + `cwd = rootAbs`,故 `hs_src = <rootAbs>\<GHC 記的相對路徑>`,Windows 為反斜線 |
| `mods.hieFile` 怎麼來 | `src/HieDb/Utils.hs` `getHieFilesIn`:`canonicalizePath path` | 也是**絕對且已 canonical 化**的路徑(可能與 `makeAbsolute` 的大小寫/短檔名形式不同)→ 不可直接與 `ihRootDir` 做 `makeRelative` |
| `Completed!` 計數 / 重用 | `src/HieDb/Run.hs` `doIndex` | 與 W3 實測一致(本 feature 不解析輸出,只註記 `F003` 的判讀有上游依據) |

**對設計的三個直接後果**:(a) 來源路徑必須用「正規化 + 後綴比對」而非前綴相減(A3);(b) `DeclKind` 只能粗推(A1);(c) `z:` 與任何不認得的前綴要有明確處置(A2)。

### 2. `readIndexFacts` 總流程

```text
readIndexFacts h pm
  │
  ├─ withConnection (ihDbPath h) $ \conn →
  │
  ├─ ① Q_MODS:  SELECT hieFile, mod, hs_src, is_boot, is_real FROM mods ORDER BY hieFile
  │      → 建 modIndex :: Map Text ModEntry            (key = hieFile)
  │        ModEntry { meModule :: ModuleName, meFile :: FilePath }
  │        · is_boot = 1                → 靜默略過(.hs-boot 不在 pmSources,不是錯誤)
  │        · resolveSource 不中          → 略過 + 一則警告(驗收標準 4)
  │
  ├─ ② Q_DEFS:  SELECT hieFile, occ, sl FROM defs ORDER BY hieFile, occ
  │      → 每列:modIndex 查 hieFile(查不到 → 已在 ① 記過警告,靜默略過)
  │              parseOcc occ → (occText, ns);Nothing → 計入未知 namespace 統計
  │              FactDecl { fdName = QualName mod occText ns
  │                       , fdKind = declKindOf ns
  │                       , fdFile = meFile, fdLine = sl }
  │
  ├─ ③ Q_REFS:  refs LEFT JOIN decls(span 包含,d.is_root = 1)ORDER BY 見下
  │      → 依「ref 鍵」分組(相鄰列)→ pickFromDecl 選最內層 → 每組一筆
  │              FactRef { frFromModule = mod(來自 r.hieFile)
  │                      , frFromDecl   = 選中的候選(無候選 → Nothing)
  │                      , frTarget     = QualName (ModuleName r.mod) occ ns
  │                      , frGenerated  = r.is_generated      ← 原樣轉載
  │                      , frFile = meFile, frLine = r.sl }
  │
  ├─ 未知 namespace 統計 → 每個相異前綴彙整成**一則**警告(不逐列出警告)
  └─ 回 (sort facts, ihNotes h ++ 蒐集到的警告)
```

三條查詢**各自**包 `try @SomeException`(規則 7「單表查詢失敗 → 警告 + 跳過」):`Q_MODS` 失敗 → 回 `([], [警告])`(沒有 module 對映就什麼都產不出);`Q_DEFS` / `Q_REFS` 失敗 → 該類事實為空 + 一則警告,另一類照出。

`ihNotes h` 依 `F003` 假設 A2(閘門已裁決採納)在此併入回傳的 `[ExtractWarning]`——這是 `.knot/` 首建提示唯一的出口。

### 3. 來源路徑與 module 對映(驗收標準 4 的落點)

**兩層策略**,逐 `mods` 列判定,結果進 `modIndex`:

1. **`hs_src` 後綴比對**(主路徑):把 `hs_src` 反斜線換正斜線後,在 `pmSources` 中找**最長的** `sfPath` 使得 `hs_src` 以 `"/" <> sfPath` 結尾(或整串相等)。命中即取該 `sfPath` **原文**當 `meFile`
2. **`mods.mod` ↔ `sfModule` 唯一比對**(退路):`hs_src` 為 `NULL`(`--src-base-dir` 解析不到來源檔,多套件專案的常見情形)或第 1 層落空時,找 `sfModule == Just (ModuleName mod)` 的 `SourceFile`;**恰好一筆**才採用,零筆或多筆(例:多個 `Main`)視為落空
3. 兩層都落空 → 一則 `ExtractWarning{ ewSource = <hieFile>, ewMessage = "cannot map indexed module <mod> back to pmSources; skipping its decls and refs" }`,該 module 的 `defs` / `refs` 全部略過

用後綴比對而非 `makeRelative (ihRootDir h)` 的理由是查證出來的:`mods.hieFile` 走 `canonicalizePath`、`hs_src` 走 `makeAbsolute`,兩者與 `ihRootDir` 的大小寫、8.3 短檔名、symlink 解析都可能不同形,前綴相減會在真實 Windows 專案上零星失敗;後綴比對只依賴「repo 相對路徑是絕對路徑的尾段」這個必然成立的事實。取 `sfPath` **原文**(而非自己拼路徑)則保證 `fdFile` / `frFile` 與 import-scan 的 `fmFile` / `fiFile` **逐字相同**——這是 graph-core 把 decl 節點掛回 module 節點的前提。

### 4. fromDecl 解析(抽取規則 4)

SQL 出候選(一對多),Haskell 挑最內層:

```sql
SELECT r.hieFile, r.occ, r.mod, r.sl, r.sc, r.el, r.ec, r.is_generated,
       d.occ, d.sl, d.sc, d.el, d.ec
FROM refs r
LEFT JOIN decls d
  ON r.hieFile = d.hieFile AND d.is_root = 1
 AND (d.sl <  r.sl OR (d.sl = r.sl AND d.sc <= r.sc))
 AND (r.el <  d.el OR (r.el = d.el AND r.ec <= d.ec))
ORDER BY r.hieFile, r.sl, r.sc, r.el, r.ec, r.occ, r.mod, r.is_generated,
         d.sl, d.sc, d.el, d.ec, d.occ
```

- **`LEFT JOIN` 是刻意的**:落在任何 root decl 之外的引用(export list、import 行、頂層型別簽章外圍…)仍要產出 `FactRef`,只是 `frFromDecl = Nothing`——graph-core 組裝規則 2 對這種事實有明確的「以來源 module 節點為源」處理,漏掉就是漏事實
- **最內層挑選在 Haskell 做**,不在 SQL 做。SQL 排不出正確的破雷序:契約要求同大小時依 `(qnSpace, qnOcc)` 字典序,而 `qnSpace` 是**解析後**的建構子序(`ValueNs < DataConNs < TypeNs < FieldNs`),原始 `d.occ` 字串序卻是 `c… < f… < t… < v…`,兩者不同。SQL 的 `ORDER BY` 只負責讓同一個 ref 的候選**相鄰且順序固定**
- **「span 最小」的落實**:候選都包含同一個 ref,故以 `(起點最大, 終點最小)` 即為最內層。比較序:`Down (d.sl, d.sc)` → `(d.el, d.ec)` → `(qnSpace, qnOcc)`,取最小者。解析不出 namespace 的候選直接淘汰
- 「ref 鍵」= `(hieFile, sl, sc, el, ec, occ, mod, is_generated)`。同鍵的相鄰列即一組(SQL 已排序);`unit` 不入鍵——它只影響「哪個套件定義了這個名字」,而 `QualName` 沒有 unit 欄位(見假設 A4)

### 5. `parseOcc` 與 `declKindOf`(純函數)

```text
parseOcc :: Text -> Maybe (Text, NameSpace)
  以第一個 ':' 切開 → (prefix, rest);rest 必須以 ':' 起頭,occ = drop 1 rest
    prefix == "v"                     → ValueNs
    prefix == "c"                     → DataConNs
    prefix == "t"                     → TypeNs
    prefix 以 'f' 起頭(長度 ≥ 1)     → FieldNs        ← 與上游 fromNsChar 同一判準
    其他(含 "z" 型別變數)            → Nothing        ← 假設 A2
```

`occ` 本身含 `:`(運算子如 `:|`、`:+:`)不會出錯:切在**第一個** `:`,`"c::|"` → `("c", ":|")`。判斷順序把 `v`/`c`/`t` 放前面,與上游 `fromNsChar` 的語意一致(那三個都不以 `f` 起頭,先後不影響結果)。

```text
declKindOf :: NameSpace -> DeclKind
  ValueNs   → ValueDecl
  FieldNs   → ValueDecl        -- 記錄欄位選擇器是值
  DataConNs → DataDecl         -- 資料建構子出自 data 宣告
  TypeNs    → DataDecl         -- 假設 A1:hiedb 丟掉了 DeclType,無從區分 class/synonym/family
```

### 6. 後端組裝與錯誤通道

```haskell
hiedbBackend :: Backend
hiedbBackend = Backend
  { bName  = hiedbName          -- F001 的契約字串常數,BackendChoice HiedbOnly 靠它比對
  , bLevel = DeclLevel
  , bProbe = probeHiedb         -- F003(假設 A1 裁決:後端值由本 feature 組裝)
  , bRun   = runHiedb
  }

runHiedb opts pm = do
  r <- ensureIndex opts pm
  case r of
    Left err -> throwIO (HiedbFactsError err)   -- 見下
    Right h  -> readIndexFacts h pm
```

`Knot.Extract.hs` 的註冊表改為 `[importScanBackend, hiedbBackend]`(順序即 `erReports` 序,import-scan 維持在前)。

**`bRun` 沒有失敗通道**(`IO ([Fact], [ExtractWarning])`),而 `ensureIndex` 會回 `Left`(probe 過了但 `hiedb index` 炸掉)。處置:定義

```haskell
newtype HiedbFactsError = HiedbFactsError Text
instance Show HiedbFactsError where show (HiedbFactsError t) = T.unpack t
instance Exception HiedbFactsError where displayException (HiedbFactsError t) = T.unpack t
```

`runOne`(`src/Knot/Extract/Backend.hs:100-112`)的 `attempt` 會把它轉成 `BackendReport hiedb False <原文>` + 一則警告,`erLevel` 自然退回 `ModuleLevel`。**已實測驗證**(GHC 9.14.1 實跑一支小程式):`displayException (e :: SomeException)` 對這樣的自訂例外回傳的就是原文本身,**不夾帶 backtrace**,故 `brDetail` 仍以 `"hiedb index failed: "` 起頭,前綴斷言成立。

不改成「回空事實 + 警告」的理由:那會讓 `brUsed = True`、`erLevel` 升到 `DeclLevel`,對外謊報「函式級成功」——比失敗更糟。

### 7. fixture 擴充(D6 / D7)

`F003` 的 `test/fixtures/hiedb/`(兩 module + 真實 `.hie`)已覆蓋 `v:`(`greet`)、`c:` / `t:`(`data Color`)與跨 module 呼叫,但**缺 `f<父型別>:` 與產生碼 ref**。本 feature 就地擴充 `src/Demo/Core.hs`(**維持兩個 module**,以免動到 `F003` 的 `IndexStats 2 0 1` 斷言):

- 加一個記錄型別(如 `data Config = Config { cfgName :: String }`)→ 產出 `fConfig:cfgName`
- 給 `data Color` 加 `deriving (Eq, Show)` → 產出 `is_generated = 1` 的 refs(驗收標準 3 要有非空樣本)
- `Demo.App.run` 維持呼叫 `Demo.Core.greet`(跨 module ref 樣本),並讓呼叫寫在一個頂層宣告內(`frFromDecl` 樣本)

`.hie` 依 `F003` 記錄的指令重產(於 fixture 目錄:`ghc -fno-code -fwrite-ide-info -hiedir .hie -isrc src/Demo/App.hs src/Demo/Core.hs`),**不入測試流程**,只記在測試原始碼註解。所有寫入型測試沿用 `withScratchTree` 把 fixture 複製到暫存目錄再跑(`F003` 假設 A6),版控樹全程唯讀。

**跳過機制**沿用 `F003` T5 的同一套(D7):`main` 先 `findExecutable "hiedb"`,無則印原因 + 跳過數,並把 F003/F004 的 hiedb 相依群組換成名稱含跳過數的佔位節點。本 feature 只**加掛**自己的測試到同一個開關,不另建一套。

## 使用到的既有串接介面

(專案內簽名為 2026-08-21 自來源檔案讀出的**原文**;`sqlite-simple` 簽名讀自 `sqlite-simple-0.4.19.0` 的 hackage 原始碼;`F003` 那三列**來自其設計文檔而非原始碼**,已在「來源檔案」欄標明)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Backend = Backend { bName :: Text, bLevel :: CapabilityLevel, bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult, bRun :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning]) }` | src/Knot/Extract/Backend.hs:34-39 | F001 | 組裝 `hiedbBackend`(四個欄位全填) |
| `data ProbeResult = Available \| Unavailable Text` `deriving (Eq, Show)` | src/Knot/Extract/Backend.hs:42-43 | F001 | `bProbe` 的回傳型別(值由 `probeHiedb` 提供) |
| `hiedbName :: Text` (= `"hiedb"`) | src/Knot/Extract/Backend.hs:50-51 | F001 | `hiedbBackend` 的 `bName`;警告的 `ewSource` |
| `importScanName :: Text` (= `"import-scan"`) | src/Knot/Extract/Backend.hs:46-47 | F001 | 測試斷言 `erReports` 兩筆的來源辨識 |
| `runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult` | src/Knot/Extract/Backend.hs:68 | F001 | 註冊表的調度引擎(`extract` 委派給它);T8 直接以它驗兩後端並存 |
| `extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult` / `registeredBackends :: [Backend]`(不匯出) | src/Knot/Extract.hs:19-25 | F001 | **本 feature 修改處**:註冊表加入 `hiedbBackend` |
| `data ExtractOptions = ExtractOptions { rootDir :: FilePath, backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | src/Knot/Extract/Types.hs:33-38 | F001 | `bRun` 的第一參數;前置 2 讓後兩欄真的收得到 CLI 值 |
| `data ExtractResult = ExtractResult { erFacts :: [Fact], erLevel :: CapabilityLevel, erReports :: [BackendReport], erWarnings :: [ExtractWarning] }` | src/Knot/Extract/Types.hs:44-49 | F001 | T8 / T11 的斷言對象 |
| `data CapabilityLevel = ModuleLevel \| DeclLevel` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:53-54 | F001 | `hiedbBackend` 的 `bLevel = DeclLevel`(`synthLevel` 取最大) |
| `data QualName = QualName { qnModule :: ModuleName, qnOcc :: Text, qnSpace :: NameSpace }` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:57-62 | F001 | `FactDecl` / `FactRef` 的名字原料 |
| `data NameSpace = ValueNs \| TypeNs` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:64-65 | F001 | **本 feature 修改處**(前置 1):擴為四值 |
| `data Fact = FactModule{…} \| FactImport{…} \| FactDecl { fdName :: QualName, fdKind :: DeclKind, fdFile :: FilePath, fdLine :: Int } \| FactRef { frFromModule :: ModuleName, frFromDecl :: Maybe QualName, frTarget :: QualName, frFile :: FilePath, frLine :: Int } \| FactInstance{…}` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:67-85 | F001 | 產出 `FactDecl` / `FactRef`;**本 feature 修改處**(前置 1):`FactRef` 增 `frGenerated :: Bool` |
| `data DeclKind = ValueDecl \| DataDecl \| ClassDecl \| InstanceDecl \| TypeSynDecl \| PatSynDecl \| FamilyDecl` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:87-90 | F001 | `declKindOf` 的值域(本版只用到前兩個,假設 A1) |
| `data BackendReport = BackendReport { brBackend :: Text, brUsed :: Bool, brDetail :: Text }` `deriving (Eq, Show)` | src/Knot/Extract/Types.hs:92-97 | F001 | T8 斷言降級原因落在 `brDetail` |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` `deriving (Eq, Show)` | src/Knot/Extract/Types.hs:100-104 | F001(D1) | 對映失敗、未知 namespace、查詢失敗的警告;`ihNotes` 的元素型別 |
| `importScanBackend :: Backend` | src/Knot/Extract/ImportScan.hs:47-53 | F002 | 註冊表既有成員(本 feature 併排註冊);T8 驗兩後端事實合流 |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` `deriving (Eq, Show)` | src/Knot/Meta/Types.hs:29-35 | project-meta/F001 | `readIndexFacts` 的第二參數;**只讀 `pmSources`** |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` `deriving (Eq, Show)` | src/Knot/Meta/Types.hs:65-71 | project-meta/F001 | `sfPath`(repo 相對正斜線)是 `fdFile`/`frFile` 的來源;`sfModule` 是第 2 層對映的依據 |
| `newtype ModuleName = ModuleName Text` `deriving (Eq, Ord, Show)` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | `QualName.qnModule` 與 `frFromModule` 的型別(D2:沿管線共用) |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` `deriving (Eq, Show)` | src/Knot/Meta/Types.hs:22-27 | project-meta/F001 | 僅測試路徑:對 fixture 副本組出真實輸入 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 僅測試路徑:讓 `pmSources` 來自真實掃描而非手寫常數 |
| `ensureIndex :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)` | **F003 設計文檔**(尚無原始碼).design/subsystems/extraction/features/F003-hiedb-driver.md「新增的介面」 | F003 | `runHiedb` 的第一步;`Left` 轉 `HiedbFactsError` |
| `data IndexHandle`(抽象型別)/ `ihDbPath :: IndexHandle -> FilePath` / `ihRootDir :: IndexHandle -> FilePath` / `ihNotes :: IndexHandle -> [ExtractWarning]` | **F003 設計文檔**(尚無原始碼)同上 | F003 | `ihDbPath` 開 SQLite;`ihNotes` 併入回傳警告;`ihRootDir` 本 feature **刻意不用**(見「實作方式 › 3」的後綴比對理由) |
| `probeHiedb :: ExtractOptions -> ProjectMeta -> IO ProbeResult` | **F003 設計文檔**(尚無原始碼)同上 | F003 | `hiedbBackend` 的 `bProbe` |
| `data ExtractCmd = ExtractCmd { ecPath :: FilePath, ecOutput :: Maybe FilePath, ecBackend :: BackendChoice, ecModuleOnly :: Bool, ecIncludeTests :: Bool, ecHieDir :: Maybe FilePath, ecStrict :: Bool, ecSummary :: Maybe SummaryMode }` `deriving (Eq, Show)` | app/Knot/App/Cli.hs:79-89 | export-query/F004 | **前置 2 修改處**:插入 `ecHiedbExe` / `ecDbPath` 兩欄位 |
| `toExtractOptions :: ExtractCmd -> XT.ExtractOptions` | app/Knot/App/Cli.hs:238-244 | export-query/F004 | **前置 2 修改處**:兩欄位改為透傳(現為寫死 `Nothing`) |
| `extractParser :: Parser ExtractCmd` | app/Knot/App/Cli.hs:127-156 | export-query/F004 | **前置 2 修改處**:加 `--hiedb` / `--db` 兩個 `optional (strOption …)` |
| `withConnection :: String -> (Connection -> IO a) -> IO a` | sqlite-simple-0.4.19.0 Database/SQLite/Simple.hs:177 | - | 以 `ihDbPath` 開索引、離開作用域自動關閉 |
| `query_ :: FromRow r => Connection -> Query -> IO [r]` | sqlite-simple-0.4.19.0 Database/SQLite/Simple.hs:359 | - | 三條 SQL 皆無參數替換(`Q_MODS` / `Q_DEFS` / `Q_REFS`) |
| `newtype Query = Query { fromQuery :: T.Text }` `deriving (Eq, Ord, Typeable)` + `instance IsString Query` | sqlite-simple-0.4.19.0 Database/SQLite/Simple/Types.hs:62-73 | - | SQL 文字;專案不開 `OverloadedStrings`,故一律 `Query . T.pack` |
| `class FromRow a where fromRow :: RowParser a` / `field :: FromField a => RowParser a` | sqlite-simple-0.4.19.0 Database/SQLite/Simple/FromRow.hs:128 | - | `Q_REFS` 有 13 欄(超過內建元組上限 10),以私有 record + 手寫 `FromRow` 承接 |
| `instance FromField T.Text` / `instance FromField Int` / `instance FromField Bool`(僅接受 `SQLInteger` 0\|1)/ `instance FromField a => FromField (Maybe a)` | sqlite-simple-0.4.19.0 Database/SQLite/Simple/FromField.hs:101,122,154,161 | - | `occ`/`mod`/`hs_src` 取 `Text`;`sl`/`sc`/`el`/`ec` 取 `Int`;`is_generated`/`is_boot`/`is_real` 取 `Bool`;`LEFT JOIN` 的 `d.*` 取 `Maybe` |
| `data SQLError = SQLError { sqlError :: !Error, sqlErrorDetails :: Text, sqlErrorContext :: Text }` | direct-sqlite-2.3.29 Database/SQLite3.hs:254-262 | - | 查詢失敗的例外型別(本 feature 以 `SomeException` 統包,沿用 `Backend.attempt` 的既有作法) |
| `Control.Exception.try :: Exception e => IO a -> IO (Either e a)` / `throwIO :: Exception e => e -> IO a` / `displayException :: Exception e => e -> String` | base-4.22(GHC 9.14.1) | - | 每條查詢包 `try`(規則 7);`ensureIndex` 的 `Left` 以 `throwIO` 走 `runOne` 的降級通道 |
| `Data.List.sortBy` / `Data.List.sort` / `Data.Ord.Down` | base-4.22 | - | 候選排序(起點降序)與事實流最終排序(規則 8) |
| `Data.Map.Strict.Map` / `fromList` / `lookup` | containers(已在 build-depends) | - | `modIndex :: Map Text ModEntry`(key = `mods.hieFile`) |
| `System.Directory.findExecutable :: String -> IO (Maybe FilePath)` | directory-1.3.10.0 | - | 僅測試路徑:D7 跳過機制(與 `F003` 共用同一個開關) |

## 新增的介面

全部落在 Level 2 契約內(`readIndexFacts` 簽名照抄;`hiedbBackend` 是契約點名的「`Backend` hiedb 實例」)。純輔助函數依既有慣例以 haddock 標註非契約面。

**`Knot.Extract.HiedbFacts`**

```haskell
module Knot.Extract.HiedbFacts
  ( -- * 後端
    hiedbBackend
    -- * Level 2 模組介面
  , readIndexFacts
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , parseOcc
  , declKindOf
  , resolveModuleSource
  , pickFromDecl
  ) where
```

```haskell
-- | hiedb 後端(T1):@bLevel = DeclLevel@,探測面來自 F003 的 'probeHiedb',
--   執行面先 'ensureIndex' 再 'readIndexFacts'。
hiedbBackend :: Backend

-- | 從就緒索引讀 decl 層事實(Level 2 模組介面,簽名照契約)。
--   回傳的警告含 'ihNotes'(F003 A2 的 .knot/ 首建提示)。不抛例外。
readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])

-- * 內部純函數

-- | hiedb 的 @occ@ 前綴 → (裸 occ 名, namespace)。
--   不認得的前綴(含型別變數 @z:@)回 'Nothing',呼叫端彙整成一則警告。
parseOcc :: Text -> Maybe (Text, NameSpace)

-- | namespace → 'DeclKind'(hiedb 0.8 不保存 GHC 的 DeclType,只能粗推;假設 A1)。
declKindOf :: NameSpace -> DeclKind

-- | 一列 @mods@ 對應到 'pmSources' 的哪個檔案:先 @hs_src@ 後綴比對,
--   再退回 @mod@ ↔ @sfModule@ 唯一比對;都不中回 'Nothing'。
--   回傳的是 @sfPath@ **原文**(與 import-scan 的 @fmFile@ 逐字相同)。
resolveModuleSource
  :: [SourceFile]      -- ^ pmSources(已由 backend-select 窄化)
  -> ModuleName        -- ^ mods.mod
  -> Maybe Text        -- ^ mods.hs_src(NULL 時為 Nothing)
  -> Maybe FilePath

-- | 抽取規則 4:從 span 包含 join 的候選中取最內層;
--   同 span 依 @(qnSpace, qnOcc)@ 字典序破雷;無候選回 'Nothing'。
pickFromDecl :: [(SrcSpan4, QualName)] -> Maybe QualName
  -- SrcSpan4 = (Int, Int, Int, Int),即 (sl, sc, el, ec)
```

**`Knot.Extract.Types`(前置 1 的契約更新)**:`NameSpace` 四值、`FactRef` 增 `frGenerated :: Bool`(內容見「實作方式 › 0」)。

**`Knot.App.Cli`(前置 2)**:`ExtractCmd` 增 `ecHiedbExe` / `ecDbPath` 兩欄位;`extractParser` 增 `--hiedb` / `--db`;`toExtractOptions` 改為透傳。屬 executable 內部,非 library 對外面。

## TodoList

- [x] T1: 前置 1——`Knot.Extract.Types` 的 `NameSpace` 擴為四值、`FactRef` 增 `frGenerated`(欄位位置照 design.md),同步調整既有測試的四處觸碰點;`cabal build all` 與既有測試全綠  `dep: F001`
- [x] T2: 前置 2——CLI `--hiedb` / `--db`:`ExtractCmd` 兩欄位、`extractParser` 兩旗標、`toExtractOptions` 透傳、刪掉引用 export-query F004 假設 A8 的 haddock  `dep: export-query/F004`
- [x] T3: `knot-hs.cabal` 加 `sqlite-simple`(library + test-suite)與 `exposed-modules`;`Knot.Extract.HiedbFacts` 骨架:`withConnection` 開闔、`Query . T.pack` 的 SQL 常數、私有 row record 與手寫 `FromRow`;`cabal build all` 通過  `dep: T1`
- [x] T4: `parseOcc` 與 `declKindOf`——四種前綴判讀、含 `:` 的運算子 occ、`z:` 與其他不認得的前綴回 `Nothing`  `dep: T3`
- [x] T5: `resolveModuleSource`——`hs_src` 反斜線正規化 + 最長後綴比對、`hs_src = NULL` 退回 `sfModule` 唯一比對、多筆同名時落空、回傳 `sfPath` 原文  `dep: T3`
- [x] T6: `pickFromDecl`——最內層挑選(起點最大、終點最小)、同 span 依 `(qnSpace, qnOcc)` 破雷、空候選回 `Nothing`  `dep: T4`
- [x] T7: `readIndexFacts` 主流程——三條 SQL(含 `LEFT JOIN` 與 `ORDER BY`)、`modIndex` 建立與 `is_boot` 略過、`FactDecl` / `FactRef` 產出(含 `frGenerated` 原樣轉載)、對映失敗與未知 namespace 的彙整警告、`ihNotes` 併入、最終排序  `dep: T5, T6, F003`
- [x] T8: `hiedbBackend` 組裝 + `Knot.Extract` 註冊表併排註冊 + `HiedbFactsError` 例外通道(`ensureIndex` 的 `Left` → `brUsed = False` + 原文)  `dep: T7, F003`
- [x] T9: fixture 擴充——`test/fixtures/hiedb/src/Demo/Core.hs` 加記錄型別與 `deriving`,重產兩個 `.hie`(維持兩 module),產生指令寫進測試原始碼註解  `dep: F003`
- [x] T10: 端到端驗收(fixture 副本,需 hiedb)——跨 module `FactRef` 的 `frFromDecl` 正確、四種 namespace 齊備、`frGenerated` 與 DB 逐筆對帳、`QualName` 全部對映得回 `pmSources`、連跑兩次結果相同  `dep: T7, T9`
- [x] T11: knot-hs 自身唯讀驗收(需 hiedb 且自身有 `.hie`)——`--db` 改道暫存目錄、走完整 `extract`、`erLevel == DeclLevel`、兩後端報告皆 `brUsed = True`、`<repo>/.knot/` 未被建立;實跑數據記入「實作備註」  `dep: T8`

## 1-to-1 測試對照表

(標「**需 hiedb**」者納入 D7 的跳過機制,與 `F003` 共用同一個開關;其餘在任何環境都會執行)

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_namespace_and_generated | `NameSpace` 四個建構子皆可構造且 `Ord` 序為 `ValueNs < DataConNs < TypeNs < FieldNs`;`FactRef` 可帶 `frGenerated = True/False` 且選擇器取值正確;兩個只差 `frGenerated` 的 `FactRef` 以 `compare` 分得開(釘住規則 8 的排序依據);既有 `extraction/F001` 測試群全綠(契約變更未破壞既有行為) |
| T2 | test_hiedb_db_flags | `["extract"]` → `ecHiedbExe == Nothing && ecDbPath == Nothing`;`["extract", "--hiedb", "C:/tools/hiedb.exe", "--db", "/tmp/x.sqlite"]` → 兩欄位為對應值,且 `toExtractOptions` 的 `XT.hiedbExe` / `XT.dbPath` **逐字透傳**(釘住缺陷已修);`--db` 缺參數 → `ExitFailure 1` 且訊息含 `--db`;其餘八個欄位不受影響(與 `baseExtractCmd` 只差這兩欄) |
| T3 | test_hiedb_facts_smoke | 對一個**空的**暫存 SQLite(只 `open`/`close`,無 hiedb schema)呼叫 `readIndexFacts` → 不抛例外、事實為空、警告非空(釘住規則 7 的「單查詢失敗 → 警告」與「不抛例外」);`hiedbBackend` 的 `bName == hiedbName`、`bLevel == DeclLevel` |
| T4 | test_parse_occ | `"v:foo"` → `(foo, ValueNs)`;`"c:Red"` → `DataConNs`;`"t:Color"` → `TypeNs`;`"fConfig:cfgName"` → `(cfgName, FieldNs)`;運算子 `"c::\|"` → `(":\|", DataConNs)`、`"v:.:+:"` 類含冒號的 occ 切在第一個冒號;`"z:a"`、`"foo"`(無冒號)、`""`、`"q:x"` → `Nothing`;`declKindOf` 四值對映(`ValueNs`/`FieldNs` → `ValueDecl`,`DataConNs`/`TypeNs` → `DataDecl`) |
| T5 | test_resolve_module_source | `hs_src = "C:\\proj\\src\\Demo\\Core.hs"` × `sfPath = "src/Demo/Core.hs"` → 回 `"src/Demo/Core.hs"` **原文**;同時存在 `"Core.hs"` 與 `"src/Demo/Core.hs"` 時取**最長**後綴;僅部分片段相符(`"emo/Core.hs"`)**不**命中(邊界必須落在 `/`);`hs_src = Nothing` 且 `sfModule` 唯一命中 → 回該 `sfPath`;`sfModule` 有兩筆同名(兩個 `Main`)→ `Nothing`;兩層皆落空 → `Nothing` |
| T6 | test_pick_from_decl | 兩個巢狀候選(外層 `(1,1,20,1)` 的 `t:X`、內層 `(3,1,5,10)` 的 `v:go`)→ 取內層;三層巢狀取最內;**同 span** 的 `c:QueryNode` 與 `t:QueryNode`(C3 實測情形)→ 依 `(qnSpace, qnOcc)` 取 `DataConNs` 那個(建構子序 `DataConNs < TypeNs`),且**與輸入順序無關**(把候選清單反轉,結果相同);空候選 → `Nothing` |
| T7 | test_read_index_facts | **需 hiedb**:fixture 副本 → `loadProjectMeta` → `ensureIndex` → `readIndexFacts`:`FactDecl` 涵蓋 `greet`(`ValueNs`)、`Color`(`TypeNs`)、其建構子(`DataConNs`)與 `cfgName`(`FieldNs`),四種 namespace 齊備(驗收標準 2);每筆 `FactDecl.fdFile` / `FactRef.frFile` 都出現在 `map sfPath (pmSources pm)` 之中(驗收標準 4);把一個 `SourceFile` 從 `pmSources` 拿掉再跑 → 該 module 的事實消失且**恰多一則**警告(訊息含該 module 名);回傳警告的**開頭**是 `ihNotes` 的內容;全程不抛例外 |
| T8 | test_hiedb_backend_registered | **需 hiedb**:fixture 副本經 `extract`(`backendChoice = Auto`)→ `erLevel == DeclLevel`;`erReports` 兩筆、順序為 `["import-scan", "hiedb"]` 且皆 `brUsed == True`;`erFacts` 同時含 `FactImport`(來自 import-scan)與 `FactRef`(來自 hiedb);(無 hiedb 亦可)以 `hiedbExe = Just "<不存在的路徑>"` 走 `extract` → `erLevel == ModuleLevel`、hiedb 那筆 `brUsed == False` 且 `brDetail` 以 `"hiedb executable "` 起頭、import-scan 事實不受影響;以一個「`ensureIndex` 必失敗」的暫存樹 → `brDetail` 含 `"hiedb index failed: "` 且不抛例外(釘住 `HiedbFactsError` 通道) |
| T9 | test_hiedb_facts_fixture | `test/fixtures/hiedb/` 的兩個 `.hie` 皆 > 0 bytes、前 3 bytes 為 `"HIE"`、檔頭第二行等於 `showVersion fullCompilerVersion`(GHC 升版時先紅,指向「重產 fixture」);`src/Demo/Core.hs` 內含記錄欄位宣告與 `deriving`(釘住四 namespace 與產生碼樣本的來源不被後人改掉);fixture 仍**恰好兩個** `.hs` 與兩個 `.hie`(釘住 `F003` 的 `IndexStats 2 0 1` 不被本次擴充破壞) |
| T10 | test_hiedb_facts_acceptance | **需 hiedb**:fixture 副本上——(a) `Demo.App` 內對 `Demo.Core.greet` 的引用產出 `FactRef`,`frFromModule == "Demo.App"`、`frTarget == QualName "Demo.Core" "greet" ValueNs`、`frFromDecl == Just (QualName "Demo.App" "run" ValueNs)`(驗收標準 1);(b) 以 `sqlite-simple` 獨立查 `SELECT occ, mod, sl, sc, is_generated FROM refs` 與產出的 `FactRef` **逐筆對帳** `frGenerated`,且 `is_generated = True` 的樣本數 > 0(驗收標準 3);(c) 連續兩次 `readIndexFacts` 的 `[Fact]` 完全相等(驗收標準 5) |
| T11 | test_hiedb_selfcheck | **需 hiedb**,且 knot-hs 自身有 `.hie` 時才跑(否則印明原因跳過):以 `dbPath = Just <暫存路徑>` 對自身跑完整 `extract` → `erLevel == DeclLevel`、`FactDecl` 與 `FactRef` 數量 > 0、無「對映不到」警告(自身是單套件專案,應全數對映得回)、`<repo>/.knot/` 未被建立;事實數、警告數與未知 namespace 統計記入「實作備註」 |

## 待確認假設

- A1: `DeclKind` 無法由 hiedb 忠實推導 → 採取:**只依 namespace 粗推**(`ValueNs`/`FieldNs` → `ValueDecl`,`DataConNs`/`TypeNs` → `DataDecl`),不做啟發式。理由:已讀上游原始碼確認 `HieDb.Utils.goDec` 把 GHC 的 `Decl DeclType` 中的 `DeclType`(`DataDec`/`ClassDec`/`SynDec`/`FamDec`/…)**丟棄**,`decls` / `defs` 表都沒有這個資訊;可用的替代訊號只有 `exports.is_datacon` + `parent` 反推(只涵蓋**有匯出**的名字,且仍分不出 synonym 與 family),屬啟發式,與「extraction 不詮釋」相衝。實務衝擊有限:graph-core 的節點 id 鑄造只看 `qnSpace`(`#t` 後綴),`DeclKind` 目前僅作為 `NodeKind = DeclNode DeclKind` 的 payload,未被 export-query 使用 → 影響:若日後 `implements` 邊或匯出格式需要真正的 class/synonym 區分,得改由直接讀 `.hie`(繞過 hiedb)或加一個 `exports` 反推層,`declKindOf` 的簽名要從 `NameSpace -> DeclKind` 變成帶上下文的版本
- A2: hiedb 的 `occ` 前綴實為**五種**(上游 `toNsChar` 原文:`v:` `c:` `t:` `z:`(型別變數)`f<父型別>:`),契約的 `NameSpace` 四值**不涵蓋 `z:`** → 採取:`parseOcc` 對 `z:` 與任何不認得的前綴回 `Nothing`,該列**跳過**並把相同前綴彙整成**一則**警告(不逐列出警告,避免淹沒 stderr 與 `--strict` 誤判)。理由:`z:` 在 `refs` 幾乎不可能出現(上游 `goRef` 要求 `nameModule_maybe name` 有值,型別變數是局部名),硬塞進 `TypeNs` 會破壞契約註解宣稱的「與 hiedb 的 occ 前綴一對一」,也可能讓型別變數 `a` 與同名型別鑄出同一個節點 id;而自行加第五個建構子屬 Level 2 契約變更,委派模式不得擅改 → 影響:若閘門裁定要保留型別變數,`NameSpace` 加 `TyVarNs`(design.md 事實流 DTO 一處、`Knot.Extract.Types` 一處、`parseOcc` 一列、graph-core 的鑄造規則表一列)
- A3: 契約沒說 `hs_src`(絕對路徑)怎麼對回 repo 相對路徑 → 採取:**正規化 + 最長後綴比對 `sfPath`**,退路是 `mods.mod` ↔ `sfModule` 唯一比對,兩層皆落空才警告 + 跳過。理由:已讀上游確認 `hs_src` 走 `makeAbsolute`、`mods.hieFile` 走 `canonicalizePath`,兩者與 `ihRootDir` 的大小寫 / 短檔名 / symlink 解析可能不同形,`makeRelative` 式的前綴相減會零星失敗;後綴比對只依賴「repo 相對路徑是絕對路徑的尾段」,且取 `sfPath` 原文可保證與 import-scan 的 `fmFile` 逐字一致 → 影響:若裁定要用 `ihRootDir` 前綴相減,`resolveModuleSource` 換一個實作,且要處理路徑不同形時的失配(可能大量 module 對映不到)
- A4: `refs` 有 `unit` 欄(被引用者所屬套件),但 `QualName` 沒有 unit 欄位 → 採取:**丟棄 `unit`**,只用 `(mod, occ, namespace)` 組 `QualName`。理由:Level 2 明文「`QualName` 是 Module + OccName + namespace」,graph-core 的節點 id 鑄造規則也只認這三者;兩個不同套件提供同名 module 時會撞在一起,但 graph-core 只實化「事實流中出現過 `FactModule`」的內部 module,外部撞名不影響圖 → 影響:若日後要區分「同名 module 來自不同套件」,`QualName` 要加欄位(Level 2 契約變更,並牽動 graph-core 的 id 鑄造規則,而該規則明文「一經發佈不可變」)
- A5: 契約沒說 `FactRef` 要不要過濾指向外部套件(base、containers…)的引用 → 採取:**全部照出,不過濾**。理由:graph-core 組裝規則 1 要「指向外部的邊丟棄並彙整進 `gsDroppedExternal` / `gsTopExternalTargets`」,extraction 先過濾掉就等於把那個統計歸零;且「不做圖層面的聚合」是本卡的明確不做 → 影響:若實測事實流體量過大(knot-hs 自身 4740 refs,大專案可能十萬量級),可考慮在 extraction 就以 `refs.unit` 濾掉非本專案 unit,但那需要 Level 2 補一條規則並重新定義 `gsDroppedExternal` 的語意
- A6: 驗收標準 4 說「產出的 `QualName` 全部可對映回 `pmSources` 的 module」,但 `frTarget` 的 module 本來就大量是外部套件(A5)→ 採取:把驗收標準解讀為**專案內側的 `QualName`**(`FactDecl.fdName`、`FactRef.frFromModule`、`FactRef.frFromDecl`),它們全部出自被索引的 `mods` 列,對映不到才警告;`frTarget` 明文豁免 → 影響:若裁定 `frTarget` 也要能對映,等同於 A5 改為「過濾外部引用」,兩者連動
- A7: `ensureIndex` 回 `Left` 時 `bRun` 無失敗通道 → 採取:**丟 `HiedbFactsError` 例外**,讓 `Backend.runOne` 的 `attempt` 轉成 `brUsed = False` + 原文(已實測 GHC 9.14.1 的 `displayException (e :: SomeException)` 對自訂例外**不夾帶 backtrace**,前綴斷言成立)。理由:回「空事實 + 警告」會讓 `brUsed = True`、`erLevel` 升到 `DeclLevel`,對外謊報函式級成功 → 影響:若裁定要改 Level 2 的 `Backend` 讓 `bRun` 帶失敗通道(如 `IO (Either Text ([Fact], [ExtractWarning]))`),`Backend` 記錄、`runOne`、兩個後端的 `bRun` 各動一處
- A8: `F003` 的 `ihNotes`(`.knot/` 首建提示)併入 `erWarnings` 後,會被 `Knot.App.Run` 的 `--strict` 判定計為「有跳檔」→ 首次對一個專案跑 `knot extract --strict` 會 exit 1,純粹因為建了索引快取目錄 → 採取:**照 F003 A2 的裁決原樣併入**,不在 extraction 端特殊處理(要不要豁免屬 CLI 組裝層的 exit code 政策,不在本卡範圍) → 影響:若編排者認為這是缺陷,修法在 `Knot.App.Run.finish` 或改讓提示走另一條非警告通道,屬 export-query 的範圍
- A9: `FieldNs` 不帶父型別名,而 hiedb 的前綴是 `f<父型別>:` → 採取:**丟棄父型別**,`QualName` 只留裸欄位名。理由:契約的 `NameSpace` 是無參數建構子,帶上父型別屬 Level 2 變更 → 影響:同一 module 內用 `DuplicateRecordFields` 宣告兩個同名欄位時,兩者會鑄出同一個 `QualName`(進而同一個節點 id)。本專案與兩個驗收標的都沒用該擴充,風險目前為零;若要修,`NameSpace` 的 `FieldNs` 需帶 `Text` 參數(Level 2 契約變更 + graph-core 鑄造規則變更)

## 實作備註

實作於 2026-08-22 完成。編排者已對 A1–A9 全部裁決:A2 維持四值 `NameSpace`(`z:` 跳過 +
依前綴彙整警告)、A1 接受 namespace 粗推(design.md 的 `DeclKind` 已補限制註記)、
A3–A9 全部接受。全部照裁決實作,無契約偏離。

### 設計偏差 1(重要):`decls.is_root = 1` 不是 fromDecl 的候選集

設計文檔「實作方式 › 1」的查證表把 `decls.is_root` 判讀為「頂層宣告(含 instance 繫結)
→ 正是 fromDecl 的候選集」,`qRefs` 的 SQL 據此帶了 `AND d.is_root = 1`。**這個判讀是錯的**,
實作階段以真實索引推翻:

上游 `HieDb/Utils.hs` 的 `isRoot` 原文只對 `ValBind InstanceBind _ _` 與 `Decl _ _` 回 `True`,
**一般的頂層值繫結(`ValBind RegularBind ModuleScope`)拿到的是 `is_root = 0`**。
2026-08-22 對 fixture 索引實測 `decls` 全表:

| occ | span | is_root |
|---|---|---|
| `v:run`(Demo.App 的頂層函式) | (8,1)–(8,30) | **0** |
| `v:greet`(Demo.Core 的頂層函式) | (19,1)–(21,21) | **0** |
| `fConfig:cfgName` | (15,5)–(15,12) | **0** |
| `t:Color` / `c:Red` / `c:Green` / `c:Blue` / `t:Config` / `c:Config` | — | 1 |

帶著 `is_root = 1` 過濾,「這個引用寫在哪個**函式**裡」會**永遠**解析不到
(`frFromDecl` 恆為 `Nothing`,只有落在 data/class 宣告內的引用解得出來)——那正是
fromDecl 最主要的用途。**實作改為不過濾 `is_root`**,候選集取該 `hieFile` 的全部 `decls` 列。
安全性由上游保證:`goDec` 要求 `nameModule_maybe name == Just smdl`,局部 `where` / `let`
繫結是 internal name(無 Module),本來就不入 `decls`,故不過濾也混不進非頂層的候選。

這是 Level 3 內部 SQL 的修正,**不動任何 Level 2 契約**(design.md 的抽取規則 4 只說
「以 span 包含關係 join 得出、取最內層」,未提 `is_root`)。`test_hiedb_facts_acceptance`
的 (a) 逐條釘住修正後的行為。

### 設計偏差 2:T3 的「空 SQLite」斷言移到 T7

1-to-1 對照表的 T3 原本要「對一個空的暫存 SQLite 呼叫 `readIndexFacts`」且**不需 hiedb**。
實際做不到:`IndexHandle` 的建構子依 F003 的設計刻意不匯出,**唯一取得途徑是 `ensureIndex`**,
而它需要 hiedb 執行檔。故:

- `test_hiedb_facts_smoke`(T3,不需 hiedb)改為釘住可及的部分:`bName` / `bLevel`、
  註冊表順序 `[import-scan, hiedb]`、`HiedbOnly` 時 import-scan 的「未選中」報告
- 「查詢失敗 → 警告 + 不抛例外」的規則 7 行為改由 `test_hiedb_backend_live`(T8,需 hiedb)
  以「0 byte 假 `.hie` 讓 `ensureIndex` 失敗」的路徑覆蓋,並額外釘住 `HiedbFactsError`
  通道的 `"hiedb index failed: "` 前綴

### 其他小偏差(皆屬 Level 3 內部)

- `Q_MODS` 只取四欄(`hieFile, mod, hs_src, is_boot`),**不取 `is_real`**:它只表示
  「`hs_src` 是否為真實來源檔」,而 `hs_src = NULL` 的情形已由 `resolveModuleSource`
  的第二層退路涵蓋;取而不用會觸發 `-Wunused-top-binds`
- D7 的跳過機制沿用 F003 的同一個開關(設計要求),故 `hiedbGatedCount` 改為
  `length hiedbGatedTests + length hiedbGatedF004Tests`(5 + 4 = 9),`hiedbNotice` 的
  文字改成 `"extraction/F003 hiedb-driver + F004 hiedb-facts: …"`,F003 的
  `test_hiedb_skip_notice` 對帳斷言同步調整。無 hiedb 環境實測:**111 個測試全過、
  9 個跳過**,兩個佔位節點分別顯示 5 與 4
- `test/Main.hs` 的 `test_hiedb_degrade`(F003 T10)內的區域 `hiedbBackend` 改名為
  `stubHiedbBackend`——本 feature 匯入了真的 `hiedbBackend`,不改名會觸發
  `-Wname-shadowing`。行為零變更(仍是替身後端)

### F003 真實簽名複驗(2026-08-22)

設計文檔標「來自 F003 設計文檔而非原始碼」的三列全部打開 `src/Knot/Extract/HiedbDriver.hs`
(285 行)複驗,**簽名零落差**:

| 複驗項 | 真實出處 | 結果 |
|---|---|---|
| `ensureIndex :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)` | HiedbDriver.hs:241 | 相符 |
| `probeHiedb :: ExtractOptions -> ProjectMeta -> IO ProbeResult` | HiedbDriver.hs:135 | 相符 |
| `IndexHandle`(抽象,建構子不匯出) | HiedbDriver.hs:78-84 | 相符 |
| `ihDbPath :: IndexHandle -> FilePath`(絕對) | HiedbDriver.hs:87-88;值來自 `makeAbsolute` | 相符 |
| `ihRootDir :: IndexHandle -> FilePath`(絕對) | HiedbDriver.hs:91-92 | 相符(本 feature 刻意不用) |
| `ihNotes :: IndexHandle -> [ExtractWarning]` | HiedbDriver.hs:106-107 | 相符 |
| `ihExe :: IndexHandle -> FilePath` | HiedbDriver.hs:95-96 | 相符(本 feature 不用) |
| `ihStats :: IndexHandle -> IndexStats` / `IndexStats { indexedCount, skippedCount, batchCount }` `deriving (Eq, Show)` | HiedbDriver.hs:100-115 | 相符(本 feature 不用) |
| `"hiedb index failed: "` 前綴 | HiedbDriver.hs:125 `indexPrefix` | 相符,`HiedbFactsError` 原樣轉載 |

`displayException` 不夾帶 backtrace 的假設(A7)實測成立:`runOne` 的
`displayException (e :: SomeException)` 對 `HiedbFactsError` 回傳原文本身,
`brDetail` 確實含 `"hiedb index failed: "`(`test_hiedb_backend_live` 釘住)。

### hiedb 0.8.0.0 schema 二次複驗

從 `C:\cabal\packages\hackage.haskell.org\hiedb\0.8.0.0` 解出原始碼,對 `HieDb/Create.hs`
的 `setupHieDb` 逐條核對:八張表(`mods` / `exports` / `refs` / `decls` / `imports` /
`defs` / `typenames` / `typerefs`),**確無 instance 表**(C4 的「不產 `FactInstance`」成立);
`mods` 為 `(hieFile, mod, unit, is_boot, hs_src, is_real, hash)`,`hs_src TEXT UNIQUE` 可為 `NULL`;
`refs` 為 `(hieFile, occ, mod, unit, sl, sc, el, ec, is_generated)`;`decls` 為
`(hieFile, occ, sl, sc, el, ec, is_root)`(無 `mod` 欄);`defs` 為
`(hieFile, occ, sl, sc, el, ec)` + `PRIMARY KEY(hieFile, occ)`。
`HieDb/Types.hs` 的 `toNsChar` / `fromNsChar` 前綴五種(`v:` `c:` `t:` `z:` `f<父型別>:`)
與 `FromField OccName` 的 `T.break (== ':')` 判準,均與 `parseOcc` 的實作一致。

實測 fixture 索引的 `mods.hs_src` = `C:\Users\User\AppData\Local\Temp\hfix\src\Demo\Core.hs`
(**絕對 + Windows 反斜線**),A3 的「正規化 + 最長後綴比對」路徑正確。

### T11 自我驗收數據(2026-08-22,knot-hs 自身,唯讀)

先以 `cabal build knot-hs:lib:knot-hs knot-hs:exe:knot --ghc-options="-fwrite-ide-info -hiedir .hie"`
產出自身的 31 個 `.hie`(`.hie/` 已在 `.gitignore`,版控樹不受影響),再以
`dbPath = <暫存路徑>` 走完整 `extract`:

| 指標 | 值 |
|---|---|
| `hieFiles` | 31 |
| `erLevel` | `DeclLevel` |
| `erReports` | `[import-scan(used), hiedb(used)]`,`brDetail` 皆為空 |
| `FactDecl` | 623 |
| `FactRef` | 7265 |
| `frGenerated = True` 的 `FactRef` | 846(11.6%) |
| `erWarnings` | **0**(無「對映不到」、無未知 namespace 前綴) |
| `<repo>/.knot/` | 未被建立(`--db` 改道生效) |

未知 namespace 統計為零,印證 A2 的判斷:`z:` 在 `refs` / `defs` 實務上不出現。
F003 的索引重用亦同步驗到:第一次 `IndexStats 31 0 1`、第二次 `IndexStats 0 31 1`。

同一條路徑經**真實 CLI** 再驗一次(前置 2 的落地證明):

```text
$ knot extract . --db <暫存路徑>/self.sqlite --summary facts
level: DeclLevel
backends: 2
  import-scan used=True
  hiedb used=True
facts: 8173 total, 31 modules, 254 imports
warnings: 0
```

`knot extract --help` 的旗標與順序與 system.md「CLI 介面(頂層契約)」逐行一致;
執行後 `<repo>/.knot/` 未被建立。

**注意(給後續開發者)**:`<repo>/.hie/` 是本次為了跑 T11 而產生的本機產物(gitignored)。
若日後**刪除**某個 library / executable 模組而沒有重產 `.hie`,殘留的 `.hie` 會讓
`test_hiedb_facts_selfcheck` 出現「對映不到」警告而變紅;此時 `rm -rf .hie` 即可
(該測試會自動回到「印明原因並跳過」)。

### 建置與測試

- `cabal build all --enable-tests`:通過。**本 feature 新增的程式碼零警告**
  (`src/Knot/Extract/HiedbFacts.hs`、`Knot.Extract`、`Knot.Extract.Types`、`Knot.App.Cli`)。
  既有負債未動:`test/Main.hs` 的 8 筆 `-Wincomplete-record-selectors`、
  `src/Knot/Extract/HiedbDriver.hs:160` 的 1 筆 `-Wx-partial`(`head`,屬 F003)
- `cabal test --enable-tests`(hiedb 在 PATH):**All 118 tests passed**
- 無 hiedb 環境(把 `C:\cabal\bin` 從 PATH 移除後直接跑測試執行檔):
  **All 111 tests passed**,並印出
  `[skip] extraction/F003 hiedb-driver + F004 hiedb-facts: hiedb executable not found on PATH; 9 tests skipped`
- 版本號 `0.0.1.0` 未更動;library 全程不印任何輸出(所有提示走 `ExtractWarning`)

**非契約面公開匯出登記(G-E001 日後一併收斂)**:`Knot.Extract.HiedbFacts` 的 `parseOcc`、
`declKindOf`、`resolveModuleSource`、`pickFromDecl` 四個純函數僅為 1-to-1 測試而匯出,
不屬 Level 2 契約面;`hiedbBackend` 與 `readIndexFacts` 是契約面。沿用
`Knot.Meta.SourceIndex.moduleNameFromPath`、`Knot.Extract.Backend.runBackends`、
`Knot.Extract.HiedbDriver` 的 `defaultDbPath` / `parseIndexStats` / `chunkFileArgs` 的既有慣例
(haddock 註明),一併登記在 `G-E001`。
