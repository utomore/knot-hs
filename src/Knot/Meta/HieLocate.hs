-- | hie-locate 模組:三層 .hie 發現、.hie 檔列舉、幽靈過濾。
--
-- F003 hie-discovery 落實判定規則 5(三層發現順序:hieDirOverride >
-- \<root\>\/.hie > 遞迴掃 dist-newstyle)、6(幽靈判定)、7(決定性);
-- 錯誤策略 best-effort(讀不到的子目錄降級為警告 + 跳過)。
-- 不讀 .hie 檔內容、不觸發編譯、不比 mtime;對目標專案一律唯讀。
module Knot.Meta.HieLocate
  ( locateHie
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , moduleNameFromHiePath
  ) where

import Control.Exception (IOException, try)
import Data.List (intercalate, sort)
import qualified Data.Set as Set
import qualified Data.Text as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath
  ( isRelative
  , makeRelative
  , splitDirectories
  , takeExtension
  , (</>)
  )

import Knot.Meta.SourceIndex (moduleNameFromPathExt)
import Knot.Meta.Types
  ( HieDirSource (..)
  , HieInfo (..)
  , MetaOptions (..)
  , MetaWarning (..)
  , ModuleName (..)
  , SourceFile (..)
  )

-- | 三層 .hie 發現(規則 5)、列舉、幽靈過濾(規則 6)、決定性(規則 7)。
--
-- 警告順序固定:層級判定警告 → 列舉走訪警告(走訪序)→
-- 幽靈\/無法對映警告(依排序後清單序)。三層皆未命中 → @(Nothing, [])@
-- (無 .hie 是常態,不出警告;F003 假設 A3)。
locateHie :: MetaOptions -> [SourceFile] -> IO (Maybe HieInfo, [MetaWarning])
locateHie opts sources = case hieDirOverride opts of
  Just d  -> tierFlag d
  Nothing -> do
    convExists <- doesDirectoryExist (root opts </> ".hie")
    if convExists
      then adoptDir FromConvention (root opts </> ".hie") ".hie" []
      else tierDistNewstyle
 where
  -- 母集:全體 sources 的 sfModule(Just 者),不論 sfIncluded(假設 A6)
  motherSet = Set.fromList [m | sf <- sources, Just m <- [sfModule sf]]

  -- 第 1 層:使用者明示的位置錯了就明說,不 fallback(驗收標準 2)
  tierFlag d = do
    let absDir = if isRelative d then root opts </> d else d   -- 假設 A5
        rel    = makeRelative (root opts) absDir
        (display, outsideWs)
          | isRelative rel = (toSlash rel, [])
          | otherwise      =                                    -- 假設 A7
              ( toSlash absDir
              , [ MetaWarning (toSlash absDir)
                    (T.pack "hie directory lies outside the project root") ] )
    exists <- doesDirectoryExist absDir
    if exists
      then adoptDir FromFlag absDir display outsideWs
      else pure ( Nothing
                , [MetaWarning (toSlash d) (T.pack "hie directory not found")] )

  -- 第 1、2 層共用:採用即成立;列舉為空仍回 Just + 警告(假設 A1)
  adoptDir src absDir display tierWs = do
    (files, walkWs) <- enumerateHie absDir display
    let emptyWs =
          [ MetaWarning display (T.pack "no .hie files found in hie directory")
          | null files
          ]
        (valid, ghosts, classifyWs) = classify motherSet files
    pure ( Just HieInfo
             { hieDir    = display
             , hieSource = src
             , hieFiles  = valid
             , hieGhosts = ghosts
             }
         , tierWs ++ walkWs ++ emptyWs ++ classifyWs )

  -- 第 3 層:找到 >= 1 個 .hie 才採用;hieDir = 最深共同祖先(假設 A4)
  tierDistNewstyle = do
    let absDist = root opts </> "dist-newstyle"
    distExists <- doesDirectoryExist absDist
    if not distExists
      then pure (Nothing, [])
      else do
        (files, walkWs) <- enumerateHie absDist "dist-newstyle"
        if null files
          then pure (Nothing, walkWs)   -- 未命中;走訪警告仍保留(best-effort)
          else do
            let (valid, ghosts, classifyWs) = classify motherSet files
            pure ( Just HieInfo
                     { hieDir    = commonAncestor files
                     , hieSource = FromDistNewstyle
                     , hieFiles  = valid
                     , hieGhosts = ghosts
                     }
                 , walkWs ++ classifyWs )

