-- | extraction 對外契約 DTO 與事實流 DTO。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「對外契約」「事實流 DTO」。
-- 'ModuleName' 依委派決策 D2 直接共用 project-meta 契約(@Knot.Meta.Types@),
-- 本 module 不重複定義。
--
-- deriving 說明:全部 DTO 有 'Eq' / 'Show';'Fact' 與其成員
-- ('QualName' / 'NameSpace' / 'DeclKind')與 'CapabilityLevel' 另有 'Ord',
-- 支撐抽取規則 8(決定性)的全序排序(F001 假設 A3)。
module Knot.Extract.Types
  ( -- * 對外契約
    ExtractOptions (..)
  , BackendChoice (..)
  , ExtractResult (..)
  , CapabilityLevel (..)
    -- * 事實流
  , QualName (..)
  , NameSpace (..)
  , Fact (..)
  , DeclKind (..)
    -- * 回報
  , BackendReport (..)
  , ExtractWarning (..)
  ) where

import Data.Text (Text)

import Knot.Meta.Types (ModuleName (..))

-- | 抽取選項。@rootDir@ 是 @sfPath@ / @hieFiles@ 等 repo 相對路徑的錨點
-- (階段一閘門裁決後的契約變更;後端要開檔就得有這個 root,
-- 抽取規則 6 的 @\<root\>\/.knot\/hiedb.sqlite@ 亦以此為準)。
data ExtractOptions = ExtractOptions
  { rootDir       :: FilePath          -- ^ 專案根目錄
  , backendChoice :: BackendChoice     -- ^ 對應 CLI --backend
  , hiedbExe      :: Maybe FilePath    -- ^ 覆寫 hiedb 執行檔(預設查 PATH)
  , dbPath        :: Maybe FilePath    -- ^ 覆寫索引位置(預設 <root>/.knot/hiedb.sqlite)
  }
  deriving (Eq, Show)

data BackendChoice = Auto | ImportsOnly | HiedbOnly
  deriving (Eq, Show)

data ExtractResult = ExtractResult
  { erFacts    :: [Fact]
  , erLevel    :: CapabilityLevel      -- ^ 實際達到的能力等級
  , erReports  :: [BackendReport]      -- ^ 各後端:用了/沒用 + 原因
  , erWarnings :: [ExtractWarning]     -- ^ best-effort 蒐集,呼叫端印 stderr
  }
  deriving (Eq, Show)

-- | 'Ord' 的建構子序即能力高低:@ModuleLevel < DeclLevel@。
data CapabilityLevel = ModuleLevel | DeclLevel
  deriving (Eq, Ord, Show)

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
-- 後端遇到時跳過該列,並依前綴彙整成一則警告(不逐列刷警告)。
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
      , frFromDecl   :: Maybe QualName  -- ^ 引用發生在哪個頂層宣告內,由後端解析
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

data BackendReport = BackendReport
  { brBackend :: Text                   -- ^ "import-scan" | "hiedb"
  , brUsed    :: Bool
  , brDetail  :: Text                   -- ^ 未用時的降級原因;用了時為空字串
  }
  deriving (Eq, Show)

-- | 帶來源(檔案路徑或後端名)的警告(委派決策 D1,比照 @MetaWarning@ 模式)。
data ExtractWarning = ExtractWarning
  { ewSource  :: Text
  , ewMessage :: Text
  }
  deriving (Eq, Show)
