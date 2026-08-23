---
id: B002
type: bugfix
title: monorepo-main-source-mapping
description: 多套件專案的 executable Main 對不回 pmSources,三個 exe 的 decl 層整個缺席
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: []
related-adr: [ADR-006]
related-feature: [F004, F005, F008]
---

# B002: monorepo 的 executable `Main` 對不回 `pmSources`,decl 層缺席

## 症狀

story-flow(12 套件,3 個 executable)`knot extract` 成功,但 8 則警告裡 6 則是:

```
extract: …/storyflow-cli-0.1.0.0/x/story-flow/build/story-flow/story-flow-tmp/extra-compilation-artifacts/hie/Main.hie:
  cannot map indexed module Main back to pmSources; skipping its decls and refs
extract: …(同一檔)cannot map indexed module Main back to pmSources; skipping its instances
```

(cli / mcp / server 各兩則:hie-facts 與 hie-instances 各一。)圖上有
`Main@cli/app/Main.hs` 三個 module 節點(import-scan 產的),卻**沒有任何一個 `main`
的 decl 節點**;`knot query --level decl reachable StoryFlow.Cli.runCli --reverse` 回 0——
唯一的呼叫者 `main` 不在圖上。

## 影響範圍

- 任何 `cabal.project` 列多個套件、且超過一個套件有 `Main`(多個 executable)的專案
- 受影響的是 **executable 的 decl 層**(`main` 與 exe 內的其他頂層宣告、它們的 `calls` 邊);
  library 的 module 不受影響(module 名唯一,退路成立)
- 單套件專案(MagicFarmer、particle-magic、knot-hs、五個 fixture)碰不到——那些的
  `hs_src` 是 repo 相對或 module 名唯一

## 重現步驟

1. 兩個套件 `a/`、`b/`,各有一個 executable,`main-is: Main.hs` 在各自的 `app/`
   (`test/fixtures/multi-exe/`)
2. `knot extract` → 兩則 `cannot map indexed module Main` 警告;`erFacts` 沒有
   `fdFile = "a/app/Main.hs"` 的 `FactDecl`

## 根因分析

`src/Knot/Extract/HiedbFacts.hs:271-295` `resolveModuleSource` 的兩條路:

1. **`hs_src` 後綴比對**:hiedb 的 `mods.hs_src` 是 GHC 拿到的原始檔路徑。多套件專案裡
   cabal 以**套件目錄**為 cwd 呼叫 GHC,所以 `hs_src = app\Main.hs`——而 `sfPath` 是
   `cli/app/Main.hs`。`matches src rel = src == rel || ("/" <> rel) isSuffixOf src`
   的方向是「`sfPath` 是 `hs_src` 的後綴」,這裡反過來了(`hs_src` 比 `sfPath` 短),不中
2. **module 名唯一比對**:三個套件都有 `Main` → 多筆 → `Nothing`

`src/Knot/Extract/HieInstances.hs:95` 走同一個函數,症狀相同(各多一則警告)。
F004 假設「`hs_src` 走 `makeAbsolute`」只在單套件、cwd = repo 根時成立。

**可用的線索沒被用上**:`.hie` 的路徑裡有 `<pkg>-<ver>` 段(`componentRefOf` 本來就會
解出 `pkgName`),`HieLayout` 每筆更直接帶著 `ComponentRef`;有了套件名就有
`pkgCabalFile` 的目錄,`<套件目錄>/<hs_src>` 正是 `sfPath`。

## 修復方向

在 hie-facts 新增(非契約面,供 hie-instances 共用):

```haskell
resolveModuleSourceFor :: ProjectMeta -> Maybe Text -> ModuleName -> Maybe Text -> Maybe FilePath
--                        ^ 套件名(來自 .hie 路徑或 ComponentRef);Nothing 時退回原函數
```

判定順序:(1) 有套件名、`hs_src` 是相對路徑 → `<pkgDir>/<hs_src>`(正斜線、`.` 化簡)
在 `pmSources` 有同名項 → 納入回 `Just sfPath`、被排除回 `Nothing`(G-B001:不退回猜測);
(2) 其餘一律退回 `resolveModuleSource`(後綴 / 唯一比對,行為不變)。

- hie-facts:`collectFacts` 對每列 `mods.hieFile` 取 `.knot` 之後的段、`componentRefOf` 解出套件名
  (對不到 → `Nothing` → 退路);`buildModIndex` 改收一個 `Text -> Maybe Text` 的套件解析函數
- hie-instances:`HieLayout` 的 `ComponentRef` 直接給套件名
- `resolveModuleSource` 簽名與行為不動(既有測試不改)

