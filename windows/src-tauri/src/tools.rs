//! Phone-driven PC tools: macros, health dashboard, per-app control, file operations, open link, find my PC,
//! and the eco-mode schedule. Everything needs "Allow iPhone to control this PC" (remote_control), like the other control routes.
use crate::control::{self, Cmd};
use crate::state::Shared;
use axum::{extract::State, http::StatusCode, response::{IntoResponse, Response}, Json};
use once_cell::sync::Lazy;
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::path::PathBuf;

fn err(code: StatusCode, msg: &str) -> Response {
    (code, Json(json!({ "error": msg }))).into_response()
}

fn allowed(app: &Shared) -> bool {
    app.cfg.read().remote_control
}

const OFF: &str = "Remote control is turned off on the PC.";

/// Runs a PowerShell script (from a temp file) hidden and returns its output. Windows only.
fn ps(script: &str) -> String {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        static LOCK: Lazy<Mutex<()>> = Lazy::new(|| Mutex::new(()));
        let _g = LOCK.lock();
        let path = crate::config::data_dir().join("tool.ps1");
        if std::fs::write(&path, script).is_err() { return String::new(); }
        return std::process::Command::new("powershell")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&path)
            .creation_flags(0x0800_0000)
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
            .unwrap_or_default();
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = script;
        String::new()
    }
}

fn q(s: &str) -> String {
    s.replace('\'', "''")
}

// ---------------------------------------------------------------- macros

fn macros_file() -> PathBuf {
    crate::config::data_dir().join("macros.json")
}

pub async fn macros_get() -> Json<Value> {
    let v = std::fs::read(macros_file()).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).unwrap_or_else(|| json!([]));
    Json(v)
}

/// Replace the whole list: [{id, name, icon, steps:[{kind, value}]}]
pub async fn macros_set(State(app): State<Shared>, Json(b): Json<Value>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let Some(list) = b.as_array().filter(|a| a.len() <= 100) else { return err(StatusCode::BAD_REQUEST, "a list of macros") };
    let _ = std::fs::write(macros_file(), Value::Array(list.clone()).to_string());
    Json(json!({ "ok": true })).into_response()
}

/// Steps: keys ("ctrl+shift+m"), text, open (http(s) link, file or program), wait (ms), eco ("on"/"off"), lock, sleep.
pub async fn macros_run(State(app): State<Shared>, Json(b): Json<Value>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let id = b["id"].as_str().unwrap_or("").to_string();
    let list = macros_get().await.0;
    let Some(m) = list.as_array().and_then(|a| a.iter().find(|m| m["id"] == id.as_str())).cloned() else { return err(StatusCode::NOT_FOUND, "no such macro") };
    std::thread::spawn(move || {
        for s in m["steps"].as_array().cloned().unwrap_or_default() {
            let v = s["value"].as_str().unwrap_or("").to_string();
            match s["kind"].as_str().unwrap_or("") {
                "keys" => control::send(Cmd::Key { key: v }),
                "text" => control::send(Cmd::Text { text: v }),
                "open" => open(&v),
                "wait" => std::thread::sleep(std::time::Duration::from_millis(v.parse::<u64>().unwrap_or(500).min(10_000))),
                "eco" => crate::eco::set(&app, v != "off"),
                "lock" => control::send(Cmd::Power { action: "lock".into() }),
                "sleep" => control::send(Cmd::Power { action: "sleep".into() }),
                _ => {}
            }
            std::thread::sleep(std::time::Duration::from_millis(120));
        }
    });
    Json(json!({ "ok": true })).into_response()
}

/// Open an http(s) link, or an existing file / program, with Windows' default handler.
fn open(target: &str) {
    let ok = target.starts_with("http://") || target.starts_with("https://") || std::path::Path::new(target).exists();
    if ok { ps(&format!("Start-Process '{}'", q(target))); }
}

pub async fn open_link(State(app): State<Shared>, Json(b): Json<Value>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let url = b["url"].as_str().unwrap_or("").trim().to_string();
    if !(url.starts_with("http://") || url.starts_with("https://")) { return err(StatusCode::BAD_REQUEST, "only http(s) links"); }
    std::thread::spawn(move || open(&url));
    Json(json!({ "ok": true })).into_response()
}

// ---------------------------------------------------------------- find my PC

pub async fn find_pc(State(app): State<Shared>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    app.notify("Find my PC", "Your iPhone is looking for this PC");
    std::thread::spawn(|| { ps("1..6 | ForEach-Object { [console]::beep(1100, 350); Start-Sleep -Milliseconds 150 }"); });
    Json(json!({ "ok": true })).into_response()
}

// ---------------------------------------------------------------- health

