-- | 目標專案 git 狀態的偵測(Level 2 契約「使用的技術」:在 @rootDir@ 執行、
-- 對目標專案唯讀、失敗即當作沒有答案)。
--
-- 兩件事:'detectCommit' 給 @built_at_commit@ 的值(匯出面,F001);
-- 'detectDirtySources' 給「工作區有沒有未提交的 Haskell 改動」(G-E008,
-- 查詢面的新鮮度提示用)。__兩者都經 "Knot.Export" 對外__——
-- exe 只依賴公開 library(ADR-004),而「怎麼問 git」這個知識只住在這裡。
--
-- 全程不印任何訊息:'readCreateProcessWithExitCode' 會__捕獲__ git 的 stderr,
-- 非 repo 時的 @fatal: not a git repository@ 不會外流(驗收標準 3 的「無警告」
-- 與委派決策 D8 的「library 全程不印」)。
module Knot.Export.Commit
  ( detectCommit
  , detectDirtySources   -- G-E008
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

-- | 工作區是否存在__未提交的 Haskell 原始碼改動__(G-E008)。
--
-- 在 @root@ 執行唯讀的 git 查詢,只看 @.hs@ 檔:tracked 檔被修改或刪除、
-- 以及未追蹤的新 @.hs@ 檔,都算;被 @.gitignore@ 排除者不算,@.hs@ 以外的
-- 檔案(@.cabal@、文件、@codegraph.json@ 自己)一律不算——後者常年未追蹤,
-- 算進去會讓提示恆真而變成噪音。
--
-- 任何失敗——git 不在 PATH 或 @root@ 不存在('IOException')、非 repo
-- ('ExitFailure')——一律回 'False' 且__不印任何訊息__:偵測不到就當作沒有
-- 證據說它髒,不製造假警報(與 'detectCommit' 的失敗語意一致)。
detectDirtySources :: FilePath -> IO Bool
detectDirtySources root = do
  outcome <- try (readCreateProcessWithExitCode gitStatus "")
  pure $ case outcome of
    Left (_ :: IOException)     -> False
    Right (ExitSuccess, out, _) -> any dirtyHsLine (lines out)
    Right (ExitFailure _, _, _) -> False
 where
  -- 唯讀;預設(不加 --ignored)本來就不列出被 .gitignore 排除的檔案
  gitStatus =
    (proc "git" ["status", "--porcelain", "--untracked-files=normal"])
      { cwd = Just root }

-- | 一行 @git status --porcelain@ 是否算一筆 law L7 的 @.hs@ 改動:
-- 未追蹤(@??@)、修改(@M@)或刪除(@D@)其一,且落在的路徑以 @.hs@ 結尾。
-- rename 的一行是 @old -> new@,只看新路徑。
dirtyHsLine :: String -> Bool
dirtyHsLine line = case T.pack line of
  t -> case T.splitAt 2 t of
    (code, rest0)
      | not (T.null rest0) ->
          let rest = T.stripStart rest0
              path = currentPath rest
          in  statusCounts code && T.pack ".hs" `T.isSuffixOf` T.stripEnd path
      | otherwise -> False

statusCounts :: Text -> Bool
statusCounts code =
  code == T.pack "??"
    || T.pack "M" `T.isInfixOf` code
    || T.pack "D" `T.isInfixOf` code

-- | @old -> new@(rename/copy)只取新路徑;其餘原樣。
currentPath :: Text -> Text
currentPath t = case T.breakOn (T.pack " -> ") t of
  (_, arrow) | not (T.null arrow) -> T.drop 4 arrow
  _                                -> t

-- | 合法 commit sha:全部字元落在 @0-9a-f@ 且長度為 40(SHA-1)或 64
-- (SHA-256 repo);不合就當偵測失敗(假設 A6)。
validSha :: Text -> Maybe Text
validSha t
  | T.length t `elem` [40, 64]
  , T.all isHexLower t = Just t
  | otherwise          = Nothing
 where
  isHexLower c = isDigit c || (c >= 'a' && c <= 'f')
