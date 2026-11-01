import Foundation

/// Deterministic DOM adapter; networking lives exclusively in ArticleCaptureSession.
enum WechatArticleParser {
    static func extract(archive: Data, source: CaptureSourceURL, packageID: String,
                        limits: CaptureLimits = CaptureLimits()) throws -> CapturedArticle {
        guard source.site == .wechat else { throw WechatParseError.invalidURL }
        return try CaptureArchiveParser.extract(archive: archive, source: source, packageID: packageID, limits: limits)
    }

    static func isWechatArticleURL(_ value: String) -> Bool {
        URLComponents(string: value)?.host?.lowercased() == "mp.weixin.qq.com"
    }
}
