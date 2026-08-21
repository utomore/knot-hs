---
id: F003
type: feature
title: decl-edges
description: 由 ref/instance 事實推導 calls/uses/implements 邊
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, F002, project-meta/F001, extraction/F001, extraction/F002, extraction/F004]
related-adr: []
related-feature: []
---

# F003: decl-edges — `calls` / `uses` / `implements` 推導

## 功能概述

graph-core 的最後一塊:把 extraction 的 `FactRef` / `FactInstance` 事實,對著 `F002` 鑄好的節點集合,推導成 decl 層的依賴邊——值目標產 `RCalls`、型別目標產 `RUses`、instance 對內部 class 產 `RImplements`。本 feature 完成後 graph-core 的四個內部模組全部填實,`codegraph.json` 從「module + decl 兩層節點,只有 `imports` / `contains` 邊」升級為**函式級呼叫圖**,dev-flow `/arch-audit` 的 hub 排名與 `/feature-design` 的定位加速才真的有依賴類邊可走。

**要解決的問題**:`FactRef` 是「(來源 module, 來源宣告, 目標 `QualName`, 檔案, 行)」的扁平列表,一筆 ref 對應原始碼裡的一次名稱出現,不是一條邊。它需要四層轉換才能成為圖的邊:(1) 目標 `QualName` 換成節點 id——而 `QualName` 只有 `(module, occ, namespace)`,沒有檔案線索,同名 module 消歧組下無從判定指向組內哪一個;(2) 來源在 `frFromDecl = Nothing` 時要退回 module 節點,而該 module 可能屬消歧組;(3) 遞迴呼叫是自環,留著會讓每個遞迴函式在 hub 排名裡自己灌自己;(4) 同一對 decl 之間的呼叫在真實專案裡動輒數十次(實測 knot-hs 自身原始邊 2107 → 去重後 1582,合併掉 525 條)。本 feature 建立這層轉換,並延續「同輸入必同輸出」與「不靜默吞資料」兩條紀律。

**驗收標準**(契約卡原文):

1. 值目標產 `RCalls`、型別目標產 `RUses`
2. `frFromDecl = Nothing` 的引用邊,源是 module 節點
3. 遞迴呼叫(自環)不產邊
4. 同一對 decl 間多次呼叫合併為一條,且 `geLine` 是最早行
5. instance 對內部 class 產 `RImplements`;對外部 class 丟棄並計入統計
6. 目標解析不到內部節點的 ref 彙整為警告,不靜默

**明確不做**(契約卡底線):不建新節點(節點集合由 `F002` decl-nodes 給定);不做 span 比對(`frFromDecl` 是 extraction 解析好給的);不改 imports 邊行為。另承子系統邊界:不讀檔案、不做任何 IO、不認識 `.hie` 或 SQLite、不序列化。另承委派決策:不重複做產生碼過濾(C4:`frGenerated = True` 的事實在 fact-gate 就被 `F002` 濾除,拿到的 `gfFacts` 已不含);不新增 `EdgeStats` / `GraphStats` 欄位(E4)。

**批次澄清 C2 的落實方式(本 feature 的核心)**:`NameSpace` → `Relation` 是 **term/type 二分**,四個值全部有歸屬:`ValueNs` / `DataConNs` / `FieldNs` → `RCalls`,`TypeNs` → `RUses`。實作以**四個顯式 pattern**(不留 catch-all)表述,讓未來新增 namespace 時 `-Wall` 的 `-Wincomplete-patterns` 直接擋下,而不是靜默落進某個分支。這不是潔癖:實測 knot-hs 自身通過閘門的 2655 筆內部目標 ref 中,`DataConNs` 363 筆、`FieldNs` 589 筆,合計 36% ——用 catch-all 或漏一個分支就會靜默少掉三分之一的 `calls` 邊。

**批次澄清 C1 的落實方式**:`FactInstance` 目前**無任何後端產出**(hiedb 0.8 的 schema 無 instance 表;實測 knot-hs 自身事實流 `FactInstance` 恰 0 筆)。本 feature 仍**完整實作** `RImplements` 推導,以手工事實流驗收;端到端輸出恆 0 條 `RImplements` 是預期行為,不是缺陷。ADR-002 預留的第三後端上線時零改動即生效。

## 相依性

`depends-on: [F001, F002, project-meta/F001, extraction/F001, extraction/F002, extraction/F004]`,六條全部由「使用到的既有串接介面」表反推。其中**五條是既有程式碼查證**(2026-08-22 自來源檔逐行讀出原文),**一條是文檔約定**:

- **`F002`(decl-nodes,同子系統)——唯一的「文檔約定」相依,不是程式碼查證**:`F002` 的 `status: open`、實作尚未開始,其產出物在 `main` 上讀不到。本 feature 依賴它的三件事,全部依 `.design/subsystems/graph-core/features/F002-decl-nodes.md`(2026-08-22 版)的介面表與 TodoList 對照,**未**打開原始碼確認:
  1. **decl / instance 節點集合**(`mintNodes` 擴充後的回傳值,T3):本 feature 的邊端點全部來自它,自己一個節點都不建
  2. **非契約面 `disambiguate` 與 `moduleOfFile`**(`F002` T2 新增於 `Knot.Graph.NodeMint`):簽名見介面表;本 feature 用它們把「事實的檔案」換成 `mintDeclId` / `mintInstanceId` 需要的 `Maybe FilePath`,以及把 `fiInstFile` 反查成 instance 的宣告 module(A3 裁決)
  3. **fact-gate 的組裝規則 3**(`F002` T1):`frGenerated = True`、行號 ≤ 0、檔案不在 `pmSources` 的 `FactRef` 在進 edge-derive 前已被濾除(C4)。本 feature **不重複過濾**,也不假設它們還在
  另,`F002` 會先在 `Knot.Graph.EdgeDerive` 建立 decl 層的判定鏈與警告彙整(`RContains`),本 feature 是在該鏈上**平行擴充** `FactRef` / `FactInstance` 兩支,不是重寫。**序列相依**:必須排在 `F002` 之後,不可平行
- **`F001`(module-graph,同子系統,`status: done`,程式碼已在 `main`)**:本 feature 改的是它建立的 `Knot.Graph.EdgeDerive`。使用面涵蓋 `deriveEdges` 的契約簽名與內部的 `Outcome` 判定鏈、`byNameFile` / `byName` 節點索引、`sourceNode` 來源解析(**額外查證 1 的答案就在這裡:沿用不改**,理由見「實作方式 › 3」)、`grouped` 去重表(規則 5)、`externalCounts` 外部統計(D4),以及 `EdgeStats` 三欄
- **`project-meta/F001`(scan-baseline,跨子系統,done)**:`ModuleName`(外部次數表、`gfInternal` 判定與警告累計表的鍵型別,已查證有 `Ord`);`SourceFile.sfPath` 的路徑語意「repo 相對、正斜線」是「實作方式 › 3」路徑相等比對成立的前提
- **`extraction/F001`(fact-contract,跨子系統,done)**:`FactRef` / `FactInstance` 的欄位名與型別(**三個名字欄位型別互異**:`frFromModule :: ModuleName`、`frFromDecl :: Maybe QualName`、`frTarget :: QualName`,已逐欄讀原始碼確認);`QualName` 的三個欄位;`NameSpace` 四個建構子(C2 的判準)
- **`extraction/F004`(hiedb-facts,跨子系統,done)**:**額外查證 1 的證據來源**。`refFactsOf` 把 `frFromModule` 與 `frFile` 從**同一個** `ModEntry` 取出(`meModule` / `meFile`),而 `meFile` 是 `resolveModuleSource` 回傳的 `sfPath` **原文**——這是「`(frFromModule, frFile)` 可以直接打 `byNameFile` 精確索引」的唯一依據
- **`extraction/F002`(import-scan,跨子系統,done)**:上一條的另一半。`scanFile` 的 `path = sfPath sf`、`scanSource` 的 `fmFile = path`,故 module 節點的 `gnFile` 也是 `sfPath` 原文,兩邊逐字相同、可用字串相等比對。這是**語意相依**(graph-core 不 import `Knot.Extract.ImportScan`),於本段落與介面表註明

