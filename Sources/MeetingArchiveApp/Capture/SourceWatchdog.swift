import CoreMedia
import Foundation
import Synchronization

/// When a capture source should be restarted. A source is quiet once nothing
/// has arrived for `quietLimit`. Restarts are spaced `restartSpacing` apart,
/// so a device that is gone is retried without being hammered. A Yeti that
/// stalls and AirPods switching to call mode both look like this: callbacks
/// simply stop, with no error.
struct SourceWatchdog: Equatable {
    static let quietLimit: TimeInterval = 3
    static let restartSpacing: TimeInterval = 10

    enum Verdict: Equatable {
        case healthy
        /// Audio arrived again after an outage of about this long.
        case recovered(after: TimeInterval)
        /// Restart the source now. `newOutage` is false for the second and
        /// later attempts at the same outage, which need no new warning.
        case restart(quietFor: TimeInterval, newOutage: Bool)
    }

    private var lastRestart = -TimeInterval.infinity
    /// The last delivery before the current outage, or nil while healthy.
    private var outageSince: TimeInterval?

    /// Times are host-clock seconds; `lastDelivery` is when audio last arrived.
    mutating func check(now: TimeInterval, lastDelivery: TimeInterval) -> Verdict {
        if let since = outageSince, lastDelivery > since {
            outageSince = nil
            return .recovered(after: lastDelivery - since)
        }
        let quiet = now - lastDelivery
        guard quiet > Self.quietLimit, now - lastRestart >= Self.restartSpacing else { return .healthy }
        let newOutage = outageSince == nil
        if newOutage { outageSince = lastDelivery }
        lastRestart = now
        return .restart(quietFor: quiet, newOutage: newOutage)
    }

    /// A restart for another reason, such as a new default device, still
    /// counts toward the spacing.
    mutating func restarted(at now: TimeInterval) {
        lastRestart = now
    }

    /// A source that could not start has already been reported. Its retries
    /// begin `restartSpacing` later and stay quiet until it delivers.
    mutating func failedToStart(at now: TimeInterval) {
        lastRestart = now
        outageSince = outageSince ?? now
    }
}

/// When a source last delivered audio. Audio callbacks stamp it without
/// taking a lock, since the tap's callback runs on Core Audio's IO thread.
final class DeliveryClock: Sendable {
    private let hostTime = Atomic<UInt64>(0)

    init() { mark() }

    func mark() {
        hostTime.store(mach_absolute_time(), ordering: .relaxed)
    }

    /// Host-clock seconds, comparable with `CMClockGetHostTimeClock()`.
    var seconds: TimeInterval {
        CMClockMakeHostTimeFromSystemUnits(hostTime.load(ordering: .relaxed)).seconds
    }

    static var now: TimeInterval {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}
