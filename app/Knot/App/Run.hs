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
-- extraction 的整體失敗 fail-fast(@Left ExtractFailure@ → exit 1、不寫檔,
-- 與 @--strict@ 無關,ADR-006)、查詢面 fail-fast('LoadError' 直接 exit 1),
-- 而__查無結果 exit 0__。
module Knot.App.Run
  ( runCommand
  , runExtractCmd
  , runExtractCmdWith
  , runQueryCmd
  , prepareHandles
  ) where

import Control.Exception (IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (ExitCode (..))
import System.IO (Handle, hSetEncoding, utf8)

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
  , extractFailureLines
  , extractNoteLines
  , graphNoteLines
  , metaNoteLines
  , queryNoteLines
  )
import Knot.App.Summary (renderFactSummary, renderGraphSummary, renderMetaSummary)
import Knot.Export (writeCodegraph)
import Knot.Export.Types (ExportReport (..))
import Knot.Extract (extract)
import Knot.Extract.Types (ExtractFailure, ExtractResult (..))
import qualified Knot.Extract.Types as XT
import Knot.Graph (buildGraph)
import Knot.Graph.Types (CodeGraph (..))
import Knot.Meta (loadProjectMeta)
import Knot.Meta.Types (ProjectMeta (..))
import Knot.Query
  ( Level (..)
  , LoadError (..)
  , NodeId (..)
  , QueryCommand (..)
  , QueryGraph
  , Scope (..)
  , loadQueryGraph
  , queryGraphHasNode
  , queryGraphHasTests
  , renderResult
  , restrictLevel
  , restrictScope
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
-- 'Main' 與既有呼叫端用的進入點:接上真實的 'extract'。
runExtractCmd :: Handle -> Handle -> ExtractCmd -> IO ExitCode
runExtractCmd = runExtractCmdWith extract

-- | 四站管線,@extract@ 以參數注入——執行層對上游進入點多型,跟兩個
-- 'Handle' 注入是同一個理由(端到端可測:測試給假的 @extract@,就能驗
-- @Left@ 通道而不必造一個真的建不起來的專案)。
--
-- @Left ExtractFailure@ 的短路發生在 @--summary facts@ \/ @graph@ 分流與
-- @--strict@ 判定__之前__:印訊息、exit 1、不寫檔、到此為止。
-- @--summary meta@ 站在 @extract@ 之前收工,不受影響。
runExtractCmdWith
  :: (XT.ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult))
  -> Handle -> Handle -> ExtractCmd -> IO ExitCode
runExtractCmdWith extractFn hOut hErr cmd = do
  pm <- loadProjectMeta (toMetaOptions cmd)
  emitNotes hErr (metaNoteLines pm)
  let nMeta = length (pmWarnings pm)
  case ecSummary cmd of
    Just SummaryMeta -> do
      TIO.hPutStr hOut (renderMetaSummary pm)
      finish nMeta
    _ -> do
      extracted <- extractFn (toExtractOptions cmd) pm
      case extracted of
        Left failure -> do
          emitNotes hErr (extractFailureLines failure)
          pure (ExitFailure 1)   -- 不看 --strict、不看 --summary、不寫檔
        Right er -> do
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
  -- 假設 A2:pmWarnings + erWarnings + cgWarnings 任一非空即視為有跳檔
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
    Right g0 -> do
      -- E001:先依 --level 收斂為誘導子圖(查詢規則 7);G-E007:再依 --scope 收斂
      -- (規則 9)——但 tests-of 永遠在 ScopeAll 的圖上跑(規則 10),否則結果恆空
      let gl = restrictLevel (qcLevel cmd) g0
          g  = case qcCommand cmd of
                 TestsOf _ -> gl
                 _         -> restrictScope (qcScope cmd) gl
      emitNotes hErr (queryNoteLines g0)
      emitNotes hErr (missingNodeLines (qcLevel cmd) g0 gl (qcCommand cmd))
      emitNotes hErr (scopeMissingLines (qcScope cmd) gl g (qcCommand cmd))
      emitNotes hErr (noTestsLines g0 (qcCommand cmd))
      TIO.hPutStr hOut (renderResult (runQuery g (qcCommand cmd)))
      -- 查無結果也是 0(空結果是正常結果,不是載入失敗)
      pure ExitSuccess

