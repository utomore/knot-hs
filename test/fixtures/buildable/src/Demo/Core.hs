module Demo.Core
  ( Color (..)
  , Config (..)
  , greet
  ) where

-- deriving 是 refs.is_generated = 1 的樣本來源(extraction/F004 驗收標準 3);
-- 拿掉它會讓 test_hiedb_facts_acceptance 的產生碼樣本歸零。
data Color = Red | Green | Blue
  deriving (Eq, Show)

-- 記錄欄位是 f<父型別>: namespace 的唯一樣本來源(驗收標準 2 的第四種);
-- 拿掉 cfgName 會讓 FieldNs 在 fixture 上再也測不到。
data Config = Config
  { cfgName :: String
  }

greet :: Color -> String
greet Red   = "red"
greet Green = "green"
greet Blue  = "blue"
