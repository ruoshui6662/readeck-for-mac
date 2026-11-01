import XCTest
import SwiftSoup
@testable import ReadeckMac

final class XiaohongshuImportTests: XCTestCase {
    private let url = "https://www.rednote.com/discovery/item/abc123"
    private let image = "http://sns-web-i10.rednotecdn.com/photo!dft?sign=keep"

    func testSupplementDownloadsOnlyMissingPublicImagesAndKeepsOrder() async throws {
        let html = html().replacingOccurrences(of: "1/1", with: "1/2").replacingOccurrences(of: "</div><div class='comments'>", with: "<div class='swiper-slide' data-swiper-slide-index='1'><img src='https://sns-web-i10.rednotecdn.com/second'></div></div><div class='comments'>")
        let prepared = try XiaohongshuImport.prepare(data: mime(html: html, resources: [(image, WechatCaptureTests.png())]), source: CaptureSourceURL(url))
        let completed = try await XiaohongshuImageDownload.supplement(prepared) { url in
            XCTAssertEqual(url.absoluteString, "https://sns-web-i10.rednotecdn.com/second")
            return WechatCaptureTests.png()
        }
        let article = try XiaohongshuImport.article(completed, packageID: "complete")
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertEqual(article.assets.count, 2)
        XCTAssertEqual(try SwiftSoup.parse(article.html).select("img").count, 2)
    }

    func testSupplementFailureStaysMissingAndRequestHasNoCredentials() async throws {
        let prepared = try XiaohongshuImport.prepare(data: mime(html: html(), resources: []), source: CaptureSourceURL(url))
        let partial = try await XiaohongshuImageDownload.supplement(prepared) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(try XiaohongshuImport.article(partial, packageID: "partial").missingImages.count, 1)
        let request = try XiaohongshuImageDownload.request(for: URL(string: image)!, source: URL(string: url + "?xsec_token=private")!)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.value(forHTTPHeaderField: "Referer")?.contains("private") == true)
        for invalid in ["https://127.0.0.1/image", "https://rednotecdn.com.evil.test/photo", "file:///private/tmp/photo", "https://user:pass@sns-web-i10.rednotecdn.com/photo"] {
            XCTAssertThrowsError(try XiaohongshuImageDownload.request(for: URL(string: invalid)!, source: URL(string: url)!))
        }
    }

    func testSingleFileImportsTextAndImageWithoutSourceScriptsOrAdjacentFiles() throws {
        let article = try XiaohongshuImport.extract(data: mime(html: html(), resources: [(image, WechatCaptureTests.png())]), source: CaptureSourceURL(url), packageID: "mhtml")
        XCTAssertEqual(article.title, "保存的图文")
        XCTAssertEqual(article.author, "作者")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
        XCTAssertTrue(article.html.contains("正文第一段"))
        XCTAssertFalse(article.html.contains("外部评论")); XCTAssertFalse(article.html.contains("script"))
        XCTAssertFalse(article.html.contains("sign=keep")); XCTAssertFalse(article.html.contains("file:"))
    }

    func testIncompleteArchivePreservesImagePositionAndNeverReportsComplete() throws {
        let html = html().replacingOccurrences(of: "1/1", with: "1/2").replacingOccurrences(of: "</div><div class='comments'>", with: "<div class='swiper-slide' data-swiper-slide-index='1'><img src='https://sns-web-i10.rednotecdn.com/missing'></div></div><div class='comments'>")
        let article = try XiaohongshuImport.extract(data: mime(html: html, resources: [(image, WechatCaptureTests.png())]), source: CaptureSourceURL(url), packageID: "partial")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertEqual(article.missingImages.count, 1)
        XCTAssertEqual(article.resourceReport?.issues.first?.position, 2)
    }

    func testWrongSourceVideoAndIncompleteCarouselFailExplicitly() throws {
        for data in [mime(html: html(), resources: [], location: "https://www.rednote.com/discovery/item/other"), mime(html: html() + "<video src='https://video.test/video.mp4'></video>", resources: []), mime(html: html().replacingOccurrences(of: "1/1", with: "1/8"), resources: [])] {
            XCTAssertThrowsError(try XiaohongshuImport.extract(data: data, source: CaptureSourceURL(url), packageID: "invalid"))
        }
    }

    func testMalformedOrOversizedMIMEAndUnknownEncodingAreRejected() throws {
        let good = mime(html: html(), resources: [])
        for data in [Data("not an archive".utf8), Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "base64", with: "unsupported").utf8), Data(String(decoding: good, as: UTF8.self).replacingOccurrences(of: "--test-boundary--", with: "").utf8)] {
            XCTAssertThrowsError(try MHTMLArchive.read(data))
        }
        var limits = CaptureLimits(); limits.maximumArchiveBytes = 10
        XCTAssertThrowsError(try MHTMLArchive.read(good, limits: limits))
    }

    func testQuotedPrintableUTF8AndSoftLineBreaksDecodeWithoutExecutingScripts() throws {
        let value = "MIME-Version: 1.0\r\nContent-Type: multipart/related; boundary=\"qp-boundary\"\r\n\r\n--qp-boundary\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\nContent-Location: \(url)\r\n\r\n<p>=E4=B8=AD=E6=96=87=\r\n=3D</p>\r\n--qp-boundary--\r\n"
        let archive = try MHTMLArchive.read(Data(value.utf8))
        XCTAssertEqual(archive.html, "<p>中文=</p>")
    }

    func testFoldedContentLocationWithInitiallyEmptyHeaderIsAccepted() throws {
        let data = Data(String(decoding: mime(html: html(), resources: []), as: UTF8.self).replacingOccurrences(of: "Content-Location: \(url)", with: "Content-Location:\r\n \(url)").utf8)
        XCTAssertEqual(try MHTMLArchive.read(data).url.absoluteString, url)
    }

    private func html() -> String {
        "<title>保存的图文</title><div id='noteContainer'><div class='author'><span class='username'>作者</span></div><div id='detail-title'>保存的图文</div><div id='detail-desc'>正文第一段<br>正文第二段</div><span class='fraction'>1/1</span><div class='note-slider'><div class='swiper-slide swiper-slide-duplicate' data-swiper-slide-index='0'><img src='\(image)'></div><div class='swiper-slide' data-swiper-slide-index='0'><img src='\(image)'></div></div><div class='comments'>外部评论<img src='file:///private/tmp/secret'></div><script>evil()</script></div>"
    }

    private func mime(html: String, resources: [(String, Data)], location: String? = nil) -> Data {
        var result = "MIME-Version: 1.0\r\nContent-Type: multipart/related;\r\n boundary=\"test-boundary\"\r\n\r\n--test-boundary\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\nContent-Location: \(location ?? url)\r\n\r\n\(Data(html.utf8).base64EncodedString(options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r\n"
        for (url, data) in resources { result += "--test-boundary\r\nContent-Type: image/png\r\nContent-Transfer-Encoding: base64\r\nContent-Location: \(url)\r\n\r\n\(data.base64EncodedString(options: [.lineLength64Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]))\r\n" }
        result += "--test-boundary--\r\n"; return Data(result.utf8)
    }
}
