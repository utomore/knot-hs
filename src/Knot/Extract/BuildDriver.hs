-- | build-driver 模組:對目標專案執行**一次**插樁建置,列舉各 component 的 @.hie@。
--
-- F005 build-driver 落實抽取規則 5(插樁建置由 extraction 驅動、增量交給 cabal、
-- 失敗不 fallback)、6(每 component 一個 @.hie@ 目錄——由 cabal 天然提供)、
-- 7(@.knot/@ 佈局與自建 @.gitignore@)。
--
-- 兩個刻意的選擇(F005「實作方式」):
--
-- * **只帶 @-fwrite-ide-info@、不帶 @-hiedir@**:GHC 會把 @.hie@ 寫在 @.hi@ 旁,
--   cabal 本來就替每個 component 準備獨立輸出目錄。逐 component 各帶 @-hiedir@
--   會被 cabal 當組態變更而每次全量重編(spike:9.2 s vs 247 ms)
-- * **cabal 的輸出逐行即時轉發到本程序的 stderr**,同時保留尾段供 'BuildFailed'。
--   這是轉發子程序輸出,不是 library 自行列印(規則 5 的明文例外)
module Knot.Extract.BuildDriver
  ( -- * Level 2 模組介面
    ensureHie
  , HieLayout (..)
    -- * 內部純函數與可注入的執行面(非契約面;1-to-1 測試取用)
  , knotDir
  , knotBuildDir
  , prepareKnotDir
  , cabalArgs
  , runCabalWith
  , enumerateHie
  , componentRefOf
  , failedUnitOf
  ) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Char (isDigit)
import Data.List (sortOn)
import GHC.IO.Handle (hDuplicate)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , makeAbsolute
  )
import System.Exit (ExitCode (..))
import System.FilePath (makeRelative, splitDirectories, takeExtension, (</>))
import System.IO (hClose, hFlush, hIsEOF, hSetBinaryMode, stderr)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , createPipe
  , createProcess
  , proc
  , waitForProcess
  )

import Knot.Extract.Types (ExtractFailure (..), ExtractOptions (..))
import Knot.Meta.Types
  ( ComponentKind (..)
  , ComponentMeta (..)
  , ComponentRef (..)
  , PackageMeta (..)
  , ProjectMeta (..)
  )

-- | 規則 7 的快取目錄:@\<root\>\/.knot@。
knotDir :: FilePath -> FilePath
knotDir root = root </> ".knot"

-- | cabal 的 builddir:@\<root\>\/.knot\/build@。@.hie@ 散在其內各 component 的輸出目錄。
knotBuildDir :: FilePath -> FilePath
knotBuildDir root = knotDir root </> "build"

-- | 準備 @.knot/@:建目錄、首次寫入內容為 @*@ 的 @.gitignore@。冪等——
-- 已存在的 @.gitignore@ **不覆寫**(使用者可能改過)。
prepareKnotDir :: FilePath -> IO ()
prepareKnotDir root = do
  createDirectoryIfMissing True (knotDir root)
  let gi = knotDir root </> ".gitignore"
  exists <- doesFileExist gi
  unless exists (BS.writeFile gi (BS8.pack "*\n"))

-- | 組 cabal 的 argv(純函數)。@all@ 目標預設不含 test-suite \/ benchmark;
-- 只有 'ProjectMeta' 裡有**納入**(@compExcluded = False@)的該類 component 時
-- 才帶 @--enable-tests@ \/ @--enable-benchmarks@——帶與不帶是兩個組態,
-- 切換會讓 cabal 重新設定,所以只在使用者改了 @--include-tests@ 時才會發生。
cabalArgs :: FilePath -> FilePath -> ProjectMeta -> [String]
cabalArgs rootAbs buildDirAbs pm =
  [ "build", "all"
  , "--project-dir=" <> rootAbs
  , "--builddir=" <> buildDirAbs
  , "--ghc-options=-fwrite-ide-info"
  ]
  <> [ "--enable-tests"      | included TestSuite ]
  <> [ "--enable-benchmarks" | included Benchmark ]
 where
  included k = or
    [ compKind c == k && not (compExcluded c)
    | p <- pmPackages pm, c <- pkgComponents p ]

