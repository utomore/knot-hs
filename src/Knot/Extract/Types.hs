-- | extraction 對外契約 DTO 與事實流 DTO。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「對外契約」「事實流 DTO」。
-- 'ModuleName' 依委派決策 D2 直接共用 project-meta 契約(@Knot.Meta.Types@),
-- 本 module 不重複定義,但**代為 re-export**:契約的四個 DTO 欄位都是這個型別,
-- 消費端不該為了替收到的值命名而再開一個 import 繞回源頭(G-E004、ADR-005)。
--
-- S5(ADR-006、F007)起的形狀:沒有後端選擇、沒有能力等級、沒有後端報告。
-- 'extract' 回 @Either ExtractFailure ExtractResult@——兩層都成立才有事實流,
-- 任一層整體拿不到就是 'ExtractFailure',不存在部分成功。
--
-- deriving 說明:全部 DTO 有 'Eq' / 'Show';'Fact' 與其成員
-- ('QualName' / 'NameSpace' / 'DeclKind')另有 'Ord',支撐抽取規則 10
-- (決定性)的全序排序(F001 假設 A3)。
module Knot.Extract.Types
  ( -- * 對外契約
    ExtractOptions (..)
  , ExtractResult (..)
  , ExtractFailure (..)
    -- * 事實流
  , QualName (..)
  , NameSpace (..)
  , Fact (..)
  , DeclKind (..)
    -- * 回報
  , ExtractWarning (..)
    -- * .hie 佈局(ADR-006;build-driver → hie-index 的載體)
  , HieLayout (..)
    -- * 共用詞彙型別(re-export 自 project-meta,見 ADR-005)
  , ModuleName (..)
  , ComponentRef (..)
  ) where

import Data.Text (Text)

import Knot.Meta.Types (ComponentRef (..), ModuleName (..))

-- | 抽取選項。@rootDir@ 是 @sfPath@ 與 'HieLayout' 內各 repo 相對路徑的錨點,
-- 也是 @.knot\/@ 快取(builddir、@hiedb.sqlite@)的所在(抽取規則 7)。
-- 使用者需要知道的只有這一個欄位——@knot extract .@ 就是全部(ADR-006)。
data ExtractOptions = ExtractOptions
  { rootDir :: FilePath                -- ^ 專案根目錄
  }
  deriving (Eq, Show)

-- | 兩層都成立時的結果:事實流(全序排序)與各站的單檔警告(站序固定)。
data ExtractResult = ExtractResult
  { erFacts    :: [Fact]
  , erWarnings :: [ExtractWarning]     -- ^ best-effort 蒐集,呼叫端印 stderr
  }
  deriving (Eq, Show)

-- | graph-core 鑄造決定性節點 id 的原料(Module + OccName + namespace)。
data QualName = QualName
  { qnModule :: ModuleName
  , qnOcc    :: Text
  , qnSpace  :: NameSpace              -- ^ 型別的 Foo 與值的 Foo 是兩個名字
  }
  deriving (Eq, Ord, Show)

-- | 四值與 hiedb 的 @occ@ 前綴一對一。刻意不壓縮成「值\/型別」二分——
-- graph-core 以 @(Module, Occ, namespace)@ 鑄決定性節點 id,壓縮會讓不同的
-- GHC 實體可能撞出同一個 id。
--
-- hiedb 另有 @\"z:\"@(型別變數,見其 @HieDb/Types.hs@ 的 @toNsChar@):
-- 刻意不涵蓋。型別變數是簽名內的區域名字、不是架構實體,鑄成圖節點無意義。
-- hie-facts 遇到時跳過該列,並依前綴彙整成一則警告(不逐列刷警告)。
data NameSpace
  = ValueNs        -- ^ hiedb @\"v:\"@ 一般值(函式、變數)
  | DataConNs      -- ^ hiedb @\"c:\"@ 資料建構子
  | TypeNs         -- ^ hiedb @\"t:\"@ 型別與 class(GHC 的 @tcClsName@,兩者同命名空間)
  | FieldNs        -- ^ hiedb @\"f\<父型別\>:\"@ 記錄欄位選擇器
  deriving (Eq, Ord, Show)

