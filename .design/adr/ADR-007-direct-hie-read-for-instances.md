---
id: ADR-007
type: adr
title: direct-hie-read-for-instances
description: implements 邊改由 knot 直接讀 .hie 取得,ghc library 成為直接相依
status: accepted
created: 2026-08-23
updated: 2026-08-23
---

# ADR-007: `implements` 邊直接讀 `.hie`,`ghc` library 成為直接相依

## 狀態(Status)

accepted(2026-08-23)。落地 feature:`extraction/F008`。

## 背景(Context)

五種 relation 裡只剩 `implements` 沒有產出。原因自 S3 起就清楚:hiedb 0.8 的索引
schema(mods / decls / defs / refs / exports / imports / typenames / typerefs)沒有
instance 表,`FactInstance` 需要的「class + instance 標頭」在索引裡不存在
(`extraction/F004` 實測,system.md「`implements` 邊不在 S3」)。graph-core 那一側
(`graph-core/F003`)已把 instance 節點鑄造與 `RImplements` 推導做完,只等事實。

ADR-006 當時記下兩條路線、都未採用:「從 refs 反推」或「直接讀 `.hie`」。2026-08-23
對 knot-hs 自身與一份涵蓋七種 instance 寫法的 fixture 做 spike(GHC 9.14.1
`GHC.Iface.Ext.Binary.readHieFile`),結論:

- 每個明寫的 `instance` 在 `.hie` 的 AST 裡是一個 `ClsInstD` 節點,第一個子節點就是
  標頭;標頭原文可從 `hie_hs_src`(`.hie` 內嵌的完整原始碼)依 span 切出
- class 名由標頭子樹的形狀決定(去 context、剝括號、取最左 `HsTyVar`),對本地與外部
  class 一體適用;GHC 9.14 新增的 `hie_entity_infos` 對外部 class 只標 `TypeConstructor`,
  不能依賴
- `deriving` 的任何形式都**不產生**節點——不需要過濾產生碼

## 決策(Decision)

### 1. `FactInstance` 由 extraction 新站 hie-instances **直接讀 `.hie`** 產出

不經 hiedb 索引,不解析 `$fClassType` 字典名,不擴充 hiedb schema。讀的是
build-driver 已經產好、hie-index 已經做過版本過濾的同一批 `.hie`。

### 2. `knot-internal` 直接相依 `ghc` library,但**只准一個模組 import `GHC.*`**

`GHC.Iface.Ext.Binary` / `GHC.Iface.Ext.Types` 住在 `ghc` package。hiedb 本來就
`build-depends: ghc`(`hiedb.cabal`),所以 knot 的**相依閉包沒有變大、執行檔沒有變大**,
變的只是 knot 自己的原始碼開始直接叫 GHC 的 API。為了不讓這條耦合擴散:

- `knot-hs.cabal` 的 `library knot-internal` 加 `ghc ^>=9.14`(版本由 ADR-001 的鎖決定)
- `src/` 下**只有 `Knot.Extract.HieInstances`** 可以 `import GHC.*`,以測試文字守門
  固定(比照 G-E001 的 `test_app_imports_within_contract`)
- `.hie` 的型別(`HieFile`、`HieAST` …)**不得**出現在任何 Level 2 介面或 DTO 上;
  hie-instances 對外只回 `[Fact]` 與 `[ExtractWarning]`

### 3. 本站永遠是 best-effort,不引入新的整體失敗

建不起來、版本不合、零 `.hie` 已由站 2、3 以 `ExtractFailure` 結束;hie-instances
單檔讀不過或對映不到 → 警告 + 跳過(規則 9)。「兩層缺一不可」的判準不變:decl 層
成立 = 至少一筆 `FactDecl`;一個專案合法地可以零 instance。

## 考慮過的替代方案(Alternatives Considered)

1. **從 hiedb 的 `decls` / `defs` 反推**:`$fRenderableSprite` 這類字典名在索引裡
   (`ValBind InstanceBind` 的 `is_root`)。否決:class 與型別要從字典名**字串拆解**
   (`$fShowMaybe`、`$fEqT0` 這種消歧後綴、多參數 class 無分隔符),而且拿不到
   instance 標頭原文——graph-core 的 instance 節點 id 需要它
2. **fork / 擴充 hiedb 加 instance 表**:要維護一份 hiedb 分支,與 ADR-006「嵌入上游
   hiedb、不自己養一套」相反
3. **在 knot 程序內跑完整 GHC API 型別檢查**(ADR-006 替代方案 3):仍是
   `hie-bios` 等級的難題;本決策只讀 GHC 已經寫好的檔,不重建編譯環境
4. **`ghc-lib-parser` 從原始碼文字找 `instance`**:可以拿到標頭原文,但 class 的
   定義 module 要靠名稱解析猜;與 ADR-006 否決 `ghc-lib-parser` 的理由相同

## 影響(Consequences)

- **正面**:`implements` 邊成立,五種 relation 齊全;extraction 第一次有了不經 hiedb
  的 `.hie` 讀取能力,日後若要補 hiedb 丟掉的 `DeclType`(class / type synonym /
  family 的精確 `DeclKind`,見 extraction DTO 註解)可以沿同一條路
- **負面 / 代價**:knot 原始碼開始直接耦合 GHC 的 HIE API——GHC 大版本升級時,除了
  hiedb 可能要等上游,knot 自己的 `HieInstances.hs` 也可能要跟著改。ADR-001 的版本鎖
  已經接受「每版 GHC 各裝一份 knot」,這條只是讓鎖多管一個檔案
- 每個 `.hie` 會被讀兩次(hiedb 索引一次、hie-instances 一次);spike 顯示單檔讀取在
  毫秒級,相對 cabal build 可忽略
- system.md「關鍵依賴」新增 `ghc` library 一條;「`implements` 邊不在 S3」段改指向 F008

## 相關

- ADR-001(版本鎖:`.hie` 讀取器在 `ghc` library 內,精確比對版本)
- ADR-006(替代方案 2、3 的否決理由仍成立;本決策是其「直接讀 `.hie`」路線的落地)
- `extraction/F008`、`graph-core/F003`、`extraction/F004`(schema 實測)
