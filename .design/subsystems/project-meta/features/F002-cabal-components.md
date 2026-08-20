---
id: F002
type: feature
title: cabal-components
description: 以 Cabal boot lib 解析多套件 component 並落實檔案歸類與精確 module 對映
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: [F001]
related-adr: [ADR-001]
related-feature: []
---

# F002: cabal-components — .cabal 解析與 component 歸類

## 功能概述

project-meta 子系統階段二的 cabal-model 模組,同時強化 discovery 與 source-index:用 GHC 自帶的 Cabal boot library 解析 `.cabal`,把 S1 的「一堆 `.hs` 檔 + 大寫尾綴猜測」升級為「每個檔案屬於哪些 component、精確的 module 名、依 component kind 判定的納入與否」。

**要解決的問題**:S1 的排除靠路徑啟發式(頂層 `test/`、`tests/`、`bench/`),對 particle-magic 這種 `hs-source-dirs: test, app, src/ffi, tools` 的跨目錄 test-suite 完全失準——`app/` 下的檔案既是 executable 的原始碼、也被 test-suite 編進去,S1 無從得知;而 `tools/` 下三個 executable 共用同一目錄,S1 也看不見。同時 S1 的大寫尾綴法只是啟發式,`src/core/Magic/Types.hs` 究竟是 `Magic.Types` 還是 `Core.Magic.Types` 必須由 `hs-source-dirs` 決定。本 feature 把這兩件事從猜測變成事實。

**驗收標準**(契約卡原文;驗收標的絕對唯讀,委派決策 D5):

1. 對 particle-magic 執行——列出 9 個 component(named library 2、executable 4、foreign-library 1、test-suite 1、benchmark 1)
2. `app/` 下檔案 `sfOwners` 同時含 executable 與 test-suite,且 `sfIncluded = True`
3. 僅屬 test-suite 的 `test/` 檔案 `sfIncluded = False`
4. 多套件 `cabal.project` 能列出多個 `PackageMeta`(以臨時 fixture 專案驗證,不得改動驗收標的專案)

**明確不做**(契約卡底線):不做非預設 flag 組合的 conditional 求值(以預設 flag 攤平);不解析 build-depends 依賴圖;不讀 `.hie`;不掃 `dist-newstyle` 內的原始碼。對目標專案一律唯讀。

## 相依性

`depends-on: [F001]`——本 feature 的每一項工作都建立在 F001 已落地的程式碼上,無其他文檔相依:

- 消費 F001 定義的 DTO(`src/Knot/Meta/Types.hs`):`PackageMeta`、`ComponentMeta`、`ComponentKind`、`ComponentRef` 為 F001 依 design.md 原文先行定義、零邏輯(F001 假設 A5),本 feature 賦予語意;`MetaOptions`、`SourceFile`、`ModuleName`、`MetaWarning` 直接使用
- 改寫 F001 的 `findCabalFiles`(`src/Knot/Meta/Discovery.hs`)使其支援 `cabal.project`,簽名不變
- 改寫 F001 的 `indexSources`(`src/Knot/Meta/SourceIndex.hs`)使其真正消費第二參數,簽名不變;重用其既有匯出的純函數 `moduleNameFromPath` 作為「無 owner 檔案」的退回路徑
- 接線 F001 的 `loadProjectMeta`(`src/Knot/Meta.hs`)與 `renderMetaSummary`(`app/Knot/App/Summary.hs`)

介面表中其餘皆 GHC 9.14.1 boot libraries(`Cabal`、`Cabal-syntax`、`bytestring`、`directory`、`filepath`、`base`、`containers`),簽名已於 2026-08-20 在本機 GHC 9.14.1 以 GHCi `:t` 讀出原文(見介面表),並以獨立 spike 專案(`build-depends: Cabal ^>=3.16, Cabal-syntax ^>=3.16`)實跑 `cabal build` 驗證 solver 不需 `allow-newer` 即可解、且全部 API 在 `GHC2024` + `-Wall` 下編譯乾淨。

**與 F003(hie-discovery)的關係**:兩份設計無介面交集(F003 只動 hie-locate,只吃 F001 已定義的 `[SourceFile]` 與 `MetaOptions`),故不互列 `depends-on`。唯一交集是 `src/Knot/Meta.hs` 的 `loadProjectMeta` 為兩者共同的接線點:編排者排定 F002 → F003 序列實作(F003 假設 A8),F003 實作時在本 feature 完成後的最新版上接 `pmHie`,警告彙整順序為 discovery → cabal-model → source-index → hie-locate。本 feature 完成後 `sfModule` 由大寫尾綴法升級為精確對映,F003 的幽靈判定品質隨之提升,兩份文檔均不需改動。

**可平行性**:與 F003 的設計可平行(已完成);實作依編排者的階段內序列。與其他子系統的未來任務可平行。

## 對應的 Level 2 契約

逐條對照 `.design/subsystems/project-meta/design.md`:

