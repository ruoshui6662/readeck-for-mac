import Foundation
import SwiftSoup

enum CaptureVerification {
    /// New gallery captures must preserve order and readable resolution. Extra
    /// server headings/cover images are permitted, but cannot replace source pages.
    static func orderedImagesMatch(expected: [CaptureManifest.Asset], actual: [CaptureImageIdentity.Value]) -> Bool {
        guard expected.count <= CaptureLimits().maximumImages, actual.count <= CaptureLimits().maximumImages else { return false }
        var cursor = 0
        for asset in expected {
            var found = false
            while cursor < actual.count {
                let image = actual[cursor]; cursor += 1
                let requiredWidth = min(asset.width ?? Int.max, 1536)
                if Double(image.width) >= Double(requiredWidth) * 0.95,
                   imagesMatch(expected: [asset], actual: [image]) { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    static func dimensionsMatch(expected: [CaptureManifest.Asset], actual: [(Int, Int)]) -> Bool {
        completeMatching(expectedCount: expected.count, actualCount: actual.count) { index, candidate in
            dimensionsCompatible(expected[index], actual[candidate])
        }
    }

    private static func dimensionsCompatible(_ asset: CaptureManifest.Asset, _ value: (Int, Int)) -> Bool {
        guard let width = asset.width, let height = asset.height, width > 0, height > 0,
              value.0 > 0, value.1 > 0, max(value.0, value.1) >= min(max(width, height), 64) else { return false }
        return abs(log((Double(value.0) / Double(value.1)) / (Double(width) / Double(height)))) < 0.15
    }

    static func imagesMatch(expected: [CaptureManifest.Asset], actual: [CaptureImageIdentity.Value]) -> Bool {
        completeMatching(expectedCount: expected.count, actualCount: actual.count) { index, candidate in
            let asset = expected[index], image = actual[candidate]
            return (asset.frameCount == nil || asset.frameCount == image.frameCount) &&
                dimensionsCompatible(asset, (image.width, image.height)) &&
                CaptureImageIdentity.resembles(asset.fingerprint, image.fingerprint) && framesMatch(expected: asset, actual: image)
        }
    }

    /// Similar illustrations can have overlapping candidates. An augmenting-path
    /// matching avoids consuming the only valid image for a later source asset.
    private static func completeMatching(expectedCount: Int, actualCount: Int, compatible: (Int, Int) -> Bool) -> Bool {
        guard expectedCount <= actualCount, expectedCount <= CaptureLimits().maximumImages else { return false }
        let candidates = (0..<expectedCount).map { index in (0..<actualCount).filter { compatible(index, $0) } }
        var owners = [Int?](repeating: nil, count: actualCount)
        func assign(_ index: Int, seen: inout Set<Int>) -> Bool {
            for candidate in candidates[index] where seen.insert(candidate).inserted {
                if owners[candidate] == nil || assign(owners[candidate]!, seen: &seen) {
                    owners[candidate] = index; return true
                }
            }
            return false
        }
        for index in candidates.indices {
            var seen = Set<Int>()
            if !assign(index, seen: &seen) { return false }
        }
        return true
    }
    private static func framesMatch(expected: CaptureManifest.Asset, actual: CaptureImageIdentity.Value) -> Bool {
        guard (expected.frameCount ?? 1) > 1 else { return true }
        guard let left = expected.frameFingerprints, let right = actual.frameFingerprints,
              left.count == right.count, left.count == expected.frameCount else { return false }
        return zip(left, right).allSatisfy { resemblesFrame($0.0, $0.1) }
    }
    private static func resemblesFrame(_ left: String, _ right: String) -> Bool { CaptureImageIdentity.resembles(left, right) }
    static func normalizedText(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        return (try doc.body()?.text() ?? "").filter { !$0.isWhitespace && !$0.isNewline }
    }
    static func imageURLs(_ html: String, base: URL) throws -> [URL] {
        try SwiftSoup.parse(html, base.absoluteString).select("img[src]").compactMap {
            URL(string: try $0.attr("src"), relativeTo: base)?.absoluteURL
        }
    }
    static func matches(_ html: String, manifest: CaptureManifest) throws -> Bool {
        let actual = try normalizedText(html)
        // Readeck may add a heading or reformat the DOM; compare body text, not markup.
        return manifest.text.isEmpty ? !manifest.assets.isEmpty : actual.contains(manifest.text)
    }
}
