import Foundation
import SwiftSoup
import UniformTypeIdentifiers

enum WechatAssetResolver {
    static func embeddedData(_ source: String, maximumBytes: Int) -> Data? {
        guard source.lowercased().hasPrefix("data:image/"), source.utf8.count <= maximumBytes * 4,
              let comma = source.firstIndex(of: ",") else { return nil }
        let payload = String(source[source.index(after: comma)...])
        let decoded: Data?
        if source[..<comma].lowercased().hasSuffix(";base64") { decoded = Data(base64Encoded: payload.removingPercentEncoding ?? payload) }
        else { decoded = payload.removingPercentEncoding.map { Data($0.utf8) } }
        guard let decoded, decoded.count <= maximumBytes else { return nil }
        return decoded
    }

    static func isKnownLoadingBackground(_ source: String, node: Element, policy: CaptureResourcePolicy = .current) throws -> Bool {
        guard node.tagName() == "img", try node.select(policy.placeholderImageSelector).contains(where: { $0 === node }),
              source.lowercased().hasPrefix("data:image/svg+xml"),
              let data = embeddedData(source, maximumBytes: 16 * 1024) else { return false }
        return policy.placeholderSVGHashes.contains(DataHash.sha256(data))
    }

    static func backgroundURLs(_ style: String) -> [String] {
        splitTopLevel(style, separator: ";").flatMap { declaration -> [String] in
            guard let colon = declaration.firstIndex(of: ":") else { return [] }
            let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard property == "background" || property == "background-image" else { return [] }
            let value = String(declaration[declaration.index(after: colon)...])
            var result: [String] = [], index = value.startIndex
            while index < value.endIndex, let range = value.range(of: "url(", options: .caseInsensitive, range: index..<value.endIndex) {
                var cursor = range.upperBound, quoted: Character?, url = ""
                while cursor < value.endIndex && value[cursor].isWhitespace { cursor = value.index(after: cursor) }
                if cursor < value.endIndex && (value[cursor] == "\"" || value[cursor] == "'") { quoted = value[cursor]; cursor = value.index(after: cursor) }
                while cursor < value.endIndex {
                    let char = value[cursor]
                    if char == "\\" {
                        cursor = value.index(after: cursor)
                        if cursor < value.endIndex { url.append(value[cursor]); cursor = value.index(after: cursor) }
                        continue
                    }
                    if char == quoted || (quoted == nil && char == ")") { break }
                    url.append(char); cursor = value.index(after: cursor)
                }
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                index = cursor < value.endIndex ? value.index(after: cursor) : cursor
            }
            return result
        }
    }

    private static func splitTopLevel(_ value: String, separator: Character) -> [String] {
        var values: [String] = [], current = "", quote: Character?, depth = 0, escaped = false
        for char in value {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { current.append(char); escaped = true; continue }
            if let q = quote { if char == q { quote = nil } }
            else if char == "'" || char == "\"" { quote = char }
            else if char == "(" { depth += 1 }
            else if char == ")" { depth = max(0, depth - 1) }
            else if char == separator && depth == 0 { values.append(current); current = ""; continue }
            current.append(char)
        }
        values.append(current); return values
    }

    /// URL tokens may themselves contain commas (notably data: images).
    static func srcsetURLs(_ value: String) -> [String] {
        var index = value.startIndex, urls: [String] = []
        while index < value.endIndex {
            while index < value.endIndex && (value[index].isWhitespace || value[index] == ",") { index = value.index(after: index) }
            let start = index
            while index < value.endIndex && !value[index].isWhitespace { index = value.index(after: index) }
            var url = String(value[start..<index])
            let ended = url.last == ","
            while url.last == "," { url.removeLast() }
            if !url.isEmpty { urls.append(url) }
            if !ended { while index < value.endIndex && value[index] != "," { index = value.index(after: index) } }
        }
        return urls
    }

    /// ImageIO has already identified the bytes. Known MIME names do not require
    /// the LaunchServices database, which may be unavailable in a restricted process.
    static func typeInfo(_ identifier: String) -> (mime: String, fileExtension: String)? {
        let known: [String: (String, String)] = [
            "public.png": ("image/png", "png"), "public.jpeg": ("image/jpeg", "jpg"),
            "com.compuserve.gif": ("image/gif", "gif"), "org.webmproject.webp": ("image/webp", "webp"),
            "public.tiff": ("image/tiff", "tiff"), "com.microsoft.bmp": ("image/bmp", "bmp"),
            "public.heic": ("image/heic", "heic"), "public.avif": ("image/avif", "avif")
        ]
        if let value = known[identifier] { return value }
        guard let type = UTType(identifier), let mime = type.preferredMIMEType, mime.hasPrefix("image/") else { return nil }
        return (mime, type.preferredFilenameExtension ?? "bin")
    }
}
