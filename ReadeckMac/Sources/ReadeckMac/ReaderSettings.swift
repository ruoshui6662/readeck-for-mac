import Combine
import Foundation

struct ReaderStyle: Equatable {
    var fontFamily: String
    var fontSize: Double
    var lineHeight: Double
    var contentWidth: Double
    var theme: String
    var paragraphSpacing: Double = 1.1
    var letterSpacing: Double = 0
    var unifiedLayout: Bool = true
    var imageSpacing: Double = 1
    var imageWidth: Double = 100
    var firstLineIndent: Bool = false
    var alignment: String = "justify"

    static let standard = ReaderStyle(fontFamily: "system", fontSize: 15, lineHeight: 1.6,
                                      contentWidth: 700, theme: "system")

    var normalized: ReaderStyle {
        var result = self
        result.fontSize = Self.clamp(fontSize, 12...30, fallback: 15)
        result.lineHeight = Self.clamp(lineHeight, 1.2...2.2, fallback: 1.6)
        result.contentWidth = Self.clamp(contentWidth, 480...980, fallback: 700)
        result.paragraphSpacing = Self.clamp(paragraphSpacing, 0.4...1.8, fallback: 1.1)
        result.letterSpacing = Self.clamp(letterSpacing, 0...0.12, fallback: 0)
        result.imageSpacing = Self.clamp(imageSpacing, 0.4...2, fallback: 1)
        result.imageWidth = Self.clamp(imageWidth, 50...100, fallback: 100)
        if !["left", "justify"].contains(alignment) { result.alignment = "justify" }
        if !["system", "light", "dark", "sepia"].contains(theme) { result.theme = "system" }
        return result
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    var css: String {
        let value = normalized
        let family: String
        switch value.fontFamily {
        case "pingfang": family = "'PingFang SC', -apple-system, sans-serif"
        case "songti": family = "'Songti SC', 'Noto Serif CJK SC', serif"
        case "serif": family = "'New York', Georgia, 'Songti SC', serif"
        case "mono": family = "'SF Mono', Menlo, 'PingFang SC', monospace"
        default:
            if value.fontFamily.hasPrefix("custom:") {
                let name = String(value.fontFamily.dropFirst(7)).replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                family = "'\(name)', -apple-system, 'PingFang SC', sans-serif"
            } else { family = "-apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif" }
        }
        let background: String, foreground: String, link: String
        switch value.theme {
        case "dark": (background, foreground, link) = ("#1c1c1e", "#e4e4e7", "#9cc5ff")
        case "sepia": (background, foreground, link) = ("#f6f1e7", "#423b31", "#65543b")
        default: (background, foreground, link) = ("#ffffff", "#292929", "#315fc5")
        }
        return """
        :root { color-scheme: \(value.theme == "dark" ? "dark" : "light");
          --reader-font: \(family); --reader-size: \(value.fontSize)px;
          --reader-line: \(value.lineHeight); --reader-paragraph: \(value.paragraphSpacing)em;
          --reader-image-gap: \(value.imageSpacing)em; --reader-image-width: \(value.imageWidth)%;
          --reader-indent: \(value.firstLineIndent ? 2 : 0)em; --reader-alignment: \(value.alignment); }
        html, body { margin: 0; padding: 0; width: 100%; min-width: 0; background: \(background); }
        ::selection { background-color: rgba(64, 156, 255, 0.28); color: inherit; }
        ::highlight(reader-find) { background-color: rgba(255, 204, 0, .32); color: inherit; }
        ::highlight(reader-find-current) { background-color: rgba(255, 159, 10, .65); color: inherit; }
        body { color: \(foreground); overflow-x: hidden; font-family: var(--reader-font);
          font-size: var(--reader-size); line-height: var(--reader-line); -webkit-font-smoothing: antialiased; }
        #reader-content { box-sizing: border-box; width: 100%; max-width: \(value.contentWidth)px;
          margin: 0 auto; padding: 30px clamp(22px, 4vw, 48px) 80px;
          overflow-wrap: anywhere; letter-spacing: \(value.letterSpacing)em; }
          #reader-content { text-align: justify; }
        #reader-content :where(article, section, div, p, figure, ul, ol, blockquote) {
          box-sizing: border-box; max-inline-size: 100% !important; min-inline-size: 0 !important; }
        #reader-content :where(p, li, div, span, section, article, blockquote) {
          font-family: inherit !important; font-size: inherit !important; line-height: inherit !important; }
        #reader-content p { margin-block: 0 var(--reader-paragraph) !important; }
        #reader-content h1, #reader-content h2, #reader-content h3,
        #reader-content h4, #reader-content h5, #reader-content h6 {
          font-family: var(--reader-font) !important; line-height: 1.4 !important;
          font-weight: 650; margin: 1.6em 0 .65em; overflow-wrap: anywhere; }
        #reader-content h1 { font-size: 1.7em !important; letter-spacing: -.025em; }
        #reader-content h2 { font-size: 1.35em !important; }
        #reader-content h3 { font-size: 1.15em !important; }
        #reader-content h4, #reader-content h5, #reader-content h6 { font-size: 1em !important; }
        #reader-content > :first-child { margin-top: 0; }
        #reader-content img, #reader-content video { max-width: 100% !important; height: auto !important; border-radius: 4px; }
        #reader-content figure { margin: 1.5em 0; }
        #reader-content figcaption { opacity: .6; font-size: .85em; text-align: center; margin-top: .6em; }
        #reader-content a { color: \(link); text-decoration-thickness: .06em; text-underline-offset: .15em; }
        #reader-content pre { max-width: 100%; overflow-x: auto; padding: 16px; border-radius: 8px;
          background: rgba(128,128,128,.09); white-space: pre; overflow-wrap: normal; }
        #reader-content pre, #reader-content code, #reader-content pre * {
          font-family: 'SF Mono', Menlo, monospace !important; letter-spacing: 0; font-size: .9em; }
        #reader-content blockquote { margin: 1.4em 0; padding: .15em 0 .15em 1.1em;
          border-left: 2px solid rgba(128,128,128,.3); opacity: .85; }
        #reader-content table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; margin: 1.5em 0; }
        #reader-content td, #reader-content th { padding: .5em .75em; border: 1px solid rgba(128,128,128,.2); }
        #reader-content li { margin-bottom: .35em; }
        #reader-content hr { border: 0; border-top: 1px solid rgba(128,128,128,.2); margin: 2em 0; }
        """ + ReaderReflow.css
    }
}

@MainActor
final class ReaderPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var style: ReaderStyle { didSet { persist() } }
    @Published var outlinePresentation: ReaderOutlinePresentation {
        didSet { defaults.set(outlinePresentation.rawValue, forKey: "reader.outlinePresentation") }
    }

