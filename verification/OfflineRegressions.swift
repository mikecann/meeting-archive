import CryptoKit
import Foundation
import MeetingArchiveCore

// WorkerStatus's remote command builder shares this helper with the SwiftUI
// speaker-review source. Keep the same quoting here without importing UI.
enum RemoteShellCommand {
    static func make(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RegressionFailure(description: message) }
}

private func processingJob(
    id: Int,
    meetingID: UUID,
    state: WorkerProcessingState,
    error: String? = nil
) -> WorkerProcessingJob {
    WorkerProcessingJob(
        id: id,
        meetingID: meetingID,
        manifestRevision: 1,
        manifestSHA256: String(repeating: "a", count: 64),
        archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/fixture/\(meetingID.uuidString.lowercased())",
        state: state,
        attempts: state == .ready ? 0 : 1,
        availableAt: 100,
        leaseOwner: nil,
        leaseExpiresAt: nil,
        lastError: error
    )
}

private func publicationJob(
    processingJobID: Int,
    state: WorkerPublicationState,
    error: String? = nil
) -> WorkerPublicationJob {
    WorkerPublicationJob(
        processingJobID: processingJobID,
        archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/fixture",
        state: state,
        attempts: 1,
        availableAt: 100,
        lastError: error,
        leaseOwner: nil,
        leaseExpiresAt: nil,
        refreshRequested: 0
    )
}

private func verifyWorkerStatusMapping() throws {
    let publishedID = UUID()
    let speakerReviewID = UUID()
    let failedID = UUID()
    let publicationFailedID = UUID()
    let unknownID = UUID()
    let response = WorkerStatusResponse(
        schemaVersion: 1,
        counts: [:],
        jobs: [
            processingJob(id: 1, meetingID: publishedID, state: .succeeded),
            processingJob(id: 2, meetingID: speakerReviewID, state: .succeeded),
            processingJob(id: 3, meetingID: failedID, state: .permanentFailure, error: "audio is corrupt"),
            processingJob(id: 4, meetingID: publicationFailedID, state: .succeeded),
        ],
        publication: WorkerPublicationStatus(
            counts: [:],
            phase: "running",
            lastError: nil,
            jobs: [
                publicationJob(processingJobID: 1, state: .succeeded),
                publicationJob(processingJobID: 2, state: .ready),
                publicationJob(processingJobID: 4, state: .retryWait, error: "Notion is unavailable"),
            ]
        )
    )
    let statuses = try response.statuses(
        for: [publishedID, speakerReviewID, failedID, publicationFailedID, unknownID]
    )

    try require(statuses[publishedID]?.phase == .published, "published worker status mapped incorrectly")
    try require(statuses[publishedID]?.speakerReview == .available, "published speaker review was unavailable")
    try require(statuses[speakerReviewID]?.phase == .processing, "speaker-review-ready meeting was not processing")
    try require(statuses[speakerReviewID]?.speakerReview == .available, "completed processing hid speaker review")
    try require(statuses[failedID]?.phase == .needsAttention, "processing failure did not need attention")
    try require(statuses[failedID]?.retryStage == .processing, "processing failure mapped to wrong retry stage")
    try require(statuses[failedID]?.lastError == "audio is corrupt", "processing failure lost its error")
    try require(statuses[publicationFailedID]?.phase == .needsAttention, "publication failure did not need attention")
    try require(statuses[publicationFailedID]?.retryStage == .publication, "publication failure mapped to wrong retry stage")
    try require(statuses[publicationFailedID]?.speakerReview == .available, "publication failure hid speaker review")
    try require(statuses[publicationFailedID]?.lastError == "Notion is unavailable", "publication failure lost its error")
    try require(statuses[unknownID]?.phase == .archived, "unknown worker meeting invented processing state")
    try require(statuses[unknownID]?.processingState == nil, "unknown worker meeting gained a processing state")
    try require(statuses[unknownID]?.speakerReview == .waitingForProcessing, "unknown meeting exposed speaker review")
}

private actor OrderedWorkerStatusRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRequestRelease: CheckedContinuation<Void, Never>?

    init(results: [ArchiveProcessResult]) {
        self.results = results
    }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        if requests.count == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstRequestRelease = continuation
            }
        }
        guard !results.isEmpty else {
            throw RegressionFailure(description: "unexpected worker status request")
        }
        return results.removeFirst()
    }

    func waitForFirstRequest() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseFirstRequest() {
        firstRequestRelease?.resume()
        firstRequestRelease = nil
    }

    func requestCount() -> Int { requests.count }
    func recordedRequests() -> [ArchiveProcessRequest] { requests }
}

