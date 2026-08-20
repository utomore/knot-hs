---
id: F002
type: feature
title: import-scan
description: 掃描原始碼的 module 標頭與 import 行產出 module 級事實
status: done
created: 2026-08-20
updated: 2026-08-20
depends-on: [F001, project-meta/F001]
related-adr: [ADR-002]
related-feature: []
---

# F002: import-scan — T0 後端(module 標頭與字面 import)

## 功能概述

extraction 的第一個**真後端**:實作 `Backend` 介面的 import-scan 實例(`bLevel = ModuleLevel`),讀 `pmSources` 中 included 的 `.hs` 檔,以輕量掃描(非完整 Haskell 語法解析)抽出兩種事實——`FactModule`(檔案裡實際宣告的 module)與 `FactImport`(字面 import 行),並註冊進 `F001` 的後端註冊表,使 `extract` 首次對真實專案產出非空事實流。

**要解決的問題**:ADR-002 的保底層——`imports` 邊是 `/arch-audit` 依賴矩陣、循環依賴、跨界引用的唯一原料,必須零外部依賴、永遠可用;抽取規則 2 因此把 `FactImport` 的產出權**唯一**指派給本後端(hiedb 可用與否都不改變 imports 邊的內容)。

**驗收標準**(契約卡原文):

1. 每個 included 檔案有一筆 `FactModule`
2. `import`、`import qualified X as Y`、`import X (…) hiding (…)` 多行語法都能抽出 `FactImport`
3. CPP 條件內的 import 依字面抽取(best-effort,行為寫進文件)
4. 單檔讀取失敗印警告不中斷
5. 連續兩次執行輸出相同
6. 以 MagicFarmer 與 particle-magic(唯讀)實跑驗收

**明確不做**(契約卡底線):不解析 import 清單明細(只到 module 對 module,`(…)` / `hiding (…)` 的內容一律丟棄);不讀 `.hie`;不驗證 import 的目標 module 是否存在(懸空 import 留給 graph-core);不做完整 Haskell 語法解析(只認 module 標頭與 import 區)。另外承 F001 的分工:不做事實去重、不決定節點 id、不組圖、不碰 CLI 參數解析。

## 相依性

`depends-on: [F001, project-meta/F001]`,兩條皆由「使用到的既有串接介面」表反推:

- **`F001`(fact-contract,同子系統)**:本 feature 的產出型別(`Fact` 的 `FactModule` / `FactImport` 建構子、`ExtractWarning`)、要實作的介面(`Backend`、`ProbeResult`、`CapabilityLevel`)、後端名常數(`importScanName`)全部出自 `F001`;註冊動作也要改 `F001` 的 `Knot.Extract` 註冊表常數。`F001` 設計已完成、**程式碼尚未實作**,故本相依依 `F001` 文檔的介面約定成立(非既有程式碼查證),介面表對應列的「來源檔案」標為未實作。排程已定 F001 → F002 序列實作,本 feature 開工時 `F001` 的程式碼應已存在。
- **`project-meta/F001`(scan-baseline,跨子系統)**:`ProjectMeta` / `SourceFile` / `ModuleName` 的型別定義,簽名為 2026-08-20 自 `src/Knot/Meta/Types.hs` 讀出的原文;測試路徑另用 `loadProjectMeta` 與 `MetaOptions` 由 fixture 產生真實輸入。

未列入的相依與理由:

- `project-meta/F002`(cabal-components)、`project-meta/F003`(hie-discovery):只改變 `sfIncluded` / `sfOwners` / `pmHie` 的**填值語意**,不改型別;本 feature 依欄位型別使用、對填值來源不可知,不構成相依
- `F003` / `F004`(hiedb 兩件):方向無關,本後端與 hiedb 後端職責互斥(規則 2),不共用任何程式碼
- graph-core / export-query:本 feature 不呼叫它們,`Fact` 是單向資料流的下游輸入

