-- | 目標專案 git 狀態的偵測(Level 2 契約「使用的技術」:在 @rootDir@ 執行、
-- 對目標專案唯讀、失敗即當作沒有答案)。
--
-- 兩件事:'detectCommit' 給 @built_at_commit@ 的值(匯出面,F001);
-- 'detectDirtySources' 給「工作區有沒有未提交的 Haskell 改動」(G-E008,
-- 查詢面的新鮮度提示用)。__兩者都經 "Knot.Export" 對外__——
-- exe 只依賴公開 library(ADR-004),而「怎麼問 git」這個知識只住在這裡。
--
-- 全程不印任何訊息:git 的 stderr 一律被__捕獲__(前者走
-- 'readCreateProcessWithExitCode',後者自己開 pipe 讀掉),非 repo 時的
-- @fatal: not a git repository@ 不會外流(驗收標準 3 的「無警告」與委派決策
-- D8 的「library 全程不印」)。
--
-- 兩者讀輸出的方式不同,原因是編碼(B002):'detectCommit' 只讀 40\/64 位的
-- hex sha,locale 解碼不會出事;'detectDirtySources' 讀的是__路徑__,可能含
-- 非 ASCII,必須走 binary pipe 自己做 lenient UTF-8 解碼。
module Knot.Export.Commit
  ( detectCommit
  , detectDirtySources   -- G-E008
  ) where

import Control.Exception (IOException, try)
import qualified Data.ByteString as BS
import Data.Char (isDigit)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.Exit (ExitCode (..))
import System.IO (hClose, hSetBinaryMode)
import System.Process
  ( CreateProcess (..)
  , StdStream (CreatePipe)
  , createProcess
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
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
-- 在 @root@ 執行唯讀的 git 查詢,只看 @.hs@ 檔:__工作區側與 index 側的任何
-- 一種未提交狀態都算__——修改、刪除、新增(已 @git add@)、改名、複製、
-- 衝突未解,以及未追蹤的新檔(B002)。被 @.gitignore@ 排除者不算,@.hs@ 以外的
-- 檔案(@.cabal@、文件、@codegraph.json@ 自己)一律不算——後者常年未追蹤,
-- 算進去會讓提示恆真而變成噪音。
--
-- 任何失敗——git 不在 PATH 或 @root@ 不存在('IOException')、非 repo
-- ('ExitFailure')——一律回 'False' 且__不印任何訊息__:偵測不到就當作沒有
-- 證據說它髒,不製造假警報(與 'detectCommit' 的失敗語意一致)。
detectDirtySources :: FilePath -> IO Bool
detectDirtySources root = do
  outcome <- try runGitStatus
  pure $ case outcome of
    Left (_ :: IOException)  -> False
    Right (ExitSuccess, out) -> any dirtyHsLine (T.lines out)
    Right (ExitFailure _, _) -> False
 where
  -- __不能用 'readCreateProcessWithExitCode'__(B002 根因二):它以 locale 編碼
  -- 解碼子程序輸出,而 git 吐的是 UTF-8。Windows 非 UTF-8 codepage(實測
  -- @CP950@)碰到中文路徑會拋 @hGetContents: invalid argument@,被上面的 'try'
  -- 吞掉之後__整份 status 都不見了__——repo 裡任何一個非 ASCII 路徑都會讓這個
  -- 函式恆回 'False'。改走 binary pipe + lenient UTF-8,與 build-driver 讀 cabal
  -- 輸出的既有作法一致。
  --
  -- stderr 另開一條 pipe 讀掉但不解析:git 的訊息不該混進判定,也不能印出來
  -- (契約:全程不印)。先讀完 stdout 再讀 stderr 不會卡死——@git status@ 的
  -- stderr 只在失敗時有寥寥數行,填不滿 pipe 緩衝區。
  runGitStatus = do
    (_, mOut, mErr, ph) <- createProcess gitStatus
    case (mOut, mErr) of
      (Just hOut, Just hErr) -> do
        hSetBinaryMode hOut True
        hSetBinaryMode hErr True
        bs <- BS.hGetContents hOut
        _  <- BS.hGetContents hErr
        hClose hOut
        hClose hErr
        code <- waitForProcess ph
        pure (code, TE.decodeUtf8With lenientDecode bs)
      _ -> do
        code <- waitForProcess ph
        pure (code, T.empty)
  -- 唯讀;預設(不加 --ignored)本來就不列出被 .gitignore 排除的檔案。
  -- @core.quotePath=false@:git 預設會把非 ASCII 路徑轉義成 @"\344\270\255…"@
  -- 並前後加引號,副檔名比對會落空(B002 根因二)。只影響輸出編碼,不改語意
  gitStatus =
    (proc "git"
      [ "-c", "core.quotePath=false"
      , "status", "--porcelain", "--untracked-files=normal"
      ])
      { cwd = Just root, std_out = CreatePipe, std_err = CreatePipe }

-- | 一行 @git status --porcelain@ 是否算一筆 @.hs@ 改動:狀態碼表示某種未提交的
-- 改動,且路徑以 @.hs@ 結尾。rename \/ copy 的一行是 @old -> new@,只看新路徑。
dirtyHsLine :: Text -> Bool
dirtyHsLine t = case T.splitAt 2 t of
  (code, rest0)
    | not (T.null rest0) ->
        let path = currentPath (T.stripStart rest0)
        in  statusCounts code && T.pack ".hs" `T.isSuffixOf` T.stripEnd path
    | otherwise -> False

-- | porcelain v1 的兩欄狀態碼(index 側、工作區側)是否表示某種未提交的改動。
--
-- __列排除、不列白名單__(B002):原本只認 @??@ 與含 @M@ \/ @D@ 的碼,結果
-- @A@(已 @git add@ 的新檔)、@R@(改名)、@C@(複製)、@U@(衝突未解)全部漏掉
-- ——它們每一種都是未提交的改動。改成「兩欄任一不是『未修改』就算」之後,
-- 日後 git 新增狀態碼也不會再漏一次。
--
-- 兩個特例:@??@(未追蹤)算改動;@!!@(ignored)不算——後者只有加 @--ignored@
-- 才會出現,這裡沒加,列著是防禦性的。
statusCounts :: Text -> Bool
statusCounts code
  | code == T.pack "!!" = False
  | code == T.pack "??" = True
  | otherwise           = T.any (/= ' ') code

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
