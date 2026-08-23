-- | hiedb-facts 模組:讀 hiedb 索引 SQLite(@mods@ \/ @defs@ \/ @decls@ \/
-- @refs@ 四張表)→ @FactDecl@ \/ @FactRef@ 事實流——fact-pipeline 的第四站
-- (F007 起;F006 的過渡期 @Backend@ 轉接器已隨 @Knot.Extract.Backend@ 拆掉)。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「模組間公開介面」
-- 的 'readIndexFacts'(管線把 'ensureIndex' 取得的 'IndexHandle' 交進來);
-- 落實抽取規則 4(fromDecl 由 span 包含 join 解析、取最內層)、4a(產生碼的三個面
-- 只標註不過濾:@frGenerated@ 原樣轉載 @refs.is_generated@,@fdGenerated@ 與
-- @frTargetGenerated@ 由 @defs@ \\ @decls@ 判定,見 'qDeclOccs')、
-- 7(best-effort:單查詢失敗 → 警告)、8(決定性)。
--
-- __不做__:不產出 @FactInstance@(hiedb 0.8 的 schema 無 instance 表,已於
-- 上游 @HieDb/Create.hs@ 的 @setupHieDb@ 複查屬實);不產出 @FactModule@ \/
-- @FactImport@(規則 2:那是 import-scan 的唯一職責);不輸出型別資訊
-- (@typenames@ \/ @typerefs@ 本版不用);__不判斷產生碼要不要丟棄__
-- (只標註旗標,取捨是 graph-core 規則 3 的職責);不做圖層面的聚合。
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
  ( -- * Level 2 模組介面
    readIndexFacts
    -- * 內部純函數(僅為 1-to-1 測試而匯出,非 Level 2 契約面)
  , parseOcc
  , declKindOf
  , resolveModuleSource
  , resolveModuleSourceFor
  , pickFromDecl
  , SourceDecls (..)
  , unavailableSourceDecls
  , isGeneratedName
  ) where

import Control.Exception (SomeException, displayException, try)
import Data.List (find, isPrefixOf, isSuffixOf, minimumBy, sort)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Ord (Down (..), comparing)
import Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import System.FilePath (splitDirectories, takeDirectory)
import Database.SQLite.Simple
  ( Connection
  , Query (..)
  , query_
  , withConnection
  )
import Database.SQLite.Simple.FromRow (FromRow (..), field)

import Knot.Extract.BuildDriver (componentRefOf)
import Knot.Extract.HieIndex (IndexHandle, hiedbName, ihDbPath, ihNotes)
import Knot.Extract.Types
  ( DeclKind (..)
  , ExtractWarning (..)
  , Fact (..)
  , NameSpace (..)
  , QualName (..)
  )
import Knot.Meta.Types
  ( ComponentRef (..)
  , ModuleName (..)
  , PackageMeta (..)
  , ProjectMeta (..)
  , SourceFile (..)
  )

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