未列入的相依與理由:

- **`project-meta/F002` / `F003`**:只改變 `sfIncluded` / `sfOwners` / `pmHie` 的填值語意,不改型別;本 feature 連 `ProjectMeta` 都不碰(`deriveEdges` 沒有這個參數)
- **`extraction/F003`(hiedb-driver)**:本 feature 完全不觸碰索引路徑
- **`export-query` 各 feature**:單向資料流的下游,本 feature 不呼叫它;已查證**不需改動**(見「實作方式 › 8」),不構成 `depends-on`(比照 `F001` / `F002` 的既有判準)

可平行性:**不可**與 `F002` 平行(契約卡明載「節點集合由 decl-nodes 給定」);可與其他子系統的任務平行。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/graph-core/design.md`(2026-08-22 版),無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| DTO `Relation` 的 `RCalls` | `FactRef` 目標為 `ValueNs` / `DataConNs` / `FieldNs` 時產生(C2) |
| DTO `Relation` 的 `RUses` | `FactRef` 目標為 `TypeNs` 時產生(C2) |
| DTO `Relation` 的 `RImplements` | `FactInstance` 對內部 class 產生(C1:手工事實流驗收) |
| 組裝規則 2 · `FactRef`(term-level)列 | `RCalls`(fromDecl → target decl) |
| 組裝規則 2 · `FactRef`(type-level)列 | `RUses`(fromDecl → target decl) |
| 組裝規則 2 · `FactRef`(`frFromDecl = Nothing`)列 | 以**來源 module 節點**為源,relation 依 namespace 同上 |
| 組裝規則 2 · `FactInstance` 的 `RImplements` 部分 | instance 節點 → class decl 節點;同列的**節點與 `RContains` 屬 `F002`,不重做** |
| 組裝規則 1(內部才實化) | `qnModule frTarget` / `qnModule fiClass` ∉ `gfInternal` → 丟棄該邊,計入 `esDroppedExternal` 與 `esTopExternal` |
| 組裝規則 4(自環丟棄) | 解析後 `geSource == geTarget` 的邊不產出、不計統計、不發警告(遞迴呼叫、自我引用) |
| 組裝規則 4b(內部性以 module 為判準) | `frFromModule` / instance 宣告 module ∉ `gfInternal` → 不產邊、**不**計 `esDroppedExternal`,彙整為 `GraphWarning`(判定順序見假設 A2) |
| 組裝規則 5(去重、證據行) | 與 `RImports` / `RContains` **共用同一個 `grouped` 去重表**,鍵含 relation 故不互相污染;`geLine` 取組內最小行 |
| 組裝規則 6(`moduleOnly`) | `Knot.Graph.isModuleLayer` 既有窄化已把 `FactRef` / `FactInstance` 排除 → 本 feature 的邊在 `moduleOnly = True` 時自動全為零,**零改動**;只補測試釘住 |
| 組裝規則 7(決定性)/ D5 排序 | `Relation` 的 `Ord` 建構子序 `RImports < RCalls < RUses < RImplements < RContains` 已 derive,`buildGraph` 既有的 `sortOn (geSource, geRelation, geTarget)` 在五種 relation 下即全序 |
| 模組介面 `deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])` | 簽名**一字不動**;新增 `FactRef` / `FactInstance` 兩支判定與其警告 |
| 模組介面 `EdgeStats` | 三欄**不動**(E4:`esDroppedExternal` 維持單一計數器) |
| 對外契約 `buildGraph` 簽名、`BuildOptions` / `CodeGraph` / `GraphStats` 欄位 | **完全不動** |
| 節點 id 鑄造規則表 | **不重做**(`F002` 的範圍);本 feature 只透過 node-mint 的函式**查**節點 id,不自己鑄 |
| 組裝規則 3(產生碼過濾)、規則 4a(消歧組的 import 目標) | **不觸碰**(分屬 `F002` 與 `F001`) |

超出 Level 2 契約的部分:**無**。本 feature 在 node-mint 新增**一個非契約面**函式 `declNodeIndex`(見「新增的介面」),沿用 `F001` 匯出 `moduleFiles`、`F002` 匯出 `disambiguate` / `moduleOfFile` 的同一慣例——它不出現在 design.md 的「模組間公開介面」,也不改變任何契約簽名。這正是編排者對 `F002` 假設 A8 的裁決所指定的作法。

## 實作方式

### 模組配置(全部是既有檔案的擴充,不新增 module)

```text
src/Knot/Graph/NodeMint.hs     -- 非契約面新增 declNodeIndex(QualName → 節點 id 索引)
src/Knot/Graph/EdgeDerive.hs   -- 新增 FactRef / FactInstance 兩支判定鏈與警告彙整
test/Main.hs                   -- 新增 graph-core/F003 group
```

`knot-hs.cabal` **完全不動**(無新 module、無新依賴);`version` 依 D6 凍結為 `0.0.1.0`。測試 group 命名 `graph-core/F003 decl-edges`。依 **E2**:新增程式碼在 `-Wall` 下不得產生任何新警告;`test/Main.hs` 既有的 8 筆警告(G-E002 追蹤)**不修**。

### 管線總覽(粗體為本 feature 的改動點)

```text
GatedFacts(F002 已濾除產生碼 / 壞行號 / 非 pmSources 的事實)
   │
   ├─▶ mintNodes ──▶ [GraphNode] = module(F001) ++ decl / instance(F002)
   │                     │
   ▼                     ▼
 deriveEdges gated nodes
   ├─ byNameFile / byName          (F001 既有,module 端點)
   ├─ **declNodeIndex gated nodes**(本 feature,decl / instance 端點)
   ├─ FactImport  → RImports       (F001 既有,一字不改)
   ├─ FactDecl / FactInstance → RContains  (F002,不重做)
   ├─ **FactRef      → RCalls / RUses**
   ├─ **FactInstance → RImplements**
   └─ 共用 grouped 去重表 → ([GraphEdge], EdgeStats, [GraphWarning])
```

### 1. node-mint:`declNodeIndex`(唯一的新介面)

**為什麼非有不可**:`FactRef.frTarget` 是一個 `QualName`,而 `deriveEdges` 的第二參數是 `[GraphNode]`——`GraphNode` 的五個欄位(`gnId` / `gnKind` / `gnLabel` / `gnFile` / `gnLine`)**無法還原** `(module, occ, namespace)` 三元組:`gnLabel` 只有裸 occ 名,同一檔的 `Foo#t`(型別)與 `Foo`(建構子)兩個節點的 `gnLabel` 都是 `Foo`,`gnKind` 也分不開(`declKindOf TypeNs = DataDecl`、`declKindOf DataConNs = DataDecl`,已讀 `Knot.Extract.HiedbFacts` 確認兩者同值)。

