# knot-hs

讀 Haskell 專案的 `.hie` 與 import,產出 [dev-flow](https://github.com/utomore) 相容的
`codegraph.json` 程式碼知識圖。

dev-flow 的 `/arch-audit` 等接點在專案根目錄有 `codegraph.json` 時,能直接算出子系統
依賴矩陣、循環依賴、跨界引用與架構 hub。但它唯一登記的產生器 graphify **不支援
Haskell**。knot-hs 填這個洞——而且 Haskell 的原料更好:GHC 的 `.hie` 是型別檢查後、
名稱全部解析完的**事實**,不是啟發式猜出來的。

- 決定性輸出:零 API key、零 LLM,同樣輸入同樣結果
- 對目標專案唯讀(索引快取可用 `--db` 改道到專案外)
- 兩層圖:module 級依賴 + 函式級呼叫

## 需求

| 項目 | 版本 / 說明 |
|---|---|
| GHC | **9.14.1**(base 4.22) |
| cabal-install | 3.16 以上 |
| `hiedb` 執行檔 | **選用**。函式級抽取需要;沒有時自動降級為 module 級 |

### ⚠ GHC 版本鎖(最重要的限制)

`.hie` 的格式綁 GHC 版本,**knot 必須用與目標專案相同的 GHC 編譯**。目前這份原始碼
鎖 GHC 9.14.1,所以它只掃得了同樣用 9.14.1 建置的專案。要掃別的版本,得用那個版本的
GHC 重新編譯 knot 一次。

這是刻意的取捨,理由見 `.design/adr/ADR-001-ghc-version-locked-toolchain.md`。

## 安裝

```bash
git clone https://github.com/utomore/knot-hs
cd knot-hs
cabal install exe:knot
```

裝到 cabal 的 installdir(用 `cabal path --installdir` 查,Windows 上常見是
`C:\cabal\bin`),確認它在 `PATH` 上。

### hiedb(選用,函式級抽取才需要)

```bash
cabal install hiedb --allow-newer=hie-compat:base
```

`--allow-newer` 是必要的:hiedb 的 `hie-compat` 相依對 base 設了上界,GHC 9.14 超出
該範圍,但實測加上這個旗標後完全可用(見 `ADR-002`)。裝好後 knot 會自動從 `PATH`
找到它,也可以用 `--hiedb PATH` 指定。

## 快速上手

### 只要 module 級依賴圖(零設定)

架構檢測要的就是這一層——依賴矩陣、循環依賴、跨界引用全部只需要 module 級。

```bash
cd /path/to/your-haskell-project
knot extract . --module-only
```

產出 `./codegraph.json`。不需要 `.hie`、不需要 hiedb。

### 要函式級呼叫圖(需要 `.hie` 與 hiedb)

目標專案得先產出 `.hie`:

```bash
cd /path/to/your-haskell-project
cabal build all --ghc-options="-fwrite-ide-info -hiedir .hie"
knot extract .
```

`--backend auto`(預設)會在 hiedb 可用時輸出兩層圖,不可用時自動降級為 module 級
並在 stderr 說明,而不是整個失敗。

> **注意**:上面刻意**沒有**加 `--enable-tests`。加了會踩到已知缺陷 G-B001,見
> 「已知限制」。

### 掃別人的專案時保持真正唯讀

函式級抽取預設會在目標專案建 `.knot/` 索引快取。要完全不寫入目標專案:

```bash
knot extract /path/to/other-project --db /tmp/knot-index.sqlite --output /tmp/cg.json
```

## 指令

### `knot extract`

```
Usage: knot extract [PATH] [-o|--output FILE] [--backend auto|imports|hiedb]
                    [--module-only] [--include-tests] [--hiedir DIR]
                    [--hiedb PATH] [--db FILE] [--strict]
                    [--summary meta|facts|graph]

  PATH                     要掃的專案根目錄(預設 ".")
  -o,--output FILE         輸出路徑(預設 <PATH>/codegraph.json)
  --backend auto|imports|hiedb
                           抽取後端(預設 auto)
  --module-only            只輸出 module 節點與 imports 邊
  --include-tests          納入 test-suite 與 benchmark component(預設排除)
  --hiedir DIR             覆寫 .hie 目錄位置
  --hiedb PATH             覆寫 hiedb 執行檔位置
  --db FILE                覆寫索引位置(預設 <PATH>/.knot/hiedb.sqlite)
  --strict                 有任何警告就 exit 1
  --summary meta|facts|graph
                           改印該站的唯讀摘要到 stdout,不寫 codegraph.json
```

`.hie` 目錄的發現順序:`--hiedir` > `<PATH>/.hie` > 遞迴掃 `dist-newstyle`。

`--summary` 是對帳用的唯讀路徑,分別印出 project-meta(檔案清單與 component 歸屬)、
extraction(事實流)、graph-core(節點與邊)三站的中間結果。

### `knot query`

讀既有的 `codegraph.json` 回答導航問題,只走依賴類邊(`contains` 這類結構邊不算)。

```
knot query find KEYWORD              # id 或 label 含 KEYWORD 的節點(不分大小寫)
knot query reachable ID [--reverse]  # 從 ID 可達的節點;--reverse 改問「誰依賴它」
knot query path FROM TO              # 兩點最短路徑
knot query rank [--top N]            # 連通度排名(預設前 10)

  --graph FILE   要查哪份圖(預設 ./codegraph.json,四個子命令共用)
```

## 輸出格式

`codegraph.json` 的欄位規格由 dev-flow 定義(細節見 `.design/adr/ADR-003`):

```json
{
  "directed": true,
  "built_at_commit": "648009c1b81a",
  "nodes": [
    {"id":"Demo.Core","label":"Demo.Core","source_file":"src/Demo/Core.hs"}
  ],
  "links": [
    {"source":"Demo.Render","target":"Demo.Core","relation":"imports",
     "confidence":"EXTRACTED","source_location":"L3"}
  ]
}
```

- knot 產出五種 relation:`imports` / `calls` / `uses` / `implements` / `contains`
- `confidence` 恆為 `EXTRACTED`——GHC 給的是事實,不是推測
- 輸出是 **byte 級決定性**的:同一份輸入的序列化結果完全相同(欄位順序、清單順序、
  換行一律 `\n`)

## 錯誤處理

best-effort:單一檔案讀不過(壞 `.hie`、版本不合、解析失敗)印警告到 stderr、跳過續跑,
仍產出部分圖,exit code 仍為 0。`--strict` 讓**任何警告**變成 exit 1。

## 已知限制

### 1. GHC 版本鎖

見上方「需求」。knot 與目標專案必須同版 GHC。

### 2. 同名 module 的 `.hie` 互相覆蓋(G-B001)

**這是目前最該注意的一項。** GHC 的 `-hiedir` 依 **module 名**決定輸出路徑,不含
component。當 `executable` 與 `test-suite` 都有 `Main` 時,兩者都寫 `.hie/Main.hie`,
後編譯的**覆蓋**先編譯的;knot 只能靠 module 名把 `.hie` 對回原始檔,同名時必然對錯。

實測(knot 掃自己):19 行的 `app/Main.hs` 被掛上 **302 個節點**、行號到 L3789,而那些
其實是 `test/Main.hs` 的宣告。

- **影響**:decl 層的 `source_file` 與行號不可信、節點數被灌水、hub 排名失真
- **不影響**:module 層(`imports` 邊來自 import-scan,不讀 `.hie`),依賴矩陣與
  循環依賴偵測仍可信
- **迴避法**:產 `.hie` 時**不要**加 `--enable-tests`;或用 `--module-only`

細節與修復方向見 `.design/bugfixes/G-B001-hie-component-collision.md`。

### 3. `implements` 邊尚未實作

hiedb 0.8 的索引 schema 沒有 instance 表(實測八張表:mods / decls / defs / refs /
exports / imports / typenames / typerefs),class/instance 關係沒有直接的資料來源。
`Fact` 的建構子已保留,邊的推導待後續 feature。

### 4. `hs-source-dirs` 取預設值 `.` 的 component 會認領整個 repo

Cabal 的 `hs-source-dirs` 預設值是 `.`。若某個 component 省略了這欄,knot 會忠實地
把 repo 內**全部** `.hs` 判給它並標為納入——包含 test fixture、範例碼、腳本。這忠實
實作了 Cabal 語意,但對「根目錄擺 library」的專案會灌水整張圖。

**迴避法**:在目標專案的 `.cabal` 明寫 `hs-source-dirs`。

### 5. 驗證覆蓋面

目前實跑驗證過三個專案(兩個外部驗收標的 + knot 自己)。更奇特的 cabal 結構
(Backpack、custom Setup.hs、複雜 conditional)沒有實測過。

### 6. 不做的事

不做 LLM 語意推測邊、不做社群偵測、不做視覺化、不做多語言(只服務 Haskell)。
理由見 `.design/system.md`「非目標」。

## 開發

```bash
# 建置品質閘門(唯一合法的零警告驗收指令,cabal clean 不可省略)
cabal clean && cabal build all --enable-tests --ghc-options=-Werror

# 測試
cabal test --enable-tests
```

`cabal clean` 是必要條件不是保險:少了它,`-Werror` 與 `-fforce-recomp` 都會回報
「乾淨」而實際不然,因為 GHC 的重編檢查不理會警告旗標的變動、增量建置不重印警告。
詳見 `.design/enhancements/G-E002-wall-clean-build.md`。

### 架構文件

`.design/` 是這個專案的設計樹:

| 路徑 | 內容 |
|---|---|
| `.design/system.md` | Level 1 主架構:系統邊界、對外契約、子系統劃分、通訊拓撲 |
| `.design/subsystems/<slug>/design.md` | Level 2 子系統架構(四個:project-meta、extraction、graph-core、export-query) |
| `.design/adr/` | 架構決策紀錄 |
| `.design/enhancements/`、`.design/bugfixes/` | 優化與缺陷文檔 |

## 授權

尚未指定。
