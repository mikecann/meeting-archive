#!/usr/bin/env bash
# Rebuilding must never replace the app bundle while Meeting Archive runs,
# however it was started. Stubs stand in for pgrep, launchctl, swift and open,
# so nothing is built, launched or installed, and real processes are ignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-rebuild-guard.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# pgrep applies its -f pattern to FAKE_PROCESSES, one command line per line.
cat >"$ROOT/bin/pgrep" <<'STUB'
#!/bin/sh
[ "$1" = "-f" ] || exit 2
printf '%s\n' "${FAKE_PROCESSES:-}" | grep -Eq -- "$2" || exit 1
echo 4242
STUB
# launchctl knows only the login item, in whatever state FAKE_LOGIN_ITEM says.
cat >"$ROOT/bin/launchctl" <<'STUB'
#!/bin/sh
[ "$1" = "print" ] && [ "$2" = "gui/$(id -u)/com.mikerosoft.meeting-archive" ] || exit 2
[ -n "${FAKE_LOGIN_ITEM:-}" ] || exit 113
printf '\tstate = %s\n' "$FAKE_LOGIN_ITEM"
STUB
# swift and open note that they ran. swift then fails, so a build that got past
# the guard stops before it can install anything.
cat >"$ROOT/bin/swift" <<'STUB'
#!/bin/sh
echo swift >>"$CALLS"
exit 3
STUB
cat >"$ROOT/bin/open" <<'STUB'
#!/bin/sh
echo open >>"$CALLS"
STUB
chmod +x "$ROOT/bin/pgrep" "$ROOT/bin/launchctl" "$ROOT/bin/swift" "$ROOT/bin/open"

# run SCRIPT PROCESSES LOGIN_ITEM_STATE
run() {
  : >"$ROOT/calls"
  set +e
  PATH="$ROOT/bin:$PATH" CALLS="$ROOT/calls" FAKE_PROCESSES="$2" FAKE_LOGIN_ITEM="$3" \
    MEETING_ARCHIVE_APP_DIR="$ROOT/Meeting Archive.app" \
    bash "$TOOL_DIR/$1" >"$ROOT/output" 2>&1
  status=$?
  set -e
}

fail() {
  echo "Rebuild guard: $1" >&2
  cat "$ROOT/output" >&2
  exit 1
}

expect_refused() {
  [[ "$status" -eq 1 ]] || fail "$1: expected a refusal, got exit $status"
  grep -q "Quit Meeting Archive from its menu" "$ROOT/output" || fail "$1: no quit message"
  [[ ! -s "$ROOT/calls" ]] || fail "$1: ran $(tr '\n' ' ' <"$ROOT/calls")after refusing"
}

expect_build() {
  [[ "$status" -eq 3 && "$(cat "$ROOT/calls")" == "swift" ]] || fail "$1: expected the build to start, got exit $status"
}

# The login item's real command line has no bundle path in it.
login_item="meeting-archive-app --background"
opened="/Users/me/Applications/Meeting Archive.app/Contents/MacOS/meeting-archive-app"

run build-app.sh "" ""
expect_build "nothing running"
run build-app.sh "" "not running"
expect_build "login item quit from its menu"
run build-app.sh "/usr/bin/tail -f /tmp/meeting-archive-app.log" ""
expect_build "an unrelated process"
run build-app.sh "$login_item" ""
expect_refused "login item process"
run build-app.sh "" "running"
expect_refused "login item running according to launchd"
run build-app.sh "$opened" ""
expect_refused "app opened from Finder"
run restart.sh "$login_item" "running"
expect_refused "restart.sh"
run setup_mac.sh "$login_item" "running"
expect_refused "setup_mac.sh"

echo "Rebuild guard tests passed"
