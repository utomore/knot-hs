-- | hie-instances 模組:直接讀 @.hie@ 的 @ClsInstD@ 節點 → 'FactInstance'
-- (F008、ADR-007)。fact-pipeline 的第五站,接在 hie-facts 之後。
--
-- Level 2:@.design/subsystems/extraction/design.md@「內部模組劃分 › hie-instances」;
-- 落實抽取規則 2(@FactInstance@ 永遠且只來自本站)、8(只讀同版 GHC 的 @.hie@,
-- 沿用 hie-index 的 'partitionByGhc')、9(單檔 best-effort:讀不過 \/ 對映不到 \/
-- 解不出 class 都是一則警告 + 跳過)、10(事實全序、警告依檔序)。
--
-- __本模組是 @src\/@ 內唯一准 import @GHC.*@ 的模組__(ADR-007):@.hie@ 的讀取器與
-- AST 型別住在 @ghc@ package;hiedb 本來就依賴它,閉包沒變大。@.hie@ 的任何型別
-- 不得出現在本模組的匯出簽名上——對外只回 @[Fact]@ 與 @[ExtractWarning]@。
--
-- == 為什麼是樹形規則、不是 @hie_entity_infos@
--
-- 2026-08-23 spike:每個明寫的 @instance@ 是一個帶 @("ClsInstD", "InstDecl")@ 註記的
-- 節點,第一個子節點是標頭;@deriving@ 的任何形式都__不產生__節點。GHC 9.14 的
-- @hie_entity_infos@ 對__外部__ class(@Show@、@FromRow@)只標 @EntityTypeConstructor@,
-- 所以 class 名只能靠標頭子樹的形狀取:剝掉 context(@HsQualTy@ \/ @HsForAllTy@ 的
-- 最後一個子節點才是 body)與括號,取最左邊的 @HsTyVar@ 葉。
--
-- __不做__:不讀 @deriving@(沒有節點、也不該有)、不為 @FactInstance@ 加產生碼旗標
-- (只取 @SourceInfo@ 來源即可)、不解析 instance 方法的引用(@calls@ 仍由 hie-facts
-- 負責)、不處理 @.hie-boot@、不碰 hiedb 索引。
module Knot.Extract.HieInstances
  ( -- * Level 2 模組介面
    readInstanceFacts
    -- * 內部純函數(非契約面;1-to-1 測試取用)
  , normaliseHead
  ) where