-- | 執行 cabal 並逐行轉發輸出到 stderr,保留最後 'tailLines' 行。
-- 第一參數是執行檔名(正式路徑固定 @cabal@;測試注入不存在的名字驗啟動失敗)。
-- 不走 shell(免 quoting);@cwd@ 釘在目標專案根目錄。
runCabalWith :: FilePath -> FilePath -> [String] -> IO (Either ExtractFailure ())
runCabalWith exe rootAbs args = do
  -- 子程序的 stdout 與 stderr 併進**同一條** pipe(stderr 端用 hDuplicate 的副本),
  -- 由主執行緒**單一讀者** drain 到 EOF 之後才 waitForProcess。
  --
  -- 不用 CreatePipe × 2 + forkIO 的理由:非 -threaded RTS 下 waitForProcess 是
  -- blocking 的 safe FFI call,會凍結所有 green thread;pump 跑不了、pipe 塞滿、
  -- cabal 寫不出去就永遠不結束(2026-08-22 實測死鎖)。既有的
  -- readCreateProcessWithExitCode 能用,正是因為它先 drain 再 wait。
  started <- try $ do
    (rd, wr) <- createPipe
    wr2 <- hDuplicate wr
    (_, _, _, ph) <- createProcess (proc exe args)
      { cwd = Just rootAbs, std_out = UseHandle wr, std_err = UseHandle wr2 }
    -- 父程序不得持有寫入端,否則 EOF 永遠不來
    hClose wr
    hClose wr2
    hSetBinaryMode rd True
    pure (rd, ph)
  case started of
    Left (e :: IOException) ->
      pure (Left (BuildFailed (T.pack "all")
                   (T.pack ("cannot start " <> exe <> ": " <> displayException e))))
    Right (rd, ph) -> do
      tl <- drain rd []
      hClose rd
      code <- waitForProcess ph
      hFlush stderr
      case code of
        ExitSuccess -> pure (Right ())
        ExitFailure c -> do
          let tlText = map (TE.decodeUtf8With lenientDecode) tl
              detail = T.intercalate (T.pack "\n")
                         (T.pack ("cabal exited with " <> show c) : tlText)
          pure (Left (BuildFailed (failedUnitOf tlText) detail))
 where
  -- 逐行轉發到本程序的 stderr,同時保留最後 tailLines 行(累積為正序清單)
  drain h acc = do
    eof <- hIsEOF h
    if eof
      then pure acc
      else do
        line <- BS8.hGetLine h
        BS8.hPutStrLn stderr line
        drain h (takeLast (acc ++ [line]))
  takeLast xs = drop (length xs - tailLines) xs

tailLines :: Int
tailLines = 40

-- | 盡力從 cabal 的輸出尾段解析失敗單元:
-- @Failed to build exe:knot from knot-hs-0.0.1.0.@ → @knot-hs:exe:knot@。
-- 格式不是契約,解析不到回 @all@;'bfDetail' 的尾段永遠在。
failedUnitOf :: [Text] -> Text
failedUnitOf ls = case [ u | l <- ls, Just u <- [unitOf l] ] of
  (u : _) -> u
  []      -> T.pack "all"
 where
  marker = T.pack "Failed to build "
  unitOf l = case T.breakOn marker l of
    (_, rest) | T.null rest -> Nothing
              | otherwise   -> case T.words (T.drop (T.length marker) rest) of
                  (unit : from : pkgver : _) | from == T.pack "from" ->
                    Just (stripVersion (trimDot pkgver) <> T.pack ":" <> trimDot unit)
                  (unit : _) -> Just (trimDot unit)
                  []         -> Nothing
  trimDot = T.dropWhileEnd (\c -> c == '.' || c == ',')

-- | @knot-hs-0.0.1.0@ → @knot-hs@:去掉最後一個全由數字與點組成的段。
stripVersion :: Text -> Text
stripVersion t = case reverse (T.splitOn (T.pack "-") t) of
  (v : rest@(_ : _)) | T.all (\c -> isDigit c || c == '.') v && not (T.null v)
    -> T.intercalate (T.pack "-") (reverse rest)
  _ -> t

-- | build-driver 的產物:@.knot/build@ 下各 component 輸出目錄裡的 @.hie@。
-- 路徑 repo 相對、正斜線,依碼位序;每筆附其 component(由 cabal 佈局路徑推得)。
--
-- 這是 build-driver → hie-index 的__模組間__介面型別(Level 2「模組間公開介面」),
-- 不是對外契約,所以定義住在這裡而不在 "Knot.Extract.Types"(G-E006):公開
-- library 不會 re-export 它,組裝層看不到。
data HieLayout = HieLayout
  { hlRoot  :: FilePath                       -- ^ @\<root\>\/.knot\/build@
  , hlFiles :: [(ComponentRef, FilePath)]
  }
  deriving (Eq, Show)

