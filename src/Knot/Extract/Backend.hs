-- | 後端抽象(Level 2 模組間公開介面)與 backend-select 的調度引擎。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「模組間公開介面」;
-- 落實抽取規則 1(納入範圍)、3(auto 合成與降級)、7(best-effort)、
-- 8(決定性)。
module Knot.Extract.Backend
  ( -- * 後端抽象
    Backend (..)
  , ProbeResult (..)
    -- * 後端名常數
  , importScanName
  , hiedbName
    -- * 調度引擎(非契約面)
  , runBackends
  ) where

import Control.Exception (SomeException, displayException, evaluate, try)
import Data.List (sort)
import qualified Data.Text as T
import Data.Text (Text)

import Knot.Extract.Types
  ( BackendChoice (..)
  , BackendReport (..)
  , CapabilityLevel (..)
  , ExtractOptions (..)
  , ExtractResult (..)
  , ExtractWarning (..)
  , Fact
  )
import Knot.Meta.Types (ProjectMeta (..), SourceFile (..))

-- | backend-select 調度的統一介面,兩個後端各實現一份。
data Backend = Backend
  { bName  :: Text
  , bLevel :: CapabilityLevel
  , bProbe :: ExtractOptions -> ProjectMeta -> IO ProbeResult
  , bRun   :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
  }

-- | 探測結果;@Unavailable@ 的原因文字直接進 'BackendReport'。
data ProbeResult = Available | Unavailable Text
  deriving (Eq, Show)

-- | import-scan 後端的契約名(即 @brBackend@ 的值域之一)。
importScanName :: Text
importScanName = T.pack "import-scan"

-- | hiedb 後端的契約名(即 @brBackend@ 的值域之一)。
hiedbName :: Text
hiedbName = T.pack "hiedb"

-- | 單一後端在本次調度中的結果(內部型別)。
data Outcome = Outcome
  { oReport   :: BackendReport
  , oFacts    :: [Fact]
  , oWarnings :: [ExtractWarning]
  , oLevel    :: Maybe CapabilityLevel   -- ^ 只有實際跑成功者才有值
  }

-- | 調度引擎;僅為 1-to-1 測試(假後端)而匯出,非 Level 2 契約面
-- (F001 假設 A6)。
--
-- 管線:窄化(規則 1)→ 選擇 → 探測 → best-effort 執行(規則 7)
-- → 合成(規則 8)。@erReports@ 依註冊序,每個註冊後端剛好一筆;
-- @erWarnings@ 亦依註冊序串接;@erFacts@ 為全序排序結果,
-- 不受後端產出序影響。
runBackends :: [Backend] -> ExtractOptions -> ProjectMeta -> IO ExtractResult
runBackends registry opts pm = do
  outcomes <- mapM (runOne opts (narrowScope pm)) registry
  pure ExtractResult
    { erFacts    = sort (concatMap oFacts outcomes)
    , erLevel    = synthLevel outcomes
    , erReports  = map oReport outcomes
    , erWarnings = concatMap oWarnings outcomes
    }

-- | 規則 1:只把 @sfIncluded = True@ 的原始檔交給後端;
-- @pmPackages@ / @pmHie@ / @pmWarnings@ 原樣保留(F001 假設 A1)。
narrowScope :: ProjectMeta -> ProjectMeta
narrowScope pm = pm { pmSources = filter sfIncluded (pmSources pm) }

-- | 規則 3:@BackendChoice@ 以 'bName' 比對契約字串常數(F001 假設 A2)。
isSelected :: BackendChoice -> Backend -> Bool
isSelected Auto        _ = True
isSelected ImportsOnly b = bName b == importScanName
isSelected HiedbOnly   b = bName b == hiedbName

-- | 單一後端的「選擇 → 探測 → 執行」,全程包例外(規則 7)。
runOne :: ExtractOptions -> ProjectMeta -> Backend -> IO Outcome
runOne opts pm b
  | not (isSelected (backendChoice opts) b) =
      -- 未選中不是錯誤:進報告(F001 假設 A5),不產警告
      pure (skipped (T.pack "not selected by backendChoice"))
  | otherwise = do
      probed <- attempt (bProbe b opts pm >>= evaluate)
      case probed of
        Left err              -> pure (skipped err)          -- 探測抛例外視同不可用
        Right (Unavailable r) -> pure (skipped r)
        Right Available       -> do
          ran <- attempt $ do
            (fs, ws) <- bRun b opts pm
            _ <- evaluate (length fs)   -- 強制 list spine,讓惰性例外落在 try 內
            _ <- evaluate (length ws)
            pure (fs, ws)
          case ran of
            Left err -> pure Outcome
              { oReport   = BackendReport (bName b) False err
              , oFacts    = []                                -- 失敗後端的事實全數丟棄
              , oWarnings = [ExtractWarning (bName b) err]
              , oLevel    = Nothing
              }
            Right (fs, ws) -> pure Outcome
              { oReport   = BackendReport (bName b) True T.empty
              , oFacts    = fs
              , oWarnings = ws                                -- 後端自報的警告原樣併入
              , oLevel    = Just (bLevel b)
              }
 where
  skipped reason = Outcome
    { oReport   = BackendReport (bName b) False reason
    , oFacts    = []
    , oWarnings = []
    , oLevel    = Nothing
    }

-- | 包例外並把例外轉成報告 / 警告用的文字。
attempt :: IO a -> IO (Either Text a)
attempt act = do
  r <- try act
  pure $ case r of
    Left e  -> Left (T.pack (displayException (e :: SomeException)))
    Right a -> Right a

-- | 規則 3 + 假設 A4:實際跑成功者的能力等級取最大;無人成功回 'ModuleLevel'。
synthLevel :: [Outcome] -> CapabilityLevel
synthLevel outcomes = foldr max ModuleLevel [l | Just l <- map oLevel outcomes]
