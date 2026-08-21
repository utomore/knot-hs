-- | extraction 子系統對外契約進入點。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「對外契約」。
module Knot.Extract
  ( extract
  ) where

import Knot.Extract.Backend (Backend, runBackends)
import Knot.Extract.HiedbFacts (hiedbBackend)
import Knot.Extract.ImportScan (importScanBackend)
import Knot.Extract.Types (ExtractOptions, ExtractResult)
import Knot.Meta.Types (ProjectMeta)

-- | 依 'ExtractOptions' 調度已註冊的後端,合成事實流與能力等級。
--
-- 階段二起註冊表為 import-scan(F002)+ hiedb(F004):hiedb 探測通過時
-- @erLevel@ 到得了 @DeclLevel@,探測不過則只降級 + 記報告,import-scan 的
-- 事實不受影響。'extract' 本身的行為不隨註冊表填實而改變。
extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult
extract = runBackends registeredBackends

-- | 後端註冊表;順序即報告與警告的固定序(規則 8)。
-- 屬 backend-select 內部狀態,不匯出。
registeredBackends :: [Backend]
registeredBackends = [importScanBackend, hiedbBackend]
