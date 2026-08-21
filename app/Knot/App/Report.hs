-- | knot 執行檔內部模組:五條上游警告/報告通道 → stderr 行(F004 cli-wiring)。
--
-- 四個子系統一律__不印任何輸出__(委派決策 D8),警告收在各自的 DTO 欄位裡等
-- CLI 取走;本模組把它們收成統一的行清單,'emitNotes' 是整條管線__唯一__的
-- 列印函式。
--
-- 五條通道與其「非印不可」的出處:
--
-- * 'metaNoteLines' ← @pmWarnings@("Knot.Meta.Types" haddock:「由呼叫端印到 stderr」)
-- * 'extractNoteLines' ← @erLevel@ \/ @erReports@ \/ @erWarnings@
--   ("Knot.Graph" haddock:「由 CLI 印 stderr,graph-core 不轉載」;ADR-002 的降級告知)
-- * 'graphNoteLines' ← @cgWarnings@(__硬性要求__:'Knot.Export.writeCodegraph'
--   完全不碰它,漏接的話同名 module 碰撞警告永遠不會被使用者看到)
-- * 'exportNoteLines' ← @xrNotes@("Knot.Export.Types" haddock:「由 CLI 層列印」)
-- * 'queryNoteLines' ← 'Knot.Query.queryGraphNotes'(查詢規則 2:未知 relation 不靜默吞掉)
--
-- 行渲染全部是純函數,__空輸入回 @[]@__(不產生噪音行);
-- 行文沿用專案既有慣例(英文小寫、'T.pack' 不依賴 @OverloadedStrings@)。
module Knot.App.Report
  ( -- * 五條通道的行渲染(純函數)
    metaNoteLines
  , extractNoteLines
  , graphNoteLines
  , exportNoteLines
  , queryNoteLines
    -- * 唯一的列印函式
  , emitNotes
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (Handle)

import Knot.Export.Types (ExportReport (..))
import Knot.Extract.Types
  ( BackendReport (..)
  , ExtractResult (..)
  , ExtractWarning (..)
  )
import Knot.Graph.Types (CodeGraph (..), GraphWarning (..))
import Knot.Meta.Types (MetaWarning (..), ProjectMeta (..))
import Knot.Query (QueryGraph, queryGraphNotes)

-- | 通道 1:@pmWarnings@ → @meta: \<mwPath\>: \<mwMessage\>@。
metaNoteLines :: ProjectMeta -> [Text]
metaNoteLines pm =
  [ T.concat [T.pack "meta: ", T.pack (mwPath w), T.pack ": ", mwMessage w]
  | w <- pmWarnings pm
  ]

-- | 通道 2:@erLevel@ \/ @erReports@ \/ @erWarnings@。
--
-- @extract: level \<erLevel\>@ 是本通道的__標頭行__:只在通道有話說時輸出
-- (降級報告或警告非空),讓「無事發生」的預設路徑維持零噪音——與其餘四條
-- 通道「空輸入回 @[]@」的規則一致。@brUsed = True@ 的報告不產生行。
extractNoteLines :: ExtractResult -> [Text]
extractNoteLines er
  | null degradeLines && null warningLines = []
  | otherwise = levelLine : degradeLines <> warningLines
 where
  levelLine = T.pack ("extract: level " <> show (erLevel er))
  degradeLines =
    [ T.concat
        [T.pack "extract: backend ", brBackend r, T.pack " unused: ", brDetail r]
    | r <- erReports er
    , not (brUsed r)
    ]
  warningLines =
    [ T.concat [T.pack "extract: ", ewSource w, T.pack ": ", ewMessage w]
    | w <- erWarnings er
    ]

-- | 通道 3(__硬性要求__):@cgWarnings@ → @graph: \<gwSource\>: \<gwMessage\>@。
--
-- 'Knot.Export.writeCodegraph' 只轉載 @cgStats@,完全不碰 @cgWarnings@
-- (F001 假設 A3 的閘門裁決),因此本層是這條通道__唯一__的出口。
graphNoteLines :: CodeGraph -> [Text]
graphNoteLines g =
  [ T.concat [T.pack "graph: ", gwSource w, T.pack ": ", gwMessage w]
  | w <- cgWarnings g
  ]

-- | 通道 4:@xrNotes@ → @export: \<note\>@(@note@ 已是完整摘要行)。
exportNoteLines :: ExportReport -> [Text]
exportNoteLines rep = [T.pack "export: " <> n | n <- xrNotes rep]

-- | 通道 5:未知 relation 統計 → @query: unknown relation "\<rel\>": \<n\> edges@。
queryNoteLines :: QueryGraph -> [Text]
queryNoteLines g =
  [ T.concat
      [ T.pack "query: unknown relation \""
      , rel
      , T.pack "\": "
      , T.pack (show n)
      , T.pack " edges"
      ]
  | (rel, n) <- queryGraphNotes g
  ]

-- | 唯一的列印函式;空清單__不寫任何 byte__,每行以 @\\n@ 結尾。
emitNotes :: Handle -> [Text] -> IO ()
emitNotes h = mapM_ (\l -> TIO.hPutStr h (l <> T.pack "\n"))
