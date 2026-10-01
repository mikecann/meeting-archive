#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meeting-archive-contract.XXXXXX")"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export CLANG_MODULE_CACHE_PATH="$FIXTURE_ROOT/module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$FIXTURE_ROOT/archive"

swiftc \
  "$TOOL_DIR/Sources/MeetingArchiveCore/ModelCodec.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Models.swift" \
  "$TOOL_DIR/Sources/MeetingArchiveCore/Manifest.swift" \
  "$SCRIPT_DIR/ContractRoundTrip.swift" \
  -o "$FIXTURE_ROOT/contract-roundtrip"

round_trip() {
  local bundle="$1"
  shift
  local manifest_sha256
  manifest_sha256="$("$FIXTURE_ROOT/contract-roundtrip" emit "$bundle" "$@")"
  PYTHONPATH="$TOOL_DIR/worker" python3 -m meeting_archive_worker accept \
    --incoming "$bundle" \
    --archive-root "$FIXTURE_ROOT/archive" \
    --db "$FIXTURE_ROOT/worker.sqlite" \
    --manifest-sha256 "$manifest_sha256" \
    > "$bundle.acknowledgement.json"

  "$FIXTURE_ROOT/contract-roundtrip" validate \
    "$bundle" \
    "$bundle.acknowledgement.json"
}

round_trip "$FIXTURE_ROOT/incoming"
# A capture whose microphone never started is archived with its other tracks.
round_trip "$FIXTURE_ROOT/without-microphone" --without-microphone

PYTHONPATH="$TOOL_DIR/worker" python3 -m meeting_archive_worker status \
  --db "$FIXTURE_ROOT/worker.sqlite"
