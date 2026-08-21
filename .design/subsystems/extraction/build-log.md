---
id: extraction-build
type: build-log
title: extraction-build
description: 委派展開 extraction 兩階段(S1 骨架、S3 函式級)
status: in-progress
created: 2026-08-20
updated: 2026-08-21
parent: extraction
---

# extraction 委派展開紀錄

## 排程

| 階段 | 波次 | features | 狀態 |
|---|---|---|---|
| 階段一:S1 骨架 | W1 | fact-contract | impl-done |
| 階段一:S1 骨架 | W2 | import-scan | impl-done |
| 階段二:S3 函式級 | W3 | hiedb-driver | pending |
| 階段二:S3 函式級 | W4 | hiedb-facts | pending |

開發者決定本次只跑階段一(主架構 S1 里程碑優先,S3 之後接續模式回來);無跨子系統未完成依賴(project-meta done)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | ExtractWarning 欄位形狀 | 比照 MetaWarning:{ ewSource, ewMessage },已回寫契約 | F001、後續全部 |
| D2 | ModuleName 型別來源 | 直接共用 Knot.Meta.Types 的定義,不重複定義,已回寫契約 | F001、F002 |
| D3 | 無 module 標頭的 .hs 檔 | 依 Haskell 語意視為 Main(fmFile 區分),已回寫契約 | F002 |
| D4 | 測試框架/命名空間/唯讀(沿 project-meta 展開的全域決定) | hedgehog+tasty;Knot.Extract.*;驗收標的絕對唯讀;版本號 0.0.1.0 凍結 | 全部 |
| D5 | 階段二跑到哪 | 一路跑完階段二(W3 hiedb-driver → W4 hiedb-facts),接續模式沿用既有配號 | F003、F004 |
| D6 | fixture 的 `.hie` 從哪來 | **commit 小型真實 `.hie` 進 fixtures**:自建 2-3 個 module 的小專案、用 GHC 9.14.1 產出並入版控(實測單檔 2.6-26KB)。不在測試裡 shell out 呼叫 ghc——與 export-query D5 刪掉「測試裡跑 node」是同一個理由。版本鎖不是新問題,ADR-001 本來就要求同版 GHC | F003、F004 |
| D7 | hiedb 不在 PATH 時的測試行為 | 需要 hiedb 的測試**自動跳過並印明原因**,測試摘要列出跳過數。符合 ADR-002:沒裝選用依賴不該讓專案看起來是壞的 | F003、F004 |
| D8 | 驗收標的的 `.hie` | **不重建兩個標的**(會寫進它們的 dist-newstyle)。改以自建 fixture + knot-hs 自身(24 個 module 的真實 Haskell 專案)驗收 | F003、F004 |
| D9 | 工具鏈 spike(2026-08-21 實測,GHC 9.14.1) | `hiedb` 已裝於 `/c/cabal/bin/hiedb`;對 knot-hs 自身 24 個真實 `.hie` 執行 `hiedb index` → **24 indexed / 0 skipped / 1.34s**,產出 2.6MB SQLite;`sqlite-simple` + `direct-sqlite 2.3.29` 直讀成功。schema 確認為 mods / decls / defs / refs / exports / imports / typenames / typerefs 八張表(**無 instance 表**);`decls` 無 `mod` 欄,module 需 join `mods.hieFile` | F003、F004 |

## 配號表

| feature | id | 檔名 | 設計模型 | 實作模型 | 狀態 |
|---|---|---|---|---|---|
| fact-contract | F001 | F001-fact-contract.md | opus(Fable 誤判中斷改派) | 繼承 | impl-done |
| import-scan | F002 | F002-import-scan.md | opus(預防 Fable 誤判) | 繼承 | impl-done |
| hiedb-driver | F003 | F003-hiedb-driver.md | 繼承 | 繼承 | pending |
| hiedb-facts | F004 | F004-hiedb-facts.md | 繼承 | 繼承 | pending |

## 待確認假設彙總

