---
id: system
type: system
title: knot-hs
description: 讀 Haskell 專案的 .hie 與 import 產出 dev-flow 相容程式碼知識圖
status: active
created: 2026-08-20
updated: 2026-08-22
subsystems: [project-meta, extraction, graph-core, export-query]
---

# knot-hs 系統主架構

## 需求說明

dev-flow 0.8.1 起支援「程式碼知識圖」整合層:專案根目錄有 `codegraph.json` 時,`/arch-audit` 能直接計算子系統依賴矩陣、循環依賴、跨界引用與架構 hub;`/feature-design`、`/enhance-design`、`/bugfix` 能用它定位。但目前唯一登記的產生器 graphify **不支援 Haskell**(`.hs` 完全不被分類,連 LLM 語意抽取都繞不過去)。

knot-hs 要填這個洞:讀取 Haskell 專案,產出 dev-flow 相容的 `codegraph.json`。而且 Haskell 的原料比 graphify 支援的語言更好——GHC 的 `.hie` 檔是型別檢查後、名稱全部解析完的事實,graphify 需要用啟發式猜的東西,這裡直接有答案。

**目標**

- 產出 module 級依賴圖(滿足架構檢測的全部需求)+ 函式級呼叫圖(定位加速)
- 決定性輸出:零 API key、零 LLM、同樣輸入同樣結果
- 末期提供查詢 CLI(關鍵字查節點、反向可達、最短路徑、連通度排名)
- **零前置、單一命令**:裝一個執行檔、打 `knot extract .`,不要求使用者安裝任何其他工具、不要求他先對自己的專案做任何事——與 graphify 的體驗對齊(→ ADR-006)

**非目標**

- 不做 LLM 語意推測邊(GHC 給的是事實,不需要猜的那層)
- 不做社群偵測與命名(module 階層本身就是分群,`.design/subsystems/*` + `code-paths` 才是權威分組)
- 不做視覺化(`scan-graph.mjs` 的文字輸出就是消費端)
- 不做多語言(只服務 Haskell)

**使用者與體量**:長期維護的個人工具,服務使用者自己的 Haskell 專案。驗收標的兩個,不得異動其程式碼、既有檔案與既有建置產物(唯一例外:允許新建 `.knot/` 快取目錄——插樁建置的 builddir、產出的 `.hie`、hiedb 索引全部收在裡面,一行 `.gitignore` 即可排除;第一次慢,之後三層都增量):MagicFarmer(`C:\Users\User\Documents\GameProjects\MagicFarmer`,4 個子系統,驗 dev-flow 整合)、particle-magic(`C:\Users\User\Documents\GameProjects\particle-magic`,單套件 9 個 component 含具名 sub-library / foreign-library / 跨目錄 test-suite,驗 component 歸類與多套件 DTO)。

## 技術棧與環境

- **語言 / 編譯器**:Haskell,GHC 9.14.1(base 4.22),`default-language: GHC2024`,cabal-install 3.16.1.0
- **架構模式**:單一執行檔 `knot`,內部為四個 Bounded Context 的單向資料流 DAG(拓撲見下)
- **硬性版本鎖**:`.hie` 的讀寫綁 GHC 版本,knot-hs 必須用與目標專案相同的 GHC 編譯(→ ADR-001;ADR-006 使其更關鍵——knot 自己產 `.hie` 又自己讀,兩端必須同版)
- **關鍵依賴**(→ ADR-006):
  - **`hiedb`(build-depends 嵌入)**:函式級抽取的索引引擎,走 hiedb 的 library API 建索引與查詢,不 spawn 外部執行檔;`cabal.project` 以 `allow-newer: hie-compat:base, hie-compat:ghc` 解相依。**使用者不必安裝、不必知道它存在**
  - **目標專案的建置系統(`cabal`)**:`.hie` 缺席或過期時,knot **自行**對目標專案執行插樁建置(`-fwrite-ide-info`)產生之,建置產物落在 `.knot/` 的獨立 builddir,**不碰對方既有的 `dist-newstyle`**
  - 下游消費者:dev-flow `arch-audit/scripts/scan-graph.mjs`(非依賴,是契約對象;→ ADR-003)
- **兩層缺一不可**(→ ADR-006):module 層與函式層同時成立才算成功;任一層拿不到(目標專案建不起來、GHC 版本不合、索引失敗)就**明確失敗**,不產出部分圖。module 級的關聯無法協助寫 code,「降級成功」只是把沒用的結果回報成成功
- **發佈形式**:`cabal install` 產生獨立執行檔;文件明載版本鎖要求,執行時檢查 `.hie` header 的 GHC 版本,不合者**失敗**而非告警

