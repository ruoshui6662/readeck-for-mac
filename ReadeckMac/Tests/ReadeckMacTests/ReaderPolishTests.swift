import XCTest
@testable import ReadeckMac

final class ReaderPolishTests: XCTestCase {
    func testRenamingIsADurableIndependentPatchFieldAndDetectsRemoteTitleChanges() throws {
        let item = Bookmark(id: "one", url: "https://example.com", title: "Old", labels: ["keep"])
        var mutation = PendingMutation(bookmark: item, patch: BookmarkPatch(title: "New"))
        mutation.merge(BookmarkPatch(isMarked: true), baselineBookmark: item)
        let roundtrip = try JSONDecoder().decode(PendingMutation.self, from: JSONEncoder().encode(mutation))
        XCTAssertEqual(roundtrip.desired.applying(to: item).title, "New")
        XCTAssertEqual(roundtrip.desired.fields["title"] as? String, "New")
        var remote = item; remote.title = "Elsewhere"
        XCTAssertTrue(roundtrip.desired.conflicts(with: remote, baseline: roundtrip.baseline))
        remote.title = "New"; remote.isMarked = true
        XCTAssertTrue(roundtrip.desired.isSatisfied(by: remote))
        XCTAssertFalse(BookmarkPatch(title: "New").isEmpty)
    }
    func testReadableCategoryNamesRoundTripLiteralPercentAndPreserveLegacyDecoding() throws {
        XCTAssertEqual(CategoryCodec.label(for: "微信"), "分类/微信")
        XCTAssertEqual(CategoryCodec.name(from: "mac-category/%E5%BE%AE%E4%BF%A1"), "微信")
        XCTAssertEqual(CategoryCodec.name(from: "分类/增长50%"), "增长50%")
        XCTAssertEqual(try CategoryCodec.labelsForWrite(["mac-category/%E5%BE%AE%E4%BF%A1", "经济"]), ["经济", "分类/微信"])
        XCTAssertFalse(CategoryCodec.assignment(in: ["分类/微信", "mac-category/%E5%BE%AE%E4%BF%A1"]).hasConflict)
    }
    func testCategoryMigrationPersistsAliasesAndLeavesUncertainSaveIdentityIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let old = "mac-category/%E5%BE%AE%E4%BF%A1"
        try await store.upsert(Bookmark(id: "one", url: "https://example.com", labels: [old, "经济"]), instance: "test")
        var pending = PendingSave(url: "https://example.com/new", title: "", labels: [old])
        pending.attemptedAt = Date()
        try await store.updatePending(pending, instance: "test")
        try await store.prepareReadableCategories(instance: "test")
        let book = try await store.bookmark(id: "one", instance: "test")
        XCTAssertEqual(book?.labelValues, ["分类/微信", "经济"])
        let jobs = try await store.actions(instance: "test")
        XCTAssertEqual(jobs.filter { $0.kind == .renameLabel }.count, 1)
        let queued = try await store.pending(instance: "test")
        XCTAssertEqual(queued.first?.labels, [old])
        let reopened = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let clean = try await reopened.cleanLabels([old, "经济"], instance: "test")
        XCTAssertEqual(clean, ["分类/微信", "经济"])
        let other = try await reopened.cleanLabels([old], instance: "other")
        XCTAssertEqual(other, [old])
    }
    func testMigrationRebasesQueuedEditsAndOnlyRewritesUnsentSaves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let old = "mac-category/%E5%BE%AE%E4%BF%A1"
        let item = Bookmark(id: "one", url: "https://example.com", labels: [old, "经济"])
        try await store.upsert(item, instance: "test")
        try await store.enqueueMutation(PendingMutation(bookmark: item, patch: BookmarkPatch(labels: [old, "经济", "new"])), instance: "test")
        let unsent = PendingSave(url: "https://example.com/new", title: "", labels: [old])
        try await store.updatePending(unsent, instance: "test")
        try await store.prepareReadableCategories(instance: "test")
        let mutation = try await store.mutation(id: "one", instance: "test")
        XCTAssertEqual(mutation?.baseline.labels, ["分类/微信", "经济"])
        XCTAssertEqual(mutation?.desired.labels, ["分类/微信", "经济", "new"])
        let saves = try await store.pending(instance: "test")
        XCTAssertEqual(saves.first?.labels, ["分类/微信"])
        var uncertain = unsent; uncertain.attemptedAt = Date(); uncertain.labels = [old]
        try await store.updatePending(uncertain, instance: "test")
        let persisted = try await store.pending(instance: "test")
        XCTAssertEqual(persisted.first?.labels, [old], "A lost POST must keep the exact submitted labels, even after aliases exist")
    }

    func testDeletingMigratedCategoryCancelsRenameAndDeletesBothNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let old = "mac-category/old"
        try await store.upsert(Bookmark(id: "one", url: "https://example.com", labels: [old, "keep"]), instance: "test")
        try await store.prepareReadableCategories(instance: "test")
        try await store.enqueueDeleteLabel(name: "分类/old", instance: "test")
        try await store.prepareReadableCategories(instance: "test")
        let actions = try await store.actions(instance: "test")
        XCTAssertFalse(actions.contains { $0.kind == .renameLabel })
        XCTAssertEqual(Set(actions.filter { $0.kind == .deleteLabel }.compactMap(\.label)), Set([old, "分类/old"]))
        let late = try await store.cleanLabels([old, "分类/old", "keep"], instance: "test")
        XCTAssertEqual(late, ["keep"])
    }

    func testInflightRenameKeepsLaterTitleAndAdvancesBaseline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let original = Bookmark(id: "one", url: "https://example.com", title: "Original", labels: ["keep"])
        try await store.upsert(original, instance: "test")
        try await store.mergeMutation(bookmark: original, patch: BookmarkPatch(title: "First"), instance: "test")
        let firstValue = try await store.mutation(id: "one", instance: "test")
        let first = try XCTUnwrap(firstValue)
        try await store.mergeMutation(bookmark: original, patch: BookmarkPatch(title: "Second"), instance: "test")
        var remote = original; remote.title = "First"
        try await store.completeMutation(id: "one", revision: first.revision, sentPatch: first.desired,
                                         updated: remote, instance: "test")
        let latestValue = try await store.mutation(id: "one", instance: "test")
        let latest = try XCTUnwrap(latestValue)
        XCTAssertEqual(latest.desired.title, "Second")
        XCTAssertEqual(latest.baseline.title, "First")
        XCTAssertFalse(latest.desired.conflicts(with: remote, baseline: latest.baseline))
        XCTAssertEqual(latest.desired.applying(to: remote).labels, ["keep"])
    }

}
