---
id: F008
type: feature
title: hie-instances
description: 直接讀 .hie 的 ClsInstD 節點產出 FactInstance,讓 implements 邊成立
status: done
created: 2026-08-23
updated: 2026-08-23
depends-on: [F001, F004, F005, F006, F007, G-E006]
related-adr: [ADR-007, ADR-006, ADR-001]
related-feature: [graph-core/F003]
---

# F008: hie-instances——直接讀 `.hie` 產出 `FactInstance`

## 功能概述

**要解決的問題**:五種 relation 裡 `implements` 是唯一沒有產出的。hiedb 0.8 的索引
schema 沒有 instance 表(F004 實測八張表),`FactInstance` 自 F001 起就是「建構子保留、
零邏輯」;graph-core 那一側的 instance 節點鑄造與 `RImplements` 推導(`graph-core/F003`)
已經完整,差的只是事實來源。ADR-006 記下的兩條路線——「從 refs 反推」或「直接讀
`.hie`」——本 feature 走後者(裁決理由見 ADR-007)。

**2026-08-23 spike 證據**(對 knot-hs 自身與一份刻意涵蓋各種 instance 形式的 fixture
各跑一次,工具:GHC 9.14.1 的 `GHC.Iface.Ext.Binary.readHieFile`):

| 觀察 | 結果 |
|---|---|
| 明寫的 `instance … where` | 每一個都是一個帶 `NodeAnnotation "ClsInstD" "InstDecl"` 的 `HieAST` 節點,origin `SourceInfo` |
| 節點的第一個子節點 | 就是 instance 標頭(帶 `HsSig/HsSigType` 註記),其 `nodeSpan` 切出的原文正是 `Renderable a => Renderable (Wrapper a)` 這種字串 |
| class 名 | 標頭子樹去掉 `HsQualTy` 的 context(最後一個子節點才是 body)、剝 `HsParTy` 後,**最左邊的 `HsTyVar` 葉節點**的 `Name`;`nameModule_maybe` 給出 class 定義所在 module |
| `hie_entity_infos` | 本地 class 標 `EntityTypeClass`,**外部 class(`Show`、`FromRow`)只標 `EntityTypeConstructor`**——所以不能靠它認 class,要靠上面的樹形規則 |
| `deriving (Eq, Show)` 子句、`deriving instance`、`deriving anyclass instance` | **完全沒有 `ClsInstD` 節點**(fixture 7 個明寫 instance → 恰 7 個節點,3 個 deriving 形式 → 0 個) |
| 字典繫結 `$fRenderableSprite` | 在標頭節點上,context `EvidenceVarBind`,module = instance 所在 module |
| 多參數 class `instance Convert Sprite Int` | 標頭是左結合的 `HsAppTy` 巢狀,最左 `HsTyVar` 仍是 class |

**驗收標準**(對齊契約卡):

1. fixture `test/fixtures/instances/`(可建置)上 `extract` 回 `Right`,`erFacts` 含的
   `FactInstance` 筆數 = fixture 明寫的 instance 數、deriving 形式零筆;每筆 `fiInstHead`
   與原始碼標頭逐字相同(多行標頭以單一空白接合)、`fiClass` 的 `qnModule` 指向 class
   定義 module、`fiInstFile` 是 `sfPath` 原文、`fiInstLine` 是標頭起始行
2. 同一 fixture 經 `buildGraph` 得到 instance 節點(id 形如 `<mod>#i:<head>`)與
   `RImplements` 邊(class 為內部 module 時);class 為外部(`Show`)時無邊、計入
   `gsDroppedExternal`——graph-core 零修改
3. knot-hs 自掃:`FactInstance` 筆數 ≥ `src/` 明寫的 `instance` 行數(2026-08-23 為 3),
   0 警告;五份黃金檔 `codegraph.json` **byte 不變**(黃金 fixture 不可建置、走
   `scanImports` + `buildGraph`,不經本站)
4. 單一 `.hie` 讀不過或對映不到 `pmSources` → 一則警告、跳過、仍回 `Right`(規則 9);
   本站**不會**產生任何 `ExtractFailure`
