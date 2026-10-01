# Agent guidance for meeting-archive

This repo contains a native macOS 15+ Swift menu-bar capture app and its Python
archive worker. All source paths and commands below are relative to this clone.

## Working on changes

- Use test-first development for non-trivial changes. Write or update a test
  first, extracting a test seam if necessary.
- When behaviour, UI copy, persistence, startup or a tested contract changes,
  update the relevant expectations and rerun the affected tests.
- Test before committing. Run the relevant automated tests, then verify the
  actual app or script when its hardware and permission requirements are available.
  Report any checks you could not run rather than claiming live capture worked.
- Keep writing direct, personal and conversational. Use no em dashes.
- Avoid eyebrows or kickers in UI designs.
- PRs start with `## Why`, explaining what prompted the change in plain language.

## Capture app

- `Package.swift` is self-contained. Build with Swift 6+ on macOS 15+.
  Full Xcode is required for XCTest; select it with `xcode-select` or
  `DEVELOPER_DIR` when the command line tools alone lack XCTest.
- `install.sh` creates the command symlink. `setup_mac.sh` builds and signs
  `~/Applications/Meeting Archive.app`, and `restart.sh` rebuilds and opens it.
  Both refuse while the app is running, however it was started; the login item
  runs as plain `meeting-archive-app --background`, so a path match misses it.
  Finish recording and quit from the menu before rebuilding.
- Verify capture through the signed app bundle, not the SwiftPM executable.
  macOS permissions depend on app identity. Preserve the existing bundle,
  LaunchAgent and log identifiers unless explicitly migrating them.
- Preserve original meeting media and archive data. Cleanup requires a verified
  durable worker acknowledgement and the user's backup-coverage setting.
- Camera/window signals alone do not prove live support for an application.
  Zoom is preview-tested; Chrome automatic capture is blocked, and Teams/Slack
  still need live validation.
- Startup commands must exit before creating a recording controller.

## Worker

- `worker/meeting_archive_worker` has standard-library tests. Heavy model
  libraries in `worker/requirements.txt` are only needed for transcription.
- Bruce deployment scripts intentionally verify the fixed external volume UUID
  and archive path before touching queues or media. Never replace a failed
  volume check with an internal-disk fallback.
- Changes for a different installation must keep app transfer guards, worker
  wrappers, launcher path checks and their fixtures consistent.
- Credentials belong in a private owner-only file on the worker, or in the
  environment for local commands. Never print tokens or put them in argv, a
  plist or source control. `.env.example` documents local shell variables;
  `.env` is not automatically loaded by the managed service.
- Service installers stage by default; `--enable` starts them explicitly.
  Viewer/Tailscale routing remains separate. Uninstallers remove only their
  own service, retaining archive data, models, queues and credentials.
- Strong voice matches and tentative suggestions are separate. Predictions
  must not enroll themselves as confirmed profiles. Confirmed observations
  preserve meeting, revision and speaker provenance.

## Checks

Run from the repo root:

```sh
swift test
PYTHONPATH=worker python3 -W error::ResourceWarning -m unittest discover -s worker_tests
bash verification/run-contract-roundtrip.sh
bash verification/run-offline-regressions.sh
bash verification/run-rebuild-guard-tests.sh
bash diagnostics/run-tests.sh
bash worker/launcher/run-tests.sh
bash worker/vision/run-tests.sh
```

Use ffmpeg for the synthetic media checks. Keep CI offline, with no model
downloads, secrets or recording permissions. UI harnesses, live transfer and
real-media fixtures are manual verification, not CI requirements.
