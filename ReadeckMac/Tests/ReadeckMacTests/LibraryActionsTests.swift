import Foundation
import XCTest
@testable import ReadeckMac

final class LibraryActionsTests: XCTestCase {
    private var directory: URL!
    private var store: LocalStore!
    private var client: ReadeckClient!
    private var coordinator: SyncCoordinator!
    private var instance: String { client.storageInstance }
    private let selection = AnnotationSelection(startSelector: "/p[1]", startOffset: 1,
                                                endSelector: "/p[2]", endOffset: 3, text: "🙂 words")
    private let annotationJSON = #"{"id":"server-note","start_selector":"/p[1]","start_offset":1,"end_selector":"/p[2]","end_offset":3,"text":"🙂 words","color":"yellow","note":"remember","created":"2026-10-25T00:00:00Z"}"#
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryURLProtocol.self]
        client = ReadeckClient(address: try ServerAddress("http://nas.test/"), token: "test",
                               session: URLSession(configuration: config), permissionCheck: { _ in false })
        coordinator = SyncCoordinator(client: client, store: store)
        LibraryURLProtocol.respond = { _ in (200, Data("[]".utf8)) }
    }
    override func tearDownWithError() throws {
        LibraryURLProtocol.respond = nil
        LibraryURLProtocol.hold = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func book(_ id: String = "one", labels: [String] = []) throws -> Bookmark {
        try JSONDecoder.readeck.decode(Bookmark.self, from: JSONSerialization.data(withJSONObject: [
            "id": id, "url": "https://example.com", "labels": labels
        ]))
    }

    func testReadableMigrationReconcilesUncertainPostBeforeRenaming() async throws {
        let old = "mac-category/%E5%BE%AE%E4%BF%A1"
        try await store.upsert(book(labels: [old]), instance: instance)
        var pending = PendingSave(url: "https://new.example", title: "", labels: [old])
        pending.attemptedAt = Date()
        try await store.updatePending(pending, instance: instance)
        let response = try JSONSerialization.data(withJSONObject: [[
            "id": "saved", "url": pending.url, "labels": [old],
            "created": ISO8601DateFormatter().string(from: Date())
        ]])
        var renameCount = 0
        LibraryURLProtocol.respond = { request in
            XCTAssertNotEqual(request.httpMethod, "POST", "Reconcile the delivered save without creating a duplicate")
            if request.url!.path == "/api/bookmarks" { return (200, response) }
            if request.httpMethod == "PATCH" { renameCount += 1; return (200, Data("{}".utf8)) }
            return (200, Data("[]".utf8))
        }
        let result = try await coordinator.sync()
        XCTAssertTrue(result.pending.isEmpty)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(renameCount, 1)
        XCTAssertEqual(result.bookmarks.first { $0.id == "saved" }?.labels, ["分类/微信"])
    }

    func testReadableMigrationAcceptsAlreadyRenamed404AndEncodesExactNames() async throws {
        let old = "mac-category/%E5%BE%AE%E4%BF%A1"
        try await store.upsert(book(labels: [old, "经济"]), instance: instance)
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "name" }?.value, old)
                let body = try JSONSerialization.jsonObject(with: request.libraryBody) as? [String: String]
                XCTAssertEqual(body?["name"], "分类/微信")
                return (404, Data("{}".utf8))
            }
            return (200, Data("[]".utf8))
        }
        let result = try await coordinator.sync()
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.bookmarks.first?.labels, ["分类/微信", "经济"])
    }

    func testMigrationDiscoversServerOnlyLegacyLabelsAndReplaysNextRound() async throws {
        let old = "mac-category/remote"
        var migrated = false
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" { migrated = true; return (200, Data("{}".utf8)) }
            if request.url!.path == "/api/bookmarks/labels" {
                return (200, try JSONSerialization.data(withJSONObject: [["name": migrated ? "分类/remote" : old]]))
            }
            return (200, Data("[]".utf8))
        }
        _ = try await coordinator.sync()
        let result = try await coordinator.sync()
        XCTAssertTrue(migrated)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.labelNames, ["分类/remote"])
    }

    func testSelectionBridgeDecodesSnakeCaseOffsets() throws {
        let decoded = try JSONDecoder().decode(AnnotationSelection.self, from: Data(#"{"start_selector":"/p[1]","start_offset":1,"end_selector":"/p[2]","end_offset":3,"text":"🙂 words"}"#.utf8))
        XCTAssertEqual(decoded, selection)
    }

    func testInvalidAnnotationDoesNotCreatePoisonQueueEntry() async throws {
        let invalid = AnnotationSelection(startSelector: "", startOffset: -1, endSelector: "/p[1]", endOffset: 1, text: "")
        do {
            try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: invalid, color: "yellow", note: "")
            XCTFail("Invalid selectors/offsets must be rejected")
        } catch { XCTAssertNotNil(error.localizedDescription) }
        do {
            try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: String(repeating: "a", count: 1025))
            XCTFail("Overlong notes must be rejected")
        } catch { XCTAssertNotNil(error.localizedDescription) }
        let snapshot = try await coordinator.cached()
        XCTAssertTrue(snapshot.actions.isEmpty)
    }

    func testCompletedLabelDeletionAllowsExplicitReuseAfterRoundFinishes() async throws {
        try await coordinator.enqueueDeleteLabel(name: "again")
        _ = try await coordinator.sync()
        try await coordinator.enqueue(url: "https://new.example", labels: ["again", "other"])
        let snapshot = try await coordinator.cached()
        XCTAssertEqual(snapshot.pending.first?.labels, ["again", "other"])
    }

    func testEditQueuedDuringAnnotationCreateUsesReturnedServerID() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let local = try await coordinator.annotations(bookmarkID: "one")
        let started = expectation(description: "POST began")
        let release = DispatchSemaphore(value: 0)
        let response = Data(annotationJSON.utf8)
        var patched = false
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "POST" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return (201, response)
            }
            if request.httpMethod == "PATCH" {
                patched = true
                XCTAssertEqual(request.url!.lastPathComponent, "server-note")
                return (200, Data("{}".utf8))
            }
            return (200, Data("[]".utf8))
        }
        let syncing = Task { try await self.coordinator.sync() }
        await fulfillment(of: [started], timeout: 5)
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: local[0], color: "red", note: "new note")
        release.signal()
        _ = try await syncing.value
        _ = try await coordinator.sync()
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertTrue(patched)
        XCTAssertEqual(values.first?.note, "new note")
        XCTAssertEqual(values.first?.color, "red")
    }

    func testDuplicatePendingSelectionIsCoalescedWithServerTrimmedMetadata() async throws {
        let spaced = AnnotationSelection(startSelector: " /p[1] ", startOffset: 1, endSelector: "/p[2] ", endOffset: 3, text: "🙂 words")
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: spaced, color: " yellow ", note: " remember\n")
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let cached = try await coordinator.cached()
        XCTAssertEqual(cached.actions.count, 1)
        XCTAssertEqual(cached.actions.first?.selection?.startSelector, "/p[1]")
        XCTAssertEqual(cached.actions.first?.note, "remember")
    }

    func testStaleAnnotationRefreshCannotReplaceCompletedLocalEdit() async throws {
        let annotation = try JSONDecoder.readeck.decode(BookmarkAnnotation.self, from: Data(annotationJSON.utf8))
        try await store.setAnnotations([annotation], bookmarkID: "one", instance: instance)
        let started = expectation(description: "refresh began")
        var held: LibraryURLProtocol?
        let response = Data("[\(annotationJSON)]".utf8)
        LibraryURLProtocol.hold = { proto in
            guard proto.request.url!.path.hasSuffix("annotations"), proto.request.httpMethod == "GET" else { return false }
            held = proto
            started.fulfill()
            return true
        }
        LibraryURLProtocol.respond = { _ in (200, Data("[]".utf8)) }
        let refreshing = Task { try await self.coordinator.annotations(bookmarkID: "one", refresh: true) }
        await fulfillment(of: [started], timeout: 5)
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: annotation, color: "red", note: "latest")
        _ = try await coordinator.sync()
        held?.finish(status: 200, data: response)
        let refreshed = try await refreshing.value
        XCTAssertEqual(refreshed.first?.note, "latest")
        let cached = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(cached.first?.color, "red")
    }

    func testRejectedAnnotationCanBeCancelledWithoutSendingServerDelete() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let initial = try await coordinator.annotations(bookmarkID: "one")
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "POST" { return (400, Data("invalid XPath".utf8)) }
            if request.httpMethod == "DELETE" { XCTFail("Rejected draft must cancel locally") }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        let failed = try await coordinator.cached()
        XCTAssertNil(failed.actions.first?.attemptedAt)
        try await coordinator.enqueueDeleteAnnotation(bookmarkID: "one", id: initial[0].id)
        let cancelled = try await coordinator.cached()
        XCTAssertTrue(cancelled.actions.isEmpty)
        _ = try await coordinator.sync()
    }

    func testGlobalLabelDeleteWaitsForUncertainSaveReconciliation() async throws {
        try await coordinator.enqueue(url: "https://new.example", labels: ["old"])
        try await coordinator.enqueueDeleteLabel(name: "old")
        var deletes = 0
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            if request.httpMethod == "DELETE" { deletes += 1 }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        XCTAssertEqual(deletes, 0)
        let pending = try await coordinator.cached()
        XCTAssertEqual(pending.actions.count, 1)
        let waiting = try await coordinator.sync()
        XCTAssertEqual(waiting.actions.count, 1)
        XCTAssertEqual(deletes, 0)
        let response = try JSONSerialization.data(withJSONObject: [[
            "id": "saved", "url": "https://new.example", "labels": ["old"],
            "created": ISO8601DateFormatter().string(from: Date())
        ]])
        LibraryURLProtocol.respond = { request in
            if request.url!.path == "/api/bookmarks" { return (200, response) }
            if request.httpMethod == "DELETE" { deletes += 1 }
            return (200, Data("[]".utf8))
        }
        let reconciled = try await coordinator.sync()
        XCTAssertTrue(reconciled.actions.isEmpty)
        XCTAssertTrue(reconciled.pending.isEmpty)
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(reconciled.bookmarks.first?.labels, [])
    }

    func testDeletingServerAnnotationSupersedesFailedQueuedUpdate() async throws {
        let annotation = try JSONDecoder.readeck.decode(BookmarkAnnotation.self, from: Data(annotationJSON.utf8))
        try await store.setAnnotations([annotation], bookmarkID: "one", instance: instance)
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: annotation, color: "red", note: "edit")
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" { return (404, Data()) }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        try await coordinator.enqueueDeleteAnnotation(bookmarkID: "one", id: annotation.id)
        let pending = try await coordinator.cached()
        XCTAssertEqual(pending.actions.map(\.kind), [.deleteAnnotation])
        let result = try await coordinator.sync()
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testDeletePersistsHidesBookmarkSkipsPatchAndAccepts404() async throws {
        let item = try book()
        try await store.upsert(item, instance: instance)
        try await coordinator.enqueueMutation(bookmark: item, patch: BookmarkPatch(isMarked: true))
        try await coordinator.enqueueDeleteBookmark(id: "one")
        let reopened = SyncCoordinator(client: client, store: try LocalStore(url: directory.appendingPathComponent("library.sqlite")))
        let cached = try await reopened.cached()
        XCTAssertTrue(cached.bookmarks.isEmpty)
        XCTAssertEqual(cached.actions.map(\.kind), [.deleteBookmark])
        let other = SyncCoordinator(client: ReadeckClient(address: client.address, token: "other"), store: store)
        let isolated = try await other.cached()
        XCTAssertTrue(isolated.actions.isEmpty)
        var deleted = 0
        LibraryURLProtocol.respond = { request in
            XCTAssertNotEqual(request.httpMethod, "PATCH")
            if request.httpMethod == "DELETE" { deleted += 1; return (404, Data()) }
            return (200, Data("[]".utf8))
        }
        let result = try await reopened.sync()
        XCTAssertEqual(deleted, 1)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.bookmarks.isEmpty)
    }
    func testGlobalLabelDeletionCleansEveryLocalSourceAndStaleEdits() async throws {
        let item = try book(labels: ["delete & 中", "keep"])
        try await store.upsert(item, instance: instance)
        try await store.setCachedLabelNames(["delete & 中", "keep"], instance: instance)
        _ = try await store.togglePinnedLabel("delete & 中", instance: instance)
        _ = try await store.recordRecentLabels(["delete & 中", "keep"], instance: instance)
        try await coordinator.enqueue(url: "https://new.example", labels: ["delete & 中", "keep"])
        try await coordinator.enqueueMutation(bookmark: item, patch: BookmarkPatch(labels: ["delete & 中", "keep"]))
        try await coordinator.enqueueDeleteLabel(name: "delete & 中")
        try await coordinator.enqueueMutation(bookmark: item, patch: BookmarkPatch(labels: ["delete & 中", "keep"]))
        let snapshot = try await coordinator.cached()
        XCTAssertEqual(snapshot.bookmarks.first?.labels, ["keep"])
        XCTAssertEqual(snapshot.pending.first?.labels, ["keep"])
        XCTAssertEqual(snapshot.pendingMutations.first?.desired.labels, ["keep"])
        XCTAssertEqual(snapshot.pendingMutations.first?.baseline.labels, ["keep"])
        XCTAssertEqual(snapshot.labelNames, ["keep"])
        let preferences = try await store.labelPreferences(instance: instance)
        XCTAssertTrue(preferences.pinned.isEmpty)
        XCTAssertEqual(preferences.recent, ["keep"])
    }
    func testGlobalLabelDeletionDoesNotInventConflictAgainstUnchangedRemoteLabels() async throws {
        let item = try book(labels: ["old", "keep"])
        try await store.upsert(item, instance: instance)
        try await coordinator.enqueueMutation(bookmark: item, patch: BookmarkPatch(labels: ["old", "keep", "new"]))
        try await coordinator.enqueueDeleteLabel(name: "old")
        let response = try JSONEncoder().encode(item)
        LibraryURLProtocol.respond = { request in
            if request.url!.path == "/api/bookmarks/one" { return (200, response) }
            return (200, Data("[]".utf8))
        }
        let result = try await coordinator.sync()
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.pendingMutations.isEmpty)
    }

    func testAnnotationClientUsesReadeckFieldsAndEncodedLabelQuery() async throws {
        let response = Data(annotationJSON.utf8)
        var methods: [String] = []
        LibraryURLProtocol.respond = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "DELETE" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first?.name, "name")
                XCTAssertEqual(query?.first?.value, "tag & 中/#?")
                return (204, Data())
            }
            let json = try JSONSerialization.jsonObject(with: request.libraryBody) as! [String: Any]
            XCTAssertEqual(json["color"] as? String, "yellow")
            XCTAssertEqual(json["note"] as? String, "remember")
            if request.httpMethod == "POST" {
                XCTAssertEqual(json["start_selector"] as? String, "/p[1]")
                XCTAssertEqual(json["end_offset"] as? Int, 3)
                XCTAssertNil(json["text"])
                return (201, response)
            }
            return (200, Data("{}".utf8))
        }
        let created = try await client.createAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        XCTAssertEqual(created.text, "🙂 words")
        try await client.updateAnnotation(bookmarkID: "one", id: created.id, color: "yellow", note: "remember")
        try await client.deleteLabel(name: "tag & 中/#?")
        XCTAssertEqual(methods, ["POST", "PATCH", "DELETE"])
    }
    func testFailedDeleteRemainsQueued() async throws {
        try await coordinator.enqueueDeleteBookmark(id: "one")
        LibraryURLProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await coordinator.sync(); XCTFail("Expected offline error") } catch {}
        let result = try await coordinator.cached()
        XCTAssertEqual(result.actions.count, 1)
    }
    func testLostAnnotationPostReconcilesBeforeRetryWithoutDuplicating() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let local = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(local.first?.note, "remember")
        var posts = 0
        let response = Data("[\(annotationJSON)]".utf8)
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "POST" { posts += 1; throw URLError(.networkConnectionLost) }
            if request.url!.path.hasSuffix("annotations") { return (200, response) }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync(); XCTFail("Expected uncertain error") } catch {}
        let result = try await coordinator.sync()
        XCTAssertEqual(posts, 1)
        XCTAssertTrue(result.actions.isEmpty)
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(values.map(\.id), ["server-note"])
    }
    func testUncertainAnnotationWaitsAndRequiresExactNoteMatch() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "different")
        var posts = 0
        let response = Data("[\(annotationJSON)]".utf8)
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "POST" { posts += 1; throw URLError(.timedOut) }
            if request.url!.path.hasSuffix("annotations") { return (200, response) }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        let result = try await coordinator.sync()
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(result.actions.count, 1)
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(Set(values.map(\.note)), ["different", "remember"])
    }
    func testLateEditUsingOptimisticIDAfterCreateCompletionResolvesToServerID() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let local = try await coordinator.annotations(bookmarkID: "one")
        let response = Data(annotationJSON.utf8)
        LibraryURLProtocol.respond = { request in
            request.httpMethod == "POST" ? (201, response) : (200, Data("[]".utf8))
        }
        _ = try await coordinator.sync()
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: local[0], color: "red", note: "late")
        var patched = false
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" {
                patched = true
                XCTAssertEqual(request.url!.lastPathComponent, "server-note")
            }
            return (200, Data("[]".utf8))
        }
        let result = try await coordinator.sync()
        XCTAssertTrue(patched)
        XCTAssertTrue(result.actions.isEmpty)
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(values.first?.note, "late")
    }

    func testAnnotationCacheAndOptimisticOverlayNeverRequireNetwork() async throws {
        LibraryURLProtocol.respond = { _ in XCTFail("Cached annotations must not make requests"); throw URLError(.notConnectedToInternet) }
        let empty = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertTrue(empty.isEmpty)
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "offline")
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(values.first?.note, "offline")
    }

    func testSuccessfulCreateRemapsQueuedEditAndDeletionToServerID() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let local = try await coordinator.annotations(bookmarkID: "one")
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: local[0], color: "blue", note: "changed")
        var paths: [String] = []
        let response = Data(annotationJSON.utf8)
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "POST" { return (201, response) }
            if request.httpMethod == "PATCH" {
                paths.append(request.url!.path)
                let fields = try JSONSerialization.jsonObject(with: request.libraryBody) as! [String: String]
                XCTAssertEqual(fields, ["color": "blue", "note": "changed"])
                return (200, Data("{}".utf8))
            }
            return (200, Data("[]".utf8))
        }
        let snapshot = try await coordinator.sync()
        XCTAssertTrue(snapshot.actions.isEmpty)
        XCTAssertEqual(paths, ["/api/bookmarks/one/annotations/server-note"])
        let annotations = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(annotations.first?.note, "changed")
        try await coordinator.enqueueDeleteAnnotation(bookmarkID: "one", id: "server-note")
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "DELETE" {
                XCTAssertEqual(request.url!.path, "/api/bookmarks/one/annotations/server-note")
                return (404, Data())
            }
            return (200, Data("[]".utf8))
        }
        let deleted = try await coordinator.sync()
        XCTAssertTrue(deleted.actions.isEmpty)
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertTrue(values.isEmpty)
    }

    func testFailedAnnotationEditKeepsLaterEditsInOrder() async throws {
        let annotation = try JSONDecoder.readeck.decode(BookmarkAnnotation.self, from: Data(annotationJSON.utf8))
        try await store.setAnnotations([annotation], bookmarkID: "one", instance: instance)
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: annotation, color: "blue", note: "first")
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: annotation, color: "red", note: "last")
        var patchCount = 0
        LibraryURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" { patchCount += 1; return (500, Data()) }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        let cached = try await coordinator.cached()
        XCTAssertEqual(cached.actions.count, 2)
        XCTAssertEqual(patchCount, 1)
        let values = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(values.first?.note, "last")
    }

    func testSyncEventRefreshesAnnotationsWithoutLosingPendingOverlay() async throws {
        let annotation = try JSONDecoder.readeck.decode(BookmarkAnnotation.self, from: Data(annotationJSON.utf8))
        try await store.setAnnotations([annotation], bookmarkID: "one", instance: instance)
        LibraryURLProtocol.respond = { request in
            if request.url!.path.hasSuffix("/sync") {
                return (200, Data(#"[{"id":"one","type":"update","time":"2026-10-25T01:00:00Z"}]"#.utf8))
            }
            if request.url!.path == "/api/bookmarks/one" { return (200, Data(#"{"id":"one","url":"https://example.com"}"#.utf8)) }
            return (200, Data("[]".utf8))
        }
        _ = try await coordinator.sync()
        let values = try await coordinator.annotations(bookmarkID: "one", refresh: true)
        XCTAssertTrue(values.isEmpty)
    }

    func testPendingAnnotationCanBeEditedThenDeletedBeforeUpload() async throws {
        try await coordinator.enqueueCreateAnnotation(bookmarkID: "one", selection: selection, color: "yellow", note: "remember")
        let initial = try await coordinator.annotations(bookmarkID: "one")
        try await coordinator.enqueueUpdateAnnotation(bookmarkID: "one", annotation: initial[0], color: "blue", note: "edited")
        let edited = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertEqual(edited.first?.note, "edited")
        XCTAssertEqual(edited.first?.color, "blue")
        try await coordinator.enqueueDeleteAnnotation(bookmarkID: "one", id: initial[0].id)
        let deleted = try await coordinator.annotations(bookmarkID: "one")
        XCTAssertTrue(deleted.isEmpty)
        let snapshot = try await coordinator.cached()
        XCTAssertTrue(snapshot.actions.isEmpty)
    }
}
private final class LibraryURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    static var hold: ((LibraryURLProtocol) -> Bool)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.hold?(self) == true { return }
        do {
            let (status, data) = try Self.respond!(request)
            finish(status: status, data: data)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func finish(status: Int, data: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension URLRequest {
    var libraryBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }
}
