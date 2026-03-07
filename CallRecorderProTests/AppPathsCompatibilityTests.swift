import XCTest
@testable import CallRecorderPro

final class AppPathsCompatibilityTests: XCTestCase {
    func testLegacyAppSupportFolderNameRemainsStable() {
        XCTAssertEqual(AppPaths.appSupportFolderName, "CallRecorderPro")
    }

    func testLegacySharedModelsFolderRemainsStable() {
        XCTAssertEqual(AppPaths.sharedModelsFolder, "/Users/Shared/CallRecorderProModels")
    }
}
