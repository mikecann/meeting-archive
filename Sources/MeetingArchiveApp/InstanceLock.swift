import Foundation

/// The instance lock that makes sure only one copy records.
enum InstanceLock {
    static var path: String { AppPaths.root.appendingPathComponent("instance.lock").path }

    /// Taken by a background copy before the app starts, for ArchiveController
    /// to keep rather than take the lock a second time.
    @MainActor static var taken: Int32?

    /// The login item restarts the app whenever it exits, so a background copy
    /// that found another copy running would quit and be relaunched every ten
    /// seconds. Instead it waits here until the other copy quits, and takes the
    /// lock in the same step, so nothing can slip in between. Returns nil if
    /// the lock file can't be opened at all; the controller then reports it.
    static func waitAndTake(at path: String = path, pollEvery interval: TimeInterval = 5) -> Int32? {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        while true {
            let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { return nil }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            close(descriptor)
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
