//! Movie-poster database. Every song is linked to its movie (album name) and every movie has exactly one
//! poster, so all songs of a movie always show the same picture. `covers.json` holds both tables:
//!   songs:  song id -> movie key        (a song is "populated" once it has an entry)
//!   movies: movie key -> { name, file, source, checked, manual }
//! At every library scan `sync` compares the songs on disk with the table, links the new ones and fetches
//! posters (Deezer, then iTunes) only for movies that have none. A poster you set by hand is never replaced.
use once_cell::sync::Lazy;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    hash::{Hash, Hasher},
    io::Read,
    path::PathBuf,
    sync::atomic::{AtomicBool, AtomicUsize, Ordering::SeqCst},
    time::Duration,
};

#[derive(Default, Serialize, Deserialize, Clone)]
struct Movie {
    name: String,
    file: Option<String>,
    source: String,
    checked: i64,
    manual: bool,
}
#[derive(Default, Serialize, Deserialize)]
struct Db {
    songs: HashMap<String, String>,
    movies: HashMap<String, Movie>,
}

static DB: Lazy<RwLock<Db>> = Lazy::new(|| {
    RwLock::new(std::fs::read(config_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default())
});
static RUNNING: AtomicBool = AtomicBool::new(false);
static SONGS: AtomicUsize = AtomicUsize::new(0);
static NEW: AtomicUsize = AtomicUsize::new(0);
static M_TOTAL: AtomicUsize = AtomicUsize::new(0);
static M_DONE: AtomicUsize = AtomicUsize::new(0);
static M_FOUND: AtomicUsize = AtomicUsize::new(0);
const RETRY_MS: i64 = 30 * 24 * 3600 * 1000;

fn config_path() -> PathBuf { crate::config::cache_dir().join("covers.json") }
fn posters() -> PathBuf {
    let d = crate::config::cache_dir().join("posters");
    let _ = std::fs::create_dir_all(&d);
    d
}
fn save() {
    if let Ok(b) = serde_json::to_vec(&*DB.read()) { let _ = std::fs::write(config_path(), b); }
}
fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}
fn norm(s: &str) -> String {
    s.split(" (").next().unwrap_or(s).chars().filter(|c| c.is_alphanumeric()).collect::<String>().to_lowercase()
}
fn file_for(key: &str) -> String {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    key.hash(&mut h);
    format!("{:016x}.img", h.finish())
}

/// The movie poster file for a song, if its movie has one.
pub fn poster_for(id: &str) -> Option<PathBuf> {
    let db = DB.read();
    let f = db.movies.get(db.songs.get(id)?)?.file.as_ref()?;
    let p = posters().join(f);
    p.exists().then_some(p)
}

pub fn status() -> serde_json::Value {
    let (populated, movies, with) = {
        let db = DB.read();
        (db.songs.len(), db.movies.len(), db.movies.values().filter(|m| m.file.is_some()).count())
    };
    serde_json::json!({
        "running": RUNNING.load(SeqCst), "songs": SONGS.load(SeqCst), "populated": populated, "new": NEW.load(SeqCst),
        "movies": movies, "withPoster": with, "done": M_DONE.load(SeqCst), "total": M_TOTAL.load(SeqCst), "found": M_FOUND.load(SeqCst),
    })
}

/// Set a poster by hand for the song's whole movie.
pub fn set_manual(id: &str, album: &str, bytes: &[u8]) -> std::io::Result<()> {
    let mut key = norm(album);
    if key.is_empty() { key = format!("song:{id}"); }
    let file = file_for(&key);
    std::fs::write(posters().join(&file), bytes)?;
    {
        let mut db = DB.write();
        db.songs.insert(id.to_string(), key.clone());
        db.movies.insert(key, Movie { name: album.to_string(), file: Some(file), source: "manual".into(), checked: now_ms(), manual: true });
    }
    save();
    Ok(())
}

fn pick<'a>(want: &str, cands: impl Iterator<Item = (&'a str, String)>) -> Option<String> {
    let mut loose = None;
    for (title, url) in cands {
        let got = norm(title);
        if got == want { return Some(url); }
        if loose.is_none() && want.len() >= 5 && got.len() >= 5 && (got.starts_with(want) || want.starts_with(&got)) { loose = Some(url); }
    }
    loose
}

