---
id: E003
type: enhance
title: clean-command
description: knot clean [PATH] 刪掉 <PATH>/.knot 快取目錄;路徑由 extraction 公開的 knotDir 給
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-006]
related-feature: [F004, F005, extraction/F005]
---

# E003: `knot clean`——刪掉 `.knot/` 快取

## 現況分析

- ADR-006 起 knot 把插樁建置的 builddir、`.hie`、hiedb 索引全收在目標專案根目錄的 `.knot/`
  (`system.md` Output 4:「純快取,刪掉只會讓下次變慢」)。story-flow 實測 `.knot/` 326 MB
  (三個 executable 各一份 build 樹)
- 目前沒有任何指令能清它:README §更新寫「想乾淨重來就刪掉 `.knot/`」,使用者要自己
  `rm -rf` / `Remove-Item`;`knot --help` 只有 `extract` / `query`(2026-08-23 開發者詢問
  「現在有這個命令嗎?」——沒有)
- `.knot` 這個目錄名只住在 extraction 的 build-driver(`src/Knot/Extract/BuildDriver.hs:70-71`
  `knotDir :: FilePath -> FilePath`),**沒有**經 `Knot.Extract` 公開;CLI 組裝層若要刪它,
  要嘛自己拼 `".knot"`(兩處真相),要嘛 extraction 把路徑函數放上契約

## Scope(涵蓋範圍)

**動**:

- **extraction**(Level 2 對外契約,加一條):`Knot.Extract` 匯出 `knotDir :: FilePath -> FilePath`
  (既有函數,只是公開;`design.md` 對外契約補一行)
- **cli-assembly**:`Command` 加 `CmdClean CleanCmd`、`newtype CleanCmd = CleanCmd { ccPath :: FilePath }`
  (位置參數 PATH,預設 `.`);`runCleanCmd :: Handle -> Handle -> CleanCmd -> IO ExitCode`;
  executable 加 `directory` 相依
- **Level 1 CLI 契約**(`system.md`)加 `knot clean [PATH]`;export-query `design.md` CLI 對映
  加一行;README §`knot clean`、§更新改用它

**明確不動**:

- 不刪 `codegraph.json`(它是輸出不是快取;要刪使用者自己刪)
- 不問確認、不加 `--force` / `--dry-run`:`.knot/` 是可重建快取,與 `cabal clean` 同性質;
  目錄不存在也 exit 0
- 不做「只清某個 component」「只清索引留 build」這類部分清理——快取內部佈局屬 extraction
  Level 2/3 自主權,CLI 不該知道
- 不動 `.knot/` 的佈局、`.gitignore` 自建邏輯(extraction/F005)

## 改善目標

| 指標 | 改善前 | 改善後(驗收標準) |
|---|---|---|
| `knot clean` | 無此子命令 | `knot clean [PATH]`:`<PATH>/.knot` 整棵刪除、stdout `removed <path>`、exit 0;`codegraph.json` 不動 |
| 目錄不存在 | — | stdout `nothing to clean: <path> does not exist`、exit 0 |
| 刪除失敗(`IOException`) | — | stderr `clean: …`、exit 1 |
| `.knot` 名稱的真相 | build-driver 內部 | 仍只有一處:CLI 走 `Knot.Extract.knotDir` |
| 測試 | 178 綠(含 E002) | 178 + 本文檔新增 綠;`-Wall -Werror` 零警告 |

## 相依性

`depends-on: []`。與 E002(`--version`)同一條分支、同一版 0.1.0.0 出,但互不依賴。

## 改善方案

```haskell
-- Knot.Extract(對外契約加一條)
module Knot.Extract (extract, knotDir) where

-- app/Knot/App/Cli.hs
data Command = CmdExtract ExtractCmd | CmdQuery QueryCmd | CmdClean CleanCmd
newtype CleanCmd = CleanCmd { ccPath :: FilePath }
-- command "clean" (info (CmdClean <$> cleanParser) (progDesc "delete the .knot cache directory of a project"))

-- app/Knot/App/Run.hs
runCleanCmd hOut hErr cmd = do
  let dir = knotDir (ccPath cmd)
  exists <- doesDirectoryExist dir
  if not exists then "nothing to clean" / ExitSuccess
  else try (removePathForcibly dir) → Left e: "clean: <e>" / ExitFailure 1;Right: "removed <dir>" / ExitSuccess
```

