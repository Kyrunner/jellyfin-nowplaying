#!/usr/bin/env bash
# Jellyfin "now playing" -> one compact JSON line on stdout.
#
# The ONLY thing in this plugin that talks to Jellyfin. Kept as a script, not QML,
# so it can be run and diffed over SSH — the widget itself can only be checked by
# eye on the owner's screen.
#
#   {"ok":true,"streams":[{...}]}          nothing playing -> streams: []
#   {"ok":false,"error":"not configured"}  and a non-zero exit
#
# Config: ~/.config/omarchy-jellyfin/config.json  {"url":"http://host:8095","token":"..."}
set -uo pipefail

CFG="${OMARCHY_JELLYFIN_CONFIG:-$HOME/.config/omarchy-jellyfin/config.json}"

fail() { printf '{"ok":false,"error":"%s","streams":[]}\n' "$1"; exit 1; }

[ -r "$CFG" ] || fail "not configured"

# web_base is the address for BROWSER links; url stays the API endpoint. Separating
# them keeps polling on the fast LAN path instead of crossing the public edge
# (Traefik + geoblock + CrowdSec + rate-limit) 8,640 times a day, while a click still
# opens somewhere reachable away from home. Falls back to url when unset.
read -r URL TOKEN WEB_BASE < <(python3 - "$CFG" <<'PY'
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    url=c.get("url","").rstrip("/")
    print(url, c.get("token",""), (c.get("web_base") or url).rstrip("/"))
except Exception:
    print("", "", "")
PY
) || fail "bad config"

[ -n "${URL:-}" ] && [ -n "${TOKEN:-}" ] || fail "bad config"

# -m keeps a hung server from wedging the poll; %{http_code} separates auth from reachability
BODY=$(curl -s -m 8 -w $'\n%{http_code}' \
  -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
  "$URL/Sessions" 2>/dev/null) || fail "unreachable"

CODE=$(printf '%s' "$BODY" | tail -n1)
JSON=$(printf '%s' "$BODY" | sed '$d')

case "$CODE" in
  200) : ;;
  401|403) fail "auth failed" ;;
  000|"") fail "unreachable" ;;
  *) fail "http $CODE" ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s' "$JSON" | python3 "$DIR/flatten.py" "$WEB_BASE" || fail "bad response"
