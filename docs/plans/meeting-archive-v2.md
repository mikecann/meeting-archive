# Meeting Archive v2: audio only, started by the mic

Status: approved by Mike on 2026-10-01. Installed on Mike's Mac and Bruce on 2026-10-02 from `claude/meeting-archive-v2`; live testing continues.

## Why

v1 started recording when a meeting app turned the camera on, then recorded the
meeting window as video plus two audio tracks. In its first two weeks it caught
eight real calls, all Zoom, and missed everything else:

- camera-off calls, audio-only Slack huddles, FaceTime and phone calls
- anything in Chrome (Google Meet, or Teams in the browser, which is how the
  1 Oct Teams call went unrecorded)
- most of the 1 Oct all-hands, because the video check failed 15 seconds in
  and the app then skipped the rest of the meeting

Video and the per-app window detection were about 20% of the code and caused
every lost recording. Reading speaker names off video frames added almost
nothing. Meanwhile the Bruce side (transfer, processing, Notion, speaker
profiles) worked: 10 of 10 transfers verified, 9 of 10 processed and published.

## What v2 does

1. **Notices the mic.** Core Audio lists which processes are using audio input
   (`kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyIsRunningInput`).
   No permission is needed to read it. A helper process (Chrome, Slack, Discord)
   is traced back to its app, so a Meet or Teams call in Chrome counts as Chrome.
2. **Records first, decides later.** As soon as an app that isn't ignored takes
   the mic, recording starts. When it ends, the recording is kept if it ran for
   at least a minute and someone on the other end spoke (5 seconds of incoming
   audio). Anything shorter or one-sided, like a voice memo, is quietly deleted.
3. **Stops when the app lets go.** Thirty seconds after the app releases the mic,
   the recording finishes. If a different app takes the mic, the current
   recording finishes and a new one starts straight away.
4. **Audio only, two tracks.** `microphone.m4a` (mono, 48 kHz) and `incoming.m4a`
   (stereo, 48 kHz) from a Core Audio process tap of everything the Mac plays,
   minus Meeting Archive itself. Same file names and bundle format as v1, so the
   transfer and worker contracts barely change.
5. **Never gives up on a call.** If a source dies (USB mic stall, AirPods
   switching mode, output device change) it is rebuilt and the track carries on
   with silence over the gap. If the whole capture fails, that part is saved and
   a new part starts while the app still holds the mic. Nothing suppresses the
   rest of a meeting.
6. **Manual control is still there.** Record now, Stop, Discard and "Never record
   this app" in the menu, plus a global hotkey for in-person meetings that no app
   is listening to.
7. **No naming prompt.** The title comes from the calendar when an event matches,
   otherwise it stays generic until Bruce gives it an AI title from the
   transcript, and it can be renamed any time. A notification says what was
   saved, and the menu offers Discard for the 90 seconds before upload.

Ignored by default: Meeting Archive, Voice Type, Record It, Record Meeting,
Telemprompit, Tandem, Apple dictation and Siri, AI voice apps (Claude, ChatGPT),
dictation tools (Superwhisper, MacWhisper, Wispr Flow) and screen recorders
(CleanShot, OBS, QuickTime). Browsers, Zoom, Teams, Slack, Discord, WhatsApp and
FaceTime are recorded. Mike asked for personal calls to be included.

## Permissions

Microphone, "System Audio Recording Only" (asked on the first recording; there is
no public API to check it in advance), Calendar and Notifications. No Screen
Recording, Accessibility or camera access.

## Bruce worker changes

- Build an audio-only `playback/meeting.mp4` when there is no video, so speaker
  review excerpts and the viewer keep working. Old video bundles keep their
  video playback.
- When the incoming track has speech, treat the mic track as one speaker instead
  of diarizing it (Mike wears headphones on calls). A mic-only recording, like
  an in-person meeting, is still diarized.
- Read calendar attendees from where the app actually writes them. v1 never
  delivered them, and the tests used a shape the app never wrote.
- A non-finite voice embedding means "no embedding", not a failed job.
- Drop the video frame name reading (`visual_labels.py`, `worker/vision`).
- Benchmark Parakeet (parakeet-mlx) against `small.en` on Bruce before switching.

## What goes

`MeetingSignalProvider` (accessibility window detection), `CameraActivity`,
`NativeRecording` (ScreenCaptureKit window video), `CaptureStateMachine`,
`CaptureLifecycleCoordinator`, `NativeCaptureLifecycle`, the naming panel, the
camera diagnostic under `diagnostics/` and their tests.

## What stays

Spool bundles, manifests, SSH transfer and verified acknowledgement, local
cleanup, the SQLite store, worker status, speaker review, library, search,
rename, Notion publishing and the login item.

## Speaker review without the chore (2 Oct 2026)

Mike found the review window annoying: it popped up by itself, and on the
2 Oct Slack call pyannote split Micah into two voices that each needed their
own Confirm before Complete would work. He wants it to fade away as it learns
voices.

- **No pop-ups.** The window only opens from the menu bar's **Review
  speakers** entries or the library's button. The menu keeps its count.
