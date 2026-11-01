import Foundation

/// One built-in rule set drives browser acquisition and archive normalization.
struct CaptureResourcePolicy: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case profile, music, miniprogramCard }
    struct WidgetRule: Codable, Sendable {
        let selector: String
        let kind: Kind
    }
    let version: Int
    let widgets: [WidgetRule]
    let placeholderImageSelector: String
    let placeholderSVGHashes: [String]
    static let current = CaptureResourcePolicy(version: 2, widgets: [
        .init(selector: "mp-common-profile", kind: .profile),
        .init(selector: "mp-common-clmusic", kind: .music),
        .init(selector: "mp-common-miniprogram[data-miniprogram-type=card]", kind: .miniprogramCard)
    ], placeholderImageSelector: "img.js_img_placeholder[data-src],img.wx_img_placeholder[data-src]",
       placeholderSVGHashes: ["cde6c3aa37096f46abfacbf004cb87e538d1caab30cafdecb1a7b22940f3c04a"])
    var selector: String { widgets.map(\.selector).joined(separator: ",") }
    var scriptJSON: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
}
