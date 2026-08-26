{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | User configuration (TOML, hand-editable) and per-root identity markers.
-- Config lives under the roaming profile (derived at runtime, never
-- hard-coded); root markers live in @\<root\>\/.pm\/root-id.json@ so roots are
-- recognized by UUID, not by drive letter (DESIGN.md §9).
--
-- 这里同时是 @.pm@ **状态文件的受信取用口**：读与追加走 'readPmState' \/
-- 'withPmStateAppend' \/ 'readSideCache'，成对写走 'writeSideCache'，而
-- 'Pm.Catalog.saveCatalog' 那类**自有多代轮转**在使用点用 'resolvePmPath'
-- 解析后只操作返回路径。见 'readPmState' 的注释：十一轮之前每个模块自己拼
-- @.pm@ 路径再按名字打开，那个模式在原理上补不完。
-- （P3b-15\/十二轮更正：十一轮这里写的"唯一取用口"不实——当时 'saveCatalog'
-- 的轮转与 'Pm.Lock' 的裸句柄都不经过本模块。）
module Pm.Config
  ( Config (..)
  , configFilePath
  , loadConfig
  , writeConfig
  , withConfigLock
  , renderConfig
  , RootIdState (..)
  , readRootState
  , readRootInfo
  , requireRole
  , requireMain
  , requireWritable
  , createRootInfo
  , writeRootInfo
  , freshRootId
  , pmDir
  , pmSubTrash
  , pmSubTmp
  , pmSubPlans
  , requirePmTrusted
  , pmSubBackupCache
  , pmSubVaultCache
  , untrustedMsg
  , readPmState
  , withPmStateAppend
  , resolvePmPath
  , readSideCache
  , SideCacheWrite (..)
  , writeSideCache
  , withRootLock
  , writePmState
  ) where

import Control.Exception (IOException, bracket, finally, throwIO, try)
import Control.Monad (when)
import Crypto.Random (getRandomBytes)
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory
  ( XdgDirectory (XdgConfig)
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getXdgDirectory
  , listDirectory
  , makeAbsolute
  )
import System.Environment (lookupEnv)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hTryLock)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (Handle, hClose)
import System.IO.Error (isAlreadyInUseError, isDoesNotExistError)
import Text.Printf (printf)
import qualified TOML

import Pm.GitGuard (pmIgnoreGuard)
import Pm.Types
import Pm.Win
  ( NameKind (..)
  , deleteBoundAt
  , flushHandleToDisk
  , moveBoundNoReplace
  , openFreshBinary
  , openStateAppend
  , openStateLock
  , openStateRead
  , probeName
  , resolveUnder
  )

