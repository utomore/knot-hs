module Main (main) where

import Demo.Core (greet)

main :: IO ()
main = putStrLn (greet "knot")
