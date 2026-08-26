---
id: G-E008
type: enhance
title: graph-freshness-and-test-scope
description: 查詢端比對圖的新鮮度,並讓抽取預設納入測試層
status: done
created: 2026-08-26
updated: 2026-08-27
depends-on: []
related-adr: [ADR-003, ADR-004, ADR-006, ADR-008]
related-feature: [export-query/F001, export-query/F002, export-query/F004, project-meta/F002, G-E007]
subsystems: [export-query, project-meta]
---

# G-E008: 圖的新鮮度提示與抽取期測試範圍

## 現況分析

兩個獨立的缺口,共同後果是「使用者(尤其是 agent)不信任圖,改回去直接讀檔」。

### 缺口一:`built_at_commit` 只寫不讀

匯出端有完整的 commit 偵測:`Knot.Export.Commit.detectCommit`(`src/Knot/Export/Commit.hs:37`)在
`rootDir` 跑唯讀的 `git rev-parse HEAD`,失敗一律回 `Nothing` 且不印;`writeCodegraph`
(`src/Knot/Export.hs:42`)把它填進頂層 `built_at_commit`。本 repo 的 `codegraph.json` 實測確實有這個欄位。

查詢端**完全沒有讀它**:

- `parseQueryGraph`(`src/Knot/Query/Load.hs:165`)只解析 `nodes` / `links` 兩個頂層鍵;
  `built_at_commit` 落在「其餘欄位一律忽略」那條(ADR-003:多餘欄位可安全擴充)
- `QueryGraph`(`src/Knot/Query/Types.hs:81`)九個欄位裡沒有任何一個承載它
- `Knot.App.Run.runQueryCmd`(`app/Knot/App/Run.hs:198`)載入成功後印四條提示
  (未知 relation、端點不存在、端點不在 scope、圖上無測試節點),沒有一條與新鮮度有關

所以圖是不是還對應當前工作區,使用者**沒有任何便宜的判斷方式**。理性的反應就是不信任它。
`_shared/codegraph.md` 甚至已經把「比對 `built_at_commit` 與 `git rev-parse HEAD`」寫成使用紀律,
卻要求使用者自己手動去比——knot 手上有兩邊的資料,卻不做這件事。

而 exe 拿不到現成的偵測:`Knot.Export.Commit` 屬 `knot-internal`(ADR-004 的私有 sublibrary),
`executable knot` 只依賴公開 library,`import` 它是 `GHC-87110 hidden package` 編譯錯誤。

### 缺口二:測試範圍只能在抽取期決定,切換代價昂貴

範圍旋鈕有兩個,分屬兩個階段:

- **抽取期**:`--include-tests` → `MetaOptions.includeTests`(`src/Knot/Meta/Types.hs:22`,預設 `False`)
  → `compExcluded` / `sfIncluded`(`src/Knot/Meta/SourceIndex.hs:60`)→ extraction 據此帶
  `--enable-tests` / `--disable-tests`(`src/Knot/Extract/BuildDriver.hs:100-101`)
- **查詢期**:`--scope product|tests|all`(G-E007),預設 `product`

結果是查詢期發現缺料只能退回抽取期重跑,而重跑的代價不是「多跑一次」:
`BuildDriver.hs:89` 已註明**帶與不帶是兩個組態,切換會讓 cabal 重新設定**。

2026-08-26 於本 repo 實測(warm cache):

| 動作 | 實測耗時 |
|---|---|
| 同一組旗標重跑、原始碼沒動 | **1.4 s** |
| 切換到 `--include-tests`(反向重設定) | **17.4 s** |
| 切換掉 `--include-tests`(反向重設定 + 全量重建) | **91.8 s** |

`app/Knot/App/Run.hs:282` 的提示 `rerun knot extract --include-tests` 因此是在叫使用者付
17–92 秒,而且它**只在 `tests-of` 回空集合時才出現**——用 `--scope tests` 查別的東西時連提示都沒有。

## Scope(涵蓋範圍)

與開發者於 2026-08-26 定案(四題 + 一題追問):

**動**

