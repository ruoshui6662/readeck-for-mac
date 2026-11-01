import XCTest
@testable import ReadeckMac

final class LabelCatalogTests: XCTestCase {
    func testCatalogIncludesServerCachedPendingAndPinnedTagsButSeparatesCategories() {
        var preferences = LabelPreferences()
        preferences.togglePin("常用")
        let bookmark = Bookmark(id: "one", url: "https://example.com", labels: ["已存", CategoryCodec.label(for: "科技")])
        let pending = PendingSave(url: "https://example.org", title: "", labels: ["待发送"])
        let catalog = LabelCatalog(bookmarks: [bookmark], pending: [pending],
                                   remoteNames: ["远端", "已存", CategoryCodec.label(for: "工作")],
                                   preferences: preferences)
        XCTAssertEqual(Set(catalog.tags), Set(["常用", "已存", "待发送", "远端"]))
        XCTAssertEqual(Set(catalog.categories), Set(["科技", "工作"]))
        XCTAssertEqual(catalog.matchingTags("远"), ["远端"])
        XCTAssertFalse(catalog.tags.contains { CategoryCodec.isCategoryLabel($0) })
    }

    func testUnpinKeepsArticleTagAndRecentNamesDoNotMergeCaseSensitiveLabels() {
        var preferences = LabelPreferences()
        preferences.togglePin("AI")
        preferences.recordUse(["AI", "ai", "AI"])
        preferences.togglePin("AI")
        let catalog = LabelCatalog(bookmarks: [Bookmark(id: "one", url: "https://example.com", labels: ["AI"])],
                                   pending: [], remoteNames: [], preferences: preferences)
        XCTAssertTrue(preferences.pinned.isEmpty)
        XCTAssertEqual(preferences.recent, ["AI", "ai"])
        XCTAssertEqual(Set(catalog.matchingTags("ai")), Set(["AI", "ai"]))
    }

    func testPinnedAndRecentTagsSurviveReopenWithoutCrossingConnectionPartitions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("library.sqlite")
        let store = try LocalStore(url: database)
        _ = try await store.togglePinnedLabel("设计", instance: "account-one")
        _ = try await store.recordRecentLabels(["设计", "阅读"], instance: "account-one")
        let reopened = try LocalStore(url: database)
        let own = try await reopened.labelPreferences(instance: "account-one")
        let other = try await reopened.labelPreferences(instance: "account-two")
        XCTAssertEqual(own.pinned, ["设计"])
        XCTAssertEqual(own.recent, ["设计", "阅读"])
        XCTAssertTrue(other.pinned.isEmpty)
        XCTAssertTrue(other.recent.isEmpty)
    }

    func testConcurrentPinChangesAreMergedInTheStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        async let first = store.togglePinnedLabel("AI", instance: "one")
        async let second = store.togglePinnedLabel("设计", instance: "one")
        _ = try await (first, second)
        let stored = try await store.labelPreferences(instance: "one")
        XCTAssertEqual(Set(stored.pinned), Set(["AI", "设计"]))
        XCTAssertEqual(stored.revision, 2)
    }
}