import Control.Exception (SomeException, displayException, try)
import Data.List (sort, sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.FilePath ((</>))

import GHC.Data.FastString (unpackFS)
import GHC.Iface.Ext.Binary (HieFileResult (..), readHieFile)
import GHC.Iface.Ext.Types
  ( ContextInfo (..)
  , HieAST (..)
  , HieASTs (..)
  , HieFile (..)
  , IdentifierDetails (..)
  , NodeAnnotation (..)
  , NodeInfo (..)
  , NodeOrigin (..)
  , SourcedNodeInfo (..)
  )
import GHC.Types.Name (Name, nameModule_maybe, nameOccName)
import GHC.Types.Name.Occurrence (isTcOcc, occNameString)
import GHC.Types.SrcLoc (RealSrcSpan, srcSpanEndCol, srcSpanEndLine, srcSpanStartCol, srcSpanStartLine)
import GHC.Unit.Types (moduleName)
import HieDb (makeNc)
import Language.Haskell.Syntax.Module.Name (moduleNameString)

import Knot.Extract.BuildDriver (HieLayout (..))
import Knot.Extract.HieIndex (ownGhcVersion, partitionByGhc)
import Knot.Extract.HiedbFacts (resolveModuleSource)
import Knot.Extract.Types
  ( ExtractOptions (..)
  , ExtractWarning (..)
  , Fact (..)
  , NameSpace (..)
  , QualName (..)
  )
import Knot.Meta.Types (ModuleName (..), ProjectMeta (..))

-- | 讀 'HieLayout' 裡與 knot 同版 GHC 的每個 @.hie@,產出 'FactInstance'
-- (Level 2 模組介面,簽名照契約)。__不拋例外__:單檔任何失敗收斂為一則警告。
-- 零個相符的 @.hie@ 回 @([], [])@——那種情況 hie-index 已先以 @VersionMismatch@
-- 失敗,本站不會被呼叫到,這裡只是防禦。
readInstanceFacts :: ExtractOptions -> HieLayout -> ProjectMeta -> IO ([Fact], [ExtractWarning])
readInstanceFacts opts layout pm =
  case fst (partitionByGhc ownGhcVersion layout) of
    [] -> pure ([], [])
    matching -> do
      nc <- makeNc
      results <- mapM (readOne nc . snd) matching
      -- 規則 10:事實全序(Fact 的 Ord);警告依 HieLayout 的檔序(已是碼位序)
      pure (sort (concatMap fst results), concatMap snd results)
 where
  readOne nc rel = do
    r <- try (readHieFile nc (rootDir opts </> rel))
    case r of
      Left (e :: SomeException) ->
        pure ([], [warn rel ("cannot read .hie: " <> firstLine (displayException e))])
      Right hfr ->
        let hf      = hie_file_result hfr
            modName = ModuleName (T.pack (moduleNameString (moduleName (hie_module hf))))
        in case resolveModuleSource (pmSources pm) modName (Just (T.pack (hie_hs_file hf))) of
             -- 命中被排除的檔或對不上 → 與 hie-facts 同一條規則(G-B001)整批跳過
             Nothing -> pure ([], [ExtractWarning (T.pack rel)
                                     (T.pack "cannot map indexed module " <> unModule modName
                                       <> T.pack " back to pmSources; skipping its instances")])
             Just sf -> pure (instanceFacts sf hf)
  warn rel msg = ExtractWarning (T.pack rel) (T.pack msg)
  unModule (ModuleName m) = m
  firstLine = takeWhile (/= '\n')

-- | 一份 @.hie@ 的全部 instance 事實(純函數)。@file@ 是已對回的 @sfPath@ 原文。
instanceFacts :: FilePath -> HieFile -> ([Fact], [ExtractWarning])
instanceFacts file hf = (facts, warns)
 where
  -- .hie 內嵌完整原始碼;以字元(非 byte)切片,GHC 的行列是字元座標
  srcLines = T.lines (T.filter (/= '\r') (TE.decodeUtf8With lenientDecode (hie_hs_src hf)))
  nodes    = sortOn (\n -> (srcSpanStartLine (nodeSpan n), srcSpanStartCol (nodeSpan n)))
               (concatMap clsInstNodes (Map.elems (getAsts (hie_asts hf))))
  outcomes = map one nodes
  facts    = [ f | Right f <- outcomes ]
  warns    = [ w | Left  w <- outcomes ]

  one n = case nodeChildren n of
    [] -> Left (ExtractWarning (T.pack file)
                 (T.pack ("instance declaration at line " <> show (srcSpanStartLine (nodeSpan n))
                          <> " has no head node; skipping")))
    (h : _) ->
      let hd = normaliseHead (sliceSpan srcLines (nodeSpan h))
      in case classOf h of
           Just cls -> Right FactInstance
             { fiClass = cls, fiInstHead = hd
             , fiInstFile = file, fiInstLine = srcSpanStartLine (nodeSpan h) }
           Nothing  -> Left (ExtractWarning (T.pack file)
                              (T.pack "cannot resolve class of instance " <> hd))

-- | 深度優先收集帶 @ClsInstD@ 註記、且來源為 @SourceInfo@ 的節點。
-- @GeneratedInfo@ 的 instance(TH \/ deriving 衍生物)不是使用者寫的架構事實,跳過。
clsInstNodes :: HieAST a -> [HieAST a]
clsInstNodes n =
  [ n | hasConstr "ClsInstD" n ] ++ concatMap clsInstNodes (nodeChildren n)

-- | 節點的 @SourceInfo@ 那份 'NodeInfo'(沒有就當作沒有註記、沒有識別字)。
sourceInfo :: HieAST a -> Maybe (NodeInfo a)
sourceInfo n = Map.lookup SourceInfo (getSourcedNodeInfo (sourcedNodeInfo n))

hasConstr :: String -> HieAST a -> Bool
hasConstr c n =
  any (\a -> unpackFS (nodeAnnotConstr a) == c)
      (maybe [] (Set.toList . nodeAnnotations) (sourceInfo n))

-- | 標頭子樹的 class 解析(設計文檔「實作方式 › 6」的 peel 規則,判定順序即列序):
-- context 取尾、括號與應用取首、@HsTyVar@ 葉取 @Use@ 的型別層 'Name'。
-- 同一節點可能同時帶多個註記(標頭節點本身就是 @HsSig@ + @HsAppTy@ + @VarBind@),
-- 先命中者先。
classOf :: HieAST a -> Maybe QualName
classOf n
  | anyConstr ["HsQualTy", "HsForAllTy"]        = lastChild  >>= classOf
  | anyConstr ["HsParTy", "HsKindSig", "HsAppTy"] = firstChild >>= classOf
  | hasConstr "HsTyVar" n                       = useTyName n >>= toQualName
  | otherwise                                   = Nothing
 where
  anyConstr = any (`hasConstr` n)
  firstChild = case nodeChildren n of { (c : _) -> Just c; [] -> Nothing }
  lastChild  = case reverse (nodeChildren n) of { (c : _) -> Just c; [] -> Nothing }

-- | 葉節點上「被使用的型別層名字」:@identInfo ∋ Use@ 且 occ 在 type\/class
-- namespace(排掉同一節點上的 @C:Renderable@ 字典建構子與 @$c…@ 方法)。多於一個時
-- 依 occ 字串序取最小——不依 'Name' 的 'Ord'(那是 unique 序,跨次執行不穩)。
useTyName :: HieAST a -> Maybe Name
useTyName n =
  case sortOn (occNameString . nameOccName) candidates of
    (x : _) -> Just x
    []      -> Nothing
 where
  candidates =
    [ nm
    | ni <- maybe [] pure (sourceInfo n)
    , (Right nm, det) <- Map.toList (nodeIdentifiers ni)
    , Use `Set.member` identInfo det
    , isTcOcc (nameOccName nm)
    ]

-- | 'Name' → 'QualName'(class 定義所在 module、occ、'TypeNs')。
-- 沒有 module 的名字(區域型別變數之類)不可能是 class → 'Nothing'。
toQualName :: Name -> Maybe QualName
toQualName nm = do
  m <- nameModule_maybe nm
  pure QualName
    { qnModule = ModuleName (T.pack (moduleNameString (moduleName m)))
    , qnOcc    = T.pack (occNameString (nameOccName nm))
    , qnSpace  = TypeNs
    }

-- | 依 span 從原始碼行切出文字(起點含、終點不含,GHC 的慣例);跨行時以單一
-- 空白接合——正規化在 'normaliseHead' 一併做。
sliceSpan :: [Text] -> RealSrcSpan -> Text
sliceSpan ls sp =
  case take (l2 - l1 + 1) (drop (l1 - 1) ls) of
    []         -> T.empty
    [l]        -> T.take (c2 - c1) (T.drop (c1 - 1) l)
    (f : rest) -> T.unwords (T.drop (c1 - 1) f : init rest ++ [T.take (c2 - 1) (last rest)])
 where
  l1 = srcSpanStartLine sp
  l2 = srcSpanEndLine sp
  c1 = srcSpanStartCol sp
  c2 = srcSpanEndCol sp

-- | 標頭文字正規化:任何空白序列(含換行、tab)收斂為單一空白、去頭尾。
-- 這是 graph-core instance 節點 id(@\<mod\>#i:\<head\>@)的一部分,必須決定性。
normaliseHead :: Text -> Text
normaliseHead = T.unwords . T.words
