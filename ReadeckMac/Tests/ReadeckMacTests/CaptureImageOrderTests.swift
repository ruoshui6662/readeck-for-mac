import XCTest
@testable import ReadeckMac

final class CaptureImageOrderTests: XCTestCase {
    func testOrderedVerificationRejectsReorderingAndUnreadableDownscale() {
        let a = Data(repeating: 20, count: 192).base64EncodedString()
        let b = Data(repeating: 210, count: 192).base64EncodedString()
        let left = CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/a")!, mimeType: "image/png", checksum: "a", byteCount: 1, width: 1000, height: 4000, fingerprint: a)
        let right = CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/b")!, mimeType: "image/png", checksum: "b", byteCount: 1, width: 1000, height: 1000, fingerprint: b)
        let first = CaptureImageIdentity.Value(width: 1000, height: 4000, fingerprint: a)
        let second = CaptureImageIdentity.Value(width: 1000, height: 1000, fingerprint: b)
        XCTAssertTrue(CaptureVerification.orderedImagesMatch(expected: [left, right, left], actual: [first, second, first]))
        XCTAssertFalse(CaptureVerification.orderedImagesMatch(expected: [left, right], actual: [second, first]))
        XCTAssertFalse(CaptureVerification.orderedImagesMatch(expected: [left], actual: [.init(width: 100, height: 400, fingerprint: a)]))
    }
}
