import AppKit
import Darwin
import XCTest
@testable import ReadeckMac

final class CaptureBenchmarkTests: XCTestCase {
    func testSyntheticFiveTwentyFiveAndHundredImageBaselines() async throws {
        for count in [5, 25, 100] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            var resources: [[String: Any]] = [], tags = ""
            for index in 0..<count {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 1024, bitsPerPixel: 32)!
                var state = UInt64(index + 1)
                for offset in stride(from: 0, to: 256 * 1024, by: 4) {
                    state = state &* 6364136223846793005 &+ 1
                    rep.bitmapData?[offset] = UInt8(truncatingIfNeeded: state >> 24)
                    rep.bitmapData?[offset+1] = UInt8(truncatingIfNeeded: state >> 32)
                    rep.bitmapData?[offset+2] = UInt8(truncatingIfNeeded: state >> 40)
                    rep.bitmapData?[offset+3] = 255
                }
                let url = "https://fixture.invalid/image-\(index).png"
                resources.append(["WebResourceURL": url, "WebResourceData": rep.representation(using: .png, properties: [:])!])
                tags += "<img src='\(url)'>"
            }
            let archive = try PropertyListSerialization.data(fromPropertyList: ["WebMainResource": ["WebResourceData": Data("<div id='js_content'><p>自制合成样例</p>\(tags)</div>".utf8)], "WebSubresources": resources], format: .binary, options: 0)
            let start = Date()
            let article = try WechatArticleParser.extract(archive: archive, source: CaptureSourceURL("https://mp.weixin.qq.com/s/fixture"), packageID: "fixture")
            let parsed = Date()
            let packages = CapturePackageStore(root: root)
            let generation = try await packages.saveGeneration(article, id: "fixture", instance: "benchmark")
            let written = Date()
            let package = try await packages.load(id: "fixture", instance: "benchmark", generation: generation)
            XCTAssertEqual(package.manifest.assets.count, count)
            XCTAssertTrue(package.manifest.missingImages.isEmpty)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("CAPTURE_BASELINE images=\(count) archive_bytes=\(archive.count) parse_ms=\(Int(parsed.timeIntervalSince(start)*1000)) save_ms=\(Int(written.timeIntervalSince(parsed)*1000)) process_max_rss_bytes=\(usage.ru_maxrss)")
        }
    }
}
