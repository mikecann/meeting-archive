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
PYTHONPATH=worker python3 -m meeting_archive_worker identify-speakers --meeting-id UUID --revision 1 --names '{"incoming:SPEAKER_00": "Name"}' --db WORKER_DB
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
`OPENROUTER_API_KEY`; the worker never includes them in status or result JSON.
The service accepts `--db WORKER_DB` and optional `--poll-seconds SECONDS`. It
holds one process lock for that database, while both media processing and
publication also use durable leases for crash recovery. Heavy processing runs
one job at a time in a child process with a time budget of max(1 hour, 6x the
meeting duration); speaker refresh and Notion publication run on a separate
thread so they never wait behind a long transcription.

Whisper defaults to two CPU threads and enables its voice-activity filter to
avoid inventing text across long silent spans. On a track that is diarized it
also asks for word timestamps, which slow Whisper down, and gives each word to
the pyannote speaker active at the word's midpoint (the nearest speaker turn if
none is). A Whisper line is split into separate turns where the speaker
changes, so someone cutting in mid-sentence no longer has their words labelled
as the previous speaker's. A run of one or two words spanning under 0.3 seconds
in total, sitting between the same speaker on both sides, stays with that
speaker instead of making a turn.
A track held to one speaker skips word timestamps. Diarization decodes through
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

Confirming speaker names rewrites
the JSON and Markdown views with fsync plus atomic replacement, then requests a
fresh idempotent Notion publication without retranscribing media.

`review-speakers` returns nullable confirmed, automatic, and tentative names,
the kind of each automatic name (`strong`, `own_microphone`, `same_meeting` or
`context`), what the conversation called the voice (`context_name`,
`context_confidence`, `context_evidence`),
cosine similarity and separation values, whether an embedding exists, the three
wordiest timestamped lines per diarized speaker in the order they were said, an
optional absolute playback path, and normalized
calendar candidate objects. Candidates are the top-level `attendees` the app
writes for the calendar event it matched, each `{name, email, response}`. A
bundle without that list falls back to the attendees of its only event under
`calendar`, and suggests nobody when there were several.

`identify-speakers` is what the app's **Save names** runs. `--names` is a JSON
object of speaker ID to name; every name is saved in one transaction or none
is, and the reply lists exactly what was saved,
`{"schema_version":1,"meeting_id":"UUID","manifest_revision":1,"speakers":[{"speaker_id":"incoming:SPEAKER_00","name":"Name","voice_profile_enrolled":true}]}`.
`identify` saves one name the same way. Both use each speaker's saved
observation and enroll it only because Mike saved that name. A speaker whose
pyannote embedding is empty, non-finite or all zeros has no embedding: it is
still reviewed, but never matched or enrolled, and the rest of the job carries
on.

Matching gates come from Mike's own voices on Bruce on 2 Oct 2026: 22 confirmed
voices from 9 meetings. Two different people scored at most 0.654 against each
other across meetings and 0.640 within one meeting; the same person scored
anywhere from 0.04 to 0.82, because short and split voices give noisy
embeddings. So similarity-based naming only names the mic's single voice below 0.72
(naming from the conversation, below, is a separate signal):

| Rule | Gate | Result |
| --- | --- | --- |
| Voice matches someone confirmed in one meeting | 0.82, margin 0.08 | Named automatically |
| Voice matches someone confirmed in two or more meetings | 0.72, margin 0.08 | Named automatically |
| Voice is close to someone confirmed in two or more meetings | 0.65, margin 0.08 | Suggested only |
| The only voice on the mic is its usual owner | 0.65, margin 0.08 | Named automatically |
| Voice matches one Mike saved in the same meeting | 0.72, margin 0.08 | Named automatically |
| The conversation named the voice (see below) and no rule above did | high or medium confidence | Named automatically |

The mic's owner is whoever Mike confirmed on the microphone in the most
meetings; other people heard through his mic scored at most 0.612 against him,
and his own mic tracks 0.72 to 0.96. When two rules name a voice differently it
is only a suggestion. Leaving out each confirmed voice in turn and matching it
against the rest, these rules named 7 of the 22 automatically, all correctly,
where the old 0.82 rule named none. These are still not calibrated
probabilities. Matching excludes the current meeting across all revisions.
Profile provenance is migrated from unambiguous existing assignments and
observations; repeated confirmations update one source profile.

