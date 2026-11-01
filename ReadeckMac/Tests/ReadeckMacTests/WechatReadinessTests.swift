import AppKit
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class WechatReadinessTests: XCTestCase {
    func testComputedStyleBackgroundSurvivesArchiveAndSanitization() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let (web, observer) = try await load("<style>.illustration{background-image:url('\(image)');width:50px;height:50px}</style><div id='js_content'><p>正文</p><section class='illustration'></section></div>")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        _ = try await web.callAsyncJavaScript(WechatCaptureSession.prepareScript, arguments: ["normalized": "", "readinessOptions": ["stableMS": 80, "maximumMS": 800]], in: nil, contentWorld: .defaultClient)
        let archive: Data = try await withCheckedThrowingContinuation { c in web.createWebArchiveData { c.resume(with: $0) } }
        let article = try WechatArticleParser.extract(archive: archive, source: CaptureSourceURL("https://mp.weixin.qq.com/s/test"), packageID: "test")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }
    func testSameSessionReloadRecoversFailedBytesIntoNativeArchive() async throws {
        let handler = RecoveringImageHandler()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: "fixture-image")
        let (web, observer) = try await load("<div id='js_content'><p>正文</p><img src='fixture-image://body/photo'></div>", configuration: configuration)
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        var previous: CaptureResourceReport?
        let result = try await WechatCaptureRecovery.run { round in
            if round > 0 {
                _ = try await web.callAsyncJavaScript(WechatCaptureRecovery.retryScript, arguments: ["ids": previous?.issues.compactMap(\.nodeID) ?? []], in: nil, contentWorld: .defaultClient)
            }
            _ = try await web.callAsyncJavaScript(WechatCaptureSession.prepareScript, arguments: ["normalized": "", "readinessOptions": ["stableMS": 80, "maximumMS": 800]], in: nil, contentWorld: .defaultClient)
            let data: Data = try await withCheckedThrowingContinuation { c in web.createWebArchiveData { c.resume(with: $0) } }
            previous = try WechatArticleParser.extract(archive: data, source: CaptureSourceURL("https://mp.weixin.qq.com/s/test"), packageID: "test").resourceReport
            return (data, previous)
        }
        let article = try WechatArticleParser.extract(archive: result, source: CaptureSourceURL("https://mp.weixin.qq.com/s/test"), packageID: "test")
        XCTAssertGreaterThanOrEqual(handler.requests, 2)
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }
    func testLateInsertedImageIsLoadedBeforeSnapshotAndKnownCardIsExcluded() async throws {
        let image = "data:image/png;base64," + WechatCaptureTests.png().base64EncodedString()
        let (web, observer) = try await load("<div id='js_content'><p>正文</p><mp-common-clmusic music_name='music'><img src='https://invalid.test/cover'></mp-common-clmusic></div>")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let result = try await web.callAsyncJavaScript("""
            setTimeout(()=>{const img=document.createElement('img');img.src=image;document.querySelector('#js_content').append(img);},120);
            """ + WechatCaptureSession.prepareScript + "\nreturn true;", arguments: ["normalized": "", "image": image, "readinessOptions": ["stableMS": 240, "maximumMS": 1500]], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(result as? Bool, true)
        let count = try await web.callAsyncJavaScript("return document.querySelector('#js_content').getAttribute('data-readeck-image-count');", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(count as? String, "1")
        let archive: Data = try await withCheckedThrowingContinuation { c in web.createWebArchiveData { c.resume(with: $0) } }
        let article = try WechatArticleParser.extract(archive: archive, source: CaptureSourceURL("https://mp.weixin.qq.com/s/test"), packageID: "test")
        XCTAssertEqual(article.assets.count, 1)
        XCTAssertTrue(article.missingImages.isEmpty)
    }

    func testContinuousMutationAndBrokenImageStopAtBudget() async throws {
        let (web, observer) = try await load("<div id='js_content'><p>正文</p><img src='data:image/png;base64,broken'></div>")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        let start = Date()
        _ = try await web.callAsyncJavaScript("""
            const timer=setInterval(()=>document.querySelector('p').textContent+='x',30);
            try {
            """ + WechatCaptureSession.prepareScript + "\n} finally { clearInterval(timer); }", arguments: ["normalized": "", "readinessOptions": ["stableMS": 800, "maximumMS": 400]], in: nil, contentWorld: .defaultClient)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let snapshot = try await web.callAsyncJavaScript("return JSON.parse(document.querySelector('#js_content').getAttribute('data-readeck-readiness'));", arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(snapshot?["settled"] as? Bool, false)
        XCTAssertEqual(snapshot?["failedImages"] as? Int, 1)
    }

    func testCancellationStopsObservation() async throws {
        let (web, observer) = try await load("<div id='js_content'><p>正文</p></div>")
        defer { web.stopLoading(); withExtendedLifetime(observer) {} }
        do {
            _ = try await web.callAsyncJavaScript("setTimeout(()=>globalThis.__readeckCaptureAbort=true,50);\n" + WechatCaptureSession.prepareScript, arguments: ["normalized": "", "readinessOptions": ["stableMS": 500, "maximumMS": 1000]], in: nil, contentWorld: .defaultClient)
            XCTFail("aborted observation must not succeed")
        } catch { }
    }

    private func load(_ body: String, configuration supplied: WKWebViewConfiguration? = nil) async throws -> (WKWebView, ReadinessLoadObserver) {
        _ = NSApplication.shared
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let loaded = expectation(description: "local readiness page")
        let observer = ReadinessLoadObserver { loaded.fulfill() }
        web.navigationDelegate = observer
        web.loadHTMLString("<html><body>\(body)</body></html>", baseURL: URL(string: "https://mp.weixin.qq.com/s/test"))
        await fulfillment(of: [loaded], timeout: 8)
        return (web, observer)
    }
}

@MainActor
private final class RecoveringImageHandler: NSObject, WKURLSchemeHandler {
    var requests = 0
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        requests += 1
        if requests == 1 { urlSchemeTask.didFailWithError(URLError(.networkConnectionLost)); return }
        let bytes = WechatCaptureTests.png()
        urlSchemeTask.didReceive(URLResponse(url: urlSchemeTask.request.url!, mimeType: "image/png", expectedContentLength: bytes.count, textEncodingName: nil))
        urlSchemeTask.didReceive(bytes); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
}

@MainActor
private final class ReadinessLoadObserver: NSObject, WKNavigationDelegate {
    let ready: () -> Void
    init(_ ready: @escaping () -> Void) { self.ready = ready }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready() }
}
