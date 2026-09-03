# AI Usage

A native iOS app and home-screen widget showing how much of each AI plan has been consumed:
Claude, Grok, Codex and Antigravity, plus Claude Code token history and a counterfactual API cost.
Self-hosted: a small Python aggregator on a Mac you own serves one JSON file over Tailscale or
your LAN, and the phone reads it. No account, no cloud relay, no credentials on the phone.

Providers are optional. Configure the ones you have and the app and widget show only those rows.

## Is this the right tool?

Probably not, if you want the mainstream option. [CodexBar](https://github.com/steipete/CodexBar)
covers dozens of providers on the Mac menu bar, and [CodexBar-Mobile](https://github.com/o1xhack/CodexBar-Mobile)
puts them on an iPhone widget via iCloud. Use those if a Mac app plus CloudKit suits you.

This repo exists for the self-hosting case: a collector on the machine where your tools are
logged in, an aggregator on an always-on box, one token-guarded JSON endpoint, and a widget that
reads it. It also does two things I could not find elsewhere:

- **Early-reset detection.** Providers hand out resets before the advertised time (on this
  account, 8 of 10 Codex weekly windows ended early, median 2.5 days against an advertised 7).
  The aggregator watches for usage dropping to zero well before the reset, pushes an ntfy alert,
  and after enough history shows an *estimated* reset alongside the advertised one.
- **A costed token history.** Claude Code session logs are rescanned and de-duplicated by
  message id, then priced at list API rates in your currency, so you can see what the flat-rate
  plan is actually worth to you.

## What it shows

**Widget** (small, medium, Lock Screen): Claude 5-hour / weekly / scoped, Grok weekly, Codex
weekly, Antigravity Gemini and Claude+GPT. An `AT LIMIT` badge appears when any metric hits 100%.
Rows for unconfigured providers are simply absent.

**App**: the same, plus reset times, both used and remaining figures per row, and a Token history
screen: daily chart, lifetime totals, per-model breakdown, and what the usage would have cost at
list API rates.

Every percentage in this project is **consumption**. Antigravity's own Models screen shows the
inverse (what is left), so its numbers are flipped once, at collection time, and each row also
prints the remaining figure so the two screens can never appear to disagree.

## Architecture

```
always-on Mac (aggregator)                    the Mac your tools are logged in on (collector)
┌───────────────────────────┐                 ┌──────────────────────────────┐
│ ai_usage_aggregator.py    │◀── POST /push ──│ collector.py (every 20 min)  │
│  · Claude  oauth/usage    │                 │  · Claude usage (own token)  │
│  · Grok    gRPC-web       │                 │  · Antigravity loopback RPC  │
│  · serves usage.json      │                 │  · Codex ChatGPT plan quota  │
│                           │                 │  · token history + costing   │
└───────────┬───────────────┘                 └──────────────────────────────┘
            │ Tailscale or LAN
            ▼
      iPhone: app + WidgetKit extension (20-min timeline)
```

The collector pushes **computed percentages only**. No credential ever leaves the machine that
owns it. If one Mac plays both roles, run both scripts on it.

### Why the split

The aggregator lives on an always-on machine so readings stay fresh when your laptop is asleep.
But Antigravity's quota RPC is only reachable on the machine running it (loopback, and its port
and CSRF token change every launch), and Codex's token lives in that machine's `~/.codex`, so
those have to originate there. Claude rides the same channel as a fallback for when the
aggregator's own keychain copy cannot authenticate.

Consequence, surfaced in the UI rather than hidden: **collector-fed rows are only fresh while the
collector is awake.** Pushes older than 45 minutes are marked stale.

## Data sources

| Source | Endpoint | Notes |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` | OAuth token from Claude Code's own credentials |
| Grok | `POST grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig` | gRPC-web, cookie auth, hand-parsed protobuf (two fields, no dependency) |
| Codex | `GET chatgpt.com/backend-api/codex/usage` | Bearer token from `~/.codex/auth.json` (Codex CLI refreshes it; read-only here) |
| Antigravity | `POST 127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` | header `x-codeium-csrf-token`; port and token discovered per run |
| Token history | `~/.claude/projects/**/*.jsonl` | full rescan (about 5s over 2 GB), de-duplicated by message id |

**The Grok, Codex and Antigravity endpoints are private and undocumented. They will break.** When
Grok's does, re-find it by hooking `window.fetch` on a fresh page load, then opening
Settings > Usage. The network panel alone does not show it, because the value is cached after
the dialog first opens.

## Two counting subtleties

**Token de-duplication.** One API message spans several logged lines when it contains multiple
content blocks (text plus tool calls). Tokens must be counted once per message id or they
inflate about 2.3x. The *message count* deliberately does not de-duplicate: it counts logged
entries, which is what Claude Code itself reports.

**Cost is a counterfactual.** These are flat-rate plans; the figure is what the same tokens would
have cost on pay-as-you-go pricing. Cache writes are billed at 1.25x input (5-minute TTL) and
cache reads at 0.1x. USD list rates are converted to the currency in the collector config at a
rate fetched live and cached daily; a stale rate is flagged in the UI rather than silently used.
Model prices are a table at the top of `collector.py`; update it when models change.

## Setup

### 1. Aggregator (always-on Mac)

```bash
mkdir -p ~/.ai-usage-aggregator
cp infra/ai_usage_aggregator.py ~/.ai-usage-aggregator/
cat > ~/.ai-usage-aggregator/config.json <<'EOF'
{"token": "a-long-random-string", "port": 8756,
 "providers": ["claude", "grok"],
 "ntfy_url": "https://ntfy.sh/your-private-topic"}
EOF
sed "s|__HOME__|$HOME|g" infra/ai-usage-aggregator.plist > ~/Library/LaunchAgents/ai-usage-aggregator.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai-usage-aggregator.plist
```

`providers` is what this machine reads itself. Claude needs Claude Code logged in here (it reads
the login keychain item). Grok needs `~/.ai-usage-aggregator/grok.json` with `{"cookie": "...",
"ua": "..."}` copied from a logged-in grok.com session. Drop `ntfy_url` to disable early-reset
alerts. Leave a provider out and it never appears on the phone.

### 2. Collector (the Mac where Codex, Antigravity and Claude Code run)

```bash
mkdir -p ~/.ai-usage-collector
cp infra/collector.py ~/.ai-usage-collector/
cat > ~/.ai-usage-collector/config.json <<'EOF'
{"aggregator": "http://100.x.x.x:8756", "token": "a-long-random-string",
 "providers": ["claude", "antigravity", "codex", "tokens"], "currency": "AUD"}
EOF
sed "s|__HOME__|$HOME|g" infra/ai-usage-collector.plist > ~/Library/LaunchAgents/ai-usage-collector.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai-usage-collector.plist
```

The collector LaunchAgent must run under **Homebrew python, not `/usr/bin/python3`**:
chatgpt.com's Cloudflare returns 403 to the LibreSSL TLS fingerprint of Apple's python and system
curl, which freezes the Codex row. The plist tries `/opt/homebrew/bin/python3` first and falls
back down a path list so a missing brew python degrades to a frozen Codex row (which the widget
flags) rather than killing the whole collector. Do not simplify it back to a bare python path.

Skip this step entirely if you only want Claude and Grok; the aggregator alone covers those.

### 3. Phone

```bash
cp Shared/Secrets.example.swift Shared/Secrets.swift   # fill in host(s) + token
./deploy-to-iphone.sh                                  # discovers team + device itself
```

Change `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project to your own reverse-DNS name before the
first build. `deploy-to-iphone.sh` reads the signing team from an existing provisioning profile,
falling back to a `.team-id` file (gitignored) in the repo root. Do **not** parse the team out of
the certificate name: for a free personal team the value in parentheses there is a different
identifier, and `xcodebuild` rejects it with a misleading "No Account for Team".

Free Apple ID certificates expire after **7 days**; re-run the script when the app stops
launching or the widget goes blank. A paid Developer Program membership makes it annual.

On the phone, Tailscale must be connected (or you must be on the LAN host) or every row reads
`n/a`. The app keeps its last good reading and labels it "offline" rather than blanking.

### Automatic redeploy

`auto-deploy.sh` plus `infra/ai-usage-autodeploy.plist` keep the app alive on a free team without
intervention. It runs every 30 minutes and exits silently unless the iPhone is **discoverable by
CoreDevice** (same Wi-Fi as this Mac) **and** the profile is within 72h of expiry, or 5 days have
passed as a backstop.

```bash
echo YOURTEAMID > .team-id
sed "s|__HOME__|$HOME|g; s|__REPO__|$PWD|g" infra/ai-usage-autodeploy.plist > ~/Library/LaunchAgents/ai-usage-autodeploy.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai-usage-autodeploy.plist
```

**A plain 5-day timer would not work.** Xcode reuses a provisioning profile that is still valid,
so deploying well before expiry renews nothing (verified twice: a deploy with 166h remaining left
the expiry date untouched). Only proximity to expiry causes a new profile to be issued, and even
then the script has to move the current profiles aside first so Xcode is forced to mint.

**Tailscale cannot substitute for the local network here.** The phone is a tailnet node and is
pingable, but `devicectl` only accepts devices discovered via CoreDevice, whose
`.coredevice.local` names resolve over **mDNS only**. Tailscale is a layer-3 unicast overlay and
does not forward multicast, so discovery never happens across it. Targeting the MagicDNS name
directly fails with `CoreDeviceError 1000, device not found`.

Log: `~/Library/Logs/ai-usage-autodeploy.log` (written only when it actually deploys or declines).

## What is and is not committed

- `Shared/Secrets.swift` (aggregator hosts and token) and `.team-id` are gitignored. Copy the
  example file and fill it in.
- Both `Info.plist` files set `NSAllowsArbitraryLoads`, because the aggregator is plain http on a
  private network and its address is per-install. If you would rather list your host as an ATS
  exception, do that instead.
- `infra/` is a **reference copy** of the server-side scripts. The live copies run from
  `~/.ai-usage-aggregator/` and `~/.ai-usage-collector/` under launchd; editing `infra/` changes
  nothing until you copy it across.

## Repository layout

| Path | |
|---|---|
| `AIUsage/` | App target: main screen, token history, cost |
| `AIUsageWidget/` | WidgetKit extension |
| `Shared/` | Models, loader, widget views (shared by both targets) |
| `infra/` | Aggregator, collector, and the three LaunchAgent plists |
| `deploy-to-iphone.sh` | Build and install to a connected iPhone |
| `auto-deploy.sh` | Unattended re-sign near profile expiry |

## Known gaps

- Medium and Lock Screen widget sizes have been verified through the in-app preview and on one
  phone only.
- Token history covers Claude Code on the collector machine only: not claude.ai, and not Grok or
  Antigravity, neither of which exposes token counts at all.
- Threshold alerts (ntfy at 80% / 100% on weekly limits) are designed but not built.
- Adding a provider means a fetcher in the aggregator or collector, a `Decodable` struct in
  `Shared/UsageModel.swift`, and a row in the views. There is no plugin layer; four providers did
  not justify one.

## Licence

MIT.
