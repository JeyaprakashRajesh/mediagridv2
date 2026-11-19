//! Virtual webcam: the iPhone's camera frames are fed into the "softcam" DirectShow filter
//! (https://github.com/tshino/softcam, built in CI and bundled as softcam.dll), which shows up in Zoom, Teams, Chrome,
//! OBS... as the camera "DirectShow Softcam". Registering the filter needs administrator rights once (UAC prompt).
//! Windows only; other platforms get inert stubs so `cargo check` passes everywhere.
use serde_json::{json, Value};

#[cfg(target_os = "windows")]
mod imp {
    use libloading::{Library, Symbol};
    use std::{
        ffi::c_void,
        os::windows::process::CommandExt,
        path::PathBuf,
        process::Command,
        sync::atomic::{AtomicBool, Ordering},
        time::Duration,
    };
    use tokio::sync::broadcast::error::TryRecvError;

    pub static ON: AtomicBool = AtomicBool::new(false);
    pub static FLIP: AtomicBool = AtomicBool::new(false);

    type Create = unsafe extern "C" fn(i32, i32, f32) -> *mut c_void;
    type Delete = unsafe extern "C" fn(*mut c_void);
    type Send = unsafe extern "C" fn(*mut c_void, *const c_void);

    /// softcam.dll next to the app (bundled resource); an empty placeholder file counts as missing.
    pub fn dll_path() -> Option<PathBuf> {
        let dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
        [dir.join("resources").join("softcam.dll"), dir.join("softcam.dll")]
            .into_iter()
            .find(|p| std::fs::metadata(p).map(|m| m.len() > 0).unwrap_or(false))
    }

    fn marker() -> PathBuf {
        crate::config::cache_dir().join("vcam.registered")
    }

    /// Registered for the DLL at its current location?
    pub fn installed() -> bool {
        match (dll_path(), std::fs::read_to_string(marker())) {
            (Some(p), Ok(m)) => m.trim() == p.to_string_lossy(),
            _ => false,
        }
    }

    /// Registers the DirectShow filter (regsvr32 as administrator: Windows shows a UAC prompt).
    pub fn install() -> Result<(), String> {
        let p = dll_path().ok_or("The virtual camera component is not part of this build.")?;
        let script = format!(
            "$p = Start-Process regsvr32.exe -ArgumentList '/s','\"{}\"' -Verb RunAs -Wait -PassThru; exit $p.ExitCode",
            p.display()
        );
        let ok = Command::new("powershell")
            .args(["-NoProfile", "-Command", &script])
            .creation_flags(0x0800_0000)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok {
            return Err("The virtual camera was not installed (the administrator prompt was cancelled or registration failed).".into());
        }
        let _ = std::fs::write(marker(), p.to_string_lossy().as_bytes());
        Ok(())
    }

    pub fn set_on(on: bool) {
        if on {
            if !ON.swap(true, Ordering::SeqCst) {
                std::thread::spawn(run);
            }
        } else {
            ON.store(false, Ordering::SeqCst);
        }
    }

    fn run() {
        let Some(path) = dll_path() else { ON.store(false, Ordering::SeqCst); return };
        let Ok(lib) = (unsafe { Library::new(&path) }) else { ON.store(false, Ordering::SeqCst); return };
        let (create, delete, send): (Symbol<Create>, Symbol<Delete>, Symbol<Send>) = unsafe {
            match (lib.get(b"scCreateCamera\0"), lib.get(b"scDeleteCamera\0"), lib.get(b"scSendFrame\0")) {
                (Ok(a), Ok(b), Ok(c)) => (a, b, c),
                _ => { ON.store(false, Ordering::SeqCst); return }
            }
        };
        let mut rx = crate::server::cam_subscribe();
        let mut cam: *mut c_void = std::ptr::null_mut();
        let (mut w, mut h) = (0usize, 0usize);
        while ON.load(Ordering::SeqCst) {
            // newest frame only: a slow moment must not build up delay
            let mut jpeg = None;
            loop {
                match rx.try_recv() {
                    Ok(b) => jpeg = Some(b),
                    Err(TryRecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
            let Some(jpeg) = jpeg else { std::thread::sleep(Duration::from_millis(4)); continue };
            let Ok(img) = image::load_from_memory_with_format(&jpeg, image::ImageFormat::Jpeg) else { continue };
            let mut rgb = img.to_rgb8();
            if cam.is_null() {
                // softcam wants sizes that are multiples of four
                w = rgb.width() as usize & !3;
                h = rgb.height() as usize & !3;
                if w == 0 || h == 0 { continue }
                cam = unsafe { create(w as i32, h as i32, 30.0) };
                if cam.is_null() { ON.store(false, Ordering::SeqCst); break } // another program already owns the camera
            }
            if rgb.width() as usize != w || rgb.height() as usize != h {
                rgb = image::imageops::resize(&rgb, w as u32, h as u32, image::imageops::FilterType::Triangle);
            }
            // DirectShow RGB24 = BGR; flip only if the picture shows up upside down
            let flip = FLIP.load(Ordering::Relaxed);
            let src = rgb.as_raw();
            let mut out = vec![0u8; w * h * 3];
            for y in 0..h {
                let sy = if flip { h - 1 - y } else { y };
                let (s, d) = (&src[sy * w * 3..(sy + 1) * w * 3], &mut out[y * w * 3..(y + 1) * w * 3]);
                for x in 0..w {
                    d[x * 3] = s[x * 3 + 2];
                    d[x * 3 + 1] = s[x * 3 + 1];
                    d[x * 3 + 2] = s[x * 3];
                }
            }
            unsafe { send(cam, out.as_ptr() as *const c_void) };
        }
        if !cam.is_null() {
            unsafe { delete(cam) };
        }
        ON.store(false, Ordering::SeqCst);
    }
}

#[cfg(not(target_os = "windows"))]
mod imp {
    use std::sync::atomic::AtomicBool;
    pub static ON: AtomicBool = AtomicBool::new(false);
    pub static FLIP: AtomicBool = AtomicBool::new(false);
    pub fn dll_path() -> Option<std::path::PathBuf> { None }
    pub fn installed() -> bool { false }
    pub fn install() -> Result<(), String> { Err("The virtual camera is Windows only.".into()) }
    pub fn set_on(_on: bool) {}
}

use std::sync::atomic::Ordering;

pub fn install() -> Result<(), String> { imp::install() }
pub fn installed() -> bool { imp::installed() }
pub fn set_on(on: bool) { imp::set_on(on) }
pub fn set_flip(f: bool) { imp::FLIP.store(f, Ordering::Relaxed) }

pub fn status() -> Value {
    json!({
        "available": imp::dll_path().is_some(),
        "installed": imp::installed(),
        "on": imp::ON.load(Ordering::SeqCst),
        "flip": imp::FLIP.load(Ordering::Relaxed),
    })
}
