#!/usr/bin/env bash
# Phase 1 exit-criterion smoke check: the dev flavor installs and launches on a running
# emulator/device, and logcat shows no fatal crash or Flutter exception.
#
# Usage (from mobile/, with an emulator running, e.g. `emulator -avd AfterMe_API_36 &`):
#   flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json
#   tool/emulator_smoke.sh
set -euo pipefail

APK="build/app/outputs/flutter-apk/app-dev-debug.apk"
PKG="app.afterme.dev"

[[ -f "$APK" ]] || { echo "Missing $APK; build the dev debug APK first." >&2; exit 2; }
adb get-state >/dev/null 2>&1 || { echo "No emulator/device attached." >&2; exit 2; }

adb logcat -c
adb install -r "$APK" >/dev/null
adb shell am force-stop "$PKG"
adb shell am start -n "$PKG/app.afterme.MainActivity" >/dev/null
sleep 10

if ! adb shell pidof "$PKG" >/dev/null; then
  echo "FAIL: $PKG is not running after launch." >&2
  exit 1
fi

LOG="$(adb logcat -d -v brief)"
if grep -E "FATAL EXCEPTION|AndroidRuntime.*$PKG|flutter.*(Exception caught|EXCEPTION CAUGHT)" <<<"$LOG"; then
  echo "FAIL: crash or Flutter exception in logcat." >&2
  exit 1
fi
echo "OK: $PKG installed, running, and logcat is clean."
