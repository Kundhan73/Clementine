import ClementineCore
import XCTest

final class AppInfoTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(AppInfo.bundleIdentifier, "io.github.kundhan73.clementine")
    }
}
