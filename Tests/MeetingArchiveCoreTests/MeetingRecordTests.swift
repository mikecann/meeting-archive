import Foundation
import XCTest
@testable import MeetingArchiveCore

final class MeetingRecordTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testFinalizedMeetingDefaultsToAcceptanceAfterNinetySeconds() {
        let record = makeRecord()

        XCTAssertEqual(record.acceptance, .pending(deadline: start.addingTimeInterval(150)))
        XCTAssertNil(record.resolvingDeadline(at: start.addingTimeInterval(149)))
        XCTAssertEqual(
            record.resolvingDeadline(at: start.addingTimeInterval(150))?.acceptance,
            .accepted(at: start.addingTimeInterval(150), trigger: .deadline)
        )
    }

    func testClosingPromptAcceptsImmediately() {
        let record = makeRecord()
        XCTAssertEqual(
            record.resolvingAcceptance(.accept(trigger: .promptClosed), at: start.addingTimeInterval(65)).acceptance,
            .accepted(at: start.addingTimeInterval(65), trigger: .promptClosed)
        )
    }

    func testExplicitDiscardWinsDurablyOnce() {
        let discarded = makeRecord().resolvingAcceptance(.discard, at: start.addingTimeInterval(65))
        let lateAcceptance = discarded.resolvingAcceptance(.accept(trigger: .deadline), at: start.addingTimeInterval(80))

        XCTAssertEqual(lateAcceptance.acceptance, .discarded(at: start.addingTimeInterval(65)))
    }

    func testTitleUpdatesRemainIndependentOfAcceptance() {
        let accepted = makeRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: start.addingTimeInterval(65))
        let renamed = accepted.updatingTitle("Architecture catch-up", at: start.addingTimeInterval(90))

        XCTAssertEqual(renamed.title, "Architecture catch-up")
        XCTAssertEqual(renamed.metadataRevision, accepted.metadataRevision + 1)
        XCTAssertEqual(renamed.acceptance, accepted.acceptance)
    }

    func testVersionedModelRoundTripsDatesInUTC() throws {
        let data = try ModelCodec.encoder.encode(makeRecord())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("Z\""), json)

        let decoded = try ModelCodec.decoder.decode(MeetingRecord.self, from: data)
        XCTAssertEqual(decoded, makeRecord())
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testRenamingAnArchivedMeetingKeepsItsRevision() {
        let record = makeRecord().resolvingAcceptance(.accept(trigger: .deadline), at: start.addingTimeInterval(200))
        let renamed = record.renamingArchived("Weekly planning", at: start.addingTimeInterval(300))
        XCTAssertEqual(renamed.title, "Weekly planning")
        XCTAssertEqual(renamed.metadataRevision, record.metadataRevision, "a new revision would re-upload and reprocess the whole meeting")
        XCTAssertEqual(renamed.acceptance, record.acceptance)
    }

    func testTitleSourceIsOptionalSoOlderRecordsStillLoad() throws {
        var record = makeRecord()
        XCTAssertNil(record.titleSource)
        let old = try ModelCodec.encoder.encode(record)
        XCTAssertFalse(try XCTUnwrap(String(data: old, encoding: .utf8)).contains("titleSource"))
        XCTAssertNil(try ModelCodec.decoder.decode(MeetingRecord.self, from: old).titleSource)

        record.titleSource = .calendar
        let data = try ModelCodec.encoder.encode(record)
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("\"titleSource\":\"calendar\""))
        XCTAssertEqual(try ModelCodec.decoder.decode(MeetingRecord.self, from: data), record)
        // The worker reads these as metadata title_source.
        XCTAssertEqual([MeetingTitleSource.default, .calendar, .user].map(\.rawValue), ["default", "calendar", "user"])
    }

    func testEitherKindOfRenameIsTheUsers() {
        var record = makeRecord()
        record.titleSource = .calendar
        XCTAssertEqual(record.updatingTitle("Mine", at: start).titleSource, .user)
        XCTAssertEqual(record.renamingArchived("Mine", at: start).titleSource, .user)
    }

    func testBrucesTitleIsAdoptedUnlessTheUserNamedTheMeeting() {
        let later = start.addingTimeInterval(500)
        var record = makeRecord().resolvingAcceptance(.accept(trigger: .deadline), at: start.addingTimeInterval(200))
        for source in [nil, MeetingTitleSource.default, .calendar] {
            record.titleSource = source
            let adopted = record.adoptingArchivedTitle("Budget revision with Sam", at: later)
            XCTAssertEqual(adopted?.title, "Budget revision with Sam")
            XCTAssertEqual(adopted?.titleSource, source, "adopting a title doesn't make it the user's")
            XCTAssertEqual(adopted?.metadataRevision, record.metadataRevision, "no new upload revision")
            XCTAssertEqual(adopted?.updatedAt, later)
        }
        record.titleSource = .default
        XCTAssertNil(record.adoptingArchivedTitle(nil, at: later))
        XCTAssertNil(record.adoptingArchivedTitle("  ", at: later))
        XCTAssertNil(record.adoptingArchivedTitle(record.title, at: later), "nothing to change")
        record.titleSource = .user
        XCTAssertNil(record.adoptingArchivedTitle("Budget revision with Sam", at: later))
    }

    private func makeRecord() -> MeetingRecord {
        MeetingRecord(
            id: UUID(uuidString: "3f679acb-96d4-4ee0-aa4e-36e96a1fe41d")!,
            title: "Weekly catch-up",
            sourceApplication: .init(bundleIdentifier: "us.zoom.xos", displayName: "Zoom", kind: .zoom),
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            timezoneIdentifier: "Australia/Perth",
            video: .init(surfaceID: "window-1", codec: "hevc", width: 1920, height: 1080),
            microphone: .init(deviceUID: "default-input", displayName: "Default microphone", sampleRate: 48_000, channels: 1),
            incomingAudio: .init(sourceApplicationBundleIdentifier: "us.zoom.xos", sampleRate: 48_000, channels: 2),
            finalizedAt: start.addingTimeInterval(60)
        )
    }
}
