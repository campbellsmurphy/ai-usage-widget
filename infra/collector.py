#!/usr/bin/env python3
"""Collector: runs on the machine where the AI tools are logged in, pushes to the aggregator.

Sources that only the collector machine can reach:
  * Claude   - this machine's Claude Code stays logged in, so its access token works.
  * Antigravity - its quota RPC is served by a local language_server on loopback.
  * Codex    - the ChatGPT plan quota, read with the Codex CLI's stored access token.
  * tokens   - Claude Code token history from the local session logs, with a costing.
  * codex_tokens - Codex CLI token history from its local session rollouts, priced at
    OpenAI's published list rates.
  * grok_tokens - Grok CLI token history from its session update logs, with the cost the
    CLI itself records per turn.
  * agy_tokens - agy (Antigravity CLI) and Antigravity IDE token history, decoded from
    the protobuf step metadata in their conversation SQLite files.

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
PROVIDERS = CFG.get("providers", ["claude", "antigravity", "codex", "tokens", "codex_tokens",
                                  "grok_tokens", "agy_tokens"])
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
    # OpenAI standard tier, short context, verified 2026-09-06 at
    # developers.openai.com/api/docs/pricing. Cached input is 0.1x and cache writes
    # 1.25x for these too, so the same multipliers apply. gpt-5.5 is the standard rate
    # (its Fast-mode price is listed at exactly double).
    "gpt-6-astra":       (10.0, 50.0),
    "gpt-5.6-sol":       (4.0, 20.0),
    "gpt-5.6-terra":     (2.0, 12.0),
    "gpt-5.6-luna":      (0.2, 1.2),
    "gpt-5.5":           (6.25, 37.5),
    # Gemini API paid tier, verified 2026-09-06 at ai.google.dev/gemini-api/docs/pricing.
    # 3.6/3.7/3.8 Flash share an introductory rate that doubles on 2027-01-01; cached
    # input is 0.1x here too. Gemini bills no cache-write premium (storage per hour
    # instead), and agy records no cache-write field, so that term is always zero.
    "gemini-3.8-flash":  (0.75, 3.75),
    "gemini-3.7-flash":  (0.75, 3.75),
    "gemini-3.6-flash":  (0.75, 3.75),
    "gemini-3.1-pro":    (2.0, 12.0),
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
    byproj = collections.Counter()

    for root, _dirs, files in os.walk(PROJECTS):
        rel = os.path.relpath(root, PROJECTS).split(os.sep)[0]
        label = _activity(_claude_project_path(rel)) if rel != "." else "unknown"
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
                    byproj[label] += ((u.get("input_tokens", 0) or 0) + (u.get("output_tokens", 0) or 0)
                                      + (u.get("cache_creation_input_tokens", 0) or 0))
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
        "by_project": _top_projects(byproj),
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
    model, usage, turns, cwd = None, None, 0, None
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            if cwd is None and '"session_meta"' in line:
                m = re.search(r'"cwd":"([^"]+)"', line)
                cwd = m.group(1) if m else ""
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
    return day, model, usage, turns, cwd


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
            key = "v2:%d:%d" % (st.st_size, int(st.st_mtime))
            ent = index.get(p)
            if not ent or ent.get("key") != key:
                try:
                    day, model, usage, turns, cwd = _codex_session_totals(p)
                except Exception:
                    continue
                ent = {"key": key, "day": day, "model": model, "usage": usage, "turns": turns,
                       "cwd": cwd}
            live[p] = ent
    index = live
    try:
        json.dump(index, open(CODEX_TOKEN_INDEX, "w"))
    except Exception:
        pass

    tot = collections.Counter()
    byday = collections.defaultdict(collections.Counter)
    models = collections.Counter()
    bymodel = collections.defaultdict(collections.Counter)
    byproj = collections.Counter()
    sessions = turns = 0
    for ent in index.values():
        u = ent.get("usage")
        if not u:
            continue
        sessions += 1
        turns += ent.get("turns", 0)
        inp, out = u.get("input_tokens", 0) or 0, u.get("output_tokens", 0) or 0
        cached_in = u.get("cached_input_tokens", 0) or 0
        cache_w = u.get("cache_write_input_tokens", 0) or 0
        tot["input"] += inp; tot["output"] += out; tot["cache_read"] += cached_in
        tot["cache_write"] += cache_w
        byproj[_activity(ent.get("cwd"))] += inp - cached_in + out
        day = ent.get("day") or ""
        if day:
            byday[day]["billed"] += inp - cached_in + out
            byday[day]["msgs"] += ent.get("turns", 0)
        if ent.get("model"):
            models[ent["model"]] += ent.get("turns", 0) or 1
            # Same key names price() expects for Claude; OpenAI's input_tokens includes
            # the cached part, so split it out here.
            bm = bymodel[ent["model"]]
            bm["input_tokens"] += inp - cached_in
            bm["cache_read_input_tokens"] += cached_in
            bm["cache_creation_input_tokens"] += cache_w
            bm["output_tokens"] += out
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
        "cache_creation": tot["cache_write"],
        "models": dict(models.most_common(8)),
        "cost": price(bymodel),
        "by_project": _top_projects(byproj),
        "days": [{"d": d, "billed": byday[d]["billed"], "msgs": byday[d]["msgs"]} for d in days],
    }
    try:
        json.dump({"at": int(time.time()), "data": data}, open(CODEX_TOKEN_CACHE, "w"))
    except Exception:
        pass
    return data


GROK_SESSIONS = os.path.expanduser("~/.grok/sessions")
GROK_TOKEN_CACHE = os.path.join(STATE_DIR, "grok-tokens.json")


def fetch_grok_tokens():
    """Lifetime + daily Grok CLI token usage from ~/.grok/sessions/*/*/updates.jsonl.

    Every completed turn logs a `usage` block with per-model tokens and the CLI's own
    cost in `costUsdTicks` (nano-dollars: a 2.7M-token turn logged 3.81e9 ticks against
    $3.68 by list price, so 1e9 ticks = US$1). That figure is used as the cost rather
    than a pricing table of our own."""
    try:
        cached = json.load(open(GROK_TOKEN_CACHE))
        if time.time() - cached.get("at", 0) < TOKEN_TTL:
            return cached["data"]
    except Exception:
        pass
    import collections, datetime, glob
    tot = collections.Counter()
    byday = collections.defaultdict(collections.Counter)
    models = collections.Counter()
    bymodel = collections.defaultdict(collections.Counter)
    turns = calls = 0
    sessions = set()
    byproj = collections.Counter()
    import urllib.parse
    for f in glob.glob(os.path.join(GROK_SESSIONS, "*", "*", "updates.jsonl")):
        label = _activity(urllib.parse.unquote(os.path.basename(os.path.dirname(os.path.dirname(f)))))
        try:
            for line in open(f, errors="replace"):
                if '"turn_completed"' not in line or '"usage"' not in line:
                    continue
                try:
                    d = json.loads(line)
                    u = d["params"]["update"]["usage"]
                except Exception:
                    continue
                turns += 1
                sessions.add(f)
                calls += u.get("modelCalls", 0) or 0
                inp = u.get("inputTokens", 0) or 0
                out = u.get("outputTokens", 0) or 0
                cached_in = u.get("cachedReadTokens", 0) or 0
                tot["input"] += inp; tot["output"] += out; tot["cache_read"] += cached_in
                tot["cache_write"] += u.get("cacheCreationTokens", 0) or 0
                tot["ticks"] += u.get("costUsdTicks", 0) or 0
                day = datetime.datetime.fromtimestamp(
                    d.get("timestamp", 0), datetime.timezone.utc).date().isoformat()
                byday[day]["billed"] += inp - cached_in + out
                byday[day]["msgs"] += 1
                byproj[label] += inp - cached_in + out
                for m, mu in (u.get("modelUsage") or {}).items():
                    models[m] += mu.get("modelCalls", 0) or 1
                    bymodel[m]["ticks"] += mu.get("costUsdTicks", 0) or 0
        except Exception:
            pass
    if not turns:
        return {"error": "no_sessions"}
    fx, as_of, stale = fx_rate()
    if not fx:
        cost = {"error": "no_fx_rate"}
    else:
        rows = sorted(({"model": m, "cost": round(c["ticks"] / 1e9 * fx, 2)}
                       for m, c in bymodel.items()), key=lambda r: -r["cost"])
        basis = "cost as reported by the Grok CLI itself (costUsdTicks, 1e9 = US$1)"
        if CURRENCY != "USD":
            basis += ", converted at %.4f USD/%s (%s)" % (fx, CURRENCY, as_of or "unknown")
        if stale:
            basis = "STALE RATE - " + basis
        cost = {"currency": CURRENCY, "total": round(tot["ticks"] / 1e9 * fx, 2),
                "by_model": rows, "fx_rate": fx, "fx_as_of": as_of, "fx_stale": stale,
                "basis": basis}
    days = sorted(byday)[-TOKEN_DAYS:]
    data = {
        "ok": True,
        "messages": turns,
        "api_messages": len(sessions),
        "billed": tot["input"] - tot["cache_read"] + tot["output"],
        "cache_read": tot["cache_read"],
        "input": tot["input"],
        "output": tot["output"],
        "cache_creation": tot["cache_write"],
        "models": dict(models.most_common(8)),
        "cost": cost,
        "by_project": _top_projects(byproj),
        "days": [{"d": d, "billed": byday[d]["billed"], "msgs": byday[d]["msgs"]} for d in days],
    }
    try:
        json.dump({"at": int(time.time()), "data": data}, open(GROK_TOKEN_CACHE, "w"))
    except Exception:
        pass
    return data


AGY_CONVERSATION_DIRS = [os.path.expanduser("~/.gemini/antigravity-cli/conversations"),
                         os.path.expanduser("~/.gemini/antigravity/conversations")]
AGY_TOKEN_INDEX = os.path.join(STATE_DIR, "agy-tokens-index.json")
AGY_TOKEN_CACHE = os.path.join(STATE_DIR, "agy-tokens.json")
# Model code -> id, established 2026-09-06 by running one-word prompts with a known
# --model and reading the code back. Anything else is reported by number, unpriced.
AGY_MODELS = {1318: "gemini-3.8-flash-high", 1319: "gemini-3.8-flash-medium",
              1320: "gemini-3.8-flash-low",
              1298: "gemini-3.7-flash-high", 1299: "gemini-3.7-flash-medium",
              1300: "gemini-3.7-flash-low",
              1071: "gemini-3.6-flash-high", 1072: "gemini-3.6-flash-medium",
              1073: "gemini-3.6-flash-low",
              1016: "gemini-3.1-pro-high", 1036: "gemini-3.1-pro-low",
              1035: "claude-sonnet-4-6", 1026: "claude-opus-4-6-thinking",
              342: "gpt-oss-120b-medium",
              # One IDE call on 2026-06-27 on a Gemini-family model (family code 24)
              # that the CLI no longer offers, so it cannot be test-mapped.
              1050: "gemini-retired-code-1050"}


def _activity(path):
    """Working directory -> a short activity label for the by-activity breakdown.
    A proxy, not a truth: interactive sessions started from the home directory all
    land in one bucket, while fleet and project work separates cleanly."""
    if not path:
        return "unknown"
    home = os.path.expanduser("~")
    p = path.rstrip("/")
    if p == home:
        return "home (interactive)"
    vault = "/Documents/karpathy-vault"
    if vault in p:
        rest = p.split(vault, 1)[1].strip("/")
        return "vault" if not rest else "vault: " + rest.split("/")[-1]
    if p.startswith(home + "/code/"):
        return "code: " + p[len(home) + 6:].split("/")[0]
    if p.startswith("/private/tmp") or p.startswith("/tmp"):
        parts = p.split("/")
        return "scratch: " + parts[3] if len(parts) > 3 else "scratch"
    if p.startswith(home + "/"):
        return "home: " + p[len(home) + 1:].split("/")[0]
    return p.split("/")[-1] or p


def _claude_project_path(dirname):
    """~/.claude/projects encodes the cwd by replacing every '/' with '-', which is
    ambiguous for names containing hyphens. Resolve the vault and home prefixes,
    which is enough for the activity label."""
    home = os.path.expanduser("~")
    enc_home = home.replace("/", "-")
    # '~' and ' ' are encoded as '-' as well, so the vault prefix has none of them.
    for enc_vault in (enc_home + "-Library-Mobile-Documents-iCloud-md-obsidian-Documents-karpathy-vault",
                      enc_home + "-Library-Mobile-Documents-com-apple-CloudDocs-Documents-karpathy-vault"):
        if dirname.startswith(enc_vault):
            return home + "/Documents/karpathy-vault" + dirname[len(enc_vault):].replace("-", "/", 1)
    if dirname.startswith(enc_home):
        return home + dirname[len(enc_home):].replace("-", "/", 1)
    return dirname.replace("-", "/")


def _top_projects(counter, n=8):
    rows = sorted(counter.items(), key=lambda kv: -kv[1])
    return [{"name": k, "billed": v} for k, v in rows[:n]]


def _pb_top(b):
    """(field, wire_type, value) for one protobuf message; stops at the first oddity."""
    out, i = [], 0
    while i < len(b):
        try:
            key, i = _varint(b, i)
        except Exception:
            break
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, i = _varint(b, i); out.append((fn, 0, v))
        elif wt == 1:
            i += 8
        elif wt == 5:
            i += 4
        elif wt == 2:
            ln, i = _varint(b, i); out.append((fn, 2, b[i:i + ln])); i += ln
        else:
            break
    return out


def _varint(buf, i):
    val = shift = 0
    while i < len(buf):
        b = buf[i]; i += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, i
        shift += 7
    raise ValueError("truncated varint")


def _agy_conversation_totals(path):
    """Per-day and per-model token totals for one conversation SQLite file.

    Each step's `metadata` blob carries, at field 9, a usage message: 1 = model code,
    2 = uncached input, 3 = output, 5 = cached input, 9 = thinking, 10 = text, with
    3 == 9 + 10 on every record checked. Field 1 of the same blob holds a Timestamp
    (sub-field 1 = epoch seconds) used for the day bucket."""
    import sqlite3, datetime
    byday, bymodel, calls = {}, {}, 0
    db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
    try:
        rows = db.execute("select metadata from steps").fetchall()
    finally:
        db.close()
    for (blob,) in rows:
        if not blob:
            continue
        top = _pb_top(bytes(blob))
        usage = next((v for fn, wt, v in top if fn == 9 and wt == 2), None)
        if usage is None:
            continue
        u = {k: v for k, w, v in _pb_top(usage) if w == 0}
        if 2 not in u or 3 not in u:
            continue
        ts = next((v for fn, wt, v in top if fn == 1 and wt == 2), None)
        epoch = next((v for k, w, v in _pb_top(ts) if k == 1 and w == 0), 0) if ts else 0
        day = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).date().isoformat() if epoch else ""
        model = AGY_MODELS.get(u.get(1), "agy-model-%s" % u.get(1))
        inp, out, cached = u.get(2, 0), u.get(3, 0), u.get(5, 0)
        calls += 1
        d = byday.setdefault(day, {"billed": 0, "msgs": 0})
        d["billed"] += inp + out; d["msgs"] += 1
        m = bymodel.setdefault(model, {"input_tokens": 0, "output_tokens": 0,
                                      "cache_read_input_tokens": 0,
                                      "cache_creation_input_tokens": 0, "calls": 0})
        m["input_tokens"] += inp; m["output_tokens"] += out
        m["cache_read_input_tokens"] += cached; m["calls"] += 1
    return {"byday": byday, "bymodel": bymodel, "calls": calls}


def fetch_agy_tokens():
    """Lifetime + daily agy / Antigravity token usage. Per-file index like Codex."""
    try:
        cached = json.load(open(AGY_TOKEN_CACHE))
        if time.time() - cached.get("at", 0) < TOKEN_TTL:
            return cached["data"]
    except Exception:
        pass
    try:
        index = json.load(open(AGY_TOKEN_INDEX))
    except Exception:
        index = {}
    import collections
    live = {}
    for d in AGY_CONVERSATION_DIRS:
        for fn in (os.listdir(d) if os.path.isdir(d) else []):
            if not fn.endswith(".db"):
                continue
            p = os.path.join(d, fn)
            try:
                st = os.stat(p)
            except OSError:
                continue
            # The version tag forces a rescan when AGY_MODELS gains a mapping, since
            # model names are resolved at scan time.
            key = "v2:%d:%d" % (st.st_size, int(st.st_mtime))
            ent = index.get(p)
            if not ent or ent.get("key") != key:
                try:
                    ent = {"key": key, **_agy_conversation_totals(p)}
                except Exception:
                    continue
            live[p] = ent
    index = live
    try:
        json.dump(index, open(AGY_TOKEN_INDEX, "w"))
    except Exception:
        pass

    tot = collections.Counter()
    byday = collections.defaultdict(collections.Counter)
    models = collections.Counter()
    bymodel = collections.defaultdict(collections.Counter)
    calls = convs = 0
    for ent in index.values():
        if not ent.get("calls"):
            continue
        convs += 1; calls += ent["calls"]
        for day, v in ent["byday"].items():
            if day:
                byday[day]["billed"] += v["billed"]; byday[day]["msgs"] += v["msgs"]
        for m, v in ent["bymodel"].items():
            models[m] += v["calls"]
            for k in ("input_tokens", "output_tokens", "cache_read_input_tokens",
                      "cache_creation_input_tokens"):
                bymodel[m][k] += v[k]; tot[k] += v[k]
    if not calls:
        return {"error": "no_sessions"}
    days = sorted(byday)[-TOKEN_DAYS:]
    data = {
        "ok": True,
        "messages": calls,
        "api_messages": convs,
        # agy already reports uncached and cached input separately, so billed is in + out.
        "billed": tot["input_tokens"] + tot["output_tokens"],
        "cache_read": tot["cache_read_input_tokens"],
        "input": tot["input_tokens"] + tot["cache_read_input_tokens"],
        "output": tot["output_tokens"],
        "cache_creation": 0,
        "models": dict(models.most_common(8)),
        "cost": price(bymodel),
        "days": [{"d": d, "billed": byday[d]["billed"], "msgs": byday[d]["msgs"]} for d in days],
    }
    try:
        json.dump({"at": int(time.time()), "data": data}, open(AGY_TOKEN_CACHE, "w"))
    except Exception:
        pass
    return data


def main():
    fetchers = {"claude": fetch_claude, "antigravity": fetch_antigravity,
                "codex": fetch_codex, "tokens": fetch_tokens,
                "codex_tokens": fetch_codex_tokens, "grok_tokens": fetch_grok_tokens,
                "agy_tokens": fetch_agy_tokens}
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
