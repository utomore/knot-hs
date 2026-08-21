---
id: extraction-build
type: build-log
title: extraction-build
description: 委派展開 extraction 兩階段(S1 骨架、S3 函式級)
status: done
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
| 階段二:S3 函式級 | W3 | hiedb-driver | impl-done |
| 階段二:S3 函式級 | W4 | hiedb-facts | impl-done |

開發者決定本次只跑階段一(主架構 S1 里程碑優先,S3 之後接續模式回來);無跨子系統未完成依賴(project-meta done)。

## 委派決策記錄

| # | 問題 | 開發者決定 | 影響範圍 |
|---|------|-----------|---------|
| D1 | ExtractWarning 欄位形狀 | 比照 MetaWarning:{ ewSource, ewMessage },已回寫契約 | F001、後續全部 |
| D2 | ModuleName 型別來源 | 直接共用 Knot.Meta.Types 的定義,不重複定義,已回寫契約 | F001、F002 |
| D3 | 無 module 標頭的 .hs 檔 | 依 Haskell 語意視為 Main(fmFile 區分),已回寫契約 | F002 |
| D4 | 測試框架/命名空間/唯讀(沿 project-meta 展開的全域決定) | hedgehog+tasty;Knot.Extract.*;驗收標的絕對唯讀;版本號 0.0.1.0 凍結;`-Wall` 零警告(**2026-08-22 更正:此項從未真正成立,見 G-E002**) | 全部 |
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
| hiedb-driver | F003 | F003-hiedb-driver.md | 繼承 | 繼承 | impl-done |
| hiedb-facts | F004 | F004-hiedb-facts.md | 繼承 | 繼承 | impl-done |

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

### 階段二 W4 回報後的裁決(2026-08-21)

W4 的 subagent 到 **hiedb 0.8 與 sqlite-simple 的原始碼**複查行為成因,挖出三項實質事實:

| 來源 | 發現 | 裁決 |
|---|---|---|
| F004 A2 | `occ` 前綴實為**五種**,多一個 `z:`(型別變數,見 hiedb `HieDb/Types.hs` 的 `toNsChar`)。編排者複驗:**knot-hs 自身索引的 decls 與 refs 皆為零筆**,是「可能」而非「實際」 | **跳過 `z:` 並彙整成一則警告**,`NameSpace` 維持四值。理由不只是省事:型別變數是簽名內的區域名字、不是架構實體,鑄成圖節點無意義。已回寫 `NameSpace` 註記 |
| F004 A1 | **hiedb 丟棄了 GHC 的 `DeclType`**(其 `HieDb/Utils.hs` 的 `goDec` 只存 `is_root`)→ `DeclKind` 的七個建構子無法忠實推導,只能由 namespace 粗推 | **接受粗推並在契約註明限制**。七個建構子是「抽取契約的目標精度」,不是每個後端都交得出來;消費端不得假設能分辨 class。精度要補滿得等 ADR-002 預留的第三後端。已回寫 `DeclKind` 註記 |
| F004 A3 | **`mods.hs_src` 是絕對路徑**(`makeAbsolute (srcBaseDir </> hie_hs_file)`),未給 `--src-base-dir` 時為 `NULL`;`mods.hieFile` 走 `canonicalizePath`。編排者複驗屬實:實測值為 `C:\Users\...\src\Knot\Query.hs`(Windows 反斜線) | 接受:改用「正規化 + 最長後綴比對 `sfPath`」而非前綴相減,並取 `sfPath` 原文以保證與 import-scan 的 `fmFile` 逐字一致 |

其餘假設 A4(丟棄 `refs.unit`)、A5(外部 ref 全照出,`gsDroppedExternal` 需要)、A6(驗收標準 4 的「全部可對映」解讀為專案內側)、A7(`bRun` 以例外回報失敗)、A8(`ihNotes` 照樣併入,`--strict` 首跑 exit 1 不特殊處理)、A9(`FieldNs` 丟棄父型別)全部接受。

### Level 1 調整(開發者裁定)

`system.md` 的 S3 里程碑原寫「兩層節點、`calls`/`implements` 邊」,依 C4 已改為「兩層節點、`calls` / `uses` 邊」,並在「開發階段」補一段說明 `implements` 為何延後(hiedb schema 無 instance 表)。**里程碑是驗收標準,留著一個沒人要做的項目會讓 S3 永遠無法宣告完成。**

### 留給 graph-core 階段二的前置(W4 發現,編排者不跨子系統修改)

`graph-core/design.md` 的邊推導表仍只列 `FactRef`(target 為 `ValueNs`)→ `RCalls`、(`TypeNs`)→ `RUses`,**`DataConNs` / `FieldNs` 未涵蓋**(C1 擴充後才出現的兩個值)。graph-core 階段二開工前需裁決補齊,否則兩個 namespace 的引用會靜默落空。

### 階段二:S3 函式級