private func workerStatusData(
    meetingID: UUID,
    state: WorkerProcessingState,
    error: String? = nil
) throws -> Data {
    try JSONEncoder().encode(WorkerStatusResponse(
        schemaVersion: 1,
        counts: [:],
        jobs: [processingJob(id: 9, meetingID: meetingID, state: state, error: error)],
        publication: .init(counts: [:], phase: "not_queued", lastError: nil, jobs: [])
    ))
}

private func verifyWorkerStatusOperationOrder() async throws {
    let meetingID = UUID()
    let retryData = try JSONEncoder().encode(WorkerRetryResponse(
        schemaVersion: 1,
        meetingID: meetingID,
        retried: true,
        processing: .init(jobID: 9, state: .ready, retried: true),
        publication: nil
    ))
    let runner = OrderedWorkerStatusRunner(results: [
        .init(
            exitCode: 0,
            stdout: try workerStatusData(meetingID: meetingID, state: .permanentFailure, error: "old failure"),
            stderr: ""
        ),
        .init(exitCode: 0, stdout: retryData, stderr: ""),
        .init(exitCode: 0, stdout: try workerStatusData(meetingID: meetingID, state: .ready), stderr: ""),
    ])
    let client = WorkerStatusClient(processRunner: runner, cacheDuration: 60)
    let oldFetch = Task {
        try await client.fetch(meetingIDs: [meetingID], configuration: .bruce, force: true)
    }
    await runner.waitForFirstRequest()
    let retry = Task {
        try await client.retry(meetingID: meetingID, configuration: .bruce)
    }
    await Task.yield()
    let blockedRequestCount = await runner.requestCount()
    try require(blockedRequestCount == 1, "retry overtook an older blocked status request")

    await runner.releaseFirstRequest()
    let oldStatus = try await oldFetch.value
    let retryResult = try await retry.value
    try require(oldStatus[meetingID]?.phase == .needsAttention, "blocked status response changed unexpectedly")
    try require(retryResult.retried, "worker retry did not report success")

    let freshStatus = try await client.fetch(
        meetingIDs: [meetingID],
        configuration: .bruce,
        force: true
    )
    try require(freshStatus[meetingID]?.processingState == .ready, "fresh post-retry status did not win")
    let requests = await runner.recordedRequests()
    try require(requests.count == 3, "worker operation sequence did not issue exactly three requests")
    try require(requests[0].arguments.last?.contains("'status'") == true, "first worker request was not status")
    try require(requests[1].arguments.last?.contains("'retry'") == true, "retry was not serialized second")
    try require(requests[2].arguments.last?.contains("'status'") == true, "fresh status was not serialized last")
}

private actor RetryBlockingWorkerStatusRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryRelease: CheckedContinuation<Void, Never>?

    init(results: [ArchiveProcessResult]) {
        self.results = results
    }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        if requests.count == 2 {
            let waiters = retryWaiters
            retryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                retryRelease = continuation
            }
        }
        guard !results.isEmpty else {
            throw RegressionFailure(description: "unexpected cached worker status request")
        }
        return results.removeFirst()
    }

    func waitForRetryRequest() async {
        if requests.count >= 2 { return }
        await withCheckedContinuation { continuation in
            retryWaiters.append(continuation)
        }
    }

    func releaseRetryRequest() {
        retryRelease?.resume()
        retryRelease = nil
    }

    func recordedRequests() -> [ArchiveProcessRequest] { requests }
}

private func verifyCachedStatusWaitsForRetry() async throws {
    let meetingID = UUID()
    let retryData = try JSONEncoder().encode(WorkerRetryResponse(
        schemaVersion: 1,
        meetingID: meetingID,
        retried: true,
        processing: .init(jobID: 12, state: .ready, retried: true),
        publication: nil
    ))
    let runner = RetryBlockingWorkerStatusRunner(results: [
        .init(
            exitCode: 0,
            stdout: try workerStatusData(meetingID: meetingID, state: .permanentFailure, error: "old failure"),
            stderr: ""
        ),
        .init(exitCode: 0, stdout: retryData, stderr: ""),
        .init(exitCode: 0, stdout: try workerStatusData(meetingID: meetingID, state: .ready), stderr: ""),
    ])
    let client = WorkerStatusClient(processRunner: runner, cacheDuration: 60)
    _ = try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)

    let retry = Task {
        try await client.retry(meetingID: meetingID, configuration: .bruce)
    }
    await runner.waitForRetryRequest()
    let refresh = Task {
        try await client.fetch(meetingIDs: [meetingID], configuration: .bruce)
    }
    await Task.yield()
    await runner.releaseRetryRequest()
    _ = try await retry.value
    let freshStatus = try await refresh.value

    try require(freshStatus[meetingID]?.processingState == .ready, "cached failure bypassed an in-flight retry")
    let requests = await runner.recordedRequests()
    try require(requests.count == 3, "cached retry race did not issue a fresh status request")
    try require(requests[0].arguments.last?.contains("'status'") == true, "cache prime was not status")
    try require(requests[1].arguments.last?.contains("'retry'") == true, "blocked operation was not retry")
    try require(requests[2].arguments.last?.contains("'status'") == true, "post-retry refresh was not third")
}