### package 佈局(契約面收斂)

`knot-hs` package 內為**雙 library**(→ ADR-004,G-E001 落地):

| stanza | 內容 | 誰依賴它 |
|---|---|---|
| `library knot-internal`(`visibility: private`) | `src/` 全部 26 個模組 | `test-suite knot-test` |
| `library`(公開) | 只 `reexported-modules` 四個子系統的進入點與對外 DTO 共 9 個模組 | `executable knot` |

**exe 只依賴公開 library、test-suite 依賴 private sublibrary**——組裝層碰到非契約
模組時是編譯錯誤(`GHC-87110 hidden package`),而 1-to-1 測試仍摸得到內部純函數。
子系統內部模組的匯出清單因此不再是「對外公開面」,重構它們不必回頭改架構文件。

公開 `library` 的 `hs-source-dirs` 必須明寫 `src`:省略的話 cabal 套用預設值 `.`,
該 component 就宣告擁有整個 repo,knot 掃自己時連 `test/fixtures/**.hs` 都會被認領。

### 建置品質閘門(`-Wall` 零警告)

全專案三個 component 都帶 `-Wall`,**零警告**是硬性要求。閘門與收尾的驗收指令**只有這一條**:

```
cabal clean && cabal build all --enable-tests --ghc-options=-Werror
```

**`cabal clean` 是必要條件,不是保險。** 少了它,兩種看似合理的做法都會回報「乾淨」而實際不然(2026-08-22 實測,G-E002):

| 想走的捷徑 | 實際結果 | 為什麼是假答案 |
|---|---|---|
| `--ghc-options=-fforce-recomp` | `Up to date`、0 警告 | cabal 自己的 up-to-date 檢查先短路,GHC 根本沒被呼叫 |
| `--ghc-options=-Werror`(不 clean) | exit 0、0 警告 | cabal 會重新呼叫 GHC,但 **GHC 的重編檢查不理會警告旗標的變動**,每個模組都被跳過、警告不重印 |
| `touch` 原始檔 | 同上 | cabal 用內容雜湊而非 mtime 判斷 |

根因是**增量建置不重印警告**:GHC 只在真的重編某個模組時才發警告。這讓警告能在無人察覺下長回來——`-Wall` 零警告曾在四次子系統閘門被宣告「達成」,而全量重建的真實數字是 9 筆(G-E002 的發現依據)。任何「本次零警告」的宣告,都必須出自上面那條 clean 指令。

## 系統對外介面(External I/O Contract)

### Input

1. Haskell 專案根目錄(預設為目前目錄):`*.cabal`、`cabal.project`、Haskell 原始碼
2. 目標專案**必須能以 `cabal build` 建置成功**——這是唯一的前置條件,且它是對方專案本來就該滿足的。`.hie` 與索引由 knot 自己產生(→ ADR-006),不是輸入

不再是輸入的東西:`.hie` 目錄(knot 自產)、`hiedb` 執行檔(已嵌入)。

### Output

1. **`codegraph.json`**(預設寫到目標專案根目錄)——唯一的檔案輸出,格式由 dev-flow 定義(→ ADR-003):
   - `nodes[]`:必要 `id` / `label` / `source_file`(repo 相對路徑、正斜線);選填 `source_location`
   - `links[]`:必要 `source` / `target`(節點 id)/ `relation`;選填 `confidence`
   - 頂層選填 `directed`、`built_at_commit`
   - relation 依賴類(`imports`、`calls`、`uses`、`implements` 等十種)才算進下游依賴圖;結構類(`contains`、`method`、`defines`、`declares`、`rationale_for`、`part_of` 六種)不算。兩份名單以 ADR-003 為準,並與 `scan-graph.mjs` 的 `DEP_RELATIONS` / `STRUCTURAL_RELATIONS` 逐項對齊
2. 查詢結果(S4):stdout 文字輸出
3. 警告與錯誤:stderr;有警告仍 exit 0,`--strict` 時**任何警告** exit 1。**兩層任一層整體拿不到則 exit 1**,這不是警告、不受 `--strict` 影響(→ ADR-006)
4. **`.knot/` 快取目錄**(目標專案根目錄下,唯一允許的副作用):插樁建置的 builddir、產出的 `.hie`、hiedb 索引。純快取,刪掉只會讓下次變慢;內容格式屬 Level 2/3 自主權,不是契約

