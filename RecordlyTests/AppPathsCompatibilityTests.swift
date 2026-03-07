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
