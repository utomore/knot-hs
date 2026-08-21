module Demo.Core
  ( Color (..)
  , greet
  ) where

data Color = Red | Green | Blue

greet :: Color -> String
greet Red   = "red"
greet Green = "green"
greet Blue  = "blue"
