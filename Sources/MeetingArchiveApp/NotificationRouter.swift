import Foundation
import UserNotifications

/// Lets the "Recording" and "Saved" notifications carry Stop and Discard
/// buttons, so an unexpected recording can be dealt with where it appears.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Recording buttons name their call's series, so a banner left in
    /// Notification Center can never stop or discard a later call.
    enum Action: Equatable {
        case stopRecording(seriesID: UUID)
        case discardRecording(seriesID: UUID)
        case discardSaved(UUID)
    }

    static let shared = NotificationRouter()
    static let recordingCategory = "recording"
    static let savedCategory = "saved"
    static let seriesKey = "seriesID"
    static let meetingKey = "meetingID"
    private static let stopAction = "stop"
    private static let discardAction = "discard"
    private static let discardSavedAction = "discard-saved"

    /// Set by `install`. Tests set it directly, since installing needs a
    /// notification center that only an app bundle has.
    var handler: (@MainActor (Action) -> Void)?

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
        func id(_ key: String) -> UUID? { (userInfo[key] as? String).flatMap(UUID.init(uuidString:)) }
        switch identifier {
        case stopAction: return id(seriesKey).map { .stopRecording(seriesID: $0) }
        case discardAction: return id(seriesKey).map { .discardRecording(seriesID: $0) }
        case discardSavedAction: return id(meetingKey).map { .discardSaved($0) }
        default: return nil
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        respond(
            to: Self.action(identifier: response.actionIdentifier, userInfo: response.notification.request.content.userInfo),
            completion: completionHandler
        )
    }

    /// Runs the button's action, then tells macOS the response is handled.
    /// In that order, since macOS may stop an app it woke for the button once
    /// it hears back.
    func respond(to action: Action?, completion: @escaping () -> Void) {
        let completion = Completion(call: completion)
        Task { @MainActor in
            if let action { self.handler?(action) }
            completion.call()
        }
    }

    /// macOS's completion handler isn't marked Sendable, but it may be called
    /// from any thread, so it can wait for the main actor.
    private struct Completion: @unchecked Sendable {
        let call: () -> Void
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
