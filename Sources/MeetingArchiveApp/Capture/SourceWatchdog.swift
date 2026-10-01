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

/// Turns a burst of device notifications into one rebuild. A rebuild waits
/// until notifications have been quiet for `settleDelay` (connecting AirPods
/// changes the default input, output and rate one after another), and
/// rebuilds stay `minimumSpacing` apart, so a device that keeps changing, or
/// a rebuild that itself sets off a notification, cannot loop. Use it only
/// on its queue.
final class RebuildScheduler: @unchecked Sendable {
    private let queue: DispatchQueue
    private let settleDelay: TimeInterval
    private let minimumSpacing: TimeInterval
    private var generation = 0
    private var reason: String?
    private var lastRebuild = -TimeInterval.infinity

    init(queue: DispatchQueue, settleDelay: TimeInterval = 0.3, minimumSpacing: TimeInterval = 2) {
        self.queue = queue
        self.settleDelay = settleDelay
        self.minimumSpacing = minimumSpacing
    }

    /// `rebuild` runs on the queue with the burst's first reason, which
    /// explains it best.
    func request(_ reason: String, rebuild: @escaping @Sendable (String) -> Void) {
        generation += 1
        let request = generation
        self.reason = self.reason ?? reason
        let delay = max(settleDelay, lastRebuild + minimumSpacing - DeliveryClock.now)
        queue.asyncAfter(deadline: .now() + delay) {
            guard request == self.generation, let reason = self.reason else { return }
            self.reason = nil
            self.lastRebuild = DeliveryClock.now
            rebuild(reason)
        }
    }

    /// Restarts for other reasons, such as the watchdog's, count too.
    func rebuilt(at now: TimeInterval) {
        lastRebuild = now
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
