import Combine
import XCTest
@testable import ReadeckMac

@MainActor
final class LibraryModelTests: XCTestCase {
    private func context() throws -> (URL, LocalStore, ReadeckClient) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineLibraryProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://library.test/"), token: "test",
                                   session: URLSession(configuration: configuration))
        return (directory, store, client)
    }

    func testBulkOfflineUpdatesLibrarySearchAndRestoresReceipt() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = [Bookmark(id: "one", url: "https://example.com/1", labels: ["keep1"]), Bookmark(id: "two", url: "https://example.com/2", labels: ["keep2"])]
        for book in books { try await store.upsert(book, instance: client.storageInstance) }
        let model = AppModel(client: client, store: store)
        await model.loadCached();model.searchResults = books
        let saved = await model.applyBulk(id: "batch", bookmarks: books, intent: .organize(category: .keep, adding: ["new"], removing: []))
        XCTAssertTrue(saved);XCTAssertFalse(model.isApplyingBulk)
        XCTAssertTrue(model.bookmarks.allSatisfy { $0.labelValues.contains("new") })
        XCTAssertTrue(model.searchResults?.allSatisfy { $0.labelValues.contains("new") } == true)
        XCTAssertEqual(model.bulkOperations.first?.items.count, 2)
        model.cancelSync()
    }

    func testBulkResolutionReconcilesOptimisticSearchAndPrunesMissingArticle() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Bookmark(id: "one", url: "https://example.com/1", labels: ["keep"], isMarked: false)
        try await store.upsert(book, instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        await model.loadCached()
        _ = try await store.enqueueBulk(id: "first", bookmarks: [book], intent: .star(true), instance: client.storageInstance)
        await model.loadCached();model.searchResults = model.bookmarks
        await model.resolveBulkConflict(id: book.id, keepLocal: false)
        XCTAssertEqual(model.searchResults?.first?.isMarked, false)
        _ = try await store.enqueueBulk(id: "second", bookmarks: [book], intent: .star(true), instance: client.storageInstance)
        await model.loadCached();model.searchResults = model.bookmarks
        await model.discardMissingBulk(id: book.id)
        XCTAssertTrue(model.searchResults?.isEmpty == true)
        model.cancelSync()
    }

    func testOfflineRenameImmediatelyUpdatesSearchResultAndLibrary() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = Bookmark(id: "one", url: "https://example.com", title: "Original", labels: ["keep"])
        try await store.upsert(item, instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        await model.loadCached()
        model.searchResults = [item]
        let saved = await model.updateBookmark(item, patch: BookmarkPatch(title: "Renamed"))
        XCTAssertTrue(saved)
        XCTAssertEqual(model.bookmarks.first?.title, "Renamed")
        XCTAssertEqual(model.searchResults?.first?.title, "Renamed")
        XCTAssertEqual(model.pendingMutations.first?.desired.title, "Renamed")
        model.cancelSync()
    }

    func testDeleteLabelUpdatesCatalogAndKeepsOtherArticleLabelsWhenOffline() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = Bookmark(id: "one", url: "https://example.com", labels: ["阅读", "保留"])
        try await store.upsert(item, instance: client.storageInstance)
        _ = try await store.togglePinnedLabel("阅读", instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        await model.loadCached()
        let saved = await model.deleteLabel("阅读")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.bookmarks.first?.labelValues, ["保留"])
        XCTAssertFalse(model.labelCatalog.tags.contains("阅读"))
        XCTAssertFalse(model.labelPreferences.pinned.contains("阅读"))
        XCTAssertTrue(model.libraryActions.contains { $0.kind == .deleteLabel })
        model.cancelSync()
    }

    func testManagerCreatesEmptySeparateDefinitionsAndRejectsKnownNames() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(client: client, store: store)
        await model.loadCached()
        let category = await model.addManagedLabel("设计", kind: .category)
        let tag = await model.addManagedLabel("设计", kind: .tag)
        let duplicate = await model.addManagedLabel("设计", kind: .tag)
        XCTAssertTrue(category)
        XCTAssertTrue(tag)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(model.labelCatalog.categories, ["设计"])
        XCTAssertEqual(model.labelCatalog.tags, ["设计"])
        let saves = try await store.pending(instance: client.storageInstance)
        let actions = try await store.actions(instance: client.storageInstance)
        XCTAssertTrue(saves.isEmpty)
        XCTAssertTrue(actions.isEmpty, "Empty definitions must not require server placeholder writes")
        model.cancelSync()
    }

    func testDeletingCategoryRemovesAllLegacyAliasesAndPreservesSameNamedTag() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonical = CategoryCodec.label(for: "科技")
        let legacy = "mac-category/科技"
        let item = Bookmark(id: "one", url: "https://example.com", labels: [canonical, legacy, "科技", "阅读"])
        try await store.upsert(item, instance: client.storageInstance)
        _ = try await store.addManagedLabel("科技", kind: .category, instance: client.storageInstance)
        _ = try await store.addManagedLabel("科技", kind: .tag, instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        await model.loadCached()
        let saved = await model.deleteLabel(canonical)
        XCTAssertTrue(saved)
        XCTAssertEqual(model.bookmarks.first?.labelValues, ["科技", "阅读"])
        XCTAssertFalse(model.labelCatalog.categories.contains("科技"))
        XCTAssertTrue(model.labelCatalog.tags.contains("科技"))
        XCTAssertEqual(Set(model.libraryActions.filter { $0.kind == .deleteLabel }.compactMap(\.label)), Set([canonical, legacy]))
        model.cancelSync()
    }

    func testOfflineHighlightIsVisibleLocallyAndDoesNotBecomeAnotherAccountsData() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = Bookmark(id: "one", url: "https://example.com")
        try await store.upsert(item, instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        let selection = AnnotationSelection(startSelector: "p[1]", startOffset: 0,
                                            endSelector: "p[1]", endOffset: 2, text: "阅读")
        let saved = await model.createAnnotation(selection, for: item, note: "离线笔记")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.annotationItems[item.id]?.first?.note, "离线笔记")
        XCTAssertTrue(model.libraryActions.contains { $0.kind == .createAnnotation })
        let other = ReadeckClient(address: client.address, token: "other-account")
        let otherCache = try await SyncCoordinator(client: other, store: store).annotations(bookmarkID: item.id)
        XCTAssertTrue(otherCache.isEmpty)
        model.cancelSync()
    }

    func testDeleteArticleHidesItWhileKeepingAnOfflineDeletionQueued() async throws {
        let (directory, store, client) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = Bookmark(id: "one", url: "https://example.com")
        try await store.upsert(item, instance: client.storageInstance)
        let model = AppModel(client: client, store: store)
        await model.loadCached()
        let saved = await model.deleteBookmark(item)
        XCTAssertTrue(saved)
        XCTAssertFalse(model.bookmarks.contains { $0.id == item.id })
        XCTAssertTrue(model.libraryActions.contains { $0.kind == .deleteBookmark && $0.bookmarkID == item.id })
        model.cancelSync()
    }
}

private final class OfflineLibraryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)) }
    override func stopLoading() {}
}
