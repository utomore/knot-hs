-- | source-index 模組:檔案樹走訪、component 歸類、module 對映、排除判定。
--
-- F002 cabal-components 落實判定規則 1(kind 排除)、2(一對多歸類與納入
-- 判定)、3(精確 module 對映,取最長命中 hs-source-dirs)、7(決定性)。
-- 無 owner 的檔案退回 S1 的大寫尾綴法與路徑啟發式(F002 假設 A5)。
module Knot.Meta.SourceIndex
  ( indexSources
    -- * 內部純函數(非 Level 2 契約面;1-to-1 測試與 hie-locate 取用)
  , moduleNameFromPath
  , moduleNameFromPathExt
  ) where

import Control.Exception (IOException, try)
import Data.Char (isUpper)
import Data.List (intercalate, isPrefixOf, nub, sort, sortOn)
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (splitDirectories, stripExtension, takeExtension, (</>))

import Knot.Meta.Types
  ( ComponentKind (..)
  , ComponentMeta (..)
  , ComponentRef (..)
  , MetaOptions (..)
  , MetaWarning (..)
  , ModuleName (..)
  , PackageMeta (..)
  , SourceFile (..)
  )

-- | DFS 走訪 root 檔案樹(每層排序),每個 .hs 檔依 @[PackageMeta]@ 的
-- component hs-source-dirs 做一對多歸類;產出前以 @sfPath@ 碼位序排序。
--
-- 收到的 @[PackageMeta]@ 應已由組裝層錨定為 repo 相對(compSourceDirs
-- 正斜線);kind 排除依 'MetaOptions' 的 @includeTests@ 在此重新判定。
indexSources :: MetaOptions -> [PackageMeta] -> IO ([SourceFile], [MetaWarning])
indexSources opts pkgs = do
  (relPaths, warnings) <- walk (root opts) []
  pure (sortOn sfPath (map toSourceFile relPaths), warnings)
 where
  -- 順序 = pmPackages 序 × pkgComponents 序 × compSourceDirs 序(決定性)
  ownerIndex =
    [ (ComponentRef (pkgName p, compName c), compKind c, dirSegs d)
    | p <- pkgs, c <- pkgComponents p, d <- compSourceDirs c
    ]
  dirSegs d = case splitDirectories d of
    ["."] -> []              -- "." 視為根(恆命中)
    segs  -> segs
  -- 判定規則 1:kind 排除
  excludedKind k = k `elem` [TestSuite, Benchmark] && not (includeTests opts)

  toSourceFile segs =
    let path    = intercalate "/" segs   -- 正斜線重組:Windows 反斜線在此消除
        matches = [m | m@(_, _, dsegs) <- ownerIndex, dsegs `dirPrefixOf` segs]
    in SourceFile
         { sfPath     = path
         , sfModule   = case matches of
             [] -> moduleNameFromPath path            -- S1 尾綴法退回(假設 A5)
             _  -> modFromSegs (longestDir matches) segs   -- 規則 3
         , sfOwners   = nub [ref | (ref, _, _) <- matches]     -- 規則 2(保序去重)
         , sfIncluded = case matches of
             [] -> includedByHeuristic (includeTests opts) segs    -- S1 規則 4 退回
             _  -> any (\(_, k, _) -> not (excludedKind k)) matches -- 規則 1 + 2
         }
  -- dir 的段序列為 path 段序列的前綴,且 path 還有剩餘段
  dirPrefixOf dsegs segs = dsegs `isPrefixOf` segs && length segs > length dsegs
  -- 規則 3:取命中的最長 hs-source-dirs(段數相同代表同一個 dir)
  longestDir matches =
    let allDirs = [dsegs | (_, _, dsegs) <- matches]
    in foldr (\d acc -> if length d > length acc then d else acc) [] allDirs

-- | 規則 3 的精確 module 對映(純函數):path 去掉所屬 dir 的前綴段、
-- 末段去 .hs 副檔名,剩餘每段首字元必須大寫,以 "." 連接;否則 Nothing。
modFromSegs :: [FilePath] -> [FilePath] -> Maybe ModuleName
modFromSegs dsegs segs = do
  let rest = drop (length dsegs) segs
  file <- case reverse rest of
    []       -> Nothing
    (f : _)  -> Just f
  stem <- stripExtension "hs" file
  let parts = take (length rest - 1) rest <> [stem]
  if all upperSeg parts
    then Just (ModuleName (T.pack (intercalate "." parts)))
    else Nothing
 where
  upperSeg (c : _) = isUpper c
  upperSeg []      = False

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
moduleNameFromPath = moduleNameFromPathExt "hs"

-- | 大寫尾綴法的共用實作,第一參數為副檔名(不含點)。
--
-- source-index 的 @.hs@ 與 hie-locate 的 @.hie@ 是同一條規則、只差副檔名;
-- 兩份副本會各自漂移(G-E001 現況分析 (2)),故收斂於此。相依方向
-- source-index → hie-locate 與資料流管線同向。
moduleNameFromPathExt :: String -> FilePath -> Maybe ModuleName
moduleNameFromPathExt ext path =
  case reverse (splitDirectories path) of
    [] -> Nothing
    (file : revDirs) -> do
      stem <- stripExtension ext file
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
