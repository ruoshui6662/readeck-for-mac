import Foundation

/// Resolves only the public cv-to-opus mapping. This session never receives NAS credentials.
enum BilibiliLegacyResolver {
    static func opusURL(data: Data, expectedCV: String) throws -> URL {
        struct Response: Decodable {
            struct Article: Decodable { let id: Int64; let dyn_id_str: String? }
            let code: Int
            let data: Article?
        }
        guard data.count <= 2 * 1024 * 1024,
              let result = try? JSONDecoder().decode(Response.self, from: data), result.code == 0,
              let item = result.data, String(item.id) == expectedCV,
              let id = item.dyn_id_str, !id.isEmpty, id.utf8.count <= 20,
              id.utf8.allSatisfy({ (48...57).contains($0) }),
              let url = URL(string: "https://www.bilibili.com/opus/\(id)") else {
            throw WechatParseError.parseError("无法确认 B 站旧专栏的对应文章，可能受到频率限制；请稍后重试或使用新版图文链接。")
        }
        return url
    }

    static func resolve(_ source: CaptureSourceURL) async throws -> URL {
        guard source.site == .bilibili, let id = source.articleID, id.hasPrefix("cv") else { return source.original }
        let digits = String(id.dropFirst(2))
        guard let url = URL(string: "https://api.bilibili.com/x/article/view?id=\(digits)") else { throw WechatParseError.invalidURL }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config, delegate: CoverRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WechatParseError.parseError("无法确认 B 站旧专栏的对应文章，请稍后重试或使用新版图文链接。")
        }
        return try opusURL(data: data, expectedCV: digits)
    }
}
