---
id: export-query-build
type: build-log
title: export-query-build
description: 委派展開 export-query 全子系統(匯出、查詢、CLI 組裝)
status: done
created: 2026-08-21
updated: 2026-08-21
parent: export-query
---

# export-query 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | json-export | impl-done |
| 階段二:S4 查詢 CLI | W2 | graph-load | impl-done |
| 階段二:S4 查詢 CLI | W3 | query-commands | impl-done |
| 階段二:S4 查詢 CLI | W4 | cli-wiring | impl-done |

開發者決定本次一路跑完整個子系統(階段一 + 階段二)。跨子系統依賴 project-meta、extraction、graph-core 的階段一皆 done 並已 merge 進 main(PR #1、#2,commit 1ea5f27),無等待項。專案尚無 `codegraph.json`,略過 codegraph 對帳。

波次全為單 feature 序列:#1 → #2 → #3 → #4 的依賴鏈無可平行處。cli-wiring 為本次新增的第 4 個 feature(見 D3)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 這次跑到第幾階段 | 一路跑完階段一 + 階段二(整個子系統) | 全部 |
| D2 | CLI 接線範圍 | 完整:引入 optparse-applicative 排 `extract` + `query` 全部旗標 | F004 |
| D3 | 完整 CLI 掛在哪(三張契約卡都寫「不解析 CLI 參數」) | 全部集中到階段二末的新 feature F004 cli-wiring;已補契約卡與功能規劃第 4 列。**代價已告知並確認**:階段一閘門沒有 CLI 入口,MagicFarmer / particle-magic 實跑順延到 F004 | F001、F004 |
| D4 | `codegraph.json` 排版格式 | 半 pretty:`nodes` / `links` 每個物件壓成單行、彼此換行(git diff 友善,MagicFarmer 規模約 300 行) | F001 |
| D5 | scan-graph.mjs 驗收怎麼跑 | 不在 Haskell 測試裡 shell out node(CI 脆弱);由測試直接呼叫 `writeCodegraph` 寫出真檔,編排者在閘門前手動跑一次 `scan-graph.mjs` 對帳 | F001、F004 |
| D6 | 版本號 | 維持 `0.0.1.0` 不動(沿用 graph-core D6 的凍結決定);全部子系統完成後再定版 | 全部 |
| D7 | git 收尾 | 一個 PR 收整個子系統(分支 `feat/export-query-stage1`);過程中仍逐 feature 留 checkpoint commit | 全部 |
| D8 | 沿用的全域決定 | hedgehog + tasty;命名空間 `Knot.*`;兩個驗收標的絕對唯讀;`-Wall` 零警告;library 全程不印任何輸出(列印一律在 executable 層) | 全部 |
| D9 | 工具鏈 spike(2026-08-21 實測,GHC 9.14.1 / base 4.22) | aeson **2.3.1.0** 與 optparse-applicative **0.19.0.0** 皆解析並編譯成功;`Data.Aeson.Encoding` 可顯式控制欄位順序、`hsubparser` 可用。已回寫 design.md「使用的技術」 | F001、F004 |

### 契約類決定(已回寫 design.md,此處僅索引)

| # | 問題 | 決定 | 回寫位置 |
|---|------|------|---------|
| C1 | `AutoDetect` 要在哪個目錄跑 `git rev-parse`(`ExportOptions` 只有 `outputPath`,`--output` 可改道) | `ExportOptions` 增 `rootDir :: FilePath`(比照 extraction A1 給 `ExtractOptions` 加 `rootDir` 的前例) | 對外契約 › 匯出面 |
| C2 | 未知 relation 的「彙整列印」從哪條通道出來(`loadQueryGraph` 無回報欄位,library 不印) | 契約新增 `queryGraphNotes :: QueryGraph -> [(Text, Int)]`,CLI 層取來印 stderr | 對外契約 › 查詢面 |
| C3 | `LoadError` 形狀 | 三建構子各帶說明 `Text`:`LoadFileMissing` / `LoadParseError` / `LoadSchemaError` | 對外契約 › 查詢面 |
| C4 | `Reachable` 是否含起點 | 不含,只回距離 ≥ 1;起點在環上時以真實距離出現 | 查詢規則 5 |
| C5 | `ShortestPath` 多條等長路徑時的決定性 | 取字典序最小路徑(BFS 鄰居依 id 排序、前驅取最早抵達者);`PathResult` 型別不動 | 查詢規則 6 |
| C6 | 既有三個唯讀驗收輸出(預設 meta 摘要、`--facts`、`--graph`)的去留 | 收進 `knot extract --summary meta|facts|graph`;不給 `--summary` 時 `extract` 預設寫 `codegraph.json` | cli-wiring 契約卡 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| json-export | F001 | F001-json-export.md | 繼承 | 繼承 | impl-done |
| graph-load | F002 | F002-graph-load.md | 繼承 | 繼承 | impl-done |
| query-commands | F003 | F003-query-commands.md | 繼承 | 繼承 | impl-done |
| cli-wiring | F004 | F004-cli-wiring.md | 繼承 | 繼承 | impl-done |

四個 feature 全部不降級:F001 的決定性序列化與 F004 的跨四子系統組裝都不是樣板工作;F002 / F003 雖然單一入口,但它們是 F004 的前置,設計錯會沿依賴鏈複利。

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | Level 2 只列單一 `export-writer` 模組,但純函數投影 / IO 偵測 / 寫檔混一檔難測 | 拆 `Knot.Export` / `.Types` / `.Encode` / `.Commit` 四個 Haskell 模組 | **開工前接受**:Level 2 的 export-writer 是邏輯模組不等於單一檔案,比照 graph-core 拆 FactGate/NodeMint/EdgeDerive 的前例,屬實作自主權 |
| F001 A2 | `outputPath` 非 `Maybe`,預設值由誰算未定 | `writeCodegraph` 視為權威值;另出非契約面 `defaultOutputPath :: FilePath -> FilePath` 給 F004 用 | 接受 |
| F001 A3 | `cgWarnings` 若不進 `xrNotes` 就沒有通道被印出 | `xrNotes` 嚴守契約只放 `GraphStats`;警告由 F004 直接從 `CodeGraph` 取來印 | 接受,**但通道現在是斷的**:已列為 F004 委派的硬性驗收項 |
| F001 A4 | `xrNotes` 行文格式未定 | 固定五種英文小寫行,對齊 `Summary.hs` 風格 | 接受 |
| F001 A5 | 投影規則 3 不輸出 `geLine`,但下游 `scan-graph.mjs:265` 以 `e.source_location ?? src.source_location` 取循環依賴證據行;S1 的 module 節點 `gnLine` 恆為 `Nothing`,兩層皆空 | 嚴守契約不輸出,列為建議修訂 Level 2 | **開工前裁決:輸出**。編排者複驗下游程式碼屬實,判定為契約起草漏欄(ADR-003 本就寫明 `source_location` 供循環依賴證據行用,IR 的 `geLine` 也已備好資料)。投影規則 3 與 json-export 契約卡已回寫 |
| F001 A6 | git sha 驗證強度未定 | 去空白後要求字元全落在 `0-9a-f` 且長度 40 或 64 | 接受 |
| F001 A7 | `ExportOptions.rootDir` 與既有 `ExtractOptions.rootDir` 同名 | 實測 GHC2024 內含 `DisambiguateRecordFields`:記錄建構語法可消歧、裸選擇器不行;一律用記錄建構語法,不新增擴充 | 接受(實作已更正該結論:改用 qualified import,見階段結果) |
| F002 A1 | 契約的 `QueryCommand` / `QueryResult` 用到 `NodeId`,但「對外契約 › 查詢面」從未定義它 | 查詢面自定義 `newtype NodeId = NodeId Text` | **開工前裁決:採納**。graph-load 手上只有 JSON 字串,而 graph-core 的 `NodeId` 明訂唯一構造入口是 node-mint;ADR-003 也明寫匯出格式 ≠ 內部模型。已寫進 design.md 查詢面契約 |
| F002 A2 | `links` 頂層鍵缺席的行為未定 | 當空陣列、載入成功(不接受 `edges` 別名) | 階段二閘門:接受 |
| F002 A3 | 節點 id 重複的行為未定 | 回 `LoadSchemaError` | 階段二閘門:接受 |
| F002 A4 | `RankConnectivity` 的度數算邊數還是相異鄰居數 | 鄰接表去重、度數算邊數,兩者分開存 | **開工前接受**:編排者複驗 `scan-graph.mjs:310-316` 為逐邊累加(跳過結構邊、兩端各 +1),與此判斷一致 |
| F002 A5 | `directed: false` 要不要告警 | 忽略該欄位,一律當有向(library 無警告通道) | 階段二閘門:接受 |
| F002 A6 | `design.md` / ADR-003 的結構類是 3 種,`scan-graph.mjs:64` 實際是 6 種 | 依 design.md 實作 3 種,多的落入 `RelUnknown` | **開工前裁決:補齊到 6 種**。編排者複驗屬實;`knot query` 讀的是任何 codegraph.json(含 graphify 產的其他語言圖),分類必須與唯一下游對齊。design.md 查詢規則 1 與 ADR-003 皆已補 |
| F003 A1 | 起點/終點 id 不存在,契約無錯誤建構子 | 回空結果(`ReachableSet []` / `PathResult Nothing`);建議 F004 自行以索引判存在性給明確訊息 | 階段二閘門:接受 |
| F003 A2 | `ShortestPath a a` 語意未定 | 回 `Just [a]`(0 hop),不找環(與規則 5 刻意不同) | 階段二閘門:接受 |
| F003 A3 | `rank` 是否納入總度數 0 的節點 | 排除,對齊 `scan-graph.mjs` 的 degree map | 階段二閘門:接受 |
| F003 A4 | `RankConnectivity n` 的 `n <= 0` | `take` 自然語意 → 空清單 | 階段二閘門:接受 |
| F003 A5 | `renderResult` 格式與語言未定 | 英文小寫 `key: value` + 兩空格明細行(對齊 `Summary.hs` / `xrNotes`);不連通 = `path: not connected` | 階段二閘門:接受 |
| F003 A6 | `FindNodes ""` 的行為 | 回全部節點(`isInfixOf` 空字串恆真) | 階段二閘門:接受 |
| F003 A7 | 契約卡只寫「查詢規則 3、4」,但規則 5、6 明屬本 feature | 一併實作 3/4/5/6,以 `design.md` 為準 | **開工前裁決:契約卡已補正為「3、4、5、6」**。規則 5、6 是編排者在 W2 期間新增(C4/C5),卡片未同步是編排者的疏漏,非 subagent 誤判 |
| F004 A1 | `--summary` 下要不要照樣印 stderr 警告通道 | 照樣印(`renderGraphSummary` 看不到 pm/er 警告) | 階段二閘門:接受 |
| F004 A2 | `--strict` 的「跳檔」判定沒有對應欄位 | 三條警告清單任一非空即算;`brUsed == False` 的**降級不算**(否則沒裝 hiedb 永遠 exit 1,牴觸 ADR-002) | 階段二閘門:接受 |
| F004 A3 | `knot query` 讀哪份 json,契約未定 | 新增 `--graph FILE`,預設 `./codegraph.json` | **階段二閘門:接受**,並已補進 system.md CLI 契約 |
| F004 A4 | 起點 id 不存在的 exit code | exit 0 + stderr `node not found`(落實 F003 A1 建議) | 階段二閘門:接受 |
| F004 A5 | 串流分配 | stdout 只放結果/摘要/`wrote` 行,其餘全 stderr | 階段二閘門:接受 |
| F004 A6 | `CommitPolicy` 無對應旗標 | 固定 `AutoDetect` | 階段二閘門:接受 |
| F004 A7 | `--backend hiedb` 在階段一回空事實流 | CLI 不攔截,由降級行說明 | 階段二閘門:接受 |
| F004 A8 | `hiedbExe`/`dbPath` 無旗標,但 system.md「使用者與體量」寫「`--db` 可改道」 | 依契約卡六旗標,兩欄位填 `Nothing`,**不新增旗標** | **階段二閘門:接受**。開發者裁定走 /system-design 更新模式,CLI 契約已補上 --db 與 --hiedb(--db 是唯讀約束的載重旗標) |
| F004 A9 | `--top` 負數 | 不在解析層擋,交給 F003 的 `take` | 階段二閘門:接受 |
| F004 A10 | `--summary` 不在 system.md 的 CLI 契約內 | 依契約卡實作,建議補 system.md | **階段二閘門:接受**,--summary 已補進 system.md CLI 契約 |
| F004 A11 | 舊 `--facts` / `--graph` 去留 | 移除,由 `--summary` 承接(C6 原文) | 階段二閘門:接受 |

## 階段結果

### 階段一:S1 骨架

- **F001 json-export**(設計繼承 / 實作繼承):Todo 6/6、測試 **69/69**(既有 63 全綠)、`-Wall` 零警告、版本號維持 `0.0.1.0`
- 落地位置:`src/Knot/Export.hs` + `Knot/Export/{Types,Encode,Commit}.hs`(A1 拆分);`knot-hs.cabal` library 新增 `aeson ^>=2.3`、`process`
- **契約補完(開工前裁決)**:A5 投影規則 3 增邊的 `source_location`,實作一字不差落地並補了兩分支測試
- **D5 手動對帳通過**:`test/fixtures/graph` 走完整管線產出的真檔餵 `scan-graph.mjs`,3 節點 / 3 邊全部解析成功,`imports` relation 認得、`directed` 與 `built_at_commit` 都正確消費(還做了新鮮度比對)。編排者另行驗證輸出為 **0 CR / 14 LF**,Windows 上未被轉成 CRLF(投影規則 5 的必要條件)
- **A7 的設計階段結論被實作推翻**:設計說「GHC2024 內含 `DisambiguateRecordFields`,記錄建構語法可消歧」,實作發現它**不涵蓋記錄更新**(GHC-99339)與裸選擇器(GHC-87543)。已改用 qualified import 解決(`test/Main.hs` 8 處)。教訓:spike 要覆蓋實際用法,不能只驗最簡案例
- **arch-audit subsys 發現**(依嚴重度):
  1. (中)A3 的警告通道在 F004 完成前是斷的——`writeCodegraph` 完全不碰 `cgWarnings`,若 F004 漏接,graph-core 的碰撞警告永遠不會被使用者看到。已列為 F004 委派的硬性驗收項
  2. (中)非契約面公開匯出 4 個:`Knot.Export.Encode` 的 `encodeCodegraph` / `relationText` / `statsNotes`、`Knot.Export.Types` 的 `defaultOutputPath`。其中 `relationText` **目前只有測試在用**,屬 G-E001 的同型需求
  3. (低)`design.md` 匯出管線敘述順序與實作相反且不可行:文檔寫「投影 → commit 偵測 → 寫檔」,但 `built_at_commit` 是投影的輸出欄位,commit 必須先偵測。實作為 commit → 投影 → 寫檔
  4. (低)`writeCodegraph` 會自動建立輸出路徑的父目錄,契約未登記;預設路徑不會觸發,`--output` 指向不存在目錄時會在目標專案內建目錄
  5. (低)`statsNotes` 放在 `Encode` 模組,但它產生的是報告文字不是 JSON 投影,輕微職責混雜(屬實作自主權,不強制改)
  6. (低/觀察)`Encode` 直接 import `Knot.Meta.Types (ModuleName)`,成因是 graph-core 的 `GraphStats.gsTopExternalTargets` 在公開 DTO 透出上游型別。消費契約而非繞道,不算外洩
  7. (資訊)`cabal test` 不加 `--enable-tests` 解不出 plan(`cabal.project` 只有 `packages: .`)。既有狀況,非本次造成
  8. (資訊)各 `design.md` 的 frontmatter 都沒填 `code-paths`,將來拿 knot 掃自己時 `scan-graph.mjs` 會 0% 對映
- **契約卡對帳**:負責模組、Level 2 介面、資料流段落與實作相符;`writeCodegraph` 簽名一字不差;三個 DTO 欄位與契約一致(含本次新增的 `rootDir`)
- **本階段未驗到的事**(D3 的已知代價):沒有 CLI 入口,MagicFarmer / particle-magic 的唯讀實跑順延至 F004

### 階段二:S4 查詢 CLI

- **F002 graph-load**:Todo 5/5、測試 74/74;`Knot.Query{,.Types,.Load}`,**library 端零 `Knot.Graph.*` / `Knot.Meta.*` 相依**(編排者複驗,唯一命中是註解)
- **F003 query-commands**:Todo 7/7、測試 84/84;`Knot.Query.{Engine,Render}`,四演算法全私有
- **F004 cli-wiring**:Todo 9/9、測試 **92/92**;`app/Knot/App/{Cli,Report,Run}.hs` + `Main.hs` 收成單行分派。**中途因 API 錯誤中斷一次**,工作樹無殘留,以 SendMessage 帶 context 續跑完成
- **六條警告通道全部接上**(階段一發現 1 已解):`pmWarnings`、`erLevel`/`erReports`/`erWarnings`、`cgWarnings`、`xrNotes`、`queryGraphNotes`;`emitNotes` 是整條管線唯一的列印函式,library 仍全程不印
- **T9 唯讀實跑**(D3 順延的項目,本階段補上):

  | 標的 | exit | 節點 | 邊 | 警告 | scan-graph.mjs |
  |---|---|---|---|---|---|
  | MagicFarmer | 0 | 60 | 247 | 0 | 解析成功 |
  | particle-magic | 0 | 46 | 127 | 1(Main 由 5 個來源檔宣告) | 解析成功 |

  **唯讀性經編排者獨立複驗**:兩標的皆無 `codegraph.json`,particle-magic 工作樹全乾淨;MagicFarmer 的異動全是其領域檔(`History.hs` 等),而 knot 全庫只有 `writeCodegraph` 一條寫入路徑、無寫 `.hs`/`.cabal` 的能力,屬本 session 外的並行編輯
- **knot 首次掃自己**(端到端跑通):29 節點 / 79 邊;`query path Knot.Export Knot.Meta.Types` 回 `Knot.Export → Knot.Export.Encode → Knot.Meta.Types`——**工具自己印證了階段一的 arch-audit 發現 6**
- **T4 的反向驗證**:F003 實作把演算法臨時改成錯誤變體(整層佇列依 id 重排),確認 `test_query_path` 真的會失敗(`Beta/Whisky` vs 正解 `Alpha/Xray`),再還原重跑。查詢規則 6 的唯一防線經證實有效
- **arch-audit subsys 發現**(依嚴重度):
  1. (中)**`missingNodeLines` 繞過 Level 2 契約**:CLI 需要「節點是否存在」的能力,但契約只有 `runQuery`(回空結果,分不出「不存在」與「存在但無鄰居」),於是直接讀 `Knot.Query.Types` 的 `qgNodes` / `qnId`。與 A5 / C2 / F002 A1 同型——契約沒給通道,實作只好繞道。建議補 `queryGraphHasNode :: QueryGraph -> NodeId -> Bool`
  2. (中)**`--graph FILE` 是實作新增的旗標**(F004 A3),不在契約卡也不在 system.md。功能上必要(否則 `knot query` 只能讀 cwd 的檔),但兩層契約都沒登記
  3. (低)**`code-paths` 第一次變成可解**:knot 現在能產出自己的圖,但四份 `design.md` 都沒填 `code-paths`,對映 0%,arch-audit 的圖分析仍吃不出結論
  4. (低)`extract: level` 行由「無條件輸出」改為「只在通道有話說時輸出」(subagent 自報並記入實作備註),判斷合理但設計文檔的行格式表與實作有落差
  5. (低)8 筆 `-Wincomplete-record-selectors` 既有負債仍在(階段一發現 7)
  6. (資訊)`app/Main.hs` 因與 `test/Main.hs` 模組名衝突而不進 test-suite,所以可測邏輯全部下沉到 `Cli`/`Report`/`Run`。這是好設計,值得記為專案慣例
- **契約卡對帳**:三張卡的負責模組、Level 2 介面、資料流段落與實作相符;`loadQueryGraph` / `queryGraphNotes` / `runQuery` / `renderResult` 四個簽名一字不差

#### 閘門裁決落地(三項)

1. **補 `code-paths`(發現 3)**:四份 `design.md` 的 frontmatter 都補上。比對是精確前綴(`scan-graph.mjs:194` 的 `f === prefix || f.startsWith(prefix + "/")`),所以 `src/Knot/Meta` 與 `src/Knot/Meta.hs` 兩個都要列。**對映從 0% 升到 100%(29/29)**,knot-hs 從此可以 dogfood 自己。圖檔隨用隨產、不進版控。

   首次跑出的子系統依賴矩陣**與 system.md 宣告的單向拓撲完全吻合,無循環依賴**:

   ```
   export-query → graph-core   7 條      graph-core → extraction    5 條
   export-query → project-meta 6 條      graph-core → project-meta  5 條
   export-query → extraction   5 條      extraction → project-meta  4 條
   ```

   **但 18 條跨界引用要分開讀**:15 條來自 `app/`(cli-assembly,依 D3 掛在 export-query 下,呼叫四個子系統正是它的職責);library 只有 3 條,其中 `Knot.Export` / `Knot.Export.Encode` → `Knot.Graph.Types` 兩條合法(`CodeGraph` 是契約輸入),**只有 `src/Knot/Export/Encode.hs:L38 → Knot.Meta.Types` 是真旁路**——階段一發現 6 至此被工具以精確證據行釘死,成因是 `GraphStats.gsTopExternalTargets :: [(ModuleName, Int)]` 讓 graph-core 的公開 DTO 透出 project-meta 的型別。

   **副作用值得記下**:把 cli-assembly 放進 export-query 的 `code-paths`,會讓依賴矩陣把組裝層的合法呼叫算成 export-query 的跨界引用。日後若覺得矩陣失真,可考慮讓 `app/` 獨立成假想子系統(那是 Level 1 的問題)。

2. **補契約 `queryGraphHasNode`(發現 1)**:已寫進 `design.md` 查詢面,並委派一輪小實作把 `missingNodeLines` 改走契約函式。

3. **`system.md` CLI 契約四處落差(發現 2 + A8/A10)**:開發者裁定現在走 `/system-design` 更新模式補齊。

## 收尾

全部四個 feature 完成,子系統進度 4/4(100%),測試 93/93,分支 `feat/export-query-stage1`。

**契約在委派過程中被修訂 8 次**,全部源自 subagent 的實質發現、且全部在寫程式碼之前裁決:

| # | 發現 | 落點 |
|---|---|---|
| C1 | `AutoDetect` 無從得知在哪跑 git | `ExportOptions` 增 `rootDir` |
| C2 | 未知 relation 沒有列印通道 | 新增 `queryGraphNotes` |
| C3 | `LoadError` 形狀未定 | 三建構子 |
| C4/C5 | `Reachable` 起點、`ShortestPath` 多解未定義 | 查詢規則 5、6 |
| A5 | 邊不輸出證據行,下游循環依賴報告會全空 | 投影規則 3 增 `source_location` |
| F002 A1 | 契約引用了未定義的 `NodeId` | 查詢面補 `newtype NodeId` |
| F002 A6 | 結構類名單只有 3 種,下游是 6 種 | `design.md` + ADR-003 補齊 |
| 閘門發現 1 | 契約無「節點存在性」能力,CLI 只好繞過抽象 | 新增 `queryGraphHasNode` |

其中 C1、C2、A5、F002 A1、閘門發現 1 是**同一個模式**:契約少了一條通道,實作者要嘛繞道、要嘛腦補。這是委派模式最容易出事的地方,也是「契約卡門檻」與「待確認假設」機制真正發揮作用的地方。

**Level 1 也更新了**(開發者裁定走 `/system-design` 更新模式):CLI 頂層契約補上 `--summary`、`--graph`、query 的四個子命令細節,以及漏列的 `--hiedb` / `--db`。`--db` 是唯讀約束的載重旗標——S3 函式級抽取預設會在目標專案建 `.knot/`,沒有改道旗標,驗收標的的「零寫入」就做不到。另修正兩處過期陳述(子系統 design.md「均未建立」、結構類 relation 只列兩種)。

**留給後續的三件事**:

1. **library 唯一的旁路**:`src/Knot/Export/Encode.hs:L38 → Knot.Meta.Types`,違反 system.md「無旁路」。成因是 graph-core 的 `GraphStats.gsTopExternalTargets :: [(ModuleName, Int)]` 在公開 DTO 透出上游型別。修法是 graph-core 改用 `Text` 或 re-export。**尚未開文檔**,待開發者決定走 `/enhance-design` 或併入 G-E001
2. **G-E001 已登記三批非契約面匯出**(project-meta / extraction / export-query),export-query 這批性質更複雜(純測試用、跨內部模組必要匯出、executable 專用三種),使 internal library 成為唯一能一次解決三者的方案
3. **`-Wall` 零警告從未成立**:`test/Main.hs` 有 8 筆 `-Wincomplete-record-selectors`(extraction 的 `Fact` 部分選擇器),只在全量重編時浮現,前兩個子系統的閘門都是從增量建置得出「零警告」的錯誤結論
