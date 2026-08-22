-- | extraction 子系統對外契約進入點。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「對外契約」。
module Knot.Extract
  ( extract
  ) where

import Knot.Extract.BuildDriver (ensureHie)
import Knot.Extract.HieIndex (IndexHandle, ensureIndex)
import Knot.Extract.HiedbFacts (readIndexFacts)
import Knot.Extract.ImportScan (scanImports)
import Knot.Extract.Pipeline (Stages (..), runPipeline)
import Knot.Extract.Types (ExtractFailure, ExtractOptions, ExtractResult)
import Knot.Meta.Types (ProjectMeta)

-- | 固定四站、全有全無(ADR-006、F007):import-scan 的 module 層與
-- hie-index + hie-facts 的 decl 層__都成立__才回 @Right@;任一層整體拿不到
-- 回 @Left@,不產出部分事實流。沒有後端選擇、沒有降級。
extract :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)
extract = runPipeline realStages

-- | 真實四站。屬 fact-pipeline 的內部接線,不匯出。
realStages :: Stages IndexHandle
realStages = Stages
  { stScan  = scanImports
  , stBuild = ensureHie
  , stIndex = ensureIndex
  , stFacts = readIndexFacts
  }
