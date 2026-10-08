import Foundation

@main
enum MeetingFollowUpScenarios {
    static func main() throws {
        precondition(MeetingFollowUpPhase.transferring.isBusy)
        precondition(MeetingFollowUpPhase.processing.isBusy)
        precondition(MeetingFollowUpPhase.checking.isBusy)
        precondition(!MeetingFollowUpPhase.waiting("Bruce is offline").isBusy)
        precondition(!MeetingFollowUpPhase.complete.isBusy)
        precondition(MeetingFollowUpPhase.complete.detail == "Processed on Bruce", "Finished processing never mentions unnamed voices")
        let notArchived = MeetingFollowUpPhase.notArchived(reason: "No audio or video was recorded.")
        precondition(!notArchived.isBusy, "A recording that can't be archived is not waiting on anything")
        precondition(notArchived.detail == "Not archived: No audio or video was recorded.")
        precondition(MeetingFollowUpPhase.notArchived(reason: nil).detail == "Not archived")
        func archived(revision: Int? = 2, succeeded: Bool = true, error: String? = nil) -> MeetingFollowUpPhase {
            MeetingFollowUpPhase.afterArchive(expectedRevision: 2, workerRevision: revision,
                processingSucceeded: succeeded, processingError: nil, connectionError: error)
        }
        precondition(archived() == .complete, "Finished processing is complete, named voices or not")
        precondition(archived(succeeded: false) == .processing)
        precondition(archived(revision: 1) == .checking, "Old revision must not count as complete")
        precondition(archived(revision: nil) == .checking)
        precondition(!archived(revision: nil, error: "Offline").isBusy, "Offline must not show an endless active spinner")
        print("Meeting follow-up progress, revision, and offline scenarios passed")
    }
}