Automatic names are written as transcript names with `name_source` set to
`voice_match` (or `context`, below) and count as reviewed; they are recomputed
on every refresh and never enrolled by that alone. Explicit corrections use `confirmed`. Tentative matches stay in
the review evidence. Saving a name also queues a refresh of every other accepted
meeting with an unnamed voice within 0.57 of the saved voice, or of any sample
of someone whose confirmed meetings crossed two or who became or stopped being
the mic's owner, so the service updates those names in the background. When the matching rules change
(`MATCHING_RULES_VERSION`), the service queues one refresh of every meeting
with an unnamed voice, so older meetings get the new rules without being
opened. On 2 Oct that takes Bruce from 12 voices needing names to 9. The
service retries durable speaker refresh requests so interrupted transcript or
Notion updates recover without retranscribing or enrolling predictions.
Per-meeting locks serialize review/confirmation writes.

The worker no longer reads names off video frames. `review-speakers` still
returns `evidence_labels` for each speaker, always as an empty list, because
the app decodes it. A `visual-labels.json` left in an older meeting is ignored.

## Naming voices from the conversation

With the same OpenRouter key, each transcript gets one request that names its
speaker labels from what people say: introductions, being thanked or addressed
by name and answering, and the calendar attendees once other clues say which is
which. It is its own durable stage on its own service thread, like the
summary: a `naming_jobs` table with the summary's attempts, backoff and
`Retry-After` handling, strict JSON schema, low reasoning effort and
`provider.require_parameters`. `MEETING_ARCHIVE_NAMING_MODEL` picks the model
(default `anthropic/claude-opus-5.5`, which named 36 of 42 voices correctly and
none wrongly on real meetings with this prompt). Without a key it is off. A
failure never blocks transcription, Notion or the summary.

The request is a "Meeting details" block (app, length, a title someone chose,
recorded by Mike Cann, calendar attendees), a roster of each label's turns and
words, then every line as `[time] label: text` with the raw diarization label.
Names written onto the transcript and an AI title are never sent, so the
stage cannot read its own output; a speaker refresh asks for naming again only
when the request would differ, which it never does for names alone. The answer
goes to `transcripts/vN/naming.json` with its `input_sha256` (prompt, schema
and model), so an unchanged transcript is never paid for twice, and its
`usage` and cost.