fn find(name: &str) -> Option<(Vec<u8>, &'static str)> {
    let want = norm(name);
    if want.is_empty() { return None; }
    let (url, src) = match deezer(name, &want) {
        Some(u) => (u, "deezer"),
        None => (itunes(name, &want)?, "itunes"),
    };
    let mut b = Vec::new();
    ureq::get(&url).timeout(Duration::from_secs(10)).call().ok()?.into_reader().take(6_000_000).read_to_end(&mut b).ok()?;
    (b.len() > 2000 && (b.starts_with(&[0xFF, 0xD8]) || b.starts_with(&[0x89, b'P']))).then_some((b, src))
}

fn deezer(name: &str, want: &str) -> Option<String> {
    let v: serde_json::Value = ureq::get("https://api.deezer.com/search/album").query("q", name).query("limit", "8").timeout(Duration::from_secs(6)).call().ok()?.into_json().ok()?;
    pick(want, v["data"].as_array()?.iter().filter_map(|it| Some((it["title"].as_str()?, it["cover_xl"].as_str()?.to_string()))))
}

fn itunes(name: &str, want: &str) -> Option<String> {
    let v: serde_json::Value = ureq::get("https://itunes.apple.com/search").query("term", name).query("entity", "album").query("country", "IN").query("limit", "8").timeout(Duration::from_secs(6)).call().ok()?.into_json().ok()?;
    pick(want, v["results"].as_array()?.iter().filter_map(|it| Some((it["collectionName"].as_str()?, it["artworkUrl100"].as_str()?.replace("100x100", "1000x1000")))))
}

/// tracks = (song id, album). Links new songs to their movie, then fetches posters for movies without one
/// (`force` also retries movies that failed before the retry window ended). `on_done` runs after the table changed.
pub fn sync(tracks: Vec<(String, String)>, force: bool, on_done: impl FnOnce() + Send + 'static) {
    if RUNNING.swap(true, SeqCst) { return; }
    std::thread::spawn(move || {
        SONGS.store(tracks.len(), SeqCst);
        let mut new = 0;
        {
            let mut db = DB.write();
            for (id, album) in &tracks {
                if db.songs.contains_key(id) { continue; }
                let mut key = norm(album);
                if key.is_empty() { key = format!("song:{id}"); }
                let m = db.movies.entry(key.clone()).or_default();
                if m.name.is_empty() { m.name = album.clone(); }
                db.songs.insert(id.clone(), key);
                new += 1;
            }
        }
        NEW.store(new, SeqCst);
        eprintln!("covers: {} songs on disk, {} newly added", tracks.len(), new);
        let now = now_ms();
        let todo: Vec<(String, String)> = DB
            .read()
            .movies
            .iter()
            .filter(|(k, m)| !m.manual && !k.starts_with("song:") && m.file.is_none() && (force || m.checked == 0 || now - m.checked > RETRY_MS))
            .map(|(k, m)| (k.clone(), m.name.clone()))
            .collect();
        M_DONE.store(0, SeqCst);
        M_FOUND.store(0, SeqCst);
        M_TOTAL.store(todo.len(), SeqCst);
        save();
        for (key, name) in todo {
            while crate::eco::ON.load(SeqCst) { std::thread::sleep(Duration::from_secs(5)); }
            let got = find(&name);
            let file = file_for(&key);
            let stored = got.as_ref().map_or(false, |(b, _)| std::fs::write(posters().join(&file), b).is_ok());
            if let Some(m) = DB.write().movies.get_mut(&key) {
                m.checked = now;
                if stored {
                    m.file = Some(file);
                    m.source = got.map(|g| g.1).unwrap_or_default().into();
                }
            }
            if stored { M_FOUND.fetch_add(1, SeqCst); }
            if M_DONE.fetch_add(1, SeqCst) % 10 == 9 { save(); }
            std::thread::sleep(Duration::from_millis(400));
        }
        save();
        RUNNING.store(false, SeqCst);
        on_done();
    });
}
