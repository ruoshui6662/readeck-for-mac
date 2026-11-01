import XCTest
@testable import ReadeckMac

final class BulkSyncTests: XCTestCase {
    private func context() throws -> (LocalStore, SyncCoordinator, URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LocalStore(url: dir.appendingPathComponent("library.sqlite"))
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [BulkMockProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://bulk.test/"), token: "test-only", session: URLSession(configuration: config))
        return (store, SyncCoordinator(client: client, store: store), dir, client.storageInstance)
    }
    func testSuccessfulItemsConfirmAndConflictsRemainPerArticleAfterRestart() async throws {
        let (store, coordinator, dir, scope) = try context();defer { try? FileManager.default.removeItem(at: dir) }
        let a = Bookmark(id: "a", url: "https://example.com/a", labels: ["old"])
        let b = Bookmark(id: "b", url: "https://example.com/b", labels: ["old"])
        try await store.upsert(a, instance: scope);try await store.upsert(b, instance: scope)
        _ = try await store.enqueueBulk(id: "edit", bookmarks: [a,b], intent: .organize(category: .keep, adding: ["new"], removing: []), instance: scope)
        var remoteB = b;remoteB.labels = ["elsewhere"]
        BulkMockProtocol.reset(books: [a,remoteB])
        do { _ = try await coordinator.sync();XCTFail("Expected conflict") } catch {}
        let reopened = try LocalStore(url: dir.appendingPathComponent("library.sqlite"))
        let reopenedValues = try await reopened.bulkOperations(instance: scope)
        let receipt = try XCTUnwrap(reopenedValues.first)
        XCTAssertEqual(receipt.items.first { $0.id == "a" }?.status, .synced)
        XCTAssertEqual(receipt.items.first { $0.id == "b" }?.status, .conflict)
        XCTAssertEqual(BulkMockProtocol.patches, ["a"])
    }
    func testLostPatchResponseIsConfirmedWithoutSendingSuccessfulPatchAgain() async throws {
        let (store, coordinator, dir, scope) = try context();defer { try? FileManager.default.removeItem(at: dir) }
        let a = Bookmark(id: "a", url: "https://example.com/a", labels: [])
        try await store.upsert(a, instance: scope)
        _ = try await store.enqueueBulk(id: "star", bookmarks: [a], intent: .star(true), instance: scope)
        BulkMockProtocol.reset(books: [a], losePatch: true)
        _ = try? await coordinator.sync()
        let first = try await store.bulkOperations(instance: scope)
        XCTAssertEqual(first.first?.items.first?.status, .failed)
        _ = try await coordinator.sync()
        let final = try await store.bulkOperations(instance: scope)
        XCTAssertEqual(final.first?.items.first?.status, .synced)
        XCTAssertEqual(BulkMockProtocol.patches, ["a"])
    }
    func testMissingBulkEditStopsAutomaticReplayAndDelete404Confirms() async throws {
        let (store, coordinator, dir, scope) = try context();defer { try? FileManager.default.removeItem(at: dir) }
        let a = Bookmark(id: "a", url: "https://example.com/a", labels: [])
        try await store.upsert(a, instance: scope)
        _ = try await store.enqueueBulk(id: "star", bookmarks: [a], intent: .star(true), instance: scope)
        BulkMockProtocol.reset(books: [])
        _ = try? await coordinator.sync()
        let count = BulkMockProtocol.bookGets
        _ = try? await coordinator.sync()
        XCTAssertEqual(BulkMockProtocol.bookGets, count)
        let receipt = try await store.bulkOperations(instance: scope)
        XCTAssertEqual(receipt.first?.items.first?.failure, .missing)
        _ = try await store.enqueueBulk(id: "delete", bookmarks: [a], intent: .delete, instance: scope)
        _ = try await coordinator.sync()
        let deletion = try await store.bulkOperations(instance: scope).first { $0.id == "delete" }
        XCTAssertEqual(deletion?.items.first?.status, .synced)
    }
    func testLaterOverwritingEditSupersedesReceiptButUnrelatedFieldsDoNot() async throws {
        let (store, _, dir, scope) = try context();defer { try? FileManager.default.removeItem(at: dir) }
        let a = Bookmark(id: "a", url: "https://example.com", labels: [])
        try await store.upsert(a, instance: scope)
        _ = try await store.enqueueBulk(id: "star", bookmarks: [a], intent: .star(true), instance: scope)
        try await store.mergeMutation(bookmark: a, patch: BookmarkPatch(title: "Renamed"), instance: scope)
        let before = try await store.bulkOperations(instance: scope)
        XCTAssertEqual(before.first?.items.first?.status, .queued)
        try await store.mergeMutation(bookmark: a, patch: BookmarkPatch(isMarked: false), instance: scope)
        let after = try await store.bulkOperations(instance: scope)
        XCTAssertEqual(after.first?.items.first?.status, .superseded)
    }
    func testReplayedDeleteBatchReturnsReceiptBeforeFetchingMissingMetadata() async throws {
        let (store, coordinator, dir, scope) = try context();defer { try? FileManager.default.removeItem(at: dir) }
        let book = Bookmark(id: "a", url: "https://example.com/a", labels: [])
        try await store.upsert(book, instance: scope)
        _ = try await store.enqueueBulk(id: "delete", bookmarks: [book], intent: .delete, instance: scope)
        BulkMockProtocol.reset(books: [])
        let replayed = try await coordinator.enqueueBulk(id: "delete", bookmarks: [book], intent: .delete)
        XCTAssertEqual(replayed.items.count, 1)
        XCTAssertEqual(BulkMockProtocol.bookGets, 0)
    }

}

private final class BulkMockProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var books: [String: Bookmark] = [:]
    private static var lost = false
    private static var sent: [String] = []
    private static var gets = 0
    static var patches: [String] { lock.lock();defer { lock.unlock() };return sent }
    static var bookGets: Int { lock.lock();defer { lock.unlock() };return gets }
    static func reset(books values: [Bookmark], losePatch: Bool = false) {
        lock.lock();defer { lock.unlock() }
        books = Dictionary(uniqueKeysWithValues: values.map { ($0.id,$0) });lost = losePatch;sent = [];gets = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path, method = request.httpMethod ?? "GET"
        var code = 200, data = Data("[]".utf8), fail = false
        if path.hasPrefix("/api/bookmarks/"), !path.hasSuffix("/labels"), !path.hasSuffix("/sync"), !path.hasSuffix("/collections") {
            let id = request.url!.lastPathComponent
            if method == "GET" {
                Self.gets += 1
                if let book = Self.books[id] { data = try! JSONEncoder().encode(book) } else { code = 404 }
            } else if method == "PATCH", var book = Self.books[id] {
                Self.sent.append(id)
                var payload = request.httpBody
                if payload == nil, let stream = request.httpBodyStream {
                    stream.open();defer { stream.close() };var bytes = Data();var buffer = [UInt8](repeating: 0, count: 2048)
                    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count);if n <= 0 { break };bytes.append(buffer,count:n) };payload = bytes
                }
                let fields = (try? JSONSerialization.jsonObject(with: payload ?? Data())) as? [String: Any] ?? [:]
                if let labels = fields["labels"] as? [String] { book.labels = labels }
                if let marked = fields["is_marked"] as? Bool { book.isMarked = marked }
                if let archived = fields["is_archived"] as? Bool { book.isArchived = archived }
                Self.books[id] = book;data = try! JSONEncoder().encode(book)
                if Self.lost { Self.lost = false;fail = true }
            } else if method == "DELETE" { if Self.books.removeValue(forKey: id) == nil { code = 404 } }
        }
        Self.lock.unlock()
        if fail { client?.urlProtocol(self, didFailWithError: URLError(.timedOut));return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
