-- | hiedb-driver 模組:hiedb 執行檔探測、@.hie@ 相容性檢查、執行
-- @hiedb index@、@.knot\/@ 索引檔管理 → 就緒的索引。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「模組間公開介面」
-- 的 'ensureIndex' 與 'IndexHandle',以及 @Backend@ hiedb 實例的__探測面__
-- 'probeHiedb'(型別即 @Backend.bProbe@ 的欄位型別);落實抽取規則
-- 5(兩類不可用的區分回報)、6(@\<root\>\/.knot\/hiedb.sqlite@ 預設位置與
-- @dbPath@ 改道)、7(best-effort)、8(決定性)。
--
-- __不做__:不讀索引內容出事實(hiedb-facts 的事)、不自己解析 @.hie@、
-- 不管理 @.gitignore@(只在首次建立 @.knot\/@ 時__產生__一則提示,
-- 見 'ihNotes')、不清理過期索引。
--
-- __本模組全程不印任何輸出__(委派決策 D4):hiedb 的進度與 @Completed!@
-- 皆走 stderr,'readCreateProcessWithExitCode' 同時捕獲兩股。
--
-- == 降級原因的穩定前綴
--
-- 'Unavailable' 與 @Left@ 的文字以四個固定前綴區分類別(消費端與測試以此
-- 辨別,屬本模組的公開行為):
--
-- * @\"hiedb executable \"@ —— 執行檔不存在 \/ 不可執行(規則 5 第一類)
-- * @\"hie files unavailable: \"@ —— 無 @.hie@ 目錄 \/ 清單為空 \/ 檔頭讀不到
-- * @\"hie\/ghc version mismatch: \"@ —— @.hie@ 由別版 GHC 產出(ADR-001)
-- * @\"hiedb index failed: \"@ —— @hiedb index@ 非零結束或索引檔未生成
--   (只出現在 'ensureIndex' 的 @Left@)
module Knot.Extract.HiedbDriver
  ( -- * Level 2 模組介面
    ensureIndex
  , IndexHandle
  , ihDbPath
  , ihRootDir
  , ihExe
  , ihStats
  , ihNotes
  , IndexStats (..)
    -- * Backend hiedb 實例的探測面
  , probeHiedb
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , defaultDbPath
  , parseIndexStats
  , chunkFileArgs
  ) where

import Control.Exception (IOException, displayException, try)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Version (showVersion)
import qualified Data.Text as T
import Data.Text (Text)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
  , makeAbsolute
  )
import System.Exit (ExitCode (..))
import System.FilePath (isRelative, takeDirectory, (</>))
import System.Info (fullCompilerVersion)
import System.Process
  ( CreateProcess (..)
  , proc
  , readCreateProcessWithExitCode
  )
import Text.Read (readMaybe)

import Knot.Extract.Backend (ProbeResult (..), hiedbName)
import Knot.Extract.Types (ExtractOptions (..), ExtractWarning (..))
import Knot.Meta.Types (HieInfo (..), ProjectMeta (..))

--------------------------------------------------------------------------------
-- 公開型別
--------------------------------------------------------------------------------

-- | 「已就緒索引」的不透明參照(Level 2 契約:內容屬 Level 3)。
-- 只能由 'ensureIndex' 取得,欄位一律經存取子讀取——建構子不匯出。
data IndexHandle = IndexHandle
  { unDbPath  :: FilePath
  , unRootDir :: FilePath
  , unExe     :: FilePath
  , unStats   :: IndexStats
  , unNotes   :: [ExtractWarning]
  }

-- | 索引 SQLite 的__絕對__路徑(hiedb-facts 開 DB 用)。
ihDbPath :: IndexHandle -> FilePath
ihDbPath = unDbPath

-- | 專案根的__絕對__路徑(hiedb-facts 把來源路徑對回 repo 相對用)。
ihRootDir :: IndexHandle -> FilePath
ihRootDir = unRootDir

-- | 本次實際使用的 hiedb 執行檔(回報 \/ 除錯用)。
ihExe :: IndexHandle -> FilePath
ihExe = unExe

-- | 本次 index 的觀測值。__不進事實流__,故不受抽取規則 8(決定性)拘束
-- (第一次與第二次本來就不同,那正是索引重用的證據)。
ihStats :: IndexHandle -> IndexStats
ihStats = unStats

-- | 本次執行產生的提示(目前只有「首次建立 @.knot\/@」一種)。
-- 由 hiedb-facts 的 @bRun@ 併入回傳的 @[ExtractWarning]@,最終經
-- @ExtractResult.erWarnings@ 由 CLI 組裝層印 stderr(library 自己不印)。
ihNotes :: IndexHandle -> [ExtractWarning]
ihNotes = unNotes

