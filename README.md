# <img src="icons/meeting-archive.png" width="24" alt=""> meeting-archive

Records your calls when the camera comes on and files them away for later

macOS

<!-- media: hero -->
<!-- ![meeting-archive](docs/hero.png) -->
<!-- /media: hero -->

![A webcam switching on a video call whose audio becomes speaker-labelled transcript cards filed into an archive box](docs/header.webp)

## What it is

This is still very much a preview. It's a menu-bar app that starts recording a meeting window when the meeting app turns the camera on, and stops once the camera's been off for 20 seconds or the window closes. I've only properly tested it with Zoom so far.

When a call ends it asks for a title, then sends the recording off to my home server for transcription and speaker review, and it can end up in Notion too.

The home server is called Bruce in the scripts. Its worker is included in this
repo, but the disk paths and volume identity are specific to my setup. Read
[Adapting the worker](#adapting-the-worker) before installing it elsewhere.

## Get it

Paste this into your AI coding agent (Claude Code, Codex, Cursor...):

> Clone https://github.com/mikecann/meeting-archive and make it my own. It's one of Mike
> Cann's personal tools, so read the README first, change anything specific to his
> setup to suit mine, then help me get it running.

### Or set it up by hand

The capture app needs macOS 15 or later and Swift 6 or later. Install Xcode and
its command line tools. Full Xcode is needed for the XCTest suite. My worker
setup uses an Apple Silicon Mac, Python 3.13 and ffmpeg on PATH. The worker's
model packages are only needed for transcription, not for its unit tests.

```sh
git clone https://github.com/mikecann/meeting-archive.git
cd meeting-archive
bash install.sh
bash setup_mac.sh
open "$HOME/Applications/Meeting Archive.app"
```

`install.sh` links the `meeting-archive` command into `~/.local/bin`. You can
pass a different bin directory as its first argument. Add that directory to
PATH if needed. Re-run it after moving the clone. `setup_mac.sh` builds and
signs the app, and `--with-launcher` can also create the default launcher.
Neither script downloads models or enables the Bruce worker.

Quit Meeting Archive from its menu before updating or rebuilding it so an
active recording can finish cleanly. Use `bash restart.sh` to rebuild and open
the staged app after a change.

The capture app needs no API keys. For local worker commands, copy
`.env.example` to `.env`, fill in your Hugging Face token and optional Notion
settings, then load them in your shell:

```sh
cp .env.example .env
# Edit .env before loading it. Quote values when they contain shell characters.
set -a
source .env
set +a
```

The Hugging Face token needs access to the configured pyannote diarization
model. The managed Bruce service loads a private credential file instead of
`.env`; see [worker setup](worker/README.md#bruce-background-service).

When a login item already exists, the setup script re-registers it through
LaunchServices and restarts the background agent. A replaced bundle is otherwise
refused by launchd (`EX_CONFIG`) until it is re-registered, and registering from
a shell does not count. The build signs with your Apple Development identity
when one is available, so the signature stays stable across rebuilds.

## Using it

Open Settings from the menu bar, grant the capture permissions and select the
calendars you want to use. Set the worker host and archive path to match your
worker installation. Join a Zoom call and turn the camera on to begin recording.
Turning the camera off for 20 seconds or closing the meeting window ends it.

Give the call a title when prompted. The library shows transfer and processing
progress, then lets you play the recording and review the speaker names. Enable
launch at login from Settings if you want the app available after a restart.

Chrome automatic capture is blocked pending a choice between a dedicated Meet
window and manual tab capture. Teams and Slack adapters are implemented but
live-unverified. Remote speech, shared-screen readability and the broader app
matrix still need validation.

## Adapting the worker

The app defaults to host `bruce` and `/Volumes/CannMedia/MeetingArchive`. Change
the host and archive path in Settings. The worker scripts additionally lock down
my disk UUID, archive path, Notion data source, playback URL and Tailscale login.
Those guards are intentional, so changing a single environment variable is not
enough to adapt the managed service.

Before deploying on another machine, update the matching constants in
`worker/install-bruce.sh`, the worker service/viewer install and run scripts,
`worker/launcher/Sources/LauncherConfiguration.swift`,
`worker/launcher/Sources/main.swift`,
`worker/meeting_archive_worker/credentials.py`, and the remote path guards in
`Sources/MeetingArchiveApp/ArchiveTransfer.swift`. Keep volume and path checks
in place, and run the tests again after adapting their fixtures.

On the worker Mac, install Python 3.13 and ffmpeg, then run
`bash worker/install-bruce.sh` from this clone after adapting those settings.
It copies the worker into the configured external archive runtime and installs
`worker/requirements.txt` in a dedicated virtual environment. Build the
[worker launcher](worker/launcher/README.md), grant its disk access from Finder,
and follow the [service setup](worker/README.md#bruce-background-service).
Notion and the [private playback viewer](worker/VIEWER.md) are optional and need
their own configuration. Check your backup coverage before enabling local cleanup.

## Development and tests

Run these from the clone root:

```sh
swift test
PYTHONPATH=worker python3 -W error::ResourceWarning -m unittest discover -s worker_tests
bash verification/run-contract-roundtrip.sh
bash verification/run-offline-regressions.sh
bash diagnostics/run-tests.sh
bash worker/launcher/run-tests.sh
bash worker/vision/run-tests.sh
```

The Python tests use the standard library and synthetic media. Install ffmpeg
to include the playback tests. These commands do not download models, use
credentials or start the capture app. The Vision helper's real image fixture is
optional. GUI harnesses, live transfer and real-media validation in
`verification/` are separate manual checks that need permissions, fixtures or
your worker host. CI runs the offline checks on macOS.

The existing `com.mikerosoft.meeting-archive` app and service identifiers stay
unchanged so settings, permissions and login items keep their identity.

## First launch and privacy

Open the staged app yourself, then use Settings to request the permissions it
needs. macOS may require reopening the app after granting them:

- Accessibility, for meeting-window detection
- Screen & System Audio Recording, for the meeting window and incoming audio
- Microphone, which remains active even when the call is muted
- Notifications, for recording prompts
- Calendar access, after adding your accounts in macOS Internet Accounts;
  select the calendars to use for title and speaker suggestions

The app can register or unregister its login item from Settings. The standalone
`uninstall-startup.sh` does the same startup-only unregister through Apple’s
documented `SMAppService` API and does not delete recordings or archive data.

## Bruce archive and cleanup

The configured Bruce archive path is `/Volumes/CannMedia/MeetingArchive` on
host `bruce`. Before enabling the cleanup toggle, verify that this exact
directory is covered by Bruce’s existing backup. A successful network transfer
alone is not evidence of backup coverage. Cleanup is allowed only after the
worker validates every declared media stream, rechecks the manifest, and saves
its durable processing job.

Until that toggle is on, every recording stays in the local spool after Bruce
has verified it. That is the intended safe default, but it adds up: eight
calls took about 1 GB.

Transfers and Notion publication are retryable and recorded in durable local
state. Retries back off while Bruce is unreachable and are released as soon as
the Mac wakes or the network returns. A Notion outage does not repeat transcription or playback generation.
Existing files under the older `RecordedMeetings` location are left alone and
are not imported automatically yet.

Bruce uses a separate one-time drive permission for the
[worker launcher](worker/launcher/README.md). In my original installation, that consent
was complete and the managed worker passed startup, clean shutdown, and automatic
restart. A solo recording completed processing and publication after a disk
priority correction and retry. That does not verify a new installation or an
actual reboot.

## Recording and naming

Recording follows the meeting app's camera. Turning video off for up to 20
seconds keeps the same recording; the session ends once the camera stays off
for 20 seconds or the meeting window closes. Nothing is polled through
Accessibility while no camera is in use.

When a recording ends, a small floating panel asks for a title. It takes
typing without pulling focus from the call, stays above a full-screen meeting,
and saves on its own after 90 seconds. Typing adds time. Return saves, Esc
saves with the current title, and Discard asks before deleting anything.
Calendar suggestions only appear once calendars are selected in Settings.

An archived meeting can be renamed from the library with **Rename…**. Bruce
stores the new title next to the archive and republishes Notion; nothing is
re-uploaded or re-transcribed.

If the meeting window stops producing frames (hidden, dragged, or static), the
recorder repeats the last frame so the video stays as long as the audio. A
microphone that drops out mid-call is restarted rather than ending the whole
recording.

The app logs capture, detection and transfer events to the unified log:

```sh
log show --predicate 'subsystem == "com.mikerosoft.meeting-archive"' --last 1d
```

## Review and current limits

After naming a meeting, a progress window shows transfer and processing on
Bruce. It can be closed while that work continues. When speaker analysis is
ready, the app brings up speaker review once per meeting revision, deferring
the popup while another call is recording or its title prompt is open. The
menu bar retains a count and direct review actions for speakers needing names,
including after a review is dismissed or the app restarts. Notifications do
not need to be enabled for this window and menu-bar flow.

Strong voice matches are filled in automatically and marked **Recognized**.
Weaker matches can show **Possibly Mike Cann** after at least two different
meetings were explicitly confirmed. These still require **Confirm**. Editing
an automatic name also requires confirmation. Repeatedly confirming the same
recording does not add extra evidence, and predictions never train themselves.
Similarity scores are not confidence percentages.

Bruce also reads known participant names from a few video frames using local
Apple Vision OCR. Visible names and explicit “Talking:” / “Speaking:” labels
appear separately with timestamps. Selecting one only fills the draft; it
does not confirm the speaker. Gallery names do not prove who was speaking.
This analysis makes no external model requests and does not recognise faces.

Confirm any remaining names, then choose **Complete**. **Later** closes review
without marking unresolved speakers complete. Confirmed names remain saved
when reopening review. Archiving and subsequent recordings do not wait for
speaker review.

The library supports playback, transcript access, and speaker review after a
processed archive is available. Calendar candidates are suggestions and need
manual confirmation. Keep the app’s minimal settings explicit: selected
calendars, Bruce host and archive path, and the backup-coverage confirmation.

Do not describe the app as production-ready until a representative live run has
verified recording, transfer, retries, and review on your installation.

The catalog icon reuses the film icon from
[Mark James’s famfamfam silk set](https://www.famfamfam.com/lab/icons/silk/),
licensed under CC BY 2.5.

## More tools

My other tools are at [mikerosoft.app](https://mikerosoft.app).

MIT licensed.
