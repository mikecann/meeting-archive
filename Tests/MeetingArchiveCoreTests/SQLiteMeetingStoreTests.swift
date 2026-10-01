import Foundation
import XCTest
@testable import MeetingArchiveCore

final class SQLiteMeetingStoreTests: XCTestCase {
    func testSavedStateSurvivesReopenUnderItsOwnKey() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        struct Saved: Codable, Equatable { var isPaused: Bool; var note: String }

        let state = Saved(isPaused: true, note: "persisted")
        try SQLiteMeetingStore(url: databaseURL).saveState(state, key: "example")

        let store = try SQLiteMeetingStore(url: databaseURL)
        XCTAssertEqual(try store.loadState(Saved.self, key: "example"), state)
        XCTAssertNil(try store.loadState(Saved.self, key: "missing"))
    }

    func testOldRecorderRowDoesNotLeakIntoTheNewKey() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        struct Saved: Codable, Equatable { var schemaVersion: Int }
        let store = try SQLiteMeetingStore(url: databaseURL)
        try store.saveState(Saved(schemaVersion: 1), key: "recorder")

        XCTAssertNil(try store.loadState(Saved.self, key: SQLiteMeetingStore.recordingPolicyStateKey))
    }

    func testAcceptanceResolutionIsAtomicAndDiscardCannotBeOverwritten() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord()
        try store.insertMeeting(record)

        let discarded = try store.resolveAcceptance(
            meetingID: record.id,
            resolution: .discard,
            at: record.endedAt.addingTimeInterval(1)
        )
        let afterTimeout = try store.resolveAcceptance(
            meetingID: record.id,
            resolution: .accept(trigger: .deadline),
            at: record.endedAt.addingTimeInterval(20)
        )

        XCTAssertEqual(discarded.acceptance, afterTimeout.acceptance)
        XCTAssertEqual(try store.fetchMeeting(id: record.id), afterTimeout)
    }

    func testMeetingAndJobAreInsertedInOneTransactionAndLeaseRecovers() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: Date())
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: Date(timeIntervalSince1970: 1_800_000_000))

        try store.insertAcceptedMeeting(record, job: job)
        let firstLease = try XCTUnwrap(store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_001), leaseDuration: 30))
        XCTAssertEqual(firstLease.id, job.id)
        XCTAssertNil(try store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_010), leaseDuration: 30))
        XCTAssertEqual(
            try store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_032), leaseDuration: 30)?.id,
            job.id
        )
    }

    func testExistingPendingMeetingAcceptsAndEnqueuesIdempotentlyInOneTransaction() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord()
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: record.endedAt)
        try store.insertMeeting(record)

        let accepted = try store.resolveAcceptanceAndEnqueue(
            id: record.id,
            resolution: .accept(trigger: .deadline),
            at: record.endedAt.addingTimeInterval(20),
            job: job
        )
        _ = try store.resolveAcceptanceAndEnqueue(
            id: record.id,
            resolution: .accept(trigger: .deadline),
            at: record.endedAt.addingTimeInterval(21),
            job: job
        )

        XCTAssertFalse(accepted.acceptance.isPending)
        XCTAssertEqual(try store.listJobs().map(\.id), [job.id])
    }

    func testRetryBackoffCanBeClearedWhenBruceBecomesReachable() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: Date())
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.insertAcceptedMeeting(record, job: job)
        _ = try store.claimNextJob(now: Date(timeIntervalSince1970: 1_800_000_001), leaseDuration: 30)
        try store.scheduleRetry(jobID: job.id, availableAt: Date(timeIntervalSince1970: 1_800_003_600), error: "Bruce asleep")

        let now = Date(timeIntervalSince1970: 1_800_000_100)
        XCTAssertNil(try store.claimNextJob(now: now, leaseDuration: 30))
        XCTAssertEqual(try store.makeRetryableJobsAvailable(now: now), 1)
        XCTAssertEqual(try store.claimNextJob(now: now, leaseDuration: 30)?.id, job.id)
    }

    func testAFailedJobKeepsItsReasonAndIsNeverClaimedAgain() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord().resolvingAcceptance(.accept(trigger: .deadline), at: Date())
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: record.endedAt)
        try store.insertAcceptedMeeting(record, job: job)
        _ = try XCTUnwrap(store.claimNextJob(now: record.endedAt.addingTimeInterval(1), leaseDuration: 30))

        try store.failJob(id: job.id, error: "No audio or video was recorded.")

        let failed = try XCTUnwrap(store.fetchJob(id: job.id))
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.lastError, "No audio or video was recorded.")
        XCTAssertNil(failed.leaseUntil)
        // Neither an expired lease, a wake nor a relaunch picks it up again.
        let nextWeek = record.endedAt.addingTimeInterval(7 * 24 * 3600)
        let reopened = try SQLiteMeetingStore(url: databaseURL)
        XCTAssertEqual(try reopened.makeRetryableJobsAvailable(now: nextWeek), 0)
        XCTAssertNil(try reopened.claimNextJob(now: nextWeek, leaseDuration: 30))
        XCTAssertEqual(try reopened.fetchJob(id: job.id), failed)
    }

    func testAFailedJobDoesNotHoldUpLaterMeetings() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let first = meetingRecord().resolvingAcceptance(.accept(trigger: .deadline), at: Date())
        let second = meetingRecord().resolvingAcceptance(.accept(trigger: .deadline), at: Date())
        let firstJob = ArchiveJob(meetingID: first.id, manifestRevision: 1, createdAt: first.endedAt)
        let secondJob = ArchiveJob(meetingID: second.id, manifestRevision: 1, createdAt: first.endedAt.addingTimeInterval(60))
        try store.insertAcceptedMeeting(first, job: firstJob)
        try store.insertAcceptedMeeting(second, job: secondJob)
        let now = first.endedAt.addingTimeInterval(120)

        XCTAssertEqual(try store.claimNextJob(now: now, leaseDuration: 30)?.id, firstJob.id)
        try store.failJob(id: firstJob.id, error: "No audio or video was recorded.")

        XCTAssertEqual(try store.claimNextJob(now: now, leaseDuration: 30)?.id, secondJob.id)
    }

    func testStoreErrorsReadAsWrittenWhenShown() {
        let id = UUID()
        XCTAssertEqual(MeetingStoreError.missingJob(id).localizedDescription, "Archive job does not exist: \(id.canonicalString)")
    }

    func testCheckpointMovesCommittedPagesIntoTheMainDatabaseFile() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        try store.insertMeeting(meetingRecord())
        try store.checkpoint()

        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? Int) ?? 0
        XCTAssertEqual(walSize, 0)
        let mainSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databaseURL.path)[.size] as? Int)
        XCTAssertGreaterThan(mainSize, 4096)
    }

    func testRetryAndSuccessfulAcknowledgementRemainDurable() throws {
        let databaseURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let store = try SQLiteMeetingStore(url: databaseURL)
        let record = meetingRecord().resolvingAcceptance(.accept(trigger: .keepButton), at: Date())
        let job = ArchiveJob(meetingID: record.id, manifestRevision: 1, createdAt: record.endedAt)
        try store.insertAcceptedMeeting(record, job: job)

        try store.scheduleRetry(jobID: job.id, availableAt: record.endedAt.addingTimeInterval(60), error: "Bruce unavailable")
        XCTAssertEqual(try store.fetchJob(id: job.id)?.status, .retryScheduled)
        XCTAssertEqual(try store.fetchJob(id: job.id)?.lastError, "Bruce unavailable")

        let acknowledgement = ArchiveAcknowledgement(
            meetingID: record.id,
            manifestRevision: 1,
            manifestSHA256: String(repeating: "a", count: 64),
            archivePath: "/Volumes/CannMedia/MeetingArchive/test",
            acceptedAt: record.endedAt.addingTimeInterval(90),
            verifiedFiles: [],
            queueJobID: job.id.uuidString.lowercased(),
            cleanupAllowed: true
        )
        try store.acknowledgeJob(id: job.id, acknowledgement: acknowledgement)
        XCTAssertEqual(try store.fetchJob(id: job.id)?.status, .succeeded)
        XCTAssertEqual(try store.fetchJob(id: job.id)?.acknowledgement, acknowledgement)
    }

    private func temporaryDatabaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("meeting-archive.sqlite3")
    }

    private func meetingRecord() -> MeetingRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return MeetingRecord(
            id: UUID(),
            title: "Meeting",
            sourceApplication: .init(bundleIdentifier: "com.google.Chrome", displayName: "Chrome", kind: .other),
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            timezoneIdentifier: "Australia/Perth",
            microphone: .init(deviceUID: "default", displayName: "Default", sampleRate: 48_000, channels: 1),
            incomingAudio: .init(sourceApplicationBundleIdentifier: "com.google.Chrome", sampleRate: 48_000, channels: 2),
            finalizedAt: start.addingTimeInterval(60)
        )
    }
}