data Fact
  = FactModule                          -- ^ 檔案裡實際宣告的 module
      { fmFile :: FilePath, fmModule :: ModuleName }
  | FactImport                          -- ^ 字面 import 行(imports 邊唯一來源)
      { fiFrom :: ModuleName, fiTo :: ModuleName
      , fiFile :: FilePath, fiLine :: Int }
  | FactDecl                            -- ^ 頂層宣告
      { fdName :: QualName, fdKind :: DeclKind
      , fdGenerated :: Bool             -- ^ 宣告__本身__是產生碼(G-E003:hiedb
                                        --   @defs@ 有列、@decls@ 無列 ⇒ 沒有原始碼
                                        --   宣告 AST 節點 ⇒ deriving \/ TH 字典)
      , fdFile :: FilePath, fdLine :: Int }
  | FactRef                             -- ^ 名稱引用(calls / uses 邊的原料)
      { frFromModule :: ModuleName
      , frFromDecl   :: Maybe QualName  -- ^ 引用發生在哪個頂層宣告內,由 hie-facts 解析
      , frTarget     :: QualName
      , frGenerated  :: Bool            -- ^ 引用__站點__是產生碼(hiedb @refs.is_generated@)
      , frTargetGenerated :: Bool       -- ^ 引用__目標__是產生碼宣告(G-E003,判準同
                                        --   'fdGenerated');目標 module 不在索引內
                                        --   (外部套件)時恆 'False'
      , frFile :: FilePath, frLine :: Int }
  | FactInstance                        -- ^ implements 邊的兩端
      { fiClass    :: QualName          -- ^ class(TypeNs)
      , fiInstHead :: Text              -- ^ 渲染後的 instance 標頭,如 "Renderable Sprite"
      , fiInstFile :: FilePath, fiInstLine :: Int }
  deriving (Eq, Ord, Show)

data DeclKind
  = ValueDecl | DataDecl | ClassDecl | InstanceDecl
  | TypeSynDecl | PatSynDecl | FamilyDecl
  deriving (Eq, Ord, Show)

-- | 帶來源(檔案路徑或站名)的警告(委派決策 D1,比照 @MetaWarning@ 模式)。
-- @ewSource@ 的值域是契約:單檔警告填 repo 相對路徑,站級警告填
-- @\"import-scan\"@ \/ @\"hiedb\"@。
data ExtractWarning = ExtractWarning
  { ewSource  :: Text
  , ewMessage :: Text
  }
  deriving (Eq, Show)

-- | 整體失敗(ADR-006):兩層任一層拿不到。呼叫端 exit 1、不寫檔,與 @--strict@
-- 無關。'BuildFailed' 由 build-driver 產生,'VersionMismatch' 由 hie-index,
-- 'IndexFailed' 由 hie-index(索引檔層級)或 fact-pipeline(索引讀不出任何
-- 頂層宣告,規則 3 的 decl 層判準),'NoSources' 由 fact-pipeline。
data ExtractFailure
  = BuildFailed     { bfComponent :: Text, bfDetail :: Text }  -- ^ cabal 回報的失敗單元(解析不到為 @all@)與輸出尾段
  | VersionMismatch { vmHie :: Text, vmKnot :: Text }          -- ^ .hie 的 GHC 版本 ≠ knot 的(ADR-001)
  | IndexFailed     { ifDetail :: Text }                        -- ^ hiedb 索引整體失敗
  | NoSources                                                   -- ^ 納入範圍內零個原始檔
  deriving (Eq, Show)

-- | build-driver 的產物:@.knot/build@ 下各 component 輸出目錄裡的 @.hie@。
-- 路徑 repo 相對、正斜線,依碼位序;每筆附其 component(由 cabal 佈局路徑推得)。
data HieLayout = HieLayout
  { hlRoot  :: FilePath                       -- ^ @\<root\>\/.knot\/build@
  , hlFiles :: [(ComponentRef, FilePath)]
  }
  deriving (Eq, Show)
