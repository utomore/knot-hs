---
id: ADR-001
type: adr
title: ghc-version-locked-toolchain
description: 工具與目標專案同 GHC 版本編譯的硬性版本鎖策略
status: accepted
created: 2026-08-20
updated: 2026-08-20
---

# ADR-001: 以 Haskell 實作並鎖定與目標專案同版的 GHC 工具鏈

## 狀態(Status)

accepted

## 背景(Context)

`.hie` 檔的二進位格式綁 GHC 版本:讀寫必須用同版 GHC 的 `GHC.Iface.Ext.*`。目標環境是 GHC 9.14.1(base 4.22)、cabal-install 3.16.1.0、`GHC2024`——工具鏈走在最前面,第三方套件普遍還沒跟上(實測見 ADR-002)。

## 決策(Decision)

- knot-hs 以 **Haskell** 實作,**必須用與目標專案相同的 GHC 版本編譯**;版本鎖視為設計約束,不是缺陷
- 發佈形式為 `cabal install` 的獨立執行檔;文件明載版本鎖要求
- 執行時檢查 `.hie` header 的 GHC 版本,不合者告警(best-effort 下跳過)
- 核心解析能力只依賴編譯器自帶的 library(`ghc == 9.14.*`),不把第三方 `.hie` 解析套件納入必要路徑

## 考慮過的替代方案(Alternatives Considered)

1. **其他語言實作(如 Node.js,貼近下游 scan-graph.mjs)**:必須自己重刻 `.hie` 二進位格式解析,且每次 GHC 改格式就重寫;Haskell 直接用編譯器自帶 library,格式知識零成本
2. **不鎖版本、做多 GHC 相容層(hie-compat 式 CPP)**:體量定位是個人工具,只服務自己手上的 GHC 版本;相容層是 Hackage 發佈等級的成本,不在範圍(見 system.md 非目標)

## 影響(Consequences)

- ✅ 零第三方套件落後風險:`ghc` library 永遠與編譯器同步
- ✅ 讀到的是型別檢查後、名稱全解析的事實,不需要 confidence 猜測
- ⚠️ GHC 升版時 knot-hs 要用新版重編,若 `GHC.Iface.Ext.*` API 變動需跟進修正
- ⚠️ 多專案多 GHC 版本並存時,需各裝一份對應版本的執行檔
