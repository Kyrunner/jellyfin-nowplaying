#!/usr/bin/env bash
# Config parsing and credential handling for backend.sh.
#
#   bash backend-config.test.sh
#
# Runs against a stub Jellyfin on localhost, so it needs no real server and no
# credentials. The stub records the token it was sent, which is the only way to
# prove the credential reaching the wire is the one in the config file -- the bug
# this suite exists for sent a *different field's value* as the token and got a
# plausible-looking "auth failed" back.
set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'kill ${STUB_PID:-} 2>/dev/null; rm -rf "$WORK"' EXIT
export XDG_STATE_HOME="$WORK/state"   # keep the endpoint memory out of the real one

PORT="${JELLYFIN_TEST_PORT:-8792}"
GOOD_TOKEN="realtoken-abcdef0123456789"
export STUB_TOKEN="$GOOD_TOKEN" STUB_LOG="$WORK/seen-token.txt" STUB_PORT="$PORT"

python3 - <<'PY' &
import http.server, json, os, re
TOKEN = os.environ["STUB_TOKEN"]; LOG = os.environ["STUB_LOG"]


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # Jellyfin's scheme: Authorization: MediaBrowser Token="..."
        auth = self.headers.get("Authorization", "")
        m = re.search(r'Token="([^"]*)"', auth)
        got = m.group(1) if m else ""
        with open(LOG, "w") as f:
            f.write(got)
        body = b"[]"          # authenticated, nothing playing
        self.send_response(200 if got == TOKEN else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        auth = self.headers.get("Authorization", "")
        m = re.search(r'Token="([^"]*)"', auth)
        got = m.group(1) if m else ""
        with open(LOG, "w") as f:
            f.write(got)
        self.send_response(204 if got == TOKEN else 401)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(os.environ["STUB_PORT"])), H).serve_forever()
PY
STUB_PID=$!

for _ in $(seq 30); do
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && break
  read -r -t 0.1 < /dev/zero 2>/dev/null || true
done

pass=0
fail=0

run() { # name, expected-substring, config-json ("" means no config file at all), [backend args...]
  local name="$1" want="$2" cfg="$3" out
  shift 3
  rm -f "$WORK/seen-token.txt"
  if [ -z "$cfg" ]; then rm -f "$WORK/config.json"; else printf '%s' "$cfg" >"$WORK/config.json"; fi
  out=$(OMARCHY_JELLYFIN_CONFIG="$WORK/config.json" "$PLUGIN/backend.sh" "$@" 2>&1)
  if [[ "$out" == *"$want"* ]]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$name" "$want" "$out"
  fi
}

U="http://127.0.0.1:$PORT"

echo "config errors are reported as config errors:"
run "missing file"          '"error":"not configured"' ""
run "unparseable JSON"      '"error":"bad config"'     '{"url": '
run "not a JSON object"     '"error":"bad config"'     '["url","token"]'
# The regression. An absent token once collapsed the field split and put
# web_base in the token's place, which the server rejected as "auth failed".
run "token absent"          '"error":"bad config"'     "{\"url\":\"$U\",\"web_base\":\"https://web.example\"}"
run "token empty"           '"error":"bad config"'     "{\"url\":\"$U\",\"token\":\"\",\"web_base\":\"https://web.example\"}"
run "token null"            '"error":"bad config"'     "{\"url\":\"$U\",\"token\":null,\"web_base\":\"https://web.example\"}"
run "url absent"            '"error":"bad config"'     "{\"token\":\"$GOOD_TOKEN\"}"
run "url empty"             '"error":"bad config"'     "{\"url\":\"\",\"token\":\"$GOOD_TOKEN\"}"

echo "credentials:"
run "a wrong token is still an auth failure" '"error":"auth failed"' "{\"url\":\"$U\",\"token\":\"nope\"}"
run "valid config polls"    '"ok":true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\",\"web_base\":\"https://web.example\"}"
if [ "$(cat "$WORK/seen-token.txt" 2>/dev/null)" = "$GOOD_TOKEN" ]; then
  pass=$((pass + 1)); echo "  ok    the token on the wire is the token in the file"
else
  fail=$((fail + 1)); echo "  FAIL  sent '$(cat "$WORK/seen-token.txt" 2>/dev/null)' instead of the configured token"
fi
run "token pasted with stray whitespace" '"ok":true' "{\"url\":\"$U\",\"token\":\"  $GOOD_TOKEN \\n\"}"
run "web_base absent falls back to url"  '"ok":true' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\"}"
run "trailing slash on url"              '"ok":true' "{\"url\":\"$U/\",\"token\":\"$GOOD_TOKEN\"}"

# Nothing listens on port 1, so the LAN address fails fast and deterministically.
DEAD="http://127.0.0.1:1"
ENDPOINT="$WORK/state/omarchy-jellyfin/endpoint.json"

echo "endpoint fallback:"
rm -f "$ENDPOINT"
run "LAN dead, public_url answers" '"endpoint":"public"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$U\"}"
if grep -q '"which": *"public"' "$ENDPOINT" 2>/dev/null; then
  pass=$((pass + 1)); echo "  ok    the public choice is remembered for the next poll"
else
  fail=$((fail + 1)); echo "  FAIL  endpoint.json does not record the public choice: $(cat "$ENDPOINT" 2>/dev/null)"
fi
run "a control follows the same fallback" '"ok": true' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$U\"}" control sess1 playpause
if [ "$(cat "$WORK/seen-token.txt" 2>/dev/null)" = "$GOOD_TOKEN" ]; then
  pass=$((pass + 1)); echo "  ok    the control carried the configured token"
else
  fail=$((fail + 1)); echo "  FAIL  control sent '$(cat "$WORK/seen-token.txt" 2>/dev/null)'"
fi
rm -f "$ENDPOINT"
run "public_url defaults to web_base" '"endpoint":"public"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"web_base\":\"$U\"}"
rm -f "$ENDPOINT"
run "LAN alive is reported as lan"  '"endpoint":"lan"' "{\"url\":\"$U\",\"token\":\"$GOOD_TOKEN\",\"public_url\":\"$DEAD\"}"
run "no public_url: LAN dead is still unreachable" '"error":"unreachable"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\"}"
run "public_url set to empty never leaves the LAN" '"error":"unreachable"' "{\"url\":\"$DEAD\",\"token\":\"$GOOD_TOKEN\",\"web_base\":\"$U\",\"public_url\":\"\"}"
# A wrong token must never fail over: retrying bad credentials against a public
# edge is how you get banned by your own rate limiter.
run "a wrong token does not fail over" '"error":"auth failed"' "{\"url\":\"$U\",\"token\":\"nope\",\"public_url\":\"$DEAD\"}"

echo
if [ "$fail" -eq 0 ]; then
  echo "backend config: all $pass assertions passed"
else
  echo "backend config: $fail of $((pass + fail)) failed"
fi
[ "$fail" -eq 0 ]
