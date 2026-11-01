import AppKit
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderNavigationBridgeTests: XCTestCase {
    func testScrollMessagesUpdateCurrentSectionButRejectOldDocumentAndStopAfterDismantle() async throws {
        let loaded = expectation(description: "tracking article loaded")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(WKUserScript(source: ReaderNavigationScript.bootstrap,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 400), configuration: config)
        let observer = NavigationBridgeLoadObserver { loaded.fulfill() }
        web.navigationDelegate = observer
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 540, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var current: Int?
        var received: [ReaderHeading] = []
        let html = "<h2>第一节</h2>" + String(repeating: "<p>正文段落，为目录跳转提供真实排版高度。</p>", count: 30) + "<h2>第二节</h2>" + String(repeating: "<p>结语正文。</p>", count: 30)
        let parent = ReaderWebView(html: html, baseURL: URL(string: "about:blank")!, style: .standard,
            initialProgress: 0, onProgress: { _ in }, onOutline: { received = $0 }, onCurrentHeading: { current = $0 })
        let bridge = parent.makeCoordinator()
        config.userContentController.add(bridge, contentWorld: .defaultClient, name: "readerOutline")
        defer { config.userContentController.removeScriptMessageHandler(forName: "readerOutline", contentWorld: .defaultClient) }
        bridge.load(html: html, baseURL: parent.baseURL, style: .standard, in: web)
        await fulfillment(of: [loaded], timeout: 10)
        bridge.webView(web, didFinish: nil)
        await bridge.styleTask?.value
        await bridge.navigationTask?.value
        _ = try await web.callAsyncJavaScript("window.__readerNavigation.revealHeading(1); await new Promise(r=>setTimeout(r,100)); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(current, 1)
        XCTAssertEqual(received.map(\.title), ["第一节", "第二节"])
        _ = try await web.callAsyncJavaScript("window.webkit.messageHandlers.readerOutline.postMessage({documentID:'old-document',headings:[],current:null}); await new Promise(r=>setTimeout(r,50));return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual(current, 1)
        XCTAssertEqual(received.count, 2)
        ReaderWebView.dismantleNSView(ReaderContainerView(webView: web), coordinator: bridge)
        current = nil
        _ = try await web.callAsyncJavaScript("window.scrollTo(0,0);await new Promise(r=>setTimeout(r,100));return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertNil(current)
    }

    func testCoordinatorLoadsOutlineAndLatestFindWinsWithoutReloadingArticle() async throws {
        let loaded = expectation(description: "isolated article loaded")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.userContentController.addUserScript(WKUserScript(source: ReaderNavigationScript.bootstrap,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 540, height: 400), configuration: config)
        let observer = NavigationBridgeLoadObserver { loaded.fulfill() }
        web.navigationDelegate = observer
        var outline: [ReaderHeading] = []
        var states: [ReaderFindState] = []
        let html = "<h1>文章</h1><p>中文阅读，中文批注</p><h2>第二节</h2>"
        let parent = ReaderWebView(html: html, baseURL: URL(string: "about:blank")!, style: .standard,
                                  initialProgress: 0, onProgress: { _ in },
                                  onOutline: { outline = $0 }, onFindState: { states.append($0) })
        let bridge = parent.makeCoordinator()
        bridge.load(html: html, baseURL: parent.baseURL, style: .standard, in: web)
        await fulfillment(of: [loaded], timeout: 10)
        bridge.webView(web, didFinish: nil)
        await bridge.styleTask?.value
        await bridge.navigationTask?.value
        XCTAssertEqual(outline.map(\.title), ["文章", "第二节"])
        bridge.parent.navigationRequest = ReaderNavigationRequest(action: .find("中文", 0))
        bridge.updateNavigation(in: web)
        await bridge.navigationTask?.value
        XCTAssertEqual(states.last, ReaderFindState(count: 2, current: 1))
        bridge.parent.navigationRequest = ReaderNavigationRequest(action: .find("中文", 1))
        bridge.updateNavigation(in: web)
        bridge.parent.navigationRequest = ReaderNavigationRequest(action: .find("不存在", 0))
        bridge.updateNavigation(in: web)
        await bridge.navigationTask?.value
        XCTAssertEqual(states.last, ReaderFindState(count: 0, current: 0))
        bridge.parent.navigationRequest = ReaderNavigationRequest(action: .find("", 0))
        bridge.updateNavigation(in: web)
        await bridge.navigationTask?.value
        let count = try await web.callAsyncJavaScript("return CSS.highlights.get('reader-find')?.size || 0", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertEqual((count as? NSNumber)?.intValue, 0)
        XCTAssertEqual(observer.loads, 1)
    }
}

@MainActor
private final class NavigationBridgeLoadObserver: NSObject, WKNavigationDelegate {
    var loads = 0
    let onLoad: () -> Void
    init(onLoad: @escaping () -> Void) { self.onLoad = onLoad }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loads += 1; onLoad() }
}
