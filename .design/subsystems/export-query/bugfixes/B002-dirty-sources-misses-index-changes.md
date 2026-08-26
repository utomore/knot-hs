---
id: B002
type: bugfix
title: dirty-sources-misses-index-changes
description: 新鮮度提示漏掉已 git add 的新檔與改名,非 ASCII 檔名也漏
status: done
created: 2026-08-27
updated: 2026-08-27
depends-on: []
related-adr: []
related-feature: [G-E008]
---

# B002: `detectDirtySources` 漏掉 index 內的改動與非 ASCII 檔名

## 症狀

`knot query` 的新鮮度提示(G-E008)在下列情況**該出聲卻沉默**——圖確實已經對不上工作區,
使用者卻拿不到任何提示:

| 觸發方式 | 預期行為 | 實際行為 |
|---|---|---|
| `git add New.hs` 之後查詢(尚未 commit) | stderr 一行 `query: graph may be stale: …` | **零行** |
| `git mv Old.hs New.hs` 之後查詢(尚未 commit) | 同上 | **零行** |
| 新增未追蹤的 `中文.hs` 之後查詢 | 同上 | **零行** |

影響範圍:只影響**提示的有無**,不影響任何查詢結果、不影響 exit code,也不會給出錯誤答案
——是「該提醒時沒提醒」,不是「提醒錯了」。但**改名正是圖最容易過期的時機**
(重構後節點 id 整批變動),漏在這裡最痛。

`--include-tests` / `--exclude-tests`、`built_at_commit` 的比對(L1/L2)、
`freshnessNoteLines` 的文案(L2/L3/L5)全部不受影響。

## 重現步驟

`Knot.Export.detectDirtySources` 對下列三種工作區狀態回 `False`,正確答案是 `True`:

1. **staged 新增**:git repo 內 `writeFile "New.hs"` → `git add New.hs` → `detectDirtySources dir`
2. **staged 改名**:已 commit 的 `Old.hs` → `git mv Old.hs New.hs` → `detectDirtySources dir`
3. **非 ASCII 檔名**:`writeFile "中文.hs"`(未追蹤)→ `detectDirtySources dir`

`git status --porcelain` 在三種狀態下的實際輸出(2026-08-27 於臨時 repo 實測):

```
A  New.hs
R  New.hs -> Renamed.hs
?? "\344\270\255\346\226\207.hs"
```

## 根因分析

兩個獨立的根因,都在 `src/Knot/Export/Commit.hs` 的逐行判定。

**根因一:`statusCounts` 的狀態碼白名單漏了 index 側的三個碼**(`src/Knot/Export/Commit.hs:85-89`)

```haskell
statusCounts code =
  code == T.pack "??"
    || T.pack "M" `T.isInfixOf` code
    || T.pack "D" `T.isInfixOf` code
```

只認未追蹤(`??`)與含 `M` / `D` 的碼。porcelain v1 的 index 側還有
`A`(新增)、`R`(改名)、`C`(複製),三者都表示**未提交的改動**,卻一律落到 `False`。

連帶後果:`currentPath`(`src/Knot/Export/Commit.hs:92-95`)是**不可達的死碼**。
它專為 `old -> new` 的改名行而寫,而 `&&` 先短路在 `statusCounts code` 上,
改名行永遠走不到它。函式的 haddock 還寫著「rename 的一行是 `old -> new`,只看新路徑」
——**註解宣稱的行為與程式碼實際做的事不一致**。

**根因二:非 ASCII 路徑被 git 加引號轉義**(`src/Knot/Export/Commit.hs:82`)

git 預設 `core.quotePath=true`,路徑含非 ASCII 位元組時會輸出成 `"\344\270\255…"`
——**前後多一對雙引號**。後綴比對 `".hs" \`T.isSuffixOf\` path` 因此對到的是 `hs"`,判 `False`。

