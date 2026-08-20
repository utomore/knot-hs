-- | knot 執行檔內部模組:ProjectMeta 摘要輸出。
-- 不屬 library 對外介面(F001「新增的介面」:executable 內部;
-- test-suite 以共用 hs-source-dirs 方式測試)。
--
-- F002 擴充:package / component 區塊與檔案行尾的 owners 標示,
-- 供 particle-magic 唯讀驗收觀察 component 清單與歸類結果。
--
-- extraction/F002 擴充:'renderFactSummary'——事實摘要輸出,
-- 供 MagicFarmer / particle-magic 唯讀實跑對帳(假設 A6)。
--
-- graph-core/F001 擴充:'renderGraphSummary'——圖摘要輸出,
-- 同屬唯讀驗收路徑(假設 A8;library 全程不印任何輸出)。
module Knot.App.Summary
  ( renderMetaSummary
  , renderFactSummary
  , renderGraphSummary
  ) where

import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Extract.Types
  ( BackendReport (..)
  , ExtractResult (..)
  , ExtractWarning (..)
  , Fact (..)
  )
import Knot.Graph.Types
  ( CodeGraph (..)
  , GraphEdge (..)
  , GraphNode (..)
  , GraphStats (..)
  , GraphWarning (..)
  , NodeId (..)
  , NodeKind (..)
  , Relation (..)
  )
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

-- | 事實摘要:能力等級、後端報告、事實/警告筆數 + 逐筆 module/import 行,
-- 供唯讀驗收比對。輸出順序完全依 'ExtractResult' 內清單順序(決定性)。
renderFactSummary :: ExtractResult -> Text
renderFactSummary er = T.unlines
  (levelLine : backendLines <> countLines <> map factLine facts <> map warnLine warnings)
 where
  facts    = erFacts er
  warnings = erWarnings er
  nModules = length [() | FactModule{} <- facts]
  nImports = length [() | FactImport{} <- facts]
  levelLine = T.pack "level: " <> tshow (erLevel er)
  backendLines =
    (T.pack "backends: " <> tshow (length (erReports er)))
      : map backendLine (erReports er)
  backendLine br = T.concat
    [ T.pack "  ", brBackend br
    , T.pack " used=", tshow (brUsed br)
    , if T.null (brDetail br) then T.empty else T.pack " (" <> brDetail br <> T.pack ")"
    ]
  countLines =
    [ T.concat
        [ T.pack "facts: ", tshow (length facts), T.pack " total, "
        , tshow nModules, T.pack " modules, "
        , tshow nImports, T.pack " imports"
        ]
    , T.pack "warnings: " <> tshow (length warnings)
    ]
  factLine f@FactModule{} = T.concat
    [ T.pack "  M ", T.pack (fmFile f), T.pack "  [", unMod (fmModule f), T.pack "]" ]
  factLine f@FactImport{} = T.concat
    [ T.pack "  I ", T.pack (fiFile f), T.pack ":", tshow (fiLine f)
    , T.pack "  ", unMod (fiFrom f), T.pack " -> ", unMod (fiTo f)
    ]
  factLine f = T.pack "  ? " <> tshow f
  warnLine w = T.concat [T.pack "  ! ", ewSource w, T.pack ": ", ewMessage w]
  unMod (ModuleName m) = m
  tshow :: Show a => a -> Text
  tshow = T.pack . show

-- | 圖摘要:節點/邊/警告筆數、四項統計、外部 Top 清單、逐筆節點與邊行,
-- 供唯讀驗收比對。輸出順序完全依 'CodeGraph' 內清單順序(已由
-- graph-assemble 排序,決定性)。
renderGraphSummary :: CodeGraph -> Text
renderGraphSummary cg = T.unlines
  (countLine : statsLine : topLines <> map nodeLine nodes <> map edgeLine edges
    <> map warnLine warnings)
 where
  nodes    = cgNodes cg
  edges    = cgEdges cg
  warnings = cgWarnings cg
  stats    = cgStats cg
  countLine = T.concat
    [ T.pack "graph: ", tshow (length nodes), T.pack " nodes, "
    , tshow (length edges), T.pack " edges, "
    , tshow (length warnings), T.pack " warnings"
    ]
  statsLine = T.concat
    [ T.pack "stats: dropped-external=", tshow (gsDroppedExternal stats)
    , T.pack ", filtered-generated=", tshow (gsFilteredGenerated stats)
    , T.pack ", deduped-edges=", tshow (gsDedupedEdges stats)
    , T.pack ", top-external=", tshow (length (gsTopExternalTargets stats))
    ]
  topLines =
    [ T.concat [T.pack "  X ", unMod m, T.pack " ", tshow n]
    | (m, n) <- gsTopExternalTargets stats
    ]
  nodeLine n = T.concat
    [ T.pack "  N ", unNodeId (gnId n)
    , T.pack " [", kindText (gnKind n), T.pack "] "
    , T.pack (gnFile n)
    , maybe T.empty (\l -> T.pack ":" <> tshow l) (gnLine n)
    ]
  edgeLine e = T.concat
    [ T.pack "  E ", unNodeId (geSource e)
    , T.pack " -", relText (geRelation e), T.pack "-> "
    , unNodeId (geTarget e)
    , maybe T.empty (\l -> T.pack "  L" <> tshow l) (geLine e)
    ]
  warnLine w = T.concat [T.pack "  ! ", gwSource w, T.pack ": ", gwMessage w]
  kindText ModuleNode     = T.pack "module"
  kindText (DeclNode k)   = T.pack "decl:" <> tshow k
  kindText InstanceNode   = T.pack "instance"
  relText RImports    = T.pack "imports"
  relText RCalls      = T.pack "calls"
  relText RUses       = T.pack "uses"
  relText RImplements = T.pack "implements"
  relText RContains   = T.pack "contains"
  unNodeId (NodeId t) = t
  unMod (ModuleName m) = m
  tshow :: Show a => a -> Text
  tshow = T.pack . show
