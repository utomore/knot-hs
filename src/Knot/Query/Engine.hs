-- | export-query 查詢面的四種演算法(內部模組 query-engine)。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 查詢面」
-- 的 'runQuery',以及查詢規則 3('FindNodes' 掃全部節點)、4(決定性排序)、
-- 5('Reachable' 不含起點但環上以真實距離出現)、6('ShortestPath' 取字典序最小)。
--
-- __全程無 IO、不印任何輸出__(委派決策 D8),也__不看 relation__——依賴類 \/
-- 結構類 \/ 未知類的分流在 'Knot.Query.Load' 就做完了,本模組只消費
-- 'qgForward' \/ 'qgReverse' \/ 'qgOutDeg' \/ 'qgInDeg' 四張已分流的表。
--
-- 決定性的三個破口與對策:走訪容器只用 @containers@ 的 'Map' \/ 'Set'
-- (依 'Ord' 走訪,不引入任何 hash 容器);BFS 的展開序寫死為 FIFO 發現序 +
-- 鄰居依 id 升序(升序由 'Knot.Query.Load' 在載入時備好);四個查詢的輸出
-- 排序鍵全部明列於各自的 haddock。
--
-- __零 knot-hs 相依__:只 import @containers@ \/ @text@ \/ @base@ 與同子系統的
-- 'Knot.Query.Types'(ADR-003:匯出格式不是內部模型)。
module Knot.Query.Engine
  ( -- * 對外契約
    runQuery
  ) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import Knot.Query.Types
  ( Direction (..)
  , NodeId (..)
  , QueryCommand (..)
  , QueryGraph (..)
  , QueryNode (..)
  , QueryResult (..)
  )

--------------------------------------------------------------------------------
-- 分派
--------------------------------------------------------------------------------

-- | export-query 查詢面的演算法本體(Level 2 契約原文簽名)。
--
-- 純函數:同一 'QueryGraph' 配同一 'QueryCommand' 必得同一結果(查詢規則 4)。
-- 任何輸入都回得出一個 'QueryResult'——起點 \/ 終點不存在、查無命中、不連通
-- 全部是正常結果(空集合 \/ 'Nothing'),__沒有失敗路徑__。
runQuery :: QueryGraph -> QueryCommand -> QueryResult
runQuery g cmd = case cmd of
  FindNodes kw          -> FoundNodes   (findNodes g kw)
  Reachable start dir limit -> ReachableSet (reachableFrom g start dir limit)
  ShortestPath from to  -> PathResult   (shortestPath g from to)
  RankConnectivity n    -> Ranking      (rankConnectivity g n)

-- | 'NodeId' 的內容;'Knot.Query.Types' 只匯出建構子,沒有具名選擇器。
unNodeId :: NodeId -> Text
unNodeId (NodeId t) = t

--------------------------------------------------------------------------------
-- FindNodes(查詢規則 3、4)
--------------------------------------------------------------------------------

-- | 關鍵字比對 __全部__ 節點的 id 與 label(規則 3:含只被結構類邊連到、
-- 甚至完全孤立的節點),兩邊都 'T.toLower' 後做子字串比對(不分大小寫)。
--
-- 輸出沿 'qgNodes' 的原序,即 id 升序(規則 4);沒有分數欄位,命中即收錄。
-- 空關鍵字恆命中('T.isInfixOf' 對空字串恆真)→ 回全部節點(假設 A6)。
findNodes :: QueryGraph -> Text -> [(NodeId, Text, FilePath)]
findNodes g kw =
  [ (qnId n, qnLabel n, qnFile n) | n <- qgNodes g, hit n ]
 where
  needle = T.toLower kw
  hit n =
    needle `T.isInfixOf` T.toLower (unNodeId (qnId n))
      || needle `T.isInfixOf` T.toLower (qnLabel n)

--------------------------------------------------------------------------------
-- Reachable(查詢規則 2、4、5)
--------------------------------------------------------------------------------

-- | 自 @start@ 沿指定方向逐層 BFS,回 (節點, hop 距離)。
--
-- * 起點不存在於 'qgIndex' → 空集合,不拋例外(假設 A1)
-- * 起點__不入結果__:第 0 層的 @start@ 只被展開一次、從不寫進距離表(規則 5 前半)
-- * 起點在環上時__以真實距離出現__:@start@ 沒有被預先標記,某層的鄰居含它就
--   以該層距離入表——自環給 1、二元環給 2(規則 5 後半)
-- * 輸出依 (距離升序, id 升序)(規則 4);__不能__只 'Map.toAscList'(那是純 id 序)
reachableFrom :: QueryGraph -> NodeId -> Direction -> Maybe Int -> [(NodeId, Int)]
reachableFrom g start dir limit
  | not (start `Map.member` qgIndex g) = []
  | otherwise = sortOn (\(i, d) -> (d, i)) (Map.toAscList dist)
 where
  adj = case dir of
    Forward -> qgForward g
    Reverse -> qgReverse g
  -- 'Knot.Query.Load' 只收錄「實際有依賴邊」的節點,無邊者是缺鍵而非空清單。
  neighbours v = Map.findWithDefault [] v adj
  dist = go Map.empty 1 (neighbours start)
  -- frontier 是本層的發現序;每個節點最多寫入一次,故層數上限為節點數。
  -- 深度上限(查詢規則 8,E001):超過 limit 的層不展開——只是截斷,規則 5 不變。
  go acc _ [] = acc
  go acc d _ | maybe False (d >) limit = acc
  go acc d frontier =
    let fresh = freshInOrder (`Map.member` acc) frontier
        acc'  = foldl' (\m v -> Map.insert v d m) acc fresh
    in  go acc' (d + 1) (concatMap neighbours fresh)

