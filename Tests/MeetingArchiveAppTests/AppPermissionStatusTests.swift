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
}