```text
declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]

nodeIds = Set.fromList (map gnId nodes)
files   = moduleFiles (gfFacts gated)                       -- F001 既有
entries = [ (fdName, (fdFile, nid))
          | FactDecl{fdName, fdFile} <- gfFacts gated
          , let nid = mintDeclId fdName (disambiguate files (qnModule fdName) fdFile)
          , nid `Set.member` nodeIds ]                       -- 只收真的鑄出來的節點
index   = Map.fromListWith (++) …                            -- 值依 (FilePath, NodeId) 排序
```

- **`nid ∈ nodeIds` 這個守門不是可選的**:編排者的裁決明載「查得到才產邊」——`codegraph.json` 的 `links` 若指向不存在的 `nodes`,下游 `scan-graph.mjs` 會壞。把守門放在索引建立時,結構性保證「索引查得到 ⇒ 節點存在」,edge-derive 不需要再驗一次
- **值是清單而非單值**:D1 消歧組下(多個 executable 各有自己的 `Main`)兩個 `Main.main` 是**同一個 `QualName`**、卻是兩個節點。這與 `F001` 的 `byNameFile` / `byName` 兩張索引是同一個模式:有檔案線索的一端用 `(名字, 檔案)` 收斂,沒有線索的一端只能在 >1 時判為歧義
- **值帶 `FilePath`** 的用途只有一個:`frFromDecl = Just q` 時,`q` 所在的檔案就是 `frFile`(hiedb 的 span 包含 join 條件是 `r.hieFile = d.hieFile`,已讀 `qRefs` 原文確認 fromDecl 必與 ref 同檔),故來源端可以用檔案把消歧組收斂到唯一節點;`frTarget` 沒有這個線索,只能靠清單長度判歧義
- 排序:`Map` 的鍵序 + 值清單顯式 `sortOn` → 對事實流重排序不敏感(規則 7)

instance 節點的 id **不進本索引**(它的鍵是 `QualName`,而 instance 沒有 `QualName`)。`RImplements` 的來源端沿用 `F002` 在 edge-derive 已建立的 instance 端點解析(`moduleOfFile` 反查 → `disambiguate` → `mintInstanceId` → 節點集合驗證),不另建第二條路徑。

### 2. edge-derive:`FactRef` 判定鏈

`Outcome` 需要一個新建構子承載**可彙整**的跳過理由(`F001` 既有的 `Unresolved GraphWarning` 是逐筆警告,對 imports 的量級沒問題,對 6000+ 筆 ref 會刷屏):

```text
data Outcome
  = External ModuleName          -- F001 既有
  | Unresolved GraphWarning      -- F001 既有(imports 逐筆,不動)
  | Skipped (Text, Text)         -- 本 feature:(gwSource, 原因) → 彙整計數
  | SelfLoop                     -- F001 既有
  | Derived GraphEdge            -- F001 既有
```

(若 `F002` 為 `RContains` 的彙整警告已引入等價建構子,**直接沿用、不另加**——內部型別屬實作自主權。)

逐筆 `FactRef` 依序判定(順序即優先序):

| 步驟 | 條件 | 動作 |
|---|---|---|
| 1 來源內部性(規則 4b) | `frFromModule` ∉ `gfInternal` | `Skipped`;不產邊、**不**計 `esDroppedExternal`(假設 A2 說明為何排在最前) |
| 2 目標外部判定(規則 1) | `qnModule frTarget` ∉ `gfInternal` | `External (qnModule frTarget)`;丟棄、`esDroppedExternal + 1`、累進外部次數表 |
| 3 目標解析 | `declNodeIndex` 查 `frTarget` 得 1 筆 | 取該 `NodeId` |
| | 0 筆(module 內部但沒有對應 decl 節點) | `Skipped`(驗收標準 6:彙整為警告,不靜默) |
| | ≥2 筆(D1 消歧組) | `Skipped`(比照規則 4a 對 import 目標的既有處理) |
| 4 來源解析 · `frFromDecl = Just q` | `declNodeIndex` 查 `q`,先以 `frFile` 過濾;過濾後恰 1 筆 | 取該 `NodeId` |
| | 過濾後 0 筆,但未過濾時恰 1 筆 | 取該筆(退路,對稱於 `sourceNode` 的既有退路) |
| | 其餘 | `Skipped` |
| 5 來源解析 · `frFromDecl = Nothing` | `sourceNode frFromModule frFile`(**`F001` 既有函式,一字不改**)命中 | 取該 module 節點 id(驗收標準 2) |
| | 未命中 | `Skipped` |
| 6 自環(規則 4) | `srcId == tgtId` | `SelfLoop`;丟棄,不計統計、不發警告(驗收標準 3) |
| 7 產出 | — | `Derived GraphEdge{ geSource, geTarget, geRelation = relationOf (qnSpace frTarget), geLine = Just frLine }` |

**C2 的 relation 對照(四個顯式 pattern,無 catch-all)**:

```text
relationOf ValueNs   = RCalls
relationOf DataConNs = RCalls
relationOf FieldNs   = RCalls
relationOf TypeNs    = RUses
```

extraction 的 `z:`(型別變數)在其契約已裁決不產出(`parseOcc` 回 `Nothing`、後端跳過該列並彙整警告,已讀原始碼確認),不會流到這裡。

### 3. `frFromDecl = Nothing` 的來源解析:沿用 `sourceNode`,**不需調整**(額外查證 1 的結論)

契約說「以來源 module 節點為源」。`F001` 的 `sourceNode` 是兩段式:先查 `byNameFile :: Map (Text, FilePath) NodeId`(鍵 = `(gnLabel, gnFile)`),未命中才退回「該名恰一個節點」。委派 prompt 提醒的風險是「消歧組的來源解析若靠 `frFromModule` 單獨判定會落空」——確實會,因為退路那段對消歧組回 `Nothing`。**但精確索引那段會先命中**,理由是三段程式碼查證(全部 2026-08-22 讀自來源檔,不是推論):

1. `Knot.Extract.HiedbFacts.refFactsOf`(`src/Knot/Extract/HiedbFacts.hs:337-354`)把 `frFromModule = meModule e` 與 `frFile = meFile e` 從**同一個 `ModEntry`** 取出——兩者必然配對,不會出現「module 名對、檔案錯」的組合
2. `resolveModuleSource`(同檔 `287-307`)的 haddock 與實作明載回傳的是 `sfPath` **原文**(「與 import-scan 的 `fmFile` 逐字相同」),不經 `makeAbsolute` / `canonicalizePath`;hiedb 的 Windows 反斜線絕對路徑只用於**後綴比對**,不會流進 `frFile`
3. `Knot.Extract.ImportScan.scanFile` 的 `path = sfPath sf`(`src/Knot/Extract/ImportScan.hs:77`)、`scanSource` 的 `fmFile = path`(同檔 `97`);而 module 節點的 `gnFile = fmFile`(`Knot.Graph.NodeMint.mintNodes`,`src/Knot/Graph/NodeMint.hs:58`)

三段串起來:`(frFromModule, frFile)` 與 module 節點的 `(gnLabel, gnFile)` **逐字相同**,`byNameFile` 精確命中,消歧組不會落空。**故本 feature 沿用 `sourceNode` 不改**,並在測試裡用「兩個 `Main` + 各自一筆 `frFromDecl = Nothing` 的 ref」釘住這個結論(見 T3)。

