#!/usr/bin/env python3
"""Collector: runs on the machine where the AI tools are logged in, pushes to the aggregator.

Sources that only the collector machine can reach:
  * Claude   - this machine's Claude Code stays logged in, so its access token works.
  * Antigravity - its quota RPC is served by a local language_server on loopback.
  * Codex    - the ChatGPT plan quota, read with the Codex CLI's stored access token.
  * tokens   - Claude Code token history from the local session logs, with a costing.
  * codex_tokens - Codex CLI token history from its local session rollouts (no costing:
    Codex plan models have no published per-token list price to convert against).

Only computed percentages are pushed. No credentials leave this machine.
Read-only with respect to Claude's credential file: if the access token has expired we
report it and let Claude Code refresh on its own, rather than racing it for a write.

Config lives in ~/.ai-usage-collector/config.json:
  {"aggregator": "http://100.x.x.x:8756", "token": "shared secret",
   "providers": ["claude", "antigravity", "codex", "tokens"], "currency": "AUD"}
Leave a provider out of the list and its key is never pushed, so the phone shows no
row for it rather than an error.
"""
import json, os, re, ssl, subprocess, time, urllib.request, urllib.error

STATE_DIR = os.path.expanduser("~/.ai-usage-collector")
os.makedirs(STATE_DIR, exist_ok=True)
try:
    CFG = json.load(open(os.path.join(STATE_DIR, "config.json")))
except Exception:
    CFG = {}
AGG = CFG.get("aggregator", "http://100.x.x.x:8756").rstrip("/") + "/push"
TOKEN = CFG.get("token", "REPLACE_ME")
PROVIDERS = CFG.get("providers", ["claude", "antigravity", "codex", "tokens", "codex_tokens"])
CURRENCY = CFG.get("currency", "USD")
CREDS = os.path.expanduser("~/.claude/.credentials.json")
USAGE_URL = "https://api.anthropic.com/api/oauth/usage"

_noverify = ssl.create_default_context()
_noverify.check_hostname = False
_noverify.verify_mode = ssl.CERT_NONE


def fetch_claude():
    try:
        blob = json.load(open(CREDS))
    except Exception:
        return {"error": "no_credentials_file"}
    o = blob.get("claudeAiOauth", blob)
    tok = o.get("accessToken")
    if not tok:
        return {"error": "no_access_token"}
    if (o.get("expiresAt") or 0) <= time.time() * 1000:
        return {"error": "access_token_expired"}

    req = urllib.request.Request(USAGE_URL, headers={
        "Authorization": "Bearer " + tok,
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": "claude-cli/1.0"})
    try:
        b = json.loads(urllib.request.urlopen(req, timeout=20).read())
    except urllib.error.HTTPError as e:
        return {"error": "http_%s" % e.code}
    except Exception as e:
        return {"error": type(e).__name__}

    limits = {}
    for L in b.get("limits") or []:
        model = ((L.get("scope") or {}).get("model") or {}).get("display_name")
        limits[L.get("kind")] = {"percent": L.get("percent"),
                                 "resets_at": L.get("resets_at"), "model": model}
    return {"ok": True,
            "five_hour": (b.get("five_hour") or {}).get("utilization"),
            "seven_day": (b.get("seven_day") or {}).get("utilization"),
            "limits": limits}


def _antigravity_endpoint():
    """The language server picks a fresh port and CSRF token on every launch."""
    pid = subprocess.run(["pgrep", "-f", "language_server --standalone"],
                         capture_output=True, text=True).stdout.split()
    if not pid:
        return None, None
    pid = pid[0]
    cmd = subprocess.run(["ps", "-p", pid, "-o", "command="],
                         capture_output=True, text=True).stdout
    m = re.search(r"--csrf_token\s+(\S+)", cmd)
    if not m:
        return None, None
    ports = subprocess.run(["lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN"],
                           capture_output=True, text=True).stdout
    p = re.findall(r"127\.0\.0\.1:(\d+)", ports)
    return (p[0] if p else None), m.group(1)


AG_CACHE = os.path.join(STATE_DIR, "antigravity.json")


def _antigravity_last_good(error):
    """Quitting Antigravity used to blank the rows on the phone, which reads the same as
    'you have plenty left'. Keep serving the last reading, labelled with its age."""
    try:
        c = json.load(open(AG_CACHE))
    except Exception:
        return {"error": error}
    return {"ok": True, "groups": c["groups"], "error": error,
            "reading_age": int(time.time()) - c["at"]}


def fetch_antigravity():
    port, csrf = _antigravity_endpoint()
    if not port:
        return _antigravity_last_good("not_running")
    url = ("https://127.0.0.1:%s/exa.language_server_pb.LanguageServerService"
           "/RetrieveUserQuotaSummary" % port)
    req = urllib.request.Request(url, data=b"{}", method="POST",
                                 headers={"Content-Type": "application/json",
                                          "x-codeium-csrf-token": csrf})
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=15, context=_noverify).read())
    except urllib.error.HTTPError as e:
        return _antigravity_last_good("http_%s" % e.code)
    except Exception as e:
        return _antigravity_last_good(type(e).__name__)

    groups = []
    for g in (d.get("response") or {}).get("groups") or []:
        entry = {"name": g.get("displayName")}
        for b in g.get("buckets") or []:
            frac = b.get("remainingFraction")
            # The API reports what is LEFT; everything else in this widget reports
            # what has been USED, so invert here rather than at display time.
            used = None if frac is None else round(100 * (1 - frac))
            key = "weekly" if b.get("window") == "weekly" else "five_hour"
            entry[key + "_used"] = used
            entry[key + "_resets_at"] = b.get("resetTime")
        groups.append(entry)
    if not groups:
        return _antigravity_last_good("no_groups")
    try:
        json.dump({"at": int(time.time()), "groups": groups}, open(AG_CACHE, "w"))
    except Exception:
        pass
    return {"ok": True, "groups": groups}


