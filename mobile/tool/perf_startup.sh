#!/usr/bin/env bash
# Cold-start measurement (TEST_PLAN PERF-05: cold start < 2 s on a mid-range device).
#
# What it measures, and what it does not:
#   * `adb shell am start -W` TotalTime / WaitTime over N cold starts (the app is
#     force-stopped before each one, so the process, the engine and the Dart isolate start
#     from nothing; the OS file cache stays warm, as it does on a phone that was used a
#     minute ago). TotalTime is "tap to first frame drawn by the activity";
#   * Flutter's own first-frame time (`flutter run --trace-startup`, which writes
#     build/start_up_info.json: timeToFirstFrameMicros, timeToFrameworkInitMicros ...);
#   * the installed build is the dev flavor (config/dev.json) so that the same command
#     works with no keys. The signed-out launch is measured (no session): what happens before
#     the first frame is the same, the Home data arrives after it.
#
# The build is a RELEASE build by default (AOT, R8, resource shrinking: what users get;
# signed with the debug key, which is fine for dev). `--mode profile` builds the profile
# APK instead (AOT, no minification). Release builds cannot run `--trace-startup`
# (it needs the VM service), so that step always installs a PROFILE build.
#
# THE EMULATOR IS NOT A MID-RANGE PHONE. Numbers from an x86_64/arm64 emulator on a laptop
# are only indicative and are usually faster or slower than a real phone in unpredictable
# ways. The PERF-05 number must come from a real mid-range device: plug it in (USB
# debugging on, `adb devices` lists it) and run
#
#     mobile/tool/perf_startup.sh --device <serial> --runs 10
#
# Usage:
#   mobile/tool/perf_startup.sh                      # boots AfterMe_API_36 if nothing is attached
#   mobile/tool/perf_startup.sh --device emulator-5554 --runs 10
#   mobile/tool/perf_startup.sh --mode profile       # profile instead of release for am start
#   mobile/tool/perf_startup.sh --skip-build         # re-use the APKs already built
#   mobile/tool/perf_startup.sh --no-trace           # skip the flutter run --trace-startup step
#   mobile/tool/perf_startup.sh --out DIR            # where the raw numbers are written
#
# Output: a summary on stdout and DIR/am_start.csv, DIR/trace_startup.json. Exit code 0
# when the measurement ran, 1 when it could not (a build or device problem); the script
# makes no pass/fail judgement on the numbers (they are not from the target device).
set -euo pipefail

MOBILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AVD="${AFTERME_IT_AVD:-AfterMe_API_36}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
ADB="${ADB:-$SDK/platform-tools/adb}"
EMULATOR="${EMULATOR:-$SDK/emulator/emulator}"
PACKAGE="app.afterme.dev"
ACTIVITY="app.afterme.MainActivity"
BOOT_TIMEOUT=300

RUNS=10
MODE="release"
DEVICE=""
BUILD=1
TRACE=1
OUT="${TMPDIR:-/tmp}/afterme-perf-startup"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="${2:?--runs needs a number}"; shift ;;
    --mode) MODE="${2:?--mode needs release|profile}"; shift ;;
    --device) DEVICE="${2:?--device needs a serial}"; shift ;;
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    --skip-build) BUILD=0 ;;
    --no-trace) TRACE=0 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$MODE" == release || "$MODE" == profile ]] || { echo "--mode must be release or profile" >&2; exit 2; }
[[ "$RUNS" =~ ^[0-9]+$ && "$RUNS" -ge 1 ]] || { echo "--runs must be a positive number" >&2; exit 2; }

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null || die "flutter is not on PATH"
[[ -x "$ADB" ]] || die "adb not found at $ADB (set ANDROID_HOME)"
mkdir -p "$OUT"

