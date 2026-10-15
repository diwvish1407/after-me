#!/usr/bin/env bash
# The Play listing's phone screenshots (PLAY_STORE §5), from the real app on the
# emulator: tool/integration.sh --screenshots on a throwaway database of its own
# (`afterme_shots`, dropped and recreated) and a port of its own (default 8010, so a
# server on 8000 is never touched; the app is pointed at it with --dart-define).
#
#   mobile/tool/screenshots.sh                       # store/screenshots/0*.png
#   AFTERME_IT_PORT=8020 mobile/tool/screenshots.sh  # another free port
#   mobile/tool/screenshots.sh --keep-emulator --device emulator-5554
#
# A dev build with SCREENSHOT_MODE=true (FLAG_SECURE off, a "Screenshot mode" strip that
# the capture cuts off), fictional people only (Asha, her contact Meera, Ravi), 1080 x
# 2160 portrait, 24-bit PNG without alpha; tool/store_assets/check_store_assets.dart
# checks them at the end. Needs what tool/integration.sh needs (PostgreSQL, the
# backend's .venv, the AVD or an attached emulator).
set -euo pipefail
export AFTERME_IT_DB=afterme_shots
export AFTERME_IT_PORT="${AFTERME_IT_PORT:-8010}"
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/integration.sh" --screenshots "$@"
