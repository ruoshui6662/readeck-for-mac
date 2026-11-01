import SwiftUI
import XCTest
@testable import ReadeckMac

final class LibraryAppearanceTests: XCTestCase {
    func testBrowsingAndSystemReadingRestoreSystemAppearance() {
        XCTAssertNil(LibraryAppearance.preferredScheme(readerTheme: nil))
        XCTAssertNil(LibraryAppearance.preferredScheme(readerTheme: "system"))
        XCTAssertNil(LibraryAppearance.preferredScheme(readerTheme: "unknown"))
    }

    func testExplicitReadingThemesCoordinateNativeControls() {
        XCTAssertEqual(LibraryAppearance.preferredScheme(readerTheme: "dark"), .dark)
        XCTAssertEqual(LibraryAppearance.preferredScheme(readerTheme: "light"), .light)
        XCTAssertEqual(LibraryAppearance.preferredScheme(readerTheme: "sepia"), .light)
    }
}