EMULATOR_PID=""
STARTED_EMULATOR=0
cleanup() {
  local code=$?
  set +e
  if [[ "$STARTED_EMULATOR" == 1 ]]; then
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    sleep 2
    kill "$EMULATOR_PID" 2>/dev/null
  fi
  return "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- the device (same boot logic as tool/integration.sh) ---------------------------------
SERIAL="$DEVICE"
[[ -n "$SERIAL" ]] || SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
if [[ -z "$SERIAL" ]]; then
  [[ -x "$EMULATOR" ]] || die "no device attached and no emulator binary at $EMULATOR"
  say "Booting $AVD headless"
  "$EMULATOR" -avd "$AVD" -no-window -no-audio -no-snapshot -no-boot-anim \
    >"$OUT/emulator.log" 2>&1 &
  EMULATOR_PID=$!
  STARTED_EMULATOR=1
  waited=0
  while [[ -z "$SERIAL" ]]; do
    sleep 2
    waited=$((waited + 2))
    SERIAL="$("$ADB" devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
    (( waited < BOOT_TIMEOUT )) || die "the emulator did not appear within ${BOOT_TIMEOUT}s"
    kill -0 "$EMULATOR_PID" 2>/dev/null || die "the emulator exited (see $OUT/emulator.log)"
  done
fi
say "Waiting for $SERIAL to finish booting"
waited=0
until [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 2
  waited=$((waited + 2))
  (( waited < BOOT_TIMEOUT )) || die "$SERIAL did not finish booting within ${BOOT_TIMEOUT}s"
done
until "$ADB" -s "$SERIAL" shell pm path android >/dev/null 2>&1; do sleep 1; done
# Let the boot settle (first-boot dexopt and the system UI use the CPU for a while).
sleep 20

adb_s() { "$ADB" -s "$SERIAL" "$@"; }
MODEL="$(adb_s shell getprop ro.product.model | tr -d '\r')"
ABI="$(adb_s shell getprop ro.product.cpu.abi | tr -d '\r')"
SDKLVL="$(adb_s shell getprop ro.build.version.sdk | tr -d '\r')"
ANIM="$(adb_s shell settings get global window_animation_scale | tr -d '\r')"
QEMU="$(adb_s shell getprop ro.kernel.qemu | tr -d '\r')"
say "Device: $SERIAL ($MODEL, $ABI, API $SDKLVL, animation scale $ANIM, emulator=${QEMU:-0})"

cd "$MOBILE_DIR"
DEFINES=(--dart-define-from-file=config/dev.json)

# --- 1. am start -W over N cold starts ----------------------------------------------------
APK="build/app/outputs/flutter-apk/app-dev-$MODE.apk"
if [[ "$BUILD" == 1 ]]; then
  say "Building the dev flavor ($MODE)"
  flutter build apk "--$MODE" --flavor dev "${DEFINES[@]}" >"$OUT/build_$MODE.log" 2>&1 \
    || { tail -n 30 "$OUT/build_$MODE.log" >&2; die "the $MODE build failed (see $OUT/build_$MODE.log)"; }
fi
[[ -f "$APK" ]] || die "$APK not found (run without --skip-build)"
adb_s install -r "$APK" >/dev/null || die "install failed"

say "Cold starts: $RUNS x am start -W ($MODE)"
echo "run,this_time_ms,total_time_ms,wait_time_ms" >"$OUT/am_start.csv"
for ((i = 1; i <= RUNS; i++)); do
  adb_s shell am force-stop "$PACKAGE"
  adb_s shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  sleep 3
  result="$(adb_s shell am start -W -n "$PACKAGE/$ACTIVITY" | tr -d '\r')"
  this="$(awk -F': ' '/ThisTime/ {print $2}' <<<"$result")"
  total="$(awk -F': ' '/TotalTime/ {print $2}' <<<"$result")"
  wait="$(awk -F': ' '/WaitTime/ {print $2}' <<<"$result")"
  [[ -n "$total" ]] || die "could not read TotalTime from: $result"
  echo "$i,$this,$total,$wait" >>"$OUT/am_start.csv"
  printf '    run %2d: ThisTime %5s ms  TotalTime %5s ms  WaitTime %5s ms\n' "$i" "$this" "$total" "$wait"
  sleep 4 # let the process finish what it does after the first frame before the next kill
done
adb_s shell am force-stop "$PACKAGE"

summary() { # column index (1-based in the csv), label
  tail -n +2 "$OUT/am_start.csv" | cut -d, -f"$1" | sort -n | awk -v label="$2" '
    { v[NR] = $1; sum += $1 }
    END {
      med = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
      printf "    %-10s min %5d  median %7.1f  mean %7.1f  max %5d ms (n=%d)\n", label, v[1], med, sum / NR, v[NR], NR
    }'
}
echo
say "am start -W summary ($MODE build, $MODEL)"
# ThisTime is not printed by every Android version; skip it when it is missing.
if [[ -n "$(tail -n +2 "$OUT/am_start.csv" | cut -d, -f2 | tr -d '\n')" ]]; then
  summary 2 ThisTime
fi
summary 3 TotalTime
summary 4 WaitTime

# --- 2. Flutter's first-frame time -----------------------------------------------------------
if [[ "$TRACE" == 1 ]]; then
  say "flutter run --profile --trace-startup (a profile build; first frame as the engine sees it)"
  rm -f build/start_up_info.json
  # --trace-startup writes build/start_up_info.json and exits once the first frame is out.
  flutter run --profile --trace-startup --flavor dev "${DEFINES[@]}" -d "$SERIAL" \
    >"$OUT/trace_startup.log" 2>&1 \
    || { tail -n 30 "$OUT/trace_startup.log" >&2; die "flutter run --trace-startup failed (see $OUT/trace_startup.log)"; }
  if [[ -f build/start_up_info.json ]]; then
    cp build/start_up_info.json "$OUT/trace_startup.json"
    cat "$OUT/trace_startup.json"
    echo
    # Micros to milliseconds, one line each.
    python3 -I - "$OUT/trace_startup.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for key, value in data.items():
    if key.endswith("Micros"):
        print(f"    {key:<40} {value / 1000:8.1f} ms")
PY
  else
    die "build/start_up_info.json was not written (see $OUT/trace_startup.log)"
  fi
  adb_s shell am force-stop "$PACKAGE"
fi

say "Raw numbers: $OUT"
echo "    These come from '$MODEL' (emulator=${QEMU:-0}). They are indicative, not the PERF-05 result."
echo "    For the real figure, repeat on a physical mid-range phone:"
echo "      mobile/tool/perf_startup.sh --device <serial> --runs 10"