可平行性:**不可**與 `F001` 平行(序列相依,F001 的型別與註冊表是本 feature 的前提);與 graph-core、export-query 的任務可平行(無交集)。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/extraction/design.md`,無一超出範圍:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `Backend` 的 import-scan 實例 | 提供 `importScanBackend :: Backend`,`bName = importScanName`(`"import-scan"`,即 `brBackend` 值域)、`bLevel = ModuleLevel`、`bProbe`、`bRun` 四欄齊備 |
| `ProbeResult` | `bProbe` 恆回 `Available`(零外部依賴;規則 3「import-scan 必跑」的具體化) |
| 事實流 DTO `FactModule` | 每個成功讀取的 included 檔一筆:`fmFile = sfPath`(repo 相對正斜線)、`fmModule` = 檔內宣告的 module |
| 事實流 DTO `FactImport` | 每條字面 import 一筆:`fiFrom` = 本檔 module、`fiTo` = 被 import 的 module、`fiFile = sfPath`、`fiLine` = `import` 關鍵字所在行(1 起算) |
| 抽取規則 2(imports 唯一來源、無標頭視為 Main) | `FactImport` / `FactModule` 只由本後端產出;無 module 標頭 → `ModuleName "Main"`(D3),多個 Main 由 `fmFile` 區分 |
| 抽取規則 1(納入範圍) | 依 `F001` 假設 A1,窄化由 backend-select 單點負責;本後端**原樣掃描收到的 `pmSources`**,不自行過濾(haddock 註明此前提) |
| 抽取規則 7(best-effort) | 單檔讀取/解碼失敗 → `ExtractWarning` + 跳過該檔,續掃其餘;單行 import 解析失敗 → 警告 + 跳過該行;後端整體不抛例外 |
| 抽取規則 8(決定性) | 事實依 `pmSources` 序 × 檔內行序輸出,警告同序;無亂序來源(不使用 Map/Set 走訪、不併發) |
| 資料流管線段落 | `pmSources`(included)→ 逐檔讀取解碼 → 掃描 → `FactModule` / `FactImport` 事實流 |
| 規則 3(auto 合成)、4、5、6 | **不觸碰**(規則 3 屬 `F001`;4/5/6 屬 `F003` / `F004`) |

超出 Level 2 契約的部分只有一處,且為契約**缺口**而非偏離:`Backend.bRun` 收到的 `ExtractOptions` 與 `ProjectMeta` 都不帶專案根目錄,而 `sfPath` 是 repo 相對路徑——沒有根目錄就開不了檔。處理見「待確認假設 A1」(建議 Level 2 為 `ExtractOptions` 增 `rootDir` 欄位),已列入回報請編排者裁決。

## 實作方式

### 模組配置

```text
src/Knot/Extract/ImportScan.hs   -- Backend 實例 + 讀檔 IO + 純掃描核心
```

`knot-hs.cabal`:library `exposed-modules` 加入 `Knot.Extract.ImportScan`;`build-depends` **不變**(`base` / `bytestring` / `text` / `filepath` 皆已在列);test-suite 需新增 `bytestring`(T6 產生非法 UTF-8 位元組的臨時檔)。`version: 0.0.1.0` 依 D4 凍結不動。測試 group 命名 `extraction/F002 import-scan`(與 project-meta 的 `F00x` group 區隔)。

註冊:`Knot.Extract` 的後端註冊表常數由空清單改為 `[importScanBackend]`(`F001` 已預告此變更;`extract` 本身邏輯不動)。

### 掃描管線(單檔)

```text
sfPath ──┬─▶ rootDir </> sfPath ─▶ ByteString.readFile   (IOException → 警告 + 跳過整檔)
         │                              │
         │                              ▼
         │                        decodeUtf8'             (UnicodeException → 警告 + 跳過整檔)
         │                              │ Text(剝 U+FEFF BOM)
         │                              ▼
         │                        stripCommentLines       [(行號, 去註解後的行)]
         │                         ├─▶ headerModuleOf ─▶ Maybe ModuleName ─(Nothing)─▶ Main(D3)
         │                         └─▶ importsOf      ─▶ [(行號, Maybe ModuleName)]
         ▼                                                       │
   FactModule{fmFile = sfPath}  ◀───────────────────────────────┘
   FactImport{fiFile = sfPath, fiFrom = 本檔 module, fiTo, fiLine}
```

輸出順序固定:先 `FactModule`,再依行號遞增的 `FactImport`;檔案間依 `pmSources` 原序串接(`F001` 合成階段還會做一次全序排序,本後端自身的序仍必須決定性)。

### 1. 去註解掃描器 `stripCommentLines`

前處理:剝除開頭的 U+FEFF(BOM);`Data.Text.lines` 切行後每行剝掉行尾 `\r`(CRLF 檔)。行號 1 起算,**輸出行數與輸入相同**(行號即索引,不因註解消失而位移)。

逐字元狀態機,狀態跨行延續:

| 狀態 | 遇到 | 動作 |
|---|---|---|
| `Code` | `"` | 進 `Str`(字串內容原樣輸出) |
| `Code` | `{-` | 進 `Block 1`,輸出一個空白 |
| `Code` | `--` 且其後非符號字元(`!#$%&*+./<=>?@\^\|-~:`) | 丟棄該行剩餘 |
| `Code` | 其他 | 原樣輸出 |
| `Str` | `\` | 跳脫下一字元 |
| `Str` | `"` | 回 `Code` |
| `Str` | 行尾 | 回 `Code`(best-effort;不支援字串 gap 跨行) |
| `Block n` | `{-` | 深度 +1(Haskell 區塊註解可巢狀) |
| `Block n` | `-}` | 深度 -1,歸零回 `Code` |
| `Block n` | 其他 | 輸出空白(保留行結構與欄位位置) |

