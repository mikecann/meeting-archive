# Meeting Archive worker foundation

This stdlib-only Python package verifies finalized meeting bundles, accepts
them into permanent storage without overwriting archive inputs, and durably
queues one heavy processing job at a time.

Run it from the repository root with the worker directory on `PYTHONPATH`:

```sh
PYTHONPATH=worker python3 -m meeting_archive_worker verify INCOMING_DIR
PYTHONPATH=worker python3 -m meeting_archive_worker accept --incoming INCOMING_DIR --archive-root ARCHIVE_ROOT --db WORKER_DB --manifest-sha256 RAW_MANIFEST_SHA256 --validate-media
PYTHONPATH=worker python3 -m meeting_archive_worker status --db WORKER_DB --meeting-id UUID
PYTHONPATH=worker python3 -m meeting_archive_worker retry --db WORKER_DB --meeting-id UUID
PYTHONPATH=worker python3 -m meeting_archive_worker process-ready --archive-root ARCHIVE_ROOT --db WORKER_DB --processor package.module:function
PYTHONPATH=worker python3 -m meeting_archive_worker review-speakers --archive-dir MEETING_DIR --revision 1 --db WORKER_DB
PYTHONPATH=worker python3 -m meeting_archive_worker identify --meeting-id UUID --revision 1 --speaker-id incoming:SPEAKER_00 --name "Name" --db WORKER_DB
PYTHONPATH=worker python3 -m meeting_archive_worker.service --db WORKER_DB
```

Every command writes one compact JSON object. Validation and contract errors
use exit code 2. A processor failure uses exit code 1 and records either a
retry with bounded exponential backoff or a visible permanent failure when the
adapter raises `meeting_archive_worker.cli.PermanentProcessingError`. After 8
attempts a transient failure also becomes a permanent failure; an expired lease
(the worker died mid-job) counts as a failed attempt and backs off the same way.

Production transfers pass `--validate-media`. The worker probes every declared
audio/video file in permanent storage for the expected stream and a positive
duration, fully decodes each stream, and re-verifies its manifest hash before
it commits the cleanup acknowledgement. The acknowledgement then includes a
`media_validation` audit object. Each file records `coverage_end_seconds` and
`truncated`; a track that ends before the claimed meeting duration adds a
`warnings` entry such as `video_truncated` rather than blocking cleanup, since
the Mac holds the same hash-verified bytes and a retry cannot recover more. Omitting the flag is intended for lightweight
fixture tests and does not add that object.

`ARCHIVE_ROOT` and the parent directory of `WORKER_DB` must already exist. The
service deliberately will not create the configured volume root, so a missing
external volume cannot turn into a lookalike directory on the startup disk.
Installation must verify the expected mounted volume before creating them.

The processor callable receives `(archive_directory: Path, job: Job)`. Model
packages stay outside this core so importing and testing it never loads a
transcription model. `TranscriptProcessor` provides the separate-channel merge
seam: it preserves `microphone` or `incoming` as `channel_origin`, independently
of any optional diarization speaker label.

It transcribes the incoming track first. If anyone on it spoke, the whole
microphone track is one speaker, `microphone:SPEAKER_00`, because Mike wears
headphones on calls and the mic only hears him. pyannote still runs once on
the mic, held to one speaker, purely for that voice embedding so profile
matching can name him. A recording with no incoming speech, like an in-person
meeting, has its microphone diarized as before.

The optional Bruce adapter is `meeting_archive_worker.processor:process`.
It imports faster-whisper and pyannote only when a job runs. Configure `HF_HOME`
on CannMedia and supply `HF_TOKEN` to enable diarization. With no token it
refuses to start model work and leaves the job retryable. The explicit
`MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION=1` override exists for
synthetic testing and records diarization as disabled in provenance. The setup
smoke test is
`python -c 'import faster_whisper, pyannote.audio'`; real model success still
requires a representative fixture benchmark on Bruce.