    func toggleBrightness(systemIsDark: Bool) {
        let theme = style.normalized.theme
        let isDark = theme == "dark" || (theme == "system" && systemIsDark)
        style.theme = isDark ? "light" : "dark"
    }
    @Published private var compatibilityScopes: Set<AnnotationScope> {
        didSet { defaults.set(compatibilityScopes.map { ["article": $0.bookmarkID, "connection": $0.connectionID] },
                              forKey: "reader.compatibilityArticles") }
    }

    func usesCompatibility(for scope: AnnotationScope) -> Bool { compatibilityScopes.contains(scope) }
    func setCompatibility(_ value: Bool, for scope: AnnotationScope) {
        if value { compatibilityScopes.insert(scope) } else { compatibilityScopes.remove(scope) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outlinePresentation = ReaderOutlinePresentation(rawValue: defaults.string(forKey: "reader.outlinePresentation") ?? "") ?? .immersive
        compatibilityScopes = Set((defaults.array(forKey: "reader.compatibilityArticles") as? [[String: String]] ?? []).compactMap {
            guard let article = $0["article"], let connection = $0["connection"] else { return nil }
            return AnnotationScope(bookmarkID: article, connectionID: connection)
        })
        func number(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: "reader." + key) == nil ? fallback : defaults.double(forKey: "reader." + key)
        }
        style = ReaderStyle(fontFamily: defaults.string(forKey: "reader.fontFamily") ?? "system",
                            fontSize: number("fontSize", 15), lineHeight: number("lineHeight", 1.6),
                            contentWidth: number("contentWidth", 700), theme: defaults.string(forKey: "reader.theme") ?? "system",
                            paragraphSpacing: number("paragraphSpacing", 1.1), letterSpacing: number("letterSpacing", 0),
                            imageSpacing: number("imageSpacing", 1), imageWidth: number("imageWidth", 100),
                            firstLineIndent: defaults.bool(forKey: "reader.firstLineIndent"),
                            alignment: defaults.string(forKey: "reader.alignment") ?? "justify").normalized
    }

    func reset() { style = .standard }

    var presetName: String {
        let value = style.normalized
        func matches(_ size: Double, _ line: Double, _ paragraph: Double, _ width: Double) -> Bool {
            abs(value.fontSize-size) < 0.001 && abs(value.lineHeight-line) < 0.001
                && abs(value.paragraphSpacing-paragraph) < 0.001 && abs(value.contentWidth-width) < 0.001
                && value.letterSpacing == 0 && value.imageSpacing == 1 && value.imageWidth == 100
                && !value.firstLineIndent && value.alignment == "justify"
        }
        if matches(15, 1.6, 1.1, 700) { return "compact" }
        if matches(17, 1.8, 1.25, 740) { return "comfortable" }
        if matches(20, 1.8, 1.3, 780) { return "large" }
        return "custom"
    }

    func applyPreset(_ name: String) {
        var updated = style
        updated.letterSpacing = 0
        updated.imageSpacing = 1; updated.imageWidth = 100
        updated.firstLineIndent = false; updated.alignment = "justify"
        switch name {
        case "comfortable": updated.fontSize = 17; updated.lineHeight = 1.8; updated.paragraphSpacing = 1.25; updated.contentWidth = 740
        case "large": updated.fontSize = 20; updated.lineHeight = 1.8; updated.paragraphSpacing = 1.3; updated.contentWidth = 780
        default: updated.fontSize = 15; updated.lineHeight = 1.6; updated.paragraphSpacing = 1.1; updated.contentWidth = 700
        }
        style = updated
    }

    private func persist() {
        let value = style.normalized
        defaults.set(value.fontFamily, forKey: "reader.fontFamily")
        defaults.set(value.fontSize, forKey: "reader.fontSize")
        defaults.set(value.lineHeight, forKey: "reader.lineHeight")
        defaults.set(value.contentWidth, forKey: "reader.contentWidth")
        defaults.set(value.theme, forKey: "reader.theme")
        defaults.set(value.paragraphSpacing, forKey: "reader.paragraphSpacing")
        defaults.set(value.letterSpacing, forKey: "reader.letterSpacing")
        defaults.set(value.imageSpacing, forKey: "reader.imageSpacing")
        defaults.set(value.imageWidth, forKey: "reader.imageWidth")
        defaults.set(value.firstLineIndent, forKey: "reader.firstLineIndent")
        defaults.set(value.alignment, forKey: "reader.alignment")
    }
}

/// Kept separate from typography so presets and reset do not move the reader's tools.
enum ReaderOutlinePresentation: String, CaseIterable {
    case immersive, classic

    func showsInline(at width: CGFloat, hasHeadings: Bool) -> Bool {
        self == .immersive && hasHeadings && width >= 800
    }
}