private struct CleanupFixture {
    let source: URL
    let manifest: TransferManifest
    let acknowledgement: ArchiveAcknowledgement
    let rawManifest: Data
    let rawReceipt: Data
    let mediaURLs: [URL]
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func receiptData(
    acknowledgement: ArchiveAcknowledgement,
    manifest: TransferManifest
) throws -> Data {
    var value = try JSONSerialization.jsonObject(
        with: ModelCodec.encoder.encode(acknowledgement)
    ) as! [String: Any]
    value["media_validation"] = [
        "status": "passed",
        "full_decode": true,
        "files": manifest.files.filter { $0.kind != .metadata }.map {
            ["path": $0.path, "full_decode": true, "duration_seconds": 1.0] as [String: Any]
        },
    ] as [String: Any]
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

private func makeCleanupFixture(
    root: URL,
    externalMediaDirectory: URL? = nil,
    omitSecondMedia: Bool = false
) throws -> CleanupFixture {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let metadata = Data("metadata".utf8)
    try metadata.write(to: root.appendingPathComponent("metadata.json"))

    let mediaDirectory = externalMediaDirectory ?? root.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    if externalMediaDirectory != nil {
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("media"),
            withDestinationURL: mediaDirectory
        )
    }
    let firstData = Data("first media".utf8)
    let secondData = Data("second media".utf8)
    let firstURL = mediaDirectory.appendingPathComponent("first.m4a")
    let secondURL = mediaDirectory.appendingPathComponent("second.m4a")
    try firstData.write(to: firstURL)
    if !omitSecondMedia { try secondData.write(to: secondURL) }

    let manifest = TransferManifest(
        meetingID: UUID(),
        revision: 1,
        files: [
            .init(path: "metadata.json", sizeBytes: Int64(metadata.count), sha256: digest(metadata), kind: .metadata),
            .init(path: "media/first.m4a", sizeBytes: Int64(firstData.count), sha256: digest(firstData), kind: .microphoneAudio),
            .init(path: "media/second.m4a", sizeBytes: Int64(secondData.count), sha256: digest(secondData), kind: .incomingAudio),
        ]
    )
    let rawManifest = try manifest.canonicalData()
    try rawManifest.write(to: root.appendingPathComponent("manifest.json"))
    let acknowledgement = ArchiveAcknowledgement(
        meetingID: manifest.meetingID,
        manifestRevision: manifest.revision,
        manifestSHA256: digest(rawManifest),
        archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/fixture",
        acceptedAt: Date(timeIntervalSince1970: 1_800_000_000),
        verifiedFiles: manifest.files,
        queueJobID: "fixture-job",
        cleanupAllowed: true
    )
    let rawReceipt = try receiptData(acknowledgement: acknowledgement, manifest: manifest)
    try rawReceipt.write(to: root.appendingPathComponent("acknowledgement.json"))
    return .init(
        source: root,
        manifest: manifest,
        acknowledgement: acknowledgement,
        rawManifest: rawManifest,
        rawReceipt: rawReceipt,
        mediaURLs: [firstURL, secondURL]
    )
}

private func expectCleanupRefusal(
    _ body: () throws -> Void,
    matching predicate: (ArchiveTransferError) -> Bool,
    _ message: String
) throws {
    do {
        try body()
        throw RegressionFailure(description: message)
    } catch let error as ArchiveTransferError {
        try require(predicate(error), "unexpected cleanup error: \(error)")
    }
}

private func verifyCleanupSafety(in root: URL) throws {
    let symlinkSource = root.appendingPathComponent("symlink-source")
    let external = root.appendingPathComponent("external-media")
    let symlinkFixture = try makeCleanupFixture(
        root: symlinkSource,
        externalMediaDirectory: external
    )
    try expectCleanupRefusal(
        {
            try ArchiveCleanup.perform(
                source: symlinkFixture.source,
                index: root.appendingPathComponent("symlink-index"),
                acknowledgement: symlinkFixture.acknowledgement
            )
        },
        matching: { if case .unsafeLocalPath = $0 { true } else { false } },
        "parent symlink cleanup was accepted"
    )
    try require(
        symlinkFixture.mediaURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        },
        "external media was deleted"
    )

