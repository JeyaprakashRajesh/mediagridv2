//! HTTP + WebSocket API the iPhone app talks to (LAN or Tailscale).
use crate::config::{self, random_hex};
use crate::control::{self, Cmd};
use crate::library;
use crate::state::{now_ms, Device, Shared, SharedItem};
use axum::{
    body::{Body, Bytes},
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        DefaultBodyLimit, Path as AxPath, Query, Request, State,
    },
    http::{header, HeaderMap, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use once_cell::sync::Lazy;
use tokio::io::AsyncWriteExt;
use tokio::sync::broadcast;
use tower::ServiceExt;
use tower_http::{cors::CorsLayer, services::ServeFile};

#[derive(Clone)]
struct Who(String); // token

type Q = Query<HashMap<String, String>>;

fn err(code: StatusCode, msg: &str) -> Response {
    (code, Json(json!({ "error": msg }))).into_response()
}

pub async fn run(app: Shared) {
    let port = app.cfg.read().port;
    tokio::spawn(presence_loop(app.clone()));
    advertise(&app, port);

    let open = Router::new()
        .route("/api/ping", get(ping))
        .route("/api/login", post(login));

    let secured = Router::new()
        .route("/api/me", get(me))
        .route("/api/music/tracks", get(tracks))
        .route("/api/music/stream/{id}", get(stream_track))
        .route("/api/music/art/{id}", get(track_art))
        .route("/api/rescan", post(rescan))
        .route("/api/media/items", get(media_items))
        .route("/api/media/file/{id}", get(media_file))
        .route("/api/media/thumb/{id}", get(media_thumb))
        .route("/api/files/list", get(files_list))
        .route("/api/files/raw", get(files_raw))
        .route("/api/files/thumb", get(files_thumb))
        .route("/api/files/upload", post(files_upload))
        .route("/api/music/upload", post(music_upload))
        .route("/api/clipboard", get(clip_get).post(clip_set))
        .route("/api/shared", get(shared_list))
        .route("/api/shared/text", post(shared_text))
        .route("/api/shared/file", post(shared_file_up))
        .route("/api/shared/file/{id}", get(shared_file_get))
        .route("/api/photos/synced", get(photos_synced))
        .route("/api/photos/upload", post(photos_upload))
        .route("/api/control", post(control_http))
        .route("/api/screen", get(screen))
        .route("/api/screen/stream", get(screen_stream))
        .route("/api/audio/stream", get(audio_stream))
        .route("/api/stream/options", get(stream_options))
        .route("/api/presence", get(presence_get).post(presence_set))
        .route("/api/music/lyrics/{id}", get(lyrics))
        .route("/api/pc/play", post(pc_play))
        .route("/api/devices", get(devices))
        .route("/api/playback", get(playback_get).post(playback_set))
        .route("/api/call", get(call_get).post(call_set))
        .route("/api/clipboard/silent", post(clip_silent))
        .route("/api/playlists", get(playlists_get).post(playlists_set))
        .route("/api/phone", post(phone_cmd))
        .route("/api/cam/frame", post(cam_frame))
        .route("/api/cam/audio", get(cam_audio_out).post(cam_audio_in))
        .route("/api/cam/state", get(cam_state_get).post(cam_state_set))
        .route("/cam.mjpg", get(cam_mjpeg))
        .route("/api/cam/stream", get(cam_stream))
        .route("/api/vcam", get(vcam_status).post(vcam_set))
        .route("/api/vcam/install", post(vcam_install))
        .route("/ws", get(ws))
        .layer(middleware::from_fn_with_state(app.clone(), auth));

    let router = open
        .merge(secured)
        .layer(DefaultBodyLimit::disable())
        .layer(CorsLayer::permissive())
        .with_state(app.clone());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    match tokio::net::TcpListener::bind(addr).await {
        Ok(l) => {
            let _ = axum::serve(l, router.into_make_service_with_connect_info::<SocketAddr>()).await;
        }
        Err(e) => {
            let msg = format!("Port {port} is already in use ({e}). Close the other app using it or change the port.");
            *app.server_error.lock() = Some(msg.clone());
            app.ui("error", json!({ "message": msg }));
        }
    }
}

fn advertise(app: &Shared, port: u16) {
    let name = app.cfg.read().device_name.clone();
    std::thread::spawn(move || {
        let Ok(d) = mdns_sd::ServiceDaemon::new() else { return };
        let host = format!("{}.local.", name.replace(' ', "-"));
        let ip = local_ip_address::local_ip().map(|i| i.to_string()).unwrap_or_default();
        let props = [("app", "mediagrid"), ("v", "1")];
        if let Ok(info) = mdns_sd::ServiceInfo::new("_mediagrid._tcp.local.", &name, &host, ip.as_str(), port, &props[..]) {
            let _ = d.register(info.enable_addr_auto());
        }
        // keep daemon alive
        loop { std::thread::sleep(std::time::Duration::from_secs(3600)); }
    });
}

async fn auth(State(app): State<Shared>, mut req: Request, next: Next) -> Response {
    let mut token = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(|s| s.to_string());
    if token.is_none() {
        token = req.uri().query().and_then(|q| {
            q.split('&').find_map(|kv| kv.strip_prefix("t=").map(|s| s.to_string()))
        });
    }
    let Some(t) = token else { return err(StatusCode::UNAUTHORIZED, "missing token") };
    let ok = t == app.ui_token || app.cfg.read().tokens.contains_key(&t);
    if !ok {
        return err(StatusCode::UNAUTHORIZED, "invalid token");
    }
    req.extensions_mut().insert(Who(t));
    next.run(req).await
}

/// This PC's network card address, so the phone can send a Wake-on-LAN packet when the PC is asleep.
static MAC: Lazy<Option<String>> = Lazy::new(|| mac_address::get_mac_address().ok().flatten().map(|m| m.to_string()));

async fn ping(State(app): State<Shared>) -> Json<Value> {
    let c = app.cfg.read();
    Json(json!({ "app": "MediaGrid", "name": c.device_name, "version": env!("CARGO_PKG_VERSION"), "account": c.has_account(), "mac": *MAC }))
}

#[derive(Deserialize)]
struct Login {
    email: String,
    password: String,
    #[serde(default)]
    device: String,
}

async fn login(State(app): State<Shared>, Json(b): Json<Login>) -> Response {
    let (has, ok) = {
        let c = app.cfg.read();
        (c.has_account(), c.check(&b.email, &b.password))
    };
    if !has {
        return err(StatusCode::CONFLICT, "Create your account in the MediaGrid app on your PC first (Profile tab).");
    }
    if !ok {
        // slow down password guessing
        tokio::time::sleep(std::time::Duration::from_millis(900)).await;
        return err(StatusCode::UNAUTHORIZED, "Wrong email or password.");
    }
    login_ok(&app, b.device)
}

fn login_ok(app: &Shared, device: String) -> Response {
    let mut c = app.cfg.write();
    let token = random_hex(24);
    let dev = if device.is_empty() { "iPhone".into() } else { device };
    // signing in again from the same phone replaces its old pairing
    let stale: Vec<String> = c.tokens.iter().filter(|(_, n)| **n == dev).map(|(t, _)| t.clone()).collect();
    for t in &stale { c.tokens.remove(t); }
    c.tokens.insert(token.clone(), dev.clone());
    c.save();
    let name = c.device_name.clone();
    drop(c);
    {
        let mut d = app.devices.write();
        d.retain(|t, _| !stale.contains(t));
    }
    app.ui("devices", json!({}));
    Json(json!({ "token": token, "name": name })).into_response()
}

async fn me(State(app): State<Shared>) -> Json<Value> {
    let c = app.cfg.read();
    let l = app.lib.read();
    Json(json!({
        "name": c.device_name, "email": c.email, "tracks": l.tracks.len(), "media": l.media.len(),
        "clipboardSync": c.clipboard_sync, "remoteControl": c.remote_control, "autoPhotoSync": c.auto_photo_sync,
        "scanning": l.scanning
    }))
}

/// One copy per song: when the same song exists in several qualities, only the best one (lossless, then bitrate) is offered.
/// Streaming and downloads always serve the original file, never a transcode.
async fn tracks(State(app): State<Shared>, Query(q): Q) -> Json<Value> {
    let l = app.lib.read();
    let want_pop = q.get("pop").map(|s| s.as_str()) == Some("1");
    let rank = |t: &library::Track| -> (u8, u64) {
        let r = match t.ext.to_lowercase().as_str() {
            "flac" | "wav" | "aiff" | "aif" | "alac" => 3,
            "m4a" | "aac" | "ogg" | "opus" => 2,
            _ => 1,
        };
        (r, if t.duration > 0.0 { (t.size as f64 / t.duration) as u64 } else { 0 })
    };
    let mut best: std::collections::HashMap<(String, String, i64), &library::Track> = std::collections::HashMap::new();
    for t in &l.tracks {
        let key = (t.title.to_lowercase(), t.artist.to_lowercase(), (t.duration / 4.0).round() as i64);
        best.entry(key).and_modify(|b| if rank(t) > rank(*b) { *b = t }).or_insert(t);
    }
    let keep: std::collections::HashSet<&str> = best.values().map(|t| t.id.as_str()).collect();
    if want_pop {
        // the phone uses internet popularity: fill in songs we have no rank for (background, throttled)
        let todo = l.tracks.iter().filter(|t| keep.contains(t.id.as_str())).map(|t| (t.id.clone(), t.artist.clone(), t.title.clone())).collect();
        crate::popularity::fetch_missing(todo);
    }
    // bpm / energy / punch come from the audio analysis (genre.rs) once it has reached a song
    let v: Vec<Value> = l
        .tracks
        .iter()
        .filter(|t| keep.contains(t.id.as_str()))
        .map(|t| {
            let mut j = json!(t);
            if let Some(f) = crate::genre::get(&t.id) {
                j["bpm"] = json!(f[0]);
                j["energy"] = json!(f[1]);
                j["punch"] = json!(f[2]);
            }
            if want_pop {
                if let Some(r) = crate::popularity::get(&t.id) { j["rank"] = json!(r); }
            }
            j
        })
        .collect();
    Json(json!(v))
}

/// MIME types iOS's AVPlayer recognises (mime_guess gives e.g. "audio/m4a", which it rejects).
fn media_mime(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    Some(match ext.as_str() {
        "mp3" => "audio/mpeg",
        "m4a" | "alac" | "m4b" => "audio/mp4",
        "aac" => "audio/aac",
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "aif" | "aiff" => "audio/aiff",
        "ogg" | "opus" => "audio/ogg",
        "mp4" => "video/mp4",
        "m4v" => "video/x-m4v",
        "mov" => "video/quicktime",
        "heic" => "image/heic",
        "heif" => "image/heif",
        _ => return None,
    })
}

async fn serve_path(path: PathBuf, req: Request) -> Response {
    let mime = media_mime(&path);
    match ServeFile::new(path).oneshot(req).await {
        Ok(r) => {
            let mut r = r.map(Body::new).into_response();
            if let Some(m) = mime {
                r.headers_mut().insert(header::CONTENT_TYPE, header::HeaderValue::from_static(m));
            }
            r
        }
        Err(_) => err(StatusCode::NOT_FOUND, "not found"),
    }
}

async fn stream_track(State(app): State<Shared>, AxPath(id): AxPath<String>, req: Request) -> Response {
    let p = app.lib.read().track(&id).map(|t| t.path.clone());
    match p {
        Some(p) => serve_path(p.into(), req).await,
        None => err(StatusCode::NOT_FOUND, "no such track"),
    }
}

async fn track_art(AxPath(id): AxPath<String>) -> Response {
    let p = config::cache_dir().join("art").join(format!("{id}.img"));
    match tokio::fs::read(&p).await {
        Ok(b) => {
            let ct = if b.starts_with(&[0x89, b'P']) { "image/png" } else { "image/jpeg" };
            ([(header::CONTENT_TYPE, ct), (header::CACHE_CONTROL, "max-age=604800")], b).into_response()
        }
        Err(_) => err(StatusCode::NOT_FOUND, "no art"),
    }
}

async fn rescan(State(app): State<Shared>) -> Json<Value> {
    app.rescan();
    Json(json!({ "ok": true }))
}

async fn media_items(State(app): State<Shared>, Query(q): Q) -> Json<Value> {
    let kind = q.get("kind").cloned().unwrap_or_default();
    let l = app.lib.read();
    let v: Vec<_> = l.media.iter().filter(|m| kind.is_empty() || m.kind == kind).collect();
    Json(json!(v))
}

async fn media_file(State(app): State<Shared>, AxPath(id): AxPath<String>, req: Request) -> Response {
    let p = app.lib.read().item(&id).map(|m| m.path.clone());
    match p {
        Some(p) => serve_path(p.into(), req).await,
        None => err(StatusCode::NOT_FOUND, "no such item"),
    }
}

async fn media_thumb(State(app): State<Shared>, AxPath(id): AxPath<String>, Query(q): Q) -> Response {
    let item = app.lib.read().item(&id).map(|m| (m.path.clone(), m.kind));
    let size: u32 = q.get("s").and_then(|s| s.parse().ok()).unwrap_or(360).clamp(64, 1600);
    let Some((path, _kind)) = item else { return err(StatusCode::NOT_FOUND, "no such item") };
    thumb_response(id, path, size).await
}

async fn thumb_response(id: String, path: String, size: u32) -> Response {
    match tokio::task::spawn_blocking(move || library::thumbnail(&id, &path, size)).await {
        Ok(Some(b)) => ([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "max-age=604800")], b).into_response(),
        _ => err(StatusCode::UNSUPPORTED_MEDIA_TYPE, "cannot thumbnail"),
    }
}

