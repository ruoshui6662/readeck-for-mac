import XCTest
import CryptoKit
@testable import ReadeckMac

final class CoverImageTests: XCTestCase {
    func testOldBookmarksStillDecodeAndResourcesPreferThumbnail() throws {
        let old = try JSONDecoder().decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com"}"#.utf8))
        XCTAssertNil(old.resources)
        let book = try JSONDecoder().decode(Bookmark.self, from: Data(#"{"id":"one","url":"https://example.com","resources":{"thumbnail":{"src":"/media/thumb.jpg","width":400,"height":250},"image":{"src":"/media/large.jpg"}}}"#.utf8))
        XCTAssertEqual(book.coverResources.map(\.src), ["/media/thumb.jpg", "/media/large.jpg"])
    }
    func testOnlyCurrentNASOriginCanReceiveCredentials() throws {
        let root = try ServerAddress("http://nas.test:8180/readeck/").root
        XCTAssertNotNil(CoverResourcePolicy.url("/readeck/media/a.jpg", root: root))
        XCTAssertNotNil(CoverResourcePolicy.url("media/a.jpg", root: root))
        for value in ["https://external.test/a.jpg", "http://nas.test:8181/readeck/a.jpg", "http://u:p@nas.test:8180/readeck/a.jpg", "file:///tmp/a", "data:image/png,x", "//external.test/a", "../other/a.jpg"] {
            XCTAssertNil(CoverResourcePolicy.url(value, root: root), value)
        }
    }
    func testBodyImageCandidatesUseOnlyNASResourcesAndSkipSmallDecorations() throws {
        let root = try ServerAddress("http://nas.test:8180/").root
        let html = """
        <img src="https://evil.test/tracker"><img src="/bm/a/logo.png" width="32" height="32">
        <img src="/bm/a/first.jpg"><img src="/bm/a/first.jpg"><img src="/bm/a/second.jpg">
        """
        let images = CoverArticleCandidates.resources(html: html, root: root)
        XCTAssertEqual(images.map(\.src), ["http://nas.test:8180/bm/a/first.jpg", "http://nas.test:8180/bm/a/second.jpg"])
    }

    func testBodyCoverSkipsIdentifiedDecorativeImagesBeforeCandidateLimit() throws {
        let root = try ServerAddress("http://nas.test/").root
        let decoration = (0..<9).map { "<img class='author-avatar' src='/bm/avatar\($0).jpg'>" }.joined()
        let html = decoration + "<img alt='网站 logo' src='/bm/logo.jpg'><img alt='文章示意图' src='/bm/article.jpg'>"
        let images = CoverArticleCandidates.resources(html: html, root: root)
        XCTAssertEqual(images.map(\.src), ["http://nas.test/bm/article.jpg"])
    }

    func testSmallSquareSiteImagesAreNotTreatedAsArticleCovers() {
        XCTAssertFalse(CoverQuality.isUsefulCover(width: 120, height: 120))
        XCTAssertFalse(CoverQuality.isUsefulCover(width: 128, height: 128))
        XCTAssertTrue(CoverQuality.isUsefulCover(width: 380, height: 253))
        XCTAssertTrue(CoverQuality.isUsefulCover(width: 250, height: 250))
    }

    func testArtFallbackIsStableAndAllBundledImagesHaveProvenance() throws {
        let catalog = try ArtCoverCatalog.load()
        XCTAssertEqual(catalog.count, 6)
        XCTAssertEqual(ArtCoverCatalog.artwork(for: "https://example.com/one", in: catalog).id,
                       ArtCoverCatalog.artwork(for: "https://example.com/one", in: catalog).id)
        for item in catalog {
            XCTAssertTrue(item.isPublicDomain)
            XCTAssertEqual(item.license, "CC0-1.0")
            let url = try XCTUnwrap(ArtCoverCatalog.imageURL(for: item))
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, item.sha256)
            XCTAssertTrue(item.source.hasPrefix("https://www.artic.edu/artworks/"))
        }
    }
    func testCoverRequestsAuthenticateOnlyToNASAndRejectForeignMetadataBeforeNetwork() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTestProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://covers.test/"), token: "test-cover-token", session: URLSession(configuration: configuration))
        CoverTestProtocol.reset(data: Data("image-data".utf8))
        let data = try await client.coverData(resource: BookmarkResource(src: "/bm/one/img/cover.jpg"))
        XCTAssertEqual(data, Data("image-data".utf8))
        XCTAssertEqual(CoverTestProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-cover-token")
        XCTAssertEqual(CoverTestProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), "image/*")
        do {
            _ = try await client.coverData(resource: BookmarkResource(src: "https://foreign.test/private.jpg"))
            XCTFail("External resource must not be requested")
        } catch {}
        XCTAssertEqual(CoverTestProtocol.requests.count, 1)
    }