5. 閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` exit 0,
   `knot-hs.cabal` 的 `knot-internal` 新增 `ghc` 相依,且 `src/` 內 **只有**
   `Knot.Extract.HieInstances` import `GHC.*` 模組(ADR-007 的邊界)

## 相依性

`depends-on: [F001, F004, F005, F006, F007, G-E006]`,全部已 `done` 或為文檔性變更:

| 相依 | 為什麼 | 性質 |
|---|---|---|
| F001 | `Fact` 的 `FactInstance` 建構子、`QualName`、`NameSpace.TypeNs`、`ExtractWarning` | 既有程式碼 |
| F004 | `resolveModuleSource`——`.hie` 的 `hie_hs_file` 對回 `sfPath`,G-B001 的「命中被排除檔即跳過」規則沿用同一函數 | 既有程式碼 |
| F005 | `HieLayout`(`hlFiles` 是本站的輸入清單) | 既有程式碼 |
| F006 | `partitionByGhc` / `ownGhcVersion`——只讀與 knot 同版 GHC 的 `.hie`(規則 8);`makeNc` 的用法 | 既有程式碼 |
| F007 | `Pipeline.Stages` 記錄與 `runPipeline`——本站是第五站,接在 hie-facts 之後 | 既有程式碼 |
| G-E006 | `HieLayout` 的定義將從 `Knot.Extract.Types` 搬到 `Knot.Extract.BuildDriver`;本 feature 的 import 寫法以搬家後為準 | 文檔 / 匯出清單變更,`open` |

**可與 G-E006 平行設計、但實作要排在它之後**(否則 import 來源要改兩次)。與
project-meta / export-query 無關。graph-core **不需要改程式碼**(`graph-core/F003` 已把
`FactInstance` 的兩條推導做完),只改 `design.md` 一句「目前無後端產出」的註記。

## 對應的 Level 2 契約

| 契約條目 | 本 feature 落實 |
|---|---|
| 對外契約 `extract :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)` | 簽名不變;`erFacts` 多出 `FactInstance` |
| 事實流 DTO `FactInstance { fiClass :: QualName, fiInstHead :: Text, fiInstFile :: FilePath, fiInstLine :: Int }` | 首次填實;欄位不動 |
| 抽取規則 2(來源職責互斥) | 新增一句:`FactInstance` **永遠且只**來自 hie-instances |
| 抽取規則 3(兩層缺一不可) | **不動**:decl 層「成立」的判準仍是至少一筆 `FactDecl`;`FactInstance` 零筆不是失敗(一個專案可以合法地沒有 instance) |
| 抽取規則 8(GHC 版本相容) | 同 hie-index:只讀 `ghc-<knot 版本>/` 目錄下的 `.hie` |
| 抽取規則 9(單檔 best-effort) | 單一 `.hie` 讀取失敗 / 對映不到 → 警告 + 跳過 |
| 抽取規則 10(決定性) | `FactInstance` 依 `(fiInstFile, fiInstLine, fiInstHead)` 排序,併入 `erFacts` 的全序 |
| 內部模組劃分 | 新增 **hie-instances** 一站(本 feature 回填 `design.md`) |
| 模組間公開介面 | 新增 `readInstanceFacts`(下方「新增的介面」) |

未超出範圍:不動 `ExtractFailure`、不動 `HieLayout`、不動 `IndexHandle`、不碰 hiedb 索引。

## 實作方式

### 資料流

```text
HieLayout ──partitionByGhc ownGhcVersion──▶ [(ComponentRef, .hie 路徑)]   (規則 8)
   每個 .hie ──readHieFile nc──▶ HieFile
        │  hie_hs_file ──resolveModuleSource pmSources──▶ sfPath   (落空 → 警告跳過,G-B001 同規則)
        │  hie_asts 走訪:origin == SourceInfo 且 nodeAnnotations ∋ ("ClsInstD", _) 的節點
        │       head = nodeChildren !! 0
        │       fiInstHead = slice (hie_hs_src) (nodeSpan head),空白正規化
        │       fiClass    = leftmostTyVar (peel head) → Name → QualName (module, occ, TypeNs)
        │       fiInstLine = srcSpanStartLine (nodeSpan head)
        ▼
   [FactInstance] 依 (file, line, head) 排序 ──▶ fact-pipeline 第五站併入 erFacts