**根因三(修復途中才發現,比前兩條嚴重):子程序輸出以 locale 編碼解碼會拋例外**

`readCreateProcessWithExitCode` 用 `localeEncoding` 解碼子程序的 stdout,而 git 吐的是 **UTF-8**。
在非 UTF-8 codepage 的 Windows 上兩者對不上。最小探針實測(2026-08-27,本機):

```
localeEncoding = CP950
THREW: fd:4: hGetContents: invalid argument (cannot decode byte sequence starting from 150)
```

例外被 `detectDirtySources` 的 `try` 吞掉 → 回 `False`。後果比根因二大得多:
**repo 裡只要有任何一個非 ASCII 路徑(不限 `.hs`、不限本次改動的檔案),整份 status 就全沒了**,
這個函式對該 repo 恆回 `False`。這條沒有被原本的重現步驟直接描述,是修完根因二、
測試仍紅之後才用探針定位出來的。

`detectCommit` 不受影響:它只讀 40/64 位的 hex sha,全 ASCII。

**責任歸屬分兩邊,不要混為一談:**

- **根因一、二的上游責任在 spec。** G-E008 的 law L7 把判準列舉成「tracked 檔的修改或刪除、
  未追蹤的新 `.hs` 檔」,impl 照字面實作是正確的;是列舉本身漏了 index 側的狀態與轉義路徑。
  修復時一併回填 L7(T4)
- **根因三與 spec 無關**,是平台層的陷阱:任何 law 都不會去規定「子程序輸出該用什麼編碼解碼」。
  它也不是 impl 的疏忽——`readCreateProcessWithExitCode` 是最直覺的選擇,而它在 UTF-8 locale 的機器上
  完全正常。這條只有在**非 UTF-8 codepage 的 Windows 上碰到非 ASCII 路徑**才會現形

## 修復方向

**根因一**:把 `statusCounts` 從「白名單特定字母」改成「排除非改動狀態」——porcelain 的
兩欄狀態碼中,只要任一欄不是「未修改」(空白)或 ignored,這一行就是一筆未提交的改動。
`??` 照舊視為改動。這樣 `A` / `R` / `C` / `U`(unmerged)自動納入,日後 git 增加狀態碼也不會再漏。
`currentPath` 因此被救活,改名行取新路徑判斷副檔名。

**根因二**:呼叫 git 時帶 `-c core.quotePath=false`,讓路徑原樣輸出。
不改用 `-z`(NUL 分隔)是因為那會連 `lines` 的切法一起換掉、改動面比較大,
而 `core.quotePath=false` 只影響輸出編碼,是最小修復。

**替代方案(否決)**:在 Haskell 這端反轉義 `\344\270\255` 這類八進位序列。
否決理由:那等於在 knot 裡重寫一份 git 的引號規則(還要處理 `\"`、`\\`、`\t` 等),
維護成本遠高於讓 git 直接不要轉義。

**根因三**:改成自己開 pipe、`hSetBinaryMode` 讀原始位元組、再 `decodeUtf8With lenientDecode`
——這正是 `src/Knot/Extract/BuildDriver.hs:128,141` 讀 cabal 輸出的既有作法,不是新發明。
stderr 另開一條 pipe 讀掉但不解析(git 的訊息不該混進判定,也不能印出來)。
`dirtyHsLine` 的參數型別因此由 `String` 改為 `Text`——它是未匯出的私有函式,不影響任何契約。

**替代方案(否決)**:全域 `setLocaleEncoding utf8`。否決理由:library 不得改動整個行程的
全域狀態,那會波及呼叫端所有無關的 IO。

**`detectCommit` 不跟著改**:它只讀 hex sha,locale 解碼不會出事;為了「一致」去動一個
沒壞的函式違反最小修復原則。兩者的差異寫進模組 haddock,避免下次有人以為是漏改。

