import Foundation

enum CaptureMultipart {
    struct File { let url: URL; let contentType: String }
    static func write(package: CapturePackage, title: String, labels: [String], directory: URL) throws -> File {
        guard package.manifest.missingImages.isEmpty else { throw CaptureError.missingImages(package.manifest.missingImages.count) }
        let boundary = "ReadeckCapture-" + UUID().uuidString
        let url = directory.appendingPathComponent("upload-" + UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: url)
        var succeeded = false
        defer { try? handle.close(); if !succeeded { try? FileManager.default.removeItem(at: url) } }
        func append(_ value: String) throws { try handle.write(contentsOf: Data(value.utf8)) }
        func field(_ name: String, _ value: String) throws {
            try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        func resource(_ name: String, _ location: URL, _ mime: String, _ file: URL) throws {
            guard !location.absoluteString.contains(where: { $0 == "\r" || $0 == "\n" }), !mime.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw CaptureError.invalidPackage }
            try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"resource\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\nLocation: \(location.absoluteString)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty { try handle.write(contentsOf: chunk) }
            try append("\r\n")
        }
        try field("url", package.manifest.url.absoluteString)
        try field("title", title)
        for label in labels { try field("labels", label) }
        try field("feature_find_main", "false")
        try resource("page.html", package.manifest.url, "text/html; charset=utf-8", package.directory.appendingPathComponent("page.html"))
        for (index, asset) in package.manifest.assets.enumerated() { try resource("image-\(index)", asset.location, asset.mimeType, package.file(for: asset)) }
        try append("--\(boundary)--\r\n")
        succeeded = true
        return File(url: url, contentType: "multipart/form-data; boundary=\(boundary)")
    }
}
