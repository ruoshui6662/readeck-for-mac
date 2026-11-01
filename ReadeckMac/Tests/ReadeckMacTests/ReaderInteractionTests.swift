import XCTest
@testable import ReadeckMac

final class ReaderInteractionTests: XCTestCase {
    func testStaleNativePointerDoesNotMoveSelectionAnchor() {
        let anchor = SelectionAnchor(x: 350, y: 420, width: 1, height: 20, viewportWidth: 600, viewportHeight: 600, pointerX: 350, pointerY: 430)
        let viewport = CGRect(x: 200, y: 100, width: 600, height: 600)
        XCTAssertEqual(anchor.screenRect(in: viewport, pointer: CGPoint(x: 250, y: 650)),
                       CGRect(x: 550, y: 260, width: 1, height: 20))
    }
    func testPointerReleaseAnchorsInWindowSpaceAndKeepsSelectionBounds() {
        let anchor = SelectionAnchor(x: 350, y: 420, width: 1, height: 60, viewportWidth: 600, viewportHeight: 600, pointerX: 350, pointerY: 470)
        let viewport = CGRect(x: 200, y: 100, width: 600, height: 600)
        let rect = anchor.screenRect(in: viewport, pointer: CGPoint(x: 560, y: 240))
        XCTAssertEqual(rect, CGRect(x: 560, y: 230, width: 1, height: 60))
    }

    func testKeyboardAnchorScalesViewportAndDoesNotUseUnrelatedMouse() {
        let anchor = SelectionAnchor(x: 200, y: 400, width: 1, height: 40, viewportWidth: 400, viewportHeight: 500)
        XCTAssertEqual(anchor.screenRect(in: CGRect(x: 100, y: 100, width: 800, height: 1000), pointer: CGPoint(x: 500, y: 900)),
                       CGRect(x: 500, y: 220, width: 2, height: 80))
    }
    func testAnchorClipsToViewportAndConvertsNonFlippedCoordinates() {
        let anchor = SelectionAnchor(x: -8, y: 10, width: 100, height: 22)
        XCTAssertEqual(anchor.rect(in: CGSize(width: 500, height: 300), flipped: true), CGRect(x: 0, y: 10, width: 92, height: 22))
        XCTAssertEqual(anchor.rect(in: CGSize(width: 500, height: 300), flipped: false), CGRect(x: 0, y: 268, width: 92, height: 22))
        XCTAssertNil(SelectionAnchor(x: 0, y: 500, width: 10, height: 20).rect(in: CGSize(width: 500, height: 300), flipped: true))
        XCTAssertNil(SelectionAnchor(x: .infinity, y: 0, width: 10, height: 20).rect(in: CGSize(width: 500, height: 300), flipped: true))
    }

    func testAnchorDoesNotChangePersistedServerSelectors() throws {
        let data = Data(#"{"start_selector":"p[1]","end_selector":"p[2]","start_offset":0,"end_offset":2,"text":"中文","anchor":{"x":10,"y":20,"width":50,"height":20}}"#.utf8)
        let value = try JSONDecoder().decode(AnnotationSelection.self, from: data)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        XCTAssertNil(encoded["anchor"])
        XCTAssertEqual(value.endOffset, 2)
    }
}
