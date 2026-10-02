import CryptoKit
import Foundation
import MeetingArchiveCore

/// A capture that can never be archived as recorded. Its job stops retrying,
/// and its folder stays on this Mac.
enum UnarchivableCapture: LocalizedError, Equatable {
    /// Capture stopped before any audio or video reached a file. Bruce refuses
    /// a bundle with no media, so a retry could never succeed.
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .nothingRecorded: "No audio or video was recorded."
        }
    }
}

/// What a failed upload does to its job. Most failures mean Bruce is out of
/// reach, so the job backs off and tries again.
enum UploadFailure: Equatable {
    case retry(after: TimeInterval)
    case permanent(reason: String)

    init(_ error: Error, attempt: Int) {
        if let unarchivable = error as? UnarchivableCapture {
            self = .permanent(reason: unarchivable.localizedDescription)
        } else {
            self = .retry(after: min(3600, 30 * pow(2, Double(min(attempt, 7)))))
        }
    }
}

enum SpoolBundle {
    static let sources: [(String, ManifestFileKind)] = [("meeting-view.mov", .video), ("microphone.m4a", .microphoneAudio), ("incoming.m4a", .incomingAudio)]

    /// Every media file the capture left, each a real, non-empty file. Recovery
    /// measures these even when the microphone never started.
    static func mediaFiles(in directory: URL) throws -> [(URL, ManifestFileKind)] {
        try sources.compactMap { name, kind -> (URL, ManifestFileKind)? in
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw CaptureFailure.message("Capture contains an unsafe or empty media file: \(name)")
            }
            return (url, kind)
        }
    }

    /// Finalized inputs become immutable before transfer. Retries reuse the
    /// manifest bytes, rather than changing metadata under an in-flight upload.
    static func prepare(record: MeetingRecord, directory: URL) throws -> TransferManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let manifest = try ModelCodec.decoder.decode(TransferManifest.self, from: Data(contentsOf: manifestURL))
            try manifest.validate()
            guard manifest.meetingID == record.id, manifest.revision == record.metadataRevision else {
                throw CaptureFailure.message("The queued manifest does not match this meeting revision.")
            }
            return manifest
        }
        let media = try mediaFiles(in: directory)
        // A capture whose microphone never started is archived with the tracks
        // it has. One with no media at all stops here, before anything is written.
        guard !media.isEmpty else { throw UnarchivableCapture.nothingRecorded }
        let base = WorkerMeetingMetadata(meetingID: record.id, manifestRevision: record.metadataRevision, startedAt: record.startedAt, endedAt: record.endedAt, durationSeconds: record.endedAt.timeIntervalSince(record.startedAt), timezone: record.timezoneIdentifier, sourceApp: record.sourceApplication.bundleIdentifier)
        try base.validate()
        var metadata = try JSONSerialization.jsonObject(with: base.canonicalData()) as! [String: Any]
        metadata["title"] = record.title
        // Bruce only replaces a "default" title with an AI one. Without a
        // source, as on older records, it goes by the app's default pattern.
        if let titleSource = record.titleSource {
            metadata["title_source"] = titleSource.rawValue
        }
        metadata["capture"] = try JSONSerialization.jsonObject(with: ModelCodec.encoder.encode(record))
        // Calendar attendees remain suggestions for the voice review UI.
        for (filename, key) in [("calendar.json", "calendar"), ("tracks.json", "tracks")] {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) {
                metadata[key] = try JSONSerialization.jsonObject(with: data)
            }
        }
        // The worker suggests names from top-level "attendees". v1 only wrote
        // every nearby event under "calendar", so suggestions never arrived.
        // An empty list says "no match"; leaving it out would let the worker
        // fall back to a lone nearby event that isn't this meeting.
        metadata["attendees"] = try JSONSerialization.jsonObject(with: ModelCodec.encoder.encode(matchedAttendees(in: directory, record: record)))
        let metadataURL = directory.appendingPathComponent("metadata.json")
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: metadataURL, options: .atomic)
        let files = try (media + [(metadataURL, .metadata)]).map { url, kind in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ManifestFile(path: url.lastPathComponent, sizeBytes: (attributes[.size] as! NSNumber).int64Value, sha256: try hash(url), kind: kind)
        }
        let manifest = TransferManifest(meetingID: record.id, revision: record.metadataRevision, files: files)
        try manifest.validate()
        try manifest.canonicalData().write(to: manifestURL, options: .atomic)
        return manifest
    }

    /// The events around a call, and the one it matched, if any. The title
    /// came from that match, so the attendees do too. Ranking again against
    /// the part's end would count the release grace after the call.
    static func saveCalendar(_ events: [CalendarSuggestion], match: CalendarSuggestion?, in directory: URL) throws {
        try ModelCodec.encoder.encode(events).write(to: directory.appendingPathComponent("calendar.json"), options: .atomic)
        try ModelCodec.encoder.encode(CalendarMatch(eventID: match?.id))
            .write(to: directory.appendingPathComponent(calendarMatchName), options: .atomic)
    }

    /// Only the event that clearly matches the recording counts. Attendees of
    /// a neighbouring event are not people who might have spoken.
    static func matchedAttendees(in directory: URL, record: MeetingRecord) throws -> [CalendarAttendee] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("calendar.json")) else { return [] }
        let events = try ModelCodec.decoder.decode([CalendarSuggestion].self, from: data)
        if let saved = try? Data(contentsOf: directory.appendingPathComponent(calendarMatchName)) {
            let match = try ModelCodec.decoder.decode(CalendarMatch.self, from: saved)
            return events.first { $0.id == match.eventID }?.attendees ?? []
        }
        // A bundle saved before the match was kept.
        return CalendarRanking.best(events, start: record.startedAt, end: record.endedAt)?.attendees ?? []
    }

    private static let calendarMatchName = "calendar-match.json"

    private struct CalendarMatch: Codable {
        var eventID: String?
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
