module Main (main) where

import A.Lib (greet)

main :: IO ()
main = putStrLn (greet "a")
