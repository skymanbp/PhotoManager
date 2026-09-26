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

/// Locate `pm`, in order: `PM_EXE` (what `pm ui` sets to its own path) → a
/// `pm.exe` sitting next to this executable → `pm` on PATH.
///
/// The installer ships the CLI as a Tauri sidecar, i.e. right next to
/// `pm-ui.exe`, and a Start-menu launch has neither `PM_EXE` nor (usually) the
/// install dir on `PATH` — so the sibling lookup is what makes the packaged
/// build work at all. Both the bundled name and the raw sidecar name are
/// tried, so it does not matter whether the bundler stripped the triple.
fn pm_exe() -> String {
    if let Ok(p) = std::env::var("PM_EXE") {
        return p;
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for cand in ["pm.exe", "pm-x86_64-pc-windows-msvc.exe"] {
                let p = dir.join(cand);
                if p.is_file() {
                    return p.to_string_lossy().into_owned();
                }
            }
        }
    }
    "pm".to_string()
}

fn spawn_serve() -> Result<(ApiInfo, Child), String> {
    let exe = pm_exe();
    let mut cmd = Command::new(&exe);
    // `--exit-on-stdin-eof` + a piped stdin we never write to: if this
    // process dies for any reason (crash, taskkill without /T), Windows
    // closes the pipe and serve exits on EOF — no orphan listener. The pipe
    // handle lives inside `Child` (we never take `child.stdin`), so it stays
    // open exactly as long as we keep the Child.
    // `--writable` + `--allow-apply` (P7, user ruling 2026-08-26): the GUI
    // both GENERATES plans (writes only .pm/plans and pm's own state) and may
    // EXECUTE a stored plan from the plans page — POST /api/apply is the one
    // endpoint that moves photo bytes, the page gates it behind a two-click
    // confirm, and execution itself runs inside `pm serve` with the same
    // prepare/barrier/journal chain as CLI `pm apply`. This process still
    // never touches photo files itself, and git stays generate-only (I9).
    cmd.arg("serve")
        .arg("--exit-on-stdin-eof")
        .arg("--writable")
        .arg("--allow-apply")
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

/// Audit #15: the packaged build is `windows_subsystem = "windows"`, so a
/// Start-menu launch has no console and anything on stderr goes nowhere —
/// when `pm serve` could not start (no config yet, loopback bind refused) or
/// the window could not be built, the app used to vanish without a word.
/// Every fatal exit of `run()` goes through here: stderr for a terminal
/// launch via `pm ui`, a system message box for everyone else, then exit 2
/// (pm's "error" code, which `pm ui` passes through; a panic's 101 was outside
/// that contract). `pm serve` prints its own error as the first stdout line,
/// which the "not JSON" error from `spawn_serve` carries verbatim.
fn fatal(msg: &str) -> ! {
    eprintln!("pm-ui: {msg}");
    show_error(&format!("pm-ui 没能启动：{msg}"));
    std::process::exit(2);
}

#[cfg(windows)]
fn show_error(msg: &str) {
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(hwnd: *mut core::ffi::c_void, text: *const u16, caption: *const u16, kind: u32) -> i32;
    }
    let wide = |s: &str| s.encode_utf16().chain(std::iter::once(0)).collect::<Vec<u16>>();
    let (text, caption) = (wide(msg), wide("pm-ui"));
    // SAFETY: both buffers are NUL-terminated UTF-16 that outlive the call;
    // a null owner window is allowed. 0x10 = MB_OK | MB_ICONERROR.
    unsafe {
        MessageBoxW(std::ptr::null_mut(), text.as_ptr(), caption.as_ptr(), 0x10);
    }
}

#[cfg(not(windows))]
fn show_error(_msg: &str) {}

fn kill_serve(app: &tauri::AppHandle) {
    if let Some(mut c) = app.state::<ServeChild>().0.lock().unwrap().take() {
        let _ = c.kill();
        let _ = c.wait();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let (info, child) = spawn_serve().unwrap_or_else(|e| fatal(&e));
    tauri::Builder::default()
        .manage(info)
        .manage(ServeChild(Mutex::new(Some(child))))
        .invoke_handler(tauri::generate_handler![api_info])
        .build(tauri::generate_context!())
        .unwrap_or_else(|e| fatal(&format!("窗口建不起来：{e}")))
        .run(|app, event| {
            if let RunEvent::Exit = event {
                kill_serve(app);
            }
        });
}
