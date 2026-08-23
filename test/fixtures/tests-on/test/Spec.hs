module Main (main) where

import TOn.Helper (helper)

main :: IO ()
main = if helper == 42 then pure () else error "nope"