Only `high` and `medium` names are kept, in the `context_names` table with
their evidence quote and the voice's seconds of speech and words. A kept name
is the automatic name of a voice that Mike hasn't named and no voice-match rule
named: a saved name always wins, and a voice match wins over a conflicting
conversation name (the conversation's is still recorded). It is written to the
turns with `name_source` `context`, and into `speaker_matches` as
`suggestion_kind` `context` with `context_name`, `context_confidence` and
`context_evidence`, so `transcript.md`, search and Notion show it like any
automatic name. A voice with no embedding can be named this way too.

The summary waits while a meeting's naming is ready or running, so it uses the
names, but not while naming waits to retry or has failed. When naming finishes
the transcript is rewritten, Notion is refreshed and the summary is asked for
again at once.

### Learning voices when two signals agree

Only names Mike saves enroll voice profiles, with one exception. When the
conversation named a voice at `high` confidence and the voice agrees, naming
also enrolls it as a profile marked `source = 'context'` (`voice_profiles.source`
is `confirmed` otherwise). It agrees when either:

- its embedding scores 0.55 or more against an enrolled profile of the same
  name (compared ignoring case; the profile's spelling is kept), or
- nobody of that name is enrolled yet, and another meeting's conversation gave
  the same name at high confidence to a voice scoring 0.55 or more against this
  one. This voice and the closest such voice are both enrolled.

The measured highest score between two different people was 0.654, so the
score alone proves nothing; the matching name is what makes this safe. Never
enrolled: a zero or non-finite embedding, a voice with under 15 seconds of
speech or under 40 words, a `microphone:` voice (Mike's own is handled by
his saved profile), the name "AI", or a voice Mike has named. A voice learned
this way counts as a confirmed meeting when matching other voices, and a name
Mike saves for it later replaces the automatic profile. A meeting's context
profiles are rebuilt each time it is named, so a changed name doesn't leave
the old one.

`context-voices` lists these profiles. `forget-context-voices [--name NAME]
[--meeting-id UUID]` removes them (all, or by name or meeting), never Mike's
own, and queues a refresh of every meeting with an unnamed voice so names that
rested on them go. `learn-context-voices` learns again from every meeting's
saved names, for example after `forget-context-voices`.

`name-speakers --db WORKER_DB [--meeting-id UUID ...]` queues naming for those
meetings, or every processed one, for the service to run. A meeting named
before and unchanged costs nothing. A meeting whose naming is waiting to retry
or has failed is not queued: it is listed under `needs_retry`, and `retry`
releases it. It is also what the service does by itself
the first time it starts with a key. `status` and `retry` report and release the
`naming` stage like the others. Cost is about the summary's, since the prompt
carries the same transcript: roughly 5 to 15 US cents per meeting.

## AI titles and summaries

With an OpenRouter API key, each meeting gets a short title, three to five
summary points and any action items, written by Claude from its transcript.
Without a key the stage is skipped quietly and nothing else changes. To turn
it on, add `openRouterApiKey` to the protected credentials file (see below),
then restart with `install-service-bruce.sh --enable`. Nothing extra is
installed: the worker calls OpenRouter's chat completions API with the
standard library.

It is its own durable stage on its own service thread. When a transcript is
written, a summary job is queued. The first start with a key also queues every
meeting processed earlier. The job sends the transcript, with speaker names or
labels like "Remote speaker 1", rough timestamps, the source app, date, length
and calendar attendees, to `anthropic/claude-opus-5.5` at low reasoning
effort, asking for JSON that fits a strict schema. Set
`MEETING_ARCHIVE_SUMMARY_MODEL` to use another OpenRouter model. The whole
transcript is always sent; one too long for a single request fails visibly
rather than being cut short.

The worker checks the answer against that schema itself, since not every
provider behind OpenRouter enforces it, then writes it atomically to
`transcripts/vN/summary.json` with its `schema_version`, `provider`
(`openrouter`), the `model` it asked for, the `served_by` model OpenRouter
reports, its `usage` (requests, tokens and `cost` in US dollars, added up
across any retries) and an `input_sha256` of everything sent. A retry with the
same transcript and model reuses it without calling OpenRouter. Confirming
speaker names asks for a fresh summary five minutes after the last name, so it
can use them. When voices are named from the conversation the summary waits
for that and is asked again as soon as the names are in. A summary that failed
is left to its own backoff, or to `retry`.

An OpenRouter outage never holds up transcription or Notion. The page is
published without a summary and updated in place once one arrives. Rate limits
(429), timeouts (408), server errors and network failures retry with backoff
from 1 minute, doubling to an hour, never sooner than a `Retry-After` header
asks (up to a day), and become a `permanent_failure` after 8 attempts. Running out of
credits (402) waits an hour between tries, so a top-up within about seven
hours lets it carry on by itself. An answer that runs out of room is asked for
again with 16,000 tokens, and one that isn't valid JSON in the expected shape
is asked for once more. If the second try doesn't help, the summary fails
permanently, as a refusal or content filter, a rejected key (401), a
forbidden request (403) or a bad request (400) does straight away. `retry`
releases it, for example after fixing the key and restarting.

The AI title replaces only a title nobody chose: the app's default title
(`title_source` `default`), or, for recordings from before the app recorded a
source, one matching its old default pattern such as `Meeting 23 Sep 2026 at
6:47 am`. A calendar title, a title typed in the app and any rename stay. The
AI title is written through the same `title.json` as `rename`, marked
`"source": "ai"`, so Notion, search, the viewer and the app pick it up. The app
adopts Bruce's display title for any meeting the user didn't name there.

Cost is roughly 5 to 15 US cents per meeting on Claude Opus 5.5, at $4 per
million input tokens and $20 per million output tokens: about 5 cents for a
half-hour call and 10 to 15 cents for 90 minutes. A meeting whose speakers are
named after it was summarized is summarized again, so allow about double for
those. Each `summary.json` records what it actually cost.

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
`openRouterApiKey`, which becomes `OPENROUTER_API_KEY` and turns on AI titles
and summaries. Symlinks, shared permissions, unexpected fields, empty values
and malformed data are rejected. Values only enter the worker's process
environment; the wrapper first clears any inherited `OPENROUTER_API_KEY`,
along with the old `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
`ANTHROPIC_BASE_URL`. They are never printed, placed in command arguments, or
included in the plist/source repository.
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
