---
id: ADR-006
type: adr
title: single-binary-zero-setup
description: knot 自行驅動建置並嵌入 hiedb,兩層圖缺一不可
status: accepted
created: 2026-08-22
updated: 2026-08-22
---

# ADR-006: 單一執行檔、零前置、兩層圖缺一不可

## 狀態(Status)

accepted(2026-08-22)。**取代 ADR-002**(hiedb 外部執行檔 + import-scan 降級保底)。
ADR-001(GHC 版本鎖)**維持有效**,理由見下。

## 背景(Context)

knot-hs 的存在理由是「graphify 不支援 Haskell,由 knot 填這個洞」。但實測比較
兩者的實際使用體驗,差距大到讓 knot 在別人的專案上幾乎不可用。

**graphify 的體驗**(2026-08-22 實測,對 2 個 `.mjs`、972 行):

```
graphify extract . --code-only --directed
→ 67 nodes / 78 edges,全部帶行號的函式級節點
```

裝一個執行檔,一個命令,**對目標專案零改動、零前置**。

**knot 當時的體驗**:

1. 使用者要另外 `cabal install hiedb --allow-newer=hie-compat:base`
2. 使用者要另外在目標專案跑 `cabal build --ghc-options="-fwrite-ide-info -hiedir .hie"`
3. 使用者要理解「module 級 / 函式級」這個純內部概念,並決定要哪一個
4. 不做 1、2 就只拿得到 module 級——**而 module 級的關聯無法協助寫 code**

前三項全是**實作洩漏到介面**。第四項是更根本的問題:降級模式產出的東西,對這個
工具的實際用途(定位、協助寫 code)沒有價值,卻讓工具「看起來能跑」。

### ADR-002 的三個判斷,兩個已經站不住

| ADR-002 的理由 | 2026-08-22 的複查 |
|---|---|
| 「hiedb 當 library 嵌入……**單一執行檔體驗最好**,但 `allow-newer` 的編譯連動風險直接進入自己的 build」 | 風險是真的(`hie-compat` 對 base 設 `<4.22`,GHC 9.14 是 4.22),但 **`allow-newer: hie-compat:base` 實測解析通過**。而它換到的正是 ADR-002 自己承認「最好」的那個體驗 |
| 「自己不 link `ghc` library」 | **做不到也沒必要**:hiedb 的 library 本身就 `build-depends: ghc >= 8.6 && < 9.15`。而且 ADR-001 早就把 GHC 版本鎖死了,再迴避 link `ghc` 是在防一個**已經被接受的風險** |
| 「hiedb 不可用時自動降級,module 級能力永遠可用」 | 降級產出的圖無法協助寫 code。「永遠可用」買到的是「永遠可以跑出一個沒用的結果」 |

### 已驗證的技術前提(spike,2026-08-22)

| 驗的事 | 結果 |
|---|---|
| `hiedb` 直接當 `build-depends` | ❌ 失敗:`hie-compat` 要求 `base < 4.22`,GHC 9.14.1 是 4.22 |
| 同上 + `allow-newer: hie-compat:base, hie-compat:ghc` | ✅ **解析通過** |
| hiedb 的 library 有沒有匯出索引能力 | ✅ `exposed-modules` 含 **`HieDb.Create`**(索引)、`HieDb.Query`、`HieDb.Utils` |
| `ghc-lib-parser 9.14.1.20251220` | ✅ 解析通過且**實際編譯成功**(降級路線的備案,本 ADR 不採用) |
| `cabal build --builddir=<獨立目錄>` 能否隔離插樁建置 | ✅ dry-run 確認會建到獨立目錄,不動目標專案的 `dist-newstyle` |

最後一項是關鍵:直接在對方的 `dist-newstyle` 加 `-fwrite-ide-info` 會讓 cabal 認定
組態改變,**把他既有的建置產物全部作廢**——他下次正常開發要重編一次。用獨立
builddir 就完全不碰。

## 決策(Decision)

### 1. `.hie` 的產生由 knot 驅動,不是使用者的事

`knot extract` 判斷 `.hie` 不存在或過期時,**自行**在目標專案跑

```
cabal build <all> --builddir=<knot 快取> --ghc-options="-fwrite-ide-info -hiedir <knot 快取>/hie"
```