```

### 模組 `Knot.Extract.HieInstances`(hie-instances)

1. **輸入過濾**:`partitionByGhc ownGhcVersion layout` 取相符清單(零相符的情況
   hie-index 已經以 `VersionMismatch` 失敗,本站不會被呼叫到;防禦性地對空清單回空)
2. **讀檔**:`nc <- makeNc`(hiedb 提供,含 GHC 的 `knownKeyNames`,與索引用同一種
   `NameCache`),逐檔 `try (readHieFile nc path)`;`SomeException` → 警告
   `(ewSource = 該 .hie 相對路徑, "cannot read .hie: …")`,跳過
3. **對映**:`resolveModuleSource (pmSources pm) (ModuleName <$> hie_module) (Just hie_hs_file)`
   → `Nothing` 時警告 `cannot map … back to pmSources; skipping its instances`(措辭比照
   hie-facts)並跳過
4. **走訪**:對 `getAsts (hie_asts hf)` 每棵樹深度優先;節點的 `sourcedNodeInfo` 中
   **只看 `SourceInfo` 那份** `NodeInfo`(`GeneratedInfo` 的 `ClsInstD` 是 TH / deriving
   衍生物,不是使用者寫的架構事實;spike 顯示 deriving 根本不產生節點,這條是防禦)
   ;`nodeAnnotations` 含 `nodeAnnotConstr == "ClsInstD"` 即為一個 instance
5. **標頭**:`nodeChildren` 的第一個節點;`hie_hs_src` 依 `nodeSpan` 的起迄行列切片,
   `T.unwords . T.words` 正規化(多行標頭、縮排、tab 一律收斂為單一空白)。**不**用
   GHC 的 pretty-printer 重排(那會改寫使用者寫法,id 就不再是「看原始碼就能猜到」)
6. **class**:對標頭節點做 `peel`:
   - 註記含 `HsQualTy` / `HsForAllTy` → 取**最後一個**子節點(body)
   - 註記含 `HsParTy` / `HsKindSig` → 取第一個子節點
   - 註記含 `HsAppTy` → 取第一個子節點(左結合,函數位置)
   - 註記含 `HsTyVar` → 葉:取 `nodeIdentifiers` 中 `Right name` 且 `identInfo ∋ Use` 的
     `Name`;`nameModule_maybe name` 為 `Just m` → `QualName (ModuleName (moduleNameString
     (moduleName m))) (occNameString (nameOccName name)) TypeNs`
   - 其他形狀(`HsOpTy` 中綴 class、`HsTupleTy` 等)→ 警告
     `(ewSource = sfPath, "cannot resolve class of instance <head>")`,跳過該 instance
   - 同一節點可能同時帶多個註記(spike:標頭節點本身就同時是 `HsSig`、`HsAppTy`、
     `VarBind`),判定順序即上列順序,先命中者先
7. **排序與回傳**:`sort` 後回 `([Fact], [ExtractWarning])`;警告依檔案碼位序

`Fact` 已有 `Ord`(F007 規則 10 要求 `sort (moduleFacts <> declFacts)`),`FactInstance`
落在既有全序內,不需另訂。

### fact-pipeline 第五站

`Stages h` 加一欄

```haskell
  , stInstances :: ExtractOptions -> HieLayout -> ProjectMeta -> IO ([Fact], [ExtractWarning])
    -- ^ 站 5 hie-instances:FactInstance;單檔失敗已在站內轉警告,不會失敗
