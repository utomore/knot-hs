-- | discovery 模組:定位 .cabal 檔。
--
-- S1(F001):僅定位根目錄 @*.cabal@(repo 相對、正斜線、排序);
-- 不解析內容、不讀 cabal.project(F002 cabal-components 的事)。
module Knot.Meta.Discovery
  ( findCabalFiles
  ) where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.List (sort)
import qualified Data.Text as T
import System.Directory (doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))

import Knot.Meta.Types (MetaWarning (..))

-- | 根目錄 @*.cabal@ 定位。找不到任何 .cabal → 空清單 + 一則警告;
-- 根目錄讀不到 → 空清單 + 警告(best-effort,不中斷)。
findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])
findCabalFiles dir = do
  listed <- try (listDirectory dir)
  case listed of
    Left (e :: IOException) ->
      pure ([], [MetaWarning dir (T.pack ("cannot read directory: " <> show e))])
    Right entries -> do
      -- 根目錄下的檔名不含分隔符,天然滿足「repo 相對、正斜線」
      found <- filterM (\name -> doesFileExist (dir </> name))
                       (sort [n | n <- entries, takeExtension n == ".cabal"])
      if null found
        then pure ([], [MetaWarning dir (T.pack "no .cabal file found")])
        else pure (found, [])
