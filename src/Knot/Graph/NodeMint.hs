-- | graph-core 內部模組 node-mint:節點 id 鑄造與 'GraphNode' 建構。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「模組間公開介面」
-- 與「節點 id 鑄造規則」。'NodeId' 的唯一構造入口。
--
-- F002 起鑄造規則表**全表**到位:module 列(F001)、值/型別宣告列
-- ('mintDeclId')、instance 列('mintInstanceId')。
module Knot.Graph.NodeMint
  ( -- * 契約面(鑄造規則表)
    mintModuleId
  , mintDeclId
  , mintInstanceId
  , mintNodes
    -- * 非契約面(供 graph-assemble 彙整碰撞警告、edge-derive 解析端點與 1-to-1 測試)
  , moduleFiles
  , disambiguate
  , moduleOfFile
  , declNodeIndex
  ) where

import Data.Containers.ListUtils (nubOrd, nubOrdOn)
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Extract.Types (Fact (..), ModuleName (..), NameSpace (..), QualName (..))
import Knot.Graph.FactGate (GatedFacts (..))
import Knot.Graph.Types (GraphNode (..), NodeId (..), NodeKind (..))

-- | module 節點 id 鑄造(A2 裁決的契約簽名)。
--
-- @Nothing@ = 該 module 名未碰撞,鑄裸名;@Just file@ = 碰撞組成員,鑄
-- @\<module\>\@\<source_file\>@(@file@ 為 @fmFile@ 原文:repo 相對、正斜線)。
mintModuleId :: ModuleName -> Maybe FilePath -> NodeId
mintModuleId (ModuleName m) Nothing     = NodeId m
mintModuleId (ModuleName m) (Just file) = NodeId (m <> T.pack "@" <> T.pack file)

-- | decl 節點 id 鑄造(C3 裁決的契約簽名)。
--
-- @Maybe FilePath@ 語意同 'mintModuleId':@Nothing@ = 該 module 未碰撞、
-- 鑄裸名;@Just file@ = 碰撞組成員。以 'mintModuleId' 為基底,**結構性
-- 保證**「decl 層沿用所屬 module 的消歧結果」。
--
-- @TypeNs@ 加 @\"#t\"@ 後綴,其餘三個 term-level namespace
-- (@ValueNs@ / @DataConNs@ / @FieldNs@)無後綴(批次澄清 C2)——故
-- @data Foo = Foo@ 鑄出的 @Demo.Core.Foo#t@ 與 @Demo.Core.Foo@ 不碰撞。
mintDeclId :: QualName -> Maybe FilePath -> NodeId
mintDeclId q mf = NodeId (modText <> T.pack "." <> qnOcc q <> suffix)
 where
  NodeId modText = mintModuleId (qnModule q) mf
  suffix = case qnSpace q of
    TypeNs    -> T.pack "#t"
    ValueNs   -> T.empty
    DataConNs -> T.empty
    FieldNs   -> T.empty

-- | instance 節點 id 鑄造(C3 裁決的契約簽名)。
--
-- 第一參數是 instance **宣告所在**的 module(由 @fiInstFile@ 反查
-- 'moduleOfFile' 取得,A3 裁決;**不是** @qnModule fiClass@,後者是 class
-- 定義處的 module);第三參數是渲染後的 instance 標頭(@fiInstHead@ 原文)。
mintInstanceId :: ModuleName -> Maybe FilePath -> Text -> NodeId
mintInstanceId m mf hd = NodeId (modText <> T.pack "#i:" <> hd)
 where
  NodeId modText = mintModuleId m mf

-- | 委派決策 D1 的判定面:module 名 → 宣告它的相異來源檔集合。
-- 集合大小 > 1 即碰撞組(該組全部改用消歧形式)。
moduleFiles :: [Fact] -> Map ModuleName (Set FilePath)
moduleFiles facts = Map.fromListWith Set.union
  [(m, Set.singleton file) | FactModule{fmModule = m, fmFile = file} <- facts]

-- | 非契約面:D1 消歧判定。碰撞組成員回 @Just file@、未碰撞回 @Nothing@。
-- 由 F001 'mintNodes' 的內部 where 子句提升為可共用函式,語意一字不變。
disambiguate :: Map ModuleName (Set FilePath) -> ModuleName -> FilePath -> Maybe FilePath
disambiguate files m file
  | maybe False ((> 1) . Set.size) (Map.lookup m files) = Just file
  | otherwise                                           = Nothing

-- | 非契約面:檔案 → 該檔宣告的 module。
--
-- @FactInstance@ 沒有 module 欄位,instance 節點的所屬 module 只能由
-- @fiInstFile@ 反查(A3 裁決)。
-- 同一檔宣告多個 module 名的病態輸入取字典序最小者,使結果不隨事實序改變
-- (規則 7)。
moduleOfFile :: [Fact] -> Map FilePath ModuleName
moduleOfFile facts = Map.fromListWith min
  [(file, m) | FactModule{fmFile = file, fmModule = m} <- facts]