- **One click.** Per-speaker Confirm and Complete are gone. **Save names**
  sends every filled-in name, typed, chosen, suggested or recognized, to
  Bruce's new `identify-speakers` in one transaction. Blanks stay unknown. A
  failed save marks nothing saved and the same button retries.
- **One person, one card.** Voices with the same name share a card
  ("Micah · 2 voices"), names merge cards once typed or chosen, and
  **Not Micah** splits a voice back out.
- **Ask less over time.** Bruce names automatically a voice matching someone
  confirmed in two meetings (0.72), the mic's only voice once its owner's voice
  is saved (0.65), and a voice matching one saved in the same meeting (0.72).
  Saving a name refreshes other meetings with that voice in the background,
  and the first sweep after deploying refreshes every meeting with an unnamed
  voice once, which takes Bruce from 12 voices needing names to 9. Automatic
  names still never train the profiles.

The gates come from the voices on Bruce on 2 Oct, read from a copy of
`worker.sqlite`: 43 voices observed in 11 meetings, 22 of them confirmed in 9.

| Pairs | Count | Median | Highest |
| --- | --- | --- | --- |
| Different people, across meetings | 173 | 0.158 | 0.654 |
| Different people, within a meeting | 21 | 0.131 | 0.640 |
| Same person, across meetings | 26 | 0.276 | 0.820 |
| Same person, within a meeting | 11 | 0.365 | 0.741 |

Mike's confirmed mic tracks matched each other at 0.60 to 0.82 one to one
(leaving out one that is probably mislabeled, below), and 0.72 to 0.96 against
the best of his saved samples. Short or split voices give noisy
embeddings, so the same person often scores low; the gates only have to stay
above every different-person pair. The lowest gate with no wrong name was 0.66
(0.65 within a meeting); 0.72 keeps a margin. With each confirmed voice left
out in turn, the new rules named 7 of 22 automatically and all correctly; the
old 0.82 gate named none, including Mike's own mic at 0.8199.

Three saved names look wrong and are worth checking in review: on the 2 Oct
Slack call, Call audio voice 3 is saved as Mike Cann but sounds like Micah
(0.64 to his other voice, 0.29 at most to Mike's mic, and its lines are
Micah's); on the 2 Oct 5:31am Zoom call, voice 4 is saved as Micah but scores
0.05 to 0.08 against the Slack call's Micah while unnamed voice 3 matches him
at 0.91; and on the 29 Sep 7:31am meeting, mic voice 1 is saved as Mike Cann
but sounds more like someone else from the same call (0.61) than Mike (0.20 at
most). The first two probably happened because
review excerpts play both tracks mixed, so a voice that only says "yeah" over
Mike sounds like Mike. Review now plays each voice's wordiest lines instead of
its first ones.

Deploy the worker before the app: **Save names** needs `identify-speakers` on
Bruce, and an older worker answers it with an error the window shows.

## Live tests

Each with headphones and once on speakers. Results so far (2 Oct 2026):

- A fake call (an app holding the mic while the Mac spoke) was detected within a
  second, recorded on both tracks, stopped 30 s after release, kept, uploaded,
  transcribed and published to Notion in about two minutes. On speakers the mic
  repeated the call audio, which led to the echo cleanup on Bruce.
- A 34 minute Zoom call and a 33 minute Slack huddle were caught on their own
  overnight. Zoom holding the mic for 38 s before the huddle was thrown away as
  under a minute, and the huddle started in the same second. Each took about 15
  minutes to process on Bruce with GPU diarization, against 2.5 hours for a
  61 minute call before.
- Still to try: Teams and Meet in Chrome, FaceTime, AirPods switching, and a
  deliberate quit mid-call.

| Scenario | Expected |
| --- | --- |
| Zoom call, camera off | Recorded, kept, both voices transcribed |
| Teams in Chrome | Recorded as Chrome, kept |
| Google Meet in Chrome | Recorded as Chrome, kept |
| FaceTime audio call | Recorded, kept |
| Slack huddle, audio only | Recorded, kept |
| Voice Type dictation | Ignored |
| Voice memo in another app | Recorded, then deleted (nobody else spoke) |
| AirPods connect mid-call | Both tracks continue, gap filled |
| Quit the app mid-call | Part 1 recovered on relaunch, part 2 starts |
| Record now with no app on the mic | Recorded until Stop, always kept |

## Open items

- The Convex calendar can't be added to macOS (SSO), and it's shared with
  Mike's personal account as free/busy only, so work calls rarely get a
  calendar title. AI titles cover that instead.
- AI titles and summaries are live: Claude Opus 5.5 through Mike's existing
  OpenRouter key writes a title, three to five summary points and action items
  for each meeting, shown in Notion and synced to the app's library. All
  earlier meetings were summarized on 2 Oct, at about 5 US cents for a half
  hour call. Only titles nobody chose are replaced.
- Speaker review excerpts play both tracks mixed, which makes some voices hard
  to tell apart. Playing just the speaker's own track would help.
