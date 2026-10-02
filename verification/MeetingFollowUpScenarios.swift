import Foundation

@main
enum MeetingFollowUpScenarios {
    static func main() throws {
        precondition(MeetingFollowUpPhase.transferring.isBusy)
        precondition(MeetingFollowUpPhase.processing.isBusy)
        precondition(MeetingFollowUpPhase.checking.isBusy)
        precondition(!MeetingFollowUpPhase.waiting("Bruce is offline").isBusy)
        precondition(!MeetingFollowUpPhase.needsNames(1).isBusy)
        precondition(!MeetingFollowUpPhase.complete.isBusy)
        precondition(MeetingFollowUpPhase.needsNames(1).detail == "1 speaker needs a name")
        precondition(MeetingFollowUpPhase.needsNames(2).detail == "2 speakers need names")
        let notArchived = MeetingFollowUpPhase.notArchived(reason: "No audio or video was recorded.")
        precondition(!notArchived.isBusy, "A recording that can't be archived is not waiting on anything")
        precondition(notArchived.detail == "Not archived: No audio or video was recorded.")
        precondition(MeetingFollowUpPhase.notArchived(reason: nil).detail == "Not archived")
        func archived(revision: Int? = 2, succeeded: Bool = true, count: Int? = nil, error: String? = nil) -> MeetingFollowUpPhase {
            MeetingFollowUpPhase.afterArchive(expectedRevision: 2, workerRevision: revision,
                processingSucceeded: succeeded, remainingNames: count, processingError: nil, connectionError: error)
        }
        precondition(archived(count: 0) == .complete)
        precondition(archived(count: 1) == .needsNames(1))
        precondition(archived(succeeded: false) == .processing)
        precondition(archived() == .checking, "Missing analysis must not mean complete")
        precondition(archived(revision: 1, count: 0) == .checking, "Old revision must not clear new review")
        precondition(archived(revision: nil, count: 0) == .checking)
        precondition(archived(count: -1) == .checking)
        precondition(!archived(revision: nil, error: "Offline").isBusy, "Offline must not show an endless active spinner")
        print("Meeting follow-up progress, revision, and offline scenarios passed")
    }
}