    let mismatchFixture = try makeCleanupFixture(root: root.appendingPathComponent("mismatch-source"))
    var mismatched = mismatchFixture.acknowledgement
    mismatched.queueJobID = "different-job"
    try expectCleanupRefusal(
        {
            try ArchiveCleanup.perform(
                source: mismatchFixture.source,
                index: root.appendingPathComponent("mismatch-index"),
                acknowledgement: mismatched
            )
        },
        matching: { if case .invalidAcknowledgement = $0 { true } else { false } },
        "receipt identity mismatch was accepted"
    )
    try require(
        mismatchFixture.mediaURLs.allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        },
        "identity failure deleted media"
    )

    let validFixture = try makeCleanupFixture(
        root: root.appendingPathComponent("valid-source"),
        omitSecondMedia: true
    )
    let unmanifested = validFixture.source.appendingPathComponent("keep-me.txt")
    try Data("keep".utf8).write(to: unmanifested)
    let index = root.appendingPathComponent("valid-index")
    try ArchiveCleanup.perform(
        source: validFixture.source,
        index: index,
        acknowledgement: validFixture.acknowledgement
    )
    try require(!FileManager.default.fileExists(atPath: validFixture.mediaURLs[0].path), "verified media was retained")
    try require(!FileManager.default.fileExists(atPath: validFixture.mediaURLs[1].path), "missing media unexpectedly appeared")
    try require(FileManager.default.fileExists(atPath: unmanifested.path), "unmanifested file was removed")
    let retainedManifest = try Data(contentsOf: index.appendingPathComponent("manifest.json"))
    let retainedReceipt = try Data(contentsOf: index.appendingPathComponent("acknowledgement.json"))
    try require(retainedManifest == validFixture.rawManifest, "raw manifest proof changed")
    try require(retainedReceipt == validFixture.rawReceipt, "raw receipt proof changed")
    try require(FileManager.default.fileExists(atPath: index.appendingPathComponent("cleanup-complete.json").path), "cleanup marker missing")
    try ArchiveCleanup.perform(
        source: validFixture.source,
        index: index,
        acknowledgement: validFixture.acknowledgement
    )
    try require(FileManager.default.fileExists(atPath: unmanifested.path), "cleanup retry removed an unmanifested file")
}

private actor StubProcessRunner: ArchiveProcessRunning {
    private var results: [ArchiveProcessResult]
    private var requests: [ArchiveProcessRequest] = []

    init(results: [ArchiveProcessResult]) { self.results = results }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        requests.append(request)
        guard !results.isEmpty else {
            throw RegressionFailure(description: "unexpected process request")
        }
        return results.removeFirst()
    }

    func recordedRequests() -> [ArchiveProcessRequest] { requests }
}

private func volumeInformation(uuid: String) throws -> Data {
    try PropertyListSerialization.data(
        fromPropertyList: ["VolumeUUID": uuid],
        format: .xml,
        options: 0
    )
}

private func verifyWrongVolumeStopsTransfer(in root: URL) async throws {
    let fixture = try makeCleanupFixture(root: root.appendingPathComponent("transfer-source"))
    let wrongUUID = "00000000-0000-0000-0000-000000000000"
    let runner = StubProcessRunner(
        results: [
            .init(exitCode: 0, stdout: try volumeInformation(uuid: wrongUUID), stderr: ""),
        ]
    )
    do {
        _ = try await ArchiveTransfer(processRunner: runner).upload(
            sourceDirectory: fixture.source,
            manifest: fixture.manifest,
            configuration: .bruce
        )
        throw RegressionFailure(description: "wrong volume was accepted")
    } catch let error as ArchiveTransferError {
        try require(error == .remoteVolumeMismatch(actual: wrongUUID), "unexpected volume error: \(error)")
    }
    let requests = await runner.recordedRequests()
    try require(requests.count == 1, "transfer continued after wrong volume")
    try require(requests[0].arguments.contains("/usr/sbin/diskutil"), "first request was not volume preflight")
    try require(!requests.contains(where: { $0.arguments.contains("mkdir") }), "mkdir ran after wrong volume")
    try require(!requests.contains(where: { $0.executable.path.hasSuffix("rsync") }), "rsync ran after wrong volume")
}

@main
enum OfflineRegressions {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-archive-offline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try verifyWorkerStatusMapping()
        try await verifyWorkerStatusOperationOrder()
        try await verifyCachedStatusWaitsForRetry()
        try verifyCleanupSafety(in: root)
        try await verifyWrongVolumeStopsTransfer(in: root)
        print("Meeting Archive offline production-seam regressions passed")
    }
}
