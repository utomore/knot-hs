---
id: E001
type: enhance
title: query-depth-and-level
description: knot query 加 --depth N 與 --level module|decl,reachable 不再只有遞移閉包
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-003]
related-feature: [F002, F003, F004]
---

# E001: `knot query` 的 `--depth N` 與 `--level module|decl`

## 現況分析

2026-08-23 的「knot 查詢效益實測」(六題導航問題,knot vs grep)量到兩個 CLI 缺口,
都在 `knot query` 這一面:

### (1) `reachable` 只有遞移閉包,而且不分層

`src/Knot/Query/Engine.hs:89-105` 的 `reachableFrom` 是逐層 BFS 到底:

```haskell
reachableFrom :: QueryGraph -> NodeId -> Direction -> [(NodeId, Int)]
  …
  dist = go Map.empty 1 (neighbours start)
  go acc _ [] = acc
  go acc d frontier = … go acc' (d + 1) (concatMap neighbours fresh)
```

沒有停止深度。而 `qgForward` / `qgReverse`(`src/Knot/Query/Load.hs:256-268` 的
`absorb`)收的是**全部依賴類邊**——`imports`(module → module)、`calls` / `uses`
(decl → decl,以及 `frFromDecl = Nothing` 時 module → decl)、`implements`。從一個
module 節點出發,第一跳就會沿 `calls` 走進函數節點,之後全是 decl 層:

| 實測(knot-hs 自掃,555 節點) | 輸出 |
|---|---|
| `reachable Knot.Extract.Pipeline` | **65 個節點**、2,505 字元(≈626 tokens) |
| 同一題用 `grep "^  1 "` 事後過濾 + 去掉 decl id | 3 個上游 module、105 字元(≈26 tokens) |
| 31 個 module 各叫一次 `reachable` 組 import 圖 | 35,518 字元、20.8 s |

使用者要的多半是「**直接**依賴誰」(hop-1)或「**module 層**的遞移依賴」,兩者 CLI
都給不了,只能事後用 shell 過濾——而且過濾 decl id 靠的是「id 裡有沒有小寫段 /
`#t`」這種對 id 格式的猜測。

### (2) 四個查詢都沒有「層」的概念

`src/Knot/Query/Types.hs:79-84` 的 `QueryCommand` 與 `:56-64` 的 `QueryGraph` 都不知道
節點是 module 還是 decl;`rank`(`Engine.hs:170-182`)算的是 decl 層連通度
(`Knot.Graph.EdgeDerive.deriveEdges in=3 out=63` 排第一),不是架構 hub。想問
「哪個 module 是 hub」得直接掃 `codegraph.json` 的 `imports` 邊——那正是
dev-flow `scan-graph.mjs` 的讀法,但 `knot query` 自己做不到。

### 節點的層從哪裡來

`codegraph.json` 的節點只有 `id` / `label` / `source_file` / `source_location`
(`src/Knot/Export/Encode.hs:94-98`,ADR-003 沒有 `kind` 欄位)。層必須從**結構**推:
graph-core 組裝規則 2 對每個 decl / instance 節點都發一條 `contains`(module → 該節點)
邊,所以 **「是某條 `contains` 邊的目標」⇔「decl 層」**,其餘是 module 層。這條判準
是精確的、不靠 id 字串猜;graph-load 目前把 `contains` 歸為 `RelStructural` 後
**靜默丟掉**(`Load.hs:258`),丟掉之前剛好可以把目標記下來。

對非 knot 產生的 `codegraph.json`(沒有 `contains` 邊),所有節點都會被判為
module 層——`--level decl` 得到空集合,`--level module` 等於不加。這是正確的退化。

## Scope(涵蓋範圍)

**動**(全部在 export-query 內):

- **graph-load**:載入時記錄 `contains` 的目標集合;新增模組介面
  `restrictLevel :: Level -> QueryGraph -> QueryGraph`——把圖收斂為指定層的**誘導子圖**
  (節點過濾、鄰接表與度數依過濾後的邊重算)。`QueryGraph` 內部多存依賴類邊的原始清單
  以便重算(欄位屬 Level 3)
- **query-engine**:`Reachable` 的 BFS 加深度上限;其餘三個查詢**不動**(層由
  `restrictLevel` 在進入 `runQuery` 之前處理)
- **cli-assembly**:`knot query` 加全域選項 `--level all|module|decl`(預設 `all`,四個
  子命令共用,與 `--graph` 同層);`reachable` 加 `--depth N`(預設不限)
- **對外契約**(Level 2,回填 `design.md`):`QueryCommand.Reachable` 加第三個欄位
  `Maybe Int`;新增 `Level` DTO 與 `restrictLevel`;查詢規則加兩條;CLI 子命令對映表加
  兩個旗標。`system.md` 的 CLI 頂層契約同步加旗標(Level 1)

