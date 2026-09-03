#!/usr/bin/env python3
"""AI usage aggregator: runs on an always-on Mac and serves usage.json to the phone.

Reads Claude and Grok itself, folds in whatever the collector pushes (Codex,
Antigravity, token history, and Claude as a fallback), and serves one JSON document
over the tailnet or LAN. Claude token: read from the login Keychain item
'Claude Code-credentials'; self-refreshes via the OAuth refresh grant when expired and
writes the rotated tokens back so this machine's Claude Code stays in sync. Backs the
item up once before any write.

Config lives in ~/.ai-usage-aggregator/config.json:
  {"token": "shared secret", "port": 8756,
   "providers": ["claude", "grok"],            # what THIS machine reads itself
   "ntfy_url": "https://ntfy.sh/your-topic"}   # optional, early-reset alerts
A provider left out of the list is never reported unless the collector pushes it, so
the phone shows no row for it.
"""
import datetime, json, os, re, statistics, struct, subprocess, time, threading, urllib.request, urllib.error
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE   = os.path.expanduser("~/.ai-usage-aggregator")
os.makedirs(BASE, exist_ok=True)
try:
    CFG = json.load(open(os.path.join(BASE, "config.json")))
except Exception:
    CFG = {}
PORT   = int(CFG.get("port", 8756))
TOKEN  = CFG.get("token", "REPLACE_ME")
PROVIDERS = CFG.get("providers", ["claude", "grok"])
NTFY_URL = CFG.get("ntfy_url")      # None disables the early-reset push
TTL    = 1200
KC_SERVICE      = "Claude Code-credentials"
OAUTH_TOKEN_URLS = [
    "https://api.anthropic.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
    "https://claude.ai/v1/oauth/token",
]
CLIENT_ID       = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
STATE  = os.path.join(BASE, "usage.json")
BACKUP = os.path.join(BASE, "keychain-backup.json")
GROK_CFG = os.path.join(BASE, "grok.json")   # {"cookie","ua"}
RESET_STATE    = os.path.join(BASE, "reset-watch.json")
RESET_MIN_PREV = 20    # only a meaningful amount of freed quota is worth a push
RESET_SLACK    = 2700  # a drop within 45 min of the advertised reset is just the reset
HIST_KEEP      = 12    # actual lengths kept per window, so the median tracks recent behaviour
HIST_MIN       = 4     # below this the median is one lucky goodwill reset, not a pattern
NEW_WINDOW     = 600   # resets_at moving further than this is a new window, not clock jitter
RESET_DROP     = 8     # ...and usage has to fall with it, or it is the same window re-anchoring
CONTINUITY     = 3600  # a row absent longer than this was not watched, so nothing spanning it counts
EXPECT_MARGIN  = 3600  # only worth saying when the estimate is meaningfully before the advertised time

_cache = {"ts": 0.0, "data": None}
# Pushed by the collector, which is the only machine that can reach Claude's token (when
# this one is logged out) and Antigravity's loopback quota RPC. Older than this and we
# stop presenting it as current.
PUSH_MAX_AGE = 2700
PUSH_STATE = os.path.join(BASE, "pushed.json")
_pushed = {"at": 0, "claude": None, "antigravity": None, "tokens": None, "codex": None}
try:
    # Survive a restart: otherwise the pushed rows vanish until the collector's next run.
    _pushed.update(json.load(open(PUSH_STATE)))
except Exception:
    pass
_lock  = threading.Lock()
_diag  = {}

def _sec(args):
    return subprocess.run(["security"] + args, capture_output=True, text=True, timeout=12)

def kc_read():
    try:
        raw = (_sec(["find-generic-password", "-s", KC_SERVICE, "-w"]).stdout or "").strip()
        return json.loads(raw) if raw else None
    except Exception:
        return None

def kc_account():
    try:
        p = _sec(["find-generic-password", "-s", KC_SERVICE, "-g"])
        txt = (p.stdout or "") + (p.stderr or "")
        m = re.search(r'"acct"<blob>="([^"]*)"', txt)
        return m.group(1) if m else None
    except Exception:
        return None

def kc_write(blob, acct):
    if not acct:
        return False
    try:
        return _sec(["add-generic-password", "-U", "-a", acct, "-s", KC_SERVICE,
                     "-w", json.dumps(blob)]).returncode == 0
    except Exception:
        return False

