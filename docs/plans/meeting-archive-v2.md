# Meeting Archive v2: audio only, started by the mic

Status: approved by Mike on 2026-10-01, in progress on `claude/meeting-archive-v2`.

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

## Live tests before installing for real

Each with headphones and once on speakers:

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

- The calendar only ever matched one family event, so the Convex Google account
  is probably missing from macOS Internet Accounts. Mike to check.
- AI titles and summaries are built: Claude Opus 5.5, through Mike's existing
  OpenRouter account, writes a title, three to five summary points and action
  items for each meeting, shown in Notion and synced to the app's library.
  They stay off until the updated worker is on Bruce, `openRouterApiKey` is in
  its protected credentials file and the worker is restarted. No extra package
  is needed. The first start then summarizes earlier meetings too, at roughly
  5 to 15 US cents each. Only titles nobody chose are replaced; calendar
  titles and renames stay.
