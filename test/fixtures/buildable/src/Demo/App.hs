module Demo.App
  ( run
  ) where

import Demo.Core (Color (..), greet)

run :: String
run = greet Red ++ greet Blue
