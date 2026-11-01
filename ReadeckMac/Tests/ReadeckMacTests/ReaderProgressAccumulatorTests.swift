import XCTest
@testable import ReadeckMac

final class ReaderProgressAccumulatorTests: XCTestCase {
    func testRapidProgressChangesAreCoalescedIntoOneWrite() {
        var progress = ReaderProgressAccumulator(initial: 12)

        progress.record(18)
        progress.record(23)
        progress.record(31)

        XCTAssertEqual(progress.flush(), 31)
        XCTAssertNil(progress.flush())
    }

    func testRestoredOrRegressingProgressIsNotWritten() {
        var progress = ReaderProgressAccumulator(initial: 45)

        progress.record(45)
        progress.record(30)
        progress.record(48)

        XCTAssertNil(progress.flush())
        progress.record(52)
        XCTAssertEqual(progress.flush(), 52)
    }
}
