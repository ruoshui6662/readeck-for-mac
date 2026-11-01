import XCTest
@testable import ReadeckMac

final class LibraryListPresentationTests: XCTestCase {
    func testNarrowRowsPrioritizeTitleAndSourceWithoutOverflow() {
        let wide = LibraryListMetrics(availableWidth: 1600, density: .standard, thumbnails: true)
        XCTAssertLessThanOrEqual(wide.rowWidth, 1040)
        XCTAssertTrue(wide.showsSummary)
        XCTAssertTrue(wide.showsTags)
        let narrow = LibraryListMetrics(availableWidth: 650, density: .standard, thumbnails: true)
        XCTAssertFalse(narrow.showsSummary)
        XCTAssertFalse(narrow.showsTags)
        XCTAssertTrue(narrow.showsCover)
        XCTAssertFalse(narrow.showsInlineActions)
        let small = LibraryListMetrics(availableWidth: 540, density: .standard, thumbnails: true)
        XCTAssertFalse(small.showsCover)
        XCTAssertFalse(small.showsCategory)
        XCTAssertFalse(small.showsProgressBar)
        XCTAssertLessThan(small.rowWidth, 540)
    }
    func testCompactAndThumbnailPreferenceRemoveOptionalContent() {
        let compact = LibraryListMetrics(availableWidth: 1000, density: .compact, thumbnails: false)
        XCTAssertFalse(compact.showsSummary)
        XCTAssertFalse(compact.showsTags)
        XCTAssertFalse(compact.showsCover)
        XCTAssertTrue(compact.showsCategory)
        XCTAssertLessThan(compact.minimumHeight, LibraryListMetrics(availableWidth: 1000, density: .standard, thumbnails: true).minimumHeight)
        for width in [CGFloat.nan, .infinity, -100, 0, 150] {
            let metrics = LibraryListMetrics(availableWidth: width, density: .standard, thumbnails: true)
            XCTAssertTrue(metrics.rowWidth.isFinite)
            XCTAssertGreaterThanOrEqual(metrics.rowWidth, 0)
        }
    }
    func testSortingHandlesMissingDatesAndStableTies() {
        let books = [Bookmark(id: "a", url: "https://example.com/a", title: "Beta", created: "2026-10-25T00:00:00Z"),
                     Bookmark(id: "b", url: "https://example.com/b", title: "Alpha", created: "2026-10-27T00:00:00Z"),
                     Bookmark(id: "c", url: "https://example.com/c", title: "Alpha", created: "2026-10-27T00:00:00Z"),
                     Bookmark(id: "d", url: "https://example.com/d", title: "Gamma")]
        XCTAssertEqual(LibrarySortOrder.recent.sorted(books).map(\.id), ["b", "c", "a", "d"])
        XCTAssertEqual(LibrarySortOrder.title.sorted(books).map(\.id), ["b", "c", "a", "d"])
        XCTAssertEqual(LibrarySortOrder.title.sorted(Array(books.reversed())).map(\.id), ["c", "b", "a", "d"])
    }
}
