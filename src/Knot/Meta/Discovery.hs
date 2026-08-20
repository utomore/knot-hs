-- | discovery 模組:定位 .cabal 檔。
--
-- F002 cabal-components:支援 @cabal.project@ 的 @packages@ /
-- @optional-packages@ 多套件列表(以 'readFields' 解析——cabal.project
-- 沒有公開的專用解析器,那部分在 cabal-install);無 @cabal.project@ 或
-- 解析失敗時退回 S1 的根目錄 @*.cabal@ 行為。glob(含 @*@ 的 entry)
-- 不展開,出警告並略過(F002 假設 A2);@import:@ 不追隨(F002 假設 A4)。
module Knot.Meta.Discovery
  ( findCabalFiles
  ) where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Containers.ListUtils (nubOrd)
import Data.List (sort)
import qualified Data.Text as T
import Distribution.Fields.Field (Field (..), FieldLine (..), Name (..))
import Distribution.Fields.Parser (readFields)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (normalise, takeExtension, (</>))

import Knot.Meta.Types (MetaWarning (..))

-- | .cabal 檔定位。有 @cabal.project@ 時展開其 @packages@ /
-- @optional-packages@;否則(或 cabal.project 讀不到/解析不了,附警告)
-- 退回根目錄 @*.cabal@ 掃描。回傳 repo 相對正斜線路徑,
-- @nubOrd@ 去重 + 碼位序排序(決定性);找不到任何 .cabal → 一則警告。
findCabalFiles :: FilePath -> IO ([FilePath], [MetaWarning])
findCabalFiles dir = do
  let projPath = dir </> "cabal.project"
  hasProject <- doesFileExist projPath
  if not hasProject
    then rootScan dir
    else do
      readResult <- try (BS.readFile projPath)
      case readResult of
        Left (e :: IOException) ->
          degrade dir ("cannot read cabal.project: " <> show e)
        Right bs ->
          case readFields bs of
            Left perr ->
              degrade dir ("cannot parse cabal.project: " <> show perr)
            Right fields -> expandProject dir fields

-- | cabal.project 讀不到/解析不了:警告 + 退回 S1 根目錄掃描。
degrade :: FilePath -> String -> IO ([FilePath], [MetaWarning])
degrade dir msg = do
  (found, ws) <- rootScan dir
  pure (found, MetaWarning (toSlash (dir </> "cabal.project")) (T.pack msg) : ws)

-- | S1(F001)行為:根目錄 @*.cabal@ 定位。
rootScan :: FilePath -> IO ([FilePath], [MetaWarning])
rootScan dir = do
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

-- | 展開 @packages@ / @optional-packages@ 的每個 entry;
-- 警告序 = entry 出現序,清單經 @nubOrd@ + @sort@(決定性)。
expandProject :: FilePath -> [Field ann] -> IO ([FilePath], [MetaWarning])
expandProject dir fields = do
  results <- mapM (uncurry expandEntry) entries
  let found = nubOrd (sort (concatMap fst results))
      ws    = concatMap snd results
  if null found
    then pure ([], ws <> [MetaWarning dir (T.pack "no .cabal file found")])
    else pure (found, ws)
 where
  entries =
    [ (entry, optional)
    | Field (Name _ fname) fls <- fields
    , Just optional <- [fieldKind fname]
    , fl <- fls
    , entry <- splitEntries fl
    ]
  fieldKind n
    | n == BS8.pack "packages"          = Just False
    | n == BS8.pack "optional-packages" = Just True
    | otherwise                         = Nothing
  -- cabal 的兩種寫法都收:逗號分隔與空白/換行分隔
  splitEntries (FieldLine _ bs) =
    filter (not . null)
      (words (map (\c -> if c == ',' then ' ' else c) (BS8.unpack bs)))

  expandEntry entry optional
    | '*' `elem` entry =
        -- 明確不支援 glob(F002 假設 A2)
        pure ([], [MetaWarning entry (T.pack "glob patterns in cabal.project packages are not supported; entry skipped")])
    | takeExtension entry == ".cabal" = do
        exists <- doesFileExist (dir </> entry)
        if exists
          then pure ([normRel entry], [])
          else missing entry optional "listed .cabal file not found"
    | otherwise = do
        isDir <- doesDirectoryExist (dir </> entry)
        if isDir
          then do
            listed <- try (listDirectory (dir </> entry))
            case listed of
              Left (e :: IOException) ->
                pure ([], [MetaWarning (normRel entry) (T.pack ("cannot read directory: " <> show e))])
              Right names ->
                pure ( [ normRel (entry </> n)
                       | n <- sort names, takeExtension n == ".cabal" ]
                     , [])
          else missing entry optional "listed package directory not found"
  -- packages 的缺項出警告;optional-packages 靜默略過
  missing entry optional what
    | optional  = pure ([], [])
    | otherwise = pure ([], [MetaWarning entry (T.pack what)])
  normRel = toSlash . normalise

toSlash :: FilePath -> FilePath
toSlash = map (\c -> if c == '\\' then '/' else c)
