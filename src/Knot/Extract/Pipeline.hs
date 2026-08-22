-- | fact-pipeline 模組:固定四站、全有全無的事實管線(F007 two-layer-contract)。
--
-- Level 2 契約:@.design/subsystems/extraction/design.md@「內部模組劃分 ›
-- fact-pipeline」;落實抽取規則 1(納入範圍零檔 → 'NoSources')、2(module 層
-- 只來自 import-scan、decl 層只來自 hie-facts——沒有第二個來源可混)、
-- 3(兩層缺一不可;decl 層「成立」= 至少一筆 'FactDecl')、9(單檔警告原樣
-- 併入、整體失敗只走 @Left@)、10(事實全序排序、警告依站序)。
--
-- 取代 S1 的 @Knot.Extract.Backend@(註冊表 → 探測 → 選擇 → 降級合成):
-- 那一層的每個概念(後端選擇、能力等級、後端報告)在 ADR-006 之後都沒有
-- 對應物,整個模組連同型別一起拆掉。
--
-- 本模組只認識 'Knot.Extract.Types' 與 'Knot.Meta.Types',不 import 任何一站的
-- 模組;四站由 'Knot.Extract.extract' 裝進 'Stages' 交進來,四站模組也不
-- import 本模組——沒有環。
--
-- __不在管線層包 @try@__:四站的契約都是「不拋例外」(import-scan 逐檔 @try@、
-- build-driver 收斂 @IOException@、hie-index \/ hie-facts 收斂 @SomeException@);
-- 逃出來的例外是該站的 bug,'ExtractFailure' 也沒有對應的建構子,硬包只會把
-- bug 偽裝成「建置失敗」。
module Knot.Extract.Pipeline
  ( -- * 可注入的四站(非契約面:僅為 1-to-1 測試而匯出,與 F001 的調度引擎同模式)
    Stages (..)
  , runPipeline
  ) where

import Data.List (sort)
import qualified Data.Text as T
import Data.Text (Text)

import Knot.Extract.Types
  ( ExtractFailure (..)
  , ExtractOptions
  , ExtractResult (..)
  , ExtractWarning (..)
  , Fact (..)
  , HieLayout
  )
import Knot.Meta.Types (ProjectMeta (..), SourceFile (..))

-- | 四站。對索引控制代碼型別 @h@ 多型:'Knot.Extract.HieIndex.IndexHandle'
-- 的建構子不匯出(F006 刻意不透明),假階段用 @h = ()@ 就能測全有全無的
-- 邏輯,不必真的建索引。
data Stages h = Stages
  { stScan  :: ExtractOptions -> ProjectMeta -> IO ([Fact], [ExtractWarning])
    -- ^ 站 1 import-scan:module 層事實;單檔失敗已在站內轉警告,不會失敗
  , stBuild :: ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure HieLayout)
    -- ^ 站 2 build-driver:插樁建置 → @.hie@ 佈局;失敗 = 'BuildFailed'
  , stIndex :: ExtractOptions -> HieLayout -> IO (Either ExtractFailure h)
    -- ^ 站 3 hie-index:索引就緒;失敗 = 'VersionMismatch' \/ 'IndexFailed'
  , stFacts :: h -> ProjectMeta -> IO ([Fact], [ExtractWarning])
    -- ^ 站 4 hie-facts:decl 層事實(警告已含 hie-index 的 @ihNotes@,本站不重複加)
  }

-- | 全有全無的管線。
--
-- 站 1 排在站 2 之前:'NoSources' 與 import-scan 的警告都不需要建置,先做能讓
-- 「零檔」這類情況在幾毫秒內結束,而不是先等 cabal。
--
-- @Left@ 不附帶已蒐集的警告:'ExtractFailure' 四個建構子都沒有警告欄,而 cabal
-- 的輸出已由 build-driver 即時轉發到 stderr(規則 5),使用者看得到失敗原因。
runPipeline :: Stages h -> ExtractOptions -> ProjectMeta -> IO (Either ExtractFailure ExtractResult)
runPipeline st opts pm
  | not (any sfIncluded (pmSources pm)) = pure (Left NoSources)   -- 0. 不叫任何一站,尤其不叫 cabal
  | otherwise = do
      (moduleFacts, scanWarns) <- stScan st opts pm                 -- 1.
      built <- stBuild st opts pm                                   -- 2.
      case built of
        Left f -> pure (Left f)
        Right layout -> do
          indexed <- stIndex st opts layout                         -- 3.
          case indexed of
            Left f -> pure (Left f)
            Right h -> do
              (declFacts, factWarns) <- stFacts st h pm             -- 4.
              pure $
                if any isDecl declFacts
                  then Right ExtractResult
                    { erFacts    = sort (moduleFacts <> declFacts)  -- 規則 10:全序,不受站序影響
                    , erWarnings = scanWarns <> factWarns           -- 站序固定:import-scan 在前
                    }
                  else Left (IndexFailed (noDeclDetail factWarns))  -- 規則 3 的 decl 層判準
 where
  isDecl FactDecl{} = True
  isDecl _          = False

-- | decl 層零事實的失敗說明:固定前綴 + 該站全部警告依序以 @\"; \"@ 串接。
-- 警告序由規則 10 保證,所以這段文字也決定性。
noDeclDetail :: [ExtractWarning] -> Text
noDeclDetail ws = T.intercalate (T.pack "; ") (noDeclPrefix : map render ws)
 where
  render w = ewSource w <> T.pack ": " <> ewMessage w

noDeclPrefix :: Text
noDeclPrefix = T.pack "the index yielded no top-level declarations"
