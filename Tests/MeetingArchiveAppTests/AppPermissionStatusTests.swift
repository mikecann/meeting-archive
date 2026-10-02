import XCTest
@testable import MeetingArchiveApp

final class AppPermissionStatusTests: XCTestCase {
    func testSystemAuthorizationStatesMapWithoutCollapsingRestrictedAccess() {
        XCTAssertEqual(AppPermissionStatusMapper.system(.notDetermined), .notRequested)
        XCTAssertEqual(AppPermissionStatusMapper.system(.denied), .denied)
        XCTAssertEqual(AppPermissionStatusMapper.system(.restricted), .restricted)
        XCTAssertEqual(AppPermissionStatusMapper.system(.granted), .granted)
        XCTAssertEqual(AppPermissionStatusMapper.system(.unknown), .unknown)
    }

    /// TCC's preflight answers 0 for allowed, 1 for denied, anything else for not asked yet.
    func testSystemAudioPreflightResultsMapToStatuses() {
        XCTAssertEqual(SystemAudioPermission.status(preflightResult: 0), .granted)
        XCTAssertEqual(SystemAudioPermission.status(preflightResult: 1), .denied)
        XCTAssertEqual(SystemAudioPermission.status(preflightResult: 2), .notDetermined)
        XCTAssertEqual(AppPermissionStatusMapper.system(SystemAudioPermission.status(preflightResult: 0)), .granted)
    }
}
