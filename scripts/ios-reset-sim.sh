#!/usr/bin/env bash
# Put the simulator back to "never launched Ekko", so onboarding can be driven from the top.
#
# Why this is not just `simctl uninstall`: the identity does not live in the app's container, it
# lives in the APP GROUP container, which is shared with the keyboard and the Safari extension and
# therefore SURVIVES uninstalling the app. Leave it behind and the next launch skips the welcome
# screen — OnboardingView sees an identity with no finished onboarding and resumes at the backup
# step, which is correct behaviour for a user and useless for a test.
#
#   scripts/ios-reset-sim.sh            # booted simulator
#   scripts/ios-reset-sim.sh "iPhone 17 Pro"
#
# Prerequisite of EkkoUITests/OnboardingFlowTests. Run it, then run the test.
set -euo pipefail

SIM="${1:-booted}"
APP="app.useekko.ios"
GROUP="group.app.useekko"

APP_PATH=$(
  xcodebuild -project "$(dirname "$0")/../ios/Ekko.xcodeproj" -scheme Ekko \
    -destination "platform=iOS Simulator,name=${2:-iPhone 17 Pro}" -showBuildSettings 2>/dev/null |
    awk -F' = ' '/ BUILT_PRODUCTS_DIR /{gsub(/^ +| +$/,"",$2); d=$2}
                 / FULL_PRODUCT_NAME /{gsub(/^ +| +$/,"",$2); n=$2}
                 END{print d"/"n}'
)
[ -d "$APP_PATH" ] || { echo "no built app at $APP_PATH — build the Ekko scheme first" >&2; exit 1; }

# The app's own container (and with it UserDefaults, where the "onboarded" flag lives).
xcrun simctl uninstall "$SIM" "$APP" 2>/dev/null || true

# Reinstall so the App Group container has a path to resolve, then empty it. The group container is
# only reachable through an installed app.
xcrun simctl install "$SIM" "$APP_PATH"
GROUP_DIR=$(xcrun simctl get_app_container "$SIM" "$APP" "$GROUP")
rm -f "$GROUP_DIR/vault.json"

# UserDefaults can outlive an uninstall: `defaults write app.useekko.ios ...` from the command line
# (e.g. hand-seeding onboarded=YES) lands in cfprefsd, which the container removal does not touch.
# A stale onboarded=YES is nasty — the app still shows the welcome screen (no identity yet), then
# jumps STRAIGHT past the 24-word backup to Home the instant createIdentity() flips hasIdentity,
# because RootView gates on `hasIdentity && onboarded`. That looks exactly like an onboarding bug and
# is not. Clear the domain so the reset really means "never launched Ekko".
xcrun simctl spawn "$SIM" defaults delete "$APP" >/dev/null 2>&1 || true

echo "reset: app data + defaults cleared, vault removed from $GROUP_DIR"