// ---------- file explorer ----------

fn places() -> Vec<Value> {
    let mut v = vec![];
    let list = [
        ("Desktop", dirs::desktop_dir()),
        ("Documents", dirs::document_dir()),
        ("Downloads", dirs::download_dir()),
        ("Music", dirs::audio_dir()),
        ("Pictures", dirs::picture_dir()),
        ("Videos", dirs::video_dir()),
    ];
    for (n, p) in list {
        if let Some(p) = p {
            v.push(json!({ "name": n, "path": p.to_string_lossy(), "dir": true, "place": true }));
        }
    }
    #[cfg(target_os = "windows")]
    for c in b'A'..=b'Z' {
        let root = format!("{}:\\", c as char);
        if Path::new(&root).exists() {
            v.push(json!({ "name": format!("Local Disk ({}:)", c as char), "path": root, "dir": true, "drive": true }));
        }
    }
    #[cfg(not(target_os = "windows"))]
    v.push(json!({ "name": "Root", "path": "/", "dir": true, "drive": true }));
    v
}

async fn files_list(Query(q): Q) -> Response {
    let path = q.get("path").cloned().unwrap_or_default();
    if path.is_empty() {
        return Json(json!({ "path": "", "parent": null, "entries": places() })).into_response();
    }
    let hidden = q.get("hidden").map(|v| v == "1").unwrap_or(false);
    let p = PathBuf::from(&path);
    let res = tokio::task::spawn_blocking(move || -> std::io::Result<Vec<Value>> {
        let mut out = vec![];
        for e in std::fs::read_dir(&p)? {
            let Ok(e) = e else { continue };
            let name = e.file_name().to_string_lossy().to_string();
            if !hidden && (name.starts_with('.') || name.starts_with('$') || name == "desktop.ini" || name == "Thumbs.db") {
                continue;
            }
            let Ok(meta) = e.metadata() else { continue };
            let modified = meta.modified().ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64).unwrap_or(0);
            out.push(json!({
                "name": name, "path": e.path().to_string_lossy(), "dir": meta.is_dir(),
                "size": if meta.is_dir() { 0 } else { meta.len() }, "modified": modified,
                "ext": e.path().extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default()
            }));
        }
        out.sort_by(|a, b| {
            let (ad, bd) = (a["dir"].as_bool().unwrap_or(false), b["dir"].as_bool().unwrap_or(false));
            bd.cmp(&ad).then_with(|| a["name"].as_str().unwrap_or("").to_lowercase().cmp(&b["name"].as_str().unwrap_or("").to_lowercase()))
        });
        Ok(out)
    })
    .await;
    let parent = Path::new(&path).parent().map(|p| p.to_string_lossy().to_string()).filter(|s| !s.is_empty());
    match res {
        Ok(Ok(entries)) => Json(json!({ "path": path, "parent": parent.unwrap_or_default(), "entries": entries })).into_response(),
        Ok(Err(e)) => err(StatusCode::FORBIDDEN, &e.to_string()),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "failed"),
    }
}

