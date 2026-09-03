#!/bin/bash
# Keep AI Usage alive on the iPhone without manual intervention.
#
# Run on a short interval by launchd. Does nothing unless BOTH:
#   1. the iPhone is currently discoverable by CoreDevice (same Wi-Fi as this Mac), and
#   2. the provisioning profile is close to expiry, or the periodic floor has elapsed.
#
# Why not a plain 5-day timer: Xcode reuses a provisioning profile that is still valid,
# so a deploy well before expiry renews nothing (verified 2026-07-24: deploying with
# 166h left left the expiry date untouched). Deploying only helps near expiry, so the
# expiry window is the real trigger and the day floor is a backstop.

set -uo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

REPO="$(cd "$(dirname "$0")" && pwd)"
STATE="$HOME/.ai-usage-deploy/autodeploy-state.json"
LOG="$HOME/Library/Logs/ai-usage-autodeploy.log"

# Signing identity: the team from .team-id (gitignored) and the bundle ID from the
# project, so nothing personal is baked into this script.
TEAM=$(tr -d '[:space:]' < "$REPO/.team-id" 2>/dev/null || true)
BUNDLE=$(grep -o 'PRODUCT_BUNDLE_IDENTIFIER = [^;]*' "$REPO/AIUsage.xcodeproj/project.pbxproj" | head -1 | sed 's/.*= //')
[ -z "$TEAM" ] && { echo "auto-deploy: no .team-id in $REPO" >&2; exit 1; }

RENEW_WINDOW_H=72        # deploy once the profile has less than this left
DAY_FLOOR=5              # ...or if this many days have passed since the last deploy
MIN_GAP_H=4              # never retry more often than this, unless already expired

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")"
log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# --- is the phone here? -----------------------------------------------------
# Absent is the normal case (phone out of the house) -- exit quietly, no log spam.
UDID=$(xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    hw, conn = dev.get("hardwareProperties", {}), dev.get("connectionProperties", {})
    if hw.get("deviceType") != "iPhone" or conn.get("pairingState") != "paired":
        continue
    if conn.get("transportType") in ("localNetwork", "wired"):
        print(dev.get("identifier", ""))
        break
' 2>/dev/null)
[ -z "$UDID" ] && exit 0

# --- should we deploy? ------------------------------------------------------
DECISION=$(python3 - "$STATE" "$RENEW_WINDOW_H" "$DAY_FLOOR" "$MIN_GAP_H" "$TEAM" "$BUNDLE" <<'PY'
import datetime, glob, json, os, plistlib, subprocess, sys

state_path, window_h, day_floor, min_gap_h = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
team, bundle = sys.argv[5], sys.argv[6]
now = datetime.datetime.now(datetime.timezone.utc)

# Both App IDs need a live profile: the app will not install if either is missing or
# stale. Substring-matching the app ID alone also matches the Widget, so a missing app
# profile could be masked by a healthy Widget one and reported as fine.
NEEDED = ["%s.%s" % (team, bundle), "%s.%s.Widget" % (team, bundle)]
found = {}
for p in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")):
    try:
        d = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True).stdout)
    except Exception:
        continue
    appid = d.get("Entitlements", {}).get("application-identifier", "")
    if appid not in NEEDED:
        continue
    exp = d["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    h = (exp - now).total_seconds() / 3600
    found[appid] = h if appid not in found else max(found[appid], h)

if any(a not in found for a in NEEDED):
    hours_left = 0.0          # a missing profile is an outage, not an unknown
else:
    hours_left = min(found.values())

try:
    st = json.load(open(state_path))
except Exception:
    st = {}
last = st.get("last_attempt_at", 0)
if not last:
    # First run: seed the clock instead of deploying. A deploy this far from expiry
    # renews nothing, so it would be pure churn.
    json.dump({"last_attempt_at": now.timestamp(), "seeded": True}, open(state_path, "w"))
    gap_h = 0.0
else:
    gap_h = (now.timestamp() - last) / 3600

expired = hours_left is None or hours_left <= 0
near_expiry = hours_left is not None and hours_left < window_h
floor_due = gap_h >= day_floor * 24

if expired:
    reason = "profile expired"
elif near_expiry and gap_h >= min_gap_h:
    reason = "profile expires in %.1fh" % hours_left
elif floor_due:
    reason = "%.1f days since last attempt" % (gap_h / 24)
elif near_expiry:
    print(json.dumps({"go": False, "hours_left": hours_left,
                      "reason": "profile expires in %.1fh but only %.1fh since last attempt (min gap %.0fh)" % (hours_left, gap_h, min_gap_h)}))
    sys.exit(0)
else:
    print(json.dumps({"go": False, "hours_left": hours_left,
                      "reason": "profile has %.1fh left (renew window %.0fh) and %.1f days since last attempt (floor %.0f)" % (hours_left, window_h, gap_h / 24, day_floor)}))
    sys.exit(0)

print(json.dumps({"go": True, "reason": reason, "hours_left": hours_left}))
PY
)
GO=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("go"))' 2>/dev/null)
if [ "$GO" != "True" ]; then
    # Phone-absent already exited quietly above; every other decline gets a line, so a
    # hand-run is never indistinguishable from a successful deploy.
    WHY=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)
    log "declined: ${WHY:-no decision returned (guard script failed)}"
    exit 0
fi

