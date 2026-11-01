import XCTest
@testable import ReadeckMac

@MainActor
final class ReaderPreferencesTests: XCTestCase {
    func testQuickThemeSwitchUsesVisibleBrightnessAndPreservesSavedTypography() throws {
        let name = "readck-theme-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ReaderPreferences(defaults: defaults)
        preferences.style.fontFamily = "songti"
        preferences.style.fontSize = 21
        preferences.style.paragraphSpacing = 1.25
        preferences.style.imageWidth = 80
        let cases: [(String, Bool, String)] = [
            ("system", false, "dark"), ("system", true, "light"),
            ("light", true, "dark"), ("dark", false, "light"),
            ("sepia", true, "dark"), ("sepia", false, "dark")
        ]
        for (theme, systemIsDark, expected) in cases {
            preferences.style.theme = theme
            var expectedStyle = preferences.style
            expectedStyle.theme = expected
            preferences.toggleBrightness(systemIsDark: systemIsDark)
            XCTAssertEqual(preferences.style, expectedStyle, "Switch from \(theme), system dark: \(systemIsDark)")
            XCTAssertEqual(ReaderPreferences(defaults: defaults).style, expectedStyle)
        }
    }

    func testMigratesExistingReadingChoicesAndPersistsNewSpacing() throws {
        let name = "readck-reader-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("mono", forKey: "reader.fontFamily")
        defaults.set(18.0, forKey: "reader.fontSize")
        defaults.set(1.8, forKey: "reader.lineHeight")
        let preferences = ReaderPreferences(defaults: defaults)
        XCTAssertEqual(preferences.style.fontSize, 18)
        XCTAssertEqual(preferences.style.fontFamily, "mono")
        XCTAssertEqual(preferences.style.lineHeight, 1.8)
        preferences.style.paragraphSpacing = 1.4
        preferences.style.letterSpacing = 0.04
        let reopened = ReaderPreferences(defaults: defaults)
        XCTAssertEqual(reopened.style.paragraphSpacing, 1.4)
        XCTAssertEqual(reopened.style.letterSpacing, 0.04)
    }

    func testInvalidPersistedValuesUseSafeRangesAndResetDoesNotEraseOtherSettings() throws {
        let name = "readck-reader-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(500.0, forKey: "reader.fontSize")
        defaults.set(-3.0, forKey: "reader.lineHeight")
        defaults.set("http://nas.example/", forKey: "serverURL")
        let preferences = ReaderPreferences(defaults: defaults)
        XCTAssertLessThanOrEqual(preferences.style.fontSize, 30)
        XCTAssertGreaterThanOrEqual(preferences.style.lineHeight, 1.2)
        preferences.reset()
        XCTAssertEqual(preferences.style.fontSize, 15)
        XCTAssertEqual(defaults.string(forKey: "serverURL"), "http://nas.example/")
    }
    func testReflowDefaultsPersistAndCompatibilityIsScopedToConnectionAndArticle() throws {
        let name = "readck-reader-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(19.0, forKey: "reader.fontSize")
        let preferences = ReaderPreferences(defaults: defaults)
        XCTAssertEqual(preferences.style.imageSpacing, 1)
        XCTAssertEqual(preferences.style.imageWidth, 100)
        XCTAssertFalse(preferences.style.firstLineIndent)
        XCTAssertEqual(preferences.style.alignment, "justify")
        let scope = AnnotationScope(bookmarkID: "one", connectionID: "nas-a")
        preferences.setCompatibility(true, for: scope)
        preferences.style.imageSpacing = 1.5
        preferences.style.imageWidth = 75
        preferences.style.firstLineIndent = true
        preferences.style.alignment = "left"
        let reopened = ReaderPreferences(defaults: defaults)
        XCTAssertEqual(reopened.style.fontSize, 19)
        XCTAssertEqual(reopened.style.imageSpacing, 1.5)
        XCTAssertEqual(reopened.style.imageWidth, 75)
        XCTAssertTrue(reopened.style.firstLineIndent)
        XCTAssertEqual(reopened.style.alignment, "left")
        XCTAssertTrue(reopened.usesCompatibility(for: scope))
        XCTAssertFalse(reopened.usesCompatibility(for: AnnotationScope(bookmarkID: "one", connectionID: "nas-b")))
        XCTAssertFalse(reopened.usesCompatibility(for: AnnotationScope(bookmarkID: "two", connectionID: "nas-a")))
        reopened.setCompatibility(false, for: scope)
        XCTAssertFalse(ReaderPreferences(defaults: defaults).usesCompatibility(for: scope))
    }

    func testReflowValuesClampAndPresetsRestoreCoherentLayout() throws {
        var style = ReaderStyle.standard
        style.imageSpacing = .infinity
        style.imageWidth = 900
        style.alignment = "unsafe"
        XCTAssertEqual(style.normalized.imageSpacing, 1)
        XCTAssertEqual(style.normalized.imageWidth, 100)
        XCTAssertEqual(style.normalized.alignment, "justify")
        let name = "readck-reader-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ReaderPreferences(defaults: defaults)
        preferences.style.imageSpacing = 1.5
        XCTAssertEqual(preferences.presetName, "custom")
        preferences.applyPreset("comfortable")
        XCTAssertEqual(preferences.style.imageSpacing, 1)
        XCTAssertEqual(preferences.presetName, "comfortable")
    }

}