`frFromDecl = Just q` 的來源端同理:`qnModule q` 恆等於 `frFromModule`(`refFactsOf` 的 `candidates` 用同一個 `meModule e` 建 `QualName`),而 `q` 所在檔案恆為 `frFile`,故用 `frFile` 過濾 `declNodeIndex` 的候選即可收斂。

### 4. edge-derive:`FactInstance` → `RImplements`

`F002` 已在 edge-derive 為 `RContains` 建立 instance 端點解析;本 feature 在同一支判定裡多產一條邊:

| 步驟 | 條件 | 動作 |
|---|---|---|
| 1 來源解析(規則 4b) | `moduleOfFile` 查不到 `fiInstFile`,或該 module ∉ `gfInternal`,或 `mintInstanceId` 算出的 id 不在節點集合 | 不產 `RImplements`;不計統計;**不另發警告**(`F002` 的 `RContains` 支對同一筆事實已發過,graph-assemble 的 `(gwSource, gwMessage)` 去重會合併;見假設 A4) |
| 2 目標外部判定(規則 1) | `qnModule fiClass` ∉ `gfInternal` | 丟棄、`esDroppedExternal + 1`、累進外部次數表(驗收標準 5 後半) |
| 3 目標解析 | `declNodeIndex` 查 `fiClass` 得 1 筆 | 取該 `NodeId`(class 是 `TypeNs`,節點 id 為 `<mod-id>.<occ>#t`) |
| | 0 筆 / ≥2 筆 | `Skipped`(彙整警告) |
| 4 自環 | `srcId == tgtId` | 丟棄(instance 節點 id 含 `#i:`、class 節點含 `#t`,實務上不可能相等,但判定照跑) |
| 5 產出 | — | `GraphEdge{ geSource = instance 節點, geTarget = class 節點, geRelation = RImplements, geLine = Just fiInstLine }` |

- `fiClass` 的 `qnSpace` 是 `TypeNs`(`src/Knot/Extract/Types.hs:94` 的欄位註解明載),故它在 `declNodeIndex` 裡的鍵就是型別節點的 `QualName`,查得到即代表該 class 在本專案內有頂層宣告
- **A3 裁決的落實**:instance 節點的 `<mod-id>` 由 `fiInstFile` 反查 `FactModule` 取得(`F002` 的 `moduleOfFile`),**不是** `qnModule fiClass`——後者是 class **定義處**的 module。本 feature 只是消費 `F002` 的既有解析,不重新決定

### 5. 警告彙整(驗收標準 6:不靜默)

`Skipped (gwSource, reason)` 以 `Map (Text, Text) Int` 累計,每個相異鍵輸出**一則** `GraphWarning`,訊息尾端帶筆數:

```text
gwSource  = frFile(或 fiInstFile)
gwMessage = <原因,含解析不到的名字> <> "; N ref edge(s) dropped"
```

- **為什麼不逐筆**:imports 的量級是每檔數行,ref 的量級是每檔數百筆。逐筆會淹沒 stderr,也會讓 `--strict` 的訊號完全失去可讀性。`F002` 對 `RContains` 的跳過已採同一作法,本 feature 沿用同一模式
- **決定性**:`Map` 的鍵序即輸出序;筆數是計數不是序列。graph-assemble 既有的 `(gwSource, gwMessage)` 去重與字典序排序原樣適用
- **imports 的逐筆警告一字不改**(契約卡「不改 imports 邊行為」):`Unresolved GraphWarning` 那條路徑完全不動

### 6. 去重、統計與排序:沿用既有機制,零特例

- **去重(規則 5)**:`RCalls` / `RUses` / `RImplements` 的原始邊與 `RImports`(`F001`)、`RContains`(`F002`)進**同一個** `grouped :: Map (NodeId, NodeId, Relation) (Maybe Int, Int)`。鍵含 `Relation`,`Demo.A.f -calls-> Demo.B.g` 與 `Demo.A.f -uses-> Demo.B.g` 不會互相污染;`geLine` 取組內最小 → 驗收標準 4;`esDeduped` 累加
- **統計**:`esDroppedExternal` = 外部丟棄的**邊數**(imports + refs + instances 合計,E4 維持單一計數器);`esTopExternal` 沿用 D4 的「前 10、次數降序、同次數依 module 名字典序」
- **排序(D5)**:`buildGraph` 既有的 `sortOn (geSource, geRelation, geTarget)`;去重後該鍵即全序,不需 `geLine` 參與比較

### 7. `moduleOnly`(規則 6):零改動

`Knot.Graph.isModuleLayer`(`src/Knot/Graph.hs:86-89`)只讓 `FactModule` / `FactImport` 通過,`FactRef` / `FactInstance` 在進 fact-gate 之前就被移除 → 本 feature 的三種邊在 `moduleOnly = True` 時自動全為零,統計也不受影響。**只補測試釘住,不改任何程式碼。**

### 8. 下游消費端:已查證**不需改動**(額外查證 3)

| 下游 | 現況(2026-08-22 讀自來源檔) | 結論 |
|---|---|---|
| `src/Knot/Export/Encode.hs` · `relationText`(`131-136`) | 五個建構子**全部**已有對應:`RCalls → "calls"`、`RUses → "uses"`、`RImplements → "implements"` | **不需改動** |
| `src/Knot/Export/Encode.hs` · `edgeObject`(`109-115`) | `source` / `target` / `relation` / `confidence` / `source_location` 與 relation 無關 | **不需改動** |
| `app/Knot/App/Summary.hs` · `renderGraphSummary` 的 `relText`(`182-186`) | 同樣五個建構子全備 | **不需改動** |
| `src/Knot/Query/Load.hs`(`63-64`) | `dependencyRelations` 已含 `calls` / `uses` / `implements`,`contains` 在 `structuralRelations` | **不需改動**;但**行為會變**:decl 層邊全屬依賴類,`knot query reachable` / `rank` 的結果會從 module 級洗成函式級(這是本 feature 的目的,不是缺陷) |
| `app/Knot/App/Report.hs` · `graphNoteLines` | 逐筆轉載 `cgWarnings`,與內容無關 | **不需改動** |

**寫進回報建議欄、不屬本 feature 的兩點**:(a) `gsTopExternalTargets` 的語意在本 feature 之後實質改變——它從「被 import 最多的外部 module」變成「被引用最多的外部 module」,而 hiedb 回報的是**定義處** module,故 Top-10 會被 `GHC.Internal.*` 佔滿(實測見下表)。E4 已裁定不加欄位,故本 feature 照做,但這是 export-query 摘要呈現面該知道的事;(b) `app/Knot/App/Summary.hs` 的 `renderFactSummary` 對 `FactDecl` / `FactRef` / `FactInstance` 走 `"  ? " <> tshow f` 的 fallback(`133`),`--summary facts` 在有 hiedb 的環境會印出 `Show` 原文——`F002` 已回報過,本 feature 再次遇到,仍不跨子系統改。

### 9. 規模預估(額外查證 4:閘門對帳用)

以 **knot-hs 自身**為樣本,2026-08-22 實測。重現方式(唯讀,索引寫到專案外的暫存目錄):

```text
hiedb -D <tmp>/f003.sqlite index .hie --src-base-dir .
knot extract . --backend auto --db <tmp>/f003.sqlite --summary graph
```

事實流實測值(31 個 module、`includeTests = False`):`FactModule` 31、`FactImport` 254、`FactDecl` 631、`FactRef` 7265、`FactInstance` 0,合計 8181 筆。

