-- | source-index 模組:檔案樹走訪、大寫尾綴 module 對映、路徑啟發式排除。
--
-- S1(F001)落實判定規則 3(大寫尾綴法)、4(路徑啟發式排除)、7(決定性)。
module Knot.Meta.SourceIndex
  ( indexSources
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , moduleNameFromPath
  ) where

import Control.Exception (IOException, try)
import Data.Char (isUpper)
import Data.List (intercalate, sort, sortOn)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (splitDirectories, stripExtension, takeExtension, (</>))

import Knot.Meta.Types
  ( MetaOptions (..)
  , MetaWarning (..)
  , ModuleName (..)
  , PackageMeta
  , SourceFile (..)
  )

-- | S1:第二參數恆收 @[]@,@sfOwners@ 恆為 @[]@。
-- DFS 走訪 root 檔案樹,每層排序;產出前以 @sfPath@ 碼位序排序(決定性)。
indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])
indexSources opts _pkgs = do
  (relPaths, warnings) <- walk (root opts) []
  pure (sortOn sfPath (map toSourceFile relPaths), warnings)
 where
  toSourceFile segs =
    let path = intercalate "/" segs   -- 正斜線重組:Windows 反斜線在此消除
    in SourceFile
         { sfPath     = path
         , sfModule   = moduleNameFromPath path
         , sfOwners   = []
         , sfIncluded = includedByHeuristic (includeTests opts) segs
         }

-- | 走訪一層:回傳(命中 .hs 檔的相對路徑段清單, 警告)。
-- 讀不到的目錄降級為 'MetaWarning' + 跳過,不中斷(best-effort)。
walk :: FilePath -> [FilePath] -> IO ([[FilePath]], [MetaWarning])
walk dir relSegs = do
  listed <- try (listDirectory dir)
  case listed of
    Left (e :: IOException) ->
      pure ([], [MetaWarning (relLabel relSegs) (T.pack ("cannot read directory: " <> show e))])
    Right entries -> do
      results <- mapM step (sort entries)   -- 每層排序後走訪(決定性)
      pure (concatMap fst results, concatMap snd results)
 where
  step name = do
    let full = dir </> name
    isDir <- doesDirectoryExist full
    if isDir
      then
        if skipDir name
          then pure ([], [])
          else walk full (relSegs ++ [name])
      else
        if takeExtension name == ".hs"   -- 僅 .hs,不含 .lhs(F001 假設 A4)
          then pure ([relSegs ++ [name]], [])
          else pure ([], [])
  relLabel [] = "."
  relLabel segs = intercalate "/" segs

-- | D4 略過清單(依 basename):「.」開頭的隱藏目錄(涵蓋 .git、.stack-work、
-- .hie、.design)、dist-newstyle。
skipDir :: FilePath -> Bool
skipDir ('.' : _) = True
skipDir name      = name == "dist-newstyle"

-- | 判定規則 3 的 S1 大寫尾綴法(純函數,不做 IO):
-- 末段去 .hs 副檔名後,從尾端往前取最長的、每段皆大寫開頭的連續段序列,
-- 以 "." 連接;末段本身非大寫開頭 → Nothing。
moduleNameFromPath :: FilePath -> Maybe ModuleName
moduleNameFromPath path =
  case reverse (splitDirectories path) of
    [] -> Nothing
    (file : revDirs) -> do
      stem <- stripExtension "hs" file
      if upperSeg stem
        then Just (ModuleName (T.pack (intercalate "."
               (reverse (stem : takeWhile upperSeg revDirs)))))
        else Nothing
 where
  upperSeg (c : _) = isUpper c
  upperSeg []      = False

-- | 判定規則 4 的 S1 路徑啟發式:第一個路徑段 ∈ {test, tests, bench} 的
-- 目錄下檔案視為排除,sfIncluded = includeTests;其餘恆 True。
includedByHeuristic :: Bool -> [FilePath] -> Bool
includedByHeuristic incl (top : _ : _)
  | top `elem` ["test", "tests", "bench"] = incl
includedByHeuristic _ _ = True
