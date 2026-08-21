-- | knot 執行檔內部模組:管線組裝與 exit code 決定(F004 cli-wiring)。
--
-- 匯出面依 @project-meta → extraction → graph-core → export-query@ 單向串接
-- (system.md 通訊拓撲),且__只跑到需要的那一站__:@--summary meta@ 不呼叫
-- 'extract'、@--summary facts@ 不呼叫 'buildGraph'。
--
-- 兩個 'Handle' 由呼叫端注入('Main' 給 @stdout@ \/ @stderr@,測試給暫存檔):
-- 這是「@cgWarnings@ 真的走到 stderr」這條硬性要求可被端到端測到的關鍵。
--
-- 錯誤策略在此交會:匯出面 best-effort(有警告仍 exit 0,@--strict@ 改 1)、
-- 查詢面 fail-fast('LoadError' 直接 exit 1),而__查無結果 exit 0__。
module Knot.App.Run
  ( runCommand
  , runExtractCmd
  , runQueryCmd
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (ExitCode (..))
import System.IO (Handle)

import Knot.App.Cli
  ( Command (..)
  , ExtractCmd (..)
  , QueryCmd (..)
  , SummaryMode (..)
  , toBuildOptions
  , toExportOptions
  , toExtractOptions
  , toMetaOptions
  )
import Knot.App.Report
  ( emitNotes
  , exportNoteLines
  , extractNoteLines
  , graphNoteLines
  , metaNoteLines
  , queryNoteLines
  )
import Knot.App.Summary (renderFactSummary, renderGraphSummary, renderMetaSummary)
import Knot.Export (writeCodegraph)
import Knot.Export.Types (ExportReport (..))
import Knot.Extract (extract)
import Knot.Extract.Types (ExtractResult (..))
import Knot.Graph (buildGraph)
import Knot.Graph.Types (CodeGraph (..))
import Knot.Meta (loadProjectMeta)
import Knot.Meta.Types (ProjectMeta (..))
import Knot.Query
  ( LoadError (..)
  , NodeId (..)
  , QueryCommand (..)
  , QueryGraph
  , loadQueryGraph
  , queryGraphHasNode
  , renderResult
  , runQuery
  )

-- | 依 'Command' 分派。
runCommand :: Handle -> Handle -> Command -> IO ExitCode
runCommand hOut hErr cmd = case cmd of
  CmdExtract c -> runExtractCmd hOut hErr c
  CmdQuery   c -> runQueryCmd hOut hErr c

--------------------------------------------------------------------------------
-- extract
--------------------------------------------------------------------------------

-- | 四站管線;@--summary@ 三條路徑各在自己那一站收工。
runExtractCmd :: Handle -> Handle -> ExtractCmd -> IO ExitCode
runExtractCmd hOut hErr cmd = do
  pm <- loadProjectMeta (toMetaOptions cmd)
  emitNotes hErr (metaNoteLines pm)
  let nMeta = length (pmWarnings pm)
  case ecSummary cmd of
    Just SummaryMeta -> do
      TIO.hPutStr hOut (renderMetaSummary pm)
      finish nMeta
    _ -> do
      er <- extract (toExtractOptions cmd) pm
      emitNotes hErr (extractNoteLines er)
      let nExtract = nMeta + length (erWarnings er)
      case ecSummary cmd of
        Just SummaryFacts -> do
          TIO.hPutStr hOut (renderFactSummary er)
          finish nExtract
        _ -> do
          let cg = buildGraph (toBuildOptions cmd) pm er
          -- ↓ 硬性要求的落點:cgWarnings 的唯一出口
          emitNotes hErr (graphNoteLines cg)
          let nGraph = nExtract + length (cgWarnings cg)
          case ecSummary cmd of
            Just SummaryGraph -> do
              TIO.hPutStr hOut (renderGraphSummary cg)
              finish nGraph
            _ -> do
              -- writeCodegraph 讓 IOException 原樣上拋(其 haddock 明文
              -- 「由 F004 的 CLI 層決定 exit code 與訊息」),在此收斂
              r <- try (writeCodegraph (toExportOptions cmd) cg)
              case r of
                Left e -> do
                  emitNotes hErr
                    [T.pack ("export: " <> show (e :: IOException))]
                  pure (ExitFailure 1)
                Right rep -> do
                  emitNotes hErr (exportNoteLines rep)
                  TIO.hPutStr hOut (wroteLine rep)
                  finish nGraph
 where
  -- 假設 A2:pmWarnings + erWarnings + cgWarnings 任一非空即視為有跳檔;
  -- brUsed = False 的「降級」不算(否則沒裝 hiedb 的環境在 --backend auto
  -- 下永遠 exit 1,與 ADR-002「降級而非失敗」直接衝突)
  finish n
    | ecStrict cmd && n > 0 = do
        emitNotes hErr [T.pack ("strict: " <> show n <> " warnings")]
        pure (ExitFailure 1)
    | otherwise = pure ExitSuccess

wroteLine :: ExportReport -> Text
wroteLine rep = T.pack
  ( "wrote " <> xrPath rep <> ": "
      <> show (xrNodeCount rep) <> " nodes, "
      <> show (xrEdgeCount rep) <> " edges\n"
  )

--------------------------------------------------------------------------------
-- query
--------------------------------------------------------------------------------

-- | 載入 → 未知 relation 提示 → 端點存在性提示 → 結果。
runQueryCmd :: Handle -> Handle -> QueryCmd -> IO ExitCode
runQueryCmd hOut hErr cmd = do
  r <- loadQueryGraph (qcFile cmd)
  case r of
    Left e -> do
      -- 契約:LoadError 直接失敗。三個建構子都自帶已組好的訊息
      -- (含路徑與問題),CLI 只加前綴,不重寫訊息
      emitNotes hErr [T.pack "query: " <> loadErrorText e]
      pure (ExitFailure 1)
    Right g -> do
      emitNotes hErr (queryNoteLines g)
      emitNotes hErr (missingNodeLines g (qcCommand cmd))
      TIO.hPutStr hOut (renderResult (runQuery g (qcCommand cmd)))
      -- 查無結果也是 0(空結果是正常結果,不是載入失敗)
      pure ExitSuccess

loadErrorText :: LoadError -> Text
loadErrorText e = case e of
  LoadFileMissing t -> t
  LoadParseError  t -> t
  LoadSchemaError t -> t

-- | 起點/終點不存在時的提示(落實 F003 假設 A1 的建議)。
--
-- __只影響訊息,不影響 exit code__(假設 A4):'runQuery' 本來就會回空結果,
-- 契約寫的是「查無結果 exit 0」。
--
-- 存在性一律問契約的 'queryGraphHasNode'(階段二閘門裁決):組裝層不讀
-- 'QueryGraph' 的內部欄位,「內容屬 Level 3」的承諾才成立;查詢在 library
-- 內走 @qgIndex@ 做 O(log n),executable 段也就不需要 @containers@。
missingNodeLines :: QueryGraph -> QueryCommand -> [Text]
missingNodeLines g cmd =
  [ T.concat [T.pack "query: node not found: ", t]
  | nid@(NodeId t) <- endpoints
  , not (queryGraphHasNode g nid)
  ]
 where
  endpoints = case cmd of
    Reachable start _    -> [start]
    ShortestPath from to -> [from, to]
    FindNodes _          -> []
    RankConnectivity _   -> []
