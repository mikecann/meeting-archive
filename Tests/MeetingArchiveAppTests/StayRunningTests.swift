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

    func testABackgroundCopyWaitsForTheOtherCopyToQuitThenHoldsTheLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // First run: the data folder doesn't exist yet.
        let path = directory.appendingPathComponent("instance.lock").path
        let first = try XCTUnwrap(InstanceLock.waitAndTake(at: path, pollEvery: 0.05))
        close(first)

        // Another copy holds the lock, the way ArchiveController does.
        let other = open(path, O_CREAT | O_RDWR, 0o600)
        XCTAssertEqual(flock(other, LOCK_EX | LOCK_NB), 0)

        let waited = expectation(description: "takes the lock once the other copy quits")
        let start = Date()
        nonisolated(unsafe) var taken: Int32?
        DispatchQueue.global().async {
            taken = InstanceLock.waitAndTake(at: path, pollEvery: 0.05)
            waited.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        close(other)
        wait(for: [waited], timeout: 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        let descriptor = try XCTUnwrap(taken)
        defer { close(descriptor) }

        // Still held, so a copy opened by hand now can't start recording too.
        let late = open(path, O_CREAT | O_RDWR, 0o600)
        defer { close(late) }
        XCTAssertNotEqual(flock(late, LOCK_EX | LOCK_NB), 0)
        // And ArchiveController's own attempt on the same descriptor succeeds.
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
    }
}
