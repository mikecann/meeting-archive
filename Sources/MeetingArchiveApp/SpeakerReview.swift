import AVFoundation
import AVKit
import Combine
import Foundation
import MeetingArchiveCore
import SwiftUI

struct SpeakerReviewResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var meetingID: UUID
    var manifestRevision: Int
    var speakers: [SpeakerReviewSpeaker]
    var calendarCandidates: [SpeakerCalendarCandidate]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case speakers
        case calendarCandidates = "calendar_candidates"
    }

    func validate(meetingID expectedMeetingID: UUID, revision expectedRevision: Int) throws {
        guard schemaVersion == 1, meetingID == expectedMeetingID, manifestRevision == expectedRevision else {
            throw SpeakerReviewError.invalidResponse("review-speakers returned the wrong meeting or revision")
        }
        guard Set(speakers.map(\.speakerID)).count == speakers.count else {
            throw SpeakerReviewError.invalidResponse("review-speakers returned duplicate speaker IDs")
        }
        for speaker in speakers {
            guard !speaker.speakerID.isEmpty else {
                throw SpeakerReviewError.invalidResponse("review-speakers returned an empty speaker ID")
            }
            for excerpt in speaker.excerpts {
                guard SpeakerPlaybackRange(start: excerpt.start, end: excerpt.end) != nil else {
                    throw SpeakerReviewError.invalidResponse("review-speakers returned an invalid excerpt range")
                }
            }
        }
    }
}

struct SpeakerReviewSpeaker: Codable, Equatable, Identifiable, Sendable {
    var speakerID: String
    var name: String?
    var suggestedName: String?
    var suggestionScore: Double?
    var suggestionMargin: Double?
    var embeddingAvailable: Bool
    var excerpts: [SpeakerReviewExcerpt]
    var automaticName: String? = nil
    /// "strong", "own_microphone" or "same_meeting" for an automatic name,
    /// "tentative" for a suggestion.
    var suggestionKind: String? = nil
    var confirmationCount: Int? = nil

    var id: String { speakerID }

    enum CodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case name
        case suggestedName = "suggested_name"
        case suggestionScore = "suggestion_score"
        case suggestionMargin = "suggestion_margin"
        case embeddingAvailable = "embedding_available"
        case excerpts
        case automaticName = "automatic_name"
        case suggestionKind = "suggestion_kind"
        case confirmationCount = "confirmation_count"
    }

    /// "Call audio, voice 2" for incoming:SPEAKER_01.
    var voiceLabel: String {
        let parts = speakerID.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let number = Int(parts[1].replacingOccurrences(of: "SPEAKER_", with: ""))
        else { return speakerID }
        let channel = switch parts[0] {
        case "incoming": "Call audio"
        case "microphone": "Your mic"
        default: parts[0]
        }
        return "\(channel), voice \(number + 1)"
    }
}

struct SpeakerReviewExcerpt: Codable, Equatable, Identifiable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var channelOrigin: String
    var playbackPath: String?

    var id: String { "\(start)-\(end)-\(text)" }

    enum CodingKeys: String, CodingKey {
        case start, end, text
        case channelOrigin = "channel_origin"
        case playbackPath = "playback_path"
    }
}

struct SpeakerCalendarCandidate: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var email: String?
    var responseStatus: String?
    var source: String?

    var id: String { "\(name)\u{0}\(email ?? "")" }

    enum CodingKeys: String, CodingKey {
        case name, email, source
        case responseStatus = "response_status"
    }
}

/// What identify-speakers saved: exactly the names it was sent.
struct SavedSpeakerNamesResponse: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var meetingID: UUID
    var manifestRevision: Int
    var speakers: [Speaker]

    struct Speaker: Codable, Equatable, Sendable {
        var speakerID: String
        var name: String
        var voiceProfileEnrolled: Bool

        enum CodingKeys: String, CodingKey {
            case speakerID = "speaker_id"
            case name
            case voiceProfileEnrolled = "voice_profile_enrolled"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case manifestRevision = "manifest_revision"
        case speakers
    }

    func validate(meetingID expectedMeetingID: UUID, revision expectedRevision: Int, names: [String: String]) throws {
        let saved = Dictionary(speakers.map { ($0.speakerID, $0.name) }, uniquingKeysWith: { first, _ in first })
        guard schemaVersion == 1,
              meetingID == expectedMeetingID,
              manifestRevision == expectedRevision,
              speakers.count == names.count,
              saved == names
        else {
            throw SpeakerReviewError.invalidResponse("identify-speakers returned different names from the ones sent")
        }
    }
}