| 子系統 | 動到什麼 |
|---|---|
| export-query(查詢面) | `QueryGraph` 多一個欄位、多一條契約 `queryGraphCommit`、`parseQueryGraph` 多讀一個頂層鍵 |
| export-query(匯出面) | `detectCommit` 由內部模組**提升為對外契約**;新增 `detectDirtySources` |
| export-query(cli-assembly) | 新增第 6 條 stderr 通道 `freshnessNoteLines`;`runQueryCmd` 接上;`noTestsLines` 文案更新;`extract` 的測試旗標改為預設納入 + `--exclude-tests` |
| project-meta | **僅文件**:`MetaOptions.includeTests` 的「預設 False」註記改寫為「CLI 預設納入」。library 語意零變動 |

**明確不動**

- `codegraph.json` 的**格式**(ADR-003):本次只**讀** `built_at_commit`,不新增欄位、不改欄位、不改投影規則
- 任何 exit code 語意:不新增 `knot query --strict`、不新增 `--require-fresh`(開發者裁定:不新鮮是提示不是錯誤)
- extraction 子系統:它只消費 `compExcluded` 的判定結果,行為與文件皆不變
- `MetaOptions.includeTests` 的 **library 預設**——這個欄位沒有預設值,呼叫者一律明確給值;
  翻轉只發生在 CLI 旗標層(這是五份黃金檔 byte 不變的前提)
- graph-core、query-engine、query-render:一行不動

**被排除的「順便改」**

- 「commit 相同但圖是在髒工作區裡建的」——要靠 `codegraph.json` 記錄抽取當下的髒污狀態才判得準,
  那要動 ADR-003 的唯一契約且下游 `scan-graph.mjs` 不認得。否決,不另開文檔
- 「圖只有 contains/depends 邊,答不了『有沒有人對這個型別做窮舉 case』」——那是 IR 顆粒度問題
  (節點是具名實體、邊是引用關係,運算式內部形狀沒有位置可放),要做等於開第二種輸出格式。
  本次不碰,值得另開文檔討論

## 改善目標

1. **過期必報**:圖的 commit 與當前 HEAD 不同時,`knot query` 的任一子命令都印出恰一行 stderr 提示(law L2)
2. **同 commit 上的改動也報**:commit 相同但有未提交的 `.hs` 改動時,印出恰一行不同文案的提示(law L3)
3. **零誤報**:圖新鮮、或無從判斷(圖沒記 commit / 目標不是 git repo / git 不在 PATH)時,**零行**(law L4)
4. **切換代價歸零**:一個開發階段內不再需要切換測試旗標,實測 17–92 s 的 reconfigure 從流程中消失;
   同組態重跑的 1.4 s 不變
