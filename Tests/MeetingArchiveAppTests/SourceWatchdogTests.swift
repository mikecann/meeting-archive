import XCTest
@testable import MeetingArchiveApp

final class SourceWatchdogTests: XCTestCase {
    func testASourceThatKeepsDeliveringIsLeftAlone() {
        var watchdog = SourceWatchdog()
        for second in 0..<30 {
            XCTAssertEqual(watchdog.check(now: Double(second), lastDelivery: Double(second) - 0.01), .healthy)
        }
    }

    func testThreeQuietSecondsRestartTheSource() {
        var watchdog = SourceWatchdog()
        XCTAssertEqual(watchdog.check(now: 102.9, lastDelivery: 100), .healthy)
        XCTAssertEqual(watchdog.check(now: 103.5, lastDelivery: 100), .restart(quietFor: 3.5, newOutage: true))
    }

    func testRestartsForOneOutageAreTenSecondsApartAndWarnedOnce() {
        var watchdog = SourceWatchdog()
        XCTAssertEqual(watchdog.check(now: 104, lastDelivery: 100), .restart(quietFor: 4, newOutage: true))
        // The Yeti can stay dead; it is retried, not hammered.
        XCTAssertEqual(watchdog.check(now: 108, lastDelivery: 100), .healthy)
        XCTAssertEqual(watchdog.check(now: 113.9, lastDelivery: 100), .healthy)
        XCTAssertEqual(watchdog.check(now: 114, lastDelivery: 100), .restart(quietFor: 14, newOutage: false))
    }

    func testAudioReturningEndsTheOutageOnce() {
        var watchdog = SourceWatchdog()
        _ = watchdog.check(now: 104, lastDelivery: 100)
        XCTAssertEqual(watchdog.check(now: 105, lastDelivery: 104.5), .recovered(after: 4.5))
        XCTAssertEqual(watchdog.check(now: 106, lastDelivery: 105.9), .healthy)
        // A later outage is new again, but still waits out the spacing.
        XCTAssertEqual(watchdog.check(now: 113.9, lastDelivery: 110), .healthy)
        XCTAssertEqual(watchdog.check(now: 114, lastDelivery: 110), .restart(quietFor: 4, newOutage: true))
    }

    func testASourceThatCouldNotStartIsRetriedQuietlyAndReportedWhenItArrives() {
        var watchdog = SourceWatchdog()
        watchdog.failedToStart(at: 100)
        XCTAssertEqual(watchdog.check(now: 109, lastDelivery: 100), .healthy)
        XCTAssertEqual(watchdog.check(now: 110, lastDelivery: 100), .restart(quietFor: 10, newOutage: false))
        XCTAssertEqual(watchdog.check(now: 111, lastDelivery: 110.5), .recovered(after: 10.5))
    }

    func testABurstOfDeviceChangesBecomesOneRebuildOnceItSettles() {
        let queue = DispatchQueue(label: "rebuild-scheduler-test")
        let scheduler = RebuildScheduler(queue: queue, settleDelay: 0.1, minimumSpacing: 1)
        let rebuilds = Rebuilds()
        let rebuilt = expectation(description: "rebuilt")
        // AirPods connecting: input, output and rate change one after another.
        for (index, reason) in ["The default microphone changed", "The sound output changed", "The sound output changed mode"].enumerated() {
            queue.asyncAfter(deadline: .now() + 0.05 * Double(index)) {
                scheduler.request(reason) { rebuilds.add($0); rebuilt.fulfill() }
            }
        }

        wait(for: [rebuilt], timeout: 2)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(rebuilds.reasons, ["The default microphone changed"])
        // It waited for the last change, not the first.
        XCTAssertGreaterThanOrEqual(rebuilds.times[0] - rebuilds.started, 0.19)
    }

    func testRebuildsStayApartSoAChangeThatKeepsComingCannotLoop() {
        let queue = DispatchQueue(label: "rebuild-scheduler-test")
        let scheduler = RebuildScheduler(queue: queue, settleDelay: 0.05, minimumSpacing: 0.5)
        let rebuilds = Rebuilds()
        let both = expectation(description: "rebuilt twice")
        both.expectedFulfillmentCount = 2
        queue.async { scheduler.request("first") { rebuilds.add($0); both.fulfill() } }
        queue.asyncAfter(deadline: .now() + 0.15) { scheduler.request("second") { rebuilds.add($0); both.fulfill() } }

        wait(for: [both], timeout: 3)

        XCTAssertEqual(rebuilds.reasons, ["first", "second"])
        XCTAssertGreaterThanOrEqual(rebuilds.times[1] - rebuilds.times[0], 0.45)
    }

    func testARebuildForANewDeviceCountsTowardTheSpacing() {
        var watchdog = SourceWatchdog()
        watchdog.restarted(at: 100)
        XCTAssertEqual(watchdog.check(now: 105, lastDelivery: 100), .healthy)
        XCTAssertEqual(watchdog.check(now: 110, lastDelivery: 100), .restart(quietFor: 10, newOutage: true))
    }
}

private final class Rebuilds: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, TimeInterval)] = []
    let started = DeliveryClock.now
    var reasons: [String] { lock.withLock { entries.map(\.0) } }
    var times: [TimeInterval] { lock.withLock { entries.map(\.1) } }
    func add(_ reason: String) { lock.withLock { entries.append((reason, DeliveryClock.now)) } }
}