CODEX_AUTH = os.path.expanduser("~/.codex/auth.json")
CODEX_URL = "https://chatgpt.com/backend-api/codex/usage"
CODEX_CACHE = os.path.join(STATE_DIR, "codex.json")


def _codex_last_good(error):
    """Same hazard as Antigravity: an empty row looks exactly like 0% used."""
    try:
        c = json.load(open(CODEX_CACHE))
    except Exception:
        return {"error": error}
    return {"ok": True, "plan": c.get("plan"), "windows": c["windows"], "error": error,
            "reading_age": int(time.time()) - c["at"]}


def fetch_codex():
    """ChatGPT plan quota behind Codex, from the endpoint the CLI's own status uses.

    Read-only on the credential file: the Codex CLI refreshes its own token (10-day
    life), so an expired one is reported rather than raced for a write.
    """
    try:
        a = json.load(open(CODEX_AUTH))["tokens"]
    except Exception:
        return _codex_last_good("no_credentials_file")
    req = urllib.request.Request(CODEX_URL, headers={
        "Authorization": "Bearer " + a["access_token"],
        "chatgpt-account-id": a.get("account_id", ""),
        "User-Agent": "codex-cli", "Accept": "application/json"})
    try:
        d = json.loads(urllib.request.urlopen(req, timeout=20).read())
    except urllib.error.HTTPError as e:
        return _codex_last_good("auth_expired" if e.code == 401 else "http_%s" % e.code)
    except Exception as e:
        return _codex_last_good(type(e).__name__)

    rl = d.get("rate_limit") or {}
    windows = []
    for key in ("primary_window", "secondary_window"):
        w = rl.get(key)
        if not w:
            continue
        secs = w.get("limit_window_seconds") or 0
        resets = w.get("reset_at")
        windows.append({
            # Which window is primary varies by plan, so label from its length.
            "label": "weekly" if secs >= 86400 else "5-hour",
            "percent": w.get("used_percent"),
            "window_seconds": secs,
            "resets_at": None if not resets else time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime(resets))})
    if not windows:
        return _codex_last_good("no_windows")

    out = {"ok": True, "plan": d.get("plan_type"), "windows": windows}
    try:
        json.dump({"at": int(time.time()), **out}, open(CODEX_CACHE, "w"))
    except Exception:
        pass
    return out