#[cfg(target_os = "windows")]
fn cpu_percent() -> f64 {
    use windows::Win32::{Foundation::FILETIME, System::Threading::GetSystemTimes};
    static LAST: Lazy<Mutex<Option<(u64, u64)>>> = Lazy::new(|| Mutex::new(None));
    let (mut i, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default());
    if unsafe { GetSystemTimes(Some(&mut i), Some(&mut k), Some(&mut u)) }.is_err() { return 0.0; }
    let t = |f: FILETIME| ((f.dwHighDateTime as u64) << 32) | f.dwLowDateTime as u64;
    let (idle, total) = (t(i), t(k) + t(u)); // kernel time already includes idle time
    let mut last = LAST.lock();
    let pct = match *last {
        Some((li, lt)) if total > lt => 100.0 * (1.0 - (idle - li) as f64 / (total - lt) as f64),
        _ => 0.0,
    };
    *last = Some((idle, total));
    pct.clamp(0.0, 100.0)
}
#[cfg(not(target_os = "windows"))]
fn cpu_percent() -> f64 { 0.0 }

/// (total GB, used GB)
#[cfg(target_os = "windows")]
fn memory() -> (f64, f64) {
    use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    let mut m = MEMORYSTATUSEX { dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32, ..Default::default() };
    if unsafe { GlobalMemoryStatusEx(&mut m) }.is_err() { return (0.0, 0.0); }
    let gb = |b: u64| b as f64 / 1_073_741_824.0;
    (gb(m.ullTotalPhys), gb(m.ullTotalPhys - m.ullAvailPhys))
}
#[cfg(not(target_os = "windows"))]
fn memory() -> (f64, f64) { (0.0, 0.0) }

/// NVIDIA card via nvidia-smi (ships with the driver): name, load %, temp C, watts, VRAM used / total MB, fan %.
fn gpu() -> Option<Value> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let out = std::process::Command::new("nvidia-smi")
            .args(["--query-gpu=name,utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total,fan.speed", "--format=csv,noheader,nounits"])
            .creation_flags(0x0800_0000)
            .output()
            .ok()?;
        let s = String::from_utf8_lossy(&out.stdout).to_string();
        let f: Vec<&str> = s.lines().next()?.split(',').map(|x| x.trim()).collect();
        let n = |i: usize| f.get(i).and_then(|x| x.parse::<f64>().ok());
        return Some(json!({ "name": f.first()?, "load": n(1), "temp": n(2), "watts": n(3), "vramUsed": n(4), "vramTotal": n(5), "fan": n(6) }));
    }
    #[cfg(not(target_os = "windows"))]
    None
}

static HEALTH: Lazy<Mutex<(std::time::Instant, Value)>> = Lazy::new(|| Mutex::new((std::time::Instant::now().checked_sub(std::time::Duration::from_secs(60)).unwrap_or_else(std::time::Instant::now), json!({}))));

pub async fn health(State(app): State<Shared>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let v = tokio::task::spawn_blocking(|| {
        let mut c = HEALTH.lock();
        if c.0.elapsed() < std::time::Duration::from_millis(1500) { return c.1.clone(); } // several viewers share one reading
        let cpu = cpu_percent();
        let (total, used) = memory();
        let g = gpu();
        // rough wall-power estimate: board/fans/drives ~45 W + CPU ~20-150 W by load + the GPU's own reading
        let watts = 45.0 + 20.0 + cpu * 1.05 + g.as_ref().and_then(|g| g["watts"].as_f64()).unwrap_or(15.0);
        let v = json!({ "cpu": cpu, "ramTotal": total, "ramUsed": used, "gpu": g, "watts": watts, "eco": crate::eco::ON.load(std::sync::atomic::Ordering::SeqCst) });
        *c = (std::time::Instant::now(), v.clone());
        v
    })
    .await
    .unwrap_or_else(|_| json!({}));
    Json(v).into_response()
}

// ---------------------------------------------------------------- apps

