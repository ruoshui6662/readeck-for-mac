import SQLite3
import XCTest
@testable import ReadeckMac

final class CacheRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func context() throws -> (URL, LocalStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, try LocalStore(url: directory.appendingPathComponent("library.sqlite")))
    }

    func testPoliciesUseOnlyRequestedDurationsAndInvalidPreferenceDefaultsToThirtyDays() {
        XCTAssertEqual(CacheRetention.allCases.map(\.rawValue), [15, 30, 45, 60])
        XCTAssertEqual(CacheRetention.stored(0), .days30)
        XCTAssertEqual(CacheRetention.days15.cutoff(at: now), now.addingTimeInterval(-15 * 86_400))
    }

    func testExpirationBoundaryAndReadRenewsLifetimeAcrossPartitions() async throws {
        let (directory, store) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cutoff = CacheRetention.days30.cutoff(at: now)
        try await store.setArticle("到期", id: "expired", instance: "one", accessedAt: cutoff)
        try await store.setArticle("续期", id: "read", instance: "one", accessedAt: cutoff)
        try await store.setArticle("另一个账号", id: "expired", instance: "two", accessedAt: cutoff)
        let read = try await store.article(id: "read", instance: "one", accessedAt: now)
        XCTAssertEqual(read, "续期")
        let result = try await store.cleanArticleCache(through: cutoff)
        XCTAssertEqual(result.removedCount, 2)
        let remaining = try await store.article(id: "read", instance: "one")
        let expired = try await store.article(id: "expired", instance: "one")
        XCTAssertEqual(remaining, "续期")
        XCTAssertNil(expired)
    }

    func testManualCleanupPreservesPendingEditsNotesAndLibraryData() async throws {
        let (directory, store) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = Bookmark(id: "edit", url: "https://example.com", labels: ["保留"])
        try await store.upsert(book, instance: "one")
        try await store.mergeMutation(bookmark: book, patch: BookmarkPatch(isMarked: true), instance: "one")
        let selection = AnnotationSelection(startSelector: "p[1]", startOffset: 0, endSelector: "p[1]", endOffset: 2, text: "批注")
        try await store.enqueueAction(LibraryAction(kind: .createAnnotation, bookmarkID: "note", selection: selection, note: "未同步内容"), instance: "one")
        try await store.setArticle("正文一", id: "edit", instance: "one")
        try await store.setArticle("正文二", id: "note", instance: "one")
        try await store.setArticle("可清理", id: "free", instance: "one")
        let result = try await store.cleanArticleCache(through: nil)
        XCTAssertEqual(result.removedCount, 1)
        XCTAssertEqual(result.protectedCount, 2)
        let mutations = try await store.pendingMutations(instance: "one")
        let actions = try await store.actions(instance: "one")
        let books = try await store.bookmarks(instance: "one")
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(actions.first?.note, "未同步内容")
        XCTAssertEqual(books.first?.labelValues, ["保留"])
        let stats = try await store.articleCacheStatistics()
        XCTAssertEqual(stats.articleCount, 2)
        XCTAssertEqual(stats.protectedArticleCount, 2)
    }

    func testLateDownloadCannotRestoreDiskCacheAfterManualCleanup() async throws {
        let (directory, store) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generation = await store.articleCacheGeneration()
        _ = try await store.cleanArticleCache(through: nil)
        try await store.setArticle("清理前发起的请求", id: "late", instance: "one", generation: generation)
        let late = try await store.article(id: "late", instance: "one")
        XCTAssertNil(late)
        try await store.setArticle("重新打开后的下载", id: "new", instance: "one")
        let fresh = try await store.article(id: "new", instance: "one")
        XCTAssertEqual(fresh, "重新打开后的下载")
    }

    func testLazyReadRejectsExpiredCacheAndCleanupReclaimsDatabaseSpace() async throws {
        let (directory, store) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = now.addingTimeInterval(-61 * 86_400)
        try await store.setArticle(String(repeating: "x", count: 2_000_000), id: "large", instance: "one", accessedAt: old)
        let before = try await store.articleCacheStatistics()
        let expired = try await store.article(id: "large", instance: "one", notOlderThan: CacheRetention.days60.cutoff(at: now), accessedAt: now)
        XCTAssertNil(expired)
        _ = try await store.cleanArticleCache(through: nil)
        let after = try await store.articleCacheStatistics()
        XCTAssertEqual(after.articleCount, 0)
        XCTAssertLessThan(after.databaseBytes, before.databaseBytes)
    }

    func testLegacyArticleMigrationKeepsExistingCacheWithKnownInitialAccessTime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("library.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "CREATE TABLE articles(instance TEXT NOT NULL,id TEXT NOT NULL,html TEXT NOT NULL,PRIMARY KEY(instance,id)); INSERT INTO articles VALUES('old','one','legacy');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)
        let store = try LocalStore(url: database, cacheMigrationDate: now)
        let result = try await store.cleanArticleCache(through: now.addingTimeInterval(-1))
        XCTAssertEqual(result.removedCount, 0)
        let value = try await store.article(id: "one", instance: "old", notOlderThan: now.addingTimeInterval(-1), accessedAt: now)
        XCTAssertEqual(value, "legacy")
    }
}
