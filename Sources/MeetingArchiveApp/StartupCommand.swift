import Foundation
import ServiceManagement
import SwiftUI

/// Registration must run from the signed app bundle. A `swift -` script has
/// its own bundle context and cannot manage this app's embedded LaunchAgent.
@main
enum MeetingArchiveEntry {
    @MainActor
    static func main() async {
        let service = SMAppService.agent(plistName: "com.mikerosoft.meeting-archive.plist")
        do {
            if CommandLine.arguments.contains("--disable-startup") {
                try await service.unregister()
                print("Meeting Archive login item disabled. If it was running, it saved any recording and quit. Recordings and archive data were retained.")
                return
            }
            if CommandLine.arguments.contains("--enable-startup") {
                try service.register()
                print(service.status == .enabled ? "Meeting Archive login item enabled." : "Allow Meeting Archive in System Settings > Login Items.")
                return
            }
        } catch {
            FileHandle.standardError.write(Data("Could not change startup registration: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        // launchd relaunches the login item however it exits. If a copy opened
        // by hand is already recording, wait for it to quit rather than exit
        // and be relaunched every ten seconds.
        // Blocks the main thread on purpose, and must never become an await:
        // after a real suspension the rest of main(), App.main() included,
        // runs inside a main-queue job, so the main queue never drains and
        // every Task { @MainActor } (saving on quit, too) hangs for good.
        if CommandLine.arguments.contains("--background") {
            InstanceLock.taken = InstanceLock.waitAndTake()
        }
        MeetingArchiveApplication.main()
    }
}
