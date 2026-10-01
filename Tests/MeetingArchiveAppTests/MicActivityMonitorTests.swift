import CoreAudio
import Foundation
import MeetingArchiveCore
import XCTest
@testable import MeetingArchiveApp

@MainActor
final class MicActivityMonitorTests: XCTestCase {
    private let zoom = MicUser(bundleIdentifier: "us.zoom.xos", displayName: "zoom.us")
    private let chrome = MicUser(bundleIdentifier: "com.google.Chrome", displayName: "Google Chrome")
    private let slack = MicUser(bundleIdentifier: "com.tinyspeck.slackmacgap", displayName: "Slack")
    private let claude = MicUser(bundleIdentifier: "com.anthropic.claudefordesktop", displayName: "Claude")
    private let ownPID: pid_t = 999

    // MARK: Who holds the mic

    func testOurOwnProcessIsLeftOut() {
        let reader = FakeAudioInputReader(processes: [process(ownPID, "com.mikerosoft.meeting-archive"), process(10, zoom)])
        let monitor = makeMonitor(reader)

        XCTAssertEqual(monitor.snapshot(), MicUsageSnapshot(users: [zoom], ignored: [], error: nil))
    }

    func testHelpersOfOneAppBecomeOneUser() {
        let reader = FakeAudioInputReader(processes: [
            process(10, "com.google.Chrome.helper"),
            process(11, "com.google.Chrome.helper"),
            process(12, chrome),
        ])

        XCTAssertEqual(makeMonitor(reader).snapshot().users, [chrome])
    }

    func testProcessesWithNoOwningAppAreLeftOut() {
        let reader = FakeAudioInputReader(processes: [process(10, nil), process(11, zoom)])

        XCTAssertEqual(makeMonitor(reader).snapshot().users, [zoom])
    }

    func testUsersStayInTheOrderTheyTookTheMic() {
        let reader = FakeAudioInputReader(processes: [process(20, zoom)])
        let monitor = makeMonitor(reader)
        XCTAssertEqual(monitor.snapshot().users, [zoom])

        // Core Audio lists Chrome first, but Zoom had the mic first.
        reader.processes = [process(10, chrome), process(20, zoom)]
        XCTAssertEqual(monitor.snapshot().users, [zoom, chrome])
        reader.processes = [process(30, slack), process(10, chrome), process(20, zoom)]
        XCTAssertEqual(monitor.snapshot().users, [zoom, chrome, slack])
    }

    func testAnAppThatLetsGoAndComesBackJoinsAtTheEnd() {
        let reader = FakeAudioInputReader(processes: [process(20, zoom), process(10, chrome)])
        let monitor = makeMonitor(reader)
        XCTAssertEqual(monitor.snapshot().users, [zoom, chrome])

        reader.processes = [process(10, chrome)]
        XCTAssertEqual(monitor.snapshot().users, [chrome])
        reader.processes = [process(20, zoom), process(10, chrome)]
        XCTAssertEqual(monitor.snapshot().users, [chrome, zoom])
    }

    func testIgnoredAppsAreSplitOutWhateverTheirCase() {
        let reader = FakeAudioInputReader(processes: [process(10, claude), process(11, zoom), process(12, chrome)])
        let monitor = makeMonitor(reader, ignoring: ["COM.ANTHROPIC.CLAUDEFORDESKTOP", "com.google.chrome"])

        XCTAssertEqual(monitor.snapshot(), MicUsageSnapshot(users: [zoom], ignored: [claude, chrome], error: nil))
    }

    func testTheIgnoreListIsReadOnEverySnapshot() {
        let reader = FakeAudioInputReader(processes: [process(10, zoom)])
        let settings = IgnoreSetting()
        let monitor = MicActivityMonitor(
            ignoredBundleIDs: { settings.bundleIDs },
            ownPID: ownPID,
            reader: reader,
            resolve: resolve
        )
        XCTAssertEqual(monitor.snapshot().users, [zoom])

        settings.bundleIDs = [zoom.bundleIdentifier]
        XCTAssertEqual(monitor.snapshot(), MicUsageSnapshot(users: [], ignored: [zoom], error: nil))
    }

    func testAReadErrorIsReportedAndTheNextPollScansAgain() {
        let reader = FakeAudioInputReader(deviceRunning: false)
        let monitor = makeMonitor(reader)
        _ = monitor.snapshot()
        reader.deviceRunning = true
        reader.error = CoreAudioReadError(selector: kAudioHardwarePropertyProcessObjectList, status: -50)

        let failed = monitor.snapshot()
        XCTAssertEqual(failed.users, [])
        XCTAssertEqual(failed.error, "Couldn't read 'prs#' from Core Audio (-50)")

        reader.deviceRunning = false
        reader.error = nil
        reader.processes = [process(10, zoom)]
        let scansBefore = reader.scans
        XCTAssertEqual(monitor.snapshot(), MicUsageSnapshot(users: [zoom], ignored: [], error: nil))
        XCTAssertEqual(reader.scans, scansBefore + 1)
    }

