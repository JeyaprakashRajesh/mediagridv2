use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

pub fn data_dir() -> PathBuf {
    let d = dirs::config_dir().unwrap_or_else(std::env::temp_dir).join("MediaGrid");
    let _ = std::fs::create_dir_all(&d);
    d
}

pub fn cache_dir() -> PathBuf {
    let d = dirs::cache_dir().unwrap_or_else(std::env::temp_dir).join("MediaGrid");
    let _ = std::fs::create_dir_all(d.join("thumbs"));
    let _ = std::fs::create_dir_all(d.join("art"));
    d
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub device_name: String,
    pub email: String,
    pub password_hash: String,
    pub salt: String,
    pub port: u16,
    pub music_dirs: Vec<String>,
    pub media_dirs: Vec<String>,
    pub photo_sync_dir: String,
    pub inbox_dir: String,
    pub clipboard_sync: bool,
    pub remote_control: bool,
    pub auto_photo_sync: bool,
    pub autostart: bool,
    /// token -> device name
    pub tokens: HashMap<String, String>,
}

impl Default for Config {
    fn default() -> Self {
        let h = home();
        let music = dirs::audio_dir().unwrap_or_else(|| h.join("Music"));
        let pics = dirs::picture_dir().unwrap_or_else(|| h.join("Pictures"));
        let vids = dirs::video_dir().unwrap_or_else(|| h.join("Videos"));
        let dl = dirs::download_dir().unwrap_or_else(|| h.join("Downloads"));
        Config {
            device_name: hostname::get()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|_| "My PC".into()),
            email: String::new(),
            password_hash: String::new(),
            salt: String::new(),
            port: 47800,
            music_dirs: vec![music.to_string_lossy().into()],
            media_dirs: vec![pics.to_string_lossy().into(), vids.to_string_lossy().into()],
            photo_sync_dir: pics.join("MediaGrid iPhone").to_string_lossy().into(),
            inbox_dir: dl.join("MediaGrid").to_string_lossy().into(),
            clipboard_sync: true,
            remote_control: true,
            auto_photo_sync: true,
            autostart: true,
            tokens: HashMap::new(),
        }
    }
}

impl Config {
    pub fn load() -> Self {
        let p = data_dir().join("config.json");
        std::fs::read_to_string(&p)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let p = data_dir().join("config.json");
        if let Ok(s) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(p, s);
        }
        let _ = std::fs::create_dir_all(&self.photo_sync_dir);
        let _ = std::fs::create_dir_all(&self.inbox_dir);
    }

    pub fn has_account(&self) -> bool {
        !self.email.is_empty() && !self.password_hash.is_empty()
    }

    pub fn set_password(&mut self, email: &str, password: &str) {
        self.email = email.trim().to_lowercase();
        self.salt = random_hex(16);
        self.password_hash = hash_pw(&self.salt, password);
        // changing credentials signs out every paired phone
        self.tokens.clear();
    }

    pub fn check(&self, email: &str, password: &str) -> bool {
        self.has_account()
            && self.email == email.trim().to_lowercase()
            && self.password_hash == hash_pw(&self.salt, password)
    }
}

pub fn hash_pw(salt: &str, pw: &str) -> String {
    let mut h = Sha256::new();
    h.update(salt.as_bytes());
    h.update(pw.as_bytes());
    let mut out = h.finalize().to_vec();
    // key stretching
    for _ in 0..50_000 {
        let mut h = Sha256::new();
        h.update(&out);
        h.update(salt.as_bytes());
        out = h.finalize().to_vec();
    }
    hex::encode(out)
}

pub fn random_hex(bytes: usize) -> String {
    use rand::RngCore;
    let mut b = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut b);
    hex::encode(b)
}

pub fn id_for(path: &str) -> String {
    let mut h = Sha256::new();
    h.update(path.to_lowercase().as_bytes());
    hex::encode(&h.finalize()[..8])
}

/// iPhone photo asset ids that were already received.
pub fn load_synced() -> HashSet<String> {
    std::fs::read_to_string(data_dir().join("synced.json"))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

pub fn save_synced(s: &HashSet<String>) {
    if let Ok(j) = serde_json::to_string(s) {
        let _ = std::fs::write(data_dir().join("synced.json"), j);
    }
}
