---
id: E002
type: enhance
title: version-flag
description: knot --version 印套件版本與建置它的 GHC 版本;版本號定為 0.1.0.0,README 補更新與發版流程
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-001]
related-feature: [F004, F005]
---

# E002: `knot --version` 與版本號 0.1.0.0

## 現況分析

- `knot-hs.cabal` 的 `version` 自 2026-08-20 起凍結在 `0.0.1.0`(export-query build-log D6:
  「全部子系統完成後再定版」);2026-08-23 `/arch-audit status` 確認 36 份任務文檔全數 done,
  四個子系統 100%,凍結的前提已經成立
- `app/Knot/App/Cli.hs:116-121` 的 `cliParserInfo` 只掛 `helper`,沒有 `--version`。使用者
  機器上 PATH 的 `C:\cabal\bin\knot.exe`(2026-08-22 17:19)比同日 merge 的 E001 / E002 /
  B001 / B002 / G-E007 都舊,但從外面看不出來——唯一的辨法是 `knot query --help` 有沒有
  `--scope`。更新(`cabal install exe:knot`)也會因 installdir 已有同名檔被 cabal 拒絕,
  README §安裝沒寫 `--overwrite-policy=always`
- ADR-001 的版本鎖讓「建置 knot 的 GHC 版本」成為使用者最常需要核對的資訊(`VersionMismatch`
  時 extraction 會印出該用哪版重裝),但目前只有失敗時才看得到

## Scope(涵蓋範圍)

**動**(全部在 cli-assembly 與文件):

- `knot-hs.cabal`:`version: 0.1.0.0`(開發者指定);executable / test-suite 加
  `Paths_knot_hs`(`other-modules` + `autogen-modules`)
- cli-assembly:頂層 `--version`(optparse `infoOption`),輸出
  `knot <版本> (GHC <建置它的 GHC 版本>)`,exit 0;新增非契約面 `versionText :: String`
- Level 1 CLI 契約(`system.md`)加 `knot --version`;export-query `design.md` CLI 對映加一行
  註明它不進本子系統
- README §安裝:`--version` 範例、新增「更新」(含 `--overwrite-policy=always`)與「發版
  (維護者)」兩節

**明確不動**:

- library(`src/`)一字不改;四個子系統的 Level 2 契約不變
- 不引入 `gitrev` / Template Haskell 把 commit 塞進二進位(多一個相依、多一段 TH 編譯,
  換來的資訊 `git describe` 就有);不做自我更新、不做版本檢查網路請求
- 不建 CI / release workflow(另案;README 先把手動步驟寫清楚)
- extraction 的 `VersionMismatch` 訊息不改(已指出該用哪版重裝)

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| `knot --version` | 無此旗標(optparse 報錯 exit 1) | 印 `knot 0.1.0.0 (GHC 9.14.1)`、exit 0;不需要任何子命令 |
| `knot-hs.cabal` `version` | `0.0.1.0` | `0.1.0.0`;`--version` 的數字**來自 `Paths_knot_hs`**,不是手抄的常數 |
| 更新流程 | README 無;`cabal install` 撞已存在的 `knot.exe` 失敗 | README 有「更新」一節,含 `--overwrite-policy=always` |
| 發版流程 | 無 tag、無 Release | README 有「發版」一節;本文檔合進 main 後打 `v0.1.0.0` |
| 測試 | 176 綠 | 176 + 本文檔新增 綠;`-Wall -Werror` 零警告(`Paths_knot_hs` 進 `-Wall` 編譯不得冒警告) |

## 相依性

`depends-on: []`。動的檔案(`Cli.hs`、`.cabal`、三份文件)與進行中任務無交集。

## 改善方案

```haskell
-- app/Knot/App/Cli.hs
cliParserInfo = info (commandParser <**> helper <**> versionOption) (…)
 where versionOption = infoOption versionText (long "version" <> help "…")

versionText :: String   -- 非契約面,測試直接比對
versionText = "knot " <> showVersion version <> " (GHC " <> showVersion fullCompilerVersion <> ")"
```

