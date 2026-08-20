---
id: ADR-002
type: adr
title: hiedb-backend-import-scan-fallback
description: 函式級抽取採 hiedb SQLite 後端並以 import 掃描保底
status: accepted
created: 2026-08-20
updated: 2026-08-20
---

# ADR-002: 函式級抽取採 hiedb 後端,module 級以 import-scan 保底

## 狀態(Status)

accepted

## 背景(Context)

2026-08-20 在 GHC 9.14.1 上對現成工具做過 spike,結果:

| 工具 | solver | 編譯 | 實測 |
|---|---|---|---|
| calligraphy 0.1.8 | ✅ | ❌ `HieFile` 在 9.14 多了第 7 個欄位(`hie_entity_infos`),pattern arity 不合 | — |
| hiedb 0.8.0.0 | ❌ `hie-compat` 上界 `base < 4.22`;加 `--allow-newer=hie-compat:base` 後 ✅ | ✅ | ✅ index 成功吃 9.14 的 `.hie`,`name-refs` 正確列出跨 module 引用 |

關鍵事實:`--allow-newer` 只能解 solver 層的版本上界(hiedb 的情況),解不了編譯層的 API 變動(calligraphy 的情況)。hiedb 這次是「宣告過時、程式碼碰巧相容」,下次 GHC 升版可能真斷。

## 決策(Decision)

- **函式級抽取**:呼叫外部 `hiedb` 執行檔建索引,knot-hs 讀其 SQLite 投影成圖——省掉整塊「讀 `.hie` 二進位」的工,自己不 link `ghc` library
- **module 級保底**:內建零依賴的 import-scan 後端(掃 import 行);hiedb 不可用時自動降級,`/arch-audit` 所需的 module 級能力永遠可用
- 兩後端實現 extraction 子系統的**同一抽取契約**;「自寫 GHC.Iface.Ext 解析」保留為未來可換的第三後端,hiedb 真斷時啟動
- `hiedb` 由使用者以同版 GHC 加 `--allow-newer=hie-compat:base` 自行安裝,knot-hs 不把它列為 build 依賴

## 考慮過的替代方案(Alternatives Considered)

1. **自寫 `.hie` 解析(備忘原案)**:零第三方風險,但 T1 成本數天~一週;hiedb 實測可用後,先用它換時間,契約抽象保留隨時換回的路
2. **hiedb 當 library 嵌入(build-depends)**:單一執行檔體驗最好,但 `allow-newer` 的編譯連動風險直接進入自己的 build;外部執行檔隔離了這層風險
3. **fork calligraphy**:要長期維護追 GHC API 的 fork,還要再寫格式轉換層,與個人工具定位衝突
4. **純 hiedb、不做 import-scan**:hiedb 斷掃就全斷,且依賴其未文件化的 SQLite schema;保底後端成本僅約 250 行,值得

## 影響(Consequences)

- ✅ 函式級能力立刻可得,S3 成本大幅下降
- ✅ hiedb 斷掉時 module 級(依賴矩陣、循環依賴、跨界引用)不受影響
- ⚠️ 依賴 hiedb 的 SQLite schema(未文件化,升版可能變);extraction 契約把這層隔離在單一後端模組內
- ⚠️ 使用者要多裝一個工具才有函式級;文件要寫清楚安裝指令與 `--allow-newer` 理由
