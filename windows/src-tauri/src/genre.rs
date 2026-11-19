//! Audio analysis for auto-genres: decodes ~40 s from the middle of each song and measures
//! tempo (BPM), energy (RMS) and punch (how percussive it is). The phone turns those numbers
//! into labels (Melody, Chill, Dance...) relative to your own library.
use once_cell::sync::Lazy;
use parking_lot::RwLock;
use std::{
    collections::HashMap,
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
};
use symphonia::core::{
    audio::SampleBuffer,
    codecs::DecoderOptions,
    formats::{FormatOptions, SeekMode, SeekTo},
    io::MediaSourceStream,
    meta::MetadataOptions,
    probe::Hint,
    units::Time,
};

/// id -> [bpm, energy, punch]; an empty vec means the song could not be analysed.
static CACHE: Lazy<RwLock<HashMap<String, Vec<f32>>>> = Lazy::new(|| {
    let m = std::fs::read(crate::config::cache_dir().join("genres.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    RwLock::new(m)
});
static RUNNING: AtomicBool = AtomicBool::new(false);

pub fn get(id: &str) -> Option<[f32; 3]> {
    let c = CACHE.read();
    let v = c.get(id)?;
    (v.len() == 3).then(|| [v[0], v[1], v[2]])
}

fn save() {
    if let Ok(b) = serde_json::to_vec(&*CACHE.read()) {
        let _ = std::fs::write(crate::config::cache_dir().join("genres.json"), b);
    }
}

/// Analyse songs that have no result yet, in one background thread (a second call while it runs is ignored).
pub fn analyze_missing(tracks: Vec<(String, String)>) {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let mut n = 0;
        for (id, path) in tracks {
            if CACHE.read().contains_key(&id) {
                continue;
            }
            while crate::eco::ON.load(Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_secs(5)); // eco mode: no background CPU work
            }
            let f = analyze(&path).unwrap_or_default();
            CACHE.write().insert(id, f);
            n += 1;
            if n % 20 == 0 {
                save();
            }
        }
        save();
        RUNNING.store(false, Ordering::SeqCst);
    });
}

fn analyze(path: &str) -> Option<Vec<f32>> {
    let file = std::fs::File::open(path).ok()?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(e) = Path::new(path).extension().and_then(|e| e.to_str()) {
        hint.with_extension(e);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .ok()?;
    let mut format = probed.format;
    let track = format.default_track()?;
    let id = track.id;
    let sr = track.codec_params.sample_rate? as f32;
    let secs = track.codec_params.n_frames.map(|n| n as f32 / sr);
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default()).ok()?;
    if secs.map_or(false, |s| s > 100.0) {
        // skip the intro: listen to the middle of the song
        let _ = format.seek(SeekMode::Coarse, SeekTo::Time { time: Time::new(40, 0.0), track_id: Some(id) });
        decoder.reset();
    }

    let want = (sr * 40.0) as usize;
    let mut mono: Vec<f32> = Vec::with_capacity(want);
    while mono.len() < want {
        let Ok(packet) = format.next_packet() else { break };
        if packet.track_id() != id {
            continue;
        }
        let Ok(buf) = decoder.decode(&packet) else { continue };
        let ch = buf.spec().channels.count().max(1);
        let mut sb = SampleBuffer::<f32>::new(buf.capacity() as u64, *buf.spec());
        sb.copy_interleaved_ref(buf);
        for frame in sb.samples().chunks(ch) {
            mono.push(frame.iter().sum::<f32>() / ch as f32);
        }
    }
    features(&mono, sr)
}

fn features(x: &[f32], sr: f32) -> Option<Vec<f32>> {
    if x.len() < (sr * 10.0) as usize {
        return None;
    }
    let (win, hop) = (1024usize, 512usize);
    let mut env = Vec::with_capacity(x.len() / hop);
    let mut i = 0;
    while i + win <= x.len() {
        let e = x[i..i + win].iter().map(|v| v * v).sum::<f32>() / win as f32;
        env.push(e.sqrt());
        i += hop;
    }
    let rms = (x.iter().map(|v| v * v).sum::<f32>() / x.len() as f32).sqrt();

    // onset strength = positive change of the log-compressed loudness envelope
    let c: Vec<f32> = env.iter().map(|e| (1.0 + 50.0 * e).ln()).collect();
    let onset: Vec<f32> = c.windows(2).map(|w| (w[1] - w[0]).max(0.0)).collect();
    if onset.len() < 200 {
        return None;
    }
    let mean_on = onset.iter().sum::<f32>() / onset.len() as f32;
    let mean_c = c.iter().sum::<f32>() / c.len() as f32;
    let punch = if mean_c > 0.0 { mean_on / mean_c } else { 0.0 };

    // tempo = strongest repeat of the onset pattern between 60 and 180 BPM (autocorrelation)
    let fps = sr / hop as f32;
    let (lo, hi) = ((fps * 60.0 / 180.0) as usize, (fps * 60.0 / 60.0) as usize);
    let o: Vec<f32> = onset.iter().map(|v| v - mean_on).collect();
    let mut best = (0usize, f32::MIN);
    for lag in lo.max(1)..=hi.min(o.len() / 2) {
        let r = (0..o.len() - lag).map(|k| o[k] * o[k + lag]).sum::<f32>() / (o.len() - lag) as f32;
        if r > best.1 {
            best = (lag, r);
        }
    }
    if best.0 == 0 {
        return None;
    }
    let mut bpm = 60.0 * fps / best.0 as f32;
    while bpm < 70.0 {
        bpm *= 2.0;
    }
    while bpm > 160.0 {
        bpm /= 2.0;
    }
    Some(vec![bpm, rms, punch])
}