    @MainActor
    func testOldCachedBookmarksFetchOnlyNASMetadataBeforeCover() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTestProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://covers.test/"), token: "test", session: URLSession(configuration: configuration))
        let art = try XCTUnwrap(ArtCoverCatalog.shared.first)
        CoverTestProtocol.reset(data: try Data(contentsOf: XCTUnwrap(ArtCoverCatalog.imageURL(for: art))))
        let image = await CoverImageStore().image(for: Bookmark(id: "legacy", url: "https://original.test/"), client: client)
        XCTAssertNotNil(image)
        XCTAssertEqual(CoverTestProtocol.requests.map { $0.url!.path }, ["/api/bookmarks/legacy", "/bm/legacy/img/cover.jpg"])
        XCTAssertTrue(CoverTestProtocol.requests.allSatisfy { $0.url?.host == "covers.test" })
    }

    @MainActor
    func testInvalidImageUsesFallbackAndFailedResultIsTemporarilyMemoized() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTestProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://covers.test/"), token: "test", session: URLSession(configuration: configuration))
        CoverTestProtocol.reset(data: Data("not-an-image".utf8))
        let book = Bookmark(id: "one", url: "https://original.test/", resources: ["thumbnail": BookmarkResource(src: "/bm/one/img/cover.jpg")])
        let store = CoverImageStore()
        let first = await store.image(for: book, client: client)
        let again = await store.image(for: book, client: client)
        XCTAssertNil(first)
        XCTAssertNil(again)
        XCTAssertEqual(CoverTestProtocol.requests.count, 2)
        XCTAssertFalse(ArtCoverCatalog.shared.isEmpty)
    }

    @MainActor
    func testBrokenCoverFallsBackToFirstUsableSavedBodyImage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTestProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://covers.test/"), token: "test", session: URLSession(configuration: configuration))
        let art = try XCTUnwrap(ArtCoverCatalog.shared.first)
        CoverTestProtocol.reset(data: try Data(contentsOf: XCTUnwrap(ArtCoverCatalog.imageURL(for: art))))
        let book = Bookmark(id: "body-fallback", url: "https://original.test/", resources: ["thumbnail": BookmarkResource(src: "/broken.jpg")])
        let image = await CoverImageStore().image(for: book, client: client)
        XCTAssertNotNil(image)
        XCTAssertEqual(CoverTestProtocol.requests.compactMap { $0.url?.path }, ["/broken.jpg", "/api/bookmarks/body-fallback/article", "/bm/body-image.jpg"])
        XCTAssertTrue(CoverTestProtocol.requests.allSatisfy { $0.url?.host == "covers.test" })
    }

    @MainActor
    func testGenericCnblogsShareImageFallsBackToArticleImage() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTestProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("http://covers.test/"), token: "test", session: URLSession(configuration: configuration))
        let art = try XCTUnwrap(ArtCoverCatalog.shared.first)
        CoverTestProtocol.reset(data: try Data(contentsOf: XCTUnwrap(ArtCoverCatalog.imageURL(for: art))))
        let book = Bookmark(id: "generic", url: "https://www.cnblogs.com/test/p/1", resources: ["thumbnail": BookmarkResource(src: "/generic.jpg")])
        let image = await CoverImageStore().image(for: book, client: client)
        XCTAssertNotNil(image)
        XCTAssertEqual(CoverTestProtocol.requests.compactMap { $0.url?.path }, ["/api/bookmarks/generic/x/props.json", "/api/bookmarks/generic/article", "/bm/body-image.jpg"])
    }

    @MainActor
    func testCnblogsGenericCoverOnIsolatedServer() async throws {
        guard let directory = ProcessInfo.processInfo.environment["READECK_COVER_LOCAL_VALIDATION"] else { throw XCTSkip("Opt-in isolated server cover check") }
        let token = try String(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("token.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = ReadeckClient(address: try ServerAddress("http://127.0.0.1:18981/"), token: token)
        let url = "https://www.cnblogs.com/misswell/p/22851429"
        let id = try await client.createBookmark(PendingSave(url: url, title: "", labels: []))
        do {
            var item: Bookmark?
            for _ in 0..<50 {
                let value = try await client.bookmark(id: id)
                if !value.isProcessing { item = value; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            let book = try XCTUnwrap(item)
            let meta = try await client.coverOriginMetadata(id: id)
            XCTAssertTrue((meta["graph.image"] ?? []).contains("https://assets.cnblogs.com/images/wechat-share.jpg"))
            XCTAssertFalse(book.coverResources.isEmpty)
            let cover = await CoverImageStore().image(for: book, client: client)
            XCTAssertNil(cover, "No body image: use bundled artwork rather than generic share image")
            try await client.deleteBookmark(id: id)
        } catch {
            try? await client.deleteBookmark(id: id)
            throw error
        }
    }

    @MainActor
    func testMemoryCoversReuseDecodedImageAndSeparateAccountTokens() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverTestProtocol.self]
        let session = URLSession(configuration: configuration)
        let address = try ServerAddress("http://covers.test/")
        let one = ReadeckClient(address: address, token: "account-one", session: session)
        let two = ReadeckClient(address: address, token: "account-two", session: session)
        let art = try XCTUnwrap(ArtCoverCatalog.shared.first)
        CoverTestProtocol.reset(data: try Data(contentsOf: XCTUnwrap(ArtCoverCatalog.imageURL(for: art))))
        let book = Bookmark(id: "one", url: "https://example.com", resources: ["thumbnail": BookmarkResource(src: "/bm/one/img/cover.jpg")])
        let store = CoverImageStore()
        let first = await store.image(for: book, client: one)
        let cached = await store.image(for: book, client: one)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === cached)
        XCTAssertEqual(CoverTestProtocol.requests.count, 1)
        let other = await store.image(for: book, client: two)
        XCTAssertNotNil(other)
        XCTAssertEqual(CoverTestProtocol.requests.count, 2)
    }

}

private final class CoverTestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var bytes = Data()
    private static var sent: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return sent }
    static func reset(data: Data) { lock.lock(); bytes = data; sent = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.sent.append(request); var data = Self.bytes; Self.lock.unlock()
        if request.url?.path == "/api/bookmarks/generic/x/props.json" { data = Data(#"{"Meta":{"graph.image":["https://assets.cnblogs.com/images/wechat-share.jpg"]}}"#.utf8) }
        if request.url?.path == "/api/bookmarks/generic/article" { data = Data("<img src='/bm/body-image.jpg'>".utf8) }
        if request.url?.path == "/broken.jpg" { data = Data("not-image".utf8) }
        if request.url?.path == "/api/bookmarks/body-fallback/article" { data = Data("<img src='https://foreign.test/a'><img src='/bm/body-image.jpg'>".utf8) }
        if request.url?.path == "/api/bookmarks/legacy" {
            data = Data(#"{"id":"legacy","url":"https://original.test/","resources":{"thumbnail":{"src":"/bm/legacy/img/cover.jpg"}}}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
