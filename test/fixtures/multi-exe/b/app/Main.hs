module Main (main) where

import B.Lib (greet)

main :: IO ()
main = putStrLn (greet "b")