| 契約項 | 本 feature 的落實 |
|---|---|
| 模組介面 `resolvePackage :: FilePath -> IO (Either MetaWarning PackageMeta)` | 完整實作(design.md「模組間公開介面 › cabal-model」原文簽名) |
| 模組介面 `findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])` | 強化:支援 `cabal.project` 的 `packages` 多套件列表;無 `cabal.project` 時退回 S1 的根目錄 `*.cabal` 行為。簽名不變 |
| 模組介面 `indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])` | 強化:第二參數由「恆收 `[]`」改為真正消費,填實 `sfOwners`、以 component 判定取代啟發式。簽名不變 |
| DTO `PackageMeta`(`pkgName`、`pkgCabalFile`、`pkgComponents`) | F001 已照原文定義;本 feature 賦予語意,欄位零改動 |
| DTO `ComponentMeta`(`compName`、`compKind`、`compSourceDirs`、`compExcluded`) | 同上;`compName` 採 cabal 自身的 component target 前綴命名(假設 A3) |
| DTO `ComponentKind`(六種) | 同上;對映 Cabal 的 main library / sub-library / executable / foreign-library / test-suite / benchmark |
| DTO `ComponentRef`(`(pkgName, compName)` 參照) | 同上;`sfOwners` 的元素 |
| 判定規則 1(kind 排除) | `TestSuite`、`Benchmark` → `compExcluded = not includeTests`;其餘 kind 恆 `False` |
| 判定規則 2(一對多歸類與納入判定) | 檔案落在多個 component 的 `hs-source-dirs` 時 `sfOwners` 全列;`sfIncluded = any (not . compExcluded)` |
| 判定規則 3(S2 精確 module 對映) | 以「檔案路徑相對於所屬 component 的 `hs-source-dirs`」推導,取代大寫尾綴法;無 owner 的檔案退回 S1 尾綴法(假設 A5) |
| 判定規則 4(S1 路徑啟發式) | 有 owner 的檔案由 component 判定取代;無 owner 的檔案(含專案無 `.cabal` 的情況)保留啟發式作為退回(假設 A5) |
| 判定規則 7(決定性) | `pmPackages`、`pkgComponents`、`sfOwners`、`pmSources` 全部固定序;同輸入同輸出 |
| 資料流管線段落 | discovery 的 `.cabal` 清單 → cabal-model(`resolvePackage`)→ source-index(`indexSources`),出 owners/included/module 填實的 `[SourceFile]` 與 `pmPackages` |
| 錯誤策略(best-effort) | `.cabal` 解析失敗 → 警告 + 略過該套件,不中斷;`cabal.project` 讀不到/解析不了 → 警告 + 退回根目錄掃描 |
| 使用的技術(Cabal boot library) | `Cabal-3.16.0.0` + `Cabal-syntax-3.16.0.0`(GHC 9.14.1 自帶),不引入任何第三方套件 |

未新增任何超出 Level 2 的公開介面。新 module 命名依委派決策 D3 的自主權定為 `Knot.Meta.CabalModel`。

## 實作方式

### 技術選型的實測結論(2026-08-20,GHC 9.14.1)

以探測程式對 particle-magic、MagicFarmer、knot-hs 自身與合成 fixture 實跑後確認:

- **解析進入點**:用 `Distribution.PackageDescription.Parsec.parseGenericPackageDescription`(純函數,吃 `ByteString`)+ `runParseResult`,自己 `BS.readFile`。不用 `Distribution.Simple.PackageDescription.readGenericPackageDescription`——後者在 Cabal 3.16 走 `SymbolicPath` 參數且會自行拋 IO 例外,與 best-effort 的 `Either MetaWarning` 契約不合
- **conditional 攤平**:必須用 `finalizePD`,**不可**用 `flattenPackageDescription`。實測合成 fixture(`flag extra` 預設 `False` 加 `src-extra`、`if os(windows) … else …`):
  - `finalizePD mempty …` → `["src","src-win"]`(預設 flag 值 + 本機平台,正是契約要的「以預設 flag 攤平」)
  - `flattenPackageDescription` → `["src","src-extra","src-win","src-posix"]`(取所有分支聯集,會把非預設 flag 的目錄也算進來,違反「明確不做」)
- **`finalizePD` 的參數**(Cabal 3.16 的第三參數型別是 `Dependency -> DependencySatisfaction`,不是 `Dependency -> Bool`;3.16 才改的):
  - `FlagAssignment` = `mempty`(全部 flag 取宣告的 `default:`)
  - `ComponentRequestedSpec { testsRequested = True, benchmarksRequested = True }`(否則 test-suite / benchmark 會被丟掉,而本 feature 需要列出它們並標 `compExcluded`)
  - `(const Satisfied)`(不解析 build-depends 依賴圖——契約卡「明確不做」)
  - `buildPlatform`(`Distribution.System`)、`unknownCompilerInfo (CompilerId GHC (mkVersion [9,14,1])) NoAbiTag`、`[]`
- **`hs-source-dirs` 空白時 Cabal 已自動正規化為 `["."]`**(實測合成 fixture 無 `hs-source-dirs` 的 library 與 test-suite 皆得 `["."]`),不需自行補預設值
- **component 宣告序被保留**:particle-magic 實測 `magic-core, magic-boundary`、`particle-magic, magic-validate, magic-schema, magic-inspect` 皆為 `.cabal` 內的宣告序(`flattenPackageDescription` 反而會重排),故決定性可直接依賴 Cabal 的輸出序
- **`cabal.project` 沒有公開解析器**(那部分在 cabal-install,不是 boot library):改用 `Distribution.Fields.Parser.readFields` 取通用欄位表,自行取 `packages` / `optional-packages` 欄位。實測對 particle-magic 與 MagicFarmer 的 `cabal.project` 皆成功,註解已被剝除
- **名稱衝突**:`Distribution.PackageDescription` 重匯出的 `pkgName :: PackageIdentifier -> PackageName` 與 `Knot.Meta.Types.pkgName :: PackageMeta -> Text` 同名。`Knot.Meta.CabalModel` 一律以明確 import list / qualified import 隔開
- **solver 實測**:獨立 spike 專案 `build-depends: base ^>=4.22, Cabal ^>=3.16, Cabal-syntax ^>=3.16, bytestring, directory, filepath, text`,`cabal build` 直接通過(`-w ghc-9.14.1`),無需 `allow-newer`,`GHC2024` + `-Wall` 無警告

### cabal-model:`resolvePackage`

```text
resolvePackage cabalPath
  · BS.readFile cabalPath(IOException → Left MetaWarning)
  · runParseResult (parseGenericPackageDescription bs)
      - Left (_, errs) → Left (MetaWarning cabalPath (showPError 的訊息,取第一則 + 總則數))
      - 非致命 PWarning 一律丟棄(Either 只能帶一則警告,契約使然;見假設 A6)
  · finalizePD mempty (tests+benchmarks requested) (const Satisfied) buildPlatform ghc9141 [] gpd
      - Left missing → Left MetaWarning(理論上不會發生,因相依一律視為滿足;見假設 A7)
      - Right (pd, _) → 抽 component
  · component 抽取順序(固定):
      main library → sub-libraries → executables → foreign-libraries → test-suites → benchmarks
      各段內維持 Cabal 給的宣告序
  · 每個 component:
      compName       = 前綴 <> ":" <> 名稱(見下)
      compKind       = 對應的 ComponentKind
      compSourceDirs = map getSymbolicPath (hsSourceDirs bi),各自 normalise + 反斜線轉正斜線
      compExcluded   = False(kind 排除由 indexSources 依 MetaOptions 決定;見下方「規則 1 的落點」)
  · pkgName      = unPackageName (Distribution.Types.PackageId.pkgName (package pd))
    pkgCabalFile = takeFileName cabalPath(路徑基準由呼叫端錨定;見下)
```

