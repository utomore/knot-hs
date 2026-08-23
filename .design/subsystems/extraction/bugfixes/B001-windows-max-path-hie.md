---
id: B001
type: bugfix
title: windows-max-path-hie
description: monorepo 上 knot 自己寫的 .hie 路徑超過 Windows MAX_PATH,建置失敗且原因難辨
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-006]
related-feature: [F005, E001]
---

# B001: Windows MAX_PATH——knot 自己寫的 `.hie` 路徑超過 260 字元

## 症狀

2026-08-23 對 story-flow(12 套件 monorepo,repo 路徑 47 字元)首次 `knot extract`,
34.8 s 後 exit 1:

```
extract: build failed for storyflow-service:test:storyflow-service-test
extract:   cabal exited with 1
extract:   <no location info>: error:
extract:       CreateFile "C:\Users\User\Documents\alchbees-dev\story-flow\.knot\build\build\x86_64-windows\ghc-9.14.1\storyflow-service-0.1.0.0\t\storyflow-service-test\build\storyflow-service-test\storyflow-service-test-tmp\extra-compilation-artifacts\hie\StoryFlow\Service\CabalSpec.hie"
```

失敗的路徑 **262 字元**,是 `-fwrite-ide-info` 要寫的 `.hie`——knot 自己要求 GHC 產生的檔。
9 / 12 套件已經建完、120 個 `.hie` 已落地,整體仍失敗(ADR-006:兩層缺一不可,正確)。
同一個專案自己的 `dist-newstyle/` 建得起來,只因為少了 `.knot\build\build` 那 12 個字元。

## 影響範圍

