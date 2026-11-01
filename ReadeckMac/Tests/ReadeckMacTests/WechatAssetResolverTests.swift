import XCTest
import SwiftSoup
@testable import ReadeckMac

final class WechatAssetResolverTests: XCTestCase {
    func testLoadingBackgroundRequiresKnownBytesAndExplicitImagePlaceholderScope() throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'><circle r='4'/></svg>".utf8)
        let url = "data:image/svg+xml," + String(decoding: svg, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let policy = CaptureResourcePolicy(version: 1, widgets: [], placeholderImageSelector: "img.js_img_placeholder[data-src]", placeholderSVGHashes: [DataHash.sha256(svg)])
        let doc = try SwiftSoup.parse("<img class='js_img_placeholder' data-src='https://body.test/photo'><div class='js_img_placeholder' data-src='https://body.test/photo'></div>")
        XCTAssertTrue(try WechatAssetResolver.isKnownLoadingBackground(url, node: doc.select("img").first()!, policy: policy))
        XCTAssertFalse(try WechatAssetResolver.isKnownLoadingBackground(url, node: doc.select("div").first()!, policy: policy))
        XCTAssertFalse(try WechatAssetResolver.isKnownLoadingBackground("data:image/svg+xml,<svg/>", node: doc.select("img").first()!, policy: policy))
    }
    func testEmptyZeroWidthLayoutSVGDoesNotBlockBody() throws {
        let article = try parse("<div id='js_content'><p>正文</p><svg viewBox='0 0 1 1' style='float:left;line-height:0;width:0' role='img' aria-label='插图'></svg></div>")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertFalse(article.html.contains("<svg"))
    }
    func testBackgroundDoesNotCollectUnrelatedCSSURLs() throws {
        let dataURL = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let html = "<div id='js_content'><p style=\"background-color:red;list-style-image:url(https://unrelated.test/no);background-image:url('\(dataURL)')\">正文</p></div>"
        let article = try parse(html)
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testSrcsetWithEmbeddedDataImageKeepsCommaInURL() throws {
        let dataURL = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let article = try parse("<div id='js_content'><p>正文</p><img srcset='\(dataURL) 1x'></div>")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testUnsupportedInlineSVGIsReportedInsteadOfSilentlyRemoved() throws {
        let article = try parse("<div id='js_content'><p>正文</p><svg width='100' height='100'><circle cx='30' cy='30' r='20'/></svg></div>")
        XCTAssertFalse(article.missingImages.isEmpty)
        XCTAssertEqual(article.resourceReport?.issues.first?.reason, .decodeUnsupported)
        XCTAssertFalse(article.html.contains("<svg"))
    }

    private func parse(_ html: String) throws -> CapturedArticle {
        let data = try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": Data(html.utf8)]], format: .binary, options: 0)
        return try WechatArticleParser.extract(archive: data, source: CaptureSourceURL("https://mp.weixin.qq.com/s/test"), packageID: "test")
    }
}