**`compName` 命名**(design.md 只給了 `"lib:magic-core"`、`"exe:particle-magic"` 兩個例子,其餘四種依 cabal 自身的 component target 語法補齊;假設 A3):

| ComponentKind | compName |
|---|---|
| `MainLibrary` | `lib:<套件名>` |
| `NamedLibrary` | `lib:<sub-library 名>` |
| `Executable` | `exe:<名稱>` |
| `ForeignLibrary` | `flib:<名稱>` |
| `TestSuite` | `test:<名稱>` |
| `Benchmark` | `bench:<名稱>` |

**路徑基準(假設 A1)**:Level 2 把 `resolvePackage` 的簽名鎖成單一 `FilePath`,而 `pkgCabalFile` 契約要求「repo 相對」——一個參數無法同時是「讀得到的路徑」與「repo 相對路徑」。解法:`resolvePackage` 只負責**相對於 `.cabal` 檔自身目錄**的結果(`pkgCabalFile` = 檔名、`compSourceDirs` = `.cabal` 內原樣的 `hs-source-dirs`),由組裝層 `Knot.Meta.loadProjectMeta` 以 root 與 discovery 給的 repo 相對路徑錨定。這樣不需要在 Windows 上做易碎的絕對路徑裁切,`resolvePackage` 也保持不需要知道 root。DTO 契約(`pkgCabalFile` 為 repo 相對)在子系統對外輸出 `ProjectMeta` 時成立。

### discovery:`findCabalFiles` 支援 `cabal.project`

```text
findCabalFiles root
  1. <root>/cabal.project 存在?
     否 → S1 行為:listDirectory root 取 *.cabal(排序);空 → 警告 "no .cabal file found"
     是 → readFields 讀出欄位表
            解析失敗(Left ParseError)→ 警告 + 退回 S1 行為
            成功 → 取頂層欄位名 "packages" 與 "optional-packages" 的所有 FieldLine
  2. entry 切分:每個 FieldLine 以逗號與空白切成 entry(cabal 兩種寫法都收),去空字串
  3. entry 展開(路徑一律以 root 為基準組合、正斜線化、normalise):
       · 以 ".cabal" 結尾           → 該檔存在則收,否則警告(來自 packages)/ 靜默略過(來自 optional-packages)
       · 目錄(含 "." 與尾斜線)    → listDirectory 取其中 *.cabal 全收;目錄不存在同上
       · 含 '*'                     → 不展開,出一則警告並略過(明確不支援 glob;假設 A2)
  4. nubOrd + sort(碼位序)後回傳 repo 相對正斜線路徑
  5. 展開結果為空 → 警告 "no .cabal file found"
```

`packages: .` 展開為根目錄的 `*.cabal`,與 S1 結果相同——兩個驗收標的與 knot-hs 自身都是這個形狀,故既有行為不回歸。

### source-index:規則 1、2、3 的落點

`indexSources` 收到的 `[PackageMeta]` 已由組裝層錨定為 repo 相對。走訪與正斜線重組沿用 F001 既有實作,改動集中在「每個檔案怎麼填三個欄位」:

```text
準備(純函數,走訪前算一次):
  ownerIndex = [ (ComponentRef (pkgName p, compName c), compKind c, dir)
               | p <- pkgs, c <- pkgComponents p, dir <- compSourceDirs p c ]
             (順序 = pmPackages 序 × pkgComponents 序 × compSourceDirs 序,決定性)
  excluded kind = kind ∈ {TestSuite, Benchmark} && not (includeTests opts)

每個檔案 path:
  matches = [ (ref, kind, dir) | (ref, kind, dir) <- ownerIndex, dir `underOf` path ]
            underOf:以路徑「段」比對,dir == "." 視為根(恆命中);
                    dir 的段序列為 path 段序列的前綴,且 path 還有剩餘段
  sfOwners   = nubOrd(保序)[ ref | (ref, _, _) <- matches ]      -- 規則 2
  sfIncluded | null matches = includedByHeuristic (S1 規則 4,退回路徑)
             | otherwise    = any (\(_, k, _) -> not (excluded k)) matches   -- 規則 1 + 2
  sfModule   | null matches = moduleNameFromPath path            -- S1 尾綴法退回(假設 A5)
             | otherwise    = modFromDir (最長的命中 dir) path    -- 規則 3
```

`compExcluded` 欄位本身(`ComponentMeta` 的一部分)在 `indexSources` 內依 `includeTests` 重新計算並寫回 `pmPackages` 交出的副本——`resolvePackage` 看不到 `MetaOptions`,而契約要求 `compExcluded` 是「依 kind 與 `includeTests` 判定」的結果,故這一步由組裝層在呼叫 `indexSources` 前套用(見下)。

**`modFromDir`(規則 3 的精確對映,純函數)**:

1. 取命中的最長 `hs-source-dirs`(段數最多者;段數相同代表同一個 dir,故唯一)
2. `path` 去掉該 dir 的前綴段,末段以 `stripExtension "hs"` 去副檔名
3. 剩餘段序列每段首字元都必須 `isUpper` 且非空——全部通過才以 `.` 連接為 `ModuleName`,任一段不通過 → `Nothing`(例:`src/lowercase/util.hs` 在 `hs-source-dirs: src` 下 → `Nothing`)

取最長 dir 是因為一個檔案可能同時落在 `src` 與 `src/core` 之下,精確 module 名該由最貼近的那個決定;此規則同時保證決定性。