`version` 來自 cabal autogen 的 `Paths_knot_hs`(本專案 extraction/E002 已對 autogen module
靜默跳過,knot 自掃不受影響);`fullCompilerVersion` 來自 `System.Info`(base ≥ 4.15),
是**建置 knot 的** GHC,正是 ADR-001 要使用者對齊的那個版本。`infoOption` 是 optparse 的
abort option:解析到就印字串 + exit 0,不會進 `Command`,所以 `runCommand` 與各子命令
零改動。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `cliParserInfo :: ParserInfo Command`;`cliParserInfo = info (commandParser <**> helper) (…)` | `app/Knot/App/Cli.hs:116-121` | F004 | 掛 `--version` 的位置 |
| `infoOption :: String -> Mod OptionFields (a -> a) -> Parser (a -> a)` | optparse-applicative 0.19 `Options.Applicative.Extra` | - | abort option |
| `version :: Data.Version.Version` | cabal autogen `Paths_knot_hs` | - | 套件版本的唯一來源 |
| `fullCompilerVersion :: Data.Version.Version` | base `System.Info` | - | 建置 knot 的 GHC 版本 |
| `parseCli :: [String] -> ParserResult Command`、`expectParseFailure :: [String] -> IO (String, ExitCode)` | `test/Main.hs:4636-4660` | F004 | 測試 abort option 的輸出與 exit code |

## 介面變動

| 變動 | 層級 | 受影響呼叫端 |
|---|---|---|
| CLI 頂層 `--version` | Level 1 CLI 契約(`system.md`) | 使用者 |
| `versionText :: String`(新,`Knot.App.Cli` 匯出) | executable 內部(非契約面) | 測試 |
| `knot-hs.cabal` `version` 0.0.1.0 → 0.1.0.0 | 套件 metadata | 無程式碼呼叫端;`.knot/build` 下的 inplace id 會變 `knot-hs-0.1.0.0-inplace`(知識圖重掃一次即可) |

## TodoList

- [x] T1: `.cabal` 版本號 + `Paths_knot_hs`;`Cli.hs` `--version` / `versionText`  `dep: -`
- [x] T2: 文件——`system.md` CLI、export-query `design.md` CLI 對映、README §安裝 / 更新 / 發版  `dep: T1`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e002_version_flag` | `parseCli ["--version"]` 以 exit 0 結束且輸出 = `versionText`;`versionText` 以 `knot 0.1.0.0 (GHC ` 開頭、以 `)` 結尾;`["query", "--version"]` 與 `["--version", "extract"]`:前者失敗(旗標只在頂層)、後者成功(abort 先於子命令) |
| T2 | `test_e002_docs_mention_version` | `system.md` 與 export-query `design.md` 含 `--version`;README 含 `--overwrite-policy=always`、`knot --version`、「發版」 |

## 實作備註

### 2026-08-23 實作完成

| 指標 | 改善前 | 改善後 |
|---|---|---|
| `knot --version` | 無 | `knot 0.1.0.0 (GHC 9.14.1)`、exit 0;`--version extract` 同(abort 先於子命令);`query --version` 失敗(只在頂層) |
| 版本號來源 | 手抄 | `Paths_knot_hs.version`(executable 與 test-suite 都列進 `other-modules` + `autogen-modules`,`-Wall -Werror` 零警告) |
| README | 無更新 / 發版流程 | §安裝加 `--version` 範例,新增 §更新(`--overwrite-policy=always`)、§發版(tag + `cabal install --install-method=copy` + `gh release create`) |
| 測試 | 176 綠 | +2(`test_e002_version_flag`、`test_e002_docs_mention_version`) |

**與設計的偏差**:無。同一分支一併出 E003(`knot clean`),同版 0.1.0.0。`.knot/build` 下的 inplace
id 由 `knot-hs-0.0.1.0-inplace-*` 變為 `0.1.0.0`,knot 自掃時 cabal 會重新設定一次(一次性成本)。
