#!/usr/bin/env python3
"""
MediaGrid Automated Playlist Generator (Spotify-Style Algorithm)

Generates dynamic playlists using acoustic features (BPM, energy, punch),
temporal context (Daylist), or sound-alike clustering, sequenced with
Spotify-style flow (smooth tempo transitions & artist spreading).

Usage examples:
  python scripts/auto-playlist.py --type daylist
  python scripts/auto-playlist.py --type workout --limit 30
  python scripts/auto-playlist.py --type chill
  python scripts/auto-playlist.py --type radio --artist "Coldplay"
  python scripts/auto-playlist.py --type decade --decade 2000
"""

import argparse
import datetime
import math
import random
import sys
import uuid
import json

try:
    import urllib.request
    import urllib.parse
    import urllib.error
except ImportError:
    pass

def http_json(url, data=None, headers=None, method=None):
    hdrs = {"User-Agent": "MediaGridAutoPlaylist/1.0"}
    if headers:
        hdrs.update(headers)
    req_body = None
    if data is not None:
        req_body = json.dumps(data).encode("utf-8")
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=req_body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read().decode("utf-8")
            return json.loads(content) if content else {}
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode("utf-8")
        sys.stderr.write(f"HTTP Error {e.code}: {err_msg}\n")
        sys.exit(1)
    except Exception as e:
        sys.stderr.write(f"Connection Error: {e}\n")
        sys.exit(1)

def sequence_spotify_flow(picks, mode="tempo"):
    """
    Applies Spotify's sequencing heuristics:
    1. Progressive tempo or energy arc (warm-up -> peak -> cooldown)
    2. Artist Spreading: No two consecutive tracks from the same artist
    """
    if len(picks) <= 2:
        return picks

    pool = list(picks)
    if mode == "arc":
        pool.sort(key=lambda t: t.get("bpm") or 110)
        warm, peak, cool = [], [], []
        for i, t in enumerate(pool):
            if i % 3 == 0:
                warm.append(t)
            elif i % 3 == 1:
                peak.append(t)
            else:
                cool.append(t)
        pool = warm + list(reversed(peak)) + cool
    else:
        pool.sort(key=lambda t: t.get("bpm") or 110)

    # Artist spreading (damping)
    sequenced = []
    last_artist = ""
    while pool:
        idx = next((i for i, t in enumerate(pool) if t.get("artist") != last_artist), 0)
        picked = pool.pop(idx)
        sequenced.append(picked)
        last_artist = picked.get("artist")

    return sequenced

