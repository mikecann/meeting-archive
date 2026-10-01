import AVFoundation
import AVKit
import Foundation
import XCTest
@testable import MeetingArchiveApp

final class SpeakerReviewTests: XCTestCase {
    func testReviewResponseDecodesNullablePredictionsCandidatesAndPlayback() throws {
        let meetingID = UUID()
        let data = Data("""
        {
          "schema_version": 1,
          "meeting_id": "\(meetingID.uuidString.lowercased())",
          "manifest_revision": 3,
          "speakers": [
            {
              "speaker_id": "SPEAKER_00",
              "name": null,
              "suggested_name": "Alex Chen",
              "suggestion_score": 0.87,
              "suggestion_margin": null,
              "embedding_available": true,
              "excerpts": [
                {
                  "start": 12.5,
                  "end": 18.25,
                  "text": "I can take that action.",
                  "channel_origin": "system",
                  "playback_path": "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/id/playback/meeting.mp4"
                }
              ]
            },
            {
              "speaker_id": "SPEAKER_01",
              "name": "Michael",
              "suggested_name": null,
              "suggestion_score": null,
              "suggestion_margin": null,
              "embedding_available": false,
              "excerpts": []
            }
          ],
          "calendar_candidates": [
            {"name":"Alex Chen","email":"alex@example.com","response_status":"accepted","source":"calendar"}
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(SpeakerReviewResponse.self, from: data)

        XCTAssertEqual(response.meetingID, meetingID)
        XCTAssertEqual(response.speakers[0].suggestedName, "Alex Chen")
        XCTAssertEqual(response.speakers[0].excerpts[0].start, 12.5)
        XCTAssertEqual(response.speakers[1].name, "Michael")
        XCTAssertEqual(response.calendarCandidates.first?.email, "alex@example.com")
        XCTAssertNil(response.speakers[0].automaticName)
        XCTAssertNil(response.speakers[0].suggestionKind)
        XCTAssertNil(response.speakers[0].confirmationCount)
    }

    /// Bruce stopped reading names off video, but older payloads still decode.
    func testReviewResponseDecodesAutomaticNameAndIgnoresOldVideoEvidence() throws {
        let meetingID = UUID()
        let data = Data("""
        {
          "schema_version": 1,
          "meeting_id": "\(meetingID.uuidString.lowercased())",
          "manifest_revision": 3,
          "speakers": [{
            "speaker_id": "SPEAKER_00",
            "name": null,
            "suggested_name": "Michael",
            "suggestion_score": null,
            "suggestion_margin": null,
            "embedding_available": true,
            "excerpts": [],
            "automatic_name": "Mike Cann",
            "suggestion_kind": "own_microphone",
            "confirmation_count": 4,
            "evidence_labels": [{
              "name": "Michael Cann",
              "timestamps": [12.5, 42.0],
              "source": "video_text"
            }]
          }],
          "calendar_candidates": []
        }
        """.utf8)

        let response = try JSONDecoder().decode(SpeakerReviewResponse.self, from: data)
        let speaker = try XCTUnwrap(response.speakers.first)

        XCTAssertEqual(speaker.automaticName, "Mike Cann")
        XCTAssertEqual(speaker.suggestionKind, "own_microphone")
        XCTAssertEqual(speaker.confirmationCount, 4)
    }

    func testVoicesAreLabelledByTrackAndNumberFromOne() {
        XCTAssertEqual(makeSpeaker(id: "incoming:SPEAKER_01").voiceLabel, "Call audio, voice 2")
        XCTAssertEqual(makeSpeaker(id: "microphone:SPEAKER_00").voiceLabel, "Your mic, voice 1")
        XCTAssertEqual(makeSpeaker(id: "SPEAKER_00").voiceLabel, "SPEAKER_00")
    }

    func testStartingNamePrefersSavedThenRecognizedThenSuggested() {
        XCTAssertEqual(SpeakerReviewCard.startingName(for: makeSpeaker(
            id: "a", name: " Michael ", suggestion: "Mike", automaticName: "Wrong automatic fallback"
        )), "Michael")
        XCTAssertEqual(SpeakerReviewCard.startingName(for: makeSpeaker(
            id: "b", suggestion: "Tentative fallback", automaticName: "Known voice", suggestionKind: "strong"
        )), "Known voice")
        XCTAssertEqual(SpeakerReviewCard.startingName(for: makeSpeaker(id: "c", suggestion: "Alex")), "Alex")
        XCTAssertEqual(SpeakerReviewCard.startingName(for: makeSpeaker(id: "d", name: "  ")), "")
    }

    /// Mike's screenshot: pyannote split Micah in two, and each half needed
    /// its own Confirm. Voices with the same name are now one card.
    func testVoicesWithTheSameNameShareOneCardWhateverTheNameCameFrom() {
        let cards = SpeakerReviewCard.make(speakers: [
            makeSpeaker(id: "incoming:SPEAKER_00", name: "Micah"),
            makeSpeaker(id: "incoming:SPEAKER_01", suggestion: "micah ", suggestionKind: "tentative"),
            makeSpeaker(id: "incoming:SPEAKER_02"),
            makeSpeaker(id: "incoming:SPEAKER_03"),
            makeSpeaker(id: "microphone:SPEAKER_00", automaticName: "Mike Cann", suggestionKind: "own_microphone"),
        ])

        XCTAssertEqual(cards.map(\.speakerIDs), [
            ["incoming:SPEAKER_00", "incoming:SPEAKER_01"],
            ["incoming:SPEAKER_02"],
            ["incoming:SPEAKER_03"],
            ["microphone:SPEAKER_00"],
        ])
        XCTAssertEqual(cards.map(\.name), ["Micah", "", "", "Mike Cann"])
    }

    func testRemoteShellQuotesArbitraryNamesAsOneLiteralArgument() {
        let name = "D'Angelo $(touch /tmp/nope); `whoami`\nSecond line"

        let quoted = RemoteShellCommand.quote(name)

        XCTAssertEqual(quoted, "'D'\"'\"'Angelo $(touch /tmp/nope); `whoami`\nSecond line'")
    }

    func testSaveNamesSendsEveryNameAsOneQuotedJSONArgument() throws {
        let meetingID = UUID()
        var configuration = ArchiveTransferConfiguration.bruce
        configuration.host = "test-host"
        let request = try SpeakerReviewCommandBuilder.saveNames(
            meetingID: meetingID,
            revision: 4,
            names: ["incoming:SPEAKER_01": " D'Angelo; echo bad ", "incoming:SPEAKER_00": "Micah"],
            configuration: configuration
        )

        XCTAssertEqual(request.executable.path, "/usr/bin/ssh")
        XCTAssertEqual(request.arguments.dropLast().suffix(1), ["test-host"])
        let command = try XCTUnwrap(request.arguments.last)
        XCTAssertTrue(command.contains("'identify-speakers'"))
        XCTAssertTrue(command.contains("'--meeting-id' '\(meetingID.uuidString.lowercased())'"))
        XCTAssertTrue(command.contains(
            "'--names' '{\"incoming:SPEAKER_00\":\"Micah\",\"incoming:SPEAKER_01\":\"D'\"'\"'Angelo; echo bad\"}'"
        ))
        XCTAssertEqual(request.timeout, configuration.workerTimeout)
    }

    func testSaveNamesRefusesAnEmptyRequestOrName() {
        XCTAssertThrowsError(try SpeakerReviewCommandBuilder.saveNames(
            meetingID: UUID(), revision: 1, names: [:], configuration: .bruce
        ))
        XCTAssertThrowsError(try SpeakerReviewCommandBuilder.saveNames(
            meetingID: UUID(), revision: 1, names: ["incoming:SPEAKER_00": "  "], configuration: .bruce
        ))
    }

    func testSavedNamesMustBeExactlyTheNamesSent() throws {
        let meetingID = UUID()
        let names = ["a": "Micah", "b": "Micah"]
        func response(_ speakers: [(String, String)], revision: Int = 3) -> SavedSpeakerNamesResponse {
            SavedSpeakerNamesResponse(
                schemaVersion: 1, meetingID: meetingID, manifestRevision: revision,
                speakers: speakers.map { .init(speakerID: $0.0, name: $0.1, voiceProfileEnrolled: true) }
            )
        }

        XCTAssertNoThrow(try response([("a", "Micah"), ("b", "Micah")]).validate(meetingID: meetingID, revision: 3, names: names))
        XCTAssertThrowsError(try response([("a", "Micah")]).validate(meetingID: meetingID, revision: 3, names: names))
        XCTAssertThrowsError(try response([("a", "Micah"), ("b", "Sean")]).validate(meetingID: meetingID, revision: 3, names: names))
        XCTAssertThrowsError(try response([("a", "Micah"), ("a", "Micah")]).validate(meetingID: meetingID, revision: 3, names: names))
        XCTAssertThrowsError(try response([("a", "Micah"), ("b", "Micah")], revision: 2).validate(meetingID: meetingID, revision: 3, names: names))
    }

    func testSaveNamesClientChecksWhatBruceSaved() async throws {
        let meetingID = UUID()
        let saved = """
        {"schema_version":1,"meeting_id":"\(meetingID.uuidString.lowercased())","manifest_revision":3,
         "speakers":[{"speaker_id":"incoming:SPEAKER_00","name":"Micah","voice_profile_enrolled":true}]}
        """
        let runner = RecordingProcessRunner(stdout: Data(saved.utf8))
        let client = SpeakerReviewClient(processRunner: runner)

        let response = try await client.saveNames(
            meetingID: meetingID, revision: 3, names: ["incoming:SPEAKER_00": " Micah "], configuration: .bruce
        )
        XCTAssertEqual(response.speakers.map(\.name), ["Micah"])

        do {
            _ = try await client.saveNames(
                meetingID: meetingID, revision: 3, names: ["incoming:SPEAKER_00": "Sean"], configuration: .bruce
            )
            XCTFail("A different name back must not count as saved")
        } catch {}
    }

    func testReviewRequestUsesResolvedArchiveDirectoryAndWorkerTimeout() throws {
        let path = "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/meeting-id"
        let request = try SpeakerReviewCommandBuilder.review(
            archivePath: path,
            revision: 7,
            configuration: .bruce
        )
        let command = try XCTUnwrap(request.arguments.last)

        XCTAssertEqual(command.components(separatedBy: "'review-speakers'").count - 1, 1)
        XCTAssertTrue(command.contains("'--archive-dir' '\(path)'"))
        XCTAssertTrue(command.contains("'--revision' '7'"))
        XCTAssertEqual(request.timeout, ArchiveTransferConfiguration.bruce.workerTimeout)
    }

    func testReviewRequiresSafeLocatedArchiveAndExpectedIdentity() throws {
        let meetingID = UUID()
        let valid = LocatedSpeakerArchive(
            schemaVersion: 1,
            meetingID: meetingID,
            archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/2026/09/\(meetingID.uuidString.lowercased())"
        )
        XCTAssertNoThrow(try valid.validate(meetingID: meetingID, configuration: .bruce))

        let traversal = LocatedSpeakerArchive(
            schemaVersion: 1,
            meetingID: meetingID,
            archivePath: "/Volumes/CannMedia/MeetingArchive/meetings/../incoming/bad"
        )
        XCTAssertThrowsError(try traversal.validate(meetingID: meetingID, configuration: .bruce))
    }

    func testPlaybackRangeRejectsInvalidAndClampsNegativeStart() {
        XCTAssertEqual(SpeakerPlaybackRange(start: -2, end: 4)?.start, 0)
        XCTAssertEqual(SpeakerPlaybackRange(start: -2, end: 4)?.end, 4)
        XCTAssertNil(SpeakerPlaybackRange(start: 4, end: 4))
        XCTAssertNil(SpeakerPlaybackRange(start: .nan, end: 5))
    }

    @MainActor
    func testNativePlayerSurfaceAttachesAndDetachesPlayer() {
        let player = AVPlayer()
        let view = SpeakerPlayerSurface.make(player: player)

        XCTAssertTrue(view.player === player)
        XCTAssertEqual(view.controlsStyle, .inline)

        SpeakerPlayerSurface.dismantle(view)

        XCTAssertNil(view.player)
        XCTAssertEqual(player.rate, 0)
    }

    @MainActor
    func testLatePlaybackFetchCannotStartAfterReviewStops() async {
        let meetingID = UUID()
        let client = ControlledPlaybackReviewClient(meetingID: meetingID)
        let model = makeModel(meetingID: meetingID, client: client)
        let excerpt = SpeakerReviewExcerpt(
            start: 0,
            end: 1,
            text: "fixture",
            channelOrigin: "system",
            playbackPath: "playback/meeting.mp4"
        )

        let play = Task { await model.play(excerpt, speakerID: "pending") }
        await client.waitUntilFetchStarted()
        model.stopPlayback()
        await client.finishFetch()
        await play.value

        XCTAssertNil(model.player)
        XCTAssertNil(model.playbackStatus)
        XCTAssertFalse(model.isFetchingPlayback)
    }

    @MainActor
    func testLoadPutsVoicesThatNeedMikeFirstAndRestoresSavedNames() async {
        let meetingID = UUID()
        let model = makeModel(meetingID: meetingID, client: StubSpeakerReviewClient(response: makeResponse(
            meetingID: meetingID,
            speakers: [
                makeSpeaker(id: "saved", name: "Michael"),
                makeSpeaker(id: "recognized", automaticName: "Mike Cann", suggestionKind: "strong", confirmationCount: 3),
                makeSpeaker(id: "suggested", suggestion: "Alex", suggestionKind: "tentative"),
                makeSpeaker(id: "unknown"),
            ]
        )))

        await model.load()

        XCTAssertEqual(model.cards.map(\.speakerIDs), [["suggested"], ["unknown"], ["recognized"], ["saved"]])
        XCTAssertEqual(model.cards.map { model.status(of: $0) }, [.suggested, .unknown, .recognized, .saved])
        XCTAssertEqual(model.savedNames, ["saved": "Michael"])
        XCTAssertEqual(model.namesToSave, ["recognized": "Mike Cann", "suggested": "Alex"])
    }

    /// One click: everything filled in is saved, whoever filled it in.
    @MainActor
    func testOneSaveSendsEveryFilledInNameAndLeavesBlanksUnknown() async throws {
        let meetingID = UUID()
        let client = StubSpeakerReviewClient(response: makeResponse(
            meetingID: meetingID,
            speakers: [
                makeSpeaker(id: "saved", name: "Michael"),
                makeSpeaker(id: "recognized", automaticName: "Mike Cann", suggestionKind: "own_microphone"),
                makeSpeaker(id: "suggested", suggestion: "Alex", suggestionKind: "tentative"),
                makeSpeaker(id: "split-a"),
                makeSpeaker(id: "split-b"),
                makeSpeaker(id: "unknown"),
            ]
        ))
        var changes = 0
        let model = makeModel(meetingID: meetingID, client: client, onReviewChanged: { changes += 1 })
        await model.load()
        let first = try XCTUnwrap(model.card(containing: "split-a"))
        let second = try XCTUnwrap(model.card(containing: "split-b"))
        model.setName("Micah", forCard: first.id)
        model.setName("Micah", forCard: second.id)

        let finished = await model.save()

        XCTAssertTrue(finished)
        let calls = await client.savedNameCalls()
        XCTAssertEqual(calls, [[
            "recognized": "Mike Cann", "suggested": "Alex", "split-a": "Micah", "split-b": "Micah",
        ]])
        XCTAssertEqual(model.card(containing: "split-a")?.speakerIDs, ["split-a", "split-b"])
        XCTAssertEqual(model.cards.filter { model.status(of: $0) == .saved }.count, 4)
        XCTAssertNil(model.savedNames["unknown"])
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.card(containing: "unknown"))), .unknown)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(model.failure)
    }

    @MainActor
    func testTypingAnotherCardsNameMergesThemOnlyOnceTheNameIsFinished() async throws {
        let meetingID = UUID()
        let model = makeModel(meetingID: meetingID, client: StubSpeakerReviewClient(response: makeResponse(
            meetingID: meetingID,
            speakers: [makeSpeaker(id: "a", name: "Micah"), makeSpeaker(id: "b"), makeSpeaker(id: "c")]
        )))
        await model.load()
        let typed = try XCTUnwrap(model.card(containing: "b"))

        model.setName("MICAH", forCard: typed.id)
        XCTAssertEqual(model.cards.count, 3, "cards must not jump about while Mike types")

        model.commitName(forCard: typed.id)

        XCTAssertEqual(model.cards.count, 2)
        let merged = try XCTUnwrap(model.card(containing: "a"))
        XCTAssertEqual(merged.speakerIDs, ["b", "a"])
        XCTAssertEqual(merged.name, "Micah", "the name already there keeps its spelling")
        XCTAssertEqual(model.cards.first?.id, merged.id, "the merged card takes the earlier place")
        XCTAssertEqual(model.namesToSave, ["b": "Micah"])
    }

    @MainActor
    func testChoosingACalendarAttendeeMergesStraightAway() async throws {
        let meetingID = UUID()
        let model = makeModel(meetingID: meetingID, client: StubSpeakerReviewClient(response: makeResponse(
            meetingID: meetingID,
            speakers: [makeSpeaker(id: "a", suggestion: "Priya Shah", suggestionKind: "tentative"), makeSpeaker(id: "b")]
        )))
        await model.load()

        model.chooseName("Priya Shah", forCard: try XCTUnwrap(model.card(containing: "b")).id)

        XCTAssertEqual(model.cards.map(\.speakerIDs), [["a", "b"]])
    }

    @MainActor
    func testSeparatingAVoiceGivesItABlankCardThatSaveLeavesAlone() async throws {
        let meetingID = UUID()
        let client = StubSpeakerReviewClient(response: makeResponse(
            meetingID: meetingID,
            speakers: [
                makeSpeaker(id: "a", suggestion: "Sean", suggestionKind: "tentative"),
                makeSpeaker(id: "b", suggestion: "Sean", suggestionKind: "tentative"),
            ]
        ))
        let model = makeModel(meetingID: meetingID, client: client)
        await model.load()
        XCTAssertEqual(model.cards.count, 1)

        model.separate("b")

        XCTAssertEqual(model.cards.map(\.speakerIDs), [["a"], ["b"]])
        XCTAssertEqual(model.card(containing: "b")?.name, "")
        _ = await model.save()
        let calls = await client.savedNameCalls()
        XCTAssertEqual(calls, [["a": "Sean"]])
    }

    @MainActor
    func testFailedSaveMarksNothingSavedAndTheSameClickRetries() async throws {
        let meetingID = UUID()
        let client = StubSpeakerReviewClient(
            response: makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "pending", suggestion: "Alex")]),
            failures: 1
        )
        var changes = 0
        let model = makeModel(meetingID: meetingID, client: client, onReviewChanged: { changes += 1 })
        await model.load()

        let failed = await model.save()

        XCTAssertFalse(failed)
        XCTAssertNotNil(model.failure)
        XCTAssertEqual(model.savedNames, [:])
        XCTAssertEqual(model.namesToSave, ["pending": "Alex"])
        XCTAssertEqual(changes, 0)

        let retried = await model.save()

        XCTAssertTrue(retried)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.savedNames, ["pending": "Alex"])
        XCTAssertEqual(changes, 1)
    }

    @MainActor
    func testANameEditedWhileSavingStaysToBeSaved() async throws {
        let meetingID = UUID()
        let client = ControlledSpeakerReviewClient(
            response: makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "pending", suggestion: "Alex")])
        )
        let model = makeModel(meetingID: meetingID, client: client)
        await model.load()
        let card = try XCTUnwrap(model.cards.first)

        let saving = Task { await model.save() }
        await client.waitUntilSaveStarted()
        XCTAssertFalse(model.canSave)
        model.setName("Alicia", forCard: card.id)
        await client.finishSave()
        let finished = await saving.value

        XCTAssertFalse(finished)
        XCTAssertEqual(model.savedNames, ["pending": "Alex"])
        XCTAssertEqual(model.namesToSave, ["pending": "Alicia"])
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.cards.first)), .typed)
        XCTAssertTrue(model.canSave)
    }

    @MainActor
    func testNothingToSaveClosesWithoutAskingBruce() async {
        let meetingID = UUID()
        let client = StubSpeakerReviewClient(response: makeResponse(
            meetingID: meetingID,
            speakers: [makeSpeaker(id: "saved", name: "Michael"), makeSpeaker(id: "unknown")]
        ))
        let model = makeModel(meetingID: meetingID, client: client)
        await model.load()

        let finished = await model.save()

        XCTAssertTrue(finished)
        let calls = await client.savedNameCalls()
        XCTAssertEqual(calls, [])
    }

    @MainActor
    func testClearingASavedNameDoesNotUnsaveItAndRenamingSavesTheNewName() async throws {
        let meetingID = UUID()
        let client = StubSpeakerReviewClient(
            response: makeResponse(meetingID: meetingID, speakers: [makeSpeaker(id: "saved", name: "Michael")])
        )
        let model = makeModel(meetingID: meetingID, client: client)
        await model.load()
        let card = try XCTUnwrap(model.cards.first)

        model.setName("", forCard: card.id)
        XCTAssertEqual(model.namesToSave, [:])
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.cards.first)), .unknown)

        model.setName("Mike", forCard: card.id)
        XCTAssertEqual(model.status(of: try XCTUnwrap(model.cards.first)), .typed)
        let finished = await model.save()

        XCTAssertTrue(finished)
        let calls = await client.savedNameCalls()
        XCTAssertEqual(calls, [["saved": "Mike"]])
        XCTAssertEqual(model.savedNames, ["saved": "Mike"])
    }

    @MainActor
    func testZeroSpeakerReviewCanBeSavedOnlyOnceItLoads() async {
        let meetingID = UUID()
        let model = makeModel(
            meetingID: meetingID,
            client: StubSpeakerReviewClient(response: makeResponse(meetingID: meetingID, speakers: []))
        )

        XCTAssertFalse(model.canSave)
        let early = await model.save()
        XCTAssertFalse(early)

        await model.load()

        XCTAssertTrue(model.canSave)
        let finished = await model.save()
        XCTAssertTrue(finished)
    }

    @MainActor
    private func makeModel(
        meetingID: UUID,
        client: any SpeakerReviewServing,
        onReviewChanged: @escaping () -> Void = {}
    ) -> SpeakerReviewModel {
        SpeakerReviewModel(
            meetingID: meetingID,
            revision: 3,
            configuration: .bruce,
            client: client,
            onReviewChanged: onReviewChanged
        )
    }

    private func makeResponse(
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

    private func makeSpeaker(
        id: String,
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

private func savedResponse(meetingID: UUID, revision: Int, names: [String: String]) -> SavedSpeakerNamesResponse {
    SavedSpeakerNamesResponse(
        schemaVersion: 1,
        meetingID: meetingID,
        manifestRevision: revision,
        speakers: names.sorted { $0.key < $1.key }.map {
            .init(speakerID: $0.key, name: $0.value.trimmingCharacters(in: .whitespacesAndNewlines), voiceProfileEnrolled: true)
        }
    )
}

private actor RecordingProcessRunner: ArchiveProcessRunning {
    let stdout: Data

    init(stdout: Data) { self.stdout = stdout }

    func run(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        ArchiveProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

private actor StubSpeakerReviewClient: SpeakerReviewServing {
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
            throw SpeakerReviewError.invalidResponse("Bruce is unavailable")
        }
        return savedResponse(meetingID: meetingID, revision: revision, names: names)
    }

    func savedNameCalls() -> [[String: String]] { calls }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        destination
    }
}

private actor ControlledSpeakerReviewClient: SpeakerReviewServing {
    let response: SpeakerReviewResponse
    private var saveStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(response: SpeakerReviewResponse) {
        self.response = response
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
        saveStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { finishContinuation = $0 }
        return savedResponse(meetingID: meetingID, revision: revision, names: names)
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
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        destination
    }
}

private actor ControlledPlaybackReviewClient: SpeakerReviewServing {
    let meetingID: UUID
    private var fetchStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<URL, Error>?

    init(meetingID: UUID) { self.meetingID = meetingID }

    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse {
        SpeakerReviewResponse(
            schemaVersion: 1,
            meetingID: meetingID,
            manifestRevision: revision,
            speakers: [],
            calendarCandidates: []
        )
    }

    func saveNames(
        meetingID: UUID,
        revision: Int,
        names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) async throws -> SavedSpeakerNamesResponse {
        throw SpeakerReviewError.invalidResponse("saving is not part of this fixture")
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
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