def backup_once(blob):
    if not os.path.exists(BACKUP):
        try:
            json.dump({"backed_up_at": int(time.time()), "blob": blob}, open(BACKUP, "w"))
            os.chmod(BACKUP, 0o600)
        except Exception:
            pass

def oauth_refresh(rt):
    body = json.dumps({"grant_type": "refresh_token", "refresh_token": rt,
                       "client_id": CLIENT_ID}).encode()
    attempts = {}
    for url in OAUTH_TOKEN_URLS:
        req = urllib.request.Request(url, data=body, method="POST",
            headers={"Content-Type": "application/json", "Referer": "https://claude.ai/",
                     "Origin": "https://claude.ai", "User-Agent": "claude-cli/1.0"})
        try:
            d = json.loads(urllib.request.urlopen(req, timeout=20).read())
            _diag["refresh_ok_url"] = url
            _diag["refresh_attempts"] = attempts
            return d
        except urllib.error.HTTPError as e:
            try: b = e.read().decode()[:160]
            except Exception: b = "?"
            attempts[url] = "%s %s" % (e.code, b)
        except Exception as e:
            attempts[url] = type(e).__name__
    _diag["refresh_attempts"] = attempts
    raise RuntimeError("all refresh endpoints failed")

def get_access_token(force=False):
    """Returns (access_token, error). Refreshes + writes back when needed."""
    blob = kc_read()
    if not blob:
        return None, "keychain_denied"
    backup_once(blob)
    o = blob.get("claudeAiOauth", blob)
    now = time.time() * 1000
    _diag["now"] = int(now); _diag["expiresAt"] = o.get("expiresAt")
    _diag["refreshTokenExpiresAt"] = o.get("refreshTokenExpiresAt")
    _diag["has_rt"] = bool(o.get("refreshToken")); _diag["rt_len"] = len(o.get("refreshToken") or "")
    # Key names only -- never values -- so a shape change in the stored blob is diagnosable.
    _diag["blob_keys"] = sorted(blob.keys()) if isinstance(blob, dict) else type(blob).__name__
    _diag["oauth_keys"] = sorted(o.keys()) if isinstance(o, dict) else type(o).__name__
    ea = o.get("expiresAt") or 0
    if not force and o.get("accessToken") and ea > now + 60000:
        return o["accessToken"], None
    rt = o.get("refreshToken")
    if not rt:
        return o.get("accessToken"), "no_refresh_token"
    try:
        d = oauth_refresh(rt)
    except urllib.error.HTTPError as e:
        return o.get("accessToken"), "refresh_http_%s" % e.code
    except Exception as e:
        return o.get("accessToken"), "refresh_%s" % type(e).__name__
    o["accessToken"] = d.get("access_token", o.get("accessToken"))
    if d.get("refresh_token"):
        o["refreshToken"] = d["refresh_token"]
    if d.get("expires_in"):
        o["expiresAt"] = int(now + d["expires_in"] * 1000)
    if "claudeAiOauth" in blob:
        blob["claudeAiOauth"] = o
    else:
        blob = o
    kc_write(blob, kc_account())   # best-effort keychain sync
    return o["accessToken"], None

def _call_usage(tok):
    req = urllib.request.Request("https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": "Bearer " + tok, "anthropic-beta": "oauth-2025-04-20",
                 "anthropic-version": "2023-06-01", "User-Agent": "claude-cli/1.0"})
    r = urllib.request.urlopen(req, timeout=20)
    return json.loads(r.read())

def fetch_claude():
    tok, err = get_access_token()
    if not tok:
        return {"error": err or "no_token"}
    try:
        b = _call_usage(tok)
    except urllib.error.HTTPError as e:
        if e.code == 401:   # stale despite expiry check -> force one refresh + retry
            tok, err = get_access_token(force=True)
            if not tok:
                return {"error": err or "no_token"}
            try:
                b = _call_usage(tok)
            except Exception as e2:
                return {"error": "retry_%s" % getattr(e2, "code", type(e2).__name__)}
        else:
            return {"error": "http_%s" % e.code}
    except Exception as e:
        return {"error": type(e).__name__}
    limits = {}
    for L in b.get("limits", []) or []:
        sc = L.get("scope") or {}
        model = (sc.get("model") or {}).get("display_name") if sc else None
        limits[L.get("kind")] = {"percent": L.get("percent"),
                                 "resets_at": L.get("resets_at"), "model": model}
    return {"ok": True,
            "five_hour": (b.get("five_hour") or {}).get("utilization"),
            "seven_day": (b.get("seven_day") or {}).get("utilization"),
            "limits": limits}