- **F003 hiedb-driver**(設計繼承 / 實作繼承):Todo 11/11、測試 **106/106**;`src/Knot/Extract/HiedbDriver.hs`
- **F004 hiedb-facts**(設計繼承 / 實作繼承):Todo 11/11、測試 **118/118**;`src/Knot/Extract/HiedbFacts.hs`,並完成三項前置(DTO 補齊 C1、CLI 補接 `--hiedb`/`--db`、註冊 hiedb Backend)
- **無 hiedb 的環境**:111 通過 + **9 跳過**(F003 五 + F004 四),印明原因。D7 的機制實測有效
- **契約補完(實作階段發現)**:`fromDecl` 候選集**不得以 `is_root` 過濾**。實測 knot-hs 自身索引:`v:` 前綴 **108 筆全部 `is_root = False`**(含 `buildGraph` / `extract` / `writeCodegraph`),只有 `c:` 95 筆與 `t:` 50 筆為 True。帶著該過濾,`calls` 邊會**全空而查詢本身不報錯**。已回寫抽取規則 4
  - **這個坑同時騙過了編排者的 spike 與 F004 的設計查證表**:兩邊都用了 `is_root = 1` 且「看起來能跑」,因為回傳的每一筆都是型別。F004 實作時才發現函式本體被 100% 靜默排除
- **自我驗收實測**(knot-hs 自身,唯讀):`hieFiles = 31` → `erLevel = DeclLevel`、兩後端 `brUsed = True`、**FactDecl 623 / FactRef 7265 / `frGenerated = True` 846(11.6%)/ 警告 0**;`knot extract . --summary facts` → `facts: 8173 total`
- **ADR-002 降級承諾實測成立**(編排者於閘門執行):兩個驗收標的都沒有 `.hie`,`knot extract` 正確降為 `ModuleLevel`、印明原因(`backend hiedb unused: hie files unavailable`)、**exit 0**、仍產出完整 module 級圖(MagicFarmer 62 節點/266 邊、particle-magic 46/127 含 1 條碰撞警告),且**兩者皆未被建 `.knot/`**。這是 `--db` 補接後的第一次真實驗證
- **arch-audit subsys 發現**(依嚴重度):
  1. (中)**`-Wall` 新增 1 筆警告**:`HiedbDriver.hs:160` 的 `head (hieFiles hie)` 觸發 `-Wx-partial`(前一分支有 `null` 保護,執行期安全)。**編排者更正**:F003 checkpoint 時轉述的「新增程式碼零警告」不成立;clean 重建後的真實總數是 **9 筆**(既有 8 + 本次 1)
  2. (低)`renderFactSummary` 的分類計數落後:8173 筆事實只分類出 31 modules + 254 imports,約 7888 筆 decl 層事實沒有計數行(該函式寫於階段一,decl 事實出現後就不完整)。屬 export-query 的 `Summary.hs`
  3. (低)`hiedbBackend`(`Backend` 值)住在 `HiedbFacts` 而非 `HiedbDriver`,與 `design.md` 模組職責表略有出入——F003 假設 A1 已裁決如此(避免 `bRun` 未實作的後端提早壞掉),但職責表未同步
  4. (資訊)`<repo>/.hie/` 留有 31 個檔(已 gitignore)。留著讓 selfcheck 實跑;但刪模組而未重產會讓該測試變紅,`rm -rf .hie` 即回到跳過分支
  5. (資訊)圖仍是 module 級 31 節點 / 86 邊——**decl 事實已產出但未進圖**,因為 graph-core 階段二(decl-nodes / decl-edges)尚未實作。這是 S3 的下一步
- **契約卡對帳**:兩張卡的負責模組、Level 2 介面、資料流段落與實作相符;`ensureIndex` / `readIndexFacts` / `Backend` 四欄位簽名一字不差(F004 複驗 F003 真實原始碼,零落差)

### 階段二閘門裁決(2026-08-22)

1. **發現 1(`-Wx-partial`)當場修掉**:`HiedbDriver.hs:160` 的 `head` 換成全函式寫法。它是本輪造成的,不該留給別人。
2. **另開 [[G-E002]] 追既有的 8 筆** `-Wincomplete-record-selectors`(全在 extraction/F002 的測試碼),並訂正 D8/D4 的「`-Wall` 零警告」描述。

   **這條慣例在四次閘門被宣告達成、實際從未成立**,根因值得記住:增量建置不重印警告,而想強制重編的直覺做法 `--ghc-options=-fforce-recomp` **會被 cabal 的 up-to-date 檢查短路**(輸出 `Up to date`、警告數 0,看起來像乾淨),`touch` 原始檔也無效(cabal 用內容雜湊)。**唯一問得出真話的是 `cabal clean` 後重建。** G-E002 的長期價值就在補上防退化手段。
3. 發現 2(`renderFactSummary` 分類計數落後)、發現 3(`hiedbBackend` 落點與模組職責表出入)屬低嚴重度,未開文檔,記錄於此供後續。