const NATIVE: &str = r#"
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class N {
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(int a, bool i, int pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@
"#;

/// Programs with a window, biggest memory first.
pub async fn apps_list(State(app): State<Shared>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let out = tokio::task::spawn_blocking(|| ps(r#"
$sid = (Get-Process -Id $PID).SessionId
$r = @(Get-Process | Where-Object { $_.SessionId -eq $sid -and $_.MainWindowTitle } | Group-Object ProcessName | ForEach-Object {
  [pscustomobject]@{ name = $_.Name; count = $_.Count; mb = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB); title = ($_.Group | Where-Object MainWindowTitle | Select-Object -First 1).MainWindowTitle }
} | Sort-Object mb -Descending | Select-Object -First 40)
ConvertTo-Json -InputObject $r -Compress
"#)).await.unwrap_or_default();
    Json(serde_json::from_str::<Value>(out.trim()).unwrap_or_else(|_| json!([]))).into_response()
}

/// {name, action: suspend | resume | close}
pub async fn apps_act(State(app): State<Shared>, Json(b): Json<Value>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let name = b["name"].as_str().unwrap_or("").to_string();
    let action = b["action"].as_str().unwrap_or("").to_string();
    let safe = !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || " ._-".contains(c));
    if !safe || ["mediagrid", "explorer", "tailscale", "tailscale-ipn", "powershell"].contains(&name.to_lowercase().as_str()) {
        return err(StatusCode::BAD_REQUEST, "that program can't be controlled from here");
    }
    let body = match action.as_str() {
        "suspend" => "$f = { param($h) [void][N]::NtSuspendProcess($h) }",
        "resume" => "$f = { param($h) [void][N]::NtResumeProcess($h) }",
        "close" => "$f = $null",
        _ => return err(StatusCode::BAD_REQUEST, "suspend, resume or close"),
    };
    let script = format!(
        "{NATIVE}\n$sid = (Get-Process -Id $PID).SessionId\n{body}\nforeach ($p in Get-Process -Name '{n}' -ErrorAction SilentlyContinue) {{\n  if ($p.SessionId -ne $sid) {{ continue }}\n  if ($f) {{ $h = [N]::OpenProcess(0x800, $false, $p.Id); if ($h -ne [IntPtr]::Zero) {{ & $f $h; [void][N]::CloseHandle($h) }} }}\n  else {{ [void]$p.CloseMainWindow() }}\n}}",
        n = q(&name)
    );
    let _ = tokio::task::spawn_blocking(move || ps(&script)).await; // close = polite window close, so programs can ask to save
    Json(json!({ "ok": true })).into_response()
}

// ---------------------------------------------------------------- file operations

/// {op: rename | mkdir | delete (recycle bin) | move, path, name | to}
pub async fn files_op(State(app): State<Shared>, Json(b): Json<Value>) -> Response {
    if !allowed(&app) { return err(StatusCode::FORBIDDEN, OFF); }
    let path = PathBuf::from(b["path"].as_str().unwrap_or(""));
    let name = b["name"].as_str().unwrap_or("").to_string();
    let clean = |n: &str| !n.is_empty() && !n.contains(['/', '\\', ':', '*', '?', '"', '<', '>', '|']) && n != "." && n != "..";
    let res: Result<(), String> = match b["op"].as_str().unwrap_or("") {
        "rename" if clean(&name) && path.exists() => std::fs::rename(&path, path.with_file_name(&name)).map_err(|e| e.to_string()),
        "mkdir" if clean(&name) && path.is_dir() => std::fs::create_dir(path.join(&name)).map_err(|e| e.to_string()),
        "move" if path.exists() => {
            let to = PathBuf::from(b["to"].as_str().unwrap_or(""));
            match (to.is_dir(), path.file_name()) {
                (true, Some(f)) => std::fs::rename(&path, to.join(f)).map_err(|e| e.to_string()),
                _ => Err("destination folder not found".into()),
            }
        }
        "delete" if path.exists() => {
            let p = path.to_string_lossy().to_string();
            let call = if path.is_dir() { "DeleteDirectory" } else { "DeleteFile" };
            let script = format!(
                "Add-Type -AssemblyName Microsoft.VisualBasic\n[Microsoft.VisualBasic.FileIO.FileSystem]::{call}('{}', 'OnlyErrorDialogs', 'SendToRecycleBin')",
                q(&p)
            );
            let _ = tokio::task::spawn_blocking(move || ps(&script)).await; // to the recycle bin, never a hard delete
            Ok(())
        }
        _ => Err("bad request".into()),
    };
    match res {
        Ok(()) => Json(json!({ "ok": true })).into_response(),
        Err(e) => err(StatusCode::BAD_REQUEST, &e),
    }
}

// ---------------------------------------------------------------- eco schedule

fn in_window(now: &str, from: &str, to: &str) -> bool {
    if from <= to { now >= from && now < to } else { now >= from || now < to } // crosses midnight
}

/// Turns eco mode on at `eco_from` and off at `eco_to` (HH:MM, local time). Acts on transitions only, so a manual
/// switch stays until the next boundary.
pub async fn schedule_loop(app: Shared) {
    let mut last: Option<bool> = None;
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(20)).await;
        let (on, from, to) = {
            let c = app.cfg.read();
            (c.eco_schedule, c.eco_from.clone(), c.eco_to.clone())
        };
        if !on { last = None; continue; }
        let inside = in_window(&chrono::Local::now().format("%H:%M").to_string(), &from, &to);
        if last != Some(inside) {
            if last.is_some() { crate::eco::set(&app, inside); }
            last = Some(inside);
        }
    }
}
