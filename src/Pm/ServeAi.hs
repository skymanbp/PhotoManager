{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @POST \/api\/suggest@（P8-D，DESIGN-P8 §22）：拉起用户自己账号下的
-- @claude -p@ 看图，给**分类**（相册里的 jpg → 类目 \/ 地点 \/ 坐标）或**地点**
-- （整理页的候选分段 → 地点）建议。四条边界照抄 photo-place，不放宽：只出
-- 建议、不进内核判断、不改任何计划参数、出不来就说出不来。
--
--   * 只读级端点：不写 @.pm@、不碰照片。模型跑在 @--permission-mode plan@ 下，
--     只放行只读工具，**构造上写不了任何东西**；cwd = 主库 root（分类）或源目录
--     （地点），让 Read 落在工作目录内（P8-D 探针：cwd 内 Read 图片免提示）。
--   * 可执行：@PM_CLAUDE_EXE@ → PATH 上的 @claude@；找不到 → 409。
--   * 一次只跑一个（'seSuggestLock'，上一次未完成 → 409）；整体超时
--     @PM_SUGGEST_TIMEOUT@ 秒（缺省 180），超时杀**整棵**进程树 → 409
--     （'Pm.Subprocess.runTool'：@claude.cmd@ → node 的子树也一起收掉，锁放开时
--     没有幽灵进程还在跑）。
--   * 上限：分类每次 ≤ 20 张；地点每次 ≤ 12 段、每段抽样 ≤ 5 张（首\/中\/尾）。
--   * 响应解析：@result@ 文本里取第一段 JSON（裸或 ``` 围栏）；解析不了 → 502
--     并把 @raw@ 原样带回——页面显示「AI 回复无法解析」，不猜。信封里
--     @is_error:true@（claude 自己报错，如额度用尽）→ 502 带原文。
module Pm.ServeAi (routeAi, findClaude, extractJson, evenSample) where

import Control.Concurrent.MVar (putMVar, tryTakeMVar)
import Control.Exception (finally, mask)
import Control.Monad (forM)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as AT
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Types
import Network.Wai
import System.Directory (doesFileExist, findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (splitDirectories, takeFileName)

import Pm.Album (albumTop)
import Pm.Catalog (catalogOr, loadCatalog)
import Pm.Config (Config (..), requireRole)
import Pm.ServeEnv
import Pm.ServeGuard (withJsonBody)
import Pm.Sort (SortSegment (..), SortSurvey (..), surveySort)
import Pm.Subprocess (ToolOutcome (..), envTimeout, runTool)
import Pm.Types
import Pm.VaultCore (fixedCategories, pushableExt)
import Pm.VaultHold (isFlatName)
import Pm.VaultNote (noteSources, parseCoordinates)
import Pm.Win (resolveUnder)

routeAi :: Config -> ServeEnv -> Request -> Reply -> ErrReply -> Maybe (IO ResponseReceived)
routeAi cfg env req jsonR err = case (requestMethod req, pathInfo req) of
  ("POST", ["api", "suggest"]) -> Just $ withJsonBody req err $ \sreq -> do
    eexe <- findClaude
    case eexe of
      Left m -> err status409 m
      Right exe -> do
        -- 取锁与登记归还在 mask 之内：取到之后、finally 装上之前若来一个异步
        -- 异常（warp 的连接超时）锁就永远丢了，之后每次点击都 409。
        got <- mask $ \restore -> do
          g <- tryTakeMVar (seSuggestLock env)
          case g of
            Nothing -> pure Nothing
            Just () ->
              Just
                <$> restore
                  ( case sreq of
                      SuggestClassify names -> classify cfg jsonR err exe names
                      SuggestPlace src gap -> place cfg jsonR err exe src gap
                  )
                  `finally` putMVar (seSuggestLock env) ()
        maybe (err status409 "上一次 AI 建议还没结束——等它回来再点") pure got
  _ -> Nothing

-- | @PM_CLAUDE_EXE@ → PATH 上的 @claude@（'findExecutable' 只按 @.exe@ 找——
-- 本机实测就是 @claude.exe@；装成 @claude.cmd@ 的用 @PM_CLAUDE_EXE@ 指过去）。
-- 找不到就说找不到。
findClaude :: IO (Either String FilePath)
findClaude = do
  mEnv <- lookupEnv "PM_CLAUDE_EXE"
  case mEnv of
    Just p -> do
      ok <- doesFileExist p
      pure (if ok then Right p else Left ("PM_CLAUDE_EXE 指向的文件不存在: " <> p))
    Nothing ->
      maybe (Left "未安装 claude CLI（PATH 上没有 claude）→ 装 Claude Code，或设 PM_CLAUDE_EXE 指向它") Right
        <$> findExecutable "claude"

-- ─── 分类 ───────────────────────────────────────────────────────────────────

classify :: Config -> Reply -> ErrReply -> FilePath -> [FilePath] -> IO ResponseReceived
classify cfg jsonR err exe names
  | null names || length names > 20 = err status400 "names 须为 1–20 个相册文件名（超过就分批）"
  | otherwise = do
      let root = cfgMainPath cfg
      er <- requireRole RoleMain root
      case er of
        Left m -> err status404 m
        Right _ -> do
          lc <- loadCatalog root
          case catalogOr "主库尚未索引 → 先 pm scan" lc of
            Left m -> err status404 m
            Right (cat, _) -> do
              let inAlbum e = take 1 (splitDirectories (enPath e)) == [albumTop] && enKind e == KindPhoto
                  byName = Map.fromList [(takeFileName (enPath e), e) | e <- Map.elems (catEntries cat), inAlbum e]
              resolved <- forM names $ \n -> case Map.lookup n byName of
                Nothing -> pure (n, Nothing)
                Just e -> (,) n <$> resolveUnder root (enPath e)
              let errs =
                    [n <> " 不是平铺文件名" | n <- names, not (isFlatName n)]
                      <> [n <> " 不在相册索引里（先 pm scan？）" | n <- names, Map.notMember n byName]
                      <> [n <> " 不是 jpg（AI 分类只看相册里的 jpg）" | n <- names, Map.member n byName, not (pushableExt n)]
                      <> [n <> " 不是库内真实路径（链接？），不交给模型" | (n, Nothing) <- resolved, Map.member n byName]
                      <> [n <> " 重复给出" | (n, k) <- Map.toList (Map.fromListWith (+) [(x, 1 :: Int) | x <- names]), k > 1]
              if not (null errs)
                then jsonR status400 [] (object ["error" .= ("names 不合法" :: String), "details" .= errs])
                else do
                  let paths = [p | (_, Just p) <- resolved]
                  r <- runClaude exe root (classifyPrompt paths)
                  case r of
                    Left (st, m) -> err st m
                    Right (result, cost) -> case extractJson result >>= AT.parseMaybe Aeson.parseJSON of
                      Nothing -> jsonR status502 [] (object ["error" .= ("AI 回复无法解析（不是预期的 JSON 数组）" :: String), "raw" .= result])
                      Just (items :: [AiItem]) -> do
                        let wanted = Map.fromList [(T.pack n, ()) | n <- names]
                            kept = [normItem it | it <- items, Map.member (aiName it) wanted]
                            answered = Map.fromList [(aiName it, ()) | it <- items]
                        jsonR
                          status200
                          []
                          ( object
                              [ "items" .= kept
                              , "dropped" .= [n | n <- names, Map.notMember (T.pack n) answered]
                              , "raw" .= result
                              , "cost" .= cost
                              ]
                          )

classifyPrompt :: [FilePath] -> Text
classifyPrompt paths =
  T.unlines $
    [ "你是照片整理助手。下面是若干张照片的绝对路径，请用 Read 工具逐张查看图像内容，然后只输出一个 JSON 数组（不要任何其它文字、不要围栏），每个元素形如："
    , "{\"name\":\"<文件名>\",\"category\":\"landscape|urban|portrait\" 或 null,\"location\":\"<地点>\" 或 null,\"coordinates\":\"<lat, lng>\" 或 null,\"source\":\"ai-high|ai-med|ai-low|none\",\"basis\":\"<一句依据>\",\"title\":\"<可选标题>\" 或 null}"
    , "规则：category 按图像内容判断（自然风景=landscape；城市、建筑、街道=urban；以人物为主体=portrait），不按宽高比，判不出给 null；"
    , "location 只在能从画面说出具体依据（地标、招牌、文字、独特地貌）时给，否则 null；coordinates 只在地点确定到具体地标时给十进制 \"lat, lng\"，否则 null；"
    , "source 表示你的把握：ai-high / ai-med / ai-low；category 与 location 都判不出时用 none。不要猜，不确定就 null。不要修改任何文件。"
    , "照片："
    ]
      <> map T.pack paths

-- | 模型给的一条分类建议（字段全部可缺省；@.:?@ 把 null 与缺失都读成 Nothing）。
data AiItem = AiItem
  { aiName :: Text
  , aiCategory :: Maybe Text
  , aiLocation :: Maybe Text
  , aiCoordinates :: Maybe Text
  , aiSource :: Maybe Text
  , aiBasis :: Maybe Text
  , aiTitle :: Maybe Text
  }

instance Aeson.FromJSON AiItem where
  parseJSON = Aeson.withObject "ai-item" $ \o ->
    AiItem
      <$> o Aeson..: "name"
      <*> o Aeson..:? "category"
      <*> o Aeson..:? "location"
      <*> o Aeson..:? "coordinates"
      <*> o Aeson..:? "source"
      <*> o Aeson..:? "basis"
      <*> o Aeson..:? "title"

-- | 规范化：类目不在 'fixedCategories' 里 → null；坐标解析不出 → null；
-- source 不在 'noteSources' 里 → @none@。页面拿到的永远是**能直接预填**的值——
-- 预填不等于已定，提交仍由用户点。
normItem :: AiItem -> Value
normItem it =
  object
    [ "name" .= aiName it
    , "category" .= (aiCategory it >>= \c -> if T.unpack c `elem` fixedCategories then Just c else Nothing)
    , "location" .= (aiLocation it >>= nonBlank)
    , "coordinates" .= (aiCoordinates it >>= \c -> (\(la, ln) -> T.pack (show la <> ", " <> show ln)) <$> parseCoordinates c)
    , "source" .= (case aiSource it of Just s | s `elem` noteSources -> s; _ -> "none")
    , "basis" .= (aiBasis it >>= nonBlank)
    , "title" .= (aiTitle it >>= nonBlank)
    ]
 where
  nonBlank t = let s = T.strip t in if T.null s then Nothing else Just s

-- ─── 地点 ───────────────────────────────────────────────────────────────────

-- | serve 自己重跑 'surveySort' 抽样，不信任客户端给的段与路径；段内只有
-- RAW（没有可看的 jpg）的段不交给模型，答 @place:null@ 并说明。
place :: Config -> Reply -> ErrReply -> FilePath -> FilePath -> Double -> IO ResponseReceived
place cfg jsonR err exe src gap = do
  r <- surveySort src gap cfg
  case r of
    Left m -> err status409 m
    Right sv
      | null (ssSegments sv) -> err status409 "源目录里没有可定时的照片段——先在整理页扫描确认"
      | length (ssSegments sv) > 12 -> err status400 "候选分段超过 12 段——提高间隔阈值或分批"
      | otherwise -> do
          let segs = [(g, evenSample 5 (filter pushableExt (sgFiles g))) | g <- ssSegments sv]
              viewable = [(g, ps) | (g, ps) <- segs, not (null ps)]
              blind g = object ["index" .= sgIndex g, "place" .= Aeson.Null, "basis" .= ("没有可看的图（段内只有 RAW / 无 jpg）" :: String), "confidence" .= ("none" :: String)]
          if null viewable
            then jsonR status200 [] (object ["segments" .= map (blind . fst) segs, "raw" .= ("" :: String), "cost" .= Aeson.Null])
            else do
              er <- runClaude exe (ssSrcAbs sv) (placePrompt viewable)
              case er of
                Left (st, m) -> err st m
                Right (result, cost) -> case extractJson result >>= AT.parseMaybe Aeson.parseJSON of
                  Nothing -> jsonR status502 [] (object ["error" .= ("AI 回复无法解析（不是预期的 JSON 数组）" :: String), "raw" .= result])
                  Just (ans :: [AiSeg]) -> do
                    let byIx = Map.fromList [(asIndex a, a) | a <- ans]
                        one (g, ps)
                          | null ps = blind g
                          | otherwise = case Map.lookup (sgIndex g) byIx of
                              Nothing -> object ["index" .= sgIndex g, "place" .= Aeson.Null, "basis" .= ("模型没有回答这一段" :: String), "confidence" .= ("none" :: String)]
                              Just a ->
                                object
                                  [ "index" .= sgIndex g
                                  , "place" .= (asPlace a >>= \p -> let s = T.strip p in if T.null s then Nothing else Just s)
                                  , "basis" .= fromMaybe "" (asBasis a)
                                  , "confidence" .= (case asConfidence a of Just c | c `elem` ["high", "med", "low"] -> c; _ -> "low")
                                  ]
                    jsonR status200 [] (object ["segments" .= map one segs, "raw" .= result, "cost" .= cost])

placePrompt :: [(SortSegment, [FilePath])] -> Text
placePrompt segs =
  T.unlines $
    [ "你是照片整理助手。下面按「段」列出若干张照片的绝对路径（同一段是同一趟拍摄，按拍摄时间首/中/尾抽样）。请用 Read 工具逐张查看图像内容，判断每一段是在哪里拍的，然后只输出一个 JSON 数组（不要任何其它文字、不要围栏），每个元素形如："
    , "{\"index\":<段号>,\"place\":\"<地点，越具体越好，如城市或景区名>\" 或 null,\"basis\":\"<一句依据：看到了什么地标/招牌/文字/地貌>\",\"confidence\":\"high|med|low\"}"
    , "规则：只在画面里有具体依据时给地点，否则 place 用 null；不要用文件名、不要猜；每一段都要有一个元素。不要修改任何文件。"
    ]
      <> concat
        [ ("段 " <> T.pack (show (sgIndex g)) <> "（" <> T.pack (show (sgFrom g)) <> " → " <> T.pack (show (sgTo g)) <> "，共 " <> T.pack (show (sgCount g)) <> " 张，抽样 " <> T.pack (show (length ps)) <> " 张）：")
            : map T.pack ps
        | (g, ps) <- segs
        ]

data AiSeg = AiSeg
  { asIndex :: Int
  , asPlace :: Maybe Text
  , asBasis :: Maybe Text
  , asConfidence :: Maybe Text
  }

instance Aeson.FromJSON AiSeg where
  parseJSON = Aeson.withObject "ai-seg" $ \o ->
    AiSeg <$> o Aeson..: "index" <*> o Aeson..:? "place" <*> o Aeson..:? "basis" <*> o Aeson..:? "confidence"

-- | 首\/中\/尾均匀抽样 ≤ n 个（n ≥ 2；不足 n 个原样返回）。
evenSample :: Int -> [a] -> [a]
evenSample n xs
  | len <= n = xs
  | otherwise = [xs !! ((i * (len - 1)) `div` (n - 1)) | i <- [0 .. n - 1]]
 where
  len = length xs

-- ─── 子进程与响应解析 ───────────────────────────────────────────────────────

-- | @{"kind":"classify","names":[…]}@ 或 @{"kind":"place","src":"…","gap":72}@
data SuggestReq = SuggestClassify [FilePath] | SuggestPlace FilePath Double

instance Aeson.FromJSON SuggestReq where
  parseJSON = Aeson.withObject "suggest" $ \o -> do
    k <- o Aeson..: "kind"
    case (k :: Text) of
      "classify" -> SuggestClassify <$> o Aeson..: "names"
      "place" -> SuggestPlace <$> o Aeson..: "src" <*> (fromMaybe 72 <$> o Aeson..:? "gap")
      _ -> fail "kind 须为 classify 或 place"

-- | 跑 @claude -p --output-format json --permission-mode plan --max-turns 8@，
-- 提示经 stdin 交给它（'runTool'：三个管道显式 UTF-8、整体超时到点杀整棵进程
-- 树）。返回（@result@ 文本，@total_cost_usd@）；信封 @is_error:true@ → 502。
runClaude :: FilePath -> FilePath -> Text -> IO (Either (Status, String) (Text, Value))
runClaude exe dir prompt = do
  secs <- envTimeout "PM_SUGGEST_TIMEOUT" 180
  r <- runTool exe ["-p", "--output-format", "json", "--permission-mode", "plan", "--max-turns", "8"] (Just dir) [] prompt secs
  pure $ case r of
    ToolFailed e -> Left (status409, "拉起 claude 失败: " <> e)
    ToolTimeout n -> Left (status409, "claude 超过 " <> show n <> " 秒未回复，已终止整棵进程树（PM_SUGGEST_TIMEOUT 可调）")
    ToolRan (ExitFailure n) out errT -> Left (status502, "claude 退出码 " <> show n <> ": " <> T.unpack (T.take 400 (T.strip (errT <> out))))
    ToolRan ExitSuccess out _ -> case Aeson.eitherDecodeStrict' (TE.encodeUtf8 out) of
      Left e -> Left (status502, "claude 输出不是 JSON: " <> e)
      Right v -> case AT.parseMaybe envelope v of
        Nothing -> Left (status502, "claude 输出缺 result 字段")
        Just (res, _, True) -> Left (status502, "claude 报错（is_error）: " <> T.unpack (T.take 400 (T.strip res)))
        Just (res, cost, False) -> Right (res, cost)
 where
  envelope = Aeson.withObject "claude-json" $ \o ->
    (,,)
      <$> o Aeson..: "result"
      <*> (fromMaybe Aeson.Null <$> o Aeson..:? "total_cost_usd")
      <*> (fromMaybe False <$> o Aeson..:? "is_error")

-- | @result@ 文本里的第一段 JSON：从第一个 @[@ \/ @{@ 到最后一个 @]@ \/ @}@
-- （``` 围栏、前后说明文字都在括号之外）；解析不出 → Nothing。
extractJson :: Text -> Maybe Value
extractJson t = case mapMaybe (Aeson.decodeStrict' . TE.encodeUtf8) candidates of
  (v : _) -> Just v
  [] -> Nothing
 where
  s = T.strip t
  open = T.findIndex (`elem` ['[', '{']) s
  close = fmap (\i -> T.length s - i) (T.findIndex (`elem` [']', '}']) (T.reverse s))
  clipped = case (open, close) of
    (Just i, Just j) | j > i -> [T.take (j - i) (T.drop i s)]
    _ -> []
  candidates = [s | isJust open] <> clipped
