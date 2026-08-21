-- | export-query 子系統查詢面的唯一對外進入點。
--
-- Level 2 契約:@.design/subsystems/export-query/design.md@「對外契約 › 查詢面」。
-- 'F002' graph-load 落地 'loadQueryGraph' 與 'queryGraphNotes';
-- @F003@ query-commands 再把 'runQuery' \/ 'renderResult' 與三個查詢 DTO 加進
-- 同一份匯出清單,@F004@ 因此只需 import 這一個模組即可完成整條查詢管線。
--
-- 之於查詢面 = 'Knot.Export' 之於匯出面:唯一的 IO 是__讀檔__,
-- 不建圖、不改圖、不寫任何檔案、全程不印任何輸出(委派決策 D8)
-- ——'renderResult' 回傳 'Data.Text.Text',列印由 CLI 層負責。
module Knot.Query
  ( -- * 進入點
    loadQueryGraph
  , queryGraphNotes
  , queryGraphHasNode
  , runQuery
  , renderResult
    -- * DTO
  , LoadError (..)
  , QueryGraph
  , NodeId (..)
  , QueryCommand (..)
  , Direction (..)
  , QueryResult (..)
  ) where

import Control.Exception (try)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import System.IO.Error (isDoesNotExistError)

import Knot.Query.Engine (runQuery)
import Knot.Query.Load (parseQueryGraph, queryGraphHasNode, queryGraphNotes)
import Knot.Query.Render (renderResult)
import Knot.Query.Types
  ( Direction (..)
  , LoadError (..)
  , NodeId (..)
  , QueryCommand (..)
  , QueryGraph
  , QueryResult (..)
  )

-- | 讀 @codegraph.json@ 並組成查詢用圖(Level 2 契約原文簽名)。
--
-- 讀不到 \/ 壞 JSON \/ 結構不合一律回 'LoadError',__不修不猜__、不印任何訊息,
-- 也不產出部分圖。
--
-- 讀檔走 'try' 而非「先 @doesFileExist@ 再讀」:免掉 TOCTOU,並一併涵蓋
-- 「路徑是目錄」「權限不足」——契約對 'LoadFileMissing' 的註解本來就是
-- 「檔案不存在 \/ 讀不到」。'BS.readFile' 是 binary 讀取,不做平台換行或編碼
-- 轉換(與 'Knot.Export' 的 binary 寫檔對稱,round-trip 才成立)。
loadQueryGraph :: FilePath -> IO (Either LoadError QueryGraph)
loadQueryGraph path = do
  r <- try (BS.readFile path)
  pure $ case r of
    Right bs -> parseQueryGraph path bs
    Left e
      | isDoesNotExistError e -> Left (missing "file not found")
      | otherwise             -> Left (missing ("cannot read file: " <> show e))
 where
  missing detail = LoadFileMissing (T.pack (path <> ": " <> detail))