| 來源 | 假設 | 採取的判斷 | 閘門裁決 |
|---|---|---|---|
| F001 A1 | 規則 1 落實位置 | backend-select 調度前窄化 pmSources,後端只見 included 檔 | 接受 |
| F001 A2 | BackendChoice → 後端辨識 | 以 bName 比對契約字串常數 import-scan/hiedb | 接受 |
| F001 A3 | 規則 8 排序手段 | Fact 及成員 DTO derive Ord,合成後全序排序 | 接受 |
| F001 A4 | 無後端成功時 erLevel | 取 ModuleLevel(能力下限),真相由 erReports 表達 | 接受 |
| F001 A5 | 未選中的後端是否進 erReports | 進,brUsed=False + 未選中原因 | 接受 |
| F001 A6 | 調度引擎需為測試匯出 | 比照 project-meta 慣例,haddock 註明非契約面 | 接受 |
| F001 A7 | 本階段註冊表空,extract 回空事實流 | 視為階段一預期語意,T7 測試釘住 | 接受 |
| F002 A1 | ExtractOptions/ProjectMeta 都不帶專案根目錄,後端開不了檔(sfPath 是 repo 相對) | 建議 ExtractOptions 增 rootDir;純核心 scanSource 不碰路徑 | 接受:ExtractOptions 增 rootDir(已回寫契約) |
| F002 A2 | fmModule 權威來源 | 以檔案 module 標頭為唯一權威,不與 sfModule 交叉比對 | 接受 |
| F002 A3 | 讀檔/解碼失敗的檔案 | 不產生 FactModule(規則 7 優先) | 接受 |
| F002 A4 | import 區邊界判定 | 第一個「第 0 欄、非空、非 import/module/CPP」的 token | 接受 |
| F002 A5 | 重複與自我 import | 照字面出事實,不去重 | 接受 |
| F002 A6 | 驗收方式 | 以 knot 手動唯讀實跑,app 層加 renderFactSummary | 接受 |
| F002 A7 | 去註解狀態機範圍 | 只追字串字面量與巢狀區塊註解,不追字元字面量 | 接受 |
| F001 A8 | 後端成功時 brDetail 該填什麼(契約只定義未用時的原因) | brUsed=True 時 brDetail="",使「非空 detail ⇔ 有降級原因」 | 接受 |
| F002 A8 | F001 的 T7 測試以「註冊表為空」為前提,與 F002 填實註冊表衝突 | 保留測試名,斷言改為驗證 extract 委派給 registeredBackends | 接受 |

## 階段結果

### 階段一:S1 骨架

- F001 fact-contract(設計 opus/實作繼承):7/7 Todo、測試 44/44;ExtractOptions 增 rootDir 的契約變更已落實並回寫文檔
- F002 import-scan(設計 opus/實作繼承):8/8 Todo、測試 53/53;MagicFarmer 58 檔/581 事實、particle-magic 44 檔/386 事實,逐檔對帳(module 標頭、import 行數)0 筆不符,兩標的唯讀無殘留
- 委派插曲:F001 設計遭 Fable [reasoning_extraction] 誤判中斷一次,改派 opus 完成;F002 設計預防性改派 opus
- arch-audit subsys:資料流管線(窄化→選擇→探測→best-effort→合成)與契約一致;規則 1/3/7/8 逐條落實;SRP 清楚、無邊界外洩、模組介面零漂移
- 閘門裁決:15 條假設全部接受;F001 A8 補進 design.md 的 brDetail 語意;測試改名 test_extract_entry_registry;E001 升為全域 G-E001(涵蓋兩子系統的測試用匯出);階段一收尾以 PR 整合

### 契約類決定(2026-08-21 階段二批次澄清,已回寫 design.md)

四項全部源自開跑前的工具鏈實測,不是推測:

| # | 實測發現 | 決定 | 回寫位置 |
|---|---|---|---|
| C1 | hiedb 的 `occ` 有**四類** namespace 前綴(實測 knot-hs 自身:`v:` 108、`c:` 95、`t:` 50、`f<父型別>:` 166+),契約的 `NameSpace` 只有二值 | **擴充成四值** `ValueNs` / `DataConNs` / `TypeNs` / `FieldNs`,與 hiedb 一對一。理由:graph-core 用 (Module, Occ, namespace) 鑄決定性節點 id,壓縮成二值會讓不同 GHC 實體可能撞出同一個 id | 事實流 DTO › `NameSpace` |
| C2 | `refs.is_generated` 是 hiedb 的現成事實(實測 672/4740 = 14% 為 deriving 產生),但 `Fact` 無欄位承載;而契約要 graph-core 靠「異常 span」猜 | `FactRef` 增 `frGenerated :: Bool` **原樣轉載**,extraction 不過濾不詮釋;取捨仍是 graph-core 的職責,但它從此有事實可依 | `FactRef`、抽取規則 4a(新增) |
| C3 | span 包含 join 是**一對多**(實測同一 ref 同時落在 `c:QueryNode` 與 `t:QueryNode` 內),但 `frFromDecl` 是單值 | 取 **span 最小(最內層)** 者;同大小再依 `(qnSpace, qnOcc)` 字典序破雷 | 抽取規則 4 |
| C4 | hiedb 0.8 的 schema **沒有 instance 表**;本專案 `grep "^instance"` 亦為空(全是 deriving)。`FactInstance` 需要的「class + instance 標頭」無直接來源 | **本階段不產出 `FactInstance`**,建構子保留但零邏輯;`implements` 邊另開 feature。hiedb-facts 契約卡的驗收標準與「明確不做」已改寫 | hiedb-facts 契約卡 |

