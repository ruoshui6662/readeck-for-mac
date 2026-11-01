import AppKit
import SwiftUI
import XCTest
@testable import ReadeckMac

@MainActor
final class BookmarkListUITests: XCTestCase {
    func testInlineStarDoesNotOpenOrSelectArticle() async throws {
        let state = ListUIState()
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let rect = table.rect(ofRow: table.numberOfRows - 2)
        // The persistent starred button occupies the first trailing action slot.
        try click(NSPoint(x: table.bounds.maxX - 92, y: rect.midY), view: table, window: window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.patches.map(\.0), ["a"])
        XCTAssertEqual(state.patches.first?.1, BookmarkPatch(isMarked: false))
        XCTAssertNil(state.opened)
        XCTAssertFalse(state.selection.isSelecting)
    }
    func testNativeRowOpensAndCheckboxTogglesOnlyOnceAcrossResize() async throws {
        let state = ListUIState()
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let row = table.numberOfRows - 2
        let rect = table.rect(ofRow: row)
        try click(NSPoint(x: rect.midX, y: rect.midY), view: table, window: window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.opened, "a")
        state.opened = nil
        state.selection.begin()
        try await Task.sleep(for: .milliseconds(100))
        let selectingTable = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let selectingRect = selectingTable.rect(ofRow: selectingTable.numberOfRows - 2)
        try click(NSPoint(x: 50, y: selectingRect.midY), view: selectingTable, window: window)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(state.selection.ids, ["a"])
        XCTAssertNil(state.opened)
        window.setContentSize(NSSize(width: 500, height: 550))
        state.density = .compact
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(state.selection.ids, ["a"])
        XCTAssertTrue(state.selection.isSelecting)
        let resizedTable = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let resizedRect = resizedTable.rect(ofRow: resizedTable.numberOfRows - 2)
        try click(NSPoint(x: 48, y: resizedRect.midY), view: resizedTable, window: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(state.selection.ids.isEmpty)
    }
    func testCommandAndShiftClicksSelectWithoutOpening() async throws {
        let state = ListUIState()
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        var table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        var rect = table.rect(ofRow: table.numberOfRows - 2)
        try clickWindow(table.convert(NSPoint(x: 320, y: rect.midY), to: nil), window: window, modifiers: .command)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.selection.isSelecting)
        XCTAssertEqual(state.selection.ids, ["a"])
        XCTAssertNil(state.opened)
        table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        rect = table.rect(ofRow: table.numberOfRows - 1)
        try clickWindow(table.convert(NSPoint(x: 320, y: rect.midY), to: nil), window: window, modifiers: .shift)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.selection.ids, ["a", "b"])
        XCTAssertNil(state.opened)
    }
    func testPendingSavesCannotEnterSelection() async throws {
        let state = ListUIState()
        state.selection.begin()
        let (window, host) = makeWindow(state, pending: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let row = table.numberOfRows - 4
        let rect = table.rect(ofRow: row)
        try click(NSPoint(x: rect.midX, y: rect.midY), view: table, window: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(state.selection.ids.isEmpty)
        XCTAssertNil(state.opened)
    }
    private func makeWindow(_ state: ListUIState, pending: Bool = false) -> (NSWindow, NSView) {
        _ = NSApplication.shared; NSApp.finishLaunching()
        let host = NSHostingView(rootView: ListUIFixture(state: state, pending: pending)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 550), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        return (window, host)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func click(_ point: NSPoint, view: NSView, window: NSWindow) throws { try clickWindow(view.convert(point, to: nil), window: window) }
    private func clickWindow(_ point: NSPoint, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }
}

@MainActor private final class ListUIState: ObservableObject {
    @Published var opened: String?
    @Published var selection = LibrarySelection()
    @Published var density = LibraryListDensity.standard
    var patches: [(String, BookmarkPatch)] = []
}
private struct ListUIFixture: View {
    @ObservedObject var state: ListUIState
    let pending: Bool
    var body: some View {
        BookmarkListView(selectedID: $state.opened,
            bookmarks: [Bookmark(id: "a", url: "https://example.com/a", title: "第一篇", siteName: "来源", labels: ["分类/科技", "阅读"], isMarked: true),
                        Bookmark(id: "b", url: "https://example.com/b", title: "第二篇")],
            pending: pending ? [PendingSave(url: "https://example.com/pending", title: "尚未发送", labels: [])] : [],
            selection: $state.selection, density: state.density,
            onPatch: { state.patches.append(($0.id, $1)) })
    }
}
