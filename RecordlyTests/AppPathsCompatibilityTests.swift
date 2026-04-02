import XCTest
@testable import Recordly

final class AppPathsCompatibilityTests: XCTestCase {
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
            openSettings: {},
            relaunchCurrentApp: { _ in },
            bundleURLProvider: { URL(fileURLWithPath: "/Applications/Recordly.app") }
        )

        XCTAssertTrue(coordinator.hasSystemRecordingPermission())
    }

    func testRelaunchCurrentAppUsesCurrentBundleURL() {
        var relaunchedURL: URL?
        let currentBundleURL = URL(fileURLWithPath: "/tmp/DerivedData/Build/Products/Debug/Recordly.app")
        let coordinator = ScreenCapturePermissionCoordinator(
            hasPermission: { false },
            requestPermission: { false },
            openSettings: {},
            relaunchCurrentApp: { relaunchedURL = $0 },
            bundleURLProvider: { currentBundleURL }
        )

        coordinator.relaunchCurrentApp()

        XCTAssertEqual(relaunchedURL, currentBundleURL)
    }

    func testRequestSystemRecordingPermissionCallsSystemRequest() {
        var didRequestPermission = false
        let coordinator = ScreenCapturePermissionCoordinator(
            hasPermission: { false },
            requestPermission: {
                didRequestPermission = true
                return true
            },
            openSettings: {},
            relaunchCurrentApp: { _ in },
            bundleURLProvider: { URL(fileURLWithPath: "/Applications/Recordly.app") }
        )

        XCTAssertTrue(coordinator.requestSystemRecordingPermission())
        XCTAssertTrue(didRequestPermission)
    }
}