| 階段 | 筆數 | 說明 |
|---|---|---|
| `FactRef` 原始 | 7265 | 與 design.md 記載的實測值一致 |
| − `frGenerated = True`(`F002` 規則 3) | −846 | 11.6%,fact-gate 已濾 |
| = 進 edge-derive | **6419** | |
| − 來源 module 非內部(規則 4b) | −0 | auto 模式下恆 0(`frFromModule` 必來自 `FactModule` 涵蓋的檔案) |
| − 目標為外部套件(規則 1) | **−3764** | 58.6%;計入 `esDroppedExternal` |
| = 目標內部 | 2655 | 其中 `ValueNs` 1077 / `TypeNs` 626 / `FieldNs` 589 / `DataConNs` 363 |
| − 目標解析不到 decl 節點 | −0 | 實測 0(所有內部目標都有對應 `FactDecl`) |
| − 自環(遞迴/自我引用,規則 4) | **−548** | 20.6% |
| = 去重前原始邊 | 2107 | |
| − 去重合併(規則 5) | **−525** | |
| = **decl 層邊產出** | **1582** | `RCalls` 1271 + `RUses` 311 + `RImplements` 0 |

其中 **507 條**以 module 節點為源(來自 814 筆 `frFromDecl = Nothing` 的 ref),佔 32%——這條路徑不是邊角案例,漏掉會少掉三分之一的邊。

全圖對帳(F001 + F002 + F003 三層合計):

| 項目 | 預估值 |
|---|---|
| `cgNodes` | **662**(31 module + 631 decl + 0 instance);已實測 631 個 `FactDecl` 鑄出 **631 個相異 id**(無 `DuplicateRecordFields` 型的合併)、31 個 module **無同名碰撞**,故本樣本驗不到 D1 消歧路徑,T1/T3 的消歧斷言只能由手工事實流覆蓋 |
| `cgEdges` | **2299**(86 `imports` + 631 `contains` + 1271 `calls` + 311 `uses` + 0 `implements`) |
| `gsDroppedExternal` | **3930**(166 imports + 3764 refs) |
| `gsTopExternalTargets` | 相異外部 module 116 個;Top-3 = `GHC.Internal.Base` 554 / `Data.Text.Internal` 406 / `GHC.Internal.Classes` 401 |
| `gsFilteredGenerated` | **846** |
| `gsDedupedEdges` | **527**(2 imports + 525 refs + 0 contains) |
| `cgWarnings` | **0**(knot-hs 無同名 module、無解析失敗) |

閘門若實跑出的數字與本表差距超過個位數,先查 `.hie` 是否為同一次 build 的產物(重編後 span 會變、`refs` 筆數隨之變動),再查是不是漏了某個 namespace 分支(C2)。

### 10. 決定性(規則 7 / D5)

- 全程純函數,無 IO、無 `unsafePerformIO`、無時間戳、無 GHC `Unique`
- `declNodeIndex` 的 `Map` 只用於查表;值清單顯式排序
- 警告以 `Map` 鍵序輸出,筆數是計數 → 對事實流重排序不敏感
- 去重的 `geLine` 取極小值(非輸入序第一筆),沿用 `F001` 的既有作法

## 使用到的既有串接介面

