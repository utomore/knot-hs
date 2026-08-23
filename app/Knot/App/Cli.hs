-- | knot 執行檔內部模組:@argv@ → 'Command' 的參數解析,以及
-- 'ExtractCmd' → 四個子系統 Options DTO 的純對映(F004 cli-wiring)。
--
-- 不屬 library 對外介面(F004「新增的介面」:executable 內部;
-- test-suite 以共用 @hs-source-dirs@ 方式測試,沿用 'Knot.App.Summary' 前例)。
--
-- 本模組__全程無 IO__:'cliParserInfo' 只是描述,執行由 'Knot.App.Run' 負責;
-- 解析失敗的 exit code 與訊息由 optparse-applicative 的 'info' 決定
-- (@infoFailureCode = 1@)。
--
-- 同名欄位的處置(F004「同名欄位與同名型別的處理」):
-- 'Knot.Extract.Types.ExtractOptions' 與 'Knot.Export.Types.ExportOptions'
-- 都有 @rootDir@,而 GHC2024 內含的 @DisambiguateRecordFields@ 不涵蓋
-- 記錄更新(GHC-99339)與裸選擇器(GHC-87543)→ 兩者一律 qualified
-- (@XT.@ \/ @ET.@),不新增語言擴充、不動任何 library DTO 的欄位名。
module Knot.App.Cli
  ( -- * CLI DTO
    Command (..)
  , ExtractCmd (..)
  , SummaryMode (..)
  , QueryCmd (..)
    -- * 解析
  , cliParserInfo
    -- * 旗標 → Options DTO 的純對映
  , toMetaOptions
  , toExtractOptions
  , toBuildOptions
  , toExportOptions
  , defaultOutputPath
  ) where

import Control.Applicative (optional)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Options.Applicative
  ( Parser
  , ParserInfo
  , ReadM
  , auto
  , command
  , eitherReader
  , fullDesc
  , header
  , help
  , helper
  , hsubparser
  , info
  , long
  , metavar
  , option
  , showDefaultWith
  , progDesc
  , short
  , showDefault
  , strArgument
  , strOption
  , switch
  , value
  , (<**>)
  )

import System.FilePath ((</>))

import Knot.Export.Types (CommitPolicy (AutoDetect))
import qualified Knot.Export.Types as ET
import qualified Knot.Extract.Types as XT
import Knot.Graph.Types (BuildOptions (..))
import Knot.Meta.Types (MetaOptions (..))
import Knot.Query (Direction (..), Level (..), NodeId (..), QueryCommand (..), Scope (..))

--------------------------------------------------------------------------------
-- CLI DTO
--------------------------------------------------------------------------------

-- | knot 的兩個子命令(system.md「CLI 介面(頂層契約)」)。
data Command
  = CmdExtract ExtractCmd
  | CmdQuery QueryCmd
  deriving (Eq, Show)

-- | @knot extract [PATH]@ 的四個旗標(S5 cli-zero-setup 起:@--backend@ \/
-- @--module-only@ \/ @--hiedir@ \/ @--hiedb@ \/ @--db@ 五個旗標已廢,
-- @knot extract .@ 是使用者需要知道的全部,ADR-006)。
--
-- 欄位序即 'extractParser' 的解析序(applicative 串接),兩者必須一致;
-- 順序照 system.md「CLI 介面(頂層契約)」的旗標列表。
data ExtractCmd = ExtractCmd
  { ecPath         :: FilePath           -- ^ 位置參數 PATH,預設 "."
  , ecOutput       :: Maybe FilePath     -- ^ --output
  , ecIncludeTests :: Bool               -- ^ --include-tests
  , ecStrict       :: Bool               -- ^ --strict
  , ecSummary      :: Maybe SummaryMode  -- ^ --summary;Nothing = 寫 codegraph.json
  }
  deriving (Eq, Show)

-- | C6:既有三個唯讀驗收輸出。
data SummaryMode = SummaryMeta | SummaryFacts | SummaryGraph
  deriving (Eq, Show)

