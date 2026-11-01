import CryptoKit
import Foundation

struct CaptureLimits: Sendable {
    var maximumArchiveBytes = 96 * 1_024 * 1_024
    var maximumHTMLBytes = 8 * 1_024 * 1_024
    // Up to 100 × 300 frame signatures plus JSON-escaped 8MiB article text.
    var maximumManifestBytes = 64 * 1_024 * 1_024
    var maximumImageBytes = 12 * 1_024 * 1_024
    var maximumTotalImageBytes = 32 * 1_024 * 1_024
    var maximumImages = 100
    var maximumImagePixels = 80_000_000
}

struct CapturedAsset: Sendable {
    let location: URL
    let mimeType: String
    let data: Data
    let width: Int
    let height: Int
    var coverOnly: Bool = false
    var checksum: String { DataHash.sha256(data) }
}

struct CapturedArticle: Sendable {
    let url: URL
    let title: String
    let author: String
    let siteName: String
    let published: String?
    let html: String
    let assets: [CapturedAsset]
    let missingImages: [String]
    var resourceReport: CaptureResourceReport? = nil
}

enum DataHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