**驗收對帳**(以 particle-magic 的實測 component 表推演):

| 檔案 | 命中的 hs-source-dirs | `sfOwners` | `sfIncluded`(預設) |
|---|---|---|---|
| `app/App/Loop.hs` | `app`(exe:particle-magic)、`app`(test:spec)、`app`(bench:bench) | 三者 | `True`(exe 未排除)✅ 驗收 2 |
| `test/BoundarySpec.hs` | `test`(test:spec) | 僅 test:spec | `False` ✅ 驗收 3 |
| `bench/Bench.hs` | `bench`(bench:bench) | 僅 bench:bench | `False` |
| `tools/Validate.hs` | `tools`(exe ×3、test:spec) | 四者 | `True` |
| `src/core/Magic/Types.hs` | `src/core`(lib:magic-core) | lib:magic-core | `True`,module `Magic.Types` |
| `examples/haskell/Main.hs` | 無 | `[]` | 退回啟發式 → `True`,module `Main`(尾綴法) |

### 組裝層:`Knot.Meta.loadProjectMeta`

```text
loadProjectMeta opts = do
  (cabalRels, wsD) <- findCabalFiles (root opts)          -- repo 相對
  results          <- mapM (\rel -> resolvePackage (root opts </> rel)) cabalRels
  let (wsP, pkgsRaw) = partitionEithers results            -- 失敗者只留警告,略過該套件
      pkgs = zipWith anchor cabalRels' pkgsRaw             -- 錨定 + compExcluded 判定
  (sources, wsI) <- indexSources opts pkgs
  pure ProjectMeta { pmPackages = pkgs, pmSources = sources
                   , pmWarnings = wsD ++ wsP ++ wsI }      -- 固定順序(規則 7)
 where
  anchor rel pm = pm { pkgCabalFile  = rel
                     , pkgComponents = [ c { compSourceDirs = map (prefix (takeDirectory rel)) (compSourceDirs c)
                                           , compExcluded   = isExcludedKind (compKind c) }
                                       | c <- pkgComponents pm ] }
  prefix "." d = normaliseSlash d
  prefix pd  d = normaliseSlash (pd </> d)     -- d == "." 時化簡為 pd
  isExcludedKind k = k `elem` [TestSuite, Benchmark] && not (includeTests opts)
```

`wsP` 的順序 = `cabalRels` 的順序(已排序),決定性成立。警告總順序:discovery → cabal-model → source-index;F003 實作時在尾端追加 hie-locate(F003 假設 A8)。

### 決定性(判定規則 7)

- `pmPackages`:`findCabalFiles` 的排序 + 去重結果決定順序
- `pkgComponents`:kind 分段固定序 × Cabal 保留的宣告序(實測確認)
- `sfOwners`:`pmPackages` 序 × `pkgComponents` 序 × `compSourceDirs` 序,`nubOrd` 保序去重
- `pmSources`:沿用 F001 的 `sortOn sfPath`
- 無 mtime、無雜湊迭代序、`finalizePD` 的輸入(flag assignment、platform、compiler info)全部固定

### 測試 fixture 策略(D5)

驗收標的絕對唯讀,fixture 全部新建於 `test/fixtures/`,不動 F001 既有的 `proj/` 與 `no-cabal/` 樹:

```text
test/fixtures/comps/                 六種 kind 齊全 + 一對多歸類(particle-magic 的縮小模型)
├── comps.cabal        library(src)、library sub(src/sub)、executable(app)、
│                      foreign-library(src/ffi)、test-suite(test, app)、benchmark(bench, app)
├── src/Comps/Core.hs          lib:comps → Comps.Core
├── src/sub/Comps/Sub.hs       lib:sub   → Comps.Sub
├── src/ffi/Comps/FFI.hs       flib
├── src/lowercase/util.hs      落在 src 下但段非大寫 → sfModule = Nothing
├── app/Main.hs                exe + test + bench(三 owner,included = True)
├── test/Spec.hs               僅 test(included = False,--include-tests 翻轉)
└── bench/Bench.hs             僅 bench(included = False)

test/fixtures/cond/                  預設 flag 攤平
└── cond.cabal         flag extra(default False)加 src-extra;if os(windows)/else
                       期望:src 恆在、src-extra 不在、平台分支恰一個

test/fixtures/multi/                 多套件 cabal.project(驗收標準 4)
├── cabal.project      packages: pkg-a, ./pkg-b/
├── pkg-a/pkg-a.cabal  library(src)+ test-suite(test)
├── pkg-a/src/A/Core.hs
├── pkg-a/test/ASpec.hs
├── pkg-b/pkg-b.cabal  executable(app)
└── pkg-b/app/Main.hs

test/fixtures/broken/                解析失敗路徑
└── broken.cabal       故意寫壞的語法 → resolvePackage 回 Left
```

particle-magic 的 9 component 驗收以 `knot` 執行檔手動執行(唯讀),屬階段閘門步驟,不寫成自動測試(沿 F001 前例)。

### F001 既有測試的回歸

`test/fixtures/proj/proj.cabal` 目前只有 `name: proj` / `version: 0`(實測:可解析、0 component)。本 feature 上線後該 fixture 的 `pmPackages` 會由 `[]` 變成一個 0-component 的 `PackageMeta`,而 0 component 代表所有檔案無 owner、走退回路徑——`pmSources` 的 `sfPath` / `sfModule` / `sfIncluded` 期望值完全不變。需要更新的只有 `test/Main.hs` 的 T8 `test_load_project_meta` 中 `pmPackages pm @?= []` 這一條斷言(改為斷言一個 `pkgName = "proj"`、`pkgCabalFile = "proj.cabal"`、`pkgComponents = []` 的 `PackageMeta`)。T3 `test_find_cabal_files` 的期望(`["proj.cabal"]`、no-cabal 一則警告)在無 `cabal.project` 的退回路徑下不變。

## 使用到的既有串接介面

