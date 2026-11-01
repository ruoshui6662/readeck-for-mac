import CryptoKit
import Foundation
import ImageIO

struct InstanceInfo: Decodable {
    struct Version: Decodable { let release: String? }
    let version: Version?
    let features: [String]?
}

struct ReadeckClient {
    let address: ServerAddress
    let token: String
    private let session: URLSession
    private let coverSession: URLSession
    private let captureSession: URLSession
    private let permissionCheck: @Sendable (URL) async -> Bool

    init(address: ServerAddress, token: String, session: URLSession? = nil,
         permissionCheck: @escaping @Sendable (URL) async -> Bool = LocalNetworkAccess.isDenied(for:)) {
        self.address = address
        self.token = token
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
        if let session { captureSession = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false; config.urlCache = nil
            config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 180
            config.waitsForConnectivity = false
            captureSession = URLSession(configuration: config, delegate: CoverRedirectBlocker(), delegateQueue: nil)
        }
        self.permissionCheck = permissionCheck
        if let session { coverSession = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 4
            configuration.timeoutIntervalForResource = 8
            configuration.httpMaximumConnectionsPerHost = 4
            coverSession = URLSession(configuration: configuration, delegate: CoverRedirectBlocker(), delegateQueue: nil)
        }
    }

    var storageInstance: String {
        let digest = SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "\(address.root.absoluteString)|token-sha256:\(digest)"
    }

    func info() async throws -> InstanceInfo {
        try await get("info", authenticated: false)
    }

    func verify() async throws {
        let _: Data = try await request("profile")
    }

