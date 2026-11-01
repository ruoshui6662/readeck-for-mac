import XCTest
@testable import ReadeckMac

final class CaptureResourceReportTests: XCTestCase {
    func testFailedResourceKeepsActualCaptureAttemptCount() throws {
        let article = try parse("<div id='js_content' data-readeck-attempt='3'><p>正文</p><img src='https://image.test/fail'></div>")
        XCTAssertEqual(article.resourceReport?.issues.first?.attempts, 3)
    }
    func testUnsettledBodyCannotBeReportedAsComplete() throws {
        let result = try parse("<div id='js_content' data-readeck-readiness='{&quot;settled&quot;:false,&quot;failedImages&quot;:0,&quot;pendingImages&quot;:0,&quot;milliseconds&quot;:10000}'><p>持续变化的正文</p></div>")
        XCTAssertEqual(result.resourceReport?.issues.first?.reason, .timedOut)
        XCTAssertFalse(result.missingImages.isEmpty)
    }
    func testReportUsesSharedPolicyAndNeverPersistsSourceSecrets() async throws {
        let html = "<div id='js_content'><p>正文</p><mp-common-clmusic music_name='歌曲'><template shadowrootmode='open'><img src='https://ui.test/cover'></template></mp-common-clmusic><mp-common-miniprogram data-miniprogram-type='image'><img src='https://mmbiz.qpic.cn/private-path?key=secret'></mp-common-miniprogram></div>"
        let article = try parse(html)
        let report = try XCTUnwrap(article.resourceReport)
        XCTAssertEqual(report.policyVersion, CaptureResourcePolicy.current.version)
        XCTAssertEqual(report.normalizedWidgets, 1)
        XCTAssertEqual(report.discoveredImages, 1)
        XCTAssertEqual(report.issues.first?.reason, .archiveMissing)
        XCTAssertEqual(report.issues.first?.role, .unknownWidget)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertTrue(encoded.contains("mmbiz.qpic.cn"))
        for secret in ["private-path", "secret", "key=", "ui.test", "歌曲"] { XCTAssertFalse(encoded.contains(secret)) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = CapturePackageStore(root: root)
        _ = try await packages.save(article, id: "one", instance: "a")
        let loaded = try await packages.load(id: "one", instance: "a")
        XCTAssertEqual(loaded.manifest.resourceReport, report)
    }

    func testScopeMismatchBlocksCompleteCapture() throws {
        let result = try parse("<div id='js_content' data-readeck-policy-version='1' data-readeck-image-count='1'><p>正文</p></div>")
        XCTAssertEqual(result.resourceReport?.issues.first?.reason, .scopeMismatch)
        XCTAssertFalse(result.missingImages.isEmpty)
    }

    func testPolicyOnlyConvertsKnownCardsAndOldManifestStillDecodes() throws {
        let rules = CaptureResourcePolicy.current
        let selectors = rules.widgets.map(\.selector)
        XCTAssertTrue(selectors.contains("mp-common-miniprogram[data-miniprogram-type=card]"))
        XCTAssertFalse(selectors.contains("mp-common-miniprogram"))
        let json = "{\"url\":\"https://mp.weixin.qq.com/s/one\",\"title\":\"old\",\"htmlChecksum\":\"hash\",\"text\":\"text\",\"assets\":[],\"missingImages\":[]}"
        XCTAssertNil(try JSONDecoder().decode(CaptureManifest.self, from: Data(json.utf8)).resourceReport)
    }

    private func parse(_ html: String) throws -> CapturedArticle {
        let data = try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": Data(html.utf8)]], format: .binary, options: 0)
        return try WechatArticleParser.extract(archive: data, source: CaptureSourceURL("https://mp.weixin.qq.com/s/one"), packageID: "test")
    }
}
