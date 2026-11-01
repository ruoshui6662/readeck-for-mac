import AppKit
import CryptoKit
import ImageIO
import SwiftSoup

/// Never send a NAS token to an arbitrary image URL returned by page metadata.
enum CoverResourcePolicy {
    static func url(_ src: String, root: URL) -> URL? {
        guard let url = URL(string: src, relativeTo: root)?.absoluteURL.standardized,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.scheme?.lowercased() == root.scheme?.lowercased(), url.host?.lowercased() == root.host?.lowercased(),
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (root.port ?? (root.scheme == "https" ? 443 : 80)),
              url.user == nil, url.password == nil,
              url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else { return nil }
        return url
    }
}

/// Only saved NAS resources are eligible; never fetch source-site image URLs with a NAS token.
enum CoverArticleCandidates {
    static func resources(html: String, root: URL) -> [BookmarkResource] {
        guard let document = try? SwiftSoup.parse(html), let images = try? document.select("img") else { return [] }
        var result: [BookmarkResource] = []
        var seen = Set<String>()
        for image in images {
            guard result.count < 8 else { break }
            if isExplicitDecoration(image) { continue }
            let width = Int((try? image.attr("width")) ?? "")
            let height = Int((try? image.attr("height")) ?? "")
            if let width, width < 120 { continue }
            if let height, height < 80 { continue }
            guard let src = try? image.attr("src"),
                  let url = CoverResourcePolicy.url(src, root: root),
                  seen.insert(url.absoluteString).inserted else { continue }
            result.append(BookmarkResource(src: url.absoluteString))
        }
        return result
    }

    private static func isExplicitDecoration(_ image: Element) -> Bool {
        let names = ["avatar", "favicon", "logo", "qrcode", "qr-code", "site-logo", "author-avatar"]
        let attributes = ["class", "id"].compactMap { try? image.attr($0).lowercased() }
        for attribute in attributes {
            let words = attribute.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if words.contains(where: { ["avatar", "favicon", "qrcode"].contains($0) }) { return true }
            if attribute.split(whereSeparator: { $0.isWhitespace }).contains(where: { names.contains(String($0)) }) { return true }
        }
        let alt = ((try? image.attr("alt")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["logo", "网站 logo", "网站logo", "站点 logo", "站点logo", "头像", "作者头像", "二维码"].contains(alt)
    }
}

enum CoverQuality {
    static func isUsefulCover(width: Int, height: Int) -> Bool {
        width >= 120 && height >= 80 && max(width, height) >= 200
    }
}

final class CoverRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class CoverImageStore {
    static let shared = CoverImageStore()
    private let cache = NSCache<NSString, NSImage>()
    private var failed: [String: Date] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    init() { cache.totalCostLimit = 40 * 1024 * 1024; cache.countLimit = 120 }

    func image(for bookmark: Bookmark, client: ReadeckClient) async -> NSImage? {
        let identity = client.storageInstance + "|" + bookmark.id + "|" + (bookmark.updated ?? "") + bookmark.coverResources.map(\.src).joined(separator: "|")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let date = failed[key], Date().timeIntervalSince(date) < 60 { return nil }
        if let task = inFlight[key] { return await task.value }
        let task = Task<NSImage?, Never> {
            // Older cached bookmark JSON predates resource decoding. Enrich only
            // visible cards through the same short, isolated image session.
            var resources = bookmark.coverResources
            if resources.isEmpty, let detailed = try? await client.coverMetadata(id: bookmark.id) {
                resources = detailed.coverResources
            }
            func load(_ resource: BookmarkResource) async -> NSImage? {
                guard let data = try? await client.coverData(resource: resource),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      CoverQuality.isUsefulCover(width: width, height: height),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else { return nil }
                let result = NSImage(cgImage: image, size: .zero)
                cache.setObject(result, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                return result
            }
            var genericCover = false
            if let host = URL(string: bookmark.url)?.host?.lowercased(), host == "cnblogs.com" || host.hasSuffix(".cnblogs.com"),
               let meta = try? await client.coverOriginMetadata(id: bookmark.id) {
                let origin = (meta["x.picture_url"] ?? []).first ?? (meta["graph.image"] ?? []).first
                if let origin, let url = URL(string: origin) {
                    genericCover = url.host?.lowercased() == "assets.cnblogs.com" && url.path.lowercased() == "/images/wechat-share.jpg"
                }
            }
            if !genericCover {
                for resource in resources {
                    guard !Task.isCancelled else { return nil }
                    if let image = await load(resource) { return image }
                }
            }
            // Article HTML and candidate images use the short, bounded NAS-only session.
            if !Task.isCancelled, let html = try? await client.coverArticle(id: bookmark.id) {
                for resource in CoverArticleCandidates.resources(html: html, root: client.address.root) {
                    guard !Task.isCancelled else { return nil }
                    if let image = await load(resource) { return image }
                }
            }
            if failed.count >= 120 { failed.removeAll() }
            failed[key] = Date()
            return nil
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }
}
