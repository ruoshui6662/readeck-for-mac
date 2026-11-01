import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderOutlinePreferencesTests: XCTestCase {
    func testOutlineChoicePersistsAndTypographyPresetsDoNotReplaceIt() throws {
        let suite = "outline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ReaderPreferences(defaults: defaults)
        XCTAssertEqual(preferences.outlinePresentation, .immersive)
        preferences.outlinePresentation = .classic
        preferences.applyPreset("large")
        XCTAssertEqual(ReaderPreferences(defaults: defaults).outlinePresentation, .classic)
        preferences.reset()
        XCTAssertEqual(ReaderPreferences(defaults: defaults).outlinePresentation, .classic)
        defaults.set("obsolete-value", forKey: "reader.outlinePresentation")
        XCTAssertEqual(ReaderPreferences(defaults: defaults).outlinePresentation, .immersive)
    }

    func testInlineCollapseDoesNotChangeDirectoryStyleAndOpenRestoresIt() {
        var state = ReaderOutlineVisibility()
        XCTAssertFalse(state.isCollapsed)
        state.toggle()
        XCTAssertTrue(state.isCollapsed)
        state.open()
        XCTAssertFalse(state.isCollapsed)
        state.toggle()
        state.toggle()
        XCTAssertFalse(state.isCollapsed)
    }

    func testDirectoryMovesOutOfTheTextColumnWhenAvailableWidthIsTooSmall() {
        XCTAssertTrue(ReaderOutlinePresentation.immersive.showsInline(at: 980, hasHeadings: true))
        XCTAssertFalse(ReaderOutlinePresentation.immersive.showsInline(at: 720, hasHeadings: true))
        XCTAssertFalse(ReaderOutlinePresentation.immersive.showsInline(at: 980, hasHeadings: false))
        XCTAssertFalse(ReaderOutlinePresentation.classic.showsInline(at: 980, hasHeadings: true))
    }
}
