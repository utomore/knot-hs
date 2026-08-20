-- | graph-core 內部模組 fact-gate:事實驗證與過濾。
--
-- Level 2 契約:@.design/subsystems/graph-core/design.md@「模組間公開介面」。
--
-- 階段一(F001)語意:只建立內部 module 集合(委派決策 D2)。組裝規則 3
-- (產生碼過濾)屬階段二 @F002@ decl-nodes,故 @gfFiltered@ 恆為 0、
-- 'ProjectMeta' 參數本階段不被讀取——這是階段性狀態,不是遺漏(假設 A6)。
module Knot.Graph.FactGate
  ( gateFacts
  , GatedFacts (..)
  ) where

import Data.Set (Set)
import qualified Data.Set as Set

import Knot.Extract.Types (Fact (..))
import Knot.Meta.Types (ModuleName, ProjectMeta)

data GatedFacts = GatedFacts
  { gfFacts    :: [Fact]          -- ^ 通過過濾的事實
  , gfInternal :: Set ModuleName  -- ^ 內部 module 集合(內外部判定的依據)
  , gfFiltered :: Int             -- ^ 濾除量(進 @gsFilteredGenerated@)
  }
  deriving (Eq, Show)

-- | 內部集合 = 事實流中所有 @FactModule@ 的 @fmModule@(D2:與節點來源同一
-- 樣本,**不是** @pmSources@ 的 @sfModule@)。
--
-- 非 module 層事實(@FactDecl@ / @FactRef@ / @FactInstance@)原樣通過,由
-- 下游模組各自忽略——契約卡要求「忽略之但不 crash」,故此處不得 pattern
-- match 失敗。
gateFacts :: ProjectMeta -> [Fact] -> GatedFacts
gateFacts _pm facts = GatedFacts
  { gfFacts    = facts
  , gfInternal = Set.fromList [m | FactModule{fmModule = m} <- facts]
  , gfFiltered = 0
  }
