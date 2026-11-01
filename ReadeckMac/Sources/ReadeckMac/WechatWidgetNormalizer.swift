import Foundation
import SwiftSoup

/// Interactive card shadow trees contain UI artwork, not article illustrations.
/// Adapt only recognized widgets; unknown content keeps the strict image checks.
enum WechatWidgetNormalizer {
    @discardableResult
    static func normalize(_ root: Element, sourceURL: URL, policy: CaptureResourcePolicy = .current) throws -> Int {
        var count = 0
        for rule in policy.widgets {
            for widget in try root.select(rule.selector) {
                let label: String
                let detail: String
                let action: String
                switch rule.kind {
                case .profile:
                    let name = try value(widget, "data-nickname", fallback: widget.text())
                    label = name.isEmpty ? "公众号" : "公众号：\(name)"
                    detail = try widget.attr("data-signature")
                    action = "在原文中查看公众号"
                case .music:
                    let name = try value(widget, "music_name", fallback: "音乐")
                    let singer = try widget.attr("singer").trimmingCharacters(in: .whitespacesAndNewlines)
                    label = "音乐：\(name)" + (singer.isEmpty ? "" : " — \(singer)")
                    detail = "音乐内容请在原文中播放。"
                    action = "在原文中播放"
                case .miniprogramCard:
                    let name = try value(widget, "data-miniprogram-title", fallback: "小程序")
                    label = "小程序：\(name)"
                    detail = try widget.attr("data-miniprogram-nickname")
                    action = "在原文中打开小程序"
                }
                let replacement = try Element(Tag.valueOf("blockquote"), sourceURL.absoluteString)
                try replacement.appendElement("p").text(label)
                if !detail.isEmpty { try replacement.appendElement("p").text(detail) }
                try replacement.appendElement("p").appendElement("a").attr("href", sourceURL.absoluteString).text(action)
                try widget.before(replacement.outerHtml())
                try widget.remove()
                count += 1
            }
        }
        return count
    }

    private static func value(_ widget: Element, _ attribute: String, fallback: String) throws -> String {
        let value = try widget.attr(attribute).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }
}
