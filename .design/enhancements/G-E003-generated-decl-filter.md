---
id: G-E003
type: enhance
title: generated-decl-filter
description: 產生碼過濾只擋 ref 不擋 decl,deriving 字典污染 decl 層節點
status: open
created: 2026-08-22
updated: 2026-08-22
depends-on: []
related-adr: [ADR-002]
related-feature: [extraction/F004, graph-core/F002, graph-core/F003]
subsystems: [extraction, graph-core]
---

# G-E003: 產生碼過濾的不對稱與 deriving 字典節點

## 發現依據(2026-08-22 graph-core 階段二閘門)

graph-core 的組裝規則 3 有三個過濾條件,其中 (c) `FactRef.frGenerated = True` 在 knot-hs 自身實測濾掉 **846 筆** deriving/TH 產生的引用。但**產生碼的宣告本身一筆都沒被濾掉**。

編排者於閘門唯讀實跑 knot-hs 自身取證:

```
knot extract . --db <專案外路徑>
→ 654 nodes / 2267 edges
   節點 = 31 module + 623 decl + 0 instance
```

623 個 decl 節點中,**106 個(17%)是 deriving 產生的 dictionary 繫結**:

```
Knot.App.Cli.$fEqCommand          Knot.Export.Types.$fShowExportReport
Knot.App.Cli.$fShowSummaryMode    Knot.Extract.Backend.$fEqProbeResult
Knot.Extract.HiedbFacts.$fFromRowDefRow
Knot.Extract.HiedbFacts.$fExceptionHiedbFactsError   …(共 106 個)
```

## 為什麼會不對稱(這是本文檔的重點)

**hiedb 只在 `refs` 表有 `is_generated` 欄,`decls` 與 `defs` 表沒有。**

extraction 的抽取規則 4a 忠實轉載了它有的那一半(`FactRef.frGenerated`),而 `FactDecl` 的 DTO 因此**沒有對應欄位**——不是 extraction 漏掉,是上游資料就只有一半。graph-core 的規則 3 只能濾它拿得到的那一半,於是形成:

| | 產生碼 | 是否被濾 |
|---|---|---|
| `FactRef`(引用) | 846 筆 | ✅ 規則 3 (c) |
| `FactDecl`(宣告) | 106 個節點 | ❌ **無旗標可依** |

結果是圖裡出現一批「沒有任何人寫過那些行」的節點,而且它們**稀釋 hub 排名**——decl 層節點總數被灌水 17%,連通度排名的分母跟著失真。

## 同源的第二個症狀:19 則 unresolved 警告

閘門實跑的 19 則警告全是 `unresolved reference target $f…`:

```
graph: src/Knot/Extract/Types.hs: unresolved reference target $fShowFact; 2 ref edge(s) dropped
graph: app/Knot/App/Cli.hs: unresolved reference target $fEqBackendChoice; 1 ref edge(s) dropped
```

graph-core/F003 追出根因:**hiedb 的 `defs` 表隨索引建法而異**——`hiedb index <目錄>` 得 631 列,而 knot 的 HiedbDriver 逐檔傳 `hieFiles`(為了排除幽靈檔)得 623 列,兩者的 `mods` / `decls` / `refs` 三表**逐列相同**,只有 `defs` 差 8 列。少的 8 列全是 deriving instance 字典(`$fEqBackendChoice`、`$fShowFact` 等),連帶 **25 筆 ref 解析不到目標**。

換句話說:**同一批 deriving 字典,有些進了圖(106 個節點)、有些沒進(8 個),取決於索引怎麼建。** 這個不一致本身就是雜訊來源。

## 量化目標

1. `knot extract` 對 knot-hs 自身產出的 decl 節點中,deriving 產生的 dictionary 繫結為 **0**(目前 106)
2. `unresolved reference target $f…` 類警告為 **0**(目前 19 則 / 25 筆)
3. 兩種 hiedb 索引建法(走目錄 vs 逐檔清單)產出的圖**完全相同**(目前差 8 節點 / 33 邊)
4. 既有 134 條測試零回歸;決定性不變(兩次輸出位元相同)

## 待調查的方向(不是結論,實作前要先驗證)

- **A. `.hie` 直讀**:GHC 的 `HieAST` 有 `NodeAnnotation` 與 origin 資訊,可能分得出 deriving 產生碼。這條等於 ADR-002 預留的第三後端,成本最高但精度最好
- **B. hiedb `decls.is_root` 之外的欄位**:先把 `decls` / `defs` 兩表的完整 schema 再查一次,確認真的沒有可用旗標(extraction/F004 查過 `is_generated`,但沒逐欄確認)
- **C. occ 名啟發式**:`$f` 前綴是 GHC 對 instance dictionary 的內部命名慣例。**與 graph-core design.md「不做啟發式」的原則相衝**,採用前需要開發者裁決是否鬆綁該原則(或把它定位成 extraction 側的事實標註而非 graph-core 的猜測)
- **D. 索引建法一致化**:單獨解掉症狀 2 —— 但要先確認逐檔傳 `hieFiles` 是為了排除幽靈檔(extraction/F003 W3 實測:單一 0-byte 假 `.hie` 會讓整批 exit 1),不能直接改回走目錄

## 影響範圍

- **extraction**:若走 A/B/C,`FactDecl` 需要新增欄位 → **Level 2 契約變更**,graph-core 的規則 3 連帶更新
- **graph-core**:規則 3 增加第四條件;`gsFilteredGenerated` 的語意由「濾除的 ref 數」變成「濾除的事實數」
- **不影響**:module 層行為、匯出格式、查詢 CLI

## 明確不做

- 不改 `GraphStats` 加欄位(階段二 E4 已裁定)
- 不動 `gsTopExternalTargets` 的呈現(那是另一件事,見 graph-core build-log 階段二發現 2)
