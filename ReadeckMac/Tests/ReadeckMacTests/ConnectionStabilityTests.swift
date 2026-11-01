import Foundation
import Combine
import XCTest
@testable import ReadeckMac

final class ConnectionStabilityTests: XCTestCase {
    override func tearDown() {
        StabilityURLProtocol.respond = nil
        super.tearDown()
    }

    private func context() throws -> (URL, LocalStore, ReadeckClient, SyncCoordinator) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StabilityURLProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://nas.test/"), token: "test",
                                   session: URLSession(configuration: configuration))
        return (directory, store, client, SyncCoordinator(client: client, store: store))
    }

    func testTransportFailureStopsRoundInsteadOfTimingOutEveryQueuedSave() async throws {
        let (directory, _, _, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 { try await coordinator.enqueue(url: "https://example.com/\(index)") }
        var requests = 0
        StabilityURLProtocol.respond = { _ in
            requests += 1
            throw URLError(.timedOut)
        }
        do {
            _ = try await coordinator.sync()
            XCTFail("Expected timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
        XCTAssertEqual(requests, 1)
        let cached = try await coordinator.cached()
        XCTAssertEqual(cached.pending.count, 3)
        XCTAssertEqual(cached.pending.filter { $0.attemptedAt != nil }.count, 1)
    }

    func testAuthenticationFailureStopsRoundAndPreservesQueue() async throws {
        let (directory, _, _, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 { try await coordinator.enqueue(url: "https://example.com/\(index)") }
        var requests = 0
        StabilityURLProtocol.respond = { _ in requests += 1; return (401, Data("{}".utf8)) }
        do {
            _ = try await coordinator.sync()
            XCTFail("Expected authentication failure")
        } catch APIError.status(401, _) {}
        XCTAssertEqual(requests, 1)
        let cached = try await coordinator.cached()
        XCTAssertEqual(cached.pending.count, 3)
    }

    func testInterruptedDownloadCheckpointsOnlySuccessfullySavedChanges() async throws {
        let (directory, store, client, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        StabilityURLProtocol.respond = { request in
            switch request.url!.path {
            case "/api/bookmarks/sync":
                return (200, Data(#"[{"id":"two","type":"update","time":"2026-10-24T22:00:02Z"},{"id":"one","type":"update","time":"2026-10-24T22:00:01Z"}]"#.utf8))
            case "/api/bookmarks/one":
                return (200, Data(#"{"id":"one","url":"https://example.com/one"}"#.utf8))
            case "/api/bookmarks/two": throw URLError(.timedOut)
            default: return (200, Data("[]".utf8))
            }
        }
        do { _ = try await coordinator.sync(); XCTFail("Expected interrupted download") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let cursor = try await store.cursor(instance: client.storageInstance)
        let bookmarks = try await store.bookmarks(instance: client.storageInstance)
        XCTAssertEqual(cursor, "2026-10-24T22:00:01Z")
        XCTAssertEqual(bookmarks.map(\.id), ["one"])
    }

    func testRetrySkipsPersistedBoundaryEventsWithIdenticalTimestamps() async throws {
        let (directory, store, client, coordinator) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var detailReads: [String: Int] = [:]
        StabilityURLProtocol.respond = { request in
            switch request.url!.path {
            case "/api/bookmarks/sync":
                return (200, Data(#"[{"id":"two","type":"update","time":"2026-10-24T22:00:01Z"},{"id":"one","type":"update","time":"2026-10-24T22:00:01Z"}]"#.utf8))
            case "/api/bookmarks/one", "/api/bookmarks/two":
                let id = request.url!.lastPathComponent
                detailReads[id, default: 0] += 1
                if id == "two", detailReads[id] == 1 { throw URLError(.timedOut) }
                return (200, try JSONSerialization.data(withJSONObject: ["id": id, "url": "https://example.com/" + id]))
            default: return (200, Data("[]".utf8))
            }
        }
        do { _ = try await coordinator.sync(); XCTFail("Expected interrupted first round") }
        catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        let cursor = try await store.cursor(instance: client.storageInstance)
        XCTAssertEqual(cursor, "2026-10-24T22:00:01Z")

        let reopened = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let result = try await SyncCoordinator(client: client, store: reopened).sync()

        XCTAssertEqual(result.bookmarks.count, 2)
        XCTAssertEqual(detailReads["one"], 1)
        XCTAssertEqual(detailReads["two"], 2)
    }

    func testDeadlineCancelsARequestThatNeverFinishes() async throws {
        let (directory, _, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            _ = try await SyncDeadline.run(seconds: 0.05) { try await client.info() }
            XCTFail("Expected a round deadline")
        } catch SyncDeadlineError.exceeded {}
    }

    @MainActor
    func testApplicationStopsBusyStateAndSchedulesRetryAfterDeadline() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = expectation(description: "Timed out round exits busy state")
        let model = AppModel(client: client, store: store,
                             policy: SyncPolicy(fullSyncTimeout: 0.05))
        let observer = model.$isSyncing.dropFirst().first(where: { !$0 })
            .sink { _ in finished.fulfill() }
        defer { observer.cancel() }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(model.isSyncing)
        XCTAssertNotNil(model.nextRetryAt)
        XCTAssertTrue(model.syncMessage?.contains("等待过久") == true)
    }

    @MainActor
    func testApplicationAutomaticallyRecoversAfterTransientFailure() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        var attempts = 0
        StabilityURLProtocol.respond = { request in
            if request.url?.path == "/api/bookmarks/sync" {
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
            }
            return (200, Data("[]".utf8))
        }
        let recovered = expectation(description: "Second round succeeds without manual retry")
        let model = AppModel(client: client, store: store,
                             policy: SyncPolicy(retryIntervals: [0.03]))
        let observer = model.$lastSyncAt.first(where: { $0 != nil }).sink { _ in recovered.fulfill() }
        defer { observer.cancel() }
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(model.syncMessage)
        XCTAssertNil(model.nextRetryAt)
    }

    @MainActor
    func testCancelActionReleasesBusyStateWithoutDiscardingData() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.upsert(Bookmark(id: "one", url: "https://example.com"), instance: client.storageInstance)
        let started = expectation(description: "Sync started")
        let stopped = expectation(description: "Canceled sync stopped")
        let model = AppModel(client: client, store: store)
        let startObserver = model.$isSyncing.first(where: { $0 }).sink { _ in started.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        let stopObserver = model.$isSyncing.first(where: { !$0 }).sink { _ in stopped.fulfill() }
        model.cancelSync()
        await fulfillment(of: [stopped], timeout: 2)
        startObserver.cancel()
        stopObserver.cancel()
        XCTAssertEqual(model.bookmarks.count, 1)
        XCTAssertFalse(model.isSyncing)
        XCTAssertNil(model.nextRetryAt)
    }

    func testLocalNetworkDenialHasSpecificMessageAndIsNotRetriedAsAnOutage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StabilityURLProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://nas.test/"), token: "test",
                                   session: URLSession(configuration: configuration), permissionCheck: { _ in true })
        StabilityURLProtocol.respond = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await client.info(); XCTFail("Expected a permission diagnosis") }
        catch NetworkAccessError.localNetworkDenied {
            XCTAssertFalse(ConnectionDiagnostics.shouldRetry(NetworkAccessError.localNetworkDenied))
            XCTAssertTrue(ConnectionDiagnostics.message(for: NetworkAccessError.localNetworkDenied).contains("本地网络"))
        }
    }

    func testBackoffStopsGrowingAtOneMinuteAndDoesNotRetryAuthentication() {
        let policy = SyncPolicy()
        XCTAssertEqual((0..<7).map { policy.retryDelay(attempt: $0) }, [5, 10, 20, 40, 60, 60, 60])
        XCTAssertFalse(ConnectionDiagnostics.shouldRetry(APIError.status(401, "")))
        XCTAssertTrue(ConnectionDiagnostics.shouldRetry(URLError(.timedOut)))
    }

    @MainActor
    func testWakeEventTriggersImmediateRetry() async throws {
        let (directory, store, client, _) = try context()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (events, continuation) = AsyncStream<ConnectionEvent>.makeStream()
        defer { continuation.finish() }
        var attempts = 0
        StabilityURLProtocol.respond = { request in
            if request.url?.path == "/api/bookmarks/sync" {
                attempts += 1
                if attempts == 1 { throw URLError(.timedOut) }
            }
            return (200, Data("[]".utf8))
        }
        let failed = expectation(description: "First sync failed")
        let recovered = expectation(description: "Wake event recovers without waiting for backoff")
        let model = AppModel(client: client, store: store, connectionEvents: events)
        let failedObserver = model.$nextRetryAt.first(where: { $0 != nil }).sink { _ in failed.fulfill() }
        let recoveredObserver = model.$lastSyncAt.first(where: { $0 != nil }).sink { _ in recovered.fulfill() }
        await fulfillment(of: [failed], timeout: 2)
        continuation.yield(.woke)
        await fulfillment(of: [recovered], timeout: 2)
        failedObserver.cancel()
        recoveredObserver.cancel()
        XCTAssertEqual(attempts, 2)
    }
}

private final class StabilityURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let respond = Self.respond else { return }
        do {
            let (status, data) = try respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