5. **零回歸**:五份黃金檔 byte 不變、`knot query` 的 exit code 語意零變動、`--scope product` 的查詢輸出
   與翻轉前逐字相同、`cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0

## 數據與介面變動

| 項目 | 動作 | 簽名 / 定義 | 語意(做什麼) | 受影響呼叫端 | 骨架位置 |
|---|---|---|---|---|---|
| `QueryGraph.qgCommit` | 新增欄位 | `qgCommit :: Maybe Text` | 承載圖檔頂層 `built_at_commit` 的原文;缺鍵與型別不對皆為 `Nothing` | `parseQueryGraph`(建構處);`restrictNodes` 以 record update 原樣帶過 | `src/Knot/Query/Types.hs:92` |
| `queryGraphCommit` | 新增(Level 2 契約 · 查詢面) | `queryGraphCommit :: QueryGraph -> Maybe Text` | 回報圖自己記了哪個 commit;**不判斷新不新鮮** | `Knot.Query`(re-export)、`Knot.App.Run` | `src/Knot/Query/Load.hs:141` |
| `parseQueryGraph` | 修改(行為,簽名不變) | `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | 多解析一個頂層選填字串鍵填進 `qgCommit`;**缺鍵與型別不對都合法**,兩者皆為 `Nothing`,不改變任何檔案的載入成敗 | 無(簽名不變) | `src/Knot/Query/Load.hs:165`(建構處 `:214`) |
| `detectCommit` | 修改(可見性,簽名不變) | `detectCommit :: CommitPolicy -> FilePath -> IO (Maybe Text)` | 行為一字不變;由 export-writer 內部細節**提升為 `Knot.Export` 對外契約** | `Knot.Export`(新匯出)、`Knot.App.Run` | `src/Knot/Export.hs:14`(定義 `src/Knot/Export/Commit.hs:37`) |
| `detectDirtySources` | 新增(Level 2 契約 · 匯出面) | `detectDirtySources :: FilePath -> IO Bool` | 該目錄的 git 工作區有沒有未提交的 Haskell 原始碼改動;任何失敗回 `False` 且不印 | `Knot.Export`、`Knot.App.Run` | `src/Knot/Export/Commit.hs:59`(匯出 `src/Knot/Export.hs:15`) |
| `freshnessNoteLines` | 新增(cli-assembly) | `freshnessNoteLines :: Maybe Text -> Maybe Text -> Bool -> [Text]` | 圖的 commit、當前 HEAD、是否有未提交 `.hs` 改動 → 0 或 1 行 stderr 提示 | `Knot.App.Run.runQueryCmd` | `app/Knot/App/Report.hs:133` |
| `runQueryCmd` | 修改(行為,簽名不變) | `runQueryCmd :: Handle -> Handle -> QueryCmd -> IO ExitCode` | 載入成功後先偵測並印新鮮度提示,再印既有四條;**回傳值不因此改變** | 無(簽名不變) | `app/Knot/App/Run.hs:198` |
| `noTestsLines` 文案 | 修改(行為,簽名不變) | `noTestsLines :: QueryGraph -> QueryCommand -> [Text]` | 提示改為指向 `--exclude-tests`,不再叫使用者加已成預設的旗標 | 無(簽名不變) | `app/Knot/App/Run.hs:279`(現行文案 `:282`) |
| `extract` 的測試旗標 | 修改(CLI 契約) | `--include-tests` / `--exclude-tests`(互斥) | 預設**納入** test-suite 與 benchmark;`--exclude-tests` 排除;兩者同時給是錯誤 | `toMetaOptions`(不變)、system.md 頂層契約 | `app/Knot/App/Cli.hs:179` |
| `ExtractCmd.ecIncludeTests` | 修改(語意,型別不變) | `ecIncludeTests :: Bool` | 從「使用者有沒有給 `--include-tests`」改為「**最終判定**,預設 `True`」 | `toMetaOptions`(`app/Knot/App/Cli.hs:303`) | `app/Knot/App/Cli.hs:104` |

**骨架佔位的兩處說明(給 impl)**

- `queryGraphCommit` 是 `undefined`:新行為的紅燈由它負責
- `qgCommit` 在 `parseQueryGraph` 建構處填 `Nothing` 而非 `undefined`,原因是既有回歸測試會做
  **整張圖的相等性斷言**(`restrictLevel LevelAll g == g`、`restrictScope ScopeAll g == g`),
  填 `undefined` 會讓那些該綠的測試爆掉。副作用是 L1 的**後兩半**(缺鍵 → `Nothing`、型別不對 →
  `Nothing`)在骨架上就會通過——**它們不是實作完成的證據**,實作完成的判準是 L1 的第一半
  (有合法字串時回 `Just s`)

## Laws(行為性質)

**回歸 law(改完必須一模一樣的現有行為)**