`{-# … #-}` pragma 在此規則下即區塊註解,被整段換成空白——這正是要的行為:`import {-# SOURCE #-} Foo` 變成 `import   Foo`(換成空白而非刪除,避免 token 黏連)。

**已知限制(best-effort,寫進 haddock)**:不追蹤字元字面量,故 `'"'`、`'{'` 等字面量理論上會擾亂狀態;掃描範圍限於 import 區(見下)使實際風險趨近於零。

### 2. module 標頭 `headerModuleOf`

在去註解行流上,找第一行「首個 token 為 `module`」的行(允許前導空白),自該 token 之後**跨行**讀取第一個 module id token;取到即為結果,取不到 → `Nothing` + 一則警告。整份檔案沒有 `module` 行 → `Nothing`(無警告,合法情形)。

module id token 文法:`[A-Z][A-Za-z0-9_']*` 以 `.` 連接的序列(例:`MagicFarmer.Render.Core`)。跨行支援涵蓋 `module\n  App.Effects\n  ( … ) where` 這種寫法;export list 內的 `-- *` haddock 標題已在步驟 1 被剝除,不影響。

`Nothing` 一律代入 `ModuleName "Main"`(規則 2 / D3),`FactModule` 照出。

### 3. import 抽取 `importsOf`

在去註解行流上依序處理,直到**import 區結束**:

| 行的形態(去註解後) | 動作 |
|---|---|
| 空白行 | 跳過,不結束 |
| `#` 開頭(CPP 指令 `#if` / `#else` / `#endif` / `#define` …) | 跳過,不結束 |
| 首字元為空白(縮排行) | 跳過(視為前一宣告的延續:import 清單、export 清單、`where`) |
| 第 0 欄 token = `module` | 跳過(標頭本身;其續行為縮排行) |
| 第 0 欄 token = `import` | 解析(見下),續掃 |
| 其他第 0 欄非空 token | **結束掃描**(已進入宣告區) |

單條 import 的解析:自 `import` 之後依序**跳過** `qualified` token 與字串字面量 token(package-qualified import,如 `import "network" Network.Socket`),取第一個 module id token 為 `fiTo`;該行取不到時允許延續到後續縮排行(`import\n  qualified Data.Map as M`)。取不到 → 該筆記為 `Nothing`,由 `scanSource` 轉一則警告。`as`、`hiding`、`(…)` 之後的內容一律不看。

`fiLine` 取 `import` 關鍵字所在行(即使 module id 落在續行)。

**CPP 行為(契約卡要求寫進文件)**:`#` 指令行只被丟棄,**不做條件求值**——`#if` / `#else` 兩個分支內的 import 會**同時**被抽出。這是刻意的 best-effort:import-scan 不知道目標專案的編譯旗標,寧可多報(graph-core 端表現為多一條 imports 邊)也不漏報。已知限制:`#define` 的反斜線續行若落在第 0 欄且非 import,會提前結束 import 區掃描(header 區極罕見)。

### 4. 事實組裝 `scanSource`

```text
selfMod = headerModuleOf 的結果,Nothing → ModuleName "Main"
facts   = FactModule sfPath selfMod
          : [ FactImport selfMod m sfPath n | (n, Just m) <- importsOf ]
warnings = 標頭警告 ++ [ 每個 (n, Nothing) 一則 "unparsable import" 警告 ]
```

- **不去重**:同一檔 import 同一 module 兩次(不同行)→ 兩筆 `FactImport`(行號不同);去重與衝突解決屬 graph-core(承 `F001` 的決定)
- **不與 `sfModule` 交叉比對**:`FactModule.fmModule` 以檔案標頭為唯一權威(`sfModule` 是路徑啟發式,見假設 A2)
- **自我 import**(`fiFrom == fiTo`,CPP 分支下有可能)照出,由 graph-core 決定要不要丟

### 5. 後端值與錯誤處理

```text
bProbe = \_ _ -> pure Available                    -- 零外部依賴,恆可用
bRun   = \opts pm -> 逐檔掃描 (pmSources pm)       -- 已由 backend-select 窄化為 included
```

