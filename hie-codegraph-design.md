# hie-codegraph — 設計備忘

**這份文件不是架構文件。** 它是把一次技術討論固化下來的**前提與已驗證事實**,供之後開新專案時當 `/system-design` 訪談的輸入用。真正的 Level 1 主架構由那次訪談產出,不是這份。

放在 uto-skills 之外是刻意的:uto-skills 只認 `codegraph.json` 的**格式**,不認產生它的工具。

- 撰寫日期:2026-08-20
- 驗證環境:Windows 11、GHC 9.14.1、cabal-install 3.16.1.0
- 下游消費者:uto-skills / dev-flow 0.8.1 的 `arch-audit/scripts/scan-graph.mjs` 與 `_shared/codegraph.md`

---

## 1. 為什麼要自己做

dev-flow 0.8.1 加了「程式碼知識圖」整合層:有圖時,`/arch-audit` 能直接算出子系統依賴矩陣、循環依賴、跨界引用清單、架構 hub;`/feature-design`、`/enhance-design`、`/bugfix` 能用它定位。

目前唯一登記的產生器是 graphify,而 **graphify 不支援 Haskell**:

- 實測:同一資料夾放 `foo.py` 與 `Foo.hs`,`.py` 被解析,`.hs` 落進 `not classified (no supported extension or shebang)` 被整個跳過
- 在 MagicFarmer 實跑 `graphify extract . --code-only --directed` → `graph is empty`,110 個 `.hs` 全數跳過
- `.hs` 不是被歸成「文件」,是**完全沒分類**,所以連走 LLM 語意抽取那條路都繞不過去

但 Haskell 的原料其實**比 graphify 支援的語言都好**。graphify 對 Python/TS 做的是啟發式 AST 解析——看到 `foo(x)` 就記一條 `calls`,但那個 `foo` 到底是哪個 `foo` 它不知道(區域變數?import 來的?被 shadow 的?),所以它的邊才需要 `confidence` 欄位。GHC 可以直接給**型別檢查後、名稱全部解析完**的 AST。graphify 要猜的,GHC 直接給答案。

## 2. 目標與非目標

**目標**

- 讀 `.hie` → 產出 `codegraph.json`,讓 dev-flow 的 `scan-graph.mjs` 與七個 skill 接點直接可用
- module 級依賴(**這一層就滿足架構檢測的全部需求**)+ 函式級呼叫(加值)
- 決定性輸出:零 API key、零 LLM、同樣輸入同樣結果

**明確不做**

- **不做 LLM 語意推測邊**。dev-flow 那邊本來就規定 `INFERRED` 只能當假設,GHC 給的是事實,不需要猜的那一層
- **不做社群偵測與命名**。Haskell 的 module 階層(`MagicFarmer.Render.*`)本身就是分群,而 `.design/subsystems/*` + `code-paths` 才是權威分組。graphify 花 LLM 錢猜的東西,架構文件已經寫死了
- **不做視覺化**。`scan-graph.mjs` 的文字輸出就是消費端,HTML 圖先不做
- **不做多語言**。只服務 Haskell

## 3. 唯一的對外契約:`codegraph.json`

```json
{ "directed": true,
  "nodes": [{ "id": "…", "label": "…", "source_file": "src/A.hs", "source_location": "L42" }],
  "links": [{ "source": "<node id>", "target": "<node id>", "relation": "calls", "confidence": "EXTRACTED" }] }
```

- **必要**:`nodes[].id` / `label` / `source_file`,`links[].source` / `target` / `relation`(source/target 是節點 id,不是索引)
- **選填**:`source_location`(證據用,`scan-graph.mjs` 會把它印進循環依賴的證據行)、`confidence`、頂層 `built_at_commit`(新鮮度比對)、頂層 `directed`(不給時下游當有向)
- **`relation` 分兩類**——依賴類 `imports` `imports_from` `calls` `uses` `references` `extends` `implements` `inherits` `instantiates` `depends_on` 才算進依賴圖;結構類 `contains` `method` `defines` 不算;下游認不得的一律排除**並列印出來**,不靜默吞掉
- `source_file` 用 **repo 相對路徑、正斜線**——`code-paths` 的前綴比對靠它

三件要記住的事:

1. **這是匯出格式,不是內部模型。** 工具內部愛用 hiedb 的 SQLite 或自己的 IR 都行,`codegraph.json` 只是投影給 dev-flow 看的那一面。專案叫「hiedb + exporter」就是這個意思
2. **多餘欄位會被忽略。** `scan-graph.mjs` 只讀它需要的,想在節點塞型別、instance 資訊、原始 span 都可以,下游不會壞
3. **輸出到 repo 根目錄的 `codegraph.json`。** 下游的搜尋順序是 `codegraph.json` → `.codegraph/graph.json` → `graphify-out/graph.json`,第一個是為自製工具保留的通用位置,零設定接上

## 4. 兩階段

| | 做法 | 拿到什麼 | 成本 | 解鎖 dev-flow 的 |
|---|---|---|---|---|
| **T0** | 掃 `import` 行,module 名 ↔ 檔案路徑 | module → module 依賴圖 | 一個下午,~250 行,零依賴 | `/arch-audit` 全部(依賴矩陣、循環依賴、跨界引用、hub) |
| **T1** | 讀 `.hie` | 函式級呼叫圖、型別、精確 span、class/instance 關係 | 數天～一週 | 再加上 `/feature-design` 定位、`/enhance-design` 影響面、`/bugfix` 呼叫鏈 |

**價值分布很不平均,T0 用約 5% 的成本拿到約 80% 的整合價值**——因為循環依賴、依賴矩陣、邊界外洩這三件事**本來就只需要 module 級關係**。T1 多出來的函式級圖只服務定位加速,而那些用 grep 也做得動。

建議:**先花 10 分鐘試 `cabal install hiedb` / `calligraphy`,編不過再做 T0,T1 押後。**

## 5. 已驗證的技術前提

以下都是在本機實際確認過的,不是憑記憶:

**環境**:GHC 9.14.1(base 4.22 / template-haskell 2.24)、cabal-install 3.16.1.0、`default-language: GHC2024`。MagicFarmer 的 `cabal.project` 已為 h-raylib、hedgehog 開 `allow-newer`——工具鏈走在很前面,這會影響第三方套件可用性。

**`ghc` library 本體就帶 HIE 模組**(`ghc --print-libdir` 下確認存在):

```text
GHC/Iface/Ext/{Binary, Types, Utils, Ast, Debug, Fields}.hi
```

**`GHC.Iface.Ext.Binary`** 匯出:`readHieFile`、`readHieFileWithVersion`、`writeHieFile`;
`readHieFile` 吃一個 `GHC.Types.Name.Cache.NameCache`,回傳
`HieFileResult { hie_file_result, hie_file_result_ghc_version, hie_file_result_version }`。

**`GHC.Iface.Ext.Types`** 的關鍵型別(建構子與欄位名為實際 dump 所得):

| 型別 | 欄位 / 建構子 |
|---|---|
| `HieFile` | `hie_hs_file` `hie_module` `hie_types` `hie_asts` `hie_exports` `hie_hs_src` `hie_entity_infos` |
| `HieASTs` | `getAsts` |
| `HieAST` | `Node { sourcedNodeInfo, nodeSpan, nodeChildren }` |
| `SourcedNodeInfo` | `getSourcedNodeInfo` |
| `NodeInfo` | `nodeAnnotations` `nodeIdentifiers` `nodeType` |
| `IdentifierDetails` | `identInfo` `identType` |
| `ContextInfo` | `Use` `Decl` `ValBind` `PatternBind` `MatchBind` `IEThing` `TyDecl` `ClassTyDecl` `RecField` `TyVarBind` `EvidenceVarBind` `EvidenceVarUse` |
| `DeclType` | `ClassDec` `ConDec` `DataDec` `FamDec` `InstDec` `PatSynDec` `SynDec` |
| 型別表 | `HieType`(`HTyVarTy` `HAppTy` `HTyConApp` `HForAllTy` `HFunTy` `HQualTy` `HLitTy` `HCastTy` `HCoercionTy`)、`HieTypeFlat`、`HieTypeFix`/`Roll` |

`hie_entity_infos` 是較新的欄位;`EntityInfo`、`HieName` 也在同模組。

**版本鎖是硬性的**:`.hie` 的讀寫綁 GHC 版本,所以**工具必須用專案同一個 GHC 編譯**。這是設計約束不是缺陷——反過來說,只依賴 `ghc == 9.14.*`(編譯器自帶的 library)就**沒有第三方套件落後的風險**,這正是「用 Haskell 實作」在這件事上是唯一乾淨解的原因。

**現成工具的版本風險**:

- [calligraphy](https://hackage.haskell.org/package/calligraphy) — HIE-based 呼叫圖與視覺化,基本上就是 Haskell 版 graphify。但宣稱測過 **GHC 8.8 ～ 9.6**
- [hiedb](https://hackage.haskell.org/package/hiedb) — 把 `.hie` 索引進 SQLite,HLS 用的那套

兩者都 link `ghc` library 且需與專案同版編譯,9.14 大概率還沒跟上。**先試裝再決定 wrap 還是自己寫。**

## 6. 抽取設計要點

**產生 `.hie`**:`ghc-options: -fwrite-ide-info -hiedir <dir>`(或 `cabal build --ghc-options=-fwrite-ide-info`)。要先確認產出大小與重編成本。

**節點粒度**:建議兩層都出——module 節點(供 `code-paths` 捲動與 module 依賴)+ top-level 宣告節點(供函式級)。`contains` 邊連接兩層,但記得它是**結構類**,下游不算進依賴圖。

**邊怎麼來**:`nodeIdentifiers` 的 key 是 `Identifier = Either ModuleName Name`,value 是 `IdentifierDetails`。用 `identInfo :: Set ContextInfo` 判斷這個出現點是什麼:

| ContextInfo | 意義 | 對應 |
|---|---|---|
| `Decl DeclType _` | 這裡是定義 | 建節點(`DeclType` 決定是 class / data / instance / …) |
| `Use` | 這裡在使用某個名字 | `calls` 或 `uses` 邊 |
| `IEThing` | import/export 清單裡的項目 | `imports` / `imports_from` |
| `ValBind` `PatternBind` `MatchBind` | 綁定 | 通常是節點不是邊 |
| `ClassTyDecl` / `InstDec` | class 方法簽名 / instance 宣告 | `implements` 邊的兩端 |

`source_location` 從 `nodeSpan` 取(格式 `L<行>` 即可,下游只拿來當定位線索)。

**typeclass 的分岔**:`.hie` 能告訴你某處用了 `render :: Renderable a => a -> Picture`,但實際跑哪個 instance 是 dispatch 時才決定。這不是工具做不好,是語言的性質。建議:**class method 與各 instance 各自建節點,中間連 `implements` 邊**,讓讀圖的人自己看分岔,不要假裝解析得出來。

## 7. 已知難點

1. **節點 id 的穩定性**。GHC 的 `Unique` **不跨編譯穩定**,絕對不能拿來當 `id`。要用 `Module` + `OccName` 組出決定性的 id,並且區分 namespace(型別的 `Foo` 與值的 `Foo` 是兩個節點)
2. **產生的程式碼**。TH、deriving 產生的節點 span 會指到奇怪的位置甚至不存在的檔案,需要過濾或標記
3. **`test/` 要不要納入**。建議 exporter 提供開關且**預設排除**——測試引用生產碼是正常的,納入會在子系統依賴矩陣裡製造大量假的跨界邊
4. **增量**。`.hie` 跟著 GHC 增量編譯走,但**刪檔**要自己處理(舊 `.hie` 會留在 `-hiedir`,產生幽靈節點)
5. **`identType` 的展開**。它是進 `hie_types` 表的索引,要展開成可讀型別需要處理 `HieTypeFlat` / `HieTypeFix`。第一版可以先不輸出型別

## 8. 驗收標準

拿 MagicFarmer(4 個子系統:`engine-core` / `npc-mind` / `render-pipeline` / `time-rewind`,`src/MagicFarmer/*`)當驗收標的:

1. 產出 repo 根目錄的 `codegraph.json`
2. 先在四份 `design.md` 的 frontmatter 補 `code-paths`(例:`code-paths: [src/MagicFarmer/Render]`),**不含 `test/`**
3. `node "<uto-skills>/plugins/dev-flow/skills/arch-audit/scripts/scan-graph.mjs" .design` 能跑出:對映覆蓋率接近 100%、四個子系統的依賴矩陣、循環依賴段落
4. **循環依賴的結果要人工抽查複驗**——照 dev-flow 的鐵律,圖是導航不是查證,第一次上線更要驗

## 9. 開放問題

- 要不要同時提供查詢 CLI(對應 dev-flow 的四項能力:關鍵字查節點、反向可達、兩點最短路徑、連通度排名)?**不做也完全可用**,只是 `/feature-design`、`/bugfix` 的定位加速拿不到
- module 節點與 decl 節點混在同一張圖,`scan-graph.mjs` 的「架構 hub」排名會不會被 module 節點洗版?(它已排除結構類邊,但仍要實測)
- 專案名稱與 repo 位置
- 要不要順便吃 `.cabal` 的 component 資訊(library / executable / test-suite),讓子系統對映多一個維度
