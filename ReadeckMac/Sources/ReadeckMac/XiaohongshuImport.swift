import Foundation
import SwiftSoup

enum XiaohongshuImport {
    struct Prepared: Sendable {
        let html: String
        let source: CaptureSourceURL
        var resources: [String: Data]
        let images: [URL]
    }

    static func imageURL(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), ["xhscdn.com", "rednotecdn.com", "xiaohongshu.com", "rednote.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        parts.scheme = "https"; parts.fragment = nil; parts.port = nil
        return parts.url
    }

    static func prepare(data: Data, source: CaptureSourceURL) throws -> Prepared {
        guard source.site == .xiaohongshu, let id = source.articleID else { throw CaptureError.invalidPackage }
        let archive = try MHTMLArchive.read(data)
        let saved = try CaptureSourceURL(archive.url.absoluteString)
        guard saved.site == .xiaohongshu, saved.articleID == id else { throw WechatParseError.parseError("所选文件与当前小红书链接不是同一篇笔记。") }
        let doc = try SwiftSoup.parse(archive.html, saved.canonical.absoluteString)
        guard try doc.select("meta[property=og:type]").first()?.attr("content").lowercased() != "video",
              try doc.select("video").isEmpty() else { throw WechatParseError.parseError("这是一篇视频笔记，首版仅导入静态图文。") }
        guard let root = try doc.select("#noteContainer,.note-container").first(),
              let titleNode = try root.select("#detail-title").first(),
              let desc = try root.select("#detail-desc").first(),
              let counter = try root.select(".fraction,.pagination-fraction,.swiper-pagination-fraction").first(),
              let total = Int(try counter.text().split(separator: "/").last?.trimmingCharacters(in: .whitespaces) ?? ""), (1...100).contains(total) else {
            throw WechatParseError.parseError("单文件网页缺少完整的图文内容或图片总数，请重新保存。")
        }
        var slides: [Int: Element] = [:]
        for slide in try root.select(".swiper-slide:not(.swiper-slide-duplicate)") {
            guard let position = Int(try slide.attr("data-swiper-slide-index")), slides[position] == nil else { throw CaptureError.invalidPackage }
            slides[position] = slide
        }
        guard slides.count == total, (0..<total).allSatisfy({ slides[$0] != nil }) else { throw WechatParseError.parseError("网页未保存全部图片位置，请在浏览器中浏览图集后重新保存。") }
        let title = try titleNode.text()
        let author = try root.select(".author .username,.author-container .username,.author-name").first()?.text() ?? ""
        let body = try desc.text(trimAndNormaliseWhitespace: false).components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { "<p>" + escape($0) + "</p>" }.joined()
        var content = ""
        var images: [URL] = []
        for position in 0..<total {
            guard let node = try slides[position]!.select("img").first(), let url = imageURL(try node.attr("src")) else { throw WechatParseError.parseError("第 \(position + 1) 张图片没有可用的小红书图片地址。") }
            images.append(url); content += "<figure><img src=\"\(escape(url.absoluteString))\" alt=\"图片 \(position + 1)\"></figure>"
        }
        content += body
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(escape(title))</title><meta name=\"author\" content=\"\(escape(author))\"><meta property=\"og:site_name\" content=\"小红书\"></head><body><div id=\"readeck-captured-content\">\(content)</div></body></html>"
        let wanted = Set(images.map(\.absoluteString)); var resources: [String: Data] = [:]
        for resource in archive.resources {
            if let url = imageURL(resource.url.absoluteString), wanted.contains(url.absoluteString) { resources[url.absoluteString] = resource.data }
        }
        return Prepared(html: html, source: saved, resources: resources, images: images)
    }

    static func extract(data: Data, source: CaptureSourceURL, packageID: String) throws -> CapturedArticle {
        try article(prepare(data: data, source: source), packageID: packageID)
    }

    static func article(_ prepared: Prepared, packageID: String) throws -> CapturedArticle {
        let archive = try PropertyListSerialization.data(fromPropertyList: [
            "WebMainResource": ["WebResourceURL": prepared.source.canonical.absoluteString, "WebResourceMIMEType": "text/html", "WebResourceData": Data(prepared.html.utf8)],
            "WebSubresources": prepared.resources.map { ["WebResourceURL": $0.key, "WebResourceData": $0.value] }
        ], format: .binary, options: 0)
        return try CaptureArticleParser.extract(archive: archive, source: prepared.source, packageID: packageID)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
