import Foundation
import SwiftSoup

/// Template field names follow WeChat's public page data (types 0, 8 and 10).
/// Reference: wechat-article-exporter/shared/utils/renderer.ts (MIT); no runtime dependency.
enum WechatTemplateAdapter {
    static func html(type: Int, html: String, text: String, pictures: [String]) throws -> String {
        guard [0, 8, 10].contains(type), html.utf8.count + text.utf8.count <= CaptureLimits().maximumHTMLBytes,
              pictures.count <= CaptureLimits().maximumImages else { throw WechatParseError.noContent }
        let doc = try SwiftSoup.parse("<section id='readeck-captured-content'></section>")
        let root = try doc.select("#readeck-captured-content").first()!
        if type == 10 {
            for line in text.components(separatedBy: .newlines) { try root.appendElement("p").text(line) }
        } else {
            try root.html(html)
            if type == 8 {
                for url in pictures {
                    guard let value = URL(string: url.replacingOccurrences(of: "&amp;", with: "&")),
                          ["http", "https"].contains(value.scheme?.lowercased() ?? "") else { throw WechatParseError.noContent }
                    try root.appendElement("figure").appendElement("img").attr("src", value.absoluteString)
                }
            }
        }
        return try root.outerHtml()
    }
}

enum WechatImport {
    static func archive(data: Data, fileExtension: String, source: CaptureSourceURL) throws -> Data {
        guard data.count <= CaptureLimits().maximumArchiveBytes else { throw CaptureError.invalidPackage }
        if fileExtension.lowercased() == "webarchive" {
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let main = plist["WebMainResource"] as? [String: Any], let raw = main["WebResourceURL"] as? String,
                  try CaptureSourceURL(raw).canonical == source.canonical else { throw CaptureError.invalidPackage }
            return data
        }
        guard ["html", "htm"].contains(fileExtension.lowercased()), data.count <= CaptureLimits().maximumHTMLBytes,
              String(data: data, encoding: .utf8) != nil else { throw CaptureError.invalidPackage }
        // No file URLs or adjacent files are opened. Embedded data: images are decoded by the adapter.
        return try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": data,
            "WebResourceURL": source.canonical.absoluteString, "WebResourceMIMEType": "text/html"]], format: .binary, options: 0)
    }
}