- 任何 Windows 上 repo 路徑 ≥ 約 45 字元、套件名 / module 名偏長的 monorepo
  (`<pkg>-<ver>\t\<pkg>-test\build\<pkg>-test\<pkg>-test-tmp\` 把套件名重複四次)
- 第一個撞到的是 **test-suite** 的 `.hie`:test-suite 名字最長(`<pkg>-test`),而它根本
  不是 knot 要的——標的的 `cabal.project` 寫了 `tests: True`,knot 沒有要 test-suite
  卻也沒有說「不要」,cabal 就照建(extraction/E001 只過濾了列舉,沒管建置)
- 使用者看到的是 GHC 的 `CreateFile` 錯誤,沒有任何「路徑太長」的字樣

## 重現步驟

1. Windows,`LongPathsEnabled` 未開(預設)
2. 把 `test/fixtures/buildable` 複製到一個總長 ≥ 200 字元的目錄(或任何路徑長到
   `<root>\.knot\build\build\x86_64-windows\ghc-9.14.1\<pkg>-<ver>\…\extra-compilation-artifacts\hie\<Mod>.hie` ≥ 260)
3. `knot extract <該目錄>` → `BuildFailed`,`bfDetail` 含 `CreateFile "…"`,無提示

重現測試不能依賴真實的長路徑(CI 上未必撞得到),改以純函數驗證兩件事:
`cabalArgs` 對未納入的 test-suite / benchmark **明確傳** `--disable-*`;`BuildFailed`
的尾段含 ≥ 248 字元的 `CreateFile` 路徑時附上 MAX_PATH 提示。

## 根因分析

兩層:

1. **長路徑本身**:`.knot/build`(規則 7)+ cabal 的 builddir 佈局 + `extra-compilation-artifacts/hie/`
   + module 路徑。knot 能動的只有 `.knot/build` 這一段,改短 5 個字元治不了本質;
   `\\?\` 前綴是否被 cabal / GHC 接受未經 spike,不在本次。
2. **建了不該建的 component**:`src/Knot/Extract/BuildDriver.hs` `cabalArgs` 只在有納入的
   test-suite 時帶 `--enable-tests`,**沒有納入時什麼都不帶**——於是標的自己的
   `cabal.project`(`tests: True`)說了算。規則 5 的原意是「只建納入的 component」,
   實作只做了一半。

## 修復方向

1. `cabalArgs`:沒有納入的 test-suite → `--disable-tests`;沒有納入的 benchmark →
   `--disable-benchmarks`(明確覆寫專案設定;有納入時維持 `--enable-*`)。這同時把
   story-flow 那種專案的 cold 建置時間砍掉一半(152 個測試檔不再編)
2. `BuildFailed` 的 `bfDetail` 尾段出現 `CreateFile "<path>"` 且 `<path>` ≥ 248 字元時,
   附一行提示:路徑長度、260 的限制、兩個解法(`subst X: <root>` 縮短路徑 / 開啟
   Windows 長路徑支援)。純函數 `maxPathHint :: [Text] -> [Text]`,不判 OS——非 Windows
   不會出現 `CreateFile` 字樣
3. README「已知限制」加 MAX_PATH 一條;`design.md` 規則 5 補「未納入者明確 `--disable-*`」

## TodoList

- [x] T1: `cabalArgs` 對未納入的 test-suite / benchmark 明確傳 `--disable-tests` / `--disable-benchmarks`  `dep: -`
- [x] T2: `maxPathHint` 純函數 + 接進 `BuildFailed` 的 `bfDetail`  `dep: -`
- [x] T3: README 已知限制、`design.md` 規則 5 回填  `dep: T1`

## 驗證方式

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_b001_cabal_args_disable_excluded` | 無納入 test/bench → argv 含 `--disable-tests` 與 `--disable-benchmarks`、不含 `--enable-*`;有納入 test → `--enable-tests` 且無 `--disable-tests`;既有 F005 `cabalArgs` 測試改寫後全綠 |
| T2 | `test_b001_max_path_hint` | 尾段含 262 字元 `CreateFile` 路徑 → 提示一行含 `262`、`260`、`subst`;路徑 100 字元或沒有 `CreateFile` → 無提示;`BuildFailed` 的 `bfDetail` 末尾即該提示 |
| T3 | `test_b001_docs_mention_max_path` | README 含 `MAX_PATH`;`design.md` 規則 5 含 `--disable-tests` |

## 修復紀錄

### 修法(2026-08-23)

- `src/Knot/Extract/BuildDriver.hs` `cabalArgs`:`--enable-tests` / `--disable-tests`、
  `--enable-benchmarks` / `--disable-benchmarks` 二選一**一定帶**,依 `compExcluded` 決定
- 同檔新增 `maxPathHint :: [Text] -> [Text]`(門檻 248),接進 `BuildFailed` 的 `bfDetail`
  尾段;提示以 `windows MAX_PATH:` 開頭,含實際長度、260 上限、`subst` 與長路徑支援兩個解法
- README 已知限制 §6、`design.md` 規則 5
- 既有 F005 `test_cabal_invocation` 的 argv 精確比對加上兩個 `--disable-*`

### 量化結果

| | 修前 | 修後 |
|---|---|---|
| story-flow 於**原路徑**(47 字元,不用 `subst`)`knot extract` | exit 1(`CreateFile` 262 字元,test-suite 的 `.hie`) | **exit 0**,54 s(含 cabal 因 `--disable-tests` 重新設定與重建 libs / exes);warm 1.27 s |
| 被建出的 test-suite | 12 個、152 個測試檔 | **0**(cabal 不再建 test-suite;`.knot/build` 裡留著上一次的 152 個 `.hie` 是殘骸,E001 的列舉過濾擋掉) |
| 圖 | — | 1768 節點 / 8054 邊,與 `subst K:` 路徑下的結果在非 instance 節點與依賴邊上逐數相同 |
| 測試 | 160 綠 | 160 + 3 綠 |

### 與「修復方向」的偏差

無。MAX_PATH 的長路徑本質沒有解(不在 scope):`.knot\build` 仍是 knot 的固定佈局,
library module 名夠長時仍可能撞到,屆時會看到提示而不是裸的 `CreateFile`。

### 仍然成立的限制

`<root>` 本身太長(例如 ≥ 120 字元)時,library 的 `.hie` 也會超限;解法只有縮短路徑或
開啟長路徑支援,README §6 已寫明。
