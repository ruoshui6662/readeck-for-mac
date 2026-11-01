import AppKit
import ImageIO
import XCTest
@testable import ReadeckMac

private final class VerificationURLProtocol: URLProtocol {
    static var imageData = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let data: Data
        if path.hasSuffix("/article") { data = Data("<p>正文</p><img src='/api/bookmarks/one/resources/image'>".utf8) }
        else if path.hasSuffix("/image") { data = Self.imageData }
        else { data = Data(#"{"id":"one","url":"https://mp.weixin.qq.com/s/one","state":0,"has_article":true}"#.utf8) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class CaptureVerificationTests: XCTestCase {
    func testSimilarImagesUseCompleteAssignmentRatherThanGreedyFirstMatch() {
        func signature(_ value: UInt8) -> String { Data(repeating: value, count: 192).base64EncodedString() }
        let expected = [UInt8(10), 0].map { value in
            CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/\(value)")!, mimeType: "image/png", checksum: "", byteCount: 10, width: 32, height: 32, fingerprint: signature(value), frameCount: 1)
        }
        let actual = [UInt8(0), 20].map { CaptureImageIdentity.Value(width: 32, height: 32, fingerprint: signature($0)) }
        XCTAssertTrue(CaptureVerification.imagesMatch(expected: expected, actual: actual))
        XCTAssertFalse(CaptureVerification.imagesMatch(expected: expected, actual: [actual[1], actual[1]]))
    }
    func testAnimatedImagesWithSameFirstFrameButDifferentLaterFrameDoNotMatch() throws {
        func gif(_ secondByte: UInt8) throws -> Data {
            let bytes = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "com.compuserve.gif" as CFString, 2, nil))
            for fill in [UInt8(80), secondByte] {
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
                for i in stride(from: 0, to: 4096, by: 4) { rep.bitmapData?[i] = fill; rep.bitmapData?[i+1] = fill; rep.bitmapData?[i+2] = fill; rep.bitmapData?[i+3] = 255 }
                CGImageDestinationAddImage(destination, rep.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return bytes as Data
        }
        let first = try XCTUnwrap(CaptureImageIdentity.read(try gif(20)))
        let changed = try XCTUnwrap(CaptureImageIdentity.read(try gif(230)))
        let asset = CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/a")!, mimeType: "image/gif", checksum: "", byteCount: 10, width: first.width, height: first.height, fingerprint: first.fingerprint, frameCount: first.frameCount, frameFingerprints: first.frameFingerprints)
        XCTAssertFalse(CaptureVerification.imagesMatch(expected: [asset], actual: [changed]))
    }
    func testAnimatedCaptureCannotVerifyAgainstOnlyItsFirstFrame() throws {
        let identity = try XCTUnwrap(CaptureImageIdentity.read(WechatCaptureTests.png()))
        let asset = CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/animation")!, mimeType: "image/gif", checksum: "", byteCount: 100, width: 32, height: 32, fingerprint: identity.fingerprint, frameCount: 2)
        XCTAssertFalse(CaptureVerification.imagesMatch(expected: [asset], actual: [identity]))
    }

    func testNASImageMustResembleCaptureBeforeOriginalPackageCanBeReleased() async throws {
        let original = WechatCaptureTests.png()
        let identity = try XCTUnwrap(CaptureImageIdentity.read(original))
        let asset = CaptureManifest.Asset(location: URL(string: "https://readeck-capture.invalid/image")!, mimeType: "image/png", checksum: DataHash.sha256(original), byteCount: original.count, width: 32, height: 32, fingerprint: identity.fingerprint)
        let manifest = CaptureManifest(url: URL(string: "https://mp.weixin.qq.com/s/one")!, title: "文章", htmlChecksum: "", text: "正文", assets: [asset], missingImages: [])
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [VerificationURLProtocol.self]
        let client = ReadeckClient(address: try ServerAddress("https://nas.test/"), token: "test", session: URLSession(configuration: configuration))
        let replacement = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        for offset in stride(from: 0, to: 128 * 32, by: 4) {
            replacement.bitmapData?[offset] = 240; replacement.bitmapData?[offset + 1] = 0
            replacement.bitmapData?[offset + 2] = 0; replacement.bitmapData?[offset + 3] = 255
        }
        VerificationURLProtocol.imageData = replacement.representation(using: .png, properties: [:])!
        do { _ = try await client.verifyCapture(id: "one", manifest: manifest); XCTFail("unrelated equally-sized NAS image was accepted") } catch { }
        VerificationURLProtocol.imageData = original
        _ = try await client.verifyCapture(id: "one", manifest: manifest)
    }
}