struct LocatedSpeakerArchive: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var meetingID: UUID
    var archivePath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meetingID = "meeting_id"
        case archivePath = "archive_path"
    }

    func validate(meetingID expectedMeetingID: UUID, configuration: ArchiveTransferConfiguration) throws {
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        guard schemaVersion == 1,
              meetingID == expectedMeetingID,
              archivePath.hasPrefix(configuration.archiveRoot + "/"),
              !archivePath.contains(".."),
              archivePath.unicodeScalars.allSatisfy({ safeCharacters.contains($0) })
        else {
            throw SpeakerReviewError.invalidResponse("locate returned an unsafe archive path")
        }
    }
}

struct SpeakerPlaybackRange: Equatable, Sendable {
    var start: Double
    var end: Double

    init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite else { return nil }
        let clampedStart = max(0, start)
        guard end > clampedStart else { return nil }
        self.start = clampedStart
        self.end = end
    }
}

@MainActor
enum SpeakerPlayerSurface {
    static func make(player: AVPlayer) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        return view
    }

    static func update(_ view: AVPlayerView, player: AVPlayer) {
        if view.player !== player { view.player = player }
    }

    static func dismantle(_ view: AVPlayerView) {
        view.player?.pause()
        view.player = nil
    }
}

@MainActor
struct SpeakerPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        SpeakerPlayerSurface.make(player: player)
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        SpeakerPlayerSurface.update(view, player: player)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        SpeakerPlayerSurface.dismantle(view)
    }
}

/// One person in the review. pyannote often splits one person into several
/// voices; voices with the same name share a card, so naming it once names
/// them all.
struct SpeakerReviewCard: Identifiable, Equatable, Sendable {
    let id: UUID
    var speakerIDs: [String]
    var name: String

    init(id: UUID = UUID(), speakerIDs: [String], name: String) {
        self.id = id
        self.speakerIDs = speakerIDs
        self.name = name
    }

    /// A saved name first, then what Bruce recognized, then its suggestion.
    static func startingName(for speaker: SpeakerReviewSpeaker) -> String {
        for candidate in [speaker.name, speaker.automaticName, speaker.suggestedName] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return ""
    }

    /// Names that only differ by case, accents or spacing are one person.
    static func groupingKey(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// One card per name, in the order Bruce listed the voices. Every voice
    /// without a name gets a card of its own.
    static func make(speakers: [SpeakerReviewSpeaker]) -> [SpeakerReviewCard] {
        var cards: [SpeakerReviewCard] = []
        var cardForKey: [String: Int] = [:]
        for speaker in speakers {
            let name = startingName(for: speaker)
            let key = groupingKey(name)
            if !key.isEmpty, let index = cardForKey[key] {
                cards[index].speakerIDs.append(speaker.speakerID)
                continue
            }
            if !key.isEmpty { cardForKey[key] = cards.count }
            cards.append(SpeakerReviewCard(speakerIDs: [speaker.speakerID], name: name))
        }
        return cards
    }
}

/// How sure a card's name is, which decides what the card says about it.
enum SpeakerNameStatus: Equatable, Sendable {
    /// No name. Saving leaves these voices unknown.
    case unknown
    /// Every voice is saved on Bruce with this name.
    case saved
    /// Bruce named these voices from what it has heard before.
    case recognized
    /// Bruce's guess, filled in for checking.
    case suggested
    /// Mike typed or chose it.
    case typed
}

enum SpeakerReviewError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidResponse(String)
    case emptyName

    var description: String {
        switch self {
        case .invalidResponse(let message): message
        case .emptyName: "A speaker name to save was empty."
        }
    }

    var errorDescription: String? { description }
}