(專案自有介面的簽名為 2026-08-20 從來源檔案讀出的原文;boot library 簽名為同日於本機 GHC 9.14.1 以 GHCi `:t` 讀出的原文,`ByteString` 一律還原為 `Data.ByteString.ByteString` 的短名)

| 介面(含完整簽名) | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])` | src/Knot/Meta/Discovery.hs | F001 | 本 feature 改寫其實作以支援 `cabal.project`,簽名不變 |
| `indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])` | src/Knot/Meta/SourceIndex.hs | F001 | 本 feature 改寫其實作以消費第二參數,簽名不變 |
| `moduleNameFromPath :: FilePath -> Maybe ModuleName` | src/Knot/Meta/SourceIndex.hs | F001 | 無 owner 檔案的 module 對映退回路徑(S1 大寫尾綴法) |
| `loadProjectMeta :: MetaOptions -> IO ProjectMeta` | src/Knot/Meta.hs | F001 | 接線標的:`pmPackages` 由恆 `[]` 改為填實,並負責 root 錨定 |
| `renderMetaSummary :: ProjectMeta -> Text` | app/Knot/App/Summary.hs | F001 | 擴充摘要以印出 package / component / owners,供驗收觀察 |
| `data PackageMeta = PackageMeta { pkgName :: Text, pkgCabalFile :: FilePath, pkgComponents :: [ComponentMeta] }` | src/Knot/Meta/Types.hs | F001 | `resolvePackage` 的輸出 DTO(F001 先行定義,零邏輯) |
| `data ComponentMeta = ComponentMeta { compName :: Text, compKind :: ComponentKind, compSourceDirs :: [FilePath], compExcluded :: Bool }` | src/Knot/Meta/Types.hs | F001 | component 描述 |
| `data ComponentKind = MainLibrary \| NamedLibrary \| Executable \| ForeignLibrary \| TestSuite \| Benchmark` | src/Knot/Meta/Types.hs | F001 | kind 排除判定(規則 1)的依據 |
| `newtype ComponentRef = ComponentRef (Text, Text)` | src/Knot/Meta/Types.hs | F001 | `sfOwners` 的元素 |
| `data SourceFile = SourceFile { sfPath :: FilePath, sfModule :: Maybe ModuleName, sfOwners :: [ComponentRef], sfIncluded :: Bool }` | src/Knot/Meta/Types.hs | F001 | 本 feature 填實 `sfOwners`,改寫 `sfModule`、`sfIncluded` 的推導 |
| `data MetaOptions = MetaOptions { root :: FilePath, includeTests :: Bool, hieDirOverride :: Maybe FilePath }` | src/Knot/Meta/Types.hs | F001 | 輸入:`root`(錨定基準)與 `includeTests`(規則 1 翻轉) |
| `newtype ModuleName = ModuleName Text` | src/Knot/Meta/Types.hs | F001 | 精確 module 對映的輸出型別 |
| `data MetaWarning = MetaWarning { mwPath :: FilePath, mwMessage :: Text }` | src/Knot/Meta/Types.hs | F001 | 警告載體(`resolvePackage` 的 `Left`) |
| `parseGenericPackageDescription :: ByteString -> ParseResult GenericPackageDescription` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription.Parsec`) | - | `.cabal` 解析進入點(純函數,自行讀檔) |
| `runParseResult :: ParseResult a -> ([PWarning], Either (Maybe Version, NonEmpty PError) a)` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription.Parsec`) | - | 取出解析結果與錯誤 |
| `showPError :: FilePath -> PError -> String` | Cabal-syntax-3.16.0.0(`Distribution.Parsec`) | - | 解析錯誤轉成 `MetaWarning` 的訊息 |
| `finalizePD :: FlagAssignment -> ComponentRequestedSpec -> (Dependency -> DependencySatisfaction) -> Platform -> CompilerInfo -> [PackageVersionConstraint] -> GenericPackageDescription -> Either [MissingDependency] (PackageDescription, FlagAssignment)` | Cabal-3.16.0.0(`Distribution.PackageDescription.Configuration`) | - | 以**預設 flag** 攤平 conditional(契約要求;`flattenPackageDescription` 取全分支聯集,不可用) |
| `data ComponentRequestedSpec = ComponentRequestedSpec { testsRequested :: Bool, benchmarksRequested :: Bool } \| OneComponentRequestedSpec ComponentName` | Cabal-syntax-3.16.0.0(`Distribution.Types.ComponentRequestedSpec`) | - | 要求保留 test-suite 與 benchmark(否則被丟掉) |
| `data DependencySatisfaction = Satisfied \| Unsatisfied MissingDependencyReason` | Cabal-syntax-3.16.0.0(`Distribution.Types.DependencySatisfaction`) | - | `finalizePD` 第三參數;一律回 `Satisfied`(不解析依賴圖) |
| `buildPlatform :: Platform` | Cabal-syntax-3.16.0.0(`Distribution.System`) | - | `if os(...)` / `if arch(...)` 的求值平台 |
| `unknownCompilerInfo :: CompilerId -> AbiTag -> CompilerInfo` | Cabal-syntax-3.16.0.0(`Distribution.Compiler`) | - | 組 `finalizePD` 的 `CompilerInfo`(`if impl(ghc …)` 求值) |
| `CompilerId :: CompilerFlavor -> Version -> CompilerId` | Cabal-syntax-3.16.0.0(`Distribution.Compiler`) | - | 同上,搭配 `GHC` 與 `mkVersion [9,14,1]`(ADR-001 版本鎖) |
| `NoAbiTag :: AbiTag` | Cabal-syntax-3.16.0.0(`Distribution.Compiler`) | - | 同上 |
| `mkVersion :: [Int] -> Version` | Cabal-syntax-3.16.0.0(`Distribution.Version`) | - | 組 GHC 9.14.1 版本值 |
| `library :: PackageDescription -> Maybe Library` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取 main library |
| `subLibraries :: PackageDescription -> [Library]` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取具名 sub-library(particle-magic 有 2 個) |
| `executables :: PackageDescription -> [Executable]` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取 executable(4 個) |
| `foreignLibs :: PackageDescription -> [ForeignLib]` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取 foreign-library(1 個) |
| `testSuites :: PackageDescription -> [TestSuite]` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取 test-suite(1 個) |
| `benchmarks :: PackageDescription -> [Benchmark]` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取 benchmark(1 個) |
| `data LibraryName = LMainLibName \| LSubLibName UnqualComponentName` | Cabal-syntax-3.16.0.0(`Distribution.Types.LibraryName`) | - | 分辨 `MainLibrary` 與 `NamedLibrary` |
| `libName :: Library -> LibraryName` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 同上 |
| `exeName :: Executable -> UnqualComponentName` / `foreignLibName :: ForeignLib -> UnqualComponentName` / `testName :: TestSuite -> UnqualComponentName` / `benchmarkName :: Benchmark -> UnqualComponentName` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取 component 名稱 |
| `unUnqualComponentName :: UnqualComponentName -> String` | Cabal-syntax-3.16.0.0(`Distribution.Types.UnqualComponentName`) | - | component 名稱轉字串 |
| `libBuildInfo :: Library -> BuildInfo` / `buildInfo :: Executable -> BuildInfo` / `foreignLibBuildInfo :: ForeignLib -> BuildInfo` / `testBuildInfo :: TestSuite -> BuildInfo` / `benchmarkBuildInfo :: Benchmark -> BuildInfo` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取各 component 的 `BuildInfo` |
| `hsSourceDirs :: BuildInfo -> [SymbolicPath Pkg (Dir Source)]` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | `compSourceDirs` 的來源(空白時 Cabal 已正規化為 `["."]`) |
| `getSymbolicPath :: SymbolicPathX allowAbsolute from to -> FilePath` | Cabal-syntax-3.16.0.0(`Distribution.Utils.Path`) | - | `SymbolicPath` 轉 `FilePath`(Cabal 3.12 起 `hs-source-dirs` 改用此型別) |
| `package :: PackageDescription -> PackageIdentifier` | Cabal-syntax-3.16.0.0(`Distribution.PackageDescription`) | - | 取套件識別 |
| `pkgName :: PackageIdentifier -> PackageName` | Cabal-syntax-3.16.0.0(`Distribution.Types.PackageId`) | - | 取套件名(與 `Knot.Meta.Types.pkgName` 同名,須 qualified) |
| `unPackageName :: PackageName -> String` | Cabal-syntax-3.16.0.0(`Distribution.Types.PackageName`) | - | 套件名轉字串 |
| `readFields :: ByteString -> Either ParseError [Field Position]` | Cabal-syntax-3.16.0.0(`Distribution.Fields.Parser`) | - | `cabal.project` 通用欄位解析(Cabal 無公開的 project 解析器) |
| `data Field ann = Field !(Name ann) [FieldLine ann] \| Section !(Name ann) [SectionArg ann] [Field ann]` | Cabal-syntax-3.16.0.0(`Distribution.Fields.Field`) | - | 取 `packages` / `optional-packages` 欄位 |
| `data Name ann = Name !ann !FieldName` | Cabal-syntax-3.16.0.0(`Distribution.Fields.Field`) | - | 比對欄位名 |
| `data FieldLine ann = FieldLine !ann !ByteString` | Cabal-syntax-3.16.0.0(`Distribution.Fields.Field`) | - | 取欄位每一行的原始位元組 |
| `Data.ByteString.readFile :: FilePath -> IO ByteString` | bytestring-0.12.2.0 | - | 讀 `.cabal` 與 `cabal.project` |
| `Data.ByteString.Char8.unpack :: ByteString -> [Char]` | bytestring-0.12.2.0 | - | 欄位名與 entry 轉字串 |
| `System.Directory.listDirectory :: FilePath -> IO [FilePath]` | directory-1.3.10.0 | - | `packages` entry 為目錄時列出其 `*.cabal` |
| `System.Directory.doesFileExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | `cabal.project` 與 `.cabal` entry 存在性 |
| `System.Directory.doesDirectoryExist :: FilePath -> IO Bool` | directory-1.3.10.0 | - | 分辨 entry 是目錄還是檔案 |
| `System.FilePath.takeDirectory :: FilePath -> FilePath` | filepath-1.5.4.0 | - | 由 `.cabal` 路徑取套件目錄(root 錨定) |
| `System.FilePath.normalise :: FilePath -> FilePath` | filepath-1.5.4.0 | - | 化簡 `./x`、`x/.` 等形式 |
| `System.FilePath.splitDirectories :: FilePath -> [FilePath]` | filepath-1.5.4.0 | - | 段層級的 `hs-source-dirs` 前綴比對與 module 對映 |
| `System.FilePath.stripExtension :: String -> FilePath -> Maybe FilePath` | filepath-1.5.4.0 | - | 去 `.hs` 副檔名取 module 末段 |
| `Data.Containers.ListUtils.nubOrd :: Ord a => [a] -> [a]` | containers-0.8 | - | `.cabal` 清單與 `sfOwners` 保序去重 |
| `Data.List.sortOn :: Ord b => (a -> b) -> [a] -> [a]` | base-4.22.0.0(GHC 9.14.1) | - | 決定性排序 |
| `Data.List.isPrefixOf :: Eq a => [a] -> [a] -> Bool` | base-4.22.0.0(GHC 9.14.1) | - | 段序列前綴比對 |
| `Data.Char.isUpper :: Char -> Bool` | base-4.22.0.0(GHC 9.14.1) | - | module 段合法性判定 |
| `Data.Either.partitionEithers :: [Either a b] -> ([a], [b])` | base-4.22.0.0(GHC 9.14.1) | - | 拆 `resolvePackage` 的成功/失敗結果 |

