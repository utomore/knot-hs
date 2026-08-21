---
id: F002
type: feature
title: decl-nodes
description: 鑄出 decl/instance 節點與 contains 邊並過濾產生碼
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: [F001, project-meta/F001, extraction/F001, extraction/F004]
related-adr: []
related-feature: []
---

# F002: decl-nodes — decl / instance 節點、`contains` 邊與產生碼過濾

## 功能概述

graph-core 的第二層:把 extraction 的 `FactDecl` / `FactInstance` 事實鑄成 decl / instance 節點,並由所屬 module 拉出 `RContains` 結構邊;同時把階段一刻意留白的**組裝規則 3(產生碼過濾)**填進 fact-gate。本 feature 完成後,`codegraph.json` 從「只有 module 節點」升級為「module + decl 兩層」,`/arch-audit` 的定位加速與 hub 排名才有函式級素材。

**要解決的問題**:事實流的 `FactDecl` 是「`QualName` × 檔案 × 行」的扁平列表,沒有節點身分;而 `QualName` 的 `TypeNs` 與 `ValueNs` 可以同名(`data Foo = Foo` 產生兩個 `Demo.Core.Foo`),多 executable 專案的 `Main.main` 更會整組撞成同一個 id 而在去重時被靜默吞掉。同時 hiedb 的 `refs.is_generated` 事實(實測 knot-hs 自身 846/7265 = 11.6%)與異常 span 若不濾除,會在 decl 之間製造非人為的邊並污染 hub 排名。本 feature 建立這層轉換,並維持「同輸入必同輸出」。

**驗收標準**(契約卡原文):

1. 同名型別與值鑄出不同 id(`Demo.Core.Foo#t` vs `Demo.Core.Foo`)
2. instance 節點 id 含渲染標頭且穩定
3. 指向 `pmSources` 外檔案或行號 ≤ 0 的事實被濾除,且 `gsFilteredGenerated` 計數
4. 每個 decl 節點有一條來自所屬 module 的 `RContains`
5. `moduleOnly = True` 時 decl 節點與 `RContains` 完全不出現

**明確不做**(契約卡底線):不推導 `calls` / `uses` / `implements`(`F003` decl-edges 的事);不改 module 層行為;不嘗試為外部名稱建節點。另承子系統邊界:不讀檔案、不做任何 IO、不認識 `.hie` 或 SQLite、不序列化、不做 span 比對。

**編排者對契約卡內部張力的裁示(已納入本文檔)**:契約卡的「負責模組」只列 fact-gate、node-mint,但同一張卡要求產出 `RContains`,而 design.md「內部模組劃分」把「邊推導(規則 2)」歸給 **edge-derive**。以模組職責表為準:所有邊一律由 edge-derive 產出,故本 feature **會**修改 `src/Knot/Graph/EdgeDerive.hs` 的 `RContains` 部分,但**不**在其中實作 `RCalls` / `RUses` / `RImplements`。

**批次澄清 C1 的落實方式**:`FactInstance` 目前**無任何後端產出**(extraction C4:hiedb 0.8 的 schema 無 instance 表)。本 feature 仍**完整實作** instance 節點鑄造路徑,以手工事實流驗收;端到端輸出恆 0 個 instance 節點是預期行為,不是缺陷。ADR-002 預留的第三後端上線時零改動即生效。

## 相依性

`depends-on: [F001, project-meta/F001, extraction/F001, extraction/F004]`,四條全部由「使用到的既有串接介面」表反推,且四份文檔皆為 `status: done`、程式碼已在 `main`,故**全部是既有程式碼查證**(2026-08-22 自來源檔逐行讀出原文),沒有任何一條是文檔約定:

- **`F001`(module-graph,同子系統)**:本 feature 直接改寫它建立的四個內部模組。使用面涵蓋全部對外 DTO(`CodeGraph` / `GraphNode` / `NodeKind` / `GraphEdge` / `Relation` / `GraphStats` / `GraphWarning` / `NodeId` / `BuildOptions`)、模組介面(`gateFacts` / `GatedFacts` / `mintModuleId` / `mintNodes` / `deriveEdges` / `EdgeStats`)、非契約面 `moduleFiles`,以及 `buildGraph` 的規則 6 窄化與規則 7 排序。**序列相依**:必須排在 `F001` 之後
- **`project-meta/F001`(scan-baseline,跨子系統)**:規則 3 的 (a) 條件要拿 `pmSources` 的 `sfPath` 比對(路徑語意「repo 相對、正斜線」出自此文檔);`ModuleName` 是內部集合與消歧表的鍵型別(已查證有 `Ord`)
- **`extraction/F001`(fact-contract,跨子系統)**:`FactDecl` / `FactInstance` 的欄位名與型別、`QualName`(`qnModule` / `qnOcc` / `qnSpace`)、`NameSpace` 四個建構子(`#t` 後綴的判準)、`DeclKind`(`DeclNode` 的參數)
- **`extraction/F004`(hiedb-facts,跨子系統)**:規則 3 的 (c) 條件讀的 `FactRef.frGenerated` 欄位**由本文檔加入 `Fact`**(git 查證:commit `e366fba` 於 `src/Knot/Extract/Types.hs:91` 新增);另 `fdFile` 的填值語意(`resolveModuleSource` 回傳 `sfPath` **原文**,與 import-scan 的 `fmFile` 逐字相同)也出自此文檔,是 (a) 條件能用字串相等比對的依據

未列入的相依與理由:

- **`extraction/F002`(import-scan)**:`F001` 因「T7/T8 需要真實非空事實流」列它為資料相依;本 feature 依委派決策 **E3** 一律用手工 `[Fact]` 事實流測試,不呼叫 `extract`、不讀 `.hie`、不 shell out,故無此相依。(`F001` 既有的兩條端到端測試仍會跑到 import-scan,但那是 `F001` 的相依,不是本 feature 新增的)
- **`extraction/F003`(hiedb-driver)**:本 feature 完全不觸碰索引路徑
- **`project-meta/F002` / `F003`**:只改變 `sfIncluded` / `sfOwners` / `pmHie` 的填值語意,不改型別;規則 3 讀的是 `sfPath`,不受影響
- **`export-query` 各 feature**:單向資料流的下游,本 feature 不呼叫它(下游不需改動的查證見「實作方式 › 7」)
- **graph-core `F003`**:方向相反(它依賴本 feature 產出的節點集合與規則 3 的過濾結果)

