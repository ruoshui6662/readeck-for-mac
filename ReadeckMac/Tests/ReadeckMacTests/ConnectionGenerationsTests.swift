import Foundation
import XCTest
@testable import ReadeckMac

final class ConnectionGenerationsTests: XCTestCase {
    func testStaleConnectionWorkCannotApplyAfterSwitch() throws {
        var generations = ConnectionGenerations()
        let firstClient = ReadeckClient(address: try ServerAddress("http://first.test/"), token: "one")
        let firstSession = generations.begin(for: firstClient)
        let secondClient = ReadeckClient(address: try ServerAddress("http://second.test/"), token: "two")
        let secondSession = generations.begin(for: secondClient)

        let staleCannotApply = generations.isCurrent(firstSession, for: secondClient)
        let secondCanApply = generations.isCurrent(secondSession, for: secondClient)

        XCTAssertFalse(staleCannotApply)
        XCTAssertTrue(secondCanApply)
    }

    func testDisconnectInvalidatesEveryOutstandingSession() throws {
        var generations = ConnectionGenerations()
        let client = ReadeckClient(address: try ServerAddress("http://nas.test/"), token: "test")
        let session = generations.begin(for: client)
        generations.invalidate()

        XCTAssertFalse(generations.isCurrent(session, for: client))
    }

    func testFailedConnectionAttemptCannotLeaveOlderSessionActive() throws {
        var generations = ConnectionGenerations()
        let oldClient = ReadeckClient(address: try ServerAddress("http://old.test/"), token: "old")
        let oldSession = generations.begin(for: oldClient)

        do {
            _ = try ServerAddress("ftp://invalid.test/")
        } catch {
            generations.invalidate()
        }

        XCTAssertFalse(generations.isCurrent(oldSession, for: oldClient))
    }
}
