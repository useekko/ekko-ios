#!/usr/bin/env bash
# Register the Ekko keyboard in a simulator, the way a user would in Settings > General >
# Keyboard > Keyboards > Add New Keyboard. There is no simctl verb for this, so it goes straight
# into the preference the keyboard picker reads.
#
#   scripts/ios-sim-setup.sh [device-udid]     (default: the booted one)
#
# Needed before EkkoUITests can drive the keyboard: without this there is nothing for the globe
# key to switch to.
set -euo pipefail

SIM="${1:-booted}"
KB="app.useekko.ios.keyboard"

current=$(xcrun simctl spawn "$SIM" defaults read .GlobalPreferences AppleKeyboards 2>/dev/null || echo "")
if [[ "$current" == *"$KB"* ]]; then
  echo "Ekko keyboard already registered on $SIM"
else
  xcrun simctl spawn "$SIM" defaults write .GlobalPreferences AppleKeyboards \
    -array "en_US@sw=QWERTY;hw=Automatic" "emoji@sw=Emoji" "$KB"
  echo "registered $KB on $SIM"
fi

# The keyboard picker caches the list; restarting the simulator's SpringBoard picks it up without
# a full reboot.
xcrun simctl spawn "$SIM" launchctl stop com.apple.SpringBoard 2>/dev/null || true
sleep 2

xcrun simctl spawn "$SIM" defaults read .GlobalPreferences AppleKeyboards
