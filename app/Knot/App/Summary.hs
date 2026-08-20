-- | knot 執行檔內部模組:ProjectMeta 摘要輸出。
-- 不屬 library 對外介面(F001「新增的介面」:executable 內部;
-- test-suite 以共用 hs-source-dirs 方式測試)。
module Knot.App.Summary
  ( renderMetaSummary
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Meta.Types
  ( MetaWarning (..)
  , ModuleName (..)
  , ProjectMeta (..)
  , SourceFile (..)
  )

-- | 摘要:檔案數、module 對映數、排除數、警告數 + 逐檔清單 + 警告清單。
-- 輸出順序完全依 ProjectMeta 內清單順序(決定性)。
renderMetaSummary :: ProjectMeta -> Text
renderMetaSummary pm = T.unlines (countLines <> map sourceLine sources <> map warningLine warnings)
 where
  sources  = pmSources pm
  warnings = pmWarnings pm
  nFiles    = length sources
  nModules  = length (filter (isJust . sfModule) sources)
  nExcluded = length (filter (not . sfIncluded) sources)
  countLines =
    [ T.concat
        [ T.pack "sources: ", tshow nFiles, T.pack " files, "
        , tshow nModules, T.pack " with module, "
        , tshow nExcluded, T.pack " excluded"
        ]
    , T.pack "warnings: " <> tshow (length warnings)
    ]
  sourceLine sf =
    T.concat
      [ T.pack (if sfIncluded sf then "  + " else "  - ")
      , T.pack (sfPath sf)
      , case sfModule sf of
          Just (ModuleName m) -> T.pack "  [" <> m <> T.pack "]"
          Nothing             -> T.empty
      ]
  warningLine w =
    T.concat [T.pack "  ! ", T.pack (mwPath w), T.pack ": ", mwMessage w]
  tshow = T.pack . show
