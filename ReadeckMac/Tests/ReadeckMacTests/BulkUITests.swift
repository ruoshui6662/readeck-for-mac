import AppKit
import SwiftUI
import XCTest
@testable import ReadeckMac

@MainActor
final class BulkUITests: XCTestCase {
    func testNativeSelectionEditorAndResultsRenderWithIndependentTargets() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [BulkUIOfflineProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://bulk-ui.test/"), token: "test-only", session: URLSession(configuration: config))
        let books = [
            Bookmark(id: "a", url: "https://example.com/a", title: "让阅读与整理保持专注", siteName: "示例来源", labels: ["分类/科技", "阅读", "AI"], readProgress: 42),
            Bookmark(id: "b", url: "https://example.com/b", title: "每篇文章保留自己的分类和标签", siteName: "数字生活", labels: ["分类/生活", "阅读"], readProgress: 70),
            Bookmark(id: "c", url: "https://example.com/c", title: "稍后阅读，也能井井有条", siteName: "示例来源", labels: ["设计"], readProgress: 0)
        ]
        for book in books { try await store.upsert(book, instance: client.storageInstance) }
        _ = try await store.enqueueBulk(id: "demo", bookmarks: books, intent: .star(true), instance: client.storageInstance)
        try await store.recordBulkFailure(bookmarkID: "b", error: SyncError.conflictingEdit(id: "b", title: "示例文章"), instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        await model.loadCached();model.cancelSync()
        var selection = LibrarySelection();selection.selectAll(books.prefix(2).map(\.id))
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let request = BulkEditorRequest(connectionID: client.storageInstance, bookmarks: books)
        let samples: [(String, AnyView, NSSize)] = [
            ("selection", AnyView(BookmarkGridView(bookmarks: books, pending: [], client: nil, onOpen: { _ in }, onRename: { _ in }, onDelete: { _ in }, selection: binding)), NSSize(width: 850,height: 560)),
            ("editor", AnyView(BulkOrganizationView(model: model, request: request)), NSSize(width: 460,height: 530)),
            ("results", AnyView(BulkResultsView(model: model, connectionID: client.storageInstance)), NSSize(width: 580,height: 500)),
            ("selection-compact-dark", AnyView(BookmarkGridView(bookmarks: books, pending: [], client: nil, onOpen: { _ in }, onRename: { _ in }, onDelete: { _ in }, selection: binding)), NSSize(width: 570,height: 560)),
            ("editor-dark", AnyView(BulkOrganizationView(model: model, request: request)), NSSize(width: 460,height: 530)),
            ("results-dark", AnyView(BulkResultsView(model: model, connectionID: client.storageInstance)), NSSize(width: 580,height: 500))
        ]
        for (name, content, size) in samples {
            let root = content.environment(\.locale, Locale(identifier: "zh-Hans"))
                .environment(\.colorScheme, name.contains("dark") ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root);host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100,y: 100), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            let appearance = NSAppearance(named: name.contains("dark") ? .darkAqua : .aqua)
            window.appearance = appearance;host.appearance = appearance
            window.isReleasedWhenClosed = false;window.contentView = host;window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(160));host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
            if let output = ProcessInfo.processInfo.environment["READECK_BULK_QA_DIR"] {
                let path = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path.appendingPathComponent("bulk-\(name).png"))
            }
            window.close()
        }
        XCTAssertEqual(selection.ids, Set(["a","b"]))
        XCTAssertEqual(request.bookmarks.map(\.id), ["a","b","c"])
        model.cancelSync()
    }
    func testNativeCollectionSelectAllAndEscapeDoNotOverrideSearchFieldSelection() async throws {
        _ = NSApplication.shared
        // Command-line XCTest has no application key window or default Edit
        // menu. Install an explicit menu target once the field is focused.
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        NSApp.mainMenu = nil
        let state = BulkKeyboardState()
        let host = NSHostingView(rootView: BulkKeyboardFixture(state: state));host.sizingOptions = []
        let content = NSView(frame: NSRect(x: 0,y: 0,width: 700,height: 500))
        host.frame = NSRect(x: 0,y: 0,width: 700,height: 450);content.addSubview(host)
        let field = NSTextField(frame: NSRect(x: 10,y: 460,width: 300,height: 24));field.stringValue = "search words";content.addSubview(field)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false;window.contentView = content;window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(160))
        func send(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            NSApp.sendEvent(event)
        }
        try send("a", code: 0, modifiers: .command)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(state.selection.ids, Set(["a","b","c"]))
        try send("\u{1b}", code: 53)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(state.selection.isSelecting)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3,length: 0))
        XCTAssertTrue(window.firstResponder === editor)
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let selectAll = editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAll.target = editor
        edit.submenu = editMenu;menu.addItem(edit);NSApp.mainMenu = menu
        try send("a", code: 0, modifiers: .command)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0,length: 12))
        XCTAssertTrue(state.selection.ids.isEmpty)
    }

}

private final class BulkUIOfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

@MainActor
private final class BulkKeyboardState {
    var selection = LibrarySelection()
}

private struct BulkKeyboardFixture: View {
    let state: BulkKeyboardState
    @State private var selection = LibrarySelection()
    @FocusState private var focused: Bool
    var body: some View {
        Color.clear
            .modifier(CollectionSelectionKeys(selection: $selection, visibleIDs: ["a","b","c"]))
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: selection) { _, value in state.selection = value }
    }
}
