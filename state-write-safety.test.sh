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
# Marketplace review round 3 (2026-09-22): checking only the final directory
# left its parents open -- a symlink swapped in for ~/.local/state, or any other
# component, would redirect every write. The directory is now reached by walking
# the whole path one component at a time from "/", each opened O_NOFOLLOW
# relative to its parent's descriptor and owner-checked, so:
#   4. a symlink anywhere in the path is refused, not followed
#   5. a parent writable by others (without the sticky bit) is refused
# plus controls proving the normal ~/.local/state path and a sticky /tmp
# ancestor still work.
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

# ---------------------------------------------------------------- 6. symlinked parent
# Round 3: the state root itself (XDG_STATE_HOME / ~/.local/state) swapped for a
# symlink. Every write would land wherever it points; it must be refused.
rm -rf "$WORK/real" "$WORK/linked"; mkdir -p "$WORK/real"
ln -s "$WORK/real" "$WORK/linked"
XDG_STATE_HOME="$WORK/linked" run_py <<'PY' >/dev/null 2>&1
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
PY
check "symlinked state root is not written through" \
  "absent" "$([ -e "$WORK/real/omarchy-jellyfin/endpoint.json" ] && echo present || echo absent)"

mkdir -p "$WORK/real/omarchy-jellyfin"; chmod 0700 "$WORK/real/omarchy-jellyfin"
printf '{"which": "planted"}\n' > "$WORK/real/omarchy-jellyfin/endpoint.json"
check "symlinked state root is not read through" \
  "default" "$(XDG_STATE_HOME="$WORK/linked" run_py <<'PY' 2>/dev/null
import jellyfin
print(jellyfin._load_json(jellyfin.ENDPOINT_FILE, "default"))
PY
)"

# ---------------------------------------------------------------- 7. symlink higher up
# Not just the last parent: a symlink two levels above the state dir.
rm -rf "$WORK/up"; mkdir -p "$WORK/up/realdir/state"
ln -s "$WORK/up/realdir" "$WORK/up/alias"
XDG_STATE_HOME="$WORK/up/alias/state" run_py <<'PY' >/dev/null 2>&1
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
PY
check "symlink higher in the path is refused" \
  "absent" "$([ -e "$WORK/up/realdir/state/omarchy-jellyfin/endpoint.json" ] && echo present || echo absent)"

# ---------------------------------------------------------------- 8. writable parent
# A parent anyone can write (and not sticky) lets them rename our directory away
# and put their own in its place between runs.
rm -rf "$WORK/open"; mkdir -p "$WORK/open/state"; chmod 0777 "$WORK/open"
XDG_STATE_HOME="$WORK/open/state" run_py <<'PY' >/dev/null 2>&1
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
PY
check "parent writable by others is refused" \
  "absent" "$([ -e "$WORK/open/state/omarchy-jellyfin/endpoint.json" ] && echo present || echo absent)"
chmod 0755 "$WORK/open"

# ---------------------------------------------------------------- 9. controls
# The default location (no XDG_STATE_HOME) must still work: $HOME/.local/state,
# created on first use.
rm -rf "$WORK/home"; mkdir -p "$WORK/home"; chmod 0700 "$WORK/home"
check "default ~/.local/state still round-trips" \
  "public" "$(unset XDG_STATE_HOME; HOME="$WORK/home" run_py <<'PY' 2>/dev/null
import jellyfin
jellyfin._save_json(jellyfin.ENDPOINT_FILE, {"which": "public"})
print(jellyfin._load_json(jellyfin.ENDPOINT_FILE, {}).get("which"))
PY
)"
check "state dir created 0700" \
  "700" "$(stat -c %a "$WORK/home/.local/state/omarchy-jellyfin" 2>/dev/null)"

# $WORK lives under /tmp: a root-owned sticky world-writable ancestor must be
# accepted, or the widget would refuse every normal system. (Every round-trip
# above already runs under it; asserted here explicitly.)
check "sticky root-owned ancestor accepted" \
  "1777 root" "$(stat -c '%a %U' "$(dirname "$WORK")")"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