    // MARK: When it scans

    func testAnIdleMicOnlyChecksTheDevicesBetweenFullScans() {
        let reader = FakeAudioInputReader(deviceRunning: false)
        let monitor = makeMonitor(reader)

        for _ in 1...11 { XCTAssertEqual(monitor.snapshot(), MicUsageSnapshot(users: [], ignored: [], error: nil)) }
        // The first poll and every fifth after it scan; the rest only check the devices.
        XCTAssertEqual(reader.scans, 3)
        XCTAssertEqual(reader.deviceChecks, 8)
    }

    func testARunningInputDeviceScansStraightAway() {
        let reader = FakeAudioInputReader(deviceRunning: false)
        let monitor = makeMonitor(reader)
        _ = monitor.snapshot()
        _ = monitor.snapshot()
        XCTAssertEqual(reader.scans, 1)

        reader.deviceRunning = true
        reader.processes = [process(10, zoom)]
        XCTAssertEqual(monitor.snapshot().users, [zoom])
        XCTAssertEqual(reader.scans, 2)
    }

    func testDevicesThatCannotBeReadAreTreatedAsRunning() {
        let reader = FakeAudioInputReader(deviceRunning: nil)
        let monitor = makeMonitor(reader)

        for _ in 1...3 { _ = monitor.snapshot() }
        XCTAssertEqual(reader.scans, 3)
    }

    func testEveryPollScansWhileAnAppHoldsTheMicEvenIfNoDeviceSaysSo() {
        // Bluetooth mics reportedly never say they are running.
        let reader = FakeAudioInputReader(deviceRunning: false)
        let monitor = makeMonitor(reader)
        _ = monitor.snapshot()

        reader.processes = [process(10, zoom)]
        for _ in 1...4 { XCTAssertEqual(monitor.snapshot().users, []) }
        XCTAssertEqual(monitor.snapshot().users, [zoom], "the next full scan finds the call")
        for _ in 1...10 { XCTAssertEqual(monitor.snapshot().users, [zoom]) }
        XCTAssertEqual(reader.scans, 12)

        reader.processes = []
        XCTAssertEqual(monitor.snapshot().users, [])
        _ = monitor.snapshot()
        XCTAssertEqual(reader.scans, 13, "with nobody on the mic, it goes back to checking the devices")
    }

    func testAnIgnoredAppOnTheMicStillKeepsTheScansComing() {
        let reader = FakeAudioInputReader(deviceRunning: false, processes: [process(10, claude)])
        let monitor = makeMonitor(reader, ignoring: [claude.bundleIdentifier])

        for _ in 1...4 { XCTAssertEqual(monitor.snapshot().ignored, [claude]) }
        XCTAssertEqual(reader.scans, 4)
    }

    // MARK: Core Audio

    func testCoreAudioCanBeReadWithoutAnyPermission() throws {
        let reader = CoreAudioInputReader()
        let processes = try reader.runningInputProcesses()
        for process in processes { XCTAssertGreaterThan(process.pid, 0) }

        let monitor = MicActivityMonitor()
        XCTAssertNil(monitor.snapshot().error)
    }

    // MARK: Helpers

    private func makeMonitor(_ reader: FakeAudioInputReader, ignoring: Set<String> = []) -> MicActivityMonitor {
        MicActivityMonitor(ignoredBundleIDs: { ignoring }, ownPID: ownPID, reader: reader, resolve: resolve)
    }

    /// Fake processes carry their owner's bundle ID, or a helper's ID that
    /// the fake resolver lifts to the app, the way the real one walks paths.
    private func resolve(_ process: AudioInputProcess) -> MicUser? {
        let owners = [zoom, chrome, slack, claude, MicUser(bundleIdentifier: "com.mikerosoft.meeting-archive", displayName: "Meeting Archive")]
        guard let bundleID = process.bundleID else { return nil }
        if bundleID == "com.google.Chrome.helper" { return chrome }
        return owners.first { $0.bundleIdentifier == bundleID }
    }

    private func process(_ pid: pid_t, _ user: MicUser) -> AudioInputProcess {
        process(pid, user.bundleIdentifier)
    }

    private func process(_ pid: pid_t, _ bundleID: String?) -> AudioInputProcess {
        AudioInputProcess(pid: pid, bundleID: bundleID, executablePath: nil)
    }
}

@MainActor
private final class IgnoreSetting {
    var bundleIDs: Set<String> = []
}

@MainActor
private final class FakeAudioInputReader: AudioInputReading {
    var deviceRunning: Bool?
    var processes: [AudioInputProcess]
    var error: Error?
    private(set) var deviceChecks = 0
    private(set) var scans = 0

    init(deviceRunning: Bool? = true, processes: [AudioInputProcess] = []) {
        self.deviceRunning = deviceRunning
        self.processes = processes
    }

    func anyInputDeviceRunning() -> Bool? {
        deviceChecks += 1
        return deviceRunning
    }

    func runningInputProcesses() throws -> [AudioInputProcess] {
        scans += 1
        if let error { throw error }
        return processes
    }
}
