# Meeting Archive passive diagnostic

This is a standalone feasibility tool for the Meeting Archive plan. It observes
device-level camera state and ScreenCaptureKit application/window metadata. It
does not open a camera, request permissions, create an `SCStream`, capture
pixels/audio, or infer which process owns a camera.

## Build and test

The scripts use `xcrun` to find the selected Swift compiler and matching
macOS SDK. Set `DEVELOPER_DIR` to choose a different Xcode or Command Line
Tools installation, and `SDKROOT` only if you need a specific compatible SDK.

```sh
diagnostics/run-tests.sh
diagnostics/build.sh
```

The binary is written to:

```text
diagnostics/.build/meeting-archive-diagnostic
```

## Commands

Each command writes one JSON object per line with an ISO-8601 timestamp and an
explicit evidence boundary.

```sh
# Device metadata and passive activity state only
diagnostics/.build/meeting-archive-diagnostic camera

# One combined camera/window snapshot
diagnostics/.build/meeting-archive-diagnostic snapshot

# Supported application windows only
diagnostics/.build/meeting-archive-diagnostic inventory

# Include every shareable window for rule development
diagnostics/.build/meeting-archive-diagnostic inventory --all-windows

# Bounded polling, emitting initial state plus changes
diagnostics/.build/meeting-archive-diagnostic watch --samples 120 --interval 0.5
```

`watch` is always bounded to 1 through 3,600 polls. Add `--emit-unchanged` when
a periodic heartbeat is useful.

The inventory path first calls `CGPreflightScreenCaptureAccess()`. If permission
is absent, it reports that fact and returns without calling ScreenCaptureKit,
so the diagnostic never creates a permission prompt itself.

## Evidence model

Camera evidence comes from two system properties:

- `AVCaptureDevice.isInUseByAnotherApplication`
- CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere`

Both are device-level signals. CoreMediaIO says only that a device is running
in at least one process. Neither property returns the consuming process. The
diagnostic therefore records camera and window observations independently.

Window candidates require an exact known bundle identifier. Titles add only a
heuristic classification:

- Chrome: a title containing `Google Meet` or `meet.google.com`
- Zoom: `Zoom Meeting` or `Zoom Webinar`, with preview/settings titles excluded
- Teams: a non-generic title containing `meeting` or `call`
- Slack: a title containing `huddle` or `call`

Every candidate has `safeForAutomaticTrigger: false`. A future production
adapter must separately prove joined-call state and the local outgoing-camera
state. Window metadata alone cannot distinguish Meet pre-join, browser camera
test pages, Zoom preview, or all application-specific variants.