可平行性:**不可**與 graph-core `F003` 平行(`F003` 的契約卡明載「節點集合由 decl-nodes 給定」);可與其他子系統的任務平行。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/graph-core/design.md`(2026-08-22 版),無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| 鑄造規則表 · 值宣告列 `<mod-id>.<occ>` | `mintDeclId`;`<occ>` 涵蓋 `ValueNs` / `DataConNs` / `FieldNs` 三個 term-level namespace(C2) |
| 鑄造規則表 · 型別宣告列 `<mod-id>.<occ>#t` | `mintDeclId`;`#t` **只對 `TypeNs`**(C2) |
| 鑄造規則表 · instance 列 `<mod-id>#i:<instance 標頭>` | `mintInstanceId`;標頭取 `FactInstance.fiInstHead` 原文 |
| `<mod-id>` = 該 module 節點實際鑄出的 id(C3) | `mintDeclId` / `mintInstanceId` 的 `Maybe FilePath` 語意同 `mintModuleId`:`Nothing` = 該 module 未碰撞鑄裸名、`Just file` = 碰撞組成員;消歧判定沿用 `F001` 的 `moduleFiles`(`FactModule.fmFile` 相異數 > 1) |
| 模組介面 `mintDeclId :: QualName -> Maybe FilePath -> NodeId` | `Knot.Graph.NodeMint`,簽名一字不差 |
| 模組介面 `mintInstanceId :: ModuleName -> Maybe FilePath -> Text -> NodeId` | `Knot.Graph.NodeMint`,簽名一字不差 |
| 模組介面 `mintNodes :: GatedFacts -> [GraphNode]` | 簽名**不變**,回傳值擴充為三種 `NodeKind` |
| 模組介面 `gateFacts :: ProjectMeta -> [Fact] -> GatedFacts` | 簽名**不變**;`ProjectMeta` 參數由「不讀取」改為讀 `pmSources`(填掉 `F001` 假設 A6 的留白) |
| 模組介面 `deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])` | 簽名**不變**;新增 `RContains` 推導與其解析失敗警告 |
| DTO `NodeKind` 的 `DeclNode DeclKind` / `InstanceNode` | 由「先行定義、零邏輯」轉為實際產生(`DeclNode` 的參數取 `FactDecl.fdKind` 原值) |
| DTO `Relation` 的 `RContains` | 由「先行定義、零邏輯」轉為實際產生 |
| 組裝規則 2 · `FactDecl` 列 | decl 節點 + `RContains`(module → decl) |
| 組裝規則 2 · `FactInstance` 列(節點與 `RContains` 部分) | instance 節點 + `RContains`(module → instance);同列的 `RImplements` **屬 `F003`,不做** |
| 組裝規則 3(產生碼過濾,C4 三條件) | fact-gate:(a) 事實指向的檔案不在 `pmSources`、(b) 行號 ≤ 0、(c) `FactRef.frGenerated = True`,任一成立即濾除並計入 `gfFiltered` → `gsFilteredGenerated`。(c) 只存在於 `FactRef`(`F003` 的原料),但實作在本 feature 的 fact-gate,`F003` 直接受惠 |
| 組裝規則 6(`moduleOnly`) | `buildGraph` 既有的事實窄化即足(decl 層事實在進 fact-gate 前就被移除 → decl 節點、`RContains` 與 `gfFiltered` 全部為零);本 feature 只補測試釘住 |
| 組裝規則 1(內部才實化) | 只為 `qnModule ∈ gfInternal` 且所屬 module 節點存在的宣告建節點;非內部的 decl / instance 事實不建節點、不產邊(統計處理見假設 A4) |
| 組裝規則 5(去重)、規則 7(決定性) | `RContains` 沿用 edge-derive 既有的去重與排序機制,無特例;decl 節點依 `gnId` 去重(`nubOrdOn`) |
| 組裝規則 2 的 `FactRef` 三列、規則 4a | **不觸碰**(`F003` 的範圍;規則 4a 是 import 邊的事) |
| 對外契約 `buildGraph` 簽名、`BuildOptions` / `CodeGraph` / `GraphStats` 欄位 | **完全不動** |

超出 Level 2 契約的部分:**無**。撰寫時發現的契約**缺口**(不是偏離)記在「待確認假設」,其中 A3(`FactInstance` 沒有「宣告 module」欄位)與 A8(edge-derive 如何取得 decl 節點 id)是需要編排者裁決的兩處;兩者本文檔都採取了「零契約變更」的作法繼續推進。

## 實作方式

### 模組配置(全部是既有檔案的擴充,不新增 module)

```text
src/Knot/Graph/FactGate.hs     -- 規則 3 三條件過濾 + gfFiltered 計數
src/Knot/Graph/NodeMint.hs     -- mintDeclId / mintInstanceId;mintNodes 擴充為三種節點
src/Knot/Graph/EdgeDerive.hs   -- 新增 RContains 推導(RCalls/RUses/RImplements 仍不做)
test/Main.hs                   -- 新增 graph-core/F002 group;更新受影響的 F001 測試
```

`knot-hs.cabal` **完全不動**(無新 module、無新依賴);`version` 依 D6 凍結為 `0.0.1.0`。測試 group 命名 `graph-core/F002 decl-nodes`。依 **E2**:新增程式碼在 `-Wall` 下不得產生任何新警告;`test/Main.hs` 既有的 8 筆警告(G-E002 追蹤)**不修**。

### 管線總覽(粗體為本 feature 的改動點)

```text
BuildOptions + ProjectMeta + ExtractResult
   │ erFacts
   ▼
 moduleOnly 窄化(規則 6,既有):True → 只留 FactModule / FactImport
   ▼
 gateFacts pm facts ──▶ GatedFacts{ gfFacts = 通過規則 3 者, gfInternal, **gfFiltered = 濾除數** }
   │
   ▼
 mintNodes gated ──▶ [GraphNode]  = module 節點(既有) ++ **decl 節點** ++ **instance 節點**
   │
   ▼
 deriveEdges gated nodes ──▶ ([GraphEdge], EdgeStats, [GraphWarning])
   │                            = RImports(既有) ++ **RContains**
   ▼
 graph-assemble(既有):gsFilteredGenerated ← gfFiltered;統計/警告彙整;D5 排序
   ▼
 CodeGraph
```

### 1. fact-gate:組裝規則 3(C4 三條件)

```text
srcSet = Set.fromList [ sfPath sf | sf <- pmSources pm ]

filteredOut FactModule{}   = False                      -- module 層不受規則 3 影響(假設 A1)
filteredOut FactImport{}   = False
filteredOut FactDecl{..}     = fdFile     `Set.notMember` srcSet || fdLine     <= 0
filteredOut FactInstance{..} = fiInstFile `Set.notMember` srcSet || fiInstLine <= 0
filteredOut FactRef{..}      = frFile     `Set.notMember` srcSet || frLine     <= 0 || frGenerated

gfFacts    = filter (not . filteredOut) facts
gfInternal = Set.fromList [ fmModule f | f@FactModule{} <- gfFacts ]   -- D2,語意不變
gfFiltered = length facts - length gfFacts
```

- **(a) 條件的路徑比對語意(已查證,不假設)**:`FactDecl.fdFile` 來自 `Knot.Extract.HiedbFacts.resolveModuleSource`,其 haddock 與實作明載回傳的是 **`sfPath` 原文**(「與 import-scan 的 `fmFile` 逐字相同」);`FactModule.fmFile` 來自 `Knot.Extract.ImportScan.scanFile` 的 `path = sfPath sf`,同樣是原文。兩者都不經 `makeAbsolute` / `canonicalizePath`(hiedb 的 Windows 反斜線絕對路徑 `mods.hs_src` 只用於**後綴比對**,不會流進 `fdFile`)。因此 (a) 用**字串完全相等**比對即可,**不做**大小寫折疊、不做斜線轉換、不做相對錨點運算——加正規化反而會掩蓋真正的不一致
- **比對母體**:`pmSources` **全部**條目的 `sfPath`,不限 `sfIncluded = True`(見假設 A2)。注意 `Knot.App.Run.runExtractCmd` 傳給 `buildGraph` 的是**未窄化**的 `pm`,而 extraction 內部才由 `Knot.Extract.Backend.narrowScope` 窄化為 `sfIncluded = True` 的子集——故端到端下 (a) 條件恆不成立,它是防禦性過濾;真正會觸發的是手工事實流與未來的第三後端
- **(c) 條件只出現在 `FactRef`**:`frGenerated` 是 `FactRef` 專屬欄位(已讀 `src/Knot/Extract/Types.hs:87-92` 確認),`FactDecl` / `FactInstance` 沒有對應欄位,不得臆造
- 三條件**任一成立即濾除**,計數是「濾掉的事實筆數」(不是條件命中次數;一筆同時違反兩條件只算一次)

