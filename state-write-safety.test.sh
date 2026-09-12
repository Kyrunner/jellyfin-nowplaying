#!/usr/bin/env bash
# What the plugin will and will not do when it writes its own state files.
#
#   bash state-write-safety.test.sh
#
# Needs no Jellyfin and no credentials -- it calls the state helpers directly.
#
# Marketplace review (2026-09-11) blocked the listing because the state writes
# used a predictable "<file>.tmp" name opened without O_NOFOLLOW or O_EXCL. Any
# process that can write into the state directory could pre-plant that exact
# name as a symlink and have the poll truncate the file it pointed at -- an
# arbitrary-write primitive in whatever account runs the widget.
#
# The three guarantees asserted here:
#   1. a planted symlink at the predictable temp name is never followed
#   2. a state file that is itself a symlink is never read through
#   3. a group- or world-writable state directory is refused outright
# plus a control proving ordinary state still round-trips, so a fix that simply
# stopped writing would fail rather than look like a pass.
#
# Scope note, stated rather than implied: the directory descriptor is opened
# O_NOFOLLOW and owner-checked, and every file operation is relative to that
# descriptor. That closes the final component and the directory itself. A parent
# directory that is already an attacker-owned symlink is outside what a widget
# can defend against and is not claimed here.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"
STATE="$XDG_STATE_HOME/omarchy-jellyfin"

PASS=0
FAIL=0
check() {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"
  fi
}

run_py() { PYTHONPATH="$PLUGIN" python3 - "$@"; }

echo "state write safety"

# ---------------------------------------------------------------- 1. temp symlink
# The attack the review named: plant the predictable temp name as a symlink to a
# file we own, then let the poll save state. The victim must come back untouched.
rm -rf "$XDG_STATE_HOME"; mkdir -p "$STATE"
printf 'original contents\n' > "$WORK/victim"
ln -s "$WORK/victim" "$STATE/endpoint.json.tmp"
run_py <<'PY' >/dev/null 2>&1
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
PY
check "planted <file>.tmp symlink is not followed" \
  "original contents" "$(cat "$WORK/victim")"

# ---------------------------------------------------------------- 2. symlinked state file
# Reading through a symlink would let anything that can write the state dir feed
# the widget a file it was never meant to read.
rm -rf "$XDG_STATE_HOME"; mkdir -p "$STATE"
printf '{"which": "planted"}\n' > "$WORK/elsewhere.json"
ln -s "$WORK/elsewhere.json" "$STATE/endpoint.json"
check "symlinked state file is not read through" \
  "default" "$(run_py <<'PY' 2>/dev/null
import jellyfin
print(jellyfin._load_json(jellyfin.ENDPOINT_FILE, "default"))
PY
)"

# ---------------------------------------------------------------- 3. unsafe directory
# A world-writable state directory is exactly the precondition the attack needs.
# Refusing to write there is the fail-closed answer; state is a convenience.
rm -rf "$XDG_STATE_HOME"; mkdir -p "$STATE"; chmod 0777 "$STATE"
run_py <<'PY' >/dev/null 2>&1
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
PY
check "world-writable state dir is refused" \
  "absent" "$([ -e "$STATE/endpoint.json" ] && echo present || echo absent)"

# ---------------------------------------------------------------- 4. control
# Without this a fix that just stopped writing would pass every test above.
rm -rf "$XDG_STATE_HOME"
check "ordinary state round-trips" \
  "public" "$(run_py <<'PY' 2>/dev/null
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
print(jellyfin._load_json(jellyfin.ENDPOINT_FILE, {}).get("which"))
PY
)"

# No leftover temp files, or the next run inherits a name an attacker can predict.
check "no temp file left behind" \
  "0" "$(find "$STATE" -name '*.tmp*' 2>/dev/null | wc -l)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
