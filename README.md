# MediaGrid

A PC ⇄ iPhone ecosystem: stream and sync music, browse PC photos/videos, back up iPhone photos to the PC,
a universal clipboard, a PC file explorer, and full remote control (trackpad, keyboard, media keys, live screen).

| Folder | What |
|---|---|
| `windows/` | Tauri 2 app (Rust + HTML). Runs in the tray, starts with Windows, serves the API on port **47800**. |
| `ios/` | SwiftUI app for iOS 26+ with Liquid Glass, Dynamic Island Live Activity, background audio & photo sync. |
| `branding/` | Logo (SVG) and app icon. |

## Pairing
1. Install & open MediaGrid on Windows → **Profile** → create your email + password.
2. On the iPhone, open MediaGrid. Your PC shows up automatically on Wi-Fi; over Tailscale type the `100.x.x.x` address from the PC's Profile tab.
3. Sign in with the same email + password.

## Building
Push to `main`: GitHub Actions builds `MediaGrid.ipa` (unsigned) and the Windows installer, and puts them on the `builds` branch.
Install the IPA with Sideloadly (free Apple ID → reinstall every 7 days).
