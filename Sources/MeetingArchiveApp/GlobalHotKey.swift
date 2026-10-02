import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut through Carbon's hot key API, which needs no
/// Accessibility permission, unlike a global key monitor.
@MainActor
final class GlobalHotKey {
    /// Control-Option-Command-R starts a recording, or stops the current one.
    static let recordToggleDescription = "⌃⌥⌘R"

    // Only touched on the main thread; deinit is the one nonisolated reader.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    private init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    static func recordToggle(_ action: @escaping @MainActor () -> Void) -> GlobalHotKey? {
        let hotKey = GlobalHotKey(action: action)
        return hotKey.register(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | cmdKey)) ? hotKey : nil
    }

    private func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handlerRef)
        guard installed == noErr else {
            Log.controller.error("Could not install the hot key handler: \(installed, privacy: .public)")
            return false
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D41_5243), id: 1) // "MARC"
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            // Usually another app already owns the shortcut. The menu still works.
            Log.controller.error("Could not register \(Self.recordToggleDescription, privacy: .public): \(registered, privacy: .public)")
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return false
        }
        return true
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