### CLI 介面(頂層契約)

```text
knot extract [PATH]          產出 codegraph.json(需要時自行建置目標專案產 .hie,全自動)
  --output FILE              預設 <PATH>/codegraph.json
  --include-tests            納入 test-suite component(預設排除)
  --strict                   任何警告改為 exit 1
  --summary meta|facts|graph 改印該站的摘要到 stdout,不寫 codegraph.json

knot query <find|reachable|path|rank> …   (S4)讀取 codegraph.json 回答導航問題
  --graph FILE               讀哪份圖,預設 ./codegraph.json(四個子命令共用)
  find <keyword>             關鍵字比對 id 與 label(不分大小寫)
  reachable <id> [--reverse] 可達集合;--reverse 改問「誰依賴它」
  path <from> <to>           兩點最短路徑
  rank [--top N]             連通度排名,N 預設 10
```

**ADR-006 移除的旗標**:`--backend`、`--module-only`、`--hiedir`、`--hiedb`、`--db`。它們全是「有兩個後端、有外部執行檔、有使用者要自己產的檔案」這些實作細節洩漏到介面的結果;那些細節不存在了,旗標也就沒有存在的理由。`.knot/` 固定在目標專案根目錄,不提供改道——它是快取,與 `dist-newstyle` 同性質。

`--summary` 承接開發期的三條唯讀對帳路徑(取代早期的 `--facts` / `--graph` 旗標)。

內部旗標細節(參數格式、預設值微調)屬 Level 2/3 自主權,此處只鎖定子命令劃分與語意。

## 子系統劃分(Subsystems & Bounded Contexts)

單一執行檔內的四個 Bounded Context,依單向資料流排列。四者的 Level 2 `design.md` 均已建立。

### project-meta — 專案發現

已建 Level 2:`.design/subsystems/project-meta/design.md`

- **職責**:解析 `.cabal` / `cabal.project` 取得 component(library / executable / test-suite 等,支援多套件)與 `hs-source-dirs`,把每個原始碼檔歸類到 component(一對多);產出 test 排除判定(檔案級的 `sfIncluded` 與 component 級的 `compExcluded`)。**`.hie` 的定位、列舉與幽靈過濾自 S5 起移交 extraction**(ADR-006:`.hie` 由 extraction 自建於 `.knot/`,project-meta 跑在建置之前、看不到它)
- **邊界(不做)**:不讀原始碼內容、**不碰 `.hie`**、不建圖、不觸發任何編譯
- **對外契約摘要**:輸入專案根目錄,輸出「專案描述」——檔案清單(含 module 名對映、component 歸屬、是否排除)與 component 清單(extraction 據此決定建置哪些 component)

### extraction — 事實抽取

已建 Level 2:`.design/subsystems/extraction/design.md`

- **職責**:定義統一的抽取契約,把原始碼/`.hie` 轉成「事實流」(module import、頂層宣告、名稱引用、class/instance 關係)。兩個來源**都必須成功**:import-scan(掃 import 行,imports 邊的唯一來源)與 hie-index(`.hie` 缺席或過期時**自行驅動目標專案的插樁建置**產生之,再以內嵌的 hiedb library 建索引並讀取,產出 decl 層)。沒有「後端選擇」,沒有「降級」(→ ADR-006)
- **邊界(不做)**:不決定節點 id、不組圖、不過濾 test(接受 project-meta 的判定)、不寫 `codegraph.json`;**唯一的檔案副作用是 `.knot/` 快取**
- **對外契約摘要**:輸入專案描述,輸出事實流;任一來源整體失敗(目標專案建不起來、GHC 版本不合、索引失敗)即回報失敗並說明原因,不產出部分事實流

### graph-core — 圖 IR

已建 Level 2:`.design/subsystems/graph-core/design.md`

- **職責**:把事實流組裝成內部圖 IR(純函數):鑄造決定性節點 id(Module + OccName + namespace,絕不用 GHC `Unique`);組裝 module + decl 兩層節點與 `contains` 結構邊;過濾 TH/deriving 產生碼的異常 span;外部目標丟棄與統計;彙整警告
- **邊界(不做)**:不讀檔案、不認識 `.hie` 或 SQLite、不序列化
- **對外契約摘要**:輸入**事實流 + 專案描述**(後者來自拓撲的邊 2:建圖要靠專案描述的檔案清單判定內外部與過濾),輸出圖 IR(內部模型,非匯出格式)