After the transcript, the adapter builds `playback/meeting.mp4` for review
excerpts and the viewer, with a `meeting-playback.json` receipt so a retry
reuses it. Both audio tracks are mixed on the transcript's capture clock. A
bundle with video, from before v2, also gets H.264 video. An audio-only
bundle gets an AAC-only MP4.

The service keeps media processing, AI summaries and Notion publication in
separate durable SQLite states. A Notion outage retries publication with
backoff and does not run transcription or playback generation again.
Credentials are read only from `MEETING_ARCHIVE_NOTION_TOKEN`,
`MEETING_ARCHIVE_NOTION_DATA_SOURCE`, `HF_TOKEN` and, for summaries,
`ANTHROPIC_API_KEY`; the worker never includes them in status or result JSON.
The service accepts `--db WORKER_DB` and optional `--poll-seconds SECONDS`. It
holds one process lock for that database, while both media processing and
publication also use durable leases for crash recovery. Heavy processing runs
one job at a time in a child process with a time budget of max(1 hour, 6x the
meeting duration); speaker refresh and Notion publication run on a separate
thread so they never wait behind a long transcription.

Whisper defaults to two CPU threads and enables its voice-activity filter to
avoid inventing text across long silent spans. Diarization decodes through
ffmpeg into a disk-backed 16 kHz mono buffer so pyannote does not depend on
torchcodec's FFmpeg ABI support. The float waveform has a default 1.5 GiB
memory budget, configurable with
`MEETING_ARCHIVE_MAX_DIARIZATION_MEMORY_BYTES`. The worker never truncates a
long track: if it exceeds that budget, the complete source stays queued with
an actionable error. Chunked diarization with cross-chunk speaker matching is
required before unusually long recordings can run inside a smaller budget.

`status` accepts up to 100 repeated `--meeting-id` filters. Its processing jobs,
counts, and nested publication jobs are scoped to those meetings, which keeps
the app response bounded as the archive grows. Omitting the filter retains the
operator-facing full queue response. The `publication` and `summary` objects
include their scoped aggregate `phase`, `last_error`, counts, and durable job
details. Each processing job also carries the meeting's current display
`title`, the one Notion and search show, so the app can follow AI titles and
renames made on Bruce.

`retry --meeting-id UUID` is an idempotent operator action. It releases only a
processing job in `retry_wait` or `permanent_failure`, or an errored publication
job in `retry_wait`, or a summary in `retry_wait` or `permanent_failure` (with
a fresh attempt budget). It never takes a live lease and never moves succeeded
processing back to ready, so a Notion or summary retry cannot retranscribe the
meeting. The JSON response identifies the processing, optional publication and
optional summary stage and whether this call changed any queue.

`rename --meeting-id UUID --title TEXT --archive-root ROOT --db WORKER_DB` sets
a meeting's display title without touching the manifest-hashed `metadata.json`.
It atomically writes `title.json` beside it, with `"source": "user"`, which
Notion, search and the viewer prefer over the captured title, and queues a
Notion republish once processing has succeeded. A rename always wins: an AI
title never replaces it, then or later. Titles are trimmed, at most 200
characters, with no control characters. It is idempotent and prints
`{"schema_version":1,"meeting_id":...,"title":...}`.

After `accept` commits a receipt it removes the staged copy at
`INCOMING_ROOT/<meeting>/r<revision>` and then that meeting directory if it is
empty. `INCOMING_ROOT` defaults to `incoming` beside the archive root and can be
set with `--incoming-root`; symlinked or out-of-layout paths are left alone, and
a removal failure is only logged. A retried accept whose staging is already gone
returns the committed receipt when `--manifest-sha256` matches it.

`search --query TEXT --archive-root ROOT --db WORKER_DB [--limit N]` finds a
case-insensitive substring in each accepted meeting's transcript and prints
`{"schema_version":1,"results":[{"meeting_id","title","matches":[{"start_seconds","speaker","text"}]}]}`,
newest meeting first, at most 5 matches per meeting and `N` meetings (default
20, maximum 100). Queries are trimmed and must be 2 to 200 characters.

Confirming a speaker name rewrites
the JSON and Markdown views with fsync plus atomic replacement, then requests a
fresh idempotent Notion publication without retranscribing media.

