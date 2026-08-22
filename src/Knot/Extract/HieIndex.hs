-- | hie-index 模組:以__內嵌__的 hiedb library 把 F005 列舉出的 @.hie@
-- 增量索引進 @\<root\>\/.knot\/hiedb.sqlite@ → 就緒的索引。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「模組間公開介面」
-- 的 'ensureIndex' 與 'IndexHandle';落實抽取規則 1(@.hie@ 清單來自
-- 'HieLayout')、7(索引固定住在 @.knot\/@)、8(GHC 版本相容:__依路徑段__
-- 判定)、9(單檔 best-effort)。取代 F003 的 @Knot.Extract.HiedbDriver@
-- (ADR-006:hiedb 不再是使用者要自己安裝的外部執行檔)。
--
-- __不做__:不建置(build-driver 的事)、不讀索引出事實(hiedb-facts 的事)、
-- 不自己解析 @.hie@ 的內容(全交給 hiedb)、不自動重建 schema 不合的舊索引
-- (訊息指明刪檔重跑,見 'describeIndexError')。
--
-- __本模組全程不印任何輸出__:提示一律走 'ihNotes'。
--
-- == 版本判定為什麼看路徑不讀檔頭(規則 8)
--
-- cabal 的 builddir 佈局是 @build\/\<arch\>\/ghc-\<ver\>\/…@,版本就寫在路徑上。
-- 一份 knot 連結的是__它自己那一版__ GHC 的 @ghc@ library,只讀得懂同版的
-- @.hie@;其他版本目錄是使用者升級 GHC 後留下的殘骸(cabal 不會再碰),
-- 略過即可。零個相符才是真的版本不合 → 'VersionMismatch',@vmHie@ 帶
-- 觀察到的版本讓 CLI 印出 @cabal install knot-hs -w ghc-\<ver\>@。
module Knot.Extract.HieIndex
  ( -- * Level 2 模組介面
    ensureIndex
  , IndexHandle
  , ihDbPath
  , ihRootDir
  , ihStats
  , ihNotes
  , IndexStats (..)
    -- * 站名常數(非契約面:@ewSource@ 的值域是契約,具名常數本身不是)
  , hiedbName
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , ownGhcVersion
  , ghcVersionOfPath
  , partitionByGhc
  , indexDbPath
  ) where

import Control.Exception (SomeException, displayException, fromException, try)
import Data.Char (isDigit)
import Data.IORef (newIORef)
import Data.List (nub, sort)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import Data.Version (showVersion)
import Database.SQLite.Simple (Only (..), Query (..), query_)
import System.Directory (createDirectoryIfMissing, makeAbsolute)
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.Info (fullCompilerVersion)

import HieDb
  ( DbMonad
  , HieDb
  , HieDbException (..)
  , SkipOptions (..)
  , addRefsFrom
  , defaultSkipOptions
  , deleteFileFromIndex
  , deleteMissingRealFiles
  , getConn
  , makeNc
  , runDbM
  , withHieDb
  )

import Knot.Extract.Types
  ( ExtractFailure (..)
  , ExtractOptions (..)
  , ExtractWarning (..)
  , HieLayout (..)
  )
import Knot.Meta.Types (ComponentRef)

--------------------------------------------------------------------------------
-- 公開型別
--------------------------------------------------------------------------------

-- | hiedb 兩站(hie-index、hie-facts)共用的契約名(即 @ewSource@ 的值域之一)。
-- F007 自 @Knot.Extract.Backend@ 搬來;hie-facts 本來就 import 本模組。
hiedbName :: Text
hiedbName = T.pack "hiedb"

-- | 「已就緒索引」的不透明參照(Level 2 契約:內容屬 Level 3)。
-- 只能由 'ensureIndex' 取得,欄位一律經存取子讀取——建構子不匯出。
data IndexHandle = IndexHandle
  { unDbPath  :: FilePath
  , unRootDir :: FilePath
  , unStats   :: IndexStats
  , unNotes   :: [ExtractWarning]
  }