-- | 本次 'ensureIndex' 的索引統計(索引重用驗收的證據來源)。
data IndexStats = IndexStats
  { indexedCount :: Int   -- ^ 本次新建索引的 .hie 數
  , skippedCount :: Int   -- ^ hiedb 判定內容未變而重用的 .hie 數
  , batchCount   :: Int   -- ^ 實際發出的 hiedb index 次數
  }
  deriving (Eq, Show)

--------------------------------------------------------------------------------
-- 降級原因的前綴
--------------------------------------------------------------------------------

exePrefix, hiePrefix, versionPrefix, indexPrefix :: Text
exePrefix     = T.pack "hiedb executable "
hiePrefix     = T.pack "hie files unavailable: "
versionPrefix = T.pack "hie/ghc version mismatch: "
indexPrefix   = T.pack "hiedb index failed: "

--------------------------------------------------------------------------------
-- 探測
--------------------------------------------------------------------------------

-- | @Backend@ 的 hiedb 實例探測面(型別即 @Backend.bProbe@ 的欄位型別)。
--
-- 依序短路:執行檔解析 → @--help@ smoke → @pmHie@ → @hieFiles@ 非空 →
-- 第一個 @.hie@ 檔頭的 GHC 版本比對(ADR-001)。__不抛例外__。
probeHiedb :: ExtractOptions -> ProjectMeta -> IO ProbeResult
probeHiedb opts pm = do
  parts <- probeParts opts pm
  pure $ case parts of
    Left reason -> Unavailable reason
    Right _     -> Available

-- | 'probeHiedb' 的實作本體,成功時把後續要用的東西一併交出來
-- (執行檔路徑 + 'HieInfo'),讓 'ensureIndex' 不必重解析一次。
probeParts :: ExtractOptions -> ProjectMeta -> IO (Either Text (FilePath, HieInfo))
probeParts opts pm = do
  resolved <- resolveExe opts
  case resolved of
    Left reason -> pure (Left reason)
    Right exe -> do
      runnable <- checkRunnable exe
      case runnable of
        Left reason -> pure (Left reason)
        Right () -> case pmHie pm of
          Nothing -> pure . Left $ hiePrefix
            <> T.pack ("no .hie directory found under " <> rootDir opts)
          Just hie -> case hieFiles hie of
            [] -> pure . Left $ hiePrefix
              <> T.pack (hieDir hie <> " has no usable .hie files")
            (firstHie : _) -> do
              verdict <- checkHieVersion (rootDir opts) firstHie
              pure (fmap (const (exe, hie)) verdict)

-- | 執行檔解析:@hiedbExe@ 明示時用它(必要時補副檔名),否則查 PATH。
resolveExe :: ExtractOptions -> IO (Either Text FilePath)
resolveExe opts = case hiedbExe opts of
  Just p -> do
    here <- attemptIO (doesFileExist p)
    case here of
      Right True -> pure (Right p)
      _ -> do
        -- Windows 上使用者可能省略 .exe;交給 findExecutable 補
        found <- attemptIO (findExecutable p)
        pure $ case found of
          Right (Just q) -> Right q
          _              -> Left (exePrefix <> T.pack ("not found: " <> p))
  Nothing -> do
    found <- attemptIO (findExecutable "hiedb")
    pure $ case found of
      Right (Just q) -> Right q
      _              -> Left (exePrefix <> T.pack "not found: \"hiedb\" is not on PATH")

