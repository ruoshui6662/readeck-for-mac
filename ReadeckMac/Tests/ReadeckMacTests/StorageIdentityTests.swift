import XCTest
@testable import ReadeckMac

final class StorageIdentityTests: XCTestCase {
    func testSameServerWithDifferentTokensUsesDifferentLocalPartitions() throws {
        let address = try ServerAddress("http://nas.test:8180/")
        let first = ReadeckClient(address: address, token: "account-A-secret")
        let second = ReadeckClient(address: address, token: "account-B-secret")
        let sameAgain = ReadeckClient(address: address, token: "account-A-secret")

        XCTAssertNotEqual(first.storageInstance, second.storageInstance)
        XCTAssertEqual(first.storageInstance, sameAgain.storageInstance)
        XCTAssertFalse(first.storageInstance.contains("account-A-secret"))
    }
}
