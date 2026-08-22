module Main (main) where

-- F005 T3 fixture:刻意引用不存在的符號,讓 cabal build 必定失敗
main :: IO ()
main = thisSymbolDoesNotExist
