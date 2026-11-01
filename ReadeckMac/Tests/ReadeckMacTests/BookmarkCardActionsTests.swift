import AppKit
import SwiftUI
import XCTest
@testable import ReadeckMac

@MainActor final class BookmarkCardActionsTests: XCTestCase {
    func testFocusedStarAndArchiveDoNotOpenOrSelectCard() async throws {
        let state = CardActionState()
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        // First 252pt card is centered in a 700pt, two-column collection.
        try await focusCard(host: host, window: window)
        try click(NSPoint(x: 260, y: 48), host: host, window: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state.patches.first?.0, "a")
        XCTAssertEqual(state.patches.first?.1, BookmarkPatch(isMarked: false))
        XCTAssertNil(state.opened)
        XCTAssertFalse(state.selection.isSelecting)
        try click(NSPoint(x: 288, y: 48), host: host, window: window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(state.patches.last?.1, BookmarkPatch(isArchived: true))
        XCTAssertEqual(state.patches.count, 2)
        XCTAssertNil(state.opened)
        XCTAssertFalse(state.selection.isSelecting)
    }
    func testTabReachesQuickActionsAndSpaceExecutesWithoutOpening() async throws {
        let state = CardActionState()
        state.delayedPatch = true
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        try await focusCard(host: host, window: window)
        try key("\t", code: 48, window: window)
        try await Task.sleep(for: .milliseconds(80))
        try key(" ", code: 49, window: window)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(state.patches.first?.1, BookmarkPatch(isMarked: false))
        XCTAssertNil(state.opened)
        try key("\t", code: 48, window: window)
        try await Task.sleep(for: .milliseconds(80))
        try key(" ", code: 49, window: window)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(state.patches.last?.1, BookmarkPatch(isArchived: true))
        XCTAssertEqual(state.patches.count, 2)
        XCTAssertNil(state.opened)
        XCTAssertFalse(state.selection.isSelecting)
    }
    func testHiddenActionsPassThroughToOpenAndModifiersStillSelect() async throws {
        let state = CardActionState()
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        try click(NSPoint(x: 260, y: 48), host: host, window: window)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(state.opened, "a")
        XCTAssertTrue(state.patches.isEmpty)
        state.opened = nil
        try click(NSPoint(x: 160, y: 90), host: host, window: window, modifiers: .command)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(state.selection.ids, ["a"])
        XCTAssertNil(state.opened)
        try click(NSPoint(x: 450, y: 90), host: host, window: window, modifiers: .shift)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(state.selection.ids, ["a", "b"])
        XCTAssertNil(state.opened)
    }
    func testSelectionModeSuppressesFocusedActionsAndTogglesOnce() async throws {
        let state = CardActionState(); state.selection.begin()
        let (window, host) = makeWindow(state)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(180))
        try await focusCard(host: host, window: window)
        try click(NSPoint(x: 260, y: 48), host: host, window: window)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(state.selection.ids, ["a"])
        XCTAssertTrue(state.patches.isEmpty)
        XCTAssertNil(state.opened)
        try click(NSPoint(x: 260, y: 48), host: host, window: window)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(state.selection.ids.isEmpty)
    }
    private func makeWindow(_ state: CardActionState) -> (NSWindow, NSView) {
        _ = NSApplication.shared; NSApp.finishLaunching()
        let host = NSHostingView(rootView: CardActionFixture(state: state)); host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        return (window, host)
    }
    private func click(_ top: NSPoint, host: NSView, window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws {
        let point = host.convert(NSPoint(x: top.x, y: host.isFlipped ? top.y : host.bounds.height - top.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        }
    }
    private func key(_ value: String, code: UInt16, window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)))
        }
    }
    private func focusCard(host: NSView, window: NSWindow) async throws {
        window.makeFirstResponder(host)
        NSApp.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)))
        try await Task.sleep(for: .milliseconds(80))
    }
}
@MainActor private final class CardActionState: ObservableObject {
    @Published var selection = LibrarySelection()
    var delayedPatch = false
    var opened: String?
    var patches: [(String, BookmarkPatch)] = []
}
private struct CardActionFixture: View {
    @ObservedObject var state: CardActionState
    var body: some View {
        BookmarkGridView(bookmarks: [Bookmark(id: "a", url: "https://example.com/a", title: "第一篇", siteName: "示例", isMarked: true), Bookmark(id: "b", url: "https://example.com/b", title: "第二篇")], pending: [], client: nil,
            onOpen: { state.opened = $0.id }, onRename: { _ in }, onDelete: { _ in }, selection: $state.selection,
            onPatch: { item, patch in
                if state.delayedPatch { try? await Task.sleep(for: .milliseconds(100)) }
                state.patches.append((item.id, patch))
            })
    }
}