-- | 幽靈判定(規則 6):排序後逐一分類。
-- 對映到母集 → 有效;對映到但不在母集 → 幽靈 + 警告;
-- 對映不出 → 留置有效清單 + 警告(假設 A2)。
-- 回傳的兩份清單天然承襲碼位序(規則 7)。
classify
  :: Set.Set ModuleName
  -> [FilePath]
  -> ([FilePath], [FilePath], [MetaWarning])
classify mother files = go (sort files) ([], [], [])
 where
  go [] (vs, gs, ws) = (reverse vs, reverse gs, reverse ws)
  go (f : rest) (vs, gs, ws) = case moduleNameFromHiePath f of
    Just m
      | m `Set.member` mother -> go rest (f : vs, gs, ws)
      | otherwise             -> go rest (vs, f : gs, ghostWarning f m : ws)
    Nothing -> go rest (f : vs, gs, unmappableWarning f : ws)
  ghostWarning f (ModuleName m) = MetaWarning f
    (T.pack "ghost .hie file: no source file for module " <> m)
  unmappableWarning f = MetaWarning f
    (T.pack "cannot map .hie path to a module name; kept for extraction")

-- | DFS 走訪(沿用 F001 source-index 模式):每層排序後走訪(決定性)、
-- 僅收 .hie、不略過任何子目錄名、讀不到的子目錄降級為警告 + 跳過。
-- 回傳 repo 相對正斜線路徑(走訪序;排序由 'classify' 統一處理)。
enumerateHie :: FilePath -> FilePath -> IO ([FilePath], [MetaWarning])
enumerateHie absRoot display = walkHie absRoot []
 where
  walkHie dir relSegs = do
    listed <- try (listDirectory dir)
    case listed of
      Left (e :: IOException) ->
        pure ( []
             , [ MetaWarning (joinRel relSegs)
                   (T.pack ("cannot read directory: " <> show e)) ] )
      Right entries -> do
        results <- mapM (step dir relSegs) (sort entries)
        pure (concatMap fst results, concatMap snd results)
  step dir relSegs name = do
    let full = dir </> name
    isDir <- doesDirectoryExist full
    if isDir
      then walkHie full (relSegs ++ [name])
      else if takeExtension name == ".hie"
        then pure ([joinRel (relSegs ++ [name])], [])
        else pure ([], [])
  joinRel segs
    | display == "." = intercalate "/" segs
    | null segs      = display
    | otherwise      = display <> "/" <> intercalate "/" segs

-- | 全部 .hie 檔的最深共同祖先目錄(假設 A4;呼叫端保證清單非空)。
commonAncestor :: [FilePath] -> FilePath
commonAncestor files = intercalate "/" (foldr1 commonPrefix (map parentSegs files))
 where
  parentSegs f = let segs = splitDirectories f in take (length segs - 1) segs
  commonPrefix (a : as) (b : bs) | a == b = a : commonPrefix as bs
  commonPrefix _ _                        = []

-- | .hie 路徑 → module 名(純函數):末段以 @stripExtension "hie"@ 去副檔名,
-- 從尾端往前取最長的、每段首字元大寫的連續段序列,以 "." 連接;
-- 末段非大寫開頭 → Nothing。
--
-- 與 F001 的大寫尾綴法同構、僅副檔名不同,故直接沿用 source-index 的共用
-- 實作(G-E001 M3),不留第二份會漂移的副本。
moduleNameFromHiePath :: FilePath -> Maybe ModuleName
moduleNameFromHiePath = moduleNameFromPathExt "hie"

-- | Windows 反斜線正規化為正斜線。
toSlash :: FilePath -> FilePath
toSlash = map (\c -> if c == '\\' then '/' else c)
