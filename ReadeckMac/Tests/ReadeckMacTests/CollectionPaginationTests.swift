import Foundation
import XCTest
@testable import ReadeckMac

final class CollectionPaginationTests: XCTestCase {
    override func tearDown() {
        CollectionURLProtocol.respond = nil
        super.tearDown()
    }

    func testCollectionsRespectServerLimitAndLoadRemainingPages() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollectionURLProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://nas.test/"),
                                   token: "test", session: URLSession(configuration: configuration))
        var offsets: [Int] = []
        CollectionURLProtocol.respond = { request in
            XCTAssertEqual(request.url?.path, "/api/bookmarks/collections")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let limit = Int(query.first(where: { $0.name == "limit" })?.value ?? "0") ?? 0
            let offset = Int(query.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
            guard (1...100).contains(limit) else { return (404, Data("{}".utf8)) }
            offsets.append(offset)
            let count = offset == 0 ? 100 : 1
            let page = (offset..<(offset + count)).map { index in
                ["id": "collection-\(index)", "name": "Collection \(index)"]
            }
            return (200, try JSONSerialization.data(withJSONObject: page))
        }

        let collections = try await client.collections()

        XCTAssertEqual(collections.count, 101)
        XCTAssertEqual(Set(collections.map(\.id)).count, 101)
        XCTAssertEqual(offsets, [0, 100])
        XCTAssertEqual(collections.last?.id, "collection-100")
    }
}

private final class CollectionURLProtocol: URLProtocol {
    static var respond: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.respond!(request)
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
