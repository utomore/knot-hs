-- | project-meta 對外 DTO。
--
-- Level 2 契約:@.design/subsystems/project-meta/design.md@「對外契約」。
-- S1(F001)僅 'MetaOptions'、'ProjectMeta'、'SourceFile'、'MetaWarning'、
-- 'ModuleName' 有邏輯觸碰;其餘為階段二 DTO 先行定義(F001 假設 A5),零邏輯。
module Knot.Meta.Types
  ( MetaOptions (..)
  , ProjectMeta (..)
  , PackageMeta (..)
  , ComponentMeta (..)
  , ComponentKind (..)
  , ComponentRef (..)
  , SourceFile (..)
  , ModuleName (..)
  , HieInfo (..)
  , HieDirSource (..)
  , MetaWarning (..)
  ) where

import Data.Text (Text)

data MetaOptions = MetaOptions
  { root           :: FilePath        -- ^ 專案根目錄
  , includeTests   :: Bool            -- ^ 納入 test-suite 與 benchmark(預設 False)
  , hieDirOverride :: Maybe FilePath  -- ^ --hiedir 覆寫
  }
  deriving (Eq, Show)

data ProjectMeta = ProjectMeta
  { pmPackages :: [PackageMeta]   -- ^ 多套件;S1(尚無 .cabal 解析)為空
  , pmSources  :: [SourceFile]    -- ^ 全專案原始碼檔案清單
  , pmHie      :: Maybe HieInfo   -- ^ 找不到 .hie 時 Nothing
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
  , sfOwners   :: [ComponentRef]       -- ^ 一對多;S1 為空
  , sfIncluded :: Bool                 -- ^ 排除判定結果
  }
  deriving (Eq, Show)

-- | 點分形式 module 名,如 @"MagicFarmer.Render.Core"@(F001 假設 A1)。
newtype ModuleName = ModuleName Text
  deriving (Eq, Ord, Show)

data HieInfo = HieInfo
  { hieDir    :: FilePath
  , hieSource :: HieDirSource          -- ^ 採用了哪層發現順序
  , hieFiles  :: [FilePath]            -- ^ 有效 .hie 清單(repo 相對)
  , hieGhosts :: [FilePath]            -- ^ 幽靈 .hie(對應原始檔已不存在)
  }
  deriving (Eq, Show)

data HieDirSource = FromFlag | FromConvention | FromDistNewstyle
  deriving (Eq, Show)

-- | 帶來源路徑的警告(F001 假設 A2)。
data MetaWarning = MetaWarning
  { mwPath    :: FilePath
  , mwMessage :: Text
  }
  deriving (Eq, Show)
