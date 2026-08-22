---
id: ADR-004
type: adr
title: private-sublibrary-contract-surface
description: 以 cabal private sublibrary 把 Level 2 契約面收斂為公開 library
status: accepted
created: 2026-08-22
updated: 2026-08-22
---

# ADR-004: 以 private sublibrary 收斂 library 公開面

## 背景

knot-hs 的 `library` 目前把 `src/` 全部 26 個模組列進 `exposed-modules`,其中
17 個是子系統內部模組。四次子系統閘門累積出 **31 個非契約面匯出**(盤點見
G-E001):21 個純為 1-to-1 測試而匯出、9 個是 Haskell 模組間呼叫的必要匯出、
1 個由 executable 消費。

Haskell 的模組匯出清單沒有「只對同 package 的兄弟模組開放」這種可見度,
所以「模組 A 要呼叫模組 B 的函式」與「這個函式屬於子系統對外契約」在單一
library 佈局下無法區分——只靠註解標示 `-- 非契約面`,沒有任何機制阻止它
被當契約用。

## 決策

package 改為**雙 library 佈局**:

```
library knot-internal        -- visibility: private
    hs-source-dirs:   src
    exposed-modules:  <全部 26 個模組,各模組匯出清單原樣不動>

library                      -- 公開面 = Level 2 契約
    reexported-modules: Knot.Meta, Knot.Meta.Types
                      , Knot.Extract, Knot.Extract.Types
                      , Knot.Graph, Knot.Graph.Types
                      , Knot.Export, Knot.Export.Types
                      , Knot.Query
    build-depends:      knot-hs:knot-internal

executable knot     build-depends: knot-hs                 -- 只看得到那 9 個
test-suite knot-test build-depends: knot-hs:knot-internal   -- 看得到全部 26 個
```

**exe 依賴公開 library、test-suite 依賴 private sublibrary**,是這個佈局的
關鍵:違反契約的 import 在 exe 端是**編譯錯誤**,而測試仍摸得到內部純函數。

## 實測證據(2026-08-22 spike,`C:\Users\User\AppData\Local\Temp\kspike`)

環境:cabal-install 3.16.1.0(Cabal 3.16.1.0 in-tree)、GHC 9.14.1、
`cabal-version: 3.4`、`default-language: GHC2024`——與 knot-hs 同組工具鏈。

| 驗的事 | 結果 |
|---|---|
| 公開 library 只有 `reexported-modules`、無 `hs-source-dirs` / `exposed-modules` | ✅ 建置通過 |
| `reexported-modules` 從 `visibility: private` 的 sublibrary 再匯出 | ✅ 建置通過,exe 用得到 |
| test-suite 直接 `build-depends: <pkg>:<sublib>` 取用未被 reexport 的模組 | ✅ 建置通過,`cabal test` PASS |
| **負向**:exe import 未被 reexport 的私有模組 | ✅ **編譯失敗**,`GHC-87110: Could not load module ‘Spike.Guts’. It is a member of the hidden package ‘spike-0.1.0.0:spike-internal’.` |
| G-E002 的閘門指令 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` | ✅ 在雙 library 佈局下照常成立 |

負向那一列是採用這個方案的**唯一理由**:沒有它,雙 library 只是把註解換個
地方寫,強制力仍為零。

**踩到的環境坑(與方案無關,記錄以免重踩)**:spike 一開始建在 session
scratchpad 下,`ghc-pkg` 寫 `dist-newstyle/.../l/<sublib>/package.conf.inplace`
時炸 `openBinaryTempFileWithDefaultPermissions: invalid argument`——是 Windows
MAX_PATH,不是 sublibrary 不支援。sublibrary 的 `dist-newstyle` 路徑比單
library 深,深目錄下的專案要留意。

## 後果

**得到**

- 公開面從 26 個模組降為 9 個;31 個非契約面匯出全數退出公開面
- 契約違反從「靠人看註解」變成「exe 編譯失敗」,可在 CI 攔截
- 內部模組重構(改匯出、拆模組)不再動到公開面,不必回頭改架構文件

**付出**

- `.cabal` 多一個 stanza;`build-depends` 要分辨 `knot-hs` 與 `knot-hs:knot-internal`
- executable 專用的工具函式不能再寄居 library 契約模組(`defaultOutputPath`
  因此移進 `Knot.App.Cli`)
- 未來若真的要對外開放某個內部模組,是**加一行 `reexported-modules`** 的
  明示動作,而不是預設就開著——這是本決策要的效果,不是缺點

**不做**

- 不改任何模組的 `module ... ( ... ) where` 匯出清單:模組層級的匯出紀律
  仍由各子系統自理,本 ADR 只管 package 層級的可見度
- 不引入 Backpack 的 signature/mixin;`reexported-modules` 是純粹的模組再匯出

## 替代方案與否決理由

| 方案 | 否決理由 |
|---|---|
| 維持單 library + 註解標示 | 零強制力;四次閘門的實績是匯出面只增不減 |
| test-suite 以 `hs-source-dirs: src` 共用原始碼 | **解不了問題**:模組匯出清單照樣生效,測試依然看不到未匯出的函式 |
| `Knot.X.Internal` 慣例模組 | 只是換名字,`Internal` 模組仍在 `exposed-modules`,公開面一樣寬 |
| 刪掉純測試用匯出、改由契約層測試涵蓋 | 21 條 1-to-1 測試會退化為間接斷言,違反 dev-flow 的 1-to-1 紀律 |

## 相關

- G-E001(本決策的落地文檔,含 31 個匯出的逐項盤點)
- G-E002(閘門指令 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror`)
- ADR-001(GHC 版本鎖;本決策的驗證綁定同一組工具鏈)