(標「來源文檔 = `F002`」的三列是**文檔約定**,`F002` 尚未實作、無法讀原始碼;其餘全部是 2026-08-22 自來源檔案讀出的原文,含行號。`containers` / `base` / `text` 為 GHC 9.14.1 boot libs。)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])` | src/Knot/Graph/EdgeDerive.hs:55 | F001 | 本 feature 的擴充點,簽名**不動** |
| `data EdgeStats = EdgeStats { esDroppedExternal :: Int, esTopExternal :: [(ModuleName, Int)], esDeduped :: Int }` `deriving (Eq, Show)` | src/Knot/Graph/EdgeDerive.hs:35-40 | F001 | 外部丟棄與去重統計;三欄不動(E4) |
| `data Outcome = External ModuleName \| Unresolved GraphWarning \| SelfLoop \| Derived GraphEdge`(`Knot.Graph.EdgeDerive` 私有) | src/Knot/Graph/EdgeDerive.hs:43-47 | F001 | 判定結果的內部型別;本 feature 加一個可彙整的跳過建構子 |
| `sourceNode`(`deriveEdges` 的 where 子句:先查 `byNameFile (moduleText from, file)`,未命中退回「該名恰一個節點」) | src/Knot/Graph/EdgeDerive.hs:104-108 | F001 | **`frFromDecl = Nothing` 的來源解析沿用它**(額外查證 1) |
| `byNameFile :: Map (Text, FilePath) NodeId` / `byName :: Map Text [NodeId]`(同上 where 子句) | src/Knot/Graph/EdgeDerive.hs:61-66 | F001 | module 端點的兩張索引 |
| `grouped :: Map (NodeId, NodeId, Relation) (Maybe Int, Int)`(同上 where 子句,`geLine` 取 `min`) | src/Knot/Graph/EdgeDerive.hs:120-126 | F001 | 規則 5 的去重表,decl 層邊直接進同一張表 |
| `mintModuleId :: ModuleName -> Maybe FilePath -> NodeId` | src/Knot/Graph/NodeMint.hs:32 | F001 | `mintDeclId` 的基底(C3 的「decl 沿用 module 消歧結果」由此保證) |
| `moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)` | src/Knot/Graph/NodeMint.hs:38 | F001 | D1 消歧分組,`declNodeIndex` 與 edge-derive 共用同一份 |
| `mintNodes :: GatedFacts -> [GraphNode]` | src/Knot/Graph/NodeMint.hs:48 | F001 | 節點集合的產出者;本 feature 只消費不改 |
| `data GatedFacts = GatedFacts { gfFacts :: [Fact], gfInternal :: Set ModuleName, gfFiltered :: Int }` `deriving (Eq, Show)` | src/Knot/Graph/FactGate.hs:19-24 | F001 | `gfFacts` 是原料、`gfInternal` 是規則 1 / 4b 的判準 |
| `gateFacts :: ProjectMeta -> [Fact] -> GatedFacts` | src/Knot/Graph/FactGate.hs:32 | F001 | 僅測試路徑呼叫;規則 3 的實作屬 `F002` |
| `data GraphEdge = GraphEdge { geSource :: NodeId, geTarget :: NodeId, geRelation :: Relation, geLine :: Maybe Int }` `deriving (Eq, Show)` | src/Knot/Graph/Types.hs:65-71 | F001 | 三種新邊的容器 |
| `data Relation = RImports \| RCalls \| RUses \| RImplements \| RContains` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:74-75 | F001 | 三個建構子在本 feature 首次產生;`Ord` 建構子序即 D5 排序鍵 |
| `data GraphNode = GraphNode { gnId :: NodeId, gnKind :: NodeKind, gnLabel :: Text, gnFile :: FilePath, gnLine :: Maybe Int }` `deriving (Eq, Show)` | src/Knot/Graph/Types.hs:53-60 | F001 | `deriveEdges` 第二參數的元素;**五個欄位還原不出 `QualName`**,故需 `declNodeIndex` |
| `newtype NodeId = NodeId Text` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:50-51 | F001 | 端點型別;建構子仍**只在 node-mint** 使用 |
| `data NodeKind = ModuleNode \| DeclNode DeclKind \| InstanceNode` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:62-63 | F001 | 索引時區分節點層級 |
| `data GraphWarning = GraphWarning { gwSource :: Text, gwMessage :: Text }` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:86-90 | F001 | 解析失敗的彙整警告 |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | src/Knot/Graph.hs:37 | F001 | 進入點;本 feature **不改動**,只被測試呼叫 |
| `isModuleLayer :: Fact -> Bool`(`Knot.Graph` 私有,只讓 `FactModule` / `FactImport` 通過) | src/Knot/Graph.hs:86-89 | F001 | 規則 6 由它既有成立,本 feature 零改動 |
| `mintDeclId :: QualName -> Maybe FilePath -> NodeId` | (尚未實作) | **F002** | `declNodeIndex` 的候選 id 來源;文檔約定,非程式碼查證 |
| `disambiguate :: Map ModuleName (Set FilePath) -> ModuleName -> FilePath -> Maybe FilePath` | (尚未實作) | **F002** | 把事實的檔案換成 `mintDeclId` 的第二參數;文檔約定 |
| `moduleOfFile :: [Fact] -> Map FilePath ModuleName` | (尚未實作) | **F002** | instance 宣告 module 的反查(A3);文檔約定 |
| `data QualName = QualName { qnModule :: ModuleName, qnOcc :: Text, qnSpace :: NameSpace }` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:57-62 | extraction/F001 | `declNodeIndex` 的鍵(**已查證有 `Ord`**);`qnSpace` 是 C2 的判準 |
| `data NameSpace = ValueNs \| DataConNs \| TypeNs \| FieldNs` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:71-76 | extraction/F001 | C2 的四個顯式分支,無 catch-all |
| `FactRef { frFromModule :: ModuleName, frFromDecl :: Maybe QualName, frTarget :: QualName, frGenerated :: Bool, frFile :: FilePath, frLine :: Int }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:87-92 | extraction/F001 | `RCalls` / `RUses` 的全部原料。**三個名字欄位型別互異**:`frFromModule` 是 `ModuleName`(module 級)、`frFromDecl` 是 `Maybe QualName`(可為空)、`frTarget` 是 `QualName`(必有);`frGenerated` 本 feature **不讀**(C4:已在 fact-gate 濾除) |
| `FactInstance { fiClass :: QualName, fiInstHead :: Text, fiInstFile :: FilePath, fiInstLine :: Int }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:93-96 | extraction/F001 | `RImplements` 的原料;`fiClass` 的 `qnSpace` 是 `TypeNs`(欄位註解明載),**無「宣告 module」欄位**(A3) |
| `FactDecl { fdName :: QualName, fdKind :: DeclKind, fdFile :: FilePath, fdLine :: Int }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:84-86 | extraction/F001 | `declNodeIndex` 的候選來源(鍵 `fdName`、消歧檔 `fdFile`) |
| `FactModule { fmFile :: FilePath, fmModule :: ModuleName }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:79-80 | extraction/F001 | `gfInternal` 與消歧分組的來源;測試事實流的必備前置 |
| `refFactsOf`(`frFromModule = meModule e`、`frFile = meFile e`,取自**同一個** `ModEntry`) | src/Knot/Extract/HiedbFacts.hs:337-354 | extraction/F004 | **額外查證 1 的證據(一)**:`(frFromModule, frFile)` 必然配對 |
| `resolveModuleSource :: [SourceFile] -> ModuleName -> Maybe Text -> Maybe FilePath`(回傳 `sfPath` **原文**) | src/Knot/Extract/HiedbFacts.hs:287-307 | extraction/F004 | **額外查證 1 的證據(二)**:`frFile` 不是 hiedb 的絕對路徑 |
| `qRefs`(`LEFT JOIN decls d ON r.hieFile = d.hieFile AND …`) | src/Knot/Extract/HiedbFacts.hs:190-200 | extraction/F004 | `frFromDecl` 必與 ref 同檔的依據(來源端可用 `frFile` 收斂消歧組) |
| `parseOcc :: Text -> Maybe (Text, NameSpace)`(`z:` 回 `Nothing`) | src/Knot/Extract/HiedbFacts.hs:396-407 | extraction/F004 | 型別變數不會流進本 feature 的依據(C2) |
| `scanSource`(`fmFile = path`,而 `path = sfPath sf`) | src/Knot/Extract/ImportScan.hs:77, 97 | extraction/F002 | **額外查證 1 的證據(三)**:module 節點的 `gnFile` 與 `frFile` 逐字相同(語意相依,不直接呼叫) |
| `newtype ModuleName = ModuleName Text` `deriving (Eq, Ord, Show)` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | `gfInternal` / 外部次數表的鍵型別(已查證有 `Ord`) |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs:65-71 | project-meta/F001 | `sfPath` 的「repo 相對、正斜線」語意是路徑相等比對成立的前提(本 feature 不直接讀 `pmSources`) |
| `Data.Map.Strict.fromListWith :: Ord k => (a -> a -> a) -> [(k, a)] -> Map k a` / `lookup :: Ord k => k -> Map k a -> Maybe a` / `toList :: Map k a -> [(k, a)]` / `findWithDefault :: Ord k => a -> k -> Map k a -> a` | containers(GHC 9.14.1 boot) | - | `declNodeIndex`、警告累計表、既有去重表 |
| `Data.Set.fromList :: Ord a => [a] -> Set a` / `member :: Ord a => a -> Set a -> Bool` / `notMember :: Ord a => a -> Set a -> Bool` | containers(GHC 9.14.1 boot) | - | 節點 id 存在性守門、規則 1 / 4b 的內部判定 |
| `Data.List.sortOn :: Ord b => (a -> b) -> [a] -> [a]` | base-4.22(GHC 9.14.1) | - | `declNodeIndex` 值清單的顯式排序 |
| `Data.Text.pack :: String -> Text` / `Data.Text` 的 `<>` | text(GHC 9.14.1 boot) | - | 警告訊息組裝 |

## 新增的介面

本 feature **不新增任何契約面介面**;所有 Level 2 契約簽名(`deriveEdges`、`EdgeStats`、`buildGraph`、全部 DTO)一字不動。

**`Knot.Graph.NodeMint`**(非契約面 · 唯一的新增,沿用 `F001` 的 `moduleFiles` / `F002` 的 `disambiguate` 既有慣例,haddock 標註非契約面)

```haskell
-- | 非契約面:decl 節點索引,供 edge-derive 把 @FactRef.frTarget@ /
--   @FactInstance.fiClass@ 這種「只有 QualName、沒有檔案線索」的目標換成
--   'NodeId'('GraphNode' 的五個欄位還原不出 @(module, occ, namespace)@)。
--
--   由與 'mintNodes' 相同的輸入建立,且**只收真的鑄出來的節點**
--   (候選 id 必須落在傳入節點集合裡),故「查得到 ⇒ 節點存在」,
--   不會產出懸空端點。
--
--   D1 消歧組下同一個 'QualName' 對到多個節點,故值為清單;附帶的
--   'FilePath' 是該節點的來源檔,供有檔案線索的一端(@frFromDecl@)
--   收斂到唯一節點。值清單依 @(FilePath, NodeId)@ 排序(決定性)。
declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]
```

**簽名不變、語意擴充的既有介面**(不算新增,列出以利對帳):

```haskell
deriveEdges :: GatedFacts -> [GraphNode]
            -> ([GraphEdge], EdgeStats, [GraphWarning])  -- 邊集合含 RCalls / RUses / RImplements
