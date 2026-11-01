import Security
import XCTest
@testable import ReadeckMac

final class CredentialStoreTests: XCTestCase {
    func testExistingCredentialIsUpdatedWithoutCreatingAnotherItem() throws {
        var updates = 0, additions = 0
        try CredentialStore.upsert(update: { updates += 1; return errSecSuccess }, add: { additions += 1; return errSecSuccess })
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(additions, 0)
    }

    func testMissingCredentialIsCreated() throws {
        var additions = 0
        try CredentialStore.upsert(update: { errSecItemNotFound }, add: { additions += 1; return errSecSuccess })
        XCTAssertEqual(additions, 1)
    }

    func testDeniedUpdateDoesNotReplaceCredential() {
        var additions = 0
        XCTAssertThrowsError(try CredentialStore.upsert(update: { errSecAuthFailed }, add: { additions += 1; return errSecSuccess }))
        XCTAssertEqual(additions, 0)
    }
}
