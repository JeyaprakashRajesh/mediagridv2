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
    /// Essential PC controls: volstep (value = key presses, +/-), brightness (0-100), wifi / bluetooth (1 = on).
    Sys { action: String, #[serde(default)] value: f64 },
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
                Cmd::Sys { action, value } => sys(&mut en, &action, value),
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

#[cfg(target_os = "windows")]
fn sys(en: &mut Enigo, a: &str, v: f64) {
    use std::os::windows::process::CommandExt;
    const NO_WINDOW: u32 = 0x0800_0000;
    let on = v >= 0.5;
    let script = match a {
        "volstep" => {
            let n = v.round() as i32;
            let k = if n >= 0 { Key::VolumeUp } else { Key::VolumeDown };
            for _ in 0..n.abs().min(50) { let _ = en.key(k, Direction::Click); }
            return;
        }
        "brightness" => format!("(Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods).WmiSetBrightness(1,{})", v.clamp(0.0, 100.0) as i32),
        // needs the PC app to run as administrator; fails quietly otherwise
        "wifi" => format!("netsh interface set interface name=\"Wi-Fi\" admin={}", if on { "enabled" } else { "disabled" }),
        "bluetooth" => format!(
            "Add-Type -AssemblyName System.Runtime.WindowsRuntime; \
             $t=([System.WindowsRuntimeSystemExtensions].GetMethods()|?{{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'}})[0]; \
             function Aw($x,$r){{$n=$t.MakeGenericMethod($r).Invoke($null,@($x));$n.Wait(-1)|Out-Null;$n.Result}}; \
             [Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime]|Out-Null; \
             [Windows.Devices.Radios.RadioAccessStatus,Windows.System.Devices,ContentType=WindowsRuntime]|Out-Null; \
             Aw ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus])|Out-Null; \
             $r=Aw ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]]); \
             $b=$r|?{{$_.Kind -eq 'Bluetooth'}}; \
             [Windows.Devices.Radios.RadioState,Windows.System.Devices,ContentType=WindowsRuntime]|Out-Null; \
             Aw ($b.SetStateAsync('{}')) ([Windows.Devices.Radios.RadioAccessStatus])|Out-Null",
            if on { "On" } else { "Off" }
        ),
        _ => return,
    };
    let _ = std::process::Command::new("powershell").args(["-NoProfile", "-WindowStyle", "Hidden", "-Command", &script]).creation_flags(NO_WINDOW).spawn();
}

#[cfg(not(target_os = "windows"))]
fn sys(_en: &mut Enigo, _a: &str, _v: f64) {}

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

/// Parsec-style screen stream: captures the primary monitor, encodes H.264 (low-latency, screen-content tuned) and
/// sends one Annex-B access unit per message. Static screens send nothing; a full frame is forced when `key` is set.
/// Runs on its own thread until `stop` is set or the receiver is gone.
pub fn stream_h264(
    max_w: u32,
    fps: u32,
    kbps: u32,
    tx: tokio::sync::mpsc::Sender<Vec<u8>>,
    stop: std::sync::Arc<std::sync::atomic::AtomicBool>,
    key: std::sync::Arc<std::sync::atomic::AtomicBool>,
) {
    use openh264::encoder::{Encoder, EncoderConfig};
    use openh264::formats::YUVBuffer;
    use std::sync::atomic::Ordering;
    use std::time::{Duration, Instant};

    let Ok(mons) = xcap::Monitor::all() else { return };
    let Some(m) = mons.iter().find(|m| m.is_primary().unwrap_or(false)).or_else(|| mons.first()) else { return };
    let step = Duration::from_micros(1_000_000 / fps.clamp(5, 60) as u64);
    let mut enc: Option<Encoder> = None;
    let mut dims = (0u32, 0u32);
    let mut last_sig = 0u64;
    let mut last_sent = Instant::now();

    while !stop.load(Ordering::Relaxed) {
        let t0 = Instant::now();
        let Ok(cap) = m.capture_image() else { std::thread::sleep(step); continue };
        let (w, h) = (cap.width(), cap.height());
        let tw = w.min(max_w) & !1;
        let th = ((h as u64 * tw as u64 / w as u64) as u32) & !1;
        let Some(rgba) = image::RgbaImage::from_raw(w, h, cap.into_raw()) else { continue };
        let small = if tw != w { image::imageops::resize(&rgba, tw, th, image::imageops::FilterType::Triangle) } else { rgba };
        let rgb = image::DynamicImage::ImageRgba8(small).to_rgb8();

        // cheap change detection on a sample of the picture: an unchanged desktop costs no CPU or bandwidth
        let raw = rgb.as_raw();
        let sig = raw.iter().step_by(257).fold(1469598103934665603u64, |a, b| (a ^ *b as u64).wrapping_mul(1099511628211));
        let force = key.swap(false, Ordering::Relaxed);
        if sig == last_sig && !force && last_sent.elapsed() < Duration::from_secs(2) {
            std::thread::sleep(step.saturating_sub(t0.elapsed()));
            continue;
        }
        last_sig = sig;

        if enc.is_none() || dims != (tw, th) {
            let cfg = EncoderConfig::new(tw, th)
                .set_bitrate_bps(kbps.clamp(500, 40_000) * 1000)
                .max_frame_rate(fps as f32);
            match Encoder::with_config(cfg) {
                Ok(e) => { enc = Some(e); dims = (tw, th); }
                Err(_) => return,
            }
        }
        let Some(e) = enc.as_mut() else { return };
        if force { e.force_intra_frame(); }
        let yuv = YUVBuffer::with_rgb(tw as usize, th as usize, raw);
        let Ok(bits) = e.encode(&yuv) else { continue };
        let data = bits.to_vec();
        if !data.is_empty() {
            match tx.try_send(data) {
                Ok(()) => last_sent = Instant::now(),
                // the phone is behind: drop this frame and make the next one a full frame so the picture recovers at once
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => key.store(true, Ordering::Relaxed),
                Err(_) => return,
            }
        }
        std::thread::sleep(step.saturating_sub(t0.elapsed()));
    }
}

/// PC sound for the phone: captures what the PC is playing (WASAPI loopback) as 16-bit stereo PCM.
/// Messages: first byte 0 = JSON header {"rate":N}, first byte 1 = interleaved s16le stereo samples.
pub fn stream_audio(tx: tokio::sync::mpsc::Sender<Vec<u8>>, stop: std::sync::Arc<std::sync::atomic::AtomicBool>) {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use std::sync::atomic::Ordering;
    let host = cpal::default_host();
    let Some(dev) = host.default_output_device() else { return };
    let Ok(cfg) = dev.default_output_config() else { return };
    if cfg.sample_format() != cpal::SampleFormat::F32 { return; }
    let (rate, ch) = (cfg.sample_rate().0, (cfg.channels() as usize).max(1));
    let mut head = vec![0u8];
    head.extend_from_slice(format!("{{\"rate\":{rate}}}").as_bytes());
    if tx.blocking_send(head).is_err() { return; }
    let tx2 = tx.clone();
    let built = dev.build_input_stream(
        &cfg.config(),
        move |data: &[f32], _| {
            let mut out = Vec::with_capacity(1 + data.len() / ch * 4);
            out.push(1);
            for f in data.chunks(ch) {
                let l = f[0];
                let r = if ch > 1 { f[1] } else { f[0] };
                for s in [l, r] {
                    out.extend_from_slice(&((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
                }
            }
            let _ = tx2.try_send(out); // phone behind: drop, stay live
        },
        |_| {},
        None,
    );
    let Ok(stream) = built else { return };
    if stream.play().is_err() { return; }
    while !stop.load(Ordering::Relaxed) && !tx.is_closed() {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
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
