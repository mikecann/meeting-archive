import XCTest
@testable import MeetingArchiveApp
import MeetingArchiveCore

final class SpoolBundleTests: XCTestCase {
    func testExportContainsHashedMetadataAndIndependentTracks() throws {
        let directory = try bundle(with: ["microphone.m4a", "meeting-view.mov"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try SpoolBundle.prepare(record: record(), directory: directory)
        try manifest.validate()
        XCTAssertEqual(Set(manifest.files.map(\.path)), ["metadata.json", "meeting-view.mov", "microphone.m4a"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), try manifest.canonicalData())
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("metadata.json"))) as! [String: Any]
        XCTAssertEqual(metadata["title"] as? String, "Planning")
        XCTAssertEqual(metadata["duration_seconds"] as? Double, 60)
    }

    func testAnAudioOnlyCaptureIsArchivedWithBothTracks() throws {
        let directory = try bundle(with: ["microphone.m4a", "incoming.m4a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        var audioOnly = record()
        audioOnly.video = nil

        let manifest = try SpoolBundle.prepare(record: audioOnly, directory: directory)

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.kind) }),
            ["metadata.json": .metadata, "microphone.m4a": .microphoneAudio, "incoming.m4a": .incomingAudio]
        )
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("metadata.json"))) as! [String: Any]
        let capture = try XCTUnwrap(metadata["capture"] as? [String: Any])
        XCTAssertNil(capture["video"])
    }

    func testAttendeesOfTheMatchedEventAreWrittenWhereTheWorkerReadsThem() throws {
        let directory = try bundle(with: ["microphone.m4a", "incoming.m4a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = record()
        let matched = CalendarSuggestion(
            id: "standup", title: "Acme catch up", start: meeting.startedAt, end: meeting.endedAt,
            attendees: [CalendarAttendee(name: "Sam Example", email: "sam@example.com", response: "2")]
        )
        let elsewhere = CalendarSuggestion(
            id: "school-run", title: "School run", start: meeting.endedAt.addingTimeInterval(3600),
            end: meeting.endedAt.addingTimeInterval(7200),
            attendees: [CalendarAttendee(name: "Not In The Call", email: nil, response: "1")]
        )
        try ModelCodec.encoder.encode([matched, elsewhere]).write(to: directory.appendingPathComponent("calendar.json"))

        _ = try SpoolBundle.prepare(record: meeting, directory: directory)

        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("metadata.json"))) as! [String: Any]
        let attendees = try XCTUnwrap(metadata["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.count, 1)
        XCTAssertEqual(attendees.first?["name"] as? String, "Sam Example")
        XCTAssertEqual(attendees.first?["email"] as? String, "sam@example.com")
        XCTAssertEqual((metadata["calendar"] as? [Any])?.count, 2)
    }

    func testNoAttendeesAreWrittenWithoutAClearCalendarMatch() throws {
        let directory = try bundle(with: ["microphone.m4a"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = record()
        let unrelated = CalendarSuggestion(
            id: "later", title: "Later", start: meeting.endedAt.addingTimeInterval(600),
            end: meeting.endedAt.addingTimeInterval(1200),
            attendees: [CalendarAttendee(name: "Someone", email: nil, response: "1")]
        )
        try ModelCodec.encoder.encode([unrelated]).write(to: directory.appendingPathComponent("calendar.json"))

        _ = try SpoolBundle.prepare(record: meeting, directory: directory)

        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("metadata.json"))) as! [String: Any]
        XCTAssertNil(metadata["attendees"])
    }

    func testACaptureWithoutMicrophoneAudioIsArchivedWithTheTracksItHas() throws {
        let directory = try bundle(with: ["meeting-view.mov", "incoming.m4a"])
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = try SpoolBundle.prepare(record: record(), directory: directory)

        try manifest.validate()
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.kind) }),
            ["metadata.json": .metadata, "meeting-view.mov": .video, "incoming.m4a": .incomingAudio]
        )
    }

    func testACaptureWithNoAudioOrVideoIsLeftExactlyAsRecorded() throws {
        let directory = try bundle(with: ["tracks.json"])
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SpoolBundle.prepare(record: record(), directory: directory)) { error in
            XCTAssertEqual(error as? UnarchivableCapture, .nothingRecorded)
        }
        // No metadata or manifest is written, so nothing here looks ready to send.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["tracks.json"])
    }

    func testRecoveryStillFindsTheTracksOfACaptureWithoutAMicrophone() throws {
        let directory = try bundle(with: ["meeting-view.mov", "incoming.m4a"])
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try SpoolBundle.mediaFiles(in: directory).map { $0.1 }, [.video, .incomingAudio])
    }

    func testAnEmptyTrackIsStillRefused() throws {
        let directory = try bundle(with: ["meeting-view.mov"])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.appendingPathComponent("microphone.m4a").path, contents: Data()))

        XCTAssertThrowsError(try SpoolBundle.mediaFiles(in: directory))
    }

    func testOnlyACaptureThatCanNeverBeArchivedStopsRetrying() {
        XCTAssertEqual(
            UploadFailure(UnarchivableCapture.nothingRecorded, attempt: 1),
            .permanent(reason: "No audio or video was recorded.")
        )
        // Anything else, usually Bruce being out of reach, backs off as before.
        let unreachable = ArchiveTransferError.processTimedOut("/usr/bin/ssh")
        XCTAssertEqual(UploadFailure(unreachable, attempt: 1), .retry(after: 60))
        XCTAssertEqual(UploadFailure(unreachable, attempt: 3), .retry(after: 240))
        XCTAssertEqual(UploadFailure(unreachable, attempt: 40), .retry(after: 3600))
    }

    private func bundle(with names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        return directory
    }

    private func record() -> MeetingRecord {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return MeetingRecord(title: "Planning", sourceApplication: .init(bundleIdentifier: "us.zoom.xos", displayName: "Zoom", kind: .zoom), startedAt: now, endedAt: now.addingTimeInterval(60), timezoneIdentifier: "Australia/Perth", video: .init(surfaceID: "1", codec: "hevc", width: 1920, height: 1080), microphone: .init(deviceUID: "default", displayName: "Default", sampleRate: 48000, channels: 1), incomingAudio: .init(sourceApplicationBundleIdentifier: "us.zoom.xos", sampleRate: 48000, channels: 2), finalizedAt: now.addingTimeInterval(60))
    }
}
