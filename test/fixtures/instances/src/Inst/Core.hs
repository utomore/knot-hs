{-# LANGUAGE DeriveAnyClass #-}
module Inst.Core
  ( Renderable (..)
  , Convert (..)
  , Sprite (..)
  , Wrapper (..)
  , Tag (..)
  ) where

class Renderable a where
  render :: a -> String
  render _ = "?"

class Convert a b where
  convert :: a -> b

data Sprite = Sprite Int
newtype Wrapper a = Wrapper a
data Tag = Tag deriving (Show)

instance Renderable Sprite where
  render (Sprite n) = show n

instance Renderable a => Renderable (Wrapper a) where
  render (Wrapper a) = render a

instance (Show a, Renderable a) => Renderable [a] where
  render = concatMap render

instance Renderable (Maybe a) where
  render _ = "maybe"

instance Convert Sprite Int where
  convert (Sprite n) = n

instance Show Sprite where
  show (Sprite n) = "Sprite " ++ show n

instance Renderable Tag

instance
  Renderable
    Bool where
  render b = if b then "yes" else "no"

deriving instance Eq Sprite
deriving anyclass instance Renderable Int