## 新增的介面

全部落在 Level 2 契約內;`findCabalFiles`、`indexSources`、`loadProjectMeta` 只改實作,簽名一字不動。

**`Knot.Meta.CabalModel`(Level 2 模組介面 cabal-model;D3 命名自主權)**

```haskell
resolvePackage :: FilePath -> IO (Either MetaWarning PackageMeta)
-- design.md「模組間公開介面 › cabal-model」原文簽名
-- 解析單一 .cabal → PackageMeta(conditional 以預設 flag 值攤平)
-- 回傳的 pkgCabalFile 為 .cabal 檔名、compSourceDirs 為相對該 .cabal 所在目錄;
-- repo 相對的錨定由組裝層 Knot.Meta 負責(假設 A1)
-- compExcluded 一律 False(它依 includeTests,由組裝層套用)
```

`knot-hs.cabal` 的 library `exposed-modules` 加入 `Knot.Meta.CabalModel`;`build-depends` 加入 `Cabal ^>=3.16`、`Cabal-syntax ^>=3.16`、`bytestring`(皆 GHC 9.14.1 boot library,已 spike 驗證 solver 可解;元件結構不變,不屬介面新增)。

**executable 內部(不屬 library 對外介面,不進 Level 2 契約面)**

```haskell
renderMetaSummary :: ProjectMeta -> Text   -- 簽名不變,擴充輸出內容
-- 新增:package / component 區塊(pkgName、pkgCabalFile、每個 compName + kind +
-- sourceDirs + excluded),以及每個檔案行尾的 owners 標示;供驗收標準 1–3 觀察
```