enum RemoteShellCommand {
    /// OpenSSH sends its trailing arguments through the remote login shell.
    /// Quote every argument before joining so names cannot become shell syntax.
    static func make(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum SpeakerReviewCommandBuilder {
    static func locate(
        meetingID: UUID,
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "locate",
                "--meeting-id", meetingID.uuidString.lowercased(),
                "--archive-root", configuration.archiveRoot,
                "--db", configuration.workerDatabase,
            ],
            timeout: configuration.commandTimeout,
            configuration: configuration
        )
    }

    static func review(
        archivePath: String,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        guard revision >= 1 else { throw SpeakerReviewError.invalidResponse("Revision must be at least one") }
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "review-speakers",
                "--archive-dir", archivePath,
                "--revision", String(revision),
                "--db", configuration.workerDatabase,
            ],
            timeout: configuration.workerTimeout,
            configuration: configuration
        )
    }

    /// Saves every name in one call, so they are saved together or not at all.
    static func saveNames(
        meetingID: UUID,
        revision: Int,
        names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) throws -> ArchiveProcessRequest {
        try configuration.validate()
        guard revision >= 1 else { throw SpeakerReviewError.invalidResponse("Revision must be at least one") }
        let trimmed = names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
            throw SpeakerReviewError.emptyName
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(trimmed), as: UTF8.self)
        return remoteRequest(
            arguments: workerPrefix(configuration) + [
                "identify-speakers",
                "--meeting-id", meetingID.uuidString.lowercased(),
                "--revision", String(revision),
                "--names", json,
                "--db", configuration.workerDatabase,
            ],
            // It rewrites the transcript like review-speakers does, so it
            // gets the same allowance; keepalives still end a dead connection.
            timeout: configuration.workerTimeout,
            configuration: configuration
        )
    }

    private static func workerPrefix(_ configuration: ArchiveTransferConfiguration) -> [String] {
        [configuration.workerPython, configuration.workerScript]
    }

    private static func remoteRequest(
        arguments: [String],
        timeout: TimeInterval,
        configuration: ArchiveTransferConfiguration
    ) -> ArchiveProcessRequest {
        ArchiveProcessRequest(
            executable: configuration.sshExecutable,
            arguments: configuration.sshOptions + [
                "--", configuration.host,
                RemoteShellCommand.make(arguments),
            ],
            timeout: timeout
        )
    }
}

protocol SpeakerReviewServing: Sendable {
    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse

    /// Saves Mike's names, keyed by speaker ID, all together.
    func saveNames(
        meetingID: UUID,
        revision: Int,
        names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) async throws -> SavedSpeakerNamesResponse

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL
}

