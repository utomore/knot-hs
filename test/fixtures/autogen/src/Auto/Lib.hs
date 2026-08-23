module Auto.Lib (banner) where

import Data.Version (showVersion)
import Paths_autogen (version)

banner :: String
banner = "autogen " ++ showVersion version
