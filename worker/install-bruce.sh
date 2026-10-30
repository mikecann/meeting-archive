#!/usr/bin/env bash
set -euo pipefail
ROOT="${MEETING_ARCHIVE_ROOT:-/Volumes/CannMedia/MeetingArchive}"
EXPECTED_VOLUME="${MEETING_ARCHIVE_VOLUME_UUID:-5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46}"
PYTHON="${MEETING_ARCHIVE_PYTHON:-/opt/homebrew/bin/python3.13}"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTUAL_VOLUME="$(diskutil info -plist /Volumes/CannMedia | "$PYTHON" -c 'import plistlib,sys; print(plistlib.loads(sys.stdin.buffer.read()).get("VolumeUUID", ""))')"
if [[ "$ACTUAL_VOLUME" != "$EXPECTED_VOLUME" ]]; then
  echo "The expected CannMedia archive volume is not mounted. Nothing was installed." >&2
  exit 1
fi
umask 077
mkdir -p "$ROOT/meetings" "$ROOT/incoming" "$ROOT/runtime/worker" "$ROOT/runtime/models" "$ROOT/runtime/cache" "$ROOT/runtime/tmp" "$ROOT/logs"
if [[ "$SOURCE" != "$ROOT/runtime/worker" ]]; then
  /usr/bin/rsync -a --exclude='__pycache__' --exclude='.venv' "$SOURCE/" "$ROOT/runtime/worker/"
fi
if [[ ! -x "$ROOT/runtime/venv/bin/python3" ]]; then "$PYTHON" -m venv "$ROOT/runtime/venv"; fi
export PIP_CACHE_DIR="$ROOT/runtime/cache/pip"
export TMPDIR="$ROOT/runtime/tmp"
"$ROOT/runtime/venv/bin/python3" -m pip install -r "$ROOT/runtime/worker/requirements.txt"
"$ROOT/runtime/venv/bin/python3" -m pip check
"$ROOT/runtime/venv/bin/python3" -c 'import faster_whisper, pyannote.audio; print("Worker libraries import successfully")'

# Nemotron 3 Diarization runs through FluidAudio's CLI, built here at a pinned
# commit (v0.18.0; its tag is annotated, so pin the commit itself).
FLUIDAUDIO_COMMIT="e15287985625dbf544a343df679436789ffb03fb"
FLUIDAUDIO="$ROOT/runtime/fluidaudio"
mkdir -p "$ROOT/runtime/bin"
if [[ ! -d "$FLUIDAUDIO/.git" ]]; then
  git clone --quiet https://github.com/FluidInference/FluidAudio.git "$FLUIDAUDIO"
fi
if [[ "$(git -C "$FLUIDAUDIO" rev-parse HEAD)" != "$FLUIDAUDIO_COMMIT" ]]; then
  git -C "$FLUIDAUDIO" fetch --quiet origin "$FLUIDAUDIO_COMMIT"
  git -C "$FLUIDAUDIO" checkout --quiet --detach "$FLUIDAUDIO_COMMIT"
fi
# Two jobs keep the build inside Bruce's 8 GB alongside everything else.
(cd "$FLUIDAUDIO" && /usr/bin/nice -n 10 swift build -c release --product fluidaudiocli -j 2)
install -m 755 "$FLUIDAUDIO/.build/release/fluidaudiocli" "$ROOT/runtime/bin/fluidaudiocli"
# Diarize a second of silence so the model downloads and compiles now, not
# during the first meeting. It caches under ~/Library/Application Support/FluidAudio.
WARMUP="$ROOT/runtime/tmp/nemotron-warmup"
mkdir -p "$WARMUP"
"$PYTHON" -c 'import sys, wave; w = wave.open(sys.argv[1], "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(bytes(32000)); w.close()' "$WARMUP/silence.wav"
"$ROOT/runtime/bin/fluidaudiocli" nemotron3-diarize "$WARMUP/silence.wav" --variant offline --output "$WARMUP/silence.rttm" >/dev/null
rm -rf "$WARMUP"
echo "Nemotron 3 Diarization is ready"
echo "Installed worker at $ROOT. No background service has been enabled yet."
