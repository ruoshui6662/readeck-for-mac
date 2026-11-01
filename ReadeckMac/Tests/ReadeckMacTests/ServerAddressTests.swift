import XCTest
@testable import ReadeckMac

final class ServerAddressTests: XCTestCase {
    func testKeepsHTTPHostPortAndSubpath() throws {
        let address = try ServerAddress("http://192.168.1.12:8000/readeck")
        XCTAssertEqual(address.root.absoluteString, "http://192.168.1.12:8000/readeck/")
        XCTAssertEqual(address.api("info").absoluteString, "http://192.168.1.12:8000/readeck/api/info")
    }

    func testRejectsCredentialsAndOtherSchemes() {
        XCTAssertThrowsError(try ServerAddress("https://user:secret@example.com"))
        XCTAssertThrowsError(try ServerAddress("ftp://example.com"))
        XCTAssertThrowsError(try ServerAddress("https://example.com?x=1"))
    }
}
