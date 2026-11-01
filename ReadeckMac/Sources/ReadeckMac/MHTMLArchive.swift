import Foundation

/// A bounded, self-contained browser archive. No MIME header becomes a local path.
struct MHTMLArchive {
    struct Resource { let url: URL; let mime: String; let data: Data }
    let url: URL
    let html: String
    let resources: [Resource]

    static func read(_ data: Data, limits: CaptureLimits = CaptureLimits()) throws -> MHTMLArchive {
        guard data.count <= limits.maximumArchiveBytes,
              let raw = String(data: data, encoding: .isoLatin1),
              let separator = raw.range(of: "\r\n\r\n") else { throw CaptureError.invalidPackage }
        let top = try headers(String(raw[..<separator.lowerBound]))
        guard let type = top["content-type"], type.lowercased().hasPrefix("multipart/related"),
              let regex = try? NSRegularExpression(pattern: #"(?i)boundary\s*=\s*(?:"([^"]+)"|([^;\s]+))"#),
              let match = regex.firstMatch(in: type, range: NSRange(type.startIndex..., in: type)),
              let range = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: type) else { throw CaptureError.invalidPackage }
        let boundary = String(type[range])
        guard !boundary.isEmpty, boundary.utf8.count <= 128, !boundary.contains("\r"), !boundary.contains("\n") else { throw CaptureError.invalidPackage }
        let chunks = ("\r\n" + raw[separator.upperBound...]).components(separatedBy: "\r\n--" + boundary)
        guard chunks.count > 2, chunks.count <= 514, chunks.last?.hasPrefix("--") == true else { throw CaptureError.invalidPackage }
        var main: (URL, String)?
        var resources: [Resource] = []
        var imageBytes = 0
        for chunk in chunks.dropFirst().dropLast() {
            guard chunk.hasPrefix("\r\n"), let split = chunk.range(of: "\r\n\r\n") else { throw CaptureError.invalidPackage }
            // CRLF is one Swift Character, not two. Use the actual range boundary.
            let headerStart = chunk.range(of: "\r\n")!.upperBound
            let fields = try headers(String(chunk[headerStart..<split.lowerBound]))
            let mime = fields["content-type"]?.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard mime == "text/html" || mime.hasPrefix("image/") else { continue }
            guard let location = fields["content-location"], let url = URL(string: location),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { continue }
            let body = String(chunk[split.upperBound...])
            let decoded = try decode(body, encoding: fields["content-transfer-encoding"]?.lowercased() ?? "8bit")
            if mime == "text/html", main == nil {
                guard decoded.count <= limits.maximumHTMLBytes, let html = String(data: decoded, encoding: .utf8) else { throw CaptureError.invalidPackage }
                main = (url, html)
            } else if mime.hasPrefix("image/") {
                imageBytes += decoded.count
                guard decoded.count <= limits.maximumImageBytes, imageBytes <= limits.maximumArchiveBytes else { throw CaptureError.invalidPackage }
                resources.append(Resource(url: url, mime: mime, data: decoded))
            }
        }
        guard let main else { throw CaptureError.invalidPackage }
        return .init(url: main.0, html: main.1, resources: resources)
    }

    private static func headers(_ value: String) throws -> [String: String] {
        guard value.utf8.count <= 65536 else { throw CaptureError.invalidPackage }
        var result: [String: String] = [:]
        var key: String?
        for line in value.components(separatedBy: "\r\n") {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let key else { throw CaptureError.invalidPackage }
                result[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                guard let colon = line.firstIndex(of: ":") else { throw CaptureError.invalidPackage }
                let name = line[..<colon].lowercased()
                guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), result[name] == nil else { throw CaptureError.invalidPackage }
                key = name; result[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return result.mapValues { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func decode(_ body: String, encoding: String) throws -> Data {
        switch encoding {
        case "base64":
            let compact = body.filter { !$0.isWhitespace }
            guard let data = Data(base64Encoded: compact) else { throw CaptureError.invalidPackage }
            return data
        case "quoted-printable":
            let bytes = Array(body.utf8); var result = Data(); var index = 0
            while index < bytes.count {
                if bytes[index] != 61 { result.append(bytes[index]); index += 1; continue }
                guard index + 2 < bytes.count else { throw CaptureError.invalidPackage }
                if bytes[index + 1] == 13 && bytes[index + 2] == 10 { index += 3; continue }
                guard let value = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) else { throw CaptureError.invalidPackage }
                result.append(value); index += 3
            }
            return result
        case "8bit", "binary", "7bit":
            guard let data = body.data(using: .isoLatin1) else { throw CaptureError.invalidPackage }; return data
        default: throw CaptureError.invalidPackage
        }
    }
}