-- | @knot query@:圖檔路徑 + 五子命令之一。
data QueryCmd = QueryCmd
  { qcFile    :: FilePath      -- ^ --graph,預設 "codegraph.json"(假設 A3)
  , qcLevel   :: Level         -- ^ --level all|module|decl,預設 all(export-query/E001;子命令共用)
  , qcScope   :: Scope         -- ^ --scope product|tests|all,預設 product(G-E007;@tests-of@ 不受影響)
  , qcCommand :: QueryCommand  -- ^ F003 的契約 DTO
  }
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- 解析
--------------------------------------------------------------------------------

-- | 頂層 'ParserInfo'(含 @--help@ 與兩個子命令)。
--
-- 'hsubparser' 會自動替每個子命令掛上 @--help@;頂層另以 @\<**\> helper@
-- 明確掛一次。
cliParserInfo :: ParserInfo Command
cliParserInfo = info (commandParser <**> helper)
  ( fullDesc
      <> progDesc "build and query a Haskell code knowledge graph"
      <> header "knot - Haskell code knowledge graph generator"
  )

commandParser :: Parser Command
commandParser = hsubparser
  ( command "extract"
      (info (CmdExtract <$> extractParser)
        (progDesc "scan a project and write codegraph.json"))
      <> command "query"
      (info (CmdQuery <$> queryParser)
        (progDesc "query an existing codegraph.json"))
  )

extractParser :: Parser ExtractCmd
extractParser = ExtractCmd
  <$> strArgument
        (metavar "PATH" <> value "." <> showDefault
          <> help "project root to scan")
  <*> optional
        (strOption
          (long "output" <> short 'o' <> metavar "FILE"
            <> help "output path (default: <PATH>/codegraph.json)"))
  <*> switch
        (long "include-tests"
          <> help "include test-suite and benchmark components")
  <*> switch
        (long "strict"
          <> help "exit 1 when there is any warning")
  <*> optional
        (option summaryReader
          (long "summary" <> metavar "meta|facts|graph"
            <> help "print a read-only summary instead of writing codegraph.json"))

queryParser :: Parser QueryCmd
queryParser = QueryCmd
  <$> strOption
        (long "graph" <> metavar "FILE"
          <> value "codegraph.json" <> showDefault
          <> help "codegraph.json to query")
  <*> option levelReader
        (long "level" <> metavar "all|module|decl"
          <> value LevelAll <> showDefaultWith levelName
          <> help "restrict the graph to one level before querying (decl = targets of contains edges)")
  <*> option scopeReader
        (long "scope" <> metavar "product|tests|all"
          <> value ScopeProduct <> showDefaultWith scopeName
          <> help "restrict the graph to product or test components before querying (tests-of ignores this)")
  <*> queryCommandParser

-- | @--scope@ 的三個取值(G-E007)。
scopeReader :: ReadM Scope
scopeReader = eitherReader $ \s -> case s of
  "product" -> Right ScopeProduct
  "tests"   -> Right ScopeTests
  "all"     -> Right ScopeAll
  _         -> Left ("unknown scope: " <> s <> " (expected product|tests|all)")

scopeName :: Scope -> String
scopeName s = case s of
  ScopeProduct -> "product"
  ScopeTests   -> "tests"
  ScopeAll     -> "all"

-- | @--level@ 的三個取值(export-query/E001)。
levelReader :: ReadM Level
levelReader = eitherReader $ \s -> case s of
  "all"    -> Right LevelAll
  "module" -> Right LevelModule
  "decl"   -> Right LevelDecl
  _        -> Left ("unknown level: " <> s <> " (expected all|module|decl)")

levelName :: Level -> String
levelName l = case l of
  LevelAll    -> "all"
  LevelModule -> "module"
  LevelDecl   -> "decl"

-- | @--depth N@:必須 ≥ 1(0 與負數沒有意義——規則 5 本來就不含起點)。
depthReader :: ReadM Int
depthReader = eitherReader $ \s -> case reads s of
  [(n, "")] | n >= 1 -> Right n
  _                  -> Left ("--depth must be a positive integer, got: " <> s)

queryCommandParser :: Parser QueryCommand
queryCommandParser = hsubparser
  ( command "find"
      (info findParser (progDesc "nodes whose id or label contains KEYWORD"))
      <> command "reachable"
      (info reachableParser (progDesc "nodes reachable from ID"))
      <> command "path"
      (info pathParser (progDesc "shortest path from FROM to TO"))
      <> command "rank"
      (info rankParser (progDesc "nodes ranked by connectivity"))
      <> command "tests-of"
      (info testsOfParser (progDesc "test nodes that (directly or indirectly) depend on ID"))
  )

