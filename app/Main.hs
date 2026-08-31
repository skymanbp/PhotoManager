{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Thin CLI shell: option parsing + dispatch only. All orchestration lives
-- in Pm.Commands / Pm.Cli (库层，P4 的 serve/GUI 复用同一路径).
-- CPP 只为一处：@--version@ 取 Cabal 注入的 @CURRENT_PACKAGE_VERSION@ 宏。
module Main (main) where

-- 两摞、各自按字母序：先 base/外部，再 Pm.*。P4-8 与 P5-A 各自把新 import
-- 塞在了中间（Data.Time / Text.Read / Pm.ConfigEdit），本次归位。
import qualified Data.Text as T
import Data.Time (Day)
import Options.Applicative
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import Text.Read (readMaybe)

import Pm.Album (runAlbumAdd, runAlbumCandidates, runAlbumIgnore)
import Pm.Cli (GoOpts (..), savePlanAndMaybeRun, savePlanAndMaybeRun')
import Pm.Plan (runPlanList, runPlanPrune, runPlanRm)
import Pm.Commands
import Pm.ConfigEdit (ConfigSetOpts (..), mkPatch, runConfigSet, runConfigShow)
import Pm.Convert (ConvertOpts (..), runConvert)
import Pm.Doctor (DoctorOpts (..), renderFinding, runDoctor)
import Pm.Ingest (runVaultIngest)
import Pm.Names (runNames)
import Pm.Serve (ServeOpts (..), runServe)
import Pm.Sort (runSortPlan, runSortSurvey)
import Pm.Status (StatusOpts (..), runStatus)
import Pm.Ui (runUi)
import Pm.Vault (runVaultPush, runVaultStatus)
import Pm.VaultCmd (NoteArgs (..), runVaultHold, runVaultNote, runVaultNotes)
import Pm.VaultNote (NoteFields (..))
import Pm.Versions (runVersions)
import Pm.Win (setupConsole)

data Cmd
  = CmdInit InitOpts
  | CmdScan ScanCmd
  | CmdStatus StatusOpts
  | CmdDoctor DoctorOpts Bool Bool -- --backup / --vault
  | CmdTrash TrashCmd Bool Bool
  | CmdUndo Int Bool Bool
  | CmdApply ApplyOpts
  | CmdResolve ResolveOpts
  | CmdImport GoOpts Bool -- --also-album（P8-B：成片 jpg 同源再拷一份进相册）
  | CmdAlbum AlbumCmd -- 成片 → 相册（P8-B，DESIGN-P8 §19.3/19.4）
  | CmdConvert ConvertOpts -- 非 jpg → 派生 jpg 的两段式转换（P8-C2，DESIGN-P8 §20）
  | CmdSort SortOpts
  | CmdBackup BackupCmd
  | CmdClean GoOpts -- clean staging
  | CmdVaultStatus Bool -- --json（sync_photos.py 兼容输出）
  | CmdVaultPush GoOpts (Maybe String) [FilePath] -- --category + FILES
  | CmdVaultHold Bool [FilePath] -- 暂不同步（True）/ 恢复（False）；只写主库 .pm
  | CmdVaultNote NoteArgs -- 照片记录（P8-C）：类目/地点/坐标/标题；只写主库 .pm/vault-notes.json
  | CmdVaultNotes Bool -- --json；列出照片记录与发布状态（只读）
  | CmdVaultIngest GoOpts String [FilePath] -- --category + FILES；两份计划（主库 相册/ + vault <类目>/）
  | CmdConfigShow -- 打印配置与路径健康（只读）
  | CmdConfigSet ConfigSetOpts -- 改 vault / photos.json / 并发数（主库路径只读）
  | CmdNames GoOpts -- Raw 事件夹 Scheme A 统一
  | CmdVersions -- 版本组/精确重复报告（只读）
  | CmdDedupe GoOpts -- 精确重复 → 逐份可裁决的隔离计划（全部 NEEDS-DECISION）
  | CmdServe ServeOpts -- 127.0.0.1 JSON API（缺省只读；--writable 才开生成计划端点）
  | CmdUi -- 拉起 Tauri 桌面 GUI（P4-3；GUI 自己跑 serve）
  | CmdPlanCmd PlanSub -- 计划文件管理（2026-08-31：list 带 journal 折叠执行态 / rm / prune）

-- | @pm album@ 的子命令（P8-B；ignore 系 2026-08-31）：@add@ 生成成片→相册的
-- 拷贝计划；@candidates@ 只读列出候选；@ignore@\/@unignore@ 按内容 sha 把候选
-- 压进\/移出主库 @.pm\/album-ignore.json@（照片零改动）。
data AlbumCmd = AlbumAdd GoOpts [String] | AlbumCandidates | AlbumIgnoreC Bool [String]

-- | @pm plan@ 的三个子命令：不带子命令 = @list@。
data PlanSub = PlanList | PlanRm [String] | PlanPrune

-- | @pm sort@ 的参数（两种形态见 'run'）。
data SortOpts = SortOpts
  { soSrc :: FilePath
  , soPlace :: Maybe String
  , soEvent :: Maybe String
  , soFrom :: Maybe Day
  , soTo :: Maybe Day
  , soGapHours :: Double
  , soGo :: GoOpts
  }

-- | --backup/--vault 二选一校验后进入命令体。
withSel :: Bool -> Bool -> (RootSel -> IO Int) -> IO Int
withSel bku vlt act = case rootSel bku vlt of
  Left m -> putStrLn m >> pure 2
  Right sel -> act sel

main :: IO ()
main = do
  setupConsole
  cmd <- execParser parserInfo
  code <- run cmd
  if code == 0 then exitSuccess else exitWith (ExitFailure code)

run :: Cmd -> IO Int
run (CmdInit o) = runInit o
run (CmdScan o) = withCfg (runScanCmd o)
run (CmdStatus o) = withCfg (\cfg -> runStatus cfg o)
run (CmdDoctor o bku vlt) = withCfg $ \cfg -> withSel bku vlt $ \sel -> do
  eroot <- pickRoot cfg sel
  case eroot of
    Left (msg, code) -> putStrLn msg >> pure code
    Right root -> do
      (findings, code) <- runDoctor root o
      if null findings
        then putStrLn "✓ doctor: 无发现"
        else mapM_ (putStrLn . renderFinding) findings
      pure code
run (CmdTrash tc bku vlt) = withCfg $ \cfg -> withSel bku vlt $ \sel -> do
  eroot <- pickRoot cfg sel
  case eroot of
    Left (msg, code) -> putStrLn msg >> pure code
    Right root -> runTrash cfg tc root
run (CmdUndo n bku vlt) = withCfg $ \cfg -> withSel bku vlt $ \sel -> runUndoCmd n sel cfg
run (CmdApply o) = withCfg (runApply o)
run (CmdResolve o) = withCfg (runResolve o)
run (CmdImport go also) = withCfg (runImport go also)
run (CmdAlbum (AlbumAdd go fs)) = withCfg (runAlbumAdd go fs)
run (CmdAlbum AlbumCandidates) = withCfg runAlbumCandidates
run (CmdAlbum (AlbumIgnoreC doIg fs)) = withCfg (runAlbumIgnore doIg fs)
run (CmdPlanCmd PlanList) = withCfg runPlanList
run (CmdPlanCmd (PlanRm ids)) = withCfg (runPlanRm ids)
run (CmdPlanCmd PlanPrune) = withCfg runPlanPrune
run (CmdConvert o) = withCfg (runConvert o)
-- 两种形态：地点与日期区间**给齐**才生成计划，一个都不给是只读提议；
-- 给一半是使用者写错了，直接报错——不替他猜另一半（I1）。
run (CmdSort o) = withCfg $ \cfg ->
  case (soPlace o, soEvent o, soFrom o, soTo o) of
    (Nothing, Nothing, Nothing, Nothing) -> runSortSurvey (soSrc o) (soGapHours o) cfg
    (mp, me, Just f, Just t) -> case (mp, me) of
      (Just _, Just _) -> putStrLn "--place 与 --event 只能给一个" >> pure 2
      -- 计划 id 只有 GUI 那条路要（第二页生成后要显示/跳转）；CLI 已经
      -- 在计划渲染里打印过它，这里只取退出码。
      (Just p, Nothing) -> fst <$> runSortPlan (soGo o) (soSrc o) (Left p) f t cfg
      (Nothing, Just e) -> fst <$> runSortPlan (soGo o) (soSrc o) (Right e) f t cfg
      (Nothing, Nothing) -> putStrLn "给了 --from/--to 就必须给 --place 或 --event" >> pure 2
    _ -> putStrLn "生成计划需要同时给 --from 与 --to（先不带参数跑一次看分段提议）" >> pure 2
run (CmdBackup (BackupInit p)) = withCfg (runBackupInit p)
run (CmdBackup (BackupRun go mworkers)) = withCfg (runBackupRun go mworkers)
run (CmdClean go) = withCfg (runClean go)
run (CmdVaultStatus asJson) = withCfg (runVaultStatus asJson)
-- push 与 ingest 同：收尾按逐项结果判（'Pm.Cli.landedItems'），退出码由
-- 'Pm.Cli.planRunCode' 换算（工作流 F068）。
run (CmdVaultPush go mcat fs) =
  withCfg (\cfg -> runVaultPush (savePlanAndMaybeRun' cfg go) mcat fs cfg)
run (CmdVaultHold hold fs) = withCfg (runVaultHold hold fs)
run (CmdVaultNote a) = withCfg (runVaultNote a)
run (CmdVaultNotes asJson) = withCfg (runVaultNotes asJson)
-- ingest 走可判别的 'savePlanAndMaybeRun''：它要按「主库那份**真的全部落完**」
-- 决定 vault 那份跑不跑，Int 退出码分不出这个（三十二轮 R4，见 Pm.Ingest）。
run (CmdVaultIngest go cat fs) =
  withCfg (\cfg -> runVaultIngest (savePlanAndMaybeRun' cfg go) (goApply go) cat fs cfg)
run CmdConfigShow = withCfg runConfigShow
-- 工作流 F082：--X 与 --no-X 同给是矛盾，报错退出 2（与 --place/--event、
-- --backup/--vault 同一纪律），不在解析器里替使用者猜一个
run (CmdConfigSet o) = either (\m -> putStrLn m >> pure 2) (\p -> withCfg (runConfigSet p)) (mkPatch o)
run (CmdNames go) = withCfg (\cfg -> runNames (savePlanAndMaybeRun cfg go) cfg)
run CmdVersions = withCfg runVersions
run (CmdDedupe go) = withCfg (runDedupe go)
run (CmdServe o) = withCfg (\cfg -> runServe cfg o)
-- 先过 withCfg：配置缺失时在这里报清楚，而不是让 GUI 里的 serve 静默失败
run CmdUi = withCfg (const runUi)

parserInfo :: ParserInfo Cmd
parserInfo =
  info
    (helper <*> versionOpt <*> (commands <|> pure (CmdStatus (StatusOpts False))))
    (fullDesc <> header "pm — 照片库管理器（零参数 = pm status；写盘一律两段式 计划→apply）")
 where
  versionOpt =
    -- 版本号取自 package.yaml（Cabal 注入的 CPP 宏），不再手抄一份：
    -- 二十四轮实测，这个字面量是第六处版本号，改版本时漏掉它 → 0.4.6 的
    -- 二进制自称 0.4.5。单一真源之后它不可能再漂。
    -- 0.6.0 发布链实测：改宏不改 Paths 模块，因为 Paths_photo_manager 把
    -- 构建机的六个安装目录（D:\…\.stack-work\install\…）整段烤进二进制——
    -- 公开资产不得带本机路径；package.yaml 的 exe 段同时不再生成该模块。
    infoOption ("pm " <> CURRENT_PACKAGE_VERSION) (long "version" <> help "打印版本")
  backupSw = switch (long "backup" <> help "作用于备份 root（需插盘）")
  vaultSw = switch (long "vault" <> help "作用于 vault root（首次 pm vault push 时建立）")
  commands =
    hsubparser
      ( command "init" (info initP (progDesc "生成配置 + 主库 root 标识"))
          <> command "scan" (info scanP (progDesc "索引主库（增量；首次全量 hash）"))
          <> command "status" (info statusP (progDesc "总览仪表盘（默认命令）"))
          <> command "import" (info importP (progDesc "暂存区 To-Be-Sync'd → Raw/成片 归档计划（--also-album 同时把成片 jpg 拷进相册）"))
          <> command "album" (info albumP (progDesc "成片 → 相册（平铺收藏层，只收 jpg）：add 生成拷贝计划；candidates 列出候选；ignore/unignore 按内容忽略候选"))
          <> command "convert" (info convertP (progDesc "非 jpg 照片（tif/png/psd/heic…）→ 派生 jpg（Pillow，写 .pm/derived）→ 落成片同事件夹/相册的计划；原文件原地不动"))
          <> command "sort" (info sortP (progDesc "散落新照片按拍摄时间分段 → 暂存区事件夹（不带参数=只读提议）"))
          <> command "backup" (info backupP (progDesc "主库 → 备份盘单向增量（init 登记备份盘）"))
          <> command "clean" (info cleanP (progDesc "clean staging: 三副本确认后的暂存清理计划"))
          <> command "vault" (info vaultP (progDesc "相册 ↔ vault 展示集（status 兼容 sync_photos.py）"))
          <> command "names" (info (CmdNames <$> goOpts) (progDesc "Raw 事件夹统一 Scheme A（YY-MM-地点-Raw；目录改名走 §6.2 协议，undo 可回滚）"))
          <> command "versions" (info (pure CmdVersions) (progDesc "版本组/精确重复报告（只读；版本后缀不强制统一）"))
          <> command "dedupe" (info (CmdDedupe <$> goOpts) (progDesc "归档层精确重复 → 逐份可裁决的隔离计划（全部待裁决；留哪份 pm 不替你选，用 pm resolve --unskip 逐份批准）"))
          <> command "doctor" (info doctorP (progDesc "崩溃恢复对账 + 完整性体检（默认只读）"))
          <> command "trash" (info trashP (progDesc "隔离区：list / empty（唯一最终清除入口）"))
          <> command "undo" (info undoP (progDesc "由主库 journal 生成反向计划（经 pm apply 执行）"))
          <> command "apply" (info applyP (progDesc "执行已存的计划（root 按 UUID 重新绑定；--only 按组闭包）"))
          <> command "resolve" (info resolveP (progDesc "裁决计划某项：跳过/恢复/--keep src|dst|both（组为单元）"))
          <> command "serve" (info serveP (progDesc "127.0.0.1 JSON API（供 GUI/skill；随机端口 + 会话 token，启动时打印一行 JSON；缺省只读，见 --writable）"))
          <> command
            "config"
            ( info
                ( hsubparser
                    ( command "show" (info (pure CmdConfigShow) (progDesc "打印配置与每条路径的健康状态（只读）"))
                        <> command "set" (info (CmdConfigSet <$> patchP) (progDesc "改 vault / photos.json / 并发数（主库路径只读，用 pm init）"))
                    )
                    <|> pure CmdConfigShow
                )
                (progDesc "查看/修改配置（GUI 设置页与此同源）")
            )
          <> command "ui" (info (pure CmdUi) (progDesc "拉起桌面 GUI（pm-ui.exe：PM_UI_EXE 或 pm.exe 同目录；GUI 自己启动并管理 pm serve）"))
          <> command
            "plan"
            ( info
                ( hsubparser
                    ( command "list" (info (pure (CmdPlanCmd PlanList)) (progDesc "列出主库/vault 的计划与执行态（已执行/部分/未执行——从 journal 折叠，计划文件不回写）"))
                        <> command "rm" (info (CmdPlanCmd . PlanRm <$> many (strArgument (metavar "PLAN-ID..." <> help "要删除的计划 id（pm plan list 查看）"))) (progDesc "删除计划文件（可再生成；journal/undo 不受影响）"))
                        <> command "prune" (info (pure (CmdPlanCmd PlanPrune)) (progDesc "一键清理已执行的计划（待执行项全部 Done 且无待裁决残余；草稿不动）"))
                    )
                    <|> pure (CmdPlanCmd PlanList)
                )
                (progDesc "计划文件管理（GUI 计划页与此同源）：list / rm / prune")
            )
      )
  -- 三态：不给 = 不动；--no-X = 清空；给值 = 设值。与 API 的 JSON 三态同构。
  -- 解析器只收集原始 (值, 清空) 对；矛盾（两个都给）由 'Pm.ConfigEdit.mkPatch'
  -- 拒绝（工作流 F082——旧写法在这里把矛盾静默折成清空）。
  patchP =
    ConfigSetOpts
      <$> pair "vault" "展示集（vault）目录"
      <*> pair "photos-json" "portfolio 的 photos.json（只读引用检查）"
      <*> ( (,)
              <$> optional (option auto (long "workers" <> metavar "N" <> help "扫描并发数（1..64）；备份盘不读它，默认单线程防 HDD 寻道抖动，另用 pm backup --workers"))
              <*> switch (long "no-workers" <> help "清空并发数（回到默认=核数）")
          )
      <*> pair "portfolio-dir" "portfolio 仓的本地路径（上线命令生成用）"
      <*> pair "vault-push" "展示集仓的 push 目标（如 origin main；不设 = 裸 git push）"
      <*> pair "portfolio-push" "portfolio 仓的 push 目标（同上）"
      -- 只为**拒绝**而存在（internal，不出现在帮助里）：与 JSON 的
      -- @"main": null@ 同构——出现即拒，不区分"设值"还是"清空"。
      <*> optional (strOption (long "main" <> metavar "PATH" <> internal))
  pair nm desc =
    (,)
      <$> optional (strOption (long nm <> metavar "PATH" <> help ("设置" <> desc)))
      <*> switch (long ("no-" <> nm) <> help ("清空" <> desc))
  serveP =
    fmap CmdServe $
      ServeOpts
        <$> optional (option auto (long "port" <> metavar "N" <> help "固定端口（默认由内核随机分配）"))
        <*> switch (long "exit-on-stdin-eof" <> help "stdin 关闭即退出（GUI 拉起时用：父进程一死 serve 随之结束，不留孤儿）")
        <*> switch (long "writable" <> help "允许十二个 POST 写端点：生成推送计划（写 vault 的 .pm/plans + 首次 root-id）、生成 sort / 归档 / 相册 / 转换计划（写主库的 .pm/plans；转换另写 .pm/derived 派生件）、记录「暂不同步」决定（写主库的 .pm/vault-holds.json）、照片记录（写主库的 .pm/vault-notes.json）、忽略候选（写主库的 .pm/album-ignore.json）、删除/清理计划文件（只删 .pm/plans，journal 不动）、改配置（写 config.toml，主库路径只读）、登记备份盘（在盘上建备份 root 标识）；都不执行、不碰照片；缺省只读。AI 建议 POST /api/suggest 是只读级（拉起 claude -p，只出建议）")
        <*> switch (long "allow-apply" <> help "另外允许 POST /api/apply 执行已存的计划——这是唯一会动照片字节的端点，因此单独一个开关，不并进 --writable（蕴含 --writable）。装载/绑 root/--only/执行期复验全部与 CLI 的 pm apply 同源")
  initP =
    fmap CmdInit $
      InitOpts
        <$> strOption (long "main" <> metavar "PATH" <> help "主库路径，如 D:\\Photography")
        <*> optional (strOption (long "vault" <> metavar "PATH" <> help "vault 展示集路径（P3 使用）"))
        <*> optional (strOption (long "photos-json" <> metavar "PATH" <> help "portfolio photos.json 路径（P3 使用）"))
        <*> optional (option auto (long "workers" <> metavar "N" <> help "hash 并行度（默认=物理核数）"))
        <*> switch (long "force" <> help "已有配置时允许覆盖（备份盘登记保留）")
  scanP =
    fmap CmdScan $
      ScanCmd
        <$> optional (option auto (long "workers" <> metavar "N" <> help "hash 并行度"))
        <*> switch (long "quiet" <> help "不打印进度")
  statusP =
    fmap CmdStatus $
      StatusOpts
        <$> switch (long "cached" <> help "跳过新鲜度核对，纯读快照")
  goOpts =
    GoOpts
      <$> switch (long "apply" <> help "展示计划后确认执行（缺省只生成计划）")
      <*> switch (long "yes" <> help "跳过交互确认（脚本用）")
  importP =
    CmdImport
      <$> goOpts
      <*> switch (long "also-album" <> help "成片里的 jpg 同时拷一份进相册（同源第二份拷贝，与成片项同组：成片没落位相册就不执行；非 jpg 只进成片）")
  albumP =
    fmap CmdAlbum $
      hsubparser
        ( command
            "add"
            ( info
                (AlbumAdd <$> goOpts <*> many (strArgument (metavar "事件夹/文件名..." <> help "相对成片层的路径，如 26-06-R66/_DSC9621.jpg（只收 jpg；相册平铺，同名只能进一份）")))
                (progDesc "成片里已归档的 jpg 挑进相册（拷贝计划；相册同名异容 → 待裁决，I5）")
            )
            <> command "candidates" (info (pure AlbumCandidates) (progDesc "只读：成片里还没进相册的 jpg（按事件夹）与成片/相册下的非 jpg（→ pm convert）；已忽略的单列"))
            <> command
              "ignore"
              ( info
                  (AlbumIgnoreC True <$> many (strArgument (metavar "事件夹/文件名..." <> help "要忽略的候选（相对成片层）")))
                  (progDesc "忽略候选：按内容 sha 记进主库 .pm/album-ignore.json，候选清单不再列出（照片零改动；重新导出=新内容会重新出现）")
              )
            <> command
              "unignore"
              ( info
                  (AlbumIgnoreC False <$> many (strArgument (metavar "事件夹/文件名|sha..." <> help "要恢复的候选：当前路径、记录里的存档路径、或 64 位 sha")))
                  (progDesc "取消忽略，候选回到清单")
              )
        )
  -- P8-C2：两段式——第一段派生（生成期写 .pm/derived，python 由 PM_PYTHON / PATH 发现），
  -- 第二段照片层落位仍是计划（--apply / pm apply）。
  convertP =
    fmap CmdConvert $
      ConvertOpts
        <$> goOpts
        <*> switch (long "also-album" <> help "派生 jpg 同时进相册（源在成片时；与成片项同组：成片没落位相册不执行）")
        <*> switch (long "redo" <> help "已有派生件也重新派生（缺省复用 .pm/derived 里的）")
        <*> many (strArgument (metavar "库内相对路径..." <> help "成片/<事件夹>/<文件> 或 相册/<文件>：tif/png/psd/heic 等已渲染位图；RAW 不是转换对象"))
  sortP =
    fmap CmdSort $
      SortOpts
        <$> argument str (metavar "源目录" <> help "相机卡/下载目录等，散落新照片所在处（只读，不会被改动）")
        <*> optional (strOption (long "place" <> metavar "地点" <> help "事件地点；年月自动取自该段起始日"))
        <*> optional (strOption (long "event" <> metavar "YY-MM-地点" <> help "直接给完整事件夹名（跨月旅程/并入已有事件时用）"))
        <*> optional (option dayReader (long "from" <> metavar "YYYY-MM-DD" <> help "区间起（含）"))
        <*> optional (option dayReader (long "to" <> metavar "YYYY-MM-DD" <> help "区间止（含）"))
        <*> option auto (long "gap-hours" <> metavar "H" <> value 72 <> showDefault <> help "提议分段用的间隔阈值（只影响提议，不影响归位）")
        <*> goOpts
  dayReader = maybeReader (readMaybe :: String -> Maybe Day)
  backupP =
    fmap CmdBackup $
      hsubparser
        ( command
            "init"
            ( info
                (BackupInit <$> strArgument (metavar "PATH" <> help "备份盘上的镜像路径，如 E:\\Photography"))
                (progDesc "登记已插入的备份盘（写 .pm/root-id.json，按 UUID 认盘不认盘符）")
            )
        )
        <|> (BackupRun <$> goOpts <*> optional (option auto (long "workers" <> metavar "N" <> help "备份盘 hash 并行度（默认 1，HDD 防寻道抖动）")))
  cleanP =
    fmap CmdClean $
      hsubparser
        (command "staging" (info goOpts (progDesc "仅清理「Raw/成片 + 备份盘」都有同 sha 副本的暂存文件")))
  vaultP =
    hsubparser
      ( command
          "status"
          ( info
              (CmdVaultStatus <$> switch (long "json" <> help "sync_photos.py 兼容的 JSON 输出（六键值形状逐字段一致，另加 unpushable / unstable / held / held_stale）"))
              (progDesc "相册 ↔ vault 差异（六态 + UNPUSHABLE / UNSTABLE / HELD；只读；退出码 0/1/2 同 sync_photos.py，但已决定「暂不同步」的 NEW 不计入差异）")
          )
          <> command
            "push"
            ( info
                ( CmdVaultPush
                    <$> goOpts
                    <*> optional (strOption (long "category" <> metavar "CAT" <> help "landscape|portrait|urban——推送 NEW 文件的类目（CLI 无法看图，类目由你定）"))
                    <*> many (strArgument (metavar "FILES..." <> help "要推送的 NEW 文件名（相册内文件名，须配 --category）"))
                )
                (progDesc "NEW→拷入 vault 类目；DRIFT→生成裁决计划（resolve --keep src 走 supersede）；结束打印显式 git 步骤（pm 不执行 git，I9）")
            )
          <> command
            "hold"
            ( info
                (CmdVaultHold True <$> many (strArgument (metavar "FILES..." <> help "决定暂不同步的 NEW 文件名")))
                (progDesc "把 NEW 标成「暂不同步」：只写主库 .pm 的一条本地决定，vault 与照片零改动，随时 unhold 恢复")
            )
          <> command
            "unhold"
            ( info
                (CmdVaultHold False <$> many (strArgument (metavar "FILES..." <> help "要恢复待同步的文件名")))
                (progDesc "撤销「暂不同步」，文件回到 NEW")
            )
          <> command
            "note"
            ( info
                noteP
                (progDesc "记一条照片记录（类目/地点/坐标/标题）到主库 .pm/vault-notes.json：vault 与照片零改动；/photo-publish 据此写 photos.json；--clear 清除")
            )
          <> command
            "notes"
            ( info
                (CmdVaultNotes <$> switch (long "json" <> help "机器可读：每条带 status（unsynced/pending/published/stale/unknown）与 vault_category/photos_json_line/why"))
                (progDesc "列出照片记录及其发布状态（只读；有 stale/unknown 时退出码 1）")
            )
          <> command
            "ingest"
            ( info
                ( CmdVaultIngest
                    <$> goOpts
                    <*> strOption (long "category" <> metavar "CAT" <> help "landscape|portrait|urban——本批成品的类目（看图分类归调用方）")
                    <*> many (strArgument (metavar "FILES..." <> help "_inbox 里的成品 JPG（绝对路径；pm 只拷不动源）"))
                )
                (progDesc "批量入库：源 → 主库 相册/ + vault <类目>/ 两份计划（I5 冲突出裁决项）；_inbox→_done 与 photos.json 由调用方收尾（pm 打印显式步骤）")
            )
      )
  -- P8-C：记录时给且只给一个文件名（字段跟着它）；--clear 可多个。组合校验在
  -- 'runVaultNote'（同 --place/--event 的纪律：不在解析器里替使用者猜）。
  noteP =
    fmap CmdVaultNote $
      NoteArgs
        <$> switch (long "clear" <> help "清除给定文件的记录（可多个文件）")
        <*> many (strArgument (metavar "FILES..." <> help "相册里的文件名（记录时给且只给一个；--clear 可多个）"))
        <*> ( NoteFields
                <$> optional (strOption (long "category" <> metavar "CAT" <> help "landscape|portrait|urban"))
                <*> optional (T.pack <$> strOption (long "location" <> metavar "地点" <> help "地点文字，如「Hallstatt, AT」（≤200 字符）"))
                <*> optional (T.pack <$> strOption (long "coordinates" <> metavar "\"lat, lng\"" <> help "十进制坐标，如「47.556533, 13.648033」"))
                <*> optional (T.pack <$> strOption (long "title" <> metavar "标题" <> help "标题（≤200 字符）"))
                <*> (T.pack <$> strOption (long "source" <> metavar "SRC" <> value "user" <> showDefault <> help "来源标签：exif|ai-high|ai-med|ai-low|user|none"))
            )
  -- P8-C2：--repair 的删除线多了派生件（.pm/derived 里已落位 / 失源 / 半成品三态）；
  -- 帮助文本把三态说全（步 9 minor：此前漏了半成品 .tmp）。
  doctorP =
    CmdDoctor
      <$> ( DoctorOpts
              <$> switch (long "deep" <> help "全量重 hash 索引条目（慢，介质级验证）")
              <*> switch (long "repair" <> help "应用安全闭环：补记 Done / 清自建 tmp / 清 .pm/derived 里已落位、失源、半成品（.tmp）的派生件 / 生成 C5 隔离计划")
          )
      <*> backupSw
      <*> vaultSw
  trashP =
    CmdTrash
      <$> hsubparser
        ( command "list" (info (pure TrashList) (progDesc "manifest ∪ 盘面 并集视图"))
            <> command
              "empty"
              ( info
                  (TrashEmpty <$> switch (long "yes" <> help "确认清除下列条目（无此开关只列清单）"))
                  (progDesc "最终清除隔离区已登记条目（逐项列出；clean-staging 条目须再过三副本屏障）")
              )
        )
      <*> backupSw
      <*> vaultSw
  undoP =
    CmdUndo
      <$> option auto (long "last" <> metavar "N" <> value 1 <> help "撤销最近 N 个已完成操作（默认 1）")
      <*> backupSw
      <*> vaultSw
  applyP =
    fmap CmdApply $
      ApplyOpts
        <$> strArgument (metavar "PLAN-ID")
        <*> optional (strOption (long "only" <> metavar "1,3-5" <> help "只执行这些序号（自动扩到复合组）"))
        <*> switch (long "dry" <> help "只打印计划不执行")
  resolveP =
    fmap CmdResolve $
      ResolveOpts
        <$> strArgument (metavar "PLAN-ID")
        <*> option auto (long "item" <> metavar "N" <> help "条目序号（复合组条目自动扩到全组）")
        <*> flag True False (long "unskip" <> help "恢复为待执行（默认动作是跳过该项）")
        <*> optional
          ( strOption
              ( long "keep"
                  <> metavar "src|dst|both"
                  <> help "NEEDS-DECISION 冲突裁决：src=以源替换（旧目标先隔离）；dst=保留目标跳过；both=源另起版本名并存"
              )
          )