--------------------------------------------------------------------------------
-- ShortestPath(查詢規則 6)
--------------------------------------------------------------------------------

-- | 沿 'qgForward' 找 @from@ 到 @to@ 的最短路徑,多解取__字典序最小__
-- (路徑視為節點 id 序列比大小)。
--
-- 決定性的三條展開紀律:
--
-- 1. __鄰居依 id 升序展開__——'qgForward' 的鄰接清單在載入時就排好,直接取用,
--    不再排序也不打亂
-- 2. __層內依 FIFO 發現序展開__——下一層的順序 = 被發現的先後,__不得__按節點 id
--    重排;重排會退化成「反向貪心」(只保證前驅 id 最小),在
--    @S→Alpha→Xray→T@ 與 @S→Beta→Whisky→T@ 這種案例上選到錯的路徑
-- 3. __首次發現寫入前驅,之後不覆蓋__(「前驅取最早抵達者」)
--
-- 正確性(歸納):字典序最小最短路徑的前綴必然也是其終點的字典序最小最短路徑,
-- 否則換掉前綴會得到更小且等長的路徑。故若第 d 層節點依其路徑的字典序排列,
-- 第 d+1 層以「層內順序 × 鄰居 id 升序」展開時恰好是依字典序枚舉所有長度 d+1
-- 的候選,首次發現者即為最小者,且新層仍依字典序排列;第 0 層只有 @from@,平凡成立。
--
-- 端點不存在 → 'Nothing'(假設 A1);@from == to@ → @Just [from]@(0 hop,假設 A2,
-- __不__去找經過環回到自己的路徑);不連通 → 'Nothing'。
shortestPath :: QueryGraph -> NodeId -> NodeId -> Maybe [NodeId]
shortestPath g from to
  | not (from `Map.member` qgIndex g) = Nothing
  | not (to   `Map.member` qgIndex g) = Nothing
  | from == to                        = Just [from]
  | otherwise                         = rebuild <$> bfs seed [from]
 where
  neighbours v = Map.findWithDefault [] v (qgForward g)
  -- 前驅表兼 visited 集合;@from@ 以自我前驅當哨兵(此分支保證 from /= to)。
  seed = Map.singleton from from
  bfs prev frontier
    -- 提早結束:發現 @to@ 即停,同層其餘節點的前驅已寫完,不影響結果。
    | to `Map.member` prev = Just prev
    | null frontier        = Nothing
    | otherwise =
        let expanded = [(v, u) | u <- frontier, v <- neighbours u]
            fresh    = freshPairs (`Map.member` prev) expanded
            prev'    = foldl' (\m (v, u) -> Map.insert v u m) prev fresh
        in  bfs prev' (map fst fresh)
  rebuild prev = reverse (walk to)
   where
    walk v
      | v == from = [from]
      | otherwise = case Map.lookup v prev of
          Just u  -> v : walk u
          Nothing -> [v]   -- 不可達分支:@to@ 在表內時鏈必回到 @from@

--------------------------------------------------------------------------------
-- RankConnectivity(查詢規則 4、驗收標準 5)
--------------------------------------------------------------------------------

-- | 依 (入度 + 出度) 降序、同分按 id 升序排名,取前 @n@ 名。
--
-- 度數__直接取 'qgInDeg' \/ 'qgOutDeg'__,不從鄰接表重算:那兩張表算的是
-- __邊數__(重複邊計 2、自環兩端各 +1),與下游 @scan-graph.mjs@ 的 hub 計算同語意;
-- 用鄰接表長度會得到「相異鄰居數」,語意不同。
--
-- 總度數為 0 的節點(只被結構類邊連到、或完全孤立)__不進榜__(假設 A3),
-- 與 @scan-graph.mjs@ 的 @degree@ map 只收非結構邊端點一致。
-- @n <= 0@ 時 'take' 的自然語意即空清單(假設 A4);@n@ 過大則輸出全部。
rankConnectivity :: QueryGraph -> Int -> [(NodeId, Int, Int)]
rankConnectivity g n =
  take n (sortOn rankKey ranked)
 where
  rankKey (i, inD, outD) = (Down (inD + outD), i)
  ranked =
    [ (i, inD, outD)
    | node <- qgNodes g
    , let i    = qnId node
          inD  = Map.findWithDefault 0 i (qgInDeg g)
          outD = Map.findWithDefault 0 i (qgOutDeg g)
    , inD + outD > 0
    ]

--------------------------------------------------------------------------------
-- 保序去重(兩個 BFS 共用)
--------------------------------------------------------------------------------

-- | 濾掉「已走訪」與「本層前面已出現過」的重複,__保留首次出現的位置__。
-- 只影響效率與展開序,不影響距離值。
freshInOrder :: (NodeId -> Bool) -> [NodeId] -> [NodeId]
freshInOrder visited = go Set.empty
 where
  go :: Set NodeId -> [NodeId] -> [NodeId]
  go _ [] = []
  go seen (v : vs)
    | visited v || v `Set.member` seen = go seen vs
    | otherwise                        = v : go (Set.insert v seen) vs

-- | 'freshInOrder' 的 (節點, 前驅) 版本:以節點判重,保留最早抵達的那個前驅。
freshPairs :: (NodeId -> Bool) -> [(NodeId, NodeId)] -> [(NodeId, NodeId)]
freshPairs visited = go Set.empty
 where
  go :: Set NodeId -> [(NodeId, NodeId)] -> [(NodeId, NodeId)]
  go _ [] = []
  go seen (p@(v, _) : ps)
    | visited v || v `Set.member` seen = go seen ps
    | otherwise                        = p : go (Set.insert v seen) ps
