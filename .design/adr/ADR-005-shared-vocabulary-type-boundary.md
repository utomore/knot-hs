---
id: ADR-005
type: adr
title: shared-vocabulary-type-boundary
description: 公開契約 DTO 透出上游詞彙型別的兩條判準
status: accepted
created: 2026-08-22
updated: 2026-08-22
---

# ADR-005: 共用詞彙型別在公開契約 DTO 的邊界判準

## 狀態(Status)

accepted(2026-08-22)

## 背景(Context)

`ModuleName`、`DeclKind` 這類**詞彙型別**由管線上游的子系統定義,沿管線流動、
零轉換(extraction Level 2 的批次澄清裁定)。問題不在型別本身,而在**它出現在
別人的公開契約 DTO 裡**時,消費端會被迫去認識一個本來不該認識的子系統。

G-E001 修掉了一個實例:graph-core 的 `GraphStats.gsTopExternalTargets ::
[(ModuleName, Int)]` 讓 export-query 的 library 直接 import `Knot.Meta.Types`
——export-query 對 project-meta 沒有任何宣告過的依賴。當時寫進 `system.md` 的
規則是「公開契約 DTO **不得透出**上游詞彙型別」。

2026-08-22 的 `/arch-audit system` 發現那條規則**寫得比專案自己的設計決定還嚴**,
現行程式碼有兩處刻意違反它:

| 位置 | 透出 | 來源 |
|---|---|---|
| `src/Knot/Extract/Types.hs:58,80,82,91`(`QualName.qnModule`、`Fact*` 欄位) | `ModuleName` | project-meta |
| `src/Knot/Graph/Types.hs:61`(`NodeKind = … DeclNode DeclKind …`) | `DeclKind` | extraction |

兩者都是事實流沿管線流動的正常型態,不該被判違規。規則需要重寫成能區分
「正常流動」與「`GraphStats` 那一類」的可執行判準。

**同一次檢測還修正了拓撲宣告**:`project-meta` 其實同時餵給 extraction 與
graph-core(`buildGraph` 的參數含 `ProjectMeta`,是 graph-core 的 Level 2 契約
進入點),原本宣告的線性鏈少畫了一條邊。這件事直接影響本 ADR 的選項評估。

## 決策(Decision)

公開契約 DTO 透出上游詞彙型別時,**兩條判準同時成立才合格**:

1. **只能透出你真的依賴的人** —— 僅限 `system.md`「通訊拓撲」表中,本子系統
   確實有邊指向的那些子系統之詞彙型別。透出沒有邊的子系統之型別,等於逼消費端
   替你建一條旁路。
2. **報告 / 統計欄位一律不得使用上游詞彙型別** —— 那種欄位裝的是**外部世界的
   資料**(被丟棄的第三方 module 名之類),不是沿管線流動的值;包成上游型別換不到
   任何型別安全,只會讓消費端為了拆包多認識一個型別。

附帶義務:**詞彙型別的擁有者要 re-export 它**,消費端才不必為了「命名一個從契約
收到的型別」而繞回源頭。

## 考慮過的替代方案(Alternatives Considered)

### 只用判準 1(依實際依賴關係)

**否決,而且是本 ADR 最關鍵的一點。** 拓撲修正把 `project-meta → graph-core`
補成真實存在的邊之後,project-meta 對 graph-core 就是**合法的相鄰上游**——單看
依賴關係,`GraphStats` 透出 `ModuleName` 反而變成合規,等於追認 G-E001 那項修正
是不必要的。

判準 1 擋得住「未來冒出的旁路」,擋不住「沿著合法的邊透出不該透出的東西」。

### 只用判準 2(報告欄位規則)

否決。它解釋得了 `GraphStats`,但擋不住未來有人在**非**報告欄位透出跨段型別
——例如 export-query 的 `ExportReport` 若出現 `ModuleName`,判準 2 放行,而
export-query 對 project-meta 並沒有邊,那就是一條真旁路。

### 維持原規則(公開 DTO 一律不得透出)

否決。它會判 `QualName.qnModule` 與 `NodeKind` 違規,而這兩者正是
extraction Level 2 明文裁定的「同一型別沿管線流動,零轉換」。規則不該譴責專案
自己刻意做出的設計決定;真要執行,代價是沿管線每一站都要為同一個概念再定義一次
型別並加轉換層。

## 影響(Consequences)

**得到**

- 判準可執行:`/arch-audit system` 能逐條比對「這個 DTO 透出的型別,來源子系統
  在拓撲表上有沒有邊」,不必再靠語感
- 現行程式碼全數通過,不需要為了迎合規則而改動任何既有契約
- 拓撲表升格為判準的一部分——它一旦漏畫邊,判準 1 會跟著失準,這給了拓撲表
  持續正確的壓力

**付出**

- 兩條判準都要查,比單一條規則麻煩
- 「什麼算報告 / 統計欄位」有灰帶(目前的判別法:欄位裝的是外部世界的資料,
  還是沿管線流動的值)

**附帶義務的正確範圍(2026-08-22 複核修正)**

本 ADR 初版在此列了一條待辦,說 `Knot.Extract.Types` 「依附帶義務應補上
re-export」。**那句把義務講得比規則本身寬**,更正如下:

- 附帶義務落在**擁有者**——`ModuleName` 由 project-meta 定義,而 `Knot.Meta.Types`
  本來就匯出它,義務已履行
- extraction 只是**傳遞**這個型別(契約 DTO 的四個欄位用到它)。它跟著 re-export
  屬於**便利改善**,不是本 ADR 要求的事
- 同理,`src/Knot/Graph/EdgeDerive.hs` 與 `src/Knot/Graph/NodeMint.hs` 原本自己
  import `Knot.Meta.Types` 也**不違規**:graph-core → project-meta 是 `system.md`
  拓撲表的邊 2,判準 1 放行

那項傳遞型 re-export 已由 **G-E004** 完成(兩處 import 隨之消失),但它的依據是
人體工學,不是本 ADR。

## 相關

- G-E001(修掉 `GraphStats` 的實例,並促成原規則入檔)
- ADR-003(`codegraph.json` 是唯一對外契約——本 ADR 管的是**內部**子系統之間)
- `.design/subsystems/extraction/design.md`「同一型別沿管線流動,零轉換」的裁定
