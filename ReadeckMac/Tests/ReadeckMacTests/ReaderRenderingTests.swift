import AppKit
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderRenderingTests: XCTestCase {
    func testAnnotationInitializationSurvivesCancelledTypographyInitialization() async throws {
        let loaded = expectation(description: "Local annotated article loaded")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.userContentController.addUserScript(WKUserScript(source: AnnotationScript.bootstrap,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 400), configuration: configuration)
        let observer = ReaderLoadObserver { loaded.fulfill() }
        webView.navigationDelegate = observer
        let mark = BookmarkAnnotation(id: "one", startSelector: "p[1]", startOffset: 0,
                                      endSelector: "p[1]", endOffset: 2, color: "yellow", note: "", text: "阅读")
        let parent = ReaderWebView(html: "<p>阅读测试</p>", baseURL: URL(string: "about:blank")!, style: .standard,
                                   initialProgress: 0, onProgress: { _ in }, annotations: [mark])
        let coordinator = parent.makeCoordinator()
        coordinator.load(html: parent.html, baseURL: parent.baseURL, style: parent.style, in: webView)
        coordinator.updateAnnotations([mark], in: webView)
        await fulfillment(of: [loaded], timeout: 10)
        coordinator.webView(webView, didFinish: nil)
        coordinator.styleTask?.cancel()
        await coordinator.annotationTask?.value
        let count = try await webView.callAsyncJavaScript("return CSS.highlights.get('reader-annotation-yellow')?.size || 0",
                                                         arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual((count as? NSNumber)?.intValue, 1)
    }

    func testNativeStyleUpdatesChangeRenderedTextWithoutRunningSourceScriptsOrReloading() async throws {
        let loaded = expectation(description: "Local article loaded")
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 400), configuration: configuration)
        let navigation = ReaderLoadObserver { loaded.fulfill() }
        webView.navigationDelegate = navigation
        let html = "<script>document.body.dataset.sourceRan='yes'</script><p id='sample' style='font-size:99px;line-height:9'>中文阅读 Aa</p>"
            + String(repeating: "<p>用于检查阅读位置与排版的长段落。</p>", count: 35)
        let parent = ReaderWebView(html: html, baseURL: URL(string: "about:blank")!, style: .standard,
                                   initialProgress: 0, onProgress: { _ in })
        let coordinator = parent.makeCoordinator()
        coordinator.load(html: html, baseURL: URL(string: "about:blank")!, style: .standard, in: webView)
        await fulfillment(of: [loaded], timeout: 10)
        let initial = try await webView.callAsyncJavaScript("return getComputedStyle(document.getElementById('sample')).fontSize",
                                                          arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(initial as? String, "15px")
        _ = try await webView.callAsyncJavaScript("window.scrollTo(0,300); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        var updated = ReaderStyle.standard
        updated.fontSize = 22
        updated.paragraphSpacing = 1.4
        updated.letterSpacing = 0.04
        try await coordinator.applyStyle(updated, in: webView)
        let rendered = try await webView.callAsyncJavaScript("""
            const style = getComputedStyle(document.getElementById('sample'));
            return {size:style.fontSize, paragraph:style.marginBottom,
                    sourceRan:document.body.dataset.sourceRan || 'no',
                    overflow:document.body.scrollWidth > window.innerWidth,
                    scrolled:window.scrollY > 0};
            """, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
        XCTAssertEqual(rendered?["size"] as? String, "22px")
        let paragraph = try XCTUnwrap(rendered?["paragraph"] as? String)
        let paragraphPixels = try XCTUnwrap(Double(paragraph.replacingOccurrences(of: "px", with: "")))
        XCTAssertEqual(paragraphPixels, 30.8, accuracy: 0.05)
        XCTAssertEqual(rendered?["sourceRan"] as? String, "no")
        XCTAssertEqual(rendered?["overflow"] as? Bool, false)
        XCTAssertEqual(rendered?["scrolled"] as? Bool, true)
        XCTAssertEqual(navigation.loads, 1)

        // Returning to the last completed style must supersede an in-flight change.
        coordinator.updateStyle(.standard, in: webView)
        await coordinator.styleTask?.value
        coordinator.updateStyle(updated, in: webView)
        coordinator.updateStyle(.standard, in: webView)
        await coordinator.styleTask?.value
        let finalSize = try await webView.callAsyncJavaScript("return getComputedStyle(document.getElementById('sample')).fontSize",
                                                             arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(finalSize as? String, "15px")
        XCTAssertEqual(navigation.loads, 1)
    }
}

@MainActor
private final class ReaderLoadObserver: NSObject, WKNavigationDelegate {
    var loads = 0
    let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loads += 1
        onLoad()
    }
}
