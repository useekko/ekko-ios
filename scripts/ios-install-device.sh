#!/usr/bin/env bash
# Build Ekko for a real iPhone and install it.
#
#   scripts/ios-install-device.sh            # build + install on the first connected device
#   scripts/ios-install-device.sh --wait     # wait for a device to be plugged in, then do it
#
# Requires: the phone plugged in (or on Wi-Fi with "Connect via Network" ticked in Xcode's
# Devices window), UNLOCKED, and Developer Mode on (Settings > Privacy & Security > Developer Mode).
#
# `devicectl list devices` will happily report a paired-but-absent phone as "connected"; the field
# that actually matters is transportType. If it says None, there is no live channel and the install
# will fail with the unhelpful "unable to locate a device matching the requested device identifier".
set -euo pipefail

cd "$(dirname "$0")/.."
DD="${TMPDIR:-/tmp}/ekko-device-dd"

# Prints:  <coredevice-uuid> <hardware-udid> <name>
# The two ids are NOT interchangeable and this bites every time: `devicectl` takes the CoreDevice
# UUID, while `xcodebuild -destination` takes the hardware UDID. Give either one the other's id and
# you get "Unable to find a device matching the provided destination specifier".
live_device() {
  xcrun devicectl list devices --json-output /tmp/ekko-devices.json >/dev/null 2>&1 || return 1
  python3 - <<'EOF'
import json, sys
try:
    d = json.load(open('/tmp/ekko-devices.json'))
except Exception:
    sys.exit(1)
for dev in d.get('result', {}).get('devices', []):
    c = dev.get('connectionProperties', {})
    # transportType None means paired but not actually attached — installs cannot work.
    if c.get('transportType') in ('localNetwork', 'wired') and c.get('tunnelState') != 'unavailable':
        print(dev['identifier'], dev['hardwareProperties']['udid'], dev['deviceProperties']['name'])
        sys.exit(0)
sys.exit(1)
EOF
}

if [[ "${1:-}" == "--wait" ]]; then
  echo "waiting for an iPhone (plug it in and unlock it)…"
  for _ in $(seq 1 120); do
    if out=$(live_device); then break; fi
    sleep 5
  done
fi

if ! out=$(live_device); then
  echo "✗ no iPhone with a live connection."
  echo "  Plug it in with a cable, unlock the screen, and tap Trust if asked."
  xcrun devicectl list devices 2>/dev/null | tail -n +2 | head -3
  exit 1
fi

read -r DEVICE_ID UDID NAME <<<"$out"
echo "device: $NAME  (coredevice $DEVICE_ID / udid $UDID)"

npm run --silent ios:safari >/dev/null
# Safari may keep an already-running web-extension process when an app is reinstalled with the
# same native bundle version, even if every JavaScript resource changed underneath it. Give every
# device push the Chrome manifest's release version and a fresh build number so iOS reliably loads
# the extension we just synced. The host app and both embedded extensions inherit these overrides,
# which also keeps their bundle versions aligned for embedded-binary validation.
EXTENSION_VERSION="$(
  node -e "process.stdout.write(JSON.parse(require('fs').readFileSync('ios/EkkoSafari/Resources/manifest.json', 'utf8')).version)"
)"
BUILD_NUMBER="$(date +%s)"

echo "building for iOS device…  version $EXTENSION_VERSION ($BUILD_NUMBER)"
xcodebuild -project ios/Ekko.xcodeproj -scheme Ekko -sdk iphoneos \
  -destination "platform=iOS,id=$UDID" -derivedDataPath "$DD" \
  -allowProvisioningUpdates \
  MARKETING_VERSION="$EXTENSION_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"

APP="$DD/Build/Products/Debug-iphoneos/Ekko.app"
echo "installing…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" 2>&1 | grep -iE "error|installed|bundleID"

cat <<'DONE'

Installed. Three things left, on the phone:

  1. Settings > General > VPN & Device Management > trust the developer certificate.
     (Only needed the first time. Without it the app will not open.)
  2. Settings > General > Keyboard > Keyboards > Add New Keyboard > Ekko.
  3. Tap Ekko in that list and turn on Allow Full Access.
     iOS blocks a keyboard from reading the app's own storage without it, and that is
     where your keys live. The Ekko keyboard makes no network requests at all.

This is a free-team build, so it stops launching after 7 days. Re-run this script to renew it.
DONE
