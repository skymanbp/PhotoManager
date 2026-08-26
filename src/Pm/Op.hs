{-# LANGUAGE OverloadedStrings #-}

-- | The operation algebra (DESIGN.md §3). Deliberately closed: there is no
-- delete constructor and no overwrite constructor — every landing goes
-- through a fail-if-exists rename, and the only way bytes leave a library is
-- 'OpQuarantine' into the manifest-tracked trash (invariant I2).
module Pm.Op
  ( Op (..)
  , Fingerprint (..)
  , opId
  , isValidPlanId
  , OpIdSuffix (..)
  , opIdParts
  , restoreOpId
  , displacedOpId
  , relPathOk
  , winNameOk
  , userRelOk
  , isTrashSrcRel
  , opRelPaths
  , opPathsOk
  , describeOp
  ) where

import Control.Monad (guard)
import Data.Aeson
import Data.Char (isControl, isDigit, toLower)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath (isAbsolute, isPathSeparator, splitDirectories)

data Fingerprint
  = FpFileSha Text
  | -- | sha256 over the sorted @name\\tsize@ lines of the direct children —
    -- filesystem-agnostic (backup drive may be exFAT, no FILE_ID_128).
    FpDir Text
  deriving (Show, Eq)

instance ToJSON Fingerprint where
  toJSON (FpFileSha s) = object ["file" .= s]
  toJSON (FpDir s) = object ["dir" .= s]

instance FromJSON Fingerprint where
  parseJSON = withObject "Fingerprint" $ \o -> do
    mf <- o .:? "file"
    md <- o .:? "dir"
    case (mf, md) of
      (Just s, _) -> pure (FpFileSha s)
      (_, Just s) -> pure (FpDir s)
      _ -> fail "fingerprint needs 'file' or 'dir'"

data Op
  = -- | Copy one file into the mutated root. @src@ is absolute (it may live
    -- in another root); @dst@ is relative to the mutated root. size/mtime
    -- are the plan-time precondition on the source (§6.7 并发防护).
    OpCopy
      { opSrcAbs :: FilePath
      , opDstRel :: FilePath
      , opSha :: Text
      , opSrcSize :: Integer
      , opSrcMtimeNs :: Integer
      }
  | OpRename
      { opOldRel :: FilePath
      , opNewRel :: FilePath
      , opFp :: Fingerprint
      }
  | OpQuarantine
      { opVictimRel :: FilePath
      , opVictimSha :: Text
      , opReason :: Text
      }
  deriving (Show, Eq)

instance ToJSON Op where
  toJSON op = case op of
    OpCopy s d h sz mt ->
      object ["t" .= ("copy" :: Text), "src" .= s, "dst" .= d, "sha256" .= h, "size" .= sz, "mtimeNs" .= mt]
    OpRename o n fp ->
      object ["t" .= ("rename" :: Text), "old" .= o, "new" .= n, "fp" .= fp]
    OpQuarantine v h r ->
      object ["t" .= ("quarantine" :: Text), "victim" .= v, "sha256" .= h, "reason" .= r]

instance FromJSON Op where
  parseJSON = withObject "Op" $ \o -> do
    t <- o .: "t"
    case (t :: Text) of
      "copy" ->
        OpCopy <$> o .: "src" <*> o .: "dst" <*> o .: "sha256" <*> o .: "size" <*> o .: "mtimeNs"
      "rename" -> OpRename <$> o .: "old" <*> o .: "new" <*> o .: "fp"
      "quarantine" -> OpQuarantine <$> o .: "victim" <*> o .: "sha256" <*> o .: "reason"
      _ -> fail ("unknown op type: " <> show t)

-- | Stable id of item @ix@ inside plan @pid@.
opId :: Text -> Int -> Text
opId pid ix = pid <> "#" <> T.pack (show ix)

-- | 'Pm.Plan.newPlanId' 的生成格式 @YYYYMMDD-HHMMSS-hex6@（hex 小写）。计划文件
-- 是可手编的外部输入，而 id 参与 opId\/tmp\/trash 路径推导：不合格式的 id（如
-- 含 @~d@、@#@、路径分隔符、@..@）在装载（'Pm.Plan.loadPlan'）、执行
-- （'Pm.Exec.execPlan'）与 oid 解析（'opIdParts'）三处都拒绝。定义在本模块
-- 而非 Plan，是因为 opId 解析也要它（Plan 再导出）。
isValidPlanId :: Text -> Bool
isValidPlanId t = case T.splitOn "-" t of
  [d, hms, hex] ->
    T.length d == 8
      && T.all isDigit d
      && T.length hms == 6
      && T.all isDigit hms
      && T.length hex == 6
      && T.all isHexLower hex
  _ -> False
 where
  isHexLower c = isDigit c || (c >= 'a' && c <= 'f')

-- | opId 后缀 = 内核内部事务约定（P3b-6 复审 A1 统一解析）：无后缀是用户可见
-- 操作；@~r@ 是 §6.5 组回滚的自动复位 rename；@~d\<N\>@ 是组回滚时占位者的
-- 第 N 次位移隔离（落 @\<pid\>~displaced-\<N\>\/@）。其它形态都不是 pm 生成的。
data OpIdSuffix = SfxPlain | SfxRestore | SfxDisplaced Int
  deriving (Show, Eq)

-- | 严格解析 @\<planId\>#\<ix\>[~r|~d\<N\>]@ → (planId, ix, 后缀)。planId 部分
-- 必须是生成格式（'isValidPlanId'）——P3b-8 复审 A1：此前只排除 @#@\/@~@，
-- 手编 journal 的 @..\/..\/outside#0@ 能通过解析，doctor 随即把 trash\/tmp
-- 路径推到 root 之外（内容相符即 Q-DONE-LOST，--repair 补 Done）。ix 与 N 为
-- 规范十进制，N ≥ 1。此前 Trash 用 @splitOn "~d"@、Undo 用 @isInfixOf "~d"@
-- 各自弱解析：planId 含 @~d@ 时前者把普通隔离推到位移目录、后者把正常操作当
-- 内部事务剔出 undo。
opIdParts :: Text -> Maybe (Text, Int, OpIdSuffix)
opIdParts oid = do
  let (pid, rest) = T.breakOn "#" oid
  guard (isValidPlanId pid)
  rest' <- T.stripPrefix "#" rest
  let (ixT, sfx) = T.span isDigit rest'
  ix <- readDigits ixT
  s <- case sfx of
    "" -> Just SfxPlain
    "~r" -> Just SfxRestore
    _
      | Just nT <- T.stripPrefix "~d" sfx
      , Just n <- readDigits nT
      , n >= 1 ->
          Just (SfxDisplaced n)
    _ -> Nothing
  pure (pid, ix, s)
 where
  -- 规范十进制：无前导零、无符号、有界（P3b-7 复审 A1："p#00"、"p#0~d01" 不是
  -- pm 生成的，接受它们会让手编 "p#00~r" 抵消真实的 "p#0" Done）。isDigit 只认
  -- ASCII 0-9（GHC 9.10 实测 U+0663\/U+FF11 → False）；长度封顶 18 位使 read
  -- 永不越过 Int（超长串 read 会静默回绕，show n == t 本已拒绝，P3b-8 起不再
  -- 依赖回绕语义）。
  readDigits t
    | T.null t || T.length t > 18 || not (T.all isDigit t) = Nothing
    | otherwise =
        let n = read (T.unpack t) :: Int
         in if T.pack (show n) == t then Just n else Nothing

-- | 复位 rename 的 opId（§6.5）。
restoreOpId :: Text -> Int -> Text
restoreOpId pid ix = opId pid ix <> "~r"

-- | 第 N 次位移隔离的 opId。
displacedOpId :: Text -> Int -> Int -> Text
displacedOpId pid ix n = opId pid ix <> "~d" <> T.pack (show n)

-- | Win32 路径**分量**规范化（P3b-10 七轮复审 major，GHC 9.10 + Win11 实测）：
-- 打开文件时尾随的点会被丢弃（@.pm.@ 打开的就是 @.pm@，实测命中），比较不分
-- 大小写（@.PM@ 即 @.pm@，实测命中）；尾随空格反而**不**被剥（@.pm @ 打不开，
-- @.. @ 也不等于 @..@——codex 该断言实测证伪）。谓词按更保守的一侧取：两者
-- 一并剥除后再判定，宁可多拒（Windows 本就无法创建以点\/空格结尾的名字）。
normComp :: String -> String
normComp = map toLower . dropWhileEnd (\c -> c == '.' || c == ' ')

-- | 用户键入、将成为**新建目录分量**的名字（@pm sort --place\/--event@）：
-- pm 必须能按它忠实创建。保留字符与控制符不许；尾随点\/空格 Win32 创建时会
-- 剥掉（'normComp' 记录的实测），落位名与计划名从此不一致，执行期句柄后验
-- 必败——那是响亮失败，但该在计划前就拒。'relPathOk' 面对的是**盘上已有**的
-- 路径（剥后比较即可），两者问的不是同一件事（第一方自审 R3）。
winNameOk :: String -> Bool
winNameOk n = not (null n) && all ok n && normComp n == map toLower n
 where
  ok c = c `notElem` ("\\/:*?\"<>|" :: String) && not (isControl c)

-- | 外部可手编输入（plan\/journal\/manifest\/catalog）里相对路径字段的
-- fail-closed 词法校验（P3b-8 六轮复审 major，Exec\/validatePlan\/Doctor\/
-- Trash\/Catalog\/Undo 共用）：这些字段会被拼到 @root \<\/\>@ 或
-- @.pm\/trash \<\/\>@ 上，而 Windows 的 @\<\/\>@ 对带盘符（@c:evil@）或以分隔符
-- 开头（@\\evil@）的第二参数是**整体替换**而非拼接（filepath 实测），@..@
-- 分量向上越界，@:@ 还打开 NTFS 备用数据流（@a.jpg:ads@）。只接受非空、纯
-- 相对、不含 @:@、不以分隔符开头、且**规范化后**每个分量都非空的路径
-- （P3b-10：规范化后为空即 @.@ \/ @..@ \/ @...@ \/ 纯空格之类的等价名）。
--
-- 词法校验挡不住 junction\/symlink 别名——那一层由 'Pm.Win.pathUnder' 在真正
-- 动盘处（尤其 @pm trash empty@ 的唯一 unlink）做 canonical 限域。
relPathOk :: FilePath -> Bool
relPathOk p =
  not (null p)
    && not (isAbsolute p)
    && notElem ':' p
    && not (any isPathSeparator (take 1 p))
    && all (not . null . normComp) (splitDirectories p)

-- | Op 的相对路径字段（OpCopy 的 src 是绝对路径，允许指向其他 root，不在
-- 其列——它只被读取，落位目标是 dstRel；其来源 catalog 由
-- 'Pm.Catalog.loadCatalog' 校验）。
opRelPaths :: Op -> [FilePath]
opRelPaths OpCopy {opDstRel = d} = [d]
opRelPaths (OpRename o n _) = [o, n]
opRelPaths (OpQuarantine v _ _) = [v]

-- | **用户数据**相对路径：词法合法（'relPathOk'）且首级不是 @.pm@（比对走
-- 'normComp'，@.PM@ \/ @.pm.@ 一并拒绝）。Op 的落位目标与 catalog 条目路径
-- 共用一个谓词——两者都会被拼成绝对路径去读写真实文件，对"什么算用户数据
-- 路径"必须给出同一个答案。
userRelOk :: FilePath -> Bool
userRelOk p = relPathOk p && map normComp (take 1 (splitDirectories p)) /= [".pm"]

-- | 该相对路径是否落在 @.pm\/trash@ 之内（规范化后比对首两级）。这是 pm 唯一
-- 允许 Op 触及 @.pm@ 内部的形态——undo\/组复位 rename 的**源**，把隔离文件搬回
-- 原位。单一真源：'opPathsOk' 的例外判定与 'Pm.Exec' 的限域分流都用它，
-- 免得两处对"什么算 trash 源"给出不同答案。
isTrashSrcRel :: FilePath -> Bool
isTrashSrcRel p = relPathOk p && map normComp (take 2 (splitDirectories p)) == [".pm", "trash"]

-- | Op 全部相对路径合法，且不指向 @.pm@ 内部——唯一例外是 undo\/复位 rename
-- 的源（'isTrashSrcRel'）；其余任何 @.pm@ 前缀（如 rename
-- @.pm\/root-id.json@、quarantine journal）都是对 pm 自身状态的操纵，拒绝。
opPathsOk :: Op -> Bool
opPathsOk op = case op of
  OpCopy {opDstRel = d} -> userRelOk d
  OpRename o n _ -> (userRelOk o || isTrashSrcRel o) && userRelOk n
  OpQuarantine v _ _ -> userRelOk v

describeOp :: Op -> String
describeOp (OpCopy s d _ sz _) = "copy " <> s <> " -> " <> d <> " (" <> show sz <> " B)"
describeOp (OpRename o n _) = "rename " <> o <> " -> " <> n
describeOp (OpQuarantine v _ r) = "quarantine " <> v <> " (" <> T.unpack r <> ")"
