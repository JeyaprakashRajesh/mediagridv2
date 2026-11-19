use crate::config::{self, Config};
use crate::library::Library;
use once_cell::sync::OnceCell;
use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};
use tokio::sync::broadcast;

#[derive(Clone, Serialize, Deserialize, Default)]
pub struct Device {
    pub name: String,
    pub model: String,
    pub battery: f64,
    pub charging: bool,
    pub now_playing: Option<serde_json::Value>,
    pub connected: bool,
    pub last_seen: i64,
    pub address: String,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct SharedItem {
    pub id: String,
    pub kind: String, // "text" | "file" | "clipboard"
    pub text: Option<String>,
    pub name: Option<String>,
    pub size: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub from: String, // "pc" | device name
    pub at: i64,
}

pub struct App {
    pub cfg: RwLock<Config>,
    pub lib: RwLock<Library>,
    pub events: broadcast::Sender<String>,
    pub devices: RwLock<HashMap<String, Device>>,
    pub shared: RwLock<Vec<SharedItem>>,
    /// {"recent":[{id,at,pos,device}], "now":{id,pos,playing,device,at}} — shared by PC and phones.
    pub playback: RwLock<serde_json::Value>,
    /// Playlists made on any device (JSON array), shared through the PC.
    pub playlists: RwLock<serde_json::Value>,
    /// The phone's current call (or null) and the finished calls, newest first.
    pub call: RwLock<serde_json::Value>,
    pub calls: RwLock<Vec<serde_json::Value>>,
    pub last_clip: Mutex<String>,
    pub synced: Mutex<HashSet<String>>,
    pub ui_token: String,
    pub handle: OnceCell<AppHandle>,
    pub server_error: Mutex<Option<String>>,
    rescan_pending: AtomicBool,
    photo_batch: AtomicU32,
    photo_gen: AtomicU32,
    watcher: Mutex<Option<notify::RecommendedWatcher>>,
}

pub type Shared = Arc<App>;

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

impl App {
    pub fn new() -> Shared {
        let cfg = Config::load();
        cfg.save();
        let (tx, _) = broadcast::channel(256);
        let shared: Vec<SharedItem> = std::fs::read_to_string(config::data_dir().join("shared.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let playback: serde_json::Value = std::fs::read_to_string(config::data_dir().join("playback.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| serde_json::json!({ "recent": [], "now": null }));
        let playlists: serde_json::Value = std::fs::read_to_string(config::data_dir().join("playlists.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_else(|| serde_json::json!([]));
        Arc::new(App {
            cfg: RwLock::new(cfg),
            lib: RwLock::new(Library::default()),
            events: tx,
            devices: RwLock::new(HashMap::new()),
            shared: RwLock::new(shared),
            playback: RwLock::new(playback),
            playlists: RwLock::new(playlists),
            call: RwLock::new(serde_json::Value::Null),
            calls: RwLock::new(Vec::new()),
            last_clip: Mutex::new(String::new()),
            synced: Mutex::new(config::load_synced()),
            ui_token: config::random_hex(16),
            handle: OnceCell::new(),
            server_error: Mutex::new(None),
            rescan_pending: AtomicBool::new(false),
            photo_batch: AtomicU32::new(0),
            photo_gen: AtomicU32::new(0),
            watcher: Mutex::new(None),
        })
    }

    /// Notify the desktop UI.
    pub fn ui(&self, event: &str, payload: serde_json::Value) {
        if let Some(h) = self.handle.get() {
            let _ = h.emit("mg", serde_json::json!({ "event": event, "data": payload }));
        }
    }

    /// Windows toast notification.
    pub fn notify(&self, title: &str, body: &str) {
        if let Some(h) = self.handle.get() {
            use tauri_plugin_notification::NotificationExt;
            let _ = h.notification().builder().title(title).body(body).show();
        }
    }

    /// One toast per burst of photos ("12 photos backed up") instead of one per photo.
    pub fn photo_received(self: &Shared) {
        self.photo_batch.fetch_add(1, Ordering::SeqCst);
        let gen = self.photo_gen.fetch_add(1, Ordering::SeqCst) + 1;
        let me = self.clone();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(5)).await;
            if me.photo_gen.load(Ordering::SeqCst) == gen {
                let n = me.photo_batch.swap(0, Ordering::SeqCst);
                if n > 0 {
                    me.notify("Photos backed up", &format!("{n} new photo{} from your iPhone", if n == 1 { "" } else { "s" }));
                }
            }
        });
    }

