# knot-hs

讀 Haskell 專案,產出 [dev-flow](https://github.com/utomore) 相容的 `codegraph.json`
程式碼知識圖。**一個執行檔、一個命令、零前置**:

```bash
knot extract .
```

dev-flow 的 `/arch-audit` 等接點在專案根目錄有 `codegraph.json` 時,能直接算出子系統
依賴矩陣、循環依賴、跨界引用與架構 hub;`/feature-design`、`/bugfix` 用它定位。但
dev-flow 唯一登記的產生器 graphify **不支援 Haskell**。knot-hs 填這個洞——而且
Haskell 的原料更好:GHC 的 `.hie` 是型別檢查後、名稱全部解析完的**事實**,不是啟發式
猜出來的。

- **兩層圖,缺一不可**:module 節點 + `imports` 邊,加上頂層宣告節點 + `calls` / `uses` 邊。
  任一層拿不到就明確失敗,不產出「只有 module 層」的半成品(理由見 ADR-006)
- **零前置**:不用裝 hiedb、不用改目標專案的 `.cabal`、不用自己跑 `-fwrite-ide-info`。
  `.hie` 由 knot 自行驅動插樁建置產生,索引由內嵌的 hiedb library 建
- **決定性**:零 API key、零 LLM;同樣輸入 byte 級相同的輸出
- **對目標專案唯讀**:唯一的副作用是根目錄下的 `.knot/` 快取(自帶 `.gitignore`),
  不碰對方的 `dist-newstyle`、不改任何既有檔案

## 需求

| 項目 | 版本 / 說明 |
|---|---|
| GHC | **9.14.1**(base 4.22)——見下方版本鎖 |
| cabal-install | 3.16 以上 |
| 目標專案 | 必須能 `cabal build all` 成功。這是唯一的前置條件,也是對方專案本來就該滿足的 |

不需要安裝 hiedb(已嵌入),不需要目標專案事先產出 `.hie`。

### ⚠ GHC 版本鎖(最重要的限制)

`.hie` 是 GHC 內部結構的二進位序列化,讀取器在 `ghc` library 裡、精確比對版本。knot
自己產 `.hie` 又自己讀,**兩端必須同版**:這份原始碼鎖 GHC 9.14.1,所以它只掃得了用
9.14.1 建置的專案。目標專案若以 `with-compiler` 釘了別的 GHC,knot 會以
`VersionMismatch` 失敗並印出該用哪個版本重裝:

```
extract: .hie files were produced by GHC 9.12.2, but this knot was built with GHC 9.14.1
extract: install a matching knot: cabal install knot-hs -w ghc-9.12.2
```

跨版本的正解是每版 GHC 各裝一份 knot。這是刻意的取捨,理由見
`.design/adr/ADR-001-ghc-version-locked-toolchain.md`。

## 安裝

```bash
git clone https://github.com/utomore/knot-hs
cd knot-hs
cabal install exe:knot
```

裝到 cabal 的 installdir(用 `cabal path --installdir` 查,Windows 上常見是
`C:\cabal\bin`),確認它在 `PATH` 上。repo 內的 `cabal.project` 已含 hiedb 在 GHC 9.14
上需要的 `allow-newer: hie-compat:base, hie-compat:ghc`,不必自己加。

## 快速上手

```bash
cd /path/to/your-haskell-project
knot extract .
```

產出 `./codegraph.json`。第一次會比較久——knot 要把你的專案完整建一次;之後增量。
這一行做了四件事:

1. **project-meta**:解析 `.cabal` / `cabal.project`,列出 component 與原始碼檔、判定
   test-suite / benchmark 的排除(預設排除,`--include-tests` 納入)
2. **extraction**:對你的專案跑一次 `cabal build all --builddir=.knot/build`(帶
   `-fwrite-ide-info`),讓每個 component 的 `.hie` 落在 cabal 自己的輸出目錄;再用內嵌的
   hiedb 建 `.knot/hiedb.sqlite` 索引;同時掃 import 行。兩者都成功才往下
3. **graph-core**:組出 module 與宣告兩層節點、五種邊,過濾 deriving / TH 產生碼,丟掉指向
   外部套件的邊並統計
4. **export**:寫 `codegraph.json`,把丟棄 / 過濾 / 去重的統計印到 stderr

`.knot/` 是純快取,第一次建立時自動寫入內容為 `*` 的 `.gitignore`。刪掉只會讓下次變慢。

### 掃別人的專案

`.knot/` 固定在目標專案根目錄、不提供改道(它與 `dist-newstyle` 同性質);
`codegraph.json` 可用 `--output` 改道:

```bash
knot extract /path/to/other --output /tmp/other.json
```

對方專案**不會**被改動:knot 的建置用獨立 builddir,不碰既有的 `dist-newstyle`;
`.knot/` 自帶 `.gitignore`,`git status` 看不到它。

### 指到哪、建哪

knot 對目標目錄下 `--project-dir=<PATH>`:有 `cabal.project` 就用它,沒有就以該目錄的
`.cabal` 為隱含專案,**不會往上層找別人的 `cabal.project`**。monorepo 的子套件若依賴
上層 `cabal.project` 的設定,請指向 monorepo 根。

## 指令

### `knot extract`

```
Usage: knot extract [PATH] [-o|--output FILE] [--include-tests] [--strict]
                    [--summary meta|facts|graph]

  PATH                     要掃的專案根目錄(預設 ".")
  -o,--output FILE         輸出路徑(預設 <PATH>/codegraph.json)
  --include-tests          納入 test-suite 與 benchmark component(預設排除)
  --strict                 有任何警告就 exit 1
  --summary meta|facts|graph
                           改印該站的唯讀摘要到 stdout,不寫 codegraph.json
```

`--summary` 是對帳用的唯讀路徑:`meta` 印套件 / component / 檔案清單與歸屬(不跑建置),
`facts` 印事實筆數(依種類分計),`graph` 印節點與邊的統計。

### `knot query`

讀既有的 `codegraph.json` 回答導航問題,只走依賴類邊(`contains` 這類結構邊不算)。

```
knot query find KEYWORD                         # id 或 label 含 KEYWORD 的節點(不分大小寫)
knot query reachable ID [--reverse] [--depth N] # 從 ID 可達的節點;--reverse 改問「誰依賴它」;--depth 只回 N 跳內
knot query path FROM TO                         # 兩點最短路徑
knot query rank [--top N]                       # 連通度排名(預設前 10)
knot query tests-of ID                          # 哪些測試(直接或間接)依賴 ID

  --graph FILE                 要查哪份圖(預設 ./codegraph.json,子命令共用)
  --level all|module|decl      先把圖收斂到一層再查(預設 all;子命令共用)
  --scope product|tests|all    先把圖收斂到產品碼或測試碼再查(預設 product;tests-of 不受影響)
```

`--level module` 只留 module 節點與它們之間的 `imports` 邊——「誰依賴誰」「哪個 module 是
hub」這類架構問題用這一層;`--level decl` 只留宣告節點與 `calls` / `uses` / `implements`。
層由 `contains` 邊推得(宣告節點 = 某條 `contains` 的目標),不靠 id 長相猜。
常用組合:

```bash
knot query --level module reachable Knot.Extract.Pipeline --depth 1            # 直接 import 了誰
knot query --level module reachable Knot.Extract.Pipeline --depth 1 --reverse  # 誰直接 import 它
knot query --level module rank --top 10                                        # module 層 hub
```

`--graph`、`--level` 與 `--scope` 是 `knot query` 自己的選項,要寫在子命令**之前**(optparse 的慣例:
子命令之後的旗標屬於該子命令)。

#### 測試碼:`--scope` 與 `tests-of`

`knot extract --include-tests` 會把 test-suite / benchmark 也建起來納入圖中,每個節點以
選填欄位 `component`(`<套件>:<component>`,如 `knot-hs:test:knot-test`)標記所屬。查詢時
**預設 `--scope product`**:測試節點被收斂掉,`rank` / `reachable` 不會被「什麼都 import」
的測試檔灌水——輸出與不帶 `--include-tests` 的圖相同。`--scope tests` 只看測試碼,
`--scope all` 兩者都看。

```bash
knot query tests-of Knot.Query.Load.restrictLevel   # 改它會壞哪些測試(反向可達、只留測試節點)
knot query --scope tests rank --top 5                # 測試碼自己的 hub
```

`tests-of` 永遠在整張圖上找(不受 `--scope` 影響);圖裡沒有任何測試節點時會在 stderr
提示重跑 `knot extract --include-tests`。

節點 id 的長相:module 是裸名(`Demo.Core`),值宣告是 `<module>.<occ>`
(`Demo.Core.render`),型別宣告多一個 `#t`(`Demo.Core.Foo#t`,與建構子 `Demo.Core.Foo`
不碰撞)。同名 module(多個 executable 各有 `Main`)整組改用 `<module>@<source_file>`。

## 輸出格式

`codegraph.json` 的欄位規格由 dev-flow 定義(細節見 `.design/adr/ADR-003`):

```json
{
  "directed": true,
  "built_at_commit": "648009c1b81a",
  "nodes": [
    {"id":"Demo.Core","label":"Demo.Core","source_file":"src/Demo/Core.hs"},
    {"id":"Demo.Core.render","label":"render","source_file":"src/Demo/Core.hs","source_location":"L12"}
  ],
  "links": [
    {"source":"Demo.Render","target":"Demo.Core","relation":"imports",
     "confidence":"EXTRACTED","source_location":"L3"},
    {"source":"Demo.Core","target":"Demo.Core.render","relation":"contains","confidence":"EXTRACTED"}
  ]
}
```

- 五種 relation:`imports` / `calls` / `uses` / `implements`(依賴類,下游算進依賴圖)、
  `contains`(結構類);`implements` 來自明寫的 `instance` 宣告(見已知限制 2)
- `confidence` 恆為 `EXTRACTED`——GHC 給的是事實,不是推測
- `built_at_commit` 取自目標專案的 `git rev-parse HEAD`(唯讀);不是 git repo 就省略
- **byte 級決定性**:同一份輸入的序列化結果完全相同(欄位順序、清單順序、換行一律 `\n`)

## 錯誤處理

分兩層,對應兩種 exit code:

| 情況 | 行為 | exit |
|---|---|---|
| **整體失敗**:目標專案建不起來(`BuildFailed`)、`.hie` 的 GHC 版本與 knot 不合(`VersionMismatch`)、索引整體失敗(`IndexFailed`)、納入範圍內零個原始檔(`NoSources`) | 印原因到 stderr,**不寫** `codegraph.json` | **1**,與 `--strict` 無關 |
| **單檔 best-effort**:個別原始檔解析失敗、個別 `.hie` 對映不到納入範圍內的原始檔(例如模組已刪、舊 `.hie` 還在快取裡) | 警告到 stderr、跳過續跑,仍產圖 | 0;`--strict` 時**任何警告**改為 1 |

沒有「降級」:拿不到 decl 層不會退成 module 級圖。module 級的關聯無法協助寫 code,把它
當成功回報比明確失敗更糟——下游會拿它當真。

`cabal build` 的輸出會即時轉發到 stderr,建置失敗時尾段進錯誤訊息,你看到的就是 cabal
看到的。

## 成本

| | 第一次 | 之後(沒改動) | 改一個檔之後 |
|---|---|---|---|
| 發生什麼 | 目標專案完整建置進 `.knot/build/` + 全量索引 | cabal 的 up-to-date 檢查 + 索引增量 | 重編那個模組 + 索引該檔 |
| knot-hs 自身(27 個模組) | 即目標專案的 `cabal build all` 時間 | **2.5 秒**(含 cabal 檢查) | 幾秒 |
| MagicFarmer(141 個 `.hs`,h-raylib 遊戲) | **66 秒**(刪掉 `.knot/` 後實測) | **1.4 秒** | — |
| particle-magic(223 個 `.hs`,9 個 component) | **35 秒** | **0.7 秒** | — |

建置時間是 cabal / GHC 的成本,不是 knot 的——抽取與建圖本身在幾秒內。上表兩個
外部專案的數字量自 2026-08-23(Windows / GHC 9.14.1),cold 與 warm 產出的
`codegraph.json` byte 相同,標的的 `git status` 前後皆為空。細節見
`.design/system.md`「開發階段」。

## 已知限制

### 1. GHC 版本鎖

見上方「需求」。knot 與目標專案必須同版 GHC,不合時整體失敗。

### 2. `implements` 邊只涵蓋明寫的 `instance`

hiedb 0.8 的索引沒有 instance 表,所以 knot 直接讀 `.hie` 的 AST 取 instance 宣告
(ADR-007)。每個明寫的 `instance … where` 成為一個 `<module>#i:<標頭原文>` 節點,
對它的 class 發一條 `implements` 邊(class 在外部套件時無邊,計入丟棄統計)。
`deriving` 的任何形式(子句、standalone、`anyclass`)在 `.hie` 裡沒有節點,也不會出現
在圖上——那不是使用者畫的架構線。標頭原文保留使用者寫法(多行收斂為單一空白),
`instance (Show a) => Foo [a]` 的 context 會留在節點 id 裡。

### 3. 沒列在 `exposed-modules` / `other-modules` / `main-is` 的檔案不屬於任何 component

knot 判斷「哪個檔屬於哪個 component」看兩件事:檔案落在該 component 的
`hs-source-dirs` 下,**且** 由路徑推得的 module 名在它的 `exposed-modules` /
`other-modules` 清單內(或路徑就是它的 `main-is`)。這是 Cabal 本身的語意,所以
`hs-source-dirs` 省略(預設 `.`)的 component 也只會認領它真正宣告的 module,不會把
test fixture、範例碼、腳本整個 repo 吃進去。

代價是 `.cabal` 漏列的 module(cabal 建置時會警告「modules not listed」的那些)在 knot
眼裡沒有 owner:module 名退回大寫尾綴法推導,納入與否退回路徑啟發式(頂層 `test/`、
`tests/`、`bench/` 排除、其餘納入)。補齊 `other-modules` 即可——那同時也是 cabal 的
要求。(`.design/subsystems/project-meta/enhancements/E001-component-module-list-ownership.md`)

### 4. 同名 module 的 decl 層只有一份

`executable` 與 `test-suite` 各有 `Main` 時,兩者的 `.hie` 落在 cabal 各自的 component
輸出目錄,**不會**互相覆蓋(這是 S5 之前的缺陷 G-B001 的根因,現已由佈局消除)。但
graph 層的 module 節點以名字為 id,同名組會以 `<module>@<source_file>` 消歧;`--include-tests`
時兩個 `Main` 都會出現在圖上。

### 5. 驗證覆蓋面

實跑驗證過三個專案(兩個外部驗收標的 + knot 自己)。更奇特的 cabal 結構(Backpack、
custom `Setup.hs`、複雜 conditional、`build-type: Configure`)沒有實測過。conditional 以
預設 flag 值與本機平台攤平,非預設 flag 組合的原始碼不會被納入。

### 6. Windows 路徑長度(MAX_PATH)

knot 要 GHC 把 `.hie` 寫進 `<root>\.knot\build\build\<arch>\ghc-<ver>\<pkg>-<ver>\<kind>\<comp>\build\<comp>\<comp>-tmp\extra-compilation-artifacts\hie\<Module>.hie`,
比專案自己的 `dist-newstyle` 長 12 個字元。repo 路徑 ≥ 約 45 字元、套件 / module 名偏長的
monorepo 可能超過 Windows 預設的 260 字元上限,GHC 會以 `CreateFile` 失敗、knot 回報
`BuildFailed` 並附一行 `windows MAX_PATH: … N characters` 的提示。解法二選一:把專案放到
(或 `subst X: <root>` 對映到)較短的路徑;或開啟 Windows 長路徑支援。被排除的 component
(test-suite、benchmark)自 B001 起一律明確 `--disable-*`,不會再因目標專案自己的
`tests: True` 被建出來——它們的路徑最長,也最先撞到。

### 7. 不做的事

不做 LLM 語意推測邊、不做社群偵測、不做視覺化、不做多語言(只服務 Haskell)。
理由見 `.design/system.md`「非目標」。

## 開發

```bash
# 建置品質閘門(唯一合法的零警告驗收指令,cabal clean 不可省略)
cabal clean && cabal build all --enable-tests --ghc-options=-Werror

# 測試(144 條;含五份黃金 codegraph.json 的 byte 級回歸與 knot-hs 自掃)
cabal test --enable-tests
```

`cabal clean` 是必要條件不是保險:少了它,`-Werror` 與 `-fforce-recomp` 都會回報
「乾淨」而實際不然,因為 GHC 的重編檢查不理會警告旗標的變動、增量建置不重印警告。
詳見 `.design/enhancements/G-E002-wall-clean-build.md`。

### package 佈局

| stanza | 內容 | 誰依賴它 |
|---|---|---|
| `library knot-internal`(private) | `src/` 全部模組 | `test-suite knot-test` |
| `library`(公開) | 只 re-export 四個子系統的進入點與對外 DTO(9 個模組) | `executable knot` |

組裝層碰到非契約模組是編譯錯誤,不是靠自律(ADR-004)。

### 架構文件

`.design/` 是這個專案的設計樹,以 dev-flow 的三層階梯法維護:

| 路徑 | 內容 |
|---|---|
| `.design/system.md` | Level 1 主架構:系統邊界、對外契約、子系統劃分、通訊拓撲、進度 |
| `.design/subsystems/<slug>/design.md` | Level 2 子系統架構(project-meta、extraction、graph-core、export-query) |
| `.design/subsystems/<slug>/features/` | Level 3 feature 設計(含 TodoList 與 1-to-1 測試對照) |
| `.design/adr/` | 架構決策紀錄(ADR-006 是目前架構的依據) |
| `.design/enhancements/`、`.design/bugfixes/` | 跨子系統的優化與缺陷文檔 |

## 授權

尚未指定。