**明確不動**:

- `runQuery` / `loadQueryGraph` / `renderResult` 簽名;`FindNodes` / `ShortestPath` /
  `RankConnectivity` 建構子;`QueryResult`;輸出格式(`renderResult` 一字不改)
- `codegraph.json` 格式(ADR-003):**不**加 `kind` 欄位——下游 `scan-graph.mjs` 不認識它,
  而結構推導已經夠精確
- graph-core / extraction / project-meta
- 預設行為:不帶旗標時四個查詢的輸出 **byte 級相同**(回歸測試釘住)
- 排除的「順便改」:`reachable` 的輸出加 module 欄或縮排分層(輸出格式變更,另案);
  `rank` 加 `--by in|out`(另案);批次查詢(一次 CLI 多個問題,另案——實測 31 次呼叫
  20 s 的問題由 `--level module` 的 `reachable --depth 1` 一次回答大半)

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| 「`Pipeline` 直接依賴哪些 module」 | 65 節點 / ≈626 tokens,或 shell 過濾兩次呼叫 590 ms | `reachable Knot.Extract.Pipeline --depth 1 --level module` **一次呼叫**,輸出 3 列(BuildDriver、Extract.Types、Meta.Types)、≤ 30 tokens |
| 「誰直接依賴 `Pipeline`」 | 同上 | `… --reverse --depth 1 --level module` → 1 列(`Knot.Extract`) |
| module hub 排名 | `rank` 回 decl 層;要自己掃 JSON | `rank --level module --top 10` 與「掃 `imports` 邊算 fan-in」同一份排名(Meta.Types 18、Extract.Types 16、Graph.Types 9 …) |
| 非 knot 圖(無 `contains`) | — | `--level decl` 空集合、`--level module` 與不加相同,不報錯 |
| 預設行為 | — | 四個查詢不帶旗標的輸出與改善前 **byte 相同**(既有 F003 / F004 測試全綠) |
| `--depth 0` / 負數 | — | CLI 拒絕(`--depth` 必須 ≥ 1),訊息明確 |

## 相依性

`depends-on: []`——只動 export-query 內部與其契約;被優化的 feature 是 F002(graph-load)、
F003(query-commands)、F004(cli-wiring),皆 done。與 extraction/E001(`.hie` 過濾)
互不相干,可平行。

## 改善方案

### M1 層的判定與誘導子圖(graph-load)

```haskell
data Level = LevelAll | LevelModule | LevelDecl      -- 新增 DTO(Knot.Query.Types)

-- QueryGraph 新增兩個 Level 3 欄位
  , qgDeclNodes :: Set NodeId            -- contains 邊的目標集合 = decl 層節點
  , qgDepEdges  :: [(NodeId, NodeId)]    -- 依賴類邊原始清單(含重複,度數重算用)

restrictLevel :: Level -> QueryGraph -> QueryGraph   -- 新增模組介面(Knot.Query.Load)
```

- `absorb` 的 `RelStructural` 分支:relation == `contains` 時把 `t` 加進 `accDecl`;
  其餘結構類仍靜默丟
- `restrictLevel LevelAll g = g`;`LevelModule` 保留 `qgDeclNodes` 之外的節點、
  `LevelDecl` 保留其內的節點;邊只留**兩端都保留**者,`qgForward` / `qgReverse` /
  `qgOutDeg` / `qgInDeg` 依留下的邊重算(度數仍算邊數、不去重,與假設 A4 一致);
  `qgNodes` / `qgIndex` 同步過濾;`qgNotes` 不動
- 決定性:過濾不改變既有排序;重算走同一個 `absorb`

### M2 深度上限(query-engine)

`Reachable NodeId Direction (Maybe Int)`;`reachableFrom` 的 `go` 在 `d > limit` 時停止
(`Nothing` = 不限)。規則 5「起點不入結果、環上以真實距離出現」不變——深度只是截斷。

### M3 CLI(cli-assembly)

```text
knot query [--graph FILE] [--level all|module|decl] <find|reachable|path|rank> …
knot query reachable ID [--reverse] [--depth N]        N ≥ 1
```