GROK_URL = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"


def _varint(buf, i):
    val = shift = 0
    while i < len(buf):
        b = buf[i]
        i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7
    raise ValueError("truncated varint")


def _pb_fields(buf):
    """Yield (field_number, wire_type, value) for one protobuf message."""
    i = 0
    while i < len(buf):
        key, i = _varint(buf, i)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(buf, i)
        elif wt == 5:
            v, i = buf[i:i + 4], i + 4
        elif wt == 1:
            v, i = buf[i:i + 8], i + 8
        elif wt == 2:
            ln, i = _varint(buf, i)
            v, i = buf[i:i + ln], i + ln
        else:
            return
        yield fn, wt, v


def fetch_grok():
    """Weekly SuperGrok quota via the gRPC-web RPC the web Usage tab uses.

    This is the subscription meter shown in grok.com > Settings > Usage. The older
    /rest/rate-limits endpoint reported the 2-hour chat limiter instead, which read
    ~0% regardless of how much of the plan had actually been consumed.
    """
    try:
        cfg = json.load(open(GROK_CFG))
    except Exception:
        return {"error": "not_configured"}
    cookie = cfg.get("cookie")
    if not cookie:
        return {"error": "no_cookie"}
    ua = cfg.get("ua", "Mozilla/5.0")

    req = urllib.request.Request(
        GROK_URL,
        data=bytes([0, 0, 0, 0, 0]),          # gRPC-web frame: flags=0, empty message
        method="POST",
        headers={"Content-Type": "application/grpc-web+proto", "X-Grpc-Web": "1",
                 "Cookie": cookie, "User-Agent": ua,
                 "Origin": "https://grok.com", "Referer": "https://grok.com/"})
    try:
        raw = urllib.request.urlopen(req, timeout=20).read()
    except urllib.error.HTTPError as e:
        return {"error": "http_%s" % e.code}
    except Exception as e:
        return {"error": type(e).__name__}

    # HTTP 200 with a non-zero grpc-status still means the call was rejected.
    if "grpc-status:0" not in raw[-120:].decode("latin-1", "replace").replace(" ", ""):
        return {"error": "grpc_rejected"}
    if len(raw) < 5 or raw[0] & 0x80:
        return {"error": "no_data_frame"}

    msg = raw[5:5 + int.from_bytes(raw[1:5], "big")]
    body = next((v for fn, wt, v in _pb_fields(msg) if fn == 1 and wt == 2), None)
    if body is None:
        return {"error": "no_config"}

    pct = ends = None
    for fn, wt, v in _pb_fields(body):
        if fn == 1 and wt == 5:
            pct = struct.unpack("<f", v)[0]
        elif fn == 5 and wt == 2:                       # period end Timestamp
            ends = next((s for f2, w2, s in _pb_fields(v) if f2 == 1 and w2 == 0), None)
    if pct is None:
        return {"error": "no_percent"}

    return {"ok": True, "percent": round(pct), "window": "weekly",
            "resets_at": datetime.datetime.fromtimestamp(
                ends, datetime.timezone.utc).isoformat() if ends else None}


