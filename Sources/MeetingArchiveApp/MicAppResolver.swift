import Darwin
import Foundation
import MeetingArchiveCore

/// Turns a process using the mic into the app the user knows. Chromium and
/// Electron apps capture in a helper buried inside their bundle, FaceTime
/// calls run in system daemons and Safari captures in the WebKit GPU process.
struct MicAppResolver {
    /// Apps whose mic use is never a meeting. Matching ignores case.
    static let defaultIgnoredBundleIDs: Set<String> = [
        // Mike's own tools
        "com.mikerosoft.meeting-archive",
        "com.mikerosoft.voice-type",
        "com.mikerosoft.record-it",
        "com.mikerosoft.record-meeting",
        "com.mikerosoft.telemprompit",
        "com.mikerosoft.tandem",
        "com.mikerosoft.video-hq",

        // Apple dictation, Siri and other things that listen. corespeechd
        // reports com.apple.CoreSpeech to Core Audio on macOS 26 and signs as
        // com.apple.corespeechd; DictationIM.app is com.apple.inputmethod.ironwood.
        "com.apple.CoreSpeech",
        "com.apple.corespeechd",
        "com.apple.corespeechd_system",
        "com.apple.corespeech.xpc",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.siri.launcher",
        "com.apple.siri.embeddedspeech",
        "com.apple.inputmethod.ironwood",
        "com.apple.SpeechRecognitionCore.brokerd",
        "com.apple.speech.SpeechRecognitionServer",
        "com.apple.accessibility.heard",
        "com.apple.accessibility.LiveTranscriptionAgent",
        "com.apple.musicrecognition.mac",
        "com.apple.Sound-Settings.extension",
        "com.apple.VoiceMemos",

        // AI voice apps. ChatGPT.app is com.openai.codex since mid 2026.
        "com.anthropic.claudefordesktop",
        "com.openai.chat",
        "com.openai.codex",

        // Dictation tools
        "com.superduper.superwhisper",
        "com.goodsnooze.MacWhisper",
        "com.electron.wispr-flow",

        // Recorders. replayd records the mic for screen recordings made with
        // ScreenCaptureKit, such as the Screenshot toolbar's.
        "pl.maketheweb.cleanshotx",
        "com.getcleanshot.app-setapp",
        "com.obsproject.obs-studio",
        "com.apple.QuickTimePlayerX",
        "com.apple.screenshot.launcher",
        "com.apple.replayd",
        "com.rogueamoeba.audiohijack",
        "com.apple.garageband10",
    ]

    private static let faceTime = MicUser(bundleIdentifier: "com.apple.FaceTime", displayName: "FaceTime")
    private static let safari = MicUser(bundleIdentifier: "com.apple.Safari", displayName: "Safari")

    /// System processes that hold the mic for an app the user knows, keyed by
    /// lowercased bundle ID. FaceTime and phone calls through the Mac run in
    /// avconferenced and callservicesd (com.apple.TelephonyUtilities), the
    /// same daemons Anarlog relabels in crates/detect.
    private static let systemProcessOwners: [String: MicUser] = [
        "com.apple.avconferenced": faceTime,
        "com.apple.telephonyutilities": faceTime,
        "com.apple.telephonyutilities.callservicesd": faceTime,
        "com.apple.facetime.ftconversationservice": faceTime,
        "com.apple.webkit.gpu": safari,
    ]

    /// The same daemons by executable name, for when Core Audio has no bundle ID.
    private static let systemExecutableOwners: [String: MicUser] = [
        "avconferenced": faceTime,
        "callservicesd": faceTime,
        "com.apple.WebKit.GPU": safari,
    ]

    /// The app that owns an audio process. `processBundleID` is the process's
    /// own (a helper's, for a helper) and `executablePath` comes from
    /// `proc_pidpath`, which is read from `pid` when it is missing.
    static func owningApp(processBundleID: String?, executablePath: String?, pid: pid_t) -> MicUser? {
        let bundleID = processBundleID.flatMap { $0.isEmpty ? nil : $0 }
        let path = executablePath ?? self.executablePath(ofPID: pid)

        if let path, let appPath = outermostAppBundlePath(containing: path), let app = app(atBundlePath: appPath) {
            return app
        }
        if let bundleID, let owner = systemProcessOwners[bundleID.lowercased()] { return owner }
        let executableName = path.map { ($0 as NSString).lastPathComponent }
        if let executableName, let owner = systemExecutableOwners[executableName] { return owner }

        // An unknown daemon is only worth reporting if it can be named and ignored.
        guard let bundleID else { return nil }
        return MicUser(bundleIdentifier: bundleID, displayName: executableName ?? bundleID)
    }

    /// The outermost `.app` bundle that contains an executable, so a helper
    /// nested anywhere inside Google Chrome.app resolves to Google Chrome.app.
    /// The executable itself never counts, only the folders above it.
    static func outermostAppBundlePath(containing executablePath: String) -> String? {
        let components = executablePath.split(separator: "/")
        guard let index = components.dropLast().firstIndex(where: { $0.count > 4 && $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        let prefix = executablePath.hasPrefix("/") ? "/" : ""
        return prefix + components[...index].joined(separator: "/")
    }

    static func executablePath(ofPID pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[..<Int(length)], as: UTF8.self)
    }

    /// Names that read better in titles than the app's file name.
    private static let friendlyNames: [String: String] = [
        "us.zoom.xos": "Zoom",
    ]

    private static func app(atBundlePath path: String) -> MicUser? {
        guard let bundleID = Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier, !bundleID.isEmpty else { return nil }
        var name = FileManager.default.displayName(atPath: path)
        if name.lowercased().hasSuffix(".app") { name.removeLast(4) }
        return MicUser(bundleIdentifier: bundleID, displayName: friendlyNames[bundleID] ?? name)
    }
}