data Config = Config
  { cfgMainPath :: FilePath
  , cfgVaultPath :: Maybe FilePath
  , cfgPhotosJson :: Maybe FilePath
  , cfgWorkers :: Maybe Int
  , cfgBackupId :: Maybe Text
    -- ^ 备份 root 的 UUID（`pm backup init` 登记；发现流程按 UUID 认盘，§9）
  , cfgBackupSubpath :: Maybe FilePath
    -- ^ 备份镜像相对盘根的位置（如 "Photography"）；盘符不入配置
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

-- | 配置文件位置。**`PM_CONFIG` 覆盖**优先于 XDG 目录，理由两条：
--
-- ① 测试必须能把配置写进临时目录。配置路径是**机器全局**的，写端点的用例
--    一旦真的写成功，覆盖的就是使用者本机那份 config.toml——P4-8 开发时实测
--    踩到：一次突变让 POST 通过，真实配置当场被 fixture 的临时路径覆盖。
--    整个测试进程在 `Spec.hs` 里把 `PM_CONFIG` 指到临时文件，这条路就断了。
-- ② 顺带支持一台机器上多个库：不同 `PM_CONFIG` 指不同配置。
--
-- 三十二轮 R3：环境变量的值必须过 'makeAbsolute' 归一（正斜杠 → 反斜杠、
-- 相对 → 绝对）。P6-C 起 'writeConfig' 的落位走 'Pm.Win.rawBoundTo' 的句柄
-- 后验，比较基准是 GetFinalPathNameByHandleW 的反斜杠规范形——`D:/…` 拼写或
-- 相对路径原样传下去会被当成「句柄绑定的不是这条路径」拒绝，且首次失败残留的
-- @.tmp@ 会卡死后续所有配置写。这里是全部提交路里唯一不经 canonicalize 的
-- 路径入口，归一在源头做一次，别处不再各自兜。
configFilePath :: IO FilePath
configFilePath = do
  mo <- lookupEnv "PM_CONFIG"
  case mo of
    Just p | not (null p) -> makeAbsolute p
    _ -> do
      dir <- getXdgDirectory XdgConfig "pm"
      pure (dir </> "config.toml")

loadConfig :: IO (Either String Config)
loadConfig = do
  fp <- configFilePath
  exists <- doesFileExist fp
  if not exists
    then do
      -- 二十四轮 minor：'writeConfig' 的「删旧 → 改名」之间崩掉，会只剩
      -- @<fp>.tmp@。那份内容是**完整且已 flush** 的新配置，把这种局面一律
      -- 解释成"配置不存在，去 pm init"会让人重建一份、把刚改的设置丢掉。
      -- 这里认出它并给出恢复动作；**不自动改名**——自动提升一个来历不明的
      -- .tmp 与 'Pm.VaultHold.readHolds' 的 fail-closed 原则相悖。
      orphan <- doesFileExist (fp <> ".tmp")
      pure . Left $
        if orphan
          then
            "配置缺失，但发现 " <> fp <> ".tmp —— 上次写入崩在删旧与改名之间。"
              <> "那份内容是完整的新配置：核对后改名成 "
              <> takeFileName fp
              <> " 即可恢复（或重跑 pm init --main <主库路径>）"
          else "配置不存在: " <> fp <> " —— 先运行 pm init --main <主库路径>"
    else do
      -- 三十五轮 F4：doesFileExist 与读取之间有窗口（编辑器/同步器短暂独占、
      -- 文件被挪走），裸 BS.readFile 抛出会让**每一条** pm 命令在入口崩掉。
      -- 读不出 = Left，withCfg 打印后 exit 2（fail-closed，不猜内容）。
      rawE <- try (BS.readFile fp) :: IO (Either IOException BS.ByteString)
      case rawE of
        Left e -> pure (Left ("配置读取失败（被占/被挪？）: " <> show e <> " —— 解除占用后重试"))
        Right raw -> case TE.decodeUtf8' raw of
          Left e -> pure (Left ("配置不是 UTF-8: " <> show e))
          Right txt -> case TOML.decode txt of
            Left e -> pure (Left (T.unpack (TOML.renderTOMLError e)))
            Right c -> pure (Right c)

-- | TOML literal strings (single quotes) keep Windows backslashes verbatim.
renderConfig :: Config -> Text
renderConfig c =
  T.unlines $
    [ "# pm 配置 —— 手动编辑后无需任何重载步骤"
    , "[main]"
    , "path = '" <> T.pack (cfgMainPath c) <> "'"
    ]
      <> maybe [] (\w -> ["workers = " <> T.pack (show w)]) (cfgWorkers c)
      <> ( case (cfgBackupId c, cfgBackupSubpath c) of
            (Just bid, Just sub) ->
              ["", "[backup]", "id = '" <> bid <> "'", "subpath = '" <> T.pack sub <> "'"]
            _ -> []
         )
      <> maybe [] (\p -> ["", "[vault]", "path = '" <> T.pack p <> "'"]) (cfgVaultPath c)
      <> maybe
        []
        (\p -> ["", "[portfolio]", "photos-json = '" <> T.pack p <> "'"])
        (cfgPhotosJson c)

-- | 写配置。P4-8 起 GUI 也能改配置，半写的 config.toml 会让**每一条** pm
-- 命令都起不来。
--
-- 二十四轮 minor：这里原本是裸 'BS.writeFile'——pm 里**唯一**一个不走
-- 「独占建 tmp → flush 到盘 → no-replace 改名」三件套的状态写入口。它之所以
-- 漏掉，只是因为配置在 XDG 目录、不在任何 root 的 @.pm@ 下，于是没继承那套
-- 纪律；现在与 'Pm.Catalog.saveCatalog'、'writeRootInfo' 用同一组原语。
-- （@.pm@ 的**限域**（'resolveUnder'）依然不适用：配置本来就不在 root 里。）
--
-- 删旧与改名之间仍有一个**窗口**——Windows 这边没有暴露"no-replace 语义的
-- 原子 replace"（见 'Pm.Win.moveBoundNoReplace'），而 pm 不要覆盖原语。崩在
-- 那里只会剩下内容完整的 @<fp>.tmp@，'loadConfig' 认得出并指明怎么恢复。
-- 并发那一侧由 'withConfigLock' 兜（同一个固定 tmp 名也只有一个写者）。
writeConfig :: Config -> IO FilePath
writeConfig c = do
  fp <- configFilePath
  -- 目录取自 fp 本身（PM_CONFIG 可以指到任意位置，不能再假定是 XDG 目录）
  createDirectoryIfMissing True (takeDirectory fp)
  let tmp = fp <> ".tmp"
  bracket (openFreshBinary tmp) hClose $ \h -> do
    BS.hPut h (TE.encodeUtf8 (renderConfig c))
    flushHandleToDisk h
  old <- doesFileExist fp
  when old (deleteBoundAt fp)
  moveBoundNoReplace tmp fp
  pure fp

-- | 配置的**读改写事务锁**（二十四轮 minor）。配置是全机器一份的，而编辑层有
-- 三条读改写路径（`pm config set`、@POST \/api\/config@、登记备份盘），彼此
-- 之间、以及与另一个 pm 进程之间原本没有互斥：两边各读一份旧配置、各写回
-- 自己那一项，后写的把先写的整条抹掉（还会撞同一个固定 tmp 名）。
--
-- 机制与 I10 的 @.pm\/lock@ 完全相同（'openStateLock' 在句柄上查 link count
-- 挡 hardlink DoS，同句柄 'hTryLock'），只是锁文件挂在配置**旁边**——配置不在
-- 任何 root 下，@.pm@ 那套限域不适用。
--
-- 'Nothing' = 另一个 pm 正在改配置。调用方必须当成**失败**报出去，不得当成
-- "改好了"——静默吞掉正是这条 minor 想堵的那种局面。
withConfigLock :: IO a -> IO (Maybe a)
withConfigLock act = do
  fp <- configFilePath
  createDirectoryIfMissing True (takeDirectory fp)
  r <- try (openStateLock (fp <> ".lock"))
  case r of
    Left (e :: IOException)
      | isAlreadyInUseError e -> pure Nothing
      | otherwise -> throwIO e
    Right h ->
      ( do
          ok <- hTryLock h ExclusiveLock
          if ok then Just <$> act else pure Nothing
      )
        `finally` hClose h

pmDir :: FilePath -> FilePath
pmDir root = root </> ".pm"

-- | @.pm@ 下的固定子目录名——单一真源：'Pm.Trash.trashDir'、
-- 'Pm.Exec.tmpDirFor'、'Pm.Plan.plansDir' 都引用这里，'requirePmTrusted'
-- 才能保证「校验过的那几条路径」与「实际写入的那几条路径」不会漂移。
pmSubTrash, pmSubTmp, pmSubPlans, pmSubBackupCache, pmSubVaultCache :: FilePath
pmSubTrash = "trash"
pmSubTmp = "tmp"
pmSubPlans = "plans"
pmSubBackupCache = "backup-cache"
pmSubVaultCache = "vault-cache"

-- | @.pm@ 家族的可信性闸（P3b-11，八轮复审 critical）：@.pm@ 及其内容都必须是
-- 盘上的**真名**，不得是 junction\/symlink。
--
-- 探针实证：把 @.pm\/trash@ 本身做成指向库外的 junction 后，落位\/删除侧的
-- canonical 限域两侧都解析到库外、判定通过，@removeFile@ 删掉了库外文件；
-- @.pm@ 自身被劫持时 journal\/plan\/manifest\/catalog\/root-id 会**整套**写到
-- 库外。
--
-- P3b-13（十轮复审 critical）：**不再维护白名单**。改为枚举 @.pm@ 下**实际
-- 存在**的每个条目——pm 现有的、我漏掉的、将来新增的、任何人放进去的，全部
-- 自动进入检查范围。
--
-- P3b-14（十一轮复审 minor，探针实证）：@.pm@ 是**普通文件**时旧实现放行——
-- @doesDirectoryExist@ 为 False 被直接读成"尚不存在（新库）"，于是无可枚举、
-- 一路 Right。四态分开判：缺失=新库放行，非目录与"查不出"一律拒绝。
--
-- 它的作用域是**深度 1**（@.pm@ 自身与它的直接子项）。更深的完整路径由
-- 'readPmState' \/ 'withPmStateAppend' \/ 'writeSideCache' 在每次取用时逐条
-- 验——见 'readPmState'。两者是分工，不是重复。
requirePmTrusted :: FilePath -> IO (Either String ())
requirePmTrusted root = do
  m <- resolveUnder root ".pm"
  case m of
    Nothing -> pure (Left (untrustedMsg (pmDir root)))
    Just pmAbs -> do
      k <- probeName pmAbs
      case k of
        -- .pm 尚不存在（新库）→ 无可枚举，通过；pm 自己会创建它。
        NameMissing -> pure (Right ())
        NameSurrogate -> pure (Left (untrustedMsg (pmDir root)))
        ProbeUnknown ->
          pure (Left (pmAbs <> " 存在但查不出是什么（ACL？），拒绝读写——人工核查"))
        NamePlain -> do
          isDir <- doesDirectoryExist pmAbs
          if not isDir
            then
              pure
                ( Left
                    ( pmAbs <> " 存在但不是目录——正常库里 .pm 必须是普通目录，"
                        <> "拒绝读写；人工核查（pm 不会替你删它）"
                    )
                )
            else do
              er <- try (listDirectory pmAbs) :: IO (Either IOException [FilePath])
              case er of
                Left e -> pure (Left (pmAbs <> " 无法枚举（" <> show e <> "），拒绝读写——人工核查"))
                Right names -> go names
 where
  go [] = pure (Right ())
  go (n : rest) = do
    m <- resolveUnder root (".pm" </> n)
    case m of
      Nothing -> pure (Left (untrustedMsg (pmDir root </> n)))
      Just _ -> go rest

untrustedMsg :: FilePath -> String
untrustedMsg p =
  p
    <> " 不是 root 下的真实目录项（junction/symlink/别名？）——pm 拒绝以它为基准读写。"
    <> "人工核查该路径；正常库里 .pm 及其内容必须是普通目录与普通文件"

rootInfoPath :: FilePath -> FilePath
rootInfoPath root = pmDir root </> "root-id.json"

-- | @.pm@ 下状态文件的**唯一**受信读取口。@rel@ 是相对 @.pm@ 的路径，可以是
-- 任意深度（@"catalog.json"@、@"trash\/manifest.ndjson"@、
-- @"plans\/\<id\>.json"@、@"vault-cache\/catalog.json"@）。
--
-- P3b-14（十一轮复审 critical + 两条 major，探针实证）：在这之前 pm 访问
-- @.pm@ 的模式一律是「拼路径字符串 → （也许）校验字符串 → 再**按名字**打开」。
-- 这个模式有三个各自独立的洞，十一轮把三个都实证了：
--
--  1. **深度**：可信闸只覆盖 @.pm@ 的直接子项，而 @trash\/manifest.ndjson@、
--     @plans\/\<id\>.json@ 是深度 2，直接 @readFile@\/@decodeFileStrict@。
--     实测把 @manifest.ndjson@ 做成指向库外的**文件 symlink** 后，正常的
--     @appendManifest@ 把记录**追加进了库外文件**（critical）。
--  2. **链接种类**：字符串校验只看得见 reparse point。hardlink 不改名字解析，
--     'resolveUnder' 在原理上看不见它，而读侧此前**完全没有** link count 判定。
--     实测 @catalog.json@ 与 @plans\/\<id\>.json@ 被 hardlink 占名后，
--     @loadCatalog@ 零警告载入库外快照、@loadPlan@ 载入库外计划（major×2）。
--  3. **重开**：即使两处都校验过，之后仍按名字重新打开一次——校验的对象与
--     使用的对象是两次独立解析。
--
-- 三者只有一个根因：**按名字访问**。所以修法不是再补一处校验，而是把取用
-- 收成一个口，一次做完三件事：完整相对路径的 'resolveUnder'（任意深度，
-- 治 1）→ 只打开一次 → 在**句柄**上查 link count（治 2）→ 从**同一句柄**
-- 读完（治 3）。此后任何模块都不得自己拼 @.pm@ 路径再打开。
--
-- 三态返回：@Left@=不可信（拒绝，绝不降级成"空"）、@Right Nothing@=文件不存在、
-- @Right (Just bytes)@=可信内容。
readPmState :: FilePath -> FilePath -> IO (Either String (Maybe BS.ByteString))
readPmState root rel = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> pure (Left (untrustedMsg (pmDir root </> rel)))
    Just fp -> do
      r <- try (bracket (openStateRead fp) hClose BS.hGetContents) :: IO (Either IOException BS.ByteString)
      pure $ case r of
        Right bytes -> Right (Just bytes)
        Left e
          | isDoesNotExistError e -> Right Nothing
          -- link count \> 1（hardlink）、ACL 拒绝、目录占名……一律拒绝，不当"缺席"
          | otherwise ->
              Left ((pmDir root </> rel) <> " 无法可信读取（" <> show e <> "）——人工核查")

-- | 'readPmState' 的追加写对偶：完整路径 'resolveUnder' → 'openStateAppend'
-- （打开后立刻查 link count）→ 在该句柄上执行 @act@。journal 与 manifest 是
-- pm 仅有的两个「必须复用既有名字」的追加目标，都走这里。
--
-- 两种拒绝都以 IOException 抛出（与 'openStateAppend' 的既有契约一致）：
-- 调用点在 Exec 的崩溃处理之内，写不成必须整项中止而不是继续。
withPmStateAppend :: FilePath -> FilePath -> (Handle -> IO a) -> IO a
withPmStateAppend root rel act = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> ioError (userError (untrustedMsg (pmDir root </> rel)))
    Just fp -> bracket (openStateAppend fp) hClose act

-- | 可重建侧缓存（备份盘缓存 \/ vault 缓存）的受信读取。三态：
-- @Left@=不可信（junction\/hardlink\/ACL）、@Right Nothing@=缺席或损坏 JSON
-- （可重建缓存按缺席重算即可）、@Right (Just a)@=可信内容。
--
-- P3b-15（十二轮 minor）：此前把 @Left@ 也压成 @Nothing@，并声称"配对的
-- 写侧会暴露失信"——不实：@pm status@ 只读不写，失信被显示成「未登记\/未
-- 比对过」且可能 exit 0。失信原因必须保留，由调用点决定呈现
-- （status 报 ⚠ 并计入退出码；vault\/backup 的重算路径可弃用内容但要报警）。
readSideCache :: Aeson.FromJSON a => FilePath -> FilePath -> FilePath -> IO (Either String (Maybe a))
readSideCache root sub name = do
  r <- readPmState root (sub </> name)
  pure $ case r of
    Left m -> Left m
    Right Nothing -> Right Nothing
    Right (Just bytes) ->
      Right (either (const Nothing) Just (Aeson.eitherDecodeStrict' bytes))

-- | @.pm@ 内 pm 自有文件的**使用点**路径解析：完整相对路径 'resolveUnder'，
-- 解析不出即抛（同 'withPmStateAppend' 口径）。P3b-15（十二轮 critical）：
-- 'Pm.Catalog.saveCatalog' 的轮转（tmp\/base\/.1\/.2 的创建、unlink、rename）
-- 此前全按名字操作、自身无任何解析——scan\/backup 在 loadCatalog 与保存之间隔
-- 一次长扫描，期间 @.pm@ 换成 junction，保存就会在**库外**建 tmp、删 @.2@、
-- 轮转 @.1@\/base。凡「解析后按返回路径操作」的写点都用这里。
resolvePmPath :: FilePath -> FilePath -> IO FilePath
resolvePmPath root rel = do
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> ioError (userError (untrustedMsg (pmDir root </> rel)))
    Just fp -> pure fp

-- | root 标识的三态（P3b-7 复审 major）：缺席与**损坏**必须区分——损坏（半写\/
-- 手编坏 JSON）若按缺席处理，init\/backup init\/vault push 会用新 UUID 与新
-- role 覆盖它，等于把一块备份盘的身份改写成主库。
-- P3b-12（九轮复审 major）：加第四态 'RootUntrusted'。`pm init` /
-- `pm backup init` / 首次 `pm vault push` 建立身份时**还没有身份**，因此天然
-- 走不了 'requireWritable' —— 九轮据此指出它们能在 `.pm` 是 junction 时到库外
-- 读写 root-id.json。身份读取的唯一入口是 'readRootState'，把可信闸放进它，
-- 这些 init 旁路一并覆盖。P3b-13（十轮更正）：status / versions 当时**并未**
-- 被它覆盖（那两条直接调 'Pm.Catalog.loadCatalog'），闸下沉到 loader 后才真正盖住。
-- P3b-14：标识本身也改走 'readPmState'（hardlink 占名的 root-id.json 此前会
-- 被当成本库身份读进来）。
data RootIdState = RootAbsent | RootCorrupt String | RootUntrusted String | RootPresent RootInfo
  deriving (Show, Eq)

readRootState :: FilePath -> IO RootIdState
readRootState root = do
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure (RootUntrusted m)
    Right () -> do
      r <- readPmState root "root-id.json"
      pure $ case r of
        Left m -> RootUntrusted m
        Right Nothing -> RootAbsent
        Right (Just bytes) -> either RootCorrupt RootPresent (Aeson.eitherDecodeStrict' bytes)

-- | 只读视图：Present → Just；缺席、损坏与**不可信**都是 Nothing（读者一律按
-- 「无身份」fail-closed；要改写标识的入口必须用 'readRootState' 分辨这几态）。
readRootInfo :: FilePath -> IO (Maybe RootInfo)
readRootInfo root = do
  st <- readRootState root
  pure $ case st of
    RootPresent i -> Just i
    _ -> Nothing

-- | 可写 root 的统一前提（P3b-7 复审新 major）：标识存在且可解析，**并且**
-- 按盘上 role 通过 I11 守卫。所有直接写 @.pm\/@ 的入口（计划保存、catalog\/
-- 侧缓存写入、doctor --repair、trash empty、undo\/resolve）在写之前都走这里；
-- Exec 在取锁前与锁内另有同规则复检。
-- P3b-12：可信闸已下沉到 'readRootState'（它是身份读取的唯一入口，init 旁路
-- 也走它），这里只需分派它的四态。
requireWritable :: FilePath -> IO (Either String RootInfo)
requireWritable root = do
  st <- readRootState root
  case st of
    RootUntrusted m -> pure (Left m)
    RootAbsent ->
      pure (Left (root <> " 缺 .pm/root-id.json → 先 pm init --main <主库>（备份盘用 pm backup init）"))
    RootCorrupt e ->
      pure
        ( Left
            ( root <> " 的 .pm/root-id.json 存在但无法解析（" <> e
                <> "），拒绝以任何身份读写——人工核查修复；pm 不改写它"
            )
        )
    RootPresent info -> do
      g <- pmIgnoreGuard (riRole info) root
      pure (either Left (const (Right info)) g)

-- | 'requireWritable' + role 校验（P3b-5 复审 B1）：配置里的主库路径若指向
-- 备份\/vault root，任何以「主库」身份生成的计划（import\/clean\/names\/scan）
-- 都会改错库。缺身份、损坏、role 不符、I11 不过都是 Left，调用点一律
-- fail-closed。
requireRole :: RootRole -> FilePath -> IO (Either String RootInfo)
requireRole role root = do
  r <- requireWritable root
  pure $ case r of
    Right info
      | riRole info /= role ->
          Left (root <> " 是 " <> show (riRole info) <> " root，不是 " <> show role <> "，拒绝以该身份操作（检查配置路径）")
    other -> other

-- | 配置的主库路径必须是 RoleMain root（P3b-5 复审 B1；P3b-7 扩到 clean 见证\/
-- 备份缓存刷新\/init）。
requireMain :: Config -> IO (Either String RootInfo)
requireMain = requireRole RoleMain . cfgMainPath

-- | 首次建立 root 标识：**原子 no-replace**（写 tmp → 'moveBoundNoReplace'；
-- 目标已存在——并发创建、或 'readRootState' 之后有人放了文件——即拒绝，
-- 绝不覆盖）。P3b-7 复审 major：此前覆盖写让损坏\/竞态 marker 可被改写身份。
createRootInfo :: FilePath -> RootInfo -> IO (Either String ())
createRootInfo root info = do
  -- P3b-12（九轮复审 major）：纵深防御。三条建身份旁路已在 'readRootState'
  -- 处被 'RootUntrusted' 拦下，但这个函数是公开 API，自身也必须问一次——
  -- 否则 .pm 是 junction 时它会把标识原子地建到**库外**（测试实测过）。
  tr <- requirePmTrusted root
  case tr of
    Left m -> pure (Left m)
    Right () -> createRootInfo' root info

createRootInfo' :: FilePath -> RootInfo -> IO (Either String ())
createRootInfo' root info = do
  createDirectoryIfMissing True (pmDir root)
  bytes <- getRandomBytes 4
  let final = rootInfoPath root
      tmp = final <> "." <> concatMap (printf "%02x") (BS.unpack bytes) <> ".tmp"
  -- 独占创建（P3b-11，八轮复审 major）：pm 自建 tmp 一律不覆盖既有名字，
  -- 预置的 hardlink 会被 CREATE_NEW 拒绝而不是被写穿到库外。
  bracket (openFreshBinary tmp) hClose $ \h -> do
    BSL.hPut h (Aeson.encode info)
    flushHandleToDisk h
  r <- try (moveBoundNoReplace tmp final) :: IO (Either IOException ())
  case r of
    Right () -> pure (Right ())
    Left e -> do
      -- §6.1 脚注：pm 自建、从未落位的 tmp 是唯一允许 unlink 的东西
      deleteBoundAt tmp
      pure (Left (final <> " 已存在或不可创建（不覆盖既有身份）: " <> show e))

-- | 覆盖写标识——仅供测试 fixture 与显式重写场景；生产建 root 一律走
-- 'createRootInfo'。
writeRootInfo :: FilePath -> RootInfo -> IO ()
writeRootInfo root info = do
  createDirectoryIfMissing True (pmDir root)
  BSL.writeFile (rootInfoPath root) (Aeson.encode info)

-- | 侧缓存目录的成对写入（catalog.json + meta.json），备份盘缓存与 vault 缓存
-- 共用：都是可重建的展示\/加速缓存，耐久层在别处（备份盘自己的 @.pm@、照片
-- 文件本身）。
--
-- P3b-12（九轮）：覆盖写能被 hardlink 引到库外 → 改「独占创建 tmp → 删旧 →
-- no-replace 落位」。
-- P3b-13（十轮复审 critical，探针实证）：接口从「给我一个目录」改成
-- 「给我 root + @.pm@ 下的子目录名」——旧签名让调用方自由拼路径
-- （'Pm.Backup.cacheDir'、'Pm.Vault.vaultCacheDir'），于是把
-- @.pm\/vault-cache@ 做成 junction 后，正常的 @pm vault status@ 会删掉并替换
-- **库外**的 catalog.json\/meta.json（实测库外文件变成了 pm 写的内容）。
-- 现在每个文件的完整路径在建目录前后各过一次 'resolveUnder'，与 Exec 的
-- tmp 落位同款。
-- | Run the action holding the root's exclusive mutation lock; Nothing if
-- another pm instance holds it. （原 Pm.Lock，三十一轮下沉至此——见该模块头。）
--
-- 两层内核级互斥，都随进程死亡自动释放：GHC 运行时对可写打开的跨进程文件锁
-- （Windows LockFileEx；第二个可写打开直接 resource busy），以及显式
-- 'hTryLock'。P3b-14：锁文件先过完整路径 'resolveUnder'；P3b-15：改用
-- 'openStateLock' 在句柄上查 link count（.pm/lock 被 hardlink 到库外文件时
-- 会锁住共享对象，跨库互斥/对外部程序 DoS）。
withRootLock :: FilePath -> IO a -> IO (Maybe a)
withRootLock root act = do
  createDirectoryIfMissing True (pmDir root)
  ml <- resolveUnder root (".pm" </> "lock")
  lockFp <- case ml of
    Nothing -> ioError (userError (untrustedMsg (pmDir root </> "lock")))
    Just fp -> pure fp
  -- ReadWriteMode inside: creates the file if missing, never truncates.
  r <- try (openStateLock lockFp)
  case r of
    Left (e :: IOException)
      | isAlreadyInUseError e -> pure Nothing
      | otherwise -> throwIO e
    Right h ->
      ( do
          ok <- hTryLock h ExclusiveLock
          if ok then Just <$> act else pure Nothing
      )
        `finally` hClose h

-- | 侧缓存成对写的三种结局。锁被占与不可信**必须**是不同构造子：前者是
-- 良性并发（含 vault-holds 事务在锁内经 computeVault 走到这里的自持情形），
-- 降级为"本轮不刷新"即可——缓存可由下一次命令重建；后者是 junction 劫持，
-- 继续写等于把 pm 的写交给库外（P3b-13），必须硬停。压成一个 Left 会让调用
-- 方要么把劫持当并发放过、要么把并发当劫持硬停（三十一轮实测：后者让全部
-- hold 用例 exit 2）。
data SideCacheWrite
  = CacheWritten
  | CacheLockBusy
  | CacheRefused String
  deriving (Show, Eq)

writeSideCache :: Aeson.ToJSON meta => FilePath -> FilePath -> Catalog -> meta -> IO SideCacheWrite
writeSideCache root sub cat meta = do
  -- 三十一轮 F1：catalog.json + meta.json 是**成对**状态，两文件之间没有锁时
  -- 两个 pm（两次 pm backup、或 backup 与 afterApply）交错写会得到 catalog 与
  -- meta 不配对的缓存。成对写整段进 I10 锁；拿不到锁 = 有人（可能是本进程的
  -- 外层事务）正持有该 root，本轮放弃。统一修复：backup-cache 与 vault-cache
  -- 共用本函数，十九轮登记的 vault-cache 跨进程争用残余随本条一并关闭
  -- （三十二轮更正：此前误记为二十轮；登记原文在 REVIEW-LOG 十九轮 bullet）。
  m <- withRootLock root $ do
    let dir = pmDir root </> sub
    pre <- resolveUnder root (".pm" </> sub)
    case pre of
      Nothing -> pure (Left (untrustedMsg dir))
      Just _ -> do
        createDirectoryIfMissing True dir
        r1 <- writeCacheFile root sub "catalog.json" (Aeson.encode cat)
        case r1 of
          Left e -> pure (Left e)
          Right () -> writeCacheFile root sub "meta.json" (Aeson.encode meta)
  pure (case m of
    Nothing -> CacheLockBusy
    Just (Left e) -> CacheRefused e
    Just (Right ()) -> CacheWritten)

writeCacheFile :: FilePath -> FilePath -> FilePath -> BSL.ByteString -> IO (Either String ())
writeCacheFile root sub name bytes = do
  -- 建目录之后再验一次完整路径：把 createDirectoryIfMissing 与写入之间的
  -- TOCTOU 窗口收窄到"创建后立刻"（同 'Pm.Exec' 的动态 tmp 处理）。
  -- 这一次是**文件级**的：目录级 pre-check 看不见 vault-cache/catalog.json
  -- 自身被做成 symlink 的形态（P3b-14 十一轮：旧用例只放目录 junction，
  -- 删掉这一行也照样绿，新用例 caseSideCacheFileLink 钉的就是这里）。
  m <- resolveUnder root (".pm" </> sub </> name)
  case m of
    Nothing -> pure (Left (untrustedMsg (pmDir root </> sub </> name)))
    Just fp -> Right <$> writeJsonReplacing fp bytes

-- | @.pm@ 下**单个** pm 自有状态文件的可信覆盖写，'readPmState' 的对偶。
-- 侧缓存是成对的（catalog+meta，走 'writeSideCache'）；用户**决定**类的单文件
-- （vault 的「暂不同步」名单）走这里：完整路径 'resolveUnder' → 独占创建 tmp
-- → flush → no-replace rename，与 'writeCacheFile' 同款。调用方须先过
-- 'requireWritable'（I11 + 身份）。
writePmState :: FilePath -> FilePath -> BSL.ByteString -> IO (Either String ())
writePmState root rel bytes = do
  createDirectoryIfMissing True (pmDir root)
  m <- resolveUnder root (".pm" </> rel)
  case m of
    Nothing -> pure (Left (untrustedMsg (pmDir root </> rel)))
    Just fp -> Right <$> writeJsonReplacing fp bytes

writeJsonReplacing :: FilePath -> BSL.ByteString -> IO ()
writeJsonReplacing fp bytes = do
  let tmp = fp <> ".tmp"
  bracket (openFreshBinary tmp) hClose $ \h -> do
    BSL.hPut h bytes
    flushHandleToDisk h
  old <- doesFileExist fp
  when old (deleteBoundAt fp)
  moveBoundNoReplace tmp fp

freshRootId :: IO Text
freshRootId = do
  bytes <- getRandomBytes 16
  pure (T.pack (concatMap (printf "%02x") (BS.unpack bytes)))