### export-query — 匯出與查詢

已建 Level 2:`.design/subsystems/export-query/design.md`

- **職責**:把圖 IR 投影成 `codegraph.json`(欄位規格與 relation 分類遵守 ADR-003,`built_at_commit` 自動偵測);S4 起提供查詢 CLI(關鍵字查節點、反向可達、兩點最短路徑、連通度排名,只走依賴類邊);**並承載 CLI 組裝層**——`knot` 的參數解析、四站管線串接、上游警告匯流與 exit code 決定。組裝層本身是跨子系統的黏合層,落在此處是因為兩個子命令的主體都在管線末站
- **邊界(不做)**:不建圖、不改圖;查詢只讀不寫;組裝層不含任何投影/載入/查詢邏輯(全部委由四個子系統的契約函式)
- **對外契約摘要**:輸入圖 IR(或既有 codegraph.json),輸出 JSON 檔與 stdout 查詢結果

## 通訊拓撲與原則(Communication Topology)

- **拓撲**:單向 in-memory **DAG**(無反向呼叫、無環),**四條邊、一條都不多**:

  | # | 邊 | 載送什麼 | 為什麼存在 |
  |---|---|---|---|
  | 1 | `project-meta → extraction` | `ProjectMeta` | 後端要知道讀哪些檔 |
  | 2 | `project-meta → graph-core` | `ProjectMeta` | 建圖要靠專案描述的檔案清單判定內外部與過濾(**不是旁路,是宣告內的邊**) |
  | 3 | `extraction → graph-core` | `ExtractResult`(事實流) | 建圖的原料 |
  | 4 | `graph-core → export-query` | `CodeGraph`(圖 IR) | 投影的輸入 |

  主線是 `project-meta → extraction → graph-core → export-query`,第 2 條是 project-meta
  **同時**餵 extraction 與 graph-core 的分岔——它是 graph-core Level 2 契約進入點的
  參數之一,不是實作偷跑。

  **這四條以外的跨子系統依賴一律視為旁路**,特別是 `export-query → project-meta`
  與 `export-query → extraction`:兩者都不在表上,必須維持零。
- **共用詞彙型別的邊界**(兩條判準,同時成立才合格):

  1. **只能透出你真的依賴的人**:公開契約 DTO 得使用上游詞彙型別(`ModuleName`、
     `DeclKind` 等),但**僅限上表中本子系統確實有邊指向的那些子系統**。透出沒有邊
     的子系統之型別,等於逼消費端替你建一條旁路
  2. **報告 / 統計欄位一律不得使用上游詞彙型別**:那種欄位裝的是**外部世界的資料**
     (被丟棄的第三方 module 名之類),不是沿管線流動的值。包成上游型別換不到任何
     型別安全,只會讓消費端為了拆包多認識一個型別

  第 1 條擋未來的旁路,第 2 條擋 `GraphStats` 那一類(G-E001 已修正:
  `gsTopExternalTargets` 改用 `Text`)。**只靠第 1 條是不夠的**——第 2 條邊補上之後
  project-meta 對 graph-core 就成了合法的相鄰,單看依賴關係反而判不出 `GraphStats`
  有問題(→ ADR-005)。

  詞彙型別由定義它的子系統擁有,沿管線流動、零轉換(extraction Level 2 的批次澄清
  裁定);**擁有者要 re-export 它**,消費端才不必為了命名而繞回源頭。
- **全域錯誤處理**分兩個層次(→ ADR-006):
  - **整體失敗**(exit 1,與 `--strict` 無關):目標專案建不起來、`.hie` 的 GHC 版本與 knot 不合、索引整體失敗——任一層拿不到就不產圖。理由:部分圖會被下游當真
  - **單檔 best-effort**(警告 + 跳過,仍產圖):在兩層都成立的前提下,個別檔案讀不過(單一壞 `.hie`、單檔解析失敗)印警告到 stderr、跳過續跑;有警告時 exit 0,`--strict` 使**任何警告**變 exit 1。不認得的 relation 或資料一律列印,不靜默吞掉
- **沒有降級原則**:ADR-002 的「hiedb 不可用時降到 module 級」已廢除。module 級的關聯無法協助寫 code,把它當成功回報比明確失敗更糟

## 架構圖

