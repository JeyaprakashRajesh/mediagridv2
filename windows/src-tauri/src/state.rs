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
        Arc::new(App {
            cfg: RwLock::new(cfg),
            lib: RwLock::new(Library::default()),
            events: tx,
            devices: RwLock::new(HashMap::new()),
            shared: RwLock::new(shared),
            playback: RwLock::new(playback),
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

    /// Push an event to every connected phone.
    pub fn push(&self, v: serde_json::Value) {
        let _ = self.events.send(v.to_string());
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