```

**`Knot.Graph`**、**`Knot.Graph.Types`**、**`Knot.Graph.FactGate`**、`knot-hs.cabal`:**無任何新增或改動**。

## TodoList

- [ ] T1: `Knot.Graph.NodeMint` 非契約面 `declNodeIndex`——由 `gfFacts` 的 `FactDecl` 建候選(`mintDeclId fdName (disambiguate files (qnModule fdName) fdFile)`),以傳入節點集合的 `gnId` 守門,值為 `[(FilePath, NodeId)]` 且顯式排序;haddock 標註非契約面  `dep: F002`
- [ ] T2: `Knot.Graph.EdgeDerive` 的 `FactRef` 主線——`Outcome` 加可彙整的跳過建構子;判定鏈「來源內部性(4b)→ 目標外部(規則 1)→ 目標解析 → 來源解析 → 自環(規則 4)→ 產出」;`relationOf` 以四個顯式 pattern 落實 C2(`ValueNs`/`DataConNs`/`FieldNs` → `RCalls`、`TypeNs` → `RUses`,無 catch-all);`geLine = Just frLine`  `dep: T1`
- [ ] T3: `frFromDecl` 兩分支的來源解析——`Just q` 走 `declNodeIndex` 並以 `frFile` 收斂消歧組;`Nothing` 走 `F001` 既有的 `sourceNode frFromModule frFile`(**一字不改**),消歧組由 `(module, 檔案)` 精確索引命中  `dep: T2`
- [ ] T4: `FactInstance` → `RImplements`——來源沿用 `F002` 的 instance 端點解析(`moduleOfFile` → `disambiguate` → `mintInstanceId` → 節點集合驗證),目標走 `declNodeIndex` 查 `fiClass`;外部 class 丟棄並計入 `esDroppedExternal` + 外部次數表;內部但查不到 → 彙整警告  `dep: T2`
- [ ] T5: 警告彙整——跳過理由以 `Map (Text, Text) Int` 累計,每個相異 `(gwSource, 原因)` 輸出一則帶筆數的 `GraphWarning`;`imports` 的逐筆警告路徑**不動**;`Map` 鍵序即輸出序  `dep: T3, T4`
- [ ] T6: 收斂複驗——三種新邊與 `RImports` / `RContains` 共用同一個 `grouped` 去重表(`geLine` 取最小、`esDeduped` 累加、不同 relation 不互相污染);`esDroppedExternal` / `esTopExternal` 涵蓋 ref 與 instance 的外部丟棄(E4 不加欄位);`moduleOnly = True` 時三種邊全為零(規則 6,預期零改動,若實際需改動則記入「實作備註」);D5 排序在五種 relation 下成立  `dep: T5`
- [ ] T7: 決定性與規模對帳——手工 `[Fact]` 事實流(E3:不依賴 hiedb、不讀 `.hie`、不 shell out)驗同輸入兩次結果相等、事實流重排序不改變輸出;hedgehog property 以隨機 decl/ref 事實流驗排序與純函數性;階段閘門另做 knot-hs 自身唯讀實跑,對照「實作方式 › 9」的預估表並把實際值寫入「實作備註」  `dep: T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_decl_node_index | 手工事實流(2 個 module × 數筆 `FactDecl`,含 `Demo.Core.Foo#t` 與 `Demo.Core.Foo` 同名不同 namespace):`declNodeIndex` 對每個 `QualName` 回傳恰 1 筆且 `NodeId` 與 `mintDeclId` 一致;型別與值兩個 `Foo` 是兩個相異鍵、對到兩個相異 id;`qnModule` 非內部的 `FactDecl` **不**進索引;傳入節點集合刻意抽掉某個節點時該鍵消失(釘住「查得到 ⇒ 節點存在」的守門);碰撞組 module 的兩個 `Main.main` 在同一個鍵下有 2 筆、`FilePath` 各自正確且值清單已排序 |
| T2 | test_ref_edges_calls_uses | 手工事實流:`ValueNs` / `DataConNs` / `FieldNs` 三種目標各產一條 `RCalls`、`TypeNs` 目標產一條 `RUses`(驗收標準 1,C2 四個值全覆蓋、無一落空);`geLine == Just frLine`;`geSource` 是 `frFromDecl` 對應的 decl 節點;目標 module 非內部的 ref 不產邊且 `esDroppedExternal` 遞增、該 module 進 `esTopExternal`;來源 module 非內部(規則 4b)的 ref 不產邊且 `esDroppedExternal` **不變**;輸出中不含任何 `RImplements` |
| T3 | test_ref_module_sourced | 手工事實流:`frFromDecl = Nothing` 的 ref 產出的邊 `geSource` 是**來源 module 節點**(驗收標準 2),`geRelation` 仍依 namespace 二分;**消歧組情境**——兩個 `Main`(`app/Main.hs`、`test/Main.hs`)各有一筆 `frFromDecl = Nothing` 的 ref,兩條邊的源分別是 `Main@app/Main.hs` 與 `Main@test/Main.hs`(釘住額外查證 1:靠 `(frFromModule, frFile)` 精確索引而非 module 名單獨判定);`frFromDecl = Just q` 且 `qnModule q` 屬消歧組時,來源以 `frFile` 收斂到正確的那個 decl 節點;`frFromModule` 沒有對應 module 節點的 ref → 0 條邊 + 警告 |
| T4 | test_implements_edges | 手工 `FactInstance` 事實流(C1:端到端恆 0,只能手工驗):class 在內部 → 一條 `RImplements`,`geSource` 是 `<mod-id>#i:<標頭>` 的 instance 節點、`geTarget` 是 `<mod-id>.<class>#t` 的型別節點、`geLine == Just fiInstLine`(驗收標準 5 前半);class 的 module 為外部 → 0 條邊且 `esDroppedExternal` 遞增、該 module 進 `esTopExternal`(驗收標準 5 後半);class module 內部但沒有對應 `FactDecl` → 0 條邊 + 警告;instance 的宣告 module 由 `fiInstFile` 反查(A3)而非 `qnModule fiClass`——以「class 定義在 `Demo.Class`、instance 宣告在 `Demo.Impl`」的事實流釘住 |
| T5 | test_ref_warnings_aggregated | 手工事實流:同一檔的 5 筆解析不到目標的 ref → **1 則**警告、`gwSource` 是該檔路徑、訊息含解析不到的名字與筆數 `5`(驗收標準 6:不靜默、不刷屏);兩個相異檔各自一則;不同原因(目標 0 筆 / 目標 ≥2 筆 / 來源解析不到)各自成鍵不被合併;`imports` 的解析失敗警告仍為**逐筆**格式且訊息含 `import edge dropped at line`(釘住「不改 imports 邊行為」);同一輸入的警告清單對事實流重排序完全相同 |
| T6 | test_decl_edge_dedupe_selfloop | 手工事實流:同一對 decl 之間 4 筆 ref(行號亂序 40/12/25/33)→ 合併為 1 條、`geLine == Just 12`、`esDeduped == 3`(驗收標準 4);遞迴呼叫(`frFromDecl == Just q` 且 `frTarget == q`)不產邊、不計統計、不發警告(驗收標準 3);同一對端點的 `RCalls` 與 `RUses` **不**被誤併(去重鍵含 relation);`RImports` / `RContains` / `RCalls` 三種 relation 混合的事實流下 `cgEdges` 依 `(source, relation, target)` 遞增(D5);同一份事實流以 `moduleOnly = True` 呼叫 `buildGraph` → 邊全為 `RImports`、零 `RCalls` / `RUses` / `RImplements`、`gsFilteredGenerated == 0`(規則 6) |
| T7 | test_decl_edges_deterministic | 全部走手工 `[Fact]`(E3,無 hiedb / 無 `.hie` / 無外部行程):同輸入連續兩次 `buildGraph` 結果 `==`;`Gen.shuffle` 重排事實流後結果 `==`;hedgehog property 隨機生成 module × decl × ref(混四種 namespace、混內部/外部目標、混 `frFromDecl` 有無、含遞迴與重複)→ 邊數 == 「相異非自環 (源, 目標, relation) 三元組數」、`RCalls` 條數 == 目標為三種 term namespace 的相異三元組數、`RUses` 條數 == `TypeNs` 的、`gsDroppedExternal` == 目標外部的 ref 筆數 + 外部 import 筆數、`cgNodes` / `cgEdges` 已排序、每條邊的兩端都在 `cgNodes` 裡(釘住「不產懸空端點」) |

