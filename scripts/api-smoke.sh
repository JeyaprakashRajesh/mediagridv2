#!/usr/bin/env bash
# Smoke-test the MediaGrid API (start scripts/dev-server.sh first).
B="${1:-http://localhost:47800}"; fail=0
ok(){ printf "PASS %s\n" "$1"; }; bad(){ printf "FAIL %s\n" "$1"; fail=1; }
T=$(curl -s -XPOST "$B/api/login" -H 'content-type: application/json' \
  -d '{"email":"jp@test.com","password":"secret123","device":"smoke"}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
[ -n "$T" ] && ok login || { bad login; exit 1; }
A="Authorization: Bearer $T"
code(){ curl -s -o /dev/null -w "%{http_code}" -H "$A" "$@"; }
[ "$(code "$B/api/me")" = 200 ] && ok me || bad me
ID=$(curl -s -H "$A" "$B/api/music/tracks" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')
[ -n "$ID" ] && ok tracks || bad tracks
[ -n "$ID" ] && { [ "$(code -H 'Range: bytes=0-1' "$B/api/music/stream/$ID")" = 206 ] && ok "stream range" || bad "stream range"; }
[ "$(code "$B/api/media/items")" = 200 ] && ok media || bad media
[ "$(code "$B/api/files/list")" = 200 ] && ok files || bad files
[ "$(code -XPOST -H 'content-type: application/json' -d '{"text":"smoke"}' "$B/api/shared/text")" = 200 ] && ok shared || bad shared
[ "$(code "$B/api/photos/synced")" = 200 ] && ok photos || bad photos
[ "$(code "$B/api/me" -H 'Authorization: Bearer nope')" = 401 ] && ok "rejects bad token" || bad "rejects bad token"
exit $fail
