#!/usr/bin/env bash
# Builds the production release the way SECURITY.md §11 (CODE) says it is built, and
# refuses to build it any other way (Phase 9 review M-04):
#
#   * Dart obfuscation with the debug symbols split out (--obfuscate --split-debug-info);
#   * the prod flavor with config/prod.json, whose APP_ENV must be prod and whose API URL
#     must be https (a dev file in a prod build is the mistake this exists to stop), and
#     which must not turn SCREENSHOT_MODE on (a screenshot build is never a release);
#   * the upload key (android/key.properties) must exist, or the build stops with a clear
#     message. --allow-debug-signing is the explicit, loud way to build without it: the
#     result is signed with the public DEBUG key and can never be uploaded to Play. CI
#     uses it, because CI has no upload key and only proves that the release compiles;
#   * after the build, the merged release manifest is checked: permission allowlist,
#     allowBackup, cleartext and debuggable flags, deep links off, and the exact set of
#     exported components (tool/check_manifest_permissions.dart).
#
# Usage (from anywhere; it changes to mobile/ itself):
#   tool/build_release.sh [--apk | --appbundle] [--allow-debug-signing]
#                         [--symbols-dir=DIR]
#
#   --appbundle (default)  the Android App Bundle for the Play upload
#   --apk                  a release APK (local checks, CI)
#   --symbols-dir=DIR      where --split-debug-info writes the Dart symbols
#                          (default build/symbols). Keep them, and the R8 mapping at
#                          build/app/outputs/mapping/prodRelease/, PRIVATE and per version:
#                          they de-obfuscate crash traces and are never committed
#                          (.gitignore excludes build/ and *.symbols).
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="appbundle"
ALLOW_DEBUG_SIGNING=0
SYMBOLS_DIR="build/symbols"

fail() {
  echo "build_release: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --apk) TARGET="apk" ;;
    --appbundle) TARGET="appbundle" ;;
    --allow-debug-signing) ALLOW_DEBUG_SIGNING=1 ;;
    --symbols-dir=*) SYMBOLS_DIR="${arg#--symbols-dir=}" ;;
    -h | --help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) fail "unknown argument: $arg (see --help)" ;;
  esac
done

[ -n "$SYMBOLS_DIR" ] || fail "--symbols-dir must not be empty"

# --- The configuration: prod, https ----------------------------------------------------
CONFIG="config/prod.json"
[ -f "$CONFIG" ] || fail "$CONFIG not found"
grep -Eq '"APP_ENV"[[:space:]]*:[[:space:]]*"prod"' "$CONFIG" ||
  fail "$CONFIG must set \"APP_ENV\": \"prod\" (a release is built from the prod configuration only)"
grep -Eq '"API_BASE_URL"[[:space:]]*:[[:space:]]*"https://' "$CONFIG" ||
  fail "$CONFIG must set an https API_BASE_URL"

# A screenshot build (SCREENSHOT_MODE, README "Screenshots for the store") makes the
# window capturable and is for staging and dev only. The app itself refuses it with
# APP_ENV prod; this stops the release before anything is built. The key does not belong
# in the prod file at all: if it is there, its value must be false.
if grep -Eiq 'SCREENSHOT_MODE' "$CONFIG"; then
  grep -Eiq '"SCREENSHOT_MODE"[[:space:]]*:[[:space:]]*"?false"?[[:space:]]*,?[[:space:]]*$' "$CONFIG" ||
    fail "$CONFIG mentions SCREENSHOT_MODE with a value other than false. A screenshot build is never a release: it switches off FLAG_SECURE (use config/staging.json for screenshots)."
  [ "$(grep -Eic 'SCREENSHOT_MODE' "$CONFIG")" -eq 1 ] ||
    fail "$CONFIG mentions SCREENSHOT_MODE more than once; a release configuration does not carry it."
fi

# --- The signing key --------------------------------------------------------------------
if [ ! -f android/key.properties ]; then
  if [ "$ALLOW_DEBUG_SIGNING" -ne 1 ]; then
    fail "android/key.properties (the upload key, see README 'Release signing') was not found.
  A release without it would be signed with the public debug key and could not be uploaded.
  Create it, or pass --allow-debug-signing for a build that is only a compile/inspection check."
  fi
  {
    echo "################################################################"
    echo "# WARNING: android/key.properties is missing and --allow-debug-signing was given."
    echo "# This build is signed with the DEBUG key. It is NOT a release:"
    echo "# never upload it, never install it on anybody's phone."
    echo "################################################################"
  } >&2
elif [ "$ALLOW_DEBUG_SIGNING" -eq 1 ]; then
  echo "build_release: note: android/key.properties exists, so --allow-debug-signing has no effect (the upload key is used)." >&2
fi

# --- Build -------------------------------------------------------------------------------
mkdir -p "$SYMBOLS_DIR"
echo "build_release: flutter build $TARGET --flavor prod --release --obfuscate --split-debug-info=$SYMBOLS_DIR"
flutter build "$TARGET" \
  --flavor prod \
  --release \
  --dart-define-from-file="$CONFIG" \
  --obfuscate \
  --split-debug-info="$SYMBOLS_DIR"

# --- The merged manifest of what was just built ---------------------------------------------
dart run tool/check_manifest_permissions.dart

echo
echo "build_release: done."
if [ "$TARGET" = "apk" ]; then
  echo "  artifact: build/app/outputs/flutter-apk/app-prod-release.apk"
else
  echo "  artifact: build/app/outputs/bundle/prodRelease/app-prod-release.aab"
fi
echo "  Dart symbols: $SYMBOLS_DIR  (keep private, per version)"
echo "  R8 mapping:   build/app/outputs/mapping/prodRelease/mapping.txt  (keep private, per version)"
if [ ! -f android/key.properties ]; then
  echo "  SIGNED WITH THE DEBUG KEY: do not upload." >&2
fi
