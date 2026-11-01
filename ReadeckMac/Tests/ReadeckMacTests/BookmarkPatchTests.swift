import Foundation
import XCTest
@testable import ReadeckMac

final class BookmarkPatchTests: XCTestCase {
    private func bookmark() throws -> Bookmark {
        try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","labels":["old"],"is_marked":false,"is_archived":false,"read_progress":20}"#.utf8))
    }

    func testLaterToggleWinsAndProgressOnlyIncreases() throws {
        let original = try bookmark()
        var mutation = PendingMutation(bookmark: original,
                                       patch: BookmarkPatch(isMarked: true, readProgress: 35))
        mutation.merge(BookmarkPatch(isMarked: false, readProgress: 25), baselineBookmark: original)

        XCTAssertEqual(mutation.desired.isMarked, false)
        XCTAssertEqual(mutation.desired.readProgress, 35)
        XCTAssertEqual(mutation.desired.applying(to: original).readProgress, 35)
    }

    func testNewFieldKeepsItsOriginalServerBaseline() throws {
        let original = try bookmark()
        var mutation = PendingMutation(bookmark: original, patch: BookmarkPatch(isMarked: true))
        mutation.merge(BookmarkPatch(labels: ["new"]), baselineBookmark: original)

        XCTAssertEqual(mutation.baseline.isMarked, false)
        XCTAssertEqual(mutation.baseline.labels, ["old"])
        XCTAssertEqual(mutation.desired.labels, ["new"])
    }

    func testLabelOrderDoesNotCreateFalseConflict() throws {
        let original = try bookmark()
        let desired = BookmarkPatch(labels: ["design", "reading"])
        let reordered = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","labels":["reading","design"]}"#.utf8))
        let baseline = desired.baseline(from: original)

        XCTAssertTrue(desired.isSatisfied(by: reordered))
        XCTAssertFalse(desired.conflicts(with: reordered, baseline: baseline))
    }
}
