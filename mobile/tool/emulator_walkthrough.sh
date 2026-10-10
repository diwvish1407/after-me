#!/usr/bin/env bash
# Best-effort walkthrough of the first onboarding screens on an emulator or device
# (Phase 2): Welcome -> "Get started" -> Create account, with a screenshot of each screen.
#
# It taps by reading the screen with `uiautomator dump` (no coordinates are hard-coded),
# so it keeps working when layouts change, and it fails with a clear message when a
# screen or button cannot be found.
#
# Usage (from mobile/):
#   flutter build apk --flavor dev --debug --dart-define-from-file=config/dev.json
#   tool/emulator_walkthrough.sh <screenshot-dir>
#
# If no device is attached it boots AfterMe_API_36 headless (set AVD_NAME to change) and
# shuts that emulator down again when the script ends. With several devices attached set
# ANDROID_SERIAL to the one to use; the script refuses to guess.
# Needs adb (and emulator when booting); python3 parses the UI dump.
set -euo pipefail

OUT="${1:-}"
[[ -n "$OUT" ]] || { echo "Usage: $0 <screenshot-dir>" >&2; exit 2; }
mkdir -p "$OUT"

APK="build/app/outputs/flutter-apk/app-dev-debug.apk"
PKG="app.afterme.dev"
AVD_NAME="${AVD_NAME:-AfterMe_API_36}"

fail() { echo "FAIL: $*" >&2; exit 1; }

command -v adb >/dev/null || fail "adb not found. Install the Android SDK platform-tools and put them on PATH."
[[ -f "$APK" ]] || fail "Missing $APK. Build the dev debug APK first (see the usage above)."

STARTED_EMULATOR=0
cleanup() {
  # Remove the UI dump from the device, and stop an emulator this script started.
  adb shell rm -f /sdcard/afterme_ui.xml >/dev/null 2>&1 || true
  if [[ "$STARTED_EMULATOR" == "1" ]]; then
    adb emu kill >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- device ------------------------------------------------------------------------
# Count the attached devices (lines ending in "device"; the header and offline ones are
# not counted). adb itself honours ANDROID_SERIAL for every call below.
attached() { adb devices | awk 'NR > 1 && $2 == "device" { n++ } END { print n + 0 }'; }

if [[ -z "${ANDROID_SERIAL:-}" && "$(attached)" -gt 1 ]]; then
  fail "More than one device is attached. Set ANDROID_SERIAL to the one to use."
fi
if [[ "$(attached)" -eq 0 ]]; then
  command -v emulator >/dev/null || fail "No device attached and 'emulator' is not on PATH."
  echo "Booting $AVD_NAME (headless)..."
  nohup emulator -avd "$AVD_NAME" -no-window -no-audio -no-boot-anim -no-snapshot \
    >"$OUT/emulator.log" 2>&1 &
  STARTED_EMULATOR=1
  adb wait-for-device
fi
for _ in $(seq 1 120); do
  [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] && break
  sleep 2
done
[[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]] \
  || fail "The device did not finish booting."

# --- helpers -----------------------------------------------------------------------
dump_ui() {
  adb shell uiautomator dump /sdcard/afterme_ui.xml >/dev/null 2>&1 || return 1
  adb shell cat /sdcard/afterme_ui.xml 2>/dev/null
}

# Prints "x y" of the centre of the first node whose text or content-desc equals $1
# (read from stdin), or nothing.
find_center() {
  python3 -I -c '
import re, sys
want = sys.argv[1]
xml = sys.stdin.read()
for node in re.finditer(r"<node\b[^>]*>", xml):
    tag = node.group(0)
    texts = re.findall(r"(?:text|content-desc)=\"([^\"]*)\"", tag)
    b = re.search(r"bounds=\"\[(\d+),(\d+)\]\[(\d+),(\d+)\]\"", tag)
    # A live-region card reads "Card 2 of 3. <text>": match its leading position too.
    if b and any(t == want or t.startswith(want + ". ") for t in texts):
        x1, y1, x2, y2 = map(int, b.groups())
        print((x1 + x2) // 2, (y1 + y2) // 2)
        break
' "$1"
}

# Dismisses the "System UI isn't responding" dialog that a cold-booted emulator shows.
dismiss_anr() {
  local xml pos
  xml="$(dump_ui || true)"
  pos="$(printf '%s' "$xml" | find_center "Wait")"
  if [[ -n "$pos" ]] && printf '%s' "$xml" | grep -q "isn't responding"; then
    adb shell input tap $pos
    sleep 1
  fi
}

# Waits until a node with exactly this text/content-desc is on screen.
wait_for() {
  local text="$1" xml
  for _ in $(seq 1 30); do
    dismiss_anr
    xml="$(dump_ui || true)"
    if [[ -n "$(printf '%s' "$xml" | find_center "$text")" ]]; then
      return 0
    fi
    sleep 1
  done
  adb exec-out screencap -p >"$OUT/failure.png" || true
  fail "Could not find \"$text\" on screen (see $OUT/failure.png)."
}

tap_text() {
  local text="$1" pos
  wait_for "$text"
  pos="$(dump_ui | find_center "$text")"
  [[ -n "$pos" ]] || fail "Could not locate \"$text\" to tap it."
  adb shell input tap $pos
  sleep 1
}

shot() {
  adb exec-out screencap -p >"$OUT/$1.png"
  echo "Saved $OUT/$1.png"
}

# --- walkthrough ---------------------------------------------------------------------
adb logcat -c
adb install -r "$APK" >/dev/null
adb shell pm clear "$PKG" >/dev/null 2>&1 || true
adb shell am force-stop "$PKG"
adb shell am start -n "$PKG/app.afterme.MainActivity" >/dev/null

wait_for "Get started"
wait_for "AfterMe is not an emergency service. If someone is in danger, contact your local emergency services."
shot 01_welcome

tap_text "Next"
wait_for "Card 2 of 3"
shot 02_welcome_card_2

tap_text "Get started"
wait_for "Let's set you up"
wait_for "Send my code"
shot 03_create_account

if adb logcat -d -v brief | grep -E "FATAL EXCEPTION|flutter.*(Exception caught|EXCEPTION CAUGHT)"; then
  fail "A crash or Flutter exception appeared in logcat."
fi
echo "OK: Welcome -> Get started -> Create account reached; screenshots are in $OUT."