-- | 索引 SQLite 的__絕對__路徑(hiedb-facts 開 DB 用)。
ihDbPath :: IndexHandle -> FilePath
ihDbPath = unDbPath

-- | 專案根目錄,__照 'ExtractOptions.rootDir' 原樣__(hiedb-facts 把來源路徑
-- 對回 repo 相對用)。
ihRootDir :: IndexHandle -> FilePath
ihRootDir = unRootDir

-- | 本次索引的觀測值。__不進事實流__,故不受決定性規則拘束
-- (第一次與第二次本來就不同,那正是增量索引的證據)。
ihStats :: IndexHandle -> IndexStats
ihStats = unStats

-- | 本次執行產生的警告(規則 9:單檔讀不過的那些)。由 hiedb-facts 併入
-- 回傳的 @[ExtractWarning]@,最終經 @ExtractResult.erWarnings@ 由 CLI 印出。
ihNotes :: IndexHandle -> [ExtractWarning]
ihNotes = unNotes

-- | 本次 'ensureIndex' 的索引統計。
data IndexStats = IndexStats
  { indexedCount :: Int   -- ^ 本次真的索引的 .hie 數
  , skippedCount :: Int   -- ^ 雜湊未變、hiedb 判定重用的 .hie 數
  }
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- 版本判定(純函數)
--------------------------------------------------------------------------------

-- | 本執行檔自身的 GHC 版本,如 @\"9.14.1\"@;與 cabal builddir 路徑段
-- @ghc-\<ver\>@ 的 @\<ver\>@ 格式一致,可直接字串比對。
ownGhcVersion :: Text
ownGhcVersion = T.pack (showVersion fullCompilerVersion)

-- | 從 @.hie@ 路徑取出 cabal builddir 的 @ghc-\<ver\>@ 段。取__第一個__形如
-- @ghc-@ + 純數字與點的段(套件段如 @ghc-lib-parser-9.14.1@ 因含字母不會誤判,
-- 且永遠排在編譯器段之後);沒有 → 'Nothing'。
ghcVersionOfPath :: FilePath -> Maybe Text
ghcVersionOfPath p =
  case [ v | seg <- splitDirectories p, Just v <- [versionSeg seg] ] of
    (v : _) -> Just v
    []      -> Nothing
 where
  versionSeg seg = case splitAt 4 seg of
    ("ghc-", rest) | not (null rest), all (\c -> isDigit c || c == '.') rest
      -> Just (T.pack rest)
    _ -> Nothing

-- | 規則 8 的判定:把 'HieLayout' 切成「版本與 @own@ 相符者」與
-- 「觀察到的其他版本(去重、字典序)」。沒有版本段的檔既不相符也不計入
-- 其他版本(由 'ensureIndex' 在零相符時分辨兩種空集合)。
partitionByGhc :: Text -> HieLayout -> ([(ComponentRef, FilePath)], [Text])
partitionByGhc own layout = (matching, others)
 where
  tagged   = [ (entry, ghcVersionOfPath (snd entry)) | entry <- hlFiles layout ]
  matching = [ entry | (entry, Just v) <- tagged, v == own ]
  others   = sort (nub [ v | (_, Just v) <- tagged, v /= own ])

-- | 規則 7 的索引位置:@\<root\>\/.knot\/hiedb.sqlite@。純函數,不碰檔案系統。
indexDbPath :: FilePath -> FilePath
indexDbPath root = root </> ".knot" </> "hiedb.sqlite"

--------------------------------------------------------------------------------
-- 索引就緒
--------------------------------------------------------------------------------

-- | 確保索引就緒(Level 2 模組介面,簽名照契約)。__不抛例外__:索引檔
-- 整體層級的失敗收斂成 @Left (IndexFailed …)@,單檔失敗進 'ihNotes'。
ensureIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure IndexHandle)
ensureIndex opts layout =
  case (hlFiles layout, matching, others) of
    ([], _, _) -> pure . Left . IndexFailed $ T.pack
      ("the build produced no .hie files under " <> hlRoot layout)
    (_, [], _ : _) -> pure . Left $ VersionMismatch
      { vmHie = T.intercalate (T.pack ", ") others, vmKnot = ownGhcVersion }
    (_, [], []) -> pure . Left . IndexFailed $ T.pack
      ("no .hie path under " <> hlRoot layout
        <> " carries a ghc-<version> segment; unexpected build layout")
    _ -> do
      outcome <- try (indexFiles opts (map snd matching))
      pure $ case outcome of
        Left e  -> Left (IndexFailed (describeIndexError e))
        Right h -> Right h
 where
  (matching, others) = partitionByGhc ownGhcVersion layout

