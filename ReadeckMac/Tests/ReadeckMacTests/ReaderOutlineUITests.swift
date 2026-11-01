import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderOutlineUITests: XCTestCase {
    func testRoundedOutlineToggleRespondsToNativeClick() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        var pressed = false
        let controller = NSHostingController(rootView: ReaderOutlineToggle(collapsed: false) { pressed = true }.frame(width: 80, height: 80))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 80, height: 80))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let point = NSPoint(x: 40, y: 40)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        XCTAssertTrue(pressed)
    }

    func testStylesResizeAndNotesKeepTheSameArticleAndUnsavedDraft() async throws {
        _ = NSApplication.shared
        NSApp.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "outline-reader-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OutlineOfflineProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://outline-ui.test/"), token: "fixture", session: URLSession(configuration: config))
        let article = Bookmark(id: "outline-fixture", url: "https://example.com/article", title: "阅读目录验证", readProgress: 0, hasArticle: true)
        try await store.upsert(article, instance: client.storageInstance)
        let html = "<h2>第一章</h2>" + String(repeating: "<p>保持正文连贯，保留批注草稿。</p>", count: 25) + "<h3>第二节</h3>" + String(repeating: "<p>后续正文。</p>", count: 25)
        try await store.setArticle(html, id: article.id, instance: client.storageInstance)
        let model = AppModel(client: client, store: store, cacheDefaults: defaults)
        await model.loadCached(); model.cancelSync()
        let preferences = ReaderPreferences(defaults: defaults)
        let workspace = AnnotationWorkspace()
        let root = NavigationStack { ReaderView(model: model, workspace: workspace, bookmark: article).environmentObject(preferences) }
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 740)); window.makeKeyAndOrderFront(nil)
        defer { window.close(); model.cancelSync() }
        try await Task.sleep(for: .milliseconds(500))
        let content = try XCTUnwrap(window.contentView)
        let web = try XCTUnwrap(descendants(content, as: WKWebView.self).first)
        let before = try await identity(in: web)
        XCTAssertEqual(descendants(content, as: WKWebView.self).count, 1)
        XCTAssertFalse(labels(window).contains(AppLanguage.text("文章目录")), "Wide immersive mode keeps the directory beside the text")
        preferences.outlinePresentation = .classic
        try await Task.sleep(for: .milliseconds(180))
        workspace.showOutline()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(workspace.isPresented)
        XCTAssertEqual(workspace.panel, .outline)
        XCTAssertTrue(labels(window).contains(AppLanguage.text("目录与笔记")))
        preferences.outlinePresentation = .immersive
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(workspace.panel, .notes, "Immersive mode reserves the right panel for notes")
        preferences.outlinePresentation = .classic
        workspace.showOutline()
        workspace.close()
        preferences.outlinePresentation = .immersive
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(workspace.isPresented, "Choosing a directory style cannot reopen a closed notes panel")
        let selection = AnnotationSelection(startSelector: "p[1]", startOffset: 0, endSelector: "p[1]", endOffset: 4, text: "保持正文")
        workspace.open(AnnotationDraft(selection: selection, annotation: nil))
        workspace.note = "未保存的思考"
        preferences.outlinePresentation = .classic
        try await Task.sleep(for: .milliseconds(100))
        preferences.outlinePresentation = .immersive
        window.setContentSize(NSSize(width: 720, height: 740))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(workspace.note, "未保存的思考")
        XCTAssertNotNil(workspace.draft)
        XCTAssertFalse(workspace.needsDiscardConfirmation)
        XCTAssertTrue(labels(window).contains(AppLanguage.text("文章目录")), "A narrow reader must offer the compact directory")
        XCTAssertTrue(descendants(content, as: WKWebView.self).first === web)
        let after = try await identity(in: web)
        XCTAssertEqual(after, before, "Layout changes cannot reload or replace the article document")
        XCTAssertEqual(ReaderPreferences(defaults: defaults).outlinePresentation, .immersive)
    }

    private func identity(in web: WKWebView) async throws -> String? {
        try await web.callAsyncJavaScript("return document.body.dataset.readerDocument", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
    }
    private func labels(_ window: NSWindow) -> [String] { window.toolbar?.items.map(\.label) ?? [] }
    private func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
    }
}

private final class OutlineOfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
