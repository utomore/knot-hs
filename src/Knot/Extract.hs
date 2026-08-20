-- | extraction 子系統對外契約進入點。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「對外契約」。
module Knot.Extract
  ( extract
  ) where

import Knot.Extract.Backend (Backend, runBackends)
import Knot.Extract.Types (ExtractOptions, ExtractResult)
import Knot.Meta.Types (ProjectMeta)

-- | 依 'ExtractOptions' 調度已註冊的後端,合成事實流與能力等級。
--
-- 階段一語意:後端註冊表為空(import-scan 由 F002 註冊、hiedb 由階段二
-- 註冊),因此對任何專案都回 @erFacts = []@、@erReports = []@、
-- @erWarnings = []@、@erLevel = ModuleLevel@——這是預期行為,不是缺陷
-- (F001 假設 A7)。'extract' 本身的行為不隨註冊表填實而改變。
extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult
extract = runBackends registeredBackends

-- | 後端註冊表;順序即報告與警告的固定序(規則 8)。
-- 屬 backend-select 內部狀態,不匯出。
registeredBackends :: [Backend]
registeredBackends = []
