---
id: graph-core-build
type: build-log
title: graph-core-build
description: 委派展開 graph-core 階段一(module-graph)與階段二(decl 層)
status: done
created: 2026-08-20
updated: 2026-08-22
parent: graph-core
---

# graph-core 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | module-graph | impl-done |
| 階段二:S3 decl 層 | W2 | decl-nodes | impl-done |
| 階段二:S3 decl 層 | W3 | decl-edges | impl-done |

階段一(2026-08-20):開發者決定只跑階段一(主架構 S1 端到端優先);跨子系統依賴 project-meta、extraction 階段一皆 done 並已 merge 進 main(PR #1,commit 76cf838)。

階段二(2026-08-22,接續模式):跑完整個階段二(E1 裁決)。兩波序列——#3 依 #2 的節點集合,無平行空間。上游 extraction 階段二已 done 並 merge(PR #4,commit 2b0c5b6),`FactDecl` / `FactRef` 實測產出(knot-hs 自身:FactDecl 623 / FactRef 7265 / `frGenerated = True` 846)。**`FactInstance` 無後端產出**(extraction C4),instance 路徑以手工事實流驗收。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | 同名 module 碰撞(多個 executable 的 Main、extraction D3 讓無標頭檔皆為 Main) | 改鑄造規則:同名整組改用 `<module>@<source_file>`,碰撞事實進 GraphWarning;已回寫契約 | F001,及階段二 decl 層 |
| D2 | 內部 module 集合的來源 | 以事實流的 FactModule.fmModule 為準(非 pmSources.sfModule);已回寫契約 | F001 |
| D3 | GraphWarning 形狀 | `{ gwSource :: Text, gwMessage :: Text }`,比照 MetaWarning / ExtractWarning;已回寫契約 | F001 |
| D4 | gsTopExternalTargets 的 N 與排序 | 取前 10,次數降序、同次數依 module 名字典序;已回寫契約 | F001 |
| D5 | 排序鍵 | cgNodes 依 NodeId 字典序;cgEdges 依 (source, relation, target) 字典序;已回寫契約 | F001 |
| D6 | 沿用的全域決定 | hedgehog+tasty;命名空間 `Knot.Graph.*`;驗收標的絕對唯讀;版本號 0.0.1.0 凍結;收尾以 PR 整合 | 全部 |

### 階段二批次澄清(2026-08-22)

**契約類**(已回寫 `design.md`,`updated` 同步):

| # | 問題 | 開發者決定 | 回寫位置 |
|---|------|-----------|---------|
| C1 | 兩張卡都要 instance(`mintInstanceId`、`#i:`、`RImplements`),但 extraction 依 C4 不產 `FactInstance`(hiedb 0.8 無 instance 表),system.md 亦已寫明「`implements` 邊不在 S3」 | **保留完整程式碼路徑,以手工 fixture 事實流驗收**;端到端恆 0。兩段都是純函數,ADR-002 的第三後端上線時零改動即生效 | 組裝規則 2 表後註記 |
| C2 | 邊推導表只列 `ValueNs`→`RCalls`、`TypeNs`→`RUses`;`DataConNs`(hiedb `c:`,實測 95 筆 decl)與 `FieldNs`(`f:`,166+ 筆)未涵蓋 —— extraction W4 閘門明確留給本階段的前置,不裁決會**靜默落空** | **term/type 二分**:`ValueNs` / `DataConNs` / `FieldNs` → `RCalls`;`TypeNs` → `RUses`。四個 namespace 全部有歸屬 | 邊推導表 + 表後註記 |
| C3 | `mintDeclId :: QualName -> NodeId` 無 file 參數,消歧組(例:particle-magic 的 5 個 `Main`)的 decl 會全部撞成 `Main.foo` —— 與階段一 A2 同一個坑 | **比照 A2 改契約簽名**:`mintDeclId` / `mintInstanceId` 都帶 `Maybe FilePath`;鑄造規則表的 `<module>` 改為 `<mod-id>`(= module 節點實際鑄出的 id) | 鑄造規則表 + 模組間公開介面 |
| C4 | 組裝規則 3 未提 `frGenerated`,但 extraction 規則 4a 說「丟不丟是 graph-core 的決定」、system.md 說 S3 過濾改用 `refs.is_generated` 事實 | **`frGenerated = True` 一律濾除並計入 `gsFilteredGenerated`**(實測 846/7265 = 11.6%)。不做「異常 span」啟發式 | 組裝規則 3 |

**執行取向類**(不屬 Level 2,只留此處):

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| E1 | 本次跑到哪 | **跑完整個階段二**(W2 → W3)。只有 decl 節點而無 calls/uses 邊是半成品,S3 里程碑要兩者到位才宣告完成 | F002、F003 |
| E2 | G-E002(`-Wall` 零警告,open,`test/Main.hs` 8 筆 `-Wincomplete-record-selectors`)本階段是否順手處理 | **不碰**(跨子系統改別人的測試碼,不屬本契約卡範圍),但**本階段新增程式碼不得再添新警告**;閘門以 `cabal clean` 後重建確認 —— 這是 G-E002 挖出來的唯一可靠手段(`-fforce-recomp` 會被 cabal up-to-date 短路而給出假答案) | F002、F003、閘門 |
| E3 | decl 層 1-to-1 測試的輸入來源 | **一律手工 `[Fact]` 事實流**,不依賴 hiedb、不受 D7 跳過機制影響,測試在任何機器全綠。graph-core 是純函數子系統,契約卡的驗收標準本來就寫「以 fixture 事實流驗證」 | F002、F003 |
| E4 | `gsDroppedExternal` 是單一計數器(module 級實測 283),decl 層上來後會被推到數千 | **維持單一計數器**。`GraphStats` 是 Level 2 契約 DTO,加欄位要連帶動 export-query 的摘要渲染;`gsTopExternalTargets` 已能看出丟到哪些 module,層別區分屬診斷需求而非契約需求 | F002、F003 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| module-graph | F001 | F001-module-graph.md | opus(預防 Fable 誤判) | 繼承 | impl-done |
| decl-nodes | F002 | F002-decl-nodes.md | 繼承 | 繼承 | impl-done |
| decl-edges | F003 | F003-decl-edges.md | 繼承 | 繼承 | impl-done |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | NodeId 唯一構造入口在 Haskell 無法不新增模組地強制(會成 import 環) | Types 匯出 NodeId(..) + haddock 紀律;edge-derive 一律從 gnId 取值不鑄 id | 接受 |
| F001 A2 | mintModuleId 簽名早於 D1 寫定,缺 file 參數無法鑄 <module>@<file> | 契約簽名不動,另加非契約面 mintModuleIdAt | 接受:改契約簽名(已回寫) |
| F001 A3 | deriveEdges/EdgeStats 無警告通道,但解析失敗不得靜默 | 契約函式不動,另加非契約面 deriveEdgesWithWarnings | 接受:改回三元組(已回寫) |
| F001 A4 | import 目標落在同名消歧組時無從判定指向哪個節點 | 丟棄該邊 + 警告,不計入 gsDroppedExternal | 接受 |
| F001 A5 | 消歧節點的 gnLabel | 維持裸 module 名,消歧只在 gnId/gnFile | 接受 |
| F001 A6 | 規則 3 不在本卡範圍但 gfFiltered/gsFilteredGenerated 欄位屬本卡 | 欄位齊備恆 0,規則 3 留階段二 | 接受 |
| F001 A7 | cgWarnings 的排序與去重未定義,但規則 7 要求決定性 | 依 (gwSource, gwMessage) 去重並字典序輸出 | 接受 |
| F001 A8 | 契約卡「不印任何輸出」vs 兩標的實跑驗收 | library 不印;app 層加 renderGraphSummary + --graph | 接受 |
| F001 A9 | test/fixtures/proj 三個 included 檔全無標頭也無 import,端到端驗不到邊 | 保留 proj(D1 真實樣本),另建 test/fixtures/graph 驗邊集/丟棄/去重/自環 | 接受 |
| F001 A10 | edge-derive 警告的 gwSource 該填什麼 | 邊警告用來源檔路徑(行號進 gwMessage);碰撞警告用 module 名 | 接受 |

### 階段二(2026-08-22)

**開工前裁決**(影響下游 feature,不等閘門):

| 來源 | 假設 | 採取的判斷 | 裁決 |
|---|---|---|---|
| F002 A8 | `deriveEdges` 第二參數 `[GraphNode]` 五欄無法還原 `(module, occ, namespace)`,decl 端點換不成 `NodeId` | 三案:改契約簽名 / node-mint 增索引函式 / edge-derive 自行重建 | **裁決:node-mint 增設非契約面索引函式**(比照 F001 `moduleFiles` 先例),`deriveEdges` 簽名零變更 |
| F002 A3 | `FactInstance` 無 module 欄位,instance 節點的 `<mod-id>` 無來源 | 由 `fiInstFile` 反查 `FactModule` | **裁決:維持反查,不動 extraction 契約**。該建構子目前零產出,為想像中的資料改契約不划算;已回寫鑄造規則 |
| F002 A1 | 規則 3 若套用到 `FactModule` 會讓 `gfInternal` 縮水 | 規則 3 只適用 decl 層事實 | **裁決:接受**,已回寫組裝規則 3 |

**閘門裁決(2026-08-22)**:

| 來源 | 假設 | 採取的判斷 | 裁決 |
|---|---|---|---|
| F002 A2 | (a) 條件比對 `pmSources` 全部條目而非只 `sfIncluded = True` | 比對全部條目 | 接受 |
| F002 A4 | decl/instance 的 module 非內部 → 不建節點不產邊 | 不計 `gsDroppedExternal`,發彙整警告 | 接受(已回寫為組裝規則 4b) |
| F002 A5 | `RContains` 的 `geLine` 取宣告行 | 取宣告行 | 接受 |
| F002 A6 | 規則 3 生效會打破 F001 三條既有測試 | 更新期望值不刪除斷言 | 接受 |
| F002 A7 | `mintNodes` 無警告通道 | 跳過一律靜默,警告由 edge-derive 以同一組判定發出 | 接受 |
| F002 A9 | `DuplicateRecordFields` 同名欄位選擇器會靜默合併 | 不補救、不加統計欄位 | 接受(繼承 extraction A9 的粗度,已註記於鑄造規則) |
| F002 A10 | `--backend hiedb` 單跑時 `gfInternal` 為空 → 整圖為空 | 由 4b 警告如實呈現 | 接受(D2 的既有推論,非本階段引入) |
| **F002 A11** | **節點去重用 `nubOrdOn`(保留輸入序第一筆)會讓 `gnLine` 隨事實流順序跳動,違反組裝規則 7** | 改保留 `(gnFile, gnLine, gnKind)` 最小者 | **接受**。property test 實測抓出反例;與 F001 閘門對 `geLine` 取極小值的裁決同源。規則 5 只寫了邊的合併,節點面的決定性至此有了實作依據 |
| F003 A2 | 規則 4b 與規則 1 衝突時的優先序 | 4b 先判 | 接受(否則 `--backend hiedb` 單跑會把自家 module 灌進 `gsTopExternalTargets`) |
| F003 A3 | `frTarget` 落在 D1 消歧組 → 丟棄 + 警告不計統計 | 比照 4a | 接受 |
| F003 A4 | instance 來源解析失敗不重發警告(F002 的 `RContains` 支已發過) | 不重發 | 接受 |
| F003 A5 | `RImplements` 的 `geLine` 取 `fiInstLine` | 取 `fiInstLine` | 接受 |
| F003 A6 | ref 警告採「每個 (來源檔, 原因) 一則帶筆數」的彙整式,imports 維持逐筆 | 兩種粒度並存 | 接受(ref 量級是每檔數百筆,逐筆會刷屏;實跑 19 則 vs 25 筆) |
| F003 A7 | `gsTopExternalTargets` 語意由「被 import 最多」變成「被引用最多」 | 照 E4 不加欄位 | 接受(見閘門發現 2) |
| F003 A8 | 來源解析失敗也發警告(契約卡只寫目標) | 兩端對稱 | 接受 |
| F003 A12 | 端到端數字取決於索引建法 | 兩組數字並陳,以真實管線為基準 | 接受(見閘門發現 1) |

## 階段結果

### 階段一:S1 骨架

- F001 module-graph(設計 opus/實作繼承):8/8 Todo、測試 63/63(既有 53 全綠)、-Wall 零警告
- 契約補完:A2(mintModuleId 增 Maybe FilePath)、A3(deriveEdges 改三元組)於實作開工前裁決並回寫,實作一字不差落地,未產生非契約面包裝函式
- 唯讀實跑:MagicFarmer 58 節點/239 邊/0 警告(外部丟棄 283、去重 1);particle-magic 45 節點/125 邊/1 警告(外部丟棄 222、去重 2);兩次輸出 diff 位元相同
- **D1 消歧首次真實實證**:particle-magic 的 Main 由 5 個來源檔宣告(app、examples、tools/三支),整組鑄成 Main@<file>,無裸名節點;唯一警告即此碰撞
- arch-audit subsys:純函數無 IO、資料流管線(gate → mint → derive → assemble)與契約一致、規則 1/2/4/5/6/7 逐條落實、SRP 清楚、NodeId 構造入口單一;去重取組內最小行號(比契約的「保留最早」更嚴格的決定性)
- 閘門裁決:A1、A4–A10 全部接受(A4 的消歧組丟邊規則已寫進 design.md 組裝規則 4a);階段一收尾以 PR 整合

### 階段二:S3 decl 層

- **F002 decl-nodes**(設計繼承 / 實作繼承):Todo 7/7、測試 **126/126**;改 `FactGate.hs`(規則 3 三條件)、`NodeMint.hs`(`mintDeclId` / `mintInstanceId` / `declNodeIndex` / `dedupeNodes`)、`EdgeDerive.hs`(`RContains`)
- **F003 decl-edges**(設計繼承 / 實作繼承):Todo 7/7、測試 **134/134**;只改 `EdgeDerive.hs`(`relationOf` 的 term/type 二分、`RCalls`/`RUses`/`RImplements` 三條判定鏈、`SkipKind` 彙整警告)
- **Level 2 契約零偏離**:`buildGraph` / `gateFacts` / `mintNodes` / `deriveEdges` / `EdgeStats` / 全部 DTO 一字未動,E4 遵守。C3 改的兩個鑄造函式簽名實作一字不差落地
- **編排者獨立驗證(未採信 subagent 轉述)**:
  - `cabal clean` 後全量重建:警告 **8 筆**,逐筆確認全部是 G-E002 追蹤的 `test/Main.hs` `-Wincomplete-record-selectors`,**graph-core 新增程式碼零警告**。這是本專案首次在閘門獨立驗證此慣例而非轉述
  - `cabal test`:**All 134 tests passed**,0 失敗 0 跳過
  - 唯讀實跑 knot-hs 自身(`--db` 改道專案外):**654 節點 / 2267 邊 / 19 警告**;節點 = 31 module + 623 decl + 0 instance,邊 = 87 imports + 623 contains + **1246 calls + 311 uses** + 0 implements;`gsDroppedExternal` 3932、`gsFilteredGenerated` 846、`gsDedupedEdges` 527。**repo 零寫入**(無 `.knot/`)
  - **決定性**:連跑兩次,輸出**位元相同**
  - **下游契約驗證(S3 的存在理由)**:把圖餵給 dev-flow `scan-graph.mjs` → 解析成功、**檔案對映覆蓋率 31/31(100%)**、**端點未對映 0**(「查得到才產邊」的規則生效,無懸空 link)、**無子系統循環依賴**、依賴矩陣六條邊全部合理。**hub 洗版實測成立**:函式級節點(`deriveEdges` 38、`buildGraph` 33、`refFactsOf` 30、`renderGraphSummary` 31)首次與 module 並列進榜——這正是 S3 里程碑承諾的能力
  - **邊界檢查**:graph-core 對外只碰 `Knot.Extract.Types` 與 `Knot.Meta.Types` 兩個契約 DTO 模組;別人進來只碰 `Knot.Graph` / `Knot.Graph.Types`。**無邊界外洩**
- **arch-audit subsys 發現**(依嚴重度):
  1. (中)**產生碼過濾不對稱**:規則 3(c) 濾掉 846 筆 generated **ref**,但 generated **decl** 一個都沒濾——`FactDecl` 沒有對應旗標(hiedb 的 `decls`/`defs` 表無 `is_generated` 欄,只有 `refs` 有)。實測 623 個 decl 節點中 **106 個(17%)是 deriving 產生的 dictionary 繫結**(`$fEqCommand`、`$fShowFact`、`$fFromRowDefRow`…)。它們稀釋 hub 排名,且沒有任何人寫過那些行。**修正需擴充 extraction 契約**(為 `FactDecl` 補 generated 欄位),或在 fact-gate 加 occ 名啟發式(與 design.md「不做啟發式」相衝)。**跨子系統,建議走 `/enhance-design`**
  2. (低)**`gsTopExternalTargets` 語意漂移**(F003 A7):decl 層邊上線後由「被 import 最多的外部 module」變成「被引用最多的外部 module」,而 hiedb 回報的是**定義處**——實跑 Top-3 是 `GHC.Internal.Base`(554)/`Data.Text.Internal`(406)/`GHC.Internal.Classes`(401),使用者實際寫的 `Data.Text` 排到第 7。報告可讀性下降。E4 已裁定不加欄位;要改只能在 export-query 的摘要層分開呈現
  3. (低)**19 則 `unresolved reference target $f…` 警告**:根因是 hiedb 的 `defs` 表隨索引建法而異(走目錄 631 列 / 逐檔清單 623 列,`mods`/`decls`/`refs` 三表逐列相同)。少的 8 列全是 deriving instance 字典,連帶 25 筆 ref 解析不到。屬 extraction 上游,與發現 1 同源
  4. (低)`renderFactSummary`(`app/Knot/App/Summary.hs`)對 `FactDecl`/`FactRef`/`FactInstance` 走 `Show` fallback,`--summary facts` 會印 `Show` 原文。屬 export-query;extraction 階段二閘門已記過同一項,兩次委派都回報但都不跨子系統改
  5. (資訊)三個非契約面共用工具(`moduleFiles` F001、`disambiguate`/`moduleOfFile` F002、`declNodeIndex` F002)都未登記進 design.md「模組間公開介面」,沿用 F001 的先例。要不要統一登記待裁決
- **契約卡對帳**:兩張卡的負責模組、Level 2 介面、資料流段落與實作相符(decl-nodes 的「負責模組」已於委派前補上 `edge-derive`);`mintDeclId` / `mintInstanceId` / `declNodeIndex` 三個簽名在 F003 複驗 F002 真實原始碼時零落差

### 階段二閘門裁決(2026-08-22)

1. **全部待確認假設接受**,無一條需要重做 feature。其中 F002 A11(節點去重的決定性)已在實作階段修正並有 property test 護住;開工前裁決的 A8 / A3 / A1 三條已回寫 `design.md`
2. **發現 1 與 3 合併開 [[G-E003]] 追蹤**:產生碼過濾只擋 ref 不擋 decl,實測 623 個 decl 節點中 106 個(17%)是 deriving dictionary;同源的 19 則 unresolved 警告一併記入。根因是 hiedb 只在 `refs` 表有 `is_generated`,`decls`/`defs` 沒有——**不是 extraction 漏掉,是上游資料就只有一半**。文檔列了四條待調查方向,實作前要先驗證而非直接動手
3. **發現 2**(`gsTopExternalTargets` 語意漂移)、**發現 4**(`renderFactSummary` 的 `Show` fallback)、**發現 5**(三個非契約面共用工具未登記)未開文檔,記錄於此供後續。發現 4 是 extraction 階段二閘門就記過的同一項,兩次委派都回報、都正確地不跨子系統改——**這種重複回報是委派模式運作正常的訊號,不是雜訊**
4. **建議修正 `system.md` 的一段描述**(需走 `/system-design` 更新模式,編排者不改 Level 1):第 171 行「`Fact` 的建構子保留、**零邏輯**,`implements` 邊另開 feature」已被 C1 裁決取代——graph-core 的 `RImplements` 推導在 F003 **完整實作**並以手工事實流驗收,缺的只是**事實來源**(hiedb 0.8 無 instance 表)
5. **git 收尾**:保留六個 commit 的現狀(每個都可回退、與 build-log 進度逐條對得起來),整合走 `/branch-pr`

**graph-core 子系統至此可交付**:3/3 feature done,S3 里程碑的三項(兩層節點、`calls`/`uses` 邊、hub 洗版)全部實測達成。
