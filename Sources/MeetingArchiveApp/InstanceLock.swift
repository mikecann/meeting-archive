import Foundation

/// The instance lock ArchiveController takes so only one copy records.
enum InstanceLock {
    static var path: String { AppPaths.root.appendingPathComponent("instance.lock").path }

    /// Whether another copy holds the lock. Checking takes it briefly and lets
    /// it go again, so the caller can still take it for real afterwards.
    static func isHeld(at path: String = path) -> Bool {
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }

    /// The login item restarts the app whenever it exits, so a background copy
    /// that found another copy running would quit and be relaunched every ten
    /// seconds. Instead it sits here until the other copy quits, then takes over.
    static func waitUntilFree(at path: String = path, pollEvery interval: TimeInterval = 5) {
        while isHeld(at: path) { Thread.sleep(forTimeInterval: interval) }
    }
}
