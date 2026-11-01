import AppKit
import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderFontCatalogTests: XCTestCase {
    func testLocalizedAndEnglishSearchKeepSameStableFamilyThroughSavedReaderStyle() throws {
        let fonts = ReaderFontCatalog.installed()
        let family = "Yuanti SC"
        let expectedName = NSFontManager.shared.localizedName(forFamily: family, face: nil)
        let font = try XCTUnwrap(fonts.first { $0.familyName == family })
        XCTAssertEqual(font.displayName, expectedName)
        XCTAssertTrue(font.matches(expectedName))
        XCTAssertTrue(font.matches("  yuanti  "))
        XCTAssertFalse(font.matches("font-that-is-not-installed"))
        XCTAssertEqual(font.selectionValue, "custom:Yuanti SC")

        let suite = "readck-font-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ReaderPreferences(defaults: defaults)
        prefs.style.fontFamily = font.selectionValue
        let restored = ReaderPreferences(defaults: defaults)
        XCTAssertEqual(restored.style.fontFamily, "custom:Yuanti SC")
        XCTAssertTrue(restored.style.css.contains("'Yuanti SC'"), "WebKit must use the stable family, not a translated label")
        XCTAssertEqual(ReaderFontCatalog.displayName(for: "Yuanti SC"), expectedName)
    }

    func testCatalogKeepsEveryRegisteredFamilyAndResolvesRealPreviewFace() throws {
        let fonts = ReaderFontCatalog.installed()
        XCTAssertEqual(Set(fonts.map(\.familyName)), Set(NSFontManager.shared.availableFontFamilies))
        let font = try XCTUnwrap(fonts.first { $0.familyName == "Songti SC" })
        let preview = try XCTUnwrap(NSFont(name: font.previewName, size: 15))
        XCTAssertEqual(preview.familyName, "Songti SC")
        XCTAssertTrue(font.matches("   "), "A cleared search restores the complete catalog")
        XCTAssertEqual(ReaderFontCatalog.displayName(for: "Uninstalled-Previously-Selected-Font"), "Uninstalled-Previously-Selected-Font")
    }
}
