#!/usr/bin/env bash
# Re-run after moving the clone because the launcher symlink is absolute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${MEETING_ARCHIVE_LAUNCHER_DIR:-$HOME/.local/bin}"

usage() {
  echo "Usage: bash install.sh [target_bin_dir]"
  echo "Links meeting-archive into ~/.local/bin by default."
  echo "Build the signed app separately with bash setup_mac.sh."
}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 1
fi
if [[ $# -eq 1 ]]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -*) echo "meeting-archive install: unknown option: $1" >&2; exit 1 ;;
    *) TARGET_DIR="$1" ;;
  esac
fi

LAUNCHER="$ROOT/meeting-archive"
DESTINATION="$TARGET_DIR/meeting-archive"
[[ -x "$LAUNCHER" ]] || { echo "Missing executable launcher: $LAUNCHER" >&2; exit 1; }
# Refresh symlinks, but do not overwrite someone's real command or directory.
if [[ -e "$DESTINATION" && ! -L "$DESTINATION" ]]; then
  echo "Refusing to replace a non-symlink: $DESTINATION" >&2
  exit 1
fi
mkdir -p "$TARGET_DIR"
ln -sfn "$LAUNCHER" "$DESTINATION"
echo "$DESTINATION -> $LAUNCHER"
case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "Add this bin directory to PATH in ~/.zshrc or ~/.bashrc: $TARGET_DIR" ;;
esac
echo "Run bash \"$ROOT/setup_mac.sh\" to build and sign Meeting Archive.app."