### 2. node-mint:鑄造規則表全表

契約面兩個新函式:

```text
mintDeclId (QualName m occ ns) mf
  = NodeId (modText <> "." <> occ <> suffix)
  where NodeId modText = mintModuleId m mf
        suffix = if ns == TypeNs then "#t" else ""      -- C2:只有 TypeNs 有後綴

mintInstanceId m mf head
  = NodeId (modText <> "#i:" <> head)
  where NodeId modText = mintModuleId m mf
```

兩者都以 `mintModuleId` 為基底,**結構性保證** C3 的「decl 層沿用所屬 module 的消歧結果」:module 未碰撞 → `Demo.Core.render`;碰撞組 → `Main@app/Main.hs.main`。

非契約面新增兩個小工具(沿用 `F001` 匯出 `moduleFiles` 的先例,haddock 標註非契約面):

```text
-- 消歧判定(F001 的 mintNodes 內部 where 子句提升為可共用函式)
disambiguate :: Map ModuleName (Set FilePath) -> ModuleName -> FilePath -> Maybe FilePath
disambiguate files m file
  | maybe False ((> 1) . Set.size) (Map.lookup m files) = Just file
  | otherwise                                           = Nothing

-- 檔案 → 該檔宣告的 module(FactInstance 沒有 module 欄位,只能反查;假設 A3)
moduleOfFile :: [Fact] -> Map FilePath ModuleName
moduleOfFile facts = Map.fromList [ (fmFile f, fmModule f) | f@FactModule{} <- facts ]
```

### 3. node-mint:`mintNodes` 擴充為三種節點

```text
files     = moduleFiles (gfFacts gated)              -- 既有
fileMods  = moduleOfFile (gfFacts gated)
modNodes  = <F001 既有邏輯,一字不改>
modIds    = Set.fromList (map gnId modNodes)         -- 存在性守門
```

| 事實 | 條件 | 產出節點 |
|---|---|---|
| `FactDecl` | `qnModule fdName ∈ gfInternal` **且** `mintModuleId m disamb ∈ modIds` | `gnId = mintDeclId fdName disamb`、`gnKind = DeclNode fdKind`、`gnLabel = qnOcc fdName`、`gnFile = fdFile`、`gnLine = Just fdLine` |
| `FactInstance` | `Map.lookup fiInstFile fileMods = Just m`、`m ∈ gfInternal` 且 `mintModuleId m disamb ∈ modIds` | `gnId = mintInstanceId m disamb fiInstHead`、`gnKind = InstanceNode`、`gnLabel = fiInstHead`、`gnFile = fiInstFile`、`gnLine = Just fiInstLine` |
| 其他 | — | 不產節點(不 crash) |

其中 `disamb = disambiguate files m <該事實的檔案>`。

- **`gnLabel` 取 occ 名 / instance 標頭**:契約原文「人類可讀名(module 名 / occ 名 / instance 標頭)」;消歧與 `#t` 後綴只反映在 `gnId`(比照 `F001` 假設 A5 對 module 節點的處理)
- **存在性守門(`modIds`)的用意**:保證每個 decl 節點的所屬 module 節點一定存在,`RContains` 不會產生懸空端點;沒有它,「`fdFile` 不屬於該 module 任何 `fmFile`」的病態輸入會鑄出孤兒節點
- 最後對**全部**節點依 `gnId` 去重(既有的 `nubOrdOn gnId` 涵蓋三種節點)。`DuplicateRecordFields` 下同 module 兩個同名欄位選擇器會在此合併——這是 design.md 明載、繼承自 extraction 假設 A9 的精度限制,**不補救、不猜測**(見假設 A9)
- 節點輸出順序在 node-mint 內不重要:`buildGraph` 的規則 7 會依 `gnId` 全序排序

### 4. edge-derive:`RContains` 推導

edge-derive 既有的 `FactImport` → `RImports` 判定鏈**一字不改**;新增一條平行的 decl 層判定鏈,兩者的原始邊在同一個去重表(規則 5)裡收斂,`(source, target, relation)` 三元組已含 relation,不會互相污染。

逐筆判定(`files` / `fileMods` 由 node-mint 的非契約面工具取得,與 node-mint 用同一份輸入 → 判定必然一致):

| 事實 | 步驟 | 動作 |
|---|---|---|
| `FactDecl` | module 非內部,或 `mintModuleId` / `mintDeclId` 算出的 id 不在節點集合 | 不產邊;**不**計入 `esDroppedExternal`;彙整為警告(假設 A4) |
| | 兩端都在節點集合 | `GraphEdge{ geSource = 模組節點 id, geTarget = decl 節點 id, geRelation = RContains, geLine = Just fdLine }` |
| `FactInstance` | `fiInstFile` 查不到 module,或 module 非內部,或 id 不在節點集合 | 同上:不產邊、不計統計、彙整為警告 |
| | 都通過 | `GraphEdge{ …, geRelation = RContains, geLine = Just fiInstLine }`(假設 A5) |

- **端點 id 的取得方式**:呼叫 node-mint 的 `mintDeclId` / `mintInstanceId` / `mintModuleId`,再以 `Set NodeId`(由傳入的 `[GraphNode]` 建立)驗證存在性。`NodeId` 建構子仍**只在 node-mint 使用**,符合 Level 2「`NodeId` 的唯一構造入口在 node-mint」;`F001` haddock 那句「edge-derive 不鑄造任何 id」是 `F001` 的階段性自我約束(module 節點可用 `(gnLabel, gnFile)` 索引反查),decl 節點的 `(module, occ, namespace)` 三元組**無法**從 `GraphNode` 的五個欄位還原,故此處改為呼叫鑄造函式(見假設 A8)
- **警告彙整**:以 `Map ModuleName Int`(instance 路徑另以 `Map FilePath Int`)累計跳過筆數,每個相異來源輸出**一則** `GraphWarning`(`gwSource` = module 名或檔案路徑、訊息含筆數),避免逐筆刷屏;`Map` 的鍵序即決定性順序。graph-assemble 既有的 `(gwSource, gwMessage)` 去重與排序原樣適用
- **自環(規則 4)**:`RContains` 的兩端一個是 module 節點、一個是 decl / instance 節點,id 必不相同(decl id 恆多一個 `.` 或 `#i:` 尾段),既有的自環檢查照跑但恆不觸發
- **去重(規則 5)**:同一 `(module, decl)` 的重複 `FactDecl` 合併為一條、`geLine` 取最小,計入 `esDeduped` — 與 imports 邊完全同一套程式碼路徑,無特例

### 5. graph-assemble:不需改動

`buildGraph` 的四件事在 `F001` 已經到位,本 feature **一行都不改**:

- 規則 6 的事實窄化(`isModuleLayer`)已把 `FactDecl` / `FactRef` / `FactInstance` 排除在 `moduleOnly = True` 之外 → decl 節點、`RContains` 與 `gfFiltered` 自動全為零(驗收標準 5 與規則 6 的「不計入統計」同時成立)
- `gsFilteredGenerated = gfFiltered gated` 的接線已存在,規則 3 一實作就自動有值(驗收標準 3)
- 規則 7 的 `sortOn gnId` / `sortOn (geSource, geRelation, geTarget)` 對三種節點與兩種 relation 一體適用(`Relation` 的 `Ord` 建構子序 `RImports < RCalls < RUses < RImplements < RContains` 已 derive)
- 警告彙整與去重照舊