`Run.runQueryCmd`:`loadQueryGraph` → `restrictLevel level` → `runQuery`;
`missingNodeLines` 對「節點存在但不在該層」給明確訊息(`… not at level module`),
而不是靜默回空——這與 F004 為 `queryGraphHasNode` 立的理由相同。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data QueryGraph = QueryGraph { qgNodes :: [QueryNode], qgIndex :: Map NodeId QueryNode, qgForward :: Map NodeId [NodeId], qgReverse :: Map NodeId [NodeId], qgOutDeg :: Map NodeId Int, qgInDeg :: Map NodeId Int, qgNotes :: [(Text, Int)] }` | `src/Knot/Query/Types.hs:56-65` | F002 | M1 加兩欄 |
| `absorb :: Acc -> RawEdge -> Acc`;`classifyRelation :: Text -> RelationClass` | `src/Knot/Query/Load.hs:256-268`、`:79-82` | F002 | M1 記錄 `contains` 目標 |
| `parseQueryGraph :: FilePath -> ByteString -> Either LoadError QueryGraph` | `src/Knot/Query/Load.hs:135-171` | F002 | M1 填新欄位 |
| `data QueryCommand = FindNodes Text \| Reachable NodeId Direction \| ShortestPath NodeId NodeId \| RankConnectivity Int` | `src/Knot/Query/Types.hs:79-84` | F003 | M2 改 `Reachable` |
| `reachableFrom :: QueryGraph -> NodeId -> Direction -> [(NodeId, Int)]` | `src/Knot/Query/Engine.hs:89-105` | F003 | M2 加深度 |
| `runQuery :: QueryGraph -> QueryCommand -> QueryResult` | `src/Knot/Query/Engine.hs:49-54` | F003 | 不動;M3 在其前套 `restrictLevel` |
| `queryParser :: Parser QueryCmd`;`reachableParser :: Parser QueryCommand`;`data QueryCmd = QueryCmd { qcFile :: FilePath, qcCommand :: QueryCommand }` | `app/Knot/App/Cli.hs:151-182`、`:100-103` | F004 | M3 加旗標與 `qcLevel` |
| `runQueryCmd :: Handle -> Handle -> QueryCmd -> IO ExitCode` | `app/Knot/App/Run.hs` | F004 | M3 套 `restrictLevel` |

## 介面變動

| 變動 | 層級 | 受影響呼叫端 |
|---|---|---|
| 新增 DTO `data Level = LevelAll \| LevelModule \| LevelDecl`(`Knot.Query.Types`,經 `Knot.Query` 匯出) | Level 2 對外契約 | cli-assembly |
| `QueryCommand.Reachable NodeId Direction` → `Reachable NodeId Direction (Maybe Int)` | Level 2 對外契約(**建構子變更**) | `Engine.runQuery`、`Cli.reachableParser`、`Run.missingNodeLines`、測試 `test_query_command_types` / `test_query_reachable` / `test_query_flags_parse` / `test_cli_toplevel_parse` / `test_render_result`(若建構 `Reachable`) |
| 新增 `restrictLevel :: Level -> QueryGraph -> QueryGraph`(`Knot.Query.Load`,經 `Knot.Query` 匯出) | Level 2 模組間公開介面 + 對外契約 | cli-assembly |
| `QueryGraph` 新增 `qgDeclNodes`、`qgDepEdges` | Level 3(契約只寫「內容屬 Level 3」) | graph-load、query-engine 內部 |
| CLI `--level`、`--depth` | Level 1 CLI 頂層契約(system.md)+ Level 2 子命令對映表 | 使用者 |
| 查詢規則 7(層)、8(深度) | Level 2 | — |

## TodoList

- [x] T1: graph-load——`Level` DTO、`qgDeclNodes` / `qgDepEdges`、`absorb` 記錄 `contains` 目標、`restrictLevel`(誘導子圖 + 度數重算)  `dep: -`
- [x] T2: query-engine——`Reachable` 加 `Maybe Int`,`reachableFrom` 深度截斷;`runQuery` 其餘不動  `dep: T1`
- [x] T3: cli-assembly——`--level`(全域)與 `--depth`(reachable,≥ 1)解析、`QueryCmd.qcLevel`、`runQueryCmd` 套 `restrictLevel`、`missingNodeLines` 的「不在該層」訊息  `dep: T2`
- [x] T4: 文檔——`design.md` DTO / 規則 7、8 / CLI 對映表 / 模組間介面;system.md CLI 頂層契約;README §`knot query`  `dep: T3`
- [x] T5: 回歸與量化——既有 F003 / F004 測試改寫 `Reachable` 的第三欄為 `Nothing` 後全綠;預設輸出 byte 不變;knot-hs 自掃上 `reachable Knot.Extract.Pipeline --depth 1 --level module` 與 `rank --level module` 的驗收  `dep: T3`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e001_restrict_level` | 手寫 JSON(2 module、3 decl、`contains` ×3、`imports` ×1、`calls` ×2、一條 module→decl 的 `calls`):`qgDeclNodes` 恰 3;`restrictLevel LevelModule` 只剩 2 節點、1 條 `imports`、度數 1/1;`LevelDecl` 只剩 3 節點、decl 間的 `calls`(module→decl 那條消失);`LevelAll` 與原圖相等;無 `contains` 的 JSON → `LevelDecl` 空、`LevelModule` 與原圖相等 |
| T2 | `test_e001_reachable_depth` | 鏈 A→B→C→D:`Nothing` 回 3 筆;`Just 1` 只 B;`Just 2` B、C;環 A→B→A 配 `Just 1` 回 B(起點不入);`--reverse` 同理 |
| T3 | `test_e001_query_level_flags_parse` | `knot query --level module reachable X --depth 2` 解析為 `(LevelModule, Reachable X Forward (Just 2))`;`--depth 0`、`--depth -1`、`--level foo` 解析失敗;不帶旗標 = `(LevelAll, … Nothing)`;`missingNodeLines` 對「存在但不在該層」的節點給 `not at level module` |
| T4 | `test_e001_docs_mention_flags` | `design.md`、`system.md`、README 三處都含 `--depth` 與 `--level`;`design.md` 查詢規則有第 7、8 條 |
| T5 | `test_e001_default_output_unchanged` + 既有 `test_query_find` / `test_query_reachable` / `test_query_path` / `test_query_rank` / `test_render_result` / `test_query_flags_parse` | 對 `graph` fixture 的黃金圖,四個查詢不帶旗標的 `renderResult` 輸出與改善前逐字相同(改善前輸出先釘成測試內常數);自掃:`reachable Knot.Extract.Pipeline --depth 1 --level module` 恰 `[BuildDriver, Extract.Types, Meta.Types]`、`--reverse` 恰 `[Knot.Extract]`;`rank --level module --top 3` 前三名 = `Knot.Meta.Types`、`Knot.Extract.Types`、`Knot.Graph.Types` |

