---
id: G-E005
type: enhance
title: module-only-skips-hiedb
description: --module-only 仍跑完 hiedb 索引,產出卻逐 byte 相同
status: done
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: []
related-feature: [export-query/F004, extraction/F001, graph-core/F001]
subsystems: [export-query]
---

# G-E005: `--module-only` 白跑 hiedb 索引

## 現況分析

`app/Knot/App/Cli.hs` 的 `toExtractOptions` 把 `--backend` 原樣透傳給 extraction,
`toBuildOptions` 把 `--module-only` 給 graph-core。兩者互不知情,於是
`--module-only`(預設 `--backend auto`)會:

1. extraction 照跑 hiedb 後端——探測、`hiedb index`、讀 SQLite、產出全部 decl 事實
2. graph-core 依組裝規則 6(`moduleOnly` 忽略 decl 層)把那些事實**整批丟掉**

**但那些工作不可能有任何貢獻**,兩條契約明文擋著:

- 抽取規則 2:`FactImport` **永遠且只**來自 import-scan
- 組裝規則 6:`moduleOnly = True` 時 decl 節點與 `RContains` 完全不出現

### 實測(2026-08-22,knot-hs 自身 32 個 `.hs`)

| 指令 | 耗時 | 輸出 |
|---|---|---|
| `knot extract . --backend imports` | **120 ms** | 14315 bytes |
| `knot extract . --module-only`(預設 auto) | **2500 ms** | 14315 bytes,**sha256 完全相同** |

`diff` 逐 byte 相同。**20 倍時間差,零產出差異。**

這對「像 graphify 一樣快」的目標直接相關:module 級是這個工具唯一零前置、
零改動目標專案的路徑,而它被自己的預設值拖慢了一個數量級。

## Scope(涵蓋範圍)

**動**:`app/Knot/App/Cli.hs` 的 `toExtractOptions` 一處。

**明確不動**:

- extraction 與 graph-core 的任何邏輯(它們各自都沒做錯)
- `--backend` 旗標本身的語意與值域
- 輸出格式——`codegraph.json` 必須逐 byte 不變

**對外契約**:Level 1 與 Level 2 皆不變。CLI 的旗標組合語意有一處**收窄**
(見「介面變動」),屬 Level 1「內部旗標細節屬 Level 2/3 自主權」的範圍。

## 改善目標

| # | 標準 | 怎麼量 |
|---|---|---|
| 1 | `--module-only` 不再啟動 hiedb 後端 | `backendChoice` 收窄為 `ImportsOnly` |
| 2 | 耗時大幅下降 | 2500 ms → **441 ms** |
| 3 | 輸出零變更 | 與 `--backend imports` 的 `codegraph.json` 逐 byte 相同 |
| 4 | 明確指定後端時不被覆寫 | `--backend hiedb --module-only` 仍為 `HiedbOnly` |

## 相依性

`depends-on: []`。純組裝層的一處對映調整,不依賴任何未完成文檔。

## 改善方案

`toExtractOptions` 依 `(ecModuleOnly, ecBackend)` 收窄:

```haskell
  narrowedBackend = case (ecModuleOnly c, ecBackend c) of
    (True, Auto) -> ImportsOnly
    (_,    b)    -> b
```

**只在 `--backend` 停留在預設值 `Auto` 時收窄**。使用者明確指定後端(例如
`--backend hiedb --module-only` 除錯)時尊重其選擇,不覆寫——那個組合今天會產出
空圖,但那是使用者要的行為,不該由組裝層擅自改掉。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `toExtractOptions :: ExtractCmd -> XT.ExtractOptions` | `app/Knot/App/Cli.hs:255` | export-query/F004 | 修改標的 |
| `data BackendChoice = Auto \| ImportsOnly \| HiedbOnly` | `src/Knot/Extract/Types.hs` | extraction/F001 | 收窄的值域 |
| `toBuildOptions :: ExtractCmd -> BuildOptions` | `app/Knot/App/Cli.hs:264` | export-query/F004 | `moduleOnly` 的另一個消費端(不動) |

## 介面變動

### 修改

| 介面 | 變動 | 受影響呼叫端 |
|---|---|---|
| `toExtractOptions` | `--module-only` 且 `--backend` 為預設 `Auto` 時,`backendChoice` 收窄為 `ImportsOnly` | 無(組裝層內部;`ExtractCmd` 與 `ExtractOptions` 的欄位與型別皆不變) |

CLI 旗標語意的收窄:`--module-only` 現在**隱含**不跑 hiedb。輸出不變,只是不再
做註定被丟棄的工作。

## TodoList

- [x] T1: `toExtractOptions` 依 `(ecModuleOnly, ecBackend)` 收窄 backendChoice  `dep: -`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_extract_options_mapping`(既有,新增四條斷言) | `--module-only` + `Auto` → `ImportsOnly`;無 `--module-only` 時維持 `Auto`;明確給 `HiedbOnly` / `ImportsOnly` 時不被覆寫 |

## 實作備註

實測結果:`--module-only` 從 **2500 ms 降到 441 ms**,輸出與 `--backend imports`
逐 byte 相同(`diff` 驗證)。

發現經過:回答「這個工具是不是像 graphify 一樣好用」時逐項量測各指令耗時,
發現 `--summary meta` 63 ms、`--summary facts` 86 ms、`--backend imports` 120 ms,
但 `--module-only` 要 2500 ms——差額全部落在註定被丟棄的 hiedb 索引上。