| 情境 | 行為 |
|---|---|
| 檔案不存在 / 無讀取權限 / 是目錄 | `IOException` → `ExtractWarning{ ewSource = sfPath, ewMessage = "cannot read file: …" }`,跳過該檔(該檔無任何事實) |
| 內容非合法 UTF-8 | `decodeUtf8'` 回 `Left` → `ExtractWarning`(訊息含 `displayException` 文字),跳過該檔;**不做編碼猜測、不用 lenient 解碼**(委派決策:Haskell 慣例 UTF-8) |
| import 行解析不出 module id | `ExtractWarning{ ewSource = sfPath, ewMessage = "unparsable import at line N" }`,跳過該行,續掃該檔 |
| `module` 關鍵字後解析不出 module id | 警告 + 退回 `Main`,續掃該檔 |
| `pmSources` 為空 | 回 `([], [])`,`bProbe` 仍為 `Available` |

`bRun` 全程不抛例外(`F001` 的 `try` 包裝是第二道保險,不是本後端的錯誤處理手段)。

### 6. 決定性(規則 8)

- 檔案處理序 = `pmSources` 序(project-meta 已依 `sfPath` 排序);檔內事實序 = 行號序;警告序 = 檔序 × 行序
- 全程純函數 + 循序 IO,無 `Map` / `Set` 走訪、無並發、無時間戳
- T7 以「同一輸入連續兩次 `bRun` 結果 `==`」釘住

## 使用到的既有串接介面

(project-meta 與 app 層簽名為 2026-08-20 自來源檔案讀出的原文;base / bytestring / text / filepath / directory 簽名以 `ghc -e ':t …'`(GHC 9.14.1)實測;`F001` 的型別尚未實作,標為文檔約定)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `data Backend = Backend { bName :: Text, bLevel :: CapabilityLevel, bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult, bRun :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning]) }` | (未實作)`src/Knot/Extract/Backend.hs`,依 `F001`「新增的介面」 | F001 | 本 feature 實作的介面本體:`importScanBackend` 即其 import-scan 實例 |
| `data ProbeResult = Available \| Unavailable Text` | (未實作)`src/Knot/Extract/Backend.hs`,依 `F001` | F001 | `bProbe` 回傳值(恆 `Available`) |
| `importScanName :: Text  -- "import-scan"` | (未實作)`src/Knot/Extract/Backend.hs`,依 `F001` | F001 | `bName` 取值;`BackendChoice = ImportsOnly` 的比對依據 |
| `data Fact = FactModule { fmFile :: FilePath, fmModule :: ModuleName } \| FactImport { fiFrom :: ModuleName, fiTo :: ModuleName, fiFile :: FilePath, fiLine :: Int } \| …` | (未實作)`src/Knot/Extract/Types.hs`,依 `F001` | F001 | 本後端產出的兩個建構子(其餘三個不使用) |
| `data ExtractWarning = ExtractWarning { ewSource :: Text, ewMessage :: Text }` | (未實作)`src/Knot/Extract/Types.hs`,依 `F001`(D1) | F001 | best-effort 警告載體(`ewSource` 填 `sfPath`) |
| `data CapabilityLevel = ModuleLevel \| DeclLevel` | (未實作)`src/Knot/Extract/Types.hs`,依 `F001` | F001 | `bLevel = ModuleLevel` |
| `data ExtractOptions = ExtractOptions { backendChoice :: BackendChoice, hiedbExe :: Maybe FilePath, dbPath :: Maybe FilePath }` | (未實作)`src/Knot/Extract/Types.hs`,依 `F001` | F001 | `bRun` 的第一參數;**目前不含根目錄**,故有假設 A1 |
| `extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult` | (未實作)`src/Knot/Extract.hs`,依 `F001` | F001 | 註冊表所在;T1 註冊後由它端到端驗證(整合測試) |
| `data ProjectMeta = ProjectMeta { pmPackages :: [PackageMeta], pmSources :: [SourceFile], pmHie :: Maybe HieInfo, pmWarnings :: [MetaWarning] }` | src/Knot/Meta/Types.hs:29-35 | project-meta/F001 | `bRun` 的第二參數;本後端只讀 `pmSources` |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs:65-71 | project-meta/F001 | 只讀 `sfPath`(開檔 + 事實的 file 欄位);`sfModule` 刻意不用(假設 A2)、`sfIncluded` 由 backend-select 窄化(F001 A1) |
| `newtype ModuleName = ModuleName Text` `deriving (Eq, Ord, Show)` | src/Knot/Meta/Types.hs:74-75 | project-meta/F001 | D2:`FactModule` / `FactImport` 的 module 欄位型別;掃描結果直接包成此型別 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs:22-26 | project-meta/F001 | 僅測試路徑:組出真實 `ProjectMeta` 輸入 |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs:29 | project-meta/F001 | 僅測試路徑:以 fixture 產生真實 `ProjectMeta`(T6/T7) |
| `renderMetaSummary :: ProjectMeta -> Text` | app/Knot/App/Summary.hs:28 | project-meta/F001 | T8 的鄰接慣例:事實摘要輸出加在同一 app 內部模組、同樣由 test-suite 共用原始碼目錄測試 |
| `Data.ByteString.readFile :: FilePath -> IO ByteString` | bytestring-0.12.2.0(GHC 9.14.1 boot) | - | 以位元組讀檔,避開 `Data.Text.IO` 的 locale 編碼(Windows 非 UTF-8)問題 |
| `Data.Text.Encoding.decodeUtf8' :: ByteString -> Either UnicodeException Text` | text(GHC 9.14.1 boot) | - | UTF-8 解碼;`Left` 即編碼錯誤 → 警告跳過(不用 `decodeUtf8Lenient`,避免靜默污染) |
| `Control.Exception.displayException :: Exception e => e -> String` | base-4.22(GHC 9.14.1) | - | `IOException` / `UnicodeException` 轉警告文字(已實測 `UnicodeException` 有 `Exception` 實例:`displayException (DecodeError "boom" Nothing)` = `"Cannot decode input: boom"`) |
| `Control.Exception.try :: Exception e => IO a -> IO (Either e a)` | base-4.22(GHC 9.14.1) | - | 包住單檔讀取,以 `IOException` 具現(規則 7) |
| `Data.Text.lines :: Text -> [Text]` | text(GHC 9.14.1 boot) | - | 切行(行號來源) |
| `Data.Text.uncons :: Text -> Maybe (Char, Text)` / `Data.Text.span :: (Char -> Bool) -> Text -> (Text, Text)` / `Data.Text.stripPrefix :: Text -> Text -> Maybe Text` / `Data.Text.dropWhileEnd :: (Char -> Bool) -> Text -> Text` | text(GHC 9.14.1 boot) | - | 狀態機逐字元走訪、token 切分、剝 BOM 與行尾 `\r` |
| `System.FilePath.(</>) :: FilePath -> FilePath -> FilePath` | filepath(GHC 9.14.1 boot) | - | `rootDir </> sfPath` 組出實體路徑(假設 A1) |
| `Data.Char.isSpace :: Char -> Bool` / `Data.Char.isUpper :: Char -> Bool` | base-4.22(GHC 9.14.1) | - | token 切分與 module id 首字元判定 |
| `System.Directory.getTemporaryDirectory :: IO FilePath` / `createDirectoryIfMissing :: Bool -> FilePath -> IO ()` / `removePathForcibly :: FilePath -> IO ()` | directory(GHC 9.14.1 boot) | - | 僅測試路徑:T6 在暫存目錄建「非法 UTF-8 位元組檔」與「讀不到的檔」,測完刪除(不入版控) |
| `Data.ByteString.writeFile :: FilePath -> ByteString -> IO ()` | bytestring-0.12.2.0(GHC 9.14.1 boot) | - | 僅測試路徑:寫出 T6 的非法 UTF-8 位元組 |

