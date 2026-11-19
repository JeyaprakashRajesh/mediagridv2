mod clip;
mod config;
mod control;
mod genre;
mod lyrics;
mod library;
mod popularity;
mod server;
mod state;
mod vcam;

use serde_json::{json, Value};
use state::{App, Shared};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, State, WindowEvent,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

fn addresses() -> Vec<Value> {
    let mut out = vec![];
    if let Ok(list) = local_ip_address::list_afinet_netifas() {
        for (iface, ip) in list {
            let std::net::IpAddr::V4(v4) = ip else { continue };
            if v4.is_loopback() || v4.is_link_local() { continue; }
            let o = v4.octets();
            let tailscale = (o[0] == 100 && (64..128).contains(&o[1])) || iface.to_lowercase().contains("tailscale");
            out.push(json!({ "ip": v4.to_string(), "iface": iface, "kind": if tailscale { "tailscale" } else { "lan" } }));
        }
    }
    out.sort_by_key(|v| if v["kind"] == "tailscale" { 0 } else { 1 });
    out
}

/// Drag & drop onto the window: offer the files to the phone.
#[tauri::command]
fn send_files(app: State<Shared>, paths: Vec<String>) {
    for p in paths {
        let p = std::path::PathBuf::from(p);
        if p.is_file() { app.share_file(&p); }
    }
}

/// Files passed on the command line (Explorer's "Send to" menu) go to the phone too.
fn share_args(app: &Shared, args: &[String]) {
    for a in args.iter().skip(1) {
        let p = std::path::Path::new(a);
        if p.is_file() { app.share_file(p); }
    }
}

/// Adds "MediaGrid (send to iPhone)" to Explorer's right-click > Send to menu.
#[cfg(target_os = "windows")]
fn install_sendto() {
    let (Some(roaming), Ok(exe)) = (dirs::config_dir(), std::env::current_exe()) else { return };
    let dir = roaming.join("Microsoft").join("Windows").join("SendTo");
    let _ = std::fs::write(dir.join("MediaGrid (send to iPhone).cmd"), format!("@echo off\r\nstart \"\" \"{}\" %*\r\n", exe.display()));
}
#[cfg(not(target_os = "windows"))]
fn install_sendto() {}

#[tauri::command]
fn get_info(app: State<Shared>) -> Value {
    let c = app.cfg.read();
    let l = app.lib.read();
    json!({
        "uiToken": app.ui_token,
        "port": c.port,
        "name": c.device_name,
        "email": c.email,
        "hasAccount": c.has_account(),
        "addresses": addresses(),
        "musicDirs": c.music_dirs,
        "mediaDirs": c.media_dirs,
        "photoSyncDir": c.photo_sync_dir,
        "inboxDir": c.inbox_dir,
        "clipboardSync": c.clipboard_sync,
        "remoteControl": c.remote_control,
        "autoPhotoSync": c.auto_photo_sync,
        "autostart": c.autostart,
        "acceptPhoneStream": c.accept_phone_stream,
        "sharePcAudio": c.share_pc_audio,
        "tracks": l.tracks.len(),
        "media": l.media.len(),
        "photos": l.media.iter().filter(|m| m.kind == "photo").count(),
        "videos": l.media.iter().filter(|m| m.kind == "video").count(),
        "scanning": l.scanning,
        "syncedPhotos": app.synced.lock().len(),
        "serverError": app.server_error.lock().clone(),
        "version": env!("CARGO_PKG_VERSION"),
    })
}

#[tauri::command]
fn save_settings(app: State<Shared>, handle: tauri::AppHandle, s: Value) -> Result<(), String> {
    let dirs_changed;
    let autostart;
    {
        let mut c = app.cfg.write();
        let strs = |v: &Value| -> Vec<String> {
            v.as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(|s| s.trim().to_string())).filter(|s| !s.is_empty()).collect()).unwrap_or_default()
        };
        let old = (c.music_dirs.clone(), c.media_dirs.clone(), c.photo_sync_dir.clone());
        if let Some(v) = s.get("musicDirs") { c.music_dirs = strs(v); }
        if let Some(v) = s.get("mediaDirs") { c.media_dirs = strs(v); }
        if let Some(v) = s["photoSyncDir"].as_str() { if !v.trim().is_empty() { c.photo_sync_dir = v.trim().into(); } }
        if let Some(v) = s["inboxDir"].as_str() { if !v.trim().is_empty() { c.inbox_dir = v.trim().into(); } }
        if let Some(v) = s["clipboardSync"].as_bool() { c.clipboard_sync = v; }
        if let Some(v) = s["remoteControl"].as_bool() { c.remote_control = v; }
        if let Some(v) = s["autoPhotoSync"].as_bool() { c.auto_photo_sync = v; }
        if let Some(v) = s["autostart"].as_bool() { c.autostart = v; }
        if let Some(v) = s["acceptPhoneStream"].as_bool() { c.accept_phone_stream = v; }
        if let Some(v) = s["sharePcAudio"].as_bool() { c.share_pc_audio = v; }
        if let Some(v) = s["name"].as_str() { if !v.trim().is_empty() { c.device_name = v.trim().into(); } }
        dirs_changed = old != (c.music_dirs.clone(), c.media_dirs.clone(), c.photo_sync_dir.clone());
        autostart = c.autostart;
        c.save();
    }
    let al = handle.autolaunch();
    let _ = if autostart { al.enable() } else { al.disable() };
    if dirs_changed {
        app.rescan();
        app.watch_folders();
    }
    app.push(json!({ "event": "settings" }));
    Ok(())
}