```

`runPipeline` 在站 4 之後呼叫站 5,`erFacts = sort (moduleFacts <> declFacts <> instFacts)`、
`erWarnings = scanWarns <> factWarns <> instWarns`;**規則 3 的判準 `any isDecl declFacts`
只看站 4 的結果**,站 5 零筆不影響 `Right`。`realStages` 接 `readInstanceFacts`。

### `ghc` 相依的邊界(ADR-007)

`knot-hs.cabal` 的 `library knot-internal` 加 `ghc`(版本由 ADR-001 的鎖決定,寫
`ghc ^>=9.14`);**只有 `Knot.Extract.HieInstances` 准 import `GHC.*`**。T5 以文字守門
固定這條(比照 G-E001 的 `test_app_imports_within_contract` 寫法):`src/` 下除該檔外
不得出現 `import GHC.`。

### 錯誤處理

本站沒有整體失敗的情境:建不起來 / 版本不合 / 零 `.hie` 都已在站 2、3 以
`ExtractFailure` 結束。站內任何例外一律收斂為該檔一則警告(`try @SomeException`),
與 hie-index / hie-facts 同模式;**不在管線層包 `try`**(F007 的紀律)。

### 不做

- 不讀 `deriving` 任何形式(`.hie` 裡沒有節點,也不該有:那不是使用者畫的架構線)
- 不為 `FactInstance` 加產生碼旗標(DTO 不動;只取 `SourceInfo` 已達同樣效果)
- 不解析 instance **方法**的引用(`calls` 邊仍由 hie-facts 的 refs 負責,方法繫結的
  `$c…` 不另建節點)
- 不處理 `.hie-boot`
- 不改 hiedb 索引 schema、不 fork hiedb

## 使用到的既有串接介面

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Fact = … \| FactInstance { fiClass :: QualName, fiInstHead :: Text, fiInstFile :: FilePath, fiInstLine :: Int }` | `src/Knot/Extract/Types.hs:96-99` | F001 | 產出的事實 |
| `data QualName = QualName { qnModule :: ModuleName, qnOcc :: Text, qnSpace :: NameSpace }` | `src/Knot/Extract/Types.hs:54-58` | F001 | `fiClass` |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` | `src/Knot/Extract/Types.hs` | F001 | 單檔警告 |
| `resolveModuleSource :: [SourceFile] -> ModuleName -> Maybe Text -> Maybe FilePath` | `src/Knot/Extract/HiedbFacts.hs:272-276` | F004 | `hie_hs_file` → `sfPath`;被排除檔即跳過(G-B001) |
| `data HieLayout = HieLayout { hlRoot :: FilePath, hlFiles :: [(ComponentRef, FilePath)] }` | `src/Knot/Extract/Types.hs:129-133`(G-E006 後:`BuildDriver.hs`) | F005 | 輸入清單 |
| `partitionByGhc :: Text -> HieLayout -> ([(ComponentRef, FilePath)], [Text])` | `src/Knot/Extract/HieIndex.hs:147` | F006 | 規則 8 過濾 |
| `ownGhcVersion :: Text` | `src/Knot/Extract/HieIndex.hs:127-128` | F006 | 同上 |
| `makeNc :: IO NameCache` | hiedb-0.8.0.0 `src/HieDb/Utils.hs:94`(經 `HieDb` 匯出;`HieIndex.hs:55` 已 import) | F006 | `NameCache` |
| `readHieFile :: NameCache -> FilePath -> IO HieFileResult`;`hie_file_result :: HieFileResult -> HieFile` | ghc-9.14.1 `GHC.Iface.Ext.Binary`(ghci `:t` 查證) | - | 讀 `.hie` |
| `HieFile { hie_hs_file :: FilePath, hie_module :: Module, hie_asts :: HieASTs TypeIndex, hie_hs_src :: ByteString, … }`;`HieAST { sourcedNodeInfo :: SourcedNodeInfo a, nodeSpan :: Span, nodeChildren :: [HieAST a] }`;`NodeInfo { nodeAnnotations :: Set NodeAnnotation, nodeIdentifiers :: NodeIdentifiers a }`;`NodeAnnotation { nodeAnnotConstr, nodeAnnotType :: FastString }`;`data NodeOrigin = SourceInfo \| GeneratedInfo`;`IdentifierDetails { identInfo :: Set ContextInfo }` | ghc-9.14.1 `GHC.Iface.Ext.Types`(ghci `:info` 查證) | - | AST 走訪 |
| `data Stages h = Stages { stScan, stBuild, stIndex, stFacts }`;`runPipeline :: Stages h -> ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)` | `src/Knot/Extract/Pipeline.hs:44-62` | F007 | 加第五站 |
| `realStages :: Stages IndexHandle` | `src/Knot/Extract.hs:23-29` | F007 | 接線 |

## 新增的介面

```haskell
-- hie-instances(模組間公開介面,回填 design.md)
readInstanceFacts :: ExtractOptions -> HieLayout -> ProjectMeta -> IO ([Fact], [ExtractWarning])
```

- 只產 `FactInstance`;不拋例外;零 instance 回 `([], [])`
- `Stages` 新欄位 `stInstances`(同簽名);非契約面,與其他四站同為測試注入點

對外契約 `extract` 與全部 DTO **不變**。

## TodoList

- [x] T1: 接線——`knot-hs.cabal` 加 `ghc`;新模組 `Knot.Extract.HieInstances` 骨架匯出 `readInstanceFacts`(先回空);`Stages` 加 `stInstances`、`runPipeline` 併入第五站、`realStages` 接上;`GHC.*` import 邊界守門  `dep: G-E006`
- [x] T2: 讀檔與對映——`makeNc` + `readHieFile`、`partitionByGhc` 過濾、`resolveModuleSource` 對回 `sfPath`、兩種失敗各一則警告並跳過  `dep: T1`
- [x] T3: 標頭——`SourceInfo` 的 `ClsInstD` 節點走訪、第一子節點為標頭、`hie_hs_src` 切片與空白正規化、`fiInstLine`  `dep: T2`
- [x] T4: class——`peel` 樹形規則(`HsQualTy`/`HsForAllTy` 取尾、`HsParTy`/`HsKindSig`/`HsAppTy` 取首、`HsTyVar` 取 `Use` 的 `Name`)→ `QualName`,無法解析 → 警告跳過  `dep: T3`
- [x] T5: fixture `test/fixtures/instances/` + 端到端與自掃驗收、決定性、黃金檔不變、`design.md` / graph-core `design.md` / system.md 回填  `dep: T4`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `test_instances_stage_wiring` | 假五站(`h = ()`):`stInstances` 回一筆 `FactInstance` → `erFacts` 含之且全序排序;其警告排在 `factWarns` 之後;`stFacts` 零 `FactDecl` 時即使 `stInstances` 有事實仍 `Left IndexFailed`(規則 3 不看 instance);`src/` 下只有 `HieInstances.hs` 含 `import GHC.` |
| T2 | `test_instances_read_best_effort` | 對 `buildable` fixture 暫存副本:清單含一個不存在的 `.hie` 路徑 → 一則警告、其餘正常;`pmSources` 全標 `sfIncluded = False` 的副本 → 每個 `.hie` 一則 `cannot map` 警告、零事實、仍 `Right`-等價(函數回 `([], ws)`) |
| T3 | `test_instances_head_text` | `instances` fixture:標頭逐字比對 7 種形式(單參、context、雙 context、括號型、多參數 class、外部 class、空 body),含一個跨兩行的標頭收斂為單行;`fiInstLine` = 標頭行;deriving 三形式零筆 |
| T4 | `test_instances_class_resolution` | 同 fixture:本地 class → `qnModule` 為 fixture module、`qnSpace = TypeNs`;外部 `Show` → `qnModule = "GHC.Internal.Show"`(以 `nameModule_maybe` 實際值為準,不硬編 `Prelude`);`Map.Map k v` 的 class 仍是 `Renderable` 不是 `Map` |
| T5 | `test_instances_end_to_end` + 既有 `test_two_layer_selfcheck`、`test_codegraph_output_unchanged` | fixture 經 `extract` → `buildGraph`:instance 節點 id、`RImplements` 邊數 = 指向本地 class 的 instance 數、外部 class 進 `gsDroppedExternal`;兩次 `extract` 相同;knot-hs 自掃 `FactInstance` ≥ 3 且 0 警告;黃金檔 byte 不變 |

## 實作備註

### 2026-08-23 實作完成

**驗收結果**(對照契約卡):

| 驗收標準 | 結果 |
|---|---|
| fixture `instances` 的 `FactInstance` 筆數 = 明寫 instance 數、deriving 零筆、標頭逐字相同 | **9 / 9**,deriving 三形式 0 筆;跨三行的 `instance\n  Renderable\n    Bool` 收斂為 `Renderable Bool`、`fiInstLine = 42`(標頭起始行)(T3) |
| `buildGraph` 得 instance 節點與 `RImplements` 邊、外部 class 無邊 | 9 個 instance 節點、**8 條 `implements`**(`Show Sprite` 外部 → 無邊);graph-core 零修改(T5) |
| knot-hs 自掃 `FactInstance` ≥ 3、0 警告 | **3**(`FromRow ModRow/DefRow/RefJoinRow`,class 外部 → 無邊)、0 警告;自掃 555 節點 / 2068 邊 |
| 單檔 best-effort、不產生 `ExtractFailure` | 不存在的 `.hie` → 1 則 `cannot read .hie`;pmSources 全排除 → 每檔 1 則 `cannot map … skipping its instances`;皆回事實 + 警告(T2) |
| `knot-internal` 含 `ghc`、只有 `HieInstances` import ghc package 模組;閘門 | `ghc ^>=9.14` 已加;T1 守門通過(守門前綴:`GHC.Iface.` / `GHC.Types.Name` / `GHC.Types.SrcLoc` / `GHC.Unit.` / `GHC.Data.` / `GHC.Driver.` / `GHC.Utils.` / `GHC.Hs` / `GHC.Core` / `GHC.Tc.` / `Language.Haskell.Syntax`——base 的 `GHC.IO.Handle`、`GHC.Generics` 不在禁令內);`cabal build all --enable-tests` 零警告;閘門 `cabal clean && cabal build all --enable-tests --ghc-options=-Werror` **exit 0**(2026-08-23,全量重建) |
| 五份黃金檔 byte 不變 | `test_codegraph_output_unchanged` 綠 |
| 測試 | **152 綠**(147 + 5) |

**實作取捨**(Level 3 自主權內):

- `Fact` 的 `Ord` 讓 `FactInstance` 以 `fiClass` 先排、`fiInstHead` 次之——`erFacts` 內的 instance 不是行序。T3 比對前依 `fiInstLine` 排回;下游(graph-core)只關心集合,不關心序
- 葉節點上可能同時有 `C:Renderable`(字典建構子)、`$crender`(方法)與 `Renderable`(class)三個 `Use` 識別字;以 `isTcOcc` 只留型別層 namespace,再依 occ 字串序取最小(**不用 `Name` 的 `Ord`**,那是 unique 序、跨次執行不穩)
- `hie_hs_src` 以 `decodeUtf8With lenientDecode` 解碼後按**字元**切片(GHC 的行列是字元座標),`\r` 先濾掉;tab 仍視為一個字元——正規化會吸收大多數差異,極端縮排的跨行標頭可能切偏一兩個字元,未實測到
- 第五站只在站 4 的 decl 層成立後才呼叫(`runPipeline` 先判 `any isDecl`),省掉失敗路徑上多讀一遍 `.hie`;`fakeStages` 的假第五站不記錄呼叫,既有的呼叫序斷言不動
- `knot-internal` 模組數 26 → 27:G-E001 `test_cabal_contract_surface` 與 F007 `test_pipeline_module_surface` 的計數守門同步改為 27 / 18(內部模組),註解註明來源

**連帶更新**:README §輸出格式與 §已知限制 2(`implements` 只涵蓋明寫 instance、deriving 不上圖);system.md「唯一已知未做」句改為「五種 relation 齊全」、package 佈局表 27 個模組。本專案無程式碼知識圖可更新(無 `codegraph.json` 於 repo 根)。
