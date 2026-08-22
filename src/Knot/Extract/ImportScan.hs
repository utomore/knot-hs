-- | import-scan 後端(T0):以輕量掃描(非完整 Haskell 語法解析)抽出
-- 'FactModule' 與 'FactImport'。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「內部模組劃分 ›
-- import-scan」;落實抽取規則 2(imports 唯一來源、無 module 標頭視為
-- @Main@)、7(best-effort)、8(決定性)。
--
-- 掃描管線(單檔):@rootDir \</\> sfPath@ → 位元組讀檔 → UTF-8 解碼 →
-- 'stripCommentLines' → 'headerModuleOf' / 'importsOf' → 'scanSource'。
module Knot.Extract.ImportScan
  ( -- * 後端
    importScanBackend
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , scanSource
  , stripCommentLines
  , headerModuleOf
  , importsOf
  ) where

import Control.Exception (IOException, displayException, try)
import qualified Data.ByteString as BS
import Data.Char (isAlpha, isAlphaNum, isSpace, isUpper)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8')
import System.FilePath ((</>))

import Knot.Extract.Backend (Backend (..), ProbeResult (..), importScanName)
import Knot.Extract.Types
  ( CapabilityLevel (..)
  , ExtractOptions (..)
  , ExtractWarning (..)
  , Fact (..)
  )
import Knot.Meta.Types (ModuleName (..), ProjectMeta (..), SourceFile (..))

--------------------------------------------------------------------------------
-- 後端值
--------------------------------------------------------------------------------

-- | import-scan 後端(T0):零外部依賴,@bLevel = ModuleLevel@,
-- @bProbe@ 恆 'Available'。
--
-- 收到的 'ProjectMeta' 是**完整**的(含 @sfIncluded = False@ 的條目);
-- 抽取規則 1(納入範圍)由本後端在自己的迭代點套用(G-B001 起,調度層
-- 不再預先窄化——理由見 'runBackends' 的 haddock)。
importScanBackend :: Backend
importScanBackend = Backend
  { bName  = importScanName
  , bLevel = ModuleLevel
  , bProbe = \_ _ -> pure Available
  , bRun   = runImportScan
  }

-- | 逐檔掃描:依 @pmSources@ 原序串接事實與警告(規則 8)。
-- 全程循序 IO,無並發、無 Map/Set 走訪。
--
-- 規則 1 在此套用:只掃 @sfIncluded = True@ 的檔案(G-B001)。
runImportScan :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
runImportScan opts pm = do
  results <- mapM (scanFile (rootDir opts)) (filter sfIncluded (pmSources pm))
  pure (concatMap fst results, concatMap snd results)

-- | 單檔:@rootDir \</\> sfPath@ 讀位元組 → UTF-8 解碼 → 'scanSource'。
-- 讀取或解碼失敗 → 一則 'ExtractWarning' + 跳過整檔(規則 7);不抛例外。
--
-- 刻意不做編碼猜測、不用 lenient 解碼(Haskell 慣例 UTF-8),
-- 避免以替換字元靜默污染事實流。
scanFile :: FilePath -> SourceFile -> IO ([Fact], [ExtractWarning])
scanFile root sf = do
  readResult <- try (BS.readFile (root </> path))
  pure $ case readResult of
    Left e ->
      failWith ("cannot read file: " <> displayException (e :: IOException))
    Right bytes -> case decodeUtf8' bytes of
      Left e    -> failWith ("cannot decode file as UTF-8: " <> displayException e)
      Right txt -> scanSource path txt
 where
  path = sfPath sf
  failWith msg = ([], [ExtractWarning { ewSource = T.pack path, ewMessage = T.pack msg }])

--------------------------------------------------------------------------------
-- 事實組裝
--------------------------------------------------------------------------------

-- | 單檔掃描核心:repo 相對路徑 + 已解碼內容 → (事實, 警告)。
--
-- 事實序:'FactModule' 在前,'FactImport' 依行號遞增(規則 8)。
-- 無 module 標頭 → @ModuleName "Main"@(委派決策 D3);**不去重**、
-- **不與 @sfModule@ 交叉比對**(假設 A2/A5)。
scanSource :: FilePath -> Text -> ([Fact], [ExtractWarning])
scanSource path content = (facts, warnings)
 where
  lns                    = stripCommentLines content
  (headerMod, headerBad) = headerModuleOf lns
  selfMod                = fromMaybe mainModule headerMod
  imports                = importsOf lns
  facts =
    FactModule { fmFile = path, fmModule = selfMod }
      : [ FactImport { fiFrom = selfMod, fiTo = m, fiFile = path, fiLine = n }
        | (n, Just m) <- imports
        ]
  warnings =
    [ warn (T.pack "module header without a parseable module name; assuming Main")
    | headerBad
    ]
      ++ [ warn (T.pack ("unparsable import at line " <> show n))
         | (n, Nothing) <- imports
         ]
  warn msg = ExtractWarning { ewSource = T.pack path, ewMessage = msg }

