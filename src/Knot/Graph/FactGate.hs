-- | graph-core 內部模組 fact-gate:事實驗證與過濾。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「模組間公開介面」。
--
-- 職責兩件:建立內部 module 集合(委派決策 D2)、落實組裝規則 3(產生碼
-- 過濾,F002 批次澄清 C4 的三條件)。
module Knot.Graph.FactGate
  ( gateFacts
  , GatedFacts (..)
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Extract.Types (Fact (..))
import Knot.Meta.Types (ComponentRef (..), ModuleName, ProjectMeta (..), SourceFile (..))

data GatedFacts = GatedFacts
  { gfFacts    :: [Fact]          -- ^ 通過過濾的事實
  , gfInternal :: Set ModuleName  -- ^ 內部 module 集合(內外部判定的依據)
  , gfFiltered :: Int             -- ^ 濾除量(進 @gsFilteredGenerated@)
  , gfOwners   :: Map FilePath Text
    -- ^ G-E007:檔案 → @\<pkgName\>:\<compName\>@(@sfOwners@ 的__第一個__;
    -- project-meta 的序是 library → exe → flib → test → bench,故產品優先)。
    -- 無 owner 的檔不在表內
  }
  deriving (Eq, Show)

-- | 內部集合 = 事實流中所有 @FactModule@ 的 @fmModule@(D2:與節點來源同一
-- 樣本,**不是** @pmSources@ 的 @sfModule@)。
--
-- 組裝規則 3(產生碼過濾,C4 + G-E003)五條件任一成立即濾除該筆事實並計入
-- 'gfFiltered':(a) 事實指向的檔案不在 @pmSources@;(b) 行號 ≤ 0;
-- (c) @FactRef.frGenerated = True@(引用__站點__是產生碼);
-- (d) @FactDecl.fdGenerated = True@(宣告__本身__是產生碼);
-- (e) @FactRef.frTargetGenerated = True@(引用__目標__是產生碼宣告)。
--
-- (d) 與 (e) 由 G-E003 補上,解掉「只擋 ref 不擋 decl」的不對稱:deriving
-- 字典既不該成為節點((d)),指向它的引用也不該留下懸空目標((e))——後者
-- 同時消掉 @unresolved reference target $f…@ 這一類警告,因為事實在
-- edge-derive 看到它之前就已經不在了。五條件**只適用 decl 層事實**
-- (@FactDecl@ / @FactRef@ / @FactInstance@);@FactModule@ / @FactImport@
-- 一律不受影響(F002 假設 A1:濾掉 @FactModule@ 會讓 'gfInternal' 縮水、
-- module 節點連帶消失)。
--
-- (a) 用**字串完全相等**比對:@fdFile@ / @frFile@ / @fiInstFile@ 與
-- @sfPath@ 都是 repo 相對、正斜線的原文(extraction @resolveModuleSource@
-- 回傳 @sfPath@ 原文),加正規化反而會掩蓋真正的不一致。比對母體是
-- @pmSources@ **全部**條目,不限 @sfIncluded = True@(F002 假設 A2)。
--
-- 'gfFiltered' 是「濾掉的事實筆數」,不是條件命中次數:一筆同時違反兩個
-- 條件只算一次。
gateFacts :: ProjectMeta -> [Fact] -> GatedFacts
gateFacts pm facts = GatedFacts
  { gfFacts    = kept
  , gfInternal = Set.fromList [m | FactModule{fmModule = m} <- kept]
  , gfFiltered = length facts - length kept
  , gfOwners   = Map.fromList
      [ (sfPath sf, ownerLabel r) | sf <- pmSources pm, (r : _) <- [sfOwners sf] ]
  }
 where
  srcSet = Set.fromList [sfPath sf | sf <- pmSources pm]
  ownerLabel (ComponentRef (pkg, comp)) = pkg <> T.pack ":" <> comp
  kept   = filter (not . filteredOut) facts

  filteredOut :: Fact -> Bool
  filteredOut FactModule{} = False
  filteredOut FactImport{} = False
  filteredOut FactDecl{fdFile = file, fdLine = ln, fdGenerated = gen} =
    file `Set.notMember` srcSet || ln <= 0 || gen
  filteredOut FactRef{ frFile = file, frLine = ln
                     , frGenerated = gen, frTargetGenerated = tgtGen } =
    file `Set.notMember` srcSet || ln <= 0 || gen || tgtGen
  filteredOut FactInstance{fiInstFile = file, fiInstLine = ln} =
    file `Set.notMember` srcSet || ln <= 0
