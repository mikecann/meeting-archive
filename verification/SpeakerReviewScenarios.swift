import AppKit
import AVFoundation
import AVKit
import Foundation

private struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ScenarioFailure(description: message) }
}

private func saved(meetingID: UUID, revision: Int, names: [String: String]) -> SavedSpeakerNamesResponse {
    SavedSpeakerNamesResponse(
        schemaVersion: 1,
        meetingID: meetingID,
        manifestRevision: revision,
        speakers: names.sorted { $0.key < $1.key }.map {
            .init(speakerID: $0.key, name: $0.value.trimmingCharacters(in: .whitespacesAndNewlines), voiceProfileEnrolled: true)
        }
    )
}

private actor ScenarioReviewService: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    private var failures: Int
    private var calls: [[String: String]] = []

    init(response: SpeakerReviewResponse, failures: Int = 0) {
        self.response = response
        self.failures = failures
    }

    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse {
        response
    }

    func saveNames(
        meetingID: UUID,
        revision: Int,
        names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) async throws -> SavedSpeakerNamesResponse {
        calls.append(names)
        if failures > 0 {
            failures -= 1
            throw SpeakerReviewError.invalidResponse("fixture save failed")
        }
        return saved(meetingID: meetingID, revision: revision, names: names)
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        destination
    }

    func savedNameCalls() -> [[String: String]] { calls }
}

private actor ControlledScenarioReviewService: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    private var saveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(response: SpeakerReviewResponse) { self.response = response }

    func load(meetingID: UUID, revision: Int, configuration: ArchiveTransferConfiguration) async throws -> SpeakerReviewResponse {
        response
    }

    func saveNames(
        meetingID: UUID, revision: Int, names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) async throws -> SavedSpeakerNamesResponse {
        saveStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { finishContinuation = $0 }
        return saved(meetingID: meetingID, revision: revision, names: names)
    }

    func waitUntilSaveStarted() async {
        if saveStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishSave() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    func fetchPlayback(
        meetingID: UUID, destination: URL, configuration: ArchiveTransferConfiguration
    ) async throws -> URL { destination }
}