### 6. `F001` 既有測試的對帳(必做,見假設 A6)

規則 3 生效後,`F001` 三條測試的前提改變。**不刪除任何測試**,只更新到新行為:

| 既有測試 | 現況 | 更新後 |
|---|---|---|
| `test_gate_facts` | 用 `ghostMeta`(`pmSources` 只有 `src/Ghost.hs`)斷言 `gfFacts == 輸入`、`gfFiltered == 0`,其中含一筆 `src/Demo/Core.hs` 的 `FactDecl` | 該 `FactDecl` 現在會被 (a) 條件濾除 → 改為斷言「module 層事實原樣通過、該 `FactDecl` 被濾除、`gfFiltered == 1`」,並另用一個涵蓋該檔的 `ProjectMeta` 斷言「檔案在 `pmSources` 時 `FactDecl` 通過」 |
| `test_mint_module_nodes` | 用 `emptyMeta`(`pmSources = []`)驗「`FactDecl` 不產節點」 | 該結論現在成立的理由變成「被規則 3 濾掉」而非「node-mint 略過」→ 改用涵蓋該檔的 `ProjectMeta`,讓 `FactDecl` 通過閘門,斷言 module 節點清單**不變**(decl 節點另由 `F002` 的測試涵蓋),保持測試意圖 |
| `test_build_graph_assemble` | 斷言 `gsFilteredGenerated == 0` 且 `moduleOnly = True` 的輸出與 `False` **完全相同**(`F001` 驗收標準 5 原文即註明「尚無 decl 事實」) | 這條斷言已被本 feature 取代:改為以涵蓋 `assembleFacts` 各檔的 `ProjectMeta` 斷言 `moduleOnly = False` 時多出 1 個 decl 節點 + 1 條 `RContains`、`moduleOnly = True` 時回到 `F001` 的原輸出且 `gsFilteredGenerated == 0` |

`test_build_graph_deterministic` 的兩條端到端子測試與 hedgehog property **不受影響**(已查證:`test/fixtures/proj` 與 `test/fixtures/graph` 都沒有 `.hie` 目錄,`probeHiedb` 必回 `Unavailable`「hie files unavailable」→ 事實流只有 module 層;property 也只生成 module 層事實)。

### 7. 下游消費端:已查證**不需改動**(額外查證要求 1)

| 下游 | 現況 | 結論 |
|---|---|---|
| `src/Knot/Export/Encode.hs` · `nodeObject` | 輸出 `id` / `label` / `source_file`,`sourceLocation (gnLine n)` 在 `Just` 時輸出 `source_location: "L<行>"`;`gnKind` 刻意不輸出 | decl 節點的 `gnLine = Just fdLine` 會自動帶出 `source_location`,**不需改動** |
| `src/Knot/Export/Encode.hs` · `relationText` | `RContains → "contains"` 已存在(ADR-003 的結構類 relation) | **不需改動** |
| `app/Knot/App/Summary.hs` · `renderGraphSummary` | `kindText (DeclNode k) = "decl:" <> tshow k`、`kindText InstanceNode = "instance"` 已存在 | **不需改動** |
| `app/Knot/App/Report.hs` · `graphNoteLines` | 逐筆轉載 `cgWarnings`,與警告內容無關 | **不需改動** |
| `src/Knot/Query/*` | `contains` 屬結構類 relation,查詢只走依賴類邊;載入端對未知 relation 已有統計通道 | **不需改動** |

(順帶查到、**不屬本 feature**:`app/Knot/App/Summary.hs` 的 `renderFactSummary` 對 `FactDecl` / `FactRef` / `FactInstance` 走 `factLine f = "  ? " <> tshow f` 的 fallback,`--summary facts` 在有 hiedb 的環境下會印出 `Show` 原文。這是 export-query/CLI 組裝層的呈現問題,已寫進回報建議欄,本 feature 不跨子系統改。)

### 8. 決定性(規則 7 / D5)

- 全程純函數,無 IO、無 `unsafePerformIO`、無時間戳、無 GHC `Unique`
- 新增的 `Map` / `Set`(`srcSet`、`fileMods`、警告累計表)只用於查表與累加;所有輸出一律經明確排序產生
- 警告的筆數彙整以 `Map` 鍵序輸出,對事實流重排序不敏感
- `gfFiltered` 是筆數差,與事實序無關

## 使用到的既有串接介面

(全部簽名為 2026-08-22 自來源檔案讀出的原文,含行號;`containers` / `base` / `text` 為 GHC 9.14.1 boot libs)

