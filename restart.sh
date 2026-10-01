#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${MEETING_ARCHIVE_APP_DIR:-$HOME/Applications/Meeting Archive.app}"
# build-app.sh refuses while Meeting Archive is running, however it was started.
"$SCRIPT_DIR/build-app.sh"
open "$APP_DIR"
