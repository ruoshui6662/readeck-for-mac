import Foundation
import XCTest
@testable import ReadeckMac

final class SyncCoordinatorTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.respond = nil
        super.tearDown()
    }

    private func client(for address: ServerAddress) -> ReadeckClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ReadeckClient(address: address, token: "test", session: URLSession(configuration: configuration),
                             permissionCheck: { _ in false })
    }

    private func bookmark(_ json: String) throws -> Bookmark {
        try JSONDecoder.readeck.decode(Bookmark.self, from: Data(json.utf8))
    }

    func testCachedSnapshotOverlaysPendingEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let bookmark = try JSONDecoder.readeck.decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","is_marked":false}"#.utf8))
        try await store.upsert(bookmark, instance: ReadeckClient(address: address, token: "test").storageInstance)
        try await store.enqueueMutation(PendingMutation(bookmark: bookmark, patch: BookmarkPatch(isMarked: true)),
                                        instance: ReadeckClient(address: address, token: "test").storageInstance)

        let coordinator = SyncCoordinator(client: ReadeckClient(address: address, token: "test"), store: store)
        let snapshot = try await coordinator.cached()

        XCTAssertEqual(snapshot.bookmarks.first?.isMarked, true)
        XCTAssertEqual(snapshot.pendingMutations.count, 1)
    }

    func testOfflineEditSurvivesFailureThenUploadsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let original = try bookmark(#"{"id":"one","url":"https://example.com","is_marked":false}"#)
        try await store.upsert(original, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        try await coordinator.enqueueMutation(bookmark: original, patch: BookmarkPatch(isMarked: true))

        StubURLProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await coordinator.sync()
            XCTFail("Offline sync should fail")
        } catch {
            let queued = try await store.mutation(id: "one", instance: ReadeckClient(address: address, token: "test").storageInstance)
            XCTAssertNotNil(queued)
        }

        var serverMarked = false
        var patchCount = 0
        StubURLProtocol.respond = { request in
            let path = request.url!.path
            if path == "/api/bookmarks/one", request.httpMethod == "PATCH" {
                patchCount += 1
                serverMarked = true
                return (200, Data(#"{"is_marked":true}"#.utf8))
            }
            if path == "/api/bookmarks/one" {
                let data = try JSONSerialization.data(withJSONObject: [
                    "id": "one", "url": "https://example.com", "is_marked": serverMarked
                ])
                return (200, data)
            }
            if path == "/api/bookmarks/sync" || path == "/api/bookmarks/collections" { return (200, Data("[]".utf8)) }
            return (404, Data("{}".utf8))
        }
        let snapshot = try await coordinator.sync()

        XCTAssertEqual(patchCount, 1)
        XCTAssertEqual(snapshot.bookmarks.first?.isMarked, true)
        XCTAssertTrue(snapshot.pendingMutations.isEmpty)
    }

    func testAlreadyAppliedPatchIsReconciledWithoutSendingAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let original = try bookmark(#"{"id":"one","url":"https://example.com","is_marked":false}"#)
        try await store.upsert(original, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        try await coordinator.enqueueMutation(bookmark: original, patch: BookmarkPatch(isMarked: true))

        var patchCount = 0
        StubURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" { patchCount += 1; return (200, Data("{}".utf8)) }
            if request.url!.path == "/api/bookmarks/one" {
                return (200, Data(#"{"id":"one","url":"https://example.com","is_marked":true}"#.utf8))
            }
            return (200, Data("[]".utf8))
        }
        let snapshot = try await coordinator.sync()

        XCTAssertEqual(patchCount, 0)
        XCTAssertTrue(snapshot.pendingMutations.isEmpty)
        XCTAssertEqual(snapshot.bookmarks.first?.isMarked, true)
    }

    func testRemoteLabelConflictRetainsLocalEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let original = try bookmark(#"{"id":"one","url":"https://example.com","labels":["old"]}"#)
        try await store.upsert(original, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        try await coordinator.enqueueMutation(bookmark: original, patch: BookmarkPatch(labels: ["local"]))

        var patchCount = 0
        StubURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" { patchCount += 1; return (200, Data("{}".utf8)) }
            if request.url!.path == "/api/bookmarks/one" {
                return (200, Data(#"{"id":"one","url":"https://example.com","labels":["remote"]}"#.utf8))
            }
            return (200, Data("[]".utf8))
        }
        do {
            _ = try await coordinator.sync()
            XCTFail("Conflicting labels must be reported")
        } catch let error as SyncError {
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("Expected a conflict, got \(error)")
        }

        XCTAssertEqual(patchCount, 0)
        let cached = try await coordinator.cached()
        let queued = try await store.mutation(id: "one", instance: ReadeckClient(address: address, token: "test").storageInstance)
        XCTAssertEqual(cached.bookmarks.first?.labels, ["local"])
        XCTAssertNotNil(queued)
    }

    func testConflictCanBeRebasedToKeepLocalLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let original = try bookmark(#"{"id":"one","url":"https://example.com","labels":["old"]}"#)
        try await store.upsert(original, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        try await coordinator.enqueueMutation(bookmark: original, patch: BookmarkPatch(labels: ["local"]))

        var remoteLabels = ["remote"]
        var patchCount = 0
        StubURLProtocol.respond = { request in
            if request.httpMethod == "PATCH" {
                patchCount += 1
                remoteLabels = ["local"]
                return (200, Data("{}".utf8))
            }
            if request.url!.path == "/api/bookmarks/one" {
                let data = try JSONSerialization.data(withJSONObject: [
                    "id": "one", "url": "https://example.com", "labels": remoteLabels
                ])
                return (200, data)
            }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        try await coordinator.resolveConflict(id: "one", keepLocal: true)
        let snapshot = try await coordinator.sync()

        XCTAssertEqual(patchCount, 1)
        XCTAssertEqual(snapshot.bookmarks.first?.labels, ["local"])
        XCTAssertTrue(snapshot.pendingMutations.isEmpty)
    }

    func testConflictCanDiscardLocalLabels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let original = try bookmark(#"{"id":"one","url":"https://example.com","labels":["old"]}"#)
        try await store.upsert(original, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        try await coordinator.enqueueMutation(bookmark: original, patch: BookmarkPatch(labels: ["local"]))

        StubURLProtocol.respond = { request in
            if request.url!.path == "/api/bookmarks/one" {
                return (200, Data(#"{"id":"one","url":"https://example.com","labels":["remote"]}"#.utf8))
            }
            return (200, Data("[]".utf8))
        }
        do { _ = try await coordinator.sync() } catch {}
        try await coordinator.resolveConflict(id: "one", keepLocal: false)
        let snapshot = try await coordinator.cached()

        XCTAssertTrue(snapshot.pendingMutations.isEmpty)
        XCTAssertEqual(snapshot.bookmarks.first?.labels, ["remote"])
    }

    func testServerDeletedBookmarkCanBeDiscardedLocally() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let original = try bookmark(#"{"id":"gone","url":"https://example.com","is_marked":false}"#)
        try await store.upsert(original, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        try await coordinator.enqueueMutation(bookmark: original, patch: BookmarkPatch(isMarked: true))

        StubURLProtocol.respond = { request in
            if request.url!.path == "/api/bookmarks/gone" { return (404, Data("{}".utf8)) }
            return (200, Data("[]".utf8))
        }
        do {
            _ = try await coordinator.sync()
            XCTFail("Deleted remote bookmark should need a local decision")
        } catch let error as SyncError {
            XCTAssertEqual(error.missingBookmarkID, "gone")
        }
        let queued = try await store.mutation(id: "gone", instance: ReadeckClient(address: address, token: "test").storageInstance)
        XCTAssertNotNil(queued)

        try await coordinator.discardMissingBookmark(id: "gone")
        let snapshot = try await coordinator.cached()
        XCTAssertTrue(snapshot.pendingMutations.isEmpty)
        XCTAssertTrue(snapshot.bookmarks.isEmpty)
    }

    func testTimedOutSaveWaitsBeforeResubmittingWhenServerHasNoMatchYet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        var pending = PendingSave(url: "https://example.com/new", title: "New", labels: [])
        pending.attemptedAt = Date()
        try await store.enqueue(pending, instance: ReadeckClient(address: address, token: "test").storageInstance)
        let coordinator = SyncCoordinator(client: client(for: address), store: store)

        var postCount = 0
        StubURLProtocol.respond = { request in
            if request.httpMethod == "POST" { postCount += 1; return (202, Data("{}".utf8)) }
            return (200, Data("[]".utf8))
        }
        let snapshot = try await coordinator.sync()

        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(snapshot.pending.count, 1)
    }

    func testLostPostResponseIsReconciledWithoutSecondPost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        var pending = PendingSave(url: "https://example.com/new", title: "New", labels: [])
        pending.created = Date().addingTimeInterval(-3600)
        try await store.enqueue(pending, instance: ReadeckClient(address: address, token: "test").storageInstance)

        var postCount = 0
        StubURLProtocol.respond = { request in
            if request.httpMethod == "POST" {
                postCount += 1
                throw URLError(.networkConnectionLost)
            }
            if request.url!.path == "/api/bookmarks" {
                let created = ISO8601DateFormatter().string(from: Date())
                let data = try JSONSerialization.data(withJSONObject: [[
                    "id": "created", "url": "https://example.com/new",
                    "title": "New", "created": created
                ]])
                return (200, data)
            }
            return (200, Data("[]".utf8))
        }
        do {
            _ = try await coordinator.sync()
            XCTFail("Lost response should keep the item queued")
        } catch {}

        let snapshot = try await coordinator.sync()
        XCTAssertEqual(postCount, 1)
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertEqual(snapshot.bookmarks.first?.id, "created")
    }

    func testLegacyUnattemptedSaveSendsExactlyTheCanonicalLabelsPersistedForReconciliation() async throws {
        let cases = [
            (["mac-category/A/B", "keep"], ["keep", "分类/A/B"]),
            (["mac-category/未分类", "keep"], ["mac-category/未分类", "keep"])
        ]
        for (originalLabels, expectedLabels) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
            let address = try ServerAddress("http://nas.test/")
            let client = client(for: address)
            let coordinator = SyncCoordinator(client: client, store: store)
            let pending = PendingSave(url: "https://example.com/legacy", title: "", labels: originalLabels)
            try await store.updatePending(pending, instance: client.storageInstance)
            var sentLabels: [String] = []
            var postCount = 0
            StubURLProtocol.respond = { request in
                if request.httpMethod == "POST" {
                    postCount += 1
                    let body = try JSONSerialization.jsonObject(with: request.taxonomyTestBody) as! [String: Any]
                    sentLabels = body["labels"] as! [String]
                    throw URLError(.networkConnectionLost)
                }
                if request.url!.path == "/api/bookmarks" {
                    return (200, try JSONSerialization.data(withJSONObject: [[
                        "id": "created", "url": pending.url, "labels": sentLabels,
                        "created": ISO8601DateFormatter().string(from: Date())
                    ]]))
                }
                return (200, Data("[]".utf8))
            }
            do { _ = try await coordinator.sync(); XCTFail("Lost response should remain queued") } catch {}
            let queued = try await store.pending(instance: client.storageInstance)
            XCTAssertEqual(sentLabels, expectedLabels)
            XCTAssertEqual(queued.first?.labels, sentLabels)
            let reconciled = try await coordinator.sync()
            XCTAssertTrue(reconciled.pending.isEmpty)
            XCTAssertEqual(postCount, 1)
        }
    }

    func testPostReconciliationIgnoresFragmentAndRequiresMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        var pending = PendingSave(url: "https://example.com/new#section",
                                  title: "Requested", labels: ["reading"])
        pending.attemptedAt = Date()
        try await store.enqueue(pending, instance: ReadeckClient(address: address, token: "test").storageInstance)

        let created = ISO8601DateFormatter().string(from: pending.attemptedAt!)
        StubURLProtocol.respond = { request in
            if request.url!.path == "/api/bookmarks" {
                let data = try JSONSerialization.data(withJSONObject: [
                    ["id": "match", "url": "https://example.com/new",
                     "title": "Requested", "labels": ["reading"], "created": created],
                    ["id": "old", "url": "https://example.com/new",
                     "title": "Requested", "labels": ["reading"],
                     "created": ISO8601DateFormatter().string(from: pending.attemptedAt!.addingTimeInterval(-300))],
                    ["id": "other-title", "url": "https://example.com/new",
                     "title": "Different", "labels": ["reading"], "created": created],
                    ["id": "other-label", "url": "https://example.com/new",
                     "title": "Requested", "labels": ["other"], "created": created]
                ])
                return (200, data)
            }
            return (200, Data("[]".utf8))
        }
        let snapshot = try await coordinator.sync()

        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertEqual(snapshot.bookmarks.map(\.id), ["match"])
    }

    func testPostReconciliationLeavesMultipleCandidatesQueued() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let address = try ServerAddress("http://nas.test/")
        let coordinator = SyncCoordinator(client: client(for: address), store: store)
        var pending = PendingSave(url: "https://example.com/new", title: "", labels: [])
        pending.attemptedAt = Date()
        try await store.enqueue(pending, instance: ReadeckClient(address: address, token: "test").storageInstance)

        let created = ISO8601DateFormatter().string(from: pending.attemptedAt!)
        StubURLProtocol.respond = { request in
            if request.url!.path == "/api/bookmarks" {
                let data = try JSONSerialization.data(withJSONObject: [
                    ["id": "one", "url": "https://example.com/new", "created": created],
                    ["id": "two", "url": "https://example.com/new", "created": created]
                ])
                return (200, data)
            }
            return (200, Data("[]".utf8))
        }
        do {
            _ = try await coordinator.sync()
            XCTFail("Ambiguous reconciliation must not claim either bookmark")
        } catch let error as SyncError {
            XCTAssertNotNil(error.errorDescription)
        }
        let snapshot = try await coordinator.cached()
        XCTAssertEqual(snapshot.pending.map(\.id), [pending.id])
    }
}

private final class StubURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, data) = try Self.respond?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var taxonomyTestBody: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
