import Foundation

enum MeetingFollowUpPhase: Equatable {
    case transferring
    case processing
    case checking
    case waiting(String)
    /// The capture can never be archived, so its folder stays on this Mac.
    case notArchived(reason: String?)
    case needsNames(Int)
    case complete

    static func afterArchive(
        expectedRevision: Int, workerRevision: Int?, processingSucceeded: Bool,
        remainingNames: Int?, processingError: String?, connectionError: String?
    ) -> Self {
        guard workerRevision == expectedRevision else {
            return connectionError.map { .waiting("Bruce is unavailable. Processing will continue when connected. \($0)") } ?? .checking
        }
        if processingSucceeded {
            guard let count = remainingNames, count >= 0 else { return .checking }
            return count == 0 ? .complete : .needsNames(count)
        }
        if let processingError { return .waiting(processingError) }
        if let connectionError { return .waiting("Bruce status unavailable: \(connectionError)") }
        return .processing
    }

    var isBusy: Bool {
        switch self {
        case .transferring, .processing, .checking: true
        case .waiting, .notArchived, .needsNames, .complete: false
        }
    }

    var detail: String {
        switch self {
        case .transferring: "Saving recording to Bruce"
        case .processing: "Transcribing audio and identifying speaker voices on Bruce"
        case .checking: "Checking speaker analysis on Bruce"
        case .waiting(let reason): reason
        case .notArchived(let reason): reason.map { "Not archived: \($0)" } ?? "Not archived"
        case .needsNames(let count): count == 1 ? "1 speaker needs a name" : "\(count) speakers need names"
        case .complete: "Speaker review complete"
        }
    }
}

/// A meeting whose speakers still need names, for the menu bar count. Review
/// never opens by itself; the menu and the library open it.
struct SpeakerAttentionCandidate: Equatable {
    var meetingID: UUID
    var remainingCount: Int
}