# USD per million tokens, list price. Cache write is 1.25x input (5-minute TTL,
# the default Claude Code uses); cache read is 0.1x input.
PRICING = {
    "claude-fable-5":    (10.0, 50.0),
    "claude-opus-4-8":   (5.0, 25.0),
    "claude-opus-4-7":   (5.0, 25.0),
    "claude-opus-4-6":   (5.0, 25.0),
    "claude-sonnet-5":   (3.0, 15.0),
    "claude-sonnet-4-6": (3.0, 15.0),
    "claude-haiku-4-5":  (1.0, 5.0),
}
CACHE_WRITE_MULT = 1.25
CACHE_READ_MULT = 0.1


FX_CACHE = os.path.join(STATE_DIR, "fx.json")
FX_URL = "https://open.er-api.com/v6/latest/USD"
FX_TTL = 86400


def fx_rate():
    """Live USD -> CURRENCY, cached daily. API prices are USD.

    Falls back to the cached rate (even if stale) rather than silently emitting
    USD figures under another currency's label.
    """
    if CURRENCY == "USD":
        return 1.0, None, False
    try:
        c = json.load(open(FX_CACHE))
        if time.time() - c.get("at", 0) < FX_TTL and c.get("currency") == CURRENCY:
            return c["rate"], c["as_of"], False
    except Exception:
        pass
    try:
        d = json.loads(urllib.request.urlopen(FX_URL, timeout=15).read())
        rate, as_of = d["rates"][CURRENCY], d.get("time_last_update_utc")
        json.dump({"at": int(time.time()), "rate": rate, "as_of": as_of,
                   "currency": CURRENCY}, open(FX_CACHE, "w"))
        return rate, as_of, False
    except Exception:
        try:
            c = json.load(open(FX_CACHE))
            return c["rate"], c["as_of"], True      # stale, but flagged
        except Exception:
            return None, None, False


def price(bymodel):
    """What this usage would have cost at list API rates, had it not been on a plan."""
    per_type = {"input": 0.0, "output": 0.0, "cache_write": 0.0, "cache_read": 0.0}
    rows, unpriced = [], []
    for model, c in bymodel.items():
        base = PRICING.get(model) or PRICING.get(model.rsplit("-", 1)[0])
        if not base:
            unpriced.append(model)
            continue
        inp, outp = base
        parts = {
            "input": c["input_tokens"] / 1e6 * inp,
            "output": c["output_tokens"] / 1e6 * outp,
            "cache_write": c["cache_creation_input_tokens"] / 1e6 * inp * CACHE_WRITE_MULT,
            "cache_read": c["cache_read_input_tokens"] / 1e6 * inp * CACHE_READ_MULT,
        }
        for k, v in parts.items():
            per_type[k] += v
        rows.append({"model": model,
                     "cost": round(sum(parts.values()), 2),
                     "by_type": {k: round(v, 2) for k, v in parts.items()}})
    fx, as_of, stale = fx_rate()
    if not fx:
        return {"error": "no_fx_rate"}

    for r in rows:
        r["cost"] = round(r["cost"] * fx, 2)
        r["by_type"] = {k: round(v * fx, 2) for k, v in r["by_type"].items()}
    rows.sort(key=lambda r: -r["cost"])

    if CURRENCY == "USD":
        basis = "list API rates in USD; cache write 1.25x input (5-min TTL), cache read 0.1x"
    else:
        basis = ("list API rates converted at %.4f USD/%s (%s); "
                 "cache write 1.25x input (5-min TTL), cache read 0.1x"
                 % (fx, CURRENCY, as_of or "unknown"))
    if stale:
        basis = "STALE RATE - " + basis
    return {"currency": CURRENCY,
            "total": round(sum(per_type.values()) * fx, 2),
            "by_type": {k: round(v * fx, 2) for k, v in per_type.items()},
            "by_model": rows,
            "unpriced": unpriced,
            "fx_rate": fx,
            "fx_as_of": as_of,
            "fx_stale": stale,
            "basis": basis}


