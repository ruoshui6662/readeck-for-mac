import XCTest
@testable import ReadeckMac

@MainActor
final class WechatRecoveryTests: XCTestCase {
    func testOnlyTransientFailuresRetryAndNeverExceedTwoExtraRounds() async throws {
        var rounds: [Int] = []
        let failed = report(.archiveMissing)
        let result = try await WechatCaptureRecovery.run { round in
            rounds.append(round)
            return (Data([UInt8(round)]), failed)
        }
        XCTAssertEqual(rounds, [0, 1, 2])
        XCTAssertEqual(result, Data([2]))
        for reason in [CaptureResourceIssue.Reason.decodeUnsupported, .scopeMismatch, .limitExceeded] {
            rounds = []
            _ = try await WechatCaptureRecovery.run { round in rounds.append(round); return (Data(), self.report(reason)) }
            XCTAssertEqual(rounds, [0])
        }
    }

    func testSuccessStopsAndCancelledTaskCannotRetry() async throws {
        var rounds = 0
        _ = try await WechatCaptureRecovery.run { round in
            rounds += 1
            return (Data(), round == 0 ? self.report(.archiveMissing) : self.report(nil))
        }
        XCTAssertEqual(rounds, 2)
        let task = Task {
            try await WechatCaptureRecovery.run { _ in
                try await Task.sleep(for: .seconds(30))
                return (Data(), self.report(.archiveMissing))
            }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch is CancellationError { }
    }

    private func report(_ reason: CaptureResourceIssue.Reason?) -> CaptureResourceReport {
        .init(policyVersion: 1, discoveredImages: 1, archivedImages: reason == nil ? 1 : 0, omittedImages: 0, normalizedWidgets: 0,
              issues: reason.map { [.init(role: .bodyImage, position: 1, source: nil, reason: $0, nodeID: "image-0")] } ?? [])
    }
}