**不動的東西**:`detectDirtySources` 的簽名、失敗語意(任何失敗回 `False` 且不印)、
`freshnessNoteLines` 的三分支與文案、`detectCommit`、`runQueryCmd` 的接線,一律不碰
(最小修復原則)。這是內部判定邏輯的修正,**不動任何 Level 2 契約**。

## TodoList

- [x] T1: 撰寫重現缺陷的測試(staged 新增 / staged 改名 / 非 ASCII 檔名三態,修復前應失敗)  `dep: -`
- [x] T2: 修 `statusCounts`——改為「排除未修改狀態」的判定,納入 `A` / `R` / `C` / `U`  `dep: T1`
- [x] T3: 修引號轉義——git 呼叫帶 `-c core.quotePath=false`  `dep: T1`
- [x] T3b: 修解碼——改走 binary pipe + `decodeUtf8With lenientDecode`(根因三,修復途中發現)  `dep: T1`
- [x] T4: 回填 G-E008 的 law L7 列舉,使 spec 與行為一致  `dep: T2, T3, T3b`

## 驗證方式

- 三條重現測試(T1)由紅轉綠
- `test_g8_detect_dirty_sources` 既有的六個情境(乾淨 repo、tracked 修改、未追蹤新檔、
  tracked 刪除、非 `.hs` 改動、`.gitignore` 排除)全部維持綠——特別是**後兩條**:
  修法擴大了狀態碼的接受範圍,不得因此把非 `.hs` 檔或 ignored 檔誤判為髒
- 閘門:`cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0
- 完整套件:`cabal test all --enable-tests` 全綠,基線 190 條無一轉紅

## 修復紀錄

改動只落在 `src/Knot/Export/Commit.hs` 一個檔案(加測試),三處:

1. **`statusCounts`**:白名單 → 排除法。`!!`(ignored)為 `False`、`??` 為 `True`,
   其餘只要兩欄狀態碼任一不是空白就算改動。`A` / `R` / `C` / `U` 因此自動納入,
   日後 git 新增狀態碼也不會再漏一次。`currentPath` 這條原本不可達的死碼隨之被救活
2. **git 呼叫**:加 `-c core.quotePath=false`,路徑原樣輸出不轉義
3. **輸出讀法**:`readCreateProcessWithExitCode` → 自己開 pipe、`hSetBinaryMode`、
   `decodeUtf8With lenientDecode`;stderr 另開一條讀掉不解析。
   `dirtyHsLine` 的參數型別因此由 `String` 改為 `Text`(未匯出的私有函式,無契約影響)

**與「修復方向」的偏差**:原本只寫了兩個根因,修完根因二之後重現測試的第三個情境仍紅,
以最小探針定位出根因三(locale 解碼拋例外)。這一條的影響面比原先記錄的大——不是
「非 ASCII 檔名漏偵測」,而是「repo 裡有任何非 ASCII 路徑就整份 status 失效」。
文檔的「症狀」段是以修復前的觀察寫的,保留原樣不回頭美化;根因三的完整分析補在上面。

**沒有動的東西**:`detectDirtySources` 的簽名與失敗語意、`detectCommit`、
`freshnessNoteLines`、`runQueryCmd` 的接線、任何 Level 2 契約。

**驗證**(2026-08-27):

- 重現測試 `test_b002_dirty_sources_index_and_quoted_paths` 修復前於 case (a) 失敗、
  修根因一後於 case (c) 失敗、修根因三後全綠——三個情境逐一驗過,不是一次矇到
- `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0、零警告
- `cabal test all --enable-tests` **191 / 191 綠**(G-E008 的 190 條基線無一轉紅)
- `test_g8_detect_dirty_sources` 的六個既有情境維持綠,其中「非 `.hs` 改動不算」與
  「`.gitignore` 排除的檔不算」兩條特別重要:狀態碼的接受範圍擴大了,這兩條證明沒有擴過頭

**另建議的 enhance 項目**:無。修復途中沒有發現值得另開優化的機會。