**下游消費端不列在本表**:`Knot.Export.Encode` 的 `nodeObject` / `relationText` 與 `Knot.App.Summary` 的 `renderGraphSummary` 都已查證**不需改動**,且本 feature **不呼叫**它們(單向資料流的下游);簽名與查證結論見「實作方式 › 7」,不構成 `depends-on`(比照 `F001` 排除 export-query 的既有判準)。

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | src/Knot/Meta/Types.hs:29-35 | project-meta/F001 | 規則 3 的 (a) 條件由 `pmSources` 取比對母體 |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs:65-71 | project-meta/F001 | `sfPath`(repo 相對、正斜線)是 (a) 條件的比對值;`sfIncluded` **不**用於本 feature(假設 A2) |
| `newtype ModuleName = ModuleName Text` `deriving (Eq, Ord, Show)` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | 消歧表、`fileMods`、警告累計表的鍵型別(已查證有 `Ord`) |
| `data QualName = QualName { qnModule :: ModuleName, qnOcc :: Text, qnSpace :: NameSpace }` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:57-62 | extraction/F001 | `mintDeclId` 的輸入:`qnModule` 決定 `<mod-id>`、`qnOcc` 是 `<occ>`、`qnSpace` 決定 `#t` |
| `data NameSpace = ValueNs \| DataConNs \| TypeNs \| FieldNs` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:71-76 | extraction/F001 | C2 的判準:只有 `TypeNs` 加 `#t`,其餘三者共用無後綴形式 |
| `FactDecl { fdName :: QualName, fdKind :: DeclKind, fdFile :: FilePath, fdLine :: Int }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:84-86 | extraction/F001 | decl 節點的全部原料;`fdLine` 同時是 `gnLine` 與 `RContains` 的 `geLine` |
| `FactInstance { fiClass :: QualName, fiInstHead :: Text, fiInstFile :: FilePath, fiInstLine :: Int }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:93-96 | extraction/F001 | instance 節點的原料;**無「宣告 module」欄位**(假設 A3);`fiClass` 是 `F003` 的 `RImplements` 目標,本 feature 不讀 |
| `FactRef { frFromModule :: ModuleName, frFromDecl :: Maybe QualName, frTarget :: QualName, frGenerated :: Bool, frFile :: FilePath, frLine :: Int }`(`Fact` 的建構子) | src/Knot/Extract/Types.hs:87-92 | extraction/F004 | 規則 3 的三條件對它全部適用;`frGenerated` 是 (c) 條件的唯一來源(git 查證由 commit `e366fba` 加入) |
| `data DeclKind = ValueDecl \| DataDecl \| ClassDecl \| InstanceDecl \| TypeSynDecl \| PatSynDecl \| FamilyDecl` `deriving (Eq, Ord, Show)` | src/Knot/Extract/Types.hs:99-102 | extraction/F001 | `DeclNode DeclKind` 的參數,取 `fdKind` 原值 |
| `resolveModuleSource :: [SourceFile] -> ModuleName -> Maybe Text -> Maybe FilePath`(回傳 `sfPath` **原文**) | src/Knot/Extract/HiedbFacts.hs:287-307 | extraction/F004 | **(a) 條件可用字串相等比對的依據**:`fdFile = meFile e` 即此函式回傳的 `sfPath` 原文,不是 hiedb 的反斜線絕對路徑 |
| `gateFacts :: ProjectMeta -> [Fact] -> GatedFacts` | src/Knot/Graph/FactGate.hs:32 | F001 | 本 feature 在此實作規則 3(簽名不變) |
| `data GatedFacts = GatedFacts { gfFacts :: [Fact], gfInternal :: Set ModuleName, gfFiltered :: Int }` `deriving (Eq, Show)` | src/Knot/Graph/FactGate.hs:19-24 | F001 | `gfFacts` 改為過濾後結果、`gfFiltered` 改為實際筆數(欄位與型別不變) |
| `mintModuleId :: ModuleName -> Maybe FilePath -> NodeId` | src/Knot/Graph/NodeMint.hs:32 | F001 | `mintDeclId` / `mintInstanceId` 的基底(C3 的「沿用 module 消歧結果」由此結構性保證) |
| `moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)` | src/Knot/Graph/NodeMint.hs:38 | F001 | D1 消歧判定的既有非契約面入口,decl 層沿用同一份分組 |
| `mintNodes :: GatedFacts -> [GraphNode]` | src/Knot/Graph/NodeMint.hs:48 | F001 | 擴充為產出三種節點(簽名不變) |
| `deriveEdges :: GatedFacts -> [GraphNode] -> ([GraphEdge], EdgeStats, [GraphWarning])` | src/Knot/Graph/EdgeDerive.hs:55 | F001 | 新增 `RContains` 推導與其警告(簽名不變) |
| `data EdgeStats = EdgeStats { esDroppedExternal :: Int, esTopExternal :: [(ModuleName, Int)], esDeduped :: Int }` `deriving (Eq, Show)` | src/Knot/Graph/EdgeDerive.hs:35-40 | F001 | `esDeduped` 涵蓋 `RContains` 的去重;`esDroppedExternal` 維持單一計數器不加欄位(E4) |
| `buildGraph :: BuildOptions -> ProjectMeta -> ExtractResult -> CodeGraph` | src/Knot/Graph.hs:37 | F001 | 進入點;本 feature **不改動**,只被測試呼叫 |
| `isModuleLayer :: Fact -> Bool`(`Knot.Graph` 私有) | src/Knot/Graph.hs:86-89 | F001 | 規則 6 的既有窄化;驗收標準 5 直接由它成立 |
| `data GraphNode = GraphNode { gnId :: NodeId, gnKind :: NodeKind, gnLabel :: Text, gnFile :: FilePath, gnLine :: Maybe Int }` `deriving (Eq, Show)` | src/Knot/Graph/Types.hs:53-60 | F001 | decl / instance 節點的容器;`gnLine` 首次有值 |
| `data NodeKind = ModuleNode \| DeclNode DeclKind \| InstanceNode` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:62-63 | F001 | 兩個先行定義的建構子在本 feature 首次產生 |
| `data GraphEdge = GraphEdge { geSource :: NodeId, geTarget :: NodeId, geRelation :: Relation, geLine :: Maybe Int }` `deriving (Eq, Show)` | src/Knot/Graph/Types.hs:65-71 | F001 | `RContains` 邊的容器 |
| `data Relation = RImports \| RCalls \| RUses \| RImplements \| RContains` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:74-75 | F001 | `RContains` 在本 feature 首次產生;`Ord` 建構子序即 D5 排序鍵 |
| `newtype NodeId = NodeId Text` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:50-51 | F001 | 鑄造結果;建構子仍只在 node-mint 使用 |
| `data GraphWarning = GraphWarning { gwSource :: Text, gwMessage :: Text }` `deriving (Eq, Ord, Show)` | src/Knot/Graph/Types.hs:86-90 | F001 | decl / instance 跳過的彙整警告 |
| `data GraphStats = GraphStats { gsDroppedExternal :: Int, gsTopExternalTargets :: [(ModuleName, Int)], gsFilteredGenerated :: Int, gsDedupedEdges :: Int }` `deriving (Eq, Show)` | src/Knot/Graph/Types.hs:77-83 | F001 | `gsFilteredGenerated` 在本 feature 首次非零 |
| `Data.Set.fromList :: Ord a => [a] -> Set a` / `Data.Set.notMember :: Ord a => a -> Set a -> Bool` / `Data.Set.member :: Ord a => a -> Set a -> Bool` / `Data.Set.size :: Set a -> Int` | containers(GHC 9.14.1 boot) | - | `srcSet`、`modIds`、內部集合判定、消歧判定 |
| `Data.Map.Strict.fromList :: Ord k => [(k, a)] -> Map k a` / `Data.Map.Strict.fromListWith :: Ord k => (a -> a -> a) -> [(k, a)] -> Map k a` / `Data.Map.Strict.lookup :: Ord k => k -> Map k a -> Maybe a` / `Data.Map.Strict.toList :: Map k a -> [(k, a)]` | containers(GHC 9.14.1 boot) | - | `fileMods`、警告累計表、既有消歧表 |
| `Data.Containers.ListUtils.nubOrdOn :: Ord b => (a -> b) -> [a] -> [a]` | containers(GHC 9.14.1 boot) | - | 三種節點統一依 `gnId` 去重 |
| `Data.List.sortOn :: Ord b => (a -> b) -> [a] -> [a]` | base-4.22(GHC 9.14.1) | - | 既有的 D5 排序(本 feature 不改) |
| `Data.Text.pack :: String -> Text` / `Data.Text.singleton :: Char -> Text` / `Data.Text` 的 `<>` | text(GHC 9.14.1 boot) | - | id 組字(`.` / `#t` / `#i:`)與警告訊息組裝 |

## 新增的介面

全部落在 Level 2 契約內;非契約面的匯出一律以 haddock 標註(沿用 `F001` 對 `moduleFiles` 的既有慣例)。

**`Knot.Graph.NodeMint`**(契約面 · 鑄造規則表的其餘兩列)

```haskell
-- | decl 節點 id 鑄造(C3 裁決的契約簽名)。
--   Maybe FilePath 語意同 mintModuleId:Nothing = 該 module 未碰撞鑄裸名、
--   Just file = 碰撞組成員。TypeNs 加 "#t" 後綴,其餘三個 namespace 無後綴(C2)。
mintDeclId :: QualName -> Maybe FilePath -> NodeId

-- | instance 節點 id 鑄造(C3 裁決的契約簽名)。
--   第一參數是 instance **宣告所在** module(由 fiInstFile 反查,見假設 A3),
--   第三參數是渲染後的 instance 標頭(fiInstHead 原文)。
mintInstanceId :: ModuleName -> Maybe FilePath -> Text -> NodeId
```

**`Knot.Graph.NodeMint`**(非契約面 · 供 edge-derive 與 1-to-1 測試)