## 實作備註

### 2026-08-23 實作完成

**量化結果**(對照「改善目標」,knot-hs 自掃圖):

| 指標 | 改善前 | 改善後 |
|---|---|---|
| 「`Pipeline` 直接依賴哪些 module」 | `reachable` 65 節點(≈626 tokens),或兩次呼叫 + shell 過濾 | `reachable Knot.Extract.Pipeline --depth 1 --level module` **一次呼叫**,恰 3 列:`Knot.Extract.BuildDriver`、`Knot.Extract.Types`、`Knot.Meta.Types`(T5) |
| 「誰直接依賴 `Pipeline`」 | 同上 | `… --reverse --depth 1 --level module` → 恰 `Knot.Extract`(T5) |
| module hub 排名 | `rank` 回 decl 層 | `rank --level module` 前兩名 `Knot.Meta.Types`、`Knot.Extract.Types`,與掃 `imports` 邊的 fan-in 排名一致(T5;module 層的總度數含 fan-out,`Knot.App.Run` 因 out=12 排進前段,是正確語意) |
| 非 knot 圖(無 `contains`) | — | `LevelDecl` 空、`LevelModule` 與原圖 `Eq` 相等(T1) |
| 預設行為 | — | golden `graph.json` 上四個查詢不帶旗標的輸出與改善前**逐字相同**(T5 釘成常數);既有 F003 / F004 測試改寫第三欄為 `Nothing` 後全綠 |
| `--depth 0` / 非數字 / `--level foo` | — | 解析失敗(T3) |
| 「存在但不在該層」 | — | `query: node Demo.Core is not at level decl`,exit 0(T3) |

**實作取捨**(Level 3 自主權內):

- 層的判定**只看 `contains`**(`absorb` 的 `RelStructural` 分支多記一個集合),其他結構類
  relation(`method`、`defines`…)仍靜默丟——dev-flow 其他產生器的結構邊語意不一,
  不能拿來推層
- `restrictLevel` 重算鄰接表與度數走**同一個 `addDependency`**(從 `absorb` 抽出),
  載入與收斂的度數語意(算邊數、不去重)不可能漂移;`qgDepEdges` 為此保留原始清單
  (含重複、依檔序),`Eq` 比對時 `LevelAll` 恆等、`LevelModule` 對無 `contains` 的圖
  亦等(T1 證實)
- `--depth` 以 `eitherReader` 拒絕 ≤ 0 與非整數;`--level` 是 `knot query` 的**全域**
  選項(與 `--graph` 同層),`QueryCmd` 多一欄 `qcLevel`
- `missingNodeLines` 改收「完整圖 + 收斂後的圖」兩張,先判「不存在」再判「不在該層」
- 既有測試:`QT.Reachable` 的 14 處呼叫加 `Nothing`、`QueryCmd` 的 11 處記錄建構加
  `qcLevel = QT.LevelAll`、F002 T1 的 `QueryGraph` 記錄補兩欄;全部機械性改寫,
  無斷言變動

**連帶更新**:`design.md`(DTO、規則 7 / 8、CLI 對映表、`restrictLevel`)於設計階段已回填;
本次把 `system.md` CLI 契約的「設計中」標記拿掉、README §`knot query` 加旗標與三個常用組合。