#[tauri::command]
fn set_account(app: State<Shared>, email: String, password: String) -> Result<(), String> {
    if !email.contains('@') { return Err("Enter a valid email address.".into()); }
    if password.len() < 6 { return Err("Password must be at least 6 characters.".into()); }
    let mut c = app.cfg.write();
    c.set_password(&email, &password);
    c.save();
    drop(c);
    app.push(json!({ "event": "signedout" }));
    app.devices.write().clear();
    Ok(())
}

#[tauri::command]
fn revoke_device(app: State<Shared>, prefix: String) {
    let mut c = app.cfg.write();
    c.tokens.retain(|t, _| !t.starts_with(&prefix));
    c.save();
    drop(c);
    app.devices.write().retain(|t, _| !t.starts_with(&prefix));
    app.ui("devices", json!({}));
}

/// Adds an inbound Windows Firewall rule for MediaGrid (shows a UAC prompt).
#[tauri::command]
fn allow_firewall() -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let exe = exe.to_string_lossy().replace('\'', "''");
        let args = format!(
            "advfirewall firewall add rule name=MediaGrid dir=in action=allow program=\"{exe}\" enable=yes profile=any"
        );
        let ps = format!("Start-Process netsh -Verb RunAs -WindowStyle Hidden -ArgumentList '{}'", args.replace('\'', "''"));
        std::process::Command::new("powershell")
            .args(["-NoProfile", "-Command", &ps])
            .creation_flags(0x0800_0000)
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn rescan(app: State<Shared>) {
    app.rescan();
}

#[tauri::command]
fn reveal(path: String) {
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("explorer").arg(format!("/select,{path}")).spawn();
    }
    #[cfg(not(target_os = "windows"))]
    let _ = path;
}

#[tauri::command]
fn open_folder(path: String) {
    #[cfg(target_os = "windows")]
    {
        let _ = std::fs::create_dir_all(&path);
        let _ = std::process::Command::new("explorer").arg(path).spawn();
    }
    #[cfg(not(target_os = "windows"))]
    let _ = path;
}

fn show_main(app: &tauri::AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let shared = App::new();
    let minimized = std::env::args().any(|a| a == "--minimized");

    // Server-only mode (no window/tray): `MediaGrid.exe --headless` or MEDIAGRID_HEADLESS=1.
    if std::env::args().any(|a| a == "--headless") || std::env::var_os("MEDIAGRID_HEADLESS").is_some() {
        let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
        rt.block_on(async move {
            shared.rescan();
            shared.watch_folders();
            clip::watch(shared.clone());
            server::run(shared).await;
        });
        return;
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            share_args(app.state::<Shared>().inner(), &args);
            show_main(app)
        }))
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec!["--minimized"])))
        .manage(shared.clone())
        .invoke_handler(tauri::generate_handler![get_info, save_settings, set_account, revoke_device, rescan, reveal, open_folder, allow_firewall, send_files])
        .setup(move |app| {
            let _ = shared.handle.set(app.handle().clone());
            install_sendto();
            share_args(&shared, &std::env::args().collect::<Vec<_>>());

            if shared.cfg.read().autostart {
                let _ = app.autolaunch().enable();
            }

            // tray
            let open = MenuItem::with_id(app, "open", "Open MediaGrid", true, None::<&str>)?;
            let rescan = MenuItem::with_id(app, "rescan", "Rescan library", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Quit MediaGrid", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &rescan, &quit])?;
            let s2 = shared.clone();
            TrayIconBuilder::with_id("tray")
                .icon(app.default_window_icon().unwrap().clone())
                .tooltip("MediaGrid — running")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(move |app, e| match e.id.as_ref() {
                    "open" => show_main(app),
                    "rescan" => s2.rescan(),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, e| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                        show_main(tray.app_handle());
                    }
                })
                .build(app)?;

            // background services
            let s3 = shared.clone();
            tauri::async_runtime::spawn(async move { server::run(s3).await });
            clip::watch(shared.clone());
            shared.rescan();
            shared.watch_folders();

            if !minimized {
                show_main(app.handle());
            }
            Ok(())
        })
        .on_window_event(|w, e| {
            // closing the window keeps MediaGrid running in the tray
            if let WindowEvent::CloseRequested { api, .. } = e {
                api.prevent_close();
                let _ = w.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running MediaGrid");
}