```haskell
-- | D1 消歧判定:碰撞組成員回 Just file、未碰撞回 Nothing。
--   由 F001 mintNodes 的內部 where 子句提升,語意一字不變。
disambiguate :: Map ModuleName (Set FilePath) -> ModuleName -> FilePath -> Maybe FilePath

-- | 檔案 → 該檔宣告的 module。FactInstance 沒有 module 欄位,
--   instance 節點的所屬 module 只能由 fiInstFile 反查(假設 A3)。
moduleOfFile :: [Fact] -> Map FilePath ModuleName
```

**簽名不變、語意擴充的既有介面**(不算新增,列出以利對帳):

```haskell
gateFacts   :: ProjectMeta -> [Fact] -> GatedFacts          -- 開始讀 pmSources(規則 3)
mintNodes   :: GatedFacts -> [GraphNode]                     -- 回傳值含 decl / instance 節點
deriveEdges :: GatedFacts -> [GraphNode]
            -> ([GraphEdge], EdgeStats, [GraphWarning])      -- 邊集合含 RContains
```

**`Knot.Graph`**、**`Knot.Graph.Types`**、`knot-hs.cabal`:**無任何新增或改動**。

## TodoList

- [x] T1: `Knot.Graph.FactGate`——規則 3 三條件過濾(`FactDecl` / `FactInstance` 的 (a)(b);`FactRef` 的 (a)(b)(c)),`srcSet` 由 `pmSources` 的 `sfPath` 建立、字串完全相等比對;`gfFiltered` 計實際濾除筆數;module 層事實不受影響、`gfInternal` 語意不變  `dep: -`
- [x] T2: `Knot.Graph.NodeMint` 鑄造面——契約面 `mintDeclId`(`#t` 只對 `TypeNs`)、`mintInstanceId`(`#i:` 前綴),兩者皆以 `mintModuleId` 為基底;非契約面 `disambiguate`(由 `F001` 內部 where 提升)與 `moduleOfFile`  `dep: T1`
- [x] T3: `Knot.Graph.NodeMint` 節點面——`mintNodes` 擴充產出 decl 節點(`DeclNode fdKind`、`gnLabel = qnOcc`、`gnLine = Just fdLine`)與 instance 節點(`InstanceNode`、`gnLabel = fiInstHead`);內部判定(`gfInternal`)與 module 節點存在性守門;三種節點統一 `nubOrdOn gnId` 去重  `dep: T2`
- [x] T4: `Knot.Graph.EdgeDerive`——新增 `FactDecl` / `FactInstance` → `RContains`(module → decl / instance,`geLine` 取宣告行);端點以 node-mint 的鑄造函式計算並驗證存在性;解析不到的來源彙整為每個 module / 檔案一則 `GraphWarning`;沿用既有去重與統計,**不**碰 `RCalls` / `RUses` / `RImplements`  `dep: T3`
- [x] T5: 端到端串接複驗——`gsFilteredGenerated` 接上 `gfFiltered`;`moduleOnly = True` 時 decl 節點、`RContains` 與過濾統計全為零(規則 6 + 驗收標準 5);`cgNodes` / `cgEdges` 在三種節點與兩種 relation 下仍為 D5 全序。`Knot.Graph` 與 `knot-hs.cabal` 預期零改動,若實際需要改動則記入「實作備註」  `dep: T4`
- [x] T6: `F001` 既有測試對帳——依「實作方式 › 6」的對照表更新 `test_gate_facts` / `test_mint_module_nodes` / `test_build_graph_assemble` 三條測試至新行為,不刪除任何測試;確認 `test_build_graph_deterministic` 的兩條端到端與 property 不受影響  `dep: T5`
- [x] T7: 決定性與 C1 instance 路徑——以手工 `[Fact]` 事實流(E3:不依賴 hiedb、不讀 `.hie`、不 shell out)驗證同輸入兩次結果相等、事實流重排序不改變輸出;hedgehog property 以隨機 decl 事實流驗排序與純函數性;instance 節點全路徑以手工 `FactInstance` 驗收(端到端恆 0 是預期行為)  `dep: T6`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_gate_generated_filter | 手工事實流 + 手工 `ProjectMeta`:檔案在 `pmSources` 且行號 > 0 的 `FactDecl` / `FactInstance` / `FactRef` 通過;指向 `pmSources` 外檔案者被濾除;行號 `0` 與 `-1` 者被濾除;`frGenerated = True` 的 `FactRef` 被濾除(即使檔案與行號都合法);`FactModule` / `FactImport` **不論** `fmFile` 是否在 `pmSources` 一律通過(假設 A1);`gfFiltered` 等於濾除筆數,且同時違反兩條件的事實只算一次;`gfInternal` 與過濾前相同 |
| T2 | test_mint_decl_ids | `mintDeclId (qn "Demo.Core" "Foo" TypeNs) Nothing == "Demo.Core.Foo#t"`、`mintDeclId (qn "Demo.Core" "Foo" DataConNs) Nothing == "Demo.Core.Foo"`(驗收標準 1:同名型別與值不碰撞);`ValueNs` / `FieldNs` 亦無後綴(C2);`mintDeclId (qn "Main" "main" ValueNs) (Just "app/Main.hs") == "Main@app/Main.hs.main"`(C3);`mintInstanceId (mn "Demo.Core") Nothing "Renderable Sprite" == "Demo.Core#i:Renderable Sprite"`(驗收標準 2)且對同輸入恆定;`disambiguate` 對碰撞組回 `Just`、非碰撞組回 `Nothing`;`moduleOfFile` 由 `FactModule` 建出正確對映 |
| T3 | test_mint_decl_nodes | 手工事實流:每筆通過閘門的 `FactDecl` 產一個節點,`gnKind == DeclNode fdKind`、`gnLabel == qnOcc`、`gnFile == fdFile`、`gnLine == Just fdLine`;`FactInstance` 產 `InstanceNode`,`gnLabel == fiInstHead`、`gnLine == Just fiInstLine`;module 節點清單與 `F001` 完全相同(不改 module 層行為);`qnModule` 非內部的 `FactDecl` **不**產節點;同 id 的兩筆 decl 合併為一個節點(`DuplicateRecordFields` 精度限制,假設 A9);碰撞組 module 的兩個 `Main.main` 鑄出兩個相異節點(釘住 C3 的動機) |
| T4 | test_contains_edges | 手工事實流:每個 decl 節點恰有一條 `RContains`,`geSource` 是其所屬 module 節點 id、`geTarget` 是該 decl 節點 id、`geRelation == RContains`、`geLine == Just fdLine`(驗收標準 4);instance 節點同樣有一條來自其宣告 module 的 `RContains`;碰撞組專案的 `Main@app/Main.hs.main` 由 `Main@app/Main.hs` 而非 `Main@test/Main.hs` 擁有;module 非內部的 decl 不產邊、`esDroppedExternal` **不變**、彙整為一則帶筆數的警告(假設 A4);重複 `FactDecl` 去重為一條且計入 `esDeduped`;`RCalls` / `RUses` / `RImplements` 在輸出中**完全不出現**(明確不做的反向斷言) |
| T5 | test_module_only_decl | 同一份含 decl / instance 事實的輸入分別以 `moduleOnly = True` / `False` 呼叫 `buildGraph`:`True` 時 `cgNodes` 全部 `gnKind == ModuleNode`、`cgEdges` 全部 `RImports`、`gsFilteredGenerated == 0`(規則 6 的「不計入統計」);`False` 時 decl / instance 節點與 `RContains` 出現且 `gsFilteredGenerated` 等於實際濾除數(驗收標準 3、5);兩者的 module 節點與 imports 邊完全相同;`cgNodes` 依 `NodeId` 遞增、`cgEdges` 依 `(source, relation, target)` 遞增(D5 在混合節點/relation 下仍成立) |
| T6 | test_build_graph_assemble(更新版) | `F001` 的綜合事實流改配涵蓋各檔的 `ProjectMeta`:`moduleOnly = False` 時比 `F001` 原結果多出 1 個 decl 節點與 1 條 `RContains`、其餘四項統計與警告不變;`moduleOnly = True` 時輸出與 `F001` 的原斷言逐欄相同(含 `gsFilteredGenerated == 0`);反轉輸入事實序結果仍完全相同。同批更新 `test_gate_facts`(改驗規則 3 生效後的 `gfFacts` / `gfFiltered`)與 `test_mint_module_nodes`(改用涵蓋該檔的 `ProjectMeta`,斷言 module 節點清單不變),三條測試更新後全數通過 |
| T7 | test_decl_graph_deterministic | 全部走手工 `[Fact]`(E3,無 hiedb / 無 `.hie` / 無外部行程):同輸入連續兩次 `buildGraph` 結果 `==`;`Gen.shuffle` 重排事實流後結果 `==`;hedgehog property 隨機生成 module × decl(混 namespace、混碰撞組、混 `pmSources` 內外檔案、混合法/非法行號)→ decl 節點數 == 通過閘門且 module 為內部的相異 id 數、`RContains` 條數 == decl 與 instance 節點數、`gsFilteredGenerated` == 被濾除筆數、`cgNodes` / `cgEdges` 已排序;C1 專屬子測試:純 `FactInstance` 事實流走完整路徑產出 instance 節點 + `RContains` 且零 `RImplements`(端到端恆 0 是預期行為,不是缺陷) |

