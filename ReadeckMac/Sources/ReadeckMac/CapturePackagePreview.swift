import Foundation
import SwiftSoup

struct CapturePackagePreview: Identifiable, Sendable {
    struct Resource: Sendable { let data: Data; let mime: String }
    let id: UUID
    let url: URL
    let html: String
    let resources: [URL: Resource]
    func resource(for url: URL) -> Resource? { resources[url] }

    static func make(package: CapturePackage) throws -> CapturePackagePreview {
        let id = UUID()
        let base = URL(string: "readeck-preview://\(id.uuidString.lowercased())/")!
        let page = base.appendingPathComponent("index.html")
        let whitelist = try Whitelist.relaxed().addTags("section", "figure", "figcaption", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "code")
        let clean = try SwiftSoup.clean(package.html, "", whitelist) ?? ""
        let document = try SwiftSoup.parse(clean)
        var resources: [URL: Resource] = [:]
        var mappings: [String: URL] = [:]
        for asset in package.manifest.assets {
            let file = package.file(for: asset)
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard info.isSymbolicLink != true, info.isRegularFile == true,
                  info.fileSize == asset.byteCount, asset.byteCount <= CaptureLimits().maximumImageBytes else { throw CaptureError.invalidPackage }
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard DataHash.sha256(bytes) == asset.checksum else { throw CaptureError.invalidPackage }
            let url = base.appendingPathComponent(asset.checksum + ".image")
            resources[url] = Resource(data: bytes, mime: asset.mimeType)
            mappings[asset.location.absoluteString] = url
        }
        for image in try document.select("img") {
            guard let url = mappings[try image.attr("src")] else { try image.remove(); continue }
            try image.attr("src", url.absoluteString)
            try image.removeAttr("srcset")
        }
        for anchor in try document.select("a") { try anchor.removeAttr("href") }
        let body = try document.body()?.html() ?? ""
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src readeck-preview:; style-src 'unsafe-inline'; script-src 'none'; connect-src 'none'; base-uri 'none'; form-action 'none'">
        <style>\(ReaderStyle.standard.css)</style></head><body><main id="reader-content">\(body)</main></body></html>
        """
        resources[page] = Resource(data: Data(html.utf8), mime: "text/html")
        return CapturePackagePreview(id: id, url: page, html: html, resources: resources)
    }
}
