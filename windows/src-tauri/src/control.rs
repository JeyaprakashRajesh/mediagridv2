//! Remote control of this PC: mouse, keyboard, media keys, power and screen capture.
use enigo::{Axis, Button, Coordinate, Direction, Enigo, Key, Keyboard, Mouse, Settings};
use once_cell::sync::Lazy;
use serde::Deserialize;
use std::sync::mpsc::{channel, Sender};

#[derive(Deserialize, Debug, Clone)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Cmd {
    Move { dx: f64, dy: f64 },
    Moveabs { x: f64, y: f64 },
    Click { #[serde(default)] button: String, #[serde(default)] double: bool },
    Down { #[serde(default)] button: String },
    Up { #[serde(default)] button: String },
    Scroll { #[serde(default)] dx: f64, #[serde(default)] dy: f64 },
    Key { key: String },
    Text { text: String },
    Media { action: String },
    Power { action: String },
}

static TX: Lazy<Sender<Cmd>> = Lazy::new(|| {
    let (tx, rx) = channel::<Cmd>();
    std::thread::spawn(move || {
        let Ok(mut en) = Enigo::new(&Settings::default()) else { return };
        let mut acc_x = 0.0f64;
        let mut acc_y = 0.0f64;
        let mut acc_s = 0.0f64;
        while let Ok(c) = rx.recv() {
            match c {
                Cmd::Move { dx, dy } => {
                    acc_x += dx;
                    acc_y += dy;
                    let (ix, iy) = (acc_x.trunc() as i32, acc_y.trunc() as i32);
                    acc_x -= ix as f64;
                    acc_y -= iy as f64;
                    if ix != 0 || iy != 0 {
                        let _ = en.move_mouse(ix, iy, Coordinate::Rel);
                    }
                }
                Cmd::Moveabs { x, y } => {
                    if let Some((mx, my, mw, mh)) = primary_rect() {
                        let px = mx + (x.clamp(0.0, 1.0) * mw as f64) as i32;
                        let py = my + (y.clamp(0.0, 1.0) * mh as f64) as i32;
                        let _ = en.move_mouse(px, py, Coordinate::Abs);
                    }
                }
                Cmd::Click { button, double } => {
                    let b = btn(&button);
                    let _ = en.button(b, Direction::Click);
                    if double {
                        let _ = en.button(b, Direction::Click);
                    }
                }
                Cmd::Down { button } => { let _ = en.button(btn(&button), Direction::Press); }
                Cmd::Up { button } => { let _ = en.button(btn(&button), Direction::Release); }
                Cmd::Scroll { dx, dy } => {
                    acc_s += dy;
                    let n = acc_s.trunc() as i32;
                    acc_s -= n as f64;
                    if n != 0 { let _ = en.scroll(n, Axis::Vertical); }
                    let h = dx.round() as i32;
                    if h != 0 { let _ = en.scroll(h, Axis::Horizontal); }
                }
                Cmd::Key { key } => press_combo(&mut en, &key),
                Cmd::Text { text } => { let _ = en.text(&text); }
                Cmd::Media { action } => media(&mut en, &action),
                Cmd::Power { action } => power(&action),
            }
        }
    });
    tx
});

pub fn send(c: Cmd) {
    let _ = TX.send(c);
}

fn btn(s: &str) -> Button {
    match s {
        "right" => Button::Right,
        "middle" => Button::Middle,
        _ => Button::Left,
    }
}

fn named_key(k: &str) -> Option<Key> {
    Some(match k.to_lowercase().as_str() {
        "enter" | "return" => Key::Return,
        "backspace" => Key::Backspace,
        "tab" => Key::Tab,
        "esc" | "escape" => Key::Escape,
        "space" => Key::Space,
        "delete" | "del" => Key::Delete,
        "up" => Key::UpArrow,
        "down" => Key::DownArrow,
        "left" => Key::LeftArrow,
        "right" => Key::RightArrow,
        "home" => Key::Home,
        "end" => Key::End,
        "pageup" => Key::PageUp,
        "pagedown" => Key::PageDown,
        "ctrl" | "control" => Key::Control,
        "alt" => Key::Alt,
        "shift" => Key::Shift,
        "win" | "meta" | "cmd" => Key::Meta,
        "f1" => Key::F1, "f2" => Key::F2, "f3" => Key::F3, "f4" => Key::F4,
        "f5" => Key::F5, "f6" => Key::F6, "f7" => Key::F7, "f8" => Key::F8,
        "f9" => Key::F9, "f10" => Key::F10, "f11" => Key::F11, "f12" => Key::F12,
        s if s.chars().count() == 1 => Key::Unicode(s.chars().next().unwrap()),
        _ => return None,
    })
}

/// "ctrl+shift+esc", "alt+tab", "win+d", "enter"
fn press_combo(en: &mut Enigo, combo: &str) {
    let keys: Vec<Key> = combo.split('+').filter_map(|p| named_key(p.trim())).collect();
    if keys.is_empty() { return; }
    let (last, mods) = keys.split_last().unwrap();
    for m in mods { let _ = en.key(*m, Direction::Press); }
    let _ = en.key(*last, Direction::Click);
    for m in mods.iter().rev() { let _ = en.key(*m, Direction::Release); }
}

#[cfg(target_os = "windows")]
fn media(en: &mut Enigo, a: &str) {
    let k = match a {
        "playpause" => Key::MediaPlayPause,
        "next" => Key::MediaNextTrack,
        "prev" => Key::MediaPrevTrack,
        "volup" => Key::VolumeUp,
        "voldown" => Key::VolumeDown,
        "mute" => Key::VolumeMute,
        _ => return,
    };
    let _ = en.key(k, Direction::Click);
}

#[cfg(not(target_os = "windows"))]
fn media(_en: &mut Enigo, _a: &str) {}

fn power(a: &str) {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const NO_WINDOW: u32 = 0x0800_0000;
        let (prog, args): (&str, Vec<&str>) = match a {
            "lock" => ("rundll32.exe", vec!["user32.dll,LockWorkStation"]),
            "sleep" => ("rundll32.exe", vec!["powrprof.dll,SetSuspendState", "0,1,0"]),
            "shutdown" => ("shutdown", vec!["/s", "/t", "0"]),
            "restart" => ("shutdown", vec!["/r", "/t", "0"]),
            "signout" => ("shutdown", vec!["/l"]),
            "screenoff" => (
                "powershell",
                vec!["-NoProfile", "-Command", "(Add-Type '[DllImport(\"user32.dll\")]public static extern int SendMessage(int a,int b,int c,int d);' -Name a -Pas)::SendMessage(-1,0x0112,0xF170,2)"],
            ),
            _ => return,
        };
        let _ = std::process::Command::new(prog).args(args).creation_flags(NO_WINDOW).spawn();
    }
    #[cfg(not(target_os = "windows"))]
    let _ = a;
}

fn primary_rect() -> Option<(i32, i32, u32, u32)> {
    let mons = xcap::Monitor::all().ok()?;
    let m = mons
        .iter()
        .find(|m| m.is_primary().unwrap_or(false))
        .or_else(|| mons.first())?;
    Some((m.x().ok()?, m.y().ok()?, m.width().ok()?, m.height().ok()?))
}

/// JPEG screenshot of the primary monitor scaled to `max_w`.
pub fn screenshot(max_w: u32, quality: u8) -> Option<Vec<u8>> {
    let mons = xcap::Monitor::all().ok()?;
    let m = mons
        .iter()
        .find(|m| m.is_primary().unwrap_or(false))
        .or_else(|| mons.first())?;
    let cap = m.capture_image().ok()?;
    let (w, h) = (cap.width(), cap.height());
    let rgba = image::RgbaImage::from_raw(w, h, cap.into_raw())?;
    let img = image::DynamicImage::ImageRgba8(rgba);
    let img = if w > max_w {
        img.resize(max_w, (h as f64 * max_w as f64 / w as f64) as u32, image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let mut out = Vec::new();
    let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality);
    enc.encode_image(&img.to_rgb8()).ok()?;
    Some(out)
}
