import Foundation

struct CaptureManifest: Codable, Sendable {
    struct Asset: Codable, Sendable {
        let location: URL
        let mimeType: String
        let checksum: String
        let byteCount: Int
        var width: Int? = nil
        var height: Int? = nil
        var fingerprint: String? = nil
        var frameCount: Int? = nil
        var frameFingerprints: [String]? = nil
        var coverOnly: Bool? = nil
    }
    let url: URL
    let title: String
    let htmlChecksum: String
    let text: String
    let assets: [Asset]
    let missingImages: [String]
    var resourceReport: CaptureResourceReport? = nil
    /// Ordered references include repeated appearances; assets contain unique URLs.
    /// Absent on legacy packages, which retain their original verification rules.
    var imageOrder: [URL]? = nil
}

struct CapturePackage: Sendable {
    let manifest: CaptureManifest
    let html: String
    let directory: URL
    func file(for asset: CaptureManifest.Asset) -> URL { directory.appendingPathComponent(asset.checksum + ".image") }
}

enum CaptureError: LocalizedError {
    case invalidPackage, insufficientStorage, missingImages(Int), missingImageDetails([String]), verification(String)
    var errorDescription: String? {
        switch self {
        case .invalidPackage: "采集文件不完整或已损坏，请重新采集。"
        case .insufficientStorage: "本机可用空间不足，已保留原有采集文件。请释放空间后重试。"
        case let .missingImages(count): "有 \(count) 张正文图片未取得，已暂停上传，可重新采集。"
        case let .missingImageDetails(details): "采集尚未完成，已暂停上传。\n" + details.prefix(3).joined(separator: "\n")
        case let .verification(reason): "NAS 归档尚未验证：\(reason)"
        }
    }
}