## 待確認假設

- A1: 編排者裁決「node-mint 增設非契約面的索引函式,edge-derive 呼叫它取得 `QualName → NodeId` 的對映」,但未指定索引的確切形狀;而 `F002` 的假設 A8 採的是「edge-derive 直接呼叫 `mintDeclId` / `mintInstanceId` / `mintModuleId` + `Set NodeId` 驗證存在性」→ 採取:**兩者併用**——decl 目標(`frTarget` / `fiClass`,沒有檔案線索)走本 feature 新增的 `declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]`;instance 端點(有 `fiInstFile`)沿用 `F002` 已建立的鑄造+驗證路徑,不另建第二條。索引值帶 `FilePath` 是為了對稱於 `F001` 既有的 `byNameFile` / `byName` 雙索引模式(有線索的一端收斂、沒線索的一端在 >1 時判歧義)→ 影響:若編排者要求單一形狀(例如 `Map QualName NodeId`,消歧組直接不入索引),`declNodeIndex` 與 T3 的來源收斂邏輯要改,`F002` 的 A8 也需一併重裁
- A2: 規則 4b(來源 module 非內部)與規則 1(目標為外部)對同一筆 ref 同時成立時,哪一條優先未明 → 採取:**4b 先判**,該筆完全不產邊、不計 `esDroppedExternal`。依據:4b 的語意是「這筆事實不在圖的範圍內」,先把它算成一次外部丟棄再丟掉,會讓統計把根本不該進圖的事實計進去;且 `--backend hiedb` 單跑時 `gfInternal` 為空(`F002` 假設 A10),4b 先判會讓整批事實走警告,若反過來則專案自己的 module 會整批灌進 `gsTopExternalTargets`,報告完全失真。實測 auto 模式下兩種順序結果相同(knot-hs 自身 4b 命中 0 筆)→ 影響:若裁定規則 1 優先,改 edge-derive 的判定順序一處,`--backend hiedb` 單跑的 `gsTopExternalTargets` 會變成專案自身 module 的清單
- A3: `frTarget` 的 module 屬 D1 消歧組時(例:專案有兩個 `Main`,某個 ref 指向 `Main.main`),無從判定指向組內哪一個節點 → 採取:**丟棄該邊 + 彙整警告,不計 `esDroppedExternal`**,比照 `F001` 假設 A4 對 import 目標的既有裁決與規則 4a 的精神 → 影響:若裁定應對整組每個節點各連一條邊(寧可多報),改目標解析分支;下游 hub 排名會多出偽邊
- A4: instance 的來源端解析失敗(`fiInstFile` 反查不到 module / module 非內部 / instance 節點不存在)時,`F002` 的 `RContains` 支已對**同一筆事實**發過警告,本 feature 是否要再發一則未明 → 採取:**不另發**,只是不產 `RImplements`;理由是 graph-assemble 既有的 `(gwSource, gwMessage)` 去重本來就會合併同文警告,再發只是製造一則語意重複的訊息 → 影響:若要求「每種邊各自可觀測」,在本 feature 加一則訊息不同的警告即可,不動任何契約
- A5: `RImplements` 的 `geLine` 未在契約明定 → 採取:取 `fiInstLine`(instance 宣告行),與 `RCalls` / `RUses` 取 `frLine`、`F002` 的 `RContains` 取 `fdLine` / `fiInstLine` 一致 → 影響:若裁定 `RImplements` 不帶證據行,改為 `Nothing`,`codegraph.json` 的該類邊少一個 `source_location` 欄位
- A6: ref 解析失敗警告的訊息格式未在契約明定,而量級可能是 imports 的數百倍 → 採取:**每個 `(gwSource, 原因)` 一則帶筆數**(`gwSource` = `frFile` / `fiInstFile`),不逐筆;`imports` 的逐筆格式維持不變(契約卡「不改 imports 邊行為」)。這造成同一份 `cgWarnings` 裡兩種粒度並存 → 影響:若要求全體一致,`F001` 的 imports 警告也要改成彙整式,`F001` 的 `test_imports_edges_external` 與 `test_build_graph_assemble` 兩條測試要一併更新
- A7: `gsTopExternalTargets` 的語意在本 feature 之後實質改變——實測 knot-hs 自身 Top-10 全被 `GHC.Internal.Base`(554)/ `Data.Text.Internal`(406)/ `GHC.Internal.Classes`(401)這類**定義處** module 佔滿,而不是使用者寫在 import 行的 `Data.Text`(193)。原因是 hiedb 的 `refs.mod` 是被引用者的定義 module → 採取:**不改**,E4 已裁定 `EdgeStats` / `GraphStats` 維持單一計數器不加欄位,本 feature 照做並在「實作方式 › 8」把這個語意變化寫明 → 影響:若要讓報告仍以「import 目標」為主,需為統計加第二組計數器(**Level 2 契約變更**,與 E4 相衝),或由 export-query 在摘要層分開呈現(**跨子系統,屬 export-query**)
- A8: 契約卡的驗收標準 6 說「目標解析不到內部節點的 ref 彙整為警告」,但沒說**來源**解析不到時要不要警告 → 採取:**一樣彙整為警告**(用不同的原因文字,故不會與目標失敗合併成同一鍵)。依據:`F001` 的 imports 判定鏈對來源解析失敗同樣發警告,兩端對稱才不會有一邊靜默 → 影響:若裁定來源失敗應靜默,拿掉 T3 的最後一條斷言與 T5 的一個鍵
- A9: `--backend hiedb` 單跑時事實流沒有任何 `FactModule`(規則 2 明定那是 import-scan 的唯一職責),`gfInternal` 為空 → 本 feature 的三種邊全部產不出來,且依 A2 全走 4b 警告 → 採取:**不特別處理**,由彙整警告如實呈現;這是 D2 的既有推論(`F002` 假設 A10 已記載),不是本 feature 引入 → 影響:若裁定該模式應可獨立產圖,須放寬 D2(改由 `pmSources.sfModule` 或事實流的 `frFromModule` / `qnModule` 補內部集合),那是 `F001` 契約層級的變更
- A10: 「實作方式 › 9」的規模預估是以**本文檔撰寫時的 `.hie`** 為樣本算出的(2026-08-22,31 個 module、`includeTests = False`)。`.hie` 隨每次重編改變,span 一動 `refs` 筆數就跟著動 → 採取:預估表附上重現指令與樣本條件,閘門對帳時允許個位數差距;差距大時先查 `.hie` 新鮮度,再查 C2 是否漏分支 → 影響:若閘門要求逐筆對齊,需把 `.hie` 產生步驟固定進驗收腳本(屬驗收流程,不動任何契約)

## 實作備註

(撰寫時留空)
