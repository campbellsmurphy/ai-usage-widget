#!/bin/bash
# Build and install AI Usage onto a connected iPhone.
#
# Discovers the signing team and the device itself, so there is nothing to look up.
# Override the team with:  ./deploy-to-iphone.sh <TEAM_ID>
#
# Free Apple ID certificates expire after 7 days -- when the app stops launching or the
# widget goes blank, re-run this. A paid Developer Program membership lasts a year.

set -euo pipefail
cd "$(dirname "$0")"

DERIVED=".build"
APP="$DERIVED/Build/Products/Debug-iphoneos/AIUsage.app"

# --- signing team -----------------------------------------------------------
TEAM="${1:-}"
if [ -z "$TEAM" ]; then
    # Read the team from an existing provisioning profile. Do NOT parse it out of the
    # certificate name: for a free personal team the value in parentheses there is a
    # different identifier and xcodebuild rejects it with "No Account for Team".
    TEAM=$(python3 -c '
import glob, os, plistlib, subprocess, sys
best = None
for p in glob.glob(os.path.expanduser(
        "~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision")):
    try:
        raw = subprocess.run(["security", "cms", "-D", "-i", p],
                             capture_output=True).stdout
        d = plistlib.loads(raw)
        ids = d.get("TeamIdentifier") or []
        exp = d.get("ExpirationDate")
        if ids and (best is None or (exp and exp > best[1])):
            best = (ids[0], exp)
    except Exception:
        pass
print(best[0] if best else "")
' 2>/dev/null || true)
fi
# Renewal moves the expired profiles aside before building, so profile-derived discovery
# finds nothing exactly when a deploy is most needed. Fall back to the team recorded in
# .team-id (gitignored; write your own team ID there once).
[ -z "$TEAM" ] && [ -f .team-id ] && TEAM=$(tr -d '[:space:]' < .team-id)
if [ -z "$TEAM" ]; then
    cat >&2 <<'EOF'
Could not determine a signing team (no provisioning profile found).

Fix: open Xcode > Settings > Accounts > "+" > Apple ID and sign in with your normal
Apple ID (a free Personal Team is enough). Xcode must build once from the GUI to
create the first profile; after that this script finds the team on its own.

Or pass the team explicitly:  ./deploy-to-iphone.sh <TEAM_ID>
EOF
    exit 1
fi
echo "Signing team: $TEAM"

# --- device -----------------------------------------------------------------
UDID=$(xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null \
       | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    conn = dev.get("connectionProperties", {})
    # Must be an iPhone specifically -- a paired Apple Watch also shows up here.
    if hw.get("platform") != "iOS" or hw.get("deviceType") != "iPhone":
        continue
    if conn.get("pairingState") == "paired":
        print(dev.get("identifier", ""))
        break
' || true)

if [ -z "$UDID" ]; then
    cat >&2 <<'EOF'
No paired iPhone found.

Checklist:
  1. Connect the iPhone by USB and tap "Trust" on the phone.
  2. Settings > Privacy & Security > Developer Mode > on, then restart the phone.
     (Developer Mode only appears after a Mac has tried to install a dev build,
      so if you cannot see it, run this script once with the phone plugged in.)
  3. Re-run this script.
EOF
    exit 1
fi
echo "Device: $UDID"

# --- build ------------------------------------------------------------------
# -allowProvisioningUpdates lets Xcode mint the profile for the personal team.
echo "Building..."
xcodebuild \
    -project AIUsage.xcodeproj \
    -scheme AIUsage \
    -configuration Debug \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" \
    build 2>&1 | grep -E "error:|BUILD" || true

[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

# --- install ----------------------------------------------------------------
echo "Installing..."
xcrun devicectl device install app --device "$UDID" "$APP"

cat <<'EOF'

Installed.

If the app refuses to launch, trust the certificate once:
  Settings > General > VPN & Device Management > your Apple ID > Trust

Then add the widget: long-press the home screen > Edit > Add Widget > "AI Usage".
Tailscale must be connected on the phone or every row will read n/a.
EOF
