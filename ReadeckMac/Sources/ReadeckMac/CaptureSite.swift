import Foundation

enum CaptureSite: String, Sendable {
    case wechat, xiaohongshu, baike, ithome, douban, bilibili
    var availableForCapture: Bool { self != .xiaohongshu }
    var title: String {
        switch self { case .wechat: "微信文章"; case .xiaohongshu: "小红书图文"; case .baike: "百度百科"; case .ithome: "IT之家"; case .douban: "豆瓣影评"; case .bilibili: "B站专栏" }
    }
    var hosts: Set<String> {
        switch self {
        case .wechat: ["mp.weixin.qq.com"]
        case .xiaohongshu: ["www.xiaohongshu.com", "xiaohongshu.com", "m.xiaohongshu.com", "xhslink.com", "www.xhslink.com", "xhslink.cn", "www.xhslink.cn", "www.rednote.com", "rednote.com", "m.rednote.com"]
        case .baike: ["baike.baidu.com"]
        case .ithome: ["www.ithome.com"]
        case .douban: ["movie.douban.com", "sec.douban.com"]
        case .bilibili: ["www.bilibili.com"]
        }
    }
}

struct CaptureSourceURL: Sendable {
    let original: URL
    let canonical: URL
    let site: CaptureSite
    let articleID: String?

    init(_ value: String) throws {
        guard var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, let original = parts.url else { throw WechatParseError.invalidURL }
        self.original = original
        let components = parts.path.split(separator: "/").map(String.init)
        if host == "mp.weixin.qq.com", parts.path == "/s" || parts.path.hasPrefix("/s/") {
            site = .wechat; articleID = components.count > 1 ? components[1] : nil
            let publicKeys = Set(["__biz", "mid", "idx", "sn", "chksm"])
            parts.queryItems = parts.path == "/s" ? parts.queryItems?.filter { publicKeys.contains($0.name) } : nil
        } else if CaptureSite.xiaohongshu.hosts.contains(host) {
            site = .xiaohongshu
            if ["xhslink.com", "www.xhslink.com", "xhslink.cn", "www.xhslink.cn"].contains(host) {
                guard !components.isEmpty else { throw WechatParseError.invalidURL }
                articleID = nil
            } else {
                let id: String?
                if components.count == 2, ["explore", "search_result"].contains(components[0]) { id = components[1] }
                else if components.count == 3, components[0] == "discovery", components[1] == "item" { id = components[2] }
                else { id = nil }
                guard let id, id.utf8.count <= 64, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw WechatParseError.invalidURL }
                articleID = id
                let international = ["rednote.com", "www.rednote.com", "m.rednote.com"].contains(host)
                parts.host = international ? "www.rednote.com" : "www.xiaohongshu.com"
                parts.path = (international ? "/discovery/item/" : "/explore/") + id
            }
            parts.queryItems = nil
        } else if host == "baike.baidu.com", components.count >= 2, components[0] == "item" {
            site = .baike; articleID = components.dropFirst().joined(separator: "/"); parts.queryItems = nil
        } else if host == "movie.douban.com", components.count == 2, components[0] == "review",
                  !components[1].isEmpty, components[1].utf8.count <= 20, components[1].utf8.allSatisfy({ (48...57).contains($0) }) {
            site = .douban; articleID = components[1]; parts.path = "/review/\(components[1])/"; parts.queryItems = nil
        } else if host == "www.bilibili.com", components.count == 2,
                  (components[0] == "opus" || (components[0] == "read" && components[1].hasPrefix("cv"))) {
            let digits = components[0] == "read" ? String(components[1].dropFirst(2)) : components[1]
            guard !digits.isEmpty, digits.utf8.count <= 20, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { throw WechatParseError.invalidURL }
            site = .bilibili; articleID = (components[0] == "read" ? "cv" : "opus") + digits
            parts.path = components[0] == "read" ? "/read/cv\(digits)/" : "/opus/\(digits)"; parts.queryItems = nil
        } else if host == "www.ithome.com", components.count == 3,
                  components[0].allSatisfy({ $0.isNumber }), components[1].allSatisfy({ $0.isNumber }),
                  components[2].hasSuffix(".htm"), components[2].dropLast(4).allSatisfy({ $0.isNumber }) {
            site = .ithome; articleID = components.joined(separator: "/"); parts.queryItems = nil
        } else { throw WechatParseError.invalidURL }
        parts.scheme = "https"; parts.port = nil; parts.fragment = nil
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        guard let canonical = parts.url else { throw WechatParseError.invalidURL }
        self.canonical = canonical
    }

    func allowsNavigation(to url: URL) -> Bool {
        guard let p = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(p.scheme?.lowercased() ?? ""), p.user == nil, p.password == nil,
              p.port == nil || p.port == 443, let host = p.host?.lowercased() else { return false }
        return site.hosts.contains(host)
    }
}

enum CaptureInput {
    static func url(in value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // NSDataDetector handles pasted Chinese share text and surrounding punctuation.
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url.absoluteString
    }
}