-- | 非契約面:decl 節點索引,供 edge-derive 把「只有 'QualName'、沒有檔案
-- 線索」的端點換成 'NodeId'('GraphNode' 的五個欄位還原不出
-- @(module, occ, namespace)@:同檔的 @Foo#t@ 與 @Foo@ 兩個節點的 'gnLabel'
-- 都是 @Foo@)。
--
-- 由與 'mintNodes' 相同的輸入建立,且**只收真的鑄出來的節點**(候選 id
-- 必須落在傳入的節點集合裡),故「查得到 ⇒ 節點存在」,不會產出懸空端點。
--
-- D1 消歧組下同一個 'QualName' 對到多個節點,故值為清單;附帶的
-- 'FilePath' 是該節點的來源檔,供有檔案線索的一端收斂到唯一節點。
-- 值清單依 @(FilePath, NodeId)@ 排序(規則 7 決定性)。
declNodeIndex :: GatedFacts -> [GraphNode] -> Map QualName [(FilePath, NodeId)]
declNodeIndex gated nodes = Map.map (nubOrd . sort) (Map.fromListWith (++) entries)
 where
  facts   = gfFacts gated
  files   = moduleFiles facts
  nodeIds = Set.fromList (map gnId nodes)
  entries =
    [ (q, [(file, declId)])
    | FactDecl{fdName = q, fdFile = file} <- facts
    , let declId = mintDeclId q (disambiguate files (qnModule q) file)
    , declId `Set.member` nodeIds
    ]

-- | 事實流 → 節點集合(組裝規則 2 的節點列)。
--
-- 三種節點:@FactModule@ → module 節點(F001,邏輯一字不改)、
-- @FactDecl@ → decl 節點、@FactInstance@ → instance 節點。
--
-- 規則 1(內部才實化)的落實:decl / instance 只在其所屬 module ∈
-- 'gfInternal' **且**該 module 節點確實鑄得出來(存在性守門)時才建節點——
-- 沒有守門的話,「檔案不屬於該 module 任何 @fmFile@」的病態輸入會鑄出
-- 孤兒節點,`RContains` 就會有懸空端點。
--
-- 消歧只反映在 'gnId','gnLabel' 維持人類可讀名(module 名 / occ 名 /
-- instance 標頭;假設 A5)。最後對**全部**節點依 'gnId' 去重:
-- @DuplicateRecordFields@ 下同 module 兩個同名欄位選擇器會在此靜默合併
-- (繼承 extraction 假設 A9 的精度限制,graph-core 不補救;F002 假設 A9)。
--
-- node-mint 沒有警告通道(契約簽名只回 @[GraphNode]@),故跳過某筆事實在
-- 此一律靜默;警告由 edge-derive 以同一組判定發出(F002 假設 A7)。
mintNodes :: GatedFacts -> [GraphNode]
mintNodes gated = dedupeNodes (modNodes <> declNodes <> instNodes)
 where
  facts    = gfFacts gated
  files    = moduleFiles facts
  fileMods = moduleOfFile facts
  internal = gfInternal gated

  modNodes = [mkModNode m file | FactModule{fmModule = m, fmFile = file} <- facts]
  modIds   = Set.fromList (map gnId modNodes)

  mkModNode m file = GraphNode
    { gnId    = mintModuleId m (disambiguate files m file)
    , gnKind  = ModuleNode
    , gnLabel = moduleText m
    , gnFile  = file
    , gnLine  = Nothing
    }

  declNodes =
    [ GraphNode
        { gnId    = mintDeclId q disamb
        , gnKind  = DeclNode k
        , gnLabel = qnOcc q
        , gnFile  = file
        , gnLine  = Just ln
        }
    | FactDecl{fdName = q, fdKind = k, fdFile = file, fdLine = ln} <- facts
    , qnModule q `Set.member` internal
    , let disamb = disambiguate files (qnModule q) file
    , mintModuleId (qnModule q) disamb `Set.member` modIds
    ]

  instNodes =
    [ GraphNode
        { gnId    = mintInstanceId m disamb hd
        , gnKind  = InstanceNode
        , gnLabel = hd
        , gnFile  = file
        , gnLine  = Just ln
        }
    | FactInstance{fiInstHead = hd, fiInstFile = file, fiInstLine = ln} <- facts
    , Just m <- [Map.lookup file fileMods]
    , m `Set.member` internal
    , let disamb = disambiguate files m file
    , mintModuleId m disamb `Set.member` modIds
    ]

  moduleText (ModuleName t) = t

-- | 依 'gnId' 合併節點(組裝規則 5 的節點面 + 規則 7)。
--
-- 同 id 的多個候選保留 @(gnFile, gnLine, gnKind)@ **最小**者——與 edge-derive
-- 對 'geLine' 取極小值同一理由:取「輸入序第一筆」會讓同一份事實流換個順序
-- 就鑄出不同的 'gnLine',違反決定性。輸出序為各 id 的首次出現序
-- (@buildGraph@ 隨後會依 'gnId' 全序排序)。
dedupeNodes :: [GraphNode] -> [GraphNode]
dedupeNodes ns = map pick (nubOrdOn gnId ns)
 where
  best = Map.fromListWith smaller [(gnId n, n) | n <- ns]
  smaller a b
    | nodeKey a <= nodeKey b = a
    | otherwise              = b
  nodeKey n = (gnFile n, gnLine n, gnKind n)
  pick n = Map.findWithDefault n (gnId n) best