- R1: 對任何 `codegraph.json` 位元組輸入,`parseQueryGraph` 的成功/失敗**分類**與 `LoadError` 的**訊息逐字**與改動前相同——新增的頂層鍵解析不得讓任何既有檔案改判
- R2: 對任何 `QueryGraph` 與任何 `QueryCommand`,`runQuery` 的結果與 `renderResult` 的文字與改動前相同
- R3: `restrictLevel LevelAll g == g` 與 `restrictScope ScopeAll g == g` 仍成立;誘導子圖必須把 `qgCommit` 原樣帶過(`restrictScope s g` 的 `qgCommit` == `qgCommit g`)
- R4: `knot query` 的 exit code 語意不變:`LoadError` → 1、其餘(含查無結果、含任何新鮮度提示)→ 0
- R5: `detectCommit` 的行為不變:`NoCommit` → `Nothing`;`AutoDetect` 在非 repo / git 不在 PATH / 輸出非合法 sha 時 → `Nothing`,且**全程不印任何訊息**
- R6: 對同一組 `MetaOptions`,`loadProjectMeta` 的輸出與改動前相同;五份黃金檔(`test/fixtures/golden/{comps,graph,multi,no-cabal,proj}.json`)byte 不變
- R7: `knot extract --include-tests` 的解析結果與行為與改動前完全相同(旗標仍存在、仍表示納入)
- R8: 對同一份原始碼,「納入測試層的圖 + `--scope product`」與「未納入測試層的圖」的四種查詢輸出逐字相同(G-E007 既有性質;翻轉預設後它成為主要路徑)

**新 law(這次優化才成立的性質)**

- L1: 圖檔頂層有 `"built_at_commit": s`(`s` 為字串)時 `queryGraphCommit` 回 `Just s`;**缺鍵**回 `Nothing`;**有鍵但不是字串時視同缺鍵**——`queryGraphCommit` 同樣回 `Nothing`,`parseQueryGraph` **照常成功載入**。
  這一條刻意**不比照 `component` 的壞檔慣例**,兩者的後果不同:`component` 會改變 `--scope` 的判定、錯了會給出錯誤答案,所以必須擋;`built_at_commit` 只餵新鮮度提示,型別不對最壞就是退化成 L4 的靜默,沒有理由讓整份圖不能查。查詢面要讀的是**任何產生器**產的 `codegraph.json`(ADR-003:多餘欄位可安全擴充),對方塞一個同名不同型的欄位不該讓 knot 整份拒收
- L2: 兩個 commit 都有值且不同時,`freshnessNoteLines` 回**恰一行**,內容為
  `query: graph is stale: built at <圖 commit 前 12 碼>, HEAD is <HEAD 前 12 碼>; rerun knot extract`
- L3: 兩個 commit 都有值且**相同**、第三參數為 `True` 時,回**恰一行**,內容為
  `query: graph may be stale: uncommitted Haskell changes since it was built; rerun knot extract`
- L4: 任一 commit 為 `Nothing` 時回 `[]`(不論第三參數);兩者相同且第三參數為 `False` 時回 `[]`
- L5: sha 一律取**前 12 個字元**;長度不足 12 時原樣輸出(`built_at_commit` 是圖檔裡的字串,本層不驗證它是不是合法 sha)
- L6: `detectDirtySources` 對非 git repo、git 不在 PATH、路徑不存在、以及任何 git 失敗,一律回 `False` 且不印任何訊息
- L7: `detectDirtySources` 只看 Haskell 原始碼:未提交的 `.hs` 改動(tracked 檔的修改或刪除、未追蹤的新 `.hs` 檔)回 `True`;非 `.hs` 檔的改動、以及被 `.gitignore` 排除的檔案,一律不算
- L8: `knot extract` 不帶任何測試旗標時 `ecIncludeTests == True`;帶 `--exclude-tests` 時 `False`;帶 `--include-tests` 時 `True`
- L9: `--include-tests` 與 `--exclude-tests` 同時給定時,exit 非 0、訊息指出旗標問題,且**不寫** `codegraph.json`
- L10: `tests-of` 在沒有任何測試節點的圖上執行時,提示為
  `query: graph has no test components; rerun knot extract without --exclude-tests`
- L11: `knot query` 的新鮮度提示在**每個**子命令上都成立(`find` / `reachable` / `path` / `rank` / `tests-of`),不因子命令而異
- L12: `--exclude-tests` 與新鮮度提示的存在,在 `.design/system.md`、`.design/subsystems/export-query/design.md` 與 `README.md` 三份文件中都查得到(比照 E002 / E003 的既有 docs-mention 慣例)

## Examples