TOKEN_CACHE = os.path.join(STATE_DIR, "tokens.json")
TOKEN_TTL = 3600          # daily buckets do not need 20-minute granularity
TOKEN_DAYS = 60
PROJECTS = os.path.expanduser("~/.claude/projects")


def fetch_tokens():
    """Lifetime + daily Claude Code token usage, read from local session logs.

    A full rescan of the whole corpus takes ~5s, so it just rescans rather than
    keeping an incremental index -- resumed sessions can copy earlier messages into
    new files, and a full pass with global de-duplication by message id is the only
    way to avoid double counting them.
    """
    try:
        cached = json.load(open(TOKEN_CACHE))
        if time.time() - cached.get("at", 0) < TOKEN_TTL:
            return cached["data"]
    except Exception:
        pass

    import collections
    tot = collections.Counter()
    byday = collections.defaultdict(collections.Counter)
    models = collections.Counter()
    bymodel = collections.defaultdict(collections.Counter)   # tokens per model, for costing
    seen = set()
    msgs = 0
    msgs_raw = 0        # every logged assistant entry, matching Claude Code's own counter
    keys = ("input_tokens", "output_tokens",
            "cache_creation_input_tokens", "cache_read_input_tokens")

    for root, _dirs, files in os.walk(PROJECTS):
        for fn in files:
            if not fn.endswith(".jsonl"):
                continue
            try:
                for line in open(os.path.join(root, fn), "r", errors="replace"):
                    if '"usage"' not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    m = d.get("message") or {}
                    u = m.get("usage") or d.get("usage")
                    if not isinstance(u, dict):
                        continue
                    if (m.get("role") or d.get("role")) == "assistant":
                        msgs_raw += 1
                    mid = m.get("id")
                    if mid:
                        # One API message can span several logged lines (text + tool_use
                        # blocks). Tokens must be counted once, or they inflate ~2.3x.
                        if mid in seen:
                            continue
                        seen.add(mid)
                    day = (d.get("timestamp") or "")[:10]
                    for k in keys:
                        v = u.get(k, 0) or 0
                        tot[k] += v
                        if day:
                            byday[day][k] += v
                    if day:
                        byday[day]["messages"] += 1
                    if m.get("model"):
                        models[m["model"]] += 1
                        for k in keys:
                            bymodel[m["model"]][k] += u.get(k, 0) or 0
                    msgs += 1
            except Exception:
                pass

    if not msgs:
        return {"error": "no_sessions"}

    billed = tot["input_tokens"] + tot["output_tokens"] + tot["cache_creation_input_tokens"]
    days = sorted(byday)[-TOKEN_DAYS:]
    data = {
        "ok": True,
        "messages": msgs_raw or msgs,
        "api_messages": msgs,
        "billed": billed,
        "cache_read": tot["cache_read_input_tokens"],
        "input": tot["input_tokens"],
        "output": tot["output_tokens"],
        "cache_creation": tot["cache_creation_input_tokens"],
        "models": dict(models.most_common(8)),
        "cost": price(bymodel),
        "days": [{"d": d,
                  "billed": (byday[d]["input_tokens"] + byday[d]["output_tokens"]
                             + byday[d]["cache_creation_input_tokens"]),
                  "msgs": byday[d]["messages"]} for d in days],
    }
    try:
        json.dump({"at": int(time.time()), "data": data}, open(TOKEN_CACHE, "w"))
    except Exception:
        pass
    return data


CODEX_SESSIONS = os.path.expanduser("~/.codex/sessions")
CODEX_TOKEN_INDEX = os.path.join(STATE_DIR, "codex-tokens-index.json")
CODEX_TOKEN_CACHE = os.path.join(STATE_DIR, "codex-tokens.json")


def _codex_session_totals(path):
    """(day, model, cumulative usage dict, turns) for one rollout file.

    Every token_count event carries the session's running total, so the last one with
    an `info` block is the session's final figure. The model comes from the last
    turn_context seen, which is what the CLI was actually configured with."""
    day = os.path.basename(path)[8:18]     # rollout-YYYY-MM-DD...
    model, usage, turns = None, None, 0
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if '"turn_context"' in line:
                m = re.search(r'"model":"([^"]+)"', line)
                if m:
                    model = m.group(1)
            elif '"total_token_usage"' in line:
                try:
                    info = json.loads(line)["payload"]["info"]
                except Exception:
                    continue
                if info and info.get("total_token_usage"):
                    usage = info["total_token_usage"]
                    turns += 1
    return day, model, usage, turns


