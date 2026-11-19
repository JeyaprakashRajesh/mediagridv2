//! Song lyrics from LRCLIB (https://lrclib.net, free, no key): synced (LRC) when available, else plain text.
//! One lookup per song; results (and "no lyrics") are cached on disk. Only artist, title, album and length are sent.
use serde_json::{json, Value};
use std::time::Duration;

pub fn get(id: &str, artist: &str, title: &str, album: &str, duration: f64) -> Value {
    let p = crate::config::cache_dir().join("lyrics").join(format!("{id}.json"));
    if let Some(v) = std::fs::read(&p).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) {
        return v;
    }
    match fetch(artist, title, album, duration) {
        Ok(v) => {
            if let Some(d) = p.parent() { let _ = std::fs::create_dir_all(d); }
            let _ = std::fs::write(&p, v.to_string());
            v
        }
        Err(()) => json!({}), // offline: don't cache, try again next time
    }
}

fn fetch(artist: &str, title: &str, album: &str, duration: f64) -> Result<Value, ()> {
    let first = artist.split(',').next().unwrap_or(artist).trim();
    let res = ureq::get("https://lrclib.net/api/get")
        .set("User-Agent", "MediaGrid")
        .query("artist_name", first)
        .query("track_name", title)
        .query("album_name", album)
        .query("duration", &(duration.round() as i64).to_string())
        .timeout(Duration::from_secs(6))
        .call();
    match res {
        Ok(r) => {
            let v: Value = r.into_json().map_err(|_| ())?;
            Ok(json!({ "synced": v["syncedLyrics"], "plain": v["plainLyrics"] }))
        }
        Err(ureq::Error::Status(404, _)) => Ok(json!({})),
        Err(_) => Err(()),
    }
}
