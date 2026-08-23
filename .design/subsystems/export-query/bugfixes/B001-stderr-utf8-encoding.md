---
id: B001
type: bugfix
title: stderr-utf8-encoding
description: 回報建置失敗時 stderr 遇到不可編碼字元而崩潰,BuildFailed 訊息只印一半
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: []
related-feature: [F004, F005, extraction/F005]
---

# B001: stderr 用系統 code page 編碼,遇到 U+FFFD 就崩潰

## 症狀

story-flow 首次 `knot extract` 建置失敗(extraction/B001)時,knot 印到一半自己死掉:

```
extract: build failed for storyflow-service:test:storyflow-service-test
extract:   cabal exited with 1
extract:   …
extract:       CreateFile "C:\\Users\\…\\CabalSpec.hie"

<stderr>: hPutChar: invalid argument (cannot encode character '\65533')

HasCallStack backtrace:
  ioException, called at libraries\ghc-internal\src\GHC\Internal\IO\Encoding\Failure.hs:218:24
```

exit code 仍是 1(未捕捉的例外),但 `BuildFailed` 的尾段沒印完,使用者看到的是 GHC RTS
的 backtrace 而不是 knot 的錯誤訊息。

## 影響範圍

- Windows 上所有非 UTF-8 code page 的使用者(zh-TW 預設 CP950、ja-JP CP932…),
  只要任何警告 / 錯誤訊息含 code page 外的字元——U+FFFD 是 build-driver
  `decodeUtf8With lenientDecode` 對 cabal 輸出中壞位元組的替換字,最容易踩到;
  目標專案原始碼路徑含非 BMP 或非本地語系的字元也會
- 影響的是組裝層的所有 stderr / stdout 輸出(`emitNotes`、`--summary`、`query` 結果)

## 重現步驟

1. 任一 `Handle` 設成不能編碼 U+FFFD 的編碼(測試用 `latin1`;Windows 上預設就是 ANSI code page)
2. `emitNotes h [T.pack "x\65533"]` → `hPutChar: invalid argument`

## 根因分析

GHC 在 Windows 上對非 console 的 handle 以 `GetACP()` 當預設編碼(zh-TW 是 CP950);
`app/Main.hs` 直接把 `stdout` / `stderr` 交給 `runCommand`,沒有設編碼。build-driver
逐行轉發 cabal 輸出走的是 `BS8.hPutStrLn stderr`(raw bytes,不經編碼,所以即時轉發
那一路沒事),但 `BuildFailed` 的 `bfDetail` 是 `Text`,由 `Knot.App.Report.emitNotes`
用 `TIO.hPutStr` 印——這一路要編碼,U+FFFD 在 CP950 沒有對應 → 例外。

## 修復方向

`Knot.App.Run` 新增 `prepareHandles :: Handle -> Handle -> IO ()`:對兩個 handle
`hSetEncoding … utf8`;`app/Main.hs` 在 `runCommand` 之前呼叫。UTF-8 能編碼所有
Unicode 字元,也是 `codegraph.json` 與所有文件的編碼。放在 `Run` 而非 `Main` 是為了
測得到(`Main` 因模組名衝突不進 test-suite)。不用 `hSetEncoding stdout` 的替代方案
(`GHC_CHARENC`、`chcp`)——那些是環境設定,不是 knot 能保證的。

## TodoList

- [x] T1: `prepareHandles` 於 `Knot.App.Run`,`app/Main.hs` 呼叫  `dep: -`

## 驗證方式

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_b001_handles_encode_replacement_char` | 暫存檔 handle 設 `latin1` → `emitNotes h [含 U+FFFD]` 拋 `IOException`;對同一暫存檔的新 handle 先 `prepareHandles` 再 `emitNotes` → 成功,讀回以 UTF-8 解碼含 U+FFFD;`extractFailureLines (BuildFailed …含 U+FFFD…)` 經 `prepareHandles` 後可完整印出 |

## 修復紀錄

### 修法(2026-08-23)

- `app/Knot/App/Run.hs` 新增 `prepareHandles :: Handle -> Handle -> IO ()`(兩個 handle
  `hSetEncoding … utf8`),`app/Main.hs` 在 `execParser` 之前呼叫
- build-driver 逐行轉發 cabal 輸出的那一路(`BS8.hPutStrLn`)本來就是 raw bytes,不受影響

### 量化結果

| | 修前 | 修後 |
|---|---|---|
| `latin1` handle 印含 U+FFFD 的 `emitNotes` | `IOException`(`hPutChar: invalid argument`) | 經 `prepareHandles` 後成功,檔案內容為 UTF-8、含 U+FFFD(T1) |
| story-flow 於原路徑、建置失敗時 | knot 在 `BuildFailed` 尾段印到一半崩潰、印出 RTS backtrace | (B001 修後建置不再失敗,此路徑改以 T1 的 `extractFailureLines (BuildFailed …U+FFFD…)` 驗證)完整印出 |
| 測試 | 160 綠 | 160 + 1 綠 |

### 與「修復方向」的偏差

無。測試第一版在例外後沒關 `latin1` 的 handle,`removePathForcibly` 於 Windows 上被
佔用中的檔案擋住;改為例外後再 `try (hClose h)` 一次。