    /// Record what a device is playing and move it to the front of "recently played".
    pub fn set_playback(&self, b: &serde_json::Value) -> serde_json::Value {
        let id = b["id"].as_str().unwrap_or("").to_string();
        if id.is_empty() {
            return self.playback.read().clone();
        }
        let pos = b["pos"].as_f64().unwrap_or(0.0);
        let playing = b["playing"].as_bool().unwrap_or(false);
        let device = b["device"].as_str().unwrap_or("").to_string();
        let at = now_ms();
        let v = {
            let mut p = self.playback.write();
            let mut recent: Vec<serde_json::Value> = p["recent"].as_array().cloned().unwrap_or_default();
            recent.retain(|r| r["id"].as_str() != Some(id.as_str()));
            recent.insert(0, serde_json::json!({ "id": id, "at": at, "pos": pos, "device": device }));
            recent.truncate(20);
            *p = serde_json::json!({
                "recent": recent,
                "now": { "id": id, "pos": pos, "playing": playing, "device": device, "at": at }
            });
            p.clone()
        };
        if let Ok(j) = serde_json::to_string(&v) {
            let _ = std::fs::write(config::data_dir().join("playback.json"), j);
        }
        v
    }

    /// Track the phone's call (ringing / dialing / active / ended). Returns the payload for the UI.
    pub fn set_call(&self, b: &serde_json::Value, device: &str) -> serde_json::Value {
        let state = b["state"].as_str().unwrap_or("").to_string();
        let direction = b["direction"].as_str().unwrap_or("incoming").to_string();
        let now = now_ms();
        let mut c = self.call.write();
        match state.as_str() {
            "ringing" | "dialing" => {
                *c = serde_json::json!({ "state": state, "direction": direction, "since": now, "started": null, "device": device });
                c.clone()
            }
            "active" => {
                let since = c["since"].as_i64().unwrap_or(now);
                let dir = c["direction"].as_str().map(|s| s.to_string()).unwrap_or(direction);
                *c = serde_json::json!({ "state": "active", "direction": dir, "since": since, "started": now, "device": device });
                c.clone()
            }
            "ended" => {
                let started = c["started"].as_i64();
                let dir_v = if c.is_null() { serde_json::Value::String(direction) } else { c["direction"].clone() };
                let since_v = if c.is_null() { serde_json::json!(now) } else { c["since"].clone() };
                let secs: i64 = started.map(|s| (now - s) / 1000).unwrap_or(0);
                let payload = serde_json::json!({
                    "state": "ended",
                    "direction": dir_v,
                    "answered": started.is_some(),
                    "since": since_v,
                    "duration": secs,
                    "device": device
                });
                if !c.is_null() {
                    let mut l = self.calls.write();
                    l.insert(0, payload.clone());
                    l.truncate(30);
                }
                *c = serde_json::Value::Null;
                payload
            }
            _ => c.clone(),
        }
    }

    /// Floating "call bubble" window (always on top, draggable) shown while the phone is in a call.
    pub fn call_bubble(&self, show: bool) {
        use tauri::Manager;
        let Some(h) = self.handle.get() else { return };
        if show {
            if h.get_webview_window("callbubble").is_some() {
                return;
            }
            let _ = tauri::WebviewWindowBuilder::new(h, "callbubble", tauri::WebviewUrl::App("call.html".into()))
                .title("MediaGrid call")
                .inner_size(320.0, 80.0)
                .position(24.0, 64.0)
                .decorations(false)
                .transparent(true)
                .always_on_top(true)
                .skip_taskbar(true)
                .resizable(false)
                .shadow(false)
                .focused(false)
                .build();
        } else if let Some(w) = h.get_webview_window("callbubble") {
            let _ = w.close();
        }
    }

    /// Push an event to every connected phone.
    pub fn push(&self, v: serde_json::Value) {
        let _ = self.events.send(v.to_string());
    }