## TodoList

- [x] T1: `resolveModuleSourceFor` + hie-facts 以 `.hie` 路徑解套件名、`buildModIndex` 接上  `dep: -`
- [x] T2: hie-instances 以 `ComponentRef` 的套件名呼叫同一函數  `dep: T1`
- [x] T3: fixture `test/fixtures/multi-exe/`(兩套件各一 exe)端到端:零 `cannot map`、兩個 `main` 的 `FactDecl` 都在  `dep: T2`

## 驗證方式

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_b002_resolve_for_package` | 相對 `hs_src` + 套件名 → 命中 `<pkgDir>/<hs_src>`;同一 `hs_src` 在兩個套件下各自命中各自的檔;命中被排除檔 → `Nothing`(不退回);絕對 `hs_src` / 無套件名 / 套件目錄 `.` → 與 `resolveModuleSource` 同結果 |
| T2 | `test_b002_instances_use_package` | `multi-exe` 暫存副本:`readInstanceFacts` 對兩個 exe 的 `.hie` 零 `cannot map` 警告(fixture 無 instance,事實為空屬正常) |
| T3 | `test_b002_multi_exe_end_to_end` | `extract` → `Right`、`erWarnings` 無 `cannot map`;`FactDecl` 含 `a/app/Main.hs` 與 `b/app/Main.hs` 的 `main`;`buildGraph` 有 `Main@a/app/Main.hs.main` 節點且 `calls A.Lib.greet` 的邊存在 |

## 修復紀錄

### 修法(2026-08-23)

- `src/Knot/Extract/HiedbFacts.hs` 新增 `resolveModuleSourceFor`(非契約面)與
  `packageOfHiePath`(`.hie` 路徑取 `.knot/build` 之後的段交 `componentRefOf`);
  `buildModIndex` 改收 `ProjectMeta` 與「hieFile → 套件名」函數;`collectFacts` 接上
- `src/Knot/Extract/HieInstances.hs` 以 `HieLayout` 的 `ComponentRef` 套件名呼叫同一函數
- 新 fixture `test/fixtures/multi-exe/`(套件 `a`、`b` 各一 library + 一 executable)
- `resolveModuleSource` 簽名與行為不動

### 與「修復方向」的偏差(根因比文檔寫的再深一層)

文檔的根因假設是「`hs_src` 是套件相對路徑,後綴比對方向反了」。實作時把 fixture 的
`hiedb.sqlite` 撈出來看,**四列的 `hs_src` 全是 NULL**:hiedb 索引時以 knot 的 cwd
(repo 根)去 stat 套件相對的 `app\Main.hs`,stat 不到就存 NULL。所以 hie-facts 這一路
**從來沒有路徑可比**,只剩 module 名唯一比對——三個 `Main` 歧義 → 落空。hie-instances
那一路不同:它直接讀 `.hie`,`hie_hs_file` 還在(`app\Main.hs`),套件相對精確比對就中。

據此 `resolveModuleSourceFor` 的判定序改為三段:(1) 套件相對精確命中;(2) `hs_src`
後綴命中(與舊函數同規則,單套件 / 絕對路徑);(1)(2) 命中被排除檔 → `Nothing`
(G-B001);(3) **沒有路徑線索**時在**該套件目錄內**以 module 名唯一比對(`a/` 下的
`Main` 只有一個),仍歧義才退回全域舊路。第一版把 (3) 放在 (2) 前面,絕對路徑的
後綴命中會被套件內猜測蓋掉,T1 抓到後調整。

### 量化結果

| | 修前 | 修後 |
|---|---|---|
| `multi-exe` fixture | 2 則 `cannot map`、0 個 `main` decl | **0 則**、`Main@a/app/Main.hs.main` / `Main@b/app/Main.hs.main` 皆在,`a` 的 `main --calls--> A.Lib.greet` 邊存在(T3) |
| story-flow(原路徑) | 6 則 `cannot map`(3 exe × hie-facts + hie-instances)、0 個 `main` decl | **0 則**(只剩 `Paths_storyflow_types` 2 則,另案);**3 個 `main` decl 節點**;1757 → 1768 節點、8016 → 8054 邊 |
| 測試 | 160 綠 | 160 + 3 綠;F004 / F008 既有測試不動 |

### 仍然成立的限制

`Paths_<pkg>` / `PackageInfo_<pkg>` 這類 autogen module 不在 `pmSources`,仍各發一則
`cannot map`(hie-facts 與 hie-instances 各一)——另案。