| # | 輸入 | 預期輸出 | 覆蓋的邊界 |
|---|---|---|---|
| 1 | `freshnessNoteLines (Just "aaaaaaaaaaaaaaaa") (Just "bbbbbbbbbbbbbbbb") False` | `["query: graph is stale: built at aaaaaaaaaaaa, HEAD is bbbbbbbbbbbb; rerun knot extract"]` | commit 不同、截斷為 12 碼 |
| 2 | `freshnessNoteLines (Just "aaaaaaaaaaaaaaaa") (Just "aaaaaaaaaaaaaaaa") True` | `["query: graph may be stale: uncommitted Haskell changes since it was built; rerun knot extract"]` | 同 commit 但工作區有 `.hs` 改動 |
| 3 | `freshnessNoteLines Nothing (Just "bbbbbbbbbbbbbbbb") True` | `[]` | 圖沒記 commit(graphify 產的圖 / 非 repo 產出),無從判斷就不出聲 |
| 4 | 頂層含 `"built_at_commit": 42` 的圖檔 | **載入成功**(`Right`),`queryGraphCommit` 回 `Nothing`,其餘查詢結果 `= 現況` | 選填 metadata 型別不對:視同缺鍵,不影響載入成敗(R1) |
| 5 | `knot extract proj`(不帶任何測試旗標) | `toMetaOptions` 得 `MetaOptions { root = "proj", includeTests = True }` | 預設翻轉 |
| 6 | `knot extract proj --include-tests --exclude-tests` | exit 非 0、訊息指出旗標問題、`proj/codegraph.json` 不存在 | 兩旗標互斥 |
| 7 | 在 git repo 內對一份 commit 與 HEAD 相符、工作區乾淨的圖跑 `knot query rank` | stderr 無新鮮度行,stdout `= 現況`,exit 0 | 新鮮:零誤報 |

## 遷移約束

- **`codegraph.json` 格式零變動**(ADR-003)。本次只讀 `built_at_commit`,舊圖、非 git repo 產的圖、
  以及 graphify 產的其他語言圖,一律照常可查,只是拿不到新鮮度提示
- **exit code 零變動**。新鮮度提示不得影響任何一條路徑的回傳值
- **git 在哪裡執行**:以 `--graph` 指向的檔案**所在目錄**為工作目錄(`codegraph.json` 依契約寫在專案根)。
  `--graph codegraph.json` 這種無目錄成分的路徑要正規化為 `.`,不得傳空字串給子程序
- **library 層不設預設**:`MetaOptions.includeTests` 仍由呼叫者明確給值,翻轉只發生在 CLI 旗標層。
  這是 R6(黃金檔 byte 不變)的前提,不得為了「一致」而在 library 層加預設
- **既有測試的期待值由 qa 依本 spec 改寫**:CLI 解析層原本斷言「預設排除測試層」的三處
  (`ecIncludeTests` 預設值、`--help` 文字、`toMetaOptions` 對映)與 `tests-of` 的提示文案,
  都會依 L8 / L10 變動。**impl 不得碰任何測試檔**
- **骨架已做過一次機械性對齊**:`test/Main.hs` 唯一一處 `QueryGraph{…}` 字面量已補上
  `qgCommit = Nothing`(只補欄位,不動斷言),讓回歸基線在骨架上維持全綠

## 邊界與知識歸屬

- **擁有的知識**
  - 「怎麼問目標專案的 git 現況」(HEAD 是什麼、工作區髒不髒)唯一住在 `Knot.Export.Commit`。
    本次把它從「export-writer 的內部細節」升為「export-query 匯出面的對外契約」,沒有搬家、沒有複製
  - 「圖檔記了哪個 commit」住在查詢面(`qgCommit` / `queryGraphCommit`);查詢面**只**知道圖說了什麼,
    不知道現在是什麼——它仍然不碰原始碼、不跑子程序
  - 「兩邊不一致要說什麼話」住在 cli-assembly(`freshnessNoteLines`)。比對邏輯是純函數,
    IO 由 `runQueryCmd` 供給
