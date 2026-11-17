//! Universal clipboard: watch the PC clipboard and push changes to the phone.
use crate::config::random_hex;
use crate::state::{now_ms, Shared, SharedItem};
use parking_lot::Mutex;
use std::time::Duration;

static SKIP: Mutex<Option<String>> = Mutex::new(None);

/// Set PC clipboard text (from phone) without echoing it back.
pub fn set_text(t: &str) {
    *SKIP.lock() = Some(t.to_string());
    if let Ok(mut cb) = arboard::Clipboard::new() {
        let _ = cb.set_text(t.to_string());
    }
}

pub fn watch(app: Shared) {
    std::thread::spawn(move || {
        let mut last = String::new();
        if let Ok(mut cb) = arboard::Clipboard::new() {
            last = cb.get_text().unwrap_or_default();
        }
        *app.last_clip.lock() = last.clone();
        loop {
            std::thread::sleep(Duration::from_millis(700));
            if !app.cfg.read().clipboard_sync {
                continue;
            }
            let Ok(mut cb) = arboard::Clipboard::new() else { continue };
            let Ok(t) = cb.get_text() else { continue };
            if t == last || t.trim().is_empty() {
                continue;
            }
            last = t.clone();
            let from_phone = SKIP.lock().take().map(|s| s == t).unwrap_or(false);
            *app.last_clip.lock() = t.clone();
            if from_phone {
                continue;
            }
            app.push(serde_json::json!({ "event": "clipboard", "text": t }));
            app.add_shared(SharedItem {
                id: random_hex(8),
                kind: "clipboard".into(),
                text: Some(t),
                name: None,
                size: None,
                path: None,
                from: "pc".into(),
                at: now_ms(),
            });
        }
    });
}