`review-speakers` returns nullable confirmed, automatic, and tentative names,
cosine similarity and separation values, whether an embedding exists, three timestamped excerpts
per diarized speaker, an optional absolute playback path, and normalized
calendar candidate objects. Candidates are the top-level `attendees` the app
writes for the calendar event it matched, each `{name, email, response}`. A
bundle without that list falls back to the attendees of its only event under
`calendar`, and suggests nobody when there were several. `identify` uses the
saved observation automatically and enrolls it only after that explicit
confirmation. A speaker whose pyannote
embedding is empty, non-finite or all zeros has no embedding: it is still
reviewed, but never matched or enrolled, and the rest of the job carries on.

Strong matches retain the 0.82 cosine / 0.08 runner-up margin gate and require
an explicitly confirmed source meeting. Review-only tentative suggestions use
0.65 / 0.08 and at least two distinct confirmed source meetings. These are
engineering defaults, not calibrated probabilities or a completed human
recognition accuracy benchmark. Matching excludes the current meeting across
all revisions. Profile provenance is migrated from unambiguous existing
assignments and observations; repeated confirmations update one source profile.

Only strong matches are written as transcript names, with `name_source` set to
`voice_match`. Explicit corrections use `confirmed`. Tentative matches stay in
the review evidence. The service retries durable speaker refresh requests so
interrupted transcript or Notion updates recover without retranscribing or
enrolling predictions. Per-meeting locks serialize review/confirmation writes.

The worker no longer reads names off video frames. `review-speakers` still
returns `evidence_labels` for each speaker, always as an empty list, because
the app decodes it. A `visual-labels.json` left in an older meeting is ignored.

## AI titles and summaries

With an Anthropic API key, each meeting gets a short title, three to five
summary points and any action items, written by Claude from its transcript.
Without a key the stage is skipped quietly and nothing else changes. To turn
it on, rerun `install-bruce.sh` so the environment has the pinned `anthropic`
package, add `anthropicApiKey` to the protected credentials file (see below),
then restart with `install-service-bruce.sh --enable`. A key without the
package is reported once in the service log.

It is its own durable stage on its own service thread. When a transcript is
written, a summary job is queued. The first start with a key also queues every
meeting processed earlier. The job sends the transcript, with speaker names or
labels like "Remote speaker 1", rough timestamps, the source app, date, length
and calendar attendees, to `claude-opus-5-5` at low effort with a structured
output schema, opting in to Anthropic's recommended fallback model if a safety
classifier declines. The whole transcript is always sent; one too long for a
single request fails visibly rather than being cut short.

The answer is written atomically to `transcripts/vN/summary.json` with its
`schema_version`, `model`, `served_by` model and an `input_sha256` of
everything sent. A retry with the same transcript reuses it without calling
Claude. Confirming speaker names asks for a fresh summary five minutes after
the last name, so it can use them.

A Claude outage never holds up transcription or Notion. The page is published
without a summary and updated in place once one arrives. The SDK retries rate
limits and server errors itself; anything still failing retries with backoff
from 1 minute, doubling to an hour, and becomes a `permanent_failure` after 8
attempts. A refusal, a rejected key or an invalid request is permanent at
once. `retry` releases it, for example after fixing the key and restarting.

The AI title replaces only a title nobody chose: the app's default title
(`title_source` `default`), or, for recordings from before the app recorded a
source, one matching its old default pattern such as `Meeting 23 Sep 2026 at
6:47 am`. A calendar title, a title typed in the app and any rename stay. The
AI title is written through the same `title.json` as `rename`, marked
`"source": "ai"`, so Notion, search, the viewer and the app pick it up. The app
adopts Bruce's display title for any meeting the user didn't name there.

Cost is roughly 5 cents for a half-hour call and 10 to 15 cents for 90
minutes, at $4 per million input tokens and $20 per million output tokens. A
meeting whose speakers are named after it was summarized is summarized again,
so allow about double for those.

## Bruce background service