## 待確認假設

- A1: 組裝規則 3 的原文只說「事實指向的檔案不在 `pmSources`」,未指明適用於哪些事實建構子 → 採取:**只套用於 decl 層事實**(`FactDecl` / `FactRef` / `FactInstance`),`FactModule` / `FactImport` 完全不受影響。依據:委派決策 C4 只列舉這三個建構子,且契約卡明載「不改 module 層行為」;若套到 `FactModule`,`gfInternal` 會縮水、module 節點整批消失 → 影響:若裁定 module 層也要套,改 fact-gate 的 `filteredOut`,並須重跑 `F001` 的全部端到端測試與兩個唯讀驗收標的
- A2: (a) 條件的比對母體是 `pmSources` **全部**條目,還是只有 `sfIncluded = True` 者,契約未明 → 採取:**全部**(契約原文即 `pmSources`)。查證:`Knot.App.Run.runExtractCmd` 傳給 `buildGraph` 的是未窄化的 `pm`,extraction 內部才由 `narrowScope` 窄化,故端到端下事實流的檔案必為 `pmSources` 的子集、(a) 恆不成立,兩種選擇端到端無差 → 影響:若裁定只比 `sfIncluded = True`,被排除 component(test-suite / benchmark)的事實會多一層防禦性過濾,實際只在未來的第三後端或手工事實流下才看得出差異
- A3: `FactInstance` **沒有「宣告 module」欄位**(已讀 `src/Knot/Extract/Types.hs:93-96` 確認:只有 `fiClass` / `fiInstHead` / `fiInstFile` / `fiInstLine`),而鑄造規則的 instance 列需要 `<mod-id>` → 採取:由 `fiInstFile` 反查 `FactModule` 取得宣告 module(非契約面 `moduleOfFile`);**不**用 `qnModule fiClass`,因為那是 class **定義處**的 module,而 design.md 的例子 `Demo.Core#i:Renderable Sprite` 指的是 instance 宣告處 → 影響:若裁定用 `fiClass` 的 module,改 node-mint 一處;更好的作法是請 extraction 為 `FactInstance` 補一個宣告 module 欄位(**建議的 Level 2 契約變更,見回報**),否則「instance 宣告在 `A.hs` 但該檔沒有 `FactModule`」時無從鑄造
- A4: decl / instance 事實的 module 非內部(或找不到對應 module 節點)時的統計歸屬未明 → 採取:**不建節點、不產邊、不計入 `gsDroppedExternal`**,改彙整為每個相異 module(instance 路徑為每個相異檔案)一則帶筆數的 `GraphWarning`。依據:`F001` 假設 A4 的先例(非外部目標的丟棄一律走警告不走統計),且 `--backend hiedb` 單跑時事實流無 `FactModule`,若計入統計會把專案自己的 module 全部灌進 `gsTopExternalTargets` → 影響:若裁定應計入,改 edge-derive 的 decl 判定分支;`gsDroppedExternal` 維持單一計數器(E4)故無法區分兩類丟棄
- A5: `RContains` 的 `geLine` 未在契約明定 → 採取:取宣告行(`fdLine` / `fiInstLine`),與 `FactImport` → `RImports` 取 `fiLine` 的既有處理一致;下游 `edgeObject` 會據此輸出 `source_location` → 影響:若裁定結構邊不該帶證據行,改為 `Nothing`,`codegraph.json` 的 `contains` 邊少一個欄位(不影響 `scan-graph.mjs`,它只對依賴類邊取證據行)
- A6: 規則 3 生效後,`F001` 的三條既有測試與新行為衝突——最關鍵的是 `test_build_graph_assemble` 斷言 `gsFilteredGenerated == 0` 且「`moduleOnly` 兩取值輸出完全相同」,而本 feature 的驗收標準 5 蘊含兩者**必須不同** → 採取:依「實作方式 › 6」的對照表**更新**這三條測試(不刪除、不停用),並在測試註解標明是被 `F002` 取代的 `F001` 驗收標準 5(其原文已註明「尚無 decl 事實」)→ 影響:若編排者要求 `F001` 測試一字不動,則本 feature 必須讓 `graphOf` 系列 helper 改配新的 `ProjectMeta` 常數而保留舊斷言為 module-only 情境,測試檔改動範圍更大
- A7: node-mint 的契約簽名 `mintNodes :: GatedFacts -> [GraphNode]` **沒有警告通道**,故「跳過某筆 decl」在 node-mint 只能靜默 → 採取:警告一律由 edge-derive(契約已有第三分量)發出,node-mint 與 edge-derive 用同一組判定函式保證兩者跳過的集合一致 → 影響:若要求 node-mint 自報跳過,須改 Level 2 的 `mintNodes` 簽名為三元組(**Level 2 契約變更**)
- A8: edge-derive 要產 `RContains` 就必須知道 decl 節點的 id,但 `GraphNode` 的五個欄位**無法**還原 `(module, occ, namespace)` 三元組(`gnLabel` 只有 occ 名,同檔的 `Foo#t` 與 `Foo` 會撞),而 `deriveEdges` 的第二參數在 Level 2 契約裡是 `[GraphNode]` → 採取:edge-derive **呼叫 node-mint 的 `mintDeclId` / `mintInstanceId` / `mintModuleId`** 計算端點 id,再以節點集合驗證存在性;`NodeId` 建構子仍只在 node-mint 出現,符合 Level 2「唯一構造入口在 node-mint」(被放寬的只是 `F001` haddock 那句階段性自我約束「edge-derive 不鑄造任何 id」)→ 影響:若裁定 edge-derive 完全不得呼叫鑄造函式,唯一出路是把 `deriveEdges` 的第二參數改為 node-mint 產出的節點索引 DTO(**Level 2 契約變更**),`F003` 也會一併受益
- A9: 同 id 的兩個 decl 節點(`DuplicateRecordFields` 下同 module 的兩個同名欄位選擇器)合併時,是否要有統計欄位未明 → 採取:以既有的 `nubOrdOn gnId` 靜默合併,**不**計入 `gsDedupedEdges`(那是邊的統計),`GraphStats` 不加欄位 → 影響:若要求可觀測,需為 `GraphStats` 新增「合併節點數」欄位(**Level 2 契約變更**);design.md 目前把這列為「extraction 契約的粗度,graph-core 不補救」,故傾向維持現狀
- A11(**實作時新增**): 撰寫時假定「decl 節點依 `gnId` 去重(`nubOrdOn`)」即滿足規則 7,實作後由 T7 的 hedgehog property **實測推翻**——`nubOrdOn` 保留輸入序第一筆,而同 id 的兩筆 `FactDecl`(同 `QualName` + 同檔 + 不同行,或同 `QualName` + 不同檔)其 `gnFile` / `gnLine` 相異,事實流一重排就鑄出不同的節點 → 採取:node-mint 的節點去重改為「保留 `(gnFile, gnLine, gnKind)` **最小**者」(私有 `dedupeNodes`,輸出序仍為各 id 首次出現序),與 edge-derive `geLine` 取極小值同一理由;`moduleOfFile` 的 `Map.fromList` 同理改為 `Map.fromListWith min`(同檔宣告多個 module 名的病態輸入)。**契約簽名零變更**,屬內部實作自主權 → 影響:若編排者要求「合併時保留輸入序第一筆」,規則 7(決定性)就不成立,`buildGraph` 對事實流重排序不再冪等
- A12(**實作時新增**): 編排者裁決「node-mint 增設非契約面的 `QualName → NodeId` 索引函式,索引建立時就以節點集合守門」,而本文檔的假設 A8 採的是「edge-derive 直接呼叫 `mintDeclId` + `Set NodeId` 驗證」;同時 `F003` 的 T1 已把該索引寫成 `declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]` → 採取:**本 feature 就實作 `declNodeIndex`**(簽名與 `F003` 文檔一字不差),`RContains` 的 decl 端點改走它;instance 端點仍走「`moduleOfFile` 反查 → `disambiguate` → `mintInstanceId` → 節點集合驗證」(`F003` 明載沿用此路徑,不另建第二條)。module 端點沿用 `F001` 既有的 `sourceNode`,**一字不改** → 影響:`F003` 的 T1 已由本 feature 完成,該 feature 只需消費並補其 1-to-1 測試 `test_decl_node_index`;若編排者要求 `declNodeIndex` 留給 `F003`,把 node-mint 的該函式與 edge-derive 的 `declNodeOf` 拿掉、退回 A8 的原方案即可
- A10: `--backend hiedb` 單跑時,事實流沒有任何 `FactModule`(規則 2 明定 `FactModule` 是 import-scan 的唯一職責),故 `gfInternal` 為空、所有 decl 皆被判為非內部、整圖為空 → 採取:**不特別處理**,由 A4 的彙整警告如實呈現。這是 D2(內部集合來自 `FactModule`)的既有推論,不是本 feature 引入的行為 → 影響:若裁定 `--backend hiedb` 應可獨立產圖,須放寬 D2(改由 `pmSources.sfModule` 或事實流的 `frFromModule` / `qnModule` 補充內部集合),那是 `F001` 契約層級的變更

