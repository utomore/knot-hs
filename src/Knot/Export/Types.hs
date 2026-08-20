-- | export-query 匯出面對外 DTO。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 匯出面」。
-- 三個型別的欄位名與型別依契約原文;'defaultOutputPath' 為非契約面
-- (供 F004 CLI 組裝取預設路徑,見 F001 假設 A2)。
module Knot.Export.Types
  ( -- * 對外契約
    ExportOptions (..)
  , CommitPolicy (..)
  , ExportReport (..)
    -- * 非契約面
  , defaultOutputPath
  ) where

import Data.Text (Text)
import System.FilePath ((</>))

-- | 匯出選項。@rootDir@ 是目標專案根目錄('AutoDetect' 在此跑 git);
-- @outputPath@ 為權威輸出路徑('writeCodegraph' 原樣使用,不做 fallback;
-- 預設值由 CLI 層以 'defaultOutputPath' 算,見假設 A2)。
data ExportOptions = ExportOptions
  { rootDir      :: FilePath      -- ^ 目標專案根目錄
  , outputPath   :: FilePath      -- ^ 權威輸出路徑(CLI @-o@ 覆寫)
  , commitPolicy :: CommitPolicy
  }
  deriving (Eq, Show)

-- | 'AutoDetect':在 @rootDir@ 跑 @git rev-parse HEAD@(唯讀);失敗則省略
--   欄位且__不警告__。'NoCommit':不輸出 @built_at_commit@。
data CommitPolicy = AutoDetect | NoCommit
  deriving (Eq, Show)

-- | 匯出報告。@xrNotes@ 為 'Knot.Graph.Types.GraphStats' 摘要行,
-- 由 CLI 層列印(library 全程不印)。
data ExportReport = ExportReport
  { xrPath      :: FilePath
  , xrNodeCount :: Int
  , xrEdgeCount :: Int
  , xrNotes     :: [Text]
  }
  deriving (Eq, Show)

-- | 非契約面(供 F004 CLI 組裝):@rootDir@ → 預設輸出路徑
-- @\<rootDir\>\/codegraph.json@。
defaultOutputPath :: FilePath -> FilePath
defaultOutputPath r = r </> "codegraph.json"
