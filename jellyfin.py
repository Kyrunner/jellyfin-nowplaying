#!/usr/bin/env python3
"""Shared Jellyfin plumbing: config, and one request path with endpoint failover.

Two addresses. `url` is the LAN endpoint and is always tried first; `public_url`
is reached only when the LAN one fails, so the widget keeps working away from
home without dragging an all-day poll across the public edge (Traefik +
geoblock + CrowdSec + rate-limit) while at home. Both the poll and the transport
controls come through here, so a command sent away from home takes the same
road as the poll that showed the stream. Same design as ky.nzbget-queue.

As a script:
    jellyfin.py config      print url / token / web_base / public_url, one per line
    jellyfin.py sessions    print the chosen endpoint name, its base, then /Sessions

The token is read from the config file path, never taken from argv, so it stays
out of `ps`.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

CONFIG = os.environ.get("OMARCHY_JELLYFIN_CONFIG") or os.path.expanduser(
    "~/.config/omarchy-jellyfin/config.json"
)
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "omarchy-jellyfin",
)
ENDPOINT_FILE = os.path.join(STATE_DIR, "endpoint.json")

# Long enough that moving around the house does not thrash the choice, short
# enough that coming home restores the LAN path without intervention.
PUBLIC_STICKY_SEC = 600
LAN_TIMEOUT = 2.5
PUBLIC_TIMEOUT = 10


class AuthError(Exception):
    """Bad credentials. Deliberately never triggers endpoint failover: retrying a
    wrong token against a public edge is how you get banned by your own rate
    limiter."""


def load_config():
    """-> dict with url, token, web_base, public_url. Raises ValueError with the
    fault name backend.sh reports ("not configured" / "bad config")."""
    try:
        with open(CONFIG) as fh:
            c = json.load(fh)
    except FileNotFoundError:
        raise ValueError("not configured")
    except Exception:
        raise ValueError("bad config")
    if not isinstance(c, dict):
        raise ValueError("bad config")

    url = str(c.get("url") or "").strip().rstrip("/")
    # Stripped because a key pasted from Jellyfin's dashboard often carries a
    # trailing newline, which the server rejects as an invalid token.
    token = str(c.get("token") or "").strip()
    # web_base is for BROWSER links; it falls back to url when unset.
    web_base = (str(c.get("web_base") or "").strip().rstrip("/")) or url
    # public_url is the API fallback. It defaults to web_base because the public
    # web UI is the same Jellyfin and serves the API too. An explicit "" opts out.
    if "public_url" in c:
        public_url = str(c.get("public_url") or "").strip().rstrip("/")
    else:
        public_url = web_base
    if public_url == url:
        public_url = ""   # the same address twice is not a fallback
    return {"url": url, "token": token, "web_base": web_base, "public_url": public_url}


def _load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def _save_json(path, data):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception:
        pass  # remembering the endpoint is an optimisation, never a requirement


def _call(base, token, path, method, timeout):
    req = urllib.request.Request(
        base + path,
        data=b"" if method == "POST" else None,
        headers={'Authorization': 'MediaBrowser Token="%s"' % token},
        method=method,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8")
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise AuthError("auth failed")
        raise


# Once an endpoint has answered in this process, every later call uses it
# directly, so a seek (one GET, one POST) pays the LAN timeout at most once.
_chosen = None


def request(cfg, path, method="GET"):
    """Call Jellyfin, preferring the LAN address and falling back to the public one.

    The endpoint choice is persisted because these scripts run as a fresh process
    per poll: with no memory, every poll away from home would pay the LAN timeout
    before falling back.
    """
    global _chosen
    if _chosen:
        return _call(_chosen[1], cfg["token"], path, method, _chosen[2])

    lan, public = cfg["url"], cfg["public_url"]
    state = _load_json(ENDPOINT_FILE, {})
    on_public = state.get("which") == "public"
    fresh = (time.time() - float(state.get("since") or 0)) < PUBLIC_STICKY_SEC

    if on_public and fresh and public:
        order = [("public", public, PUBLIC_TIMEOUT)]
    else:
        order = ([("lan", lan, LAN_TIMEOUT)] if lan else []) + \
                ([("public", public, PUBLIC_TIMEOUT)] if public else [])

    last = None
    for which, base, tmo in order:
        try:
            result = _call(base, cfg["token"], path, method, tmo)
            _chosen = (which, base, tmo)
            if which != state.get("which") or which == "public":
                _save_json(ENDPOINT_FILE, {"which": which, "since": time.time()})
            return result
        except AuthError:
            raise      # not an endpoint problem; do not hammer the public edge with it
        except Exception as e:
            last = e

    # A sticky public choice can go stale (came home, wifi changed). One retry of
    # the full order beats staying wedged on an endpoint that is gone.
    if on_public and fresh and lan:
        _save_json(ENDPOINT_FILE, {})
        return request(cfg, path, method)

    raise last or RuntimeError("no endpoint configured")


def current_endpoint():
    if _chosen:
        return _chosen[0], _chosen[1]
    which = _load_json(ENDPOINT_FILE, {}).get("which") or "lan"
    return which, None


# ---- script entry points, for backend.sh --------------------------------------

def _fail(msg):
    print(json.dumps({"ok": False, "error": msg, "streams": []}, separators=(",", ":")))
    return 1


def _main(argv):
    mode = argv[0] if argv else ""
    if mode == "config":
        try:
            cfg = load_config()
        except ValueError:
            return 1
        for k in ("url", "token", "web_base", "public_url"):
            print(cfg[k])
        return 0

    if mode == "sessions":
        try:
            cfg = load_config()
        except ValueError as e:
            return _fail(str(e))
        if not cfg["url"] or not cfg["token"]:
            return _fail("bad config")
        try:
            sessions = request(cfg, "/Sessions")
        except AuthError:
            return _fail("auth failed")
        except urllib.error.HTTPError as e:
            return _fail("http %d" % e.code)
        except Exception:
            return _fail("unreachable")
        which, base = current_endpoint()
        # Three lines: which endpoint answered, its base (so posters come from
        # the address that is actually reachable), then the raw response for
        # flatten.py. None of the first two can contain a newline.
        print(which)
        print(base)
        print(json.dumps(sessions if sessions is not None else []))
        return 0

    return _fail("usage: jellyfin.py config|sessions")


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
