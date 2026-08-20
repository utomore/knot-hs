-- | knot 執行檔:極簡 getArgs 解析(委派決策 D1、F001 假設 A6)+ 摘要輸出。
-- 完整 CLI 參數解析屬後續 feature。
--
-- extraction/F002 擴充:@--facts@ 走 extraction 管線印事實摘要
-- (唯讀驗收路徑,假設 A6);預設仍印 ProjectMeta 摘要。
--
-- graph-core/F001 擴充:@--graph@ 走 loadProjectMeta → extract → buildGraph
-- 印圖摘要(唯讀驗收路徑,假設 A8);優先序 @--graph@ > @--facts@ > 預設。
module Main (main) where

import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Knot.App.Summary (renderFactSummary, renderGraphSummary, renderMetaSummary)
import Knot.Extract (extract)
import Knot.Extract.Types (BackendChoice (..), ExtractOptions (..))
import Knot.Graph (buildGraph)
import Knot.Graph.Types (BuildOptions (..))
import Knot.Meta (loadProjectMeta)
import Knot.Meta.Types (MetaOptions (..))

-- | CLI 選項:ProjectMeta 選項 + 輸出模式。
data CliOptions = CliOptions
  { cliMeta  :: MetaOptions
  , cliFacts :: Bool          -- ^ --facts:改印事實摘要
  , cliGraph :: Bool          -- ^ --graph:改印圖摘要
  }

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left err -> do
      hPutStrLn stderr err
      hPutStrLn stderr "usage: knot [PATH] [--include-tests] [--facts] [--graph]"
      exitFailure
    Right cli -> do
      let metaOpts = cliMeta cli
      meta <- loadProjectMeta metaOpts
      if cliGraph cli
        then do
          result <- extract (extractOpts (root metaOpts)) meta
          TIO.putStr (renderGraphSummary (buildGraph buildOpts meta result))
        else if cliFacts cli
          then do
            result <- extract (extractOpts (root metaOpts)) meta
            TIO.putStr (renderFactSummary result)
          else TIO.putStr (renderMetaSummary meta)

-- | 抽取選項:rootDir 沿用 PATH,其餘為預設(階段一只有 import-scan 註冊)。
extractOpts :: FilePath -> ExtractOptions
extractOpts r = ExtractOptions
  { rootDir       = r
  , backendChoice = Auto
  , hiedbExe      = Nothing
  , dbPath        = Nothing
  }

-- | 建圖選項:@--module-only@ 的 CLI 面屬 export-query 的 CLI feature,
-- 本階段固定 False(階段一兩個取值輸出相同)。
buildOpts :: BuildOptions
buildOpts = BuildOptions { moduleOnly = False }

-- | 位置參數 PATH(預設 ".")與旗標 --include-tests / --facts / --graph;
-- 其餘一律拒絕。
parseArgs :: [String] -> Either String CliOptions
parseArgs = go (CliOptions defMeta False False) False
 where
  defMeta = MetaOptions { root = ".", includeTests = False, hieDirOverride = Nothing }
  go cli _seenPath [] = Right cli
  go cli seenPath (a : rest)
    | a == "--include-tests" =
        go cli { cliMeta = (cliMeta cli) { includeTests = True } } seenPath rest
    | a == "--facts"   = go cli { cliFacts = True } seenPath rest
    | a == "--graph"   = go cli { cliGraph = True } seenPath rest
    | take 2 a == "--" = Left ("unknown flag: " <> a)
    | seenPath         = Left ("unexpected extra argument: " <> a)
    | otherwise        = go cli { cliMeta = (cliMeta cli) { root = a } } True rest
