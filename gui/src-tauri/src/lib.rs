//! pm-ui — Tauri v2 desktop shell for `pm` (DESIGN §11).
//!
//! Boundary (invariant-level): this process never touches photo files. The
//! only thing the Rust side does is (1) spawn `pm serve`, (2) hand the
//! announced `{port, token}` to the webview, (3) kill the child on exit.
//! Every read of library state goes over the loopback JSON API from JS.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use serde::Serialize;
use tauri::{Manager, RunEvent};

#[derive(Clone, Serialize)]
struct ApiInfo {
    port: u16,
    token: String,
}

struct ServeChild(Mutex<Option<Child>>);

#[tauri::command]
fn api_info(info: tauri::State<ApiInfo>) -> ApiInfo {
    info.inner().clone()
}

/// Locate `pm`: `PM_EXE` wins (what `pm ui` sets to its own path), otherwise
/// `pm` on PATH.
fn pm_exe() -> String {
    std::env::var("PM_EXE").unwrap_or_else(|_| "pm".to_string())
}

fn spawn_serve() -> Result<(ApiInfo, Child), String> {
    let exe = pm_exe();
    let mut cmd = Command::new(&exe);
    // `--exit-on-stdin-eof` + a piped stdin we never write to: if this
    // process dies for any reason (crash, taskkill without /T), Windows
    // closes the pipe and serve exits on EOF — no orphan listener. The pipe
    // handle lives inside `Child` (we never take `child.stdin`), so it stays
    // open exactly as long as we keep the Child.
    cmd.arg("serve")
        .arg("--exit-on-stdin-eof")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // CREATE_NO_WINDOW: the release GUI has no console; don't flash one.
        cmd.creation_flags(0x0800_0000);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| format!("无法启动 `{exe} serve`：{e}（设 PM_EXE 指向 pm.exe，或把 pm 放进 PATH）"))?;
    let stdout = child.stdout.take().ok_or("serve 没有 stdout")?;
    let mut line = String::new();
    BufReader::new(stdout)
        .read_line(&mut line)
        .map_err(|e| format!("读 serve announce 失败：{e}"))?;
    let v: serde_json::Value = serde_json::from_str(line.trim())
        .map_err(|e| format!("serve announce 不是 JSON：{e}：{line}"))?;
    let port = v["port"].as_u64().ok_or("announce 缺 port")? as u16;
    let token = v["token"].as_str().ok_or("announce 缺 token")?.to_string();
    Ok((ApiInfo { port, token }, child))
}

fn kill_serve(app: &tauri::AppHandle) {
    if let Some(mut c) = app.state::<ServeChild>().0.lock().unwrap().take() {
        let _ = c.kill();
        let _ = c.wait();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let (info, child) = match spawn_serve() {
        Ok(x) => x,
        Err(e) => {
            eprintln!("pm-ui: {e}");
            std::process::exit(2);
        }
    };
    tauri::Builder::default()
        .manage(info)
        .manage(ServeChild(Mutex::new(Some(child))))
        .invoke_handler(tauri::generate_handler![api_info])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                kill_serve(app);
            }
        });
}