**留給 graph-core 階段二的前置說明**:C1 與 C2 都動了 graph-core 將要消費的 DTO,但目前 `Knot.Graph.Types` 只 import `DeclKind` 當不透明 payload、尚未 pattern-match `FactRef`,所以**對現有程式碼零影響**。graph-core 的 decl-nodes / decl-edges 開工時要按四值 namespace 鑄 id、並用 `frGenerated` 取代原本規劃的 span 啟發式。

### 階段二 W3 回報後的裁決(2026-08-21)

| 來源 | 假設 / 發現 | 採取的判斷 | 裁決 |
|---|---|---|---|
| F003 A1 | `Backend` 值本身與註冊表歸屬未定 | F003 只出 `probeHiedb` **不註冊**,避免 `bRun` 未實作的後端在有 hiedb 的機器上直接壞掉;由 F004 組裝註冊 | 開工前接受 |
| F003 A2 | `ensureIndex` 簽名無警告通道,但契約卡要「首次建立 `.knot/` 印提示」、library 又不能印 | 提示掛 `IndexHandle` 的 `ihNotes`,F004 的 `bRun` 併入 `[ExtractWarning]` | **裁決:採納**。`IndexHandle` 內容本屬 Level 3,加欄位不動契約簽名;本專案第六次碰到「契約少一條通道」 |
| F003 A3 | `dbPath` 相對路徑的錨點未定義(採行程 cwd),但 `hieDirOverride` 是 root 相對 | 行程 cwd | **裁決:改為 root 相對**,已回寫抽取規則 6。同一支 CLI 的兩個路徑覆寫旗標不該有兩套規則 |
| F003 A4 | 相容性檢查深度 | probe 只讀第一個 `.hie` 檔頭(O(1)),混版交給 index 攔 | 接受 |
| F003 A5 | 規則 8 不拘束 `ihStats` | 它是本次執行的觀測值,兩次不同正是驗收證據 | 接受 |
| F003 A6 | fixture 測試的唯讀性 | 一律複製到暫存目錄再跑,版控樹全程唯讀 | 接受 |
| F003 A7 | tasty 無內建 skipped 狀態 | 不加 `tasty-expected-failure`,自行印原因 + 跳過數,佔位節點名含跳過數 | 接受 |

**W3 的額外實測**(subagent 在設計階段自行補做,直接影響設計):

1. `hiedb` **不會自建 `-D` 的父目錄** → exit 1 `ErrorCan'tOpen`;`.knot/` 必須由本 feature 建,那也正好是「首次建立」的判斷點
2. `hiedb index` **接受單一 `.hie` 檔參數**(help 只寫 DIRECTORY)→ 可逐檔傳 `hieFiles`,天然排除幽靈檔
3. **對不存在的路徑回 exit 0**(`0 indexed, 0 skipped`)→ exit code 不足以判成功,**必須解析 `Completed!` 計數**
4. **單一 0-byte 假 `.hie` 會讓整批 exit 1 中止** → project-meta 的幽靈過濾是硬相依;也印證現有 `test/fixtures/hie-conv/.hie/` 的空殼檔不能餵給 hiedb
5. 重跑實測:第一次 `2 indexed, 0 skipped`,第二次 `0 indexed, 2 skipped` → 驗收標準的「索引重用」改用**計數**而非計時,不受機器速度影響
6. hiedb 輸出**全走 stderr**,`readCreateProcessWithExitCode` 捕獲兩股即滿足「library 不印」
7. **`.hie` 檔頭是 `"HIE" + "9141" + \n + "9.14.1" + \n`**,與 `showVersion System.Info.fullCompilerVersion` 格式**完全一致** → ADR-001 的版本鎖可在 probe 階段就地檢出,不必等 index 炸掉
8. `ghc -fno-code -fwrite-ide-info -hiedir .hie -isrc …` 可直接產 fixture 用的真實 `.hie`(884B / 1026B),不需 cabal、不留 `dist-newstyle`

### 🔴 跨子系統缺口(W3 發現,開發者裁定本次一併補接)

`app/Knot/App/Cli.hs:238-243` 把 `hiedbExe` 與 `dbPath` **寫死 `Nothing`**,haddock 還引用著 export-query F004 的假設 A8(「契約卡的六旗標不含 `--db` / `--hiedb`」);但 `system.md` 的 CLI 契約現已明列這兩個旗標。

**成因是編排者的疏漏**:export-query 階段二閘門裁決 A8「接受」並把兩個旗標補進 `system.md` 時,沒有同時指出既有實作要跟上,導致 Level 1 契約承諾了程式碼沒有的旗標。

**後果**:目前惰性(hiedb 後端尚未註冊),但 **F004 一註冊,對任何專案跑 `knot extract` 都會在對方建 `.knot/` 且無法改道**——直接違反 system.md「驗收標的不得異動」的唯讀例外機制。

**裁決**:本次一併補接,列為 **F004 委派的前置小任務**(兩個旗標 + 兩個欄位賦值),在 hiedb 後端註冊之前完成。