/// Pending packages are durable outbox data, deliberately outside disposable caches.
actor CapturePackageStore {
    static let defaultRoot = LocalStore.defaultURL.deletingLastPathComponent().appendingPathComponent("CapturePackages", isDirectory: true)
    let root: URL
    private let availableBytes: @Sendable (URL) -> Int64?
    init(root: URL = defaultRoot, availableBytes: @escaping @Sendable (URL) -> Int64? = { url in
        var directory = url
        while !FileManager.default.fileExists(atPath: directory.path) && directory.path != "/" { directory.deleteLastPathComponent() }
        return (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }) { self.root = root; self.availableBytes = availableBytes }

    func directory(id: String, instance: String) -> URL {
        root.appendingPathComponent(DataHash.sha256(Data(instance.utf8)), isDirectory: true)
            .appendingPathComponent(DataHash.sha256(Data(id.utf8)), isDirectory: true)
    }

    func save(_ article: CapturedArticle, id: String, instance: String) throws -> CaptureManifest {
        try save(article, destination: directory(id: id, instance: instance))
    }

    func saveGeneration(_ article: CapturedArticle, id: String, instance: String) throws -> String {
        let generation = UUID().uuidString
        let destination = try generationDirectory(id: id, instance: instance, generation: generation)
        do {
            _ = try save(article, destination: destination)
            _ = try load(id: id, instance: instance, generation: generation)
            return generation
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func generationDirectory(id: String, instance: String, generation: String?) throws -> URL {
        let base = directory(id: id, instance: instance)
        guard let generation else { return base }
        guard UUID(uuidString: generation) != nil else { throw CaptureError.invalidPackage }
        return base.appendingPathComponent("generations", isDirectory: true).appendingPathComponent(generation, isDirectory: true)
    }

    private func save(_ article: CapturedArticle, destination: URL) throws -> CaptureManifest {
        guard destination.resolvingSymlinksInPath().path == destination.standardizedFileURL.path else { throw CaptureError.invalidPackage }
        let limits = CaptureLimits()
        guard article.html.utf8.count <= limits.maximumHTMLBytes, article.assets.count <= limits.maximumImages,
              article.assets.allSatisfy({ $0.data.count <= limits.maximumImageBytes }),
              article.assets.reduce(0, { $0 + $1.data.count }) <= limits.maximumTotalImageBytes else { throw CaptureError.invalidPackage }
        let required = Int64(article.html.utf8.count + article.assets.reduce(0, { $0 + $1.data.count })) + 16 * 1024 * 1024
        if let available = availableBytes(destination), available < required { throw CaptureError.insufficientStorage }
        let staging = destination.deletingLastPathComponent().appendingPathComponent("staging-" + UUID().uuidString)
        let html = Data(article.html.utf8)
        let manifest = CaptureManifest(url: article.url, title: article.title, htmlChecksum: DataHash.sha256(html),
            text: try CaptureVerification.normalizedText(article.html),
            assets: article.assets.map { asset in
                let visual = CaptureImageIdentity.read(asset.data)
                return .init(location: asset.location, mimeType: asset.mimeType, checksum: asset.checksum, byteCount: asset.data.count,
                    width: visual?.width ?? asset.width, height: visual?.height ?? asset.height, fingerprint: visual?.fingerprint, frameCount: visual?.frameCount, frameFingerprints: visual?.frameFingerprints, coverOnly: asset.coverOnly ? true : nil)
            }, missingImages: article.missingImages, resourceReport: article.resourceReport,
            imageOrder: (try CaptureSourceURL(article.url.absoluteString).site) == .wechat ? nil : try CaptureVerification.imageURLs(article.html, base: article.url))
        let metadata = try JSONEncoder().encode(manifest)
        guard metadata.count <= limits.maximumManifestBytes else { throw CaptureError.invalidPackage }
        if let available = availableBytes(destination), available < required + Int64(metadata.count) { throw CaptureError.insufficientStorage }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try html.write(to: staging.appendingPathComponent("page.html"), options: .atomic)
        for asset in article.assets { try asset.data.write(to: staging.appendingPathComponent(asset.checksum + ".image"), options: .atomic) }
        try metadata.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        // Immutable generations are published through the job only after a successful write.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CaptureError.invalidPackage }
        try FileManager.default.moveItem(at: staging, to: destination)
        return manifest
    }

    func load(id: String, instance: String, generation: String? = nil) throws -> CapturePackage {
        let dir = try generationDirectory(id: id, instance: instance, generation: generation)
        func read(_ name: String, maximum: Int) throws -> Data {
            let file = dir.appendingPathComponent(name)
            let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
            let info = try file.resourceValues(forKeys: keys)
            guard info.isSymbolicLink != true, info.isRegularFile == true,
                  let size = info.fileSize, size <= maximum,
                  dir.resolvingSymlinksInPath().path == dir.standardizedFileURL.path else { throw CaptureError.invalidPackage }
            return try Data(contentsOf: file, options: .mappedIfSafe)
        }
        let manifest = try JSONDecoder().decode(CaptureManifest.self, from: read("manifest.json", maximum: CaptureLimits().maximumManifestBytes))
        _ = try CaptureSourceURL(manifest.url.absoluteString)
        if let order = manifest.imageOrder {
            guard order.count <= CaptureLimits().maximumImages,
                  order.allSatisfy({ location in manifest.assets.contains(where: { $0.location == location }) }) else { throw CaptureError.invalidPackage }
        }
        let html = try read("page.html", maximum: CaptureLimits().maximumHTMLBytes)
        guard DataHash.sha256(html) == manifest.htmlChecksum, manifest.assets.count <= CaptureLimits().maximumImages,
              let text = String(data: html, encoding: .utf8) else { throw CaptureError.invalidPackage }
        var total = 0
        var verifiedAssets = manifest.assets
        for (index, asset) in manifest.assets.enumerated() {
            guard asset.checksum.count == 64, asset.checksum.allSatisfy({ $0.isHexDigit }),
                  asset.location.host == "readeck-capture.invalid", asset.mimeType.hasPrefix("image/"),
                  !asset.mimeType.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw CaptureError.invalidPackage }
            let data = try read(asset.checksum + ".image", maximum: CaptureLimits().maximumImageBytes)
            total += data.count
            guard data.count == asset.byteCount, DataHash.sha256(data) == asset.checksum,
                  total <= CaptureLimits().maximumTotalImageBytes else { throw CaptureError.invalidPackage }
            // Legacy packages have no frame metadata. Derive it from their
            // verified source bytes so an old animation cannot bypass new checks.
            if asset.frameCount == nil || ((asset.frameCount ?? 1) > 1 && asset.frameFingerprints == nil) {
                guard let visual = CaptureImageIdentity.read(data) else { throw CaptureError.invalidPackage }
                verifiedAssets[index].frameCount = visual.frameCount
                verifiedAssets[index].frameFingerprints = visual.frameFingerprints
            }
        }
        let verified = CaptureManifest(url: manifest.url, title: manifest.title, htmlChecksum: manifest.htmlChecksum, text: manifest.text,
            assets: verifiedAssets, missingImages: manifest.missingImages, resourceReport: manifest.resourceReport, imageOrder: manifest.imageOrder)
        return CapturePackage(manifest: verified, html: text, directory: dir)
    }

    func diskUsage() -> (pending: Int64, legacy: Int64) {
        func size(_ directory: URL) -> Int64 {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return 0 }
            var bytes: Int64 = 0
            for case let file as URL in files {
                guard let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      info.isSymbolicLink != true, info.isRegularFile == true else { continue }
                bytes += Int64(info.fileSize ?? 0)
            }
            return bytes
        }
        return (size(root), size(root.deletingLastPathComponent().appendingPathComponent("WechatImageCache")))
    }

    func remove(id: String, instance: String) throws {
        let dir = directory(id: id, instance: instance)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    func removeGeneration(id: String, instance: String, generation: String) throws {
        let dir = try generationDirectory(id: id, instance: instance, generation: generation)
        guard dir.resolvingSymlinksInPath().path == dir.standardizedFileURL.path else { throw CaptureError.invalidPackage }
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        // A cancelled late acquisition may have recreated otherwise empty containers.
        for parent in [dir.deletingLastPathComponent(), directory(id: id, instance: instance)] {
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try FileManager.default.removeItem(at: parent)
            }
        }
    }

    /// Only explicit housekeeping may remove old, unreferenced task directories.
    /// Every live job (including failed/uncertain jobs) protects all generations.
    func cleanOrphanedFiles(instance: String, protectedIDs: Set<String>, olderThan cutoff: Date) throws -> Int {
        let account = root.appendingPathComponent(DataHash.sha256(Data(instance.utf8)), isDirectory: true)
        guard FileManager.default.fileExists(atPath: account.path) else { return 0 }
        guard account.resolvingSymlinksInPath().path == account.standardizedFileURL.path else { throw CaptureError.invalidPackage }
        let protected = Set(protectedIDs.map { DataHash.sha256(Data($0.utf8)) })
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var removed = 0
        for candidate in try FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: Array(keys)) {
            let name = candidate.lastPathComponent
            guard !protected.contains(name), name.hasPrefix("staging-") || (name.count == 64 && name.allSatisfy(\.isHexDigit)) else { continue }
            let info = try candidate.resourceValues(forKeys: keys)
            guard info.isDirectory == true, info.isSymbolicLink != true,
                  let modified = info.contentModificationDate, modified < cutoff else { continue }
            try FileManager.default.removeItem(at: candidate); removed += 1
        }
        return removed
    }
}