REASON=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason",""))' 2>/dev/null)
BEFORE=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; h=json.load(sys.stdin).get("hours_left"); print("%.1f"%h if h is not None else "none")' 2>/dev/null)

log "deploying: $REASON (profile had ${BEFORE}h left)"

# Xcode reuses any profile that is still on disk and mints a new one only when none
# matches. Deploying inside the renewal window therefore renews NOTHING (verified
# 2026-08-14: five deploys from 29.6h down to 13.6h all reported ok and left the expiry
# untouched, so the app died at expiry anyway). Move the current AIUsage profiles aside
# so Xcode has to mint, and put them back if the deploy fails, so a failure never costs
# a working profile.
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
STASH="$HOME/.ai-usage-deploy/stashed-profiles"
rm -rf "$STASH"; mkdir -p "$STASH"
for p in "$PROFILES"/*.mobileprovision; do
    [ -e "$p" ] || continue
    if security cms -D -i "$p" 2>/dev/null | grep -q "$BUNDLE"; then
        mv "$p" "$STASH/"
    fi
done

OUT=$("$REPO/deploy-to-iphone.sh" 2>&1)
RC=$?

if [ $RC -ne 0 ]; then
    # Xcode mints before it installs, so a failed install still leaves new profiles on
    # disk. Those outlive the ones the phone is actually running, and the expiry check
    # above (max per app-ID) then reads a profile that was never installed and declines
    # to renew until after the app has already died. Verified 2026-08-30: an install
    # that failed on CoreDeviceError 12040 left a 6 Sep mint next to the 2 Sep profile
    # the phone had, and every run for the next 17h reported "158.0h left". Discard the
    # mints first, then put back exactly what was there.
    for p in "$PROFILES"/*.mobileprovision; do
        [ -e "$p" ] || continue
        if security cms -D -i "$p" 2>/dev/null | grep -q "$BUNDLE"; then
            rm -f "$p"
        fi
    done
    for p in "$STASH"/*.mobileprovision; do
        [ -e "$p" ] || continue
        mv "$p" "$PROFILES/"
    done
fi
rm -rf "$STASH"

# --- record outcome, and whether the profile actually moved -----------------
python3 - "$STATE" "$RC" "$BEFORE" "$TEAM" "$BUNDLE" >/dev/null 2>&1 <<'PY'
import datetime, glob, json, os, plistlib, subprocess, sys
state_path, rc, before = sys.argv[1], int(sys.argv[2]), sys.argv[3]
team, bundle = sys.argv[4], sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc)
NEEDED = ["%s.%s" % (team, bundle), "%s.%s.Widget" % (team, bundle)]
found = {}
for p in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")):
    try:
        d = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", p], capture_output=True).stdout)
    except Exception:
        continue
    appid = d.get("Entitlements", {}).get("application-identifier", "")
    if appid not in NEEDED:
        continue
    exp = d["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    h = (exp - now).total_seconds() / 3600
    found[appid] = h if appid not in found else max(found[appid], h)
after = 0.0 if any(a not in found for a in NEEDED) else min(found.values())
st = {"last_attempt_at": now.timestamp(),
      "last_rc": rc,
      "hours_left_after": round(after, 1) if after is not None else None}
if rc == 0:
    st["last_success_at"] = now.timestamp()
json.dump(st, open(state_path, "w"))
PY
AFTER=$(python3 -c "import json;print(json.load(open('$STATE')).get('hours_left_after'))" 2>/dev/null)

# Log every occurrence, but pop a notification at most every 6h: while the profile is
# expired the min-gap guard is bypassed, so this runs every 30 minutes.
alert() {
    log "ALERT: $1"
    STAMP="$HOME/.ai-usage-deploy/last-alert"
    if [ ! -e "$STAMP" ] || [ $(( $(date +%s) - $(stat -f %m "$STAMP") )) -gt 21600 ]; then
        osascript -e "display notification \"$1\" with title \"AI Usage deploy\"" >/dev/null 2>&1
        touch "$STAMP"
    fi
}

# rc=0 is not success. The only outcome that matters is whether the profile clock
# actually moved; a deploy that leaves it where it was means the app still dies on
# schedule, and that is the failure that went unnoticed for a week.
RENEWED=$(python3 -c "
b, a = '$BEFORE', '$AFTER'
try:
    # 'none' is the no-profile-at-all case: any profile at all is a renewal there.
    before = 0.0 if b == 'none' else float(b)
    print('yes' if float(a) > before + 1 else 'no')
except ValueError:
    print('no')
" 2>/dev/null)

if [ $RC -ne 0 ]; then
    ERR=$(printf '%s' "$OUT" | grep -E 'error|ERROR' | head -2 | tr '\n' ' ')
    log "FAILED rc=$RC: $ERR"
    case "$ERR" in
        *"No Accounts"*|*"No Account for Team"*)
            alert "Xcode is not signed in. Sign in at Xcode > Settings > Accounts. AI Usage cannot be renewed until then." ;;
        *) alert "AI Usage deploy failed (rc=$RC). See ~/Library/Logs/ai-usage-autodeploy.log" ;;
    esac
elif [ "$RENEWED" != "yes" ]; then
    alert "AI Usage deployed but the profile did NOT renew (still ${AFTER}h left). App will stop working when it expires."
else
    log "ok: profile now ${AFTER}h left (was ${BEFORE}h)"
fi
exit 0