testsOfParser :: Parser QueryCommand
testsOfParser = TestsOf <$> nodeIdArgument "ID" "product node id"

findParser :: Parser QueryCommand
findParser = FindNodes . T.pack
  <$> strArgument (metavar "KEYWORD" <> help "substring, case-insensitive")

reachableParser :: Parser QueryCommand
reachableParser = Reachable
  <$> nodeIdArgument "ID" "start node id"
  <*> (directionOf <$> switch
        (long "reverse"
          <> help "who depends on it (default: what it depends on)"))
  <*> optional (option depthReader
        (long "depth" <> metavar "N"
          <> help "only nodes within N hops (default: unlimited)"))
 where
  directionOf b = if b then Reverse else Forward

pathParser :: Parser QueryCommand
pathParser = ShortestPath
  <$> nodeIdArgument "FROM" "path start node id"
  <*> nodeIdArgument "TO" "path end node id"

rankParser :: Parser QueryCommand
rankParser = RankConnectivity
  <$> option auto
        (long "top" <> metavar "N" <> value 10 <> showDefault
          <> help "how many nodes to list")

nodeIdArgument :: String -> String -> Parser NodeId
nodeIdArgument mv doc =
  NodeId . T.pack <$> strArgument (metavar mv <> help doc)

-- | @--summary@ 的三個取值(C6 的三條唯讀驗收輸出)。
summaryReader :: ReadM SummaryMode
summaryReader = eitherReader $ \s -> case s of
  "meta"  -> Right SummaryMeta
  "facts" -> Right SummaryFacts
  "graph" -> Right SummaryGraph
  _       -> Left ("expected meta|facts|graph, got " <> show s)

--------------------------------------------------------------------------------
-- 旗標 → Options DTO 的純對映(驗收標準 1)
--------------------------------------------------------------------------------

-- | @PATH@ / @--include-tests@ → project-meta 的選項。
toMetaOptions :: ExtractCmd -> MetaOptions
toMetaOptions c = MetaOptions
  { root         = ecPath c
  , includeTests = ecIncludeTests c
  }

-- | @PATH@ → extraction 的選項。S5 起只剩 @rootDir@:沒有後端可選、
-- 沒有執行檔可指、索引固定住在 @\<PATH\>\/.knot\/@(ADR-006)。
toExtractOptions :: ExtractCmd -> XT.ExtractOptions
toExtractOptions c = XT.ExtractOptions { XT.rootDir = ecPath c }

-- | graph-core 的選項。@--module-only@ 已廢(S5):extraction 兩層全有全無,
-- 沒有「只要 module 層」的路徑;@moduleOnly@ 是 graph-core 契約欄位,保留
-- 並固定填 'False',不越界去 graph-core 刪欄位。
toBuildOptions :: ExtractCmd -> BuildOptions
toBuildOptions _ = BuildOptions { moduleOnly = False }

-- | @rootDir@ → 預設輸出路徑 @\<rootDir\>\/codegraph.json@。
--
-- CLI 的預設值屬組裝層,不屬 library 契約面:G-E001 M2 把它從
-- 'Knot.Export.Types' 搬來這裡,export-query 的公開模組因此只剩契約
-- (→ ADR-004)。行為與簽名與搬遷前一字不差。
defaultOutputPath :: FilePath -> FilePath
defaultOutputPath r = r </> "codegraph.json"

-- | @PATH@ / @--output@ → export-query 匯出面的選項。
--
-- @outputPath@ 未給時以 'defaultOutputPath' 算(F001 假設 A2 的既定分工);
-- @commitPolicy@ 固定 'AutoDetect'(無對應旗標,假設 A6)。
toExportOptions :: ExtractCmd -> ET.ExportOptions
toExportOptions c = ET.ExportOptions
  { ET.rootDir      = ecPath c
  , ET.outputPath   = fromMaybe (defaultOutputPath (ecPath c)) (ecOutput c)
  , ET.commitPolicy = AutoDetect
  }
