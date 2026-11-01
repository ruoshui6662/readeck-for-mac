import Foundation

enum ServerAddressError: LocalizedError {
    case invalid

    var errorDescription: String? {
        "请输入完整的 http:// 或 https:// 服务端地址。"
    }
}

struct ServerAddress: Hashable {
    let root: URL

    init(_ raw: String) throws {
        guard var parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw ServerAddressError.invalid
        }
        parts.scheme = scheme
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw ServerAddressError.invalid }
        root = url
    }

    func api(_ path: String) -> URL {
        URL(string: "api/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), relativeTo: root)!.absoluteURL
    }
}
