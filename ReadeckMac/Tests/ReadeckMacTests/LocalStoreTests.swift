import XCTest
@testable import ReadeckMac

final class LocalStoreTests: XCTestCase {
    func testPendingSaveSurvivesReopenAndIsolatedByServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite")
        let item = PendingSave(url: "https://example.com/article", title: "Example", labels: ["news"])

        let first = try LocalStore(url: path)
        try await first.enqueue(item, instance: "http://nas.local:8000/")
        let reopened = try LocalStore(url: path)

        let sameServer = try await reopened.pending(instance: "http://nas.local:8000/")
        let otherServer = try await reopened.pending(instance: "https://other.example/")
        XCTAssertEqual(sameServer.map(\.url), [item.url])
        XCTAssertTrue(otherServer.isEmpty)
    }

    func testBookmarkPayloadAndCursorSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite")
        let item = try JSONDecoder.readeck.decode(Bookmark.self, from: Data("""
        {"id":"abc","url":"https://example.com","title":"A story","labels":["reading"],"read_progress":25,"updated":"2026-10-24T00:00:00Z"}
        """.utf8))

        let first = try LocalStore(url: path)
        try await first.upsert(item, instance: "https://nas.example/")
        try await first.setCursor("2026-10-24T00:00:00Z", instance: "https://nas.example/")
        let reopened = try LocalStore(url: path)

        let items = try await reopened.bookmarks(instance: "https://nas.example/")
        let cursor = try await reopened.cursor(instance: "https://nas.example/")
        XCTAssertEqual(items.first?.title, "A story")
        XCTAssertEqual(cursor, "2026-10-24T00:00:00Z")
    }

    func testPendingMutationSurvivesReopenAndIsolatedByServer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library.sqlite")
        let bookmark = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":false}"#.utf8))
        let mutation = PendingMutation(bookmark: bookmark, patch: BookmarkPatch(isMarked: true))

        let first = try LocalStore(url: path)
        try await first.upsert(bookmark, instance: "http://nas.local/")
        try await first.enqueueMutation(mutation, instance: "http://nas.local/")
        let reopened = try LocalStore(url: path)

        let sameServer = try await reopened.pendingMutations(instance: "http://nas.local/")
        let otherServer = try await reopened.pendingMutations(instance: "https://other.example/")
        XCTAssertEqual(sameServer.first?.desired.isMarked, true)
        XCTAssertTrue(otherServer.isEmpty)
    }

    func testOlderMutationRevisionCannotRemoveNewerEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let bookmark = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":false}"#.utf8))
        let first = PendingMutation(bookmark: bookmark, patch: BookmarkPatch(isMarked: true))
        try await store.enqueueMutation(first, instance: "http://nas.local/")
        var newer = first
        newer.merge(BookmarkPatch(isMarked: false), baselineBookmark: bookmark)
        try await store.enqueueMutation(newer, instance: "http://nas.local/")

        let removed = try await store.removeMutation(id: "one", revision: first.revision,
                                                     instance: "http://nas.local/")
        let remaining = try await store.mutation(id: "one", instance: "http://nas.local/")
        XCTAssertFalse(removed)
        XCTAssertEqual(remaining?.revision, newer.revision)
        XCTAssertEqual(remaining?.desired.isMarked, false)
    }

    func testRemoteDeletionPreservesPendingEditUntilExplicitDiscard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let bookmark = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":false}"#.utf8))
        try await store.upsert(bookmark, instance: "http://nas.local/")
        try await store.enqueueMutation(PendingMutation(bookmark: bookmark, patch: BookmarkPatch(isMarked: true)),
                                        instance: "http://nas.local/")

        try await store.removeBookmark(id: "one", instance: "http://nas.local/")
        let stillQueued = try await store.mutation(id: "one", instance: "http://nas.local/")
        let stillVisible = try await store.bookmark(id: "one", instance: "http://nas.local/")
        XCTAssertNotNil(stillQueued)
        XCTAssertNotNil(stillVisible)

        try await store.removeBookmark(id: "one", instance: "http://nas.local/", discardPending: true)
        let discarded = try await store.mutation(id: "one", instance: "http://nas.local/")
        XCTAssertNil(discarded)
    }

    func testConcurrentEditsToDifferentFieldsCoalesceAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let bookmark = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":false,"is_archived":false}"#.utf8))
        try await store.upsert(bookmark, instance: "http://nas.local/")

        async let star: Void = store.mergeMutation(bookmark: bookmark, patch: BookmarkPatch(isMarked: true),
                                                   instance: "http://nas.local/")
        async let archive: Void = store.mergeMutation(bookmark: bookmark, patch: BookmarkPatch(isArchived: true),
                                                      instance: "http://nas.local/")
        try await star
        try await archive

        let queued = try await store.mutation(id: "one", instance: "http://nas.local/")
        XCTAssertEqual(queued?.desired.isMarked, true)
        XCTAssertEqual(queued?.desired.isArchived, true)
    }

    func testOwnInflightPatchRebasesNewerOppositeEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let original = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":false}"#.utf8))
        let serverAfterFirstPatch = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":true}"#.utf8))
        try await store.upsert(original, instance: "http://nas.local/")
        try await store.mergeMutation(bookmark: original, patch: BookmarkPatch(isMarked: true),
                                      instance: "http://nas.local/")
        let firstValue = try await store.mutation(id: "one", instance: "http://nas.local/")
        let first = try XCTUnwrap(firstValue)
        try await store.mergeMutation(bookmark: original, patch: BookmarkPatch(isMarked: false),
                                      instance: "http://nas.local/")

        try await store.completeMutation(id: "one", revision: first.revision,
                                         sentPatch: first.desired, updated: serverAfterFirstPatch,
                                         instance: "http://nas.local/")

        let queuedValue = try await store.mutation(id: "one", instance: "http://nas.local/")
        let queued = try XCTUnwrap(queuedValue)
        XCTAssertEqual(queued.desired.isMarked, false)
        XCTAssertEqual(queued.baseline.isMarked, true)
        XCTAssertFalse(queued.desired.conflicts(with: serverAfterFirstPatch, baseline: queued.baseline))
    }
}