## 新增的介面

全部落在 Level 2 契約內(`Backend` 實例 + 既有 `Fact` 建構子);純函數為測試而匯出的部分依 project-meta 既有慣例以 haddock 標註非契約面。

**`Knot.Extract.ImportScan`**

```haskell
-- | import-scan 後端(T0):零外部依賴,bLevel = ModuleLevel,bProbe 恆 Available。
-- 收到的 ProjectMeta 應已由 backend-select 窄化為 sfIncluded = True 的子集(F001 A1)。
importScanBackend :: Backend

-- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)

-- | 單檔掃描核心:repo 相對路徑 + 已解碼內容 → (事實, 警告)。
--   事實序:FactModule 在前,FactImport 依行號遞增。
scanSource :: FilePath -> Text -> ([Fact], [ExtractWarning])

-- | 去註解:剝 BOM 與行尾 \r,消去 --、巢狀 {- -}({-# #-} 亦然),
--   以空白佔位保留行結構;輸出行數 == 輸入行數,Int 為 1 起算的行號。
stripCommentLines :: Text -> [(Int, Text)]

-- | 取檔案宣告的 module 名;Nothing = 無 module 標頭(呼叫端代入 Main)。
--   Bool 為「有 module 關鍵字但解析不出名字」的旗標(轉警告用)。
headerModuleOf :: [(Int, Text)] -> (Maybe ModuleName, Bool)

-- | 取 import 區的每條 import;Nothing = 該行解析不出 module id(轉警告用)。
importsOf :: [(Int, Text)] -> [(Int, Maybe ModuleName)]
```

**`Knot.Extract`(既有檔案的修改,非新介面)**

後端註冊表常數由 `[]` 改為 `[importScanBackend]`;`extract` 的簽名與邏輯不變。

