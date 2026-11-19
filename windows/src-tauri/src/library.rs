use crate::config::{cache_dir, id_for};
use lofty::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::time::UNIX_EPOCH;
use walkdir::WalkDir;

const AUDIO: &[&str] = &["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "aiff", "aif", "alac", "wma"];
const PHOTO: &[&str] = &["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", "tif", "tiff", "dng"];
const VIDEO: &[&str] = &["mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp", "wmv"];

#[derive(Clone, Serialize, Deserialize)]
pub struct Track {
    pub id: String,
    #[serde(skip_serializing, default)]
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

/// Removes the "MassTamilan" branding that scraped files carry in almost every tag
/// ("Title - MassTamilan", "Album - MassTamilan", "MassTamilan.dev"). Returns "" if nothing else is left.
fn clean(s: &str) -> String {
    const BRAND: &str = "masstamilan";
    let mut out = s.trim().to_string();
    while let Some(i) = out.to_ascii_lowercase().find(BRAND) {
        let mut end = i + BRAND.len();
        if out[end..].starts_with('.') {
            end += 1 + out[end + 1..].chars().take_while(|c| c.is_ascii_alphabetic()).count();
        }
        let head = out[..i].trim_end().trim_end_matches(|c| matches!(c, '-' | '–' | '—' | '|' | '(' | '[' | ':')).trim_end().to_string();
        let tail = out[end..].trim_start().trim_start_matches(|c| matches!(c, ')' | ']')).trim_start().to_string();
        out = format!("{head} {tail}").trim().to_string();
    }
    out
}

/// Scraped file names look like "meesaya-murukku-2-2026 - Middle Class.mp3": "<album slug>-<year> - <title>".
fn scraped_name(stem: &str) -> Option<(String, u32, String)> {
    let (left, title) = stem.split_once(" - ")?;
    let (slug, year) = left.rsplit_once('-')?;
    let year: u32 = year.parse().ok().filter(|y| (1900..2100).contains(y) && left.len() - slug.len() == 5)?;
    if slug.is_empty() || !slug.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
        return None;
    }
    let album = slug
        .split('-')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ");
    Some((album, year, title.trim().to_string()))
}

fn read_track(path: &Path, meta: &std::fs::Metadata, root: &Path) -> Track {
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
    // folder name as album when the file has no tag
    if let Some(parent) = path.parent() {
        if parent != root {
            if let Some(n) = parent.file_name() { t.album = n.to_string_lossy().to_string(); }
        }
    }
    // "<album slug>-<year> - Title.mp3" (scraped sites), else "Artist - Title.mp3"
    if let Some((album, year, title)) = scraped_name(&stem) {
        t.album = album;
        t.year = year;
        t.title = title;
    } else if let Some((a, b)) = stem.split_once(" - ") {
        t.artist = a.trim().into();
        t.title = b.trim().into();
    }
    if let Ok(f) = lofty::read_from_path(path) {
        t.duration = f.properties().duration().as_secs_f64();
        if let Some(tag) = f.primary_tag().or_else(|| f.first_tag()) {
            let t_title = tag.title().map(|v| clean(&v)).unwrap_or_default();
            if !t_title.is_empty() { t.title = t_title; }
            let t_artist = tag.artist().map(|v| clean(&v)).unwrap_or_default();
            if !t_artist.is_empty() { t.artist = t_artist; }
            let t_album = tag.album().map(|v| clean(&v)).unwrap_or_default();
            if !t_album.is_empty() { t.album = t_album; }
            t.track = tag.track().unwrap_or(0);
            if let Some(d) = tag.date() { t.year = d.year as u32; }
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
        // tag cache: re-reading tags is the slow part of a scan, so reuse
        // entries whose size and modified time haven't changed.
        let cache_file = cache_dir().join("tags2.json");
        let cache: HashMap<String, Track> = std::fs::read_to_string(&cache_file)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<Track>>(&s).ok())
            .map(|v| v.into_iter().map(|t| (t.path.clone(), t)).collect())
            .unwrap_or_default();
        for d in music_dirs {
            let root = Path::new(d);
            for e in WalkDir::new(d).follow_links(true).into_iter().filter_map(|e| e.ok()) {
                if !e.file_type().is_file() { continue; }
                let p = e.path();
                if !AUDIO.contains(&ext_of(p).as_str()) { continue; }
                let Ok(meta) = e.metadata() else { continue };
                let ps = p.to_string_lossy().to_string();
                let mut t = match cache.get(&ps) {
                    Some(c) if c.size == meta.len() && c.added == mtime(&meta) => c.clone(),
                    _ => read_track(p, &meta, root),
                };
                if crate::covers::poster_for(&t.id).is_some() { t.has_art = true; } // movie poster from covers.rs
                if lib.track_map.contains_key(&t.id) { continue; }
                lib.track_map.insert(t.id.clone(), lib.tracks.len());
                lib.tracks.push(t);
            }
        }
        lib.tracks.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
        lib.track_map = lib.tracks.iter().enumerate().map(|(i, t)| (t.id.clone(), i)).collect();
        #[derive(Serialize)]
        struct Cached<'a> { #[serde(flatten)] t: &'a Track, path: &'a str }
        let cached: Vec<Cached> = lib.tracks.iter().map(|t| Cached { t, path: &t.path }).collect();
        if let Ok(j) = serde_json::to_string(&cached) { let _ = std::fs::write(&cache_file, j); }

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

    /// Add one new file (e.g. a photo just received from the iPhone) without a full rescan.
    pub fn add_media(&mut self, path: &Path, from_iphone: bool) -> Option<MediaItem> {
        let ext = ext_of(path);
        let kind = if PHOTO.contains(&ext.as_str()) { "photo" } else if VIDEO.contains(&ext.as_str()) { "video" } else { return None };
        let meta = std::fs::metadata(path).ok()?;
        let ps = path.to_string_lossy().to_string();
        let id = id_for(&ps);
        if self.media_map.contains_key(&id) { return None; }
        let item = MediaItem {
            id: id.clone(),
            name: path.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            folder: path.parent().and_then(|x| x.file_name()).map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
            from_iphone,
            path: ps,
            kind,
            size: meta.len(),
            modified: mtime(&meta),
        };
        let pos = self.media.iter().position(|m| m.modified < item.modified).unwrap_or(self.media.len());
        self.media.insert(pos, item.clone());
        self.media_map = self.media.iter().enumerate().map(|(i, m)| (m.id.clone(), i)).collect();
        Some(item)
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
    let rgb = match image::open(path) {
        Ok(img) => img.thumbnail(size, size).to_rgb8(),
        Err(_) => shell_thumbnail(path, size)?,
    };
    let mut buf = std::io::Cursor::new(Vec::new());
    rgb.write_to(&mut buf, image::ImageFormat::Jpeg).ok()?;
    let v = buf.into_inner();
    let _ = std::fs::write(&out, &v);
    Some(v)
}

/// Windows Explorer's own thumbnailer: handles HEIC (iPhone photos), RAW and videos.
#[cfg(windows)]
fn shell_thumbnail(path: &str, size: u32) -> Option<image::RgbImage> {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::SIZE;
    use windows::Win32::Graphics::Gdi::{
        CreateCompatibleDC, DeleteDC, DeleteObject, GetDIBits, GetObjectW, BITMAP, BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        DIB_RGB_COLORS,
    };
    use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};
    use windows::Win32::UI::Shell::{IShellItemImageFactory, SHCreateItemFromParsingName, SIIGBF_BIGGERSIZEOK, SIIGBF_RESIZETOFIT};
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let factory: IShellItemImageFactory = SHCreateItemFromParsingName(&HSTRING::from(path), None).ok()?;
        let hbm = factory
            .GetImage(SIZE { cx: size as i32, cy: size as i32 }, SIIGBF_RESIZETOFIT | SIIGBF_BIGGERSIZEOK)
            .ok()?;
        let mut bm = BITMAP::default();
        GetObjectW(hbm.into(), std::mem::size_of::<BITMAP>() as i32, Some(&mut bm as *mut BITMAP as *mut _));
        let (w, h) = (bm.bmWidth, bm.bmHeight.abs());
        if w <= 0 || h <= 0 {
            let _ = DeleteObject(hbm.into());
            return None;
        }
        let mut bmi = BITMAPINFO::default();
        bmi.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h, // top-down rows
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        };
        let mut buf = vec![0u8; (w * h * 4) as usize];
        let dc = CreateCompatibleDC(None);
        let rows = GetDIBits(dc, hbm, 0, h as u32, Some(buf.as_mut_ptr() as *mut _), &mut bmi, DIB_RGB_COLORS);
        let _ = DeleteDC(dc);
        let _ = DeleteObject(hbm.into());
        if rows == 0 {
            return None;
        }
        let mut rgb = image::RgbImage::new(w as u32, h as u32);
        for (i, px) in rgb.pixels_mut().enumerate() {
            let b = &buf[i * 4..i * 4 + 4];
            *px = image::Rgb([b[2], b[1], b[0]]);
        }
        Some(rgb)
    }
}

#[cfg(not(windows))]
fn shell_thumbnail(_path: &str, _size: u32) -> Option<image::RgbImage> {
    None
}
