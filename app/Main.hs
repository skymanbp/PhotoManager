{-# LANGUAGE OverloadedStrings #-}

-- | Thin CLI shell: option parsing + dispatch only. All orchestration lives
-- in Pm.Commands / Pm.Cli (库层，P4 的 serve/GUI 复用同一路径).
module Main (main) where

import Options.Applicative
import System.Exit (exitSuccess, exitWith, ExitCode (..))

import Pm.Cli (GoOpts (..), savePlanAndMaybeRun)
import Pm.Commands
import Pm.Doctor (DoctorOpts (..), renderFinding, runDoctor)
import Pm.Names (runNames)
import Pm.Serve (ServeOpts (..), runServe)
import Pm.Status (StatusOpts (..), runStatus)
import Pm.Ui (runUi)
import Pm.Vault (runVaultPush, runVaultStatus)
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
  | CmdImport GoOpts
  | CmdBackup BackupCmd
  | CmdClean GoOpts -- clean staging
  | CmdVaultStatus Bool -- --json（sync_photos.py 兼容输出）
  | CmdVaultPush GoOpts (Maybe String) [FilePath] -- --category + FILES
  | CmdNames GoOpts -- Raw 事件夹 Scheme A 统一
  | CmdVersions -- 版本组/精确重复报告（只读）
  | CmdServe ServeOpts -- 127.0.0.1 JSON API（缺省只读；--writable 才开生成计划端点）
  | CmdUi -- 拉起 Tauri 桌面 GUI（P4-3；GUI 自己跑 serve）

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
run (CmdImport go) = withCfg (runImport go)
run (CmdBackup (BackupInit p)) = withCfg (runBackupInit p)
run (CmdBackup (BackupRun go mworkers)) = withCfg (runBackupRun go mworkers)
run (CmdClean go) = withCfg (runClean go)
run (CmdVaultStatus asJson) = withCfg (runVaultStatus asJson)
run (CmdVaultPush go mcat fs) = withCfg (runVaultPush (savePlanAndMaybeRun go) mcat fs)
run (CmdNames go) = withCfg (runNames (savePlanAndMaybeRun go))
run CmdVersions = withCfg runVersions
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
    infoOption "pm 0.4.3 (P4-6)" (long "version" <> help "打印版本")
  backupSw = switch (long "backup" <> help "作用于备份 root（需插盘）")
  vaultSw = switch (long "vault" <> help "作用于 vault root（首次 pm vault push 时建立）")
  commands =
    hsubparser
      ( command "init" (info initP (progDesc "生成配置 + 主库 root 标识"))
          <> command "scan" (info scanP (progDesc "索引主库（增量；首次全量 hash）"))
          <> command "status" (info statusP (progDesc "总览仪表盘（默认命令）"))
          <> command "import" (info importP (progDesc "暂存区 To-Be-Sync'd → Raw/成片 归档计划"))
          <> command "backup" (info backupP (progDesc "主库 → 备份盘单向增量（init 登记备份盘）"))
          <> command "clean" (info cleanP (progDesc "clean staging: 三副本确认后的暂存清理计划"))
          <> command "vault" (info vaultP (progDesc "相册 ↔ vault 展示集（status 兼容 sync_photos.py）"))
          <> command "names" (info (CmdNames <$> goOpts) (progDesc "Raw 事件夹统一 Scheme A（YY-MM-地点-Raw；目录改名走 §6.2 协议，undo 可回滚）"))
          <> command "versions" (info (pure CmdVersions) (progDesc "版本组/精确重复报告（只读；版本后缀不强制统一）"))
          <> command "doctor" (info doctorP (progDesc "崩溃恢复对账 + 完整性体检（默认只读）"))
          <> command "trash" (info trashP (progDesc "隔离区：list / empty（唯一最终清除入口）"))
          <> command "undo" (info undoP (progDesc "由主库 journal 生成反向计划（经 pm apply 执行）"))
          <> command "apply" (info applyP (progDesc "执行已存的计划（root 按 UUID 重新绑定；--only 按组闭包）"))
          <> command "resolve" (info resolveP (progDesc "裁决计划某项：跳过/恢复/--keep src|dst|both（组为单元）"))
          <> command "serve" (info serveP (progDesc "127.0.0.1 JSON API（供 GUI/skill；随机端口 + 会话 token，启动时打印一行 JSON；缺省只读，见 --writable）"))
          <> command "ui" (info (pure CmdUi) (progDesc "拉起桌面 GUI（pm-ui.exe：PM_UI_EXE 或 pm.exe 同目录；GUI 自己启动并管理 pm serve）"))
      )
  serveP =
    fmap CmdServe $
      ServeOpts
        <$> optional (option auto (long "port" <> metavar "N" <> help "固定端口（默认由内核随机分配）"))
        <*> switch (long "exit-on-stdin-eof" <> help "stdin 关闭即退出（GUI 拉起时用：父进程一死 serve 随之结束，不留孤儿）")
        <*> switch (long "writable" <> help "允许 POST 端点生成计划（写域限 vault 的 .pm：plans + 首次的 root-id；不执行、不碰照片）；缺省只读")
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
  importP = CmdImport <$> goOpts
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
              (CmdVaultStatus <$> switch (long "json" <> help "sync_photos.py 兼容的 JSON 输出（六键值形状逐字段一致 + unpushable）"))
              (progDesc "相册 ↔ vault 六态差异（只读；退出码 0/1/2 同 sync_photos.py）")
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
      )
  doctorP =
    CmdDoctor
      <$> ( DoctorOpts
              <$> switch (long "deep" <> help "全量重 hash 索引条目（慢，介质级验证）")
              <*> switch (long "repair" <> help "应用安全闭环：补记 Done / 清自建 tmp / 生成 C5 隔离计划")
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
