-- | knot 執行檔:極簡 getArgs 解析(委派決策 D1、F001 假設 A6)+ ProjectMeta 摘要。
-- 完整 CLI 參數解析屬後續 feature。
module Main (main) where

import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Knot.App.Summary (renderMetaSummary)
import Knot.Meta (loadProjectMeta)
import Knot.Meta.Types (MetaOptions (..))

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left err -> do
      hPutStrLn stderr err
      hPutStrLn stderr "usage: knot [PATH] [--include-tests]"
      exitFailure
    Right opts -> do
      meta <- loadProjectMeta opts
      TIO.putStr (renderMetaSummary meta)

-- | 位置參數 PATH(預設 ".")與旗標 --include-tests;其餘一律拒絕。
parseArgs :: [String] -> Either String MetaOptions
parseArgs = go (MetaOptions { root = ".", includeTests = False, hieDirOverride = Nothing }) False
 where
  go opts _seenPath [] = Right opts
  go opts seenPath (a : rest)
    | a == "--include-tests" = go opts { includeTests = True } seenPath rest
    | take 2 a == "--"       = Left ("unknown flag: " <> a)
    | seenPath               = Left ("unexpected extra argument: " <> a)
    | otherwise              = go opts { root = a } True rest