- **依賴方向**
  - **不新增模組間依賴邊**:`Knot.App.Run` 本來就 `import Knot.Export (writeCodegraph)`
    (`app/Knot/App/Run.hs:52`),本次只是從同一個模組多取兩個符號
  - `Knot.Query.Load` 不新增任何 import,仍然零 IO
  - 方向不變:cli-assembly → 四個子系統的對外契約,單向
- **不可逆決定**
  1. **`--include-tests` 預設翻轉**是使用者可見的預設行為變更。否決的替代:保留預設關閉、只把
     reconfigure 代價寫進提示——實測 17–92 s 的往返原封不動地存在,等於沒解。技術上可逆
     (把預設改回去即可),但改回去會讓已經習慣新預設的使用者再被 reconfigure 咬一次
  2. **`detectCommit` / `detectDirtySources` 進入公開 library 契約面**。否決的替代:CLI 層自己跑 git
     ——sha 驗證規則(40 / 64 位 hex)與「失敗即靜默」兩條語意會複製成兩份,正是知識歸屬要避免的形狀。可逆
  3. **不動 `codegraph.json` 格式**。否決的替代:新增 `built_at_dirty` 之類欄位記錄抽取當下的髒污狀態
     ——會動到 ADR-003 的唯一契約,且下游 `scan-graph.mjs` 不認得。不可逆(格式一旦加了欄位,
     舊版 knot 讀新圖的相容性就要開始維護)

## 相依性

`depends-on: []`。四份被回鏈的 feature(`export-query/F001`、`F002`、`F004`、`project-meta/F002`)與
`G-E007` 都是 `status: done`,本文檔改的是它們的既有產物,沒有等待中的前置。可與任何不碰
export-query 與 project-meta 的任務平行進行。

兩半(新鮮度、測試範圍)之間**沒有程式碼耦合**——共用的只有「讓圖值得信任」這個目標與同一份
CLI 組裝層。若其中一半在仲裁時卡住,另一半可以獨立收斂。

