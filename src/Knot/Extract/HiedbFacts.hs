-- | hiedb-facts 模組:讀 hiedb 索引 SQLite(@mods@ \/ @defs@ \/ @decls@ \/
-- @refs@ 四張表)→ @FactDecl@ \/ @FactRef@ 事實流,並組裝 @Backend@ 的
-- hiedb 實例。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「模組間公開介面」
-- 的 'readIndexFacts',以及 @Backend@ hiedb 實例的__執行面__ @bRun@
-- (經 'ensureIndex' 取得 'IndexHandle' 後呼叫 'readIndexFacts');落實抽取
-- 規則 4(fromDecl 由 span 包含 join 解析、取最內層)、4a(@frGenerated@
-- 原樣轉載)、7(best-effort:單查詢失敗 → 警告)、8(決定性)。
--
-- __不做__:不產出 @FactInstance@(hiedb 0.8 的 schema 無 instance 表,已於
-- 上游 @HieDb/Create.hs@ 的 @setupHieDb@ 複查屬實);不產出 @FactModule@ \/
-- @FactImport@(規則 2:那是 import-scan 的唯一職責);不輸出型別資訊
-- (@typenames@ \/ @typerefs@ 本版不用);不判斷產生碼要不要丟棄(只轉載
-- 旗標,取捨是 graph-core 的職責);不做圖層面的聚合。
--
-- __本模組全程不印任何輸出__(委派決策 D4):所有提示一律走
-- @ExtractWarning@,由 CLI 組裝層決定怎麼印。
--
-- == hiedb 索引的四個實測事實(設計依據)
--
-- * @decls@ 沒有 @mod@ 欄,module 只能經 @hieFile@ join @mods@
-- * @refs.mod@ 是__被引用者__的定義 module;引用發生地要走 @refs.hieFile@
-- * @mods.hs_src@ 是__絕對路徑__(上游走 @makeAbsolute@),Windows 為反斜線,
--   且 @--src-base-dir@ 解析不到來源檔時為 @NULL@
-- * namespace 藏在 @occ@ 的字串前綴裡(@\"v:\"@ \/ @\"c:\"@ \/ @\"t:\"@ \/
--   @\"z:\"@ \/ @\"f\<父型別\>:\"@,見上游 @HieDb/Types.hs@ 的 @toNsChar@)
module Knot.Extract.HiedbFacts
  ( -- * 後端
    hiedbBackend
    -- * Level 2 模組介面
  , readIndexFacts
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , parseOcc
  , declKindOf
  , resolveModuleSource
  , pickFromDecl
  ) where

import Control.Exception
  ( Exception (..)
  , SomeException
  , throwIO
  , try
  )
import Data.List (minimumBy, sort)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Ord (Down (..), comparing)
import qualified Data.Text as T
import Data.Text (Text)
import Database.SQLite.Simple
  ( Connection
  , Query (..)
  , query_
  , withConnection
  )
import Database.SQLite.Simple.FromRow (FromRow (..), field)

import Knot.Extract.Backend (Backend (..), hiedbName)
import Knot.Extract.HiedbDriver (IndexHandle, ensureIndex, ihDbPath, ihNotes, probeHiedb)
import Knot.Extract.Types
  ( CapabilityLevel (..)
  , DeclKind (..)
  , ExtractOptions
  , ExtractWarning (..)
  , Fact (..)
  , NameSpace (..)
  , QualName (..)
  )
import Knot.Meta.Types (ModuleName (..), ProjectMeta (..), SourceFile (..))

--------------------------------------------------------------------------------
-- 後端組裝
--------------------------------------------------------------------------------

-- | hiedb 後端:@bLevel = DeclLevel@,探測面來自 F003 的 'probeHiedb',
-- 執行面先 'ensureIndex' 再 'readIndexFacts'。
hiedbBackend :: Backend
hiedbBackend = Backend
  { bName  = hiedbName
  , bLevel = DeclLevel
  , bProbe = probeHiedb
  , bRun   = runHiedb
  }

-- | @bRun@ 沒有失敗通道(@IO ([Fact], [ExtractWarning])@),而 'ensureIndex'
-- 會回 @Left@(探測過了但 @hiedb index@ 炸掉)→ 以 'HiedbFactsError' 抛出,
-- 由 @Knot.Extract.Backend.runOne@ 轉成 @brUsed = False@ + 原文。
--
-- 不改成「回空事實 + 警告」:那會讓 @brUsed = True@、@erLevel@ 升到
-- @DeclLevel@,對外謊報函式級成功——比失敗更糟。
runHiedb :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
runHiedb opts pm = do
  ready <- ensureIndex opts pm
  case ready of
    Left reason -> throwIO (HiedbFactsError reason)
    Right h     -> readIndexFacts h pm

-- | 索引就緒失敗的例外通道;'displayException' 即 'ensureIndex' 的 @Left@ 原文
-- (含 @\"hiedb index failed: \"@ 等 F003 的穩定前綴)。
newtype HiedbFactsError = HiedbFactsError Text

instance Show HiedbFactsError where
  show (HiedbFactsError t) = T.unpack t

instance Exception HiedbFactsError where
  displayException (HiedbFactsError t) = T.unpack t

--------------------------------------------------------------------------------
-- Level 2 模組介面
--------------------------------------------------------------------------------

-- | 從就緒索引讀 decl 層事實(Level 2 模組介面,簽名照契約)。
--
-- 回傳的警告以 'ihNotes' 起頭(F003 的 @.knot\/@ 首建提示唯一的出口),
-- 其後才是本模組蒐集到的對映失敗 \/ 未知 namespace \/ 查詢失敗警告。
--
-- __不抛例外__(規則 7):三條查詢各自包例外,單條失敗只讓該類事實為空。
readIndexFacts :: IndexHandle -> ProjectMeta -> IO ([Fact], [ExtractWarning])
readIndexFacts h pm = do
  outcome <- attempt (withConnection (ihDbPath h) (collectFacts pm))
  pure $ case outcome of
    Left reason      -> ([], ihNotes h <> [dbWarning reason])
    Right (fs, ws)   -> (sort fs, ihNotes h <> ws)
 where
  dbWarning reason = ExtractWarning
    { ewSource  = hiedbName
    , ewMessage = T.pack ("cannot read index " <> ihDbPath h <> ": ") <> reason
    }

-- | 三條查詢的編排。@mods@ 失敗即整體放棄(沒有 module 對映就什麼都產不出);
-- @defs@ \/ @refs@ 失敗只讓該類事實為空,另一類照出。
collectFacts :: ProjectMeta -> Connection -> IO ([Fact], [ExtractWarning])
collectFacts pm conn = do
  modsOutcome <- attempt (query_ conn qMods :: IO [ModRow])
  case modsOutcome of
    Left reason -> pure ([], [queryWarning "mods" reason])
    Right modRows -> do
      let (modIndex, mapWarnings) = buildModIndex (pmSources pm) modRows
      declOutcome <- attempt (query_ conn qDefs :: IO [DefRow])
      refOutcome  <- attempt (query_ conn qRefs :: IO [RefJoinRow])
      let (declFacts, declUnknown, declWarns) = case declOutcome of
            Left reason -> ([], Map.empty, [queryWarning "defs" reason])
            Right rows  -> let (fs, u) = declFactsOf modIndex rows in (fs, u, [])
          (refFacts, refUnknown, refWarns) = case refOutcome of
            Left reason -> ([], Map.empty, [queryWarning "refs" reason])
            Right rows  -> let (fs, u) = refFactsOf modIndex rows in (fs, u, [])
          unknown = Map.unionWith (+) declUnknown refUnknown
      pure ( declFacts <> refFacts
           , mapWarnings <> declWarns <> refWarns <> unknownWarnings unknown
           )

--------------------------------------------------------------------------------
-- SQL
--------------------------------------------------------------------------------

-- | 專案不開 @OverloadedStrings@(@src\/@ 與 @app\/@ 全部只靠 @GHC2024@),
-- 故 SQL 一律經本函數建出 'Query'。
sql :: String -> Query
sql = Query . T.pack

-- | @is_real@ 刻意不取:它只表示「@hs_src@ 是否為真實來源檔」,而
-- @hs_src@ 為 @NULL@ 的情形已由 'resolveModuleSource' 的第二層退路涵蓋。
qMods :: Query
qMods = sql "SELECT hieFile, mod, hs_src, is_boot FROM mods ORDER BY hieFile"

-- | @defs@ 的 @PRIMARY KEY(hieFile, occ)@ 保證每個名字剛好一列。
qDefs :: Query
qDefs = sql "SELECT hieFile, occ, sl FROM defs ORDER BY hieFile, occ"

-- | 抽取規則 4:span 包含 join 出候選(一對多),最內層挑選在 Haskell 做。
--
-- @LEFT JOIN@ 是刻意的:落在任何宣告之外的引用(export list、import 行、
-- 頂層型別簽章外圍…)仍要產出 @FactRef@,只是 @frFromDecl = Nothing@——
-- graph-core 對這種事實有明確處理,漏掉就是漏事實。
--
-- __候選集不以 @d.is_root = 1@ 過濾__:上游 @HieDb/Utils.hs@ 的 @isRoot@ 只
-- 對 @ValBind InstanceBind@ 與 @Decl@ 回 @True@,一般的頂層值繫結
-- (@ValBind RegularBind ModuleScope@)拿到的是 @is_root = 0@——2026-08-22
-- 實測 fixture:@v:run@ \/ @v:greet@ \/ @fConfig:cfgName@ 皆為 0,只有
-- @t:Color@ \/ @c:Red@ \/ @t:Config@ 等為 1。加上這個過濾會讓「引用寫在哪個
-- 函式裡」__永遠解析不到__,正是 fromDecl 最主要的用途。@decls@ 本身已只收
-- 「有 Module 的名字」(局部 @where@ \/ @let@ 繫結是 internal name,不入表),
-- 所以不過濾也不會混進非頂層的候選。
--
-- @ORDER BY@ 只負責讓同一個 ref 的候選__相鄰且順序固定__;真正的破雷序
-- 依 @(qnSpace, qnOcc)@,而 @qnSpace@ 是解析後的建構子序,與原始 @d.occ@
-- 的字串序不同,SQL 排不出來(見 'pickFromDecl')。
qRefs :: Query
qRefs = sql
  "SELECT r.hieFile, r.occ, r.mod, r.sl, r.sc, r.el, r.ec, r.is_generated, \
  \       d.occ, d.sl, d.sc, d.el, d.ec \
  \FROM refs r \
  \LEFT JOIN decls d \
  \  ON r.hieFile = d.hieFile \
  \ AND (d.sl <  r.sl OR (d.sl = r.sl AND d.sc <= r.sc)) \
  \ AND (r.el <  d.el OR (r.el = d.el AND r.ec <= d.ec)) \
  \ORDER BY r.hieFile, r.sl, r.sc, r.el, r.ec, r.occ, r.mod, r.is_generated, \
  \         d.sl, d.sc, d.el, d.ec, d.occ"

-- | @mods@ 的一列(私有 row DTO)。
data ModRow = ModRow
  { mrHieFile :: Text
  , mrModule  :: Text
  , mrHsSrc   :: Maybe Text   -- ^ @TEXT UNIQUE@,可為 @NULL@
  , mrIsBoot  :: Bool
  }

instance FromRow ModRow where
  fromRow = ModRow <$> field <*> field <*> field <*> field

-- | @defs@ 的一列(私有 row DTO)。
data DefRow = DefRow
  { drHieFile :: Text
  , drOcc     :: Text
  , drLine    :: Int
  }

instance FromRow DefRow where
  fromRow = DefRow <$> field <*> field <*> field

-- | @refs@ LEFT JOIN @decls@ 的一列(13 欄,超過 sqlite-simple 內建元組上限
-- 10,故以私有 record + 手寫 'FromRow' 承接)。@rjD*@ 為候選 decl,
-- 無候選時全為 'Nothing'。
data RefJoinRow = RefJoinRow
  { rjHieFile   :: Text
  , rjOcc       :: Text
  , rjMod       :: Text
  , rjSl        :: Int
  , rjSc        :: Int
  , rjEl        :: Int
  , rjEc        :: Int
  , rjGenerated :: Bool
  , rjDeclOcc   :: Maybe Text
  , rjDeclSl    :: Maybe Int
  , rjDeclSc    :: Maybe Int
  , rjDeclEl    :: Maybe Int
  , rjDeclEc    :: Maybe Int
  }

instance FromRow RefJoinRow where
  fromRow = RefJoinRow
    <$> field <*> field <*> field <*> field <*> field <*> field <*> field
    <*> field <*> field <*> field <*> field <*> field <*> field

--------------------------------------------------------------------------------
-- module 對映
--------------------------------------------------------------------------------

-- | 一列 @mods@ 對映成功後留下的東西。
data ModEntry = ModEntry
  { meModule :: ModuleName
  , meFile   :: FilePath      -- ^ @sfPath@ __原文__(與 import-scan 逐字相同)
  }

-- | 建 @hieFile -> ModEntry@ 索引。@.hs-boot@ 靜默略過(不在 @pmSources@,
-- 不是錯誤);對映不到的 module 記一則警告並整批跳過(驗收標準 4)。
--
-- 輸入已由 @ORDER BY hieFile@ 定序,故警告順序亦為決定性(規則 8)。
buildModIndex :: [SourceFile] -> [ModRow] -> (Map Text ModEntry, [ExtractWarning])
buildModIndex sfs rows = (idx, reverse warns)
 where
  (idx, warns) = foldl' step (Map.empty, []) rows
  step acc@(m, ws) r
    | mrIsBoot r = acc
    | otherwise =
        let modName = ModuleName (mrModule r)
        in case resolveModuleSource sfs modName (mrHsSrc r) of
             Just p  -> (Map.insert (mrHieFile r) (ModEntry modName p) m, ws)
             Nothing -> (m, unmapped r : ws)
  unmapped r = ExtractWarning
    { ewSource  = mrHieFile r
    , ewMessage = T.pack "cannot map indexed module " <> mrModule r
        <> T.pack " back to pmSources; skipping its decls and refs"
    }

-- | 一列 @mods@ 對應到 'pmSources' 的哪個檔案:先 @hs_src@ 後綴比對,
-- 再退回 @mod@ ↔ @sfModule@ 唯一比對;都不中回 'Nothing'。
-- 回傳的是 @sfPath@ __原文__(與 import-scan 的 @fmFile@ 逐字相同)。
--
-- 用後綴比對而非以 root 做前綴相減的理由:@hs_src@ 走上游的 @makeAbsolute@、
-- @hieFile@ 走 @canonicalizePath@,兩者與專案根的大小寫 \/ 8.3 短檔名 \/
-- symlink 解析都可能不同形,前綴相減會零星失敗;後綴比對只依賴「repo 相對
-- 路徑是絕對路徑的尾段」這個必然成立的事實。邊界必須落在 @\'\/\'@ 上,
-- 故 @\"emo\/Core.hs\"@ 不會誤命中 @\"src\/Demo\/Core.hs\"@。
resolveModuleSource
  :: [SourceFile]      -- ^ pmSources(已由 backend-select 窄化)
  -> ModuleName        -- ^ mods.mod
  -> Maybe Text        -- ^ mods.hs_src(NULL 時為 Nothing)
  -> Maybe FilePath
resolveModuleSource sfs modName mHsSrc =
  case mHsSrc >>= longestSuffixMatch of
    Just p  -> Just p
    Nothing -> uniqueByModule
 where
  longestSuffixMatch raw =
    case [ sfPath sf | sf <- sfs, matches (normalise raw) (T.pack (sfPath sf)) ] of
      []   -> Nothing
      hits -> Just (longest hits)
  -- 同長度且同為後綴 ⇒ 同一個字串,故長度即全序
  longest = foldr1 (\a b -> if length a >= length b then a else b)
  matches src rel = src == rel || (T.singleton '/' <> rel) `T.isSuffixOf` src
  normalise = T.map (\c -> if c == '\\' then '/' else c)
  uniqueByModule = case [ sfPath sf | sf <- sfs, sfModule sf == Just modName ] of
    [p] -> Just p
    _   -> Nothing    -- 零筆或多筆(例:多個 Main)都視為落空

--------------------------------------------------------------------------------
-- 事實產出
--------------------------------------------------------------------------------

-- | @defs@ → 'FactDecl'。第二個回傳值是未知 namespace 前綴的計數
-- (呼叫端彙整成警告)。
declFactsOf :: Map Text ModEntry -> [DefRow] -> ([Fact], Map Text Int)
declFactsOf modIndex = foldl' step ([], Map.empty)
 where
  step acc@(fs, u) r = case Map.lookup (drHieFile r) modIndex of
    Nothing -> acc                                    -- 已在 buildModIndex 記過警告
    Just e  -> case parseOcc (drOcc r) of
      Nothing -> (fs, bumpUnknown (drOcc r) u)
      Just (occ, ns) ->
        ( FactDecl
            { fdName = QualName (meModule e) occ ns
            , fdKind = declKindOf ns
            , fdFile = meFile e
            , fdLine = drLine r
            } : fs
        , u
        )

-- | @refs@ LEFT JOIN @decls@ → 'FactRef'。同一個 ref 的候選 decl 由 SQL
-- 排成相鄰列,這裡依「ref 鍵」分組後交給 'pickFromDecl' 挑最內層。
--
-- 「ref 鍵」= @(hieFile, sl, sc, el, ec, occ, mod, is_generated)@;@unit@ 不
-- 入鍵——它只影響「哪個套件定義了這個名字」,而 @QualName@ 沒有 unit 欄位。
refFactsOf :: Map Text ModEntry -> [RefJoinRow] -> ([Fact], Map Text Int)
refFactsOf modIndex = foldl' step ([], Map.empty) . groupAdjacent refKey
 where
  step acc@(fs, u) grp@(r : _) = case Map.lookup (rjHieFile r) modIndex of
    Nothing -> acc
    Just e  -> case parseOcc (rjOcc r) of
      Nothing -> (fs, bumpUnknown (rjOcc r) u)
      Just (occ, ns) ->
        ( FactRef
            { frFromModule = meModule e
            , frFromDecl   = pickFromDecl (candidates e grp)
            , frTarget     = QualName (ModuleName (rjMod r)) occ ns
            , frGenerated  = rjGenerated r        -- 規則 4a:原樣轉載
            , frFile       = meFile e
            , frLine       = rjSl r
            } : fs
        , u
        )
  step acc [] = acc
  refKey r =
    ( rjHieFile r, rjSl r, rjSc r, rjEl r, rjEc r
    , rjOcc r, rjMod r, rjGenerated r )
  -- 解析不出 namespace 的候選直接淘汰(不計入未知統計:ref 本身仍照出)
  candidates e grp =
    [ ((dsl, dsc, del, dec), QualName (meModule e) occ ns)
    | r <- grp
    , Just dOcc <- [rjDeclOcc r]
    , Just dsl  <- [rjDeclSl r]
    , Just dsc  <- [rjDeclSc r]
    , Just del  <- [rjDeclEl r]
    , Just dec  <- [rjDeclEc r]
    , Just (occ, ns) <- [parseOcc dOcc]
    ]

-- | 抽取規則 4:從 span 包含 join 的候選中取最內層;
-- 同 span 依 @(qnSpace, qnOcc)@ 字典序破雷;無候選回 'Nothing'。
--
-- 候選都包含同一個 ref,故「起點最大、終點最小」即最內層。破雷用的是
-- __解析後__的建構子序(@ValueNs \< DataConNs \< TypeNs \< FieldNs@),
-- 與原始 @occ@ 的字串序(@c… \< f… \< t… \< v…@)不同,所以不能交給 SQL。
-- 比較鍵是全序,結果與輸入順序無關。
pickFromDecl :: [((Int, Int, Int, Int), QualName)] -> Maybe QualName
pickFromDecl [] = Nothing
pickFromDecl cs = Just (snd (minimumBy (comparing rank) cs))
 where
  rank ((dsl, dsc, del, dec), q) =
    (Down (dsl, dsc), (del, dec), (qnSpace q, qnOcc q))

--------------------------------------------------------------------------------
-- 純函數
--------------------------------------------------------------------------------

-- | hiedb 的 @occ@ 前綴 → (裸 occ 名, namespace)。
--
-- 切在__第一個__冒號(與上游 @FromField OccName@ 的 @T.break (== \':\')@
-- 同一判準),故含冒號的運算子(@:|@、@:+:@)不會出錯。
--
-- 不認得的前綴(含型別變數 @z:@)回 'Nothing',呼叫端跳過該列並依前綴
-- 彙整成一則警告。
parseOcc :: Text -> Maybe (Text, NameSpace)
parseOcc raw = case T.uncons rest of
  Just (':', occ) -> flip (,) <$> nsOf prefix <*> Just occ
  _               -> Nothing
 where
  (prefix, rest) = T.break (== ':') raw
  nsOf p
    | p == T.pack "v"                = Just ValueNs
    | p == T.pack "c"                = Just DataConNs
    | p == T.pack "t"                = Just TypeNs
    | Just ('f', _) <- T.uncons p    = Just FieldNs   -- f<父型別>:,父型別丟棄
    | otherwise                      = Nothing        -- 含 "z"(型別變數)

-- | namespace → 'DeclKind'。
--
-- hiedb 0.8 索引時丟棄了 GHC 的 @DeclType@(其 @HieDb/Utils.hs@ 的 @goDec@
-- 只存 @is_root@),所以 class \/ type synonym \/ family 在索引裡與 data
-- 無從區分,只能由前綴粗推——這是 design.md @DeclKind@ 註解明載的
-- 「hiedb 後端只能交出 namespace 粗度」,消費端不得假設能分辨 class。
declKindOf :: NameSpace -> DeclKind
declKindOf ValueNs   = ValueDecl
declKindOf FieldNs   = ValueDecl   -- 記錄欄位選擇器是值
declKindOf DataConNs = DataDecl    -- 資料建構子出自 data 宣告
declKindOf TypeNs    = DataDecl    -- 無從區分 class / synonym / family

--------------------------------------------------------------------------------
-- 小工具
--------------------------------------------------------------------------------

-- | 相鄰且同鍵的列分成一組(輸入已由 SQL 的 @ORDER BY@ 定序)。
groupAdjacent :: Eq k => (a -> k) -> [a] -> [[a]]
groupAdjacent _ [] = []
groupAdjacent key (x : xs) = (x : same) : groupAdjacent key rest
 where
  (same, rest) = span ((== key x) . key) xs

-- | 未知 namespace 的計數以「前綴」為鍵;無冒號的 @occ@ 歸在一個共用鍵下。
bumpUnknown :: Text -> Map Text Int -> Map Text Int
bumpUnknown raw = Map.insertWith (+) (occPrefix raw) 1
 where
  occPrefix t = case T.break (== ':') t of
    (p, rest) | T.isPrefixOf (T.singleton ':') rest -> p <> T.singleton ':'
    _                                               -> T.pack "<no prefix>"

-- | 每個相異前綴__一則__警告(不逐列刷警告,避免淹沒 stderr 與
-- @--strict@ 誤判)。'Map' 的鍵序即決定性順序(規則 8)。
unknownWarnings :: Map Text Int -> [ExtractWarning]
unknownWarnings counts =
  [ ExtractWarning
      { ewSource  = hiedbName
      , ewMessage = T.pack "skipped " <> T.pack (show n)
          <> T.pack " name(s) with unsupported namespace prefix " <> p
      }
  | (p, n) <- Map.toAscList counts
  ]

queryWarning :: String -> Text -> ExtractWarning
queryWarning table reason = ExtractWarning
  { ewSource  = hiedbName
  , ewMessage = T.pack ("cannot read " <> table <> " table: ") <> reason
  }

-- | 規則 7:把任何例外轉成降級原因用的文字。
attempt :: IO a -> IO (Either Text a)
attempt act = do
  r <- try act
  pure $ case r of
    Left e  -> Left (T.pack (displayException (e :: SomeException)))
    Right a -> Right a