    func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        let data: Data = try await request(path, authenticated: authenticated)
        return try JSONDecoder.readeck.decode(T.self, from: data)
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil,
                 authenticated: Bool = true, accept: String = "application/json") async throws -> Data {
        try await perform(address.api(path), method: method, body: body,
                          authenticated: authenticated, accept: accept).0
    }

    private func perform(_ url: URL, method: String = "GET", body: Data? = nil,
                         authenticated: Bool = true, accept: String = "application/json") async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        try Task.checkCancellation()
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            if let network = error as? URLError, network.code == .notConnectedToInternet,
               await permissionCheck(url) {
                throw NetworkAccessError.localNetworkDenied
            }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.status(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    func syncEntries(since: String?) async throws -> [SyncEntry] {
        var parts = URLComponents(url: address.api("bookmarks/sync"), resolvingAgainstBaseURL: false)!
        if let since { parts.queryItems = [URLQueryItem(name: "since", value: since)] }
        let (data, _) = try await perform(parts.url!)
        return try JSONDecoder.readeck.decode([SyncEntry].self, from: data)
    }

    func bookmark(id: String) async throws -> Bookmark {
        try await get("bookmarks/\(id)")
    }

    func labelNames() async throws -> [String] {
        struct Label: Decodable { let name: String }
        let labels: [Label] = try await get("bookmarks/labels")
        return labels.map(\.name)
    }

    func collections() async throws -> [CollectionInfo] {
        var result: [CollectionInfo] = []
        var offset = 0
        while true {
            let page: [CollectionInfo] = try await get("bookmarks/collections?limit=100&offset=\(offset)")
            result += page
            if page.count < 100 { return result }
            offset += 100
        }
    }

    func listBookmarks(query: [URLQueryItem]) async throws -> [Bookmark] {
        var result: [Bookmark] = []
        var offset = 0
        while true {
            var parts = URLComponents(url: address.api("bookmarks"), resolvingAgainstBaseURL: false)!
            parts.queryItems = query + [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: String(offset))]
            let (data, _) = try await perform(parts.url!)
            let page = try JSONDecoder.readeck.decode([Bookmark].self, from: data)
            result += page
            if page.count < 100 { return result }
            offset += 100
        }
    }

    func createBookmark(_ pending: PendingSave) async throws -> String {
        struct Payload: Encodable { let url: String; let title: String; let labels: [String] }
        let body = try JSONEncoder().encode(Payload(url: pending.url, title: pending.title, labels: pending.labels))
        let (_, response) = try await perform(address.api("bookmarks"), method: "POST", body: body)
        guard let id = response.value(forHTTPHeaderField: "Bookmark-Id"), !id.isEmpty else {
            throw APIError.invalidResponse
        }
        return id
    }

    func matchingBookmarks(for pending: PendingSave) async throws -> [Bookmark] {
        var matches: [Bookmark] = []
        var offset = 0
        while true {
            let page: [Bookmark] = try await get("bookmarks?limit=100&offset=\(offset)")
            matches += page.filter { isReconciliationMatch($0, pending: pending) }
            if page.count < 100 { return matches }
            offset += 100
        }
    }

    func patchBookmark(id: String, fields: [String: Any]) async throws -> Bookmark {
        let data = try JSONSerialization.data(withJSONObject: fields)
        _ = try await request("bookmarks/\(id)", method: "PATCH", body: data)
        return try await bookmark(id: id)
    }

    func deleteBookmark(id: String) async throws {
        try await deleteAllowingMissing(address.api("bookmarks/\(id)"))
    }

    func renameLabel(oldName: String, newName: String) async throws {
        var parts = URLComponents(url: address.api("bookmarks/labels"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "name", value: oldName)]
        let body = try JSONSerialization.data(withJSONObject: ["name": newName])
        do { _ = try await perform(parts.url!, method: "PATCH", body: body) }
        catch APIError.status(404, _) {
            // The source label has no remaining articles (possibly renamed by a
            // previous request whose response was lost). No rename remains to do.
        }
    }

    func deleteLabel(name: String) async throws {
        var parts = URLComponents(url: address.api("bookmarks/labels"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "name", value: name)]
        try await deleteAllowingMissing(parts.url!)
    }

    private func deleteAllowingMissing(_ url: URL) async throws {
        do { _ = try await perform(url, method: "DELETE") }
        catch APIError.status(404, _) { }
    }

    func annotations(bookmarkID: String) async throws -> [BookmarkAnnotation] {
        try await get("bookmarks/\(bookmarkID)/annotations")
    }

    func createAnnotation(bookmarkID: String, selection: AnnotationSelection,
                          color: String, note: String) async throws -> BookmarkAnnotation {
        let fields: [String: Any] = ["start_selector": selection.startSelector,
                                    "start_offset": selection.startOffset,
                                    "end_selector": selection.endSelector,
                                    "end_offset": selection.endOffset, "color": color, "note": note]
        let data = try await request("bookmarks/\(bookmarkID)/annotations", method: "POST",
                                     body: JSONSerialization.data(withJSONObject: fields))
        return try JSONDecoder.readeck.decode(BookmarkAnnotation.self, from: data)
    }

    func updateAnnotation(bookmarkID: String, id: String, color: String, note: String) async throws {
        _ = try await request("bookmarks/\(bookmarkID)/annotations/\(id)", method: "PATCH",
                              body: JSONSerialization.data(withJSONObject: ["color": color, "note": note]))
    }

    func deleteAnnotation(bookmarkID: String, id: String) async throws {
        try await deleteAllowingMissing(address.api("bookmarks/\(bookmarkID)/annotations/\(id)"))
    }

    func uploadCapture(_ package: CapturePackage, title: String, labels: [String]) async throws -> String {
        try Task.checkCancellation()
        let file = try CaptureMultipart.write(package: package, title: title, labels: labels, directory: package.directory)
        defer { try? FileManager.default.removeItem(at: file.url) }
        var request = URLRequest(url: address.api("bookmarks"))
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await captureSession.upload(for: request, fromFile: file.url)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.status(http.statusCode, "") }
        guard let id = http.value(forHTTPHeaderField: "Bookmark-Id"), !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { throw APIError.invalidResponse }
        // The caller persists this ID even if the parent task was cancelled as the response arrived.
        return id
    }

    func verifyCapture(id: String, manifest: CaptureManifest) async throws -> Bookmark {
        let item = try await bookmark(id: id)
        guard !item.isProcessing else { throw CaptureError.verification("服务端正在处理，稍后继续检查。") }
        guard item.state != 1, item.hasArticle == true else { throw CaptureError.verification("服务端未生成完整正文，保留本机采集文件。") }
        let html = try await article(id: id)
        guard try CaptureVerification.matches(html, manifest: manifest) else { throw CaptureError.verification("正文与本机采集不符。") }
        let articleURL = address.api("bookmarks/\(id)/article")
        let orderedURLs = try CaptureVerification.imageURLs(html, base: articleURL)
        let urls = Array(Set(orderedURLs))
        let bodyAssets = manifest.assets.filter { $0.coverOnly != true }
        guard urls.count >= bodyAssets.count else { throw CaptureError.verification("归档图片数量不足。") }
        var visualImages: [CaptureImageIdentity.Value] = []
        var imagesByURL: [URL: CaptureImageIdentity.Value] = [:]
        for url in urls {
            guard CoverResourcePolicy.url(url.absoluteString, root: address.root) != nil else { throw CaptureError.verification("图片仍引用外部网站。") }
            var request = URLRequest(url: url); request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (bytes, response) = try await captureSession.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  bytes.count <= CaptureLimits().maximumImageBytes,
                  let visual = CaptureImageIdentity.read(bytes), visual.width > 2 || visual.height > 2 else {
                throw CaptureError.verification("有图片无法从 NAS 读取。")
            }
            visualImages.append(visual)
            imagesByURL[url] = visual
        }
        guard CaptureVerification.imagesMatch(expected: bodyAssets, actual: visualImages) else {
            throw CaptureError.verification("归档图片与本机采集不匹配，保留本机采集文件。")
        }
        if let order = manifest.imageOrder {
            let assets = Dictionary(uniqueKeysWithValues: manifest.assets.map { ($0.location, $0) })
            let expected = order.compactMap { assets[$0] }
            guard expected.count == order.count,
                  CaptureVerification.orderedImagesMatch(expected: expected, actual: orderedURLs.compactMap { imagesByURL[$0] }) else {
                throw CaptureError.verification("图片顺序或清晰度与本机采集不符，保留本机采集文件。")
            }
        }
        return item
    }

    func article(id: String) async throws -> String {
        let data = try await request("bookmarks/\(id)/article", accept: "text/html")
        return String(data: data, encoding: .utf8) ?? ""
    }

    func coverData(resource: BookmarkResource) async throws -> Data {
        guard let url = CoverResourcePolicy.url(resource.src, root: address.root) else { throw APIError.invalidResponse }
        return try await coverRequest(url, accept: "image/*", limit: 8 * 1024 * 1024)
    }

    func coverArticle(id: String) async throws -> String {
        let data = try await coverRequest(address.api("bookmarks/\(id)/article"), accept: "text/html", limit: 2 * 1024 * 1024)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func coverOriginMetadata(id: String) async throws -> [String: [String]] {
        let data = try await coverRequest(address.api("bookmarks/\(id)/x/props.json"), accept: "application/json", limit: 1024 * 1024)
        struct Properties: Decodable { let Meta: [String: [String]]? }
        return try JSONDecoder().decode(Properties.self, from: data).Meta ?? [:]
    }

    func coverMetadata(id: String) async throws -> Bookmark {
        let url = address.api("bookmarks/\(id)")
        let data = try await coverRequest(url, accept: "application/json", limit: 1024 * 1024)
        return try JSONDecoder.readeck.decode(Bookmark.self, from: data)
    }

    private func coverRequest(_ url: URL, accept: String, limit: Int) async throws -> Data {
        guard CoverResourcePolicy.url(url.absoluteString, root: address.root) != nil else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await coverSession.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= limit else { throw APIError.invalidResponse }
        return data
    }

    private func isReconciliationMatch(_ bookmark: Bookmark, pending: PendingSave) -> Bool {
        guard Self.reconciliationURL(bookmark.url) == Self.reconciliationURL(pending.url),
              isNearCreation(bookmark.created, pending.attemptedAt ?? pending.created) else {
            return false
        }

        let requestedTitle = pending.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !requestedTitle.isEmpty,
           bookmark.title?.trimmingCharacters(in: .whitespacesAndNewlines) != requestedTitle {
            return false
        }
        let requestedLabels = Set(pending.labels)
        if !requestedLabels.isEmpty,
           !requestedLabels.isSubset(of: Set(bookmark.labelValues)) {
            return false
        }
        return true
    }

    static func reconciliationURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.fragment = nil
        return components.string ?? raw
    }

    private func isNearCreation(_ created: String?, _ pending: Date) -> Bool {
        guard let created else { return false }
        let formatter = ISO8601DateFormatter()
        let value = formatter.date(from: created) ?? {
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: created)
        }()
        guard let value else { return false }
        let interval = value.timeIntervalSince(pending)
        return interval >= -60 && interval <= 15
    }
}

enum APIError: LocalizedError {
    case invalidResponse
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "服务端返回了无效响应。"
        case let .status(code, _): "服务端请求失败（HTTP \(code)）。"
        }
    }
}

extension JSONDecoder {
    static var readeck: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