-- | @--help@ smoke test(hiedb 不支援 @--version@,實測回 @Invalid option@)。
checkRunnable :: FilePath -> IO (Either Text ())
checkRunnable exe = do
  outcome <- attemptIO (readCreateProcessWithExitCode (proc exe ["--help"]) "")
  pure $ case outcome of
    Left e -> Left (notRunnable (T.pack e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) -> Left . notRunnable $
      T.pack ("--help exited with " <> show c) <> tailSnippet (T.pack err)
 where
  notRunnable detail =
    exePrefix <> T.pack exe <> T.pack " is not runnable: " <> detail

-- | ADR-001 版本鎖:@.hie@ 檔頭為 @\"HIE\" \<hie 版本\> \\n \<GHC 版本\> \\n@,
-- 第二行與 @showVersion fullCompilerVersion@ 格式完全一致,可直接字串比對。
--
-- 只讀__第一個__檔(O(1),不隨專案大小成長);混版專案的其餘檔案由
-- @hiedb index@ 自然攔下,回 @\"hiedb index failed: \"@。
checkHieVersion :: FilePath -> FilePath -> IO (Either Text ())
checkHieVersion root relPath = do
  bytes <- attemptIO (BS.take 64 <$> BS.readFile (root </> relPath))
  pure $ case bytes of
    Left e -> Left (hiePrefix <> T.pack ("cannot read hie header of " <> relPath <> ": " <> e))
    Right header -> case hieHeaderGhcVersion header of
      Nothing -> Left (hiePrefix
        <> T.pack ("cannot read hie header of " <> relPath <> ": unrecognised header"))
      Just got
        | got == ownGhcVersion -> Right ()
        | otherwise -> Left (versionPrefix <> T.pack
            (relPath <> " was produced by GHC " <> T.unpack got
              <> ", but this build of knot uses GHC " <> T.unpack ownGhcVersion))

-- | 本執行檔自身的 GHC 版本(@.hie@ 檔頭第二行的比對對象)。
ownGhcVersion :: Text
ownGhcVersion = T.pack (showVersion fullCompilerVersion)

-- | 從 @.hie@ 檔頭前段取出 GHC 版本字串;不成形回 'Nothing'。
hieHeaderGhcVersion :: BS.ByteString -> Maybe Text
hieHeaderGhcVersion bytes = do
  rest <- BS.stripPrefix (BC.pack "HIE") bytes
  case BC.split '\n' rest of
    (_hieVer : ghcVer : _) | not (BC.null ghcVer) -> Just (T.pack (BC.unpack ghcVer))
    _                                             -> Nothing

--------------------------------------------------------------------------------
-- 索引就緒
--------------------------------------------------------------------------------

-- | 確保 hiedb 索引就緒。內含一次 'probeHiedb'(自足:單獨呼叫也安全)。
--
-- @Left@ 的文字即降級原因,可直接進 @BackendReport.brDetail@;
-- __不抛例外__(規則 7)。
--
-- 索引位置:@dbPath@ 為 'Nothing' 時用 @\<root\>\/.knot\/hiedb.sqlite@;
-- @dbPath@ 為__相對路徑__時以 @rootDir@ 為錨點(與 project-meta 的
-- @hieDirOverride@ 同語意,階段二閘門裁決),要寫到專案外請用絕對路徑。
--
-- 索引重用交給 @hiedb index@ 自身的增量機制:不傳 @-r\/--reindex@、
-- 不刪舊 db(規則 6)。
ensureIndex :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)
ensureIndex opts pm = do
  outcome <- attemptIO (ensureIndexBody opts pm)
  pure $ case outcome of
    Left e       -> Left (indexPrefix <> T.pack e)
    Right result -> result

ensureIndexBody :: ExtractOptions -> ProjectMeta -> IO (Either Text IndexHandle)
ensureIndexBody opts pm = do
  parts <- probeParts opts pm
  case parts of
    Left reason -> pure (Left reason)
    Right (exe, hie) -> do
      rootAbs <- makeAbsolute (rootDir opts)
      dbAbs <- makeAbsolute (resolveDbPath rootAbs (dbPath opts))
      let dbParent = takeDirectory dbAbs
      parentExisted <- doesDirectoryExist dbParent
      createDirectoryIfMissing True dbParent
      let batches = chunkFileArgs maxCmdChars maxCmdFiles (hieFiles hie)
      indexed <- runBatches exe rootAbs dbAbs batches
      case indexed of
        Left reason -> pure (Left reason)
        Right output -> do
          made <- doesFileExist dbAbs
          if not made
            then pure . Left $ indexPrefix
              <> T.pack ("database file was not created: " <> dbAbs)
            else pure . Right $ IndexHandle
              { unDbPath  = dbAbs
              , unRootDir = rootAbs
              , unExe     = exe
              , unStats   = parseIndexStats (length batches) output
              , unNotes   = knotNote rootAbs dbParent parentExisted
              }
 where
  -- 只在「走預設位置」且「.knot/ 是這次才建起來」時產生提示;
  -- dbPath 改道的使用者不需要 .gitignore 提示,且 .knot/ 全程不被觸碰。
  knotNote rootAbs dbParent parentExisted
    | Nothing <- dbPath opts
    , not parentExisted = [ExtractWarning
        { ewSource  = hiedbName
        , ewMessage = T.pack ("created index cache directory " <> dbParent
                        <> " under " <> rootAbs <> "; add .knot/ to .gitignore")
        }]
    | otherwise = []

-- | 規則 6 的索引位置解析。相對的 @dbPath@ 以 @rootDir@ 為錨點。
resolveDbPath :: FilePath -> Maybe FilePath -> FilePath
resolveDbPath rootAbs = maybe (defaultDbPath rootAbs) anchor
 where
  anchor p
    | isRelative p = rootAbs </> p
    | otherwise    = p

-- | 抽取規則 6 的預設索引位置:@\<root\>\/.knot\/hiedb.sqlite@。
-- 純函數,不碰檔案系統。
defaultDbPath :: FilePath -> FilePath
defaultDbPath root = root </> ".knot" </> "hiedb.sqlite"

