import XCTest
import SQLite3
@testable import ReadeckMac

final class BulkOrganizationTests: XCTestCase {
    private func store() throws -> (LocalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try LocalStore(url: directory.appendingPathComponent("library.sqlite")), directory)
    }
    func testTagDeltasPreserveEachArticlesCategoryAndOtherTags() throws {
        let intent = BulkEditIntent.organize(category: .keep, adding: ["new"], removing: ["remove"])
        let a = Bookmark(id: "a", url: "https://example.com/a", labels: ["分类/科技", "AI", "remove"])
        let b = Bookmark(id: "b", url: "https://example.com/b", labels: ["分类/微信", "阅读"])
        XCTAssertEqual(Set(try XCTUnwrap(intent.patch(for: a).labels)), Set(["分类/科技", "AI", "new"]))
        XCTAssertEqual(Set(try XCTUnwrap(intent.patch(for: b).labels)), Set(["分类/微信", "阅读", "new"]))
        XCTAssertEqual(Set(try XCTUnwrap(BulkEditIntent.organize(category: .set("科技"), adding: [], removing: []).patch(for: b).labels)), Set(["分类/科技", "阅读"]))
        XCTAssertEqual(try BulkEditIntent.organize(category: .clear, adding: [], removing: []).patch(for: a).labels?.contains("AI"), true)
    }
    func testIncompleteMetadataAndAmbiguousCategoryAreNeverTreatedAsEmpty() throws {
        XCTAssertThrowsError(try BulkEditIntent.organize(category: .keep, adding: ["new"], removing: []).patch(for: Bookmark(id: "a", url: "https://example.com")))
        let conflict = Bookmark(id: "a", url: "https://example.com", labels: ["分类/一", "分类/二", "keep"])
        XCTAssertThrowsError(try BulkEditIntent.organize(category: .keep, adding: ["new"], removing: []).patch(for: conflict))
        XCTAssertEqual(Set(try XCTUnwrap(BulkEditIntent.organize(category: .set("三"), adding: [], removing: []).patch(for: conflict).labels)), Set(["分类/三", "keep"]))
        XCTAssertThrowsError(try BulkEditIntent.organize(category: .keep, adding: ["same"], removing: ["same"]).patch(for: conflict))
    }
    func testAtomicBatchUsesNewestPendingLabelsAndSurvivesRestartWithoutDuplicating() async throws {
        let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
        let a = Bookmark(id: "a", url: "https://example.com/a", labels: ["old"])
        let b = Bookmark(id: "b", url: "https://example.com/b", labels: ["other"])
        try await store.upsert(a, instance: "test");try await store.upsert(b, instance: "test")
        try await store.mergeMutation(bookmark: a, patch: BookmarkPatch(labels: ["old", "inflight"]), instance: "test")
        let intent = BulkEditIntent.organize(category: .keep, adding: ["new"], removing: [])
        let receipt = try await store.enqueueBulk(id: "batch", bookmarks: [a, b, a], intent: intent, instance: "test")
        XCTAssertEqual(receipt.items.count, 2)
        let queued = try await store.mutation(id: "a", instance: "test")
        XCTAssertEqual(Set(try XCTUnwrap(queued?.desired.labels)), Set(["old", "inflight", "new"]))
        let reopened = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        _ = try await reopened.enqueueBulk(id: "batch", bookmarks: [a], intent: .star(true), instance: "test")
        let receipts = try await reopened.bulkOperations(instance: "test")
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].intent, intent)
        let mutations = try await reopened.pendingMutations(instance: "test")
        XCTAssertEqual(mutations.count, 2)
        let other = try await reopened.bulkOperations(instance: "other")
        XCTAssertTrue(other.isEmpty)
    }
    func testOneInvalidArticleRollsBackEveryMutationAndReceipt() async throws {
        let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
        let a = Bookmark(id: "a", url: "https://example.com/a", labels: [])
        let b = Bookmark(id: "b", url: "https://example.com/b")
        try await store.upsert(a, instance: "test");try await store.upsert(b, instance: "test")
        do { _ = try await store.enqueueBulk(id: "batch", bookmarks: [a,b], intent: .organize(category: .keep, adding: ["new"], removing: []), instance: "test");XCTFail("Must reject missing metadata") } catch {}
        let mutations = try await store.pendingMutations(instance: "test")
        let receipts = try await store.bulkOperations(instance: "test")
        XCTAssertTrue(mutations.isEmpty);XCTAssertTrue(receipts.isEmpty)
    }
    func testBulkDeleteIsAtomicAndCancelsOlderEdits() async throws {
        let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
        let books = [Bookmark(id: "a", url: "https://example.com/a", labels: []), Bookmark(id: "b", url: "https://example.com/b", labels: [])]
        for book in books { try await store.upsert(book, instance: "test") }
        _ = try await store.enqueueBulk(id: "edit", bookmarks: books, intent: .star(true), instance: "test")
        _ = try await store.enqueueBulk(id: "delete", bookmarks: books, intent: .delete, instance: "test")
        let remaining = try await store.bookmarks(instance: "test")
        let edits = try await store.pendingMutations(instance: "test")
        let actions = try await store.actions(instance: "test")
        let receipts = try await store.bulkOperations(instance: "test")
        XCTAssertTrue(remaining.isEmpty);XCTAssertTrue(edits.isEmpty)
        XCTAssertEqual(actions.filter { $0.kind == .deleteBookmark }.count, 2)
        XCTAssertTrue(try XCTUnwrap(receipts.first { $0.id == "edit" }).items.allSatisfy { $0.status == .superseded })
    }
    func testSelectionSeparatesReaderClicksAndStableRanges() {
        var selection = LibrarySelection()
        XCTAssertFalse(selection.click("a", orderedIDs: ["a","b","c","d"], command: false, shift: false))
        XCTAssertTrue(selection.click("a", orderedIDs: ["a","b","c","d"], command: true, shift: false))
        XCTAssertTrue(selection.click("c", orderedIDs: ["a","b","c","d"], command: false, shift: true))
        XCTAssertEqual(selection.ids, Set(["a","b","c"]))
        selection.reconcile(visibleIDs: ["b","c","d"])
        XCTAssertEqual(selection.ids, Set(["b","c"]))
        selection.selectAll(["b","c","d"])
        XCTAssertEqual(selection.ids.count, 3)
        selection.end();XCTAssertFalse(selection.isSelecting);XCTAssertTrue(selection.ids.isEmpty)
    }
    func testTwoHundredItemsAreQueuedOnceAndOneBadItemRollsBackWholeDelete() async throws {
        let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
        let books = (0..<200).map { Bookmark(id: "\($0)", url: "https://example.com/\($0)", labels: ["keep"]) }
        for book in books { try await store.upsert(book, instance: "test") }
        let result = try await store.enqueueBulk(id: "large", bookmarks: books, intent: .archive(true), instance: "test")
        XCTAssertEqual(result.items.count, 200)
        let actions = try await store.pendingMutations(instance: "test")
        XCTAssertEqual(actions.count, 200)
        do {
            _ = try await store.enqueueBulk(id: "bad-delete", bookmarks: books + [Bookmark(id: "missing", url: "https://example.com/missing")], intent: .delete, instance: "test")
            XCTFail("Missing target must reject deletion")
        } catch {}
        let remaining = try await store.bookmarks(instance: "test")
        let receipts = try await store.bulkOperations(instance: "test")
        XCTAssertEqual(remaining.count, 200)
        XCTAssertFalse(receipts.contains { $0.id == "bad-delete" })
        XCTAssertTrue(receipts[0].items.allSatisfy { $0.status == .queued })
    }

    func testFailedLaterEditDoesNotSupersedeEarlierBatchReceipt() async throws {
        let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
        let book = Bookmark(id: "a", url: "https://example.com/a", labels: [])
        try await store.upsert(book, instance: "test")
        _ = try await store.enqueueBulk(id: "first", bookmarks: [book], intent: .star(true), instance: "test")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_pending BEFORE INSERT ON pending_mutations BEGIN SELECT RAISE(ABORT,'injected write failure'); END;", nil, nil, nil), SQLITE_OK)
        do { try await store.mergeMutation(bookmark: book, patch: BookmarkPatch(isMarked: false), instance: "test");XCTFail("Injected failure must propagate") } catch {}
        let receipt = try await store.bulkOperations(instance: "test")
        let mutation = try await store.mutation(id: "a", instance: "test")
        XCTAssertEqual(receipt.first?.items.first?.status, .queued)
        XCTAssertEqual(mutation?.desired.isMarked, true)
    }

    func testFailedDiscardKeepsReceiptsQueueAndCachedBookmarkTogether() async throws {
        for removeBook in [false,true] {
            let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
            let book = Bookmark(id: "a", url: "https://example.com/a", labels: [])
            try await store.upsert(book, instance: "test")
            _ = try await store.enqueueBulk(id: "first", bookmarks: [book], intent: .star(true), instance: "test")
            let mutation = try await store.mutation(id: "a", instance: "test")
            var db: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("library.sqlite").path, &db), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER reject_delete BEFORE DELETE ON pending_mutations BEGIN SELECT RAISE(ABORT,'injected deletion failure'); END;", nil, nil, nil), SQLITE_OK)
            do {
                if removeBook { try await store.removeBookmark(id: "a", instance: "test", discardPending: true) }
                else { _ = try await store.removeMutation(id: "a", revision: try XCTUnwrap(mutation).revision, instance: "test") }
                XCTFail("Injected failure must propagate")
            } catch {}
            sqlite3_close(db)
            let receipts = try await store.bulkOperations(instance: "test")
            let pending = try await store.mutation(id: "a", instance: "test")
            let cached = try await store.bookmark(id: "a", instance: "test")
            XCTAssertEqual(receipts.first?.items.first?.status, .queued)
            XCTAssertNotNil(pending);XCTAssertNotNil(cached)
        }
    }

    func testOldInflightFailureCannotChangeNewerReceiptRevisionOrStatus() async throws {
        let (store, directory) = try store();defer { try? FileManager.default.removeItem(at: directory) }
        let book = Bookmark(id: "a", url: "https://example.com/a", labels: ["old"])
        try await store.upsert(book, instance: "test")
        _ = try await store.enqueueBulk(id: "first", bookmarks: [book], intent: .organize(category: .keep, adding: ["B"], removing: []), instance: "test")
        let old = try await store.mutation(id: "a", instance: "test")
        _ = try await store.enqueueBulk(id: "next", bookmarks: [book], intent: .organize(category: .keep, adding: ["C"], removing: ["B"]), instance: "test")
        let latest = try await store.mutation(id: "a", instance: "test")
        try await store.recordBulkFailure(bookmarkID: "a", revision: try XCTUnwrap(old).revision, error: SyncError.conflictingEdit(id: "a", title: "Old"), instance: "test")
        let receipts = try await store.bulkOperations(instance: "test")
        let next = try XCTUnwrap(receipts.first { $0.id == "next" }).items[0]
        XCTAssertEqual(next.status, .queued);XCTAssertEqual(next.mutationRevision, latest?.revision)
    }

}