def main():
    parser = argparse.ArgumentParser(description="MediaGrid Spotify-style Automated Playlist Generator")
    parser.add_argument("--host", default="http://127.0.0.1:47800", help="MediaGrid server address")
    parser.add_argument("--token", help="Bearer token (optional if logging in)")
    parser.add_argument("--email", default="jp@test.com", help="Email for /api/login")
    parser.add_argument("--password", default="secret123", help="Password for /api/login")
    parser.add_argument("--type", choices=["daylist", "workout", "chill", "radio", "decade"], default="daylist",
                        help="Playlist generation algorithm preset")
    parser.add_argument("--artist", help="Seed artist for 'radio' preset")
    parser.add_argument("--decade", type=int, default=2000, help="Decade year for 'decade' preset (e.g. 1990, 2000)")
    parser.add_argument("--name", help="Custom name for the generated playlist")
    parser.add_argument("--limit", type=int, default=40, help="Maximum number of songs")
    parser.add_argument("--play", action="store_true", help="Start playback on PC immediately")

    args = parser.parse_args()
    base = args.host.rstrip("/")

    # 1. Obtain token
    token = args.token
    if not token:
        login_res = http_json(f"{base}/api/login", data={
            "email": args.email,
            "password": args.password,
            "device": "AutoPlaylistScript"
        })
        token = login_res.get("token")
        if not token:
            sys.stderr.write("Failed to login to MediaGrid\n")
            sys.exit(1)

    headers = {"Authorization": f"Bearer {token}"}

    # 2. Fetch tracks (?pop=1 for Deezer popularity ranking)
    tracks = http_json(f"{base}/api/music/tracks?pop=1", headers=headers)
    if not tracks:
        print("No tracks found in MediaGrid library.")
        return

    now = datetime.datetime.now()
    hour = now.hour
    weekday_name = now.strftime("%A")

    picks = []
    playlist_name = args.name
    flow_mode = "tempo"

    if args.type == "daylist":
        if 5 <= hour < 12:
            slot = f"{weekday_name} Morning Acoustic Rise"
            bpm_low, bpm_high, e_low, e_high = 75, 115, 0.0, 0.55
        elif 12 <= hour < 17:
            slot = f"{weekday_name} Afternoon Focus Groove"
            bpm_low, bpm_high, e_low, e_high = 100, 130, 0.45, 0.85
        elif 17 <= hour < 22:
            slot = f"{weekday_name} Evening Golden Vibe"
            bpm_low, bpm_high, e_low, e_high = 90, 125, 0.35, 0.75
        else:
            slot = f"{weekday_name} Late Night Chill Ambient"
            bpm_low, bpm_high, e_low, e_high = 60, 105, 0.0, 0.45

        if not playlist_name:
            playlist_name = f"Daylist: {slot}"

        candidates = [
            t for t in tracks
            if (not t.get("bpm") or bpm_low <= t["bpm"] <= bpm_high) and
               (not t.get("energy") or e_low <= t["energy"] <= e_high)
        ]
        if len(candidates) < 10:
            candidates = tracks
        random.shuffle(candidates)
        picks = candidates[:args.limit]

    elif args.type == "workout":
        flow_mode = "arc"
        if not playlist_name:
            playlist_name = "⚡ High-Energy Workout Arc"
        candidates = [t for t in tracks if (t.get("bpm") or 0) >= 120 or (t.get("energy") or 0) >= 0.5]
        if len(candidates) < 10:
            candidates = [t for t in tracks if (t.get("bpm") or 120) >= 110]
        random.shuffle(candidates)
        picks = candidates[:args.limit]

    elif args.type == "chill":
        if not playlist_name:
            playlist_name = "🌙 Chill & Focus Flow"
        candidates = [t for t in tracks if (t.get("bpm") or 100) <= 105 or (t.get("energy") or 0.4) <= 0.45]
        random.shuffle(candidates)
        picks = candidates[:args.limit]

    elif args.type == "radio":
        seed = args.artist
        if not seed:
            seed = tracks[0].get("artist", "")
        if not playlist_name:
            playlist_name = f"📻 {seed} & Sound-Alikes"

        artist_tracks = [t for t in tracks if t.get("artist") == seed]
        avg_bpm = sum(t.get("bpm") or 110 for t in artist_tracks) / max(len(artist_tracks), 1)
        avg_e = sum(t.get("energy") or 0.5 for t in artist_tracks) / max(len(artist_tracks), 1)
        avg_p = sum(t.get("punch") or 0.3 for t in artist_tracks) / max(len(artist_tracks), 1)

        def dist(t):
            db = ((t.get("bpm") or 110) - avg_bpm) / 30.0
            de = (t.get("energy") or 0.5) - avg_e
            dp = (t.get("punch") or 0.3) - avg_p
            d = math.sqrt(db*db + de*de + dp*dp)
            return d * 0.7 if t.get("artist") == seed else d

        sorted_by_dist = sorted(tracks, key=dist)
        picks = sorted_by_dist[:args.limit]

    elif args.type == "decade":
        dec = args.decade
        if not playlist_name:
            playlist_name = f"⏳ {dec}s Retro Mix"
        candidates = [t for t in tracks if dec <= (t.get("year") or 0) < dec + 10]
        if not candidates:
            candidates = tracks
        random.shuffle(candidates)
        picks = candidates[:args.limit]

    # Apply Spotify Flow sequencing (smooth tempo transitions & artist separation)
    final_tracks = sequence_spotify_flow(picks, mode=flow_mode)
    track_ids = [t["id"] for t in final_tracks]

    print(f"\nGenerated Playlist: '{playlist_name}' ({len(final_tracks)} tracks)")
    print(f"Flow Strategy: {'Energy Arc (Warm-up -> Peak -> Cooldown)' if flow_mode == 'arc' else 'Smooth BPM ladder with artist spreading'}")
    print("-" * 65)
    for i, t in enumerate(final_tracks[:10], 1):
        bpm_str = f"{int(t['bpm'])} BPM" if t.get("bpm") else "-- BPM"
        print(f"  {i:2d}. {t.get('title','?')[:28]:<28} | {t.get('artist','?')[:18]:<18} | {bpm_str}")
    if len(final_tracks) > 10:
        print(f"  ... and {len(final_tracks) - 10} more tracks.")
    print("-" * 65)

    # 3. Update playlists in MediaGrid
    existing_playlists = http_json(f"{base}/api/playlists", headers=headers)
    if not isinstance(existing_playlists, list):
        existing_playlists = []

    new_entry = {
        "id": str(uuid.uuid4()),
        "name": playlist_name,
        "trackIDs": track_ids,
        "created": int(datetime.datetime.now().timestamp() * 1000)
    }

    # Replace if duplicate name exists, otherwise prepend
    updated = False
    for i, p in enumerate(existing_playlists):
        if p.get("name", "").strip().lower() == playlist_name.strip().lower():
            existing_playlists[i] = new_entry
            updated = True
            break
    if not updated:
        existing_playlists.insert(0, new_entry)

    http_json(f"{base}/api/playlists", data=existing_playlists, headers=headers, method="POST")
    print(f"Successfully synced '{playlist_name}' to PC and all connected iPhones!")

    if args.play and track_ids:
        http_json(f"{base}/api/pc/play", data={"ids": track_ids, "mode": "play"}, headers=headers, method="POST")
        print("Started playback on PC.")

if __name__ == "__main__":
    main()
