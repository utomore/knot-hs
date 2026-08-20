-- | extraction 子系統對外契約進入點。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「對外契約」。
module Knot.Extract
  ( extract
  ) where

import Knot.Extract.Backend (Backend, runBackends)
import Knot.Extract.ImportScan (importScanBackend)
import Knot.Extract.Types (ExtractOptions, ExtractResult)
import Knot.Meta.Types (ProjectMeta)

-- | 依 'ExtractOptions' 調度已註冊的後端,合成事實流與能力等級。
--
-- 階段一語意:註冊表目前只有 import-scan(F002;hiedb 由階段二註冊),
-- 因此 @erLevel@ 最高只到 @ModuleLevel@,@HiedbOnly@ 會回空事實流 +
-- 「未選中」報告——這是預期行為,不是缺陷。'extract' 本身的行為不隨註冊表
-- 填實而改變。
extract :: ExtractOptions -> ProjectMeta -> IO ExtractResult
extract = runBackends registeredBackends

-- | 後端註冊表;順序即報告與警告的固定序(規則 8)。
-- 屬 backend-select 內部狀態,不匯出。
registeredBackends :: [Backend]
registeredBackends = [importScanBackend]
