import AppKit
import AVFoundation
import Combine
import MeetingArchiveCore
import Network
import UserNotifications

/// Written when a recording part starts and removed once its meeting is saved.
/// Finding one on launch means the app stopped mid-recording.
struct CaptureJournal: Codable {
    let id: UUID
    let seriesID: UUID
    let part: Int
    let trigger: RecordingTrigger
    let sourceApplication: SourceApplicationDescriptor
    let startedAt: Date
}

/// v1 journals described a camera session. Recovery only needs these fields.
private struct LegacyCaptureJournal: Decodable {
    struct Session: Decodable { let sourceApplication: SourceApplicationDescriptor }
    let id: UUID
    let session: Session
    let startedAt: Date
}

/// What the user is told about recordings. Kept apart from the controller so
/// the wording, and when it is shown, can be tested.
enum CaptureNotice {
    struct Message: Equatable {
        let title: String
        let body: String
    }

    /// Later parts of the same call carry on quietly; the menu still shows them.
    static func started(source: String, part: Int) -> Message? {
        guard part == 1 else { return nil }
        return Message(title: "Recording \(source)", body: "Stop or discard it here or from the menu bar.")
    }

    static func saved(title: String) -> Message {
        Message(title: "Saved \(title)", body: "It goes to Bruce in about a minute and a half. Discard it from the menu bar if you didn't want it.")
    }

    static func restarted(source: String) -> Message {
        Message(title: "Recording restarted", body: "Something interrupted the \(source) recording. What was recorded is saved and a new part has started.")
    }

    static func cannotStart(source: String, detail: String?) -> Message {
        Message(title: "Couldn't record \(source)", body: [detail, "Still trying while the call goes on."].compactMap { $0 }.joined(separator: " "))
    }

    static func notKept(source: String, reason: String) -> String {
        "Didn't keep the \(source) recording: \(reason)"
    }

    static func defaultTitle(source: String, startedAt: Date, part: Int) -> String {
        let title = "\(source) call \(startedAt.formatted(date: .abbreviated, time: .shortened))"
        return part > 1 ? "\(title) (part \(part))" : title
    }

    static func sourceName(_ trigger: RecordingTrigger) -> String {
        switch trigger {
        case .microphone(let user): user.displayName
        case .manual: "Manual recording"
        }
    }
}

@MainActor
final class ArchiveController: ObservableObject {
    @Published var status = "Starting…"
    @Published var failure: String?
    @Published var isRecording = false
    @Published var isPaused = false
    /// What is being recorded right now, for the menu.
    @Published private(set) var recordingSource: String?
    @Published private(set) var recordingStartedAt: Date?
    /// The app that triggered the current recording, so the menu can offer to
    /// never record it again. Nil for a manual recording.
    @Published private(set) var recordingApp: MicUser?
    /// Apps seen using the mic this session, for the ignore list in Settings.
    @Published private(set) var recentMicUsers: [MicUser] = []
    @Published var meetings: [MeetingRecord] = []
    @Published var jobs: [ArchiveJob] = []
    @Published var workerStatuses: [UUID: WorkerMeetingStatus] = [:]
    @Published var workerStatusFailure: String?
    @Published private(set) var followUpMeetingID: UUID?
    let settings = AppSettings()
    let calendar = CalendarService()
    private var store: SQLiteMeetingStore?
    private var policy = RecordingPolicy()
    private var monitor: MicActivityMonitor?
    private var timer: Task<Void, Never>?
    private var recording: AudioRecording?
    private var journal: CaptureJournal?
    /// Start and finish both await the audio engines. Chaining them keeps a
    /// stop and the next start from overlapping when the app switches.
    private var captureChain: Task<Void, Never>?
    private var lastSnapshot = MicUsageSnapshot(users: [], ignored: [], error: nil)
    private var notKeptNote: (text: String, at: Date)?
    private var announcedFailures = Set<UUID>()
    private var uploading = false
    private var lastQueuePoll = Date.distantPast
    private var lastWorkerStatusPoll = Date.distantPast
    private var cleanedMeetingIDs = Set<UUID>()
    private var lockFD: Int32 = -1
    private var followUpWindow: NamingWindow?
    private var attentionTracker = SpeakerAttentionTracker()
    private var refreshingWorkerStatuses = false
    private var workerRefreshRequested = false
    private var workerStatusFailures = 0
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied: Bool?
    private var hasPolledMicrophone = false
    private var hotKey: GlobalHotKey?
    private let transfer = ArchiveTransfer()
    private let workerStatusClient = WorkerStatusClient(cacheDuration: 10)
    private let keepPolicy = KeepPolicy()