```text
  Haskell 專案                         knot(單一執行檔,內嵌 hiedb)
 ┌──────────────────┐   ┌──────────────────────────────────────────────────┐
 │ *.cabal          │──▶│ project-meta                                     │
 │ cabal.project    │   │   │ ProjectMeta ──────────┐(邊 2:同一份專案描述 │
 │ src/**/*.hs      │──▶│   ▼(邊 1)              │  也直接餵給 graph-core │
 │                  │   │ extraction               │  供內外部判定)        │
 │ .knot/ 快取      │◀─▶│   ├─ import-scan         │                       │
 │  build/ hie/ db  │   │   └─ hie-index ── .hie 缺/過期時自行 cabal build │
 └──────────────────┘   │   │ 事實流(邊 3)        │   產生,內嵌 hiedb 索引 │
                        │   ▼                      │                       │
                        │ graph-core ◀─────────────┘                       │
                        │   │ 圖 IR(邊 4)                                 │
                        │   ▼                                              │
                        │ export-query                                     │
                        └───┬──────────────────────────┬───────────────────┘
                            ▼                          ▼
                     codegraph.json             查詢結果(stdout)
                     (repo 根目錄)                    │
                            │                          │
                            ▼                          ▼
                dev-flow scan-graph.mjs        /feature-design、/bugfix
                (/arch-audit 等七個接點)        定位加速
```

## 開發階段

| 階段 | 涵蓋子系統 | 里程碑 |
|---|---|---|
| **S1 骨架 + T0 上線** | project-meta(路徑掃描部分)、extraction(import-scan)、graph-core(module 層)、export-query(匯出) | 在 MagicFarmer 跑出 `codegraph.json`,`scan-graph.mjs` 吃得下,依賴矩陣/循環依賴可用 |
| **S2 .cabal 整合** | project-meta(component 解析、幽靈 `.hie` 過濾) | 免設定即正確排除 `test/`,test 排除改由 component 判定 |
| **S3 函式級抽取** | extraction(hiedb-sqlite 後端)、graph-core(decl 層、產生碼過濾) | 兩層節點、`calls` / `uses` 邊、hub 洗版實測、循環依賴人工複驗 |
| **S4 查詢 CLI** | export-query(查詢、CLI 組裝) | `knot query` 四項能力可用,`/feature-design`、`/bugfix` 定位加速接上 |
| **S5 零前置重構** | extraction(hiedb 嵌入、自驅動建置、移除降級)、export-query(砍旗標) | `knot extract .` 在**沒有 `.hie`、沒裝 hiedb** 的乾淨目標專案上一個命令跑出兩層圖;`--backend` / `--module-only` / `--hiedir` / `--hiedb` / `--db` 全部消失(→ ADR-006) |

每階段結束以 MagicFarmer 驗收(唯讀)。

**`implements` 邊不在 S3**(2026-08-21 調整):hiedb 0.8 的索引 schema 沒有 instance 表(實測八張表:mods / decls / defs / refs / exports / imports / typenames / typerefs),`FactInstance` 需要的「class + instance 標頭」無直接資料來源。`Fact` 的建構子保留、零邏輯,`implements` 邊另開 feature——要嘛從 refs 反推,要嘛直接讀 `.hie`(ADR-006 替代方案 2、3 的路線,目前未採用)。同理,S3 的 decl 層過濾改用 hiedb 的 `refs.is_generated` 事實,不再是「TH 過濾」的啟發式。

**進度**(2026-08-22):**S1–S4 四階段全數完成**,四個子系統的 14 份 feature 與三份全域優化(G-E001 / G-E002 / G-E003)皆 `done`。**S5 開工**:與 graphify 實測對照後發現 S1–S4 的成果在別人的專案上幾乎不可用(要裝第二個工具、要自己重建專案、要理解內部的能力分級),ADR-006 重定架構,extraction 與 export-query 的 Level 2 要重做。

S1–S4 完成時的唯讀實跑現況(當時以 `--db` 改道專案外;該旗標已於 S5 移除,改由 `.knot/` 快取承載):

| 標的 | 節點 / 邊 | 備註 |
|---|---|---|
| MagicFarmer | 67 / 288 | `scan-graph.mjs` 解析成功;數字較 2026-08-21 的 60/247 上升是標的自身新增 mind-sea 四個 feature |
| particle-magic | 46 / 127 | 與 2026-08-21 相同 |
| knot-hs 自掃 | 548 / 1947 | 0 警告;decl 層含 `calls` / `uses` 邊 |

`knot extract` 的兩層抽取與 `knot query` 四項能力均可用。**唯一已知未做的能力是 `implements` 邊**,理由與去處見上一段。
