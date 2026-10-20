import XCTest
@testable import Recordly

final class AppPathsCompatibilityTests: XCTestCase {
    func testPublicBrandKeepsExistingApplicationIdentity() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String, "Barkenson")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Barkenson")
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.local.Recordly")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "Recordly")
    }

    func testLegacyAppSupportFolderNameRemainsStable() {
        XCTAssertEqual(AppPaths.appSupportFolderName, "Recordly")
    }

    func testLegacySharedModelsFolderRemainsStable() {
        XCTAssertEqual(AppPaths.sharedModelsFolder, "/Users/Shared/RecordlyModels")
    }
}

final class ScreenCapturePermissionCoordinatorTests: XCTestCase {
    func testHasSystemRecordingPermissionUsesPreflightResult() {
        let coordinator = ScreenCapturePermissionCoordinator(
            hasPermission: { true },
            requestPermission: { true },
            openSettings: {}
        )

        XCTAssertTrue(coordinator.hasSystemRecordingPermission())
    }

    func testRequestSystemRecordingPermissionCallsSystemRequest() {
        var didRequestPermission = false
        let coordinator = ScreenCapturePermissionCoordinator(
            hasPermission: { false },
            requestPermission: {
                didRequestPermission = true
                return true
            },
            openSettings: {}
        )

        XCTAssertTrue(coordinator.requestSystemRecordingPermission())
        XCTAssertTrue(didRequestPermission)
    }
}
