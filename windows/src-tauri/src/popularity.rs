//! Internet popularity of songs, kept in a small local database (one JSON file: song id -> Deezer rank).
//! Light on network and memory: each song is looked up at most once (misses are retried after 90 days),
//! one request every 300 ms in a single background thread, and only when a phone asks for popularity.
use once_cell::sync::Lazy;
use parking_lot::RwLock;
use std::{
    collections::HashMap,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

const RETRY_MS: i64 = 90 * 24 * 3600 * 1000;

/// id -> (Deezer rank, checked at ms). Rank 0 = no match found.
static DB: Lazy<RwLock<HashMap<String, (u32, i64)>>> = Lazy::new(|| {
    let m = std::fs::read(crate::config::cache_dir().join("popularity.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    RwLock::new(m)
});
static RUNNING: AtomicBool = AtomicBool::new(false);

pub fn get(id: &str) -> Option<u32> {
    DB.read().get(id).map(|e| e.0).filter(|r| *r > 0)
}

fn save() {
    if let Ok(b) = serde_json::to_vec(&*DB.read()) {
        let _ = std::fs::write(crate::config::cache_dir().join("popularity.json"), b);
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn norm(s: &str) -> String {
    let base = s.split(" (").next().unwrap_or(s).split(" - ").next().unwrap_or(s);
    base.chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase()
}

/// Ok(None) = looked up fine but no matching song; Err = network problem (try again later).
fn lookup(artist: &str, title: &str) -> Result<Option<u32>, ()> {
    let first = artist.split(',').next().unwrap_or(artist).trim();
    let q = format!("artist:\"{first}\" track:\"{title}\"");
    let v: serde_json::Value = ureq::get("https://api.deezer.com/search")
        .query("q", &q)
        .query("limit", "5")
        .timeout(Duration::from_secs(6))
        .call()
        .map_err(|_| ())?
        .into_json()
        .map_err(|_| ())?;
    let want = norm(title);
    let best = v["data"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|it| {
            let got = norm(it["title"].as_str().unwrap_or(""));
            !want.is_empty() && (got == want || got.contains(&want) || want.contains(&got))
        })
        .filter_map(|it| it["rank"].as_u64())
        .max();
    Ok(best.map(|r| r.min(u32::MAX as u64) as u32))
}

/// Look up songs that have no (or an old miss) entry; (id, artist, title). One worker at a time.
pub fn fetch_missing(items: Vec<(String, String, String)>) {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let now = now_ms();
        let mut n = 0;
        for (id, artist, title) in items {
            while crate::eco::ON.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_secs(5)); // eco mode: no background work
            }
            let known = DB.read().get(&id).map(|e| e.0 > 0 || now - e.1 < RETRY_MS).unwrap_or(false);
            if known {
                continue;
            }
            match lookup(&artist, &title) {
                Ok(r) => {
                    DB.write().insert(id, (r.unwrap_or(0), now));
                    n += 1;
                    if n % 25 == 0 {
                        save();
                    }
                }
                Err(()) => break, // offline or rate limited: stop, a later request resumes
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        save();
        RUNNING.store(false, Ordering::SeqCst);
    });
}