`removePathForcibly` 對唯讀檔與非空目錄都能處理(Windows 上 `.hie` 與 `package.cache.lock`
都是一般檔);失敗路徑交給 `try`,訊息前綴 `clean:` 與 `extract:` / `query:` 同風格。

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `knotDir :: FilePath -> FilePath`;`knotDir root = root </> ".knot"` | `src/Knot/Extract/BuildDriver.hs:70-71` | extraction/F005 | 快取目錄路徑的唯一來源 |
| `runCommand :: Handle -> Handle -> Command -> IO ExitCode` | `app/Knot/App/Run.hs:72-75` | F004 | 分派點 |
| `commandParser :: Parser Command`(`hsubparser` 兩個 `command`) | `app/Knot/App/Cli.hs` | F004 | 掛第三個子命令 |
| `emitNotes :: Handle -> [Text] -> IO ()` | `app/Knot/App/Report.hs` | F004 | stderr 訊息 |
| `removePathForcibly :: FilePath -> IO ()`、`doesDirectoryExist :: FilePath -> IO Bool` | `directory` | - | 刪除與存在性 |
| `withCaptured :: FilePath -> (Handle -> Handle -> IO a) -> IO (a, Text, Text)`、`expectParse :: [String] -> IO Command` | `test/Main.hs` | F004 | 端到端測試 |

## 介面變動

| 變動 | 層級 | 受影響呼叫端 |
|---|---|---|
| `Knot.Extract` 匯出 `knotDir` | extraction Level 2 對外契約(加一條,既有函數公開) | cli-assembly |
| CLI `knot clean [PATH]` | Level 1 CLI 契約(`system.md`) | 使用者 |
| `Command` + `CmdClean`;新 DTO `CleanCmd`;`runCleanCmd` | executable 內部(F004 的 CLI DTO) | `runCommand`、測試 |

## TodoList

- [x] T1: `Knot.Extract` 公開 `knotDir`;`Cli.hs` `CmdClean` / `CleanCmd` / `cleanParser`  `dep: -`
- [x] T2: `Run.hs` `runCleanCmd` 與分派;executable 加 `directory`  `dep: T1`
- [x] T3: 文件——`system.md` CLI、extraction / export-query `design.md`、README  `dep: T2`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_e003_clean_parse` | `["clean"]` → `CmdClean (CleanCmd ".")`;`["clean", "proj"]` → `"proj"`;多餘位置參數失敗 |
| T2 | `test_e003_clean_removes_knot` | 暫存專案:`.knot/build/deep/x.hie`、`.knot/hiedb.sqlite`、`.knot/.gitignore`、`codegraph.json` → `runCommand (CmdClean …)` exit 0、stdout `removed <path>`、stderr 空、`.knot` 不在、`codegraph.json` 仍在;再跑一次 → exit 0、`nothing to clean: … does not exist` |
| T3 | `test_e003_docs_mention_clean` | `system.md`、export-query `design.md`、README 含 `knot clean`;extraction `design.md` 含 `knotDir :: FilePath -> FilePath` |

## 實作備註

### 2026-08-23 實作完成

| 指標 | 改善前 | 改善後 |
|---|---|---|
| `knot clean [PATH]` | 無 | 暫存專案實測:`.knot/`(含深層 `.hie`、`hiedb.sqlite`、`.gitignore`)整棵刪除、stdout `removed <path>`、stderr 空、exit 0;`codegraph.json` 仍在;再跑一次 `nothing to clean: … does not exist`、exit 0(T2) |
| `.knot` 名稱的真相 | build-driver 內部 | 仍一處:`Knot.Extract` 公開既有 `knotDir`,CLI 不拼字串 |
| 測試 | 178 綠 | +3(`test_e003_clean_parse` / `_removes_knot` / `_docs_mention_clean`);測試輔助 `expectExtractCmd` / `expectQueryCmd` 的 case 改用萬用分支(`-Wincomplete-patterns` 對第三個建構子) |

**與設計的偏差**:無。
