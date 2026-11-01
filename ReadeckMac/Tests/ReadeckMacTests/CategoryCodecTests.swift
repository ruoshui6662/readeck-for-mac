import XCTest
@testable import ReadeckMac

final class CategoryCodecTests: XCTestCase {
    func testCategoryNameRoundTripsWithoutClashingWithTags() {
        let label = CategoryCodec.label(for: "设计/交互")
        XCTAssertEqual(label, "分类/设计/交互")
        XCTAssertEqual(CategoryCodec.name(from: label), "设计/交互")
        XCTAssertEqual(CategoryCodec.name(from: "mac-category/%E8%AE%BE%E8%AE%A1%2F%E4%BA%A4%E4%BA%92"), "设计/交互")
        XCTAssertNil(CategoryCodec.name(from: "普通标签"))
    }

    func testReplacingCategoryPreservesOrdinaryTags() {
        let result = CategoryCodec.replacingCategory(in: ["reading", "mac-category/Old", "swift"], with: "New")
        XCTAssertEqual(result, ["reading", "swift", "分类/New"])
    }
}
