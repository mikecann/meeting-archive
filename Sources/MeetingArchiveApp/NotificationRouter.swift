import Foundation
import UserNotifications

/// Lets the "Recording" and "Saved" notifications carry Stop and Discard
/// buttons, so an unexpected recording can be dealt with where it appears.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Action: Equatable {
        case stopRecording
        case discardRecording
        case discardSaved(UUID)
    }

    static let shared = NotificationRouter()
    static let recordingCategory = "recording"
    static let savedCategory = "saved"
    private static let stopAction = "stop"
    private static let discardAction = "discard"
    private static let discardSavedAction = "discard-saved"

    private var handler: (@MainActor (Action) -> Void)?

    @MainActor
    func install(_ handler: @escaping @MainActor (Action) -> Void) {
        self.handler = handler
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.recordingCategory,
                actions: [
                    UNNotificationAction(identifier: Self.stopAction, title: "Stop and save"),
                    UNNotificationAction(identifier: Self.discardAction, title: "Discard", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Self.savedCategory,
                actions: [UNNotificationAction(identifier: Self.discardSavedAction, title: "Discard", options: [.destructive])],
                intentIdentifiers: []
            ),
        ])
    }

    static func action(identifier: String, userInfo: [AnyHashable: Any]) -> Action? {
        switch identifier {
        case stopAction: return .stopRecording
        case discardAction: return .discardRecording
        case discardSavedAction:
            guard let raw = userInfo["meetingID"] as? String, let id = UUID(uuidString: raw) else { return nil }
            return .discardSaved(id)
        default: return nil
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = Self.action(identifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
        if let action {
            Task { @MainActor in self.handler?(action) }
        }
        completionHandler()
    }

    /// A menu-bar app is often frontmost while a call runs, so show banners
    /// even then instead of letting macOS swallow them.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
