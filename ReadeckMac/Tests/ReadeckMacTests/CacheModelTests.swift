import Combine
import XCTest
@testable import ReadeckMac

@MainActor
final class CacheModelTests: XCTestCase {
    func testManualCleanupCausesNextOpenToRefetchAndRetentionPreferencePersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CacheModelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheModelProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://cache.test/"), token: "test",
                                   session: URLSession(configuration: configuration))
        let item = Bookmark(id: "one", url: "https://example.com")
        try await store.upsert(item, instance: client.storageInstance)
        CacheModelProtocol.reset()
        let model = AppModel(client: client, store: store, cacheDefaults: defaults)
        let first = try await model.article(for: item)
        let cached = try await model.article(for: item)
        XCTAssertEqual(first, cached)
        XCTAssertEqual(CacheModelProtocol.articleReads, 1)
        await model.clearArticleCache()
        let cachedAfterClear = try await store.article(id: item.id, instance: client.storageInstance)
        XCTAssertNil(cachedAfterClear)
        let downloaded = try await model.article(for: item)
        XCTAssertEqual(downloaded, "<p>从服务端重新下载</p>")
        XCTAssertEqual(CacheModelProtocol.articleReads, 2)
        await model.setCacheRetention(.days45)
        XCTAssertEqual(defaults.integer(forKey: "cache.retentionDays"), 45)
        let reopened = AppModel(client: client, store: store, cacheDefaults: defaults)
        XCTAssertEqual(reopened.cacheRetention, .days45)
        model.cancelSync()
        reopened.cancelSync()
    }

    func testStartupAutomaticallyEvictsOldBodyAndKeepsBookmarkIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CacheModelTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try LocalStore(url: directory.appendingPathComponent("library.sqlite"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CacheModelProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://cache.test/"), token: "test",
                                   session: URLSession(configuration: configuration))
        let item = Bookmark(id: "one", url: "https://example.com")
        try await store.upsert(item, instance: client.storageInstance)
        try await store.setArticle("旧缓存", id: item.id, instance: client.storageInstance,
                                   accessedAt: Date().addingTimeInterval(-61 * 86_400))
        let model = AppModel(client: client, store: store, cacheDefaults: defaults)
        let swept = expectation(description: "Startup sweep completes without a network trigger")
        let observer = model.$cacheStatistics.first(where: { $0 != nil }).sink { _ in swept.fulfill() }
        await fulfillment(of: [swept], timeout: 3)
        observer.cancel()
        XCTAssertEqual(model.cacheStatistics?.articleCount, 0)
        let indexed = try await store.bookmark(id: item.id, instance: client.storageInstance)
        XCTAssertNotNil(indexed)
        model.cancelSync()
    }
}

private final class CacheModelProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var reads = 0
    static var articleReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    static func reset() { lock.lock(); reads = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let article = request.url?.path.hasSuffix("/article") == true
        if article { Self.lock.lock(); Self.reads += 1; Self.lock.unlock() }
        let data = Data((article ? "<p>从服务端重新下载</p>" : "[]").utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
