import Foundation

enum CaptureArticleParser {
    static func extract(archive: Data, source: CaptureSourceURL, packageID: String,
                        limits: CaptureLimits = CaptureLimits()) throws -> CapturedArticle {
        if source.site == .wechat { return try WechatArticleParser.extract(archive: archive, source: source, packageID: packageID, limits: limits) }
        guard archive.count <= limits.maximumArchiveBytes,
              let plist = try PropertyListSerialization.propertyList(from: archive, options: [], format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any] else { throw CaptureError.invalidPackage }
        var resolved = source
        if let url = main["WebResourceURL"] as? String, !url.isEmpty {
            resolved = try CaptureSourceURL(url)
            guard resolved.site == source.site, source.allowsNavigation(to: resolved.original),
                  source.articleID == nil || resolved.articleID == source.articleID else { throw CaptureError.invalidPackage }
        }
        guard resolved.site != .xiaohongshu || resolved.articleID != nil else { throw WechatParseError.interactionRequired }
        return try CaptureArchiveParser.extract(archive: archive, source: resolved, packageID: packageID, limits: limits)
    }
}
