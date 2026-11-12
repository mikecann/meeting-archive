import Foundation
import XCTest
@testable import MeetingArchiveApp

/// Meeting Archive has to be running before a call starts, with nobody
/// checking. A copy quit from its menu once went unnoticed for a day and a
/// half, because the login item only came back after a crash.
final class StayRunningTests: XCTestCase {
    private var agentPlist: [String: Any] {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/com.mikerosoft.meeting-archive.plist")
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
    }

    func testTheLoginItemComesBackHoweverTheAppExits() throws {
        // A dictionary like SuccessfulExit = false leaves a clean quit dead.
        XCTAssertEqual(try agentPlist["KeepAlive"] as? Bool, true)
    }

    func testLaunchdGivesTheAppTimeToSaveARecordingWhenItStopsIt() throws {
        // Disabling the login item sends SIGTERM, then SIGKILL after this many
        // seconds. The default 5 can cut off the last part of a recording.
        let timeout = try XCTUnwrap(try agentPlist["ExitTimeOut"] as? Int)
        XCTAssertGreaterThanOrEqual(timeout, 20)
    }

    func testABackgroundCopyWaitsForTheOtherCopyToQuit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock").path

        XCTAssertFalse(InstanceLock.isHeld(at: path))

        // Another copy holds the lock, the way ArchiveController does.
        let other = open(path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)
        XCTAssertTrue(InstanceLock.isHeld(at: path))

        let waited = expectation(description: "stops waiting once the other copy quits")
        let start = Date()
        DispatchQueue.global().async {
            InstanceLock.waitUntilFree(at: path, pollEvery: 0.05)
            waited.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        close(other)
        wait(for: [waited], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        // Checking must not leave the lock held, or the controller's own
        // non-blocking attempt would fail and quit the app.
        XCTAssertFalse(InstanceLock.isHeld(at: path))
    }
}
