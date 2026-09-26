{-# LANGUAGE OverloadedStrings #-}

-- | 配置**记录**本身：字段、TOML 解码、渲染（含 'tomlStr' 字符串编码）与
-- 「路径须绝对」不变量（'checkAbsolute' \/ 'absolutizeConfig'）。2026-09-25 从
-- "Pm.Config" 拆出，搬移为字节级、零语义改动：该模块触及 750 行预算（DESIGN
-- §16），而全量 debug 审计 #4 \/ #5（配置路径与 root-id 落位的 canonical 化）
-- 要在那里加行。文件 I/O（'Pm.Config.configFilePath' \/ 'Pm.Config.loadConfig' \/
-- 'Pm.Config.writeConfig'）与 @.pm@ 受信取用口仍在 "Pm.Config"，并原样再导出
-- 这里的名字——调用方的 import 不变。
module Pm.ConfigTypes
  ( Config (..)
  , checkAbsolute
  , absolutizeConfig
  , renderConfig
  ) where

import Data.Char (isControl)
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (makeAbsolute)
import System.FilePath (isAbsolute)
import Text.Printf (printf)
import qualified TOML

data Config = Config
  { cfgMainPath :: FilePath
  , cfgVaultPath :: Maybe FilePath
  , cfgPhotosJson :: Maybe FilePath
  , cfgWorkers :: Maybe Int
  , cfgBackupId :: Maybe Text
    -- ^ 备份 root 的 UUID（`pm backup init` 登记；发现流程按 UUID 认盘，§9）
  , cfgBackupSubpath :: Maybe FilePath
    -- ^ 备份镜像相对盘根的位置（如 "Photography"）；盘符不入配置
  , cfgDriveWait :: Maybe Int
    -- ^ 备份盘掉线后最多等多少秒（1.1.2 瞬断保护，'Pm.Removable'）；缺省 1800，0 = 关闭
  , cfgPortfolioDir :: Maybe FilePath
    -- ^ portfolio 仓的本地路径（P7 上线命令生成用；photos-json 是只读引用
    -- 检查，这个是仓本身，两者独立可设）
  , cfgVaultPush :: Maybe String
    -- ^ 展示集仓 @git push@ 的目标（如 "origin main"）；不设 = 裸 @git push@。
    -- 字符闸在 'Pm.Publish.pushTargetOk'（设置入口统一过 checkPatch）。
  , cfgPortfolioPush :: Maybe String
    -- ^ portfolio 仓 push 目标；同上
  }
  deriving (Show, Eq)

instance TOML.DecodeTOML Config where
  tomlDecoder =
    Config
      <$> TOML.getFields ["main", "path"]
      <*> TOML.getFieldsOpt ["vault", "path"]
      <*> TOML.getFieldsOpt ["portfolio", "photos-json"]
      <*> TOML.getFieldsOpt ["main", "workers"]
      <*> TOML.getFieldsOpt ["backup", "id"]
      <*> TOML.getFieldsOpt ["backup", "subpath"]
      <*> TOML.getFieldsOpt ["backup", "drive-wait"]
      <*> TOML.getFieldsOpt ["portfolio", "dir"]
      <*> TOML.getFieldsOpt ["vault", "push"]
      <*> TOML.getFieldsOpt ["portfolio", "push"]

-- | 配置里的路径字段一律须为绝对路径（第一方自审 R4）：相对路径按进程 cwd
-- 解析，`pm ui` 拉起的 serve 与终端里的 pm 各有各的 cwd，同一份配置会指向
-- 两个地方，而 checkPatch 只查过「此刻从这个 cwd 看存在」。写侧 'writeConfig'
-- 先绝对化，这里挡的是手编。
checkAbsolute :: Config -> Either String Config
checkAbsolute c =
  case [k <> " = " <> v | (k, Just v) <- fields, not (isAbsolute v)] of
    [] -> Right c
    bad -> Left ("配置里的路径须为绝对路径（" <> intercalate "；" bad <> "）——改成完整盘符路径后重试")
 where
  fields =
    [ ("main.path", Just (cfgMainPath c))
    , ("vault.path", cfgVaultPath c)
    , ("portfolio.photos-json", cfgPhotosJson c)
    , ("portfolio.dir", cfgPortfolioDir c)
    ]

-- | 'writeConfig' 的入口归一：三条写入口（init / config set / 登记备份盘）都
-- 可能拿到用户键入的相对路径，统一在这一处绝对化，'checkAbsolute' 才不会把
-- pm 自己写出的配置拒掉。
absolutizeConfig :: Config -> IO Config
absolutizeConfig c = do
  m <- makeAbsolute (cfgMainPath c)
  v <- traverse makeAbsolute (cfgVaultPath c)
  j <- traverse makeAbsolute (cfgPhotosJson c)
  d <- traverse makeAbsolute (cfgPortfolioDir c)
  pure c {cfgMainPath = m, cfgVaultPath = v, cfgPhotosJson = j, cfgPortfolioDir = d}

-- | TOML 字符串值编码（39 轮 #3）。此前所有字符串值裸拼 literal 单引号：
-- 值本身含 @'@（如 @D:\\O'Brien@，能过 checkPatch 的合法目录名）就写出
-- **非法 TOML**——而 writeConfig 先落盘后重读，正式配置已被顶掉，每一条
-- pm 命令自此起不来。能用 literal（反斜杠原样，Windows 路径可读）就用；
-- 含单引号/控制符退到 basic string 并转义。**渲染器所有字符串值必须经它。**
tomlStr :: Text -> Text
tomlStr v
  | T.all litOk v = "'" <> v <> "'"
  | otherwise = "\"" <> T.concatMap esc v <> "\""
 where
  litOk ch = ch /= '\'' && not (isControl ch)
  esc ch = case ch of
    '"' -> "\\\""
    '\\' -> "\\\\"
    _
      | isControl ch -> T.pack (printf "\\u%04X" (fromEnum ch))
      | otherwise -> T.singleton ch

renderConfig :: Config -> Text
renderConfig c =
  T.unlines $
    [ "# pm 配置 —— 手动编辑后无需任何重载步骤"
    , "[main]"
    , "path = " <> tomlStr (T.pack (cfgMainPath c))
    ]
      <> maybe [] (\w -> ["workers = " <> T.pack (show w)]) (cfgWorkers c)
      -- 工作流 F011：与其它表同一 helper——此前唯独这张表全有才渲染，半对
      -- 登记被**静默归零**；「登记成对」的判定归 'Pm.ConfigEdit.checkConfig'
      -- （写入口当场拒），渲染器只忠实保全已设字段
      <> section "backup" [("id", T.unpack <$> cfgBackupId c), ("subpath", cfgBackupSubpath c)] [("drive-wait", T.pack . show <$> cfgDriveWait c)]
      -- 每张表渲染**所有**已设字段：渲染器漏一个字段，下一次任何写回就把
      -- 用户设过的那项静默抹掉（round-trip 由 configTxn 的写后重读顺带验证）。
      <> section "vault" [("path", cfgVaultPath c), ("push", cfgVaultPush c)] []
      <> section
        "portfolio"
        [ ("photos-json", cfgPhotosJson c)
        , ("dir", cfgPortfolioDir c)
        , ("push", cfgPortfolioPush c)
        ]
        []
 where
  section name kvs raws = case [k <> " = " <> tomlStr (T.pack v) | (k, Just v) <- kvs] <> [k <> " = " <> v | (k, Just v) <- raws] of -- raws = 裸值（整数），不加引号
    [] -> []
    ls -> ["", "[" <> name <> "]"] <> ls