actor SpeakerReviewClient: SpeakerReviewServing {
    private let processRunner: any ArchiveProcessRunning
    private let transfer: ArchiveTransfer

    init(processRunner: any ArchiveProcessRunning = FoundationArchiveProcessRunner()) {
        self.processRunner = processRunner
        transfer = ArchiveTransfer(processRunner: processRunner)
    }

    func load(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration
    ) async throws -> SpeakerReviewResponse {
        let locateResult = try await runChecked(
            SpeakerReviewCommandBuilder.locate(meetingID: meetingID, configuration: configuration)
        )
        let located: LocatedSpeakerArchive
        do {
            located = try ModelCodec.decoder.decode(LocatedSpeakerArchive.self, from: locateResult.stdout)
            try located.validate(meetingID: meetingID, configuration: configuration)
        } catch let error as SpeakerReviewError {
            throw error
        } catch {
            throw SpeakerReviewError.invalidResponse("Could not read locate response: \(error.localizedDescription)")
        }

        let reviewResult = try await runChecked(
            SpeakerReviewCommandBuilder.review(
                archivePath: located.archivePath,
                revision: revision,
                configuration: configuration
            )
        )
        do {
            let response = try ModelCodec.decoder.decode(SpeakerReviewResponse.self, from: reviewResult.stdout)
            try response.validate(meetingID: meetingID, revision: revision)
            return response
        } catch let error as SpeakerReviewError {
            throw error
        } catch {
            throw SpeakerReviewError.invalidResponse("Could not read speaker review: \(error.localizedDescription)")
        }
    }

    func saveNames(
        meetingID: UUID,
        revision: Int,
        names: [String: String],
        configuration: ArchiveTransferConfiguration
    ) async throws -> SavedSpeakerNamesResponse {
        let result = try await runChecked(
            SpeakerReviewCommandBuilder.saveNames(
                meetingID: meetingID,
                revision: revision,
                names: names,
                configuration: configuration
            )
        )
        let response: SavedSpeakerNamesResponse
        do {
            response = try ModelCodec.decoder.decode(SavedSpeakerNamesResponse.self, from: result.stdout)
        } catch {
            throw SpeakerReviewError.invalidResponse("Could not read the saved names: \(error.localizedDescription)")
        }
        try response.validate(
            meetingID: meetingID,
            revision: revision,
            names: names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
        return response
    }

    func fetchPlayback(
        meetingID: UUID,
        destination: URL,
        configuration: ArchiveTransferConfiguration
    ) async throws -> URL {
        try await transfer.fetch(
            relativePath: "playback/meeting.mp4",
            meetingID: meetingID,
            destination: destination,
            configuration: configuration
        )
    }

    private func runChecked(_ request: ArchiveProcessRequest) async throws -> ArchiveProcessResult {
        let result = try await processRunner.run(request)
        guard result.exitCode == 0 else {
            throw ArchiveTransferError.commandFailed(
                executable: request.executable.path,
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result
    }
}

@MainActor
final class SpeakerReviewModel: ObservableObject {
    @Published private(set) var response: SpeakerReviewResponse?
    @Published private(set) var cards: [SpeakerReviewCard] = []
    /// The name Bruce holds for each voice. Only a load or a successful save
    /// changes it, so nothing shows as saved unless Bruce said so.
    @Published private(set) var savedNames: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var playbackStatus: String?
    @Published var failure: String?
    @Published private(set) var player: AVPlayer?

    let meetingID: UUID
    let revision: Int
    private let configuration: ArchiveTransferConfiguration
    private let client: any SpeakerReviewServing
    private let onReviewChanged: () -> Void
    private var playbackURL: URL?
    private var playbackTask: Task<Void, Never>?
    private var playbackFetchTask: Task<URL, Error>?
    private var playbackGeneration = 0
    @Published private(set) var isFetchingPlayback = false

    /// The names Save names sends: every voice in a named card that Bruce
    /// doesn't already hold under that name. Blank cards stay unknown.
    var namesToSave: [String: String] {
        var names: [String: String] = [:]
        for card in cards {
            let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            for speakerID in card.speakerIDs where savedNames[speakerID] != name {
                names[speakerID] = name
            }
        }
        return names
    }

    var canSave: Bool { response != nil && !isLoading && !isSaving }

    init(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration,
        client: any SpeakerReviewServing = SpeakerReviewClient(),
        onReviewChanged: @escaping () -> Void = {}
    ) {
        self.meetingID = meetingID
        self.revision = revision
        self.configuration = configuration
        self.client = client
        self.onReviewChanged = onReviewChanged
    }

    deinit { playbackTask?.cancel() }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            let response = try await client.load(
                meetingID: meetingID,
                revision: revision,
                configuration: configuration
            )
            self.response = response
            savedNames = Dictionary(
                response.speakers.compactMap { speaker in
                    speaker.name.map { (speaker.speakerID, $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }.filter { !$0.1.isEmpty },
                uniquingKeysWith: { first, _ in first }
            )
            // Whatever still needs Mike goes first. The order then stays put
            // while he types.
            let cards = SpeakerReviewCard.make(speakers: response.speakers)
            self.cards = cards.enumerated().sorted { left, right in
                let leftRank = Self.rank(status(of: left.element))
                let rightRank = Self.rank(status(of: right.element))
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }.map(\.element)
        } catch {
            failure = error.localizedDescription
        }
    }

    func speaker(_ speakerID: String) -> SpeakerReviewSpeaker? {
        response?.speakers.first { $0.speakerID == speakerID }
    }

    func card(containing speakerID: String) -> SpeakerReviewCard? {
        cards.first { $0.speakerIDs.contains(speakerID) }
    }

    func status(of card: SpeakerReviewCard) -> SpeakerNameStatus {
        let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .unknown }
        let unsaved = card.speakerIDs.filter { savedNames[$0] != name }
        guard !unsaved.isEmpty else { return .saved }
        let speakers = unsaved.compactMap(speaker)
        let trimmed = { (value: String?) in value?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if speakers.count == unsaved.count, speakers.allSatisfy({ trimmed($0.automaticName) == name }) {
            return .recognized
        }
        if speakers.contains(where: { trimmed($0.suggestedName) == name && trimmed($0.automaticName) != name }) {
            return .suggested
        }
        return .typed
    }

    /// Changes a card's name while Mike types. Cards merge once he's done.
    func setName(_ name: String, forCard cardID: SpeakerReviewCard.ID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        cards[index].name = name
    }

    /// Once a name is finished, a card with the same name as another is the
    /// same person, so the two become one card under the name already there.
    func commitName(forCard cardID: SpeakerReviewCard.ID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        let key = SpeakerReviewCard.groupingKey(cards[index].name)
        guard !key.isEmpty,
              let other = cards.firstIndex(where: { $0.id != cardID && SpeakerReviewCard.groupingKey($0.name) == key })
        else { return }
        var merged = cards[other]
        merged.speakerIDs = index < other
            ? cards[index].speakerIDs + cards[other].speakerIDs
            : cards[other].speakerIDs + cards[index].speakerIDs
        let position = min(index, other)
        cards.removeAll { $0.id == cardID || $0.id == merged.id }
        cards.insert(merged, at: position)
    }

    func chooseName(_ name: String, forCard cardID: SpeakerReviewCard.ID) {
        setName(name, forCard: cardID)
        commitName(forCard: cardID)
    }

    /// Takes a voice out of its card when it isn't that person after all. It
    /// starts without a name.
    func separate(_ speakerID: String) {
        guard let index = cards.firstIndex(where: { $0.speakerIDs.contains(speakerID) }),
              cards[index].speakerIDs.count > 1
        else { return }
        cards[index].speakerIDs.removeAll { $0 == speakerID }
        cards.insert(SpeakerReviewCard(speakerIDs: [speakerID], name: ""), at: index + 1)
    }

    /// Saves every filled-in name in one go: typed, chosen, suggested or
    /// recognized. Returns true once nothing is left to save.
    @discardableResult
    func save() async -> Bool {
        guard response != nil, !isLoading, !isSaving else { return false }
        mergeCardsWithTheSameName()
        let names = namesToSave
        guard !names.isEmpty else {
            failure = nil
            return true
        }
        isSaving = true
        failure = nil
        defer { isSaving = false }
        do {
            let saved = try await client.saveNames(
                meetingID: meetingID,
                revision: revision,
                names: names,
                configuration: configuration
            )
            for speaker in saved.speakers {
                savedNames[speaker.speakerID] = speaker.name
            }
            onReviewChanged()
            // A name edited while this was in flight is still waiting.
            return namesToSave.isEmpty
        } catch {
            failure = error.localizedDescription
            return false
        }
    }

    private func mergeCardsWithTheSameName() {
        for card in cards where cards.contains(where: { $0.id == card.id }) {
            commitName(forCard: card.id)
        }
    }

    private static func rank(_ status: SpeakerNameStatus) -> Int {
        switch status {
        case .unknown, .suggested: 0
        case .typed, .recognized: 1
        case .saved: 2
        }
    }

    func play(_ excerpt: SpeakerReviewExcerpt, speakerID: String) async {
        guard excerpt.playbackPath != nil,
              let range = SpeakerPlaybackRange(start: excerpt.start, end: excerpt.end)
        else {
            playbackStatus = "This excerpt has text but no generated playback file."
            return
        }
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playbackTask?.cancel()
        playbackTask = nil
        do {
            let url = try await localPlaybackURL()
            guard generation == playbackGeneration else { return }
            let player = player ?? AVPlayer(url: url)
            self.player = player
            player.pause()
            await player.seek(to: CMTime(seconds: range.start, preferredTimescale: 600))
            guard generation == playbackGeneration else { return }
            player.play()
            let voice = speaker(speakerID)?.voiceLabel ?? speakerID
            playbackStatus = "Playing \(voice) from \(formatTime(range.start)) to \(formatTime(range.end))"
            playbackTask = Task { [weak self, weak player] in
                try? await Task.sleep(for: .seconds(range.end - range.start))
                guard !Task.isCancelled, self?.playbackGeneration == generation else { return }
                player?.pause()
                self?.playbackStatus = nil
            }
        } catch {
            guard generation == playbackGeneration else { return }
            failure = error.localizedDescription
        }
    }

    func stopPlayback() {
        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        playbackFetchTask?.cancel()
        player?.pause()
        player = nil
        playbackStatus = nil
    }

    private func localPlaybackURL() async throws -> URL {
        if let playbackURL { return playbackURL }
        if let playbackFetchTask { return try await playbackFetchTask.value }
        // Cached across reviews: the full playback file used to be fetched
        // into a fresh temporary copy every time a review opened.
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Archive/playback", isDirectory: true)
            .appendingPathComponent(meetingID.uuidString.lowercased(), isDirectory: true)
        let destination = directory.appendingPathComponent("meeting.mp4")
        if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
            playbackURL = destination
            return destination
        }
        playbackStatus = "Fetching the archived playback…"
        isFetchingPlayback = true
        let task = Task { [client, configuration, meetingID] in
            try await client.fetchPlayback(
                meetingID: meetingID,
                destination: destination,
                configuration: configuration
            )
        }
        playbackFetchTask = task
        defer {
            playbackFetchTask = nil
            isFetchingPlayback = false
        }
        let result = try await task.value
        playbackURL = result
        return result
    }

    private func formatTime(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}

@MainActor
struct SpeakerReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SpeakerReviewModel
    @FocusState private var focusedCard: SpeakerReviewCard.ID?
    private let onComplete: () -> Void
    private let onLater: () -> Void

    init(
        meetingID: UUID,
        revision: Int,
        configuration: ArchiveTransferConfiguration,
        client: any SpeakerReviewServing = SpeakerReviewClient(),
        onComplete: @escaping () -> Void = {},
        onReviewChanged: @escaping () -> Void = {},
        onLater: @escaping () -> Void = {}
    ) {
        self.onComplete = onComplete
        self.onLater = onLater
        _model = StateObject(
            wrappedValue: SpeakerReviewModel(
                meetingID: meetingID,
                revision: revision,
                configuration: configuration,
                client: client,
                onReviewChanged: onReviewChanged
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.response == nil {
                    ProgressView("Loading speaker samples…")
                } else if let response = model.response {
                    reviewList(response)
                } else {
                    ContentUnavailableView(
                        "Speaker review unavailable",
                        systemImage: "person.wave.2",
                        description: Text(model.failure ?? "The archived speaker analysis could not be loaded.")
                    )
                }
            }
            .navigationTitle("Review speakers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") {
                        model.stopPlayback()
                        onLater()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.response == nil && !model.isLoading {
                        Button("Try again") { Task { await model.load() } }
                    }
                    if model.isSaving {
                        ProgressView().controlSize(.small)
                    }
                    Button("Save names") {
                        focusedCard = nil
                        Task {
                            guard await model.save() else { return }
                            model.stopPlayback()
                            onComplete()
                            dismiss()
                        }
                    }
                    .disabled(!model.canSave)
                    .help("Saves every name filled in. Anyone left blank stays unknown.")
                }
            }
        }
        .frame(minWidth: 620, minHeight: 560)
        .task { if model.response == nil { await model.load() } }
        .onDisappear { model.stopPlayback() }
        .onChange(of: focusedCard) { previous, _ in
            if let previous { model.commitName(forCard: previous) }
        }
    }

    private func reviewList(_ response: SpeakerReviewResponse) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Check the names and fill in anyone you know, then choose Save names. Voices with the same name are saved as one person, and anyone left blank stays unknown.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }

                if let player = model.player {
                    SpeakerPlayerView(player: player)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let status = model.playbackStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                if response.speakers.isEmpty {
                    ContentUnavailableView(
                        "No speakers found",
                        systemImage: "person.slash",
                        description: Text("The archived transcript has no speaker tracks to review.")
                    )
                }

                ForEach(model.cards) { card in
                    speakerCard(card, candidates: response.calendarCandidates)
                }
            }
            .padding(20)
        }
    }

    private func speakerCard(
        _ card: SpeakerReviewCard,
        candidates: [SpeakerCalendarCandidate]
    ) -> some View {
        let status = model.status(of: card)
        let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name.isEmpty ? "Unknown voice" : name).font(.headline)
                if card.speakerIDs.count > 1 {
                    Text("· \(card.speakerIDs.count) voices").foregroundStyle(.secondary)
                }
                statusBadge(status)
                Spacer()
            }

            TextField(
                "Name",
                text: Binding(
                    get: { model.cards.first { $0.id == card.id }?.name ?? "" },
                    set: { model.setName($0, forCard: card.id) }
                )
            )
            .focused($focusedCard, equals: card.id)
            .onSubmit { model.commitName(forCard: card.id) }
            .disabled(model.isSaving)

            if let caption = caption(for: card, status: status) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Attendees help with a voice nobody has named yet. A saved or
            // recognized name can still be typed over.
            if !candidates.isEmpty, status != .saved, status != .recognized {
                Menu("Choose a calendar attendee") {
                    ForEach(candidates) { candidate in
                        Button(candidateLabel(candidate)) {
                            model.chooseName(candidate.name, forCard: card.id)
                        }
                    }
                }
                .disabled(model.isSaving)
            }

            ForEach(card.speakerIDs, id: \.self) { speakerID in
                voiceSamples(speakerID, in: card)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statusBadge(_ status: SpeakerNameStatus) -> some View {
        switch status {
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .recognized:
            Label("Recognized", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .suggested:
            Label("Suggested", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
        case .typed, .unknown:
            EmptyView()
        }
    }

    private func voiceSamples(_ speakerID: String, in card: SpeakerReviewCard) -> some View {
        let speaker = model.speaker(speakerID)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(speaker?.voiceLabel ?? speakerID)
                    .font(.subheadline.weight(.semibold))
                    .help(speakerID)
                Spacer()
                if card.speakerIDs.count > 1 {
                    let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Button(name.isEmpty ? "Separate" : "Not \(name)") { model.separate(speakerID) }
                        .buttonStyle(.link)
                        .disabled(model.isSaving)
                        .help("Gives this voice a card of its own")
                }
            }
            if let excerpts = speaker?.excerpts, !excerpts.isEmpty {
                ForEach(excerpts) { excerpt in
                    HStack(alignment: .top, spacing: 10) {
                        Button {
                            Task { await model.play(excerpt, speakerID: speakerID) }
                        } label: {
                            Image(systemName: "play.circle.fill").font(.title2)
                        }
                        .buttonStyle(.plain)
                        .disabled(excerpt.playbackPath == nil || model.isFetchingPlayback)
                        .help(excerpt.playbackPath == nil ? "Playback has not been generated" : "Play this excerpt")

                        VStack(alignment: .leading, spacing: 3) {
                            Text(excerpt.text).textSelection(.enabled)
                            Text("\(formatTime(excerpt.start))–\(formatTime(excerpt.end))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("No excerpt is available for this voice.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private func caption(for card: SpeakerReviewCard, status: SpeakerNameStatus) -> String? {
        let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsaved = card.speakerIDs.filter { model.savedNames[$0] != name }.compactMap(model.speaker)
        switch status {
        case .unknown:
            if let saved = card.speakerIDs.compactMap({ model.savedNames[$0] }).first {
                return "Saved as \(saved). Type another name to change it."
            }
            return "Leave it blank if you don't know who this is."
        case .saved:
            return nil
        case .recognized:
            let kinds = Set(unsaved.compactMap(\.suggestionKind))
            if kinds == ["own_microphone"] {
                return "Your mic, recognized from your voice."
            }
            if kinds == ["same_meeting"] {
                return "Sounds like the \(name) you saved in this meeting."
            }
            let count = unsaved.compactMap(\.confirmationCount).max() ?? 0
            return count > 0
                ? "Recognized from \(count) earlier \(count == 1 ? "meeting" : "meetings")."
                : "Recognized from a voice you saved before."
        case .suggested:
            let count = unsaved.compactMap(\.confirmationCount).max() ?? 0
            let evidence = count > 1 ? ", going by \(count) earlier meetings" : ""
            return "Possibly \(name)\(evidence). Change it or clear it if that's wrong."
        case .typed:
            return "Saved when you choose Save names."
        }
    }

    private func candidateLabel(_ candidate: SpeakerCalendarCandidate) -> String {
        guard let email = candidate.email, !email.isEmpty else { return candidate.name }
        return "\(candidate.name) (\(email))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let rounded = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
