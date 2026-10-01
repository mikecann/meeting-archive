import Foundation
import MeetingArchiveCore
import XCTest
@testable import MeetingArchiveApp

final class MicAppResolverTests: XCTestCase {
    private let faceTime = MicUser(bundleIdentifier: "com.apple.FaceTime", displayName: "FaceTime")
    private let safari = MicUser(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MicAppResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    // MARK: Walking up to the app

    func testTheOutermostAppWinsForAHelperNestedInsideIt() {
        XCTAssertEqual(
            MicAppResolver.outermostAppBundlePath(containing: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/154.0.8037.92/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            "/Applications/Google Chrome.app"
        )
        XCTAssertEqual(
            MicAppResolver.outermostAppBundlePath(containing: "/Applications/Discord.app/Contents/Frameworks/Discord Helper (Renderer).app/Contents/MacOS/Discord Helper (Renderer)"),
            "/Applications/Discord.app"
        )
        XCTAssertEqual(
            MicAppResolver.outermostAppBundlePath(containing: "/Users/m5-mike/Applications/Meeting Archive.app/Contents/MacOS/meeting-archive-app"),
            "/Users/m5-mike/Applications/Meeting Archive.app"
        )
    }

    func testPathsOutsideAnyAppHaveNoBundle() {
        for path in [
            "/usr/libexec/avconferenced",
            "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd",
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            "/Users/m5-mike/Library/Application Support/Voice Type/.venv/bin/Voice Type",
            "/Users/m5-mike/My.apps/tool",
        ] {
            XCTAssertNil(MicAppResolver.outermostAppBundlePath(containing: path), path)
        }
    }

    func testOnlyFoldersAboveTheExecutableCount() {
        XCTAssertNil(MicAppResolver.outermostAppBundlePath(containing: "/usr/local/bin/odd.app"))
        XCTAssertNil(MicAppResolver.outermostAppBundlePath(containing: "/tmp/.app/tool"))
        XCTAssertEqual(MicAppResolver.outermostAppBundlePath(containing: "/Volumes/X/Old.APP/Contents/MacOS/Old"), "/Volumes/X/Old.APP")
        XCTAssertEqual(MicAppResolver.outermostAppBundlePath(containing: "Relative.app/Contents/MacOS/Relative"), "Relative.app")
    }

    func testAHelperResolvesToTheAppItIsBuriedIn() throws {
        let app = try makeApp("Fake Meet.app", in: root, bundleID: "com.example.fakemeet")
        let framework = app.appendingPathComponent("Contents/Frameworks/Fake Meet Framework.framework/Versions/A/Helpers")
        let helper = try makeApp("Fake Meet Helper.app", in: framework, bundleID: "com.example.fakemeet.helper")

        XCTAssertEqual(
            MicAppResolver.owningApp(
                processBundleID: "com.example.fakemeet.helper",
                executablePath: helper.appendingPathComponent("Contents/MacOS/Fake Meet Helper").path,
                pid: 0
            ),
            MicUser(bundleIdentifier: "com.example.fakemeet", displayName: "Fake Meet")
        )
    }

    func testAnAppWithoutAnIdentifierFallsBackToTheProcess() throws {
        let app = root.appendingPathComponent("Broken.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertEqual(
            MicAppResolver.owningApp(processBundleID: "com.example.broken", executablePath: app.appendingPathComponent("broken").path, pid: 0),
            MicUser(bundleIdentifier: "com.example.broken", displayName: "broken")
        )
    }

    func testRealFaceTimeApp() {
        XCTAssertEqual(
            MicAppResolver.owningApp(processBundleID: "com.apple.FaceTime", executablePath: "/System/Applications/FaceTime.app/Contents/MacOS/FaceTime", pid: 0),
            faceTime
        )
    }

    // MARK: System processes

    func testCallDaemonsAreFaceTime() {
        XCTAssertEqual(MicAppResolver.owningApp(processBundleID: "com.apple.avconferenced", executablePath: "/usr/libexec/avconferenced", pid: 0), faceTime)
        XCTAssertEqual(
            MicAppResolver.owningApp(
                processBundleID: "com.apple.TelephonyUtilities",
                executablePath: "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd",
                pid: 0
            ),
            faceTime
        )
        XCTAssertEqual(MicAppResolver.owningApp(processBundleID: "com.apple.telephonyutilities.callservicesd", executablePath: nil, pid: 0), faceTime)
        XCTAssertEqual(MicAppResolver.owningApp(processBundleID: "com.apple.FaceTime.FTConversationService", executablePath: nil, pid: 0), faceTime)

        // Matched by executable name when Core Audio has no bundle ID for them.
        XCTAssertEqual(MicAppResolver.owningApp(processBundleID: nil, executablePath: "/usr/libexec/avconferenced", pid: 0), faceTime)
        XCTAssertEqual(
            MicAppResolver.owningApp(processBundleID: "", executablePath: "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd", pid: 0),
            faceTime
        )
    }

    func testTheWebKitGPUProcessIsSafari() {
        let path = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"
        XCTAssertEqual(MicAppResolver.owningApp(processBundleID: "com.apple.WebKit.GPU", executablePath: path, pid: 0), safari)
        XCTAssertEqual(MicAppResolver.owningApp(processBundleID: nil, executablePath: path, pid: 0), safari)
    }

    func testUnknownDaemonsWithoutABundleIDAreDropped() {
        XCTAssertNil(MicAppResolver.owningApp(processBundleID: nil, executablePath: "/usr/libexec/historicalaudiod", pid: 0))
        XCTAssertNil(MicAppResolver.owningApp(processBundleID: "", executablePath: "/Users/m5-mike/Library/Application Support/Voice Type/.venv/bin/Voice Type", pid: 0))
        XCTAssertNil(MicAppResolver.owningApp(processBundleID: nil, executablePath: nil, pid: 0))
    }

    func testUnknownDaemonsWithABundleIDKeepItSoTheyCanBeIgnored() {
        XCTAssertEqual(
            MicAppResolver.owningApp(processBundleID: "com.apple.CoreSpeech", executablePath: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd", pid: 0),
            MicUser(bundleIdentifier: "com.apple.CoreSpeech", displayName: "corespeechd")
        )
        XCTAssertEqual(
            MicAppResolver.owningApp(processBundleID: "com.apple.replayd", executablePath: nil, pid: 0),
            MicUser(bundleIdentifier: "com.apple.replayd", displayName: "com.apple.replayd")
        )
    }

    func testAMissingPathIsReadFromThePID() throws {
        let path = try XCTUnwrap(MicAppResolver.executablePath(ofPID: getpid()))
        XCTAssertTrue(path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        XCTAssertNil(MicAppResolver.executablePath(ofPID: 0))
    }

    // MARK: Ignored by default

    func testDefaultIgnoresMikesToolsDictationAIVoiceAppsAndRecorders() {
        let ignored = MicAppResolver.defaultIgnoredBundleIDs
        for bundleID in [
            "com.mikerosoft.meeting-archive", "com.mikerosoft.voice-type", "com.mikerosoft.record-it",
            "com.mikerosoft.record-meeting", "com.mikerosoft.telemprompit", "com.mikerosoft.tandem",
            "com.mikerosoft.video-hq",
            "com.apple.CoreSpeech", "com.apple.assistantd", "com.apple.Siri", "com.apple.inputmethod.ironwood",
            "com.apple.VoiceMemos",
            "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
            "com.superduper.superwhisper", "com.goodsnooze.MacWhisper", "com.electron.wispr-flow",
            "pl.maketheweb.cleanshotx", "com.obsproject.obs-studio", "com.apple.QuickTimePlayerX",
            "com.rogueamoeba.audiohijack", "com.apple.garageband10",
        ] {
            XCTAssertTrue(ignored.contains(bundleID), bundleID)
        }
    }

    func testCallAppsAndBrowsersAreNeverIgnoredByDefault() {
        let ignored = Set(MicAppResolver.defaultIgnoredBundleIDs.map { $0.lowercased() })
        for bundleID in [
            "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
            "com.microsoft.edgemac", "com.brave.Browser", "net.imput.helium",
            "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
            "com.hnc.Discord", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.apple.FaceTime",
            "com.apple.mobilephone",
        ] {
            XCTAssertFalse(ignored.contains(bundleID.lowercased()), bundleID)
        }
    }

    // MARK: Helpers

    @discardableResult
    private func makeApp(_ name: String, in folder: URL, bundleID: String) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": (name as NSString).deletingPathExtension,
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }
}
