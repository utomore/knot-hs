-- | knot 執行檔:解析 → 執行 → exit code,不含任何邏輯(F004 cli-wiring)。
--
-- 參數解析在 "Knot.App.Cli"、管線組裝與 exit code 在 "Knot.App.Run"、
-- 警告匯流在 "Knot.App.Report"——本模組因模組名衝突不會進 test-suite,
-- 故壓到只剩分派,可測邏輯全部下沉。
--
-- 舊的 @getArgs@ 解析與 @--facts@ \/ @--graph@ 兩個旗標由
-- @knot extract --summary facts|graph@ 承接(委派決策 C6、假設 A11)。
module Main (main) where

import Options.Applicative (execParser)
import System.Exit (exitWith)
import System.IO (stderr, stdout)

import Knot.App.Cli (cliParserInfo)
import Knot.App.Run (prepareHandles, runCommand)

main :: IO ()
main = do
  prepareHandles stdout stderr   -- export-query/B001:UTF-8,否則 CP950 遇 U+FFFD 即崩潰
  execParser cliParserInfo >>= runCommand stdout stderr >>= exitWith