獨立 builddir 保證不污染對方既有的建置產物。**完全自動,沒有旗標**:需要就建。

### 2. hiedb 改為 `build-depends` 嵌入

`knot-hs.cabal` 直接依賴 `hiedb`,`cabal.project` 加
`allow-newer: hie-compat:base, hie-compat:ghc`。索引走 `HieDb.Create` 的 library API,
不再 spawn 外部執行檔。**使用者不必安裝 hiedb,也不需要知道它存在。**

連帶消失的整層實作:執行檔 PATH 解析、`--help` smoke test、Windows 32767 字元的
命令列分批、exit code 與 stdout 解析。

### 3. 兩層圖缺一不可,不降級

module 層(imports 邊)與 decl 層(宣告節點、`calls` / `uses` 邊)**同時成立才算成功**。
任一層拿不到就**失敗並說明原因**,不產出部分圖。

理由:module 級的關聯無法協助寫 code,而這個工具的用途就是定位與協助寫 code。
「降級成 module 級」等於「跑出一個沒用的結果卻回報成功」——那比明確失敗更糟,
因為下游會拿它當真。

### 4. 使用者可見的概念砍到只剩一個命令

移除:`--backend`、`--module-only`、`--hiedir`、`--hiedb`、`--db`、能力分級
(`CapabilityLevel`)、後端選擇與降級回報。

**使用者只需要知道 `knot extract .`。**

## 考慮過的替代方案(Alternatives Considered)

1. **維持 ADR-002,只把 hiedb 嵌入**:解決「裝第二個工具」,但**沒解決**「要先跑一個
   命令產額外檔案」——而後者才是與 graphify 差距最大的地方。半套。
2. **改用 `ghc-lib-parser` 解析原始碼,完全不要 `.hie`**:零前置最徹底,單一執行檔,
   連 GHC 版本鎖都能解掉(parser 只讀文字)。**否決理由**:拿不到跨 module 的引用
   解析——同名、qualified import、re-export、shadowing 都得用啟發式猜。`calls` 邊
   的正確性是這個工具相對於「grep」的全部價值,不能猜。保留為「對方專案編不起來」
   時的降級備案(spike 已驗證可編譯),但不是主線。
3. **在程序內驅動完整 GHC API 做型別檢查,連 `.hie` 檔都不落地**:最乾淨,但要在
   knot 程序內重建對方的建置環境(package db、語言擴充、相依路徑)——那正是
   `hie-bios` / HLS 在解的難題,遠超個人工具的維護量。`.hie` 存在的意義就是把這件
   難事外包給對方自己的建置系統。
4. **保留降級,但預設關閉**:仍然要使用者理解兩種模式的差別。與「使用者只需要知道
   一個命令」直接衝突。

## 影響(Consequences)

**得到**

- `knot extract .` 是使用者需要知道的全部;與 graphify 的體驗對齊
- 沒有「級別」這個使用者可見概念,搜尋就是搜尋
- 消失一整層外部程序管理程式碼(PATH 解析、smoke test、命令列分批、輸出解析)
- 失敗是明確的失敗,不會產出「看起來成功但沒用」的圖

**付出**

- **第一次跑會編譯對方的專案**(相依套件走共用 store,只編他自己的模組)。之後
  cabal 增量,實測 knot-hs 改一行 19 秒
- `cabal.project` 需要 `allow-newer`,ADR-002 點名的編譯連動風險確實進入自己的 build
  ——這是刻意接受的交換
- 目標專案**必須建得起來**。建不起來就沒有圖,沒有中間地帶
- **ADR-001 的 GHC 版本鎖依然成立**,而且更硬:knot 要讀 `.hie`,就必須與產出它的
  GHC 同版

**不變**

- ADR-003(`codegraph.json` 是唯一對外契約)完全不受影響
- ADR-004(private sublibrary)、ADR-005(共用詞彙型別判準)不受影響
- import-scan 仍然存在,但**不再是「保底後端」**,而是 imports 邊的唯一來源
  (抽取規則 2 不變);它與 hiedb 兩者都必須成功

## 相關

- **取代 ADR-002**(該文檔 status 改 superseded)
- ADR-001:版本鎖維持有效,本決策使其更關鍵
- 2026-08-22 的 graphify 實測對照與三項 spike 證據