async fn files_raw(Query(q): Q, req: Request) -> Response {
    let Some(p) = q.get("path") else { return err(StatusCode::BAD_REQUEST, "path") };
    let pb = PathBuf::from(p);
    if !pb.is_file() {
        return err(StatusCode::NOT_FOUND, "not a file");
    }
    let dl = q.get("download").map(|v| v == "1").unwrap_or(false);
    let name = pb.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let mut r = serve_path(pb, req).await;
    if dl {
        if let Ok(v) = format!("attachment; filename=\"{}\"", name.replace('"', "")).parse() {
            r.headers_mut().insert(header::CONTENT_DISPOSITION, v);
        }
    }
    r
}

async fn files_thumb(Query(q): Q) -> Response {
    let Some(p) = q.get("path").cloned() else { return err(StatusCode::BAD_REQUEST, "path") };
    let size: u32 = q.get("s").and_then(|s| s.parse().ok()).unwrap_or(240).clamp(64, 1200);
    thumb_response(config::id_for(&p), p, size).await
}

fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let clean: String = name.chars().map(|c| if r#"\/:*?"<>|"#.contains(c) { '_' } else { c }).collect();
    let clean = if clean.trim().is_empty() { "file".to_string() } else { clean };
    let mut p = dir.join(&clean);
    let stem = Path::new(&clean).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    let ext = Path::new(&clean).extension().map(|s| format!(".{}", s.to_string_lossy())).unwrap_or_default();
    let mut i = 1;
    while p.exists() {
        p = dir.join(format!("{stem} ({i}){ext}"));
        i += 1;
    }
    p
}