### 使用到的既有介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `detectCommit :: CommitPolicy -> FilePath -> IO (Maybe Text)` | `src/Knot/Export/Commit.hs:37` | export-query/F001 | 取當前 HEAD(以 `AutoDetect` 呼叫) |
| `data CommitPolicy = AutoDetect \| NoCommit` | `src/Knot/Export/Types.hs:27` | export-query/F001 | `detectCommit` 的第一參數 |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | `src/Knot/Query/Load.hs:165` | export-query/F002 | 新的頂層鍵在此解析 |
| `optionalString :: FilePath -> String -> KM.KeyMap Value -> String -> Either LoadError (Maybe Text)` | `src/Knot/Query/Load.hs:244` | export-query/F002(G-E007 引入) | **對照組,`built_at_commit` 不走它**:它對「有鍵但不是字串」回 `Left`,而 L1 要的是 `Nothing`(查詢規則 11)。列在此是為了讓 impl 知道有這個現成 helper、以及為什麼不能直接用 |
| `queryGraphHasTests :: QueryGraph -> Bool` | `src/Knot/Query/Load.hs:123` | G-E007 | `noTestsLines` 的判定來源,文案改但判定不變 |
| `restrictNodes :: (QueryNode -> Bool) -> QueryGraph -> QueryGraph` | `src/Knot/Query/Load.hs:346` | export-query/E001、G-E007 | 以 record update 建誘導子圖,新欄位由它自動帶過(R3) |
| `emitNotes :: Handle -> [Text] -> IO ()` | `app/Knot/App/Report.hs:137` | export-query/F004 | 整條管線唯一的列印函式,新通道沿用 |
| `runQueryCmd :: Handle -> Handle -> QueryCmd -> IO ExitCode` | `app/Knot/App/Run.hs:198` | export-query/F004 | 新鮮度提示的接上點 |
| `toMetaOptions :: ExtractCmd -> MetaOptions` | `app/Knot/App/Cli.hs:300` | export-query/F004 | `ecIncludeTests` 的唯一消費者,本次不改 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool }` | `src/Knot/Meta/Types.hs:20` | project-meta/F002 | 只改註記,語意不變 |

## 骨架

| 檔案 | 變動 |
|---|---|
| `src/Knot/Query/Types.hs` | `QueryGraph` 新增 `qgCommit :: Maybe Text` 欄位與 haddock |
| `src/Knot/Query/Load.hs` | 匯出 `queryGraphCommit`;新增其簽名(`undefined`);`parseQueryGraph` 建構處補 `qgCommit = Nothing` 佔位與說明 |
| `src/Knot/Query.hs` | 匯出清單與 import 補 `queryGraphCommit` |
| `src/Knot/Export/Commit.hs` | 模組 haddock 改寫;匯出並新增 `detectDirtySources` 簽名(`undefined`) |
| `src/Knot/Export.hs` | 匯出 `detectCommit` 與 `detectDirtySources`,附提升理由 |
| `app/Knot/App/Report.hs` | 匯出並新增 `freshnessNoteLines` 簽名(`undefined`),haddock 寫死三種判定與逐字文案 |
| `test/Main.hs` | **僅機械性對齊**:唯一一處 `QueryGraph{…}` 字面量補 `qgCommit = Nothing`,不動任何斷言 |

**骨架不動、由 impl 依 law 落實的三處**(簽名皆未變):`app/Knot/App/Run.hs` 的 `runQueryCmd`
與 `noTestsLines`、`app/Knot/App/Cli.hs` 的 `extractParser`。

骨架驗證(2026-08-26):`cabal build all --enable-tests --ghc-options=-Werror` exit 0;
`cabal test all --enable-tests` **181 tests passed**(回歸基線在骨架上全綠)。

## 實作備註

**2026-08-27 `/spec-build` 執行結果:0 輪仲裁,一次收斂。**

- impl 7/7 落地,回報無阻塞、無 spec-gaps、未讀寫任何測試檔、骨架簽名與型別零變動;
  新增的只有模組內未匯出的私有 helper(`looseOptionalString`、`dirtyHsLine` / `statusCounts` /
  `currentPath`、`includeTestsFlag`)
- qa 把 L1–L12 與 7 個 example 譯成 `globalE008Tests`(8 條),並依「遷移約束」改寫了三處
  既有斷言(`extract` 無旗標時的預設、`--help` 旗標清單、`tests-of` 的提示文案)
- 閘門:`cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0;
  `cabal test all --enable-tests` **190 / 190 綠**(基線 181 條無一轉紅 + 新增 9 條)

**編排者的突變驗證(不是 qa 也不是 impl 做的)**:qa 自陳「新 law 的測試本該紅、卻因 impl
併發提前完成而全綠」。編排者不採信自陳,對實作植入六個突變逐一確認測試會紅:

| 突變 | 被殺掉的測試 |
|---|---|
| `queryGraphCommit = const Nothing` | `test_g8_query_graph_commit` |
| 解析端 `qgCommit = Nothing` | `test_g8_qgcommit_field`、`test_g8_query_graph_commit` |
| `restrictNodes` 丟掉 `qgCommit` | `test_g8_restrict_preserves_commit` |
| L2 文案改一個字母 | `test_g8_freshness_note_lines`、`test_g8_run_query_freshness_all_subcommands` |
| `detectDirtySources = pure False` | `test_g8_detect_dirty_sources` |
| 旗標預設改回 `False` | `test_g8_extract_test_flags_default` |

七條實作面測試全部被殺過,**無恆真斷言**。第八條 `test_g8_docs_mention_…` 是文件斷言
(對三份文件 grep `--exclude-tests` 與 `built_at_commit`),程式碼突變殺不了它,改以讀斷言原文確認。
突變全部還原後與備份逐位元相同,並重跑 clean 閘門複驗。

**一處 qa 的自主判斷,編排者複核後同意保留**:`baseExtractCmd` 這個測試 helper 的
`ecIncludeTests` 仍留 `False`。它是手工組 `ExtractCmd` 的便利值、不是「CLI 預設」的斷言,
翻它會靜默改變其他無關測試的執行路徑。L8 的預設由 `test_g8_extract_test_flags_default`
獨立守住。
