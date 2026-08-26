-- | knot 執行檔內部模組:五條上游警告/報告通道 → stderr 行(F004 cli-wiring)。
--
-- 四個子系統一律__不印任何輸出__(委派決策 D8),警告收在各自的 DTO 欄位裡等
-- CLI 取走;本模組把它們收成統一的行清單,'emitNotes' 是整條管線__唯一__的
-- 列印函式。
--
-- 五條通道與其「非印不可」的出處:
--
-- * 'metaNoteLines' ← @pmWarnings@("Knot.Meta.Types" haddock:「由呼叫端印到 stderr」)
-- * 'extractNoteLines' ← @erWarnings@("Knot.Graph" haddock:「由 CLI 印
--   stderr,graph-core 不轉載」);'extractFailureLines' ← @Left ExtractFailure@
--   (ADR-006:整體失敗 exit 1,不寫檔)
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
  , extractFailureLines
  , graphNoteLines
  , exportNoteLines
  , queryNoteLines
  , freshnessNoteLines   -- G-E008
    -- * 唯一的列印函式
  , emitNotes
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.IO (Handle)

import Knot.Export.Types (ExportReport (..))
import Knot.Extract.Types
  ( ExtractFailure (..)
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

-- | 通道 2:@erWarnings@ → @extract: \<ewSource\>: \<ewMessage\>@;空輸入回 @[]@。
--
-- S5 起沒有能力等級標頭行、沒有降級報告行——extraction 兩層全有全無,
-- 能走到這裡就是兩層都成立,剩下的只有各站的單檔警告。
extractNoteLines :: ExtractResult -> [Text]
extractNoteLines er =
  [ T.concat [T.pack "extract: ", ewSource w, T.pack ": ", ewMessage w]
  | w <- erWarnings er
  ]

-- | 整體失敗(ADR-006)→ stderr 行。四個建構子各自可辨識;永遠非空。
--
-- 'BuildFailed' 的 @bfDetail@ 可能多行:逐行縮排列印,不截斷——cabal 的輸出
-- 雖已由 build-driver 即時轉發,尾段重印一次讓失敗原因緊貼在 exit 之前。
-- 'VersionMismatch' 附上修法原文 @cabal install knot-hs -w ghc-\<vmHie\>@。
extractFailureLines :: ExtractFailure -> [Text]
extractFailureLines failure = case failure of
  BuildFailed c d ->
    (T.pack "extract: build failed for " <> c)
      : [ T.pack "extract:   " <> l | l <- T.lines d ]
  VersionMismatch h k ->
    [ T.concat
        [ T.pack "extract: .hie files were produced by GHC ", h
        , T.pack ", but this knot was built with GHC ", k ]
    , T.pack "extract: install a matching knot: cabal install knot-hs -w ghc-" <> h
    ]
  IndexFailed d ->
    [T.pack "extract: index failed: " <> d]
  NoSources ->
    [T.pack "extract: no Haskell sources in scope (check PATH and --include-tests)"]

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

-- | 通道 6(G-E008):圖的新鮮度 → 最多__一行__提示;新鮮或無從判斷時回 @[]@。
--
-- 三個參數依序是:圖記錄的 commit('Knot.Query.queryGraphCommit')、目標專案
-- 當前的 HEAD('Knot.Export.detectCommit')、工作區是否有未提交的 @.hs@ 改動
-- ('Knot.Export.detectDirtySources')。
--
-- 判定與文案(逐字,law L2\/L3\/L4):
--
-- * 兩個 commit 都有值且__不同__ →
--   @query: graph is stale: built at \<圖 commit 前 12 碼\>, HEAD is \<HEAD 前 12 碼\>; rerun knot extract@
-- * 兩個 commit 相同、但有未提交的 @.hs@ 改動 →
--   @query: graph may be stale: uncommitted Haskell changes since it was built; rerun knot extract@
-- * 其餘(相同且乾淨、圖沒記 commit、HEAD 偵測不到)→ @[]@
--
-- 兩種情形__不會同時出現__:commit 已經不同時,髒不髒不影響結論。
-- sha 一律取前 12 個字元(不足 12 就原樣)——@built_at_commit@ 是圖檔裡的字串,
-- 本函式不驗證它是不是合法 sha。
--
-- __不影響 exit code__:圖不新鮮是提示不是錯誤,'Knot.App.Run.runQueryCmd' 的
-- 回傳值不因本通道改變(law R4)。
freshnessNoteLines :: Maybe Text -> Maybe Text -> Bool -> [Text]
freshnessNoteLines mGraphCommit mHead dirty = case (mGraphCommit, mHead) of
  (Just g, Just h)
    | g /= h ->
        [ T.concat
            [ T.pack "query: graph is stale: built at ", shortSha g
            , T.pack ", HEAD is ", shortSha h
            , T.pack "; rerun knot extract"
            ]
        ]
    | dirty ->
        [ T.pack
            "query: graph may be stale: uncommitted Haskell changes since it was built; rerun knot extract"
        ]
    | otherwise -> []
  _ -> []
 where
  shortSha = T.take 12

-- | 唯一的列印函式;空清單__不寫任何 byte__,每行以 @\\n@ 結尾。
emitNotes :: Handle -> [Text] -> IO ()
emitNotes h = mapM_ (\l -> TIO.hPutStr h (l <> T.pack "\n"))
