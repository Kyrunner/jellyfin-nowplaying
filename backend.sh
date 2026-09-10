#!/usr/bin/env bash
# Jellyfin "now playing" -> one compact JSON line on stdout.
#
# The ONLY thing in this plugin that talks to Jellyfin. Kept as a script, not QML,
# so it can be run and diffed over SSH — the widget itself can only be checked by
# eye on the owner's screen.
#
#   {"ok":true,"streams":[{...}],"endpoint":"lan"}   nothing playing -> streams: []
#   {"ok":false,"error":"not configured"}            and a non-zero exit
#
# Config: ~/.config/omarchy-jellyfin/config.json
#   {"url":"http://host:8095","token":"...","web_base":"https://jf.example.com",
#    "public_url":"https://jf.example.com"}
set -uo pipefail

CFG="${OMARCHY_JELLYFIN_CONFIG:-$HOME/.config/omarchy-jellyfin/config.json}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OMARCHY_JELLYFIN_CONFIG="$CFG"

fail() { printf '{"ok":false,"error":"%s","streams":[]}\n' "$1"; exit 1; }

[ -r "$CFG" ] || fail "not configured"

# Transport is a separate entry point. The token reaches the helper through the
# config file PATH, never argv, so it stays out of `ps`. Both the poll and the
# controls go through jellyfin.py, so a command sent away from home follows the
# same LAN-then-public choice as the poll that showed the stream.
if [ "${1:-poll}" = "control" ]; then
  [ $# -eq 3 ] || { printf '{"ok":false,"error":"usage: control <session_id> <action>"}\n'; exit 1; }
  exec python3 "$DIR/control.py" "$2" "$3"
fi

# web_base is the address for BROWSER links; url stays the API endpoint. Separating
# them keeps polling on the fast LAN path instead of crossing the public edge
# (Traefik + geoblock + CrowdSec + rate-limit) 8,640 times a day, while a click still
# opens somewhere reachable away from home. Falls back to url when unset.
#
# public_url is the API address tried only when url is unreachable, so the widget
# keeps working away from home. It defaults to web_base: the public web UI is the
# same Jellyfin, and it serves the API too. Set it to "" to never leave the LAN.
#
# One field per line, and read one at a time. A space-separated
# `read -r A B C` collapses runs of whitespace, so an empty middle field does
# not read as empty — it disappears, and every later field shifts left. A config
# with no `token` put web_base in its place, passed the non-empty guard, and
# sent a URL as the credential; Jellyfin answered 401 and the widget reported
# "auth failed" — a credential problem the user did not have, while the real
# fault went unnamed. None of these values may contain a newline, so
# line-delimiting is unambiguous.
FIELDS=$(python3 "$DIR/jellyfin.py" config) || fail "bad config"

{ IFS= read -r URL; IFS= read -r TOKEN; IFS= read -r WEB_BASE; IFS= read -r PUBLIC_URL; } <<<"$FIELDS"

# Guarded individually, so a missing field is reported as the config error it is.
[ -n "${URL:-}" ] || fail "bad config"
[ -n "${TOKEN:-}" ] || fail "bad config"

# Three lines back: which endpoint answered, its base, then the /Sessions body.
# On failure jellyfin.py prints the {"ok":false,...} line itself and exits 1.
OUT=$(python3 "$DIR/jellyfin.py" sessions) || { printf '%s\n' "$OUT"; exit 1; }
{ IFS= read -r ENDPOINT; IFS= read -r API_BASE; } <<<"$OUT"
JSON=$(printf '%s\n' "$OUT" | sed '1,2d')

# Two bases, deliberately: WEB_BASE builds the click-through link that has to work
# from anywhere, API_BASE builds the poster link. At home that is the LAN address,
# so artwork never crosses the public edge to be displayed on the couch; away from
# home it is the public one, which is the only place a poster can load from.
printf '%s' "$JSON" | python3 "$DIR/flatten.py" "$WEB_BASE" "$API_BASE" "$ENDPOINT" || fail "bad response"
