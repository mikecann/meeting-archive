#!/usr/bin/env bash
# Rebuilding must never replace the app bundle while Meeting Archive runs,
# however it was started. Stubs stand in for ps, launchctl, swift and open,
# so nothing is built, launched or installed, and real processes are ignored.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-rebuild-guard.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# ps lists this user's FAKE_PROCESSES, one executable per line, as
# `ps -x -U uid -o comm=` does, plus the app once it was opened mid-build.
# With PS_FAILS set it can't list anything.
cat >"$ROOT/bin/ps" <<'STUB'
#!/bin/sh
[ "$*" = "-x -U $(id -u) -o comm=" ] || exit 2
[ -z "${PS_FAILS:-}" ] || exit 1
printf '%s\n' "${FAKE_PROCESSES:-}"
[ ! -e "$ROOT/opened-mid-build" ] || echo meeting-archive-app
STUB
# launchctl knows only the login item, in whatever state FAKE_LOGIN_ITEM says.
cat >"$ROOT/bin/launchctl" <<'STUB'
#!/bin/sh
[ "$1" = "print" ] && [ "$2" = "gui/$(id -u)/com.mikerosoft.meeting-archive" ] || exit 2
[ -n "${FAKE_LOGIN_ITEM:-}" ] || exit 113
printf '\tstate = %s\n' "$FAKE_LOGIN_ITEM"
STUB
# swift and open note that they ran. swift then fails, so a build that got past
# the guard stops before it can install anything. With OPEN_DURING_BUILD set,
# the app is opened while it compiles and the build succeeds.
cat >"$ROOT/bin/swift" <<'STUB'
#!/bin/sh
echo swift >>"$CALLS"
[ -z "${OPEN_DURING_BUILD:-}" ] || { touch "$ROOT/opened-mid-build"; exit 0; }
exit 3
STUB
cat >"$ROOT/bin/open" <<'STUB'
#!/bin/sh
echo "open $*" >>"$CALLS"
STUB
chmod +x "$ROOT/bin/ps" "$ROOT/bin/launchctl" "$ROOT/bin/swift" "$ROOT/bin/open"

PS_FAILS=

# run SCRIPT PROCESSES LOGIN_ITEM_STATE [OPEN_DURING_BUILD]
run() {
  : >"$ROOT/calls"
  rm -f "$ROOT/opened-mid-build"
  set +e
  PATH="$ROOT/bin:$PATH" ROOT="$ROOT" CALLS="$ROOT/calls" FAKE_PROCESSES="$2" FAKE_LOGIN_ITEM="$3" \
    OPEN_DURING_BUILD="${4:-}" PS_FAILS="$PS_FAILS" MEETING_ARCHIVE_APP_DIR="$ROOT/Meeting Archive.app" \
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

# The login item's executable has no bundle path, and a Finder launch's has a
# space in it. Neither can be told apart from arguments in a joined command
# line, so the guard only looks at executables.
login_item="meeting-archive-app"
opened="/Users/me/Applications/Meeting Archive.app/Contents/MacOS/meeting-archive-app"

run build-app.sh "" ""
expect_build "nothing running"
run build-app.sh "" "not running"
expect_build "login item quit from its menu"
run build-app.sh "/Users/me/meeting-archive-app/bin/tail" ""
expect_build "an executable inside a meeting-archive-app folder"
run build-app.sh "/usr/local/bin/meeting-archive-app-helper" ""
expect_build "a longer executable name"
run build-app.sh "$login_item" ""
expect_refused "login item process"
run build-app.sh "" "running"
expect_refused "login item running according to launchd"
run build-app.sh "$opened" ""
expect_refused "app opened from Finder"
# A build can take minutes, so the app may be opened before the bundle swap.
run build-app.sh "" "" yes
[[ "$status" -eq 1 && "$(cat "$ROOT/calls")" == "swift" ]] \
  || fail "app opened during the build: expected a refusal right after building, got exit $status after $(tr '\n' ' ' <"$ROOT/calls")"
grep -q "Quit Meeting Archive from its menu" "$ROOT/output" || fail "app opened during the build: no quit message"
[[ ! -e "$ROOT/Meeting Archive.app.staging" ]] || fail "app opened during the build: left a staging bundle"
# If the processes can't be listed, the app might be running, so don't build.
PS_FAILS=yes
run build-app.sh "" ""
PS_FAILS=
[[ "$status" -eq 1 && ! -s "$ROOT/calls" ]] || fail "process list unavailable: expected a refusal, got exit $status"
grep -q "Could not list running processes" "$ROOT/output" || fail "process list unavailable: no explanation"
run restart.sh "$login_item" "running"
expect_refused "restart.sh"
run setup_mac.sh "$login_item" "running"
expect_refused "setup_mac.sh"

# restart.sh opens the app once a build succeeds. A copy runs against a
# stand-in build-app.sh, since the real build always stops at the swift stub.
mkdir -p "$ROOT/restart"
cp "$TOOL_DIR/restart.sh" "$ROOT/restart/restart.sh"
printf '#!/bin/sh\necho build >>"$CALLS"\n' >"$ROOT/restart/build-app.sh"
chmod +x "$ROOT/restart/build-app.sh"
: >"$ROOT/calls"
PATH="$ROOT/bin:$PATH" CALLS="$ROOT/calls" MEETING_ARCHIVE_APP_DIR="$ROOT/Meeting Archive.app" \
  bash "$ROOT/restart/restart.sh" >"$ROOT/output" 2>&1 || fail "restart.sh: failed after a successful build"
[[ "$(cat "$ROOT/calls")" == "build"$'\n'"open $ROOT/Meeting Archive.app" ]] \
  || fail "restart.sh: expected a build, then the app to open"

echo "Rebuild guard tests passed"
