import Foundation

enum MeetingFollowUpPhase: Equatable {
    case transferring
    case processing
    case checking
    case waiting(String)
    /// The capture can never be archived, so its folder stays on this Mac.
    case notArchived(reason: String?)
    case complete

    static func afterArchive(
        expectedRevision: Int, workerRevision: Int?, processingSucceeded: Bool,
        processingError: String?, connectionError: String?
    ) -> Self {
        guard workerRevision == expectedRevision else {
            return connectionError.map { .waiting("Bruce is unavailable. Processing will continue when connected. \($0)") } ?? .checking
        }
        if processingSucceeded {
            return .complete
        }
        if let processingError { return .waiting(processingError) }
        if let connectionError { return .waiting("Bruce status unavailable: \(connectionError)") }
        return .processing
    }

    var isBusy: Bool {
        switch self {
        case .transferring, .processing, .checking: true
        case .waiting, .notArchived, .complete: false
        }
    }

    var detail: String {
        switch self {
        case .transferring: "Saving recording to Bruce"
        case .processing: "Transcribing audio and identifying speaker voices on Bruce"
        case .checking: "Checking speaker analysis on Bruce"
        case .waiting(let reason): reason
        case .notArchived(let reason): reason.map { "Not archived: \($0)" } ?? "Not archived"
        case .complete: "Processed on Bruce"
        }
    }
}