**`Knot.App.Summary`(executable 內部模組,非 library 對外介面)**

```haskell
-- | 事實摘要:事實/警告筆數 + 逐筆 module/import 行,供 T8 唯讀驗收比對。
renderFactSummary :: ExtractResult -> Text
```

## TodoList

- [x] T1: `Knot.Extract.ImportScan` 骨架與後端值(`bName` / `bLevel` / `bProbe`),加入 `exposed-modules`,並把 `Knot.Extract` 註冊表改為 `[importScanBackend]`,`cabal build all` 通過  `dep: F001`
- [x] T2: `stripCommentLines`——BOM / CRLF 前處理、`--`、巢狀 `{- -}`、`{-# #-}`、字串字面量,行號與行數保持  `dep: T1`
- [x] T3: `headerModuleOf`——module id 文法、跨行標頭、無標頭 → `Nothing`、解析失敗旗標  `dep: T2`
- [x] T4: `importsOf`——import 區邊界判定(空白/CPP/縮排/第 0 欄宣告)、`qualified` 與 package 字串跳過、多行 import、`{-# SOURCE #-}`、CPP 分支全抽  `dep: T2`
- [x] T5: `scanSource` 組裝——`FactModule`(無標頭 → `Main`,D3)、`FactImport`(`fiFrom` / `fiTo` / `fiLine`)、解析失敗轉警告、不去重  `dep: T3, T4`
- [x] T6: `bRun` 逐檔 IO——`rootDir </> sfPath` 讀取、`decodeUtf8'` 解碼、IO/編碼失敗轉警告並跳過該檔、事實依 `pmSources` 序串接;test-suite 加 `bytestring`  `dep: T5`
- [x] T7: 決定性驗證——同輸入連續兩次 `bRun` 完全相同;隨機生成 import 原始碼的 round-trip 性質  `dep: T6`
- [x] T8: 驗收 harness——`renderFactSummary` 與 `knot` 的事實摘要輸出路徑,對 MagicFarmer / particle-magic 唯讀實跑對帳(結果寫入「實作備註」)  `dep: T7`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_import_scan_backend_value | `bName == importScanName`(且等於契約字串 `"import-scan"`)、`bLevel == ModuleLevel`;對空 `ProjectMeta` 呼叫 `bProbe` 回 `Available`;經 `extract`(`Auto` 與 `ImportsOnly`)確認 import-scan 出現在 `erReports` 且 `brUsed = True`(註冊生效)、`HiedbOnly` 時為未選中 |
| T2 | test_strip_comments | HUnit 例:行尾 `--` 註解、`-->` 運算子不被當註解、巢狀 `{- {- x -} -}`、`{-# LANGUAGE CPP #-}` 換成空白、`import {-# SOURCE #-} Foo` 不黏連、字串內的 `--` 與 `{-` 不觸發、CRLF 行尾、開頭 BOM;並驗證輸出行數與行號序等於輸入 |
| T3 | test_module_header | `module A.B.C where` → `A.B.C`;跨行 `module\n  App.Effects\n  ( -- * 標題\n    x ) where` → `App.Effects`;標頭前有 pragma 與 haddock 註解仍正確;`{-# OPTIONS_GHC -F -pgmF hspec-discover #-}` 單行檔 → `Nothing` 且失敗旗標為 `False` |
| T4 | test_imports_syntax | 一份綜合原始碼:`import A`、`import qualified B.C as X`、`import D (a, b) hiding (c)` 多行清單、`import {-# SOURCE #-} E`、`import "pkg" F.G`、`import\n  qualified H as H'`、CPP `#if` / `#else` 兩分支各一個 import(**皆**抽到)、`#endif` 等指令行被跳過 → 抽出的 `(行號, module)` 清單與期望完全相同;宣告區內出現的 `import` 字樣(如字串或註解中)不被抽出 |
| T5 | test_scan_source_facts | 對同一綜合原始碼:第一筆為 `FactModule`(`fmFile` = 給定路徑、`fmModule` = 標頭 module),其後 `FactImport` 的 `fiFrom` 全等於該 module、`fiTo` / `fiLine` 正確且行號遞增;無標頭版本 → `fmModule` 與 `fiFrom` 皆為 `ModuleName "Main"`;同一 module import 兩次 → 兩筆事實(不去重);壞 import 行 → 一則 `unparsable` 警告且其餘事實不受影響 |
| T6 | test_run_best_effort | 暫存目錄樹(含正常檔、非法 UTF-8 位元組檔、`pmSources` 列出但實際不存在的檔)→ 兩則 `ExtractWarning`(`ewSource` 各為對應 `sfPath`,訊息可辨識為讀取/編碼失敗)、正常檔事實完整、`bRun` 不抛例外;另以 `loadProjectMeta` 取 fixture 專案經 `extract` 驗證被排除檔(`sfIncluded = False`)不產生任何事實 |
| T7 | test_import_scan_deterministic | 同一 `ProjectMeta` 連續兩次 `bRun`,`(facts, warnings)` 完全相等;hedgehog property:隨機生成 module 名清單與 `qualified` / `as` / `hiding` 修飾組合渲染成原始碼文字後,`scanSource` 抽出的 `(行號, fiTo)` 序列等於生成清單 |
| T8 | test_render_fact_summary | 對已知 `ExtractResult` 值驗證 `renderFactSummary` 的摘要文字(事實筆數、module/import 分項筆數、警告筆數與逐筆行格式);MagicFarmer / particle-magic 的實跑屬階段閘門手動驗收(承 project-meta F001 慣例),結果記入「實作備註」 |

