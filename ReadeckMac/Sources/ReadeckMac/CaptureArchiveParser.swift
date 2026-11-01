import Foundation
import ImageIO
import SwiftSoup
import UniformTypeIdentifiers

enum CaptureArchiveParser {
    static func extract(archive: Data, source: CaptureSourceURL, packageID: String,
                        limits: CaptureLimits = CaptureLimits()) throws -> CapturedArticle {
        guard archive.count <= limits.maximumArchiveBytes else { throw WechatParseError.parseError("网页归档超过大小上限。") }
        guard let plist = try PropertyListSerialization.propertyList(from: archive, options: [], format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any], let bytes = main["WebResourceData"] as? Data,
              bytes.count <= limits.maximumHTMLBytes, let html = String(data: bytes, encoding: .utf8) else {
            throw WechatParseError.parseError("网页归档缺少有效正文。")
        }
        let document = try SwiftSoup.parse(html, source.canonical.absoluteString)
        guard let root = try document.select(source.site == .wechat ? "#readeck-captured-content, #js_content" : "#readeck-captured-content").first() else {
            throw WechatParseError.interactionRequired
        }
        if try !root.select("mp-pay-preview-filter, .mp-pay-preview-filter").isEmpty() {
            throw WechatParseError.blocked(reason: "当前只有付费预览，未取得完整正文")
        }
        // Normalize component boundaries before collecting images or CSS backgrounds.
        let normalizedWidgets = source.site == .wechat ? try WechatWidgetNormalizer.normalize(root, sourceURL: source.canonical) : 0
        let ordinaryImageCount = try root.select("img").count
        let readinessJSON = try root.attr("data-readeck-readiness")
        let readiness = readinessJSON.utf8.count <= 1024 ? try? JSONDecoder().decode(CaptureResourceReport.Readiness.self, from: Data(readinessJSON.utf8)) : nil
        var issues: [CaptureResourceIssue] = []
        let attempt = min(3, max(1, Int(try root.attr("data-readeck-attempt")) ?? 1))
        if let readiness, !readiness.settled { issues.append(.init(role: .bodyImage, position: 0, source: nil, reason: .timedOut)) }
        if let version = Int(try root.attr("data-readeck-policy-version")),
           let expected = Int(try root.attr("data-readeck-image-count")),
           (version != CaptureResourcePolicy.current.version || expected != ordinaryImageCount) {
            issues.append(.init(role: .bodyImage, position: 0, source: nil, reason: .scopeMismatch))
        }
        let title = try firstNonempty(document, selectors: ["meta[property=og:title]", "#activity-name", "title"], attribute: "content")
        let author = try firstNonempty(document, selectors: ["meta[name=author]", ".rich_media_meta_text", "#js_name"], attribute: "content")
        let site = try firstNonempty(document, selectors: source.site == .wechat ? ["#js_name", ".rich_media_meta_nickname"] : ["meta[property=og:site_name]"], attribute: "content")
        let published = try firstNonempty(document, selectors: ["meta[property=article:published_time]", "#publish_time"], attribute: "content")
        var resources: [String: [String: Any]] = [:]
        func collect(_ value: [String: Any]) {
            for item in value["WebSubresources"] as? [[String: Any]] ?? [] {
                if let url = item["WebResourceURL"] as? String { resources[resourceKey(url, base: source.original)] = item }
            }
            for frame in value["WebSubframeArchives"] as? [[String: Any]] ?? [] { collect(frame) }
        }
        collect(plist)
        struct Background: Decodable { let id: String; let url: String }
        var backgroundCount = 0
        var omittedBackgrounds = 0
        for node in try root.select("[style],[data-readeck-backgrounds]") {
            let frozen = try node.attr("data-readeck-backgrounds")
            let backgrounds: [Background]
            if !frozen.isEmpty {
                guard frozen.utf8.count <= limits.maximumHTMLBytes, let value = try? JSONDecoder().decode([Background].self, from: Data(frozen.utf8)) else { throw CaptureError.invalidPackage }
                backgrounds = value
            } else { backgrounds = WechatAssetResolver.backgroundURLs(try node.attr("style")).map { Background(id: "", url: $0) } }
            for background in backgrounds {
                backgroundCount += 1
                if try WechatAssetResolver.isKnownLoadingBackground(background.url, node: node) { omittedBackgrounds += 1; continue }
                try node.appendElement("img").attr("src", background.url).attr("data-readeck-background", "true").attr("data-readeck-resource-id", background.id)
            }
        }
        if let expected = Int(try root.attr("data-readeck-background-count")), expected != backgroundCount {
            issues.append(.init(role: .bodyBackground, position: 0, source: nil, reason: .scopeMismatch))
        }
        var vectors: [Element] = []
        for vector in try root.select("svg") {
            // Empty SVGs are sometimes zero-width layout shims. They contain no
            // drawable elements, image resources or accessible content to archive.
            let label = try vector.attr("aria-label").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let zeroWidth = try vector.attr("style").range(of: #"(?:^|;)\s*width\s*:\s*0(?:px|pt|em|rem|%)?\s*(?:;|$)"#, options: .regularExpression) != nil
            let genericLayoutLabel = zeroWidth && ["插图", "图片", "图像", "image", "illustration"].contains(label)
            if vector.children().isEmpty(), try vector.text().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               label.isEmpty || genericLayoutLabel {
                try vector.remove()
            } else { vectors.append(vector) }
        }
        for (index, _) in vectors.enumerated() {
            issues.append(.init(role: .bodyImage, position: ordinaryImageCount + index + 1, source: nil, reason: .decodeUnsupported))
        }
        var assets: [CapturedAsset] = []
        var archivedImages = 0
        var omittedImages = omittedBackgrounds
        var mapped: [String: URL] = [:]
        var imageBytes = 0
        let images = try root.select("img")
        guard images.count + vectors.count <= limits.maximumImages else { throw WechatParseError.parseError("正文图片数量超过上限。") }
        for (index, image) in images.enumerated() {
            let selected = try image.attr("data-readeck-src")
            let lazy = try image.attr("data-src")
            var responsive = try image.attr("srcset")
            if image.parent()?.tagName() == "picture", let picture = image.parent() {
                responsive += "," + (try picture.select("source[srcset]").map { try $0.attr("srcset") }.joined(separator: ","))
            }
            let candidates = WechatAssetResolver.srcsetURLs(responsive)
            let available = candidates.first { resources[resourceKey($0, base: source.original)] != nil }
            let src: String
            if !selected.isEmpty { src = selected }
            else if !lazy.isEmpty { src = lazy }
            else if let available { src = available }
            else if let candidate = candidates.first { src = candidate }
            else { src = try image.attr("src") }
            guard !src.isEmpty else { omittedImages += 1; try image.remove(); continue }
            let key = resourceKey(src, base: source.original)
            if let location = mapped[key] {
                archivedImages += 1
                try image.attr("src", location.absoluteString)
                try image.removeAttr("data-src"); try image.removeAttr("srcset")
                continue
            }
            guard assets.count + issues.count < limits.maximumImages else {
                throw WechatParseError.parseError("正文图片数量超过上限。")
            }
            let imageData: Data?
            if src.lowercased().hasPrefix("data:image/") {
                imageData = WechatAssetResolver.embeddedData(src, maximumBytes: limits.maximumImageBytes)
            } else { imageData = resources[key]?["WebResourceData"] as? Data }
            if let imageData, imageData.count > limits.maximumImageBytes { throw WechatParseError.parseError("单张图片超过大小上限。") }
            func recordMissing(_ reason: CaptureResourceIssue.Reason) throws {
                var parent = image.parent()
                var unknownWidget = false
                while let node = parent, node !== root {
                    if node.tagName().hasPrefix("mp-") { unknownWidget = true; break }
                    parent = node.parent()
                }
                let role: CaptureResourceRole = try image.attr("data-readeck-background") == "true" ? .bodyBackground : (unknownWidget ? .unknownWidget : .bodyImage)
                issues.append(.init(role: role, position: index + 1, source: URL(string: src, relativeTo: source.original), reason: reason, attempts: attempt, nodeID: try image.attr("data-readeck-resource-id")))
                try image.remove()
            }
            guard let data = imageData else {
                try recordMissing(.archiveMissing)
                continue
            }
            guard let decoded = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
                  let uti = CGImageSourceGetType(decoded), let type = WechatAssetResolver.typeInfo(uti as String) else {
                try recordMissing(.decodeUnsupported)
                continue
            }
            guard width <= limits.maximumImagePixels / height else { throw WechatParseError.parseError("单张图片像素数超过上限。") }
            if width <= 2 && height <= 2 {
                if source.site == .wechat { omittedImages += 1; try image.remove() }
                else { try recordMissing(.decodeUnsupported) }
                continue
            }
            let mime = type.mime
            if CGImageSourceGetCount(decoded) > 1 && CaptureImageIdentity.read(data) == nil {
                try recordMissing(.decodeUnsupported); continue
            }
            var uploadData = data
            var uploadMIME = mime
            var uploadExtension = type.fileExtension
            if mime == "image/avif" || (mime == "image/webp" && properties[kCGImagePropertyHasAlpha] as? Bool == true) {
                // Readeck 0.23.5 cannot decode AVIF and converts transparent WebP to a black matte.
                // A lossless PNG retains pixels while keeping the server archive readable.
                guard CGImageSourceGetCount(decoded) == 1, let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil) else {
                    try recordMissing(.decodeUnsupported); continue
                }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw CaptureError.invalidPackage }
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: properties[kCGImagePropertyOrientation] ?? 1] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw CaptureError.invalidPackage }
                uploadData = output as Data; uploadMIME = "image/png"; uploadExtension = "png"
                guard uploadData.count <= limits.maximumImageBytes else { throw WechatParseError.parseError("透明图片转换后的大小超过上限。") }
            }
            imageBytes += uploadData.count
            guard imageBytes <= limits.maximumTotalImageBytes else { throw WechatParseError.parseError("正文图片总大小超过上限。") }
            // Surrogate URLs contain no source authentication parameters or local paths.
            // Their bytes are supplied as matching resource parts, never fetched remotely.
            let location = URL(string: "https://readeck-capture.invalid/\(packageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "capture")/image-\(assets.count + 1).\(uploadExtension)")!
            mapped[key] = location
            archivedImages += 1
            assets.append(CapturedAsset(location: location, mimeType: uploadMIME, data: uploadData, width: width, height: height))
            try image.attr("src", location.absoluteString)
            try image.removeAttr("data-src"); try image.removeAttr("srcset")
        }
        guard !(try root.text()).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assets.isEmpty else {
            throw WechatParseError.noContent
        }
        for citation in try root.select("[cite]") { try citation.removeAttr("cite") }
        for anchor in try root.select("a[href]") {
            let href = try anchor.attr("href")
            guard let url = URL(string: href, relativeTo: source.canonical)?.absoluteURL,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.user == nil, parts.password == nil else {
                try anchor.removeAttr("href"); continue
            }
            let privateKeys = Set(["key", "pass_ticket", "wxtoken", "uin", "token", "access_token", "auth", "signature", "xsec_token", "xsec_source"])
            parts.queryItems = parts.queryItems?.filter { !privateKeys.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("x-amz-") && !$0.name.lowercased().hasPrefix("x-goog-") }
            if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
            try anchor.attr("href", parts.url?.absoluteString ?? "")
        }
        let whitelist = try Whitelist.relaxed().addTags("section", "figure", "figcaption", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "code")
        let clean = try SwiftSoup.clean(root.html(), source.canonical.absoluteString, whitelist) ?? ""
        let finalTitle = title.isEmpty ? source.site.title : title
        let finalSite = site.isEmpty ? (source.site == .wechat ? "微信公众号" : source.site.title) : site
        let originalCover = try firstNonempty(document, selectors: ["meta[property=og:image]", "meta[name=twitter:image]"], attribute: "content")
        var archivedCover = mapped[resourceKey(originalCover, base: source.original)]
        // The optional cover may not appear in the body. Package it separately so
        // Readeck can extract its thumbnail without treating it as a body image.
        if archivedCover == nil, !originalCover.isEmpty, assets.count < limits.maximumImages,
           let data = resources[resourceKey(originalCover, base: source.original)]?["WebResourceData"] as? Data,
           data.count <= limits.maximumImageBytes, imageBytes + data.count <= limits.maximumTotalImageBytes,
           let decoded = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
           width >= 120, height >= 80, width <= limits.maximumImagePixels / height,
           let uti = CGImageSourceGetType(decoded), let type = WechatAssetResolver.typeInfo(uti as String),
           !(type.mime == "image/webp" && props[kCGImagePropertyHasAlpha] as? Bool == true),
           let location = URL(string: "https://readeck-capture.invalid/\(packageID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "capture")/cover.\(type.fileExtension)") {
            assets.append(CapturedAsset(location: location, mimeType: type.mime, data: data, width: width, height: height, coverOnly: true))
            archivedCover = location
        }
        let coverMeta = archivedCover.map { "<meta property=\"og:image\" content=\"\(escape($0.absoluteString))\">" } ?? ""
        let final = "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">\(coverMeta)<title>\(escape(finalTitle))</title><meta name=\"author\" content=\"\(escape(author))\"><meta property=\"og:site_name\" content=\"\(escape(finalSite))\">\(published.isEmpty ? "" : "<meta property=\"article:published_time\" content=\"\(escape(published))\">")</head><body><article>\(clean)</article></body></html>"
        return CapturedArticle(url: source.canonical, title: finalTitle, author: author,
            siteName: finalSite, published: published.isEmpty ? nil : published,
            html: final, assets: assets, missingImages: issues.map(\.message),
            resourceReport: .init(policyVersion: CaptureResourcePolicy.current.version, discoveredImages: images.count + vectors.count + omittedBackgrounds, archivedImages: archivedImages, omittedImages: omittedImages, normalizedWidgets: normalizedWidgets, issues: issues, readiness: readiness))
    }

    private static func firstNonempty(_ doc: Document, selectors: [String], attribute: String) throws -> String {
        for selector in selectors {
            guard let element = try doc.select(selector).first() else { continue }
            let attributeValue = try element.attr(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
            if !attributeValue.isEmpty { return attributeValue }
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func resourceKey(_ value: String, base: URL) -> String {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return value }
        parts.fragment = nil
        return parts.url?.absoluteString ?? value
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
