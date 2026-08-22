-- | export-query 匯出面對外 DTO。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 匯出面」。
-- 三個型別的欄位名與型別依契約原文;本模組是公開 library 的一員
-- (→ ADR-004),因此只放契約面——CLI 預設輸出路徑歸組裝層所有,見
-- @Knot.App.Cli.defaultOutputPath@(G-E001 M2)。
module Knot.Export.Types
  ( ExportOptions (..)
  , CommitPolicy (..)
  , ExportReport (..)
  ) where

import Data.Text (Text)

-- | 匯出選項。@rootDir@ 是目標專案根目錄('AutoDetect' 在此跑 git);
-- @outputPath@ 為權威輸出路徑('writeCodegraph' 原樣使用,不做 fallback;
-- 預設值由 CLI 層的 @Knot.App.Cli.defaultOutputPath@ 算,見假設 A2)。
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
