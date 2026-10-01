import CoreMedia
import XCTest
@testable import MeetingArchiveApp

final class VideoFrameOrderTests: XCTestCase {
    func testTheFirstFrameIsWrittenWithNothingBeforeIt() {
        // CoreMedia orders CMTime.invalid after every real time. Starting from
        // it skipped every frame, so the 15 second startup check ended calls.
        XCTAssertTrue(VideoFrameOrder().admits(CMClockGetTime(CMClockGetHostTimeClock())))
    }

    func testOnlyAStrictlyNewerFrameFollowsTheLastOneWritten() {
        var order = VideoFrameOrder()
        let written = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
        order.record(written)

        XCTAssertFalse(order.admits(written))
        XCTAssertFalse(order.admits(CMTime(seconds: 99.9, preferredTimescale: 1_000_000_000)))
        XCTAssertTrue(order.admits(CMTime(seconds: 100.1, preferredTimescale: 1_000_000_000)))
    }
}