## TodoList

- [ ] T1: 相依與模組骨架——`knot-hs.cabal` library 加 `Cabal`、`Cabal-syntax`、`bytestring`;新建 `Knot.Meta.CabalModel` 並列入 `exposed-modules`;`resolvePackage` 以 `parseGenericPackageDescription` + `runParseResult` 取得 `GenericPackageDescription` 並回 `Right`(component 先留空);`cabal build all` 通過  `dep: -`
- [ ] T2: 解析失敗路徑——讀檔 `IOException` 與 `runParseResult` 的 `Left` 皆轉成 `Left MetaWarning`(`mwPath` = `.cabal` 路徑,訊息取 `showPError`)  `dep: T1`
- [ ] T3: 預設 flag 攤平與 component 抽取——`finalizePD mempty (tests+benchmarks requested) (const Satisfied) buildPlatform ghc9141 []`;六種 `ComponentKind` 對映、`compName` 前綴命名、`compSourceDirs` 取 `hsSourceDirs` 並正斜線化;固定的 kind 分段序  `dep: T2`
- [ ] T4: 規則 1 的 `compExcluded` 判定——`TestSuite` / `Benchmark` 依 `includeTests` 翻轉、其餘恆 `False`(於組裝層依 `MetaOptions` 套用到 `pkgComponents`)  `dep: T3`
- [ ] T5: `findCabalFiles` 支援 `cabal.project`——`readFields` 取 `packages` / `optional-packages`、entry 切分與展開(目錄 / `.cabal` / glob 略過警告)、去重排序、無 `cabal.project` 與解析失敗時退回 S1 行為  `dep: T1`
- [ ] T6: 規則 2 的一對多歸類——`ownerIndex` 建立、段層級 `hs-source-dirs` 前綴比對、`sfOwners` 保序去重、`sfIncluded = any (not . excluded)`、無 owner 時退回 S1 啟發式  `dep: T4`
- [ ] T7: 規則 3 的精確 module 對映——取最長命中 `hs-source-dirs` 去前綴、段合法性檢查、無 owner 時退回 `moduleNameFromPath`  `dep: T6`
- [ ] T8: `loadProjectMeta` 接線與 root 錨定——`resolvePackage (root </> rel)`、`partitionEithers`、`pkgCabalFile` / `compSourceDirs` 錨定為 repo 相對、`pmPackages` 填實、警告順序 discovery → cabal-model → source-index  `dep: T5, T7`
- [ ] T9: 決定性與 F001 回歸——`pmPackages` / `pkgComponents` / `sfOwners` / `pmSources` 全序穩定;更新 `test/Main.hs` T8 中 `pmPackages pm @?= []` 的斷言(其餘 F001 期望值不變)  `dep: T8`
- [ ] T10: `renderMetaSummary` 擴充——印出 package / component 區塊與每檔 owners,供 particle-magic 唯讀驗收觀察 9 個 component 與歸類結果  `dep: T8`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | test_resolve_package_smoke | 對 `comps` fixture 呼叫 `resolvePackage` 得 `Right`,`pkgName = "comps"`、`pkgCabalFile = "comps.cabal"`;證明 `Cabal` / `Cabal-syntax` 相依接線與解析進入點成立 |
| T2 | test_resolve_parse_error | 對 `broken` fixture → `Left`,`mwPath` 為該 `.cabal` 路徑、`mwMessage` 非空;對不存在的路徑 → `Left`(不拋例外) |
| T3 | test_component_extraction | `comps` fixture:6 個 component 齊全,`compKind` 六種各一、`compName` 為 `lib:comps` / `lib:sub` / `exe:…` / `flib:…` / `test:…` / `bench:…`、`compSourceDirs` 正確且為正斜線(`test:` 含 `test` 與 `app` 兩個);`cond` fixture:含 `src`、不含 `src-extra`(預設 flag 未開)、平台分支恰一個 |
| T4 | test_component_excluded | `comps` fixture 經 `loadProjectMeta`:預設下 `test:` / `bench:` 的 `compExcluded = True`、其餘 `False`;`includeTests = True` 時全部 `False` |
| T5 | test_find_cabal_project | `multi` fixture → `["pkg-a/pkg-a.cabal","pkg-b/pkg-b.cabal"]`(排序、正斜線、無重複);`proj` fixture(無 `cabal.project`)→ `["proj.cabal"]` 不變;`no-cabal` → 空清單 + 一則警告;壞 `cabal.project` fixture → 警告且退回根目錄掃描 |
| T6 | test_owners_and_included | `comps` fixture:`app/Main.hs` 的 `sfOwners` 含 `exe:`、`test:`、`bench:` 三者且 `sfIncluded = True`;`test/Spec.hs` 僅 `test:` 且 `sfIncluded = False`;`bench/Bench.hs` 僅 `bench:` 且 `False`;`includeTests = True` 時後兩者翻轉為 `True`;`comps.cabal` 外的無 owner 檔案走啟發式 |
| T7 | test_module_mapping | `comps` fixture:`src/Comps/Core.hs` → `Comps.Core`、`src/sub/Comps/Sub.hs` → `Comps.Sub`(取最長 `hs-source-dirs`,不是 `sub.Comps.Sub`)、`src/lowercase/util.hs` → `Nothing`、`app/Main.hs` → `Main`;`no-cabal` fixture 無 owner 檔案仍由尾綴法得 `Foo` |
| T8 | test_load_meta_packages | `multi` fixture:`pmPackages` 兩個(驗收標準 4),`pkgCabalFile` 為 repo 相對(`pkg-a/pkg-a.cabal`)、`compSourceDirs` 為 repo 相對(`pkg-a/src`);跨套件檔案 `sfOwners` 指向正確套件;含壞 `.cabal` 的情境驗證警告順序為 discovery → cabal-model → source-index |
| T9 | test_s2_deterministic_and_regression | 對 `comps` 與 `multi` 連續執行兩次 `loadProjectMeta` 結果完全相等、`sfPath` 嚴格遞增;`proj` fixture 的 `pmSources`(路徑 / module / included)與 F001 期望逐項相同,`pmPackages` 為單一 0-component 的 `PackageMeta` |
| T10 | test_render_summary_components | 對已知含 `pmPackages` 的 `ProjectMeta` 值驗證 `renderMetaSummary` 輸出含套件名、`.cabal` 路徑、每個 `compName` 與其 `excluded` 標示,以及檔案行的 owners 標示 |

