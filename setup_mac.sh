#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_DIR="${MEETING_ARCHIVE_LAUNCHER_DIR:-$HOME/.local/bin}"

usage() {
  cat <<'EOF'
Usage: bash setup_mac.sh [--with-launcher] [--no-login-item]

Build and install the signed Meeting Archive.app bundle, then start it as a
login item that launchd keeps running. --no-login-item leaves that off. The
optional launcher is a symlink in ~/.local/bin (or MEETING_ARCHIVE_LAUNCHER_DIR).
EOF
}

WITH_LAUNCHER=0
LOGIN_ITEM=1
for arg in "$@"; do
  case "$arg" in
    --with-launcher) WITH_LAUNCHER=1 ;;
    --no-login-item) LOGIN_ITEM=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "meeting-archive setup: unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

echo "Building and signing Meeting Archive.app..."
bash "$SCRIPT_DIR/build-app.sh"

if [[ "$WITH_LAUNCHER" -eq 1 ]]; then
  mkdir -p "$LAUNCHER_DIR"
  ln -sf "$SCRIPT_DIR/meeting-archive" "$LAUNCHER_DIR/meeting-archive"
  echo "Launcher: $LAUNCHER_DIR/meeting-archive"
fi

APP="${MEETING_ARCHIVE_APP_DIR:-$HOME/Applications/Meeting Archive.app}"
echo "Installed: $APP"

# A replaced bundle is refused by launchd (EX_CONFIG) until its login item is
# registered again from the app itself; registering from a shell is not enough.
# Going through LaunchServices with `open` makes the app the registrant. It's
# registered every time, not only when it already was: stopping the app for a
# rebuild means disabling the login item, since launchd restarts it after a quit.
AGENT="gui/$(id -u)/com.mikerosoft.meeting-archive"
if [[ "$LOGIN_ITEM" -eq 1 ]]; then
  open -W -n "$APP" --args --disable-startup 2>/dev/null || true
  open -W -n "$APP" --args --enable-startup 2>/dev/null || true
  sleep 2
  launchctl kickstart "$AGENT" 2>/dev/null || true
  sleep 3
  if launchctl print "$AGENT" 2>/dev/null | grep -q "state = running"; then
    echo "Login item re-registered; Meeting Archive is running in the background."
  else
    echo "Login item needs attention: open Meeting Archive, then Settings > Disable at login, Enable at login." >&2
  fi
else
  echo "Login item left off. Open the app yourself after reviewing the permissions in the README."
fi