## 實作備註

**改動檔案**(4 個,全部是既有檔案的擴充;`knot-hs.cabal` 與 `src/Knot/Graph.hs` 零改動,`git diff --stat` 實測為空):

```text
src/Knot/Graph/FactGate.hs     T1
src/Knot/Graph/NodeMint.hs     T2 T3
src/Knot/Graph/EdgeDerive.hs   T4
test/Main.hs                   T6(更新 F001 三條)+ graph-core/F002 group 六條
```

**與文檔的偏差(兩處,皆屬內部實作自主權,契約簽名零變更)**:

1. **節點去重改為取極小代表**(假設 A11):文檔「實作方式 › 3」寫的 `nubOrdOn gnId` 保留輸入序第一筆,實測不滿足規則 7。改用私有 `dedupeNodes`(保留 `(gnFile, gnLine, gnKind)` 最小者)。這是 T7 的 property **實際抓出來的缺陷**,不是預防性改寫:反例 `module Aa` + 兩筆 `Aa.Foo`(同檔、行號 1 與 2)在 `Gen.shuffle` 後 `gnLine` 會在 `Just 1` / `Just 2` 之間跳動。
2. **decl 端點改走 `declNodeIndex`**(假設 A12):依編排者對 A8 的裁決,並與 `F003` 文檔的簽名對齊。

**與 `F003` 的介面對帳**(簽名逐字比對,全部一致):

| 介面 | 出處 | 狀態 |
|---|---|---|
| `mintDeclId :: QualName -> Maybe FilePath -> NodeId` | 本文檔介面表 / design.md | 一字不差 |
| `mintInstanceId :: ModuleName -> Maybe FilePath -> Text -> NodeId` | 本文檔介面表 / design.md | 一字不差 |
| `disambiguate :: Map ModuleName (Set FilePath) -> ModuleName -> FilePath -> Maybe FilePath` | 本文檔介面表 | 一字不差 |
| `moduleOfFile :: [Fact] -> Map FilePath ModuleName` | 本文檔介面表 | 一字不差(內部改用 `fromListWith min`,見 A11) |
| `declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]` | `F003` 文檔「新增的介面」 | 一字不差(見 A12) |
| `gateFacts` / `mintNodes` / `deriveEdges` / `EdgeStats` / `buildGraph` | design.md | 簽名完全未動 |

`Knot.Graph.EdgeDerive` 另留了兩個具名 where binding 供 `F003` 直接接手:`instanceContains`(instance 端點解析,`RImplements` 的來源端沿用)與 `Skipped (Text, Text)` 建構子(可彙整的跳過理由,`F003` 文檔明載「直接沿用、不另加」)。

**T5 端到端複驗**(`knot-hs` 自身,`--backend auto`,索引寫到專案外暫存目錄,唯讀):

```text
graph: 654 nodes, 710 edges, 0 warnings
stats: dropped-external=168, filtered-generated=846, deduped-edges=2, top-external=10
節點:31 module + 623 decl + 0 instance(C1:instance 端到端恆 0 是預期行為)
邊  :87 imports + 623 contains + 0 calls/uses/implements
```

`filtered-generated=846` 與 `F003` 文檔「實作方式 › 9」的預估值**逐筆吻合**(846/7265 = 11.6% 的 `frGenerated` ref);節點數與該表預估的 631 decl 差 8,原因是 `.hie` 為不同一次 build 的產物(該文檔 A10 已預告)。

**順帶查到、不屬本 feature 的觀察**(建議寫進閘門紀錄):端到端 decl 節點含 `$fEqCommand` / `$fShowExtractCmd` 這類 **deriving 產生的 dictionary 宣告**。規則 3 的 (c) 條件只讀 `FactRef.frGenerated`(hiedb 的 `decls` 表無對應欄位),故這些節點目前濾不掉,約佔 decl 節點的一部分,會稀釋 hub 排名。要處理需擴充 extraction 契約(為 `FactDecl` 補 generated 欄位)或在 fact-gate 加 occ 名啟發式——後者與 design.md「不做啟發式」的裁決相衝,故本 feature 不做。
