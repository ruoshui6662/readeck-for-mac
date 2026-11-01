import Foundation
import XCTest
@testable import ReadeckMac

final class ConnectionDiagnosticsTests: XCTestCase {
    func testAuthenticationAndPermissionErrorsHaveSpecificMessages() {
        XCTAssertEqual(ConnectionDiagnostics.message(for: APIError.status(401, "")),
                       "API Token 无效或已过期，请重新检查令牌。")
        XCTAssertEqual(ConnectionDiagnostics.message(for: APIError.status(403, "")),
                       "API Token 缺少访问收藏所需的权限。")
    }

    func testOfflineAndTimeoutErrorsAreDistinguished() {
        XCTAssertEqual(ConnectionDiagnostics.message(for: URLError(.notConnectedToInternet)),
                       "无法连接到 NAS。请检查网络和服务端地址。")
        XCTAssertEqual(ConnectionDiagnostics.message(for: URLError(.timedOut)),
                       "NAS 响应超时，请稍后重试。")
    }

    func testBookmarkCaptureStateDistinguishesFailureFromProcessing() throws {
        let decoder = JSONDecoder.readeck
        let failed = try decoder.decode(Bookmark.self, from: Data(#"{"id":"a","url":"https://example.com","state":1,"loaded":true}"#.utf8))
        let processing = try decoder.decode(Bookmark.self, from: Data(#"{"id":"b","url":"https://example.com","state":2,"loaded":false}"#.utf8))
        XCTAssertEqual(failed.captureStatus, "抓取失败")
        XCTAssertEqual(processing.captureStatus, "处理中")
    }

    func testLoadedWithoutArticleAndServerErrorsShowsFailureWhileValidNonArticleDoesNot() throws {
        let decoder = JSONDecoder.readeck
        let failed = try decoder.decode(Bookmark.self, from: Data(#"{"id":"a","url":"https://example.com","state":0,"loaded":true,"has_article":false,"errors":["cannot load resource"]}"#.utf8))
        let photo = try decoder.decode(Bookmark.self, from: Data(#"{"id":"b","url":"https://example.com/photo","state":0,"loaded":true,"has_article":false}"#.utf8))
        let partial = try decoder.decode(Bookmark.self, from: Data(#"{"id":"c","url":"https://example.com","state":0,"loaded":true,"has_article":true,"errors":["image unavailable"]}"#.utf8))
        XCTAssertEqual(failed.captureStatus, "抓取失败")
        XCTAssertNil(photo.captureStatus)
        XCTAssertEqual(partial.captureStatus, "抓取有异常")
    }
}