## 待確認假設

- A1: `Backend.bRun` 收到的 `ExtractOptions` 與 `ProjectMeta` 都不帶專案根目錄,但 `sfPath` 是 repo 相對路徑,沒有根目錄就開不了檔(`ProjectMeta` 亦無 root 欄位,已讀原始碼確認)→ 採取:建議 Level 2 為 `ExtractOptions` 增 `rootDir :: FilePath`(CLI 組裝層本來就持有 `MetaOptions.root`),本後端以 `rootDir </> sfPath` 開檔;純掃描核心 `scanSource` 完全不碰路徑解析,故裁決改變時只動 `bRun` 一處 → 影響:若改為在 `ProjectMeta` 增 `pmRoot`(動 project-meta 契約與已完成的實作),`bRun` 改取值來源一行;**注意 `F003` hiedb-driver 的規則 6 預設路徑 `<root>/.knot/hiedb.sqlite` 需要同一個 root**,本項屬階段一必須裁決的契約缺口
- A2: `FactModule.fmModule` 的權威來源未明說(`SourceFile.sfModule` 也是 module 名)→ 採取:以檔案內的 `module` 標頭為唯一權威(design.md 原文「檔案裡實際宣告的 module」),無標頭 → `Main`(D3);**不**與 `sfModule` 交叉比對、不因兩者不一致發警告(`sfModule` 在無 owner 時退回路徑啟發式,比對噪音大)→ 影響:若要求回報不一致,在 `scanSource` 外層加一則 `ExtractWarning`
- A3: 驗收標準「每個 included 檔案有一筆 `FactModule`」與規則 7 best-effort 在「檔案讀不到 / 非 UTF-8」時衝突 → 採取:規則 7 優先,該檔跳過且**不產生** `FactModule`(該檔另有一則警告),驗收標準理解為「每個成功讀取的 included 檔案」→ 影響:若裁定必須恆有一筆,改以 `sfModule` 或路徑推導補一筆(事實可信度下降,且與「字面抽取」原則牴觸)
- A4: 掃描停止點(import 區邊界)未在契約定義 → 採取:第一個「第 0 欄、非空、非 `import` / `module` / CPP 指令」的 token 結束掃描(Haskell 語意上 import 必先於所有宣告)→ 影響:若遇到顯式大括號 layout 或 `#define` 反斜線續行落在第 0 欄而漏抽,改為全檔掃描(代價:字串/字元字面量誤判風險上升、大檔變慢)
- A5: 重複 import(同檔同 module 多行)與自我 import(CPP 分支下可能出現 `fiFrom == fiTo`)如何處理未定 → 採取:全部照字面出事實(行號不同即不同筆),去重與自環處理留給 graph-core(承 `F001`「不做事實去重」)→ 影響:若裁定後端內收斂,在 `scanSource` 尾端加去重(需同時決定保留哪個行號)
- A6: 契約卡要求對 MagicFarmer 與 particle-magic 執行驗收,但單元測試不得依賴這兩個外部專案存在(project-meta F001 已立此慣例)→ 採取:自動測試全部走 `test/fixtures/` 與暫存目錄,兩標的以 `knot` 執行檔手動唯讀實跑、結果記入「實作備註」;為此在 app 層加 `renderFactSummary` 與對應輸出路徑(T8),屬 executable 內部模組,不動 library 對外契約 → 影響:若編排者要求正式 CLI feature 才能動 app 層,改以一次性 ghci script 驗收,T8 只留 `renderFactSummary` 的單元測試
- A7: 字元字面量(`'x'`)未納入去註解狀態機(TemplateHaskell 的 `'name` 與識別字尾的 `'` 難以無語法解析地區分)→ 採取:只追蹤字串字面量與區塊註解,並以 A4 的 import 區邊界把風險限縮在檔頭 → 影響:若實測有標的檔案因 `'"'`、`'{'` 類字面量出錯,補上「同行 4 字元內須有閉合 `'`」的啟發式
- A8(實作階段新增): `F001` 的 T7 測試 `test_extract_entry_empty_registry` 以「註冊表為空」為斷言前提(`erReports == []`),而本 feature 的 T1 正是要把註冊表填實,兩者直接衝突 → 採取:**保留該測試的名稱**(維持 `F001` 1-to-1 對照表的可對帳性),把斷言改為「`extract` 確實委派給 `registeredBackends`」——每個註冊後端剛好一筆 `BackendReport`、`HiedbOnly` 下 import-scan 未選中故 `erFacts == []`;`extract` 的行為本身沒變,變的只是註冊表內容 → 影響:若編排者認為名稱必須跟著語意走,`F001` 文檔 T7 列與測試名同步改為 `test_extract_entry_registry`(純改名,斷言不動)