    init(startServices: Bool = true) {
        do {
            for directory in [AppPaths.root, AppPaths.spool, AppPaths.index] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            lockFD = open(AppPaths.root.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            // Acquire before reading or restoring state. A second launch must
            // never turn the first instance's live recording into recovery.
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
            let database = try SQLiteMeetingStore(url: AppPaths.root.appendingPathComponent("meetings.sqlite"))
            store = database
            let saved = try database.loadState(RecordingPolicyState.self, key: SQLiteMeetingStore.recordingPolicyStateKey)
            policy = RecordingPolicy(restoringPersistedState: saved ?? RecordingPolicyState(), now: Date())
            try database.saveState(policy.state, key: SQLiteMeetingStore.recordingPolicyStateKey)
            try? database.checkpoint()
        } catch {
            store = nil
            policy = RecordingPolicy()
            failure = error.localizedDescription
        }
        isPaused = policy.state.isPaused
        if let data = try? Data(contentsOf: AppPaths.root.appendingPathComponent("speaker-attention.json")),
           let saved = try? JSONDecoder().decode(SpeakerAttentionTracker.self, from: data) {
            attentionTracker = saved
        }
        refresh()
        // The isolated UI verification harness uses the real controller and
        // views without polling devices, recording, uploading, or recovering.
        guard startServices else {
            hasPolledMicrophone = true
            return
        }
        monitor = MicActivityMonitor(ignoredBundleIDs: { [weak self] in
            self?.settings.ignoredBundleIDs ?? MicAppResolver.defaultIgnoredBundleIDs
        })
        NotificationRouter.shared.install { [weak self] action in
            self?.handleNotificationAction(action)
        }
        hotKey = GlobalHotKey.recordToggle { [weak self] in self?.toggleRecording() }
        adoptDefaultCalendarsIfNeeded()
        timer = Task { [weak self] in
            await self?.recoverInterruptedCaptures()
            await self?.refreshWorkerStatuses()
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connectivityRestored() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSatisfied = satisfied }
                if satisfied, self.lastPathSatisfied == false { self.connectivityRestored() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "meeting-archive.network"))
        pathMonitor = monitor
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Audio devices go away during sleep. Save this part now; if
                // the call is still going after wake, a new part starts.
                guard let self, let meetingID = self.journal?.id else { return }
                Log.controller.notice("Mac is going to sleep; saving the current part")
                self.dispatch(.captureFailed(meetingID: meetingID, at: Date()))
            }
        }
    }

    /// Retries were scheduled with exponential backoff while Bruce was out of
    /// reach. Once the network or the Mac comes back, try again straight away.
    private func connectivityRestored() {
        do {
            if try store?.makeRetryableJobsAvailable(now: Date()) ?? 0 > 0 { refresh() }
        } catch { fail(error.localizedDescription) }
        lastQueuePoll = .distantPast
        workerStatusFailures = 0
        lastWorkerStatusPoll = .distantPast
    }

    /// Picks the signed-in account calendars once, so title suggestions work
    /// without a trip to Settings. Later changes in Settings are respected.
    private func adoptDefaultCalendarsIfNeeded() {
        guard settings.selectedCalendarIDs.isEmpty else { return }
        calendar.reload()
        let ids = calendar.defaultCalendarIDs()
        guard !ids.isEmpty else { return }
        settings.selectedCalendarIDs = ids
        Log.controller.notice("Selected \(ids.count, privacy: .public) account calendars for title suggestions")
    }

    func refresh() {
        do {
            meetings = try store?.listMeetings().sorted { $0.startedAt > $1.startedAt } ?? []
            jobs = try store?.listJobs() ?? []
        } catch { fail(error.localizedDescription) }
    }

    // MARK: - Recording

    private func tick() {
        guard store != nil, let monitor else { return }
        let now = Date()
        let snapshot = monitor.snapshot()
        lastSnapshot = snapshot
        hasPolledMicrophone = true
        rememberMicUsers(snapshot.users + snapshot.ignored)
        if let error = snapshot.error {
            // An unreadable second says nothing about who holds the mic, so it
            // must not count towards an app letting go.
            Log.detector.error("Mic check failed: \(error, privacy: .public)")
        } else {
            dispatch(.tick(micUsers: snapshot.users, at: now))
        }
        recording?.checkHealth()
        updateStatus(now: now)
        for meeting in meetings {
            if case .pending(let deadline) = meeting.acceptance, now >= deadline {
                resolve(meeting.id, resolution: .accept(trigger: .deadline))
            }
        }
        if !uploading, now.timeIntervalSince(lastQueuePoll) >= 15 {
            lastQueuePoll = now
            Task { await uploadNext() }
        }
        let statusInterval = WorkerStatusPolling.interval(hasBusyMeetings: !processingMeetings.isEmpty, consecutiveFailures: workerStatusFailures)
        if now.timeIntervalSince(lastWorkerStatusPoll) >= statusInterval {
            lastWorkerStatusPoll = now
            Task { await refreshWorkerStatuses() }
        }
        presentReadySpeakerReview()
    }

    private func updateStatus(now: Date) {
        if let source = recordingSource {
            status = "Recording \(source)"
        } else if failure != nil {
            status = "Needs attention"
        } else if let note = notKeptNote, now.timeIntervalSince(note.at) < 120 {
            status = note.text
        } else if isPaused {
            status = "Paused"
        } else if let ignored = lastSnapshot.ignored.first, lastSnapshot.users.isEmpty {
            status = "Not recording \(ignored.displayName)"
        } else {
            status = "Listening for calls"
        }
    }

    private func rememberMicUsers(_ users: [MicUser]) {
        for user in users where !recentMicUsers.contains(user) {
            recentMicUsers.insert(user, at: 0)
        }
        if recentMicUsers.count > 12 { recentMicUsers.removeLast(recentMicUsers.count - 12) }
    }

    private func dispatch(_ event: RecordingEvent) {
        // A stop clears the active recording, so note its trigger first. A
        // recording pinned by Record now ends as a manual one.
        let before = policy.state.active
        let effects = policy.handle(event)
        if !effects.isEmpty {
            Log.controller.notice("\(String(describing: event), privacy: .public) -> \(String(describing: effects), privacy: .public)")
        }
        do { try store?.saveState(policy.state, key: SQLiteMeetingStore.recordingPolicyStateKey) } catch { fail(error.localizedDescription) }
        isPaused = policy.state.isPaused
        for effect in effects {
            switch effect {
            case .startCapture(let meetingID, let trigger, let seriesID, let part):
                enqueueCapture { await self.start(meetingID: meetingID, trigger: trigger, seriesID: seriesID, part: part) }
            case .stopCapture(let meetingID, let reason):
                let trigger = before?.meetingID == meetingID ? before?.trigger : nil
                enqueueCapture { await self.finish(meetingID: meetingID, reason: reason, finalTrigger: trigger) }
            }
        }
    }

    private func enqueueCapture(_ operation: @escaping @MainActor () async -> Void) {
        let previous = captureChain
        captureChain = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    func recordNow() { dispatch(.manualStart(at: Date())) }
    func stopRecording() { dispatch(.manualStop(at: Date())) }
    func discardCurrentRecording() { dispatch(.discardCurrent(at: Date())) }
    func togglePause() { dispatch(.setPaused(!isPaused, at: Date())) }

    func toggleRecording() {
        if policy.state.active != nil { stopRecording() } else { recordNow() }
    }

    /// Discards what is being recorded and keeps that app from starting one again.
    func neverRecord(_ user: MicUser) {
        settings.ignore(user.bundleIdentifier)
        if recordingApp == user { discardCurrentRecording() }
    }

    // A menu item is one slip away from a real meeting, so these ask first.

    func confirmDiscardCurrentRecording() {
        guard confirm("Discard this recording?", detail: "What has been recorded so far is deleted from this Mac and never sent to Bruce.", button: "Discard") else { return }
        discardCurrentRecording()
    }

    func confirmNeverRecord(_ user: MicUser) {
        guard confirm("Never record \(user.displayName)?", detail: "This recording is discarded, and \(user.displayName) using the mic won't start one again. You can change this in Settings.", button: "Never record") else { return }
        neverRecord(user)
    }

    func confirmDiscardSaved(_ id: UUID) {
        guard let record = meetings.first(where: { $0.id == id }), record.acceptance.isPending else { return }
        guard confirm("Discard \u{201C}\(record.title)\u{201D}?", detail: "The recording is deleted from this Mac and never sent to Bruce.", button: "Discard") else { return }
        resolve(id, resolution: .discard)
    }

    private func confirm(_ message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func start(meetingID: UUID, trigger: RecordingTrigger, seriesID: UUID, part: Int) async {
        guard policy.state.active?.meetingID == meetingID else { return }
        guard recording == nil, journal == nil else {
            Log.controller.error("A recording was still open when the next one started")
            return
        }
        let source = sourceDescriptor(for: trigger)
        let entry = CaptureJournal(id: meetingID, seriesID: seriesID, part: part, trigger: trigger, sourceApplication: source, startedAt: Date())
        let directory = AppPaths.meeting(meetingID)
        let audio = AudioRecording()
        do {
            let capacity = try AppPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity > 1024 * 1024 * 1024 else { throw CaptureFailure.message("Less than 1 GB is free, so recording is on hold to keep existing meetings safe.") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try ModelCodec.encoder.encode(entry).write(to: directory.appendingPathComponent("capture-journal.json"), options: .atomic)
            recording = audio
            journal = entry
            audio.onFailure = { [weak self] message in
                Task { @MainActor in self?.captureFailed(meetingID: meetingID, message: message) }
            }
            audio.onWarning = { message in
                Log.capture.notice("\(message, privacy: .public)")
            }
            try await audio.start(directory: directory)
        } catch {
            Log.capture.error("Recording did not start: \(error.localizedDescription, privacy: .public)")
            if recording === audio {
                recording = nil
                journal = nil
            }
            removeJournalOnlyDirectory(directory)
            if !announcedFailures.contains(seriesID) {
                announcedFailures.insert(seriesID)
                let message = CaptureNotice.cannotStart(source: source.displayName, detail: error.localizedDescription)
                notify(message.title, body: message.body, id: seriesID.uuidString + "-start-failed")
            }
            dispatch(.captureFailed(meetingID: meetingID, at: Date()))
            return
        }
        guard recording === audio else { return }
        isRecording = true
        recordingSource = source.displayName
        recordingStartedAt = entry.startedAt
        if case .microphone(let user) = trigger { recordingApp = user } else { recordingApp = nil }
        dispatch(.captureStarted(meetingID: meetingID, at: Date()))
        if let message = CaptureNotice.started(source: source.displayName, part: part) {
            notify(message.title, body: message.body, id: meetingID.uuidString + "-start", category: NotificationRouter.recordingCategory)
        }
    }

    private func captureFailed(meetingID: UUID, message: String) {
        guard let entry = journal, entry.id == meetingID else { return }
        Log.capture.error("Recording interrupted: \(message, privacy: .public)")
        if !announcedFailures.contains(entry.seriesID) {
            announcedFailures.insert(entry.seriesID)
            let notice = CaptureNotice.restarted(source: entry.sourceApplication.displayName)
            notify(notice.title, body: notice.body, id: entry.seriesID.uuidString + "-restarted")
        }
        dispatch(.captureFailed(meetingID: meetingID, at: Date()))
    }

    private func finish(meetingID: UUID, reason: RecordingStopReason, finalTrigger: RecordingTrigger?) async {
        guard let audio = recording, let entry = journal, entry.id == meetingID else { return }
        let ended = Date()
        let result = await audio.stop()
        recording = nil
        journal = nil
        isRecording = false
        recordingSource = nil
        recordingStartedAt = nil
        recordingApp = nil
        let directory = AppPaths.meeting(entry.id)
        if let error = result.error { Log.capture.error("Recording ended with: \(error.localizedDescription, privacy: .public)") }
        let decision = keepPolicy.decide(
            trigger: finalTrigger ?? entry.trigger,
            stopReason: reason,
            part: entry.part,
            duration: ended.timeIntervalSince(entry.startedAt),
            incomingActivity: result.activitySeconds["incoming"] ?? 0,
            microphoneActivity: result.activitySeconds["microphone"] ?? 0
        )
        if case .discard(let why) = decision {
            try? FileManager.default.removeItem(at: directory)
            Log.controller.notice("Not keeping \(entry.id.uuidString, privacy: .public): \(why, privacy: .public)")
            if reason != .discarded {
                notKeptNote = (CaptureNotice.notKept(source: entry.sourceApplication.displayName, reason: why), Date())
            }
            refresh()
            return
        }
        do {
            try ModelCodec.encoder.encode(result.tracks).write(to: directory.appendingPathComponent("tracks.json"), options: .atomic)
            var meeting = makeRecord(entry, ended: ended, microphone: result.microphone)
            adoptDefaultCalendarsIfNeeded()
            let events = calendar.suggestions(start: entry.startedAt, end: ended, selectedCalendarIDs: settings.selectedCalendarIDs)
            if let match = CalendarRanking.best(events, start: entry.startedAt, end: ended) {
                meeting.title = entry.part > 1 ? "\(match.title) (part \(entry.part))" : match.title
            }
            try ModelCodec.encoder.encode(events).write(to: directory.appendingPathComponent("calendar.json"), options: .atomic)
            try store?.insertMeeting(meeting)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("capture-journal.json"))
            if reason != .appQuit {
                let notice = CaptureNotice.saved(title: meeting.title)
                notify(notice.title, body: notice.body, id: entry.id.uuidString + "-finish", category: NotificationRouter.savedCategory, meetingID: entry.id)
            }
        } catch { fail(error.localizedDescription) }
        refresh()
    }

    private func sourceDescriptor(for trigger: RecordingTrigger) -> SourceApplicationDescriptor {
        switch trigger {
        case .microphone(let user):
            SourceApplicationDescriptor(bundleIdentifier: user.bundleIdentifier, displayName: user.displayName, kind: .forBundleIdentifier(user.bundleIdentifier))
        case .manual:
            SourceApplicationDescriptor(bundleIdentifier: "manual", displayName: CaptureNotice.sourceName(.manual), kind: .other)
        }
    }

    private func makeRecord(_ entry: CaptureJournal, ended: Date, microphone: CapturedMicrophone?) -> MeetingRecord {
        MeetingRecord(
            id: entry.id,
            title: CaptureNotice.defaultTitle(source: entry.sourceApplication.displayName, startedAt: entry.startedAt, part: entry.part),
            sourceApplication: entry.sourceApplication,
            startedAt: entry.startedAt,
            endedAt: ended,
            timezoneIdentifier: TimeZone.current.identifier,
            microphone: .init(deviceUID: microphone?.uid ?? "system-default", displayName: microphone?.name ?? "System default microphone", sampleRate: 48_000, channels: 1),
            incomingAudio: .init(sourceApplicationBundleIdentifier: entry.sourceApplication.bundleIdentifier, sampleRate: 48_000, channels: 2),
            finalizedAt: Date()
        )
    }

    private func removeJournalOnlyDirectory(_ directory: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
            guard try contents.allSatisfy({ url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return url.lastPathComponent == "capture-journal.json"
                    && values.isRegularFile == true
                    && values.isSymbolicLink != true
            }) else { return }
            try FileManager.default.removeItem(at: directory)
        } catch {
            // Retain anything unexpected for recovery rather than risk
            // deleting real media.
        }
    }

    private func recoverInterruptedCaptures() async {
        var issues: [String] = []
        do {
            for directory in try FileManager.default.contentsOfDirectory(at: AppPaths.spool, includingPropertiesForKeys: nil) {
                do {
                    let path = directory.appendingPathComponent("capture-journal.json")
                    guard let data = try? Data(contentsOf: path) else { continue }
                    let entry = try Self.decodeJournal(data)
                    guard try store?.fetchMeeting(id: entry.id) == nil else { continue }
                    let media = try SpoolBundle.mediaFiles(in: directory)
                    var duration = 0.0
                    for (url, _) in media {
                        let value = try await AVURLAsset(url: url).load(.duration).seconds
                        if value.isFinite { duration = max(duration, value) }
                    }
                    guard duration > 0 else {
                        // Nothing reached a file before the app stopped.
                        removeJournalOnlyDirectory(directory)
                        if FileManager.default.fileExists(atPath: directory.path) {
                            throw CaptureFailure.message("An interrupted recording needs a look: \(entry.id)")
                        }
                        continue
                    }
                    let record = makeRecord(entry, ended: entry.startedAt.addingTimeInterval(duration), microphone: nil)
                    try store?.insertMeeting(record)
                    resolve(record.id, resolution: .accept(trigger: .restartRecovery))
                    try FileManager.default.removeItem(at: path)
                } catch {
                    // One damaged recording must never hold up the others.
                    issues.append("\(directory.lastPathComponent): \(error.localizedDescription)")
                }
            }
            refresh()
        } catch { issues.append(error.localizedDescription) }
        if !issues.isEmpty { fail("Interrupted recordings were kept for recovery: " + issues.prefix(3).joined(separator: "; ")) }
    }

    private static func decodeJournal(_ data: Data) throws -> CaptureJournal {
        if let entry = try? ModelCodec.decoder.decode(CaptureJournal.self, from: data) { return entry }
        let legacy = try ModelCodec.decoder.decode(LegacyCaptureJournal.self, from: data)
        return CaptureJournal(id: legacy.id, seriesID: legacy.id, part: 1, trigger: .manual, sourceApplication: legacy.session.sourceApplication, startedAt: legacy.startedAt)
    }

    // MARK: - Saving and archiving

    /// Meetings saved in the last minute and a half, which can still be
    /// discarded before they go to Bruce.
    var pendingMeetings: [MeetingRecord] {
        meetings.filter(\.acceptance.isPending)
    }

    func resolve(_ id: UUID, resolution: AcceptanceResolution) {
        do {
            guard let record = try store?.fetchMeeting(id: id), record.acceptance.isPending else { return }
            let job = ArchiveJob(meetingID: id, manifestRevision: record.metadataRevision, createdAt: Date())
            _ = try store?.resolveAcceptanceAndEnqueue(id: id, resolution: resolution, at: Date(), job: job)
            if case .discard = resolution { try FileManager.default.removeItem(at: AppPaths.meeting(id)) }
            refresh()
            if case .accept = resolution { Task { await uploadNext() } }
        } catch { fail(error.localizedDescription) }
    }

    /// A meeting can be renamed before it is sent, or once Bruce has it. In
    /// between, the upload has already taken the title it had.
    func canRename(_ record: MeetingRecord) -> Bool {
        record.acceptance.isPending
            || jobs.contains { $0.meetingID == record.id && $0.status == .succeeded && $0.acknowledgement != nil }
    }

    /// A capture that can never be archived keeps its folder in the spool, and
    /// its job stays failed rather than retrying.
    func cannotArchive(_ record: MeetingRecord) -> Bool {
        jobs.contains { $0.meetingID == record.id && $0.status == .failed }
    }

    func rename(_ meetingID: UUID, to rawTitle: String) async -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var record = meetings.first(where: { $0.id == meetingID }) else { return false }
        do {
            if record.acceptance.isPending {
                // Not uploaded yet, so the new title travels with the upload.
                record = record.updatingTitle(title, at: Date())
                try store?.updateMeeting(record)
            } else {
                let saved = try await workerStatusClient.rename(meetingID: meetingID, title: title, configuration: transferConfiguration)
                record = record.renamingArchived(saved, at: Date())
                try store?.updateMeeting(record)
            }
            refresh()
            followUpWindow?.title = record.title
            return true
        } catch {
            fail("Could not rename the meeting. \(error.localizedDescription)")
            return false
        }
    }

    func searchTranscripts(_ query: String) async throws -> [WorkerSearchResult] {
        try await workerStatusClient.search(query: query, configuration: transferConfiguration)
    }

    func retryWorker(_ meetingID: UUID) {
        Task {
            do {
                _ = try await workerStatusClient.retry(
                    meetingID: meetingID,
                    configuration: transferConfiguration
                )
                await refreshWorkerStatuses(force: true)
            } catch {
                workerStatusFailure = error.localizedDescription
            }
        }
    }

    func refreshWorkerStatuses(force: Bool = false) async {
        guard !refreshingWorkerStatuses else {
            workerRefreshRequested = workerRefreshRequested || force
            return
        }
        refreshingWorkerStatuses = true
        defer {
            refreshingWorkerStatuses = false
            if workerRefreshRequested {
                workerRefreshRequested = false
                Task { await refreshWorkerStatuses(force: true) }
            }
        }
        lastWorkerStatusPoll = Date()
        var archivedIDs = meetings
            .filter { meeting in
                self.jobs.contains { job in
                    job.meetingID == meeting.id
                        && job.status == .succeeded
                        && job.acknowledgement != nil
                }
            }
            // Routine polls skip meetings whose Bruce state can no longer
            // change on its own; a forced refresh still covers everything.
            .filter { force || !WorkerStatusPolling.isSettled(self.workerStatuses[$0.id], revision: $0.metadataRevision) }
            .map(\.id)
        // Opening an older recording must still fetch its review, even when
        // the routine recent-history batch is full.
        if let focused = followUpMeetingID, archivedIDs.contains(focused) {
            archivedIDs.removeAll { $0 == focused }
            archivedIDs.insert(focused, at: 0)
        }
        guard !archivedIDs.isEmpty else { return }
        do {
            let fetched = try await workerStatusClient.fetch(
                meetingIDs: Array(archivedIDs.prefix(100)),
                configuration: transferConfiguration,
                force: force
            )
            workerStatuses.merge(fetched) { _, fresh in fresh }
            workerStatusFailure = nil
            workerStatusFailures = 0
            presentReadySpeakerReview()
        } catch {
            workerStatusFailure = error.localizedDescription
            workerStatusFailures += 1
        }
    }

    func followUpPhase(for record: MeetingRecord) -> MeetingFollowUpPhase {
        guard let job = jobs.first(where: { $0.meetingID == record.id && $0.manifestRevision == record.metadataRevision }) else {
            return .checking
        }
        if job.status == .failed { return .notArchived(reason: job.lastError) }
        if let error = job.lastError, job.status != .succeeded { return .waiting("Transfer waiting to retry: \(error)") }
        guard job.status == .succeeded else { return .transferring }
        let remote = workerStatuses[record.id]
        return .afterArchive(
            expectedRevision: record.metadataRevision, workerRevision: remote?.manifestRevision,
            processingSucceeded: remote?.processingState == .succeeded,
            remainingNames: remote?.unconfirmedSpeakerCount,
            processingError: remote?.retryStage == .processing ? remote?.detail : nil,
            connectionError: workerStatusFailure
        )
    }

    var processingMeetings: [MeetingRecord] {
        meetings.filter { record in
            guard case .accepted = record.acceptance else { return false }
            return followUpPhase(for: record).isBusy
        }
    }

    var speakerAttentionCandidates: [SpeakerAttentionCandidate] {
        meetings.compactMap { record in
            guard case .accepted = record.acceptance,
                  let remote = workerStatuses[record.id],
                  remote.manifestRevision == record.metadataRevision,
                  remote.processingState == .succeeded,
                  let count = remote.unconfirmedSpeakerCount, count > 0 else { return nil }
            return SpeakerAttentionCandidate(meetingID: record.id, revision: record.metadataRevision, remainingCount: count)
        }
    }

    var meetingsNeedingSpeakerNames: [MeetingRecord] {
        let ids = Set(speakerAttentionCandidates.map(\.meetingID))
        return meetings.filter { ids.contains($0.id) }
    }

    var speakersNeedingNames: Int { speakerAttentionCandidates.reduce(0) { $0 + $1.remainingCount } }

    /// `activate` is for explicit clicks. Automatic presentation orders the
    /// window in without taking keyboard focus from whatever the user is doing.
    func showFollowUp(_ id: UUID, refreshStatus: Bool = true, activate: Bool = true) {
        guard let record = meetings.first(where: { $0.id == id }) else { return }
        if followUpMeetingID != id {
            closeFollowUp()
            followUpMeetingID = id
            let panel = NamingWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.title = record.title
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: MeetingFollowUpView(controller: self, meetingID: id))
            panel.onClose = { [weak self] in
                self?.followUpMeetingID = nil
                self?.followUpWindow = nil
            }
            panel.center()
            followUpWindow = panel
        }
        if let candidate = speakerAttentionCandidates.first(where: { $0.meetingID == id }) {
            markSpeakerAttentionPresented(candidate)
        }
        if activate {
            followUpWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            followUpWindow?.orderFrontRegardless()
        }
        if refreshStatus, jobs.contains(where: { $0.meetingID == id && $0.status == .succeeded && $0.acknowledgement != nil }) {
            Task { await refreshWorkerStatuses(force: true) }
        }
    }

    func closeFollowUp() { followUpWindow?.close() }

    func speakerReviewChanged() { Task { await refreshWorkerStatuses(force: true) } }

    private func presentReadySpeakerReview() {
        // Never put a window up while a call is going on, recorded or not.
        // The menu indicator stays available.
        let callInProgress = !hasPolledMicrophone || isRecording || recording != nil || !lastSnapshot.users.isEmpty
        let blocked = !SpeakerAttentionTracker.interactionIsSafe(callInProgress: callInProgress)
        let candidates = speakerAttentionCandidates.filter { followUpMeetingID == nil || $0.meetingID == followUpMeetingID }
        guard let candidate = attentionTracker.nextPresentation(from: candidates, interactionBlocked: blocked) else { return }
        showFollowUp(candidate.meetingID, activate: false)
    }

    private func markSpeakerAttentionPresented(_ candidate: SpeakerAttentionCandidate) {
        attentionTracker.markPresented(candidate)
        do {
            try JSONEncoder().encode(attentionTracker).write(to: AppPaths.root.appendingPathComponent("speaker-attention.json"), options: .atomic)
        } catch { fail("Could not save speaker prompt state: \(error.localizedDescription)") }
    }

    private func uploadNext() async {
        guard !uploading else { return }
        uploading = true
        defer { uploading = false }
        // Implemented through ArchiveTransfer's verified acknowledgement.
        await transferQueuedMeeting()
        await cleanupVerifiedMedia()
    }

    var transferConfiguration: ArchiveTransferConfiguration {
        var configuration = ArchiveTransferConfiguration.bruce
        configuration.host = settings.archiveHost
        configuration.archiveRoot = settings.archiveRoot + "/meetings"
        configuration.incomingRoot = settings.archiveRoot + "/incoming"
        configuration.workerDatabase = settings.archiveRoot + "/worker.sqlite"
        configuration.workerPython = settings.archiveRoot + "/runtime/venv/bin/python3"
        configuration.workerScript = settings.archiveRoot + "/runtime/worker/worker.py"
        return configuration
    }

    private func transferQueuedMeeting() async {
        var claimed: ArchiveJob?
        do {
            // This exceeds the transfer + verify timeouts. Only this actor starts
            // uploads; after a crash the lease becomes available again.
            guard let job = try store?.claimNextJob(now: Date(), leaseDuration: 15_000),
                  let record = try store?.fetchMeeting(id: job.meetingID) else { return }
            claimed = job
            let source = AppPaths.meeting(record.id)
            let manifest = try await Task.detached(priority: .utility) { try SpoolBundle.prepare(record: record, directory: source) }.value
            let acknowledgement = try await transfer.upload(sourceDirectory: source, manifest: manifest, configuration: transferConfiguration)
            try store?.acknowledgeJob(id: job.id, acknowledgement: acknowledgement)
            try? store?.checkpoint()
        } catch {
            Log.transfer.error("Upload failed: \(error.localizedDescription, privacy: .public)")
            if let claimed {
                switch UploadFailure(error, attempt: claimed.attemptCount) {
                case .retry(let delay):
                    try? store?.scheduleRetry(jobID: claimed.id, availableAt: Date().addingTimeInterval(delay), error: error.localizedDescription)
                case .permanent(let reason):
                    // No retry can add media the capture never recorded. Its
                    // folder stays in the spool, and cleanup never touches it.
                    try? store?.failJob(id: claimed.id, error: reason)
                }
            }
        }
        refresh()
        if claimed != nil { await refreshWorkerStatuses(force: true) }
    }

    private func cleanupVerifiedMedia() async {
        guard settings.backupCoverageVerified else { return }
        for job in jobs where job.status == .succeeded {
            guard !cleanedMeetingIDs.contains(job.meetingID) else { continue }
            guard let acknowledgement = job.acknowledgement else { continue }
            let source = AppPaths.meeting(job.meetingID)
            let index = AppPaths.index.appendingPathComponent(job.meetingID.uuidString.lowercased())
            if FileManager.default.fileExists(atPath: index.appendingPathComponent("cleanup-complete.json").path) {
                cleanedMeetingIDs.insert(job.meetingID)
                continue
            }
            do {
                try await Task.detached(priority: .utility) {
                    try ArchiveCleanup.perform(source: source, index: index, acknowledgement: acknowledgement)
                }.value
                cleanedMeetingIDs.insert(job.meetingID)
            } catch { fail("The verified archive is safe on Bruce, but local cleanup needs attention. \(error.localizedDescription)") }
        }
    }

    /// Opens the meeting in Bruce's viewer: streamed playback plus a transcript
    /// with seek buttons. Downloading the transcript stays available as a
    /// fallback when the viewer is unreachable.
    func openInViewer(_ id: UUID) {
        let base = settings.viewerURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(base)/meeting/\(id.uuidString.lowercased())") else {
            fail("The viewer address in Settings is not a valid URL.")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openTranscript(_ id: UUID) {
        let revision = meetings.first(where: { $0.id == id })?.metadataRevision ?? 1
        retrieve(id, relativePath: "transcripts/v\(revision)/transcript.md", localName: "transcript.md")
    }

    private func retrieve(_ id: UUID, relativePath: String, localName: String) {
        Task {
            do {
                let destination = AppPaths.index.appendingPathComponent(id.uuidString.lowercased()).appendingPathComponent(localName)
                let url = try await transfer.fetch(relativePath: relativePath, meetingID: id, destination: destination, configuration: transferConfiguration)
                NSWorkspace.shared.open(url)
            } catch { fail("The archive item is not ready or Bruce is unavailable. \(error.localizedDescription)") }
        }
    }

    // MARK: - Notifications

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func notify(_ title: String, body: String, id: String, category: String? = nil, meetingID: UUID? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        if let meetingID { content.userInfo = ["meetingID": meetingID.uuidString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func handleNotificationAction(_ action: NotificationRouter.Action) {
        switch action {
        case .stopRecording:
            if isRecording { stopRecording() }
        case .discardRecording:
            if isRecording { discardCurrentRecording() }
        case .discardSaved(let meetingID):
            resolve(meetingID, resolution: .discard)
        }
    }

    func clearFailure() {
        failure = nil
        updateStatus(now: Date())
    }

    func fail(_ message: String) {
        Log.controller.error("\(message, privacy: .public)")
        failure = message
        status = "Needs attention"
    }

    func quit() async {
        timer?.cancel()
        if let meetingID = journal?.id {
            // Saved as is. If the call is still going when the app comes
            // back, the next part starts on its own.
            let trigger = policy.state.active?.trigger
            await captureChain?.value
            await finish(meetingID: meetingID, reason: .appQuit, finalTrigger: trigger)
        }
        pathMonitor?.cancel()
        try? store?.checkpoint()
        NSApp.terminate(nil)
    }
}

import SwiftUI

@MainActor
final class NamingWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() { let action = onClose; onClose = nil; action?(); super.close() }
}