def fetch_codex_tokens():
    """Lifetime + daily Codex CLI token usage from ~/.codex/sessions.

    The corpus is several GB, so unlike the Claude scan this keeps a per-file index
    (size + mtime) and only re-reads files that changed. Same output shape as
    `tokens`, minus cost."""
    try:
        cached = json.load(open(CODEX_TOKEN_CACHE))
        if time.time() - cached.get("at", 0) < TOKEN_TTL:
            return cached["data"]
    except Exception:
        pass
    try:
        index = json.load(open(CODEX_TOKEN_INDEX))
    except Exception:
        index = {}

    import collections
    live = {}
    for root, _dirs, files in os.walk(CODEX_SESSIONS):
        for fn in files:
            if not fn.endswith(".jsonl"):
                continue
            p = os.path.join(root, fn)
            try:
                st = os.stat(p)
            except OSError:
                continue
            key = "%d:%d" % (st.st_size, int(st.st_mtime))
            ent = index.get(p)
            if not ent or ent.get("key") != key:
                try:
                    day, model, usage, turns = _codex_session_totals(p)
                except Exception:
                    continue
                ent = {"key": key, "day": day, "model": model, "usage": usage, "turns": turns}
            live[p] = ent
    index = live
    try:
        json.dump(index, open(CODEX_TOKEN_INDEX, "w"))
    except Exception:
        pass

    tot = collections.Counter()
    byday = collections.defaultdict(collections.Counter)
    models = collections.Counter()
    sessions = turns = 0
    for ent in index.values():
        u = ent.get("usage")
        if not u:
            continue
        sessions += 1
        turns += ent.get("turns", 0)
        inp, out = u.get("input_tokens", 0) or 0, u.get("output_tokens", 0) or 0
        cached_in = u.get("cached_input_tokens", 0) or 0
        tot["input"] += inp; tot["output"] += out; tot["cache_read"] += cached_in
        day = ent.get("day") or ""
        if day:
            byday[day]["billed"] += inp - cached_in + out
            byday[day]["msgs"] += ent.get("turns", 0)
        if ent.get("model"):
            models[ent["model"]] += ent.get("turns", 0) or 1
    if not sessions:
        return {"error": "no_sessions"}
    days = sorted(byday)[-TOKEN_DAYS:]
    data = {
        "ok": True,
        "messages": turns,
        "api_messages": sessions,
        # OpenAI counts cached input inside input_tokens. "billed" follows the Claude
        # convention used elsewhere in this app: cache reads excluded.
        "billed": tot["input"] - tot["cache_read"] + tot["output"],
        "cache_read": tot["cache_read"],
        "input": tot["input"],
        "output": tot["output"],
        "cache_creation": 0,
        "models": dict(models.most_common(8)),
        "days": [{"d": d, "billed": byday[d]["billed"], "msgs": byday[d]["msgs"]} for d in days],
    }
    try:
        json.dump({"at": int(time.time()), "data": data}, open(CODEX_TOKEN_CACHE, "w"))
    except Exception:
        pass
    return data


def main():
    fetchers = {"claude": fetch_claude, "antigravity": fetch_antigravity,
                "codex": fetch_codex, "tokens": fetch_tokens,
                "codex_tokens": fetch_codex_tokens}
    payload = {name: fetchers[name]() for name in PROVIDERS if name in fetchers}
    payload["at"] = int(time.time())
    body = json.dumps(payload).encode()
    req = urllib.request.Request(AGG + "?k=" + TOKEN, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    try:
        print(urllib.request.urlopen(req, timeout=20).read().decode()[:200])
    except Exception as e:
        print("push failed:", type(e).__name__, e)
        print(json.dumps(payload)[:400])


if __name__ == "__main__":
    main()