## 實作備註

### 產出與改動

| 檔案 | 改動 |
|---|---|
| `src/Knot/Extract/ImportScan.hs` | 新增:`importScanBackend` + 純掃描核心(`scanSource` / `stripCommentLines` / `headerModuleOf` / `importsOf`)+ 單檔讀取解碼 IO |
| `src/Knot/Extract.hs` | `registeredBackends` 由 `[]` 改為 `[importScanBackend]`(一行;`extract` 邏輯不動) |
| `knot-hs.cabal` | library `exposed-modules` 加 `Knot.Extract.ImportScan`;test-suite `build-depends` 加 `bytestring`;`version` 維持 `0.0.1.0` |
| `app/Knot/App/Summary.hs` | 新增 `renderFactSummary`(executable 內部模組,非 library 契約面) |
| `app/Main.hs` | 新增 `--facts` 旗標:走 `extract` 印事實摘要;預設輸出不變 |
| `test/Main.hs` | 新增 group `extraction/F002 import-scan`(T1–T8);另更新 `F001` T7 的斷言(見假設 A8) |

### 內部實作決定(Level 3 自主權範圍)

- 去註解狀態機以「消耗幾個字元就補幾個空白」取代文檔表格的「輸出一個空白」——文檔本身要求「保留行結構與欄位位置」,等寬補白同時滿足兩者,且行數/行號完全不受影響
- `--` 註解判定改用「最大連續 dash run」而非固定兩字元:`---- 四個 dash` 仍是註解(固定兩字元寫法會誤判成運算子),`-->`、`<--` 因前/後接符號字元而正確判為運算子
- token 切分統一走 `nextTok`,字串字面量整段為一個 token,`import "pkg" F.G` 的 package 名因此可整段跳過而不需另立規則

### 驗收結果(A6:`knot <PATH> --facts` 唯讀實跑,2026-08-20)

| 標的 | included 檔數 | `FactModule` | `FactImport` | 事實總數 | 警告 | 連跑兩次 |
|---|---|---|---|---|---|---|
| MagicFarmer | 58 | 58 | 523 | 581 | 0 | 輸出完全相同 |
| particle-magic | 44 | 44 | 342 | 386 | 0 | 輸出完全相同 |

機械性對帳(全部唯讀):

- **驗收標準 1**:兩標的的 `FactModule` 筆數 == `sfIncluded = True` 檔數(58/58、44/44),逐檔一筆無遺漏
- **module 名正確性**:102 個檔逐一比對「檔內 `module` 標頭 vs 抽出的 `fmModule`」,**0 筆不符**;無標頭檔(如 MagicFarmer `app/Main.hs`)正確落為 `Main`(D3 在真實專案驗證通過)
- **import 筆數對帳**:102 個檔逐一比對「檔內第 0 欄 `^import` 行數 vs 抽出的 `FactImport` 筆數」,**0 筆不符**
- **驗收標準 4**:兩標的皆 0 警告(無讀取/解碼失敗);失敗路徑改由 T6 的暫存目錄(非法 UTF-8 檔 + 不存在的檔)覆蓋
- **唯讀性**:實跑後兩標的 `git status` 無新增改動,亦未建立 `.knot/`(hiedb 後端尚未註冊)

已知未被真實標的觸及、僅由單元測試覆蓋的路徑:多行 `import`(關鍵字獨佔一行)、package-qualified import、CPP `#if` / `#else` 雙分支同時抽取、`{-# SOURCE #-}`——兩個標的的 header 區都沒有這些寫法。

### 未偏離契約

公開介面全部落在 Level 2 契約內(`Backend` 實例 + 既有 `Fact` 建構子);`ExtractOptions.rootDir` 已由階段一閘門裁決落為契約(假設 A1 已消解)。無新增 Level 2 契約變更需求。