-- | 四條查詢的編排。@mods@ 失敗即整體放棄(沒有 module 對映就什麼都產不出);
-- @defs@ \/ @refs@ 失敗只讓該類事實為空,另一類照出;@decls@ 的 occ 索引
-- 失敗只讓兩個產生碼旗標退回 'False'(見 'SourceDecls')。
collectFacts :: ProjectMeta -> Connection -> IO ([Fact], [ExtractWarning])
collectFacts pm conn = do
  modsOutcome <- attempt (query_ conn qMods :: IO [ModRow])
  case modsOutcome of
    Left reason -> pure ([], [queryWarning "mods" reason])
    Right modRows -> do
      -- B002:每列 .hie 的路徑帶著 <pkg>-<ver> 段,解出套件名再對映(monorepo 的
      -- hs_src 是套件相對路徑,沒有套件名就對不回 pmSources)
      let pkgOfHie hieFile = packageOfHiePath (map pkgName (pmPackages pm)) (T.unpack hieFile)
          (modIndex, mapWarnings) = buildModIndex pm pkgOfHie modRows
      declOutcome    <- attempt (query_ conn qDefs :: IO [DefRow])
      refOutcome     <- attempt (query_ conn qRefs :: IO [RefJoinRow])
      srcDeclOutcome <- attempt (query_ conn qDeclOccs :: IO [(Text, Text)])
      let (srcDecls, srcDeclWarns) = case srcDeclOutcome of
            Left reason -> (unavailableSourceDecls, [genFlagWarning reason])
            -- 整張表空 ⇒ 上游行為變了(hiedb 不再填 decls),不是「全部都是
            -- 產生碼」。走同一條降級路徑,免得整個 decl 層被靜默清空。
            Right []    -> ( unavailableSourceDecls
                           , [genFlagWarning (T.pack "decls table is empty")] )
            Right rows  -> (buildSourceDecls modIndex rows, [])
          (declFacts, declUnknown, declWarns) = case declOutcome of
            Left reason -> ([], Map.empty, [queryWarning "defs" reason])
            Right rows  -> let (fs, u) = declFactsOf srcDecls modIndex rows in (fs, u, [])
          (refFacts, refUnknown, refWarns) = case refOutcome of
            Left reason -> ([], Map.empty, [queryWarning "refs" reason])
            Right rows  -> let (fs, u) = refFactsOf srcDecls modIndex rows in (fs, u, [])
          unknown = Map.unionWith (+) declUnknown refUnknown
      pure ( declFacts <> refFacts
           , mapWarnings <> srcDeclWarns <> declWarns <> refWarns
               <> unknownWarnings unknown
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

-- | G-E003:__有原始碼宣告__的名字清單,兩個產生碼旗標的唯一判準。
--
-- 上游 @HieDb/Utils.hs@ 的 @goDec@ 只在遇到 @Decl@ \/ @ValBind@ context 時
-- 建 @decls@ 列,而 @defs@ 額外收編譯器產生的定義點,故
-- 「在 @defs@ 不在 @decls@」⇔「沒有人寫過那一行」。2026-08-22 實測
-- knot-hs 自身索引:@defs \\ decls@ 為 106 筆且 106\/106 全是 @$f…@ 字典,
-- 2834 筆真名零誤傷;fixture @test\/fixtures\/hiedb@ 為 @$fEqColor@ \/
-- @$fShowColor@ 兩筆。這是 hiedb 兩張表的__結構事實__,不是 @$f@ 前綴的
-- 名字啟發式(graph-core design.md「不做啟發式」因此不受影響)。
--
-- 只取 @(hieFile, occ)@:@decls@ 的 span 欄位是 'qRefs' 那條 join 的事,
-- 本查詢只要「有沒有這一列」。
qDeclOccs :: Query
qDeclOccs = sql "SELECT hieFile, occ FROM decls ORDER BY hieFile, occ"

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
buildModIndex
  :: ProjectMeta
  -> (Text -> Maybe Text)   -- ^ hieFile → 套件名(B002;解不出給 Nothing 即退回舊路)
  -> [ModRow]
  -> (Map Text ModEntry, [ExtractWarning])
buildModIndex pm pkgOf rows = (idx, reverse warns)
 where
  (idx, warns) = foldl' step (Map.empty, []) rows
  step acc@(m, ws) r
    | mrIsBoot r = acc
    | otherwise =
        let modName = ModuleName (mrModule r)
        in case resolveModuleSourceFor pm (pkgOf (mrHieFile r)) modName (mrHsSrc r) of
             Just p  -> (Map.insert (mrHieFile r) (ModEntry modName p) m, ws)
             Nothing -> (m, unmapped r : ws)
  unmapped r = ExtractWarning
    { ewSource  = mrHieFile r
    , ewMessage = T.pack "cannot map indexed module " <> mrModule r
        <> T.pack " back to pmSources; skipping its decls and refs"
    }

-- | B002:套件感知的對映。多套件專案裡 cabal 以__套件目錄__為 cwd 呼叫 GHC,
-- @hs_src@ 是 @app\/Main.hs@ 這種套件相對路徑,'resolveModuleSource' 的後綴比對
-- 方向反了(@hs_src@ 比 @sfPath@ 短)、module 名比對又因多個 @Main@ 歧義——
-- 先以 @\<套件目錄\>\/\<hs_src\>@ 精確比對:在 'pmSources' 有同名項就定案(納入 →
-- 'Just';被排除 → 'Nothing',G-B001 不退回猜測);沒有同名項或資訊不足,
-- 一律退回 'resolveModuleSource',既有行為不變。
resolveModuleSourceFor
  :: ProjectMeta
  -> Maybe Text        -- ^ 套件名(來自 .hie 路徑或 'ComponentRef');Nothing = 不知道
  -> ModuleName        -- ^ mods.mod
  -> Maybe Text        -- ^ mods.hs_src
  -> Maybe FilePath
resolveModuleSourceFor pm mPkg modName mHsSrc =
  case mPkg >>= pkgDirOf of
    Nothing  -> fallback
    Just dir ->
      -- 路徑線索優先(與 'resolveModuleSource' 同序):(1) 套件相對 hs_src 精確命中
      -- (hie-instances 走這條:.hie 自帶 hie_hs_file);(2) hs_src 的後綴命中(單套件、
      -- 絕對路徑的情形)。命中即定案——被排除回 Nothing(G-B001),不退回猜測。
      case (mHsSrc >>= exactIn dir) `orElse` (mHsSrc >>= suffixHit) of
        Just sf -> if sfIncluded sf then Just (sfPath sf) else Nothing
        -- (3) 沒有路徑線索——hiedb 以 knot 的 cwd(repo 根)stat 套件相對路徑,stat 不到就把
        --     hs_src 存 NULL(B002 實測:多套件 fixture 四列全 NULL)。改在__該套件目錄內__
        --     以 module 名唯一比對:同名 Main 在不同套件各歸各家;仍歧義才退回全域舊路
        Nothing -> case [ sf | sf <- pmSources pm, sfIncluded sf, underDir dir (sfPath sf)
                             , sfModule sf == Just modName ] of
                     [sf] -> Just (sfPath sf)
                     _    -> fallback
 where
  fallback = resolveModuleSource (pmSources pm) modName mHsSrc
  orElse (Just x) _ = Just x
  orElse Nothing  y = y
  exactIn dir raw
    | relativeLike raw = find ((== joinRel dir (slashes raw)) . sfPath) (pmSources pm)
    | otherwise        = Nothing
  -- 與 resolveModuleSource 的 longestSuffixMatch 同一條規則(邊界落在 '/' 上、取最長)
  suffixHit raw =
    let src  = slashes raw
        hits = [ sf | sf <- pmSources pm, src == sfPath sf || ("/" <> sfPath sf) `isSuffixOf` src ]
    in case hits of
         [] -> Nothing
         _  -> Just (foldr1 (\a b -> if length (sfPath a) >= length (sfPath b) then a else b) hits)
  underDir dir p
    | dir == "." || null dir = True
    | otherwise              = (slashes (T.pack dir) <> "/") `isPrefixOf` p
  pkgDirOf name =
    case [ takeDirectory (pkgCabalFile p) | p <- pmPackages pm, pkgName p == name ] of
      (d : _) -> Just d
      []      -> Nothing
  slashes = T.unpack . T.map (\c -> if c == '\\' then '/' else c)
  -- 絕對路徑(磁碟機 / 根目錄開頭)不走這條:那是單套件 cwd = repo 根的情形,後綴比對本來就中
  relativeLike raw = case T.unpack raw of
    ('/' : _)           -> False
    (c : ':' : _) | c /= '.' -> False
    _                   -> True
  joinRel dir rel
    | dir == "." || null dir = rel
    | otherwise              = slashes (T.pack dir) <> "/" <> rel

-- | 從 .hie 路徑取套件名(B002):取 @.knot@ 之後、@build@ 之後的段交給
-- 'componentRefOf'(它本來就認得 cabal 的 builddir 佈局);認不得回 'Nothing'。
-- 不做 @makeRelative@——hiedb 存的 @hieFile@ 與 root 的大小寫 \/ 8.3 形式可能不同。
packageOfHiePath :: [Text] -> FilePath -> Maybe Text
packageOfHiePath pkgNames path =
  case dropWhile (/= ".knot") (splitDirectories path) of
    (".knot" : "build" : rest@(_ : _)) ->
      case componentRefOf pkgNames rest of
        ComponentRef (p, _) | not (T.null p) -> Just p
        _                                    -> Nothing
    _ -> Nothing

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
  :: [SourceFile]      -- ^ pmSources(**完整**清單,含 @sfIncluded = False@ 者)
  -> ModuleName        -- ^ mods.mod
  -> Maybe Text        -- ^ mods.hs_src(NULL 時為 Nothing)
  -> Maybe FilePath
resolveModuleSource sfs modName mHsSrc =
  case mHsSrc >>= longestSuffixMatch of
    -- 命中被排除的檔 → 這份 .hie 屬於納入範圍外的原始檔,整批跳過(G-B001)。
    -- 這裡**不能**退回 module 名猜測:同名時(exe 與 test-suite 都有 Main)
    -- 會把 test 的宣告掛到 executable 的檔案上。
    Just sf | sfIncluded sf -> Just (sfPath sf)
            | otherwise     -> Nothing
    -- 什麼都沒命中 → 路徑因大小寫 / 8.3 短檔名 / symlink 對不上,保命網照舊
    Nothing -> uniqueByModule
 where
  longestSuffixMatch raw =
    case [ sf | sf <- sfs, matches (normalise raw) (T.pack (sfPath sf)) ] of
      []   -> Nothing
      hits -> Just (longest hits)
  -- 同長度且同為後綴 ⇒ 同一個字串,故長度即全序
  longest = foldr1 (\a b -> if length (sfPath a) >= length (sfPath b) then a else b)
  matches src rel = src == rel || (T.singleton '/' <> rel) `T.isSuffixOf` src
  normalise = T.map (\c -> if c == '\\' then '/' else c)
  uniqueByModule =
    case [ sfPath sf | sf <- sfs, sfIncluded sf, sfModule sf == Just modName ] of
      [p] -> Just p
      _   -> Nothing    -- 零筆或多筆(例:多個 Main)都視為落空

--------------------------------------------------------------------------------
-- 產生碼判準(G-E003)
--------------------------------------------------------------------------------

-- | @hieFile@ → 該檔__有原始碼宣告__的 @occ@ 原文集合(來自 'qDeclOccs')。
--
-- 包一層 'Maybe':'Nothing' 代表 @decls@ 索引__整個不可用__(查詢失敗),
-- 此時判準一律回 'False'——退回本次優化前的行為。**絕不因為查不到就把全部
-- 宣告當成產生碼**:那會在一次查詢失敗時清空整個 decl 層。
newtype SourceDecls = SourceDecls (Maybe (Map Text (Set Text)))
  deriving (Eq, Show)

-- | @decls@ 查詢失敗時用的降級值。
unavailableSourceDecls :: SourceDecls
unavailableSourceDecls = SourceDecls Nothing

-- | @(hieFile, occ)@ 列 → 'SourceDecls'。只收 'buildModIndex' 認得的
-- @hieFile@(對映不到 @pmSources@ 的 module 其 decl \/ ref 本來就整批跳過)。
buildSourceDecls :: Map Text ModEntry -> [(Text, Text)] -> SourceDecls
buildSourceDecls modIndex rows = SourceDecls (Just (foldl' step Map.empty rows))
 where
  step acc (hf, occ)
    | hf `Map.member` modIndex = Map.insertWith Set.union hf (Set.singleton occ) acc
    | otherwise                = acc

-- | 產生碼判準:__名字在其所屬檔案的 @decls@ 沒有列__ ⇒ 沒有原始碼宣告
-- AST 節點 ⇒ deriving \/ TH 產生。
--
-- 第二參數是該名字所屬檔案的 @hieFile@;'Nothing' 代表名字的 module 不在
-- 索引內(外部套件)或對映不唯一,一律回 'False'——外部目標本來就由
-- graph-core 規則 1 丟棄,不該由本旗標處理。
isGeneratedName :: SourceDecls -> Maybe Text -> Text -> Bool
isGeneratedName (SourceDecls Nothing)    _         _   = False
isGeneratedName _                        Nothing   _   = False
isGeneratedName (SourceDecls (Just idx)) (Just hf) occ =
  occ `Set.notMember` Map.findWithDefault Set.empty hf idx

-- | @ModuleName@ → @hieFile@ 反查(ref 的__目標__ module 用)。
--
-- 同一個 module 名對到多個 @hieFile@ 時存 'Nothing'(不唯一 ⇒ 判不出來 ⇒
-- 'isGeneratedName' 回 'False',保守放行)。
hieFileByModule :: Map Text ModEntry -> Map ModuleName (Maybe Text)
hieFileByModule = Map.foldrWithKey step Map.empty
 where
  step hf e = Map.insertWith (\_ _ -> Nothing) (meModule e) (Just hf)

--------------------------------------------------------------------------------
-- 事實產出
--------------------------------------------------------------------------------

-- | @defs@ → 'FactDecl'。第二個回傳值是未知 namespace 前綴的計數
-- (呼叫端彙整成警告)。
declFactsOf :: SourceDecls -> Map Text ModEntry -> [DefRow] -> ([Fact], Map Text Int)
declFactsOf srcDecls modIndex = foldl' step ([], Map.empty)
 where
  step acc@(fs, u) r = case Map.lookup (drHieFile r) modIndex of
    Nothing -> acc                                    -- 已在 buildModIndex 記過警告
    Just e  -> case parseOcc (drOcc r) of
      Nothing -> (fs, bumpUnknown (drOcc r) u)
      Just (occ, ns) ->
        ( FactDecl
            { fdName = QualName (meModule e) occ ns
            , fdKind = declKindOf ns
            -- G-E003:def 有列、decls 無列 ⇒ 沒有原始碼宣告 ⇒ 產生碼
            , fdGenerated =
                isGeneratedName srcDecls (Just (drHieFile r)) (drOcc r)
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
refFactsOf :: SourceDecls -> Map Text ModEntry -> [RefJoinRow] -> ([Fact], Map Text Int)
refFactsOf srcDecls modIndex = foldl' step ([], Map.empty) . groupAdjacent refKey
 where
  targetHieFile = hieFileByModule modIndex
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
            -- G-E003:判準同 fdGenerated,只是查的是__目標__ module 的 decls。
            -- 目標為外部套件時 targetHieFile 落空 → 恆 False。
            , frTargetGenerated = isGeneratedName srcDecls
                (Map.findWithDefault Nothing (ModuleName (rjMod r)) targetHieFile)
                (rjOcc r)
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

-- | G-E003 的降級警告:@decls@ occ 索引讀不到,兩個產生碼旗標退回 'False'。
-- 訊息明說「當成非產生碼」,免得下游看到 deriving 字典節點時無從追因。
genFlagWarning :: Text -> ExtractWarning
genFlagWarning reason = ExtractWarning
  { ewSource  = hiedbName
  , ewMessage = T.pack "cannot read decls table for generated-code flags: "
      <> reason <> T.pack "; treating every declaration as hand-written"
  }

-- | 規則 7:把任何例外轉成降級原因用的文字。
attempt :: IO a -> IO (Either Text a)
attempt act = do
  r <- try act
  pure $ case r of
    Left e  -> Left (T.pack (displayException (e :: SomeException)))
    Right a -> Right a
