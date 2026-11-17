use crate::config::{self, Config};
use crate::library::Library;
use once_cell::sync::OnceCell;
use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
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
    pub last_clip: Mutex<String>,
    pub synced: Mutex<HashSet<String>>,
    pub ui_token: String,
    pub handle: OnceCell<AppHandle>,
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
        Arc::new(App {
            cfg: RwLock::new(cfg),
            lib: RwLock::new(Library::default()),
            events: tx,
            devices: RwLock::new(HashMap::new()),
            shared: RwLock::new(shared),
            last_clip: Mutex::new(String::new()),
            synced: Mutex::new(config::load_synced()),
            ui_token: config::random_hex(16),
            handle: OnceCell::new(),
        })
    }

    /// Notify the desktop UI.
    pub fn ui(&self, event: &str, payload: serde_json::Value) {
        if let Some(h) = self.handle.get() {
            let _ = h.emit("mg", serde_json::json!({ "event": event, "data": payload }));
        }
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
        });
    }
}
