#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# setup_mac.sh refuses while Meeting Archive is running, however it was
# started, then starts the login item, which launchd keeps running.
bash "$SCRIPT_DIR/setup_mac.sh" "$@"
