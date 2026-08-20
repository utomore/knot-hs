-- | knot 執行檔內部模組:ProjectMeta 摘要輸出。
-- 不屬 library 對外介面(F001「新增的介面」:executable 內部;
-- test-suite 以共用 hs-source-dirs 方式測試)。
--
-- F002 擴充:package / component 區塊與檔案行尾的 owners 標示,
-- 供 particle-magic 唯讀驗收觀察 component 清單與歸類結果。
module Knot.App.Summary
  ( renderMetaSummary
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Meta.Types
  ( ComponentMeta (..)
  , ComponentRef (..)
  , MetaWarning (..)
  , ModuleName (..)
  , PackageMeta (..)
  , ProjectMeta (..)
  , SourceFile (..)
  )

-- | 摘要:套件/component 區塊 + 檔案數、module 對映數、排除數、警告數
-- + 逐檔清單(含 owners)+ 警告清單。
-- 輸出順序完全依 ProjectMeta 內清單順序(決定性)。
renderMetaSummary :: ProjectMeta -> Text
renderMetaSummary pm = T.unlines
  (packageLines <> countLines <> map sourceLine sources <> map warningLine warnings)
 where
  packages = pmPackages pm
  sources  = pmSources pm
  warnings = pmWarnings pm
  nFiles    = length sources
  nModules  = length (filter (isJust . sfModule) sources)
  nExcluded = length (filter (not . sfIncluded) sources)
  packageLines =
    (T.pack "packages: " <> tshow (length packages))
      : concatMap packageBlock packages
  packageBlock p =
    T.concat [T.pack "  package ", pkgName p, T.pack " (", T.pack (pkgCabalFile p), T.pack ")"]
      : map componentLine (pkgComponents p)
  componentLine c = T.concat
    [ T.pack "    ", compName c
    , T.pack " [", tshow (compKind c), T.pack "]"
    , T.pack " dirs: ", T.intercalate (T.pack ", ") (map T.pack (compSourceDirs c))
    , if compExcluded c then T.pack "  excluded" else T.empty
    ]
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
      , ownersSuffix (sfOwners sf)
      ]
  ownersSuffix [] = T.empty
  ownersSuffix refs =
    T.pack "  {" <> T.intercalate (T.pack ", ") (map ownerText refs) <> T.pack "}"
  ownerText (ComponentRef (p, c)) = p <> T.pack "/" <> c
  warningLine w =
    T.concat [T.pack "  ! ", T.pack (mwPath w), T.pack ": ", mwMessage w]
  tshow :: Show a => a -> Text
  tshow = T.pack . show
