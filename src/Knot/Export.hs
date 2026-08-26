-- | export-query 子系統匯出面的唯一對外進入點(內部模組 export-writer)。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 匯出面」。
--
-- 管線:commit 偵測 → 投影(規則 1–5)→ 建父目錄 → 寫檔 → 'ExportReport'。
-- 不建圖、不改圖、不讀 JSON、全程不印任何輸出(委派決策 D8)。
-- G-E008 起本模組多兩條契約:'detectCommit' 與 'detectDirtySources'。它們原本是
-- export-writer 的內部細節,提升為對外契約的理由只有一個——「怎麼問 git 專案的
-- 現況」這個知識只能有一處,而 @knot query@ 的新鮮度提示在 executable 裡,
-- exe 只依賴公開 library(ADR-004),import 不到 "Knot.Export.Commit"。
module Knot.Export
  ( writeCodegraph
    -- * 目標專案的 git 現況(G-E008)
  , detectCommit
  , detectDirtySources
  ) where

import qualified Data.ByteString.Builder as BB
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import Knot.Export.Commit (detectCommit, detectDirtySources)
import Knot.Export.Encode (encodeCodegraph, statsNotes)
import Knot.Export.Types
  ( ExportOptions (..)
  , ExportReport (..)
  )
import Knot.Graph.Types (CodeGraph (..))

-- | 把 'CodeGraph' 投影成 @codegraph.json@ 寫到 @outputPath@,回傳匯出摘要。
--
-- @outputPath@ 是權威值(不做 fallback,見假設 A2);父目錄不存在時會建出來。
-- 寫檔走 'BB.writeFile'(binary 語意),Windows 上 @\\n@ 不會被轉成 @\\r\\n@
-- ——投影規則 5「byte 級決定性」的必要條件。
--
-- 錯誤處理:寫檔失敗(權限、路徑非法)讓 'IOException' 原樣往上拋——匯出是
-- @knot extract@ 的終點產物,寫不出來就沒有「部分成功」可言,由 F004 的 CLI
-- 層決定 exit code 與訊息。commit 偵測是唯一被吞掉例外的地方(契約明文要求
-- 「失敗則省略欄位不警告」)。
writeCodegraph :: ExportOptions -> CodeGraph -> IO ExportReport
writeCodegraph opts graph = do
  mCommit <- detectCommit (commitPolicy opts) (rootDir opts)
  let out = outputPath opts
  createDirectoryIfMissing True (takeDirectory out)
  BB.writeFile out (encodeCodegraph mCommit graph)
  pure ExportReport
    { xrPath      = out
    , xrNodeCount = length (cgNodes graph)
    , xrEdgeCount = length (cgEdges graph)
    , xrNotes     = statsNotes (cgStats graph)
    }