    /// Copy a PC file into the inbox and offer it to the phone (drag & drop, "Send to" menu).
    pub fn share_file(self: &Shared, src: &std::path::Path) {
        let Some(name) = src.file_name().map(|s| s.to_string_lossy().to_string()) else { return };
        let dir = std::path::PathBuf::from(self.cfg.read().inbox_dir.clone());
        let _ = std::fs::create_dir_all(&dir);
        let mut dest = dir.join(&name);
        let mut i = 1;
        while dest.exists() { dest = dir.join(format!("{i}-{name}")); i += 1; }
        if std::fs::copy(src, &dest).is_err() { return; }
        self.add_shared(SharedItem {
            id: config::random_hex(8), kind: "file".into(), text: None,
            name: dest.file_name().map(|s| s.to_string_lossy().to_string()),
            size: std::fs::metadata(&dest).map(|m| m.len()).ok(),
            path: Some(dest.to_string_lossy().to_string()), from: "pc".into(), at: now_ms(),
        });
    }

    pub fn add_shared(&self, item: SharedItem) {
        {
            let mut s = self.shared.write();
            s.insert(0, item.clone());
            s.truncate(300);
            if let Ok(j) = serde_json::to_string(&*s) {
                let _ = std::fs::write(config::data_dir().join("shared.json"), j);
            }
        }
        self.ui("shared", serde_json::to_value(&item).unwrap_or_default());
        self.push(serde_json::json!({ "event": "shared", "item": item }));
    }

    /// Link new songs to their movie and fetch missing posters (background); every song of a movie shares one poster.
    pub fn sync_covers(self: &Shared, force: bool) {
        let t = self.lib.read().tracks.iter().map(|t| (t.id.clone(), t.album.clone())).collect();
        let me = self.clone();
        crate::covers::sync(t, force, move || me.mark_art());
    }

    /// Flag tracks that now have a poster so the phone asks for it.
    pub fn mark_art(self: &Shared) {
        for t in self.lib.write().tracks.iter_mut() {
            if crate::covers::poster_for(&t.id).is_some() { t.has_art = true; }
        }
    }

    pub fn rescan(self: &Shared) {
        if self.lib.read().scanning {
            // a scan is running: run one more when it finishes
            self.rescan_pending.store(true, Ordering::SeqCst);
            return;
        }
        self.lib.write().scanning = true;
        self.ui("scan", serde_json::json!({ "scanning": true }));
        let me = self.clone();
        std::thread::spawn(move || {
            let (m, d, p) = {
                let c = me.cfg.read();
                (c.music_dirs.clone(), c.media_dirs.clone(), c.photo_sync_dir.clone())
            };
            let lib = Library::scan(&m, &d, &p);
            let (nt, nm) = (lib.tracks.len(), lib.media.len());
            *me.lib.write() = lib;
            let todo: Vec<(String, String)> = me.lib.read().tracks.iter().map(|t| (t.id.clone(), t.path.clone())).collect();
            crate::genre::analyze_missing(todo);
            me.sync_covers(false);
            me.ui("scan", serde_json::json!({ "scanning": false, "tracks": nt, "media": nm }));
            me.push(serde_json::json!({ "event": "library", "tracks": nt, "media": nm }));
            if me.rescan_pending.swap(false, Ordering::SeqCst) {
                me.rescan();
            }
        });
    }

    /// Watch the music & media folders and rescan (debounced) when files change.
    pub fn watch_folders(self: &Shared) {
        use notify::{RecursiveMode, Watcher};
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(e) = res {
                if e.kind.is_create() || e.kind.is_remove() || e.kind.is_modify() {
                    let interesting = e.paths.iter().any(|p| {
                        let ext = p.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
                        !ext.is_empty() && ext != "mgpart" && ext != "tmp" && ext != "crdownload"
                    });
                    if interesting { let _ = tx.send(()); }
                }
            }
        });
        let Ok(mut w) = watcher else { return };
        let dirs = {
            let c = self.cfg.read();
            let mut d = c.music_dirs.clone();
            d.extend(c.media_dirs.clone());
            d.push(c.photo_sync_dir.clone());
            d
        };
        for d in dirs {
            let _ = w.watch(std::path::Path::new(&d), RecursiveMode::Recursive);
        }
        *self.watcher.lock() = Some(w);
        let me = self.clone();
        std::thread::spawn(move || {
            while rx.recv().is_ok() {
                // debounce: wait until changes settle for 4s
                while rx.recv_timeout(std::time::Duration::from_secs(4)).is_ok() {}
                me.rescan();
            }
        });
    }
}