async fn write_body(path: &Path, body: Body) -> Result<u64, String> {
    if let Some(d) = path.parent() {
        tokio::fs::create_dir_all(d).await.map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("mgpart");
    let mut f = tokio::fs::File::create(&tmp).await.map_err(|e| e.to_string())?;
    let mut s = body.into_data_stream();
    let mut n = 0u64;
    while let Some(chunk) = s.next().await {
        let c = chunk.map_err(|e| e.to_string())?;
        n += c.len() as u64;
        f.write_all(&c).await.map_err(|e| e.to_string())?;
    }
    f.flush().await.map_err(|e| e.to_string())?;
    drop(f);
    tokio::fs::rename(&tmp, path).await.map_err(|e| e.to_string())?;
    Ok(n)
}

async fn files_upload(Query(q): Q, body: Body) -> Response {
    let (Some(dir), Some(name)) = (q.get("dir"), q.get("name")) else { return err(StatusCode::BAD_REQUEST, "dir & name") };
    let p = unique_path(Path::new(dir), name);
    match write_body(&p, body).await {
        Ok(n) => Json(json!({ "ok": true, "path": p.to_string_lossy(), "size": n })).into_response(),
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

/// Songs sent from the iPhone land in "<first music folder>/From iPhone" and are scanned into the library.
async fn music_upload(State(app): State<Shared>, Query(q): Q, body: Body) -> Response {
    let Some(name) = q.get("name").and_then(|n| Path::new(n).file_name().map(|f| f.to_string_lossy().to_string())) else {
        return err(StatusCode::BAD_REQUEST, "name");
    };
    let ext = Path::new(&name).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    if !["mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma", "alac"].contains(&ext.as_str()) {
        return err(StatusCode::UNSUPPORTED_MEDIA_TYPE, "not an audio file");
    }
    let Some(base) = app.cfg.read().music_dirs.first().cloned() else { return err(StatusCode::CONFLICT, "no music folder set on the PC") };
    let dir = Path::new(&base).join("From iPhone");
    if let Err(e) = tokio::fs::create_dir_all(&dir).await { return err(StatusCode::INTERNAL_SERVER_ERROR, &e.to_string()); }
    let p = unique_path(&dir, &name);
    match write_body(&p, body).await {
        Ok(n) => {
            if q.get("rescan").map(|s| s.as_str()) != Some("0") { app.rescan(); }
            Json(json!({ "ok": true, "size": n })).into_response()
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

// ---------- iPhone as webcam / microphone ----------
// The phone POSTs JPEG frames and 16 kHz mono PCM chunks; the PC re-serves them as an MJPEG stream (/cam.mjpg:
// preview, or an OBS browser/media source -> OBS Virtual Camera for video calls) and a raw PCM stream the desktop UI plays.

static CAM: Lazy<broadcast::Sender<Bytes>> = Lazy::new(|| broadcast::channel(4).0);
static MIC: Lazy<broadcast::Sender<Bytes>> = Lazy::new(|| broadcast::channel(32).0);
static CAM_STATE: Lazy<parking_lot::RwLock<Value>> = Lazy::new(|| parking_lot::RwLock::new(json!({ "camera": false, "mic": false })));

/// The phone's one persistent socket: binary messages, first byte 1 = JPEG frame, 2 = PCM audio.
async fn cam_stream(ws: WebSocketUpgrade, State(app): State<Shared>) -> Response {
    if !app.cfg.read().accept_phone_stream { return err(StatusCode::FORBIDDEN, "Accepting the iPhone camera and mic is turned off in the PC app (Settings)."); }
    ws.on_upgrade(|mut socket| async move {
        while let Some(Ok(msg)) = socket.recv().await {
            if let Message::Binary(b) = msg {
                if b.len() < 2 { continue; }
                match b[0] {
                    1 => { let _ = CAM.send(b.slice(1..)); }
                    2 => { let _ = MIC.send(b.slice(1..)); }
                    _ => {}
                }
            }
        }
    })
}

async fn cam_frame(State(app): State<Shared>, body: Bytes) -> Json<Value> {
    if !app.cfg.read().accept_phone_stream { return Json(json!({ "ok": false })); }
    let _ = CAM.send(body); // no viewers = nobody to send to; not an error
    Json(json!({ "ok": true }))
}

async fn cam_audio_in(State(app): State<Shared>, body: Bytes) -> Json<Value> {
    if !app.cfg.read().accept_phone_stream { return Json(json!({ "ok": false })); }
    let _ = MIC.send(body);
    Json(json!({ "ok": true }))
}

/// Frames for the virtual webcam worker (vcam.rs).
pub fn cam_subscribe() -> broadcast::Receiver<Bytes> {
    CAM.subscribe()
}

async fn vcam_status() -> Json<Value> {
    Json(crate::vcam::status())
}

/// Turn the virtual webcam on/off and/or flip the picture.
async fn vcam_set(Json(b): Json<Value>) -> Json<Value> {
    if let Some(f) = b["flip"].as_bool() { crate::vcam::set_flip(f); }
    if let Some(on) = b["on"].as_bool() { crate::vcam::set_on(on); }
    Json(crate::vcam::status())
}

/// One-time registration of the virtual camera (Windows shows a UAC prompt). Only the PC app itself may ask for it.
async fn vcam_install(State(app): State<Shared>, axum::Extension(w): axum::Extension<Who>) -> Response {
    if w.0 != app.ui_token { return err(StatusCode::FORBIDDEN, "Only the PC app can install the virtual camera."); }
    match tokio::task::spawn_blocking(crate::vcam::install).await {
        Ok(Ok(())) => Json(crate::vcam::status()).into_response(),
        Ok(Err(e)) => err(StatusCode::CONFLICT, &e),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "install failed"),
    }
}

async fn cam_state_set(State(app): State<Shared>, Json(b): Json<Value>) -> Json<Value> {
    if !app.cfg.read().accept_phone_stream { return Json(json!({ "ok": false })); }
    let v = json!({ "camera": b["camera"].as_bool().unwrap_or(false), "mic": b["mic"].as_bool().unwrap_or(false) });
    // once registered, the iPhone camera simply becomes the PC's webcam
    if crate::vcam::installed() { crate::vcam::set_on(v["camera"].as_bool().unwrap_or(false)); }
    *CAM_STATE.write() = v.clone();
    app.ui("cam", v);
    Json(json!({ "ok": true }))
}

async fn cam_state_get() -> Json<Value> {
    Json(CAM_STATE.read().clone())
}

/// Long-lived response that forwards every broadcast chunk (optionally wrapped as an MJPEG part).
fn live(rx: broadcast::Receiver<Bytes>, content_type: &'static str, mjpeg: bool) -> Response {
    let s = futures_util::stream::unfold(rx, move |mut rx| async move {
        loop {
            match rx.recv().await {
                Ok(chunk) => {
                    let out = if mjpeg {
                        let mut b = format!("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n", chunk.len()).into_bytes();
                        b.extend_from_slice(&chunk);
                        b.extend_from_slice(b"\r\n");
                        Bytes::from(b)
                    } else {
                        chunk
                    };
                    return Some((Ok::<Bytes, std::convert::Infallible>(out), rx));
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue, // slow viewer: skip ahead
                Err(_) => return None,
            }
        }
    });
    ([(header::CONTENT_TYPE, content_type), (header::CACHE_CONTROL, "no-store")], Body::from_stream(s)).into_response()
}

async fn cam_mjpeg() -> Response {
    live(CAM.subscribe(), "multipart/x-mixed-replace; boundary=frame", true)
}

async fn cam_audio_out() -> Response {
    live(MIC.subscribe(), "application/octet-stream", false)
}

// ---------- clipboard & shared ----------

async fn clip_get(State(app): State<Shared>) -> Json<Value> {
    Json(json!({ "text": app.last_clip.lock().clone() }))
}

#[derive(Deserialize)]
struct TextBody {
    text: String,
}

fn who_name(app: &Shared, w: &Who) -> String {
    if w.0 == app.ui_token { return "pc".into(); }
    app.cfg.read().tokens.get(&w.0).cloned().unwrap_or_else(|| "iPhone".into())
}

async fn clip_set(State(app): State<Shared>, axum::Extension(w): axum::Extension<Who>, Json(b): Json<TextBody>) -> Json<Value> {
    if b.text.is_empty() { return Json(json!({ "ok": false })); }
    *app.last_clip.lock() = b.text.clone();
    crate::clip::set_text(&b.text);
    let from = who_name(&app, &w);
    app.add_shared(SharedItem { id: random_hex(8), kind: "clipboard".into(), text: Some(b.text), name: None, size: None, path: None, from, at: now_ms() });
    Json(json!({ "ok": true }))
}

/// Put text on the PC clipboard without syncing it anywhere (copying from the history list).
async fn clip_silent(State(app): State<Shared>, Json(b): Json<TextBody>) -> Json<Value> {
    if !b.text.is_empty() {
        *app.last_clip.lock() = b.text.clone();
        crate::clip::set_text(&b.text);
    }
    Json(json!({ "ok": true }))
}

async fn call_get(State(app): State<Shared>) -> Json<Value> {
    let current = app.call.read().clone();
    let log = app.calls.read().clone();
    Json(json!({ "current": current, "log": log }))
}

/// The phone reports its call state; the PC shows a floating bubble while the call lasts.
async fn call_set(State(app): State<Shared>, axum::Extension(w): axum::Extension<Who>, Json(b): Json<Value>) -> Json<Value> {
    let device = who_name(&app, &w);
    let v = app.set_call(&b, &device);
    app.ui("call", v.clone());
    let a = app.clone();
    if v["state"] == "ended" {
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(3500)).await;
            a.call_bubble(false);
        });
    } else if !v.is_null() {
        app.call_bubble(true);
        // the bubble window may finish loading after the first event: repeat the current state
        tokio::spawn(async move {
            for ms in [700u64, 2000] {
                tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
                let cur = a.call.read().clone();
                if !cur.is_null() {
                    a.ui("call", cur);
                }
            }
        });
    }
    Json(json!({ "ok": true }))
}

async fn shared_list(State(app): State<Shared>) -> Json<Value> {
    Json(json!(*app.shared.read()))
}

async fn shared_text(State(app): State<Shared>, axum::Extension(w): axum::Extension<Who>, Json(b): Json<TextBody>) -> Json<Value> {
    let from = who_name(&app, &w);
    if from != "pc" && !b.text.is_empty() {
        // text sent from the phone is ready to paste on the PC
        *app.last_clip.lock() = b.text.clone();
        crate::clip::set_text(&b.text);
        let preview: String = b.text.chars().take(120).collect();
        app.notify(&format!("Text from {from} — copied"), &preview);
    }
    app.add_shared(SharedItem { id: random_hex(8), kind: "text".into(), text: Some(b.text), name: None, size: None, path: None, from, at: now_ms() });
    Json(json!({ "ok": true }))
}

async fn shared_file_up(State(app): State<Shared>, axum::Extension(w): axum::Extension<Who>, Query(q): Q, body: Body) -> Response {
    let name = q.get("name").cloned().unwrap_or_else(|| "file".into());
    let dir = PathBuf::from(app.cfg.read().inbox_dir.clone());
    let p = unique_path(&dir, &name);
    match write_body(&p, body).await {
        Ok(n) => {
            let from = who_name(&app, &w);
            let item = SharedItem {
                id: random_hex(8), kind: "file".into(), text: None,
                name: p.file_name().map(|s| s.to_string_lossy().to_string()), size: Some(n),
                path: Some(p.to_string_lossy().to_string()), from, at: now_ms(),
            };
            app.add_shared(item.clone());
            if item.from != "pc" {
                app.notify(&format!("File from {}", item.from), item.name.as_deref().unwrap_or("file"));
            }
            Json(json!(item)).into_response()
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

async fn shared_file_get(State(app): State<Shared>, AxPath(id): AxPath<String>, req: Request) -> Response {
    let p = app.shared.read().iter().find(|s| s.id == id).and_then(|s| s.path.clone());
    match p {
        Some(p) => serve_path(p.into(), req).await,
        None => err(StatusCode::NOT_FOUND, "gone"),
    }
}

// ---------- photo sync from iPhone ----------

async fn photos_synced(State(app): State<Shared>) -> Json<Value> {
    let s = app.synced.lock();
    Json(json!(s.iter().collect::<Vec<_>>()))
}

async fn photos_upload(State(app): State<Shared>, Query(q): Q, body: Body) -> Response {
    let (Some(asset), Some(name)) = (q.get("asset").cloned(), q.get("name").cloned()) else {
        return err(StatusCode::BAD_REQUEST, "asset & name");
    };
    if app.synced.lock().contains(&asset) {
        return Json(json!({ "ok": true, "skipped": true })).into_response();
    }
    let created: i64 = q.get("created").and_then(|s| s.parse().ok()).unwrap_or_else(|| chrono::Utc::now().timestamp());
    let month = chrono::DateTime::from_timestamp(created, 0)
        .map(|d| d.format("%Y-%m").to_string())
        .unwrap_or_else(|| "Unsorted".into());
    let dir = PathBuf::from(app.cfg.read().photo_sync_dir.clone()).join(month);
    let p = unique_path(&dir, &name);
    match write_body(&p, body).await {
        Ok(_) => {
            {
                let mut s = app.synced.lock();
                s.insert(asset);
                config::save_synced(&s);
            }
            // file date = when the photo was taken, so it sorts correctly everywhere
            if let Ok(f) = std::fs::File::options().write(true).open(&p) {
                let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(created.max(0) as u64);
                let _ = f.set_modified(t);
            }
            let added = app.lib.write().add_media(&p, true);
            app.photo_received();
            app.ui("photo", json!({ "name": name, "item": added }));
            Json(json!({ "ok": true })).into_response()
        }
        Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, &e),
    }
}

// ---------- remote control ----------

async fn control_http(State(app): State<Shared>, Json(c): Json<Cmd>) -> Response {
    if !app.cfg.read().remote_control {
        return err(StatusCode::FORBIDDEN, "Remote control is turned off on the PC.");
    }
    control::send(c);
    Json(json!({ "ok": true })).into_response()
}

async fn screen(State(app): State<Shared>, Query(q): Q) -> Response {
    if !app.cfg.read().remote_control {
        return err(StatusCode::FORBIDDEN, "Remote control is turned off on the PC.");
    }
    let w: u32 = q.get("w").and_then(|s| s.parse().ok()).unwrap_or(1280).clamp(320, 3840);
    let quality: u8 = q.get("q").and_then(|s| s.parse().ok()).unwrap_or(60).clamp(20, 95);
    match tokio::task::spawn_blocking(move || control::screenshot(w, quality)).await {
        Ok(Some(b)) => ([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "no-store")], b).into_response(),
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "capture failed"),
    }
}

/// H.264 desktop stream over a WebSocket (binary = one Annex-B access unit; the phone sends the text "key" to ask for a full frame).
async fn screen_stream(ws: WebSocketUpgrade, State(app): State<Shared>, Query(q): Q) -> Response {
    if !app.cfg.read().remote_control {
        return err(StatusCode::FORBIDDEN, "Remote control is turned off on the PC.");
    }
    let num = |k: &str, d: u32, lo: u32, hi: u32| q.get(k).and_then(|s| s.parse().ok()).unwrap_or(d).clamp(lo, hi);
    let (w, fps, kbps) = (num("w", 1280, 320, 3840), num("fps", 30, 5, 60), num("kbps", 5000, 500, 40_000));
    ws.on_upgrade(move |mut socket| async move {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(3);
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let key = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        {
            let (stop, key) = (stop.clone(), key.clone());
            std::thread::spawn(move || control::stream_h264(w, fps, kbps, tx, stop, key));
        }
        loop {
            tokio::select! {
                Some(frame) = rx.recv() => {
                    if socket.send(Message::Binary(frame.into())).await.is_err() { break; }
                }
                m = socket.recv() => match m {
                    Some(Ok(Message::Text(t))) if t.as_str() == "key" => key.store(true, std::sync::atomic::Ordering::Relaxed),
                    None | Some(Err(_)) | Some(Ok(Message::Close(_))) => break,
                    _ => {}
                },
            }
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
    })
}

/// What the PC app currently allows, so the phone can explain a refusal instead of failing silently.
async fn stream_options(State(app): State<Shared>) -> Json<Value> {
    let c = app.cfg.read();
    Json(json!({ "acceptPhoneStream": c.accept_phone_stream, "sharePcAudio": c.share_pc_audio && c.remote_control }))
}

/// PC sound over a WebSocket: see control::stream_audio for the message format.
async fn audio_stream(ws: WebSocketUpgrade, State(app): State<Shared>) -> Response {
    if !app.cfg.read().remote_control || !app.cfg.read().share_pc_audio {
        return err(StatusCode::FORBIDDEN, "Sharing PC sound is turned off in the PC app (Settings).");
    }
    ws.on_upgrade(|mut socket| async move {
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        {
            let stop = stop.clone();
            std::thread::spawn(move || control::stream_audio(tx, stop));
        }
        loop {
            tokio::select! {
                Some(chunk) = rx.recv() => {
                    if socket.send(Message::Binary(chunk.into())).await.is_err() { break; }
                }
                m = socket.recv() => match m {
                    None | Some(Err(_)) | Some(Ok(Message::Close(_))) => break,
                    _ => {}
                },
            }
        }
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
    })
}

/// Lock the PC when a paired iPhone has been gone for the chosen time (opt-in, one lock per absence).
static AWAY_LOCKED: Lazy<parking_lot::Mutex<std::collections::HashSet<String>>> = Lazy::new(Default::default);

async fn presence_loop(app: Shared) {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(10)).await;
        let (on, mins) = {
            let c = app.cfg.read();
            (c.lock_when_away, c.away_minutes)
        };
        if !on { continue; }
        let now = now_ms();
        let mut locked = AWAY_LOCKED.lock();
        for (t, d) in app.devices.read().iter() {
            if d.connected {
                locked.remove(t);
            } else if d.last_seen > 0 && now - d.last_seen > mins as i64 * 60_000 && locked.insert(t.clone()) {
                control::send(Cmd::Power { action: "lock".into() });
            }
        }
    }
}

async fn presence_get(State(app): State<Shared>) -> Json<Value> {
    let c = app.cfg.read();
    Json(json!({ "lock": c.lock_when_away, "minutes": c.away_minutes }))
}

async fn presence_set(State(app): State<Shared>, axum::Extension(w): axum::Extension<Who>, Json(b): Json<Value>) -> Response {
    if w.0 != app.ui_token { return err(StatusCode::FORBIDDEN, "Only the PC app can change this."); }
    {
        let mut c = app.cfg.write();
        if let Some(v) = b["lock"].as_bool() { c.lock_when_away = v; }
        if let Some(m) = b["minutes"].as_u64() { c.away_minutes = (m as u32).clamp(1, 120); }
        c.save();
    }
    presence_get(State(app)).await.into_response()
}

async fn lyrics(State(app): State<Shared>, AxPath(id): AxPath<String>) -> Json<Value> {
    let t = app.lib.read().track(&id).map(|t| (t.artist.clone(), t.title.clone(), t.album.clone(), t.duration));
    let Some((artist, title, album, dur)) = t else { return Json(json!({})) };
    let v = tokio::task::spawn_blocking(move || crate::lyrics::get(&id, &artist, &title, &album, dur)).await.unwrap_or_else(|_| json!({}));
    Json(v)
}

/// The phone asks the PC's own player to play / queue songs.
async fn pc_play(State(app): State<Shared>, Json(b): Json<Value>) -> Json<Value> {
    app.ui("pcplay", b);
    Json(json!({ "ok": true }))
}

async fn playlists_get(State(app): State<Shared>) -> Json<Value> {
    let v = app.playlists.read().clone();
    Json(v)
}

/// Last writer wins: a device posts its whole playlist list after it changes one.
async fn playlists_set(State(app): State<Shared>, Json(b): Json<Value>) -> Response {
    if !b.is_array() {
        return err(StatusCode::BAD_REQUEST, "expected a JSON array of playlists");
    }
    *app.playlists.write() = b.clone();
    if let Ok(j) = serde_json::to_string(&b) {
        let _ = std::fs::write(config::data_dir().join("playlists.json"), j);
    }
    app.ui("playlists", b.clone());
    app.push(json!({ "event": "playlists", "playlists": b }));
    Json(json!({ "ok": true })).into_response()
}

async fn playback_get(State(app): State<Shared>) -> Json<Value> {
    let v = app.playback.read().clone();
    Json(v)
}

async fn playback_set(State(app): State<Shared>, Json(b): Json<Value>) -> Json<Value> {
    let v = app.set_playback(&b);
    app.ui("playback", v.clone());
    app.push(json!({ "event": "playback", "playback": v.clone() }));
    Json(v)
}

async fn devices(State(app): State<Shared>) -> Json<Value> {
    let paired: Vec<Value> = app.cfg.read().tokens.iter().map(|(t, n)| {
        let d = app.devices.read().get(t).cloned();
        json!({ "token": &t[..6], "name": n, "status": d })
    }).collect();
    Json(json!(paired))
}

/// From the desktop UI: send a command to the phone(s) (player control, find, etc).
async fn phone_cmd(State(app): State<Shared>, Json(v): Json<Value>) -> Json<Value> {
    app.push(json!({ "event": "command", "command": v }));
    Json(json!({ "ok": true }))
}

// ---------- websocket ----------

async fn ws(
    State(app): State<Shared>,
    axum::Extension(w): axum::Extension<Who>,
    axum::extract::ConnectInfo(addr): axum::extract::ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    up: WebSocketUpgrade,
) -> Response {
    let _ = headers;
    up.on_upgrade(move |s| ws_loop(app, w.0, addr.ip().to_string(), s))
}

async fn ws_loop(app: Shared, token: String, ip: String, socket: WebSocket) {
    let is_ui = token == app.ui_token;
    let name = app.cfg.read().tokens.get(&token).cloned().unwrap_or_else(|| "iPhone".into());
    if !is_ui {
        let mut d = app.devices.write();
        let e = d.entry(token.clone()).or_insert_with(Device::default);
        e.name = name.clone();
        e.connected = true;
        e.last_seen = now_ms();
        e.address = ip;
        drop(d);
        app.ui("devices", json!({}));
    }
    let (mut tx, mut rx) = socket.split();
    let mut events = app.events.subscribe();
    let hello = json!({ "event": "hello", "clipboard": app.last_clip.lock().clone() }).to_string();
    let _ = tx.send(Message::Text(hello.into())).await;

    let send_task = tokio::spawn(async move {
        loop {
            match events.recv().await {
                Ok(m) => {
                    if tx.send(Message::Text(m.into())).await.is_err() { break; }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(_) => break,
            }
        }
    });

    while let Some(Ok(msg)) = rx.next().await {
        let Message::Text(t) = msg else { continue };
        let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
        match v["type"].as_str().unwrap_or("") {
            "status" => {
                let mut d = app.devices.write();
                if let Some(e) = d.get_mut(&token) {
                    e.model = v["model"].as_str().unwrap_or("").into();
                    e.battery = v["battery"].as_f64().unwrap_or(-1.0);
                    e.charging = v["charging"].as_bool().unwrap_or(false);
                    e.now_playing = v.get("nowPlaying").cloned().filter(|x| !x.is_null());
                    e.last_seen = now_ms();
                }
                drop(d);
                app.ui("devices", json!({}));
            }
            "ping" => {}
            _ => {
                if app.cfg.read().remote_control {
                    if let Ok(c) = serde_json::from_value::<Cmd>(v) {
                        control::send(c);
                    }
                }
            }
        }
    }
    send_task.abort();
    if !is_ui {
        if let Some(e) = app.devices.write().get_mut(&token) {
            e.connected = false;
            e.last_seen = now_ms(); // when it went away (nearby lock)
        }
        app.ui("devices", json!({}));
    }
}