-- | 開索引、逐檔增量索引、清理。任何例外往上拋給 'ensureIndex' 收斂。
indexFiles :: ExtractOptions -> [FilePath] -> IO IndexHandle
indexFiles opts files = do
  rootAbs <- makeAbsolute (rootDir opts)
  let db       = indexDbPath rootAbs
      absFiles = map (rootAbs </>) files
  -- .knot/ 正常由 build-driver 先建好;這裡補一手讓 ensureIndex 單獨呼叫也安全。
  -- 位置被同名檔案佔住時這裡就拋(createDirectoryIfMissing 會重拋非目錄的情況)。
  createDirectoryIfMissing True (takeDirectory db)
  withHieDb db $ \hdb -> do
    nc <- newIORef =<< makeNc
    results <- mapM (indexOne hdb (runDbM nc) rootAbs) absFiles
    -- 清理:索引裡不屬於本次清單的 .hie(舊版目錄、已刪 component 的殘骸),
    -- 以及原始檔已不存在的列。
    rows <- query_ (getConn hdb) (Query (T.pack "SELECT hieFile FROM mods")) :: IO [Only FilePath]
    let keep = Set.fromList absFiles
    mapM_ (deleteFileFromIndex hdb) [ f | Only f <- rows, not (Set.member f keep) ]
    deleteMissingRealFiles hdb
    pure IndexHandle
      { unDbPath  = db
      , unRootDir = rootDir opts
      , unStats   = IndexStats
          { indexedCount = length [ () | Right True  <- results ]
          , skippedCount = length [ () | Right False <- results ]
          }
      , unNotes   = [ w | Left w <- results ]
      }

-- | 單檔索引(規則 9):hiedb 以檔案雜湊判斷是否已索引過;讀不過的檔
-- 收斂成一則警告,不影響其他檔。每檔各自一個 'runDbM' 以便逐檔包 'try'。
indexOne
  :: HieDb -> (DbMonad Bool -> IO Bool) -> FilePath -> FilePath
  -> IO (Either ExtractWarning Bool)
indexOne hdb run rootAbs path = do
  r <- try (run (addRefsFrom hdb (Just rootAbs) skipOpts path))
  pure $ case r of
    Right indexed -> Right indexed
    Left e        -> Left ExtractWarning
      { ewSource  = hiedbName
      , ewMessage = T.pack ("cannot index " <> path <> ": ")
                      <> T.pack (firstLine (displayException (e :: SomeException)))
      }

-- | knot 只讀 @mods@ \/ @decls@ \/ @defs@ \/ @refs@ 四張表;其餘四張跳過
-- (@types@ \/ @typerefs@ 是索引時間的大頭,@exports@ \/ @imports@ 零消費者——
-- import 邊永遠來自 import-scan,規則 2)。
skipOpts :: SkipOptions
skipOpts = defaultSkipOptions
  { skipTypes    = True
  , skipTypeRefs = True
  , skipExports  = True
  , skipImports  = True
  }

-- | 索引檔整體層級的失敗說明。schema 不合時指明修法(本模組不擅自刪檔)。
describeIndexError :: SomeException -> Text
describeIndexError e = case fromException e of
  Just (IncompatibleSchemaVersion expected got) -> T.pack
    ("index schema version " <> show got <> " does not match the version "
      <> show expected <> " this build of knot expects; delete .knot/hiedb.sqlite and rerun")
  Nothing -> T.pack (firstLine (displayException e))

firstLine :: String -> String
firstLine = takeWhile (`notElem` "\r\n")