## 待確認假設

- A1: Level 2 把 `resolvePackage` 鎖成單一 `FilePath` 參數,但 `pkgCabalFile` 契約要求「repo 相對」——同一個參數無法既是讀得到的路徑、又是 repo 相對路徑 → 採取:`resolvePackage` 只回相對於 `.cabal` 自身目錄的結果(`pkgCabalFile` = 檔名、`compSourceDirs` = `.cabal` 內原樣),由 `Knot.Meta.loadProjectMeta` 以 root 與 discovery 的 repo 相對路徑錨定;子系統對外輸出的 `ProjectMeta` 仍完全符合契約 → 影響:若編排者要 `resolvePackage` 自己回 repo 相對,須在 Level 2 給它第二個參數(root),屬契約變更
- A2: `cabal.project` 的 `packages:` 支援 glob(如 `pkgs/*`),契約卡未提 → 採取:本 feature 只展開字面目錄與明確 `.cabal` 路徑,含 `*` 的 entry 出警告並略過(兩個驗收標的與 knot-hs 自身都是 `packages: .`,不受影響)→ 影響:若裁定要支援,在 `findCabalFiles` 加單層段 glob 展開與一條測試,不動任何介面
- A3: design.md 只給了 `compName` 的兩個例子(`"lib:magic-core"`、`"exe:particle-magic"`),其餘四種 kind 的前綴未定 → 採取:比照 cabal 自身的 component target 語法補為 `lib:` / `exe:` / `flib:` / `test:` / `bench:`,main library 用 `lib:<套件名>` → 影響:下游(extraction / graph-core)若對 `compName` 格式有別的期待,改此對映表與 T3 測試
- A4: `cabal.project` 的 `import:` 欄位可引入其他 project 檔的 `packages` 列表 → 採取:不追隨 `import:`,只讀當前檔案的 `packages` / `optional-packages` → 影響:使用 `import:` 分層的多套件專案會少列套件,需再開一個 Todo 遞迴讀取
- A5: 規則 3 / 4 說「S2 起由 component 判定取代」,但沒說「不屬任何 component 的檔案」怎麼辦(`examples/`、`scripts/`,以及專案根本沒有 `.cabal` 的情況)→ 採取:無 owner 的檔案退回 S1 的大寫尾綴法與路徑啟發式(否則沒有 `.cabal` 的專案會全部變成 `sfModule = Nothing`、F001 行為大幅回歸)→ 影響:若裁定無 owner 就該是 `Nothing` / 排除,改 `indexSources` 的退回分支與 T6/T7 測試
- A6: `parseGenericPackageDescription` 會回一批非致命的 `PWarning`(如過時欄位),但 `resolvePackage :: … -> IO (Either MetaWarning PackageMeta)` 的 `Either` 只能在失敗時帶一則警告,無法「成功且附警告」→ 採取:非致命 `PWarning` 一律丟棄,只有致命錯誤才成為 `MetaWarning` → 影響:若要保留 `.cabal` 的格式警告,`resolvePackage` 須改成回 `IO (Either MetaWarning (PackageMeta, [MetaWarning]))` 或 `IO ([MetaWarning], Maybe PackageMeta)`,屬 Level 2 契約變更
- A7: `finalizePD` 回 `Left [MissingDependency]` 時如何處置(實測以 `const Satisfied` 幾乎不會發生)→ 採取:轉成 `Left MetaWarning` 並略過該套件,不退回 `flattenPackageDescription`(後者取全分支聯集,會違反「不做非預設 flag 組合」的底線)→ 影響:若裁定寧可要不精確的結果也不要丟掉整個套件,改為 fallback 到 `flattenPackageDescription` 並加警告
- A8: `buildable: False` 的 component 是否列入 `pkgComponents` → 採取:照列,`compExcluded` 只依 kind 判定(規則 1 的原文只提 kind)→ 影響:若裁定 `buildable: False` 應視為排除,在 `compExcluded` 判定加一項並補測試
- A9: 契約卡驗收標準 2 只說 `app/` 檔案的 `sfOwners`「同時含 executable 與 test-suite」,但 particle-magic 的 `benchmark bench` 也把 `app` 列進 `hs-source-dirs`,故實際會有三個 owner → 採取:照規則 2「全列」列出三者(驗收標準用「含」字,三者含前兩者,判定為通過)→ 影響:若編排者認為驗收標準是「恰好兩個」,須改的是契約卡文字而非實作

## 實作備註

(撰寫時留空)