loadErrorText :: LoadError -> Text
loadErrorText e = case e of
  LoadFileMissing t -> t
  LoadParseError  t -> t
  LoadSchemaError t -> t

-- | 把輸出 handle 設成 UTF-8(export-query/B001)。GHC 在 Windows 對非 console 的
-- handle 預設用系統 ANSI code page(zh-TW 是 CP950),U+FFFD 這類字元一印就拋
-- @hPutChar: invalid argument@——而 build-driver 對 cabal 輸出做 lenient 解碼時
-- 正好會產生 U+FFFD。UTF-8 編得了所有字元,也是 codegraph.json 與文件的編碼。
-- 放在這裡而不是 "Main":Main 因模組名衝突不進 test-suite,這樣才測得到。
prepareHandles :: Handle -> Handle -> IO ()
prepareHandles hOut hErr = do
  hSetEncoding hOut utf8
  hSetEncoding hErr utf8

-- | 起點/終點不存在時的提示(落實 F003 假設 A1 的建議)。
--
-- __只影響訊息,不影響 exit code__(假設 A4):'runQuery' 本來就會回空結果,
-- 契約寫的是「查無結果 exit 0」。
--
-- 存在性一律問契約的 'queryGraphHasNode'(階段二閘門裁決):組裝層不讀
-- 'QueryGraph' 的內部欄位,「內容屬 Level 3」的承諾才成立;查詢在 library
-- 內走 @qgIndex@ 做 O(log n),executable 段也就不需要 @containers@。
missingNodeLines :: Level -> QueryGraph -> QueryGraph -> QueryCommand -> [Text]
missingNodeLines lvl full restricted cmd = concat
  [ if not (queryGraphHasNode full nid)
      then [T.concat [T.pack "query: node not found: ", t]]
    else if not (queryGraphHasNode restricted nid)
      -- E001:節點在,但被 --level 收斂掉了——不能靜默回空,否則分不出「不存在」與「不在該層」
      then [T.concat [T.pack "query: node ", t, T.pack " is not at level ", levelText lvl]]
    else []
  | nid@(NodeId t) <- commandEndpoints cmd
  ]
 where
  levelText l = T.pack $ case l of
    LevelAll    -> "all"
    LevelModule -> "module"
    LevelDecl   -> "decl"

-- | 節點在層內、卻被 @--scope@ 收斂掉時的提示(G-E007)。第一個圖是 @--level@ 後、
-- 第二個是再經 @--scope@ 後的圖;兩者相同(@tests-of@ 或 @--scope all@)時恆空。
scopeMissingLines :: Scope -> QueryGraph -> QueryGraph -> QueryCommand -> [Text]
scopeMissingLines scope levelled scoped cmd =
  [ T.concat [T.pack "query: node ", t, T.pack " is not in scope ", scopeText scope]
  | nid@(NodeId t) <- commandEndpoints cmd
  , queryGraphHasNode levelled nid
  , not (queryGraphHasNode scoped nid)
  ]
 where
  scopeText s = T.pack $ case s of
    ScopeProduct -> "product"
    ScopeTests   -> "tests"
    ScopeAll     -> "all"

-- | @tests-of@ 跑在一張沒有任何測試節點的圖上時的提示(G-E007):結果必然是空的,
-- 但原因是「沒建測試」而不是「沒有測試依賴它」,不提示使用者會誤判。
noTestsLines :: QueryGraph -> QueryCommand -> [Text]
noTestsLines full cmd = case cmd of
  TestsOf _ | not (queryGraphHasTests full) ->
    [T.pack "query: graph has no test components; rerun knot extract --include-tests"]
  _ -> []

-- | 各指令的端點(存在性提示的對象)。
commandEndpoints :: QueryCommand -> [NodeId]
commandEndpoints cmd = case cmd of
  Reachable start _ _  -> [start]
  ShortestPath from to -> [from, to]
  TestsOf target       -> [target]
  FindNodes _          -> []
  RankConnectivity _   -> []
