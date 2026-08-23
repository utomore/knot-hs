module Inst.Extra (Blob (..)) where

import Inst.Core (Renderable (..))

data Blob = Blob

instance Renderable Blob where
  render _ = "blob"