-- | 逐批呼叫 @hiedb index@;任一批失敗即短路(不跑剩餘批次)。
-- 成功時回傳所有批次的輸出串接(供 'parseIndexStats')。
--
-- argv 形狀固定為 @[-D db --src-base-dir . index \<files…\>]@——hiedb 的全域
-- 選項必須在子命令之前。@cwd@ 釘在 @rootAbs@ 使 repo 相對的 @.hie@ 路徑與
-- @--src-base-dir .@ 同時成立(沿用 @Knot.Export.Commit@ 的既有範式)。
runBatches :: FilePath -> FilePath -> FilePath -> [[FilePath]] -> IO (Either Text Text)
runBatches exe rootAbs dbAbs = go []
 where
  go acc [] = pure (Right (T.concat (reverse acc)))
  go acc (b : rest) = do
    outcome <- attemptIO (readCreateProcessWithExitCode (cmd b) "")
    case outcome of
      Left e -> pure (Left (indexPrefix <> T.pack e))
      Right (ExitFailure c, out, err) -> pure . Left $ indexPrefix
        <> T.pack ("hiedb exited with " <> show c)
        <> tailSnippet (T.pack out <> T.pack err)
      Right (ExitSuccess, out, err) ->
        go (T.pack err : T.pack out : acc) rest
  cmd b = (proc exe (["-D", dbAbs, "--src-base-dir", "."] ++ "index" : b))
            { cwd = Just rootAbs }

-- | Windows @CreateProcess@ 的命令列上限為 32767 字元;留頭給執行檔路徑與
-- 全域選項後以 24000 字元 \/ 400 檔切批。
maxCmdChars, maxCmdFiles :: Int
maxCmdChars = 24000
maxCmdFiles = 400

--------------------------------------------------------------------------------
-- 純輔助函數
--------------------------------------------------------------------------------

-- | 依(累計字元上限, 檔數上限)切批;順序與內容保持
-- (@concat (chunkFileArgs a b xs) == xs@,規則 8)。
--
-- 單一路徑本身就超過字元上限時仍自成一批(不丟檔,交給 OS 報錯)。
-- 兩個上限都會被視為至少 1,故永遠會有進展。
chunkFileArgs :: Int -> Int -> [FilePath] -> [[FilePath]]
chunkFileArgs charCap fileCap = go
 where
  chars = max 1 charCap
  files = max 1 fileCap
  go [] = []
  go xs = let (batch, rest) = takeBatch 0 0 xs in batch : go rest
  takeBatch _ _ [] = ([], [])
  takeBatch usedChars usedFiles all'@(p : ps)
    | usedFiles >= files                             = ([], all')
    | usedFiles > 0 && usedChars + argWidth p > chars = ([], all')
    | otherwise =
        let (batch, rest) = takeBatch (usedChars + argWidth p) (usedFiles + 1) ps
        in (p : batch, rest)
  -- 引號與分隔空白的餘裕
  argWidth p = length p + 3

-- | 解析 hiedb 的 @Completed! (N indexed, M skipped in …)@ 行,多批相加。
-- 第一參數為批數(呼叫端已知,不從文字反推)。
--
-- 找不到任何 @Completed!@ 行 → @IndexStats 0 0 \<批數\>@:計數不是權威,
-- exit code 才是(實測 hiedb 對不存在的路徑會回 exit 0 + @0 indexed@)。
parseIndexStats :: Int -> Text -> IndexStats
parseIndexStats batches output = IndexStats
  { indexedCount = sumOf (T.pack "indexed")
  , skippedCount = sumOf (T.pack "skipped")
  , batchCount   = batches
  }
 where
  completedLines =
    [ l | l <- T.lines output, T.pack "Completed!" `T.isInfixOf` l ]
  sumOf key = sum (map (countBefore key) completedLines)
  countBefore key l =
    sum [ n
        | (a, b) <- zip ws (drop 1 ws)
        , b == key
        , Just n <- [readMaybe (T.unpack a) :: Maybe Int]
        ]
   where
    ws = T.words (T.map declutter l)
  declutter c = if c `elem` ("(),\r" :: String) then ' ' else c

--------------------------------------------------------------------------------
-- 小工具
--------------------------------------------------------------------------------

-- | 包 'IOException' 並轉成降級原因用的文字(規則 7)。
attemptIO :: IO a -> IO (Either String a)
attemptIO act = do
  r <- try act
  pure $ case r of
    Left e  -> Left (displayException (e :: IOException))
    Right a -> Right a

-- | 取輸出末幾行(非空行)附在降級原因後面;輸出為空時不加東西。
tailSnippet :: Text -> Text
tailSnippet raw
  | null useful = T.empty
  | otherwise   = T.pack ": " <> T.intercalate (T.pack " | ") (lastN 3 useful)
 where
  useful = filter (not . T.null) (map T.strip (T.lines raw))
  lastN n xs = drop (length xs - n) xs