def _iso_epoch(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _flatten_windows(out):
    """{key: (used_percent, resets_at_epoch, label, dict, field_prefix)} for every live
    quota window. The dict and prefix are where an estimated reset gets written back,
    so the served JSON carries it on the row it belongs to.
    Rows carrying an error or a stale flag are excluded: a frozen last-good reading
    followed by a fresh one can look exactly like an early reset."""
    w = {}
    c = out.get("claude") or {}
    if c.get("ok") and not c.get("error"):
        names = {"session": "Claude 5-hour", "weekly_all": "Claude weekly (all models)"}
        for kind, L in (c.get("limits") or {}).items():
            label = names.get(kind) or "Claude weekly (%s)" % (L.get("model") or kind)
            w["claude." + kind] = (L.get("percent"), _iso_epoch(L.get("resets_at")),
                                   label, L, "")
    g = out.get("grok") or {}
    if g.get("ok") and not g.get("error"):
        w["grok.weekly"] = (g.get("percent"), _iso_epoch(g.get("resets_at")),
                            "Grok weekly", g, "")
    cx = out.get("codex") or {}
    if cx.get("ok") and not cx.get("error") and not out.get("codex_stale"):
        for win in cx.get("windows") or []:
            w["codex." + win["label"]] = (win.get("percent"), _iso_epoch(win.get("resets_at")),
                                          "Codex %s" % win["label"], win, "")
    ag = out.get("antigravity") or {}
    if ag.get("ok") and not ag.get("error") and not out.get("antigravity_stale"):
        for grp in ag.get("groups") or []:
            for win in ("weekly", "five_hour"):
                pct = grp.get(win + "_used")
                if pct is None:
                    continue
                w["antigravity.%s.%s" % (grp.get("name"), win)] = (
                    pct, _iso_epoch(grp.get(win + "_resets_at")),
                    "Antigravity %s %s" % (grp.get("name"), win.replace("_", "-")),
                    grp, win + "_")
    return {k: v for k, v in w.items() if v[0] is not None}


def _ntfy(title, msg):
    if not NTFY_URL:
        return False
    try:
        req = urllib.request.Request(NTFY_URL, data=msg.encode(),
                                     headers={"Title": title, "Tags": "unlock"})
        urllib.request.urlopen(req, timeout=15)
        return True
    except Exception:
        return False


def _watch_resets(out):
    """Push a ntfy alert when a window's usage drops to ~zero well before its
    advertised reset: quota has been freed early and would otherwise go unnoticed.
    Fired events also ride the served JSON as `early_resets` for 24h.

    Also tracks how long each window ACTUALLY lasts. A provider's advertised reset is
    only an upper bound where resets get handed out early - measured on this account,
    8 of 10 Codex weekly windows ended before their advertised time, median length 2.5
    days against an advertised 7 - so a window with enough history also carries an
    estimate built from its own median length.
    """
    now = time.time()
    try:
        st = json.load(open(RESET_STATE))
    except Exception:
        st = {}
    cur = _flatten_windows(out)
    events = [e for e in st.get("events") or [] if now - e["at"] < 86400]
    # Carry the previous state forward rather than rebuilding it: a row drops out of
    # `cur` whenever its source goes stale (the collector asleep takes Codex and Antigravity
    # with it), and rebuilding would throw away weeks of accumulated window lengths.
    windows = dict(st.get("windows") or {})
    for key, (pct, resets, label, dest, prefix) in cur.items():
        prev = (st.get("windows") or {}).get(key) or {}
        continuous = now - prev.get("seen_at", 0) < CONTINUITY
        if (continuous and prev.get("percent", 0) >= RESET_MIN_PREV and pct <= 5
                and prev.get("resets_at") and prev["resets_at"] - now > RESET_SLACK):
            early_h = (prev["resets_at"] - now) / 3600
            events.append({"at": int(now), "window": label, "was": prev["percent"],
                           "now": pct, "early_hours": round(early_h, 1)})
            _ntfy("%s reset early" % label,
                  "%.0f%% -> %.0f%%, %.1f h before the expected reset. "
                  "Quota is back early - good window for heavy agent work."
                  % (prev["percent"], pct, early_h))

        started, hist = prev.get("started_at"), prev.get("history") or []
        rolled = (resets and prev.get("resets_at")
                  and resets - prev["resets_at"] > NEW_WINDOW
                  and prev.get("percent", 0) - pct > RESET_DROP)
        if not continuous:
            # Nothing measured across an absence is a measurement of this window, only
            # of how long we were not looking. Give up the start and re-learn it.
            started = None
        elif rolled:
            if started is not None:
                length = now - started
                # A window cannot outlive its own advertised length; if it looks like it
                # did, a boundary went unobserved and this span covers more than one.
                if length <= resets - now:
                    hist = (hist + [length])[-HIST_KEEP:]
            started = now
        windows[key] = {"percent": pct, "resets_at": resets, "seen_at": now,
                        "started_at": started, "history": hist}

        if started is not None and len(hist) >= HIST_MIN and resets:
            expected = started + statistics.median(hist)
            # Past the estimate, or no earlier than advertised, there is nothing to add.
            if now < expected < resets - EXPECT_MARGIN:
                dest[prefix + "expected_resets_at"] = datetime.datetime.fromtimestamp(
                    expected, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                dest[prefix + "expected_windows"] = len(hist)
    try:
        json.dump({"windows": windows, "events": events}, open(RESET_STATE, "w"))
    except Exception:
        pass
    if events:
        out["early_resets"] = events


def get_usage(force=False):
    with _lock:
        now = time.time()
        if not force and _cache["data"] and (now - _cache["ts"]) < TTL:
            return _cache["data"]
        out = {"updated": int(now)}
        if "grok" in PROVIDERS:
            out["grok"] = fetch_grok()

        push_age = now - (_pushed["at"] or 0)
        push_fresh = _pushed["at"] and push_age < PUSH_MAX_AGE

        # This machine's own Claude token wins; fall back to the collector's reading when
        # it cannot authenticate (e.g. this machine is logged out of Claude Code), or when
        # this machine is not configured to read Claude at all.
        claude = fetch_claude() if "claude" in PROVIDERS else {"error": "not_configured"}
        if "claude" in PROVIDERS:
            out["claude"] = claude
        if claude.get("error") and (_pushed["claude"] or {}).get("ok"):
            out["claude"] = _pushed["claude"]
            if "claude" in PROVIDERS:
                out["claude_source"] = "collector"
                out["claude_error"] = claude["error"]
            if not push_fresh:
                out["stale"] = True
        elif claude.get("error") and _cache["data"] and _cache["data"].get("claude", {}).get("ok"):
            out["claude"] = _cache["data"]["claude"]
            out["claude_error"] = claude["error"]
            out["stale"] = True

        if _pushed["tokens"]:
            out["tokens"] = _pushed["tokens"]

        if _pushed["codex"]:
            out["codex"] = _pushed["codex"]
            if not push_fresh:
                out["codex_stale"] = True

        if _pushed["antigravity"]:
            out["antigravity"] = _pushed["antigravity"]
            out["antigravity_age"] = int(push_age)
            if not push_fresh:
                out["antigravity_stale"] = True
        _watch_resets(out)
        _cache["ts"] = now
        _cache["data"] = out
        try:
            json.dump(out, open(STATE, "w"))
        except Exception:
            pass
        return out

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        q = parse_qs(urlparse(self.path).query)
        if q.get("k", [None])[0] != TOKEN:
            self.send_response(403); self.end_headers(); self.wfile.write(b"forbidden"); return
        if urlparse(self.path).path != "/push":
            self.send_response(404); self.end_headers(); return
        try:
            n = int(self.headers.get("Content-Length") or 0)
            d = json.loads(self.rfile.read(n))
        except Exception:
            self.send_response(400); self.end_headers(); self.wfile.write(b"bad json"); return
        with _lock:
            _pushed["at"] = d.get("at") or time.time()
            _pushed["claude"] = d.get("claude")
            _pushed["antigravity"] = d.get("antigravity")
            _pushed["tokens"] = d.get("tokens")
            _pushed["codex"] = d.get("codex")
            _cache["ts"] = 0.0          # force the next read to fold in what just arrived
            try:
                json.dump(_pushed, open(PUSH_STATE, "w"))
            except Exception:
                pass
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        if q.get("k", [None])[0] != TOKEN:
            self.send_response(403); self.end_headers(); self.wfile.write(b"forbidden"); return
        if urlparse(self.path).path == "/debug":
            get_usage(force=True)
            body = json.dumps(_diag).encode()
            self.send_response(200); self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(body))); self.end_headers()
            self.wfile.write(body); return
        # ?force=1 lets the app's refresh button bypass the 20-minute cache and
        # re-read this machine's own sources (Claude + Grok) immediately.
        force = q.get("force", ["0"])[0] in ("1", "true", "yes")
        body = json.dumps(get_usage(force=force)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

def _sampler():
    """Early-reset detection must not depend on the phone polling: rebuild every TTL
    so successive readings exist even when nothing is asking."""
    while True:
        time.sleep(TTL)
        try:
            get_usage()
        except Exception:
            pass


if __name__ == "__main__":
    threading.Thread(target=_sampler, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    print("ai-usage-aggregator serving on 0.0.0.0:%d" % PORT, flush=True)
    srv.serve_forever()