-- | 無 module 標頭時代入的 module(規則 2 / D3;多個 @Main@ 由 @fmFile@ 區分)。
mainModule :: ModuleName
mainModule = ModuleName (T.pack "Main")

--------------------------------------------------------------------------------
-- 1. 去註解掃描器
--------------------------------------------------------------------------------

-- | 去註解狀態機的狀態,跨行延續。
data ScanState
  = Code        -- ^ 一般程式碼
  | Str         -- ^ 字串字面量內(行尾自動回 'Code',不支援 string gap)
  | Block !Int  -- ^ 區塊註解內(Haskell 區塊註解可巢狀,'Int' 為深度)

-- | 去註解:剝 BOM 與行尾 @\\r@,消去 @--@、巢狀 @{- -}@(@{-# #-}@ 亦然),
-- 以空白佔位保留行結構與欄位位置;輸出行數 == 輸入行數,'Int' 為 1 起算的行號。
--
-- 已知限制(best-effort):不追蹤字元字面量,故 @\'"\'@、@\'{\'@ 類字面量
-- 理論上會擾亂狀態;'importsOf' 只掃到 import 區結束,使實際風險趨近於零
-- (假設 A7)。
stripCommentLines :: Text -> [(Int, Text)]
stripCommentLines content = zip [1 ..] (walk Code rawLines)
 where
  rawLines = map (T.dropWhileEnd (== '\r')) (T.lines (stripBom content))
  walk _ []         = []
  walk st (l : ls)  = let (out, st') = stripOne st l in out : walk st' ls

-- | 剝除開頭的 U+FEFF(BOM)。
stripBom :: Text -> Text
stripBom t = fromMaybe t (T.stripPrefix (T.singleton '\xFEFF') t)

-- | 去註解單行;回傳(去註解後的行, 行尾的延續狀態)。
stripOne :: ScanState -> Text -> (Text, ScanState)
stripOne st0 line = finish (go st0 ' ' line [])
 where
  -- 字串字面量不跨行(best-effort):行尾一律回 Code
  finish (acc, Str) = (T.pack (reverse acc), Code)
  finish (acc, st)  = (T.pack (reverse acc), st)

  go st prev t acc = case T.uncons t of
    Nothing        -> (acc, st)
    Just (c, rest) -> case st of
      Str
        | c == '\\' -> case T.uncons rest of
            Nothing       -> (c : acc, Str)
            Just (c2, r2) -> go Str c2 r2 (c2 : c : acc)
        | c == '"'  -> go Code c rest (c : acc)
        | otherwise -> go Str c rest (c : acc)
      Block n
        | opensBlock c rest -> go (Block (n + 1)) ' ' (T.drop 1 rest) (' ' : ' ' : acc)
        | closesBlock c rest ->
            let st' = if n <= 1 then Code else Block (n - 1)
            in go st' ' ' (T.drop 1 rest) (' ' : ' ' : acc)
        | otherwise -> go (Block n) ' ' rest (' ' : acc)
      Code
        | c == '"'          -> go Str c rest (c : acc)
        | opensBlock c rest -> go (Block 1) ' ' (T.drop 1 rest) (' ' : ' ' : acc)
        | c == '-'          ->
            let (dashes, after) = T.span (== '-') t
                isOperator =
                  isSymbolChar prev
                    || maybe False (isSymbolChar . fst) (T.uncons after)
            in if T.length dashes >= 2 && not isOperator
                 then (acc, Code)          -- 行註解:丟棄該行剩餘
                 else go Code '-' rest (c : acc)
        | otherwise         -> go Code c rest (c : acc)

  opensBlock c rest  = c == '{' && T.isPrefixOf (T.singleton '-') rest
  closesBlock c rest = c == '-' && T.isPrefixOf (T.singleton '}') rest

-- | Haskell 符號字元;@--@ 之後接符號字元即為運算子(如 @-->@)而非註解。
isSymbolChar :: Char -> Bool
isSymbolChar c = c `elem` "!#$%&*+./<=>?@\\^|-~:"

--------------------------------------------------------------------------------
-- token 切分
--------------------------------------------------------------------------------

-- | 取下一個 token(跳過前導空白);字串字面量整段為一個 token。
-- 非識別字起首的字元一律單獨成一個 token。
nextTok :: Text -> Maybe (Text, Text)
nextTok t0 = case T.uncons t of
  Nothing -> Nothing
  Just (c, r)
    | c == '"'       -> let (s, r') = spanStringLit r in Just (T.cons '"' s, r')
    | isIdentStart c -> Just (T.span isIdentChar t)
    | otherwise      -> Just (T.singleton c, r)
 where
  t = T.dropWhile isSpace t0

isIdentStart :: Char -> Bool
isIdentStart c = isAlpha c || c == '_'

isIdentChar :: Char -> Bool
isIdentChar c = isAlphaNum c || c == '_' || c == '\'' || c == '.'

-- | 吃掉字串字面量的其餘部分(含結尾引號);行尾未閉合即止。
spanStringLit :: Text -> (Text, Text)
spanStringLit = go []
 where
  go acc t = case T.uncons t of
    Nothing        -> (T.pack (reverse acc), T.empty)
    Just ('\\', r) -> case T.uncons r of
      Nothing       -> (T.pack (reverse ('\\' : acc)), T.empty)
      Just (c2, r2) -> go (c2 : '\\' : acc) r2
    Just ('"', r)  -> (T.pack (reverse ('"' : acc)), r)
    Just (c, r)    -> go (c : acc) r

-- | module id 文法:@[A-Z][A-Za-z0-9_\']*@ 以 @.@ 連接的序列。
moduleIdOf :: Text -> Maybe ModuleName
moduleIdOf t
  | T.null t                     = Nothing
  | all validSeg (T.splitOn dot t) = Just (ModuleName t)
  | otherwise                    = Nothing
 where
  dot = T.singleton '.'
  validSeg s = case T.uncons s of
    Just (c, r) -> isUpper c && T.all conIdChar r
    Nothing     -> False
  conIdChar c = isAlphaNum c || c == '_' || c == '\''

-- | 跨行取第一個 token(token 不跨行,故逐行找第一個非空行即可)。
firstTokenAcross :: [Text] -> Maybe Text
firstTokenAcross []       = Nothing
firstTokenAcross (l : ls) = case nextTok l of
  Just (tok, _) -> Just tok
  Nothing       -> firstTokenAcross ls

--------------------------------------------------------------------------------
-- 2. module 標頭
--------------------------------------------------------------------------------

-- | 取檔案宣告的 module 名;@Nothing@ = 無 module 標頭(呼叫端代入 @Main@)。
-- 'Bool' 為「有 module 關鍵字但解析不出名字」的旗標(轉警告用)。
--
-- 支援跨行標頭(@module\\n  App.Effects\\n  ( … ) where@);export list 內的
-- haddock 標題已由 'stripCommentLines' 剝除,不影響。
headerModuleOf :: [(Int, Text)] -> (Maybe ModuleName, Bool)
headerModuleOf = go
 where
  go [] = (Nothing, False)
  go ((_, l) : rest) = case nextTok l of
    Just (tok, after)
      | tok == T.pack "module" ->
          case firstTokenAcross (after : map snd rest) >>= moduleIdOf of
            Just m  -> (Just m, False)
            Nothing -> (Nothing, True)
    _ -> go rest

--------------------------------------------------------------------------------
-- 3. import 抽取
--------------------------------------------------------------------------------

-- | 取 import 區的每條 import;@Nothing@ = 該行解析不出 module id(轉警告用)。
-- 'Int' 為 @import@ 關鍵字所在行(即使 module id 落在續行)。
--
-- 掃描到「第一個第 0 欄、非空、非 @import@ / @module@ / CPP 指令的 token」
-- 為止(假設 A4)。CPP 指令行只被丟棄、**不做條件求值**——@#if@ / @#else@
-- 兩個分支內的 import 會**同時**被抽出(刻意的 best-effort:寧可多報也不漏報)。
importsOf :: [(Int, Text)] -> [(Int, Maybe ModuleName)]
importsOf = go
 where
  go [] = []
  go ((n, l) : rest)
    | T.all isSpace l                     = go rest   -- 空白行
    | T.isPrefixOf (T.singleton '#') l    = go rest   -- CPP 指令
    | maybe False (isSpace . fst) (T.uncons l) = go rest   -- 縮排續行
    | otherwise = case nextTok l of
        Nothing         -> go rest
        Just (tok, after)
          | tok == T.pack "module" -> go rest
          | tok == T.pack "import" ->
              (n, importTarget (after : continuations rest)) : go rest
          | otherwise              -> []               -- 已進入宣告區
  continuations = map snd . takeWhile (isContinuation . snd)
  isContinuation l = maybe False (isSpace . fst) (T.uncons l) && not (T.all isSpace l)

-- | 單條 import 的目標:跳過 @qualified@ 與 package 字串字面量,
-- 取第一個 module id token。@as@ / @hiding@ / @(…)@ 之後一律不看。
importTarget :: [Text] -> Maybe ModuleName
importTarget [] = Nothing
importTarget (l : ls) = case nextTok l of
  Nothing -> importTarget ls
  Just (tok, after)
    | tok == T.pack "qualified"            -> importTarget (after : ls)
    | T.isPrefixOf (T.singleton '"') tok   -> importTarget (after : ls)
    | otherwise                            -> moduleIdOf tok