-- | 走訪 builddir 收 @.hie@,依 cabal 佈局推 component,產出 'HieLayout'。
-- 路徑為 repo 相對、正斜線,依碼位序(規則 10 的決定性)。
--
-- __只列舉納入 component 的 @.hie@__(規則 1,extraction/E001):目標專案自己的
-- @cabal.project@ 寫了 @tests: True@ 之類時,cabal 會把被排除的 test-suite 也建出來,
-- 那些 @.hie@ 對映到 @sfIncluded = False@ 的檔,下游只會逐檔警告後跳過——在這裡依
-- @compExcluded@ 濾掉,就不索引、不警告。對不到任何 component 的檔(佈局認不得)
-- __保留__,那不是「被排除」,交給規則 9 的 best-effort。
enumerateHie :: ProjectMeta -> FilePath -> FilePath -> FilePath -> IO HieLayout
enumerateHie pm root rootAbs buildDirAbs = do
  files <- walk buildDirAbs
  let pkgNames = map pkgName (pmPackages pm)
      excluded =
        [ ComponentRef (pkgName p, compName c)
        | p <- pmPackages pm, c <- pkgComponents p, compExcluded c ]
      entries  = sortOn snd
        [ (ref, toSlash (makeRelative rootAbs f))
        | f <- files
        , let ref = componentRefOf pkgNames (splitDirectories (makeRelative buildDirAbs f))
        , ref `notElem` excluded ]
  pure HieLayout { hlRoot = toSlash (knotBuildDir root), hlFiles = entries }
 where
  walk dir = do
    exists <- doesDirectoryExist dir
    if not exists then pure [] else do
      names <- listDirectory dir
      fmap concat . mapM step $ map (dir </>) names
  step p = do
    isDir <- doesDirectoryExist p
    if isDir then walk p
      else pure [p | takeExtension p == ".hie"]

-- | cabal builddir 佈局 → 'ComponentRef'(純函數)。輸入是相對 builddir 的路徑段:
-- @[build, \<arch\>, \<ghc\>, \<pkg\>-\<ver\>, \<kind\>, \<name\>, …]@;主 library 沒有
-- kind 段,第五段直接是 @build@。kind 段對映 project-meta F002 的 A3 前綴:
-- @x@→@exe:@、@t@→@test:@、@b@→@bench:@、@f@→@flib:@、@l@→@lib:@。
-- 套件名以 'pmPackages' 的 @pkgName@ 做最長前綴比對,對不上就去版號。
componentRefOf :: [Text] -> [FilePath] -> ComponentRef
componentRefOf pkgNames segs = case segs of
  ("build" : _arch : _ghc : pkgver : rest) ->
    let pkg = resolvePkg (T.pack pkgver)
    in case rest of
         ("x" : n : _) -> ComponentRef (pkg, T.pack ("exe:"   <> n))
         ("t" : n : _) -> ComponentRef (pkg, T.pack ("test:"  <> n))
         ("b" : n : _) -> ComponentRef (pkg, T.pack ("bench:" <> n))
         ("f" : n : _) -> ComponentRef (pkg, T.pack ("flib:"  <> n))
         ("l" : n : _) -> ComponentRef (pkg, T.pack ("lib:"   <> n))
         _             -> ComponentRef (pkg, T.pack "lib:" <> pkg)
  _ -> ComponentRef (T.empty, T.empty)
 where
  resolvePkg pkgver =
    case sortOn (negate . T.length)
           [ p | p <- pkgNames, p == pkgver || (p <> T.pack "-") `T.isPrefixOf` pkgver ] of
      (p : _) -> p
      []      -> stripVersion pkgver

-- | 規則 5–7 的組裝:準備 @.knot/@ → 一次 @cabal build all@ → 列舉 'HieLayout'。
-- 全部 'IOException' 在此收斂成 'Left',不往上拋。
ensureHie :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)
ensureHie opts pm = do
  r <- try $ do
    let root = rootDir opts
    rootAbs <- makeAbsolute root
    prepareKnotDir root
    let buildDirAbs = rootAbs </> ".knot" </> "build"
    outcome <- runCabalWith "cabal" rootAbs (cabalArgs rootAbs buildDirAbs pm)
    case outcome of
      Left failure -> pure (Left failure)
      Right ()     -> Right <$> enumerateHie pm root rootAbs buildDirAbs
  pure $ case r of
    Left (e :: IOException) ->
      Left (BuildFailed (T.pack "all") (T.pack (displayException e)))
    Right x -> x

toSlash :: FilePath -> FilePath
toSlash = map (\c -> if c == '\\' then '/' else c)
