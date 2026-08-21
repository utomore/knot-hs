-- | @built_at_commit@ 的偵測(Level 2 契約「使用的技術」:@git rev-parse HEAD@
-- 在 @rootDir@ 執行、對目標專案唯讀、失敗即省略)。
--
-- 全程不印任何訊息:'readCreateProcessWithExitCode' 會__捕獲__ git 的 stderr,
-- 非 repo 時的 @fatal: not a git repository@ 不會外流(驗收標準 3 的「無警告」
-- 與委派決策 D8 的「library 全程不印」)。
module Knot.Export.Commit
  ( detectCommit
  ) where

import Control.Exception (IOException, try)
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..)
  , proc
  , readCreateProcessWithExitCode
  )

import Knot.Export.Types (CommitPolicy (..))

-- | commit 偵測。'NoCommit' 直接回 'Nothing';'AutoDetect' 在 @rootDir@ 跑
-- @git rev-parse HEAD@(唯讀),任何失敗——git 不在 PATH 或 @rootDir@ 不存在
-- ('IOException')、非 repo 或空 repo('ExitFailure')、輸出不是合法 sha
-- ('validSha' 不過)——一律回 'Nothing' 且__不印任何訊息__。
--
-- 已知邊界:@rootDir@ 若位於某個更上層 repo 之內,git 會回上層 repo 的 HEAD。
-- 這是 'AutoDetect' 語意本身的性質,契約未要求偵測 repo 邊界。
detectCommit :: CommitPolicy -> FilePath -> IO (Maybe Text)
detectCommit NoCommit   _    = pure Nothing
detectCommit AutoDetect root = do
  outcome <- try (readCreateProcessWithExitCode gitRevParse "")
  pure $ case outcome of
    Left (_ :: IOException)     -> Nothing
    Right (ExitSuccess, out, _) -> validSha (T.strip (T.pack out))
    Right (ExitFailure _, _, _) -> Nothing
 where
  -- 不走 shell(免 quoting 問題);cwd 釘在目標專案而非 knot 自己的工作目錄
  gitRevParse = (proc "git" ["rev-parse", "HEAD"]) { cwd = Just root }

-- | 合法 commit sha:全部字元落在 @0-9a-f@ 且長度為 40(SHA-1)或 64
-- (SHA-256 repo);不合就當偵測失敗(假設 A6)。
validSha :: Text -> Maybe Text
validSha t
  | T.length t `elem` [40, 64]
  , T.all isHexLower t = Just t
  | otherwise          = Nothing
 where
  isHexLower c = isDigit c || (c >= 'a' && c <= 'f')
