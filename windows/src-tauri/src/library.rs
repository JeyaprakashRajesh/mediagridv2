use crate::config::{cache_dir, id_for};
use lofty::prelude::*;
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::time::UNIX_EPOCH;
use walkdir::WalkDir;

const AUDIO: &[&str] = &["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "aif", "alac", "wma"];
const PHOTO: &[&str] = &["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff", "dng"];
const VIDEO: &[&str] = &["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "wmv"];

#[derive(Clone, Serialize)]
pub struct Track {
    pub id: String,
    #[serde(skip)]
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration: f64,
    pub size: u64,
    pub ext: String,
    pub added: i64,
    pub track: u32,
    pub year: u32,
    pub has_art: bool,
}

#[derive(Clone, Serialize)]
pub struct MediaItem {
    pub id: String,
    #[serde(skip)]
    pub path: String,
    pub name: String,
    pub kind: &'static str,
    pub size: u64,
    pub modified: i64,
    pub folder: String,
    pub from_iphone: bool,
}

#[derive(Default)]
pub struct Library {
    pub tracks: Vec<Track>,
    pub track_map: HashMap<String, usize>,
    pub media: Vec<MediaItem>,
    pub media_map: HashMap<String, usize>,
    pub scanning: bool,
}

fn ext_of(p: &Path) -> String {
    p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

fn mtime(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn read_track(path: &Path, meta: &std::fs::Metadata) -> Track {
    let ps = path.to_string_lossy().to_string();
    let id = id_for(&ps);
    let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let mut t = Track {
        id: id.clone(),
        path: ps,
        title: stem.clone(),
        artist: "Unknown Artist".into(),
        album: "Unknown Album".into(),
        duration: 0.0,
        size: meta.len(),
        ext: ext_of(path),
        added: mtime(meta),
        track: 0,
        year: 0,
        has_art: false,
    };
    // "Artist - Title.mp3" fallback
    if let Some((a, b)) = stem.split_once(" - ") {
        t.artist = a.trim().into();
        t.title = b.trim().into();
    }
    if let Ok(f) = lofty::read_from_path(path) {
        t.duration = f.properties().duration().as_secs_f64();
        if let Some(tag) = f.primary_tag().or_else(|| f.first_tag()) {
            if let Some(v) = tag.title() { if !v.trim().is_empty() { t.title = v.trim().to_string(); } }
            if let Some(v) = tag.artist() { if !v.trim().is_empty() { t.artist = v.trim().to_string(); } }
            if let Some(v) = tag.album() { if !v.trim().is_empty() { t.album = v.trim().to_string(); } }
            t.track = tag.track().unwrap_or(0);
            t.year = tag.date().map(|d| d.year as u32).unwrap_or(0);
            if let Some(pic) = tag.pictures().first() {
                let art = cache_dir().join("art").join(format!("{id}.img"));
                if !art.exists() {
                    let _ = std::fs::write(&art, pic.data());
                }
                t.has_art = true;
            }
        }
    }
    t
}

impl Library {
    pub fn scan(music_dirs: &[String], media_dirs: &[String], iphone_dir: &str) -> Library {
        let mut lib = Library::default();
        for d in music_dirs {
            for e in WalkDir::new(d).follow_links(true).into_iter().filter_map(|e| e.ok()) {
                if !e.file_type().is_file() { continue; }
                let p = e.path();
                if !AUDIO.contains(&ext_of(p).as_str()) { continue; }
                let Ok(meta) = e.metadata() else { continue };
                let t = read_track(p, &meta);
                if lib.track_map.contains_key(&t.id) { continue; }
                lib.track_map.insert(t.id.clone(), lib.tracks.len());
                lib.tracks.push(t);
            }
        }
        lib.tracks.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
        lib.track_map = lib.tracks.iter().enumerate().map(|(i, t)| (t.id.clone(), i)).collect();

        let iphone_lc = iphone_dir.to_lowercase();
        let mut dirs: Vec<String> = media_dirs.to_vec();
        if !dirs.iter().any(|d| iphone_lc.starts_with(&d.to_lowercase())) {
            dirs.push(iphone_dir.to_string());
        }
        for d in &dirs {
            for e in WalkDir::new(d).follow_links(true).into_iter().filter_map(|e| e.ok()) {
                if !e.file_type().is_file() { continue; }
                let p = e.path();
                let ext = ext_of(p);
                let kind = if PHOTO.contains(&ext.as_str()) { "photo" } else if VIDEO.contains(&ext.as_str()) { "video" } else { continue };
                let Ok(meta) = e.metadata() else { continue };
                let ps = p.to_string_lossy().to_string();
                let id = id_for(&ps);
                if lib.media_map.contains_key(&id) { continue; }
                let item = MediaItem {
                    id: id.clone(),
                    name: p.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
                    folder: p.parent().and_then(|x| x.file_name()).map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
                    from_iphone: ps.to_lowercase().starts_with(&iphone_lc),
                    path: ps,
                    kind,
                    size: meta.len(),
                    modified: mtime(&meta),
                };
                lib.media_map.insert(id, lib.media.len());
                lib.media.push(item);
            }
        }
        lib.media.sort_by(|a, b| b.modified.cmp(&a.modified));
        lib.media_map = lib.media.iter().enumerate().map(|(i, m)| (m.id.clone(), i)).collect();
        lib
    }

    pub fn track(&self, id: &str) -> Option<&Track> {
        self.track_map.get(id).map(|&i| &self.tracks[i])
    }
    pub fn item(&self, id: &str) -> Option<&MediaItem> {
        self.media_map.get(id).map(|&i| &self.media[i])
    }
}

/// Build (or fetch cached) JPEG thumbnail for an image file.
pub fn thumbnail(id: &str, path: &str, size: u32) -> Option<Vec<u8>> {
    let out = cache_dir().join("thumbs").join(format!("{id}_{size}.jpg"));
    if let Ok(b) = std::fs::read(&out) {
        return Some(b);
    }
    let img = image::open(path).ok()?;
    let t = img.thumbnail(size, size);
    let mut buf = std::io::Cursor::new(Vec::new());
    t.to_rgb8().write_to(&mut buf, image::ImageFormat::Jpeg).ok()?;
    let v = buf.into_inner();
    let _ = std::fs::write(&out, &v);
    Some(v)
}
