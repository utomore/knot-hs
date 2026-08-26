-- | project-meta 對外 DTO。
--
-- Level 2 契約:@.design/subsystems/project-meta/design.md@「對外契約」。
-- S5(ADR-006、F004 hie-retire)起 project-meta 不再碰 @.hie@:沒有
-- @.hie@ 資訊 DTO、沒有 @--hiedir@ 覆寫,'ProjectMeta' 只描述套件、檔案與警告。
module Knot.Meta.Types
  ( MetaOptions (..)
  , ProjectMeta (..)
  , PackageMeta (..)
  , ComponentMeta (..)
  , ComponentKind (..)
  , ComponentRef (..)
  , SourceFile (..)
  , ModuleName (..)
  , MetaWarning (..)
  ) where

import Data.Text (Text)

data MetaOptions = MetaOptions
  { root           :: FilePath        -- ^ 專案根目錄
  , includeTests   :: Bool            -- ^ 納入 test-suite 與 benchmark。__本欄位沒有預設值__,
                                      --   呼叫者一律明確給值;CLI 的預設是 'True'
                                      --   (G-E008,@--exclude-tests@ 才給 'False')
  }
  deriving (Eq, Show)

data ProjectMeta = ProjectMeta
  { pmPackages :: [PackageMeta]   -- ^ 多套件;無 .cabal 時為空
  , pmSources  :: [SourceFile]    -- ^ 全專案原始碼檔案清單
  , pmWarnings :: [MetaWarning]   -- ^ best-effort 蒐集,由呼叫端印到 stderr
  }
  deriving (Eq, Show)

data PackageMeta = PackageMeta
  { pkgName       :: Text
  , pkgCabalFile  :: FilePath          -- ^ repo 相對路徑
  , pkgComponents :: [ComponentMeta]
  }
  deriving (Eq, Show)

data ComponentMeta = ComponentMeta
  { compName       :: Text             -- ^ 如 "lib:magic-core"、"exe:particle-magic"
  , compKind       :: ComponentKind
  , compSourceDirs :: [FilePath]       -- ^ hs-source-dirs(repo 相對)
  , compModules    :: [ModuleName]     -- ^ exposed-modules ++ other-modules(宣告序、去重;E001)
  , compMainIs     :: Maybe FilePath   -- ^ main-is,相對 hs-source-dirs 的原樣路徑(正斜線);library / flib 為 Nothing(E001)
  , compExcluded   :: Bool             -- ^ 依 kind 與 includeTests 判定
  }
  deriving (Eq, Show)

data ComponentKind
  = MainLibrary
  | NamedLibrary
  | Executable
  | ForeignLibrary
  | TestSuite
  | Benchmark
  deriving (Eq, Show)

-- | @(pkgName, compName)@ 的參照(design.md 原文)。
newtype ComponentRef = ComponentRef (Text, Text)
  deriving (Eq, Show)

data SourceFile = SourceFile
  { sfPath     :: FilePath             -- ^ repo 相對、正斜線
  , sfModule   :: Maybe ModuleName     -- ^ 路徑規則推得;推不出為 Nothing
  , sfOwners   :: [ComponentRef]       -- ^ 一對多;無 .cabal 時為空
  , sfIncluded :: Bool                 -- ^ 排除判定結果
  }
  deriving (Eq, Show)

-- | 點分形式 module 名,如 @"MagicFarmer.Render.Core"@(F001 假設 A1)。
newtype ModuleName = ModuleName Text
  deriving (Eq, Ord, Show)

-- | 帶來源路徑的警告(F001 假設 A2)。
data MetaWarning = MetaWarning
  { mwPath    :: FilePath
  , mwMessage :: Text
  }
  deriving (Eq, Show)
