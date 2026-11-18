#!/usr/bin/env bash
# Run the MediaGrid PC backend headless with sample media (Linux/macOS/WSL).
# Account: jp@test.com / secret123   Port: 47800
# Preview the desktop UI in a browser: serve windows/ui and define a stub
# window.__TAURI__ = { core:{invoke}, window:{getCurrentWindow}, event:{listen} } before app.js,
# returning get_info with uiToken = a token from /api/login.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="${MG_HOME:-/tmp/mghome}"
(cd "$ROOT/windows/src-tauri" && cargo build -q)
if [ ! -d "$H/Music" ]; then
  mkdir -p "$H"/{Music/Album1,Pictures/Trip,Videos,Downloads,Documents}
  if command -v ffmpeg >/dev/null; then
    for i in 1 2 3; do ffmpeg -loglevel error -f lavfi -i "sine=frequency=$((300+i*80)):duration=20" \
      -metadata title="Song $i" -metadata artist="Artist $i" -metadata album="Album" "$H/Music/Album1/track$i.mp3"; done
    ffmpeg -loglevel error -f lavfi -i testsrc=duration=5:size=640x360:rate=30 -pix_fmt yuv420p "$H/Videos/clip.mp4"
  fi
  command -v convert >/dev/null && for c in red blue; do convert -size 800x600 plasma:$c-white "$H/Pictures/Trip/$c.jpg"; done
  echo hello > "$H/Documents/notes.txt"
fi
CFG="$H/.config/MediaGrid/config.json"
run() { HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_CACHE_HOME="$H/.cache" MEDIAGRID_HEADLESS=1 \
  "$ROOT/windows/src-tauri/target/debug/mediagrid"; }
if [ ! -f "$CFG" ]; then run & PID=$!; sleep 2; kill $PID; fi
python3 - "$CFG" <<'PY'
import json,hashlib,sys
p=sys.argv[1]; c=json.load(open(p)); salt='00112233445566778899aabbccddeeff'
o=hashlib.sha256((salt+'secret123').encode()).digest()
for _ in range(50000): o=hashlib.sha256(o+salt.encode()).digest()
c.update(email='jp@test.com',salt=salt,password_hash=o.hex()); json.dump(c,open(p,'w'),indent=1)
PY
echo "MediaGrid backend on http://localhost:47800  (Ctrl+C to stop)"
run
