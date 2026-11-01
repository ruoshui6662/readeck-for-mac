import Foundation
import Combine
import XCTest
@testable import ReadeckMac

final class CaptureRefreshTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func bookmark(id: String = "one", state: Int = 2, loaded: Bool = false) -> Bookmark {
        Bookmark(id: id, url: "https://example.com/\(id)", loaded: loaded, state: state)
    }

    func testExplicitTerminalStateStopsProcessingEvenWithStaleLoadedFlag() {
        XCTAssertTrue(bookmark().isProcessing)
        XCTAssertFalse(bookmark(state: 0).isProcessing)
        XCTAssertFalse(bookmark(state: 1).isProcessing)
        XCTAssertNil(bookmark(state: 0).captureStatus)
        XCTAssertEqual(bookmark(state: 1).captureStatus, "抓取失败")
        XCTAssertTrue(Bookmark(id: "legacy", url: "https://example.com", loaded: false).isProcessing)
    }

    func testArticleReloadsWhenExtractionFinishesButNotOnReadingProgressEdits() {
        let processing = bookmark()
        var ready = bookmark(state: 0, loaded: true)
        XCTAssertNotEqual(processing.articleRequestKey, ready.articleRequestKey)
        let key = ready.articleRequestKey
        ready.isMarked = true
        ready.readProgress = 20
        ready.updated = "2026-10-24T23:00:00Z"
        XCTAssertEqual(ready.articleRequestKey, key)
    }

    func testStatusChecksBackOffAndCacheReloadDoesNotRestartTimer() {
        var schedule = CaptureRefreshSchedule()
        schedule.reconcile([bookmark()], now: start)
        XCTAssertEqual(schedule.nextDelay(now: start), 2)
        XCTAssertTrue(schedule.takeDueIDs(now: start.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(schedule.takeDueIDs(now: start.addingTimeInterval(2)), ["one"])
        schedule.reconcile([bookmark()], now: start.addingTimeInterval(3))
        XCTAssertEqual(schedule.nextDelay(now: start.addingTimeInterval(3)), 3)
        XCTAssertEqual(schedule.takeDueIDs(now: start.addingTimeInterval(6)), ["one"])
        XCTAssertEqual(schedule.nextDelay(now: start.addingTimeInterval(6)), 8)
        XCTAssertEqual(schedule.takeDueIDs(now: start.addingTimeInterval(14)), ["one"])
        XCTAssertEqual(schedule.nextDelay(now: start.addingTimeInterval(14)), 15)
    }

    func testCompletionAndFailureStopFastChecks() {
        var schedule = CaptureRefreshSchedule()
        schedule.reconcile([bookmark(), bookmark(id: "two")], now: start)
        schedule.reconcile([bookmark(state: 0, loaded: true), bookmark(id: "two", state: 1)],
                           now: start.addingTimeInterval(2))
        XCTAssertNil(schedule.nextDelay(now: start.addingTimeInterval(2)))
        XCTAssertTrue(schedule.takeDueIDs(now: start.addingTimeInterval(3)).isEmpty)
    }

    func testExpiredJobsStayStoppedWhileNewJobsGetTheirOwnBudget() {
        var schedule = CaptureRefreshSchedule()
        schedule.reconcile([bookmark()], now: start)
        schedule.reconcile([bookmark()], now: start.addingTimeInterval(121))
        XCTAssertNil(schedule.nextDelay(now: start.addingTimeInterval(121)))
        XCTAssertTrue(schedule.takeDueIDs(now: start.addingTimeInterval(121)).isEmpty)
        schedule.reconcile([bookmark(), bookmark(id: "two")], now: start.addingTimeInterval(122))
        XCTAssertEqual(schedule.nextDelay(now: start.addingTimeInterval(122)), 2)
        XCTAssertEqual(schedule.takeDueIDs(now: start.addingTimeInterval(124)), ["two"])
    }

    func testBulkProcessingChecksAreLimitedPerBatchWithoutStarvingOtherJobs() {
        var schedule = CaptureRefreshSchedule()
        schedule.reconcile((0..<12).map { bookmark(id: String(format: "%02d", $0)) }, now: start)
        let first = schedule.takeDueIDs(now: start.addingTimeInterval(2))
        let remaining = schedule.takeDueIDs(now: start.addingTimeInterval(3))
        XCTAssertEqual(first.count, 10)
        XCTAssertEqual(remaining, ["10", "11"])
        XCTAssertTrue(Set(first).isDisjoint(with: remaining))
    }

    override func tearDown() {
        CaptureURLProtocol.respond = nil
        super.tearDown()
    }

    private func context() throws -> (URL, LocalStore, ReadeckClient, SyncCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureURLProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://nas.test/"), token: "test",
                                   session: URLSession(configuration: configuration), permissionCheck: { _ in false })
        return (directory, store, client, SyncCoordinator(client: client, store: store))
    }

    func testTargetedRefreshFinishesCaptureAndPreservesQueuedEditsWithoutUploading() async throws {
        let (directory, store, client, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = bookmark()
        try await store.upsert(item, instance: client.storageInstance)
        try await coordinator.enqueue(url: "https://example.com/queued")
        try await coordinator.enqueueMutation(bookmark: item, patch: BookmarkPatch(isMarked: true))
        var requests = 0
        CaptureURLProtocol.respond = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/bookmarks/one")
            return (200, Data(#"{"id":"one","url":"https://example.com/one","loaded":true,"state":0,"has_article":true,"is_marked":false}"#.utf8))
        }

        let result = try await coordinator.refreshCaptures(ids: ["one"])

        XCTAssertEqual(requests, 1)
        XCTAssertEqual(result.bookmarks.first?.isProcessing, false)
        XCTAssertEqual(result.bookmarks.first?.isMarked, true)
        XCTAssertEqual(result.pendingMutations.count, 1)
        XCTAssertEqual(result.pending.count, 1)
    }

    func testTargetedRefreshPersistsServerErrorsWhenLoadedWithoutArticle() async throws {
        let (directory, store, client, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(bookmark(), instance: client.storageInstance)
        CaptureURLProtocol.respond = { _ in
            (200, Data(#"{"id":"one","url":"https://example.com/one","loaded":true,"state":0,"has_article":false,"errors":["cannot load resource"]}"#.utf8))
        }
        let result = try await coordinator.refreshCaptures(ids: ["one"])
        XCTAssertEqual(result.bookmarks.first?.captureStatus, "抓取失败")
        let saved = try await store.bookmark(id: "one", instance: client.storageInstance)
        XCTAssertEqual(saved?.errors, ["cannot load resource"])
    }

    func testTargetedRefreshHandlesRemoteDeletionAndNetworkFailureWithoutLosingQueue() async throws {
        let (directory, store, client, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(bookmark(), instance: client.storageInstance)
        try await store.upsert(bookmark(id: "two"), instance: client.storageInstance)
        try await coordinator.enqueueMutation(bookmark: bookmark(id: "two"),
                                               patch: BookmarkPatch(isMarked: true))
        CaptureURLProtocol.respond = { _ in (404, Data("{}".utf8)) }
        _ = try await coordinator.refreshCaptures(ids: ["one"])
        do {
            _ = try await coordinator.refreshCaptures(ids: ["two"])
            XCTFail("A deleted bookmark with pending edits must remain actionable")
        } catch let error as SyncError {
            XCTAssertEqual(error.missingBookmarkID, "two")
        }
        let deleted = try await coordinator.cached()
        XCTAssertEqual(deleted.bookmarks.map(\.id), ["two"])
        XCTAssertEqual(deleted.pendingMutations.count, 1)

        CaptureURLProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await coordinator.refreshCaptures(ids: ["two"])
            XCTFail("Network failures must stop fast refresh")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        let preserved = try await coordinator.cached()
        XCTAssertEqual(preserved.pendingMutations.count, 1)
        XCTAssertEqual(preserved.bookmarks.first?.isMarked, true)
    }

    func testSavedArticleBecomesReadableBeforeNextMinuteSyncWithoutAnotherPost() async throws {
        let (directory, store, client, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var posts = 0
        var detailReads = 0
        CaptureURLProtocol.respond = { request in
            let path = request.url!.path
            if request.httpMethod == "POST" {
                posts += 1
                return (202, Data("{}".utf8))
            }
            if path == "/api/bookmarks/one/article" {
                XCTAssertGreaterThanOrEqual(detailReads, 3)
                return (200, Data("<p>Ready to read.</p>".utf8))
            }
            if path == "/api/bookmarks/one" {
                detailReads += 1
                let ready = detailReads >= 3
                return (200, try JSONSerialization.data(withJSONObject: [
                    "id": "one", "url": "https://example.com/one", "loaded": ready,
                    "state": ready ? 0 : 2, "has_article": ready
                ] as [String: Any]))
            }
            return (200, Data("[]".utf8))
        }
        // A server-accepted bookmark is already cached after its POST response.
        try await store.upsert(bookmark(), instance: client.storageInstance)
        var snapshot = try await coordinator.cached()
        var schedule = CaptureRefreshSchedule()
        var elapsed: TimeInterval = 0
        while snapshot.bookmarks.contains(where: \.isProcessing), elapsed < 60 {
            let now = start.addingTimeInterval(elapsed)
            schedule.reconcile(snapshot.bookmarks, now: now)
            guard let delay = schedule.nextDelay(now: now) else { break }
            elapsed += delay
            let ids = schedule.takeDueIDs(now: start.addingTimeInterval(elapsed))
            snapshot = try await coordinator.refreshCaptures(ids: ids)
        }
        let html = try await client.article(id: "one")
        XCTAssertEqual(elapsed, 14)
        XCTAssertFalse(snapshot.bookmarks[0].isProcessing)
        XCTAssertEqual(html, "<p>Ready to read.</p>")
        XCTAssertEqual(posts, 0)
    }

    @MainActor
    func testApplicationAutomaticallyRefreshesProcessingArticleAndLoadsItsText() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(bookmark(), instance: client.storageInstance)
        let completed = expectation(description: "Processing bookmark becomes readable automatically")
        CaptureURLProtocol.respond = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/api/bookmarks/one" {
                return (200, Data(#"{"id":"one","url":"https://example.com/one","loaded":true,"state":0,"has_article":true}"#.utf8))
            }
            if request.url?.path == "/api/bookmarks/one/article" {
                return (200, Data("<p>Automatic reader update.</p>".utf8))
            }
            return (200, Data("[]".utf8))
        }
        let model = AppModel(client: client, store: store)
        let observation = model.$bookmarks.first { items in
            items.contains { $0.id == "one" && $0.state == 0 }
        }.sink { _ in completed.fulfill() }
        defer { observation.cancel() }

        await fulfillment(of: [completed], timeout: 6)

        let ready = try XCTUnwrap(model.bookmarks.first)
        XCTAssertFalse(ready.isProcessing)
        let html = try await model.article(for: ready)
        XCTAssertEqual(html, "<p>Automatic reader update.</p>")
        XCTAssertTrue(model.collections.isEmpty)
    }

    @MainActor
    func testApplicationPausesFastRefreshAfterNetworkFailure() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(bookmark(), instance: client.storageInstance)
        let failed = expectation(description: "A failed metadata read is explained")
        let noRetry = expectation(description: "No further fast metadata requests while offline")
        noRetry.isInverted = true
        var reads = 0
        CaptureURLProtocol.respond = { request in
            if request.url?.path == "/api/bookmarks/one" {
                reads += 1
                if reads > 1 { noRetry.fulfill() }
                throw URLError(.notConnectedToInternet)
            }
            return (200, Data("[]".utf8))
        }
        let model = AppModel(client: client, store: store)
        let observation = model.$syncMessage.first(where: { $0 != nil })
            .sink { _ in failed.fulfill() }
        defer { observation.cancel() }

        await fulfillment(of: [failed], timeout: 6)
        await fulfillment(of: [noRetry], timeout: 4.5)

        XCTAssertTrue(model.bookmarks.first?.isProcessing == true)
        XCTAssertNotNil(model.syncMessage)
    }

    @MainActor
    func testConnectionFailureCancelsAnInflightCaptureBatch() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(bookmark(), instance: client.storageInstance)
        try await store.upsert(bookmark(id: "two"), instance: client.storageInstance)
        let started = expectation(description: "First metadata request started")
        let noFurtherReads = expectation(description: "Canceled connection sends no remaining detail requests")
        noFurtherReads.isInverted = true
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        CaptureURLProtocol.respond = { request in
            if request.url?.path == "/api/bookmarks/one" {
                started.fulfill()
                _ = release.wait(timeout: .now() + 4)
                return (200, Data(#"{"id":"one","url":"https://example.com/one","loaded":true,"state":0}"#.utf8))
            }
            if request.url?.path == "/api/bookmarks/two" {
                noFurtherReads.fulfill()
            }
            return (200, Data("[]".utf8))
        }
        let model = AppModel(client: client, store: store)
        await fulfillment(of: [started], timeout: 6)

        model.serverText = "ftp://invalid.test/"
        await model.connect()
        release.signal()
        await fulfillment(of: [noFurtherReads], timeout: 0.5)

        XCTAssertFalse(model.connected)
        let local = try await store.bookmark(id: "one", instance: client.storageInstance)
        XCTAssertTrue(local?.isProcessing == true)
    }
}

private final class CaptureURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.respond?(request) ?? (500, Data())
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