private actor ControlledScenarioPlaybackService: SpeakerReviewServing {
    let meetingID: UUID
    private var fetchStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<URL, Error>?

    init(meetingID: UUID) { self.meetingID = meetingID }

    func load(meetingID: UUID, revision: Int, configuration: ArchiveTransferConfiguration) async throws -> SpeakerReviewResponse {
        SpeakerReviewResponse(
            schemaVersion: 1, meetingID: meetingID, manifestRevision: revision,
            speakers: [], calendarCandidates: []
        )
    }

    func saveNames(
        meetingID: UUID, revision: Int, names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) async throws -> SavedSpeakerNamesResponse {
        throw SpeakerReviewError.invalidResponse("saving is not part of this fixture")
    }

    func fetchPlayback(
        meetingID: UUID, destination: URL, configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        fetchStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { fetchContinuation = $0 }
    }

    func waitUntilFetchStarted() async {
        if fetchStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishFetch() {
        fetchContinuation?.resume(returning: URL(fileURLWithPath: "/private/tmp/late-playback-fixture.mp4"))
        fetchContinuation = nil
    }
}

@main
private enum SpeakerReviewScenarios {
    @MainActor
    static func main() async throws {
        let meetingID = UUID()

        // Mike's 2 Oct Slack call: one person split into two voices, his own
        // mic recognized, and one voice nobody knows.
        let slackCall = response(
            meetingID: meetingID,
            speakers: [
                speaker("incoming:SPEAKER_00", name: "Micah"),
                speaker("incoming:SPEAKER_01"),
                speaker("incoming:SPEAKER_02"),
                speaker("microphone:SPEAKER_00", automaticName: "Mike Cann", suggestionKind: "own_microphone", confirmationCount: 6),
            ]
        )
        let service = ScenarioReviewService(response: slackCall)
        var reviewChanges = 0
        let model = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: service,
            onReviewChanged: { reviewChanges += 1 }
        )
        try require(!model.canSave, "review could be saved before it loaded")
        await model.load()
        try require(model.savedNames == ["incoming:SPEAKER_00": "Micah"], "saved name was not restored")
        try require(model.cards.count == 4, "every distinct voice should start on its own card")
        try require(
            model.cards.first.map { model.status(of: $0) } == .unknown,
            "voices that need a name should come first"
        )

        let split = try unwrap(model.card(containing: "incoming:SPEAKER_01"), "split voice has no card")
        model.setName("micah", forCard: split.id)
        try require(model.cards.count == 4, "cards merged while a name was still being typed")
        model.commitName(forCard: split.id)
        let micah = try unwrap(model.card(containing: "incoming:SPEAKER_00"), "Micah has no card")
        try require(micah.speakerIDs.count == 2, "the same name did not make one card")
        try require(micah.name == "Micah", "merging lost the saved spelling")
        try require(model.status(of: micah) == .typed, "a half-saved person should still need saving")

        let saveFinished = await model.save()
        let calls = await service.savedNameCalls()
        try require(saveFinished, "one click did not finish the review")
        try require(
            calls == [["incoming:SPEAKER_01": "Micah", "microphone:SPEAKER_00": "Mike Cann"]],
            "Save names did not send exactly the new and recognized names in one call: \(calls)"
        )
        try require(model.savedNames["incoming:SPEAKER_02"] == nil, "a blank voice was saved")
        try require(
            model.cards.filter { model.status(of: $0) == .saved }.count == 2,
            "saved cards were not shown as saved"
        )
        try require(reviewChanges == 1, "a successful save did not refresh Bruce's status once")

        // Nothing left to save closes without another trip to Bruce.
        let again = await model.save()
        let callsAfterAgain = await service.savedNameCalls()
        try require(again && callsAfterAgain.count == 1, "saving an unchanged review called Bruce")

        // Two voices Bruce suggested as the same person, and one isn't.
        let suggested = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: ScenarioReviewService(response: response(
                meetingID: meetingID,
                speakers: [
                    speaker("incoming:SPEAKER_00", suggestion: "Sean", suggestionKind: "tentative", confirmationCount: 2),
                    speaker("incoming:SPEAKER_01", suggestion: "Sean", suggestionKind: "tentative", confirmationCount: 2),
                ]
            ))
        )
        await suggested.load()
        try require(suggested.cards.count == 1, "matching suggestions did not share a card")
        try require(suggested.status(of: suggested.cards[0]) == .suggested, "a suggestion was not flagged")
        suggested.separate("incoming:SPEAKER_01")
        try require(suggested.namesToSave == ["incoming:SPEAKER_00": "Sean"], "a separated voice kept the name")

        let failing = ScenarioReviewService(
            response: response(meetingID: meetingID, speakers: [speaker("pending", suggestion: "Alex")]),
            failures: 1
        )
        let failed = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: failing,
            onReviewChanged: { reviewChanges += 1 }
        )
        await failed.load()
        let failedSave = await failed.save()
        try require(!failedSave, "a failed save reported success")
        try require(failed.failure != nil, "a failed save was not shown")
        try require(failed.savedNames.isEmpty, "a failed save marked a name saved")
        try require(reviewChanges == 1, "a failed save published a review change")
        let retried = await failed.save()
        try require(retried && failed.savedNames == ["pending": "Alex"], "Save names did not retry the failed name")

        let controlledClient = ControlledScenarioReviewService(
            response: response(meetingID: meetingID, speakers: [speaker("pending", suggestion: "Alex")])
        )
        let controlled = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: controlledClient
        )
        await controlled.load()
        let card = try unwrap(controlled.cards.first, "controlled review has no card")
        let inFlight = Task { await controlled.save() }
        await controlledClient.waitUntilSaveStarted()
        try require(!controlled.canSave, "a second save could start while one was in flight")
        controlled.setName("Alicia", forCard: card.id)
        await controlledClient.finishSave()
        let savedCurrentDraft = await inFlight.value
        try require(!savedCurrentDraft, "a stale save finished the review")
        try require(controlled.savedNames == ["pending": "Alex"], "the saved name was not what Bruce saved")
        try require(controlled.namesToSave == ["pending": "Alicia"], "the newer name was not left to save")

        let oldResponse = try JSONDecoder().decode(
            SpeakerReviewResponse.self,
            from: Data("""
            {
              "schema_version": 1,
              "meeting_id": "\(meetingID.uuidString.lowercased())",
              "manifest_revision": 3,
              "speakers": [{
                "speaker_id": "old",
                "name": null,
                "suggested_name": null,
                "suggestion_score": null,
                "suggestion_margin": null,
                "embedding_available": false,
                "excerpts": []
              }],
              "calendar_candidates": []
            }
            """.utf8)
        )
        try require(oldResponse.speakers.first?.automaticName == nil, "old response did not decode without automatic fields")

        let empty = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: ScenarioReviewService(response: response(meetingID: meetingID, speakers: []))
        )
        try require(!empty.canSave, "empty review could be saved before loading")
        await empty.load()
        let emptySaved = await empty.save()
        try require(empty.canSave && emptySaved, "loaded zero-speaker review could not be saved")

        _ = SpeakerReviewView(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            onComplete: {},
            onReviewChanged: {},
            onLater: {}
        )
        let playbackClient = ControlledScenarioPlaybackService(meetingID: meetingID)
        let stopped = SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: playbackClient
        )
        let excerpt = SpeakerReviewExcerpt(
            start: 0, end: 1, text: "fixture", channelOrigin: "system",
            playbackPath: "playback/meeting.mp4"
        )
        let latePlayback = Task { await stopped.play(excerpt, speakerID: "pending") }
        await playbackClient.waitUntilFetchStarted()
        stopped.stopPlayback()
        await playbackClient.finishFetch()
        await latePlayback.value
        try require(stopped.player == nil && stopped.playbackStatus == nil, "late fetch restarted stopped playback")
        try require(!stopped.isFetchingPlayback, "late fetch left playback loading")

        try await verifyNativePlaybackSurface()
        print("Speaker review cards, one-click save, retry, in-flight edit, and native playback surface scenarios passed")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ScenarioFailure(description: message) }
        return value
    }

    @MainActor
    private static func verifyNativePlaybackSurface() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-speaker-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appendingPathComponent("valid.wav")
        try writeValidAudio(to: mediaURL)

        let player = AVPlayer(url: mediaURL)
        let view = SpeakerPlayerSurface.make(player: player)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        try require(view.player === player, "native player view did not retain the player")
        player.play()
        try await Task.sleep(for: .milliseconds(350))
        try require(player.currentTime().seconds > 0, "valid local media did not begin playback")

        SpeakerPlayerSurface.dismantle(view)
        window.contentView = nil
        try require(view.player == nil && player.rate == 0, "native player teardown did not stop playback")
    }

    private static func writeValidAudio(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let seconds: UInt32 = 2
        let dataSize = sampleRate * seconds * 2
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        try data.write(to: url)
    }

    private static func response(
        meetingID: UUID,
        speakers: [SpeakerReviewSpeaker]
    ) -> SpeakerReviewResponse {
        SpeakerReviewResponse(
            schemaVersion: 1,
            meetingID: meetingID,
            manifestRevision: 3,
            speakers: speakers,
            calendarCandidates: []
        )
    }

    private static func speaker(
        _ id: String,
        name: String? = nil,
        suggestion: String? = nil,
        automaticName: String? = nil,
        suggestionKind: String? = nil,
        confirmationCount: Int? = nil
    ) -> SpeakerReviewSpeaker {
        SpeakerReviewSpeaker(
            speakerID: id,
            name: name,
            suggestedName: suggestion,
            suggestionScore: nil,
            suggestionMargin: nil,
            embeddingAvailable: false,
            excerpts: [],
            automaticName: automaticName,
            suggestionKind: suggestionKind,
            confirmationCount: confirmationCount
        )
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