Bruce uses the fixed external root `/Volumes/CannMedia/MeetingArchive`. The
runtime wrapper refuses to start unless `/Volumes/CannMedia` reports the exact
volume UUID `5CCB1D81-5A98-4C4A-9E2C-3E10B23F1B46`. It performs that check
before Python can open `worker.sqlite`, and it never creates a replacement path
on the internal disk.

The deployment paths are fixed:

- worker source: `/Volumes/CannMedia/MeetingArchive/runtime/worker`
- Python environment: `/Volumes/CannMedia/MeetingArchive/runtime/venv`
- Hugging Face models: `/Volumes/CannMedia/MeetingArchive/runtime/models`
- other caches: `/Volumes/CannMedia/MeetingArchive/runtime/cache`
- decode scratch space: `/Volumes/CannMedia/MeetingArchive/runtime/tmp`
- queue database: `/Volumes/CannMedia/MeetingArchive/worker.sqlite`

Stage the per-user LaunchAgent without loading it:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-service-bruce.sh
```

Staging is the default so the generated plist can be reviewed first. Starting
or restarting the service always requires the explicit flag:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-service-bruce.sh --enable
```

The LaunchAgent runs one low-priority background service. The wrapper constrains
Whisper, PyTorch, OpenMP, and MKL to two CPU threads, disables model telemetry,
sets the virtual-environment and Homebrew system-tool path explicitly, and
redirects `TMPDIR`, `TMP`, `TEMP`, model data, caches, and decode scratch space
to CannMedia. It explicitly removes the synthetic-test transcription bypass
from its environment. The worker's own process lock and SQLite leases reject a
second active worker. Niceness is applied by the wrapper so direct invocation
has the same low-priority behavior as LaunchAgent invocation.

Bruce's login Keychain is locked for unattended SSH work. The launcher instead
loads `/Volumes/CannMedia/MeetingArchive/runtime/secrets/credentials.json`
from the encrypted archive volume. The directory must be owned by the worker
user with mode `0700`; the regular file must have mode `0600` and contain the
approved `huggingFaceToken` and `notionToken` JSON fields, plus an optional
`anthropicApiKey`, which becomes `ANTHROPIC_API_KEY` and turns on AI titles
and summaries. Symlinks, shared permissions, unexpected fields, empty values
and malformed data are rejected. Values only enter the worker's process
environment; the wrapper clears any inherited `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_BASE_URL` first. They are never printed,
placed in command arguments, or included in the plist/source repository.
Provisioning requires the user's authorization and occurs separately over
encrypted SSH.

The scripts never create or copy credentials. If credentials are unavailable,
the service still starts; affected jobs remain in durable retry state and
`status` exposes the processing or publication error. Notion publication uses the
existing data source `fe4b72d1-b303-42ba-a812-3349655746c5` without changing
its schema.

Credentials are loaded once when the service process starts. After adding or
changing the protected credential file, restart explicitly with:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/install-service-bruce.sh --enable
```

Disable and unstage the service with:

```sh
bash /Volumes/CannMedia/MeetingArchive/runtime/worker/uninstall-service-bruce.sh
```

Disabling unloads the LaunchAgent and removes only its plist. It preserves the
archive, incoming data, SQLite queues, models, caches, worker source, and
the protected credential file. Any interrupted lease is recovered by the normal retry logic
when the service is explicitly enabled again.

## Private playback viewer

The optional playback viewer resolves canonical meeting UUIDs only through the
durable acceptance database and exposes the fixed generated playback and
transcript resources on localhost. Its production wrapper is locked to
`127.0.0.1:8791`, the verified CannMedia meetings root, four request threads,
and the Tailscale identity `mike.cann@gmail.com`. It receives no model or
publication credentials.

Installation stages an owner-only LaunchAgent by default. Starting the viewer
requires `--enable`, and Tailscale routing remains a separate explicit action.
The intended tailnet-only route is HTTPS port 10443 to localhost port 8791, so
Bruce's existing 443 and 8443 routes remain untouched. See
[`VIEWER.md`](VIEWER.md) for the route contract, security checks, isolated
fixture command, staging steps, and exact rollback commands.
